# StateGraph 基础：先定义状态再画图

用 LangGraph 搭图，第一步永远是**先定义状态（State），再往上面挂节点和边**。状态是一张图的「中央数据总线」——所有节点都从它读输入、往它写输出，节点之间不直接传参，只通过状态沟通。

## 一、用 TypedDict 描述状态

最常见的方式是声明一个 `TypedDict`，把这张图要流转的所有字段列出来：

```python
from typing import TypedDict, List
from langgraph.graph import StateGraph, START, END

class State(TypedDict):
    question: str          # 用户问题
    steps: List[str]       # 已经走过的步骤记录
    answer: str            # 最终答案
```

这里的字段就是这张图的「契约」。编译后，每次 `invoke` 传入的字典会被校验，缺字段会直接报错，比散装的 `dict` 安全得多。

## 二、节点就是普通函数

每个节点本质上是一个函数，接收当前 `State`，返回一个**要更新到状态里的那部分字段**：

```python
def plan(state: State) -> State:
    return {"steps": state["steps"] + ["已规划"]}

def solve(state: State) -> State:
    return {"answer": "结论：" + state["question"]}

graph = StateGraph(State)
graph.add_node("plan", plan)
graph.add_node("solve", solve)
graph.add_edge(START, "plan")
graph.add_edge("plan", "solve")
graph.add_edge("solve", END)

app = graph.compile()
out = app.invoke({"question": "1+1=?",
                  "steps": [], "answer": ""})
print(out["answer"], out["steps"])
```

关键点：**节点返回的是「增量」**。上面 `plan` 只返回 `steps`，LangGraph 会把它合并进全局状态；`solve` 只填 `answer`。这正是后面讲「reducer」时要重点说的机制——有些字段（比如消息列表）不是简单覆盖，而是需要「累加」，那时就得用 `Annotated` 显式声明更新方式。

## 三、为什么状态要先于一切

很多 bug 都源于「状态没设计好，后面节点乱读字段」。先把 `State` 想清楚，有几个实在的好处：

1. **可视化自然成立**：Studio 能把状态随时间的变化画成时间线，因为状态就是唯一的真相来源；
2. **持久化和回溯变简单**：只要把状态按 `thread_id` 存下来，就能随时恢复或回退（见后续「检查点」「时间旅行」两篇）；
3. **多节点协作不打架**：大家都按同一份契约读写，不会出现 A 节点改了 B 节点依赖的变量却没人知道的情况。

一个常见误区是「把函数内部变量当状态用」。记住：只有写进 `State` 的东西，才会被图记住、被下一个节点看见、被检查点保存。临时变量出了节点函数就消失了。

把状态定义清楚，后面的节点、边、条件分支、人机协同，全都是在状态之上搭积木。这一篇先到这里，下一篇我们专门聊节点和边怎么连。
