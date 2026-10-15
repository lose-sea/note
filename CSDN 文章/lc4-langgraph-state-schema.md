# LangGraph 状态模式设计：TypedDict、Pydantic 和 reducer 怎么选

> 图的 State 是整个 LangGraph 应用的地基。
> 地基没打好，后面全是玄学 bug：
> 状态莫名其妙没更新、列表越跑越长、并发节点互相覆盖。

## 一、State 到底是什么

State 是一个**在节点之间流转的字典**。每个节点：

- **读**：从 State 里拿它需要的数据；
- **写**：返回一个片段，LangGraph 把它合并回 State。

```python
class State(TypedDict):
    question: str
    answer: str
    documents: list[str]

def retrieve(state: State):
    return {"documents": search(state["question"])}   # 只返回要更新的键

def generate(state: State):
    return {"answer": llm.invoke(state["documents"])}  # 注意：这里也是片段
```

**返回的是"增量"，不是"完整状态"**。这是最容易搞错的一点。

## 二、三种定义方式的取舍

### 方式一：`TypedDict`（推荐默认）

```python
from typing import TypedDict

class State(TypedDict):
    question: str
    documents: list[str]
    answer: str
```

优点：轻量、无运行时开销、IDE 补全好。
缺点：**没有运行时校验**——写错键名不报错，只是静默失效。

### 方式二：`Pydantic BaseModel`

```python
from pydantic import BaseModel, Field

class State(BaseModel):
    question: str = Field(description="用户原始问题")
    documents: list[str] = Field(default_factory=list)
    answer: str = ""
```

优点：运行时校验、类型转换、默认值清晰。
缺点：每个 super-step 都要做一次校验，长流程下有性能损耗。

### 方式三：`dataclass`

```python
from dataclasses import dataclass, field

@dataclass
class State:
    question: str
    documents: list[str] = field(default_factory=list)
```

介于两者之间。用的最少。

**选择建议：**

| 场景 | 选哪个 |
|---|---|
| 绝大多数情况 | `TypedDict` ✅ |
| 状态需要严格校验（金额、枚举） | Pydantic |
| 需要给状态加方法 | Pydantic |

## 三、reducer：解决"覆盖 vs 追加"

默认语义是**覆盖**：

```python
def node(state: State):
    return {"documents": ["新文档"]}
# 结果：documents == ["新文档"]，旧的没了
```

想让列表**追加**，用 `Annotated` 指定 reducer：

```python
from typing import Annotated
from operator import add

class State(TypedDict):
    messages: Annotated[list, add]              # 追加
    documents: Annotated[list, add]             # 追加
    retry_count: int                            # 覆盖（默认）
```

`messages` 场景通常用 LangGraph 自带的：

```python
from langgraph.graph.message import add_messages

class State(MessagesState):       # MessagesState 已经定义了 messages: Annotated[list, add_messages]
    ...
```

`add_messages` 比 `operator.add` 聪明——它会按消息 ID 去重、支持 `RemoveMessage` 删除：

```python
from langchain_core.messages import RemoveMessage

def trim_node(state: State):
    # 删掉最老的两条消息
    return {"messages": [RemoveMessage(id=m.id) for m in state["messages"][:2]]}
```

## 四、自定义 reducer

内置的 `add` 不够用时，自己写：

```python
def merge_dict(left: dict, right: dict) -> dict:
    """深合并字典，右边覆盖左边"""
    out = dict(left)
    for k, v in right.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merge_dict(out[k], v)
        else:
            out[k] = v
    return out

def keep_max(left: int, right: int) -> int:
    """只保留更大的值"""
    return max(left, right)

class State(TypedDict):
    config: Annotated[dict, merge_dict]
    best_score: Annotated[int, keep_max]
    messages: Annotated[list, add_messages]
```

`keep_max` 这种 reducer 在"迭代优化"类图里非常有用——**不需要节点自己比较，reducer 自动保留最优值**。

## 五、并发节点的坑：非 reducer 键会冲突

当 `Command(goto=["a", "b"])` 让两个节点并行执行时，如果它们都更新**非 reducer 键**，会报错：

```
InvalidUpdateError: At key 'status': Can receive only one value per step.
```

因为 LangGraph 不知道该保留哪个。

**规则：任何可能被并行更新的键，都必须有 reducer。**

```python
class State(TypedDict):
    results: Annotated[list, add]        # ✅ 并行安全
    status: str                          # ❌ 并行写会冲突
```

对于"状态标志"类的键，可以给一个"后写胜出"的 reducer：

```python
def last_wins(left, right):
    return right

class State(TypedDict):
    status: Annotated[str, last_wins]
```

## 六、子图的状态：共享还是隔离

子图有两种接入方式：

**共享状态**——子图的 State 键是父图的子集：

```python
class ParentState(MessagesState):
    order_id: str
    refund_status: str

class ChildState(MessagesState):
    refund_status: str

sub = sub_builder.compile()
builder.add_node("refund", sub)    # 直接加编译好的子图
```

子图只能读写它声明过的键，父图的其他键在子图内**不可见**。这是好的隔离。

**显式转换**——需要在父图子图之间映射时：

```python
def call_sub(state: ParentState):
    sub_input = {"messages": state["messages"], "refund_status": state["refund_status"]}
    sub_out = sub.invoke(sub_input)
    return {"refund_status": sub_out["refund_status"]}
```

明确转换的代价是啰嗦，好处是**边界清晰、好调试**。

## 七、状态设计的五条经验

**① 键名带上语义前缀。**
`status` 改成 `order_status`、`payment_status`。多智能体场景下这点尤其重要。

**② 大对象别放状态里。**
把整个文档原文放 State，每步都要序列化一遍。**放 ID 或引用，需要时再查。**

**③ 派生数据不要重复存。**
如果 `answer` 能由 `documents` 算出，就别存 `answer`。重复存意味着两个真相来源。

**④ 给"机器可读的产出"留专门字段。**
别把结构化结果塞进 `messages` 里——模型读到会当对话内容。用 `extracted: Annotated[dict, merge_dict]` 这种独立字段。

**⑤ 中间调试信息单开一个键。**

```python
class State(TypedDict):
    messages: Annotated[list, add_messages]
    _trace: Annotated[list, add]        # 下划线前缀表示"非业务数据"
```

## 八、一个完整的例子

把上面的原则用在一个"文档问答 + 重试"的图上：

```python
from typing import Annotated, Literal, TypedDict
from langgraph.graph.message import add_messages
from operator import add

def merge_dict(left: dict, right: dict) -> dict:
    return {**left, **right}

class QAState(TypedDict):
    # 对话
    messages: Annotated[list, add_messages]

    # 业务数据
    question: str                                    # 覆盖：每轮只一个问题
    retrieved: Annotated[list[dict], add]            # 追加：累加召回
    extracted: Annotated[dict, merge_dict]           # 深合并

    # 控制
    retry: Annotated[int, operator.add]              # 累加
    quality: Annotated[float, max]                   # 保留最高分

    # 调试
    _trace: Annotated[list[str], add]
```

注意 `retry` 用 `operator.add`——节点返回 `{"retry": 1}` 表示"加 1"，而不是"设为 1"。这个语义差别很容易混。

## 九、小结

| 需求 | 方案 |
|---|---|
| 默认定义 | `TypedDict` |
| 需要校验 | Pydantic |
| 列表累加 | `Annotated[list, add]` |
| 消息管理 | `MessagesState` / `add_messages` |
| 字典合并 | 自定义 `merge_dict` |
| 保留最优 | `Annotated[float, max]` |
| 并行写同键 | **必须**有 reducer |

一句话：**State 设计得好，图就写对了一半。** 花 10 分钟想清楚"哪些键会被谁改、怎么合并"，能省掉几小时的玄学排查。
