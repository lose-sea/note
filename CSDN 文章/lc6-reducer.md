# 状态更新与 reducer：用 Annotated 做累加

前面几篇都提到一个关键细节：节点返回的是「要更新的字段」，而 LangGraph 会把这些返回值**合并**进全局状态。但「合并」默认是**覆盖**——新值直接盖掉旧值。当你需要的是「追加」而不是「替换」（最典型的就是消息列表），覆盖就不够用了。这就引出 LangGraph 的状态更新函数：**reducer**。

## 一、默认是覆盖

看这个例子，`notes` 字段每跑一个节点就被整个替换：

```python
from typing import TypedDict
from langgraph.graph import StateGraph, START, END

class State(TypedDict):
    notes: list

def a(state): return {"notes": ["A"]}
def b(state): return {"notes": ["B"]}   # 覆盖，不是追加

graph = StateGraph(State)
graph.add_node("a", a); graph.add_node("b", b)
graph.add_edge(START, "a"); graph.add_edge("a", "b"); graph.add_edge("b", END)
app = graph.compile()
print(app.invoke({"notes": []})["notes"])   # ['B']，A 丢了
```

跑完只剩 `['B']`，因为 `b` 的返回值整体覆盖了 `notes`。

## 二、用 Annotated 声明 reducer

`Annotated[type, reducer_fn]` 告诉 LangGraph：**当多个节点都返回这个字段时，用 reducer_fn 把它们「合并」起来，而不是覆盖**。

```python
from typing import TypedDict, Annotated

def add(a, b):           # reducer：旧值 a，新值 b，返回合并结果
    return a + b

class State(TypedDict):
    notes: Annotated[list, add]
```

现在再跑上面的 `a` 和 `b`：

```python
print(app.invoke({"notes": []})["notes"])   # ['A', 'B']
```

`a` 返回 `["A"]`，`b` 返回 `["B"]`，reducer 把两者加起来，得到 `['A', 'B']`。

## 三、常见 reducer 套路

- **列表累加**：`Annotated[list, lambda a, b: a + b]`（或 `operator.add`）；
- **取最大值**：`Annotated[int, max]`；
- **集合去重合并**：`Annotated[set, lambda a, b: a | b]`；
- **字典合并**：`Annotated[dict, lambda a, b: {**a, **b}]`。

LangGraph 内置了最常用的「消息累加」reducer `add_messages`，专门配合聊天场景，下一篇会直接用。

## 四、reducer 只作用于「同字段多次写入」

reducer 不改变「节点返回什么」，只改变「多个返回值如何合并」。如果一个字段只有第一个节点写了、后面都没碰，那它一直保持初值，reducer 不会无事生非。

一句话：**覆盖适合「结论型字段」（answer、label），reducer 适合「累积型字段」（notes、messages、history）**。把这两者分清楚，状态就不会莫名其妙被冲掉。
