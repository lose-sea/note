# LangGraph Swarm 模式：智能体之间直接交接，不要中心调度

> Supervisor 是"主管分派"，Swarm 是"同事互相转交"。
> 用户问了一个跨部门的问题，前台处理到一半发现要转售后——
> **直接转过去，不用先回主管再派下去**。

## 一、Swarm 的核心思想

传统多智能体有两种拓扑：

```
Supervisor（中心辐射）          Swarm（网状直连）
      ┌───┐                    A ──→ B
      │ S │                    ↑     │
      └─┬─┘                    D ←── C
   ┌────┼────┐
   ▼    ▼    ▼
   A    B    C
```

Swarm 的特点：

1. **没有中心**——任何 Agent 都能把控制权交给任何其他 Agent；
2. **上下文跟随**——交接时把该带的信息传过去；
3. **活跃 Agent 概念**——同一时刻只有一个 Agent 在"持有话筒"。

好处是**链条短**（省一次调度往返），代价是**全局可见性差**（没有一处能看到全貌）。

## 二、最小实现：`langgraph-swarm`

官方提供了 `langgraph-swarm` 包，核心是一个 `create_swarm` 工厂：

```python
from langgraph_swarm import create_swarm, create_handoff_tool
from langgraph.prebuilt import create_react_agent

# 给每个 Agent 一个"转交工具"
transfer_to_refund = create_handoff_tool(
    agent_name="refund_agent",
    description="把用户转交给售后专员，适用于退款、退货、投诉",
)
transfer_to_logistics = create_handoff_tool(
    agent_name="logistics_agent",
    description="把用户转交给物流专员，适用于查快递、催发货",
)

front_desk = create_react_agent(
    model=llm,
    tools=[lookup_faq, transfer_to_refund, transfer_to_logistics],
    name="front_desk",
    prompt="你是前台客服，先了解用户诉求。判断不了就转交给对应专员。",
)

refund_agent = create_react_agent(
    model=llm,
    tools=[check_eligibility, create_refund, transfer_to_logistics],
    name="refund_agent",
    prompt="你是售后专员，处理退款。退款成功后如果用户问物流，转给物流专员。",
)

logistics_agent = create_react_agent(
    model=llm,
    tools=[track_package],
    name="logistics_agent",
    prompt="你是物流专员，只回答物流问题。",
)
```

组装成 swarm：

```python
swarm = create_swarm(
    [front_desk, refund_agent, logistics_agent],
    default_active_agent="front_desk",
).compile(checkpointer=checkpointer)

config = {"configurable": {"thread_id": "u-1001"}}
result = swarm.invoke(
    {"messages": [{"role": "user", "content": "我上周买的东西还没到，能退款吗？"}]},
    config=config,
)
```

模型看到 `transfer_to_refund` 这个工具，需要转交时直接调用它——**转交变成了一个普通的工具调用**，不需要你写路由逻辑。

## 三、活跃 Agent 是怎么记录的

Swarm 在状态里维护一个 `active_agent` 字段：

```python
from langgraph_swarm import SwarmState

swarm = create_swarm(...)
print(SwarmState.__annotations__)
# {'messages': ..., 'active_agent': ...}
```

每次交接就是改这个字段：

```python
# create_handoff_tool 内部大致做的事
def handoff(state):
    return Command(
        goto=target_agent,
        update={
            "active_agent": target_agent,
            "messages": [ToolMessage(f"已转交给 {target_agent}", tool_call_id=...)]
            + [HumanMessage(f"下面是 {target_agent} 接手时的对话")],
        },
    )
```

理解这一点很重要：**Swarm 不是"多个图并行跑"，而是"同一个图里切换当前节点"**。

## 四、手动实现 Swarm（不依赖三方包）

包封装得再好，理解原理才能调试。手写版本大概 60 行：

```python
from typing import Annotated, Literal
from langgraph.graph import StateGraph, MessagesState, START, END
from langgraph.types import Command
from langgraph.graph.message import add_messages

AGENTS = ["front_desk", "refund_agent", "logistics_agent"]

class SwarmState(MessagesState):
    active_agent: str = "front_desk"

def make_handoff_tool(from_agent: str, to_agent: str, desc: str):
    """生成一个转交工具（用 @tool 装饰，闭包捕获目标）"""
    @tool(f"transfer_to_{to_agent}", description=desc)
    def handoff(reason: str) -> Command:
        return Command(
            goto=to_agent,
            update={"active_agent": to_agent,
                    "messages": [ToolMessage(f"转交原因：{reason}", tool_call_id="handoff")]},
        )
    return handoff

def make_agent_node(name: str, tools: list, prompt: str):
    bound = llm.bind_tools(tools)
    def node(state: SwarmState):
        resp = bound.invoke([SystemMessage(prompt)] + state["messages"])
        # 若模型调用了转交工具，Command 会从 tool 的返回值里出来
        return {"messages": [resp]}
    node.__name__ = name
    return node
```

关键点：`Command` 从**工具内部返回**，LangGraph 会把 `goto` 提升为图的路由。这是 Swarm 能"在工具调用中完成跳转"的机制。

## 五、和 Supervisor 的取舍

| 维度 | Supervisor | Swarm |
|---|---|---|
| 延迟 | 每步多一次调度 | 直接转交，少一跳 |
| 可控性 | 高（中心可审计） | 低（分散决策） |
| 死循环风险 | 主管横跳 | A↔B 互相踢皮球 |
| 上下文 | 全局 | 需要显式传递 |
| 调试 | 看主管决策日志即可 | 要看每次交接 |
| 适合 | 审批、合规、流程固定 | 客服、长链条协作 |

**个人建议：能用 Supervisor 就用 Supervisor。** Swarm 的"少一跳"在大多数场景里换不来调试成本的增加。只有链条特别长（5+ 次交接）、且每一步的专业性很强时，Swarm 才划算。

## 六、死循环是所有 Swarm 的心病

A 转给 B，B 觉得不该自己管，转回 A……无限循环。

**防法一：交接记账**

```python
class SwarmState(MessagesState):
    active_agent: str = "front_desk"
    handoff_log: Annotated[list[str], add] = []

def node(state):
    if len(state["handoff_log"]) > 4:
        return Command(goto=END, update={
            "messages": [AIMessage("这个问题需要人工介入，已为您转接。")]
        })
    ...
```

**防法二：禁止回跳**

```python
last_from = state["handoff_log"][-1].split("->")[0] if state["handoff_log"] else None
# 在转交工具的 description 里说明："不要转回刚刚转给你的人"
```

**防法三：给每个 Agent 一个明确的"终止条件"**

最好的防死循环不是加计数器，而是**在提示词里写清楚边界**：

```python
prompt = """你是物流专员。

职责：查询快递轨迹、估算到达时间。
不负责：退款（转 refund_agent）、商品咨询（转 front_desk）。

如果用户的问题不在你的职责内，立即转交，不要尝试回答。
如果用户可以自行解决（如已给出单号），直接给结论并结束。
"""
```

## 七、上下文传递：Swarm 最容易出错的地方

Swarm 默认会把**全部历史**带过去。如果 A 和 B 反复交接，历史会爆炸。

两种控制：

```python
def node(state):
    # 只带最近 8 条 + 当前活跃 agent 的任务说明
    recent = state["messages"][-8:]
    prefix = HumanMessage(f"[系统] 现在由 {name} 接手。用户诉求：{extract_goal(state)}")
    resp = bound.invoke([SystemMessage(prompt), prefix] + recent)
    return {"messages": [resp]}
```

把"用户的核心诉求"单独维护成一个字段，交接时传递它——**比传递全部历史更可靠**，因为历史里可能混着已经不成立的中间结论。

## 八、什么时候该用 Swarm

**适合**：

- 客服类场景，问题是"渐进式排查"，不知道最后会归到哪个部门；
- 每个 Agent 的职责边界清晰且互斥；
- 用户能接受"被转接"的体验（体验上像打客服电话转分机）。

**不适合**：

- 需要全局预算控制（Swarm 里算法分散在各 Agent）；
- 需要严格审计（每次交接都要落库的话，Supervisor 更好做）；
- 步骤短（2~3 步就能解决的事，加一层 Swarm 是过度设计）。

## 九、小结

```python
swarm = create_swarm([a, b, c], default_active_agent="a").compile(checkpointer=cp)
```

三个要点：

1. **转交 = 工具调用**，`Command(goto=...)` 从工具里返回；
2. **`active_agent` 字段**是 Swarm 的心脏，交接就是改它；
3. **防死循环靠提示词写清边界**，计数器只是最后一道保险。

Swarm 是"更灵活但更难控"的那一端。**先从 Supervisor 开始，真的遇到了调度开销问题，再考虑换 Swarm。**
