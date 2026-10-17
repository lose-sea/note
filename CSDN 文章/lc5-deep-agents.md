# Deep Agents：给 Agent 装上规划、文件系统和长期记忆

大多数人的第一个 Agent 都是这样的：给一个 ReAct 循环，配几个工具，然后发现它只能干点「查一下天气、总结一段话」这种一次性小活。任务稍微复杂点——比如「读十份财报，写一份对比分析」——它就懵了：不知道从哪下手，上下文很快塞满，中途忘了自己干到哪。

问题不在模型不够聪明，而在**架构**。你把一个需要几个小时、几十次工具调用的活儿，扔给一个没有计划、没有笔记本、没有外部记忆的循环，当然做不完。

DeepAgents（LangChain 在 2025 年推出的 Agent 体系）就是冲着这个来的：它把 Agent 从「一个 prompt 循环」升级成「一个有规划能力、有虚拟文件系统、有持久记忆的系统」。这一篇我们就把它拆开讲清楚，并给一套可运行的实现。

---

## 一、从 Prompt 级到系统级

理解 DeepAgents 最好的方式，是看 Agent 架构的三代演进。

### 1.1 第一代：Prompt 级 Agent

就是一个 ReAct 循环：思考 → 调工具 → 观察 → 继续思考，直到给出答案。

```
while not done:
    thought = llm(history)
    if tool_call:
        result = run(tool_call)
        history.append(result)
    else:
        done = True
```

特点：**所有状态都在上下文里**。这决定了它的天花板——上下文有限，任务一长就爆；而且每一次循环都要把全部历史重新发一遍，成本和延迟线性上涨。

### 1.2 第二代：流程级 Agent（LangGraph）

用图来编排：路由、循环、并行、人机协同、断点续跑。状态可以存在外部（比如 Redis / Postgres），上下文里只放当前需要的信息。

这也正是 LangGraph 那一层做的事。它解决了「流程可控、状态可持久」，但**规划能力还是靠人手写 prompt**。

### 1.3 第三代：系统级 Agent

> 不是让 Agent「按我排好的流程跑」，而是让 Agent「自己排流程、自己记笔记、自己管记忆」。

DeepAgents 属于第三代。它的核心主张有三条：

1. **规划先行**：接到任务先写计划，而不是上来就干
2. **外部记忆**：把中间产物、笔记、结论写到文件系统里，不要全塞上下文
3. **子 Agent 派发**：把可以独立完成的子任务分给专门的子 Agent，各自带上下文

这不是一个新算法，而是一套**工程架构范式**。但正是这套范式，让 Agent 能真正处理长任务。

---

## 二、核心组件一：规划（Planning）

### 2.1 为什么必须先规划

没有规划的 Agent，失败模式非常典型：

- **视野窄**：每一步只盯着「下一步做什么」，走三步就迷路
- **不会总结**：遇到需要「先收集十份材料再综合分析」的任务，它会边收集边分析，最后得到的是一堆片段
- **无法并行**：不知道哪些子任务互不相干，只能一个一个串着做

人干活的方式完全不同：接到任务先列 to-do list，标出依赖关系，能并行的并行。**规划的价值不只是「有条理」，更是让并行和分派成为可能**。

### 2.2 工具化的 todo list

DeepAgents 的做法很直接：把「计划」做成一个工具，让 Agent 自己调用。

```python
from langchain_core.tools import tool

@tool
def write_todos(todos: list[str]) -> str:
    """创建或覆盖任务计划。

    Args:
        todos: 任务列表，每项写成「[描述] | [依赖任务序号]」的形式，
               无依赖写 none。例如：
               ["抓取A公司近三年财报 | none",
                "抓取B公司近三年财报 | none",
                "对比营收增速 | 1,2"]
    """
    STATE["todos"] = todos
    return "计划已更新：\n" + "\n".join(f"{i+1}. {t}" for i, t in enumerate(todos))

@tool
def update_todo(index: int, status: str, note: str = "") -> str:
    """更新某个任务的完成状态。status: pending/running/done/failed"""
    STATE["todos"][index] = f"{STATE['todos'][index]} [→{status}]"
    return f"任务 {index+1} 已标记 {status}"
```

注意 `write_todos` 的参数设计：**让 Agent 显式写出依赖关系**。这样你才能在后面推导出哪些任务可以并行——这是规划工具最关键的产出。

### 2.3 让模型真的愿意用

我实测过一个坑：如果你只是把 `write_todos` 加进工具列表，模型大概率**不调用它**——因为它更想直接开始干活，感觉「更快」。

解决办法是在系统提示里把规划变成**强制前置步骤**：

```python
SYSTEM = """你是一个长任务处理 Agent。

【铁律】收到任何任务后，第一步必须是调用 write_todos 制定计划，
在计划写出来之前，禁止调用其他任何工具、禁止给出任何答案。

规划要求：
1. 把任务拆成 3~10 个子任务，每个子任务应该能在 10 次工具调用内完成；
2. 显式标注依赖（任务序号），无依赖写 none；
3. 优先按「资料收集 → 加工处理 → 产出结论」的次序排；
4. 完成一个子任务立即 update_todo，不要攒着。

如果任务本身一句话就能回答（如「Python 怎么反转列表」），
可以直接回答，此时跳过规划。"""
```

最后那条例外很重要——**对简单任务强制规划是纯浪费**。

### 2.4 规划的自我修正

规划不是一次性的。跑着跑着发现原计划有问题，要能改：

```python
@tool
def revise_plan(changes: list[dict]) -> str:
    """调整计划。

    Args:
        changes: 例如 [{"op":"add","task":"..."},
                        {"op":"remove","index":2},
                        {"op":"insert","index":3,"task":"..."}]
    """
    for c in changes:
        if c["op"] == "add":
            STATE["todos"].append(c["task"])
        elif c["op"] == "remove":
            STATE["todos"].pop(c["index"] - 1)
        elif c["op"] == "insert":
            STATE["todos"].insert(c["index"] - 1, c["task"])
    return "计划已调整，当前共 %d 项" % len(STATE["todos"])
```

并在系统提示里说明：「如果执行中发现原计划有缺陷，用 revise_plan 修正，不要硬着头皮按错误计划跑完。」

---

## 三、核心组件二：虚拟文件系统

### 3.1 为什么用文件而不是上下文

这是 DeepAgents 里最能带来质变的设计。

**上下文的根本问题是：它是等价的。** 一个 token 就是一个 token，无论它装的是「刚才那次失败的搜索结果」还是「十分钟前得出的关键结论」。你没法有效地表达「这个重要，那个可以扔」。

而文件系统天然分层：目录、文件名、内容。它可以：

- 把中间产物**卸载**到磁盘，上下文里只留一个路径
- 需要时再**按需读回**（甚至只读一部分）
- 在子 Agent 之间**共享**（子 Agent 写文件，主 Agent 读）

一个典型的长任务流程变成：

```
主 Agent 规划
   ├─ spawn("分析A公司财报", "写 /reports/A.md")   → 子Agent自己跑，只回一句摘要
   ├─ spawn("分析B公司财报", "写 /reports/B.md")
   └─ 主 Agent 读 /reports/A.md + /reports/B.md → 写 /reports/对比分析.md
```

主 Agent 的上下文始终很短，因为它只持有「路径」而不是「全文」。

### 3.2 实现一个最小文件系统

```python
from langchain_core.tools import tool
from pathlib import Path
import json

BASE = Path("./workspace")
BASE.mkdir(exist_ok=True)

@tool
def ls(path: str = ".") -> str:
    """列出目录内容。"""
    p = (BASE / path).resolve()
    if not str(p).startswith(str(BASE.resolve())):
        return "非法路径"
    if not p.is_dir():
        return "不是目录"
    return "\n".join(f"{'[d]' if x.is_dir() else '[f]'} {x.name}"
                     for x in sorted(p.iterdir()))

@tool
def write_file(path: str, content: str) -> str:
    """写入文件（覆盖）。用于保存中间产物、笔记、结论。"""
    p = (BASE / path).resolve()
    if not str(p).startswith(str(BASE.resolve())):
        return "非法路径"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"已写入 {path}（{len(content)} 字符）"

@tool
def read_file(path: str, start: int = 0, lines: int = 80) -> str:
    """读文件内容，支持只读一段（start 行起，读 lines 行）。"""
    p = (BASE / path).resolve()
    if not p.exists():
        return "文件不存在"
    content = p.read_text(encoding="utf-8").splitlines()
    total = len(content)
    chunk = content[start:start + lines]
    body = "\n".join(f"{start+i+1}: {l}" for i, l in enumerate(chunk))
    return f"{path}（共 {total} 行，当前 {start+1}~{start+len(chunk)} 行）\n{body}"

@tool
def edit_file(path: str, old: str, new: str) -> str:
    """局部替换文件内容，适合改一小段而不是整篇重写。"""
    p = (BASE / path).resolve()
    text = p.read_text(encoding="utf-8")
    if old not in text:
        return "未找到要替换的文本"
    p.write_text(text.replace(old, new, 1), encoding="utf-8")
    return "已替换"
```

这套工具看起来原始，但它是整个架构的基石。几个设计要点：

- **路径必须校验**，防止 Agent 写出 `../` 逃逸工作区（安全边界，绝对不能省）
- **read_file 支持分段读**。长文档只读需要的那段，比整篇塞进上下文省得多
- **edit_file 用「找旧串换新串」**而不是整篇覆写。整篇覆写会让模型不小心丢掉没重新写出来的部分

### 3.3 文件命名的约定

要让文件系统真正可用，得给 Agent 一套命名规范，否则它会写出 `result.md`、`final_final.md` 这种灾难：

```python
SYSTEM += """

【工作区约定】
- /notes/        放你的中间笔记、临时结论
- /data/         放工具抓回来的原始数据（不要手工编造数据）
- /reports/      放最终产出，一份报告一个文件
- 文件名用英文小写+连字符，包含日期或序号，如 /reports/2026-10-16-a-company.md
- 一个文件只干一件事，不要把十份分析塞进同一个文件
"""
```

---

## 四、核心组件三：子 Agent 派发

### 4.1 为什么要子 Agent

两个硬理由：

**理由一：上下文隔离。** 子任务的过程（它试了几种搜索词、读了几篇文档、排除了什么）是噪声。如果全堆在主 Agent 上下文里，主 Agent 很快就看不见自己的目标了。子 Agent 内部跑几十轮，主 Agent 只收到一句「已完成，结论在 /reports/A.md」。

**理由二：专业化。** 「查财报的子 Agent」和「写摘要的子 Agent」需要不同的系统提示和工具集。混在一个 Agent 里，系统提示会互相干扰。

### 4.2 实现

```python
@tool
def task(description: str, context: str, output_path: str) -> str:
    """把子任务派发给一个子 Agent，返回它的执行摘要。

    Args:
        description: 子任务的完整描述，要自包含（子 Agent 看不到你们的对话历史）
        context: 完成任务所需的背景信息
        output_path: 要求子 Agent 把详细产出写到这个路径
    """
    result = sub_agent.invoke({
        "messages": [("human", f"任务：{description}\n\n背景：{context}\n\n"
                               f"请把详细结果写入 {output_path}，"
                               f"然后只用 200 字以内汇报关键结论。")]
    })
    return f"子任务完成。详见 {output_path}\n摘要：{result.messages[-1].content}"
```

**注意 `description` 要自包含**。子 Agent 没有你和主 Agent 的对话历史，如果只写「分析一下这家公司」，它根本不知道是哪家。这是 `task` 工具最常见的误用。

### 4.3 什么时候该派发，什么时候自己做

派发是有成本的（多一次完整 Agent 运行）。判断标准：

| 该派发 | 自己干 |
|-------|--------|
| 需要大量探索、过程很脏 | 目标明确，一两次调用够 |
| 多个同类任务（分析 10 份文档） | 唯一一次性的任务 |
| 需要不同的系统提示/工具 | 复用现有上下文即可 |
| 预计 > 20 轮工具调用 | 预计 < 10 轮 |

一个实用经验：**如果任务能并行，就一定派发**。串行的短任务不值得。

### 4.4 并行的正确实现

```python
from concurrent.futures import ThreadPoolExecutor

def fan_out(subtasks: list[dict]):
    with ThreadPoolExecutor(max_workers=min(len(subtasks), 5)) as pool:
        results = list(pool.map(
            lambda st: task(st["description"], st["context"], st["output_path"]),
            subtasks
        ))
    return results
```

**但要小心限流**：5 个子 Agent 同时打 LLM API，很容易触发 rate limit。要么控制并发数（上面写了 5），要么给 API 客户端配好限流和重试。

---

## 五、核心组件四：长期记忆

DeepAgents 里的记忆分两层，用途完全不同。

### 5.1 会话内记忆（工作记忆）

就是前面说的文件系统。Agent 在几十轮任务里写的笔记、结论，跑完任务还在盘上。

**关键点：它是「任务级」的。** 开一个新的任务，通常开一个新的工作区（或者根据情况继承）。

### 5.2 跨会话记忆（长期记忆）

面向「这个 Agent 服务同一个用户很久」的场景。用户上周说过自己是做金融的、偏好中文回答、常用某个数据源——这些不该每次都重新问。

```python
@tool
def save_memory(key: str, value: str) -> str:
    """把一条长期事实写入记忆库。key 用命名空间格式，如 user.preference.language"""
    MEMORY[key] = value
    (BASE.parent / "memory.json").write_text(json.dumps(MEMORY, ensure_ascii=False, indent=2))
    return "已记住"

@tool
def recall_memory(query: str) -> str:
    """检索长期记忆中与 query 相关的条目。"""
    hits = [f"{k}: {v}" for k, v in MEMORY.items() if query.lower() in k.lower() or query in v]
    return "\n".join(hits) if hits else "记忆库未找到相关条目"
```

要不要开长期记忆，取决于产品形态。**内部知识库问答类应用，建议关掉**——用户通常不希望自己的提问被永久记住，而且这是合规风险。

### 5.3 记忆的写入时机

不要让 Agent 随手记所有东西，记忆库很快就变垃圾场。明确写进系统提示：

```
只在以下情况调用 save_memory：
1. 用户明确说"记住这个/以后都用这个"；
2. 同一个偏好用户在本次会话中表达了两次以上；
3. 你的输出被用户明确否定，需要记住正确做法。

不要把具体的一次性任务内容写进长期记忆。
```

---

## 六、一套可运行的组装

把上面四块拼起来：

```python
from langchain.agents import create_agent
from langchain_openai import ChatOpenAI

TOOLS = [
    # 规划
    write_todos, update_todo, revise_plan,
    # 文件系统
    ls, read_file, write_file, edit_file,
    # 任务派发
    task,
    # 业务工具（举例）
    web_search, fetch_url,
]

model = ChatOpenAI(model="gpt-4o", temperature=0)

agent = create_agent(
    model=model,
    tools=TOOLS,
    system_prompt=SYSTEM,        # 含规划铁律 + 工作区约定
    state_schema=AgentState,     # 含 todos / current_task 字段
)
```

如果要用上断点续跑、HITL 这些能力，底层换成 LangGraph 的 `create_react_agent` + Checkpointer，DeepAgents 本身就是构建在 LangGraph 之上的。

### 6.1 最小可跑示例

```bash
pip install langchain deepagents langchain-openai
```

```python
from deepagents import create_deep_agent

agent = create_deep_agent(
    tools=[web_search, http_request],
    subagents=[research_subagent, writer_subagent],
    system_prompt="你负责完成长任务，规划优先，中间产物落盘。",
)

result = agent.invoke({
    "messages": [("human", "调研三家向量数据库的部署成本，写一份对比报告到 /reports/vdb-cost.md")]
})
```

`deepagents` 包已经帮你封装好了 todo、文件系统、子 Agent 这些，开箱即用。但**理解它底层在做什么**仍然重要——出问题时你得知道往哪查。

---

## 七、什么时候不要用这套

务实地讲，DeepAgents 是重武器，有明确的适用边界。

### 7.1 不要用的场景

- **简单问答**：「我们年假几天？」——一个检索 + 一次生成就够了，上 DeepAgents 是拿大炮打蚊子，延迟和成本都翻几倍
- **延迟敏感的交互**：用户问一句要等 3 秒。规划 + 拆解 + 多轮运行，怎么都快不起来
- **任务短且确定性高**：流程已经写死（比如「收到工单 → 分类 → 转部门」），这种用 LangGraph 静态图更好，可控性远高于让 Agent 自己规划

### 7.2 适合的场景

- 研究报告、竞品调研、文档对比（长任务、多来源、需要归纳）
- 代码改造类任务（读多个文件、改、验证，动辄几十轮）
- 数据处理流水线（多步、部分步骤可以并行）
- 需要「跨天」完成的任务（有持久化才能接着跑）

一个简单的判断法：**如果人类做这个任务需要列 to-do list，就该给 Agent 也配一个。**

---

## 八、落地时的坑

按踩过的频率排：

1. **让模型自己决定要不要规划，结果它基本不规划。** → 系统提示里写成铁律，并给出「可直接回答」的例外。
2. **子任务描述不带上下文，子 Agent 跑偏。** → `task` 的 description 必须自包含，写清楚公司名、时间范围、要什么格式。
3. **文件命名失控，最后找不着。** → 一开始就给目录约定，写进系统提示。
4. **并发派发触发限流。** → 控制 worker 数，API 客户端配 exponential backoff。
5. **忘了给文件系统做路径校验。** → 一次 `write_file("../../etc/passwd", ...)` 就足够出事。
6. **长任务跑到一半崩了，全得重来。** → 底层必须接 Checkpointer，把状态落到外部存储。
7. **中间产物只写文件不回收，磁盘慢慢涨爆。** → 加一个 TTL 清理策略，任务完成后归档或删除工作区。

---

## 小结

- DeepAgents 的本质是把 Agent 从「上下文内的循环」升级成**「带规划、带外部记忆、能派发子任务的系统」**。这是架构演进，不是新算法。
- 四个核心组件：**规划（todo 工具 + 显式依赖）、虚拟文件系统（受控的读写编辑 + 路径校验）、子 Agent 派发（上下文隔离 + 专业化 + 并行）、长期记忆（跨会话事实，谨慎开启）**。
- 其中收益最大的是**文件系统**：把中间产物卸载到磁盘，上下文里只留路径。这是长任务不崩的关键。
- `deepagents` 包可以直接用，但出问题时要能看懂底层——它建立在 LangGraph 之上。
- **不要对简单任务用它**。判断标准：人类做这活儿要不要列 to-do list，要，就上。

从「一个 ReAct 循环」到「一个能跑几小时任务的系统」，差别不在模型，而在于你有没有给它笔记本、计划表和分工的能力。
