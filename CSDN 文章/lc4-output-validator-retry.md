# 输出校验与自动修复：让模型自己把错改过来

> 模型输出了一段 JSON，少了一个必填字段。
> 你的代码抛异常，用户看到一个红色报错页。
>
> 更好的做法：**把错误告诉模型，让它自己改**。
> 大部分情况下，它一次就能改对。

## 一、为什么模型会输出不合规的内容

不是"模型不行"，是**语言模型本质上是概率生成器**：

| 原因 | 说明 |
|---|---|
| 概率性 | 同样的输入，temperature > 0 时输出会变 |
| 长输出衰减 | 输出越长，后半段越容易漏字段 |
| 复杂 schema | 嵌套深、字段多时容易张冠李戴 |
| 上下文干扰 | 输入里有类似结构，模型会"抄" |
| 截断 | `max_tokens` 不够，JSON 被切断 |

最后一条特别常见：**JSON 被截断，`json.loads` 报 "Expecting ',' delimiter"**。

## 二、三层校验的位置

```
模型输出
   ↓
① 语法层：是不是合法 JSON？
   ↓
② 结构层：字段齐不齐、类型对不对？
   ↓
③ 业务层：值符不符合业务规则？
```

大多数方案只做了 ①②，③ 才是真正的防线。

```python
from pydantic import BaseModel, Field, field_validator
from enum import Enum

class Priority(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"

class Ticket(BaseModel):
    title: str = Field(min_length=3, max_length=50)
    priority: Priority
    assignee: str
    tags: list[str] = Field(default_factory=list, max_length=5)

    # ③ 业务层校验
    @field_validator("assignee")
    @classmethod
    def check_assignee(cls, v: str) -> str:
        if v not in KNOWN_ASSIGNEES:
            raise ValueError(f"负责人 {v} 不在团队名单里，可选：{KNOWN_ASSIGNEES}")
        return v

    @field_validator("title")
    @classmethod
    def check_title(cls, v: str) -> str:
        if "【" in v or "】" in v:
            raise ValueError("标题里不要带【】等装饰符号")
        return v.strip()
```

**校验信息写得越具体，模型改对的概率越高**——`不在团队名单里，可选：[...]` 比 `invalid assignee` 有用得多。

## 三、核心模式：错误回灌

```python
from pydantic import ValidationError

def generate_with_repair(llm, schema, prompt: str, max_attempts: int = 3):
    """生成 → 校验 → 失败就用错误信息重问"""

    conversation = [HumanMessage(prompt)]

    for attempt in range(1, max_attempts + 1):
        raw = llm.invoke(conversation).content

        try:
            return schema.model_validate_json(extract_json(raw))
        except (ValidationError, json.JSONDecodeError) as e:
            error_msg = str(e)

            if attempt == max_attempts:
                raise ValueError(f"重试 {max_attempts} 次仍失败：{error_msg}")

            # 把失败输出和错误信息都带回对话
            conversation += [
                AIMessage(content=raw),
                HumanMessage(content=f"""你的输出不符合要求，错误是：

{error_msg}

请**只输出修正后的 JSON**，不要任何解释、不要 markdown 代码块。原始要求：
{prompt}"""),
            ]

        # 每次重试降低温度
        llm = llm.bind(temperature=0)
```

三个关键设计：

1. **保留完整的失败上下文**——把错误的输出也放进对话，模型能看到自己错在哪；
2. **错误信息要具体**——Pydantic 的错误信息本身就很详细，直接用；
3. **重试时降温**——温度降到 0 减少随机性。

## 四、`extract_json`：先解决"格式污染"

模型经常在 JSON 外面包一层代码块或说明文字：

```python
def extract_json(text: str) -> str:
    """从模型输出里抠出 JSON 部分"""
    text = text.strip()

    # 1. 去掉 markdown 代码块
    if "```" in text:
        blocks = re.findall(r"```(?:json)?\s*(.*?)```", text, flags=re.S)
        if blocks:
            text = blocks[0].strip()

    # 2. 找第一个 { 或 [ 到最后一个 } 或 ]
    for open_ch, close_ch in (("{", "}"), ("[", "]")):
        start = text.find(open_ch)
        end = text.rfind(close_ch)
        if start != -1 and end > start:
            return text[start:end + 1]

    return text
```

**这一步能救回 80% 的"格式错误"**，剩下 20% 才是真的结构不对。

## 五、`OutputFixingParser`：LangChain 自带的方案

LangChain 提供了现成的修复解析器：

```python
from langchain.output_parsers import OutputFixingParser
from langchain_core.output_parsers import PydanticOutputParser

base_parser = PydanticOutputParser(pydantic_object=Ticket)

fixing_parser = OutputFixingParser.from_llm(
    parser=base_parser,
    llm=llm,                       # 用哪个模型修复（可以换个便宜的）
)

chain = prompt | llm | fixing_parser
result = chain.invoke(inputs)      # 自动修复
```

它的内部实现就是上面那套：**解析失败 → 把错误和原输出发给模型 → 重新解析**。

**什么时候用自带的，什么时候自己写？**

| 场景 | 选择 |
|---|---|
| 简单场景、快速验证 | `OutputFixingParser` ✅ |
| 需要业务层校验 | 自己写（要接自定义 validator） |
| 需要记录重试次数/成本 | 自己写 |
| 需要区分错误类型做不同处理 | 自己写 |

生产环境建议**自己写**——因为需要可观测性（重试率、失败原因分布）。

## 六、修复的边界：什么时候不该修

**修复不是万能的，有些错误该直接失败**：

```python
class RepairPolicy:
    RETRYABLE = (
        "Expecting ',' delimiter",       # JSON 语法
        "field required",                 # 缺字段
        "Input should be",                # 类型错
        "不在团队名单里",                  # 业务校验（可修正）
    )

    FATAL = (
        "guardrail_violation",            # 内容违规
        "context_length_exceeded",        # 超长（重试也没用）
        "insufficient_quota",             # 配额用尽
    )

def should_retry(error: str) -> bool:
    if any(f in error for f in RepairPolicy.FATAL):
        return False
    return any(r in error for r in RepairPolicy.RETRYABLE)
```

**关键区分**：错误是"模型能通过重写来修正的"，还是"跟模型写什么无关的"。

## 七、结构化输出 + 修复的组合

如果你用了 `with_structured_output`，模型侧已经保证格式，**但业务层校验依然要做**：

```python
structured = llm.with_structured_output(Ticket, include_raw=True)

def extract(text: str, attempts: int = 3):
    for i in range(attempts):
        out = structured.invoke(text)

        if out["parsing_error"] is None:
            try:
                # 业务层校验（Pydantic validator 会在这里触发）
                out["parsed"].model_validate(out["parsed"].model_dump())
                return out["parsed"]
            except ValidationError as e:
                text = f"""{text}

【上一次尝试失败】
你给出的 assignee 是 {out['parsed'].assignee}，但校验失败：{e}
请重新生成，注意 assignee 只能是 {KNOWN_ASSIGNEES} 里的值。"""
        else:
            text = f"{text}\n\n【上一次格式错误】{out['parsing_error']}"

    raise ValueError("多次尝试后仍失败")
```

注意：`with_structured_output` 已经在 **schema 层**做了约束（`Literal`、`Enum`），所以到业务层校验时的失败率会低很多。

## 八、做一个可复用的修复链

```python
from langchain_core.runnables import RunnableLambda

def repair_chain(schema, llm, max_attempts=3, on_retry=None):
    """返回一个 Runnable：输入 prompt，输出 schema 实例"""

    def _run(prompt: str):
        convo = [HumanMessage(prompt)]
        last_error = None

        for attempt in range(1, max_attempts + 1):
            raw = llm.invoke(convo).content
            try:
                result = schema.model_validate_json(extract_json(raw))
                if on_retry:
                    on_retry(success=True, attempts=attempt)
                return result
            except Exception as e:
                last_error = str(e)
                if on_retry:
                    on_retry(success=False, attempt=attempt, error=last_error)
                convo += [
                    AIMessage(raw),
                    HumanMessage(f"输出有误：{last_error}\n请只输出修正后的 JSON："),
                ]
                llm = llm.bind(temperature=0)

        raise ValueError(f"{max_attempts} 次尝试均失败，最后错误：{last_error}")

    return RunnableLambda(_run, name="repair_chain")
```

配合监控：

```python
stats = {"total": 0, "repaired": 0, "failed": 0}

def on_retry(success, attempts=1, error=None, **kw):
    stats["total"] += 1
    if success and attempts > 1:
        stats["repaired"] += 1
    elif not success and attempts >= 3:
        stats["failed"] += 1

chain = prompt | repair_chain(Ticket, llm, on_retry=on_retry)
```

跑一段时间后看：

```
总调用 10000，一次成功 9200（92%），重试修复 750（7.5%），最终失败 50（0.5%）
```

**"重试修复率"是个很好的健康指标**——它高说明你的 schema 或提示词还能优化。

## 九、减少修复需求：上游优化

修复是兜底，**减少失败率才是根本**：

| 手段 | 效果 |
|---|---|
| schema 加 `Literal`/`Enum` | 大幅减少取值错误 |
| 字段描述写清楚 | 减少漏填 |
| 少用深嵌套 | 减少张冠李戴 |
| 输出里不要"顺带解释" | 减少格式污染 |
| `max_tokens` 留足 | 避免截断 |
| temperature 降到 0.1 以下 | 提高一致性 |
| 复杂任务拆成多次调用 | 每次输出更短更准 |

**最有效的一招是"拆"**——一次输出 20 个字段，改成 4 次各输出 5 个字段，成功率高得多。

## 十、小结

```python
# 一次完整的"生成 → 校验 → 修复"循环
for attempt in range(max_attempts):
    raw = llm.invoke(convo)
    try:
        return schema.model_validate_json(extract_json(raw))
    except ValidationError as e:
        convo += [AIMessage(raw), HumanMessage(f"错误：{e}\n请修正：")]
        llm = llm.bind(temperature=0)
```

四个层次：

```
① extract_json   → 解决格式污染（救回 80%）
② Pydantic 校验  → 解决结构和类型
③ validator      → 解决业务规则
④ 错误回灌        → 让模型自己修
```

**记住一句话：模型的错误信息，对模型自己是最有用的输入。** 别把校验错误吞掉，把它还给模型。
