# LangSmith 评测实战：搭一套评测集，盯住每次改动

模型换了、prompt 改了、检索参数调了——每次改动之后，你怎么知道 Agent 是变好了还是变差了？靠肉眼抽查几条 case，跟"我觉得应该没问题"是同义词。这篇文章讲用 LangSmith 搭一套真正能跑的评测闭环：数据集怎么攒、评测器怎么写、结果怎么读，以及线上流量怎么回流成评测集。

## 为什么评测是 Agent 工程的核心设施

传统软件改动的对错由单元测试裁定，但 LLM 应用的输出是概率性的，"对"变成了一条光谱。没有评测体系，你会陷入两种灾难循环：

- **不敢改**：每次调 prompt 都像在雷区跳舞，只能祈祷，于是系统永远停留在第一版。
- **盲改**：改完一看 demo 挺满意就上线，三天后用户投诉才发现某个场景全崩。

LangSmith 这类工具解决的就是这件事：把"改动 → 对比 → 决策"变成一个有数据支撑的流程。

## 第一步：攒数据集，从二十条开始

评测集（Dataset）不是测试集plus，它的核心是**覆盖真实分布**。新手常犯的错是一上手就要"覆盖所有场景"，憋两周憋不出来。正确的起步姿势是二十条黄金 case，来源按优先级：

1. **线上真实请求采样**：从日志里挑用户真实问过的，这是唯一能保证分布不偏的来源。
2. **已知失败案例**：投诉过的、线上出过事的，每条都是回归防线。
3. **边界和对抗样本**：空输入、超长输入、中英混杂、多意图混杂。
4. **脑补的典型案例**：锦上添花，别当主力。

每条 case 要有两部分：**输入**（问题 + 必要的上下文）和**参考答案**（outputs）。参考答案有个松紧光谱：最终答案可以严格比对就写精确值；开放生成类写不出标准答案，就写"要点清单"（rubric），交给 LLM 裁判按要点打分。

```python
from langsmith import Client

client = Client()

# 建数据集
dataset = client.create_dataset("rag-prod-v1", description="生产采样 + 历史故障")

# 逐条灌入
examples = [
    {
        "inputs": {"question": "Pandas 里怎么按分组取 topN？"},
        "outputs": {"answer": "groupby().apply(lambda g: g.nlargest(n, col)) 或 sort_values + groupby.head(n)"},
    },
    {
        "inputs": {"question": "为什么我的 join 结果行数变多了？"},
        "outputs": {"answer": "说明连接键不是唯一的，产生了笛卡尔式膨胀，应先检查两侧键的唯一性"},
    },
    # ...边界样本
    {
        "inputs": {"question": ""},
        "outputs": {"answer": "应提示用户补充问题，而不是强行生成答案"},
    },
]
client.create_examples(dataset_id=dataset.id, examples=examples)
```

**数据集要版本化**。在 LangSmith 里用 `dataset-xxx` 的固定 ID，别每次重新建。改了 prompt 就用同一份数据集跑，结果才可比。case 本身要演进——线上发现新 badcase，回流进来（后面讲怎么回流）。

## 第二步：写评测器，三种手段混用

LangSmith 的 evaluator 就是个函数，吃 `(run, example)` 吐分数。实战里三类手段混着用：

**规则型**：适合有唯一答案的。字符级相似度、是否包含关键数字、JSON 是否合法。快、便宜、稳，能用规则的地方优先用。

```python
def exact_match_judge(run, example):
    pred = run.outputs.get("answer", "")
    ref = example.outputs.get("answer", "")
    # 归一化：小写、去空白、数字容忍千分位
    norm = lambda s: re.sub(r"[\s,]", "", s.lower())
    return {"key": "exact_match", "score": 1.0 if norm(ref) in norm(pred) else 0.0}
```

**LLM 裁判**：开放生成的主力裁判。关键是把评分标准写成可执行的 rubric，而不是"好不好"：

```python
JUDGE_PROMPT = """你是严格的评测员。根据要点清单判断回答质量。
问题：{question}
参考答案要点：{reference}
待评回答：{prediction}

逐条核对要点，全部覆盖=2，覆盖一半以上=1，错误或答非所问=0。
只输出 JSON: {{"score": <0/1/2>, "reason": "一句话说明"}}"""

def llm_judge(run, example):
    resp = chat_model.invoke(JUDGE_PROMPT.format(
        question=example.inputs["question"],
        reference=example.outputs["answer"],
        prediction=run.outputs.get("answer", ""),
    ))
    data = json.loads(resp.content)
    return {"key": "rubric_score", "score": data["score"] / 2, "comment": data["reason"]}
```

LLM 裁判的已知坑早点防：裁判自己也会偏爱长答案（偏好 verbose），对含错误数字的答案可能视而不见。所以裁判 prompt 里要显式说"长度不影响评分""数字必须与要点一致"。

**检索质量专用**：RAG 系统要单独评检索层——召回的文档里有多少是相关的。LangSmith 里把 context 放到 run 的 outputs 里，写个裁判判断每条文档和问题的相关性。检索层得分低，生成层再强也白搭，**分层诊断比看总分有用**。

## 第三步：跑评测、读结果

```python
from langsmith.evaluation import evaluate

results = evaluate(
    lambda inputs: my_chain.invoke(inputs),   # 被测对象：任意函数/lcel chain
    data=dataset_name,
    evaluators=[exact_match_judge, llm_judge],
    experiment_prefix="rag-v2-prompt-a",
    max_concurrency=8,
)
```

跑完在 LangSmith 控制台看三样东西：

1. **每个评测器的平均值和分布**。平均 0.85 可能是"80% 全对 + 20% 全错"，也可能是均匀的 0.85——前者是坏味道，要去看失败样本。
2. **失败样本的归因**。点进得分最低的 case 看完整 trace：问题在哪一环坏的？是检索没召回、还是模型胡说、还是 prompt 没约束住？**评测的价值一半在分数，一半在 trace**。
3. **和上个 experiment 的对比**。LangSmith 同一数据集的不同 run 可以直接对比，分数涨了跌了一眼的事。改动能不能合入，这里说了算。

## 第四步：把线上流量接回来

评测集最大的敌人是"过期"——你按上线时的分布攒的集子，半年后用户问法早变了，分数再高也不代表现在没问题。闭环的最后一环是**线上 badcase 自动回流**：

```python
# 线上给每条回答附反馈入口
@app.post("/feedback")
def feedback(msg_id: str, thumb: int, comment: str = ""):
    client.create_feedback(
        run_id=msg_id,           # 请求时记录的 LangSmith run id
        key="user_thumb",
        score=thumb,             # 1 好评 / -1 点踩
        comment=comment,
    )
```

点踩的回答自动流入一个"待标注队列"，人工每周过一遍：确认是 badcase 的，补上参考答案，加进数据集。这样评测集跟着真实需求长，系统越用越稳。

## 接入 CI：让评测成为门禁

整套东西最后落在 CI 里才算闭环。GitHub Actions 里 PR 触发一次评测：

```yaml
- name: Run eval suite
  run: python eval/run.py --experiment-prefix "pr-${{ github.event.number }}"
- name: Check thresholds
  run: python eval/check_gate.py --min-rubric 0.8 --max-regression 0.03
```

`check_gate.py` 的逻辑：当前 experiment 的 rubric 均值不能低于 0.8，且相比上一个 experiment 回落不能超过 0.03。不过关的 PR 不许合。**门禁的价值在于把"改坏了再发现"变成"改坏了合不了"**，配合前面的 mock 测试和快照测试，才构成完整的测试金字塔。

## 结语

评测不是奢侈品，是 LLM 应用从 demo 走向生产的入场券。攒二十条真实 case 起步，规则 + LLM 裁判 + 检索分层三类评测器混用，线上点踩回流养数据集，最后用 CI 门禁把标准立起来。有了这套设施，每一次改动你都有底气说"变好了"——这才是工程化的 Agent 和玩具的分水岭。
