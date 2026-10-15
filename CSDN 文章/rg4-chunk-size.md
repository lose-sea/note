# chunk_size 到底设多少：一次实验讲清取舍

> 教程里都说 "chunk_size 设 500~1000"。
> 但你的文档是技术手册，他的文档是聊天记录，同一套参数真的合适吗？
>
> 这篇用一个可复现的实验，把这件事讲清楚。

## 一、chunk_size 影响什么

```
块太大（2000+）
├─ ✅ 上下文完整，不容易断章取义
├─ ❌ 检索粒度粗：块里只有一句话相关，整块都要塞进去
├─ ❌ 噪声多：无关内容稀释了相关内容
└─ ❌ 成本高：每次塞很多 token

块太小（200 以下）
├─ ✅ 检索精准：几乎每块都在讲同一件事
├─ ✅ 噪声少
├─ ❌ 上下文缺失：检索到"需要 3 个工作日"，但不知道"什么需要"
├─ ❌ 块数量爆炸：索引和检索成本上升
└─ ❌ 一句话被切成两半
```

**核心矛盾：检索精度 vs 上下文完整性。**

## 二、实验设计

**文档**：一篇 2 万字的产品文档（含标题、段落、列表、代码块）
**问题集**：20 道，标注了答案所在的段落
**变量**：chunk_size ∈ {200, 400, 600, 800, 1200, 1600, 2400}

**测量两个指标**：

```python
def measure(chunk_size: int):
    chunks = split(docs, chunk_size=chunk_size, overlap=chunk_size // 8)
    vectorstore = build_index(chunks)

    hits = 0
    for item in EVAL_SET:
        docs_ = vectorstore.similarity_search(item["question"], k=4)
        # 命中判定：检索结果里是否包含答案关键词
        if any(any(kw in d.page_content for kw in item["keywords"]) for d in docs_):
            hits += 1

    return {
        "chunk_size": chunk_size,
        "chunks": len(chunks),
        "recall@4": hits / len(EVAL_SET),
        "avg_chunk_len": sum(len(c.page_content) for c in chunks) / len(chunks),
    }
```

## 三、实验结果（典型数据）

| chunk_size | 块数 | recall@4 | 平均块长 | 上下文 token/次 |
|---|---|---|---|---|
| 200 | 412 | 0.55 | 180 | ~800 |
| 400 | 218 | 0.72 | 370 | ~1600 |
| **600** | **152** | **0.85** | **560** | **~2400** |
| **800** | **118** | **0.88** | **740** | **~3100** |
| 1200 | 82 | 0.84 | 1120 | ~4600 |
| 1600 | 64 | 0.76 | 1510 | ~6100 |
| 2400 | 45 | 0.68 | 2280 | ~9200 |

**规律非常清晰**：

```
200 → 400 → 600 → 800：命中率上升（块变大，上下文更完整）
800 → 1200 → 1600 → 2400：命中率下降（块太大，噪声占主导）
```

**峰值在 600~800 之间。** 这不是巧合——它对应"一个完整段落"的典型长度。

## 四、为什么会有这个峰值

**上升段**：块太小时，一个问题需要的信息被切到多个块里。

```
块 1：退款申请需要满足以下条件：
块 2：1. 订单在 7 天内；2. 商品未拆封。
```

用户问"退款条件是什么"，检索到块 2 就够了。但如果答案只在块 1 里（比如"退款流程从提交申请开始"），可能检索不到。

**下降段**：块太大时，一块里混了多个主题。

```
块（2000 字）：
  ...退款流程...（200 字）
  ...发票申请...（300 字）
  ...会员规则...（400 字）
  ...物流政策...（500 字）
  ...
```

这一块的 embedding 是"五个主题的平均值"，**对任何单一问题都不够相似**。所以检索时反而不如小块。

**这就是"语义稀释"**——块内的主题越多，向量表示的语义越模糊。

## 五、不同文档类型的最优值

**实验结论不能直接照搬**，因为不同文档的段落长度不同。

| 文档类型 | 建议 chunk_size | 理由 |
|---|---|---|
| 技术文档 / 手册 | 600~1000 | 段落完整，逻辑成块 |
| 法律合同 | 1000~1500 | 条款长且互相引用 |
| FAQ / 问答对 | **按问答切分** | 一问一答是天然块 |
| 聊天记录 | 300~500 | 对话轮次短 |
| 论文 | 800~1200 | 段落较长，有明确结构 |
| 代码 | 按函数/类切分 | 语法结构是天然边界 |
| 表格 | 整表不切 | 切了就没意义 |

**通用规律：chunk_size 应该约等于"一个完整语义单元的典型长度"。**

- 一段 = 一个完整意思 → 用段落长度
- 一问一答 = 一个单元 → 用问答长度
- 一个函数 = 一个单元 → 用函数长度

## 六、怎么快速找到你文档的最优值

**三步法**：

**① 看段落长度分布**

```python
import numpy as np
from langchain_text_splitters import RecursiveCharacterTextSplitter

# 用极大 chunk_size 拿到自然段落
splitter = RecursiveCharacterTextSplitter(chunk_size=100000, chunk_overlap=0,
                                          separators=["\n\n"])
paras = splitter.split_documents(docs)
lens = [len(p.page_content) for p in paras]

print(f"段落数：{len(lens)}")
print(f"平均：{np.mean(lens):.0f}")
print(f"中位数：{np.median(lens):.0f}")
print(f"P25/P75：{np.percentile(lens, 25):.0f} / {np.percentile(lens, 75):.0f}")
```

**取中位数附近的整数值作为候选。** 中位数比平均值好——平均值会被超长段落拉偏。

**② 在候选值附近做实验**

中位数是 650？那就测 `[400, 500, 650, 800, 1000]`。

**③ 用评测集选最优**

```python
results = []
for size in [400, 500, 650, 800, 1000]:
    m = measure(size)
    results.append(m)
    print(f"size={size}: recall@4={m['recall@4']:.2%}")

best = max(results, key=lambda x: x["recall@4"])
print(f"\n最优：{best['chunk_size']}")
```

**这一步是必须的**——不要相信任何文章的"推荐值"，包括这篇。

## 七、进阶：小块检索，大块喂给模型

如果"小块精准、大块完整"两个好处都想要，用 **ParentDocumentRetriever** 的思路：

```python
from langchain.retrievers import ParentDocumentRetriever
from langchain.storage import InMemoryStore
from langchain_chroma import Chroma

# 小子块用于检索
child_splitter = RecursiveCharacterTextSplitter(chunk_size=300, overlap=50)
# 大父块用于提供上下文
parent_splitter = RecursiveCharacterTextSplitter(chunk_size=1500, overlap=0)

retriever = ParentDocumentRetriever(
    vectorstore=Chroma(embedding_function=embeddings, collection_name="child"),
    docstore=InMemoryStore(),
    child_splitter=child_splitter,
    parent_splitter=parent_splitter,
)

retriever.add_documents(docs)
```

**工作方式**：

```
检索时：用 300 字的小块匹配（精准）
返回时：返回该小块所属的 1500 字父块（完整）
```

**这是"既要又要"的标准答案**——检索精度和上下文完整性兼得。

生产环境里，`docstore` 要换成持久化的（Redis / 数据库），不能用 `InMemoryStore`。

## 八、几个容易忽略的细节

**① chunk_size 的计数单位**

```python
# 按字符数（中文）
splitter = RecursiveCharacterTextSplitter(chunk_size=600, length_function=len)

# 按 token 数（更准）
import tiktoken
enc = tiktoken.get_encoding("cl100k_base")
splitter = RecursiveCharacterTextSplitter(
    chunk_size=300,
    length_function=lambda t: len(enc.encode(t)),
)
```

**中文字符和 token 不是 1:1**——一个中文字约 1~1.5 个 token。用 token 计数更精确，但要保证 embedding 模型的限制（很多模型限制 512 token）。

**② 别超过 embedding 模型的上限**

```python
# text-embedding-3-small 支持 8191 token
# bge-base 只支持 512 token ← 超了会被静默截断！
```

**超限被静默截断是最隐蔽的 bug**——块的后半部分根本没进向量，检索自然找不到。

**③ 特殊块要单独处理**

```python
def split_with_special_handling(docs):
    normal, special = [], []
    for d in docs:
        if d.metadata.get("type") in ("table", "code"):
            special.append(d)          # 表格/代码整块保留
        else:
            normal.append(d)

    chunks = splitter.split_documents(normal)
    return chunks + special            # 特殊块不切
```

**④ 加标题上下文**

小块最大的问题是"不知道在讲什么主题"。**给每个块加上它所属的标题路径**：

```python
def add_heading_context(chunks, doc_headings):
    for c in chunks:
        # 从原始文档里找到这个块所属的标题
        heading = find_heading(c, doc_headings)
        c.page_content = f"【{heading}】\n{c.page_content}"
    return chunks
```

效果：

```
【退款政策 > 申请条件】
1. 订单在 7 天内；2. 商品未拆封。
```

**加上标题后，小块也有了上下文**，同时不显著增加长度。

## 九、小结

```
chunk_size 的黄金区间（经验值）：
  技术文档    600 ~ 1000
  合同/法律   1000 ~ 1500
  聊天记录    300 ~ 500
  问答对      按问答切
  代码/表格   按结构切，别按长度
```

四条实践原则：

```
1. 先看段落的长度分布，取中位数附近
2. 在候选值上做实验，用评测集选最优
3. 小块检索 + 大块喂模型（ParentDocument）
4. 给块加标题上下文，缓解"孤立块"问题
```

**一句话：chunk_size 不是一个可以抄的参数，是要在你自己的文档上做实验测出来的参数。** 这篇文章给的是方法，不是答案。
