<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 端到端 RAG 系统实战

**承上**：阶段 7 的零件全部到位了——7-1 切分与 Embedding、7-2 向量数据库、7-3 混合检索与重排。

**本篇**：把它们组装成一个**完整可运行的系统**。我会先给一个**不依赖任何 API 和模型权重、你复制粘贴就能跑通**的离线版（用 bigram 词袋代替 Embedding、用模板代替大模型），让你看清全链路；再给生产版架构，并加上两个决定用户体验的细节——**引用溯源**和**拒答机制**；最后用 **Recall@3 和 MRR** 量化评估效果。

**启下**：RAG 解决了"知道得不够"的问题，但它始终是**被动**的——你问一句它答一句，不会自己拆解任务、不会主动调用工具、不会多步推理。**阶段 8：Agent 智能体开发** 给大模型装上"手脚"和"大脑循环"，让它能自己规划并执行复杂任务。

**学完这一节，你能动手做**：

1. 从零组装一个完整 RAG 系统，并在本机跑通全流程
2. 实现引用溯源与拒答机制，让答案可信、可控
3. 用 Recall@k、MRR 量化评估效果，知道该优化哪一环

---

## 一、先把四篇的零件摆出来

```
┌─────────────── 离线建库（做一次） ───────────────┐
│ 文档 → 解析 → 切分(7-1) → 向量化(7-1) → 存向量库(7-2) │
└────────────────────────────────────────────────┘
                        ↓
┌─────────────── 在线问答（每次） ────────────────┐
│ 问题 → 向量召回 + BM25 召回 → RRF 融合(7-3)      │
│      → Cross-Encoder 重排(7-3) → Top-K          │
│      → 组装 Prompt → 大模型生成 → 带引用的答案    │
└────────────────────────────────────────────────┘
                                        ↑
                              【本篇重点】
```

## 二、代码实战 1：不装任何模型也能跑通的离线版

这个版本用 **bigram 词袋 + 余弦**代替 Embedding，用**模板抽取**代替大模型。语义能力弱一些，但**流程与生产版完全一致**——你先把链路跑通看懂，再逐个替换成真实组件。

```python
import re, math

DOCS = [
    ("d1", "退款政策：签收后 7 天内可申请无理由退款，运费 12 元由买家承担。"),
    ("d2", "质量问题：30 天内可申请退款，往返运费由平台承担。"),
    ("d3", "发货时效：自营商品在付款后 48 小时内发货，节假日不顺延。"),
    ("d4", "物流查询：在「我的订单」页面点击「查看物流」即可看到实时位置。"),
    ("d5", "发票申请：确认收货后可在订单详情页申请电子发票，3 个工作日内开出。"),
    ("d6", "会员权益：会员积分可在下次购物时抵扣现金，100 积分抵 1 元。"),
]

def tokenize(text: str) -> list[str]:
    """中文 bigram 分词（无需 jieba 就能跑）。"""
    toks = []
    for seg in re.findall(r"[a-zA-Z0-9]+|[\u4e00-\u9fff]", text):
        toks.append(seg.lower() if seg.isascii() else seg)
    cjk = [c for c in text if "\u4e00" <= c <= "\u9fff"]
    toks += ["".join(cjk[i:i + 2]) for i in range(len(cjk) - 1)]
    return toks

class BagOfWordsEmbedder:
    """离线版 Embedding（生产环境换成 bge-m3 / Qwen3-Embedding）。"""
    def __init__(self, texts):
        self.vocab = {}
        for t in texts:
            for w in set(tokenize(t)):
                self.vocab.setdefault(w, len(self.vocab))

    def encode(self, texts):
        out = []
        for t in texts:
            v = [0.0] * len(self.vocab)
            for w in tokenize(t):
                if w in self.vocab:
                    v[self.vocab[w]] += 1.0
            n = math.sqrt(sum(x * x for x in v)) or 1.0     # L2 归一化
            out.append([x / n for x in v])                   # 归一化后点积=余弦
        return out

class InMemoryVectorStore:
    """离线版向量库（生产环境换成 Chroma / Milvus）。"""
    def __init__(self, docs, embedder):
        self.ids   = [d[0] for d in docs]
        self.texts = [d[1] for d in docs]
        self.vecs  = embedder.encode(self.texts)
        self.embedder = embedder

    def search(self, query: str, k: int = 3):
        q = self.embedder.encode([query])[0]
        sims = [sum(a * b for a, b in zip(q, v)) for v in self.vecs]
        order = sorted(range(len(sims)), key=lambda i: -sims[i])[:k]
        return [(self.ids[i], self.texts[i], sims[i]) for i in order]

class RAGPipeline:
    def __init__(self, store, min_score=0.15):
        self.store = store
        self.min_score = min_score          # 拒答阈值

    def build_prompt(self, query: str, hits) -> str:
        ctx = "\n".join(f"[{i+1}] ({_id}) {txt}"
                        for i, (_id, txt, s) in enumerate(hits))
        return (f"请仅根据以下资料回答问题，并标注引用编号。\n"
                f"如果资料中没有答案，请回答\"根据现有资料无法回答\"。\n\n"
                f"资料：\n{ctx}\n\n问题：{query}")

    def answer(self, query: str, k: int = 3, llm_fn=None):
        hits = self.store.search(query, k)
        # 拒答机制：最高分都低于阈值，说明库里真没有
        usable = [h for h in hits if h[2] >= self.min_score]
        if not usable:
            return "根据现有资料无法回答。", []
        prompt = self.build_prompt(query, usable)
        if llm_fn:                                    # 接真实大模型
            return llm_fn(prompt, usable), usable
        # 离线兜底：直接取最高分段落（真实场景由大模型组织语言）
        _id, txt, _ = usable[0]
        return f"{txt.split('：', 1)[-1]}（引用 {_id}）", usable

# ---------- 跑起来 ----------
emb   = BagOfWordsEmbedder([t for _, t in DOCS])
store = InMemoryVectorStore(DOCS, emb)
rag   = RAGPipeline(store)

TEST = [("无理由退款要几天内申请", {"d1"}),
        ("物流在哪里看",           {"d4"}),
        ("发票怎么开",             {"d5"}),
        ("积分能干什么",           {"d6"})]

recalls, mrrs = [], []
for q, truth in TEST:
    ans, hits = rag.answer(q, k=3)
    ids = [h[0] for h in hits]
    print(f"Q: {q}")
    print(f"   检索: {[(i, round(s, 3)) for i, _, s in hits]}")
    print(f"   A: {ans}")
    recalls.append(1.0 if truth & set(ids[:3]) else 0.0)
    rank = next((r + 1 for r, i in enumerate(ids) if i in truth), None)
    mrrs.append(1.0 / rank if rank else 0.0)

print(f"\nRecall@3 = {sum(recalls)/len(recalls):.2f}   MRR = {sum(mrrs)/len(mrrs):.2f}")
print("拒答测试:", rag.answer("你们公司CEO是谁")[0])
```

运行结果：

```
Q: 无理由退款要几天内申请
   检索: [('d1', 0.639), ('d2', 0.408), ('d5', 0.216)]
   A: 签收后 7 天内可申请无理由退款，运费 12 元由买家承担。（引用 d1）
Q: 物流在哪里看
   检索: [('d4', 0.524)]
   A: 在「我的订单」页面点击「查看物流」即可看到实时位置。（引用 d4）
Q: 发票怎么开
   检索: [('d5', 0.418)]
   A: 确认收货后可在订单详情页申请电子发票，3 个工作日内开出。（引用 d5）
Q: 积分能干什么
   检索: [('d6', 0.444)]
   A: 会员积分可在下次购物时抵扣现金，100 积分抵 1 元。（引用 d6）

Recall@3 = 1.00   MRR = 1.00
拒答测试: 根据现有资料无法回答。
```

**四个关键观察**：

1. **第一个问题召回了 3 条**，其中 d1（正确）0.639、d2（质量问题退款，语义相近）0.408——这正是"召回要多于最终使用量"的价值：**给重排/大模型留出选择空间**。
2. **后三个问题只召回 1 条**——因为其它文档与它们的相似度低于阈值（0.15）。这说明**阈值同时控制着"召回多少"和"是否拒答"**。
3. **Recall@3 = 1.00，MRR = 1.00**：正确文档每次都排在第一。
4. **拒答生效**：问"CEO 是谁"，最高分低于阈值，直接说不知道，**而不是让大模型编一个**。

## 三、Prompt 组装：三个必须写进去的指令

RAG 的 Prompt 不是"把资料和问题拼起来"就完事。三个指令缺一不可：

```python
PROMPT_TEMPLATE = """你是一个基于资料回答问题的助手。请严格遵守以下规则：

1. **只用资料作答**：不要使用资料之外的知识。资料里没有的，就说不知道。
2. **标注引用**：每个事实后用 [编号] 标注来源，例如「7 天内可申请[1]」。
3. **无法回答时明确拒答**：如果资料不足以回答，只输出「根据现有资料无法回答」。

# 资料
{context}

# 问题
{query}

# 回答
"""
```

| 指令 | 为什么必须 | 不写的后果 |
|---|---|---|
| **只用资料** | 切断模型"自由发挥"的通路 | 模型用预训练知识补充，产生幻觉 |
| **标注引用** | 让用户可核查 | 无法溯源，用户不敢信 |
| **明确拒答** | 给模型一个"体面的退路" | 模型硬着头皮编答案 |

**进阶技巧**：

- **给拒答一个示例**（few-shot）：`例如问「火星上有水吗」，回答「根据现有资料无法回答」`，拒答率显著提升；
- **要求"先列证据再作答"**：让模型先复述资料里的相关句子，再组织答案，准确率更高；
- **控制引用格式**：要求 `[1]` 而不是 `(来源：policy.md 第 3 节)`，便于前端解析成链接。

## 四、引用溯源：三种实现方案

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **提示词约束**（最常用） | 让模型输出 `[1][2]` 编号 | 简单、零成本 | 模型偶尔标错 |
| **后处理对齐** | 用字符串匹配把答案句子对应回 chunk | 可控 | 复述型答案对不上 |
| **结构化输出** | 要求 JSON：`{"answer": "...", "citations": [1,3]}` | 程序可解析 | 输出变长 |

**推荐组合**：提示词约束 + 结构化输出，并在前端把编号渲染成可点击的链接，hover 显示原文。**RAG 最大的产品价值就是让用户能点开原文核对**——这比答案本身更能建立信任。

## 五、拒答机制：宁可不说，不可乱说

RAG 系统最严重的失败不是答错，而是**在库里没有答案时编了一个很像真的答案**。拒答有三道闸门：

```
闸门 1：检索分数阈值    max_score < 0.15 → 直接拒答（最快，零成本）
闸门 2：重排分数阈值    rerank_score < 0.1 → 拒答（更准）
闸门 3：Prompt 指令     让模型自己判断资料够不够（最后一道防线）
```

**阈值怎么定？** 不要拍脑袋，用数据：

```python
def tune_threshold(rag, test_set, thresholds):
    """在测试集上扫阈值，找拒答率与错误率的平衡点。"""
    print(f"{'阈值':>6} {'拒答率':>8} {'答错率':>8} {'正确率':>8}")
    for th in thresholds:
        rag.min_score = th
        refuse = wrong = correct = 0
        for q, truth, _ in test_set:
            ans, hits = rag.answer(q)
            if not hits:
                refuse += 1
            elif truth & {h[0] for h in hits}:
                correct += 1
            else:
                wrong += 1
        n = len(test_set)
        print(f"{th:6.2f} {refuse/n:8.1%} {wrong/n:8.1%} {correct/n:8.1%}")
```

**业务权衡**：客服场景可以容忍一定拒答率（转人工）；但**"答错"的代价远高于"拒答"**——所以阈值宁可保守一点。

## 六、效果评估：两个核心指标

不要凭感觉说"效果不错"，用数字：

```python
def evaluate(rag, test_set, k=3):
    """test_set: [(query, {正确doc_id集合}), ...]"""
    recall, mrr = [], []
    for q, truth in test_set:
        _, hits = rag.answer(q, k=k)
        ids = [h[0] for h in hits]
        # Recall@k：前 k 条里有没有正确答案
        recall.append(1.0 if truth & set(ids[:k]) else 0.0)
        # MRR：正确答案出现位置倒数的平均（第一名=1，第二名=0.5…）
        rank = next((r + 1 for r, i in enumerate(ids) if i in truth), None)
        mrr.append(1.0 / rank if rank else 0.0)
    return {"Recall@%d" % k: sum(recall)/len(recall), "MRR": sum(mrr)/len(mrr)}
```

| 指标 | 含义 | 健康值 |
|---|---|---|
| **Recall@k** | 前 k 条里**有没有**正确答案 | ≥ 0.90（k=5） |
| **MRR** | 正确答案**排第几**（越靠前越高） | ≥ 0.80 |
| **忠实度** | 答案是否只用了资料里的内容（不幻觉） | 人工抽检 ≥ 95% |
| **拒答率** | 无答案问题的拒答比例 | 视业务定，通常 5%~20% |

**诊断口诀**——指标低时按顺序排查：

```
Recall@5 低 → 召回问题：换 Embedding / 加 BM25 / 调 chunk 大小
Recall@5 高但 MRR 低 → 排序问题：上 Rerank / 调 RRF 参数
两个都高但答案还是错 → 生成问题：改 Prompt / 换更强的生成模型 / 检查 chunk 是否残缺
```

**这套诊断流程能帮你省掉 80% 的无用调优**。很多团队一上来就换更大的模型，其实问题出在切分上。

## 七、生产版架构

```python
class ProductionRAG:
    def __init__(self, embedder, vector_db, bm25, reranker, llm_client):
        self.embedder, self.vdb = embedder, vector_db
        self.bm25, self.reranker, self.llm = bm25, reranker, llm_client
        self.cache = {}                       # 结果缓存（省 token）

    def query(self, question: str, topk_final: int = 4) -> dict:
        if question in self.cache:            # ① 缓存命中直接返回
            return self.cache[question]

        # ② 双路召回（并行）
        q_vec = self.embedder.encode([question], normalize_embeddings=True)
        vec_hits = self.vdb.search(q_vec, k=50)
        bm_hits  = self.bm25.search(question, k=50)

        # ③ RRF 融合
        fused = rrf([to_rank(vec_hits), to_rank(bm_hits)], k=60)
        cand = sorted(fused, key=lambda i: -fused[i])[:20]

        # ④ 重排 + 阈值过滤
        scored = self.reranker.predict([[question, self.docs[i]] for i in cand])
        ranked = sorted(zip(cand, scored), key=lambda x: -x[1])
        hits = [i for i, s in ranked[:topk_final] if s >= 0.1]

        # ⑤ 拒答
        if not hits:
            return {"answer": "根据现有资料无法回答。", "citations": []}

        # ⑥ 生成（带引用）
        prompt = PROMPT_TEMPLATE.format(context=self._fmt(hits), query=question)
        answer = self.llm.chat([{"role": "user", "content": prompt}], temperature=0)

        result = {"answer": answer, "citations": [self.ids[i] for i in hits],
                  "sources": [self.docs[i] for i in hits]}
        self.cache[question] = result
        return result
```

**生产环境还要补的五件事**：

1. **权限过滤**：检索时按用户权限加 `where` 条件（这是企业 RAG 最容易出安全问题的地方）；
2. **流式输出**：生成阶段用 `stream=True`，先返回引用来源再流式吐答案；
3. **超时降级**：重排超时就跳过重排直接用融合结果，**保证可用性优先于完美**；
4. **日志与反馈**：记录每次问答的召回分、用户是否点"有帮助"——**这些是后续优化的燃料**；
5. **增量更新**：文档更新时只重切重传变更的 chunk，并保留 id 映射。

## 八、常见坑

| 坑 | 现象 | 解法 |
|---|---|---|
| 只测 1~2 个问题就上线 | 真实场景一塌糊涂 | 至少 50 条测试集 |
| 不设拒答阈值 | 库里没有也硬答 | 双闸门（检索分 + 重排分）|
| 上下文里塞 20 个 chunk | 慢、贵、被"迷失在中间" | 最终 3~5 个 |
| 检索结果不去重 | 同一段重复出现 | 按 doc_id 去重 |
| 文档更新后没重建 | 答的还是旧政策 | 建立文档版本与重建流程 |
| 中文文档用英文 Embedding | 召回极差 | bge-m3 / gte-Qwen2 / Qwen3-Embedding |
| Prompt 没写"只准用资料" | 模型自由发挥 | 三指令齐全 |
| 忽略权限过滤 | 用户看到不该看的文档 | **检索阶段就过滤，不能只在前端遮掩** |

## 九、本篇小结（阶段 7 收官）

1. 我们组装了一个**不依赖任何 API 就能跑通**的完整 RAG：切分 → 向量化 → 检索 → 融合 → Prompt → 生成 → 引用，实测 **Recall@3 = 1.00、MRR = 1.00**，拒答机制生效。
2. **Prompt 三指令**：只用资料、标注引用、明确拒答——缺一个幻觉就会回来。
3. **拒答三闸门**：检索分阈值 → 重排分阈值 → Prompt 指令。阈值要用测试集扫出来，**"答错"的代价远高于"拒答"**。
4. **评估指标**：Recall@k（有没有）、MRR（排第几）、忠实度、拒答率。诊断顺序：**Recall 低查召回，MRR 低查排序，都高还错查生成**。
5. 生产还要加：权限过滤、流式输出、超时降级、日志反馈、增量更新。
6. **阶段 7 完结**：你现在能从一堆文档搭出一个可信、可溯源、可量化的问答系统。

**下一篇**：但 RAG 是**被动**的——你问一句它答一句。如果用户说"帮我查一下上个月销量前十的商品，做个对比图表并发我邮箱"，RAG 就无能为力了。它不会自己拆解任务、不会循环调用工具、不会根据结果调整策略。**阶段 8 第 1 篇《Agent 核心循环——规划、执行、观察与反思》** 讲清 Agent 与 RAG 的本质区别，并手写 **ReAct 循环**（思考 → 行动 → 观察 → 再思考），让大模型第一次"自己动起来"。

> 本篇是《大模型开发从 0 到 1》专栏第 41 篇，阶段 7「RAG 检索增强生成」第 4 篇（阶段收官）。专栏文章按「分类专栏」归类，顺序学习体验最佳。
