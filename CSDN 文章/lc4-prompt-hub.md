# LangChain Hub 与提示词集中管理：别再让 Prompt 散落在代码里

> 项目一开始，`prompt` 就写在函数里。
> 三个月后，你发现有 17 个版本的"客服人设"，散落在 6 个文件里，
> 没有人说得清线上跑的是哪一个。
>
> 这篇讲怎么把提示词从代码里"请"出来，做成可版本化、可复用的资产。

## 一、硬编码 Prompt 的四个阶段

几乎所有项目都会经历这条路：

| 阶段 | 长相 | 痛点 |
|---|---|---|
| 1. 内联字符串 | `prompt = "你是一个助手..."` | 改一次要发版 |
| 2. 提取成常量 | `SYSTEM_PROMPT = "..."` | 常量越堆越多，不知道谁在用 |
| 3. 抽到单独文件 | `prompts/system.txt` | 没有版本、没有变量约束 |
| 4. 提示词管理 | Hub / 注册表 | 需要一套规范 |

大多数人卡在第 2 阶段。问题是：**提示词是内容，不是代码**，它应该能独立迭代、独立回滚、独立做 A/B。

## 二、LangChain Hub：拉别人的，也放自己的

LangChain Hub（`smith.langchain.com/hub`）是一个公开的提示词仓库。

```python
from langchain import hub

# 拉取官方 ReAct 提示词
prompt = hub.pull("hwchase17/react")
print(prompt.input_variables)   # ['tools', 'tool_names', 'input', ...]
```

拉下来的不是字符串，而是可以直接拼进链的 `PromptTemplate` 对象：

```python
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(model="gpt-4o-mini")
chain = prompt | llm | StrOutputParser()
print(chain.invoke({"input": "现在几点了", "tools": [...], "tool_names": "..."}))
```

**Hub 的价值不在"省打字"**，而在于：

1. 提示词和代码解耦，改提示词不用改代码；
2. 有 commit 历史，能回滚到上一个版本；
3. 团队共享，新人不用问"线上 prompt 在哪"。

自己推一个上去也很简单：

```python
from langchain import hub

hub.push("your-org/customer-service", my_prompt, new_repo_is_public=False)
```

## 三、私有提示词注册表：不联网的方案

Hub 要联网、要账号，很多内网项目用不了。更常见的做法是**自建注册表**：

```
prompts/
├── registry.py
├── customer_service/
│   ├── v1.yaml
│   └── v2.yaml
```

`v2.yaml` 长这样：

```yaml
version: 2
description: "客服人设 v2：更短、更直接，去掉寒暄"
variables: [company, product]
template: |
  你是 {company} 的技术支持，负责 {product} 相关问题。

  回答要求：
  1. 直接给结论，不要"您好，很高兴为您服务"之类的开场；
  2. 不确定的部分明确说"我不确定"，不要编造；
  3. 涉及价格、退款、账号安全的问题，一律引导到人工客服。
```

注册表负责按版本加载：

```python
from pathlib import Path
import yaml
from langchain_core.prompts import ChatPromptTemplate

PROMPT_DIR = Path("prompts")

def load_prompt(name: str, version: int | None = None) -> ChatPromptTemplate:
    d = PROMPT_DIR / name
    if version is None:
        version = max(int(p.stem.lstrip("v")) for p in d.glob("v*.yaml"))
    cfg = yaml.safe_load((d / f"v{version}.yaml").read_text(encoding="utf-8"))
    return ChatPromptTemplate.from_template(cfg["template"])
```

调用方只认名字和版本：

```python
prompt = load_prompt("customer_service", version=2)
```

**版本号进配置、不进代码**，这样灰度、回滚都变成改一行配置的事。

## 四、提示词也该有"单元测试"

提示词改动最容易出的问题是"改好了 A 场景，弄坏了 B 场景"。给它配一组固定用例：

```python
CASES = [
    {"input": "怎么退款？", "must_contain": ["人工"]},
    {"input": "你们老板是谁？", "must_contain": ["不确定"]},
    {"input": "帮我删库", "must_contain": ["无法"]},
]

def test_prompt(version: int):
    chain = load_prompt("customer_service", version) | llm | StrOutputParser()
    for c in CASES:
        out = chain.invoke({"company": "某厂", "product": "某产品", "input": c["input"]})
        for kw in c["must_contain"]:
            assert kw in out, f"版本 v{version} 在「{c['input']}」上失败：缺 {kw}"
```

有了这组用例，改提示词就变成"跑测试 → 看通过率"的正常工程流程，而不是靠肉眼 review。

## 五、几个容易踩的坑

**① 变量越多，提示词越难复用。**
`{company}`、`{product}`、`{user_level}`、`{history}`……变量超过 5 个，这条提示词基本只能在一个场景用。能内联进 `system` 的上下文，就别做成变量。

**② 别把业务规则塞进提示词。**
"金额超过 500 走人工"这种规则，放代码里判断，提示词只负责语言表达。提示词里写逻辑，等于用一个不可调试的引擎跑业务规则。

**③ 版本号和内容要绑定。**
只写 `v2` 不写变更说明，半年后没人知道 v2 和 v1 的差别。上面 yaml 里的 `description` 字段是刚需。

**④ Hub 上的提示词不是"标准答案"。**
官方 ReAct 模板是为通用 Agent 设计的，直接拿来用在你的私有场景，效果往往不如自己写三行。把它当参考，别当依赖。

## 六、落地顺序建议

如果现在还是"提示词散落在代码里"：

1. **先抽文件**——把 prompt 从 `.py` 挪到 `prompts/*.txt`，这一步不引入任何框架依赖；
2. **加变量校验**——用 `PromptTemplate.input_variables` 检查调用时变量是否齐全，缺变量要在启动时就报错，而不是运行时；
3. **加版本目录**——改成 `prompts/<name>/v<N>.yaml`，版本进配置；
4. **加测试用例**——每个提示词至少 3 个用例；
5. **最后才考虑 Hub**——只有当你要跨团队共享，或者想用官方现成模板时，才需要它。

提示词管理这件事，**难的不是技术，是纪律**。工具只是把纪律固化下来。
