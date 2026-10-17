# Map-Reduce 式全文问答：当文档超出上下文时的分而治之

有些问题向量检索根本帮不上忙："这本 300 页的白皮书里，作者一共提出了几条反对意见？"——答案散落在全文各处，任何 Top-K 检索都捞不全。对这类"全文级"问题，LangChain 的 `map_reduce` / `refine` 链路给出了最直接的答案：**把文档切成块，逐块处理（Map），再把中间结果汇总（Reduce）**。这篇文章讲透四种链式策略的行为差异、各自的成本与坑，以及怎么为问题类型选对链路。

## 一、四种链式策略：行为决定适用面

LangChain 的 summarization/问答链有四个经典策略，先看全景对比：

| 策略 | Map | Reduce | 调用次数 | 特点 |
|---|---|---|---|---|
| `stuff` | 无 | 无 | 1 | 全部塞进一个 prompt |
| `map_reduce` | 每块独立答 | 合并中间答案 | N+1 | **各块相互独立**，全局视角 |
| `refine` | 每块在累积答案上迭代 | 滚动更新 | N | **答案逐块精炼**，保序演进 |
| `map_rerank` | 每块独立答 + 打分 | 取最高分 | N | 适合"答案在某一块里"的定位型问题 |

### 1.1 stuff：不是策略，是上限参照

所有材料塞一个 prompt，一次 LLM 调用。上下文够小时最优先（质量最好、没信息损失、最便宜），超限时直接出局。**它的价值在基线**：任何其他策略效果不如 stuff，说明问题不在链路上。

### 1.2 map_reduce：并行全局型

```
[chunk-1] ─→ LLM(问题+chunk1) ─→ 中间答案A ┐
[chunk-2] ─→ LLM(问题+chunk2) ─→ 中间答案B ┼→ LLM(汇总) ─→ 最终答案
[chunk-3] ─→ LLM(问题+chunk3) ─→ 中间答案C ┘
```

Map 阶段**完全并行**（N 个块可以并发请求），每个块只看到"问题 + 自己这块内容"，产出一个局部回答；Reduce 阶段把所有中间答案合并成最终答案。

LangChain 实现：

```python
from langchain.chains import MapReduceDocumentsChain, ReduceDocumentsChain
from langchain.chains.combine_documents.stuff import StuffDocumentsChain

# Map
map_chain = LLMChain(llm=llm, prompt=map_prompt)
# Reduce：先 stuff 成组，组超限再递归 reduce
reduce_chain = ReduceDocumentsChain(
    combine_documents_chain=StuffDocumentsChain(
        llm=llm, prompt=reduce_prompt),
    collapse_documents_chain=StuffDocumentsChain(...),
    token_max=4000,
)
chain = MapReduceDocumentsChain(
    llm_chain=map_chain, reduce_documents_chain=reduce_chain,
    document_variable_name="context",
)
result = chain.invoke({"input_documents": chunks, "question": q})
```

**map_reduce 的天然优势与死穴**：

- ✅ 每个块独立处理，**没有跨块依赖**，全文的"每个角落"都被扫到——"全文有几条反对意见"这类全局统计问题的最优解；
- ✅ Map 阶段天然并行， latency 约等于单块延迟 × 2；
- ❌ **Map 阶段每块都不知道其他块的存在**——跨块的对比、演进、因果（"第三章的观点和第七章矛盾吗"）在中间答案层丢失；
- ❌ 中间答案 token 量大时，Reduce 自身也要分段（`token_max` 触发 collapse），300 块全文 → 中间答案比原文还长，递归 reduce 烧钱没商量。

### 1.3 refine：顺序精炼型

```
chunk-1 → 初始答案
chunk-2 → LLM(问题 + 当前答案 + chunk2) → 更新答案
chunk-3 → LLM(问题 + 更新答案 + chunk3) → 再更新
...
```

每一步都基于"到目前为止的最佳答案"吸收新块。LangChain 实现：

```python
from langchain.chains import RefineDocumentsChain

chain = RefineDocumentsChain(
    initial_llm_chain=LLMChain(llm=llm, prompt=initial_prompt),
    refine_llm_chain=LLMChain(llm=llm, prompt=refine_prompt),
    document_variable_name="context",
)
```

**intermediate_steps** 可以拿到每步的中间答案——调试友好，能看见答案是怎么一步步长出来的。

- ✅ 顺序语义保住：后面的块知道前面发生了什么，"观点的演变"这类问题答得出；
- ❌ **串行 N 次调用，latency 线性累加**——50 个块就是 50 次串行请求，一分钟起步；
- ❌ **顺序敏感**：块的排列顺序影响结果，same cost 下结果有方差；
- ❌ 中间答案轮次膨胀：第 20 块时上下文里已经有前 19 块的信息浓缩，token 越滚越大。

### 1.4 map_rerank：定位型

Map 阶段不只产答案，还产"这个问题和这块内容的相关度"分数，Reduce 取最高分块的答案。适合"答案确定在某一段"（问合同条款具体规定、问某参数具体值）。

```
[chunk-1] → 答案 + 相关度分 0.2
[chunk-2] → 答案 + 相关度分 0.9 ← 它赢
[chunk-3] → 答案 + 相关度分 0.3
→ 返回 chunk-2 的答案
```

- ✅ 答案出自最相关块，不会把弱相关块的内容搅进来；
- ❌ 每块必须独立成答，跨块信息合并不了；相关度打分本身也会飘。

## 二、按问题类型选链路：决策表

| 问题类型 | 例子 | 推荐链路 |
|---|---|---|
| 材料够小 | 任意 | `stuff` |
| **全局统计/汇总** | "全文几条反对意见" | `map_reduce` |
| **顺序演进/对比** | "作者观点怎么变化的" | `refine` |
| **精确定位** | "违约金比例是多少" | `map_rerank`（或直接向量检索） |
| 跨块关系 | "A 论点和 B 数据矛盾吗" | map_reduce + 把"找矛盾"写进 map prompt |

**注意最后一行**：map_reduce 不是不能跨块——把跨块任务显式写给 Map 阶段的每块（"这段内容和反对意见相关吗？相关就总结出来"），Reduce 阶段做归并。**问题分解到位，map_reduce 能覆盖相当多的复合问题。**

## 三、成本模型：算账再上车

全文级问答是 LLM 密集型操作，单次成本 = N × (每块 prompt token) + Reduce token。以 30 万 token 文档、10 万 token/块处理为例：

| 策略 | LLM 调用 | 大致成本倍数 | 延迟 |
|---|---|---|---|
| stuff | 1 | 1× | 一次请求 |
| map_reduce | 30 + 1（Reduce 还得分组） | **~30×** | 并行 ≈ 2 倍单块 |
| refine | 30 串行 | ~30×+（中间膨胀） | **30 倍串行** |
| map_rerank | 30 并行 | ~30× | 并行，快 |

**临门一脚的省钱技巧**：

1. **Map 阶段用便宜模型**：块级处理是"体力活"（抽取、定位、打分），gpt-4o-mini、GLM-4-Flash 完全够；Reduce/Refine 的最终合成再用好模型——**成本直接砍 70%**；
2. **预过滤块**：先用向量检索粗排一遍，全文 300 块里只有 60 块可能相关，Map 只跑这 60 块——"全文问答"不等于"每块都要问 LLM"；
3. **缓存中间答案**：同一文档的类似问题（"几条反对意见"/"几条支持意见"）Map 结果可复用——按块缓存，别全文重跑；
4. **控制 chunk 大小**：块太大浪费 token（每块 prompt 都带问题+指令），太小块数爆炸。512~1500 token/块是甜点。

## 四、一个 hybrid 实战：先筛后跑

生产上我最常用的组合——**向量预筛 + map_reduce + 分段 reduce**：

```python
# 1. 预筛：全文块先过向量检索，保留相关的
candidates = vector_store.search(embed(q), top_k=60)   # 300 → 60

# 2. Map：便宜模型并发处理 60 块
partials = async_gather([
    cheap_llm(map_prompt.format(question=q, context=c)) 
    for c in candidates
])

# 3. Reduce 分组：token 超限就分组 stuff，递归上升
groups = [partials[i:i+10] for i in range(0, len(partials), 10)]
mid = async_gather([cheap_llm(collapse_prompt.format(texts=g)) for g in groups])

# 4. 最终合成：好模型
final = good_llm(final_prompt.format(question=q, mids="\n".join(mid)))
```

效果与成本：60 块里相关的一般不到 20 块的有效信息，预筛砍掉 80% 的无谓调用；三级模型分工（便宜 → 便宜 → 好）把总成本压到全量 map_reduce 的 1/4 左右，质量几乎无损——**无效块本来就产不出有用信息，用贵模型处理它们是纯浪费。**

## 五、坑与边界

1. **map_reduce 的中间答案别太长**：Map prompt 里限定"最多 3 句话，只输出和问题直接相关的信息"，否则 Reduce 阶段被中间答案的废话淹没；
2. **refine 的顺序**：块顺序打乱结果会变，正式处理前固定排序规则（按页码）并在测试集验证顺序敏感性；
3. **数值统计要小心**：map_reduce 数数（"全文出现几次 X"）时，每块的计数相加可能重复计（同一事件在多块被提到）——这类"数数"问题更适合先 Norm 后统计，或者专门写代码统计；
4. **reduce 的递归终止条件**：Reduce 分组合并后仍超 `token_max` 时，LangChain 会递归 collapse，要设最大递归深度兜底；
5. **别对全文问答上缓存幻觉**：中间答案只对"同文档同子任务"可复用，问题一换 Map 就得重跑。

## 六、评估：全文问答怎么测

这套链路没法用传统检索评估集（没有"标准检索块"），要换评估方式：

1. **构造聚合型测试集**：人工通读全文，标注"全文级事实"（共几条、分布在哪些页、核心观点是什么）；
2. **LLM-as-judge**：让裁判模型对比标准答案和链路输出，打分（允许用 Claude/GPT-4 当裁判，比人工快 20 倍）；
3. **消融对照**：同样问题跑"预筛 vs 不预筛"、"便宜模型 vs 好模型 Map"，用分数差证明省钱技巧没掉点；
4. **延迟统计**：map_reduce 的 P99、refine 的串行耗时——选型时延迟是硬约束，refine 在块数 > 30 时基本不可用。

## 七、小结

Map-Reduce 式全文问答的四句话：

- **四种链路对应四种问题**：全局统计用 map_reduce、顺序演进用 refine、精确定位用 map_rerank、材料够小直接 stuff；
- **map_reduce 并行但丢跨块语义，refine 保顺序但串行慢**——没有完美策略，只有对口的策略；
- **生产组合：向量预筛 + map_reduce + 三级模型分工**，把"全文 30 倍成本"压到 1/4，质量靠预筛保证（无效块本来就没信息）；
- **评估用聚合型测试集 + LLM-as-judge + 消融对照**，别用检索评估集的标准考全文问答。

下一篇讲增量索引：新文档怎么做到分钟级可检索，以及索引更新不停机的工程做法。
