# LLM 应用容器化部署：一个能上生产的 Dockerfile

跑通 Notebook 和跑通 Dockerfile 之间隔着一整个工程化的距离。这篇文章把 LangChain/LangGraph 应用打成生产镜像的完整做法写清楚：基础镜像怎么选、模型和向量库这种"重资产"怎么处理、健康检查怎么写、镜像怎么瘦身，以及本地 docker-compose 一把梭的全套配置。

## 一个典型事故的复盘

先说个常见状况：本地 `uvicorn main:app` 跑得好好的，打成镜像上线后疯狂 OOM。排查半天，原因很朴素——本地机器有 32G 内存，容器 limit 给了 2G，而应用在启动时把整个 embedding 模型和 Chroma 的索引全load 进了内存。

容器化的第一课不是怎么写 Dockerfile，而是**承认你的应用有一个真实的资源画像**。LLM 应用相比传统 Web 服务，特殊点在于：

| 资源 | 传统 Web 服务 | LLM 应用 |
|---|---|---|
| 内存 | 几十 MB | 几百 MB ~ 数 GB（加载模型/索引） |
| 启动时间 | 秒级 | 数十秒（下载模型、建索引连接） |
| CPU | 低 | 首启动高（tokenize、embedding），稳态中等 |
| 外部依赖 | DB、Redis | 还有模型 API、embedding 服务、向量库，任一抖动都会拖垮链路 |
| 长连接 | 短请求为主 | SSE/WebSocket 长连接，和默认的 LB 配置经常打架 |

带着这个认知再来看 Dockerfile，每一个选择都有依据。

## Dockerfile 分层写法

不直接上"最佳版本"，先说每一层各自解决什么问题。

### 第一版：能用就行

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

这版有三个问题：requirements 全装没有分层缓存、没有非 root 用户、没有 healthcheck。往下逐条修。

### 第二版：依赖分层 + 多阶段

LLM 项目的依赖分成两类：**稳定层**（fastapi、langchain、uvicorn，几周不变）和**易变层**（你的业务代码，一天改八次）。利用 Docker 的层缓存，让改代码不打乱依赖层：

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels /wheels/* && rm -rf /wheels
COPY app/ ./app/
USER 1000:1000
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

`pip wheel` 在 builder 阶段编译（torch、sentence-transformers 这类带 C 扩展的包编译一次要几分钟），最终镜像只装 wheel 不编译，构建快且镜像里没有 gcc 工具链。**改一次 app/ 下的代码，只需要重跑最后两层**，构建从 8 分钟降到 10 秒。

### 第三版：健康检查不能省

容器平台的存活判断靠 healthcheck。LLM 应用的 healthcheck 有个陷阱：**不能去真调模型**。探针每分钟打一次，每次都真调一次 GPT，既花钱又慢，模型 API 一抖动探针就连片失败，然后 K8s 开始杀容器——一场由探针引发的雪崩。

正确做法是探针只查"进程活着且依赖可达"，把"模型是否正常"交给业务监控：

```python
# app/health.py
from fastapi import APIRouter, Response
import redis, asyncpg

router = APIRouter()

@router.get("/healthz")
async def liveness():
    # 只证明事件循环没卡死
    return {"status": "ok"}

@router.get("/readyz")
async def readiness(response: Response):
    checks = {}
    # 检查重依赖是否可达，带 2s 超时
    try:
        await redis_client.ping()
        checks["redis"] = "ok"
    except Exception:
        checks["redis"] = "fail"
    checks["db"] = "ok" if await asyncpg_ok() else "fail"

    if "fail" in checks.values():
        response.status_code = 503
    return {"checks": checks}
```

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD python -c "import urllib.request,os; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3)" || exit 1
```

注意 `--start-period=60s`：LLM 应用启动慢（要连向量库、可能预热模型），不给启动宽限期会被判定为"启动即失败"反复重启。

## 重资产怎么办：模型和索引不塞进镜像

三个选择，按你的场景选：

**方案一：镜像里带模型**。适合模型体积可控（几十到几百 MB）且需要离线部署的场景。注意把模型放在 `/models` 目录并做成独立层，模型不动这层就一直命中缓存：

```dockerfile
COPY models/ /models/
ENV MODEL_PATH=/models/bge-small-zh
```

**方案二：启动时从对象存储拉取**。适合模型几 GB 以上的场景，镜像保持轻量，启动脚本里用 `aws s3 cp` 或 aria2 下载到本地卷。代价是每次冷启动都要等下载，所以节点最好挂持久卷缓存。

**方案三：调用外部 API**。你自己不部署模型，向量库用云服务。镜像最干净，但把可用性绑定在了外部服务上。

**向量库的索引文件同理**。本地 Chroma/Faiss 索引如果要进镜像，它就是个数据而不是代码，应该放数据卷、或者 nightly job 重建。把索引打进镜像意味着"知识库更新一次就要重新构建发版"，这个耦合大部分人承受不起。

## 镜像瘦身

一个没优化过的 langchain 全功能镜像能到 2GB+。瘦身手段按收益排序：

1. **slim 基础镜像 + 只装需要的 extras**。`langchain[all]` 装了十几个你用不到的集成，按需装 `langchain-core`、`langchain-openai` 就够。review requirements，把只在实际代码里 import 到的包装进去。
2. **清理 pip 缓存和临时文件**：`--no-cache-dir` 加上，apt 装完 `rm -rf /var/lib/apt/lists/*`。
3. **编译工具只在 builder 阶段**：最终镜像不出现 gcc、make。
4. **.dockerignore 必须写**，不然 `.git`、`output/`、`posts/`、`__pycache__`、`.venv` 全被打进去，常见能省几百 MB。

```gitignore
# .dockerignore
.git
.venv
__pycache__
*.pyc
output/
posts/
.pytest_cache
.env
*.log
```

## docker-compose：本地全家桶

生产上向量库和缓存是独立服务，本地用 compose 一把拉起全链路：

```yaml
version: "3.9"
services:
  app:
    build: .
    ports: ["8000:8000"]
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - REDIS_URL=redis://redis:6379/0
      - QDRANT_URL=http://qdrant:6333
    env_file: [.env]
    depends_on:
      redis:
        condition: service_healthy
      qdrant:
        condition: service_started
    deploy:
      resources:
        limits:
          memory: 2G

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s

  qdrant:
    image: qdrant/qdrant:latest
    ports: ["6333:6333"]
    volumes:
      - qdrant_data:/qdrant/storage

volumes:
  qdrant_data:
```

`deploy.resources.limits.memory` 这行别笑，它模拟的就是线上 limit。本地不给容器限内存，OOM 类 bug 你永远测不出来。

## 配置全部走环境变量

十二条要素纪律：容器里不出现任何写死的 key、URL。`.env` 只在本地用，进 `.gitignore`；镜像里一个密钥都没有。启动时用 pydantic-settings 一次性读入并校验，少一个直接启动失败，比运行到一半报 KeyError 体面得多：

```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    openai_api_key: str
    redis_url: str = "redis://localhost:6379/0"
    qdrant_url: str = "http://localhost:6333"
    request_timeout: float = 30.0
    model_config = {"env_file": ".env"}

settings = Settings()  # 缺字段这里就炸，不会等到请求进来
```

## 结语

容器化 LLM 应用的本质是把"资源画像不可控"变成"资源画像可声明"。基础镜像选 slim、编译放 builder 阶段、模型索引不进镜像、healthcheck 只探活不探智、配置全走环境变量——这五条做到了，镜像就具备了上生产的基本素质。下一篇讲这些容器上了 K8s 之后，HPA、探针和优雅退出怎么配。

全文围绕"让镜像可复现、可观测、资源可控"展开，配套的 Dockerfile、compose 和健康检查代码都可以直接拿去改改用在自己的项目里。
