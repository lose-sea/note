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

很多人一听"AI Agent"就觉得是某种新模型、新算法，甚至觉得"Agent 是不是比 GPT 更聪明"。其实真相特别朴素，朴素到可能让你有点失望：

> **Agent = 大模型（大脑） + 工具（手脚） + 循环（让它反复思考的引擎）**

模型本身没变，还是那个 GPT / Qwen / DeepSeek / Claude。**Agent 化的关键根本不在模型，而在"套在模型外面的那层循环与控制逻辑"**——让模型能：

1. **自己决定下一步做什么**（而不是你写死每一步"先调 A 再调 B"）；
2. **调用外部工具**（查数据库、调 API、运行代码、读文件、发邮件）；
3. **看到结果后再决定**（根据 Observation 调整下一步策略，而不是一条道走到黑）。

这就是"智能体"和普通"问答接口"的本质区别。为了把这件事讲透，请你做一个思想实验：把大模型想象成一位智商极高、但被关在一间没有窗、没有门、没有任何外接设备的黑屋子里的专家。他读过世界上所有的书（训练语料），所以你问他"勾股定理是什么""怎么用 Python 读文件"，他能流畅回答。但他碰不到屋外的任何真实世界：他不知道今天北京下了没下雨，算不出你数据库里最新的销售额，也没法真的帮你发出那封邮件。普通 API 调用，就是你在门外写张纸条递进去、他口述一个答案递出来，**全程他没碰过屋外的任何东西，所有答案都来自他脑子里的记忆（训练数据）**。

而 Agent 做了什么？它在这位专家手边装了一套"传声 + 跑腿"装置：他每想一步，就写张条子说"去把北京天气查来"，跑腿的（你的代码）真去查了，把结果再递进屋给他看，他接着想下一步。于是他第一次能"感知"并"作用于"真实世界。这一整套装置，就是我们要写的循环。

```
普通 LLM 调用（一次性，黑屋里口述）：
  问题 → [大模型] → 答案（可能凭记忆瞎编）

Agent（带循环，屋外有跑腿）：
  问题 → [大模型] → 计划 → 调工具 → 看结果 → [大模型] → 再计划 → 调工具 → …
                                                           ↓ 直到任务完成
                                                        最终答案
```

看明白了吗？上面那张图里，**大模型被套进了一个 while 循环**，而且每次循环之间，我们用"Observation"把真实世界的反馈又塞回了模型面前。这正是本篇要手写的 ReAct 循环。你不妨把这张图截图保存，后面学 LangChain、AutoGen 时反复对照——你会发现它们全是这张图的"精致包装版"。

这里还有一个极容易被忽略、但决定了你能否真正理解 Agent 的点：**Agent 并没有让模型"变聪明"，它只是把模型从"只能靠记忆猜"解放成"可以依赖真实数据"**。一个没接工具的模型，遇到"今天北京天气"这种时效性问题只能幻觉；接了 `get_weather` 工具后，它不必记得天气，只要"知道该去查"即可。换句话说，**Agent 的核心价值不是推理能力的提升，而是"推理"与"真实世界"之间的闭环**。推理能力是模型给的，闭环是你（作为工程师）用循环搭出来的。理解了这一句，后面所有框架你都不会再觉得神秘——它们做的无非是把这个闭环做得更稳、更可观测、更容易扩展。

进一步说，Agent 的出现不是偶然，而是大模型能力演进的必然结果。早期大家用大模型就是"写文案、做翻译"，一句话进去一句话出来，不需要循环。但业务方很快发现：真正的生产力任务（订机票、分析报表、自动回复工单）几乎都是多步的、需要真实数据的。模型自己干不了（它没有手），于是工程师把"手"接上，"循环"作为连接大脑和手的神经，自然就成了标配。所以你今天看到的所有"能干实事"的 AI 应用——GitHub Copilot 写代码、各种数据分析助手、智能客服——底层都是这个循环，区别只在工具和循环的复杂度。

**延伸一个判断**：你可能会问"那我什么时候该用 Agent，什么时候不该？"一个实用的判断准则是——**只有当任务"需要真实数据"且"需要多步"时，Agent 才划算**。如果只是"写一首诗""翻译一段话"，一次性调用就够了，上 Agent 反而多花钱、多延迟。具体可以套这个判断树：任务要不要查实时/外部数据？要不要分几步、且后一步依赖前一步结果？如果两个都是"是"，上 Agent；否则，老老实实一次性调用。这个准则在 8-2、8-4 还会反复用到，建议你现在就建立直觉。

## 二、为什么需要"循环"？一个具体例子

为了让你真切感受到"循环"的意义，我们对比同一个问题在两种模式下的表现，并且我故意选一个"模型一定会错"的问题。

假设用户问："北京今天多少度？换算成华氏度是多少？"

- **普通 LLM 调用**：模型可能直接瞎编一个"约 79°F"，或者更离谱地输出"北京今天 30 度，华氏 86 度"。它没真去查天气，也没真去做换算——纯靠训练记忆**幻觉**。你若拿这个数据去决定"要不要穿外套"，就是建立在沙子上。更要命的是，你**根本分不清**它是真查的还是编的，因为它输出得信誓旦旦。
- **Agent 循环**：模型先想"我得查天气"→ 调 `get_weather` 拿到真实 26°C → 再想"要换算"→ 调 `celsius_to_fahrenheit` → 拿到 78.8°F → 才给出答案。中间任何一步都基于上一步的真实输出。

差别在：**Agent 的每一步结论，都来自真实工具的输出，而不是模型的猜测。** 模型负责"想怎么组合"，工具负责"拿到准确事实"。这种分工带来三个实打实的好处，请你务必记住，因为它们是后面所有 Agent 设计的底层动机：

1. **事实可信**：温度、汇率、库存、最新股价这些会变的量，永远来自工具，不会过期。模型"记"的是"该找谁查"，而不是"具体数值是多少"——这让它对时效性免疫。
2. **可追责**：每一步 Action 和 Observation 都留痕，出了问题你能精确定位是哪一步调错了工具、传错了参。普通调用里模型答错了，你只能说"它错了"，但 Agent 里你能说"它在第三步调 `celsius_to_fahrenheit` 时把字符串当数字传了"。
3. **可扩展**：想加能力，只要注册新工具，不用重训模型、不用改写它的脑子。今天加个查天气，明天加个发邮件，模型"不知道"具体怎么查库没关系，只要"知道该调哪个工具"就行——这是一种极低的边际成本。

这正是 Agent 价值最大的地方——**把"可能记错的事实"交给工具，把"怎么组合推理"交给模型**。这也是为什么今天几乎所有"能干实事"的 AI 应用（写代码助手、数据分析助手、客服机器人）背后都是 Agent，而不是单纯的一次性对话。如果你只能从本篇记住一句话，就记这句：**Agent 让模型从"凭记忆猜"变成"靠工具证"**。

## 三、ReAct：目前最经典、也最好懂的 Agent 范式

ReAct 是 2022 年 Google 研究人员提出的一个框架，论文名就叫作 "ReAct: Synergizing Reasoning and Acting in Language Models"。它的名字来自两个词的组合，请你拆开理解：

- **Re**asoning（推理）：模型先"想"一步，写下自己的思考过程（Thought）；
- **Act**ion（行动）：然后决定调用哪个工具（Action）。

为什么要把"想"和"做"显式分开写下来？这是 ReAct 最精妙的设计，也是很多人第一次读论文会忽略的点。大模型是概率生成文本的，如果我们不让它把思考过程显式写出来，它就会在脑内"暗箱"推理——你既看不到它为什么这么决定，也无法在它走偏时纠正。ReAct 强制模型**把思考过程以文本形式外化**，这带来两个巨大好处：一是**人能看懂它的决策链**（可解释性，这在医疗、金融等严肃场景至关重要）；二是模型自己也能在下一步看到上一步的思考，形成连贯的逻辑流（自一致性，减少前后矛盾）。换句话说，Thought 既是给人看的"黑匣子录音"，也是给模型自己看的"备忘录"。

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

注意三组关键词的固定分工，这张表请刻进脑子：

| 关键词 | 谁产生 | 作用 | 谁来解析 |
|---|---|---|---|
| `Thought:` | 模型 | 内部思考，给人看、给模型下一步参考 | 一般忽略，仅作上下文 |
| `Action:` | 模型 | 决定调哪个工具、传什么参数 | 代码必须解析 |
| `Observation:` | **代码/工具** | 工具的真实返回值，再喂回给模型 | 代码填入，模型读取 |

**最关键的一点**：`Observation` 这一行**不是模型写的**，是我们把工具返回值填进去的。这一步把"真实世界"接进了循环，是整个 Agent 的灵魂。如果模型自己写了 Observation（比如它假装工具返回了某个值），那就退回到了"幻觉"的老路——所以严格实现里，Observation 必须来自你的代码，绝不让模型代笔。

ReAct 之外，业界还有几种常见范式，顺手对比一下，帮你建立全局观，避免以为 ReAct 是唯一的答案：

| 范式 | 特点 | 适合场景 |
|---|---|---|
| **ReAct**（Thought+Action） | 边想边做，最直观，本篇主讲 | 通用多步任务，调试友好 |
| **Plan-and-Execute** | 先一次性列完整计划，再逐步执行 | 步骤可预见的复杂任务，省 token |
| **Reflexion**（反思） | 失败后让模型自我反思写"经验教训"再重试 | 需要试错、代码生成类任务 |
| **ReWOO**（无观察） | 一次性规划多个工具调用，最后统一执行 | 工具间无依赖、要省 LLM 调用次数 |
| **Function Calling** | 用模型原生能力替代文本解析 Action | 生产主流，比正则解析更稳 |

你先吃透 ReAct 就够了，其他范式本质都是在"何时思考、何时行动、如何纠错"上做变体。等你有经验了再回头看这张表，会发现它们是同一棵树的枝丫。

### 3.1 ReAct 与 Function Calling：同一件事的两种做法

读到这里你多半会冒出一个疑问：既然要让模型调工具，为什么还要"多此一举"让它输出一段文本、再由我们用正则去抠？让模型直接返回一个结构化的 JSON 不好吗？答案是——**好，而且今天的生产系统大多就是这么干的**，这条路的官方名字叫 **Function Calling（函数调用）/ Tool Use**。请务必把这对概念刻进脑子，因为它是后续所有工程的默认形态。

两者的区别，只在"模型表达'我要调工具'这件事的方式"不同，其余完全一致：

| 对比项 | ReAct（文本协议） | Function Calling（结构化协议） |
|---|---|---|
| 模型怎么表达"要调工具" | 自然语言里写一串 `Action: xxx[...]` | 返回结构化对象：`{"name":"get_weather","arguments":{"city":"北京"}}` |
| 谁来解析 | 我们写正则 / 解析器 | SDK 直接给结构化对象，几乎不会解析失败 |
| 还需不需要 Thought | 必须（否则模型不做推理） | 仍可输出推理文本，但工具调用本身不再依赖文本 |
| 出错概率 | 中（格式一走样就解析失败） | 低（schema 把输出空间约束死了） |
| 典型代表 | 早期 LangChain ReAct Agent、不支持 FC 的模型 | OpenAI / DeepSeek / Qwen 原生支持，LangChain 新版默认 |
| 适合 | 学习原理、老模型兜底 | 生产首选 |

Function Calling 的做法是：你在请求里额外传一份 `tools` 数组，每个工具写清 `name`、`description` 和参数的 JSON Schema；模型不再"自由发挥写 Action 行"，而是被约束成只能吐出符合 schema 的调用意图。请求侧长这样（注意 description 这行中文——它就是模型唯一的判断依据）：

```json
{
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "查询某城市的当前天气。参数 city 用中文城市名。",
        "parameters": {
          "type": "object",
          "properties": {
            "city": { "type": "string", "description": "城市名，例如：北京" }
          },
          "required": ["city"]
        }
      }
    }
  ]
}
```

模型不会直接回答，而是返回一个"调用意图"：

```json
{
  "tool_calls": [
    { "function": { "name": "get_weather", "arguments": "{\"city\": \"北京\"}" } }
  ]
}
```

请盯住 `arguments` 这个字段：它居然是一个**字符串**，而不是你以为的对象（各家 SDK 约定不完全一致，有的实现给 dict，有的给 JSON 字符串）。无数初学者第一次写 Function Calling 就被这里绊倒——拿到后一定要先 `json.loads` 再传给你的 Python 函数，否则你会看到 `TypeError: ... takes 1 positional argument but 2 were given` 这种莫名其妙的报错。这个不起眼的小细节，值得你单独拿荧光笔标出来。

那么问题来了：既然 Function Calling 更稳，为什么本篇还要让你手写 ReAct？三个理由，缺一不可。

第一，**ReAct 是理解 Agent 的最短路径**。文本协议把"思考—行动—观察"的全过程明明白白摊在你眼前，每一步你能 print 出来；Function Calling 把这些藏进了 SDK，初学时你会陷入"能跑，但不知道为什么能跑"的状态——而这恰恰是排查线上问题的最大障碍。

第二，**不是所有模型都支持 Function Calling**。一些本地部署的小模型、老版本模型只认文本。届时 ReAct 那套解析就是你唯一的兜底方案。

第三，也是最重要的：**循环骨架一模一样**。Function Calling 只替换了"`parse_action` 解析 Action"这一小段，后面的"执行工具、把返回值回喂、控制步数、判断 Finish"原封不动。换句话说，**你今天写的这个 ReAct 循环，明天只要把 `parse_action` 换成 SDK 返回的结构化对象，就是生产版**。这正是本专栏始终坚持"先手写、后框架"的原因：**原理是不变量，API 是易变量**。把不变量学扎实，任何易变量你都能一夜之间上手。

## 四、手把手实现一个 ReAct 循环（离线版，无需 API）

下面这个实现**不调用任何大模型 API**，用一个"假装是模型"的脚本驱动，目的只有一个：**让你看清循环的每一根血管、每一条数据流**。等你看懂了，把它换成真正的 LLM 客户端（把 `llm.generate` 内部改成调用 `openai.chat.completions.create`），立刻就是生产版。请逐行读，不要跳。

整体流程用一张 ASCII 图先建立直觉，这张图是本篇最重要的"地图"：

```
        ┌─────────────────────────────────────────────┐
        │                  run_react()                  │
        │                                               │
        │   初始化 prompt = 工具说明 + 问题              │
        │                                               │
        │   for step in 1..max_steps:                   │
        │        │                                      │
        │        ▼                                      │
        │   out = llm.generate(prompt + history)  ◀── 模型思考 │
        │        │                                      │
        │        ▼                                      │
        │   name, args = parse_action(out)       ◀── 解析 Action │
        │        │                                      │
        │        ├── name 为 None → 当最终答案返回       │
        │        ├── name == "Finish" → 返回答案        │
        │        ├── name 不在工具箱 → 报错 Observation  │
        │        └── 否则 执行 tools[name](**args)       │
        │                  │                            │
        │                  ▼                            │
        │        obs = 工具真实返回值             ◀── 真实世界 │
        │                  │                            │
        │                  ▼                            │
        │   history.append(out + "Observation: " + obs) │
        │        │                                      │
        │        └─────── 回到 for，带着新 observation   │
        │                                               │
        └─────────────────────────────────────────────┘
```

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
# 这里的 SCRIPT 模拟了一个"已经学会 ReAct 格式"的模型会怎么分步思考。
# 真实场景里，这一段会被替换成：把 prompt+history 发给 LLM，让它自己生成。
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
# 正则说明：Action: 后面跟工具名（\w+），再跟 [ ... ] 里的参数（JSON）。
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

把假 LLM 换成真 LLM 时，`llm.generate(prompt)` 内部改为：把 `prompt + history` 发给 `openai.chat.completions.create(...)`。循环、解析、工具执行这一套**完全不用改**——这就是 ReAct 范式的魅力：推理和执行逻辑是解耦的。你甚至可以做到"模型热插拔"：今天用 GPT-4o，明天换 DeepSeek，Agent 的骨架一行都不用动。这种解耦思维，是你从"会调 API"进阶到"会做系统"的分水岭。

为了让你更进一步体会"循环为什么必要"，我们再加一个**多工具组合**的例子：查 A、B 两地气温并比较。离线脚本只需在 SCRIPT 里多写几步思考即可，框架完全不变——这正是循环架构的可扩展性证明，也预示了"复杂任务能被拆成多步"这一核心能力。

```python
# 扩展：让 Agent 比较两地气温（依然复用同一套 run_react）
SCRIPT2 = [
"""Thought: 我先查北京气温。
Action: get_weather[{"city": "北京"}]""",
"""Thought: 再查上海气温。
Action: get_weather[{"city": "上海"}]""",
"""Thought: 北京 26°C、上海 30°C，上海更热。可以结束了。
Action: Finish[北京 26°C，上海 30°C，上海比北京热 4°C]""",
]
ans2, _ = run_react("北京和上海哪个热？", FakeLLM(SCRIPT2), TOOLS)
print("最终答案:", ans2)
```

你甚至可以想象：如果再加一个 `get_stock_price` 工具，同一个循环就能回答"查腾讯和阿里股价谁高"——**能力的增长只来自"注册新工具"，循环一行都不用改**。这就是 Agent 架构优雅的地方。

### 4.1 让 Agent 学会自我纠错：在循环里加入"反思"

上面的循环能跑通，是因为剧本里每一步都是对的。但真实场景里，模型第一次调用几乎必然会出错：工具名编错、参数写反、把 `"26"` 当字符串传……我们上面用 `obs = f"错误：没有工具 {name}"` 把错误塞回去了，模型看到了确实会改——但这属于"被动纠正"：错误 Observation 进历史，模型自己看着办。

更进一步的工程做法是**把错误提炼成一句"教训"，单独存在一处反思记忆里，并在下一轮思考之前显式塞给模型**，这就是 2023 年提出的 **Reflexion** 范式（"语言 agent 的言语强化学习"）。它的核心洞察非常朴素：**人是从失败里学经验的，Agent 也该如此，而且它的"经验"就是一段自然语言**。下面把它加到我们的循环里，请对照 4 节的基础版看差异在哪：

```python
class ReflectiveLLM(FakeLLM):
    """在每次输出前，先检查历史上积累的教训，有则先反思再行动"""
    def __init__(self, script):
        super().__init__(script)
        self.lessons = []        # 长期反思记忆（真实系统会持久化，跨会话复用）
        self.reflected = 0       # 已经反思过的条数，避免同一句话反复唠叨

    def generate(self, prompt):
        base = super().generate(prompt)
        if len(self.lessons) > self.reflected:          # 只有出现新教训才触发反思
            pending = self.lessons[self.reflected:]
            self.reflected = len(self.lessons)
            return "Reflection: " + "；".join(pending) + "\n" + base
        return base

def run_reflective_react(question, llm, tools, max_steps=6, verbose=True):
    prompt = f"可用工具：{', '.join(tools)}\n\n问题：{question}"
    history = []
    for step in range(1, max_steps + 1):
        out = llm.generate(prompt + "\n" + "\n".join(history))
        if verbose: print(f"\n--- 第 {step} 步 ---\n{out}")
        name, args, raw = parse_action(out)
        if name is None:
            return out
        if name == "Finish":
            return raw or out
        if name not in tools:
            obs = f"错误：没有工具 {name}"
            llm.lessons.append(f"工具 {name} 不存在，请只用 {list(tools)} 里的工具")   # 记录教训
        else:
            try:
                obs = tools[name][1](**args)
            except Exception as e:
                obs = f"错误：{type(e).__name__}: {e}"
                llm.lessons.append(f"调用 {name} 的参数不对：{e}")
        if verbose: print(f"Observation: {obs}")
        history.append(out + f"\nObservation: {obs}")
    return "⚠️ 达到最大步数仍未完成"

SCRIPT_WRONG = [
"""Thought: 我需要先上网搜索北京天气。
Action: search_google[{"q": "北京天气"}]""",                      # 故意幻觉一个不存在的工具
"""Thought: 工具箱里没有 search_google，应该用 get_weather 才对。
Action: get_weather[{"city": "北京"}]""",
"""Thought: 拿到 26°C，现在换算成华氏度。
Action: celsius_to_fahrenheit[{"celsius": 26}]""",
"""Thought: 已经算出 78.8°F，可以给出最终答案了。
Action: Finish[北京今天晴，26°C，约合 78.8°F]""",
]

llm2 = ReflectiveLLM(SCRIPT_WRONG)
ans = run_reflective_react("北京今天多少度？换算成华氏度是多少？", llm2, TOOLS)
print("\n最终答案:", ans)
print("积累的教训:", llm2.lessons)
```

**运行结果**：

```
--- 第 1 步 ---
Thought: 我需要先上网搜索北京天气。
Action: search_google[{"q": "北京天气"}]
Observation: 错误：没有工具 search_google

--- 第 2 步 ---
Reflection: 工具 search_google 不存在，请只用 ['get_weather', 'celsius_to_fahrenheit'] 里的工具
Thought: 工具箱里没有 search_google，应该用 get_weather 才对。
Action: get_weather[{"city": "北京"}]
Observation: 北京：晴，26°C

--- 第 3 步 ---
Thought: 拿到 26°C，现在换算成华氏度。
Action: celsius_to_fahrenheit[{"celsius": 26}]
Observation: 78.8°F

--- 第 4 步 ---
Thought: 已经算出 78.8°F，可以给出最终答案了。
Action: Finish[北京今天晴，26°C，约合 78.8°F]

最终答案: 北京今天晴，26°C，约合 78.8°F
积累的教训: ["工具 search_google 不存在，请只用 ['get_weather', 'celsius_to_fahrenheit'] 里的工具"]
```

请仔细看第 2 步与第 1 步的区别：**犯错→写教训→下一轮带着教训重新思考**，这就是 Reflexion 的全部秘密。你会发现 `Reflection:` 只出现了一次——因为我们用 `self.reflected` 做了去重，同一个教训不重复注入，否则历史里会被同一句话刷屏、白白烧 token。这是我在真实项目里踩出来的经验，请直接抄走。

再往工程上走一步，这段"教训"完全可以**持久化到向量库里**：同一个用户、同类问题再犯时直接召回。你会发现它和阶段 7 的 RAG、以及下一篇要讲的长期记忆，技术上是同一套东西——**它们在 Agent 里统统叫"记忆"，只是存的内容不同**。学习到这个阶段，你应该开始有一种"万法归一"的感觉了。

### 4.2 算一笔账：一次 ReAct 循环到底烧多少钱

Agent 最大的隐性风险不是出错，是**钱**。前面说过循环每次都要把历史重发一遍，这意味着 token 消耗随步数呈**平方级增长**（第 n 步要重发前 n-1 步的所有 observation）。很多团队第一次上线 Agent，月底看见账单都以为被盗刷了。下面把这笔账算清楚，建议你把这段代码收进自己的工具箱，每次设计 Agent 前先估个数：

```python
PRICE = {"gpt-4o-mini": (0.15, 0.60), "某国产模型": (0.07, 0.28)}   # 每百万 token 美元：(输入, 输出)

def estimate_cost(model, sys_tokens, tool_tokens, steps, obs_tokens=200, out_tokens=80, rate=7.2):
    """粗算一轮 ReAct 的成本：每一步都要把 system + 工具说明 + 历史 observation 重发一遍"""
    total_in = 0
    for s in range(1, steps + 1):
        total_in += sys_tokens + tool_tokens + (obs_tokens + out_tokens) * (s - 1)
    total_out = out_tokens * steps
    p_in, p_out = PRICE[model]
    usd = total_in / 1e6 * p_in + total_out / 1e6 * p_out
    return total_in, total_out, round(usd, 6), round(usd * rate, 4)

print(f"{'步数':>4} {'输入token':>10} {'输出token':>10} {'单次(USD)':>12} {'单次(元)':>10}")
for steps in (3, 5, 8, 15):
    ti, to, usd, cny = estimate_cost("gpt-4o-mini", 120, 300, steps)
    print(f"{steps:>4} {ti:>10} {to:>10} {usd:>12.6f} {cny:>10.4f}")

# 日活折算
_, _, _, cny5 = estimate_cost("gpt-4o-mini", 120, 300, 5)
print(f"\n单次 {cny5} 元 × 1000 人 × 5 次 × 30 天 = {round(cny5*1000*5*30, 1)} 元/月")
```

**运行结果**：

```
  步数    输入token    输出token      单次(USD)      单次(元)
   3       2100        240     0.000459     0.0033
   5       4900        400     0.000975     0.0070
   8      11200        640     0.002064     0.0149
  15      35700       1200     0.006075     0.0437

单次 0.007 元 × 1000 人 × 5 次 × 30 天 = 1050.0 元/月
```

（价格为演示假设值，实际以各家官网为准。）

请把注意力放在**增长的斜率**上：步数从 3 涨到 15（5 倍），输入 token 从 2100 涨到 35700（17 倍）。**步数是最贵的资源，不是智能的度量**。由此推出三条立刻能用的工程准则：

1. **工具返回值必须精简**。Observation 每多 100 字，后面每一步都要多付一次这 100 字的钱，而且会被反复发 N 遍。宁可让工具返回结构化的一行关键字段，也不要丢给它一大段原始 HTML。
2. **`max_steps` 必须设，且要小**。一个设计良好的 Agent，绝大多数任务 3~5 步就能收敛。如果经常跑满 8 步，大概率是提示词没写清"何时该 Finish"，或者该拆分任务了。
3. **给贵的步骤配便宜的模型**。比如"决定调哪个工具"这种简单路由，用一个小模型就够；只有真正需要推理的那一步才请出大模型。这条思想在生产里叫 **模型分层（model routing）**，是所有 Agent 团队省钱的第一招。

把这三条记住，你已经比大多数"上线后才发现账单爆了"的团队提前规避了一个大坑。

## 五、四个"坑"，新手 90% 会踩

Agent 看起来简单，真跑起来坑特别多。下面这些是我和无数初学者一起踩过的，提前知道能省你至少三天调试时间。

### 坑 1：模型输出解析失败（循环卡死）

模型不一定每次都严格按 `Action: xxx[...]` 输出。它可能写 `Action: get_weather(北京)`（用了圆括号而不是 JSON 方括号），或者写 `Action: get_weather` 后面忘了参数，又或者在 Action 前后加了一大堆解释文字（"我决定调用 get_weather 工具，参数是北京"）。你的正则 `parse_action` 一旦 match 不到，就返回 `None`，按我们的代码是直接当答案返回——于是用户看到一堆没用的思考过程，任务却没完成。

**对策**：
- 解析用正则（如上），宽松匹配，必要时先用 `re.search` 兜底而非 `re.match`，并容忍 Action 行前后的噪声文字；
- 给模型清晰的 few-shot 示例（阶段 6 的 6-1 讲过 few-shot 的重要性），把标准格式示范给它看，最好给 2~3 个例子；
- 解析失败时，**把"请严格按 Action: 工具名[{"参数":值}] 格式输出"作为 Observation 回喂**，让模型重试。这一步体现了"观察→反思"的价值：模型看到自己格式错了，下一轮通常会自我纠正。这就是 Agent 比一次性调用鲁棒的根本原因——它能从错误里恢复。

### 坑 2：工具不存在 / 参数错误（幻觉工具）

模型可能编一个 `Action: search_google[...]`，而你的工具箱里根本没有它；或传了错误的参数名（比如上一节的 `celsius_to_fahrenheit({"celsius": 26})`，若函数签名是 `(c)` 就会 `TypeError`）；更隐蔽的是参数类型错（传了字符串 `"26"` 而函数要数字，导致 `float("26")` 虽能过但下游出错）。

**对策**：本代码已经做了两层保护——先判断 `name not in tools`，再 `try/except` 捕获参数错误。把**错误 Observation 回喂给模型**，它通常会自我纠正（"啊，应该这样调"）。生产环境建议再加一层：把工具签名（参数名、类型）直接写进 prompt，并在解析后用 pydantic 之类的库做参数校验，错得离谱就直接拒掉，避免把脏参数送进工具引发更深处崩溃。

### 坑 3：死循环（不收敛）

模型反复调用同一个工具，或者 A→B→A→B 来回横跳，永远不 `Finish`。我曾见过一个 Agent 因为 prompt 里没说清楚"何时结束"，连续调了同一工具 30 次，账单直接爆掉。

**对策**：必须设 `max_steps`（上例是 5）。超出就强制终止并返回中间结果，同时告诉用户"任务未完成，请简化问题或补充工具"。阶段 6 的 6-4 也讲过，每次 LLM 调用都算 token，**无限循环 = 无限烧钱**。更进阶的做法是引入"反思"步骤（Reflexion 范式）：让模型在超过 N 步后停下来自己总结"我是不是走偏了"，再决定继续还是放弃。

### 坑 4（补充）：工具返回太大，撑爆上下文

有些工具（比如"读整个文件""查数据库返回一万行"）会把巨量文本塞进 Observation，下一轮 prompt 瞬间爆掉上下文窗口，模型开始胡言乱语。

**对策**：工具层做裁剪/摘要，只返回模型需要的字段；数据库查询强制 `LIMIT`；文件读取只取相关片段。永远假设"工具会返回过多数据"，在工具边界就做好节流。这也是为什么很多生产 Agent 会给每个工具写一个"结果后处理"函数。

## 六、把视角拉高：ReAct 和 RAG 怎么配合？

其实你在 7-4 写的 RAG 检索函数，完全可以注册成 Agent 的一个工具，这是把前面所有知识串起来的关键一步：

```
TOOLS = {
    "rag_search":   ("在知识库里检索资料，参数 query",  rag_pipeline.answer),
    "get_weather":  ("查询天气",                         get_weather),
    ...
}
```

这样一个 Agent 既能"查知识库"，又能"查实时天气"，还能"算单位换算"——**它自己决定什么时候该用哪个**。

把上面这段思路落成**能直接运行的代码**（这里用一个内置的小词典模拟真实知识库，换成 7-4 的检索函数即可）：

```python
def rag_search(query: str) -> str:
    """在公司知识库里检索制度/产品文档片段。参数 query 是自然语言检索词。"""
    CORPUS = {
        "退款": "无理由退款需在签收后 7 天内申请，运费由买家承担。",
        "报销": "差旅报销需在行程结束后 30 天内提交，并附发票原件。",
        "考勤": "弹性工作制，每天在岗满 8 小时即可，午休不计入工时。",
    }
    hits = [v for k, v in CORPUS.items() if k in query]
    return "\n".join(hits) if hits else "未在知识库中检索到相关内容"

TOOLS2 = dict(TOOLS)                                   # 复用 4 节已有的工具，不重复造轮子
TOOLS2["rag_search"] = ("在知识库检索制度文档，参数 query", rag_search)

SCRIPT3 = [
'Thought: 用户问的是公司退款政策，这类事实必须查知识库，不能凭记忆猜。\nAction: rag_search[{"query": "退款"}]',
'Thought: 检索到"签收后 7 天内申请"，可以直接作答了。\nAction: Finish[无理由退款需在签收后 7 天内申请，运费由买家承担。]',
]
print("\n最终答案:", run_reflective_react("公司无理由退款要几天内申请？", FakeLLM(SCRIPT3), TOOLS2, max_steps=4, verbose=True))
```

**运行结果**：

```
--- 第 1 步 ---
Thought: 用户问的是公司退款政策，这类事实必须查知识库，不能凭记忆猜。
Action: rag_search[{"query": "退款"}]
Observation: 无理由退款需在签收后 7 天内申请，运费由买家承担。

--- 第 2 步 ---
Thought: 检索到"签收后 7 天内申请"，可以直接作答了。
Action: Finish[无理由退款需在签收后 7 天内申请，运费由买家承担。]

最终答案: 无理由退款需在签收后 7 天内申请，运费由买家承担。
```

看清楚这次的价值所在：答案是**逐字来自知识库原文**的，模型没有贡献任何"记忆里的事实"，它只贡献了一件事——**判断该去查**。这就是 Agent 与 RAG 结合后最迷人的性质：**事实的可靠性由检索保证，行为的智能性由模型保证，两者互不干扰**。对企业场景来说，这几乎是可落地 AI 的唯一正确形态——因为你终于可以理直气壮地说"这个答案不会编"。这比单独的 RAG 强在：用户问题可以是多轮的、跨工具的、需要组合结果的。比如用户问"我们公司退款政策里，无理由退款要几天？今天气温适不适合出门？"——单一 RAG 答不了第二问，单一天气工具答不了第一问，而 Agent 把两者编排起来就轻松搞定。这就是智能体的起点，也是阶段 8 后面几篇要展开的全部基础。某种意义上，RAG 是 Agent 的一个"知识型工具"，而 Agent 是 RAG 的"调度大脑"——二者是共生关系，不是替代关系。

## 七、对比：普通调用 vs ReAct Agent vs 框架 Agent

为了让你看清技术演进的脉络，把三种形态放一起比一比，建议收藏这张表：

| 维度 | 普通 LLM 调用 | 手写 ReAct | 框架 Agent（下篇） |
|---|---|---|---|
| 能否调工具 | 否（靠猜） | 能 | 能 |
| 是否需要循环 | 否 | 是（手写 while） | 是（框架托管） |
| 工具定义方式 | 无 | 手写字典 | `@tool` 装饰器 |
| 出错处理 | 无 | 手写 try/except | 框架内置 |
| 学习成本 | 低 | 中（要懂原理） | 中（要懂 API） |
| 灵活度 | — | 最高（想改哪改哪） | 受框架约束 |
| 可观测性 | 无 | 自己打日志 | 框架提供回调 |
| 适合 | 简单问答 | 学习原理、极致定制 | 上线产品 |

记住：**手写 ReAct 不是"落后的做法"，而是"理解框架的前提"**。下一篇你看到 LangChain 的 `AgentExecutor`，会发现它内部和我们这 160 行代码是同一回事，只不过多了一堆工程化包装。

## 八、本节小结

1. **Agent ≠ 新模型**，它是"大模型 + 工具 + 循环"的组合体；价值在于把"可能记错的事实"交给工具，把"怎么组合推理"交给模型，从而打通"推理—真实世界"的闭环。
2. **ReAct 范式**：`Thought → Action → Observation` 反复循环，直到模型输出 `Finish`。`Observation` 是真实工具返回值，由代码填入，绝不让模型代笔，是连接真实世界的接口。
3. 我们手写的离线版已经跑通：查天气 → 单位换算 → 输出答案，**三步自动完成，零幻觉**；并且验证了"模型热插拔"与"能力靠加工具扩展"两大特性。
4. 四大坑：解析失败、幻觉工具、死循环、工具返回过大——都有对策（正则解析 + 错误回喂 + max_steps 上限 + 工具层节流）。
5. **Agent 与 RAG 不是替代关系**：RAG 检索函数可以注册成 Agent 的一个工具，二者协作威力最大——事实由检索保证，智能由模型保证。
6. **Reflexion 是循环的纠错升级**：把失败提炼成一句"教训"存进反思记忆，下一轮先反思再行动，同一个教训只注入一次。
7. **步数是成本的第一变量**：输入 token 随步数平方级增长，压缩 Observation、收紧 `max_steps`、贵贱模型分层，是省钱三板斧。

最后送一句心法收尾：**写 Agent 时，你要管的从来不是"模型怎么想"，而是"模型能看到什么、能碰到什么、什么时候必须停下来"。** 把这三点管好，模型的能力会自然流淌出来；管不好，再强的模型也会在你的循环里迷路。

## 九、实战练习（可验证小任务）

下面几个任务你都能在本地跑出来，建议逐个做一遍，做完才算真正吃透：

1. **基础改造**：把本文的 `SCRIPT` 改成"先查上海天气，再换算"的两步剧本，运行确认输出正确。验证点：Observation 是否依次是上海气温和华氏值。
2. **加新工具**：新增一个 `multiply(a, b)` 工具（返回两数乘积），并写一段 SCRIPT 让 Agent 先查北京气温（26），再乘以 2。验证点：最终答案应为 52。
3. **故意触发坑 2**：在 SCRIPT 里写 `Action: not_exist_tool[{"x":1}]`，观察程序是否返回"错误：没有工具 not_exist_tool"而非崩溃。
4. **触发死循环防护**：把 SCRIPT 写成永远不出现 `Finish` 的五步循环（可重复同一句 Action），运行确认第 5 步后返回"⚠️ 达到最大步数仍未完成"。
5. **进阶（接真模型）**：把 `FakeLLM` 换成调用 OpenAI/DeepSeek 的真实客户端，prompt 里加上工具说明和 few-shot 示例，跑通真实 ReAct。这一步做完，你就拥有了一个能联网干活的 Agent 雏形。
6. **反思机制验证**：给 `SCRIPT_WRONG` 再加一步"参数写错"（比如 `celsius_to_fahrenheit[{" Celsius": 26}]`），运行确认 `llm2.lessons` 里会多出一条参数相关的教训，且这条教训只被注入一次。验证点：理解"去重注入"为什么能省 token。
7. **成本敏感度实验**：把 4.2 里的 `obs_tokens` 从 200 改成 800（模拟工具返回一大坨文本），重新跑一遍，观察 8 步时的输入 token 从多少涨到多少。验证点：亲眼建立"工具返回值必须精简"的直觉。
8. **Function Calling 改造**：不用改 `run_reflective_react` 的循环，只把 3.1 里那段 `tools` JSON Schema 传给 DeepSeek/OpenAI，并把返回的 `tool_calls[0].function.arguments` 用 `json.loads` 解成 dict 后送进 `tools[name][1](**args)`。验证点：证明"换协议不用换骨架"。

## 十、延伸阅读与下一步

- **论文**：*ReAct: Synergizing Reasoning and Acting in Language Models*（Yao et al., 2022）——ReAct 的源头，建议读它的 Figure 1，对比"只有推理"和"推理+行动"的效果差异，你会直观看到 Action 带来的准确率提升。
- **论文**：*Reflexion: Language Agents with Verbal Reinforcement Learning*（Shinn et al., 2023）——在 ReAct 基础上加了"失败后反思"机制，是坑 3 死循环的高级解法。
- **概念**：Tool Learning / Function Calling——OpenAI 的 function calling 机制与 ReAct 的关系（本质是用模型原生能力替代正则解析 Action，更稳，生产首选）。
- **下一步**：下一篇 **8-2《工具调用框架——LangChain 与 LlamaIndex 入门》** 会带你用框架把"工具定义、循环、异常"标准化，从此告别手写胶水代码；再之后 8-3 讲记忆，让你的 Agent 不再"转头就忘"。

> 本篇是《大模型开发从 0 到 1》专栏第 42 篇，阶段 8「Agent 智能体开发」第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
