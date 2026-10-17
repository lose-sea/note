# 限流与背压：并发请求怎么兜住

Agent 服务上线第一天，内部测试几十个人同时用，一切正常。推广到全公司，同时在线两百人——服务开始超时、返回乱七八糟的错误、最后整个实例挂掉重启。

这不是模型不够快，是**你的系统没有能力边界**。入口不设限，流量全进内部，连接池、线程、内存全被打满，最后雪崩。

限流和背压就是给系统装上「闸门」和「缓冲」。这篇讲清楚两者的区别、怎么实现、以及 Agent 场景的特殊之处。

---

## 一、限流与背压不是一回事

很多人把这两个词混用，它们解决不同问题。

### 1.1 限流（Rate Limiting）

**拒绝超额的请求。** 保护自己不被冲垮。

```
请求进来 → 检查配额 → 超额？→ 拒绝（429/排队）
                    ↓
                 放行
```

### 1.2 背压（Backpressure）

**让上游放慢发送。** 当下游处理不过来时，把压力传导回去。

```
下游满了 → 暂停读上游 → 上游积压 → 上游自然降速
```

**类比**：限流是餐厅门口「今日已满，请回」，背压是后厨喊「出菜慢，前厅少接单」。

### 1.3 Agent 场景为什么要两个都上

Agent 的特点是**单个请求耗时长、资源占用重**（一次任务几十次 LLM 调用）：

- 只限流不背压：进来的请求全挂在内部等待，连接池慢慢耗尽，最后超时一片
- 只背压不限流：上游永远按自己的节奏发，背压只让你内部队列越积越长，最终 OOM

**两者必须配合：入口限流控制总量，内部背压平滑处理。**

---

## 二、限流：几种算法与选型

### 2.1 固定窗口（最简单，有临界问题）

```python
class FixedWindow:
    def __init__(self, limit: int, window: int):
        self.limit = limit
        self.window = window
        self.count = 0
        self.window_start = time.time()

    def allow(self) -> bool:
        now = time.time()
        if now - self.window_start >= self.window:
            self.count, self.window_start = 0, now
        if self.count < self.limit:
            self.count += 1
            return True
        return False
```

**问题**：窗口交界处可能放过两倍流量。比如限 100/秒，第 0.9 秒放了 100 个，第 1.1 秒计数器重置又放 100 个——**0.2 秒内放了 200 个。**

**适用**：内部工具、对精度要求不高的场景。

### 2.2 滑动窗口（修正临界问题）

```python
class SlidingWindow:
    def __init__(self, limit: int, window: int):
        self.limit = limit
        self.window = window
        self.hits = deque()               # 存时间戳

    def allow(self) -> bool:
        now = time.time()
        # 移除窗口外的记录
        while self.hits and self.hits[0] <= now - self.window:
            self.hits.popleft()
        if len(self.hits) < self.limit:
            self.hits.append(now)
            return True
        return False
```

用时间戳队列实现，检查时只统计窗口内真实的请求数。**没有临界突刺。**

### 2.3 令牌桶（最实用，允许突发）

```python
class TokenBucket:
    def __init__(self, rate: float, capacity: int):
        self.rate = rate              # 每秒生成多少令牌
        self.capacity = capacity      # 桶容量（允许的瞬时突发）
        self.tokens = capacity
        self.last = time.monotonic()

    def allow(self, cost: int = 1) -> bool:
        now = time.monotonic()
        # 按时间补充令牌
        self.tokens = min(self.capacity,
                          self.tokens + (now - self.last) * self.rate)
        self.last = now
        if self.tokens >= cost:
            self.tokens -= cost
            return True
        return False
```

**优点**：平时攒下来的令牌可以应对突发（容量 10 的话，瞬间可以放 10 个），但长期不会超过 rate。**适合真实流量有峰谷的场景。**

**Agent 服务的默认选择。**

### 2.4 分布式限流

单机限流在多实例部署下不够（每个实例各限各的，总量还是超）。用 Redis：

```python
import redis

r = redis.Redis()

def redis_token_bucket(key: str, rate: float, capacity: int) -> bool:
    """基于 Redis + Lua 的分布式令牌桶。"""
    lua = """
    local key = KEYS[1]
    local rate = tonumber(ARGV[1])
    local capacity = tonumber(ARGV[2])
    local now = tonumber(ARGV[3])
    local data = redis.call('HMGET', key, 'tokens', 'ts')
    local tokens = tonumber(data[1]) or capacity
    local ts = tonumber(data[2]) or now
    tokens = math.min(capacity, tokens + (now - ts) * rate)
    local allowed = tokens >= 1
    if allowed then tokens = tokens - 1 end
    redis.call('HMSET', key, 'tokens', tokens, 'ts', now)
    redis.call('EXPIRE', key, 60)
    return allowed and 1 or 0
    """
    return bool(r.eval(lua, 1, key, rate, capacity, time.time()))
```

**按什么维度限流**（重要，不同维度效果不同）：

| 维度 | 用途 | 说明 |
|------|------|------|
| 全局 | 保护服务不崩 | 总和不超过实例承载能力 |
| 按用户 | 防单用户刷 | 每用户每分钟 N 次 |
| 按租户 | 防单租户挤占 | 内部 SaaS 常用 |
| 按任务类型 | 保护关键路径 | 贵的任务限严些 |

---

## 三、背压：让系统优雅地慢下来

### 3.1 背压的第一个层面：有界队列

```python
# ❌ 无界队列：流量进来全收，队列无限增长，最后 OOM
queue = asyncio.Queue()

# ✅ 有界队列：满了就拒绝或等待
queue = asyncio.Queue(maxsize=100)

async def handle_request(req):
    try:
        await asyncio.wait_for(queue.put(req), timeout=1.0)
    except asyncio.TimeoutError:
        raise HTTPException(503, "服务繁忙，请稍后重试")
```

**有界队列是背压的物理基础。** 无界队列的问题不是慢，是**最终会以最惨烈的方式崩**（OOM，全丢）。

### 3.2 第二个层面：并发控制

```python
# Agent 任务重（单任务几十次 LLM 调用），并发必须卡死
sem = asyncio.Semaphore(MAX_CONCURRENT_TASKS)      # 比如 8

async def run_task(task):
    async with sem:
        return await agent.execute(task)
```

**并发数的确定**：实测。从 8 开始，逐步加到 CPU/连接池/LLM 限流成为瓶颈为止。

**Agent 场景的并发通常比传统 Web 服务低很多。** 传统 Web 单个请求几毫秒，能扛几千并发；Agent 单任务几秒到几十秒，几百并发就可能是极限。

### 3.3 第三个层面：流式节流

Agent 的输出是流式的（SSE/WebSocket），客户端消费速度可能跟不上生产速度：

```python
async def stream_with_backpressure(generator, reader):
    """下游读得慢，就暂停生产。"""
    async for chunk in generator:
        # 缓冲区满时暂停，直到 reader 消费
        while reader.paused:
            await reader.on_resume.wait()
        await reader.write(chunk)
```

**没有节流的流式输出，内存会被缓冲区撑爆**（尤其是长任务，几十 KB/s 的输出量）。

---

## 四、拒绝的艺术

被限流时，返回什么直接影响用户体验。

### 4.1 三种拒法

**直接拒绝（最简单）**

```python
raise HTTPException(429, detail="请求过于频繁，请稍后重试",
                    headers={"Retry-After": "30"})
```

**排队等待（体验好，但需有界）**

```python
# 给个预估，别让用户无限等
position = queue.qsize()
if position > 20:
    raise HTTPException(503, "排队人数过多，请稍后重试")
return {"status": "queued", "position": position}
```

**降级响应（Agent 特有）**

```python
# 不拒绝，但给个轻量答案
if over_limit:
    return quick_answer(question)      # 用小模型/缓存快速回一句
```

### 4.2 Agent 场景的特殊处理：任务化

Agent 任务长（几分钟），同步等不合理。**改成任务化**：

```python
@router.post("/task")
async def create_task(req):
    if over_limit():
        raise HTTPException(429, "当前任务队列已满，请稍后提交")
    task_id = await queue.enqueue(req)
    return {"task_id": task_id, "status": "queued"}

@router.get("/task/{task_id}")
async def get_task(task_id: str):
    return task_store.get(task_id)     # 客户端轮询或用 SSE 订阅
```

**长任务必须异步化**，否则 HTTP 连接会全部挂住——连接池满了，连轻量请求都进不来。

---

## 五、Agent 场景的限流特殊点

### 5.1 限 LLM API，不只是限自己

即使你的服务扛得住，**上游 LLM API 的限流也会打垮你**：

```python
# 服务端限流 + 客户端侧限流同时做
# 客户端侧：对所有发往 LLM 的调用做全局令牌桶
llm_bucket = TokenBucket(rate=50, capacity=100)      # 50 req/s

async def call_llm_with_limit(prompt):
    await llm_bucket.acquire()                       # 拿不到令牌就等
    return await llm.chat(prompt)
```

**这是「背压」的另一种形式**：上游慢，你就该慢。不等它报 429，自己先控速。

### 5.2 按 token 限流比按次数更准

```python
def estimate_tokens(prompt: str) -> int:
    return len(prompt) // 4            # 粗略估算

class TokenAwareLimiter:
    def __init__(self, tokens_per_minute: int):
        self.tpm = tokens_per_minute
        self.used = 0
        self.window_start = time.time()

    def allow(self, prompt: str) -> bool:
        now = time.time()
        if now - self.window_start > 60:
            self.used, self.window_start = 0, now
        need = estimate_tokens(prompt)
        if self.used + need > self.tpm:
            return False
        self.used += need
        return True
```

**按次数限流的漏洞**：用户短请求能过，长请求（几千 token）把 TPM 配额吃光。**按 token 限才贴合上游的真实约束。**

### 5.3 超长任务单独一档

```python
LIMITS = {
    "quick":   TokenBucket(rate=20, capacity=40),     # < 30s 任务
    "long":    TokenBucket(rate=2,  capacity=5),      # > 30s 任务，限死
    "batch":   asyncio.Semaphore(2),                 # 批量任务，串行化
}
```

**长任务和短任务分开限。** 一个 5 分钟的调研任务和一个 3 秒的问答抢同一份配额，两个都别想好用。

---

## 六、监控：限流的可观测性

```python
# 必须暴露的指标
requests_total                # 总请求
requests_rejected{tier="rate_limit"}     # 因限流拒绝
queue_depth                   # 当前队列长度
queue_wait_seconds            # 排队等待时长（直方图）
active_tasks                  # 活跃任务数
upstream_rate_limited         # LLM API 429 次数
```

**告警条件**：

- `requests_rejected / requests_total > 5%` 持续 5 分钟 → 容量不足或异常流量
- `queue_wait_seconds P95 > 10s` → 背压过头，用户在等太久
- `queue_depth` 持续接近上限 → 该扩容或该降级

**queue_wait_seconds 是最该盯的**——它直接反映用户的实际等待。限流做对了应该表现为「快速拒绝」，而不是「长时间挂着」。

---

## 七、常见误区

**误区一：不限流，以为「扛得住」。** 内部工具不限流还凑合，对外服务不限流等于裸奔。

**误区二：用了无界队列。** 队列无限长 = 延迟 OOM 崩溃。**必须 maxsize。**

**误区三：只看并发数不看任务时长。** Agent 任务比 Web 请求重几十倍，并发上限低得多。别拿 Web 服务的经验套。

**误区四：限流只按次数不按 token。** 长请求能把配额吃光，短请求全被误伤。

**误区五：客户端不限 LLM 调用。** 自己扛得住，照样被上游 429 打死。客户端令牌桶必须加。

**误区六：长任务同步返回。** 几分钟的 HTTP 连接挂满连接池，轻量请求全进不来。**长任务必须异步化。**

**误区七：限流阈值拍死不变。** 该可配置，线上发现某类任务过载能即时收紧。

---

## 小结

- **限流是拒绝超额请求（护自己），背压是传导压力给上游（让系统慢下来）**。Agent 两个都要：入口限流总量，内部背压平滑。
- 限流算法选**令牌桶**（允许合理突发，贴合真实流量）；多实例部署必须**分布式限流（Redis Lua）**。
- 限流维度至少两层：**全局（护服务）+ 按用户/租户（防单点挤占）**。贵任务限严些。
- 背压三件套：**有界队列（必须 maxsize，无界 = 延迟 OOM）、并发 Semaphore（Agent 并发上限远低于 Web 服务）、流式节流**。
- Agent 特有：**客户端也要对 LLM API 限流（令牌桶），最好按 token 而不是次数限**；长任务必须异步化（任务队列 + 轮询/SSE），否则连接池挂满什么都没法做。
- 拒绝要有策略：快速拒绝 > 长时间挂着。`Retry-After` 头必须给。
- 监控盯 `queue_wait_seconds`（用户实际等待）和拒绝率，**快速拒绝是正确的限流形态**。

并发控制没做好，系统不会「平稳地慢」，而是「突然地崩」。而 Agent 这种重请求场景，崩得比传统服务更快——因为它每个请求都咬着一大把资源不肯放。
