# Agent 的系统化评测：任务完成率、步数与成本三张表

「我们的 Agent 效果挺好」——这句话在生产环境里不可信。**因为你不知道它好在哪、差在哪、改完之后是变好还是变坏。**

Agent 的评测和单轮问答完全不同。问答可以看答案对不对，Agent 是「多步任务 + 工具调用 + 有过程」——它可能答案对了但绕了 20 步，也可能步数很少但结论是错的。**只看最终输出会漏掉一半信息。**

这一篇讲一套可落地的 Agent 评测体系：三个核心指标、怎么建评测集、怎么自动化跑、以及怎么用数据定位问题。

---

## 一、为什么 Agent 评测比 LLM 评测难

### 1.1 三个额外难点

**难点一：没有唯一正确答案。** 「帮我查一下」这种任务，不同路径可能都对。评测不能只比对文本，要判断「任务达成了吗」。

**难点二：过程影响结果。** 同样的最终答案，走 3 步和走 20 步的成本差 10 倍。**过程本身是要被度量的对象**，不只是达成结果的手段。

**难点三：失败模式多样。** 选错工具、参数填错、死循环、幻觉、拒答、超时——每种都要单独能看到，混在一起看「成功率」毫无信息量。

### 1.2 三张表代替一个分数

我的做法是一起看三个维度：

| 维度 | 指标 | 回答问题 |
|------|------|---------|
| **效果** | 任务完成率、结果正确率 | 事情办成了吗 |
| **效率** | 平均步数、平均耗时、token | 办得划算吗 |
| **稳定** | 失败率、重试率、超时率 | 靠得住吗 |

**任何单张表都不足以判断一个 Agent 的健康度。** 完成率 90% 但平均 30 步，成本可能是不可持续的；步数 3 步但完成率 50%，说明简单的做了难的放弃了。

---

## 二、指标一：任务完成率（核心）

### 2.1 定义

> **完成率 = 正确完成的任务数 / 总任务数**

「正确完成」的判定是最难的部分，按可靠性分三级：

**第一级：可编程验证（最可靠）**

任务目标天然可验证时，直接写代码判：

```python
def verify_code_task(result, test_cases) -> bool:
    return all(tc(result) for tc in test_cases)

def verify_data_task(result, expected_rows) -> bool:
    return result.row_count == expected_rows and result.schema == "valid"
```

**第二级：结构化比对**

结果有明确 schema 和字段值要求：

```python
def verify_ticket_created(result) -> dict:
    ok = (result.get("status") == "created"
          and result.get("priority") == "P2"
          and result.get("assignee") == "dba-team")
    return {"ok": ok, "missing": [k for k in ["priority","assignee"] if not result.get(k)]}
```

**第三级：LLM 评判（兜底，有噪声）**

```python
JUDGE_PROMPT = """判断 Agent 是否完成了用户的任务。

【用户任务】{task}
【最终输出】{output}
【执行轨迹摘要】{trajectory}

判定标准（全部满足才算完成）：
1. 任务要求的动作都执行了吗？
2. 最终输出是否给出了用户要的信息？
3. 执行过程中有没有出现编造数据、错误结论？

输出 JSON：{{"completed": true/false, "reason": "...", "failure_mode": "none/wrong_tool/bad_params/hallucination/loop/timeout/refused"}}"""
```

**`failure_mode` 字段是关键**——它让你知道失败是哪一类，而不是只知道「失败了」。

### 2.2 分类统计

```python
from collections import Counter

results = [run_one(task) for task in eval_set]

by_mode = Counter(r["failure_mode"] for r in results if not r["completed"])
print("完成率:", sum(r["completed"] for r in results) / len(results))
print("失败模式分布:", dict(by_mode))
```

一个典型的输出：

```
完成率: 0.73
失败模式分布: {
  'wrong_tool': 8,        ← 选错工具，占 27%
  'hallucination': 5,     ← 编造，占 17%
  'bad_params': 4,        ← 参数错，占 13%
  'loop': 2,              ← 死循环，占 7%
}
```

**这一眼就能看出该先修什么**：wrong_tool 占 27%，说明工具描述或路由有问题，先去改工具描述，而不是调模型。

---

## 三、指标二：效率三件套

完成率一样时，效率决定这个 Agent 能不能上生产。

### 3.1 平均步数

```python
steps = [len(r["trajectory"]) for r in results]
p50, p95 = percentile(steps, 50), percentile(steps, 95)
# 关注 P95 而不是均值——长尾才是问题
```

**单任务步数 > 15 要单独看**。这些通常是绕路了，或者任务本身定义不清。

### 3.2 无效步数占比

比总步数更有信息量：

```python
def is_wasted_step(step) -> bool:
    # 同样工具同样参数重复调用
    # 调用后报错且没有纠正动作
    # 产出与前后步骤无关
    ...
wasted = sum(1 for s in trajectory if is_wasted_step(s))
wasted_ratio = wasted / len(trajectory)
```

**无效步数占比 > 20% 的 Agent，问题不在模型，在流程设计。** 这个指标我在前面「工具太多」那篇也提过——它是最灵敏的效率指标。

### 3.3 token 与成本

```python
cost = sum(r["tokens_in"] * PRICE_IN + r["tokens_out"] * PRICE_OUT for r in results)
avg_cost = cost / len(results)

# 按任务类型分桶，才知道哪类任务贵
by_type = defaultdict(list)
for r in results:
    by_type[r["task_type"]].append(r["cost"])
for t, cs in by_type.items():
    print(f"{t}: 平均 ¥{mean(cs):.3f}")
```

**成本必须按任务类型分桶看。** 整体平均成本会掩盖「某类简单任务异常贵」的问题。

---

## 四、指标三：稳定性

### 4.1 重跑一致性

同一个任务跑三次，结果一样吗？

```python
def consistency(task, n=3):
    outputs = [run_one(task)["output"] for _ in range(n)]
    # 语义一致性，不是字面一致
    return len(set(normalize(o) for o in outputs)) / n
```

**consistency < 0.8 是危险信号**——意味着用户问同样的问题，可能得到不同答案。对生产系统来说，这比偶尔答错更难接受。

### 4.2 环境扰动的鲁棒性

同一个任务，微调措辞、换个说法，结果还一样吗：

```python
paraphrases = ["帮我查一下订单", "这个订单什么状态", "ORD-12345678 到哪了"]
rates = [completion_rate(p) for p in paraphrases]
spread = max(rates) - min(rates)
```

**spread > 0.3 说明 Agent 对表述敏感**，提示词的稳定性不足。

### 4.3 超时与降级率

```python
timeout_rate = sum(r["timed_out"] for r in results) / len(results)
fallback_rate = sum(r["used_fallback"] for r in results) / len(results)
```

**降级率突然上升 = 某个下游在劣化**，这比完成率下降更早出现。

---

## 五、评测集怎么建

### 5.1 三个来源，别只用一种

**来源一：人工设计（30%）**
覆盖核心场景和边界情况。重点放**难例**和**历史失败案例**——评测集里全是简单题，指标会虚高。

**来源二：线上采样（40%）**
从真实流量里抽。这是唯一能反映真实分布的来源。注意脱敏。

**来源三：合成生成（30%）**
用 LLM 批量造。成本低但分布有偏，按题型配额生成。

### 5.2 评测集画像

| 维度 | 建议 |
|------|------|
| 规模 | 100~300 条（够用） |
| 难度分布 | 30% 简单 / 50% 中等 / 20% 困难 |
| 任务类型 | 按实际流量分布，但难例适当超额 |
| 必须包含 | 历史失败案例、拒答场景、无解场景 |
| 基准线 | 上线前跑一次存基线，每次改动对比 |

**「必须包含无解场景」**：如果评测集里每个任务都有解，你测不出 Agent 遇到无解任务时会不会瞎编。

### 5.3 每条评测样本的结构

```json
{
  "id": "t_042",
  "task": "查询订单 ORD-12345678 的物流状态，如果已签收就发邮件通知我",
  "task_type": "query_then_notify",
  "difficulty": "medium",
  "expected_outcome": {
    "has_tool_call": "query_logistics",
    "condition": "if signed then send_email else no_email",
    "final_output_contains": ["已签收", "通知已发送"]
  },
  "max_steps": 8,
  "max_seconds": 60,
  "known_failure_modes": ["可能漏掉条件判断直接发邮件"]
}
```

**`known_failure_modes` 很有用**：它记录这个任务历史上出过什么问题，评测时可以重点看这些模式有没有复现。

---

## 六、自动化评测流水线

### 6.1 核心循环

```python
class AgentEvaluator:
    def __init__(self, agent, eval_set, env="staging"):
        self.agent = agent
        self.eval_set = eval_set
        self.env = env

    async def run(self) -> Report:
        results = []
        for task in self.eval_set:
            results.append(await self.run_one(task))
        return self.aggregate(results)

    async def run_one(self, task) -> dict:
        t0 = time.time()
        trajectory = []
        try:
            output, steps, tokens = await asyncio.wait_for(
                self.agent.run(task["task"], on_step=trajectory.append),
                timeout=task.get("max_seconds", 120),
            )
        except asyncio.TimeoutError:
            return self.fail(task, "timeout")
        # 判定
        verdict = self.judge(task, output, trajectory)
        return {**verdict,
                "steps": len(trajectory),
                "wasted": sum(1 for s in trajectory if is_wasted(s)),
                "tokens": tokens,
                "seconds": time.time() - t0,
                "trajectory": trajectory}

    def aggregate(self, results) -> Report:
        total = len(results)
        return Report(
            completion_rate=sum(r["completed"] for r in results) / total,
            failure_modes=Counter(r["failure_mode"] for r in results if not r["completed"]),
            steps_p50=percentile([r["steps"] for r in results], 50),
            steps_p95=percentile([r["steps"] for r in results], 95),
            wasted_ratio=mean([r["wasted"] / r["steps"] for r in results]),
            avg_cost=mean([r["cost"] for r in results]),
            consistency=self.check_consistency(),
            worst_cases=worst(results, n=10),
        )
```

### 6.2 报告该长什么样

```
======================== Agent 评测报告 ========================
环境: staging   时间: 2026-10-16 20:00   样本: 200

【效果】
  任务完成率        0.73   (基线 0.70，↑0.03)
  失败模式分布:
    wrong_tool      8  ████████
    hallucination   5  █████
    bad_params      4  ████
    loop            2  ██
    timeout         1  █

【效率】
  步数 P50 / P95    4.2 / 12.8
  无效步数占比      0.18
  平均成本          ¥0.043 / 任务

【稳定性】
  重跑一致性        0.85
  表述敏感度        0.21
  降级触发率        0.05

【最差 3 例】
  t_042  步骤 18，wrong_tool 5 次 —— 工具描述需优化
  t_117  死循环 3 轮后超时
  t_190  结果正确但多绕了 11 步
===============================================================
```

**「基线对比」和「最差案例」是报告里最有价值的两块。** 前者告诉你有没有进步，后者告诉你下一步改什么。

---

## 七、用数据定位问题

拿到报告后，按这个顺序排查：

```
完成率低
  ├─ wrong_tool 占比高？  → 工具描述/路由有问题（先改文档，再改模型）
  ├─ hallucination 高？  → 检索质量 or 上下文过长 or 缺拒答机制
  └─ bad_params 高？      → 参数 schema 没写清，补约束和示例

步数 P95 高
  ├─ 无效步数占比高？    → 流程设计问题，不是模型问题
  └─ 集中在某类任务？    → 那类任务该拆解或加专用路径

一致性低
  └─ temperature 太高 / 提示词有歧义 / 工具描述模糊

降级率高
  └─ 下游在劣化（视角切换到被调用的服务，不是 Agent）
```

**每轮只改一处，重跑对比。** 同时改五处，最后还是不知道哪处起了作用。

---

## 八、常见误区

**误区一：只看完成率。** 完成率 90% 但平均 30 步、成本 5 倍，这个 Agent 上不了生产。三张表一起看。

**误区二：评测集全是简单题。** 指标虚高，上线就翻车。**必须有难例和失败案例**，还要有「无解任务」测拒答。

**误区三：用 LLM 评判但不判 failure_mode。** 只知道失败不知道类别，等于白测。

**误区四：没有基线。** 改了 prompt 没法判断有没有变好。**第一版跑完必须存基线。**

**误区五：报告只看均值。** 步数和成本必须看 P95——长尾才是问题。

**误区六：一次改多处。** 无法归因。一次一处，重跑对比。

**误区七：评测集不更新。** 上线后遇到的新失败案例要回流到评测集，否则回归测试永远测不到它们。

**误区八：忽略一致性。** 重跑三次三个答案，比偶尔答错更伤用户信任。

---

## 小结

- Agent 评测的难点是**没有唯一正确答案、过程影响结果、失败模式多样**。所以用**三张表**代替一个分数：效果（完成率）、效率（步数/token）、稳定（一致性/降级率）。
- **完成率判定的核心是 failure_mode 分类**——只知道失败不知道类别，等于白测。判据优先级：可编程验证 > 结构化比对 > LLM 评判。
- 效率看 **P95 而不是均值**，以及**无效步数占比**（>20% 说明流程设计有问题，不是模型问题）。
- 评测集三来源：人工设计（难例+历史失败）、线上采样（真实分布）、合成生成（规模）。**必须包含无解任务**测拒答。
- 报告最有价值的两块：**基线对比**（有没有进步）和**最差案例**（下一步改什么）。
- 排查顺序按 failure_mode 分布走：wrong_tool→改工具描述，hallucination→查检索和上下文，bad_params→补 schema。
- 铁律：**一次只改一处，重跑对比；新失败案例回流评测集**。

没有评测的 Agent 优化，本质上是碰运气。有了这三张表，你才能回答「这次改动到底有没有用」——以及更重要的，「下次该改哪里」。
