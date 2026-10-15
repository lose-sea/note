# LangGraph 部署上线：从本地跑通到生产可用，中间差什么

> 本地 `python main.py` 跑得挺好。
> 部署到服务器上，问题一个接一个：
> 状态丢了、并发冲突、用户 A 看到 B 的对话。

## 一、本地能跑 ≠ 生产可用

一张对照表看清差距：

| 维度 | 本地开发 | 生产环境 |
|---|---|---|
| 状态 | 内存 | 需要持久化 |
| 并发 | 单人 | 多用户同时 |
| 会话 | 一个进程一个 | 需要隔离 |
| 失败 | 重启就行 | 任务不能丢 |
| 观测 | 打 print | 需要 trace |
| 资源 | 随便用 | 需要限流 |
| 密钥 | .env 明文 | 密钥管理服务 |

**这七条每一件都要单独处理。**

## 二、第一件：状态持久化

内存 checkpointer 在生产等于"重启即失忆"。换 Postgres：

```python
from langgraph.checkpoint.postgres import PostgresSaver
from psycopg_pool import ConnectionPool

DB_URI = "postgresql://user:pwd@host:5432/langgraph?sslmode=require"

pool = ConnectionPool(conninfo=DB_URI, max_size=20, kwargs={"autocommit": True})
checkpointer = PostgresSaver(pool)

# 首次部署执行一次建表
checkpointer.setup()

graph = builder.compile(checkpointer=checkpointer)
```

**三个工程细节**：

1. **用连接池**，别每次请求新建连接；
2. **`setup()` 只在部署时执行一次**，每次启动都调会重复建表；
3. **建索引**——检查点表会很大：

```sql
CREATE INDEX IF NOT EXISTS idx_checkpoints_thread
  ON checkpoints (thread_id, checkpoint_id DESC);
```

## 三、第二件：会话隔离

**`thread_id` 必须由服务端生成并绑定用户**：

```python
from fastapi import FastAPI, Depends, HTTPException

app = FastAPI()

def get_current_user(token: str = Header(...)) -> User:
    user = verify_jwt(token)
    if not user:
        raise HTTPException(401)
    return user

@app.post("/chat")
async def chat(req: ChatRequest, user: User = Depends(get_current_user)):
    thread_id = req.thread_id or f"{user.id}:{uuid.uuid4()}"

    # ✅ 校验这个会话属于当前用户
    if not thread_id.startswith(f"{user.id}:"):
        raise HTTPException(403, "无权访问该会话")

    config = {"configurable": {"thread_id": thread_id}}
    result = await graph.ainvoke({"messages": [("user", req.message)]},
                                 config=config)
    return {"thread_id": thread_id, "reply": result["messages"][-1].content}
```

**最常见的严重漏洞**：直接信任请求里的 `thread_id`。攻击者改一下就能读到别人的对话。

更严格的方案是把 `user_id` 存进 `checkpoint_ns` 或元数据，查询时强制过滤。

## 四、第三件：并发与限流

同一个 `thread_id` 被并发调用会出问题——**两个请求同时读写同一份状态**。

```python
import asyncio
from collections import defaultdict

class ThreadLock:
    """保证同一个会话串行处理"""
    def __init__(self):
        self._locks: dict[str, asyncio.Lock] = defaultdict(asyncio.Lock)

    def get(self, thread_id: str) -> asyncio.Lock:
        return self._locks[thread_id]

thread_lock = ThreadLock()

@app.post("/chat")
async def chat(req: ChatRequest, user: User = Depends(get_current_user)):
    tid = req.thread_id or new_thread(user)
    async with thread_lock.get(tid):
        result = await graph.ainvoke(..., config={"configurable": {"thread_id": tid}})
    return result
```

**注意：进程内的锁只对单实例有效。** 多实例部署要用分布式锁：

```python
import redis.asyncio as redis

r = redis.from_url(REDIS_URL)

@asynccontextmanager
async def distributed_lock(key: str, timeout: int = 120):
    lock = r.lock(f"lock:{key}", timeout=timeout)
    acquired = await lock.acquire(blocking=True, blocking_timeout=30)
    if not acquired:
        raise HTTPException(429, "该会话正在处理中，请稍后")
    try:
        yield
    finally:
        await lock.release()
```

同时整体要做**用户级限流**：

```python
from slowapi import Limiter
limiter = Limiter(key_func=lambda: current_user_id())

@app.post("/chat")
@limiter.limit("20/minute")
async def chat(...):
    ...
```

## 五、第四件：长任务的异步化

一个 Agent 任务跑 2 分钟，HTTP 请求等 2 分钟不现实。**改成"提交任务 → 轮询/推送结果"**：

```python
from celery import Celery

celery_app = Celery("tasks", broker=REDIS_URL, backend=REDIS_URL)

@celery_app.task(bind=True, max_retries=2)
def run_graph_task(self, thread_id: str, input_data: dict):
    try:
        result = graph.invoke(input_data, config={"configurable": {"thread_id": thread_id}})
        return {"status": "done", "result": result}
    except Exception as e:
        raise self.retry(exc=e, countdown=10)

@app.post("/tasks")
async def submit(req: TaskRequest, user: User = Depends(get_current_user)):
    tid = new_thread(user)
    task = run_graph_task.delay(tid, {"messages": [("user", req.message)]})
    return {"thread_id": tid, "task_id": task.id}

@app.get("/tasks/{task_id}")
async def poll(task_id: str):
    task = celery_app.AsyncResult(task_id)
    return {"state": task.state, "result": task.result if task.ready() else None}
```

**Agent 任务天生适合异步化**——它们耗时长、可能重试、需要断点续跑，这些都是消息队列的强项。

## 六、第五件：流式输出

长任务需要流式反馈（参考"astream_events"那篇）。FastAPI + SSE：

```python
from fastapi.responses import StreamingResponse

@app.get("/chat/stream")
async def stream(q: str, sid: str, user: User = Depends(get_current_user)):
    async def gen():
        config = {"configurable": {"thread_id": sid}}
        async for event in graph.astream_events({"messages": [("user", q)]},
                                                config=config, version="v2"):
            if event["event"] == "on_chat_model_stream":
                chunk = event["data"]["chunk"].content
                if chunk:
                    yield f"data: {json.dumps({'t': chunk}, ensure_ascii=False)}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream")
```

**部署注意点**：

- **Nginx 要关缓冲**：`proxy_buffering off;`
- **超时调大**：`proxy_read_timeout 300s;`
- **gunicorn 用 `--worker-class uvicorn.workers.UvicornWorker --timeout 300`**。

## 七、第六件：可观测性

最少要有三样：

```python
import os

# 1. Trace（LangSmith）
os.environ["LANGCHAIN_TRACING_V2"] = "true"
os.environ["LANGCHAIN_PROJECT"] = f"my-agent-{os.environ['ENV']}"
os.environ["LANGCHAIN_API_KEY"] = SECRETS["langsmith_key"]

# 2. 指标（Prometheus）
from prometheus_client import Counter, Histogram, make_asgi_app

GRAPH_CALLS = Counter("graph_calls_total", "图调用次数", ["status", "user_tier"])
GRAPH_LATENCY = Histogram("graph_latency_seconds", "图调用延迟",
                          buckets=[0.5, 1, 2, 5, 10, 30, 60, 120])

app.mount("/metrics", make_asgi_app())
```

```python
@GRAPH_LATENCY.time()
def invoke():
    try:
        r = graph.invoke(...)
        GRAPH_CALLS.labels(status="ok", user_tier=user.tier).inc()
        return r
    except Exception:
        GRAPH_CALLS.labels(status="error", user_tier=user.tier).inc()
        raise
```

**关键指标清单**：

| 指标 | 用途 |
|---|---|
| 调用成功率 | 基本健康度 |
| P95/P99 延迟 | 用户体验 |
| **token 消耗** | 成本监控 |
| 工具调用失败率 | 外部依赖健康 |
| 重试率 | 早于失败率暴露问题 |
| 队列积压 | 容量预警 |

**日志要有 trace_id**，才能把一次请求的所有日志串起来：

```python
import structlog
log = structlog.get_logger()

log.info("graph_started", thread_id=tid, user_id=user.id, trace_id=trace_id)
```

## 八、第七件：配置与密钥

```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    openai_api_key: str
    database_url: str
    redis_url: str
    langsmith_api_key: str | None = None
    max_concurrency: int = 20

    model_config = {"env_file": ".env", "env_prefix": "APP_"}

settings = Settings()          # 启动时校验，缺配置直接崩
```

**绝不要把密钥写进代码或用默认值。** 生产用环境变量或密钥管理服务（AWS Secrets Manager / Vault / K8s Secret）。

**启动时校验配置**——`Settings()` 缺字段会抛异常，比运行到一半才发现好得多。

## 九、部署方式选择

| 方式 | 适合 | 说明 |
|---|---|---|
| 单机 Docker | 小规模、内部工具 | 最简单 |
| K8s 多副本 | 有并发要求 | 注意分布式锁 |
| LangGraph Platform | 想省运维 | 官方托管 |
| Serverless | 低频、突发 | 冷启动是问题 |

**K8s 部署的关键点**：

```yaml
resources:
  requests: {cpu: "500m", memory: "1Gi"}
  limits: {cpu: "2", memory: "4Gi"}

# 优雅退出：别让正在跑的任务被强杀
lifecycle:
  preStop:
    exec:
      command: ["sleep", "15"]

readinessProbe:
  httpGet: {path: /health, port: 8000}
  initialDelaySeconds: 10
```

**`preStop` 的 sleep 是必须的**——给正在处理中的请求留时间完成，否则长任务会被 SIGKILL。

## 十、上线检查清单

```
□ 检查点用 Postgres，不用内存
□ thread_id 服务端生成，校验归属
□ 同会话并发加锁（多实例用分布式锁）
□ 长任务异步化（Celery / 队列）
□ 有健康检查端点 /health
□ 密钥从环境变量读，不硬编码
□ 配置启动时校验
□ Trace + 指标 + 结构化日志
□ 限流（用户级 + 全局）
□ 优雅退出（preStop sleep）
□ 检查点定期清理
□ 幂等（有副作用的节点）
```

**这份清单里的每一条，都是别人线上事故换来的。**

## 十一、小结

```python
# 生产可用的最小配置
checkpointer = PostgresSaver(ConnectionPool(DB_URI))
graph = builder.compile(checkpointer=checkpointer)

@app.post("/chat")
async def chat(req, user = Depends(auth)):
    tid = verify_thread(req.thread_id, user)          # 会话隔离
    async with distributed_lock(tid):                  # 并发控制
        async with limiter(user):                      # 限流
            return await graph.ainvoke(..., config={"configurable": {"thread_id": tid}})
```

**本地跑通只是 10% 的工作量。** 剩下 90% 在持久化、隔离、并发、可观测、容错——这些"不产生新功能"的工作，才决定它能不能真的给人用。
