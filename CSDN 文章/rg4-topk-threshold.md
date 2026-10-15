# top_k 和相似度阈值：召回几个、卡多严

> 检索到 4 篇，其中 2 篇不相关——模型被噪声带偏。
> 改成 2 篇，结果漏掉了关键信息。
>
> **k 不是一个凭感觉设的数字。**

## 一、两个参数，两个作用

```
top_k    ：召回多少个（数量控制）
threshold：只要相似度高于多少的（质量控制）
```

**它们必须配合使用**：

| 组合 | 结果 |
|---|---|
| k 大，无阈值 | 噪声多 |
| k 小，无阈值 | 可能漏掉相关内容 |
| k 大，阈值高 | 合适 ✅ |
| k 小，阈值高 | 常常召回为空 |

**最佳实践：`k` 设大一点（给阈值和重排留余量），用 `threshold` 卡质量。**

## 二、k 该设多少

**先看"答案的分散程度"**：

```
答案集中在一个段落  → k=2~3 够
答案分散在 3~5 个段落 → k=5~8
需要综合多篇（如"总结"类问题）→ k=10~20
```

**实验方法**：

```python
def eval_k(eval_set, ks=(1, 2, 3, 5, 8, 10, 15, 20)):
    for k in ks:
        hits = 0
        for item in eval_set:
            docs = retriever.invoke(item["question"])[:k]
            if any(item["expected_keyword"] in d.page_content for d in docs):
                hits += 1
        print(f"k={k:2d}  命中率 = {hits/len(eval_set):.2%}")
```

**典型的收益曲线**：

```
k=1   58%
k=2   72%
k=3   81%
k=5   89%
k=8   93%
k=10  94%      ← 饱和点
k=15  95%
k=20  95%
```

**在饱和点取值**——再往上只是增加噪声和成本。

**大多数场景的 k 在 4~8 之间。**

## 三、有重排时，k 可以大得多

**如果后面有重排（cross-encoder），初筛的 k 可以设大**：

```
无重排：k = 4~8     （直接给模型）
有重排：k = 20~50   （重排后取 top 3~5）
```

**逻辑**：

```
初筛 k=20  →  重排  →  取 top 3  →  给模型

初筛贵在"别漏"（召回优先）
重排贵在"别错"（精度优先）
```

**这也是"两阶段检索"的核心思路。**

```python
def retrieve_with_rerank(question, k_coarse=20, k_final=3):
    # 阶段 1：粗排，k 大一些
    candidates = vectorstore.similarity_search(question, k=k_coarse)

    # 阶段 2：重排
    reranked = reranker.compress_documents(candidates, question)

    return reranked[:k_final]
```

## 四、阈值怎么定

**别用"经验值"，要用数据校准。**

```python
def calibrate_threshold(eval_set, vectorstore):
    pos_scores, neg_scores = [], []

    for item in eval_set:
        results = vectorstore.similarity_search_with_score(item["question"], k=10)
        for doc, score in results:
            (pos_scores if item["expected_id"] == doc.metadata.get("id")
             else neg_scores).append(score)

    print(f"正样本：P5={np.percentile(pos_scores,5):.3f} "
          f"P50={np.percentile(pos_scores,50):.3f}")
    print(f"负样本：P50={np.percentile(neg_scores,50):.3f} "
          f"P95={np.percentile(neg_scores,95):.3f}")

    # 阈值取"正样本 P5" —— 保证 95% 的正样本能通过
    return np.percentile(pos_scores, 5)
```

**取 P5 而不是更低**：

```
取 P1：阈值低，噪声多
取 P10：阈值高，可能漏掉边界正样本
取 P5：平衡点
```

**如果正样本 P5 < 负样本 P95**，说明**分布严重重叠**——单纯靠阈值无法区分。这时候要：

```
① 换更好的 embedding 模型
② 加混合检索
③ 加重排
④ 改分块策略
```

**调阈值解决不了根本的区分度问题。**

## 五、无条件给"保底数量"

**纯靠阈值有个风险：全部低于阈值 → 召回为空。**

```python
def retrieve_with_fallback(question, k=8, threshold=0.6, min_docs=2):
    results = vectorstore.similarity_search_with_score(question, k=k)
    filtered = [(d, s) for d, s in results if s >= threshold]

    # 保底：至少返回 min_docs 个
    if len(filtered) < min_docs:
        log.info("阈值过严，回退到 top-%d", min_docs)
        filtered = results[:min_docs]

    return [d for d, _ in filtered]
```

**但"保底"要配合"有无答案"的判断**：

```python
def answer_with_fallback(question):
    docs = retrieve_with_fallback(question)

    # 判断检索质量
    avg_score = np.mean([s for _, s in docs])
    if avg_score < LOW_QUALITY:
        return {"answer": "资料中没有找到相关内容。", "confidence": "low"}

    answer = generate(question, docs)
    return {"answer": answer, "confidence": "high" if avg_score > HIGH_QUALITY else "medium"}
```

**"检索不到就拒答"比"硬答"好得多。**

## 六、动态 k：按查询长度调整

```python
def dynamic_k(question: str) -> int:
    """问题越长、越复杂，需要越多上下文"""
    if any(w in question for w in ("总结", "综述", "都有哪些", "比较")):
        return 12                       # 需要综合多篇
    if len(question) < 15:
        return 4                        # 短问题，答案集中
    return 6
```

**这个方法在"混合了简单查询和综合查询"的场景很有效**：

```
"退款要几天？"          → k=4
"总结一下退款政策"       → k=12
```

**但要小心"分类错误"**——用关键词判断很粗糙，**更稳的做法是让 LLM 分类**（多花一次调用）。

## 七、k 与上下文长度的关系

**k 直接决定了上下文长度**：

```
k=8，每块 500 字 → 4000 字 ≈ 6000 token
k=20，每块 500 字 → 10000 字 ≈ 15000 token
```

**注意"Lost in the Middle"**——上下文越长，中间部分的注意力越弱：

```
k 大 → 上下文长 → 中间位置的内容可能被忽略
→ 不如"k 小 + 重排精准"
```

**这就是为什么要"两阶段"**：

```
粗排 k=20（宽召回）
重排后给模型 k=3~5（精准且短）
```

## 八、一个完整的检索配置

```python
from dataclasses import dataclass

@dataclass
class RetrievalConfig:
    k_coarse: int = 20            # 粗排召回数
    k_final: int = 4              # 最终给模型的数
    threshold: float = 0.6        # 相似度阈值（需校准）
    min_docs: int = 2             # 保底数量
    use_rerank: bool = True       # 是否重排

    def retrieve(self, question: str, retriever, reranker=None):
        # 1. 粗排
        results = retriever.invoke_with_score(question, k=self.k_coarse)

        # 2. 阈值过滤
        filtered = [(d, s) for d, s in results if s >= self.threshold]
        if len(filtered) < self.min_docs:
            filtered = results[:self.min_docs]

        docs = [d for d, _ in filtered]

        # 3. 重排
        if self.use_rerank and reranker:
            docs = reranker.compress_documents(docs, question)

        # 4. 截断
        return docs[:self.k_final]
```

**参数从上到下依次生效：召回 → 过滤 → 重排 → 截断。**

## 九、几个坑

**① k 太小导致"答案在但没召回"。**

这是最常见的 RAG 失效原因。**先用大 k 测上限，再逐步减小。**

**② 阈值没校准，用"经验值 0.7"。**

不同模型的分布差别很大。**必须校准。**

**③ 过滤后为空还硬答。**

```python
# ❌
docs = [d for d, s in results if s >= threshold]
if not docs:
    docs = results[:3]          # 硬取，可能全是噪声
```

**正确做法：为空时明确拒答，或者走"无检索"的兜底路径。**

**④ 忘了"k 是过滤前的还是过滤后的"。**

```python
# 语义不同！
vectorstore.similarity_search(q, k=5)                    # 返回 5 个
vectorstore.similarity_search_with_score(q, k=20)        # 20 个，过滤后可能剩 3 个
```

**统一用"先取大 k，再过滤"的模式。**

**⑤ 重排的 top_n 设得和 k 一样大。**
重排的意义就是"从多里挑少"，`top_n = k` 等于没筛。

**⑥ 不同查询用同一个 k。**
"简单查询"和"综合查询"应该用不同的 k。

## 十、小结

```python
# 推荐配置
k_coarse = 20          # 粗排（给重排留余量）
threshold = 0.6        # 必须校准，别抄
min_docs = 2           # 保底
k_final = 4            # 最终给模型的
```

五条原则：

```
1. k 用评测集测出饱和点（通常在 4~8）
2. 有重排时，粗排 k 可以放大到 20~50
3. 阈值必须在自己数据上校准（取正样本 P5）
4. 必须有"召回为空"的处理路径（拒答优于硬答）
5. 过滤前用大 k，过滤后取小 k
```

**一句话：k 管"广度"，阈值管"精度"，重排管"排序"。** 三个一起用才能既不漏掉答案，又不被噪声带偏——**单独调任何一个都不够**。
