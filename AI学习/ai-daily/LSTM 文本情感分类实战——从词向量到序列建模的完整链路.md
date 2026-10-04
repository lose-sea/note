<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# LSTM 文本情感分类实战——从词向量到序列建模的完整链路

## 一、RNN 的初衷，和它为什么不够用

处理文字和处理图像最大的差别是：**文字有顺序，而且长度可变**。"我不觉得这个电影好看" 和 "我觉得这个电影不好看"，词几乎一样，意思却相反。

RNN 的思路很朴素——**带一个记忆往前走**：

```
    h₀ ──→ h₁ ──→ h₂ ──→ h₃ ──→ ... ──→ hₜ
     ↑      ↑      ↑      ↑              ↑
    x₁     x₂     x₃     x₄             xₜ

hₜ = tanh(W·xₜ + U·hₜ₋₁ + b)
     ↑ 当前输入  ↑ 上一步的记忆
```

每一步把"当前词"和"上一步的记忆"揉在一起，得到新记忆传给下一步。理论上它能记住任意长的历史。

但实践中有两个致命问题：

```
┌─────────────────────────────────────────────────────────────┐
│  ① 梯度消失                                                   │
│     BPTT 反传要连乘每一步的雅可比矩阵，tanh 的导数 ≤ 0.25      │
│     连乘 50 次 → 0.25⁵⁰ ≈ 8e-31，梯度彻底消失                │
│     → 模型只能记住最近几步，长距离依赖学不到                  │
│                                                              │
│  ② 梯度爆炸                                                   │
│     权重稍大时连乘 → 数值爆炸 → 变成 NaN，训练直接崩          │
└─────────────────────────────────────────────────────────────┘
```

一句话总结：**标准 RNN 的"记忆"是每步全量覆盖的，信息在传递中不断被稀释。**

## 二、LSTM 的核心：用"门"来控制记忆

LSTM 没有推倒重来，而是给记忆加了一套**开关系统**。它在每一步维护两个东西：

- **细胞状态 Cₜ**：长期记忆，像一条传送带，信息主要在上面做"加/减"
- **隐状态 hₜ**：短期输出，也用来控制门

那三个"门"分别是：

```
┌──────────────────────────────────────────────────────────────┐
│  遗忘门 f = σ(Wf·[hₜ₋₁, xₜ] + bf)   → 决定旧记忆丢掉多少      │
│  输入门 i = σ(Wi·[hₜ₋₁, xₜ] + bi)   → 决定新信息写入多少      │
│  候选值 g = tanh(Wg·[hₜ₋₁, xₜ] + bg) → 待写入的新内容          │
│  输出门 o = σ(Wo·[hₜ₋₁, xₜ] + bo)   → 决定对外暴露多少        │
└──────────────────────────────────────────────────────────────┘

更新公式：
  Cₜ = f ⊙ Cₜ₋₁ + i ⊙ g        ← 长期记忆：旧的忘一部分 + 新的记一部分
  hₜ = o ⊙ tanh(Cₜ)            ← 短期输出
```

关键洞察在这条公式里：

```
Cₜ = f ⊙ Cₜ₋₁ + i ⊙ g
```

当 `f ≈ 1` 时，旧记忆**原封不动传下去**。这意味着梯度沿细胞状态反向传播时，是一条"加法通道"而不是"连乘通道"，**梯度不会指数衰减**。这就是 LSTM 能记住长距离依赖的根本原因。

用一句话记住三门的职责：**遗忘门负责丢，输入门负责记，输出门负责说。**

## 三、代码实战（一）：用 nn.LSTM 做情感分类

我们用一个极简的合成数据集，把"词向量 → LSTM → 分类"整条链路跑通。

```python
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader
import numpy as np

torch.manual_seed(0); np.random.seed(0)
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

VOCAB, MAX_LEN, EMBED_DIM, HIDDEN = 500, 20, 64, 96

# ---------- 造一份合成情感数据：含 "好/棒" 为正，含 "差/烂" 为负 ----------
POS_WORDS = [1, 2, 3]      # 假想的正面词 id
NEG_WORDS = [4, 5, 6]      # 假想的负面词 id

def make_sample():
    length = np.random.randint(8, MAX_LEN)
    ids = np.random.randint(7, VOCAB, size=length).tolist()
    label = np.random.randint(2)
    keyword = np.random.choice(POS_WORDS if label == 1 else NEG_WORDS)
    pos = np.random.randint(0, length)
    ids[pos] = keyword                      # 在随机位置插入决定性关键词
    ids = ids[:MAX_LEN] + [0] * (MAX_LEN - len(ids))   # 对齐到固定长度
    return ids, label

class SentimentDataset(Dataset):
    def __init__(self, n=6000):
        self.data = [make_sample() for _ in range(n)]
    def __len__(self): return len(self.data)
    def __getitem__(self, i):
        ids, label = self.data[i]
        return torch.tensor(ids, dtype=torch.long), torch.tensor(label, dtype=torch.float32)

train_ds, val_ds = SentimentDataset(6000), SentimentDataset(1500)
train_loader = DataLoader(train_ds, batch_size=64, shuffle=True)
val_loader = DataLoader(val_ds, batch_size=256)

class LSTMClassifier(nn.Module):
    def __init__(self, vocab_size, embed_dim, hidden, num_layers=2, pad_idx=0):
        super().__init__()
        # padding_idx 让补齐位的 embedding 恒为 0 且不参与梯度更新
        self.embed = nn.Embedding(vocab_size, embed_dim, padding_idx=pad_idx)
        self.lstm = nn.LSTM(
            input_size=embed_dim, hidden_size=hidden, num_layers=num_layers,
            batch_first=True,          # 输入形状 (batch, seq, feature)，务必设 True
            bidirectional=True,        # 双向：同时看前文和后文
            dropout=0.3,
        )
        self.dropout = nn.Dropout(0.4)
        self.fc = nn.Linear(hidden * 2, 1)    # 双向 → 2*hidden

    def forward(self, x):
        # padding 位置的 mask（用于后面的池化，避免把补齐位算进来）
        mask = (x != 0).float().unsqueeze(-1)          # (B, L, 1)
        emb = self.dropout(self.embed(x))              # (B, L, E)
        out, _ = self.lstm(emb)                        # (B, L, 2H)
        # 掩码平均池化：只对真实 token 求平均
        out = (out * mask).sum(1) / mask.sum(1).clamp(min=1e-6)
        return self.fc(self.dropout(out)).squeeze(-1)  # 返回 logits

model = LSTMClassifier(VOCAB, EMBED_DIM, HIDDEN).to(device)
print(model)
print("参数量：", sum(p.numel() for p in model.parameters()))

criterion = nn.BCEWithLogitsLoss()
optimizer = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=12)

for epoch in range(1, 13):
    model.train(); tr_loss, tr_correct, n = 0.0, 0, 0
    for xb, yb in train_loader:
        xb, yb = xb.to(device), yb.to(device)
        logits = model(xb)
        loss = criterion(logits, yb)
        optimizer.zero_grad(); loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 5.0)   # 梯度裁剪，防爆炸
        optimizer.step()
        tr_loss += loss.item() * xb.size(0)
        tr_correct += ((torch.sigmoid(logits) > 0.5).float() == yb).sum().item()
        n += xb.size(0)
    scheduler.step()

    model.eval(); va_correct, vn = 0, 0
    with torch.no_grad():
        for xb, yb in val_loader:
            p = (torch.sigmoid(model(xb.to(device))) > 0.5).float()
            va_correct += (p == yb.to(device)).sum().item(); vn += xb.size(0)

    if epoch % 3 == 0:
        print(f"epoch {epoch:2d} | train loss {tr_loss/n:.4f} acc {tr_correct/n:.3f}"
              f" | val acc {va_correct/vn:.3f}")
```

典型输出：

```
epoch  3 | train loss 0.6102 acc 0.668 | val acc 0.712
epoch  6 | train loss 0.4127 acc 0.829 | val acc 0.861
epoch  9 | train loss 0.2718 acc 0.901 | val acc 0.912
epoch 12 | train loss 0.1804 acc 0.944 | val acc 0.933
```

注意关键词只出现在**随机位置**，而 `MAX_LEN=20`。如果换成标准 RNN，位置靠前的关键词很容易被后面十几步冲淡；LSTM 靠细胞状态的加法通道把信息保住了——这正是它比 RNN 强的直观体现。

## 四、代码实战（二）：手写一个 LSTMCell，验证理解

不亲手写一遍门控，公式永远记不牢。

```python
class MyLSTMCell(nn.Module):
    """单步 LSTM，input: (B, E)，state: (h, c) 各 (B, H)"""
    def __init__(self, input_size, hidden_size):
        super().__init__()
        self.hidden_size = hidden_size
        # 一次性算 4 组门：顺序为 [i, f, g, o]
        self.linear = nn.Linear(input_size + hidden_size, 4 * hidden_size)

    def forward(self, x, state):
        h_prev, c_prev = state
        gates = self.linear(torch.cat([x, h_prev], dim=-1))       # (B, 4H)
        i, f, g, o = gates.chunk(4, dim=-1)                       # 切成四个门
        i, f, o = torch.sigmoid(i), torch.sigmoid(f), torch.sigmoid(o)
        g = torch.tanh(g)                                         # 候选值用 tanh
        c = f * c_prev + i * g                                    # 核心更新公式
        h = o * torch.tanh(c)
        return h, (h, c)

# 与官方实现数值对齐验证
torch.manual_seed(1)
E, H, B = 8, 6, 3
my_cell = MyLSTMCell(E, H)
ref = nn.LSTMCell(E, H)

# 把两者参数对齐（官方 LSTM 的权重是 i,f,g,o 拼在一起的）
with torch.no_grad():
    ref.weight_ih.copy_(my_cell.linear.weight[:, :E])
    ref.weight_hh.copy_(my_cell.linear.weight[:, E:])
    ref.bias_ih.copy_(my_cell.linear.bias)
    ref.bias_hh.zero_()

x  = torch.randn(B, E)
h0 = torch.randn(B, H); c0 = torch.randn(B, H)

h_my, (_, c_my) = my_cell(x, (h0, c0))
h_ref, c_ref = ref(x, (h0, c0))

print("h 最大误差:", (h_my - h_ref).abs().max().item())
print("c 最大误差:", (c_my - c_ref).abs().max().item())
print("✓ 与 nn.LSTMCell 数值一致" if (h_my - h_ref).abs().max() < 1e-5 else "✗ 不一致")
```

输出：

```
h 最大误差: 2.384e-07
c 最大误差: 1.192e-07
✓ 与 nn.LSTMCell 数值一致
```

能对齐官方的数值，说明门的顺序、激活函数的选择（**三处 sigmoid + 一处 tanh**）全都写对了。这个验证手法非常值得学——**手写实现后一定要和官方实现数值对齐，比"看起来对"可靠得多。**

## 五、RNN / LSTM / GRU 对比

| 维度 | 标准 RNN | LSTM | GRU |
|---|---|---|---|
| 状态数 | 1 个 h | 2 个 (h, c) | 1 个 h |
| 门数量 | 无 | 3 个（遗忘/输入/输出） | 2 个（更新/重置） |
| 长依赖能力 | 差（梯度消失） | **强** | 较强 |
| 参数量（每层） | 4H(E+H) | 4H(E+H)×4 | 3H(E+H)×4 |
| 计算速度 | 快 | 慢 | 中等（≈LSTM 的 75%） |
| 典型适用 | 短序列、教学 | 长文本、需要精确记忆 | 数据量中等、追求速度 |
| PyTorch | `nn.RNN` | `nn.LSTM` | `nn.GRU` |

选型建议很简单：**默认用 LSTM；如果数据集不大且训练太慢，换 GRU 通常能省 20%~30% 时间而精度几乎不掉；只有在序列很短（<10 步）时才考虑标准 RNN。**

## 六、几个常见的坑

**坑 1：忘了 `batch_first=True`。**
PyTorch 的 RNN 系列默认输入是 `(seq_len, batch, feature)`。数据是 `(batch, seq, feature)` 时输出维度会错位，通常表现为验证准确率卡在 50% 不动，或者取 `out[:, -1]` 拿到的是错的语义。

**坑 2：拿最后一个时间步做分类，却被 padding 污染。**
补齐到固定长度后，`out[:, -1]` 很可能拿的是 `<pad>` 位置的输出。正确做法是**用 mask 做掩码池化**（像上面那样），或者用 `pack_padded_sequence` + `pad_packed_sequence` 告诉 LSTM 真实长度。

**坑 3：`nn.LSTM` 忘了接收 `(h0, c0)` 是元组。**
`nn.LSTM` 返回 `(output, (hn, cn))`，而 `nn.RNN` 返回 `(output, hn)`。写 `out, h = lstm(x)` 时 `h` 其实是个元组，后面拿 `h[-1]` 会静默拿到错的张量。要写 `out, (hn, cn) = lstm(x)`。

**坑 4：不做梯度裁剪。**
LSTM 虽然缓解了梯度消失，但**梯度爆炸依然存在**。`clip_grad_norm_(params, 5.0)` 是标配，省掉它训练跑到一半变成 NaN 的概率会明显上升。

**坑 5：多层 LSTM 没加 dropout，或者加了单层 dropout。**
`nn.LSTM(dropout=0.3)` 只在**层与层之间**生效，`num_layers=1` 时这个参数会被忽略并且给出 warning。单层模型要在 LSTM 输出后自己接 `nn.Dropout`。

## 七、小结

把这条链路再串一遍，就是 LSTM 解决序列任务的完整思路：

```
文本 → Embedding 词向量 → LSTM 逐时刻门控更新状态
     → 掩码池化（或取最后有效步）→ 全连接 → logits → 分类
                ↑
        Cₜ = f⊙Cₜ₋₁ + i⊙g   加法通道 → 梯度不衰减 → 长依赖记得住
```

真正要带走的三点：

1. **LSTM 解决的是 RNN 的梯度问题**，机制是"细胞状态的加法更新通道"，不是什么玄学；
2. **`batch_first` / `padding_idx` / mask 池化**这三个细节，决定模型是能用还是看着收敛实则学错；
3. **手写 cell 并与官方数值对齐**，是验证自己"真懂了"最快的方式。

把这套流程换成真实数据集（如中文评论情感分析），只需要替换 `SentimentDataset` 里的分词和词表构建，其余部分直接复用。
