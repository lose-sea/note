<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# RNN 与 LSTM 序列建模——处理文本与时间序列

**承上**：上一篇《CNN 与计算机视觉》我们处理了有空间结构的图像。

**本篇**：本篇处理有先后顺序的序列：RNN 的循环记忆、LSTM 的三道门，以及它们为何被取代。

**启下**：下一篇进入阶段 5《注意力机制》，看 Transformer 如何一次看全序列且完全并行。

**学完这一节，你能动手做**：1) 能从零实现 RNN，训练字符级语言模型并自回归生成文本 2) 能理解 LSTM 三道门如何用加法结构给梯度开高速公路 3) 能说清 RNN 的两大死穴，明白注意力机制为什么非有不可。

图像是"空间结构"，而**文本、语音、股票、日志**都是**序列**——有先后顺序，前后的元素互相影响。

前面学过的 MLP 和 CNN 都有一个共同缺陷：**输入输出长度固定，且不记得历史**。而语言恰恰是"下一个词取决于前面所有词"。

**RNN（循环神经网络）** 就是为序列设计的：它有一个"隐藏状态"，像记忆一样在时间步之间传递。

这一篇你会：从零实现 RNN、理解 LSTM 的三道门、用 PyTorch 训练一个字符级语言模型，并彻底搞懂——**为什么 Transformer 最终取代了 RNN**。这是理解"注意力为什么必要"的最后一块拼图。

## 〇、概念引入与背景：序列数据为什么特殊？

先明确「序列」是什么：一串有序的元素 `x_1, x_2, ..., x_T`，元素之间有**时间或位置上的先后依赖**。典型例子：一句话（词有序）、一段语音（采样点有序）、股价（按天有序）、传感器日志（按秒有序）。它们的共同难点是——**第 T 个元素的意义，往往取决于前面所有元素**。比如「他打开了冰箱，拿出一瓶__」，空格处大概率是「饮料/水」，因为前面铺垫了「冰箱」。

为什么 MLP/CNN 处理不了？因为这两类模型是「一次性映射」：`y = f(x)`，输入长度固定、输出也固定，且对输入没有「记忆」。你若把一整句话拍平成向量喂进去，模型既不知道词序、也记不住「前文出现过冰箱」。CNN 虽然能看局部邻域，但它的「邻域」是空间上的、且不跨时间累积——它看一张图能看局部，但看一句话没法「把第 1 个词的信息带到第 20 个词」。

RNN 的解法很直观：**给模型加一个跨时间传递的「隐藏状态 h」**。每读一个词，它就结合「当前词 x_t」和「上一刻的记忆 h_{t-1}」更新记忆，并输出当前结果。于是记忆像接力棒一样，从 t=1 一直传到 t=T，**后词天然能「看到」前词**。这套「状态在时间上循环」的设计，让模型第一次有了「记忆」。

从大模型视角看，RNN 是「序列建模」这条线索上的重要一站，但也是被 Transformer 取代的一站。理解它为何「有记忆却不够好」，你才能真懂**注意力机制为什么是必然**——这正是本篇收尾要给你的「临门一脚」。

## 一、为什么需要"记忆"？

先看一个直觉例子：

> "我把手机放在桌上，然后去厨房，回来发现它不____了。"

填什么？大概率是"见"或"在"。**要填对这个空，你必须记住句子开头出现过"手机"和"桌子"**——而这是几十个词之前的信息。

```python
import numpy as np
import torch
import torch.nn as nn

# MLP 的局限：固定长度输入，没有历史概念
print("MLP 输入: 固定维度向量 → 无法处理变长序列")
print("CNN 输入: 固定尺寸图像 → 感受野有限")
print("RNN 输入: 序列 (t=1,2,3,...,T) → 每步都能看到之前的信息 ✓")
```

RNN 的核心公式只有一行：

```
h_t = tanh(W_xh · x_t + W_hh · h_{t-1} + b)
y_t = W_hy · h_t
```

- `x_t`：当前时刻的输入
- `h_{t-1}`：**上一时刻的记忆**
- `h_t`：更新后的记忆（传给下一步）

**同一个 `W_hh` 在所有时间步复用**——这和 CNN 的权值共享是同一个思想：时间的平移不变性。

把公式拆开讲：`h_t` 是「新记忆」，它由两部分合成——「当前输入经过 `W_xh` 的投影」+「旧记忆经过 `W_hh` 的投影」，再加偏置、过 `tanh` 压到 (-1,1)。`y_t` 是「基于当前记忆做出的预测」。关键的「复用」：`W_xh`、`W_hh`、`W_hy` 这三组权重在**所有时间步共用同一份**——这跟 CNN 权值共享同源：假设「处理序列的方式不随位置变」（时间的平移不变性）。好处同样是省参数、易泛化。但隐患也埋在这里：记忆每步都要经过 `W_hh` 压缩一次，信息在长序列上会衰减——这正是后面「梯度消失/长程遗忘」的根源。

## 二、从零实现一个 RNN

```python
class RNNFromScratch:
    """从零实现 RNN：理解 h_t = tanh(W_xh x_t + W_hh h_{t-1} + b)"""
    def __init__(self, input_size, hidden_size, output_size, seed=0):
        rng = np.random.default_rng(seed)
        scale = 1.0 / np.sqrt(hidden_size)
        self.W_xh = rng.standard_normal((input_size, hidden_size)) * scale
        self.W_hh = rng.standard_normal((hidden_size, hidden_size)) * scale
        self.W_hy = rng.standard_normal((hidden_size, output_size)) * scale
        self.b_h = np.zeros(hidden_size)
        self.b_y = np.zeros(output_size)
        self.hidden_size = hidden_size

    def step(self, x_t, h_prev):
        """单个时间步：x_t (input,), h_prev (hidden,)"""
        h = np.tanh(x_t @ self.W_xh + h_prev @ self.W_hh + self.b_h)
        y = h @ self.W_hy + self.b_y
        return h, y

    def forward(self, inputs):
        """inputs: (T, input_size) → 返回所有时刻的输出与隐藏状态"""
        h = np.zeros(self.hidden_size)
        hs, ys = [], []
        for x_t in inputs:
            h, y = self.step(x_t, h)
            hs.append(h); ys.append(y)
        return np.array(hs), np.array(ys)

# 测一下
rng = np.random.default_rng(1)
T, inp, hid, out = 6, 4, 8, 3
X_seq = rng.standard_normal((T, inp))

rnn = RNNFromScratch(inp, hid, out)
hs, ys = rnn.forward(X_seq)
print("隐藏状态序列:", hs.shape)   # (6, 8) 每个时刻一个
print("输出序列:", ys.shape)       # (6, 3)
print("h_0 全零（初始无记忆）:", np.allclose(hs[0], np.tanh(X_seq[0] @ rnn.W_xh + rnn.b_h)))
```

这个从零实现把 RNN 的「循环」露骨地写出来：`forward` 里一个 `for` 循环，每步调用 `step`，把上一步的 `h` 传给下一步——这就是「记忆在时间上传递」的代码形态。`h` 初始为全零（`h_0`），意味着「一开始没有记忆」，第一个时间步只能靠 `x_0` 建立初始记忆。注意 `hs` 是一个 `(T, hidden)` 的序列：每个时刻都有一个记忆向量，模型「随时都知道自己读到了哪」。输出 `ys` 是 `(T, output)`，即每个时刻都能出结果——这正是「多对多」序列建模的基础。

权重初始化 `scale = 1/sqrt(hidden_size)` 是经典技巧：让每层的激活 variance 大致恒定，避免梯度爆炸/消失（这和 PyTorch 默认的 Kaiming 初始化思想一致）。你后面训真实 RNN 时，初始化好坏直接影响能不能收敛。

## 三、用 RNN 做语言模型：预测下一个字符

这是最经典的入门任务。给模型一段文本，让它学会"看到前文，预测下一个字符"。

```python
# ---------- 1. 构造字符级数据集 ----------
text = "hello world, hello pytorch, hello rnn. "
chars = sorted(list(set(text)))
char2idx = {c: i for i, c in enumerate(chars)}
idx2char = {i: c for c, i in chars.items()}
vocab_size = len(chars)
print(f"字符集({vocab_size}): {''.join(chars)}")

def encode(s): return [char2idx[c] for c in s]
def decode(ids): return ''.join([idx2char[i] for i in ids])

data = encode(text)
print("编码前 10 个:", data[:10], "→", decode(data[:10]))

# 构造 (input, target)：target 是 input 右移一位
SEQ_LEN = 20
inputs, targets = [], []
for i in range(len(data) - SEQ_LEN):
    inputs.append(data[i:i + SEQ_LEN])
    targets.append(data[i + 1:i + SEQ_LEN + 1])
print(f"样本数: {len(inputs)}，输入长度 {SEQ_LEN}")
```

字符级语言模型的套路讲清：先把文本里所有不同字符收集成「词表」，每个字符映射成一个 id（`char2idx`），文本变成一串 id。然后做「滑窗」：窗口长 `SEQ_LEN`，输入是 `data[i:i+SEQ_LEN]`、目标是 `data[i+1:i+SEQ_LEN+1]`——**目标正好是输入整体右移一位**。训练的终极目标：给定前 20 个字符，模型能准确预测第 21 个字符。把无数个这样的窗口喂给 RNN，它就学会了「英语里 'h','e','l' 后面大概率还是 'l'」这种局部统计规律——这正是语言模型「预测下一个 token」思想的微型版，和 GPT 预训练本质相同，只是 GPT 是「词/子词」级、且规模大亿倍。

### 3.1 PyTorch 版 RNN 模型

```python
class CharRNN(nn.Module):
    def __init__(self, vocab_size, hidden_size=64):
        super().__init__()
        self.embed = nn.Embedding(vocab_size, hidden_size)      # 字符 → 向量
        self.rnn = nn.RNN(hidden_size, hidden_size, batch_first=True)
        self.fc = nn.Linear(hidden_size, vocab_size)            # 隐藏态 → 字符分数

    def forward(self, x, h=None):
        # x: (B, T) 字符 id
        emb = self.embed(x)             # (B, T, hidden)
        out, h = self.rnn(emb, h)       # out: (B, T, hidden)
        logits = self.fc(out)           # (B, T, vocab)
        return logits, h

    def init_hidden(self, batch_size, device):
        return torch.zeros(1, batch_size, self.rnn.hidden_size, device=device)

model = CharRNN(vocab_size)
print(f"参数量: {sum(p.numel() for p in model.parameters()):,}")

# 前向测试
xb = torch.tensor([inputs[0]])
logits, h = model(xb)
print("logits 形状:", logits.shape)    # (1, 20, vocab_size)
```

PyTorch 的 `nn.RNN` 把第二节那个 `for` 循环封装好了：`out` 是「每个时间步的隐藏态」堆叠成的 `(B, T, hidden)`，`h` 是「最后一个时间步的隐藏态」——做「多对一」任务（如情感分类）时你就只用 `h` 这个总结性记忆。`nn.Embedding` 把字符 id 变成向量（和 CNN 篇讲的 embedding 是同一层），让离散字符进入连续空间。`batch_first=True` 让输入形状是 `(B, T, ...)`（batch 在前），更符合直觉；默认是 `(T, B, ...)`，新手常因这个形状错而报错（见第八节）。`logits` 形状 `(1, 20, vocab_size)` 表示「每个位置、对每个字符给出一个未归一化的分数」，配合 `CrossEntropyLoss` 训练。

### 3.2 训练

```python
DEVICE = torch.device("cuda" if torch.cuda.is_available()
                      else "mps" if torch.backends.mps.is_available() else "cpu")
model = CharRNN(vocab_size, hidden_size=128).to(DEVICE)
criterion = nn.CrossEntropyLoss()
optimizer = torch.optim.Adam(model.parameters(), lr=5e-3)

X_t = torch.tensor(inputs, dtype=torch.long, device=DEVICE)
Y_t = torch.tensor(targets, dtype=torch.long, device=DEVICE)

EPOCHS = 300
for ep in range(EPOCHS):
    model.train()
    optimizer.zero_grad()
    logits, _ = model(X_t)
    # CrossEntropyLoss 需要 (N, C) 或 (N, C, d)，这里把 B 和 T 展平
    loss = criterion(logits.reshape(-1, vocab_size), Y_t.reshape(-1))
    loss.backward()
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)   # RNN 必做！
    optimizer.step()

    if ep % 60 == 0 or ep == EPOCHS - 1:
        print(f"epoch {ep:3d}  loss={loss.item():.4f}")

print("\n训练结束，开始生成：")
```

训练循环还是熟悉的五步曲，但有两个 RNN 专属要点：①`CrossEntropyLoss` 要「每个位置的预测 vs 该位置的目标」，所以把 `(B, T, vocab)` 和 `(B, T)` 都 `reshape(-1, ...)` 展平成「(B*T, vocab) 对 (B*T,)」，等价于「把序列上每个时间步当成独立样本一起算交叉熵」——这正对应前面滑窗里「每个位置都要预测下一个字符」。②`clip_grad_norm_(..., 1.0)` 是 **RNN 必做**：RNN 梯度沿时间连乘，极易爆炸成 NaN，梯度裁剪把总梯度范数限制在 1.0 内，是 RNN/LSTM 训练的保命符（详见第四节）。典型训练输出：loss 从 ~2.5（随机，约等于 `log(vocab_size)`）慢慢降到 ~0.5 以下，字符级困惑度随之下降，模型开始「像人话」。

### 3.3 生成文本（自回归采样）

```python
@torch.no_grad()
def generate(model, start_str, length=40, temperature=0.8):
    model.eval()
    ids = encode(start_str)
    h = None
    result = list(start_str)

    # 先"预热"：把起始串喂进去，拿到隐藏状态
    x = torch.tensor([ids[:-1]], dtype=torch.long, device=DEVICE)
    if len(ids) > 1:
        _, h = model(x)

    cur = torch.tensor([[ids[-1]]], dtype=torch.long, device=DEVICE)
    for _ in range(length):
        logits, h = model(cur, h)
        probs = torch.softmax(logits[0, -1] / temperature, dim=-1)
        next_id = torch.multinomial(probs, 1).item()     # 按概率采样
        result.append(idx2char[next_id])
        cur = torch.tensor([[next_id]], dtype=torch.long, device=DEVICE)
    return ''.join(result)

print(generate(model, "hello ", length=30))
```

**注意 `torch.multinomial(probs, 1)`** —— 这就是我们在阶段 2 概率篇讲过的"按概率抽样"。大模型生成的本质就是这个。

把「自回归生成」讲透：生成时我们不让模型一次性吐出整句，而是**一个字符一个字符地「滚」**——先把起始串喂进去拿到记忆 `h`，然后每次只取「最后一个位置的预测分布」，按概率采一个字符，把它接回输入、带着更新后的 `h` 再预测下一个，循环 `length` 次。`temperature`（温度）控制「有多随机」：温度低（如 0.5）分布更尖锐、生成更确定/保守；温度高（如 1.2）更随机/有创意。`torch.multinomial` 按概率抽样而非直接 `argmax`，是让生成「不每次都一样、有多样性」的关键——**今天所有大模型（GPT/Claude/Qwen）的「生成」底层就是这套自回归采样**，只是把字符换成了子词 token、把小 RNN 换成了巨型 Transformer。所以你这段代码，复刻了大模型生成的最小原型。

## 四、RNN 的致命缺陷：梯度消失与长程遗忘

RNN 看起来很美，但它有个根本问题。

反向传播要沿时间展开（**BPTT, Backpropagation Through Time**），梯度要连乘 `T` 次：

```python
# 演示：梯度沿时间步连乘的衰减
for T in [5, 10, 20, 50, 100]:
    print(f"序列长度 T={T:3d}: 0.9^{T} = {0.9**T:.2e}   1.1^{T} = {1.1**T:.2e}")
```

- **梯度消失**：早期时间步的梯度趋近 0，模型学不到"句首信息影响句尾"这种长距离依赖（**20 步之外基本就忘了**）；
- **梯度爆炸**：反过来梯度指数增长，参数直接 NaN（所以要 `clip_grad_norm_`）。

先解释「BPTT（随时间反向传播）」：训练 RNN 时，框架会把循环「展开」成一条 T 层的链（每个时间步是一层），然后像普通深层网络一样从后往前传梯度。问题就出在这条链的长度 = 序列长度 T，且**每层的梯度都乘同一个 `W_hh`**（因为权重复用）。于是第 1 个时间步收到的梯度 ≈ `(W_hh 的相关特征值)^T`——若特征值 < 1，`0.9^T` 随 T 增大指数趋近 0（梯度消失，早期信息学不到）；若 > 1，`1.1^T` 指数爆炸（梯度 NaN）。上面代码打印得很直观：`0.9^100 ≈ 2.6e-5`（几乎没了），`1.1^100 ≈ 1.4e4`（爆了）。RNN 就卡在这个「连乘」里——**要么记不住远的，要么算爆**。

```python
# 实验：看看 RNN 能不能记住长距离信息
def memory_test(seq_len):
    """任务：记住序列第一个字符，在末尾预测它"""
    np.random.seed(0)
    n = 2000
    X_mem = np.random.randint(0, vocab_size, (n, seq_len))
    X_mem[:, 0] = np.random.randint(0, vocab_size, n)     # 首字符是"线索"
    y_mem = X_mem[:, 0].copy()                            # 目标 = 首字符

    m = CharRNN(vocab_size, hidden_size=64).to(DEVICE)
    opt = torch.optim.Adam(m.parameters(), lr=3e-3)
    Xm = torch.tensor(X_mem, device=DEVICE)
    ym = torch.tensor(y_mem, device=DEVICE)
    for _ in range(120):
        opt.zero_grad()
        logits, _ = m(Xm)
        loss = nn.functional.cross_entropy(logits[:, -1], ym)
        loss.backward()
        opt.step()
    with torch.no_grad():
        pred = m(Xm)[0][:, -1].argmax(-1)
    return (pred == ym).float().mean().item()

print("短序列(T=5) 记忆准确率:", round(memory_test(5), 3))
print("长序列(T=30) 记忆准确率:", round(memory_test(30), 3))
```

**长序列上准确率会明显下滑**——这就是 RNN 的"记不住"。

`memory_test` 设计了一个「刁钻任务」：序列开头放一个随机字符（线索），要求模型在序列**末尾**准确预测出这个开头字符——这需要把第 1 个位置的信息一路带到第 T 个位置。短序列（T=5）模型尚可达成不错准确率，长序列（T=30）准确率明显下滑，因为中间 30 次 `W_hh` 传递把线索信息稀释/覆盖了。这用实验证明了「长程依赖是 RNN 的硬伤」。真实语言里「代词指代」「跨句因果」往往隔几十上百词，RNN 在这类任务上先天吃力。

### 第二个致命伤：无法并行

```
RNN:  h_1 → h_2 → h_3 → ... → h_T
      必须严格按顺序算，h_3 依赖 h_2，h_2 依赖 h_1
```

**串行 = 慢**。现代 GPU 有几千个核心，最擅长并行，而 RNN 只能一步步来。训练一个 1000 步的序列要等 1000 次串行计算——**这在大数据时代是不可接受的**。

把「无法并行」说透：RNN 的 `h_t` 依赖 `h_{t-1}`，而 `h_{t-1}` 又依赖 `h_{t-2}`……这是一条**严格串行的数据依赖链**，第 t 步没算完第 t+1 步就不能开始。GPU 几千核心在这里英雄无用武之地——你只能让一个核心一步步走完整条链。而 Transformer（下一篇）把整条序列一次性矩阵乘并行处理，1000 个位置同时算。在百亿参数、万亿 token 的大模型时代，「能不能喂满 GPU」直接决定训练要几个月还是几天——RNN 这条串行链，使它注定无法胜任大模型规模。这是它被取代的第二个、同样致命的原因。

## 五、LSTM：用"门"来保护记忆

LSTM（长短期记忆网络）通过精巧的门控设计解决了梯度消失。

它维护两条通道：
- **细胞状态 C_t**：像传送带，信息几乎无损地流过（这是解决梯度消失的关键）
- **隐藏状态 h_t**：工作记忆，每个门的输出

### 5.1 三道门

```
遗忘门 f_t = σ(W_f · [h_{t-1}, x_t] + b_f)     决定：旧记忆丢掉多少
输入门 i_t = σ(W_i · [h_{t-1}, x_t] + b_i)     决定：新信息写入多少
候选值  C̃_t = tanh(W_C · [h_{t-1}, x_t] + b_C) 待写入的新信息
细胞状态 C_t = f_t ⊙ C_{t-1} + i_t ⊙ C̃_t      旧记忆×遗忘 + 新信息×输入
输出门 o_t = σ(W_o · [h_{t-1}, x_t] + b_o)     决定：输出多少
隐藏状态 h_t = o_t ⊙ tanh(C_t)
```

```python
def lstm_step(x_t, h_prev, C_prev, W_f, W_i, W_C, W_o, b_f, b_i, b_C, b_o):
    """单步 LSTM：x_t (d,), h_prev (h,), C_prev (h,)"""
    concat = np.concatenate([h_prev, x_t])          # 拼接 [h, x]

    f = 1 / (1 + np.exp(-(concat @ W_f + b_f)))     # 遗忘门 (0~1)
    i = 1 / (1 + np.exp(-(concat @ W_i + b_i)))     # 输入门
    C_tilde = np.tanh(concat @ W_C + b_C)           # 候选记忆
    o = 1 / (1 + np.exp(-(concat @ W_o + b_o)))     # 输出门

    C = f * C_prev + i * C_tilde                    # 更新细胞状态
    h = o * np.tanh(C)                              # 更新隐藏状态
    return h, C, {"f": f, "i": i, "o": o}

# 演示门的效果
d, h = 5, 8
rng = np.random.default_rng(0)
W = lambda: rng.standard_normal((d + h, h)) * 0.1
W_f, W_i, W_C, W_o = W(), W(), W(), W()
b_f, b_i, b_C, b_o = np.zeros(h), np.zeros(h), np.zeros(h), np.zeros(h)

x_t = rng.standard_normal(d)
h_prev = np.zeros(h)
C_prev = rng.standard_normal(h)

h_new, C_new, gates = lstm_step(x_t, h_prev, C_prev, W_f, W_i, W_C, W_o, b_f, b_i, b_C, b_o)
print("遗忘门均值:", gates["f"].mean().round(3), "（接近1=保留旧记忆）")
print("输入门均值:", gates["i"].mean().round(3), "（接近1=写入新信息）")
print("输出门均值:", gates["o"].mean().round(3))
print("细胞状态变化:", np.abs(C_new - C_prev).mean().round(4))
```

LSTM 的精妙全在「三道门」上，逐个讲：门 = `sigmoid(·)`，输出恒在 (0,1)，可理解为「开关的程度」——0 表示「全关（完全不通过）」，1 表示「全开（原样通过）」。

- **遗忘门 f_t**：决定「上一个细胞状态 `C_{t-1}` 保留多少」。比如读到新段落，模型可能让 f_t 偏小，「忘掉上一句的话题」。
- **输入门 i_t**：决定「候选新信息 `C̃_t` 写进多少」。和遗忘门配合，实现「该忘的忘、该记的记」。
- **候选值 C̃_t**：本步「想写入的新内容」（`tanh` 压缩到 (-1,1)）。
- **细胞状态 C_t = f_t⊙C_{t-1} + i_t⊙C̃_t**：这是 LSTM 的灵魂——一条贯穿全程的「传送带」，旧记忆按比例保留、新记忆按比例写入，**信息几乎不被压缩扭曲地流过所有时间步**。
- **输出门 o_t**：决定「从细胞状态里放出多少到隐藏状态 h_t」供当前输出用。

上面代码里，门值均值通常在 0.4~0.6 附近（随机初始化下），说明「每步都在做部分遗忘+部分写入」的权衡；`C_new` 和 `C_prev` 的差异不大，正体现「细胞状态是缓慢演化的长时记忆」，而非像 RNN 的 `h_t` 那样每步被 `tanh` 重写。

### 5.2 为什么 LSTM 能缓解梯度消失？

关键在于 **`C_t = f_t ⊙ C_{t-1} + i_t ⊙ C̃_t`** 这一项的**加法结构**：

- 如果遗忘门 `f_t ≈ 1`、`输入门 i_t ≈ 0`，则 `C_t ≈ C_{t-1}`；
- 此时梯度 `∂C_t/∂C_{t-1} ≈ 1`（**而不是连乘小于 1 的数**）；
- **梯度可以无损地沿细胞状态这条"高速公路"传回很远**。

这就是 LSTM 能记住几百步信息的原因。

展开：RNN 的梯度在 `W_hh` 上连乘，每步都乘一个会衰减的数；而 LSTM 的梯度沿「细胞状态」回传时，主要经过 `∂C_t/∂C_{t-1} = f_t`（加法的链式法则，那一项系数是 `f_t`，另一项 `i_t·∂C̃_t/∂C_{t-1}` 通常较小）。当 `f_t ≈ 1` 时，这个系数≈1，**梯度几乎不衰减地直达序列开头**——像在 `C` 这条主路上修了一条「高速公路」，信息/梯度可以一路畅行。对比 RNN 那条被 `tanh` 和 `W_hh` 反复挤压的小路，高下立判。所以 LSTM 能记住几百步的依赖，但它**没解决「串行计算」**（每个时间步仍要依次算），所以最终还是被 Transformer 取代——LSTM 治好了「记不住」，但没治好「算得慢」。

### 5.3 PyTorch 的 nn.LSTM

```python
lstm = nn.LSTM(input_size=64, hidden_size=128, num_layers=2,
               batch_first=True, dropout=0.2, bidirectional=False)

x = torch.randn(4, 20, 64)          # (batch, seq_len, input_size)
out, (h_n, c_n) = lstm(x)
print("输出 out:", out.shape)        # (4, 20, 128) 每个时刻的隐藏态
print("最后隐藏态 h_n:", h_n.shape)   # (2, 4, 128)  (层数, batch, hidden)
print("最后细胞态 c_n:", c_n.shape)   # (2, 4, 128)  ← LSTM 独有

# 双向 LSTM（能同时看前后文，适合分类/标注任务）
bi_lstm = nn.LSTM(64, 128, batch_first=True, bidirectional=True)
out_bi, _ = bi_lstm(x)
print("双向输出:", out_bi.shape)      # (4, 20, 256) = 128 × 2

# GRU：LSTM 的简化版（两道门，参数更少，效果接近）
gru = nn.GRU(64, 128, batch_first=True)
out_g, h_g = gru(x)
print("GRU 输出:", out_g.shape, " 隐藏态:", h_g.shape)   # 没有细胞状态
```

`nn.LSTM` 比 `nn.RNN` 多返回一个 `c_n`（细胞状态）——这就是 LSTM 的「长时记忆」。`num_layers=2` 表示「叠两层 LSTM」（深层，第一层输出喂第二层），`h_n`/`c_n` 的第一维是层数。`bidirectional=True` 让序列「从左往右」和「从右往左」各跑一遍、结果拼接，于是每个位置的输出**同时看到前文和后文**——特别适合「给每个词打标签」（如命名实体识别）或「整体分类」，但不适合「自回归生成」（生成时不能偷看未来）。`nn.GRU` 是 LSTM 的轻量版：把遗忘门和输入门合并成「更新门」、去掉独立细胞态，参数更少、算更快，效果常与 LSTM 接近，是「想要循环记忆又嫌 LSTM 重」时的首选。

| | 门数 | 参数 | 特点 |
|---|---|---|---|
| **RNN** | 0 | 少 | 简单，但记不住长的 |
| **LSTM** | 3（遗忘/输入/输出） | 多 | 记忆强，经典 |
| **GRU** | 2（重置/更新） | 中 | 速度快，效果接近 LSTM |

## 六、序列任务的三类模式

```python
print("""
1. 一对一 (One-to-One)  : 固定输入 → 固定输出    例：MLP 分类
2. 一对多 (One-to-Many) : 一个输入 → 序列输出    例：图像描述生成
3. 多对一 (Many-to-One) : 序列输入 → 一个输出    例：情感分析（用最后隐藏态）
4. 多对多 (Many-to-Many): 序列 → 序列            例：机器翻译（Encoder-Decoder）
                                                 例：命名实体识别（每步都输出）
""")

# 多对一示例：情感分类（取最后一个隐藏状态）
class SentimentLSTM(nn.Module):
    def __init__(self, vocab_size, emb_dim, hidden, num_classes=2):
        super().__init__()
        self.embed = nn.Embedding(vocab_size, emb_dim, padding_idx=0)
        self.lstm = nn.LSTM(emb_dim, hidden, batch_first=True, bidirectional=True)
        self.fc = nn.Linear(hidden * 2, num_classes)     # 双向拼接

    def forward(self, x):
        emb = self.embed(x)
        out, (h_n, _) = self.lstm(emb)
        # h_n: (2层×2方向, B, hidden) → 取最后一层的前向与后向
        last = torch.cat([h_n[-2], h_n[-1]], dim=-1)
        return self.fc(last)

sen = SentimentLSTM(5000, 128, 256)
print("情感分类输出:", sen(torch.randint(1, 5000, (8, 30))).shape)   # (8, 2)
```

序列建模按「输入输出长度关系」分四类，这是选模型结构的字典：

- **One-to-One**：输入定长、输出定长（如一张图分类）——其实不需要循环，MLP/CNN 即可。
- **One-to-Many**：一个条件 → 生成序列（如「看图写诗」「图像描述生成」）——用「自回归」，每步把上一步输出喂回。
- **Many-to-One**：整段序列 → 一个标签（如情感分析、文档分类）——**取最后一个隐藏态 `h_T`** 当「整段话的总结向量」喂给分类头。上面的 `SentimentLSTM` 就是典型：双向 LSTM 跑完，把最后一层前向/后向的隐藏态拼起来做分类。
- **Many-to-Many**：序列→序列（如机器翻译、语音识别、NER）——经典用 Encoder-Decoder（编码整句、再逐词解码），每个位置都输出。

`padding_idx=0` 是细节：把「填充符」（padding）的 embedding 固定为零、且训练时不更新它，避免无意义的 padding 干扰。这个「四类模式」框架在 NLP/CV/语音通用，你以后看任何序列任务都能先归类再选型。

## 七、为什么 Transformer 取代了 RNN？（本篇重点结论）

| 维度 | RNN/LSTM | Transformer |
|---|---|---|
| **长距离依赖** | 靠记忆传递，几百步后衰减 | **注意力一步直达任意位置** |
| **并行性** | ❌ 必须串行，慢 | ✅ 全部位置并行，快几十倍 |
| **梯度路径** | 长度 = 序列长度 T | **恒为 O(1)**（任意两位置直接连） |
| **训练效率** | 低 | **高**（GPU 利用率高） |
| **可扩展性** | 堆不深 | **能堆上百层，scaling law 成立** |

```python
# 直观对比：信息传递路径长度
seq_len = 100
print(f"RNN：第 1 个词的信息要传到第 {seq_len} 个词，需要 {seq_len} 步串行传递")
print("      → 中间要连乘 100 次，梯度早就没了")
print()
print("Transformer：第 1 个词和第 100 个词之间只有 1 次注意力计算")
print("      → 路径长度恒为 1，无论序列多长（这就是为什么 LLM 能处理 128K 上下文）")
```

**两个致命劣势（串行 + 长程遗忘）叠加，让 RNN 在大数据时代彻底出局。** 2017 年《Attention Is All You Need》发表后，Transformer 迅速统治 NLP，然后扩展到 CV、语音、多模态——**今天所有大模型（GPT、LLaMA、Qwen、Claude）都是 Transformer**。

把「为什么取代」收个尾：RNN 有两个死穴——①**长程遗忘**（梯度沿时间连乘衰减，记不住远处）；②**无法并行**（严格串行，喂不满 GPU）。Transformer 用「自注意力」一次性把整条序列做矩阵乘，**任意两位置直接相连（路径长度=1）、且完全并行**。于是它既治好了「记不住」（第 1 词和第 100 词一步直达），又治好了「算得慢」（几千核心同时跑）。当数据规模上去后，这种「更通用 + 更能扩 + 更并行」的架构碾压了 RNN。2017 年那篇《Attention Is All You Need》是分水岭——之后 NLP 全面转向 Transformer，再蔓延到 CV（ViT）、语音、多模态。你现在用的每个大模型，底层都是 Transformer 而非 RNN。理解 RNN 的「为什么不行」，正是理解注意力「为什么必须」的最后一块拼图。

**但 RNN 并非一无是处**：
- 推理时是 O(1) 内存（Transformer 的 KV Cache 随长度线性增长）——近年 **Mamba、RWKV** 等"状态空间模型"正是基于这个优势在复兴 RNN 思想；
- 小数据、低延迟场景下 GRU 仍然好用。

补充这个「反方观点」很重要：Transformer 不是「永远最优」。它的 KV Cache 随上下文长度线性增长显存，处理超长序列（百万 token）时很吃力；而 RNN 类推理内存恒定。近年 **Mamba（状态空间模型）、RWKV** 重新拾起「循环/状态传递」思想，用「选择性状态」做到「既记得住长程、又能在推理时 O(1) 内存」，在长文本、端侧低延迟场景很有潜力。所以完整认知是：**Transformer 赢在「训练并行 + 大数据」，RNN 思想在「推理效率 + 超长序列」仍有价值**——这也是大模型前沿正在融合的方向（如混合架构）。

## 八、常见坑与注意事项

| 坑 | 现象 | 解决 |
|---|---|---|
| 忘记 `clip_grad_norm_` | 训练中 loss 变 NaN | RNN 必加梯度裁剪 |
| 隐藏状态没 detach | 反向传播图无限增长 | 截断 BPTT：`h = h.detach()` |
| 用 RNN 处理超长序列 | 记不住、训练慢 | 换 Transformer |
| 忘了 `batch_first=True` | 形状 (T,B,C) 而不是 (B,T,C) | 显式指定 |
| Embedding 输入是 float | `expected Long` | 词 id 用 `.long()` |
| 双向 LSTM 输出维度 | FC 层维度不匹配 | 拼接后是 `hidden × 2` |
| LSTM 返回 tuple | `out, h = lstm(x)` 报错 | LSTM 返回 `(out, (h_n, c_n))` |

补几个高频翻车点：①**梯度裁剪是 RNN 的保命符**——忘加必 NaN，养成「凡 RNN/LSTM 必 `clip_grad_norm_`」的肌肉记忆。②**隐藏状态要 detach**：长序列训练时，若把上一个 chunk 的 `h` 一直带着梯度连下去，计算图会无限拉长、显存爆炸。用**截断 BPTT**（见下）——每个 chunk 开始前 `h = h.detach()`，断开与更早 chunk 的梯度链，只在本 chunk 内回传。③**`batch_first` 形状错**：不指定时 `nn.RNN` 默认 `(T,B,C)`，你按 `(B,T,C)` 喂就 shape mismatch，一律显式写 `batch_first=True`。④**双向输出维度翻倍**：`out_bi` 最后一维是 `hidden*2`，接 `Linear` 时维度要对上，否则报 `size mismatch`。

**截断 BPTT**（训练长序列的标准做法）：

```python
h = None
for chunk in long_sequence_chunks:
    h = h.detach() if h is not None else None    # 断开与之前chunk的梯度连接
    out, h = model(chunk, h)
    loss = criterion(out, target)
    loss.backward()
    optimizer.step()
```

截断 BPTT 的直觉：把超长序列切成 chunk，每个 chunk 用「上一个 chunk 的最终隐藏态」作初始记忆（保持语义连续），但**只让梯度在本 chunk 内回传**（`detach` 切断跨 chunk 的梯度）。这样既「记忆连贯」又「显存可控、能训超长序列」。这是训练长文本 RNN/Transformer 的通用技巧（Transformer 里对应「梯度检查点 / 分块注意力」）。

## 九、本篇小结

1. **RNN 的核心是 `h_t = tanh(W_xh·x_t + W_hh·h_{t-1})`**，用隐藏状态在时间步之间传递记忆，权值在时间上共享。
2. 我们**从零实现了 RNN**，并用 PyTorch 训练了一个**字符级语言模型**，学会了自回归采样生成（`multinomial` 按概率抽样）。
3. **RNN 两大死穴**：梯度消失（连乘衰减，记不住长距离）+ **无法并行**（必须串行，GPU 跑不满）。
4. **LSTM 用三道门 + 细胞状态的加法结构**给梯度开了高速公路，缓解了梯度消失；GRU 是其简化版。
5. **Transformer 用注意力把任意两位置的路径长度压缩到 1，且完全并行**——这两点直接终结了 RNN 的统治，成就了今天所有大模型。

**阶段 4 深度学习与 PyTorch 到此完结。** 你已经会用 PyTorch 搭网络、写训练循环、处理图像和序列。

下一篇进入 **阶段 5：Transformer 与大模型原理**——真正的重头戏。我们会从注意力机制开始，手推 QKV 矩阵，逐层拆解 Transformer 架构，理解分词与 Embedding，最后搞懂 BERT 与 GPT 的分野。**学完阶段 5，你就能读懂大模型论文和 HuggingFace 源码了。**

## 十、实战练习（可验证小任务）

1. **从零跑通 RNN 语言模型**：用本篇 `CharRNN` + 3.2 训练，确认 loss 从 ~log(vocab) 明显下降；验证：跑 3.3 的 `generate("hello ", 30)` 看是否生成连贯字符。
2. **温度对比**：分别用 `temperature=0.5 / 1.0 / 1.5` 生成，观察「低温度更确定、高温度更多样」，理解采样温度的作用。
3. **记忆实验复现**：跑 `memory_test(5)` 和 `memory_test(30)`，确认长序列准确率下滑，亲手验证「长程遗忘」。
4. **LSTM 对比**：把 `CharRNN` 里的 `nn.RNN` 换成 `nn.LSTM`，在相同步数下对比 loss 下降速度与记忆实验准确率，体会门控的优势。
5. **情感分类**：用 6 节的 `SentimentLSTM` 构造一个「正面/负面」短句数据集（如各 50 条），训练并验证分类准确率，理解「多对一」取最后隐藏态。
6. **注意力预告**：手动算「RNN 第 1 词到第 100 词要 100 步、Transformer 只要 1 步」，写出一句你对「为什么注意力必要」的总结，为下一篇暖场。

## 十一、延伸阅读与下一步

- **经典论文**：Hochreiter & Schmidhuber (1997) *Long Short-Term Memory*、Cho et al. (2014) *GRU*、以及里程碑 *Attention Is All You Need* (Vaswani et al., 2017)——读这三篇你能完整看到「序列建模」从 RNN 到注意力的演进。
- **BPTT 深读**：延伸了解截断 BPTT 的理论依据，以及梯度裁剪（clip grad norm / clip grad value）的区别。
- **现代循环模型**：Mamba（状态空间模型）、RWKV，理解「RNN 思想为何在长上下文/端侧复兴」。
- **与 Transformer 的衔接**：本篇论证了「注意力为什么必要」，下一篇你将亲手推 QKV 矩阵、搭 Self-Attention——把这里的「路径长度=1」变成可运行的代码。
- **下一步**：进入阶段 5《Transformer 与大模型原理》。这是专栏的真正高潮：从注意力机制、位置编码、Encoder-Decoder，到分词与 Embedding、BERT 与 GPT 的分野，最终让你能读懂大模型论文与 HuggingFace 源码。

> 本篇是《大模型开发从 0 到 1》专栏第 27 篇，阶段 4「深度学习与 PyTorch」第 6 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
