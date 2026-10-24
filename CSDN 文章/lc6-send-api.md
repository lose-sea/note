# Send API：动态扇出多个分支

普通条件边（`add_conditional_edges`）一次只能决定「下一步去哪个节点」。但有些场景，你得**根据运行时的数据，同时派出任意多个并行分支**——比如把一份大文档拆成 N 段，每段派一个 worker 去处理。这时就要用 **Send API**。

## 一、Send 是什么

`Send(node_name, input_state)` 代表「向某个节点发送一份输入」。它不是一个节点，而是一个**可以在路由函数里返回的动作对象**。当你返回一个 `Send` 列表，框架会把这些 Send 并行分发出去。

```python
from typing import TypedDict, Annotated
from langgraph.types import Send
from langgraph.graph import StateGraph, START, END, add_messages

class State(TypedDict):
    chunks: list
    done: Annotated[list, lambda a, b: a + b]

def split(state: State):
    # 根据运行时数据，动态生成多个分支
    return [Send("worker", {"chunk": c}) for c in state["chunks"]]

def worker(state: State) -> State:
    return {"done": [state["chunk"] + "已处理"]}

graph = StateGraph(State)
graph.add_node("worker", worker)
graph.add_conditional_edges(START, split)   # 返回的是 Send 列表
graph.add_edge("worker", END)
app = graph.compile()

out = app.invoke({"chunks": ["a", "b", "c"], "done": []})
print(out["done"])   # ['a已处理', 'b已处理', 'c已处理']
```

## 二、和「静态并行」的区别

如果你预先知道只有 3 个固定分支，用普通节点 + 多条边也能并行。但 `Send` 的优势在**数量运行时才确定**：今天拆成 5 段就发 5 个，明天 20 段就发 20 个，图的结构完全不用改。

## 三、典型用途

- **数据并行**：大列表/大文档拆分后并发处理，再聚合；
- **扇出检索**：一个问题生成多个子查询，每个子查询派一个检索分支；
- **多 Agent 协作**：给每个子任务动态派出一个 Agent 实例。

## 四、配合聚合节点

`Send` 只管「派出去」，结果怎么合回来要自己写聚合逻辑。常见模式是让所有 worker 都写同一个 `Annotated[list, add]` 字段，再接一个 `aggregate` 节点把列表合并成最终输出。这样「动态扇出 + 累加聚合」就闭环了。

Send API 是 LangGraph 表达「运行时才决定的并行度」的钥匙，比写死的图结构灵活得多。
