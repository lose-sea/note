# 可观测性三板斧：Trace、指标、日志怎么配

> 用户说"刚才那次回答不对"。
> 你打开日志，只有一行 `INFO: 200 OK`。
> 没有输入、没有中间步骤、没有用了哪个模型。
>
> **这就是没有可观测性的代价。**

## 一、三者不是一回事

| 维度 | 回答什么问题 | 数据形态 | 保留期 |
|---|---|---|---|
| **Trace** | 这一次请求经历了什么？ | 调用树 | 短（7~30 天） |
| **指标** | 整体趋势怎么样？ | 时间序列 | 长（1 年+） |
| **日志** | 具体发生了什么？ | 文本事件 | 中（30~90 天） |

**Trace 看个案，指标看趋势，日志看细节。** 三者缺一不可。

## 二、第一板斧：Trace

LLM 应用的 Trace 比普通微服务更重要——因为**一次请求内部的调用次数多**（检索 → 生成 → 工具 → 再生成），而且**每一步的输出都是自然语言**，不 trace 根本不知道为什么答案错了。

LangSmith 一行开启：

```python
import os
os.environ["LANGCHAIN_TRACING_V2"] = "true"
os.environ["LANGCHAIN_API_KEY"] = "..."
os.environ["LANGCHAIN_PROJECT"] = "prod-agent-v2"
```

之后所有链调用自动上报，LangSmith 里能看到：

```
RunnableSequence
├── RunnableParallel
│   ├── VectorStoreRetriever  (1.2s, 5 docs)
│   └── RunnablePassthrough
├── ChatPromptTemplate  (prompt: 3.4k tokens)
├── ChatOpenAI  (2.1s, 812 in / 245 out, $0.0012)
└── StrOutputParser
```

**每个节点的输入输出都能看到**——这才是"能调试"的意思。

**给 trace 加上下文**，便于过滤：

```python
config = {
    "configurable": {"thread_id": tid},
    "tags": ["env:prod", f"user:{user.id}", "feature:doc_qa"],
    "metadata": {
        "user_tier": user.tier,
        "session_turn": turn_count,
        "version": APP_VERSION,
    },
}
```

`metadata` 里放**能帮你定位问题的维度**：用户等级、版本号、会话轮次。

**注意隐私**：

```python
from langchain_core.tracers.langchain import LangChainTracer

# 敏感字段脱敏（配合前面的脱敏篇）
os.environ["LANGCHAIN_HIDE_INPUTS"] = "false"       # 保留输入（已脱敏）
os.environ["LANGSMITH_HIDE_OUTPUTS"] = "false"
```

或者用**自建 trace**（Langfuse / Phoenix），数据不出内网。

## 三、第二板斧：指标

Trace 是个案，指标是全局。用 Prometheus 采集：

```python
from prometheus_client import Counter, Histogram, Gauge, make_asgi_app

# 请求级
REQUESTS = Counter("agent_requests_total", "请求总数",
                   ["status", "feature", "user_tier"])
LATENCY = Histogram("agent_latency_seconds", "端到端延迟",
                    ["feature"],
                    buckets=[.5, 1, 2, 5, 10, 30, 60, 120, 300])

# LLM 级
TOKENS = Counter("llm_tokens_total", "token 用量",
                 ["model", "direction", "feature"])
COST = Counter("llm_cost_yuan_total", "成本（元）", ["model", "feature"])
LLM_LATENCY = Histogram("llm_latency_seconds", "LLM 调用延迟", ["model"])

# 工具级
TOOL_CALLS = Counter("tool_calls_total", "工具调用", ["tool", "status"])
TOOL_LATENCY = Histogram("tool_latency_seconds", "工具延迟", ["tool"])

# 检索级
RETRIEVAL_DOCS = Histogram("retrieval_docs_count", "召回文档数",
                           buckets=[0, 1, 2, 3, 5, 8, 12, 20])
```

**接入方式**：

```python
from langchain_core.callbacks import BaseCallbackHandler

class MetricsCallback(BaseCallbackHandler):
    def __init__(self, feature: str):
        self.feature = feature
        self._start = {}

    def on_llm_start(self, serialized, prompts, *, run_id, **kwargs):
        self._start[run_id] = time.perf_counter()

    def on_llm_end(self, response, *, run_id, **kwargs):
        model = (response.llm_output or {}).get("model_name", "unknown")
        usage = extract_usage(response)

        TOKENS.labels(model=model, direction="in", feature=self.feature).inc(usage["in"])
        TOKENS.labels(model=model, direction="out", feature=self.feature).inc(usage["out"])
        COST.labels(model=model, feature=self.feature).inc(
            compute_cost(model, usage))
        LLM_LATENCY.labels(model=model).observe(
            time.perf_counter() - self._start.pop(run_id, time.perf_counter()))

    def on_tool_end(self, output, *, run_id, **kwargs):
        TOOL_CALLS.labels(tool=kwargs.get("name", "?"), status="ok").inc()

    def on_tool_error(self, error, **kwargs):
        TOOL_CALLS.labels(tool=kwargs.get("name", "?"), status="error").inc()
```

挂到每次调用：

```python
result = graph.invoke(inputs, config={
    "callbacks": [MetricsCallback(feature="doc_qa")],
    "tags": [f"user:{user.id}"],
})
```

## 四、必须盯住的六个指标

| 指标 | 告警阈值建议 | 说明 |
|---|---|---|
| 请求成功率 | < 98% | 最基础 |
| P95 延迟 | > 30s | 体验红线 |
| **单位请求成本** | 突增 50% | 成本异常 |
| 工具失败率 | > 5% | 外部依赖问题 |
| **重试率** | > 10% | 早于失败率预警 |
| 检查点表大小 | 增长过快 | 存储异常 |

**"重试率"是最被低估的指标**——失败率还是 0 的时候，重试率可能已经 30% 了。它比失败率更早暴露问题。

## 五、第三板斧：结构化日志

`print` 和裸 `logging.info("xxx")` 在分布式环境里没用。**用结构化日志（JSON）**：

```python
import structlog

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,      # 自动带上上下文
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(ensure_ascii=False),
    ],
)

log = structlog.get_logger()
```

**用 `contextvars` 自动绑定请求上下文**：

```python
import structlog
from structlog.contextvars import bind_contextvars, clear_contextvars

@app.middleware("http")
async def add_context(request, call_next):
    clear_contextvars()
    trace_id = request.headers.get("x-trace-id") or str(uuid.uuid4())
    bind_contextvars(trace_id=trace_id, path=request.url.path)
    response = await call_next(request)
    response.headers["x-trace-id"] = trace_id
    return response
```

之后所有日志自动带上 `trace_id`：

```python
log.info("graph_invoked", thread_id=tid, feature="doc_qa")
# {"event": "graph_invoked", "thread_id": "...", "feature": "doc_qa",
#  "trace_id": "...", "path": "/chat", "level": "info", "timestamp": "..."}
```

**排查时用 trace_id 一搜，整个请求的日志都在。**

## 六、日志要记什么

**必须记**：

```python
# 1. 请求入口
log.info("request_received", question_len=len(q), user_id=user.id)

# 2. 检索结果
log.info("retrieval_done", docs=len(docs), top_score=docs[0].score if docs else None)

# 3. 工具调用
log.info("tool_invoked", tool=name, args_summary=summarize(args), duration_ms=ms)

# 4. LLM 调用
log.info("llm_called", model=model, in_tokens=u["in"], out_tokens=u["out"], cost=cost)

# 5. 异常
log.error("llm_failed", model=model, error=str(e), exc_info=True)

# 6. 业务异常（不是技术异常）
log.warning("refused_to_answer", reason="no_relevant_docs", question_len=len(q))
```

**不要记**：

- 完整的用户输入（可能含 PII）→ 记长度和哈希
- 完整的模型输出（太长）→ 记摘要
- 密钥、token → 永远不要
- 高频无信息量的日志（如每次心跳）

**最后一条特别重要**：日志量大的时候，**它本身就成为成本**。日志服务是按量计费的。

## 七、把它们串起来

**透传 trace_id 是关键**：

```python
config = {
    "configurable": {"thread_id": tid},
    "tags": [f"trace:{trace_id}", f"user:{user.id}"],
    "metadata": {"trace_id": trace_id, "feature": feature},
    "callbacks": [MetricsCallback(feature)],
}
```

这样：

- **Trace** 里能按 `trace:{trace_id}` 过滤；
- **指标**里带上 feature 维度；
- **日志**里通过 contextvars 自动带上；
- **LangSmith 的 trace 链接**可以放进日志：

```python
log.info("graph_done", langsmith_url=build_langsmith_url(run_id))
```

**从告警 → 指标 → trace → 日志，一路可追**，才算真正可观测。

## 八、告警配置

指标要配告警才有用：

```yaml
groups:
  - name: llm-agent
    rules:
      - alert: HighErrorRate
        expr: rate(agent_requests_total{status="error"}[5m]) > 0.02
        for: 5m
        annotations:
          summary: "错误率超 2%"

      - alert: HighLatency
        expr: histogram_quantile(0.95, rate(agent_latency_seconds_bucket[5m])) > 30
        for: 10m

      - alert: CostSpike
        expr: increase(llm_cost_yuan_total[1h]) > 100
        annotations:
          summary: "1 小时成本超 100 元"

      - alert: ToolFailureSpike
        expr: |
          rate(tool_calls_total{status="error"}[5m])
          / rate(tool_calls_total[5m]) > 0.05
        for: 5m
```

**告警要分优先级**：

- P0（打电话）：服务不可用、成本失控
- P1（群里 @）：错误率、延迟超标
- P2（日报）：趋势异常、容量预警

**别把所有告警都设成 P0**——狼来了三次，就没人看告警了。

## 九、成本控制清单

因为 LLM 应用的特殊性，成本监控要单独说：

```python
# 按功能、用户、模型三个维度
COST.labels(model=m, feature=f).inc(c)
USER_COST.labels(user_id=uid).inc(c)

# 单次请求成本（用来发现异常请求）
REQUEST_COST.observe(c)
```

**三个必须有的看板**：

1. **日成本趋势** —— 看是否失控
2. **Top 10 消耗用户** —— 找异常用户
3. **分功能成本占比** —— 找优化重点

## 十、小结

```
Trace  → 出问题时"能复现"
指标  → 平时"看得见趋势"
日志  → 细节"能追溯"
```

落地顺序（从易到难）：

```
1. 开 LangSmith trace（一行环境变量）
2. 加结构化日志 + trace_id
3. 加 Prometheus 指标
4. 配告警
5. 做成本看板
```

**没有可观测性的 Agent 是黑盒。** 它可能工作得很好，但一旦出问题，你连"哪一步错了"都不知道——**这才是最贵的成本**。
