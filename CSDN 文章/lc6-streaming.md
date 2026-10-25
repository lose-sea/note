# 流式输出：stream_mode 的四种模式

用户不希望对着一个转圈等十几秒。LangGraph 的 app 支持**流式（streaming）**，边跑边把中间结果推出来。关键是 `stream_mode` 参数，它有四种取值，适用场景各不相同。

## 一、四个模式

```python
for chunk in app.stream(input, stream_mode="values"):
    ...
```

- **values**：每步完成后，推送「当前完整状态」。简单好用，适合轮询展示最新全貌；
- **updates**：只推送「这一步新增的更新」（哪个节点改了哪些字段）。信息最精简，便于增量渲染；
- **messages**：专门推送 LLM 的 token 流（包括中间的思考/工具调用），做「打字机效果」就靠它；
- **custom**：节点里用 `yield` / 自定义事件主动推送你关心的任意内容。

## 二、messages 模式做打字机

```python
for chunk in app.stream(
    {"messages": [{"role":"user","content":"讲个笑话"}]},
    stream_mode="messages",
):
    msg, metadata = chunk
    if msg.content:
        print(msg.content, end="", flush=True)
```

`stream_mode="messages"` 会把模型每次吐出的 token 实时给你，前端直接往屏幕上滚。

## 三、怎么选

- 想看「每一步图在干嘛」→ `updates`；
- 想实时显示「最终状态演进」→ `values`；
- 想做聊天打字机 → `messages`；
- 想在自己节点里定制事件（比如「已检索到 3 篇」）→ `custom`。

## 四、和 Checkpointer 配合

流式不影响持久化：即便边流边出，检查点依然按超级步落盘。用户中途断开重连，用同一个 `thread_id` 重新 `stream` 即可续上。

一句话：流式不是「锦上添花」，而是 Agent 体验的底线。选对 `stream_mode`，你的图既能后台算，也能前台娓娓道来。
