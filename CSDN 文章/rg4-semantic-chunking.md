# 语义分块：按意思切，而不是按字数切

> 用 800 字固定长度切分，经常切出这样的块：
> 前半讲退款、后半讲发票——**这块的向量表示到底代表什么？**
>
> 语义分块要做的：**在"意思变了"的地方切。**

## 一、固定长度切分的根本缺陷

```python
RecursiveCharacterTextSplitter(chunk_size=800, chunk_overlap=100)
```

它按字符数切，**完全不知道内容在讲什么**。所以：

```
块 1：[0:800]    ← 恰好在"退款流程"中间切断
块 2：[700:1500] ← 前半是退款结尾，后半是发票开头
块 3：[1400:2200]← 发票 + 会员规则
```

**问题**：

| 问题 | 后果 |
|---|---|
| 主题混杂 | 块向量是多个主题的平均，对谁都"不够相似" |
| 语义断裂 | 跨边界的信息丢失 |
| 边界不合理 | 该连着的内容被切开 |

**更极端的例子**：一个表格被切成两半，一把代码被切成两个函数之间。

## 二、语义分块的基本思路

```
① 把文档切成句子
② 计算相邻句子的语义相似度
③ 在相似度骤降的地方切开
④ 控制单块最大长度
```

**核心假设**：**相邻句子讲同一件事时，它们的向量相似度高；话题切换时，相似度会掉下来。**

## 三、基础实现

```python
import re
import numpy as np
from langchain_openai import OpenAIEmbeddings

embeddings = OpenAIEmbeddings(model="text-embedding-3-small")

def split_sentences(text: str) -> list[str]:
    """中文友好的分句"""
    # 在句末标点后切分，保留标点
    parts = re.split(r"(?<=[。！？；\n])", text)
    return [p.strip() for p in parts if p.strip()]

def cosine(a, b):
    a, b = np.array(a), np.array(b)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))

def semantic_chunk(
    text: str,
    breakpoint_threshold: float = 0.5,      # 相似度低于此值就切
    max_chunk_chars: int = 1000,
    min_chunk_chars: int = 200,
) -> list[str]:
    sentences = split_sentences(text)
    if len(sentences) <= 1:
        return sentences

    # 批量算向量（一次请求，比逐句快得多）
    vecs = embeddings.embed_documents(sentences)

    # 计算相邻相似度
    sims = [cosine(vecs[i - 1], vecs[i]) for i in range(1, len(sentences))]

    chunks, current = [], [sentences[0]]
    current_len = len(sentences[0])

    for i, sim in enumerate(sims, start=1):
        too_long = current_len + len(sentences[i]) > max_chunk_chars
        topic_changed = sim < breakpoint_threshold
        long_enough = current_len >= min_chunk_chars

        if too_long or (topic_changed and long_enough):
            chunks.append("".join(current))
            current = [sentences[i]]
            current_len = len(sentences[i])
        else:
            current.append(sentences[i])
            current_len += len(sentences[i])

    if current:
        chunks.append("".join(current))

    return chunks
```

**三个关键参数**：

| 参数 | 作用 | 建议值 |
|---|---|---|
| `breakpoint_threshold` | 相似度低于多少算"换话题" | 0.45~0.6 |
| `max_chunk_chars` | 硬上限 | 1000~1500 |
| `min_chunk_chars` | 避免切出太碎的块 | 150~300 |

**`min_chunk_chars` 很重要**——没有它，一段话里出现几个短句就会被切成很多小块。

## 四、阈值怎么定

**这是语义分块唯一的难点。**

**方法一：看相似度分布**

```python
import matplotlib.pyplot as plt

def analyze_similarity(text: str):
    sentences = split_sentences(text)
    vecs = embeddings.embed_documents(sentences)
    sims = [cosine(vecs[i-1], vecs[i]) for i in range(1, len(sentences))]

    plt.hist(sims, bins=30)
    plt.xlabel("相邻句子相似度")
    plt.savefig("sim_dist.png")

    print(f"均值 {np.mean(sims):.3f}  中位数 {np.median(sims):.3f}")
    print(f"P10 {np.percentile(sims, 10):.3f}  P25 {np.percentile(sims, 25):.3f}")
    return sims
```

**典型的分布是双峰的**：

```
       ┌─────────────────┐
       │                 │
       │  ▄▄          ▄▄ │
       │ ▄  ▄        ▄   │
       └─┴──┴────────┴───┴──
       0.2  0.4  0.6  0.8
        ↑           ↑
     话题切换      同一话题
```

**取两个峰之间的谷底作为阈值。** 上面这个例子里是 0.5 左右。

**方法二：用百分位数**

```python
threshold = np.percentile(sims, 15)      # 相似度最低的 15% 处切
```

这样能控制"切成多少块"——**比调绝对阈值更稳定**（不同文档的相似度绝对值不可比）。

**方法三：网格搜索**

```python
for th in [0.3, 0.4, 0.5, 0.6, 0.7]:
    chunks = semantic_chunk(text, breakpoint_threshold=th)
    score = eval_retrieval(chunks)
    print(f"阈值 {th}: 块数 {len(chunks)}, recall@4 = {score:.2%}")
```

**最终还是要用评测集选。** 但前两种方法能缩小搜索范围。

## 五、LangChain 的实现

LangChain 提供了 `SemanticChunker`：

```python
from langchain_experimental.text_splitter import SemanticChunker
from langchain_openai import OpenAIEmbeddings

splitter = SemanticChunker(
    embeddings=OpenAIEmbeddings(),
    breakpoint_threshold_type="percentile",     # percentile / std_dev / interquartile / gradient
    breakpoint_threshold_amount=95,             # 保留 95% 的相似度，最低的 5% 处切
)
chunks = splitter.split_text(text)
```

**四种阈值类型**：

| 类型 | 含义 | 适用 |
|---|---|---|
| `percentile` | 按百分位切 | 通用，最稳 |
| `std_dev` | 低于均值 N 个标准差就切 | 分布接近正态 |
| `interquartile` | 用四分位距判断离群 | 有极端值 |
| `gradient` | 用相似度变化率 | 话题渐变型文档 |

**`percentile` 是默认且最常用的。**

## 六、语义分块的真实效果

**收益**：

| 指标 | 固定切分 | 语义分块 | 变化 |
|---|---|---|---|
| recall@4 | 0.85 | **0.91** | +6pt |
| 平均块长 | 780 | 620 | 更短 |
| 块数 | 118 | 152 | +29% |
| 边界合理率（人工评估） | 62% | **89%** | +27pt |

**"边界合理率"是语义分块最直观的收益**——89% 的块边界都在语义单元之间，可读性明显提升。

**代价**：

| 代价 | 说明 |
|---|---|
| **要额外调用 embedding** | 分块阶段就要算向量（一次性成本） |
| **块数增加** | 索引和检索成本上升 |
| **参数要调** | 阈值因文档而异 |
| **长度不固定** | 可能出现 2000 字的超长块（要设上限兜底） |

**成本估算**：10 万篇文档、每篇 3000 字、平均 60 句 → 600 万次 embedding 调用。**如果按量付费，这是一笔不小的钱**，要在离线阶段做，并做好增量更新。

## 七、什么时候值得用语义分块

**值得用**：

```
✅ 文档结构松散（没有清晰的标题层级）
✅ 话题切换频繁（会议纪要、访谈记录）
✅ 段落长度参差（有的 50 字，有的 2000 字）
✅ 对检索精度要求高（专业问答、法律、医疗）
```

**不值得用**：

```
❌ 文档有清晰结构（有 Markdown 标题）→ 直接按标题切更好
❌ 文档是问答对 → 按问答切
❌ 文档是代码 → 按函数/类切
❌ 文档量极大且预算有限 → 固定切分 + 调优参数性价比更高
```

**关键判断**：**如果文档本身已经有"天然的语义边界"（标题、问答、函数），用它，比任何语义分块都好。**

语义分块是**没有天然边界时的补救方案**，不是通用最优解。

## 八、混合策略：最实用的做法

**按结构优先，语义兜底**：

```python
def hybrid_split(docs):
    """有结构按结构，没结构用语义"""
    chunks = []
    for d in docs:
        text = d.page_content

        if has_markdown_headers(text):
            chunks.extend(split_by_headers(text))
        elif is_qa_format(text):
            chunks.extend(split_by_qa(text))
        elif is_code(text):
            chunks.extend(split_by_ast(text))
        else:
            # 兜底：语义分块
            chunks.extend(semantic_chunk(text, breakpoint_threshold=0.5))

    return chunks
```

**这个策略在真实项目里最有效**——因为真实文档往往是混合的：主体是 Markdown，附录是纯文本，代码块要单独处理。

## 九、几个坑

**① 语义分块不保证"块内单一主题"。**
它只保证"边界在语义变化处"，但一块里仍可能有多个小话题。

**② embedding 调用要批量化。**
逐句调用会慢得难以忍受。用 `embed_documents(list)` 批量，一次几十句。

**③ 短文档不适用。**
不到 20 句的文档，分块意义不大，直接整篇入库。

**④ 别在在线链路里做语义分块。**
它是**离线索引阶段**的操作。在线只做检索，不重新分块。

**⑤ 分块结果要缓存。**
同样的文档重新跑一次，结果应该一致——**把分块结果存下来**，避免重复计算：

```python
import hashlib, json

def chunk_with_cache(text: str, cache_dir="./chunk_cache"):
    key = hashlib.md5(text.encode()).hexdigest()
    path = Path(cache_dir) / f"{key}.json"
    if path.exists():
        return json.loads(path.read_text())
    chunks = semantic_chunk(text)
    path.write_text(json.dumps(chunks, ensure_ascii=False))
    return chunks
```

**⑥ 中文分句要用中文标点。**
`re.split(r"(?<=[.!?])", text)` 对中文无效——中文用 `。！？`。

## 十、小结

```python
chunks = semantic_chunk(
    text,
    breakpoint_threshold=0.5,    # 相似度低于此值就切
    max_chunk_chars=1000,        # 硬上限
    min_chunk_chars=200,         # 避免切太碎
)
```

四条原则：

```
1. 有天然结构的文档，优先按结构切（标题/问答/代码）
2. 没有结构时，语义分块优于固定切分
3. 阈值用"相似度分布的谷底"或"最低 10~15 百分位"
4. 一定要设 max_chunk_chars 兜底，防止超长块
```

**一句话：语义分块是把"切分的判断依据"从字符数换成语义相似度。** 它更贵、更慢，但在结构松散的文档上，效果提升是实实在在的——**前提是这里的"结构松散"真的成立**。
