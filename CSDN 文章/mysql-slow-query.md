# MySQL 慢查询排查实战：慢日志、mysqldumpslow 到完整排查链路

> 线上接口突然变慢，第一反应往往是"数据库慢了"。
> 但"慢"是个感觉，需要证据。
>
> 本篇讲一套完整的排查链路：怎么开慢日志、怎么分析慢日志、
> 怎么定位到具体 SQL、以及拿到 SQL 后怎么优化。

## 一、先把慢日志开起来

慢查询日志（slow query log）是排查的起点。
它记录执行时间超过 `long_query_time` 的 SQL。

```sql
-- 查看当前配置
SHOW VARIABLES LIKE 'slow_query_log';        -- 是否开启
SHOW VARIABLES LIKE 'long_query_time';       -- 阈值（秒），默认 10
SHOW VARIABLES LIKE 'slow_query_log_file';   -- 日志文件路径
SHOW VARIABLES LIKE 'log_queries_not_using_indexes';  -- 是否记录未走索引的
```

**临时开启（重启失效）**：

```sql
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;              -- 生产建议 1 秒，甚至 0.5
SET GLOBAL log_queries_not_using_indexes = ON;
```

⚠️ 两个注意点：

1. `long_query_time` 修改后**只对新建连接生效**，
   当前连接需要重连才生效（或用 `SET SESSION`）
2. `long_query_time` 支持小数（微秒级精度），MySQL 5.6+ 可以设 0.1

**永久开启**（改配置文件 `my.cnf`）：

```ini
[mysqld]
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1
log_queries_not_using_indexes = 1
log_output = FILE          # 也可以写 TABLE（存到 mysql.slow_log 表）
```

改完重启 MySQL。

⚠️ 生产的顾虑：**慢日志会写磁盘，高并发下有一定性能影响**。
建议：
- 阈值别设太低（0.1 秒会记录海量日志）
- 定期清理 / 轮转日志
- 也可以只开一段时间采样，排查完关掉

## 二、慢日志长什么样

```
# Time: 2026-10-07T06:25:11.123456Z
# User@Host: app[app] @  [10.0.0.5]  Id:  1234
# Query_time: 3.245871  Lock_time: 0.000125  Rows_sent: 10  Rows_examined: 850000
SET timestamp=1759815911;
SELECT * FROM orders WHERE user_id = 12345 AND status = 'paid' ORDER BY created_at DESC LIMIT 10;
```

重点读这四个字段：

| 字段 | 含义 | 怎么看 |
|---|---|---|
| `Query_time` | 查询总耗时 | 主要指标 |
| `Lock_time` | **等待锁的时间** | 高说明有锁竞争，不是 SQL 本身慢 |
| `Rows_sent` | **返回行数** | 客户端拿到的行数 |
| `Rows_examined` | **扫描行数** | 引擎扫描的行数 |

🔑 **最重要的一个判断：`Rows_examined / Rows_sent` 的比值**。

上面那个例子：返回 10 行，扫描了 85 万行——**比值 85000:1**。
这说明索引没用对，扫描了大量无用数据。
**健康的值应该在 100:1 以内，最好接近 1:1。**

另一个关键判断：**`Lock_time` 占比**。
如果 `Query_time=3.2s` 而 `Lock_time=3.1s`，
那瓶颈根本不是 SQL 慢，是**被别的锁阻塞了**，
要去查锁（见上一篇），优化 SQL 没用。

## 三、mysqldumpslow：官方分析工具

```bash
# 慢日志里最耗时的前 10 条（按总时间排序）
mysqldumpslow -s t -t 10 /var/log/mysql/slow.log

# 出现次数最多的前 10 条
mysqldumpslow -s c -t 10 /var/log/mysql/slow.log

# 返回行数最多的
mysqldumpslow -s r -t 10 /var/log/mysql/slow.log

# 只看包含 'orders' 表的
mysqldumpslow -g 'orders' /var/log/mysql/slow.log
```

输出示例：

```
Count: 1523  Time=2.35s (3578s)  Lock=0.00s (0s)  Rows=10.0 (15230), app[app]@[10.0.0.5]
  SELECT * FROM orders WHERE user_id = N AND status = 'S' ORDER BY created_at DESC LIMIT N
```

注意它的**归一化**：具体数字被替换成了 `N` 和 `S`。
所以 `Count: 1523` 表示这类 SQL 出现了 1523 次，
总耗时 3578 秒——**这才是真正该优先优化的目标**。

一条执行 5 秒但一天只跑 1 次的 SQL，
不如一条执行 0.5 秒但一天跑 10 万次的 SQL 值得优化。
**优先看 Count × Time 的乘积**。

### 更好用的工具：pt-query-digest

Percona Toolkit 里的 `pt-query-digest` 比 `mysqldumpslow` 强很多：

```bash
pt-query-digest /var/log/mysql/slow.log > report.txt

# 分析最近 12 小时的
pt-query-digest --since 12h /var/log/mysql/slow.log

# 直接分析 TCP 抓包（不用开慢日志）
tcpdump -s 65535 -x -nn -q -tttt -i any -c 1000 port 3306 > mysql.tcp
pt-query-digest --type tcpdump mysql.tcp
```

它的报告会给出**每个 SQL 的响应时间分布、95 分位、索引使用情况**，
信息量大得多。生产排查推荐用它。

## 四、正在运行的慢查询怎么看

慢日志是"事后"的。如果要看**此刻**正在跑的慢 SQL：

```sql
-- 查看所有连接，按执行时间倒序
SELECT id, user, host, db, command, time, state, LEFT(info, 100) AS sql_text
FROM information_schema.processlist
WHERE command != 'Sleep' AND time > 2
ORDER BY time DESC;
```

关键字段：

- `time`：当前状态已持续多少秒
- `state`：在干什么（这是**最重要的线索**）
- `info`：SQL 文本（可能被截断，用 `SHOW FULL PROCESSLIST` 看全）

常见的 `state` 及其含义：

| state | 含义 | 该怎么办 |
|---|---|---|
| `Sending data` | 正在读取/发送数据（**不一定是在发网络包**） | 多半是扫描行数太多 |
| `Locked` | 等待表锁 | 查锁 |
| `Waiting for ... lock` | 等待行锁/元数据锁 | 查锁（上一篇） |
| `Sorting result` | 正在排序 | 排序数据量大，考虑用索引避免排序 |
| `Creating sort index` | 创建排序临时结构 | 同上，可能用了临时表 |
| `Copying to tmp table` | 拷贝到临时表 | GROUP BY / 子查询导致，可能要改 SQL |
| `statistics` | 优化器在统计信息阶段 | 极少见，可能表太多 |

⚠️ **`Sending data` 这个 state 名字极具误导性**。
它实际含义是"执行器正在处理数据"，
包括扫描行、过滤、排序等，跟"发给客户端"几乎无关。
看到它就去看 `Rows_examined`。

终止一个查询：

```sql
KILL QUERY 1234;     -- 只杀这条 SQL，保留连接
KILL 1234;           -- 杀掉整个连接
```

## 五、Performance Schema：更强大的方式

MySQL 5.6+ 有 `performance_schema`，可以直接查聚合统计：

```sql
-- 按总耗时排的 TOP SQL
SELECT
    DIGEST_TEXT AS 归一化SQL,
    COUNT_STAR AS 执行次数,
    ROUND(SUM_TIMER_WAIT/1000000000000, 2) AS 总耗时秒,
    ROUND(AVG_TIMER_WAIT/1000000000000, 4) AS 平均耗时秒,
    SUM_ROWS_EXAMINED AS 总扫描行数,
    SUM_ROWS_SENT AS 总返回行数,
    SUM_NO_INDEX_USED AS 未用索引次数
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10\G
```

这个比慢日志更好用的地方：
- **不用开慢日志**，默认就在统计
- 有 `SUM_NO_INDEX_USED`，直接告诉你哪些 SQL 没走索引
- 有 `SUM_ROWS_EXAMINED / SUM_ROWS_SENT`，一眼看出扫描比

```sql
-- 找出全表扫描次数最多的表
SELECT OBJECT_SCHEMA, OBJECT_NAME, COUNT_READ, COUNT_WRITE
FROM performance_schema.table_io_waits_summary_by_table
WHERE COUNT_READ > 0
ORDER BY COUNT_READ DESC LIMIT 10;
```

## 六、拿到慢 SQL 之后怎么办

排查流程：

```
发现慢 SQL
    │
    ├─ Lock_time 占比高？ → 查锁（innodb_trx / sys.innodb_lock_waits）
    │
    ├─ Rows_examined >> Rows_sent？ → 索引问题 → EXPLAIN
    │
    ├─ 有 Using filesort / Using temporary？ → 排序/分组没走索引
    │
    └─ 索引都正常还慢？ → 数据量太大 → 考虑分页优化/分库分表/缓存
```

### 常见优化手法

**1. 加索引**（最常用）

```sql
-- 原：WHERE user_id=? AND status=? ORDER BY created_at DESC
ALTER TABLE orders ADD INDEX idx_user_status_time (user_id, status, created_at);
```

联合索引的顺序要遵循**最左匹配**，且**等值在前、范围/排序在后**。

**2. 避免 SELECT \***

```sql
SELECT * FROM orders WHERE ...;              -- 回表取所有列
SELECT id, order_no, amount FROM orders ...; -- 只取需要的列
```

如果索引能覆盖所有需要的列（**覆盖索引**），就不用回表，能快很多。

**3. 深分页优化**

```sql
-- 慢：要扫描并丢弃 100000 行
SELECT * FROM orders ORDER BY id LIMIT 100000, 20;

-- 快：用主键锚点
SELECT * FROM orders WHERE id > 上次最大id ORDER BY id LIMIT 20;

-- 或者延迟关联
SELECT o.* FROM orders o
INNER JOIN (SELECT id FROM orders ORDER BY id LIMIT 100000, 20) t USING (id);
```

**4. 避免索引列上做运算**

```sql
WHERE DATE(created_at) = '2026-10-07'                    -- ❌ 索引失效
WHERE created_at >= '2026-10-07' AND created_at < '2026-10-08'   -- ✅

WHERE amount * 2 > 100       -- ❌
WHERE amount > 50            -- ✅
```

**5. 用 EXPLAIN 验证**

优化后**必须用 EXPLAIN 验证**索引是否真的被用上。
这是下一篇的主题。

## 七、一条完整的排查命令序列

线上出问题时的实操顺序：

```sql
-- 1. 看当前有多少连接、有没有堆积
SHOW STATUS LIKE 'Threads_%';
-- Threads_connected 接近 max_connections 就危险了

-- 2. 看此刻最慢的在跑什么
SELECT id, time, state, LEFT(info, 120) FROM information_schema.processlist
WHERE command != 'Sleep' ORDER BY time DESC LIMIT 10;

-- 3. 有没有锁等待
SELECT * FROM sys.innodb_lock_waits;

-- 4. 看最近统计的 TOP SQL
SELECT DIGEST_TEXT, COUNT_STAR,
       ROUND(AVG_TIMER_WAIT/1e12, 3) AS avg_sec,
       SUM_ROWS_EXAMINED, SUM_ROWS_SENT
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC LIMIT 5\G

-- 5. 定位到具体 SQL 后
EXPLAIN SELECT ...;

-- 6. 确认要杀的话
KILL QUERY <id>;
```

## 八、三个易踩的坑

**坑 1：慢日志记录了但没开**
很多环境默认 `slow_query_log = OFF`。
出事时才发现没开，只能干瞪眼。**上线前就配上**。

**坑 2：只优化单条 SQL，不看调用次数**
一条 5 秒的 SQL 每天跑 2 次，优化收益远小于
一条 0.3 秒但每天跑 50 万次的。**按总时间排序，不是按单次时间**。

**坑 3：慢日志里的 SQL 是"结果"不是"原因"**
SQL 慢可能是被锁阻塞（`Lock_time` 高），
也可能是因为数据库整体压力大（CPU/IO 打满）。
先看 `Lock_time`，再看系统负载。

## 九、小结

- 慢日志关键字段：**`Query_time`、`Lock_time`、`Rows_sent`、`Rows_examined`**
- 🔑 **`Rows_examined / Rows_sent` 比值**是最直接的索引健康度指标
- **`Lock_time` 高说明是锁问题**，优化 SQL 没用，要去查锁
- `mysqldumpslow` 按 `-s t`（总时间）排序，**优先看 Count × Time**
- 生产推荐 `pt-query-digest`，信息更全
- 查实时慢 SQL 用 `information_schema.processlist`，重点看 `state`
- **`Sending data` 不代表在发网络包**，是"正在处理数据"
- Performance Schema 的 `events_statements_summary_by_digest`
  不用开慢日志就能统计，非常值得用
- 优化优先级按**总耗时**排，不是单次耗时

下一篇讲 EXPLAIN——它是慢查询排查的"显微镜"，
拿到慢 SQL 之后，就得靠它看清 MySQL 到底怎么执行的。
