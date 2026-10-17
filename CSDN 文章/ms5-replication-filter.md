# 复制过滤：哪些库表同步、哪些不同步，以及它的主从不一致陷阱

"从库不需要同步 binlog 分析库""从库只同步核心业务库，报表库不同步"——复制过滤（Replication Filtering）听起来是个合理的诉求，但它是 MySQL 复制配置里**最容易埋雷**的区域。过滤规则设计不当，轻则从库缺数据、重则 failover 后数据分裂。这篇文章讲过滤的三种路径、通配符规则、以及那些"看起来对"的配置为什么出事。

## 过滤的两条路径：SQL 线程 vs IO 线程

先理清拓扑，参数要配对位置：

```
主库 → binlog dump → 从库 IO 线程 → relay log → 从库 SQL 线程 → 应用
```

过滤可以发生在两个环节：

**IO 侧过滤**（`replicate_do_db` 等旧参数在 5.7 有 bug 的行为暂且不表，正确姿势是在 SQL 线程侧）——binlog 还在传输时就丢弃，省网络传输但**从库的 relay log 不完整**，`SHOW SLAVE STATUS` 的诊断能力打折。

**SQL 侧过滤**（MySQL 8.0 的标准姿势）——relay log 完整，应用时才跳过。诊断时能看完整事件流，出问题可追溯。**生产默认应该用 SQL 侧**。

MySQL 8.0 明确推荐：过滤规则只配 `replicate_wild_do_table` / `replicate_wild_ignore_table`（库表级），IO 侧过滤（`replicate_do_db` 等）因为历史 bug 已被标记 deprecated，行为还和"当前 USE 的库"纠缠不清。

## 核心参数与通配规则

```ini
[mysqld]
# 只同步这些库表
replicate_wild_do_table = biz_db.%
replicate_wild_do_table = log_db.%          -- 多行=多个规则

# 不同步这些库表
replicate_wild_ignore_table = biz_db.tmp_%
```

三个高频组合：

**1. 只同步指定库**：

```ini
replicate_wild_do_table = core.%
```

**2. 同步全部，排除噪音库**：

```ini
replicate_wild_ignore_table = report.%
replicate_wild_ignore_table = tmp.%
```

**3. 库大部分同步、个别大表排除**：

```ini
replicate_wild_do_table = biz.%
replicate_wild_ignore_table = biz.big_log_table
```

规则匹配是"先遇到先用"还是"白名单优先"？**参数的语义**：do 规则有值时，不在 do 列表里的一律跳过（白名单模式）；只有 ignore 规则时，全同步除了 ignore 列表（黑名单模式）。两者同时配：do 列表为基础，ignore 从 do 里再排除——**do + ignore 同时配 = 白名单模式下的额外排除**，不是想象中"先匹配哪个算哪个"。

通配符规则：`%` 匹配任意字符串（含空）、`_` 匹配单字符。`biz_db.order%` 匹配 order、order_item、orders_2025 全部；想精确匹配单表，`biz_db.order_` 这种写法或直接写全名。

## 最大的坑：跨库更新与 USE 上下文

旧版 MySQL 的 `replicate_do_db` 有个臭名昭著的行为：**它匹配的是"当前 USE 的库"，不是"表所属的库"**。

```sql
USE core_db;
UPDATE biz_db.orders SET status = 'PAID' WHERE id = 123;
-- binlog 里记录的库上下文是 core_db，但改的是 biz_db.orders
```

如果从库配了 `replicate_do_db = core_db`，这条 binlog **被同步**（USE 的是 core_db）；如果配的是 `replicate_do_db = biz_db`，**被跳过**——明明改的是 biz_db 的表！这个行为坑过无数团队，8.0 已修复（do_db 也按表所属库匹配），但历史库的配置惯性还在。

**防范手段**：用 `replicate_wild_do_table = core_db.%`（按表名匹配，天然不受 USE 影响）+ `binlog_format = ROW`。ROW 格式下 binlog 记录的是"哪个库哪个表的哪些行"，不依赖 USE 上下文——**这也是 ROW 格式全面替代 STATEMENT 的诸多理由之一**。生产库用 STATEMENT 模式的，现在就该迁移。

## 从库本地查询与过滤的冲突

```ini
# 从库不同步 report 库
replicate_wild_ignore_table = report.%
```

然后有人问："从库上能不能直接查 report 库的本地数据？"——不能，report 库在从库上压根不存在（未创建）。但如果有人**手动在从库上创建了 report 库并写了本地数据**：

- 复制过来的事件里如果有 report 库的，被过滤跳过；
- 从库本地对 report 库的写操作，写进从库自己的 binlog；
- **从库提升为主库后，这些本地数据只存在于旧从库，新集群数据分裂**。

这是从库写本地数据 + 过滤组合出的经典事故。解决办法：

1. **从库 `read_only=ON` + `super_read_only=ON`**（要保留复制账号的写权限用后者）。这是铁律，和过滤无关也要开。
2. 需要在从库本地造数据（测试、ETL），用独立实例，别碰复制链上的从库。

## 过滤与 failover：晋升前必查

过滤最危险的场景不是日常复制，是**failover 时**：

```
主库：core_db + report_db + tmp_db 三库都在写
从库 A：过滤了 report 和 tmp
主库宕机 → 从库 A 提升为主
新集群缺 report_db 的数据 → 依赖 report 库的服务全挂
```

**任何 failover 方案（MHA、Orchestrator）在晋升从库前，必须校验目标从库的过滤规则和主库的一致性**。MHA 的配置里可以配 `check_repl_filter` 做前置检查——开着它，别关。

日常巡检也加一条：

```sql
-- 从库上查当前过滤规则
SHOW SLAVE STATUS\G    -- Replicate_Wild_Do_Table / Replicate_Wild_Ignore_Table 字段
-- 对比主库，规则差异即 failover 风险
```

多从库不同步不同的库（A 同步 core、B 同步 report）看起来"分工明确"，实际上把 failover 变成抽奖——**除全量从库外，特殊过滤从库不该进入 failover 候选集**。

## 监控：过滤导致的不一致怎么发现

过滤造成的数据不一致是静默的——从库复制状态正常、Seconds_Behind 为 0，但数据就是缺。两个监控手段：

**1. 定期 count/checksum 对比**。下篇讲的 pt-table-checksum 是标准工具，按周跑全库、按天跑核心表。

**2. 从库 binlog 事件审计**。ROW 模式下可以抓从库 relay log 里 report 库的事件数：

```bash
# 从库上
mysqlbinlog relay-bin.000010 | grep -c "report_db"   # 应该是 0，非 0 说明过滤没生效
```

第二个办法直击"过滤规则写错了但没人发现"的场景——比如 `replicate_wild_ignore_table = report.%` 写成了 `replcate_...`（拼错，参数名无效直接忽略），规则没生效、从库还在同步 report 库，你以为过滤了，其实没有。**过滤配置上线后必须用事件审计验证一次**，不能看 `SHOW VARIABLES` 有值就完事。

## 配置生效方式与常见错误

```sql
-- MySQL 8.0 支持动态修改复制过滤（5.7 要重启）
STOP SLAVE;
SET GLOBAL replicate_wild_ignore_table = 'report.%';   -- 8.0.22+
START SLAVE;
```

三个常见配置错误：

1. **参数名拼错**。上面说过，无效参数名被静默忽略（有 warning 但没人看），过滤规则形同虚设。改完 `SHOW VARIABLES LIKE 'replicate_wild%'` 逐个核对。
2. **ONLY_FULL_GROUP_BY 之类的 sql_mode 主从不一致**导致的应用错误——不是过滤问题，但和过滤一起配时容易混进来。стати 变量清单主从对齐。
3. **规则加到主库上了**。过滤参数是从库的 my.cnf 配置，配到主库无效（主库不读它）。多实例环境里把配置发错机器的事故年年有。

## 替代方案：不用过滤的分库同步

与其在从库做过滤，更高枕无忧的方案是**业务层就分库**：

- 报表库 report 本身就是主库上的独立库，从库不同步它 → 换成从库只同步需要的库，方案上等价于过滤，但 failover 时"这个从库就是核心业务从库"的语义清晰。
- 大表（biz.big_log_table）的排除需求 → 反方向发展：把大表拆到独立库 log_db，从库同步 biz 不同步 log，一劳永逸。

**过滤是补丁，分库是架构**。补丁能用，但别在架构该出手时拿补丁糊。

## 小结

复制过滤三要素：**用 replicate_wild_do/ignore_table（库表级、走 SQL 侧）、ROW 格式防 USE 上下文陷阱、从库 super_read_only 防本地写**。最大的坑是 failover 时过滤从库缺数据——MHA 开 check_repl_filter，特殊从库不进候选集。过滤配置的验证靠 `SHOW VARIABLES` 核对 + mysqlbinlog 事件审计双保险。能分库解决的别用过滤，架构永远比补丁睡得香。下一篇讲 pt-table-checksum——主从数据一致性的标准校验工具。
