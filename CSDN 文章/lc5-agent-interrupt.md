# Agent 的中断与恢复：跑到一半能停下来吗

一个 Agent 接到「跑全量数据迁移」的任务，跑了 20 分钟，你发现参数配错了。你点了停止——然后呢？

**如果它不能保留进度，你就得从头再来。** 如果它保留了进度但参数是错的，恢复出来的结果就是错的。如果它「停了」但底层子进程还在跑，你得到的是一个僵尸任务。

长任务 Agent 的中断与恢复，比听起来复杂得多。这一篇讲清楚：中断有哪几种、恢复需要什么、以及怎么设计才能既安全又实用。

---

## 一、为什么中断比想象的难

### 1.1 一次中断到底要停掉多少东西

一个「跑全量迁移」的任务，同时可能跑着：

- 一个 Plan-and-Execute 的主循环
- 3 个子任务线程（并发跑）
- 每个子任务里的 LLM 调用（流式响应中）
- 2 个 HTTP 请求（正在等远端返回）
- 1 个本地执行器进程（正在跑生成的数据处理代码）
- 一个状态写库的后台任务

**点了「停止」，上面每一个都要停。** 只停主循环，下面的还在跑——这就是僵尸任务。

### 1.2 中断后的三种可能状态

```
        中断
    ┌────┴────┐
    ▼         ▼
 放弃       暂停
    │         │
    ▼         ▼
 丢弃所有    保留现场
 进度          │
              ├─► 改参数后继续（热恢复）
              └─► 稍后继续（冷恢复，需持久化）
```

**暂停才是难点**，因为它要求「现场」是可保存的。现场包括：任务状态、已完成的结果、计划、中间产物、以及**下一步该干什么**。

### 1.3 恢复 ≠ 重跑

很多人把恢复做成「重新执行整个任务，跳过已完成的步骤」。这有两个问题：

1. **副作用会重复**。已完成的步骤里如果有「发邮件」「写数据库」，重跑就再发一次、再写一次。
2. **慢**。如果 80% 的步骤已完成，重跑意味着 80% 的时间白花。

**正确的恢复是「从断点继续」**，而断点的定义取决于副作用是否幂等。

---

## 二、中断的几种类型

按来源分，处理策略完全不同。

### 2.1 用户主动中断（优雅中断）

用户点「停止」或「暂停」。这是最理想的情况——你有机会做清理。

```python
class InterruptibleExecutor:
    def __init__(self):
        self._cancel = threading.Event()

    def request_stop(self, graceful: bool = True):
        self._cancel.set()
        self._graceful = graceful

    def run_step(self, step):
        for sub in self._running_subs:
            sub.check_cancel(self._cancel)
        if self._cancel.is_set():
            raise GracefulStop("用户请求停止")
        return self._execute(step)
```

**关键：每一层都要能感知到取消信号。** 主循环取消、子线程取消、正在等的 HTTP 也要能取消。用 `threading.Event` 或 `asyncio.CancelledError`。

### 2.2 超时中断（系统判定）

预算超了、步骤超时、总时长超。这类中断必须**在进入前就设好上限**：

```python
@dataclass
class Limits:
    max_steps: int = 50
    max_tokens: int = 400_000
    max_seconds: int = 1800
    max_subtasks: int = 10
```

触发时不能直接抛异常完事——要留下**可恢复的现场**，否则超时中断等于浪费全部投入。

### 2.3 异常中断（被动）

LLM 调用失败、工具报错、进程崩溃。这类最容易出现「半完成」状态：步骤 1 成功了，步骤 2 失败在中间。

**处理原则：任何副作用操作前先记录意图**（见第三节的 WAL），失败后靠日志判断「刚才那步到底做没做」。

### 2.4 部署中断（进程被杀）

Pod 重启、OOM、发版。**这种最残酷——内存里的状态全丢。** 不持久化就什么都没了。

---

## 三、恢复的技术基础：持久化

### 3.1 状态外置是前提

内存里的 Agent 状态不能作为唯一真相来源。必须外置：

```python
class TaskState(BaseModel):
    task_id: str
    status: Literal["running", "paused", "completed", "failed", "aborted"]
    plan: list[Step]
    step_results: dict[int, StepResult]     # 已完成的步骤产出
    context_snapshot: str                    # 压缩后的关键上下文
    created_at: datetime
    updated_at: datetime
    checkpoint_version: int
```

存到 Postgres / Redis / 到一个文件都行，**关键是每一步完成后立刻写**，不要攒着。

### 3.2 WAL：副作用前的意图日志

这是恢复正确性的核心。**任何有副作用的动作，执行前先写一条「我要做 X」**：

```python
def execute_side_effect(step: Step, wal: WriteAheadLog):
    # 1. 先记意图
    entry = wal.append({
        "step_id": step.id,
        "action": step.action,
        "params": step.params,
        "status": "pending",
        "ts": now(),
    })

    try:
        # 2. 执行
        result = perform(step.action, step.params)
        # 3. 标记完成
        wal.update(entry.id, status="done", result=result)
        return result
    except Exception as e:
        wal.update(entry.id, status="failed", error=str(e))
        raise
```

恢复时：

```python
def recover(task_id: str):
    state = load_state(task_id)
    pending = wal.pending_entries(task_id)     # 意图写了但没写 done 的

    for entry in pending:
        # 这个动作可能已经执行了但没来得及标 done
        if is_idempotent(entry.action):
            replayed = perform(entry.action, entry.params)   # 幂等，重放安全
            wal.update(entry.id, status="done", result=replayed)
        else:
            # 非幂等：不确定是否执行过，必须人工确认
            flag_for_human_review(entry)
            abort_recovery(task_id, reason="非幂等操作状态未知")
    return state
```

**这条规则值得单独记住：非幂等的副作用操作，状态不明时不要盲猜，挂起等人工确认。** 误判为「没执行」会漏掉操作，误判为「已执行」会漏掉补偿，两个都可能出生产事故。

### 3.3 幂等设计

让恢复变简单的根本办法是**让所有操作幂等**：

```python
# ❌ 非幂等
def send_email(to, body):
    smtp.send(...)

# ✅ 幂等（带唯一键 + 去重）
def send_email(to, body, idempotency_key):
    if dedupe_store.seen(idempotency_key):
        return {"status": "already_sent"}
    dedupe_store.mark(idempotency_key)
    smtp.send(...)
```

```python
# ❌ 非幂等
def insert_log(record): db.execute(insert_record, record)

# ✅ 幂等（自然键 upsert）
def insert_log(record):
    db.execute("""
        INSERT INTO logs (biz_key, payload)
        VALUES (:biz_key, :payload)
        ON CONFLICT (biz_key) DO NOTHING
    """, record)
```

**给每个副作用操作设计一个幂等键**，恢复时重放就是安全的。这比任何精巧的恢复逻辑都值钱。

---

## 四、中断的实现：分层取消

### 4.1 一个可取消的任务树

```python
import asyncio

class CancellationToken:
    def __init__(self):
        self._event = asyncio.Event()
    def cancel(self):
        self._event.set()
    def is_cancelled(self) -> bool:
        return self._event.is_set()
    async def throw_if_cancelled(self):
        if self._event.is_set():
            raise asyncio.CancelledError()

class AgentTask:
    def __init__(self, task_id, token: CancellationToken):
        self.task_id = task_id
        self.token = token
        self.subtasks = []

    async def run(self):
        self.token.throw_if_cancelled()
        for step in self.plan:
            if step.depends_on:
                await self.gather(step)          # 并发子任务
            await self.token.throw_if_cancelled()
            result = await self.execute_step(step)
            await self.checkpoint(result)

    async def execute_step(self, step):
        # LLM 调用也是可取消的
        return await asyncio.wait_for(
            self.llm_call(step),
            timeout=step.timeout,
        )
```

三层取消都要覆盖：

1. **步骤之间**：检查 token，取消就不再进下一步
2. **步骤之内**：`asyncio.wait_for` 超时；流式响应要能中断
3. **子任务之间**：把同一个 token 传给所有 `asyncio.create_task`

### 4.2 优雅停止 vs 强制停止

```python
def stop(self, graceful: bool):
    self.token.cancel()
    if graceful:
        # 等当前步骤收尾（最多 5 秒），保存状态，然后退出
        await asyncio.wait_for(self.finish_current_step(), timeout=5)
    else:
        # 直接取消，状态可能不完整
        self.token.cancel(force=True)
    self.save_checkpoint()
```

**UI 上应该提供两个按钮**：停止（优雅）和强制终止。默认优雅，长按或二次确认强制。

一个常见错误：点了停止，主流程停了，但**后台还在跑的子 Agent 没收到取消**。所以 token 必须一路传下去。

---

## 五、恢复的两种形态

### 5.1 热恢复：暂停后接着跑

任务暂停，状态在库里，参数可改。用户改完点「继续」：

```python
async def resume(task_id: str, new_params: dict | None = None):
    state = load_state(task_id)
    if state.status != "paused":
        raise ValueError("只能恢复暂停中的任务")

    # 1. 处理暂停期间产生的副作用（补偿或跳过）
    await replay_pending_wal(task_id)

    # 2. 如果参数变了，重新规划剩余部分
    if new_params:
        state.plan = replan(state, new_params)

    # 3. 从断点继续
    token = CancellationToken()
    state.status = "running"
    save_state(state)
    await AgentTask(task_id, token).run_from(state)
```

**新参数怎么作用到已完成的步骤是个设计难点。** 三种情况：

- 参数只影响未完成步骤 → 直接改剩余 plan
- 参数影响已完成步骤 → 需要重算并标记旧结果失效（要能识别哪些下游结果依赖它）
- 参数影响不可逆的副作用 → **不能恢复，只能放弃重跑**

第三种要在 UI 上明确告知用户，别让他以为「改个参数接着跑」是万能的。

### 5.2 冷恢复：换个进程接着跑

进程被杀后，新进程接手：

```python
def cold_start():
    # 扫描所有 running 但心跳超时的任务
    stale = db.query("""
        SELECT * FROM task_state
        WHERE status = 'running'
        AND updated_at < :threshold
    """, {"threshold": now() - timedelta(minutes=5)})

    for task in stale:
        # 先尝试恢复，恢复不了标记 failed
        try:
            resume(task.id)
        except NonIdempotentState:
            mark_failed(task.id, "非幂等状态需人工介入")
```

**心跳是冷恢复的关键**：没有心跳，你无法区分「任务真的停了」和「任务还在跑只是慢」。心跳间隔 30~60 秒，超时 2~3 个周期判定为僵死。

---

## 六、什么时候值得做

和别的高级特性一样，中断恢复有明确的适用边界。

### 6.1 值得做的信号

- 任务运行时间 **> 2 分钟**（用户等不了，中途想停/改）
- 有**不可逆副作用**（发消息、写库、花钱）
- **部署会重启**（Pod 滚动更新、OOM）
- 任务是**长流水线**（数据迁移、批量生成）
- 用户需要在不同设备/时间点接手

### 6.2 不值得的信号

- 单轮对话、秒级返回 → 中断就是取消，恢复等于重问
- 纯读操作（搜索、查询）→ 没有副作用，重跑零成本
- MVP 阶段 → 先把主流程跑通，持久化后加

### 6.3 最小可用版

如果现在就要做，优先级排序：

1. **状态外置 + 每步 checkp**（否则一切免谈）
2. **幂等键**（让恢复安全）
3. **优雅停止**（用户主动中断）
4. **超时限制**（兜底）
5. **热恢复**（暂停改参继续）
6. **冷恢复 + 心跳**（进程级容错）

**前两项不做，后面全是空中楼阁。**

---

## 七、常见误区

**误区一：把「停止」做成「kill 进程」就完事。** 后台子任务、未完成的副作用、未保存的状态，全都成了隐患。

**误区二：恢复 = 重跑。** 副作用会重复。要么幂等重放，要么改从断点续。

**误区三：副作用状态不明时自动重放。** 非幂等操作必须挂起等人工，盲猜会出事故。

**误区四：没有心跳。** 分不清「停了」和「慢了」。

**误区五：参数改了就直接恢复。** 要判断它影响的是剩余步骤还是已完成步骤。影响已完成且不可逆的，只能放弃。

**误区六：暂停不可取消的子任务。** token 必须传进每一层，包括并发子任务和正在进行的流式调用。

**误区七：只在内存保存状态。** 进程一死全丢。外置存储是前提。

---

## 小结

- 中断要停掉的是**一整棵树**：主循环、子任务线程、进行中的 LLM 调用、HTTP 请求、本地进程。只停主循环 = 僵尸任务。
- 恢复的技术前提是**状态外置**（每步立刻 checkpoint）；恢复的安全前提是**WAL + 幂等**：副作用前先记意图，执行后标完成，恢复时幂等重放、非幂等挂起等人工。
- 中断分四类：用户主动（优雅停）、超时（预设上限）、异常（半完成，靠 WAL 兜）、部署（进程死，靠心跳 + 冷恢复）。
- 热恢复要处理**参数变更的影响范围**——只影响剩余步骤才好办，影响不可逆副作用的只能放弃。
- 落地优先级：**状态外置 → 幂等键 → 优雅停止 → 超时限制 → 热恢复 → 冷恢复**。前两项不做，后面都白搭。
- 适用边界：任务 > 2 分钟、有不可逆副作用、部署会重启、长流水线。单轮对话和纯读操作不值得做。

长任务 Agent 和演示 Demo 的区别，往往就在「能不能停下来、能不能接回去」。这两件事做扎实了，Agent 才敢被用在真正有价值的任务上。
