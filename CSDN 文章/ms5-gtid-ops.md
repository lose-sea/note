# GTID 实务：从 binlog 文件名地狱里解放出来的复制坐标

MySQL 5.6 之前，搭建复制要记 `MASTER_LOG_FILE` + `MASTER_LOG_POS`——"从 master-bin.000123 第 456789 位置开始复制"。主库切 binlog、清理日志、failover 之后，这一对数字全乱套，几台从库逐个对坐标是 DBA 的日常噩梦。GTID（Global Transaction Identifier）用一个全局唯一的事务 ID 替换了文件+位置，把复制配置简化成一行。这篇文章讲 GTID 的机制、日常操作和故障场景的应对。

## GTID 是什么：事务的身份证

格式：`server_uuid:transaction_id`

```
3E11FA47-71CA-11E1-9E33-C80AA9429562:1
```

- `server_uuid`：生成这个事务的 MySQL 实例的 UUID（`SELECT @@server_uuid`，自动生成、实例唯一）。
- `transaction_id`：该实例内从 1 开始单调递增的序号。

**每个提交事务，全局唯一一个 GTID**。复制链路不再关心 binlog 文件名和偏移，只关心"我执行过哪些 GTID"。

## 复制工作原理的变化

传统 binlog 复制：从库问"master 的哪个文件哪个位置之后的事"，主库答"从这个坐标开始读 binlog 给我"。

GTID 复制：从库问"master 你有哪些我没执行过的事务"，主库答"我算一下，把这些 GTID 对应的 binlog 发给你"。

核心转变：**从"位置驱动"变成"集合差集驱动"**：

```
从库已执行集合：{uuid_a:1-100, uuid_b:1-50}
主库全部集合： {uuid_a:1-150, uuid_b:1-80}
差集：uuid_a:101-150, uuid_b:51-80  ← 主库只发这些
```

从库执行完一个 GTID，把它记入自己的 `gtid_executed` 集合。**failover 换主库时，新主库算差集就行，不需要人工找坐标**——这是 GTID 最大的运维价值。

## 开启 GTID

生产库不开 GTID 的越来越少了，5.7/8.0 都是默认推荐开启：

```ini
# my.cnf —— 注意：改这项要重启
gtid_mode = ON
enforce_gtid_consistency = ON    # 强制 GTID 兼容性，挡掉不兼容写操作
```

`enforce_gtid_consistency = ON` 会拒绝两类"GTID 不安全"操作：

```sql
-- 会被拒绝：
CREATE TABLE ... SELECT ...        -- 表和事务混在一个语句
DELETE FROM t1 JOIN t2 ...         -- 多表更新且明确指定 GTID 顺序问题
UPDATE t1 SET id = id + 1;         -- 有自增列的混合更新
```

报错 `ERROR 3525`。改用 GTID 安全写法（先 CREATE TEMPORARY TABLE 再 INSERT；UPDATE 拆成单表；`SET sql_log_bin` 类操作不允许）。

**从 binlog 模式在线升级 GTID**（5.7 支持不重启切换）：

```sql
-- 逐项改（5.7 可在线改部分，8.0 也可动态改）
SET GLOBAL enforce_gtid_consistency = ON;
SET GLOBAL gtid_mode = OFF_PERMISSIVE;   -- 中间态
SET GLOBAL gtid_mode = ON_PERMISSIVE;    // 中间态
-- 确认所有从库都 ON 后
SET GLOBAL gtid_mode = ON;
```

升级步骤的要害是**从库同步升级**：主库先 ON 之后 binlog 里全是 GTID 格式，还跑在旧模式的从库解析不了。灰度顺序：所有从库先升级 → 主库最后 ON，中间态期间新连接按 GTID 协商。

## 搭建从库：CHANGE MASTER 的简化

```sql
-- GTID 模式下一行搞定，不需要文件坐标
CHANGE MASTER TO
    MASTER_HOST = 'master.db',
    MASTER_USER = 'repl',
    MASTER_PASSWORD = 'xxx',
    MASTER_AUTO_POSITION = 1;      -- 这一行就是 GTID 自动定位
START SLAVE;
```

`MASTER_AUTO_POSITION = 1`：从库把 gtid_executed 发给主库，主库算差集开传。**换主库就再执行一次 CHANGE MASTER 指向新主库**，不用从 binlog 里捞坐标。

查看状态：

```sql
SHOW SLAVE STATUS\G
-- 关键字段：
-- Retrieved_Gtid_Set: 已从主库拉到的 GTID 集合
-- Executed_Gtid_Set:  已执行的
-- Auto_Position: 1     （开着自动定位）
-- 主从延迟看 Seconds_Behind_Master，但 GTID 模式下更准的是对比两端 gtid_executed
```

## 常用操作清单

### 从库重新指向主库

```sql
STOP SLAVE;
RESET SLAVE ALL;              -- 清空复制元数据（注意：这也清 relay log）
CHANGE MASTER TO MASTER_HOST='newmaster', MASTER_AUTO_POSITION=1, ...;
START SLAVE;
```

`RESET SLAVE ALL` 在 GTID 模式下多数场景可用——因为从库重新拉齐靠集合差集，不依赖历史位置。**但注意它清空 relay log 和复制过滤配置**，有复制过滤（下篇讲）的从库要重新设置。

### 跳过指定事务（复制报错时）

```sql
-- 二号从库在 uuid:456 报 Duplicate entry，需要跳过
STOP SLAVE;
SET GTID_NEXT = '3E11FA47-71CA-11E1-9E33-C80AA9429562:456';
BEGIN; COMMIT;               -- 空事务"执行"这个 GTID，把它加进 gtid_executed
SET GTID_NEXT = AUTOMATIC;
START SLAVE;
```

**空事务注入**是 GTID 模式跳过错误的正确姿势——比传统 `sql_slave_skip_counter` 精确（那个跳计数可能跳过头）。跳过前必须确认这个 GTID 在主库上到底是什么：`mysqlbinlog --include-gtids='...:456'` 看原事务，评估跳过的业务影响。

### 从 mysqldump 恢复带 GTID 的集簇

```sql
-- 主库导出
mysqldump --all-databases --single-transaction --triggers --routines \
          --set-gtid-purged=ON --master-data=2 > full.sql
```

`--set-gtid-purged=ON`（默认）会在导出文件头部生成：

```sql
SET @@GLOBAL.GTID_PURGED = "uuid_a:1-150,uuid_b:1-80";
```

从库/新集群 restore 后执行这个文件，gtid_executed 直接包含这些集合——**恢复出来的库立刻能作为任何旧从库的新主库**（集合包含关系成立）。这就是用 dump 文件搭集簇不丢复制位置的秘诀。

## 故障场景：GTID 相关的三个经典坑

**坑一：从库 Executed_Gtid_Set 有主库没有的 GTID**（脑裂残留）。

```sql
-- 从库当过主，写过 uuid_c:1-50，现在重新指向新主
CHANGE MASTER TO ... MASTER_AUTO_POSITION=1;
-- 报错：The slave is connecting using GTID AUTO-POSITION, 
-- but the master has purged binary logs containing GTIDs that the slave requires.
```

原因：新主的 binlog 已被清理（`expire_logs_days` 或手动 PURGE），它发不出从库需要的 GTID，而从库的集合又比新主大。解法：从新主重新 dump（`--set-gtid-purged=ON`）恢复从库。**所以 failover 之后旧从库重新入列，先看新主的 binlog 保留期够不够覆盖**。

**坑二：gtid_purged 不能删**。

`gtid_purged`（已清理的 GTID 集合）是只读的：实例重启不丢、不能 SET 为空。恢复数据时如果 dump 文件里的 `SET @@GLOBAL.GTID_PURGED` 和现有实例的集合有交集——冲突，restore 失败。恢复旧 dump 到现有环境，用 `--set-gtid-purged=OFF` 导出重新来，或者 RESET MASTER 后在新实例恢复。

**坑三：主从 gtid_executed 不一致但无报错**。

从库 `Executed_Gtid_Set` 缺了主库的某个 GTID，但复制没断（那个事务没被应用到当前 binlog 流）。`pt-table-checksum` 校验时才会暴露。GTID 模式给了你精确的集合对比能力，但数据一致性校验还是独立工程——下篇 pt-checksum 专门讲。

## 监控要点

```sql
-- 1. 各实例的 GTID 模式和集合
SELECT @@gtid_mode, @@gtid_executed\G

-- 2. 主从集合差异（从库上执行）
SHOW SLAVE STATUS\G   -- 看 Retrieved vs Executed 的大小差异

-- 3. 复制延迟的 GTID 算法（比 Seconds_Behind 准）
-- 主库当前 GTID vs 从库 Executed 最后一个 GTID 的事务在主库的时间戳
```

生产监控建议把 `gtid_executed` 的集合大小拉进 Grafana，画主从差值曲线。GTID 差集增长 = 复制延迟；差集突降 = 追上了。这比 `Seconds_Behind_Master` 在"大事务复制"场景准得多——后者在大事务执行期间显示 0（滞后未计算），GTID 差值不会说谎。

## 小结

GTID 用 `server_uuid:transaction_id` 给每个事务发身份证，复制从"文件坐标对齐"变成"集合差集同步"，CHANGE MASTER 加 `MASTER_AUTO_POSITION=1` 一行完成指向。运维红利集中在 failover 和从库重建；三个经典坑（binlog 清理冲突、gtid_purged 只增、集合漂移）要提前认清。dump 文件头部的 `SET @@GLOBAL.GTID_PURGED` 是集簇恢复的关键语法。下一篇讲复制过滤——哪些库表同步、哪些不同步，以及它的主从不一致陷阱。
