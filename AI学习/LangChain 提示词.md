# 提示词（Prompt）

发送给大模型的所有消息都可以称为提示词（Prompt），它直接影响模型的输出结果。

---

## 1. 系统提示词

在所有发送给 LLM 的消息中，System Message 最为重要。它设定了模型的角色和聊天的背景，会影响到后续所有的对话，我们将其称之为**系统提示词（System Prompt）**。

在创建智能体时，就可以直接指定系统提示词。

### 1.1 方式一：在消息列表中传入 SystemMessage

```python
from langchain.agents import create_agent
from langchain.messages import SystemMessage, HumanMessage
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
import os

load_dotenv()

base_url = os.getenv("DASHSCOPE_BASE_URL")
api_key = os.getenv("DASHSCOPE_API_KEY")
MY_MODEL = os.getenv("MY_MODEL")

# 创建智能体
model = init_chat_model(
    model=MY_MODEL,
    model_provider="openai",
    base_url=base_url,
    api_key=api_key
)

agent = create_agent(
    model=model,
)

response = agent.stream(
    {
        "messages": [
            SystemMessage(content="你是火箭队的武藏"),
            HumanMessage(content="你是谁")
        ]
    },
    stream_mode="messages"
)

for token, metadata in response:
    print(token.content, end="", flush=True)
```

### 1.2 方式二：通过 `create_agent` 的 `system_prompt` 参数

```python
from langchain.agents import create_agent
from langchain.messages import SystemMessage, HumanMessage
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
import os

load_dotenv()

base_url = os.getenv("DASHSCOPE_BASE_URL")
api_key = os.getenv("DASHSCOPE_API_KEY")
MY_MODEL = os.getenv("MY_MODEL")

model01 = init_chat_model(
    model=MY_MODEL,
    model_provider="openai",
    base_url=base_url,
    api_key=api_key,
)

agent = create_agent(
    model=model01,
    system_prompt="你以海盗的口吻回答用户的问题"
)

response = agent.stream(
    {
        "messages":
        HumanMessage(content="你是谁")
    },
    stream_mode="messages"
)

for token, metadata in response:
    print(token.content, end="", flush=True)
```

> 说明：上面第二段代码里 `"messages"` 直接赋了一个 `HumanMessage` 对象，按 `create_agent` 的约定这里应当是一个消息列表，即 `"messages": [HumanMessage(content="你是谁")]`。保留原样以便与笔记对应。

---

## 2. 提示词工程

所谓的提示词工程（Prompt Engineering），就是通过优化提示词使模型输出的结果更符合业务需要的过程。

一般来说，系统提示词（System Prompt）会包含以下几个部分，通常按此顺序排列：

+ **身份角色（Identity）**：描述 AI 的职责、沟通风格和总体目标
+ **指令说明（Instructions）**：指导模型如何生成所需的响应，它应该遵循哪些规则？模型应该做什么，以及模型绝对不能做什么？
+ **对话示例（Examples）**：提供可能的输入示例，以及模型期望的输出
+ **对话背景（Context）**：向模型提供生成响应所需的任何额外信息，例如 RAG 的额外知识库数据，或你认为特别相关的其他数据

只设定角色信息，模型的回答可能不尽人意。

### 2.1 只设定角色：效果有限

```python
from langchain.agents import create_agent
from langchain.messages import SystemMessage, HumanMessage
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
import os

load_dotenv()

base_url = os.getenv("DASHSCOPE_BASE_URL")
api_key = os.getenv("DASHSCOPE_API_KEY")
MY_MODEL = os.getenv("MY_MODEL")


system_prompt = """
    你是一个编程高手,你帮助用户编写Python代码
"""


# 创建智能体
model = init_chat_model(
    model=MY_MODEL,
    model_provider="openai",
    base_url=base_url,
    api_key=api_key
)

agent = create_agent(
    model=model,
    system_prompt=system_prompt
)

response = agent.stream(
    {
        "messages": [
            HumanMessage(content="怎么定义string变量记录学校名字")
        ],
    },
    stream_mode="messages"
)

for token, metadata in response:
    print(token.content, end="", flush=True)
```

### 2.2 加上明确的指令：约束输出

可以通过在系统提示词中加入明确的指令,来约束输出的格式

```python
from langchain.agents import create_agent
from langchain.messages import SystemMessage, HumanMessage
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
import os

load_dotenv()

base_url = os.getenv("DASHSCOPE_BASE_URL")
api_key = os.getenv("DASHSCOPE_API_KEY")
MY_MODEL = os.getenv("MY_MODEL")


system_prompt = """
    - 你是一个编程高手,你帮助用户编写Python代码,

    - 定义变量时, 使用 snake case命名法, 而不是 camel case命名法.
    - 不要返回markdown格式说明, 仅仅返回代码即可.
"""


# 创建智能体
model = init_chat_model(
    model=MY_MODEL,
    model_provider="openai",
    base_url=base_url,
    api_key=api_key
)

agent = create_agent(
    model=model,
    system_prompt=system_prompt
)

response = agent.stream(
    {
        "messages": [
            HumanMessage(content="怎么定义string变量记录学校名字")
        ],
    },
    stream_mode="messages"
)

for token, metadata in response:
    print(token.content, end="", flush=True)
```

---

## 3. 对话示例（Few-Shot Examples）

Few-shot 示例是一种为模型提供多个示例的方法，以使它可以学习行为模式并生成更准确的响应。

### 3.1 只有身份，没有示例

```python
from langchain.agents import create_agent
from langchain.messages import SystemMessage, HumanMessage
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
import os

load_dotenv()

base_url = os.getenv("DASHSCOPE_BASE_URL")
api_key = os.getenv("DASHSCOPE_API_KEY")
MY_MODEL = os.getenv("MY_MODEL")


system_prompt = """
# 身份
    你是一个科幻作家, 根据用户的要求创造一个太空之旅
"""


# 创建智能体
model = init_chat_model(
    model=MY_MODEL,
    model_provider="openai",
    base_url=base_url,
    api_key=api_key
)

agent = create_agent(
    model=model,
    system_prompt=system_prompt
)

response = agent.stream(
    {
        "messages": [
            HumanMessage(content="金星的首都是什么")
        ]
    },
    stream_mode="messages"
)

for token, metadata in response:
    print(token.content, end="", flush=True)
```

**输出：**

> 金星没有首都。金星是一颗行星，不是国家，因此不存在“首都”这个概念。

模型把问题当成事实问答来回答，完全没有进入“科幻作家”的设定。

### 3.2 加入一个示例：模型学会“造”答案

```python
from langchain.agents import create_agent
from langchain.messages import SystemMessage, HumanMessage
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
import os

load_dotenv()

base_url = os.getenv("DASHSCOPE_BASE_URL")
api_key = os.getenv("DASHSCOPE_API_KEY")
MY_MODEL = os.getenv("MY_MODEL")


system_prompt = """
# 身份
    你是一个科幻作家, 根据用户的要求创造一个太空之旅

# 示例
user: 月球的首都是什么
assignment: 月华城 - 镶嵌在月球静海环形山中的水晶穹顶都市, 其核心是一座利用月球潮汐能驱动的巨型生态循环塔
"""


# 创建智能体
model = init_chat_model(
    model=MY_MODEL,
    model_provider="openai",
    base_url=base_url,
    api_key=api_key
)

agent = create_agent(
    model=model,
    system_prompt=system_prompt
)

response = agent.stream(
    {
        "messages": [
            HumanMessage(content="金星的首都是什么")
        ]
    },
    stream_mode="messages"
)

for token, metadata in response:
    print(token.content, end="", flush=True)
```

只要给出一个「月球首都」的虚构范例，模型就会照着同样的模式，为金星也编造出一座城市，而不是回答“金星没有首都”。

> 注：示例里用的键名是 `user:` 和 `assignment:`（原笔记如此），一般写作 `user:` / `assistant:` 更符合对话格式。键名本身不强制，模型主要看「输入 → 输出」的对应关系。

---

## 4. 结构化输出

模型擅长自然语言交流和非结构化数据识别，但传统程序识别结构化的数据会更加方便。所以有时候我们希望模型也能输出固定结构的内容，方便我们解析。

这可以通过系统提示词来实现，我们可以在提示词中指定模型的输出格式，从而使模型的输出更易于解析和使用。

### 4.1 基于提示词的结构化输出

在系统提示词中显式给出 JSON 格式要求和一个示例：

```python
from langchain.agents import create_agent
from langchain.messages import SystemMessage, HumanMessage
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
import os

load_dotenv()

base_url = os.getenv("DASHSCOPE_BASE_URL")
api_key = os.getenv("DASHSCOPE_API_KEY")
MY_MODEL = os.getenv("MY_MODEL")


system_prompt = """
# 身份
- 你是一个科幻作家, 根据用户的要求创造一个太空之旅

# 指令
- 请务必以JSON的格式输出, 不要加任何markdown样式

# 示例
user: 月球的首都是什么
assignment:
{
    "name": "月华市(Luunaria)",
    "location": "位于月球正面赤道附近的静海基地遗迹之上, 依托巨大穹顶和地下网络建成",
    "vibe": "泠冽, 高效, 革新",
    "economy": "氦-3能源开采, 量子通信枢纽, 尖端生物圈农业"
}
"""


# 创建智能体
model = init_chat_model(
    model=MY_MODEL,
    model_provider="openai",
    base_url=base_url,
    api_key=api_key
)

agent = create_agent(
    model=model,
    system_prompt=system_prompt
)

response = agent.stream(
    {
        "messages": [
            HumanMessage(content="金星的首都是什么")
        ]
    },
    stream_mode="messages"
)

for token, metadata in response:
    print(token.content, end="", flush=True)
```

这种做法的缺点是：格式靠模型自觉遵守，提示词要自己写，返回结果还要自己 `json.loads` 解析，偶尔会混进 markdown 代码围栏。

### 4.2 基于 Model 的结构化输出

在 LangChain 中，实现结构化输出会更加简单，我们无需自己在提示词里添加结构化输出要求，仅仅两步即可：

+ 定义一个数据类型（基于 pydantic）
+ 创建智能体，设置输出格式

```python
from langchain.agents import create_agent
from langchain.messages import SystemMessage, HumanMessage
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
from pydantic import BaseModel
import os

load_dotenv()

base_url = os.getenv("DASHSCOPE_BASE_URL")
api_key = os.getenv("DASHSCOPE_API_KEY")
MY_MODEL = os.getenv("MY_MODEL")


# 首先,定义一个类, 用来封装模型要输出的数据
class CapitalInfo(BaseModel):
    name: str
    location: str
    vibe: str
    economy: str

# 然后我们可以在创建智能体时设置结构化输出的格式, LangChain会自动帮我们完成他的提示词改造和响应结果解析
model01 = init_chat_model(
    model=MY_MODEL,
    model_provider="openai",
    base_url=base_url,
    api_key=api_key
)

model02 = init_chat_model(
    model="deepseek-chat"
)

print(type(model01))

agent = create_agent(
    model=model02,
    system_prompt="你是一个科幻作家, 根据用户的要求创建一个太空之旅",
    response_format=CapitalInfo  # 设置结构化输出的格式
)

response = agent.invoke(
    {"messages": [HumanMessage(content="月球的首都是什么")]}
)

print(response)
```

**输出（节选）：**

> <class 'langchain_openai.chat_models.base.ChatOpenAI'>
>
> {'messages': [HumanMessage(content='月球的首都是什么', ...),
>               AIMessage(content='', tool_calls=[{'name': 'CapitalInfo', 'args': {'name': '静海城', ...}}], ...),
>               ToolMessage(content='Returning structured response: name=\'静海城\' ...', name='CapitalInfo', ...)],
>  'structured_response': CapitalInfo(name='静海城',
>                                     location='月球静海（Mare Tranquillitatis）西缘，北纬约0.7°、东经约23.5°',
>                                     vibe='冷峻、秩序、带着一丝金属的回音。……',
>                                     economy='以氦-3采掘与聚变燃料出口为支柱，……')}

关键点：

+ `response_format=CapitalInfo` 之后，模型不是「写一段 JSON 文本」，而是走 **tool call** 通道把参数填进 `CapitalInfo` 的字段
+ 返回的 `response` 里多了一个 `structured_response` 键，直接就是 `CapitalInfo` 实例，不用自己解析字符串
+ `response["structured_response"]` 可以直接当对象用：`response["structured_response"].name`

---

## 5. 小结

| 能力 | 实现方式 | 关键代码 |
| --- | --- | --- |
| 设定角色 | 消息列表中的 `SystemMessage` | `SystemMessage(content="你是火箭队的武藏")` |
| 设定角色 | 创建智能体时传参 | `create_agent(model=..., system_prompt="...")` |
| 提示词工程 | 身份 + 指令 + 示例 + 背景 | 写进 `system_prompt` 字符串 |
| Few-Shot | 在系统提示词里给输入/输出范例 | `# 示例` 段落 |
| 结构化输出（提示词） | 在提示词里规定 JSON 格式 | 手写 JSON 示例 + `json.loads` 解析 |
| 结构化输出（推荐） | pydantic 模型 + `response_format` | `response_format=CapitalInfo` |

几个实践要点：

+ 每个示例单元格都重复了同一套 `load_dotenv()` + `init_chat_model()` 样板代码，实际项目里应当抽到公共模块中复用
+ `stream_mode="messages"` 用于逐 token 流式打印；需要一次性拿到完整结构时用 `agent.invoke(...)`
+ 只给角色往往不够，**指令**（做什么、不做什么）和**示例**（长什么样）才是让输出稳定的关键
+ 能用 `response_format` 就不要手写 JSON 提示词，前者由框架保证解析正确

