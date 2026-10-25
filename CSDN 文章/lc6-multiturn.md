# 多轮对话：用持久化记住历史

聊天机器人最基础的能力，是「记得刚才聊到哪」。在 LangGraph 里，这件事不是靠把历史消息传来传去，而是靠 **Checkpointer + MessagesState + 同一个 thread_id** 三者配合自动完成的。

## 一、核心就三步

```python
from langgraph.graph import MessagesState, START, END
from langgraph.checkpoint.memory import MemorySaver
from langchain_core.messages import HumanMessage, AIMessage

def bot(state: MessagesState):
    # 真实场景这里调用大模型，读取 state["messages"] 全部历史
    return {"messages": [AIMessage(content="已收到")]}

graph = StateGraph(MessagesState)
graph.add_node("bot", bot)
graph.add_edge(START, "bot")
graph.add_edge("bot", END)
app = graph.compile(checkpointer=MemorySaver())
cfg = {"configurable": {"thread_id": "u-1"}}
```

之后每一次对话，都用**同一个 cfg** 去 invoke：

```python
app.invoke({"messages": [HumanMessage(content="你好")]}, cfg)
app.invoke({"messages": [HumanMessage(content="你叫什么")]}, cfg)
```

注意：每次传入的只是一条新消息，但框架会把它追加到该 thread_id 下已有的 messages 后面。模型看到的，始终是完整历史。

## 二、为什么不用手动拼历史

没有持久化时，你得自己维护一个 list，每次把过去 N 轮塞进 prompt。问题很多：历史会无限变长、跨进程就丢、多个用户要分桶管理。用了 Checkpointer：

- 历史由框架按 thread_id 自动累积（`add_messages` reducer）；
- 不同用户天然隔离，各用各的 thread_id；
- 想截断/总结历史，只需读取 `app.get_state(cfg).values["messages"]` 再做处理。

## 三、常见坑

- **忘了带 thread_id**：每次都传新的/空的 config，图就「失忆」，每轮都是第一次对话；
- **thread_id 复用混乱**：把不同用户的对话混到同一个 thread_id，会串台；
- **历史爆长度**：长期会话 messages 无限增长，需要在节点里加「超长则摘要压缩」的逻辑，而不是无脑全传。

## 四、和生产接上

本地用 MemorySaver 调试没问题，但服务一重启记忆就清空。真正上线要把 Checkpointer 换成 Postgres/Redis 后端，这样即使进程重启，用户的历史仍在。多轮对话的「记忆」，本质上就是被持久化下来的那份 messages。
