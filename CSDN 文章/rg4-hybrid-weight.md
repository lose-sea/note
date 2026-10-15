# 混合检索的权重怎么定：向量和关键词各占多少

> 向量检索懂语义但不懂精确词，关键词检索懂精确词但不懂语义。
> 混合起来效果最好——**但"各占 50%"是拍脑袋的决定。**

## 一、两路的互补性

| 查询 | 向量 | 关键词 | 谁赢 |
|---|---|---|---|
| "退款要多久到账" | ✅ 懂"到账"≈"到账时间" | 一般 | 向量 |
| "ERR_0x80070057" | ❌ 不懂错误码 | ✅ 精确匹配 | 关键词 |
| "身份证号 110101..." | ❌ 数字无语义 | ✅ | 关键词 |
| "怎么把钱退回来" | ✅ 语义相近 | ❌ 没有"退款"二字 | 向量 |
| "API v2 的鉴权方式" | 一般 | ✅ "v2"是精确词 | 关键词 |

**规律**：

```
自然语言提问       → 向量强
含专有名词/编号/代码 → 关键词强
```

## 二、权重不是"各占 50%"

**默认 50/50 在大多数场景都不是最优。** 实测数据：

| 权重（向量:关键词） | recall@5 |
|---|---|
| 1.0 : 0.0（纯向量） | 0.72 |
| 0.8 : 0.2 | 0.81 |
| **0.7 : 0.3** | **0.86** ⭐ |
| 0.6 : 0.4 | 0.85 |
| 0.5 : 0.5 | 0.83 |
| 0.3 : 0.7 | 0.77 |
| 0.0 : 1.0（纯关键词） | 0.58 |

**峰值在 0.7:0.3 附近。**

**为什么偏向向量**：

```
① 用户提问大多是自然语言
② 现代 embedding 已经很强
③ BM25 对"同义词"完全无能
```

**但完全不要关键词（1.0:0.0）也明显更差**——那 30% 补上了精确匹配的短板。

## 三、融合的两种方式

**① 加权求和（Weighted Sum）**

```python
def weighted_fusion(vector_results, bm25_results, alpha=0.7):
    scores = {}
    for doc_id, score in vector_results:
        scores[doc_id] = scores.get(doc_id, 0) + alpha * score
    for doc_id, score in bm25_results:
        scores[doc_id] = scores.get(doc_id, 0) + (1 - alpha) * score
    return sorted(scores.items(), key=lambda x: -x[1])
```

**问题**：**两路的分数尺度不同**。

```
向量相似度：0 ~ 1
BM25 分数：0 ~ 30（受文档长度、词频影响）
```

**直接相加，BM25 会主导一切**（30 远远大于 1）。

**必须归一化**：

```python
def normalize_scores(results):
    """min-max 归一化到 [0, 1]"""
    if not results:
        return []
    scores = [s for _, s in results]
    lo, hi = min(scores), max(scores)
    if hi == lo:
        return [(d, 1.0) for d, _ in results]
    return [(d, (s - lo) / (hi - lo)) for d, s in results]
```

**归一化的副作用**：它会把"全部都不相关"的查询也归一化到 [0, 1]——**第一名变成 1.0，即使它其实很不相关**。

**改进：保留原始分数量级信息**：

```python
def softmax_normalize(results, temperature=1.0):
    scores = np.array([s for _, s in results])
    exp = np.exp(scores / temperature)
    probs = exp / exp.sum()
    return [(d, p) for (d, _), p in zip(results, probs)]
```

**② RRF（Reciprocal Rank Fusion）** ⭐

**基于排名而不是分数融合**——彻底避开尺度问题：

```python
def rrf_fusion(lists, k=60, weights=None):
    """lists: [[doc_id, ...], ...] 每路的排序结果"""
    scores = defaultdict(float)
    weights = weights or [1.0] * len(lists)

    for lst, w in zip(lists, weights):
        for rank, doc_id in enumerate(lst, start=1):
            scores[doc_id] += w / (k + rank)

    return sorted(scores.items(), key=lambda x: -x[1])
```

**原理**：

```
某文档在向量路排第 2，在关键词路排第 5
score = 1/(60+2) + 1/(60+5) = 0.0161 + 0.0154 = 0.0315
```

**RRF 的三个优点**：

| 优点 | 说明 |
|---|---|
| **无需归一化** | 只用排名 |
| **无需调权重** | 或用权重做简单加权 |
| **鲁棒** | 对单路的分数异常不敏感 |

**缺点**：丢失了"分数差距"信息。

```
向量路：0.95、0.94、0.93（都很相关）
→ RRF 眼里它们只是 rank 1、2、3，差距消失了
```

**实践建议：**

```
数据量小、两路质量相当 → RRF
需要精细控制权重     → 归一化后加权求和
不确定              → 先试 RRF（几乎不用调参）
```

## 四、LangChain 里的实现

**`EnsembleRetriever`**：

```python
from langchain.retrievers import EnsembleRetriever, BM25Retriever

bm25 = BM25Retriever.from_documents(chunks, k=10)
vector = vectorstore.as_retriever(search_kwargs={"k": 10})

hybrid = EnsembleRetriever(
    retrievers=[vector, bm25],
    weights=[0.7, 0.3],           # 对应顺序
)
```

**注意顺序**：`weights` 和 `retrievers` 一一对应。**写反了会得到完全相反的效果。**

**它的内部实现是 RRF**（不是加权求和）——**所以 `weights` 是"加权 RRF"的权重**。

**自定义 RRF**（更可控）：

```python
from langchain_core.retrievers import BaseRetriever
from langchain_core.documents import Document

class RRFFusionRetriever(BaseRetriever):
    retrievers: list
    weights: list[float]
    k: int = 60
    top_n: int = 5

    def _get_relevant_documents(self, query, *, run_manager=None):
        all_docs = {}
        scores = {}

        for retriever, w in zip(self.retrievers, self.weights):
            docs = retriever.invoke(query)
            for rank, doc in enumerate(docs, start=1):
                did = doc.metadata["id"]
                all_docs[did] = doc
                scores[did] = scores.get(did, 0) + w / (self.k + rank)

        top = sorted(scores.items(), key=lambda x: -x[1])[:self.top_n]
        return [all_docs[did] for did, _ in top]
```

## 五、权重怎么调

**网格搜索**：

```python
def tune_weights(eval_set, bm25, vector, weights_grid=None):
    weights_grid = weights_grid or [0.0, 0.2, 0.4, 0.5, 0.6, 0.7, 0.8, 1.0]
    results = []

    for w in weights_grid:
        retriever = EnsembleRetriever(
            retrievers=[vector, bm25],
            weights=[w, 1 - w],
        )
        hits = 0
        for item in eval_set:
            docs = retriever.invoke(item["question"])
            if any(item["expected_keyword"] in d.page_content for d in docs):
                hits += 1
        acc = hits / len(eval_set)
        results.append((w, acc))
        print(f"向量权重 {w:.1f}: recall = {acc:.2%}")

    best = max(results, key=lambda x: x[1])
    print(f"\n最优权重：向量 {best[0]:.1f} / 关键词 {1-best[0]:.1f}")
    return best[0]
```

**调完你会得到一个"倒 U 形"曲线**——两端都差，中间有个峰值。

## 六、按查询类型动态调权重

**不同类型的查询，最优权重不同。**

```python
import re

def dynamic_weight(question: str) -> float:
    """返回向量检索的权重"""
    # 含错误码、编号、代码标识符 → 偏关键词
    if re.search(r"[A-Z_]{3,}|\d{4,}|0x[0-9a-fA-F]+", question):
        return 0.4

    # 含版本号、型号
    if re.search(r"[vV]\d+(\.\d+)?", question):
        return 0.5

    # 含引号（用户明示"精确匹配这个词"）
    if '"' in question or '"' in question or "「" in question:
        return 0.45

    # 短问题（< 10 字）→ 偏关键词（信息少，向量优势不明显）
    if len(question) < 10:
        return 0.55

    # 默认
    return 0.7
```

**更可靠的做法：用小模型分类**

```python
class QueryType(BaseModel):
    has_precise_terms: bool = Field(description="查询里是否含专有名词/编号/代码/版本号")
    is_natural_language: bool = Field(description="是否像自然语言提问")

def classify_and_weight(question: str) -> float:
    result = classifier.invoke(f"分析这个查询：{question}")
    if result.has_precise_terms and not result.is_natural_language:
        return 0.35
    if result.is_natural_language and not result.has_precise_terms:
        return 0.8
    return 0.6
```

**多花一次小模型调用的成本，换来更准的权重。**

## 七、BM25 的参数

**BM25 本身也有两个参数**：

```python
from rank_bm25 import BM25Okapi

bm25 = BM25Okapi(corpus, k1=1.5, b=0.75)
```

| 参数 | 含义 | 建议 |
|---|---|---|
| `k1` | 词频饱和度 | 1.2 ~ 2.0 |
| `b` | 长度归一化强度 | 0.5 ~ 0.8 |

**`b` 的含义**：

```
b = 0   → 完全不做长度归一化（长文档占优）
b = 1   → 完全归一化（短文档占优）
b = 0.75 → 默认，平衡
```

**中文要分词**：

```python
import jieba

corpus = [list(jieba.cut(d.page_content)) for d in chunks]
bm25 = BM25Okapi(corpus)
```

**不分词的话，BM25 会把整句话当一个"词"，完全失效。**

## 八、几个坑

**① 两路的分数量纲不同，直接加权会失真。**

**用 RRF，或者先归一化。**

**② `EnsembleRetriever` 的 weights 顺序和 retrievers 顺序必须对应。**

```python
# ❌ 反了
EnsembleRetriever(retrievers=[bm25, vector], weights=[0.7, 0.3])

# ✅
EnsembleRetriever(retrievers=[vector, bm25], weights=[0.7, 0.3])
```

**③ 两路各取 k 个，最终结果可能超过 k 个。**

```python
# 两路各取 5 个 → 融合后最多 10 个（去重后更少）
```

**要显式截断到最终的 k。**

**④ BM25 需要全量语料构建索引。**
不能像向量库那样"增量插入"——**语料变了要重建 BM25 索引**。

**内存影响**：BM25 需要把所有文本的**分词结果**放在内存里。

**⑤ 中文没分词。**
最常见的 BM25 失效原因。

**⑥ 权重在错误的数据上调。**
评测集要覆盖"自然语言查询"和"精确词查询"两类，**否则调出的权重会偏**。

## 九、一个完整实现

```python
class HybridRetriever:
    def __init__(self, vectorstore, chunks, alpha: float = 0.7, k: int = 20):
        self.vectorstore = vectorstore
        self.alpha = alpha
        self.k = k

        # BM25 索引（中文分词）
        corpus = [list(jieba.cut(c.page_content)) for c in chunks]
        self.bm25 = BM25Okapi(corpus)
        self.chunks = chunks

    def invoke(self, query: str, top_n: int = 5):
        # 1. 向量路
        vec_docs = self.vectorstore.similarity_search(query, k=self.k)

        # 2. 关键词路
        tokens = list(jieba.cut(query))
        bm25_scores = self.bm25.get_scores(tokens)
        top_idx = np.argsort(-bm25_scores)[:self.k]
        bm25_docs = [self.chunks[i] for i in top_idx]

        # 3. RRF 融合
        scores = defaultdict(float)
        doc_map = {}
        for lst, w in ((vec_docs, self.alpha), (bm25_docs, 1 - self.alpha)):
            for rank, d in enumerate(lst, 1):
                did = d.metadata["id"]
                doc_map[did] = d
                scores[did] += w / (60 + rank)

        top = sorted(scores.items(), key=lambda x: -x[1])[:top_n]
        return [doc_map[did] for did, _ in top]
```

## 十、小结

```python
# 推荐起点
weights = [0.7, 0.3]          # 向量 : 关键词
fusion = "rrf"                 # 用 RRF，不用加权求和
k_per_path = 10~20             # 每路召回数
```

五条原则：

```
1. 默认 0.7 : 0.3，不是 50:50
2. 优先用 RRF（免归一化，免调参）
3. 用网格搜索 + 评测集确定权重
4. 按查询类型动态调（含代码/编号的偏关键词）
5. 中文 BM25 必须分词
```

**一句话：混合检索的收益（+10~15pt）主要来自"互补"，而不是"权重调到极致"。** 先把两路都跑通，用 RRF 融合，**权重在 0.6~0.8 之间差别不大**——**别在权重上过度优化**。
