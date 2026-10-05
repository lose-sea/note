<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# Prompt 设计——Zero、Few-shot、CoT 与角色设定

**承上**：阶段 5 我们彻底拆开了大模型——注意力、位置编码、Transformer、分词、BERT 与 GPT、预训练目标。**模型已经"会接话"了**。

**本篇**：进入阶段 6。你会发现同样一个问题，换个问法结果天差地别。这一篇教你不改一个模型参数、只靠说话方式把它调教好的手艺：**Zero-shot / Few-shot / 思维链 / 角色设定**，并解决一个工程刚需——**让模型稳定输出可被程序解析的 JSON**。

**启下**：Prompt 写好了，怎么真正把它跑起来？下一篇《调用大模型 API——OpenAI 与国产模型，流式输出》用一套代码同时对接多家模型，并封装好重试、超时与流式打印。

**学完这一节，你能动手做**：

1. 按「角色 + 任务 + 约束 + 示例 + 输出格式」五段式写出稳定的 prompt
2. 判断什么场景该用 Zero-shot、Few-shot 还是 CoT
3. 让模型稳定输出 JSON，并写出带校验与重试的解析逻辑

---

## 一、Prompt 不是"问一句话"，而是"写一份需求文档"

新手最常见的错误是把 prompt 当成搜索框：

```
❌ 帮我写个排序算法
✅ 你是一位资深 Python 工程师。请实现一个快速排序函数。
   要求：
   1. 使用原地分区，空间复杂度 O(log n)
   2. 附带类型注解和 docstring
   3. 处理空列表和单元素列表
   输出：只返回 Python 代码，不要解释。
```

一个好的 prompt 是一份**需求文档**。推荐五段式结构：

```
┌────────────────────────────────────────┐
│ ① 角色设定   你是一位……                 │  限定知识领域与语气
│ ② 任务描述   请完成……                   │  说清要做什么
│ ③ 约束条件   要求：1. 2. 3.             │  边界、禁用项、风格
│ ④ 示例      输入… → 输出…（可选）        │  Few-shot，统一格式
│ ⑤ 输出格式   只返回 JSON / 代码 / 表格   │  让结果可被程序解析
└────────────────────────────────────────┘
```

**为什么"角色设定"有用？** 模型在预训练时读过海量"某领域专家写的文本"。当你说"你是一位资深 Python 工程师"，你实际上是在**把模型的输出分布往那类文本上引导**——它不是真的变成了工程师，但采样到的词会更贴近那个语境。

## 二、四种策略：什么时候用哪个

| 策略 | 做法 | 适用场景 | 代价 |
|---|---|---|---|
| **Zero-shot** | 直接说任务，不给示例 | 通用任务、模型能力范围内的 | 最省 token |
| **Few-shot** | 给 2~5 个"输入→输出"示例 | 格式特殊、风格固定、分类标签明确 | 消耗 token，但最稳 |
| **CoT（思维链）** | 要求"一步步思考后再给答案" | 数学、逻辑、多步推理 | 输出变长，成本上升 |
| **角色设定** | 指定身份与专业领域 | 需要领域术语、特定语气 | 几乎零成本 |

**经验法则**：

```
先试 Zero-shot
   ↓ 输出格式不稳定 → 加 Few-shot
   ↓ 结果算错了     → 加 CoT
   ↓ 语气/术语不对  → 加角色设定
   ↓ 还是不行       → 考虑微调（阶段 9）或 RAG（阶段 7）
```

### CoT 为什么有效？

因为**自回归模型不能"回头改"**。如果它第一句就跳到结论，错了就没机会修正。让它把中间步骤写出来，等于：

1. 把一步到位的难题，拆成多个简单子问题；
2. 每一步都能"看到"前面的推理，相当于给自己更多的计算机会；
3. 出错了你能**定位是哪一步错的**。

经典对比（同一个算术题）：

```
普通问法：
  问：一个书架有 3 层，每层放 15 本书，又买了 12 本放上去，现在一共几本？
  答：57        ← 错了（3×15+12 = 57，这次对了；但复杂题常错）

CoT 问法：
  问：……请一步步思考后再给出答案。
  答：
    第 1 步：3 层 × 每层 15 本 = 45 本
    第 2 步：45 + 新买的 12 本 = 57 本
    答案：57 本
```

> 现在的推理模型（如 DeepSeek-R1、Qwen3 的思考模式）已经把 CoT 内化了——它们会先输出一段"思考过程"再给答案。但原理一致：**中间步骤 = 更多的计算机会**。

## 三、代码实战 1：写一个可复用的 Prompt 构建器

把 prompt 当成代码来管理，而不是散落在业务里的字符串拼接。

```python
from dataclasses import dataclass, field
from typing import Optional

@dataclass
class PromptBuilder:
    """五段式 Prompt 构建器（呼应阶段 0 的面向对象那篇）。"""
    role: str = ""
    task: str = ""
    constraints: list[str] = field(default_factory=list)
    examples: list[tuple[str, str]] = field(default_factory=list)
    output_format: str = ""

    def set_role(self, role: str) -> "PromptBuilder":
        self.role = role
        return self                      # 返回自身，支持链式调用

    def set_task(self, task: str) -> "PromptBuilder":
        self.task = task
        return self

    def add_constraint(self, c: str) -> "PromptBuilder":
        self.constraints.append(c)
        return self

    def add_example(self, inp: str, out: str) -> "PromptBuilder":
        self.examples.append((inp, out))
        return self

    def set_output_format(self, fmt: str) -> "PromptBuilder":
        self.output_format = fmt
        return self

    def build(self) -> str:
        parts = []
        if self.role:
            parts.append(f"# 角色\n{self.role}")
        if self.task:
            parts.append(f"# 任务\n{self.task}")
        if self.constraints:
            body = "\n".join(f"{i}. {c}" for i, c in enumerate(self.constraints, 1))
            parts.append(f"# 要求\n{body}")
        if self.examples:
            demo = "\n\n".join(f"输入：{i}\n输出：{o}" for i, o in self.examples)
            parts.append(f"# 示例\n{demo}")
        if self.output_format:
            parts.append(f"# 输出格式\n{self.output_format}")
        return "\n\n".join(parts)


# ---------- 用法：一个"情感分类 + 理由"的 prompt ----------
p = (PromptBuilder()
     .set_role("你是一位中文情感分析专家。")
     .set_task("判断下列评论的情感倾向，并给出一句理由。")
     .add_constraint("情感只能是：正面 / 负面 / 中性，三者之一")
     .add_constraint("理由不超过 20 个字")
     .add_example("这家餐厅的牛排太老了，服务也慢。",
                  '{"label": "负面", "reason": "抱怨食材与服务"}')
     .add_example("物流很快，包装完好，满意。",
                  '{"label": "正面", "reason": "称赞物流与包装"}')
     .set_output_format('只返回一行 JSON：{"label": "...", "reason": "..."}，不要任何额外文字。'))

print(p.build())
print("\n" + "=" * 50 + "\n")

# ---------- 同一个构建器，切到 CoT 模式 ----------
p_cot = (PromptBuilder()
         .set_role("你是一位严谨的数学老师。")
         .set_task("解答下面的应用题。")
         .add_constraint("必须先列出每一步的计算过程")
         .add_constraint("最后一行以『答案：』开头给出最终结果")
         .set_output_format("分步骤的纯文本"))
print(p_cot.build())
```

运行结果（第一段）：

```
# 角色
你是一位中文情感分析专家。

# 任务
判断下列评论的情感倾向，并给出一句理由。

# 要求
1. 情感只能是：正面 / 负面 / 中性，三者之一
2. 理由不超过 20 个字

# 示例
输入：这家餐厅的牛排太老了，服务也慢。
输出：{"label": "负面", "reason": "抱怨食材与服务"}

输入：物流很快，包装完好，满意。
输出：{"label": "正面", "reason": "称赞物流与包装"}

# 输出格式
只返回一行 JSON：{"label": "...", "reason": "..."}，不要任何额外文字。
```

**这样管理 prompt 的好处**：可以版本化、可以做单元测试、可以针对不同模型切换模板，而不是在业务代码里到处拼字符串。

## 四、代码实战 2：让模型稳定输出 JSON（含校验与重试）

大模型输出 JSON 是个高频刚需，但模型经常多说废话（"好的，这是你要的 JSON：```json ..."）。解决方案是**三层防护**：

```python
import json
import re

def extract_json(text: str):
    """第 1 层：从任意文本里抠出 JSON（模型爱加 markdown 代码块和废话）。"""
    # 优先尝试直接解析
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    # 去掉 ```json ... ``` 标记
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if m:
        try:
            return json.loads(m.group(1).strip())
        except json.JSONDecodeError:
            pass
    # 找第一个 { 或 [ 到最后一个 } 或 ] 之间的内容
    for left, right in [("{", "}"), ("[", "]")]:
        s, e = text.find(left), text.rfind(right)
        if s != -1 and e != -1 and e > s:
            try:
                return json.loads(text[s:e + 1])
            except json.JSONDecodeError:
                continue
    return None


def validate(data: dict, schema: dict) -> list[str]:
    """第 2 层：按简单的类型/枚举 schema 校验。"""
    errors = []
    for key, rule in schema.items():
        if key not in data:
            errors.append(f"缺少字段 {key}")
            continue
        val = data[key]
        if "type" in rule and not isinstance(val, rule["type"]):
            errors.append(f"{key} 类型错误，期望 {rule['type'].__name__}")
        if "enum" in rule and val not in rule["enum"]:
            errors.append(f"{key} 取值 {val!r} 不在允许范围 {rule['enum']}")
        if "max_len" in rule and isinstance(val, str) and len(val) > rule["max_len"]:
            errors.append(f"{key} 超过最大长度 {rule['max_len']}")
    return errors


def call_with_retry(build_prompt, call_llm, schema, max_attempts=3):
    """第 3 层：校验失败就把错误信息回喂给模型，让它自我修正。"""
    messages = []
    for attempt in range(1, max_attempts + 1):
        raw = call_llm(build_prompt(messages))          # 伪函数：换成真实 API
        data = extract_json(raw)
        if data is None:
            messages.append("错误：你的输出不是合法 JSON，请只返回 JSON 本身。")
            continue
        errors = validate(data, schema)
        if not errors:
            return data, attempt
        messages.append("错误：" + "；".join(errors) + "。请修正后重新输出 JSON。")
    raise RuntimeError(f"{max_attempts} 次尝试后仍未得到合法输出")


# ---------- 测试第 1 层：模型常见的"脏输出" ----------
dirty_outputs = [
    '好的，这是结果：\n```json\n{"label": "正面", "reason": "物流快"}\n```',
    '{"label": "负面", "reason": "味道差"}（仅供参考）',
    '我认为应该输出：\n{"label": "中性", "reason": "没有明显情绪"}',
]
for t in dirty_outputs:
    print("脏输入 ->", repr(t[:38]), "\n  解析结果:", extract_json(t))

schema = {
    "label":  {"type": str, "enum": ["正面", "负面", "中性"]},
    "reason": {"type": str, "max_len": 20},
}
print("\n校验合法样例:", validate({"label": "正面", "reason": "物流快"}, schema))
print("校验非法样例:", validate({"label": "好评", "reason": "x" * 30}, schema))
```

运行结果：

```
脏输入 -> '好的，这是结果：\n```json\n{"label": "正面", "rea
  解析结果: {'label': '正面', 'reason': '物流快'}
脏输入 -> '{"label": "负面", "reason": "味道差"}（仅供参考）
  解析结果: {'label': '负面', 'reason': '味道差'}
脏输入 -> '我认为应该输出：\n{"label": "中性", "reason":
  解析结果: {'label': '中性', 'reason': '没有明显情绪'}

校验合法样例: []
校验非法样例: ['label 取值 '好评' 不在允许范围 ['正面', '负面', '中性'], reason 超过最大长度 20']
```

**自修正重试**是关键：把校验错误回喂给模型（"你的 label 取值『好评』不在允许范围…"），模型几乎总能在第 2 次就改对。这比自己写正则去修字符串靠谱得多。

> 进阶方案：现在主流模型都支持 **JSON Schema / Structured Output 模式**（OpenAI 的 `response_format={"type": "json_object"}`、Qwen 的结构化输出），能从采样层面保证格式。**能用原生约束就别靠提示词**。

## 五、常见坑与调优清单

| 坑 | 现象 | 解法 |
|---|---|---|
| Prompt 太模糊 | 输出发散、每次都不一样 | 加约束 + 加示例 |
| 示例太多 | token 暴涨、模型被示例带偏 | 3~5 个足够，且要覆盖边界情况 |
| 示例有倾向性 | 模型只输出示例里的那几类 | 示例要**均衡分布**各标签 |
| 只说"不要做什么" | 模型反而更容易做 | 说"要做什么"，正面描述 |
| 长 prompt 塞满细节 | 中间的关键指令被忽略 | 关键约束放**开头和结尾**（首尾效应） |
| 一次问太多事 | 丢三落四 | 拆成多轮，一件事一次说清 |
| 不设 temperature | 结果不稳定或过于死板 | 分类/抽取用 0~0.3；创意写作 0.7~1.0 |

**调优 checklist（按顺序走一遍）**：

```
1. 任务描述是否只有一个明确目标？
2. 是否有 3 条以上可验证的约束（而不是"要专业一点"）？
3. 输出格式是否给出了具体样例（而不是"用 JSON"）？
4. 示例是否覆盖了边界情况（空输入、超长输入、异常输入）？
5. 是否用 5~10 条真实数据测过，而不是只试一句话？
6. 是否需要把 temperature 调低？
```

## 六、本篇小结

1. **Prompt 是需求文档，不是搜索框**。五段式：角色 → 任务 → 约束 → 示例 → 输出格式。
2. **Zero-shot 打底，Few-shot 稳格式，CoT 提精度，角色设定调语气**。
3. **CoT 的本质**是把一步到位的难题拆成多个简单子问题，给模型更多"计算机会"。
4. 用 **PromptBuilder 把 prompt 当代码管理**，可版本化、可测试、可切换模板。
5. **结构化输出三层防护**：宽容解析 → schema 校验 → 错误回喂重试；能用模型原生的 JSON 模式就别靠提示词。

**下一篇**：Prompt 写得再好，也得跑起来才算数。下一篇《调用大模型 API——OpenAI 与国产模型，流式输出》从零封装一个健壮的客户端：**一套代码对接 OpenAI / DeepSeek / 通义 / 智谱**（只改 base_url 和 key），实现流式输出、超时重试、token 统计，并做成可复用的工程模块。

> 本篇是《大模型开发从 0 到 1》专栏第 34 篇，阶段 6「提示词工程与大模型 API」第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
