# Agent 的长期记忆落库：别让智能体每次都从零开始

> 用户上周告诉过这个 Agent："我习惯用简体中文，报价一律用人民币"。
> 这周再问，它又问了一遍："请问您希望用什么语言？"
>
> 会话内记忆（`RunnableWithMessageHistory`）解决不了这个问题——
> 它记的是"这次对话"，不是"这个用户"。

## 一、三层记忆，别混为一谈

| 层级 | 生命周期 | 存储 | 典型内容 |
|---|---|---|---|
| 短期记忆 | 单次会话 | 内存 / Redis | 刚才聊了什么 |
| 长期记忆 | 跨会话、绑用户 | 数据库 / 向量库 | 偏好、历史事实 |
| 语义记忆 | 永久、共享 | 向量库 | 知识库、文档 |

很多人把"短期记忆换个持久化后端"当成"长期记忆"，结果就是：**能翻出三个月前的对话原文，但用不上任何一条结论**。

长期记忆的本质是**提炼**——不是存原文，是存"关于这个用户，我们该记住什么"。

## 二、长期记忆的四个动作

一个完整的长期记忆系统，要能回答四个问题：

```
写入（Extract）：从对话里抽出值得记的事实
检索（Retrieve）：需要时把相关事实捞出来
更新（Update）：新信息和旧信息冲突时怎么办
遗忘（Forget）：过期信息怎么清理
```

大多数教程只讲前两个，但**后两个才是线上系统出问题的地方**。

## 三、写入：从对话里抽事实

最简单的方式：每轮对话结束后，让模型判断"这轮里有没有值得长期记住的信息"。

```python
from pydantic import BaseModel, Field
from typing import Literal

class MemoryItem(BaseModel):
    content: str = Field(description="要记住的事实，一句话，第三人称")
    category: Literal["preference", "fact", "goal", "constraint"] = Field(
        description="记忆类型"
    )
    importance: int = Field(description="重要程度 1-5", ge=1, le=5)

class ExtractResult(BaseModel):
    items: list[MemoryItem] = Field(default_factory=list, description="本轮提取的记忆，没有则为空数组")

extractor = llm.with_structured_output(ExtractResult)

EXTRACT_PROMPT = """从下面的对话中提取需要**长期记住**的关于用户的信息。

只提取以下几类：
- preference：用户的偏好（语言、风格、工具选择）
- fact：关于用户的稳定事实（职业、所在团队、常用技术栈）
- goal：用户明确表达的长期目标
- constraint：用户设定的硬性约束（合规要求、不能用某技术）

不要提取：
- 一次性的问题内容
- 可以通过对话历史恢复的信息
- 情绪化表达

对话：
{conversation}
"""
```

写进去的时候带元数据：

```python
def save_memory(user_id: str, items: list[MemoryItem]):
    for it in items:
        if it.importance < 3:          # 低价值记忆直接丢
            continue
        store.upsert(
            namespace=("memories", user_id),
            key=f"{it.category}:{hash(it.content)}",
            value={
                "content": it.content,
                "category": it.category,
                "importance": it.importance,
                "created_at": now(),
            },
        )
```

## 四、检索：什么时候捞、捞什么

**关键设计：不是每次都捞。**

每轮都注入全部记忆，有两个问题：token 白烧、记忆污染（不相关的记忆会干扰模型）。

正确做法是**按需检索**：

```python
def build_context(user_id: str, query: str, k: int = 5):
    # 1. 高重要度的偏好/约束，永远注入
    pinned = store.search(
        namespace=("memories", user_id),
        filter={"category": {"$in": ["preference", "constraint"]},
                "importance": {"$gte": 4}},
        limit=10,
    )

    # 2. 与当前问题相关的记忆，按相似度捞
    relevant = store.search(
        namespace=("memories", user_id),
        query=query,
        limit=k,
    )

    # 3. 去重后合并
    seen, merged = set(), []
    for m in pinned + relevant:
        if m.key not in seen:
            seen.add(m.key)
            merged.append(m)

    return "\n".join(f"- [{m.value['category']}] {m.value['content']}" for m in merged)
```

然后作为系统提示的一部分注入：

```python
system = f"""你是用户 {user_id} 的助手。

以下是关于该用户的长期记忆，请在回答时遵守：
{memory_block}
"""
```

## 五、更新：冲突才是常态

用户上个月说"我主要用 Java"，这个月说"我们迁到 Go 了"。两条记忆都在库里，模型会精神分裂。

三种处理策略：

**策略一：覆盖（最简单，适合强事实）**

```python
def upsert_fact(user_id: str, category: str, content: str):
    # 同 category 的旧事实先失效
    old = store.search(namespace=("memories", user_id),
                       filter={"category": category, "active": True})
    for o in old:
        store.update(o.key, {"active": False, "superseded_by": content})
    store.upsert(namespace=("memories", user_id), key=new_key(),
                 value={"content": content, "category": category, "active": True})
```

**策略二：让模型裁决（适合软偏好）**

```python
MERGE_PROMPT = """现有记忆：
{existing}

新提取的信息：
{new}

请判断：
- 新信息和现有记忆矛盾吗？
- 如果矛盾，是"用户改变了想法"还是"不同场景下的不同偏好"？
- 如果是改变想法，输出 replace；如果是不同场景，输出 coexist 并说明适用场景。
"""
```

**策略三：带时间戳共存，检索时取最新的**

适合"决策日志"类记忆——不删旧的，但排序时按时间倒序。

**线上建议：强事实用策略一，软偏好用策略二，事件记录用策略三。**

## 六、遗忘：三套清理机制

没人清理的记忆库，半年后就是垃圾场。

```python
def cleanup(user_id: str):
    # 1. 过期清理：有 TTL 的记忆
    store.delete(filter={"expire_at": {"$lt": now()}})

    # 2. 低价值清理：长期没被检索到的低重要度记忆
    store.delete(filter={"last_hit_at": {"$lt": now() - days(90)},
                         "importance": {"$lte": 2}})

    # 3. 去重合并：相似度 > 0.95 的记忆合并
    all_mem = store.list(namespace=("memories", user_id))
    for a, b in pairs(all_mem):
        if cosine(a.vector, b.vector) > 0.95:
            keep_newer(a, b)
```

**每次检索都要更新 `last_hit_at`**——这是判断"有没有用"的唯一依据。

## 七、接入 Agent 的完整形态

把上面拼起来，做成一个记忆中间件：

```python
class LongTermMemory:
    def __init__(self, store, llm, user_id):
        self.store, self.llm, self.user_id = store, llm, user_id
        self.extractor = llm.with_structured_output(ExtractResult)

    def before(self, query: str) -> str:
        """注入记忆到上下文"""
        return build_context(self.user_id, query)

    def after(self, conversation: str):
        """对话结束后异步提取并保存"""
        result = self.extractor.invoke(
            EXTRACT_PROMPT.format(conversation=conversation)
        )
        for item in result.items:
            self._merge(item)

    @property
    def id(self):
        return f"memory:{self.user_id}:{self.turn_count}"
```

在 LangGraph 里做成节点最自然：

```python
from langgraph.graph import StateGraph, MessagesState

builder = StateGraph(MessagesState)
builder.add_node("load_memory", load_memory_node)     # 进模型前
builder.add_node("agent", agent_node)
builder.add_node("save_memory", save_memory_node)     # 出结果后
builder.add_edge("load_memory", "agent")
builder.add_edge("agent", "save_memory")
```

## 八、几个必须注意的坑

**① 记忆提取要异步。**
在本轮回复前同步提取，用户会多等 2 秒。放到后台队列，或者放在流式输出结束后触发。

**② 记忆要隔离。**
`namespace=("memories", user_id)` 里的 `user_id` 必须是**服务端鉴权得出的**，绝不能从请求参数里直接取——否则 A 用户能读到 B 用户的记忆。

**③ 别记"助手说的话"。**
只提取关于**用户**的事实。把模型自己的输出也记进去，会让记忆库里充满幻觉。

**④ 记忆内容要能追溯。**
每条记忆记录"来自哪次对话"，出问题时能查证。这也是合规要求（用户有权知道系统记了他什么）。

**⑤ 给用户"查看/删除我的记忆"的入口。**
不只是合规，用户主动纠错的效率远高于模型自己判断。

## 九、小结

长期记忆不是"把历史存起来"，而是这四步循环：

```
抽取 → 检索注入 → 冲突合并 → 定期遗忘
```

最容易被忽略的是后两步。**一个只能写不能改、不能删的记忆系统，用三个月就会变成负担。**

从最小可用版本开始：先只记 `preference` 和 `constraint` 两类高价值记忆，跑通了再加 `fact` 和 `goal`。
