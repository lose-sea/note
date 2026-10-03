<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# 大模型应用与 Prompt 工程——写出稳定可控的提示词

## 一、Prompt 不是"聊天"，是"写接口文档"

很多人用大模型的方式是：丢一句话过去，看它回什么，不满意就换个说法再试。这叫**试错式调参**，效率极低，而且不可复现。

真正做应用时的思路应该是：**把 Prompt 当成一份给"实习生"看的接口文档**。

想象你要让一个聪明但不了解你业务的新同事干活，你会怎么做？

- 告诉他**角色**：你是谁、负责什么
- 告诉他**背景**：项目是什么、用户是谁
- 告诉他**任务**：具体要做什么
- 告诉他**格式**：输出成什么样
- 给他**示例**：照着这个来
- 告诉他**边界**：什么不能做、拿不准怎么办

把这六件事写清楚，就是一份合格的 Prompt。

## 二、Prompt 的六要素结构

我常用的模板长这样：

```
# 角色
你是一名资深 XXX，拥有 10 年 XXX 经验。

# 背景
（业务背景、数据背景、用户画像，越具体越好）

# 任务
请完成以下任务：
1. ...
2. ...

# 输出格式
严格按以下 JSON 输出，不要有任何额外文字：
{
  "field1": "...",
  "field2": "..."
}

# 示例
输入：xxx
输出：{"field1": "...", "field2": "..."}

# 约束
- 只使用给定材料中的信息，不允许编造
- 如果信息不足，返回 {"error": "信息不足"}
- 不要输出解释性文字
```

逐个拆解为什么需要它们：

| 要素 | 作用 | 不写的后果 |
| ---- | ---- | ---------- |
| **角色** | 激活模型对应领域的语料分布 | 回答泛泛、不专业 |
| **背景** | 消除歧义，提供判断依据 | 模型自己脑补前提 |
| **任务** | 明确要做什么 | 答非所问 |
| **输出格式** | 让结果可被程序解析 | 每次格式都不一样，没法自动化 |
| **示例** | 用例子定义"什么叫做好" | 风格漂移 |
| **约束** | 划定红线 | 胡编乱造、越权、输出啰嗦 |

**其中最容易被低估的是"约束"**。加一句"信息不足就返回错误，不要编造"，能把幻觉率砍掉一大半。

## 三、一个完整的实战例子：舆情分类

需求：把用户评论分类，并提取关键信息，输出结构化 JSON 给下游系统用。

### 3.1 先写一个"能用"的版本（不推荐）

```python
prompt = f"分析这条评论的情感：{comment}"
response = call_llm(prompt)
```

问题很明显：输出可能是"这条评论是正面的"，也可能是"情感倾向：积极。理由：……"，格式完全不可控，程序没法解析。

### 3.2 写成"工程化"的版本（推荐）

```python
import json
import os
from openai import OpenAI

client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"),
                base_url=os.getenv("OPENAI_BASE_URL"))   # 兼容各家大模型

SYSTEM_PROMPT = """
# 角色
你是一名资深舆情分析专家，服务于一家连锁餐饮品牌。

# 任务
对用户输入的用户评论做情感分类与关键信息抽取。

# 输出格式
严格输出 JSON，不要包含任何解释文字，键名固定如下：
{
  "sentiment": "positive | neutral | negative",
  "score": 0-1 之间的浮点数，表示情感强烈程度,
  "aspects": [{"aspect": "涉及维度,如 口味/服务/环境/价格/配送", "opinion": "用户具体评价"}],
  "needs_reply": true 或 false，表示是否需要客服介入
}

# 约束
- sentiment 只能是三个枚举值之一
- 无法判断的维度不要捏造，aspects 可以为 []
- 出现辱骂、投诉、食品安全问题时 needs_reply 必须为 true
- 不要输出任何 JSON 之外的内容
"""

def analyze_comment(comment: str) -> dict:
    resp = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": comment}
        ],
        temperature=0,          # 分类任务要确定性，温度设 0
        response_format={"type": "json_object"}   # 强制 JSON 输出
    )
    return json.loads(resp.choices[0].message.content)

# 测试
comment = "等了40分钟才上菜，服务员态度还特别差，再也不来了！"
print(json.dumps(analyze_comment(comment), ensure_ascii=False, indent=2))
```

典型输出：

```json
{
  "sentiment": "negative",
  "score": 0.92,
  "aspects": [
    {"aspect": "服务", "opinion": "服务员态度差"},
    {"aspect": "配送", "opinion": "上菜等待40分钟"}
  ],
  "needs_reply": true
}
```

**这个版本可以直接进生产**：格式固定、可解析、有兜底逻辑。

### 3.3 关键参数怎么调

| 参数 | 含义 | 分类/抽取任务 | 创意写作 |
| ---- | ---- | ------------- | -------- |
| `temperature` | 采样随机性 | **0 ~ 0.2**（要稳定） | 0.7 ~ 1.0 |
| `top_p` | 核采样 | 通常不动 | 可配合调 |
| `max_tokens` | 最大输出长度 | 按格式上限设 | 留足空间 |
| `response_format` | 强制 JSON | **强烈建议开** | 不用 |

> ⚠️ **坑 1**：只靠 Prompt 说"请输出 JSON"是不够的，**一定要配合 `response_format={"type":"json_object"}`**（或各家的 JSON mode），否则模型偶尔会在 JSON 外面加一句"好的，分析结果如下："。

## 四、让模型"会推理"：思维链与少样本

### 4.1 Zero-shot vs Few-shot

| 方式 | 做法 | 适用场景 |
| ---- | ---- | -------- |
| Zero-shot | 只给任务描述 | 简单任务、通用能力 |
| Few-shot | 给 2-5 个输入/输出示例 | 格式特殊、边界模糊、领域术语多 |

Few-shot 示例：

```python
FEWSHOT = """
示例1：
输入：这个披萨料足味美，就是有点贵
输出：{"sentiment":"positive","score":0.7,"aspects":[{"aspect":"口味","opinion":"料足味美"},{"aspect":"价格","opinion":"有点贵"}],"needs_reply":false}

示例2：
输入：还行吧，没什么特别的
输出：{"sentiment":"neutral","score":0.3,"aspects":[],"needs_reply":false}

示例3：
输入：吃出头发了，太恶心了
输出：{"sentiment":"negative","score":0.98,"aspects":[{"aspect":"食品安全","opinion":"吃出头发"}],"needs_reply":true}
"""
```

把示例放进 system prompt，模型对边界情况（比如"中性怎么判"）的表现会稳定很多。

### 4.2 思维链 Chain-of-Thought

对于需要推理的任务（数学、逻辑判断、多步分析），让模型**先把思考过程写出来**，准确率会显著提升。

```python
prompt = """
请判断下面的退款申请是否符合政策。

政策：
1. 7天内可无理由退款
2. 超过7天但存在质量问题可退
3. 已使用超过一半不支持退款

申请：用户 10 天前购买，称商品有裂缝，已使用约 20%。

请按以下步骤回答：
步骤1：列出关键事实（购买天数、是否质量问题、使用比例）
步骤2：逐条比对政策
步骤3：给出最终结论（同意退款 / 拒绝退款）与依据
"""
```

不加"步骤"引导时，模型容易直接跳到结论，出错率明显更高。

> 注意：**推理链会消耗更多 token**。生产环境可以做取舍——复杂判断开 CoT，简单分类不开。

## 五、Function Calling：让模型调用真实工具

大模型不会算账、查不到实时数据、不知道你数据库里有什么。**Function Calling 就是让模型"说出它想调什么函数"，由你的程序去真正执行**。

完整流程：

```
用户需求 "北京今天天气怎么样"
   ↓
模型判断：需要调用 get_weather(location)
   ↓ 返回函数调用请求（不是直接回答）
你的程序执行 get_weather("北京")
   ↓ 把结果塞回对话
模型基于真实数据生成回答
```

代码：

```python
tools = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "查询指定城市的当前天气",
        "parameters": {
            "type": "object",
            "properties": {
                "location": {"type": "string", "description": "城市名，如 北京"}
            },
            "required": ["location"]
        }
    }
}]

def get_weather(location: str) -> str:
    # 真实场景里这里调天气 API 或查数据库
    db = {"北京": "晴，26℃，东南风2级", "上海": "多云，29℃"}
    return db.get(location, "暂无该城市数据")

messages = [{"role": "user", "content": "北京今天天气怎么样？"}]

# 第一次调用：模型决定要不要用工具
resp = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=messages,
    tools=tools,
    tool_choice="auto"     # 让模型自己判断
)
msg = resp.choices[0].message
print("模型决策:", msg.tool_calls[0].function.name if msg.tool_calls else "直接回答")
print("参数:", msg.tool_calls[0].function.arguments if msg.tool_calls else "-")
# 输出：模型决策: get_weather   参数: {"location":"北京"}

# 第二次：执行函数，把结果喂回去
messages.append(msg)
messages.append({
    "role": "tool",
    "tool_call_id": msg.tool_calls[0].id,
    "content": get_weather("北京")
})
final = client.chat.completions.create(model="gpt-4o-mini", messages=messages)
print("最终回答:", final.choices[0].message.content)
# 输出：北京今天是晴天，气温 26℃，东南风 2 级，适合户外活动。
```

> ⚠️ **坑 2**：函数执行结果必须以 `role: "tool"` 且带上正确的 `tool_call_id` 回传，否则模型会报"找不到对应的 tool 消息"。

> ⚠️ **坑 3**：**永远不要让模型直接执行危险操作**（删库、转账、发邮件）。Function Calling 只返回"意图"，真正的执行必须经过你的权限校验。

## 六、上下文管理与成本控制

这是做应用最容易失控的地方。

### 6.1 上下文窗口的真实限制

| 问题 | 说明 |
| ---- | ---- |
| 长度有限 | 超过窗口会截断，早期信息丢失 |
| 中间遗忘 | 长上下文里模型对**开头和结尾**记得更牢，中间容易忽略 |
| 成本线性增长 | 每次请求都要把所有历史 token 重发一遍 |

### 6.2 四种省钱省长度的策略

```python
# 策略1：滑动窗口 —— 只保留最近 N 轮
def sliding_window(history, n=6):
    return history[-n:]

# 策略2：摘要压缩 —— 把早期对话总结成一段
def compress(history, client):
    summary = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content":
            f"把以下对话压缩成100字以内的要点：\n{history}"}]
    ).choices[0].message.content
    return [{"role": "system", "content": f"之前的对话要点：{summary}"}]

# 策略3：只回传必要字段，别把整张表塞进去
#   错误：把 1000 行订单全塞进 prompt
#   正确：先 SQL 聚合，只给 Top 10 和统计值

# 策略4：缓存 system prompt（各家有 prompt caching，重复前缀打折）
```

### 6.3 成本估算

```python
PRICE = {"gpt-4o-mini": (0.15, 0.60)}   # 每百万 token 美元：输入, 输出

def estimate_cost(model, in_tokens, out_tokens, calls=1000):
    pin, pout = PRICE[model]
    cost = (in_tokens * pin + out_tokens * pout) / 1_000_000
    return f"单次 ${cost:.6f}，{calls} 次/天 ≈ ${cost*calls:.2f}"

print(estimate_cost("gpt-4o-mini", 1500, 300))
# 单次 $0.000405，1000 次/天 ≈ $0.40
```

上线前先算一笔账，避免出现"功能做出来了，账单爆了"的事故。

## 七、Prompt 迭代的正确姿势

不要凭感觉改，要像跑实验一样：

1. **先建测试集**：准备 20-50 条有代表性的输入 + 期望输出（覆盖正常、边界、异常）
2. **定量化指标**：分类看准确率，抽取看字段完整率，格式看 JSON 解析成功率
3. **一次只改一处**：改了角色就别同时改示例，否则不知道是谁起的作用
4. **记录版本**：把每个版本的 Prompt 和对应的分数存下来

```python
testset = [
    ("太好吃了，下次还来", "positive"),
    ("一般般", "neutral"),
    ("吃出虫子了！！！", "negative"),
    ("", "neutral"),            # 空输入边界
    ("👏👏👏", "positive"),       # 纯 emoji
]

def evaluate(system_prompt):
    correct = 0
    for text, expect in testset:
        try:
            r = analyze_comment(text)
            correct += (r["sentiment"] == expect)
        except Exception as e:
            print("解析失败:", text, e)
    return f"{correct}/{len(testset)}"

print("当前版本得分:", evaluate(SYSTEM_PROMPT))
```

## 八、本节小结

1. **Prompt = 给实习生的接口文档**：角色、背景、任务、格式、示例、约束，六要素缺一不可。
2. **格式必须强制**：靠"请输出 JSON"不够，要配 `response_format` + `temperature=0`。
3. **加"信息不足就报错"的约束**，是降低幻觉最高性价比的一招。
4. **Few-shot 解决边界模糊，思维链解决推理任务**，但都要付出 token 成本。
5. **Function Calling 让模型能调真实工具**，但执行必须过你的权限校验。
6. **上下文要管理、成本要估算**：滑动窗口、摘要压缩、只给必要数据、利用 prompt caching。
7. **迭代靠测试集，不靠感觉**：20-50 条用例 + 量化指标，一次只改一处。

下一篇讲 RAG（检索增强生成）：怎么把你的私有文档喂给模型，让它只根据材料回答，彻底解决"不知道 + 会编造"的问题。

---

> 一句话记住：**好的 Prompt 不是"把话说漂亮"，而是"把需求、格式、边界说死"——越像接口文档，结果越可控。**
