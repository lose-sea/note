# 分区裁剪：让查询只扫它该扫的那几个分区

日志表三年 20 亿行，直接索引查也吃力——InnoDB 的 B+ 树太高、缓冲池放不下热数据、备份恢复按小时计。分区表（Partitioning）是这类大表的经典答案：**把一张大表物理切成多个分区，查询时只碰相关分区**。但裁减收益不是自动的——分区键选错、WHERE 写错，分区表就是个慢速版普通表。这篇文章讲分区裁剪的机制、生效条件和实战设计。

## 分区裁剪（Partition Pruning）机制

```sql
CREATE TABLE access_log (
    id BIGINT AUTO_INCREMENT,
    user_id BIGINT,
    created_at DATETIME NOT NULL,
    endpoint VARCHAR(200),
    PRIMARY KEY (id, created_at)          -- 分区键必须进主键/唯一键
)
PARTITION BY RANGE (YEAR(created_at)) (
    PARTITION p2023 VALUES LESS THAN (2024),
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION pmax  VALUES LESS THAN MAXVALUE   -- 兜底分区
);
```

物理上，这是四个独立的"子表"，数据按 `YEAR(created_at)` 落进对应分区。查询时：

```sql
SELECT * FROM access_log WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01';
```

执行计划里能看到：

```
-> Partition: p2025   ← 只碰这一个分区
-> Index range scan on access_log using idx_created (created_at between ...)
```

这就是**分区裁剪**：优化器分析 WHERE 条件，算出只涉及 p2025，其他分区物理上根本不打开。20 亿行的表，"只扫一个分区" = 扫 7 亿行变扫 7 亿行的几分之一。

判断裁剪有没有发生，EXPLAIN 输出的 `partitions` 列（TRADITIONAL 格式）会列出实际使用的分区——只出现 `p2025` 而不是 `p2023,p2024,p2025,pmax` 就是生效了。

## 裁剪生效的四个条件

分区键是 `YEAR(created_at)`，但下面这些查询**裁不动**：

**1. WHERE 里写了分区键的表达式**。

```sql
-- 能裁：分区键直接匹配
WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01'
-- 不能裁：对分区键套函数
WHERE YEAR(created_at) = 2025
```

等等，分区键本身就是 `YEAR(created_at)`，第二条写法不是更"直接"吗？**错**。分区边界是按 `YEAR(created_at)` 的**值**划分的（2023/2024/2025 三界），但 WHERE `YEAR(created_at) = 2025` 是个作用于每行的函数调用——优化器要把"函数结果等于边界值"反推成"函数输入在哪个区间"，这种反推一般做不了，于是全分区扫。

第二条写法的正确裁减法：

```sql
WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01'
-- 等价于 YEAR(created_at)=2025，但优化器认得范围
```

**用分区键建分区时，WHERE 永远写基列的范围条件，不写分区表达式**。这是分区表第一纪律。

**2. IN 列表可以裁**。

```sql
WHERE created_at IN ('2025-06-01 10:00:00', '2025-08-15 08:30:00')
-- 裁到对应分区，多个值在多个分区就扫多个
```

**3. 分区键不在 WHERE 里，完全裁不动**。

```sql
-- 分区键是 YEAR(created_at)，查询按 user_id 过滤
SELECT * FROM access_log WHERE user_id = 12345;
-- 所有分区全扫——分区白建
```

**分区键必须出现在高频查询的 WHERE 里**。按时间范围查日志是刚需，所以 RANGE 时间分区是日志表标配；如果查询一半按 user_id，分区键就该考虑别的方案（甚至分区键=user_id 的 HASH 分区）。

**4. 分区键必须是主键/唯一键的一部分**。

```sql
-- 错误：分区键不在主键里，直接报错
PARTITION BY RANGE (created_at) ... PRIMARY KEY (id)
-- InnoDB 要求：分区键的每一列都必须包含在主键或唯一索引里
```

原因是分区表每个分区是独立 B+ 树，主键唯一性要全局成立，分区键进主键才能让"分区号 + 主键"确定唯一。这是分区表设计的硬约束，建表时就定死，**后期改分区键 = 重建表**。

## 分区类型选型

四种分区类型，对应四种裁减法：

| 类型 | 语法 | 裁剪条件 | 典型场景 |
|---|---|---|---|
| RANGE | `VALUES LESS THAN` | 范围查询按边界裁 | 时间日志、订单流水 |
| LIST | `VALUES IN (列表)` | 等值/IN 裁 | 地域、状态枚举 |
| HASH | `PARTITION BY HASH(expr)` | **几乎不裁**（等值 expr 才可能） | 均匀打散、并行 IO |
| KEY | `PARTITION BY KEY(expr)` | 同上，MySQL 内部哈希 | 和 HASH 类似 |

HASH/KEY 分区的价值不在裁剪单条查询，而在**并行度和数据均匀**： range scan 每个分区可以并行扫。它们服务的是"数据打散 + 并发"需求，查询侧不要指望裁剪。

**组合分区**（RANGE 再 HASH 子分区）适合超大规模：先按年分大区、区内再 hash 打散。复杂度上去一层，只在十亿级以上考虑。

## 实战设计：日志表分区方案

需求：6 亿行访问日志，查询模式 90% 是"最近 N 天的记录"，按 user_id 和 endpoint 二级过滤。

```sql
CREATE TABLE access_log (
    id BIGINT AUTO_INCREMENT,
    user_id BIGINT NOT NULL,
    created_at DATETIME NOT NULL,
    endpoint VARCHAR(200),
    PRIMARY KEY (id, created_at),
    KEY idx_user_time (user_id, created_at),
    KEY idx_ep_time (endpoint, created_at)
)
PARTITION BY RANGE COLUMNS(created_at) (
    PARTITION p202501 VALUES LESS THAN ('2025-02-01'),
    PARTITION p202502 VALUES LESS THAN ('2025-03-01'),
    ...
    PARTITION p202612 VALUES LESS THAN ('2027-01-01'),
    PARTITION pmax VALUES LESS THAN (MAXVALUE)
) ;
```

三个设计决策解释：

**1. 月分区粒度**。日志按天查、按天分太碎（一年 365 个分区，管理成本爆炸）；按年分太粗（单分区 1.5 亿行，裁剪收益打折）。**月分区是甜点**：查询"最近三天"裁到 1~2 个分区；DROP 旧数据按分区删，秒级释放空间。

**2. `RANGE COLUMNS` 而不是 `RANGE (YEAR())`**。用日期列直接做分区键，WHERE 写的 `created_at` 范围天然匹配分区边界，不需要函数反推。分区键和 WHERE 条件形状一致，裁剪永远成立。

**3. pmax 兜底分区必须有**。忘了写 MAXVALUE 兜底，插入超出最后一个边界的数据直接报错。兜底分区定期检查 `information_schema.partitions` 里有没有意外数据——有数据说明分区边界没跟上时间，该加新区。

## 分区的代价：别只会说好话

分区不是免费的，四个成本要认：

1. **分区数上限**。单表 8192 个分区是硬上限（`MAXVALUE` 也算一个）。按月分 700 个月 = 58 年才触顶，但按天分的日志表设计 5 年就撞墙。
2. **每个分区都要索引维护**。分区数 × 索引数 = 实际索引对象数。6 个月分区 × 3 个索引 = 18 个 B+ 树在维护。写放大比普通表明显。
3. **全分区查询更慢**。本可以一次扫描搞定，分区后优化器要逐分区开、逐分区扫。`SELECT COUNT(*) FROM access_log` 无 WHERE 的统计，分区后比普通表慢 10%~30%。
4. **分区键改不了**。换分区键 = 表重建。建表时选错分区键，纠正成本是重构表加数据迁移。**分区方案是建表期决策，不是后期优化项**。

## 什么时候该分区、什么时候不该

**该分**：数据量大到索引树高（亿级以上）、有明确的时间/地域维度过滤、需要快速 DROP 历史数据、写入吞吐高需要均匀打散。

**不该分**：数据量千万以下（索引足够快）、查询没有可裁剪的维度（WHERE 五花八门）、表频繁做复杂 JOIN（分区 join 的优化器支持有限）、分区键无法提前定死（还在 schema 演进期）。

**实在想快速清理历史数据，还有一招：归档表**。定期 `INSERT INTO archive SELECT ... WHERE created_at < x` + `DELETE` 原表（按分区删更快）。分区是"内置归档能力"，归档表是"手动实现"——拆表方案的灵活性更高，看团队运维成本选。

## 小结

分区表的核心价值是分区裁剪：WHERE 匹配分区边界时，查询只扫相关分区的物理数据。生效三条件：**WHERE 写分区键的基列范围（不写函数）、分区键在高频查询里、分区键在主键/唯一键里**。月粒度 RANGE COLUMNS + MAXVALUE 兜底是日志表甜点方案。代价是分区数管理、写放大、全表统计变慢和分区键不可改。下单前想清楚查询模式，分区就是利器；模式不清晰就上分区，多半是给自己挖坑。下一篇讲分区维护：加分区、删分区和在线操作怎么做不翻车。
