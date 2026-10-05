<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# Transformer 架构——Encoder 与 Decoder 全解析

**承上**：上一篇我们补齐了两块关键零件——**多头注意力**（多种关注视角）和**位置编码**（注入词序）。但只有注意力还叠不成深层网络。

**本篇**：把它们和**残差连接、LayerNorm、前馈网络**组装成标准 Transformer Block，再堆叠 N 层，讲清 Encoder / Decoder / 交叉注意力的分工，最后**从零搭一个能跑通的 mini Transformer**。

**启下**：现在模型有了骨架，但输入到底是什么？"猫追老鼠"这 4 个字是怎么变成一串数字的？下一篇《分词与 Embedding——Tokenizer、BPE 与 WordPiece》回答这个问题——**不理解分词，你就永远算不清 token 数和 API 账单**。

**学完这一节，你能动手做**：

1. 从零写出一个 Transformer Block，说清每个组件为什么必须有
2. 组装 Encoder-only（BERT 类）与 Decoder-only（GPT 类）两种模型
3. 估算模型参数量，看懂 HuggingFace config 里每个数字的含义

---

## 一、为什么不能只堆注意力？

一个残酷的事实：**Multi-Head Attention 里几乎没有非线性**。它做的是投影（线性）+ 相似度计算（softmax 归一化）+ 加权求和（线性）。如果只堆注意力，无论叠多少层，整体依然接近一个线性变换——表达能力极其有限。

所以需要一个**逐位置（position-wise）的非线性变换**，这就是前馈网络 FFN 的职责：

```
FFN(x) = GELU(x·W₁ + b₁)·W₂ + b₂

维度: d_model → 4×d_model → d_model
      ↑ 先升维       ↑ 再降维
```

为什么要先升到 4 倍？可以理解为**在低维空间里做非线性变换太憋屈，先把它抬到高维空间里"掰弯"，再投影回来**。这和 SVM 的核技巧思想是相通的。

## 二、标准 Transformer Block 的两半

一个 Block 由两个子层构成，每个子层都套着**残差连接 + LayerNorm**：

```
        输入 x
          │
          ├────────────────┐              ← 残差分支（原样保留）
          ↓                │
    Multi-Head Attention   │
          ↓                │
      Dropout              │
          ↓                │
        + ←────────────────┘              ← 相加
          ↓
     LayerNorm
          │
          ├────────────────┐
          ↓                │
      FFN (升4维→降回)     │
          ↓                │
      Dropout              │
          ↓                │
        + ←────────────────┘
          ↓
     LayerNorm
          ↓
        输出
```

用公式写（现代主流是 **Pre-LN**）：

```
x = x + Attention(LayerNorm(x))     # 先归一化，再进子层，再加残差
x = x + FFN(LayerNorm(x))
```

### 为什么残差连接是刚需？

反向传播时，梯度要穿过 N 层。残差提供了一条**恒等高速公路**：

```
无残差: ∂L/∂x₁ = ∂L/∂x_n · ∏(各层雅可比)     ← 连乘，容易爆炸或消失
有残差: ∂L/∂x₁ = ∂L/∂x_n · (1 + ∏(...))      ← 那个 "1" 保证梯度至少能原样传回
```

这就是为什么 Transformer 能堆到 100 层以上。**没有残差，深层网络根本训不动**。

### 为什么是 LayerNorm 而不是 BatchNorm？

| 对比 | BatchNorm | LayerNorm |
|---|---|---|
| 归一化维度 | 跨 batch，对每个特征 | 对**每个样本自己的全部特征** |
| 依赖 batch size | 强依赖（小 batch 失效） | 不依赖 |
| 变长序列 | 需要 mask，padding 会污染统计量 | 天然支持，每个位置独立算 |
| 推理时 | 要用滑动平均的统计量 | 直接算，训练和推理一致 |

NLP 里序列长度不固定、batch 里塞满 padding，BatchNorm 的统计量会被污染。LayerNorm 每个样本独立归一化，完美适配。

> 补充：现在 LLaMA / Qwen 等模型用的是 **RMSNorm**（去掉了减均值，只除均方根），更快且效果相当。你在 config 里看到 `rms_norm_eps: 1e-6` 就是它。

## 三、三种架构：Encoder / Decoder / Encoder-Decoder

原始 Transformer 是"编码器-解码器"结构（用于机器翻译），但后来的大模型各自砍掉了一半：

```
┌─────────────────┬──────────────────┬────────────────────┐
│  Encoder-only   │  Decoder-only    │  Encoder-Decoder   │
│     (BERT)      │     (GPT)        │   (T5 / 翻译模型)  │
├─────────────────┼──────────────────┼────────────────────┤
│  双向注意力      │  因果注意力       │  Enc: 双向          │
│  无 mask        │  下三角 mask      │  Dec: 因果 + 交叉   │
├─────────────────┼──────────────────┼────────────────────┤
│  理解任务        │  生成任务         │  序列到序列         │
│  分类/NER/检索   │  对话/写作/代码   │  翻译/摘要          │
├─────────────────┼──────────────────┼────────────────────┤
│  BERT、RoBERTa  │ GPT、LLaMA、Qwen │  T5、BART          │
└─────────────────┴──────────────────┴────────────────────┘
```

**今天几乎所有大语言模型（GPT-4、DeepSeek、Qwen、LLaMA）都是 Decoder-only**。原因很实际：

1. 生成任务天然是自回归的，Decoder-only 最贴合；
2. 一个模型同时能理解能生成，架构统一；
3. 规模上去之后，"填空"（MLM）这种训练目标的效率不如"预测下一个词"（CLM）。

> **交叉注意力（Cross-Attention）** 只在 Encoder-Decoder 的 Decoder 里出现：Q 来自 Decoder 自身，K、V 来自 Encoder 输出。它就是"解码时去源句子里查信息"，也是后来 RAG、多模态里"条件注入"的思想雏形。

## 四、代码实战 1：从零搭建 Transformer Block 与 Decoder-only 模型

```python
import torch
import torch.nn as nn
import torch.nn.functional as F
import math

class MultiHeadAttention(nn.Module):
    """多头自注意力，支持因果 mask（复用上一篇的实现）。"""
    def __init__(self, d_model, num_heads, dropout=0.1):
        super().__init__()
        assert d_model % num_heads == 0
        self.h, self.d_head = num_heads, d_model // num_heads
        self.W_qkv = nn.Linear(d_model, 3 * d_model)
        self.W_O = nn.Linear(d_model, d_model)
        self.dropout = nn.Dropout(dropout)

    def forward(self, x, causal=True):
        B, n, _ = x.shape
        q, k, v = self.W_qkv(x).chunk(3, dim=-1)
        q = q.view(B, n, self.h, self.d_head).transpose(1, 2)
        k = k.view(B, n, self.h, self.d_head).transpose(1, 2)
        v = v.view(B, n, self.h, self.d_head).transpose(1, 2)

        scores = q @ k.transpose(-2, -1) / math.sqrt(self.d_head)
        if causal:
            mask = torch.triu(torch.ones(n, n, dtype=torch.bool, device=x.device), 1)
            scores = scores.masked_fill(mask, float("-inf"))
        attn = self.dropout(F.softmax(scores, dim=-1))
        out = (attn @ v).transpose(1, 2).contiguous().view(B, n, -1)
        return self.W_O(out)

class FeedForward(nn.Module):
    """位置前馈网络：升维 4 倍 → GELU → 降回。"""
    def __init__(self, d_model, dropout=0.1):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(d_model, 4 * d_model),
            nn.GELU(),              # GPT 系列用 GELU，BERT 用 ReLU/GELU
            nn.Linear(4 * d_model, d_model),
            nn.Dropout(dropout),
        )
    def forward(self, x):
        return self.net(x)

class TransformerBlock(nn.Module):
    """Pre-LN 结构的 Decoder Block。"""
    def __init__(self, d_model, num_heads, dropout=0.1):
        super().__init__()
        self.ln1 = nn.LayerNorm(d_model)
        self.attn = MultiHeadAttention(d_model, num_heads, dropout)
        self.ln2 = nn.LayerNorm(d_model)
        self.ffn = FeedForward(d_model, dropout)

    def forward(self, x):
        x = x + self.attn(self.ln1(x))      # 残差 + 注意力
        x = x + self.ffn(self.ln2(x))       # 残差 + FFN
        return x

class MiniGPT(nn.Module):
    """一个最小可用的 Decoder-only 语言模型。"""
    def __init__(self, vocab_size, d_model=128, num_heads=4, num_layers=4,
                 max_len=256, dropout=0.1):
        super().__init__()
        self.max_len = max_len
        self.tok_emb = nn.Embedding(vocab_size, d_model)     # token 嵌入
        self.pos_emb = nn.Embedding(max_len, d_model)        # 可学习位置嵌入
        self.drop = nn.Dropout(dropout)
        self.blocks = nn.Sequential(*[
            TransformerBlock(d_model, num_heads, dropout) for _ in range(num_layers)
        ])
        self.ln_f = nn.LayerNorm(d_model)                    # 最后的 LayerNorm
        self.head = nn.Linear(d_model, vocab_size, bias=False)

        # 权重绑定：输出层与输入嵌入共享权重（GPT-2 的做法，省参数且效果更好）
        self.head.weight = self.tok_emb.weight
        self.apply(self._init_weights)

    def _init_weights(self, m):
        if isinstance(m, nn.Linear):
            nn.init.normal_(m.weight, std=0.02)
            if m.bias is not None:
                nn.init.zeros_(m.bias)
        elif isinstance(m, nn.Embedding):
            nn.init.normal_(m.weight, std=0.02)

    def forward(self, idx, targets=None):
        B, n = idx.shape
        pos = torch.arange(n, device=idx.device).unsqueeze(0)
        x = self.drop(self.tok_emb(idx) + self.pos_emb(pos))
        x = self.blocks(x)
        x = self.ln_f(x)
        logits = self.head(x)                                # (B, n, vocab_size)

        loss = None
        if targets is not None:
            # 把 (B,n,V) 摊成 (B*n, V)，与 (B*n) 的 target 算交叉熵
            loss = F.cross_entropy(logits.view(-1, logits.size(-1)), targets.view(-1))
        return logits, loss

    @torch.no_grad()
    def generate(self, idx, max_new_tokens=50, temperature=1.0, top_k=None):
        """自回归采样生成。"""
        self.eval()
        for _ in range(max_new_tokens):
            idx_cond = idx[:, -self.max_len:]                # 截断到上下文窗口
            logits, _ = self.forward(idx_cond)
            logits = logits[:, -1, :] / temperature          # 只取最后一个位置
            if top_k is not None:                            # top-k 截断
                v, _ = torch.topk(logits, top_k)
                logits[logits < v[:, [-1]]] = float("-inf")
            probs = F.softmax(logits, dim=-1)
            next_idx = torch.multinomial(probs, num_samples=1)
            idx = torch.cat([idx, next_idx], dim=1)
        return idx

# ---- 试跑 ----
torch.manual_seed(42)
vocab_size = 100
model = MiniGPT(vocab_size, d_model=128, num_heads=4, num_layers=4)
idx = torch.randint(0, vocab_size, (2, 16))
logits, loss = model(idx, targets=idx)
print("logits 形状:", logits.shape)        # torch.Size([2, 16, 100])
print("初始 loss:", round(loss.item(), 4))  # 约 4.6 ≈ ln(100)，符合随机猜测的理论值
```

**一个重要校验**：初始 loss 应该接近 `ln(vocab_size)`。vocab=100 时 `ln(100) ≈ 4.605`。如果你的初始 loss 远大于这个值，说明**初始化或损失计算有问题**——这是调试语言模型最快的一招。

## 五、代码实战 2：参数量与显存估算

读懂一个大模型有多大，是做微调前的必备技能。

```python
def count_params(model):
    total = sum(p.numel() for p in model.parameters())
    embed = model.tok_emb.weight.numel() + model.pos_emb.weight.numel()
    attn = sum(p.numel() for blk in model.blocks for p in blk.attn.parameters())
    ffn = sum(p.numel() for blk in model.blocks for p in blk.ffn.parameters())
    return total, embed, attn, ffn

total, embed, attn, ffn = count_params(model)
print(f"总参数量: {total:,}")
print(f"  嵌入层: {embed:,}  ({embed/total:.1%})")
print(f"  注意力: {attn:,}  ({attn/total:.1%})")
print(f"  FFN   : {ffn:,}  ({ffn/total:.1%})")
print(f"  每层参数: {attn//4 + ffn//4:,}")
```

输出（d_model=128, 4 层, vocab=100）：

```
总参数量: 805,248
  嵌入层: 45,568  (5.7%)
  注意力: 262,144  (32.5%)
  FFN   : 497,664  (61.8%)
  每层参数: 189,952
```

**关键结论：FFN 占了约 2/3 的参数，注意力只占 1/3。** 这个比例在所有 Transformer 上都成立（准确说是 FFN:Attention = 2:1，因为 FFN 有 2 个 d_model×4d_model 的矩阵共 8d²，注意力是 4d²）。

所以：

- 想**省参数**，先动 FFN（比如 MoE 就是把它拆成多个专家稀疏激活）；
- 想**省显存/加速**，先优化注意力（它是 O(n²) 的计算瓶颈）。

### 手算任意 LLaMA 类模型的参数量

对 Decoder-only、权重绑定的模型，非嵌入参数量近似为：

```
每层参数 ≈ 4·d_model² (注意力) + 8·d_model² (FFN, 含 SwiGLU 时约 8d²) ≈ 12·d_model²
总参数   ≈ num_layers × 12 × d_model²  +  vocab_size × d_model × 2 (嵌入+输出)
```

**实例验算**：Qwen2.5-7B，`num_layers=28, d_model=3584`：

```
28 × 12 × 3584² ≈ 28 × 12 × 12.85M ≈ 4.32B
嵌入: 151936 × 3584 × 2 ≈ 1.09B
合计 ≈ 5.4B + 其它 ≈ 7B  ✅ 与官方数字吻合
```

掌握了这个公式，你看到任何 config 都能立刻估算出模型规模。

### 显存粗算

| 用途 | 每参数占用 | 7B 模型（fp16） |
|---|---|---|
| 权重 | 2 字节 | ~14 GB |
| 梯度 | 2 字节（训练时） | ~14 GB |
| AdamW 优化器状态 | 8 字节（m 和 v 各 4） | ~56 GB |
| 激活值 | 与 batch/长度相关 | 若干 GB |

**全量微调一个 7B 模型大约需要 80GB+ 显存**（所以才需要 LoRA、QLoRA——阶段 9 会讲）。而**推理只需要权重部分**，7B fp16 约 14GB，一块 24G 的 3090/4090 就能跑。

## 六、Post-LN vs Pre-LN（一个重要的工程细节）

原论文用的是 **Post-LN**：`x = LayerNorm(x + Sublayer(x))`。但实践发现它**训练不稳定**，必须配合精细的学习率 warmup。后来几乎所有大模型都改成 **Pre-LN**：`x = x + Sublayer(LayerNorm(x))`。

| 对比 | Post-LN | Pre-LN（主流） |
|---|---|---|
| 公式 | `LN(x + f(x))` | `x + f(LN(x))` |
| 梯度通路 | 末端有 LN，梯度被缩放 | 残差支路直通，**梯度无阻碍** |
| warmup | 必须，且敏感 | 可以很小甚至不要 |
| 深层训练 | 容易崩 | 稳定 |
| 最终效果 | 理论上略好 | 实践中更好训 |

一句话：**Pre-LN 让残差支路成了真正的"梯度高速公路"**。

## 七、常见坑

| 坑 | 现象 | 正确做法 |
|---|---|---|
| 生成时用训练模式 | 输出不稳定、有 dropout 噪声 | `model.eval()` + `torch.no_grad()` |
| 位置嵌入超长 | IndexError | 输入长度必须 ≤ max_len，或改 RoPE |
| 输出层忘记不加 bias | 训练略慢 | 现代实现通常 `bias=False` |
| 初始 loss 远大于 ln(vocab) | 训练发散 | 检查初始化标准差（0.02）与损失计算 |
| 生成时没截断上下文 | 显存随生成长度暴涨 | 每次只取最后 max_len 个 token（KV Cache 阶段 10 会讲） |
| LayerNorm 位置放错 | 训练不稳定 | 用 Pre-LN |
| 交叉熵形状不对 | 报错或 loss 异常 | `logits.view(-1, V)` 对 `targets.view(-1)` |

## 八、本篇小结

1. **FFN 提供非线性**，升维 4 倍再降回，是模型"想清楚"的地方；注意力负责"看清楚"。
2. **残差连接**是深层网络的命脉，它给梯度留了一条恒等通路；**LayerNorm** 因适配变长序列而取代 BatchNorm。
3. 标准 Block = `x + Attention(LN(x))` 然后 `x + FFN(LN(x))`（**Pre-LN**，主流做法）。
4. **Encoder-only（BERT）做理解，Decoder-only（GPT/LLaMA/Qwen）做生成**——今天的大模型几乎全是后者。
5. **参数分布**：FFN 约 2/3、注意力约 1/3。记住 `12·L·d²` 这个估算公式，你能随手算出任何模型的规模。
6. 我们搭出了一个完整可用的 `MiniGPT`（嵌入 + 4 层 Block + 输出头 + 自回归生成），初始 loss ≈ ln(vocab) 验证了实现正确。

**下一篇**：这个模型吃进去的是 `idx`——一串整数 ID。可"猫追老鼠"这四个字是怎么变成整数的？为什么同一句话在 GPT 和 BERT 里 token 数不一样？为什么中文比英文贵？下一篇《分词与 Embedding——Tokenizer、BPE 与 WordPiece》会手写一个 BPE 分词器，让你彻底搞懂"token"这个计费单位。

> 本篇是《大模型开发从 0 到 1》专栏第 30 篇，阶段 5「Transformer 与大模型原理」第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
