# JSON 模式 vs 结构化输出：到底该用哪个

> 你需要模型返回 `{"sentiment": "negative", "score": 0.8}`。
> 摆在面前有三条路：自己写 prompt 求它输出 JSON、开 `response_format={"type":"json_object"}`、
> 用 `with_structured_output`。
>
> 三条路都能跑通，但**可靠性差一个数量级**。

## 一、三种方式的本质区别

| 方式 | 谁保证格式 | 可靠性 | 需要 schema |
|---|---|---|---|
| 提示词求 JSON | 模型自己"自觉" | 低（70~90%） | 否 |
| JSON 模式 | API 层约束输出是合法 JSON | 中高 | 否 |
| 结构化输出 | API 层按 schema 约束 | 高 | 是 |

关键差别在**约束层在哪**：

- 方式一是**提示约束**——你在 prompt 里求它，它可能忘了、可能加个 ` ```json ` 包裹；
- 方式二是**语法约束**——服务端保证输出能被 `json.loads` 解析，但**不保证字段名和类型**；
- 方式三是**模式约束**——服务端（或本地校验层）保证输出符合你给的 JSON Schema。

## 二、方式一：提示词求 JSON（不推荐单独用）

```python
from langchain_core.prompts import ChatPromptTemplate
import json

prompt = ChatPromptTemplate.from_template(
    "分析下面这句话的情感，只输出 JSON，格式为 "
    '{{"sentiment": "positive|negative|neutral", "score": 0~1 的小数}}。\n\n句子：{text}'
)

chain = prompt | llm | StrOutputParser()
raw = chain.invoke({"text": "这软件卡得我想砸电脑"})
print(raw)
```

十有八九你会看到：

```
```json
{"sentiment": "negative", "score": 0.9}
```
```

带着 Markdown 代码块围栏，直接 `json.loads` 就报错。你只能再加一层清洗：

```python
def strip_fence(s: str) -> str:
    s = s.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[1]
        s = s.rsplit("```", 1)[0]
    return s.strip()

data = json.loads(strip_fence(raw))
```

能跑，但**每次换模型、换 prompt，这层清洗都可能失效**。

## 三、方式二：JSON 模式

```python
from langchain_openai import ChatOpenAI

llm_json = ChatOpenAI(model="gpt-4o-mini").bind(
    response_format={"type": "json_object"}
)
```

注意两个硬性要求：

1. **提示词里必须出现 "JSON" 这个词**。OpenAI 明确要求 json 模式下提示词要提到 JSON，否则可能报错；
2. **它只保证是合法 JSON，不保证内容**。

所以可能出现：

```json
{"sentiment": "负", "score": "高"}
```

是合法 JSON，但 `score` 是字符串不是数字，"高"也不是你要的分数。你依然要写校验。

## 四、方式三：结构化输出

```python
from pydantic import BaseModel, Field
from typing import Literal

class Sentiment(BaseModel):
    """对一句话的情感判断。"""
    sentiment: Literal["positive", "negative", "neutral"] = Field(
        description="情感倾向"
    )
    score: float = Field(description="置信度，0 到 1 之间")

llm_structured = llm.with_structured_output(Sentiment)
result = llm_structured.invoke("这软件卡得我想砸电脑")
print(result)          # sentiment='negative' score=0.9
print(type(result))    # <class '__main__.Sentiment'>
```

**返回的直接是 Pydantic 对象**，不是字符串。你不需要 `json.loads`，不需要清洗，不需要校验——`Literal` 已经把取值范围锁死了。

这才是"结构化输出"该有的样子：**类型系统接管了格式校验**。

## 五、底层发生了什么

`with_structured_output` 并不是魔法，它做两件事：

1. 把你的 Pydantic 模型转成 **JSON Schema**；
2. 通过模型的原生能力（OpenAI 的 `json_schema`、Anthropic 的 tool use、开源模型的 grammar 约束）强制输出符合这个 schema。

可以用 `include_raw=True` 观察到中间过程：

```python
llm_structured = llm.with_structured_output(Sentiment, include_raw=True)
out = llm_structured.invoke("这软件卡得我想砸电脑")
print(out.keys())          # dict_keys(['raw', 'parsed', 'parsing_error'])
print(out["parsing_error"])  # None 表示解析成功
```

如果模型能力不支持原生 schema 约束，LangChain 会退化成"**工具调用**"路径——把这个 schema 包装成一个 tool 交给模型。你能在 `raw` 里看到 `tool_calls` 字段。

## 六、什么时候还是得用 JSON 模式

结构化输出这么好，为什么还留着 JSON 模式？

**场景一：结构不固定。**
"根据用户问题返回一个任意结构的分析结果"——没有 schema 可给，只能要个 JSON 再自己解析。

**场景二：模型不支持。**
部分国产模型、部分本地模型不支持 `json_schema`，但支持 `json_object`。

**场景三：你需要多段 JSON。**
比如一次返回 3 个独立对象，schema 表达起来别扭，不如让它输出 JSON 数组自己解析。

## 七、组合使用：JSON 模式 + Pydantic 校验

一个折中方案——**让 API 保证语法，让 Pydantic 保证语义**：

```python
from pydantic import ValidationError

def robust_extract(text: str, retries: int = 2) -> Sentiment:
    raw = (prompt | llm_json | StrOutputParser()).invoke({"text": text})
    for attempt in range(retries + 1):
        try:
            return Sentiment.model_validate_json(raw)
        except ValidationError as e:
            # 把错误回灌给模型，让它自己修
            raw = (fix_prompt | llm_json | StrOutputParser()).invoke(
                {"bad_json": raw, "error": str(e)}
            )
    raise ValueError(f"重试 {retries} 次仍无法解析：{raw}")
```

这个"失败就把校验错误喂回去"的模式，在处理能力较弱的模型时非常有效。

## 八、选择建议

```
模型支持 json_schema？
├─ 是 → 用 with_structured_output（首选）
│        └─ 输出结构不固定？→ 退回 JSON 模式
└─ 否 → 模型支持 json_object？
         ├─ 是 → JSON 模式 + Pydantic 校验 + 错误回灌
         └─ 否 → 提示词 + 清洗 + 校验（最后手段）
```

一句话总结：**能拿 schema 约束就别拿提示词约束**。前者是编译期检查，后者是运行时期望。
