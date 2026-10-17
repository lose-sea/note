# 分区维护：加分区、删分区、REORGANIZE 与在线操作的节奏

分区表建好只是开始——按月分区的时间表，你需要月初加新分区、季末删旧分区，中间还可能 REORGANIZE 调整粒度。这些 DDL 在 6 亿行的日志表上直接执行，锁表时间是灾难级的。这篇文章讲分区维护的四个操作的正确姿势，以及怎么和业务窗口、在线工具配合。

## 维护操作的四个基本动作

```sql
-- ① 加分区（月初执行）
ALTER TABLE access_log ADD PARTITION (
    PARTITION p202611 VALUES LESS THAN ('2026-12-01')
);

-- ② 删分区（季末/年末清理历史）——秒级释放空间
ALTER TABLE access_log DROP PARTITION p202501, p202502, p202503;

-- ③ REORGANIZE 重组（调整粒度或合并）
ALTER TABLE access_log REORGANIZE PARTITION pmax INTO (
    PARTITION p202701 VALUES LESS THAN ('2027-02-01'),
    PARTITION p202702 VALUES LESS THAN ('2027-03-01')
);

-- ④ TRUNCATE 分区（清空但保留结构）
ALTER TABLE access_log TRUNCATE PARTITION p202602;
```

四个动作里，**DROP PARTITION 是分区表最大的红利**：删一个分区是元数据操作 + 释放表空间文件，物理上"删掉一个子表"，6 亿行里删 2 亿行是秒级的。普通表 DELETE 历史数据走 binlog、造碎片、拖慢主从，分区直接赢一个数量级。

## 加分区：忘加的后果和提前量

**不加新分区的后果**：数据全部挤进 MAXVALUE 兜底分区。查询"最近七天"裁不到新分区（全在 pmax 里），分区表退化成单表——**而你可能几周后才发现**，因为不报错。

所以加分区要有**自动化 + 监控**双保险：

```sql
-- 监控：兜底分区有没有数据
SELECT PARTITION_NAME, TABLE_ROWS
FROM information_schema.PARTITIONS
WHERE TABLE_NAME = 'access_log' AND PARTITION_NAME = 'pmax';
-- TABLE_ROWS > 0 就是告警信号
```

自动化方案三种成熟度：

1. **事件调度器**（MySQL 内置）：每月 1 号自动 ADD PARTITION。简单，但调度器本身是单点，要监控它是否活着。
2. **外部定时任务**（crontab + 脚本）：最常用。脚本要幂等——加已存在的分区会报错，先查 information_schema 再决定加不加。
3. **部署在业务系统里**：应用启动时检查分区水位，不够就补。和应用生命周期绑定，最不容易被遗忘。

生产脚本的骨架：

```bash
#!/bin/bash
# 提前加未来 3 个月的分区
DB=logdb
TABLE=access_log
for i in 1 2 3; do
    ym=$(date -d "+${i} month" +%Y-%m)
    next=$(date -d "+$((i+1)) month" +%Y-%m-01)
    # 分区名和未来月份。注意 name 规则
    part="p$(date -d "+${i} month" +%Y%m)"
    exists=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.PARTITIONS 
             WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='$TABLE' AND PARTITION_NAME='$part'")
    if [ "$exists" = "0" ]; then
        mysql -e "ALTER TABLE $TABLE ADD PARTITION (PARTITION $part VALUES LESS THAN ('$next'))"
        echo "$(date) added $part"
    fi
done
```

**提前量给 3 个月**：不是加当前月，是加未来三个月。这样即使调度挂了，兜底还能扛一个季度，监控告警有时间反应。

## 删分区：红利与陷阱

DROP PARTITION 很快，但有个常被忽略的陷阱——**分区里可能有还没归档/还在使用的数据**。删之前的三步核查：

```sql
-- 1. 分区里的数据量和时间范围
SELECT COUNT(*), MIN(created_at), MAX(created_at) FROM access_log PARTITION (p202501);

-- 2. 业务侧确认这些数据不再需要实时查（超过冷存档期限）

-- 3. 有归档需求的，先 INSERT INTO archive SELECT ... PARTITION (p202501) 再删
```

删完之后的动作：

```sql
-- 确认空间释放（独立表空间时）
SHOW TABLE STATUS LIKE 'access_log';   -- Data_free 应该归零

-- InnoDB 独立表空间模式（默认），分区删除后 .ibd 文件直接消失；
-- 共享表空间或 file-per-table 关闭时，空间不还给 OS，只标为可复用
```

第二条是重点：`innodb_file_per_table=ON`（默认）时删分区物理释放 `.ibd` 文件；如果实例是共享表空间的老配置，删了几个分区的空间还在 ibdata1 里，`Data_free` 增长但磁盘不减——**迁移到独立表空间是这类实例的第一优先级**。

## REORGANIZE：粒度过时的补救

典型场景：日志按月分区三年后，查询变成"按小时查最近一天"——月分区粒度太粗，一个分区 2000 万行，裁剪收益打折。

```sql
-- 把当前月分区拆成 30 个日分区
ALTER TABLE access_log REORGANIZE PARTITION p202610 INTO (
    PARTITION d20261001 VALUES LESS THAN ('2026-10-02'),
    PARTITION d20261002 VALUES LESS THAN ('2026-10-03'),
    ...
    PARTITION d20261031 VALUES LESS THAN ('2026-11-01')
);
```

代价：**REORGANIZE 重建该分区的所有索引**。大分区执行期间锁该分区的读写（其他分区不受影响——这是分区维护的隐藏红利，操作粒度是分区级）。6 亿行的表重组一个 2000 万行的分区，分钟级；选低峰期执行。

REORGANIZE 的常见错误是拿 pmax 开刀——它往往积累了大量"意外数据"（时间乱序的写入），重组时全要搬。**重组前先查 pmax 的数据时间分布**，异常数据是别处来的脏数据，先治理写入端。

## 大表上的分区维护：阻塞问题

分区 DDL 的锁行为（MySQL 8.0）：

```
ADD PARTITION        → 大部分情况 ALGORITHM=INSTANT 或 INPLACE，锁短暂
DROP PARTITION       → 元数据 + 释放文件，快
TRUNCATE PARTITION   → 同 DROP
REORGANIZE PARTITION → ALGORITHM=INPLACE 或 COPY，重
```

但"大部分情况"不等于所有情况——**带外键、或有分区外的二级索引结构特殊时，可能降级**。8.0 的判断：

```sql
-- 看 DDL 实际会不会阻塞
ALTER TABLE access_log ADD PARTITION (...) ALGORITHM=INPLACE, LOCK=NONE;
-- 如果优化器/引擎拒绝，直接报错而不是静默阻塞——这是好事
```

**对十亿级大表，分区加删也走 pt-osc/gh-ost**。注意这两个工具对分区表的支持有差异：pt-osc 对 ADD/DROP PARTITION 的支持有限，gh-ost 对分区操作（尤其 ADD PARTITION）支持更好。**极端情况下的 Plan B**：业务低峰期直接 DDL，准备好回滚脚本和变更公告。

## 自动化的完整方案：事件调度器示例

```sql
-- MySQL 事件调度器：每月 1 号加分区、上季度末删分区
SET GLOBAL event_scheduler = ON;

DELIMITER //
CREATE EVENT IF NOT EXISTS evt_access_log_maintain
ON SCHEDULE EVERY 1 MONTH
STARTS '2026-11-01 02:00:00'
DO
BEGIN
    -- 加未来分区（条件存在性检查防止重复）
    SET @cnt = (SELECT COUNT(*) FROM information_schema.PARTITIONS
        WHERE TABLE_SCHEMA='logdb' AND TABLE_NAME='access_log'
          AND PARTITION_DESCRIPTION = DATE_FORMAT(DATE_ADD(NOW(), INTERVAL 2 MONTH), '%Y-%m-01'));
    IF @cnt = 0 THEN
        SET @ddl = CONCAT('ALTER TABLE logdb.access_log ADD PARTITION (
            PARTITION p', DATE_FORMAT(DATE_ADD(NOW(), INTERVAL 2 MONTH), '%Y%m'),
            ' VALUES LESS THAN (''', DATE_FORMAT(DATE_ADD(NOW(), INTERVAL 3 MONTH), '%Y-%m-01'), '''))');
        PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    END IF;
END //
DELIMITER ;
```

事件调度器的坑：**主从复制的是事件还是它产生的 DDL****——默认复制 DDL 不复制事件本身。从库要么也建事件（手动同步），要么主库的 DDL 通过 binlog 同步后从库分区状态自动跟上。**混合双写场景下，主从分区不一致是隐形炸弹**：主上加了分区、从上报错或行为分叉。生产上分区维护必须确认主从都执行到位。

## 监控清单

分区表上线后的固定巡检项：

```sql
-- 1. 分区数量（上限 8192）
SELECT TABLE_NAME, COUNT(*) AS partition_count
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'logdb' GROUP BY TABLE_NAME;

-- 2. 兜底分区数据量（>0 告警）
SELECT * FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA='logdb' AND PARTITION_NAME='pmax' AND TABLE_ROWS > 0;

-- 3. 各分区行数分布（发现冷热不均）
SELECT PARTITION_NAME, TABLE_ROWS, ROUND(DATA_LENGTH/1024/1024) AS mb
FROM information_schema.PARTITIONS WHERE TABLE_NAME='access_log'
ORDER BY PARTITION_ORDINAL_POSITION;

-- 4. 事件调度器状态
SHOW EVENTS FROM logdb LIKE 'evt%';
SHOW STATUS LIKE 'event%';
```

## 小结

分区维护四动作：**加分区要提前 3 个月并自动化、删分区是秒级红利但要核查归档、REORGANIZE 是重操作要挑低峰、TRUNCATE 是清空数据保结构**。大表上分区 DDL 也要评估阻塞、必要时在线工具；事件调度器自动化加分区但要注意主从一致性差异。监控四个指标：分区数、兜底分区数据量、分布冷热、调度器存活。分区表是"低维护成本换查询性能"的交换——运维自动化不到位，红利会变成半夜的告警。下一篇讲分区设计的边界，哪些场景分区反而坑你。
