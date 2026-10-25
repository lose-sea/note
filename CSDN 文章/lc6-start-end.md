# START 与 END：图的入口和出口节点

每张 LangGraph 图都有两个**特殊的端点**：`START` 和 `END`。它们不是你注册的节点，而是框架预留的「虚拟节点」，专门用来标记一张图的入口和出口。

## 一、START：图的入口

`START` 代表「这张图的开始」。你做的第一件事，通常是把某个真实节点连到 `START` 上：

```python
graph.add_edge(START, "first_node")
```

意思是：一旦 `app.invoke(...)` 被调用，执行就从 `START` 流到 `first_node`。你不能往 `START` 里写节点函数，它只是个「从哪里出发」的标记。

也可以让 `START` 直接连到条件边，实现入口即分流：

```python
graph.add_conditional_edges(START, entry_router, ["a", "b"])
```

## 二、END：图的出口

`END` 代表「这张图到此结束」。任何一个节点跑完，如果连到了 `END`，整个图就停在这里，并把当前状态作为最终结果返回：

```python
graph.add_edge("last_node", END)
```

没有连到 `END` 的节点，执行到它就会「悬空」——图不知道接下来去哪，通常会被认为是不完整的图（取决于是否还有其他出边）。

## 三、为什么需要这两个虚拟端点

- **统一入口，解耦调用方**：调用方永远只说「从 START 开始」，不用关心第一个真实节点叫什么；重命名节点不影响入口声明。
- **明确终止，避免死循环**：只有显式连到 `END` 的路径才会停。配合条件边，你可以让某些分支「打到 END 结束」，另一些分支「回到中间节点循环」，终止条件因此变得清晰可控。
- **可视化友好**：Studio 把 `START`/`END` 画成图的首尾，一眼看清整条链路。

## 四、一个完整小图

```python
from typing import TypedDict
from langgraph.graph import StateGraph, START, END

class State(TypedDict):
    n: int

def inc(state: State) -> State:
    return {"n": state["n"] + 1}

graph = StateGraph(State)
graph.add_node("inc", inc)
graph.add_edge(START, "inc")
graph.add_edge("inc", END)

app = graph.compile()
print(app.invoke({"n": 0}))   # {'n': 1}
```

这张图只有一个真实节点 `inc`，但它依然要有 `START → inc → END` 这条完整链路才算一张「闭合的图」。

记住一句话：**真实节点负责「做事」，START/END 负责「划界」**。先把入口和出口钉死，再往中间填节点，图就不会跑偏。
