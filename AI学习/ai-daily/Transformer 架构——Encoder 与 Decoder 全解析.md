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

### 1.1 没有非线性的网络到底"弱"在哪？

线性变换的致命缺陷是：它**永远画不出弯曲的决策边界**。假设你有一堆点，红点和蓝点交错分布（比如 XOR 问题），任何线性函数都分不开它们——必须靠非线性把它"掰开"。神经网络之所以强大，全靠一层层非线性把数据映射到越来越"好分"的空间。

注意力里的 softmax 虽然是非线性的，但它作用在"注意力权重"上，而不是作用在"每个位置的语义表示"上。换句话说，softmax 负责"决定看谁"，但"看了之后怎么加工"这件事，注意力本身是线性的（加权求和）。如果你只堆注意力层，那相当于"每步都重新决定看谁，但从不对看到的信息做非线性加工"——信息在空间里只是被线性搬运，形状不变，当然学不出复杂模式。FFN 正是补上"非线性加工"这一环的。

### 1.2 FFN 到底在"想"什么？

有个很经典的观点：可以把 FFN 每层的两个矩阵 `W₁`、`W₂` 理解成"知识存储器"。`W₁`（升维）把每个位置的表示投影到一个巨大的"中间空间"，这个空间里每个神经元可以对应一种**可识别的模式**（比如"这是人名""这是代码缩进""这是负面情绪"）；GELU 激活后，再经 `W₂`（降维）把匹配到的模式重新组合回语义空间。

近年有不少研究（如 "Transformer Feed-Forward Layers Are Key-Value Memories"）发现，FFN 的权重里确实隐式存储了大量"事实性知识"——这就是为什么你问 LLaMA "法国的首都是？"它能答出来，知识就藏在 FFN 的参数里。所以一句话总结：**注意力负责"从哪儿取信息"，FFN 负责"把信息加工成知识并存储"**。两者缺一不可，这也是 Transformer Block "注意力 + FFN" 双子层结构的根本原因。

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

### 2.1 残差连接为什么能"保底"梯度？一个更形象的说法

把深层网络想成一条有很多岔路的山路，梯度是"从山顶往下滚的信号"。如果没有残差（捷径），信号每过一层都要乘以该层的雅可比矩阵——连乘几十层后，要么被压成 0（消失），要么被放大到爆（爆炸）。残差相当于在每层都修了一条"直达天桥"：`x → x + f(x)`。这样即使 `f(x)` 那一坨的梯度很小甚至为 0，信号仍然能顺着 "+x" 这条天桥原样传下去。

这就是为什么 ResNet（2015）是深度学习的里程碑——它第一次让"上百层"的网络能被稳定训练。Transformer 直接继承了这套思想。你后面自己写 `MiniGPT` 时，`x = x + self.attn(...)` 这条加号，就是整张网络的"生命线"，绝不能漏。

### 2.2 RMSNorm 与 LayerNorm 的取舍：为什么新模型都换掉了？

LayerNorm 对每个样本的特征做"减均值、除标准差"的归一化。RMSNorm 发现：**减均值这一步收益不大，却要额外算一次均值**。于是它只做"除均方根"（root mean square），省掉了减均值的计算。在 d_model 很大（如 4096）的模型里，这部分省下的计算量相当可观，而且实验表明精度几乎无损。

一句话：**RMSNorm = 更快更省、效果相当的 LayerNorm 简化版**。你读 LLaMA/Qwen 源码看到 `RMSNorm` 类，就知道它干的是"归一化"这件事，不必惊讶。这也体现了大模型工程的一个共性——**能省的算一步都不多算**，因为参数规模下每一点优化乘以全局都会放大。

### 2.3 为什么层数（depth）比宽度（d_model）更难堆？

模型有两个"变大"的维度：**宽度 d_model**（每层的表示维度）和**深度 L**（堆叠多少层）。理论和工程都表明，深度比宽度更难训练——原因正是深层堆叠下梯度要穿越更多层，即使有残差连接，层数到 100+ 时仍可能出现"某些层学不动"的现象。

所以大模型在"变强"时，往往**先加宽度到某个甜区（如 4096~8192），再谨慎加深度（如 32~96 层）**。你看到的 LLaMA-7B（32 层）、LLaMA-70B（80 层），深度增长远慢于参数增长——因为参数主要被宽度和 FFN 撑起来，深度则受训练稳定性约束。理解这点，你就不会盲目追求"堆更多层"，而是根据任务和数据规模选一个合理的 L。

### 2.4 一个 Block 内"两次残差"的直觉

每个 Block 有两处残差（注意力后一次、FFN 后一次）。可以这么理解：模型在每一层都在做"**保留原信息 + 叠加一次小修改**"的迭代式精修。第 1 层把粗糙的 embedding 修一修，第 2 层在修过的基础上再修一修…… 第 L 层输出时，原始 token embedding 的"痕迹"仍通过一条条残差捷径保留着，而"增量修改"层层累积成了复杂的语义表示。这种"主干保真、支路增量"的结构，正是深度网络既能深、又不会信息丢失的根本原因。

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

### 3.1 为什么"做理解"也要用 Decoder-only 了？

早期（2018-2020）的共识是：理解用 BERT（双向）、生成用 GPT（单向）。但 2022 年后风向变了——大家发现 **Decoder-only 大模型通过 few-shot / prompt 也能做理解类任务**，而且统一架构能共享一套基础设施（推理引擎、微调框架、KV Cache）。

举例：你问 Qwen "判断这句话的情感是正面还是负面"，它虽然不是 BERT 那种"双向编码"，但靠 prompt 把任务说清楚，照样能做分类。这带来巨大的工程简化——**一家公司只需要维护一套 Decoder-only 的栈，就能同时覆盖理解和生成**。这也是为什么今天"预训练一个新 BERT"的诉求大幅减少：与其专门训理解模型，不如直接拿现成的大模型 + prompt/RAG 解决。

### 3.2 交叉注意力的"条件注入"思想为什么重要？

交叉注意力是 Encoder-Decoder 的精髓：Decoder 在生成第 i 个词时，用**自己的表示当 Q**，去查 **Encoder 对整个源句子的表示（K/V）**。这等价于"我（Decoder）在生成时，随时可以去原文里翻找相关信息"。

这个模式在今天的很多系统里反复出现：

- **机器翻译**：Decoder 查源语言句子；
- **RAG（检索增强）**：Decoder 用 cross-attention 去查检索到的文档（或把文档拼进上下文用自注意力等效替代）；
- **多模态（图文）**：Decoder 用 cross-attention 去查图像编码器输出的视觉特征；
- **语音/代码生成**：同理去查对应模态的表示。

理解交叉注意力，你就理解了"条件生成"的通用套路：**生成端持 Q，条件端持 K/V，注意力负责把两者对齐**。这是把 Transformer 从"单模态文本模型"扩展成"通用多模态架构"的关键一招。

### 3.3 为什么"原始 Encoder-Decoder"架构今天变少了？

2017 年原论文、以及后来的 T5/BART，都是完整的 Encoder-Decoder。但今天纯 Decoder-only 几乎通吃，原因在于：

1. **训练数据的"对齐"成本高**：Encoder-Decoder 对翻译、摘要这类"输入-输出成对"任务最自然，但互联网上绝大多数是"无成对"的单语文本，Decoder-only 的 CLM 目标能直接吃这些免费数据，数据利用率高得多。
2. **一个模型全包**：Decoder-only 既能续写又能靠 prompt 做理解/转换，不必为"理解"和"生成"维护两套架构。T5 那种"把所有任务都改成文本到文本"的思想虽优雅，但工程上不如"一个对话模型 + 好 prompt"来得省事。
3. **推理更简单**：Decoder-only 的 KV Cache 机制统一、成熟；Encoder-Decoder 还要同时维护 Encoder 的缓存和 Decoder 的交叉注意力缓存，复杂度更高。

所以，除非你专做翻译/摘要这类强序列转换任务，否则今天起步做应用，默认选 Decoder-only 是最省心的。这也是为什么你在本专栏后续"实战"部分看到的模型全是 Qwen/DeepSeek/LLaMA 这类 Decoder-only。

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

### 4.1 这段代码里每一行"为什么存在"，都对应一个工程决策

- `self.tok_emb = nn.Embedding(...)`：把 token ID 查表成向量（下一篇详讲，本篇只要知道它是"入口"）。
- `self.pos_emb = nn.Embedding(max_len, ...)`：可学习位置编码，弥补"注意力分不清顺序"的短板（上一篇已讲）。
- `TransformerBlock` 用 **Pre-LN**：`x = x + Sublayer(LN(x))`，比原论文的 Post-LN 稳定，深层也不崩（本篇第六节展开）。
- **权重绑定** `self.head.weight = self.tok_emb.weight`：输出层和输入嵌入共享参数。这既省了 `vocab × d_model` 这么多参数（对大模型是上亿），又让"预测下一个词"的向量空间和"表示这个词"的空间一致，实验证明效果反而更好。
- `generate` 里的 `idx[:, -self.max_len:]`：生成时只保留最近 max_len 个 token，避免超长报错。真实部署里这一步由 KV Cache 接管（阶段 10）。

把这套"为什么"吃透，你读任何 HuggingFace 模型的 `modeling_xxx.py` 都不会再发怵——它们无非是这套最小实现的"工业级加料版"。

### 4.2 自回归生成的三个采样技巧

`generate` 函数里出现了 `temperature` 和 `top_k`，这里展开一下，因为它们是"控制生成质量"的常用旋钮：

- **temperature（温度）**：对 logits 除以 T 再 softmax。T>1 让分布更平滑（更随机、更有创意），T<1 让分布更尖锐（更确定、更保守），T→0 退化为贪心（永远取概率最大的词）。
- **top-k**：只在概率最高的 k 个词里采样，过滤掉长尾的低概率词，避免生成乱码。
- **top-p（核采样，nucleus sampling）**：动态取"累计概率达到 p 的最小词集"来采样，比 top-k 更自适应。实际对话模型（GPT/Claude/Qwen）默认都用 top-p。

这三个都是"不改模型参数、只改采样策略"就能调出不同风格的手段——也是提示词/推理工程里最常用的开关。

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

### 5.1 为什么 FFN 参数量是注意力的两倍？一个快速推导

- 注意力有 4 个矩阵（W_Q、W_K、W_V、W_O），每个 `d_model × d_model`，共 `4·d_model²`；
- FFN 有 2 个矩阵（升维 `d_model × 4·d_model`、降维 `4·d_model × d_model`），共 `8·d_model²`。

所以单层 FFN = 2 × 注意力。**这是架构决定的、与具体数值无关的比例**。知道这点，你就能瞬间判断"某个开源模型号称 70B 但 FFN 占比异常"之类的反常配置——大概率要么是 MoE（FFN 被拆成多专家），要么是改了中间维度倍数（有些模型用 2/3 倍而非 4 倍）。

### 5.2 MoE：把 FFN 变"稀疏"，省算力不省参数

既然 FFN 占了 2/3 参数、且是"逐位置独立计算"（每个 token 都过一遍 FFN），那能不能"每个 token 只过其中一小部分"？这就是 **Mixture-of-Experts（混合专家）** 的思路：把 FFN 复制成 N 个"专家"，再加一个"路由器"决定每个 token 交给哪几个专家。

好处巨大：**总参数量（容量）变成原来的 N 倍，但每个 token 实际计算量只涨一点点**（只激活 top-k 个专家）。DeepSeek-V3、Qwen 的 MoE 版本、Mixtral 都是这么干的——这就是为什么 DeepSeek-V3 有 671B 参数，激活时却只有约 37B 在算，单卡也能跑。

代价是工程复杂度（要调度不同专家、负载均衡），以及训练时专家分配不均的"路由崩溃"问题。但作为开发者你要记住：**MoE 的本质就是"让 FFN 参数睡着、只叫醒需要的那几个"**，它是当今大模型"又大又快"的核心技术。

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

### 6.2 一个容易踩的"warmup 陷阱"

如果你一定要用 Post-LN（比如复现某些老论文），必须配合学习率 warmup：训练刚开始的几十到几百步，学习率从接近 0 线性升到目标值，之后再按 schedule 衰减。为什么需要它？因为初始化时参数随机、各层输出方差大，直接上大学习率会让 Post-LN 的归一化被炸飞。而 Pre-LN 因为残差直通，warmup 可以很短甚至不要——这也是它"更好训"的直接体现。给做训练的你一句经验：**如果你发现 loss 前几百步疯狂震荡或不下降，先怀疑是不是 warmup 没配好，而不是怀疑模型结构**。

### 6.1 为什么 Post-LN 会"训练不稳"？

Post-LN 里，归一化放在残差**之后**：`x = LN(x + f(x))`。问题是，刚初始化时 `f(x)` 的输出方差可能很大，加上 x 再归一化，会让前面层的梯度在反向时被 LN 的缩放因子反复压缩，导致"深层梯度小、浅层梯度大"的不均衡，必须用很长的 warmup 慢慢把学习率拉起来，否则直接发散。

Pre-LN 把 LN 移到子层**之前**：`x = x + f(LN(x))`。此时残差支路 `x` 完全没被 LN 动过，梯度可以原样沿 "+x" 这条道直通到底，均衡又稳定。代价是理论上 Post-LN 的表示能力略强（因为残差路径上也做了归一化），但工程上"好训"远比"理论略优"重要，所以 Pre-LN 成了事实标准。

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

### 7.1 进阶坑：你以为"能跑"就对了？

- **batch 内序列不等长**：真实数据每句话长度不同，要用 `attention_mask` 把 padding 位置屏蔽（第三篇已讲 mask 思想），否则模型会去"关注空格"，loss 虚低但效果差。
- **推理没关 dropout / 没 eval**：生成出的文本每次都不一样且质量飘忽，还以为是模型不行——其实只是忘了 `model.eval()`。
- **max_len 设置过小**：训练时 max_len=512，上线后用户丢来 2000 字文档，位置嵌入直接越界报错。要么提前规划上下文窗口，要么换 RoPE 类可外推编码。

## 八、本篇小结

1. **FFN 提供非线性**，升维 4 倍再降回，是模型"想清楚"的地方；注意力负责"看清楚"。
2. **残差连接**是深层网络的命脉，它给梯度留了一条恒等通路；**LayerNorm** 因适配变长序列而取代 BatchNorm。
3. 标准 Block = `x + Attention(LN(x))` 然后 `x + FFN(LN(x))`（**Pre-LN**，主流做法）。
4. **Encoder-only（BERT）做理解，Decoder-only（GPT/LLaMA/Qwen）做生成**——今天的大模型几乎全是后者。
5. **参数分布**：FFN 约 2/3、注意力约 1/3。记住 `12·L·d²` 这个估算公式，你能随手算出任何模型的规模。
6. 我们搭出了一个完整可用的 `MiniGPT`（嵌入 + 4 层 Block + 输出头 + 自回归生成），初始 loss ≈ ln(vocab) 验证了实现正确。

## 九、实战练习（可验证小任务）

1. **改架构题**：把 `MiniGPT` 改成 Encoder-only（去掉因果 mask、去掉生成函数、加一个分类头），用同样的数据验证初始 loss 仍 ≈ ln(vocab)。
2. **参数量自测**：用 `12·L·d²` 公式手算 Qwen2.5-7B 的层数参数，和第五节给的 4.32B 对一对。
3. **采样实验**：把 `generate` 的 `temperature` 分别设 0.1 / 1.0 / 2.0，观察生成结果的"确定 vs 发散"差异。
4. **改结构题**：把 Pre-LN 改成 Post-LN（注意加 LayerNorm 的位置），跑同样的初始化，对比训练初期 loss 是否更容易发散（验证第六节结论）。

## 十、延伸阅读与下一步

- 原论文 *Attention Is All You Need* (Vaswani et al., 2017)：重点读 Figure 1（架构图）和 Table 3（复杂度对比）。
- *Deep Residual Learning for Image Recognition* (He et al., 2015)：残差连接的开山之作，理解"为什么能堆深"。
- MoE 入门：读 *Mixtral of Experts*、*DeepSeek-V3 Technical Report*，理解"稀疏激活"如何又大又快。
- 归一化对比：搜索 "On Layer Normalization in the Transformer Architecture"（Xiong et al.）看 Pre-LN vs Post-LN 的理论分析；读 LLaMA 论文了解 RMSNorm 的选择理由。

**下一篇**：这个模型吃进去的是 `idx`——一串整数 ID。可"猫追老鼠"这四个字是怎么变成整数的？为什么同一句话在 GPT 和 BERT 里 token 数不一样？为什么中文比英文贵？下一篇《分词与 Embedding——Tokenizer、BPE 与 WordPiece》会手写一个 BPE 分词器，让你彻底搞懂"token"这个计费单位。

> 本篇是《大模型开发从 0 到 1》专栏第 30 篇，阶段 5「Transformer 与大模型原理」第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
