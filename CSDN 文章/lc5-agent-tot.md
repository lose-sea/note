# Tree of Thoughts：把一条思维链展开成一棵树

CoT（思维链）让模型「一步一步想」，已经是很强的提升了。但它本质上还是一条线：给定起点，一路推到底，中间没有回头路。

ToT（Tree of Thoughts）的想法很直白：**为什么只走一条路？** 让模型在关键节点同时生成多个候选思路，评估每条的前景，差的剪掉、好的继续展开，必要时还能回溯。把「线性推理」变成「树状搜索」。

听起来很美，但 ToT 在工程上的成本比 CoT 高一个量级（调用次数可能多十倍）。这一篇讲清楚它到底强在哪、什么时候值得上、以及怎么在成本可控的前提下用出它的效果。

---

## 一、CoT 的局限：单线承诺

### 1.1 一个具体场景

用户问：24 点游戏，给定 3、3、8、8，能不能算出 24？

CoT 的做法：

```
想法1: 8/(3-8/3) = 8/(1/3) = 24  ✓
```

这次运气好，一次命中。但如果它第一反应是：

```
想法1: 3×8=24，还剩 3 和 8。3+8=11，11 和 24 凑不出 24
       24-11=13，不是目标 → 失败
```

**线性的 CoT 到这里就卡死了**，它要么认输，要么在一条走不通的路上反复修补。

而人的做法是：3×8=24 这条路不通，试试别的组合——8/(3-8/3)。**关键是「换一条路」，而不是「在走不通的路上死磕」。**

### 1.2 单线思维的三个盲区

**盲区一：早期的局部最优困住全局。** 第一步选了看似最好的方向，走到第三步发现是死胡同，但已经没有回头路了。

**盲区二：无法并行探索。** 一次只能试一个方向，试错成本高。

**盲区三：没有「前瞻」能力。** CoT 的每一步只知道「从这儿怎么走下一步」，不知道「从这儿能不能走到终点」。

ToT 就是把这三个盲区逐一补上：**多分支（并行探索）+ 状态评估（前瞻）+ 回溯（换路）**。

---

## 二、ToT 的结构

### 2.1 四个核心概念

```
目标
 │
 ├─ 想法A（评分 0.8）────── 保留
 │    ├─ 想法A1（0.9）───── 保留
 │    │    ├─ 想法A1a（解）→ 验证 ✓
 │    │    └─ 想法A1b（0.3）→ 剪枝
 │    └─ 想法A2（0.2）────── 剪枝
 ├─ 想法B（0.4）────────── 剪枝
 └─ 想法C（0.7）────────── 保留
      └─ 想法C1（0.1）───── 剪枝
```

- **状态（State）**：推理过程中的一个中间步骤（如「3×8=24 后还剩 3、8」）
- **思维（Thought）**：从当前状态出发的一个候选下一步
- **评估**：给每个思维打一个「有没有前途」的分
- **搜索策略**：决定展开哪个、剪掉哪个、什么时候回溯

### 2.2 和 ReAct 的区别

| | ReAct | ToT |
|---|-------|-----|
| 单步产出 | 1 个动作 | k 个候选思维 |
| 有无评估 | 无（直接执行） | 有（每个思维打分） |
| 分支处理 | 无（单线） | 剪枝 + 回溯 |
| 调用次数 | 每步 1 次 | 每步 k 次生成 + m 次评估 |
| 适用 | 开放式任务 | 有明确目标、可验证、搜索空间适中的任务 |

**注意最后一行**：ToT 不是万能的，它对任务类型有明确要求。

---

## 三、实现一个最小 ToT

以「24 点」为例，这是 ToT 论文里的经典 demo。

### 3.1 状态表示

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class State:
    numbers: tuple           # 剩余可用的数字，如 (3, 8)
    expr: str                # 已构建的表达式描述
    depth: int
```

状态不可变，每个新分支产生一个新 State。

### 3.2 生成候选思维

```python
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(model="gpt-4o", temperature=0.7)   # 多样化要用高 temperature

GEN_PROMPT = """剩余数字: {numbers}
目标: {target}
当前表达式: {expr}

请给出 {k} 个不同的「下一步组合」，
每个想法选择两个数字进行一次四则运算，得到一个新数字替换它们。

要求：
1. 只输出 JSON 数组，每个元素 {{"a": x, "b": y, "op": "+-*/", "result": z}}；
2. k 个想法必须互不相同；
3. 优先尝试不同的组合思路，不要都是同一种运算。"""

def generate_thoughts(state: State, k: int = 3):
    resp = llm.invoke(GEN_PROMPT.format(
        numbers=state.numbers, target=TARGET, expr=state.expr, k=k))
    return json.loads(resp.content)
```

**temperature 要高（0.7~1.0）**——ToT 要的是多样性。温度太低，k 个候选会长得一样，树就退化成了线。

### 3.3 评估每个思维

这是 ToT 的关键，也是最容易做砸的一步。

```python
EVAL_PROMPT = """判断下面这个中间结果「有没有可能最终算出 {target}」。

当前剩余数字: {new_numbers}
已走路径: {expr}

请评估：
- 剩余数字能凑出目标的可能性，0~1 之间的小数
- 只输出数字，不要解释"""

def evaluate(state: State) -> float:
    resp = llm.invoke(EVAL_PROMPT.format(
        target=TARGET, new_numbers=state.numbers, expr=state.expr))
    try:
        return float(resp.content.strip())
    except ValueError:
        return 0.0
```

**评估提示词决定了 ToT 的上限。** 评估器判错了，好的分支被剪、坏的分支留，整个搜索就废了。

对于 24 点这种**能用代码验证**的任务，永远别用 LLM 评估：

```python
def evaluate_code(state: State) -> float:
    # 直接算：剩余数字能否凑出目标
    return 1.0 if can_reach(state.numbers, TARGET) else 0.0
```

`can_reach` 用一个穷举函数就能写出来。**LLM 评估是最后选项，不是首选。**

### 3.4 搜索策略：BFS / DFS / Beam

```python
def beam_search(root: State, beam_width: int = 3, max_depth: int = 6):
    frontier = [root]
    best = None

    for depth in range(max_depth):
        candidates = []
        for state in frontier:
            if len(state.numbers) == 1:
                if abs(state.numbers[0] - TARGET) < 1e-6:
                    return state.expr            # 找到解
                continue
            for thought in generate_thoughts(state, k=beam_width):
                new_state = apply(state, thought)
                score = evaluate_code(new_state)
                candidates.append((score, new_state))

        # 剪枝：只留 beam_width 个最高分的
        candidates.sort(key=lambda x: -x[0])
        frontier = [s for sc, s in candidates[:beam_width]]
        if not frontier:
            return None
    return None
```

这就是 **Beam Search**：每一层只保留 beam_width 个最有前途的状态。它比「全展开再找」省大量调用，比「单线 DFS」覆盖更广。

### 3.5 参数怎么定

| 参数 | 建议值 | 说明 |
|------|-------|------|
| beam_width | 2~4 | 越大覆盖越广，成本线性涨 |
| k（每状态候选数） | 3~5 | 生成多样性，太多会稀释 beam |
| max_depth | 按任务定 | 24 点 4 个数字 → 深度 3 |
| 生成 temperature | 0.7~1.0 | 太低退化成单线 |
| 评估 temperature | 0 | 评估要稳定 |

一组参考成本：24 点，beam_width=3，depth=3，大概 20~30 次 LLM 调用。**这是 CoT（1 次）的几十倍。** 所以选型时成本是必须考虑的因素。

---

## 四、什么时候 ToT 是值得的

### 4.1 ToT 的主场

三个条件同时满足，ToT 的收益才划算：

1. **有明确目标，且目标可验证**（24 点的「等于 24」、代码的「通过测试」、数独的「每行每列数字不重复」）
2. **搜索空间适中**——不是无穷大，也不能一眼看穿
3. **第一步很容易选错方向**，需要回溯

典型场景：

- 数学/逻辑题（24 点、数独、纵横字谜）
- 代码生成与自动修复（多个修复方案里挑能过测的那个）
- 需要多步规划的创意任务（写故事大纲，几种开头选哪个）
- 方案比选（架构设计，几个方案并行探索后择优）

### 4.2 ToT 是浪费的场景

- **开放式问答**：「解释一下什么是向量数据库」——没有多个分支可探索，CoT 甚至直接答都行
- **简单工具调用**：选工具、填参数，一次生成就够，ToT 是在给同一个决策做无意义的树搜索
- **延迟敏感**：客服实时对话、流式输出。ToT 的几十次调用没有机会塞进 2 秒响应
- **搜索空间极大**：写一篇 5000 字报告，每一步的候选空间近乎无限，beam 再宽也覆盖不了

**一个务实的判断法**：人类做这个任务时，会不会「先试 A 发现不行，换 B 试试」？会，那可以考虑 ToT；不会，就别用。

---

## 五、工程上的三个省钱变体

完整 ToT 成本太高。实践中常用这三个变体，保留大部分收益但成本可控。

### 5.1 变体一：推理期多采样 + 择优（最实用）

不建树，只是在**最终答案层**多生成几个候选，用验证器挑最好的：

```python
def sample_and_select(question: str, n: int = 5):
    # temperature 0.8，生成 n 个不同答案
    answers = [llm.invoke(question).content for _ in range(n)]
    # 用验证器/代码校验挑最好的
    best, best_score = None, -1
    for a in answers:
        score = verify(a)          # 代码跑测试、规则校验
        if score > best_score:
            best, best_score = a, score
    return best
```

成本是 CoT 的 n 倍，但**远比完整 ToT 便宜**。而且对「代码生成并跑测试」这类任务，效果接近 ToT——因为验证器足够强。

**这是我最推荐的起点。**

### 5.2 变体二：单层 ToT

只在最关键的决策点做分支，其他步骤线性走：

```python
# 只在开头做方案选择
plans = generate_plan_options(task, k=3)          # 3 个候选计划
scores = [evaluate_plan(p) for p in plans]
best_plan = plans[argmax(scores)]

# 之后线性执行
result = execute(best_plan)
```

成本只有 3~4 次额外调用。适合「开头选错方向代价大」的任务（架构设计、复杂规划）。

### 5.3 变体三：自洽性（Self-Consistency）

严格说这不是 ToT，但解决同一个问题：

```python
def self_consistency(question: str, n: int = 5):
    answers = [llm.invoke(question, temperature=0.7).content for _ in range(n)]
    from collections import Counter
    counts = Counter(normalize(a) for a in answers)
    return counts.most_common(1)[0][0]        # 多数投票
```

**用投票替代搜索。** 对数学题特别有效（标准答案集中），比 ToT 便宜得多。缺点：没有原理解释，而且对开放任务无效（答案不重复，投票没意义）。

---

## 六、ToT 在 Agent 场景怎么用

ToT 用在 Agent 上和单模型推理略有不同，落地形态有三种。

### 6.1 工具选择层的 ToT

Agent 每一步要选工具。可以用 ToT 在选工具这一层做分支：

```python
def choose_action_with_tot(state: State, k: int = 3):
    candidates = generate_action_candidates(state, k=k)   # 3 个候选动作
    scored = [(evaluate_action(state, c), c) for c in candidates]
    scored.sort(key=lambda x: -x[0])
    return scored[0][1]
```

**但实践中通常不划算。** Agent 的每一步都做 ToT，调用次数爆炸。更好的做法是只在「关键决策点」（如是否要切换到另一个策略）用 branch，普通步骤还是单线。

### 6.2 方案生成层的 ToT

让 Agent 一次性给出 3 个方案，然后并行验证：

```python
@tool
def propose_solutions(task: str, k: int = 3) -> str:
    """生成 k 个候选方案，用于需要多方案比选的任务。"""
    sols = [llm.invoke(PROPOSE_PROMPT.format(task=task), temperature=0.9).content
            for _ in range(k)]
    return json.dumps(sols)
```

这个工具挂在 Agent 上，让它**在需要比选时主动调用**，比无脑套 ToT 更符合 Agent 的工作方式。

### 6.3 规划层的 ToT（最实用）

Plan-and-Execute 里，Planner 可以生成多个候选计划，Replanner 评估后择优：

```python
plans = [generate_plan(task, temperature=0.9) for _ in range(3)]
scored = [(evaluate_plan_feasibility(p), p) for p in plans]
best_plan = max(scored, key=lambda x: x[0])
```

**成本只增加 3 次规划调用，收益是「开头不走错路」。** 这是 ToT 思想在 Agent 里性价比最高的应用点。

---

## 七、常见误区

**误区一：所有任务都上 ToT。** 开放式问答、简单工具调用用它纯属浪费。先判断任务是否符合 4.1 的三个条件。

**误区二：用 LLM 评估，而且提示词写得含糊。** 评估器不准，整个搜索就是随机乱走。**能代码验证就一定用代码**。

**误区三：beam_width 设太大。** 5 和 3 差别不大，成本差一倍。Beam 宽度 2~4 就够。

**误区四：生成候选时 temperature 太低。** 三个候选一模一样，树退化成线，白花钱。

**误区五：忘了设 max_depth 和总体调用上限。** 分支 + 分支持续膨胀，没有上限就是无底洞。**必须设硬性调用次数预算。**

**误区六：把 ToT 当「模型更聪明」。** ToT 不提升模型能力，它只是**用更多计算换更高的成功率**。同样的模型，ToT 的正确率更高，但每一次都更贵。

---

## 小结

- ToT 的本质是**把线性推理变成树状搜索**：多分支生成 + 状态评估 + 剪枝回溯。它解决的是 CoT「单线承诺、走不通只能死磕」的问题。
- 核心三要素：**候选生成（高 temperature 保证多样性）、状态评估（这是上限，能代码验证就别用 LLM）、搜索策略（Beam Search 最实用）**。
- Beam width 2~4、候选数 3~5、必须有 max_depth 和**硬性调用预算**。
- 适用条件苛刻：目标可验证、搜索空间适中、开头容易选错方向。**数学/逻辑题、代码修复、方案比选**是主场。
- 成本是 CoT 的几十倍，所以实践用三个省钱变体：**推理期多采样择优（最推荐）、单层 ToT（开头分支）、自洽性投票（数学题）**。
- 在 Agent 里最有价值的应用点是**规划层 ToT**：生成 3 个候选计划择优，成本只增 3 次调用，收益是开头不走错路。

一句话总结：**ToT 不是让模型变聪明，是用更多计算换更高成功率。** 先确认你的任务值这个价，再决定要不要上。
