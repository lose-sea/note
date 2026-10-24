# 节点与边：add_node 与 add_edge 的最小图

状态定义好之后，图的骨架就靠两样东西搭起来：**节点（node）** 和 **边（edge）**。节点是「做什么」，边是「做完之后去哪」。

## 一、注册节点：add_node

`add_node(name, func)` 给一个函数起个名字挂到图上。名字在同一个图里必须唯一，后面所有边的连接都靠它寻址。

```python
from typing import TypedDict
from langgraph.graph import StateGraph, START, END

class State(TypedDict):
    x: int

def plus_one(state: State) -> State:
    return {"x": state["x"] + 1}

def times_two(state: State) -> State:
    return {"x": state["x"] * 2}

graph = StateGraph(State)
graph.add_node("plus_one", plus_one)
graph.add_node("times_two", times_two)
```

节点函数接收 `State`、返回需要更新的字段，这一点上一篇已经强调过。

## 二、连接边：add_edge

`add_edge(a, b)` 表示「节点 a 跑完，无条件走到节点 b」：

```python
graph.add_edge(START, "plus_one")
graph.add_edge("plus_one", "times_two")
graph.add_edge("times_two", END)

app = graph.compile()
print(app.invoke({"x": 3}))   # {'x': 8}  -> (3+1)*2
```

执行顺序是 `START → plus_one → times_two → END`，状态里的 `x` 从 3 变成 4 再变成 8。这种**固定顺序、无分支**的边叫「普通边」，最简单也最可控。

## 三、普通边 vs 条件边

普通边 `add_edge` 永远是「一条道走到黑」；当你需要根据运行结果决定走向时，就要用 `add_conditional_edges`（下一篇专门讲）。两者不是替代关系，而是配合：先靠普通边串起主干，在少数分叉点用条件边择路。

```python
# 主干用普通边
graph.add_edge(START, "classify")
# 分叉点用条件边
graph.add_conditional_edges("classify", router, ["path_a", "path_b"])
graph.add_edge("path_a", END)
graph.add_edge("path_b", END)
```

## 四、几个容易踩的坑

- **必须能从 START 走到 END**：如果某条路径断了（比如有个节点谁都没连向它），`compile()` 通常会报错提醒你图不连通；
- **避免意外环路**：普通边如果 `A→B→A` 会形成死循环，`compile` 一般不会拦，但运行时会卡死，要靠条件边里的终止判断来收口；
- **节点名别和保留字冲突**：`START` / `END` 是特殊端点，你自己加节点请用普通字符串名字。

最小图的心法就一句：**节点是积木，边是连接说明书**。先把每块积木（节点函数）写好、互不耦合，再用边把流程说清楚，图就立起来了。下一篇我们看条件边，给图装上「判断能力」。
