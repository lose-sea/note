# LangGraph 入门：为什么 Agent 需要图编排

很多人第一次写 Agent，用的都是 ReAct 那种「一个 while 循环套着 思考 → 调工具 → 观察」的写法。短任务确实好用，可一旦任务变长、步骤变多，就会暴露三个绕不开的短板：

- **只能一条直线走**：流程是线性的，想循环重试、想根据不同结果走不同分支都很别扭；
- **状态记不住**：代码跑完一轮就清空，中途崩了只能从头再来，没法「接着上次的地方继续」；
- **人插不进去**：你想在某个关键节点让人工确认一下，纯循环结构几乎要重写才能塞进去。

LangGraph 的思路是把 Agent 的执行过程**建模成一张图（Graph）**：节点（Node）是每一步要干的事，边（Edge）是步骤之间怎么流转，而一张共享的**状态（State）**在节点之间传递。有了这张图，上面三个问题都迎刃而解——图天然支持循环和条件分支，状态可以被持久化，人也可以在任意节点介入。

下面是最朴素的一张图，感受一下结构：

```python
from typing import TypedDict
from langgraph.graph import StateGraph, START, END

class State(TypedDict):
    question: str
    answer: str

def think(state: State) -> State:
    # 真实场景里这里会调用大模型
    return {"answer": f"关于「{state['question']}」的回答"}

graph = StateGraph(State)
graph.add_node("think", think)      # 注册一个节点
graph.add_edge(START, "think")      # 入口连到 think
graph.add_edge("think", END)        # think 之后到出口
app = graph.compile()                # 编译成可运行的 app

result = app.invoke({"question": "LangGraph 是什么？"})
print(result["answer"])
```

注意 `app.invoke` 的输入和输出都是同一份 `State`：你喂进去一个问题，图跑完把填好的 `answer` 还给你。这就是 LangGraph 最核心的心智模型——**所有节点都围绕同一份状态读写**。

和「链式（Chain）」相比，图的关键差异在于它允许**环路**和**分支**。比如一个节点跑了之后，可以回到上一个节点再试一次，或者根据模型输出决定下一步走哪条边。后面几篇会逐个拆开讲：先定义状态（StateGraph）、再加节点与边、然后上条件路由、持久化、人机协同……循序渐进，把这张图真正用起来。

一句话总结：当你需要的不是一个「一次性流水线」，而是一个**能循环、能判断、能记住、能让人参与**的智能体时，就该用 LangGraph 了。
