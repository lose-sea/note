# 持久化上生产：Postgres 检查点实战

前面用的 `MemorySaver` 把检查点存在进程内存里，一重启就没了，只能本地调试。要上生产，必须用**持久化后端**。LangGraph 对 Postgres 的支持最成熟，`PostgresSaver` 的 API 和 MemorySaver 完全一致，只是把存储换成了数据库。

## 一、最小可用

```python
from langgraph.checkpoint.postgres import PostgresSaver
from langgraph.graph import StateGraph, START, END

# 先建表（只需一次）
with PostgresSaver.from_conn_string("postgresql://user:pass@host:5432/db") as saver:
    saver.setup()

# 之后每次用同一个 saver 编译
with PostgresSaver.from_conn_string("postgresql://user:pass@host:5432/db") as saver:
    app = graph.compile(checkpointer=saver)
    app.invoke({"x": 1}, {"configurable": {"thread_id": "u-1"}})
```

`PostgresSaver.from_conn_string(...)` 返回一个检查点实例；`saver.setup()` 负责建好所需的表（首次调用即可，后续可省略）。之后所有 `invoke` 的状态都会落到 Postgres。

## 二、两种用法：上下文管理器 vs 长连接

- `with ... as saver`：每次用都新建连接，简单但频繁开关；
- 持有长连接：在服务里初始化一次，多个请求复用，性能更好（注意连接池与线程安全）。

生产服务一般用连接池（如 `psycopg_pool`），避免每请求建连。

## 三、为什么必须是数据库

- **进程重启不丢记忆**：服务更新、崩溃、扩容，用户的历史 thread 仍在；
- **多实例共享状态**：横向扩容后，请求落到任意节点都能恢复同一会话；
- **可审计**：检查点表里天然存了每一步状态，方便排查与回放。

## 四、别忘了清理与容量

检查点会一直累积，生产上要：
- 设定 retention（定期清理老 thread 的检查点）；
- 监控表大小；
- 敏感状态考虑加密存储。

其他可选后端还有 `SqliteSaver`（单机轻量）、`RedisSaver`（高性能缓存式）等，选择取决于你的部署形态。一句话：MemorySaver 用于「我能看到就行」，PostgresSaver 用于「用户能看到、且重启不能丢」。
