# Agentic RAG 实战：让 Agent 自己决定怎么检索、检索几次

传统 RAG 是一条流水线：查询 → 检索 → 拼 prompt → 生成，一步都不能少、一步都不会多。现实里的问题可没这么规矩："对比 A 和 B 的优缺点，再结合去年财报下结论"——这种查询需要先查 A、再查 B、发现财报数字不够再补一轮、最后综合。流水线结构答不了它，Agentic RAG 可以：**把检索从固定步骤变成 Agent 的可选动作，由模型自己决定检索什么、检索几次、什么时候收手**。这篇文章讲透它和传统 RAG 的边界、怎么搭、以及最容易翻车的三个地方。

## 一、从流水线到循环：范式差异

把两种结构并排放，一眼看懂：

```
传统 RAG（固定管线）：
用户问题 → 检索一次 → prompt 组装 → LLM 生成 → 答案
           ↑ 无论问题难易，都是这一步，一次检索

Agentic RAG（控制循环）：
用户问题 → Agent 主循环：
             ├─ 思考：我现在缺什么信息？
             ├─ 行动：调检索工具（关键词/向量/时间过滤…）
             ├─ 观察：拿到结果，够了吗？
             └─ 循环 或 生成最终答案
```

核心差异不是"用了 Agent"这个形式，而是**三个控制权转移**：

| 控制权 | 传统 RAG | Agentic RAG |
|---|---|---|
| 检索什么 | 用户原始查询 | Agent 改写后的子查询 |
| 检索几次 | 固定一次 | 动态，视信息缺口而定 |
| 何时停 | 检索完就生成 | Agent 判断信息够了才生成 |

**什么时候需要 Agentic RAG**：问题本身是复合的（多实体、多步骤）、答案需要迭代收敛（先粗后细）、或者查询意图一开始不明确（要拆解）。简单事实查询用 Agentic 是杀鸡用牛刀——还更贵更慢。

## 二、最小实现：一个带工具的检索 Agent

用 OpenAI Function Calling 搭一个最小可用版本：

```python
from openai import OpenAI

client = OpenAI()

TOOLS = [{
    "type": "function",
    "function": {
        "name": "search_docs",
        "description": "在企业知识库中检索相关文档。输入具体查询词，返回相关段落",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "检索查询词"},
                "year": {"type": "integer", "description": "限定年份，可选"},
            },
            "required": ["query"]
        }
    }
}]

def agent_answer(question, max_steps=5):
    messages = [{"role": "system", "content": """你是知识库问答助手。
规则：
1. 先用 search_docs 查最关键的实体，不要一次查太宽
2. 每轮观察结果，缺什么补什么，不要重复查同样的内容
3. 信息够了直接给答案，答案必须标注引用来源
4. 最多查 %d 次，超了就基于已有信息作答""" % max_steps},
                {"role": "user", "content": question}]

    for step in range(max_steps):
        resp = client.chat.completions.create(
            model="gpt-4o", messages=messages,
            tools=TOOLS, tool_choice="auto"
        )
        msg = resp.choices[0].message
        messages.append(msg)

        if not msg.tool_calls:
            return msg.content   # 没有工具调用 = 给出最终答案

        for tc in msg.tool_calls:
            if tc.function.name == "search_docs":
                args = json.loads(tc.function.arguments)
                results = rag_search(args["query"], year=args.get("year"))
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": format_results(results)
                })
    return "已达最大检索步数，基于已有信息作答..."
```

跑起来的行为链：

```
用户：对比 A、B 两家公司 2026 年的营收增速，并分析原因
Step1: search_docs("A公司 2026 营收")
Step2: search_docs("B公司 2026 营收")
Step3: search_docs("A公司 增长 原因 新产品")
Step4: search_docs("B公司 增长 放缓 竞争")
Step5: （信息够了）生成答案，带四段引用
```

**五个工具调用全部由模型自己发起**，查询词也是自己改写的。这就是 Agentic RAG 的最小形态。

## 三、工具设计：检索能力的拆法

Agent 的能力上限 = 工具集的质量。检索工具拆分的原则是**和用户问题的常见维度对齐**，而不是把整个检索系统塞一个工具里：

| 工具 | 职责 | 适用维度 |
|---|---|---|
| `search_semantic` | 向量语义检索 | 概念、主题类查询 |
| `search_keyword` | BM25 精确匹配 | 型号、代码、专有名词 |
| `search_structured` | SQL/元数据过滤（时间、部门、类型） | 带明确约束的查询 |
| `get_document` | 按 ID 取全文/章节 | 二次深挖（看全上下文） |
| `search_graph` | 图谱关系查询 | 多跳关系问题 |

**关键设计：工具描述（description）就是 Agent 的路由指南。** 写得含糊，Agent 就乱选；写清楚"什么时候用这个"，准确率立刻上一个台阶。比如：

```
# 差
description: 检索文档

# 好
description: 对知识库做语义相似度检索，返回最相关的 5 个段落。
适合概念性、描述性问题。不要用它查精确的型号/编号/代码——
那些请用 search_keyword。返回格式为带 [1][2] 编号的段落列表。
```

**再强调一遍：工具描述不是文档，是 prompt 工程。**每个工具的参数、返回格式、适用边界、不适用场景，都要写在 description 里。

## 四、三个最容易翻车的地方

### 4.1 无限循环与重复检索

Agent 抽风的表现：反复搜同一个词、或者在"信息不够"的错觉里出不来。**必须有硬性护栏**：

```python
MAX_STEPS = 5              # 最多工具调用轮数
MAX_SAME_QUERY = 2         # 同一查询词最多出现 2 次
```

超限后强制进入生成（prompt 里注明"已达步数上限，基于现有信息作答"）。**护栏不是限制能力，是防止一次故障烧掉几百次 API 调用。**

### 4.2 检索结果不可控地撑爆上下文

Agent 循环 5 轮、每轮 5 个 chunk、每 chunk 500 字 = 一万多字塞进上下文，token 费用爆炸而且生成质量反而下降。控制手段：

1. **单轮结果限量**：每轮最多 3~5 个 chunk，宁可多轮；
2. **结果压缩**：工具返回的不是全文，是"编号 + 摘要（一两百字）"，Agent 要深挖再调 `get_document` 取全文；
3. **历史结果滑窗**：超过 N 轮的旧结果压缩成一句总结，原文丢掉；
4. **token 预算硬顶**：上下文接近上限时强制收尾。

### 4.3 幻觉引用

Agentic RAG 的引用标注比传统 RAG 更容易出错——模型在多轮交织的信息里，可能把 [1] 的结论安到 [3] 头上。缓解：

- 引用强制格式：`生成规则：每个论断后用 [n] 标注来源，n 必须是本轮或历史工具返回中出现过的编号，不许编造`；
- **生成后校验**：用一个小模型/规则校验答案里每个 [n] 编号是否真实存在于本轮上下文，不存在的标红丢弃；
- 记离线评估：专门构造"多轮检索后引用准确性"的测试集，这是 Agentic RAG 的专属评估维度，传统 RAG 用不到。

## 五、评估：Agentic RAG 怎么测

传统 RAG 的评估集（问题 → 文档 → 答案）不够用了，Agentic 要测四个维度：

| 维度 | 指标 | 怎么测 |
|---|---|---|
| 答案质量 | 正确率/人工评分 | 和传统 RAG 共用测试集 |
| **检索效率** | 平均步数、重复检索率 | 日志统计，4 步内答对是优秀 |
| **引用准确性** | [n] 编号有效率 | 程序化校验 |
| **成本** | 单次问答 token 消耗 | 和传统 RAG 对比 |

**必须回答的问题：Agentic 比传统 RAG 好在哪？** 拿测试集跑两版对比——如果 Agentic 在简单问题上没有优势（大概率事件）、在复合问题上有明显优势（预期事件），才值得上线。**为了先进而先进地上 Agentic，是用五倍成本换一成提升，还引入不可控风险。**

## 六、渐进落地路线

别一上来全量 Agentic，三步走：

1. **影子模式**：Agentic 和传统 RAG 并行跑，人工对比答案——只读不写，零风险；
2. **分类启用**：简单问题走传统 RAG（快且便宜），复合问题（多实体/多步骤/对比类）才走 Agentic——**查询路由器分流**，成本收益比最优；
3. **全量 + 监控**：稳定后放开，监控步数分布、引用准确率、单次成本，异常回退。

路由器的实现可以很简单（问题长度/实体个数/关键词规则），也可以训练分类模型——从规则起步，数据攒够了再升级。

## 七、落地检查清单

- [ ] 工具集按查询维度拆分，每个工具的 description 写清适用/不适用场景；
- [ ] 护栏三件套：MAX_STEPS、重复查询上限、token 预算硬顶；
- [ ] 工具返回用"编号 + 摘要"模式，全文深挖走独立工具；
- [ ] 引用编号存在性程序化校验；
- [ ] 四维评估集（答案/步数/引用/成本）上线前跑一遍；
- [ ] 查询路由器分流简单问题到传统 RAG；
- [ ] 影子模式先行，日志分析步数分布再全量。

## 八、小结

Agentic RAG 的三句话：

- **本质是把检索从固定步骤变成 Agent 的可选动作**——检索什么、几次、何时停，三个控制权从管线转移给模型；
- **工具描述就是 prompt 工程**，工具拆分对齐查询维度，写好 description 比换模型收益大；
- **护栏-first**：步数上限、重复查询限制、token 预算、引用校验——没有这四样，一次 Agent 抽风就是一次成本事故。上线前先跑影子模式，用四维评估证明收益再全量。

下一篇讲检索工具化的封装：怎么把内部数据源（ES、SQL、Confluence）包装成 Agent 能调用的统一检索接口。
