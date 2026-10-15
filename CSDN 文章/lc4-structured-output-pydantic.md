# Pydantic 结构化输出实操：嵌套模型、枚举和字段描述怎么写

> 上一篇讲了"什么时候用结构化输出"。
> 这篇讲**怎么写 schema**——
> 同样的模型，schema 写得好和写得烂，成功率能从 60% 提到 99%。

## 一、从一个"不好用"的 schema 说起

```python
class Bad(BaseModel):
    type: str
    data: dict
    score: float
```

问题在哪？

- `type` 没有任何约束，模型会返回 `"news"` / `"新闻"` / `"NEWS"` 各种形式；
- `data` 是裸 `dict`，模型不知道要放什么，经常返回空；
- `score` 没说范围，可能返回 `95`（以为满分 100）或者 `"高"`。

**schema 是给模型的说明书。** 说明书写得含糊，模型就只能猜。

## 二、约束类型：用 `Literal` 而不是 `str`

```python
from typing import Literal
from pydantic import BaseModel, Field

class Good(BaseModel):
    category: Literal["tech", "finance", "sports", "other"] = Field(
        description="文章分类，只能从这四个里选"
    )
```

`Literal` 会在 JSON Schema 里生成 `enum`，很多模型原生支持 enum 约束——**从"模型尽量选对"变成"模型只能选这几个"**。

对于会演化的枚举，用 Python `Enum` 更好：

```python
from enum import Enum

class Category(str, Enum):
    TECH = "tech"
    FINANCE = "finance"
    SPORTS = "sports"
    OTHER = "other"

class Article(BaseModel):
    category: Category
```

继承 `str` 是必须的，否则序列化时可能出问题。

## 三、嵌套模型：把复杂结构拆开

不要用裸 `dict`。拆成子模型：

```python
class Author(BaseModel):
    name: str = Field(description="作者姓名，中文全名")
    email: str | None = Field(default=None, description="邮箱，没有就填 null")

class Tag(BaseModel):
    name: str = Field(description="标签名，2-6 个字")
    weight: float = Field(description="权重，0 到 1 之间", ge=0, le=1)

class Article(BaseModel):
    title: str = Field(description="文章标题，不超过 30 字")
    summary: str = Field(description="摘要，50-100 字")
    author: Author
    tags: list[Tag] = Field(description="3-5 个标签", min_length=1, max_length=5)
    published_at: str = Field(description="发布日期，格式 YYYY-MM-DD")
```

**嵌套层级建议不超过 3 层。** 再深模型就容易漏字段或者张冠李戴。

## 四、可选字段：`Optional` 的坑

```python
class Item(BaseModel):
    name: str
    price: float | None = None      # ✅ 明确可为空
```

三个注意点：

**① `Optional[X]` 一定要给默认值**，否则 Pydantic 认为它是必填的（只是允许值为 null）。

**② 别滥用 Optional。**
如果 80% 的情况都为空，说明这个字段设计有问题——考虑拆成两个模型。

**③ 模型倾向于"凑答案"而不是返回 null。**
如果提示词里说"没有就填 null"，模型经常编一个。要在 `description` 里强调：

```python
phone: str | None = Field(
    default=None,
    description="联系电话。**如果原文中没有明确出现电话，必须填 null，不要编造**"
)
```

## 五、字段描述（description）的写法

`description` 是投入产出比最高的一环。写法规则：

| 写什么 | 例子 |
|---|---|
| 取值范围 | "0 到 1 之间的浮点数" |
| 格式 | "格式为 YYYY-MM-DD，如 2026-01-15" |
| 边界情况 | "原文没提到时填 null" |
| 反例 | "不要包含单位，只填数字部分" |

反例特别有用：

```python
class Product(BaseModel):
    name: str = Field(description="商品名。去掉品牌前缀，只保留品类名，如「无线鼠标」而不是「罗技无线鼠标」")
    price: float = Field(description="价格，单位元。只填数字，不要带「¥」或「元」")
    stock: int = Field(description="库存数量。如果原文没有提及库存，填 -1")
```

## 六、用 `Field` 做值域约束

```python
from pydantic import BaseModel, Field

class Review(BaseModel):
    rating: int = Field(ge=1, le=5, description="评分，只能是 1 到 5 的整数")
    confidence: float = Field(ge=0.0, le=1.0, description="置信度")
    comment: str = Field(min_length=1, max_length=200, description="评论内容")
    tags: list[str] = Field(max_length=5, description="最多 5 个标签")
```

这些约束会**写进 JSON Schema**，支持原生结构化输出的模型会严格遵守。

## 七、用 `model_validator` 做跨字段校验

有些规则不能靠单字段约束表达：

```python
from pydantic import model_validator

class DateRange(BaseModel):
    start: str = Field(description="开始日期 YYYY-MM-DD")
    end: str = Field(description="结束日期 YYYY-MM-DD")

    @model_validator(mode="after")
    def check_order(self):
        if self.start > self.end:
            raise ValueError("开始日期不能晚于结束日期")
        return self
```

注意：**`model_validator` 抛的错会变成解析失败**。配合"错误回灌"（把错误信息发给模型让它重试），能显著提升复杂场景的成功率：

```python
def extract_with_repair(text: str, model, schema, retries=2):
    raw = model.with_structured_output(schema, include_raw=True).invoke(text)
    if not raw["parsing_error"]:
        return raw["parsed"]

    for _ in range(retries):
        fix = llm.invoke(f"""上一次输出不符合要求，错误是：
{raw['parsing_error']}

上一次的输出是：
{raw['raw'].content}

请修正后重新输出。原文：{text}""")
        raw = model.with_structured_output(schema, include_raw=True).invoke(fix.content)
        if not raw["parsing_error"]:
            return raw["parsed"]
    raise ValueError("多次重试仍失败")
```

## 八、Union 与判别式

需要"多种可能结构"时，用**带判别式的 Union**：

```python
from typing import Annotated, Union
from pydantic import Field

class TextBlock(BaseModel):
    kind: Literal["text"]
    content: str

class TableBlock(BaseModel):
    kind: Literal["table"]
    headers: list[str]
    rows: list[list[str]]

class ImageBlock(BaseModel):
    kind: Literal["image"]
    url: str
    caption: str | None = None

Block = Annotated[Union[TextBlock, TableBlock, ImageBlock], Field(discriminator="kind")]

class Document(BaseModel):
    blocks: list[Block]
```

`discriminator="kind"` 是关键——它让 schema 里出现 `oneOf` + `discriminator` 的清晰结构，模型知道要按 `kind` 挑一个。

**没有判别式的 Union 是灾难**：模型分不清该用哪个，会返回字段混搭的结果。

## 九、别把"解释"混进数据

一个常见错误：

```python
class Bad(BaseModel):
    answer: str = Field(description="答案")
    explanation: str = Field(description="解释为什么")
```

如果下游只要答案，`explanation` 就是噪声。更糟的是——**模型会为了填 `explanation` 而编造理由**。

正确做法是用**两段式**：

```python
# 第一次：先思考
thinking = llm.invoke(f"分析下面的问题，说明你的推理过程：{question}")

# 第二次：只输出结构化结果，把思考作为上下文
result = structured_llm.invoke(f"""基于以下分析，给出最终结论。

分析过程：
{thinking.content}

原始问题：{question}""")
```

这叫 **"思维链与输出分离"**——思考归思考，数据归数据。

## 十、复杂 schema 的调试方法

schema 不好用时，按这个顺序排查：

**① 打印真实的 JSON Schema**

```python
import json
print(json.dumps(Article.model_json_schema(), ensure_ascii=False, indent=2))
```

看它实际生成了什么。很多问题（比如 `$ref` 嵌套、`anyOf` 混乱）在 schema 层面就能看出来。

**② 用小样本测成功率**

```python
cases = ["...", "...", "..."]     # 10 个典型输入
ok = sum(1 for c in cases if try_extract(c))
print(f"成功率：{ok}/{len(cases)}")
```

**③ 看 `parsing_error` 的具体内容**

```python
out = llm.with_structured_output(Article, include_raw=True).invoke(text)
print(out["parsing_error"])     # 这里能看到是哪个字段错了
```

**④ 判断是"模型不行"还是"schema 不清"**

把同一个 schema 换成更强的模型（如 GPT-4o）跑一遍：

- 强模型也错 → schema 设计有问题；
- 强模型对、弱模型错 → 是模型能力问题，考虑加错误回灌。

## 十一、小结

写结构化输出 schema 的优先级排序：

```
1. 用 Literal/Enum 锁取值范围       ← 收益最大
2. 写清楚每个字段的 description      ← 成本最低
3. 拆嵌套模型，别用裸 dict          ← 结构清晰
4. 用 Field 加值域约束              ← 便宜保险
5. 跨字段规则用 model_validator      ← 处理复杂规则
6. 配错误回灌                        ← 兜底
```

一句话：**把 schema 当作给模型的 API 文档来写。** 文档写得清楚，调用方（模型）才不会出错。
