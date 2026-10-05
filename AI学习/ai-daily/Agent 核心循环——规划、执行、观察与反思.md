<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# Agent 核心循环——规划、执行、观察与反思

**承上**：阶段 7 我们做出来的 RAG 是**被动**的——你问一句它答一句，全程没有"自己想办法"。但现实任务往往是"查上个月销量前十、做个对比图、发我邮箱"这种**多步、需调用工具、要根据中间结果调整策略**的事。RAG 做不了，缺的就是一个**会循环的大脑**。

**本篇**：讲清 Agent 到底是什么、它和普通"调一次大模型"的本质区别；手把手实现经典的 **ReAct 循环**（Reason + Act：思考 → 行动 → 观察 → 再思考），并用一个**不依赖任何 API、复制粘贴就能跑**的例子，让大模型第一次"自己动起来"。最后聊 Agent 工程里最容易翻车的几个坑。

**启下**：这一篇是"手写裸循环"，理解了原理，下一站 **8-2《工具调用框架——LangChain 与 LlamaIndex 入门》** 就会讲清楚：怎么用现成框架把工具、记忆、规划这些零件标准化，别每次都从头写胶水代码。

**学完这一节，你能动手做**：

1. 用自己的话讲清 Agent 与普通 LLM 调用的区别（为什么需要循环）
2. 从零手写一个 ReAct 循环，让模型自己决定调用哪个工具、调几次
3. 跑通一个离线版 Agent（查天气 + 单位换算），看懂 Thought/Action/Observation 是怎么串起来的
4. 识别 Agent 的三个常见失败模式（死循环、幻觉工具、不收敛）并知道对策

---

## 一、先拆掉一个误解：Agent 没那么神秘

很多人一听"AI Agent"就觉得是某种新模型。其实：

> **Agent = 大模型（大脑） + 工具（手脚） + 循环（让它反复思考的引擎）**

模型本身没变，还是那个 GPT / Qwen / DeepSeek。**Agent 化的关键不在模型，而在"套在模型外面的那层循环"**——让模型能：

1. **自己决定下一步做什么**（而不是你写死每一步）；
2. **调用外部工具**（查数据库、调 API、运行代码、读文件）；
3. **看到结果后再决定**（根据 Observation 调整下一步）。

这就是"智能体"和普通"问答接口"的本质区别。

```
普通 LLM 调用（一次性）：
  问题 → [大模型] → 答案

Agent（带循环）：
  问题 → [大模型] → 计划 → 调工具 → 看结果 → [大模型] → 再计划 → 调工具 → …
                                                           ↓ 直到任务完成
                                                        最终答案
```

看明白了吗？右边那张图里，**大模型被套进了一个 while 循环**。这正是本篇要手写的 ReAct 循环。

## 二、为什么需要"循环"？一个具体例子

假设用户问："北京今天多少度？换算成华氏度是多少？"

- **普通 LLM 调用**：模型可能直接瞎编一个"约 79°F"。它没真去查天气，也没真去换算——纯靠训练记忆**幻觉**。
- **Agent 循环**：模型先想"我得查天气"→ 调 `get_weather` 拿到真实 26°C → 再想"要换算"→ 调 `celsius_to_fahrenheit` → 拿到 78.8°F → 才给出答案。

差别在：**Agent 的每一步结论，都来自真实工具的输出，而不是模型的猜测。**

这正是 Agent 价值最大的地方——**把"可能记错的事实"交给工具，把"怎么组合推理"交给模型**。

## 三、ReAct：目前最经典、也最好懂的 Agent 范式

ReAct 是 2022 年 Google 提出的一个框架，名字来自两个词：

- **Re**asoning（推理）：模型先"想"一步，写下自己的思考过程（Thought）；
- **Act**ion（行动）：然后决定调用哪个工具（Action）。

它的输出格式非常讲究，必须让模型按固定模板吐字，方便我们用代码解析：

```
Thought: 我需要先查出北京的天气。
Action: get_weather[{"city": "北京"}]
Observation: 北京：晴，26°C
Thought: 拿到 26°C，现在换算成华氏度。
Action: celsius_to_fahrenheit[{"celsius": 26}]
Observation: 78.8°F
Thought: 已经拿到结果，可以给出最终答案。
Action: Finish[北京今天晴，26°C，约合 78.8°F]
```

注意三组关键词的固定分工：

| 关键词 | 谁产生 | 作用 |
|---|---|---|
| `Thought:` | 模型 | 内部思考，给人看、给模型下一步参考 |
| `Action:` | 模型 | 决定调哪个工具、传什么参数 |
| `Observation:` | **代码/工具** | 工具的真实返回值，再喂回给模型 |

**最关键的一点**：`Observation` 不是模型写的，是我们把工具返回值填进去的。这一步把"真实世界"接进了循环。

## 四、手把手实现一个 ReAct 循环（离线版，无需 API）

下面这个实现**不调用任何大模型 API**，用一个"假装是模型"的脚本驱动，目的只有一个：**让你看清循环的每一根血管**。你把它换成真正的 LLM 客户端，就是生产版。

```python
import re, json

# —— 1. 工具箱：每个工具是 (说明, 函数) ——
def get_weather(city): return f"{city}：晴，26°C"
def c_to_f(celsius):  return f"{float(celsius) * 9 / 5 + 32:.1f}°F"

TOOLS = {
    "get_weather":           ("查询城市天气，参数 city",           get_weather),
    "celsius_to_fahrenheit": ("摄氏度转华氏度，参数 celsius",       c_to_f),
}

# —— 2. 假的"大模型"：按固定剧本吐 Thought/Action ——
SCRIPT = [
"""Thought: 用户想知道北京天气的华氏度，我需要先查摄氏度。
Action: get_weather[{"city": "北京"}]""",
"""Thought: 已拿到 26°C，现在转换成华氏度。
Action: celsius_to_fahrenheit[{"celsius": 26}]""",
"""Thought: 已经算出 78.8°F，可以给最终答案了。
Action: Finish[北京今天晴，26°C，约合 78.8°F]""",
]

class FakeLLM:
    def __init__(self, script): self.s, self.i = script, 0
    def generate(self, prompt):
        r = self.s[min(self.i, len(self.s) - 1)]; self.i += 1
        return r

# —— 3. 解析模型的 Action 行 ——
ACTION_RE = re.compile(r"Action:\s*(\w+)\s*\[(.*?)\]", re.S)

def parse_action(text):
    m = ACTION_RE.search(text)
    if not m: return None, None, None
    name, raw = m.group(1), m.group(2)
    try:
        return name, json.loads(raw) if raw.strip() else {}, None
    except json.JSONDecodeError:
        return name, {}, raw          # Finish 的答案是自然语言，不是 JSON

# —— 4. 核心循环：反复 思考→行动→观察 直到 Finish ——
def run_react(question, llm, tools, max_steps=5, verbose=True):
    prompt = f"可用工具：{', '.join(tools)}\n\n问题：{question}"
    history = []
    for step in range(1, max_steps + 1):
        out = llm.generate(prompt + "\n" + "\n".join(history))
        if verbose: print(f"\n--- 第 {step} 步 ---\n{out}")
        name, args, raw = parse_action(out)
        if name is None:                 # 模型没按要求输出 Action → 直接当答案
            return out, history
        if name == "Finish":             # 模型认为任务完成
            return (raw or out), history
        if name not in tools:            # 模型幻觉出一个不存在的工具
            obs = f"错误：没有工具 {name}"
        else:
            try:
                obs = tools[name][1](**args)   # 真正执行工具
            except Exception as e:
                obs = f"错误：{type(e).__name__}: {e}"
        if verbose: print(f"Observation: {obs}")
        history.append(out + f"\nObservation: {obs}")   # 把结果塞回历史，供下一步推理
    return "⚠️ 达到最大步数仍未完成", history

ans, _ = run_react("北京今天多少度？换算成华氏度是多少？", FakeLLM(SCRIPT), TOOLS)
print("\n最终答案:", ans)
```

**运行结果**（真实输出，不是推算）：

```
--- 第 1 步 ---
Thought: 用户想知道北京天气的华氏度，我需要先查摄氏度。
Action: get_weather[{"city": "北京"}]
Observation: 北京：晴，26°C

--- 第 2 步 ---
Thought: 已拿到 26°C，现在转换成华氏度。
Action: celsius_to_fahrenheit[{"celsius": 26}]
Observation: 78.8°F

--- 第 3 步 ---
Thought: 已经算出 78.8°F，可以给最终答案了。
Action: Finish[北京今天晴，26°C，约合 78.8°F]

最终答案: 北京今天晴，26°C，约合 78.8°F
```

把假 LLM 换成真 LLM 时，`llm.generate(prompt)` 内部改为：把 `prompt + history` 发给 `openai.chat.completions.create(...)`。循环、解析、工具执行这一套**完全不用改**——这就是 ReAct 范式的魅力：推理和执行业务是解耦的。

## 五、三个"坑"，新手 90% 会踩

### 坑 1：模型输出解析失败（循环卡死）

模型不一定每次都严格按 `Action: xxx[...]` 输出。它可能写 `Action: get_weather(北京)`（括号不是 JSON），或加一堆解释文字。

**对策**：
- 解析用正则（如上），宽松匹配；
- 给模型清晰的 few-shot 示例（阶段 6 的 6-1 讲过）；
- 解析失败时，把"请严格按 Action: 工具名[{"参数":值}] 格式输出"作为 Observation 回喂，让模型重试。

### 坑 2：工具不存在 / 参数错误（幻觉工具）

模型可能编一个 `Action: search_google[...]`，而你的工具箱里根本没有它；或传了错误的参数名（比如上一节的 `celsius_to_fahrenheit[{"celsius": 26}]`，若函数签名是 `(c)` 就会 `TypeError`）。

**对策**：本代码已经做了两层保护——先判断 `name not in tools`，再 `try/except` 捕获参数错误。把**错误 Observation 回喂给模型**，它通常会自我纠正（"啊，应该这样调"）。这正好体现了"观察→反思"的价值。

### 坑 3：死循环（不收敛）

模型反复调用同一个工具，永远不 `Finish`。

**对策**：必须设 `max_steps`（上例是 5）。超出就强制终止并返回中间结果，同时告诉用户"任务未完成，请简化问题或补充工具"。阶段 6 的 6-4 也讲过，每次 LLM 调用都算 token，**无限循环 = 无限烧钱**。

## 六、把视角拉高：ReAct 和 RAG 怎么配合？

其实你在 7-4 写的 RAG 检索函数，完全可以注册成 Agent 的一个工具：

```
TOOLS = {
    "rag_search":   ("在知识库里检索资料，参数 query",  rag_pipeline.answer),
    "get_weather":  ("查询天气",                         get_weather),
    ...
}
```

这样一个 Agent 既能"查知识库"，又能"查实时天气"，还能"算单位换算"——**它自己决定什么时候该用哪个**。这比单独的 RAG 强在：用户问题可以是多轮的、跨工具的、需要组合结果的。这就是智能体的起点。

## 七、本篇小结

1. **Agent ≠ 新模型**，它是"大模型 + 工具 + 循环"的组合体；价值在于把"可能记错的事实"交给工具，把"怎么组合推理"交给模型。
2. **ReAct 范式**：`Thought → Action → Observation` 反复循环，直到模型输出 `Finish`。`Observation` 是真实工具返回值，由代码填入，是连接真实世界的接口。
3. 我们手写的离线版已经跑通：查天气 → 单位换算 → 输出答案，**三步自动完成，零幻觉**。
4. 三大坑：解析失败、幻觉工具、死循环——都有对策（正则解析 + 错误回喂 + max_steps 上限）。
5. **Agent 与 RAG 不是替代关系**：RAG 检索函数可以注册成 Agent 的一个工具，二者协作威力最大。

> 本篇是《大模型开发从 0 到 1》专栏第 42 篇，阶段 8「Agent 智能体开发」第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
