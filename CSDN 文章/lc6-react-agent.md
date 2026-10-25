# 工具调用循环：create_react_agent 实战

如果你只是想要一个「能调工具、会多轮思考」的 Agent，没必要从零搭图。LangGraph 的 `langgraph.prebuilt` 里提供了 **create_react_agent**，一行就能组装出一个标准的 ReAct（推理+行动）循环。

## 一、最简用法

```python
from langchain_openai import ChatOpenAI
from langchain_core.tools import tool
from langgraph.prebuilt import create_react_agent

@tool
def get_weather(city: str) -> str:
    """查询某城市的天气"""
    return f"{city} 今天晴，25℃"

model = ChatOpenAI(model="gpt-4o-mini")
agent = create_react_agent(model, [get_weather])

result = agent.invoke(
    {"messages": [{"role": "user", "content": "北京天气怎么样？"}]}
)
print(result["messages"][-1].content)
```

`create_react_agent(model, tools)` 返回的就是一个**编译好的 LangGraph app**，可以直接 `invoke` / `stream`。默认流程是：模型决定调哪个工具 → 执行工具 → 把结果喂回模型 → 模型继续，直到它认为可以给出最终答案。

## 二、它帮我们省了什么

自己写 ReAct 循环，你要手写：状态定义（messages）、调模型的节点、调工具的节点、判断「是否还要继续」的条件边。而 `create_react_agent` 把这些全封装好了，并且：

- 自动处理 `ToolMessage` 的回写；
- 内置「模型输出 tool_calls 就走工具、否则结束」的条件路由；
- 返回的依然是标准 `MessagesState`，可以无缝接 Checkpointer、流式、子图。

## 三、加持久化就是多轮 Agent

```python
from langgraph.checkpoint.memory import MemorySaver

agent = create_react_agent(model, [get_weather], checkpointer=MemorySaver())
cfg = {"configurable": {"thread_id": "u-1"}}
agent.invoke({"messages": [{"role":"user","content":"北京天气？"}]}, cfg)
agent.invoke({"messages": [{"role":"user","content":"那上海呢？"}]}, cfg)
```

同一 `thread_id` 下，模型记得上一轮问过什么——因为底层就是一张带 MessagesState 的图。

## 四、什么时候不该用它

当你的流程不是标准 ReAct（比如要条件分支、人工审核、子图编排、并行扇出），就该退回手写 `StateGraph`。`create_react_agent` 是「80% 场景的开箱即用」，复杂编排还得自己画图。

一句话：想快就 `create_react_agent`，想完全可控就手写图。两者底层是同一套 LangGraph，随时可以升级。
