# MySQL 锁与死锁讲透：行锁、间隙锁、Next-Key Lock 与排查方法

> "线上突然报 Deadlock found when trying to get lock"，
> 然后日志里一段看不懂的 LATEST DETECTED DEADLOCK。
>
> 本篇讲清楚 InnoDB 有哪些锁、什么情况下加什么锁、
> 死锁怎么产生、以及**拿到死锁日志后该怎么读**。

## 一、锁的分类

按**粒度**分：

| 粒度 | 说明 | 开销 | 冲突概率 |
|---|---|---|---|
| 表级锁 | 锁整张表 | 小 | 高 |
| 行级锁 | 锁单行或范围 | 大 | 低 |
| 页级锁 | 折中（BDB 引擎用，基本见不到） | 中 | 中 |

**InnoDB 支持行级锁**，这是它取代 MyISAM 的核心原因。
但要注意：**行锁是加在索引上的**，
如果 SQL 没走索引，会退化成锁全表的所有行（甚至表锁）。

按**模式**分：

```sql
-- 共享锁（S 锁）：读锁，多个事务可同时持有
SELECT * FROM t WHERE id = 1 LOCK IN SHARE MODE;

-- 排他锁（X 锁）：写锁，独占
SELECT * FROM t WHERE id = 1 FOR UPDATE;
UPDATE t SET ... WHERE id = 1;    -- 自动加 X 锁
DELETE FROM t WHERE id = 1;       -- 自动加 X 锁
```

兼容性矩阵：

| 已持有 \ 请求 | S | X |
|---|---|---|
| **S** | ✅ 兼容 | ❌ 冲突 |
| **X** | ❌ 冲突 | ❌ 冲突 |

## 二、行锁的三种类型

这才是 InnoDB 锁的精髓所在。

### 2.1 Record Lock（记录锁）

锁住**一条具体的索引记录**。

```sql
SELECT * FROM t WHERE id = 10 FOR UPDATE;   -- id 是主键，锁 id=10 这一行
```

### 2.2 Gap Lock（间隙锁）

锁住**两条记录之间的间隙**，防止别的事务往这个间隙里插入数据。

假设表里有 id = 1, 5, 10 三条记录，那么间隙有：
`(-∞, 1)`、`(1, 5)`、`(5, 10)`、`(10, +∞)`

```sql
SELECT * FROM t WHERE id BETWEEN 5 AND 10 FOR UPDATE;
-- 会锁住 (1,5]、(5,10]、(10,+∞) 这些范围
```

**间隙锁的唯一目的是防止幻读**——阻止别的事务在范围内插入新行。

⚠️ 两个关键特性：
1. **间隙锁之间不冲突**：两个事务可以同时对同一个间隙加间隙锁
   （因为它们都是为了防止插入，目标一致）
2. **间隙锁只在 RR 及以上级别存在**。
   **RC 级别下没有间隙锁**（这是 RC 并发更高的主因）

### 2.3 Next-Key Lock（临键锁）

**Record Lock + Gap Lock 的组合**，锁住"左开右闭"的区间 `(prev, current]`。

**这是 InnoDB 在 RR 级别下的默认加锁单位。**

```sql
-- 表里有 id = 1, 5, 10
SELECT * FROM t WHERE id = 5 FOR UPDATE;
-- 加的是 Next-Key Lock，锁定范围 (1, 5]
```

注意：**等值查询命中唯一索引时，Next-Key Lock 会退化成 Record Lock**。
这是 InnoDB 的优化——既然 id 是唯一的，
锁住 5 这一行就够了，不需要间隙。

```sql
-- id 是主键（唯一索引）
SELECT * FROM t WHERE id = 5 FOR UPDATE;   -- 只锁 id=5 这一行（退化）

-- age 是普通索引，可能重复
SELECT * FROM t WHERE age = 20 FOR UPDATE;
-- 不退化！锁住所有 age=20 的行 + 前后的间隙
```

## 三、不同 SQL 加什么锁

这是最实用的部分，建议对着看：

| SQL | 索引情况 | 加锁 |
|---|---|---|
| `SELECT ... FROM` | — | **不加锁**（快照读，走 MVCC） |
| `SELECT ... LOCK IN SHARE MODE` | 唯一索引等值 | S 型 Record Lock |
| `SELECT ... FOR UPDATE` | 唯一索引等值 | X 型 Record Lock |
| `SELECT ... FOR UPDATE` | 唯一索引范围 | X 型 Next-Key Lock（扫到的范围） |
| `SELECT ... FOR UPDATE` | **普通索引**等值 | X 型 Next-Key Lock（**不退化**） |
| `SELECT ... FOR UPDATE` | **无索引** | **锁全表所有行 + 所有间隙** |
| `UPDATE / DELETE` | 同上逻辑 | 同 FOR UPDATE |

最后一行是**最危险的情况**：

```sql
-- name 字段没有索引
UPDATE user SET status = 1 WHERE name = 'Tom';
-- 全表扫描，锁住所有记录和所有间隙 → 整张表实际上不可写
```

**生产事故高发点**：一条不走索引的 UPDATE，把整张表锁死。
所以 `UPDATE/DELETE` 的 WHERE 条件**必须有索引**，这是硬性纪律。

### 验证加锁范围

```sql
-- MySQL 8.0+ 可以用 performance_schema 查看
SELECT * FROM performance_schema.data_locks;

-- 5.7 用
SHOW ENGINE INNODB STATUS\G
```

## 四、死锁是怎么产生的

死锁的四个必要条件：互斥、占有且等待、不可抢占、**循环等待**。
InnoDB 无法破坏前三个（锁的本质），所以只能**检测循环等待并回滚**。

### 4.1 最经典的场景：加锁顺序不同

```sql
-- 事务 A
BEGIN;
UPDATE account SET balance = balance - 100 WHERE id = 1;   -- 锁 id=1
UPDATE account SET balance = balance + 100 WHERE id = 2;   -- 等 id=2

-- 事务 B（同时）
BEGIN;
UPDATE account SET balance = balance - 50 WHERE id = 2;    -- 锁 id=2
UPDATE account SET balance = balance + 50 WHERE id = 1;    -- 等 id=1
```

时间线：

```
T1  A 锁住 id=1
T2  B 锁住 id=2
T3  A 请求 id=2 → 等待
T4  B 请求 id=1 → 等待
T5  InnoDB 检测到环路 → 回滚其中一个，报 Deadlock
```

**解决方案：统一加锁顺序**。比如永远按 id 升序处理：

```python
ids = sorted([1, 2])    # 排序！
for i in ids:
    cursor.execute("UPDATE account SET ... WHERE id = %s", (i,))
```

这一行 `sorted()` 能消除绝大多数死锁。

### 4.2 间隙锁导致的死锁

这个更隐蔽。RR 级别下，两个事务对同一间隙加间隙锁不冲突，
但**后续的插入操作会冲突**：

```sql
-- 表里有 id = 5
-- 事务 A
BEGIN;
SELECT * FROM t WHERE id = 5 FOR UPDATE;   -- 加 Next-Key Lock，锁 (?, 5]

-- 事务 B
BEGIN;
SELECT * FROM t WHERE id = 5 FOR UPDATE;   -- 间隙锁不冲突，也成功

-- 事务 A
INSERT INTO t (id) VALUES (4);   -- 等待 B 释放间隙锁

-- 事务 B
INSERT INTO t (id) VALUES (4);   -- 等待 A 释放 → 死锁！
```

这种死锁在 RC 级别下不会发生（没有间隙锁）。
**这也是很多团队改用 RC 的原因之一。**

### 4.3 唯一键冲突导致的死锁

并发插入相同的唯一键时，一个成功一个失败，
失败的会加 S 锁等待，如果此时有其他事务持有锁，可能形成环路。

## 五、死锁日志怎么读

死锁发生后：

```sql
SHOW ENGINE INNODB STATUS\G
```

找到 `LATEST DETECTED DEADLOCK` 段落：

```
------------------------
LATEST DETECTED DEADLOCK
------------------------
2026-10-07 06:20:11 0x7f8b
*** (1) TRANSACTION:
TRANSACTION 421568, ACTIVE 2 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 3 lock struct(s), heap size 1136, 2 row lock(s)
MySQL thread id 15, OS thread handle ..., query id 88 localhost root updating
UPDATE account SET balance = balance - 100 WHERE id = 1

*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 58 page no 3 n bits 80 index PRIMARY of table `test`.`account`
trx id 421568 lock_mode X locks rec but not gap waiting

*** (2) TRANSACTION:
TRANSACTION 421569, ACTIVE 1 sec starting index read
UPDATE account SET balance = balance + 50 WHERE id = 2

*** (2) HOLDS THE LOCK(S):
RECORD LOCKS ... index PRIMARY ...
trx id 421569 lock_mode X locks rec but not gap

*** WE ROLL BACK TRANSACTION (2)
```

**读日志的关键四点**：

1. **`(1) TRANSACTION` 和 `(2) TRANSACTION`** —— 两个互相等待的事务，
   各自下面有它正在执行的 SQL
2. **`lock_mode X locks rec but not gap`** —— 锁类型。
   - `X` = 排他锁
   - `locks rec but not gap` = Record Lock（**没有间隙锁**）
   - `locks gap before rec` = 间隙锁
   - `next-key` / 无后缀 = Next-Key Lock
3. **`index PRIMARY`** —— 锁在哪个索引上。
   如果显示的是二级索引，说明还回表锁了主键
4. **`WE ROLL BACK TRANSACTION (2)`** —— 谁被回滚了。
   InnoDB 选择回滚**影响行数更少**的那个（权重小的）

⚠️ 一个坑：`SHOW ENGINE INNODB STATUS` 只保留**最近一次**死锁。
要看历史得开参数：

```sql
-- MySQL 5.6+ 可以把死锁日志写进 error log
SET GLOBAL innodb_print_all_deadlocks = ON;
```

生产环境建议**常开**，否则死锁信息会被覆盖掉。

## 六、锁等待与超时

```sql
-- 查看锁等待超时时间（默认 50 秒）
SHOW VARIABLES LIKE 'innodb_lock_wait_timeout';

-- 查看当前等待锁的事务（MySQL 8.0+）
SELECT * FROM performance_schema.data_lock_waits;

-- 5.7 查锁等待
SELECT * FROM information_schema.innodb_lock_waits;
SELECT * FROM information_schema.innodb_locks;   -- 已加锁的

-- 查看活跃事务
SELECT * FROM information_schema.innodb_trx;
```

找阻塞源的经典 SQL（8.0+）：

```sql
SELECT
    waiting_pid AS 被阻塞的线程,
    waiting_query AS 被阻塞的SQL,
    blocking_pid AS 阻塞者线程,
    blocking_query AS 阻塞者的SQL,
    wait_age AS 已等待时长
FROM sys.innodb_lock_waits;
```

`sys` 库是 MySQL 5.7+ 自带的诊断视图集合，
`innodb_lock_waits` 把上面几张表 join 好了，直接用就行。

**处理**：确认后 `KILL <blocking_pid>` 杀掉阻塞源。

## 七、减少死锁的六条实践

**1. 统一加锁顺序**（最重要）
批量更新前排序，永远按同一顺序访问资源。

**2. 缩小事务范围**

```python
# ❌ 事务里夹着 RPC 调用
with transaction():
    db.update(...)
    requests.post("https://外部服务")    # 可能耗时几秒，锁一直占着
    db.update(...)

# ✅ 事务里只做数据库操作
with transaction():
    db.update(...)
    db.update(...)
requests.post(...)    # 放到事务外
```

事务越长，锁持有越久，冲突概率指数上升。

**3. 降低隔离级别**
RR → RC 可以消除大部分间隙锁死锁。

**4. 避免无索引的 UPDATE/DELETE**
WHERE 条件必须有索引，否则锁全表。

**5. 用 `SELECT ... FOR UPDATE` 显式预加锁**

```sql
BEGIN;
SELECT * FROM t WHERE id = 1 FOR UPDATE;    -- 一开始就锁住
-- 业务逻辑
UPDATE t SET ... WHERE id = 1;
COMMIT;
```

先读后写的场景，在事务开始就加锁，避免中途升级锁造成环路。

**6. 重试机制**
死锁无法完全避免，**应用层必须有重试**：

```python
from functools import wraps
import pymysql, time, random

def retry_on_deadlock(times=3):
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            for i in range(times):
                try:
                    return fn(*a, **kw)
                except pymysql.err.OperationalError as e:
                    if e.args[0] == 1213:      # 1213 = deadlock
                        time.sleep(0.1 * (2 ** i) + random.random() * 0.1)
                        continue
                    raise
            raise
        return wrapper
    return deco
```

加了随机抖动，避免多个请求同时重试再次撞车。

## 八、死锁 vs 锁等待超时

| | 死锁 | 锁等待超时 |
|---|---|---|
| 原因 | 循环等待 | 长时间拿不到锁 |
| 检测 | InnoDB 主动检测（**立即**回滚） | 等 `innodb_lock_wait_timeout` 秒 |
| 错误码 | 1213 | 1205 |
| 处理 | 重试即可 | 要排查为什么持有这么久 |

死锁其实"好处理"——InnoDB 会立刻发现并回滚一个，
应用层重试就行。**锁等待超时更麻烦**，它说明有长事务，
需要查 `innodb_trx` 找出是谁。

## 九、小结

- InnoDB 行锁分三种：**Record Lock**（行）、**Gap Lock**（间隙）、
  **Next-Key Lock**（前两者组合，RR 下默认）
- **等值查询 + 唯一索引 → 退化成 Record Lock**；普通索引不退化
- **间隙锁只在 RR 存在**，RC 没有 → RC 并发更高、死锁更少
- **WHERE 没索引 = 锁全表**，这是最危险的情况
- 死锁主因是**加锁顺序不同** → 批量操作前 `sorted()`
- 读死锁日志看四点：两个事务的 SQL、锁类型、锁在哪个索引、谁被回滚
- **生产建议开 `innodb_print_all_deadlocks`**，否则日志会被覆盖
- 查阻塞用 `sys.innodb_lock_waits`
- **应用层必须做死锁重试**（错误码 1213），加随机抖动

下一篇讲慢查询排查——锁解决"数据正确性"，
慢查询解决"为什么这么慢"，两者经常一起出现：
一条慢 SQL 持有锁太久，就会引发大面积锁等待。
