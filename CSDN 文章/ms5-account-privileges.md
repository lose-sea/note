# MySQL 账号权限体系：从 everyone root 到最小权限实践

生产库权限管理失控的典型画面：应用连库用 root、测试连生产用同一个 over-privileged 账号、离职员工的账号还在、`GRANT ALL` 满天飞。出一次事（误删、注入、拖库），损失程度完全由权限体系决定。这篇文章讲 MySQL 权限体系的设计：账号分层、权限最小化、以及落地时的审计机制。

## MySQL 权限的两个层级

**全局权限**（`ON *.*`）：作用于整个实例。

```sql
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%';   -- 万恶之源，排第二
GRANT PROCESS, REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'monitor'@'10.0.0.%';
```

**库/表/列级权限**：

```sql
GRANT SELECT, INSERT, UPDATE ON biz_db.* TO 'app_rw'@'10.0.0.%';
GRANT SELECT (id, name) ON biz_db.customer TO 'app_ro'@'10.0.0.%';   -- 列级
GRANT SELECT ON biz_db.orders TO 'report'@'10.0.0.%';
```

还有三个特殊权限永远单独考量：`GRANT OPTION`（能转授权限，不给）、`SUPER`（8.0 已拆成细粒度动态权限，慎给）、`FILE`（读写服务器文件，约等于 shell）。

**关键认知：MySQL 的权限粒度止步于库表列 + 过程函数触发器级别**，没有行级权限、没有列值过滤（"只看自己的订单"这类要应用层实现）。权限体系是粗粒度防线，细粒度永远靠应用。

## 账号分层设计

生产实例的账号矩阵，按角色划分：

| 角色 | 权限 | 用途 | 来源 |
|---|---|---|---|
| **root/localhost** | ALL | 仅本地应急维护 | 默认 |
| **admin** | ALL + GRANT | DBA 管理，人使用，应用禁用 | 新建 |
| **app_rw** | CRUD on 业务库 | 应用主库连接 | 新建 |
| **app_ro** | SELECT on 业务库 | 应用读库连接 | 新建 |
| **repl** | REPLICATION SLAVE, SLAVE MONITOR | 复制账号 | 新建 |
| **backup** | RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT, BACKUP_ADMIN | XtraBackup/mydumper | 新建 |
| **monitor** | PROCESS, REPLICATION CLIENT, SELECT on mysql 系统库 | 监控采集 | 新建 |
| **etl** | SELECT + 必要写权限 on 指定库 | 数据同步 | 新建 |

创建的标准写法：

```sql
-- 强策略：caching_sha2_password（8.0 默认）
CREATE USER 'app_rw'@'10.0.0.%' IDENTIFIED BY 'xxx' 
    WITH MAX_QUERIES_PER_HOUR 100000 
         MAX_USER_CONNECTIONS 100 
         PASSWORD EXPIRE INTERVAL 90 DAY;

GRANT SELECT, INSERT, UPDATE, DELETE ON biz_db.* TO 'app_rw'@'10.0.0.%';

-- 复制账号：必须 REPLICATION SLAVE 系统权限
CREATE USER 'repl'@'10.0.0.%' IDENTIFIED BY 'yyy';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'10.0.0.%';

FLUSH PRIVILEGES;
```

`@'10.0.0.%'` 是**来源 IP 白名单**——比 `@'%'`（任何 IP）安全一个量级。应用连接固定网段的，配到网段甚至单 IP。**来源限制是被低估的防线**：即使密码泄露，攻击者的机器连不上也白搭。

## 最小权限的三条落地纪律

**纪律一：按功能拆账号，不按"读写"粗分**。

很多团队只配 app_rw 和 app_ro 两个。进一步：ETL 账号、报表账号、消息消费者账号各自独立。某天拖库事件发生时，日志里能分清"是哪个系统的连接干的"——共用账号等于全员共享指纹。

**纪律二：敏感表收紧到列级**。

```sql
-- customer 表的手机号、身份证列，应用主链路只读 id/name/status
GRANT SELECT (id, name, status) ON biz_db.customer TO 'app_rw'@'10.0.0.%';
-- 敏感字段的读取走单独的高权限账号或脱敏视图
CREATE VIEW biz_db.customer_masked AS 
    SELECT id, name, CONCAT(LEFT(phone,3), '****', RIGHT(phone,4)) AS phone FROM customer;
GRANT SELECT ON biz_db.customer_masked TO 'app_ro'@'10.0.0.%';
```

**脱敏视图是低成本高价值的手段**：查敏感数据的入口收窄成视图，视图里做脱敏，泄露面直接砍半。

**纪律三：定期清理**。

离职、项目下线、临时账号——不清理的权限表就是债务。三个自动化点：

```sql
-- 1. 列出所有非 root 超级账号（应该几乎没有）
SELECT user, host FROM mysql.user WHERE Super_priv = 'Y' AND user != 'root';

-- 2. 列出 90 天未使用的账号（需要 performance_schema 或审计插件）
-- 3. 列出密码过期的账号（开了 PASSWORD EXPIRE 的场景）
SELECT user, host, password_expired FROM mysql.user WHERE password_expired = 'Y';
```

## 权限查询与审计

日常审计三张表：

```sql
-- 1. 所有人的完整权限
SHOW GRANTS FOR 'app_rw'@'10.0.0.%';
SELECT * FROM mysql.user WHERE user NOT IN ('mysql.infoschema', ...);   -- 全量用户

-- 2. 谁在连（实时）
SELECT * FROM information_schema.processlist;   -- 或 sys.processlist

-- 3. 谁连过、从哪连（历史）
SELECT * FROM performance_schema.host_cache;    -- 连接来源统计
```

**审计插件（下篇专讲）补上"谁执行了什么"**——权限体系管"能不能做"，审计管"做了什么"，两层都要。

## 典型事故复盘：一个 over-privileged 的代价

真实案例：电商团队所有服务共用 `app_rw`，权限是 `GRANT ALL ON biz_db.*`。某天一个订单服务的接口被注入，攻击者拿到连接串后执行：

```sql
-- 直接删了整个用户表
DROP TABLE biz_db.vip_user;
```

如果当时 vip_user 只对服务账号开放 `SELECT, INSERT, UPDATE`（不需要 DELETE/DROP），这条语句会被权限拒绝；如果再收紧到列级，连"导出全表"都难。**过宽的权限把一次接口注入放大成一次数据灾难**。

事后整改：按服务拆账号、收回 DDL、敏感表列级、连接来源限 IP、审计插件上线。每个措施都不复杂，难的是在没有事故时就有动力做——**权限治理的价值恰好在出事时才兑现**。

## 迁移到 8.0 的动态权限

MySQL 8.0 把 SUPER 拆成 50+ 个动态权限，这是好事——细粒度授权：

```sql
-- 只需要"看主从状态"的监控账号，不用给 SUPER
GRANT SYSTEM_VARIABLES_ADMIN, SESSION_VARIABLES_ADMIN ON *.* TO 'monitor'@'%';
-- 需要 kill 连接的运维脚本账号
GRANT CONNECTION_ADMIN ON *.* TO 'ops'@'10.0.0.%';
```

升级路径上，逐个审 old SUPER 账号的实际用途，替换成最小动态权限组合。这个工作没有捷径，只能一个账号一个账号过。

## 小结

MySQL 权限管理的核心是分层与最小化：应用、复制、备份、监控、ETL 各用独立账号，来源 IP 限制，库表列三级授权，敏感数据走脱敏视图，SUPER 和 FILE 单独审批。定期清理 + host_cache/审计插件是治理闭环。权限体系防不住 SQL 注入（那是下篇的事），但它决定注入的危害上限——**把每个账号的能力圈划到"完成本职工作所需的最小集合"，是 DBA 能做的最划算的安全投资**。
