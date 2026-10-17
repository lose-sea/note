# ACL 过滤检索实现：可见性模型、向量库 filter 与权限实时同步

"文档 A 的权限从公开改成了部门可见，为什么同事还能搜到？"——ACL 过滤是 RAG 权限体系的最后一公里，做不好就是安全事故。上一篇讲了多租户的大架构，这篇钻到底层实现：可见性数据模型怎么设计、向量库 filter 怎么写才又快又对、权限变更怎么做到秒级生效、以及 ACL 过滤对召回率的影响与补偿。所有细节都围绕一个目标：**用户永远只能检索到自己有权看的内容，且这个约束不依赖业务代码自觉**。

## 一、可见性数据模型：四种粒度

ACL 数据模型的设计起点是回答"谁能看"。四种粒度覆盖 95% 场景：

```
┌────────────────────────────────────────────┐
│ 1. 公开 public          —— 所有登录用户可见    │
│ 2. 租户 tenant           —— 同租户可见        │
│ 3. 部门/组 group         —— 指定组成员可见      │
│ 4. 个人 user            —— 指定用户可见（含 owner）│
└────────────────────────────────────────────┘
组合 = allow / deny 列表
```

一个文档的 ACL 记录：

```json
{
  "doc_id": "doc_123",
  "tenant": "alpha",
  "acl": {
    "visibility": "mixed",
    "allow_groups": ["grp_finance", "grp_board"],
    "allow_users": ["u_lisi"],
    "deny_users": ["u_wangwu"]
  },
  "owner": "u_zhangsan",
  "updated_at": "2026-10-16T09:00:00Z"
}
```

**两个设计决策**：

1. **deny 压倒 allow**：权限判断先查 deny 列表，"黑名单里的谁都看不到"是安全惯例；
2. **可见性预展开**：入库时把文档可见的**最终用户集合**（或组集合）算好存 metadata——检索时只做集合相交判断，不做实时 ACL 计算。理由：权限判断逻辑复杂（组继承、临时授权、交叉授权），每次检索现场算既慢又容易和实际不一致。**展开是"以空间换一致性和速度"**。

```python
# 入库时预展开
def resolve_visibility(doc_acl, group_members_resolver):
    """把组/个人 ACL 展开成最终用户集合"""
    users = set(doc_acl.get("allow_users", []))
    for g in doc_acl.get("allow_groups", []):
        users |= group_members_resolver(g)
    users -= set(doc_acl.get("deny_users", []))
    return users

# chunk metadata 里存展开结果（注意：集合大的情况用组 ID 折中）
chunk.metadata["acl_users"] = sorted(users)      # 或 ["grp_finance", "grp_board"] 组级
```

**集合太大怎么办**：全员可见的公共文档 `acl_users` 会膨胀。分级处理：`visibility: public` 的不存展开集合，检索时单独走公共通道；小众文档存展开用户集；中间态存组 ID。**没有一种表示能通吃，按文档粒度选表示。**

## 二、检索时的过滤判断：向量库 filter 怎么写

不同向量库的 filter 能力决定实现方式，以 Qdrant / Milvus 为例。

### 2.1 简单场景：tenant + group 两个维度

```python
# 用户 u_lisi：tenant=alpha，属于 [grp_finance, grp_board]，且有个人授权 doc_x
filt = {
    "$or": [
        {"tenant": "alpha", "visibility": "tenant"},                    # 租户级
        {"tenant": "alpha", "acl_groups": {"$any": ["grp_finance", "grp_board"]}},  # 组级
        {"acl_users": {"$any": ["u_lisi"]}},                            # 个人级（含 owner）
    ],
    "deny_users": {"$not_any": ["u_lisi"]},                             # 黑名单
}
```

**Qdrant 的 filter 表达式**是结构化 JSON，`$or`/`$any`/`$not_any` 组合足够表达复杂 ACL。要点：

- `acl_users` 字段用**数组类型**（Qdrant payload 支持 list），`$any` 语义是"交集非空"——个人级过滤的核心；
- `deny_users` 独立作为一个 `must_not` 条件，先黑后白；
- filter 在**检索时下推**到向量索引层执行，不是查完再过滤——下推才能保证 top_k 语义正确。

### 2.2 展开模式的两种表示与 trade-off

| 表示 | metadata | 检索过滤 | 适用 |
|---|---|---|---|
| **用户级展开** | `acl_users: [u1, u2, ...]` | `acl_users $any [user]` | 文档少、受众窄（部门文档） |
| **组级 + 公共标记** | `acl_groups + visibility` | 组相交判断 | 受众大、组织层级深 |

**组级表示的风险**：用户组关系变更（把人加进组）后，组级文档无需重写 metadata——这是它比用户级展开优越的地方（用户级展开要把老用户移除、新用户加入，每篇文档都要改）。权限变更的传播成本，**组级 >> 用户级**。

折中方案（推荐）：**默认组级 + 个人授权单独标记**，只有"个人显式授权"的文档才写 `acl_users`。权限变更绝大多数发生在组层面，个人授权是少数场景。

### 2.3 检索层伪代码（生产骨架）

```python
def acl_search(query, user_ctx, top_k=8):
    # 1. 组过滤条件（用户所属组 + 公开/租户通道）
    base_or = [
        {"visibility": "public"},
        {"tenant": user_ctx.tenant, "visibility": "tenant"},
        {"tenant": user_ctx.tenant, "acl_groups": {"$any": user_ctx.groups}},
    ]
    # 2. 个人授权通道（单独授予的文档）
    if user_ctx.personal_grants:      # u_lisi 被单独授权的 doc_x 集合
        base_or.append({"doc_id": {"$any": user_ctx.personal_grants}})
    # 3. 黑名单
    must_not = [{"deny_users": {"$any": [user_ctx.user_id]}}]

    filt = {"$or": base_or}
    return vector_store.search(query, filter=filt, must_not=must_not, k=top_k)
```

**注意 `personal_grants` 的来源**：用户上下文里带，来自权限中心的"个人授权文档列表"——权限中心同步，不是向量库存。**ACL 的真相在权限系统，向量库只是执行过滤的末端。**

## 三、权限变更的实时同步：秒级生效路径

ACL 最难的运维点是"权限变了，检索立刻变"。典型事故：员工转岗，原部门文档还搜得到；文档紧急撤回，已分享的检索还在命中。同步链路设计：

```
权限中心（真相源：HR 系统 / 文档系统 / 管理后台）
  │
  ├─ 权限事件流（webhook/MQ）：doc.acl.changed / user.group.changed
  │
  ├─ 写入侧处理器：
  │    ├─ doc.acl.changed → 更新该文档所有 chunk 的 metadata（filter 条件）
  │    │     （组级变更 → 改 acl_groups 数组；用户级变更 → 改 acl_users 数组）
  │    └─ user.group.changed → 只更新用户上下文缓存（组关系不需要动文档）
  │
  └─ 用户上下文档（刷新周期 < 5 分钟，或事件驱动失效）
```

三个关键设计：

1. **组级变更零文档更新**：把人加进组，只刷用户的组列表缓存——这是组级表示（2.2）在运维上的决定性优势。文档级 ACL 要逐 chunk 改 metadata，百万 chunk 的库慢到不可用；
2. **文档 ACL 变更走增量更新**：利用上一篇的 upsert 流水线改 metadata——不重 embedding、只改 payload，几十毫秒完成；
3. **撤回类紧急场景**：文档权限设为"仅自己可见"或物理删除，走软删 + 缓存失效通道，目标 < 30 秒生效——**合规场景（法院取证撤回）的时效红线**。

**校验机制**：权限变更事件 + 文档 metadata 的实际值，每天跑一次对账（抽样 1000 篇），不一致告警。和删除残留断言一样——安全属性不能"配了就当生效"。

## 四、ACL 过滤对召回率的影响与补偿

这是 ACL 检索绕不开的代价，必须量化认知：

**问题**：向量检索的 top-k 是在"全库最近邻"里选的，ACL 过滤**在检索后**剔除无权文档——过滤后可能只剩 3 个结果，甚至 0 个。过滤比例越高，召回崩塌越狠：

```
全库 Top-10 ──过滤（保留 30%）──→ 有效结果 3 个 → 答案质量下降
```

**三种补偿手段**：

1. **过采样**：检索时要 `top_k × (1 / 预估可见比例)`，比如过滤后通常剩 20%，就取 top_k=40 再过滤留 8。预估比例可从历史检索日志统计（各租户/组的过滤留存率）；
2. **filter 下推（如果向量库支持）**：Qdrant/Milvus 的 filtered search 在取 KNN 时就带上过滤条件，找到的本来就是"过滤后的最近邻"——比过采样更优雅，top_k 语义保留。**过采样是 filter 无法下推时的降级方案**；
3. **ACL 感知的召回评估**：评估集按"用户 A 的可见集"构造，测"该用户视角下的命中率"——不是全库命中率。**同一个查询，公共知识充足的租户命中率高，冷启动租户命中率低，这是 ACL 系统的固有现象**，要在评估时分层看。

## 五、无法回避的两个坑

### 5.1 元组爆炸

用户级展开存 `acl_users` 数组，文档受众广时数组几千人——payload 体积膨胀，检索时 `$any` 大数组匹配变慢。**规则：个人授权只用于小众文档**；广域文档永远走组级/租户级通道。

### 5.2 组继承的语义复杂

企业组的现实：人属于"部门 → 事业部 → 公司"多级，文档授权给"事业部"时，它下面的部门自动继承吗？——**这取决于权限中心的语义**，不是 RAG 层能决定的。RAG 层要做的：组集合由权限中心算好（含继承展开），RAG 只消费最终集合。**别在检索层实现组继承逻辑**——那是权限系统的职责，跨系统实现必然不一致。

## 六、落地检查清单

- [ ] 可见性四级模型（public/tenant/group/user）+ deny 优先级；
- [ ] metadata 表示：默认组级 + 个人授权单独标，公共文档走 visibility 标记；
- [ ] filter 下推到向量检索层（Qdrant filter 表达式），filter 无法下推时过采样补偿；
- [ ] 权限变更事件流 → 文档 metadata 增量更新 + 用户组缓存失效；
- [ ] 组级变更零文档更新（用户上下文缓存刷新 < 5 分钟）；
- [ ] 紧急撤回通道 < 30 秒（软删 + 缓存失效）；
- [ ] 每日权限对账抽样 + 不一致告警；
- [ ] ACL 感知的召回评估（按用户视角分层评估）；
- [ ] 组继承语义由权限中心实现，RAG 只消费最终集合。

## 七、小结

ACL 过滤检索的五句话：

- **可见性四级模型**：public/tenant/group/user + deny 优先，deny 是安全底线；
- **组级表示为默认**，个人授权单独标记——组级变更只刷用户缓存不动文档，这是权限实时生效的关键；
- **filter 必须下推到向量检索层**，Qdrant/Milvus 的结构化 filter 直接表达 ACL；下推不了就过采样，代价是 top_k 语义失真；
- **ACL 的真相在权限中心**：RAG 是过滤执行末端，组继承、个人授权、deny 语义都在权限中心算好，RAG 消费最终集合；
- **安全属性靠持续验证**：每日对账抽样、不一致即告警——ACL 配了不等于生效，和删除残留断言同理。

下一篇讲引用溯源：怎么让生成的每句话都能点回原文出处。
