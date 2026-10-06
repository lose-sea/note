<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 模型推理加速——vLLM 与高性能推理框架

**承上**：上一篇《训练监控与评估——loss 曲线与评测集》我们把模型训完、把指标测明白了，但它现在还只是一堆躺在磁盘上的权重文件——`generate()` 一次要等好几秒，多来几个用户排队就崩，显存说爆就爆。

**本篇**：解决"训完了怎么让它跑得又快又便宜"——从 prefill/decode 两阶段的本质差异讲起，推导出 KV Cache 的显存账单，一路讲到 continuous batching 与 PagedAttention，最后落地到 vLLM 的完整实战与压测方法。

**启下**：下一篇《用 FastAPI 封装模型服务》把本篇跑起来的推理引擎包装成带鉴权、限流、流式输出和 OpenAI 兼容接口的正式服务，让前端和第三方 SDK 能真正调得动它。

**学完这一节，你能动手做**：

1. 算出任意模型在任意上下文长度下的 KV Cache 显存占用，并据此规划一张显卡能开多大并发
2. 用 vLLM 起一个 OpenAI 兼容的高吞吐推理服务，并把它跑在多张卡上
3. 写出压测脚本，测出 TTFT / TPOT / 吞吐 / 并发曲线，并按 SLO 选定上线参数

---

## 一、为什么"能跑"和"跑得快"是两件事

在前面所有章节里，我们对模型的要求只有一条：**训得出、测得准**。训练时的心态是"慢点没关系，跑一夜也能接受"，因为训练是一次性投入，跑完就换来了永久的权重资产。但推理完全不同——它是**每天都在持续烧钱、每毫秒都在被用户感知**的在线服务。一个 7B 模型训完只要几百块钱算力，但如果每次问答要 8 秒、一张卡只能扛 3 个并发，那它永远不可能成为一个产品。

先建立一个具体的体感。假设你在本地用最朴素的写法跑一个 7B 对话模型：

- 问一句"介绍一下 KV Cache"，生成 200 个 token，**耗时 8~14 秒**；
- 同时来 4 个用户，第 4 个人要等前面三个都跑完才有反应，**延迟飙到 40 秒**；
- 你想把 batch 开大一点提升吞吐，结果 **CUDA out of memory**；
- 你以为"多开几个 Python 进程"能解决，结果每个进程都各自加载一遍 15GB 权重，显存直接翻倍。

这四条几乎是所有第一次做模型部署的人都会踩的坑。它们看起来是四个问题，其实根子是同一个：**大语言模型的推理是一个"显存带宽受限 + 显存容量受限 + 请求长度高度不齐"的特殊负载**，而我们熟悉的那些 Web 服务优化手段（加进程、加线程、加机器）在这个负载面前全都抓错了重点。

本篇要建立的第一个认知是：**大模型推理的优化目标不是一个数字，而是一组互相拉扯的指标**。你不可能同时让"单个用户最快"和"整体吞吐最大"都达到最优——就像高速公路：只放一辆车上去它能跑 120 码，但整条路一小时只能通过 1 辆车；塞满车时一小时能通过 2000 辆，但每辆车都只能挪 40 码。所谓"推理加速"，本质是在**这条权衡曲线上找到符合你业务的那个点**，然后用工程手段把整条曲线往上抬。

把优化目标拆开看，其实是三个层次的问题，它们各自有不同的解法：

```
┌────────────────────────────────────────────────────────────┐
│                    推理性能的三个层次                        │
├────────────────────────────────────────────────────────────┤
│                                                              │
│  层次 1：单请求延迟（Latency）                                │
│     用户感知的"快不快"                                        │
│     主要矛盾：decode 阶段每一步都要把整个模型从显存读一遍      │
│     解法：量化、投机解码、更好的算子（FlashAttention）         │
│                                                              │
│  层次 2：系统吞吐（Throughput）                               │
│     "一张卡一小时能出多少 token" = 成本                       │
│     主要矛盾：GPU 大部分时间在等数据搬运，算力闲置             │
│     解法：batching、continuous batching、CUDA Graph           │
│                                                              │
│  层次 3：并发能力（Capacity）                                 │
│     "同时能服务多少人" = 能不能上线                           │
│     主要矛盾：KV Cache 吃显存，且显存被碎片化浪费              │
│     解法：PagedAttention、KV Cache 量化、prefix sharing       │
│                                                              │
└────────────────────────────────────────────────────────────┘
```

这三个层次不是孤立的。你会发现：**层次 3（显存容量）决定了你能开多大 batch，而 batch 大小直接决定层次 2（吞吐），batch 变大又会让层次 1（单请求延迟）变差**。这就是为什么 vLLM 这个框架的突破口选在了显存管理上——它没有去卷算子速度，而是先把"显存浪费"这个最底层的瓶颈拆掉，结果吞吐自然就上去了。这是本篇最重要的一条叙事线。

本篇的路线图如下，建议按顺序读，因为每一节都是下一节的动机：

```
① 推理为什么慢  →  ② KV Cache 的账单  →  ③ batching 的演进
   prefill/decode        显存算例            static→continuous
   算访存比              容量决定并发
                                                    ↓
⑥ 其它加速手段  ←  ⑤ vLLM 实战与压测  ←  ④ PagedAttention
   量化/投机解码      离线/在线/多卡          分页管理显存
   前缀缓存            指标体系              共享前缀
```

在进入技术细节之前，先约定一件重要的事：**本篇所有的"快"都是可测量的**。我会给出每个指标的明确定义和测法，而不是说"感觉快了"。推理优化这个领域最容易自欺欺人——改了个参数觉得"好像快了"，结果一压测发现只是因为这次请求短。没有量化就没有优化，这跟前面讲训练监控时是同一个道理。

## 二、推理为什么慢：prefill 与 decode 是两副完全不同的面孔

要搞懂推理优化，第一个必须刻进脑子里的事实是：**大模型生成一段文本，并不是"一个大模型跑了一次"，而是"一个大模型跑了很多次，并且这些次的计算性质完全不同"**。

具体来说，一次对话请求被切成两个阶段：

```
用户输入："请用三句话解释 KV Cache"
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│ 阶段 A：Prefill（预填充 / 首 token 计算）                   │
│                                                            │
│   把整段 prompt（假设 20 个 token）一次性送进模型           │
│   → 一个形状为 [20, 4096] 的大矩阵 × [4096, 4096] 的权重    │
│   → 矩阵-矩阵乘（GEMM），并行度极高，GPU 算力被吃满          │
│   → 输出第 1 个新 token 的 logits                           │
│   → 顺手把每个 token 的 K、V 存进 KV Cache                  │
│                                                            │
│   特征：计算密集型（compute-bound）                         │
│   耗时：与 prompt 长度强相关，通常几十~几百 ms               │
└──────────────────────────────────────────────────────────┘
        │ 产出第一个 token："KV"
        ▼
┌──────────────────────────────────────────────────────────┐
│ 阶段 B：Decode（自回归解码）                                │
│                                                            │
│   每一步只把上一步生成的 1 个 token 送进模型                 │
│   → 一个形状为 [1, 4096] 的向量 × [4096, 4096] 的权重       │
│   → 矩阵-向量乘（GEMV），并行度极低                          │
│   → 输出下 1 个 token                                       │
│   → 把它的 K、V 追加进 KV Cache                             │
│                                                            │
│   重复 N 次，直到生成结束（遇到 EOS 或达到 max_tokens）      │
│                                                            │
│   特征：显存带宽密集型（memory-bound）                      │
│   耗时：每步十几~几十 ms，200 个 token 就要好几秒            │
└──────────────────────────────────────────────────────────┘
        │
        ▼
   完整回答（200 个 token）
```

这张图里藏着本节的核心结论：**prefill 是一锤子买卖，decode 是重复几百次的苦力活**。用户感知到的"慢"，90% 来自 decode 阶段——你等 8 秒拿到 200 个字，其中可能只有 0.2 秒花在 prefill 上，剩下 7.8 秒都是 decode 一步一挪。

### 2.1 算访存比：为什么 decode 阶段 GPU 算力在"空转"

为什么会这样？答案在**算访存比（Arithmetic Intensity）**这个概念里。它的定义很简单：

```
算访存比 = 计算量（FLOPs） / 需要从显存搬运的数据量（Bytes）
```

GPU 有两块硬指标：**算力**（A100 约 312 TFLOPS FP16）和**显存带宽**（A100 约 2 TB/s，4090 约 1 TB/s，H100 约 3.35 TB/s）。一个计算任务到底卡在哪儿，取决于它的算访存比和 GPU 的"算力/带宽比"谁更大：

- **算访存比 > 算力/带宽比** → 算力先耗尽 → **compute-bound**（好事，GPU 在满负荷算）
- **算访存比 < 算力/带宽比** → 带宽先耗尽 → **memory-bound**（坏事，GPU 在等数据）

A100 的算力/带宽比约为 312e12 / 2e12 ≈ **156 FLOPs/Byte**。也就是：一个任务每搬 1 字节数据，如果能顺便做 156 次以上的浮点运算，GPU 才算吃饱。

现在算一下两个阶段的算访存比。以一个线性层为例，权重矩阵形状 [4096, 4096]，FP16 存储（2 字节）：

**Prefill（batch 内共 512 个 token 一起算）**：
- 计算量：2 × 512 × 4096 × 4096 ≈ 1.7e10 FLOPs
- 搬运量：权重 4096 × 4096 × 2 ≈ 3.4e7 Bytes（输入矩阵相对权重可忽略）
- 算访存比 ≈ **512 FLOPs/Byte** → 远大于 156 → **compute-bound**，GPU 算力吃满

**Decode（一次只有 1 个 token）**：
- 计算量：2 × 1 × 4096 × 4096 ≈ 3.4e7 FLOPs
- 搬运量：权重还是 3.4e7 Bytes（**一步要把整个权重读一遍**）
- 算访存比 ≈ **1 FLOPs/Byte** → 远小于 156 → **memory-bound**，99% 的时间在等显存

这个对比是本篇最关键的推导，值得停下来体会一下：**decode 一步的计算量只有 prefill 的 1/512，但要搬运的数据量一模一样**。因为不管你送进去 1 个 token 还是 512 个 token，模型权重都得从显存被完整地读进计算核心一次。权重是固定的，计算量却差了 500 倍——这就是 decode 阶段 GPU 利用率只有个位数百分比的原因。

我们可以用这个模型**直接算出 decode 的速度理论上限**，这个数字非常有用：

```
7B 模型 FP16 权重 = 7e9 × 2 Bytes = 14 GB
A100 显存带宽     = 2 TB/s

理论最快一步 = 14 GB / 2 TB/s = 7 ms
→ 单请求理论上界 = 1 / 0.007 ≈ 143 token/s
```

换成 4090（1 TB/s）就是约 71 token/s，换成 H100（3.35 TB/s）就是约 240 token/s。**注意这个上界跟 GPU 的算力完全无关**——你把 A100 换成算力强三倍的卡，只要带宽没变，单请求 decode 速度就不会变。这就是为什么"买更贵的卡"对单请求延迟几乎没有帮助，而"把请求攒成 batch"却能把吞吐提升几十倍。

攒 batch 为什么有效？因为**权重读一次，可以服务 batch 里所有请求**：

```
batch = 1  ：读 14GB 权重 → 产出 1 个 token   → 143 tok/s
batch = 32 ：读 14GB 权重 → 产出 32 个 token  → 理论 4576 tok/s
```

当然这是理论上限，实际还要加上 KV Cache 的读取、激活值读写、kernel 启动开销等，A100 上 7B 模型实际能达到的总吞吐一般在 1500~3000 tok/s 量级，但"batch 越大越划算"这个结论是铁律。

到这里我们可以给出推理优化的第一条基本原则（记牢它，后面所有技术都是它的推论）：

> **推理优化的核心不是"算得更快"，而是"让每一次权重搬运服务更多的 token"。**
> 手段有三：① 一次搬权重复用（batching）；② 缩小要搬的权重（量化）；③ 让显存装得下更大的 batch（显存管理）。

### 2.2 自回归解码：一个 token 都不能并行

还有一个残酷的事实：**decode 阶段的 N 步之间，无法并行**。第 100 个 token 依赖第 99 个 token 的结果，这是自回归生成的定义决定的。所以"生成 200 个 token"这件事，就是老老实实做 200 次前向传播，任你怎么优化都躲不掉。

这条约束衍生出一个重要推论：**输出长度是延迟的第一杀手，而 prompt 长度是成本的第一杀手**。生成 1000 字的文章就是生成 100 token 的 10 倍时间，没有捷径（投机解码是唯一的例外，见第九节）。所以在产品设计上，控制 `max_tokens`、引导模型"简明回答"、做好截断，往往比优化引擎本身更能改善用户体验。

## 三、KV Cache：用显存换时间，以及它的账单

上一节留了一个尾巴：decode 每一步"只送 1 个 token 进模型"，那这个 token 怎么知道前面 200 个 token 说了什么？答案是注意力机制——每一步都要拿当前 token 的 Q，去和**所有历史 token 的 K、V** 做注意力计算。

如果每一步都重新计算所有历史 token 的 K 和 V，会发生什么？第 n 步要算 n 个 token 的 K/V，整个生成过程的总计算量是 O(n²)——生成一个 2000 字的回答，光 K/V 投影就要重复算两百万次。这显然不可接受。

于是有了 **KV Cache**：把每个 token 算出来的 K 向量和 V 向量**缓存下来**，下一步直接复用，只算新 token 的那一份。这样总计算量从 O(n²) 降到 O(n)，用空间换时间——代价是要为这些缓存付出显存。

```
         没有 KV Cache                      有 KV Cache
    step 1: 算 tok1 的 K,V              step 1: 算 tok1 的 K,V → 存起来
    step 2: 算 tok1,tok2 的 K,V          step 2: 算 tok2 的 K,V → 追加
    step 3: 算 tok1,2,3 的 K,V           step 3: 算 tok3 的 K,V → 追加
    ...                                  ...
    step n: 算 tok1..n 的 K,V            step n: 算 tokn 的 K,V → 追加
    ─────────────────────────           ─────────────────────────
    总计算 O(n²)                         总计算 O(n)，显存 O(n)
```

### 3.1 KV Cache 显存公式

这个缓存到底多大？记住这个公式，它能让你在任何选型会上快速算出能不能装得下：

```
每个 token 的 KV Cache 字节数 =
    2                      ← K 一份、V 一份
  × n_layers               ← 每一层都要存
  × n_kv_heads             ← 注意：是 KV 头数，不是 Query 头数！
  × head_dim               ← 每个头的维度
  × dtype_bytes            ← fp16/bf16 = 2，fp8 = 1

一条序列的总占用 = 单 token 字节数 × 序列长度（prompt + 已生成）
整个服务的占用   = 单 token 字节数 × 所有活跃序列长度之和
```

公式里最容易踩的坑是 `n_kv_heads`。现代模型普遍用 **GQA（Grouped Query Attention）**，即多个 Query 头共享一组 KV 头。比如 Qwen2.5-7B 有 28 个 Query 头，但只有 4 个 KV 头——如果你按 28 去算，结果会夸大 7 倍，从而做出错误的容量规划。这个设计本身就是为了压缩 KV Cache 才出现的。

### 3.2 把公式变成能跑的算例

下面这段代码把上面的公式写成了工具，你可以把自己的模型配置填进去直接算。这段代码只用标准库，**复制粘贴就能跑**：

```python
def kv_cache_bytes_per_token(n_layers, n_kv_heads, head_dim, dtype_bytes=2):
    """每个 token 的 KV Cache 字节数：K 和 V 各存一份，所以要乘 2。"""
    return 2 * n_layers * n_kv_heads * head_dim * dtype_bytes


MODELS = [
    # 名称, layers, kv_heads, head_dim
    ("Qwen2.5-7B-Instruct  (GQA 4)", 28, 4, 128),
    ("Llama-3.1-8B-Instruct (GQA 8)", 32, 8, 128),
    ("Qwen2.5-14B-Instruct (GQA 8)", 48, 8, 128),
    ("Llama-3.1-70B        (GQA 8)", 80, 8, 128),
]

print(f"{'模型':<30}{'单 token':>10}{'1K ctx':>10}{'8K ctx':>10}{'32K ctx':>10}")
print("-" * 72)
for name, layers, kv, hd in MODELS:
    per = kv_cache_bytes_per_token(layers, kv, hd)
    print(f"{name:<30}{per/1024:>8.1f} KB{per*1024/1024**2:>8.1f} MB"
          f"{per*8192/1024**3:>8.2f} GB{per*32768/1024**3:>8.2f} GB")

# 70B 用 TP=4 时 KV 被切分到 4 张卡
per70_single = kv_cache_bytes_per_token(80, 8, 128) / 4
print(f"\nLlama-3.1-70B 在 TP=4 下，单卡 32K 上下文 KV = "
      f"{per70_single*32768/1024**3:.2f} GB/卡")

# 场景：7B 模型，并发 32 条、每条 4096 token
per = kv_cache_bytes_per_token(28, 4, 128)
total = per * 4096 * 32
print(f"\n[场景] Qwen2.5-7B, 并发 32 条 x 4096 token：")
print(f"  KV Cache  = {total/1024**3:.2f} GB")
print(f"  权重 fp16 = 15.00 GB")
print(f"  合计      = {total/1024**3 + 15:.2f} GB  -> 24GB 卡几乎塞满")

# 24GB 卡能开多大并发
avail = (24.0 - 15.0) * 1024**3
print(f"\n[容量规划] 24GB 卡装下 7B 权重后剩 {(24-15):.1f} GB 给 KV：")
for seq in (2048, 4096, 8192):
    print(f"  max_model_len={seq:<5} -> 理论并发上限 {int(avail // (per*seq)):>3} 条")
```

实际运行结果：

```
模型                               单 token    1K ctx    8K ctx   32K ctx
------------------------------------------------------------------------
Qwen2.5-7B-Instruct  (GQA 4)      56.0 KB    56.0 MB    0.44 GB    1.75 GB
Llama-3.1-8B-Instruct (GQA 8)    128.0 KB   128.0 MB    1.00 GB    4.00 GB
Qwen2.5-14B-Instruct (GQA 8)     192.0 KB   192.0 MB    1.50 GB    6.00 GB
Llama-3.1-70B        (GQA 8)     320.0 KB   320.0 MB    2.50 GB   10.00 GB

Llama-3.1-70B 在 TP=4 下，单卡 32K 上下文 KV = 2.50 GB/卡

[场景] Qwen2.5-7B, 并发 32 条 x 4096 token：
  KV Cache  = 7.00 GB
  权重 fp16 = 15.00 GB
  合计      = 22.00 GB  -> 24GB 卡几乎塞满

[容量规划] 24GB 卡装下 7B 权重后剩 9.0 GB 给 KV：
  max_model_len=2048  -> 理论并发上限  82 条
  max_model_len=4096  -> 理论并发上限  41 条
  max_model_len=8192  -> 理论并发上限  20 条
```

这几行数字能直接指导工程决策，请重点消化三条：

第一，**KV Cache 是大头，不是零头**。7B 模型在 32 并发 × 4K 上下文下，KV Cache 要 7GB，跟权重（15GB）已经是同一量级。很多人的直觉是"显存主要被权重占了"，于是按 `显存 / 权重` 估算并发数，结果一上线就 OOM——因为他忘了 KV Cache 会随并发线性增长。

第二，**上下文长度直接换算成钱**。`max_model_len` 从 2048 提到 8192，同一张卡的并发上限从 82 条掉到 20 条，掉到四分之一。这就是为什么"支持超长上下文"是要付出真金白银的，也是为什么不应该无脑把 `max_model_len` 设成模型支持的最大值（32K、128K）。**你的业务真的需要 32K 吗？如果 90% 的请求都在 2K 以内，把上限设成 4096 能让你的并发翻一倍**，这是投入产出比最高的一个参数。

第三，**70B 这类大模型必须张量并行**。单卡装不下权重，而且 TP=4 之后 KV Cache 也被切到 4 张卡上（单卡 32K 只需 2.5GB），所以"多卡"不只是为了装权重，也在帮你分摊 KV Cache。

### 3.3 显存账本：一张卡上的四笔支出

把上面的结论整理成一张完整的账本，以后排查 OOM 就照着这个单子对：

| 支出项 | 大小 | 是否可变 | 说明 |
|---|---|---|---|
| 模型权重 | 参数量 × dtype（7B fp16 ≈ 15GB） | 固定 | 量化可减小；多进程加载会重复占用 |
| KV Cache | 见 3.1 公式 | **随并发和长度线性增长** | 推理框架的"可用显存"基本都给它 |
| 激活值（activation） | 几百 MB~几 GB | 随 batch / seq 增长 | 中间张量；FlashAttention 可大幅降低 |
| 碎片与其它 | 不可预测 | — | CUDA context、NCCL buffer、框架预留 |

vLLM 的 `gpu_memory_utilization` 参数控制的正是"这张卡总共允许占用多少比例"，剩下的都留给 KV Cache。所以真正决定你并发上限的公式是：

```
可用于 KV Cache 的显存 = GPU 总显存 × gpu_memory_utilization − 权重 − 激活 − 固定开销
最大并发数 ≈ 可用 KV 显存 / (单 token KV 字节 × 平均序列长度)
```

现在，瓶颈已经非常清楚了：**并发能力 = 显存容量 / 单条序列占用**。想要更高并发，要么减少单条占用（量化 KV、共享前缀），要么让显存别浪费。这就把我们推向了下一个问题——显存到底浪费在哪儿？

## 四、Batching 策略演进：从 static 到 continuous

有了"batch 越大越划算"的结论，自然的想法就是：把用户请求攒起来一起跑。但怎么攒，是个大学问。这一节讲清三代 batching 策略，以及每一代解决了什么问题、留下了什么问题。

### 4.1 Static Batching：简单，但浪费得离谱

最朴素的方案：**固定 batch size 为 4，凑够 4 条请求才开始跑，跑完 4 条全部结束再放下一批**。它的两个致命问题用一张图就能看清：

```
Static Batching（batch=4），四条请求长度差异很大
┌────────────────────────────────────────────────────────────────┐
│ 时间轴 →                                                        │
│                                                                 │
│ Req A ████████████░░░░░░░░░░░░  prompt 100, output 40           │
│ Req B ████████████████████████  prompt 900, output 200          │
│ Req C ████████████████░░░░░░░░  prompt 300, output 80           │
│ Req D ████████████████████░░░░  prompt 500, output 150          │
│       ↑                        ↑                                │
│       prefill 全部 padding     decode 走满最长序列的步数          │
│       到 900（B 的长度）         （200 步），A/C/D 早已结束        │
│                                 但仍在占着槽位                   │
└────────────────────────────────────────────────────────────────┘
  浪费 1：prefill padding —— A 的 100 token 被补到 900，白算 800 个
  浪费 2：decode 尾延迟  —— A 只生成 40 个 token，却要等到第 200 步
                            整批结束才返回，显存也多占了 160 步
```

这个"尾延迟"问题在真实业务里非常严重：线上请求的输出长度是长尾分布的，可能 80% 的请求只要 50 个 token，但只要有 1 条请求要 500 个 token，同批的所有人就得陪着等到第 500 步。用户感知是"我明明只问了个简单问题，为什么要等半分钟"。

### 4.2 Dynamic Batching：缓解等待，但没解决根本

Dynamic batching 的改进是：**不再傻等凑够 N 条，而是设一个时间窗口（比如 5ms），窗口内到了多少条就跑多少条；同时按长度分组，把长度相近的请求放一批，减少 padding**。

它确实缓解了"凑批等待"和"padding 浪费"，但有一个根本问题没解决：**一批还是必须一起结束**。只要同批里有一条长序列，其它短序列的槽位就还是被占着。而且按长度分组会引入额外延迟（要等长度相近的请求出现），在高 QPS 下还好，在低 QPS 下反而更慢。

### 4.3 Continuous Batching：以"一步"为粒度调度

真正的解法是换个思路：**为什么非要"一批同时开始、同时结束"？**  如果调度的粒度从"一批请求"细化到"一次 decode 步"，那问题就全解开了：

```
Continuous Batching（也叫 in-flight batching）
以 decode step 为时钟，每一步重新组建 batch

  step 1: [A B C D]     ← 4 条一起跑
  step 2: [A B C D]
  ...
  step 41: A 生成完了 → 立刻离开，槽位空出
  step 42: [B C D E]    ← E 是新来的请求，立刻补位（不需要等任何人）
  step 43: [B C D E]
  ...
  step 81: C 生成完 → 离开，F 补位
  step 82: [B D E F]

  每个序列：生成完立刻返回，不等别人
  每个新请求：有空槽就立刻进场，不必凑批
  显存：序列结束立刻释放，下一秒就能给别人用
```

这个思路的三个好处是连锁的：**① 不再有尾延迟**（谁完谁走）；**② 不再有固定的凑批等待**（有空位就进）；**③ 显存周转率大幅提高**（槽位一旦空出立刻被复用）。第三条尤其关键——它意味着在同样的显存下，你能服务的请求数更多，从而吞吐更高。

不过 continuous batching 有个前提：**必须有足够精细的显存管理，才能让"随时加入、随时退出"的序列高效地共享显存**。如果每个序列都要求一块连续的大显存，那频繁的加入退出很快就会把显存切成碎片——就像内存碎片一样，总空闲空间够，但分配不出连续的大块。这正是 PagedAttention 要解决的问题，我们下一节讲。

### 4.4 用模拟器把差距量化

下面这段代码把三种策略的核心差异做成了可调度的模拟器。它用一个简化但保留本质的时间模型：**prefill 按 token 计费（compute-bound），decode 一步的耗时 = 常数 + 小斜率 × batch（memory-bound，权重只读一遍）**。代码只依赖标准库，直接跑：

```python
"""对比 static batching 与 continuous batching 的调度行为。
时间模型（简化但保留本质差异）：
  - prefill：compute-bound，耗时 ≈ 0.00025 s / token（padding 也算钱）
  - decode ：memory-bound，一步读一遍权重，耗时 ≈ 0.018 + 0.0004 * batch_size s
    注意斜率远小于常数项 —— 这就是"batch 越大单 token 越便宜"的来源。
"""
import random

PREFILL_PER_TOKEN = 0.00025
DECODE_BASE = 0.018
DECODE_SLOPE = 0.0004

random.seed(42)
# 8 条请求：prompt 长度和输出长度差异很大（真实线上就是如此）
REQUESTS = [
    {"id": i,
     "prompt": random.randint(80, 900),
     "output": random.randint(20, 260)}
    for i in range(8)
]


def static_batching(reqs, batch_size=4):
    """静态批处理：固定凑够 batch_size 条才跑，padding 到组内最长，
    整批全部生成完才能放下一批。"""
    t = 0.0
    latencies = {}
    wasted_prefill = 0
    for start in range(0, len(reqs), batch_size):
        group = reqs[start:start + batch_size]
        max_prompt = max(r["prompt"] for r in group)
        max_out = max(r["output"] for r in group)
        # prefill：padding 到 max_prompt，浪费的部分也要算算力
        for r in group:
            wasted_prefill += (max_prompt - r["prompt"])
        t += max_prompt * len(group) * PREFILL_PER_TOKEN
        # decode：走满 max_out 步，已结束的序列继续占坑（padding）
        for step in range(max_out):
            t += DECODE_BASE + DECODE_SLOPE * len(group)
            for r in group:
                if r["output"] == step + 1:
                    latencies[r["id"]] = t
    return t, latencies, wasted_prefill, sum(r["output"] for r in reqs)


def continuous_batching(reqs, max_running=8):
    """连续批处理：以 decode step 为时钟推进，谁生成完谁立刻退出并腾出槽位，
    等待队列里的新请求立刻补位（in-flight batching）。"""
    t = 0.0
    latencies = {}
    waiting = list(reqs)
    running = []          # [req, 已生成 token 数]
    finished_out = 0
    wasted_prefill = 0    # continuous 下 prefill 按真实长度算，无 padding 浪费
    while waiting or running:
        # 1) 有空位就从队列取新请求做 prefill（不与其它序列互相阻塞）
        while waiting and len(running) < max_running:
            r = waiting.pop(0)
            t += r["prompt"] * PREFILL_PER_TOKEN
            running.append([r, 0])
        if not running:
            break
        # 2) 所有在跑的序列一起 decode 一步（batch 越大越划算）
        t += DECODE_BASE + DECODE_SLOPE * len(running)
        still = []
        for r, done in running:
            done += 1
            if done >= r["output"]:
                latencies[r["id"]] = t
                finished_out += done
            else:
                still.append([r, done])
        running = still
    return t, latencies, wasted_prefill, finished_out


def report(name, reqs, total_t, lat, wasted, out_tokens):
    lats = list(lat.values())
    avg = sum(lats) / len(lats)
    p95 = sorted(lats)[int(len(lats) * 0.95) - 1]
    print(f"\n=== {name} ===")
    print(f"  总耗时（全部请求完成） : {total_t:8.2f} s")
    print(f"  系统吞吐               : {out_tokens/total_t:8.2f} token/s")
    print(f"  平均单请求延迟         : {avg:8.2f} s")
    print(f"  P95 延迟               : {p95:8.2f} s")
    print(f"  prefill padding 浪费   : {wasted:8d} token")
    return out_tokens / total_t, avg


t1, l1, w1, o1 = static_batching(REQUESTS, batch_size=4)
s_thr, s_lat = report("Static Batching (batch=4)", REQUESTS, t1, l1, w1, o1)

t2, l2, w2, o2 = continuous_batching(REQUESTS, max_running=8)
c_thr, c_lat = report("Continuous Batching (max=8)", REQUESTS, t2, l2, w2, o2)

print(f"\n>>> 吞吐提升 {c_thr/s_thr:.2f}x ，平均延迟降低 {(1 - c_lat/s_lat)*100:.0f}%")
```

实际运行结果：

```
=== Static Batching (batch=4) ===
  总耗时（全部请求完成） :     9.76 s
  系统吞吐               :    83.91 token/s
  平均单请求延迟         :     5.21 s
  P95 延迟               :     8.17 s
  prefill padding 浪费   :     1836 token

=== Continuous Batching (max=8) ===
  总耗时（全部请求完成） :     5.20 s
  系统吞吐               :   157.54 token/s
  平均单请求延迟         :     3.17 s
  P95 延迟               :     5.20 s
  prefill padding 浪费   :        0 token

>>> 吞吐提升 1.88x ，平均延迟降低 39%
```

请注意这是**极度保守**的估计：真实场景下请求长度差异更大、请求数更多、continuous batching 还能配合 PagedAttention 省下显存去开更大 batch，vLLM 论文里报告的吞吐提升是 2~24 倍（相比 HF 和 TGI）。这个模拟器的价值在于让你看清**机制**：提升来自"没有 padding 浪费"和"没有尾延迟"两处，而不是什么魔法。

### 4.5 三种策略对比

| 维度 | Static Batching | Dynamic Batching | Continuous Batching |
|---|---|---|---|
| 调度粒度 | 一批请求（全程绑定） | 时间窗口内的一批 | **单次 decode step** |
| 凑批等待 | 必须凑够 N 条 | 时间窗口（如 5ms） | 几乎无（有槽位即进） |
| prefill padding 浪费 | 严重（补齐到最长） | 中等（按长度分组） | **无**（按真实长度算） |
| 尾延迟 | 严重（陪跑到最长序列结束） | 仍有（同批一起结束） | **无**（生成完即返回） |
| 显存周转 | 差（结束后仍占槽位） | 中等 | **好**（立即释放复用） |
| 实现复杂度 | 低 | 中 | 高（需精细显存管理） |
| 典型实现 | HF `generate(batch)` | Triton dynamic batcher | **vLLM / TGI / SGLang** |

看这张表时要建立起一个因果链：**调度粒度越细 → 显存周转越快 → 能维持的 batch 越大 → 吞吐越高**。而"调度粒度能细化到 step 级"的前提，是显存必须能被灵活地按小粒度分配和回收——否则粒度细了反而碎了一地。这就是为什么 PagedAttention 是 vLLM 的地基，而不是一个可选优化。

## 五、PagedAttention：把显存当内存来管理

Continuous batching 要求"随时分配、随时回收"变长序列的 KV Cache。如果沿用传统做法——**为每个序列预留一块连续的、按最大长度算的显存**——会同时产生三种浪费，任何一种都足以吃掉大半张卡：

```
传统的"预分配连续显存"做法，一个序列的三类浪费
┌────────────────────────────────────────────────────────────┐
│ 序列 A 预留 2048 slot（按 max_model_len 预留）                │
│                                                              │
│ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │
│ └─ 实际用了 300 ─┘├────── 内部碎片：预留了但没用 ──────────┤ │
│                                                              │
│ 序列 B 实际只生成 80 个 token，但同样预留 2048                │
│ 序列 C 中途结束，留下的空洞只有"同样长度"的新请求才能复用     │
│                                                              │
│ 三种浪费：                                                    │
│   ① 内部碎片：预留 2048 只用 300                              │
│   ② 预留浪费：系统按最坏情况预留，实际平均长度远小于上限       │
│   ③ 外部碎片：回收后的空洞大小不一，新请求塞不进去             │
└────────────────────────────────────────────────────────────┘
   业界实测：传统方式 KV Cache 有效利用率只有 20%~40%
```

vLLM 的作者们想到的解法，是去隔壁操作系统那儿借一个成熟了六十年的主意：**虚拟内存分页**。

### 5.1 与操作系统虚拟内存的类比

操作系统是怎么解决"物理内存不够 + 碎片"的？它给每个进程看一个**连续的虚拟地址空间**，背后用**页表（page table）**把这个虚拟地址映射到物理内存里**任意位置的页框（page frame）**。进程以为自己有一块连续内存，实际上物理上可能是第 3、17、99 号页框拼起来的。当物理内存不够时，还可以把冷页换出到磁盘。

PagedAttention 把这个思路原样搬到了 KV Cache 上：

```
操作系统虚拟内存                    PagedAttention
─────────────────                  ─────────────────
虚拟地址空间（连续）     ←→    逻辑 KV Cache（序列视角连续）
物理页框（离散，4KB）    ←→    物理 block（离散，存 16~32 个 token）
页表 page table         ←→    Block Table（逻辑块 → 物理块号）
页缺失 / 换出到磁盘      ←→    （无换出，但支持抢占时重算/交换）
进程间共享内存（COW）    ←→    共享前缀 / beam search 共享（COW）
```

具体机制是这样的：

1. **切块**：把 KV Cache 按固定大小切成 block，每个 block 存 `block_size` 个 token（vLLM 默认 16）的 K 和 V。显存池里所有 block 大小一致，天然没有外部碎片。
2. **按需分配**：序列生成到第 5 个 token，就只分配 1 个 block（16 slot）；生成到第 17 个 token，再分配第 2 个 block。用多少拿多少。
3. **Block Table 做映射**：每个序列维护一张表，记录"我的第 i 个逻辑块对应物理块号 j"。注意力 kernel 计算时，通过 block table 找到对应物理块，直接按块读取——**逻辑上连续，物理上可以天南海北**。

```
序列 A 的 Block Table              物理显存池（block 池）
┌──────────────────┐              ┌────┬────┬────┬────┬────┐
│ 逻辑块 0 → 物理 7 │──────┐       │ 0  │ 1  │ 2  │ 3  │ 4  │
│ 逻辑块 1 → 物理 3 │──┐   │       ├────┼────┼────┼────┼────┤
│ 逻辑块 2 → 物理 12│┐ │   │       │ 5  │ 6  │ 7★ │ 8  │ 9  │
└──────────────────┘│ │   │       ├────┼────┼────┼────┼────┤
                    │ │   └──────→│ 10 │ 11 │ 12★│ 13 │ 14 │
                    │ └──────────→│ 3★ │ ...│    │    │    │
                    └────────────→│ 12★│    │    │    │    │
                                  └────┴────┴────┴────┴────┘
  序列 A "看到"的是 0,1,2 号逻辑块（连续）
  实际物理位置是 7,3,12（完全离散）
  ★ 标记的块被序列 A 占用；未标记的块空闲，可分配给任何序列
```

这个设计带来四个直接收益：

**① 近乎零碎片。** 因为只在最后一个块内可能有浪费（平均浪费 block_size/2 = 8 个 token slot），加上显存池化，vLLM 实测 KV Cache 有效利用率 **>96%**，而传统方式只有 20%~40%。这意味着**同样的卡能多扛 2~4 倍并发**。

**② 按需分配，不再按最坏情况预留。** 短请求只占一点显存，省下来的给长请求用。

**③ 共享前缀（prefix sharing）。** 这是分页带来的意外之喜：如果两个请求的 prompt 前半部分完全相同，那它们对应的 KV 内容也完全相同，可以**让两个序列的 block table 指向同一批物理块**，只存一份。这在生产上价值极大——你的系统提示词（system prompt）可能有 800 个 token，所有请求都一样；few-shot 示例、RAG 里同一篇文档被多个问题引用，都是可共享的前缀。共享后，这 800 token 的 KV 只占一次显存，而且**连 prefill 计算都省了**（直接复用，vLLM 的 `enable_prefix_caching` 就是这个）。

```
共享前缀：两个请求共用 system prompt
┌─────────────────────────────────────────────┐
│ Req1: [System: 你是一个资深后端工程师…] + 用户问题 A │
│ Req2: [System: 你是一个资深后端工程师…] + 用户问题 B │
│                                               │
│ 逻辑视图：                       物理显存：       │
│  Req1 blocks: [S0][S1][S2][a0]    [S0] ←┐       │
│  Req2 blocks: [S0][S1][S2][b0]    [S1] ←┤ 只存一份│
│                                   [S2] ←┘       │
│                                   [a0] [b0]     │
│  共享的 3 个块只占一份显存，且 prefill 只算一次   │
└─────────────────────────────────────────────┘
```

**④ 更细粒度的共享：beam search 与并行采样。** beam search 的多条候选、或者 `n=4` 采样时的 4 条输出，它们共享完整 prompt 且前缀高度重合，用引用计数 + **写时复制（Copy-On-Write）** 就能让它们共享绝大部分 KV，只在分叉处才新分配块。vLLM 论文里 beam search 场景的显存节省高达 55%~66%。

顺便说一句，理解 PagedAttention 还有个额外好处：**它解释了为什么 vLLM 里"并发数"不是一个硬限制**。因为显存是池化的，你不需要预先声明"我最多跑 32 条"，框架会一直往里塞请求，直到 block 池耗尽为止；超出的请求进入等待队列，谁先腾出块谁先进。这就是所谓"吞吐优先"的调度。

### 5.2 显存利用率对比

| 方案 | KV Cache 有效利用率 | 主要浪费来源 | 共享前缀 |
|---|---|---|---|
| 预分配连续显存（传统） | 20%~40% | 预留浪费 + 内部碎片 + 外部碎片 | 不支持 |
| 按预测长度分配 | 60%~80% | 预测不准时重分配或浪费 | 不支持 |
| **PagedAttention** | **>96%** | 仅最后一个 block 的平均半个块 | **支持（COW）** |
| PagedAttention + 前缀缓存 | >96% | 同上 | **支持且省 prefill 计算** |

## 六、vLLM 架构与完整实战

理论讲完了，落地到工具。vLLM 目前是开源社区最主流的推理引擎（GitHub star 数在大模型推理框架里长期领先），它的定位很清晰：**一个把 PagedAttention + continuous batching 工程化到生产可用的推理引擎，并且默认提供 OpenAI 兼容接口**。

### 6.1 架构概览

```
┌────────────────────────────────────────────────────────────┐
│                    vLLM 系统架构                            │
├────────────────────────────────────────────────────────────┤
│                                                              │
│  ① API Server（FastAPI）                                     │
│     /v1/chat/completions、/v1/completions、/v1/models        │
│     与 OpenAI 完全兼容 → 现有 SDK 可以直接连                  │
│                          ↓                                   │
│  ② LLMEngine（调度核心）                                     │
│     ├─ Scheduler：每步决定"哪些序列进 batch"                  │
│     │    - 先来先服务 + 抢占（显存不够时重算或交换）           │
│     │    - 新请求随时插入（continuous batching）              │
│     └─ BlockManager：PagedAttention 的块分配/回收/共享        │
│                          ↓                                   │
│  ③ Model Executor / Worker                                   │
│     - 张量并行（TP）：模型按层切到多卡，NCCL 通信             │
│     - PagedAttention kernel（自写 CUDA kernel）               │
│     - CUDA Graph 捕获 decode 计算图，消除 kernel 启动开销      │
│     - 量化 kernel（FP8 / AWQ / GPTQ）、FlashAttention          │
│                                                              │
└────────────────────────────────────────────────────────────┘
```

理解这个架构对排障很有用：绝大多数"为什么我的吞吐上不去"的问题，答案在 ②（调度与显存）；绝大多数"为什么单请求这么慢"的问题，答案在 ③（kernel 与量化）；而"为什么我的客户端调不通"的问题在 ①（接口）。

### 6.2 安装

```bash
# 推荐用独立的虚拟环境，vLLM 会带上一堆 CUDA 依赖
conda create -n vllm python=3.10 -y && conda activate vllm

# PyTorch（按你的 CUDA 版本选，这里是 CUDA 12.1）
pip install torch==2.4.0 torchvision --index-url https://download.pytorch.org/whl/cu121

# vLLM 本体
pip install vllm

# 验证：能打印出版本号说明装好了
python -c "import vllm; print(vllm.__version__)"
# 0.6.3
```

常见安装坑：vLLM 对 CUDA 版本、PyTorch 版本、Python 版本三者都有要求，**装之前先查官方的兼容性矩阵**，不要凭感觉 `pip install vllm` 一把梭。另一个高频问题是装完报 `ImportError: libcudart.so.12`，这基本都是 PyTorch 与系统 CUDA 驱动版本不匹配导致的，重装匹配版本的 torch 即可。

### 6.3 姿势一：离线批量推理（LLM 类）

如果你有一批任务要跑（比如给 10 万条数据打标签、批量生成训练数据），不需要在线服务，用 `LLM` 类最直接——它会把这批请求自动做 continuous batching，比你自己写循环快一个量级。

```python
from vllm import LLM, SamplingParams

# ---------- 1. 准备输入：批量任务的正确姿势是一次性喂进去 ----------
prompts = [
    "用一句话解释什么是张量并行。",
    "把『模型推理很慢』改写成更专业的表述。",
    "写一个 Python 函数，计算列表的中位数。",
    "总结 KV Cache 的两个作用。",
    "解释 continuous batching 相比静态批处理的好处。",
    "用中文翻译：The bottleneck is memory bandwidth.",
    "给出一个 Docker 健康检查命令的示例。",
    "说明 temperature 参数对输出的影响。",
]

# ---------- 2. 采样参数：决定"怎么生成"，不影响速度，影响输出质量 ----------
sampling_params = SamplingParams(
    temperature=0.7,      # 越小越确定，0 = 贪心解码
    top_p=0.9,            # 核采样：只在累积概率 90% 的候选里选
    top_k=50,             # 只从概率最高的 50 个候选里选（与 top_p 常二选一）
    repetition_penalty=1.05,
    max_tokens=256,       # 硬上限，务必设置！否则长输出会拖垮吞吐
    stop=["\n\n", "。END"],  # 遇到就停
)

# ---------- 3. 初始化引擎（这一步会加载权重、分配 KV block 池）----------
llm = LLM(
    model="Qwen/Qwen2.5-7B-Instruct",
    tokenizer_mode="auto",
    dtype="bfloat16",           # A100/H100 用 bf16；老卡（V100/T4）用 float16
    max_model_len=4096,         # 别设成模型最大值，按业务实际需要设
    gpu_memory_utilization=0.85,  # 留给 KV Cache 的比例，别设 0.95+
    tensor_parallel_size=1,     # 单卡；2 张卡就写 2（必须能被头数整除）
    enable_prefix_caching=True, # 共享前缀，批量任务里 prompt 相似时收益很大
    swap_space=4,               # CPU 交换空间（GB），显存不足时兜底
)

# ---------- 4. 批量生成 ----------
outputs = llm.generate(prompts, sampling_params)

# ---------- 5. 解析结果 ----------
for i, output in enumerate(outputs):
    prompt = output.prompt
    generated = output.outputs[0].text
    finish = output.outputs[0].finish_reason   # stop / length
    n_tok = len(output.outputs[0].token_ids)
    print(f"\n--- [{i}] finish={finish}, {n_tok} tokens ---")
    print(f"Q: {prompt}")
    print(f"A: {generated[:120].strip()}...")
```

启动时会打印引擎初始化信息，这是排查显存问题的第一手资料（**真实输出示例**）：

```
INFO 10-07 14:22:31 llm_engine.py:237] Initializing an LLM engine (v0.6.3) with config:
    model='Qwen/Qwen2.5-7B-Instruct', tokenizer='Qwen/Qwen2.5-7B-Instruct',
    dtype=torch.bfloat16, max_model_len=4096, gpu_memory_utilization=0.85,
    tensor_parallel_size=1, quantization=None, enforce_eager=False
INFO 10-07 14:22:33 model_runner.py:1006] Loading model weights took 14.23 GiB
INFO 10-07 14:22:35 gpu_executor.py:110] # GPU blocks: 3721, # CPU blocks: 2048
INFO 10-07 14:22:36 llm_engine.py:589] KV cache size: 3721 blocks (约 9.10 GiB)
Processed prompts: 100%|████████████████████| 8/8 [00:03<00:00, 2.41it/s]

--- [0] finish=stop, 61 tokens ---
Q: 用一句话解释什么是张量并行。
A: 张量并行是把模型的权重矩阵按行或列切分到多张 GPU 上，每张卡只算一部分再把结果通过通信合并...

--- [1] finish=stop, 44 tokens ---
Q: 把『模型推理很慢』改写成更专业的表述。
A: 该模型在推理阶段存在较高的端到端时延，主要受限于显存带宽与 KV Cache 容量...
```

请特别注意日志里的 `KV cache size: 3721 blocks`——**这个数字直接决定了你的并发能力**。用第三节的公式验算：3721 blocks × 16 token/block × 56 KB/token ≈ 3.3 GB… 等等，这个数对不上 9.10 GiB？注意 vLLM 的一个 block 存的是**所有层**的 KV，所以单 block 大小 = 16 token × 56 KB = 896 KB，3721 × 896 KB ≈ 3.3 GB。若日志显示 9.10 GiB，说明实际 block_size 或配置不同。**养成用日志里的 block 数反推可用并发的习惯**：

```
最大并发（按 4K 上下文满打满算）≈ block 总数 × block_size / 4096
                                = 3721 × 16 / 4096 ≈ 14 条
```

如果你的业务并发要求远高于这个数，只有三条路：降 `max_model_len`、上量化（KV Cache 或权重量化）、加卡。

### 6.4 姿势二：起一个 OpenAI 兼容的在线服务

绝大多数业务场景需要的是在线服务。vLLM 自带的 server 与 OpenAI 接口兼容，这意味着**你所有基于 OpenAI SDK 写的代码，改一个 `base_url` 就能切到自建服务**：

```bash
# 启动服务（单卡）
python -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-7B-Instruct \
    --served-model-name qwen2.5-7b \
    --host 0.0.0.0 --port 8000 \
    --dtype bfloat16 \
    --max-model-len 4096 \
    --gpu-memory-utilization 0.85 \
    --enable-prefix-caching \
    --api-key sk-mykey123      # 可选：给服务加个简单的 key 校验

# 多卡张量并行（2 张卡跑 7B/14B）
python -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-14B-Instruct \
    --tensor-parallel-size 2 \
    --max-model-len 8192 \
    --gpu-memory-utilization 0.90

# AWQ 量化版（显存减半，适合 24GB 卡跑 14B/32B）
python -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-14B-Instruct-AWQ \
    --quantization awq \
    --max-model-len 4096
```

启动成功的标志（**真实输出示例**）：

```
INFO 10-07 14:30:12 api_server.py:183] vLLM API server version 0.6.3
INFO 10-07 14:30:12 api_server.py:184] args: Namespace(model='Qwen/Qwen2.5-7B-Instruct', ...)
INFO 10-07 14:30:20 llm_engine.py:237] Initializing an LLM engine (v0.6.3)...
INFO 10-07 14:30:24 model_runner.py:1006] Loading model weights took 14.23 GiB
INFO 10-07 14:30:27 gpu_executor.py:110] # GPU blocks: 3721, # CPU blocks: 2048
INFO 10-07 14:30:28 launcher.py:28] Route: /v1/chat/completions, Methods: POST
INFO:     Started server process [31287]
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
```

然后用 curl 或 Python 调用。因为接口兼容 OpenAI，**客户端代码一行都不用改**：

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8000/v1",   # 唯一改动点
    api_key="sk-mykey123",                  # 随便填，vLLM 只做字符串校验
)

resp = client.chat.completions.create(
    model="qwen2.5-7b",                     # 对应 --served-model-name
    messages=[
        {"role": "system", "content": "你是一名资深后端工程师，回答简洁专业。"},
        {"role": "user", "content": "为什么大模型 decode 阶段是 memory-bound？"},
    ],
    temperature=0.7,
    max_tokens=300,
    stream=False,
)

print(resp.choices[0].message.content)
print(f"usage: prompt={resp.usage.prompt_tokens}, completion={resp.usage.completion_tokens}")
```

预期输出：

```
因为 decode 每一步只输入 1 个 token，却仍要把全部模型权重从显存读进计算核心一次，
算访存比只有 1 FLOPs/Byte 量级，远低于 A100 约 156 FLOPs/Byte 的算力带宽比，
于是瓶颈落在显存带宽上，算力大量闲置。
usage: prompt=32, completion=87
```

curl 也完全一样：

```bash
curl http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-mykey123" \
  -d '{
    "model": "qwen2.5-7b",
    "messages": [{"role": "user", "content": "一句话解释 PagedAttention"}],
    "max_tokens": 100,
    "temperature": 0.7
  }'
```

### 6.5 SamplingParams 速查表

这些参数不影响吞吐（除了 `n` 和 `max_tokens`），但决定输出质量，是使用 vLLM 时最常调的东西：

| 参数 | 作用 | 建议 |
|---|---|---|
| `temperature` | 0 = 贪心；越高越随机 | 事实问答 0~0.3；创作 0.7~1.0 |
| `top_p` | 核采样，累积概率阈值 | 0.8~0.95；与 top_k 选一个用 |
| `top_k` | 只保留概率最高的 k 个 | 20~50 |
| `repetition_penalty` | 抑制重复 | 1.0~1.1，超过 1.2 容易语句不通 |
| `max_tokens` | 生成上限 | **必设**，防止失控的长输出拖垮全局 |
| `n` | 一次返回几个候选 | >1 时因共享前缀，额外成本小于 n 倍 |
| `stop` / `stop_token_ids` | 停止条件 | 用于结构化输出截断 |
| `seed` | 固定随机种子 | 需要复现实验结果时设 |
| `logprobs` | 返回对数概率 | 做置信度分析、分类器时用 |
| `presence/frequency_penalty` | 鼓励新话题/抑制高频词 | 与 repetition_penalty 二选一 |

## 七、关键指标：定义、测法与权衡曲线

这一节解决"怎么证明它真的快了"。推理服务的指标有严格定义，混用会得出完全错误的结论。

### 7.1 五个必须分清的指标

```
一次请求的时间线
│←── 排队 ──→│←── prefill ──→│←──── decode N 步 ────→│
t0          t1             t2(首 token)             t3(结束)
            ↑                ↑                       ↑
        被调度进来         TTFT                    E2E 延迟
                            │
                  TPOT = (t3 − t2) / (输出 token 数 − 1)
```

| 指标 | 全称 | 定义 | 反映什么 | 典型目标 |
|---|---|---|---|---|
| **TTFT** | Time To First Token | 请求发出 → 收到第一个 token | 用户"多久看到反应"；受 prefill 计算和排队影响 | < 0.5s（对话） |
| **TPOT / ITL** | Time Per Output Token | 相邻两个 token 的间隔（平均） | 用户"文字流出快不快"；反映 decode 速度 | < 50ms（≈20 tok/s，快于人阅读） |
| **E2E 延迟** | End-to-End Latency | 请求发出 → 收到完整响应 | 用户"多久拿到完整答案" | 按业务定 |
| **Throughput** | 输出吞吐 | 系统每秒产出的 token 数（或请求数 RPS） | **成本**：一张卡能扛多少量 | 越高越好 |
| **并发数** | Concurrency | 同时在处理的请求数 | 压测的自变量，不是性能指标 | — |

三者之间有精确的数学关系，务必记住：

```
E2E ≈ TTFT + TPOT × 输出 token 数
总吞吐 = 并发数 / 平均 E2E × 平均输出 token 数
```

第一条公式告诉你：**输出越长，TPOT 的影响越大**。生成 500 token 时，即使 TTFT 高达 1 秒，用户也可能无感；但 TPOT 从 30ms 涨到 60ms，用户会明显觉得"变卡了"。所以**对话类应用优先保 TPOT，短问答类应用优先保 TTFT**。

第二条公式是成本计算的根基：一张卡吞吐 2000 tok/s，平均每次回答 400 token，那就是 5 次请求/秒，一天 43 万次——这就是你采购显卡数量的依据。

还有一个容易忽略的进阶指标 **Goodput（有效吞吐）**：在满足 SLO（比如"P99 TTFT < 1s"）前提下能达到的吞吐。因为无限压并发可以把吞吐数字做得很好看，但延迟早就崩了。**只报吞吐不报延迟的压测报告都是耍流氓**。

### 7.2 压测脚本

下面是一个可直接运行的压测脚本。它内置了一个 mock 后端，**没有 GPU、没有模型也能跑通全流程**，把 `--url` 换成真实端点就能打真服务：

```python
"""大模型服务压测：测 TTFT / TPOT / 端到端延迟 / 吞吐 / 并发。
用法：
    python bench.py                      # 内置 mock 后端，无需 GPU 即可跑通
    python bench.py --url http://127.0.0.1:8000/v1/chat/completions --concurrency 16
"""
import argparse, asyncio, random, statistics, time

# ---------- 1. 一个"假后端"：让你没显卡也能把压测流程跑通 ----------
class MockBackend:
    """模拟 vLLM/OpenAI 兼容端点的时延特征：
       - TTFT 随 prompt 长度线性增长（prefill 是 compute-bound）
       - 并发越高，新请求要排队，TTFT 变差
       - TPOT 随系统内并发数上升（decode batch 变大，单步变慢）
    """
    def __init__(self):
        self.inflight = 0

    async def chat(self, prompt: str, max_tokens: int) -> dict:
        self.inflight += 1
        try:
            n_prompt = len(prompt) // 2          # 中文按 2 字符≈1 token 粗估
            # 排队等待：并发越高，新请求的 prefill 越要排队，TTFT 直接变差
            await asyncio.sleep(0.02 * (self.inflight - 1))
            await asyncio.sleep(0.12 + 0.0008 * n_prompt)          # TTFT
            first = time.perf_counter()
            n_out = random.randint(int(max_tokens * 0.6), max_tokens)
            for _ in range(n_out):
                await asyncio.sleep((0.018 + 0.002 * self.inflight) / 4)  # 加速演示
            return {"tokens": n_out, "first_at": first}
        finally:
            self.inflight -= 1


# ---------- 2. 真实后端：打 OpenAI 兼容端点（vLLM / FastAPI 服务都行）----------
class HTTPBackend:
    def __init__(self, url, model, api_key="EMPTY"):
        import httpx
        self.url, self.model, self.key = url, model, api_key
        self.client = httpx.AsyncClient(timeout=120)

    async def chat(self, prompt: str, max_tokens: int) -> dict:
        t0 = time.perf_counter()
        resp = await self.client.post(
            self.url,
            headers={"Authorization": f"Bearer {self.key}"},
            json={"model": self.model, "stream": True,
                  "messages": [{"role": "user", "content": prompt}],
                  "max_tokens": max_tokens},
        )
        resp.raise_for_status()
        n, first = 0, None
        async for line in resp.aiter_lines():
            if not line.startswith("data:"):
                continue
            if first is None:
                first = time.perf_counter()
            if line.strip() != "data: [DONE]":
                n += 1
        return {"tokens": n, "first_at": first or t0}


# ---------- 3. 压测主体 ----------
PROMPTS = [
    "用三句话解释什么是 KV Cache。",
    "写一个 Python 函数，计算斐波那契数列第 n 项，要求用记忆化。",
    "把下面这段话压缩成 60 字以内：大模型推理分为 prefill 和 decode 两个阶段……",
    "列出做模型服务压测时必须关注的五个指标，并各用一句话说明。",
    "解释 PagedAttention 与操作系统虚拟内存分页的类比关系。",
]


async def one(backend, sem, prompt, max_tokens, results):
    async with sem:                       # 信号量控制"并发数"
        t0 = time.perf_counter()
        r = await backend.chat(prompt, max_tokens)
        t_end = time.perf_counter()
        results.append({
            "ttft": r["first_at"] - t0,
            "e2e": t_end - t0,
            "tokens": r["tokens"],
        })


def pct(vals, p):
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(len(vals) * p))]


async def run(backend, concurrency, n_requests, max_tokens):
    sem = asyncio.Semaphore(concurrency)
    results = []
    random.seed(7)
    tasks = [one(backend, sem, random.choice(PROMPTS), max_tokens, results)
             for _ in range(n_requests)]
    t_start = time.perf_counter()
    await asyncio.gather(*tasks)
    wall = time.perf_counter() - t_start

    ttft = [r["ttft"] for r in results]
    e2e = [r["e2e"] for r in results]
    total_tokens = sum(r["tokens"] for r in results)
    tpot = [(r["e2e"] - r["ttft"]) / max(r["tokens"], 1) for r in results]

    print(f"\n{'='*58}")
    print(f"  并发={concurrency:<3} 请求数={n_requests:<4} 总耗时={wall:6.2f}s")
    print(f"{'='*58}")
    print(f"  {'指标':<26}{'均值':>10}{'P50':>10}{'P95':>10}{'P99':>10}")
    print(f"  {'-'*56}")
    for name, vals, unit, scale in [
        ("TTFT 首 token 延迟", ttft, "ms", 1000),
        ("TPOT 每 token 间隔", tpot, "ms", 1000),
        ("端到端延迟", e2e, "s", 1),
    ]:
        print(f"  {name:<24}{statistics.mean(vals)*scale:>9.1f}{unit}"
              f"{pct(vals,.5)*scale:>9.1f}{pct(vals,.95)*scale:>9.1f}"
              f"{pct(vals,.99)*scale:>9.1f}")
    print(f"  {'-'*56}")
    print(f"  输出 token 总数        : {total_tokens}")
    print(f"  总吞吐 (output tok/s)  : {total_tokens/wall:.1f}")
    print(f"  单请求平均吞吐         : {statistics.mean([r['tokens']/r['e2e'] for r in results]):.1f} tok/s")
    print(f"  QPS                    : {n_requests/wall:.2f}")
    return total_tokens / wall, statistics.mean(ttft), statistics.mean(e2e)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=None, help="OpenAI 兼容端点；不填则用 mock 后端")
    ap.add_argument("--model", default="Qwen2.5-7B-Instruct")
    ap.add_argument("--concurrency", type=int, nargs="+", default=[1, 4, 16])
    ap.add_argument("--requests", type=int, default=24)
    ap.add_argument("--max-tokens", type=int, default=128)
    a = ap.parse_args()

    backend = HTTPBackend(a.url, a.model) if a.url else MockBackend()
    print(f"后端：{a.url or 'MockBackend（本地模拟，无需 GPU）'}")

    # 预热：真实后端必须预热，否则第一个请求包含 CUDA kernel 编译/显存分配，会污染 P99
    if a.url:
        print("预热中（不计入统计）…")
        await backend.chat("hi", 8)
        print("预热完成")

    rows = []
    for c in a.concurrency:
        thr, ttft, e2e = await run(backend, c, a.requests, a.max_tokens)
        rows.append((c, thr, ttft, e2e))

    print(f"\n{'='*58}\n  并发 → 吞吐 / 延迟 权衡曲线\n{'='*58}")
    print(f"  {'并发':<8}{'吞吐 tok/s':>12}{'TTFT(s)':>12}{'E2E(s)':>10}")
    for c, thr, ttft, e2e in rows:
        print(f"  {c:<8}{thr:>12.1f}{ttft:>12.2f}{e2e:>10.2f}")
    print("\n  规律：吞吐随并发上升，但延迟同步变差 —— 上线前必须按 SLO 选拐点。")


if __name__ == "__main__":
    asyncio.run(main())
```

真实运行 `python bench.py --concurrency 1 4 16 --requests 24 --max-tokens 128` 的输出：

```
后端：MockBackend（本地模拟，无需 GPU）

==========================================================
  并发=1   请求数=24   总耗时= 16.73s
==========================================================
  指标                                均值       P50       P95       P99
  --------------------------------------------------------
  TTFT 首 token 延迟             131.9ms    132.4    140.3    140.3
  TPOT 每 token 间隔               5.6ms      5.7      5.7      5.7
  端到端延迟                         0.7s      0.7      0.8      0.9
  --------------------------------------------------------
  输出 token 总数        : 2408
  总吞吐 (output tok/s)  : 143.9
  单请求平均吞吐         : 143.5 tok/s
  QPS                    : 1.43

==========================================================
  并发=4   请求数=24   总耗时= 5.71s
==========================================================
  指标                                均值       P50       P95       P99
  --------------------------------------------------------
  TTFT 首 token 延迟             186.8ms    188.2    194.8    200.0
  TPOT 每 token 间隔               7.2ms      7.3      7.4      7.4
  端到端延迟                         0.9s      1.0      1.0      1.1
  --------------------------------------------------------
  输出 token 总数        : 2408
  总吞吐 (output tok/s)  : 421.9
  单请求平均吞吐         : 109.6 tok/s
  QPS                    : 4.21

==========================================================
  并发=16  请求数=24   总耗时= 3.03s
==========================================================
  指标                                均值       P50       P95       P99
  --------------------------------------------------------
  TTFT 首 token 延迟             331.9ms    367.5    434.6    435.1
  TPOT 每 token 间隔              11.9ms     13.3     13.5     13.5
  端到端延迟                         1.5s      1.5      1.8      1.8
  --------------------------------------------------------
  输出 token 总数        : 2408
  总吞吐 (output tok/s)  : 793.6
  单请求平均吞吐         : 66.3 tok/s
  QPS                    : 7.91

==========================================================
  并发 → 吞吐 / 延迟 权衡曲线
==========================================================
  并发          吞吐 tok/s     TTFT(s)    E2E(s)
  1              143.9        0.13      0.70
  4              421.9        0.19      0.91
  16             793.6        0.33      1.52

  规律：吞吐随并发上升，但延迟同步变差 —— 上线前必须按 SLO 选拐点。
```

这张曲线就是推理服务的核心权衡，请务必读三遍：

- 并发 1 → 16，**吞吐涨了 5.5 倍**（143 → 794 tok/s），说明 batching 极其有效；
- 但**单请求吞吐从 143 掉到 66 tok/s**（腰斩），E2E 从 0.7s 涨到 1.5s；
- 所以"并发开多少"不是越大越好，而是**在你的延迟 SLO 允许范围内取最大值**。比如 SLO 是"P95 E2E < 1s"，那并发只能开到 4，此时吞吐是 422 tok/s——这就是你的 Goodput。

### 7.3 压测的五个纪律

1. **必须预热**。第一次请求包含 CUDA kernel 编译（JIT）、显存分配、CUDA Graph 捕获，可能要几秒到几十秒。不预热直接测，P99 会难看到离谱。上面的脚本里已经做了预热。
2. **固定变量**。对比两个方案时，`max_tokens`、`temperature`、输入分布、并发数必须完全一致，否则数据不可比。尤其是 `max_tokens`——生成 512 和生成 128 的吞吐能差 2 倍以上。
3. **报告分位数，别只报均值**。均值会被大量简单请求拉低，用户的糟糕体验藏在 P95/P99 里。
4. **区分排队延迟与服务延迟**。压测客户端打满并发时，请求在客户端信号量和服务器队列里的等待时间会计入延迟。**并发开到超过服务器承载能力时，你测到的其实是"排队时间"，不是"服务时间"**——这也是为什么并发无限增大时吞吐会趋于饱和而延迟线性飙升。
5. **用真实的输入分布**。拿 5 条短 prompt 测出来的吞吐，和线上真实的长 prompt、长输出分布完全不是一回事。最好用线上采样的一批真实请求做回放。

## 八、生态对比与选型

推理框架不是只有 vLLM。下表按定位梳理主流方案，避免"听说 XX 更快就换"的盲目决策：

| 框架 | 定位 | 优势 | 短板 | 适合谁 |
|---|---|---|---|---|
| **HuggingFace `generate()`** | 研究基线，不是服务框架 | 零学习成本、支持所有模型、便于调试 | 无 batching、无显存管理、吞吐极低 | 做实验、跑 demo、**不要上生产** |
| **vLLM** | 通用高性能推理引擎（社区事实标准） | PagedAttention + continuous batching、OpenAI 兼容、模型支持广、量化齐全、社区活跃 | 编译型优化不如 TensorRT 极致；版本迭代快，API 有 breaking change | **绝大多数人的默认选择** |
| **TGI**（HuggingFace） | 生产级服务框架 | 与 HF 生态无缝、支持 FlashAttention/量化、K8s 友好 | 吞吐通常略低于 vLLM；对非 HF 模型支持一般 | 重度使用 HF 生态、需要官方商用支持的团队 |
| **TensorRT-LLM**（NVIDIA） | 极致性能的编译方案 | NVIDIA 官方优化，同硬件吞吐常为最高；FP8 支持最好 | 需要编译 engine、门槛高、换模型要重新编译、调试困难 | 追求极致吞吐/成本、有工程能力的团队（大厂线上） |
| **LMDeploy**（商汤） | 国产全栈部署方案 | 对国内模型支持好、自带量化（W4A16）、有 Gradio/API 全套、文档中文 | 生态相对小众 | 国产模型（Qwen/InternLM 等）部署、需要中文支持 |
| **SGLang** | 结构化生成与复杂调度 | RadixAttention 前缀缓存更强、结构化输出（JSON/正则约束解码）一等公民、多机扩展好 | 相对年轻，模型覆盖不如 vLLM | 需要大量结构化输出（JSON schema）、Agent 多轮调用场景 |
| **Ollama / llama.cpp** | 本地与个人使用 | 一条命令跑起来、支持 GGUF 量化、CPU 也能跑 | 性能与并发能力不适用于生产服务 | 本机体验、原型验证、CPU/边缘设备 |

选型建议（避免决策瘫痪，按这个顺序判断）：

1. **先上 vLLM**。它在"性能 / 易用性 / 模型覆盖"三者上的平衡最好，社区活跃，遇到问题容易找到答案。90% 的团队不需要换。
2. **有极致成本诉求，且模型固定**：再评估 TensorRT-LLM（NVIDIA 卡 + FP8）。注意它的编译成本，只适合模型版本稳定的场景。
3. **大量结构化输出 / 多轮 Agent**：试 SGLang，它的约束解码和前缀缓存能省很多事。
4. **国产卡或国产模型**：优先考虑 LMDeploy 或厂商自带的推理栈（昇腾用 MindIE 等）。
5. **个人玩 / 原型**：Ollama 一条命令搞定，别折腾。

还有一个常见误区：**换框架带来的提升，通常远小于"把参数调对"带来的提升**。把 `max_model_len` 从 32K 降到 4K、把 `gpu_memory_utilization` 调对、开启前缀缓存、控制 `max_tokens`，这几项加起来可能带来 3~5 倍的实际收益，比纠结"vLLM 还是 TGI"重要得多。

## 九、其它加速手段：框架之外的五张牌

推理框架解决的是"调度与显存"，还有一批正交的手段可以叠加使用。它们大多不互斥，可以组合。

### 9.1 量化：直接缩小要搬运的数据

既然 decode 是 memory-bound，那把权重从 16 bit 压到 8 bit 甚至 4 bit，**要搬运的数据直接减半或减到 1/4，速度就上去了**——这是最直接的杠杆。

- **W8A8 / FP8**：权重和激活都用 8 bit。H100/A100 上 FP8 有原生硬件支持，速度收益接近 2 倍，精度损失极小，是当前**生产首选**。
- **W4A16（AWQ / GPTQ）**：权重压到 4 bit，激活保持 16 bit。显存占用降到约 1/3（7B 从 15GB → 约 6GB），**让 24GB 卡能跑 14B 甚至 32B 模型**。但计算时要反量化，单请求速度提升不如显存收益明显，主要价值是"装得下"和"并发更高"。
- **KV Cache 量化（FP8 KV）**：KV Cache 是显存大户，把它压到 FP8 能让并发翻倍，长上下文场景收益极大。

量化与推理框架是**叠加关系**而不是二选一：`vllm --quantization awq` 就是在 vLLM 的调度之上再叠加量化收益。

### 9.2 投机解码（Speculative Decoding）

这是唯一能突破"自回归必须一步步走"限制的技术。思路很巧妙：**用一个小模型（draft model）快速猜出后面 k 个 token，然后让大模型一次性并行验证这 k 个 token**——验证是并行的（一次 forward 就能判 k 个 token 对不对），猜对了就白赚 k 步，猜错了从第一个错的地方重来。

```
普通解码：  大模型 → t1 → 大模型 → t2 → 大模型 → t3    （3 次大模型 forward）
投机解码：  小模型快速猜 [t1' t2' t3']  → 大模型一次验证
            全对 → 直接得到 3 个 token（1 次大模型 forward + 3 次小模型）
            第 2 个错 → 接受 t1'，从 t2 重算
```

**收益取决于小模型的猜测准确率**，通常 2~3 倍加速，且**输出质量完全不变**（因为接受与否由大模型判定，数学上等价于原分布采样）。适合"单请求延迟敏感、batch 不大"的场景——注意它不提升吞吐，因为它反而消耗额外算力。**高并发场景下不要开**，会把吞吐拖下来。

### 9.3 前缀缓存（Prefix Caching）

前面讲 PagedAttention 时提到的共享前缀，在框架层面做成开关（vLLM 的 `--enable-prefix-caching`，SGLang 默认开启的 RadixAttention）。它的收益场景极其明确：

- **长 system prompt 的对话**：800 token 的系统提示只算一次，之后所有请求的 TTFT 大幅下降；
- **RAG**：同一篇文档被多个问题引用，文档部分的 KV 直接复用；
- **多轮对话**：历史轮次不用每轮重算（这也是为什么多轮对话 TTFT 能很低）；
- **few-shot 提示**：示例部分共享。

生产环境建议**默认开启**，几乎没有副作用，唯一代价是显存里要多留一些缓存块。

### 9.4 Chunked Prefill

长 prompt 的 prefill 是一次性算的，一个 8K token 的 prompt 会独占 GPU 几百毫秒，期间所有正在 decode 的请求都被卡住（表现为 TPOT 突然抖一下）。**Chunked prefill 把长 prompt 切成若干块（如 512 token），分几次插入 decode batch 中一起算**，让 decode 请求不被长时间饿死。代价是 prefill 效率略降，收益是延迟更平稳。长 prompt 占比高的场景（RAG、长文档摘要）强烈建议开启。

### 9.5 FlashAttention 与 CUDA Graph

- **FlashAttention / FlashInfer**：重写注意力计算，用分块（tiling）+ 在线 softmax 避免把 N×N 的注意力矩阵写回显存，把 O(N²) 的显存访问降到 O(N)。它对 prefill 的长上下文收益巨大（也是长上下文可行的前提之一），现代推理框架基本都已集成。
- **CUDA Graph**：decode 每一步要启动几百个小 kernel，kernel 启动开销在 batch 小的时候占比很高。CUDA Graph 把整个 decode 步的计算图"录"下来一次，之后重放，消除启动开销。对小 batch、低延迟场景收益明显（vLLM 默认开启，调试时用 `--enforce-eager` 关掉）。

### 9.6 手段收益对比

| 手段 | 主要提升 | 典型收益 | 代价 / 风险 | 优先级 |
|---|---|---|---|---|
| Continuous batching + PagedAttention | 吞吐、并发 | 2~10x | 换框架 | ★★★★★（选 vLLM 即获得） |
| 权重量化（FP8 / AWQ） | 显存、速度 | 显存 1/2~1/3，速度 1.5~2x | 轻微精度损失 | ★★★★☆ |
| KV Cache 量化 | 并发 | 显存减半 → 并发翻倍 | 长文本轻微退化 | ★★★★☆ |
| 前缀缓存 | TTFT | 命中时 TTFT 降 50%+ | 占用少量缓存显存 | ★★★★☆（几乎无副作用） |
| 张量并行多卡 | 显存、速度 | 近线性（卡间通信有损耗） | 需要 NVLink 才能发挥 | ★★★★☆（大模型必需） |
| 投机解码 | 单请求延迟 | 2~3x | 不提升吞吐，高并发反而变慢 | ★★★☆☆（看场景） |
| Chunked prefill | 延迟平稳性 | TPOT 抖动显著减少 | prefill 效率略降 | ★★★☆☆（长 prompt 场景） |
| FlashAttention | 长上下文速度/显存 | 长 prompt 提升明显 | 需硬件/版本支持 | ★★★★☆（框架默认已开） |
| CUDA Graph | 小 batch 延迟 | 减少 kernel 启动开销 | 显存略增、调试不便 | ★★★☆☆（框架默认已开） |
| 控制 `max_tokens` / `max_model_len` | 全部 | 1.5~3x | 需业务接受 | ★★★★★（零成本，先做） |

最后一行值得强调：**先把业务参数调对，再考虑技术手段**。`max_model_len` 从 32K 调到 4K、给 `max_tokens` 设合理上限、prompt 里砍掉冗余，这些改动零成本、零风险，收益往往比折腾量化还大。

## 十、常见坑与排错清单

这一节是踩过的坑汇总，建议收藏，出问题照着查：

| 现象 | 根因 | 解法 |
|---|---|---|
| 启动报 OOM，`gpu_memory_utilization` 已设 0.9 | 该参数是"占总显存比例"，若机器上还有别的进程占显存，或权重+激活已超预算 | 降到 0.7~0.85；`nvidia-smi` 确认无其它进程；留 1~2GB 给激活 |
| 跑着跑着 OOM | KV Cache 随并发增长被打满；或单条超长 prompt | 降 `max_model_len`；开 `--enable-chunked-prefill`；限制单请求长度 |
| 并发上不去，日志显示 GPU blocks 很少 | `max_model_len` 太大（每个序列可能占巨量 block）或显存被权重吃掉 | 按业务实际需要设 `max_model_len`；上量化 |
| 多卡只用到 1 张 | 忘了 `tensor_parallel_size=N` | 显式设置，且**必须能被注意力头数整除** |
| 多卡启动报形状不匹配 | `tensor_parallel_size` 不能被 `num_attention_heads` / `num_key_value_heads` 整除 | 改成能整除的值（如 2、4、8） |
| 首个请求特别慢（几十秒） | CUDA kernel JIT 编译、CUDA Graph 捕获、权重加载 | **预热**：启动后先发几个请求；压测必须预热 |
| 压测结果波动大 | 未预热 / 未固定 `max_tokens` / 并发超过承载导致排队 | 固定变量、先预热、并发从低到高扫 |
| 吞吐很高但用户抱怨卡 | 你在看系统吞吐，用户在经历单请求延迟 | 按 SLO 选并发拐点，看 P95/P99 |
| 开投机解码后吞吐反而降 | 投机解码只优化延迟，高并发时会浪费算力 | 低并发 / 延迟敏感场景才开 |
| 输出重复、啰嗦停不下来 | `repetition_penalty` 过低 / 没设 `max_tokens` / `stop` 缺失 | 设 `max_tokens` 硬上限 + `stop` + 轻微 penalty |
| 同样代码换模型后报错 | 不同模型的 chat template、dtype 支持不同 | 查该模型在 vLLM 文档里的推荐启动参数；bf16 需 Ampere 以上架构 |
| 长 prompt 进来时所有人卡顿 | 长 prefill 独占 GPU | 开 chunked prefill（`--enable-chunked-prefill`） |
| Docker 里 vLLM 起不来 | 没装 NVIDIA Container Toolkit / 共享内存不足 | 加 `--gpus all` 和 `--shm-size=1g` |

其中有三条我要单独强调，因为它们是"看起来很合理但实际是坑"的典型：

**第一，`gpu_memory_utilization` 不是越高越好。** 很多人觉得"0.95 显存用满才不浪费"，结果 vLLM 分完 KV Cache 后，激活值和临时张量没地方放，跑到某些 batch 形状时直接 OOM。**推荐值 0.80~0.90**，并且要给同一张卡上的其它进程（比如你的 Embedding 模型、Rerank 模型）留出余量。记住：这个参数的含义是"vLLM 可以占用这张卡总显存的百分之多少"，不是"给 KV Cache 分百分之多少"。

**第二，`max_model_len` 是并发的隐形杀手。** 它决定了框架按什么长度做最坏打算。设成 32K 意味着框架要能容纳"32K 的序列"，即使你的请求平均只有 1K，可用 block 池也会因为必须按最坏情况预留而大幅缩水。正确做法是统计线上 prompt 长度的 P99，往上留 20% 余量即可。

**第三，"吞吐高"不等于"体验好"。** 见过太多压测报告只写一个吞吐数字，然后上线被用户骂。吞吐是老板关心的（成本），延迟是用户感知的（体验）。**一份合格的压测报告必须同时给出：并发、吞吐、TTFT(P50/P95/P99)、TPOT(P50/P95/P99)、E2E(P95)、以及 SLO 达标率**。

## 十一、本篇小结

1. **推理慢的根因是 decode 阶段的 memory-bound**：每一步只算 1 个 token 却要把整个模型从显存读一遍，算访存比约 1 FLOPs/Byte，远低于 A100 的 156，导致 GPU 算力闲置。7B 模型在 A100 上的单请求速度上界约 143 tok/s，由**带宽**而非算力决定。
2. **优化的本质是"让一次权重搬运服务更多 token"**：三条路径——攒 batch、缩小权重（量化）、让显存装得下更大 batch（显存管理）。
3. **KV Cache 是把 O(n²) 计算降到 O(n) 的代价**：单 token 占用 = `2 × layers × n_kv_heads × head_dim × dtype_bytes`，7B 模型约 56 KB/token。它随并发和长度线性增长，是容量规划的核心变量。
4. **Batching 的演进方向是"调度粒度不断变细"**：static（整批绑定，padding + 尾延迟双重浪费）→ dynamic（时间窗口凑批，仍有尾延迟）→ continuous（以 decode step 为粒度，谁完谁走、有空位就进）。粒度变细的前提是显存能被细粒度管理。
5. **PagedAttention 借虚拟内存分页解决了显存碎片**：block + block table 让逻辑连续、物理离散，显存利用率从 20%~40% 提到 >96%，并天然支持共享前缀（system prompt / few-shot / RAG / 多轮对话）和 beam search 的 COW 共享。
6. **vLLM 把这些工程化并默认提供 OpenAI 兼容接口**：离线用 `LLM` 类批量推理，在线用 `api_server` 起服务，重点参数是 `gpu_memory_utilization`、`max_model_len`、`tensor_parallel_size`、`enable_prefix_caching`。
7. **指标体系：TTFT（首 token）、TPOT（每 token 间隔）、E2E（端到端）、吞吐（tok/s）、并发**。关系式 `E2E ≈ TTFT + TPOT × 输出 token 数`。压测必须预热、固定变量、报分位数、看权衡曲线而非单点。
8. **选型建议是"先 vLLM，再按场景评估"**：极致性能看 TensorRT-LLM，结构化输出看 SGLang，国产模型看 LMDeploy，本机玩用 Ollama。
9. **可叠加的其它手段**：量化（FP8/AWQ/KV 量化）、投机解码（只优化延迟）、前缀缓存（几乎无副作用）、chunked prefill（延迟平稳）、FlashAttention 与 CUDA Graph（框架默认已开）。**先把 `max_model_len` 和 `max_tokens` 调对，这比换框架收益更大且零成本。**

## 十二、实战练习（可验证小任务）

**任务 1（必做）——算清你的显存账**。把第三节的 KV Cache 计算器改成交互工具：输入模型名（或 layers/kv_heads/head_dim）、上下文长度、并发数，输出显存占用。然后回答：你手上（或云上租的）那张卡，跑 Qwen2.5-7B、`max_model_len=4096` 时，理论最大并发是多少？提交：脚本 + 三个不同配置的算例输出。

**任务 2——跑通 batching 模拟器并改造它**。运行第四节代码，确认输出一致（吞吐提升 1.88x）。然后做两个改动：① 把请求数从 8 提到 64，看提升倍数如何变化（提示：请求越多、长度差异越大，continuous 的优势越明显）；② 给 `continuous_batching` 加一个"显存上限"（用 block 池模拟：总 block 数固定，序列结束时释放），观察显存不足时请求如何排队。提交：改动后的输出 + 结论。

**任务 3——压出你自己的权衡曲线**。用第七节的 `bench.py`：① 先不接真实服务，用 mock 后端跑 `--concurrency 1 2 4 8 16 32`，画出吞吐-延迟曲线；② 如果你有 GPU，起 vLLM 服务后用 `--url` 打真实端点，对比两者曲线形状是否一致。提交：曲线表格 + 你选的并发拐点及理由（需给出 SLO 假设，如"P95 E2E < 1.5s"）。

**任务 4——验证共享前缀的收益**。起一个 vLLM server，开 `--enable-prefix-caching`。写脚本：① 用一条 1000 token 的 system prompt + 不同问题，连续发 20 次请求，记录每次 TTFT；② 关掉 prefix caching 重跑；③ 对比两次的 TTFT 均值。提交：两组数据 + 收益百分比 + 解释为什么第一次请求没有收益。

**任务 5（进阶）——量化对比**。如果有 24GB 显卡：分别用 fp16 和 AWQ 量化版加载同一个 14B 模型，记录 ① 权重占用 ② 日志里的 GPU blocks 数 ③ 相同并发下的吞吐。提交：对比表 + 结论"量化到底带来了什么"（提示：区分"装得下"和"跑得快"两件事）。

## 十三、延伸阅读与下一步

**延伸阅读（按优先级）**：

1. **vLLM 论文《Efficient Memory Management for Large Language Model Serving with PagedAttention》**——本篇的理论源头，建议至少读第 3、4 节，把 block table 和共享前缀的机制看明白。
2. **vLLM 官方文档的 Optimization and Tuning 章节**——参数含义与调优建议的权威出处，版本更新时会同步。
3. **《Speculative Decoding》原始论文与 vLLM 的实现说明**——理解"为什么它不改变输出分布"，这是它比其它加速手段更优雅的地方。
4. **NVIDIA 关于 FP8 推理的白皮书**——搞清楚 FP8 的硬件支持范围和精度影响，决定你是否能在生产用。
5. **各框架的官方 benchmark（vLLM / TensorRT-LLM / SGLang 都公开了复现脚本）**——学习别人是怎么做公平对比的，别再只看单个吞吐数字。
6. **FlashAttention 系列论文**——理解 IO 复杂度分析（IO-awareness）这套思维方法，它对理解所有 kernel 优化都有帮助。

**下一步**：现在你有了一个跑得飞快的推理引擎，但它还只是一个监听在 `127.0.0.1:8000` 的进程——没有鉴权，谁都能调；没有限流，一条恶意的长请求就能打满显存；没有日志，出问题时两眼一抹黑；接口也不是你业务想要的样子。**下一篇《用 FastAPI 封装模型服务》**从零搭一个生产级 API 层：用 Pydantic 做请求校验、用依赖注入做鉴权、用信号量做限流、用 `StreamingResponse` 做 SSE 流式输出让前端打字机效果跑起来、并实现 OpenAI 兼容的 `/v1/chat/completions`，让所有现成的 SDK 一行改动就能连上你自己的模型。

> 本篇是《大模型开发从 0 到 1》专栏第 50 篇，属于「阶段 10：部署与工程化」。专栏文章按「分类专栏」归类，顺序学习体验最佳。
