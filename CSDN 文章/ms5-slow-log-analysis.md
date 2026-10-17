# MySQL 慢日志分析实战：从几百兆日志到三条优化项

慢查询日志天天在写，文件几个 G，但"打开了慢日志"和"会分析慢日志"之间隔着一整套方法论。不会分析的表现是：要么日志躺平没人看，要么一上来看花了眼，随便挑几条 EXPLAIN 一下，改完没效果。这篇文章把慢日志分析的标准流程讲透：怎么配才不炸、怎么用 pt-query-digest 找出"最该优化的三条"、`EXPLAIN` 之后怎么看、以及和 `performance_schema` 的配合姿势。

## 一、慢日志的正确配置：别让分析工具先拖垮库

慢日志的配置参数看着简单，配错了要么没用、要么把库搞挂：

```sql
SHOW VARIABLES LIKE 'slow_query_log%';
SHOW VARIABLES LIKE 'long_query_time';
SHOW VARIABLES LIKE 'log_queries_not_using_indexes';
SHOW VARIABLES LIKE 'min_examined_row_limit';
```

核心参数：

| 参数 | 建议值 | 说明 |
|---|---|---|
| `long_query_time` | 0.5~1 秒 | 超过这个值记日志。别设 0！0 = 全量记录，日志秒爆炸 |
| `log_queries_not_using_indexes` | ON | 记录没用索引的查询——**它不受 long_query_time 影响**，这是"全表扫描收割机" |
| `min_examined_row_limit` | 1000~10000 | 扫描行数低于此值的不记。配合上一个参数，滤掉"查小表全扫描"的噪音 |
| `log_slow_admin_statements` | ON | DDL、`ALTER` 也记 |
| `log_slow_replica_statements` | ON | 从库上的慢查询也记（复制引起的 CommSql_delay 慢句） |
| `slow_query_log_file` | 独立磁盘 | 别和 datadir 争 IO |

**黄金组合**（生产常用）：

```sql
SET GLOBAL long_query_time = 0.5;
SET GLOBAL log_queries_not_using_indexes = ON;
SET GLOBAL min_examined_row_limit = 1000;
```

**为什么 `long_query_time=0` 是禁区**：它记录每一条语句，写日志的开销（磁盘 + 锁）随 QPS 线性增长，实测能把生产库拖慢 30%+。**要抓全量语句用 `performance_schema`，不要用慢日志全量模式。**

**8.0 的改进**：`long_query_time` 支持微秒精度（`0.5` 可以写 `0.500000`），慢日志输出到 `mysql.system` 库的 slow_log 表（CSV 引擎），可以用 SQL 直接查——比 grep 文件方便。

**日志轮转必须配**：慢日志不会自动切，几个月能涨到几十 G。用 `logrotate` 按日切，或 8.0 用 `FLUSH SLOW LOGS` 配合外部调度。别等磁盘满了才发现。

## 二、pt-query-digest：慢日志分析的标准入口

日志拿到手，别 `grep`，用 `pt-query-digest`（Percona Toolkit）做归一化聚合：

```bash
pt-query-digest /var/log/mysql/slow.log > slow_report.txt
```

它做的事：把SQL里的字面量归一化（`WHERE id=123` 和 `WHERE id=456` 视为同一条），按指纹（fingerprint）聚合，输出排序报告。**报告的结构是精华**，按这个顺序读：

```
# 总览：总时间、总查询数、唯一查询数、QPS 等
# Profile：按"总耗时"排序的 Top SQL
# Query 1: 0.89 QPS, 0.34x concurrency, 1.2M times executed, 45% total
#    执行次数：1,200,000 次
#    总耗时：8,400 秒（占全部慢日志 45%）
#    ...
#    EXPLAIN /*!50100 PARTITIONS*/
#    SELECT * FROM t_order WHERE user_id = 123 AND status = 1\G
```

**读报告的四个维度**（这是分析的核心方法论）：

| 维度 | 说明 | 优先级 |
|---|---|---|
| **总耗时占比** | 这条 SQL 累计花了多少时间 | 降整体负载的主战场 |
| **执行次数 × 单次耗时** | 高频低耗时 = 量的暴政；低频高耗时 = 个案 | 两个都要治，手段不同 |
| **扫描行数/返回行数比** | 扫 100 万行返回 10 行 = 索引/写法有问题 | 判断优化空间 |
| **并发度（concurrency）** | 执行时长 × QPS，体现"同时占用数据库的程度" | 连接池打满、CPU 飙高的元凶 |

**那个"1.2M times executed, 45% total"的含义**：这条查询跑了一百万次，累计占慢日志总耗时的 45%。它不是最慢的，但**它是最该优化的**——单次快 10 毫秒，一百万次就省回 10000 秒。而排第二的"单次 30 秒但一天只跑 5 次"的报表 SQL，优化它对整体负载毫无意义（但对用户体验有意义，另行处理）。

**这就是慢日志分析的核心判断：先优化"高频 × 中低耗时"，再治"低频 × 高耗时"。** 顺序反了，投入产出比差十倍。

## 三、从报告到行动：四类问题的标准路径

pt-query-digest 报出的 Top SQL，逐条走这个决策树：

### 3.1 类型一：高频 + 全表扫描

特征：执行次数百万级，`Rows_examined` 巨大、`Rows_sent` 很小。

```sql
EXPLAIN SELECT * FROM t_order WHERE user_id = 123 AND status = 1;
-- type: ALL, rows: 2000000, key: NULL
```

**动作**：加索引。`user_id` 和 `status` 的组合，建 `(user_id, status)` 联合索引（等值列在前）。加完复测 `Rows_examined` 应降到个位数。

### 3.2 类型二：高频 + 索引走了但还是很慢

特征：`key` 有值，`rows` 也不夸张，但单次耗时几百毫秒。

排查顺序：

1. **回表太多**：`SELECT *` 导致大量回表，改成覆盖索引（只查索引列）；
2. **排序/分组**：`ORDER BY` 字段没进索引，filesort 小表没事大表致命；
3. **函数吞噬索引**：`WHERE DATE(created_at) = '2026-10-16'`——列上包了函数，索引失效，改成范围查询 `WHERE created_at >= '2026-10-16' AND created_at < '2026-10-17'`；
4. **隐式类型转换**：`WHERE phone = 74955953457`——phone 是 VARCHAR，数字比较触发转换，索引失效；
5. **分页深翻**：`LIMIT 1000000, 10`——扫描一百万行扔一百万行，改游标分页（`WHERE id > 上一页最大id LIMIT 10`）。

### 3.3 类型三：低频 + 高耗时

特征：一天几次，一次几秒到几十秒（报表、统计、定时任务）。

**动作**：

- 改写 SQL（大表 JOIN 小表 vs 小表驱动大表）；
- 引导走汇总表/物化视图（MySQL 没原生物化视图，用定时任务建汇总表是常规操作）；
- 这种查询如果躲不开，挪到从库跑——它不配占用主库资源。

### 3.4 类型四：写入类的慢

`INSERT`/`UPDATE`/`DELETE` 慢，别急着加索引，先看：

- 是不是**批量插入太大**（单条 SQL 插一万行， undo log 膨胀）；
- 是不是**索引太多**（每个索引都要维护，写入放大）；
- 是不是**死锁/锁等待**（慢日志只能看到锁等待的时间，`SHOW ENGINE INNODB STATUS` 看死锁详情）；
- 是不是**purge/change buffer 压力**（`innodb_purge_threads`、`innodb_io_capacity` 调大）。

## 四、EXPLAIN 之后看什么：一张决策表

`EXPLAIN` 输出字段的解读，重点五个：

| 字段 | 健康值 | 差值 | 动作 |
|---|---|---|---|
| `type` | `const`/`eq_ref`/`ref`/`range` | `index`/`ALL` | ALL = 全表扫，必须处理 |
| `key` | 用上目标索引 | `NULL` | 检查列上有无索引、是否被函数/类型转换/前导模糊吞噬 |
| `rows` | 与返回行数同量级 | 大一个数量级以上 | 索引选择性差或统计信息过期（`ANALYZE TABLE`） |
| `Extra` | `Using index` | `Using filesort`/`Using temporary` | filesort 加排序列到索引；temporary 考虑改组聚合逻辑 |
| `key_len` | 用全联合索引 | 只用了一部分 | 联合索引列顺序不匹配查询条件 |

`EXPLAIN ANALYZE`（MySQL 8.0）更强：直接跑一遍，给出**真实执行时间和行数**，不是估算：

```sql
EXPLAIN ANALYZE SELECT ...;
-- -> Filter: (t.status = 1)  (actual time=0.035..8.2 rows=15 loops=2000)
```

"actual time" 和 "estimated rows" 差得多，就是统计信息问题——`ANALYZE TABLE t_order` 重建统计信息，成本低效果好，是"没改 SQL 但突然变慢"的标准急救。

**结合慢日志看**：慢日志记录的是"实际发生的慢"，`EXPLAIN ANALYZE` 是"现在再跑一次多慢"。如果 EXPLAIN ANALYZE 很快但慢日志天天记——大概率是**当时的负载/锁/缓存状态**导致的慢，往锁竞争、缓冲池污染方向查。

## 五、performance_schema：慢日志的补充与替代

慢日志有两个盲区：`long_query_time` 以下的查询（高频短查询累加起来也很致命），以及历史不可回溯（日志轮转就没了）。`performance_schema` 补这两个盲区：

```sql
-- 按总耗时排 Top SQL（默认已聚合）
SELECT digest_text, COUNT_STAR AS exec_count,
       SUM_TIMER_WAIT/1e12 AS total_sec,
       AVG_TIMER_WAIT/1e12 AS avg_sec,
       SUM_ROWS_EXAMINED/COUNT_STAR AS avg_rows_examined
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;
```

`events_statements_summary_by_digest` 表自动聚合所有语句（默认最多存 200 组，`performance_schema_digests_size` 可调），`SUM_TIMER_WAIT` 排序就是"谁最耗时"。**它比慢日志更全——记录了所有语句，不只慢的。**

配合两张表看锁和 IO：

```sql
-- 等锁的语句
SELECT * FROM performance_schema.events_statements_history WHERE LOCK_TIME > 0;

-- 文件 IO 热点表
SELECT file_name, count_read, count_write, sum_timer_wait
FROM performance_schema.file_summary_by_instance ORDER BY sum_timer_wait DESC LIMIT 10;
```

**实践姿势**：慢日志负责"抓大慢"和长期留档，performance_schema 负责"实时体检和全量视角"，两者配合使用。

## 六、优化效果的度量：别改完就完事

每次优化都要闭环验证，否则就是玄学优化：

1. **优化前基准**：pt-query-digest 报告存档，记下目标 SQL 的 QPS、平均耗时、扫描行数；
2. **执行优化**（加索引/改写 SQL/`ANALYZE TABLE`）；
3. **优化后对比**：同时间段再跑一次 pt-query-digest，同一条指纹的指标对比；
4. **业务指标**：接口 P99 延迟、DB CPU、连接数；
5. **确认无回归**：新索引让写入变慢了吗？（索引是双刃剑，每个索引都在拖慢 INSERT/UPDATE）

判断"优化成功"的最低标准：目标 SQL 的耗时下降 ≥ 50%，且整体 QPS 无明显劣化。达不到，方向就错了（大概率不是索引问题，是数据量/架构问题）。

## 七、一套可落地的例行流程

把上面所有内容收进日常：

**每周（30 分钟）**：
1. 拉取昨天慢日志，pt-query-digest 出报告；
2. 按"总耗时 Top 5 + 执行次数 Top 5"取交集候选；
3. 对候选逐条 EXPLAIN ANALYZE，能当场处理的当天处理；
4. 不能处理的登记优化 backlog，排期。

**每月**：
1. performance_schema 全量视角扫一遍（有没有新兴的高耗时查询）；
2. 检查索引冗余（`sys.schema_redundant_indexes`）；
3. `ANALYZE TABLE` 核心表（统计信息保鲜）。

**每次发布后**：新 SQL 灰度的第一份慢日志必查——新功能的慢查询在发布当天最明显，等用户投诉就晚了。

## 八、小结

慢日志分析的三句话：

- **配好参数再谈分析**：`long_query_time=0.5`、`log_queries_not_using_indexes=ON`、`min_examined_row_limit=1000`，日志轮转别忘；
- **读报告的四个维度**：总耗时占比、执行次数 × 单次耗时、扫描/返回行数比、并发度——先治"高频中低耗时"，再治"低频高耗时"；
- **优化必须闭环**：基准 → 优化 → 复测对比 → 业务指标，`EXPLAIN ANALYZE` 和 `performance_schema` 是左右手。

下一篇是 MySQL 系列的收尾，讲监控告警体系：mysqld_exporter 该采哪些指标、告警怎么分级、以及哪些指标是"事前信号"。
