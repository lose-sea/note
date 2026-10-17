# 知识图谱构建流水线实战：实体关系抽取的提示词、质量抽检与增量维护

GraphRAG 也好、LightRAG 也好，效果的上限在建图质量——实体抽漏了、关系抽错了、同义实体没合并，图上全是毛边，查询时一步错步步错。这篇文章不讲框架怎么调用（前两篇讲过），讲**构建流水的工程细节**：抽取提示词怎么设计、批处理怎么做、质量怎么抽检、增量图谱怎么维护。这些才是自己搭图谱时真正花时间的地方。

## 一、抽取提示词：整个流水线的第一性问题

自动建图靠 LLM 抽取，产出质量八分靠提示词。一个生产可用的抽取提示词长这样：

```
你是一个知识图谱抽取引擎。从给定文本中抽取实体和关系，严格按以下 JSON 输出。

【实体定义】
- entity_name: 实体名称（规范化，使用全称，去除修饰词）
- entity_type: 实体类型，只能是以下之一：
  [人物, 组织, 产品, 技术, 地点, 时间, 事件, 概念, 数值指标]
- description: 实体的完整描述，整合文本中所有相关信息

【关系定义】
- source_entity / target_entity: 必须是已抽取的实体名称
- relation_type: 关系类型，从以下选：[创立, 任职, 合作, 竞争, 属于,
  位于, 发生于, 投资, 使用, 导致, 升级, 替代]
- relation_description: 关系的文字描述，保留关键细节和数字
- strength: 关系强度 1-10，根据文本中信息量判断

【规则】
1. 实体名称规范化："蓝海科技有限公司"→"蓝海科技"，去公司后缀
2. 数字带单位：营收"18 亿"不要写成"18"
3. 无信息可抽时输出空列表，不要编造
4. 只输出 JSON，不要任何解释文字

文本：
{chunk_text}
```

四个设计要点，都是踩坑换来的：

### 1.1 实体类型封闭枚举

**类型必须是封闭集合**，不能开放式。开放类型（"给实体分个类"）会让每次抽取产出 `组织`、`Company`、`企业`三种等价类型，图谱统计全乱。封闭枚举换来的是可统计、可路由（后头按类型过滤）。

### 1.2 关系类型也封闭

同理，关系类型封闭。关系类型还决定了图遍历的语义质量——`[创立, 任职]` 这套枚举里没有"是...的朋友"这种边，图才干净。**业务图谱的关系类型应该和业务问题对齐**：做企业关系图谱就枚举股权/任职/合作，做技术选型图谱就枚举使用/替代/兼容。

### 1.3 规范化规则显式写死

模型不会自动知道"蓝海科技有限公司"和"蓝海科技"是同一个。规则要写进提示词：去公司后缀、统一全称、数字带单位。**显式规则每写一条，图谱噪音少一片。**

### 1.4 强度评分要谨慎

`strength` 这个字段 LightRAG/GraphRAG 都有，用于边加权。但 LLM 给的强度主观性很强，不同 chunk 里同一对实体的强度可能一个 8 一个 3。**合并时必须取均值或max并记录证据**，不然加权检索会随机漂移。

## 二、实体消歧：图谱质量的最大杀手

同一实体在语料里有多个名字，图谱里就是多个节点——查询召回残缺，多跳链条在这里断。生产级消歧分三步：

### 2.1 抽取时归一

提示词层面解决大部分：要求全称、去后缀、附别名。LLM 在 chunk 内部能看到上下文，归一效果不错。

```json
{"entity_name": "蓝海科技", "entity_type": "组织",
 "description": "蓝海科技，2015 年由张伟创立的企业级 SaaS 公司，别名'蓝海'"}
```

### 2.2 合并时用别名表

跨 chunk 的别名统一要有机制。最简单的做法是维护一份**别名映射表**（人工 + 高频统计结合）：

```python
ALIAS_MAP = {
    "蓝海科技": ["蓝海", "蓝海科技有限公司", "LH Tech", "BlueOcean"],
    "清风数据": ["清风", "QF Data"],
    "张伟": ["张总", "张先生", "Wei Zhang"],   # 人称词慎重，看场景
}

def normalize(name: str) -> str:
    for canonical, aliases in ALIAS_MAP.items():
        if name in aliases or name == canonical:
            return canonical
    return name
```

别名表从哪来：抽取后统计所有实体名称，找高频共现/编辑距离近的候选，人工确认。**这是唯一必须人肉的环节**，但是一次性的，之后增量自动跑。

### 2.3 嵌入相似度兜底

别名表覆盖不到的，用向量相似度找候选合并：实体描述的 embedding 相近（cosine > 0.92）且类型相同的，标记为疑似同一实体，进人工复核队列。全自动合并风险大（"苹果公司"和"苹果派"描述相似度可能意外地高），**宁可漏合不可错合**。

## 三、批处理工程：控成本、可恢复、可观测

建图是长任务（小时级到天级），工程设计和离线 ETL 对齐：

### 3.1 流水线结构

```
文档 → 解析（Docling 等）→ 清洗 → 切 chunk（1200-2400 token）
  → 去重（同 hash chunk 跳过）
  → 【抽取】每 chunk 一次 LLM 调用（并发 + 重试 + 限流）
  → 归一化（别名表）
  → 写入图数据库（Neo4j：MERGE 幂等合并）
  → 记录 checkpoint（chunk_id → 状态）
```

### 3.2 幂等与断点续跑

任务中断不能从头再来（一次全量抽取几十美元到几百美元）。两个机制：

1. **chunk 级 checkpoint**：每个 chunk 的抽取结果落对象存储，键为 `chunk_hash`，跑过的直接跳过；
2. **图写入幂等**：Neo4j 的 `MERGE`（而非 `CREATE`）保证同一实体重复写入是更新不是新建——重跑安全。

```python
# 伪代码：断点续跑
def build(docs, ckpt_store):
    for chunk in chunks(docs):
        key = chunk.hash
        if ckpt_store.done(key):
            continue
        try:
            entities, rels = extract(chunk)          # LLM 抽取
            validate(entities, rels)                  # schema 校验
            merge_to_graph(entities, rels)            # MERGE 写入
            ckpt_store.mark_done(key)
        except Exception as e:
            ckpt_store.mark_failed(key, e)
            # 失败重试 N 次后进死信队列，人工看
```

### 3.3 并发与限流

LLM API 有 rate limit，并发不是越高越好。经验值：按 API 的 RPM/RPM 配额反推，留 30% 余量；失败走指数退避；429/500 自动重试三次。

### 3.4 可观测：建图期的仪表盘

长任务要有进度和产出质量监控，至少四项：

- 处理进度：chunk 完成率；
- 抽取产出：平均每 chunk 抽出多少实体/关系（**突降要警觉**——可能是提示词被改坏或模型抽风）；
- 失败率：死信队列深度；
- 图规模：节点数、边数、孤立节点占比（孤立实体多 = 关系抽取失败）。

## 四、质量抽检：唯一可信的验收

自动流水线的输出不能"看起来跑完就信"，要定期人工抽检：

### 4.1 随机抽检协议

每次跑完全量/大批增量，随机抽 50 个 chunk 的抽取结果，对照原文人工核：

| 维度 | 及格线 |
|---|---|
| 实体召回（原文有的实体被抽出） | > 90% |
| 实体准确（抽出的不是编造的） | > 95% |
| 关系正确（两端实体选对、类型合理） | > 85% |
| 描述忠实（不添加原文没有的信息） | > 90% |

低于及格线：停下来调提示词，别硬着头皮往下建——图谱错误会随着增量累积。

### 4.2 图结构体检

```cypher
// Neo4j 里的例行体检查询

// 1. 孤立实体（没有关系的节点，多半是废节点）
MATCH (e) WHERE NOT (e)--() RETURN e LIMIT 50;

// 2. 高频实体 Top20（看分布是否合理）
MATCH (e) RETURN e.name, count{()--()} ORDER BY 2 DESC LIMIT 20;

// 3. 疑似重复实体（名称编辑距离近）
//    用 APOC 或外部计算找候选

// 4. 关系类型分布（枚举外泄检测）
MATCH ()-[r]->() RETURN type(r), count(*) ORDER BY 2 DESC;
```

**孤立节点占比 > 5%** 就是信号：要么关系枚举没覆盖这个领域，要么提示词跑了偏。

## 五、增量图谱的真实坑

增量"加文档"听起来简单，做起来有三个坑：

### 5.1 新增实体与旧实体的连接

新文档抽出的实体，图谱里已存在 → MERGE 合并；**新实体和旧实体的关系边，只有新文档里提到了才会有**。这意味着"张伟"这个实体，新文档没提他的关系，他的旧关系还在——这没问题。真正的问题是**社区结构漂移**：GraphRAG 类方案的社区是全局聚类的，增量加进来社区边界就该动，但全量重聚类贵。LightRAG 的图谱方案没有社区摘要，天然免疫这个问题——**这是增量场景优先 LightRAG 的又一个理由**。

### 5.2 删除文档的图谱回滚

删了文档，抽出来的实体关系怎么办？**正确做法是记录每个实体/关系的来源 chunk_id**，删文档时级联清理只属于它的边；被多文档共享的实体保留（把来源标记删掉）。没有血缘设计，图谱只会涨不会消，时间久了全是幽灵。**建图第一天就要设计来源字段**（`source_chunks: [id1, id2]`），事后补不了。

### 5.3 版本与重抽

抽取提示词升级了，全量图谱想重抽？——chunk 级 checkpoint 的设计价值在这：**换个 checkpoint 目录重跑一遍**，新旧图谱并存，对比质量后再切换。图谱也是要版本管理的，`graph_v1`、`graph_v2` 目录分开，查询引擎指哪套读哪套。

## 六、一套最小的可跑实现

不依赖框架的最小流水线（用 Neo4j 存图）：

```python
from neo4j import GraphDatabase
import json, hashlib

driver = GraphDatabase.driver("bolt://localhost:7687", auth=("neo4j", "pwd"))

def merge_extraction(session, chunk_id, extraction):
    # 实体 MERGE
    for e in extraction["entities"]:
        session.run("""
            MERGE (e:Entity {name: $name})
            ON CREATE SET e.type = $type, e.description = $desc,
                          e.source_chunks = [$cid]
            ON MATCH SET  e.source_chunks = 
                CASE WHEN $cid IN e.source_chunks THEN e.source_chunks 
                     ELSE e.source_chunks + $cid END
        """, name=normalize(e["entity_name"]), type=e["entity_type"],
             desc=e["description"], cid=chunk_id)
    # 关系 MERGE
    for r in extraction["relationships"]:
        session.run("""
            MATCH (a:Entity {name: $src}), (b:Entity {name: $dst})
            MERGE (a)-[rel:REL {type: $rtype}]->(b)
            ON CREATE SET rel.description = $desc, rel.source_chunks = [$cid]
            ON MATCH SET rel.source_chunks = 
                CASE WHEN $cid IN rel.source_chunks THEN rel.source_chunks 
                     ELSE rel.source_chunks + $cid END
        """, src=normalize(r["source_entity"]),
             dst=normalize(r["target_entity"]),
             rtype=r["relation_type"], desc=r["relation_description"],
             cid=chunk_id)
```

这套 MERGE 逻辑保证：重跑幂等、增量追加、来源可溯。自建图谱的最小可用内核就这些，剩下的都是工程加固（并发、重试、体检）。

## 七、落地检查清单

- [ ] 抽取提示词定型：实体类型封闭枚举、关系类型封闭枚举、规范化规则显式；
- [ ] 别名表建立（抽取统计 + 人工确认），归一化函数上线；
- [ ] chunk 级 checkpoint（hash 键）+ 图写入 MERGE 幂等，支持断点续跑；
- [ ] 抽取用便宜/本地模型，并发按 API 配额留 30% 余量；
- [ ] 建图仪表盘：进度、每 chunk 产出实体数、失败率、孤立节点占比；
- [ ] 每次全量/大批增量后 50 样本人工抽检，四项指标过线；
- [ ] 来源 chunk_id 血缘字段设计（删除回滚的前提）；
- [ ] 图谱版本管理（换 checkpoint 目录重抽，新旧并存对比）。

## 八、小结

知识图谱构建的三句话：

- **提示词是第一生产力**：实体/关系类型封闭枚举、规范化规则显式写死、禁止编造——抽错一步后面全歪；
- **消歧靠三层**：抽取时归一、别名表映射、向量相似度兜底人工复核，宁可漏合不可错合；
- **增量从第一天开始设计**：chunk checkpoint 断点续跑、MERGE 幂等写入、来源血缘字段、图结构体检四项指标——这四样没有，图谱上线三个月就是一笔糊涂账。

下一篇讲 Agentic RAG：让 Agent 自己决定怎么检索、检索几次、什么时候该停止。
