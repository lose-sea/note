# LangChain 入门：Chain、PromptTemplate 和 Memory 到底该怎么用

LangChain 是大部分人接触 Agent 开发的第一个框架，也是被吐槽最多的一个：有人说它太重、抽象太多，有人说它只是把几行代码包了一层。

两种说法都有道理。这篇不吹不黑，只讲三件事：**它的三个核心抽象各自解决什么问题、怎么用最少的抽象把事情做出来、以及什么时候该绕开它直接写**。

---

## 一、先搞清楚它在解决什么

不用框架时，一个「让模型总结一段文字」的调用是这样的：

```python
prompt = f"请用三句话总结以下内容，语言简洁：\n\n{text}"
resp = client.chat.completions.create(
    model="m", messages=[{"role": "user", "content": prompt}])
print(resp.choices[0].message.content)
```

就三步：拼提示词 → 调用 → 取结果。看起来根本不需要框架。

问题出在**需求变复杂之后**：

- 提示词要复用、要带变量、要按场景切换 → 需要模板管理；
- 要「先总结、再翻译、再提取关键词」三步串联 → 需要流程编排；
- 要记住上一轮说了什么 → 需要状态管理；
- 要换个模型、换厂商 → 需要统一接口；
- 要接向量库、接工具、加缓存、加日志 → 需要一堆胶水代码。

LangChain 就是把这些**重复出现的模式**抽成了标准组件。核心价值不在「少写代码」，而在**统一接口**——换模型、换向量库时只改一行配置。

---

## 二、三个核心抽象

### ① ChatModel：统一的模型接口

不管底层是哪家厂商，套一层之后调用方式统一：

```python
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(model="gpt-4o-mini", temperature=0)
msg = llm.invoke("用一句话解释什么是向量数据库")
print(msg.content)
```

这样做的好处是**可替换**：哪天要换成别的模型，只改这一行，下游代码一行不动。

### ② PromptTemplate：提示词模板

把「写死的字符串拼接」变成「带变量的模板」：

```python
from langchain_core.prompts import ChatPromptTemplate

prompt = ChatPromptTemplate.from_messages([
    ("system", "你是{role}。回答不超过 {n} 句话。"),
    ("user", "{question}")
])

chain = prompt | llm            # 用 | 把模板和模型串起来
out = chain.invoke({"role": "资深后端工程师", "n": 3,
                    "question": "Redis 为什么快？"})
print(out.content)
```

注意那个 `|` 符号——这是 LangChain 的 **LCEL（LangChain Expression Language）**，把组件像管道一样接起来。它看着像 shell 的管道，语义也确实类似：左边输出喂给右边。

**模板真正的价值**在于：提示词可以单独版本管理、单独测试、在不同场景复用，不用散落在业务逻辑里。

### ③ Memory：对话记忆

最基础的用法是手动维护消息列表：

```python
from langchain_core.messages import HumanMessage, AIMessage

history = [
    HumanMessage("我叫张三"),
    AIMessage("你好，张三"),
    HumanMessage("我叫什么？"),
]
resp = llm.invoke(history)
```

实际项目里更常用的是**把历史存在外部**（Redis、数据库），每轮取出来拼进去，而不是依赖框架的内存实现——因为服务重启后内存里的历史就没了。

---

## 三、Chain：把步骤串起来

Chain 就是「把几个组件按顺序接起来」。最简单的：

```python
from langchain_core.output_parsers import StrOutputParser

chain = (
    ChatPromptTemplate.from_template("把下面这句话翻译成{lang}：{text}")
    | llm
    | StrOutputParser()          # 把消息对象转成纯字符串
)

print(chain.invoke({"lang": "英语", "text": "今天天气不错"}))
```

三个组件：模板 → 模型 → 输出解析。这就是一条完整的 Chain。

**带分支的 Chain**（比如先分类再走不同处理）用 `RunnableBranch`：

```python
from langchain_core.runnables import RunnableBranch

branch = RunnableBranch(
    (lambda x: "退款" in x["q"], refund_chain),
    (lambda x: "物流" in x["q"], logistics_chain),
    default_chain,
)
```

### LCEL 自带的几个好东西

| 方法 | 作用 |
|---|---|
| `.invoke(x)` | 单条同步调用 |
| `.batch([x1, x2])` | 批量调用，内部并发 |
| `.stream(x)` | 流式输出，做打字机效果 |
| `.with_retry()` | 失败自动重试 |
| `.with_fallbacks([...])` | 主模型挂了自动切备用 |

这几个能力如果自己写，每一个都是几十行。这是框架**最实在的价值**。

---

## 四、一个完整的例子：带记忆的问答

把上面几块拼起来，做一个能记住上下文的问答：

```python
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.output_parsers import StrOutputParser

prompt = ChatPromptTemplate.from_messages([
    ("system", "你是一个乐于助人的助手，回答简洁。"),
    MessagesPlaceholder("history"),      # ★ 历史消息插在这里
    ("human", "{input}"),
])

chain = prompt | llm | StrOutputParser()

history = []
def chat(text):
    out = chain.invoke({"history": history, "input": text})
    history.append(HumanMessage(text))
    history.append(AIMessage(out))
    return out

print(chat("我叫张三"))          # 记住了
print(chat("我叫什么名字？"))     # → 你叫张三
```

`MessagesPlaceholder` 是关键——它给历史消息留了个位置，每轮把 `history` 列表塞进去。

---

## 五、什么时候不要用 LangChain

框架的抽象是有成本的。以下情况建议**直接调 API**：

| 场景 | 建议 |
|---|---|
| 就一两次简单调用 | 别引框架，直接调 SDK |
| 流程非常固定、就两三行 | 框架带来的间接性大于收益 |
| 需要精细控制提示词的每一个 token | LCEL 的模板反而碍事 |
| 团队没人熟悉它 | 调试成本会很高 |

一个实用的做法：**先用 LangChain 快速验证原型，跑通之后把不必要的抽象拆掉**。很多团队最后只保留 `ChatModel` 那一层统一接口，其余自己写。

另外要提醒一句：**LangChain 版本迭代很快，API 变动较大**。查资料时注意版本，v0.1 之前的写法（`LLMChain`、`ConversationChain` 那些）在现在的新版本里已经被 LCEL 取代，混着看会很困惑。

---

## 六、小结

1. LangChain 的核心价值是**统一接口和可复用组件**，不是「省几行代码」。
2. 三个基本抽象：**ChatModel（统一模型）/ PromptTemplate（提示词模板）/ Memory（对话历史）**。
3. Chain 用 `|`（LCEL）把组件串起来，顺带白送批量、流式、重试、降级。
4. `MessagesPlaceholder` 是做多轮对话的关键组件。
5. **简单场景别硬上框架**；原型用框架、生产拆抽象是常见做法。
6. 注意版本——老教程里的 `LLMChain` 那套已经被 LCEL 取代了。

下一篇讲 LangGraph：Chain 只能表达「一条直线」（或简单分支），而 Agent 需要的是**带环的图**——模型可能要回到上一步重来。那是 LangGraph 要解决的问题。
