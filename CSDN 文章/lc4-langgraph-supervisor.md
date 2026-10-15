# Supervisor 多智能体编排：一个主管带几个专员，比一锅乱炖靠谱

> 你给一个 Agent 绑了 15 个工具：查订单、改地址、退款、发优惠券、查物流……
> 结果它经常选错工具，或者在一个工具上打转。
>
> 把工具按职责拆给多个专职 Agent，再加一个主管调度——**上下文变小了，选择变准了**。

## 一、为什么单 Agent 绑 15 个工具会崩

三个原因：

1. **工具描述的干扰**。"查订单"和"查物流"的描述里都有"查询"、"编号"，模型很容易混；
2. **上下文被无关工具占满**。每次调用都要把 15 个工具的 schema 塞进上下文，白烧 token；
3. **状态污染**。处理退款时历史里混着物流查询的中间结果，模型容易串。

Supervisor 架构就是把"一个全能选手"换成"**一个调度 + 若干专家**"：

```
              ┌──────────────┐
              │  Supervisor  │
              └──────┬───────┘
        ┌────────────┼────────────┐
        ▼            ▼            ▼
   ┌────────┐  ┌────────┐  ┌────────┐
   │ 订单组 │  │ 售后组 │  │ 物流组 │
   └────────┘  └────────┘  └────────┘
```

主管**不干活**，只做两件事：看清当前状态、决定下一个该谁上。

## 二、最简 Supervisor 实现

每个子 Agent 是一个编译好的图：

```python
from langgraph.graph import StateGraph, MessagesState, START, END
from langgraph.prebuilt import create_react_agent

order_agent = create_react_agent(
    model=llm,
    tools=[query_order, list_orders, modify_address],
    state_modifier="你是订单专员，只处理订单查询和地址修改。其他问题直接说'不归我管'。",
)

refund_agent = create_react_agent(
    model=llm,
    tools=[check_refund_eligibility, create_refund, query_refund_status],
    state_modifier="你是售后专员，只处理退款相关。涉及金额超过 500 元时必须说明需要人工审核。",
)

logistics_agent = create_react_agent(
    model=llm,
    tools=[track_package, estimate_delivery],
    state_modifier="你是物流专员，只回答物流轨迹和时效问题。",
)
```

主管节点负责决策：

```python
from typing import Literal
from langchain_core.messages import SystemMessage

MEMBERS = ["order_agent", "refund_agent", "logistics_agent"]

SUPERVISOR_PROMPT = """你是一个客服团队的调度员。根据当前对话，决定下一步交给谁处理。

可选的团队成员：
- order_agent：订单查询、地址修改
- refund_agent：退款申请、退款进度
- logistics_agent：物流轨迹、配送时效
- FINISH：用户问题已全部解决

判断规则：
1. 一次只指派一个人；
2. 如果上一个人的回答已经解决了问题，输出 FINISH；
3. 如果用户在追问同一件事，继续交给同一个人。
"""

class SupervisorState(MessagesState):
    next: str

def supervisor_node(state: SupervisorState) -> Command[Literal[*MEMBERS, "__end__"]]:
    messages = [SystemMessage(SUPERVISOR_PROMPT)] + state["messages"]
    decision = llm.with_structured_output(Route).invoke(messages)
    goto = "__end__" if decision.next == "FINISH" else decision.next
    return Command(goto=goto, update={"next": decision.next})

class Route(BaseModel):
    next: Literal["order_agent", "refund_agent", "logistics_agent", "FINISH"]
    reason: str = Field(description="选择理由，一句话")
```

用结构化输出而不是解析文本，是让调度稳定的关键——**别让主管"自由发挥"输出格式**。

## 三、把子 Agent 接进主图

用 `Command.PARENT` 让子 Agent 干完活回到主管：

```python
builder = StateGraph(SupervisorState)
builder.add_node("supervisor", supervisor_node)
builder.add_node("order_agent", order_agent)
builder.add_node("refund_agent", refund_agent)
builder.add_node("logistics_agent", logistics_agent)

for m in MEMBERS:
    builder.add_edge(m, "supervisor")     # 每个专员干完都回主管

builder.add_edge(START, "supervisor")
graph = builder.compile(checkpointer=checkpointer)
```

关键设计：**专员 → 主管** 的边是固定的。专员干完必回主管，主管决定下一步或结束。

这形成了"**中心辐射**"结构——所有流转都经过主管，主管始终掌握全局。

## 四、交接时怎么传上下文

默认情况下，子 Agent 看到的是**全部消息历史**。这会导致两个问题：上下文膨胀、专业偏见（物流专员看到退款讨论会分心）。

两种控制方式：

**方式一：交接时注入提示**

```python
def make_handoff(from_agent: str, to_agent: str):
    def handoff(state: State):
        return Command(
            goto=to_agent,
            update={"messages": [HumanMessage(
                f"[{from_agent} → {to_agent}] 请接手处理用户最新诉求。"
            )]},
        )
    return handoff
```

**方式二：子 Agent 只看最近 N 条**

```python
def order_agent_node(state: State):
    trimmed = trim_messages(state["messages"], max_tokens=2000,
                            token_counter=llm, strategy="last")
    return order_agent.invoke({"messages": trimmed})
```

生产环境建议**方式二为主**——子 Agent 的上下文越干净，判断越准。

## 五、防死循环：主管最容易犯的错

主管在 A → B → A → B 之间反复横跳，是最常见的故障。

**三把锁**：

```python
class SupervisorState(MessagesState):
    next: str
    hops: int = 0                          # 转手次数

def supervisor_node(state: SupervisorState) -> Command:
    if state.get("hops", 0) >= 6:
        return Command(goto="__end__", update={
            "messages": [AIMessage("问题较复杂，已转人工客服处理。")]
        })

    decision = llm.with_structured_output(Route).invoke(...)
    return Command(goto=..., update={"hops": state.get("hops", 0) + 1, "next": decision.next})
```

三把锁分别是：

1. **轮次上限**（`hops`）——硬止损；
2. **禁止立即回跳**——记录上一个执行者，不允许连续回到同一个人；
3. **状态感知**——把"已经做过什么"写进系统提示，让主管知道哪些路走过了：

```python
history = "\n".join(f"- {m}" for m in state["visited"])
prompt = f"{SUPERVISOR_PROMPT}\n\n已完成步骤：\n{history}\n不要重复指派已完成的任务。"
```

## 六、主管要不要"能干活"

有两种流派：

| 流派 | 主管职责 | 优点 | 缺点 |
|---|---|---|---|
| 纯调度 | 只决定下一跳 | 职责单一、好调试 | 简单问题也要绕一圈 |
| 混合 | 能自己回答简单问题 | 快 | 容易出现"什么都要自己做" |

推荐**纯调度 + 一个 `general_agent` 兜底**——简单问题交给通用专员，主管保持纯调度。这样主管的提示词可以写得很短很硬，稳定性最高。

## 七、和 Swarm 的区别

| | Supervisor | Swarm |
|---|---|---|
| 拓扑 | 中心辐射 | 网状直连 |
| 决策者 | 主管 | 当前 Agent |
| 上下文 | 全局可见 | 交接时传递 |
| 适用 | 明确分工、需要审计 | 交接灵活、链条长 |

**需要审计和可控性就选 Supervisor，需要灵活协作就选 Swarm。**大部分客服、企业流程场景，Supervisor 更合适。

## 八、常见坑

**① 子 Agent 的提示词写得太"礼貌"。**
写"你可以帮助用户解决订单问题"，子 Agent 会去回答任何问题。要写死边界："**只**处理订单查询和地址修改，其他一律回复不归我管。"

**② 主管没有"结束"这个概念。**
必须显式给一个 `FINISH`/`__end__` 选项，否则它会一直找人。

**③ 消息历史无限增长。**
多轮转手后，`messages` 会非常长。主管节点建议只喂**最近 6 条**，并配一条固定的任务描述。

**④ 忽略 `reason` 字段。**
让主管输出选择理由，出问题时能一眼看出它为什么这么选。这个字段调试价值极高。

**⑤ 状态键命名冲突。**
多个子 Agent 共用一个 State 时，`next`、`status` 这类通用名很容易撞。给每个键加前缀（`order_status`、`refund_status`）。

## 九、一个可直接用的骨架

```python
def build_supervisor(members: dict[str, CompiledGraph], llm, checkpointer):
    state = SupervisorState
    b = StateGraph(state)
    b.add_node("supervisor", make_supervisor_node(llm, list(members)))
    for name, agent in members.items():
        b.add_node(name, agent)
        b.add_edge(name, "supervisor")
    b.add_edge(START, "supervisor")
    return b.compile(checkpointer=checkpointer)

graph = build_supervisor(
    {"order_agent": order_agent, "refund_agent": refund_agent, "logistics_agent": logistics_agent},
    llm, checkpointer,
)
```

**加新专员 = 往字典里加一项**，主管的其他逻辑不用动。这是 Supervisor 架构最大的工程优势。
