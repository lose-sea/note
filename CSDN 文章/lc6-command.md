# Command：在节点里控制流向

前面讲 `add_conditional_edges` 是在「节点之外」用路由函数决定走向。但有时你希望**节点自己**在返回结果的同时，直接指定「下一步去哪」——比如一个节点根据内部计算结果，既要更新状态，又要跳到不同节点。LangGraph 提供 `Command` 对象干这件事。

## 一、Command 的基本形态

```python
from langgraph.types import Command
from langgraph.graph import END

def node(state):
    if state["x"] > 0:
        return Command(goto="positive", update={"y": 1})
    return Command(goto=END, update={"y": 0})
```

`Command` 同时携带两部分：
- `goto`：下一个节点名（或节点名列表，用于扇出）；
- `update`：要写回状态的字段（相当于普通节点 return 的字典）。

注意 `Command` 是**返回值**，不是副作用调用。节点函数直接 `return Command(...)`。

## 二、和 add_conditional_edges 的对比

- `add_conditional_edges`：路由逻辑独立于节点，所有分支判断集中在一处，适合「分叉点清晰、分支少」；
- `Command`：判断逻辑写在节点内部，节点对自己「往哪走」有完全的控制权，适合「走向依赖节点内部复杂计算」。

两者可以混用：有的分叉用条件边，有的节点内部用 Command 跳转。

## 三、在中断里也常用

`Command(resume=...)` 我们在「人机协同」里见过——它用来把外部输入塞回 `interrupt`。而 `Command(goto=...)` 则是在正常流转里动态指定下一个节点，二者是同一对象的不同用法。

## 四、一个小例子

```python
def router_node(state):
    if "紧急" in state["text"]:
        return Command(goto="urgent", update={"level": "high"})
    return Command(goto="normal", update={"level": "low"})

graph.add_node("router_node", router_node)
graph.add_edge(START, "router_node")
graph.add_edge("urgent", END)
graph.add_edge("normal", END)
```

一个节点同时完成「判断 + 跳转 + 写状态」，图更紧凑。

一句话：当节点的「下一步」必须由节点自己说了算时，用 `Command` 把控制流交回给节点。它和条件边是互补的两种路由手段。
