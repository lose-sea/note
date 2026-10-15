# 向量维度怎么选：越大不一定越好

> OpenAI 的 `text-embedding-3-large` 有 3072 维，
> `text-embedding-3-small` 只有 1536 维。
>
> 是维度越高越好吗？**不一定——而且高维度有明显的代价。**

## 一、维度意味着什么

一个 d 维向量，是在 d 维空间里的一个点。**维度越高，能表达的信息越丰富，但也越"稀疏"。**

```
2 维：像在纸上画点，两个点很容易靠得很近
1536 维：像在 1536 维空间里，任意两个随机点几乎等距
```

**这就是"维度灾难"**——维度太高时，"相似度"这个概念会失效：

```
高维空间里，最近邻和最远邻的距离差趋近于 0
→ "相似"和"不相似"难以区分
```

## 二、维度的三个代价

| 代价 | 说明 | 影响 |
|---|---|---|
| **存储** | d × 4 字节/向量（float32） | 100 万 × 3072 维 = 12 GB |
| **计算** | 相似度计算量正比于 d | 检索延迟上升 |
| **精度** | 高维稀疏导致区分度下降 | 召回质量可能变差 |

**存储的账**：

```
100 万个块：
1536 维  →  100万 × 1536 × 4B = 6.1 GB
3072 维  →  100万 × 3072 × 4B = 12.3 GB
```

**成本翻倍，但效果提升往往不到 5%。**

## 三、维度与效果的真实关系

以 MTEB 榜单上的典型数据为例（同一系列模型）：

| 模型 | 维度 | 检索准确率 | 相对提升 |
|---|---|---|---|
| 3-small | 512 | 58.2% | - |
| 3-small | 1024 | 60.1% | +3.3% |
| 3-small | 1536 | **61.5%** | +5.7% |
| 3-large | 1024 | 62.8% | - |
| 3-large | 2560 | 64.5% | - |
| 3-large | 3072 | **64.6%** | +0.2% |

**规律非常明显**：

```
512 → 1536：有明显提升（+5.7%）
1536 → 3072：几乎无提升（+0.2%）
```

**收益是先快后慢的**，通常**在 1024~1536 附近就基本饱和**。

**更重要的观察**：`3-large` 的 1024 维（62.8%）**比** `3-small` 的 1536 维（61.5%）**更好**。

**结论：模型质量比维度更重要。** 与其把维度堆高，不如换个更好的模型。

## 四、Matryoshka 嵌入：维度可以截断

**新模型（如 `text-embedding-3-*`、`bge-m3`）支持"套娃嵌入"（Matryoshka Representation Learning）**：

> 训练时就把信息按重要性排列在前面的维度里——**截断前面 N 维就是一个可用的低维向量。**

```python
from langchain_openai import OpenAIEmbeddings

# 关键参数：dimensions
embeddings = OpenAIEmbeddings(
    model="text-embedding-3-large",
    dimensions=512,          # 只取前 512 维
)
```

**这意味着：你可以在不换模型的情况下，用 `dimensions` 参数平衡效果和成本。**

**实测对比**：

| dimensions | 存储 | 准确率 | 建议 |
|---|---|---|---|
| 256 | 1 GB | 59.8% | 极致省成本 |
| 512 | 2 GB | 62.1% | 成本敏感 |
| **1024** | **4 GB** | **64.0%** | **推荐** |
| 3072 | 12 GB | 64.6% | 不划算 |

**1024 维是性价比拐点**——比 3072 维省 2/3 存储，效果只差 0.6%。

## 五、怎么选：一个决策流程

```
① 你的向量库总规模是多少？
   ├─ < 10 万      → 维度不是瓶颈，用默认
   └─ > 100 万     → 开始考虑降维

② 你的模型支持 Matryoshka 吗？
   ├─ 支持 → 用 dimensions 参数降到 512~1024
   └─ 不支持 → 用 PCA 或换模型

③ 做过效果对比吗？
   └─ 没做过 → 用评测集跑一次（不同维度的 recall）
```

**一句话：先用默认维度跑基线，再用评测集验证"降维会不会掉效果"。** 大多数场景下，降到 1024 维效果不变，存储省一半。

## 六、降维的三种方式

**① `dimensions` 参数（首选）**

```python
OpenAIEmbeddings(model="text-embedding-3-small", dimensions=512)
```

**简单、免费、无损**（Matryoshka 模型天然支持）。**缺点**：只对支持的模型有效。

**② PCA 降维**

```python
from sklearn.decomposition import PCA
import numpy as np

def pca_reduce(vectors: np.ndarray, target_dim: int = 512):
    pca = PCA(n_components=target_dim, random_state=42)
    reduced = pca.fit_transform(vectors)
    print(f"解释方差比：{pca.explained_variance_ratio_.sum():.3f}")
    return reduced, pca
```

**注意：PCA 的变换矩阵必须保存下来**——查询时也要用同一个矩阵变换：

```python
query_vec = pca.transform([embed(query)])[0]
```

**③ 量化压缩（不是降维，是降精度）**

```python
# float32 → int8
def quantize(vectors: np.ndarray) -> tuple[np.ndarray, tuple]:
    mins = vectors.min(axis=0)
    maxs = vectors.max(axis=0)
    scale = (maxs - mins) / 255
    quantized = ((vectors - mins) / scale).astype(np.uint8)
    return quantized, (mins, scale)
```

**存储降 4 倍**（4 字节 → 1 字节），**精度损失约 1~2%**。这是**比降维更划算的方案**。

## 七、向量库的量化支持

大多数向量库支持内置量化：

```python
# Qdrant：标量量化
from qdrant_client import QdrantClient, models

client.create_collection(
    collection_name="docs",
    vectors_config=models.VectorParams(size=1536, distance=models.Distance.COSINE),
    quantization_config=models.ScalarQuantization(
        scalar=models.ScalarQuantizationConfig(
            type=models.ScalarType.INT8,
            quantile=0.99,
            always_ram=True,
        ),
    ),
)

# Milvus：PQ 量化
# index_type="IVF_PQ"
```

**组合策略最常见**：

```
原始向量（float32） → 用于 rerank（少量候选）
量化向量（int8）    → 用于初筛（全量检索）
```

**这就是"两阶段检索"**——先用压缩向量快速筛出 100 个候选，再用原始向量精排到 10 个。

## 八、维度对不同任务的影响

**不是所有任务对维度都敏感**：

| 任务 | 维度敏感度 | 说明 |
|---|---|---|
| 短文本检索 | 中 | 100~500 维够用 |
| 长文档检索 | 高 | 需要更多维度表达 |
| 语义去重 | 低 | 粗粒度判断 |
| 聚类 | 中 | 受维度影响但不太敏感 |
| 跨语言检索 | **很高** | 维度不足时跨语言对齐差 |

**跨语言场景要特别注意**——中英混合检索对维度的要求比单语言高得多。

## 九、实测方法

**在你自己的数据上测**，而不是看榜单：

```python
def eval_dimension(dim: int, eval_set, docs):
    embeddings = OpenAIEmbeddings(model="text-embedding-3-large", dimensions=dim)
    vs = build_index(docs, embeddings)

    hits = 0
    for item in eval_set:
        results = vs.similarity_search(item["question"], k=4)
        if any(item["expected_source"] in d.metadata["source"] for d in results):
            hits += 1
    return hits / len(eval_set)

for dim in [256, 512, 1024, 1536, 3072]:
    acc = eval_dimension(dim, EVAL_SET, docs)
    print(f"dim={dim:4d}  recall@4 = {acc:.2%}  （存储 ≈ {dim*4*len(docs)/1e9:.2f} GB）")
```

**你会得到一条"边际收益递减"的曲线**，然后在拐点处选值。

## 十、几个坑

**① 换了 embedding 模型（或维度）必须重建索引。**
不同模型的向量空间完全不通。**混用会导致检索结果完全随机**。

```python
# 记录索引用的模型和维度
INDEX_META = {"model": "text-embedding-3-small", "dim": 1536, "built_at": "..."}

def check_consistency(query_emb, index_meta):
    if query_emb.dim != index_meta["dim"]:
        raise ValueError(f"维度不一致：查询 {query_emb.dim} vs 索引 {index_meta['dim']}")
```

**② 降维后要重新归一化。**
如果用余弦相似度，降维后向量模长会变，要重新 L2 归一化。

```python
def l2_normalize(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)
```

**③ 量化后距离度量会变。**
int8 量化的向量，用余弦相似度时要注意缩放。

**④ 别在小数据集上降维。**
1 万条数据，1536 维只占 60 MB，**没有优化必要**。降维是为了规模，不是为了"看起来省"。

**⑤ 降维前先确认模型支持。**
不是所有模型都支持 Matryoshka。**bge-m3、text-embedding-3-*、jina-v3 支持**；老的 `text-embedding-ada-002` 不支持。

## 十一、小结

```
维度选择的三条规律：
① 512 → 1536 有明显提升
② 1536 → 3072 几乎无提升
③ 模型质量 > 维度数量
```

**推荐配置**：

| 场景 | 维度 | 方式 |
|---|---|---|
| 小规模（< 10 万） | 模型默认 | 不用调 |
| 中等（10~100 万） | 1024 | `dimensions` 参数 |
| 大规模（> 100 万） | 512 + int8 量化 | 组合使用 |
| 跨语言 | ≥ 1024 | 别降太多 |

**三条原则**：

```
1. 先在默认维度上跑基线
2. 用评测集验证降维的代价
3. 优先用"量化"而不是"降维"来省存储
```

**一句话：维度不是越高越好，而是"够用就好"。** 与其在维度上堆数量，不如把同样的预算花在更好的模型、更强的重排、更细的分块上——**那些地方的收益更实在**。
