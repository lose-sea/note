# 物化策略专题：MySQL 的临时表都分派给谁干了什么

derived_merge、semi-join、subquery 的执行计划里，反复出现同一个角色——**物化（Materialize）**。它像个加班的中转站：把中间结果算出来、写进临时表、下游多次查询。用好了是性能杠杆，用砸了是故障源。这篇文章把物化策略集中讲透：哪些场景会触发物化、临时表的两副面孔、内存和磁盘的边界、以及怎么监控这个"中转站"堵没堵。

## 物化是什么：三个动作，一个目的

无论哪种优化触发的物化，本质都是同样三步：

```
1. 执行子查询/派生表，产生一组中间行
2. 把结果写入一张内部临时表（IMPORTANT：这不是用户可见的表）
3. 下游查询访问这张临时表，往往还在上面建索引加速查找
```

目的只有一个：**把"每次用都重算"变成"算一次到处用"**。当同一个子结果被引用多次、或者结果集比原始输入小得多时，物化是笔划算的买卖；反之就是纯亏。

## 触发物化的五类场景

对照执行计划，物化出现在这些地方：

### 场景一：Derived table 不能 merge

上一篇讲过——有聚合、LIMIT、UNION、非确定性函数的派生表，无法拍平进外层，只能物化。执行计划里出现 `Materialize subquery` 节点。常见于报表子查询：

```sql
SELECT * FROM (SELECT customer_id, SUM(amount) s FROM orders GROUP BY customer_id) t
WHERE t.s > 10000;
```

### 场景二：Semi-join 的 Materialization 策略

`IN (SELECT ...)` 子查询结果小时，优化器把子查询物化成带索引的临时表，外层每行来查一次。执行计划：`Semijoin → Materialize → Index lookup`。**物化表上自动建的索引是它快的根本原因**——否则物化出来也没法高效查找。

### 场景三：相关子查询的物化改写

8.0 把部分相关子查询（依赖外层的子查询）转换为 semi-join 再物化。经典的 `EXISTS (SELECT 1 FROM ... WHERE b.id = a.id)` 在特定条件下被反嵌套 + 物化。这是一种"猜你最终要这个"的激进优化，EXISTS、IN 的执行计划里可能悄悄变成物化。

### 场景四：UNION 的中间结果

UNION（去重）需要"两张表合并 + 去重"，实现路径就是物化全部输入到临时表再做唯一化。大表的 UNION 是性能重灾区，能改 UNION ALL 就别 UNION。

### 场景五：DISTINCT / GROUP BY 的兜底

没索引可用时，DISTINCT 和 GROUP BY 的兜底实现就是"全量物化 + 去重/分组"。执行计划里 `Temporary table` 节点的来源。这类物化是"没得选"的信号——出现它，先检查是不是缺了合适的索引。

## 临时表的两副面孔

MySQL 的临时表不是只有一种，内部按存储引擎分两条路：

**Memory 引擎（默认首选）**：哈希索引、内存存储、快。但有两个硬限制：

- 行宽超限自动转磁盘（和行格式、列类型共同决定的阈值）。
- **TEXT/BLOB 列**在 memory 临时表里支持很差，几乎必然转磁盘。

**InnoDB 引擎**：当结果集超过 `tmp_table_size` 上限时，Memory 临时表溢出到磁盘临时表（InnoDB 存储）。`max_heap_table_size` 是 Memory 表的硬顶，两者取小生效。

**判断物化走了哪条路**：`SHOW STATUS LIKE 'Created_tmp_disk_tables'` 增量、或 EXPLAIN ANALYZE 的耗时结构（物化阶段占大头且巨慢，大概率落盘了）。Performance Schema 里能按 SQL 语句看临时表使用明细：

```sql
SELECT * FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_CREATED_TMP_TABLES DESC LIMIT 10;
```

磁盘临时表 = 物化的成本爆炸点，**一张本该内存里完成的聚合物化到了磁盘，性能掉一个数量级**。

## 物化的成本账：什么时候亏

物化的收益是"少算"，成本是"物化的建立 + 存储"。判断这笔账的四个维度：

**1. 引用次数**。物化表被访问几次？只用一次的物化，等于白建一次临时表。执行计划里物化节点被 join 引用一次还是多次，EXPLAIN 的子节点结构能看出来。

**2. 输入输出比**。物化后剩多少行？子查询 500 万行过滤后剩 500 行，物化血赚；5000 行进 5000 万行出（一对多爆炸），物化等于请了个爹。**下单前算好中间结果规模**，这是 SQL 评审就该做的事。

**3. 内存是否放得下**。预估行数 × 行宽 vs tmp_table_size。放不下的物化全部要过磁盘，优势全无。

**4. 临时表索引能否建**。物化后要被频繁等值查找，临时表上自动建的哈希索引是关键；如果物化表拿到外层还要范围扫描，收益打折。

一个反直觉的结论：**物化不是越小越快**。50 行的物化表，物化本身的开销（建临时表元数据）占比反而高；几万行、被引用三四次的物化才最划算。优化器按成本模型选，你看 EXPLAIN ANALYZE 物化节点的实际耗时验证。

## 干预手段：让物化发生或不发生

### 让它别物化

```sql
-- 关掉 semi-join 物化策略（会话级诊断用）
SET SESSION optimizer_switch='semijoin=off,materialization=off';
```

但注意：这往往让优化器走 firstmatch 或 dupsweedout 而不是放弃优化。真正"不想物化"的场景，应该从 SQL 改写入手——把聚合子查询改成 join + 聚合。

反过来，想强制物化（避免优化器做了错判的 merge）用 CTE 显式控制：

```sql
-- 显式要求物化（8.0.14+ 语法）
WITH t AS MATERIALIZED (
    SELECT customer_id, SUM(amount) s FROM orders GROUP BY customer_id
)
SELECT * FROM t JOIN vip v ON t.customer_id = v.id WHERE t.s > 10000;
```

`MATERIALIZED` 和 `NOT MATERIALIZED` 关键词让你从"猜优化器心情"变成"明确告诉它"。**这是 8.0 之后写复杂子查询最重要的一个语法武器**——CTE 被引用多次时，显式 MATERIALIZED 防止优化器把它 inline 展开算 N 遍；CTE 只用一次且想让它下推条件时，NOT MATERIALIZED 强制合并。

### 让它物化得更好

物化已经选了，就优化物化的输入：**把过滤条件下推进子查询**。子查询里的 WHERE 越严，物化行数越少。这是零成本的改法：

```sql
-- 差：CTE 先算全量再外层过滤
WITH t AS (SELECT * FROM orders) SELECT * FROM t WHERE created_at > '...';
-- 好：条件下推，物化输入直接变小
WITH t AS (SELECT * FROM orders WHERE created_at > '...') SELECT * FROM t;
```

注意行为差异：MATERIALIZED 的 CTE 通常不下推外层条件（它要独立算完），条件留在子查询里更是关键；NOT MATERIALIZED 则可以下推。

## 监控：盯住这个中转站

物化引发的故障模式很固定：**内存临时表转磁盘 → 磁盘 IO 打满 → 全实例变慢**。监控三件套：

```sql
-- 1. 磁盘临时表比率（全局）
SHOW GLOBAL STATUS LIKE 'Created_tmp%tables';
-- Created_tmp_disk_tables / Created_tmp_tables 超过 20% 就要查

-- 2. 谁在产磁盘临时表
SELECT DIGEST_TEXT, COUNT_STAR, SUM_CREATED_TMP_TABLES, SUM_CREATED_TMP_DISK_TABLES
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_CREATED_TMP_DISK_TABLES > 0
ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC LIMIT 20;
```

慢查询里如果物化/临时表是耗时大头，两条路：调大 `tmp_table_size`（如果内存富余且并发可控），或改写 SQL 缩小物化输入。**优先改写——加内存只是把爆炸点延后。**

## 小结

物化策略是 MySQL 优化器的"缓存层"：derived table、semi-join、UNION 都在用它。读执行计划认出 Materialize 节点，用 EXPLAIN ANALYZE 量它的实际耗时，用 CTE 的 MATERIALIZED / NOT MATERIALIZED 显式控制，用条件下推缩小它的输入，用监控盯住磁盘临时表比率。中转站不堵，复杂查询才快。下一篇讲 semi-join 六策略里最被低估的一个——FirstMatch。
