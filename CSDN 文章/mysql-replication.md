# MySQL 主从复制讲透：binlog 原理、搭建步骤与读写分离

> 单库扛不住读压力时，第一个想到的方案就是主从复制。
> 本篇讲清楚复制是怎么工作的（三个线程 + 两类日志）、
> binlog 的三种格式有什么区别、怎么搭建、
> 以及最让人头疼的**主从延迟**怎么排查和缓解。

## 一、复制解决什么问题

| 问题 | 主从怎么解决 |
|---|---|
| 读压力大 | 写走主库，读分散到多个从库 |
| 单点故障 | 主库挂了可以切从库 |
| 备份影响业务 | 在从库上做备份，不影响主库 |
| 分析查询拖垮线上 | 慢查询、报表跑在从库 |

⚠️ 要明确：**主从复制不解决写压力**。
所有写还是在主库，从库只是分担读。
写压力大要靠分库分表（下一篇）。

## 二、复制的三个线程

```
主库 (Master)                          从库 (Slave)
┌──────────────┐                    ┌──────────────────┐
│  binlog      │                    │  relay log       │
│  (二进制日志) │                    │  (中继日志)       │
└──────┬───────┘                    └────────┬─────────┘
       │                                     │
       │ ① 读 binlog                   ③ 回放
   ┌───▼─────────┐                    ┌──────▼──────┐
   │ dump 线程    │ ──── 传输 ────▶   │ SQL 线程     │
   │ (Binlog     │      ②            │ (回放 relay  │
   │  Dump)      │ ◀──── 请求 ────── │   log)      │
   └─────────────┘                    └─────────────┘
                                      ┌──────────────┐
                                      │ IO 线程       │
                                      │ (接收并写     │
                                      │  relay log)  │
                                      └──────────────┘
```

完整流程：

1. **主库**：事务提交时，把变更记录写进 **binlog**
2. **从库 IO 线程**：连接主库，请求 binlog；主库起一个 **dump 线程**把 binlog 推过来；
   IO 线程收到后写进本地的 **relay log（中继日志）**
3. **从库 SQL 线程**：读 relay log，把变更回放（replay）到从库

三个线程记住：
- 主库：**Binlog Dump 线程**
- 从库：**IO 线程**（拉日志）+ **SQL 线程**（回放）

## 三、binlog：复制的数据源

### 3.1 binlog 是什么

binlog 是**服务层**（不是 InnoDB 独有）的二进制日志，
记录所有**数据变更**（DDL 和 DML），不记录 SELECT。

三个作用：**复制**、**数据恢复**、**审计**。

```sql
-- 查看 binlog 是否开启
SHOW VARIABLES LIKE 'log_bin';

-- 查看当前 binlog 文件列表
SHOW BINARY LOGS;

-- 查看正在写的 binlog
SHOW MASTER STATUS;

-- 查看 binlog 内容
SHOW BINLOG EVENTS IN 'mysql-bin.000001' LIMIT 10;
```

### 3.2 三种格式（重点）

```sql
SHOW VARIABLES LIKE 'binlog_format';
```

| 格式 | 记录内容 | 优点 | 缺点 |
|---|---|---|---|
| **STATEMENT** | 记录**SQL 语句原文** | 日志小 | 某些语句不安全（如 `NOW()`、`UUID()`、触发器） |
| **ROW** | 记录**每行数据的变化** | 绝对安全 | 日志大（改 10 万行就记 10 万条） |
| **MIXED** | 混合：安全用 STATEMENT，不安全用 ROW | 折中 | 行为不完全可预测 |

**生产必须用 ROW 格式**，这是共识。原因：

```sql
-- STATEMENT 格式的经典问题
UPDATE orders SET updated_at = NOW() WHERE status = 'paid';
-- 主库执行时 NOW() 是 10:00
-- 从库回放时 NOW() 是 10:05  ← 数据不一致！
```

ROW 格式记录的是"哪一行从什么值改成什么值"，
跟执行时间无关，绝对安全。

```sql
SET GLOBAL binlog_format = 'ROW';
-- my.cnf: binlog_format = ROW
```

⚠️ **READ COMMITTED 隔离级别下 binlog 必须用 ROW**，
因为 STATEMENT 在 RC 下会有主从不一致问题。

### 3.3 ROW 格式的日志太大怎么办

MySQL 5.6+ 有个参数控制 ROW 格式记录多少内容：

```sql
SHOW VARIABLES LIKE 'binlog_row_image';
-- FULL    : 记录所有列（默认，最安全）
-- MINIMAL : 只记录变更的列 + 定位行所需的列（日志最小）
-- NOBLOB  : 不记录没变更的 BLOB/TEXT
```

`MINIMAL` 能显著减小日志，但有约束：
**表必须有主键**（否则无法唯一定位行）。

## 四、复制的三种模式

| 模式 | 说明 | 特点 |
|---|---|---|
| **异步复制**（默认） | 主库写完 binlog 就返回，不等从库 | 性能好，**可能丢数据** |
| **半同步复制** | 主库等**至少一个**从库收到才返回 | 折中，减少丢失风险 |
| **组复制**（Group Replication） | 基于 Paxos，强一致 | 复杂，MySQL InnoDB Cluster 用 |

生产常用**半同步**：

```sql
-- 主库和从库都装插件
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';

-- 开启
SET GLOBAL rpl_semi_sync_master_enabled = 1;
SET GLOBAL rpl_semi_sync_slave_enabled = 1;

-- 超时时间（超过就退化成异步）
SET GLOBAL rpl_semi_sync_master_timeout = 1000;   -- 毫秒
```

## 五、搭建步骤（一步步来）

### 5.1 主库配置

```ini
# my.cnf
[mysqld]
server-id = 1                    # 必须唯一
log_bin = /var/log/mysql/mysql-bin
binlog_format = ROW
binlog_row_image = FULL
expire_logs_days = 7             # 自动清理 7 天前的 binlog
```

```sql
-- 创建复制专用账号
CREATE USER 'repl'@'%' IDENTIFIED BY 'StrongPass123';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;

-- 查看主库状态，记下 File 和 Position
SHOW MASTER STATUS;
-- +------------------+----------+
-- | mysql-bin.000003 |    154   |
-- +------------------+----------+
```

### 5.2 从库配置

```ini
[mysqld]
server-id = 2                    # 必须跟主库不同
relay_log = /var/log/mysql/relay-bin
read_only = 1                    # 从库只读（对 SUPER 权限用户无效）
super_read_only = 1              # 8.0+，连 SUPER 也只读
```

### 5.3 数据初始化

主库已有数据时，需要先同步一份全量到从库：

```bash
# 用 mysqldump 导出（--single-transaction 保证一致性快照，不锁表）
mysqldump --single-transaction --master-data=2 \
          --all-databases -uroot -p > full.sql

# 在从库导入
mysql -uroot -p < full.sql
```

`--master-data=2` 会把 `CHANGE MASTER TO` 需要的
binlog 文件名和位置以注释形式写进 SQL 文件，
导入后直接能看到。

### 5.4 启动复制

```sql
-- MySQL 8.0.23+ 推荐新语法
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='10.0.0.1',
    SOURCE_USER='repl',
    SOURCE_PASSWORD='StrongPass123',
    SOURCE_LOG_FILE='mysql-bin.000003',
    SOURCE_LOG_POS=154;

START REPLICA;

-- 老语法（5.7/8.0 早期）
CHANGE MASTER TO MASTER_HOST='10.0.0.1', ...;
START SLAVE;
```

### 5.5 检查状态

```sql
SHOW REPLICA STATUS\G      -- 8.0.22+
-- 或 SHOW SLAVE STATUS\G

-- 关键看这两行（5.7/8.0 单线程）
Slave_IO_Running: Yes
Slave_SQL_Running: Yes

-- 8.0 多线程复制下看
Replica_IO_Running: Yes
Replica_SQL_Running: Yes

Seconds_Behind_Master: 0     -- 延迟秒数
Last_IO_Error:               -- IO 线程错误
Last_SQL_Error:              -- SQL 线程错误
```

**两个 Yes 才算正常**。任何一个 No 就去看对应的 `Last_*_Error`。

## 六、主从延迟：最头疼的问题

### 6.1 延迟从哪来

主库执行 → 写 binlog → 网络传输 → 从库写 relay log → SQL 线程回放

延迟可能来自任何一环：

| 环节 | 常见原因 |
|---|---|
| 主库写 binlog 慢 | 大事务、磁盘 IO 差 |
| 网络传输慢 | 跨机房、带宽不足 |
| **从库回放慢** | **最常见**：单线程回放跟不上主库并发写入 |
| 从库负载高 | 从库上跑了大量读查询，抢资源 |

### 6.2 最核心的原因：单线程回放

主库可以几百个连接并发写，但从库 SQL 线程**只有一个**，
必须串行回放。主库 1 秒写 1000 个事务，从库 1 秒只能回放 200 个，
延迟就会持续累积。

**解决方案：多线程复制（MTS）**

```sql
-- MySQL 5.7+ 支持基于逻辑时钟的并行回放
SET GLOBAL slave_parallel_type = 'LOGICAL_CLOCK';
SET GLOBAL slave_parallel_workers = 8;      -- 8 个 worker 线程

-- 8.0 默认已经是 LOGICAL_CLOCK，workers 默认 4
SHOW VARIABLES LIKE 'slave_parallel%';
```

`LOGICAL_CLOCK` 的原理：**同一组提交的事务在主库上没有冲突，
可以并行回放**。所以主库并发度越高，从库也越能并行。

⚠️ 但有个前提：**主库的 `binlog_group_commit` 相关参数要调好**，
否则事务组划分得太细，并行度上不去。

```sql
SET GLOBAL binlog_group_commit_sync_delay = 100;       -- 微秒，稍微攒一攒
SET GLOBAL binlog_group_commit_sync_no_delay_count = 10;
```

### 6.3 大事务：延迟的另一大来源

```sql
-- ❌ 一个事务改 100 万行
UPDATE orders SET status = 'archived' WHERE created_at < '2025-01-01';
-- 从库要回放这个巨大的事务，期间延迟飙升
```

**解决：拆成小批量**

```python
# 分批更新，每批 1000 行
while True:
    n = cursor.execute("""
        UPDATE orders SET status='archived'
        WHERE created_at < '2025-01-01' AND status != 'archived'
        LIMIT 1000
    """)
    conn.commit()
    if n == 0: break
    time.sleep(0.1)      # 给从库一点喘息时间
```

**纪律：禁止在主库执行影响行数超过 1 万的单条 DML。**

### 6.4 延迟怎么监控

```sql
SHOW REPLICA STATUS\G
-- Seconds_Behind_Master
```

⚠️ **`Seconds_Behind_Master` 不完全可靠**：

1. 它是用**时间戳差值**算的，主库没写入时会显示 0，
   但实际可能有积压（因为没新的 binlog 事件来更新时间）
2. 主从机器**时钟不同步**时数值不准
3. 大事务期间它不准

**更可靠的判断：对比 binlog 位点**

```sql
-- 主库
SHOW MASTER STATUS;       -- Position: 1540000

-- 从库
SHOW REPLICA STATUS\G
-- 看 Relay_Source_Log_File / Exec_Source_Log_Pos
-- 对比主库的 File/Position 差多少
```

或者用 `pt-heartbeat`（Percona 工具），
在主库写心跳表，从库读，算出真实延迟。这是生产最准的做法。

## 七、读写分离怎么落地

### 7.1 应用层路由（最常见）

```python
class Router:
    def __init__(self, master, slaves):
        self.master, self.slaves = master, slaves

    def get_conn(self, sql: str, in_transaction: bool):
        # 写操作、事务内、或刚写完需要读自己写入的数据 → 走主库
        if in_transaction or is_write(sql):
            return self.master
        return random.choice(self.slaves)      # 读走从库
```

⚠️ **关键坑：写完立刻读**会因为延迟读不到自己刚写的数据。

```python
# ❌ 写完马上读从库，可能读到旧数据
db_master.execute("INSERT INTO orders ...")
row = db_slave.query("SELECT * FROM orders WHERE id = %s", (new_id,))
# 可能查不到！

# ✅ 方案一：这类读强制走主库
row = db_master.query("SELECT ...")

# ✅ 方案二：写完后的 N 秒内读主库（基于 GTID 或时间戳判断）
```

这个坑叫**"读己之写"一致性问题**，是读写分离落地的第一大坑。

### 7.2 中间件方案

不想改代码可以用中间件，它解析 SQL 自动路由：

| 中间件 | 特点 |
|---|---|
| **ProxySQL** | 功能强，支持查询规则、连接池、故障转移 |
| **MyCat** | 国产，支持分库分表 |
| **ShardingSphere** | Apache 项目，生态好 |

代价是多一跳网络、多一个组件要维护。

### 7.3 用 Hint 强制走主库

```sql
-- 在 SQL 里加注释，中间件识别
SELECT /*+ MASTER */ * FROM orders WHERE id = 1;
```

## 八、常见故障处理

### 8.1 主键冲突导致复制中断

```sql
SHOW REPLICA STATUS\G
-- Last_SQL_Error: Duplicate entry '5' for key 'PRIMARY'
```

原因：从库被写入了数据，或者主从数据本来就不一致。

快速恢复（**慎用，会丢数据**）：

```sql
STOP REPLICA;
SET GLOBAL sql_slave_skip_counter = 1;    -- 跳过 1 个事件
START REPLICA;
```

**更好的做法**：用 `pt-table-sync` 修复不一致，或者重建从库。

### 8.2 从库落后太多

如果延迟已经几十分钟且追不上，**重建从库**反而更快：
重新 mysqldump 一份全量，重新 START REPLICA。

### 8.3 主从不一致校验

```bash
# Percona 工具
pt-table-checksum --databases=test u=root,p=xxx
pt-table-sync --print --databases=test u=root,p=xxx   # 先 --print 看差异
```

建议**定期跑一次校验**（比如每周），别等出问题才发现不一致。

## 九、小结

- 复制靠**三个线程**：主库 dump 线程，从库 IO 线程 + SQL 线程
- **binlog 必须用 ROW 格式**（STATEMENT 有 `NOW()` 这类不安全语句）
- 三种复制模式：异步（默认）、**半同步（生产推荐）**、组复制
- 搭建四步：配 server-id → 建复制账号 → 导全量 → CHANGE MASTER + START SLAVE
- **两个 Yes 才正常**，看 `Last_IO_Error` / `Last_SQL_Error`
- 延迟主因是**从库单线程回放** → 开多线程复制（`LOGICAL_CLOCK`）
- **禁止大事务**，批量操作拆成小批
- `Seconds_Behind_Master` 不完全可靠，用 `pt-heartbeat` 更准
- 读写分离第一大坑：**写完立刻读**要强制走主库

下一篇讲分库分表——主从解决读扩展，
但写压力和单表数据量到了瓶颈，就必须把数据拆开了。
