# 自我批评与多轮打磨：让 Agent 自己改自己的作业

让 LLM 写完第一稿就直接上线，出来的东西往往「能用但不放心」。你加一句「请检查你的输出有没有问题」，它说「我检查过了，没问题」——然后错误原封不动。

自我批评（Self-Critique）想解决的就是这个：**让模型显式地审视自己的输出，找出问题，然后重写。** 听起来自然而然，但这里面的坑非常多——模型倾向于「自我感觉良好」，改反了的情况也不少见。

这一篇讲清楚：自我批评真正起效的条件是什么、怎么设计「批评—修改」的闭环、以及什么时候它反而会让结果变差。

---

## 一、为什么「再看看」不管用

### 1.1 自我确认偏误

模型的默认行为模式是「生成 + 确认」。你让它检查自己的输出，它倾向于找到证据支持自己是对的，而不是找错。

```
你的输入：请检查上面这段代码有没有 bug。
模型输出：经检查，代码逻辑正确，边界情况已处理，没有发现问题。
```

典型的敷衍。原因有两个：

1. **训练信号偏向「有帮助、有信心」**。说「没问题」在训练里通常比「我发现三处疑点」更受奖励。
2. **重新评估自己的输出时，用的是「生成时的那套推理」**。同一条推理路径很难自己推翻自己。

### 1.2 上下文带来的「沉没成本」

输出已经在上下文里，模型看到自己的长篇大论，天然倾向于认为它是对的。**修改意味着否定自己刚写的几百字**，这在模型的概率分布里是低概率路径。

### 1.3 真正有效的是「换个视角批评」

要让自我批评起作用，核心是**打破那套「用同样的方式再看一遍」**。方法有三个：

- **换角色**：不是「作者自查」，而是「评论家审稿」——不同的身份对应不同的关注点
- **给明确的检查维度**：空泛的「有没有问题」≈ 没有问题；具体的「是否处理了空输入、是否处理了并发、异常路径是否覆盖」才有得查
- **用外部证据**：让批评基于「跑一遍看结果」而不是「读一遍看感觉」

---

## 二、有效的批评闭环长什么样

```
初稿 → 批评（多维度、有清单）→ 若有问题 → 修改（针对问题，不推翻全文）→ 复审
                                                              ↓
                                                   3 轮未收敛 → 输出当前最好版本 + 风险说明
```

### 2.1 第一步：批评要带清单

```python
CRITIQUE_PROMPT = """你是严格的技术审稿人。请审查下面的初稿。

【任务要求】
{task_requirements}

【初稿】
{draft}

请逐项检查并打分（0=没问题，1=有问题）：

1. 正确性：事实、逻辑、计算是否有错？
2. 完整性：是否覆盖了任务要求的所有点？列出遗漏项。
3. 边界情况：空输入、异常值、极端情况下是否会出问题？
4. 一致性：前后是否有自相矛盾的地方？
5. 格式规范：是否符合要求的输出格式？

只输出有问题的项，没问题的项不要提。输出 JSON：
{{"issues": [{{"dimension": "正确性", "severity": "high/medium/low", "description": "具体问题", "location": "问题所在的位置"}}]}}"""
```

三个关键设计：

- **分维度**：不分维度就只会说「整体还行」。
- **「只输出有问题的项」**：防止模型为了填满格式而编造问题。
- **必须有 location**：说不出位置的问题，往往不是真问题。

### 2.2 第二步：修改要定向

```python
REVISE_PROMPT = """根据审稿意见修订初稿。

【任务要求】
{task_requirements}

【原稿】
{draft}

【审稿意见】
{issues}

修订规则：
1. 只修改意见中指出的问题，不要重写没有问题的部分；
2. 如果某条意见你判断不成立，保留原样并在 notes 里说明理由；
3. 修改后保持原有的结构和风格；
4. 输出修订稿，并在末尾附上 notes（你对每条意见的处理）。"""
```

**第 1 条是关键。** 让模型「重写一版更好的」通常会引入新问题、丢掉原来对的部分。定向修改 + 「不许动没问题的部分」，稳定性高得多。

### 2.3 第三步：复审与收敛

```python
def refine(draft, max_rounds=3):
    for r in range(max_rounds):
        issues = critique(draft)
        if not issues["issues"]:
            return draft, r              # 没有问题了，收敛

        draft = revise(draft, issues)

    return draft, max_rounds            # 没收敛，但返回当前最好版本
```

**必须设轮次上限。** 见过自我批评跑十几轮的——每轮都挑出新问题，有的还是模型自己上一轮引入的。设 3 轮，不收敛就带着问题输出，比无限循环强。

---

## 三、让批评真正有效的四个手段

### 3.1 手段一：换一个「身份」

同一个模型，不同的系统提示，视角完全不同：

```python
GENERATOR_SYS = "你是一名资深工程师，负责写出高质量的代码。"

CRITIC_SYS = """你是一名严苛的代码审查员。你的职责是找出问题，不是夸奖。
已知作者会犯的典型错误：
- 忽略空输入和 None
- 忘记关闭资源（文件、连接）
- 并发下数据竞争
- 错误处理吞掉异常
对于每一处，你必须给出具体的代码位置和触发场景。"""
```

**在 Critic 的系统提示里列出「已知的典型错误」**，效果出奇地好。它给了模型一个「该往哪里看」的先验，比「你仔细看看」有用一百倍。

### 3.2 手段二：把检查变成可执行代码

对于能跑的东西，**永远用代码检验，别用模型感觉**：

```python
def critique_code(draft_code: str, test_cases: list) -> dict:
    issues = []
    try:
        sandbox = DockerSandbox()
        result = sandbox.run(draft_code, tests=test_cases)
        if not result.passed:
            for failed in result.failures:
                issues.append({
                    "dimension": "正确性",
                    "severity": "high",
                    "description": f"测试失败: {failed.case} — 期望 {failed.expected}，实得 {failed.actual}",
                    "location": failed.line,
                })
    except Exception as e:
        issues.append({"dimension": "可运行性", "severity": "high", "description": str(e)})
    return {"issues": issues}
```

**测试用例就是最好的批评者。** 它不敷衍、不偏向、不累。你只需要把失败信息翻译成 issue 格式喂给修改环节。

### 3.3 手段三：把批评和修改拆成两次调用

把「批评」和「修改」放在同一次调用里：

```
模型：我发现有三处问题……（然后直接输出修正版）
```

这样做的问题：**模型会因为「我已经修了」而降低批评的严格度**，而且你拿不到中间的批评记录，无法排障。

拆成两次：

```
调用1（只批评，禁止修改）：输出 issues JSON
调用2（按 issues 定向修改）：输出修订稿
```

虽然多花一次调用，但批评质量明显更高，而且可追溯——你能看到「到底批评了什么、改了什么、哪条批评被拒了」。

### 3.4 手段四：让阳光下的批评可被质疑

模型会提出**不正确**的批评。如果无脑接受，越改越错。

在 REVISE 提示词里明确「你可以拒绝某条意见」，并要求说明理由（前面 2.2 的第 2 条）。这样：

- 假问题不会被强行「修」出真 bug
- 你能从 notes 里看到模型为什么拒绝，据此调整批评提示词

**一个实用监控**：统计「拒绝意见的比例」。如果模型拒掉了 60% 以上的意见，说明批评提示词在生成噪声；如果几乎从不拒绝，说明批评提示词太保守，可以加码。

---

## 四、三个层次的自我批评

自我批评不是只有「写完再改」一种形态。按介入的时机分三种：

### 4.1 事前批评（生成前）

在生成前先列出易错点和约束：

```python
PRE_DRAFT_PROMPT = """在写之前，先列出：
1. 这个任务容易犯的 3 个错误（结合任务类型）
2. 必须满足的硬约束

然后基于这两点再开始写初稿。"""
```

**成本最低，效果常被低估。** 让模型先想「哪里会错」，比写完再想「哪里错了」更能防患于未然。

### 4.2 事中批评（分解成步骤时）

长任务里，每一步做完自检一次再进下一步：

```python
def execute_step(step):
    result = run(step)
    check = verify_step(result, step.criteria)
    if not check.ok:
        result = retry_with_feedback(step, check.feedback)
    return result
```

这就是 Reflexion 的轻量版，适合长流程。

### 4.3 事后批评（完整产出后）

就是前面那套「批评—修改—复审」闭环。适合最后的产出（报告、代码、方案）。

**三者的选择**：流程长的用事中，产出质量要求高的用事后，两者都要就都上。事前批评基本无成本，建议默认加。

---

## 五、什么时候自我批评反而有害

这块务必看清楚，别盲目上。

### 5.1 创造性任务

写文案、起名字、想创意。批评会让产出趋向「安全但平庸」——每一轮都在削掉风险和新意。**创意任务应该用多次生成 + 人工选，而不是自我批评。**

### 5.2 事实型问答

「Python 的 len() 是什么」——初稿就是对的，自我批评只会浪费调用，还可能引入错误。

### 5.3 延迟敏感场景

批评+修改+复审，一轮至少 2 次调用。客服实时对话塞不进这个流程。

### 5.4 任务本身没有明确标准

「写一段介绍公司的话」——批评者不知道该按什么标准批，会编出一些似是而非的意见（「语气可以更热情一点」），模型照着改，改完反而更糟。

**判据：有没有一个明确的、可判定的质量标准？** 有，自我批评有价值；没有，它是噪声发生器。

---

## 六、一个完整实现

```python
from pydantic import BaseModel, Field
from typing import Literal

class Issue(BaseModel):
    dimension: str
    severity: Literal["high", "medium", "low"]
    description: str
    location: str

class Critique(BaseModel):
    issues: list[Issue] = Field(default_factory=list)

class Critic:
    def __init__(self, llm, task_requirements: str, max_rounds: int = 3):
        self.llm = llm.with_structured_output(Critique)
        self.requirements = task_requirements
        self.max_rounds = max_rounds

    def review(self, draft: str) -> Critique:
        return self.llm.invoke(CRITIQUE_PROMPT.format(
            task_requirements=self.requirements, draft=draft))

    def refine(self, draft: str, verifier=None):
        """verifier: 可选的外部校验函数（跑测试、规则检查）"""
        history = []
        for r in range(self.max_rounds):
            # 优先用外部验证器，退回到 LLM 批评
            if verifier:
                issues = verifier(draft)
            else:
                issues = self.review(draft)

            if not issues.issues:
                return {"draft": draft, "rounds": r, "history": history,
                        "status": "converged"}

            before = draft
            draft = self.revise(draft, issues)
            history.append({
                "round": r + 1,
                "issues": [i.model_dump() for i in issues.issues],
                "accepted": draft != before,
            })

        return {"draft": draft, "rounds": self.max_rounds,
                "history": history, "status": "max_rounds_reached"}
```

**有 verifier 就优先用**。它是唯一不会敷衍的批评者。

---

## 七、常见误区

**误区一：让模型「顺便检查一下」。** 没有清单、没有身份转换、没有可执行验证，检查就是走过场。要给它具体的检查维度和已知错误清单。

**误区二：批评和修改在同一次调用。** 省一次调用，但批评质量下降、过程不可追溯。

**误区三：无脑接受所有批评意见。** 模型会提假问题。必须允许它拒绝并说明理由，同时监控拒绝比例。

**误区四：没有轮次上限。** 每轮都能挑出新问题，无限循环。设 3 轮，不收敛就带问题输出。

**误区五：修改时让模型「重写一版更好的」。** 定向修改，不许动没问题的部分。

**误区六：在所有任务上用。** 创意、事实问答、延迟敏感、无明确标准的场景，自我批评会让结果变差。先判断有没有可判定的质量标准。

---

## 小结

- 自我批评的难点不是「让模型再看一遍」，而是**打破自我确认偏误**——同一条推理路径很难推翻自己。
- 有效的四个手段：**换 Critic 身份（附已知错误清单）、把检查变成可执行代码（测试是最好的批评者）、批评和修改拆成两次调用、允许拒绝意见并监控拒绝比例**。
- 闭环必须**定向修改 + 轮次上限（3 轮）**，否则要么改出新 bug，要么无限循环。
- 三种介入时机：事前（列易错点，几乎无成本，建议默认开）、事中（分步自检）、事后（完整产出后闭环）。
- **有外部验证器就优先用**——它是唯一不敷衍、不偏向、不累的批评者。
- 有害的四类场景：创意任务（变平庸）、事实问答（纯浪费）、延迟敏感（来不及）、无明确标准（噪声发生器）。

「让模型自己改作业」的前提是，你给了它**一份真正的评分标准和一把不容糊弄的尺子**。缺了这两样，自我批评就只是多花两倍 token 演一遍流程。
