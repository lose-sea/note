# LangGraph 入门：当你的 Agent 需要「回到上一步」

用 LangChain 的 Chain 能画出一条直线：A → B → C。但真实的 Agent 往往需要**回头**——查了一次发现信息不够，得再查一次；工具报错了，得换个参数重试；模型自己觉得答案不满意，得返工。

**直线表达不了循环**。这就是 LangGraph 存在的理由。

这篇讲清楚：**图的三个基本概念、怎么画出带环的流程、状态怎么传递、以及一个能跑的完整例子**。

---

## 一、从 Chain 到 Graph

对比一下两种结构：

```
Chain（有向无环）：            Graph（可以有环）：

  输入 ─► A ─► B ─► 输出        输入 ─► 思考 ─► 行动 ─► 观察 ─┐
                                          ▲                    │
                                          └────────────────────┘
```

Agent 的核心循环天然是**有环的**：观察完还要回到思考。用 Chain 硬做也不是不行——写个 `while` 循环手动调——但状态管理、中断恢复、人工介入这些很快就会失控。

LangGraph 把 Agent 建模成一张**状态图**：节点是干活的函数，边是流转规则，状态在节点之间流动。

---

## 二、三个核心概念

### ① State（状态）

整张图共享的一份数据。通常是一个 TypedDict：

```python
from typing import TypedDict, Annotated
from langgraph.graph.message import add_messages

class State(TypedDict):
    messages: Annotated[list, add_messages]   # ★ 追加而不是覆盖
    step: int
```

那个 `Annotated[list, add_messages]` 很关键。它告诉 LangGraph：**消息列表是「追加」语义，不是「覆盖」**。节点返回新消息时，会被追加到已有列表后面，而不是把历史冲掉。

如果写成普通的 `messages: list`，节点返回什么就整体替换掉什么，历史就丢了——这是最常见的坑。

### ② Node（节点）

一个普通函数，接收 state、返回**部分更新**：

```python
def think(state: State):
    resp = llm.invoke(state["messages"])
    return {"messages": [resp], "step": state["step"] + 1}
```

注意返回的是**增量**（dict），LangGraph 负责合并回完整状态。你不需要把整个 state 都返回。

### ③ Edge（边）

决定「下一步走哪」。两种：

- **普通边**：`graph.add_edge("a", "b")` —— 无条件从 a 到 b；
- **条件边**：`graph.add_conditional_edges("a", router)` —— 由 `router` 函数返回值决定去哪。

条件边就是实现循环和分支的地方。

---

## 三、画一张带环的图

一个典型的 Agent 图：

```python
from langgraph.graph import StateGraph, END

graph = StateGraph(State)

# 1. 注册节点
graph.add_node("think", think)        # 让模型决定要不要用工具
graph.add_node("act", call_tool)      # 执行工具

# 2. 入口
graph.set_entry_point("think")

# 3. 条件边：模型说要用工具就去 act，否则结束
def router(state: State):
    last = state["messages"][-1]
    if hasattr(last, "tool_calls") and last.tool_calls:
        return "act"
    return "end"

graph.add_conditional_edges("think", router, {
    "act": "act",
    "end": END,
})

# 4. ★ 回环：干完活回到 think
graph.add_edge("act", "think")

app = graph.compile()
```

第 4 步那行 `add_edge("act", "think")` 就是**环**——这是 Chain 做不到的。

跑起来：

```python
result = app.invoke({
    "messages": [HumanMessage("杭州今天天气怎么样？")],
    "step": 0,
})
print(result["messages"][-1].content)
```

---

## 四、防止无限循环

有环就必须有出口。三个常用手段：

**1. 步数上限**（最直接）

```python
def router(state: State):
    if state["step"] >= 10:
        return "end"                 # 到点强制结束
    ...
```

**2. 编译时的递归限制**

```python
app = graph.compile()
result = app.invoke(input, {"recursion_limit": 25})
```

超过会抛 `GraphRecursionError`，避免跑飞烧钱。

**3. 在节点里判断收敛**

比如工具连续两次返回相同结果，就判定无进展，直接结束。

---

## 五、两个真正好用的进阶特性

### ① Checkpoint（断点保存）

把每一步的状态存下来，可以做**中断恢复**和**时间旅行**：

```python
from langgraph.checkpoint.memory import MemorySaver

memory = MemorySaver()
app = graph.compile(checkpointer=memory)

config = {"configurable": {"thread_id": "user-123"}}
app.invoke(input, config)

# 拿到当前状态，甚至可以往回改
snapshot = app.get_state(config)
```

生产环境换成数据库版本（`SqliteSaver` / `PostgresSaver`），服务重启后对话能接着走。这是 LangGraph 相对手写循环**最有价值的地方**。

### ② 人工介入（Human-in-the-loop）

在敏感操作前暂停，等人确认：

```python
app = graph.compile(checkpointer=memory, interrupt_before=["act"])
```

图会在进入 `act` 节点前停下，你检查一遍再 `app.invoke(None, config)` 继续。做「Agent 要删文件 / 要花钱」这类操作时，这个能力几乎是必需的。

---

## 六、LangGraph vs 手写循环

| 维度 | 手写 while 循环 | LangGraph |
|---|---|---|
| 简单场景 | 更轻量，几行搞定 | 有点重 |
| 状态管理 | 自己维护，容易乱 | 框架统一管 |
| 中断 / 恢复 | 基本做不了 | Checkpoint 原生支持 |
| 人工介入 | 要自己设计 | `interrupt_before` 一行 |
| 可视化 / 调试 | 靠 print | 图结构可导出、可追踪 |
| 学习成本 | 低 | 中（要理解状态合并语义） |

**建议**：如果只是「模型 + 两个工具」的小 Agent，手写循环完全够用；一旦需要长任务、断点续跑、人工审核，再上 LangGraph。

---

## 七、小结

1. LangGraph 解决的是 **Chain 表达不了循环**的问题——Agent 的「思考 → 行动 → 观察 → 再思考」天生是有环的。
2. 三个概念：**State（共享状态）/ Node（处理函数）/ Edge（流转规则）**，条件边是分支和回环的关键。
3. `Annotated[list, add_messages]` 表示**追加语义**，写错会让历史消息被覆盖——这是最高频的坑。
4. 有环必须设出口：步数上限、`recursion_limit`、收敛判断，三选一（或都用）。
5. **Checkpoint 和人工介入是它相对手写循环最大的价值**，长任务和敏感操作场景几乎必需。
6. 小 Agent 别过度设计，手写循环更轻。

到这里 Agent 的「框架」这条线讲了一半。下一篇进入 RAG——它是目前 Agent 落地最广泛、也最容易做砸的方向。
