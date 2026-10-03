<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# Transformer 与注意力机制——从 Self-Attention 到多头注意力

## 一、为什么需要注意力机制

在 Transformer 出现之前，处理序列（句子、时间序列）靠的是 RNN / LSTM。它们有个致命问题：**必须一个词一个词按顺序处理，而且距离越远，信息越容易丢失**。

举个例子：

```
"那只猫跳上了窗台，它晒了一会儿太阳，然后______"
```

要填最后的空，模型得知道主语是"猫"。但"猫"距离句尾隔了十几个词，RNN 要一路传递状态，传着传着就忘了。

**注意力机制的解法非常直觉：别传了，让每个词直接"看"所有词，自己决定该关注谁。**

处理"它"这个词时，模型直接计算它与句子中每个词的关联度，发现"猫"的关联度最高，于是把"猫"的信息加权吸收过来。这个"关联度"就是**注意力权重**。

一句话概括：**注意力 = 按相关性做加权平均**。

## 二、Self-Attention 的核心：Q / K / V

Self-Attention（自注意力）的公式只有一行：

```
Attention(Q, K, V) = softmax(QKᵀ / √d_k) V
```

看起来抽象，拆成 Q、K、V 三个角色就清楚了：

| 角色 | 名字 | 类比 | 作用 |
| ---- | ---- | ---- | ---- |
| **Q** | Query 查询 | 你在搜索引擎输入的关键词 | "我现在要找什么" |
| **K** | Key 键 | 网页的标题/标签 | "我这里有什么可被检索的" |
| **V** | Value 值 | 网页的实际内容 | "被选中后真正取走的信息" |

计算分四步：

```
1. 打分：Q 与每个 K 做点积  →  得到"我和你有多相关"
2. 缩放：除以 √d_k          →  防止点积过大把 softmax 推到饱和区
3. 归一：softmax            →  转成加起来等于 1 的权重
4. 加权：用权重对 V 求和    →  得到输出
```

### 2.1 为什么要除以 √d_k

这是论文里最容易被忽略但很关键的细节。

假设 Q 和 K 的每个分量都是均值 0、方差 1 的随机变量，维度是 `d_k`，那么它们的点积 `q·k` 的**方差是 `d_k`**（方差可加）。当 `d_k = 512` 时，点积的典型值会到 ±20 量级。

softmax 在输入很大时会变得极其"陡峭"——几乎全部概率集中在最大那一项，梯度趋近于 0，训练就直接卡死了。

除以 `√d_k` 后，方差回到 1，softmax 保持在梯度健康的区间。

> 一句话：**缩放是为了让 softmax 别饱和，保证梯度能传回去**。

### 2.2 手写一个 Self-Attention

用 PyTorch 从零实现一遍，比看十遍公式都管用：

```python
import torch
import torch.nn.functional as F

torch.manual_seed(0)

# 假设： batch=1, 序列长度=4(4个词), 每个词用 8 维向量表示
seq_len, d_model = 4, 8
x = torch.randn(1, seq_len, d_model)      # 输入 (1, 4, 8)

# 三个线性变换矩阵，把输入映射成 Q / K / V
W_q = torch.randn(d_model, d_model) * 0.1
W_k = torch.randn(d_model, d_model) * 0.1
W_v = torch.randn(d_model, d_model) * 0.1

Q = x @ W_q      # (1, 4, 8)
K = x @ W_k      # (1, 4, 8)
V = x @ W_v      # (1, 4, 8)

# 步骤 1-2：打分 + 缩放
d_k = d_model
scores = Q @ K.transpose(-2, -1) / (d_k ** 0.5)   # (1, 4, 4)
print("打分矩阵 shape:", scores.shape)

# 步骤 3：softmax 归一（在最后一个维度上）
attn_weights = F.softmax(scores, dim=-1)          # 每行和为 1
print("注意力权重（每行是某个词对所有词的关注度）:")
print(attn_weights[0].detach().numpy().round(3))

# 步骤 4：加权求和
out = attn_weights @ V                            # (1, 4, 8)
print("\n输出 shape:", out.shape)                 # 与输入形状一致
```

输出示例：

```
打分矩阵 shape: torch.Size([1, 4, 4])
注意力权重（每行是某个词对所有词的关注度）:
[[0.271 0.219 0.301 0.208]
 [0.243 0.278 0.234 0.245]
 [0.285 0.213 0.264 0.238]
 [0.226 0.256 0.243 0.275]]

输出 shape: torch.Size([1, 4, 8])
```

注意两个关键点：

1. **权重矩阵是 4×4**：第 i 行第 j 列 = "第 i 个词对第 j 个词的关注度"，每行和为 1。
2. **输入输出形状相同**：`(1,4,8)` 进，`(1,4,8)` 出。这意味着 Attention 层可以**堆叠**，这才有后面的多层 Transformer。

## 三、多头注意力 Multi-Head Attention

单个注意力有个局限：**一次只能关注一种关系**。但句子里的关系是多维的——"它"要关注指代对象（语法关系），"跳"要关注主语（语义关系）。

多头注意力的思路：**把向量切成 h 份，每份独立做一次注意力，最后拼起来**。

```
输入 (batch, seq_len, d_model=512)
    ↓  切成 h=8 份，每份 64 维
Head 1 ─┐
Head 2 ─┤   各自独立算 Attention
 ...    ├─→ 得到 8 个 (seq_len, 64)
Head 8 ─┘
    ↓  拼接 concat 回 512 维
    ↓  再过一个线性层 W_o
输出 (batch, seq_len, 512)
```

代码实现：

```python
class MultiHeadAttention(torch.nn.Module):
    def __init__(self, d_model=512, num_heads=8):
        super().__init__()
        assert d_model % num_heads == 0, "d_model 必须能被 num_heads 整除"
        self.d_model = d_model
        self.num_heads = num_heads
        self.d_k = d_model // num_heads      # 每个头的维度

        self.W_q = torch.nn.Linear(d_model, d_model)
        self.W_k = torch.nn.Linear(d_model, d_model)
        self.W_v = torch.nn.Linear(d_model, d_model)
        self.W_o = torch.nn.Linear(d_model, d_model)

    def forward(self, x):
        batch, seq_len, _ = x.shape
        h, d_k = self.num_heads, self.d_k

        # 1. 线性映射
        Q = self.W_q(x)
        K = self.W_k(x)
        V = self.W_v(x)

        # 2. 变形：把 d_model 拆成 (h, d_k) 并换轴，让"头"提到 batch 前面
        #    (batch, seq_len, d_model) -> (batch, h, seq_len, d_k)
        Q = Q.view(batch, seq_len, h, d_k).transpose(1, 2)
        K = K.view(batch, seq_len, h, d_k).transpose(1, 2)
        V = V.view(batch, seq_len, h, d_k).transpose(1, 2)

        # 3. 每个头独立算注意力
        scores = Q @ K.transpose(-2, -1) / (d_k ** 0.5)   # (batch, h, seq_len, seq_len)
        attn = torch.softmax(scores, dim=-1)
        out = attn @ V                                     # (batch, h, seq_len, d_k)

        # 4. 拼回去：(batch, h, seq_len, d_k) -> (batch, seq_len, d_model)
        out = out.transpose(1, 2).contiguous().view(batch, seq_len, self.d_model)

        return self.W_o(out), attn

# 试跑
mha = MultiHeadAttention(d_model=512, num_heads=8)
x = torch.randn(2, 10, 512)          # 2 条句子，每条 10 个词，512 维
out, attn = mha(x)
print("输出 shape:", out.shape)       # torch.Size([2, 10, 512])
print("注意力权重 shape:", attn.shape) # torch.Size([2, 8, 10, 10]) —— 8 个头各一套权重
```

> ⚠️ **坑 1**：`transpose(1,2)` 之后内存不再连续，**必须先 `.contiguous()` 再 `.view()`**，否则报 `view size is not compatible`。这是上一篇就强调过的高频错误。

**多头的好处**：8 个头可以分别学会关注不同的语言学现象（指代、句法、位置邻近……）。实测中，去掉多头、只用一个大头，效果会明显下降。

## 四、位置编码：Attention 看不见顺序

这里有个反直觉的事实：**Self-Attention 本身是"位置无关"的**。

把句子里的词打乱顺序，Attention 的输出只是跟着换了个位置，内容完全一样——因为它只算词与词之间的相似度，压根不知道谁在前谁在后。但语言显然是有顺序的（"狗咬人" ≠ "人咬狗"）。

所以必须**手动把位置信息塞进去**，这就是**位置编码（Positional Encoding）**。

原始 Transformer 用的是正弦余弦编码：

```
PE(pos, 2i)   = sin(pos / 10000^(2i/d_model))
PE(pos, 2i+1) = cos(pos / 10000^(2i/d_model))
```

直观理解：**不同位置得到一组独一无二的"指纹"向量**，且相对位置关系可以被线性表示（位置 pos+k 的编码能由 pos 的编码线性变换得到）。

```python
import math

def positional_encoding(seq_len, d_model):
    pe = torch.zeros(seq_len, d_model)
    pos = torch.arange(0, seq_len).unsqueeze(1).float()        # (seq_len, 1)
    div = torch.exp(torch.arange(0, d_model, 2).float() * (-math.log(10000.0) / d_model))
    pe[:, 0::2] = torch.sin(pos * div)      # 偶数维度用 sin
    pe[:, 1::2] = torch.cos(pos * div)      # 奇数维度用 cos
    return pe

pe = positional_encoding(10, 16)
print(pe.shape)                              # torch.Size([10, 16])
print("位置0 与 位置1 的编码余弦相似度:",
      F.cosine_similarity(pe[0], pe[1], dim=0).item().round(3))
```

使用时直接**加到词向量上**：

```python
x = word_embedding + positional_encoding(seq_len, d_model)
```

> 后来的模型（BERT、GPT）更多用**可学习的位置嵌入**（`nn.Embedding(max_len, d_model)`），效果相近但更灵活。

## 五、三种注意力变体对比

| 类型 | Q 来源 | K/V 来源 | 用在哪 | 特点 |
| ---- | ------ | -------- | ------ | ---- |
| **Self-Attention** | 当前序列 | 当前序列 | Transformer 编码器 | 序列内部互相看 |
| **Masked Self-Attention** | 当前序列 | 当前序列（**遮住未来**） | GPT 解码器 | 保证预测第 i 个词时看不到 i 之后的词 |
| **Cross-Attention** | 解码器 | 编码器 | 机器翻译 decoder | 两种序列之间对齐 |

GPT 只能用第二种——因为它是"从左到右生成"的，如果生成第 3 个词时能偷看到第 5 个词，就等于作弊。实现方式是在 softmax 之前把未来位置**置为 -∞**：

```python
# mask：下三角为 0，上三角为 -inf
mask = torch.triu(torch.ones(seq_len, seq_len), diagonal=1).bool()
scores = scores.masked_fill(mask, float('-inf'))
attn = torch.softmax(scores, dim=-1)     # 未来位置的权重变成 0
```

## 六、Transformer 整体结构速览

```
输入句子
   ↓
词嵌入 Embedding + 位置编码
   ↓
┌─────── Encoder × N 层 ───────┐
│  多头自注意力                 │
│    ↓ 残差 + LayerNorm        │
│  前馈网络 FFN（两层 MLP）     │
│    ↓ 残差 + LayerNorm        │
└─────────────────────────────┘
   ↓
（Encoder-Decoder 模型还有 Cross-Attention 层）
   ↓
输出
```

两个重要设计：

- **残差连接（Residual）**：`output = LayerNorm(x + Attention(x))`。让梯度能直接回传，是训练超深网络的关键。
- **LayerNorm**：对每个样本自身做归一化，稳定训练。注意它和 BatchNorm 的区别——LayerNorm 在**特征维度**上归一，更适合变长序列。

| 对比项 | BatchNorm | LayerNorm |
| ------ | --------- | --------- |
| 归一化方向 | 跨样本、同一特征 | 同一样本、跨特征 |
| 依赖 batch size | 是（小 batch 效果差） | 否 |
| 序列任务表现 | 差（长度不一） | 好 |

## 七、常见坑清单

| 坑 | 现象 | 解决 |
| -- | ---- | ---- |
| `transpose` 后直接 `view` | RuntimeError 形状不兼容 | 先 `.contiguous()` |
| 忘记 mask 未来信息 | 生成模型作弊、指标虚高 | 解码器加 causal mask |
| 打分忘除 `√d_k` | 训练初期 loss 不动、梯度消失 | 必须缩放 |
| 维度对不上 | `mat1 and mat2 shapes cannot be multiplied` | 打印每一步 shape，检查 `transpose(-2,-1)` |
| 位置编码加错位置 | 模型学不到顺序 | 应在**进入第一层之前**加到 embedding 上 |

## 八、本节小结

1. **注意力 = 按相关性加权平均**，解决了 RNN 长距离遗忘的问题，而且可以完全并行计算。
2. **Q/K/V 三角色**：Q 是"我要找什么"，K 是"我能被怎么检索"，V 是"被选中后取走的内容"。
3. **公式四步**：打分 → 缩放（除以 √d_k）→ softmax → 加权求和；缩放是为了防止 softmax 饱和。
4. **多头注意力**让模型同时关注多种关系，输出拼接后过线性层。
5. **Attention 本身不感知顺序**，必须靠位置编码补充；正弦编码和 learned embedding 都可以。
6. **GPT 用 masked self-attention** 遮住未来词，BERT 用普通 self-attention 双向看全文——这是两者最本质的架构差异。

下一篇我们进入大模型应用：搞清楚 Prompt 该怎么写、Function Calling 是怎么让模型"调工具"的、以及上下文长度和成本该怎么控制。

---

> 一句话记住：**Attention 让每个词都能直接看到整个句子，位置编码告诉它顺序，多头让它同时看多个角度——这三件事加起来，就是 Transformer 的全部精髓。**
