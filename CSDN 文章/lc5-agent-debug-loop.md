# 本地调试循环：不上线也能复现 Agent 的问题

「这个 bug 只在生产环境出现」——Agent 开发里这句话的频率高得离谱。用户报了一个奇怪的回答，你在本地跑同样的输入，一切正常。

**问题是 Agent 的输出取决于上下文，而上下文在生产里和本地完全不是一回事。** 生产有真实的检索结果、真实的历史对话、真实的用户措辞。本地你只有一句 prompt。

这一篇讲怎么搭一个「生产等价的本地复现环境」，让 bug 在你机器上稳定出现，而不是只能看日志猜。

---

## 一、为什么本地复现不了

### 1.1 三个不等价

**上下文不等价。** 生产上用户已经聊了 20 轮，本地你只有最后一轮。模型看到的输入不同，输出自然不同。

**工具返回不等价。** 生产上调真实接口，数据每天在变。本地你用 mock，mock 的数据和真实分布不一致。

**时间与并发不等价。** 生产上有其它请求、有缓存命中、有并发竞态。本地单机单线程跑，时序问题根本不出现。

### 1.2 「加日志重跑」的局限

最常见的做法是：线上出问题 → 看日志 → 猜哪里错了 → 加日志 → 等下次出现。

问题是：**Agent 的错误往往是上下文相关的**，不是代码 bug。同样的代码，换个输入就不出错。你加十轮日志，可能只是看到「它确实这么选了」，不知道为什么。

**真正需要的是：把生产那一次执行的完整输入，在本地原样重放。**

---

## 二、第一步：完整记录生产执行

复现的前提是记录。**记录的量决定了你能复现多少。**

### 2.1 记录什么

```python
@dataclass
class ExecutionRecord:
    # 身份与输入
    trace_id: str
    task_id: str
    user_id: str
    thread_id: str                    # 多轮对话的关键

    # 完整输入
    system_prompt: str
    messages: list[dict]              # 发给模型的完整消息
    tools_schema: list[dict]          # 当时的工具定义

    # 模型侧
    model_config: dict                # temperature、model 名、max_tokens
    llm_responses: list[dict]         # 每次 LLM 调用的 raw response

    # 工具侧
    tool_calls: list[dict]            # 每次调用的参数
    tool_results: list[dict]          # 每次的返回（含失败）

    # 环境
    env: str                          # prod/staging
    deployed_version: str             # 代码版本
    prompt_version: str               # 提示词版本
    timestamp: str
```

**最容易被漏掉的两项**：`tools_schema`（每次调用的工具定义，因为它在动态变化）和 `deployed_version`/`prompt_version`（版本不同，同样输入行为不同）。

### 2.2 存哪、存多大

```python
# 全量存太贵。分层策略：
# L1: 100% 存元数据 + 输入摘要 + 最终输出 + 分数（便宜，用于统计）
# L2: 失败/低分的存完整 record（用于复现）
# L3: 采样的成功案例存完整 record（用于对比）
```

**「失败案例必须全量存完整 record」**——这是复现的原料。生产上一个失败的完整 JSON，就是你本地复现的全部所需。

### 2.3 脱敏

```python
def sanitize_record(record):
    # token/密钥/个人信息 过滤后再存
    record["messages"] = [redact(m) for m in record["messages"]]
    record["tool_calls"] = [{**c, "args": redact(c["args"])} for c in record["tool_calls"]]
    return record
```

**注意脱敏不能破坏复现**——把用户 query 原文替换成 `[REDACTED]`，复现时模型看到的输入就变了，bug 可能不再出现。折中是：存原文但加密，只在授权的调试环境解密。

---

## 三、第二步：本地重放

### 3.1 录制-重放（Record & Replay）

核心思想：**本地的工具调用不真调外部系统，而是「播」生产上记录的结果。**

```python
class ReplayingToolBox:
    """本地重放用的工具箱：拦截所有调用，返回录制的响应。"""

    def __init__(self, record: ExecutionRecord):
        self.record = record
        self.call_index = 0
        self.calls = record["tool_calls"]
        self.results = record["tool_results"]

    async def call(self, tool_name: str, args: dict) -> dict:
        # 按顺序取出录制的响应
        if self.call_index >= len(self.results):
            raise ReplayMismatch("录制的调用次数用尽，Agent 走了不同路径")
        recorded = self.results[self.call_index]
        self.call_index += 1

        # 校验：本地这次调用的参数，和当时一致吗？
        if recorded["args"] != args:
            log.warning(f"重放分歧：expected {recorded['args']}, got {args}")
        return recorded["result"]
```

**重放的价值**：你可以在本地修改代码/提示词，然后用同一套录制的工具结果重跑，看行为变化。

**「重放分歧」检测很有用**——如果 Agent 在本地走到第 3 步时调用了 `search_orders`，而生产记录里第 3 步调用的是 `query_order`，说明你的改动已经改变了行为。这是个明确的信号。

### 3.2 Mock 模式（没有录制数据时）

```python
MOCK_MODE = os.environ.get("AGENT_MOCK", "false") == "true"

async def query_order(order_id: str) -> dict:
    if MOCK_MODE:
        return {"order_id": order_id, "status": "shipped", "eta": "2026-10-20"}
    # 真实调用
    ...
```

**Mock 的问题**：返回的是「理想数据」，不是「生产真实数据」。Agent 对脏数据（空值、超长字段、异常格式）的处理，mock 测不出来。

**所以 Mock 只能用于单元测试，复现生产问题必须用重放。**

### 3.3 一个完整的复现脚本

```python
# reproduce.py <trace_id>
import sys, json, asyncio

async def main():
    trace_id = sys.argv[1]
    record = load_record(trace_id)            # 从存储加载
    sanitized = sanitize_record(record)

    # 1. 重建环境
    toolbox = ReplayingToolBox(sanitized)
    agent = build_agent(tools=toolbox, env="local-replay")

    # 2. 用当时的完整输入重跑
    result = await agent.run(
        messages=sanitized["messages"],
        system_prompt=sanitized["system_prompt"],
        model_config=sanitized["model_config"],
    )

    # 3. 对比
    print("=== 生产最终输出 ===")
    print(sanitized["final_output"])
    print("=== 本地重跑输出 ===")
    print(result.output)
    print("=== 差异 ===")
    print(diff(sanitized["final_output"], result.output))

    # 4. 保存新的轨迹供对比
    save_trajectory(trace_id + "-local", result.trajectory)

asyncio.run(main())
```

**跑通的标准**：本地重放的轨迹，和生产录制的轨迹**逐步骤一致**。到了这一步，你才算「复现了」。

---

## 四、第三步：本地调试工具箱

复现之后，调试需要一些本地特有的能力。

### 4.1 单步模式

```python
class StepDebugger:
    def __init__(self, agent):
        self.agent = agent

    async def step(self, state):
        """执行一步，然后停下，打印决策依据。"""
        snapshot_before = capture(state)
        action = await self.agent.next_action(state)
        print(f"""
=== 步骤 {state.step} ===
【上下文摘要】{summarize(state.messages)[:500]}
【决策】{action.type}: {action.tool}({action.args})
【原始输出】{action.raw_response}
【可用工具】{[t.name for t in state.tools]}
""")
        return action
```

**「原始输出」是关键**——模型解释它为什么这么选的那段，90% 的 bug 能在里面找到线索。

### 4.2 上下文 diff

改了提示词之后，想看「模型看到的输入变了什么」：

```python
before_messages = run_with(prompt_v1).input_messages
after_messages  = run_with(prompt_v2).input_messages

for i, (b, a) in enumerate(zip(before_messages, after_messages)):
    if b != a:
        print(f"消息 {i} 差异：")
        print(f"  v1: {b['content'][:300]}")
        print(f"  v2: {a['content'][:300]}")
```

**这个 diff 比「跑一遍看输出有没有变」精确得多**——你能看到是输入的哪一部分变了，进而推断为什么输出变了。

### 4.3 确定性模式

Agent 的随机性让复现变难。本地调试时关掉随机源：

```python
# 1. temperature = 0
# 2. 禁用所有 lookbehind randomness
# 3. 时间戳固定
freezegun.freeze_time("2026-10-16 12:00:00")
# 4. 随机数固定
random.seed(42)
```

**注意**：`temperature=0` 不保证完全确定（不同 API 版本、不同后端实现仍有微小差异），但足以让复现稳定。

### 4.4 干预模式

复现后想测试「如果上一步结果不同会怎样」：

```python
# 修改录制数据，测试敏感性
record["tool_results"][2]["result"] = {"status": "empty"}   # 改掉第 3 步返回
result = await replay(record)
# 看 Agent 走什么新路径
```

**这是定位根因的利器**：如果改成「返回空」Agent 就正常了，说明根因是「那个工具返回的脏数据」。

---

## 五、快速回归：本地评测

调完 prompt，不能只靠感觉。**本地跑一遍评测集就是回归测试。**

```python
# eval_local.py —— 提交前必跑
async def main():
    report = await evaluator.run(eval_set="quick", n=30)   # 30 条快速集
    baseline = load_baseline()                              # 上次结果

    if report.completion_rate < baseline.completion_rate - 0.03:
        print(f"⚠️ 完成率下降 {baseline.completion_rate - report.completion_rate:.2f}，")
        print("   请检查改动的 prompt / 工具描述 / 模型配置")
        sys.exit(1)                                        # 拦住提交
    print(f"✓ 完成率 {report.completion_rate:.2f}（基线 {baseline.completion_rate:.2f}）")
```

**和 CI 挂上**：每次改 prompt 或工具定义，跑 30 条快速集，掉太多就拦住。

**快速集的要求**：30 秒内能跑完、覆盖主要场景、包含历史失败案例。**太大会没人跑，等于没有。**

---

## 六、常见误区

**误区一：用 Mock 复现生产问题。** Mock 返回理想数据，Agent 对脏数据的处理 bug 复现不出来。复现必须用**录制重放**。

**误区二：只记录「失败了」，不记录完整输入。** 没有完整 messages，复现时上下文就是错的，bug 不出现。

**误区三：记录里缺版本信息。** prompt 改了、代码发了，同样输入行为不同。没有 `prompt_version` / `deployed_version`，复现出来也不是同一个东西。

**误区四：脱敏把 query 原文也脱了。** 复现就没意义了。折中是加密存储、授权环境解密。

**误区五：在本地改代码调，改完直接上线。** 没有回归测试，你的「修复」可能破坏了别的场景。**30 条快速集 + 基线比对，拦住劣化。**

**误区六：追求 100% 确定性。** temperature=0 + 固定时间已经够用，不必为了理论上的完全可重复投入过多。

**误区七：没有「重放分歧」检测。** 如果 Agent 在本地走了不同路径，要能第一时间发现，而不是当成「同样的问题」继续分析。

---

## 小结

- 本地复现不了的根本原因是**上下文不等价**（生产有多轮历史、真实工具返回、真实措辞），不是代码 bug。所以解法不是「加日志」，而是**把生产那次的完整输入搬回本地**。
- 三步：**完整记录（含 tools_schema、版本号、raw response）→ 录制重放（拦截调用、按序播放、检测分歧）→ 本地工具箱（单步、上下文 diff、干预）**。
- 复现的**完成标准**：本地重放轨迹与生产录制轨迹逐步一致。没到这个标准就不叫复现。
- 复现最常用的两个动作：**改录制数据测敏感性**（改工具返回 → 看 Agent 走什么路），**上下文 diff**（改 prompt 前后，模型输入具体差在哪）。
- Mock 只用于单元测试，**复现生产问题必须用重放**——mock 给的是理想数据，测不出脏数据处理的 bug。
- 记录要分层：**失败案例全量存完整 record**（复现原料），成功案例抽样存（对比）。
- 最后：本地 30 条快速集 + 基线比对，掉太多就拦住提交。**没有回归的调试，等于每次都在碰运气。**

「只在生产出现」的 bug，本质上都是「你没把生产的现场搬回来」。把录制重放搭起来，你会发现大部分生产问题在本地都能稳定复现——然后在推送之前就修掉。
