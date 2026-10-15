# HyDE：用一个假答案去检索

> 用户问："这个东西退回去要几天才能拿到钱？"
> 文档里写的是："退款将在 7 个工作日内到账。"
>
> **问题和文档用的是完全不同的词**——向量检索可能匹配不上。
>
> HyDE 的思路：**先让模型编一个假答案，用假答案去检索。**

## 一、核心思想

**问题：查询和文档的"表达方式"往往不同。**

```
用户查询（口语、短、模糊）：
  "退回去要几天才能拿到钱"

文档（书面、长、具体）：
  "退款将在收到退货后 7 个工作日内原路返回到您的支付账户"
```

**"提问"和"陈述"的语义空间不完全重合**——尤其是在短查询上。

**HyDE（Hypothetical Document Embeddings）**：

```
① 让 LLM 根据问题生成一个"假想的答案文档"
② 用这个假文档的向量去检索
③ 检索到的真实文档更可能相关
```

```
查询："退回去要几天才能拿到钱"
  ↓ LLM 生成假答案
假文档："退款一般需要 5 到 10 个工作日，具体取决于支付方式。
        信用卡退款通常 7 个工作日，银行卡 5 个工作日..."
  ↓ 用假文档的向量检索
真实文档："退款将在收到退货后 7 个工作日内原路返回..."  ✅ 匹配上了
```

## 二、为什么有效

**关键在于"同质性"**：

| 对象 | 文体 | 长度 | 与文档的相似度 |
|---|---|---|---|
| 用户查询 | 疑问句 | 短 | 低 |
| **假文档** | **陈述句** | **中长** | **高** ✅ |

**假文档和真实文档在"文体、长度、用词习惯"上更接近**——所以它们的向量更容易匹配。

**这解决了两个问题**：

```
① 短查询信息量不足（"怎么退款" 只有 4 个字）
② 问句和陈述句的语义鸿沟
```

## 三、最简实现

```python
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser

HYDE_PROMPT = ChatPromptTemplate.from_template("""请根据下面的问题，写一段可能出现在技术文档里的回答。

要求：
- 用陈述句，像文档正文
- 包含可能的专业术语（即使用户没用这些词）
- 200 字左右
- 不要写"我不知道"之类的话，尽力编一个合理的答案

问题：{question}

回答：""")

hyde_chain = HYDE_PROMPT | llm | StrOutputParser()

def hyde_retrieve(question: str, vectorstore, k: int = 5):
    # 1. 生成假文档
    hypothetical = hyde_chain.invoke({"question": question})

    # 2. 用假文档检索
    docs = vectorstore.similarity_search(hypothetical, k=k)

    return docs, hypothetical
```

**注意提示词的三个要求**：

| 要求 | 为什么 |
|---|---|
| 用陈述句 | 和文档文体一致 |
| 包含专业术语 | 覆盖面更广 |
| "尽力编一个" | 避免模型说"我不知道"（那样检索不到任何东西） |

## 四、关键技巧：多生成几个

**一个假文档可能偏。生成多个然后取并集或平均向量。**

```python
def hyde_multi(question: str, vectorstore, n: int = 3, k: int = 5):
    # 生成 n 个不同角度的假文档
    prompt = ChatPromptTemplate.from_template(
        """为下面的问题写一段文档内容（第 {idx} 个版本，尽量与其他版本不同）：

问题：{question}
"""
    )
    chain = prompt | llm | StrOutputParser()

    fakes = [chain.invoke({"question": question, "idx": i}) for i in range(1, n + 1)]

    # 方式 A：分别检索后合并去重
    all_docs = {}
    for fake in fakes:
        for d in vectorstore.similarity_search(fake, k=k):
            all_docs[d.metadata["id"]] = d

    # 方式 B：平均向量后检索（更省一次检索）
    # embeddings = [embed(f) for f in fakes]
    # avg_vec = np.mean(embeddings, axis=0)
    # docs = vectorstore.similarity_search_by_vector(avg_vec, k=k)

    return list(all_docs.values())[:k]
```

**多版本能提升召回率约 3~5 个百分点**，代价是多几次 LLM 调用。

## 五、效果实测

| 方案 | recall@5 | 延迟 | 成本 |
|---|---|---|---|
| 原始查询（直接检索） | 0.72 | 50ms | 0 |
| **HyDE（1 个假文档）** | **0.81** | 800ms | +1 次 LLM |
| HyDE（3 个假文档） | 0.84 | 1.5s | +3 次 LLM |
| 查询改写（简单版） | 0.78 | 600ms | +1 次 LLM |

**HyDE 在"短查询、口语化查询"上收益最大**。

**在"已经很详细的查询"上，HyDE 收益很小甚至为负**：

```
查询："LangChain 的 RunnableWithMessageHistory 怎么在多轮会话中
      维护历史消息，需要注意哪些线程安全问题？"

→ 这个查询已经足够详细，HyDE 生成的假文档反而可能引入噪声
```

## 六、什么时候用 HyDE

**适合**：

```
✅ 查询短（< 15 字）
✅ 口语化、模糊
✅ 用户用词和文档用词差异大
✅ 向量检索效果明显不好，但分块没问题
```

**不适合**：

```
❌ 查询已经很详细
❌ 需要精确匹配（错误码、编号）→ 用混合检索
❌ 延迟敏感（HyDE 多一次 LLM 调用）
❌ 成本敏感（每次查询多一次 LLM 费用）
❌ 领域幻觉风险高（法律、医疗——假文档可能有错误信息）
```

**判断方法**：**先测一下"直接检索的召回率"**。

```
召回率 > 85%  → 不需要 HyDE
召回率 < 70%  → 试试 HyDE
```

## 七、进阶：HyDE + 混合检索

**HyDE 生成的假文档也可以用于 BM25 检索**：

```python
def hyde_hybrid(question: str, vectorstore, bm25, k: int = 10):
    hypothetical = hyde_chain.invoke({"question": question})

    # 向量路：用假文档
    vec_docs = vectorstore.similarity_search(hypothetical, k=k)

    # 关键词路：用"原查询 + 假文档"的并集分词
    tokens = list(jieba.cut_for_search(question)) + list(jieba.cut_for_search(hypothetical))
    scores = bm25.get_scores(tokens)
    bm25_docs = [chunks[i] for i in np.argsort(-scores)[:k]]

    # RRF 融合
    return rrf_fuse([vec_docs, bm25_docs])
```

**关键：关键词路用"原查询 + 假文档"**——因为假文档里的术语能补上原查询没有的词。

## 八、和"查询改写"的区别

**这两个容易混淆，其实不同**：

| | 查询改写 | HyDE |
|---|---|---|
| 输出 | **改写后的查询** | **假想的文档** |
| 文体 | 还是问句 | 陈述句 |
| 长度 | 和原查询相当 | 更长（200+ 字） |
| 目的 | 补充上下文 | 跨越"问句-陈述句"鸿沟 |
| 适合 | 多轮对话（代词消解） | 单轮短查询 |

**两者可以叠加**：

```python
def rewrite_then_hyde(question, history):
    # 1. 先改写（解决"它"、"那个"的指代）
    rewritten = rewrite(question, history)

    # 2. 再 HyDE
    return hyde_retrieve(rewritten, vectorstore)
```

## 九、和其他"查询扩展"技术的对比

| 技术 | 做法 | 收益 | 成本 |
|---|---|---|---|
| **HyDE** | 生成假文档 | +9pt | 1 次 LLM |
| **多查询** | 生成多个查询 | +5pt | 1 次 LLM |
| **查询分解** | 拆成子问题 | +7pt（复杂问题） | 1 次 LLM |
| **Step-back** | 先问抽象问题 | +6pt（推理型） | 1 次 LLM |
| **查询扩展** | 加同义词 | +3pt | 0 |

**它们可以组合**，但**每叠加一个就多一次 LLM 调用**。

**推荐的组合**：

```
简单场景：直接检索
中等：HyDE（短查询）或多查询
复杂：查询分解 + HyDE
```

## 十、几个坑

**① 假文档有幻觉，可能误导检索。**

```python
# ❌ 假文档编了一个不存在的功能
"这个 API 支持 batch_size 参数..."（实际不支持）
→ 检索到讨论 batch_size 的无关文档
```

**对策**：在提示词里加"基于常见的技术文档风格"约束，并且**只在"术语扩展"的层面使用假文档，不要相信它的事实**。

**② 假文档太长，反而稀释了语义。**

```python
# 提示词里限定长度
"200 字左右，不要超过 300 字"
```

**③ 每次都调用 LLM，成本上升。**

**优化**：

```python
def hyde_with_cache(question: str, vectorstore, cache: dict):
    if question in cache:
        hypothetical = cache[question]
    else:
        hypothetical = hyde_chain.invoke({"question": question})
        cache[question] = hypothetical
    return vectorstore.similarity_search(hypothetical, k=5)
```

**高频问题能命中缓存。**

**④ 用便宜的模型生成假文档。**
这一步不需要强推理能力，**用最便宜的模型就行**：

```python
hyde_llm = ChatOpenAI(model="gpt-4o-mini", temperature=0.3)
```

**temperature 设 0.3**——太随机会生成偏离的假文档，太确定又只有一个版本。

**⑤ 领域敏感场景慎用。**
医疗、法律场景，假文档里的错误信息可能"引导"检索到错误的文档。**这类场景更适合"查询改写"而不是 HyDE。**

**⑥ 忘了对比基线。**
**HyDE 不是万能的**——在某些数据集上它甚至会降低效果。**一定要用评测集对比。**

## 十一、完整实现

```python
class HyDERetriever:
    def __init__(self, llm, vectorstore, bm25=None, n_hypotheticals: int = 1,
                 top_k: int = 10, use_cache: bool = True):
        self.llm = llm
        self.vs = vectorstore
        self.bm25 = bm25
        self.n = n_hypotheticals
        self.k = top_k
        self.cache = {} if use_cache else None

        self.chain = ChatPromptTemplate.from_template(
            """为下面的问题写一段技术文档内容（约 200 字，陈述句，包含相关专业术语）。

问题：{question}
"""
        ) | llm | StrOutputParser()

    def _generate(self, question: str) -> list[str]:
        if self.cache is not None and question in self.cache:
            return self.cache[question]

        fakes = []
        for i in range(self.n):
            suffix = f"（第 {i+1} 个版本，尽量从不同角度写）" if self.n > 1 else ""
            fakes.append(self.chain.invoke({"question": question + suffix}))

        if self.cache is not None:
            self.cache[question] = fakes
        return fakes

    def invoke(self, question: str) -> list:
        fakes = self._generate(question)
        combined = question + " " + " ".join(fakes)

        # 向量路
        vec_docs = []
        for f in fakes:
            vec_docs.extend(self.vs.similarity_search(f, k=self.k))

        # 去重
        seen, unique = set(), []
        for d in vec_docs:
            did = d.metadata.get("id", d.page_content[:50])
            if did not in seen:
                seen.add(did)
                unique.append(d)

        # 关键词路（用原查询 + 假文档）
        if self.bm25:
            tokens = list(jieba.cut_for_search(combined))
            scores = self.bm25.get_scores(tokens)
            bm25_docs = [self.chunks[i] for i in np.argsort(-scores)[:self.k]]
            return self._rrf([unique, bm25_docs])

        return unique[:self.k]

    def _rrf(self, lists, k: int = 60):
        scores = defaultdict(float)
        doc_map = {}
        for lst in lists:
            for rank, d in enumerate(lst, 1):
                did = d.metadata.get("id")
                doc_map[did] = d
                scores[did] += 1 / (k + rank)
        top = sorted(scores.items(), key=lambda x: -x[1])[:self.k]
        return [doc_map[did] for did, _ in top]
```

## 十二、小结

```python
# 最小可用版本
hypothetical = (HYDE_PROMPT | llm | StrOutputParser()).invoke({"question": q})
docs = vectorstore.similarity_search(hypothetical, k=5)
```

五条原则：

```
1. 只在"短查询/口语化查询"上用（长查询收益小）
2. 用便宜模型生成假文档（不需要强推理）
3. 假文档限长 200~300 字（太长稀释语义）
4. 不要相信假文档的事实，只用它的"术语"
5. 必须用评测集对比——HyDE 不是万能的
```

**一句话：HyDE 解决的是"提问和文档的表达方式不同"这个根本问题。** 它的核心洞见是——**与其让模型理解"问题"，不如让模型先写出"答案"，然后用答案去找答案**。这个思路听起来绕，但在短查询场景下确实有效。

**但记住：它是"可选增强"，不是"必需组件"。** 直接检索的召回率到了 85%，就不需要它。
