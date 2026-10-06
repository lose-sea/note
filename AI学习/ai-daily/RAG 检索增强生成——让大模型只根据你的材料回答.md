<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# RAG 检索增强生成——让大模型只根据你的材料回答

## 一、为什么需要 RAG

大模型有两个绕不开的短板：

1. **不知道你的私有数据**：公司文档、产品手册、内部 FAQ，它训练时没见过。
2. **会一本正经地编造**：问到它不知道的东西，它倾向于"合理编一个"，也就是幻觉。

微调能解决一部分问题，但成本高、更新慢（改一次文档就得重新训练）。

**RAG（Retrieval-Augmented Generation，检索增强生成）的思路更直接**：

> 别让模型凭记忆回答，**先去你的资料库里检索相关内容，把找到的片段塞进 Prompt，让模型"开卷考试"**。

```
用户提问
   ↓
① 把问题转成向量（Embedding）
   ↓
② 在向量库里找最相似的 K 个文档片段
   ↓
③ 把片段 + 问题一起塞进 Prompt
   ↓
④ 大模型基于材料生成答案，并标注引用来源
```

这样做的好处：

| 优势 | 说明 |
| ---- | ---- |
| 无需训练 | 改文档即刻生效，不用重训模型 |
| 可溯源 | 答案能标出来自哪一段，方便核验 |
| 降低幻觉 | 模型被材料约束，编造空间被压缩 |
| 成本低 | 相比微调，成本几乎可以忽略 |

## 二、第一步：把文本变成向量（Embedding）

### 2.1 Embedding 是什么

Embedding 模型把一段文本映射成一个固定长度的数值向量（比如 768 维或 1536 维）。**语义相近的文本，向量在空间中距离更近**。

```
"如何申请退款"  →  [0.12, -0.34, 0.56, ...]
"退款流程是怎样的" →  [0.11, -0.31, 0.58, ...]   ← 与上面很接近
"今天天气不错"   →  [-0.62, 0.44, -0.09, ...]   ← 距离很远
```

于是"找相关内容"就变成了"**找最近的向量**"，这就是语义检索的本质——**它匹配的是意思，不是关键词**。

| 对比 | 关键词检索（BM25） | 向量检索 |
| ---- | ------------------ | -------- |
| 匹配依据 | 字面重合 | 语义相似 |
| 同义词 | ❌ 搜"退款"搜不到"退货" | ✅ 能关联 |
| 精确编号/专有名词 | ✅ 强 | ⚠️ 弱 |
| 是否需要模型 | 否 | 是 |

实际系统里**两者结合（混合检索）效果最好**，这点后面会讲。

### 2.2 调用 Embedding 接口

```python
import os
import numpy as np
from openai import OpenAI

client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"),
                base_url=os.getenv("OPENAI_BASE_URL"))

def embed(texts: list[str]) -> np.ndarray:
    """把文本列表转成向量矩阵，形状 (n, dim)"""
    resp = client.embeddings.create(
        model="text-embedding-3-small",
        input=texts
    )
    vecs = np.array([d.embedding for d in resp.data], dtype="float32")
    # 归一化后，点积就等于余弦相似度，后续算起来更快
    vecs /= np.linalg.norm(vecs, axis=1, keepdims=True)
    return vecs

docs = [
    "退款政策：收到商品 7 天内可申请无理由退款，需保持商品完好。",
    "配送说明：全国大部分地区 48 小时内发货，偏远地区 3-5 天。",
    "会员权益：年度会员享受全年包邮与专属客服通道。",
]
doc_vecs = embed(docs)
print("向量形状:", doc_vecs.shape)     # (3, 1536)

# 语义检索：问"东西不想要了怎么退"
q_vec = embed(["不想要了怎么退"])
scores = doc_vecs @ q_vec[0]           # 归一化后点积 = 余弦相似度
top = np.argsort(-scores)[:2]
for i in top:
    print(f"相似度 {scores[i]:.3f} | {docs[i]}")
```

输出：

```
向量形状: (3, 1536)
相似度 0.742 | 退款政策：收到商品 7 天内可申请无理由退款，需保持商品完好。
相似度 0.415 | 会员权益：年度会员享受全年包邮与专属客服通道。
```

注意：问题里没有出现"退款"二字，也没出现"7天"，但系统仍然正确匹配到了退款政策——**这就是语义检索的价值**。

## 三、第二步：文档切片（Chunking）

RAG 效果好不好，**切片策略占一半因素**。

### 3.1 为什么不能整篇丢进去

- 上下文窗口有限，长文档塞不下
- 整篇做 Embedding 会把多个主题混合成一个向量，检索精度下降
- 你只想给模型相关那几段，不是整本书

### 3.2 三种常用切片方式

| 方式 | 做法 | 优点 | 缺点 |
| ---- | ---- | ---- | ---- |
| 固定长度 | 每 500 字切一刀 | 简单 | 可能把句子切断，破坏语义 |
| 按结构 | 按标题/段落/空行切 | 语义完整 | 长度不均，有的太短 |
| 重叠滑动 | 每段 500 字，相邻重叠 100 字 | 减少切断损失 | 有冗余，存储变大 |

**推荐做法：按结构优先 + 长度上限兜底 + 少量重叠**。

```python
import re

def chunk_text(text: str, max_len=500, overlap=80) -> list[str]:
    """先按段落切，过长的段落再按句子细切，并保留少量重叠"""
    # 1. 先按空行切成自然段落
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks = []

    for p in paragraphs:
        if len(p) <= max_len:
            chunks.append(p)
            continue

        # 2. 过长的段落按句号切分，累积到 max_len 就成块
        sentences = re.split(r"(?<=[。！？；])", p)
        buf = ""
        for s in sentences:
            if len(buf) + len(s) <= max_len:
                buf += s
            else:
                if buf:
                    chunks.append(buf)
                    # 保留尾部 overlap 个字符，避免切断上下文
                    buf = buf[-overlap:] + s
                else:
                    buf = s
        if buf:
            chunks.append(buf)
    return chunks

# 试一下
text = "退款政策。用户可在收到商品后 7 天内申请无理由退款，商品需保持完好且配件齐全。" * 3
for i, c in enumerate(chunk_text(text, max_len=120, overlap=20)):
    print(f"[{i}] ({len(c)}字) {c[:40]}...")
```

> ⚠️ **坑 1**：切片太短会丢失上下文（"它指的是什么"无从判断），太长则引入噪声。**一般 300-800 字是个不错的起点，再根据评测结果调**。

> **小技巧**：给每个 chunk 加上它所属标题作为前缀（如"【退款政策】..."),能显著提升检索准确率。

## 四、第三步：检索与重排

### 4.1 向量库：从暴力搜索到近似检索

文档不多（几千条以内）时，NumPy 暴力算就够快：

```python
class SimpleVectorDB:
    def __init__(self):
        self.vectors = None
        self.texts = []

    def add(self, texts, vectors):
        self.texts.extend(texts)
        self.vectors = vectors if self.vectors is None else np.vstack([self.vectors, vectors])

    def search(self, query_vec, top_k=3):
        scores = self.vectors @ query_vec            # (n,)
        idx = np.argsort(-scores)[:top_k]
        return [(self.texts[i], float(scores[i])) for i in idx]

db = SimpleVectorDB()
db.add(docs, doc_vecs)
for t, s in db.search(q_vec[0]):
    print(f"{s:.3f} | {t[:40]}")
```

文档上万条后，需要专门的向量库（FAISS、Milvus、Chroma、pgvector），它们用 **HNSW / IVF 等近似最近邻算法**，牺牲一点点精度换来数量级的速度提升。

| 方案 | 适用场景 |
| ---- | -------- |
| NumPy 暴力 | < 1 万条，原型验证 |
| FAISS | 单机、百万级，性能好 |
| Chroma | 轻量级，开箱即用 |
| Milvus / pgvector | 生产级、分布式、需持久化 |

### 4.2 混合检索：向量 + 关键词

纯向量检索在**精确匹配**（产品型号、错误码、人名）上表现一般。解决办法是两路召回再融合：

```python
def hybrid_search(query, vec_scores, bm25_scores, alpha=0.6):
    """alpha 控制向量检索的权重，0.6 表示偏重语义"""
    def norm(x):
        x = np.asarray(x, dtype=float)
        return (x - x.min()) / (x.max() - x.min() + 1e-9)
    return alpha * norm(vec_scores) + (1 - alpha) * norm(bm25_scores)
```

### 4.3 Rerank 重排：把最相关的提到最前面

两阶段策略是工业界的标配：

```
粗排（召回 50 条）→ 精排（Rerank 模型打分）→ 取 Top 5 给大模型
```

Rerank 模型（如 bge-reranker、Cohere Rerank）会把问题和每个候选片段**拼在一起过一遍模型**，判断相关性，精度远高于直接算向量距离，代价是慢一些。

```python
# 伪代码：示意两阶段流程
candidates = db.search(q_vec[0], top_k=50)        # 粗排：便宜、快
reranked = rerank_model.score(query, candidates)  # 精排：贵、准
final = reranked[:5]                              # 只把最相关的 5 条给 LLM
```

## 五、第四步：组装 Prompt 并生成答案

检索到片段后，关键是**让模型严格基于材料回答**。

```python
RAG_PROMPT = """
# 角色
你是企业知识库助手，只能依据下方【参考资料】回答问题。

# 参考资料
{context}

# 问题
{question}

# 约束
1. 只能使用参考资料中的信息，禁止使用你的先验知识
2. 若资料中没有答案，直接回答"资料中没有相关信息"，不要编造
3. 每个关键结论后用 [1] [2] 标注对应的资料编号
4. 回答简洁，控制在 200 字以内
"""

def rag_answer(question: str, db, top_k=3) -> str:
    # 1. 检索
    hits = db.search(embed([question])[0], top_k=top_k)
    # 2. 组装带编号的上下文
    context = "\n".join(f"[{i+1}] {t}" for i, (t, s) in enumerate(hits))
    # 3. 生成
    prompt = RAG_PROMPT.format(context=context, question=question)
    resp = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": prompt}],
        temperature=0
    )
    return resp.choices[0].message.content

print(rag_answer("买的东西不想要了，多久之内能退？", db))
```

典型输出：

```
您可以在收到商品后 7 天内申请无理由退款 [1]。申请时商品需保持完好且配件齐全 [1]。
```

> ⚠️ **坑 2**：不写"资料中没有就直说"，模型几乎一定会根据常识编一个像模像样的答案。这是 RAG 失败最常见的原因。

## 六、RAG 效果怎么评测

不要只看"感觉挺好"，要拆成两个环节分别测：

### 6.1 检索环节指标

| 指标 | 含义 | 目标 |
| ---- | ---- | ---- |
| Recall@K | 正确片段出现在前 K 条中的比例 | > 0.9 |
| MRR | 首个正确结果的排名倒数 | 越接近 1 越好 |
| Hit Rate | 至少命中一条的比例 | > 0.95 |

### 6.2 生成环节指标

| 指标 | 检测什么 |
| ---- | -------- |
| 忠实度 Faithfulness | 答案是否都能在资料中找到依据（防幻觉） |
| 答案相关性 | 是否回答了问题 |
| 引用准确率 | 标注的 [1] 是否真的支持该结论 |

```python
# 构建最小评测集
eval_set = [
    {"q": "退款期限是多久", "expect_chunk": "退款政策"},
    {"q": "偏远地区几天发货", "expect_chunk": "配送说明"},
    {"q": "会员有什么好处", "expect_chunk": "会员权益"},
    {"q": "公司CEO是谁", "expect_chunk": None},   # 负样本：不该命中
]

def eval_recall(db, k=3):
    ok = 0
    for case in eval_set:
        hits = db.search(embed([case["q"]])[0], top_k=k)
        texts = [t for t, s in hits]
        expect = case["expect_chunk"]
        if expect is None:
            # 负样本：期望模型回答"没有相关信息"
            ok += 1
            continue
        ok += any(expect in t for t in texts)
    return f"Recall@{k}: {ok}/{len(eval_set)}"

print(eval_recall(db))
```

**负样本很重要**：专门准备一批"资料里确实没有"的问题，验证系统会不会老实说"不知道"。

## 七、常见坑清单

| 坑 | 现象 | 解决 |
| -- | ---- | ---- |
| 切片切断语义 | 检索到的片段读不通 | 按结构切 + 重叠 + 加标题前缀 |
| 切片过长 | 引入噪声，答案跑偏 | 控制 300-800 字，配评测调 |
| Prompt 不设约束 | 模型自己编答案 | 明确"资料中没有就直说" |
| 只做向量检索 | 型号、编号搜不准 | 混合检索（向量 + BM25） |
| 忘记归一化向量 | 相似度算错 | Embedding 后做 L2 归一化 |
| 中文分词影响 BM25 | 关键词路召回差 | 用 jieba 分词 + 中文 BM25 实现 |
| 一次性塞 20 条片段 | 上下文过长、中间遗忘 | 粗排后 Rerank，最终只给 3-5 条 |

## 八、本节小结

1. **RAG = 检索 + 生成**，让模型"开卷考试"，解决私有数据不可见和幻觉两大问题，且无需训练。
2. **Embedding 是语义检索的基础**：把文本变向量，用余弦相似度找近邻，匹配的是意思而非字面。
3. **切片策略决定一半效果**：按结构切、长度 300-800 字、少量重叠、带上标题前缀。
4. **两阶段检索是标配**：粗排召回（快）→ Rerank 精排（准）→ 只给模型 3-5 条。
5. **混合检索兼顾语义与精确**：向量路 + 关键词路加权融合。
6. **Prompt 必须写死约束**：禁止用先验知识、资料没有就说不知道、标注引用编号。
7. **评测要分环节**：检索看 Recall@K，生成看忠实度，并准备负样本验证"会不会瞎编"。

到这里，AI 学习主线已经串起来了：Python 数据处理 → 机器学习 → 深度学习 PyTorch → Transformer → Prompt 工程 → RAG。下一步可以往 **Agent（让模型自己规划、调工具、多步执行）** 或 **微调与部署** 两个方向深入。

---

> 一句话记住：**RAG 的本质不是"让模型知道更多"，而是"让模型只被允许用它该用的材料"——检索负责找对，Prompt 负责管住。**
