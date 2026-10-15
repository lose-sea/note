# 向量库选型：Milvus、Qdrant、PGVector、ES 到底怎么选

> "我们用 Milvus 吧，听说性能最好。"
> 结果团队没人会运维，集群三天两头挂。
>
> **选型不是选"最强的"，是选"最匹配你团队的"。**

## 一、先破除三个误区

**❌ 误区一：性能是唯一标准**

向量库的性能差异，在 100 万条以下**基本感知不到**。真正让你痛苦的是**运维复杂度**。

**❌ 误区二：功能越多越好**

支持十种索引、二十种距离度量——**你真正会用的只有一两种**。多出来的功能是维护负担。

**❌ 误区三：一定要用"专业向量库"**

如果你的数据已经在 PostgreSQL 里，**用 pgvector 比新引入一个系统好得多**——少一个组件，少一堆运维问题。

## 二、五个主要选择

| 库 | 类型 | 特点 |
|---|---|---|
| **PGVector** | PostgreSQL 扩展 | 复用现有 PG，最省事 |
| **Qdrant** | 专用向量库（Rust） | 功能全，运维简单 |
| **Milvus** | 专用向量库（分布式） | 超大规模，最复杂 |
| **Elasticsearch** | 搜索引擎 + 向量 | 已有的 ES 直接用 |
| **Chroma** | 嵌入式 | 原型开发，零配置 |

## 三、PGVector：最实用的默认选择

**优势**：

```
✅ 复用现有的 PostgreSQL（不用新引入组件）
✅ 事务保证（向量和业务数据一致）
✅ 可以 JOIN 业务表做混合过滤
✅ 运维知识可以直接迁移
✅ 支持 HNSW 和 IVFFlat 索引
```

**劣势**：

```
❌ 超大规模（> 1 亿）性能不如专用库
❌ 索引构建较慢
❌ 不支持一些高级量化
```

**适用**：

- 数据量 < 1000 万
- 已经有 PostgreSQL
- **需要向量和业务数据在同一事务里**（这是最大的理由）
- 团队不想引入新组件

**用法**：

```sql
CREATE EXTENSION vector;

CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT,
    embedding vector(1536),
    tenant_id INT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- HNSW 索引
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200);
```

```python
from langchain_postgres import PGVector

store = PGVector(
    connection="postgresql+psycopg://user:pwd@host/db",
    collection_name="docs",
    embeddings=embeddings,
    use_jsonb=True,
)
```

**混合过滤（PGVector 最强的能力）**：

```sql
SELECT content, 1 - (embedding <=> query_vec) AS score
FROM documents
WHERE tenant_id = 42
  AND created_at > now() - interval '30 days'
ORDER BY embedding <=> query_vec
LIMIT 10;
```

**向量检索和业务过滤在同一个 SQL 里**，不用"先查向量再过滤"（那会丢结果）。

## 四、Qdrant：运维最友好的专业库

**优势**：

```
✅ Rust 写的，性能好且稳定
✅ 单二进制部署，运维极简
✅ 功能全（过滤、量化、多向量、稀疏向量）
✅ 官方 Python 客户端很好用
✅ 支持本地模式（原型开发零依赖）
```

**劣势**：

```
❌ 生态不如 ES 和 PG 广
❌ 分布式能力弱于 Milvus
```

**适用**：

- 数据量 100 万 ~ 1 亿
- 需要专业向量能力（多向量、量化）
- 团队不想花大力气运维

**用法**：

```python
from qdrant_client import QdrantClient, models

client = QdrantClient(url="http://localhost:6333")

client.create_collection(
    collection_name="docs",
    vectors_config=models.VectorParams(size=1536, distance=models.Distance.COSINE),
    hnsw_config=models.HnswConfigDiff(m=16, ef_construct=200),
    quantization_config=models.ScalarQuantization(
        scalar=models.ScalarQuantizationConfig(type=models.ScalarType.INT8, always_ram=True),
    ),
)
```

**过滤能力很强**：

```python
client.search(
    collection_name="docs",
    query_vector=qvec,
    limit=10,
    query_filter=models.Filter(
        must=[
            models.FieldCondition(key="tenant_id", match=models.MatchValue(value=42)),
            models.FieldCondition(key="created_at", range=models.Range(gte=timestamp)),
        ]
    ),
)
```

**`MatchText` 支持全文过滤**——这是很多向量库没有的：

```python
models.FieldCondition(key="content", match=models.MatchText(text="退款"))
```

## 五、Milvus：为超大规模而生

**优势**：

```
✅ 支持十亿级向量
✅ 完整的分布式架构（存算分离）
✅ 索引类型最丰富（HNSW / IVF / PQ / DiskANN / GPU）
✅ 社区活跃，企业用例多
```

**劣势**：

```
❌ 架构复杂（etcd + MinIO + 多个组件）
❌ 运维成本高（要懂 K8s）
❌ 小规模使用是"杀鸡用牛刀"
```

**适用**：

- 数据量 > 1 亿
- 有专门的 SRE 团队
- 对吞吐有极高要求

**部署方式**：

```bash
# 单机开发
docker run -d --name milvus-standalone \
  -p 19530:19530 -p 9091:9091 \
  milvusdb/milvus:latest standalone

# 生产：Milvus Operator on K8s（推荐）
```

**别在 100 万条的数据上用 Milvus**——你付出的运维成本远超获得的性能。

## 六、Elasticsearch：已有 ES 就选它

**优势**：

```
✅ 如果已经在用 ES，零新增组件
✅ 天生支持混合检索（BM25 + 向量，一次查询）
✅ 过滤、聚合能力极强
✅ 团队有 ES 运维经验
```

**劣势**：

```
❌ 向量性能不如专用库（尤其高维）
❌ 内存消耗大
❌ HNSW 参数调优空间小
```

**适用**：

- 已经在用 ES（这是唯一理由）
- **需要 BM25 + 向量的混合检索**（ES 在这点上很优雅）

**混合检索的写法**：

```json
POST /docs/_search
{
  "query": {
    "bool": {
      "should": [
        {
          "knn": {
            "field": "embedding",
            "query_vector": [0.1, 0.2, ...],
            "k": 50,
            "num_candidates": 200,
            "boost": 0.7
          }
        },
        {
          "match": {
            "content": { "query": "退款流程", "boost": 0.3 }
          }
        }
      ]
    }
  }
}
```

**一次查询同时打两路**——省去了应用层的融合逻辑。

## 七、Chroma：只适合原型

**优势**：

```
✅ 零配置，pip install 就能用
✅ 嵌入式（像 SQLite 一样）
✅ 集成 LangChain 极简
```

**劣势**：

```
❌ 生产环境的并发和持久化能力弱
❌ 缺乏高级索引
❌ 不适合多副本部署
```

**适用**：原型、Demo、单机小工具。

**别把 Chroma 用在生产上**——尤其是多副本部署时，数据不一致的问题会让你很难受。

## 八、选型决策树

```
① 你已经有 Elasticsearch 吗？
   ├─ 是 → 用 ES（零新增组件 + 混合检索）
   └─ 否 ↓

② 你在用 PostgreSQL 吗？数据量 < 1000 万？
   ├─ 是 → 用 pgvector（最省事）⭐
   └─ 否 ↓

③ 数据量是多少？
   ├─ < 10 万   → Chroma / pgvector / 本地模式
   ├─ 10 万 ~ 1 亿 → Qdrant ⭐
   └─ > 1 亿     → Milvus（准备好 SRE 团队）
```

**"已经有 X" 永远优先于 "Y 更强"**——**少一个组件，少一个故障点**。

## 九、七个必须考虑的维度

| 维度 | 问题 |
|---|---|
| **规模** | 现在多少？一年后多少？ |
| **运维** | 团队会不会运维？谁值班？ |
| **现有技术栈** | 已经有 PG / ES 吗？ |
| **过滤需求** | 需要按元数据过滤吗？复杂吗？ |
| **一致性** | 需要事务吗？需要强一致吗？ |
| **语言/框架** | 有官方客户端吗？和现有框架契合吗？ |
| **成本** | 许可、云服务、人力成本 |

**其中最容易被忽略的是"运维"**——很多团队选了 Milvus，然后发现没人会排障，最终迁移回 pgvector。

## 十、迁移成本：换库比想象中贵

**换向量库要重做**：

```
① 重新向量化（除非模型不变且导出格式兼容）→ 花钱
② 重建索引 → 花时间
③ 改写检索逻辑（API 不同）→ 花人力
④ 重新调参（索引参数不同）→ 花时间
⑤ 数据一致性校验 → 花时间
⑥ 双写/灰度切换 → 工程复杂度
```

**所以"选错"的代价很高。** 宁可多花一周做 PoC，也别仓促决定。

**PoC 要注意**：

```python
# ❌ 用 1000 条数据做 PoC —— 测不出任何东西
# ✅ 用真实的 1/10 数据量，跑真实的查询负载
```

**至少要测**：

```
□ 在真实数据量下的 P99 延迟
□ 并发 10/50/100 时的表现
□ 索引构建时间
□ 元数据过滤的性能
□ 内存占用
□ 重启恢复时间
```

## 十一、一个务实的建议

**大多数项目的最佳选择是 pgvector。**

理由：

```
1. 你的数据量大概率不到 1000 万
2. 你大概率已经在用 PostgreSQL
3. 向量和业务数据在同一事务里，能省掉大量一致性问题
4. 一个新组件的引入成本，远高于性能上的收益
```

**什么时候升级到专用库**：

```
① 单表向量超过 1000 万，且查询延迟开始超标
② 需要高级功能（多向量、稀疏向量、复杂量化）
③ 向量查询已经影响到了业务库的其他查询
```

**这是一个"用到了再换"的判断——不用提前优化。**

## 十二、小结

```
数据量 < 10 万：      Chroma / SQLite 向量扩展 / 本地文件
数据量 10 万~1000 万： pgvector（首选）或 Qdrant
数据量 1000 万~1 亿：  Qdrant / Milvus
数据量 > 1 亿：        Milvus（+ SRE 团队）
已有 ES：              ES（混合检索优雅）
```

五条原则：

```
1. 优先复用现有技术栈（少一个组件 = 少一个故障点）
2. 规模决定选型上限，运维决定选型下限
3. PoC 要用真实数据量，别用玩具数据
4. 考虑迁移成本——选错的代价很高
5. 默认选 pgvector，遇到瓶颈再换
```

**一句话：向量库选型的核心不是"性能对比表"，而是"你的团队能维护什么"。** 一个跑得快但没人会排障的库，比一个慢一点但运维熟悉的库要糟糕得多。
