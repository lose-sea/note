# Agent 记忆的三种类型：情景、语义、程序性该分开设计

大多数 Agent 的记忆实现是一锅粥：把历史对话往一个向量库里一塞，检索时就近取几条。简单任务够用，但稍微复杂就暴露问题——它记不住「我是谁」（语义），也记不住「上次我们干到哪了」（情景），更不会从「我这次这么干对了」里提炼出「下次也这么干」（程序性）。

问题在于：**这三件事在人类认知里就是分开的系统**，混在一个存储里，检索逻辑必然打架。

这篇把三类记忆的边界划清楚，讲它们各自适合什么实现、怎么协同，以及最容易踩的坑。

---

## 一、为什么必须分开

### 1.1 一锅粥记忆的症状

典型实现：所有对话历史 → embedding → 存向量库 → 按 query 相似度取 top_k。

出问题的三个场景：

**场景一：用户偏好被具体事件淹没。**
用户两周前说过「我在腾讯做后端」，之后又聊了三十轮别的。现在问「帮我写个监控告警」，检索 top_k 里全是这三十轮的具体技术讨论——因为它们在语义上离当前问题更近。「用户是做后端的」这条被挤到后面。

**场景二：过程信息干扰结论。**
记忆里存着「上次我们讨论自建 PG 因为成本太高放弃了」——这是个**过程事实**（结论是：不自建）。用户现在问「我们 PG 要不要自建」，模型检索到这句话，可能理解成「上次讨论了自建」，而不是「自建被否决了」。

**场景三：成功的做法没被沉淀。**
上周让 Agent 做数据清洗，它试了三次才找到正确流程。这个流程很有价值，但它只是躺在某次对话的过程记录里。下次做类似清洗，它重新试错——**能力没有积累。**

### 1.2 分开的本质原因

| | 情景记忆 | 语义记忆 | 程序性记忆 |
|---|---------|---------|-----------|
| **内容** | 发生了什么（事件序列） | 是什么（事实、概念、属性） | 怎么做（流程、技能） |
| **时间性** | 强（带时间戳） | 弱（可长期不变） | 弱（可迭代优化） |
| **粒度** | 单次事件、单次交互 | 单条事实 | 一组有序步骤 |
| **更新方式** | 追加 | 覆盖/合并/失效 | 修订 |
| **检索依据** | 时间范围、参与者、主题 | 语义相似 | 任务类型匹配 |

**它们的更新策略是冲突的**：情景记忆只追加不修改（历史就是历史），语义记忆要合并去重（同一事实的多个表述要归一），程序性记忆要版本化（v1 流程被 v2 替代）。用一个库实现，只能选一种策略，另两类必然受损。

---

## 二、情景记忆（Episodic Memory）

### 2.1 它记什么

> 「什么时候，谁，做了什么，结果如何」

```python
@dataclass
class Episode:
    ts: datetime          # 什么时候
    user_id: str          # 谁
    task_summary: str     # 做了什么
    outcome: str          # 结果（成功/失败/部分）
    detail: str           # 过程摘要
    artifacts: list[str]  # 关联产出（文件路径等）
```

### 2.2 实现要点

**追加式存储，不要合并去重。** 这是情景记忆和其它两类最大的区别。

```python
def log_episode(ep: Episode):
    episodes.append(ep)     # 只追加
    # 不做去重、不做合并、不做覆盖
```

**检索方式是按元数据过滤 + 语义排序**：

```python
def recall_episodes(user_id: str, topic: str, days: int = 30) -> list[Episode]:
    since = now() - timedelta(days=days)
    # 先按用户和时间过滤，再按主题语义排序
    return [e for e in episodes
            if e.user_id == user_id and e.ts >= since
            and semantic_match(e.task_summary, topic) > 0.7][:5]
```

**注意检索顺序：先元数据、后语义。** 反过来会让「时间近、语义近但属于别的用户」的混进来。

### 2.3 它解决什么问题

- **连续性**：「上周我们处理的那个 PG 延迟问题，后来怎么样了」
- **责任追溯**：「上次是谁改的这个配置」——审计必需
- **避免重复**：「这个问题上周已经排查过了，根因是 X，不要再从头查」

第三点是工程上最有价值的。**把历史失败的原因存成情景记忆，能直接避免同一类问题反复消耗成本。**

---

## 三、语义记忆（Semantic Memory）

### 3.1 它记什么

> 「关于这个用户/这个领域，稳定成立的事实」

```python
@dataclass
class Fact:
    id: str
    text: str                    # 一句独立、无指代的事实
    category: str                # user / env / domain / constraint
    confidence: float            # 置信度
    source_episodes: list[str]   # 从哪些事件提炼的（可溯源）
    valid_from: datetime
    valid_until: datetime | None # 失效时间，None = 长期有效
```

### 3.2 核心是「去情境化」和「合并」

情景记忆里的原始表述往往不能直接当事实用。比如用户说「我们那个 PG 啊，跑得慢死了」——这句话里「慢死了」不是事实，要提炼成：

```
Fact(text="用户的 PostgreSQL 存在查询性能问题", category="env", confidence=0.8)
```

**提炼过程由 LLM 做，但规则要写死**：

```python
EXTRACT_PROMPT = """从对话里提取「长期成立的事实」，而非一次性信息。

只提取以下类别：
- user: 用户身份、角色、技术栈偏好
- env: 用户的环境（数据库版本、部署方式、网络限制）
- domain: 业务领域的专有名词和规则
- constraint: 硬约束（合规、预算、禁用技术）

不提取：具体一次任务的内容、临时参数、情绪表达、闲聊。

每条事实必须：
1. 一句完整、无指代（不出现"它""那个""上次"）
2. 独立成立，不依赖对话上下文
3. 带 certainty: 0.5(推测)/0.8(用户明说)/1.0(用户强调)
"""
```

### 3.3 合并与失效（语义记忆的生命线）

```python
def reconcile(new_fact: Fact, store):
    similar = store.search(new_fact.text, top_k=3)
    for old in similar:
        decision = llm.invoke(RECONCILE_PROMPT.format(old=old.text, new=new_fact.text))
        # decision ∈ {SKIP, UPDATE, CONFLICT, MERGE}
        if decision == "SKIP":
            return
        if decision == "UPDATE":
            old.valid_until = now()          # 旧事实失效
            store.save(new_fact)
            return
        if decision == "MERGE":
            store.replace(old.id, merge(old, new_fact))
            return
    store.save(new_fact)
```

**没有这一步，语义记忆库会迅速劣化。** 用户会改口（「其实我们用 PG 14，不是 13」）、表述会重复（同一个事实说了五遍）、信息会更新（跳槽、换代）。

一个必须做的兜底：**检索时过期的自动忽略**。

```python
def recall_facts(query: str):
    hits = store.search(query, top_k=5)
    return [f for f in hits if f.valid_until is None or f.valid_until > now()]
```

---

## 四、程序性记忆（Procedural Memory）

### 4.1 它记什么

> 「这类任务，正确的做法是什么」

```python
@dataclass
class Procedure:
    id: str
    task_type: str         # 触发条件：什么类型的任务
    steps: list[str]       # 有序步骤
    tips: list[str]        # 注意事项、易错点
    success_rate: float    # 用这个流程做同类任务的成功率
    usage_count: int
    version: int
    deprecated: bool = False
```

### 4.2 来源：从成功轨迹里提炼

程序性记忆不是凭空写的，是从**成功完成的任务轨迹**里反向提炼的：

```python
def distill_procedure(episode: Episode, trajectory: list):
    if episode.outcome != "success":
        return None
    return llm.invoke(DISTILL_PROMPT.format(
        task=episode.task_summary,
        steps=[t.action for t in trajectory],
    ))
# 产出：
# task_type: "数据清洗任务"
# steps: ["1. 先取样本确认字段类型", "2. 检查空值比例", "3. 按类型分派清洗策略"]
# tips: ["不要假设时间字段是 ISO 格式，先取样看", "空值超过 30% 要先和用户确认"]
```

**注意「只从成功轨迹提炼」**。失败轨迹提炼出来的是错误做法。而且要带 `success_rate` 统计——用了几次、成功几次，用来判断这个流程靠不靠谱。

### 4.3 执行：先查流程，再做事

```python
def run_task(task_type: str, user_input: str):
    proc = recall_procedure(task_type)      # 按任务类型检索
    if proc and proc.success_rate > 0.6:
        system = f"""参考已验证的标准流程完成任务：

【标准流程】{proc.steps}
【注意事项】{proc.tips}

如果当前任务与流程不完全匹配，可以适当调整，但偏离要说明理由。"""
    else:
        system = DEFAULT_SYSTEM
    return agent.invoke({"messages": [...], "system": system})
```

**关键在「按任务类型检索」而不是「按用户 query 语义检索」**。流程的匹配键是任务类型，不是具体措辞。写「怎么清洗数据」和「这个 CSV 字段乱了怎么弄」应该命中同一条流程。

### 4.4 程序性记忆的价值

三类记忆里，**程序性记忆对「任务完成率」的提升最直接，也最容易被忽略。**

- 语义记忆让 Agent「更懂你」（个性化）
- 情景记忆让 Agent「记得你们干过什么」（连续性）
- 程序性记忆让 Agent「同类任务越做越好」（能力积累）

前两者改善体验，第三者改善效率。一个只用语义记忆的 Agent，三个月后还是同一水平；攒了程序性记忆的，同类任务会明显变快变稳。

---

## 五、三类怎么协同

一个完整的记忆系统，三类各司其职：

```
用户请求
   │
   ├─► 语义记忆检索   → 注入「用户是谁、环境如何」（个性化上下文）
   │
   ├─► 情景记忆检索   → 注入「上次相关的事是什么」（连续性）
   │
   ├─► 程序性记忆检索 → 注入「这类任务的标准做法」（能力）
   │
   ▼
执行任务
   │
   ▼
会话结束
   ├─► 写情景记忆（追加一条事件）
   ├─► 提炼语义记忆（去情境化的事实）
   └─► 若成功，提炼程序性记忆（流程 + tips）
```

### 5.1 各自独立的存储

```python
class MemorySystem:
    def __init__(self):
        self.episodes = EpisodeStore()          # 时序数据库 / 追加日志
        self.facts = FactStore()                # 向量库 + 版本字段
        self.procedures = ProcedureStore()      # 结构化，按 task_type 索引
```

**不要用一个库存三类。** 至少不要用同一套更新策略。追加式、合并式、版本化是三种冲突的生命周期。

### 5.2 注入口径

```python
def build_system_prompt(user_id: str, task: str) -> str:
    parts = ["你是一个智能助手。"]
    if facts := self.facts.recall(task, user_id=user_id):
        parts.append("【已知的用户信息】\n" + "\n".join(f"- {f.text}" for f in facts))
    if eps := self.episodes.recall(user_id=user_id, topic=task, days=30):
        parts.append("【相关的历史事项】\n" + "\n".join(f"- {e.ts:%m-%d} {e.task_summary}（{e.outcome}）" for e in eps))
    if proc := self.procedures.recall(task_type_of(task)):
        parts.append("【已验证的标准流程】\n" + "\n".join(f"{i+1}. {s}" for i, s in enumerate(proc.steps)))
    return "\n\n".join(parts)
```

三段各自独立注入，谁没有就不加。**不要为了让 prompt 看起来丰满而硬凑**——没有相关记忆就空着，塞无关内容只会干扰。

---

## 六、常见误区

**误区一：只做语义记忆。** 大部分团队的记忆就是「存用户事实向量库」。缺了情景记忆，Agent 没有连续性；缺了程序性记忆，能力不积累。

**误区二：把情景记忆当语义记忆用。** 直接对历史对话做相似度检索，返回的是「某次讨论的具体内容」，不是「用户的稳定偏好」。前者带一堆过程噪声。

**误区三：语义记忆不做失效处理。** 事实会变，库只增不减，半年后 Agent 拿着一堆过期信息自信回答。

**误区四：程序性记忆按语义检索匹配。** 应该按 task_type 匹配。按语义会把「清洗数据」和「分析数据」的流程混在一起。

**误区五：从失败轨迹提炼流程。** 失败对应的是错误做法，或者只是任务本身无解。只从成功轨迹蒸馏。

**误区六：三类记忆用同一个向量库、同一套去重逻辑。** 追加、合并、版本化三种策略混用，互相破坏。

**误区七：记忆不按 user_id 隔离。** 这是最严重也最常见的 bug，等于把不同用户的记忆混一锅。

---

## 小结

- 三类记忆是**三套不同的系统**，内容、时间性、更新策略、检索依据全不一样：
  - **情景记忆**发生了什么（追加式、时序、按元数据过滤）
  - **语义记忆**是什么（合并去重、按语义相似）
  - **程序性记忆**怎么做（版本化、按任务类型匹配）
- 分开的根本原因是**更新策略冲突**：只追加 / 要合并 / 要版本化，用一个库只能满足一类。
- 情景记忆最直接的工程价值是**避免重复失败**；程序性记忆对**任务完成率**提升最大，且最容易被忽略。
- 语义记忆必须有**失效与合并机制**，否则库会劣化成过期事实垃圾场。
- 协同方式：**用户请求时三段独立检索注入，会话结束后三段独立写入**（追加事件 / 提炼事实 / 蒸馏流程）。
- 落地底线：user_id 隔离、三类不同存储、程序性记忆只从成功轨迹蒸馏、检索顺序先元数据后语义。

记忆不是一个功能，是一组功能。把它们分开设计，Agent 才既能「记得你」，又能「越干越好」。
