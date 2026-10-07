# MySQL 事务隔离级别讲透：MVCC、幻读与四个级别怎么选

> 事务隔离级别是 MySQL 面试的必考点，也是实际开发中
> "数据莫名其妙对不上"的根源之一。
>
> 本篇不背定义，从**三个并发问题**出发，推导出为什么需要四个级别，
> 再把 RC 和 RR 的实现差异（MVCC 的 ReadView 时机）讲透。

## 一、事务的四个特性，隔离性是其中最复杂的

ACID 里，原子性靠 undo log、持久性靠 redo log、一致性是前三者共同的结果。
**隔离性（Isolation）**最复杂，因为它要在"正确"和"性能"之间做权衡——
隔离得越严，并发度越低。

SQL 标准定义了四种隔离级别，MySQL InnoDB 全部支持：

| 级别 | 脏读 | 不可重复读 | 幻读 |
|---|---|---|---|
| READ UNCOMMITTED（读未提交） | ❌ 可能 | ❌ 可能 | ❌ 可能 |
| READ COMMITTED（读已提交） | ✅ 避免 | ❌ 可能 | ❌ 可能 |
| REPEATABLE READ（可重复读） | ✅ 避免 | ✅ 避免 | ✅ InnoDB 下避免 |
| SERIALIZABLE（串行化） | ✅ 避免 | ✅ 避免 | ✅ 避免 |

**MySQL 默认是 REPEATABLE READ**，这和 Oracle、PostgreSQL 默认 RC 不同，
是个经常被拿来对比的点。

## 二、先搞清楚三个问题是什么

### 2.1 脏读：读到了别人没提交的数据

```sql
-- 时刻 T1，事务 A
UPDATE account SET balance = 900 WHERE id = 1;   -- 原 1000，未提交

-- 时刻 T2，事务 B
SELECT balance FROM account WHERE id = 1;   -- 读到 900

-- 时刻 T3，事务 A 回滚
ROLLBACK;   -- balance 恢复成 1000
```

事务 B 读到的 900 **从未真实存在过**（因为 A 回滚了）。
如果 B 基于 900 做了业务判断，就全错了。

**READ COMMITTED 及以上解决**：只能读到已提交的数据。

### 2.2 不可重复读：同一事务内两次读不一样

```sql
-- 事务 B
BEGIN;
SELECT balance FROM account WHERE id = 1;   -- 读到 1000

-- 此时事务 A 提交了 UPDATE，balance 变成 900

SELECT balance FROM account WHERE id = 1;   -- 读到 900  ← 同一事务内，变了！
COMMIT;
```

重点在于：**事务 B 自己没改任何东西，但两次读的结果不同**。
这会让"先读后写"的逻辑出问题。

**REPEATABLE READ 及以上解决**：事务内多次读同一行，结果一致。

### 2.3 幻读：多了或少了行

```sql
-- 事务 B
BEGIN;
SELECT COUNT(*) FROM orders WHERE status = 'unpaid';   -- 10 条

-- 事务 A 插入了一条新订单并提交

SELECT COUNT(*) FROM orders WHERE status = 'unpaid';   -- 11 条  ← 多了一行
COMMIT;
```

注意和不可重复读的区别：
- **不可重复读**针对**已存在的行**被修改/删除（行内容变了）
- **幻读**针对**新插入的行**（行数变了）

**标准里 SERIALIZABLE 才解决幻读**，
但 **InnoDB 在 REPEATABLE READ 下就用间隙锁解决了幻读**——
这是 MySQL 和标准不一致的地方，也是面试爱追问的点。

## 三、MVCC：隔离级别的实现基础

MVCC（Multi-Version Concurrency Control，多版本并发控制）的核心思想：
**一行数据在 undo log 里保存多个历史版本，读操作读它该读的那个版本**。

好处非常直接：**读不加锁，读写不冲突**。
写事务改数据时，读事务照常读它的历史版本，互不阻塞。
这是 InnoDB 并发能力强的关键。

### 3.1 隐藏字段

InnoDB 每行数据有三个隐藏字段：

| 字段 | 含义 |
|---|---|
| `DB_TRX_ID` | 最后一次修改这行的事务 ID |
| `DB_ROLL_PTR` | 回滚指针，指向 undo log 里的上一个版本 |
| `DB_ROW_ID` | 隐含自增行 ID（没主键时才有） |

通过 `DB_ROLL_PTR` 把多个版本串成一条**版本链**：

```
当前行 (trx_id=200, balance=900)
    │ roll_ptr
    ▼
历史版本 (trx_id=150, balance=1000)
    │ roll_ptr
    ▼
历史版本 (trx_id=100, balance=800)
```

### 3.2 ReadView：判断"我能看哪个版本"

ReadView 是快照读时生成的一个"可见性规则集合"，包含：

- `m_ids`：当前活跃（未提交）的事务 ID 列表
- `min_trx_id`：活跃事务里最小的 ID
- `max_trx_id`：系统即将分配的下一个事务 ID
- `creator_trx_id`：生成这个 ReadView 的事务 ID

判断某行版本是否可见的规则（简化版）：

```
1. 若 trx_id == creator_trx_id  → 可见（自己改的当然能看到）
2. 若 trx_id < min_trx_id       → 可见（这个版本在 ReadView 生成前就提交了）
3. 若 trx_id >= max_trx_id      → 不可见（这个版本是之后才产生的）
4. 若 min_trx_id <= trx_id < max_trx_id:
     若 trx_id 在 m_ids 里      → 不可见（生成 ReadView 时它还活着，未提交）
     否则                       → 可见（已提交）
5. 不可见就沿 roll_ptr 往回找上一个版本，重复判断
```

### 3.3 🔑 RC 和 RR 的唯一区别：ReadView 生成时机

这是整个隔离级别话题的题眼：

| 级别 | ReadView 生成时机 | 结果 |
|---|---|---|
| **READ COMMITTED** | **每条 SELECT 都重新生成** | 每次都能看到最新已提交的数据 → 不可重复读 |
| **REPEATABLE READ** | **事务里第一次 SELECT 时生成，之后复用** | 整个事务看到同一个快照 → 可重复读 |

用同一条时间线对比：

```sql
-- 场景：初始 balance = 1000

-- 事务 A
BEGIN;
UPDATE account SET balance = 900 WHERE id = 1;
-- 尚未提交

-- 事务 B（RR）
BEGIN;
SELECT balance FROM account WHERE id=1;   -- 1000（生成 ReadView，A 未提交所以不可见）

-- 事务 A
COMMIT;   -- balance 变成 900

-- 事务 B（RR）
SELECT balance FROM account WHERE id=1;   -- 还是 1000！因为复用了同一个 ReadView
COMMIT;
```

如果是 RC，第二次 SELECT 会**重新生成 ReadView**，
此时 A 已提交，所以读到 900。

**一句话记住**：RR 是"事务开始时拍了张照片，后面一直看这张照片"；
RC 是"每次读都重新拍一张"。

## 四、当前读 vs 快照读

这是另一个关键区分：

```sql
-- 快照读（Snapshot Read）：不加锁，走 MVCC
SELECT * FROM account WHERE id = 1;

-- 当前读（Current Read）：加锁，读最新版本
SELECT * FROM account WHERE id = 1 FOR UPDATE;      -- 加排他锁
SELECT * FROM account WHERE id = 1 LOCK IN SHARE MODE;  -- 加共享锁
UPDATE account SET balance = 800 WHERE id = 1;      -- UPDATE 本质是 current read
DELETE FROM account WHERE id = 1;
INSERT INTO account VALUES (...);
```

⚠️ **REPEATABLE READ 只对快照读生效**。
如果你在事务里用了 `FOR UPDATE` 或做了 UPDATE，
那就是当前读，会看到别的事务已提交的最新版本。

这个坑非常常见：

```sql
BEGIN;
SELECT balance FROM account WHERE id=1;        -- 快照读，1000
-- 别的事务把这行改成 900 并提交了
UPDATE account SET balance = balance - 100 WHERE id=1;   -- 当前读！基于 900 算，得 800
SELECT balance FROM account WHERE id=1;        -- 800（自己改的，可见）
COMMIT;
```

**RM 级别下做"先读后写"必须用 `FOR UPDATE` 加锁**，否则会丢失更新。
这一点下一篇讲锁时会展开。

## 五、四个级别的实际表现与选择

### 5.1 READ UNCOMMITTED

几乎没用。能读到未提交数据，会脏读。
**生产环境不要用**。

### 5.2 READ COMMITTED

- 每次读都看最新已提交数据
- **锁范围小**（没有间隙锁，或间隙锁范围小），并发度高
- 不会脏读，但会不可重复读和幻读

**适用**：对"读到最新数据"要求高、能接受同一事务内数据变化的场景。
互联网业务很多用 RC——因为它**并发更好、死锁更少**。

```sql
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

### 5.3 REPEATABLE READ（MySQL 默认）

- 事务内一致性快照
- 用 Next-Key Lock 解决幻读
- 但因为加锁范围更大，**死锁概率高于 RC**

**适用**：需要事务内多次读取保持一致的場景，比如对账、批量校验。

```sql
-- 典型用途：备份时拿到一致性快照
mysqldump --single-transaction
```

`--single-transaction` 就是靠 RR 的一致性读，
在不锁表的情况下拿到某个时间点的一致性备份。

### 5.4 SERIALIZABLE

所有读都加共享锁，读写串行。**并发度极低，基本不用**。
只在金融等对一致性要求极端、且并发极低的场景才考虑。

## 六、查看和设置

```sql
-- 查看当前会话隔离级别（MySQL 8.0+）
SELECT @@transaction_isolation;
-- 5.7 用：SELECT @@tx_isolation;

-- 查看全局
SELECT @@global.transaction_isolation;

-- 设置当前会话
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- 设置全局（需重新连接生效）
SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- 只对下一个事务生效
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
```

⚠️ 注意 MySQL 8.0 把变量名从 `tx_isolation` 改成了 `transaction_isolation`，
写脚本时要注意版本兼容。

## 七、RC 还是 RR？一个实用判断

很多团队把 MySQL 从默认 RR 改成 RC，理由是：

- **并发度更高**：RC 下没有间隙锁（或范围小），锁冲突少
- **死锁概率低**：加锁范围小，形成环路的可能就小
- **binlog 格式**：RC 只支持 ROW 格式（STATEMENT 在 RC 下不安全）；
  RR + ROW 也可以

**但改成 RC 的前提**：你的业务能接受"同一事务内两次读结果不同"。
如果代码里有"先 SELECT 判断，再 UPDATE"的逻辑，
在 RC 下**必须加 `FOR UPDATE`**，否则会有竞态。

推荐做法：

| 场景 | 建议级别 |
|---|---|
| 普通互联网业务，高并发写 | RC + 显式加锁保护关键路径 |
| 需要事务内一致性（对账、报表） | RR |
| 用 `mysqldump --single-transaction` 备份 | 必须 RR |
| 金融级强一致 | RR + 显式锁，或 SERIALIZABLE |

## 八、三个常见误区

**误区 1：RR 下就不会有幻读**
——**快照读**确实不会（因为复用 ReadView）。
但**当前读**（`FOR UPDATE`、UPDATE）会看到别的事务新插入的行，
这时候靠的是 **Next-Key Lock（间隙锁）**来防止别的事务插入。
如果你的 SQL 没走索引、退化成全表扫描加锁，锁的范围会大得离谱。

**误区 2：MVCC 能解决所有并发问题**
——MVCC 只解决**读-写**冲突。
**写-写**冲突必须靠锁，MVCC 管不了。所以 UPDATE 还是要加锁。

**误区 3：隔离级别越高越好**
——隔离级别和并发度是**此消彼长**的。
SERIALIZABLE 最安全但也最慢。选级的本质是**业务能容忍什么**。

## 九、小结

- 三个并发问题：**脏读**（读到未提交）、**不可重复读**（行内容变了）、**幻读**（行数变了）
- **MVCC = undo log 版本链 + ReadView**，实现了"读不加锁"
- 🔑 **RC 和 RR 的唯一实现差异是 ReadView 生成时机**：
  RC 每条 SELECT 重新生成，RR 事务内第一次生成后复用
- **快照读走 MVCC，当前读（FOR UPDATE / UPDATE）走锁**
- RR 下做"先读后写"必须 `FOR UPDATE`，否则丢失更新
- MySQL 默认 **RR**，但高并发写场景很多改用 **RC**（锁少、死锁少）
- 8.0 变量名是 `transaction_isolation`（5.7 是 `tx_isolation`）

下一篇讲锁与死锁——MVCC 解决了读写并发，
但写写冲突、间隙锁、死锁排查，是另一半必须掌握的知识。
