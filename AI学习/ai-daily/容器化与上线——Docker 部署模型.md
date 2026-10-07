<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 容器化与上线——Docker 部署模型

**承上**：上一篇《用 FastAPI 封装模型服务》我们把手写的推理逻辑封成了一个带 `/v1/chat/completions`、支持流式输出和 OpenAI 兼容协议的 HTTP 服务，本地 `uvicorn main:app` 跑得好好的——但它目前只能活在你这台机器上，换台机器就得重装 Python、重装 CUDA、重装依赖，而且没人敢保证换个环境还能跑出一样的结果。

**本篇**：解决"怎么把这个服务交付出去"的问题——用 Docker 把**代码 + Python 依赖 + CUDA 运行时 + 系统库**整体打包成一个可复制的镜像，再讲清 GPU 容器怎么让容器看见显卡、模型权重为什么不能打进镜像、docker-compose 怎么编排多容器、镜像怎么瘦身、以及再往上 K8s 怎么做到扩缩容与灰度发布。

**启下**：下一篇《生产监控与评测体系》解决下一个问题——镜像跑起来之后，**你怎么知道它是好是坏**：延迟的 P99 是多少、显存还剩多少、用户点了多少次踩、模型有没有悄悄退化。

**学完这一节，你能动手做**：

1. 写出一个能挂载本地权重、支持 GPU、带健康检查的大模型服务 Dockerfile，并成功 `docker build` + `docker run` 起来
2. 用 docker-compose 一次拉起"推理服务 + Redis 缓存 + 向量库"三容器，并让服务依赖就绪后才启动
3. 用多阶段构建、`slim` 基础镜像和 `.dockerignore` 把镜像从 20GB 级砍到个位数 GB，并知道每一层缓存为什么命中/失效
4. 写出 Deployment + Service + Ingress + HPA 的 K8s 清单，让服务能申请 GPU、能横向扩容、能一键回滚

---

## 一、为什么大模型服务尤其需要容器化

### 1.1 先从那句经典台词说起："我机器上能跑"

每个做过大模型服务的工程师都经历过这个场景：你在自己的开发机上把 vLLM 跑通了，于是兴冲冲地把 `main.py` 和 `requirements.txt` 发给运维同事，让他在 GPU 服务器上部署。半小时后对方甩过来一段报错：

```
ImportError: libcudart.so.12: cannot open shared object file: No such file or directory
```

你俩开始了一场漫长的对线。最后发现：你机器上装的是 CUDA 12.1，服务器上是 11.8；你的 PyTorch 是 2.3.0+cu121，服务器 pip 自动解析到了 CPU 版本；你还顺手 `apt install` 过 `libnccl-dev`，但那条命令不在任何文档里，你自己都忘了。

**问题的本质不是"装不上"，而是"装的到底是什么，没人说得清"。** 一个能跑的大模型服务，依赖层次比普通 Web 服务深得多：

```
第 4 层：业务代码（app.py、prompt 模板、路由逻辑）
第 3 层：Python 包（vllm / torch / transformers / fastapi / flash-attn）
第 2 层：CUDA 生态（CUDA runtime、cuDNN、NCCL、cuBLAS）—— 有版本矩阵
第 1 层：系统环境（glibc、libstdc++、驱动版本、内核模块）
第 0 层：硬件（GPU 型号、算力 SM、显存容量）
```

普通 Web 服务只要第 4 层和第 3 层对得上就行；**大模型服务四层全部要对，而且下层错一个版本号，上层就直接崩**。这就是所谓"依赖地狱"。Docker 的价值就在于：**它把第 1~3 层全部冻结进镜像，让"能跑的环境"变成一个可以被搬运、被版本化、被复制的文件**。

### 1.2 四个只有容器化才能解决的实际问题

**（1）环境可复现 = 可回滚。** 大模型服务的版本管理不只是代码版本，还包括 CUDA 版本、torch 版本、flash-attn 版本。线上出问题时，你需要能精确回到"上周三那个能跑的组合"。如果环境和代码分离管理，你就得靠文档和记忆去拼；如果环境写在 Dockerfile 里并提交进 Git，回滚就是 `git checkout` 一个 tag 再重新构建。**能不能回滚，决定了你敢不敢发布。**

**（2）依赖隔离 = 一台机器能跑多个模型。** 现实中一台 8 卡服务器往往要同时跑：一个 7B 对话模型（要 CUDA 12.1 + vLLM 0.6）、一个 embedding 模型（要 CUDA 11.8 + 老版本 transformers）、还可能有一个 rerank 服务。这三个服务的 Python 依赖是互相冲突的。裸机上你得靠 conda 环境手工作坊式地隔离，容器里它们天然就是三个互不可见的世界，甚至连 `CUDA_VISIBLE_DEVICES` 都能做到物理卡隔离。

**（3）弹性伸缩 = 成本。** 大模型的流量特征通常是"白天高、夜里低"，而且 GPU 是按小时计费的硬成本。容器化的真正意义是：**让"服务实例"变成一个可以被 K8s 在几分钟内创造和销毁的无状态单元**。裸机上一个实例是要手动部署的资产；容器里它只是一个副本数 `replicas: 3` 里的一个数字。能不能把夜间副本数从 8 缩到 1，直接决定你的 GPU 账单是 100% 还是 30%。

**（4）交付物统一。** 不管是本地开发、测试环境、预发布还是生产，跑的都是**同一个镜像**。CI 里构建一次，到处部署，不存在"测试环境和生产环境行为不一致"这种经典甩锅场景。

### 1.3 传统部署 vs 容器化：一张分工表

| 环节 | 传统裸机部署 | 容器化部署 |
|---|---|---|
| 环境安装 | 手工 `pip install` / `apt install`，靠文档 | 写在 Dockerfile 里，一次构建处处可用 |
| 环境一致性 | 依赖人和文档，漂移是常态 | 镜像哈希保证字节级一致 |
| 多服务混布 | conda / venv 手工隔离，仍可能污染系统库 | 命名空间级隔离，`CUDA_VISIBLE_DEVICES` 切分显卡 |
| 扩容 | 装机、配环境，小时级 | 改副本数，分钟级（取决于镜像拉取速度） |
| 回滚 | 重装旧版本依赖，风险高 | 换镜像 tag 重新拉起，秒级切换 |
| 制品管理 | 无（代码即全部） | 镜像仓库 tag + digest，可审计可签名 |
| 交付边界 | 开发交付代码，运维负责环境（扯皮点） | 开发交付镜像，运维负责编排（边界清晰） |

一句话总结：**容器化解决的核心问题是"把环境从口头约定变成可执行的制品"。**

---

## 二、Docker 核心概念：镜像、容器、层、Dockerfile

### 2.1 三个最容易混的词：镜像、容器、层

很多新手会把"镜像"理解成"虚拟机的 ISO"，把"容器"理解成"一台虚拟机"。这个比喻有害，因为它让你以为容器很重。正确的理解是：

- **镜像（Image）**：一个只读的、分层的**文件系统 + 元数据**。它不是一个运行中的东西，本质上是打包好的文件。
- **容器（Container）**：镜像的**一个运行实例** = 只读的镜像层 + 最上面一层薄薄的**可写层**。容器里的进程本质上就是你宿主机上的一个普通进程，只是被 Linux 的 Namespace（隔离的 PID/网络/挂载视图）和 Cgroups（资源限额）关起来了。
- **层（Layer）**：每执行 Dockerfile 里的一条指令（大部分），就生成一个只读层。**层是缓存和复用的基本单位**。

用一个示意图把它们串起来：

```
┌───────────────────────────────────────────────┐
│  容器 Container（运行时）                       │
│                                               │
│  ┌─────────────────────────────────────────┐  │
│  │  可写层 Container RW Layer              │  │ ← 你容器里新写的日志、
│  │  /app/logs/*.log  /tmp/*                │  │   下载的模型、改的配置
│  │  ⚠ 容器删除即消失（除非用 volume）       │  │   都存在这一层
│  └─────────────────────────────────────────┘  │
│  ┌─────────────────────────────────────────┐  │
│  │  L5  CMD ["python","app.py"]            │  │ ← 只有元数据，不占空间
│  ├─────────────────────────────────────────┤  │
│  │  L4  COPY requirements.txt + pip install│  │ ← 通常是最大的一层（几 GB）
│  ├─────────────────────────────────────────┤  │
│  │  L3  ENV HF_HOME=/cache   LANG=C.UTF-8  │  │
│  ├─────────────────────────────────────────┤  │
│  │  L2  RUN apt-get install -y ...         │  │
│  ├─────────────────────────────────────────┤  │
│  │  L1  FROM nvidia/cuda:12.1.1-runtime-   │  │ ← 基础镜像层
│  │      ubuntu22.04                        │  │
│  └─────────────────────────────────────────┘  │
│                    ↑ 全部只读，可被多个容器共享 │
└───────────────────────────────────────────────┘
        多个容器共享同一份只读层 → 启动快、省磁盘
```

这里有一个对大模型场景特别重要的推论：**同一台机器上跑 4 个相同的推理容器，只读层（含 4GB 的 torch）只占一份磁盘**，每个容器额外消耗的只是各自的可写层。也就是说容器化不但不会浪费空间，反而比跑 4 个独立的 conda 环境省得多。

### 2.2 Dockerfile：把环境写成代码

Dockerfile 是一个纯文本文件，逐行描述"从什么基础镜像出发、往里面加什么、最后怎么启动"。它的本质是**一份可执行的、有版本号的构建脚本**。

几条最常用但最容易被误解的指令：

| 指令 | 作用 | 大模型场景下的典型用法 / 坑 |
|---|---|---|
| `FROM` | 指定基础镜像，**必须是第一条** | 决定 CUDA 版本，选错后面全崩 |
| `WORKDIR` | 设置后续指令的工作目录 | 一定要设，否则文件全丢根目录，很脏 |
| `COPY` / `ADD` | 把宿主机文件复制进镜像 | 用 `COPY`；`ADD` 会自动解压缩/支持 URL，行为不可预测 |
| `RUN` | 在构建期执行命令，提交为新层 | `apt-get clean && rm -rf /var/lib/apt/lists/*` 必须跟在同一条 RUN 里才真能瘦身 |
| `ENV` | 设置环境变量 | `HF_HOME`、`TOKENIZERS_PARALLELISM`、`LANG` 都是常用项 |
| `EXPOSE` | **只是文档声明**，不真的开端口 | 真正开端口靠运行时的 `-p` |
| `VOLUME` | 声明匿名卷挂载点 | 权重目录、缓存目录用它提醒使用者："这里必须挂出去" |
| `HEALTHCHECK` | 定义容器健康探测命令 | 大模型加载慢，`--start-period` 不开的话一定被判死（详见第十二节） |
| `USER` | 切换运行用户 | 默认 root 跑推理服务是安全隐患（详见第十二节） |
| `ENTRYPOINT`/`CMD` | 启动命令 | `ENTRYPOINT` 是不可覆盖的主命令，`CMD` 是可被 `docker run` 尾部参数覆盖的默认参数 |

一个关键细节是 **`COPY` 与 `RUN` 的顺序决定了缓存命中率**，这一点在后面第七节"镜像瘦身"里会专门展开，因为它直接影响你每次改代码要重新构建多久。

### 2.3 数据去哪了：volume、bind mount 与 tmpfs

容器删掉之后，可写层随之消失，容器里写的日志、下的数据全没了。为了让数据活过容器的生命周期，需要挂载。三种方式的区别必须分清：

| 类型 | 命令示例 | 数据存在哪 | 大模型场景怎么用 |
|---|---|---|---|
| **bind mount（绑定挂载）** | `-v /data/models:/models` | 宿主机指定路径 | **挂载模型权重的标准做法**，路径直观、可用宿主机工具直接管理 |
| **named volume（命名卷）** | `-v llm_cache:/cache` | Docker 管理的区域（Linux 默认 `/var/lib/docker/volumes/...`） | 放 HF 缓存 Redis 数据，跨机器迁移方便，备份有标准工具 |
| **tmpfs** | `--tmpfs /run/infer:size=2g` | **内存**（宿主 RAM） | 临时中间结果、不希望落盘的中间文件；注意它会跟显卡抢主机内存 |

还有一个大模型专属的、特别容易踩的挂载：共享内存 `/dev/shm`。Docker 默认给每个容器分配 **64MB** 的 `/dev/shm`，而多卡推理时 PyTorch/NCCL 的进程间通信非常依赖这块区域，于是你会看到诡异的报错：

```
RuntimeError: NCCL error ... unhandled system error
# 或者更隐晦的 Bus error (core dumped)
```

解决办法是构建/运行时显式加大：`docker run --shm-size=16g ...`，或者（安全性稍差但更简单）`--ipc=host` 直接用宿主机的 IPC 命名空间。**这是多卡 vLLM 部署几乎必配的一个参数**，第十二节还会再强调一遍。

### 2.4 容器网络：三层服务怎么互相找到对方

单机场景下最常用的两种网络模式：

- **bridge（默认）**：Docker 建了一个虚拟网桥，容器各拿一个内网 IP（如 `172.17.0.3`）。容器之间可以用 IP 互访，但**外部访问必须靠 `-p 8080:8000` 做端口映射**。
- **host**：容器直接用宿主机网络栈，没有隔离也不需要 `-p`，性能略好（少一层 NAT）。代价是端口容易冲突，多个推理实例不能都用 8000。推理服务一般不推荐。

而在 docker-compose 和 K8s 里，你会发现不需要写 IP 了——因为 **Docker / K8s 内置了服务发现**：你只需要用**服务名**（如 `http://redis:6379`、`http://milvus:19530`）作为主机名访问，DNS 会自动解析到对应容器的 IP。这就是为什么第六节的 compose 文件里健康检查写的是服务名而不是 IP。

```
  宿主机 localhost:8080
        │  (端口映射 -p 8080:8000)
        ▼
┌─── Docker bridge: llm-net ──────────────────┐
│                                             │
│  ┌──────────┐   HTTP/8000   ┌───────────┐   │
│  │  vllm    │◄──────────────│  api-gw   │   │
│  │  :8000   │               │  :9000    │   │
│  └────┬─────┘               └───────────┘   │
│       │  redis://redis:6379                 │
│       ▼                                     │
│  ┌──────────┐                               │
│  │  redis   │   ← 服务名即域名，DNS 自动解析 │
│  └──────────┘                               │
└─────────────────────────────────────────────┘
```

---

## 三、GPU 容器：让容器看见显卡

### 3.1 容器默认看不见 GPU，为什么

容器里缺省只有 CPU 设备，看不到 `/dev/nvidia0`。原因很简单：**GPU 是硬件设备，容器技术本身隔离的是软件视图（文件系统、进程、网络），硬件访问要靠宿主机的设备文件和内核驱动**。

NVIDIA 给出的解决方案是 **NVIDIA Container Toolkit**，它的工作原理是在容器启动时"注入"三样东西：宿主机的 GPU 设备文件（`/dev/nvidia0`、`/dev/nvidiactl`、`/dev/nvidia-uvm`）、用户态驱动库（`libcuda.so` 等），以及必要的环境变量：

```
宿主机
┌──────────────────────────────────────────────────────┐
│  GPU 硬件 A100 ── NVIDIA 内核驱动 (Driver 550.54.14)  │
│                        │                             │
│  /dev/nvidia0  libcuda.so.550.54.14                  │
└────────────────────────┬─────────────────────────────┘
                         │ NVIDIA Container Toolkit
                         │  ① 挂载设备文件 ② 注入驱动库 ③ 设 env
                         ▼
┌─── 容器内 ───────────────────────────────────────────┐
│  /dev/nvidia0 存在 ✓                                 │
│  libcuda.so (来自宿主机驱动，版本 = 550.54.14)         │
│  libcudart.so (来自镜像里的 CUDA runtime, v12.4)      │
│  nvidia-smi 可用 ✓   torch.cuda.is_available() ✓     │
└──────────────────────────────────────────────────────┘
```

请注意这个图里最关键的一句话：**容器里有两个 CUDA，它们不是一回事**：

1. **CUDA Driver API（`libcuda.so`）** —— 来自**宿主机驱动**，你改不了，容器启动时被注入；
2. **CUDA Runtime（`libcudart.so`）+ 编译器 nvcc** —— 来自**镜像**，由你选的 `FROM` 决定。

绝大多数报错都源于这两个 CUDA 版本不匹配。理解这一点，第三节剩下的内容就都是推论了。

### 3.2 兼容性规则：一条铁律 + 一张表

**铁律：宿主机驱动版本决定上限，容器内 CUDA runtime 版本不能超过这个上限。**

驱动是向后兼容的（新驱动支持老 CUDA），但不能向前兼容（老驱动不支持新 CUDA）。所以：

```
宿主机驱动 550.54.14  →  最高支持 CUDA 12.4
├── 镜像用 cuda:12.4-runtime   ✅ 边界内
├── 镜像用 cuda:12.1-runtime   ✅ 完全 OK（向下兼容）
└── 镜像用 cuda:12.8-runtime   ❌ 越界，报错或 CUDA 不可用
```

常用 CUDA 版本对宿主机驱动的最低要求（**以 NVIDIA 官方 CUDA Release Notes 为准**，下表用于快速对照）：

| CUDA runtime 版本 | 要求的 Linux 驱动最低版本 | 常见对应 cuDNN |
|---|---|---|
| 11.8 | ≥ 520.61.05 | 8.6 |
| 12.1 | ≥ 530.30.02 | 8.9 |
| 12.2 | ≥ 535.54.03 | 8.9 |
| 12.4 | ≥ 550.54.14 | 9.0 |
| 12.6 | ≥ 560.28.03 | 9.3 |
| 12.8 | ≥ 570.80.10 | 9.7 |

**实践建议**：线上集群的驱动版本通常由运维统一控制，且升级驱动需要重启机器（风险高）。所以正确的做法是——**先问清楚 GPU 服务器的驱动版本，再倒推能用的最高 CUDA 版本，最后选基础镜像**。这个顺序不能反过来。

### 3.3 CUDA 基础镜像怎么选

NVIDIA 官方镜像仓库 `nvidia/cuda` 的 tag 有固定的命名规则：

```
nvidia/cuda : <CUDA版本> - <变体> - <系统发行版>
              └─ 12.1.1    └─ devel/runtime/cudnn8-devel
                                └─ ubuntu22.04 / ubuntu20.04 / ubi9

例：nvidia/cuda:12.1.1-runtime-ubuntu22.04
    nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04
    nvidia/cuda:12.4.1-devel-ubuntu22.04
```

三个变体的区别：

| 变体 | 含有什么 | 体积（约） | 什么时候用 |
|---|---|---|---|
| `base` | 只有 CUDA runtime 的最小集 | ~300MB | 极少直接用 |
| `runtime` | runtime + cuBLAS 等常用库 | ~1.5~2GB | **首选**：纯推理、已经装好 wheel 的场景 |
| `devel` | runtime + **nvcc 编译器 + 头文件 + 静态库** | ~4~5GB | 需要在容器内**编译** CUDA 扩展时（如自己编译 flash-attn、自定义算子） |
| `cudnn8/cudnn9` 前缀 | 额外带 cuDNN | +0.5~1GB | 训练场景；vLLM 推理一般不需要 |

**vLLM 到底选哪个？** 这是个真实的高频问题。vLLM 的安装分两种情形：

- **装预编译 wheel**（`pip install vllm`，绝大多数情况）：镜像里只需要能加载 CUDA 运行时库，**`runtime` 变体完全够用，体积小一半**。
- **源码编译 / 需要编译 flash-attention 等算子**：必须 `devel`，否则 `nvcc not found`。

一个稳妥的折中：先用 `runtime` 起容器 docker run 试一下，如果报 `libcudart.so`、`libcuda xxx not found` 或编译期缺 `nvcc`，就换 `devel`。另外 vLLM 官方维护了 `vllm/vllm-openai` 镜像，**如果只是想最快跑起来，直接用官方镜像是最省事的路径**（第四节会给出自己写的版本，第六节的 compose 里会提到何时改用官方镜像）。

### 3.4 `--gpus` 参数怎么用

Docker 19.03 之后，旧时代的 `nvidia-docker2` 命令被原生参数取代，用法如下：

```bash
# 让容器看见所有 GPU
docker run --gpus all ...

# 只让容器看见第 0、1 两张卡（按 nvidia-smi 的物理编号）
docker run --gpus '"device=0,1"' ...

# 限制算力与显存（MIG 场景）
docker run --gpus 'all,"capabilities=compute,utility"' ...

# 等价的老式写法（不推荐，但很多老教程还在写）
docker run -e NVIDIA_VISIBLE_DEVICES=0,1 ...
```

需要提醒的两点：

1. `--gpus` 是**运行时参数**，跟 Dockerfile 无关。同一个镜像在 CPU 机器上不带 `--gpus` 也能跑（只是 `torch.cuda.is_available()` 返回 False）。
2. `--gpus '"device=0,1"'` 那层奇怪的引号是必需的：**外层单引号给 shell，内层双引号给 Docker CLI**。少一层会报 device 解析错误。

容器起来后第一件事永远是验证：

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-runtime-ubuntu22.04 nvidia-smi
```

预期会看到和宿主机几乎一致的显卡信息输出（驱动版本显示的是宿主机驱动的版本），这是"GPU 直通成功"的唯一可靠证据。如果这条命令能出结果，你后面 90% 的 GPU 相关问题就已经排除了。

---

## 四、动手：给 FastAPI + vLLM 服务写 Dockerfile

上一节我们写好的推理服务现在要打包。这一节给出一套能直接用的完整工程模板。

### 4.1 项目结构

一个**正确的大模型服务项目结构**，第一眼就该能看出"权重不在镜像里"：

```
llm-serving/
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── .dockerignore        # 必须！否则 20GB 数据集被塞进构建上下文
├── .env.example         # 提交到 Git 的配置样例（不含真实密钥）
├── app/
│   ├── __init__.py
│   ├── main.py          # FastAPI 入口
│   ├── settings.py      # 环境变量统一读这里
│   └── engine.py        # vLLM 引擎封装（可换成 transformers）
└── models/              # ❌ 绝不放权重，只放 README 说明挂载方式
```

而宿主机上的真实布局应该是这样（**镜像里看不见左边这一列**）：

```
宿主机 /data/llm/hub/Qwen2.5-7B-Instruct/   → 挂载进容器 /models/Qwen2.5-7B-Instruct
宿主机 /data/llm/cache/                     → 挂载进容器 /cache (HF_HOME)
```

### 4.2 为什么模型权重绝对不能打进镜像

这是初学者最容易犯、代价也最高的一个错误。7B 模型 bf16 权重约 15GB，70B 约 140GB。如果 `COPY` 进镜像，会发生：

| 后果 | 具体表现 |
|---|---|
| 镜像体积爆炸 | 20GB+ 起步，`docker push/pull` 一次十几分钟到几十分钟 |
| 构建缓存被污染 | 权重层通常是最后几层之一，但它前面的层一改就要重传整个权重层 |
| **扩缩容极其缓慢** | K8s 调度一个新 Pod 要先拉 20GB 镜像，冷启动从 30 秒变成 10 分钟，HPA 基本失效 |
| 权重与镜像耦合 | 换一版微调权重就得重建整个镜像，无法做到"一份镜像，多个产品线" |
| 分发困难 | 私有仓库磁盘被几十个大镜像撑爆，且没法做按模型的增量更新 |

正确做法是**数据与代码分离**：镜像里只放"程序"，权重用 **bind mount 或共享存储（NFS / OSS CSI）**在运行时挂载进来。这样做的收益是：

- 镜像保持 3~5GB，**拉取快，弹性伸缩才可能成立**；
- 同一份镜像可以服务不同的模型：`docker run -v /data/models/Qwen2.5-7B:/models/LLM ...` 换个路径就是另一个模型；
- 更新权重不需要重新构建，**回滚也只需要换挂载路径**。

（一个例外：如果目标环境**完全没有外网也没有共享存储**（比如交付给客户的一台离线内网一体机、边缘设备），才会把权重一并打进镜像做成单文件交付物。线上服务不要这么做。）

### 4.3 主程序：把上一节的服务接进来

下面是这份模板的核心代码 `app/main.py`。它在上一篇 FastAPI 服务的基础上补了三样东西：**配置外置**（全部从环境变量读）、**健康检查**（区分"活着"和"就绪"）、**Prometheus 埋点**（下一节监控要用，提前埋好）。

```python
# app/main.py
"""
大模型推理服务入口：FastAPI + vLLM OpenAI 兼容接口
相比上一篇的 demo，这里补齐了三件生产必需的事：
  1. 配置全部来源于环境变量（12-factor，不硬编码）
  2. /healthz（活着）与 /readyz（就绪）分离 —— 模型加载期间不应被判死
  3. Prometheus 埋点：请求数、延迟直这条线，下一篇的监控直接复用
"""
import os
import time
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from prometheus_client import (
    Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
)

# ---- 1. 指标定义：全局单例，进程内累积 ----
REQ_COUNTER = Counter(
    "llm_requests_total",              # 指标名（Prometheus 里用来查询）
    "Total LLM requests",              # 说明文字
    ["model", "status"],               # 标签(label)：支持多维聚合
)
# Histogram 会自动分桶，可以用来算 P50/P95/P99 —— 这点很关键，
# 只存一个平均值的话，你永远看不到长尾请求有多惨
LATENCY = Histogram(
    "llm_request_latency_seconds",
    "Request latency in seconds",
    ["model"],
    buckets=(0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0),
)
TOKENS = Histogram(
    "llm_output_tokens", "Generated tokens per request", ["model"],
    buckets=(16, 32, 64, 128, 256, 512, 1024, 2048, float("inf")),
)

MODEL_PATH = os.getenv("MODEL_PATH", "/models/LLM")
MODEL_NAME = os.getenv("MODEL_NAME", "qwen2.5-7b-instruct")
# 取 float 时注意：环境变量永远是字符串，必须显式转换
GPU_UTIL   = float(os.getenv("GPU_MEMORY_UTILIZATION", "0.90"))
MAX_LEN    = int(os.getenv("MAX_MODEL_LEN", "8192"))

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    # 结构化日志：带 request_id，下一篇讲全链路追踪时会用上
    format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
)

engine = None  # 全局引擎句柄，启动时赋值


@asynccontextmanager
async def lifespan(app: FastAPI):
    """服务生命周期钩子：启动时加载模型，退出时清理。
    把加载放在这里而不是全局作用域，是为了让 HTTP 端口尽快监听上，
    这样 /healthz 在模型还在加载时就能返回 200，不会被容器判死。"""
    global engine
    from vllm import LLM, SamplingParams  # 延迟导入：读 vLLM 要几秒，推迟到这里
    logging.info("loading model from %s ...", MODEL_PATH)
    t0 = time.time()
    engine = LLM(
        model=MODEL_PATH,
        tokenizer=MODEL_PATH,       # tokenizer 也走本地路径，避免联网下载
        gpu_memory_utilization=GPU_UTIL,
        max_model_len=MAX_LEN,
        dtype="bfloat16",           # A100/H100 建议 bf16；T4/V100 要改成 float16
        enforce_eager=False,        # False=启用 CUDA graph，吞吐更高、显存略增
    )
    logging.info("model loaded in %.1fs", time.time() - t0)
    yield
    logging.info("shutting down")


app = FastAPI(title="LLM Serving", lifespan=lifespan)


@app.get("/healthz")
def healthz():
    """存活探针：只要进程还在就返回 200。
    注意这里绝不能去检查 model 是否加载完！"""
    return {"status": "alive"}


@app.get("/readyz")
def readyz():
    """就绪探针：模型加载完才返回 200，否则 503。
    K8s 的 readinessProbe 应该打这个接口，这样加载期间不会接流量。"""
    if engine is None:
        return JSONResponse({"status": "loading"}, status_code=503)
    return {"status": "ready", "model": MODEL_NAME}


@app.get("/metrics")
def metrics():
    """Prometheus 抓取端点。下一篇的监控全靠它。
    生产上建议单独开一个端口，不对外暴露业务端口上的 /metrics。"""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/v1/generate")
async def generate(request: Request):
    body = await request.json()
    prompt = body.get("prompt", "")
    max_tokens = int(body.get("max_tokens", 256))
    start = time.time()
    try:
        from vllm import SamplingParams
        out = engine.generate([prompt], SamplingParams(max_tokens=max_tokens))[0]
        text = out.outputs[0].text
        n_tokens = len(out.outputs[0].token_ids)
        # observe 才会写入 histogram；顺便 depth 地把 token 数也记下来，
        # 成本分析（token 单价 × token 数）就靠它
        LATENCY.labels(MODEL_NAME).observe(time.time() - start)
        TOKENS.labels(MODEL_NAME).observe(n_tokens)
        REQ_COUNTER.labels(MODEL_NAME, "ok").inc()
        return {"text": text, "tokens": n_tokens,
                "latency_ms": round((time.time() - start) * 1000, 1)}
    except Exception as e:                      # 异常也要计数，否则成功率算不准
        REQ_COUNTER.labels(MODEL_NAME, "error").inc()
        logging.exception("generate failed")
        return JSONResponse({"error": str(e)}, status_code=500)


from fastapi import Response  # 放在末尾避免上面的 Response 未定义（真实项目请放文件头）
```

要注意上面 `@app.get("/metrics")` 用到 `Response`，实际项目中请把 `from fastapi import Response` 放在文件顶部的导入区，这里为了突出"逐步补齐"的讲解顺序放在了末尾——这是刻意保留的、你需要修掉的一处小瑕疵。

### 4.4 requirements.txt：版本必须钉死

大模型的依赖如果不钉版本，今天能构建的镜像下个月就构建不出同样的东西了。

```txt
# 推理引擎：版本与 CUDA / torch 强相关，务必三者一起锁定
torch==2.4.0
vllm==0.6.3.post1

# 服务框架
fastapi==0.115.2
uvicorn[standard]==0.30.6
pydantic==2.9.2
pydantic-settings==2.5.2

# 可观测性（下一篇要用）
prometheus-client==0.20.0

# 注意：不要写 transformers==latest，也不要不写版本。
# 每一行版本号都应来自一次"真的跑通过"的组合，而不是 pip 猜出来的。
```

### 4.5 Dockerfile：生产可用版

```dockerfile
# ===================== 第一阶段：依赖安装 =====================
# 选 runtime 而非 devel：推理不需要 nvcc，体积直接省 2~3GB
FROM nvidia/cuda:12.1.1-runtime-ubuntu22.04 AS builder

# 时区与编码：不加这两行，容器里会出现中文乱码 + 日志时间差 8 小时
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.10 python3-pip python3-venv \
        tzdata curl ca-certificates \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    # rm 必须跟在同一条 RUN 里：Docker 是层式文件系统，
    # 下一条 RUN 里再删，上一层的 apt 缓存已经永远留在镜像里了
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .

# pip 装依赖放在最前面：requirements.txt 变动频率远低于源码，
# 改 py 文件时这一层直接命中缓存，不用重装几 GB 的 torch
# --no-cache-dir：pip 缓存对镜像毫无用处，还会白白多几百 MB
RUN python3 -m pip install --no-cache-dir --upgrade pip \
    && python3 -m pip install --no-cache-dir -r requirements.txt

# ===================== 第二阶段：运行 =====================
# 这里刻意换成不带 CUDA 的小镜像 + 从 builder 拷贝 site-packages，
# 好处是最终镜像里没有 pip、没有 .h 头文件、没有编译中间产物
FROM ubuntu:22.04

ENV TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TOKENIZERS_PARALLELISM=false \
    HF_HOME=/cache/huggingface \
    HF_HUB_OFFLINE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.10 libgl1 libglib2.0-0 tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/lib/python3/dist-packages /usr/lib/python3/dist-packages
COPY --from=builder /usr/local/lib/python3.10/dist-packages \
                    /usr/local/lib/python3.10/dist-packages
COPY --from=builder /usr/local/bin                 /usr/local/bin

WORKDIR /app
COPY app/ ./app/

# 这两个目录是给宿主机挂载用的：前者挂权重，后者挂 HF 缓存
# VOLUME 在这里的作用更像"给使用者的强制提醒"
VOLUME ["/models", "/cache"]

EXPOSE 8000

# 健康检查：给足 start_period，因为大模型冷启动可能要几分钟
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD curl -f http://localhost:8000/healthz || exit 1

CMD ["python3", "-m", "uvicorn", "app.main:app", \
     "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

关于这份 Dockerfile 有几个决策值得说明：

- **`--workers 1` 必须是 1。** vLLM/transformers 多进程 worker 会各自加载一份完整权重，8 workers × 15GB 会直接 OOM。要并发，靠 vLLM 内部的连续批处理，以及靠**多副本容器**（K8s 扩副本），不是靠 uvicorn 多 worker。
- **`HF_HUB_OFFLINE=1` 是个保险栓。** 生产环境容器不该有外网访问权限。一旦配置了（配合 `--network=none` 或不出网的安全组），任何试图联网下载 tokenizer 的行为会立刻失败并暴露问题，而不是悄悄拖垮启动速度。
- **`HF_HOME=/cache/huggingface`**：把 HF 的默认缓存从 `~/.cache` 挪到一个明确会被挂载的目录，这样 tokenizer 缓存能跨容器复用，也方便你把镜像体积控制住。

### 4.6 .dockerignore：一个能省你十分钟的文件

没有 `.dockerignore` 时，Docker 会把当前目录的**所有文件**打包成"构建上下文"发给守护进程。如果你的项目根目录里躺着一个 `data/` 或 `.venv/`，构建第一步就会卡住几分钟。

```dockerignore
# Python 缓存与虚拟环境：体积大户，且和容器内环境不兼容
__pycache__/
*.py[cod]
.venv/
venv/
env/

# 本地数据与模型：这些应该用 volume 挂载，绝不能进镜像
models/
data/
*.safetensors
*.bin
*.gguf

# 版本控制与编辑器
.git/
.gitignore
.vscode/
.idea/

# 密钥和配置：进了镜像就等于泄露 —— 换成 .env 运行时注入或 Secret
.env
*.pem
*.key
credentials.json

# 文档与测试（构建不需要）
*.md
tests/
Dockerfile*
docker-compose*.yml
```

### 4.7 .env.example：配置契约

```bash
# ===== 模型相关 =====
MODEL_PATH=/models/Qwen2.5-7B-Instruct
MODEL_NAME=qwen2.5-7b-instruct
MAX_MODEL_LEN=8192
GPU_MEMORY_UTILIZATION=0.90
DTYPE=bfloat16

# ===== 服务相关 =====
PORT=8000
LOG_LEVEL=INFO
WORKERS=1

# ===== 外部依赖（compose 里用服务名互访） =====
REDIS_URL=redis://redis:6379/0
VECTORDB_HOST=milvus

# ===== 密钥：真实值写在 .env 里且 .gitignore，这里只给键名 =====
# HF_TOKEN=
# API_KEY=
```

这个文件的作用是**声明"这个服务需要哪些配置"**，是团队协作的契约。

---

## 五、构建与运行：完整命令与预期输出

上一节的文件准备就绪后，真正上手就两条命令。

### 5.1 docker build

```bash
cd llm-serving

docker build -t registry.example.com/ai/llm-serving:1.0.0 .

# 预期输出的尾巴（真实输出会有大量中间层日志）：
# => [builder 2/7] RUN apt-get update && apt-get install -y ...   12.4s
# => [builder 3/7] WORKDIR /app                                    0.0s
# => [builder 4/7] COPY requirements.txt .                         0.1s
# => [builder 5/7] RUN python3 -m pip install ...                 183.6s   ← torch/vllm 耗时最大
# => [stage-1 6/7] COPY --from=builder /usr/local/lib/...          8.2s
# => [stage-1 7/7] COPY app/ ./app/                                0.1s
# => exporting to image                                            6.7s
# => => writing image sha256:9b3f2c1e7a44...
# Successfully tagged registry.example.com/ai/llm-serving:1.0.0

docker images registry.example.com/ai/llm-serving
# REPOSITORY                              TAG      IMAGE ID       CREATED         SIZE
# registry.example.com/ai/llm-serving     1.0.0    9b3f2c1e7a44   10 seconds ago  6.2GB
```

第一次构建通常要 5~15 分钟，主要时间花在装 torch + vLLM（约 3~5GB 依赖）。**第二次改一行 Python 代码再构建，应该只需要几秒钟**——如果你发现还是几分钟，说明 `COPY` 顺序写错了，Dockerfile 第 4 层缓存没命中，请回到 4.5 节检查你是不是把 `COPY app/` 写到了 `RUN pip install` 前面。

### 5.2 docker run

```bash
docker run -d \
  --name llm-api \
  --gpus all \
  --shm-size=16g \
  -p 8080:8000 \
  -v /data/llm/hub/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct:ro \
  -v /data/llm/cache:/cache \
  --env-file .env \
  --restart unless-stopped \
  --health-cmd "curl -f http://localhost:8000/healthz || exit 1" \
  --health-start-period 300s \
  registry.example.com/ai/llm-serving:1.0.0

# 返回一串容器 ID，例如：3a7c1f8e2b9045d6a1ff04c3b2e8d9f00c1b2a3d4e5f60718293a4b5c6d7e8f90
```

每个参数的意义逐条说明：

| 参数 | 为什么必须 |
|---|---|
| `--gpus all` | 没有它容器看不见显卡，`torch.cuda.is_available()` 返回 False |
| `--shm-size=16g` | 默认 64MB，多卡/多进程推理 NCCL 通信会崩。**单卡也可加，成本极低** |
| `-p 8080:8000` | 宿主机 8080 → 容器 8000，避免和宿主机已有服务冲突 |
| `-v ...:/models/...:ro` | `:ro` 表示只读挂载，防止服务意外改写权重文件 |
| `-v /data/llm/cache:/cache` | 对应 `HF_HOME`，让 tokenizer 缓存跨容器复用 |
| `--env-file .env` | 配置外置；`.env` 本身写进 `.gitignore` 和 `.dockerignore` |
| `--restart unless-stopped` | 机器重启后自动拉起（K8s 环境下由控制器负责，不需要） |
| `--health-start-period 300s` | 给模型加载留时间，否则启动 90 秒内就被判 unhealthy 然后被杀 |

验证三连：

```bash
# 1. 看容器状态（HEALTH 列要从 starting 变成 healthy）
docker ps
# CONTAINER ID   IMAGE                          STATUS                    PORTS
# 3a7c1f8e2b90   registry.example.com/ai/...    Up 2 minutes (healthy)    0.0.0.0:8080->8000/tcp

# 2. 看启动日志，确认模型加载完成
docker logs -f llm-api
# INFO:     Started server process [1]
# INFO:     Waiting for application startup.
# INFO:     loading model from /models/Qwen2.5-7B-Instruct ...
# INFO  Using model weights format ['*.safetensors']
# INFO:     Processed prompts: 100%|██████████| 1/1 [00:03<00:00,  3.42it/s, est. speed input: 12.3 toks/s, output: 68.5 toks/s]
# INFO:     model loaded in 41.3s
# INFO:     Application startup complete.
# INFO:     Uvicorn running on http://0.0.0.0:8000

# 3. 实际发一个请求
curl -s http://localhost:8080/v1/generate \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"用一句话解释什么是容器化","max_tokens":128}' | python3 -m json.tool
# {
#     "text": "容器化是把应用程序及其全部依赖（库、配置、运行时）打包成一个标准化、\n可移植的镜像，从而保证它在任何环境下都以相同方式运行。",
#     "tokens": 41,
#     "latency_ms": 1187.4
# }

# 4. 确认 GPU 真的在用
docker exec llm-api nvidia-smi
# 会输出和宿主机一致的显卡信息， Processes 一栏里能看到 python3 进程占用几十 GB 显存
```

如果第 3 步返回了正常文本、第 4 步能看到显存占用，恭喜——**你的大模型服务已经是一个可交付制品了**，可以给任何人，只要他有一台装了 docker 和 nvidia-toolkit 的 GPU 机器。

---

## 六、docker-compose：一次拉起整个系统

真实的 LLM 应用从来不是一个容器。以 RAG 问答系统为例，一次完整请求至少涉及：网关/业务 API、推理引擎、向量库、缓存，还可能有 trace 收集器。手工 `docker run` 四个容器并配好网络既不优雅也不可复现。

### 6.1 编排要解决的三件事

1. **启动顺序 vs 依赖就绪**：注意这两个不是一回事。`depends_on` 默认只保证"容器启动了"，不保证"服务可用了"。vLLM 起来要 40 秒，这期间 API 调它会全部失败。所以必须用 `condition: service_healthy` 配合健康检查。
2. **网络与服务发现**：compose 会为整个项目建一个 bridge 网络，容器间用**服务名**互访。你在业务容器里写的连接串是 `redis://redis:6379` 而不是 `redis://localhost:6379`（这一点本地开发和容器里不一样，最容易出错）。
3. **配置集中**：每个服务的环境变量、挂载、端口都写在同一个 YAML 里，谁改了什么一目了然，也能进 Git。

### 6.2 完整的 compose 文件

```yaml
# docker-compose.yml
name: llm-rag-stack

services:
  # ---------- 1. 推理引擎 ----------
  vllm:
    # 真实项目里，如果不需要自定义逻辑，可以直接用官方镜像省掉构建：
    # image: vllm/vllm-openai:v0.6.3.post1
    image: registry.example.com/ai/llm-serving:1.0.0
    command: >
      python3 -m vllm.entrypoints.openai.api_server
      --model /models/Qwen2.5-7B-Instruct
      --host 0.0.0.0 --port 8000
      --dtype bfloat16
      --max-model-len 8192
      --gpu-memory-utilization 0.85
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1                 # 需求 1 张卡
              capabilities: [gpu]
    volumes:
      # 权重只读挂载；多个服务共享同一份权重也不会重复占用磁盘
      - ${MODEL_DIR}:/models/Qwen2.5-7B-Instruct:ro
      # HF 缓存做成命名卷：跨容器复用 tokenizer，避免每次重新"下载"
      - hf_cache:/cache
    environment:
      - HF_HOME=/cache/huggingface
      - HF_HUB_OFFLINE=1
      - TZ=Asia/Shanghai
    # 共享内存：多卡 NCCL 的救命参数（cli 里没有 deploy 时用 shm_size: '16gb'）
    shm_size: '16gb'
    # 健康检查必须是"业务可用"级别的探针，不能只探 /healthz
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 20s
      timeout: 5s
      retries: 20
      start_period: 300s               # ← 模型加载窗口，没有它必定 flapping
    restart: unless-stopped

  # ---------- 2. 业务 API（含 RAG 逻辑） ----------
  api:
    build: .
    ports:
      - "8080:8000"
    environment:
      - LLM_BASE_URL=http://vllm:8000/v1   # ← 服务名即域名
      - REDIS_URL=redis://redis:6379/0
      - MILVUS_HOST=milvus
      - MILVUS_PORT=19530
      - API_KEY=${API_KEY}                 # 从 .env 读，不写死在文件里
      - TZ=Asia/Shanghai
    volumes:
      - ./app:/app/app                     # 开发期热更新；生产请删掉这行
    depends_on:
      vllm:
        condition: service_healthy         # ← 关键：等推理引擎真正就绪
      redis:
        condition: service_started
      milvus:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    restart: unless-stopped

  # ---------- 3. 缓存：存问答对 / 会话历史 / embedding 结果 ----------
  redis:
    image: redis:7-alpine                  # alpine 变体极小，约 40MB
    command: redis-server --maxmemory 2gb --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    restart: unless-stopped

  # ---------- 4. 向量库 ----------
  milvus:
    image: milvusdb/milvus:v2.4.13
    command: ["milvus", "run", "standalone"]
    environment:
      - ETCD_USE_EMBED=true
      - COMMON_SECURITY_AUTHORIZATIONENABLED=false
    volumes:
      - milvus_data:/var/lib/milvus
    ports:
      - "19530:19530"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9091/healthz"]
      interval: 30s
      timeout: 20s
      retries: 3
      start_period: 90s
    restart: unless-stopped

volumes:
  hf_cache:
  redis_data:
  milvus_data:
```

### 6.3 运行与管理

```bash
# 语法检查：写错缩进或变量名时 docker compose 往往不报错，只是行为不对，
# 所以用 config 先 dump 出解析后的真实配置来核对
docker compose config

# 后台拉起全部服务
docker compose up -d
# [+] Running 6/6
#  ✔ Network llm-rag-stack_default     Created
#  ✔ Volume "llm-rag-stack_milvus_data" Created
#  ✔ Container redis                   Started
#  ✔ Container milvus                  Healthy
#  ✔ Container vllm                    Healthy      ← api 在它 health 之后才启动
#  ✔ Container api                     Started

docker compose ps
# NAME      SERVICE   STATUS                  PORTS
# api       api       Up (healthy)            0.0.0.0:8080->8000/tcp
# milvus    milvus    Up (healthy)            0.0.0.0:19530->19530/tcp
# redis     redis     Up                      6379/tcp
# vllm      vllm      Up (healthy)            8000/tcp

# 单独看某个服务的日志
docker compose logs -f vllm

# 重启（改了 compose 文件后）
docker compose up -d --force-recreate api

# 彻底清理（注意 -v 会删掉命名卷，默认不删）
docker compose down
```

一个常见疑问：**`depends_on` 能不能替代健康检查？** 不能。默认的 `depends_on` 是"容器进程起来了就算数"，而 vLLM 容器进程起来到模型加载完可能差 40 秒。上面这套 `condition: service_healthy` + `start_period` 的组合才是正确写法，这也是 compose 新手最常踩的坑。

---

## 七、镜像瘦身：从 22GB 到 6GB 的四个杠杆

大模型镜像天然就大（光 torch+CUDA 就 4~6GB），但"大"和"失控地大"是两回事。下面四个杠杆按性价比排序。

### 7.1 杠杆一：层顺序（改代码后能不能秒构建）

Docker 构建缓存的规则是：**某条指令的内容或其输入文件变了，从这一层起后面全部失效**。所以要把**变化频率低、耗时长的层放前面**：

```
正确顺序（变动频率从低到高）：
  ① FROM / ENV / apt install     ← 几个月变一次
  ② COPY requirements.txt         ← 几周变一次
  ③ RUN pip install               ← 跟上一条同步变，耗时最长，必须靠前
  ④ COPY app/                     ← 每次改代码都变
  ⑤ CMD                           ← 几乎不变，但放最后也没成本

错误示例：COPY . .  然后再 pip install
  → 任何一次改 README，都会让几 GB 的 pip 层完全重建
```

另一个等价技巧：**先 `COPY requirements.txt` 单独一层，再 `COPY` 源码**。就是 4.5 节那份 Dockerfile 的写法。

### 7.2 杠杆二：多阶段构建

第二节图里那个"可写层"机制有个副作用：你在某层删了文件，那文件在下层还在。所以 `rm -rf` 必须和下载/安装写在**同一条 RUN** 里（用 `&&` 连接）：

```dockerfile
# ❌ 错误：两条 RUN，删掉的文件仍留在上一层，镜像一点没小
RUN apt-get update && apt-get install -y build-essential
RUN rm -rf /var/lib/apt/lists/*

# ✅ 正确：同一层里完成"安装 → 用完即弃"
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && pip install vllm \
    && apt-get purge -y build-essential \      # 编译完就不再需要编译器
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /root/.cache/pip
```

这就是典型的"多阶段思想"：**构建期需要的东西（编译器、头文件、pip 缓存）不应该出现在运行期镜像里**。真正的多阶段构建（4.5 节用的 `AS builder` + `COPY --from`）把这个思想推到极致：第二阶段甚至连 Python 都不重装，直接把第一阶段的 `dist-packages` 拷过来。

### 7.3 杠杆三：基础镜像选 slim / alpine 的取舍

| 基础镜像 | 体积 | glibc/依赖 | 适合场景 |
|---|---|---|---|
| `ubuntu:22.04` | ~78MB | glibc，兼容性最好 | **推荐**：PyTorch 官方 wheel 就是按 glibc 编的 |
| `python:3.10-slim` | ~45MB | glibc，缺一些系统库 | 推荐：体积小，但要手动补 `libgl1` 等 |
| `python:3.10-alpine` | ~18MB | **musl libc** | ❌ 不要用：PyTorch/vLLM 的预编译 wheel 在 musl 下装不上，会从源码编译，编译几小时还可能失败 |
| `nvidia/cuda:...-devel-ubuntu22.04` | ~5GB | 含 nvcc | 只有需要容器内编译时才用 |

**alpine 是个陷阱**：它看着最小，但大模型生态几乎全都依赖 glibc，用 alpine 要么装不上 wheel，要么得自己编译 torch。省几十 MB 换几小时编译时间，完全不划算。

### 7.4 杠杆四：.dockerignore（已在 4.6 给出）

它不影响最终镜像大小，但**直接影响构建速度**，因为它决定"构建上下文"有多大。一个项目根目录里躺着 30GB 的数据集，`docker build` 第一行的 `Sending build context to Docker daemon` 就会让你以为卡死了。

### 7.5 效果对比：某真实项目

| 优化动作 | 镜像体积 | 构建时间（改一行代码） | Pull 时间（千兆内网） |
|---|---|---|---|
| 未优化：复制整个目录 + 权重 COPY 进镜像 + devel 基础镜像 | 22.4 GB | 8 分 20 秒 | 约 4 分钟 |
| 权重改为 volume 挂载 | 7.1 GB | 7 分 50 秒 | 约 75 秒 |
| `devel` → `runtime`，多阶段构建 | 5.6 GB | 7 分 30 秒 | 约 60 秒 |
| 整理层顺序 + 补 `.dockerignore` | 5.6 GB | **6 秒** | 约 60 秒 |
| 清理 apt / pip 缓存与编译中间产物、`--no-cache-dir` | 5.1 GB | 6 秒 | 约 55 秒 |

看这两个最右侧的对比结果：**调整层顺序带来的收益（8 分钟 → 6 秒）远大于所有体积优化的总和**。这是因为开发期你每天要构建几十次，而 pull 只在部署时发生。**先优化"改一行代码的重构速度"，再优化体积**——这个优先级很多团队搞反了。

---

## 八、环境变量与配置管理：12-factor 在大模型服务里的落地

### 8.1 原则：一份代码，多份配置

"12-factor App"里那条关于配置的规则，放到大模型服务上尤其贴切：

> **配置应该严格从代码中分离，并存储在环境变量中。**

原因很实际：同一个镜像要跑在"开发（用 0.5B 小模型、fp16、单卡）"、"测试（用 7B、bf16）"、"生产（用 72B、8 卡、开 CUDA graph）"三种环境里。**如果把这些差异写进代码，你就得维护三份代码；写进环境变量，你只需要三份 `.env`。**

配置大致分三类，处理方式不同：

| 配置类型 | 例子 | 放哪 | 能不能进 Git |
|---|---|---|---|
| **非敏感配置** | `MAX_MODEL_LEN`、`GPU_MEMORY_UTILIZATION`、`LOG_LEVEL` | `.env` 或 ConfigMap | ✅ 可以，推荐差异配置也进 Git（环境可读性） |
| **敏感配置** | `API_KEY`、`HF_TOKEN`、数据库密码 | `.env`（本地）/ Secret（K8s） | ❌ 绝对不行 |
| **运行时才知道的** | Pod IP、副本序号、节点名 | Downward API / K8s 自动注入 | — |

### 8.2 代码里怎么写才不会乱

散落在代码各处的 `os.getenv("XXX")` 是维护噩梦。正确做法是**集中一处声明，做类型校验，缺失即快速失败**（fail fast）：

```python
# app/settings.py
"""配置集中管理：一处声明、一处校验、一处导出。
这样别人看这个文件就知道"这个服务需要哪些配置"，
而不是满仓库 grep os.getenv。"""
from functools import lru_cache
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # env_prefix 让环境变量命名更清晰：LLM_MODEL_PATH 而不是裸 MODEL_PATH，
    # 避免和其他进程的环境变量撞名
    model_config = SettingsConfigDict(
        env_file=".env", env_prefix="LLM_", case_sensitive=False
    )

    # ---- 模型配置 ----
    model_path: str = Field(..., description="模型权重绝对路径（容器内路径）")
    model_name: str = "qwen2.5-7b-instruct"
    max_model_len: int = 8192
    gpu_memory_utilization: float = Field(0.90, ge=0.1, le=0.95)  # 超过 0.95 极易 OOM
    dtype: str = "bfloat16"

    # ---- 服务配置 ----
    port: int = 8000
    log_level: str = "INFO"
    workers: int = 1

    # ---- 外部依赖 ----
    redis_url: str = "redis://localhost:6379/0"
    milvus_host: str = "localhost"

    # ---- 敏感配置：Optional 但缺失会让某些功能不可用 ----
    api_key: str | None = None
    hf_token: str | None = None


@lru_cache
def get_settings() -> Settings:
    """缓存单例：避免每次请求都重新解析一遍环境变量。
    注意这里用了 @lru_cache 而不是普通全局变量的理由：测试时方便
    get_settings.cache_clear() 之后注入新的环境变量。"""
    s = Settings()          # 缺失必填项时这里直接抛 ValidationError，
                            # 服务启动即失败 —— 这正是我们要的 fail fast
    if s.dtype == "bfloat16" and s.gpu_memory_utilization > 0.95:
        raise ValueError("显存占用率过高会在加载 KV cache 时 OOM，请调低")
    return s
```

然后在 `main.py` 里：

```python
from app.settings import get_settings
cfg = get_settings()
MODEL_PATH = cfg.model_path      # 不再是裸 os.getenv
```

**为什么值得多写这三十行？** 因为大模型服务的配置项越来越多（8 卡并行策略、量化方式、LoRA 热插拔、speculative decoding 参数…），靠人脑记住"这次忘了配 `VLLM_WORKER_MULTIPROC_METHOD` 会怎样"是不可能的。把配置变成一份有类型、有默认值、有校验的 **schema**，是这个复杂度的唯一解药。

### 8.3 四条不该破的规矩

1. **密钥绝不进镜像层。** 即使你在 Dockerfile 里 `ENV API_KEY=xxx` 然后下一条 RUN 里 unset 掉，那个值仍然留在镜像层的元数据里，`docker history` 一查就出来。用 `--env-file` 或 K8s Secret。
2. **`.env` 必须同时写进 `.gitignore` 和 `.dockerignore`**，仓库里只留 `.env.example`。
3. **不要把 `.env` 挂载成容器内的固定路径又设为只读**：不同环境要能替换。compose 里用 `env_file:` 而不是 `-v .env:/app/.env`。
4. **生产环境给容器加 `--read-only`**（只放行 `/tmp` 和日志目录的可写挂载），能挡掉一大类"容器里被人写了个文件"的问题。

---

## 九、CI/CD：从"提交代码"到"线上跑新镜像"

手写 `docker build` + `docker push` + 上服务器 `docker pull` 这套流程，第三次就会出错：忘记打新 tag、tag 用了 `latest` 导致不知道跑的是哪个版本、某次忘了 push 结果线上拉的是上周的镜像。所以必须自动化。

一条最小可用的流水线长这样：

```
  git push (feature 分支)
        │
        ▼
  ┌───────────────────────────────────────┐
  │ Stage 1: Lint & Test（快，秒级~分钟）  │
  │  ruff + pytest + 小模型冒烟测试        │
  └───────────┬───────────────────────────┘
              │ 全绿才继续
              ▼
  ┌───────────────────────────────────────┐
  │ Stage 2: Build Image                  │
  │  docker build -t $REG/repo:$GIT_SHA   │  ← 用 commit hash 当 tag，
  │  耗时最长的阶段，通常 5-15 分钟      │     保证每个 tag 唯一可追
  └───────────┬───────────────────────────┘
              ▼
  ┌───────────────────────────────────────┐
  │ Stage 3: Smoke Test（最关键的一步）    │
  │  docker run 起来 → curl /healthz      │ ← 不做这步，坏镜像会直接上产
  │  → 发一个真实 prompt 检查输出不为空    │
  └───────────┬───────────────────────────┘
              ▼
  ┌───────────────────────────────────────┐
  │ Stage 4: Scan & Push                  │
  │  trivy 扫描漏洞 → push 到私有仓库      │
  └───────────┬───────────────────────────┘
              ▼
  ┌───────────────────────────────────────┐
  │ Stage 5: Deploy                       │
  │  kubectl set image ...=$REG:...:$SHA  │ ← YAML 里的 tag 用变量替换，
  │  或 ArgoCD 监听 Git 自动同步 (GitOps) │     永远别手改 YAML
  └───────────────────────────────────────┘
```

三个容易被忽略但极其重要的实践：

- **用 Git SHA 而不是 `latest` 做 tag。** `latest` 的语义是"最后一个被推上来的镜像"，使用它等于放弃版本控制。出事故时你要能回答"线上现在跑的是哪次提交"，用 SHA 一秒回答，用 `latest` 只能靠猜。
- **Stage 3 的冒烟测试必须有。** 大模型服务有个特殊风险：镜像能构建成功不代表能跑起来（比如 CUDA 版本和宿主驱动不匹配要运行时才暴露、 weight 路径挂载错了加载失败）。带着真实 prompt 跑一次，是唯一能拦住这类问题的手段。
- **构建机要有 GPU 才能做真正的冒烟测试**；如果 CI runner 是 CPU 机器，就把 Stage 3 降级为"能启动 + 能进 Python + 能 import vllm"，GPU 相关的放到部署后的健康检查里兜底。

---

## 十、Kubernetes 入门：从"跑起来"到"稳定地跑"

### 10.1 为什么有了 Docker 还需要 K8s

Docker 解决了"单个容器怎么打包和启动"，但不解决：

- 容器挂了谁把它拉起来？（**自愈**）
- 流量涨了谁多开几个？（**扩缩容**）
- 新版本怎么灰度、出问题怎么回滚？（**发布策略**）
- 这台 GPU 满了，新实例应该去哪台机器？（**调度**）
- 外部流量怎么进到这一堆会漂移的容器里？（**服务发现与入口**）

K8s 的答案是 **声明式 API**：你只描述"我想要什么状态"（3 个副本、每张卡一份、用这个镜像），控制器持续比对实际状态和期望状态并自动纠正。你不再"操作机器"，而是"声明期望"。

### 10.2 四个核心对象，一张图看懂

```
                     Internet
                        │
                        ▼
        ┌───────────────────────────────┐
        │  Ingress                       │ ← 七层路由 / TLS 证书 / 域名
        │  (nginx-ingress controller)    │   "llm.example.com/api → api-svc"
        └──────────────┬────────────────┘
                       ▼
        ┌───────────────────────────────┐
        │  Service: api-svc (ClusterIP)  │ ← 稳定的虚拟 IP + DNS 名 + 负载均衡
        │  永远不变，Pod 怎么重建都不影响  │   屏蔽 Pod IP 的漂移
        └──────────────┬────────────────┘
                       │ 按标签选择器转发
       ┌───────────────┼───────────────┐
       ▼               ▼               ▼
   ┌────────┐     ┌────────┐     ┌────────┐
   │ Pod 1  │     │ Pod 2  │     │ Pod 3  │   ← Deployment 管理 3 个副本
   │ (GPU)  │     │ (GPU)  │     │ (GPU)  │      挂了自动重建，滚动更新逐个替换
   └────────┘     └────────┘     └────────┘
       ▲
       │ 由 Deployment 维护 replicas=3
   ┌────┴─────────────────────────────────┐
   │  Deployment: api                      │
   │  期望状态：image=...:a1b2c3d, 副本 3  │
   └───────────────────────────────────────┘
```

一句话记住它们的关系：**Deployment 管 Pod 的副本与版本，Service 给这堆会漂移的 Pod 一个稳定入口，Ingress 把外部流量引到 Service。**

### 10.3 GPU Pod 的完整清单

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-api
  namespace: llm-prod
spec:
  replicas: 3                          # HPA 会动态改这个值，这里写初始值
  revisionHistoryLimit: 5              # 保留 5 个历史版本，方便 kubectl rollout undo
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1                      # 更新期间最多多出 1 个 Pod（省一张卡）
      maxUnavailable: 0                # 更新期间一个都不能少 → 零停机更新
  selector:
    matchLabels: { app: llm-api }      # 必须与下面 template.labels 一致，否则不生效
  template:
    metadata:
      labels: { app: llm-api }
    spec:
      # ---- GPU 调度三件套 ----
      nodeSelector:
        nvidia.com/gpu.product: NVIDIA-A100-SXM4-80GB   # 只调度到特定型号（需节点有此 label）
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"         # GPU 节点通常打了污点，得显式容忍才能调度上去
      containers:
        - name: llm
          image: registry.example.com/ai/llm-serving:a1b2c3d   # ← Git SHA tag
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              nvidia.com/gpu: 1        # ← 声明"我要一张整卡"，这是 K8s 分配 GPU 的方式
              memory: "32Gi"
              cpu: "8"
            limits:
              nvidia.com/gpu: 1        # GPU 的 request 和 limit 必须相等且为整数
              memory: "64Gi"
              cpu: "16"                # requests.cpu 别设太小：加载模型时 CPU 也很忙
          ports:
            - containerPort: 8000
          env:
            - name: MODEL_PATH
              value: "/models/Qwen2.5-7B-Instruct"
            - name: HF_HOME
              value: "/cache/huggingface"
            - name: MAX_MODEL_LEN
              valueFrom:
                configMapKeyRef:       # ← 非敏感配置放 ConfigMap
                  name: llm-config
                  key: maxModelLen
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:         # ← 敏感配置放 Secret，二者写法几乎一样
                  name: llm-secret
                  key: hfToken
          volumeMounts:
            - name: models
              mountPath: /models
              readOnly: true          # 只读，防止线上被改写
            - name: cache
              mountPath: /cache
            - name: dshm
              mountPath: /dev/shm     # ← 覆盖默认的 64MB，多卡推理必需
          # ---- 三个探针分工不同 ----
          startupProbe:               # 启动探针：给它 10 分钟慢慢加载，期间另外两个不生效
            httpGet: { path: /healthz, port: 8000 }
            failureThreshold: 60      # 60 × 10s = 最多等 10 分钟
            periodSeconds: 10
          readinessProbe:             # 就绪探针：不通过则从 Service 摘掉，不接流量
            httpGet: { path: /readyz, port: 8000 }
            periodSeconds: 10
            timeoutSeconds: 3
          livenessProbe:              # 存活探针：失败则重启容器（慎用！见第十二节）
            httpGet: { path: /healthz, port: 8000 }
            periodSeconds: 30
            timeoutSeconds: 3
            failureThreshold: 3
      volumes:
        # 共享权重：ReadOnlyMany 的 PVC，或对象存储 CSI
        - name: models
          persistentVolumeClaim: { claimName: models-pvc }
        - name: cache
          persistentVolumeClaim: { claimName: hf-cache-pvc }
        # /dev/shm 加大到 16GB
        - name: dshm
          emptyDir: { medium: Memory, sizeLimit: 16Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: llm-api-svc
  namespace: llm-prod
spec:
  type: ClusterIP                      # 集群内访问；外面访问靠 Ingress
  selector: { app: llm-api }           # ← 把流量转发到带这个 label 的 Pod
  ports:
    - port: 80
      targetPort: 8000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: llm-api-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"   # ← 必须！大模型输出慢
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-body-size: "20m"       # prompt 很长时也要调
spec:
  ingressClassName: nginx
  tls:
    - hosts: [llm.example.com]
      secretName: llm-tls
  rules:
    - host: llm.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: llm-api-svc
                port: { number: 80 }
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler         # 自动扩缩容
metadata:
  name: llm-api-hpa
  namespace: llm-prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: llm-api
  minReplicas: 1
  maxReplicas: 10
  behavior:                            # 大模型服务特别需要"慢慢来"
    scaleUp:
      stabilizationWindowSeconds: 300  # 指标上涨后先观察 5 分钟再扩
    scaleDown:
      stabilizationWindowSeconds: 900  # 缩容要更保守：15 分钟（避免抖来抖去重复加载几百 GB 权重）
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
    # GPU 利用率本身不是内置指标，需要通过 Prometheus Adapter 暴露自定义指标：
    # - type: Pods
    #   pods:
    #     metric: { name: DCGM_FI_DEV_GPU_UTIL }
    #     target: { type: AverageValue, averageValue: "80" }
```

这份清单里有几个"大模型专属"的决策值得单独强调：

- **`nvidia.com/gpu` 只能整卡申请。** K8s 原生不支持"半张卡"（除非用 MIG 或 time-slicing 虚拟切分）。所以 7B 模型独占一张 80GB A100 是很浪费的——这也是为什么生产上更常见的是"一张卡上用 vLLM 的显存分片跑多个模型"，或者干脆选型时就挑一张卡刚好装得下的模型。
- **三个探针缺一不可，但用途完全不同。** `startupProbe` 专门给"加载几分钟"这件事兜底；`readinessProbe` 决定接不接流量；`livenessProbe` 会杀容器，**对大模型服务要慎用**（见第十二节坑 4）。
- **`maxUnavailable: 0` + `maxSurge: 1`** 意味着更新时先起一个新的、就绪后再删一个旧的。代价是更新期间需要**多占一张 GPU**，所以 GPU 资源池必须留出余量，否则会卡在 `Insufficient nvidia.com/gpu` 一直更新不动。
- **Ingress 的超时必须调。** nginx 默认 60 秒，而一次长输出可能有几分钟。

### 10.4 GPU 相关的前置依赖

想让上面的 YAML 生效，集群层面还需要装三样东西，缺一个 Pod 就会一直 `Pending`：

| 组件 | 作用 | 不装的后果 |
|---|---|---|
| **NVIDIA Device Plugin** | 向 kubelet 上报 `nvidia.com/gpu` 资源 | Pod 报 `Insufficient nvidia.com/gpu`，一直 Pending |
| **NVIDIA Container Toolkit**（节点上） | 让容器真的能用卡 | Pod 起来了但 `torch.cuda.is_available()` 为 False |
| **Node Feature Discovery（可选）** | 给节点打上 GPU 型号标签 | `nodeSelector` 按型号挑选不生效 |

排障第一条命令永远是：

```bash
kubectl describe pod <pod-name> | tail -20
# 看 Events：
#   0/12 nodes are available: 12 Insufficient nvidia.com/gpu  ← Device Plugin 没装或卡满了
#  FailedScheduling / Failed to allocate device               ← 同一个 Pod 申请了超过 1 张的余量
```

---

## 十一、发布策略：怎么敢把新模型推到线上

换模型 = 换行为。**任何一次模型/权重/prompt 的变更，本质上都是一次风险发布**。这一节讲四种策略怎么选。

### 11.1 四种策略对比

| 策略 | 怎么做 | 资源开销 | 回滚速度 | 适合场景 |
|---|---|---|---|---|
| **重建（Recreate）** | 全停旧的、全起新的 | 1 份 | 慢（要重新加载几 GB~几百 GB） | 只有 1 张卡、无 SLA 要求的内部工具 |
| **滚动更新（Rolling）** | 逐个替换，`maxSurge=1, maxUnavailable=0` | 1 份 + 1 个 Pod 的余量 | 中（要逐个回退） | **默认选择**：业务代码改动、镜像版本升级 |
| **蓝绿（Blue-Green）** | 起一套完整的新环境，验证 OK 后 Service 选择器一键切过去 | **2 份（双倍 GPU）** | **秒级**（改 Service selector） | 大版本模型切换、重大架构变更 |
| **金丝雀/灰度（Canary）** | 先放 5% 流量到新版本，观察指标，逐步放量到 100% | 1 份 + 少量 | 秒级（把流量权重调回 0） | **模型/prompt 类变更的唯一稳妥做法** |

### 11.2 为什么模型变更尤其需要灰度

换模型和你改一行 Python 代码的风险性质完全不同：

- **它不会报错，只会变差。** 新模型的输出语法完全正确、接口 200、延迟可能还更低，但**答案质量悄悄降了 15%**。没有任何自动化断言能拦住这件事。
- **影响面和用户高度相关。** 你可能 Workflow 里那些长 prompt 变好了，但客服短问句变糟了。只有真实流量才知道。
- **成本/延迟特性也变了。** 新模型可能 token 更啰嗦（成本翻倍）、或者 TTFT 更高。

所以模型类变更的正确姿势是：**灰度 + 量化对比指标**。灰度期间同时看两边的数据（下一篇的监控与评测体系就是为此准备的），只有当新版本的"点踩率、拒答率、P95 延迟、单请求成本"都不劣于旧版本时，才放量到 100%。

### 11.3 用 Ingress 做最简单的金丝雀（无需 Istio）

如果你没装服务网格，nginx-ingress 自带金丝雀能力：

```yaml
# 稳定版本（100% 流量）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: llm-api-stable
spec:
  ingressClassName: nginx
  rules:
    - host: llm.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: llm-api-svc-v1, port: { number: 80 } } }
---
# 金丝雀版本（先承接 10% 流量）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: llm-api-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "10"   # 10% 流量走新模型
    # 也可以按 header/cookie 定向，适合"只让内部员工先试"
    # nginx.ingress.kubernetes.io/canary-by-header: "x-canary"
spec:
  ingressClassName: nginx
  rules:
    - host: llm.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: llm-api-svc-v2, port: { number: 80 } } }
```

放量节奏建议：**10% → 观察 30 分钟 → 30% → 观察 2 小时 → 100%**。观察期间盯四个数：点踩率、错误率、P95 延迟、单请求 token 成本（下一篇会讲怎么建这张表）。

### 11.4 回滚：三秒钟能救你一条命

```bash
# 查看历史版本
kubectl rollout history deployment/llm-api
# REVISION  CHANGE-CAUSE
# 3         镜像 → SHA a1b2c3d (7B 新权重)
# 4         镜像 → SHA e4f5g6h (7B + 新版 LoRA)

# 回滚到上一版 —— 秒切 Service 指向 + 回滚副本，不用重新加载（旧 Pod 还在）
kubectl rollout undo deployment/llm-api

# 回滚到指定版本
kubectl rollout undo deployment/llm-api --to-revision=3

# 暂停/继续正在进行中的发布（发现指标异常时用）
kubectl rollout pause  deployment/llm-api
kubectl rollout resume deployment/llm-api

# 确认状态
kubectl rollout status deployment/llm-api
# deployment "llm-api" successfully rolled out
```

**回滚能多快的前提，是你要预先把资源留出来。** 如果 `maxUnavailable=0` 且集群一张空卡都没有，回滚时会新 Pod 起不来、旧 Pod 删不掉，卡在中间态。所以 GPU 资源池一定要留 10~20% 余量——这个余量不是浪费，是你的**回滚保险费**。

---

## 十二、常见坑：十二条血泪清单

| # | 现象 | 根因 | 解决 |
|---|---|---|---|
| 1 | `libcudart.so.12: cannot open shared object file` | 镜像 CUDA 版本 > 宿主机驱动支持上限 | `nsmi` 看驱动版本 → 查 3.2 表 → 降基础镜像 CUDA 版本 |
| 2 | 容器内 `nvidia-smi` 命令不存在 | 正常现象。容器里只需要 `libcuda.so`，不需要驱动工具 | 用 `torch.cuda.is_available()` 或 `dcgm-exporter` 验证，别纠结 `nvidia-smi` |
| 3 | 多卡推理报 `NCCL error` / `Bus error` | 容器 `/dev/shm` 默认只有 64MB | `--shm-size=16g` 或 K8s 挂 `emptyDir{medium: Memory}` |
| 4 | 容器无限重启，日志显示模型加载到一半被杀 | **livenessProbe 在加载期就把容器判死杀了** | 加 `startupProbe`（给 10 分钟），或把 liveness 的 `initialDelaySeconds` 调到 > 加载时间 |
| 5 | 中文輸出是乱码 / 日志时间差 8 小时 | 容器默认 `LANG` 为 `POSIX`、`TZ` 为 UTC | Dockerfile 里设 `LANG=C.UTF-8` 和 `TZ=Asia/Shanghai`，或挂 `/etc/localtime` |
| 6 | `pull access denied` / 拉镜像极慢 | 私有仓库鉴权缺失，或镜像几十 GB | 镜像瘦身到个位数 GB；配 imagePullSecrets；节点做镜像预热（DaemonSet 预拉） |
| 7 | 挂载的权重目录在容器里是**空目录** | 宿主机路径写错了（常见于 macOS/Windows 的相对路径），或用了 `~` 没展开 | 用绝对路径；宿主机先 `ls /data/llm/hub/Qwen2.5-7B-Instruct` 确认存在 |
| 8 | 容器内生成的日志文件，宿主机是 root 属主 | 容器以 root 运行 | Dockerfile 加 `USER 1000:1000`，或启动时 `-u $(id -u):$(id -g)` |
| 9 | `docker build` 第一步卡半天 | 没有 `.dockerignore`，上下文几十 GB | 补 `.dockerignore`（见 4.6） |
| 10 | 改一行代码重新构建要 8 分钟 | `COPY . .` 写在 `RUN pip install` 之前 | 先 `COPY requirements.txt` → `RUN pip install` → `COPY app/` |
| 11 | Pod 一直 `Pending`：`Insufficient nvidia.com/gpu` | Device Plugin 未装 / GPU 节点有污点没容忍 | 装 device plugin；配 `tolerations` |
| 12 | 显存 OOM：`KV cache size is larger than available` | `gpu_memory_utilization` 设太高（>0.95）或 `max_model_len` 太大 | 降到 0.85~0.90；或缩短 `max_model_len`；或开启量化/减小 `max_num_seqs` |
| 13 | 请求返回 504 Gateway Timeout | Ingress nginx 默认 proxy-read-timeout 60s | 加 annotation 调到 600 |
| 14 | `TOKENIZERS_PARALLELISM` 警告刷屏导致日志爆炸 | HF tokenizer fork 警告 | 环境变量设 `TOKENIZERS_PARALLELISM=false` |

第 4 条值得再多说两句，因为它是**大模型容器化最独特的一个坑**：普通 Web 服务启动只要 1 秒，健康检查 3 次失败就重启是合理的；而大模型服务加载要 40 秒到 10 分钟（取决于权重大小和磁盘 IO）。如果你照抄网上的健康检查配置给了 3 次 × 10 秒，那你的容器就永远处在"加载 40 秒 → 第 30 秒被判死 → 重启 → 加载 40 秒"的死亡循环里。**记住：有模型加载这一步的服务，必须配 `startupProbe` 或足够长的 `start_period`。**

第 8 条也常被忽略：容器里 root 写的文件，宿主机上也是 root。如果你的 CI 用户没 sudo 权，清理临时文件会失败、甚至误删不了旧数据。用非 root 用户运行容器（`USER`）是安全基线的标准动作。

---

## 十三、本节小结

这一节我们把"能跑的服务"变成了"能交付的服务"，串起了完整链路：

- **为什么容器化**：大模型服务的依赖有四层（业务代码 / Python 包 / CUDA 生态 / 系统库），比普通服务深得多，靠文档和记忆无法复现。容器化把环境从口头约定变成可执行、可版本化、可回滚的制品。
- **核心概念**：镜像是只读分层文件，容器 = 镜像层 + 可写层，多个容器共享只读层并不会浪费磁盘。数据持久化靠 bind mount / volume / tmpfs 三种挂载，容器间互访靠服务名做 DNS 解析。
- **GPU 容器**：理解"容器里有两个 CUDA"是关键——`libcuda.so` 来自宿主机驱动，`libcudart.so` 来自镜像。铁律是**容器 CUDA 版本 ≤ 宿主机驱动支持的上限**。选基础镜像按 `runtime/devel` 取舍，`--gpus all` 是运行时参数。
- **Dockerfile 工程实践**：权重**绝不能进镜像**（会让镜像几十 GB、冷启动十分钟、无法弹性伸缩），要用 volume 挂载，配合 `HF_HOME` 复用缓存。
- **compose 编排**：`depends_on` 默认不等待服务就绪，必须配合 `healthcheck` + `condition: service_healthy` + `start_period`，否则业务容器会在推理引擎加载期间疯狂报错。
- **镜像瘦身**：优先级是「层顺序（改一行代码从 8 分钟到 6 秒）> 权重外挂 > 多阶段构建 > 基础镜像 > 清理缓存」。`alpine` 是陷阱，别用。
- **配置管理**：代码与配置分离（12-factor），非敏感配置进 ConfigMap、敏感配置进 Secret，密钥永远不进镜像层。
- **K8s**：Deployment 管副本与版本、Service 给稳定入口、Ingress 引入外部流量，GPU 靠 `nvidia.com/gpu` 整卡申请，HPA 缩容要留长稳定窗口。
- **发布**：业务代码用滚动更新；**模型/权重/prompt 变更必须用灰度**，因为它不会报错只会变差；回滚的前提是 GPU 资源池有余量。

一句话总结：**容器化解决"能不能搬过去"，K8s 解决"能不能稳定地、规模化地跑"，而发布策略解决"改了之后敢不敢上线"。**

---

## 十四、实战练习

**练习 1（必做）：容器化你的推理服务**
把上一篇写好的 FastAPI 服务按第四节的结构整理好，写出 Dockerfile 并成功构建。验证标准：① `docker images` 看到镜像体积在 10GB 以内；② 改一行 `app/main.py` 后重新构建，耗时 < 30 秒（验证层缓存生效）；③ `docker run --gpus all` 后 `docker exec` 进去 `python -c "import torch; print(torch.cuda.is_available())"` 输出 `True`。

**练习 2（必做）：权重外挂与数据持久化**
故意做一次对比：先把 1GB 左右的模型权重 COPY 进镜像构建一次，记录镜像体积和 build 时间；再改成 bind mount 挂载构建一次，对比两者差异。然后在容器里生成一份日志，`docker rm` 删掉容器，观察宿主机挂载目录里的文件还在不在——动手验证"可写层随容器消失、volume 不消失"。

**练习 3：多容器编排**
写一个 compose 文件，起"推理服务 + Redis"两个容器，在推理服务里加一层缓存：相同的 prompt 先查 Redis，命中就直接返回（跳过推理）。用 `redis-cli MONITOR` 观察命中情况，并统计加了缓存之后第二次请求的延迟下降了多少毫秒。注意别忘 Compose 里 `redis` 的服务名。

**练习 4：故意犯错并修复（最有价值的一项）**
依次制造并修复以下四个故障，记录每次的报错原文和你的修复命令：① 删掉 `--shm-size` 看多卡是否报错；② 把 `start_period` 去掉看容器会不会无限重启；③ 把基础镜像换成 `-devel` 看体积涨了多少；④ 用 `python:3.10-alpine` 构建看 torch 能不能装上。**这四个坑你在本地踩一遍，比在生产环境踩一次便宜太多。**

**练习 5：K8s 清单（有集群条件再做）**
写出 10.3 节那套 Deployment + Service + Ingress，部署到集群（没有 GPU 集群可以用 kind + CPU 版的迷你模型）。观察：`kubectl get pod -w` 里 Pod 从 `Pending` → `ContainerCreating` → `Running` → `Ready` 的状态迁移，用 `kubectl describe pod` 看 Events 里发生了什么。然后执行一次 `kubectl set image` 触发滚动更新，观察新旧 Pod 的交替顺序。

---

## 十五、延伸阅读与下一步

**延伸阅读**

- NVIDIA Container Toolkit 官方文档 —— 安装方式、`--gpus` 各参数语义
- NVIDIA CUDA Compatibility 文档 —— "驱动版本 ↔ CUDA runtime 版本"完整对照表的权威来源
- NVIDIA DCGM / dcgm-exporter —— GPU 指标采集，下一篇会用到
- Kubernetes 官方文档：Device Plugins、Horizontal Pod Autoscaling、Probe 配置
- vLLM 官方仓库的 Dockerfile —— 学习别人怎么写 GPU 推理镜像的最好教材

**下一步**

容器化把服务稳稳地放到线上之后，紧接着的问题就变成——**你怎么知道它现在还是好的**？延迟的 P99 是多少、显存还剩多少、用户点了多少次踩、昨天换的那版 prompt 到底让答案变好了还是变差了。这些都不是"部署"能回答的，得靠观测。下一篇《生产监控与评测体系》就来补上这最后一块拼图：Prometheus + Grafana 的指标与告警、结构化日志与 request_id 全链路、影子流量与 A/B 实验、LLM-as-judge 自动打分，以及怎么把用户的每一次点踩都回流成下一次迭代的数据。

---

本篇是《大模型开发从 0 到 1》专栏第 52 篇。
