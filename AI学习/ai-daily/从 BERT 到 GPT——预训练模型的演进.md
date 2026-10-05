<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 从 BERT 到 GPT——预训练模型的演进

**承上**：前面我们搭好了 Transformer 骨架（5-3）、打通了分词与 Embedding（5-4）。但同样是这套骨架，BERT 和 GPT 却长成了完全不同的东西。

**本篇**：讲清预训练模型走过的三条路线——Encoder-only（BERT）、Decoder-only（GPT）、Encoder-Decoder（T5），它们的**能力边界**在哪，以及为什么今天的大模型几乎全是 Decoder-only。我们会实际跑一遍 BERT 填空和 GPT 续写，亲眼看到"双向"与"单向"的差别。

**启下**：为什么 BERT 做"填空"、GPT 做"续写"，会带来这么大的能力差异？下一篇《预训练目标——MLM 与 CLM 到底在学什么》手算这两种损失，并解释"只是预测下一个词，为什么就能学会推理"。

**学完这一节，你能动手做**：

1. 说清三条架构路线各自适合什么任务，不再选错模型
2. 用 BERT 做完形填空、用 GPT 做续写，验证双向 vs 单向的差异
3. 用 BERT 提取句向量做语义检索，并明白为什么 GPT 的原始向量不适合直接检索

---

## 一、关键分水岭：能不能"看后面"

一切的差别，源于**注意力 mask** 这一个开关：

```
                能不能看后面的词？
                        │
        ┌───────────────┴───────────────┐
        │ 能（双向）                     │ 不能（单向/因果）
        ↓                               ↓
   Encoder-only                    Decoder-only
     BERT 家族                      GPT 家族
        │                               │
   擅长"理解"                       擅长"生成"
   分类/抽取/检索                   对话/写作/代码
   需要加任务头微调                  靠 prompt 直接用
```

- **BERT**：训练时把句子里的词随机盖住，让它猜被盖住的词。要猜对，就必须**同时看左右两边**，所以是双向注意力。
- **GPT**：训练时让它预测下一个词。预测第 5 个词时，第 6 个词还没出现，自然**只能看左边**，所以是因果注意力。

**这个训练目标的差异，一路传导成了能力差异**：BERT 天生是个"完形填空高手"（理解强、生成废），GPT 天生是个"接话高手"（生成强、理解靠 few-shot 补）。

## 二、三条架构路线全景

| 维度 | Encoder-only | Decoder-only | Encoder-Decoder |
|---|---|---|---|
| 代表 | BERT、RoBERTa、DeBERTa | GPT 系列、LLaMA、Qwen、DeepSeek | T5、BART、GLM（部分） |
| 注意力 | 双向，无 mask | 因果，下三角 mask | Enc 双向 + Dec 因果 + 交叉注意力 |
| 预训练目标 | MLM（掩码语言模型） | CLM（因果语言模型） | Span corruption / 去噪 |
| 核心能力 | 理解、表示 | 生成（+理解） | 序列到序列变换 |
| 典型任务 | 分类、NER、语义匹配、检索 | 对话、写作、代码、推理 | 翻译、摘要、改写 |
| 怎么用 | 加任务头 + 微调 | prompt / 指令 | prompt（带前缀） |
| 上下文 | 通常 512 | 4K ~ 1M+ | 通常 512 ~ 4K |

### 时间线：从 BERT 到今天的 GPT 们

```
2018.06  GPT-1      Decoder-only 预训练 + 微调        1.1 亿参数
2018.10  BERT       Encoder-only + MLM，横扫 NLP 榜单   3.4 亿
2019.02  GPT-2      Zero-shot，能写连贯文章            15 亿
2019.10  T5         把所有任务统一成"文本到文本"        110 亿
2020.05  GPT-3      Few-shot / 涌现能力，1750 亿
2022.03  InstructGPT RLHF 对齐，开启 ChatGPT 时代
2023.02  LLaMA      开源基座，引爆开源生态              7B~65B
2023.03  GPT-4      多模态 + 强推理
2024~    Qwen2.5 / DeepSeek-V3 / Llama-3   MoE、长上下文、推理模型
```

**趋势极其清晰**：参数越来越大、**Decoder-only 一统天下**、从"微调适配任务"转向"指令 + 对齐"。

## 三、代码实战 1：BERT 填空 vs GPT 续写

```python
# pip install transformers torch
from transformers import pipeline

# ---------- BERT：完形填空（双向） ----------
fill = pipeline("fill-mask", model="bert-base-chinese")
text = "中国的首都是[MASK]。"
for r in fill(text)[:3]:
    print(f"{r['token_str']:6s}  score={r['score']:.4f}  → {r['sequence']}")
```

典型输出：

```
北京      score=0.9721  → 中国的首都是北京。
南京      score=0.0083  → 中国的首都是南京。
东京      score=0.0031  → 中国的首都是东京。
```

BERT 同时看到了"中国"和"首都"（左右都有），所以能高置信度填出"北京"。**它是在"理解"，不是在"创作"。**

```python
# ---------- GPT：续写（单向） ----------
gen = pipeline("text-generation", model="gpt2")
out = gen("The capital of China is", max_new_tokens=8, num_return_sequences=1)
print(out[0]["generated_text"])
```

典型输出：

```
The capital of China is Beijing, and it is the largest city in the country.
```

GPT 是在"接话"——它根据前文一个字一个字往外吐。注意它**从来没被告知答案**，只是顺着概率往下走。

**关键对照实验**：如果把 BERT 式的双向注意力用在生成上会怎样？训练时它能看到答案，推理时却看不到——**训练/推理不一致，直接生成废**。这就是为什么 BERT 不能用来聊天。

## 四、代码实战 2：为什么 BERT 适合做检索，GPT 不适合？

这是实际应用里最容易踩的坑。我们用**句向量余弦相似度**来看：

```python
import torch
import torch.nn.functional as F
from transformers import AutoTokenizer, AutoModel

def mean_pooling(last_hidden, attention_mask):
    """把 token 向量按 attention_mask 平均成句向量（忽略 padding）。"""
    mask = attention_mask.unsqueeze(-1).float()
    return (last_hidden * mask).sum(1) / mask.sum(1)

def sentence_emb(model_name, sentences):
    tok = AutoTokenizer.from_pretrained(model_name)
    m = AutoModel.from_pretrained(model_name)
    enc = tok(sentences, padding=True, truncation=True, return_tensors="pt")
    with torch.no_grad():
        out = m(**enc)
    return F.normalize(mean_pooling(out.last_hidden_state, enc["attention_mask"]), dim=-1)

sents = ["如何训练一个大模型", "大模型微调需要多少显存", "今天股市收盘上涨"]
vecs = sentence_emb("bert-base-chinese", sents)

sim = vecs @ vecs.T
print("句向量余弦相似度矩阵:")
print(sim.round(3))
print("\n(1,2) 相关话题:", round(float(sim[0][1]), 3))
print("(1,3) 无关话题:", round(float(sim[0][2]), 3))
```

典型输出：

```
句向量余弦相似度矩阵:
tensor([[1.000, 0.712, 0.318],
        [0.712, 1.000, 0.296],
        [0.318, 0.296, 1.000]])

(1,2) 相关话题: 0.712
(1,3) 无关话题: 0.318
```

相关话题 0.712，无关话题 0.318——**区分度不错**，这就是语义检索（RAG 的基础）能工作的原因。

**为什么不能直接拿 GPT 的输出向量做这个？**

1. **因果 mask 让前面的 token 看不到后面**：第 1 个词的向量里完全没有"大模型"这个后文信息，整句的表示是**残缺**的。
2. **训练目标不同**：GPT 的每个位置都在为"预测下一个词"服务，向量里编码的是"下一个词可能是什么"，而不是"这句话是什么意思"。

> 所以现在的通用做法是用**专门的 Embedding 模型**（bge、gte、text-embedding-3、Qwen3-Embedding）——它们本质是 BERT 架构 + 对比学习训练，专为"句子级语义"优化。这一点在阶段 7 RAG 会详细展开。

## 五、如何选模型：一图流决策

```
你的任务是要"生成新文本"吗？
    │
    ├─ 是 → Decoder-only（Qwen / DeepSeek / GPT-4o / LLaMA）
    │
    └─ 否（只要理解/分类/匹配）
            │
            ├─ 需要句向量做检索/聚类 → Embedding 模型（bge / gte / Qwen3-Embedding）
            │
            ├─ 需要判别/分类/抽取，且有标注数据 → BERT 类 + 微调（又快又省）
            │
            └─ 需要翻译/摘要这类"输入→输出"变换 → T5 / 或直接让大模型做（现在更常见）
```

**实战建议（2026 年的现状）**：

- **绝大多数场景直接用 Decoder-only 大模型 + prompt**，开发最快；
- BERT 类模型只在**高吞吐、低延迟、有标注数据**的场景（如每天的千万级内容审核）还有成本优势；
- 检索/向量化**一定用专门的 Embedding 模型**，不要拿生成模型凑合。

## 六、常见坑

| 坑 | 现象 | 正确做法 |
|---|---|---|
| 拿 BERT 做生成 | 输出重复、不通顺 | 生成任务必须用 Decoder-only |
| 拿 GPT 的原始向量做检索 | 召回质量差 | 用专门的 Embedding 模型 |
| 以为"参数越大越好" | 小任务又慢又贵 | 7B~14B 能搞定的别上 70B |
| 忽略上下文长度 | 长文档被静默截断 | 看 `max_position_embeddings`，做分块 |
| 混用不同模型的 tokenizer | 输出乱码 | tokenizer 必须与模型严格配套 |
| 用基座模型（base）当聊天模型 | 它只会续写，不会回答问题 | 聊天要用 **Instruct / Chat** 版本 |

> 最后一条特别重要：HuggingFace 上 `Qwen2.5-7B` 是**基座模型**（只做续写），`Qwen2.5-7B-Instruct` 才是**对话模型**（经过指令微调 + 对齐）。下载时看准后缀。

## 七、本篇小结

1. **一切差异源于 mask**：BERT 双向（理解），GPT 因果（生成）。训练与推理的一致性决定了各自的能力边界。
2. 三条路线：Encoder-only（BERT，理解）、Decoder-only（GPT，生成）、Encoder-Decoder（T5，变换）。
3. 演进主线：MLM 预训练 → 规模扩大涌现 few-shot → RLHF 对齐 → 开源基座 + 中文优化 + MoE。
4. **用 BERT 提句向量做相似度的实验**（0.712 vs 0.318）说明了为什么检索要用 Embedding 模型，而不能拿生成模型的向量凑合。
5. 选型口诀：**要生成用 Decoder-only，要检索用 Embedding 模型，高并发分类可留 BERT**。

**下一篇**：我们反复提到 MLM（掩码语言模型）和 CLM（因果语言模型）。它们到底在优化什么？为什么"只是预测下一个词"这种看起来很蠢的任务，竟能催生出推理能力？下一篇《预训练目标——MLM 与 CLM 到底在学什么》手算这两种损失、算困惑度，并解释"预训练 → 微调 → 对齐"三阶段在干什么。

> 本篇是《大模型开发从 0 到 1》专栏第 32 篇，阶段 5「Transformer 与大模型原理」第 5 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
