# 并行工具调用：让 Agent 一次问完，而不是问一句等一句

用户让 Agent「同时查一下订单状态、物流信息和会员等级」，你的 Agent 怎么处理？

串行的做法：调 `query_order` 等 3 秒 → 调 `query_logistics` 等 5 秒 → 调 `query_member` 等 2 秒。总耗时 10 秒，用户看到的是「转圈圈转圈圈」。

并行的做法：三个一起发，5 秒后三个结果都回来。**耗时取决于最慢的那个，不是总和。**

这一篇讲清楚并行工具调用怎么实现、模型怎么才会并行、以及什么情况下强行并行反而更糟。

---

## 一、并行调用的两种来源

先分清两种「并行」，实现方式完全不同。

### 1.1 模型主动并行

模型在**同一次响应里返回多个 tool_call**：

```json
{
  "tool_calls": [
    {"id": "call_1", "function": {"name": "query_order", "arguments": "{\"order_id\":\"123\"}"}},
    {"id": "call_2", "function": {"name": "query_logistics", "arguments": "{\"order_id\":\"123\"}"}},
    {"id": "call_3", "function": {"name": "query_member", "arguments": "{\"user_id\":\"u1\"}"}}
  ]
}
```

三个调用在一次 LLM 返回里。**这是模型的能力，也是效率最高的形态**——模型自己判断出这三件事互不相干。

### 1.2 程序强制并行

你明知道这几个可以并行，直接代码里同时发：

```python
async def gather_tools(order_id: str):
    results = await asyncio.gather(
        query_order(order_id),
        query_logistics(order_id),
        query_member(order_id),
    )
    return results
```

不需要模型判断，程序说了算。**适合固定流程**（比如每次都要同时查三样），省掉模型的决策开销。

**多数场景应该用 1.2（程序强制并行），只在需要模型灵活判断时才依赖 1.1。**

---

## 二、怎么让模型主动并行

模型想不想并行，取决于三件事。

### 2.1 系统提示要明确授权

```
你可以并且应该在**相互独立**的多个查询、多个数据源时，
在同一次回复中同时发起多个工具调用，而不是一个接一个地等结果。

规则：
1. 多个调用之间没有依赖关系时，必须同时发出；
2. 如果调用 B 的参数需要调用 A 的结果，必须等 A 返回后再发 B；
3. 同时发起的调用数量不要超过 5 个。
```

**没有这段提示，很多模型默认会串行。** 它会一个调用返回一个结果再决定下一步——这样更「稳」，但慢。

### 2.2 让模型知道「这一步要的是多个独立信息」

把任务的并行性说清楚：

```python
# ❌ 模糊，模型可能一次只做一件
"帮我查一下这个订单的情况"

# ✅ 明确要多项独立信息，模型更容易并行
"请同时查询：1) 订单状态 2) 物流进度 3) 用户会员等级。"
```

**列点比长句更能触发并行**——模型看到「1) 2) 3)」天然知道这是三个独立项。

### 2.3 工具描述要自包含

如果 `query_logistics` 的描述里写「需要先调用 query_order 获取 logistics_id」，模型就会串行。**把参数依赖消除（都接收 order_id）**，模型才能判断出「这三个互相独立」。

**参数设计的独立性直接决定并行可能性。** 这是并行能力的地基。

---

## 三、处理并行调用的返回

### 3.1 结果必须按 id 对回

模型返回多个 tool_call，每个有唯一 id。执行后必须按 id 把 tool 结果拼回去：

```python
def run_tool_calls(response) -> list[dict]:
    results = []
    for tc in response.tool_calls:          # 逐个处理（此处可并行执行，见 3.2）
        try:
            out = dispatch(tc.name, json.loads(tc.arguments))
            results.append({
                "tool_call_id": tc.id,          # 必须带
                "role": "tool",
                "name": tc.name,
                "content": serialize(out),
            })
        except Exception as e:
            results.append({
                "tool_call_id": tc.id,
                "role": "tool",
                "content": f"调用失败：{e}",       # 失败也要返回，不能跳过
            })
    return results
```

**`tool_call_id` 是关键**，漏了模型就不知道哪个结果对应哪个调用——它会假设你按顺序返回，顺序错就全乱套。

### 3.2 执行阶段可以真正并发

```python
async def run_tool_calls_async(response):
    calls = response.tool_calls

    async def run_one(tc):
        try:
            out = await dispatch_async(tc.name, json.loads(tc.arguments))
            return {"tool_call_id": tc.id, "role": "tool",
                    "name": tc.name, "content": serialize(out)}
        except Exception as e:
            return {"tool_call_id": tc.id, "role": "tool",
                    "name": tc.name, "content": f"调用失败：{e}"}

    # 并发执行所有工具调用
    results = await asyncio.gather(*[run_one(tc) for tc in calls])
    return list(results)
```

**注意顺序**：`asyncio.gather` 保序返回，但**模型要求的是按 tool_call_id 匹配**，不是按位置。所以哪怕颠倒了顺序，只要有 id 就不会出错。

### 3.3 单个工具失败不能拖垮整体

```python
except Exception as e:
    return {"tool_call_id": tc.id, "role": "tool", "name": tc.name,
            "content": f"【调用失败】{type(e).__name__}: {e}\n"
                       f"请基于其他已成功的工具结果回答，"
                       f"并在回复中说明此项未获取到。"}
```

**失败也要返回一条 tool 消息**，不能跳过。否则消息数量不匹配，模型会困惑（或者直接报错）。而且要让模型知道「这项失败了，别说它成功」。

---

## 四、并行的边界

不是所有情况都该并行。

### 4.1 有依赖的必须串行

```python
# ❌ 不能并行：第二个调用需要第一个的结果
call_1: get_user(u1) → {user_id, dept_id}
call_2: get_dept(dept_id)      # dept_id 来自 call_1
```

这类依赖，模型通常自己能识别（因为参数描述里有依赖）。但如果你在系统提示里写「总是并行调用」，模型可能强行并行、参数填错。

**提示词要写清规则：「无依赖才并行，有依赖必须等结果」。**

### 4.2 同一个资源的并发写操作要小心

并行调两个「写」工具，可能互相覆盖、触发锁冲突、或者违反业务顺序（先创建再修改）。

```python
# ❌ 并行有风险
call_1: create_order(...)
call_2: add_items_to_order(order_id)     # 依赖 call_1 创建的订单

# ✅ 写操作串行，读操作可并行
```

**判据：写操作默认串行，读操作默认可并行。**

### 4.3 下游系统扛不住

三个并行调用同时打同一个数据库，连接池可能打满。**并发的上限要考虑下游容量**，不只是 LLM API 的限流。

### 4.4 并发成本守恒

并行不省 token，只省时间。五次并行的 token 和五次串行一样多。**如果你的瓶颈是成本而不是延迟，并行没有帮助。**

---

## 五、框架怎么支持

各主流框架都有并行支持，用法简述：

**LangChain / LangGraph**

```python
# 模型侧：tool_calls 本身支持多个
# 执行侧：用 RunnableParallel 或自己并发
from langchain_core.runnables import RunnableParallel

chain = RunnableParallel({
    "order": query_order_chain,
    "logistics": query_logistics_chain,
    "member": query_member_chain,
})
result = await chain.ainvoke(input)      # 三个并发跑
```

**OpenAI Function Calling**

```python
response = client.chat.completions.create(
    model="gpt-4o",
    messages=messages,
    tools=[order_tool, logistics_tool, member_tool],
    parallel_tool_calls=True,       # 显式开启（默认是 True）
)
# response.choices[0].message.tool_calls 可能是多个
```

**LangChain Agent（create_agent）**

现代 Agent 循环默认会并发执行一批 tool_call。但**如果你的工具有副作用（写操作），要确认它是否正确串行**——有的实现是并发的，写操作会撞车。

**自研循环**

按 3.2 的代码自己实现，注意三件：按 id 对回、失败也返回消息、写操作串行。

---

## 六、怎么验证并行生效了

并行提速很容易「以为生效了但其实没有」。三个验证点：

### 6.1 看 trace

一次请求打了几次工具？时间戳是重叠的还是首尾相接的？

```
t=0.0s  调 query_order（耗时 3s）
t=3.0s  调 query_logistics（耗时 5s）     ← 串行！总 10s
t=8.0s  调 query_member（耗时 2s）
```

```
t=0.0s  同时发三个调用
t=5.0s  全部返回（最慢的那个）           ← 并行 ✓ 总 5s
```

### 6.2 看单次请求的工具调用数

模型响应里 `tool_calls` 数组长度 > 1，才叫「模型主动并行」。长度永远是 1，说明提示词没写对，或者工具描述让模型以为有依赖。

### 6.3 看总耗时

固定任务跑 10 次，比较并行前后的 P95 耗时。如果没降，问题在执行层（你以为并发发了，实际在 for 循环里一个个 await）。

---

## 七、常见误区

**误区一：系统提示没授权并行，模型就一直串行。** 多数模型默认保守串行。显式写「无依赖时同时发起」。

**误区二：忘了 `tool_call_id`。** 模型靠它匹配结果。漏了会错配，尤其是你调整了执行顺序之后。

**误区三：工具执行失败就跳过。** 必须返回一条失败消息，否则消息对不上，模型也不知道这项失败了。

**误区四：写操作也并行。** 读可并行，写默认串行。并发的写会撞车、覆盖、违反业务顺序。

**误区五：以为并行省 token。** 只省时间。成本该多少还是多少。

**误区六：工具参数互相依赖还强行并行。** 仔细看工具描述，参数依赖是并行的硬约束。

**误区七：只优化 LLM API 并发，不管下游。** 数据库、下游服务扛不住，并行一样卡。

---

## 小结

- 并行工具调用把「转 10 秒」变成「转 5 秒」——**耗时取决于最慢的那个调用，不是总和**。
- 两个来源：**模型主动并行**（一次响应多个 tool_call，需要系统提示明确授权「无依赖时同时发起」）和**程序强制并行**（`asyncio.gather`，适合固定流程，省掉模型决策）。
- 让模型并行的三个条件：**系统提示授权、任务描述列点（1/2/3）、工具参数自包含无依赖**。第三点是地基——参数有依赖就永远并行不了。
- 执行的三个必须：**按 tool_call_id 对回（漏了必错）、失败也返回 tool 消息、写操作默认串行**。
- 边界：有依赖必须串行、写操作不并行、注意下游容量、**并行只省时间不省 token**。
- 验证并行是否生效：看 trace 时间戳是否重叠、看 tool_calls 数组长度、对比固定任务 P95 耗时。

Agent 的「快」，一半来自模型，一半来自工程。并行是最便宜的那一半——不改模型、不改提示词，改的只是「一次问完还是问一句等一句」。
