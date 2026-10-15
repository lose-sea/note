# LangGraph 审批流：把人放在关键节点上，而不是事后救火

> Agent 自动给客户发了 8 折优惠券。等你看报表发现时，已经发出 2000 张。
>
> 正确的做法不是"事后补偿"，而是**把关键动作卡在人工审批上**。
> 这篇讲怎么用 LangGraph 做一个真正可用的审批流。

## 一、哪些动作必须卡审批

不是所有动作都要审批——那样 Agent 就没意义了。判断标准三条：

| 标准 | 例子 |
|---|---|
| **不可逆** | 扣款、发券、删数据、发邮件 |
| **有金额/额度** | 退款 > 500 元、折扣 > 8 折 |
| **有合规要求** | 涉及个人信息、合同条款、医疗建议 |

逆命题同样重要——**"查询类"动作永远不审批**。查订单、查物流、查余额，卡审批只会让流程变得没法用。

## 二、最简实现：`interrupt` + `Command(resume=...)`

```python
from langgraph.types import interrupt, Command
from langgraph.checkpoint.postgres import PostgresSaver

def execute_refund(state: State):
    """执行退款（高风险动作）"""
    decision = interrupt({
        "type": "approval_required",
        "action": "refund",
        "order_id": state["order_id"],
        "amount": state["amount"],
        "reason": state["refund_reason"],
    })

    if not decision.get("approved"):
        return {"status": "rejected", "reject_reason": decision.get("note", "")}

    return {"status": "executed", "refund_id": do_refund(...)}
```

执行流程：

```python
config = {"configurable": {"thread_id": "refund-order-20260115-001"}}

# 第一次调用：跑到 interrupt 处停下
for chunk in graph.stream({"order_id": "...", "amount": 800}, config=config, stream_mode="updates"):
    if "__interrupt__" in chunk:
        payload = chunk["__interrupt__"][0].value
        print("需要审批：", payload)
        # 把 payload 推给审批系统

# 审批人点了"同意"
graph.invoke(Command(resume={"approved": True, "operator": "zhangsan"}), config=config)
```

**`interrupt` 不是阻塞线程，而是让图"干净地退出"**，状态存进检查点。几个小时后审批完再恢复，完全没问题。

## 三、审批队列：把待办可视化的三个字段

`interrupt` 只负责"停"。要在前端展示待办队列，还需要索引。**给每个需审批的任务打上可查询的标签**：

```python
def execute_refund(state: State):
    decision = interrupt({
        "type": "approval_required",
        "action": "refund",
        "priority": "high" if state["amount"] > 1000 else "normal",
        "amount": state["amount"],
        "requester": state["user_id"],
        "created_at": datetime.now().isoformat(),
        "expires_in": 86400,                 # 24 小时未审批自动过期
        "summary": f"为用户 {state['user_id']} 退款 {state['amount']} 元：{state['refund_reason']}",
    })
    ...
```

然后从检查点库里查出"所有停在 `execute_refund` 的任务"：

```python
def list_pending_approvals(limit: int = 50):
    """列出所有等待审批的任务"""
    rows = db.query("""
        SELECT thread_id, checkpoint, created_at
        FROM checkpoints
        WHERE checkpoint->'next' ? 'execute_refund'
        ORDER BY created_at DESC
        LIMIT %s
    """, (limit,))

    out = []
    for r in rows:
        state = graph.get_state({"configurable": {"thread_id": r["thread_id"]}})
        # interrupt 的 payload 在 tasks 里
        for task in state.tasks:
            if task.interrupts:
                out.append({
                    "thread_id": r["thread_id"],
                    "created_at": r["created_at"],
                    **task.interrupts[0].value,
                })
    return out
```

这份列表就是**审批工作台的数据源**。

## 四、审批结果要写回业务系统

审批动作本身要留痕——**谁批的、什么时候批的、批了什么**：

```python
def approve(thread_id: str, operator: str, note: str = ""):
    config = {"configurable": {"thread_id": thread_id}}

    # 1. 记录审计日志
    audit_log.write({
        "thread_id": thread_id,
        "operator": operator,
        "action": "approve",
        "note": note,
        "at": datetime.now(),
    })

    # 2. 恢复图执行
    result = graph.invoke(
        Command(resume={"approved": True, "operator": operator, "note": note}),
        config=config,
    )
    return result
```

审计日志**不要只存在 LangGraph 的检查点里**——那是技术状态，不是业务审计记录。合规检查要的是独立的、不可篡改的审计表。

## 五、超时与升级：审批最容易被忽略的部分

审批人没看怎么办？三种策略：

**策略一：超时自动拒绝**（最安全）

```python
def check_expired():
    """定时任务：把超时的审批自动拒绝"""
    for item in list_pending_approvals():
        if time.time() - parse(item["created_at"]) > item.get("expires_in", 86400):
            graph.invoke(
                Command(resume={"approved": False, "note": "审批超时自动拒绝"}),
                config={"configurable": {"thread_id": item["thread_id"]}},
            )
```

**策略二：超时升级**（审批人的上级接手）

```python
def escalate(item):
    if item["priority"] == "high":
        notify(item["manager"], f"高优先级审批超时：{item['summary']}")
```

**策略三：分级审批**（金额越大层级越高）

```python
class State(TypedDict):
    amount: float
    approvals: Annotated[list[dict], add]

def required_level(amount: float) -> int:
    if amount < 500: return 1      # 组长
    if amount < 5000: return 2     # 主管
    return 3                        # 总监

def approval_node(state: State):
    level = required_level(state["amount"])
    got = len(state.get("approvals", []))

    if got >= level:
        return {"status": "approved"}

    decision = interrupt({
        "type": "approval_required",
        "required_level": level,
        "current_level": got + 1,
        "amount": state["amount"],
    })

    if not decision["approved"]:
        return {"status": "rejected"}

    return {"approvals": [{"by": decision["operator"], "at": now()}]}
```

`got >= level` 这个判断让**同一节点可以被多次中断**，逐级审批。这是分级审批最优雅的实现方式。

## 六、"改后再批"：允许审批人修改

实际业务里，审批人经常希望"改一下再批"——比如把 800 元改成 500 元。

```python
decision = interrupt({...})

if decision["action"] == "modify":
    return Command(
        goto="execute_refund",
        update={"amount": decision["new_amount"], "modified_by": decision["operator"]},
    )
```

但要注意**别让"修改"绕过校验**。改后的值必须重新走一遍规则检查：

```python
def validate_amount(state):
    if state["amount"] > state["customer_max_refund"]:
        return Command(goto="reject", update={"reason": "超出该客户可退上限"})
    return Command(goto="approval_node")
```

## 七、批量化审批：一次批一堆

客服场景里，待审批项可能有几百条。一条条点太低效。

```python
def batch_approve(thread_ids: list[str], operator: str, action: str = "approve"):
    """批量审批：先全量校验，再逐条恢复"""
    results = {}
    for tid in thread_ids:
        state = graph.get_state({"configurable": {"thread_id": tid}})
        # 校验：状态必须还停在待审批节点，避免重复审批
        if not any(t.interrupts for t in state.tasks):
            results[tid] = "skipped: 不在待审批状态"
            continue
        try:
            graph.invoke(Command(resume={"approved": action == "approve", "operator": operator}),
                         config={"configurable": {"thread_id": tid}})
            results[tid] = "ok"
        except Exception as e:
            results[tid] = f"failed: {e}"
    return results
```

关键：**恢复前检查任务是否还停在待审批节点**。两个人同时点同一条，没有这个检查会执行两次。

## 八、几个必须注意的点

**① 审批人的身份必须服务端确定。**
`operator` 绝不能从请求体里直接取。要用 session/token 映射出的用户身份——否则可以伪造审批人。

**② 审批链要能"撤回"。**
审批后发现错了怎么办？留一个回滚节点，或者至少在审计里标记"已撤销"。

**③ 状态里不要放"等待中"这种瞬态标记。**
判断"是否在等待审批"应该查 `state.tasks` 里的 `interrupts`，而不是自己维护一个 `status = waiting` 字段（进程崩了它就不准了）。

**④ 审批提示要写清楚"到底批什么"。**
`{"action": "refund"}` 太模糊。要写：谁、多少钱、什么理由、影响范围。审批人看不懂的提示，等于没做审批。

**⑤ 别把"人工确认"做成必选项塞满全流程。**
每两步卡一个审批，用户会直接弃用。**只在不可逆和高风险的节点设卡**。

## 九、小结

一个能上生产的审批流包含五件事：

```
interrupt 停住   →  检查点存状态
可查询的索引     →  审批工作台能看到
审计日志         →  谁批的能追溯
超时策略         →  没人批不会永远挂着
分级/批量        →  符合真实业务节奏
```

LangGraph 给你的是前两件（`interrupt` + `checkpointer`），**后三件是你自己要补的业务能力**。这后三件，才是审批流能不能落地的分水岭。
