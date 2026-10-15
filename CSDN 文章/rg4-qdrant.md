# Qdrant 上手：单机部署 + 过滤检索实战

> 想用专业向量库，又不想维护 etcd + MinIO + 消息队列？
> **Qdrant 是一个二进制文件就能跑起来的专业向量库。**

## 一、为什么推荐 Qdrant

| 特性 | Qdrant |
|---|---|
| 部署 | 单个二进制 / 一个容器 |
| 语言 | Rust（性能好，内存安全） |
| 依赖 | **无**（内置存储） |
| 客户端 | Python / JS / Go / Rust / Java |
| 本地模式 | 支持（进程内，零依赖） |
| 过滤 | 强（含全文匹配） |
| 量化 | 支持（标量 / 乘积 / 二值） |

**"零依赖"是最实际的优点**——不用为向量库单独维护一套基础设施。

## 二、三种部署方式

**① 本地模式（开发调试，零依赖）**

```python
from qdrant_client import QdrantClient

client = QdrantClient(":memory:")                    # 全内存，进程退出即失
# 或
client = QdrantClient(path="./qdrant_data")          # 落盘到本地目录
```

**本地模式适合原型开发和单元测试**——不启动任何服务。

**② Docker（单机生产）**

```bash
docker run -d --name qdrant \
  -p 6333:6333 -p 6334:6334 \
  -v $(pwd)/qdrant_storage:/qdrant/storage \
  qdrant/qdrant:v1.12.0
```

**`6333` 是 HTTP 端口，`6334` 是 gRPC 端口**（gRPC 更快，Python 客户端默认用 gRPC）。

**③ 分布式（大规模）**

Qdrant 支持分布式，但**比 Milvus 简单得多**——只需几个节点加一个共识层。

## 三、建集合

```python
from qdrant_client import QdrantClient, models

client = QdrantClient(url="http://localhost:6333")

client.create_collection(
    collection_name="docs",
    vectors_config=models.VectorParams(
        size=1536,
        distance=models.Distance.COSINE,
        on_disk=False,                     # 向量是否存磁盘
    ),
    hnsw_config=models.HnswConfigDiff(
        m=16,
        ef_construct=200,
        full_scan_threshold=10000,          # 小于此规模用暴力检索
    ),
    quantization_config=models.ScalarQuantization(
        scalar=models.ScalarQuantizationConfig(
            type=models.ScalarType.INT8,
            quantile=0.99,
            always_ram=True,
        ),
    ),
)
```

**四个可选配置**：

| 配置 | 作用 |
|---|---|
| `on_disk` | 向量存磁盘（省内存，慢一点） |
| `hnsw_config` | 索引参数 |
| `quantization_config` | 量化压缩 |
| `full_scan_threshold` | 小集合退化为暴力检索 |

**`quantization_config` 是 Qdrant 的亮点**——**INT8 量化把内存降到 1/4，召回率只掉约 1%**。

## 四、插入数据

```python
client.upsert(
    collection_name="docs",
    points=[
        models.PointStruct(
            id=i,                              # 整数或 UUID
            vector=embedding,                   # list[float]
            payload={                           # 元数据（可过滤）
                "content": chunk.page_content,
                "source": "manual.pdf",
                "tenant_id": 42,
                "created_at": 1735689600,
                "category": "refund",
            },
        )
        for i, (chunk, embedding) in enumerate(zip(chunks, embeddings))
    ],
    wait=True,                                  # 等待写入完成
)
```

**`payload` 是 Qdrant 的元数据字段**——任意 JSON，**可以被过滤和返回**。

**`wait=True` 建议开启**——否则写入是异步的，紧接着检索可能查不到。

**批量插入要分批**：

```python
BATCH = 500

for i in range(0, len(points), BATCH):
    client.upsert(collection_name="docs", points=points[i:i+BATCH], wait=True)
    print(f"{min(i+BATCH, len(points))}/{len(points)}")
```

**`upsert` 而不是 `insert`**——同一个 id 重复写入会覆盖，天然幂等。

## 五、检索

```python
hits = client.search(
    collection_name="docs",
    query_vector=query_embedding,
    limit=10,
    with_payload=True,                       # 返回 payload
    with_vectors=False,                       # 不返回向量（省带宽）
    search_params=models.SearchParams(hnsw_ef=128),
)

for h in hits:
    print(f"{h.score:.4f} | {h.payload['source']}")
    print(h.payload["content"][:120])
```

**注意 Qdrant 返回的 `score` 是相似度**（越大越像），不是距离。

## 六、过滤：Qdrant 最强的能力

**基础条件**：

```python
query_filter = models.Filter(
    must=[
        models.FieldCondition(key="tenant_id", match=models.MatchValue(value=42)),
        models.FieldCondition(key="created_at", range=models.Range(gte=1735689600)),
    ]
)
```

**`must` / `should` / `must_not`**：

```python
models.Filter(
    must=[...],          # 全部满足（AND）
    should=[...],        # 至少一个满足（OR）
    must_not=[...],      # 全部不满足（NOT）
)
```

**可用的匹配类型**：

| 类型 | 用途 | 例子 |
|---|---|---|
| `MatchValue` | 精确等值 | `tenant_id == 42` |
| `MatchAny` | 在集合中 | `category in ["a","b"]` |
| `MatchText` | **全文匹配** ⭐ | `content 含 "退款"` |
| `MatchExcept` | 不在集合中 | `status not in [...]` |
| `Range` | 数值范围 | `score >= 0.8` |

**`MatchText` 是 Qdrant 的特色**：

```python
models.FieldCondition(key="content", match=models.MatchText(text="退款流程"))
```

**它需要为字段建全文索引**：

```python
client.create_payload_index(
    collection_name="docs",
    field_name="content",
    field_schema=models.TextIndexParams(
        type=models.TextIndexType.TEXT,
        tokenizer=models.TokenizerType.MULTILINGUAL,       # 支持中文
        min_token_len=1,
        max_token_len=20,
        lowercase=True,
    ),
)
```

**`MULTILINGUAL` 分词器支持中文**——这是很多向量库不具备的。

## 七、建 payload 索引（过滤性能的关键）

**没有索引的过滤会全表扫描**：

```python
# 为常用的过滤字段建索引
client.create_payload_index("docs", "tenant_id", models.PayloadSchemaType.INTEGER)
client.create_payload_index("docs", "created_at", models.PayloadSchemaType.INTEGER)
client.create_payload_index("docs", "category", models.PayloadSchemaType.KEYWORD)
client.create_payload_index("docs", "source", models.PayloadSchemaType.KEYWORD)
```

**索引类型**：

| 类型 | 字段类型 | 用途 |
|---|---|---|
| `KEYWORD` | 字符串 | 精确匹配、集合 |
| `INTEGER` / `FLOAT` | 数值 | 范围、等值 |
| `TEXT` | 字符串 | 全文检索 |
| `BOOL` | 布尔 | 标记位 |
| `DATETIME` | 时间 | 时间范围 |

**建索引会显著降低过滤延迟**——尤其是在过滤掉大部分数据时。

## 八、混合检索（稀疏 + 稠密）

**Qdrant 1.10+ 支持命名向量**，可以同时存稠密和稀疏向量：

```python
client.create_collection(
    collection_name="hybrid",
    vectors_config={
        "dense": models.VectorParams(size=1536, distance=models.Distance.COSINE),
    },
    sparse_vectors_config={
        "sparse": models.SparseVectorParams(),
    },
)

# 插入
client.upsert("hybrid", points=[
    models.PointStruct(
        id=1,
        vector={
            "dense": dense_vec,
            "sparse": models.SparseVector(indices=[1, 5, 20], values=[0.8, 0.3, 0.5]),
        },
        payload={"content": "..."},
    )
])

# 混合检索（用 RRF 融合）
from qdrant_client.conversions.common_types import QueryResponse

results = client.query_points(
    collection_name="hybrid",
    prefetch=[
        models.Prefetch(query=dense_vec, using="dense", limit=20),
        models.Prefetch(query=models.SparseVector(indices=[...], values=[...]),
                        using="sparse", limit=20),
    ],
    query=models.FusionQuery(fusion=models.Fusion.RRF),
    limit=10,
)
```

**`Fusion.RRF`**：用 Reciprocal Rank Fusion 融合两路结果。

**这是"向量检索 + 关键词检索"的标准实现**——而且**在数据库内部完成**，不用在应用层写融合逻辑。

## 九、接进 LangChain

```python
from langchain_qdrant import QdrantVectorStore

store = QdrantVectorStore.from_documents(
    documents=chunks,
    embedding=embeddings,
    url="http://localhost:6333",
    collection_name="docs",
    distance=models.Distance.COSINE,
    hnsw_config=models.HnswConfigDiff(m=16, ef_construct=200),
    quantization_config=models.ScalarQuantization(
        scalar=models.ScalarQuantizationConfig(type=models.ScalarType.INT8, always_ram=True)
    ),
)

retriever = store.as_retriever(
    search_kwargs={
        "k": 5,
        "filter": models.Filter(
            must=[models.FieldCondition(key="tenant_id",
                                        match=models.MatchValue(value=42))]
        ),
    }
)
```

**注意**：LangChain 的 Qdrant 集成**返回的分数是 Qdrant 的 score**（余弦相似度），可以直接用来做阈值过滤。

## 十、几个坑

**① 忘了建 payload 索引。**
过滤能用，但会退化成全表扫描。**常用过滤字段一定要建索引。**

**② `wait=False` 导致"写后读"查不到。**
默认异步写入。**开发时用 `wait=True`。**

**③ 分数方向搞反。**
Qdrant 返回的是**相似度**（越大越像）。如果你按"最小分数"排序就错了。

**④ `id` 类型要统一。**
集合的 id 类型（整数还是 UUID）在建集合时就确定了，**混用会报错**。

**⑤ 本地模式的并发限制。**
`path="./data"` 模式**同一目录只能被一个进程打开**。多个进程访问会报锁冲突。

**⑥ 中文全文检索要选对分词器。**
`TokenizerType.MULTILINGUAL` 支持中文；用 `WHITESPACE` 会把整句当一个词。

**⑦ 版本兼容。**
Python 客户端和服务端版本要匹配。**升级服务端前先确认客户端支持**。

## 十一、和 pgvector 的取舍

| | Qdrant | pgvector |
|---|---|---|
| 部署 | 独立服务 | PG 扩展 |
| 过滤 | 强（含全文） | SQL（最灵活） |
| 事务 | 无 | **有** |
| 混合检索 | 内置 RRF | 要自己写 |
| 运维 | 简单 | **最简单**（复用 PG） |
| 规模 | 千万级 | 千万级 |

**判断标准**：

```
需要"向量和业务数据强一致" → pgvector
需要"高级向量功能 + 不想维护复杂组件" → Qdrant
```

## 十二、小结

```python
# 最小流程
client = QdrantClient(url="http://localhost:6333")

client.create_collection("docs",
    vectors_config=models.VectorParams(size=1536, distance=models.Distance.COSINE),
    quantization_config=models.ScalarQuantization(...))

client.create_payload_index("docs", "tenant_id", models.PayloadSchemaType.INTEGER)

client.upsert("docs", points=[...], wait=True)

hits = client.search("docs", query_vector=qvec, limit=10,
                     query_filter=models.Filter(must=[...]),
                     with_payload=True)
```

五条要点：

```
1. 本地模式适合开发，Docker 适合生产
2. INT8 量化把内存降到 1/4，召回 -1pt（强烈推荐）
3. 常用过滤字段必须建 payload 索引
4. MatchText 支持中文全文检索（少见的优点）
5. prefetch + FusionQuery.RRF 内置混合检索
```

**一句话：Qdrant 在"专业能力"和"运维简单"之间找到了很好的平衡点。** 如果你需要专用向量库的功能，又不想承担 Milvus 的运维成本，**它是当前最合适的选择**。
