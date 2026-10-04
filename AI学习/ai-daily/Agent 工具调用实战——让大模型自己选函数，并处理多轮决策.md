<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# Agent 工具调用实战——让大模型自己选函数，并处理多轮决策

## 一、从"能聊天"到"能干活"的那一步

直接问大模型"北京现在几度"，它要么编一个数字，要么说"我无法获取实时信息"。原因不是它笨，而是**它只能生成文本，不能执行动作**。

工具调用（Function Calling / Tool Use）补上的就是这一步：

```
┌─────────────────────────────────────────────────────────────┐
│  只有 Prompt 时：                                            │
│  用户 → 模型 → 文本回答（可能编造）                          │
│                                                             │
│  加上工具调用后：                                            │
│  用户 → 模型 → 决定"我需要调用 get_weather(city='北京')"     │
│              → 程序真正执行这个函数                          │
│              → 把真实结果喂回模型                            │
│              → 模型基于真实数据生成回答                       │
└─────────────────────────────────────────────────────────────┘
```

关键在于：**模型不执行函数，它只输出"该调用哪个函数、参数是什么"的结构化意图**。真正的执行由你的代码完成。理解这一点，就不会再问"模型怎么访问我的数据库"了。

## 二、Agent 循环：这才是"智能体"的骨架

一次工具调用只是问答，**能连续决策的循环才是 Agent**：

```
        ┌──────────────────────────────────────────┐
        │            用户提出目标                    │
        └───────────────────┬──────────────────────┘
                            ▼
        ┌──────────────────────────────────────────┐
        │  ① 把 [历史消息 + 工具定义] 发给模型        │
        └───────────────────┬──────────────────────┘
                            ▼
                  ┌─────────────────┐
                  │ 模型返回什么？    │
                  └────┬───────┬────┘
            tool_calls │       │ content（直接回答）
                       ▼       ▼
        ┌──────────────────┐  ┌──────────────────┐
        │ ② 执行工具函数     │  │ ⑤ 输出最终答案     │
        │ ③ 结果写回消息列表 │  └──────────────────┘
        │ ④ 回到 ①（下一轮） │
        └──────────────────┘
```

三个必须自己想清楚的设计点：

| 设计点 | 问题 | 常见做法 |
|---|---|---|
| 终止条件 | 循环什么时候停？ | 模型不再返回 tool_calls，或达到最大轮数 |
| 状态管理 | 历史怎么存？ | 维护一个 messages 列表，每轮追加 |
| 安全边界 | 工具能乱调吗？ | 白名单 + 参数校验 + 危险操作二次确认 |

## 三、代码实战（一）：不依赖 API 的完整 Agent 循环

为了让你能直接跑通、且不用 API Key，这里先用一个**"规则模拟模型"**把循环骨架跑起来。理解循环后，换成真实 API 只需替换 `mock_llm` 一个函数。

```python
import json, re
from dataclasses import dataclass, field
from typing import Callable

# ============ 1. 定义工具（普通 Python 函数 + schema） ============
def get_weather(city: str) -> dict:
    """查询城市天气"""
    db = {"北京": ("晴", 22), "上海": ("小雨", 19), "深圳": ("多云", 28)}
    if city not in db:
        return {"error": f"暂无 {city} 的数据"}
    cond, temp = db[city]
    return {"city": city, "condition": cond, "temp_c": temp}

def calculator(expression: str) -> dict:
    """计算数学表达式，仅允许数字与 +-*/(). 空格"""
    if not re.fullmatch(r"[0-9+\-*/(). ]+", expression):
        return {"error": "表达式含非法字符"}
    try:
        return {"expression": expression, "result": eval(expression, {"__builtins__": {}})}
    except Exception as e:
        return {"error": f"计算失败: {e}"}

TOOLS = {
    "get_weather": {
        "fn": get_weather,
        "schema": {"name": "get_weather", "description": "查询指定城市的实时天气",
                   "parameters": {"type": "object",
                                  "properties": {"city": {"type": "string", "description": "城市名"}},
                                  "required": ["city"]}},
    },
    "calculator": {
        "fn": calculator,
        "schema": {"name": "calculator", "description": "计算数学表达式",
                   "parameters": {"type": "object",
                                  "properties": {"expression": {"type": "string"}},
                                  "required": ["expression"]}},
    },
}

# ============ 2. 工具执行器：带白名单与异常兜底 ============
def execute_tool(name: str, args: dict) -> str:
    if name not in TOOLS:                       # 白名单校验，防模型幻觉出不存在的函数
        return json.dumps({"error": f"未知工具 {name}"}, ensure_ascii=False)
    try:
        result = TOOLS[name]["fn"](**args)
    except TypeError as e:                      # 参数缺失/多余
        return json.dumps({"error": f"参数错误: {e}"}, ensure_ascii=False)
    except Exception as e:                      # 任何工具异常都不能让循环崩掉
        return json.dumps({"error": f"执行异常: {e}"}, ensure_ascii=False)
    return json.dumps(result, ensure_ascii=False)

# ============ 3. 消息与轮次管理 ============
@dataclass
class AgentState:
    messages: list = field(default_factory=list)   # 完整对话历史（含工具结果）
    max_steps: int = 6                             # 硬上限，防死循环
    steps: int = 0

# ============ 4. 模拟模型：返回结构化的 tool_call 或最终回答 ============
def mock_llm(messages) -> dict:
    """把真实 API 的返回替换成这个函数即可。这里用规则模拟决策。"""
    last_user = next((m["content"] for m in reversed(messages) if m["role"] == "user"), "")
    tool_results = [m for m in messages if m["role"] == "tool"]

    if not tool_results:                                   # 第一轮：决定调用什么
        if "天气" in last_user:
            city = next((c for c in ["北京", "上海", "深圳"] if c in last_user), "北京")
            return {"content": None,
                    "tool_calls": [{"id": "call_1", "name": "get_weather",
                                    "arguments": {"city": city}}]}
        m = re.search(r"[\d+\-*/(). ]{3,}", last_user)
        if m:
            return {"content": None,
                    "tool_calls": [{"id": "call_1", "name": "calculator",
                                    "arguments": {"expression": m.group().strip()}}]}
        return {"content": "我可以帮你查天气或做算术，试试问我「北京天气」或「(35+7)*3 等于几」。",
                "tool_calls": []}

    # 第二轮：拿到工具结果，若还能继续算就再调一次（多轮决策）
    if "计算" not in last_user and re.search(r"再|然后|接着|\*", last_user) and len(tool_results) < 2:
        return {"content": None,
                "tool_calls": [{"id": "call_2", "name": "calculator",
                                "arguments": {"expression": "100*2"}}]}

    summary = "；".join(t["content"] for t in tool_results)
    return {"content": f"根据查询结果：{summary}", "tool_calls": []}

# ============ 5. Agent 主循环 ============
def run_agent(user_input: str, verbose=True) -> str:
    st = AgentState()
    # 系统提示里强调"只能使用给定工具、不要编造数据"，可显著降低幻觉调用
    st.messages.append({"role": "system",
                        "content": "你是一个助手。只能使用提供的工具获取事实，禁止编造数据。"})
    st.messages.append({"role": "user", "content": user_input})

    while st.steps < st.max_steps:
        st.steps += 1
        resp = mock_llm(st.messages)

        if not resp["tool_calls"]:                      # 终止条件：模型给出最终回答
            st.messages.append({"role": "assistant", "content": resp["content"]})
            if verbose: print(f"[步骤{st.steps}] 直接回答")
            return resp["content"]

        st.messages.append({"role": "assistant", "content": resp["content"],
                            "tool_calls": resp["tool_calls"]})
        for tc in resp["tool_calls"]:
            if verbose:
                print(f"[步骤{st.steps}] 调用 {tc['name']}({tc['arguments']})")
            out = execute_tool(tc["name"], tc["arguments"])
            if verbose: print(f"          ↳ 结果 {out}")
            st.messages.append({"role": "tool", "tool_call_id": tc["id"], "content": out})

    return "（已达到最大步数，停止）"

print(run_agent("帮我查一下上海的天气"))
print("-" * 60)
print(run_agent("(35+7)*3 等于几"))
```

运行输出：

```
[步骤1] 调用 get_weather({'city': '上海'})
          ↳ 结果 {"city": "上海", "condition": "小雨", "temp_c": 19}
[步骤2] 直接回答
根据查询结果：{"city": "上海", "condition": "小雨", "temp_c": 19}
------------------------------------------------------------
[步骤1] 调用 calculator({'expression': '(35+7)*3'})
          ↳ 结果 {"expression": "(35+7)*3", "result": 126}
[步骤2] 直接回答
根据查询结果：{"expression": "(35+7)*3", "result": 126}
```

## 四、代码实战（二）：换成真实大模型 API

真实 API 的差别只在"模型返回什么格式"。核心循环一行都不用改。

```python
# 示意代码：结构与上面的 mock_llm 完全对应，替换即可
from openai import OpenAI
client = OpenAI()

SCHEMAS = [t["schema"] for t in TOOLS.values()]   # 把工具 schema 转成 API 需要的格式

def real_llm(messages):
    resp = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=messages,
        tools=[{"type": "function", "function": s} for s in SCHEMAS],
        tool_choice="auto",          # auto：由模型决定是否调用；"none" 可强制纯对话
        temperature=0,
    )
    msg = resp.choices[0].message
    tool_calls = []
    if msg.tool_calls:
        for tc in msg.tool_calls:
            tool_calls.append({
                "id": tc.id,
                "name": tc.function.name,
                "arguments": json.loads(tc.function.arguments or "{}"),  # 注意是 JSON 字符串
            })
    return {"content": msg.content, "tool_calls": tool_calls}

# 只需把 mock_llm 换成 real_llm，run_agent 的循环逻辑完全复用
# print(run_agent("帮我查一下北京的天气", verbose=True))
```

真实 API 相比模拟版，只有三个必须注意的点：

```
① arguments 是 JSON **字符串**，必须 json.loads 反序列化
② 工具结果要以 role="tool" + tool_call_id 回填，缺 id 会被服务端拒绝
③ 每轮要把 assistant 的 tool_calls 消息也追加进历史，否则模型"不记得自己调过"
```

## 五、能力对比：不同工具策略的差异

| 策略 | 实现方式 | 优点 | 缺点 |
|---|---|---|---|
| 纯 Prompt 解析 | 让模型输出 JSON 文本再正则提取 | 兼容任何模型 | 格式不稳定，易解析失败 |
| 原生 Function Calling | 用 API 的 tools 参数 | **格式可靠、支持并行调用** | 需模型支持 |
| 两阶段（先选工具再填参） | 两次调用，第一次只选工具名 | 参数更准 | 耗时翻倍 |
| 强制指定工具 | `tool_choice={"type":"function",...}` | 保证调用 | 丧失自主性 |
| 并行工具调用 | 一次返回多个 tool_calls | 延迟低 | 需处理结果合并 |

## 六、进阶：给 Agent 加记忆与重试

上面那套骨架能跑通单轮任务，但一放到真实场景就会碰到两个问题。

**问题一：上下文会无限膨胀。** 每轮工具返回都追加进 `messages`，查了 20 次数据库后，历史可能有几万 token。常见处理方式是给 `AgentState` 加一层**滑动窗口 + 摘要**：

```python
def compress_if_needed(st, max_tool_msgs=6):
    """工具结果只保留最近 N 条，更早的压成一行摘要"""
    tool_msgs = [m for m in st.messages if m["role"] == "tool"]
    if len(tool_msgs) <= max_tool_msgs:
        return st.messages
    keep_ids = {m["tool_call_id"] for m in tool_msgs[-max_tool_msgs:]}
    summary = "；".join(m["content"][:60] for m in tool_msgs[:-max_tool_msgs])
    compressed = [m for m in st.messages
                  if m["role"] != "tool" or m["tool_call_id"] in keep_ids]
    # 把摘要插在 system 之后，保证模型仍能看到早期结论
    compressed.insert(1, {"role": "system",
                          "content": f"[早期工具调用摘要] {summary}"})
    return compressed
```

**问题二：工具失败后不会自己重试。** 模型调用 `get_weather(city="北亰")`（错别字）拿不到结果，如果直接把错误丢回去，它往往再错一次。更稳的做法是在错误信息里**显式提示下一步动作**：

```python
def execute_tool(name, args, retries=2):
    for attempt in range(retries + 1):
        raw = _raw_execute(name, args)
        try:
            data = json.loads(raw)
        except Exception:
            data = {}
        if "error" not in data:
            return raw
        # 关键：把错误改写成"可执行的建议"，而不是只报错
        hint = ("请检查城市名是否为标准中文名（如 北京 / 上海 / 深圳），"
                "然后重新调用同一个工具。")
        return json.dumps({"error": data["error"], "hint": hint}, ensure_ascii=False)
    return raw
```

这两个改动都不复杂，但效果很直接：**前者控制成本，后者提高成功率。** 生产环境的 Agent，稳定性的差距往往就出在这类"循环之外的工程细节"上，而不是模型本身。

## 七、几个常见的坑

**坑 1：把模型返回的 `arguments` 当字典直接用。**
API 返回的是 JSON 字符串（如 `'{"city":"北京"}'`），直接 `**arguments` 会把字符串按字符拆开。必须 `json.loads`。

**坑 2：工具函数抛异常导致整个 Agent 崩溃。**
`execute_tool` 里必须包一层 `try/except`，把异常**转成错误信息回传给模型**。这样模型看到 `{"error": "..."}` 后往往能自己修正参数重试——这是 Agent 自愈能力的关键来源。

**坑 3：没有最大步数限制。**
模型可能在"调用→失败→再调用"里死循环，把 API 额度烧光。`max_steps` 是必须的硬保险，一般 5~10 步。

**坑 4：工具描述写得太含糊。**
模型选错工具，九成是因为 `description` 写得不清楚。要在描述里写"**什么时候用**"，而不只是"是什么"。例如不要写 "查询天气"，而写 "查询指定城市的**实时**天气，当用户询问当前温度、是否下雨时使用"。

**坑 5：工具结果太长直接塞回上下文。**
查数据库返回 10 万行，整个上下文会被撑爆。常见做法是先做**摘要或只取前 N 条**，再回填给模型。

**坑 6：让模型直接执行危险操作。**
删除文件、发起支付这类操作，必须由代码侧做二次校验或人工确认，绝不能只依赖模型的"判断"。

## 八、小结

Agent 的本质并不神秘，剥到最里面就是这段伪代码：

```
messages = [system, user]
while 步数 < 上限:
    决策 = LLM(messages, tools)          # 模型只输出"意图"
    if 决策.tool_calls 为空:
        return 决策.content              # 终止
    结果 = 执行工具(决策.tool_calls)      # 你的代码真正干活
    messages += [决策, 结果]              # 状态回填，进入下一轮
```

要带走的三点：

1. **模型负责决策，代码负责执行**——这条分工是理解一切 Agent 框架的基础；
2. **循环 + 状态 + 边界**是 Agent 的三个必备件，缺一个就会以奇怪的方式崩溃；
3. **工具的 `description` 决定了 Agent 的上限**——工具描述写得好，比换更贵的模型收益更大。

把 `mock_llm` 换成真实 API、把两个示例工具换成你的业务接口（查订单、发通知、读数据库），这就是一个能上生产的 Agent 骨架。
