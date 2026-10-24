# MessagesState：消息列表怎么累加

做对话类 Agent，状态里几乎一定会有一个「消息列表」：用户说的、模型回的、工具返回的全堆在里面。前面讲过，这种「累积型字段」要用 reducer 来追加而不是覆盖。LangGraph 已经把这套逻辑封装好了一个开箱即用的状态：`MessagesState`。

## 一、MessagesState 是什么

`MessagesState` 本质上就是一个只含 `messages` 字段的 `TypedDict`，并且 `messages` 已经用 `add_messages` 这个 reducer 声明了「累加」语义：

```python
from langgraph.graph import MessagesState, START, END
from langchain_core.messages import HumanMessage, AIMessage

def chat(state: MessagesState):
    # 返回一个 AIMessage，会被追加进 messages，而不是替换
    return {"messages": [AIMessage(content="你好，我是助手")]}

graph = StateGraph(MessagesState)
graph.add_node("chat", chat)
graph.add_edge(START, "chat")
graph.add_edge("chat", END)
app = graph.compile()

result = app.invoke({"messages": [HumanMessage(content="在吗？")]})
for m in result["messages"]:
    print(type(m).__name__, ":", m.content)
# HumanMessage : 在吗？
# AIMessage    : 你好，我是助手
```

注意：输入里只有 1 条 HumanMessage，输出里变成 2 条——AI 的回复被**追加**进去了。`add_messages` 就是背后的 reducer。

## 二、add_messages 的智能之处

`add_messages` 不只是简单拼接，它还会：

- **去重更新**：如果新消息带 `id` 且已存在，会就地更新而不是重复添加；
- **自动适配类型**：你可以传 `HumanMessage` / `AIMessage` / `ToolMessage` / `SystemMessage`，甚至传纯字典 `{"role":"user","content":"..."}`，它都会规整成标准消息对象；
- **保留顺序**：严格按时间先后累加，天然形成对话时间线。

## 三、为什么不用普通 list + 自己 append

手动 `state["messages"].append(...)` 虽然也能加，但有两个麻烦：一是节点函数里改的是「入参的副本」，不一定回写进状态；二是失去 `add_messages` 的更新/去重能力。用 `MessagesState` 让「消息怎么累积」这件事变成框架约定，省心且不易错。

## 四、自定义时还能加别的字段

`MessagesState` 只有 `messages`。如果你的图还需要别的累积字段，可以自己继承式声明：

```python
from typing import TypedDict, Annotated
from langchain_core.messages import AnyMessage
from langgraph.graph import add_messages

class MyState(TypedDict):
    messages: Annotated[list[AnyMessage], add_messages]
    scratch: Annotated[list, lambda a, b: a + b]   # 自己再加一个累积字段
```

对话 Agent 的「记忆」其实就是这份不断变长的 `messages`。配合后面要讲的「检查点（Checkpointer）」，这份消息列表还能被按会话存下来，实现真正的多轮记忆。这就是下一篇的内容。
