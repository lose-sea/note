# 多 Agent 编排：supervisor 与 handoff

单个 Agent 能力有限，真实系统常把任务拆给多个 specialist（专家 Agent），由一个「主管（supervisor）」来调度。LangGraph 既支持**手写多 Agent 图**，也提供了 `create_supervisor` 这种预建编排。两种思路都值得掌握。

## 一、手写：supervisor 调度子 Agent

每个子 Agent 本身是个编译好的 app（比如用 create_react_agent 造的），supervisor 根据问题决定派给谁：

```python
from langgraph.prebuilt import create_react_agent

research = create_react_agent(model, [web_search], name="researcher")
writer   = create_react_agent(model, [doc_tool],   name="writer")

# supervisor 图里，用一个节点根据 state 选择把任务交给 research 还是 writer
# 经典做法：supervisor 节点返回 Command(goto=下一个被调用的 agent 节点)
```

子 Agent 作为节点挂进 supervisor 图，supervisor 的路由逻辑决定「这一步派给谁」。这是最灵活的做法，流程完全自定义。

## 二、预建：create_supervisor

LangGraph 提供 `create_supervisor` 快速搭一个「主管 + 多个 worker」的结构：

```python
from langgraph.prebuilt import create_supervisor

workflow = create_supervisor([research, writer], model=model)
app = workflow.compile()
app.invoke({"messages": [{"role":"user","content":"先查资料，再写一份摘要"}]})
```

supervisor 会自动在 worker 之间协调：收到任务 → 决定调用哪个 worker → 汇总结果 → 必要时再派活，直到完成。

## 三、handoff（交接）的概念

`handoff` 指「一个 Agent 把对话/任务移交给另一个 Agent」。在 LangGraph 里，交接通常通过：

- supervisor 把输入路由到对应 worker（集中式）；
- 或 worker 主动 `Command(goto=另一个_agent节点)` 把控制权交出去（去中心化）。

前者好管控、易观测；后者更灵活，适合 worker 之间平级协作。

## 四、选型建议

- 任务清晰、worker 职责固定 → `create_supervisor` 最快；
- 需要复杂编排、条件交接、人工介入 → 手写 StateGraph，用 Send/Command 精细控制；
- 担心串台 → 给每个 worker 独立的 thread_id 或状态空间，避免互相污染。

一句话：多 Agent 的本质是「分工 + 调度」。supervisor 负责调度，handoff 负责移交，LangGraph 把这两件事都变成了图里的普通节点。
