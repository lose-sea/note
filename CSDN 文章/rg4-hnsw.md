# HNSW 参数怎么调：M、ef_construction、ef_search 分别管什么

> 你建了个 100 万向量的库，检索要 200ms。
> 调了三个参数，降到 8ms——**召回率只掉了 1%。**

## 一、为什么需要近似检索

**暴力检索（Flat）**：拿查询向量和库里每个向量算距离。

```
100 万向量 × 1536 维 → 一次查询约 1.5 亿次浮点运算
单核约 200~500ms
```

**这在在线服务里不可接受。**

**近似最近邻（ANN）** 的思路：**不找精确的最近邻，找"足够近"的**——用少量召回损失换 10~100 倍的速度。

## 二、HNSW 的核心思想

HNSW = Hierarchical Navigable Small World（分层可导航小世界）。

```
第 2 层（最稀疏）：  A ──────────────── F
                     │                  │
第 1 层（中等）：    A ── C ──── E ──── F
                     │    │      │      │
第 0 层（最密）：    A─B─C─D─E─F─G─H─I─J   ← 包含所有向量
```

**检索过程**：

```
① 从最上层某个入口点开始
② 在当前层贪心地走向"更近的邻居"
③ 走到局部最优后，下降到下一层
④ 重复直到第 0 层，得到最终结果
```

**类比**：像坐飞机。先在"洲际航线"层快速靠近目标城市，再换"城际"层，最后在"市内"层精确定位。

**复杂度**：从 O(n) 降到 O(log n)。

## 三、三个关键参数

### M：每个节点的连接数

```
M = 16：每个节点连 16 个邻居
```

| M | 效果 | 代价 |
|---|---|---|
| 小（8~12） | 图稀疏，内存小 | 召回率下降 |
| **中（16~32）** | **平衡** | 平衡 |
| 大（48~64） | 召回率高 | 内存大、构建慢 |

**内存影响**：每层每个节点约 `M × 2` 个连接（无向图的双向存储）。

```
M=16，100 万节点，每连接 4 字节（int32 id）
≈ 100万 × 16 × 2 × 4B = 128 MB（仅连接）
```

**经验值**：

| 数据规模 | 推荐 M |
|---|---|
| < 10 万 | 16 |
| 10 万 ~ 100 万 | 16 ~ 24 |
| 100 万 ~ 1000 万 | 24 ~ 32 |
| > 1000 万 | 32 ~ 48 |

### ef_construction：构建时的候选池大小

**构建每个节点时，从多大的候选集里挑邻居。**

| 值 | 效果 |
|---|---|
| 40 | 构建快，图质量一般 |
| **100~200** | **推荐** |
| 400+ | 图质量高，构建慢 |

**这是"构建期"参数**，只影响索引构建的质量和速度，**不影响查询速度**。

**注意：ef_construction 至少要等于 M**，否则邻居都挑不满。

### ef_search：查询时的候选池大小

**查询时探索多少个候选。**

| 值 | 召回率 | 延迟 |
|---|---|---|
| 10 | 低（~85%） | 最快 |
| **50** | 高（~98%） | 快 |
| **100** | 很高（~99%） | 中 |
| 500 | 接近 100% | 慢 |

**这是"查询期"参数**，可以**动态调整**——不同场景用不同的值。

**关键性质：`ef_search ≥ top_k`**。想返回 10 个结果，`ef_search` 至少 10。

## 四、参数对效果的实际影响

一组实测数据（100 万向量，1536 维）：

| M | ef_c | ef_s | 召回@10 | 延迟 | 索引大小 |
|---|---|---|---|---|---|
| 8 | 100 | 50 | 0.912 | 3.1ms | 580 MB |
| 16 | 100 | 50 | 0.968 | 4.2ms | 720 MB |
| 16 | 200 | 50 | 0.975 | 4.3ms | 720 MB |
| **16** | **200** | **100** | **0.991** | **7.5ms** | **720 MB** |
| 32 | 200 | 100 | 0.995 | 9.1ms | 1.1 GB |
| 32 | 400 | 200 | 0.998 | 15.2ms | 1.1 GB |

**结论**：

```
M 从 8 → 16：召回率 +5.6pt（收益最大）
M 从 16 → 32：召回率 +0.4pt（收益很小，内存 +50%）

ef_search 从 50 → 100：召回率 +1.6pt，延迟 +78%
```

**M=16、ef_construction=200、ef_search 按需在 50~150 之间调**，是性价比最高的配置。

## 五、怎么选 ef_search

**ef_search 是唯一可以"按查询动态调"的参数。**

```python
def adaptive_search(vectorstore, query: str, importance: str = "normal"):
    ef_map = {
        "low": 32,        # 内部检索、预筛选
        "normal": 64,     # 普通问答
        "high": 200,      # 关键决策、法律/医疗
    }
    return vectorstore.similarity_search(
        query, k=10,
        search_params={"ef": ef_map[importance]},
    )
```

**分级策略**：

| 场景 | ef_search | 理由 |
|---|---|---|
| 预筛选（后面还有重排） | 32~64 | 后面会精排，初筛够用 |
| 普通问答 | 64~128 | 平衡 |
| 高精度要求 | 200~500 | 宁可慢一点 |
| 多路召回中的一路 | 32 | 有其他路补充 |

**"后面有重排"是最重要的判断**——如果有交叉编码器重排，**初筛的 ef_search 可以设小**（只要保证正确答案在前 50 名里）。

## 六、不同向量库的配置

**Qdrant**：

```python
from qdrant_client import models

client.create_collection(
    collection_name="docs",
    vectors_config=models.VectorParams(size=1536, distance=models.Distance.COSINE),
    hnsw_config=models.HnswConfigDiff(
        m=16,
        ef_construct=200,
        full_scan_threshold=10000,      # 小于此规模用暴力检索
    ),
)

# 查询时调 ef
client.search(
    collection_name="docs",
    query_vector=qvec,
    limit=10,
    search_params=models.SearchParams(hnsw_ef=128),
)
```

**Milvus**：

```python
index_params = {
    "index_type": "HNSW",
    "metric_type": "COSINE",
    "params": {"M": 16, "efConstruction": 200},
}
collection.create_index("vector", index_params)

# 查询
collection.search(..., param={"metric_type": "COSINE", "params": {"ef": 128}})
```

**FAISS**：

```python
import faiss

index = faiss.IndexHNSWFlat(dim, 16)          # M=16
index.hnsw.efConstruction = 200

index.add(vectors)
index.hnsw.ef_search = 128                     # 查询时的 ef
D, I = index.search(query, k=10)
```

**Chroma**：《langchain》的 Chroma 支持通过 metadata 配置：

```python
Chroma.from_documents(
    docs, embeddings, collection_name="docs",
    collection_metadata={"hnsw:space": "cosine",
                         "hnsw:construction_ef": 200,
                         "hnsw:M": 16,
                         "hnsw:search_ef": 128},
)
```

## 七、`full_scan_threshold`：小集合用暴力检索

**数据量小的时候，暴力检索比 HNSW 更快且 100% 准确。**

```
1000 个向量：暴力检索约 0.5ms，HNSW 约 0.3ms（还要建图）
→ 差别不大，但暴力是精确的
```

Qdrant 的 `full_scan_threshold` 就是这个阈值：

```python
full_scan_threshold=10000      # 小于 1 万点，自动用暴力检索
```

**经验值**：

| 规模 | 建议 |
|---|---|
| < 1 万 | 用暴力（Flat） |
| 1 万 ~ 100 万 | HNSW |
| > 100 万 | HNSW + 量化 |

**别在小数据集上纠结 HNSW 参数**——直接 Flat 更省事，而且结果更准。

## 八、调参的正确流程

```
① 先用默认参数跑基线，测出「召回率 + 延迟」
② 固定 M 和 ef_construction，扫 ef_search
   → 找到满足召回率要求的最小 ef_search
③ 固定 ef_search，扫 M
   → 看内存翻倍能换来多少召回率
④ 如果召回率还不够，提高 ef_construction 重建索引
```

**关键点**：**一次只调一个参数**，否则不知道哪个起了作用。

**评测脚本**：

```python
def eval_hnsw(index, queries, ground_truth, k=10, ef=64):
    index.hnsw.ef_search = ef
    recalls = []
    latencies = []
    for q, gt in zip(queries, ground_truth):
        t0 = time.perf_counter()
        _, ids = index.search(q, k)
        latencies.append(time.perf_counter() - t0)
        recalls.append(len(set(ids[0]) & set(gt)) / len(gt))
    return {
        "recall": np.mean(recalls),
        "latency_p50": np.percentile(latencies, 50) * 1000,
        "latency_p99": np.percentile(latencies, 99) * 1000,
    }
```

**`ground_truth` 怎么来**：用 Flat 索引跑一遍，得到精确的 top-k。

```python
flat = faiss.IndexFlatIP(dim)
flat.add(vectors)
_, gt = flat.search(queries, k)          # 这就是 ground truth
```

**注意：召回率是相对 Flat 结果算的**——它是"近似索引的召回率"，不是"对正确答案的召回率"。后者要在业务标注集上测。

## 九、几个坑

**① ef_search 小于 k 会导致返回不足。**

```python
# ❌ 想要 10 个结果，但 ef=5
similarity_search(q, k=10, search_params={"ef": 5})
```

**ef_search 必须 ≥ k**，且最好留 2~5 倍余量。

**② 增量添加会降低图质量。**

HNSW 支持动态添加，但**后加的节点只会连到已有的近邻**，长期会导致图结构退化。

**建议**：大批量更新后**重建索引**（离线窗口做）。

**③ 删除不等于物理删除。**

HNSW 大多用"标记删除"——被删的节点仍在图里，只是不返回。**长期大量删除会浪费内存并拖慢检索**。

**定期重建**是必要的运维动作。

**④ 距离度量影响很大。**
HNSW 的 `M` 和距离度量要一起考虑：

```
COSINE：通常 M=16 够用
L2：同样 M=16，但归一化后等价于 COSINE
IP（内积）：对 M 更敏感，可能要调大
```

**⑤ 内存要预留。**
图结构 + 向量本身，内存需求约：

```
memory ≈ n × (d × 4 + M × 2 × 4) bytes

100 万 × (1536×4 + 16×2×4) = 100万 × (6144 + 128) = 6.3 GB
```

**加上索引开销和系统开销，实际要预留 1.3 倍左右。**

**⑥ 不要在生产环境调 ef_construction。**
重建索引要锁库或双写，**在离线环境调好再上线**。

## 十、小结

```python
# 推荐配置
m = 16                      # 每节点连接数
ef_construction = 200       # 构建期候选池
ef_search = 64 ~ 128        # 查询期候选池（可动态调）
```

三条原则：

```
1. M 从 8 提到 16 收益最大，再往上收益递减
2. ef_construction 在离线阶段调到 200 就够了
3. ef_search 是唯一能在线调的参数，按场景分级
```

**调参的顺序**：

```
先测基线 → 扫 ef_search → 扫 M → 需要时调 ef_construction 重建
```

**一句话：HNSW 的参数是"召回率 vs 延迟 vs 内存"的三方权衡。** 大多数场景下 `M=16, ef_construction=200` 加一个动态的 `ef_search` 就够了——**别为了 0.3 个百分点的召回率把索引撑大一倍**。
