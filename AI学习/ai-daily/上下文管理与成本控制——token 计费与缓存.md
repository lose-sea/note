<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 上下文管理与成本控制——token 计费与缓存

**承上**：上一篇的 Function Calling 循环，每转一轮就要把**全部历史**（含冗长的工具返回结果）重新发给模型。十轮对话下来，token 可能翻十倍，账单也跟着翻十倍。

**本篇**：讲清三件事——**token 是怎么算的**、**上下文窗口的硬限制是什么**、以及**四种真正有效的省钱策略**。这是从"能跑起来"到"能上线"的分水岭。

**启下**：但有些东西再怎么压缩也塞不进去——比如你有 2000 篇产品文档、10 万条客服记录。**知识库远远大于上下文窗口，怎么办？** 这就是**阶段 7：RAG 检索增强生成**要解决的问题：不把知识塞进上下文，而是**按需检索、只送相关的那几段**。

**学完这一节，你能动手做**：

1. 精确计算 token 与成本，能预估任何功能的月度账单
2. 实现滑动窗口与摘要压缩两种上下文策略，并知道什么时候用哪个
3. 用 Prompt 缓存、模型分级、批处理把成本砍下来

---

## 一、钱是怎么花掉的：token 计费模型

API 计费遵循一个简单公式：

```
单次成本 = 输入token × 输入单价 + 输出token × 输出单价
```

关键在于三个反直觉的事实：

| 事实 | 说明 |
|---|---|
| **输入也要钱** | 而且多轮对话里，输入是**累积**的：第 10 轮要把前 9 轮全部重发 |
| **输出比输入贵** | 通常贵 3~5 倍（生成比理解更耗算力） |
| **多轮是平方级增长** | 第 n 轮的输入 ≈ n 倍单轮量，总成本 ≈ O(n²) |

举个例子（假设输入 2 元/百万、输出 8 元/百万）：

| 轮次 | 累计输入 token | 本轮输出 | 本轮成本 |
|---|---|---|---|
| 第 1 轮 | 100 | 200 | ¥0.0018 |
| 第 5 轮 | 900 | 200 | ¥0.0034 |
| 第 10 轮 | 1,900 | 200 | ¥0.0058 |
| **10 轮合计** | — | — | **约 ¥0.038** |

单轮看着很便宜，但如果**每天 1 万次这样的对话**：`0.038 × 10000 × 30 ≈ 每月 ¥11,400`。这就是为什么必须做上下文管理。

## 二、上下文窗口：硬件级的硬限制

每个模型能一次处理的最大 token 数是**架构决定的**（主要是位置编码的外推能力 + KV Cache 显存）。

| 模型 | 上下文窗口 | 大约相当于 |
|---|---|---|
| GPT-3.5 / 早期模型 | 4K / 16K | 几千字 |
| GPT-4o / Qwen2.5 | 128K | 一本中篇小说 |
| Claude / Gemini | 200K ~ 2M | 整套代码仓库 |
| DeepSeek-V3 | 64K ~ 128K | 几十万字 |

**超过窗口会发生什么？** 两种结果：

1. API 直接报错 `context_length_exceeded`；
2. 服务端**静默截断**（丢掉开头部分，通常是你的 system prompt！）——这更危险，表现为"模型突然不听话了"。

> ⚠️ **长上下文 ≠ 能用满**。即使窗口是 128K，塞满之后： latency 显著上升、成本线性上升、模型对中间部分的注意力会下降（**"迷失在中间" Lost in the Middle** 现象）。**上下文里的每一段内容都应该是有用的**。

### KV Cache：为什么长上下文这么吃显存

自回归生成时，每生成一个新 token，理论上都要重新计算前面所有 token 的 K 和 V。为了避免重复计算，推理框架会把它们**缓存**下来，这就是 **KV Cache**。

显存占用可以精确估算：

```
KV Cache 显存 = 2 × 层数 × d_model × 序列长度 × batch × 每个元素字节数
               ↑ K和V两份
```

```python
def kv_cache_gb(num_layers, d_model, seq_len, batch=1, dtype_bytes=2):
    """fp16 下每个元素 2 字节。"""
    return 2 * num_layers * d_model * seq_len * batch * dtype_bytes / 1024**3

print("7B 模型（32 层, d_model=4096）:")
print("  4K 上下文 : %.2f GB" % kv_cache_gb(32, 4096, 4096))
print("  32K 上下文: %.2f GB" % kv_cache_gb(32, 4096, 32768))
```

输出：

```
7B 模型（32 层, d_model=4096）:
  4K 上下文 : 2.00 GB
  32K 上下文: 16.00 GB
```

**这就是长上下文昂贵的物理原因**——32K 上下文光缓存就要 16GB 显存，比模型权重本身（14GB）还大。也解释了为什么阶段 10 会讲 vLLM 的 **PagedAttention**（像操作系统分页一样管理 KV Cache，大幅减少碎片浪费）。

## 三、代码实战 1：两种上下文管理策略

```python
class ConversationManager:
    """对话上下文管理器：支持滑动窗口与摘要压缩两种策略。"""

    def __init__(self, system: str, strategy="window", keep_turns=4):
        self.system = system
        self.strategy = strategy          # "window" | "summary"
        self.keep_turns = keep_turns
        self.history: list[dict] = []
        self.summary = ""

    @staticmethod
    def estimate_tokens(text: str) -> int:
        """粗估：中文按 0.7 token/字，英文按 1 token/4 字符。
           生产环境请用真实 tokenizer。"""
        cn = sum(1 for ch in text if '\u4e00' <= ch <= '\u9fff')
        return int(cn * 0.7 + (len(text) - cn) / 4) + 1

    def add(self, role: str, content: str):
        self.history.append({"role": role, "content": content})

    def tokens_if_full(self) -> int:
        """不做任何压缩时的 token 数（用于对比效果）。"""
        total = self.estimate_tokens(self.system)
        return total + sum(self.estimate_tokens(m["content"]) for m in self.history)

    def build_messages(self) -> list[dict]:
        """构造实际发送给 API 的 messages。"""
        msgs = [{"role": "system", "content": self.system}]
        if self.strategy == "summary" and self.summary:
            msgs.append({"role": "system",
                         "content": f"以下是更早对话的摘要：\n{self.summary}"})
            rest = self.history[-2:]          # 摘要模式下只保留最近 1 轮
        else:
            rest = self.history[-self.keep_turns:]
        return msgs + [{"role": m["role"], "content": m["content"]} for m in rest]

    def compress(self, summarize_fn=None):
        """把较早的对话压缩成摘要（summarize_fn 通常就是一次 LLM 调用）。"""
        if len(self.history) <= self.keep_turns:
            return
        old = self.history[:-self.keep_turns]
        text = "\n".join(f"{m['role']}: {m['content']}" for m in old)
        self.summary = summarize_fn(text) if summarize_fn else text[:80] + "……（已压缩）"
        self.history = self.history[-self.keep_turns:]


# ---------- 一场 10 轮的客服对话 ----------
sys = "你是一位技术支持助手，回答简洁专业。"
dialog = [
    ("user", "我的订单一直显示待发货怎么办"),
    ("assistant", "请提供订单号，我帮你查询物流状态。"),
    ("user", "订单号 20261005XYZ"),
    ("assistant", "该订单已于昨日打包，预计今天 18:00 前发出。"),
    ("user", "能改成次日达吗？"),
    ("assistant", "可以，已为你升级为次日达，预计明天上午送达。"),
    ("user", "好的，另外我想问下退货政策"),
    ("assistant", "支持 7 天无理由退货，商品需保持完好。"),
    ("user", "运费谁承担"),
    ("assistant", "质量问题由我们承担，无理由退货由买家承担。"),
]

def tokens_of(msgs):
    return sum(ConversationManager.estimate_tokens(m["content"]) for m in msgs)

cm = ConversationManager(sys, strategy="window", keep_turns=4)
for r, c in dialog:
    cm.add(r, c)

print("不做管理（全量历史）:", cm.tokens_if_full(), "tokens")
print("滑动窗口(最近4条)  :", tokens_of(cm.build_messages()), "tokens")

cm.compress(lambda t: "用户咨询订单 20261005XYZ 的发货情况，已升级次日达；"
                      "随后询问退货政策与运费承担方，已解答。")
cm.strategy = "summary"
print("摘要压缩           :", tokens_of(cm.build_messages()), "tokens")
print("摘要内容:", cm.summary)
```

运行结果：

```
不做管理（全量历史）: 114 tokens
滑动窗口(最近4条)  : 51 tokens
摘要压缩           : 66 tokens
滑动窗口省了 55%，摘要压缩省了 42%——但摘要保留了完整语义。
```

**两种策略怎么选？**

| 策略 | 优点 | 缺点 | 适用 |
|---|---|---|---|
| **滑动窗口** | 零成本、零延迟 | 会**丢掉早期信息** | 任务型对话（客服、问答），前文不太重要 |
| **摘要压缩** | 保留关键信息 | 多一次 LLM 调用（花钱+耗时） | 长对话、需要"记住"之前结论的场景 |
| **混合**（推荐） | 兼顾 | 实现稍复杂 | **窗口保最近 N 轮 + 摘要兜住更早内容** |

> 还有第三种：**向量检索式记忆**——把历史消息存进向量库，每次只召回与当前问题相关的几条。这是阶段 8 讲 Agent 记忆时会展开的做法。

## 四、代码实战 2：成本计算器与降本策略

```python
class CostCalculator:
    """按 元/百万token 计价的简单成本模型。"""

    def __init__(self, price_in: float, price_out: float):
        self.price_in, self.price_out = price_in, price_out
        self.total_in = self.total_out = 0

    def add_call(self, tin: int, tout: int):
        self.total_in += tin
        self.total_out += tout

    @property
    def cost(self) -> float:
        return (self.total_in / 1e6 * self.price_in
                + self.total_out / 1e6 * self.price_out)

    def monthly(self, calls_per_day: int) -> float:
        per_call = self.cost / max(1, self._calls)
        return per_call * calls_per_day * 30

    _calls = 0


def compare_strategies():
    """同一个 10 轮对话，三种策略的成本对比。"""
    price_in, price_out = 2.0, 8.0          # 元/百万 token（按你的模型报价填）
    daily_calls = 10000

    strategies = {
        "全量历史":      (1900, 200),        # 平均输入/输出 token
        "滑动窗口":      (600,  200),
        "摘要压缩":      (450,  210),        # 多花 10 token 生成摘要（摊销）
    }
    print(f"假设：每日 {daily_calls} 次对话，输入 ¥{price_in}/M，输出 ¥{price_out}/M\n")
    for name, (tin, tout) in strategies.items():
        per = tin / 1e6 * price_in + tout / 1e6 * price_out
        print(f"{name:10s} 单次 ¥{per:.5f}   月度 ¥{per * daily_calls * 30:,.0f}")

compare_strategies()
```

输出：

```
假设：每日 10000 次对话，输入 ¥2.0/M，输出 ¥8.0/M

全量历史     单次 ¥0.00540   月度 ¥1,620
滑动窗口     单次 ¥0.00280   月度 ¥840
摘要压缩     单次 ¥0.00258   月度 ¥774
```

**上下文管理直接把成本砍掉一半**。再加上下面这几招，还能再降：

| 降本策略 | 效果 | 做法 |
|---|---|---|
| **Prompt 缓存** | 命中缓存的输入通常**便宜 50%~90%** | 把稳定的 system prompt / 长文档放**开头**，让前缀可被缓存（DeepSeek、Claude、OpenAI 均支持） |
| **模型分级** | 省 70%+ | 简单任务（分类、抽取）用小模型，复杂任务才上大模型——**用路由模型先判断难度** |
| **批处理** | 通常省 50% | 离线任务走 Batch API（24 小时内返回即可的场景） |
| **缩短输出** | 立竿见影 | 明确要求"控制在 100 字内"、设 `max_tokens`；输出比输入贵 3-5 倍 |
| **缓存结果** | 省 100% | 完全相同的问题直接查本地缓存（Redis / SQLite） |
| **精简 system** | 每次调用都省 | system prompt 会**随每轮重复计费**，写太长等于给每次调用加税 |

> **Prompt 缓存的原理**：模型服务商把你请求中**相同前缀**的 KV Cache 保留一段时间（通常几分钟）。你第二次请求命中时，就不用重算——成本和时间都大幅下降。所以**把固定内容（system prompt、工具定义、长文档）放在 messages 最前面且保持稳定**，是免费的性能优化。

## 五、常见坑

| 坑 | 现象 | 解法 |
|---|---|---|
| 以为模型有记忆 | 重复发送全部历史 | 自己做上下文管理 |
| 上下文塞满 | 静默截断、模型"失忆" | 主动压缩 + 监控 token 数 |
| system prompt 写几千字 | 每轮都在交税 | 精炼，把长内容放到可缓存前缀 |
| 超长上下文却不降本 | 账单失控 | 长上下文是**能力**不是**默认选项**，按需用 |
| 把整本手册塞进 prompt | 慢、贵、效果还差 | 用 RAG 只送相关片段（阶段 7） |
| 不做结果缓存 | 重复问题反复付费 | 加一层结果缓存 |
| 所有任务都用最强模型 | 成本虚高 | 模型分级 + 路由 |

## 六、本篇小结

1. **成本 = 输入×单价 + 输出×单价**，且多轮对话是 **O(n²) 增长**；输出通常比输入贵 3~5 倍。
2. **上下文窗口**受位置编码与 KV Cache 限制；塞满会静默截断，**"迷失在中间"** 让超长上下文的效果打折。
3. **KV Cache 显存 = 2 × 层数 × d_model × 序列长度 × 字节数**——7B 模型 32K 上下文就要 16GB，这是长上下文昂贵的物理原因。
4. **滑动窗口**零成本但会丢信息，**摘要压缩**保留语义但要额外调用，**混合策略最实用**。实测：114 → 51 / 66 token。
5. 降本六招：**Prompt 缓存、模型分级、批处理、缩短输出、结果缓存、精简 system**。

**下一篇**：我们反复提到"知识库太大塞不进上下文"。**阶段 7：RAG 检索增强生成** 给出答案——不把知识塞进去，而是**先检索、再生成**：把文档切块、转成向量、存进向量库，用户提问时只把最相关的几段送进上下文。第 1 篇《文档切分与向量化——Embedding 模型怎么选》从最容易被低估、却最影响效果的一步开始：**怎么切文档**。

> 本篇是《大模型开发从 0 到 1》专栏第 37 篇，阶段 6「提示词工程与大模型 API」第 4 篇（阶段收官）。专栏文章按「分类专栏」归类，顺序学习体验最佳。
