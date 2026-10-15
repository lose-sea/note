# Milvus 上手：从部署到第一次检索

> Milvus 是向量数据库里"功能最全、架构最重"的那个。
> 这篇不讲原理，只讲**从零跑通**——包括那些文档里没写的坑。

## 一、先判断你要不要 Milvus

**别因为"听说性能好"就上 Milvus。**

| 你的情况 | 建议 |
|---|---|
| 数据量 < 100 万 | **别用**，pgvector / Qdrant 更合适 |
| 数据量 100 万 ~ 1000 万 | Qdrant 更省心 |
| 数据量 > 1000 万 | Milvus 的舞台 |
| 需要 GPU 检索 | Milvus |
| 团队没有 K8s 经验 | **别用**，运维会拖垮你 |

**Milvus 的复杂度来自它的分布式架构**：

```
┌─────────────────────────────────────────┐
│              Milvus 集群                 │
├──────────┬──────────┬──────────┬────────┤
│ Proxy    │ Coordinator │ QueryNode │ ...  │
└──────────┴──────────┴──────────┴────────┘
     ↓           ↓            ↓
  etcd       MinIO       Pulsar/Kafka
（元数据）  （对象存储）  （消息队列）
```

**五个外部依赖**——这就是它"重"的原因。

## 二、部署：开发环境（Standalone）

**最简单的方式是 Docker**：

```bash
# 下载官方 compose 文件
curl -sfL https://raw.githubusercontent.com/milvus-io/milvus/master/deployments/docker/standalone/docker-compose.yml \
  -o docker-compose.yml

# 启动
docker compose up -d

# 查看状态（要等 1~2 分钟）
docker compose ps
```

**或者一步到位**：

```bash
docker run -d --name milvus-standalone \
  --security-opt seccomp:unconfined \
  -e ETCD_USE_EMBED=true \
  -e ETCD_DATA_DIR=/var/lib/milvus/etcd \
  -e COMMON_STORAGETYPE=local \
  -p 19530:19530 \
  -p 9091:9091 \
  milvusdb/milvus:v2.4.0 \
  milvus run standalone
```

**验证**：

```bash
curl http://localhost:9091/healthz
# 返回 OK 就说明起来了
```

**内存要求**：至少 4 GB，推荐 8 GB。**Milvus 比较吃内存**。

## 三、连接与建模

```python
from pymilvus import (
    connections, utility, FieldSchema, CollectionSchema, DataType, Collection,
)

connections.connect(alias="default", host="localhost", port="19530")
print(utility.list_collections())        # []
```

**定义 Collection（相当于"表"）**：

```python
fields = [
    FieldSchema(name="id", dtype=DataType.INT64, is_primary=True, auto_id=True),
    FieldSchema(name="embedding", dtype=DataType.FLOAT_VECTOR, dim=1536),
    FieldSchema(name="content", dtype=DataType.VARCHAR, max_length=8000),
    FieldSchema(name="source", dtype=DataType.VARCHAR, max_length=512),
    FieldSchema(name="tenant_id", dtype=DataType.INT64),
    FieldSchema(name="created_at", dtype=DataType.INT64),
]

schema = CollectionSchema(fields, description="文档知识库")
collection = Collection(name="docs", schema=schema)
```

**三个注意点**：

1. **`VARCHAR` 必须指定 `max_length`**——忘写会报错；
2. **主键用 `auto_id=True`** 让 Milvus 生成，或者自己传入；
3. **`dim` 必须和你的 embedding 模型一致**（1536 对应 `text-embedding-3-small`）。

## 四、建索引（必须）

**Milvus 不建索引也能用，但是暴力检索**——100 万条要几秒。

```python
index_params = {
    "metric_type": "COSINE",           # 距离度量
    "index_type": "HNSW",
    "params": {"M": 16, "efConstruction": 200},
}
collection.create_index(field_name="embedding", index_params=index_params)
```

**索引类型选择**：

| 数据量 | 推荐索引 | 参数 |
|---|---|---|
| < 100 万 | HNSW | M=16, efConstruction=200 |
| 100 万 ~ 1000 万 | HNSW 或 IVF_SQ8 | nlist=4096 |
| > 1000 万 | IVF_PQ | nlist=16384, m=96 |
| 磁盘受限 | DISKANN | - |

**常见错误**：忘记 `collection.load()`。

```python
collection.load()          # 必须！否则搜不到
```

**`load()` 是把索引从磁盘加载到内存**——没 load 的 collection 查询会报错。

## 五、插入数据

```python
import numpy as np

def insert_documents(collection, docs: list[dict], embeddings: list[list[float]]):
    data = [
        [np.array(e, dtype=np.float32) for e in embeddings],      # embedding
        [d["content"][:8000] for d in docs],                      # content
        [d["source"][:512] for d in docs],                        # source
        [d.get("tenant_id", 0) for d in docs],                    # tenant_id
        [d.get("created_at", 0) for d in docs],                   # created_at
    ]
    result = collection.insert(data)
    collection.flush()                # 落盘
    return result.primary_keys
```

**两个关键点**：

**① 数据要按字段顺序组列**——Milvus 是列式插入，不是逐行插入。顺序错了会报类型错误。

**② `flush()` 要慎用**。它会强制落盘，**频繁调用会生成大量小文件**，拖慢性能。

```python
# ✅ 批量插入后 flush 一次
for batch in batches:
    collection.insert(batch_to_columns(batch))
collection.flush()

# ❌ 每批都 flush
for batch in batches:
    collection.insert(...)
    collection.flush()          # 慢且会产生碎片
```

**查询可见性**：插入后需要 `flush()` 或等待自动 flush（默认 1 秒），数据才能被搜到。

## 六、检索

```python
search_params = {
    "metric_type": "COSINE",
    "params": {"ef": 128},           # HNSW 的 ef_search
}

results = collection.search(
    data=[query_vector],
    anns_field="embedding",
    param=search_params,
    limit=10,
    output_fields=["content", "source", "tenant_id"],
)

for hits in results:
    for hit in hits:
        print(f"score={hit.score:.4f} | {hit.entity.get('source')}")
        print(hit.entity.get("content")[:100])
```

**`output_fields` 要显式声明**——否则只能拿到 id 和 score，还得二次查询。

## 七、带过滤的检索（Milvus 的强项）

```python
results = collection.search(
    data=[query_vector],
    anns_field="embedding",
    param=search_params,
    limit=10,
    expr='tenant_id == 42 and created_at > 1735689600',
    output_fields=["content", "source"],
)
```

**expr 语法**（Milvus 的过滤表达式语言）：

```python
# 等值
'tenant_id == 42'
# 范围
'created_at > 1735689600 and created_at < 1767225600'
# 集合
'category in ["tech", "finance"]'
# 字符串前缀
"source like 'docs/%'"
# 逻辑组合
'(tenant_id == 42 or tenant_id == 43) and score > 0.8'
```

**性能注意**：过滤条件最好建**标量索引**：

```python
collection.create_index("tenant_id", {"index_type": "STL_SORT"})
collection.create_index("source", {"index_type": "TRIE"})      # 字符串用 TRIE
```

## 八、分区：物理级别的隔离

**Milvus 的分区（Partition）是物理隔离**——比过滤更高效。

```python
# 按租户分区
collection.create_partition("tenant_42")
collection.create_partition("tenant_43")

# 插入到指定分区
collection.insert(data, partition_name="tenant_42")

# 只在指定分区检索
results = collection.search(
    data=[qvec], anns_field="embedding", param=search_params,
    limit=10, partition_names=["tenant_42"],
)
```

**什么时候用分区**：

```
✅ 有明显的"大类"划分（多租户、按年月）
✅ 单类数据量占比大
❌ 类别太多（> 1000 个分区会拖慢元数据）
```

**规则**：**分区的数量控制在几百个以内**。租户上万的话，用过滤字段而不是分区。

## 九、更新与删除

```python
# 删除（按条件）
collection.delete("tenant_id == 999")

# 更新 = 删除 + 插入（Milvus 不支持原地更新向量）
collection.delete(f"id in {ids_to_update}")
collection.insert(new_data)
collection.flush()
```

**Milvus 的更新本质是"标记删除 + 插入新记录"**——所以**频繁更新会导致大量墓碑记录**。

**定期做 compaction**：

```python
from pymilvus import utility
utility.compact(collection_name="docs", is_clustering=False)
```

**或者更彻底：定期重建 collection**（离线窗口做）。

## 十、其他必备操作

**统计数量**：

```python
print(collection.num_entities)         # 实体总数
```

**查索引状态**：

```python
print(collection.indexes)              # 索引列表
print(collection.has_index())          # 是否建了索引
```

**释放内存**：

```python
collection.release()                   # 从内存卸载（还能重新 load）
```

**删除 collection**：

```python
utility.drop_collection("docs")
```

## 十一、接进 LangChain

```python
from langchain_milvus import Milvus

vectorstore = Milvus(
    embedding_function=embeddings,
    collection_name="docs",
    connection_args={"host": "localhost", "port": "19530"},
    index_params={"metric_type": "COSINE", "index_type": "HNSW",
                  "params": {"M": 16, "efConstruction": 200}},
    search_params={"metric_type": "COSINE", "params": {"ef": 128}},
    auto_id=True,
    drop_old=False,
)

vectorstore.add_documents(chunks)

retriever = vectorstore.as_retriever(
    search_kwargs={
        "k": 5,
        "expr": "tenant_id == 42",       # 用表达式做过滤
    }
)
docs = retriever.invoke("退款流程是什么")
```

## 十二、几个必踩的坑

**① 忘了 `load()`。**
最常见。`collection.load()` 之后才能检索。

**② `flush()` 调太频繁。**
每次 insert 后 flush 会生成大量 segment 文件，性能急剧下降。

**③ VARCHAR 忘写 max_length。**
直接报 schema 错误。

**④ 向量维度不匹配。**
`dim=1536` 的 collection 塞 3072 维的向量会报错。

**⑤ 主键类型不一致。**
`INT64` 的主键不能用字符串，反之亦然。

**⑥ 过滤表达式用 Python 语法。**
Milvus 用 `==` 而不是 `=`，用 `and` 而不是 `&&`，字符串用双引号。

**⑦ 内存不足。**
Milvus 把索引加载到内存。100 万 × 1536 维 float32 = 6 GB，**加上索引开销要 8 GB 以上**。

**⑧ 忘了启动依赖服务。**
Standalone 模式内置了 etcd 和 MinIO，但**集群模式要单独部署**。

## 十三、小结

```python
# 最小流程
connections.connect(host="localhost", port="19530")
collection = Collection("docs", schema)
collection.create_index("embedding", {"index_type": "HNSW", ...})
collection.load()                       # 别忘了
collection.insert(data)                 # 按列组织
collection.flush()                      # 批量后一次
results = collection.search(qvec, "embedding", params, limit=10,
                            expr="tenant_id == 42",
                            output_fields=["content"])
```

五条要点：

```
1. 先确认规模——小于 100 万别用 Milvus
2. 建索引 + load，两步都不能少
3. 插入按列组织，flush 要少调
4. 过滤用表达式，分区用于物理隔离
5. 更新是"删+插"，要定期 compaction
```

**一句话：Milvus 是一个"能力很强但代价很高"的选择。** 如果你的数据量真的到了千万级以上，它的分布式能力物有所值；如果只是几十万条，**用它是在给自己找麻烦**。
