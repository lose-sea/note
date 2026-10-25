# 断点与恢复：从指定节点接着跑

调试或上线时，你常想让图**不要一口气跑完**，而是在某个节点前先停下来看看，确认没问题再继续。LangGraph 提供两类「断点」机制：编译期的 `interrupt_before/after`，和运行期基于检查点的动态恢复。

## 一、编译时固定断点

```python
from langgraph.graph import StateGraph, START, END, MessagesState
from langgraph.checkpoint.memory import MemorySaver
from langchain_core.messages import HumanMessage, AIMessage

def think(state): return {"messages": [AIMessage(content="计划中")]}
def act(state):   return {"messages": [AIMessage(content="已执行")]}

graph = StateGraph(MessagesState)
graph.add_node("think", think)
graph.add_node("act", act)
graph.add_edge(START, "think")
graph.add_edge("think", "act")
graph.add_edge("act", END)

# 在 act 之前强制暂停
app = graph.compile(checkpointer=MemorySaver(), interrupt_before=["act"])
cfg = {"configurable": {"thread_id": "b-1"}}
```

第一次运行会在进 `act` 前停下：

```python
app.invoke({"messages": [HumanMessage(content="开始")]}, cfg)
print(app.get_state(cfg).next)   # ('act',) —— 卡在 act 之前
```

## 二、恢复执行

不传新输入，直接对同一个 config 再 invoke，图就会从断点处继续：

```python
app.invoke(None, cfg)   # 从 act 开始往下跑完
```

也可以像人机协同那样用 `Command(resume=...)` 把值带进去（当断点节点需要外部输入时）。

## 三、和 interrupt 节点的区别

- `interrupt()`（节点内调用）：**业务语义**的中断，「这里需要人的决定」，是图逻辑的一部分；
- `interrupt_before/after`（编译期）：**控制/调试**用的断点，纯粹为了「先停一下」，不一定要人输入，常用于上线前灰度、逐步放开自动执行。

两者都依赖 Checkpointer 保存状态，所以编译时务必传入 checkpointer，否则断点无从恢复。

## 四、运行期动态断点

除了写死在 compile，部分场景可以在 config 里追加断点，让「停在哪」变成运行时决定。掌握了固定断点，理解动态断点只是「把断点位置从常数变成变量」。

一句话：断点让「自动跑」变成「可控地跑」——先停、看状态、再决定放行，是上线 Agent 的必备安全绳。
