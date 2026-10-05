<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# RNN 与 LSTM 序列建模——处理文本与时间序列

**承上**：上一篇《CNN 与计算机视觉》我们处理了有空间结构的图像。

**本篇**：本篇处理有先后顺序的序列：RNN 的循环记忆、LSTM 的三道门，以及它们为何被取代。

**启下**：下一篇进入阶段 5《注意力机制》，看 Transformer 如何一次看全序列且完全并行。

**学完这一节，你能动手做**：

1. 从零实现 RNN，训练字符级语言模型并自回归生成文本
2. 理解 LSTM 三道门如何用加法结构给梯度开高速公路
3. 说清 RNN 的两大死穴，明白注意力机制为什么非有不可


图像是"空间结构"，而**文本、语音、股票、日志**都是**序列**——有先后顺序，前后的元素互相影响。

前面学过的 MLP 和 CNN 都有一个共同缺陷：**输入输出长度固定，且不记得历史**。而语言恰恰是"下一个词取决于前面所有词"。

**RNN（循环神经网络）** 就是为序列设计的：它有一个"隐藏状态"，像记忆一样在时间步之间传递。

这一篇你会：从零实现 RNN、理解 LSTM 的三道门、用 PyTorch 训练一个字符级语言模型，并彻底搞懂——**为什么 Transformer 最终取代了 RNN**。这是理解"注意力为什么必要"的最后一块拼图。

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

### 第二个致命伤：无法并行

```
RNN:  h_1 → h_2 → h_3 → ... → h_T
      必须严格按顺序算，h_3 依赖 h_2，h_2 依赖 h_1
```

**串行 = 慢**。现代 GPU 有几千个核心，最擅长并行，而 RNN 只能一步步来。训练一个 1000 步的序列要等 1000 次串行计算——**这在大数据时代是不可接受的**。

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

### 5.2 为什么 LSTM 能缓解梯度消失？

关键在于 **`C_t = f_t ⊙ C_{t-1} + i_t ⊙ C̃_t`** 这一项的**加法结构**：

- 如果遗忘门 `f_t ≈ 1`、`输入门 i_t ≈ 0`，则 `C_t ≈ C_{t-1}`；
- 此时梯度 `∂C_t/∂C_{t-1} ≈ 1`（**而不是连乘小于 1 的数**）；
- **梯度可以无损地沿细胞状态这条"高速公路"传回很远**。

这就是 LSTM 能记住几百步信息的原因。

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

**但 RNN 并非一无是处**：
- 推理时是 O(1) 内存（Transformer 的 KV Cache 随长度线性增长）——近年 **Mamba、RWKV** 等"状态空间模型"正是基于这个优势在复兴 RNN 思想；
- 小数据、低延迟场景下 GRU 仍然好用。

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

## 九、本篇小结

1. **RNN 的核心是 `h_t = tanh(W_xh·x_t + W_hh·h_{t-1})`**，用隐藏状态在时间步之间传递记忆，权值在时间上共享。
2. 我们**从零实现了 RNN**，并用 PyTorch 训练了一个**字符级语言模型**，学会了自回归采样生成（`multinomial` 按概率抽样）。
3. **RNN 两大死穴**：梯度消失（连乘衰减，记不住长距离）+ **无法并行**（必须串行，GPU 跑不满）。
4. **LSTM 用三道门 + 细胞状态的加法结构**给梯度开了高速公路，缓解了梯度消失；GRU 是其简化版。
5. **Transformer 用注意力把任意两位置的路径长度压缩到 1，且完全并行**——这两点直接终结了 RNN 的统治，成就了今天所有大模型。

**阶段 4 深度学习与 PyTorch 到此完结。** 你已经会用 PyTorch 搭网络、写训练循环、处理图像和序列。

下一篇进入 **阶段 5：Transformer 与大模型原理**——真正的重头戏。我们会从注意力机制开始，手推 QKV 矩阵，逐层拆解 Transformer 架构，理解分词与 Embedding，最后搞懂 BERT 与 GPT 的分野。**学完阶段 5，你就能读懂大模型论文和 HuggingFace 源码了。**

> 本篇是《大模型开发从 0 到 1》专栏第 27 篇，阶段 4「深度学习与 PyTorch」第 6 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
