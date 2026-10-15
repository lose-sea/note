# 工具报错怎么让模型自愈：ToolException 与 handle_tool_error

> Agent 调了个查询天气的工具，接口超时报错。
> 默认行为：整个 Agent 崩掉，用户看到一堆 traceback。
>
> 但如果你把错误**当成一条消息还给模型**，它往往会自己换个参数重试、或者换个工具。
> 这篇讲怎么设计这个"自愈"通道。

## 一、默认行为有多糟

```python
from langchain_core.tools import tool

@tool
def get_weather(city: str) -> str:
    """查询指定城市的天气。"""
    resp = requests.get(f"https://api.example.com/weather?city={city}", timeout=3)
    resp.raise_for_status()          # 超时会抛异常
    return resp.json()["desc"]
```

一旦 `raise_for_status()` 抛错，Agent 执行链会**直接中断**，异常冒泡到调用方。用户看到的是：

```
requests.exceptions.HTTPError: 429 Client Error: Too Many Requests
```

模型完全不知道发生了什么，也没有机会补救——**它已经被踢出流程了**。

## 二、ToolException：把错误变成可读消息

LangChain 提供了 `ToolException`，专门用来表达"这个工具失败了，但别崩，告诉模型"：

```python
from langchain_core.tools import tool, ToolException

@tool
def get_weather(city: str) -> str:
    """查询指定城市的天气。city 必须是中文城市名，如"北京"。"""
    try:
        resp = requests.get(f"https://api.example.com/weather?city={city}", timeout=3)
        resp.raise_for_status()
        return resp.json()["desc"]
    except requests.exceptions.Timeout:
        raise ToolException("天气接口超时（3 秒），请稍后重试或换一个城市名")
    except requests.exceptions.HTTPError as e:
        if e.response.status_code == 429:
            raise ToolException("天气接口限流了，请减少调用频率")
        raise ToolException(f"天气接口返回异常：{e.response.status_code}")
    except KeyError:
        raise ToolException(f"返回数据里没有天气字段，可能城市名「{city}」无法识别")
```

关键点：**错误信息是写给模型看的，不是写给人看的**。

对比一下：

| 写法 | 模型看到的 | 模型能做什么 |
|---|---|---|
| `raise HTTPError(...)` | 无（链断了） | 什么都做不了 |
| `raise ToolException("Error 429")` | 太模糊 | 只能瞎猜 |
| `raise ToolException("天气接口限流了，请减少调用频率")` | 明确 | 可能改用缓存或换工具 |

## 三、handle_tool_error：让错误自动回灌

`ToolException` 默认还是会中断流程——除非你设置 `handle_tool_error`：

```python
@tool(handle_tool_error=True)
def get_weather(city: str) -> str:
    ...
```

三种取值：

```python
@tool(handle_tool_error=True)              # 用异常消息本身作为工具返回
@tool(handle_tool_error="天气服务暂时不可用")  # 用固定字符串
@tool(handle_tool_error=lambda e: f"工具失败：{e}")  # 自定义转换
```

设置之后，工具不会抛异常，而是**返回一段文本作为工具消息**，模型会读到它并决定下一步。

用一个最小例子验证：

```python
@tool(handle_tool_error=True)
def divide(a: float, b: float) -> str:
    """计算 a 除以 b。"""
    if b == 0:
        raise ToolException("除数不能为 0，请检查输入")
    return str(a / b)

llm_with_tools = llm.bind_tools([divide])
msg = llm_with_tools.invoke("帮我算 10 除以 0")
print(msg.tool_calls)   # [{'name': 'divide', 'args': {'a': 10, 'b': 0}}]

result = divide.invoke(msg.tool_calls[0])
print(result)           # "除数不能为 0，请检查输入"
```

真实运行中，这段文本会作为 `ToolMessage` 回到模型，模型通常会说"除数为 0 无法计算，请提供其他数值"。

## 四、区分"可重试错误"和"致命错误"

不是所有错误都该回灌。**该崩的还是要崩**：

```python
class RetryableError(ToolException):
    """可以告诉模型重试的错误。"""

class FatalError(Exception):
    """必须中断流程的错误。"""

@tool
def query_order(order_id: str) -> str:
    """根据订单号查询订单详情。"""
    if not re.match(r"^SO\d{10}$", order_id):
        # 参数格式错 → 模型可以改，回灌
        raise RetryableError(f"订单号格式不对：{order_id}，正确格式是 SO + 10 位数字")
    try:
        return db.query(order_id)
    except DBConnectionError as e:
        # 数据库连不上 → 重试也没用，必须崩
        raise FatalError(f"数据库连接失败：{e}") from e
```

判定标准很简单：

- **模型能通过改变行为修复的** → `ToolException` + `handle_tool_error`；
- **模型做什么都没用的**（网络断了、密钥错了、服务下线）→ 让它崩，交给上层重启/告警。

把数据库连不上这种事回灌给模型，它只会反复重试，浪费 token。

## 五、更细的粒度：给模型的"重试预算"

有时候你希望模型可以重试，但**不能无限重试**。用一个状态容器记账：

```python
from collections import defaultdict

class ToolBudget:
    def __init__(self, max_retry=3):
        self.count = defaultdict(int)
        self.max_retry = max_retry

    def check(self, tool_name: str, args_key: str):
        key = f"{tool_name}:{args_key}"
        self.count[key] += 1
        if self.count[key] > self.max_retry:
            raise FatalError(f"工具 {tool_name} 用参数 {args_key} 已重试 {self.max_retry} 次，放弃")

budget = ToolBudget()

@tool
def get_weather(city: str) -> str:
    """查询天气。"""
    budget.check("get_weather", city)
    ...
```

注意用 `tool_name + 参数` 作为 key——**同一个工具用不同参数重试是合理的，用相同参数反复撞墙才该拦**。

## 六、错误信息的写法模板

一条好的错误信息包含四部分：

```
[发生了什么] + [为什么] + [怎么改] + [备选方案]
```

例子：

```
查询订单失败：订单号格式不对（收到 "SO123"）。
正确格式是 SO + 10 位数字，如 SO2026010001。
如果你不知道订单号，可以调用 list_orders(user_id) 先列出该用户的订单。
```

最后那句"备选方案"是精髓——**它直接告诉模型下一步该干什么**。没有这句，模型经常陷入"原工具重试"的死循环。

## 七、别忘了给工具写清楚的 docstring

`handle_tool_error` 治的是"执行出错"，但**参数填错**靠的是 docstring：

```python
@tool
def get_weather(city: str) -> str:
    """查询指定城市的天气。

    Args:
        city: 城市中文名，必须是完整市名，如"北京市"、"上海市"。
              不要传省份名或区县名。
    """
```

模型选工具、填参数全靠这段描述。**描述模糊 → 参数错 → 触发错误 → 回灌 → 再错**，形成浪费循环。前端防错比后端兜底更划算。

## 八、小结

| 做法 | 效果 |
|---|---|
| 裸 `raise` | Agent 崩溃，模型无法补救 |
| `ToolException` | 错误可读，但流程仍中断 |
| `ToolException` + `handle_tool_error` | 错误回灌，模型自愈 ✅ |
| 区分可重试/致命错误 | 避免无意义重试 |
| 错误信息带"备选方案" | 引导模型走出死循环 |

核心思想一句话：**工具的错误是一种信息，不是一种终止**。把它设计成模型能理解、能利用的信息，Agent 的鲁棒性会有质的变化。
