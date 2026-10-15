# 敏感信息脱敏：把手机号、身份证送进模型之前先处理掉

> 用户跟客服机器人说："我的身份证是 110101199001011234，帮我改下手机号 13812345678。"
>
> 这条消息会经过：你的服务器 → 模型服务商 → 日志系统 → trace 平台。
> **每一站都是一次泄露风险。**

## 一、先搞清楚：泄露发生在哪里

很多人只关注"发给模型"，实际链路长得多：

```
用户输入
  ↓
① 应用日志（log.info(f"收到消息：{text}")）
  ↓
② LangSmith / Trace 平台（记录每次调用的完整 prompt）
  ↓
③ 模型服务商（OpenAI、国内厂商，可能用于训练）
  ↓
④ 向量库（如果做了 RAG 存储）
  ↓
⑤ 会话历史（Redis / 数据库）
```

**①②③④⑤ 都要处理**，只做 ③ 是最常见的疏漏。

## 二、脱敏 vs 加密：先分清目的

| 方案 | 目的 | 模型能用吗 | 可逆 |
|---|---|---|---|
| 脱敏（Mask） | 移除或替换 | ✅ 能 | ❌ |
| 加密（Encrypt） | 保护存储和传输 | ❌ 不能（密文无意义） | ✅ |
| 令牌化（Tokenize） | 可逆替换 | ✅ 能 | ✅ |

**发给模型的必须是"脱敏"或"令牌化"**，加密后的密文模型读不懂。

**令牌化**是最实用的方案——用占位符替换，本地保留映射表，需要时还原。

## 三、基础实现：正则脱敏

```python
import re

PATTERNS = {
    "PHONE":      r"1[3-9]\d{9}",
    "ID_CARD":    r"\d{17}[\dXx]",
    "BANK_CARD":  r"\d{16,19}",
    "EMAIL":      r"[\w.+-]+@[\w-]+\.[\w.]+",
    "IP":         r"\b(?:\d{1,3}\.){3}\d{1,3}\b",
    "NAME_CN":    r"(?<=我是)[\u4e00-\u9fa5]{2,4}(?=，|。|\s|$)",
}

class Redactor:
    def __init__(self, patterns=None):
        self.patterns = patterns or PATTERNS
        self.mapping = {}          # 占位符 → 原值
        self.counter = {}

    def redact(self, text: str) -> str:
        for label, pattern in self.patterns.items():
            text = re.sub(pattern, lambda m: self._mask(label, m.group()), text)
        return text

    def _mask(self, label: str, value: str) -> str:
        self.counter[label] = self.counter.get(label, 0) + 1
        placeholder = f"<{label}_{self.counter[label]}>"
        self.mapping[placeholder] = value
        return placeholder

    def restore(self, text: str) -> str:
        for placeholder, value in self.mapping.items():
            text = text.replace(placeholder, value)
        return text
```

用起来：

```python
r = Redactor()
raw = "我的身份证是 110101199001011234，手机号 13812345678"
safe = r.redact(raw)
print(safe)
# "我的身份证是 <ID_CARD_1>，手机号 <PHONE_1>"

answer = llm.invoke(f"用户说：{safe}\n请确认信息是否正确。")
print(r.restore(answer))       # 还原成真实值再展示
```

**关键：还原只发生在"给用户看"的最后一步**，中间所有环节（日志、trace、向量库）存的是占位符。

## 四、给占位符加类型提示，帮助模型理解

纯 `<PHONE_1>` 模型不知道这是什么。加上语义：

```python
def _mask(self, label: str, value: str) -> str:
    self.counter[label] = self.counter.get(label, 0) + 1
    placeholder = f"[{LABELS[label]}_{self.counter[label]}]"
    ...
```

```python
LABELS = {
    "PHONE": "手机号",
    "ID_CARD": "身份证号",
    "EMAIL": "邮箱",
}
```

替换效果：

```
"我的身份证是 [身份证号_1]，手机号 [手机号_1]"
```

模型读到 `[身份证号_1]` 能正确理解为"这里有个身份证号"，回答时也会沿用这个占位符。

**注意：占位符要用 `[]` 或 `<>` 这种明显标记**，别用 `__PHONE__`——模型可能会把它当普通文本处理掉。

## 五、用 NER 处理正则抓不到的

正则只能抓格式化信息。"我叫张三，住北京市朝阳区"里的姓名和地址，正则无能为力。

方案一：**本地 NER 模型**（推荐，数据不出机器）

```python
from transformers import pipeline

ner = pipeline("ner", model="uer/roberta-base-finetuned-cluener2020-chinese",
               aggregation_strategy="simple")

def redact_ner(text: str) -> str:
    entities = ner(text)
    # 从后往前替换，避免位置偏移
    for ent in sorted(entities, key=lambda x: x["start"], reverse=True):
        if ent["entity_group"] in ("PER", "LOC", "ORG"):
            text = text[:ent["start"]] + f"[{TYPE_MAP[ent['entity_group']]}]" + text[ent["end"]:]
    return text
```

方案二：**用 LLM 做抽取**（准确但慢，且本身要把原文发给模型——需要先过一遍正则）

```python
from pydantic import BaseModel

class PII(BaseModel):
    text: str
    type: str
    start: int
    end: int

extractor = llm.with_structured_output(list[PII])

def find_pii(text: str) -> list[PII]:
    # ⚠️ 这里已经把原文发给模型了，所以必须先做一轮正则脱敏
    pre = Redactor().redact(text)
    return extractor.invoke(f"找出下面文本里的个人信息：\n{pre}")
```

**注意顺序**：LLM 抽取应该放在正则脱敏**之后**，否则等于把原始 PII 发给了模型。

## 六、脱敏要挂在 LangChain 的哪一层

**入口处脱敏，出口处还原**——用一个 Runnable 包住：

```python
from langchain_core.runnables import RunnableLambda

class RedactionRunnable(RunnableLambda):
    """在链的入口脱敏，出口还原"""
    def __init__(self, inner, patterns=None):
        self.redactor = Redactor(patterns)
        super().__init__(self._process)
        self.inner = inner

    def _process(self, x):
        raw = x["input"] if isinstance(x, dict) else x
        safe = self.redactor.redact(raw)
        out = self.inner.invoke({"input": safe, **({"extra": x["extra"]} if isinstance(x, dict) and "extra" in x else {})})
        return self.redactor.restore(out)
```

更实际的做法是**在 API 层做**，而不是在链里：

```python
@app.post("/chat")
async def chat(req: ChatRequest):
    redactor = Redactor()
    safe_text = redactor.redact(req.message)

    # 后续全部用 safe_text
    result = await chain.ainvoke({"input": safe_text})

    # 返回前还原
    return {"reply": redactor.restore(result)}
```

**理由**：脱敏是"数据治理"层面的关注点，不该混进业务链。放 API 层能保证**所有下游（日志、trace、模型）拿到的都是脱敏后的文本**。

## 七、日志和 Trace 是重灾区

最常见的泄露其实是**你自己打的日志**：

```python
# ❌ 泄露
log.info(f"用户 {user_id} 说：{message}")

# ✅ 先脱敏
log.info(f"用户 {user_id} 说：{redactor.redact(message)}")
```

LangSmith 也一样，默认会把完整输入输出上传。两种处理：

**方式一：改用本地 trace**（数据不出网）

```python
import os
os.environ["LANGCHAIN_TRACING_V2"] = "false"      # 关掉云端
# 或者指向自建的 Langfuse
os.environ["LANGFUSE_HOST"] = "http://internal-langfuse:3000"
```

**方式二：脱敏后再进链**——因为脱敏在 API 层已经做了，trace 里记录的自然就是脱敏后的文本。**这是"入口脱敏"的最大好处。**

## 八、向量库和会话历史

RAG 场景里，用户上传的文档可能含大量 PII：

```python
from langchain_core.documents import Document

def sanitize_documents(docs: list[Document]) -> list[Document]:
    r = Redactor()
    return [
        Document(page_content=r.redact(d.page_content),
                 metadata={**d.metadata, "pii_redacted": True})
        for d in docs
    ]
```

会话历史同理：

```python
def save_history(session_id: str, message: BaseMessage):
    if isinstance(message, HumanMessage):
        content = redactor.redact(message.content)      # 用户消息脱敏
    else:
        content = message.content                        # 模型输出本来就是占位符
    redis.rpush(f"history:{session_id}", json.dumps({"role": message.type, "content": content}))
```

**关键判断：用户消息必须脱敏后存储**；AI 回复因为是在脱敏文本上生成的，通常已经只含占位符。

## 九、还原的时机和边界

**只在"返给用户看"的时候还原**。而且要注意：

**① 不要还原到日志里。**

```python
# ❌ 还原后再打日志 = 白脱敏
log.info(f"回复用户：{redactor.restore(reply)}")

# ✅ 日志记脱敏版本
log.info(f"回复用户：{reply}")
```

**② 多轮会话要共用一份映射表。**

```python
class SessionRedactor:
    """按会话维护映射表，保证多轮之间占位符一致"""
    def __init__(self):
        self.sessions = defaultdict(Redactor)

    def get(self, session_id: str) -> Redactor:
        return self.sessions[session_id]

    def clear(self, session_id: str):
        self.sessions.pop(session_id, None)      # 会话结束清理
```

如果每轮都 new 一个 Redactor，第二轮说"把上面那个手机号改成 139..."时，模型拿着 `<PHONE_1>` 你也还原不出来。

**③ 及时销毁映射表。**
原始 PII 在内存里，会话结束就该清掉。设一个 TTL：

```python
SESSION_TTL = 3600 * 2      # 2 小时
```

## 十、几个容易踩的坑

**① 正则顺序很重要。**
`ID_CARD` 的 18 位数字会被 `BANK_CARD`（16-19 位）抢先匹配。**长模式放前面**，或者用更精确的边界。

**② 别用 `\d{11}` 匹配手机号。**
会把身份证号、订单号的一部分也匹配掉。用 `1[3-9]\d{9}` 并加边界：

```python
r"(?<!\d)1[3-9]\d{9}(?!\d)"
```

**③ 脱敏后要检查"是否还能回答问题"。**
把什么都替换掉，模型就没法干活了。比如客服场景要判断"这个手机号格式对不对"，那就得保留部分信息：

```python
def mask_phone_keep_prefix(value: str) -> str:
    return value[:3] + "****" + value[-2:]     # 138****78
```

**④ 模型可能"猜"出被脱敏的内容。**
如果上下文里说"用户 1990 年出生，身份证是 [身份证号_1]"，模型可能根据日期猜出前几位。**做严格脱敏时，要连相关的推理线索一起处理。**

**⑤ 别忘了流式输出的还原。**
流式场景下，占位符可能被切成两半（`[手机` + `号_1]`），逐 chunk 还原会失败。**要按句子缓冲后再还原**。

## 十一、小结

```python
# 1. 入口脱敏
safe = redactor.redact(user_input)

# 2. 全流程用 safe 版本（日志、trace、模型、存储）

# 3. 出口还原
return redactor.restore(answer)
```

三层防线：

```
第一层：正则      → 手机号、身份证、银行卡、邮箱
第二层：NER       → 姓名、地址、机构名
第三层：LLM 抽取  → 兜底（但必须放在正则之后）
```

**核心原则：真实数据只在"用户输入"和"用户输出"两个端点出现，中间全链路只见占位符。** 这样即使中间某一环被击穿，泄露的也只是 `<PHONE_1>`。
