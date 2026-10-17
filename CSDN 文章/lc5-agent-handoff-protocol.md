# 智能体交接协议：上下文到底怎么传给下一个 Agent

「交接」这件事听起来就是「把话头交给下一个人」，但在 Agent 系统里，它是出错率最高的环节之一。

症状都很典型：子 Agent 一脸茫然地问「用户说的是哪个订单」；或者它拿着一堆无关的历史，慢且贵；再或者它拿到了不该看的上下文，把别的客户信息带进了回答。

**根本原因是：交接协议没有设计。** 大家默认「把对话历史传过去」就是交接，但那既不够也不安全。

这篇讲清楚交接要传什么、不传什么、怎么格式化和校验，以及一套可落地的模板。

---

## 一、交接的本质：一次有损的信息压缩

交接的本质是：**把父 Agent 拥有的全部信息，压缩成子 Agent 完成任务所需的最小集合。**

这句话里两个关键词：

- **最小集合**：传多了是噪声和风险，传少了子 Agent 干不了活
- **压缩**：父 Agent 的完整上下文里，绝大多数是对子任务无用的过程信息

所以交接不是「转发」，是「**用父 Agent 的理解，为子 Agent 重写一份需求**」。这个重写动作，父 Agent 必须显式完成——不能指望把原文一塞，子 Agent 自己从里面刨。

---

## 二、交接要传什么

一次完整的交接，包含五类信息。少了任何一类都会出问题。

### 2.1 类一：使命（Mission）

**这个子任务要达成什么。** 必须自包含、无指代。

```python
# ❌ 子 Agent 收到这个会懵
"帮我分析一下这份报告"

# ✅ 自包含
"分析《2026Q3 供应链成本报告》（/data/reports/q3-supply.md），
 提取三项核心指标：单位物流成本、库存周转天数、缺货率，
 并对比 2026Q2 的数值给出变化幅度。"
```

**判据：把这段文字单独发给一个不了解上下文的 Agent，它能不能开工？** 能，才算合格。

常见缺陷是**残留指代**：「这家公司」「上次那个问题」「上面提到的数据」——父 Agent 知道这些指什么，子 Agent 不知道。

### 2.2 类二：输入（Inputs）

任务需要的具体数据。两种形式：

```python
@dataclass
class HandoffInput:
    # 形式一：直接内容（小体量）
    inline: str | None

    # 形式二：路径引用（大体量，子 Agent 自己读）
    path: str | None

    # 元信息：帮子 Agent 判断数据可信度和时效
    metadata: dict = field(default_factory=dict)
```

**判断标准：数据超过几百字就用路径，让子 Agent 自己读。** 直接塞内容会把交接消息撑爆，而且子 Agent 可能根本不需要读全文（它可能只用到其中两段）。

### 2.3 类三：约束（Constraints）

**能做什么、不能做什么。**

```python
constraints = {
    "允许的工具": ["read_file", "calculate"],         # 白名单
    "禁止的动作": ["不要调用外部 API", "不要写文件到 /reports 之外"],
    "输出格式": "JSON，字段：indicator, q3_value, q2_value, change_pct",
    "输出位置": "/data/analysis/q3-supply.json",
    "时间预算": "120 秒内完成",
}
```

**约束是安全边界**。不给工具白名单，子 Agent 可能调用父 Agent 才有权限的工具；不限制输出位置，它可能把中间产物写进最终目录。

### 2.4 类四：背景（Context）

**帮助子 Agent 理解「为什么这么做」的少量信息。**

```python
background = {
    "受众": "财务负责人，关注同比变化",
    "口径": "单位物流成本 = 物流总成本 / 发货单数",
    "已知陷阱": "Q2 数据在 7 月初做过一次回溯修正，以修正后为准",
}
```

**背景要极度克制。** 我的经验是：**超过 5 条就该警惕——你是在把父 Agent 的整个上下文倒给它。**

### 2.5 类五：回报格式（Return Contract）

**子 Agent 做完要回什么。**

```python
return_contract = {
    "摘要": "200 字以内，说明三项指标的关键发现",
    "详细结果": "写入上面指定的输出位置",
    "失败时": '返回 JSON {"status": "failed", "reason": "..."}，不要编造数据',
}
```

**「失败时怎么办」必须写。** 否则子 Agent 遇到困难会「尽力而为」——编一个看起来合理的数据回来。这比直接报错危险得多。

---

## 三、什么不该传

这几类信息，交接时绝对不能带。

### 3.1 父 Agent 的完整推理链

父 Agent 想了五轮、试错三次、排除了两个方案——这些是父 Agent 的决策过程，对子 Agent 是**噪声**。子 Agent 只需要父 Agent 的**结论**（「要分析 Q3 报告」），不需要它怎么得出这个结论的。

传了推理链的两个后果：上下文变大；子 Agent 被父 Agent 的思路带偏（比如父 Agent 排除了某个方案，子 Agent 连试都不试了）。

### 3.2 其他用户/租户的信息

这条没有例外。父 Agent 的上下文里如果有客户 B 的信息（哪怕只是顺带出现），交接前必须过滤掉。

**过滤不能靠模型自觉，要靠代码**：

```python
def sanitize_handoff(payload: dict, allowed_tenant: str) -> dict:
    """交接前的租户过滤，代码层做，不靠 prompt。"""
    def check(v):
        if isinstance(v, str):
            # 简单启发式：出现其他 tenant 标识就拒绝
            for other in KNOWN_TENANTS - {allowed_tenant}:
                if other in v:
                    raise HandoffSecurityError(f"交接内容包含租户 {other} 的数据")
        return v
    return {k: check(v) for k, v in payload.items()}
```

生产环境这个检查要做更严（实体识别、字段级 ACL），但**方向是明确的：隔离在交接边界上强制执行**。

### 3.3 凭证、token、敏感配置

子 Agent 不需要父 Agent 的 API key。**交接消息里永远不出现凭证。**

### 3.4 已经被否定的方案

父 Agent 试过方案 A 失败了，不代表子 Agent 不能试——子 Agent 的任务可能不同。但如果传过去，子 Agent 会默认「这个不行」，减少探索空间。

**只在「父 Agent 明确知道这个方案在当前约束下必然失败」时才传**，而且要说明原因。

---

## 四、交接的实现模板

### 4.1 消息格式

用结构化对象，不要用自由文本拼接：

```python
@dataclass(frozen=True)
class Handoff:
    mission: str
    inputs: list[HandoffInput]
    constraints: dict
    background: dict
    return_contract: dict
    # 以下为元数据，用于排障，不进子 Agent 上下文
    _parent_span_id: str = ""
    _created_at: str = ""
```

`frozen=True` 防止传递过程中被篡改。

### 4.2 渲染成子 Agent 的输入

```python
def render_handoff(h: Handoff) -> str:
    parts = [f"【任务】\n{h.mission}"]

    if h.inputs:
        inputs_desc = []
        for i in h.inputs:
            if i.path:
                inputs_desc.append(f"- 数据文件：{i.path}（请用 read_file 读取）")
            else:
                inputs_desc.append(f"- 内容：\n{i.inline}")
        parts.append("【输入】\n" + "\n".join(inputs_desc))

    if h.background:
        parts.append("【背景】\n" +
                    "\n".join(f"- {k}：{v}" for k, v in h.background.items()))

    if h.constraints:
        c = h.constraints
        lines = []
        if c.get("允许的工具"):
            lines.append(f"- 只能使用这些工具：{', '.join(c['允许的工具'])}")
        if c.get("禁止的动作"):
            lines.append(f"- 禁止：{'; '.join(c['禁止的动作'])}")
        if c.get("输出格式"):
            lines.append(f"- 输出格式：{c['输出格式']}")
        if c.get("输出位置"):
            lines.append(f"- 写入位置：{c['输出位置']}")
        parts.append("【约束】\n" + "\n".join(lines))

    parts.append(f"【回报要求】\n{h.return_contract['摘要']}"
                 f"\n失败时：{h.return_contract['失败时']}")

    return "\n\n".join(parts)
```

### 4.3 交接前的自动校验

```python
def validate_handoff(h: Handoff) -> list[str]:
    problems = []
    # 1. 使命必须自包含：不能有指代词
    for word in ["这个", "那个", "上面", "上述", "它", "上次", "刚才"]:
        if word in h.mission:
            problems.append(f"mission 含指代词「{word}」，子 Agent 无法理解")
    # 2. 至少有一个输入或明确的「无需输入」
    if not h.inputs and "无需输入" not in h.mission:
        problems.append("没有 inputs，子 Agent 可能缺数据")
    # 3. 必须有回报契约
    if not h.return_contract.get("失败时"):
        problems.append("未定义失败时的回报方式")
    # 4. 安全过滤
    try:
        sanitize_handoff(as_dict(h), current_tenant)
    except HandoffSecurityError as e:
        problems.append(f"安全检查失败: {e}")
    return problems
```

**校验不通过就不要交接。** 把问题反馈给父 Agent 让它重写 mission，比让子 Agent 猜要好得多。

---

## 五、交接后的责任边界

交接完成不代表父 Agent 没事了。

### 5.1 父 Agent 的收尾职责

```python
def run_subtask(handoff: Handoff):
    payload = render_handoff(handoff)
    problems = validate_handoff(handoff)
    if problems:
        # 反馈给父 Agent，让它修
        return {"status": "handoff_invalid", "problems": problems}

    result = sub_agent.invoke({"messages": [("human", payload)]})
    summary = result.messages[-1].content

    # 校验回报是否符合契约
    if not conforms_to_contract(summary, handoff.return_contract):
        return {"status": "contract_violation", "raw": summary}

    return {"status": "ok", "summary": summary, "detail_path": handoff.constraints.get("输出位置")}
```

**「回报是否符合契约」要校验。** 子 Agent 经常会忽略「200 字以内」「返回 JSON」这类要求。

### 5.2 失败的传播

子 Agent 失败时，要把**失败原因如实传回父 Agent**，而不是父 Agent 自己猜：

```python
if result["status"] == "ok":
    return result
# 失败原因 + 已尝试的方案 + 建议
return {
    "status": "subtask_failed",
    "reason": result.get("reason"),
    "retryable": result.get("retryable", False),
}
```

父 Agent 拿到这些才能决定：重试、换方案、还是降级。

---

## 六、常见误区

**误区一：直接把对话历史甩给子 Agent。** 最常见也最糟糕。上下文膨胀、信息过载、可能泄漏其他租户数据。

**误区二：mission 写得太简略。** 「分析一下」「处理一下」——子 Agent 只能瞎猜，猜错就是浪费一整轮。

**误区三：不给工具白名单。** 子 Agent 可能调用父级专属的高危工具。

**误区四：忘了定义失败回报。** 子 Agent 会编数据而不是报错。

**误区五：交接前不做安全过滤。** 其他租户信息跟着上下文就过去了，这是数据泄露不是 bug。

**误区六：交接后不管。** 子 Agent 回报不符合契约（太长、格式错、结论含糊），父 Agent 直接拿去用，错误就传导到了最终输出。

**误区七：背景信息倒太多。** 把父 Agent 的整个理解都传给子 Agent，看着「信息充分」，实际是把它塞进了噪声。

---

## 小结

- 交接的本质是**有损压缩**：把父 Agent 的全部信息，压成子 Agent 所需的最小集合。**父 Agent 必须显式做这次重写**，不能原文转发。
- 五类必传：**使命（自包含无指代）、输入（大文件走路径）、约束（工具白名单 + 输出契约）、背景（克制，≤5 条）、回报格式（含失败时怎么办）**。
- 四类不传：**父 Agent 的推理链、其他租户信息、凭证、已被否定的方案**（除非确实必然失败）。
- **交接前必须自动校验**：mission 无指代词、有输入或明确说明无需输入、有失败契约、租户安全过滤。不通过就打回让父 Agent 重写。
- **交接后必须收尾**：校验回报是否符合契约，不合规要处理而不是直接用。
- 安全过滤**靠代码不靠 prompt**——隔离是边界，不是请求。

交接做得好，多 Agent 系统会明显更稳、更便宜、更安全。做得差（直接转发），你会发现多出来的 Agent 一个都不省心——它们要么笨（信息不全），要么慢（信息太多），要么危险（信息越界）。
