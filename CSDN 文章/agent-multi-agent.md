# 多智能体协作实战：AutoGen 与 CrewAI 该选谁

> 单个 Agent 做到一定程度，你会遇到一个很具体的瓶颈：
> 让它同时扮演「分析师」「程序员」「测试」三个角色，
> 它就开始串味——写代码时突然开始复述需求，测试时又跑回去改设计。
>
> 解决办法很直觉：**拆成多个 Agent，各司其职**。
> 本篇讲清楚多智能体为什么有效、两种主流框架怎么用，以及什么时候**不该**用。

## 一、为什么"多个人"比"一个人"强

这不是玄学，有三个实打实的机制：

**1. 上下文隔离。** 每个 Agent 只看到自己该看的东西。
写代码的 Agent 不需要知道产品经理纠结过哪三个方案，
它只需要拿到最终确认的需求。上下文干净了，注意力就集中了。

**2. 角色约束降低了发散。** 给模型一个明确人设（"你是一个严格的代码审查者，
只关注安全漏洞和性能问题"），它的输出分布会被显著收窄。
这本质上是**用 prompt 做先验约束**。

**3. 可并行。** 三个独立子任务可以同时跑，而不是串行等。
在长任务里这个收益很大。

但要清醒：**多智能体不是银弹**。它带来三个新成本：
token 消耗成倍增长（Agent 之间每次通信都是一次完整调用）、
调试难度陡增（错误在多个 Agent 之间传递，很难定位是谁先跑偏的）、
以及**可能陷入无效循环**（两个 Agent 互相客气，谁也不推进）。

## 二、两种协作拓扑

### 2.1 对话式（Conversable）

所有 Agent 在一个**群聊**里自由发言，谁想说就说。
适合探索性任务——没有标准流程，需要多方讨论收敛。

```
        ┌──────────────┐
        │   群聊总线    │
        └──┬───┬───┬──┘
           │   │   │
      ┌────▼┐ ┌▼───┐ ┌▼────┐
      │产品经理│ │程序员│ │审查员│
      └─────┘ └────┘ └─────┘
```

### 2.2 流水线式（Sequential / Hierarchical）

严格按阶段流转，上一个的输出是下一个的输入。
适合有明确 SOP 的任务——比如"调研 → 大纲 → 写作 → 校对"。

```
需求 → [调研员] → [撰稿人] → [审校] → 成品
         ↓          ↓         ↓
       资料包      初稿      修改意见（打回重来）
```

**判断标准很简单**：你能不能画出流程图？
能画出来就用流水线，画不出来才用群聊。

## 三、AutoGen：把多智能体做成"群聊"

AutoGen（微软）的核心抽象是 `ConversableAgent`——万物皆可对话，
包括人（`UserProxyAgent`，可以在循环里等真人输入）。

```python
# pip install autogen-agentchat
from autogen import ConversableAgent
import os

llm_config = {"config_list": [{"model": "gpt-4o", "api_key": os.environ["OPENAI_API_KEY"]}]}

coder = ConversableAgent(
    name="coder",
    system_message="你是资深 Python 工程师。只写可运行的代码，"
                   "每次输出完整的函数，不要省略。写完说 'OVER' 结束。",
    llm_config=llm_config,
    is_termination_msg=lambda m: "OVER" in m.get("content", ""),
)

reviewer = ConversableAgent(
    name="reviewer",
    system_message="你是代码审查者。指出 bug、安全隐患和性能问题。"
                   "没有问题就回复 'APPROVED'。",
    llm_config=llm_config,
)

# 启动群聊，coder 先说，最多 6 轮
chat = reviewer.initiate_chat(
    coder,
    message="写一个函数，安全地读取 YAML 配置并校验必填字段",
    max_turns=6,
)
```

### 3.1 让 Agent 真正"干活"：注册工具

光聊天没用，得能执行。AutoGen 用 `register_for_execution` 把 Python 函数变成工具：

```python
from typing import Annotated
import subprocess

def run_python(code: Annotated[str, "要执行的 Python 代码"]) -> str:
    """在沙箱里执行代码并返回输出"""
    try:
        r = subprocess.run(["python", "-c", code],
                           capture_output=True, text=True, timeout=30)
        return f"stdout: {r.stdout}\nstderr: {r.stderr}"
    except subprocess.TimeoutExpired:
        return "执行超时（30s）"

executor = ConversableAgent(
    name="executor",
    llm_config=False,               # 这个 Agent 不用大模型，纯执行
    human_input_mode="NEVER",
)
executor.register_for_execution(name="run_python")(run_python)
coder.register_for_llm(name="run_python", description="执行 Python 代码")(run_python)
```

`register_for_llm` 是"让另一个 Agent 知道有这个工具"，
`register_for_execution` 是"谁来真正执行"。
**两边都注册才能闭环**——这是 AutoGen 新手最容易卡住的地方。

### 3.2 什么时候用 AutoGen

- 任务流程不确定，需要 Agent 之间自由协商
- 需要人机协作（真人可以随时插话）
- 需要 Agent 实际执行代码、调外部系统
- 你在做研究性/探索性的原型

**代价**：流程不可控。你很难保证它一定在第 5 轮收敛，
有时会来回客套烧掉大量 token。`max_turns` 一定要设。

## 四、CrewAI：把多智能体做成"项目组"

CrewAI 的抽象更贴近现实组织：`Agent`（人）+ `Task`（活）+ `Crew`（团队）。
流程由你显式定义，可控性强得多。

```python
# pip install crewai crewai-tools
from crewai import Agent, Task, Crew, Process
from crewai_tools import SerperDevTool

search_tool = SerperDevTool()

researcher = Agent(
    role="资深技术调研员",
    goal="找到关于 {topic} 最权威、最新的资料",
    backstory="你擅长从海量信息中筛出真正有价值的部分，讨厌营销话术。",
    tools=[search_tool],
    verbose=True,
    allow_delegation=False,      # 不许甩锅给别人，自己干完
)

writer = Agent(
    role="技术撰稿人",
    goal="把调研结果写成一篇让新手看得懂的文章",
    backstory="你写过上百篇技术博客，最擅长用类比讲清复杂概念。",
    allow_delegation=False,
)

t_research = Task(
    description="调研 {topic}，产出 5 个关键结论，每条附上来源。",
    expected_output="结构化的调研笔记，5 个要点，Markdown 格式",
    agent=researcher,
)

t_write = Task(
    description="基于调研笔记写一篇 1500 字的技术文章。",
    expected_output="完整的 Markdown 文章，含代码示例",
    agent=writer,
    context=[t_research],        # 显式声明依赖，会自动注入上游输出
)

crew = Crew(
    agents=[researcher, writer],
    tasks=[t_research, t_write],
    process=Process.sequential,  # 顺序执行；也可用 Process.hierarchical 加一个经理
    verbose=True,
)

result = crew.kickoff(inputs={"topic": "RAG 的召回率优化方法"})
print(result.raw)
```

### 4.1 三个必知的设计点

**`context=[t_research]` 是核心。** 它声明了任务间的依赖，
CrewAI 会自动把上游输出注入下游 prompt。不写这行，
writer 根本看不到调研结果——这是最常见的"为什么我的 Agent 在瞎编"的原因。

**`allow_delegation` 默认开启是个坑。** 开启后 Agent 可以把活甩给别人，
在简单流程里会造成无限转交。明确不需要就设 `False`。

**`expected_output` 要认真写。** 它会被拼进 prompt，
直接决定输出格式。写得越具体，结果越可控。

### 4.2 层级流程：加一个"经理"

```python
crew = Crew(
    agents=[researcher, writer, reviewer],
    tasks=[t_research, t_write, t_review],
    process=Process.hierarchical,
    manager_llm=ChatOpenAI(model="gpt-4o"),   # 经理用来做任务分配决策
)
```

`hierarchical` 模式下 CrewAI 会自动创建一个经理 Agent，
由它决定下一步派谁干活。适合任务复杂、无法预先定死顺序的场景。
代价是**多了一层大模型调用，成本和延迟都上升**。

## 五、正面 PK：怎么选

| 维度 | AutoGen | CrewAI |
|---|---|---|
| 核心抽象 | 对话（ConversableAgent） | 组织（Agent / Task / Crew） |
| 流程控制 | 弱，靠 prompt 和终止条件 | 强，显式声明依赖 |
| 可预测性 | 低 | 高 |
| 人机协作 | 原生支持（UserProxyAgent） | 需要额外配置 |
| 代码执行 | 原生强项，生态成熟 | 通过 tools 支持 |
| 学习曲线 | 较陡 | 平缓 |
| 适合 | 研究、探索、需要执行代码 | 业务流程、内容生产、SOP 明确 |

**一句话结论**：
**流程能画成图就用 CrewAI，画不出来才用 AutoGen。**

## 六、多智能体的四个现实问题

### 问题 1：token 消耗失控

5 个 Agent 聊 10 轮，就是 50 次大模型调用，
每次还都带着完整历史。**成本是单 Agent 的几十倍**。

对策：给每个 Agent 设独立的、更小的模型（调研用 gpt-4o-mini，
决策才用 gpt-4o）；给每个 Agent 独立的上下文窗口，不要全局共享全部历史。

### 问题 2：死循环

两个 Agent 互相说"你说得对，请你继续"，烧掉一万 token 什么也没干。

对策：
- 硬性 `max_turns` / `max_iter` 上限
- 设置明确的终止词（`is_termination_msg`）
- 加一个"进展检测"——连续 N 轮输出相似就强制中断

### 问题 3：错误放大

上游 Agent 给了一个错误的事实，下游全盘接受并在此基础上发挥，
最后产出的东西错得理直气壮。

对策：**关键节点加验证 Agent**，让它独立核查上游结论，
而不是在同一个上下文里自我确认（那样会自我洗脑）。

### 问题 4：调试地狱

出问题时你不知道是哪个 Agent 先跑偏的。

对策：开启 `verbose=True`，把每个 Agent 的完整输入输出落盘。
**没有日志的多智能体系统等于不可维护**。

## 七、什么时候不该用多智能体

说点政治不正确的话：**大部分场景其实不需要多智能体**。

如果你的任务是"输入 A 产出 B"的确定性流程，
一个 Agent + 几个工具 + 清晰 prompt 就够了，
多 Agent 只会增加成本和不确定性。

真正需要上多智能体的信号：
- 单个 prompt 已经长到模型开始顾此失彼（> 2000 字的指令）
- 任务确实需要**不同视角的互相制衡**（比如生成 + 审查）
- 子任务之间可以并行，串行太慢

## 八、小结

- 多智能体的价值来自**上下文隔离、角色约束、可并行**三点
- **能画流程图就选 CrewAI**（显式依赖、可预测），探索性任务用 AutoGen
- AutoGen 工具要 `register_for_llm` + `register_for_execution` **两边都注册**
- CrewAI 的 `context=[...]` 不写，下游 Agent 就会瞎编
- 必须设 `max_turns`、必须开日志、必须给关键节点加独立验证
- **别为了用而用**——多数场景一个 Agent 加工具就够了

下一篇回到更基础也更实用的话题：提示词工程。
无论你用单 Agent 还是多 Agent，最终落地的都是一段 prompt——
那段话怎么写，决定了上面所有架构能发挥几成。
