# 归一化与距离度量：为什么你的相似度算错了

> 你换了 embedding 模型，检索结果全乱了。
> 明明向量算出来了，相似度也在 0~1 之间——
> **问题出在"归一化"和"距离度量"上。**

## 一、三种距离度量

| 度量 | 公式 | 取值范围 | 关注 |
|---|---|---|---|
| **余弦相似度** | cos(a,b) = a·b / (\|a\|\|b\|) | [-1, 1] | 方向 |
| **点积** | a·b | (-∞, +∞) | 方向 + 模长 |
| **欧氏距离** | ‖a-b‖ | [0, +∞) | 位置 |

**它们的关系**：

```
如果向量已经归一化（模长 = 1）：
    余弦相似度 = 点积
    欧氏距离² = 2 - 2 × 余弦相似度
```

**所以：归一化之后，三者是等价的（单调对应）。**

**反之，没有归一化时，三者给出的排序可能不同**——这就是"结果全乱了"的原因。

## 二、为什么"没归一化"会出问题

假设两个向量：

```
a = [10, 0]     模长 10
b = [1, 0]      模长 1
c = [0.9, 0.1]  模长 ≈ 0.905
```

**用点积**：

```
a·b = 10    ← 最大
a·c = 9
```

**用余弦**：

```
cos(a,b) = 1.0
cos(a,c) = 0.994
```

两种度量下 b 和 c 的排序一致，但差距完全不同。**如果文档长度差异大（长文档的向量模长更大），点积会系统性偏向长文档**。

**这就是为什么大多数场景要用余弦相似度**——它排除了模长的影响。

## 三、哪些模型输出归一化向量

| 模型 | 是否归一化 |
|---|---|
| OpenAI `text-embedding-3-*` | **是**（默认 L2 归一化） |
| `bge-*` 系列 | 否（要手动归一化） |
| `m3e-*` | 否 |
| `sentence-transformers` | 取决于配置（`normalize_embeddings=True`） |
| Cohere embed | 是 |

**关键问题：你无法确定所有库/服务的行为一致。**

**最稳的做法：自己归一化。**

```python
import numpy as np

def l2_normalize(vec: np.ndarray) -> np.ndarray:
    norm = np.linalg.norm(vec, axis=-1, keepdims=True)
    return vec / np.maximum(norm, 1e-10)      # 避免除零

# 单个
v = l2_normalize(np.array([3.0, 4.0]))
assert abs(np.linalg.norm(v) - 1.0) < 1e-6   # [0.6, 0.8]

# 批量
M = l2_normalize(np.random.randn(100, 1536))
assert np.allclose(np.linalg.norm(M, axis=1), 1.0)
```

**`1e-10` 的防护很重要**——零向量会除以零得到 NaN。

## 四、归一化 + 余弦：标准组合

```python
class EmbeddingService:
    def __init__(self, model: str = "text-embedding-3-small", normalize: bool = True):
        self.model = model
        self.normalize = normalize

    def embed_documents(self, texts: list[str]) -> np.ndarray:
        vecs = self._call_api(texts)
        return l2_normalize(vecs) if self.normalize else vecs

    def embed_query(self, text: str) -> np.ndarray:
        return self.embed_documents([text])[0]

    def _call_api(self, texts):
        # 调模型 API，返回 np.ndarray
        ...
```

**注意：用同一个函数处理"文档"和"查询"**。如果文档归一化了但查询没有，余弦相似度就会偏。

## 五、向量库的距离配置

**向量库的距离度量必须和你的 embedding 处理方式匹配**：

```python
# Qdrant
from qdrant_client import models

vectors_config = models.VectorParams(
    size=1536,
    distance=models.Distance.COSINE,      # 余弦
    # distance=models.Distance.DOT,       # 点积
    # distance=models.Distance.EUCLID,    # 欧氏
)
```

**匹配规则**：

| 你的 embedding | 应该选 |
|---|---|
| 已归一化 | COSINE 或 DOT（等价） |
| 未归一化 | COSINE（推荐）或 EUCLID |
| 训练目标就是点积（某些模型） | DOT |

**最常见的错配**：模型训练用点积（如部分新模型），但向量库配了余弦——**效果会打折扣**。

**看模型文档确认它的训练目标**：

```
text-embedding-3-*：训练用 cosine
bge-*：训练用 cosine（需归一化）
e5-*：训练用 cosine
某些多模态模型：训练用 dot product
```

## 六、得分转换：把距离变成"人看得懂"的分数

**余弦相似度的原始值范围是 [-1, 1]**，直接展示很奇怪。转换成 [0, 1]：

```python
def cosine_to_score(cos: float) -> float:
    """线性映射到 [0, 1]"""
    return (cos + 1) / 2

# 更实用的做法：用一个"最差可接受值"做截断
def cosine_to_percent(cos: float, floor: float = 0.3) -> float:
    """把 [floor, 1] 映射到 [0, 1]，低于 floor 归零"""
    if cos <= floor:
        return 0.0
    return (cos - floor) / (1 - floor)
```

**为什么需要 floor？** 因为余弦相似度的分布**不是均匀的**：

```
完全不相关的两段文本：cos ≈ 0.1 ~ 0.3（不是 0！）
```

**如果直接展示 0.25，用户会以为"有点相关"，其实完全不相关。**

**经验阈值**（text-embedding-3-small，中文）：

| 余弦值 | 含义 |
|---|---|
| > 0.85 | 几乎相同的意思 |
| 0.7 ~ 0.85 | 高度相关 |
| 0.5 ~ 0.7 | 相关 |
| 0.3 ~ 0.5 | 弱相关 |
| < 0.3 | 基本不相关 |

**这个阈值必须在你自己的数据上校准**——不同模型、不同领域的分布差别很大。

## 七、校准阈值的方法

```python
def calibrate(eval_set, docs):
    """在标注数据上找最优阈值"""
    pos_scores, neg_scores = [], []

    for item in eval_set:
        results = vectorstore.similarity_search_with_score(item["question"], k=10)
        for d, score in results:
            if item["expected_source"] in d.metadata["source"]:
                pos_scores.append(score)
            else:
                neg_scores.append(score)

    print(f"正样本相似度：均值 {np.mean(pos_scores):.3f}，"
          f"P10 {np.percentile(pos_scores, 10):.3f}")
    print(f"负样本相似度：均值 {np.mean(neg_scores):.3f}，"
          f"P90 {np.percentile(neg_scores, 90):.3f}")

    # 最优阈值 = 正样本 P10 和负样本 P90 的交界
    threshold = (np.percentile(pos_scores, 10) + np.percentile(neg_scores, 90)) / 2
    print(f"建议阈值：{threshold:.3f}")
    return threshold
```

**用这个阈值做过滤**：

```python
def retrieve_with_threshold(query, threshold):
    results = vectorstore.similarity_search_with_score(query, k=10)
    filtered = [(d, s) for d, s in results if s >= threshold]
    if not filtered:
        return None          # 触发"检索不到"的处理
    return [d for d, _ in filtered]
```

## 八、几个坑

**① 归一化必须在"入库"和"查询"两侧都做。**
只做一侧是最常见的错误。

**② 换模型必须重建索引。**
不同模型的向量空间不通，且归一化行为可能不同。

```python
INDEX_META = {
    "model": "text-embedding-3-small",
    "normalized": True,
    "distance": "cosine",
    "built_at": "2026-10-15",
}
```

**把这份元数据存在向量库里**，启动时校验。

**③ 注意 float32 / float16 的精度。**
float16 归一化后模长可能不是精确的 1.0（约 0.999）。**用容差比较**：

```python
assert abs(np.linalg.norm(v) - 1.0) < 1e-3     # 不要用 == 1.0
```

**④ 别对"已经归一化"的模型重复归一化。**
虽然重复归一化无害（幂等），但会引入浮点误差。**确认一次就够了。**

**⑤ 零向量要处理。**
空字符串或纯符号的文本可能产生零向量（或接近零）。**归一化前要检查**：

```python
def safe_normalize(v):
    norm = np.linalg.norm(v)
    if norm < 1e-6:
        return np.zeros_like(v)          # 或抛异常
    return v / norm
```

**⑥ 不同库的"score"含义不同。**
`similarity_search_with_score` 返回的分数：

- 有些库返回"相似度"（越大越像）；
- 有些库返回"距离"（越小越像）。

**用之前一定要看文档**。FAISS 返回的是 L2 距离（越小越好），Chroma 返回的是距离，Qdrant 返回的是相似度。**搞反了会把最不相关的当成最相关。**

## 九、小结

```python
# 标准配置
vecs = l2_normalize(model.encode(texts))          # 归一化
vectorstore = Chroma(collection, embedding_function=..., 
                     collection_metadata={"hnsw:space": "cosine"})  # 余弦

# 得分转换
score = (cos + 1) / 2                             # 映射到 [0,1]
```

五条原则：

```
1. 自己归一化，不依赖库的默认行为
2. 文档和查询用同一套处理
3. 距离度量和模型的训练目标要匹配
4. 阈值必须在自己数据上校准
5. 记下索引用的模型/维度/度量，启动时校验
```

**一句话：归一化和距离度量是"向量检索的物理单位"。** 单位搞错了，所有比较都是错的——**而它引起的错误非常隐蔽，因为分数看起来"很正常"**。
