# 用 trim_messages 管住上下文长度：长对话不再爆 token

> 客服机器人跑了 40 轮对话后突然报错：
> `This model's maximum context length is 128000 tokens`。
>
> 你翻代码发现——历史消息是"只增不减"的，全量塞给模型。
> 这篇讲怎么科学地裁剪上下文。

## 一、为什么不能"全量塞"

每轮对话都带上全部历史，token 消耗是**平方级增长**的：

| 轮次 | 每轮新增 | 累计 input token（粗算） |
|---|---|---|
| 第 1 轮 | 100 | 100 |
| 第 10 轮 | 100 | ~5,500 |
| 第 40 轮 | 100 | ~82,000 |
| 第 60 轮 | 100 | ~183,000 ❌ |

第 40 轮时你已经在为"前面 39 轮说过的话"反复付费，而且**模型对中间位置的信息注意力很弱**——塞进去 8 万字，它真正用上的可能只有开头和结尾。

所以裁剪不是"省钱的妥协"，而是**提升效果的手段**。

## 二、LangChain 的 trim_messages

`langchain_core.messages.trim_messages` 是官方提供的历史裁剪工具：

```python
from langchain_core.messages import trim_messages, SystemMessage, HumanMessage, AIMessage

trimmer = trim_messages(
    max_tokens=2000,          # 保留的最大 token 数
    strategy="last",          # 从最新往回保留
    token_counter=llm,        # 用哪个模型算 token
    include_system=True,      # 系统消息必须保留
    allow_partial=False,      # 不切半条消息
    start_on="human",         # 裁剪后必须以人类消息开头
)
```

三个参数最关键：

- **`token_counter`**：传模型对象，就用该模型的 tokenizer 精确计算；传函数则按你的规则算。别用 `len(text)//4` 这种估算，中文场景偏差极大。
- **`allow_partial=False`**：宁可少留几条，也不要把一条消息切成两半——切半的消息会让模型读出乱码感。
- **`start_on="human"`**：很多模型（尤其是 Claude 系）要求消息序列以 human 开头。裁完发现开头是 AIMessage，请求会直接被拒。

## 三、接进链里

裁剪器可以作为一个"预处理器"直接挂进 LCEL 链：

```python
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.output_parsers import StrOutputParser

prompt = ChatPromptTemplate.from_messages([
    ("system", "你是技术客服，回答简洁。"),
    MessagesPlaceholder("history"),
    ("human", "{question}"),
])

chain = trimmer | prompt | llm | StrOutputParser()
```

注意裁剪器放在**最前面**——先裁剪再格式化，这样 `MessagesPlaceholder` 拿到的是已经瘦身过的历史。

调用时把完整历史丢进去即可：

```python
result = chain.invoke({
    "history": all_history,     # 可能几百条
    "question": "那退款要多久到账？",
})
```

## 四、只留最近 N 条是不够的

最朴素的做法是"只保留最近 10 条消息"。它有两个硬伤：

**硬伤一：丢掉了"定调"的那条。**
用户第一句说"我是企业版客户，走特殊流程"，第 30 轮时这条早没了。

**硬伤二：工具调用会被截断。**
一条 `AIMessage(tool_calls=[...])` 和它对应的 `ToolMessage` 必须成对出现。只保留最近 10 条，很可能留下 `ToolMessage` 却丢了对应的调用请求，模型会报"无法识别的工具结果"。

`trim_messages` 的 `allow_partial=False` 只是不切单条消息，**并不保证工具调用成对**。要处理这个，得自己后处理：

```python
def fix_tool_pairs(messages):
    """裁掉开头孤立的 ToolMessage，保证工具调用成对。"""
    while messages and isinstance(messages[0], ToolMessage):
        messages.pop(0)
    return messages

trimmed = fix_tool_pairs(trimmer.invoke(all_history))
```

## 五、更好的做法：分级记忆

`trim_messages` 解决"最近上下文"，但**长期信息**要用另一套机制：

```
┌─────────────────────────────────────┐
│ 系统提示词（人设 + 规则）   ← 永久    │
├─────────────────────────────────────┤
│ 长期记忆摘要（前 N 轮压缩）  ← 长期    │
├─────────────────────────────────────┤
│ 最近 K 轮原文              ← trim    │
├─────────────────────────────────────┤
│ 当前问题                   ← 必留    │
└─────────────────────────────────────┘
```

摘要那层可以在对话超过阈值时触发：

```python
SUMMARY_PROMPT = """把下面的对话压缩成不超过 150 字的要点，保留：
1. 用户的身份/偏好等长期信息
2. 已确认的事实和结论
3. 尚未解决的问题

对话：
{history}
"""

def maybe_summarize(history, threshold=30):
    if len(history) < threshold:
        return None
    older = history[:-10]                  # 把较老的部分压缩掉
    return (summary_prompt | llm | StrOutputParser()).invoke(
        {"history": to_text(older)}
    )
```

摘要内容作为一条 `SystemMessage` 插在历史前面，这样它**不会被 `start_on="human"` 规则影响**（因为它在历史之外）。

## 六、参数怎么定

| 场景 | max_tokens 建议 | 说明 |
|---|---|---|
| 客服问答 | 2000~4000 | 单轮信息密度低，留太多是浪费 |
| 代码助手 | 8000~16000 | 上下文里常有长代码块 |
| 文档分析 | 40000+ | 主体是文档而非对话，用另一套逻辑 |
| 多工具 Agent | 4000~8000 | 工具结果占大头，别用对话轮数衡量 |

**判断依据不是"模型上限多少"，而是"模型实际会用多少"**。128K 的模型不代表你要塞 128K。

## 七、小结

- 历史全量塞 = 烧钱 + 效果变差，从第 10 轮开始就要裁剪；
- `trim_messages` 的三要点：`token_counter` 用真模型、`allow_partial=False`、`start_on="human"`；
- 工具调用成对问题要单独处理；
- 长期信息靠"摘要"而不是靠"裁剪"；
- 参数按场景定，不按模型上限定。
