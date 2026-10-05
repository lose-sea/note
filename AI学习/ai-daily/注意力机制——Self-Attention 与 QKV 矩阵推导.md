<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 注意力机制——Self-Attention 与 QKV 矩阵推导

**承上**：上一篇《RNN 与 LSTM 序列建模》我们亲手训练了字符级语言模型，也看清了 RNN 的两个死穴——必须串行算（GPU 跑不满）、距离一长就遗忘（梯度连乘衰减）。

**本篇**：这一篇学注意力机制。它让序列里**任意两个位置直接对话**，把最长路径从 O(n) 压到 O(1)，而且完全并行。我们会手推 QKV 与缩放点积公式的每一步维度变化。

**启下**：但单头注意力只有"一种看法"，而且它**分不清词的先后顺序**。下一篇《多头注意力与位置编码》补齐这两块，那才是 Transformer 里真正用的形态。

**学完这一节，你能动手做**：

1. 用 NumPy 从零写出 Self-Attention，打印并读懂注意力权重矩阵
2. 手推 `softmax(QKᵀ/√d_k)V` 每一步的维度变化，说清为什么要除以 √d_k
3. 给注意力加上因果 mask，写出 GPT 解码器的核心部件

---

## 一、先建立直觉：注意力就是"带权重的查字典"

假设你在读这句话：

> 那只**猫**追着一只**小**老**鼠**跑进了厨房

当你处理"追"这个词时，你脑子里会自动去找：**谁在追？追什么？** 答案分别是"猫"和"老鼠"。你不会平均地看待句子里每个词，而是把注意力**分配**给相关的几个词。

注意力机制就是把这件事写成数学。它给每个词准备三个身份：

| 身份 | 英文名 | 作用 | 一句话理解 |
|---|---|---|---|
| 查询 | Query (Q) | "我要找什么样的信息" | 我发出的检索条件 |
| 键 | Key (K) | "我这里有什么样的信息" | 每个词的标签/索引 |
| 值 | Value (V) | "我真正能提供的信息" | 检索到的内容本体 |

对应到图书馆：

```
Query  = 你写在检索卡上的关键词
Key    = 每本书书脊上的分类号
Value  = 书里的正文

流程：用 Query 和所有 Key 算相似度 → 归一化成权重 → 按权重把 Value 加权求和
```

关键在于：**Q、K、V 都不是原始词向量，而是由同一个输入向量经过三次不同的线性变换得到的**。模型训练的目标，就是学会这三组变换矩阵，让它知道"什么时候该关注谁"。

## 二、五步推导：从公式到维度

设输入序列有 `n` 个 token，每个 token 的向量维度是 `d_model`。我们把它堆成一个矩阵 `X`，形状 `(n, d_model)`。

```
X = [[x₁],
     [x₂],        shape = (n, d_model)
     ...
     [xₙ]]
```

### 第 1 步：投影出 Q、K、V

```
Q = X · W_Q      W_Q: (d_model, d_k)
K = X · W_K      W_K: (d_model, d_k)
V = X · W_V      W_V: (d_model, d_v)
```

注意 **W 是共享的**——所有位置用同一组矩阵。这就是"权值共享"，也是 Transformer 参数量不随序列长度增长的原因。

> 为什么 Q 和 K 的维度必须一样（都是 d_k），而 V 可以不一样？因为 Q 和 K 要**做点积**，维度必须对齐；V 只是被加权求和，维度自由。实践中通常取 `d_k = d_v = d_model / h`（h 是头数，下一篇会讲）。

### 第 2 步：算相似度分数

```
S = Q · Kᵀ        shape = (n, d_k) × (d_k, n) = (n, n)
```

这个 `(n, n)` 的矩阵就是**注意力分数矩阵**。`S[i][j]` 表示第 i 个词对第 j 个词的"关注度"。

### 第 3 步：缩放（关键！）

```
S = S / √d_k
```

为什么要除以 √d_k？假设 q 和 k 的每个分量都是均值 0、方差 1 的独立随机变量，那么点积 `q·k = Σ qᵢkᵢ` 的**方差是 d_k**（方差可加）。d_k 越大，点积的绝对值越大，有些值会跑到很大——一旦送进 softmax，就会把分布推向**极端的 one-hot**（梯度接近 0，训练不动）。除以 √d_k 把方差拉回 1。

### 第 4 步：softmax 归一化

```
A = softmax(S, dim=-1)      shape = (n, n)，每行和为 1
```

对每一行做 softmax，于是每个词对全句的注意力权重加起来 = 1，变成了一个**概率分布**。

### 第 5 步：加权求和得到输出

```
Output = A · V              shape = (n, n) × (n, d_v) = (n, d_v)
```

### 合成一行就是那个著名的公式

```
                     QKᵀ
Attention(Q, K, V) = softmax(------) V
                      √d_k
```

整个过程的形状变化一览：

```
X      (n, d_model)
  ├─→ Q (n, d_k) ─┐
  ├─→ K (n, d_k) ─┴→ QKᵀ (n,n) → /√d_k → softmax → A (n,n)
  └─→ V (n, d_v) ─────────────────────────────→ A·V (n, d_v)
```

**注意输入输出都是 `(n, ·)`**——序列长度不变，变的是每个位置的向量内容：它从"孤立的词"变成了"融合了上下文的词"。这就是"语境化表示"。

## 三、代码实战 1：NumPy 从零手写 Self-Attention

我们用一个人造例子，让注意力权重**可解释**。设计 4 个 token，每个用 4 维特征表示：

| token | 特征含义 |
|---|---|
| 猫 | f0=1（施事 / 动作发出者） |
| 追 | f1=1（动词） |
| 小 | f3=1（修饰语） |
| 鼠 | f2=1（受事 / 动作承受者） |

然后手工设定 W_Q / W_K：**让动词去查询论元，让名词去查询动词**。

```python
import numpy as np

# ---------- 1. 输入：4 个 token，每个 4 维特征 ----------
# 特征含义：f0=施事(动作发出者)  f1=动词  f2=受事(动作承受者)  f3=修饰语
tokens = ["猫", "追", "小", "鼠"]
X = np.array([
    [1, 0, 0, 0],   # 猫：施事
    [0, 1, 0, 0],   # 追：动词
    [0, 0, 0, 1],   # 小：修饰语
    [0, 0, 1, 0],   # 鼠：受事
], dtype=float)
n, d_model = X.shape          # n=4, d_model=4
d_k = d_v = 3

# ---------- 2. 手工设计三组投影矩阵 ----------
# 设计意图：
#   query 第0维 = 动词强度  → 动词用它去查"谁参与了动作"
#   key   第0维 = 论元强度  → 施事/受事在这个维度上有值
#   query 第2维 = 论元强度  → 名词用它去查"哪个动词作用于我"
#   key   第2维 = 动词强度
W_Q = np.zeros((d_model, d_k))
W_Q[1, 0] = 2.0     # 动词  -> query dim0
W_Q[0, 2] = 2.0     # 施事  -> query dim2
W_Q[2, 2] = 2.0     # 受事  -> query dim2

W_K = np.zeros((d_model, d_k))
W_K[0, 0] = 2.0     # 施事  -> key dim0
W_K[2, 0] = 2.0     # 受事  -> key dim0
W_K[1, 2] = 2.0     # 动词  -> key dim2

W_V = np.eye(d_model, d_v)    # value 直接取前 3 维特征

Q, K, V = X @ W_Q, X @ W_K, X @ W_V

# ---------- 3. 缩放点积注意力 ----------
scores = Q @ K.T / np.sqrt(d_k)          # (n, n)

def softmax(z):
    z = z - z.max(axis=-1, keepdims=True)   # 减最大值，数值稳定
    e = np.exp(z)
    return e / e.sum(axis=-1, keepdims=True)

A = softmax(scores)
out = A @ V

np.set_printoptions(precision=3, suppress=True)
print("注意力权重矩阵 A（行=当前词, 列=被关注的词）")
print("        " + "  ".join(f"{t:>6s}" for t in tokens))
for i, t in enumerate(tokens):
    print(f"{t:>4s}  " + "  ".join(f"{w:6.3f}" for w in A[i]))
print("\n输出向量 out（每行和为1的加权结果）:")
for i, t in enumerate(tokens):
    print(f"  {t}: {out[i]}")
```

运行结果：

```
注意力权重矩阵 A（行=当前词, 列=被关注的词）
             猫      追      小      鼠
  猫     0.077   0.770   0.077   0.077
  追     0.455   0.045   0.045   0.455
  小     0.250   0.250   0.250   0.250
  鼠     0.077   0.770   0.077   0.077

输出向量 out（每行和为1的加权结果）:
  猫: [0.077 0.77  0.077]
  追: [0.455 0.045 0.455]
  小: [0.25  0.25  0.25 ]
  鼠: [0.077 0.77  0.077]
```

**逐行解读**（这是理解注意力最重要的一步）：

- **`追` 行 = [0.455, 0.045, 0.045, 0.455]`**：动词"追"把 91% 的注意力平均分给了"猫"和"鼠"——也就是**谁在追**和**追什么**。它的输出 `[0.455, 0.045, 0.455]` 正是"施事 + 受事"信息的混合（因为 value 取的是输入前 3 维，猫贡献第 0 维、鼠贡献第 2 维）。这就是句法里说的**论元结构**，模型自己从数据里学出来了。
- **`猫` 行 / `鼠` 行**：都把 0.77 给了"追"——名词在找**作用于自己的动词**。
- **`小` 行 = 均匀分布**：因为我们的 W_Q 没给"修饰语"设计查询方向（query 全 0），分数全为 0，softmax 退化成平均。真实模型里这一行会去关注它修饰的名词。

这个例子揭示的本质是：**注意力 = 内容寻址的软检索**。权重不是写死的，而是由 Q 和 K 的内容动态算出来的。

## 四、代码实战 2：加上因果 mask，写成 PyTorch 模块

自注意力有个问题：算第 i 个位置的输出时，它能看到**所有**位置，包括后面的。这在理解任务（BERT）里没问题，但在**生成任务**（GPT）里是作弊——预测第 5 个词时不能偷看第 6 个词。解决办法是**因果 mask（causal mask）**：把未来位置的分数设成 -∞，softmax 后权重变成 0。

```
mask 矩阵（✓=可见, ✗=屏蔽）    对应 GPT 的预测方向

      t1  t2  t3  t4              t1 → 只能看自己
t1    ✓   ✗   ✗   ✗              t2 → 看 t1,t2
t2    ✓   ✓   ✗   ✗              t3 → 看 t1,t2,t3
t3    ✓   ✓   ✓   ✗              t4 → 看全部
t4    ✓   ✓   ✓   ✓
```

```python
import torch
import torch.nn as nn
import torch.nn.functional as F
import math

class SelfAttention(nn.Module):
    """单头缩放点积注意力，支持因果 mask。"""

    def __init__(self, d_model: int, d_k: int, d_v: int):
        super().__init__()
        self.d_k = d_k
        self.W_Q = nn.Linear(d_model, d_k, bias=False)
        self.W_K = nn.Linear(d_model, d_k, bias=False)
        self.W_V = nn.Linear(d_model, d_v, bias=False)

    def forward(self, x, causal: bool = False):
        # x: (batch, n, d_model)
        Q = self.W_Q(x)
        K = self.W_K(x)
        V = self.W_V(x)

        # (batch, n, d_k) x (batch, d_k, n) -> (batch, n, n)
        scores = Q @ K.transpose(-2, -1) / math.sqrt(self.d_k)

        if causal:
            n = x.size(1)
            # 上三角（不含对角线）置为 -inf
            mask = torch.triu(torch.ones(n, n, dtype=torch.bool), diagonal=1)
            scores = scores.masked_fill(mask, float("-inf"))

        A = F.softmax(scores, dim=-1)
        return A @ V, A          # 输出 + 注意力权重（便于可视化）

# ---- 跑一遍 ----
torch.manual_seed(42)
batch, n, d_model = 1, 5, 16
x = torch.randn(batch, n, d_model)
attn = SelfAttention(d_model, d_k=16, d_v=16)

out_bi, a_bi = attn(x, causal=False)      # 双向（BERT 风格）
out_ca, a_ca = attn(x, causal=True)       # 因果（GPT 风格）

print("输出形状:", out_bi.shape)                 # torch.Size([1, 5, 16])
print("双向 每行权重和:", a_bi.sum(-1))           # 全为 1
print("因果 注意力矩阵:")
print(a_ca[0].detach().numpy().round(3))
```

输出（因果模式下注意力矩阵形如）：

```
[[1.    0.    0.    0.    0.   ]     ← 第1个词只看自己
 [0.42  0.58  0.    0.    0.   ]     ← 第2个词看前2个
 [0.31  0.27  0.42  0.    0.   ]
 [0.22  0.31  0.19  0.28  0.   ]
 [0.19  0.24  0.22  0.17  0.18 ]]    ← 最后一行仍可看全部
```

下三角全是有效权重，上三角严格为 0——这就是 GPT 能"一个字一个字往外吐"的原因。

**验证一下有没有写错**：PyTorch 自带了官方实现，可以直接对拍（这是写底层代码最有用的习惯）：

```python
# 与官方实现对比（batch-first 需转置）
official = nn.MultiheadAttention(d_model, num_heads=1, batch_first=True)
official.load_state_dict({
    "in_proj_weight": torch.cat([attn.W_Q.weight, attn.W_K.weight, attn.W_V.weight], 0),
    "in_proj_bias": torch.zeros(3 * d_model),
    "out_proj.weight": torch.eye(d_model),
    "out_proj.bias": torch.zeros(d_model),
}, strict=False)

y, _ = official(x, x, x, need_weights=False)
print("与官方实现最大误差:", (y - out_bi).abs().max().item())
# 与官方实现最大误差: 约 1e-7 量级（浮点误差）
```

> 官方 `MultiheadAttention` 内部把 Q/K/V 打包成一个 `in_proj_weight`（按 Q、K、V 顺序拼接），并多了一个输出投影层 `out_proj`。我们这里令 `out_proj` 为单位阵，就能直接对拍。

## 五、为什么 Self-Attention 赢了：三种架构的复杂度对比

这是论文《Attention Is All You Need》里那张经典表格，也是理解"为什么是 Transformer"的核心：

| 层类型 | 每层复杂度 | 顺序操作数（可并行度） | 任意两位置最长路径 |
|---|---|---|---|
| 全连接（MLP） | O(n · d²) | O(1) ✅ | O(1) ✅ |
| 卷积（CNN） | O(k · n · d²) | O(1) ✅ | O(n / k) ❌ |
| 循环（RNN） | O(n · d²) | **O(n)** ❌ | **O(n)** ❌ |
| **Self-Attention** | **O(n² · d)** | **O(1)** ✅ | **O(1)** ✅ |

三条结论：

1. **最短路径 O(1)**：任意两个 token 之间只有一步之遥，彻底解决 RNN 的长程遗忘。
2. **顺序操作 O(1)**：所有位置同时算，一次矩阵乘法搞定，GPU 利用率拉满。这是大模型能训练起来的工程前提。
3. **代价是 O(n²)**：序列长度翻倍，注意力计算量翻**四倍**。这就是"上下文长度"昂贵、各种长上下文优化（FlashAttention、稀疏注意力、线性注意力）存在的根本原因。

当 `n < d` 时（比如 n=2048, d=12288，GPT-3 的规模），`n²d` 反而比 RNN 的 `nd²` 更小——self-attention 在实际配置下甚至更快。

## 六、常见坑（这些错我见过太多次）

| 坑 | 现象 | 正确做法 |
|---|---|---|
| 忘除 √d_k | 训练初期 loss 不动、梯度接近 0 | softmax 前必须缩放 |
| 生成任务忘加因果 mask | 训练 loss 很低，一生成就复读/胡说 | 解码器必须 mask 上三角 |
| mask 用 0 而不是 -inf | 未来位置仍分到权重 | 要 `-inf`（或 `-1e9`），因为 softmax(0) ≠ 0 |
| padding 没屏蔽 | `<pad>` 抢走注意力 | 用 attention_mask 把 padding 位置置 -inf |
| softmax 溢出 | 出现 nan | 先减最大值再 exp（PyTorch 的 softmax 已内置） |
| 转置写错 | 形状报错或结果诡异 | 记住 `Q @ K.transpose(-2,-1)`，不是 `K @ Q` |
| 把 d_k 设得极大 | 显存爆炸 + 注意力过尖锐 | d_k = d_model / h |

## 七、本篇小结

1. **注意力的本质**是"内容寻址的软检索"：用 Query 和 Key 算相似度，归一化成概率，再对 Value 加权求和。
2. **五步公式**：`Q=XW_Q → K=XW_K → V=XW_V → S=QKᵀ/√d_k → A=softmax(S) → Out=A·V`。
3. **除以 √d_k** 是为了压住点积方差（方差 = d_k），避免 softmax 饱和成 one-hot、梯度消失。
4. **Self-Attention 让任意两位置路径长度为 1 且完全并行**，代价是 O(n²) 的计算量。
5. **因果 mask**（上三角置 -inf）是自回归生成的前提，也是 BERT 与 GPT 的第一个分水岭。

**下一篇**：你会立刻发现单头注意力的两个短板——它只有**一种**关注视角，而且**完全不知道词的先后顺序**（把句子打乱，输出只是跟着换了行，内容一模一样）。下一篇《多头注意力与位置编码》来解决这两件事，并手写正弦位置编码。

> 本篇是《大模型开发从 0 到 1》专栏第 28 篇，阶段 5「Transformer 与大模型原理」第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
