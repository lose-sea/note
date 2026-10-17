# 检索工具化封装：把 Elasticsearch、SQL、Confluence 包装成 Agent 的统一工具

Agentic RAG 的地基是"检索即工具"——Agent 不需要知道数据存在哪、怎么查，它只调工具、拿结果。但企业内部的数据源五花八门：向量库、Elasticsearch、MySQL、Confluence、公司自建 API……每个的查询方式、返回格式、权限模型都不一样。这篇文章讲**怎么把这些差异封装掉，给 Agent 一套统一的检索工具接口**：适配器模式怎么设计、返回格式怎么定、权限在哪一层注入、以及工具注册和发现机制。

## 一、为什么不能"一个 Agent 直连所有数据源"

天真架构长这样：Agent 的 prompt 里列五个数据源，Function Calling 直接调各家的 SDK。三个月内必崩，原因：

1. **prompt 被接口细节污染**：ES 的 query DSL、MySQL 的 SQL、Confluence 的 CQL——每个工具的 description 都在拉低 Agent 的路由准确率；
2. **返回格式不统一**：ES 返回 hits、SQL 返回 rows、Confluence 返回 HTML——Agent 每接一种格式就多一类解析错误；
3. **权限无法收口**：Agent 拿着一个数据库超级账号，查哪都通——审计做不了，越权查不了；
4. **加一个数据源 = 改一遍 Agent**：耦合在 prompt 里，每次加源都改动核心逻辑，回归测试全重跑。

工具化封装就是解决这四个问题的：**面向 Agent 的是统一协议，面向数据源的是各自的适配器**。

## 二、统一工具协议：定义 Agent 所见

先定协议——Agent 看到的所有工具共享同一张脸：

```python
from pydantic import BaseModel
from typing import Optional

class UnifiedRetrievalInput(BaseModel):
    """所有检索工具的统一入参"""
    query: str                      # 自然语言查询或关键词
    filters: Optional[dict] = None  # 结构化过滤（时间、类型、部门…）
    top_k: int = 5                  # 返回条数

class UnifiedHit(BaseModel):
    """统一结果单元"""
    id: str
    score: float
    title: str
    snippet: str                    # 压缩摘要（不是全文！）
    source: str                     # 数据源标识：es_logs / mysql_orders / confluence
    metadata: dict                  # 时间、作者、权限标签等
    full_text_ref: Optional[str]    # 深挖取全文的引用句柄

class UnifiedRetrievalOutput(BaseModel):
    hits: list[UnifiedHit]
    total: int
    took_ms: int
```

**这个协议设计的三个关键决策：**

1. **snippet 而不是 full_text**：默认返回压缩内容（一两百字），全文通过 `full_text_ref` 按需取——**上下文预算的第一道闸**，Agentic 场景下这是省钱关键；
2. **source 字段必填**：Agent 知道每条信息来自哪，答案里能做来源标注；审计时能回溯；
3. **filters 结构化**：Agent 可以表达"只看 2026 年的"，但不用知道底层是 ES 的 range query 还是 SQL 的 WHERE——过滤语义统一。

## 三、适配器模式：各数据源的实现

每种数据源一个适配器，实现同一接口：

```python
class BaseAdapter(ABC):
    source_name: str

    @abstractmethod
    def search(self, inp: UnifiedRetrievalInput, ctx: UserContext) -> UnifiedRetrievalOutput:
        ...

    @abstractmethod
    def get_full_text(self, ref: str, ctx: UserContext) -> str:
        ...
```

### 3.1 向量库适配器

```python
class VectorStoreAdapter(BaseAdapter):
    source_name = "kb_docs"

    def search(self, inp, ctx):
        # 1. 查询改写（可复用查询理解的中间产物）
        # 2. 带权限过滤的向量检索（关键！权限下推到检索层）
        results = vector_store.search(
            embedding=embed(inp.query),
            top_k=inp.top_k * 2,   # 多取一倍，过滤后可能不够
            where={
                "acl.visible_to": ctx.user_groups,      # 多租户 ACL
                "doc_type": inp.filters.get("doc_type"),
                "created_at": {"$gte": inp.filters["start"]} if inp.filters else None,
            }
        )
        # 3. 转统一格式：snippet 取 chunk 前 200 字
        return UnifiedRetrievalOutput(
            hits=[...], total=len(results), took_ms=12)

    def get_full_text(self, ref, ctx):
        doc = vector_store.get(ref, check_acl=ctx)   # 取全文时二次校验权限
        return doc.full_text
```

注意 `top_k * 2` 和 `get_full_text` 里的权限二次校验——**权限在检索层过滤、在取全文层复核，两层都要**（ACL 元数据可能滞后，取全文时文档权限可能已变更）。

### 3.2 ES 适配器：query DSL 翻译

```python
class ElasticsearchAdapter(BaseAdapter):
    source_name = "es_logs"

    def search(self, inp, ctx):
        must = [{"multi_match": {"query": inp.query, "fields": ["title^2", "body"]}}]
        # filters → ES 结构化过滤翻译
        if inp.filters:
            if "start" in inp.filters:
                must.append({"range": {"@timestamp": {"gte": inp.filters["start"]}}})
            if "level" in inp.filters:
                must.append({"term": {"level": inp.filters["level"]}})
        # 权限：按用户可见的业务线过滤
        must.append({"terms": {"biz_line": ctx.visible_biz_lines}})

        resp = self.es.search(index="logs-*", body={
            "query": {"bool": {"must": must}},
            "size": inp.top_k,
            "_source": ["title", "body", "@timestamp", "biz_line"],
        })
        # 统一成 hits，body 截断成 snippet
        ...
```

**翻译层是每个适配器的核心工作**：把统一 filters 译成 ES DSL / SQL WHERE / CQL。翻译逻辑集中在一处，Agent 永远看不到底层差异。

### 3.3 SQL 适配器：白名单查询 + 只读护栏

数据库类数据源是最危险的——Agent 生成的 SQL 要是能跑任意语句，一次注入就是事故。安全做法**禁止自由 SQL，只允许模板化白名单查询**：

```python
class MySQLAdapter(BaseAdapter):
    source_name = "db_orders"

    # 白名单查询：每个有明确语义和安全边界
    TEMPLATES = {
        "order_by_user": {
            "sql": "SELECT id, amount, status, created_at FROM orders "
                   "WHERE user_id = %(user_id)s "
                   "AND created_at >= %(start)s LIMIT %(limit)s",
            "params_schema": {"user_id": "str", "start": "date", "limit": "int"},
            "allowed_sort": [],
        },
        "order_stats_by_status": {
            "sql": "SELECT status, COUNT(*) cnt, SUM(amount) total "
                   "FROM orders WHERE created_at >= %(start)s GROUP BY status",
            ...
        },
    }

    def search(self, inp, ctx):
        # 查询分类器决定用哪个模板（LLM 分类 or 规则）
        template_name = self.route(inp.query)
        tpl = self.TEMPLATES[template_name]
        params = self.extract_params(inp, tpl["params_schema"])
        rows = self.db.execute(tpl["sql"], params)   # 参数化查询
        return UnifiedRetrievalOutput(hits=[row_to_hit(r) for r in rows], ...)
```

三条铁律：**只走模板、参数化传参、连接用只读账号**。Agent 想自由发挥 SQL，门都没有。

### 3.4 Wiki/API 适配器

Confluence、飞书知识库这类，适配器做三件事：认证透传（用 ctx 里的用户身份调 API，**不能用服务账号绕过权限**）、HTML/Markdown 转 snippet、分页归一。

## 四、权限注入：工具层是最佳位置

权限该在哪管？答案是**工具层，用调用上下文贯穿**：

```python
class UserContext(BaseModel):
    user_id: str
    groups: list[str]                # AD/LDAP 组
    visible_biz_lines: list[str]     # 可见业务线
    doc_acl: dict[str, list[str]]    # 文档级 ACL 映射（如需要）

# 工具调用链
agent.call_tool("search_docs", args, ctx=user_ctx)
    → adapter.search(inp, ctx)
        → 检索层 where 权限过滤（向量库/ES 的 ACL 过滤）
        → 取全文层 ACL 复核
        → 结果带 source + metadata 返回
```

三个设计要点：

1. **权限下推到检索层**，不是查完再过滤——查 1000 条过滤剩 5 条是浪费，且 top_k 语义全乱；
2. **取全文时复核**：检索到 → 决定看全文 → 这一刻再校验一次（中间文档权限可能变了）；
3. **全程记录审计日志**：哪个用户、什么查询、命中哪些文档、调了哪个工具——合规审查和安全复盘全靠它。

## 五、工具注册与发现

数据源多了，工具注册要动态化：

```python
class ToolRegistry:
    def __init__(self):
        self._adapters = {}

    def register(self, adapter: BaseAdapter, description: str, when_to_use: str):
        self._adapters[adapter.source_name] = adapter

    def tool_specs(self, ctx) -> list[dict]:
        """按用户可见的数据源生成工具清单"""
        specs = []
        for name, ad in self._adapters.items():
            if not ctx.can_access(name):
                continue          # 没权限的数据源，Agent 根本看不到这个工具
            specs.append({
                "type": "function",
                "function": {
                    "name": f"search_{name}",
                    "description": f"{description}。适用场景：{when_to_use}",
                    "parameters": UnifiedRetrievalInput.model_json_schema(),
                }
            })
        return specs
```

**"没权限就看不到"比"看到了但报错"好两个量级**——Agent 不会去尝试不可用的工具，prompt 也更干净。权限感知的工具清单，是安全和效果的共同最优解。

## 六、性能与可靠性

统一封装层还顺手解决三个工程问题：

1. **超时与降级**：每个适配器配超时（ES 2s、SQL 5s、外部 API 10s），超时返回"该源暂不可用"而不是拖死整个 Agent——Agent 可以基于其他源继续答；
2. **并发调用**：Agent 一轮里调三个工具时并发执行，延迟取 max 而非 sum；
3. **结果缓存**：相同 query + filters + 用户组的检索结果缓 5 分钟（工具层的语义缓存），Agent 重复检索同一内容时直接命中——省 API 也省数据源压力。

## 七、落地检查清单

- [ ] 统一协议定义：统一入参（query/filters/top_k）、统一结果（snippet 模式 + source + metadata + full_text_ref）；
- [ ] 每个数据源一个适配器，filters 翻译逻辑集中在适配器内；
- [ ] SQL 类源只走白名单模板 + 参数化 + 只读账号，禁止自由 SQL；
- [ ] 权限下推检索层 + 取全文复核两层，UserContext 贯穿全链；
- [ ] 工具清单按权限生成，无权限数据源不可见；
- [ ] 工具 description 写清适用/不适用场景（这是路由准确率的一半）；
- [ ] 适配器级超时 + 降级 + 并发 + 缓存；
- [ ] 审计日志：用户/查询/命中/工具四要素落库。

## 八、小结

检索工具化的三句话：

- **面向 Agent 统一协议，面向数据源各自适配**：统一入参、统一结果（snippet 优先、全文按需）、统一权限模型——Agent 永远只看到一套工具；
- **适配器模式隔离差异**：filters 翻译成各家的 DSL/SQL/白名单，翻译逻辑集中，加数据源不动 Agent 核心；
- **权限在工具层收口**：检索层下推过滤、取全文层复核、按权限生成工具清单——安全、效果、可审计三个目标一次满足。

下一篇讲长文档处理：当文档超过上下文窗口，分层摘要和父子索引怎么兜住检索质量。
