# MySQL 监控告警体系：从"出事才知道"到"事前预警"

数据库事故复盘里最高频的结论不是"缺少某个监控"，而是"有监控但没人收到告警"、"告警收到了但当噪音忽略了"。监控体系的建设分三层：**采什么指标**、**怎么分级告警**、**怎么降低噪音**。这篇文章按这个结构展开 mysqld_exporter + Prometheus + Grafana 这套标准栈的落地方法，覆盖核心指标清单、告警阈值设计、以及哪些指标是真正的"事前信号"。

## 一、指标分层：不是所有数字都值得告警

MySQL 可观测指标分四层，每层的用途完全不同：

| 层 | 指标举例 | 用途 | 告警价值 |
|---|---|---|---|
| **可用层** | 进程存活、端口、主从状态 | 服务是否活着 | 高（但太迟） |
| **负载层** | QPS、TPS、连接数、线程状态 | 压力是否正常 | 中 |
| **资源层** | CPU、内存、磁盘 IO、Buffer Pool 命中 | 资源是否充裕 | 中 |
| **健康层** | 主从延迟、复制错误、锁等待、慢查询突增 | 是否在"变坏" | **高（事前信号）** |

大多数团队只配了前两层——出事时"库挂了"的告警最灵敏，但那时用户已经在投诉了。**真正的价值在健康层**：延迟开始爬、锁等待变多、连接数缓慢上涨，这些信号比"挂掉"早几十分钟到几小时，够你介入处理。

指标采集用 mysqld_exporter：

```yaml
# docker-compose 片段
mysqld-exporter:
  image: prom/mysqld-exporter:v0.15
  environment:
    DATA_SOURCE_NAME: "exporter:密码@(mysql-master:3306)/"
  ports:
    - "9104:9104"
```

`DATA_SOURCE_NAME` 里的账号只需要最小权限（`PROCESS`、`REPLICATION CLIENT`、`SELECT` on `performance_schema`），别用 root。

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'mysql'
    static_configs:
      - targets: ['mysqld-exporter:9104']
```

## 二、核心指标清单：这十二个先配上

上百个指标不可能全看，先建立"最小核心集"，按主库/从库分组：

### 2.1 主库必看

| 指标 | PromQL | 含义 | 说明 |
|---|---|---|---|
| QPS | `rate(mysql_global_status_questions[5m])` | 每秒查询数 | 突降可能是流量跌或连不上 |
| TPS | `rate(mysql_global_status_innodb_rows_inserted[5m]) + ...` | 写入吞吐 | 用 Com_insert/update/delete 算 |
| 活跃连接 | `mysql_global_status_threads_running` | 正在执行的线程 | > CPU 核数持续 5 分钟 = 危险 |
| 连接数 | `mysql_global_status_threads_connected / mysql_global_status_max_connections` | 连接使用率 | > 80% 告警 |
| 连接失败 | `rate(mysql_global_status_aborted_connects[5m])` | 被拒连接 | 突增 = 连接池打满或撞库 |
| 缓冲池命中 | `mysql_global_status_innodb_buffer_pool_read_requests / (...requests + ...reads)` | 读缓存命中率 | < 99% 要关注 |
| 慢查询增量 | `rate(mysql_global_status_slow_queries[5m])` | 慢查询速率 | 突增 = 有 SQL 劣化或数据量变化 |
| 锁等待 | `rate(mysql_global_status_innodb_row_lock_waits[5m])` | 行锁等待次数 | 持续增长 = 有热点行/死锁竞争 |

### 2.2 复制必看

| 指标 | 说明 |
|---|---|
| `mysql_slave_status_seconds_behind_master` | 主从延迟（ slaves 视角） |
| `mysql_slave_status_slave_sql_running_state` | SQL 线程状态（Waiting/executing） |
| `mysql_slave_status_last_sql_error` | 最近复制错误 |

**延迟告警的坑**：`Seconds_Behind_Master` 有大事务时严重失真（主库跑了个 20 分钟的 UPDATE，从库显示延迟 1200 秒，实际只是这一条）。**补充监控**：比较主从的 `Exec_Master_Log_Pos`（心跳位点）或 Pt-Heartbeat 表，比原生延迟字段可靠得多。

### 2.3 系统层

CPU 使用率、内存、磁盘空间（数据盘 < 70% 预警）、磁盘 IO 利用率（`%util > 80%` 持续）、以及 **Buffer Pool 的 `Innodb_buffer_pool_pages_dirty` 比例**（脏页比例突然拉高，预示 checkpoint 压力，是 next-epoch 卡顿的前兆）。

## 三、告警分级：P0 到 P3 的设计

告警的价值 = 及时性 × 准确性，两者靠分级和阈值平衡。建议的分级：

| 级别 | 定义 | 响应 | 示例 |
|---|---|---|---|
| **P0** | 数据服务不可用或数据有损 | 电话/短信，5 分钟响应 | 主库宕机、主从全断、磁盘满 |
| **P1** | 即将不可用或严重劣化 | IM 强提醒，15 分钟响应 | 连接数 > 90%、主从延迟 > 300s 且持续、复制 IO 线程挂 |
| **P2** | 异常趋势，需当天处理 | IM 消息，当天响应 | 慢查询突增 10 倍、Buffer Pool 命中 < 99%、锁等待持续增长 |
| **P3** | 容量预警 | 周报汇总 | 磁盘增长趋势、自增 ID 余量、索引冗余 |

**阈值设计原则**（照抄这套能避开大部分坑）：

1. **动态基线优于固定阈值**。QPS "超过 1000 告警"是错的——大促期间本来就该 5000。用同比/环比（本周此时 vs 上周此时）或 7 日同时段分位数。PromQL 的 `avg_over_time` 和预测函数可以做基线告警。
2. **持续时间门槛**。任何阈值都要配 `for: 5m`——瞬时毛刺不告警。CPU 冲高 5 秒是正常的，持续 5 分钟才是问题。
3. **告警必须带上下文**。告警消息里带：实例名、当前值、阈值、持续时长、Dashboard 链接。只发"连接数过高"四个字，值班的人还得现场查。
4. **一条业务线一个收敛组**。同一个库的所有 P2 告警合并发送，避免一条链路故障引发 20 条告警刷屏。

## 四、降低噪音：告警疲劳是监控体系的头号死因

调研过的大部分团队，告警体系死于"天天响、没人看、索性屏蔽"。三个实战药方：

### 4.1 静默与依赖

- **维护窗口静默**：DDL、批量任务、演练期间 Silence；
- **告警依赖**：从库延迟告警，如果主库已 P0，则从库的告警自动抑制（P0 是根因，其他都是症状）；
- **级联抑制**：网络分区时，成百上千实例不可达，只报"网络层异常"一条，实例级"不可达"静默。

### 4.2 告警要对应明确动作

一个告警如果值班的人不知道"收到后该干什么"，它就不该存在。列出每个告警对应的 SOP 动作：

| 告警 | 动作 |
|---|---|
| 连接数 > 90% | 查 `information_schema.processlist` 是否有堆积 → kill 慢查询 → 扩容连接 |
| 主从延迟 > 300s | 查 `SHOW SLAVE STATUS` SQL 线程状态 → 大事务？并行复制？从库 IO？ |
| 磁盘 < 70% | 预测 7 天打满时间 → 清理策略/扩容 |
| 慢查询突增 | 拉慢日志 → pt-query-digest → 定位新 SQL |

没写进 SOP 的告警，最终都会变成噪音。

### 4.3 定期复盘告警质量

每月看一次：哪些告警响了但不用处理（假阳性）？哪些事故发生了但没有对应告警（盲区）？前者调阈值，后者补告警。**告警清单是活的**，不是配完就结束的。

## 五、Dashboard：三层视图

Grafana Dashboard 别搞成一张大而全的图表墙，按用户分三个：

**1. 总览页（值班室用）**：核心红绿灯——实例数（Up/Down）、主从拓扑状态、连接/线程、复制延迟。一屏看完，任何一项红就能下钻。

**2. 实例详情页（DBA/开发排查）**：单库全指标——QPS/TPS 曲线、Buffer Pool、锁等待、慢查询 Top、临时表使用、IO。`$instance` 变量切换。

**3. 慢查询页（优化用）**：pt-query-digest 定期跑，结果推给 Grafana 的 JSON 数据源，或导出成静态报表贴 Dashboard。慢查询 Top 10 表格 + 趋势曲线。

看板原则：**每张图回答一个问题**，超过一分钟看不完的 Dashboard 等于没有。

## 六、落地路线图

从零建设的推荐顺序：

1. **第一周**：mysqld_exporter + Prometheus + Grafana 基础栈，核心十二指标，P0/P1 告警（宕机、连接满、主从断）；
2. **第二周**：补复制监控和磁盘/系统层，接入值班 IM 机器人；
3. **第一个月**：慢查询看板、锁等待分析、性能基线的建立（把"正常长什么样"量化出来）；
4. **持续**：告警 SOP 化、月度复盘调阈值、业务高峰期专项 Dashboard（大促独立一套）。

## 七、小结

监控告警的三句话：

- **指标分层收集**：可用层报警太迟，健康层（延迟、锁等待、命中率）才是事前信号，慢查询和复制错误是性价比最高的两个切入点；
- **告警分级配 SOP**：P0 电话 P1 强提醒 P2 消息 P3 周报，每个告警必须对应明确动作，配 `for: 5m` 持续时间门槛；
- **降噪比加告警重要**：依赖抑制、维护静默、月度复盘假阳性——告警疲劳会让整套体系在一周内失效。

至此，MySQL 专题（执行计划、索引、优化、锁、事务、高可用、备份恢复、安全、运维调优）全部收尾。下一篇起进入 RAG 检索增强生成的工程实战系列。
