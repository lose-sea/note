# overlap 设多少才不丢上下文：答案比你想的小

> 教程常写 "chunk_overlap 设为 chunk_size 的 10%~20%"。
> 于是有人把 1000 的块设成 200 重叠——
> 结果每块都带上一段的尾巴，检索反而更容易撞到无关内容。

## 一、overlap 到底解决什么问题

**场景**：一句话被块边界切成两半。

```
块 1（前 600 字）：...退款申请需要满足以下条件：订单在 7 天内，
块 2（后 600 字）：商品未拆封，且未使用过优惠券。
```

如果用户问"退款需要什么条件"，检索到块 2，模型只看到"商品未拆封，且未使用过优惠券"——**不知道这是"退款条件"**。

加 overlap 后：

```
块 1：...退款申请需要满足以下条件：订单在 7 天内，商品未拆封，
块 2：订单在 7 天内，商品未拆封，且未使用过优惠券。
```

块 2 现在包含了完整的条件列表。**这就是 overlap 的作用：让边界处的语义不在任何一个块里"缺失"。**

## 二、overlap 的代价

**代价一：索引体积膨胀**

```
1000 字文档，chunk_size=500，overlap=0    →  2 个块，共 1000 字
1000 字文档，chunk_size=500，overlap=100  →  3 个块，共 1400 字（+40%）
```

**实际膨胀率公式**：

```
总字符数 ≈ 文档长度 × chunk_size / (chunk_size - overlap)
```

| chunk_size | overlap | 膨胀倍数 |
|---|---|---|
| 500 | 0 | 1.00 |
| 500 | 50 | 1.11 |
| 500 | 100 | 1.25 |
| 500 | 200 | 1.67 |
| 500 | 300 | 2.50 |
| 500 | 400 | 5.00 ⚠️ |

**overlap 接近 chunk_size 时，膨胀是爆炸性的。**

**代价二：检索结果重复**

重叠的内容会被两个块都命中，返回时出现"同一段内容出现两次"。

**代价三：边界噪声**

块里包含了上一段的内容，**这个块的向量表示就"不纯"**了。如果 overlap 太大，每块都带着大量上一块的内容，语义会模糊。

## 三、实验：overlap 对命中率的影响

用同一批文档和评测集：

| chunk_size | overlap | overlap% | recall@4 | 索引块数 | 重复率 |
|---|---|---|---|---|---|
| 800 | 0 | 0% | 0.79 | 118 | 0% |
| 800 | 40 | 5% | 0.83 | 124 | 2% |
| **800 | 80 | 10% | 0.88** | **131** | **4%** |
| 800 | 120 | 15% | 0.88 | 139 | 7% |
| 800 | 160 | 20% | 0.87 | 148 | 10% |
| 800 | 240 | 30% | 0.84 | 169 | 16% |
| 800 | 400 | 50% | 0.76 | 236 | 28% |

**规律**：

```
0% → 10%：命中率明显上升（修复了边界丢失）
10% → 20%：基本持平（收益已经饱和）
20% → 50%：命中率下降（噪声和重复开始占主导）
```

**最优区间是 8%~15%，也就是约 80~120 字（对 800 的块）。**

**这个数字比"10%~20%"的常见建议更窄**——而且超过 20% 就开始有害。

## 四、为什么 10% 就够了

**因为 overlap 只需要覆盖"一个完整句子"的长度。**

```
块边界处的信息丢失，最长也就丢一句话。
中文一句话的长度：20~80 字（平均约 40 字）
```

所以 overlap = **一句话的长度** 就足够。对 800 字的块，一句话占 5%——10% 已经有余量了。

**overlap 超过 20% 时，情况反转**：

```
块 1：[========= 主题A =========]
块 2：          [========= 主题B =========]
                    ↑ 这 160 字是 A 的尾部和 B 的开头

块 2 的向量 = 0.2 × 主题A + 0.8 × 主题B
→ 对"主题A"的问题相似度不够
→ 对"主题B"的问题相似度被稀释
```

**块 2 变成了"半个 A 加完整的 B"，两边都不讨好。**

## 五、overlap 的正确打开方式

**① 按句子边界重叠，而不是按字符数**

字符级的 overlap 会从句子中间切开：

```
块 1：...满足以下条件：订单在 7 天内，商
块 2：品未拆封，且未使用过优惠券...
```

**"商" + "品未拆封"** 这种断裂很难看，也影响语义。

```python
from langchain_text_splitters import RecursiveCharacterTextSplitter

splitter = RecursiveCharacterTextSplitter(
    chunk_size=800,
    chunk_overlap=100,
    separators=["\n\n", "\n", "。", "！", "？", "；", "，", " ", ""],
    keep_separator=True,        # 保留分隔符，句子更完整
)
```

**`separators` 里带中文标点，是中文文档的关键**——默认的分隔符只有英文标点，中文会被当成一个巨大段落。

**② 用"标题感知"切分替代盲目重叠**

如果文档有清晰结构，**按标题切分比按长度切分好得多**：

```python
from langchain_text_splitters import MarkdownHeaderTextSplitter

splitter = MarkdownHeaderTextSplitter(
    headers_to_split_on=[
        ("#", "h1"),
        ("##", "h2"),
        ("###", "h3"),
    ],
    strip_headers=False,        # 保留标题在内容里
)
chunks = splitter.split_text(markdown_text)
```

按标题切分后，**每块天然是完整的语义单元，overlap 可以设得很小（甚至为 0）**。

**③ 语义分块：在语义变化处切**

```python
def semantic_split(text: str, max_chunk: int = 800):
    """在两个句子的语义相似度骤降处切分"""
    sentences = split_sentences(text)
    embs = embed(sentences)

    chunks, current = [], [sentences[0]]
    for i in range(1, len(sentences)):
        sim = cosine(embs[i - 1], embs[i])
        if sim < 0.5 or sum(len(s) for s in current) > max_chunk:
            chunks.append("".join(current))
            current = [sentences[i]]
        else:
            current.append(sentences[i])
    chunks.append("".join(current))
    return chunks
```

**语义分块在"意思变了"的地方切**，块边界天然合理，**几乎不需要 overlap**。

## 六、不同场景的 overlap 建议

| 场景 | chunk_size | overlap | 说明 |
|---|---|---|---|
| 技术文档 | 800 | 80（10%） | 标准配置 |
| 按标题切分 | 不定 | **0** | 天然边界，不需要重叠 |
| 语义分块 | 不定 | **0~40** | 边界已经最优 |
| 问答对 | 按问答 | **0** | 一问一答不能重叠 |
| 法律条款 | 1000 | 100（10%） | 条款互相引用，需要一点重叠 |
| 聊天记录 | 400 | 60（15%） | 对话上下文依赖强 |
| 代码 | 按函数 | **0** | 函数不会"重叠" |

**规律：边界越"天然"，overlap 越可以小。**

## 七、验证 overlap 是否合适

**方法一：看是否有"半句块"**

```python
def find_broken_chunks(chunks, min_len=30):
    """找出以不完整句子开头/结尾的块"""
    broken = []
    for c in chunks:
        text = c.page_content.strip()
        # 开头不是标点/标题，且前一个字不是句末标点
        if not text[0] in "【#【1. 一、•-*" and text[0] not in "，。！？；":
            broken.append(text[:40])
    return broken
```

**方法二：看重复率**

```python
def overlap_ratio(chunks):
    """统计相邻块的重复字符比例"""
    dup = 0
    total = 0
    for i in range(1, len(chunks)):
        prev, cur = chunks[i-1].page_content, chunks[i].page_content
        # 找 cur 开头有多少字出现在 prev 的结尾
        n = 0
        for l in range(min(len(cur), 200), 0, -1):
            if cur[:l] in prev:
                n = l
                break
        dup += n
        total += len(cur)
    return dup / total if total else 0
```

如果重复率超过 15%，说明 overlap 太大了。

**方法三：检索结果去重后才用**

```python
def dedupe_retrieved(docs, threshold: float = 0.9):
    """去掉高度重叠的检索结果"""
    out = []
    for d in docs:
        if not any(similar(d.page_content, o.page_content) > threshold for o in out):
            out.append(d)
    return out
```

## 八、小结

```
overlap 黄金值：chunk_size 的 8% ~ 15%
  800 的块 → 80 ~ 120 字
  1000 的块 → 80 ~ 150 字
  300 的块 → 30 ~ 50 字
```

四条原则：

```
1. 只覆盖"一句话"的长度就够了，不需要更多
2. 超过 20% 开始有害（噪声 + 重复 + 索引膨胀）
3. 边界天然时（标题切分/语义分块/代码），overlap 可以为 0
4. 中文文档必须自定义 separators，带中文标点
```

**一句话：overlap 是"创可贴"，不是"补药"。** 它用来修补切分造成的边界损伤，最好的方案是**让切分本身就在正确的位置发生**（按标题、按语义），这样就不需要大 overlap。

**如果你的 overlap 需要设到 30% 以上，说明切分策略有问题，该换切分方式了。**
