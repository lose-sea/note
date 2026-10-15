# IVF 与 PQ 量化：把亿级向量的检索成本压下来

> 1 亿个 1536 维向量：
> 光存储就要 **614 GB**（float32），内存放不下，全放 SSD 又太慢。
>
> IVF + PQ 能把存储压到 **1/10 以下**，检索还能保持毫秒级。

## 一、先算清楚"亿级"意味着什么

```
1 亿向量 × 1536 维 × 4 字节 = 614 GB（原始 float32）
```

**内存装不下**（一般服务器 64~256 GB），必须走 SSD。但 SSD 的随机读延迟是内存的 100 倍。

**需要的是"压缩"**——把向量变小，变得能放进内存。

## 二、IVF：倒排索引

**核心思想：先把向量聚类成若干个"桶"，检索时只扫最近的几个桶。**

```
① 训练阶段：用 k-means 把空间分成 nlist 个簇
   ┌───────┬───────┬───────┐
   │ 簇 1  │ 簇 2  │ 簇 3  │
   │ ····  │ ····  │ ····  │
   └───────┴───────┴───────┘

② 入库：每个向量归到最近的簇

③ 检索：先找 query 最近的 nprobe 个簇，只在这些簇里搜
```

**nlist**：簇的数量。经验值是 `sqrt(N)`：

| 数据量 | nlist |
|---|---|
| 10 万 | 约 316 |
| 100 万 | 约 1000 |
| 1000 万 | 约 4096 |
| 1 亿 | 约 16384 |

**nprobe**：检索时扫多少个簇。

| nprobe | 召回率 | 速度 |
|---|---|---|
| 1 | 低（~50%） | 最快 |
| **8~32** | **高（~95%）** | 快 |
| 128 | 很高 | 慢 |
| = nlist | 100%（退化为暴力） | 最慢 |

**IVF 本身的压缩效果有限**——它主要是**减少扫描量**，不减少存储。压缩要靠 PQ。

## 三、PQ：乘积量化

**核心思想：把一个 d 维向量切成 m 段，每段用一个"码本编号"表示。**

```
原始向量（1536 维 float32）：1536 × 4 = 6144 字节
  ↓ 切成 96 段，每段 16 维
  ↓ 每段用 8 位编码（对应 256 个码本中心）
压缩后：96 字节
压缩比：64 倍
```

**过程**：

```
① 把 1536 维切成 96 个子空间（每段 16 维）
② 对每个子空间做 k-means（256 个中心）
③ 每个向量的一段，用最近的中心的编号（0~255）表示
④ 最终：96 个字节的编码
```

**检索时**：距离计算用**查表法**——预先算好查询向量到 256 个中心的距离表，然后查表累加。

```python
# 伪代码
def pq_distance(query, code):
    # distance_table[i][c] = query 在第 i 段到第 c 个中心的距离
    dist = 0
    for i, c in enumerate(code):
        dist += distance_table[i][c]
    return dist
```

**这就是 PQ 快的秘诀**——**把浮点运算变成了整数查表**。

## 四、IVF-PQ 的组合

```
① 用 IVF 缩小搜索范围（只扫 nprobe 个簇）
② 用 PQ 压缩存储（每向量 96 字节而非 6144 字节）
③ 用查表加速距离计算
```

**效果**：

| 指标 | Flat | IVF-PQ |
|---|---|---|
| 存储（1 亿） | 614 GB | **9.6 GB** |
| 单次检索 | ~30 s | **~15 ms** |
| 召回率@10 | 100% | 92~96% |

**64 倍压缩 + 2000 倍加速，代价是 4~8 个百分点的召回。**

## 五、参数怎么设

**三个关键参数**：

| 参数 | 含义 | 经验值 |
|---|---|---|
| `nlist` | 簇数量 | `4 × sqrt(N)` |
| `m` | 子空间数量 | 维度的 1/8 ~ 1/4 |
| `nbits` | 每子空间的位数 | 8（对应 256 个中心） |

**`m` 的取舍**：

```
m 大 → 每段维度少 → 量化误差小 → 召回率高，但存储大
m 小 → 每段维度多 → 量化误差大 → 召回率低，但存储小

1536 维：
  m=48  → 每段 32 维，编码 48 字节，压缩 128 倍
  m=96  → 每段 16 维，编码 96 字节，压缩 64 倍  ← 常用
  m=192 → 每段 8 维，编码 192 字节，压缩 32 倍
```

**经验规则**：**每个子空间 8~16 维比较合适**。

**Milvus 配置**：

```python
index_params = {
    "index_type": "IVF_PQ",
    "metric_type": "COSINE",
    "params": {
        "nlist": 4096,
        "m": 96,              # 子空间数
        "nbits": 8,           # 每段 8 位
    },
}
collection.create_index("vector", index_params)

# 查询
collection.search(..., param={"params": {"nprobe": 32}})
```

**FAISS 配置**：

```python
import faiss

# 1536 维，切成 96 段（每段 16 维），8 位编码
quantizer = faiss.IndexFlatL2(1536)
index = faiss.IndexIVFPQ(quantizer, 1536, 4096, 96, 8)

# 训练（必须先训练）
index.train(training_vectors)      # 至少 39 × nlist 个向量
index.add(vectors)

# 查询
index.nprobe = 32
D, I = index.search(queries, k=10)
```

**"必须先训练"是 IVF 系索引的特点**——需要足够的数据来学习簇中心和码本。

## 六、训练数据的量

**IVF-PQ 需要训练，训练数据不足会导致质量差。**

**经验规则**：

```
训练样本数 ≥ 39 × nlist        （FAISS 官方建议）
或 ≥ 256 × m                   （每个子空间至少 256 个样本）
```

**举例**：`nlist=4096, m=96`

```
39 × 4096 = 159,744
256 × 96 = 24,576
→ 取最大值：至少 16 万条训练样本
```

**如果数据量不够**：

```python
# 方案 1：减小 nlist
nlist = max(64, int(len(vectors) / 39))

# 方案 2：用 Python 层再做一次 PQ
index = faiss.IndexIVFPQ(quantizer, dim, nlist, m, nbits)
```

**数据量少于 10 万时，别用 IVF-PQ**——用 HNSW 或 Flat 更好。

## 七、更好的选择：HNSW + PQ

**纯 IVF-PQ 的召回率损失较大**。更优的组合是 **HNSW + SQ（标量量化）** 或 **HNSW + PQ**：

| 组合 | 召回率 | 延迟 | 内存 | 适用 |
|---|---|---|---|---|
| Flat | 100% | 极慢 | 100% | 小规模 |
| HNSW | 98% | 快 | 110% | 中等规模 |
| **HNSW + SQ8** | **97%** | **快** | **35%** | **大中规模** ⭐ |
| IVF-PQ | 93% | 快 | 6% | 超大规模 |
| HNSW + PQ | 95% | 中 | 20% | 大规模 |

**Qdrant 的标量量化配置**：

```python
from qdrant_client import models

client.create_collection(
    collection_name="docs",
    vectors_config=models.VectorParams(size=1536, distance=models.Distance.COSINE,
                                       on_disk=False),
    quantization_config=models.ScalarQuantization(
        scalar=models.ScalarQuantizationConfig(
            type=models.ScalarType.INT8,
            quantile=0.99,
            always_ram=True,
        ),
    ),
)
```

**SQ8 的优势**：把 float32 压成 int8，**内存降到 1/4，召回率只掉 1 个百分点**。

**这是"性价比最高"的量化方案**——除非你的规模真的到了亿级。

## 八、两阶段检索：精度和速度兼得

**最实用的架构**：

```
① 粗排（量化索引）：从 1 亿条里快速筛出 100~1000 个候选
② 精排（原始向量或重排模型）：对这 1000 个精确计算
```

```python
def two_stage_search(query, quantized_index, raw_vectors, k=10, candidates=500):
    # 阶段 1：量化索引快速召回
    _, coarse_ids = quantized_index.search(query, candidates)

    # 阶段 2：用原始向量精确重算
    raw = raw_vectors[coarse_ids[0]]
    scores = cosine_similarity(query, raw)

    # 取 top-k
    order = np.argsort(-scores)[:k]
    return coarse_ids[0][order], scores[order]
```

**这个架构在 Milvus / Qdrant 里是内置的**：

```python
# Qdrant：自动做两阶段（量化初筛 + 原始重算）
# 只需保证 always_ram=True 或设置 rescore
search_params=models.SearchParams(
    quantization=models.QuantizationSearchParams(rescore=True, oversampling=2.0)
)
```

**`rescore=True`** 表示"用原始向量重新算分"，**`oversampling=2.0`** 表示"多召回一倍候选再重排"。

**这是质量损失最小的量化用法。**

## 九、几个坑

**① 忘记训练。**
IVF 系索引必须先 `train()`。直接 `add()` 会报错。

**② nprobe 太小。**
`nprobe=1` 时召回率可能只有 50%。**从 16 起步，按需调大。**

**③ 训练数据和实际数据分布不一致。**
如果训练用的是通用语料、实际是垂直领域，码本会不匹配，量化误差大。**用实际数据训练。**

**④ 训练数据太少。**
少于 39 × nlist 会导致某些簇没有中心，检索时漏结果。

**⑤ 距离度量选错。**
PQ 量化时用 L2 距离，**但向量如果没归一化，L2 和余弦不等价**。要先归一化。

**⑥ 量化后不能做"精确的相似度判断"。**
PQ 的距离是近似值。**如果业务需要"相似度 > 0.9 才算命中"，必须用原始向量重算。**

**⑦ 内存没省下来。**
如果设了 `always_ram=True` 但实际只在磁盘上，**每次检索都要读磁盘**，比不量化还慢。要理解"压缩"和"常驻内存"是两件事。

## 十、选型决策树

```
向量总数是多少？
├─ < 10 万
│   └─ Flat（暴力）或 HNSW，别折腾量化
├─ 10 万 ~ 100 万
│   └─ HNSW，内存够就上，不够加 SQ8
├─ 100 万 ~ 1000 万
│   └─ HNSW + SQ8（内存 1/4，召回 97%）
│       或 IVF-PQ（内存 1/10，召回 93%）
└─ > 1000 万
    └─ IVF-PQ + 两阶段检索（rescore）
        或 HNSW + PQ
        或 分片（sharding）
```

**一句话：先看规模，再看内存预算，最后看召回率要求。**

## 十一、小结

```python
# 亿级规模的标准配置
index_params = {
    "index_type": "IVF_PQ",
    "params": {"nlist": 16384, "m": 96, "nbits": 8},
}
search_params = {"nprobe": 32}          # 按召回率调

# 更推荐的组合（中小规模）
量化 = ScalarQuantization(INT8)          # 内存 1/4，召回 -1pt
重排 = rescore=True, oversampling=2.0    # 用原始向量重算
```

五条原则：

```
1. 先算清存储量，再决定要不要量化
2. IVF-PQ 需要训练数据（≥ 39 × nlist）
3. SQ8 是性价比最高的量化（内存 1/4，召回 -1pt）
4. 一定要用两阶段检索（量化粗排 + 原始精排）
5. 别在小数据集上用 IVF-PQ
```

**一句话：量化的本质是"用少量精度换大量空间"。** 而最聪明的用法是**"粗排用压缩、精排用原始"**——**既不牺牲最终精度，又能把成本降下来**。
