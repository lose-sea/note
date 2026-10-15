# Runnable 组合模式清单：Parallel、Passthrough、Lambda、Branch 各管什么

> LCEL 的 `|` 只能表达"串行"。
> 一旦遇到"同时做两件事"、"原样传递"、"按条件走不同分支"，
> 就需要这五个组件：`Parallel`、`Passthrough`、`Lambda`、`Branch`、`Assign`。

## 一、一张速查表

| 组件 | 作用 | 一句话记忆 |
|---|---|---|
| `RunnableParallel` | 并行执行多个分支 | "同时算几件事" |
| `RunnablePassthrough` | 原样传递输入 | "什么都不改" |
| `RunnableLambda` | 包装普通函数 | "把函数变成 Runnable" |
| `RunnableBranch` | 条件选择分支 | "if/else" |
| `RunnableAssign` | 把并行结果合并进输入 | "在输入上打补丁" |

它们的共同点：**都是 `Runnable`，都能用 `|` 连接**。这就是 LCEL 的普适性——万物皆 Runnable。

## 二、RunnableParallel：同时干几件事

最典型的场景：**一次检索，多种处理**。

```python
from langchain_core.runnables import RunnableParallel, RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser

vector_search = retriever | format_docs
keyword_search = bm25_retriever | format_docs

parallel = RunnableParallel(
    vector_docs=vector_search,
    keyword_docs=keyword_search,
    question=RunnablePassthrough(),        # 原样保留问题
)

result = parallel.invoke("如何配置超时？")
# {"vector_docs": "...", "keyword_docs": "...", "question": "如何配置超时？"}
```

**关键点：所有分支收到的是同一个输入。**

如果分支需要不同的输入，就别用 Parallel，改用 Lambda 手工拆：

```python
RunnableLambda(lambda x: {
    "a": do_a(x["query"]),
    "b": do_b(x["doc_id"]),
})
```

`RunnableParallel` 也支持字典简写：

```python
# 这两种等价
RunnableParallel(a=chain_a, b=chain_b)
{
    "a": chain_a,
    "b": chain_b,
} | RunnableLambda(lambda x: x)      # 不推荐，可读性差
```

**推荐显式写 `RunnableParallel`**，意图更清晰。

## 三、RunnablePassthrough：什么都不做，但很重要

最常见的用法：**保留原输入**。

```python
chain = (
    RunnableParallel(
        context=retriever | format_docs,
        question=RunnablePassthrough(),          # 把输入原样放进 question
    )
    | prompt
    | llm
    | StrOutputParser()
)
```

没有 `RunnablePassthrough`，`RunnableParallel` 里就没法保留原始输入——**因为每个分支都要对输入做点什么**。

两种形态：

```python
RunnablePassthrough()                          # 原样返回输入
RunnablePassthrough.assign(extra=some_chain)   # 原样返回 + 增加字段
```

`assign` 其实等价于 `RunnableAssign`：

```python
RunnablePassthrough.assign(
    summary=summary_chain,
    keywords=keyword_chain,
)
| prompt
```

这行做的是：**把输入的字典原样留着，再加上 `summary` 和 `keywords` 两个键**。

## 四、`RunnablePassthrough.assign`：最实用的组合技巧

RAG 链里最常见的写法：

```python
chain = (
    RunnablePassthrough.assign(
        context=retriever | format_docs,       # 加一个 context 键
    )
    | prompt
    | llm
    | StrOutputParser()
)
```

输入 `{"question": "..."}` → 变成 `{"question": "...", "context": "..."}` → 喂给 prompt。

**语义非常清楚：在原始输入上，附加检索到的上下文。**

对比手写 Lambda：

```python
RunnableLambda(lambda x: {**x, "context": format_docs(retriever.invoke(x["question"]))})
```

**能用 `assign` 就别写 Lambda**——`assign` 支持并行、支持流式、支持回调追踪；手写 Lambda 里做的事对框架是黑盒。

## 五、RunnableLambda：逃生舱

当内置组件表达不了时，用 Lambda 包一个函数：

```python
from langchain_core.runnables import RunnableLambda

def normalize(text: str) -> str:
    return " ".join(text.split()).strip()

chain = RunnableLambda(normalize) | prompt | llm
```

**注意输入输出的形状**：

```python
# 输入是上一个 Runnable 的输出
#   上一个输出是 str → 函数接收 str
#   上一个输出是 dict → 函数接收 dict
# 输出可以是任意类型，但下游要能接住
```

常见错误是**链的中间类型对不上**：

```python
# ❌ 上一个输出是 dict，这里却按 str 处理
RunnableLambda(lambda x: x.upper())

# ✅ 正确
RunnableLambda(lambda x: x["text"].upper())
```

**用 `RunnableLambda` 的 `name` 参数给调试加便利**：

```python
RunnableLambda(normalize, name="normalize_whitespace")
```

LangSmith 里的 trace 会直接显示这个名字，比 `lambda` 友好太多。

## 六、RunnableBranch：if / elif / else

```python
from langchain_core.runnables import RunnableBranch

branch = RunnableBranch(
    (lambda x: x["type"] == "code", code_chain),        # if
    (lambda x: x["length"] > 2000, summary_chain),      # elif
    default_chain,                                       # else
)
```

规则：

1. 参数是 `(条件函数, 分支链)` 的元组列表；
2. **最后一个参数不是元组**，是兜底分支；
3. **所有分支的输入和输出类型必须一致**，否则合并后下游会炸。

如果条件是"值匹配"而不是"函数判断"，用 `RunnableBranch` 有点重，直接 `RunnableLambda` 分派更简单：

```python
RunnableLambda(lambda x: {"a": chain_a, "b": chain_b}[x["kind"]].invoke(x))
```

但这样会失去流式支持。**能用 Branch 就用 Branch。**

## 七、把几个组合起来：一个完整的 RAG 链

```python
from langchain_core.runnables import (
    RunnableParallel, RunnablePassthrough, RunnableLambda, RunnableBranch,
)

# 1. 并行检索 + 查询改写
retrieval = RunnableParallel(
    original=RunnablePassthrough(),
    rewritten=rewrite_chain,
)

# 2. 按有没有检索到结果分岔
answer_chain = RunnableBranch(
    (lambda x: not x["context"].strip(), refuse_chain),     # 没检索到 → 拒答
    RunnablePassthrough.assign(
        answer=RunnableLambda(lambda x: generate(x)) ,
    ),
)

chain = (
    RunnablePassthrough.assign(context=retrieval | merge_docs)
    | answer_chain
    | RunnableLambda(lambda x: x["answer"])
)
```

这个链的结构很清晰：

```
输入 → 并行(原样 + 改写) → 合并检索结果 → 判断有无结果 → 拒答 / 生成 → 取答案
```

**用组合组件搭出来的链，比一大坨 Lambda 可读性好得多**，而且每一步在 trace 里都是独立可见的。

## 八、流式与组合：哪些支持、哪些不支持

| 组件 | 支持流式 | 说明 |
|---|---|---|
| `RunnableParallel` | ✅ | 各分支独立流式 |
| `RunnablePassthrough` | ✅ | 透明 |
| `RunnableLambda` | ⚠️ | 用 `async def` + `yield` 才支持 |
| `RunnableBranch` | ✅ | 选中分支的流式 |
| `RunnableAssign` | ✅ | 除新加分支外透明 |

**`RunnableLambda` 是流式的分水岭**。如果 Lambda 里调用了 `.invoke()`，流式就断了。

想让 Lambda 保持流式，得用生成器：

```python
async def stream_wrapper(x):
    async for chunk in inner_chain.astream(x):
        yield chunk

RunnableLambda(stream_wrapper)
```

## 九、调试技巧：给每一步起名字

```python
chain = (
    RunnableLambda(normalize, name="01_normalize")
    | RunnableParallel(
        context=RunnableLambda(fetch, name="02_fetch"),
        question=RunnablePassthrough(),
    )
    | prompt.with_config(run_name="03_prompt")
    | llm.with_config(run_name="04_llm")
)
```

在 LangSmith 里，你会看到一棵有层次的树，每步的输入输出都清清楚楚。**匿名 chain 的 trace 是没法调试的。**

## 十、小结

```python
# 同时算几件事
RunnableParallel(a=chain_a, b=chain_b)

# 保留原输入
RunnablePassthrough()

# 在输入上加字段（最常用！）
RunnablePassthrough.assign(context=retriever | format_docs)

# 包普通函数
RunnableLambda(func, name="可读的名字")

# 条件分支
RunnableBranch((cond, chain_a), (cond2, chain_b), default)
```

三个原则：

1. **能用内置组件就别写 Lambda**——内置的能流式、能追踪；
2. **每一步都要能起名字**，方便看 trace；
3. **分支的输入输出类型要统一**，否则合并必炸。
