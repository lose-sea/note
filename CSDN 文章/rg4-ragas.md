# RAGAS 实战：一套能跑起来的 RAG 自动评测框架

RAG 做出来之后，最现实的问题是：**怎么知道它好不好？** 靠人工看几条答案，很容易被"看起来挺流畅"骗过去。

RAGAS（Retrieval-Augmented Generation Assessment）是目前最常用的开源 RAG 评测框架。它的价值在于：不需要人工给每篇文档标注相关性，只靠"问题 + 答案 + 上下文 + 标准答案"就能算出一组有解释力的指标。

这一篇从实战角度讲：它有哪些指标、怎么跑起来、结果怎么读、以及它有哪些坑。

---

## 一、RAGAS 是什么

### 1.1 定位

RAGAS 不是一个端到端的测试平台，它是一套**指标计算库**。你给它数据，它返回分数。

它的核心设计思路是：**用 LLM 当评判员（LLM-as-a-judge）**，把原本需要人工标注的环节自动化。

### 1.2 输入输出

**最小输入**（四元组）：

```python
{
    "question":      "用户问题",
    "answer":        "系统生成的答案",
    "contexts":      ["召回的文档1", "召回的文档2", ...],
    "ground_truth":  "标准答案"      # 部分指标需要
}
```

**输出**：一组 0~1 的分数。

### 1.3 指标全景

| 指标 | 需要 ground_truth | 评估对象 | 回答什么问题 |
|------|------------------|---------|------------|
| **Faithfulness** | 否 | 生成 | 答案有没有编造？ |
| **Answer Relevancy** | 否 | 生成 | 答案切题吗？ |
| **Context Precision** | 是 | 检索 | 召回的有用吗、排序好吗？ |
| **Context Recall** | 是 | 检索 | 需要的信息召回了吗？ |
| Context Entities Recall | 是 | 检索 | 关键实体覆盖了吗？ |
| Answer Similarity | 是 | 生成 | 和标准答案语义像吗？ |
| Answer Correctness | 是 | 生成 | 答案对吗？（语义+事实加权） |

前四个是核心，绝大多数场景够用。

**关键区分**：
- 不需要 ground_truth 的指标（Faithfulness、Answer Relevancy）→ 可以**在线监控真实流量**
- 需要 ground_truth 的 → 只能**离线评测**

这个区分很重要。很多线上系统只能跑前两个，所以离线评测集的建设不能省。

---

## 二、安装与第一个例子

### 2.1 安装

```bash
pip install ragas datasets
```

RAGAS 需要配置一个评判用的 LLM。默认用 OpenAI：

```python
import os
os.environ["OPENAI_API_KEY"] = "sk-xxx"
```

用其他模型（比如国内模型、本地模型）需要自定义，后面讲。

### 2.2 完整示例

```python
from ragas import evaluate
from ragas.metrics import (
    faithfulness,
    answer_relevancy,
    context_precision,
    context_recall,
)
from datasets import Dataset

data = {
    "question": [
        "公司差旅一线城市住宿标准是多少？",
        "超标部分怎么申请特批？",
    ],
    "answer": [
        "一线城市住宿上限为 500 元/晚。",
        "超标需提前提交特批申请，由部门负责人审批。",
    ],
    "contexts": [
        [
            "差旅标准（2023版）：一线城市住宿上限 500 元/晚，二线城市 350 元/晚。",
            "差旅报销流程：提交发票 → 部门审批 → 财务复核。",
        ],
        [
            "超标部分需提前提交特批申请，由部门负责人审批后方可报销。",
            "特殊情况可事后补充说明。",
        ],
    ],
    "ground_truth": [
        "一线城市住宿上限 500 元/晚。",
        "超标需提前提交特批申请，由部门负责人审批。",
    ],
}

ds = Dataset.from_dict(data)
result = evaluate(ds, metrics=[
    faithfulness, answer_relevancy,
    context_precision, context_recall,
])

print(result)
```

输出大致是：

```
{'faithfulness': 0.9500, 'answer_relevancy': 0.8731,
 'context_precision': 0.8333, 'context_recall': 1.0000}
```

### 2.3 转成 DataFrame 细看

```python
df = result.to_pandas()
print(df[["question", "faithfulness", "context_recall"]])
```

能看到每条样本的分数，找出具体哪些题拖了后腿。这比只看平均分有用得多——**平均分会被大量简单题掩盖问题**。

---

## 三、每个指标在算什么

### 3.1 Faithfulness（忠实度）

**算法**：把答案拆成原子陈述 → 逐条判断能否从 contexts 推出 → 被支撑数 / 总数。

```python
# 答案："一线城市 500 元，超标需部门负责人审批。"
# 陈述1: 一线城市住宿上限 500 元     → 上下文支撑 ✓
# 陈述2: 超标需部门负责人审批        → 上下文支撑 ✓
# Faithfulness = 2/2 = 1.0
```

**注意**：它只管"照没照材料说"，不管材料本身对错。详细讨论见我写的忠实度专篇。

### 3.2 Answer Relevancy（答案相关性）

**算法**（这个比较巧妙）：
1. 用答案**反向生成**若干个问题（假设答案是对某个问题的回答）
2. 计算这些生成问题与原始问题的相似度
3. 取平均

**原理**：如果答案切题，那么从答案反推出来的问题，应该和原问题很接近。如果答案跑题了，反推的问题也会跑偏。

```python
# 原问题："一线城市住宿标准是多少？"
# 答案："公司成立于 2010 年，总部在北京。"
# → 反推问题："公司什么时候成立的？" / "公司总部在哪？"
# → 与原问题相似度很低
# → Answer Relevancy 低
```

**优点**：不需要 ground_truth，可以在线跑。
**缺点**：答案很短或很长时，反推会不稳定。

### 3.3 Context Precision（上下文精确率）

**算法**：判断每篇上下文是否对得出 ground_truth 有贡献 → 按排名加权平均。

它惩罚"有用的排在后面"。详见我写的上下文精确率与召回率专篇。

### 3.4 Context Recall（上下文召回率）

**算法**：把 ground_truth 拆成陈述 → 判断每条能否从 contexts 推出 → 能推出数 / 总数。

---

## 四、用自定义模型跑

用 OpenAI 之外的模型（国内模型、本地模型），需要自己接。

### 4.1 用 LangChain 的 LLM 包装

```python
from ragas.llms import LangchainLLMWrapper
from langchain_openai import ChatOpenAI

# 例如接一个兼容 OpenAI 接口的中转/本地服务
judge_llm = ChatOpenAI(
    model="qwen-plus",
    openai_api_key="xxx",
    openai_api_base="https://your-endpoint/v1",
    temperature=0,
)

ragas_llm = LangchainLLMWrapper(judge_llm)
```

### 4.2 传入 evaluate

```python
from ragas import evaluate

result = evaluate(
    ds,
    metrics=[faithfulness, context_recall],
    llm=ragas_llm,
)
```

### 4.3 embedding 也要换（Answer Relevancy 需要）

```python
from ragas.embeddings import LangchainEmbeddingsWrapper
from langchain_community.embeddings import HuggingFaceEmbeddings

emb = HuggingFaceEmbeddings(model_name="BAAI/bge-small-zh-v1.5")
ragas_emb = LangchainEmbeddingsWrapper(emb)

result = evaluate(ds, metrics=[answer_relevancy],
                  llm=ragas_llm, embeddings=ragas_emb)
```

### 4.4 一个重要的注意事项

**评判模型不能太弱。** 用 7B 模型去评判 GPT-4 生成的答案，判定本身就不可靠。经验法则：**评判模型的能力应不低于被测系统的生成模型**。

如果预算有限，折中方案是：用便宜模型做**相对比较**（A 方案 vs B 方案），而不是看绝对分数。

---

## 五、结果怎么读

### 5.1 建立基线表

改动前后各跑一次，填表对比：

| 配置 | Faithfulness | Answer Relev. | Ctx Precision | Ctx Recall | 平均延迟 |
|------|-------------|---------------|---------------|------------|---------|
| 基线（top_k=5，无重排） | 0.72 | 0.81 | 0.48 | 0.66 | 0.9s |
| + 重排 | 0.79 | 0.83 | **0.71** | 0.66 | 1.6s |
| + 混合检索 | 0.80 | 0.84 | 0.68 | **0.83** | 1.7s |
| + 提示词硬约束 | **0.91** | 0.85 | 0.68 | 0.83 | 1.7s |

这样一眼能看出每个改动的收益：
- 重排提精确率（0.48→0.71）
- 混合检索提召回率（0.66→0.83）
- 提示词约束提忠实度（0.72→0.91）

**定位很清晰，不会瞎调。**

### 5.2 不要只看平均分

按分数分布看：

```python
df = result.to_pandas()
print(df["faithfulness"].describe())
print("\n最差的 5 条：")
print(df.nsmallest(5, "faithfulness")[["question", "faithfulness"]])
```

**低分的那些样本才是金矿**。把它们挑出来人工看，往往能发现系统性的失败模式（比如某一类问题全都答不好）。

### 5.3 关注相对变化

LLM 判定有噪声，单次跑分波动 ±0.05 正常。**判断改动是否有效，看变化幅度是否超过 0.05~0.1**，别为 0.02 的差异纠结。

---

## 六、常见坑

### 6.1 ground_truth 写法影响巨大

Context Recall 会把 ground_truth 拆成陈述。如果 ground_truth 写得太啰嗦：

```python
# ❌ 糟糕
"根据《差旅管理制度》第三章第二节的规定，结合公司实际情况，一线城市的住宿标准被设定为每晚 500 元人民币。"

# ✅ 好
"一线城市住宿上限 500 元/晚。"
```

啰嗦的版本会拆出很多无关陈述（"根据制度第三章"这种），拉低召回率，而且不稳定。

**原则：ground_truth 只写事实点，不写套话。**

### 6.2 contexts 传错格式

`contexts` 必须是**列表的列表**——每个问题对应一个文档列表：

```python
# ✅ 正确
"contexts": [["doc1", "doc2"], ["doc3", "doc4"]]

# ❌ 错误（少一层）
"contexts": ["doc1", "doc2"]
```

这个错误很常见，会报奇怪的错。

### 6.3 版本兼容问题

RAGAS 更新比较快，API 在不同版本间有变化。常见问题：

- `EvaluationDataset` vs 直接传 `Dataset`
- 指标导入路径变化（`ragas.metrics` vs `ragas.metrics.critique`）
- `llm=` 参数的类型要求（有的版本要 wrapper，有的不要）

**建议：固定版本号**，写进 requirements：

```
ragas==0.1.x
```

### 6.4 成本

每个样本的四个指标，大约需要 5~15 次 LLM 调用。跑 200 条样本、用 GPT-4 级别模型，成本可能在几十到上百元。

**控制成本的办法**：
- 用小一点的评测集（50~100 条足够发现趋势）
- 分层抽样：简单题少抽，难例多抽
- 日常回归用便宜模型，关键决策时才用贵模型

### 6.5 中文场景表现下降

RAGAS 的提示词是英文的，中文文本的**陈述拆分**质量会下降——中文标点、无空格分词，都让 LLM 拆句子更困难。

**缓解**：
1. 自定义提示词（RAGAS 支持传入自定义 prompt）
2. 用中文能力强的评判模型
3. 对中文场景，考虑自己实现简版指标（参考我写的忠实度篇）

---

## 七、和其他评测方案怎么选

| 方案 | 优点 | 缺点 | 适用 |
|------|------|------|------|
| **RAGAS** | 开箱即用、指标成体系、社区活跃 | 需 LLM 成本高、有噪声、中文打折 | 通用首选 |
| 传统 IR 指标（P@K/MRR） | 便宜、可复现、无噪声 | 需要文档级相关性标注 | 有标注时 |
| 自建 LLM 评判 | 完全可控、可定制标准 | 要自己写、要自己验证可靠性 | 有特殊判定标准 |
| 人工评测 | 最可靠 | 贵、慢、不可规模化 | 关键决策、抽检复核 |
| 业务指标（点击率/解决率） | 真正反映价值 | 滞后、干扰因素多 | 线上长期监控 |

**我的建议组合**：

1. **离线**：RAGAS 四指标跑评测集，用于迭代决策
2. **在线**：只跑不需要 ground_truth 的指标（Faithfulness、Answer Relevancy），抽样监控
3. **定期**：人工抽检 50 条，校验自动指标是否可信
4. **长期**：看业务指标（用户是否点了"有用"、是否转人工）

**自动指标不能替代人工抽检。** 它们是指向器，不是终审。

---

## 八、一个可复制的工作流

```python
# evaluate_rag.py
import json
from ragas import evaluate
from ragas.metrics import (
    faithfulness, answer_relevancy,
    context_precision, context_recall,
)
from datasets import Dataset

def load_eval_set(path):
    return json.load(open(path, encoding="utf-8"))

def collect_predictions(eval_set, pipeline):
    rows = {"question": [], "answer": [], "contexts": [], "ground_truth": []}
    for item in eval_set:
        ans, ctxs = pipeline.query(item["question"])
        rows["question"].append(item["question"])
        rows["answer"].append(ans)
        rows["contexts"].append(ctxs)
        rows["ground_truth"].append(item["ground_truth"])
    return Dataset.from_dict(rows)

def main():
    eval_set = load_eval_set("eval_set.json")
    ds = collect_predictions(eval_set, my_pipeline)

    result = evaluate(ds, metrics=[
        faithfulness, answer_relevancy,
        context_precision, context_recall,
    ])

    # 1. 打印总分
    print(result)

    # 2. 保存明细
    df = result.to_pandas()
    df.to_csv("eval_result.csv", index=False, encoding="utf-8-sig")

    # 3. 挑出最差样本
    df["min_score"] = df[[
        "faithfulness", "answer_relevancy",
        "context_precision", "context_recall"
    ]].min(axis=1)
    worst = df.nsmallest(10, "min_score")
    worst.to_csv("worst_cases.csv", index=False, encoding="utf-8-sig")
    print("\n最差 10 条已保存到 worst_cases.csv")

if __name__ == "__main__":
    main()
```

每次改动 pipeline 就跑一次，对比 `eval_result.csv`，看 `worst_cases.csv` 找失败模式。这个循环跑几轮，系统质量会有明显提升。

---

## 小结

- RAGAS 是一套**基于 LLM-as-judge 的 RAG 评测指标库**，核心四个指标：Faithfulness、Answer Relevancy、Context Precision、Context Recall。
- **前两个不需要 ground_truth，可以在线监控；后两个需要，只能离线评测**。
- 用法很直接：准备四元组数据 → `evaluate()` → 读分数。但要注意 contexts 是"列表的列表"、ground_truth 要简洁。
- **看明细比看平均分重要**。挑出最差的样本人工分析，才能发现系统性失败模式。
- 主要坑：LLM 判定有噪声（±0.05）、成本高、中文场景陈述拆分质量下降、版本 API 不稳定（**固定版本号**）。
- 它不能替代人工抽检。**自动指标 + 定期人工复核**才是可靠组合。

一句话：**没有评测就没有优化**。RAGAS 的意义不在于分数本身，而在于它让你能回答"这次改动到底有没有用"。
