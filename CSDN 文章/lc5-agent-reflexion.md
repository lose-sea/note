# Reflexion：让 Agent 从自己的失败里学习

一个 Agent 解数学题，第一次答案错了。你把正确答案告诉它，它说「明白了」。然后你换个类似的题，它又用同样的错误方式解——因为它**什么都没有学到**。

这是纯 ReAct 的根本缺陷：每次执行都是从零开始，之前的失败没有留下任何痕迹。

Reflexion（Shinn et al., 2023）提了一个很直接的思路：**让 Agent 在执行失败后，生成一段「反思」存进记忆，下一次尝试时带上这段反思。** 听起来简单，但它把 Agent 的「经验」变成了可积累的东西。

这一篇讲清楚它的工作机制、为什么有效、工程上怎么落地、以及它和微调的关系。

---

## 一、为什么失败不会自动变成经验

### 1.1 Agent 的「失忆」结构

ReAct 循环里，失败信息是这样处理的：

```
尝试1：搜索"北京天气" → 工具返回空
       模型：可能关键词不对，改搜"北京 今日天气" → 还是空
       模型：再试试"北京市天气" → 空
       模型：放弃，回答"查不到"
```

这次失败**完全消失在对话历史的末尾**。下次用户问「上海天气」，模型又是从「搜索"上海天气"」开始，重复同样的弯路。

问题在于：**模型看到过失败，但没有把失败转化成「下次该怎么做」的规则。**

### 1.2 反思的作用

Reflexion 增加了一步：**在任务失败后，让模型显式地分析「为什么会失败，下次该怎么改」**，并把这段分析写进一个跨尝试的记忆。

```
尝试1失败 → 反思："搜索天气类信息应该先确认城市名，再用城市名+日期作为查询词；
               纯城市名查询容易返回旅游介绍页而不是天气数据。"
                 ↓
尝试2时，上下文中多了这段反思 → 模型第一步就用了正确策略
```

关键区别在于：**反思是「规则」，失败记录是「事件」。** 规则可以迁移到相似任务上，事件不能。

---

## 二、Reflexion 的工作流程

### 2.1 三角色架构

Reflexion 论文里定义了三个角色，工程上可以简化但思路要保留：

```
┌─────────────┐
│   Actor     │  ← 执行任务（就是普通的 ReAct Agent）
└──────┬──────┘
       │ 失败
       ▼
┌─────────────┐
│  Evaluator  │  ← 打分：这次执行成功了吗？
└──────┬──────┘
       │ 失败
       ▼
┌─────────────┐
│  Self-Reflect│ ← 生成反思，写入记忆
└──────┬──────┘
       │
       ▼
   带着新反思重试（最多 N 次）
```

### 2.2  Evaluator：怎么判断成功

这一步是**整个机制的瓶颈**。反思的质量完全取决于「是否失败」判断得准不准。

三种判断方式，按可靠性排：

**方式一：可验证的信号（最可靠）**

```python
# 代码能跑的：直接跑测试
if test_passed:
    return {"success": True, "score": 1.0}

# SQL 能跑的：检查执行结果
try:
    rows = db.execute(agent_sql)
    if rows and matches_expected_schema(rows):
        return {"success": True}
except SQLSyntaxError as e:
    return {"success": False, "error": str(e), "score": 0.0}
```

**方式二：结构化校验**

```python
def validate(output: dict) -> dict:
    errors = []
    if not output.get("summary"):
        errors.append("缺 summary 字段")
    if len(output.get("items", [])) < 3:
        errors.append("items 少于 3 条")
    return {"success": not errors, "errors": errors}
```

**方式三：LLM 评判（兜底，但有噪声）**

```python
EVAL_PROMPT = """评判下面的回答是否合格。

任务要求：{task}
实际输出：{output}

合格标准：
1. 完整回应了任务要求
2. 事实正确，没有编造
3. 格式符合要求

输出 JSON：{{"success": true/false, "reason": "..."}}"""
```

**能用方式一就别用方式三。** LLM 评判的随机性会让反思跟着抖动——这次说失败，下次说成功，Agent 就学乱了。

### 2.3 Self-Reflect：反思提示词

```python
REFLECT_PROMPT = """任务失败了。请分析原因并给出下次的改进策略。

【原始任务】
{task}

【执行轨迹】
{trajectory}

【失败原因】
{failure_reason}

要求：
1. 只分析可改进的具体行为，不要怪外部环境（"数据不全""运气不好"不算）；
2. 产出一条可复用的规则，格式："当<场景>时，应该<做法>，因为<理由>"；
3. 如果失败是任务本身无解（比如要求查不存在的数据），输出 "TASK_UNFEASIBLE"；
4. 不超过 150 字。

反思："""
```

注意第 2 条的格式约束。**自由发挥的反思很难复用**，「当…时，应该…」这种规则式表达，下次能直接套用。

第 3 条也很关键。有些失败不是 Agent 的错（要求查不存在的数据），这时候应该触发「任务不可行」而不是让 Agent 反复尝试。

### 2.4 带反思的重试

```python
def run_with_reflexion(task: str, max_attempts: int = 3):
    reflections = load_reflections(task)      # 历史上相似任务攒下的反思

    for attempt in range(max_attempts):
        history = build_history(reflections)  # 反思进系统提示或首条消息
        result = actor.invoke({"task": task, "messages": history})

        evaluation = evaluate(result, task)
        if evaluation["success"]:
            return result

        # 反思并入库
        new_reflection = self_reflect(task, result, evaluation["reason"])
        if new_reflection == "TASK_UNFEASIBLE":
            return {"error": "任务无解", "reason": evaluation["reason"]}
        reflections.append(new_reflection)
        save_reflection(task, new_reflection)   # 跨任务持久化

    return {"error": "多次尝试后仍失败", "reflections": reflections}
```

---

## 三、跨任务的记忆管理

尝试内的反思容易，难的是**跨任务积累**。如果每次任务都从零开始反思，那和没有 Reflexion 差别不大。

### 3.1 按任务类型检索反思

```python
def load_reflections(task: str, top_k: int = 3) -> list[str]:
    """检索历史上相似任务的反思。"""
    return reflection_store.search(task, top_k=top_k)

# 存的时候要带上任务的特征
reflection_store.add(
    text=reflection_text,
    metadata={"task_type": "sql_generation", "created": "2026-10-16"},
)
```

### 3.2 只保留有用的反思

反思库会无限膨胀，而且很多反思是**重复的、或者是错的**。要有清理机制：

```python
def prune_reflections(task_type: str):
    """按有效性清理反思库。"""
    for r in reflection_store.list(task_type):
        stats = reflection_stats[r.id]
        # 30 天内：被检索后任务成功率仍然低 → 这条反思没用
        if stats["uses"] >= 5 and stats["success_rate_after_use"] < 0.2:
            reflection_store.delete(r.id)
```

**一条反思如果被用了 5 次以上、后续成功率还是低于 20%，说明它是错的或无效的，该删。**

### 3.3 反思冲突的处理

两条反思可能矛盾：

- 「当查询返回为空时，应该扩大关键词范围」——来自「关键词太窄」的失败
- 「当查询返回为空时，应该检查数据源是否存在」——来自「数据源配错」的失败

两条都对，但适用条件不同。**解决方案是让反思带上触发条件**，而不是写通用的规则：

```
✅ "当查询结果为空且关键词很短（<4字）时，应该扩展为同义词组合，因为短词匹配范围过窄。"
✅ "当查询结果为空且确认参数正确时，应该先检查数据源连通性，因为曾遇到连接超时被静默吞掉的情况。"
```

条件越具体，反思越不容易互相打架。

---

## 四、工程落地：和现有 Agent 的结合

### 4.1 在 LangGraph 里实现

```python
from langgraph.graph import StateGraph, START, END
from typing import TypedDict

class State(TypedDict):
    task: str
    messages: list
    reflections: list[str]
    attempt: int
    success: bool

def actor_node(state: State):
    result = actor.invoke({
        "task": state["task"],
        "messages": build_with_reflections(state["messages"], state["reflections"]),
    })
    return {"messages": result["messages"], "attempt": state["attempt"] + 1}

def evaluator_node(state: State):
    ok = evaluate(state["messages"][-1], state["task"])
    return {"success": ok["success"], **ok}

def reflect_node(state: State):
    r = self_reflect(state["task"], state["messages"])
    reflections = state["reflections"] + [r]
    return {"reflections": reflections}

def route(state: State):
    if state["success"]:
        return "end"
    if state["attempt"] >= 3:
        return "end"
    return "reflect"

builder = StateGraph(State)
builder.add_node("actor", actor_node)
builder.add_node("evaluator", evaluator_node)
builder.add_node("reflect", reflect_node)
builder.add_edge(START, "actor")
builder.add_edge("actor", "evaluator")
builder.add_conditional_edges("evaluator", route, {"end": END, "reflect": "reflect"})
builder.add_edge("reflect", "actor")   # 带新反思重试

graph = builder.compile()
```

用图而不是 while 循环的好处：**每个 attempt 的状态可追溯，能拿到中间 trace**。调试时你能看到「第 2 次尝试用了第 1 次的哪条反思」。

### 4.2 和 Plan-and-Execute 结合

单独用 Reflexion 是「错了再改」。更好的用法是在**规划阶段**就用上历史反思：

```python
plan = planner.invoke({
    "task": task,
    "past_lessons": load_reflections(task, top_k=3),   # 关键
})
```

这样第一次尝试就避开历史上的坑，而不是试错三次才发现。**反思的最大价值不是「重试时带上」，而是「第一次就带上」。**

---

## 五、Reflexion 的边界

诚实地讲，这个技术有明确的适用边界。

### 5.1 有效的情况

- **任务可重复、结构相似**：同一类 SQL 生成、同一类数据清洗。第一次的反思能直接迁移。
- **失败原因是行为性的**：比如「第一步应该先确认参数」「不要假设数据源在线」。这类规则能泛化。
- **有可靠的 Evaluator**：这是前提，没有它一切都是空转。

### 5.2 无效甚至有害的情况

- **每次任务都是全新类型**：反思攒了一堆，没有一条能匹配上新任务，纯浪费 token。
- **失败是客观的**：API 挂了、数据源权限没批。反思「下次应该检查权限」屁用没有——该修的是流程，不是 Agent。
- ** Evaluator 不可靠**：如果用 LLM 评判且评判本身在抖，反思会自相矛盾，Agent 越学越糊涂。
- **实时性要求高的场景**：反思库检索 + 额外的反思调用会增加 1~2 秒延迟。

### 5.3 和微调的关系

有人会问：既然能从失败里学习，为什么不直接微调模型？

| | Reflexion | 微调 |
|---|-----------|------|
| 学习载体 | 提示词里的文本 | 模型权重 |
| 生效速度 | 立即 | 需要训练 |
| 成本 | 每次调用多几百 token | 一次性训练费用 |
| 可回滚 | 删库即可 | 要换模型版本 |
| 泛化性 | 只在相似任务上有效 | 更强的泛化，但可能过拟合 |

**实践中两者互补**：用 Reflexion 快速迭代，等积累了几百条高质量反思、且发现某些错误反复出现时，再把这些案例整理成微调数据集。**Reflexion 是微调的数据来源之一。**

---

## 六、一个完整的轻量实现

不用框架，几十行能跑：

```python
import json
from pathlib import Path

STORE = Path("reflections.jsonl")

def save_reflection(task: str, reflection: str):
    with STORE.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"task": task, "reflection": reflection,
                            "ts": datetime.now().isoformat()}, ensure_ascii=False) + "\n")

def load_similar(task: str, top_k=3) -> list[str]:
    if not STORE.exists():
        return []
    lines = [json.loads(l) for l in STORE.read_text(encoding="utf-8").splitlines()]
    # 简单实现：按共同词数排序。生产换向量检索
    scored = []
    t_words = set(task)
    for item in lines:
        overlap = len(t_words & set(item["task"]))
        scored.append((overlap, item["reflection"]))
    scored.sort(reverse=True)
    return [r for _, r in scored[:top_k]]

def attempt_with_reflexion(task: str, max_attempts=3):
    reflections = load_similar(task)

    for i in range(max_attempts):
        prompt = build_prompt(task, reflections=reflections)
        output = call_model(prompt)

        verdict = evaluate(task, output)          # 你自己的校验逻辑
        if verdict["success"]:
            return output

        reflection = generate_reflection(task, output, verdict["reason"])
        if reflection.startswith("TASK_UNFEASIBLE"):
            break
        save_reflection(task, reflection)
        reflections.append(reflection)

    return {"status": "failed", "last_output": output}
```

这套东西没有黑魔法，价值全在** Evaluator 的可靠性和反思提示词的质量**上。这两个调不好，Reflexion 就是空转。

---

## 七、常见误区

**误区一：反思写得太笼统。** 「下次要更仔细」「应该考虑更全面」——这种反思没有任何指导价值。必须是「当 X 时，做 Y」的规则式表达。

**误区二：不设 Evaluator 就用 LLM 评判。** 评判抖，反思就抖，Agent 学到的是噪声。

**误区三：把反思当万能药。** 如果失败原因是客观的（数据缺失、权限不足），反思一百次也没用。

**误区四：重试时清空历史重新开始。** 那等于没用反思。必须把历史反思显式放进下一次尝试的上下文。

**误区五：反思库只增不减。** 定期清理无效反思（用了多次后续成功率还是低的），否则库会变成垃圾场，检索时把垃圾也捞出来。

---

## 小结

- Reflexion 的核心是把**失败转化为可复用的规则**，而不是让它消失在对话历史里。「反思是规则，失败记录是事件」，规则才能迁移。
- 流程：**Actor 执行 → Evaluator 判定成败 → 失败则生成规则式反思 → 带反思重试（≤3 次）**。
- **Evaluator 的可靠性是瓶颈**，能用代码校验就别用 LLM 评判；评判抖动会让反思自相矛盾。
- 反思提示词要求：**规则式格式（"当X时应该Y，因为Z"）、带具体触发条件、可判定任务无解**。条件越具体，反思越不易互相冲突。
- 跨任务积累需要**检索 + 定期清理**（用了 5 次以上后续成功率仍低于 20% 的反思删除）。
- **最大价值是让第一次尝试就带上历史经验**，而不是试错三次才发现。
- 和微调互补：Reflexion 快速迭代，积累的案例是微调数据集的来源。

Agent 要从「每次重新学」变成「越来越熟」，缺的就是这一步显式的反思。但记住：**它的上限取决于你判断「失败」的能力**——判断不准，学得越快错得越远。
