# ReAct 范式：让大模型「想一步、做一步、看一步」

如果你去读 Agent 相关的论文或框架源码，几乎一定会碰到一个词：**ReAct**。它出现在本篇的第 2 篇，是因为它是目前绝大多数 Agent 的决策骨架——LangChain 的默认 Agent、各种开源实现，底层都是这个循环。

ReAct 的全称是 **Re**asoning + **Act**ing，核心思想朴素得有点意外：**让模型把「思考」说出来，再据此行动，然后观察结果，再思考**。

这篇讲三件事：**循环长什么样、为什么要把思考写出来、以及怎么自己实现一个能跑的版本**。

---

## 一、三种模式的对比

假设任务是：「Python 里 `pandas` 最新稳定版是多少？」

**模式 A：直接问答（Standard）**

模型凭记忆答一个版本号。问题是它的训练数据有截止日期，答案大概率是旧的——这就是幻觉。

**模式 B：只行动，不说话（Act-only）**

模型直接输出 `search("pandas latest version")` → 拿到结果 → 输出答案。能用，但遇到需要多步推理的任务容易走偏，因为它没有地方「打草稿」。

**模式 C：ReAct**

```
思考 1：我需要查 pandas 的最新版本，我的训练数据可能过时了。
行动 1：search("pandas latest release version")
观察 1：pandas 2.2.3 是最新稳定版，发布于 2024 年 9 月。
思考 2：拿到了确切版本号，可以直接回答了。
行动 2：finish("pandas 最新稳定版是 2.2.3")
```

差别就在于**「思考」这一步被显式写出来了**。

---

## 二、为什么把「思考」写出来真的有用

这一点初看很反直觉：让模型多说话，难道不是更费 token 吗？

确实更费，但换来三个好处：

**1. 给了模型一个「草稿纸」**

大模型是逐个 token 生成的，它没有「回头改前面」的能力。如果它必须在同一个输出里完成「推理 + 决策」，推理过程就被压缩了。把思考单独写出来，等于让它在输出决策之前先做了一段**可见的链式推理**（Chain of Thought），决策质量明显更高。

**2. 让每一步都可追溯**

Agent 跑错的时候，你能看到它当时是怎么想的。没有思考链，你只能看到一个莫名其妙的工具调用，排查全靠猜。

**3. 给了纠错的锚点**

观察到结果后，模型可以显式地写「上一步的结果说明我猜错了，应该换个方向」。这种自我修正在 Act-only 模式下很难自然发生。

---

## 三、循环的三个要素

ReAct 的每一步由三部分组成，缺一不可：

| 要素 | 作用 | 由谁产生 |
|---|---|---|
| **Thought（思考）** | 分析现状、规划下一步 | 模型生成 |
| **Action（行动）** | 调用哪个工具、传什么参数 | 模型生成 |
| **Observation（观察）** | 工具返回的真实结果 | **外部执行**，不是模型编的 |

**Observation 必须由外部真实执行产生**——这是 ReAct 和普通 CoT 的根本区别。模型可以「想」，但不能自己「编造观察结果」，否则就退化回幻觉了。

流程可以画成：

```
        ┌──────────────────────────┐
        │                          │
        ▼                          │
   Thought ──► Action ──► Observation
                                   │
                                   └──► （回到 Thought）
```

---

## 四、提示词怎么设计

ReAct 不需要特殊 API，靠提示词就能驱动。一个能用的模板长这样：

```
你是一个可以调用工具的助手。按下面的格式思考，每轮只输出一轮：

Thought: 你当前的思考
Action: 工具名
Action Input: 工具的 JSON 参数
Observation: （这一步由系统填入，你不要自己写）

可用工具：
- search(query): 搜索网页，返回摘要
- calculator(expression): 计算数学表达式
- finish(answer): 给出最终答案并结束

规则：
- 每次只输出一个 Action
- 收到 Observation 后再决定下一步
- 最多 8 轮，超过请直接 finish
```

几个实践要点：

1. **格式要严格且唯一**。用 `Thought:` / `Action:` 这种固定前缀，解析时才好用正则提取。
2. **明确禁止模型自己写 Observation**。不然它会自己编一个结果然后宣布成功——这就是前面说的「幻觉成功」。
3. **给轮数上限**。写在提示词里，同时代码里也要兜底。
4. **工具列表要精简**。工具太多模型会挑花眼，一般控制在 5~8 个。

---

## 五、自己实现一个

下面是一个完整可运行的 ReAct 循环，包含一个解析器：

```python
import re, json

TOOLS = {
    "search": lambda q: f"搜索结果：{q} 的最新版本是 2.2.3（2024-09 发布）",
    "calculator": lambda e: str(eval(e)),
}

PROMPT = """你是一个可以调用工具的助手，按以下格式工作：

Thought: 你的思考
Action: 工具名
Action Input: JSON 参数

可用工具：search(query) / calculator(expression) / finish(answer)
注意：Observation 由系统填入，你绝不能自己编造。最多 8 轮。

任务：{goal}
"""

def parse(text: str):
    """从模型输出里抠出 Action 和参数"""
    m = re.search(r"Action:\s*(\w+)", text)
    a = re.search(r"Action Input:\s*(.+)", text)
    if not m:
        return None, None
    tool = m.group(1).strip()
    try:
        args = json.loads(a.group(1).strip()) if a else {}
    except json.JSONDecodeError:
        args = {"_raw": a.group(1).strip()}
    return tool, args

def react(goal, llm, max_rounds=8):
    history = PROMPT.format(goal=goal)

    for r in range(max_rounds):
        out = llm(history)                      # 模型输出 Thought + Action
        tool, args = parse(out)

        if tool is None or tool == "finish":    # 没有 Action 或主动结束
            return out

        if tool not in TOOLS:                   # 工具名写错 → 把错误告诉它，让它重试
            obs = f"错误：没有名为 {tool} 的工具，可用的是 {list(TOOLS)}"
        else:
            try:
                obs = TOOLS[tool](**args)
            except Exception as e:              # ★ 异常也要如实回传
                obs = f"工具执行失败：{e}"

        history += f"\n{out}\nObservation: {obs}\n"   # 观察结果拼回上下文

    return "已达最大轮数，强制结束"
```

这段代码里三个**容易被忽略但很关键的设计**：

1. **工具名写错时返回错误让它重试**，而不是直接崩溃。模型经常把 `search` 写成 `Search` 或 `web_search`，给一次纠正机会就能救回来。
2. **异常原样回传**。第 5 行的 `except` 把真实报错塞进 Observation——这是防止「幻觉成功」的关键。
3. **历史是字符串累加**。真实项目里应该改成消息列表（system / user / assistant 角色分离），但原理一样：把 Observation 作为新的输入喂回去。

---

## 六、ReAct 的三个已知弱点

用之前先知道它会在哪里出问题：

**1. 上下文膨胀**

每轮都把完整历史拼回去，10 轮之后提示词就有几千 token。长任务要做**历史压缩**：只保留最近 N 轮，更早的做摘要。

**2. 容易在原地打转**

「搜 A 没结果 → 再搜 A → 还是没结果」是很常见的死循环。缓解办法：在提示词里加「不要重复上一步失败的行动」，或者在代码里检测重复调用并强制打断。

**3. 对模型能力有要求**

小模型很难稳定输出合规格式，经常漏写 `Action Input` 或者格式错乱。**7B 以下的模型跑 ReAct 会比较吃力**，需要加格式校验和重试。

---

## 七、小结

1. ReAct = **Thought → Action → Observation** 的循环，是目前最主流的 Agent 决策骨架。
2. 「把思考写出来」不是浪费 token，它是给模型的**草稿纸**，同时让过程可追溯、可纠错。
3. **Observation 必须来自真实执行**，模型绝不能自己编——这是 ReAct 与纯 CoT 的分界线。
4. 实现上有三个必做：格式严格解析、错误如实回传、轮数设上限。
5. 主要弱点是上下文膨胀和原地打转，分别靠历史压缩和重复检测来缓解。

下一篇讲 Function Calling——它是 ReAct 里「Action」这一步的工业化实现，把「靠提示词约束输出格式」变成了「模型原生支持的结构化输出」。
