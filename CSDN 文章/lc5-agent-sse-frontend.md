# SSE 推送：把 Agent 的执行过程实时送到前端

用户点了「开始调研」，页面上只有一个转圈按钮。30 秒后，答案出来了。这 30 秒里用户不知道：是在检索？在思考？还是卡死了？

**黑盒等待是 Agent 产品体验最大的短板。** LLM 生成有 token 级流式输出可以展示，但 Agent 的执行过程（在调哪个工具、检索到了什么、计划到第几步）也需要实时可见——**否则用户没法判断该继续等还是该取消。**

SSE（Server-Sent Events）是把这些过程推送到前端的标准方案。这篇讲清楚协议怎么用、事件怎么设计、以及工程上的坑。

---

## 一、为什么是 SSE 而不是 WebSocket

两者都能服务端推送，但 Agent 场景 SSE 更合适。

| | SSE | WebSocket |
|---|-----|-----------|
| 方向 | 服务端 → 客户端（单向） | 双向 |
| 协议 | 普通 HTTP | 升级协议 |
| 断线重连 | **浏览器自动** | 要自己实现 |
| 实现复杂度 | 低 | 高 |
| 代理/网关兼容 | 好（就是 HTTP） | 差（要配 WS 穿透） |
| 浏览器限制 | **同域 6 个连接** | 无 |

**Agent 推送的本质是「日志流」**：服务端持续把过程事件发给客户端，客户端基本不回话。这是 SSE 的舒适区。

**什么时候用 WebSocket**：需要客户端频繁发消息（协同编辑、实时语音对话）。Agent 过程推送用不上。

---

## 二、SSE 协议基础

### 二.1 最小实现

服务端返回 `text/event-stream`，每行一个字段，空行分隔事件：

```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive

event: thought
data: 我需要先查一下订单状态

event: tool_call
data: {"tool": "query_order", "args": {"order_id": "ORD-12345678"}}

event: tool_result
data: {"status": "shipped", "eta": "2026-10-20"}
```

**四个核心字段**：

- `event`：事件类型（自定义，客户端用来分发）
- `data`：内容（多行要用多个 `data:` 行，客户端会用 `\n` 拼回）
- `id`：事件 ID，断线重连时客户端带 `Last-Event-ID` 请求，服务端可以补发
- `retry`：告诉客户端断线后多久重连（毫秒）

### 2.2 为什么必须有心跳

**没有心跳的 SSE 会被中间代理掐断。** Nginx、CDN、负载均衡都有默认超时（常见 60 秒），连接空闲超过就断。

```
: 这是一个注释行，SSE 用它做心跳（客户端不会收到）

: ping
```

定时发注释行（每 15~30 秒），保持连接活跃。**这是生产环境必须做的**，否则用户会看到「跑到一半连接断了」。

### 2.3 客户端

```javascript
const es = new EventSource("/agent/stream?task_id=abc123");

// 按事件类型分发
es.addEventListener("thought", (e) => {
    appendThought(JSON.parse(e.data));
});

es.addEventListener("tool_call", (e) => {
    showToolCall(JSON.parse(e.data));
});

es.addEventListener("answer", (e) => {
    showAnswer(e.data);
    es.close();                       // 收到结束事件主动关闭
});

es.addEventListener("done", () => es.close());

es.onerror = (e) => {
    // EventSource 会自动重连，这里只做 UI 提示
    if (es.readyState === EventSource.CLOSED) {
        showError("连接已断开");
    }
};
```

**浏览器自动重连**是 SSE 的优势——不用自己写重试逻辑。

---

## 三、Agent 的事件怎么设计

### 3.1 事件类型清单

```python
class EventType:
    # 生命周期
    STARTED = "started"            # 任务开始
    PLANNED = "planned"            # 计划生成
    STEP_START = "step_start"      # 某步骤开始
    STEP_END = "step_end"          # 某步骤结束
    DONE = "done"                  # 全部完成
    ERROR = "error"                # 出错

    # 过程细节
    THINKING = "thinking"          # 模型的推理片段
    TOOL_CALL = "tool_call"        # 调用工具
    TOOL_RESULT = "tool_result"    # 工具返回
    RETRIEVAL = "retrieval"        # 检索到文档

    # 输出
    TOKEN = "token"                # 最终答案的 token（流式）
    ANSWER = "answer"              # 完整答案
    SOURCES = "sources"            # 引用来源
```

### 3.2 事件的载荷设计

```python
def sse_event(event: str, data: dict, event_id: str | None = None) -> str:
    payload = json.dumps(data, ensure_ascii=False)
    lines = []
    if event_id:
        lines.append(f"id: {event_id}")
    lines.append(f"event: {event}")
    # data 可能含换行，必须每个换行前都加 data: 前缀
    for line in payload.split("\n"):
        lines.append(f"data: {line}")
    return "\n".join(lines) + "\n\n"
```

**`data` 里的换行必须处理**——一条 JSON 里有 `\n`，就要拆成多行 `data:`。少了这个，客户端收到的 JSON 是断的，解析失败。

### 3.3 前端展示的对应关系

| 事件 | 前端怎么展示 |
|------|------------|
| `started` | 显示「开始处理」 |
| `planned` | 渲染计划列表（可折叠） |
| `step_start/end` | 高亮当前步骤，已完成的打勾 |
| `thinking` | 打字机式展示推理 |
| `tool_call` | 显示「正在调用 XXX」 |
| `tool_result` | 可折叠的结果详情 |
| `token` | 答案区打字机效果 |
| `sources` | 答案末尾显示引用 |
| `error` | 醒目错误 + 重试按钮 |

**关键是 `step_start/end`**：它让用户看到「计划到第几步了，还剩几步」。这比单纯的字幕更让用户安心。

---

## 四、服务端实现

### 4.1 FastAPI 版

```python
from fastapi import FastAPI
from fastapi.responses import StreamingResponse

app = FastAPI()

@app.get("/agent/stream")
async def stream(task_id: str):
    async def event_generator():
        queue: asyncio.Queue = task_queues[task_id]

        # 先补发历史事件（断线重连场景）
        last_id = request.headers.get("Last-Event-ID")
        for ev in replay_history(task_id, after=last_id):
            yield ev

        while True:
            try:
                event = await asyncio.wait_for(queue.get(), timeout=30.0)
            except asyncio.TimeoutError:
                # 心跳，防代理超时
                yield ": ping\n\n"
                continue

            yield event
            if event.startswith("event: done"):
                break

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",          # 关掉 Nginx 缓冲！关键
        },
    )
```

### 4.2 三个必须注意的点

**点一：`X-Accel-Buffering: no`**
Nginx 默认缓冲代理响应，SSE 会被攒着不发。这个 header 可以让 Nginx 立即透传。**没有它，本地的 SSE 全正常，上了 Nginx 就变成「最后一次性收到全部」。**

**点二：生产者-消费者解耦**
Agent 执行在后台任务/线程里，SSE 处理器负责把事件转发给客户端。队列连接两者。**不要让 SSE 连接去驱动 Agent 执行**——连接断了任务就停了。

**点三：多客户端订阅**
同一个任务，可能多个页面在看。用「任务 + 订阅者列表」：

```python
class EventBus:
    def __init__(self):
        self.subscribers: dict[str, list[asyncio.Queue]] = defaultdict(list)

    def subscribe(self, task_id: str) -> asyncio.Queue:
        q = asyncio.Queue(maxsize=100)
        self.subscribers[task_id].append(q)
        return q

    def unsubscribe(self, task_id: str, q: asyncio.Queue):
        self.subscribers[task_id].remove(q)

    async def publish(self, task_id: str, event: str):
        for q in self.subscribers[task_id]:
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                # 客户端消费太慢，丢 oldest 保 newest
                q.get_nowait()
                q.put_nowait(event)
```

---

## 五、工程坑清单

### 5.1 Nginx 缓冲

```nginx
location /agent/ {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;              # 关缓冲
    proxy_read_timeout 3600s;         # 长任务要放宽超时
    proxy_send_timeout 3600s;
    chunked_transfer_encoding on;
}
```

**`proxy_buffering off` 是 SSE 的生死线。**

### 5.2 单次连接的浏览器限制

**HTTP/1.1 下，浏览器对同一域名最多 6 个 SSE 连接。** 开 8 个页面同时跑任务，后两个连不上。

解法：上 HTTP/2（多路复用，没这个限制），或者合并成单连接 + 服务端按 task_id 分发。

### 5.3 移动端与弱网

- 锁屏后连接可能被系统杀掉 → `Last-Event-ID` 重连补发
- 弱网下频繁重连 → 客户端做指数退避，别狂连
- 事件量大 → 服务端合并/丢弃非关键事件（`thinking` 可以降频）

### 5.4 内存

每个订阅一个队列，队列有上限（`maxsize`）。**无界队列 + 慢客户端 = 内存泄漏。** 客户端断开要 `unsubscribe`，别让队列挂在字典里。

---

## 六、降级方案

不是所有客户端都支持 SSE / 都在同一域。

**降级一：轮询**

```python
# /agent/status 返回当前进度，客户端 1~2s 轮询一次
@app.get("/agent/status")
async def status(task_id: str):
    return {"step": 3, "total": 6, "current": "检索中",
            "events": recent_events(task_id, n=10)}
```

**降级二：长轮询**

客户端发请求，服务端 hold 住直到有新事件或超时才返回。比轮询实时，比 SSE 兼容性好。

**降级三：WebSocket 兜底**
如果跨域且不能用 HTTP/2，退回 WebSocket。

**默认 SSE + 轮询兜底**是性价比最高的组合。

---

## 七、常见误区

**误区一：没关 Nginx 缓冲。** 本地好的，上线就变成「最后一秒全来」。

**误区二：没有心跳。** 代理 60 秒掐断，长任务必断。

**误区三：`data` 里有换行没拆行。** 客户端 JSON 解析失败，你排查半天以为是格式问题。

**误区四：SSE 连接驱动任务执行。** 连接断了任务跟着停。必须解耦。

**误区五：队列无上限。** 慢客户端把服务端内存吃光。

**误区六：忘了关旧连接。** 客户端 close 了，服务端的订阅者和队列还在字典里。

**误区七：一次发太多事件。** `thinking` 每个 token 一个事件，网络和前端都扛不住。合并成片段。

---

## 小结

- Agent 的过程必须实时可见——**黑盒等待是体验最大的短板**，用户没法判断该等还是该取消。
- **SSE 比 WebSocket 更适合**：单向推送、自动重连、HTTP 兼容、实现简单。
- 事件设计核心是 `step_start/step_end`（让用户看到计划进度）+ `token`（答案打字机）。其余按需。
- 服务端三个必须：**`X-Accel-Buffering: no`（关 Nginx 缓冲，SSE 的生死线）、心跳注释行（防代理 60s 超时）、生产者-消费者解耦（连接断了任务不能停）**。
- 多客户端用事件总线（任务 + 订阅者队列），**队列必须有 maxsize**，客户端断开要 unsubscribe。
- 浏览器同域 6 连接限制 → HTTP/2 或多任务合并单连接。
- 兜底：SSE 主 + 轮询备。长轮询折中。

SSE 的技术含量不高，但它是「Agent 能不能让人愿意等」的关键。**同样 30 秒的任务，黑盒等待像是卡死了，有过程推送像是在干活。**
