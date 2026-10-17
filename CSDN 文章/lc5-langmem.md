# LangMem：把 Agent 的长期记忆做成一套标准件

Agent 做了三天的客服，用户第四天来问「我上次说的那个问题解决了吗」——它一脸茫然。上下文早清了， session 也换了，它什么都不记得。

这是 Agent 落地时最普遍的能力缺口：**短期上下文谁都有，长期记忆没人管。** 大家各写各的——有人塞 Redis，有人写向量库，有人往系统提示里硬编码一段「用户画像」。攒到最后，记忆这个东西变成一团没有章法的补丁代码。

LangMem 是 LangChain 团队出的记忆 SDK，想把这些补丁变成标准件。这一篇讲清楚它的设计思路、三种记忆形态、怎么用、以及什么时候它对你来说是过度设计。

---

## 一、Agent 记忆到底难在哪

### 1.1 上下文 ≠ 记忆

先说清楚一个容易混的点：**上下文窗口是工作台，不是记忆**。

- 工作台（上下文）：当前任务正在处理的信息，任务结束就可以清空
- 记忆：跨任务、跨会话仍然成立的事实和偏好，需要主动存、主动取

把两者混在一起的后果：要么上下文无限膨胀（成本和延迟爆炸），要么上下文一清，Agent 就失忆（用户体验断裂）。

### 1.2 记忆的三个问题比存储本身更难

很多人以为记忆的难点是「存哪儿」，其实存储是最简单的部分。真正的难点是：

**问题一：什么该记？** 用户随口一句「今天天气真差」不该记，「我是做后端开发的」该记。判断相关性本身就是个模型任务。

**问题二：记了以后怎么用？** 记忆库攒了 5000 条事实，下次回答问题时该取哪几条？全塞进去上下文就爆了，串行全量比对又慢。这是个检索问题。

**问题三：怎么更新和遗忘？** 用户三年前在这家公司，现在跳槽了。旧记忆不删，Agent 会用过期信息回答；删错了，用户觉得「我明明说过你怎么不记得」。

**LangMem 的核心价值就在处理这三个问题，而不是提供一个 KV 存储。**

---

## 二、三种记忆形态

LangMem 把记忆分成三类工程实现，对应三种完全不同的用途。用错类型是常见的翻车点。

### 2.1 语义记忆（Semantic Memory）

> 「是什么」——事实、概念、用户偏好。

例子：
- 用户在一家做跨境电商的公司，负责供应链系统
- 用户的部署环境是 K8s 1.28，不接公网
- 用户偏好中文回答，讨厌客套话

**技术实现**：存向量库，用「当前对话中值得记的事实」做入库键，检索时按相关性取。

**适用**：个性化助手、Agent 的用户画像。

### 2.2 情景记忆（Episodic Memory）

> 「发生过什么」——具体的交互历史、事件序列。

例子：
- 2026-09-12，用户问过「为什么我们的 PG 主从延迟突然涨」，当时定位到是大批量归档导致的
- 上周用户拒绝了一个方案，理由是「不想引入额外组件」

**实现**：带时间戳的事件流，可以按时间范围、参与者、主题检索。

**适用**：需要「连续服务感」的 Agent（客服、运维助手）。它让 Agent 能说「你上次提到的那个问题，按当时的方法试了吗」。

**情景记忆和语义记忆的关键差别**：语义记忆是「去情境化的结论」，情景记忆是「带时间线的过程」。用户上周被拒绝的方案，这是个情景；「用户不喜欢引入额外组件」是从这个情景提炼出的语义。

### 2.3 程序性记忆（Procedural Memory）

> 「怎么做」——成功的做事流程、技能。

例子：
- 「遇到 PG 延迟问题，先查 pg_stat_replication，再看长事务，最后看 IO」
- 「生成 SQL 时，先问用户库版本和字符集，再写」

**实现**：存的是可复用的提示模板、工具调用序列、或者少量示例。本质上是从历史成功轨迹里提炼的「套路」。

**适用**：任务型 Agent 的能力沉淀。这是三类里**最容易被忽略但长期价值最高**的——因为它直接提升任务完成率。

---

## 三、LangMem 是怎么工作的

### 3.1 写入：让模型自己判断记什么

LangMem 的做法不是「记全部对话」，而是两步走：

**第一步：判断值不值得记**

```python
from langmem import create_memory_manager

manager = create_memory_manager(
    "gpt-4o",
    instructions="""从对话中提取值得长期记住的事实。

提取规则：
1. 只提取关于用户身份、偏好、环境、约束的事实，不提取具体任务内容；
2. 每件事写成一句独立、完整、无指代的话；
3. 带时间属性的要标时间；
4. 没有值得记的就返回空列表，不要硬凑。

例子：
对话：我在腾讯做后端，我们 PG 是 14，能上 extension
输出：["用户在腾讯做后端开发", "用户的生产 PostgreSQL 版本是 14，允许安装 extension"]
"""
)

# 每次对话结束，跑一次提取
memories = manager.invoke({"messages": conversation})
```

**第二步：去重与合并**

新提取的事实可能和库里已有的重复、部分矛盾、或是补充。LangMem 会做一次合并判断：

- 库里有「用户的 PG 是 14」，新来一条「用户升级到 PG 16」→ 应该标记旧的过期，写新的
- 库里有「用户做后端」，新来「用户做后端，在腾讯」→ 应该合并成更完整的一条
- 库里已有完全相同的 → 什么都不做

**这一步不做好，记忆库会迅速劣化成一堆互相矛盾的事实。**

### 3.2 读取：注入而不是塞入

记忆的使用方式有两种，别搞混：

```python
# 方式一：作为系统提示的一部分（自动检索 + 注入）
from langmem import create_memory_searcher

searcher = create_memory_searcher("gpt-4o")

chain = memory_hook | prompt_template | model
# memory_hook 在每个请求前，自动检索相关记忆并注入 messages
```

**方式一（自动注入）**适合省心，但你会失去对「到底注入了什么」的控制。排查「Agent 为什么突然说了奇怪的话」时，看不见注入内容很痛苦。

**方式二（显式工具）**更适合生产：

```python
@tool
def recall(query: str, memory_type: str = "all") -> str:
    """查询与该用户的长期记忆。

    Args:
        query: 要查什么，比如"用户的数据库版本"
        memory_type: semantic / episodic / procedural / all
    """
    ...
```

让 Agent **在需要时主动查**，而不是每次都全量注入。这样上下文更干净，也更符合「记忆是按需取用」的直觉。

**我的建议：生产环境用方式二，开发调试用方式一对照。**

### 3.3 遗忘：比你想的重要

LangMem 支持记忆的更新和作废。但更重要的是你要有策略：

```python
@tool
def forget(memory_id: str, reason: str) -> str:
    """把一条记忆标记为失效。reason 会同步记录，便于审计。"""
    ...
```

推荐三条硬规则，写进 Agent 的系统提示：

```
关于记忆维护：
1. 用户明确说"那个已经变了/不适用了" → 立即 forget 旧记忆
2. 新事实与旧记忆冲突 → forget 旧的，写新的，不要并存
3. 不要 forget 你没有十足把握冲突的记忆，不确定就并存并在回复中说明
```

**第 3 条是安全垫。** 自动遗忘很容易误删，「不确定就并存」比「猜着删」安全得多。

---

## 四、一个完整用例

场景：一个帮用户做 SQL 优化的助手，需要记住用户的环境和偏好。

```python
from langchain_openai import ChatOpenAI
from langmem import create_memory_manager, create_memory_searcher
from langchain.agents import create_agent

store = InMemoryStore(  # 生产换 PostgresStore / RedisStore
    index={"dims": 1536, "embed": "openai:text-embedding-3-small"}
)

mem_manager = create_memory_manager("gpt-4o", store=store, instructions=EXTRACT_RULES)
mem_searcher = create_memory_searcher("gpt-4o", store=store)

@tool
def recall_memory(query: str) -> str:
    """查这个用户的环境、偏好、历史（如"用户的MySQL版本"）。"""
    results = mem_searcher.invoke({"query": query, "user_id": user_id})
    return "\n".join(r.value for r in results) or "无相关记忆"

agent = create_agent(
    model=ChatOpenAI(model="gpt-4o"),
    tools=[explain_sql, recall_memory, propose_optimization],
    system_prompt=SQL_SYSTEM,
)

def chat(user_id: str, user_input: str):
    result = agent.invoke({
        "messages": [("human", user_input)],
        "user_id": user_id,
    })
    # 会话结束，提取新记忆
    mem_manager.invoke({
        "messages": result["messages"],
        "user_id": user_id,
    })
    return result["messages"][-1].content
```

注意三点：

1. **`user_id` 贯穿全链路**。记忆必须按用户隔离，忘了这个就是把所有人的记忆混一锅。
2. **记忆提取放在会话结束**，不是每条消息。实时提取太贵且容易记错（后半句可能推翻前半句）。
3. **存储用 InMemoryStore 只是 demo**。生产必须用持久化存储，否则重启全丢。

---

## 五、什么时候值得上，什么时候别上

### 5.1 值得上的信号

- 用户会**多次回来**（客服、私人助手、长期协作）
- 用户环境**复杂且稳定**（自建机房、老旧版本、合规限制），每次重述很烦
- Agent 需要**连续性**（「按上次的方案继续」）
- 你想**沉淀套路**（同类任务反复出现，程序性记忆能提升完成率）

### 5.2 别上的信号（很重要）

- **一次性问答 / 单轮工具类场景**：记忆纯属浪费 token
- **匿名或公开服务**：用户没有身份，记忆无处挂；且留存用户输入有合规风险
- **数据敏感且无合规方案**：记住用户说的话 = 存下用户数据。医疗、金融场景必须先过合规
- **用户量小、任务简单**：一个硬编码的「用户画像」字符串比一整套记忆系统便宜一百倍

**一个反直觉的经验**：绝大多数「Agent 记不住事」的抱怨，根因不是缺记忆系统，而是**缺 user_id**。会话没有关联到同一用户，上下文换了自然全忘。先把这个修好，再考虑要不要上记忆库。

---

## 六、自建 vs 用框架

LangMem 不是唯一选择。对比一下：

| 方案 | 优点 | 缺点 | 适合 |
|------|------|------|------|
| **LangMem** | 三类记忆成型、提取/合并/检索都封装好、接入 LangChain 生态顺畅 | 较新、迭代快（API 可能变）、和框架耦合 | 已在 LangChain/LangGraph 栈里 |
| **Mem0 / Zep** | 成熟产品、有图结构、自带时序推理 | 商业服务（成本、数据出境）、定制受限 | 想省事、不介意 SaaS |
| **自己搭**（向量库 + 定时抽取） | 完全可控、无耦合、便宜 | 去重/合并/冲突处理全自己写，很容易劣化 | 有强定制需求、或有存量存储 |

**自己搭的最小可用版**其实不难，核心就三段：

```python
# 1. 会话结束后抽取
FACTS = llm.invoke(EXTRACT_PROMPT.format(messages=history))

# 2. 先查再定去留
for f in FACTS:
    similar = vectorstore.search(f, top_k=3, threshold=0.9)
    if similar:
        decision = llm.invoke(DEDUCE_PROMPT.format(old=similar, new=f))
        if decision == "SKIP": continue
        if decision == "UPDATE": vectorstore.delete(similar[0].id)
    vectorstore.add(f, metadata={"ts": now, "type": "semantic"})

# 3. 查询时按需取
def recall(query):
    return vectorstore.search(query, top_k=5)
```

但真要做好，难点全在中间那段「去重与冲突处理」的提示词调优上。LangMem 的价值是帮你把这段调好了。

---

## 七、常见坑

1. **不按 user_id 隔离**：这是最严重的 bug，等于把用户记忆互相污染。
2. **实时提取**：每条消息都抽一次，钱烧得快，还容易记下后来被推翻的中间结论。
3. **抽取提示词不设边界**：模型会把「今天天气很差」「用户说了谢谢」全记下来。必须在 instructions 里明确「只记持久事实」。
4. **全量注入记忆**：一问「你好」就把 500 条记忆全塞进系统提示。要么按需查，要么检索后截断到 top 3~5。
5. **没有遗忘策略**：记忆库变成只增不减的事实垃圾场，半年后 Agent 拿着一堆过期信息自信地回答。
6. **忽略合规**：记住用户输入前，先确认这合不合规、要不要脱敏、保留多久。这个不是技术问题，但会出事。

---

## 小结

- 记忆难的**不是存储，是「记什么、怎么取、怎么更新」**。LangMem 的价值在这三件事上，不在它提供的 Store。
- 三类记忆：**语义（事实偏好）、情景（历史事件）、程序性（成功的套路）**。用错类型是最常见的问题——想「连续性」却只用语义记忆，想「能力沉淀」却只存了情景。
- 写入靠模型抽取 + **合并去重**（不做这一步记忆库会迅速劣化）；读取建议**做成按需工具**而不是全量注入，前者上下文更干净、更好排查。
- **遗忘策略必须一开始就有**：冲突时标记旧的失效，不确定就并存，别猜着删。
- 落地先检查 user_id 关联，再考虑上不上记忆系统——多数「失忆」问题根源在前者。
- 敏感场景先过合规关：记住用户的话 = 存下用户数据。

记忆是 Agent 从「一次性工具」变成「长期伙伴」的分水岭。但它是那种「做错了比不做更糟」的功能——错误的记忆会让 Agent 自信地拿着过期信息办事。慎重地加，比激进地加要好。
