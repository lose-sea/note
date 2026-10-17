# XtraBackup 增量备份：全量打底、增量叠加、按时间点恢复

500GB 的业务库，每天全备一次要 40 分钟，备份窗口越来越紧——增量备份是标准答案：**每周一次全量打底，每天增量，恢复时全量 + 一串增量叠加**。这篇文章用 Percona XtraBackup 8.0 把增量备份的原理、操作流程和恢复演练讲透，附带一份生产备份策略模板。

## 增量的原理：LSN 水位线

InnoDB 每个页都有 LSN（Log Sequence Number，逻辑时钟）。XtraBackup 备份的本质是：

```
全量备份：把所有数据页拷贝到备份目录，记录备份结束时引擎的 LSN（to_lsn）
增量备份：只拷贝 to_lsn 之后修改过的页，记录本轮新的 to_lsn
```

增量不是"解析 binlog 找变更"（那是另一种思路），而是**页级差异**：MySQL 8.0 的 InnoDB 按页追踪修改历史，xtrabackup 从上一个备份的 LSN 往后只拷"从那个水位线以来脏过的页"。

```bash
# 全备
xtrabackup --backup --target-dir=/backup/full_20261016

# 备份完成后，看 to_lsn
cat /backup/full_20261016/xtrabackup_checkpoints | grep to_lsn
# to_lsn = 1234567890
```

增量基于这个 LSN 继续：

```bash
# 第一次增量：从全备的 to_lsn 开始
xtrabackup --backup --target-dir=/backup/inc1_20261017 \
    --incremental-basedir=/backup/full_20261016

# 第二次增量：基于上一次增量
xtrabackup --backup --target-dir=/backup/inc2_20261018 \
    --incremental-basedir=/backup/inc1_20261017
```

`--incremental-basedir` 指向上一轮备份目录，工具自动读它的 to_lsn 作为起点。增量链就是这么一节节接起来的。

## 生产备份脚本：策略与节奏

一份可直接改造的生产方案：

```bash
#!/bin/bash
# backup.sh —— XtraBackup 8.0 全量+增量策略
BACKUP_ROOT=/data/backup
FULL_DAY=Sun               # 周日全备，其余增量
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=30
LOG=/var/log/xtrabackup.log

exec >> $LOG 2>&1
echo "===== $DATE backup start ====="

if [ $(date +%a) = "$FULL_DAY" ]; then
    # 全量
    xtrabackup --backup \
        --user=bkp_user --password=xxx \
        --target-dir=$BACKUP_ROOT/full/$DATE \
        --compress --compress-threads=4 \
        --parallel=4 \
        --stream=xbstream | \
        ssh backup@storagenode "cat > $BACKUP_ROOT/full/$DATE.xbstream"
    # 记录 LSN 供增量用
    echo $DATE > $BACKUP_ROOT/last_full_tag
else
    LAST_FULL=$(cat $BACKUP_ROOT/last_full_tag)
    # 找 last_full 之后最新的增量做基准（链式）
    BASE=$(ls -d $BACKUP_ROOT/inc/${LAST_FULL}_inc* 2>/dev/null | tail -1)
    [ -z "$BASE" ] && BASE=$BACKUP_ROOT/full/$LAST_FULL
    xtrabackup --backup \
        --user=bkp_user --password=xxx \
        --target-dir=$BACKUP_ROOT/inc/${LAST_FULL}_inc_$DATE \
        --incremental-basedir=$BASE \
        --compress --compress-threads=4
fi

# 备份校验 + 清理
xtrabackup --prepare --target-dir=$BACKUP_ROOT/full/$DATE 2>/dev/null || true
find $BACKUP_ROOT -mtime +$KEEP_DAYS -name "*.xbstream" -delete
find $BACKUP_ROOT/inc -mtime +$KEEP_DAYS -type d -exec rm -rf {} \;

# 校验备份可用（定期）
echo "$DATE done, size: $(du -sh $BACKUP_ROOT/full/$DATE 2>/dev/null | cut -f1)"
```

策略要点解释：

1. **全量周日、增量周一~周六**。增量链最长 6 节，恢复时叠加 6 次，时间可控。链太长恢复风险累积，**别超过 7 节**。
2. **压缩 + 多线程**。500GB 库压缩后通常 150~250GB（InnoDB 页压缩率 2:1 常见），`--compress-threads` 吃 CPU 別和业务抢。
3. **流式 + SSH 到存储机**。备份目录在存储机上而不是库房本地，库挂了机器还能访问备份。备份集至少 3-2-1 原则：3 份拷贝、2 种介质、1 份异地。
4. **KEEP_DAYS=30**。按合规要求调整，金融通常 180 天起。

备份账号要最小权限：`RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT, BACKUP_ADMIN`。**不给 SUPER**——XtraBackup 8.0 用 `BACKUP_ADMIN` 就够，旧版的 SUPER 已经不推荐。

## 恢复：prepare 的 prepare 和 copy-back 的 copy-back

恢复分两阶段，概念必须分清：

**阶段一 prepare（在备份机上做）**：把增量备份"合并回滚"进全备，形成可直接使用的数据目录。

```bash
# 1. 准备全量目录（--apply-log-only，不回滚，保持可接受增量）
xtrabackup --prepare --apply-log-only --target-dir=/backup/full/20261016

# 2. 逐个增量 prepare（每个都要 --apply-log-only）
xtrabackup --prepare --apply-log-only --target-dir=/backup/full/20261016 \
    --incremental-dir=/backup/inc/full_inc_20261017
xtrabackup --prepare --apply-log-only --target-dir=/backup/full/20261016 \
    --incremental-dir=/backup/inc/full_inc_20261018
# ... 链路每一节都来一遍

# 3. 最后一节 prepare 时去掉 --apply-log-only（执行回滚）
xtrabackup --prepare --target-dir=/backup/full/20261016
```

`--apply-log-only` 的含义：只前滚已提交事务、不回滚未提交的——**中间的增量处理必须保留未提交事务等下一节**，只有最后一节才做完整回滚。顺序错了（中间节没加 apply-log-only）备份直接报废，这是新手最高频的错误。

**阶段二 copy-back（在目标库机器上做）**：

```bash
# 目标库 datadir 必须为空
systemctl stop mysql
rm -rf /var/lib/mysql/*

xtrabackup --copy-back --target-dir=/backup/full/20261016
chown -R mysql:mysql /var/lib/mysql
systemctl start mysql
```

## 按时间点恢复（PITR）

备份恢复到的是"备份那一刻"的状态，之后的数据在 binlog 里。恢复到"事故前 5 分钟"的标准流程：

```bash
# 1. 全量+增量 prepare 并 copy-back（恢复到周日全备 + 增量覆盖到周六）
# 2. 找到起始 GTID 或 binlog 坐标（备份 checkpoints 里有）
cat /backup/full/20261016/xtrabackup_binlog_info
# mysql-bin.000123  4567890

# 3. 应用 binlog 到事故前时间点
mysqlbinlog --start-position=4567890 \
    --stop-datetime="2026-10-18 14:25:00" \
    /data/mysql/mysql-bin.000123 | mysql -u root -p
```

GTID 模式更简洁：

```bash
# xtrabackup 8.0 的 gtid_executed 记录
mysqlbinlog --include-gtids='...' --exclude-gtids='...' | mysql
```

误操作事故（DROP TABLE、UPDATE 没带 WHERE）的标准恢复姿势 = 备份 + PITR，下一篇 binlog 闪回讲"不动备份直接回滚"的轻量方案，两者是不同场景的互补。

## 演练：备份恢复的最后一公里

**没恢复过的备份等于没有备份**。恢复演练清单：

1. **月度全链路演练**：随机抽一份最近的备份（含增量链），在测试环境完整走一遍 prepare → copy-back → 启动 → 数据完整性校验（行数、checksum 对核心表）。记录耗时。
2. ** ritein 时长红线**：500GB 库的恢复时长如果超过业务容忍的 RTO，方案就要调整（比如增量链缩短、并行 copy-back、存储升级）。**恢复演练的最大价值是暴露 RTO 和 RPO 的真实值**。
3. **binlog 保留期对齐**：增量备份的天数 × 每天的备份量，决定了 binlog 至少要保留覆盖整个备份周期的时长。`expire_logs_days` 别短于备份保留策略——否则备份期间 binlog 清掉，PITR 断链。
4. **备份失败告警**：脚本 exit code 接监控，备份失败 = 数据裸奔，这类告警级别和主库宕机同级。

## 常见坑

- **增量基准指错**：`--incremental-basedir` 指到全量目录两次（本该指上一次增量），增量就"漏了中间的变化"。
- **prepare 阶段机器内存不够**：大备份 prepare 是重 IO + 内存操作，在测试环境跑要调到生产规格。
- **备份期间长事务**：xtrabackup 是物理热备不锁表，但如果备份开始时有个跑了几小时的大事务，prepare 阶段会卡在它上面。备份时间点避开批处理。
- **libmysqlclient / 版本不匹配**：MySQL 8.0 库必须 XtraBackup 8.0，跨大版本混用直接报错或不兼容。

## 小结

XtraBackup 增量备份 = LSN 水位线 + 页级差异拷贝。策略模板：周日全量、平日增量（链不超 7 节）、压缩流式异地、30 天保留。恢复两阶段：prepare 合并增量（中间节必须 `--apply-log-only`，末节完整回滚）→ copy-back + 重启。PITR 靠 binlog 补备份点到事故点的数据。演练是最后一道关：没跑过恢复的备份只是占磁盘的文件。下一篇换 mydumper/myloader——逻辑备份在高并发提取和自定义过滤上的优势场景。
