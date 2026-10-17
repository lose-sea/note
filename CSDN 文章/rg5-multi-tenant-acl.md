# 多租户知识库实战：隔离模式、检索过滤与成本分摊

SaaS 化的 RAG 系统都要过同一道坎：**一套系统服务多家企业租户，A 公司的数据绝不能出现在 B 公司的答案里，但全库物理隔离又贵又难维护**。选错隔离模式，要么踩安全红线，要么被运维成本和检索质量拖垮。这篇文章讲三种隔离模式的取舍、检索层的租户过滤怎么做、共享库场景下的性能与成本分摊，以及一套经过验证的落地架构。

## 一、先明确：隔离的不是数据，是"检索路径"

多租户设计最常见的误区是"先把数据隔开"。其实 RAG 场景里，数据本身存在哪不是最重要——**答案是围着"谁能检索到谁"转的**。一个文档归属多个维度：租户、部门、项目、密级、可见用户。隔离的本质是：**每次检索都按查询者的身份过滤**。

但物理层怎么放数据，决定了过滤的效率和安全的下限，这就是 isolation level 的选择。

## 二、三种隔离模式

### 模式 A：每租户独立 collection（强隔离）

```
kb_tenant_alpha/    ← A 公司独占
kb_tenant_beta/     ← B 公司独占
```

- **检索**：查询直接路由到本租户 collection，`where: {tenant: "alpha"}` 都不用写——物理隔离；
- **隔离强度**：最高。代码 bug 顶多查错 collection，不会跨租户混数据；
- **成本**：向量库 collection 数量 = 租户数。几百租户还行，几千租户后 collection 元数据管理、备份、监控都要按 collection 维度铺开，运维复杂度线性涨；
- **检索质量**：单租户数据量小，embedding 在全库上没差别（模型推理按 chunk 走），但 BM25 倒排等词汇统计被限制在小 collection，IDF 统计偏弱；
- **共享知识**：❌ 平台级公共知识（产品公告、公共文档）要么每租户拷一份（浪费），要么单独建公共 collection 检索时并行（第一篇讲过的混合架构）。

### 模式 B：共享 collection + 行级过滤（主流）

```
kb_shared/
  chunk-1: {text: ..., tenant: "alpha"}
  chunk-2: {text: ..., tenant: "beta"}
```

- **检索**：每次查询带 `where: {"tenant": {"$in": user_tenants}}`，向量库在检索时过滤；
- **隔离强度**：依赖过滤代码的正确性——**过滤条件漏写 = 跨租户泄露**。必须框架层强制（所有检索入口统一走带 tenant 的封装），不允许裸调向量库；
- **成本**：一个 collection 管所有租户，元数据管理成本最低；collection 越大，向量库的索引（HNSW）越满，**过滤后可用邻居变少，召回率可能下降**——这是行级过滤的经典代价；
- **检索质量**：BM25 侧 IDF 基于全库，统计更稳；
- **共享知识**：✅ 公共文档 `tenant: "public"`，租户文档 `tenant: "xxx"`，查询过滤 `tenant: {$in: [user_tenant, "public"]}` 天然覆盖。

### 模式 C：按租户等级混部

大租户独立 collection（数据量大、客制化多、隔离要求高），小租户共享 collection——**按规模分流**，兼顾隔离强度和运维成本。判断标准：> 10 万文档 或 签了数据驻留协议的租户进独立 collection，其余进共享池。

**选型速查**：

| 租户规模 | 隔离要求 | 推荐 |
|---|---|---|
| 租户数 < 50，都要强隔离 | 高 | 模式 A |
| 租户数几百~几千 | 标准 SaaS | 模式 B + 公共知识池 |
| 大小租户混合 | 头部贵宾特殊 | 模式 C |

## 三、行级过滤的正确实现：安全细节

模式 B 的命门是过滤代码。正确实现的四层防护：

### 3.1 封装层强制

```python
class TenantAwareRetriever:
    def __init__(self, vector_store):
        self.vs = vector_store

    def search(self, query, user_ctx, top_k=5):
        # 唯一入口：不允许绕过 ctx 的检索
        if not user_ctx.tenants:
            raise PermissionError("用户无租户上下文")
        filt = {"tenant": {"$in": user_ctx.tenants}}     # 公共知识在 tenants 里已含 "public"
        hits = self.vs.similarity_search_with_filter(query, filter=filt, k=top_k)
        return self._post_filter(hits, user_ctx)           # 兜底再过一遍
```

**所有检索必须过 `TenantAwareRetriever`**——这是代码规范 + 代码评审 + 静态检查要保的事，不是口头约定。安全红线类代码不能依赖"大家记得带 tenant"。

### 3.2 入库时租户标签强制

写入侧同样封装：文档入库必须带 `tenant`，没带的拒绝入库。写漏的文档比查漏更糟——**匿名文档一旦进了共享 collection，所有租户都能检索到**。

```python
def ingest(doc, tenant_id):
    assert tenant_id, "tenant_id 必填"
    chunks = [...]  # 切块
    for c in chunks:
        c.metadata["tenant"] = tenant_id
        c.metadata["visibility"] = doc.visibility  # team/user 级可见粒度
    vs.add_documents(chunks)
```

### 3.3 过滤 + 后置校验

向量库的 `filter` 在查询时可不可靠？——Qdrant/Milvus 的过滤是查询层执行，理论可靠，但**跨版本升级、索引重建、异常 rollback 都可能引入过滤失效**。生产架构加一道廉价的后置校验：

```python
def _post_filter(self, hits, user_ctx):
    return [h for h in hits 
            if h.metadata.get("tenant") in user_ctx.tenants]
```

一次内存遍历，成本忽略，换来"过滤失效时最后一道防线"。**安全组件的原则：宁可重复过滤，不可单点信任。**

### 3.4 定期渗透自检

每周跑一次自动化的跨租户探测：用租户 B 的上下文构造"只有 A 有的内容"查询，断言返回为空。这个用例进 CI/定期任务——**和删除残留断言同理，安全属性要靠持续验证，不是靠一次实现**。

## 四、细粒度 ACL：租户内的部门与用户隔离

租户隔离解决"公司之间"，公司内部还要分"谁能看什么"：

```
租户 alpha
 ├─ 财务部文档（vis: dept_finance）
 ├─ 工程部文档（vis: dept_eng）
├─ 全员公告（vis: all）
└─ 张三的个人笔记（vis: user_zhangsan）
```

metadata 设计：

```json
{
  "tenant": "alpha",
  "visibility": {
    "type": "mixed",           // all / dept / user / mixed
    "allow_depts": ["dept_finance"],
    "allow_users": ["user_lisi"],
    "deny_users": []
  }
}
```

检索过滤从"等于 tenant"变成"可见性表达式匹配"——向量库的 filter 表达式能力（Qdrant 的 `should`/`must`）能直接表达，复杂场景在前置算好"可见集合"再简化过滤条件。**用户组多的时候，把每篇文档的可见性预先展开成 `allow_groups: [g1,g2,...]`**，检索时 `allow_groups ∩ user_groups ≠ ∅`，比嵌套表达式快。

## 五、性能：共享 collection 的三个坎

模式 B 用久了会撞上性能问题，提前知道：

1. **召回率衰减**：collection 涨到千万级 + HNSW + 过滤，过滤后有效候选少，召回下滑。对策：按 `tenant` 分片（向量库原生分片）或按租户规模混部（模式 C）；
2. **大租户热点**：某租户占 60% 数据，它的查询把共享索引的缓存全占了。对策：识别头部租户迁独立 collection；
3. **索引重建放大**：版本管理（上一篇）里"全量重建"在多租户下是全体重建——按租户分 collection 后可以**按租户滚动重建**，爆炸半径小。

## 六、成本分摊与配额

多租户的成本账要算到租户头上，否则平台被大租户白嫖：

| 成本项 | 分摊依据 | 实现 |
|---|---|---|
| 解析 + embedding 入库费 | 文档页数/token 数 | 入库时按租户计量 |
| 存储费 | 租户 chunk 数 × 向量维度 | 定期统计 |
| 查询 LLM 费 | 按租户的查询 token | 调用链打标 |
| 向量库资源 | 共享部分按调用比例摊 | 按月报表 |

配额设计（防单一租户拖垮平台）也是必修课：单租户文档数上限、单日查询上限、并发查询上限——**超限要有限流和配额提醒机制**，不是无底洞。

## 七、落地检查清单

- [ ] 隔离模式定稿：小租户共享 + 公共知识池，头部租户（>10 万文档）独立 collection；
- [ ] 所有检索强制走 `TenantAwareRetriever`，代码评审清单 + 静态检查兜底；
- [ ] 入库强制租户标签，无标签拒绝；
- [ ] 向量库过滤 + 后置校验双保险；
- [ ] 跨租户探测自动化（B 查 A 内容断言为空）进 CI；
- [ ] visibility 支持 dept/user 级，可见集合预展开；
- [ ] 头部租户识别与混部机制（共享池召回率监控触发）；
- [ ] 按租户的计量与配额（文档数、查询数、并发）。

## 八、小结

多租户知识库的四句话：

- **隔离的本质是检索路径，不是数据存放位置**——每次检索按身份过滤，比物理隔离更灵活；
- **小租户共享 collection + 行级过滤是主流**，头部租户独立 collection 混部，公共知识单列；
- **安全靠封装强制 + 双重过滤 + 持续探测**——跨租户泄露没有"下次注意"，只有代码规范、静态检查和每周自动探测三道防线；
- **召回率、热点、成本三笔账**共享池迟早要还——按租户计量计量，按规模混部，识别头部租户迁出，是共享池的宿命也是解法。

下一篇讲 ACL 过滤的具体实现：可见性表达式怎么设计、向量库 filter 怎么写、以及权限变更的实时同步。
