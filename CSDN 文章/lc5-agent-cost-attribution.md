# Agent 成本归因：一次任务到底花了多少钱，花在哪

Agent 上线三个月，账单比预估高了六倍。你去查，发现 token 用得不少，但**说不上来是哪类任务贵、哪个环节在烧钱、是该换模型还是该改流程。**

单轮问答的成本很好算：一次调用 = 输入 token × 单价 + 输出 token × 单价。但 Agent 是**多轮、多模型、多工具、有分支**的——一次任务的成本可能拆成十几次 LLM 调用和若干个外部 API，成本结构完全不是一次乘法能算清的。

这一篇讲怎么把成本拆开、怎么归因、以及拿到数据之后怎么降。

---

## 一、Agent 成本为什么难算

### 1.1 四个复杂因素

**因素一：一个任务多次调用。** 跑 15 轮的 Agent，成本是 15 次调用的和。哪怕每轮只涨 500 token，累计也很可观。

**因素二：不同环节用不同模型。** 感知用小模型、规划用大模型、参数填充用小模型。同一个任务里混着三种单价。

**因素三：上下文在膨胀。** 第 1 轮输入 2k token，第 15 轮可能输入 20k——**同样的对话，后面的每一轮都在为前面所有内容付费**。这是 Agent 成本的非线性来源。

**因素四：失败也要钱。** 跑错重试、工具报错重试、死循环——这些 token 都计费，但不产生价值。

### 1.2 一个真实的账单

「调研三家向量数据库写对比报告」这个任务，实际计费明细：

```
步骤 1  规划（gpt-4o-mini）      输入 1.2k  输出 0.8k    ¥0.006
步骤 2  检索（embedding × 12）   12 × 0.3k            ¥0.001
步骤 3  子任务A（gpt-4o + 工具）  输入 8k   输出 2k     ¥0.180   ← 上下文已膨胀
步骤 4  子任务B（gpt-4o + 工具）  输入 11k  输出 2.5k   ¥0.225
步骤 5  子任务C（gpt-4o + 工具）  输入 14k  输出 3k     ¥0.270
步骤 6  汇总（gpt-4o-mini）       输入 6k   输出 2k     ¥0.018
步骤 7  重试（步4失败后重跑）     输入 11k  输出 2.5k   ¥0.225   ← 纯浪费
步骤 8  重试（步5超时重跑）       输入 14k  输出 2k     ¥0.230   ← 纯浪费
                                            合计        ¥1.155
```

**重试烧掉了 40% 的预算。** 而且步骤 3/4/5 的成本逐轮递增——因为上下文在累积。

不拆开看，你只会知道「这个任务花了 1 块多」，不知道**问题在重试（该修）和上下文膨胀（该压缩）**。

---

## 二、成本的四个维度

归因要按维度拆。四个维度一起看，才能定位问题。

### 2.1 维度一：按任务类型

```python
from collections import defaultdict

cost_by_type = defaultdict(lambda: {"total": 0.0, "count": 0})
for task in tasks:
    c = task["cost"]
    cost_by_type[task["type"]]["total"] += c
    cost_by_type[task["type"]]["count"] += 1

for t, v in sorted(cost_by_type.items(), key=lambda x: -x[1]["total"]):
    print(f"{t:20s} 总 ¥{v['total']:8.3f}  单次 ¥{v['total']/v['count']:.4f}  {v['count']}次")
```

输出：

```
query_simple        总 ¥0.312   单次 ¥0.0062   50次
doc_analysis        总 ¥18.60   单次 ¥0.3720    50次   ← 单次最贵
code_gen            总 ¥9.80    单次 ¥0.1960    50次
chat_retry          总 ¥12.45   单次 ¥0.2490    50次   ← 总量第二但价值低
```

**`chat_retry` 这种就是典型的「没产生价值但烧钱」类型。** 它总量排第二，但单次也不便宜——说明用户在反复问同类问题，而缓存没命中。

### 2.2 维度二：按环节

```python
STAGE_COSTS = defaultdict(float)
for task in tasks:
    for step in task["trajectory"]:
        STAGE_COSTS[step["stage"]] += step["cost"]

# 输出示例：planning 12%, retrieval 3%, reasoning 45%, generation 28%, retry 12%
```

**`retry` 占比是最需要盯的指标。** 健康值应该 < 5%。超过 10% 说明失败处理有大问题。

### 2.3 维度三：按模型

```python
cost_by_model = defaultdict(float)
for task in tasks:
    for call in task["llm_calls"]:
        cost_by_model[call["model"]] += call["cost"]

# 判断：贵的模型是否只用在真正需要它的地方
```

**常见问题**：用 gpt-4o 做参数填充或者意图识别——这些任务小模型完全够，钱白花一半。

### 2.4 维度四：按输入/输出拆

```python
in_cost = sum(c["tokens_in"] * c["price_in"] for c in all_calls)
out_cost = sum(c["tokens_out"] * c["price_out"] for c in all_calls)
print(f"输入 ¥{in_cost:.3f} ({in_cost/(in_cost+out_cost):.0%})  输出 ¥{out_cost:.3f}")
```

**输入成本占比过高（> 70%）就是上下文没管好。** Agent 每轮都在为累积的历史付费——这是最普遍的浪费，也是最好优化的。

---

## 三、怎么采集成本数据

### 3.1 在每次 LLM 调用处埋点

```python
class CostTracker:
    def __init__(self):
        self.reset()

    def reset(self):
        self.calls = []

    def record(self, *, stage: str, model: str, tokens_in: int,
               tokens_out: int, task_id: str, retry: bool = False):
        price = PRICES[model]
        self.calls.append({
            "task_id": task_id,
            "stage": stage,
            "model": model,
            "tokens_in": tokens_in,
            "tokens_out": tokens_out,
            "cost_in": tokens_in * price["in"],
            "cost_out": tokens_out * price["out"],
            "total_cost": tokens_in * price["in"] + tokens_out * price["out"],
            "retry": retry,
            "ts": now(),
        })

    def summary(self) -> dict:
        total = sum(c["total_cost"] for c in self.calls)
        return {
            "total": total,
            "by_stage": group_sum(self.calls, "stage"),
            "by_model": group_sum(self.calls, "model"),
            "retry_cost": sum(c["total_cost"] for c in self.calls if c["retry"]),
            "input_ratio": sum(c["cost_in"] for c in self.calls) / total,
        }
```

**`retry` 标记很重要**——重试的成本要单独算，不然它藏在总账里看不出来。

### 3.2 从 API 响应里拿 token

OpenAI 兼容接口都返回 `usage`：

```python
resp = await client.chat.completions.create(...)
usage = resp.usage
tracker.record(stage="reasoning", model="gpt-4o",
               tokens_in=usage.prompt_tokens,
               tokens_out=usage.completion_tokens,
               task_id=current_task)
```

**注意流式响应**：流式的 usage 在最后一个 chunk 里，别漏掉。而且流式的 `prompt_tokens` 也可能因为 prompt 缓存而显示为 0（命中缓存时不重计），要看清楚计费口径。

### 3.3 存储

```python
# 成本明细表（按天/周聚合做报表）
COST_LOG = """
CREATE TABLE cost_log (
    ts          TIMESTAMP,
    task_id     TEXT,
    user_id     TEXT,
    task_type   TEXT,
    stage       TEXT,
    model       TEXT,
    tokens_in   INT,
    tokens_out  INT,
    cost        NUMERIC,
    is_retry    BOOL
);
"""
```

**必须带 `user_id` 和 `task_type`**，否则只能看总量，做不了按用户/按类型的分析。

---

## 四、拿到数据后的降本手段

按 ROI 从高到低排。

### 4.1 先砍重试（通常最省）

如果 `retry_cost / total > 10%`，这是第一优先级。方案：

- 修工具描述，减少参数错误（见「工具描述的写法」）
- 错误信息写清楚，让模型一次改对而不是盲重试
- 区分可重试/不可重试错误，别对 400 也重试

**这一项经常能把总成本降 15%~30%，且不损失任何效果。**

### 4.2 再压上下文

输入成本占比 > 70% 时做：

- 工具输出压缩：只留相关字段，别把整个 JSON 塞回去
- 历史截断：只保留关键决策点，丢弃试错过程
- 文件系统代替上下文传递（DeepAgents 那套）

**这一项通常能降 30%~50% 的输入成本。**

### 4.3 模型分级

把不需要强智能的环节换成小模型：

| 环节 | 该用什么 | 省多少 |
|------|---------|-------|
| 意图识别 / 分类 | 小模型（4o-mini 级） | ~90% |
| 参数填充 / 格式转换 | 小模型 | ~90% |
| 规划 / 复杂推理 | 大模型 | 不能省 |
| 最终生成 | 视质量要求 | ~50% |

**最常见的浪费是用大模型做简单分类。** 换成小模型，这类环节成本降一个数量级，效果几乎无损。

### 4.4 缓存

- **精确缓存**：相同 query 直接返回。命中率高时省很多
- **语义缓存**：相似 query 命中（embedding 相似度 > 0.95）。注意误命中的代价——返回了不相关的答案比多花钱更糟

**语义缓存的阈值要保守（0.95+），宁可少命中。**

### 4.5 限制步数与预算

```python
@dataclass
class TaskBudget:
    max_llm_calls: int = 15
    max_tokens: int = 60_000
    max_seconds: int = 120
```

超预算强制收尾，产出「基于已完成部分」的答案。**这是防失控的最后一道闸**，比任何优化都可靠。

---

## 五、成本该怎么看：不是越低越好

一个反直觉的结论：**一味压成本会伤害效果。**

| 做法 | 成本变化 | 效果变化 |
|------|---------|---------|
| 砍重试（修根因） | ↓ 20% | 持平或↑ |
| 压上下文 | ↓ 30% | 持平或↑ |
| 模型分级（简单环节） | ↓ 30% | 持平 |
| 全用小模型 | ↓ 70% | ↓↓ |
| 砍 top_k | ↓ 15% | ↓ |
| 砍重试次数到 0 | ↓ 10% | ↓ |

**前四项是「无损优化」，后三项是「有损优化」。** 区别在于：前者砍的是浪费，后者砍的是能力。

**判断标准**：这个改动砍掉的是「没产生价值的花费」还是「产生价值的必要花费」？前者尽管砍，后者要慎重。

### 5.1 一个健康的成本构成

```
重试浪费      < 5%      ← 超过就该修
输入(上下文)   < 60%     ← 超过就压缩
有效推理       ~30%
有效生成       ~20%（视任务类型）
```

---

## 六、常见误区

**误区一：只看总账。** 「这个月花了 3000」没有信息量。必须按任务类型、环节、模型拆开。

**误区二：不算重试成本。** 重试是最容易被忽视的浪费，而且经常占 10%~40%。**每次调用带 `is_retry` 标记。**

**误区三：只算 token，不算 embedding 和外部 API。** 检索、rerank、外部接口都花钱，虽然占比小，长期看也不少。

**误区四：没有 user_id 维度。** 想按用户限额、想知道谁在烧钱，必须有用户维度。

**误区五：流式响应漏计 token。** 流式的 usage 在最后一块，漏了就少算一大截，账不平。

**误区六：成本越低越好。** 无脑压缩会砍到能力上。区分「浪费」和「必要投入」，只砍前者。

**误区七：没有预算护栏。** 再精的成本分析，也拦不住一个跑飞的任务。预算上限是必配。

---

## 小结

- Agent 成本难算，因为它**多次调用、多模型、上下文非线性膨胀、失败也计费**。一次任务的成本可能是十几次调用的和。
- 四个维度归因：**按任务类型（哪类贵）、按环节（哪步在烧钱）、按模型（贵模型用对地方了吗）、按输入输出拆（上下文是不是太胖）**。
- **重试成本必须单独标记统计**——健康值 < 5%，超过 10% 说明失败处理有大问题，这是最高 ROI 的优化点。
- **输入成本占比 > 70% 就该压上下文**（工具输出压缩、历史截断、路径传递替代内容）。
- 降本 ROI 排序：**砍重试 → 压上下文 → 模型分级（简单环节换小模型）→ 缓存 → 预算护栏**。
- **区分无损优化和有损优化**：前者砍浪费，后者砍能力。前者尽管做，后者要评估。
- 每个任务必须有**预算上限**——分析再精细，也拦不住跑飞的任务。

成本归因的价值不只是省钱。它是个体检指标：**钱花得不合理的地方，通常也是架构不合理的地方。** 重试占比高说明工具描述有问题，输入占比高说明上下文管理有问题——账单的异常，往往是系统病灶的早期信号。
