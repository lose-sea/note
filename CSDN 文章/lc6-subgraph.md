# 子图：把一张图嵌进另一张图

当图变复杂，把所有节点平铺在一张图里会越来越难维护。LangGraph 支持**子图（Subgraph）**：把一组相关节点先编成一张独立的小图，再把它整体当成一个节点挂到主图里。结构像函数调用函数，图也能嵌套图。

## 一、先编一张子图

```python
from typing import TypedDict
from langgraph.graph import StateGraph, START, END

class SubState(TypedDict):
    x: int
    ok: bool

def validate(state: SubState) -> SubState:
    return {"ok": state["x"] > 0}

def fix(state: SubState) -> SubState:
    return {"x": 1}

sub = StateGraph(SubState)
sub.add_node("validate", validate)
sub.add_node("fix", fix)
sub.add_edge(START, "validate")
sub.add_edge("validate", "fix")
sub.add_edge("fix", END)
sub_app = sub.compile()
```

## 二、把子图当节点挂上去

主图里只需 `add_node("预处理", sub_app)`，就能像普通节点一样连边：

```python
class MainState(TypedDict):
    x: int
    ok: bool

def main_logic(state: MainState) -> MainState:
    return {"x": state["x"] + 10}

main = StateGraph(MainState)
main.add_node("预处理", sub_app)     # 直接传编译好的子图
main.add_node("主逻辑", main_logic)
main.add_edge(START, "预处理")
main.add_edge("预处理", "主逻辑")
main.add_edge("主逻辑", END)
app = main.compile()
```

当主图走到「预处理」节点时，会**完整执行整张子图**，子图跑完的最终状态再交还给主图，继续走后面的边。

## 三、子图的价值

- **模块复用**：同一张子图可被多张主图引用，改一处全局生效；
- **职责清晰**：每张子图聚焦一件事（清洗、校验、检索……），主图只关心编排；
- **可独立测试**：子图单独 compile 就能跑，不必带着主图一起调；
- **状态隔离**：子图内部状态变化对主图透明，主图只看到子图的输入/输出。

## 四、状态 schema 的衔接

子图和主图的状态可以是同一份，也可以各自独立。若共享同一 `State` 类型，子图节点直接读写主图状态；若子图有自己的状态定义，则通过「主图传入子图需要的字段、子图返回主图关心的字段」来衔接。新手建议先用共享状态，等真出现命名冲突再拆。

一句话：子图让图从「一整张平铺的网」变成「可组合的层级结构」，是构建大型 Agent 系统的必备手段。
