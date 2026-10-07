<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 量化——INT8 与 INT4，GPTQ 与 AWQ

**承上**：上一篇《LoRA 与 QLoRA——用消费级显卡微调大模型》用 NF4 + 分页优化器把 7B 模型塞进了单张消费级显卡，但留下一个没解决的问题：训练完成后的模型依然是 FP16 体量，部署时照样面临"显存装不下、推理慢、并发上不去"。

**本篇**：本篇把量化这件事从"调一个参数"升级为"能算账、能选方案、能判断结果好坏"，讲清显存账本与带宽瓶颈、量化映射与校准粒度、PTQ 与 QAT 的取舍，并手撕 GPTQ 与 AWQ 两个主流算法的核心机制。

**启下**：下一篇《训练监控与评估——loss 曲线与评测集》会解决另一个隐蔽的灾难源：模型训出来了，你怎么知道它到底变好了还是变坏了。

**学完这一节，你能动手做**：

1. 能算出任意规模模型在 FP16 / INT8 / INT4 下的权重显存、KV Cache 显存，以及 batch=1 解码的带宽理论上限。
2. 能写出一个可运行的量化器，量化粒度（per-tensor / per-channel / per-group）与校准策略（min-max / 百分位 / KL）亲手对比出差异。
3. 能跑通 GPTQ 的 Hessian 误差补偿与 AWQ 的激活感知缩放两个极简复现，并看懂两者为什么"都不需要反向传播"。
4. 能用 transformers 加载 4bit 模型并叠加 QLoRA 适配器，同时判断该用 bitsandbytes、auto-gptq、autoawq 还是 GGUF。

---

## 一、为什么大模型非量化不可

### 1.1 把"装不下"翻译成三笔账

很多同学第一次接触量化，是被一句"7B 模型 FP16 要 14GB 显存"劝退的。但这句口号只算了第一笔账。真正决定你能不能跑起来的是三笔账叠在一起：权重、KV Cache、训练期的优化器状态。

先说权重。FP16 每个参数 2 字节，INT8 是 1 字节，INT4 是 0.5 字节。7B 参数在 FP16 下是 14GB（严格说是 13.04GiB），INT8 降到 6.52GiB，INT4 降到 3.26GiB。注意 INT4 并不是 0.5 字节那么简单——每 32 或 64 或 128 个共享权重还要额外存一个 scale（通常是 FP16，2 字节），所以真实占用会比理论值高 3%~10%，这是后文要讲的"group-size"直接决定的开销。

再说 KV Cache。这是最容易被忽略的一笔账，也是长上下文服务的隐形杀手。自回归生成时，每生成一个 token 都要把前面所有 token 的 Key 和 Value 缓存下来。单个 token 的 KV 占用 = 2（K 和 V）× 层数 × 每层 KV 头数 × 每头维度 × 每个数的字节数。对 Llama-2-7B 这种没有用 GQA 的老架构，32 层 × 32 头 × 128 维 × 2 字节 × 2 = 0.5MB/token，一个 4096 上下文的请求就吃掉 2GB。如果用 GQA（比如 Qwen2.5-14B 只有 8 个 KV 头），同样的模型规模下 KV 直接降到六分之一。这就是为什么 newer 架构拼命上 GQA 和 MLA——它们治的不是权重，是 KV Cache。

第三笔账是训练期的优化器状态。这一篇主要讲推理量化，但必须提醒：如果你打算全参数微调，每参数大概要 18 字节（FP32 主权重 4 + 梯度 4 + Adam 一阶动量 4 + 二阶动量 4 + BF16 计算副本 2），7B 模型光优化器就吃掉 117GB，这就是为什么全参数微调必须上多卡或者用 ZeRO 分片。也正是 LoRA 和 QLoRA 存在的全部理由。

三笔账放在一起，你就能回答一个非常实际的问题：我手上这张 24GB 的 4090，到底能跑什么？答案是——FP16 的 7B 模型权重占 13GB，剩下 11GB 全给 KV Cache，在 4096 上下文下勉强支持 5 条并发；换成 INT4 后权重只占 3.3GB，剩下 20GB 能撑 10 条并发还不止。量化在这里不是"省一点显存"，而是直接把并发能力翻倍。

### 1.2 带宽瓶颈：batch=1 解码到底在等什么

第二个必须量化的理由更本质，也更反直觉：**大模型单条推理慢，不是因为算力不够，而是因为显存带宽不够。**

自回归解码时，每生成一个 token，模型要把全部权重从 HBM（显存）搬进计算核心一次，做一遍矩阵乘法，然后扔掉，再搬一次。这个过程里每个权重只参与一次乘加运算，算术强度（每字节数据对应的浮点运算数）极低。而现代 GPU 的算力增长远远快于带宽增长——H100 的 FP16 算力是 A100 的三倍多，带宽只提升 60%。于是 batch=1 的解码被死死钉在屋顶线的最左侧：带宽受限区。

```
                              算术强度 (FLOPs / Byte) 增大 ————▶
  吞吐量  ┌─────────────────────────────────────────────────────┐
    ▲     │                                          ██████████ │  ← 算力天花板
    │     │                                 ██████████          │
    │     │                        █████████                    │
    │     │               ████████                              │
    │     │      ████████                                       │
    │     │██████  ← 带宽天花板决定的斜线                          │
    └─────┴─────────────────────────────────────────────────────┘
          ▲
          batch=1 解码落在这里：每生成一个 token 都要把权重整体搬一遍
          → 搬得越少越快 → 权重的字节数直接决定速度上限
```

这条斜线的斜率就是显存带宽。也就是说，在 batch=1 场景下，**把权重从 2 字节压到 0.5 字节，理论上就能把吞吐上限提升接近 4 倍**。这是量化最诱人的承诺，也是很多文章只讲一半的真相（另一半见后文第九节）。

反过来，在 prefill 阶段或者大 batch 场景下，每个权重会被复用很多次，算术强度陡增，此时进入算力受限区，量化就不再是"提速"，而主要是"省显存"。这个区分决定了你该不该给线上服务上量化。

### 1.3 代码：显存账本与带宽屋顶线计算器

下面这段代码不依赖任何 GPU，纯 Python 就能跑。把它保存成 `memory_ledger.py`，换模型规模之前先算一遍，能省掉大量"装不下"的试错。

```python
"""显存账本 + 带宽屋顶线：纯 Python，离线可跑"""

MODELS = {
    "Qwen2.5-0.5B": dict(params=0.5e9, layers=24, kv_heads=2, head_dim=64),
    "Llama-2-7B":   dict(params=7.0e9, layers=32, kv_heads=32, head_dim=128),
    "Qwen2.5-14B":  dict(params=14.0e9, layers=48, kv_heads=8, head_dim=128),
    "Llama-3-70B":  dict(params=70.0e9, layers=80, kv_heads=8, head_dim=128),
}

DTYPES = [("fp16 / bf16", 2.0), ("int8", 1.0), ("int4", 0.5)]
GIB = 1024 ** 3


def kv_per_token(cfg, kv_dtype_bytes=2.0):
    # K 和 V 两份，乘以层数、每层的 KV 头数、每头维度
    return 2 * cfg["layers"] * cfg["kv_heads"] * cfg["head_dim"] * kv_dtype_bytes


print("=" * 92)
print("表 1：权重显存账本（单位 GiB，1 GiB = 1024^3 B）")
print("=" * 92)
print(f"{'模型':<16}{'层数':>6}{'KV头':>6}{'权fp16':>9}{'权int8':>9}{'权int4':>9}"
      f"{'KV/token':>11}{'省出GiB':>10}")
print("-" * 92)
for name, cfg in MODELS.items():
    row = f"{name:<16}{cfg['layers']:>6}{cfg['kv_heads']:>6}"
    w = {}
    for dname, b in DTYPES:
        w[dname] = cfg["params"] * b / GIB
        row += f"{w[dname]:>9.2f}"
    kv = kv_per_token(cfg)
    row += f"{kv/1024:>9.1f}Ki"
    row += f"{w['fp16 / bf16'] - w['int4']:>10.2f}"
    print(row)

print()
print("=" * 92)
print("表 2：KV Cache 显存（fp16 KV，单位 GiB）——上下文越长、并发越大，它越吃显存")
print("=" * 92)
ctx_batch = [(2048, 1), (4096, 1), (4096, 8), (8192, 16), (32768, 4)]
print(f"{'模型':<16}" + "".join(f"{'L%d/B%d':>12}" % (l, b) for l, b in ctx_batch))
print("-" * 92)
for name, cfg in MODELS.items():
    row = f"{name:<16}"
    for length, batch in ctx_batch:
        total = kv_per_token(cfg) * length * batch / GIB
        row += f"{total:>12.2f}"
    print(row)

print()
print("=" * 92)
print("表 3：带宽屋顶线 —— batch=1 解码时理论单流上限（tokens/s）")
print("=" * 92)
GPUS = [("RTX 4090", 1008), ("RTX 3090", 936), ("A100 80G", 2039), ("H100 SXM", 3350)]
cfg = MODELS["Llama-2-7B"]
print(f"模型：Llama-2-7B（{cfg['params']/1e9:.0f}B 参数）")
print(f"{'GPU':<12}{'带宽 GB/s':>12}{'fp16 tok/s':>14}{'int8 tok/s':>13}{'int4 tok/s':>13}{'int4/fp16':>11}")
print("-" * 92)
for gpu, bw in GPUS:
    line = f"{gpu:<12}{bw:>12}"
    ref = None
    for dname, b in DTYPES:
        tps = bw * 1e9 / (cfg["params"] * b)
        if ref is None:
            ref = tps
        line += f"{tps:>14.1f}" if dname.startswith("fp") else f"{tps:>13.1f}"
    line += f"{ (bw*1e9/(cfg['params']*0.5)) / ref:>10.1f}x"
    print(line)

print()
print("注：以上是『每生成一个 token 必须把全部权重从显存搬进计算核心一次』的绝对上限，")
print("实际能跑到 60%~75% 就很不错了（kernel 开销、注意力、采样、KV Cache 读取都要时间）。")

print()
print("=" * 92)
print("表 4：训练显存账本（全参数指令微调，AdamW + fp32 主权重，不含激活值）")
print("=" * 92)
# 每参数字节数：主权重 fp32(4) + 梯度 fp32(4) + Adam m(4) + Adam v(4) + bf16 副本(2)
bytes_per_param = 4 + 4 + 4 + 4 + 2
print(f"{'模型':<16}{'每参字节':>10}{'优化器显存':>14}{'+梯度检查点激活(估)':>22}{'合计 GiB':>12}")
print("-" * 92)
for name, cfg in MODELS.items():
    opt = cfg["params"] * bytes_per_param / GIB
    act = opt * 0.20
    print(f"{name:<16}{bytes_per_param:>10}{opt:>13.1f}G{act:>20.1f}G{opt + act:>11.1f}G")
```

实跑输出：

```
============================================================================================
表 1：权重显存账本（单位 GiB，1 GiB = 1024^3 B）
============================================================================================
模型                  层数   KV头    权fp16    权int8    权int4   KV/token     省出GiB
--------------------------------------------------------------------------------------------
Qwen2.5-0.5B        24     2     0.93     0.47     0.23     12.0Ki      0.70
Llama-2-7B          32    32    13.04     6.52     3.26    512.0Ki      9.78
Qwen2.5-14B         48     8    26.08    13.04     6.52    192.0Ki     19.56
Llama-3-70B         80     8   130.39    65.19    32.60    320.0Ki     97.79

============================================================================================
表 2：KV Cache 显存（fp16 KV，单位 GiB）——上下文越长、并发越大，它越吃显存
============================================================================================
模型                   L2048/B1     L4096/B1     L4096/B8     L8192/B16     L32768/B4
--------------------------------------------------------------------------------------------
Qwen2.5-0.5B            0.02        0.05        0.38        1.50        1.50
Llama-2-7B              1.00        2.00       16.00       64.00       64.00
Qwen2.5-14B             0.38        0.75        6.00       24.00       24.00
Llama-3-70B             0.62        1.25       10.00       40.00       40.00

============================================================================================
表 3：带宽屋顶线 —— batch=1 解码时理论单流上限（tokens/s）
============================================================================================
模型：Llama-2-7B（7B 参数）
GPU              带宽 GB/s    fp16 tok/s   int8 tok/s   int4 tok/s  int4/fp16
--------------------------------------------------------------------------------------------
RTX 4090            1008          72.0        144.0        288.0       4.0x
RTX 3090             936          66.9        133.7        267.4       4.0x
A100 80G            2039         145.6        291.3        582.6       4.0x
H100 SXM            3350         239.3        478.6        957.1       4.0x

注：以上是『每生成一个 token 必须把全部权重从显存搬进计算核心一次』的绝对上限，
实际能跑到 60%~75% 就很不错了（kernel 开销、注意力、采样、KV Cache 读取都要时间）。

============================================================================================
表 4：训练显存账本（全参数指令微调，AdamW + fp32 主权重，不含激活值）
============================================================================================
模型                    每参字节         优化器显存           +梯度检查点激活(估)      合计 GiB
--------------------------------------------------------------------------------------------
Qwen2.5-0.5B            18          8.4G                 1.7G       10.1G
Llama-2-7B              18        117.3G                23.5G      140.8G
Qwen2.5-14B             18        234.7G                46.9G      281.6G
Llama-3-70B             18       1173.5G               234.7G     1408.2G
```

把这张表读透，你会发现几个立刻能用的结论：70B 模型 FP16 想单机跑需要 130GB 以上显存，INT4 后 32.6GB，两张 4090 或者一张 A100 就够了；Llama-2-7B 的 KV Cache 是 0.5MB/token，在 4096 上下文 8 并发下要 16GB，比权重本身还大，所以高并发场景下 KV Cache 量化（比如 FP8 KV）比权重量化更关键；训练侧 18 字节/参数意味着全参数微调 7B 至少要 140GB，这张表本身就是 LoRA 存在的证明。

---

## 二、量化的基本盘：把浮点映射到整数

### 2.1 一条公式撑起整个领域

所有均匀量化的核心都是一条仿射映射：

```
量化：   q = clip( round( r / S ) + Z ,  qmin, qmax )
反量化： r̂ = S * ( q - Z )
```

其中 `S` 是 scale（步长），`Z` 是 zero-point（零点），`q` 是整数编码，`r̂` 是反量化后用来计算的浮点值。整条公式的物理含义非常朴素：把浮点区间 `[rmin, rmax]` 线性压缩到整数的有限格子上，计算时再弹回去。

scale 的定义是 `S = (rmax - rmin) / (qmax - qmin)`，对有符号 INT8 来说 `qmax - qmin = 255`，对 INT4 来说是 15。zero-point 的作用是让浮点 0 恰好落在某个整数格子上——这一点很重要，因为神经网络里有大量的 0（padding、ReLU 输出、稀疏激活），如果 0 不能被精确表示，误差会系统性累积。

### 2.2 对称还是非对称

对称量化强制 `Z = 0`，只用一个 scale，用 `±(2^(b-1)-1)` 的对称整数区间去覆盖 `[-amax, amax]`。好处是反量化时少一次减法，硬件实现简单、速度快；代价是如果数据分布本身不对称（比如 ReLU 之后的激活全为正），会浪费掉一半的编码空间。

非对称量化允许 `Z ≠ 0`，把 `[rmin, rmax]` 完整映射到 `[qmin, qmax]`。它能吃下不对称分布，但每次反量化要多一次整数减法，而且在做矩阵乘累加时 zero-point 会引入额外的修正项（INT8 矩阵乘的经典实现里这部分叫 "zero-point compensation"），拖慢 kernel。

工程上的经验法则很清晰：**权重量化优先对称**（权重近似零均值对称分布，对称损失极小），**激活量化可以考虑非对称**（ReLU / SwiGLU 之后的长尾正值分布）。这也是为什么你看到的大多数 W4A16 方案（权重 INT4、激活 FP16）都用对称量化——激活根本没量化，省下的复杂度全给了权重。

### 2.3 粒度：决定成败的那个维度

粒度（granularity）指的是"多少个权重共享一组 (S, Z)"。这是量化里比比特数更关键的旋钮。

```
                  W: 4 行 × 8 列（深浅代表幅值大小）

  per-tensor    整块张量只用一个 scale
  ┌────────────────────────────────┐
  │                                │   ← 1 个 scale
  └────────────────────────────────┘

  per-channel   每行一个 scale（工程上最常用）
  ┌────────────────────────────────┐  ← scale_row0
  ├────────────────────────────────┤  ← scale_row1
  ├────────────────────────────────┤  ← scale_row2
  └────────────────────────────────┘  ← scale_row3

  per-group     每行再按列切成 group_size 一组（group=2 示意）
  ┌───────┬───────┬───────┬───────┐
  │ s_0,0 │ s_0,1 │ s_0,2 │ s_0,3 │
  ├───────┼───────┼───────┼───────┤
  │ s_1,0 │ s_1,1 │ s_1,2 │ s_1,3 │
  └───────┴───────┴───────┴───────┘
```

为什么粒度这么关键？因为 Transformer 的权重有一个致命特性：**通道间尺度差异极大**。某些输出通道的权重幅值是其他通道的几十倍，某些输入维度上存在极端的 outlier 特征（这个现象由 LLM.int8() 那篇论文系统性地揭示）。用一个全局 scale 去覆盖"大部分很小的数 + 极少数很大的数"，结果就是小数全被压成 0，信息被彻底抹平。

per-channel 让每行有自己的 scale，解决了行间差异；per-group 进一步在列方向切块，把 outlier 的影响限制在它所在的那个小块里，代价是多存 scale（额外显存）和反量化时要按组切换 scale（额外指令开销）。

**group-size 128 的由来**：GPTQ 论文里做了一组消融实验，group-size 从 1024 一路降到 32，精度单调提升但边际收益递减，而存储开销线性上升。128 是"精度收益 / 额外开销"曲线的拐点：相对 per-channel（group = in_features）它只损失极少的精度，却把 scale 数量降到 1/128 的量级。之后整个行业（包括 AWQ、llama.cpp 的 Q4_K）都默认沿用了 128，个别方案用 64（精度更好、开销更大）或 32。这不是数学上的最优解，是工程上的最优点。

### 2.4 校准：scale 到底怎么定

有了粒度，还要定每个组的 `rmax`（或 `amax`）。这个"用一小批数据跑一遍前向、统计激活分布"的过程叫校准（calibration）。常见的几种策略：

- **min-max**：直接取这批数据里的最大绝对值。最朴素，但对离群点毫无抵抗力。
- **percentile / 截尾**：取 99.9% 分位之类的值，超出部分直接 clip。牺牲极少数点，保住绝大多数点的精度。
- **MSE**：在候选阈值里暴力搜索，让量化前后的均方误差最小。
- **KL 散度**：TensorRT 的经典做法，把分布离散成直方图，搜索让量化分布与原始分布 KL 散度最小的阈值。它衡量的不是逐点误差，而是"分布形状"的失真。

校准集的选择比校准算法本身更重要。用一个和真实输入分布相差十万八千里的校准集（比如拿英文维基去校准一个中文客服模型），无论算法多先进都会得到灾难性的 scale。经验是：校准集应当是你真实请求分布的一个无偏采样，128~512 条、长度覆盖典型上下文即可，不必多，但必须准。

### 2.5 代码：手写一个量化器，把粒度和校准比出来

下面这段代码用纯 numpy 实现了对称/非对称、per-tensor/per-channel/per-group，以及四种校准策略。所有数字都是实跑结果，你可以直接复制验证。

```python
"""手写量化器：粒度（per-tensor / per-channel / per-group）与校准策略的差异
纯 numpy，离线可跑。以下代码执行后输出的每一个数字都是真实运行得到的。"""

import numpy as np

rng = np.random.default_rng(20261007)

# ============================================================
# 1. 造一块"像真 Weight"的矩阵
#    真实权重的典型特征：近似高斯 + 重尾，且不同输出通道尺度差异很大
# ============================================================
ROWS, COLS = 256, 1024
W = rng.standard_normal((ROWS, COLS)) * 0.02
W += 0.004 * rng.standard_t(df=3, size=(ROWS, COLS))     # 重尾扰动（df 越小尾巴越厚）
W *= rng.uniform(0.3, 3.0, size=(ROWS, 1))               # 通道间尺度差异（这是关键）
W[:3, :] *= 8.0                                          # 制造 3 个离群通道
print(f"权重矩阵 W.shape = {W.shape}  std = {W.std():.5f}  absmax = {np.abs(W).max():.5f}")


def _codes(bits):
    return -(2 ** (bits - 1)), 2 ** (bits - 1) - 1      # int4 -> (-8, 7)


def _qparams(x, bits, symmetric, axis):
    """求 scale 与 zero-point。axis=None 表示整块张量共享一组参数。"""
    qmin, qmax = _codes(bits)
    if symmetric:
        amax = np.max(np.abs(x), axis=axis, keepdims=True)
        amax = np.where(amax == 0, 1e-12, amax)
        s = amax / (2 ** (bits - 1) - 1)
        zp = np.zeros_like(s)
    else:
        rmin = np.min(x, axis=axis, keepdims=True)
        rmax = np.max(x, axis=axis, keepdims=True)
        span = np.where(rmax - rmin == 0, 1e-12, rmax - rmin)
        s = span / (qmax - qmin)
        zp = np.clip(np.round(qmin - rmin / s), qmin, qmax)
    return s, zp, qmin, qmax


def fake_quantize(x, bits=4, symmetric=True, axis=None, group_size=None):
    """伪量化：反量化值 x_hat = s * (clip(round(x/s) + zp) - zp)
    axis=-1   -> per-channel（逐输出行一组参数）
    group_size -> 沿最后一个维度再切小块，每块一组参数"""
    orig = x.shape
    if group_size is not None:
        n = orig[-1]
        assert n % group_size == 0, "最后一维必须能被 group_size 整除"
        x = x.reshape(-1, n // group_size, group_size)
    s, zp, qmin, qmax = _qparams(x, bits, symmetric, axis if group_size is None else -1)
    q = np.clip(np.round(x / s) + zp, qmin, qmax)
    return (s * (q - zp)).reshape(orig)


def report(name, x_hat, x=W, width=34):
    err = x - x_hat
    mse = float(np.mean(err ** 2))
    snr = 10 * np.log10(np.mean(x ** 2) / mse)
    cos = float(np.sum(x * x_hat) / (np.linalg.norm(x) * np.linalg.norm(x_hat)))
    print(f"{name:<{width}}{mse:>13.3e}{snr:>10.2f}{cos:>12.6f}")


print("\n" + "=" * 92)
print("表 A：量化粒度对比（INT4）")
print("=" * 92)
print(f"{'方案':<34}{'MSE':>15}{'SNR(dB)':>10}{'余弦相似度':>12}")
print("-" * 92)
report('per-tensor / 对称',        fake_quantize(W, 4, True,  axis=None))
report('per-tensor / 非对称',      fake_quantize(W, 4, False, axis=None))
report('per-channel(逐行) / 对称',  fake_quantize(W, 4, True,  axis=-1))
report('per-channel(逐行) / 非对称', fake_quantize(W, 4, False, axis=-1))
report('per-group-32  / 对称',     fake_quantize(W, 4, True,  axis=-1, group_size=32))
report('per-group-128 / 对称',     fake_quantize(W, 4, True,  axis=-1, group_size=128))
report('per-group-256 / 对称',     fake_quantize(W, 4, True,  axis=-1, group_size=256))
report('per-group-128 / 非对称',   fake_quantize(W, 4, False, axis=-1, group_size=128))

print("\n" + "=" * 92)
print("表 B：比特宽度对比（均使用 per-channel 非对称）")
print("=" * 92)
print(f"{'方案':<34}{'MSE':>15}{'SNR(dB)':>10}{'余弦相似度':>12}")
print("-" * 92)
for bits, tag in [(8, 'INT8 / per-channel'), (6, 'INT6 / per-channel'),
                  (4, 'INT4 / per-channel'), (3, 'INT3 / per-channel'),
                  (2, 'INT2 / per-channel')]:
    report(tag, fake_quantize(W, bits, False, axis=-1))

# ============================================================
# 2. 校准：absmax 到底该怎么定
#    LLM.int8() 发现的 outlier 现象：少量通道幅值远超其他通道
# ============================================================
print("\n" + "=" * 92)
print("表 C：校准策略对比（对激活值做 INT8 per-tensor 对称量化）")
print("=" * 92)
N_SAMP, DIM = 8192, 512
X = rng.standard_normal((N_SAMP, DIM)) * 0.8
scale = np.ones(DIM)
scale[[11, 57, 233]] = 60.0                    # 三个 outlier 通道
scale[rng.integers(0, DIM, 20)] = 8.0          # 二十个次离群通道
X = X * scale
body = X[:, [i for i in range(DIM) if scale[i] == 1.0]]
print(f"激活值：absmax = {np.abs(X).max():.1f}   body(|普通通道|)均值 = {np.abs(body).mean():.2f}  "
      f"-> 离群比 ≈ {np.abs(X).max()/np.abs(body).mean():.0f}x")


def quant_sym_two_sided(x, threshold, bits=8):
    """对称量化并进行 双侧截断（超出 threshold 的值被 clip 掉）"""
    qmax = 2 ** (bits - 1) - 1
    s = threshold / qmax
    return s * np.clip(np.round(x / s), -2 ** (bits - 1), qmax)


def kl_threshold(x, bits=8, bins=2048):
    """TensorRT 风格的 KL 散度校准：搜索使量化分布与原分布 KL 最小的截断阈值"""
    levels = 2 ** (bits - 1)                                  # int8 正半轴 128 级
    amax = np.abs(x).max()
    hist, edges = np.histogram(np.abs(x), bins=bins, range=(0.0, amax))
    hist = hist.astype(np.float64)
    best_kl, best_i = float('inf'), None
    for i in range(levels, bins + 1, levels):
        # 1) 参考分布：保留前 i 个 bin，尾部概率全部塞进最后一个 bin
        ref = hist[:i].copy()
        ref[-1] += hist[i:].sum()
        ref = np.where(ref == 0, 1e-12, ref)
        ref = ref / ref.sum()
        # 2) 候选分布：把 i 个 bin 合并成 levels 个桶，再还原回 i 个 bin
        cand = np.zeros(levels)
        for j in range(levels):
            seg = ref[j * (i // levels): (j + 1) * (i // levels)]
            cand[j] = seg.sum()
        cand = np.where(cand == 0, 1e-12, cand)
        cand = cand / cand.sum()
        exp = np.zeros(i)
        for j in range(levels):
            seg_len = i // levels
            exp[j * seg_len: (j + 1) * seg_len] = cand[j] / seg_len
        exp = np.where(exp == 0, 1e-12, exp)
        # 3) KL(ref || exp)
        kl = float(np.sum(ref * np.log(ref / exp)))
        if kl < best_kl:
            best_kl, best_i = kl, i
    return (best_i + 0.5) * (amax / bins), best_kl


def eval_calib(tag, thr):
    q = quant_sym_two_sided(X, thr)
    err = X - q
    mse_all = float(np.mean(err ** 2))
    mse_body = float(np.mean((body - quant_sym_two_sided(body, thr)) ** 2))
    print(f"{tag:<30}{thr:>10.2f}{10*np.log10(np.mean(X**2)/mse_all):>12.2f}"
          f"{10*np.log10(np.mean(body**2)/mse_body):>14.2f}")


print(f"{'校准方式':<30}{'阈值':>12}{'整体SNR':>12}{'普通通道SNR':>14}")
print("-" * 92)
eval_calib("min-max（直接取最大值）", float(np.abs(X).max()))
for p in [99.999, 99.99, 99.9, 99.0, 95.0]:
    eval_calib(f"百分位 {p}%", float(np.percentile(np.abs(X), p)))
# MSE 最优：在 0.05~1.0 倍 max 之间暴力搜索，让总体 MSE 最小
cands = np.linspace(0.05, 1.0, 96)
best = min(cands, key=lambda c: np.mean((X - quant_sym_two_sided(X, np.abs(X).max() * c)) ** 2))
eval_calib(f"MSE 最优搜索(x{best:.2f})", float(np.abs(X).max() * best))
thr_kl, kl = kl_threshold(X)
eval_calib(f"KL 散度校准", thr_kl)
```

实跑输出：

```
权重矩阵 W.shape = (256, 1024)  std = 0.06001  absmax = 2.76954

============================================================================================
表 A：量化粒度对比（INT4）
============================================================================================
方案                                            MSE   SNR(dB)       余弦相似度
--------------------------------------------------------------------------------------------
per-tensor / 对称                       1.703e-03      3.25    0.728297
per-tensor / 非对称                      1.641e-03      3.41    0.740294
per-channel(逐行) / 对称                  1.441e-04     13.98    0.980490
per-channel(逐行) / 非对称                 8.838e-05     16.10    0.987919
per-group-32  / 对称                    3.912e-05     19.64    0.994603
per-group-128 / 对称                    6.467e-05     17.46    0.991186
per-group-256 / 对称                    8.382e-05     16.33    0.988588
per-group-128 / 非对称                   4.238e-05     19.29    0.994152

============================================================================================
表 B：比特宽度对比（均使用 per-channel 非对称）
============================================================================================
方案                                            MSE   SNR(dB)       余弦相似度
--------------------------------------------------------------------------------------------
INT8 / per-channel                    2.984e-07     40.82    0.999959
INT6 / per-channel                    4.966e-06     28.60    0.999312
INT4 / per-channel                    8.838e-05     16.10    0.987919
INT3 / per-channel                    3.932e-04      9.62    0.949679
INT2 / per-channel                    1.828e-03      2.94    0.781153

============================================================================================
表 C：校准策略对比（对激活值做 INT8 per-tensor 对称量化）
============================================================================================
激活值：absmax = 191.2   body(|普通通道|)均值 = 0.64  -> 离群比 ≈ 300x
校准方式                                    阈值       整体SNR       普通通道SNR
--------------------------------------------------------------------------------------------
min-max（直接取最大值）                   191.25       19.18          5.32
百分位 99.999%                       144.59       21.49          7.73
百分位 99.99%                        114.13       21.79          9.78
百分位 99.9%                          65.43       12.64         14.61
百分位 99.0%                           9.65        2.09         31.24
百分位 95.0%                           1.94        0.63         25.22
MSE 最优搜索(x0.65)                   124.31       22.13          9.04
KL 散度校准                            12.00        2.48         29.35
```

这几张表值得你盯着看三分钟，它们把前文所有抽象结论都变成了数字。

表 A 里最刺眼的是 per-tensor 只有 3.25dB 而 per-channel 有 13.98dB——同样的 4 个比特，仅仅因为粒度不同，信噪比差了 10.7dB（相当于误差小了一个数量级）。per-group-128 进一步到 17.46dB，per-group-32 到 19.64dB。非对称在每个粒度上都能再赚 1~2dB。这解释了为什么"INT4 能不能用"这个问题的答案是"看你用什么粒度"，而不是简单的是或否。

表 B 展示了比特数的收益曲线：INT8 有 40dB（几乎无损），INT6 掉到 28dB，INT4 只有 16dB，INT3 跌到 9.6dB，INT2 只剩 2.9dB（基本不可用）。**每降 1 比特大约损失 6dB**，这条经验规律可以帮你快速估算：想保住 20dB 以上（多数任务可用的门槛），4 比特是极限，3 比特必须上特殊手段。

表 C 讲的是一个更重要也更残酷的故事。注意我故意造了一个"离群比 300 倍"的极端激活分布。min-max 校准下整体 SNR 有 19.18dB 看起来很美，但普通通道的 SNR 只有 5.32dB——也就是说，**绝大多数普通数值被压成了噪声，整体指标好看完全是因为那几个离群点贡献了绝大部分能量**。截尾到 99.9% 后，整体 SNR 掉到 12.64dB，普通通道却从 5.32dB 涨到 14.61dB。继续截到 99%，普通通道冲到 31.24dB 而整体只剩 2.09dB。而"只按整体 MSE 搜索"得到的最优解 x0.65，同样被离群点劫持（普通通道 9.04dB）。

结论非常明确：**单一标量 absmax 无法同时服务离群点和普通点**，必须换挡——要么把粒度做细（per-channel / per-group），要么把离群部分单独拎出来高精度计算。这正是 LLM.int8()（混合精度分解）、SmoothQuant（把激活的难度迁移到权重）、AWQ（激活感知缩放）三条路线共同的出发点。

---

## 三、PTQ 与 QAT：两条路的成本差着一个数量级

量化按"什么时候做"分成两大类。

**PTQ（Post-Training Quantization，训练后量化）**：模型已经训好了，拿一小批校准数据跑一遍前向，统计分布、算 scale、量化，结束。它不需要反向传播，不需要标注数据，不需要 GPU 训练几天——通常几十分钟就能搞定一个 7B 模型。GPTQ、AWQ、LLM.int8()、SmoothQuant 都属于这一类。代价是精度损失相对大，尤其在 4 比特以下。

**QAT（Quantization-Aware Training，量化感知训练）**：在训练图里插入"伪量化节点"（fake quantization），前向时模拟量化误差，反向时直通（Straight-Through Estimator）。模型在训练过程中就"知道"自己将来会被量化，会主动把权重调整到更抗量化的位置。精度最好，甚至可以做到 INT4 几乎无损。代价是需要完整训练流程、需要数据、算力开销接近重新训练一遍。

对绝大多数大模型开发者来说，答案很明确：**用 PTQ**。原因不是 PTQ 更好，而是 QAT 在大模型上的成本高到不可承受——你要为一个 70B 模型做 QAT，需要的是和预训练同量级的算力预算。QAT 真正有价值的地方是小模型（移动端 BERT、ResNet）和极端低比特（INT2 / 二值网络）场景，那里 PTQ 完全失效而训练成本又可控。

| 维度 | PTQ | QAT |
| --- | --- | --- |
| 是否需要反向传播 | 不需要 | 需要，全流程训练 |
| 需要的数据 | 128~512 条无标注校准样本 | 完整训练数据集（通常带标注） |
| 时间成本（7B） | 数十分钟到 2 小时 | 数天到数周 |
| 算力成本 | 单卡推理级 | 训练级（多卡） |
| INT8 精度损失 | 极小（<0.5%） | 几乎无损 |
| INT4 精度损失 | 小到中等（1%~5%，看算法） | 极小 |
| INT2 / 二值 | 基本失效 | 唯一可行路径 |
| 典型工具 | GPTQ / AWQ / LLM.int8() / SmoothQuant | PyTorch FX QAT / QLoRA 后的 QAT |
| 适用人群 | 几乎所有大模型应用开发者 | 端侧小模型、极致压缩需求 |

还有一条中间路线叫 **QAT 的轻量版：量化后再微调**。比如先 GPTQ 量化到 INT4，再用 LoRA 在低比特基座上做一小段适配，让模型适应量化噪声。这条路成本介于两者之间，是近年很实用的做法，但要注意后文会讲的坑：在量化后的模型上微调，梯度的尺度和数值稳定性都会出问题，需要谨慎设置学习率并密切监控。

---

## 四、数据格式全家桶：INT8 / INT4 / FP8 / NF4

说完方法论，说说具体用哪种数值格式。

**INT8（W8A8）**：最成熟、最安全的选择。权重和激活都量化到 INT8，靠 NVIDIA 的 TensorCore（INT8 模式）能拿到真实的 2~4 倍加速，硬件支持完善（TensorRT、FasterTransformer、vLLM 都有成熟 kernel）。精度损失通常在 0.5% 以内，很多任务上和 FP16 无法区分。缺点是只省一半显存，对 70B 这种规模仍然不够。

**W4A16（INT4 权重 + FP16 激活）**：当前最主流的"甜点位"。权重压到 4 比特（显存降到 1/4），激活保持 FP16，计算时把 INT4 权重反量化成 FP16 再做矩阵乘。GPTQ、AWQ、bitsandbytes-NF4 都是这一类。显存收益巨大（7B 从 13GB 到 3.3GB），精度损失可控（1%~3%），但**不省计算量，也不一定提速**（见第九节）。

**FP8（E4M3 / E5M2）**：Hopper 架构（H100 / H200）和 Ada Lovelace（4090）开始原生支持。E4M3（4 位指数 3 位尾数）用于权重和前向激活，E5M2 用于梯度。FP8 的优势是动态范围和 FP16 接近、硬件直接支持、转换开销极低，在 H100 上能拿到接近 2 倍的算力提升。它特别适合训练加速和 KV Cache 压缩。缺点是生态还在铺，老卡（A100 及之前）用不了。

**NF4（Normal Float 4）**：QLoRA 带火的格式。它不是均匀量化，而是**信息论最优的 4 比特码本**——把标准正态分布按等概率切成 16 段，每段取一个代表值。因为 LLM 权重高度近似零均值正态分布，这种"数据密集处刻度密、稀疏处刻度疏"的非均匀码本能榨出比均匀 INT4 更高的信噪比。

下面这段代码现场算出 bitsandbytes 用的那张 NF4 码本，并在不同分布上和均匀 INT4 对比：

```python
"""NF4（Normal Float 4）信息论最优码本 + 困惑度 PPL 差异的可信判断
纯 numpy + Python 标准库，离线可跑。"""

import numpy as np
from statistics import NormalDist

rng = np.random.default_rng(7)
nd = NormalDist()

# ==================================================================
# 1. NF4：bitsandbytes 里那张 16 个点的"非均匀刻度尺"
#    原理：把标准正态的分位点等概率切 16 段，每段取一个代表值
#    数据落在哪一段最多，那段就配最密的刻度 -> 同等比特下信噪比最高
# ==================================================================
def create_nf4_map(offset=0.9677083, use_extra_value=True):
    """复刻 bitsandbytes.functional.create_normal_map 的核心逻辑"""
    ppf = nd.inv_cdf
    if use_extra_value:
        v1 = [ppf(x) for x in np.linspace(offset, 0.5, 9)[:-1]]    # 负半轴 8 个
        v3 = [-ppf(x) for x in np.linspace(offset, 0.5, 8)[:-1]]   # 正半轴 7 个
    else:
        v1 = [ppf(x) for x in np.linspace(offset, 0.5, 8)[:-1]]
        v3 = [-ppf(x) for x in np.linspace(offset, 0.5, 8)[:-1]]
    v = np.array(sorted(v1 + [0.0] + v3))
    return v / np.abs(v).max()


NF4_LEVELS = create_nf4_map()
INT4_LEVELS = np.linspace(-1.0, 1.0, 16)          # 均匀 int4（对称 16 级）

print("=" * 84)
print("按 bitsandbytes 的算法现场算出的 NF4 码本（已归一化到 [-1, 1]）")
print("=" * 84)
print(f"共 {len(NF4_LEVELS)} 个刻度：")
print("  " + "  ".join(f"{v:+.4f}" for v in NF4_LEVELS))
print()
print("相邻刻度间隔（只看非负半轴）：")
nf_pos = NF4_LEVELS[NF4_LEVELS >= 0]
print("  NF4 :", " ".join(f"{d:.3f}" for d in np.diff(nf_pos)))
in_pos = INT4_LEVELS[INT4_LEVELS >= 0]
print("  INT4:", " ".join(f"{d:.3f}" for d in np.diff(in_pos)))
print("-> INT4 刻度是等距的；NF4 在 0 附近最密（0.0796）、向两端逐渐变疏（0.24），")
print("   因为正态分布的样本几乎都堆在 0 附近，把格子分配给数据密集区才能压低总误差。")


def quant_to_levels(x, levels):
    """按 absmax 归一化后，把每个值吸附到最近的码本刻度上"""
    absmax = np.abs(x).max()
    xn = x / absmax
    idx = np.abs(xn[:, None] - levels[None, :]).argmin(axis=1)
    return absmax * levels[idx], idx


def snr(x, x_hat):
    return 10 * np.log10(np.mean(x ** 2) / np.mean((x - x_hat) ** 2))


print()
print("=" * 84)
print("不同分布下 NF4 vs 均匀 INT4 的信噪比（dB，越高越好）")
print("=" * 84)
print(f"{'数据分布':<26}{'NF4 SNR':>12}{'INT4 SNR':>12}{'差值':>10}")
print("-" * 84)
cases = {
    "标准正态 N(0,1)":   rng.standard_normal(200000),
    "混合高斯（MoE式）": np.concatenate([rng.standard_normal(100000) * 0.2,
                                     rng.standard_normal(100000) * 1.5]),
    "重尾 t(3)":         rng.standard_t(3, 200000),
    "均匀分布 U(-1,1)":  rng.uniform(-1, 1, 200000),
}
for name, data in cases.items():
    a = snr(data, quant_to_levels(data, NF4_LEVELS)[0])
    b = snr(data, quant_to_levels(data, INT4_LEVELS)[0])
    print(f"{name:<26}{a:>12.2f}{b:>12.2f}{a - b:>+10.2f}")
print()
print("结论：数据接近正态/重尾 -> NF4 大幅占优；数据真均匀 -> NF4 反而吃亏。")
print("LLM 的权重矩阵恰好高度近似零均值正态分布，这就是 QLoRA 选 NF4 而不是均匀 INT4 的理由。")
```

实跑输出：

```
====================================================================================
按 bitsandbytes 的算法现场算出的 NF4 码本（已归一化到 [-1, 1]）
====================================================================================
共 16 个刻度：
  -1.0000  -0.6962  -0.5251  -0.3949  -0.2844  -0.1848  -0.0910  +0.0000  +0.0796  +0.1609  +0.2461  +0.3379  +0.4407  +0.5626  +0.7230  +1.0000

相邻刻度间隔（只看非负半轴）：
  NF4 : 0.080 0.081 0.085 0.092 0.103 0.122 0.160 0.277
  INT4: 0.133 0.133 0.133 0.133 0.133 0.133 0.133
-> INT4 刻度是等距的；NF4 在 0 附近最密（0.0796）、向两端逐渐变疏（0.24），
   因为正态分布的样本几乎都堆在 0 附近，把格子分配给数据密集区才能压低总误差。

====================================================================================
不同分布下 NF4 vs 均匀 INT4 的信噪比（dB，越高越好）
====================================================================================
数据分布                           NF4 SNR    INT4 SNR        差值
------------------------------------------------------------------------------------
标准正态 N(0,1)                      18.17       15.16     +3.00
混合高斯（MoE式）                       15.81       11.18     +4.64
重尾 t(3)                           2.69       -8.51    +11.20
均匀分布 U(-1,1)                     20.60       23.52     -2.92

结论：数据接近正态/重尾 -> NF4 大幅占优；数据真均匀 -> NF4 反而吃亏。
LLM 的权重矩阵恰好高度近似零均值正态分布，这就是 QLoRA 选 NF4 而不是均匀 INT4 的理由。
```

注意最后一行：在均匀分布数据上 NF4 反而比均匀 INT4 差 2.92dB。这说明 NF4 不是"万能更优"，而是"更贴合 LLM 权重先验的数据格式"。任何声称某种格式全面碾压的说法都值得怀疑。

QLoRA 里还有一层叫**双重量化（Double Quantization）**：NF4 权重的每个 group 都要存一个 FP16 的 scale（group=64 时每 64 个数多 2 字节，相当于额外 0.5 比特/参数），把这些 scale 再做一次 8 比特量化，又能省下约 0.4 比特/参数。这属于锱铢必较的工程优化，但正是这类细节让 QLoRA 能在 24GB 卡上跑 65B 模型。

---

## 五、GPTQ：用二阶信息做"误差补偿"

### 5.1 从 OBD 到 GPTQ 的一条谱线

GPTQ 不是凭空冒出来的，它的理论祖先是 1990 年代的模型压缩三连：

- **OBD（Optimal Brain Damage）**：用二阶泰勒展开估计"删掉某个权重会让 loss 上升多少"，假设 Hessian 是对角阵。
- **OBS（Optimal Brain Surgeon）**：放弃对角假设，用完整的 Hessian **逆矩阵**，并且关键创新是——删掉一个权重后，**更新其余权重来补偿这个损失**。
- **OBQ（Optimal Brain Quantization）**：把"删除权重"换成"量化权重"，用同一套 OBS 框架逐权重处理。
- **GPTQ**：把 OBQ 的逐权重改成**逐列（按输入维度）批量处理**，并用 Cholesky 分解高效求 Hessian 逆，把复杂度从不可接受降到"几百亿参数模型也能在几小时内量化完"。

这条谱线的核心思想始终没变：**量化不是一个独立的舍入动作，而是一连串相互影响的决策；量化第 j 个权重引入的误差，可以通过调整还没量化的权重来部分抵消。**

### 5.2 Hessian 从哪来，为什么是它

对一个线性层，量化前后输出的差异是：

```
目标：  min_Q  || W X - Q X ||²_F
```

这里 `W` 是原始权重（d_out × d_in），`Q` 是量化后的权重，`X` 是校准数据（d_in × N）。展开成关于"权重扰动 δ"的二次型，中间那个矩阵就是 Hessian：

```
H = 2 X Xᵀ        （对输入维度而言，是 d_in × d_in 的对称矩阵）
```

Hessian 的物理含义是"输出对权重扰动的曲率"。有了它，OBS 给出闭式解：量化第 j 列产生残差 δ 时，其余未量化列的最优补偿量是

```
ΔW[:, j+1:] = - (δ / [H⁻¹]_jj) · [H⁻¹]_{j, j+1:}
```

一句话概括它的直觉：**已经量化的列不能再动了，所以只能把误差按比例摊给还没量化的列，而这个"比例"由输入特征之间的相关性决定**。如果两个输入维度高度相关，那么在其中一个上引入的误差，可以通过在另一个上反向修正来抵消。

```
         GPTQ 逐列量化 + 误差补偿（简化示意）

  输入：W (d_out × d_in)，校准激活 X (N × d_in)
  H = 2·XᵀX        ← 二阶信息：告诉"第 j 列动一点，输出会变多少"

  for j in 0 .. d_in-1 :
      取第 j 列      w = W[:, j]
      舍入量化        q = quant(w)          产生残差 δ = w - q
      落盘            Q[:, j] = q
      误差补偿        W[:, j+1:] -= δ ⊗ H⁻¹[j, j+1:] / H⁻¹[j, j]
                      └── 只改"还没量化"的列，已量化的列不能反悔
      （act-order 时，列的遍历顺序按 diag(H) 从大到小排）
```

工程上还有三个必须知道的实现细节：

- **阻尼（damping）**：H 在真实数据上常常接近奇异（特征之间强相关），直接求逆会数值爆炸。GPTQ 在 H 的对角线上加一个 `λ·mean(diag(H))` 的小扰动（通常 λ=0.01），这是稳定性与精度之间的权衡。
- **惰性批量更新（lazy batch update）**：真实实现里不是每列都立刻更新整个 W（那样 GPU 利用率极低），而是攒够 128 列做一次批量更新，数学上等价但快得多。
- **act-order（激活顺序）**：按 `diag(H)` 从大到小排序列的量化顺序，把"影响最大"的列先量化（此时可补偿的余地最大）。实测能带来可观的额外收益，代价是推理时输入维度被重排过，需要额外记录一个置换索引。

### 5.3 代码：把 GPTQ 与 AWQ 的核心机制跑出来

下面这段代码用 numpy 复现了 GPTQ 的误差补偿与 AWQ 的激活感知缩放。它不是论文级实现（真实实现要处理 Cholesky 逆、块更新、kernel 融合），但保留了全部核心机制，CPU 上零点几秒跑完，输出的数字都是真实的。

```python
"""GPTQ / AWQ 核心思想的极简可运行复现（纯 numpy，CPU 秒级跑完）
目的不是复现论文精度，而是让『Hessian 误差补偿』和『激活感知缩放』这两件事肉眼可见。"""

import numpy as np

rng = np.random.default_rng(20261007)
D_IN, D_OUT, N_CALIB, BITS = 256, 128, 512, 4
QMAX = 2 ** (BITS - 1) - 1                      # INT4 -> 7


# ---------- 构造一个"像 Transformer Linear 层"的场景 ----------
def make_layer():
    W = rng.standard_normal((D_OUT, D_IN)) * 0.02
    W += 0.004 * rng.standard_t(df=3, size=(D_OUT, D_IN))   # 重尾
    W *= rng.uniform(0.4, 3.0, size=(D_OUT, 1))             # 输出通道尺度差异
    return W


def make_calib():
    Z = rng.standard_normal((N_CALIB, 24)) @ rng.standard_normal((24, D_IN)) * 0.6
    X = Z + rng.standard_normal((N_CALIB, D_IN)) * 0.4
    # 输入通道的"重要性"（激活幅值）高度不均 —— 这正是 AWQ 成立的前提
    saliency = np.exp(rng.normal(0.0, 0.9, size=D_IN))
    return X * saliency


W0, X = make_layer(), make_calib()
Y_ref = X @ W0.T
print(f"校准数据 X {X.shape}，权重 W {W0.shape}，参考输出 Y {Y_ref.shape}，||Y||_F = {np.linalg.norm(Y_ref):.2f}")
_sx = np.abs(X).mean(axis=0)
print(f"输入通道激活幅值：最大 {_sx.max():.2f} / 最小 {_sx.min():.3f} / 中位 {np.median(_sx):.2f}"
      f"  -> 重要性差异约 {_sx.max()/_sx.min():.0f} 倍")


def rel_out_err(Y_hat):
    return float(np.linalg.norm(Y_ref - Y_hat) / np.linalg.norm(Y_ref))


def rel_w_err(W_hat):
    return float(np.linalg.norm(W0 - W_hat) / np.linalg.norm(W0))


# ---------- scale 预计算：从"原始权重"算出，RTN 与 GPTQ 用同一套，保证公平 ----------
def precompute_scales(W, group=D_IN):
    S = np.empty_like(W)
    for i in range(W.shape[0]):
        for b in range(W.shape[1] // group):
            blk = W[i, b * group:(b + 1) * group]
            S[i, b * group:(b + 1) * group] = np.abs(blk).max() / QMAX
    return S


SCALE = precompute_scales(W0, group=D_IN)        # per-channel（逐输出行一个 scale）


def rtn(W, S=SCALE):
    """Round-To-Nearest：最朴素的量化，用它当基线"""
    return S * np.clip(np.round(W / S), -QMAX - 1, QMAX)


# ==================================================================
# GPTQ：逐列量化 + 二阶信息（Hessian）驱动的残差补偿
#   每量化一列 j，就用 H^{-1} 告诉剩下未量化的列"该怎么改才能把输出误差补回来"
# ==================================================================
def gptq(W, X, actorder=False, damp=0.01, S=SCALE):
    W = W.astype(np.float64).copy()
    H = 2.0 * (X.T @ X) / X.shape[0]                       # 曲率（二阶信息）
    H += damp * float(np.mean(np.diag(H))) * np.eye(H.shape[0])   # 阻尼：H 常接近奇异
    Hinv = np.linalg.inv(H)                                # 真实实现用 Cholesky 逆，更快更稳
    order = np.argsort(-np.diag(H)) if actorder else np.arange(W.shape[1])
    Hp = Hinv[np.ix_(order, order)]
    Q = np.zeros_like(W)
    for j, idx in enumerate(order):
        col = W[:, idx].copy()
        q = S[:, idx] * np.clip(np.round(col / S[:, idx]), -QMAX - 1, QMAX)
        Q[:, idx] = q
        err = (col - q) / Hp[j, j]                         # OBS 最优更新量
        W[:, order[j:]] -= np.outer(err, Hp[j, j:])        # 把残差按相关性摊到剩余列
    return Q


# ==================================================================
# AWQ：不看权重看激活
#   重要输入通道放大 -> 占用更多量化级别；量化后在前向时被除回来，数学上等价
# ==================================================================
def awq_scale(sx, alpha):
    base = np.exp(np.mean(np.log(sx + 1e-12)))
    return np.clip((sx / base) ** alpha, 0.05, 20.0)


def awq_forward(W, X, alpha=None, delta=None, keep_ratio=0.0):
    delta = awq_scale(np.abs(X).mean(axis=0), alpha) if delta is None else delta
    Ws = W * delta                                         # 放大/缩小输入通道维
    Q = rtn(Ws, precompute_scales(Ws))                     # 按缩放后的权重重新定 scale
    if keep_ratio > 0:                                     # top-r% salient 通道保留 FP16
        k = max(1, int(W.shape[1] * keep_ratio))
        keep = np.argsort(-np.abs(X).mean(axis=0))[:k]
        Q[:, keep] = Ws[:, keep]
    return (X / delta) @ Q.T                               # 前向时把 X 反向缩放回来


W_rtn = rtn(W0)
W_gptq = gptq(W0, X)
W_gptq_ao = gptq(W0, X, actorder=True)

print("\n" + "=" * 92)
print("实验一：RTN vs GPTQ（INT4 / per-channel，两者使用完全相同的 scale）")
print("=" * 92)
base_ey = rel_out_err(X @ W_rtn.T)
print(f"{'方法':<34}{'权重相对误差':>14}{'输出相对误差':>14}{'输出误差降幅':>14}")
print("-" * 92)
for tag, Wq in [("RTN（最近舍入，无补偿）", W_rtn),
                ("GPTQ（Hessian 误差补偿）", W_gptq),
                ("GPTQ + act-order（重排列）", W_gptq_ao)]:
    ew, ey = rel_w_err(Wq), rel_out_err(X @ Wq.T)
    print(f"{tag:<34}{ew:>14.5f}{ey:>14.5f}{(base_ey - ey) / base_ey * 100:>13.1f}%")

print("\n" + "=" * 92)
print("实验二：AWQ 缩放指数 alpha 的影响（INT4 / per-channel）")
print("=" * 92)
print(f"{'alpha':>8}{'输出相对误差':>16}{'误差降幅':>14}")
print("-" * 92)
errs = {}
for a in [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]:
    errs[a] = rel_out_err(awq_forward(W0, X, alpha=a))
    print(f"{a:>8.2f}{errs[a]:>16.5f}{(errs[0.0] - errs[a]) / errs[0.0] * 100:>13.1f}%")
best_a = min(errs, key=errs.get)
print(f"-> 本例最优 alpha = {best_a:.2f}；alpha=0 时 AWQ 退化为普通 RTN")

print("\n" + "=" * 92)
print(f"实验三：把 1% salient weight 保留为 FP16 的额外收益（alpha={best_a:.2f}）")
print("=" * 92)
print(f"{'保留比例':>10}{'输出相对误差':>16}{'误差降幅':>14}{'额外显存开销':>16}")
print("-" * 92)
for keep in [0.0, 0.005, 0.01, 0.03, 0.10]:
    ey = rel_out_err(awq_forward(W0, X, alpha=best_a, keep_ratio=keep))
    print(f"{keep*100:>9.1f}%{ey:>16.5f}{(errs[best_a] - ey) / errs[best_a] * 100:>13.1f}%"
          f"{keep * (16 / BITS - 1) * 100:>15.1f}%")

print("\n" + "=" * 92)
print("实验四：总览（同一份权重、同一份校准数据、INT4 / per-channel）")
print("=" * 92)
print(f"{'方案':<34}{'输出相对误差':>16}{'误差降幅':>14}{'是否需要反向传播':>16}")
print("-" * 92)
rows = [("RTN（基线）", X @ W_rtn.T),
        (f"AWQ（alpha={best_a:.2f}，无保留）", awq_forward(W0, X, alpha=best_a)),
        (f"AWQ + 保留1% FP16", awq_forward(W0, X, alpha=best_a, keep_ratio=0.01)),
        ("GPTQ（Hessian 补偿）", X @ W_gptq.T),
        ("GPTQ + act-order", X @ W_gptq_ao.T)]
for tag, Yh in rows:
    print(f"{tag:<34}{rel_out_err(Yh):>16.5f}{(base_ey - rel_out_err(Yh)) / base_ey * 100:>13.1f}%"
          f"{'不需要':>16}")
```

实跑输出：

```
校准数据 X (512, 256)，权重 W (128, 256)，参考输出 Y (512, 128)，||Y||_F = 992.75
输入通道激活幅值：最大 22.27 / 最小 0.215 / 中位 2.27  -> 重要性差异约 104 倍

============================================================================================
实验一：RTN vs GPTQ（INT4 / per-channel，两者使用完全相同的 scale）
============================================================================================
方法                                        权重相对误差        输出相对误差        输出误差降幅
--------------------------------------------------------------------------------------------
RTN（最近舍入，无补偿）                            0.13650       0.13139          0.0%
GPTQ（Hessian 误差补偿）                       0.14785       0.08401         36.1%
GPTQ + act-order（重排列）                    0.15456       0.05748         56.3%

============================================================================================
实验二：AWQ 缩放指数 alpha 的影响（INT4 / per-channel）
============================================================================================
   alpha          输出相对误差          误差降幅
--------------------------------------------------------------------------------------------
    0.00         0.13139          0.0%
    0.10         0.12094          7.9%
    0.25         0.11775         10.4%
    0.50         0.13568         -3.3%
    0.75         0.18239        -38.8%
    1.00         0.25076        -90.9%
-> 本例最优 alpha = 0.25；alpha=0 时 AWQ 退化为普通 RTN

============================================================================================
实验三：把 1% salient weight 保留为 FP16 的额外收益（alpha=0.25）
============================================================================================
      保留比例          输出相对误差          误差降幅          额外显存开销
--------------------------------------------------------------------------------------------
      0.0%         0.11775          0.0%            0.0%
      0.5%         0.11484          2.5%            1.5%
      1.0%         0.11281          4.2%            3.0%
      3.0%         0.10515         10.7%            9.0%
     10.0%         0.08703         26.1%           30.0%

============================================================================================
实验四：总览（同一份权重、同一份校准数据、INT4 / per-channel）
============================================================================================
方案                                          输出相对误差          误差降幅        是否需要反向传播
--------------------------------------------------------------------------------------------
RTN（基线）                                    0.13139          0.0%             不需要
AWQ（alpha=0.25，无保留）                        0.11775         10.4%             不需要
AWQ + 保留1% FP16                            0.11281         14.1%             不需要
GPTQ（Hessian 补偿）                           0.08401         36.1%             不需要
GPTQ + act-order                           0.05748         56.3%             不需要
```

**这张表里最反直觉的一行是"权重相对误差"那一列**：GPTQ 的权重空间误差（0.14785）比 RTN（0.13650）**更大**，可它的输出误差（0.08401）却小了 36%。这不是 bug，恰恰是 GPTQ 的精髓——它优化的目标函数从来不是"逐元素逼近原始权重"，而是"让输出 `XWᵀ` 尽量不变"。它主动把误差引导到了输入数据不敏感的方向上。**如果你用权重空间的 MSE 去评估一个量化算法，你会得出完全错误的结论。**

另外几个观察：

- act-order 在 GPTQ 基础上又砍掉 20 个百分点的误差（36.1% → 56.3%），性价比极高，实际使用 GPTQ 时几乎没有理由不开。
- AWQ 的 alpha 是一个需要搜的参数，本例最优在 0.25，而**过大（≥0.5）会迅速劣化甚至不如基线**。真实实现里 AWQ 会在一个小网格上搜索 alpha，不要想当然地用 0.5 或 1.0。
- "保留 1% salient weight 为 FP16"只多花 3% 显存就换来 4.2% 的误差下降，性价比很好；但保留 10% 要花 30% 显存才换 26%，就不划算了。这正好解释了 AWQ 论文为什么取 1%。
- 本例中 AWQ 的收益（10.4%）不如 GPTQ（36.1%）。这是玩具数据的局限——真实 Transformer 里存在更极端的离群通道结构，AWQ 在那里表现会和 GPTQ 接近。不要在 toy 实验上得出"AWQ 不如 GPTQ"的结论。

---

## 六、AWQ：激活感知，以及为什么它更快

如果说 GPTQ 是"事后补偿"，AWQ 就是"事前布局"。

AWQ 的出发点是一篇非常漂亮的观察：**权重的重要性并不均匀，而且重要性不取决于权重自己，取决于流过它的激活**。论文做了个实验：只把 0.1%~1% 的权重保留成 FP16，模型性能就几乎回到 FP16 水平；但如果随机保留 1% 的权重，性能几乎没提升。这说明确实存在极少量"牵一发动全身"的关键权重，而它们的位置由激活分布决定。

顺着这条线索，AWQ 提出了一个极其聪明的等价变换。对输入通道 j 做缩放 `Δ_j`：

```
原本：  Y = X · Wᵀ
变换后：Y = (X / Δ) · (W · Δ)ᵀ        数学上完全等价
```

既然等价，那么就可以先按 `Δ` 把权重缩放一下，量化这个缩放后的权重，推理时把输入反过来除回去。关键在于 `Δ` 怎么选。AWQ 的做法是：

```
Δ_j = (s_X_j)^α        s_X_j = 第 j 个输入通道的平均激活幅值，α ∈ [0, 1] 待搜索
```

激活大的通道被放大，于是它在所在量化组里占据更大的幅值范围，"抢到"更多的量化级别；激活小的通道被缩小，让出精度。整个过程只需要一次前向统计激活幅值，**不需要 Hessian，不需要矩阵求逆，不需要反向传播**。

这带来了两个直接优势：

1. **更快**。GPTQ 需要对每个层构造并求逆一个 d_in × d_in 的 Hessian，这个过程在 4096 维甚至 8192 维上是实打实的计算负担，还要做 Cholesky 分解保证数值稳定。AWQ 只需要 `mean(|X|, axis=0)`，几乎零成本。实测上 AWQ 的量化速度通常是 GPTQ 的数倍。
2. **更好的硬件亲和性**。AWQ 不改动权重的排列顺序（不像 act-order 需要置换索引），也不需要在列之间做耦合更新，产出的权重布局规整，写 kernel 更友好。这也是 AWQ 在 vLLM、TensorRT-LLM、TGI 里支持得特别快、推理吞吐常常优于 GPTQ 的原因。

一句话总结两者的取舍：**GPTQ 用算力换精度（误差补偿更彻底），AWQ 用洞察换速度（不需要二阶信息）**。

---

## 七、工具链生态：什么时候用谁

量化算法说完了，落到工程上有四条主流路线，定位完全不同。

| 工具 | 定位 | 典型格式 | 强项 | 短板 |
| --- | --- | --- | --- | --- |
| **bitsandbytes** | 训练/微调期的动态量化 | NF4 / INT8（W4A16、W8A8） | `load_in_4bit=True` 一行接入；与 peft/QLoRA 无缝配合；支持分页优化器 | 推理吞吐一般；模型不能直接存成"量化权重"分发 |
| **auto-gptq** | 推理导向的 GPTQ 量化 | INT4 / INT3 / INT2（W4A16） | 精度最好；group-size、act-order、damping 全可配；产出可分发 | 量化耗时长；依赖 Triton kernel；部分架构支持滞后 |
| **autoawq** | 推理导向的 AWQ 量化 | INT4（W4A16） | 量化快数倍；vLLM / TensorRT-LLM 支持完善；吞吐高 | 精度略逊于 GPTQ（多数场景差距很小） |
| **GGUF + llama.cpp** | 端侧 / CPU / 苹果芯片 | Q4_K_M / Q5_K_M / Q2_K 等几十种 | CPU 与 Metal 推理极强；单文件分发；量化档位极细 | GPU 大批量吞吐不如 vLLM；生态偏"本地玩家" |

选型建议非常直接：

- **你要微调**：bitsandbytes（QLoRA），别无二选。
- **你要在 GPU 上做高并发在线服务**：autoawq 或 auto-gptq 量化 + vLLM 部署。追求极限精度选 GPTQ，追求量化速度和吞吐选 AWQ。
- **你要在 CPU / Mac / 树莓派 / 笔记本上跑**：GGUF + llama.cpp，按显存/内存预算在 Q4_K_M、Q5_K_M 里挑。
- **你要在 H100 上训练**：考虑 FP8。

### 代码：transformers 加载 4bit 并叠加 QLoRA

这是把前一篇的 QLoRA 和本篇的量化原理串起来的那段代码。`load_in_4bit` 背后走的是 bitsandbytes 的 NF4 + 双重量化 + 分页优化器那一整套。

```python
# 需要 GPU 与 bitsandbytes / peft / transformers，此处为可直接跑的参考实现
# pip install -U transformers accelerate bitsandbytes peft torch

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training

MODEL_ID = "Qwen/Qwen2.5-7B-Instruct"

# ---------- 1. 4bit 量化配置：这些参数每一个都对应本篇讲过的概念 ----------
bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,                      # 权重以 4bit 存储（显存降到约 1/4）
    bnb_4bit_quant_type="nf4",              # nf4（信息论最优码本）vs fp4（浮点 4bit）
    bnb_4bit_use_double_quant=True,         # 双重量化：把 scale 本身再压成 8bit
    bnb_4bit_compute_dtype=torch.bfloat16,  # 计算时反量化到 bf16——注意它决定的是"算"，不是"存"
)

tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID,
    quantization_config=bnb_config,
    device_map="auto",                      # 自动把放不下的层分到 CPU / 多卡
)

# ---------- 2. 让 4bit 模型"可以被训练" ----------
# prepare_model_for_kbit_training 做三件事：
#   (a) 打开输入的梯度需求；(b) 把 LayerNorm 等稳定层转成 fp32；(c) 开启梯度检查点
model = prepare_model_for_kbit_training(
    model, use_gradient_checkpointing=True
)

# ---------- 3. 叠加 LoRA：基座冻结且是 4bit，只有适配器是 fp16/fp32 ----------
lora_config = LoraConfig(
    r=16,
    lora_alpha=32,
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                    "gate_proj", "up_proj", "down_proj"],
)
model = get_peft_model(model, lora_config)

# 打印可训练参数占比——你会看到 0.1% 量级
trainable, total = model.get_nb_trainable_parameters()
print(f"可训练参数: {trainable:,} / 总参数: {total:,} = {trainable / total:.4%}")
print(model)
```

参考输出（结构示意，具体数字随版本与模型而变）：

```
可训练参数: 33,554,432 / 总参数: 4,094,484,480 = 0.8195%   # 7B 量化后统计口径不同，量级在 0.1%~1%

PeftModelForCausalLM(
  (base_model): LoraModel(
    (model): Qwen2ForCausalLM(
      (model): Qwen2Model(
        (layers): ModuleList(
          (0-27): 28 x Qwen2DecoderLayer(
            (self_attn): Qwen2Attention(
              (q_proj): lora.Linear4bit(
                (base_layer): Linear4bit(in_features=3584, out_features=3584, bias=False)
                (lora_dropout): Dropout(p=0.05, inplace=False)
                (lora_A): Linear(in_features=3584, out_features=16, bias=False)
                (lora_B): Linear(in_features=16, out_features=3584, bias=False)
              )
              ...
```

注意两件事。其一，`bnb_4bit_compute_dtype` 决定的是**计算精度**而不是**存储精度**——权重始终以 4bit 存在显存里，只是每次矩阵乘之前反量化成 bf16。用 bf16 而不是 fp16 是为了数值稳定性（fp16 在激活值大时容易溢出）。其二，输出的模块名是 `Linear4bit`，LoRA 的 A/B 矩阵则是正常精度的 `Linear`——**这就是 QLoRA 的全部秘密：用低精度存基座，用高精度训增量**。

---

## 八、量化之后，怎么判断"还能不能用"

量化不是做完就完事，你必须有一套评估流程。三层，从便宜到贵：

**第一层：困惑度（Perplexity, PPL）**。最便宜、最常用。`PPL = exp(平均 NLL)`，在 held-out 语料上跑一遍前向就能算。经验阈值：INT8 相对 FP16 的 PPL 上升通常 <1%；W4A16（GPTQ/AWQ）一般在 1%~5%；超过 10% 就要警惕。

但 PPL 有个陷阱：**PPL 的微小差异往往是噪声**。下面这段代码用 bootstrap 给出置信区间，告诉你"差多少才算真的差"。

```python
"""困惑度（PPL）差异的可信判断：用 bootstrap 重采样估计置信区间
纯 numpy，离线可跑。真实使用时把 nll_a / nll_b 换成两个模型逐 token 的负对数似然。"""

import numpy as np

rng = np.random.default_rng(7)


def ppl(nll):
    return float(np.exp(np.mean(nll)))


def bootstrap_delta_ci(nll_a, nll_b, n_boot=2000, seed=42):
    """对『B 相对 A 的平均 NLL 增量』做 bootstrap，看 95% 区间是否跨过 0"""
    rg = np.random.default_rng(seed)
    n = len(nll_a)
    d = np.empty(n_boot)
    for i in range(n_boot):
        idx = rg.integers(0, n, n)
        d[i] = np.mean(nll_b[idx]) - np.mean(nll_a[idx])
    return np.percentile(d, [2.5, 97.5])


N_TOKENS = 2000
# 令平均 NLL ≈ 2.2 -> PPL ≈ 9，接近一个 7B 中文模型在通用语料上的量级
base = rng.lognormal(mean=0.55, sigma=0.75, size=N_TOKENS)
scenarios = {
    "几乎无差别":   base + rng.normal(0, 0.002, N_TOKENS),
    "B 略好":      base + rng.normal(-0.012, 0.06, N_TOKENS),
    "B 明显更好":   base + rng.normal(-0.08, 0.06, N_TOKENS),
    "B 明显更差":   base + rng.normal(+0.08, 0.06, N_TOKENS),
}
print(f"基准模型 A：PPL = {ppl(base):.4f}（评测集 {N_TOKENS} 个 token）")
print()
print(f"{'场景':<14}{'模型B PPL':>12}{'相对变化':>12}{'ΔNLL 95%CI':>28}{'判定':>10}")
print("-" * 84)
for name, nll_b in scenarios.items():
    ci = bootstrap_delta_ci(base, nll_b)
    pa, pb = ppl(base), ppl(nll_b)
    verdict = "显著" if ci[0] * ci[1] > 0 else "不显著"
    print(f"{name:<14}{pb:>12.4f}{(pb - pa) / pa * 100:>11.2f}%"
          f"[{ci[0]:+.4f}, {ci[1]:+.4f}]{verdict:>12}")
```

实跑输出：

```
====================================================================================
PPL 差异的可信判断：用 bootstrap 重采样估计置信区间
====================================================================================
基准模型 A：PPL = 10.2983（评测集 2000 个 token）

场景                 模型B PPL        相对变化                  ΔNLL 95%CI        判定
------------------------------------------------------------------------------------
几乎无差别              10.2976      -0.01%[-0.0002, +0.0000]         不显著
B 略好               10.1846      -1.10%[-0.0138, -0.0082]          显著
B 明显更好              9.5244      -7.52%[-0.0807, -0.0755]          显著
B 明显更差             11.1591       8.36%[+0.0775, +0.0829]          显著
```

在 2000 个 token 的评测集上，PPL 差 0.01%（10.2983 vs 10.2976）显然是不可信的；而差 1.10% 就已经能被 95% 置信区间判定为显著。这个量级感很重要：**量化前后如果 PPL 只差千分之几，那基本等同于噪声，别急着下结论**。

**第二层：下游任务准确率**。PPL 衡量的是"语言建模能力"，不等于"能不能干活"。量化后必须跑你的真实任务集：分类准确率、抽取 F1、代码通过率、SQL 执行正确率等。这一层的指标才是上线决策的依据。做法上，建议固定一份 200~500 条的 held-out 集，每次量化后跑同一套脚本，把结果落盘成 JSON 便于对比。

**第三层：人工抽检**。自动化指标会漏掉很多东西——尤其是"格式崩坏"（JSON 少个括号）、"重复啰嗦"、"语气变化"这类问题。每次量化后人工看 30~50 条输出，成本极低但价值极高。具体怎么组织人工评估，下一篇会展开讲。

---

## 九、重要真相：量化省显存，但不一定提速

这是本篇最想让你记住的一条，也是最容易踩坑的地方。

量化一定省显存（权重字节数实实在在变少了）。但**量化不一定提速**，原因有三个：

**其一，反量化开销。** W4A16 方案在每次矩阵乘之前，要把 INT4 权重反量化回 FP16/BF16。这个动作本身要花时间，还要消耗带宽。如果 kernel 写得不好，反量化的开销可能吃掉省下来的数据搬运时间。

**其二，W4A16 根本没有减少计算量。** 矩阵乘依然是在 FP16 下做的，FLOPs 一点没少。在算力受限区（大 batch、prefill、长 prompt），省下的带宽完全不影响瓶颈，此时量化**只会更慢**（多了反量化这一步）。

**其三，kernel 支持决定一切。** 有没有高效的 INT4 GEMM kernel，是提速与否的分水岭。A100 上有很好的 INT4 支持；某些卡或某些框架下，INT4 反而不如 INT8 快（因为 INT8 有成熟的 TensorCore 原生支持而 INT4 没有）。

那么什么时候量化能提速？判断标准很清晰：

| 场景 | 瓶颈 | 量化的效果 |
| --- | --- | --- |
| batch=1、短 prompt、长生成 | 显存带宽（搬权重） | **明显提速**，接近比特数下降的比例 |
| batch 较大（>8）、生成为主 | 带宽 + 计算混合 | 有一定提速，幅度递减 |
| prefill / 长 prompt 处理 | 算力（FLOPs） | **基本不提速**，甚至略慢 |
| batch 很大、持续满负荷 | 纯算力 | 不提速，只省显存（但省下的显存可以多开并发，间接提吞吐） |
| CPU / 端侧推理 | 内存带宽 + 算力都弱 | **提速最明显**（llama.cpp 的 Q4_K_M 常常比 FP16 快 2~3 倍） |

一句话：**量化真正的价值，在 batch=1 或 CPU 场景下是"提速"，在大 batch GPU 服务场景下是"省显存换并发"**。如果你的服务已经是大 batch 满负荷，量化对你的单请求延迟没有任何帮助，但能让你开更多并发、降低单位成本。搞清楚你的场景在哪一格，再决定要不要量化、量化到几比特。

---

## 十、常见坑与注意事项

**坑一：校准集不具代表性。** 这是最容易犯也最致命的错。用英文维基校准中文客服模型、用短句校准长文档摘要模型，得到的 scale 会系统性偏离。做法：从真实请求日志里随机采样 128~512 条，长度分布要和线上一致。如果你的模型有明确的领域（医疗、法律、代码），校准集必须来自同一领域。

**坑二：group-size 不是越小越好。** group=32 精度最好，但 scale 的存储开销是 group=128 的 4 倍，反量化时的指令开销也更高。128 是业界默认的甜点，64 是精度敏感场景的折中。不要盲目调小。

**坑三：某些层不能量化。** 经验上，`lm_head`（输出投影）和 `embed_tokens`（词嵌入）建议保持高精度——它们直接决定输出分布，量化误差会被放大。LayerNorm / RMSNorm 的参数绝对不能量化（它们对数值精度极敏感，而且参数量极小，省下来也没意义）。另外，模型的**第一层和最后一层**通常对量化更敏感，有些实现会单独保留。

**坑四：量化后再微调要谨慎。** 在 4bit 基座上继续训练时，梯度要穿过反量化操作，数值稳定性比全精度差很多。务必：学习率降到原来的 1/2 到 1/5；开启梯度检查点；密切监控 loss（下一篇会讲怎么看）；如果不是必须，优先选择"先在 FP16 上微调完，再统一量化"的顺序。

**坑五：量化模型的推理结果不可复现地漂移。** 换了 kernel 版本、换了框架、甚至换了 GPU 架构，同一个量化模型可能给出略微不同的输出。这不是 bug，是低精度计算的舍入顺序差异。如果你的业务强依赖确定性输出，需要在量化后做回归测试，而不是假设"数值应该一模一样"。

**坑六：只看 PPL 不看下游。** 前面已经讲过，PPL 差 1% 可能对应下游任务 5% 的准确率差异（尤其是在需要严格格式输出、多步推理的任务上）。量化后必须跑下游评测。

**坑七：bitsandbytes 量化模型不能直接"存成量化权重"分发。** bnb 是加载时动态量化的，你 save 出来的还是 FP16 权重（除非用专门流程）。要做可分发的量化模型，得走 auto-gptq / autoawq / GGUF 那条路。

---

## 本节小结

把这一篇压缩成几条可以带走的结论：

- 量化的第一性原理不是"压缩"，而是**"在带宽受限场景下减少每 token 必须搬运的字节数"**。所以 batch=1 和 CPU 场景收益最大，大 batch 场景收益主要来自省下的显存换并发。
- 一条仿射映射 `q = clip(round(r/S) + Z)` 撑起整个领域；真正决定成败的是**粒度**（per-channel / per-group）而不是比特数。per-tensor 到 per-channel 的差距（3.25dB → 13.98dB）比 INT8 降 INT4 的差距还大。
- **校准的本质是在"少数离群点"和"多数普通点"之间做取舍**，单一标量阈值做不到两全，所以才需要细粒度、截尾、混合精度分解（LLM.int8()）和激活感知缩放（AWQ）。
- GPTQ 用 Hessian 逆做**误差补偿**，优化的是输出空间而非权重空间（所以权重 MSE 变大、输出误差变小是完全正常的）；AWQ 用**激活感知缩放**做等价变换，不做反向传播因而快得多。两者都是 PTQ，都不需要训练。
- 选型看场景：微调用 bitsandbytes + QLoRA；GPU 在线服务用 autoawq / auto-gptq + vLLM；端侧 CPU 用 GGUF + llama.cpp；H100 训练考虑 FP8。
- 评估要三层：PPL（便宜但要配置信区间）、下游任务准确率（决策依据）、人工抽检（抓格式与语气崩坏）。
- 最后一条也是最重要的：**量化省显存是确定的，提速是有条件的**。先判断你的场景在屋顶线的哪一格，再决定要不要量化。

---

## 实战练习（可验证的小任务）

1. **改一改显存账本**：把 `memory_ledger.py` 里的 `MODELS` 换成你正在用的模型（查它的 config.json 拿层数、KV 头数、head_dim），算出它在你的显卡上、你的目标并发下能不能跑起来。再把 KV Cache 的 dtype 改成 1 字节（FP8 KV），看看并发能提升多少。

2. **验证 group-size 的收益拐点**：在量化器脚本里，把 `group_size` 从 32 扫到 1024（取 2 的幂），画出"额外存储开销"与"SNR"的曲线，亲眼确认 128 附近是不是拐点。你会发现超过 256 之后收益几乎不再增长。

3. **亲手触发一次量化灾难**：把校准脚本里三个 outlier 通道的 scale 从 60 改成 600，再跑一遍，观察 min-max 校准下普通通道 SNR 会掉到多少。然后试着用 per-channel 粒度救回来——理解"粒度为什么比比特数重要"。

4. **给 GPTQ 加上阻尼实验**：把 `gptq()` 里的 `damp` 从 0.01 改成 0 和 1.0，看输出误差怎么变。你会发现 damp=0 时可能因为 Hessian 奇异而结果爆炸，这就是工程实现里必须加阻尼的原因。

5. **量化一个真实小模型**：用 `pip install autoawq` 对 Qwen2.5-0.5B-Instruct 做 W4 量化（消费级显卡几十分钟，CPU 慢一些），量化前后各跑一份 200 条的领域评测集，把 PPL 和任务准确率记下来，用第八节的 bootstrap 脚本判断差异是否显著。

---

## 延伸阅读与下一步

- **论文**：GPTQ（arXiv:2210.17323）、AWQ（arXiv:2306.00978）、LLM.int8()（arXiv:2208.07339）、SmoothQuant（arXiv:2211.10438）、QLoRA（arXiv:2305.14314）。建议按这个顺序读，它们构成一条完整的"发现 outlier → 分解 → 迁移 → 缩放 → 补偿"的思路链。
- **工程文档**：bitsandbytes 的 NF4 实现（`functional.create_normal_map`）、auto-gptq 的 `GPTQ` 类、llama.cpp 的 `quantize` 工具（-q 参数列表里几十种档位值得一读，能帮你建立"不同比特位怎么分配"的直觉）。
- **下一步**：量化解决的是"训完的模型怎么变小变快"，但一个更前置的问题还没解决——你怎么知道训出来的模型是好的？loss 曲线下降就万事大吉了吗？下一篇《训练监控与评估——loss 曲线与评测集》会讲清 loss 曲线该怎么看、评测集该怎么建、以及为什么"训完就发"是一场灾难。

---

本篇是《大模型开发从 0 到 1》专栏第 48 篇。
