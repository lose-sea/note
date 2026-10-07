# MySQL EXPLAIN 完全解读：执行计划里每个字段都在说什么

> EXPLAIN 是 SQL 优化的核心工具，但很多人只会看 `type` 是不是 ALL。
> 实际上执行计划里藏着十几项信息，读懂它们，
> 你就能判断"这条 SQL 到底慢在哪一步"。
>
> 本篇逐字段拆解 EXPLAIN 输出，并给出一张"看到什么该干什么"的对照表。

## 一、基本用法

```sql
EXPLAIN SELECT * FROM orders WHERE user_id = 123 AND status = 'paid';

-- MySQL 8.0.18+ 可以直接看实际执行（带真实耗时和行数）
EXPLAIN ANALYZE SELECT ...;

-- 看更详细的信息
EXPLAIN FORMAT=JSON SELECT ...;
```

输出示例：

```
+----+-------------+--------+------+---------------+------+---------+------+------+-------------+
| id | select_type | table  | type | possible_keys | key  | key_len | ref  | rows | Extra       |
+----+-------------+--------+------+---------------+------+---------+------+------+-------------+
|  1 | SIMPLE      | orders | ref  | idx_user      | idx_user | 4    | const| 12   | Using where |
+----+-------------+--------+------+---------------+------+---------+------+------+-------------+
```

## 二、type：最重要的字段

`type` 表示**访问类型**，也就是 MySQL 怎么找到数据。
从好到坏排列：

```
system > const > eq_ref > ref > range > index > ALL
```

| type | 含义 | 出现场景 |
|---|---|---|
| **system** | 表只有一行 | 系统表，罕见 |
| **const** | 主键/唯一索引等值，最多一行 | `WHERE id = 1` |
| **eq_ref** | 唯一索引，JOIN 时每行匹配一条 | `JOIN ... ON a.id = b.id` |
| **ref** | 普通索引等值，可能多行 | `WHERE name = 'Tom'` |
| **range** | 索引范围扫描 | `WHERE id > 100`、`BETWEEN`、`IN` |
| **index** | **全索引扫描**（扫整个索引树） | 覆盖索引但没 WHERE |
| **ALL** | **全表扫描** | 没索引或索引失效 |

### 判断标准

- **目标**：至少 `range`，最好 `ref` 或更好
- **可接受**：`index`（虽然扫全索引，但至少没回表）
- **必须优化**：`ALL`（全表扫描）

```sql
-- ❌ type = ALL
EXPLAIN SELECT * FROM orders WHERE amount > 100;   -- amount 没索引

-- ✅ 加索引后 type = range
ALTER TABLE orders ADD INDEX idx_amount (amount);
```

⚠️ 一个例外：**小表全表扫描可能比走索引更快**。
表只有几百行时，优化器会主动选择 ALL，因为回表成本更高。
所以别看到 ALL 就恐慌，先看 `rows`。

## 三、key 和 possible_keys

| 字段 | 含义 |
|---|---|
| `possible_keys` | 理论上**可能**用到的索引 |
| `key` | 优化器**实际**选择的索引 |
| `key_len` | 实际使用的索引长度（字节） |

**关键判断**：

- `possible_keys` 有值但 `key` 是 NULL → **索引没被用上**，需要排查
- `key` 是 NULL 且 `possible_keys` 也是 NULL → 压根没可用索引
- `key_len` 比预期短 → **联合索引只用了前面几列**

```sql
-- 联合索引 (a, b, c)
-- key_len 只反映了 a 的长度 → 说明只用了 a，没用到 b、c
```

### key_len 怎么算

常用规则（utf8mb4 字符集）：

| 类型 | 字节数 |
|---|---|
| INT | 4 |
| BIGINT | 8 |
| TINYINT | 1 |
| DATE | 3 |
| DATETIME | 5（5.6+） |
| TIMESTAMP | 4 |
| CHAR(n) | n × 4（utf8mb4） |
| VARCHAR(n) | n × 4 + 2（长度前缀） |
| 可为 NULL 的列 | +1 |

```sql
-- 索引 (user_id INT NOT NULL, status VARCHAR(20) NOT NULL)
-- 只用 user_id：key_len = 4
-- 用了两列：key_len = 4 + 20*4 + 2 = 86
```

用 `key_len` 反推用了联合索引的几列，是判断最左匹配的实用技巧。

## 四、rows：预估扫描行数

```sql
EXPLAIN SELECT * FROM orders WHERE status = 'paid';
-- rows = 850000
```

这是**优化器预估**需要扫描的行数，不是精确值。
但数量级是对的，非常有用：

**判断原则**：`rows` × 单行成本 ≈ 查询成本。
如果 `rows` 远大于最终返回的行数，说明扫描了大量无用数据。

⚠️ `rows` 是**基于统计信息估算**的，可能不准。
统计信息不准会导致优化器选错索引。更新统计信息：

```sql
ANALYZE TABLE orders;
```

`EXPLAIN ANALYZE`（8.0.18+）会给出**真实**的行数和耗时，
排查时优先用它。

## 五、Extra：藏着最多线索

`Extra` 里的信息最杂也最有价值。常见的几项：

### ✅ 好的信号

| 值 | 含义 |
|---|---|
| `Using index` | **覆盖索引**，不用回表，很好 |
| `Using index condition` | 索引条件下推（ICP），减少了回表次数 |
| `Using where` | 用 WHERE 过滤（正常，配合其他项看） |

### ⚠️ 需要关注的

| 值 | 含义 | 怎么办 |
|---|---|---|
| **`Using filesort`** | **额外排序**，没走索引顺序 | 给 ORDER BY 字段建索引 |
| **`Using temporary`** | **用了临时表**（GROUP BY / DISTINCT / 子查询） | 优化 SQL 或加索引 |
| `Using join buffer` | JOIN 没走索引，用块嵌套循环 | 给 JOIN 字段加索引 |
| `Range checked for each record` | 每行都要重新判断索引 | 通常是类型不匹配 |

### `Using filesort` 详解

这是最常见的性能杀手。名字有误导性——
**它不一定真的用文件排序，也可能在内存里排**，
本质是"无法利用索引顺序，需要额外排序"。

```sql
-- 索引 (user_id)
SELECT * FROM orders WHERE user_id = 123 ORDER BY created_at DESC;
-- Extra: Using filesort  ← created_at 没在索引里，要额外排序

-- 改成联合索引
ALTER TABLE orders ADD INDEX idx_user_time (user_id, created_at);
-- Extra: Using where     ← 索引本身有序，不用排了
```

**原理**：B+ 树索引本身是有序的。
如果索引是 `(user_id, created_at)`，
那么 `user_id=123` 的所有行在索引里已经按 `created_at` 排好序了，
直接顺着叶子节点读就行。

### `Using temporary` 详解

```sql
-- GROUP BY 的字段不在索引里 → 临时表
SELECT status, COUNT(*) FROM orders GROUP BY status;
-- Extra: Using temporary; Using filesort

-- 加索引
ALTER TABLE orders ADD INDEX idx_status (status);
-- Extra: Using index    ← 直接用索引分组
```

**⚠️ 注意：`Using filesort` 和 `Using temporary` 不一定都要消灭。**
如果结果集只有几十行，内存排序几乎不耗时。
只有当 `rows` 很大（万级以上）时才必须优化。

## 六、id 和 select_type

### id

`id` 表示执行顺序：**id 越大越先执行；id 相同则从上往下**。

```sql
EXPLAIN SELECT * FROM orders WHERE user_id IN (SELECT id FROM users WHERE vip = 1);
-- id=1: orders（外层）
-- id=2: users（子查询，先执行）
```

### select_type

| 值 | 含义 |
|---|---|
| `SIMPLE` | 简单查询，不含子查询/UNION |
| `PRIMARY` | 最外层查询 |
| `SUBQUERY` | 子查询 |
| `DERIVED` | 派生表（FROM 里的子查询），会生成临时表 |
| `UNION` | UNION 的第二个及之后的部分 |
| `DEPENDENT SUBQUERY` | **相关子查询**，外层每一行都要跑一次 → 性能杀手 |

⚠️ **`DEPENDENT SUBQUERY` 是最需要警惕的**：

```sql
-- 相关子查询：外表 10 万行，子查询就要跑 10 万次
SELECT name, (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id) AS cnt
FROM users u;

-- 改成 JOIN
SELECT u.name, COUNT(o.id) AS cnt
FROM users u LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.id, u.name;
```

## 七、ref 和 filtered

| 字段 | 含义 |
|---|---|
| `ref` | 索引列跟谁比较（`const` / 列名 / 函数） |
| `filtered` | 存储引擎返回后，WHERE 条件过滤后剩余的比例（百分比） |

```sql
-- ref = const → 用常量比较（WHERE id = 1）
-- ref = test.u.id → 跟另一张表的列比较（JOIN 条件）
-- ref = func → 用了函数，通常是隐式类型转换的信号
```

⚠️ **`ref = func` 要警惕**，它往往意味着**隐式类型转换导致索引失效**：

```sql
-- user_id 是 VARCHAR，但传了数字 → 隐式转换，索引失效
SELECT * FROM orders WHERE user_id = 123;        -- ❌

SELECT * FROM orders WHERE user_id = '123';      -- ✅
```

`filtered` 的用法：`rows × filtered%` ≈ 传给上层的行数。
**filtered 很低（比如 1%）说明过滤效果差**，
大量行被扫描后被丢弃——索引选得不对。

## 八、实战：一条慢 SQL 的完整诊断

```sql
EXPLAIN SELECT o.order_no, u.name
FROM orders o
JOIN users u ON o.user_id = u.id
WHERE o.status = 'paid'
ORDER BY o.created_at DESC
LIMIT 20;
```

假设输出：

```
orders: type=ALL, rows=500000, Extra=Using where; Using filesort
users:  type=eq_ref, key=PRIMARY
```

诊断：

1. **`orders` 是 ALL** → 全表扫描 50 万行，主因
2. **`Using filesort`** → 排序没走索引
3. `users` 是 `eq_ref` → JOIN 走主键，没问题

优化：

```sql
ALTER TABLE orders ADD INDEX idx_status_created (status, created_at);
```

再 EXPLAIN：

```
orders: type=ref, key=idx_status_created, rows=12000, Extra=Using where
```

`type` 从 ALL → ref，`rows` 从 50 万 → 1.2 万，
`Using filesort` 消失了（因为索引里 created_at 已有序）。

⚠️ 但注意：**如果 `status='paid'` 的数据占了表的一半，
优化器可能仍然选择全表扫描**，因为回表成本太高。
这时候要重新设计索引或改写 SQL。

## 九、"看到什么该怎么办"对照表

| 你看到 | 说明 | 行动 |
|---|---|---|
| `type=ALL` + `rows` 很大 | 全表扫描 | 加索引 / 检查索引是否失效 |
| `key=NULL` 但 `possible_keys` 有值 | 优化器放弃了索引 | 可能数据倾斜，考虑 `FORCE INDEX` 或改 SQL |
| `rows` 远大于返回行数 | 扫描了太多无用行 | 优化索引，提高选择性 |
| `Using filesort` + `rows` 大 | 额外排序 | 给 ORDER BY 建联合索引 |
| `Using temporary` + `rows` 大 | 临时表 | 优化 GROUP BY，加索引 |
| `DEPENDENT SUBQUERY` | 相关子查询 | 改写成 JOIN |
| `ref=func` | 可能隐式类型转换 | 检查字段类型与传入值类型是否一致 |
| `filtered` 极低 | 过滤效果差 | 换更合适的索引 |
| `key_len` 小于预期 | 联合索引没用全 | 检查最左匹配 |

## 十、三个常见误区

**误区 1：`type=ALL` 一定有问题**
——小表（几百行）全表扫描比走索引快，优化器是对的。
看 `rows` 再判断。

**误区 2：加了索引 EXPLAIN 就一定会用**
——不一定。如果索引选择性差
（比如 `status` 只有两个值且分布均匀），
优化器会算成本后放弃。**索引不是越多越好**。

**误区 3：EXPLAIN 的 rows 是精确的**
——它是**估算值**，基于统计信息。
统计信息过期会严重影响估算准确性，
定期 `ANALYZE TABLE` 或开 `innodb_stats_persistent`。

## 十一、小结

- **`type`** 最重要：目标是 `ref` 以上，`ALL` 必须优化（大表）
- **`key`** 看实际用的索引，**`key_len`** 反推联合索引用了几列
- **`rows`** 看扫描量，跟返回行数对比判断索引效率
- **`Extra` 里的 `Using filesort` / `Using temporary`** 是两大性能杀手，
  但只在 `rows` 大时才必须处理
- **`Using index`** 是好事：覆盖索引，不回表
- **`DEPENDENT SUBQUERY`** 要改写成 JOIN
- **`ref=func`** 警惕隐式类型转换
- 索引用不上不一定是你错了，**优化器会算成本**，
  选择性差的索引它不用是对的
- 8.0.18+ 用 **`EXPLAIN ANALYZE`** 能看到真实耗时和行数

下一篇讲主从复制——索引解决单机性能，
主从解决的是读扩展和高可用，那是架构层面的事。
