# Redis 做向量检索：把缓存和向量搜索合并到一个组件

> 你的 RAG 里已经有 Redis 了（缓存、会话、限流）。
> 再加一个向量库存向量的必要性有多大？
>
> **如果你只需要"几万到几十万"级别的检索，Redis 就够了。**

## 一、Redis 向量检索的定位

**Redis 8.0 起把向量检索（RediSearch 模块）内置了**——不再需要单独装模块。

| 场景 | 适合用 Redis 吗 |
|---|---|
| 向量量 < 50 万 | ✅ 够用 |
| 需要**同时**做缓存和向量检索 | ✅ 非常合适 |
| 需要"会话 + 短期记忆"的向量检索 | ✅ 天然契合 |
| 需要复杂过滤 + 聚合 | ⚠️ 不如 ES |
| 数据量 > 500 万 | ❌ 用专用库 |
| 需要持久化保证 | ⚠️ 要看配置 |

**最适合的场景：把"会话缓存"和"短期记忆检索"放在一起。**

```
会话数据（聊天历史）+ 向量（历史摘要的嵌入）
→ 都放 Redis
→ 一次查询搞定"检索相关历史 + 取回会话状态"
```

## 二、启动带向量检索的 Redis

```bash
docker run -d --name redis-vector \
  -p 6379:6379 \
  -v $(pwd)/redis_data:/data \
  redis/redis-stack-server:latest
```

**`redis-stack-server` 自带 RediSearch**。**普通 `redis:latest` 镜像没有向量检索能力。**

**验证模块**：

```bash
docker exec -it redis-vector redis-cli MODULE LIST
# 应该能看到 search 模块
```

## 三、建索引

```python
import redis
from redis.commands.search.field import (
    VectorField, TextField, NumericField, TagField,
)
from redis.commands.search.indexDefinition import IndexDefinition, IndexType

r = redis.Redis(host="localhost", port=6379, decode_responses=False)

schema = (
    TextField("content"),
    TextField("source"),
    NumericField("tenant_id"),
    NumericField("created_at"),
    TagField("category"),
    VectorField(
        "embedding",
        "HNSW",                                  # 或 "FLAT"
        {
            "TYPE": "FLOAT32",
            "DIM": 1536,
            "DISTANCE_METRIC": "COSINE",
            "M": 16,
            "EF_CONSTRUCTION": 200,
        },
    ),
)

r.ft("idx:docs").create_index(
    schema,
    definition=IndexDefinition(prefix=["doc:"], index_type=IndexType.HASH),
)
```

**几个关键点**：

**① 索引定义在"前缀"上**
`prefix=["doc:"]` 表示所有以 `doc:` 开头的 key 都进入这个索引。

**② `FLAT` vs `HNSW`**

| 类型 | 精度 | 速度 | 内存 |
|---|---|---|---|
| `FLAT` | 100% | 慢（暴力） | 低 |
| `HNSW` | ~97% | 快 | 高 |

**< 10 万条用 FLAT**（精确且够快）；以上用 HNSW。

**③ `DIM` 必须精确匹配。**

## 四、写入向量

**必须用二进制格式存向量**：

```python
import numpy as np

def to_bytes(vec: list[float]) -> bytes:
    return np.array(vec, dtype=np.float32).tobytes()

r.hset(
    "doc:1",
    mapping={
        "content": "退款申请需要满足以下条件...",
        "source": "manual.pdf",
        "tenant_id": 42,
        "created_at": 1735689600,
        "category": "refund",
        "embedding": to_bytes(embedding),
    },
)
```

**注意**：

- **`FLOAT32` 不是 `FLOAT64`**——用 float64 会因字节数不符而报错；
- **`decode_responses=False`**——否则二进制向量会被当字符串处理，破坏数据。

**批量写入用 pipeline**：

```python
pipe = r.pipeline(transaction=False)

for i, (chunk, vec) in enumerate(zip(chunks, embeddings)):
    pipe.hset(f"doc:{i}", mapping={
        "content": chunk.page_content[:8000],
        "source": chunk.metadata["source"],
        "tenant_id": 42,
        "embedding": to_bytes(vec),
    })

pipe.execute()
```

**用 pipeline 比逐条 hset 快 10 倍以上**。

## 五、向量检索

**用 KNN 查询**：

```python
from redis.commands.search.query import Query

def search(query_vec, k=10, tenant_id=None):
    q = (
        Query(f"*=>[KNN {k} @embedding $vec AS score]")
        .sort_by("score")
        .return_fields("content", "source", "tenant_id", "score")
        .dialect(2)
    )

    params = {"vec": to_bytes(query_vec)}

    results = r.ft("idx:docs").search(q, query_params=params)

    return [
        {
            "content": d.content,
            "source": d.source,
            "score": 1 - float(d.score),        # 转成相似度
            "id": d.id,
        }
        for d in results.docs
    ]
```

**几个必须知道的点**：

**① `dialect(2)` 必须加。**
`KNN` 查询语法需要 dialect 2 才能解析。

**② Redis 返回的是"距离"不是"相似度"。**
用 `COSINE` 时，**`score = 1 - 余弦相似度`**（越小越像）。所以要 `1 - score` 转成相似度。

**③ `return_fields` 会显著减少传输量。**
**绝对不要返回 `embedding` 字段**——它会带上整个向量。

## 六、带过滤的检索

```python
def search_with_filter(query_vec, tenant_id: int, k=10):
    # 过滤条件写在 KNN 查询前面
    q = (
        Query(f"(@tenant_id:[{tenant_id} {tenant_id}])=>[KNN {k} @embedding $vec AS score]")
        .sort_by("score")
        .return_fields("content", "source", "score")
        .dialect(2)
    )
    return r.ft("idx:docs").search(q, query_params={"vec": to_bytes(query_vec)})
```

**过滤语法**：

| 类型 | 语法 |
|---|---|
| 数值等值 | `@tenant_id:[42 42]` |
| 数值范围 | `@created_at:[1735689600 +inf]` |
| Tag 精确 | `@category:{refund}` |
| Tag 多值 | `@category:{refund|return}` |
| 文本 | `@content:退款` |
| 逻辑 | `(@a:[1 1]) (@b:{x})` |

**注意**：**过滤条件写在 `=>` 前面**，`KNN` 写在后面。

## 七、混合检索（向量 + 全文）

```python
def hybrid_search(query_vec, query_text, k=10, alpha=0.7):
    # 分别查两路，然后融合
    vec_results = search(query_vec, k=k*2)
    text_results = r.ft("idx:docs").search(
        Query(f"@content:{query_text}").return_fields("content", "source").dialect(2)
    )

    # 用 RRF 融合
    scores = {}
    for rank, doc in enumerate(vec_results):
        scores[doc["id"]] = scores.get(doc["id"], 0) + alpha / (60 + rank)
    for rank, doc in enumerate(text_results.docs):
        scores[doc.id] = scores.get(doc.id, 0) + (1 - alpha) / (60 + rank)

    top = sorted(scores.items(), key=lambda x: -x[1])[:k]
    return top
```

**Redis 不内置 RRF**（不像 ES）——**要在应用层写**。这是 Redis 相比 ES 的一个劣势。

## 八、TTL：Redis 的独特能力

**Redis 可以给向量设过期时间**——这是专用向量库没有的：

```python
r.hset("session:user123:summary", mapping={"content": ..., "embedding": ...})
r.expire("session:user123:summary", 7 * 86400)      # 7 天后自动删除
```

**对"短期记忆"场景极其合适**：

```python
class SessionMemory:
    """会话记忆：只保留最近 7 天"""

    def add(self, session_id: str, text: str, ttl: int = 7 * 86400):
        key = f"mem:{session_id}:{uuid.uuid4()}"
        r.hset(key, mapping={"content": text, "embedding": to_bytes(embed(text))})
        r.expire(key, ttl)

    def search(self, session_id: str, query: str, k: int = 3):
        q = (Query(f"(@session_id:{{{session_id}}})=>[KNN {k} @embedding $vec AS score]")
             .sort_by("score").dialect(2))
        ...
```

**内存自动回收**——不用自己写清理任务。

## 九、Redis 向量检索的性能特征

| 规模 | FLAT | HNSW |
|---|---|---|
| 1 万 | < 1ms | < 1ms |
| 10 万 | 约 5ms | 约 1ms |
| 100 万 | 约 50ms | 约 3ms |
| 500 万 | 约 250ms | 约 5ms |

**数据量小的时候 FLAT 完全够用。**

**内存占用**：

```
100 万 × 1536 维 × 4 字节 = 6.1 GB（仅向量）
+ HNSW 图结构（约 10~20%）
+ 内容和其他字段
≈ 8~10 GB
```

**Redis 是全内存的**——这就是"规模上限"的来源。

## 十、接进 LangChain

```python
from langchain_redis import RedisConfig, RedisVectorStore
from langchain_openai import OpenAIEmbeddings

config = RedisConfig(
    index_name="docs",
    redis_url="redis://localhost:6379",
    distance_metric="COSINE",
    metadata_schema=[
        {"name": "tenant_id", "type": "numeric"},
        {"name": "category", "type": "tag"},
    ],
)

store = RedisVectorStore(embeddings, config=config)
store.add_documents(chunks)

retriever = store.as_retriever(search_kwargs={"k": 5})
```

**`metadata_schema` 是关键**——它声明哪些字段可以被过滤。

## 十一、几个坑

**① 向量必须转成 `FLOAT32` 的 bytes。**
用 float64、或者没转 bytes，都会出错。

**② `decode_responses=False` 是必须的。**
设成 `True` 会破坏二进制数据。

**③ 忘了 `dialect(2)`。**
KNN 查询会解析失败。

**④ 返回字段带了 embedding。**
**这是最常见的性能问题**——响应体积暴增几十倍。

```python
# ❌ 默认返回所有字段（含 embedding）
r.ft("idx:docs").search(q)

# ✅ 显式指定返回字段
q.return_fields("content", "source", "score")
```

**⑤ HNSW 的 `EF_RUNTIME` 没调。**
查询时可以动态调整：

```python
Query(f"*=>[KNN {k} @embedding $vec AS score EF_RUNTIME 128]")
```

**⑥ 忘了给 Redis 配持久化。**
默认 RDB 快照可能丢数据。**重要数据要开 AOF**：

```bash
redis-server --appendonly yes --appendfsync everysec
```

**⑦ 集群模式的索引要分片。**
Redis Cluster 下，索引定义要指定分片数，否则所有数据都在一个节点。

**⑧ 内容太长会超内存。**
Redis 存的是完整内容（不像向量库只存向量）。**长文本建议只存摘要或引用**。

## 十二、选型判断

```
你的向量量 < 50 万，且已经在用 Redis？
├─ 是 → 用 Redis 向量检索 ✅
│       （尤其适合：短期记忆、会话检索、缓存+GNN 混合场景）
└─ 否 → 用 pgvector（有 PG）或 Qdrant（没有）

需要复杂的元数据过滤和聚合？
└─ 用 ES 或 pgvector

数据量 > 500 万？
└─ 用专用向量库
```

## 十三、小结

```python
# 建索引
r.ft("idx:docs").create_index(schema, definition=IndexDefinition(prefix=["doc:"]))

# 写入
r.hset("doc:1", mapping={"content": "...", "embedding": to_bytes(vec)})

# 检索
q = (Query("*=>[KNN 10 @embedding $vec AS score]")
     .sort_by("score").return_fields("content", "source").dialect(2))
r.ft("idx:docs").search(q, query_params={"vec": to_bytes(qvec)})
```

五条要点：

```
1. 用 redis-stack-server，普通 redis 没有向量能力
2. 向量用 FLOAT32 的 bytes，decode_responses=False
3. Redis 返回的是距离，要 1-score 转相似度
4. return_fields 排除 embedding（最重要的性能优化）
5. TTL 是 Redis 的独特优势，适合短期记忆场景
```

**一句话：Redis 做向量检索的最大价值是"少一个组件"。** 如果你的向量规模不大，而且 Redis 已经在架构里，**复用它比自己引入向量库更务实**——**尤其是"会话 + 检索"耦合的场景，它的 TTL 能力是专用向量库给不了的**。
