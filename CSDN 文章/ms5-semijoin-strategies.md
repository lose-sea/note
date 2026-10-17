# Semi-join 策略：MySQL 优化 IN / EXISTS 子查询的六种武器

`WHERE id IN (SELECT id FROM other WHERE status = 'x')`——这种半连接查询，写起来直观，执行起来没那么简单。MySQL 优化器对 semi-join 有一整套转换策略，选对了差出几个数量级的性能。这篇文章把这六种策略讲清：它们各自的机制、适用场景、以及怎么用 EXPLAIN 和 hint 引导优化器。

## 先分清 semi-join 和普通 JOIN

关键差异：**去重语义**。普通 join 一对多会产生重复行，semi-join 只关心"是否存在匹配"，左表每行最多输出一次。

```sql
-- semi-join：orders 每行最多出现一次
SELECT * FROM orders o WHERE o.customer_id IN (SELECT id FROM vip_customer);
-- 等价的普通 join（写法不同，语义要小心重复）
SELECT o.* FROM orders o JOIN vip_customer c ON o.customer_id = c.id;
```

MySQL 不会天真地把 IN 子查询当 join 执行再"事后去重"（有些数据库会），而是有专门的 semi-join 执行策略。8.0 里可选的策略一共五种执行方式，加上 outside-in 的反嵌套，共六种武器。

## 六种策略全景

### 1. Materialization（物化）

```
子查询结果先物化成一张临时表（带索引）
外层每行去临时表做等值查找
```

执行计划特征：

```
-> Semijoin ... 
    -> Materialize subquery
    -> Index lookup on <subqueryN> (...)
```

适用：**子查询结果集小**（物化成本低）且执行多次。临时表上自动建哈希/索引，外层查找 O(1)。这是小结果集子查询的默认优解。

### 2. FirstMatch

```
外层每行取一行匹配就停，不等子查询全跑完
```

执行计划特征：

```
-> Nested loop inner join
    -> Table scan on o
    -> Index lookup on c (customer_id=o.customer_id)  → FirstMatch
```

适用：**外层行数少、外层是驱动方**的 EXISTS 场景。比如"找出所有有已完成订单的用户"，外层 users 表小，每找到一个 order 就走人。这是"短路求值"的数据库版。

### 3. Duplicate Weedout（去重后消除）

```
先当普通 join 跑（可能产生重复）
用临时表记录已输出的左表主键，重复行被丢弃
```

执行计划特征：

```
-> Nested loop inner join
    -> ...
    -> Duplicate weedout ... (temporary table)
```

适用：**子查询结果有重复、但去重后量可控**。典型：`WHERE o.id IN (SELECT order_id FROM order_item)`，order_item 一个订单多条记录，join 会产生重复，weedout 把它们清掉。Extra 列（TRADITIONAL 格式）里能看到 `Start temporary table` / `End temporary table`。

### 4. Loose Scan（松散索引扫描）

```
利用索引的有序性，一次跳到下一个不同的值
只对 DIGEST 形式的 semi-join 生效：GROUP BY 或 DISTINCT 的 MIN/MAX
```

例如 `SELECT customer_id, MIN(created_at) FROM orders GROUP BY customer_id`——如果索引是 `(customer_id, created_at)`，优化器可以每个 customer_id 只读第一条，而不是把该用户的订单全读出来再取最小。执行计划里 Extra 出现 `Using index for group-by` 就是它。

适用窄，但一旦命中，GROUP BY 的成本从 O(N) 降到 O(不同组数)，是教科书级优化。

### 5. Semi-join Materialization + Scan

物化后不查找，把物化表和外层做一次批量扫描合并。大结果集时的变体，和策略 1 是同一家族。

### 6. 表上拉 / 反嵌套（8.0.17+）

```
IN 子查询直接被优化器"合并"（merge）成外层查询的一部分
```

子查询足够简单（无聚合、无 LIMIT）时，反嵌套成 semi-join；8.0.17 之后 derived table 也能 merge 进外层，省掉物化开销。执行计划里看不到子查询节点，直接是表访问——**这是最快的信号，但条件苛刻**。

## 优化器怎么选：决策逻辑

选择依据主要四条，都在 EXPLAIN ANALYZE 下可验证：

1. **子查询结果大小**：小 → materialization / firstmatch；大 → duplicate weedout 或 loose scan。
2. **外层行数与驱动关系**：外层小 → firstmatch（外层驱动）；外层大、子查询小 → materialization（子查询驱动）。
3. **索引可用性**：子查询表连接列有索引，firstmatch/ weedout 有优势；没索引，materialization 建临时索引更划算。
4. **重复率**：子查询结果重复多，weedout 的临时表成本要算进去。

一个核心认知：**优化器在 semi-join 上的选择空间比普通 join 大得多，选错的概率也大得多**。这也是为什么同样的 IN 写法，有人快有人慢——写法和数据分布共同决定了优化器走的哪条路。

## 用 hint 引导优化器

当优化器选错时（EXPLAIN ANALYZE 实测确认），用 hint 强制策略：

```sql
-- 强制物化策略
SELECT /*+ SEMIJOIN(@subq MATERIALIZATION) */ * FROM orders o
WHERE o.customer_id IN (SELECT id FROM customer WHERE type='vip');

-- 强制 FirstMatch
SELECT /*+ SEMIJOIN(@subq FIRSTMATCH) */ ...

-- 强制 DuplicateWeedout
SELECT /*+ SEMIJOIN(@subq DUPSWEEDOUT) */ ...

-- 禁止反嵌套，保留子查询形态
SELECT /*+ SUBQUERY(MATERIALIZATION off) */ ...
```

`@subq` 是子查询的名字，用 `EXPLAIN FORMAT=JSON` 能看到每个 query_block 的 select_id 和名字。**hint 使用纪律：每次用 hint，注释里写清楚"为什么强制"和"数据前提"**——数据分布变了，hint 就成了性能地雷。

## 重写：比 hint 更稳的控制

有些场景重写 SQL 比 hint 更稳：

**IN → EXISTS**。这两者在 MySQL 语义相同，但可能走不同策略。IN 子查询在 MySQL 里会先物化再连接，EXISTS 更倾向于 firstmatch。外层大子查询小时，改写方向明确：

```sql
-- IN 版：可能物化整个子查询
SELECT * FROM orders o WHERE o.customer_id IN (SELECT id FROM vip WHERE type='vip');
-- EXISTS 版：更可能 firstmatch（vip 有 customer_id 索引时）
SELECT * FROM orders o WHERE EXISTS (
    SELECT 1 FROM vip v WHERE v.id = o.customer_id AND v.type = 'vip'
);
```

**NOT IN 的 NULL 陷阱**（这是真坑，不只是性能）：`NOT IN` 子查询里只要有一个 NULL，整个结果集恒为空。`NOT IN (SELECT id FROM t WHERE flag=0)`，如果 t 里有 id 为 NULL 的行，SQL 返回零行——不是"排除这些"，是"全排除"。**NOT IN 改用 NOT EXISTS**，语义正确且可优化：

```sql
-- 危险
SELECT * FROM orders WHERE customer_id NOT IN (SELECT id FROM blocked);
-- 正确
SELECT * FROM orders o WHERE NOT EXISTS (
    SELECT 1 FROM blocked b WHERE b.id = o.customer_id
);
```

**大 IN 列表改写**。`IN (1,2,3,...,10000)` 手写列表，优化器可能不建索引而走全表。分批（每 500 个 UNION ALL）或塞进临时表 join，是常见工程手段。

## 一个完整案例

```sql
-- 找出上个月有退货的 VIP 用户
SELECT u.id, u.name
FROM user u
WHERE u.level = 'vip'
  AND EXISTS (SELECT 1 FROM refund r WHERE r.user_id = u.id
              AND r.created_at >= '2026-09-01');
```

初始执行计划：全表扫 user（level 无索引）→ 每个 user 对 refund 做子查询执行。refund 有 (user_id) 索引，firstmatch 每次点查。vip 用户 5000，总成本还行，但**user 全表扫 2000 万行是瓶颈**。

修复：加 `user(level)` 索引（vip 占比 0.25%，选择性足够）。驱动行 2000 万 → 5 万，总耗时从 45s → 1.8s。**semi-join 优化的一半在子查询侧，另一半永远是外层扫描**——别顾此失彼。

## 小结

semi-join 的六种策略里，materialization 治小结果集、firstmatch 治外层驱动、duplicate weedout 治重复、loose scan 治分组极值、merge/反嵌套 治简单子查询。读懂 EXPLAIN 的策略字段，用 ANALYZE 验证选择对不对，hint 和 SQL 重写作为干预手段——IN/EXISTS 这条日常写烂了的语法，里面藏着这么大的优化空间，值得每个 DBA 和后台工程师吃透。下一篇讲另一个优化器魔法： derived table 的合并与物化。
