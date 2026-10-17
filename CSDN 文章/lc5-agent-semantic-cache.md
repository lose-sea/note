# 语义缓存：相似问题别反复花钱，但别命中错的东西

客服机器人被问了 200 遍「怎么退款」，每次都老老实实走一遍完整流程：理解意图 → 检索知识库 → 组织答案。**200 次几乎相同的计算，200 次几乎相同的答案。**

精确缓存解决不了这个问题——用户不会一字不差地问第二遍。「怎么退款」「如何申请退款」「我想把钱要回来」是三个不同的字符串。

语义缓存（Semantic Cache）就是为这个场景设计的：**用向量相似度判断「这个问题和之前某个问题是不是一回事」，是就复用旧答案。** 但它有个危险的另一面——命中错了，用户拿到不相关的答案，比多花钱更糟。

这篇讲清楚语义缓存的实现、阈值怎么定、以及误命中的防范。

---

## 一、精确缓存为什么不够

### 1.1 用户的问法天然多样

同一个意图的真实问法：

```
"怎么退款？"
"如何申请退款"
"我想退掉这个订单，钱什么时候到账？"
"东西不想要了，能退吗？"
"退货流程是什么？"
```

精确缓存只能命中完全相同的字符串。**这五种问法里，后四种全是 miss。**

### 1.2 而且很多场景不能预生成

有些答案依赖实时数据（订单状态、库存），预生成不了。但「流程类」「规则类」的知识（怎么退款、年假几天、怎么请假）是稳定的——**这类占了客服问题的很大比例，语义缓存的收益主要来自这里。**

---

## 二、语义缓存的实现

### 2.1 核心三步

```python
import numpy as np
from dataclasses import dataclass

@dataclass
class CacheEntry:
    embedding: np.ndarray
    question: str
    answer: str
    context: str | None        # 答案依赖的上下文（如用户ID），用于防误命中
    created_at: float
    hit_count: int = 0

class SemanticCache:
    def __init__(self, embed_fn, similarity_threshold: float = 0.92,
                 max_entries: int = 5000, ttl: int = 86400):
        self.embed = embed_fn
        self.threshold = similarity_threshold
        self.entries: list[CacheEntry] = []
        self.max_entries = max_entries
        self.ttl = ttl

    def get(self, question: str, context_key: str | None = None):
        q_emb = self.embed(question)
        best, best_score = None, -1.0
        for e in self.entries:
            # 上下文不同的，直接跳过（防 A 用户命中 B 用户的答案）
            if context_key is not None and e.context != context_key:
                continue
            score = float(np.dot(q_emb, e.embedding))
            if score > best_score:
                best, best_score = e, score
        if best is not None and best_score >= self.threshold:
            best.hit_count += 1
            return best, best_score
        return None, best_score

    def put(self, question: str, answer: str, context_key: str | None = None):
        self.entries.append(CacheEntry(
            embedding=self.embed(question),
            question=question, answer=answer, context=context_key,
            created_at=time.time(),
        ))
        # 超出容量，淘汰最久未命中 + 最早的
        if len(self.entries) > self.max_entries:
            self.entries.sort(key=lambda e: (e.hit_count, e.created_at))
            self.entries = self.entries[len(self.entries) - self.max_entries:]
```

**`context_key` 是防误命中的关键设计**（2.3 细说）。

### 2.2 用向量库而不是线性扫描

条目上千之后，`for` 循环遍历太慢。生产上把 embedding 存进向量库：

```python
# Redis / Qdrant / pgvector 都可以
def get(self, question: str, context_key: str):
    q_emb = self.embed(question)
    results = vector_store.search(
        vector=q_emb,
        top_k=1,
        filter={"context_key": context_key, "valid": True},   # 过滤在检索层做
    )
    hit = results[0]
    if hit.score >= self.threshold:
        return hit
    return None
```

**`filter` 要在检索层做**，不能先取回再过滤——后者既慢又可能在过滤后无候选。

### 2.3 context_key：防误命中的第一道防线

**没有 context_key 的语义缓存，在多用户场景下是事故源。**

```python
# ❌ 危险：A 用户问了「我的订单到哪了」，B 用户问同样的话，命中 A 的答案
cache.get("我的订单到哪了")

# ✅ 带上用户上下文
cache.get("我的订单到哪了", context_key=f"user:{user_id}")
```

**判据：答案依赖的信息带了用户属性，就必须有 context_key。** 知识库通用问答可以不带（大家答案一样），带用户数据的必须带。

---

## 三、阈值怎么定

这是语义缓存最关键的参数，也是最容易拍脑袋的地方。

### 3.1 阈值就是「宁可放过，不可错杀」

```python
# 阈值太低（0.85）→ 大量误命中，用户拿到不相关答案
# 阈值太高（0.98）→ 几乎不命中，缓存形同虚设
```

**我的默认起点：0.92。** 然后按下面的方法标定。

### 3.2 标定方法

准备两组问题：一组「应该命中」（同义不同说法），一组「不该命中」（意图相近但答案不同）。

```python
should_hit = [
    ("怎么退款？", "如何申请退款？"),
    ("年假有几天？", "入职一年有多少年假？"),
]
should_miss = [
    ("怎么退款？", "怎么开发票？"),              # 都是售后，但答案不同
    ("年假有几天？", "年假能攒到明年吗？"),      # 相关但答案不同
]

# 跑 embedding，看相似度分布
for a, b in should_hit:
    print(f"HIT   {sim(a,b):.3f}  {a} / {b}")
for a, b in should_miss:
    print(f"MISS  {sim(a,b):.3f}  {a} / {b}")
```

典型输出：

```
HIT   0.947  怎么退款？ / 如何申请退款？
HIT   0.931  年假有几天？ / 入职一年有多少年假？
MISS  0.881  怎么退款？ / 怎么开发票？
MISS  0.898  年假有几天？ / 年假能攒到明年吗？
```

阈值取 **should_hit 的最小值和 should_miss 的最大值之间**：这个例子是 0.898 < threshold < 0.931，取 0.92。

### 3.3 不同场景该用不同阈值

| 场景 | 阈值 | 理由 |
|------|------|------|
| 通用 FAQ / 规则问答 | 0.90~0.93 | 答案稳定，误中代价低 |
| 涉及用户数据（订单、账户） | 0.95+ | 必须带 context_key，且阈值要保守 |
| 医疗 / 法律 / 金融 | 0.96+ | 答案错误代价极高，能不缓存就不缓存 |
| 创意生成（文案、代码） | 不缓存 | 每次应该不一样 |

**最后一类根本不该用语义缓存**——用户要的是多样性，不是复用。

---

## 四、误命中：最危险的情况

### 4.1 三个典型误命中案例

**案例一：否定与肯定的语义接近**

```
缓存里: "支持微信支付吗？" → "支持，可以在结算页选择微信支付"
用户问: "不支持微信支付吗？" → 相似度 0.94，命中了"支持"
```

**案例二：数字不同，语义极近**

```
缓存里: "满 100 减 20 吗？" → "满 100 减 20"
用户问: "满 200 减 40 吗？" → 相似度 0.93，命中了错误答案
```

**案例三：主体变了**

```
缓存里: "iPhone 15 多少钱？" → "5999 起"
用户问: "iPhone 16 多少钱？" → 相似度 0.95，返回了 15 的价格
```

**这一类是最阴险的——用户以为拿到了答案，实际是错的。**

### 4.2 防误命中的四道关卡

**关卡一：相似度阈值**（前面讲的，保守取值）

**关卡二：数字/实体一致性校验**

```python
NUM_RE = re.compile(r"\d+")

def numbers_match(a: str, b: str) -> bool:
    return set(NUM_RE.findall(a)) == set(NUM_RE.findall(b))

# 数字集合不同，拒绝命中
if not numbers_match(cached_question, new_question):
    return None
```

这一条极便宜，且能干掉案例二/三的大部分情况。**强烈建议默认开启。**

**关卡三：否定词与语义方向校验**

```python
NEGATIVE_WORDS = ["不", "没", "无", "别", "非", "未"]

def sentiment_match(a: str, b: str) -> bool:
    a_neg = any(w in a for w in NEGATIVE_WORDS)
    b_neg = any(w in b for w in NEGATIVE_WORDS)
    return a_neg == b_neg        # 一个有否定一个没有 → 不命中
```

**关卡四：人工抽检 + badcase 回流**

```python
# 记录每次命中，允许用户/运营标记「这个缓存错了」
def mark_bad_hit(question: str):
    entry = find_entry(question)
    if entry:
        entry.valid = False                    # 立刻作废
        badcases.append({"cached_q": entry.question,
                         "asked_q": question,
                         "wrong_answer": entry.answer})
```

**用户点和运营反馈是最可靠的信号。** 命中错了要**立刻作废该条目**并记录，积累 badcase 反哺阈值。

### 4.3 一条务实的兜底

在答案上标注来源，让用户能察觉异常：

```
【缓存答案】退款会在 1-3 个工作日原路返回。
（此回答来自相似问题「如何申请退款」，如与你的情况不符请重新描述问题）
```

**给用户一个「发现错了能反馈」的入口**，比追求零误命中更现实。

---

## 五、缓存的失效管理

### 5.1 TTL

```python
# 按内容类型设
TTL = {
    "客服流程":     7 * 86400,      # 规则稳定，一周
    "价格/库存":    300,            # 5 分钟，变动快
    "政策法规":     30 * 86400,     # 一月
    "内部工具帮助":  1 * 86400,      # 一天
}
```

**答案依赖实时数据的，TTL 要短。** 「订单到哪了」缓存一周是灾难。

### 5.2 主动失效

答案依赖的数据变了（知识库更新、规则改了），要作废相关缓存：

```python
def invalidate_by_topic(topic: str):
    """知识库某主题更新后，作废相关缓存。"""
    for e in self.entries:
        if topic in e.question or topic in e.answer:
            e.valid = False
```

**知识库更新和缓存失效必须联动**，否则用户会持续拿到旧答案。

### 5.3 监控指标

```python
metrics = {
    "hit_rate": hits / (hits + misses),
    "avg_confidence": mean(scores of hits),
    "bad_hit_rate": bad_hits / hits,      # 人工标记的误命中占比
    "cost_saved": sum(skipped_costs),
}
```

**`bad_hit_rate` 是最重要的**——它超过 2% 就该调阈值或者关掉缓存。

---

## 六、什么时候别用

- **答案依赖实时数据且用户可区分**：订单状态、余额、库存——这类带 context_key 缓存价值也低（每个用户的查询都不同）
- **错误代价高的场景**：医疗、法律、金融建议。命错一次的代价远超省下的钱
- **需要多样性的任务**：创意生成、代码生成
- **问法高度一致的场景**：那精确缓存就够，语义缓存反而增加复杂度

**判断法**：如果「拿到一个相似但不完全对」的答案，用户会生气 → 别用，或者阈值拉到 0.97+。

---

## 七、常见误区

**误区一：阈值拍太低。** 0.85 的阈值看着命中率很高，实际一半是错答案。**保守取值，宁可少命中。**

**误区二：不带 context_key。** 多用户场景下这是数据泄露级别的 bug。

**误区三：不校验数字和否定词。** 这两类校验极便宜，能拦掉大部分危险误命中。

**误区四：知识库更新了缓存不失效。** 用户持续拿旧答案，而且你从缓存里查不出来。

**误区五：只看命中率，不看误命中率。** 命中率 80% + 误命中率 15% = 灾难。**两个必须一起看。**

**误区六：创意类任务也用语义缓存。** 用户要的是每次不一样。

**误区七：答案里不给来源提示。** 用户不知道这是缓存答案，错了也没法反馈，badcase 收不上来。

---

## 小结

- 语义缓存解决**问法多样**导致的重复计算，核心是「embedding 相似度 ≥ 阈值则复用答案」。精确缓存只能命中一模一样的字符串。
- **阈值默认 0.92，必须自己标定**：取「该命中的最低分」和「不该命中的最高分」之间。
- **`context_key` 是必须的**：答案依赖用户数据时，不带 context_key 就是 A 用户命中 B 用户的答案。
- 防误命中四道关卡：**保守阈值、数字集合校验、否定词校验、badcase 反馈回流**。数字和否定词校验几乎零成本，强烈建议默认开。
- 最危险的误命中是「主体/数字变了，语义极近」（iPhone 15 vs 16、满 100 vs 满 200）——这类靠语境校验拦。
- 失效管理：按内容设 TTL、**知识库更新必须联动作废缓存**、监控 `bad_hit_rate`（超过 2% 就该调阈值）。
- 别用的场景：实时数据可区分、错误代价高（医疗金融）、需要多样性。

语义缓存是少见的「省钱立竿见影」优化，但它换取的成本是**答案可能不是针对你这个问题定制的**。所以先问：你的场景能容忍这个不确定性吗？能，再上。
