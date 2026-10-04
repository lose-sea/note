<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# AI Agent 入门——用 Function Calling 让大模型真正干活

## 一、大模型最大的尴尬：只会说，不会做

你问大模型"今天北京天气怎么样"，它会很礼貌地告诉你：

> 抱歉，我无法获取实时天气信息，建议你查看天气预报网站。

这句话翻译过来就是：**我只是个语言模型，我没有手。**

大模型本质上是一个"根据上文预测下一个字"的概率机器。它擅长组织语言、推理逻辑，但它有三个天然短板：

1. **没有实时数据**：训练数据截止之后发生的事，它一概不知
2. **不会算**：让它算 `123456 × 789012`，它会一本正经地给你一个错答案
3. **没有副作用**：它没法帮你发邮件、查数据库、下单、改文件

而 **Function Calling（函数调用）** 就是给大模型"装上手"的机制：模型不直接干活，但它能**判断该调哪个工具、传什么参数**，真正的活由你的代码去执行。

一句话理解这个分工：

```
大模型负责"想"：现在该查天气了，参数是 city="北京"
你的代码负责"做"：真的去调天气 API，拿到 26℃ 多云
大模型再负责"说"：把结果组织成人话回答用户
```

## 二、Function Calling 的完整链路

先把整个流程画清楚，后面所有代码都是照着这张图写的：

```
┌──────────┐   ① 用户问题 + 工具清单
│  用户提问 │ ─────────────────────────▶ ┌──────────┐
└──────────┘                             │  大模型  │
                                         └────┬─────┘
                            ② 模型返回"我要调用 xx 工具，参数是 yy"
                                              │
                                              ▼
                                    ┌────────────────────┐
                                    │ 你的代码执行真实函数 │
                                    │ get_weather("北京") │
                                    └─────────┬──────────┘
                                              │ ③ 执行结果 26℃ 多云
                                              ▼
┌──────────┐   ④ 模型把结果组织成自然语言      ┌──────────┐
│ 最终回答  │ ◀────────────────────────────── │  大模型  │
└──────────┘                                  └──────────┘
```

注意关键点：**整个过程要跑两轮模型调用**，第二轮是把工具结果"喂回去"让模型总结。很多初学者卡在这里——拿到工具结果就直接返回给用户了，得到的是一堆原始 JSON。

还有一点容易误解：**Function Calling 不是模型自己执行了代码**。模型输出的只是一段结构化的"调用意图"，比如：

```json
{"name": "get_weather", "arguments": "{\"city\": \"北京\"}"}
```

真正去向气象局发请求的是你的 Python 函数。模型从头到尾没碰过你的网络、你的数据库。这也是这套机制安全的原因——**能力边界完全由你定义**。

## 三、实战一：让模型查天气（最小可用版本）

下面这段代码可以直接跑。我用 OpenAI 兼容的 SDK，DeepSeek、通义、 moonshot 等国内服务基本都兼容这个接口，改一下 `base_url` 和 `api_key` 就能用。

```python
import json
import os
from openai import OpenAI

# 1. 初始化客户端（换成你自己的服务地址和密钥）
client = OpenAI(
    api_key=os.getenv("OPENAI_API_KEY"),
    base_url="https://api.deepseek.com",   # 示例：DeepSeek 兼容 OpenAI 协议
)

# 2. 定义真实函数：这部分是"你的手"，模型永远碰不到它的内部实现
def get_weather(city: str) -> str:
    """假装调用了天气 API，真实项目里这里替换成 requests.get(...)"""
    fake_db = {
        "北京": {"temp": 26, "weather": "多云", "wind": "东南风 3 级"},
        "上海": {"temp": 31, "weather": "晴", "wind": "东风 2 级"},
        "广州": {"temp": 34, "weather": "雷阵雨", "wind": "南风 4 级"},
    }
    data = fake_db.get(city)
    if not data:
        return json.dumps({"error": f"暂不支持查询 {city} 的天气"}, ensure_ascii=False)
    return json.dumps({"city": city, **data}, ensure_ascii=False)

# 3. 用 JSON Schema 描述这个工具，告诉模型"你的手长什么样"
tools = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "查询指定城市的实时天气，包括温度、天气状况和风力",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {
                        "type": "string",
                        "description": "城市名称，例如：北京、上海、广州",
                    }
                },
                "required": ["city"],
            },
        },
    }
]

# 4. 第一轮：把问题和工具清单一起丢给模型
messages = [{"role": "user", "content": "北京今天天气怎么样？适合出门跑步吗？"}]

response = client.chat.completions.create(
    model="deepseek-chat",
    messages=messages,
    tools=tools,
    tool_choice="auto",   # auto = 让模型自己决定要不要用工具
)
msg = response.choices[0].message
print("【模型第一轮输出】", msg.tool_calls)
```

运行结果：

```
【模型第一轮输出】 [
  ChatCompletionMessageToolCall(
    id='call_0_abc123',
    function=Function(arguments='{"city": "北京"}', name='get_weather'),
    type='function'
  )
]
```

看到没？模型没有直接回答，而是说"我要调 `get_weather`，参数是 `{"city": "北京"}"`。而且它聪明地**只提取了 `北京` 这个词**，把"适合跑步吗"这种无关信息自动过滤掉了——这就是 schema 里 `description` 写得清楚带来的好处。

接下来执行函数、把结果喂回去：

```python
# 5. 执行真实函数
if msg.tool_calls:
    # 把模型的"调用意图"加进对话历史
    messages.append(msg)

    for tool_call in msg.tool_calls:
        fn_name = tool_call.function.name
        fn_args = json.loads(tool_call.function.arguments)

        # 函数名 → 真实函数的映射表
        available_fns = {"get_weather": get_weather}
        fn = available_fns[fn_name]
        result = fn(**fn_args)
        print(f"【执行结果】{fn_name} -> {result}")

        # 把执行结果按约定格式塞回对话
        messages.append({
            "role": "tool",
            "tool_call_id": tool_call.id,
            "content": result,
        })

    # 6. 第二轮：让模型看着工具结果做总结
    final = client.chat.completions.create(
        model="deepseek-chat",
        messages=messages,
    )
    print("\n【最终回答】", final.choices[0].message.content)
```

最终输出：

```
【执行结果】get_weather -> {"city": "北京", "temp": 26, "weather": "多云", "wind": "东南风 3 级"}

【最终回答】北京今天 26℃，多云，东南风 3 级。这个温度很适合户外跑步，
不过风力稍大，建议选择公园等有遮挡的路线，注意补水。
```

到这里一个最小可用的 Function Calling 就跑通了。核心只有三步：**描述工具 → 执行调用 → 结果回填**。

## 四、实战二：多轮调用循环（真正的 Agent 雏形）

真实场景里，用户的问题往往需要**连查好几个工具**，或者"查完天气发现不适合跑步，再帮我查个室内健身房"。这种链式需求，就要把上面的逻辑包成一个 `while` 循环：

```python
def run_agent(user_query: str, max_rounds: int = 5):
    """带工具调用循环的简易 Agent"""
    messages = [{"role": "user", "content": user_query}]

    for round_i in range(max_rounds):
        response = client.chat.completions.create(
            model="deepseek-chat",
            messages=messages,
            tools=tools,
        )
        msg = response.choices[0].message

        # 模型没要求调工具 → 说明它认为信息够了，直接输出答案
        if not msg.tool_calls:
            return msg.content

        messages.append(msg)
        for call in msg.tool_calls:
            args = json.loads(call.function.arguments)
            fn = available_fns[call.function.name]
            try:
                result = fn(**args)
            except Exception as e:
                # 关键：工具报错也要如实告诉模型，让它自己想办法或如实交代
                result = json.dumps({"error": str(e)}, ensure_ascii=False)

            messages.append({
                "role": "tool",
                "tool_call_id": call.id,
                "content": result,
            })
        print(f"--- 第 {round_i + 1} 轮调用完成 ---")

    return "抱歉，尝试了多次仍未能完成任务。"

# 测试：需要连续调用多个工具
print(run_agent("北京和上海今天哪儿更适合户外跑？"))
```

这个 `max_rounds` 非常重要，下面坑位会讲到原因。

## 五、五个必踩的坑

| 坑 | 现象 | 解决办法 |
| --- | --- | --- |
| 工具描述含糊 | 模型乱调、漏调、参数乱填 | `description` 写清"什么时候该用、什么时候不该用" |
| 参数幻觉 | 传了 schema 里不存在的字段，或 city 传成拼音 | 参数加 `enum` 约束，代码侧做校验兜底 |
| 忘记回填 tool 消息 | 第二轮报错 `tool_call_id 无对应结果` | 每个 tool_call 必须有一条 `role="tool"` 的消息 |
| 死循环 | 模型反复调同一个工具、账单飞涨 | 设 `max_rounds`，超次数强制退出并上报 |
| 工具报错直接崩 | 一次异常整个对话断开 | try/except 包住调用，把错误信息作为结果返回给模型 |

其中**参数幻觉**最常见。比如用户说"帮我查下魔都天气"，模型很可能老老实实传 `{"city": "魔都"}`，而你的数据库里根本没有这个 key。正确做法是在代码侧兜一层：

```python
CITY_ALIAS = {"魔都": "上海", "帝都": "北京", "羊城": "广州", "鹏城": "深圳"}

def get_weather_safe(city: str) -> str:
    # 别名归一化，把模型的"自由发挥"拉回可控范围
    city = CITY_ALIAS.get(city, city)
    return get_weather(city)
```

## 六、三种方案的取舍

| 方案 | 优点 | 缺点 | 适合场景 |
| --- | --- | --- | --- |
| 纯 Prompt 约束输出 JSON | 不用改 SDK 调用方式 | 格式经常不合法，要写一堆重试 | 简单场景、临时验证 |
| **Function Calling** | 格式有保证、多工具稳定、生态成熟 | 要多写一层工具描述和分发逻辑 | **绝大多数生产场景** |
| 直接用 LangChain 等框架 | 封装好、起步快 | 抽象层次高，出问题不好排查 | 快速原型、团队已有技术栈 |

我的建议是：**先用原生 SDK 手写一遍**，搞懂那张流程图，再决定要不要上框架。跳过这一步直接用框架，出问题的时候你会完全不知道该看哪一层。

## 七、小结

1. Function Calling 的本质是**模型输出调用意图，代码负责真实执行**，安全边界由你掌控
2. 完整链路必须跑**两轮模型调用**：第一轮决策工具，第二轮总结结果，少了第二轮就只能给用户看 JSON
3. `description` 的质量直接决定调用准确率——它是给模型看的"说明书"
4. 包一层 `while` 循环并设置 `max_rounds`，就得到了一个最简可用的 Agent
5. 参数幻觉、工具报错、死循环这三个坑，**全部在代码侧兜底**，不要指望模型自己变乖

掌握 Function Calling 之后，往上一步是让 Agent 具备"规划"和"反思"能力——那才是完整的 Agent 工程实践。

> 一句话总结：**Prompt 决定了模型说什么，Function Calling 决定了模型能做什么。**
