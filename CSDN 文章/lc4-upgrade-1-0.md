# LangChain 1.0 迁移指南：哪些 API 变了，怎么改

> LangChain 1.0 是一次"整理"式的发布：
> 把 0.x 时代积累的多套写法收敛成一套，
> 把散落的入口归并，把"隐式魔法"改成"显式配置"。

## 一、1.0 的核心变化

| 变化 | 0.x 的写法 | 1.0 的写法 |
|---|---|---|
| Agent 入口 | `initialize_agent`、`AgentExecutor` | `create_agent` |
| 状态图 | `langgraph` 独立包 | 内建到 `langchain` |
| 消息管理 | `RunnableWithMessageHistory` | 内建到 Agent |
| 工具 | `@tool` + `BaseTool` | 同样，但类型更严 |
| Chain | `LLMChain`、`RetrievalQA` | LCEL（0.2 起就在推） |
| 输出 | `PydanticOutputParser` | `with_structured_output` |

**大方向：少即是多。** 由多个"能做同一件事"的 API，收敛成一个。

## 二、Agent 的变化（影响最大）

**0.x 的写法**（有多套）：

```python
# 写法 A：initialize_agent
agent = initialize_agent(tools, llm, agent="zero-shot-react-description")
result = agent.run("查一下北京的天气")

# 写法 B：AgentExecutor + create_react_agent
agent = create_react_agent(llm, tools, prompt)
executor = AgentExecutor(agent=agent, tools=tools)
result = executor.invoke({"input": "..."})
```

**1.0 的写法**（统一）：

```python
from langchain.agents import create_agent

agent = create_agent(
    model="openai:gpt-4o-mini",
    tools=[get_weather, search_web],
    system_prompt="你是一个助手，回答前先确认信息是否足够。",
)

result = agent.invoke({"messages": [{"role": "user", "content": "查一下北京的天气"}]})
print(result["messages"][-1].content)
```

**三个显著差异**：

1. **返回值是消息列表**，不再是裸字符串。要拿文本得取 `result["messages"][-1].content`。
2. **模型可以用字符串简写**（`"openai:gpt-4o-mini"`），不需要先实例化 ChatOpenAI。想要更多控制仍然可以传对象。
3. **内置了短期记忆**——传 `thread_id` 即可，不需要手动包裹 `RunnableWithMessageHistory`：

```python
result = agent.invoke(
    {"messages": [{"role": "user", "content": "..."}]},
    config={"configurable": {"thread_id": "user-123"}},
)
```

## 三、记忆的变化

**0.x**：三层套娃

```python
from langchain_community.chat_message_histories import RedisChatMessageHistory
from langchain_core.runnables.history import RunnableWithMessageHistory

def get_history(session_id):
    return RedisChatMessageHistory(session_id, url=REDIS_URL)

chain_with_history = RunnableWithMessageHistory(
    chain,
    get_history,
    input_messages_key="question",
    history_messages_key="history",
)
```

**1.0**：把"持久化后端"变成可插拔的配置

```python
from langgraph.checkpoint.redis import RedisSaver
from langchain.agents import create_agent

with RedisSaver.from_conn_string(REDIS_URL) as checkpointer:
    agent = create_agent(
        model=llm,
        tools=tools,
        checkpointer=checkpointer,       # 记忆后端直接声明
    )

result = agent.invoke(
    {"messages": [...]},
    config={"configurable": {"thread_id": "user-123"}},
)
```

**变化的核心**：记忆从"你要手动包装"变成"**Agent 的内建能力**"。

## 四、`create_agent` 里能配什么

```python
from langchain.agents import create_agent
from langchain.agents.structured_output import ToolStrategy

agent = create_agent(
    model=llm,
    tools=[a, b, c],

    # ① 系统提示
    system_prompt="你是客服助手，回答简洁。",

    # ② 记忆后端
    checkpointer=checkpointer,

    # ③ 跨会话长期记忆
    store=InMemoryStore(),

    # ④ 结构化输出
    response_format=ToolStrategy(MySchema),

    # ⑤ 中间件（1.0 的新概念）
    middleware=[summarization_middleware, retry_middleware],

    # ⑥ 控制细节
    name="customer_agent",
)
```

**`middleware` 是 1.0 新增的抽象**——用来插"在模型调用前后做的事"：

```python
from langchain.agents.middleware import before_model, after_model

@before_model
def summarize_if_long(state, runtime):
    """消息太长就先摘要"""
    if count_tokens(state["messages"]) > 8000:
        return {"messages": [summarize(state["messages"][:-5])] + state["messages"][-5:]}
    return None

@after_model
def log_cost(state, runtime):
    """记录本次调用的成本"""
    log.info("model_called", tokens=...)
    return None

agent = create_agent(model=llm, tools=tools, middleware=[summarize_if_long, log_cost])
```

这比 0.x 里"在链上挂回调"更结构化。

## 五、结构化输出的变化

**0.x**：解析器 + 格式说明

```python
from langchain_core.output_parsers import PydanticOutputParser

parser = PydanticOutputParser(pydantic_object=MySchema)
prompt = ChatPromptTemplate.from_template(
    "回答问题。\n{format_instructions}\n问题：{question}"
).partial(format_instructions=parser.get_format_instructions())

chain = prompt | llm | parser
```

**1.0**：直接在 Agent/模型上声明

```python
from pydantic import BaseModel

class Answer(BaseModel):
    conclusion: str
    confidence: float
    sources: list[str]

agent = create_agent(model=llm, tools=tools, response_format=ToolStrategy(Answer))
result = agent.invoke({"messages": [...]})
print(result["structured_response"])       # Answer 实例
```

**变化**：不用再往提示词里塞 `format_instructions`，框架负责。

## 六、LCEL 的变化：基本没变

好消息是 **LCEL 语法几乎完全兼容**：

```python
chain = prompt | llm | StrOutputParser()      # 1.0 里依然有效
```

但**推荐场景变了**：

| 场景 | 0.x 推荐 | 1.0 推荐 |
|---|---|---|
| 固定的数据流水线 | LCEL | LCEL ✅ |
| 需要循环/条件分支 | LCEL + 自定义 | LangGraph |
| Agent 循环 | AgentExecutor | `create_agent` |
| 需要人工介入 | 手动实现 | LangGraph interrupt |

**规律：确定的流程用 LCEL，动态决策用图/Agent。**

## 七、迁移步骤

**① 先升到 0.3 并清掉警告**

1.0 的大部分改动在 0.3 就埋了废弃警告。**先在 0.3 上把所有 `DeprecationWarning` 清掉**：

```bash
python -W error::DeprecationWarning -c "import your_app" 2>&1 | grep -i deprecat
```

**② 替换 Agent 相关代码**

```
initialize_agent(...)        → create_agent(...)
AgentExecutor(...)           → 不再需要（create_agent 自带循环）
create_react_agent(...)      → create_agent(...)
```

**③ 替换记忆**

删掉 `RunnableWithMessageHistory`，改用 `checkpointer`：

```python
# 删掉
chain_with_history = RunnableWithMessageHistory(chain, get_history, ...)

# 换成
agent = create_agent(model=llm, tools=tools, checkpointer=checkpointer)
```

**④ 改返回值处理**

```python
# 旧
answer = executor.invoke({"input": q})["output"]

# 新
answer = agent.invoke({"messages": [("user", q)]})["messages"][-1].content
```

**⑤ 更新依赖**

```bash
pip install -U "langchain>=1.0" "langchain-core>=1.0" "langchain-openai>=1.0"
```

## 八、几个容易卡住的点

**① `output` 键没有了。**

大量代码在 `result["output"]` 上取值。**全局搜一遍 `["output"]`**：

```bash
grep -rn '\["output"\]' --include="*.py" .
```

**② 消息格式统一。**

旧代码里常见 `{"input": "..."}`、`{"question": "..."}` 这类自定义键。1.0 的 Agent 统一用 `messages`：

```python
# 旧
executor.invoke({"input": "问题", "chat_history": history})

# 新
agent.invoke({"messages": history + [("user", "问题")]})
```

**③ `return_intermediate_steps` 不同。**

旧代码靠这个参数拿中间步骤。1.0 里**中间步骤本来就在 `messages` 里**：

```python
result = agent.invoke({"messages": [("user", q)]})
for m in result["messages"]:
    if m.type == "tool":
        print("工具结果：", m.content)
    elif m.tool_calls:
        print("调用了：", [tc["name"] for tc in m.tool_calls])
```

**④ 自定义 Agent 需要重写。**

如果你实现了自定义的 `BaseSingleActionAgent`，1.0 里这套接口变了。**通常更好的选择是改用 LangGraph 显式建图**——表达能力更强，也更可控。

**⑤ 部分 community 集成滞后。**

一些冷门的 community 集成可能还没适配 1.0。**先在测试环境验证**，别直接上生产。

## 九、值不值得升级

**值得升**：

- 你在用 AgentExecutor（0.x 的 Agent 在可观测性和可控性上确实弱）
- 你想用上内建的 checkpoint / 流式 / 结构化输出
- 你想统一项目里的写法（0.x 项目通常混着三四种风格）

**可以等等**：

- 项目稳定、没有新需求、升级风险大于收益
- 依赖了大量冷门 community 集成

**通用建议**：**先把 0.3 的废弃警告清干净**，这是几乎无风险的准备工作；等 1.x 生态稳定后再切主体代码。

## 十、小结

```python
# 1.0 的核心入口
from langchain.agents import create_agent

agent = create_agent(
    model=llm,
    tools=tools,
    system_prompt="...",
    checkpointer=checkpointer,      # 记忆
    store=store,                    # 长期记忆
    response_format=Schema,         # 结构化输出
    middleware=[...],               # 中间件
)
```

五条迁移要点：

```
1. AgentExecutor → create_agent
2. RunnableWithMessageHistory → checkpointer
3. 返回值取 messages[-1].content
4. 记忆/结构化输出变成声明式配置
5. LCEL 基本不变
```

**1.0 最大的价值不是新功能，而是"只有一种正确写法"。** 对维护者来说，这比任何单个特性都重要。
