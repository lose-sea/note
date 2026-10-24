# 条件边与路由：让图自己决定下一步

普通边（add_edge）是「一条道走到黑」。但真实业务里，流程几乎总要根据中间结果分叉——比如分类完了该走 A 还是 B，校验不过该回到重写节点。这时就用 **条件边（conditional edge）**：让一个「路由函数」读状态，返回下一个节点的名字。

## 一、add_conditional_edges 的结构

```python
graph.add_conditional_edges(
    source,          # 从哪个节点出发
    router,          # 路由函数：读 state，返回目标节点名（字符串）
    path_map         # 可选：把函数返回值映射到真实节点名
)
```

`router` 是个普通函数，签名 `(state) -> str`。它返回的字符串必须对应某个已注册节点（或通过 `path_map` 映射）。

## 二、一个分类路由的例子

```python
from typing import TypedDict, Literal
from langgraph.graph import StateGraph, START, END

class State(TypedDict):
    text: str
    label: str

def classify(state: State) -> State:
    return {"label": "spam" if "免费" in state["text"] else "normal"}

def route(state: State) -> str:
    return "spam" if state["label"] == "spam" else "normal"

def handle_spam(state: State) -> State:
    return {"label": state["label"] + ":已拦截"}

def handle_normal(state: State) -> State:
    return {"label": state["label"] + ":已回复"}

graph = StateGraph(State)
graph.add_node("classify", classify)
graph.add_node("spam", handle_spam)
graph.add_node("normal", handle_normal)
graph.add_edge(START, "classify")
graph.add_conditional_edges("classify", route)   # 返回值直接就是节点名
graph.add_edge("spam", END)
graph.add_edge("normal", END)

app = graph.compile()
print(app.invoke({"text": "免费领红包", "label": ""})["label"])
```

这里 `route` 返回 `"spam"` 或 `"normal"`，正好是两个节点名，所以不需要 `path_map`。如果路由想返回语义化的字符串（比如 `"block"` / `"reply"`），再用 `path_map={"block":"spam","reply":"normal"}` 转一道即可。

## 三、为什么比 if-else 链更稳

把分叉点抽成「路由函数 + 条件边」，图的结构一眼就能看明白，而且每个分支都是独立节点，便于单独测试、单独重试。对比把所有 if-else 塞进一个巨型函数，条件边的可维护性高得多。

## 四、收口与兜底

条件边有个隐性风险：如果 `router` 返回了一个不存在的节点名，`compile` 或运行时会报错。常见做法：

- **明确列出所有可能分支**，并在 `path_map` 里收口，避免拼写漂移；
- **给「默认分支」**：让 router 永远落到一个存在的节点，必要时加一个 `fallback` 节点承接意外情况；
- **循环靠条件边自己收**：比如「校验失败 → 回到重写」，要在 router 里判断「还没通过就回写，通过了才去 END」。

条件边是 LangGraph 把「流程控制」交给数据驱动的关键。想清楚「在哪分叉、分几叉、每叉去哪」，图就有了真正的判断能力。
