<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# Function Calling——让大模型调用你的函数

**承上**：上一篇我们封装了能聊天、能流式输出、能统计成本的客户端。但它有个根本限制——**只能说，不能做**。它不知道今天的天气，查不了你的订单数据库，也算不准实时汇率（它只是背过类似的文本）。

**本篇**：打通"说"与"做"之间的链路。你会学到如何用 **JSON Schema 描述工具**、模型如何**自主决定调用哪个工具、传什么参数**，以及最关键的——**完整的调用循环**怎么写。最后我们用一个**可离线运行的模拟器**把整条链路跑通。

**启下**：你会立刻发现一个现实问题：工具调用是**多轮**的，每一轮都要把全部历史再发一遍，几轮下来 token 和费用直线上升。下一篇《上下文管理与成本控制》解决这件事。

**学完这一节，你能动手做**：

1. 用 JSON Schema 定义工具，让模型自己选择并填对参数
2. 写出完整的「模型 → 工具 → 回填 → 再回答」循环
3. 加上参数校验、白名单与最大轮数，让它在生产环境里不会失控

---

## 一、Function Calling 到底发生了什么？

一个常见误解是"模型会执行函数"。**不会**。真实流程是：

```
① 你告诉模型：你有这些工具（只发"说明书"，不发代码）
        ↓
② 模型判断：这个问题需要查天气
        ↓
③ 模型返回：请调用 get_weather(city="北京")    ← 它只输出"调用意图"
        ↓
④ 【你的代码】真正执行这个函数，拿到结果
        ↓
⑤ 你把结果作为一条 tool 消息塞回对话历史
        ↓
⑥ 模型看到结果，生成最终回答
```

**模型全程只是在"说话"——它说"我想调用这个函数"，真正执行的是你的程序。** 这是理解 Function Calling 的第一要点，也解释了为什么它是安全的（模型碰不到你的系统）。

## 二、工具说明书：JSON Schema

你用一段 JSON 描述每个工具：名字、用途、参数类型、必填项。**描述写得好不好，直接决定模型会不会用对**。

```python
tools = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "查询指定城市的当前天气。当用户询问天气、气温、是否下雨时使用。",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {"type": "string", "description": "城市名称，如「北京」「上海」"},
                    "unit": {"type": "string", "enum": ["celsius", "fahrenheit"],
                             "description": "温度单位，默认 celsius"},
                },
                "required": ["city"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "calculate",
            "description": "计算数学表达式。只支持加减乘除、括号与小数，不要用它做字符串处理。",
            "parameters": {
                "type": "object",
                "properties": {
                    "expression": {"type": "string",
                                   "description": "数学表达式，如 '(12 + 8) * 3.5'"},
                },
                "required": ["expression"],
            },
        },
    },
]
```

**写 description 的三条经验**：

1. **说清"什么时候用"**，而不只是"这个工具干什么"（`当用户询问天气…时使用`）；
2. **说清边界**（`不要用它做字符串处理`），避免模型乱调；
3. **枚举值要用 `enum`**，比在描述里写"只能是 A 或 B"更可靠。

## 三、代码实战 1：完整的调用循环（可离线运行）

为了让这段代码**不需要 API Key 也能跑通**，我把模型替换成一个模拟器。真实项目中把 `FakeLLM` 换成 `client.chat.completions.create` 即可，其余代码完全不用改。

```python
import json
from typing import Callable

# ---------- 1. 真实的业务函数（你的代码） ----------
def get_weather(city: str, unit: str = "celsius") -> str:
    db = {"北京": "晴，26°C，湿度 40%", "上海": "多云，29°C，湿度 70%"}
    return db.get(city, f"{city}：暂无数据")

def calculate(expression: str) -> str:
    if any(ch in expression for ch in ["import", "eval", "__", ";"]):
        return "错误：表达式含非法字符"
    try:
        return str(eval(expression, {"__builtins__": {}}, {}))   # 见下方安全说明
    except Exception as e:
        return f"计算失败：{e}"

# ---------- 2. 工具注册表：名字 → 函数 ----------
TOOL_REGISTRY: dict[str, Callable] = {
    "get_weather": get_weather,
    "calculate": calculate,
}

# ---------- 3. 执行单次工具调用 ----------
def execute_tool(name: str, arguments: str) -> str:
    if name not in TOOL_REGISTRY:
        return f"错误：未注册的工具 {name}"
    try:
        kwargs = json.loads(arguments) if arguments else {}
    except json.JSONDecodeError:
        return f"错误：参数不是合法 JSON - {arguments}"
    try:
        return str(TOOL_REGISTRY[name](**kwargs))
    except TypeError as e:                      # 参数名/个数对不上
        return f"错误：参数不匹配 - {e}"
    except Exception as e:
        return f"错误：执行异常 - {e}"

# ---------- 4. 模拟模型（真实项目换成 OpenAI 调用） ----------
class FakeLLM:
    """按剧本返回 tool_calls，用于离线跑通整条链路。"""
    def __init__(self, script):
        self.script, self.i = script, 0
    def chat(self, messages, tools=None):
        step = self.script[min(self.i, len(self.script) - 1)]
        self.i += 1
        return step

# 剧本：第 1 轮要查天气 → 第 2 轮给出最终回答
script = [
    {"tool_calls": [{"id": "call_1",
                     "function": {"name": "get_weather",
                                  "arguments": '{"city": "北京"}'}}]},
    {"content": "北京今天晴，26°C，湿度 40%，适合出门。"},
]

TOOLS = [
    {"type": "function", "function": {
        "name": "get_weather",
        "description": "查询指定城市的当前天气。",
        "parameters": {"type": "object",
                       "properties": {"city": {"type": "string"},
                                      "unit": {"type": "string",
                                               "enum": ["celsius", "fahrenheit"]}},
                       "required": ["city"]}}},
    {"type": "function", "function": {
        "name": "calculate",
        "description": "计算数学表达式。",
        "parameters": {"type": "object",
                       "properties": {"expression": {"type": "string"}},
                       "required": ["expression"]}}},
]

# ---------- 5. 核心：完整的多轮调用循环 ----------
def run_agent(llm, user_query: str, max_turns: int = 5) -> str:
    messages = [{"role": "user", "content": user_query}]

    for turn in range(1, max_turns + 1):
        resp = llm.chat(messages, tools=TOOLS)

        # 情况 A：模型不再需要工具 → 直接返回最终答案
        if "content" in resp:
            return resp["content"]

        # 情况 B：模型要求调用工具
        messages.append({"role": "assistant", "tool_calls": resp["tool_calls"]})
        for call in resp["tool_calls"]:
            name = call["function"]["name"]
            args = call["function"]["arguments"]
            print(f"  [第 {turn} 轮] 调用 {name}({args})")
            result = execute_tool(name, args)
            print(f"  [第 {turn} 轮] 结果 -> {result}")
            # 关键：把结果以 tool 角色回填，并用 tool_call_id 关联
            messages.append({
                "role": "tool",
                "tool_call_id": call["id"],
                "content": result,
            })

    return "⚠️ 已达到最大轮数仍未得出答案"

answer = run_agent(FakeLLM(script), "北京今天天气怎么样？")
print("\n最终回答:", answer)
```

运行结果：

```
  [第 1 轮] 调用 get_weather({"city": "北京"})
  [第 1 轮] 结果 -> 晴，26°C，湿度 40%

最终回答: 北京今天晴，26°C，湿度 40%，适合出门。
```

**换成真实模型只需要改两处**：

```python
# 1) llm.chat 换成真实调用
resp = client.chat.completions.create(
    model="deepseek-chat",
    messages=messages,
    tools=TOOLS,            # 传工具说明书
    tool_choice="auto",     # auto=模型自己决定；也可强制指定或 "none"
)

# 2) 判断是否要调工具
msg = resp.choices[0].message
if msg.tool_calls:
    # 转成循环里用的结构
    ...
else:
    return msg.content
```

### 消息历史的结构（这是最容易写错的地方）

```
user        : "北京今天天气怎么样？"
assistant   : tool_calls=[{id: call_1, get_weather, {"city":"北京"}}]   ← 模型的"意图"
tool        : {tool_call_id: "call_1", content: "晴，26°C"}             ← 你的执行结果
assistant   : "北京今天晴，26°C，适合出门。"                              ← 最终回答
```

三条规则：

1. `assistant` 消息里带 `tool_calls` 时，`content` 可以为 `None`；
2. 每条 `tool` 消息必须用 **`tool_call_id` 与对应的调用关联**（并行调用多个工具时尤其重要）；
3. **工具结果必须全部回填后再请求**，否则模型会抱怨"缺少 tool 消息"。

## 四、代码实战 2：生产环境的三道保险

Function Calling 最大的风险是**失控**：模型传错参数、反复调用、甚至死循环。这三道保险必须加。

```python
import json

ALLOWED_TOOLS = {"get_weather", "calculate"}        # 保险①：白名单

def safe_execute(call: dict) -> str:
    name = call["function"]["name"]
    # ① 白名单：绝不允许调用未注册的工具
    if name not in ALLOWED_TOOLS or name not in TOOL_REGISTRY:
        return f"错误：工具 {name} 未被授权"

    # ② 参数校验：用 schema 检查必填项与类型
    schema = next(t for t in TOOLS if t["function"]["name"] == name)["function"]["parameters"]
    try:
        kwargs = json.loads(call["function"]["arguments"] or "{}")
    except json.JSONDecodeError:
        return "错误：参数不是合法 JSON"
    for req in schema.get("required", []):
        if req not in kwargs:
            return f"错误：缺少必填参数 {req}"

    # ③ 执行并兜住所有异常，绝不让异常冒泡崩掉整个对话
    try:
        return str(TOOL_REGISTRY[name](**kwargs))
    except Exception as e:
        return f"错误：执行失败 - {type(e).__name__}: {e}"

print(safe_execute({"function": {"name": "calculate", "arguments": '{"expression": "(12+8)*3.5"}'}}))
print(safe_execute({"function": {"name": "delete_database", "arguments": "{}"}}))
print(safe_execute({"function": {"name": "calculate", "arguments": '{"expr": "1+1"}'}}))
```

输出：

```
70.0
错误：工具 delete_database 未被授权
错误：缺少必填参数 expression
```

**另外两条必须做的防护**：

- **最大轮数 `max_turns`**（上面代码已实现）：防止模型陷入"调用→失败→再调用"的死循环烧钱。
- **危险操作人工确认**：涉及**写数据库、发消息、付款**的工具，不要直接执行，应该返回一条"待确认"让用户点确认。这是 Agent 安全的第一原则。

## 五、常见坑

| 坑 | 现象 | 解法 |
|---|---|---|
| description 写得太笼统 | 模型不选它、或乱选 | 写清"什么时候用"和边界 |
| 参数不用 `enum` | 传出不合法枚举值 | 用 `enum` + 代码里二次校验 |
| 忘记回填 tool 消息 | 报 "missing tool message" | 每个 tool_call 都要有对应 tool 消息 |
| `tool_call_id` 对不上 | 并行调用时结果错配 | 严格用返回的 id 回填 |
| 工具抛异常 | 整个对话崩溃 | 兜住异常，把错误信息当作结果返回（模型会自己改） |
| 没设 max_turns | 死循环、费用爆炸 | 限制 3~5 轮 |
| 用 `eval` 执行表达式 | 安全漏洞 | 白名单字符 + 空 `builtins`；生产用 `asteval` 等库 |
| 一次性给 20 个工具 | 模型选择困难、准确率下降 | 控制在 5~8 个，或按意图**动态路由**工具集 |

> 关于 `eval`：`eval(expr, {"__builtins__": {}}, {})` 能挡住大部分攻击，但**不是绝对安全**。生产环境请用专门的表达式求值库（如 `asteval`），或干脆用沙箱。

## 六、本篇小结

1. **模型不会执行函数**，它只输出"调用意图"，真正执行的是你的代码——这是 Function Calling 的本质，也是它安全的原因。
2. 工具用 **JSON Schema 描述**，`description` 要写清"**什么时候用**"和边界，枚举用 `enum`。
3. 完整链路是**多轮循环**：`user → assistant(tool_calls) → tool(结果) → assistant(最终答案)`，每条 tool 消息必须用 `tool_call_id` 关联。
4. 生产三道保险：**白名单 + 参数校验 + 最大轮数**；危险操作必须人工确认。
5. 工具数量控制在 **5~8 个以内**，太多会显著降低选择准确率。

**下一篇**：上面那个循环每转一轮，就要把**全部历史**（包括冗长的工具返回结果）重新发给模型。几轮下来 token 可能翻十倍，费用也跟着翻十倍。下一篇《上下文管理与成本控制》讲清 token 是怎么算的、上下文窗口的硬限制，并给出**滑动窗口、摘要压缩、Prompt 缓存**三种省钱策略。

> 本篇是《大模型开发从 0 到 1》专栏第 36 篇，阶段 6「提示词工程与大模型 API」第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
