# MySQL 审计插件实战：server_audit 安装配置与日志分析

等保测评现场，测评机构问："请提供数据库中所有管理员的操作记录，证明谁能查到客户手机号。"如果你只能打开 general_log——那个平时都不敢开、开了就掉性能的开关——这场对话会很尴尬。MySQL 社区版没有内置审计，但有一套成熟的外部插件方案。这篇文章把审计这条线讲全：等保到底要求什么、三类方案怎么选、`server_audit` 插件怎么装怎么配、日志长什么样怎么解析、以及审计本身的性能代价和落地检查清单。

## 一、先对齐需求：等保要的"审计"是什么

等保（等级保护）对数据库审计的要求，落到技术上是四个能力：

| 能力 | 具体含义 |
|---|---|
| 记录 | 用户登录、登出、查询、变更、授权操作，都要有记录 |
| 防篡改 | 审计记录不能随便被删改 |
| 可分析 | 能按用户、时间、操作类型检索 |
| 告警 | 高危操作（删库、改权限、批量导出）能及时发现 |

注意最后一层"告警"——只落盘不算完结，得有消费。很多系统配了审计但从没人看过日志，等于没配。

MySQL 社区版自带的三个手段各有短板：

| 手段 | 问题 |
|---|---|
| `general_log` | 全量记所有语句，量大到不可持续，且没有结构化字段 |
| `slow_log` | 只记慢查询，覆盖不了 SELECT 和登录事件 |
| binlog | 只记数据变更，不记查询和 DDL 授权操作 |

结论很明确：**生产审计要用专业插件或外部方案**。下面按落地难度排序讲三类。

## 二、方案一：server_audit 插件（社区版首选）

这是 MariaDB 贡献给社区的审计插件，Percona Server / MariaDB 原生自带，MySQL 社区版可以装 Percona 编译的版本。它是目前社区生态里最成熟的 MySQL 审计方案。

### 2.1 安装

Percona Server 的包里有现成 `.so`：

```sql
INSTALL PLUGIN SERVER_AUDIT SONAME 'server_audit.so';
SHOW VARIABLES LIKE 'server_audit%';
```

变量一览（部分）：

```
server_audit_output_type    file        -- file / syslog / null（只测不落盘）
server_audit_logging        ON          -- 总开关
server_audit_events         connect,query,table              -- 记哪些事件
server_audit_file_path      /var/log/mysql/server_audit.log
server_audit_file_rotations 6           -- 轮转保留份数
server_audit_incl_users     （空）       -- 只记这些用户
server_audit_excl_users     （空）       -- 排除这些用户
server_audit_query_log_limit 1024       -- 单条语句记录长度上限
```

关键决策：**记什么**。`server_audit_events` 的常用组合：

- `connect`：客户端连接建立/断开（含来源 IP、账号）
- `query`：所有执行的语句（包括 SELECT）
- `table`：表被访问时记一条（比 query 更适合"谁动了客户表"这类问题）
- 其他：`quit`、`failed_login`、`grant`、`revoke`、`ddl`……

生产建议组合：`connect,query,table`。如果只要"登录和数据访问"，可以砍掉 `query` 只留 `connect,table,failed_login`，日志量能降一个数量级。

**写放大提醒**：`query` + `table` 同时开，一条 `SELECT * FROM t_order` 会产生 query 一条 + table 一条。高 QPS 系统要评估 IO。折中方案是只开 `table`，它天然记录了每条语句触及的表，且比 query 更省。

### 2.2 日志长什么样

audit 日志是 JSON 数组，每行一个事件：

```json
{"audit_record":{"name":"Query","record":"1_2026-10-16T14:23:11","timestamp":"2026-10-16T14:23:11","command_class":"select","connection_id":"33","status":0,"user":"app_web@app01 (10.0.2.15)","os_login":"","host":"","ip":"10.0.2.15","db":"bizdb","table":"t_order","sqltext":"SELECT * FROM t_order WHERE user_id = 10086"}}
```

关键字段：

| 字段 | 用途 |
|---|---|
| `name` | 事件类型（Query / Connect / Quit） |
| `command_class` | select / insert / update / drop / grant…… |
| `user` / `ip` / `db` / `table` | **四个检索维度**，安全分析就靠它们 |
| `sqltext` | 被截断到 `query_log_limit` 的语句 |
| `status` | 0 = 成功 |

### 2.3 常用分析姿势

```bash
# 1. 谁查过客户表（按 table 字段过滤）
grep '"table":"t_customer"' server_audit.log | jq -r '.audit_record | [.timestamp,.user,.ip,.sqltext] | @tsv'

# 2. 失败登录（撞库/密码错误）
grep '"name":"FailedLogin"' server_audit.log | jq -r '.audit_record.ip' | sort | uniq -c | sort -rn

# 3. 高危 DDL/DCL 操作
grep -E '"command_class":"(drop|alter|grant|create_user|delete)"' server_audit.log

# 4. 非工作时间的数据导出
jq -r 'select(.audit_record.command_class=="select" and (.audit_record.sqltext | contains("INTO OUTFILE")))' server_audit.log
```

配好 `jq`，审计日志就从"躺平的文件"变成能回答安全问题的工具。**这些都是事后排查；要变成实时告警，需要用 Filebeat/Logstash 把日志送进 SIEM，配规则：夜间全表 SELECT、批量 DELETE、`GRANT` 语句即触发。**

### 2.4 权限与防篡改

审计日志文件归 mysql 用户，普通应用账号删不掉——这是防篡改的第一层。更进一步：

- 日志目录独立磁盘/挂载点，防打满影响主库（`server_audit_file_rotations` + logrotate 双保险）；
- 日志外发到远程 syslog（`server_audit_output_type = syslog`），本地只留缓存，实现**日志不出机**的抵赖面；
- 定期把 `.log` 归档转存到只写存储（S3 Object Lock / WORM），保留 6 个月以上（等保二级要求不少于 6 个月）。

## 三、方案二：MySQL Enterprise Audit

Oracle 官方的商业版插件，随 MySQL企业版提供。社区版有两个变通：

1. `audit_log` 插件在 MySQL 8.0 企业版默认包含；
2. 社区版用户常用 MariaDB 的 `server_audit` 替代（即方案一）。

企业版的优势是 XML/JSON 双格式、压缩、内置过滤规则、和 Oracle 生态集成；劣势是要钱、要企业版订阅。**中小团队直接用 server_audit 就行，功能覆盖等保 90% 的要求。**

社区版还有一个常被提到的 `mcafee` 审计插件，早已停止维护，不建议新部署，看到老教程还在教的直接跳过。

## 四、方案三：外部型——proxy 层与网络采集

除了数据库内部插件，还有两类外部方案，适合"不许在生产库装插件"的场景：

**1. 数据库中间件/代理审计**

MaxScale（MariaDB 官方）、MySQL Router、或自研 proxy，在代理层记录所有流经的 SQL。优点：不动生产库；缺点：只有走代理的连接能记到，直连的漏掉；延迟增加一跳。

**2. 网络流量审计**

镜像流量用 DNS/probe 解析 MySQL 协议。优点：对数据库零侵入；缺点：加密流量（SSL）解不了，走 SSL 的生产库基本作废；解析有线宽限制。

这两类是补充，不是主力。**主力仍然是插件方案**：贴近数据库、协议级解析、能拿到 user/db/table 字段。

## 五、性能与容量：开审计前先算这笔账

审计的开销分两块：**生成开销**和**存储开销**。

生成开销实测经验值（同样硬件，TPCC 类负载）：

| 配置 | QPS 影响 | 说明 |
|---|---|---|
| `server_audit_logging=OFF` | 基准 | |
| `connect,table` | ~1-2% | 可接受 |
| `connect,query,table` | ~5-15% | 高 QPS 系统需评估 |
| `server_audit_output_type=syslog` 远程 | 再加网络抖动 | 远程 syslog 阻塞会反噬写入 |

存储开销估算公式：

```
日志量/天 ≈ QPS × 24×3600 × 平均每条记录字节数(约300B) × 开的事件数
```

举例：5000 QPS、开 `connect,query,table`，粗算 `5000 × 86400 × 300B × 2 ≈ 260GB/天`——这显然不可持续。所以要**分级**：

| 库类型 | 审计配置 |
|---|---|
| 核心账务库 | 全开 + 远程归档，保留 180 天 |
| 普通业务库 | `connect,table,failed_login`，保留 90 天 |
| 只读从库/测试库 | 关闭 |

**按库分级、按用户过滤**：`server_audit_excl_users` 可以把监控账号、备份账号（`xtrabackup`、`mysqldump`）这些"自己人"的高频操作排除，日志量立刻降 70%——备份账号一天能刷几百万条。用 `incl_users` 反向只记管理员账号也是常用手法（`server_audit_incl_users = root,admin`），适合安全视角"只盯管理员"。

## 六、落地检查清单

1. 明确等保等级对应的留存期限（二级 6 个月、三级及以上按测评要求延长）与审计范围；
2. 确认版本路线：Percona/MariaDB 装 `server_audit`；企业版评估 Enterprise Audit；
3. 按库分级配置 `server_audit_events`，核心库全开、普通库精简；
4. `excl_users` 排除备份、监控等高频账号；`incl_users` 覆盖所有管理员账号；
5. 日志轮转 + logrotate + 独立挂载点，防打满；
6. 送 SIEM/日志平台，配高危规则告警（删表、改权限、夜间批量 SELECT、OUTFILE）；
7. 每季度做一次审计自查：翻一周日志，验证记录确实完整（连一次、查一次、断一次，核对三条记录都在）；
8. 变更管理：审计配置变更（尤其是关闭）要走审批，防止被顺手关掉。

## 七、小结

MySQL 审计的三句话总结：

- **要专业方案**：general_log / slow_log / binlog 都不能替代审计，生产用 `server_audit` 插件（社区版）或企业版 Enterprise Audit；
- **检索靠四个字段**：`user` / `ip` / `db` / `table`，分析问题、写告警规则都围绕它们；
- **分级 + 过滤才能可持续**：按库分等级开事件，用 `excl_users` 排掉备份监控账号，日志量才可控。

下一篇是 ms5-7 的最后一篇，讲 utf8mb4 改造：历史库为什么从 utf8 迁到 utf8mb4、索引长度限制怎么破、改造期怎么灰度不翻车。
