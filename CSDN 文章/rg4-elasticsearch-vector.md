# Elasticsearch 做向量检索：一次查询同时打关键词和向量两路

> 你的团队已经在用 Elasticsearch——日志、搜索、聚合都在上面。
> 现在要做 RAG，**要不要再引入一个向量数据库？**
>
> 先看看 ES 能不能直接干。

## 一、ES 做向量检索的合理性

**引入新组件的代价**：

```
① 新的部署（服务器、配置、监控）
② 新的运维知识（备份、扩容、排障）
③ 数据同步（业务数据 → 向量库的一致性）
④ 新的故障点（挂了谁来查）
```

**如果你的数据已经在 ES 里，复用它能省掉以上全部。**

**ES 在 RAG 场景有一个独特优势：**BM25 和向量检索在同一个查询里完成**——不用在应用层做融合。

## 二、版本要求

**向量检索需要 ES 8.x+**（7.x 有实验性支持，不推荐）。

```bash
docker run -d --name es \
  -p 9200:9200 \
  -e "discovery.type=single-node" \
  -e "xpack.security.enabled=false" \
  -e "ES_JAVA_OPTS=-Xms4g -Xmx4g" \
  docker.elastic.co/elasticsearch/elasticsearch:8.15.0
```

**内存要给足**——ES 默认堆是 1 GB，向量检索远远不够。**至少 4 GB**。

**验证**：

```bash
curl localhost:9200
```

## 三、建索引（mapping）

```json
PUT /docs
{
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 1
  },
  "mappings": {
    "properties": {
      "content": {
        "type": "text",
        "analyzer": "ik_max_word",
        "fields": {
          "keyword": { "type": "keyword", "ignore_above": 256 }
        }
      },
      "embedding": {
        "type": "dense_vector",
        "dims": 1536,
        "index": true,
        "similarity": "cosine",
        "index_options": {
          "type": "hnsw",
          "m": 16,
          "ef_construction": 200
        }
      },
      "source": { "type": "keyword" },
      "tenant_id": { "type": "integer" },
      "created_at": { "type": "date" }
    }
  }
}
```

**四个关键点**：

**① `dense_vector` + `index: true`**
`index: true` 才会建 HNSW 索引。设为 `false` 只能做精确的 script_score 查询（慢）。

**② `similarity` 要和你的向量处理匹配**

| similarity | 说明 |
|---|---|
| `cosine` | 余弦（推荐，向量无需预先归一化） |
| `dot_product` | 点积（**要求向量已归一化**） |
| `l2_norm` | 欧氏距离 |
| `max_inner_product` | 内积 |

**③ 中文要用 IK 分词器**

需要装插件：

```bash
docker exec -it es bin/elasticsearch-plugin install \
  https://github.com/infinilabs/analysis-ik/releases/download/v8.15.0/elasticsearch-analysis-ik-8.15.0.zip
```

不装的话，中文会被按单字切分——**BM25 的效果会很差**。

**④ `m` 和 `ef_construction` 要显式设**

ES 的默认值偏保守。`m=16, ef_construction=200` 是常用配置。

## 四、写入数据

**单条**：

```json
POST /docs/_doc/1
{
  "content": "退款申请需要满足以下条件：订单在 7 天内...",
  "embedding": [0.012, -0.034, ...],
  "source": "manual.pdf",
  "tenant_id": 42,
  "created_at": "2026-01-15T10:00:00Z"
}
```

**批量（推荐）**：

```python
from elasticsearch import Elasticsearch, helpers

es = Elasticsearch("http://localhost:9200")

actions = [
    {
        "_index": "docs",
        "_id": i,
        "_source": {
            "content": chunk.page_content,
            "embedding": embedding,
            "source": chunk.metadata["source"],
            "tenant_id": 42,
            "created_at": chunk.metadata.get("created_at"),
        },
    }
    for i, (chunk, embedding) in enumerate(zip(chunks, embeddings))
]

success, errors = helpers.bulk(es, actions, chunk_size=500)
print(f"成功 {success} 条，失败 {len(errors)} 条")
```

**`helpers.bulk` 比逐条 `index` 快几十倍。**

**注意向量必须是**：`list[float]`，长度必须等于 `dims`。

## 五、纯向量检索（kNN）

```python
response = es.search(
    index="docs",
    knn={
        "field": "embedding",
        "query_vector": query_embedding,
        "k": 10,
        "num_candidates": 100,          # 候选池，越大越准越慢
    },
    size=10,
    source=["content", "source", "tenant_id"],
)

for hit in response["hits"]["hits"]:
    print(f"{hit['_score']:.4f} | {hit['_source']['source']}")
    print(hit["_source"]["content"][:120])
```

**`num_candidates` 是最重要的调参项**：

| num_candidates | 召回率 | 延迟 |
|---|---|---|
| 10 | 低 | 最快 |
| **100** | **高** | **快** |
| 500 | 很高 | 中 |
| 5000 | 接近精确 | 慢 |

**经验**：`num_candidates = 10 × k` 起步，按召回率调。

## 六、混合检索（ES 的杀手锏）

**一次查询同时打两路**：

```python
response = es.search(
    index="docs",
    query={
        "bool": {
            "should": [
                {"match": {"content": {"query": "退款流程", "boost": 0.3}}},
            ],
            "filter": [
                {"term": {"tenant_id": 42}},
                {"range": {"created_at": {"gte": "now-30d"}}},
            ],
        }
    },
    knn={
        "field": "embedding",
        "query_vector": query_embedding,
        "k": 20,
        "num_candidates": 200,
        "boost": 0.7,
        "filter": [
            {"term": {"tenant_id": 42}},
            {"range": {"created_at": {"gte": "now-30d"}}},
        ],
    },
    size=10,
)
```

**`boost` 控制两路的权重**：

```
query.boost = 0.3        # 关键词权重
knn.boost = 0.7          # 向量权重
```

**`filter` 在两路都要写**——否则过滤只作用于其中一路。

**分数融合**：ES 会把两路的分数**加权求和**。所以 `score = 0.7 × 向量分 + 0.3 × BM25 分`。

**注意**：两路的分数尺度不同（BM25 可能是 0~20，余弦是 0~1），**需要归一化**。ES 会对 BM25 做归一化，但**建议自己验证排序是否符合预期**。

## 七、RRF 融合（更好的方式）

**ES 8.8+ 支持 RRF（Reciprocal Rank Fusion）**——基于"排名"而不是"分数"融合，**避免了分数尺度问题**：

```python
response = es.search(
    index="docs",
    retriever={
        "rrf": {
            "retrievers": [
                {"standard": {"query": {"match": {"content": "退款流程"}}}},
                {"knn": {"field": "embedding", "query_vector": qvec,
                         "k": 20, "num_candidates": 200}},
            ],
            "rank_window_size": 50,
            "rank_constant": 60,
        }
    },
    size=10,
)
```

**RRF 的原理**：

```
score(doc) = Σ 1 / (rank_constant + rank_in_list)

例：某文档在 BM25 里排第 2，在 kNN 里排第 5
score = 1/(60+2) + 1/(60+5) = 0.0161 + 0.0154 = 0.0315
```

**优势**：不需要调权重，对分数尺度不敏感，**鲁棒性更好**。

**推荐用 RRF 而不是手动 boost**——除非你有明确的理由相信某一路更准。

## 八、接进 LangChain

```python
from langchain_elasticsearch import ElasticsearchStore

store = ElasticsearchStore(
    es_url="http://localhost:9200",
    index_name="docs",
    embedding=embeddings,
    distance_strategy="COSINE",
)

store.add_documents(chunks)

retriever = store.as_retriever(
    search_kwargs={
        "k": 5,
        "filter": [{"term": {"tenant_id": 42}}],
    }
)
```

**LangChain 的 ES 集成支持两种检索模式**：

```python
# 纯向量
store = ElasticsearchStore(..., strategy=ElasticsearchStore.ApproxRetrievalStrategy())

# 混合（向量 + BM25）
store = ElasticsearchStore(
    ...,
    strategy=ElasticsearchStore.ApproxRetrievalStrategy(
        hybrid=True,
        rrf={"rank_constant": 60, "window_size": 50},
    ),
)
```

## 九、性能优化

**① `num_candidates` 要合理**

太小丢召回，太大拖慢。**从 100 起步**。

**② 减少返回字段**

```python
source=["content", "source"]        # 不要返回 embedding！
```

**返回 embedding 会让响应体积暴增几十倍。**

**③ 用 `filter` 而不是 `must`**

```python
# ✅ filter：不参与打分，可缓存
{"filter": [{"term": {"tenant_id": 42}}]}

# ❌ must：参与打分，慢
{"must": [{"term": {"tenant_id": 42}}]}
```

**`filter` 的结果会被缓存**（filter cache），重复查询极快。

**④ 分片数要合理**

```
建议：每分片 10~50 GB 数据
100 GB 数据 → 3~10 个分片
```

**分片太多会拖慢查询**（每个分片都要协调）。

**⑤ 向量不要存副本太多**

```
number_of_replicas = 1 即可
向量占空间大，多副本成本高
```

## 十、ES 做向量检索的局限

| 局限 | 说明 |
|---|---|
| 内存消耗 | 向量索引全在堆内，1 亿向量要 TB 级内存 |
| 量化能力弱 | 没有 PQ/SQ 等高级量化（8.15 后有限支持） |
| 高维性能 | 1536 维以上性能下降明显 |
| 索引构建 | 大索引的重建时间长 |

**判断标准**：

```
数据量 < 500 万，且已经在用 ES → 用 ES ✅
数据量 > 500 万 → 考虑专用向量库
需要高级量化 → 专用向量库
```

## 十一、几个坑

**① `dims` 必须精确匹配。**
1536 维的字段塞 1537 个数字会直接报错。

**② `dot_product` 要求向量归一化。**
不归一化时结果会偏向模长大的向量。

**③ 中文分词器没装。**
BM25 部分会退化成"按字匹配"，效果很差。**装 IK 插件**。

**④ `num_candidates` 默认太小。**
ES 的默认值是 `max(k, 50)`——对高召回要求不够。**显式设成 100 以上**。

**⑤ 忘了设 `index: true`。**
`dense_vector` 默认 `index: false`，**只能做 script_score 查询（很慢）**。

**⑥ `size` 和 `k` 的区别。**

```
knn.k = 20          → 向量检索召回 20 个
size = 10           → 最终返回 10 个
```

**`k` 应该 ≥ `size`**，给融合和重排留余量。

**⑦ 更新向量要重建整个文档。**
ES 不支持部分更新 `dense_vector`——要么整个文档 reindex，要么用 `_update` 全量替换字段。

## 十二、小结

```python
# 混合检索（推荐用 RRF）
es.search(
    index="docs",
    retriever={
        "rrf": {
            "retrievers": [
                {"standard": {"query": {"match": {"content": q}}}},
                {"knn": {"field": "embedding", "query_vector": vec,
                         "k": 20, "num_candidates": 200}},
            ]
        }
    },
    size=10,
)
```

五条要点：

```
1. ES 8.x + dense_vector + index:true + HNSW
2. 中文必须装 IK 分词器（BM25 效果的关键）
3. 混合检索用 RRF，别手动调权重
4. num_candidates ≥ 100，filter 用 filter 不用 must
5. 返回字段里绝对不要带 embedding
```

**一句话：ES 做向量检索的价值不在"性能最强"，而在"复用已有基础设施 + 原生混合检索"。** 已有 ES 的团队，**先用它把 RAG 跑起来，遇到瓶颈再换专用库**——这是最务实的路径。
