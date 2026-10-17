# Agent 崩溃后怎么接着跑：Checkpoint 与重放

长任务跑到一半，进程崩了——OOM、Pod 重启、部署发版、或者一句未捕获的异常。**这时候最贵的不是崩溃本身，是「已经做完的一半工作全部作废」。**

一个跑 20 分钟的任务，第 18 分钟挂了，重跑要再花 20 分钟——用户等了 38 分钟。如果有 checkpoint，续跑只要 2 分钟。

这篇讲清楚：什么该存、怎么存、恢复时要处理哪些坑，以及一套和框架无关的实现思路。

---

## 一、为什么 Agent 特别容易丢进度

### 1.1 Agent 的状态是「散落各处」的

一个传统请求处理，状态就是几个局部变量，函数栈退了就没了，重来成本低。Agent 的状态完全不是：

```
任务状态        → 内存里的对象
LLM 对话历史    → 内存里的 messages 列表
已完成的步骤产出 → 变量、临时文件
工具调用的副作用 → 已经发生的写操作（外部世界）
```

**前三个可以重建，第四个不能。** 这就是恢复的核心难点。

### 1.2 崩溃的两种性质

**崩溃在「纯计算」阶段**：只是丢了中间变量，重跑即可，没有副作用损失。

**崩溃在「有副作用」的阶段**：比如刚发了邮件、刚写了数据库、刚扣了额度。这时候恢复不能简单重跑——会重复发送、重复扣费。

**区分这两类，是设计恢复机制的前提。**

### 1.3 三个必须回答的问题

1. **存什么**：哪些状态是「丢了就不能继续」的
2. **何时存**：什么时候写 checkpoint（太频费性能，太疏丢进度）
3. **怎么恢复**：重新执行时，哪些跳过、哪些补偿、哪些必须人工介入

---

## 二、Checkpoint 存什么

### 2.1 五类必存内容

```python
@dataclass
class Checkpoint:
    task_id: str
    version: int                    # 单调递增，恢复时取最新
    status: str                     # running / paused / failed
    # 1. 计划与进度
    plan: list[Step]
    completed_steps: dict[int, StepResult]    # id → 结果
    # 2. 上下文（压缩后的关键部分）
    context_summary: str
    full_messages: list[dict] | None          # 可选，成本高
    # 3. 副作用日志（WAL）
    side_effects: list[SideEffectRecord]
    # 4. 资源使用
    tokens_used: int
    started_at: str
    updated_at: str
```

**`side_effects` 是恢复正确性的核心**，单独一节讲。

### 2.2 什么可以不存

- **完整的原始工具输出**：太大。存摘要 + 保留原始数据的路径引用
- **临时的中间推理草稿**：除非任务需要「思考连续性」，否则可以丢
- **可重新计算的东西**：比如「当前是第几步」可以从 plan + completed_steps 推出来

**判据：丢了它，恢复后还能不能继续？** 能，就别存。

### 2.3 上下文的存法

完整对话历史可能几万 token，每次 checkp 都存，存储和写入开销都大。三种策略：

```python
# 策略一：只存摘要（最省）
context_summary = summarize(full_messages)
# 恢复时用摘要重建上下文 —— 有损，可能漏细节

# 策略二：存关键消息，丢弃过程消息
context_summary = extract_key_turns(full_messages)
# 保留「决策」「结论」「工具结果摘要」，丢弃「试错」「重试」

# 策略三：全量存（最贵，最准）
context_summary = serialize(full_messages)
# 适合任务步数少、单步重要的场景
```

**我的默认选择是策略二**：保留关键决策点。实践中试错过程对恢复后的继续执行价值很低，而结论和方法论价值很高。

---

## 三、副作用日志：恢复安全的基石

### 3.1 什么是副作用

任何**改变外部世界**的动作：

- 发消息（邮件、IM、Webhook）
- 写数据（数据库、文件系统、S3）
- 调用有副作用的接口（下单、退款、创建资源）
- 消耗额度（LLM token 计费、API 调用次数）

**读操作不算**。读操作重复无害，副作用操作重复有害。

### 3.2 WAL 模式：先记意图，再执行

```python
class SideEffectLog:
    def record_intent(self, step_id: int, action: str, params: dict, idem_key: str):
        """副作用执行【前】调用。"""
        entry = {
            "step_id": step_id,
            "action": action,
            "params": params,
            "idem_key": idem_key,
            "status": "pending",        # pending → done / failed / rolled_back
            "ts": now(),
        }
        self.store.append(entry)
        return entry.id

    def mark_done(self, entry_id: str, result):
        self.store.update(entry_id, status="done", result=result)

    def mark_failed(self, entry_id: str, error):
        self.store.update(entry_id, status="failed", error=error)
```

**为什么必须先记意图**：如果先执行后记录，崩溃发生在这两者之间，你就永远不知道「那步到底做没做」。意图日志的存在让你能回答这个问题。

### 3.3 恢复时怎么处理 pending 副作用

```python
def resolve_pending_side_effects(task_id: str) -> list[dict]:
    """恢复时调用。返回需要处理的状态不明的副作用。"""
    log = SideEffectLog.for_task(task_id)
    pending = log.find(status="pending")
    ambiguous = []

    for entry in pending:
        # 幂等的操作：直接重放（安全）
        if is_idempotent(entry):
            result = replay(entry)
            log.mark_done(entry.id, result)
        else:
            # 非幂等：状态不明，不能猜
            ambiguous.append({
                "step_id": entry.step_id,
                "action": entry.action,
                "params": entry.params,
                "reason": "非幂等操作且状态未知，需人工确认是否已执行",
            })

    return ambiguous
```

**这是整篇文章最重要的一段逻辑。** 规则：

- **幂等副作用** → 重放安全（有幂等键去重）
- **非幂等副作用状态不明** → **绝不自动处理**，挂起等人工

宁可不自动恢复，也不能盲目重放一个「可能已经发出去的钱」。

### 3.4 幂等键设计

让 WAL 能安全重放的前提：

```python
# 给每个副作用操作一个确定性的幂等键
def idem_key_for(step_id: int, action: str, params: dict) -> str:
    # 同一 task + 同一 step + 同一参数 → 同一 key
    raw = json.dumps({"task": task_id, "step": step_id, "action": action,
                      "params": params}, sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()
```

**工具侧要支持幂等键**（大部分成熟的内部服务都支持 `Idempotency-Key` header，第三方支付接口也普遍支持）。不支持的老接口，就按非幂等处理——恢复时挂起。

---

## 四、什么时候写 Checkpoint

### 4.1 三种时机

```python
class CheckpointPolicy:
    # 1. 步进式：每个步骤完成后
    def after_step(self, step_result):
        save_checkpoint()

    # 2. 时间式：每 N 秒（长步骤防丢太多）
    def periodically(self, interval=30):
        if now() - self.last_checkpoint > interval:
            save_checkpoint()

    # 3. 关键点：重要的里程碑（计划生成后、重要副作用前）
    def on_milestone(self, milestone):
        save_checkpoint(milestone=milestone)
```

**默认组合：步进式 + 关键点。** 时间式用在「单步本身很长」的场景（比如一个工具要跑 5 分钟，期间要有心跳 checkp）。

### 4.2 写入不能阻塞主流程

```python
async def save_checkpoint_async(state):
    # 落库放后台，不阻塞 Agent 推进
    asyncio.create_task(_persist(state))

async def _persist(state):
    async with db.transaction():
        await db.execute("""
            INSERT INTO checkpoints (task_id, version, payload)
            VALUES (:task_id, :version, :payload)
        """, {...})
```

**崩溃风险**：异步写入如果在崩溃前没落盘，最后几秒的进度丢了。**关键 checkp（含副作用意图）必须同步写。** 折中：

- 普通进度 → 异步
- 副作用意图 + 状态变更 → 同步（这些必须可靠）

---

## 五、恢复的完整流程

```python
async def resume_task(task_id: str):
    # 1. 取最新 checkp
    cp = load_latest_checkpoint(task_id)
    if cp is None:
        raise CannotResume("没有找到 checkp，只能从头开始")

    # 2. 清理状态不明的副作用
    ambiguous = resolve_pending_side_effects(task_id)
    if ambiguous:
        return {
            "status": "needs_manual_intervention",
            "ambiguous_side_effects": ambiguous,
            "message": "有非幂等操作状态未知，请人工确认后再恢复",
        }

    # 3. 重建上下文
    context = rebuild_context(cp)

    # 4. 找出下一步
    next_steps = [s for s in cp.plan if s.id not in cp.completed_steps]

    if not next_steps:
        return {"status": "already_completed"}

    # 5. 续跑
    cp.status = "running"
    save_checkpoint(cp)
    return await run_from(cp, next_steps, context)
```

### 5.1 恢复后的第一步：对账

续跑前先核对「声称完成的」和「实际完成的」：

```python
def reconcile(checkpoint) -> list[str]:
    """返回不一致的项。"""
    problems = []
    # checkp 里标 done 的步骤，副作用日志里必须有对应 done 记录
    for step_id, result in checkpoint.completed_steps.items():
        if result.has_side_effect:
            se = side_effect_log.find(step_id=step_id)
            if not se or se.status != "done":
                problems.append(f"步骤 {step_id} 标记完成但副作用未确认")
    return problems
```

**这一步能抓出一类隐蔽 bug**：任务标成功了，副作用其实没成功（比如数据库写入返回了但实际失败了）。恢复时如果不对账，会基于错误的「已完成」状态继续。

---

## 六、框架怎么做

### 6.1 LangGraph 的 Checkpointer

LangGraph 原生支持，接入最简单：

```python
from langgraph.checkpoint.postgres import PostgresSaver

checkpointer = PostgresSaver.from_conn_string("postgresql://...")

graph = builder.compile(checkpointer=checkpointer)

# 每次调用带 thread_id，状态自动持久化
config = {"configurable": {"thread_id": task_id}}
result = graph.invoke({"messages": [...]}, config=config)

# 崩溃后：同样的 thread_id 重新 invoke，自动从上次的状态继续
result = graph.invoke(None, config=config)      # ← 恢复
```

**它的 checkpoint 粒度是「每个 node 执行后」**，比手写的更细。副作用 node 记得自己做成幂等的（在 node 内部判断 thread_id + node 名是否已执行过）。

### 6.2 自研的话记住三点

不用框架的话，最小实现抓住三点：

1. **状态外置**（每次 checkp 写库，版本号递增）
2. **副作用先记 WAL**
3. **恢复先对账 + 处理 pending，再续跑**

其它都是优化。**先有这三样，再谈断点续跑的体验。**

---

## 七、什么时候值得做

和别的高级特性一样，有明确边界。

### 7.1 值得的信号

- 任务运行 **> 2 分钟**（重跑成本高）
- 有**不可逆副作用**（发钱、发消息、生产写库）
- 部署会**滚动重启**（Pod 重启丢状态）
- 用户可能**中途来接手**（换个设备继续）
- 任务**经常因外部抖动失败**（超时重试场景，checkp 让重试从断点开始，省一大截）

### 7.2 不值得的信号

- 秒级返回的单轮交互
- 纯读任务（重跑零成本，反而简单）
- 任务短且稳定，部署频率低

### 7.3 最小可用版

如果现在就要做，优先级：

1. **WAL + 幂等键**（没有这个，恢复不安全）
2. **关键点 checkp**（计划生成后、重要步骤后、副作用前后）
3. **恢复对账**（标完成的 vs 副作用日志）
4. **自动续跑**（幂等的自动走，非幂等的挂起）
5. 时间式 checkp + 心跳（长步骤场景）

**第 1、2 项不做，后面都是空谈。**

---

## 八、常见误区

**误区一：恢复 = 重新跑一遍。** 副作用会重复。要么幂等重放，要么从断点续。

**误区二：先执行副作用，再记录。** 顺序反了，崩溃在中间就丢失真相。**必须先记意图。**

**误区三：非幂等操作状态不明时自动重放。** 这是最危险的。挂起等人工，别猜。

**误区四：checkp 全异步。** 普通进度可以异步，但副作用意图和状态变更必须同步落盘。

**误区五：不对账就续跑。** 「标完成但副作用未确认」的步骤会被跳过，基于错误状态继续。

**误区六：存整个上下文。** 全量 messages 又大又贵，多数场景存「关键决策点摘要」就够。

**误区七：忘了并发写。** 同一 task 多个 worker 同时 checkp 会互相覆盖。用版本号或乐观锁。

---

## 小结

- Agent 丢进度的根本原因是**状态散落四处**，而其中「已发生的副作用」无法通过重跑重建。
- Checkp 存五类：**计划与进度、上下文摘要、副作用 WAL、资源用量、时间戳**。完整上下文通常太贵，存关键决策点。
- **WAL 模式（先记意图再执行）是恢复安全的地基**，顺序反了就丢失真相。
- 恢复时**先处理 pending 副作用**：幂等 → 重放；**非幂等状态不明 → 挂起等人工，绝不盲猜**。
- 恢复第二步是**对账**：标记完成的步骤，副作用日志必须有对应记录，防止基于错误状态继续。
- LangGraph 的 Checkpointer 开箱即用（按 node 粒度）；自研抓住三点：状态外置、副作用先记 WAL、恢复先对账。
- 值得做的信号：任务 > 2 分钟、有不可逆副作用、部署会重启。**先做 WAL + 幂等键，再做 checkp**，顺序不能反。

崩溃不可怕，可怕的是「崩了就得从头再来」。Checkpoint 和 WAL 就是把「从头再来」变成「接着跑」的两个零件——而它们的前提，是你在**动手之前**就把副作用记下来。
