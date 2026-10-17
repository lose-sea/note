# LLM 应用上 K8s：HPA、探针和优雅退出

容器打包好只是起点。K8s 上一套组合拳——Deployment 管副本、Service 管流量、HPA 管伸缩——对普通 Web 服务是标准动作，但 LLM 应用有两个"反直觉"的地方：**它的每次请求又贵又慢，按 QPS 扩容经常扩了个寂寞**；**请求动辄几十秒，粗暴杀进程等于把用户的钱扔进水里**。这篇文章把这两件事怎么配讲清楚。

## 部署清单：先抄再改

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-api
spec:
  replicas: 2
  selector:
    matchLabels: { app: rag-api }
  template:
    metadata:
      labels: { app: rag-api }
    spec:
      containers:
        - name: api
          image: registry.example.com/rag-api:v1.4.2
          ports: [{ containerPort: 8000 }]
          envFrom:
            - secretRef: { name: rag-api-secrets }
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
            limits:   { cpu: "2",    memory: "2Gi" }
          readinessProbe:
            httpGet: { path: /readyz, port: 8000 }
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: 8000 }
            initialDelaySeconds: 30
            periodSeconds: 20
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 10"]
          terminationGracePeriodSeconds: 90
---
apiVersion: v1
kind: Service
metadata: { name: rag-api }
spec:
  selector: { app: rag-api }
  ports: [{ port: 80, targetPort: 8000 }]
```

几个字段是专为 LLM 应用调的，下面逐个说为什么。

## HPA：别按 QPS，按并发和延迟

默认教程教你 `autoscaling/v2` 按 CPU 或者按 QPS 扩。LLM 应用这里全是坑：

**按 CPU 扩不准**。请求大部分时间花在等模型 API 返回（网络 + 排队 + 推理），CPU 可能连 10% 都占不到。你看到 CPU 一片绿，实际上每个 pod 里都堵着几十个 in-flight 请求。

**按 QPS 扩会滞后**。QPS 涨到阈值时才开始扩，但新 pod 从拉到镜像到 ready 要几十秒，等它上线，洪峰早过去了。

**正确的指标是并发请求数和 P95 延迟**。这两个直接反映"请求堵不堵"：

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: rag-api }
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rag-api
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Pods
      pods:
        metric:
          name: http_requests_in_flight
        target:
          type: AverageValue
          averageValue: "20"
    - type: Pods
      pods:
        metric:
          name: http_request_duration_p95
        target:
          type: AverageValue
          averageValue: "800m"  # 毫秒
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 100
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
```

这里需要你的应用暴露自定义指标。FastAPI 侧用中间件顺手就能采集：

```python
import time, prometheus_client
from starlette.middleware.base import BaseHTTPMiddleware

IN_FLIGHT = prometheus_client.Gauge("http_requests_in_flight", "in-flight requests")
LATENCY  = prometheus_client.Histogram("http_request_duration_seconds", "latency")

class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if request.url.path in ("/healthz", "/readyz", "/metrics"):
            return await call_next(request)
        IN_FLIGHT.inc()
        start = time.perf_counter()
        try:
            return await call_next(request)
        finally:
            IN_FLIGHT.dec()
            LATENCY.observe(time.perf_counter() - start)
```

指标暴露给 Prometheus（`prometheus_client.start_http_server(8001)` 或 `/metrics` 路由），HPA 需要集群装了 prometheus-adapter 才能读到自定义指标。没有这套基建的话，退而求其次用 CPU + 内存做兜底指标，再加一条 `scaleUp` 更激进的策略。

`behavior` 那段值得解释：**扩容要快，缩容要慢**。LLM 服务缩容缩猛了，长连接请求全断；缩容保守一点，`stabilizationWindowSeconds: 300` 让它在真正空闲五分钟后再缩，浪费的只是一点空闲资源，比反复抖断连接划算。

## 优雅退出：preStop + sleep 的秘密

这是 K8s 上 LLM 应用最值得注意的一个配置。默认情况下，K8s 发终止信号后直接把 pod 从 Service 的 endpoints 里摘掉，然后等 30 秒 SIGKILL。问题在于**从 endpoints 摘除、到所有客户端 LB 感知到这个变化，是有时间差的**——DNS 缓存、keep-alive 连接、客户端自己的连接池，都让你"已经摘掉"的 pod 继续收到新请求。新请求进来时 pod 已经收到 SIGTERM 进入退出流程，用户看到的就是一批莫名失败的请求。

解法就是上面 YAML 里的组合：

1. `preStop: sleep 10`——pod 进入终止流程后先扛 10 秒，这段时间里继续处理存量请求。10 秒是行业里默认拍的吗？是个经验值：够覆盖大部分 LB 的传播延迟。
2. `terminationGracePeriodSeconds: 90`——给 SIGTERM 到 SIGKILL 之间留 90 秒。LLM 请求长，一个流式生成可能两分钟，90 秒不一定够，但比默认 30 强。真想保护超长请求，需要更复杂的机制（比如应用层把任务状态外置，断开后客户端凭 task_id 重连拉结果）。
3. 应用层接住 SIGTERM，把 in-flight 请求处理完再退出：

```python
import signal, asyncio, contextlib

shutdown_event = asyncio.Event()

def _handle_sigterm(*_):
    shutdown_event.set()

signal.signal(signal.SIGTERM, _handle_sigterm)

@app.on_event("shutdown")
async def graceful():
    # 等待存量请求结束，最多等 80s
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(drain_inflight(), timeout=80)
    # 关闭连接池
    await redis_client.close()
```

uvicorn 本身就是收到 SIGTERM 后先 stop accepting 再等存量请求完成，写 SSE 长连接的话确保生成循环里检查 `shutdown_event.is_set()`，中断时给客户端发一个明确的结束事件，别让 TCP 直接断。

## 探针分工：活性和就绪分开

- **liveness（/healthz）**：只证明"进程没死锁"。LLM 应用里事件循环被一个同步大操作堵住是真实风险（比如有人写了个同步的 requests 调用模型），healthz 迟迟不返回就会重启 pod。它**绝对不能去调模型**——模型 API 抖动时探针全红，K8s 重启所有 pod，故障扩大十倍。
- **readiness（/readyz）**：证明"依赖都活着，可以接流量了"。查 Redis、查向量库、查模型 API 的连通性（一次便宜的 ping 或 list models），失败就把 pod 摘出 endpoints——流量不进来，但 pod 不会被杀。这才是应对模型 API 故障的正确姿势。

两者阈值也不同：liveness 宽松（20s 一次，fail 3 次才重启），readiness 严格（10s 一次，fail 2 次就摘流量）。

## 其他几条实战经验

**GPU 场景另说**。如果镜像里跑的是本地推理框架，HPA 要用 GPU 指标（DCGM exporter），副本数上限受节点 GPU 数硬约束，弹性思路整个不一样——通常做请求排队而不是无脑扩容。

**PDB 一定要配**。滚动更新或多副本同时被杀时，PodDisruptionBudget 保证至少 N 个副本活着：

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: rag-api-pdb }
spec:
  minAvailable: 1
  selector:
    matchLabels: { app: rag-api }
```

**配置和密钥用 Secret，更新要滚动**。`envFrom: secretRef` 是最省事的做法，但改 Secret 不会自动触发 pod 重建，需要 `kubectl rollout restart deployment/rag-api`。

**日志直接 stdout/stderr**，别写容器内文件——采集器捞的是标准输出，写文件既捞不着又占磁盘。

## 结语

K8s 上跑 LLM 应用，核心心法就一条：**把请求当作有状态的、长时间占用连接、失败代价高的资源来对待**。所以 HPA 看并发不看 QPS，缩容要慢；所以退出要 sleep + 排空 + 宽限期三件套；所以探针要分清"别杀我"和"别给我流量"。把这些配置对号入座，你的 Agent 服务才真正有了生产级的韧性。
