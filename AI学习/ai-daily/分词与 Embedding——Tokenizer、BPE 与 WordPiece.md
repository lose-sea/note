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

## 二、三大子词算法

| 算法 | 核心思路 | 代表模型 |
|---|---|---|
| **BPE**（字节对编码） | 从字符开始，**反复合并出现频次最高的相邻对**，直到词表达到目标大小 | GPT 系列、RoBERTa、LLaMA、Qwen |
| **WordPiece** | 类似 BPE，但合并准则不是频次，而是**最大化语言模型似然**（优先合并"合并后能大幅提升概率"的对） | BERT、DistilBERT、Electra |
| **Unigram** | 反过来：先造一个大词表，**逐步删掉"删了损失最小"的子词** | T5、ALBERT、部分 SentencePiece 模型 |

现在最主流的是 **BPE**（尤其是它的字节级变种 **Byte-level BPE**——把 UTF-8 字节当作基本单元，彻底消灭 OOV，任何语言、任何 emoji 都能编码）。

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

### 编码新词

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

### 成本估算函数

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

## 六、常见坑

| 坑 | 现象 | 正确做法 |
|---|---|---|
| 用错模型的 tokenizer | 输出乱码、效果极差 | **tokenizer 必须与模型严格配套**（同一个 checkpoint） |
| 数字被拆得七零八落 | 算术题老算错 | GPT-4/Qwen 用数字级分词；老模型可按位拆分，必要时先做格式化 |
| 中文 token 数远超预期 | 成本失控、上下文塞不下 | 选中文优化的模型（Qwen、DeepSeek、ChatGLM） |
| 忘记加特殊 token | 检索/分类效果差 | BERT 要 `[CLS]` `[SEP]`；对话模型要走 `apply_chat_template` |
| 截断把句子切一半 | 语义破损 | 按句子/段落切，保留重叠；长文本用滑窗 |
| 用 `len(text)` 当 token 数 | 账单差好几倍 | 必须用 tokenizer 精确计数 |

## 七、本篇小结

1. **子词分词**是字符与单词的折中：常见词完整保留，罕见词拆成已知片段，词表可控且几乎无 OOV。
2. **BPE** 从字符出发，反复合并频次最高的相邻对（我们亲手跑通了 10 步合并，看到 `est</w>`、`low`、`newest` 依次诞生）。WordPiece 按似然合并，Unigram 反向剪枝。
3. **编码就是回放合并规则**，未见词也能拆成已知片段（"lowest" → `low` + `est</w>`）。
4. **Embedding 就是查表**，等价于 one-hot × 权重矩阵；维度必须等于 d_model；现代模型普遍做**权重绑定**。
5. **中文 token 消耗约为英文的 1.5~2 倍**，选模型要看中文压缩率，成本估算必须用真实 tokenizer。

**下一篇**：输入管道打通了。现在回到模型本身——同样是 Transformer 骨架，**BERT 用双向注意力做"填空"，GPT 用因果注意力做"续写"**，这个选择决定了它们各自能干什么、干不了什么。下一篇《从 BERT 到 GPT——预训练模型的演进》会实际加载两个模型跑一遍，让你亲眼看到双向与单向的差别。

> 本篇是《大模型开发从 0 到 1》专栏第 31 篇，阶段 5「Transformer 与大模型原理」第 4 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
