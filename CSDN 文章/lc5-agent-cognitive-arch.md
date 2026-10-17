# 认知架构：把 Agent 拆成模块，而不是一个巨型提示词

「写个 Agent」通常是怎么开始的？打开编辑器，写一个系统提示：

```
你是一个智能助手，你能够：
1. 理解用户意图
2. 判断是否需要检索
3. 调用工具
4. 组织语言回答
5. 如果用户不满意的道歉并重试
6. 记住用户的偏好
7. 注意不要泄露隐私
...
```

写着写着，这个提示词变成两千字，Agent 也变成「什么都能干一点，什么都干不利索」。

**Agent 做不大，往往不是因为模型不行，而是因为它被做成了一个单体的「大脑」。** 人类智能从来不靠单个大脑，而是靠感知、记忆、注意、推理、行动这些模块协同。认知架构就是把这套思路搬到 Agent 上。

这一篇讲清楚：模块怎么切、之间怎么通信、以及什么时候模块化是自找麻烦。

---

## 一、单体 Agent 的天花板

### 1.1 三个必然出现的瓶颈

**瓶颈一：提示词互相干扰。**
「生成内容」要发散，「事实校验」要严谨。两者写在同一个系统提示里，模型会在这两种模式间摇摆，产出不稳定。你调了一周 prompt，发现改了 A 场景坏了 B 场景——因为它们共享同一份指令。

**瓶颈二：无法独立评测和优化。**
一个 Agent 端到端准确率 75%。这 25% 的失败到底出在哪？意图理解错了？检索没召回？生成编造？你没法知道，因为全部混在一次调用里。

**瓶颈三：无法替换组件。**
想换个 embedding 模型？想加一层内容审核？想把某个步骤换成本地小模型省成本？在单体里这些都动不了——全都是 prompt 的一部分。

### 1.2 类比：为什么软件不写成一个大函数

这个道理在传统软件里是常识。没人会把一个电商系统写成「一个处理所有事情的函数」——要拆成订单、库存、支付、通知。

**Agent 也应该这样拆。** 区别只在于：传统软件的模块边界由数据流决定，Agent 的模块边界由「认知功能」决定。

---

## 二、模块怎么切

借鉴认知科学的框架，一个生产级 Agent 可以拆成这几层：

```
┌─────────────────────────────────────────────┐
│               感知层（Perception）            │  输入解析、意图识别、实体抽取
├─────────────────────────────────────────────┤
│               注意层（Attention）             │  筛选相关信息，控制上下文预算
├─────────────────────────────────────────────┤
│               记忆层（Memory）                │  情景 / 语义 / 程序性，三类分治
├─────────────────────────────────────────────┤
│               推理层（Reasoning）             │  规划、分解、评估、决策
├─────────────────────────────────────────────┤
│               行动层（Action）                │  工具调用、执行、结果校验
├─────────────────────────────────────────────┤
│               元认知层（Metacognition）       │  监控、反思、纠错、成本控制
└─────────────────────────────────────────────┘
```

逐层说它们各自的职责和实现。

### 2.1 感知层

**职责**：把「用户说的一句话」变成结构化输入。

```python
class PerceivedInput(BaseModel):
    raw_text: str
    intent: Literal["question", "command", "chitchat", "unclear"]
    entities: dict            # 时间、对象、约束
    needs_retrieval: bool
    needs_tool: bool
    confidence: float
```

实现：一次轻量 LLM 调用（小模型即可），或者规则 + 小模型的混合。

**关键是这一步做完，后面各层都基于结构化对象通信**，而不是把「用户那句话」一路传下去。这就避免了后面每一层都要重新理解一遍用户意图。

### 2.2 注意层

**职责**：决定「这一次调用，上下文里放什么」。

这是最容易被忽略、但对成本和效果影响最大的一层。它做三件事：

1. **筛选**：从记忆库、检索结果里挑出相关的
2. **排序**：重要的放前面/后面（注意 Lost in the Middle）
3. **预算**：总 token 超了就压缩或丢弃

```python
def attend(perceived: PerceivedInput, budget_tokens: int = 3000) -> Context:
    parts = []
    used = 0

    # 优先级：当前任务 > 用户偏好 > 历史情景 > 程序性流程 > 检索材料
    for source, priority in [
        (current_task(), 1.0),
        (user_preferences(perceived), 0.8),
        (relevant_episodes(perceived), 0.6),
        (relevant_procedure(perceived), 0.5),
        (retrieve_docs(perceived), 0.7),
    ]:
        text, cost = source
        if used + cost <= budget_tokens:
            parts.append(text)
            used += cost
        else:
            # 放不下就压缩
            compressed = compress(text, budget_tokens - used)
            if compressed:
                parts.append(compressed)
            break
    return Context(parts=parts, used_tokens=used)
```

**注意层独立出来的价值**：你能单独调整上下文策略（改排序、改预算、加权压缩），而不动任何其它层。

### 2.3 记忆层

就是上一篇讲的三类分治（情景/语义/程序性）。在架构里它是一个**被调用的服务**，不是一个 prompt 段落。

### 2.4 推理层

**职责**：规划、决策、评估。

对于复杂任务，它是 Plan-and-Execute 的 Planner；对于简单任务，它可能只是一次直接的「该不该调工具」判断。

```python
class Reasoner:
    def decide(self, perceived, context) -> Action:
        # 简单决策用小模型，复杂规划用大模型
        if perceived.intent == "question" and not perceived.needs_tool:
            return Action(type="answer")
        return self.plan(perceived, context)      # 复杂路径
```

**模型分级是这一层的主要成本优化手段**：80% 的请求是简单的，用小模型；20% 复杂的走大模型。

### 2.5 行动层

**职责**：执行推理层产出的动作，并做结果校验。

```python
def execute(action: Action) -> Observation:
    try:
        if action.type == "tool_call":
            result = tool_registry[action.tool].run(**action.args)
            return Observation(ok=True, data=result)
        elif action.type == "answer":
            return Observation(ok=True, data=action.content)
    except Exception as e:
        return Observation(ok=False, error=str(e), retryable=is_retryable(e))
```

**行动层不要包含决策逻辑。** 它只负责「把事办了，把结果（含失败原因）返回」。判断要不要重试、要不要换方案，是推理层和元认知层的事。

### 2.6 元认知层

**职责**：监控整个流程，发现异常并干预。

这是「让 Agent 知道自己状态不好」的一层，包括：

```python
class Metacognition:
    def monitor(self, state) -> list[Signal]:
        signals = []
        # 1. 循环检测：同样的动作重复三次以上
        if count_recent_identical_actions(state) >= 3:
            signals.append(Signal("loop_detected", "动作在重复，建议重规划"))
        # 2. 预算告警
        if state.tokens_used > state.budget * 0.8:
            signals.append(Signal("budget_warning", "接近预算上限，准备收尾"))
        # 3. 信心衰减：连续失败
        if consecutive_failures(state) >= 2:
            signals.append(Signal("confidence_drop", "考虑降级为部分回答或拒答"))
        # 4. 偏离目标：当前动作与原始目标相关性低
        if relevance_to_goal(state.current_action, state.goal) < 0.3:
            signals.append(Signal("drift", "可能偏离目标，需要回顾计划"))
        return signals
```

**元认知层是单体 Agent 永远做不到的**——它不是 prompt 的一部分，它是一个观察整个状态机的外部视角。这也是模块化架构最大的隐性收益。

---

## 三、模块之间怎么通信

### 3.1 结构化消息，别传字符串

模块间传「用户原话」是灾难——每个模块都要重新 NLP 一遍。约定好消息格式：

```python
@dataclass
class Message:
    from_layer: str
    to_layer: str
    type: Literal["perception", "context", "decision", "observation", "signal"]
    payload: dict
    trace_id: str
    ts: datetime
```

### 3.2 用一个共享状态对象

```python
@dataclass
class AgentState:
    trace_id: str
    turns: list[Turn]
    perceived: PerceivedInput | None = None
    context: Context | None = None
    plan: Plan | None = None
    memory_snapshot: dict = field(default_factory=dict)
    tokens_used: int = 0
    signals: list[Signal] = field(default_factory=list)
```

每个层读自己需要的字段、写自己负责的字段。**这是 LangGraph 的核心思想**——图节点对应层，state schema 对应共享对象。

### 3.3 trace_id 贯穿

没这个，排障时你只能看到「Agent 给了个错答案」，看不到错在哪层。

---

## 四、一个可跑的最小架构

用 LangGraph 把六层串起来：

```python
from langgraph.graph import StateGraph, START, END

builder = StateGraph(AgentState)

builder.add_node("perceive", perceive_node)      # 感知层
builder.add_node("attend", attend_node)          # 注意层
builder.add_node("recall", memory_node)          # 记忆层
builder.add_node("reason", reason_node)          # 推理层
builder.add_node("act", act_node)                # 行动层
builder.add_node("meta", monitor_node)           # 元认知层

builder.add_edge(START, "perceive")
builder.add_edge("perceive", "attend")
builder.add_edge("attend", "recall")
builder.add_edge("recall", "reason")
builder.add_edge("reason", "act")
builder.add_conditional_edges("act", route_after_act, {
    "reason": "reason",      # 需要继续
    "end": END,
    "meta": "meta",          # 出问题了，先元认知
})
builder.add_edge("meta", "reason")

graph = builder.compile(checkpointer=postgres_checkpointer)
```

**元认知层的介入点**：行动层返回异常信号时，先走 meta 判断是重试还是改计划，再回 reason。这样它不占正常路径的开销。

### 4.1 模型分级（成本关键）

```python
MODELS = {
    "perceive":  ChatOpenAI(model="gpt-4o-mini"),    # 意图识别，便宜
    "reason":    ChatOpenAI(model="gpt-4o"),          # 规划决策，要强
    "act":       ChatOpenAI(model="gpt-4o-mini"),    # 参数填充，便宜
}
```

**感知层用便宜模型完全够**——识别人意图不需要最强智能。这一项通常能省 30%~40% 的总成本。

---

## 五、什么时候不要模块化

模块化不是免费的，有明确的成本。

### 5.1 模块化的三个代价

1. **调用次数变多**：六层各跑一次，简单任务也要 3~4 次调用（可以跳过部分层）
2. **上下文要反复传递**：每层都要把结构化 state 传给模型，有额外 token 开销
3. **系统复杂度上升**：调试、部署、监控都变复杂。排障要横跨多层

### 5.2 别模块化的场景

- **简单问答/工具调用**：一个 prompt + 一个工具循环就能搞定，拆六层是拿大炮打蚊子
- **快速验证 MVP**：先跑通端到端再拆。**先做对，再做模块化。** 一开始就设计完美架构，往往设计出来的是想象中的需求
- **单人维护且功能稳定**：没有多场景演进压力，模块化的维护成本收不回来

### 5.3 该模块化的信号

- 同一个 prompt 改了影响多个场景（**最明确的信号**）
- 有问题说不清是哪个环节出的
- 需要针对性优化某一环（换模型、加审核、调上下文）
- 场景在持续增加（新业务方接入新需求）

**核心判据：是否需要「独立地调整和度量」某一环。** 需要，就拆；不需要，别拆。

### 5.4 折中方案

不必一次拆六层。一个很实用的渐进路径：

**第一版**：单体 prompt + 工具循环，跑通再说
**第二版**：拆出「感知层」（意图分类 + 结构化输入），因为这一层最独立、收益最明确
**第三版**：拆出「注意层」（上下文管理），因为这一层直接影响成本和效果
**第四版**：按需拆推理、行动、元认知

**先从感知和注意两层拆起**——它们最独立、收益最直接、返工风险最小。

---

## 六、常见误区

**误区一：为了架构而架构。** 六层全上，结果每一层都是 trivial 逻辑，白白多了四次调用。**先跑通，再拆。**

**误区二：模块间传自然语言。** 每层都重新解析用户原话，既慢又容易失真。传结构化对象。

**误区三：所有层用同一个模型。** 感知、参数填充用小模型能省三成成本，而且效果几乎无损。

**误区四：元认知层放在正常路径上。** 每步都跑一次监控，开销翻倍。只在异常信号触发时介入。

**误区五：忘了可观测性。** 分层之后没有 trace_id，就得到一个更贵的黑盒。分层的最大价值之一是「可单独评测」，没有 trace 就丢了这个价值。

**误区六：拆了层但没定义清晰的输入输出。** 层与层之间靠「大概是那个意思」通信，最后变成隐式耦合的单体。

---

## 小结

- 单体 Agent 的天花板：**提示词互相干扰、无法单独评测优化、无法替换组件**。这和「把所有逻辑写在一个大函数里」是同一类问题。
- 六层划分：**感知（结构化输入）、注意（上下文预算与排序）、记忆（三类分治）、推理（规划决策）、行动（执行与校验）、元认知（监控反思）**。
- 模块间必须**传结构化消息和共享 state 对象**，配 trace_id 贯穿——否则分层只是得到一个更贵的黑盒。
- **模型分级**是分层最直接的收益：感知层和参数填充用小模型，能省三成以上成本。
- 元认知层提供的是**外部视角**——循环检测、预算告警、偏离目标，这些是单体 prompt 结构上做不到的。
- 但**先跑通再拆**。模块化适合「需要独立调整和度量某一环」的系统，简单任务和 MVP 阶段别拆。渐进路径：单体 → 感知 → 注意 → 其余。

架构的价值不在于层数多，而在于**每一层都能单独改、单独测、单独换**。做到这一点，Agent 才是一个可以长期演进的系统，而不是一份越写越长的 prompt。
