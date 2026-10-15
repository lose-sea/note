# astream_events 做打字机前端：把 Agent 的每一步都推给用户

> 一个 Agent 任务要跑 20 秒。
> 用户盯着空白的对话框 20 秒，然后突然蹦出一大段字。
>
> 体验上的差别不在最终答案，**在中间过程的可见性**。

## 一、三个层级的流式

LangChain 提供了三种流式，粒度依次变细：

| API | 流出来的东西 | 适合 |
|---|---|---|
| `stream()` | 最终输出的 token | 纯聊天（无工具） |
| `astream(stream_mode="updates")` | 每个节点的状态更新 | LangGraph 图 |
| `astream_events()` | **所有内部事件** | 复杂链 / Agent |

**`astream_events` 是唯一能让你看到"链内部发生了什么"的接口**——包括每次检索、每次工具调用、每个 LLM token。

## 二、最小示例

```python
import asyncio

async def main():
    async for event in chain.astream_events("什么是 LCEL", version="v2"):
        print(event["event"], "|", event["name"])

asyncio.run(main())
```

输出大致是：

```
on_chain_start | RunnableSequence
on_chain_start | RunnableParallel
on_retriever_start | VectorStoreRetriever
on_retriever_end | VectorStoreRetriever
on_chat_model_start | ChatOpenAI
on_chat_model_stream | ChatOpenAI
on_chat_model_stream | ChatOpenAI
...
on_chain_end | RunnableSequence
```

**事件类型清单**：

```
on_chat_model_start / stream / end
on_llm_start / stream / end
on_chain_start / stream / end
on_tool_start / end / error
on_retriever_start / end / error
on_prompt_start / end
on_parser_start / end
```

## 三、过滤出你需要的事件

把所有事件打出来太吵。按类型和名字过滤：

```python
async for event in chain.astream_events(inputs, version="v2"):
    kind = event["event"]
    name = event["name"]

    if kind == "on_chat_model_stream":
        # 只关心最终那个 LLM 的 token，不要中间步骤的
        if name == "ChatOpenAI" and event["metadata"].get("langgraph_node") == "generate":
            chunk = event["data"]["chunk"]
            if chunk.content:
                yield chunk.content          # 推给前端
```

`metadata` 里有很多有用的信息：

```python
print(event["metadata"])
# {
#   'ls_provider': 'openai',
#   'ls_model_name': 'gpt-4o-mini',
#   'langgraph_node': 'generate',
#   'langgraph_step': 3,
#   'tags': [...],
#   'run_id': '...',
#   'parent_ids': [...]
# }
```

**`langgraph_node` 是关键**——它告诉你这个 token 是哪个节点产生的，可以据此决定要不要推给用户。

## 四、做成 SSE 推给前端

FastAPI + SSE 是标准组合：

```python
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from langchain_core.runnables import RunnableConfig
import json

app = FastAPI()

async def event_generator(query: str, session_id: str):
    config: RunnableConfig = {"configurable": {"thread_id": session_id}}

    async for event in graph.astream_events({"messages": [("user", query)]},
                                            config=config, version="v2"):
        kind = event["event"]

        # 1. 节点开始：告诉前端"正在做什么"
        if kind == "on_chain_start" and event["name"] in NODE_LABELS:
            yield sse({"type": "step", "node": event["name"],
                       "label": NODE_LABELS[event["name"]]})

        # 2. 工具调用：显示"正在调用 xx 工具"
        elif kind == "on_tool_start":
            yield sse({"type": "tool_start", "tool": event["name"],
                       "args": event["data"].get("input")})

        # 3. LLM token：打字机效果
        elif kind == "on_chat_model_stream":
            content = event["data"]["chunk"].content
            if content and is_final_answer_node(event):
                yield sse({"type": "token", "text": content})

        # 4. 结束
        elif kind == "on_chain_end" and event["name"] == "LangGraph":
            yield sse({"type": "done"})

def sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"

@app.get("/chat")
async def chat(q: str, sid: str):
    return StreamingResponse(event_generator(q, sid), media_type="text/event-stream")
```

前端：

```javascript
const es = new EventSource(`/chat?q=${encodeURIComponent(q)}&sid=${sid}`);

es.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  switch (msg.type) {
    case "step":
      showStatus(`正在${msg.label}…`);
      break;
    case "tool_start":
      showToolCall(msg.tool, msg.args);
      break;
    case "token":
      appendText(msg.text);      // 打字机
      break;
    case "done":
      es.close();
      showStatus("");
      break;
  }
};
```

**这个设计的关键：把"步骤"和"token"分开推。** 步骤让用户知道"系统在干活"，token 让用户看到"答案在生成"。

## 五、`is_final_answer_node` 怎么写

这是最容易出 bug 的地方——**你只想推最终答案的 token，不想推中间推理的 token**。

```python
def is_final_answer_node(event) -> bool:
    return event["metadata"].get("langgraph_node") == "generate_answer"
```

如果节点上带了 tag，更简单：

```python
graph = builder.compile()
# 节点定义时打标签
builder.add_node("generate_answer", generate_answer_node)

# 或者在事件里判断 tags
def is_final(event) -> bool:
    return "final_answer" in event.get("tags", [])
```

更省事的做法是**用 `include_names` / `exclude_names` 过滤**：

```python
async for event in graph.astream_events(
    inputs,
    version="v2",
    include_names=["generate_answer", "retrieve_docs"],    # 只监听这两个
):
    ...
```

## 六、`astream_events` 的版本参数很关键

```python
chain.astream_events(x, version="v2")
```

**`version="v2"` 必须显式指定**。v1 的事件结构和 v2 不同，不指定会走 v1，得到一堆结构不符的事件。

v2 的事件结构：

```python
{
    "event": "on_chat_model_stream",       # 事件类型
    "name": "ChatOpenAI",                  # 组件名
    "run_id": "uuid",                      # 本次运行的 ID
    "parent_ids": ["uuid1", "uuid2"],      # 父级调用链
    "tags": [],
    "metadata": {...},
    "data": {"chunk": AIMessageChunk(...)},  # 事件载荷
}
```

**`parent_ids` 可以用来还原调用树**——需要区分"主链的 token"和"子链的 token"时很有用。

## 七、用事件做实时进度条

有了事件，进度可以精确到"第几个节点"：

```python
TOTAL_STEPS = 4

async def with_progress(graph, inputs, config):
    done = 0
    async for event in graph.astream_events(inputs, config=config, version="v2"):
        if event["event"] == "on_chain_end" and event["name"] in NODE_NAMES:
            done += 1
            yield {"type": "progress", "percent": int(done / TOTAL_STEPS * 100)}
        elif event["event"] == "on_chat_model_stream":
            ...
```

**比"转圈圈"体验好得多**——用户能看到"检索完成 → 分析完成 → 生成中"，心理等待时间大幅缩短。

## 八、流式 + 结构化输出：怎么同时要

一个难点：**你想流式展示，但又需要结构化结果**。

方案一：**两阶段**。先流式输出自然语言，完成后单独调一次结构化输出。

```python
# 阶段 1：流式给用户看
full_text = ""
async for chunk in llm.astream(prompt):
    full_text += chunk.content
    yield sse({"type": "token", "text": chunk.content})

# 阶段 2：结构化抽取（不流式，很快）
data = structured_llm.invoke(f"从下面的内容里抽取字段：\n{full_text}")
yield sse({"type": "data", "data": data.model_dump()})
```

方案二：**流式 JSON 解析**。让模型输出 JSON，用 `JsonOutputParser` 做部分解析：

```python
from langchain_core.output_parsers import JsonOutputParser

parser = JsonOutputParser(pydantic_object=Result)
chain = prompt | llm | parser

async for partial in chain.astream(inputs):
    yield sse({"type": "partial_json", "data": partial})
```

用户能实时看到"字段一个个被填上"的效果。

## 九、几个坑

**① 忘了 `version="v2"`。**
最常犯的错误，事件结构会完全不对。

**② 在 `astream_events` 里做重活。**
事件回调的每一次 `yield` 都在事件循环里。别在这里做数据库写入、大计算——会把流式阻塞成批处理。

**③ 不同模型的 token 边界不同。**
OpenAI 的 chunk 有时是空字符串（用于 tool_calls），要先判空再推。

**④ 客户端断连要清理。**
用户关页面后，后端还在跑 Agent（浪费 token）。要监听断连并取消：

```python
try:
    async for event in graph.astream_events(...):
        yield ...
except asyncio.CancelledError:
    log.info("客户端断开，任务取消")
    raise
```

**⑤ 事件量可能很大。**
一个 20 步的 Agent 可能有上千个事件。**在服务端做聚合**，别把原始事件全推给前端。

## 十、小结

```python
async for event in chain.astream_events(inputs, version="v2"):
    match event["event"]:
        case "on_chain_start":   ...   # 步骤开始
        case "on_tool_start":    ...   # 工具调用
        case "on_chat_model_stream": ...  # token
        case "on_chain_end":     ...   # 结束
```

三个要点：

1. **`version="v2"` 必填**；
2. **用 `metadata["langgraph_node"]` 或 `include_names` 过滤**，只推需要的；
3. **步骤事件和 token 事件分开推**，前者管"在干什么"，后者管"写出了什么"。

把中间过程暴露出来，**用户对"慢"的容忍度会显著提高**——因为他知道系统在干活，而不是卡住了。
