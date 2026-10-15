# BM25：为什么向量检索之外还要有关键词检索

> 用户问："ERR_0x80070057 怎么解决？"
> 向量检索返回了三篇"常见错误处理"的通用文档——
> **因为"ERR_0x80070057"这个字符串对 embedding 模型来说毫无意义。**
>
> BM25 能精确匹配到它。

## 一、向量检索的三个盲区

**① 精确字符串**

```
查询："ERR_0x80070057"
embedding：这串字符会被切碎，"ERR"和"0x80070057"没有语义
结果：召回的语义相近内容，但漏掉精确的那篇
```

**② 数字和编号**

```
查询："订单 SO2026010001"
embedding：数字的含义很弱
BM25：精确匹配
```

**③ 低频专有名词**

```
查询："王艺蒙老师布置的作业"
embedding：模型可能没见过这个名字
BM25：只要文档里有"王艺蒙"，就能匹配
```

**BM25 补的正是这三个盲区。**

## 二、BM25 是什么

**BM25（Best Matching 25）是一个基于词频的排序函数**：

```
score(q, d) = Σ IDF(t) × (tf(t,d) × (k1+1)) / (tf(t,d) + k1 × (1 - b + b × |d|/avgdl))
```

**拆开看三个部分**：

| 部分 | 作用 |
|---|---|
| **IDF(t)** | 词越稀有，权重越高（"的"权重几乎为 0，"退款"权重高） |
| **tf 饱和** | 词频增加，得分增加但会饱和（出现 100 次不比 10 次强多少） |
| **长度归一化** | 长文档不会因为"词多"而占优 |

**这正是向量检索缺的能力**——**它对"精确的词"敏感，对"语义的像"不敏感**。

## 三、用法（Python）

```python
from rank_bm25 import BM25Okapi

# 1. 语料要分词（中文必须！）
import jieba

corpus_tokens = [
    list(jieba.cut(doc.page_content))
    for doc in chunks
]

# 2. 建索引
bm25 = BM25Okapi(corpus_tokens, k1=1.5, b=0.75)

# 3. 查询
query_tokens = list(jieba.cut("退款需要多久到账"))
scores = bm25.get_scores(query_tokens)

# 4. 取 top-k
top_idx = np.argsort(-scores)[:5]
for i in top_idx:
    print(f"{scores[i]:.3f} | {chunks[i].page_content[:80]}")
```

**三个关键点**：

**① 中文必须分词。**
不分词的话，BM25 会把整句话当一个"词"——**完全失效**。

**② 查询和语料要用同一套分词。**
用 `jieba` 就都用 `jieba`。

**③ BM25 索引要在内存里。**
`BM25Okapi` 持有全部分词结果。**100 万条文档会占用几个 GB**。

## 四、BM25 的两个参数

```python
bm25 = BM25Okapi(corpus, k1=1.5, b=0.75)
```

**`k1`：词频饱和参数**

```
小（1.0）：出现 1 次和 10 次差别明显
大（2.0）：词频影响更大
默认 1.5：平衡
```

**`b`：长度归一化强度**

```
b = 0   → 不归一化（长文档占优）
b = 1   → 完全归一化（短文档占优）
b = 0.75 → 默认
```

**调参建议**：

| 场景 | k1 | b |
|---|---|---|
| 短文档（< 300 字） | 1.2 | 0.5 |
| 中等长度 | 1.5 | 0.75 |
| 长文档（> 2000 字） | 1.5 | 0.4 |
| 文档长度差异大 | 1.5 | 0.3~0.5 |

**`b` 是对效果影响最大的参数**——文档长度差异大时，要调小。

## 五、中文分词的坑

**jieba 的几种模式**：

```python
import jieba

text = "退款申请需要满足以下条件"

# 精确模式（默认）
print(list(jieba.cut(text)))
# ['退款', '申请', '需要', '满足', '以下', '条件']

# 全模式（更多切分，召回高但噪声多）
print(list(jieba.cut(text, cut_all=True)))

# 搜索引擎模式（长词再切）
print(list(jieba.cut_for_search(text)))
# ['退款', '申请', '需要', '满足', '以下', '条件']
```

**推荐用"搜索引擎模式"**——它会把长词切出更细的子词，提升召回。

**自定义词典（关键）**：

```python
# 加载领域词典
jieba.load_userdict("domain_dict.txt")

# 或者动态添加
jieba.add_word("蜂巢架构")
jieba.add_word("蓝标客户")
```

**`domain_dict.txt` 格式**：

```
蜂巢架构 100 n
蓝标客户 100 n
三号项目 100 n
```

**没加自定义词典时，领域术语会被切碎**：

```
"蜂巢架构" → ["蜂巢", "架构"]  ❌
"蓝标客户" → ["蓝标", "客户"]  ❌
```

**切碎后 BM25 的匹配精度大幅下降。**

**分词器对比**：

| 分词器 | 特点 |
|---|---|
| jieba | 通用，速度快，生态好 |
| pkuseg | 精度略高，速度慢 |
| HanLP | 功能全，依赖重 |
| 官方 ES/ES 的 IK | 需要 ES 环境 |

**通用场景 jieba 够用。** 领域强的话，加词典比换分词器有效。

## 六、BM25 在 LangChain 里

```python
from langchain_community.retrievers import BM25Retriever
from langchain_core.documents import Document

retriever = BM25Retriever.from_documents(
    chunks,
    preprocess_func=lambda t: list(jieba.cut_for_search(t)),    # 中文要指定
    k=10,
)

docs = retriever.invoke("退款需要多久到账")
```

**`preprocess_func` 是关键**——默认是英文的 `\w+` 分词，**对中文完全无效**。

**保存和加载**：

```python
retriever.save_local("./bm25_index")
retriever = BM25Retriever.load_local("./bm25_index")
```

**`save_local` 只存文档，不存索引**——加载时会重建。**大语料下这个重建过程很慢**（几百万文档要几分钟）。

**真要持久化 BM25，用 Whoosh 或 Tantivy**：

```python
from langchain_community.retrievers import BM25Retriever
# 或者用 Tantivy（Rust 实现，支持持久化）
import tantivy

schema_builder = tantivy.SchemaBuilder()
schema_builder.add_text_field("content", stored=True, tokenizer_name="jieba")
...
```

## 七、BM25 vs 向量：什么时候谁更强

| 查询类型 | BM25 | 向量 | 建议 |
|---|---|---|---|
| 自然语言问句 | 弱 | 强 | 向量为主 |
| 精确错误码 | **强** | 弱 | 关键词为主 |
| 专有名词 | 强 | 中 | 混合 |
| 同义改写 | 弱 | **强** | 向量 |
| 短关键词（1~2 个词） | **强** | 中 | 混合 |
| 长段落查询 | 弱 | 强 | 向量 |
| 数字/编号 | **强** | 弱 | 关键词 |

**"有没有精确标识符"是最实用的判断依据。**

## 八、混合检索的标准做法

```python
from langchain.retrievers import EnsembleRetriever

# BM25 路
bm25 = BM25Retriever.from_documents(
    chunks,
    preprocess_func=lambda t: list(jieba.cut_for_search(t)),
    k=10,
)

# 向量路
vector = vectorstore.as_retriever(search_kwargs={"k": 10})

# 融合
hybrid = EnsembleRetriever(
    retrievers=[vector, bm25],
    weights=[0.7, 0.3],
)

docs = hybrid.invoke("ERR_0x80070057 怎么解决")
```

**收益（实测）**：

| 方案 | recall@5 |
|---|---|
| 纯向量 | 0.72 |
| 纯 BM25 | 0.58 |
| **混合 0.7:0.3** | **0.86** |

**混合比最好的单路还高 14 个百分点。**

## 九、BM25 的局限

**① 无法处理同义词**

```
查询："怎么退钱"
文档："退款流程"
BM25：没有共同词 → 得分 0 ❌
```

**② 无法处理语序**

```
"猫追狗" 和 "狗追猫"
BM25：词频相同 → 得分相同 ❌
```

**③ 依赖分词质量**

分词错了，一切都错了。

**④ 无法理解上下文**

```
"苹果" 是水果还是公司？
BM25：不知道
```

**这就是为什么它只能"补位"，不能"主攻"。**

## 十、进阶：BM25 的变体

**BM25+**：改进低频词的处理

```python
# 在 TF 上加一个下限，避免长文档中词频被过度惩罚
score = Σ IDF × (tf × (k1+1) / (tf + k1×(1-b+b×|d|/avgdl)) + δ)
```

**BM25F**：字段级加权

```python
# 标题里的词权重更高
score = w_title × tf_title + w_body × tf_body
```

**实践中的简化版**：

```python
def field_weighted_bm25(query, doc):
    """标题命中额外加分"""
    score = bm25_score(query, doc.page_content)
    if any(t in doc.metadata.get("title", "") for t in jieba.cut(query)):
        score *= 1.5
    return score
```

**这个简单的加权在"标题即摘要"的文档上很有效。**

## 十一、几个坑

**① 中文没分词。**
最高频的错误。**必须通过 `preprocess_func` 指定中文分词。**

**② 查询和语料分词方式不一致。**

```python
# ❌ 语料用 cut_for_search，查询用 cut
corpus = [list(jieba.cut(d)) for d in docs]
query = list(jieba.cut_for_search(q))
```

**必须一致。**

**③ 停用词没处理。**
"的"、"了"、"是" 这些词在所有文档里都高频，**IDF 很低所以影响小**，但**分词后如果把它们混进查询，会引入噪声**。

```python
STOPWORDS = {"的", "了", "是", "在", "和", "就", "都", "而", "及", "与"}

def tokenize(text: str) -> list[str]:
    return [t for t in jieba.cut_for_search(text)
            if t.strip() and t not in STOPWORDS]
```

**④ BM25 分数不能跨查询比较。**

```
查询 A 的最高分：25.3
查询 B 的最高分：8.7
```

**这不代表 A 的结果比 B 更相关**——BM25 分数受查询词数、IDF 分布影响。**别用固定阈值过滤 BM25 结果。**

**⑤ 增量更新的代价。**
BM25 索引是全量的，**新增文档要重建**。

**变通方案**：**维护一个"增量段"**：

```python
class IncrementalBM25:
    def __init__(self, base_chunks):
        self.base_bm25 = BM25Okapi([tokenize(c.page_content) for c in base_chunks])
        self.base_chunks = base_chunks
        self.delta_chunks = []
        self.delta_bm25 = None

    def add(self, new_chunks):
        self.delta_chunks.extend(new_chunks)
        self.delta_bm25 = BM25Okapi([tokenize(c.page_content) for c in self.delta_chunks])

    def search(self, query, k=10):
        base_scores = self.base_bm25.get_scores(tokenize(query))
        results = [(self.base_chunks[i], base_scores[i])
                   for i in np.argsort(-base_scores)[:k]]

        if self.delta_bm25:
            delta_scores = self.delta_bm25.get_scores(tokenize(query))
            results += [(self.delta_chunks[i], delta_scores[i])
                        for i in np.argsort(-delta_scores)[:k]]

        return sorted(results, key=lambda x: -x[1])[:k]
```

## 十二、小结

```python
# 标准用法
import jieba
from rank_bm25 import BM25Okapi

corpus = [list(jieba.cut_for_search(c.page_content)) for c in chunks]
bm25 = BM25Okapi(corpus, k1=1.5, b=0.75)

scores = bm25.get_scores(list(jieba.cut_for_search(query)))
```

五条原则：

```
1. 中文必须分词（用 cut_for_search + 自定义词典）
2. 查询和语料分词方式必须一致
3. b 参数（长度归一化）对效果影响最大
4. 和向量混合用（0.7:0.3），别单独用
5. BM25 分数不能跨查询比较
```

**一句话：BM25 是"精确匹配"的守卫者，向量是"语义理解"的探索者。** 单独用 BM25 会漏掉所有同义改写，单独用向量会漏掉所有精确字符串——**两者的互补性，就是混合检索能提升 10+ 个百分点的根本原因**。
