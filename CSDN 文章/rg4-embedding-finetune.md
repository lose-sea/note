# 微调 Embedding 模型：什么时候值得做，怎么做

> 用了最好的通用 embedding 模型，检索准确率还是只有 60%。
> 因为你的领域词汇它"没见过"——**医疗缩写、内部代号、行业黑话**。
>
> 微调能把准确率提到 85%+，但**代价不小**。

## 一、先确认：你真的需要微调吗

**微调是最后手段**，不是第一选择。按顺序试：

```
① 换更好的通用模型（bge-large / text-embedding-3-large）
② 优化分块策略
③ 加混合检索（向量 + BM25）
④ 加重排模型
⑤ 加查询改写
⑥ 微调 embedding 模型         ← 最后才到这里
```

**为什么放最后**：

| 代价 | 说明 |
|---|---|
| 需要标注数据 | 几百到几千对，标注成本高 |
| 需要 GPU | 训练和推理 |
| 需要重新索引 | 全量向量化 |
| 效果不一定提升 | 数据不好时可能变差 |
| 维护成本 | 新数据要持续训练 |

**前三步做完还没解决，才考虑微调。**

## 二、什么时候微调真的有用

**有效场景**：

| 场景 | 例子 |
|---|---|
| **领域术语** | 医疗的"IA 期肺癌"、法律的"善意取得" |
| **内部黑话** | 公司的"三号项目"、"蓝标客户" |
| **缩写歧义** | "AC" 是空调还是交流电 |
| **非标准表达** | 客服对话、用户口语 |
| **跨语言配对** | 中文查询匹配英文文档 |

**无效场景**：

```
❌ 通用问答题（通用模型已经很好）
❌ 数据量太少（< 500 对）
❌ 标注质量差（噪声大）
❌ 问题其实是"分块不对"
```

## 三、微调的原理：对比学习

**目标**：让"相关的文本对"在向量空间里更近，"不相关的"更远。

```
训练数据：（查询，正例文档，负例文档）

损失函数（Contrastive / Triplet）：
  maximize  sim(query, positive) - sim(query, negative)
```

**三种训练数据格式**：

| 格式 | 数据 | 说明 |
|---|---|---|
| Pair | (query, positive) | 最简单 |
| Triplet | (query, positive, negative) | 需要负例 |
| Pair + In-batch 负例 | (query, positive) | **负例从 batch 里取** ⭐ |

**推荐"Pair + In-batch 负例"**——**不用手工标注负例**，batch 里其他样本的正例自动成为负例。

## 四、训练数据从哪来

**这是微调最大的瓶颈。**

**① 已有的业务数据（最好）**

```
用户搜索日志 → (query, 点击的文档) 是正例
客服工单     → (问题, 解决该问题的文档) 是正例
标注数据     → 人工标"这个问题应该看哪几篇"
```

**② 用 LLM 合成**

```python
GEN_PROMPT = """根据下面的文档段落，生成 3 个用户可能提出的问题。
要求：问题要自然、口语化，就像真实用户在搜索。

文档：
{chunk}

输出格式（每行一个问题）：
"""

def generate_query_doc_pairs(chunks):
    pairs = []
    for c in chunks:
        queries = llm.invoke(GEN_PROMPT.format(chunk=c.page_content)).content
        for q in queries.strip().split("\n"):
            if q.strip():
                pairs.append({"query": q.strip(), "positive": c.page_content})
    return pairs
```

**合成数据的注意事项**：

```
✅ 生成 2~3 个问题/文档（避免单一模式）
✅ 用不同的 prompt 模板（多样化）
✅ 让问题"口语化"，别太正式
❌ 不要让 LLM 生成"太简单"的问题（一问就能匹配上，学不到东西）
```

**③ 难负例挖掘（关键提升点）**

**随机负例太容易区分，学不到东西。要挖"难负例"**：

```python
def mine_hard_negatives(queries, corpus, embeddings, top_k=50, num_neg=5):
    """挖"当前模型误认为相关，但实际不相关"的样本"""
    pairs = []
    for q, pos_doc in queries:
        qvec = embeddings.embed_query(q)
        results = vectorstore.similarity_search_by_vector(qvec, k=top_k)

        # 排除正确答案，剩下的就是难负例
        negatives = [d for d in results if d.page_content != pos_doc][:num_neg]
        pairs.append({"query": q, "positive": pos_doc, "negatives": negatives})
    return pairs
```

**难负例是提升效果最明显的一步**——从 +3% 到 +15% 都可能。

## 五、微调实现（sentence-transformers）

```python
from sentence_transformers import SentenceTransformer, InputExample, losses
from torch.utils.data import DataLoader

model = SentenceTransformer("BAAI/bge-base-zh-v1.5")

# 构造训练数据
train_examples = [
    InputExample(texts=[p["query"], p["positive"]])       # 正例对
    for p in train_pairs
] + [
    InputExample(texts=[p["query"], p["positive"], n])     # 三元组
    for p in triplet_pairs for n in p["negatives"]
]

loader = DataLoader(train_examples, shuffle=True, batch_size=32)

# 损失函数
train_loss = losses.MultipleNegativesRankingLoss(model)   # 用 batch 内负例

# 训练
model.fit(
    train_objectives=[(loader, train_loss)],
    epochs=3,
    warmup_steps=100,
    output_path="./bge-finetuned",
    evaluation_steps=500,
    save_best_model=True,
)
```

**`MultipleNegativesRankingLoss`** 是最常用的损失——**自动用 batch 内其他样本作为负例**。

**超参数建议**：

| 参数 | 建议值 |
|---|---|
| epochs | 2~5（太多会过拟合） |
| batch_size | 32~64（越大负例越多） |
| learning_rate | 2e-5 ~ 5e-5 |
| warmup | 总步数的 5~10% |

**batch_size 越大越好**——因为 in-batch 负例的数量等于 batch_size。

## 六、数据量要求

| 数据量 | 效果 |
|---|---|
| < 200 对 | 别做，不如调分块 |
| 500 对 | 可以看到一点提升 |
| **2,000 ~ 5,000 对** | **明显提升** ⭐ |
| 10,000+ 对 | 接近上限 |

**"质量 > 数量"**——1000 对高质量标注胜过 10000 对噪声数据。

## 七、评估：必须用"留出集"

```python
# 分成训练集和测试集
from sklearn.model_selection import train_test_split

train, test = train_test_split(pairs, test_size=0.2, random_state=42)

# 训练前测基线
def evaluate(model, test_set):
    correct = 0
    for item in test_set:
        qvec = model.encode(item["query"])
        pvec = model.encode(item["positive"])
        # 和随机负例比较
        neg_vecs = [model.encode(n) for n in item["negatives"][:5]]
        scores = [cosine(qvec, pvec)] + [cosine(qvec, n) for n in neg_vecs]
        if np.argmax(scores) == 0:
            correct += 1
    return correct / len(test_set)

base_model = SentenceTransformer("BAAI/bge-base-zh-v1.5")
print(f"基线准确率：{evaluate(base_model, test):.2%}")

# 训练后
ft_model = SentenceTransformer("./bge-finetuned")
print(f"微调后准确率：{evaluate(ft_model, test):.2%}")
```

**这是最核心的指标**：**"正确答案能否排在负例前面"。**

**更严格的做法**：用完整的检索评估（recall@k）。

```python
def eval_retrieval(model, test_set, corpus, k=10):
    """用微调后的模型重建索引，测 recall@k"""
    emb = HuggingFaceEmbeddings(model_name=model_path)
    vs = build_index(corpus, emb)
    hits = 0
    for item in test_set:
        results = vs.similarity_search(item["query"], k=k)
        if item["positive_id"] in [d.metadata["id"] for d in results]:
            hits += 1
    return hits / len(test_set)
```

## 八、微调后的部署

**① 重新向量化全量数据**

**这是不可避免的成本**。微调后向量空间变了，**旧的向量全部作废**。

```python
def rebuild_index(model_path: str):
    emb = HuggingFaceEmbeddings(model_name=model_path)
    # 全量重算
    for batch in batches(chunks, 500):
        vecs = emb.embed_documents([c.page_content for c in batch])
        vectorstore.add_embeddings(...)
```

**② 自建推理服务**

用 `text-embeddings-inference` 部署：

```bash
docker run -d --gpus all -p 8080:80 \
  -v ./bge-finetuned:/model \
  ghcr.io/huggingface/text-embeddings-inference:latest \
  --model-id /model
```

然后走 OpenAI 兼容接口：

```python
from langchain_openai import OpenAIEmbeddings

embeddings = OpenAIEmbeddings(
    model="bge-finetuned",
    base_url="http://localhost:8080/v1",
    api_key="dummy",
)
```

**好处**：批处理、GPU 加速、动态 batching 都由框架处理。

**③ 版本管理**

```python
MODEL_REGISTRY = {
    "v1": {"path": "BAAI/bge-base-zh-v1.5", "index": "docs_v1", "deployed": "2026-09-01"},
    "v2": {"path": "./bge-finetuned/v2", "index": "docs_v2", "deployed": "2026-10-15"},
}
```

**索引名带模型版本**——避免混用。

## 九、常见问题

**① 过拟合**

```
训练集准确率 95%，测试集 60%
```

**对策**：

```
- 减少 epochs（从 5 降到 2~3）
- 增大数据量
- 加 dropout
- 早停（evaluation_steps + save_best_model）
```

**② 微调后效果反而变差**

**原因**：训练数据和真实分布不一致。

```
训练数据：LLM 生成的"标准问题"
真实查询：用户的口语化短查询

→ 模型学会了匹配"标准问题"，但对真实查询更差了
```

**对策**：**训练数据要贴近真实查询**，优先用日志数据。

**③ 灾难性遗忘**

模型对通用领域的能力下降。

**对策**：**混入一部分通用数据**：

```python
# 90% 领域数据 + 10% 通用数据
train_data = domain_pairs + random.sample(general_pairs, len(domain_pairs) // 9)
```

**④ 负例太简单**

随机负例（从全库随机抽）很容易区分，学不到东西。

**对策**：用难负例挖掘（见前文）。

## 十、成本估算

```
数据准备：标注 3000 对（或合成 + 人工校验）    ≈ 3~5 人天
训练：单卡 A100，3 个 epoch，3000 对          ≈ 30 分钟
全量重索引：100 万块                           ≈ 2~4 小时（GPU）
推理服务：1 张 GPU 卡                          ≈ 持续成本
```

**核心成本在"数据准备"**——这也是为什么微调要放在最后。

## 十一、替代方案：不用微调的办法

**有些"微调能解决的问题"，不微调也能解决**：

| 问题 | 微调方案 | 替代方案 |
|---|---|---|
| 领域术语不匹配 | 微调 | **加同义词词典 + 查询扩展** |
| 缩写歧义 | 微调 | **在分块时补全缩写** |
| 内部代号 | 微调 | **建"代号 → 全称"映射表** |
| 口语化查询 | 微调 | **查询改写（LLM）** |
| 中英跨语言 | 微调 | **换多语言模型（bge-m3）** |

**先试替代方案，成本低得多。**

## 十二、小结

```python
# 微调流程
① 收集数据（日志 / 标注 / LLM 合成）
② 挖难负例
③ 训练（MultipleNegativesRankingLoss, 2~3 epochs）
④ 评估（留出集，recall@k）
⑤ 重建全量索引
⑥ 部署（text-embeddings-inference）
```

五条判断：

```
1. 先试完"换模型/调分块/混合检索/重排/改写"再考虑微调
2. 数据 < 500 对别做；2000~5000 对是甜蜜区
3. 难负例挖掘是提升最明显的一步
4. 训练数据必须贴近真实查询分布
5. 微调后必须全量重建索引
```

**一句话：微调 embedding 是"最后 10% 的提升需要付出 10 倍成本"的典型。** 它确实能解决通用模型解决不了的领域问题，**但一定要先穷尽其他手段**——**很多看起来"必须微调"的问题，其实是分块或检索策略的问题**。
