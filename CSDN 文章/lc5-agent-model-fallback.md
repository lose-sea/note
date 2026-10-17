# 模型降级链：主模型挂了，系统不能跟着挂

主模型限流了、超时了、返回 500 了——这时候你的 Agent 怎么办？

错误答案是「让用户等」或者「返回系统繁忙」。**模型调用是 Agent 最核心也最不可控的依赖**，任何单一模型服务都有抖动，你的系统不能比它更脆弱。

模型降级链的思路很直白：**准备一条备选路径，主路径不可用时依次降级。** 但降级不是「换个模型名」这么简单——降级到什么程度、什么时候降、降级后的质量怎么保证，都有讲究。

---

## 一、为什么必须有降级链

### 1.1 模型 API 的不稳定性是常态

跑过生产的都知道，模型 API 的抖动频率不低：限流（429）、超时（504）、后端 5xx、区域性故障、还有「模型更新导致行为变化」这种软故障。

**单点依赖一个模型服务，等于把你的可用性交给第三方。** 它们 99.9% 的 SLA，落到你的系统上可能就是月度几次故障。

### 1.2 降级链的三个价值

1. **可用性**：主挂了系统还能跑，用户无感知或轻微感知
2. **成本兜底**：贵模型限流时用便宜模型，至少能服务
3. **容量弹性**：高峰期自动降级，比扩容便宜

**注意降级是「有损服务」不是「无损切换」。** 便宜的模型质量差些——所以降级策略要明确告知用户，或者只在不影响核心体验的场景下自动降。

---

## 二、降级链的层级设计

### 2.1 四级降级，逐层让步

```
第 1 级  主模型（gpt-4o）        —— 全能力，最佳质量
  │ 失败
第 2 级  备选主模型（claude/
         qwen-max）             —— 同级别，不同供应商
  │ 失败
第 3 级  降级模型（gpt-4o-mini）—— 便宜、快、质量略降
  │ 失败
第 4 级  本地模型 / 缓存答案     —— 最后防线
  │ 失败
  明确告知 + 转人工
```

**层级的选择原则**：

- **第 2 级要跨供应商**。同供应商的两个模型可能同时故障（或共享同一个限流池）
- **第 3 级要明显快且便宜**——降级时往往伴随超时压力，慢模型没意义
- **第 4 级不依赖外网**——本地小模型或者预置的缓存答案，保证「最坏也能说句话」

### 2.2 代码实现

```python
from dataclasses import dataclass
import asyncio

@dataclass
class ModelTier:
    name: str
    provider: str
    timeout: float
    cost_tier: str              # 用于日志和监控
    supports_tools: bool = True

TIERS = [
    ModelTier("gpt-4o",        "openai",    30.0, "premium"),
    ModelTier("qwen-max",      "dashscope", 25.0, "premium"),     # 跨供应商
    ModelTier("gpt-4o-mini",   "openai",    15.0, "cheap"),
    ModelTier("qwen-turbo",    "dashscope", 10.0, "cheap"),
    ModelTier("local-qwen-7b", "local",     10.0, "free"),        # 本地兜底
]

class FallbackChain:
    def __init__(self, tiers, metrics):
        self.tiers = tiers
        self.metrics = metrics

    async def call(self, prompt, **kwargs):
        errors = []
        for tier in self.tiers:
            try:
                result = await asyncio.wait_for(
                    self._invoke(tier, prompt, **kwargs),
                    timeout=tier.timeout,
                )
                self.metrics.tier_used.labels(tier=tier.name).inc()
                return result, tier
            except Exception as e:
                errors.append((tier.name, type(e).__name__, str(e)[:200]))
                self.metrics.tier_failed.labels(tier=tier.name,
                                                error=type(e).__name__).inc()
                continue
        raise AllTiersFailed(errors)
```

**两个要点**：

- **每级独立 timeout**。降级到快模型就该配短超时，否则降级没意义
- **每级的失败都要记录**，否则你只看到「降级了」，不知道主模型为什么挂

### 2.3 工具调用的降级兼容

**这是最容易忽略的坑**：便宜模型不一定支持 function calling / 结构化输出。

```python
@dataclass
class ModelTier:
    name: str
    supports_tools: bool
    supports_json_mode: bool
    ...

def pick_tier_for_task(task_needs_tools: bool) -> list[ModelTier]:
    if task_needs_tools:
        return [t for t in TIERS if t.supports_tools]
    return TIERS                      # 不需要工具时，全部可选
```

**降级前要判断这个模型能不能干这个活**，不然降过去直接报错，白降一级。

---

## 三、什么时候触发降级

### 3.1 被动触发：失败即降

```python
# 超时、5xx、限流、连接错误 → 降级
if is_retryable(error) and retries_exhausted:
    fallback()
```

**注意区分「可重试失败」和「直接降级」**：偶发的 429 重试一次可能就过了，直接降级是浪费（便宜模型质量差）。策略是：**同一级重试 1 次，失败才降级。**

### 3.2 主动触发：健康度预判

更好的做法是**在调用之前就知道主模型不健康**，直接跳过：

```python
class HealthMonitor:
    def __init__(self, window_size=50):
        self.windows = defaultdict(lambda: deque(maxlen=window_size))

    def record(self, tier_name: str, ok: bool, latency: float):
        self.windows[tier_name].append((ok, latency, time.time()))

    def is_healthy(self, tier_name: str, min_success=0.9) -> bool:
        w = self.windows[tier_name]
        if len(w) < 10:                      # 样本不足，默认健康
            return True
        success_rate = sum(1 for ok, _, _ in w if ok) / len(w)
        return success_rate >= min_success

# 调用前检查
chain = [t for t in TIERS if monitor.is_healthy(t.name)]
if not chain:
    chain = TIERS                           # 全不健康也别放弃，按原样试
```

**这就是「熔断」的思路**：连续失败率达到阈值就暂时摘除这个节点，过一段时间再放回来试探。

优点：省掉「明知会失败还试一次」的延迟，用户感知更好。

### 3.3 成本触发：预算保护

```python
# 不想让某个用户/某个任务把预算烧穿
if task_budget_exhausted(task_id):
    # 只允许用便宜档
    allowed = [t for t in TIERS if t.cost_tier == "cheap"]
```

**这不算质量降级，是成本熔断。** 对内部工具、测试环境很实用——不至于一个失控任务烧掉月度预算。

---

## 四、降级的质量补偿

降级到便宜模型，质量下降是必然的。三个补偿手段：

### 4.1 提示词加强

便宜模型对指令遵循差些，降级时把提示写得更具体：

```python
PROMPT_BY_TIER = {
    "premium": "你是客服助手，回答用户问题。",
    "cheap": """你是客服助手。严格按以下规则回答：
1. 只回答知识库中有的内容，没有就说"未找到相关信息"
2. 不要编造任何数字或政策
3. 回答控制在 100 字内
4. 用礼貌、简洁的中文""",
}
```

**给便宜模型更硬、更短的指令**——它们处理复杂指令的能力弱，简单明确的规则反而执行得更好。

### 4.2 输出校验（降级时必做）

便宜模型更容易格式错、编内容。**降级后要加一层校验**：

```python
def validate_output(result, tier) -> bool:
    if tier.cost_tier == "cheap":
        # 结构校验
        if result.is_empty or len(result) > MAX_LEN:
            return False
        # 关键字段校验（如果你用了结构化输出）
        if not result.get("answer"):
            return False
    return True
```

**校验不过就继续降级**，而不是拿一个明显有问题的答案给用户。

### 4.3 明确告知用户（诚实降级）

```python
if tier.cost_tier != "premium":
    response.note = "当前为快速响应模式（服务质量可能略降）"
```

**或者更直接**：把降级信息放进返回，让前端决定怎么展示。**不要伪装成「一切正常」。** 用户能接受「现在忙，回答简化版」，不能接受被骗。

---

## 五、降级链的监控

降级链不能是「静默兜底」——你要知道它什么时候在起作用。

### 5.1 四个关键指标

```python
# 1. 每级使用占比
tier_usage_ratio{tier="gpt-4o"} 0.82
tier_usage_ratio{tier="qwen-max"} 0.09    ← 降级发生了
tier_usage_ratio{tier="4o-mini"} 0.08

# 2. 每级失败率
tier_failure_rate{tier="gpt-4o"} 0.11     ← 主模型不健康

# 3. 全链失败率（最终失败的任务占比）
all_tiers_failed_total 0.003              ← 还能接受

# 4. 降级任务的用户满意度对比
satisfaction{tier="premium"} 4.3
satisfaction{tier="cheap"} 3.1            ← 降级确实伤体验
```

### 5.2 告警条件

- 主模型成功率 < 95% 持续 5 分钟 → 告警
- 降级占比 > 30% 持续 10 分钟 → 告警（系统在慢性降级）
- 全链失败率 > 1% → 立即告警

**「降级占比」是最有预测价值的指标**。它比「主模型成功率」更早反映问题——有时候主模型成功率高，但因为慢导致频繁超时降级，这时候成功率看着正常，实际已经在降级了。

---

## 六、什么时候不要降级

降级不是万能药，有些场景应该直接失败而不是降级。

### 6.1 不能降的场景

- **降级模型会给出错误答案，而错误答案有危险后果**（医疗诊断、法律意见、财务合规）
- **任务明确要求特定模型能力**（超长上下文、特定工具调用、特定推理深度）
- **输出会被自动执行无人工审核**（降级模型生成的 SQL 直接跑）

**这些场景的正确做法是：失败 + 重试 + 明确告知，而不是降级。** 宁可系统暂时不可用，也不要给一个看起来对但实际错的答案。

### 6.2 可以降的场景

- 通用问答、内容摘要、闲聊
- 有兜底校验的生成任务
- 内部工具、非关键路径
- 成本敏感的批量任务

---

## 七、常见误区

**误区一：只配一个备选模型。** 单一备选可能同时挂（同供应商）。**至少一个跨供应商的。**

**误区二：降级时没检查能力兼容。** 降到一个不支持工具调用的模型，直接报错。**先判断 model capability。**

**误区三：降级后不做输出校验。** 便宜模型格式错、内容编，直接给用户就是事故。

**误区四：静默降级。** 用户不知道质量降了，还以为系统变笨了是 bug。**至少要让运维知道。**

**误区五：没有健康检查，全靠失败触发。** 每次都先失败一次再降，多花一次超时时间。**熔断式预判更好。**

**误区六：所有场景无脑降级。** 高风险场景降级 = 给错答案。宁可失败。

**误区七：降级链写在代码里改不动。** 应该可配置——线上发现某级持续失败，能即时摘除而不用发版。

---

## 小结

- 模型 API 抖动是常态，**单点依赖 = 把你的可用性交给第三方**。降级链是 Agent 系统的必要保险。
- 四级降级：**主模型 → 跨供应商同级别 → 便宜快模型 → 本地/缓存**。第 2 级要跨供应商（避免同源故障），第 4 级要不依赖外网。
- 触发方式两种：**失败降级（同级别先重试 1 次再降）+ 健康度预判（熔断，成功率低于阈值直接跳过）**。后者体验更好。
- 降级时三个必须：**检查能力兼容（便宜模型可能不支持工具）、输出校验（便宜模型更易编）、诚实告知（不要让用户误以为是正常质量）**。
- 监控核心是**降级占比**——它比「主模型成功率」更早暴露问题（慢导致的超时降级，成功率看着正常）。
- **不能降的场景**：错误答案有危险后果、要求特定模型能力、无人审核自动执行。这些宁可失败。
- 降级链要**可配置**——线上能即时摘除故障节点，不用发版。

模型是 Agent 的心脏，而降级链是备用起搏器。它不一定天天用上，但缺了它，一次第三方故障就能让你的系统停摆——而用户不会区分「是你的问题还是 OpenAI 的问题」。
