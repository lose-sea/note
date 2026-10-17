# pt-table-checksum：主从数据一致性的标准校验工具

复制链路跑着，Slave_IO_Running 和 Slave_SQL_Running 都是 Yes，Seconds_Behind_Master = 0——从库就真的和主库一致吗？不一定。复制过滤器漏配、DBA 手滑在从库写了一条 UPDATE、`sql_slave_skip_counter` 跳过一个含业务数据的事务——这些 silent divergence 复制状态全绿，数据却在悄悄分裂。pt-table-checksum 就是检测这种分裂的标准武器。这篇文章讲它的原理、使用姿势和修复流程。

## 工作原理：在线分块 checksum

pt-table-checksum 的思路极其优雅：**在主库上对每张表分块计算 CRC 校验和，把这个"计算动作"通过复制传到从库执行，从库算出同样的 checksum，两边一比，不一致的块就是分裂数据。**

```bash
pt-table-checksum --nocheck-repl-filters \
    --replicate=percona.checksums \
    --databases=biz_db \
    h=master_user,p=master_pass,P=3306
```

内部流程：

```
主库：把 orders 表按主键切成 N 个 chunk（每 chunk 默认 1000 行）
主库：INSERT 一个 checksum 记录到 percona.checksums 表（含 chunk 范围和待计算要求）
复制：这个 INSERT 流到所有从库
从库：SQL 线程执行时触发"对同范围数据做 checksum 计算"（依赖一个存储函数）
从库：把算出的 this_cnt/this_crc UPDATE 到 percona.checksums 表
主库：pt 工具读回结果，对比主库 chunk 的 crc 和从库的 crc
```

关键设计：**checksum 的计算请求是"搭车"在复制链路里的**——主库算一份、从库算一份，天然同步比。工具本身不碰从库连接也能完成校验，只读主库 + 等复制回流。

## 前置检查：三个必须确认的条件

**1. 工具在从库上也装了**（或至少 checksum 存储过程在）。pt-table-checksum 从 3.x 起会在主库自动创建 `percona.checksums` 表和相关函数，这些 DDL 通过复制到从库——**从库必须允许创建（不能被复制过滤拦住）**。

```bash
# 典型翻车现场：从库配了 replicate_wild_ignore_table 排除了某库，
# percona.checksums 的创建被过滤 → 校验跑不起来或结果缺失
pt-table-checksum --nocheck-repl-filters   # 加这个跳过检查强行跑，但心里要清楚自己在干嘛
```

**2. 主库的 binlog 是 ROW 格式**（或至少 STATEMENT 下 SQL 确定）。ROW 格式下 checksum 事件原样复制；STATEMENT 下如果 checksum 逻辑依赖 NOW() 或随机值会失配。生产库默认都该是 ROW，这不是问题但值得确认。

**3. 主库账号有权限**：PROCESS、REPLICATION SLAVE、REPLICATION CLIENT、SELECT、INSERT/UPDATE/CREATE on percona.*。复制账号单独跑的话权限最小集要配全。

## 跑起来：实战节奏

### 第一次全库校验

```bash
pt-table-checksum h=master,p=pass \
    --replicate=percona.checksums \
    --ignore-databases=mysql,sys,percona \
    --chunk-time=1 \
    --max-load=Threads_running=50 \
    --check-interval=2
```

`--max-load` 和 `--check-interval` 是保命参数：**checksum 是真实负载**，大表分块 CRC8 计算在主库上跑，直接压 CPU 和 IO。主库繁忙时它会自己暂停（`Threads_running` 超阈值时 sleep），生产环境必须配。选业务低峰期跑全量，白天跑只查核心表。

### 结果解读

```bash
# 校验完看报告
pt-table-checksum --replicate=percona.checksums h=master,p=pass --replicate-check-only
```

或者直接查库：

```sql
SELECT db, tbl, chunk, chunk_index, 
       master_cnt, master_crc, this_cnt, this_crc
FROM percona.checksums
WHERE master_crc <> this_crc OR this_cnt <> master_cnt;   -- 抓差异行
```

字段含义：

- `ts`：checksum 完成时间戳。
- `chunk`：主键范围（"1=1000"、"1001=2000"）。
- `master_cnt` / `master_crc`：主库这块的行数和 CRC。
- `this_cnt` / `this_crc`：从库对应块的行数和 CRC。
- `ts` 之后从库没 UPDATE 的：从库延迟，重跑。

**空结果 = 完全一致**。有差异行就是分裂实锤，定位到具体表和 chunk 范围。

### 持续校验

生产不该只跑一次：

```bash
# 每天定时跑核心表（低峰）
pt-table-checksum h=master,p=pass --replicate=percona.checksums \
    --databases=biz_db --tables=orders,order_item,payment \
    --chunk-size=500
# 结果进 percona.checksums，配合告警规则：新差异行即告警
```

## 发现分裂后的修复流程

checksum 只能发现问题，修复要单独做。按分裂原因分三类：

**原因一：从库被手写**（DBA 在从库执行了不该执行的 UPDATE/DELETE）。修复方向是把从库改回主库的样子：

```bash
# 用 pt-table-sync 直接修复从库（精确到行）
pt-table-sync --replicate=percona.checksums h=master,p=pass h=slave,p=pass \
    --databases=biz_db --tables=orders \
    --print              # 先看会改什么
pt-table-sync ... --execute   # 确认后执行
```

`--print` 到 `--execute` 的纪律不能省——sync 是会改数据的操作，打屏看一眼差异 SQL 再执行。pt-table-sync 和 checksum 共用 `--replicate` 表，直接读 checksum 结果定位差异行，增量修复最小化影响。

**原因二：复制跳过/丢事件**（`sql_slave_skip_counter`、并行复制丢事件、GTID 空事务注入）。修复方向是**补事件**而不是改从库：确认跳过的 GTID 在主库还在 binlog 里，重新执行该事务。如果 binlog 已清理，只能补数据（从主库 dump 差异行覆盖）。

**原因三：过滤规则问题**（从库同步策略漏了本该同步的数据）。修复是调过滤规则 + 让漏掉的数据补同步，然后重跑 checksum 验证跟随。

**通用铁律：修复后必须重跑 checksum 确认归零**，且分裂期间写入的数据可能已经扩散（从库缺的行后续关联操作也可能缺或错位）——重度分裂场景，重建从库往往比修更快：重新 CHANGE MASTER + MASTER_AUTO_POSITION，拉一份新的。

## 性能与影响评估

checksum 不是零成本的：

- **主库计算开销**：CRC32 是 CPU 活，大表全量跑一轮，繁忙实例上能看到 CPU 上涨几个点。低峰期 + `--max-load` 限流是标配。
- **从库上 checksum 表的数据量**：每 chunk 一行记录，大表可能几万行。定期清理：

```sql
DELETE FROM percona.checksums WHERE ts < NOW() - INTERVAL 7 DAY;
```

- **不等长主从的坑**：如果从库有 filter 排除了某些 chunk 的行，checksum 会对不上——这不是分裂，是架构差异。这时要么比时排除差异表，要么用 `--replicate-check-only` 结合人工分析。**校验前从库过滤清单要清楚**，不然告警天天误报。

## 现代替代与补充

pt-table-checksum 的地位无可替代，但两个新情况值得知道：

1. **MySQL 8.0.27+ 官方没有内建等价工具**，社区方案还是 pt 系最成熟。Percona Server 有增强版校验，但社区版用 pt-table-checksum 是事实标准。
2. **逻辑校验的补充**：checksum 比的是原始数据，有些业务场景要校验"派生一致性"（如汇总表和明细表对账）——那是业务对账系统的活，checksum 管底层分裂。两层都要。

## 小结

pt-table-checksum 的机制是"checksum 请求搭复制链路的车"：主库算一份、从库算一份、自动对比，`percona.checksums` 表 holding 结果。使用纪律：低峰期跑、`--max-load` 限流、过滤规则提前对齐防误报。分裂修复用 pt-table-sync 精准补行，修复后重跑校验归零才算完。复制全绿不等于数据一致，**周期性 checksum 是主从架构里唯一可信的"数据层心跳"**。下一篇讲高可用架构：MHA 与 Orchestrator 的选型与实操。
