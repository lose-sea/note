# LangGraph Command 原语：更新状态和跳转节点，一次搞定

> 在 LangGraph 里，一个节点通常做两件事：
> 返回状态更新，然后由**边**决定下一步去哪。
>
> 但有些场景里，"更新什么"和"去哪"是绑定的——
> 这时候该用 `Command`，而不是 `update + add_edge`。

## 一、先回顾常规写法

普通节点的返回值是**状态片段**：

```python
from langgraph.graph import StateGraph, MessagesState

def classify(state: MessagesState):
    intent = detect_intent(state["messages"][-1].content)
    return {"intent": intent}

def route(state: MessagesState) -> str:
    """条件边函数：只负责选路"""
    return "handle_refund" if state["intent"] == "refund" else "handle_general"

builder = StateGraph(MessagesState)
builder.add_node("classify", classify)
builder.add_node("handle_refund", handle_refund)
builder.add_node("handle_general", handle_general)
builder.add_edge("__start__", "classify")
builder.add_conditional_edges("classify", route)
```

这里**状态更新和路由决策是分开的**：节点返回状态，条件边函数读状态再决定去哪。

这个模式很清晰，但有时会别扭。

## 二、Command：把两件事合成一件

`Command` 让你在节点里**同时**声明状态更新和目标节点：

```python
from langgraph.types import Command
from typing import Literal

def classify(state: MessagesState) -> Command[Literal["handle_refund", "handle_general"]]:
    intent = detect_intent(state["messages"][-1].content)
    target = "handle_refund" if intent == "refund" else "handle_general"
    return Command(
        update={"intent": intent},
        goto=target,
    )

builder = StateGraph(MessagesState)
builder.add_node("classify", classify)
builder.add_node("handle_refund", handle_refund)
builder.add_node("handle_general", handle_general)
builder.add_edge("__start__", "classify")
# 注意：不需要 add_conditional_edges！
```

三个好处：

1. **不需要写单独的 `route` 函数**——决策逻辑和节点逻辑本来就在一起，拆开反而割裂；
2. **类型标注 `Command[Literal[...]]` 让图知道有哪些可能去向**，可视化时能画出完整图；
3. **状态和路由原子更新**——不存在"状态更新了但路由读到的是旧值"这种中间态。

## 三、`update` 的几种形态

```python
return Command(update={"a": 1}, goto="next")                 # 覆盖 a
return Command(update={"messages": [HumanMessage(...)]}, goto="next")  # 走 reducer 追加
return Command(goto="next")                                   # 只跳转，不更新状态
return Command(update={})                                     # 只更新，不跳转（等价于普通节点返回）
```

配合 `Annotated` 的 reducer 才完整：

```python
from typing import Annotated
from langgraph.graph.message import add_messages

class State(TypedDict):
    messages: Annotated[list, add_messages]   # 追加语义
    intent: str                                # 覆盖语义
```

`Command(update={"messages": [...]})` 走追加，`Command(update={"intent": "refund"})` 走覆盖——**同一个 Command 里两种语义并存，这是 LangGraph 的精妙之处**。

## 四、`goto` 的几种形态

```python
Command(goto="node_a")                              # 跳到单个节点
Command(goto=["node_a", "node_b"])                  # 并行跳多个（fan-out）
Command(goto=Send("worker", {"task": t}) for t in tasks)  # 动态派发
```

`goto` 传列表时会**并行执行**这些节点，全部结束后再汇聚。这是实现 Map-Reduce 的轻量方式：不需要显式的 `Send`，一个 `Command` 就完成扇出。

```python
def dispatch(state: State) -> Command[Literal["worker"]]:
    return Command(goto=[Send("worker", {"item": i}) for i in state["items"]])
```

## 五、`graph=Command.PARENT`：跨图跳转

多智能体场景里，子图节点常常需要"跳回父图的某个节点"。默认 `Command` 只在当前图内跳转，跨图要显式指定：

```python
def sub_agent(state: State) -> Command[Literal["supervisor"]]:
    result = do_work(state)
    return Command(
        update={"messages": [AIMessage(result)]},
        goto="supervisor",
        graph=Command.PARENT,      # 跳转到父图的 supervisor 节点
    )
```

这是 **Supervisor 多智能体架构的标准写法**：每个子 Agent 干完活，通过 `graph=Command.PARENT` 把结果交回主管。

如果子图有多层，`graph=Command.PARENT` 只跳一层。需要跳更多层得用节点名加前缀，或者干脆拉平图结构。

## 六、`resume`：从人工中断处继续

`Command` 还有一个关键用途——**恢复被 `interrupt` 暂停的图**：

```python
from langgraph.types import interrupt, Command

def approve_node(state: State):
    decision = interrupt({
        "question": "确认执行这笔转账吗？",
        "amount": state["amount"],
    })
    if decision["approved"]:
        return Command(goto="execute")
    return Command(update={"status": "cancelled"}, goto="end_node")

# 图执行到 interrupt 会暂停，返回一个 __interrupt__ 事件
# 外部确认后，用 Command(resume=...) 继续
graph.invoke(Command(resume={"approved": True}), config=config)
```

注意这里 `Command(resume=...)` 是**传给 `invoke` 的输入**，不是节点返回值。这两者的区别很关键：

| 用法 | 位置 | 含义 |
|---|---|---|
| `Command(update=..., goto=...)` | 节点返回值 | 更新状态并跳转 |
| `Command(resume=...)` | `invoke` 参数 | 从中断点恢复 |

## 七、什么时候别用 Command

如果只是"节点返回状态、边决定路由"，**用条件边更清晰**：

```python
# 推荐：逻辑分离，好测试
def node_a(state) -> dict: return {"x": compute()}
def route(state) -> str: return "b" if state["x"] > 0 else "c"
builder.add_conditional_edges("node_a", route)
```

判断标准：

- 路由决策**依赖节点内部的中间变量**（算完才知道去哪）→ 用 `Command`；
- 路由决策**只看已有状态**（如检查 `state["retry_count"]`）→ 用条件边。

个人经验：**`Command` 用在"边界清晰的分支点"（意图分类、主管调度、人工审批），条件边用在"循环控制"（重试、迭代）**。

## 八、常见坑

**① 忘了类型标注。**
不写 `Command[Literal[...]]` 也能跑，但图的结构推理会失效，可视化会缺边，某些校验也会跳过。

**② `goto` 指向不存在的节点。**
LangGraph 在编译期能查出静态的 `goto` 错误，但动态构造的节点名查不出来。建议在节点里加断言：

```python
assert target in NODE_NAMES, f"未知节点：{target}"
```

**③ 子图里用 `Command` 跳父图节点，但父图没这个节点。**
报错信息会比较隐晦（`Node 'x' not found in parent graph`）。多智能体调试时优先检查这个。

**④ `update` 里的 key 不在 State 定义里。**
LangGraph 会静默忽略——不报错，但状态没更新，排查起来很痛苦。**给 State 用 `TypedDict` 而不是 `dict`**，让类型检查帮你发现。

## 九、小结

```python
Command(
    update={...},          # 要更新的状态
    goto="node" | [...],   # 去哪（可多个，可 Send）
    graph=Command.PARENT,  # 跨图（可选）
)
```

记住三点：

1. `Command` 是**节点返回值**，`Command(resume=...)` 是 **invoke 输入**；
2. 能合并就别拆——路由依赖节点内部计算时，用 `Command` 比"返回值 + 条件边"更自然；
3. 类型标注不是可选项，它决定图能不能被正确推理。
