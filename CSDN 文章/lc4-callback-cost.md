# 用回调统计 token 与成本：把每一次调用的账算清楚

> 月底财务问："这个 AI 功能这个月花了多少钱？"
> 你打开后台，只有一个总数。
>
> 哪个功能贵、哪个用户用得凶、哪次调用是异常放大——
> **全都要靠回调从调用现场采集。**

## 一、回调能拿到什么

LangChain 的回调系统会在每个关键节点触发钩子，其中最有价值的是这三个：

```python
from langchain_core.callbacks import BaseCallbackHandler

class CostTracker(BaseCallbackHandler):
    def on_llm_end(self, response, **kwargs):
        # response.llm_output 里有 token 用量
        print(response.llm_output)

    def on_chat_model_start(self, serialized, messages, **kwargs):
        # 调用开始
        pass
```

`on_llm_end` 的 `response` 里包含：

```python
{
    'token_usage': {
        'prompt_tokens': 812,
        'completion_tokens': 245,
        'total_tokens': 1057,
    },
    'model_name': 'gpt-4o-mini',
    'finish_reason': 'stop',
}
```

**不同厂商字段名不完全一样**，要兼容处理：

```python
def extract_usage(response) -> dict:
    """从各种形态的 response 里抽出 token 用量"""
    out = response.llm_output or {}

    # OpenAI 系
    if "token_usage" in out:
        u = out["token_usage"]
        return {"in": u.get("prompt_tokens", 0), "out": u.get("completion_tokens", 0)}

    # 部分国产模型 / 兼容接口放在 usage 里
    if "usage" in out:
        u = out["usage"]
        return {"in": u.get("input_tokens", u.get("prompt_tokens", 0)),
                "out": u.get("output_tokens", u.get("completion_tokens", 0))}

    # 从 generations 的 message 里找（新版 langchain-openai）
    for gen_list in response.generations:
        for gen in gen_list:
            msg = getattr(gen, "message", None)
            if msg and getattr(msg, "usage_metadata", None):
                m = msg.usage_metadata
                return {"in": m.get("input_tokens", 0), "out": m.get("output_tokens", 0)}

    return {"in": 0, "out": 0}
```

## 二、一个完整的成本追踪器

```python
import time
from collections import defaultdict
from langchain_core.callbacks import BaseCallbackHandler

# 单价表（元 / 1M tokens），按需更新
PRICING = {
    "gpt-4o":        {"in": 18.0,  "out": 72.0},
    "gpt-4o-mini":   {"in": 1.1,   "out": 4.3},
    "claude-3-5-sonnet": {"in": 21.6, "out": 108.0},
    "qwen-plus":     {"in": 0.8,   "out": 2.0},
}

class CostTracker(BaseCallbackHandler):
    def __init__(self):
        self.records = []            # 每次调用的明细
        self._start = {}

    def on_chat_model_start(self, serialized, messages, *, run_id, **kwargs):
        self._start[run_id] = time.perf_counter()

    def on_llm_end(self, response, *, run_id, **kwargs):
        usage = extract_usage(response)
        model = (response.llm_output or {}).get("model_name", "unknown")

        # 价格查找（做前缀匹配，兼容 gpt-4o-mini-2024-07-18 这种带版本号的）
        price = next((v for k, v in PRICING.items() if model.startswith(k)), {"in": 0, "out": 0})
        cost = usage["in"] / 1e6 * price["in"] + usage["out"] / 1e6 * price["out"]

        self.records.append({
            "run_id": str(run_id),
            "model": model,
            "in_tokens": usage["in"],
            "out_tokens": usage["out"],
            "cost": cost,
            "latency": time.perf_counter() - self._start.pop(run_id, time.perf_counter()),
        })

    def summary(self) -> dict:
        return {
            "calls": len(self.records),
            "in_tokens": sum(r["in_tokens"] for r in self.records),
            "out_tokens": sum(r["out_tokens"] for r in self.records),
            "cost": sum(r["cost"] for r in self.records),
            "latency_p50": percentile([r["latency"] for r in self.records], 50),
            "by_model": group_sum(self.records, "model", "cost"),
        }
```

挂上去：

```python
tracker = CostTracker()
result = chain.invoke(inputs, config={"callbacks": [tracker]})
print(tracker.summary())
```

**注意：回调是跟着 `config` 走的，整条链内所有 LLM 调用都会被统计**，包括子链和工具内部。

## 三、按业务维度归因

只有总数不够，要能回答"哪个功能贵"。做法是**在调用时打标签**：

```python
result = chain.invoke(
    inputs,
    config={
        "callbacks": [tracker],
        "tags": ["feature:doc_qa", f"user:{user_id}", f"env:{ENV}"],
    },
)
```

在回调里读出来：

```python
def on_llm_end(self, response, *, tags, **kwargs):
    self.records[-1]["tags"] = tags
    self.records[-1]["feature"] = next((t.split(":")[1] for t in tags if t.startswith("feature:")), "unknown")
    self.records[-1]["user"] = next((t.split(":")[1] for t in tags if t.startswith("user:")), "anonymous")
```

于是可以出一张表：

```
功能         调用次数    输入token   输出token    成本(元)
doc_qa       12,340      8,912,000   1,203,000    15.79
chat         45,120      3,200,000   2,800,000     16.40
summarize     2,100      6,400,000     980,000      8.04
```

**归因维度建议：功能 > 用户 > 环境 > 模型。** 这四个够定位绝大多数问题。

## 四、按用户统计：发现异常放大

单个用户消耗突然飙升，通常意味着**循环调用**或**prompt 注入**。

```python
from collections import defaultdict

user_cost = defaultdict(float)
user_calls = defaultdict(int)

class AbuseDetector(BaseCallbackHandler):
    def on_llm_end(self, response, *, tags, **kwargs):
        uid = next((t.split(":")[1] for t in tags if t.startswith("user:")), None)
        if not uid:
            return
        usage = extract_usage(response)
        model = (response.llm_output or {}).get("model_name", "")
        price = PRICING.get(model, {"in": 0, "out": 0})
        user_cost[uid] += usage["in"] / 1e6 * price["in"] + usage["out"] / 1e6 * price["out"]
        user_calls[uid] += 1

        # 实时告警：单次会话成本超阈值
        if user_cost[uid] > 5.0:
            alert(f"用户 {uid} 本次会话已消耗 {user_cost[uid]:.2f} 元")
```

**阈值告警比事后统计有用得多**——可以及时掐断异常会话。

## 五、预算控制：把"统计"变成"拦截"

统计是为了行动。用回调可以在**花超之前拦下来**：

```python
class BudgetGuard(BaseCallbackHandler):
    def __init__(self, budget: float):
        self.budget = budget
        self.spent = 0.0

    def on_llm_start(self, serialized, prompts, **kwargs):
        # 调用开始前检查
        if self.spent >= self.budget:
            raise BudgetExceededError(
                f"本次会话预算 {self.budget} 元已用完（已花费 {self.spent:.2f} 元）"
            )

    def on_llm_end(self, response, **kwargs):
        usage = extract_usage(response)
        model = (response.llm_output or {}).get("model_name", "")
        price = PRICING.get(model, {"in": 0, "out": 0})
        self.spent += usage["in"] / 1e6 * price["in"] + usage["out"] / 1e6 * price["out"]
```

**在 `on_llm_start` 里抛异常，能直接中断链执行**，这是回调能做的最强硬的动作。

配一个 `RunnableWithFallbacks` 优雅降级：

```python
chain = primary_chain.with_fallbacks([
    cheap_chain,                                   # 换成便宜模型
    RunnableLambda(lambda x: "当前请求量较大，请稍后重试"),  # 最终兜底
])
```

## 六、缓存命中率：省钱的关键指标

成本优化里，**缓存命中率比单价更重要**。回调里可以统计：

```python
class CacheStats(BaseCallbackHandler):
    def __init__(self):
        self.total = 0
        self.cached = 0

    def on_llm_start(self, serialized, prompts, **kwargs):
        self.total += 1

    def on_llm_end(self, response, **kwargs):
        usage = extract_usage(response)
        # 有些服务端会返回 cached_tokens
        out = response.llm_output or {}
        if out.get("token_usage", {}).get("cached_tokens", 0) > 0:
            self.cached += 1
```

命中率高说明**同样的请求被重复发了很多次**，可以针对性加语义缓存。

## 七、别忘了这些隐藏成本

纯看 token 单价会低估成本，还有：

| 成本项 | 怎么统计 |
|---|---|
| 向量检索 | 按 QPS 和存储量算 |
| Embedding 调用 | 在 `on_retriever_start` 里也能拦到 |
| 重排模型 | 自建模型的 GPU 成本 |
| 网络出口 | 跨区调用 |
| **失败的调用** | 重试产生的重复计费 ⚠️ |

最后一条最容易忽略：**一次失败重试三次，就是三次计费**。在回调里记录 `finish_reason`，统计"因异常结束"的比例：

```python
def on_llm_end(self, response, **kwargs):
    for gen_list in response.generations:
        for gen in gen_list:
            if getattr(gen, "generation_info", {}).get("finish_reason") == "length":
                self.truncated += 1
```

`finish_reason == "length"` 意味着**输出被 max_tokens 截断了**——钱花了但答案不完整，是纯浪费。

## 八、把数据落到监控系统

```python
class MetricsExporter(BaseCallbackHandler):
    def on_llm_end(self, response, *, tags, run_id, **kwargs):
        usage = extract_usage(response)
        model = (response.llm_output or {}).get("model_name", "")
        feature = extract_tag(tags, "feature")

        # 推给 Prometheus
        LLM_TOKENS.labels(model=model, direction="in", feature=feature).inc(usage["in"])
        LLM_TOKENS.labels(model=model, direction="out", feature=feature).inc(usage["out"])
        LLM_COST.labels(model=model, feature=feature).inc(compute_cost(model, usage))
        LLM_CALLS.labels(model=model, feature=feature).inc()
```

在 Grafana 上就能看到**分功能的成本曲线**，一眼看出哪个功能在烧钱。

## 九、几个实践建议

**① 回调要异步、要容错。**
回调里抛异常会中断主流程（除非是刻意的预算拦截）。**统计代码必须 try/except 包住**：

```python
def on_llm_end(self, response, **kwargs):
    try:
        self._record(response)
    except Exception:
        log.exception("成本统计失败，不影响主流程")
```

**② 别在每个请求里 new 一个 tracker。**
用进程级单例 + 定期 flush，避免高频创建对象。

**③ 单价表要可配置。**
模型价格变动频繁，硬编码在代码里每次都要发版。放配置文件或配置中心。

**④ 只对"贵"的调用做精细统计。**
高频低成本的调用做采样即可，全量统计的写入开销可能比省下的钱还多。

**⑤ 给用户一个用量查询入口。**
B 端产品里，"我这个月用了多少"是常见诉求。**从第一天就把数据按用户维度存下来**，后期补数据非常痛苦。

## 十、小结

```python
tracker = CostTracker()
chain.invoke(inputs, config={"callbacks": [tracker], "tags": ["feature:doc_qa", "user:123"]})
print(tracker.summary())
```

四个层次，逐级递进：

```
1. 统计总量        → 知道花了多少
2. 按维度归因      → 知道谁花的
3. 异常告警        → 及时发现问题
4. 预算拦截        → 主动控制成本
```

**只做第 1 层等于没做。** 真正有价值的是"能定位到具体功能/用户/调用"——这才是成本优化的起点。
