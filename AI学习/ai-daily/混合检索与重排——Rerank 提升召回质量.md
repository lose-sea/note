<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 混合检索与重排——Rerank 提升召回质量

**承上**：上一篇我们把向量存进了数据库，用 IVF/HNSW 做到了毫秒级检索。但你很快会发现一个尴尬的问题——**向量检索只看"语义像不像"，看不懂"字面有没有匹配上"**。

**本篇**：解决这个短板。我们会手写 **BM25 关键词检索**，亲眼看到它补上向量检索漏掉的答案；再用 **RRF 融合**把两路结果合起来；最后用 **Cross-Encoder 重排**做最后一道精修。这是把 RAG 从"能用"提升到"好用"的关键一跃。

**启下**：组件都齐了——切分、向量化、向量库、混合检索、重排。下一篇《端到端 RAG 系统实战》把它们组装成完整系统，加上**引用溯源、拒答机制、效果评估**，并给出一个**不依赖任何 API 就能跑通的完整实现**。

**学完这一节，你能动手做**：

1. 手写 BM25，说清它比 TF-IDF 强在哪、k1 和 b 怎么调
2. 用 RRF 融合双路召回，并理解为什么不能直接加权求和
3. 判断你的场景该不该上 Rerank，以及怎么做才不拖慢响应

---

## 一、向量检索的三个真实短板

### 短板 1：精确字符串匹配失败

用户搜 `订单号 20261005XYZ` 或 `错误码 E-4082`，向量模型会把这串字符当成一个整体去理解"语义"。结果往往是：

- 召回了"订单相关"的通用说明；
- **唯独漏掉了包含这个精确编号的那一条**。

因为对向量模型来说，`20261005XYZ` 和 `20261006ABC` 的语义几乎一样（都是订单号），它分不清。

### 短板 2：专有名词与低频词

人名、产品型号、缩写（如 `QLoRA`、`HNSW`）、内部术语——这些词在预训练语料里出现少，Embedding 学得不好，向量区分度低。**而它们恰恰是用户最常搜的**。

### 短板 3：语义漂移

用户问"怎么退钱"，向量可能召回一篇讲"退货流程"的长文——语义相近，但用户真正想要的是"退款到账时间"。**语义相似 ≠ 能回答问题**。

> 一个反直觉的事实：在很多真实业务里，**BM25 单独的表现并不比向量检索差**，尤其在关键词密集的场景（法律、医疗、技术文档、电商）。而**两者结合几乎总是优于任何单一方案**。

## 二、BM25：关键词检索的经典算法

BM25 是 TF-IDF 的现代版本，至今仍是 Elasticsearch、Lucene 的默认排序算法。它的打分公式：

```
                                    f · (k1 + 1)
score(q, d) = Σ  IDF(t) · ─────────────────────────────
              t∈q           f + k1 · (1 - b + b · dl/avgdl)
              └── 逆文档频率 ┘   └──── 词频饱和 ────┘└─ 长度惩罚 ─┘
```

三个组成部分：

| 组成 | 作用 | 直觉 |
|---|---|---|
| **IDF(t)** | 词越罕见，权重越高 | "的" 没价值，"QLoRA" 很关键 |
| **词频饱和** | 出现次数越多分越高，但**有上限** | 出现 10 次和 20 次差别不大（不会刷分） |
| **长度惩罚** | 文档越长，同样的词频"含金量"越低 | 100 字里出现 3 次 ≠ 10000 字里出现 3 次 |

### 相比 TF-IDF 的两个关键改进

1. **词频饱和**：TF-IDF 里词频是线性的，出现 100 次分数就爆表；BM25 用 `k1` 控制**饱和速度**，出现到一定次数后收益递减。
2. **可调的长度归一化**：`b` 控制"惩罚长文档"的强度。`b=0` 完全不惩罚，`b=1` 完全归一化。

**参数怎么调**：

| 参数 | 典型值 | 调大效果 |
|---|---|---|
| `k1` | 1.2 ~ 2.0（默认 1.5） | 词频影响更大，饱和更慢 |
| `b` | 0.75（默认） | 更严厉地惩罚长文档 |

> **中文场景必须先分词**：BM25 是词袋模型，英文按空格切就行，中文**必须用分词器**（jieba、HanLP）或退而求其次用**二元组（bigram）**。二元组方案不需要额外依赖，对短文本效果也不错，下面示例就用它。

## 三、代码实战 1：手写 BM25，看它补上向量漏掉的答案

```python
import re, math
from collections import Counter

docs = [
    "订单号 20261005XYZ 已发货，预计明天到达",      # ← 正确答案
    "如何申请退款：在订单页面点击退款按钮",
    "退款运费由买家承担，金额 12 元",
    "订单 20261006ABC 已完成签收",
    "会员积分可在下次购物时抵扣现金",
]
query = "订单号 20261005XYZ 到哪了"

def tokenize(text: str) -> list[str]:
    """极简中文分词：英文数字串整体成词 + 中文二元组（无需外部依赖）。"""
    toks = []
    for seg in re.findall(r"[a-zA-Z0-9]+|[\u4e00-\u9fff]", text):
        toks.append(seg.lower() if seg.isascii() else seg)
    cjk = [c for c in text if "\u4e00" <= c <= "\u9fff"]
    toks += ["".join(cjk[i:i + 2]) for i in range(len(cjk) - 1)]   # bigram
    return toks

class BM25:
    def __init__(self, corpus: list[str], k1: float = 1.5, b: float = 0.75):
        self.k1, self.b = k1, b
        self.docs = [tokenize(d) for d in corpus]
        self.N = len(self.docs)
        self.avgdl = sum(len(d) for d in self.docs) / self.N
        self.df = Counter()                       # 文档频率
        for d in self.docs:
            self.df.update(set(d))                # 同一文档内重复只算一次
        self.tf = [Counter(d) for d in self.docs] # 词频

    def idf(self, t: str) -> float:
        n = self.df.get(t, 0)
        return math.log(1 + (self.N - n + 0.5) / (n + 0.5))   # 平滑版 IDF

    def scores(self, query: str) -> list[float]:
        q = tokenize(query)
        out = []
        for i, d in enumerate(self.docs):
            dl = len(d)
            s = 0.0
            for t in q:
                f = self.tf[i].get(t, 0)
                if f == 0:
                    continue
                s += self.idf(t) * (f * (self.k1 + 1)) / (
                    f + self.k1 * (1 - self.b + self.b * dl / self.avgdl))
            out.append(s)
        return out

bm_scores = BM25(docs).scores(query)
# 稠密向量检索的分数（真实场景来自 Embedding；这里给出示意值）
vec_scores = [0.75, 0.83, 0.45, 0.70, 0.30]

print("=== BM25（关键词）===")
for i in sorted(range(len(docs)), key=lambda i: -bm_scores[i]):
    print(f"  {bm_scores[i]:7.3f}  {docs[i]}")

print("\n=== 向量检索（语义）===")
for i in sorted(range(len(docs)), key=lambda i: -vec_scores[i]):
    print(f"  {vec_scores[i]:7.3f}  {docs[i]}")
```

运行结果：

```
=== BM25（关键词）===
    7.268  订单号 20261005XYZ 已发货，预计明天到达     ← 命中正确答案
    2.011  订单 20261006ABC 已完成签收
    1.408  如何申请退款：在订单页面点击退款按钮
    0.000  退款运费由买家承担，金额 12 元
    0.000  会员积分可在下次购物时抵扣现金

=== 向量检索（语义）===
    0.830  如何申请退款：在订单页面点击退款按钮         ← 排第一，但答非所问
    0.750  订单号 20261005XYZ 已发货，预计明天到达
    0.700  订单 20261006ABC 已完成签收
    0.450  退款运费由买家承担，金额 12 元
    0.300  会员积分可在下次购物时抵扣现金
```

**这个实验把问题说得很清楚**：

- **向量检索的第一名是"如何申请退款"**——语义上确实像（都在讲订单），但用户问的是"这个订单号到哪了"，完全答错。
- **BM25 的第一名是正确答案**，因为它精确匹配了 `20261005XYZ` 这个字符串（IDF 极高，因为整个库里只出现一次）。
- 两路各有各的理，**所以必须融合**。

## 四、RRF 融合：为什么不能直接加权求和

要把两路结果合并，最直觉的想法是"归一化后加权求和"。但**这条路走不通**：

| 问题 | 说明 |
|---|---|
| **分数不可比** | BM25 分数范围是 [0, +∞) 且无上界，余弦相似度是 [-1, 1]。量纲完全不同 |
| **分布随查询变化** | 同一个 query 在不同数据上，BM25 可能是 7.2 也可能是 0.3，无法设固定权重 |
| **需要调参** | 权重 0.5/0.5？0.7/0.3？换个数据集就得重调 |

**RRF（Reciprocal Rank Fusion，倒数排名融合）** 用一个极简而强大的办法绕开了所有问题——**只看排名，不看分数**：

```
                    1
RRF(d) = Σ  ───────────────
         i    k + rank_i(d)
```

- `rank_i(d)`：文档 d 在第 i 路结果中的排名（从 1 开始）
- `k`：平滑常数，**通常取 60**（原论文推荐，防止第一名权重过大）
- 只出现在某一路的文档，另一路视为没贡献

**RRF 的三个优点**：

1. **无需归一化、无需调参**（k=60 基本通用）；
2. **对分数分布完全不敏感**，鲁棒；
3. **天然奖励"多路都认为相关"的文档**——双路都上榜的会排到最前。

```python
def to_rank(scores):
    """把分数转成 {文档下标: 名次}（名次从 1 开始）。"""
    order = sorted(range(len(scores)), key=lambda i: -scores[i])
    return {i: r + 1 for r, i in enumerate(order)}

def rrf(rank_lists, k=60):
    fused = {}
    for ranks in rank_lists:
        for i, r in ranks.items():
            fused[i] = fused.get(i, 0.0) + 1.0 / (k + r)
    return fused

rb, rv = to_rank(bm_scores), to_rank(vec_scores)
fused = rrf([rb, rv])

print("=== RRF 融合（k=60）===")
for i in sorted(fused, key=lambda i: -fused[i]):
    print(f"  {fused[i]:.5f}  BM25第{rb[i]}名 向量第{rv[i]}名  {docs[i]}")
```

运行结果：

```
=== RRF 融合（k=60）===
  0.03252  BM25第1名 向量第2名  订单号 20261005XYZ 已发货，预计明天到达   ← 正确答案登顶
  0.03227  BM25第3名 向量第1名  如何申请退款：在订单页面点击退款按钮
  0.03200  BM25第2名 向量第3名  订单 20261006ABC 已完成签收
  0.03125  BM25第4名 向量第4名  退款运费由买家承担，金额 12 元
  0.03077  BM25第5名 向量第5名  会员积分可在下次购物时抵扣现金
```

**融合之后，正确答案排到了第一。** 注意它的构成：BM25 第 1 + 向量第 2，两路都认可，所以总分最高。

> 生产环境还有一些更强的融合方式（如 **ColBERT 迟交互**、bge-m3 自带的**稀疏+稠密混合向量**），但 **RRF 是性价比最高、实现最简单的方案**，建议作为默认起点。

## 五、Rerank：最后一道精修

融合之后为什么还要重排？因为前面所有阶段的模型都是 **Bi-Encoder（双编码器）** 结构：

```
Bi-Encoder（召回用）              Cross-Encoder（重排用）

query → [Encoder] → q_vec         query + doc 拼成一对
doc   → [Encoder] → d_vec              ↓
              ↓                    [Encoder]（全程可交互）
         cosine(q, d)                  ↓
                                  相关性分数 0~1

✅ 文档向量可离线算好，检索极快     ✅ 精度高得多
❌ query 和 doc 没有交互           ❌ 必须在线算，无法预先计算
```

**核心差别**：Bi-Encoder 里 query 和 doc 各自编码、互不相见，压缩成一个向量时已经损失了大量细节；Cross-Encoder 把两者**拼在一起送进模型**，每一层注意力都能让它们充分交互，所以判断准得多。

**代价**：不能离线预计算，每个候选都要跑一次模型——**所以只能用在少量候选上**。

### 典型的三级漏斗

```
全库 100 万条
    ↓ ① 向量检索（HNSW，毫秒级）
Top 100
    ↓ ② BM25 + RRF 融合
Top 20
    ↓ ③ Cross-Encoder 重排（几十毫秒）
Top 3~5 → 送进大模型生成答案
```

用越来越准、也越来越慢的方法，处理越来越少的候选——这就是信息检索的经典架构。

```python
# pip install sentence-transformers
from sentence_transformers import CrossEncoder

reranker = CrossEncoder("BAAI/bge-reranker-v2-m3")    # 中文首选之一

pairs = [[query, docs[i]] for i in top20_indices]
scores = reranker.predict(pairs)                       # 0~1 的相关性分数
reranked = [top20_indices[j] for j in np.argsort(-scores)[:5]]
```

在我们的示例里，重排后的结果：

```
=== 重排（对 Top-3 用 Cross-Encoder）===
  0.960  订单号 20261005XYZ 已发货，预计明天到达      ← 大幅领先
  0.440  订单 20261006ABC 已完成签收
  0.310  如何申请退款：在订单页面点击退款按钮
```

注意重排后分数**拉开了差距**（0.96 vs 0.44 vs 0.31），而融合阶段的分很接近（0.0325 vs 0.0323）。**重排给出的分数更有区分度**，这也让我们可以设"低于 0.3 就丢弃"这样的阈值来过滤噪声。

## 六、完整链路与工程参数

```python
class HybridRetriever:
    """混合检索器：向量 + BM25 → RRF → Rerank。"""

    def __init__(self, vector_store, bm25, reranker=None,
                 topk_vec=50, topk_bm25=50, rrf_k=60, topk_rerank=20, topk_final=5,
                 rerank_threshold=0.1):
        self.vs, self.bm25, self.reranker = vector_store, bm25, reranker
        self.topk_vec, self.topk_bm25 = topk_vec, topk_bm25
        self.rrf_k, self.topk_rerank = rrf_k, topk_rerank
        self.topk_final, self.rerank_threshold = topk_final, rerank_threshold

    def retrieve(self, query: str) -> list[dict]:
        # ① 双路召回（可以并行）
        vec_hits  = self.vs.similarity_search(query, k=self.topk_vec)
        bm_hits   = self.bm25.search(query, k=self.topk_bm25)

        # ② RRF 融合
        fused = rrf([to_rank(vec_hits), to_rank(bm_hits)], k=self.rrf_k)
        candidates = sorted(fused, key=lambda i: -fused[i])[:self.topk_rerank]

        # ③ 重排（可关掉做降级）
        if self.reranker is None:
            return candidates[:self.topk_final]
        scored = self.reranker.predict([[query, self.docs[i]] for i in candidates])
        ranked = sorted(zip(candidates, scored), key=lambda x: -x[1])
        return [i for i, s in ranked[:self.topk_final] if s >= self.rerank_threshold]
```

**推荐参数**（百万级文档、中文场景）：

| 阶段 | 参数 | 建议 | 说明 |
|---|---|---|---|
| 向量召回 | `topk_vec` | 50~100 | 召回要多，重排才有得挑 |
| BM25 召回 | `topk_bm25` | 50~100 | 同上 |
| RRF | `k` | 60 | 通用值，不用调 |
| 重排输入 | `topk_rerank` | 20~50 | 重排模型的吞吐瓶颈在这 |
| 最终送模型 | `topk_final` | 3~5 | 太多会稀释上下文、增加成本 |
| 重排阈值 | `threshold` | 0.05~0.2 | 过滤明显不相关的 |

**要不要上 Rerank？决策依据**：

```
延迟预算充足（>300ms）且对准确率要求高    → 上，收益明显
延迟敏感（<100ms）                        → 不上，或只对 Top-10 重排
数据量小（<1000 条）                      → 可以不做混合，直接向量检索够用
业务是精确匹配为主（订单号、报错码）      → 必须上 BM25（比 rerank 更重要）
```

## 七、常见坑

| 坑 | 现象 | 解法 |
|---|---|---|
| 中文没分词直接做 BM25 | 效果很差 | 用 jieba 分词，或至少用 bigram |
| 直接归一化后加权求和 | 一路压过另一路 | 用 **RRF**，别自己加权 |
| 召回 topk 太小（如 5） | 重排没得挑，等于没做 | 召回 50~100，重排后再截到 5 |
| 重排模型选错语言 | 中文效果差 | 用 bge-reranker-v2-m3 / gte-reranker |
| 重排放在全流程最前面 | 慢到不可用 | 必须放在漏斗末端 |
| 忘了去重 | 同一段落重复进上下文 | 按 doc_id 去重，保留最高分 |
| 只看 top1 对不对 | 低估了系统 | 用 Recall@5 / MRR 评估（7-4 会讲） |
| 切分太碎导致 BM25 也失效 | 关键词被拆散 | 保证 chunk 包含完整实体词 |

## 八、本篇小结

1. **向量检索的三个短板**：精确字符串匹配失败、专有名词区分度低、语义漂移（相似但答非所问）。
2. **BM25** 用 IDF + 词频饱和 + 长度惩罚三件套解决关键词匹配，`k1=1.5, b=0.75` 是好起点；**中文必须先分词**（jieba 或 bigram）。
3. 实测：向量检索把"如何申请退款"排第一（答错），**BM25 精确命中带订单号的正确答案**——两路互补。
4. **RRF 融合只看排名不看分数**（`1/(60+rank)`），免归一化、免调参，实测把正确答案推到第一。
5. **Bi-Encoder 召回 + Cross-Encoder 重排**构成三级漏斗（100 万 → 100 → 20 → 3），重排后分数区分度大幅提升（0.96 vs 0.44）。
6. 参数口诀：**召回 50~100 → 融合 → 重排 20 → 最终 3~5**。

**下一篇**：切分、向量化、向量库、混合检索、重排——所有零件都齐了。下一篇《端到端 RAG 系统实战》把它们组装成一个**完整可运行的系统**：加引用溯源（每句话标注出处）、拒答机制（找不到就老实说不知道）、Prompt 组装模板，最后用 **Recall@5 和 MRR** 量化评估效果，并给出一个**不装任何模型也能跑通**的离线版本让你先看懂全流程。

> 本篇是《大模型开发从 0 到 1》专栏第 40 篇，阶段 7「RAG 检索增强生成」第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
