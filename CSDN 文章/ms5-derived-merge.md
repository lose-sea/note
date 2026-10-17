# Derived Table 合并与物化：优化器对派生表的两种处置

`SELECT * FROM (SELECT ... FROM a WHERE ...) t JOIN b ON ...`——这种 FROM 子句里套 SELECT 的写法，中间那张"临时表"就是 **derived table（派生表）**。每次写子查询都在用，但很多人不知道：优化器对 derived table 有两种截然不同的处置——**合并进外层（merge）**和**单独物化（materialize）**，选错就是性能黑洞。这篇文章讲清两者的决策逻辑、性能差异和干预手段。

## Derived table 是什么

FROM 子句里的子查询，逻辑上产生一张中间表，外层再基于它查询：

```sql
SELECT t.month, COUNT(*)
FROM (
    SELECT DATE_FORMAT(created_at, '%Y-%m') AS month, customer_id
    FROM orders
    WHERE status = 'paid'
) t
GROUP BY t.month;
```

中间括号里那张 t 就是派生表。它在 SQL 标准里必须当作独立表处理：先算完括号里的，再算外层。**这个"必须独立"是逻辑语义**，MySQL 的两种优化都是从打破或利用这个语义出发的。

## 处置一：Merge（合并）——语义等价时的捷径

MySQL 发现"先物化再查"和"直接把子查询条件揉进外层"结果一样时，执行 **derived merge**：把子查询的 WHERE、SELECT 列、FROM 全部"上移"融进外层查询，中间表消失。

```sql
-- 原始
SELECT * FROM (SELECT id, name FROM customer WHERE level='vip') t WHERE t.age > 30;

-- merge 后等价于
SELECT id, name FROM customer WHERE level='vip' AND age > 30;
```

合并后三个直接收益：

1. **外层条件下推**。`age > 30` 下推到 customer 表。没 merge 的话，子查询先跑一遍全量 vip，外层再过滤——先算 5000 行再砍到 800，不如一开始就 `(level, age)` 联合索引一次到位。
2. **索引可见**。merge 后优化器能看到全部分布，可能选到更优索引；物化表只有临时索引（或没有）。
3. **省掉物化开销**。没有临时表创建、写入、读取的开销。

**merge 的条件（满足才能合并，缺一不可）**：

- 子查询没有聚合（SUM/COUNT/GROUP BY/DISTINCT）。
- 没有 LIMIT。
- 不是 UNION（纯 UNION ALL 有些版本可以 MERGE derived，但要看版本）。
- 子查询是"裸 SELECT"，不含存储过程、随机函数（RAND()、UUID()）这类把查询和非确定性绑定的元素。
- 外层 FROM 只有这一张派生表（join 场景另说，optimizer_switch 的 derived_merge 控制）。

总之：**越简单的派生表越容易被 merge，越简单通常也越快**。

## 处置二：Materialize（物化）——为"多次使用"买单

不能 merge 的场景，MySQL 默认 **materialize**：把子查询结果算出来，写进一张临时表（内存优先，超了落盘），外层对临时表查询。

```sql
SELECT * FROM (
    SELECT customer_id, SUM(amount) AS total
    FROM orders GROUP BY customer_id      -- 聚合 → 不可 merge
) t JOIN vip v ON t.customer_id = v.id
WHERE t.total > 10000;
```

这个子查询有 GROUP BY，不可能 merge。物化路径：

1. 执行子查询，每个用户聚合出 total。
2. 临时表写入（InnoDB 内存临时表，超 `tmp_table_size` 落盘）。
3. 外层 join：vip 驱动扫 t，或 t 驱动扫 vip，取决于优化器预估。临时表如果有等值连接列，物化时会自动建索引（哈希索引）加速 join。

物化的成本：**临时表创建 + 数据写入 + join 时的索引查找**。物化的收益：**子查询只执行一次，join 多轮复用**。所以关键问题是——**子查询会被用几次**？

## 决策逻辑：一次 vs 多次

优化器的核心判断：

| 场景 | 倾向 | 原因 |
|---|---|---|
| 派生表被 join 用一次，结果小 | merge | 省物化开销 |
| 派生表被多次引用（自 join、相关子查询场景） | materialize | 算一次复用 N 次 |
| 有 LIMIT 的派生表（相关场景） | materialize | merge 会破坏 limit 语义 |
| 无 LIMIT，但结果集巨大 | 两者都不理想 | 改写 SQL：把条件下推 |

**"派生表出现多次"是物化价值的核心场景**。比如这张聚合表既要 join 主表又要关联维度表，物化一次是划算的。但许多工程师在派生表只用一次时也懒得改写，白白付了物化的钱。

## 怎么干预：switch 和重写

### optimizer_switch 控制

```sql
-- 查看当前 derived 相关开关
SELECT @@optimizer_switch\G
-- 关键两个：
-- derived_merge=on        控制 derived table 是否可 merge
-- derived_condition_pushdown=on  控制条件下推
```

诊断时想对比"merge 前 vs merge 后"，临时关掉再 EXPLAIN：

```sql
SET SESSION optimizer_switch='derived_merge=off';
EXPLAIN SELECT ...;   -- 强制物化路径
SET SESSION optimizer_switch='derived_merge=on';
```

**生产上不要永久关**——只是诊断工具。merge 是默认开启且绝大多数时候正确的优化，你要做的是"确认它有没有发生"，而不是"关掉它"。

### 判断 merge 发生没有

TREE 格式下，merge 后的执行计划**没有 Materialize 节点**，直接是表访问：

```
-- merge 后：干净利落
-> Table scan on customer  (cost=... rows=800)
-- 物化：能看到 Materialize 层
-> Nested loop inner join
    -> Materialize subquery
        -> Aggregate: COUNT/SUM/GROUP BY
    -> Index lookup on vip ...
```

**执行计划里出现 `Materialize` 字样 = 物化路径，没有 = merge 路径**。诊断第一眼就看这个。

### 手动重写：替代物的两种武器

当优化器不 merge 而你想 merge 时，最可靠的是**手动把子查询拍平**：

```sql
-- 不 merge 的版本（有 LIMIT 挡住）
SELECT * FROM (SELECT * FROM orders ORDER BY amount DESC LIMIT 100) t WHERE t.status='paid';

-- 手动拍平（语义相同，条件可下推）
SELECT * FROM orders WHERE status='paid' ORDER BY amount DESC LIMIT 100;
```

反过来，想强制物化（避免优化器做了错判的 merge）也有招——加一个 merge 阻塞器。

```sql
-- 加 LIMIT 阻断 merge（8.0 里 LIMIT 子查询不再 merge，保险）
SELECT * FROM (SELECT ... LIMIT 18446744073709551615) t ...;
-- 或加 GROUP BY / DISTINCT 让子查询有独立语义
```

**注意反向武器要慎用**：LIMIT 骗优化器是 hack，注释里必须写清楚为什么，否则后人（包括三个月后的你）看不懂这行魔法数字。

## 一个实拍案例：物化的双刃剑

场景：订单报表，取每个客户的最后一单：

```sql
SELECT t.* FROM (
    SELECT * FROM orders WHERE created_at >= '2026-01-01'
) t
JOIN (SELECT customer_id, MAX(id) AS last_id FROM orders GROUP BY customer_id) last
  ON t.id = last.last_id;
```

诊断：外层派生表 t 没 LIMIT 没聚合，本该 merge，但执行计划显示它被物化了——因为 **t 出现在 JOIN 里且被引用两次**（下推条件 join 条件里都有），MySQL 选择物化保平安。结果：2026 年 500 万订单全物化 + MAX 子查询物化，内存临时表飙到 2GB。

修复思路不是关 derived_merge，而是**改写 SQL 让优化器有机会 merge**：

```sql
SELECT o.* FROM orders o
JOIN (SELECT customer_id, MAX(id) AS last_id FROM orders
      WHERE created_at >= '2026-01-01' GROUP BY customer_id) last
  ON o.id = last.last_id;
```

把 t 的下推条件直接放进内层 join 子查询（条件 MERGE 了），临时表只剩聚合结果。内存峰值从 2GB → 30MB，耗时 40s → 3s。

教训：**"执行计划显示物化" 只是信号，"物化了多大的东西"才是问题**。优化派生表查询的正确姿势永远是：EXPLAIN 看是否物化 → 看物化的输入行数 → 用 merge 或改写缩小输入。

## 和其他优化器的联动

derived merge 常常和这几个特性打架，值得联动理解：

- **条件下推（condition pushdown）**：merge 是它的前提——不 merge，外层条件碰不到基表。
- ** semi-join 反嵌套**：FROM 里的派生表如果本身是相关子查询，可能被转换成 semi-join 策略（见上一篇）。
- **窗口函数**：含窗口函数的派生表**不可 merge**（窗口函数要求独立计算）。用窗口函数的查询，改写时把窗口逻辑尽量放最内层，减少外层可 merge 的空间——听起来反直觉，其实是为了让外层尽可能简单。

## 小结

derived table 的两种处置：merge 是"拍平"——省物化开销、让条件下推和索引选择生效；materialize 是"缓存"——为多次复用付一次计算的钱。优化器按聚合/LIMIT/引用次数自动决策，你要做的是读 EXPLAIN 认出走了哪条路、物化输入有多大，然后用下推条件和 SQL 拍平把输入砍小。派生表写法的性能差距，常常比写 join 还是写子查询的差距大得多。下一篇收尾这一组优化话题：物化（Materialization）策略的专题。
