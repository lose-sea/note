# Token 预算怎么分配：把上下文当成稀缺资源来规划

> 上下文窗口从 4K 到 128K，再到 1M。
> 但**能塞多少，和该塞多少，是两回事**。
>
> 这篇讲怎么给一次调用做预算。

## 一、先算一笔账

假设你在做一个文档问答 Agent，一次请求的上下文构成：

| 部分 | token | 占比 |
|---|---|---|
| 系统提示词 | 800 | 8% |
| 工具定义（8 个） | 1200 | 12% |
| 对话历史（10 轮） | 3000 | 30% |
| 检索到的文档（5 篇） | 4000 | 40% |
| 用户当前问题 | 100 | 1% |
| **留给输出的余量** | 900 | 9% |
| **合计** | **10000** | 100% |

问题很明显：**检索占了 40%**，但里面真正被用到的可能只有 1~2 篇。

## 二、预算是"分蛋糕"

给一个固定预算，按优先级分配：

```python
from dataclasses import dataclass

@dataclass
class Budget:
    total: int = 16000

    # 固定支出
    system_prompt: int = 1500
    tools: int = 2000
    output_reserve: int = 2000        # 必须给输出留

    # 可变部分（剩下的按比例分）
    @property
    def variable(self) -> int:
        return self.total - self.system_prompt - self.tools - self.output_reserve

    def allocate(self, weights: dict[str, float]) -> dict[str, int]:
        """把可变预算按权重分配"""
        total_w = sum(weights.values())
        return {k: int(self.variable * v / total_w) for k, v in weights.items()}

budget = Budget()
allocation = budget.allocate({"history": 0.4, "retrieval": 0.6})
print(allocation)
# {'history': 4200, 'retrieval': 6300}
```

**关键原则：输出余量必须预留。** 用满输入，输出会被截断（`finish_reason == "length"`），钱花了但结果不可用。

## 三、动态分配：按内容质量分

固定比例不够聪明——**有的问题需要更多历史，有的需要更多检索**。

```python
def dynamic_allocate(question: str, budget: Budget) -> dict[str, int]:
    # 判断问题类型
    needs_history = bool(re.search(r"(刚才|之前|上面|那个|继续)", question))
    needs_context = bool(re.search(r"(是什么|为什么|怎么|介绍|详细)", question))

    if needs_history and not needs_context:
        weights = {"history": 0.7, "retrieval": 0.3}
    elif needs_context and not needs_history:
        weights = {"history": 0.25, "retrieval": 0.75}
    else:
        weights = {"history": 0.4, "retrieval": 0.6}

    return budget.allocate(weights)
```

**更细的做法**：按检索质量动态调整。

```python
def allocate_by_quality(docs: list[Document], budget: Budget):
    """召回质量高就多给上下文，质量低就少给（免得塞垃圾）"""
    if not docs:
        return {"history": 0.8, "retrieval": 0.2}

    avg_score = sum(d.metadata.get("score", 0) for d in docs) / len(docs)
    if avg_score > 0.8:
        weights = {"history": 0.3, "retrieval": 0.7}      # 高质量，多用
    elif avg_score > 0.5:
        weights = {"history": 0.5, "retrieval": 0.5}
    else:
        weights = {"history": 0.7, "retrieval": 0.3}      # 低质量，少用
    return budget.allocate(weights)
```

## 四、压缩的四个层次

预算不够时，按"损失从小到大"的顺序压缩：

```
① 去掉冗余       → 无损
② 摘要压缩       → 有损但保留信息
③ 截断           → 有损，可能丢关键信息
④ 丢弃           → 最粗暴
```

**① 无损：去空白、去注释、去重复**

```python
def dedupe_docs(docs: list[Document]) -> list[Document]:
    seen = set()
    out = []
    for d in docs:
        key = hash(d.page_content[:200])        # 用前缀做去重键
        if key not in seen:
            seen.add(key)
            out.append(d)
    return out

def squeeze_whitespace(text: str) -> str:
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text.strip()
```

**② 有损：摘要**

```python
def summarize_history(messages: list[BaseMessage], target_tokens: int) -> str:
    text = "\n".join(f"{m.type}: {m.content}" for m in messages)
    summary = (summary_prompt | cheap_llm | StrOutputParser()).invoke({"text": text})
    # 保证不超过目标长度
    while count_tokens(summary) > target_tokens:
        summary = summary[: int(len(summary) * 0.8)]
    return summary
```

**摘要要用便宜模型**——这一步不需要推理能力，用最便宜的模型就行。

**③ 截断：按段落而非字符**

```python
def truncate_by_paragraph(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    paras = text.split("\n\n")
    out, total = [], 0
    for p in paras:
        if total + len(p) > max_chars:
            break
        out.append(p)
        total += len(p)
    return "\n\n".join(out)
```

**按段落截断比按字符截断好**——不会出现半句话。

**④ 丢弃：按优先级**

```python
def drop_lowest_priority(docs: list[Document], keep: int) -> list[Document]:
    # 按 score 排序，保留前 keep 个
    return sorted(docs, key=lambda d: -d.metadata.get("score", 0))[:keep]
```

## 五、历史压缩：最值得优化的地方

对话历史往往占比 30%+，而且**信息密度低**——很多"好的""明白了""那再问一个"。

**分级保存**：

```python
@dataclass
class HistoryTier:
    recent: list[BaseMessage]        # 最近 3 轮，原文
    summarized: str                  # 更早的，摘要成一段
    pinned: list[str]                # 关键信息，永不丢

def build_history(history: list[BaseMessage], budget_tokens: int) -> list[BaseMessage]:
    # 1. 最近 N 轮原文（保真）
    recent = history[-6:]
    recent_tokens = count_tokens(recent)

    # 2. 更早的压缩成摘要
    older = history[:-6]
    summary_tokens = budget_tokens - recent_tokens - 200
    summary = summarize_history(older, summary_tokens) if older else ""

    out = []
    if summary:
        out.append(SystemMessage(f"【之前的对话摘要】\n{summary}"))
    out.extend(recent)
    return out
```

**"关键信息"应该单独抽取并存成结构化字段**，不要指望摘要能无损保留：

```python
def extract_facts(messages: list[BaseMessage]) -> list[str]:
    """抽取必须记住的硬事实"""
    result = fact_extractor.invoke(f"从下面对话里提取必须记住的事实（数字、名称、约定）：\n{to_text(messages)}")
    return result.facts
```

然后作为 `SystemMessage` 固定注入——**这些内容永远不会被压缩掉**。

## 六、工具定义也要算预算

8 个工具的 schema 可能有 1200 token，**每次调用都要带上**。

**优化手段**：

**① 精简描述**

```python
# ❌ 冗长
@tool
def query_order(order_id: str) -> str:
    """这个工具用于查询订单详情。你可以在需要了解订单状态、
    订单金额、下单时间、收货地址等信息时调用它。
    输入应该是一个订单号，格式为 SO 开头加 10 位数字。
    返回一个包含订单所有字段的 JSON 字符串。"""

# ✅ 精简
@tool
def query_order(order_id: str) -> str:
    """查询订单详情。order_id 格式：SO+10位数字。"""
```

**description 写清"什么时候用"，不需要写"返回什么格式"**——格式模型能从返回值看出来。

**② 按需加载工具**

```python
def get_tools(intent: str) -> list:
    TOOL_GROUPS = {
        "order": [query_order, list_orders, modify_address],
        "refund": [check_eligibility, create_refund],
        "logistics": [track_package],
        "general": [lookup_faq],
    }
    return TOOL_GROUPS.get(intent, all_tools)
```

先用一次便宜的分类调用确定意图，再只加载该组的工具——**省下的 token 远大于分类调用的成本**。

**③ 拆分 Agent**

工具超过 10 个时，拆成多个专职 Agent（参考 Supervisor 那篇）。

## 七、给预算加"实时监控"

预算不能只在设计时算，**运行时要盯着**：

```python
class BudgetGuard:
    def __init__(self, total: int, output_reserve: int = 2000):
        self.total = total
        self.output_reserve = output_reserve

    def check(self, messages: list[BaseMessage]) -> None:
        used = count_tokens(messages)
        available = self.total - used

        if available < self.output_reserve:
            raise BudgetExceeded(
                f"输入已用 {used} token，仅剩 {available} 给输出，"
                f"低于保留值 {self.output_reserve}"
            )

    def fit(self, messages: list[BaseMessage]) -> list[BaseMessage]:
        """自动裁剪到预算内"""
        while count_tokens(messages) > self.total - self.output_reserve:
            # 从最老的非系统消息开始删
            for i, m in enumerate(messages):
                if not isinstance(m, SystemMessage):
                    messages.pop(i)
                    break
            else:
                break
        return messages
```

**用精确的 token 计数**，不要用 `len(text) / 4` 估算——中文场景误差能到 100%：

```python
import tiktoken

def count_tokens(text_or_msgs) -> int:
    enc = tiktoken.encoding_for_model("gpt-4o")
    if isinstance(text_or_msgs, str):
        return len(enc.encode(text_or_msgs))
    total = 0
    for m in text_or_msgs:
        total += len(enc.encode(m.content)) + 4      # 消息开销
    return total
```

## 八、成本优化的优先级

按"投入产出比"排序：

| 手段 | 省多少 | 改动量 |
|---|---|---|
| **缓存**（相同请求） | 30~60% | 小 ⭐ |
| **按需加载工具** | 5~15% | 小 ⭐ |
| **历史摘要** | 10~25% | 中 |
| **检索去重** | 5~15% | 小 |
| **换便宜模型**（简单任务） | 50~90% | 中 |
| **减少重试** | 5~20% | 中 |
| 压缩提示词 | 2~5% | 大 |

**最有效的两件事：缓存和分级用模型。**

```python
# 按难度路由
def route_model(question: str, history: list) -> str:
    if len(question) < 20 and not history:
        return "gpt-4o-mini"          # 简单问题，便宜模型
    if is_complex(question):
        return "gpt-4o"               # 复杂问题，强模型
    return "gpt-4o-mini"
```

**80% 的请求是简单请求**，用便宜模型处理，成本能降一个数量级。

## 九、小结

```python
@dataclass
class Budget:
    total: int = 16000
    system_prompt: int = 1500
    tools: int = 2000
    output_reserve: int = 2000       # 必须留
    # 剩下的按权重分给 history / retrieval
```

五条原则：

```
1. 输出余量必须预留（否则被截断）
2. 固定支出（系统提示 + 工具）先扣掉
3. 可变部分按内容质量动态分配
4. 压缩按"无损 → 摘要 → 截断 → 丢弃"的顺序
5. 历史摘要 + 关键事实固定注入
```

**核心认知：上下文不是"能塞多少塞多少"，而是"该塞多少塞多少"。** 塞得越多，模型越容易迷失在中间（Lost in the Middle），而且成本线性上升。
