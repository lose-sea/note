# with_retry 重试细节：重试几次、退避多久、哪些错该重试

> `with_retry` 两行代码就能加上重试。
> 但"重试三次、间隔一秒"这种默认配置，
> 在面对限流（429）和服务过载（503）时，**往往是把小故障放大成大故障**。

## 一、最简用法和它的隐患

```python
from langchain_core.runnables import RunnableLambda
import requests

chain = RunnableLambda(fetch_data).with_retry()
```

默认参数大致是：

```python
with_retry(
    retry_if_exception_type=(Exception,),    # ⚠️ 所有异常都重试
    wait_exponential_jitter=True,
    stop_after_attempt=3,
    exponential_jitter_params=None,
)
```

隐患在第一个参数：**`Exception` 覆盖一切**。包括：

- `ValueError`（参数错了，重试一万次还是错）
- `AuthenticationError`（密钥错了）
- `KeyboardInterrupt`（用户想中断，你还在重试）

**重试不可重试的错误，等于把一次失败变成三次失败 + 三倍计费。**

## 二、第一步：明确哪些错该重试

```python
from openai import RateLimitError, APITimeoutError, APIConnectionError, BadRequestError
import httpx

RETRYABLE = (
    RateLimitError,         # 429 限流
    APITimeoutError,        # 超时
    APIConnectionError,     # 网络抖动
    httpx.ReadTimeout,
    httpx.ConnectError,
)

FATAL = (
    BadRequestError,        # 400 参数错
    ValueError,
    KeyError,
)

chain = RunnableLambda(call_llm).with_retry(
    retry_if_exception_type=RETRYABLE,
)
```

**判断标准：这个错误是否可能"过一会儿就好了"？**

| 错误类型 | 该重试吗 | 理由 |
|---|---|---|
| 429 限流 | ✅ | 等一会儿配额就恢复 |
| 超时 | ✅ | 网络抖动的概率性事件 |
| 503 服务不可用 | ✅ | 对端临时过载 |
| 400 参数错 | ❌ | 参数不会自己变对 |
| 401 认证失败 | ❌ | 密钥不会自己变对 |
| 内容审核拒绝 | ❌ | 内容不会自己变合规 |
| JSON 解析失败 | ⚠️ 看情况 | 模型有随机性，值得重试 |

最后一条值得展开——**模型输出不稳定导致的解析失败，是特例**。它属于"重试有可能成功"的类别，但重试策略要不同（见后文）。

## 三、退避策略：指数退避 + 抖动

固定间隔重试是最糟的选择。当 1000 个客户端同时被限流、同时等 1 秒重试，会在同一时刻再次撞上去——**惊群效应**。

正确做法是**指数退避 + 随机抖动**：

```python
chain.with_retry(
    retry_if_exception_type=RETRYABLE,
    wait_exponential_jitter=True,        # 指数退避 + 抖动
    stop_after_attempt=4,
    exponential_jitter_params={
        "initial": 1.0,      # 首次等待 1 秒
        "max": 60.0,         # 最多等 60 秒
        "exp_base": 2,       # 每次翻倍
        "jitter": 1.0,       # 抖动幅度（秒）
    },
)
```

实际等待序列大致是：

```
第 1 次重试：~1 秒 + 随机 0~1 秒
第 2 次重试：~2 秒 + 随机 0~1 秒
第 3 次重试：~4 秒 + 随机 0~1 秒
```

**抖动是必须的**，不是可选项。

如果是做微服务，还可以参考 `Retry-After` 请求头——很多 API 在 429 时会明确告诉你要等多久：

```python
def smart_wait(attempt: int, exc: Exception) -> float:
    # 服务端给了建议等待时间，就听它的
    if isinstance(exc, RateLimitError) and hasattr(exc, "response"):
        ra = exc.response.headers.get("Retry-After")
        if ra:
            return float(ra) + random.random()    # 加抖动
    return min(2 ** attempt, 60) + random.random()
```

## 四、按错误类型区分策略

不同错误该有不同的重试次数和间隔：

```python
def route_retry(attempt: int, exc) -> bool:
    """决定是否继续重试"""
    if attempt >= 4:
        return False
    if isinstance(exc, RateLimitError):
        return True                  # 限流多试几次
    if isinstance(exc, APITimeoutError):
        return attempt < 2           # 超时最多试两次（可能本身就是慢请求）
    return True
```

超时重试次数要少——**一个 60 秒的超时重试 4 次，总共要等 4 分钟**，用户早就走了。

## 五、重试 + 超时的组合

单次调用的超时和整体重试时长是两回事：

```python
chain = (
    RunnableLambda(call_llm)
    .with_retry(stop_after_attempt=3, retry_if_exception_type=RETRYABLE)
    .with_config(run_name="llm_call")
)
```

**整体超时**用 `asyncio.wait_for`（异步）或 `concurrent.futures`（同步）包一层：

```python
import asyncio

async def call_with_deadline(chain, inputs, deadline: float = 30.0):
    try:
        return await asyncio.wait_for(chain.ainvoke(inputs), timeout=deadline)
    except asyncio.TimeoutError:
        raise TimeoutError(f"整体超时 {deadline} 秒")
```

这样即使重试本身要花很久，也能在 30 秒时果断放弃。

## 六、幂等性：重试的前提

**有副作用的操作重试前，必须先确认幂等。**

```python
# ❌ 危险：重试可能重复扣款
def charge(state):
    return pay_gateway.charge(state["order_id"], state["amount"])

# ✅ 幂等：先查再扣
def charge(state):
    if db.exists("charges", state["order_id"]):
        return db.get("charges", state["order_id"])
    result = pay_gateway.charge(state["order_id"], state["amount"])
    db.insert("charges", state["order_id"], result)
    return result
```

支付网关通常支持**幂等键**：

```python
pay_gateway.charge(order_id, amount, idempotency_key=order_id)
```

传同一个 key 多次，只会真正扣一次。**用现成的幂等键，比自己写检查更可靠。**

## 七、别在错误的分层加重试

一个常见反模式：**每层都加重试**。

```
HTTP 客户端：重试 3 次
LangChain chain：重试 3 次
业务服务：重试 3 次
总计：27 次请求 ❌
```

**重试只在最接近故障的那一层做。**

在 LangChain 里，意味着把重试加在 `RunnableLambda` 里而不是整个 chain 上：

```python
# ✅ 只重试真正会失败的那一步
chain = RunnableLambda(fetch_from_vector_db).with_retry(...) | prompt | llm
```

## 八、重试的可见性：必须打日志

重试是"看不见的失败"。不打日志，你会以为一切正常。

```python
from langchain_core.callbacks import BaseCallbackHandler
import logging

log = logging.getLogger("retry")

class RetryLogger(BaseCallbackHandler):
    def on_retry(self, retry_state, **kwargs):
        log.warning(
            "重试 %d/%d，异常=%s，已等待=%.2fs",
            retry_state.attempt_number,
            retry_state.retry_object.stop.max_attempt_number,
            type(retry_state.outcome.exception()).__name__,
            retry_state.seconds_since_start,
        )

chain = RunnableLambda(call_llm).with_retry(
    retry_if_exception_type=RETRYABLE,
    stop_after_attempt=4,
).with_config(callbacks=[RetryLogger()])
```

**监控指标里，"重试率"比"失败率"更早预警问题**。失败率还很低的时候，重试率可能已经飙到 30% 了。

## 九、模型输出解析失败的重试

这是 LLM 特有的场景，策略和网络错误不同：

```python
def parse_with_retry(text: str, schema, max_tries: int = 3):
    """解析失败就重问，且把错误告诉模型"""
    last_error = None
    for i in range(max_tries):
        raw = llm.invoke(prompt_for(text, last_error))
        try:
            return schema.model_validate_json(raw.content)
        except ValidationError as e:
            last_error = str(e)
            log.info("第 %d 次解析失败：%s", i + 1, last_error)
    raise ValueError(f"重试 {max_tries} 次仍无法解析")
```

注意两点：

1. **把上一次的错误喂回去**——模型能根据错误自我修正，成功率大幅提升；
2. **温度调低**——重试时把 `temperature` 降到 0，减少随机性。

```python
llm_retry = llm.bind(temperature=0)
```

## 十、小结

```python
chain.with_retry(
    retry_if_exception_type=RETRYABLE,      # ① 只重试该重试的
    wait_exponential_jitter=True,           # ② 指数退避 + 抖动
    stop_after_attempt=4,                   # ③ 有次数上限
    exponential_jitter_params={...},        # ④ 参数可调
)
```

四条规则：

1. **精确限定异常类型**，别用 `Exception`；
2. **指数退避 + 抖动**，避免惊群；
3. **只在最底层加重试**，别层层叠加；
4. **副作用操作必须幂等**，否则重试是灾难。

`with_retry` 是脚手架，**真正的功夫在"判断什么错该重试"上**。
