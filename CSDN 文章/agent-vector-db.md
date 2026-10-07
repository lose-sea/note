# 向量数据库怎么选：Chroma、FAISS、Milvus 一次讲清

> 前面几篇我们把 RAG 的链路跑通了：切片 → 向量化 → 检索 → 拼接 → 生成。
> 但有个环节一直被我轻轻带过——**向量存哪儿**。
> 本篇就把这件事单独拎出来讲透：向量数据库到底在解决什么问题，
> Chroma / FAISS / Milvus 三者的差异在哪，以及你该怎么按场景选。

## 一、为什么普通数据库存不了向量

先破除一个误解：向量不是"不能"存进 MySQL，而是**存进去也没法用**。

传统数据库的索引建立在"相等"和"有序"之上。B+ 树能快速回答
`age = 25`、`price BETWEEN 10 AND 100`，本质是它知道数据在一维轴上谁左谁右。

但嵌入向量是 768 维（甚至 3072 维）的浮点数数组，我们要的查询是
**"找出和这个向量最相似的 K 个"**——这是一个**距离**问题，不是排序问题。
B+ 树面对这种查询只能全表扫描，逐条算余弦距离。

算一笔账：10 万条 768 维向量，每条算一次余弦相似度约 768 次乘加，
总共约 7.7 亿次浮点运算，再乘以 10 万条 ≈ **10^14 量级**。
单核跑到天荒地老，线上绝对不能接受。

向量数据库的核心价值就是：**用近似最近邻（ANN）索引，把 O(N) 暴力搜索降到接近 O(log N)**，
代价是放弃一点点精确率（召回率通常能做到 95%~99%），换来的却是几十到几百倍的提速。

## 二、ANN 索引：三个主流流派

选型之前必须知道它们在底层做了什么，否则看参数表只会一头雾水。

| 流派 | 代表 | 原理 | 优点 | 缺点 |
|---|---|---|---|---|
| **IVF 倒排** | IVF_FLAT、IVF_PQ | 先聚类分桶，只搜最近的几个桶 | 内存占用可控，构建快 | 需要训练，边界点易漏 |
| **图索引** | HNSW | 建多层"小世界"导航图，贪心跳跃逼近 | 查询极快，召回率高 | 内存开销大，构建慢 |
| **哈希** | LSH | 用哈希把近邻映射到同一桶 | 理论简单 | 召回率低，实际用得少 |

**HNSW 是当下事实上的默认选择**。可以理解为"给向量建了一个多层地铁网络"：
上层是快线（站点少、跨度大），下层是站站停；查询时从顶层快线快速定位到大致区域，
再逐层下钻精修。这也是为什么它查询快——跳过了绝大多数无关节点。

代价是内存。经验数字：**HNSW 的索引大小约为原始向量的 1.5~2 倍**。
100 万条 768 维 float32 向量原始数据约 3 GB，索引后可能要 5~6 GB。

## 三、三个选手逐个拆解

### 3.1 Chroma —— 五分钟跑通原型

```python
# pip install chromadb
import chromadb
from chromadb.utils import embedding_functions

client = chromadb.PersistentClient(path="./chroma_db")
ef = embedding_functions.SentenceTransformerEmbeddingFunction(
    model_name="BAAI/bge-small-zh-v1.5"
)
coll = client.get_or_create_collection("docs", embedding_function=ef)

coll.add(
    documents=["退货需要先联系客服获取工单号", "发货时效为下单后48小时内"],
    ids=["d1", "d2"],
    metadatas=[{"dept": "aftersale"}, {"dept": "logistics"}],
)

print(coll.query(query_texts=["买的东西不想要了怎么退"], n_results=2))
```

Chroma 最大的优点是**零配置**。`PersistentClient` 一行就落盘，
不需要起服务、不需要建 schema、不需要定义维度。
内置 embedding function，连模型调用都帮你封装了。

**它的定位是"开发者的 SQLite"**，不是生产级分布式数据库。
默认的单节点写并发能力有限，数据量过百万级后查询延迟会明显上升。

适合的场景：本地 demo、单元测试、个人知识库、万级以内的文档量。

### 3.2 FAISS —— 你要的是性能，不是数据库

FAISS（Facebook AI Similarity Search）严格来说**不是数据库，是一个算法库**。
它没有服务端、没有权限、没有持久化 schema，你拿到的是一个可以 `write_index()` 的文件。

```python
# pip install faiss-cpu numpy
import faiss, numpy as np

d = 768                       # 向量维度
xb = np.random.random((100000, d)).astype("float32")
xb /= np.linalg.norm(xb, axis=1, keepdims=True)   # 归一化后内积=余弦

index = faiss.IndexHNSWFlat(d, 32)   # 32 是每个节点的邻居数
index.hnsw.efConstruction = 200      # 建索引时的搜索宽度，越大越准越慢
index.add(xb)

index.hnsw.efSearch = 64             # 查询时的搜索宽度，可调
D, I = index.search(xb[:1], 5)
print("最相似的前 5 个 id:", I, "相似度:", D)
```

FAISS 的强项是**极致的性能和精细的可调性**：

- `IndexFlatIP`：暴力精确搜索，作为召回率的 ground truth 基线
- `IndexIVFFlat`：倒排 + 精确距离，需要训练，nlist 通常取 `4*sqrt(N)`
- `IndexHNSWFlat`：图索引，无需训练，贪心搜索
- `IndexIVFPQ`：倒排 + 乘积量化，**把 768 维压到 96 字节**，内存降一个数量级

```python
# 量化示例：768 维 → 96 字节/条，压缩率约 32 倍
quantizer = faiss.IndexFlatIP(d)
index_pq = faiss.IndexIVFPQ(quantizer, d, nlist=1024, m=96, nbits=8)
index_pq.train(xb)      # PQ 必须先训练
index_pq.add(xb)
```

代价：**所有运维问题都得你自己扛**。
持久化要手动 `faiss.write_index()`，增量删除要自己维护 id 映射
（FAISS 原生只支持按 id 删除，且是软删除），
元数据过滤得自己在外部再套一层字典，崩溃恢复、备份、多进程共享全都没有。

适合的场景：算法研究、离线批量建库、对延迟和内存极度敏感、
已经有一套成熟存储体系只需要补一个检索内核。

### 3.3 Milvus —— 生产级分布式

Milvus 是正经的分布式数据库：存算分离、水平扩展、支持流式写入、
有权限、有备份、有 Prometheus 监控指标。

```python
# pip install pymilvus
from pymilvus import connections, FieldSchema, CollectionSchema, Collection, DataType

connections.connect("default", host="localhost", port="19530")

fields = [
    FieldSchema(name="pk", dtype=DataType.VARCHAR, is_primary=True, max_length=64),
    FieldSchema(name="dept", dtype=DataType.VARCHAR, max_length=32),  # 标量字段，用于过滤
    FieldSchema(name="embedding", dtype=DataType.FLOAT_VECTOR, dim=768),
]
schema = CollectionSchema(fields, description="企业知识库")
coll = Collection("kb", schema)

index_params = {
    "metric_type": "COSINE",
    "index_type": "HNSW",
    "params": {"M": 16, "efConstruction": 200},
}
coll.create_index("embedding", index_params)
coll.load()          # 关键：建索引后必须 load 才能查

results = coll.search(
    data=[query_vec], anns_field="embedding",
    param={"metric_type": "COSINE", "params": {"ef": 64}},
    limit=5,
    expr="dept == 'aftersale'",        # 标量过滤表达式
    output_fields=["pk", "dept"],
)
```

Milvus 的关键优势在**工程属性**：

1. **标量 + 向量的混合过滤**（`expr`），这是 RAG 落地刚需，
   "只在这个部门的知识里搜"这类需求 Chroma 和 FAISS 都得你自己在外面拼
2. **存算分离**，查询节点和索引节点可独立扩缩容
3. **多一致性级别**：`Strong` / `Session` / `Bounded` / `Eventually`，
   可以在"刚写入能否立刻搜到"和"吞吐"之间做取舍
4. **分区（Partition）与多租户**，天然支持按业务线隔离

代价是**重**。最小部署也要 etcd + MinIO + Milvus 三件套，
`docker-compose` 起起来就是几个 G 内存。个人项目用它属于杀鸡用牛刀。

> 轻量替代：如果嫌 Milvus 重又想要服务端，可以看 **Qdrant**（Rust 写的单二进制，
> 资源占用低、过滤能力强）和 Milvus 官方的 **Milvus Lite**（pip 安装，本地文件模式）。

## 四、决策表：照着选就行

| 你的情况 | 选什么 | 理由 |
|---|---|---|
| 刚学 RAG，跑通流程 | **Chroma** | 五分钟上手，不用管运维 |
| 文档量 < 10 万，单机 | **Chroma / Qdrant** | 够用且省心 |
| 10 万 ~ 500 万，要稳定服务 | **Qdrant / Milvus 单机** | 有服务化能力，运维可控 |
| > 500 万或需要高可用 | **Milvus 集群** | 唯一能水平扩展的方案 |
| 算法调优、离线建库、极限性能 | **FAISS** | 参数最全，性能天花板最高 |
| 已经用了 Postgres | **pgvector** | 不引入新组件，数据量不大时很香 |
| 已经用了 Elasticsearch | **ES dense_vector** | 关键词 + 向量混合检索一把梭 |

补充一条**容易被忽略的经验**：
**不到百万级数据量，别急着上分布式**。很多团队一上来就 Milvus 集群，
结果 80% 的时间花在调 Kubernetes 而不是调召回率。
先用 Chroma 把效果做对，等真到了瓶颈再迁移——向量迁移的成本远低于你的想象。

## 五、三个新手必踩的坑

### 坑 1：索引建了但没 load

Milvus 里 `create_index()` 之后必须 `coll.load()` 才能查，
否则会报 `collection not loaded`。这是最高频的报错，没有之一。

### 坑 2：距离度量和归一化对不上

- 用 `COSINE` 度量时，向量是否归一化不影响结果（Milvus 内部处理）
- 用 `IP`（内积）时，**必须先归一化**，否则内积结果被模长污染
- FAISS 的 `IndexFlatIP` / `IndexFlatL2` 不做任何自动归一化，全靠你自己

建议统一：**代码里显式归一化 + 度量用余弦**，语义最直观，不容易出错。

### 坑 3：HNSW 的 efSearch 太小导致召回率暴跌

`efSearch` 默认 64，图大的时候不够用。判断方法：
拿 `IndexFlatIP` 暴力搜索的结果做基线，对比 HNSW 的召回率。
如果低于 90%，把 `efSearch` 调到 128、256 再试——**这是延迟和召回率的旋钮**。

```python
# 用暴力搜索做基线，量化 HNSW 的真实召回率
flat = faiss.IndexFlatIP(d); flat.add(xb)
_, baseline = flat.search(xq, 10)
_, hnsw_res = index.search(xq, 10)
recall = sum(len(set(a) & set(b)) for a, b in zip(baseline, hnsw_res)) / (len(xq) * 10)
print(f"HNSW 召回率: {recall:.2%}")   # 低于 90% 就调大 efSearch
```

## 六、小结

- 向量数据库的价值是**用 ANN 索引把相似度搜索从 O(N) 降到 O(log N)**
- **HNSW 是默认答案**，查询快召回高，代价是内存约 1.5~2 倍膨胀
- **Chroma = 原型验证，FAISS = 性能内核，Milvus = 生产基础设施**
- 数据量不到百万别上分布式，先把召回率做对
- 上线前一定要拿暴力搜索当基线，**量化你的召回率**，别凭感觉说"效果还行"

下一篇我们聊 Agent 的记忆机制——检索解决了"外挂知识"，
但 Agent 还需要记住"你是谁、上次聊到哪"，那是另一套完全不同的设计。
