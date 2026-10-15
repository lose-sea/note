# Prompt 的 partial：把固定变量提前填好，减少调用时的噪音

> 你写了条提示词，里面 6 个变量。
> 其中 3 个在整条链里是固定的（公司名、产品名、输出语言），
> 另外 3 个才是每次调用变的。
>
> 每次调用都要把这 6 个变量拼一遍——**这是可以省掉的**。

## 一、问题：变量混在一起

```python
prompt = ChatPromptTemplate.from_template("""
你是 {company} 的 {product} 技术支持。

回答语言：{language}
回答风格：{style}

用户问题：{question}
""")
```

每次调用：

```python
chain.invoke({
    "company": "某科技",
    "product": "云盘",
    "language": "简体中文",
    "style": "简洁、直接",
    "question": "怎么退款？",
})
```

前四个在整条链的生命周期内不会变。每次都要传，是纯粹的噪音——**而且很容易漏传或传错**。

## 二、`partial`：把固定的部分提前填进去

```python
base_prompt = ChatPromptTemplate.from_template("""
你是 {company} 的 {product} 技术支持。

回答语言：{language}
回答风格：{style}

用户问题：{question}
""")

# 一次性填掉固定变量
company_prompt = base_prompt.partial(
    company="某科技",
    product="云盘",
    language="简体中文",
    style="简洁、直接",
)

# 调用时只需要传剩下的
chain = company_prompt | llm | StrOutputParser()
chain.invoke({"question": "怎么退款？"})
```

**`partial` 返回的是一个新的 prompt 对象**，原对象不变。这点很重要——可以基于同一个模板派生多套：

```python
support_prompt = base_prompt.partial(style="简洁、直接", language="简体中文")
marketing_prompt = base_prompt.partial(style="热情、有感染力", language="简体中文")
en_prompt = base_prompt.partial(language="English", style="concise")
```

## 三、混用：`partial` 之后还能继续传

```python
p1 = base_prompt.partial(company="某科技")
print(p1.input_variables)
# ['product', 'language', 'style', 'question']

p2 = p1.partial(product="云盘")
print(p2.input_variables)
# ['language', 'style', 'question']
```

`input_variables` 会**随着 partial 逐步减少**，这可以用来做校验：

```python
def build_chain(prompt, required):
    missing = set(required) - set(prompt.input_variables)
    if missing:
        raise ValueError(f"这些变量已被 partial 固定，不能再传：{missing}")
    return prompt | llm
```

**Partial 是单向的**——填进去的变量不能再在后面覆盖（除非用另一个 prompt 重新构造）。所以顺序要设计好：**先固定最不变的，再固定次不变的。**

## 四、函数形态的 partial：动态填充

`partial` 的值不一定是常量，也可以是函数：

```python
from datetime import datetime

def now_str():
    return datetime.now().strftime("%Y-%m-%d %H:%M")

prompt = ChatPromptTemplate.from_template("""
当前时间：{current_time}
用户问题：{question}
""").partial(current_time=now_str)      # 传函数，不是调用
```

**每次 `invoke` 时都会重新调用这个函数**，所以时间是最新的。

甚至可以传一个接收变量的函数：

```python
def upper_if_needed(x):
    return x.upper() if len(x) < 10 else x

prompt = template.partial(question=upper_if_needed)
```

不过这种用法会让 input_variables 变得不透明，**建议只用于最简单的场景**。

## 五、partial 最实际的用途：消息列表

`ChatPromptTemplate` 的 messages 形态下，partial 特别有用：

```python
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.messages import SystemMessage

prompt = ChatPromptTemplate.from_messages([
    ("system", "你是 {company} 的客服，遵循以下规则：\n{rules}"),
    MessagesPlaceholder("history"),
    ("human", "{question}"),
])

# 规则文本很长，提前固化
RULES = """
1. 不确定的不要编造，直接说不确定
2. 涉及价格、退款、账号安全的问题，引导到人工
3. 不要承诺任何时限
4. 回答控制在 200 字以内
"""

fixed = prompt.partial(company="某科技", rules=RULES)
```

这样**长文本（规则）只写一次**，调用方完全不用关心。

## 六、把 partial 用在"系统提示 + 用户提示"分离

一个常见需求：系统提示要长而详细，用户提示要短。

```python
SYSTEM = """你是一位资深 Python 代码审查员。

审查维度：
- 正确性：边界条件、异常处理
- 可读性：命名、注释、函数长度
- 性能：不必要的循环、重复计算
- 安全：注入、越权、敏感信息泄露

输出格式：按「严重问题 / 建议改进 / 可选优化」三段列出，每条给出代码行号和修改建议。
"""

review_prompt = ChatPromptTemplate.from_messages([
    ("system", SYSTEM),
    ("human", "请审查下面的代码：\n\n```python\n{code}\n```"),
])

chain = review_prompt | llm
```

这里其实**不需要 partial**——`system` 里没有变量就是常量。

但如果你有多个审查员角色，就可以用 partial 复用同一个骨架：

```python
SKELETON = ChatPromptTemplate.from_messages([
    ("system", "你是{role}。\n\n你的关注点：{focus}\n\n输出格式：{format}"),
    ("human", "{input}"),
])

security_reviewer = SKELETON.partial(
    role="安全工程师",
    focus="注入、越权、敏感信息、依赖漏洞",
    format="按风险等级列出，每条给出复现思路",
)
```

**一套骨架，多套人设。** 这是 partial 最有价值的用法。

## 七、partial 与 LCEL 结合：做一个"提示词工厂"

```python
def make_chain(role: str, focus: str, company: str):
    return SKELETON.partial(role=role, focus=focus, company=company) | llm | StrOutputParser()

reviewer = make_chain("代码审查员", "正确性和可读性", "某科技")
auditor = make_chain("合规审计员", "数据处理合规性", "某科技")

print(reviewer.invoke({"input": code}))       # 同一份输入，两个角色
print(auditor.invoke({"input": code}))
```

**同一份输入，不同角色 → 天然的多视角评审。**

## 八、几个坑

**① partial 填了但模板里没这个变量。**

```python
template.partial(whoops="x")     # 模板里没有 {whoops}
```

不会有明显报错（不同版本行为不同），但在某些版本里会静默忽略。**建议先检查 `input_variables`。**

**② partial 之后 `format` 少了变量。**

```python
p = template.partial(a=1)
p.format(b=2)        # 如果模板还有 {c}，这里会报 KeyError
```

这是好事——**提前暴露问题**。但如果你在 partial 时漏了某个变量，要到运行时才发现。

**③ 用 partial 隐藏了变量，导致可读性下降。**

```python
chain.invoke({"question": "..."})       # 这样很好
chain.invoke({})                         # 这样就要翻代码才知道用了什么
```

调用点看不到信息时，**加一层包装函数**：

```python
def ask(question: str):
    """向客服助手提问。company/product/language 已固化。"""
    return chain.invoke({"question": question})
```

## 九、partial 的边界：什么时候不该用

**不该用 partial 的情况**：

- 变量值来源于**运行时上下文**（用户 ID、会话 ID）——这些应该走 `RunnableConfig` 的 `configurable`，而不是 partial；
- 变量**每个用户不同**——partial 是"构造时固定"，不是"每次注入"；
- 需要**动态切换**的——考虑 `configurable_fields`。

对于"按租户切换配置"这个需求，正确做法是用 `configurable`：

```python
from langchain_core.runnables import ConfigurableField

prompt = base_prompt.configurable_fields(
    style=ConfigurableField(id="reply_style"),
)

prompt.invoke({"question": "..."}, config={"configurable": {"reply_style": "幽默"}})
```

**区别记住一句话：partial 是"构造期固定"，configurable 是"调用期可变"。**

## 十、小结

```python
prompt.partial(a="固定值")              # 填常量
prompt.partial(now=datetime.now)       # 填函数（每次调用求值）
prompt.partial(**config)               # 批量填
```

三个使用场景：

1. **变量太多**——把固定的那部分收进 partial，调用点只传变化的；
2. **一套骨架多种人设**——partial 不同的人设参数，派生多条链；
3. **长文本固化**——规则、格式说明这类长内容只写一次。

**核心思想：让调用点尽可能少知道细节。** 调用方只该关心"这次要处理什么"，不该关心"公司叫什么名字"。
