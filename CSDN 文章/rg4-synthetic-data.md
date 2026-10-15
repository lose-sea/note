# RAG 评测集怎么来：用 LLM 合成测试数据的完整流程

想评测 RAG，第一步就得有评测集。现实是：没人愿意写几百条问答对，而且人工写的还常常覆盖不到真实的失败模式。

于是大家转向**用 LLM 合成测试数据**——让模型读你的文档，自动生成问题、答案和上下文。这条路能走通，但也有很多坑：生成的问题太简单、答案本身是错的、所有问题都长一个样。

这一篇讲清楚怎么合成一份**真的有用**的评测集：生成策略、质量控制、多样性保证、以及如何避免"自己考自己"的陷阱。

---

## 一、为什么需要合成数据

### 1.1 人工标注的三个问题

1. **成本高**：一个熟悉业务的人标 100 条，可能要一整天
2. **覆盖窄**：人写问题时会不自觉地写"正常问题"，而真实用户问得千奇百怪
3. **维护难**：知识库更新后，旧的评测集就过时了，重新标又是一轮

### 1.2 合成数据的优势

- **规模可控**：想要 1000 条就能有 1000 条
- **随知识库自动更新**：文档变了，重新生成一遍即可
- **可以定向生成**：专门生成多跳问题、边界问题、拒答场景

### 1.3 但它不是万能的

合成数据最大的问题是**分布偏差**：LLM 生成的问题，和真实用户问的问题，分布不一样。用它测出来的指标，可能高估系统的真实表现。

所以正确的定位是：**合成数据用于迭代期快速对比（A 方案 vs B 方案），真实数据用于最终验收**。两者都要有。

---

## 二、生成流程概览

一个完整的合成流程大概是这样：

```
文档集合
   ↓
1. 选块（挑选信息密度高的 chunk）
   ↓
2. 生成问题（给定 chunk，让 LLM 生成能被它回答的问题）
   ↓
3. 生成答案（独立生成，不参考原 chunk —— 关键设计）
   ↓
4. 质量过滤（去重、去简单、去不可答）
   ↓
5. 多样性增强（题型分布控制）
   ↓
6. 人工抽检（10%~20%）
   ↓
评测集
```

逐步展开。

---

## 三、第一步：选块

不是所有 chunk 都适合出题。

### 3.1 过滤掉不适合的块

```python
def is_good_source(chunk: str) -> bool:
    # 太短，信息量不足
    if len(chunk) < 200:
        return False
    # 太长，生成的问题会太宽泛
    if len(chunk) > 1500:
        return False
    # 纯目录、纯代码块、纯表格表头
    if chunk.count("\n") > 15 and len(chunk) / chunk.count("\n") < 30:
        return False
    # 页眉页脚类噪声
    if any(x in chunk for x in ["版权所有", "第 X 页", "Copyright"]):
        return False
    return True
```

**信息密度**是关键判据。好的出题块应该包含：具体事实、数字、因果说明、操作步骤。

### 3.2 多样性采样

不要随机抽——随机抽会集中在最长的那类文档上。做**分层采样**：

```python
import random
from collections import defaultdict

def stratified_sample(chunks, n, key_func):
    buckets = defaultdict(list)
    for c in chunks:
        buckets[key_func(c)].append(c)

    # 每个桶按比例分配名额
    result = []
    per_bucket = max(1, n // len(buckets))
    for bucket in buckets.values():
        result.extend(random.sample(bucket, min(per_bucket, len(bucket))))

    return result[:n]

# 按文档来源/章节/类型分层
selected = stratified_sample(
    all_chunks, n=200, key_func=lambda c: c.metadata["source_doc"]
)
```

这样保证每个文档类别都有覆盖，评测集不会偏科。

---

## 四、第二步：生成问题

### 4.1 基础提示词

```python
QG_PROMPT = """你是一个测试集生成助手。请基于下面的文档片段，生成 {n} 个问题。

要求：
1. 每个问题必须能仅凭这段文档回答；
2. 问题要自然，像真实用户会问的，不要像考试题；
3. 不要出现"根据上文""这段文档"这类指代；
4. 问题要有具体性，避免"这段讲了什么"这种泛泛的问题；
5. 难度覆盖：至少 1 个需要简单定位，至少 1 个需要跨句推理。

文档片段：
{chunk}

输出 JSON 数组：["问题1", "问题2", ...]"""
```

**关键要求逐条解释**：

- **"能仅凭这段文档回答"**：保证后续 Context Recall 有意义（答案确实在库里）
- **"像真实用户会问的"**：避免生成学术腔的考试题
- **"不要出现指代"**：生成的问题要独立可用
- **"避免泛泛的问题"**：这是最常见的失败模式，LLM 特别爱生成"这段主要讲了什么"

### 4.2 定向生成不同题型

均匀生成会得到一个全是"事实查找"题的评测集，测不出系统的真实能力。**按题型配额生成**是关键：

```python
QUESTION_TYPES = {
    "factoid": {
        "desc": "单一事实查询，答案是一个具体的数字、名称或短句",
        "ratio": 0.35,
    },
    "reasoning": {
        "desc": "需要综合文档中多处信息才能回答，涉及因果或对比",
        "ratio": 0.25,
    },
    "multi_hop": {
        "desc": "需要先找到 A，再根据 A 找到 B，跨越多个知识点",
        "ratio": 0.15,
    },
    "procedural": {
        "desc": "询问如何操作，答案是一系列步骤",
        "ratio": 0.15,
    },
    "unanswerable": {
        "desc": "与文档主题相关，但文档中确实没有答案，用于测试拒答能力",
        "ratio": 0.10,
    },
}

def gen_by_type(chunk, qtype, n):
    prompt = f"""基于文档生成 {n} 个问题，题型要求：{QUESTION_TYPES[qtype]['desc']}

{其他通用要求}

文档：
{chunk}

JSON 数组："""
    ...
```

**`unanswerable` 这一类特别重要**。没有它，你的评测集会完全测不出系统的拒答能力——而拒答失败（硬编答案）是 RAG 最危险的失败模式。

### 4.3 多跳问题的特殊生成法

多跳问题不能只给一个 chunk 生成，要给**多个相关 chunk**：

```python
def gen_multihop(chunk_a, chunk_b, llm):
    prompt = f"""下面有两段文档，它们之间存在某种关联（因果关系、实体重叠、或主题延续）。

请生成 2 个需要同时用到两段信息才能回答的问题。
要求：不能只看一段就答出来。

文档 A：
{chunk_a}

文档 B：
{chunk_b}

JSON 数组："""
    ...
```

怎么找到"相关的两个 chunk"？最简单的方法是用 embedding 找邻居，但**要注意排除同一文档相邻的块**（那种多跳太简单）。要找跨文档的、语义中等相关的块对。

---

## 五、第三步：生成答案（关键设计）

### 5.1 为什么要独立生成答案

一个反直觉但很重要的设计：**生成答案时，不要让模型参考生成问题时用的那个 chunk。**

如果你的流程是"给 chunk → 生成问题 → 再根据 chunk 生成答案"，那答案必然是 chunk 的复述，评测时 Context Recall 会虚高。

**更好的做法**：

```
生成问题时：给 chunk，得到 question
生成答案时：把 question 丢给完整的 RAG 系统，让它检索+生成，得到系统答案
```

然后用**人工或另一个模型**基于原 chunk 写一个 ground_truth。

或者更简单粗暴：直接用原 chunk 作为 context，让模型写 ground_truth，但**要求它写成简洁的事实点**（不是复述）：

```python
GT_PROMPT = """基于下面的文档回答问题。

要求：
1. 只输出答案本身，不要"根据文档""答案是"这类前缀；
2. 只写事实点，不写推理过程；
3. 如果文档中确实没有答案，输出 "UNANSWERABLE"；
4. 控制在 100 字以内。

文档：{chunk}
问题：{question}

答案："""
```

### 5.2 交叉验证：检测错误标注

让另一个模型（或同一个模型换提示词）**独立判断**：这个 ground_truth 能不能被这个 chunk 支撑？

```python
VERIFY_PROMPT = """判断下面的答案能否从文档中推出。

文档：{chunk}
问题：{question}
答案：{answer}

输出 JSON：
{{"supported": true/false, "issue": "若 false，说明原因"}}"""
```

`supported=false` 的样本直接丢弃。这一步能过滤掉 10%~20% 的坏样本，很值得做。

---

## 六、第四步：质量过滤

生成完一堆数据后，必须做清洗。这一步的价值不亚于生成本身。

### 6.1 去重

```python
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics.pairwise import cosine_similarity

def dedup(questions, threshold=0.85):
    vec = TfidfVectorizer().fit_transform(questions)
    sim = cosine_similarity(vec)

    keep, dropped = [], set()
    for i in range(len(questions)):
        if i in dropped:
            continue
        keep.append(i)
        for j in range(i + 1, len(questions)):
            if sim[i][j] > threshold:
                dropped.add(j)
    return keep
```

LLM 生成问题很容易**同质化**——翻来覆去都是"XX 是什么""XX 怎么做"。去重是必须的。

### 6.2 过滤太简单的问题

判据：如果问题里几乎包含了答案的原文（词汇重叠率过高），说明太简单。

```python
def too_easy(question, ground_truth, threshold=0.7):
    q_tokens = set(jieba.lcut(question))
    a_tokens = set(jieba.lcut(ground_truth))
    if not a_tokens:
        return False
    overlap = len(q_tokens & a_tokens) / len(a_tokens)
    return overlap > threshold
```

### 6.3 过滤太泛的问题

```python
VAGUE_PATTERNS = [
    "讲了什么", "主要内容", "介绍一下", "谈谈", "说说",
    "了解一下", "是什么情况", "有哪些内容",
]

def too_vague(q):
    return any(p in q for p in VAGUE_PATTERNS)
```

### 6.4 过滤答案有问题的

```python
BAD_ANSWER_PATTERNS = [
    "根据文档", "根据上文", "文档中提到", "如文档所示",
    "UNANSWERABLE", "", "无", "不确定",
]
```

（注意：`UNANSWERABLE` 对于 unanswerable 题型是**期望**的，要按题型分开处理。）

### 6.5 完整过滤流程

```python
def clean_dataset(samples):
    # 1. 格式与空值
    samples = [s for s in samples if s["question"].strip()
               and s["ground_truth"].strip()]

    # 2. 去泛
    samples = [s for s in samples if not too_vague(s["question"])]

    # 3. 去重
    idx = dedup([s["question"] for s in samples])
    samples = [samples[i] for i in idx]

    # 4. 去太简单（unanswerable 题型除外）
    samples = [s for s in samples
               if s.get("type") == "unanswerable"
               or not too_easy(s["question"], s["ground_truth"])]

    # 5. 交叉验证
    samples = [s for s in samples if verify_supported(s)]

    return samples
```

经过这一轮，通常留下 60%~70%。**这是正常的，不要心疼**。

---

## 七、第五步：人工抽检

**这一步不能省。** 自动生成的评测集，一定有问题。

### 7.1 抽检什么

随机抽 10%~20%，人工检查：

- 问题是否自然？（真实用户会这么问吗）
- 答案是否正确？（对照原文档）
- 答案是否完整？（有没有遗漏关键点）
- 标注类型是否准确？（标成 multi_hop 的真的是多跳吗）

### 7.2 用抽检结果校准

如果抽检发现 15% 的样本有问题，那你的自动指标也有约 15% 的噪声。**这不影响相对比较**（A vs B 都受影响），但影响绝对值的可信度。

**所以在报告指标时，要说明这是基于合成数据的结果。**

### 7.3 把人工修正的样本作为"金标准"

人工修正过的那批样本，可以单独作为一个高质量子集，用于关键决策时的评估。

---

## 八、RAGAS 自带的合成器

RAGAS 提供了现成的 TestsetGenerator，可以直接用：

```python
from ragas.testset.generator import TestsetGenerator
from ragas.testset.evolutions import simple, reasoning, multi_context
from langchain_openai import ChatOpenAI, OpenAIEmbeddings

generator = TestsetGenerator.from_langchain(
    generator_llm=ChatOpenAI(model="gpt-4o"),
    critic_llm=ChatOpenAI(model="gpt-4o"),
    embeddings=OpenAIEmbeddings(),
)

testset = generator.generate_with_langchain_docs(
    documents=my_docs,
    test_size=100,
    distributions={
        simple: 0.5,
        reasoning: 0.25,
        multi_context: 0.25,
    },
)

df = testset.to_pandas()
df.to_csv("testset.csv", index=False)
```

### 8.1 它的"进化"机制

RAGAS 有个有意思的设计叫 **evolution**：不是直接生成问题，而是对简单问题做"进化"：

- **simple**：直接从 chunk 生成
- **reasoning**：改写问题，让它需要推理而非直接查找
- **multi_context**：改写问题，让它需要多个 chunk 才能回答

这个思路很好——**先生成简单的，再往难的方向改造**，比直接生成难题更可控。

### 8.2 局限

- 提示词是英文的，中文效果打折
- 不生成 unanswerable 类型（拒答场景覆盖不到）
- 生成成本高（要多次 LLM 调用）

**建议**：用它快速起步，但要自己补充 unanswerable 类型，并做质量过滤。

---

## 九、最终评测集应该长什么样

一个健康的评测集画像：

| 维度 | 建议值 |
|------|--------|
| 规模 | 100~300 条（够用即可，更多是浪费成本） |
| 题型分布 | factoid 35% / reasoning 25% / multi_hop 15% / procedural 15% / unanswerable 10% |
| 来源覆盖 | 每个主要文档类别至少 10 条 |
| 难度分布 | 应该有 20%~30% 是系统当前答不好的 |
| 人工抽检比例 | 至少 10% 经过人工确认 |

**最后一条特别重要**：如果评测集里系统全都能答对，那这个评测集没有区分度，测不出改进。

### 9.1 数据格式

```json
{
  "id": "q_001",
  "question": "一线城市差旅住宿标准是多少？",
  "ground_truth": "500 元/晚",
  "type": "factoid",
  "source_doc": "差旅管理制度_2023",
  "source_chunk_id": "chunk_1234",
  "difficulty": "easy",
  "verified_by_human": true
}
```

保留 `source_chunk_id` 很有用——后续可以算传统的 Recall@K（知道答案应该在哪个 chunk），比 LLM 判定更可靠。

---

## 十、常见误区

**误区一：生成越多越好。**
1000 条合成数据的价值，不如 100 条精心过滤 + 人工抽检的。规模大了，噪声也大，成本还高。

**误区二：完全依赖合成数据做最终决策。**
合成问题的分布 ≠ 真实用户问题的分布。**上线前必须用真实流量验证**。合成数据用于迭代，真实数据用于验收。

**误区三：同一个模型既生成又评判。**
"自己考自己"会有系统性偏差——模型倾向于认为自己的输出是对的。评判模型和生成模型最好不同，至少提示词和上下文要隔离。

**误区四：忘了生成 unanswerable 样本。**
没有拒答样本，你的评测集完全测不出系统会不会硬编答案。这是最危险的盲区。

**误区五：一次生成完就永久使用。**
知识库更新了，评测集也要更新。建议做成**可重跑的脚本**，而不是一次性产物。

---

## 小结

- 合成评测集解决的是"没人写、写得慢、覆盖窄"的问题，但**它不能替代真实数据做最终验收**。
- 完整流程：**选块 → 按题型配额生成问题 → 独立生成并验证答案 → 质量过滤（去重/去泛/去简单/交叉验证）→ 人工抽检**。
- **按题型配额生成**是关键，尤其是要包含 **unanswerable** 类型（测拒答能力）和 **multi_hop** 类型（测多跳能力）。
- 生成答案时要**避免直接复述 chunk**，否则 Context Recall 会虚高；做交叉验证过滤掉错误标注。
- 质量过滤通常留下 60%~70%，这是正常的。**过滤后的 100 条比未过滤的 500 条有用**。
- RAGAS 的 TestsetGenerator 可以快速起步（有 evolution 机制），但要补 unanswerable 类型，并做好过滤。
- **健康评测集的特征**：100~300 条、题型分布合理、来源覆盖全面、有 20%~30% 是系统当前答不好的（保证区分度）、至少 10% 人工确认。

一句话：**评测集的质量决定了你优化方向的对错**。花在评测集上的时间，最后都会以系统质量的形式还回来。
