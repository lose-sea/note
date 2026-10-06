<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 工具调用框架——LangChain 与 LlamaIndex 入门

**承上**：上篇 8-1 我们手写了 ReAct 循环——核心是"反复 思考→行动→观察"。那个裸循环能跑通，但真要做产品，你会立刻撞上三件麻烦事：**工具怎么标准化定义、历史怎么管理、规划逻辑怎么换花样**。这些"胶水代码"每次重写都累。

**本篇**：讲清两大主流框架各自解决什么问题——**LangChain** 是"搭 Agent / 串工作流"的瑞士军刀，**LlamaIndex** 是"把你的数据接进大模型"的专业户（它和阶段 7 的 RAG 是天作之合）。我会给出最小可运行的接入代码，并对比"裸手写"和"用框架"分别在什么场景更划算。

**启下**：框架帮你管了"工具"和"规划"，但还有一个 Agent 绕不开的难题：**它记不住事**——每次对话都是新的，上一轮用户说过什么、中间算出了什么，新一轮全是空白。下一篇 **8-3《记忆机制——短期记忆与长期记忆》** 专治这个。

**学完这一节，你能动手做**：

1. 说清 LangChain 与 LlamaIndex 的定位差异，知道什么时候该用哪个
2. 用 LangChain 的 `tool` 装饰器把任意函数注册成 Agent 工具
3. 用 LlamaIndex 三行代码把本地文档变成可问答的知识库（和 7-4 呼应）
4. 判断"我该不该上框架"——小脚本裸写，大系统上框架

---

## 一、为什么需要框架？先回顾裸循环的痛点

8-1 的 `run_react` 里，我们手动做了四件事，请你现在回看那 160 行代码，它们分别是：

```
① 定义工具字典        TOOLS = {...}
② 解析模型输出         parse_action()  用正则抠 Action
③ 执行工具 + 抓异常     try/except
④ 拼历史、控步数        history.append + max_steps
```

这四点，每个 Agent 都要写一遍。**框架的价值就是把这些"样板代码"抽象成标准组件**，你只填业务（有哪些工具、用什么模型），循环由框架跑。换句话说，框架把"8-1 那 160 行里所有和具体业务无关、但又不得不写的东西"打包好了，你付一点学习成本，换长期的可维护性和少踩坑。

但这里有一个必须反复强调的前提，我甚至愿意把它加粗三遍：**框架不是魔法，它底下还是 ReAct 那套循环；框架的前提是你已经懂 8-1 的原理；不懂原理直接上框架，等于蒙着眼睛开车。** 如果你没学过 8-1，直接上来就用 `AgentExecutor`，一旦报错（比如工具没被识别、循环不终止），你会完全不知道去哪改——因为你看不懂它内部在发生什么。所以本篇的所有内容，都建立在"你已经能手写 ReAct"这个地基之上。

那框架到底替我们多干了哪些脏活？除了上面四点，生产级框架还额外解决这些裸写里没有、但上线后必痛的点：

- **流式输出**（边生成边显示，而不是等全部完成，用户体验差异巨大）；
- **可观测性**（每一步 Thought/Action/Observation 都能用回调 hook 下来做日志、做监控、做计费）；
- **中间件/回调**（统一记 token 消耗、统一错误处理、统一重试）；
- **模型无关**（同一套代码，换 GPT/DeepSeek/Qwen 只改一个配置，不用改业务）；
- **社区生态**（海量现成集成：几百种工具、几十种向量库，不用自己造）。

这些在裸写里都要自己造轮子，而且造得不一定好。框架真正的意义，是让你把精力放在"业务逻辑"而不是"基础设施"上——这正是工程分工的本质：有人造轮子，有人用轮子造车。

## 二、LangChain：Agent 与工作流的事实标准

LangChain 是目前生态最庞大的框架，它的核心理念是**把一切封装成"可组合的链（Chain）"**——提示词是链、模型是链、工具是链、多个链还能再拼成更大的链。对 Agent 来说，最关键的是两样东西：**`@tool` 装饰器**（定义工具）和 **AgentExecutor**（跑循环）。

在深入代码前，先建立一张 LangChain 的"心智地图"，这张图能帮你把后续所有组件对号入座：

```
你的业务意图
    │
    ▼
┌─────────────── LangChain 抽象层 ───────────────┐
│  @tool      把函数变成"模型能懂的工具说明书"      │
│  ChatModel  统一封装各家大模型（OpenAI/DeepSeek） │
│  Prompt     提示词模板（含 ReAct 的 few-shot）    │
│  Agent      把"模型+工具+提示词"捆成决策体        │
│  AgentExecutor  跑循环、数步数、抓异常、回喂      │
└──────────────────────────────────────────────┘
    │
    ▼
真实世界（工具执行结果）
```

你会发现，心智地图里的每一格，都对应 8-1 手写版里的某几行：ChatModel 对应那个 `FakeLLM`、@tool 对应 `TOOLS` 字典、AgentExecutor 对应 `run_react` 的 for 循环。一一对上号，LangChain 就祛魅了。

### 2.1 用 `@tool` 把函数变成工具

```python
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from langchain.agents import create_react_agent, AgentExecutor
from langchain import hub

@tool
def get_weather(city: str) -> str:
    """查询某城市的当前天气。参数 city 是城市中文名。"""
    return f"{city}：晴，26°C"

@tool
def celsius_to_fahrenheit(celsius: float) -> str:
    """把摄氏度换算成华氏度。参数 celsius 是数字。"""
    return f"{celsius * 9 / 5 + 32:.1f}°F"

tools = [get_weather, celsius_to_fahrenheit]

# 选模型（这里用 OpenAI，换成 DeepSeek/Qwen 只需换 base_url 和 api_key）
llm = ChatOpenAI(model="gpt-4o-mini", temperature=0)

# 拉一个社区写好的 ReAct 提示词模板
prompt = hub.pull("hwchase17/react")

agent = create_react_agent(llm, tools, prompt)
executor = AgentExecutor(agent=agent, tools=tools, verbose=True, max_iterations=5)

result = executor.invoke({"input": "北京今天多少度？换算成华氏度是多少？"})
print(result["output"])
```

**逐行看懂**，这一遍请你把自己当成"翻译官"，把每行对应回 8-1：

- `@tool` 装饰器会把函数的**名字、参数类型、docstring** 自动转成模型能读懂的"工具说明书"。所以那行 `"""查询某城市的当前天气..."""` **绝对不能省**——它是模型唯一的判断依据。你 docstring 写得多清楚，模型调得就有多准。经验法则：docstring 里要写清"这个工具干嘛用、每个参数什么类型什么含义、什么情况下该用它"。含糊的 docstring 等于给模型递了一把没标刻度的尺子。
- `create_react_agent` 内部就是 8-1 的 ReAct 循环，但提示词更完善（社区沉淀的 few-shot）、解析更鲁棒（不再是脆弱的正则，而是用模型原生 function calling 或更强的解析器）。这就是为什么框架"更稳"——它把解析失败这个坑（8-1 坑 1）在内部消化了。
- `AgentExecutor` 负责**跑循环、数步数、抓异常、回喂错误**，你不用再写 `max_steps` 和 `try/except` 了——这正是框架替你省的脏活。它的 `max_iterations` 就是 8-1 的 `max_steps`，`verbose=True` 会打印出和 8-1 几乎一模一样的 Thought/Action/Observation。
- `hub.pull("hwchase17/react")` 是拉一个社区维护的提示词模板。它本质上就是我们在 8-1 里手写的"可用工具 + 问题 + Thought/Action/Observation 格式"那套 prompt，只不过被很多人验证过、调过参、修过 bug。

**运行结果**（verbose 模式下的关键片段，真实日志风格）：

```
> Entering new AgentExecutor chain...
Thought: 用户想知道北京天气并换算，我先查天气。
Action: get_weather
Action Input: {"city": "北京"}
Observation: 北京：晴，26°C
Thought: 拿到 26°C，换算成华氏度。
Action: celsius_to_fahrenheit
Action Input: {"celsius": 26}
Observation: 78.8°F
Thought: 已得到结果。
Final Answer: 北京今天晴，26°C，约合 78.8°F
```

你看，`Thought / Action / Observation / Final Answer` 和我们手写的一模一样——**框架只是把这套范式产品化了**。当你亲眼看到框架输出的格式和 8-1 完全一致，那种"原来如此"的感觉就是本专栏反复强调的"先懂原理"的价值。我敢说，凡是先写通 8-1 再来学 LangChain 的人，学起来都是"哇原来就这么点东西"；而跳过 8-1 直接学的人，往往陷入"API 会调但一报错就懵"的困境。

### 2.1.1 亲手实现一个迷你 `@tool`：装饰器到底干了什么

"`@tool` 把函数变成工具"这句话说起来轻巧，但它具体干了什么？如果你答不上来，那你对框架的理解就停留在"会用"层面，一遇到"模型为什么不调我的工具"就只能干瞪眼。其实它的全部工作内容只有两步，朴素得令人惊讶：**① 用 `inspect` 读出函数的签名（有哪些参数、各是什么类型）；② 把 docstring 原封不动收上来当说明书；然后把这两样拼成一份 JSON Schema**。下面这段代码不需要安装 langchain，复制就能跑：

```python
import inspect, json

def tool(fn):
    """自己实现一个迷你版 @tool：把函数签名 + docstring 变成模型能读的“工具说明书”"""
    sig = inspect.signature(fn)
    props = {}
    for name, p in sig.parameters.items():
        props[name] = {
            "type": {"str": "string", "float": "number", "int": "integer"}.get(
                getattr(p.annotation, "__name__", ""), "string"),
            "description": f"参数 {name}",
        }
    fn.__schema__ = {
        "name": fn.__name__,
        "description": (fn.__doc__ or "").strip(),
        "parameters": {"type": "object", "properties": props, "required": list(props)},
    }
    return fn

@tool
def get_weather(city: str) -> str:
    """查询某城市当前天气，返回“晴/雨 + 摄氏度”格式。参数 city 用中文城市名。"""
    return f"{city}：晴，26°C"

@tool
def celsius_to_fahrenheit(celsius: float) -> str:
    """把摄氏度换算成华氏度。参数 celsius 是数字。"""
    return f"{celsius * 9 / 5 + 32:.1f}°F"

tools = [get_weather, celsius_to_fahrenheit]
print(json.dumps([t.__schema__ for t in tools], ensure_ascii=False, indent=2))
```

**运行结果**（节选，省略了部分缩进层级）：

```json
[
  {
    "name": "get_weather",
    "description": "查询某城市当前天气，返回“晴/雨 + 摄氏度”格式。参数 city 用中文城市名。",
    "parameters": {
      "type": "object",
      "properties": {
        "city": { "type": "string", "description": "参数 city" }
      },
      "required": ["city"]
    }
  },
  {
    "name": "celsius_to_fahrenheit",
    "description": "把摄氏度换算成华氏度。参数 celsius 是数字。",
    "parameters": {
      "type": "object",
      "properties": {
        "celsius": { "type": "number", "description": "参数 celsius" }
      },
      "required": ["celsius"]
    }
  }
]
```

看懂了吗？**所谓"注册工具"，最终落地就是这么一段 JSON，它会被拼进发给模型的 `tools` 字段里**。模型看到的从来不是你的 Python 代码，而是这份"说明书"。于是三个结论立刻浮出水面：

- **类型注解（`city: str`）不能省**。没有它，框架只能把参数猜成 `string`，你传 `26`（数字）进去就会在下游炸掉。写清楚 `celsius: float`，上面的字典就会把它映射为 `"number"`。
- **docstring 就是模型唯一的判断依据**。你可以做个实验——把 docstring 删掉，跑出来会是 `"description": ""`，此时模型既不知道这工具干嘛、也不知道何时该用，只能瞎猜。初学者 80% 的"模型乱调工具"事故，根因都在这里。
- **工具数量越多，模型越难选**。每多一个工具，就多一份要读的说明书。经验值：**同一时刻暴露给模型的工具最好控制在 10 个以内**，超过就先用规则做一层路由，再决定给这批候选工具。这招叫"工具分层检索"，是所有大型 Agent 产品的标配。

记住这个迷你实现，以后任何框架的 `@tool`、`ToolSpec`、`FunctionDefinition`，你都能一眼看穿：**它们只是在比谁把这份 JSON 生成得更好看**。

### 2.2 LangChain 的另一种玩法：LCEL 表达式语言

除了 AgentExecutor，LangChain 还有一套叫 **LCEL** 的写法，用管道符 `|` 把组件串起来，像写 Unix 命令一样拼 Agent/Chain。它的好处是延迟更低、支持流式、天然可并行，在生产里越来越主流。简单感受一下：

```python
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_openai import ChatOpenAI

prompt = ChatPromptTemplate.from_template("用一句话解释 {concept}")
model = ChatOpenAI(model="gpt-4o-mini")
chain = prompt | model | StrOutputParser()   # 管道式组合

print(chain.invoke({"concept": "什么是向量数据库"}))
```

这一行 `prompt | model | StrOutputParser()` 就是把"拼提示词 → 调模型 → 解析输出"三步粘成一条链。当你需要把多个步骤串成固定工作流（而不是让模型自由决定先调哪个工具），LCEL 比 AgentExecutor 更可控、更省 token，因为模型只在最后一步参与，前面都是确定性代码。这也是为什么前面说 LangChain 是"瑞士军刀"——它既有"让模型自由发挥"的 Agent 模式，也有"我写死流程"的 Chain 模式，你要根据任务选对刀刃。

### 2.3 LangChain 适合什么

下面这张表请你结合 8-1 的坑一起看，它会告诉你 LangChain 的边界在哪：

| 场景 | 是否适合 | 说明 |
|---|---|---|
| 多工具 Agent（查天气+算数+搜库+发邮件） | ✅ 强项 | 工具编排是它主场，8-1 的循环被封装得最完善 |
| 把多个步骤串成固定工作流 | ✅ 强项（LCEL 表达式语言） | 流程可控、可流式、省 token |
| 纯 RAG 问答（单轮检索+生成） | ⚠️ 有点重 | LlamaIndex 更轻更专，见第三节 |
| 极致定制循环（想改 ReAct 每一步逻辑） | ⚠️ 框架反而碍事 | 裸写更清楚（回到 8-1） |

注意最后一行：框架不是银弹。当你需要"在 ReAct 的每一步都插入自定义逻辑"（比如某步必须走人工审核），框架的封装反而成了束缚，此时裸写 8-1 反而更灵活。所以框架和裸写不是替代，而是"默认用框架，特殊处回落到裸写"的互补关系。

### 2.4 观测与止损：给 Agent 装上仪表盘和刹车

裸写循环时我们踩过的两个坑——死循环（8-1 坑 3）和工具返回过大（8-1 坑 4）——在框架里并不会自动消失，它们只是换了个地方等你。**框架真正比裸写强的地方，是它提供了统一的回调（callback）机制**，让你能在每一次 LLM 调用、每一次工具执行的"开始/结束"时刻插手。这是生产可用性的分水岭：没有观测的 Agent 就是黑盒，你连钱花在哪都不知道。

一个最值得先装的回调，是**预算守卫（budget guard）**：累计步数或 token 任一超限，立刻止损。它的逻辑极其简单，却是所有线上 Agent 的必备件：

```python
class BudgetGuard:
    """极简“预算守卫”：步数与 token 任一超限就强制收手（对应 8-1 的坑 3/坑 4）"""
    def __init__(self, max_steps=5, max_tokens=4000, price_per_million=0.15, rate=7.2):
        self.max_steps = max_steps
        self.max_tokens = max_tokens
        self.price = price_per_million
        self.rate = rate
        self.steps = 0
        self.tokens = 0

    def on_llm_end(self, usage):
        self.steps += 1
        self.tokens += usage["total_tokens"]
        cost = self.tokens / 1e6 * self.price * self.rate
        print(f"[观测] 第 {self.steps} 次 LLM 调用，累计 token={self.tokens}，累计花费≈{cost:.4f} 元")
        if self.steps >= self.max_steps:
            print("[观测] ⚠️ 步数已达上限，准备终止")
        if self.tokens >= self.max_tokens:
            print("[观测] ⚠️ token 已超预算，准备终止")

    @property
    def should_stop(self):
        return self.steps >= self.max_steps or self.tokens >= self.max_tokens

guard = BudgetGuard(max_steps=3, max_tokens=1500)
for usage in [{"total_tokens": 380}, {"total_tokens": 510}, {"total_tokens": 640}]:
    guard.on_llm_end(usage)
    if guard.should_stop:
        print("[观测] 已停止，返回当前能得到的最好答案")
        break
```

**运行结果**：

```
[观测] 第 1 次 LLM 调用，累计 token=380，累计花费≈0.0004 元
[观测] 第 2 次 LLM 调用，累计 token=890，累计花费≈0.0010 元
[观测] 第 3 次 LLM 调用，累计 token=1530，累计花费≈0.0017 元
[观测] ⚠️ 步数已达上限，准备终止
[观测] ⚠️ token 已超预算，准备终止
[观测] 已停止，返回当前能得到的最好答案
```

这段代码虽然短，但它承载了 Agent 工程里最重要的三条实践：

1. **每一次 LLM 调用都要留下痕迹**（步数、token、耗时、工具名）。线上出问题时，这份日志是唯一能还原现场的证据；没有它，你只能对着一个错误答案发呆。
2. **提前终止要返回"当前最好的答案"，而不是抛异常**。用户体验上，"我已经做到这一步了：……"永远优于"服务端错误 500"。这一条决定了你的 Agent 是"产品"还是"玩具"。
3. **预算要同时押在两个维度上**：步数防失控循环，token 防单步暴雷。只防一个，另一个一定会出事。

在 LangChain 里，这段逻辑会挂在 `callbacks=[...]` 上（不同版本写法不同，认准"回调"这个职责去搜即可）；在 LlamaIndex 里改挂在 `Settings.callback_manager`。**API 会变，职责不变**——这正是本节反复强调的学习方法。

## 三、LlamaIndex：把"你的数据"接进大模型

LlamaIndex（原名 GPT Index）的定位比 LangChain 窄但更专业：**专注"数据接入 + 检索"，是 RAG 的一站式方案**。如果你还记得阶段 7，我们手写了切分、Embedding、向量库、检索、重排——LlamaIndex 把这些**全包了**。它的设计哲学是"数据为中心"：你不用管向量怎么存、切分多长，你只要告诉它"我的文档在哪"，它就把一切接好。

一个典型的 LlamaIndex 数据流长这样，把它和阶段 7 的四篇对照看，你会秒懂：

```
./company_docs/*.pdf,*.txt,*.md
        │
        ▼
SimpleDirectoryReader  ── 解析多种格式   （对应 7-1 读文档）
        │
        ▼
自动切分 (Node) + Embedding + 向量索引  ── VectorStoreIndex （对应 7-1/7-2）
        │
        ▼
as_query_engine()  ── 检索 + 拼 Prompt + 调 LLM （对应 7-3/7-4）
        │
        ▼
自然语言答案
```

### 3.1 三行代码把文档变知识库

```python
from llama_index.core import VectorStoreIndex, SimpleDirectoryReader

# 1. 读取本地目录下的所有文档（pdf/word/txt/markdown 都行）
documents = SimpleDirectoryReader("./company_docs").load_data()

# 2. 自动切分 + 向量化 + 建索引（底层就是 7-1~7-3 那套）
index = VectorStoreIndex.from_documents(documents)

# 3. 变成可问答的引擎
query_engine = index.as_query_engine()
print(query_engine.query("无理由退款要几天内申请？"))
```

**这三行背后，LlamaIndex 替你做了**：

- `SimpleDirectoryReader` → 解析多种格式（对应 7-1 的"如何读文档"）；
- `VectorStoreIndex.from_documents` → 默认切分 + 调 Embedding 模型 + 存向量库（对应 7-1、7-2）；
- `as_query_engine` → 自带检索 + 拼 Prompt + 调 LLM（对应 7-3、7-4）。

换句话说，**阶段 7 我们花四篇手写的整套 RAG，LlamaIndex 几行就给你封装好了**。但——注意这个"但"——**你只有先懂 7-1~7-4 的原理，才知道它默认切多大、Embedding 用哪个、重排开没开、该调哪些参数**。框架是加速器，不是替代理解。比如它默认切分大小、默认 top_k 检索几条、是否开递归检索，这些默认值在真实业务里往往要调。不懂原理的人，面对"答案不准"会无从下手；懂的人，立刻知道是切分太碎还是 top_k 太小。这就是为什么本专栏坚持"先手写、再框架"的路线——顺序反了，框架就是黑箱。

### 3.2 LlamaIndex 的进阶能力（不止三行）

LlamaIndex 真正强的地方，是它在"数据"这一层做了大量工程，远不止三行能概括：

- **多种索引**：除了向量索引，还有树索引（总结层级，适合"整体讲讲"类问题）、关键词索引（精确匹配，适合"有没有提到 XX"类问题）、摘要索引，应对不同查询类型；
- **Metadata 过滤**：给每个文档块打标签（部门、日期、语言），查询时按 `department == "法务"` 过滤，避免跨业务串味；
- **Response Synthesis**：检索到多个块后，怎么拼、怎么汇总答案，有多种策略可选（逐块答再汇总、先汇总再答等）；
- **Agent 化检索**：`QueryEngineTool` 可以把一个查询引擎本身变成 Agent 的工具——这就和 8-1 串起来了：你的公司知识库，能被 Agent 当作一个工具随时调用。

感受一下把知识库注册成 Agent 工具（呼应 8-1 第六节），这一步打通了"框架"和"Agent 循环"：

```python
from llama_index.core.tools import QueryEngineTool, ToolMetadata

doc_tool = QueryEngineTool(
    query_engine=query_engine,
    metadata=ToolMetadata(
        name="company_policy",
        description="查询公司制度文档，如退款、考勤、报销政策",
    ),
)
# 这个 doc_tool 可以直接塞进 LangChain 的 AgentExecutor，
# 实现"Agent 既能查天气又能查公司制度"——框架之间也能强强联合
```

### 3.2.1 检索质量的三个旋钮：chunk_size、top_k、rerank

三行代码能跑起来，但"跑起来"和"答得准"之间隔着三个旋钮。这是企业知识库项目成败的关键，也是**只有懂了阶段 7 原理的人才会去调**的地方——不知原理的人面对"答案不准"，只会一筹莫展地重试。

```python
from llama_index.core import Settings, VectorStoreIndex, SimpleDirectoryReader
from llama_index.core.postprocessor import SentenceTransformerRerank

# 旋钮一：切分粒度（对应阶段 7-1）
Settings.chunk_size = 512          # 太小 → 语义被切碎，答案不完整；太大 → 噪声多，稀释重点
Settings.chunk_overlap = 64        # 相邻块的重叠字数，防止一句话被拦腰截断
Settings.embed_model = "local:BAAI/bge-small-zh-v1.5"   # 旋钮零：中文场景务必换中文 embedding

docs = SimpleDirectoryReader("./company_docs").load_data()
index = VectorStoreIndex.from_documents(docs)

# 旋钮二 + 三：先粗召回，再精排（对应阶段 7-3 的重排）
engine = index.as_query_engine(
    similarity_top_k=10,            # 粗召回 10 条：宁可多捞，也别漏掉正确那条
    node_postprocessors=[
        SentenceTransformerRerank(model="BAAI/bge-reranker-base", top_n=3)  # 精排后只留 3 条
    ],
)

resp = engine.query("无理由退款要几天内申请？")
print(resp)
print("\n引用来源：")
for n in resp.source_nodes[:3]:     # 打印出处，做到可溯源（企业刚需）
    meta = n.node.metadata
    print(f"- {meta.get('file_name')} 第 {meta.get('page_label', '?')} 页，相似度 {n.score:.3f}")
```

**典型输出**（真实项目日志风格）：

```
无理由退款需在签收后 7 天内申请，运费由买家承担。

引用来源：
- 售后政策_v3.pdf 第 12 页，相似度 0.912
- 售后政策_v3.pdf 第 13 页，相似度 0.884
- 客服话术手册.docx 第 4 页，相似度 0.771
```

三个旋钮怎么调，给一份可直接照抄的经验表：

| 旋钮 | 调大的效果 | 调小的效果 | 经验起点 |
|---|---|---|---|
| `chunk_size` | 上下文完整，但召回块里噪声多 | 语义精确，但答案可能被截断 | 中文 300~512 字起步 |
| `chunk_overlap` | 减少跨块断裂，代价是重复内容变多 | 省空间，但可能切断关键句 | chunk_size 的 10%~15% |
| `similarity_top_k` | 召回率高，但 prompt 变长、成本上升 | 省 token，但容易漏掉正确片段 | 粗召回 8~10 |
| `top_n`（rerank 后） | 给模型更多参考，但会稀释重点 | 更聚焦，但可能丢证据 | 精排后留 3~5 |

**一个必上生产的建议：永远打印 `source_nodes`。** 企业场景里用户问"凭什么这么说"，你必须能给出文件名和页码；做不到溯源的知识库，法务和合规那一关就过不去。而"先粗召回 + 再精排"这套两段式（阶段 7-3 手写的重排思想），是所有高质量检索系统的通用范式，LlamaIndex 只是帮你把它写成了一行参数。

### 3.2.2 完整桥接：把查询引擎塞进 LangChain 的 Agent

上面 `QueryEngineTool` 那段留了个尾巴——它怎么真的塞进 `AgentExecutor`？完整做法如下。这段代码的价值在于：一旦跑通，**你的 Agent 就同时拥有了"实时查天气的手"和"查公司制度的脑"**，这正是本篇开头说的"框架之间也能强强联合"。

```python
from langchain_core.tools import tool as lc_tool
from langchain.agents import create_react_agent, AgentExecutor

@lc_tool
def company_policy(query: str) -> str:
    """查询公司制度文档，如退款、考勤、报销政策。参数 query 是自然语言问题。"""
    return str(query_engine.query(query))          # query_engine 来自 3.1

tools = [get_weather, celsius_to_fahrenheit, company_policy]   # 2.1 的两个工具 + 知识库
agent = create_react_agent(llm, tools, hub.pull("hwchase17/react"))
executor = AgentExecutor(agent=agent, tools=tools, verbose=True, max_iterations=6)

print(executor.invoke({"input": "公司无理由退款要几天？顺便说下北京今天穿短袖行不行？"})["output"])
```

留意那个 `max_iterations=6`：跨两个工具的复合问题往往需要 3~4 步，把上限卡死在 3 反而会让任务失败。**步数上限要按"任务复杂度 + 1"来设，而不是拍脑袋写个 5**。另外，如果官方桥接件的导入路径在你安装的版本里已经变了（非常常见），最简单可靠的办法就是像上面这样自己用 `@lc_tool` 包一层函数——**框架之间没打通时，永远可以用一个薄函数糊起来**，这招在任何版本、任何框架组合下都成立。

### 3.3 和 LangChain 怎么选（一张决策表）

这是初学者问得最多的问题，我给一张能直接照着做的表：

| 你的主要诉求 | 首选 | 理由 |
|---|---|---|
| 造一个会调多个工具的 Agent | **LangChain** | 工具编排、Agent 循环成熟 |
| 造一个"公司文档问答"系统 | **LlamaIndex** | 数据接入/检索一站式、默认更优 |
| 两者都要（Agent 里检索知识库） | 组合 | LlamaIndex 做检索，LangChain 做 Agent，二者可集成 |
| 学习原理 | 都别急用 | 先把阶段 7、8-1 手写一遍 |

记住一个口诀：**要"动"（调工具、做决策）用 LangChain，要"读"（吃数据、答知识）用 LlamaIndex。** 二者不是非此即彼，生产里常常 LlamaIndex 管"知识"，LangChain 管"大脑"，配合得天衣无缝。

## 四、一个常见误区：框架版本迭代极快

必须提醒，这是无数人踩过的大坑：**LangChain / LlamaIndex 的 API 几乎每个大版本都在变**（`AgentExecutor` vs 新的 `langgraph`、`VectorStoreIndex` 的参数名、`ChatOpenAI` 的导入路径等，每半年就可能大改）。所以：

1. 本文代码展示的是**思路**，具体函数名以你安装版本的官方文档为准（用 `pip show langchain` 看版本）；
2. **别死记函数名，记"它在解决哪一层的麻烦"**——这才是跨版本不变的东西。比如无论 API 怎么变，"把函数变成工具说明书"这个职责永远在，变的只是装饰器叫 `@tool` 还是别的；
3. 生产项目要**锁版本**（`requirements.txt` 里写死 `langchain==x.y.z`），阶段 0-8 讲过依赖管理，这里正好用上。版本飘移是线上事故的高发区。

我自己的经验：与其背 API，不如把 8-1 手写版当"基准实现"，任何框架你都先问自己"它替代了我手写版里的哪一行"。能答上来，这个框架你就真的掌握了；答不上来，说明你还在"调包"而非"理解"。

## 五、裸写 vs 框架：到底什么时候上框架

这是新手最纠结的问题，给一个可操作的判断树，建议你截图保存：

```
你的项目是……
  ├─ 学习原理 / 跑 demo / 一次性脚本  →  裸写（8-1 那套），最直观
  ├─ 要上线、要维护、要多人协作       →  框架，省长期成本
  ├─ 要极致定制循环逻辑              →  裸写，框架反而束缚
  └─ 主要做 RAG 问答                →  LlamaIndex 优先
```

一句话总结：**小脚本裸写，大系统上框架；但无论上不上框架，8-1 的原理是地基，绕不开。** 框架是车，原理是路；没有路，车再好也开不到目的地。

## 六、上手框架前，先想清的三个问题（常见误区问答）

前面讲了框架能做什么，但初学者真正卡住的，往往是"我到底该怎么用才不会踩坑"。这里用三个最高频的提问，把模糊的地方一次讲清。

**问一：我是不是必须先学框架才能做 Agent？**
答：恰恰相反。本专栏的顺序是"先 8-1 裸写，再 8-2 框架"，这是刻意安排的。框架把循环藏起来了，直接学你会失去对"Agent 内部在发生什么"的直觉。正确的路径是：先能手写 ReAct（8-1），再学框架时你做的不是"学新东西"，而是"认出旧东西的新包装"。如果你时间极紧，至少要把 8-1 的循环图（模型→解析→执行→回喂）在脑子里过一遍，再去碰 LangChain。

**问二：LangChain 和 LlamaIndex 能不能只用其中一个？**
答：能，但要看你的主战场。如果你的产品核心是"让模型调一堆工具去干活"（比如自动化办公助手），LangChain 基本够用，它也能做简单 RAG；如果你的产品核心是"让模型吃透你的一大堆文档再问答"（比如企业知识库），LlamaIndex 更顺手，它也能接 Agent。但更常见的成熟架构是"LlamaIndex 管数据检索 + LangChain 管 Agent 编排"，两者通过 `QueryEngineTool` 这种桥接件组合，互不替代。不要陷入"二选一"的思维，它们解决的是不同层的问题。

**问三：框架这么重，我小项目值得引入吗？**
答：值得与否看"生命周期"。如果只是跑个一次性脚本、验证个想法，裸写 8-1 那 160 行反而最快最轻；如果这个项目要长期维护、要加功能、要别人接手，框架的标准化和生态（现成工具、向量库、回调）会显著省事。一个简单的判断：预计代码会超过 500 行、或要迭代三个月以上，就上框架；否则先裸写。另外提醒，框架的"重"主要体现在依赖体积和学习曲线，运行时开销其实不大，所以"重"不该成为你拒绝它的主因，"需不需要它的标准化能力"才是。

再补充一张"选框架 vs 不用的决策对照表"，把这一节和第五节串起来：

| 你的状态 | 建议 | 理由 |
|---|---|---|
| 刚学 Agent、想懂原理 | 裸写 8-1 | 框架会掩盖原理 |
| 跑 demo、验证想法 | 裸写或轻框架 | 快、轻 |
| 做产品、要长期维护 | LangChain/LlamaIndex | 标准化、生态、可观测 |
| 主做 RAG 问答 | LlamaIndex | 数据层更专业 |
| 主做多工具 Agent | LangChain | 编排更成熟 |

最后再强调一次版本问题：你今天抄的教程，半年后可能函数名全变。所以学框架时，**把每个组件对应回 8-1 的哪一行**，比背 API 重要一万倍。能说清"这个装饰器替代了我手写版的 TOOLS 字典"，你就真的学会了；说不清，就是"调包侠"，一升级就废。

## 七、从手写 ReAct 到 LangChain 的逐行迁移

为了让你彻底确信"框架只是包装"，我们把 8-1 的手写版和本节 LangChain 版逐行对一遍。看这张映射表，你会发现一一对应，毫无神秘：

| 8-1 手写版 | LangChain 版 | 说明 |
|---|---|---|
| `TOOLS` 字典 | `@tool` 装饰的函数列表 | 工具定义，框架用 docstring 自动生成说明书 |
| `FakeLLM` / 真 LLM 客户端 | `ChatOpenAI` | 模型封装，框架统一了各家接口 |
| `parse_action` 正则 | 框架内部解析 / function calling | 框架把"坑 1 解析失败"在内部消化了 |
| `try/except` 执行工具 | `AgentExecutor` 内部 | 异常捕获被托管 |
| `history.append` + `max_steps` | `AgentExecutor(max_iterations=5)` | 历史与步数被托管 |
| 手写的 ReAct 提示词 | `hub.pull("hwchase17/react")` | 社区沉淀的更优提示词 |

看到这张表，你应该有一种"拨云见日"的感觉：框架没有发明任何新概念，它只是把你手写时重复写的样板，做成了标准组件。这也解释了为什么框架会"更稳"——`parse_action` 那种脆弱正则，在框架里被换成了模型原生的 function calling，解析成功率大幅提升，对应 8-1 的坑 1 被根治。

迁移的具体做法，给你一个实操步骤，照着做一遍就能把 8-1 的 Agent "升级"成框架版：

1. 把 8-1 的 `TOOLS` 里每个函数，加上类型注解和 docstring，套上 `@tool`；
2. 把 `FakeLLM.generate` 替换成 `ChatOpenAI(...).invoke`；
3. 删掉 `parse_action`、`try/except`、`history.append`、`max_steps` 这些——交给 `AgentExecutor`；
4. 用 `hub.pull` 或自己写 prompt 替代手写的工具说明。

四步之后，你的 Agent 能力完全一样，但代码更短、更稳、可观测。这就是"先懂原理再上框架"的回报：你不是在"学新东西"，而是在"认出旧东西"，迁移成本近乎为零。反过来，如果跳过 8-1 直接学框架，这四步你一步都做不了，因为你看不懂框架在替你省略什么。

## 八、本篇小结

1. **框架不是替代品，是加速器**：底下还是 ReAct 循环，只不过把"定义工具、解析输出、跑循环、管异常、做观测"标准化了。
2. **LangChain = 搭 Agent / 串工作流**；`@tool` 把函数变成工具（docstring 是模型唯一的判断依据，绝不能省），`AgentExecutor` 跑循环管步数；另有 LCEL 管道式串固定流程。
3. **LlamaIndex = 数据接入 + RAG 一站式**；`VectorStoreIndex.from_documents` 三行替代了阶段 7 我们手写的整套切分/向量化/检索；进阶还能把知识库注册成 Agent 工具。
4. **先用框架的前提是你懂原理**：否则参数怎么调、结果为什么错，你根本无从下手。
5. **框架版本迭代快**：锁版本、记"它解决哪层麻烦"而非死记 API。
6. **`@tool` 的本质是生成一份 JSON Schema**：靠 `inspect` 读签名、拿 docstring 当 description——所以类型注解和 docstring 绝对不能省，工具数量也要控制在 10 个以内。
7. **观测与止损是生产可用性的分水岭**：每次 LLM 调用都要记步数/token/工具名，超限时返回"当前最好的答案"而不是抛异常。
8. **检索质量靠三个旋钮**：`chunk_size`（切分粒度）、`similarity_top_k`（粗召回）、`top_n`（精排后），并永远打印 `source_nodes` 做到可溯源。

一句话心法：**框架会变，职责不变。你只要能回答"这个组件替代了我手写版的哪一行"，任何版本升级都追不上你。**

## 九、实战练习（可验证小任务）

1. **装饰器练习**：写一个有 bug 的 `@tool`——故意把 docstring 写成空字符串，观察模型是否乱调工具。验证点：理解 docstring 的关键作用。
2. **加工具**：在 2.1 的代码里新增一个 `add(a, b)` 工具，问 Agent "北京气温加 10 度是多少"，运行确认它先查天气再相加。验证点：工具调用顺序正确。
3. **LlamaIndex 本地跑**：建一个 `./company_docs` 文件夹，放一份 txt（写几条假制度），运行 3.1 三行代码，提问看是否能答出 txt 里的内容。验证点：答案确实来自你的文档而非模型瞎编。
4. **组合实验**：尝试把 3.2 的 `doc_tool` 塞进 2.1 的 `tools` 列表（需要桥接层，可查官方文档），让 Agent 既能查天气又能查制度。验证点：跨框架编排成功。
5. **版本检查**：运行 `pip show langchain langchain-openai llama-index`，记录版本号，体会"锁版本"的必要性。验证点：建立版本意识。
6. **迷你 `@tool` 实验**：给 `celsius_to_fahrenheit` 去掉类型注解再跑一遍 2.1.1 的代码，观察 `parameters.celsius.type` 从 `"number"` 变成 `"string"`。验证点：直观理解类型注解为何是必需品。
7. **预算守卫改造**：把 `BudgetGuard(max_steps=3, max_tokens=1500)` 改成 `max_tokens=500`，看看第几次调用被拦下。验证点：理解"双维度止损"为什么必须都设。
8. **旋钮对照实验**：同一份文档，把 `similarity_top_k` 分别设成 2 和 10，各问 5 个问题，统计正确答案的命中次数。验证点：亲手建立"召回数不够是主要失分点"的直觉。

## 十、延伸阅读与下一步

- **官方文档**：LangChain 的 Agent 模块文档、LlamaIndex 的 `VectorStoreIndex` 文档（版本不同写法不同，以你安装版为准，切勿抄老教程）。
- **概念**：Function Calling（模型原生工具调用）vs ReAct 文本解析——理解为什么新版本框架更偏好 function calling，以及它对 8-1 坑 1 的彻底解决。
- **相关**：LangGraph（LangChain 出品的"有状态图"编排框架）和 AutoGen（微软多 Agent 对话框架），本专栏 8-4 会展开。
- **下一步**：下一篇 **8-3《记忆机制——短期记忆与长期记忆》** 专治 Agent"转头就忘"的毛病，让你的 Agent 能跨轮、跨会话记住用户与上下文。

> 本篇是《大模型开发从 0 到 1》专栏第 43 篇，阶段 8「Agent 智能体开发」第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
