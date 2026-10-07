# Agent 的记忆怎么做：短期记忆、长期记忆与一套能跑的实现

> 你有没有遇到过这种对话：
> 你告诉 AI「我叫老王，做后端的」，十轮之后它问你「请问您是从事什么行业的呢？」
> 这不是模型笨，是**你的 Agent 根本没做记忆**。
>
> 大模型每次调用都是无状态的——它只看到你这次发进去的 messages。
> 所谓"记得"，全靠你在外面把历史拼进去。本篇就讲清楚：
> Agent 的记忆分几层、每层怎么存、以及一个能直接跑的实现模板。

## 一、先分清两件事：上下文 ≠ 记忆

很多人把"记忆"简单理解成"把历史对话全塞进 prompt"，这是**最短视的做法**。

| | 上下文（Context） | 记忆（Memory） |
|---|---|---|
| 生命周期 | 单次请求 | 跨会话、跨天 |
| 存放位置 | prompt 里的 messages | 数据库 / 向量库 / 文件 |
| 容量 | 受上下文窗口限制 | 理论无限 |
| 访问方式 | 每次全量传入 | **按需检索** |
| 成本 | 每个 token 都算钱 | 只检索命中的部分算钱 |

关键区别在最后一行：**上下文是全量付费，记忆是按需付费**。

一个聊了 100 轮的会话，如果把全部历史塞进去，
每轮都要为前 99 轮买单——成本随轮数**线性甚至平方级增长**，
而且大量历史跟当前问题毫无关系，纯属污染。

正确的做法是分层：**近期对话放上下文，久远信息进记忆库，用时检索**。

## 二、记忆的三层结构

业界比较通用的分层是这样的：

```
┌─────────────────────────────────────────┐
│  L1 感知层 / 工作记忆（Working Memory）   │  ← 当前这一轮
│  当前输入 + 检索到的记忆 + System Prompt │
├─────────────────────────────────────────┤
│  L2 短期记忆（Short-term Memory）        │  ← 本次会话
│  最近 N 轮对话原文，滑动窗口             │
├─────────────────────────────────────────┤
│  L3 长期记忆（Long-term Memory）         │  ← 跨会话持久化
│  ├ 事实记忆：用户是谁、偏好是什么        │
│  ├ 情节记忆：上次聊了什么、结论是什么    │
│  └ 语义记忆：从对话中提炼出的知识        │
└─────────────────────────────────────────┘
```

**L2 是"刚发生的事"，L3 是"值得记住的事"。**
两者的分界线是**有没有被提炼过**——原文进 L2，提炼后的结论进 L3。

### 2.1 短期记忆：三种压缩策略

历史总会超出窗口，必须压缩。三种策略从简到繁：

**（1）滑动窗口**——只保留最近 N 轮

```python
def sliding_window(history, n=10):
    return history[-n:]
```

最简单，但会**突然遗忘**——第 11 轮之前的信息凭空消失，
如果用户在第 3 轮说了句关键的话，后面就再也找不回来了。

**（2）token 预算截断**——按 token 数而非轮数控制

```python
import tiktoken
enc = tiktoken.get_encoding("cl100k_base")

def truncate_by_token(history, max_tokens=2000, keep_head=1):
    """保留 system（第1条）+ 最近的消息，直到逼近 token 预算"""
    system = history[:keep_head]
    rest = history[keep_head:]
    kept, total = [], sum(len(enc.encode(m["content"])) for m in system)
    for msg in reversed(rest):        # 从最近的往前加
        cost = len(enc.encode(msg["content"]))
        if total + cost > max_tokens:
            break
        kept.insert(0, msg)
        total += cost
    return system + kept
```

比滑动窗口稳，因为长话轮不会把窗口挤爆。

**（3）摘要压缩**——把旧的对话让模型自己总结成一段话

```python
def summarize_history(client, old_messages, previous_summary=""):
    prompt = f"""请将以下对话压缩为一段不超过 200 字的记忆摘要。
要求：保留用户的关键事实、已确认的结论、未完成的待办；丢弃寒暄和重复内容。
已有摘要：{previous_summary or "（无）"}

对话内容：
{chr(10).join(f"{m['role']}: {m['content']}" for m in old_messages)}
"""
    r = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": prompt}],
        temperature=0,
    )
    return r.choices[0].message.content
```

这是**生产环境的标配**：超出窗口的部分滚入摘要，摘要本身也可以再次压缩（递归摘要）。
成本是多一次小模型调用，收益是"永不突然失忆"。

### 2.2 长期记忆：写什么、怎么取

**写入时机**是设计的核心。两种流派：

- **显式写入**：用户说"记住我喜欢……"才存。可控但覆盖率低
- **隐式抽取**：每轮结束后让模型判断"这段有没有值得长期记住的"。覆盖率高质量依赖抽取 prompt

生产上一般**两者结合**。隐式抽取的实现：

```python
import json

EXTRACT_PROMPT = """从下面的对话中抽取值得长期记住的事实。
只输出 JSON 数组，每项形如 {"type": "profile|preference|fact|todo", "content": "..."}。
没有值得记的就输出 []。不要杜撰，必须是用户明确表达过的。

对话：
{dialog}
"""

def extract_memories(client, dialog):
    r = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[{"role": "user",
                   "content": EXTRACT_PROMPT.format(dialog=dialog)}],
        response_format={"type": "json_object"},
        temperature=0,
    )
    try:
        data = json.loads(r.choices[0].message.content)
        return data if isinstance(data, list) else data.get("items", [])
    except Exception:
        return []      # 抽取失败就跳过，绝不能因为记忆模块搞挂主流程
```

注意最后那行——**记忆模块的任何异常都必须吞掉**。
它只是增强，不能成为单点故障。

**检索**用向量相似度就够了，注意按 `type` 分开存：

```python
class LongTermMemory:
    def __init__(self, collection, embed_fn):
        self.coll, self.embed = collection, embed_fn

    def add(self, items, user_id):
        if not items:
            return
        self.coll.add(
            documents=[i["content"] for i in items],
            ids=[f"{user_id}-{hash(i['content'])}" for i in items],
            metadatas=[{"user_id": user_id, "type": i["type"]} for i in items],
        )

    def recall(self, query, user_id, k=5):
        """只检索当前用户的记忆 —— 这个过滤不能省"""
        return self.coll.query(
            query_texts=[query],
            n_results=k,
            where={"user_id": user_id},
        )["documents"][0]
```

`where={"user_id": user_id}` 这行看似平淡，实则是**多用户系统的生死线**。
漏了它，A 用户会读到 B 用户的隐私。

## 三、组装：一个完整可用的记忆管理器

```python
class AgentMemory:
    def __init__(self, client, ltm, window_tokens=2000):
        self.client = client
        self.ltm = ltm
        self.window_tokens = window_tokens
        self.history = []        # 短期：原文
        self.summary = ""        # 短期：压缩后的摘要
        self.user_id = None

    def build_messages(self, system, user_input):
        """组装最终发给模型的 messages"""
        recalled = self.ltm.recall(user_input, self.user_id, k=5)
        memory_block = ""
        if recalled:
            memory_block = "已知的相关信息：\n" + "\n".join(f"- {r}" for r in recalled)
        if self.summary:
            memory_block += f"\n\n此前的对话摘要：\n{self.summary}"

        msgs = [{"role": "system", "content": system}]
        if memory_block:
            msgs.append({"role": "system", "content": memory_block})
        msgs += truncate_by_token(self.history, self.window_tokens)
        msgs.append({"role": "user", "content": user_input})
        return msgs

    def on_turn_end(self, user_input, assistant_reply):
        """一轮结束后：入历史、可能压缩、抽取长期记忆"""
        self.history.append({"role": "user", "content": user_input})
        self.history.append({"role": "assistant", "content": assistant_reply})

        # 超预算就把最早的若干轮压进摘要
        while count_tokens(self.history) > self.window_tokens and len(self.history) > 2:
            to_compress = self.history[:2]
            self.history = self.history[2:]
            self.summary = summarize_history(
                self.client, to_compress, self.summary
            )

        # 异步抽取长期记忆（生产上丢到后台队列，不要阻塞响应）
        items = extract_memories(
            self.client,
            f"用户: {user_input}\n助手: {assistant_reply}",
        )
        self.ltm.add(items, self.user_id)
```

注意 `on_turn_end` 里的抽取是**同步**写的，生产上应该丢消息队列。
记忆写入慢 200ms 用户能感知到，但没人要求它是实时一致的。

## 四、四个真实踩过的坑

### 坑 1：记忆污染

模型把**助手自己的推测**当成事实存了进去。
比如助手说"您可能是后端工程师吧"，用户没否认，
抽取模块就存了 `{"type": "profile", "content": "用户是后端工程师"}`。

**对策**：抽取 prompt 里明确写"只存用户明确表达过的，不存推测"，
并且只从 `user` 角色的消息里抽，不从 `assistant` 抽。

### 坑 2：记忆无限膨胀

什么都存，三个月后库里 5 万条，检索出来的都是噪声。

**对策**：给每条记忆打分，用 `last_accessed` 做遗忘曲线，
长期未被命中的降权甚至归档。也可以设上限，比如每个用户最多 200 条活跃记忆。

### 坑 3：检索回来的记忆互相矛盾

用户去年说"我不吃辣"，今年说"最近爱上川菜"，两条都被召回，
模型不知道该信哪个。

**对策**：记忆带**时间戳**，prompt 里明确"时间更近的优先"；
更彻底的做法是冲突检测——存入新记忆时检索相似的旧记忆，让模型判断是否覆盖。

### 坑 4：把记忆塞在 system 里，结果被 Prompt Cache 吃掉

System prompt 变了会导致缓存失效。如果每轮记忆都变，缓存全 miss，成本飙升。

**对策**：把记忆放在**用户消息之前的独立 user/assistant 消息里**，
保持 system prompt 稳定。这个细节在高频调用时能省一大笔钱。

## 五、小结

- **上下文和记忆是两回事**：上下文全量付费，记忆按需付费
- 短期记忆三层递进：滑动窗口 → token 截断 → **摘要压缩（生产标配）**
- 长期记忆要**分类存**（profile / preference / fact / todo）并**按 user_id 硬过滤**
- 抽取模块的异常必须吞掉，它不能成为主流程的单点故障
- 记忆要能**遗忘**，否则三个月后全是噪声

再强调一遍最容易被忽视的一点：**记忆系统的难点不在存，在于"什么值得存"和"什么时候忘"**。
写入策略决定上限，检索策略只决定下限。

下一篇聊多智能体——单个 Agent 的记忆搞定了，
但当你有五个 Agent 协作时，它们怎么共享记忆、怎么分工，又是一套新问题。
