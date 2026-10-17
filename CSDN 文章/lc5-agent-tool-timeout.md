# 工具超时与降级：一个慢接口怎么拖垮整个 Agent

Agent 调用外部工具，最怕的不是失败，是**不确定地慢**。

失败是明确的——报错、异常、返回 500，你可以在代码里处理。慢是隐蔽的——工具过了 40 秒才返回，或者压根不返回。这时候 Agent 的整个循环挂在一次调用上，用户看着加载动画转了一分钟，最后要么超时要不说「系统繁忙」。

外部接口慢是常态：下游服务抖动、网络问题、数据量大、对方扩容没跟上。**工具层的超时和降级，就是 Agent 系统的保险丝。** 这一篇讲清楚超时怎么设、降级怎么做，以及两者怎么配合。

---

## 一、为什么工具层必须有超时

### 1.1 慢比错更致命

一次失败的调用，Agent 可以重试、可以换方案、可以告知用户。一次**悬而不决**的调用，什么都没法做——Agent 在等，用户在等，任务在等。

我见过一个线上事故：Agent 的「查询报表」工具对接了一个内部服务，那天对方在做索引重建，单次响应从 2 秒涨到 90 秒。Agent 没有超时限制，于是一次任务卡了 90 秒。更糟的是并发用户多，请求全挂住，Agent 服务的连接池被打满，**连不调报表工具的用户也一起卡死**。

**一个慢工具，污染的是整个服务。**

### 1.2 慢的三种形态

| 形态 | 表现 | 处理 |
|------|------|------|
| 一直不返回 | 连接挂着，没数据没断开 | 读超时 |
| 传输中断 | 建立连接了，传一半停住 | 读超时 |
| 返回了但内容残缺 | 状态码 200，body 截断 | 校验失败按错误处理 |

**第三种最阴险**——HTTP 状态是 200，你以为成功了，实际拿了个半截 JSON。解析时报 `Expecting value`，你还以为是自己的 bug。

**对策：拿到响应后必须校验完整性**（JSON 能解析、必填字段存在、长度合理），不能只看状态码。

---

## 二、超时怎么设

### 2.1 三层超时，不能只有一个

```python
import httpx

async def call_tool(url: str, payload: dict):
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            url, json=payload,
            timeout=httpx.Timeout(
                connect=5.0,      # 连接超时：5 秒连不上，服务有问题
                read=30.0,        # 读超时：连上后 30 秒没数据，对方卡住
                write=10.0,       # 写超时：发请求体超时
                pool=5.0,         # 从连接池拿连接超时
            ),
        )
        return resp
```

三层各自的含义：

- **connect（连不上）**：DNS、网络、对方端口。设 3~5 秒足够——能连的服务不会让你等 5 秒以上
- **read（连上了没数据）**：对方收到了但处理不完或者挂了。按 P99.9 的耗时 × 2 来设
- **pool（拿不到连接）**：连接池满了，说明并发挤爆了，快速失败比排队好

**单一 timeout 是常见错误**——它只能设一个值，没法区分「连不上」和「处理慢」，也没法对连接池单独处理。

### 2.2 怎么定具体数值

按工具类型分档，别一刀切：

| 工具类型 | connect | read | 理由 |
|---------|---------|------|------|
| 本地/内网查询 | 2s | 5s | 内网不该慢，慢就是有问题 |
| 外部 API（第三方） | 5s | 20s | 依赖对方 SLA |
| LLM 调用 | 5s | 60s | 生成慢是可预期的 |
| 批量/报表类 | 5s | 120s | 本身就耗时 |
| 文件处理/转码 | 5s | 300s | CPU 密集，合理慢 |

**先统计线上 P50/P95/P99 耗时，再定 read timeout。** 我的经验：设成 **P99.9 的 1.5~2 倍**。低于 P99.9 会误杀正常请求，高于 2 倍则用户等太久。

### 2.3 超时后必须做三件事

```python
async def call_with_timeout(url, payload, read_timeout=30.0):
    try:
        resp = await client.post(url, json=payload, timeout=read_timeout)
        resp.raise_for_status()
        return resp.json()
    except httpx.TimeoutException as e:
        # 1. 记日志（超时是高优告警信号）
        logger.warning("tool.timeout", extra={"url": url, "elapsed": read_timeout})
        # 2. 指标（按 URL + 超时维度）
        METRICS.tool_timeout.labels(url=url).inc()
        # 3. 返回结构化错误，让上层能判断
        raise ToolTimeout(f"{url} 超过 {read_timeout}s 未返回")
```

**超时不能只当异常吞掉。** 它要变成一个可观测的信号——某个工具超时率突然从 0.1% 涨到 5%，说明下游出问题了，这比等到用户投诉更早。

---

## 三、重试：什么时候重试，什么时候别重试

超时之后通常接重试。但**重试不是万能的**，重试错了反而放大故障。

### 3.1 先分类错误

```python
class RetryableError(Exception): pass       # 该重试
class FatalError(Exception): pass           # 别重试，直接失败

def classify(status_code: int, exc: Exception | None) -> type:
    if exc is not None:
        # 超时、连接错误 → 可重试
        return RetryableError
    if status_code in (408, 429, 500, 502, 503, 504):
        return RetryableError
    if status_code in (400, 401, 403, 404, 422):
        return FatalError                    # 参数错、鉴权失败，重试也一样
    return RetryableError
```

**不该重试的**：400（参数错）、401/403（鉴权）、404（资源不存在）。这些重试一百次结果一样，只是浪费下游资源。

**该重试的**：429（限流）、5xx、超时、连接错误。

### 3.2 指数退避 + 抖动

```python
import asyncio, random

async def retry_with_backoff(fn, max_attempts=3, base=1.0, cap=10.0):
    for attempt in range(max_attempts):
        try:
            return await fn()
        except RetryableError:
            if attempt == max_attempts - 1:
                raise
            # 指数退避：1s, 2s, 4s... 加上下 30% 抖动，避免同步重试
            delay = min(cap, base * (2 ** attempt)) * (0.7 + random.random() * 0.6)
            await asyncio.sleep(delay)
```

**抖动（jitter）是必须的。** 没有它，一次超时会让所有并发请求在同一时刻重试，形成「惊群」，把刚恢复的服务再打垮。

### 3.3 重试次数与总预算

单个工具最多 3 次。**更重要的是 Agent 任务级的总预算**：

```python
@dataclass
class Budget:
    max_seconds: float = 120.0        # 整个任务的时间预算
    max_llm_calls: int = 20
    max_tool_calls: int = 30
```

任务级预算的意义：单个工具的 3 次重试各自合理，但 10 个工具都重试 3 次，总耗时可能到 10 分钟。**必须有任务级熔断**，否则局部合理会导致整体失控。

---

## 四、降级：拿不到结果时怎么办

重试也失败了，不能直接把任务判死。降级策略按场景选。

### 4.1 策略一：返回部分结果 + 明确说明

```python
results = {}
for source, fetcher in SOURCES.items():
    try:
        results[source] = await asyncio.wait_for(fetcher(), timeout=timeout_for(source))
    except Exception as e:
        results[source] = None
        logger.warning(f"{source} 获取失败: {e}")

# 只要有部分成功，就带着缺口继续
ok = {k: v for k, v in results.items() if v is not None}
if len(ok) >= 1:
    return {
        "status": "partial",
        "data": ok,
        "missing": [k for k, v in results.items() if v is None],
    }
raise AllSourcesFailed("所有数据源都失败了")
```

**「partial」是一个有价值的中间态**。比明确的失败好——用户至少拿到了能用的部分，而且知道缺了什么。

**关键：`missing` 必须显式返回。** 调用方（以及最终的用户）要能看出「这个结论是基于 3 个源里的 2 个得出的」。

### 4.2 策略二：走备用路径

```python
SOURCES = [
    ("primary_api", call_primary, timeout=5.0),
    ("cache_fallback", read_cache, timeout=1.0),      # 兜底：本地缓存
    ("static_config", read_config, timeout=0.5),      # 再兜底：静态配置
]

async def fetch_with_fallback(key: str):
    for name, fn, to in SOURCES:
        try:
            val = await asyncio.wait_for(fn(key), timeout=to)
            if val is not None:
                METRICS.source_used.labels(name=name).inc()
                return val, name
        except Exception:
            continue
    raise Unavailable(f"{key} 所有数据源均不可用")
```

**兜底链的顺序**：快而可能旧的（缓存）排在前，慢而准的（实时 API）排在后。反过来就成了「永远在等慢的」。

### 4.3 策略三：换成更便宜的能力

```python
# Agent 场景特有的降级：换模型、换工具
async def analyze_with_fallback(text: str):
    try:
        return await asyncio.wait_for(gpt4_analyze(text), timeout=30)
    except (Timeout, RateLimit):
        # 降级到便宜/本地模型，快但可能不够准
        return await asyncio.wait_for(local_model_analyze(text), timeout=5)
```

**模型侧的降级很有价值**：主模型限流或超时时，本地小模型虽然质量差些，但至少能给出一个答案。比干等着强。

### 4.4 策略四：明确告知不可用

```python
FALLBACK_MESSAGE = """无法完成「{task}」：{reason}。

你现在可以：
1. 稍后重试（该服务当前不稳定）
2. 我用缓存的旧数据回答（数据时间：{cache_time}）
3. 跳过这一步，继续其他部分
"""
```

**降级的最后一层是「诚实地退化」**。Agent 不能说「我查到了」然后给空数据——那是幻觉。要说「没查到，原因是 X，你可以选 Y」。

---

## 五、Agent 场景的特殊问题

工具超时降级在 Agent 里比传统后端更麻烦，因为**决策在模型侧**。

### 5.1 模型不知道工具失败了

如果工具失败后你返回一个空字符串，模型会以为「查询结果为空」，然后基于空结果继续推理——**这是幻觉的温床**。

```python
# ❌ 失败返回空，模型当成「没有数据」
except Exception:
    return ""

# ✅ 失败返回明确的错误消息
except Exception as e:
    return f"【工具失败】query_metrics 超时({timeout}s)。" \
           f"这不是「数据为空」，是「没查到」。请不要基于此做任何结论，" \
           f"如需该数据请告知用户暂时无法获取。"
```

**失败信息要写成模型能理解、且不会被误读的措辞。** 「这不是没有数据，是没查到」这句话能救很多幻觉。

### 5.2 重试导致重复副作用

Agent 的工具可能有副作用（创建工单、发通知）。重试前必须确认**是否幂等**：

```python
@tool
def create_ticket(title: str, idem_key: str) -> dict:
    """创建工单。

    Args:
        idem_key: 幂等键，同一批次内保证唯一。重试时传相同的值。
    """
    if seen(idem_key):
        return {"status": "duplicate", "note": "该工单已创建"}
    ...
```

**幂等键由 Agent 生成并复用于重试**，这是工具设计阶段就要定好的，不能等到出问题再补。

### 5.3 超时导致的上下文污染

工具超时后，上下文里留下的是一条错误消息。如果模型后续反复引用这条错误（「因为工具失败了，所以……」），整个推理就跑偏了。

**对策：错误消息要短、要明确、要不含误导性内容。** 别把堆栈跟踪整个塞进去。

---

## 六、一套可落地的方案

```python
# 每个工具声明自己的韧性参数
TOOL_CONFIG = {
    "query_order":     {"timeout": 5.0,  "retry": 2, "fallback": "cache"},
    "query_metrics":   {"timeout": 15.0, "retry": 1, "fallback": "partial"},
    "call_llm":        {"timeout": 60.0, "retry": 2, "fallback": "local_model"},
    "send_notify":     {"timeout": 3.0,  "retry": 3, "fallback": "queue"},
}

async def resilient_call(tool_name: str, fn, *args, **kwargs):
    cfg = TOOL_CONFIG[tool_name]
    errors = []
    for attempt in range(cfg["retry"] + 1):
        try:
            result = await asyncio.wait_for(fn(*args, **kwargs), timeout=cfg["timeout"])
            validate_schema(result)              # 校验完整性，不只是状态码
            return result
        except (asyncio.TimeoutError, httpx.TimeoutException) as e:
            errors.append(f"超时({cfg['timeout']}s)")
            METRICS.tool_timeout.labels(tool=tool_name).inc()
        except RetryableError as e:
            errors.append(str(e))
        except FatalError as e:
            return {"__error__": f"{tool_name} 失败（不可重试）: {e}"}
        if attempt < cfg["retry"]:
            await asyncio.sleep(min(8, 1 * 2 ** attempt) * (0.7 + random.random() * 0.6))

    # 重试耗尽 → 降级
    return fallback_for(cfg["fallback"], tool_name, errors)
```

配套的监控（缺了这些你都是瞎的）：

- 每个工具的 **P95/P99 耗时** 和 **超时率**
- 每个工具的**降级触发次数**（降级率突然上升 = 上游在劣化）
- 任务级**预算消耗分布**（有没有任务经常跑满预算）

---

## 七、常见误区

**误区一：所有工具用同一个超时。** 内网查询和 LLM 调用不可能一个值。按类型分档。

**误区二：只设只有一个 timeout。** connect/read/pool 分开，否则连接池满了也发现不了。

**误区三：失败返回空字符串。** 模型会当成「查询结果为空」，进而产生幻觉。**失败必须返回明确的错误消息。**

**误区四：所有错误都重试。** 400/401/404 重试一万次也一样，还浪费下游。

**误区五：没有抖动。** 同步重试造成惊群，把刚恢复的服务再打垮。

**误区六：只看单个工具的重试次数，不设任务级预算。** 每个工具局部合理，整体能跑十分钟。

**误区七：重试非幂等的副作用操作。** 必须先有幂等键设计。

**误区八：超时不当信号。** 超时率是最灵敏的上游劣化指标，必须进监控告警，不能只打日志。

---

## 小结

- 工具慢比工具错更危险：**错误可处理，慢会挂住整个 Agent 循环，打满连接池，连累不相关的用户**。
- 超时**分三层设**：connect（3~5s）、read（按 P99.9×1.5~2）、pool（3~5s）。按工具类型分档，别一刀切。
- **必须校验响应完整性**——HTTP 200 也可能返回半截 JSON，这是最隐蔽的坑。
- 重试前先**分类错误**：429/5xx/超时可重试，400/401/404 别重试；退避要**指数 + 抖动**（防惊群）；单个工具 ≤3 次。
- **任务级预算是必须的**：单工具局部合理，累加起来能跑十分钟。
- 降级四策略：**部分结果（显式列出 missing）、备用路径（缓存 → 实时）、降级模型、诚实告知不可用**。
- Agent 场景特有：**失败必须返回明确的错误消息**（「不是没数据，是没查到」，防幻觉）；**副作用工具必须有幂等键**才能重试。
- 可观测性：每个工具的 P99、超时率、降级率。**超时率是最灵敏的上游劣化信号。**

超时和降级做在工具层，看起来是细节，但它决定了你的 Agent 是「演示时很好，线上偶尔抽风」，还是「什么时候都能给个说法」。
