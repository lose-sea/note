# LangGraph 断点续跑：任务挂了之后，怎么接着跑而不是从头跑

> 一个跑了 12 分钟的 Agent 任务，在第 11 分钟因为外部 API 抖动失败。
> 没有持久化 → 重跑 → 又跑到第 11 分钟 → 又抖动。
>
> 这篇讲 LangGraph 的持久化执行（durable execution）怎么用。

## 一、没有持久化时会发生什么

LangGraph 的图执行默认是**内存态**的：跑到哪一步、状态是什么，都在进程里。进程一挂，全没了。

对短任务（< 5 秒）这不是问题。但一旦出现这类节点：

- 调用了慢接口（30 秒以上）
- 调用了有副作用的操作（发邮件、扣款、写库）
- 需要人工审批（可能等几小时）

**"重跑"就不再是免费的**——它会重复副作用。

## 二、持久化的两块拼图

LangGraph 的持久化由两个组件构成：

```
checkpointer      → 存"图的状态快照"（每个 super-step 后）
store             → 存"跨线程的长期数据"（可选）
```

`checkpointer` 是重点。它让图变成"**可回放、可恢复**"的：

```python
from langgraph.checkpoint.sqlite import SqliteSaver

with SqliteSaver.from_conn_string("checkpoints.db") as checkpointer:
    graph = builder.compile(checkpointer=checkpointer)

    config = {"configurable": {"thread_id": "task-001"}}
    graph.invoke({"input": "..."}, config=config)
```

`thread_id` 是**恢复的钥匙**——同一个 `thread_id` 再次调用，会从上次的状态继续。

## 三、断点续跑的最小实现

```python
import uuid

def run_task(task_input: dict, resume: bool = False, thread_id: str | None = None):
    tid = thread_id or str(uuid.uuid4())
    config = {"configurable": {"thread_id": tid}}

    if resume:
        # 传 None 表示"接着上次的状态跑"
        result = graph.invoke(None, config=config)
    else:
        result = graph.invoke(task_input, config=config)

    return tid, result
```

第一次调用：

```python
tid, _ = run_task({"query": "分析这批数据"}, resume=False)
# 假设这里崩了
```

恢复：

```python
tid, result = run_task(None, resume=True, thread_id=tid)
```

**传 `None` 是关键**。传新的输入会覆盖初始状态，等于重跑。

## 四、检查点是什么时候写的

理解写入时机，才能理解"从哪恢复"。

LangGraph 的执行单位是 **super-step**（超步）——可以理解为"一轮并行节点全部执行完"。每个 super-step 结束后，状态会写入检查点：

```
[节点 A] ──检查点──> [节点 B, C] ──检查点──> [节点 D] ──检查点──> END
```

所以恢复的粒度是**节点级别**：已经完成的节点不会重新执行。

验证一下：

```python
for cp in graph.get_state_history(config):
    print(cp.config["configurable"]["checkpoint_id"], cp.next)
```

输出类似：

```
1ef7...  ('node_b',)
1ef6...  ('node_a',)
1ef5...  ()
```

`next` 为空元组的那条是最终状态。

## 五、幂等：比持久化更重要的事

有了检查点，**已经完成的节点不会重跑**——但这只对"干净地完成并写入了检查点"的情况成立。

如果节点执行到一半、副作用已发生、但检查点还没写，恢复时这个节点**会重跑**。所以**有副作用的节点必须幂等**。

```python
def send_email_node(state: State):
    order_id = state["order_id"]

    # 幂等键：同一个订单只发一次
    if already_sent("email", order_id):
        return {"email_sent": True}

    send_email(state["to"], state["body"])
    mark_sent("email", order_id)          # 先写标记，再算完成
    return {"email_sent": True}
```

**模式：先检查标记 → 执行 → 写标记**。标记可以放 Redis、数据库，随便哪个。

更严格的写法是**把幂等键和副作用放在同一个事务里**：

```python
def charge_node(state: State):
    with db.transaction():
        if db.exists("charges", key=state["order_id"]):
            return {"charged": True}      # 已扣过，直接返回
        pay_gateway.charge(state["order_id"], state["amount"])
        db.insert("charges", key=state["order_id"], status="ok")
    return {"charged": True}
```

## 六、重试策略：节点级 vs 图级

**节点级重试**适合"瞬时错误"：

```python
from langgraph.pregel import RetryPolicy

builder.add_node(
    "fetch_data",
    fetch_data,
    retry=RetryPolicy(
        max_attempts=3,
        initial_interval=1.0,
        backoff_factor=2.0,
        retry_on=ConnectionError,
    ),
)
```

**图级恢复**适合"进程挂了"——重启后带着 `thread_id` 重新 `invoke(None)`。

两者互补：节点级处理"我能自己救回来"的错误；图级处理"进程都不在了"的情况。

## 七、长时间等待：不占线程的做法

人工审批可能等几小时，`invoke` 一直阻塞显然不行。用 `interrupt` + 恢复：

```python
from langgraph.types import interrupt, Command

def approve_node(state: State):
    decision = interrupt({"need": "approve", "amount": state["amount"]})
    return {"approved": decision["approved"]}

def start(config):
    # 执行到 interrupt 会返回，不阻塞
    for _ in graph.stream({"amount": 1000}, config=config, stream_mode="updates"):
        pass
    return graph.get_state(config).next    # ('approve_node',)

def resume(config, approved: bool):
    return graph.invoke(Command(resume={"approved": approved}), config=config)
```

**图在 `interrupt` 处退出（不是挂起线程），状态存进检查点。**几小时后调用 `resume` 即可继续。

这是"长任务"和"Web 服务"能共存的关键。

## 八、生产环境该用哪个 checkpointer

| 实现 | 适用 | 注意 |
|---|---|---|
| `InMemorySaver` | 测试 | 进程重启即失 |
| `SqliteSaver` | 单机、开发 | 并发写有锁竞争 |
| `PostgresSaver` | 生产 ✅ | 需要 `setup()` 建表 |
| `RedisSaver` | 高频短任务 | TTL 要设 |

Postgres 版本必须初始化：

```python
from langgraph.checkpoint.postgres import PostgresSaver

with PostgresSaver.from_conn_string(DB_URI) as cp:
    cp.setup()                 # 建表，只需执行一次
    graph = builder.compile(checkpointer=cp)
```

## 九、清理：检查点会一直堆积

每个 super-step 一个检查点，一个长任务几百条很正常。**必须定期清理**：

```python
def cleanup_old_checkpoints(days: int = 7):
    cutoff = time.time() - days * 86400
    # 保留每个 thread 的最后一条（用于诊断），其余删掉
    db.execute("""
        DELETE FROM checkpoints
        WHERE thread_id IN (
            SELECT thread_id FROM checkpoints
            GROUP BY thread_id HAVING MAX(created_at) < %s
        )
    """, (cutoff,))
```

同时给业务侧一个"任务结束就删"的钩子，别让已完结的任务永久占库。

## 十、几个坑

**① `thread_id` 必须全局唯一且可追溯。**
用业务 ID（`order-20260115-001`）比 UUID 好——出问题时能直接查。

**② 别忘了 `checkpoint_ns`。**
使用子图时，检查点是分层存的。手动指定 `checkpoint_id` 恢复时要带上 `checkpoint_ns`。

**③ 状态里别放不可序列化的对象。**
`checkpointer` 要序列化整个 State。连接对象、lambda、文件句柄放进去会直接报错。**状态里只放数据**（字典、列表、字符串、消息对象）。

**④ 恢复不是"时间旅行"。**
`invoke(None)` 恢复的是**最后一个检查点**。想回到更早的检查点要用 `checkpoint_id` 显式指定——那是调试功能，不是生产恢复手段。

## 十一、小结

持久化执行 = **检查点 + 幂等 + 重试**，三件事缺一不可：

```
检查点   → 知道"跑到哪了"
幂等     → 保证"重跑无害"
重试     → 处理"临时故障"
```

只做检查点不做幂等，恢复时重复扣款；只做幂等不做检查点，恢复时从头跑一遍。**三者配套，长任务才敢上生产。**
