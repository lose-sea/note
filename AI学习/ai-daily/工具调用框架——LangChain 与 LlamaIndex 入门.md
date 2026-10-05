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

8-1 的 `run_react` 里，我们手动做了四件事：

```
① 定义工具字典        TOOLS = {...}
② 解析模型输出         parse_action()  用正则抠 Action
③ 执行工具 + 抓异常     try/except
④ 拼历史、控步数        history.append + max_steps
```

这四点，每个 Agent 都要写一遍。**框架的价值就是把这些"样板代码"抽象成标准组件**，你只填业务（有哪些工具、用什么模型），循环由框架跑。

但要注意：**框架不是魔法，它底下还是 ReAct 那套循环**。理解 8-1 之后，框架只是"换了个更顺手的写法"。

## 二、LangChain：Agent 与工作流的事实标准

LangChain 的核心理念是**把一切封装成"可组合的链（Chain）"**。对 Agent 来说，最关键的是两样东西：**`@tool` 装饰器**（定义工具）和 **AgentExecutor**（跑循环）。

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

**逐行看懂**：

- `@tool` 装饰器会把函数的**名字、参数类型、docstring** 自动转成模型能读懂的"工具说明书"。所以那行 `"""查询某城市的当前天气..."""` **不能省**——它是模型唯一的判断依据。
- `create_react_agent` 内部就是 8-1 的 ReAct 循环，但提示词更完善、解析更鲁棒。
- `AgentExecutor` 负责**跑循环、数步数、抓异常**，你不用再写 `max_steps` 和 `try/except` 了。

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

你看，`Thought / Action / Observation / Final Answer` 和我们手写的一模一样——**框架只是把这套范式产品化了**。

### 2.2 LangChain 适合什么

| 场景 | 是否适合 |
|---|---|
| 多工具 Agent（查天气+算数+搜库+发邮件） | ✅ 强项 |
| 把多个步骤串成固定工作流 | ✅ 强项（LCEL 表达式语言） |
| 纯 RAG 问答（单轮检索+生成） | ⚠️ 有点重，LlamaIndex 更轻 |
| 极致定制循环（想改 ReAct 每一步逻辑） | ⚠️ 框架反而碍事，裸写更清楚 |

## 三、LlamaIndex：把"你的数据"接进大模型

LlamaIndex（原名 GPT Index）的定位比 LangChain 窄但更专业：**专注"数据接入 + 检索"，是 RAG 的一站式方案**。如果你还记得阶段 7，我们手写了切分、Embedding、向量库、检索、重排——LlamaIndex 把这些**全包了**。

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

换句话说，**阶段 7 我们花四篇手写的整套 RAG，LlamaIndex 几行就给你封装好了**。但——注意这个"但"——**你只有先懂 7-1~7-4 的原理，才知道它默认切多大、Embedding 用哪个、重排开没开、该调哪些参数**。框架是加速器，不是替代理解。

### 3.2 和 LangChain 怎么选（一张决策表）

| 你的主要诉求 | 首选 |
|---|---|
| 造一个会调多个工具的 Agent | **LangChain** |
| 造一个"公司文档问答"系统 | **LlamaIndex** |
| 两者都要（Agent 里检索知识库） | LlamaIndex 做检索，LangChain 做 Agent，二者可集成 |
| 学习原理 | 都别急用，先把阶段 7、8-1 手写一遍 |

## 四、一个常见误区：框架版本迭代极快

必须提醒：**LangChain / LlamaIndex 的 API 几乎每个大版本都在变**（`AgentExecutor` vs 新的 `langgraph`、`VectorStoreIndex` 的参数名等）。所以：

1. 本文代码展示的是**思路**，具体函数名以你安装版本的官方文档为准（用 `pip show langchain` 看版本）；
2. **别死记函数名，记"它在解决哪一层的麻烦"**——这才是跨版本不变的东西；
3. 生产项目要**锁版本**（`requirements.txt` 里写死 `langchain==x.y.z`），阶段 0-8 讲过依赖管理，这里正好用上。

## 五、本篇小结

1. **框架不是替代品，是加速器**：底下还是 ReAct 循环，只不过把"定义工具、解析输出、跑循环、管异常"标准化了。
2. **LangChain = 搭 Agent / 串工作流**；`@tool` 把函数变成工具（docstring 是模型唯一的判断依据），`AgentExecutor` 跑循环管步数。
3. **LlamaIndex = 数据接入 + RAG 一站式**；`VectorStoreIndex.from_documents` 三行替代了阶段 7 我们手写的整套切分/向量化/检索。
4. **先用框架的前提是你懂原理**：否则参数怎么调、结果为什么错，你根本无从下手。
5. **框架版本迭代快**：锁版本、记"它解决哪层麻烦"而非死记 API。

> 本篇是《大模型开发从 0 到 1》专栏第 43 篇，阶段 8「Agent 智能体开发」第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
