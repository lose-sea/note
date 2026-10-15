# 交叉编码器重排：为什么它比向量检索准得多

> 向量检索把查询和文档**分别**编码成向量，然后算距离。
> 这个"分别"就是它的根本限制——
> **查询和文档从来没有"见过面"。**

## 一、双塔 vs 交叉：本质区别

**双塔（Bi-Encoder，向量检索）**：

```
查询 ──→ [编码器] ──→ 向量A ┐
                            ├──→ 算余弦相似度
文档 ──→ [编码器] ──→ 向量B ┘
```

**查询和文档各自独立编码，没有任何交互。**

**交叉编码器（Cross-Encoder）**：

```
查询 + 文档 ──→ [编码器] ──→ 相关性分数
"退款要多久？" + "退款流程：7个工作日到账" → 0.94
```

**查询和文档拼接后一起送入模型**——**模型能看到每个词之间的交互**。

## 二、为什么"交互"这么重要

**例子**：

```
查询："退款要多久到账"
文档 A："退款流程说明：提交申请后 7 个工作日内到账"
文档 B："账户余额查询指南：登录后点击我的账户"
```

**双塔**：

```
编码 A 时，模型不知道查询是什么
→ A 的向量是"关于退款流程的通用表示"
→ 匹配程度取决于"通用表示"和"查询表示"的相似度
→ 可能 0.81
```

**交叉编码器**：

```
模型同时看到"退款要多久到账"和文档 A
→ 能直接判断"文档 A 里的 7 个工作日回答了'多久'"
→ 分数 0.94

对文档 B：
→ 模型看到"账户余额"和"退款"
→ 判断不相关
→ 分数 0.12
```

**关键差别**：交叉编码器能做**细粒度的语义对齐**——"多久"对应"7 个工作日"。

**双塔做不到这一点**，因为它在编码阶段就"不知道对方是谁"。

## 三、代价：速度

**交叉编码器的准确性换来的是"慢"**：

| | 双塔 | 交叉编码器 |
|---|---|---|
| 查询编码 | 1 次 | 0 次 |
| 文档编码 | **预先算好（离线）** | **每次查询都要算** |
| 单文档打分 | 一次向量运算（微秒） | 一次模型推理（10~50ms） |
| 100 个候选 | 约 1ms | 1~5 秒 ❌ |

**所以交叉编码器不能用来"检索"，只能用来"重排"。**

```
① 双塔：从 100 万文档里快速召回 100 个候选（毫秒级）
② 交叉编码器：对这 100 个精确打分，取 top 5（秒级）
```

**这就是"两阶段检索"**——**用双塔的广度 + 交叉编码器的精度**。

## 四、效果对比（实测数据）

| 阶段 | recall@5 | 说明 |
|---|---|---|
| 纯向量检索 | 0.72 | 基线 |
| 向量 + BM25 混合 | 0.86 | +14pt |
| **混合 + 交叉编码器重排** | **0.93** | **+7pt** |

**重排的增益很明显**，且**和混合检索的增益是叠加的**。

**更关键的是"精度"的提升**：

| 方案 | 前 3 个结果的精确率 |
|---|---|
| 纯向量 | 0.58 |
| 混合 | 0.71 |
| 混合 + 重排 | **0.89** |

**前几个结果的质量直接决定 RAG 的效果**——因为最终给模型的往往就是前 3~5 个。

## 五、常用重排模型

| 模型 | 语言 | 大小 | 特点 |
|---|---|---|---|
| `BAAI/bge-reranker-base` | 中英 | 278M | 平衡 |
| `BAAI/bge-reranker-large` | 中英 | 560M | 更准，更慢 |
| `BAAI/bge-reranker-v2-m3` | **多语言** | 568M | 多语言场景 |
| `jina-reranker-v2` | 多语言 | 278M | 效果好 |
| `ms-marco-MiniLM-L-6-v2` | 英文 | 22M | 极快，英文专用 |
| Cohere Rerank | 多语言 | API | 免部署，按量付费 |

**中文场景推荐 `bge-reranker-base` 起步**，效果不够再上 `large`。

## 六、LangChain 里的用法

```python
from langchain.retrievers import ContextualCompressionRetriever
from langchain.retrievers.document_compressors import CrossEncoderReranker
from langchain_community.cross_encoders import HuggingFaceCrossEncoder

# 1. 加载重排模型
cross_encoder = HuggingFaceCrossEncoder(
    model_name="BAAI/bge-reranker-base",
    model_kwargs={"device": "cuda"},          # 有 GPU 就用
)

# 2. 包装成压缩器
reranker = CrossEncoderReranker(
    model=cross_encoder,
    top_n=4,                                   # 重排后保留几个
)

# 3. 包住基础检索器
retriever = ContextualCompressionRetriever(
    base_compressor=reranker,
    base_retriever=hybrid_retriever,           # 向量 + BM25
)

docs = retriever.invoke("退款要多久到账")
```

**`top_n` 是最终给模型的文档数**——`base_retriever` 召回 20 个，重排后留 4 个。

## 七、批处理：性能的关键

**逐条打分很慢，要批处理**：

```python
def rerank_batch(query: str, docs: list, model, batch_size: int = 32):
    """批量打分"""
    pairs = [(query, d.page_content) for d in docs]

    scores = model.predict(
        pairs,
        batch_size=batch_size,
        show_progress_bar=False,
    )

    ranked = sorted(zip(docs, scores), key=lambda x: -x[1])
    return ranked
```

**batch_size 的影响**：

| batch_size | 20 个文档的耗时（CPU） |
|---|---|
| 1 | 约 2.0 s |
| 8 | 约 0.6 s |
| 32 | 约 0.4 s |
| 64 | 约 0.4 s |

**32 是常见的甜蜜点**——再大收益很小，且占内存。

**GPU 能把时间压到 50ms 以内**——**重排是"用 GPU 换质量"的典型场景**。

## 八、截断：文档太长怎么办

**交叉编码器有输入长度限制**（通常 512 token）。

```python
def truncate_for_rerank(text: str, max_chars: int = 500) -> str:
    """重排时只取文档开头"""
    return text[:max_chars]
```

**为什么"只取开头"通常够用？**

```
① 文档开头通常是"主题句"
② 关键信息往往在前几句
③ 全量输入会超长并被截断（结果一样，但慢）
```

**但要注意**：如果关键信息在文档末尾，截断会漏掉。**这种情况下要用"重排模型的 max_length 参数"让它自己处理**：

```python
HuggingFaceCrossEncoder(
    model_name="BAAI/bge-reranker-base",
    model_kwargs={"max_length": 512},         # 模型自己截断
)
```

## 九、成本与延迟的权衡

**重排不是免费的**：

| 项 | 成本 |
|---|---|
| GPU 显存 | 1~2 GB（base 模型） |
| 单次延迟 | 50~400ms（取决于候选数和 batch） |
| 运维 | 要维护一个推理服务 |

**什么时候值得加**：

```
✅ 检索精度对业务影响大（法律、医疗、客服）
✅ 候选数在 20~100 之间（太小没意义，太大太慢）
✅ 有 GPU 或能接受 200~500ms 的额外延迟
❌ 候选数只有 5 个（重排收益小）
❌ 延迟要求 < 100ms
❌ 没有 GPU 且候选数 > 50（CPU 上会变成瓶颈）
```

## 十、几个优化技巧

**① 用"分数差"做早停**

```python
def rerank_with_early_stop(query, docs, model, top_n=4, margin=0.3):
    scores = model.predict([(query, d.page_content) for d in docs])
    ranked = sorted(zip(docs, scores), key=lambda x: -x[1])

    # 如果第 1 名远高于第 2 名，可以直接返回
    if len(ranked) > 1 and ranked[0][1] - ranked[1][1] > margin:
        return ranked[:2]

    return ranked[:top_n]
```

**② 只重排"边界候选"**

如果初筛的分数分布有明显的"高分区"和"低分区"，可以只重排中间部分：

```python
def selective_rerank(query, docs_with_scores, model, top_n=4):
    high = [d for d, s in docs_with_scores if s > 0.85]     # 确信相关，直接保留
    mid = [d for d, s in docs_with_scores if 0.5 < s <= 0.85]  # 不确定区，重排
    low = [d for d, s in docs_with_scores if s <= 0.5]      # 确信不相关，丢弃

    reranked = rerank_batch(query, mid, model)
    return (high + [d for d, _ in reranked])[:top_n]
```

**这个优化能省 50%+ 的重排计算。**

**③ 缓存重排结果**

```python
@lru_cache(maxsize=1000)
def cached_rerank(query: str, doc_id: str) -> float:
    return float(model.predict([(query, doc_text(doc_id))])[0])
```

**同一查询多次检索时（多轮对话），能复用重排分数。**

## 十一、几个坑

**① 忘了设置 top_n。**
默认可能返回全部候选，**失去了重排的意义**。

**② 候选数太多，延迟炸了。**

```
初筛 200 个 → CPU 上重排要 4 秒 ❌
初筛 20 个 → 200ms ✅
```

**初筛的 k 控制在 20~50。**

**③ 重排模型和 embedding 模型的语言不匹配。**
用英文重排模型处理中文文档，效果会打折。**中文用 `bge-reranker-*`。**

**④ 用错了分数方向。**

```python
# 大多数 reranker 返回"相关性分数"，越大越相关
ranked = sorted(zip(docs, scores), key=lambda x: -x[1])     # ✅ 降序
```

**有些模型返回的是"距离"**——看文档确认。

**⑤ 没做归一化，和初筛分数混用。**
重排分数和向量分数**不是一个尺度**，**不能直接相加或比较**。

**⑥ 忘了处理"候选为空"。**

```python
if not docs:
    return []          # 别让重排模型收到空列表
```

## 十二、小结

```python
# 两阶段检索的标准配置
candidates = hybrid_retriever.invoke(query)[:30]           # 阶段 1：召 30 个
reranked = reranker.compress_documents(candidates, query)  # 阶段 2：重排
final = reranked[:4]                                        # 取 top 4
```

五条原则：

```
1. 重排是"两阶段"的第二阶段，不能用来检索
2. 初筛 k 在 20~50（太小没意义，太大太慢）
3. 必须批处理（batch_size=32）
4. 中文用 bge-reranker-*
5. 有 GPU 才用 large 模型，CPU 用 base
```

**一句话：交叉编码器把"检索质量"从"够用"提升到"精准"，代价是几十到几百毫秒的延迟。** 在 RAG 里，**这是投入产出比最高的一步优化**——因为最终给模型的就是那 3~5 篇，**它们的质量决定了答案的上限**。
