# 上下文工程：比提示词工程更重要的事

> 提示词工程问的是"这句话该怎么说"。
> 上下文工程问的是"**该给模型看什么**"。
>
> 后者对效果的影响，往往比前者大一个数量级。

## 一、从 Prompt Engineering 到 Context Engineering

| | Prompt Engineering | Context Engineering |
|---|---|---|
| 关注对象 | 措辞 | 信息 |
| 载体 | 一句话 | 系统提示 + 历史 + 检索 + 工具 + 示例 |
| 关键能力 | 表达 | **取舍** |
| 效果天花板 | 中 | 高 |

一个真实的例子：

```
❌ 提示词写得很好，但检索到的是 3 篇不相关的文档
   → 模型只能基于不相关内容回答，或者拒答

✅ 提示词写得很朴素，但检索到了精确的 2 段内容
   → 模型直接给出正确答案
```

**信息对了，措辞可以朴素；信息错了，措辞再精妙也没用。**

## 二、上下文的六个组成部分

一次 LLM 调用的上下文，其实是六块拼起来的：

```
┌─────────────────────────────────────┐
│ ① 系统提示     角色、规则、约束       │
├─────────────────────────────────────┤
│ ② 工具定义     schema 与描述         │
├─────────────────────────────────────┤
│ ③ 长期记忆     用户偏好、历史事实     │
├─────────────────────────────────────┤
│ ④ 检索内容     知识库片段            │
├─────────────────────────────────────┤
│ ⑤ 对话历史     最近几轮              │
├─────────────────────────────────────┤
│ ⑥ 当前输入     用户这句话            │
└─────────────────────────────────────┘
```

**每一块都需要单独设计**，而且要设计它们的**装配顺序**。

## 三、① 系统提示：写"边界"而不是"愿望"

```python
# ❌ 愿望式（模型会自由发挥）
SYSTEM = """你是一个专业的、友善的、乐于助人的技术助手，
请尽可能准确、详细地回答用户的问题。"""

# ✅ 边界式（模型知道该怎么做）
SYSTEM = """你是 {product} 的技术支持助手。

【必答】
- 产品的功能用法、常见问题
- 报错信息的排查步骤

【不答】
- 价格（引导到销售）
- 与其他产品的对比（说"不便评价"）

【格式】
- 结论写在第一句
- 步骤用有序列表
- 代码用 ``` 包裹

【不确定时】
直接说"我不确定"，不要猜。不要编造 API 名称或参数。
"""
```

**关键差别**：

| 愿望式 | 边界式 |
|---|---|
| "尽可能准确" | "不确定就说不确定" |
| "友善专业" | "结论写第一句" |
| "详细回答" | 给出具体的"必答/不答"清单 |

后者**可验证**——你能检查模型有没有违反。

## 四、② 工具定义：让模型"一眼选对"

工具定义的上下文成本很高（每个 100~300 token），而且直接影响选择准确率。

**描述模板**：

```python
@tool
def search_orders(
    user_id: str,
    status: Literal["pending", "paid", "refunded"] | None = None,
    days: int = 30,
) -> str:
    """查询用户的订单列表。

    何时使用：用户问"我买了什么"、"我的订单"、"订单状态"。
    何时不用：查单个订单详情用 get_order_detail（更快）。

    Args:
        user_id: 用户 ID，格式 U + 8 位数字
        status: 订单状态。不传则返回所有状态
        days: 查询最近多少天。默认 30 天，最大 365
    """
```

四段结构：**能力 → 何时用 → 何时不用 → 参数说明**。

**"何时不用"这一段经常被忽略，但它最能减少误选。**

**精简原则**：

```
每个工具的描述控制在 3 行以内
工具总数控制在 8 个以内（超过就拆分 Agent）
枚举值写进 Literal，不写在描述里
```

## 五、③ 长期记忆：注入"最小必要"信息

```python
def build_memory_block(user_id: str, query: str) -> str:
    """只注入两类记忆：
       1. 高重要度的偏好/约束（永久）
       2. 与当前问题相关的（按需）
    """
    pinned = store.search(
        namespace=("memories", user_id),
        filter={"importance": {"$gte": 4},
                "category": {"$in": ["preference", "constraint"]}},
        limit=5,
    )
    relevant = store.search(namespace=("memories", user_id), query=query, limit=3)

    lines = []
    for m in dedupe(pinned + relevant):
        lines.append(f"- [{m.value['category']}] {m.value['content']}")

    return "【关于该用户的已知信息】\n" + "\n".join(lines) if lines else ""
```

**常见的错误是把所有记忆都注入**——50 条记忆占了 3000 token，其中 45 条和当前问题无关。

## 六、④ 检索内容：位置和格式都有讲究

**位置**：研究显示，模型对**开头和结尾**的内容注意力最强（Lost in the Middle）。

```python
def order_docs_for_context(docs: list[Document]) -> list[Document]:
    """最相关的放开头和结尾，中等相关的放中间"""
    docs = sorted(docs, key=lambda d: -d.metadata["score"])
    if len(docs) <= 2:
        return docs

    # 第 1 个放最前，第 2 个放最后，其余放中间
    out = [docs[0]]
    out.extend(docs[2:])
    out.append(docs[1])
    return out
```

**格式**：给每段内容**加来源标记**，模型更容易引用，也更容易识别"这是资料"。

```python
def format_docs(docs: list[Document]) -> str:
    parts = []
    for i, d in enumerate(docs, 1):
        src = d.metadata.get("source", "未知")
        title = d.metadata.get("title", "")
        parts.append(f"[资料 {i}] 来源：{title or src}\n{d.page_content}")
    return "\n\n---\n\n".join(parts)
```

**加上"资料 N"编号**，回答时模型会写"根据资料 2"，用户能核对。

## 七、⑤ 对话历史：分级而不是全留

```python
def build_context(history, question, docs, token_budget=8000):
    parts = []

    # 关键事实（永不压缩）
    facts = extract_pinned_facts(history)
    if facts:
        parts.append("【已确认的事实】\n" + "\n".join(f"- {f}" for f in facts))

    # 较早的对话（摘要）
    if len(history) > 8:
        parts.append("【较早的对话摘要】\n" + summarize(history[:-8]))

    # 最近几轮（原文）
    recent = history[-8:]

    return {
        "facts": facts,
        "summary": ...,
        "recent_history": recent,
        "docs": docs,
        "question": question,
    }
```

**三级结构**：事实（结构化）→ 摘要（压缩）→ 原文（保真）。

## 八、⑥ 当前输入：别只给"这一句"

用户的这句话常常省略了上下文：

```
用户："那它的价格呢"
```

**"它"是什么？** 得从历史里解析。两种做法：

**① 查询改写**（推荐）

```python
REWRITE_PROMPT = """根据对话历史，把用户的最新问题改写成独立完整的问句。

对话历史：
{history}

最新问题：{question}

只输出改写后的问题。如果问题本身已经完整，原样输出。"""

def rewrite(history, question):
    if is_standalone(question):
        return question
    return (rewrite_prompt | cheap_llm | StrOutputParser()).invoke(
        {"history": to_text(history[-4:]), "question": question}
    )
```

```
"那它的价格呢" → "LangChain 的 Pro 套餐价格是多少"
```

**改写后的问题**同时用于**检索**和**生成**——这能显著提升检索命中率。

**② 把历史一起给模型**（次优，但简单）

## 九、装配顺序很重要

同样的内容，顺序不同效果不同：

```python
messages = [
    SystemMessage(SYSTEM),                    # 1. 身份和规则
    SystemMessage(memory_block),              # 2. 用户长期记忆
    SystemMessage(facts_block),               # 3. 已确认事实
    *recent_history,                          # 4. 最近对话
    HumanMessage(context_block),              # 5. 检索内容
    HumanMessage(question),                   # 6. 当前问题
]
```

**为什么检索内容放在最后？**

- 离问题最近，注意力最强；
- 用户消息位置的内容被当作"当前关注的信息"；
- 系统消息位置的内容容易被当作"背景设定"。

**另一种有效布局**是把检索内容用 `<context>` 包起来放在用户消息里：

```python
HumanMessage(f"""<context>
{context_block}
</context>

{question}""")
```

**关键：给内容打标签**，让模型能区分"资料"和"问题"。

## 十、一套可复用的装配器

```python
class ContextBuilder:
    def __init__(self, budget: Budget):
        self.budget = budget

    def build(self, user, question, history, docs) -> list[BaseMessage]:
        # 1. 改写查询（如果依赖上下文）
        q = rewrite(history, question)

        # 2. 检索（用改写后的问题）
        if docs is None:
            docs = retriever.invoke(q)
        docs = dedupe_docs(docs)[:self.budget.max_docs]

        # 3. 分类预算
        alloc = self.budget.allocate({"history": 0.4, "retrieval": 0.6})

        # 4. 组装各部分
        msgs = [
            SystemMessage(SYSTEM),
            *self._memory(user, q),
            *self._facts(history),
            *self._recent(history, alloc["history"]),
            HumanMessage(self._context(docs, alloc["retrieval"])),
            HumanMessage(question),           # 原始问题，不是改写的
        ]

        return self.budget.fit(msgs)

    def _recent(self, history, tokens):
        trimmed = trim_messages(history, max_tokens=tokens, token_counter=count_tokens,
                                strategy="last", include_system=False, start_on="human")
        return trimmed

    def _context(self, docs, tokens):
        text = format_docs(docs)
        return f"<context>\n{truncate_by_paragraph(text, tokens * 3)}\n</context>"
```

**注意最后一行：`HumanMessage(question)` 用的是原始问题**，不是改写后的——因为用户看到的是他自己的话，回答也应该直接回应他的问题。

## 十一、怎么验证上下文的质量

上下文工程的效果可测：

**① 检索质量**

```python
def eval_retrieval(queries, ground_truth):
    hits = 0
    for q, gt in zip(queries, ground_truth):
        docs = retriever.invoke(rewrite(history, q))
        texts = [d.page_content for d in docs]
        if any(gt in t for t in texts):
            hits += 1
    return hits / len(queries)
```

**② 上下文精度**

检索 5 篇，只有 2 篇被引用 → 精度 40%，说明**多塞了 3 篇垃圾**。

```python
def context_precision(answer_with_citations, total_docs):
    return len(set(answer_with_citations)) / total_docs
```

**③ Lost in the Middle 检查**

把关键信息放在中间位置，看模型能不能找到：

```python
def test_middle_recall(docs):
    """把答案放在第 3 篇（中间），看模型能否答出"""
    docs = reorder_put_at_middle(docs, answer_idx=2)
    return ask(docs) == EXPECTED
```

**这三项指标，是上下文工程效果的量化依据。**

## 十二、小结

```
上下文 = 系统提示 + 工具 + 长期记忆 + 检索 + 历史 + 当前问题
```

六条实践：

```
1. 系统提示写"边界"（必答/不答清单），不写"愿望"
2. 工具描述加"何时不用"，控制数量在 8 个以内
3. 长期记忆只注入高价值项，不全量
4. 检索内容按相关性排序位置，加来源编号
5. 历史三级处理：事实 / 摘要 / 原文
6. 查询先改写，再检索和生成
```

**一句话总结：提示词工程的产出是一段文字，上下文工程的产出一套信息装配流程。**

后者更难，但它是可测的、可迭代的、能沉淀成基础设施的——**这正是它在工程上更有价值的原因。**
