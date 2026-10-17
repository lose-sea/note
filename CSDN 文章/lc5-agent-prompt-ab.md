# Prompt A/B：用真实流量验证你的改动

你在本地测了新 prompt，评测集涨了 3 个点，快照对比也没发现问题。上线！

三周后看数据：整体满意度没动，但有一类用户投诉变多了。

**本地测的上升，到线上不一定成立。** 评测集是你挑的问题，真实流量是用户想怎么问就怎么问——分布不一样，结果就不一样。

Prompt A/B 就是把验证放到真实流量上：**同一时间，一部分请求用旧 prompt，一部分用新的，对比指标，用数据决定哪个赢。**

---

## 一、为什么要上线验证

### 1.1 本地验证的三个盲区

**盲区一：评测集分布 ≠ 真实分布。**
你精心挑的 100 个问题，可能是 40% 简单问答 + 40% 多轮 + 20% 复杂任务。真实流量也许是 85% 是简单问题。你的新 prompt 在复杂任务上更好，在简单问题上更啰嗦——本地整体涨，线上整体跌。

**盲区二：没有干扰变量。**
本地测试时你知道自己在测新 prompt，会不自觉挑适合它的问题。线上没有这个偏差。

**盲区三：用户行为不可预测。**
新 prompt 让 Agent 变得更爱追问澄清——本地看着「更严谨了」，线上用户觉得「变啰嗦了」直接流失。

### 1.2 A/B 的三个前提

不是所有改动都值得 A/B：

| 该 A/B | 不该 A/B |
|-------|---------|
| prompt 大改（结构、指令变化） | 修 typo、改标点 |
| 影响主流程的改动 | 内部模块优化 |
| 效果有争议的改动 | 已确认修复的 bug |
| 低频但重要的路径 | 上线前就已验证过的小改动 |

**判据：这个改动的不确定性高吗？高就 A/B，低就直接上。**

---

## 二、实验设计

### 2.1 分流：按什么分

**按用户分（推荐）**

```python
def assign_variant(user_id: str, experiment: str) -> str:
    """同一用户始终落在同一组，避免体验不一致。"""
    # 稳定哈希，保证同一用户分流结果不变
    h = hashlib.md5(f"{user_id}:{experiment}".encode()).hexdigest()
    bucket = int(h[:8], 16) % 100
    return "new" if bucket < 50 else "old"
```

**按请求分（谨慎用）**

```python
def assign_by_request(request_id: str) -> str:
    ...
```

请求级分流会让同一用户前后两次体验不一致（第一次旧 prompt，第二次新 prompt）——对对话类产品，这种割裂感很明显。

**按用户分是默认选择**，除非你的场景没有用户概念（匿名访客）。

### 2.2 流量分配

```python
EXPERIMENT_CONFIG = {
    "prompt_v2_4": {
        "variants": {"old": 50, "new": 50},     # 各 50%
        "enabled": True,
        "min_sample": 1000,                      # 少于这个样本不出结论
        "max_duration_days": 14,
    },
}
```

**不要一上来就五五开。** 稳妥的做法：

- 第一天：新 prompt 5% 流量，只看安全指标（错误率、崩溃率）
- 安全指标没问题 → 放到 20%，看效果指标
- 效果指标有优势 → 放到 50%，做统计显著性检验
- 显著 → 全量

**灰度是 A/B 的一部分，不是额外的流程。** 一上来五五开，如果新 prompt 有严重 bug，一半用户直接受害。

---

## 三、指标：看什么

### 3.1 分层指标

**护栏指标（Guardrail）—— 新 prompt 不能更差**

```
- 错误率（工具调用失败、解析失败）
- 平均步数（变多说明在绕路）
- token 成本（变贵要能解释）
- 响应时间
- 投诉/负反馈率
```

**效果指标（Primary）—— 新 prompt 要更好的那个**

```
- 答案正确率（人工标注抽样 or LLM 评判）
- 用户采纳率（复制/使用了答案）
- 「有帮助」点击率
- 任务完成率（有没有成功解决）
```

**探索指标（Secondary）—— 辅助判断**

```
- 追问率（用户接着问，说明上一句没解决）
- 会话轮数
- 转化率（业务相关：下单、留资）
```

### 3.2 关键：指标要能算到 variant 上

```python
result = await agent.run(question, variant=variant)
metrics.record(
    variant=variant,
    correct=judge(result),
    steps=len(trace),
    tokens=result.usage.total_tokens,
    feedback=result.feedback,
)
```

**每次请求都要带上 variant 标签**——从入口到日志到指标，全链路带上。漏了任何一个环节，实验数据就是断的。

### 3.3 负反馈是最强的信号

```python
# 用户点「答案没用」/「重新生成」/ 直接退出
negative_events = count("thumb_down", "regenerate", "abandon")
```

**用户主动表达不满，比 LLM 评判可靠得多。** 哪怕正确率持平，负反馈涨了也说明新 prompt 有问题。

---

## 四、统计显著性：多少个样本够

### 4.1 别看着「好像更好」就下结论

两组各 30 个请求，新 prompt 正确率 73% vs 旧的 70%——**这什么都不能说明**，随机波动就能造成这个差距。

**简单检验**：

```python
from math import sqrt

def is_significant(p1: float, n1: int, p2: float, n2: int,
                   threshold: float = 0.05) -> bool:
    """两个比例的 z 检验。"""
    p_pool = (p1 * n1 + p2 * n2) / (n1 + n2)
    se = sqrt(p_pool * (1 - p_pool) * (1/n1 + 1/n2))
    if se == 0:
        return False
    z = abs(p1 - p2) / se
    return z > 1.96          # 95% 置信度
```

**样本量参考**（正确率从 70% 提升到 78%，95% 置信 + 80% 功效）：**每组约 900+ 个请求。** 低于这个数，别谈显著。

### 4.2 多久能收数据

```
日均请求 1000 → 一天每组 500 → 两天出初步结论
日均请求 100  → 一天每组 50  → 两周才够
```

**低流量产品做 A/B 要么等，要么只做极端保守的对比。** 另一种思路：只在关键路径上做实验，把流量集中起来，而不是分散在所有 prompt 上。

---

## 五、结果怎么看

### 5.1 三种结局

**新 prompt 全面胜出 → 全量**

```
护栏指标：错误率 3.1% → 2.4% ✓，成本持平 ✓，步数持平 ✓
效果指标：正确率 70% → 78%（显著）✓，负反馈 12% → 7% ✓
结论：全量上线
```

**互有胜负 → 判断关键指标**

```
正确率 +5%（显著）✓
但步数 +20% ✗（说明在绕路）、token 成本 +25% ✗
结论：要判断多花的 25% 换 5 个点正确率值不值。
      如果是核心链路，值；如果是 FAQ 问答，不值。
```

**无明显差异 → 回退**

```
所有指标都在噪声范围内
结论：这个改动没有价值，回退旧的（更熟悉的版本），别为改而改。
```

### 5.2 分割看：别只看总体

```python
# 按问题类型拆开看
by_type = {}
for r in results:
    by_type.setdefault(r.question_type, []).append(r)

for t, rs in by_type.items():
    old = [r for r in rs if r.variant == "old"]
    new = [r for r in rs if r.variant == "new"]
    print(f"{t}: 旧 {mean(old):.3f} vs 新 {mean(new):.3f}")
```

**总体持平但某类暴跌的情况很常见**——比如新 prompt 在处理长问题时更好，但把简单问答变得更啰嗦，两类一平均看着没变。**不拆开看，你就错过了一个真实退化。**

---

## 六、工程实现

### 6.1 配置化，不发版

```python
# prompt 配置从 DB/配置中心读，支持按 variant 取
def get_prompt(variant: str) -> str:
    return config_service.get(f"agent.prompt.{variant}")

# 实验配置也配置化，随时开关
def is_experiment_active(name: str) -> bool:
    return config_service.get_bool(f"experiments.{name}.enabled", False)
```

**prompt 不能硬编码在代码里**——否则每次改 prompt 都要发版，实验效率极低。

### 6.2 埋点必须全链路

```python
# 入口
request_id = uuid4().hex[:12]
variant = assign_variant(user_id, exp_name)

# 全链路携带
log.info("agent.start", extra={"request_id": request_id,
                               "variant": variant, "exp": exp_name})

# LLM 调用
resp = await llm.chat(messages, prompt_version=get_prompt(variant),
                      tags={"variant": variant, "exp": exp_name})

# 结果上报
monitor.record(request_id, variant=variant, exp=exp_name, **metrics)
```

**没有 `variant` 贯穿全链路，实验数据就是废的。**

### 6.3 兜底：实验本身要可控

```python
# 新 variant 的错误率飙到 20% → 自动熔断，切回旧的
if experiment.auto_kill_threshold and error_rate(new) > 0.20:
    experiment.set_traffic("new", 0)
    alert("实验 X 已自动熔断：错误率异常")
```

**自动熔断必须有。** 新 prompt 有严重 bug 时，等人工发现用户已经骂声一片了。

---

## 七、常见误区

**误区一：样本量不够就下结论。** 每组几十个请求看正确率，随机波动能造成 5% 的差距。**先算需要多少样本，再等够数据。**

**误区二：按请求分流而不是按用户。** 同一用户前后体验不一致，对话类产品尤其致命。

**误区三：只看总体指标。** 总体持平可能是一升一降。**必须按问题类型拆开看。**

**误区四：忽略护栏指标。** 正确率涨了但成本涨 50%、步数翻倍，这个「胜利」可能不划算。

**误区五：没有自动熔断。** 新 prompt 有 bug 时，人工发现太慢。

**误区六：prompt 硬编码在代码里。** 每次实验都要发版，迭代速度慢十倍。

**误区七：实验跑一次就下结论，不看长期。** 有的改动短期涨长期跌（用户新鲜感）。重要实验至少跑满一周，覆盖工作日和周末。

---

## 八、一套最小可用流程

```bash
# 1. 本地先过（单元测试 + 快照对比），确认没有明显劣化
pytest tests/unit -q && python snapshot.py diff

# 2. 上灰度：5% 流量，跑一天，只看护栏指标
#    - 错误率、成本、步数、负反馈
# 3. 护栏 OK → 提到 50%，跑到样本量够（每组 900+）
# 4. 看效果指标 + 按类型拆分 + 显著性检验
# 5. 显著胜出 → 全量；无差异 → 回退；互有胜负 → 按场景判断
# 6. 结论写进实验记录（供下次参考）
```

**第 6 步别省。** 三个月后有人问「为什么这个 prompt 长这样」，有实验记录参考答案，没有就只能猜。

---

## 小结

- Prompt A/B 解决的是**本地验证的分布偏差**——评测集是你挑的，真实流量是用户随意的，两者不一样。
- 分流**按用户不按请求**（避免同一用户前后体验割裂）；灰度要渐进：**5% 看护栏 → 50% 看效果 → 全量**。一上来五五开，有 bug 时一半用户受害。
- 指标分三层：**护栏（错误率/成本/步数/负反馈，不能更差）、效果（正确率/采纳率/完成率，要更好）、探索（追问率/轮数）**。
- **负反馈是最强的信号**，比 LLM 评判可靠。
- 样本量是硬门槛：**每组 900+ 才有统计显著性**。流量小的产品要么等，要么集中火力在关键路径做实验。
- 分析必须**按问题类型拆分**——总体持平常是一升一降，不拆就漏掉真实退化。
- 工程三要素：**prompt 配置化（不发版）、variant 全链路埋点、自动熔断（错误率飙高自动切回旧版）**。
- 任何改动都有不确定性，A/B 的价值不是「证明新 prompt 更好」，而是「在你全量之前，先用小流量把风险试掉」。

本地测试决定「敢不敢上线」，A/B 决定「该不该全量」。两个都做，prompt 迭代才不是碰运气。
