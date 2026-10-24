# Checkpointer 基础：把图的状态存下来

默认情况下，LangGraph 跑完一张图，状态就随进程消失了——下一次 `invoke` 又是全新开始。要让图「记得」上一次跑到哪、状态是什么，就得用 **Checkpointer（检查点）**：它在每个超级步（super-step）之后，把当前状态按 `thread_id` 快照存起来。

## 一、MemorySaver 最快上手

```python
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import StateGraph, START, END

# ... 定义好 graph（add_node / add_edge）...
app = graph.compile(checkpointer=MemorySaver())
config = {"configurable": {"thread_id": "user-1"}}

app.invoke({"x": 1}, config)
```

两个关键点：① `compile` 时传入 checkpointer；② 调用时带上 `config` 里的 `thread_id`。同一个 `thread_id` 下的所有运行，共享同一份持久状态。

## 二、状态存在哪、怎么取

检查点按 `(thread_id, checkpoint_id)` 组织。你可以事后把某次运行的状态取出来：

```python
state = app.get_state(config)
print(state.values)   # 当前完整状态
print(state.next)     # 下一步要跑的节点（若中断则为非空元组）
```

`state.values` 就是那张图跑完、或跑到某处时的完整 State。

## 三、为什么需要它

- **多轮对话**：同一 thread_id 下，messages 不断追加，无需手动把历史传来传去；
- **可恢复**：图跑到一半崩了，用同一个 config 再 invoke 能接着跑；
- **可观测**：每一步都有快照，配合 Studio 能回看整条轨迹（见「可视化调试」篇）；
- **人机协同前提**：interrupt / 断点恢复都依赖检查点把状态留下来。

## 四、MemorySaver 只是起点

`MemorySaver` 把状态存在内存里，进程一关就没了，只适合本地调试。上生产要用持久后端：`PostgresSaver`、`SqliteSaver`、`RedisSaver` 等（见「持久化上生产」篇）。它们 API 完全一致，只是把存储换成了数据库。

一句话：Checkpointer 是 LangGraph 从「一次性脚本」升级为「有状态服务」的开关。只要 `compile(checkpointer=...)` + 每次带 `thread_id`，图就开始「记事」了。
