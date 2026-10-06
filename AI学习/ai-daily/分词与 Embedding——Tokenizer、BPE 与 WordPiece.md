<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 分词与 Embedding——Tokenizer、BPE 与 WordPiece

**承上**：上一篇我们搭出了 `MiniGPT`，它吃进去的是 `idx`——一串整数 ID。可"猫追老鼠"这四个字，到底是怎么变成 `[35946, 223, 88]` 这样的数字的？

**本篇**：讲清大模型的第一道门——**分词（Tokenization）**。我们会手写一个 BPE 分词器，看懂子词切分的原理，然后理解 Embedding 查表，最后搞明白**为什么中文比英文贵、token 数怎么算**。

**启下**：输入的问题解决了。下一步你会发现，同样是 Transformer，BERT 和 GPT 的**训练目标完全不同**——一个做填空、一个做续写。下一篇《从 BERT 到 GPT——预训练模型的演进》讲清三条架构路线的分野。

**学完这一节，你能动手做**：

1. 从零写出 BPE 训练与编码，说清合并规则是怎么"学"出来的
2. 理解 Embedding 本质就是查表，并验证它等价于 one-hot 矩阵乘法
3. 估算任意文本的 token 数与 API 成本，解释"为什么中文更贵"

---

## 一、为什么不能直接按字或按词切？

模型只能处理数字，所以必须先把文本切成离散单元。三种切法各有硬伤：

| 切法 | 例子 | 优点 | 致命问题 |
|---|---|---|---|
| **按字符** | 猫 / 追 / 老 / 鼠；a / b / c | 词表极小（汉字约 2 万） | 序列太长（注意力 O(n²) 爆炸）、单字语义稀薄 |
| **按单词** | "running" 一个整体 | 语义完整、序列短 | **词表爆炸** + **OOV**（遇到没见过的词直接罢工）+ 形态变化（run/runs/ran/running 各算一个） |
| **按子词**（主流） | "running" → "run" + "ning" | 平衡三者 | 切分结果不直观 |

**子词（subword）**的核心思想：**常见词保持完整，罕见词拆成更小的已知片段**。这样：

- 词表可控（通常 3 万 ~ 15 万）；
- 几乎没有 OOV（再生僻的词也能拆到字符级）；
- 形态相似的词共享片段（"run"/"running" 共享 "run"），泛化更好。

### 1.1 从"语言学"看三种粒度：信息密度 vs 序列长度

切词本质上是在"每个 token 携带的语义量"和"token 总数"之间做权衡，这俩是此消彼长的关系：

- **字级别**：每个 token 信息量小（一个汉字能表达的东西有限），所以要用很多 token 才能说完一句话 → 序列长 → 注意力 O(n²) 计算爆炸，且长程依赖更难学。
- **词级别**：每个 token 信息量大（"transformer" 一个词就是完整概念），序列短，但词表巨大、新词无法处理（OOV）、且英文一个词还有各种变形（run/runs/ran/running）要各占一个坑。
- **子词级别**：折中——高频概念用整词（如 "transformer"），低频概念拆成片段（如罕见术语拆成 "trans"+"former" 类子串），既控制词表又保住表达力。

这就是为什么**几乎所有现代大模型都选子词**：它是唯一能在"可控词表 / 无 OOV / 合理序列长度"三者间同时达标的解。

### 1.2 OOV 为什么是"致命"的？

OOV 是 "Out-Of-Vocabulary"（未登录词）的缩写。按词切分的世界里，模型只认识训练时见过的词；一旦遇到新词（比如新出的产品名、专业术语、网络新词），它只能塞进一个统一的 `[UNK]`（未知）token。问题是 `[UNK]` 对所有未知词都是同一个向量——模型根本分不清"`[UNK]` 是 iPhone 还是 `是` 病毒名"，语义彻底丢失。

子词方案从根本上消灭了 OOV：因为任何词都能拆到"字符级"保底（Byte-level BPE 甚至把 UTF-8 字节当基本单元），所以**不存在"拆不到"的词**。你给模型一个从没见过的生造词，它也能靠子词组合大致编码出来。这一点对中文、代码、化学式、以及日新月异的网络用语尤其关键。

## 二、三大子词算法

| 算法 | 核心思路 | 代表模型 |
|---|---|---|
| **BPE**（字节对编码） | 从字符开始，**反复合并出现频次最高的相邻对**，直到词表达到目标大小 | GPT 系列、RoBERTa、LLaMA、Qwen |
| **WordPiece** | 类似 BPE，但合并准则不是频次，而是**最大化语言模型似然**（优先合并"合并后能大幅提升概率"的对） | BERT、DistilBERT、Electra |
| **Unigram** | 反过来：先造一个大词表，**逐步删掉"删了损失最小"的子词** | T5、ALBERT、部分 SentencePiece 模型 |

现在最主流的是 **BPE**（尤其是它的字节级变种 **Byte-level BPE**——把 UTF-8 字节当作基本单元，彻底消灭 OOV，任何语言、任何 emoji 都能编码）。

### 2.1 为什么 Byte-level BPE 这么重要？

标准 BPE 从"字符"出发，但不同语言字符集不同（中文几万汉字、英文 26 字母），字符级基本单元不统一，跨语言模型很难做。Byte-level BPE 的巧思是：**不管什么语言，都先当成 UTF-8 字节序列**（最多 256 种字节值），再在字节上做 BPE 合并。

好处：

1. **统一基本单元**：中英文、emoji、代码全都在"字节"这层对齐，一个 tokenizer 通吃所有语言；
2. **彻底无 OOV**：256 个字节一定能覆盖任何输入，不会卡死；
3. **GPT-2 之后几乎成了标配**，你用的 Qwen/GPT 底层都是它。

代价是"一个汉字通常要 2~3 个字节 token"，这也是为什么**中文 token 数天然比英文多**（下一段详细展开）。

### 2.2 WordPiece 的"似然"准则到底好在哪？

BPE 贪心地合并"出现频次最高"的对，但这不一定是最优的——一个对出现频次高，可能只是因为它所在的词本来就多，未必代表它是"有意义的语义单元"。WordPiece 改用**语言模型似然增益**做合并准则：优先合并"合并后能让整个语料的语言模型概率提升最多"的对。直觉上，这倾向于合并出"真正有语义价值"的片段（比如把 "##ing" 这种后缀、或中文里的"模型""学习"这种高频搭配合并出来），而不是机械地按频率。

所以 BERT 用 WordPiece、GPT 用 BPE，并非随意：BERT 是"理解"任务，更在乎每个 token 的语义纯度；GPT 是"生成"任务，更在乎覆盖率与无 OOV。两者都是子词家族，只是合并策略侧重不同。

## 三、代码实战 1：手写 BPE 分词器

用经典的英文小语料演示，全过程不到 40 行，你能完整看到"合并规则是怎么被学出来的"。

```python
from collections import Counter

# ---------- 语料 ----------
corpus = ["low"] * 5 + ["lower"] * 2 + ["newest"] * 6 + ["widest"] * 3

# 1) 初始化：按字符切分，词尾加 </w> 标记（用于区分"词尾的 est"和"词中的 est"）
vocab = Counter()
for w in corpus:
    vocab[" ".join(list(w)) + " </w>"] += 1
print("初始词表:", dict(vocab))

# 2) 统计所有相邻字节对的频次
def get_stats(vocab):
    pairs = Counter()
    for word, freq in vocab.items():
        symbols = word.split()
        for i in range(len(symbols) - 1):
            pairs[(symbols[i], symbols[i + 1])] += freq
    return pairs

# 3) 把最 frequent 的一对合并成一个新符号
def merge_pair(pair, vocab_in):
    vocab_out = {}
    bigram, replacement = " ".join(pair), "".join(pair)
    for word, freq in vocab_in.items():
        vocab_out[word.replace(bigram, replacement)] = freq
    return vocab_out

# 4) 迭代合并
num_merges = 10
merges = []                     # 记录合并规则，编码时要按同样顺序回放
for i in range(num_merges):
    pairs = get_stats(vocab)
    if not pairs:
        break
    best = max(pairs, key=pairs.get)
    merges.append(best)
    vocab = merge_pair(best, vocab)
    print(f"第 {i+1:2d} 步  合并 {str(best):20s} 频次 {pairs[best]}")

print("\n最终词表:")
for w, f in vocab.items():
    print(f"  {w:16s} x{f}")
```

运行结果：

```
初始词表: {'n e w e s t </w>': 6, 'l o w </w>': 5, 'w i d e s t </w>': 3, 'l o w e r </w>': 2}

第  1 步  合并 ('e', 's')          频次 9
第  2 步  合并 ('es', 't')         频次 9
第  3 步  合并 ('est', '</w>')     频次 9
第  4 步  合并 ('l', 'o')          频次 7
第  5 步  合并 ('lo', 'w')         频次 7
第  6 步  合并 ('n', 'e')          频次 6
第  7 步  合并 ('ne', 'w')         频次 6
第  8 步  合并 ('new', 'est</w>')  频次 6
第  9 步  合并 ('low', '</w>')     频次 5
第 10 步  合并 ('w', 'i')          频次 3

最终词表:
  low</w>          x5
  low e r </w>     x2
  newest</w>       x6
  wi d est</w>     x3
```

**怎么读这个结果**：

1. 第 1-3 步，`e+s → es`、`es+t → est`、`est+</w> → est</w>` 连续合并——因为 "newest" 和 "widest" 里 `est` 出现了 9 次，频次最高。模型"发现"了常见后缀。
2. 第 4-5 步合并出 `low`（7 次），第 6-8 步合并出 `newest`。
3. 最终 `low` 和 `newest` 都成了**完整 token**（它们足够常见），而 `lower` 拆成 `low + e + r`、`widest` 拆成 `wi + d + est</w>`。

**这就是 BPE 的全部秘密**：高频组合优先合并，直到词表大小达标。词表越大，完整词越多，序列越短，但嵌入矩阵也越大——这是一个权衡。

### 3.1 为什么要在词尾加 `</w>`？

这是 BPE 里一个极容易被忽略但很关键的细节。如果不加词尾标记：

- "est"（词尾）和 "est"（词中，如 "west"（西）的 est）会被当成同一个符号；
- 模型无法区分"这是一个完整词"和"这是某个词的一部分"。

加上 `</w>` 后，`est</w>` 明确代表"出现在词尾的 est"，而普通的 `est` 仍可能来自词中。这让 BPE 能学到"词边界"信息，对后续语言模型理解"词的完整性"有帮助。实际工业实现里，字节级 BPE 通常用特殊的 `Ġ`（空格标记）或 `</w>` 来表达"词在这里开始/结束"。

### 3.2 编码新词

训练完得到的是一张**合并规则表**，编码时按规则顺序贪心回放即可：

```python
def encode(word, merges):
    symbols = list(word) + ["</w>"]
    for a, b in merges:                       # 按学到的顺序依次合并
        i = 0
        while i < len(symbols) - 1:
            if symbols[i] == a and symbols[i + 1] == b:
                symbols[i:i + 2] = [a + b]    # 合并
            else:
                i += 1
    return symbols

for w in ["low", "newest", "lower", "lowest"]:
    print(f"{w:8s} -> {encode(w, merges)}")
```

输出：

```
low      -> ['low</w>']
newest   -> ['newest</w>']
lower    -> ['low', 'e', 'r', '</w>']
lowest   -> ['low', 'est</w>']
```

注意最后一行：**没见过的词 "lowest" 被自动拆成了 `low` + `est</w>`**。这正是子词算法的价值——即使训练时没见过这个词，也不会变成 `[UNK]`，模型还能靠 `low` 和 `est` 猜出它的意思。

### 3.3 为什么"贪心回放"就够了？

编码阶段我们按训练时学到的合并顺序，从左到右贪心地合并相邻对。有人会问：会不会有"更优的切分"？确实，BPE 编码是**贪心**的，不保证全局最优切分。但实践中贪心足够好，原因是：合并规则是从语料频率里学出来的，频率高的组合往往对应"自然语义单元"，贪心回放得到的结果通常就是人类直觉上的合理切分。而且贪心保证了**编码是确定、可复现、O(n) 高效**的——这对线上服务每秒几十万次分词至关重要。换成全局最优搜索，速度就崩了。

## 四、代码实战 2：真实分词器与 token 经济

真实项目直接用 HuggingFace 的 `transformers`：

```python
# pip install transformers tiktoken
from transformers import AutoTokenizer

text = "大模型开发从0到1，Let's build an LLM!"
for name in ["bert-base-chinese", "gpt2", "Qwen/Qwen2.5-0.5B"]:
    tok = AutoTokenizer.from_pretrained(name)
    ids = tok.encode(text)
    print(f"{name:24s} token 数={len(ids):3d}  {tok.tokenize(text)[:12]}")
```

典型输出（不同版本略有差异）：

```
bert-base-chinese       token 数= 22   ['大', '模', '型', '开', '发', '从', '0', '到', '1', '，', 'let', "'"]
gpt2                    token 数= 35   ['å', '¤', '§', 'æ', '¨', '¡', 'å', '�', '�', 'å', '¼', '�']
Qwen/Qwen2.5-0.5B       token 数= 16   ['å', '¤', '§', 'æ', '¨', '¡', 'å', '�', '�', 'å', '¼', '�']
```

（上面显示的是 UTF-8 字节的乱码形式，实际打印在终端里是正常的中文片段。**GPT-2 对中文极不友好**——它的词表几乎全是英文，一个汉字要拆成 2~3 个字节 token；而 **Qwen 专门为中英双语设计，中文压缩率高得多**。）

### 为什么中文更"贵"？

| 语言 | 大致压缩率 | 说明 |
|---|---|---|
| 英文 | 1 token ≈ 4 个字符 ≈ 0.75 个单词 | 常见英文单词是完整 token |
| 中文 | 1 token ≈ 1 ~ 1.5 个汉字（好模型） / 1 个字要 2-3 token（差模型） | 取决于词表是否针对中文优化 |

**结论**：同样的语义，中文消耗的 token 数通常是英文的 **1.5 ~ 2 倍**，API 账单也相应更贵。**选模型时优先看它的中文压缩率**（用一小段你的业务文本实测），这直接影响长期成本。

### 4.1 "压缩率"是怎么算出来的？一个实测方法

所谓"压缩率"，就是"一段文本的字数 ÷ 它对应的 token 数"。你完全可以自己测：取 1000 字你的业务文本，用目标模型的 tokenizer 编码，得到 token 数，相除即得。

不同模型差异巨大：

- **GPT-2**：中文几乎每个字拆成 2~3 个字节 token，压缩率可能低到 0.4 字/token（即 1 个汉字要 2.5 个 token）；
- **Qwen2.5 / DeepSeek / ChatGLM**：针对中文训练了大词表，常见中文词是整 token，压缩率能到 1.5~2 字/token；
- **GLM / 百度文心**：中文压缩率也较高。

对做中文应用的你，这是**选型硬指标**：同样跑 100 万次对话，中文压缩率差 3 倍，成本就差 3 倍。不要只看"模型能力排行榜"，**先看它吃你业务文本的 token 效率**。

### 4.2 成本估算函数

```python
def estimate_cost(text: str, tokens_per_char_cn: float = 0.7,
                  price_in: float = 2.0, price_out: float = 8.0):
    """
    粗估一次调用的输入成本（价格按你所用模型的官方报价填，单位：元 / 百万 token）
    中文按每字约 0.7 个 token 折算；实际请以 tokenizer 结果为准。
    """
    cn = sum(1 for ch in text if '\u4e00' <= ch <= '\u9fff')
    other = len(text) - cn
    tokens = cn * tokens_per_char_cn + other / 4.0
    return round(tokens), round(tokens / 1_000_000 * price_in, 6)

t, cost = estimate_cost("请把这段两千字的技术文档总结成五个要点。" * 10)
print(f"预估 token 数: {t}   输入成本: ¥{cost}")
```

**真实项目请务必用官方 tokenizer 精确计数**，这个函数只用于写代码时的快速心算。

### 4.3 省钱的三个实战技巧

1. **压缩输入**：长文档先摘要/分块再喂模型，减少 token 数。RAG 里"先检索再给相关片段"正是为了不把整本书塞进上下文。
2. **prompt 缓存**：很多 API（如 Claude 的 prompt cache、OpenAI 的 cached tokens）对"重复出现的前缀"给折扣，把系统提示词、few-shot 示例固定下来能省一大笔。
3. **选对模型档位**：简单任务用小模型（如 Qwen2.5-3B/7B 本地部署），只有复杂推理才上大模型。把"贵模型"用在刀刃上。

## 五、Embedding：把 ID 变成向量

分词后得到一串整数 ID，Embedding 层负责把它们变成模型能算的向量。

```
IDs:  [35946, 223, 88, 1024]          形状 (n,)
                    ↓  nn.Embedding(vocab_size, d_model)
向量: [[0.12, -0.31, ...],            形状 (n, d_model)
       [0.87,  0.02, ...],
       ...]
```

**Embedding 本质上就是一张查找表**：一个 `(vocab_size, d_model)` 的矩阵，第 i 行就是第 i 个 token 的向量。它**没有做任何计算**，只是取行。

```python
import torch
import torch.nn as nn
import torch.nn.functional as F

vocab_size, d_model = 10, 6
emb = nn.Embedding(vocab_size, d_model)

idx = torch.tensor([[1, 3, 5]])
vecs = emb(idx)
print("查表结果形状:", vecs.shape)          # torch.Size([1, 3, 6])

# 验证：等价于 one-hot 矩阵乘法
onehot = F.one_hot(idx, vocab_size).float()          # (1, 3, 10)
manual = onehot @ emb.weight                          # (1,3,10) @ (10,6)
print("与 one-hot 乘法等价:", torch.allclose(vecs, manual))   # True
```

输出 `True`——**Embedding = one-hot × 权重矩阵**。因为 one-hot 只有一位是 1，矩阵乘法退化成"取第 i 行"。这也是为什么它虽然参数量巨大（vocab 15 万 × d_model 4096 ≈ 6 亿参数），计算却极快。

### 三个必须知道的细节

1. **Embedding 维度必须等于 d_model**，否则没法送进后面的 Block。
2. **原始 Transformer 会把嵌入乘以 √d_model**，目的是让嵌入的方差与位置编码相当（位置编码的值是 [-1,1]）。GPT-2 之后大多不乘了，因为初始化已经处理好了。
3. **权重绑定（weight tying）**：GPT-2 / LLaMA 让输出层 `head.weight` 与输入 `tok_emb.weight` 共享。既省了 `vocab × d_model` 个参数，又让"输入表示"和"输出预测"在同一空间，效果更好。

### 为什么相似词的向量也相似？

训练目标是"预测下一个词"，而**出现在相似上下文里的词，会收到相似的梯度**，因此它们的向量会逐渐靠拢。这就是为什么：

```
vec("猫") - vec("动物") + vec("狗") ≈ 某个类似 "宠物" 的方向
```

以及为什么 Embedding 可以直接用于**语义检索**（阶段 7 的 RAG 就是靠它）。

### 5.3 训练 Embedding：它到底在"学"什么？

Embedding 的每一行向量，是和整个模型一起通过"预测下一个词"这个任务训练出来的。关键机制是**反向传播的共享信号**：当一个 token 出现在一个合适的上下文里、模型因此预测正确时，它的 embedding 向量会朝着"让这次预测更容易"的方向微调一点点。海量文本里，同一个 token 出现在成千上万种上下文，这些微调的信号相互平均，最终让"语义相近"的 token 聚到一起。

这解释了两个现象：

1. **冷门词向量质量差**：出现次数少的词，收到的高效梯度信号少，向量没被充分"校准"，所以生僻词、罕见术语的 embedding 往往不准——这也是为什么 RAG/检索有时比"让模型硬记"更可靠。
2. **Embedding 不是静态字典**：它是从数据中"浮现"出来的语义地图，而非人工标注。这点和传统 NLP（人工特征工程）有本质区别，也是大模型"涌现"语言理解能力的微观基础。

### 5.4 为什么 Embedding 维度 d_model 不能太小也不能太大？

d_model 决定了每个 token 向量能承载多少信息：

- **太小（如 64）**：向量容量不够，多个语义挤在一起分不开，模型"表达力贫血"；
- **太大（如 8192）**：每个向量能装很多，但参数量（vocab × d_model）和注意力计算量随之暴涨，且容易过拟合、训练更慢。

所以 d_model 要在"表达力"和"算力/显存"之间平衡，这就是为什么你看到的主流模型 d_model 落在 768（BERT-base）到 8192（超大模型）之间，且通常和层数、头数配套设计（见上一篇的 `12·L·d²` 公式）。它是模型"宽度"的核心旋钮。

### 5.1 Embedding 为什么"参数巨大却算得快"？

一个反直觉的事实：embedding 矩阵往往是大模型里**参数量最大的一块**（vocab_size × d_model，动辄几亿到几十亿），但它在前向时几乎不耗算力。原因就是上面验证的"等价 one-hot 乘法"——本质上只是"按 ID 取一行"，是个 O(1) 的查表操作，根本不涉矩阵乘。

这带来一个重要的工程权衡：

- **想省显存**：embedding 最占显存，但没法轻易压缩（每个 token 的向量都得存）。常见做法是减小 vocab_size（用更紧凑的子词词表）或减小 d_model（但会牺牲表示力）。
- **想省计算**：embedding 不是瓶颈（瓶颈在注意力 O(n²) 和 FFN）。所以优化重点永远在前向的注意力/FFN，而不是 embedding。

理解"参数为啥大、算力为啥小"，你就不会在错误的地方做优化——比如试图"优化 embedding 的前向速度"基本是徒劳，但它占的显存值得你在显存紧张时关注。

### 5.2 词向量空间的几何直觉

Embedding 学习到的向量空间不是随机的，它天然具有"语义几何结构"：

- **相似词距离近**：vec("猫") 和 vec("狗") 的余弦相似度远高于 vec("猫") 和 vec("汽车")；
- **类比关系近似线性**：vec("国王") - vec("男人") + vec("女人") ≈ vec("女王")，这类"国王-男人+女人=女王"的著名现象，说明语义关系被编码成了向量空间里的"平移方向"；
- **不同语言可对齐**：在多语模型里，vec("cat") 和 vec("猫") 经对齐后也接近，这正是跨语言检索/翻译零样本能力的基础。

这套几何结构是大模型"懂语义"的底层证据——它没背字典，但把"意义"学进了向量间的距离和方向里。

## 六、常见坑

| 坑 | 现象 | 正确做法 |
|---|---|---|
| 用错模型的 tokenizer | 输出乱码、效果极差 | **tokenizer 必须与模型严格配套**（同一个 checkpoint） |
| 数字被拆得七零八落 | 算术题老算错 | GPT-4/Qwen 用数字级分词；老模型可按位拆分，必要时先做格式化 |
| 中文 token 数远超预期 | 成本失控、上下文塞不下 | 选中文优化的模型（Qwen、DeepSeek、ChatGLM） |
| 忘记加特殊 token | 检索/分类效果差 | BERT 要 `[CLS]` `[SEP]`；对话模型要走 `apply_chat_template` |
| 截断把句子切一半 | 语义破损 | 按句子/段落切，保留重叠；长文本用滑窗 |
| 用 `len(text)` 当 token 数 | 账单差好几倍 | 必须用 tokenizer 精确计数 |

### 6.1 特殊 token 的坑：为什么少了 `[CLS]`/`[SEP]` 就废？

不同模型有各自的"特殊 token 协议"：

- **BERT**：用 `[CLS]` 放在句首，它的输出向量专门拿来做"整句表示"（分类、检索）；`[SEP]` 分隔句子对（如"前提"和"假设"）。如果你不走 `tokenizer(...)` 的默认处理、自己拼 ID，漏了 `[CLS]`/`[SEP]`，模型就收不到"这是句首/句界"的信号，句向量质量骤降。
- **对话模型（Qwen/LLaMA）**：有 `<|im_start|>`、`<|im_end|>`、`<|endoftext|>` 之类的控制 token，必须用 `tokenizer.apply_chat_template(messages)` 来正确拼接——它会自动加好角色标记和系统提示，否则模型不知道"现在轮到谁说话"，效果全乱。

所以**永远用官方 tokenizer 的接口**，别手搓 ID 序列，除非你清楚每个特殊 token 的语义。

### 6.2 数字、代码、emoji 的分词陷阱

- **数字**：老模型常把 "12345" 切成 "12"+"34"+"5"，做算术时容易错位。新模型（GPT-4、Qwen）做了"数字级"分词，每个数位独立，反而更稳。如果你的任务大量涉及数字运算，优先选这类模型，或先把数字格式化成固定宽度。
- **emoji / 生僻字**：靠 Byte-level BPE 兜底，一般没问题，但占的字节 token 多，成本略增。
- **代码**：缩进、符号多，token 数通常比自然语言高。做代码任务时按 token 计价比按行数靠谱得多。

### 6.3 长文本处理：分块（chunking）为什么要以 token 为单位？

做 RAG 或长文档摘要时，你常需要把文档切成一个个片段。这里最容易犯的错误是"按字符数切"——因为模型计费和上下文上限都是按 **token** 算的，按字符切会导致：

- 中文片段"看着不长"但实际 token 已经超窗；
- 不同模型 tokenizer 不同，同一段文字 token 数不同，按字符切无法跨模型通用。

正确做法是**用目标模型的 tokenizer 编码后，按 token 数（如 512/1024 token 一块）切分**，并保留块间重叠（overlap）避免把一句话拦腰斩断。这再次印证本篇的核心主题——**token 才是大模型世界的"货币"，一切长度、成本、窗口都要围绕它来设计**。

## 七、本篇小结

1. **子词分词**是字符与单词的折中：常见词完整保留，罕见词拆成已知片段，词表可控且几乎无 OOV。
2. **BPE** 从字符出发，反复合并频次最高的相邻对（我们亲手跑通了 10 步合并，看到 `est</w>`、`low`、`newest` 依次诞生）。WordPiece 按似然合并，Unigram 反向剪枝。
3. **编码就是回放合并规则**，未见词也能拆成已知片段（"lowest" → `low` + `est</w>`）。
4. **Embedding 就是查表**，等价于 one-hot × 权重矩阵；维度必须等于 d_model；现代模型普遍做**权重绑定**。
5. **中文 token 消耗约为英文的 1.5~2 倍**，选模型要看中文压缩率，成本估算必须用真实 tokenizer。

## 八、实战练习（可验证小任务）

1. **改语料题**：把本节语料换成中文（如 ["模型","模型化","大模型","小模型"] 各若干），重跑 BPE 代码，观察中文是按"字"还是"词"被合并的，思考为什么。
2. **压缩率实测**：用 `AutoTokenizer.from_pretrained("Qwen/Qwen2.5-0.5B")` 编码一段你自己的中文，算"字数 ÷ token 数"，对比 GPT-2 的结果，验证中文优化差距。
3. **查表验证**：把第五节 one-hot 实验的 vocab_size 改成 100000、d_model 改成 1024，观察参数量（emb.weight.numel()）有多大，体会"参数为啥大"。
4. **OOV 实验**：构造一个训练词表没见过的生造词（如 "lowestest"），用 `encode` 函数跑一遍，确认它能被拆成已知片段而非 `[UNK]`。

## 九、延伸阅读与下一步

- HuggingFace Tokenizers 文档：了解 `ByteLevel`、`WordPiece`、`Unigram` 三种 `model_type` 的配置与速度差异（Rust 实现比纯 Python 快几十倍）。
- SentencePiece：Google 出品、与语言无关的分词库，T5/LLaMA 都用它；搜索 "SentencePiece 中文训练" 可自己训一个中文 tokenizer。
- 词向量经典：读 *Efficient Estimation of Word Representations* (Word2Vec, Mikolov 2013) 和 *GloVe*，理解"向量空间里的语义几何"从何而来。
- Tokenizer 与成本：查阅你所用 API 的官方 pricing 页，亲手写个脚本批量测你的业务文本 token 数，建立"成本直觉"。

**下一篇**：输入管道打通了。现在回到模型本身——同样是 Transformer 骨架，**BERT 用双向注意力做"填空"，GPT 用因果注意力做"续写"**，这个选择决定了它们各自能干什么、干不了什么。下一篇《从 BERT 到 GPT——预训练模型的演进》会实际加载两个模型跑一遍，让你亲眼看到双向与单向的差别。

> 本篇是《大模型开发从 0 到 1》专栏第 31 篇，阶段 5「Transformer 与大模型原理」第 4 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
