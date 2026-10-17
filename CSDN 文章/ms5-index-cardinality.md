# 索引选择性与基数：量化一个索引"好不好"

"这个索引建了有用吗？"——这个问题不能靠感觉，能被量化。**选择性（Selectivity）= 不重复值数量 / 总行数**，它直接决定一个索引值不值得建、优化器会不会用。这篇文章讲选择性的计算方法、基数的两面性（是与非）、统计信息的采集盲区，以及怎么用它指导删索引。

## 选择性的定义与计算

```sql
-- 表总行数
SELECT COUNT(*) FROM orders;                          -- 1000 万

-- 某列的不同值数（基数 Cardinality）
SELECT COUNT(DISTINCT status) FROM orders;            -- 4
SELECT COUNT(DISTINCT user_id) FROM orders;           -- 500 万
SELECT COUNT(DISTINCT DATE(created_at)) FROM orders;  -- 730
```

选择性：

```
status:      4 / 10,000,000       = 0.0000004  （几乎无选择性）
user_id:     5,000,000 / 10,000,000 = 0.5       （极佳）
created_at:  730 / 10,000,000     ≈ 0.000073    （还行，取决于分布）
```

**选择性越接近 1，索引价值越高**。B+ 树查找的本质是"值 → 行的映射"：映射比 1:1（唯一索引）时一次点查定位一行；映射 1:N（status 一个值对应 250 万行）时，扫描一片和全表扫差别不大。

经验分级：

| 选择性 | 含义 | 索引用处 |
|---|---|---|
| ≈ 1.0 | 唯一/近唯一 | 点查神器，必建 |
| 0.01 ~ 0.1 | 高选择 | 独立索引或联合前导 |
| 0.001 ~ 0.01 | 中等 | 联合索引成员，慎独立 |
| < 0.001 | 低选择 | 独立索引多半浪费，除非 skip scan 场景 |

## 基数的两面性：不是所有高基数列都值得索引

选择性高 = 索引值得建？不止这么简单。三个纠偏：

**1. 查询频率比选择性更根本**。

```sql
-- 手机号选择性 1.0，但前台从不支持按手机号查
-- SELECT 只出现在登录注册场景，且已有账号主键路由
-- 建 mobile 索引 = 每次写订单多维护一棵树，查询零收益
```

索引的成本是每次 INSERT/UPDATE/DELETE 的维护开销 + 存储。**收益只来自查询**——没查询的索引选择性再高也是负债。删索引时这条排第一：不是"选择性低所以删"，是"没查询用它所以删"（配合上一篇 INVISIBLE 观察）。

**2. 数据分布比平均选择性重要**。

```sql
-- status 选择性 0.0000004，看着无药可救
-- 但 'PENDING' 只有 1000 行，占总行 0.01%！
SELECT status, COUNT(*) FROM orders GROUP BY status;
-- PAID: 9,980,000  CANCELLED: 19,000  PENDING: 1,000  REFUND: 0
```

查 `WHERE status = 'PENDING'` 时，索引一跳定位 1000 行，快得飞起；查 `WHERE status = 'PAID'` 时扫 99.8% 的表，索引不如没有。**优化器的世界里，"平均选择性"不如"这个具体值的选择性"**。MySQL 8 的直方图（下面讲）就是为了修正这种分布不均的盲区。

**3. 前导列基数和联合索引的匹配**。

上一篇讲过：联合索引的列序由查询模式定，不是基数定。但基数在另一个维度发挥作用——**判断某列是否该成为联合索引的前导**。user_id 出现在所有查询里、status 只在一半查询里，即便 user_id 基数 500 万、status 基数 4，前导也是 user_id。基数高只是加分项，查询覆盖是前提。

## 统计信息：优化器眼中的"选择性"

你算的选择性是理论值，优化器用的是**采样统计信息**。InnoDB 的统计信息怎么来、怎么过期，决定了优化器的判断质量：

```sql
-- 查看索引的统计信息
SHOW INDEX FROM orders;

-- Cardinality 列：优化器认为的不同值数（采样估算）
```

关键机制：

**1. 采样估算**。InnoDB 随机采样若干页（默认 `innodb_stats_persistent_sample_pages = 20`），估算基数。大表上 20 页的样本对倾斜分布（如手机号前 7 位集中）可能估偏。

**2. 自动更新阈值**。表变更超过 10% 行自动触发统计重算（`innodb_stats_auto_recalc`）。但批量导入（LOAD DATA）可能不触发——**导完大表必须手动 ANALYZE**，否则优化器拿着旧统计做计划。

```sql
ANALYZE TABLE orders;                          -- 重算统计
ANALYZE TABLE orders UPDATE HISTOGRAM ON status; -- 为 status 建直方图（8.0+）
```

**3. 持久化 vs 非持久化**。默认统计信息持久化到 `mysql.innodb_table_stats` 和 `mysql.innodb_index_stats` 两张表，重启不丢。非持久化模式（内存表）重启后重新采样——别在生产关持久化。

**4. 直方图修正分布盲区**。普通统计只记"不同值数"，直方图记"每个值的行数分布"：

```sql
ANALYZE TABLE orders UPDATE HISTOGRAM ON status USING DATA 'status';
SELECT * FROM information_schema.column_statistics WHERE table_name = 'orders'\G
```

上面 PENDING 1000 行的例子，直方图让优化器知道"查 PENDING 很便宜、查 PAID 很贵"，选择正确的连接或扫描顺序。**分布倾斜的等值列，直方图是统计信息的必需品**。

## 用选择性做索引决策：三个实战场景

**场景一：新索引立项评审**。

```sql
-- 准备给 notes(content) 加前缀索引
SELECT COUNT(DISTINCT LEFT(content, 20)) / COUNT(*) FROM notes;
-- 0.001 → 前 20 字符几乎没区分度，前缀长度加到 50 再测
-- 测到 0.05 才考虑建，且只服务特殊查询
```

**场景二：怀疑优化器没用索引**。

```sql
SHOW INDEX FROM orders;   -- Cardinality 准吗？
ANALYZE TABLE orders;     -- 先刷新统计
EXPLAIN SELECT ...;       -- 再看计划
-- 从全表扫变成 range scan = 统计过期导致的误判
```

顺序不能反：没刷新统计就下结论"优化器真蠢"，多半是自己蠢。**EXPLAIN 异常的第一诊断动作永远是 ANALYZE TABLE**。

**场景三：定期清理低价值索引**。

```sql
-- INFORMATION_SCHEMA 看索引使用情况（Performance Schema 更准）
SELECT * FROM sys.schema_unused_indexes;   -- sys 库的视图，直接看没用上的索引
```

`performance_schema.table_io_waits_summary_by_index_usage` 里 COUNT_STAR 为 0 的索引 = 观察期内从未被优化器选中。**"从未选中" + INVISIBLE 观察期无回归 = 删除候选**。但注意 sys.schema_unused_indexes 只反映"优化器没用"，不反映"约束/外键在用"——主键、唯一约束普适度别删。

## 选择性的盲区清单

1. **NULL 的坑**。`COUNT(DISTINCT col)` 不计 NULL。列允许 NULL 且 NULL 占比高时，"不同值数"低估了实际数据形态，NULL 值在索引里的分布另算。
2. **函数表达式没有统计**。`JSON_EXTRACT`、`CONCAT` 的结果，优化器按默认猜测估行数（除非函数索引自带统计）。函数查询的行数预估不可靠，是执行计划翻车高发区。
3. **前缀索引和表达式索引**。它们的选择性不能从 `SHOW INDEX` 的 Cardinality 直接读，要单独 `COUNT(DISTINCT expr)` 测。
4. **关联列统计（8.0 之前的缺口）**。MySQL 8.0 之前没有"联合选择性"概念——`WHERE a=1 AND b=2` 的组合行数靠两个独立基数猜，估不准。8.0 的直方图也只解决单列，联合分布仍是盲区。**这就是为什么有时两个列各 5% 选择性，合起来查却是全表——优化器估不出组合的真实行数**。

## 小结

选择性 = 基数 / 总行数，是索引价值的量化标尺——接近 1 必建，接近 0 慎建。但它是必要不充分条件：查询频率是前提、具体值的分布比平均值重要、统计信息的新鲜度决定优化器判断。建索引前测选择性、优化器异常先 ANALYZE、删除前用 sys.schema_unused_indexes + INVISIBLE 观察双保险。把这套流程固化，索引设计就从"玄学加索引"变成"用数据说话"。
