# mydumper/myloader：逻辑备份的多线程进化

mysqldump 是逻辑备份的老祖宗，但它单线程、大表导出慢、恢复更慢——500GB 库 dump 一遍大半天。**mydumper**（社区版 mydumper/myloader，Percona 维护）用多线程把这个过程压缩一个数量级，还带来一堆符合生产需要的过滤和一致性能力。这篇文章讲它的核心优势、典型用法和与物理备份的分工。

## mydumper 强在哪：四个硬点

**1. 多线程导出**。mysqldump 一个连接从头 dump 到尾；mydumper 起 N 个线程（`--threads`）并行导不同表、大表还按主键分块（`--rows`）。16 线程下 500GB 库导出能从 6 小时压到 30 分钟。**线程数不是越多越好**——导出是 IO + CPU 活，16~32 是常见甜点，压垮业务就得不偿失**，配 `--less-locking` 和 `--long-query-guard` 保平安：

```bash
mydumper --host=127.0.0.1 --user=bkp --password=xxx \
    --outputdir=/backup/dump_20261018 \
    --threads=16 \
    --compress \
    --trx-consistency-only          # 单事务一致性快照
```

**2. 一致性快照保证**。mydumper 默认对每个表用 `START TRANSACTION WITH CONSISTENT SNAPSHOT`，导出期间不锁表（InnoDB）。`--trx-consistency-only` 一把全局快照全程适用，比默认逐表开事务更严格——跨表关联的导出也在同一时间点。

**3. 输出结构规范**。每张表独立文件：

```
/backup/dump_20261018/
├── metadata                      # 库表结构、快照信息、binlog 坐标
├── biz_db-schema-create.sql      # 库 DDL
├── biz_db.orders-schema.sql      # 表结构
├── biz_db.orders.00000.sql.gz    # 数据（按 --rows 分块）
├── biz_db.orders.00001.sql.gz
├── biz_db.order_item.00000.sql.gz
└── ...
```

**分文件的好处**：恢复时可以挑表恢复、单表并行恢复、文件级去重；`metadata` 里记录了导出的 binlog 位点（GTID 模式下是 GTID 集合），后续配 PITR 直接用。

**4. 过滤与正则**。`--database`、`--tables-list`、`--omit-from-file`、正则表达式通配——"只导 biz_db 的 orders 和 order_item，排除 view"这类精细控制，mysqldump 要么全有要么全无。ETL 抽取、库表迁移的前处理，mydumper 的过滤能力直接省掉中间步骤。

## myloader：并行恢复 + 关键顺序

```bash
myloader --host=newdb --user=root --password=xxx \
    --directory=/backup/dump_20261018 \
    --threads=16 \
    --queries-per-transaction=1000 \
    --binary-mode
```

多线程并行导入把所有表并行载入，**大库里恢复速度是 mysql < dump.sql 的 5~10 倍**。但并行也有讲究：

- **先表结构、后数据**：myloader 默认按 schema-create → data 的顺序处理，`--queries-per-transaction` 控制多少条 INSERT 打一个事务包——1000 是写入性能和日志压力的平衡点。
- **外键约束**：并行导入如果表间有外键，多线程乱序会触发约束失败。myloader 默认 `SET foreign_key_checks=0` 导入完再开——业务有强外键需求的自己确认数据干净。
- **`--binlog-mode` 谨慎开**：恢复出来的库如果还要给别人当从库（或它自己作为复制源），导入期间禁 binlog 会断复制位置。

恢复后收尾：

```sql
-- 数据 import 完，如果原库有触发器/存储过程，myloader 需要显式开
-- mydumper 导出时 --routines --triggers 带上，myloader 默认会恢复
-- 校验行数
SELECT COUNT(*) FROM biz_db.orders;
-- 用 pt-table-checksum 校验新旧库一致性（迁移场景）
```

## 场景一：数据迁移的标准工具链

A 库迁 B 库（同版本 MySQL，换硬件/换实例）：

```bash
# 1. A 库导出（业务低峰，一致性快照）
mydumper --host=A --outputdir=/migrate/dump --threads=16 --compress \
    --trx-consistency-only --routines --events

# 2. B 库先还原结构（myloader 会做）
# 3. 并行导入
myloader --host=B --directory=/migrate/dump --threads=16

# 4. 追平增量：metadata 里的 binlog/GTID 位置，建立 B → A 的复制（或做一次性数据对齐）
# 5. 校验 + 割流量
```

迁移场景 mydumper 的核心价值：**导出的 metadata 记录了精确的切割位点**，导入完成后还有"从 A 追平增量"的能力。配合 GTID，`CHANGE MASTER TO MASTER_AUTO_POSITION=1` 一把追齐，这是迁移不丢数据的标准范式。

## 场景二：抽取数据到分析库

```bash
# 只导报表需要的库表，压缩传输
mydumper --host=proddb --outputdir=/extract/biz \
    --database=biz_db \
    --tables-list=biz_db.orders,biz_db.order_item,biz_db.product \
    --where="biz_db.orders:created_at >= '2026-10-01'" \
    --threads=8 --compress
```

`--where` 单表指定条件——**ETL 场景的杀手锏**，只抽增量数据进分析库。mysqldump 的 `--where` 只能全库统一条件，mydumper 按表定制，灵活度差着量级。

限制要知道：**`--where` 的表必须在单表查询内使用子查询**（JOIN 过滤不生效），大表条件过滤要确认走索引否则导出期间全表扫拖慢主库。值不值得看主库负载。

## 场景三：跨环境恢复演练

```bash
# 每周自动恢复一份备份到测试环境，验证备份可用性
myloader --host=testdb --directory=/backup/latest --threads=8
# 跑核心业务查询冒烟
```

上一篇 XtraBackup 恢复是"物理级"（快但要求同版本同配置），**myloader 是"逻辑级"**（慢但跨版本、跨环境更宽容）。测试环境、容量评估、版本升级预演，逻辑恢复是主力。两类备份互补，不是二选一。

## 与物理备份的分工

| 维度 | mydumper/myloader（逻辑） | XtraBackup（物理） |
|---|---|---|
| 恢复速度 | 慢（INSERT 逐行） | **快（文件拷贝）** |
| 备份速度 | 中（受输出 SQL 生成限制） | 快（页拷贝） |
| 跨版本 | **宽容**（5.7 的 dump 可导 8.0，注意兼容性） | 苛刻（版本/页格式绑定） |
| 跨引擎 | 只能 InnoDB/MyISAM 等支持 SQL 接口的 | InnoDB 原生 |
| 备份文件可读性 | **高**（SQL 文本，可 grep 可改） | 低（二进制） |
| 增量 | 不支持（binlog 补） | 原生支持 |
| 选择性恢复 | **强**（表级、行级过滤） | 表级难、行级无 |
| 大表并行 | 表 + 行分块 | 页级流式 |

**选型口诀**：日常备份靠 XtraBackup（快、增量），迁移/抽取/跨版本/可读恢复靠 mydumper。生产通常两套并存：物理备份保 RTO，逻辑备份保灵活性。

## 生产使用注意

1. **权限最小化**：备份账号 `SELECT, RELOAD, PROCESS, REPLICATION CLIENT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER`，照样不需要 SUPER。
2. **备份期间主库负载**：`--threads 16` + `--long-query-guard 60`（超过 60 秒的查询会被警告并可能被 kill 导出连接）双保险；高峰别跑，配合 `--exec` 前后自定义 throttele 脚本更稳。
3. **输出目录的磁盘容量**：压缩比通常 3:1~5:1，但导出瞬间的未压缩临时文件可观，目标盘留足余量。
4. **metadata 别删**：恢复时靠它对版本和位点，也靠它做 PITR 衔接。
5. **版本匹配**：MySQL 8.0 用 mydumper 0.11+，老版本导 8.0 各种坑（数据字典、默认 collation）。新库环境保持工具链最新。

## 小结

mydumper/myloader 是多线程逻辑备份的代表：并行导出 + 一致性快照 + 分文件结构 + 精细过滤，在数据迁移、ETL 抽取、跨版本恢复这些场景是 XtraBackup 的绝配而非替代。生产最佳实践是双轨备份——物理保 RTO、逻辑保灵活，配合 pt-table-checksum 校验和定期恢复演练，备份体系才算闭环。下一篇讲 binlog 闪回——不动备份，把误操作"倒放"回去的技术。
