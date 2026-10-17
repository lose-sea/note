# Plan-and-Execute：让 Agent 先想清楚再动手

ReAct 最大的问题是「走一步看一步」。每一步只基于当前上下文选下一步，没有全局视野。任务稍复杂就容易出现：绕圈子、做到一半忘了原始目标、把简单任务越搞越复杂。

Plan-and-Execute 是解决这个问题的经典模式：**先把任务拆成一个计划，然后逐个执行，必要时重规划。** 它不是新算法，但在工程上比 ReAct 稳得多，也是很多生产 Agent 的默认选择。

这一篇讲清楚：它和 ReAct 的差别、计划该怎么生成、执行时怎么处理失败、以及重规划的触发条件。

---

## 一、ReAct 为什么会迷路

### 1.1 没有计划的三种典型症状

**症状一：上下文漂移。** 每一步都把上一步的结果加进上下文，跑十几轮之后，「最初要解决什么问题」被埋在几十条工具结果底下。模型还在继续推理，但推理的目标已经悄悄变了。

**症状二：重复劳动。** 模型没有「我已经试过这个方法」的全局记忆，只是最近几轮。于是它会反复调同一个工具、搜同一个关键词，每次都觉得「这次可能有新结果」。

**症状三：顺序错误。** 有些步骤有隐含依赖（得先拿到表结构才能写 SQL）。ReAct 靠运气碰对顺序，碰不对就报错、重试、再碰。

### 1.2 根因

ReAct 的循环里只有一个状态：**对话历史**。历史里有用的信息（目标、约束、已完成的步骤）和没用的（失败的尝试、原始数据）混在一起，模型无法可靠地提取前者。

**计划是一个独立的、显式的状态。** 把它从对话历史里拆出来单独维护，就解决了漂移问题。

---

## 二、Plan-and-Execute 的三段结构

```
        ┌──────────────┐
        │  1. Planner  │  ← 生成计划：3~8 个步骤，每步有明确的输入/输出/依赖
        └──────┬───────┘
               ▼
        ┌──────────────┐
        │  2. Executor │  ← 按计划执行，可以串行也可以并行（看依赖）
        └──────┬───────┘
               ▼
        ┌──────────────┐
        │ 3. Replanner │  ← 检查进展，决定继续 / 重规划 / 结束
        └──────────────┘
```

### 2.1 第一步：Planner

**计划不要贪多。** 3~8 步是合理区间。低于 3 步说明没拆开，高于 8 步说明过度设计（且模型很难一次生成可靠的长计划）。

每一步要写清楚三件事：**做什么、需要什么输入、产出什么**。

```
任务：调研三家向量数据库的部署成本，输出对比报告

计划：
1. 确认三家的最新版本与计费模式 | 输入: 无 | 输出: /data/versions.md
2. 抓取 A 社区版的硬件要求与自建成本 | 依赖: 1 | 输出: /data/selfhost.md
3. 抓取 B 托管版的公开报价 | 依赖: 1 | 输出: /data/managed.md
4. 计算同规模（1亿向量）下的年度总成本 | 依赖: 2,3 | 输出: /data/cost.md
5. 写对比报告 | 依赖: 4 | 输出: /reports/vdb-compare.md
```

注意第 1 步是「确认基础信息」，第 5 步是「产出」。**这个结构（先对齐上下文 → 中间加工 → 最后产出）几乎适用于所有调研类任务**，值得作为默认骨架。

依赖标注是关键——它让 Plan 变成一张 DAG，下游才能推导哪些步骤可以并行。

### 2.2 第二步：Executor

Executor 只负责「把当前这一步干完」，它**不需要看整个计划**（避免又被全局信息干扰）。

```python
def execute_step(step: Step, all_steps: list[Step], results: dict) -> StepResult:
    # 把上一步的结果喂进来，但不给它整个计划
    upstream = {dep: results[dep] for dep in step.depends_on}

    prompt = STEP_PROMPT.format(
        description=step.description,
        inputs=step.inputs,
        expected_output=step.outputs,
        upstream=json.dumps(upstream, ensure_ascii=False),
    )
    result = executor_agent.invoke({"messages": [("human", prompt)]})
    return StepResult(step_id=step.id, output=result.messages[-1].content)
```

Executor 可以是简单的 LLM 调用，也可以是一个 ReAct 子 Agent。**如果这一步本身需要多次工具调用，用子 Agent**；如果是一次生成就够，直接调用模型。

### 2.3 第三步：Replanner

Replanner 是整个模式里最容易被忽略、但最关键的部分。它的职责：

- 当前步骤失败，是重试、跳过、还是改计划？
- 后面的步骤还成立吗？
- 全部完成了没？

```python
REPLAN_PROMPT = """你是计划审查者。

【原始目标】
{goal}

【当前计划】
{plan}

【已完成的步骤与结果】
{completed}

【当前遇到的情况】
{issue}

请判断并输出 JSON：
{{
  "action": "continue" | "replan" | "finish",
  "reason": "一句话说明",
  "new_steps": []   // 仅当 action=replan 时填写，列出新计划
}}

判断原则：
1. 目标已达成 → finish，不要为了"再完善一下"无限加步骤；
2. 当前步骤失败但可用替代方案 → replan，插入新步骤；
3. 后续步骤因前面的结果而不必要 → 删掉它们；
4. 不要把已完成步骤重新加回计划。"""
```

第 4 条要特别注意。我见过 Replanner 把已完成的步骤又生成一遍，导致重复执行。

---

## 三、计划生成：让模型写出可执行的计划

### 3.1 提示词模板

```python
PLAN_PROMPT = """你是任务规划器。请把下面的任务拆成一个可执行计划。

【硬性要求】
1. 拆成 3~8 个步骤，宁少勿多；
2. 每一步格式：[动作描述] | 输入: [所需信息] | 输出: [产物或答案] | 依赖: [步骤序号，逗号分隔，无则 none]
3. 典型结构：先确认基础信息/上下文，再加工处理，最后产出结论；
4. 每一步只做一件事，不要把"查数据并写报告"合成一步；
5. 输出必须是 JSON 数组。

【任务】
{task}

JSON："""
```

用 JSON 数组输出，配合 `with_structured_output` 做类型约束，别让模型自由发挥。

### 3.2 让计划带上「验证条件」

光有步骤不够，还要有「怎么算做完」。给每一步加一个 `success_criteria`：

```python
class Step(BaseModel):
    id: int
    description: str
    inputs: str
    expected_output: str
    depends_on: List[int]
    success_criteria: str = ""      # 例如："文件存在且包含三家报价"
```

有验证条件的计划，失败时你能判断「是可重试的失败」还是「此路不通需要 replan」。

### 3.3 简单任务跳过规划

```python
def should_plan(task: str) -> bool:
    """判断是否需要拆计划。"""
    # 简单事实问答、单步操作，直接干
    SIMPLE_SIGNALS = ["是什么", "多少钱", "怎么读", "帮我查一下", "翻译"]
    if len(task) < 30 and any(s in task for s in SIMPLE_SIGNALS):
        return False
    return True
```

**对「Python 怎么反转列表」这种问题规划是纯浪费。** 规划本身要一次 LLM 调用，至少要让它换来多步执行的能力。

---

## 四、执行调度：串行、并行与混合

依赖关系决定了执行方式。

### 4.1 串行执行

```python
for step in topo_sorted(plan):
    result = execute_step(step, plan, results)
    results[step.id] = result
```

### 4.2 并行执行（同一层的步骤一起跑）

```python
from concurrent.futures import ThreadPoolExecutor

def run_parallel_layer(steps, plan, results, max_workers=4):
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(execute_step, s, plan, results): s for s in steps}
        for f in as_completed(futures):
            s = futures[f]
            results[s.id] = f.result()
```

**能并行的必须并行**，这是 Plan-and-Execute 相对 ReAct 最大的性能优势。一个 5 步计划如果有 3 步无依赖，串行是 5 个单位时间，并行只要 3 个。

### 4.3 混合调度

按 DAG 分层，每层内并行：

```python
def schedule(plan: list[Step]):
    remaining = {s.id: s for s in plan}
    done = set()
    while remaining:
        # 找出所有依赖已满足的步骤，组成一层
        layer = [s for s in remaining.values()
                 if all(d in done for d in s.depends_on)]
        if not layer:
            raise ValueError("计划有环，检查 depends_on")
        run_parallel_layer(layer, plan, results, max_workers=4)
        done |= {s.id for s in layer}
        for s in layer:
            del remaining[s.id]
```

### 4.4 并行的两个坑

**坑一：限流。** 4 个 Executor 同时打 API，容易触发 rate limit。要么降并发，要么 API 客户端配 `with_retry` 和令牌桶限流。

**坑二：共享状态竞争。** 如果两个步骤都要写同一个文件，后写的会覆盖先写的。**给每个步骤指定独立的输出路径**，不要让它们共享写入目标。

---

## 五、失败处理与重规划

### 5.1 失败的三种性质

不是所有失败都一样，处理方式完全不同：

| 失败类型 | 例子 | 处理 |
|---------|------|------|
| **可重试** | API 超时、限流、临时 5xx | 原样重试，配退避 |
| **需修正** | 输出格式不对、缺一个字段 | 带错误信息重试，最多 2 次 |
| **此路不通** | 数据源不存在、权限不够、结论是「查不到」 | 回 Replanner 改计划 |

**区分这三类，需要 Replanner 介入判断**，不能无脑重试。

### 5.2 带诊断信息的重试

```python
def execute_with_retry(step: Step, max_attempts=2):
    attempts = []
    for i in range(max_attempts + 1):
        result = execute_step(step, plan, results, prior_errors=attempts)
        if result.ok:
            return result
        attempts.append(result.error)     # 把错误带给下一次
        time.sleep(2 ** i)                # 指数退避
    return StepResult(step_id=step.id, status="failed", error=attempts)
```

重试时把 `prior_errors` 一起给模型，它知道「上次是因为输出格式不对」，第二次大概率能改对。**盲重试十次不如带诊断重试两次。**

### 5.3 重规划的触发条件

```python
def maybe_replan(state) -> str:
    # 1. 某步连续失败
    if state.failed_steps_since_replan >= 1:
        return "replan"

    # 2. 计划步骤数持续膨胀（模型在"为了完善而完善"）
    if len(state.plan) > 12:
        return "replan"

    # 3. 预算快用完了
    if state.total_tokens > TOKEN_BUDGET * 0.8:
        return "replan"

    # 4. 所有步骤完成
    if all(s.status == "done" for s in state.plan):
        return "finish"
    return "continue"
```

第 3 条是成本护栏——**长任务最怕跑飞**，设一个 token 预算，超了就强制收尾，产出「基于当前已完成部分」的答案，而不是继续烧。

---

## 六、Plan-and-Execute vs ReAct：怎么选

| 维度 | ReAct | Plan-and-Execute |
|------|-------|-----------------|
| 步骤数 | 不可控，看任务 | 显式约束（3~8 步） |
| 并行能力 | 无（串行循环） | 有（按依赖分层并行） |
| 长任务稳定性 | 差，易漂移 | 好，计划是锚点 |
| 简单任务开销 | 低（直接开干） | 高（多一次规划调用） |
| 灵活性 | 高（随时改方向） | 中（改计划要走 Replanner） |
| 可解释性 | 差（历史里翻） | 好（计划本身就是解释） |

**选择建议：**

- 步骤 ≤ 3、无并行需求 → **ReAct**，简单直接
- 步骤 ≥ 4、有独立子任务、或者任务需要跨多轮 → **Plan-and-Execute**
- 需要人工审批/断点续跑 → 用 LangGraph 实现，两者都行

实践中，一个常见组合是：**外层 Plan-and-Execute，内层每步用 ReAct 子 Agent 执行**。这样既有全局视野，又保留单步的灵活性。

---

## 七、完整实现

```python
import json
from typing import Literal
from pydantic import BaseModel, Field

class Step(BaseModel):
    id: int
    description: str
    inputs: str = ""
    expected_output: str = ""
    depends_on: list[int] = Field(default_factory=list)
    success_criteria: str = ""

class Plan(BaseModel):
    steps: list[Step]

class Decision(BaseModel):
    action: Literal["continue", "replan", "finish"]
    reason: str
    new_steps: list[Step] = Field(default_factory=list)


def run_plan_execute(goal: str, llm, execute_fn, budget_tokens=400_000):
    plan: Plan = llm.with_structured_output(Plan).invoke(PLAN_PROMPT.format(task=goal))
    results: dict[int, str] = {}
    status = {s.id: "pending" for s in plan.steps}
    total_tokens = 0

    while True:
        # 分层调度
        ready = [s for s in plan.steps
                 if status[s.id] == "pending"
                 and all(status[d] == "done" for d in s.depends_on)]

        if ready:
            for s in ready:
                status[s.id] = "running"
            # 无依赖的并行跑
            layer = [s for s in ready if not s.depends_on]
            for s in layer:
                out, used = execute_with_retry(s, results)
                results[s.id] = out
                total_tokens += used
                status[s.id] = "done" if out.ok else "failed"
            # 有依赖的串行跑（依赖本层刚产出的结果顺序执行）
            for s in [x for x in ready if x.depends_on]:
                out, used = execute_with_retry(s, results)
                results[s.id] = out
                total_tokens += used
                status[s.id] = "done" if out.ok else "failed"
            continue

        # 没有可执行步骤了，问 Replanner
        decision = llm.with_structured_output(Decision).invoke(
            REPLAN_PROMPT.format(
                goal=goal,
                plan=json.dumps([s.model_dump() for s in plan.steps], ensure_ascii=False),
                completed=json.dumps(results, ensure_ascii=False),
                issue="所有就绪步骤已执行完毕。",
            )
        )

        if decision.action == "finish":
            return synthesize(goal, results, llm)
        if decision.action == "replan":
            if total_tokens > budget_tokens:
                return synthesize(goal, results, llm)   # 预算耗尽，强制收尾
            plan = Plan(steps=decision.new_steps)
            status = {s.id: "pending" for s in plan.steps}
            continue
        break

    return synthesize(goal, results, llm)
```

几个细节：

- `execute_with_retry` 返回 `(output, tokens_used)`，用来累计预算
- 预算超了强制收尾，避免长任务失控
- 重规划时会**完全替换**计划，所以要保证 new_steps 是自包含的（Replanner 看不到已废弃的旧步骤细节，得在 prompt 里给全）

---

## 八、常见误区

**误区一：计划越细越好。** 12 步以上的计划，模型生成质量下降、执行层调度也复杂。**3~8 步**是甜点区。

**误区二：无脑重试失败步骤。** 「此路不通」型失败重试一百次也没用，还会烧预算。先让 Replanner 判断失败性质。

**误区三：把整个计划塞给每个 Executor。** 那会重现 ReAct 的漂移问题。只给它当前步骤 + 上游产出。

**误区四：没有预算护栏。** 长任务最怕跑飞。设 token 上限，超了收尾产出「部分答案」，也远好于无限烧钱。

**误区五：并行步骤共享输出目标。** 两个步骤写同一个文件，后写的覆盖前面的。给每步独立输出路径。

---

## 小结

- Plan-and-Execute 的核心是把**计划作为独立显式状态**，解决 ReAct 的上下文漂移、重复劳动和顺序错误。
- 三段结构：**Planner（3~8 步，带输入/输出/依赖）→ Executor（只看当前步骤）→ Replanner（判断继续/重规划/结束）**。
- 依赖标注让计划变成 DAG，**同层无依赖步骤并行执行**——这是它相对 ReAct 最大的性能优势。
- 失败要分三类处理：可重试（退避重试）、需修正（带诊断信息重试）、此路不通（回 Replanner）。**区分它们的是 Replanner，不是盲目重试逻辑。**
- **必须设 token 预算护栏**，超限强制产出部分答案，防止长任务跑飞。
- 选择标准：步骤少无并行 → ReAct；步骤多有依赖 → Plan-and-Execute。经典组合是外层规划、内层每步用 ReAct 子 Agent。

先想清楚再动手，听起来是老生常谈，但它是 Agent 从「演示品」变成「生产件」最关键的一步。
