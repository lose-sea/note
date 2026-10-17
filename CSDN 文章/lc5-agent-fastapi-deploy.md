# FastAPI 封装：把 Agent 包成 HTTP 服务

Agent 在 Jupyter 里跑通了，接下来怎么办？画个 Gradio 页面是最快的，但生产要的是**能被别的系统调用的 HTTP 服务**：有鉴权、有限流、有任务队列、能异步、能监控。

FastAPI 是这个场景的主流选择——异步支持好（Agent 是全 IO 等待）、类型清晰、生态成熟。这篇讲一套可以直接用的结构，包括最关键的「长任务怎么处理」。

---

## 一、先想清楚：一个请求对应什么

Agent 请求和传统 API 有个根本差异：**它可能跑 5 秒，也可能跑 5 分钟。**

这决定了接口形态：

| 形态 | 适用 | 问题 |
|------|------|------|
| 同步返回 | < 10 秒的任务 | 长任务挂住连接、连接池耗尽 |
| 异步任务 + 轮询 | 长任务 | 要多一个状态接口 |
| 异步任务 + SSE | 长任务 + 要过程 | 前端复杂度 |

**我的建议：默认异步任务化，短任务也走同一套。** 统一形态比「短任务同步长任务异步」少一半代码，而且长任务的坑（超时、重连、取消）提前踩完。

---

## 二、基本结构

### 2.1 目录

```
service/
├── main.py            # FastAPI 入口
├── agent_app.py       # Agent 构建
├── schemas.py         # 请求/响应模型
├── task_manager.py    # 任务队列与状态
├── events.py          # SSE 事件总线
└── config.py          # 配置
```

### 2.2 数据模型

```python
from pydantic import BaseModel, Field
from typing import Literal

class ChatRequest(BaseModel):
    question: str = Field(..., min_length=1, max_length=4000)
    session_id: str | None = None        # 多轮对话用，不传则新建
    stream: bool = False

    model_config = {"json_schema_extra": {
        "examples": [{"question": "帮我查一下订单状态"}]
    }}


class TaskStatus(BaseModel):
    task_id: str
    status: Literal["queued", "running", "completed", "failed", "cancelled"]
    progress: str | None = None          # 当前步骤描述
    answer: str | None = None
    sources: list[str] = []
    error: str | None = None
    tokens_used: int | None = None
    created_at: str
    finished_at: str | None = None
```

**`session_id` 决定上下文隔离**（我专门写过一篇）。不传就建新的——这个逻辑必须在服务端，不能让客户端传错。

---

## 三、核心：任务化管理长任务

### 3.1 任务管理器

```python
import asyncio, uuid
from datetime import datetime

class TaskManager:
    def __init__(self, max_concurrent: int = 8, max_queue: int = 100):
        self.tasks: dict[str, TaskStatus] = {}
        self.queues: dict[str, asyncio.Queue] = {}     # 每个任务的事件队列
        self.sem = asyncio.Semaphore(max_concurrent)
        self.workers = []                               # 后台执行协程

    def create(self, req: ChatRequest) -> str:
        if len(self.tasks) >= self.max_queue:
            raise HTTPException(503, "任务队列已满，请稍后重试")
        task_id = uuid.uuid4().hex[:16]
        self.tasks[task_id] = TaskStatus(
            task_id=task_id, status="queued",
            created_at=datetime.now().isoformat(),
        )
        self.queues[task_id] = asyncio.Queue()
        # 起后台任务执行，不阻塞 HTTP 响应
        asyncio.create_task(self._run(task_id, req))
        return task_id

    async def _run(self, task_id: str, req: ChatRequest):
        async with self.sem:                      # 并发控制
            t = self.tasks[task_id]
            t.status = "running"
            try:
                result = await asyncio.wait_for(
                    agent_app.ainvoke(req, on_event=lambda e: self._emit(task_id, e)),
                    timeout=GLOBAL_TASK_TIMEOUT,
                )
                t.status = "completed"
                t.answer = result.answer
                t.sources = result.sources
                t.tokens_used = result.usage.total_tokens
            except asyncio.TimeoutError:
                t.status = "failed"
                t.error = f"任务超时（{GLOBAL_TASK_TIMEOUT}s）"
            except asyncio.CancelledError:
                t.status = "cancelled"
                raise
            except Exception as e:
                t.status = "failed"
                t.error = f"{type(e).__name__}: {e}"
            finally:
                t.finished_at = datetime.now().isoformat()
                self._emit(task_id, {"event": "done"})
```

**三个关键点**：

1. **`asyncio.create_task` 让 HTTP 响应立即返回**，不挂连接
2. **`Semaphore` 控制并发**（Agent 任务重，8 并发可能就饱和）
3. **`wait_for` 兜底超时**，防跑飞

### 3.2 接口

```python
@app.post("/api/task", status_code=202)
async def create_task(req: ChatRequest) -> dict:
    task_id = task_manager.create(req)
    return {"task_id": task_id, "status_url": f"/api/task/{task_id}"}

@app.get("/api/task/{task_id}")
async def get_task(task_id: str) -> TaskStatus:
    t = task_manager.tasks.get(task_id)
    if not t:
        raise HTTPException(404, "任务不存在")
    return t

@app.post("/api/task/{task_id}/cancel")
async def cancel_task(task_id: str) -> dict:
    """优雅取消：置状态 + 通知 Agent 停止。"""
    ...
```

**202 Accepted** 是创建异步任务的标准返回码，语义准确。

---

## 四、SSE 订阅

```python
from fastapi.responses import StreamingResponse

@app.get("/api/task/{task_id}/stream")
async def stream_task(task_id: str):
    if task_id not in task_manager.tasks:
        raise HTTPException(404, "任务不存在")

    async def gen():
        q = task_manager.queues[task_id]
        t = task_manager.tasks[task_id]

        # 先补发历史事件（客户端可能中途加入）
        for ev in task_manager.history(task_id):
            yield format_sse(ev)

        if t.status in ("completed", "failed", "cancelled"):
            yield format_sse({"event": "done"})
            return

        while True:
            try:
                ev = await asyncio.wait_for(q.get(), timeout=30.0)
            except asyncio.TimeoutError:
                yield ": ping\n\n"                 # 心跳
                continue
            yield format_sse(ev)
            if ev.get("event") == "done":
                break

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})
```

---

## 五、中间件与生产细节

### 5.1 鉴权

```python
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

security = HTTPBearer()

async def verify_token(cred: HTTPAuthorizationCredentials = Depends(security)):
    payload = jwt.decode(cred.credentials, SECRET, algorithms=["HS256"])
    return payload["user_id"]          # 后续所有逻辑基于这个 user_id

@app.post("/api/task")
async def create_task(req: ChatRequest, user_id: str = Depends(verify_token)):
    # user_id 从 token 取，不接受客户端传——防冒充
    ...
```

**`user_id` 必须从 token 取，不能从请求体取。** 否则用户可以传别人的 ID，拿到别人的上下文。

### 5.2 限流

```python
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)

@app.post("/api/task")
@limiter.limit("10/minute")               # 每 IP 每分钟 10 次
async def create_task(req: ChatRequest, request: Request,
                      user_id: str = Depends(verify_token)):
    ...
```

**按用户限比按 IP 限准**（NAT 后面一群人共享一个 IP）。用 `key_func` 换成 user_id。

### 5.3 请求日志与 trace

```python
import time, uuid

@app.middleware("http")
async def add_trace(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID", uuid.uuid4().hex[:12])
    start = time.time()
    try:
        response = await call_next(request)
        return response
    finally:
        logger.info("http.request", extra={
            "request_id": request_id,
            "path": request.url.path,
            "method": request.method,
            "duration_ms": int((time.time() - start) * 1000),
        })
        response.headers["X-Request-ID"] = request_id
```

**`X-Request-ID` 贯穿全链路**，排障时用它对前后端和 Agent 内部日志。

### 5.4 优雅退出

```python
@app.on_event("shutdown")
async def shutdown():
    # 等运行中的任务收尾（最多 30 秒），不丢已完成的一半
    await task_manager.drain(timeout=30)
```

**不 drain 直接退出，正在跑的任务全丢。** 滚动发布时这是数据丢失。

### 5.5 健康检查

```python
@app.get("/health")
async def health():
    return {"status": "ok", "queue_depth": len(task_manager.tasks),
            "active": task_manager.active_count}
```

**K8s 探针用这个。** 如果队列爆满，可以返回 503 让 K8s 摘流——比让请求排队超时好。

---

## 六、常见误区

**误区一：同步返回长任务。** 连接全挂住，连接池满，轻量请求也进不来。**必须任务化。**

**误区二：任务状态只存内存。** 进程重启全丢，也做不了多实例。生产至少要存 Redis。

**误区三：user_id 从请求体取。** 用户可以冒充别人。从 token 取。

**误区四：没有全局任务超时。** 一个跑飞的任务占着 worker，后面全堵。`wait_for` 必须有。

**误区五：并发不设限。** Agent 任务重（几十次 LLM 调用），8~16 并发可能就是上限。Semaphore 必须有。

**误区六：SSE 忘了 `X-Accel-Buffering: no`。** 本地好好的，上 Nginx 就变成最后一次性收到。

**误区七：没有优雅退出。** 滚动发布时全丢进行中的任务。`shutdown` 里 drain。

**误区八：错误直接抛裸异常。** 客户端拿到 500 + 堆栈。返回结构化的 `{"error": "...", "detail": "..."}`，堆栈只进日志。

---

## 七、一套最小骨架

```python
# main.py —— 拿这个改改就能用
from fastapi import FastAPI, Depends, HTTPException
from contextlib import asynccontextmanager

@asynccontextmanager
async def lifespan(app: FastAPI):
    await task_manager.start()
    yield
    await task_manager.drain(timeout=30)        # 优雅退出

app = FastAPI(title="Agent Service", lifespan=lifespan)

app.include_router(tasks.router, prefix="/api", tags=["tasks"])
app.include_router(stream.router, prefix="/api", tags=["stream"])
app.add_middleware(TraceMiddleware)
app.add_middleware(RateLimitMiddleware, limit="10/minute")
```

**用 `lifespan` 而不是 `@app.on_event`**——后者已废弃，新版 FastAPI 推荐 lifespan 上下文管理器。

---

## 小结

- Agent 请求**可能几秒也可能几分钟**，所以**默认任务化**：`POST /api/task` 立即返回 task_id，客户端轮询或 SSE 订阅。统一形态比「短同步长异步」省一半代码。
- TaskManager 三个核心：**`create_task` 不阻塞响应（create_task 协程）、Semaphore 控并发（Agent 重，8~16 就饱和）、`wait_for` 全局超时（防跑飞）**。
- 必须有的生产件：**鉴权（user_id 从 token 取，不接受请求体）、限流（按用户不按 IP）、X-Request-ID 全链路、优雅退出（drain 进行中的任务）、health 探针**。
- SSE 订阅要**补发历史事件**（客户端可能中途加入）+ **心跳** + `X-Accel-Buffering: no`。
- 状态存储至少 Redis——纯内存的话进程重启全丢，也没法多实例。
- 错误返回结构化，堆栈只进日志。**客户端不需要看到你的异常链。**

Jupyter 里跑通到生产服务，中间隔着的不是模型，是任务管理、并发控制、鉴权限流这些「无聊」的东西。早做比晚做好——因为这些边界条件，等有用户了再补就是事故。
