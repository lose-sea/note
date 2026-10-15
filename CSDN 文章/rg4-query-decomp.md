# 查询分解：把复杂问题拆成子问题，RAG 才答得上来

用户问一个问题，你检索一次，拿回一堆文档，塞给大模型，它给了一个看起来很像样但其实是拼凑出来的答案。这种失败在 RAG 系统里非常常见，而且很难通过调 embedding、调切分解决——因为问题出在**问题本身的结构**上。

复杂问题天然是多步的。你非要一步检索到位，系统只能拿一个"平均向量"去碰运气。查询分解（Query Decomposition）就是承认这一点：先拆，再分别检索，最后综合。

这篇我们讲清楚怎么拆、拆完怎么检索、结果怎么汇总、以及哪些问题根本不该拆。

---

## 一、什么样的问答不动

先看看哪些问题是"一步检索"搞不定的。实际日志里高频出现的几类：

### 1.1 比较类

> "A 方案和 B 方案在成本、部署难度、运维复杂度上各有什么优劣？"

要回答这个，你需要分别拿到 A 方案的三项信息和 B 方案的三项信息，共 6 个事实点。一次 top_k=5 的检索，很难同时覆盖。

### 1.2 多跳类

> "我们采用的那个向量数据库，它的分片机制在节点故障时会怎样？"

第一跳：确认"我们采用的那个向量数据库"是哪个（可能在架构文档里）。第二跳：查它的分片机制。第三跳：查故障时的行为。**后面的检索依赖前面的答案**，这是典型多跳。

### 1.3 条件约束类

> "2024 年之后的差旅政策里，一线城市住宿标准是多少？"

"2024 年之后"是时间约束，"一线城市"是地域约束，"住宿标准"是目标。一次性检索时，约束条件往往被稀释——向量模型对"2024年之后"这种时间限定词的敏感度很低。

### 1.4 聚合类

> "统计一下知识库里提到过几次数据泄露事件，分别是什么类型？"

这种需要遍历、计数，检索根本不该去"找一段包含答案的文本"，而应该走别的路径（比如结构化查询）。

---

## 二、两种分解方式

查询分解不是一个单一技术，实际落地分两种，适用场景不同。

### 2.1 并行分解（Parallel Decomposition）

子问题之间**没有依赖**，可以并行检索。

原问题："比较 MySQL 和 PostgreSQL 在事务隔离、JSON 支持、全文检索三方面的差异"

拆分：
```
1. MySQL 的事务隔离级别支持情况
2. PostgreSQL 的事务隔离级别支持情况
3. MySQL 的 JSON 类型支持能力
4. PostgreSQL 的 JSON 类型支持能力
5. MySQL 的全文检索实现方式
6. PostgreSQL 的全文检索实现方式
```

6 个子问题互不相干，全部并发检索，结果汇总后一次生成。延迟约等于一次检索 + 一次生成。

### 2.2 串行分解（Sequential / Iterative Decomposition）

子问题之间**有依赖**，必须按顺序，后面的问题要根据前面的答案才能定下来。

原问题："我们线上用的那个向量库，它在单节点宕机时数据会丢吗？"

```
第 1 步：检索"线上向量库选型" → 得到：Milvus
第 2 步：检索"Milvus 单节点故障 数据丢失" → 得到：依赖 etcd 持久化配置
第 3 步：检索"Milvus etcd 持久化配置" → 得到答案
```

串行分解延迟高（N 轮检索 + N 轮生成），但能解决并行分解解决不了的问题。**不要一上来就上串行**，它是成本最高的方案。

### 2.3 怎么判断用哪种

一个实用的判据：**子问题里有没有指代需要前置答案来消解的**。

- 出现"那个/这个/它/上述/前者"这类指代，且指向需要查才知道的东西 → 串行
- 子问题都能独立表述清楚 → 并行

实现上可以让 LLM 在输出分解结果时顺带标注类型和依赖关系：

```json
{
  "type": "sequential",
  "sub_questions": [
    {"id": 1, "q": "公司当前线上使用的向量数据库是哪一种？", "depends_on": []},
    {"id": 2, "q": "{q1_result} 在单节点宕机时的数据持久化行为", "depends_on": [1]},
    {"id": 3, "q": "{q1_result} 的 etcd 配置如何保证元数据不丢失", "depends_on": [1]}
  ]
}
```

---

## 三、让 LLM 拆：提示词怎么写

### 3.1 分解提示词

```python
DECOMPOSE_PROMPT = """你是查询分析助手。请判断下面的用户问题是否需要拆解，并输出拆解结果。

判断规则：
- 如果问题只包含一个明确的检索目标，输出 original 类型，sub_questions 只有原问题。
- 如果问题包含多个可以独立检索的子目标，输出 parallel 类型。
- 如果子问题的检索需要先知道前面子问题的答案，输出 sequential 类型。
- 最多拆 5 个子问题，超出就合并相近的。

每个子问题必须：
1. 独立完整，不含"它/这个/上述"等需要上下文的指代；
2. 只描述检索目标，不要试图回答问题。

用户问题：{question}

严格输出 JSON，不要加任何解释：
{{"type": "...", "sub_questions": [{{"id": 1, "q": "...", "depends_on": []}}]}}"""
```

### 3.2 用结构化输出保证格式稳定

靠提示词让模型"输出 JSON"经常翻车。用 LangChain 的 `with_structured_output` 强制约束更稳：

```python
from pydantic import BaseModel, Field
from typing import Literal, List

class SubQuestion(BaseModel):
    id: int = Field(description="子问题编号，从 1 开始")
    q: str = Field(description="子问题的完整表述")
    depends_on: List[int] = Field(
        default_factory=list,
        description="依赖的子问题编号列表，无依赖则为空"
    )

class Decomposition(BaseModel):
    type: Literal["original", "parallel", "sequential"] = Field(
        description="分解类型"
    )
    sub_questions: List[SubQuestion] = Field(description="子问题列表")

decomposer = llm.with_structured_output(Decomposition)
result = decomposer.invoke(DECOMPOSE_PROMPT.format(question=user_q))
```

这样拿到的就是可以直接用的 Python 对象，不用写脆弱的正则解析。

### 3.3 一个必须做的兜底

LLM 偶尔会拆出 10 个子问题，或者拆出无法检索的空问题。加一层校验：

```python
def sanitize(d: Decomposition, max_n: int = 5) -> Decomposition:
    subs = [s for s in d.sub_questions if s.q.strip()]
    # 超过上限，截断
    subs = subs[:max_n]
    # 依赖编号必须小于自身编号，且指向存在的 id
    valid_ids = {s.id for s in subs}
    for s in subs:
        s.depends_on = [i for i in s.depends_on if i < s.id and i in valid_ids]
    # 一个都不剩就退回原问题
    if not subs:
        return Decomposition(type="original",
                             sub_questions=[SubQuestion(id=1, q=user_q)])
    return Decomposition(type=d.type, sub_questions=subs)
```

---

## 四、并行分解的执行

并行子问题没有依赖，可以一把并发掉：

```python
from concurrent.futures import ThreadPoolExecutor

def parallel_answer(subs: List[SubQuestion], k: int = 4):
    def one(s):
        docs = retriever.invoke(s.q)[:k]
        return s.id, s.q, docs

    with ThreadPoolExecutor(max_workers=min(len(subs), 8)) as pool:
        results = list(pool.map(one, subs))

    # 汇总：把每个子问题的证据打上来源标记
    ctx_parts = []
    for sid, q, docs in results:
        block = "\n\n".join(d.page_content for d in docs)
        ctx_parts.append(f"[子问题 {sid}] {q}\n支撑材料：\n{block}")

    context = "\n\n---\n\n".join(ctx_parts)
    return context, results
```

关键设计：**给每段证据打上子问题编号和子问题原文**。这样生成阶段大模型知道每段材料对应哪个子问题，不会张冠李戴。我实测过，标注 vs 不标注，在比较类问题上答案准确率差了接近 20 个百分点。

生成时的提示词也要相应调整：

```python
ANSWER_PROMPT = """基于下面按子问题组织的材料，回答用户问题。

要求：
- 逐个子问题作答，最后给出综合结论；
- 只使用材料中的信息，材料没提到的明确说"材料未提及"；
- 每个关键结论用 [子问题 N] 标注来源。

材料：
{context}

用户问题：{question}"""
```

---

## 五、串行分解的执行

串行要有状态传递。核心是一个循环，每轮把已有答案喂回去：

```python
def sequential_answer(subs: List[SubQuestion], k: int = 4):
    answers = {}   # id -> 答案文本

    for s in sorted(subs, key=lambda x: x.id):
        # 用已得到的答案替换占位符
        q = s.q
        for dep in s.depends_on:
            q = q.replace("{q%d_result}" % dep, answers.get(dep, "未知"))

        docs = retriever.invoke(q)[:k]
        ctx = "\n\n".join(d.page_content for d in docs)

        ans = llm.invoke(
            f"基于材料回答问题，只答要点，不超过 100 字。\n材料：{ctx}\n问题：{q}"
        ).content
        answers[s.id] = ans.strip()

    return answers
```

placeholder 替换这步是串行分解的灵魂。`depends_on` 声明了依赖，但子问题文本里怎么引用？我用的是 `{q1_result}` 这种占位符，执行时替换成前面的答案。

### 5.1 中间答案要短

每轮让 LLM 生成详细答案是浪费。中间步骤只取要点（100 字以内），最后一轮才展开。这能省下大量 token，也减少中间步骤出错被放大的风险。

### 5.2 中间步骤失败的传播问题

串行分解最大的风险是**错误传播**：第 1 步检索错了，第 2 步基于错误答案检索，第 3 步更错，最后给出一个自信的错答案。

缓解办法：

- 中间步骤检索不到内容时，明确标记"未找到"，不要硬答；
- 最后一轮生成时，把中间步骤的置信度也传进去，让模型知道哪些基础不牢；
- 给串行分解设最大轮次（我一般设 3），超了就降级成并行或者单条检索。

---

## 六、什么时候不该拆

查询分解不是免费的。每次拆分至少多一次 LLM 调用，并行分解还要多 N 次检索，串行分解更是 N 轮完整流程。以下情况别拆：

### 6.1 简单事实查询

> "Python 里怎么把字符串转小写？"

一个子问题就够了。拆了纯属浪费，还可能拆出噪声。

**判据**：让 LLM 判断时，明确要求"只包含一个检索目标就输出 original"。实测大约 60% 的真实查询会被判为 original，这部分直接走快速路径。

### 6.2 知识库本身覆盖不足时

如果知识库只有 200 个 chunk，拆成 5 个子问题去检索，很可能 3 个检索结果为空。这时候拆了反而暴露出"知识不全"，答案支离破碎。

**判据**：知识库规模小（< 1000 chunk）时，优先做查询改写而不是分解。

### 6.3 延迟预算不够

并行分解：1 次分解 + N 次并发检索 + 1 次生成 ≈ 1.5~2.5s
串行分解（3 轮）：3 × (检索 + 生成) ≈ 4~6s

客服场景 2.5s 勉强接受，6s 基本不可接受。串行分解要么用在异步场景（比如报告生成），要么就别用。

---

## 七、效果实测

我在一个技术文档库（1.8 万 chunk）上跑过一组对比，评测集 200 条，其中 80 条是人工标注的复杂问题：

| 方案 | 简单题准确率 | 复杂题准确率 | 平均延迟 | 平均 token |
|------|------------|------------|---------|-----------|
| 单条检索 | 0.82 | 0.41 | 0.6s | 2.1k |
| + 多查询 | 0.82 | 0.52 | 2.1s | 2.4k |
| + 并行分解 | 0.80 | **0.74** | 2.6s | 5.8k |
| + 串行分解（复杂题） | 0.80 | **0.79** | 5.4s | 9.2k |

几个观察：

1. **简单题上分解没有收益，甚至略降**（0.82 → 0.80）。这印证了"不该拆就别拆"。
2. **复杂题上分解收益巨大**（0.41 → 0.74），这是分解的主战场。
3. 串行比并行又高了 5 个点，但延迟翻倍、token 涨 60%。性价比要按场景算。

注意第二行：多查询也能提升复杂题（0.41→0.52），但不如分解。因为多查询只改变了表述，没有改变问题的结构——**多查询是"换说法"，分解是"拆结构"**，后者对复杂问题更对症。

---

## 八、落地建议

1. **先做分类**：入口加一个轻量分类器，判断 original / parallel / sequential。简单题直接放行，别浪费算力。
2. **并行优先**：能用并行解决的不要上串行。串行只在确认存在依赖时用。
3. **证据带编号**：把子问题编号和原文一起传给生成阶段，准确率提升明显。
4. **限深限宽**：最多 5 个子问题，串行最多 3 轮。超了降级。
5. **失败可降级**：分解失败或中间步骤检索为空时，回退到单条检索 + 多查询，总比空手而归好。
6. **建立复杂问题评测子集**：整体准确率会被大量简单题稀释，单独看复杂题子集才能判断分解是否有效。

---

## 小结

- 查询分解解决的是**问题结构**层面的缺陷，和调 embedding、调 chunk 不是一个维度的事。
- 两种形态：并行（无依赖，并发检索）和串行（有依赖，依次检索）。并行是默认选择，串行是代价高昂的补充。
- 用 `with_structured_output` 强制 JSON 输出，别靠提示词赌格式；拿到结果后必须做校验和兜底。
- **简单题别拆**，拆了准确率可能还降；复杂题收益巨大（实测 0.41 → 0.74）。
- 证据要带子问题编号进生成阶段，这一步的收益比想象中大。

分解不是越细越好。它本质上是在"用更多检索轮次换更完整的证据覆盖"，什么时候这个交换划算，取决于你的问题分布和延迟预算。
