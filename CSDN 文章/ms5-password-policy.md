# MySQL 密码策略实战：validate_password、有效期与双密码轮换

生产库被一顿彩虹表暴力破解，是很多 DBA 职业生涯里最不愿意回忆的一个晚上。入侵者不需要 0day，只需要你的 `root` 密码还停留在安装时的默认值，或者全库几十个账号共用一个弱口令。这篇文章把 MySQL 的账号密码安全体系完整拆开：`validate_password` 组件怎么配、密码有效期怎么设、双密码怎么平滑轮换、连接失败锁定怎么开，以及一套能直接落地的生产检查清单。

## 一、先看清楚：MySQL 的密码防线有四层

很多教程只讲了第一层，导致生产环境看起来"设了强密码"却依然出事。完整的防线其实是四层：

| 层级 | 手段 | 防的是什么 | MySQL 对应能力 |
|---|---|---|---|
| 第一层 | 密码复杂度 | 弱口令、字典攻击 | `validate_password` 组件 |
| 第二层 | 密码有效期 | 密码长期不换、离职员工还记得旧密码 | `default_password_lifetime` |
| 第三层 | 失败锁定 | 在线暴力破解、撞库 | `FAILED_LOGIN_ATTEMPTS` + `Connection_control` 插件 |
| 第四层 | 网络层暴露面 | 端口暴露、明文传输 | bind-address、SSL、防火墙 |

四层是"与"关系，不是"或"关系。只做第一层，挡不住长期有效的旧密码；只做第三层，锁得住爆破但锁不住你本来就设成的 `123456`。

## 二、validate_password：把弱口令挡在建号那一刻

`validate_password` 是 MySQL 5.7 以后内置的组件（插件），安装后所有 `CREATE USER` / `ALTER USER` / `SET PASSWORD` 都会经过策略校验。它的价值在于**前移**：在密码写入 `mysql.user` 表之前就拒绝，而不是等被爆破后才在慢日志里后悔。

### 2.1 安装与确认

```sql
-- 查看组件是否已安装
SELECT * FROM mysql.component;

-- 安装（MySQL 8.0）
INSTALL COMPONENT 'file://component_validate_password';

-- 查看当前策略参数
SHOW VARIABLES LIKE 'validate_password%';
```

安装后能看到这样一组参数：

```
validate_password.changed_characters_percentage   0
validate_password.check_dictionary_name           <空>
validate_password.check_user_name                 ON
validate_password.dictionary_file                 <空>
validate_password.length                          8
validate_password.mixed_case_count                1
validate_password.number_count                    1
validate_password.policy                          MEDIUM
validate_password.special_char_count              1
```

### 2.2 三个策略等级怎么选

`validate_password.policy` 有三个值，强度递增：

| 策略 | 长度要求 | 数字 | 大小写 | 特殊字符 | 适用 |
|---|---|---|---|---|---|
| `LOW` | 仅 length | 不要求 | 不要求 | 不要求 | 只测开发环境 |
| `MEDIUM` | ≥ length | ≥ number_count | ≥ mixed_case_count | ≥ special_char_count | 生产默认 |
| `STRONG` | ≥ length | 同上 + 字典文件校验 | 同上 | 同上 | 金融、核心账务 |

生产建议：先用 `MEDIUM` 把长度拉到 12，再视合规要求升 `STRONG`。直接上 `STRONG` 而不同步改造发布系统（CI 里建测试账号）会把自动化流程全打断——这是切换策略时最常见的坑。

```sql
-- 生产推荐组合
SET PERSIST validate_password.policy = MEDIUM;
SET PERSIST validate_password.length = 12;
SET PERSIST validate_password.number_count = 1;
SET PERSIST validate_password.mixed_case_count = 1;
SET PERSIST validate_password.special_char_count = 1;
SET PERSIST validate_password.check_user_name = ON;
```

注意用 `SET PERSIST` 而不是 `SET GLOBAL`：前者写进 `mysqld-auto.cnf`，重启后依然生效；后者重启即丢，半夜一次计划内重启就能让你的密码策略悄悄消失。

### 2.3 拒绝效果实测

配好后随便建一个号试试：

```sql
CREATE USER 'test01'@'%' IDENTIFIED BY '123456';
-- ERROR 1819 (HY000): Your password does not satisfy the current policy requirements

CREATE USER 'test01'@'%' IDENTIFIED BY 'Abcd@12345678';
-- Query OK, 0 rows affected
```

第二条能过：长度 12、有大写有小写、有数字、有特殊字符，且不包含用户名。**这就是策略的意义——它不依赖人的自觉性，把规则固化在数据库层。**

### 2.4 字典文件：STRONG 模式的最后一道闸

```sql
SET PERSIST validate_password.dictionary_file = '/etc/mysql/pwd_dict.txt';
SET PERSIST validate_password.policy = STRONG;
```

`pwd_dict.txt` 每行一个词，比如 `password`、`mysql`、`qwerty`、公司名、常见生日模式。密码只要包含字典中的子串（不区分大小写）就会被拒。文件不需要排序，但要注意编码必须是 UTF-8 或 ASCII。

**实践建议**：字典文件要定期更新。把每次安全审计中发现的员工真实使用过的弱口令脱敏后收进去，这个列表会越来越贴近你们的实际风险。

### 2.5 已存在的存量弱密码怎么办

`validate_password` 只管新密码，不改旧密码。对存量账号要做一次全库体检：

```sql
SELECT user, host,
       LENGTH(authentication_string) AS pwd_len,
       password_lifetime,
       account_locked,
       password_expired
FROM mysql.user
ORDER BY pwd_len;
```

`authentication_string` 是哈希，看不出原文强弱，但**长度异常短**的（比如老版本 `mysql_old_password` 是 16 位十六进制）基本可判定为遗留格式。结合应用侧清单逐个清理：停用的删，还要用的强制改。

## 三、密码有效期与双密码：轮换不打断业务

### 3.1 全局与账号两级有效期

```sql
-- 全局默认：180 天过期（0 表示永不过期）
SET PERSIST default_password_lifetime = 180;

-- 单账号覆盖：核心账号 90 天
ALTER USER 'app_rw'@'10.0.%' PASSWORD EXPIRE INTERVAL 90 DAY;

-- 永不过期（只给明确的应急账号，且要登记）
ALTER USER 'breakglass'@'localhost' PASSWORD EXPIRE NEVER;
```

密码过期后账号**不会立刻断开已有连接**，但会在下次登录时被拒绝，进入"沙箱模式"——只能改密码，干不了别的。这对长连接应用是个隐患：连接池里的连接如果长期不重连，某天集中过期会造成一波同时失败。

两个规避手段：

1. 打开连接池的 `maxLifetime`，让它短于密码有效期，保证连接会周期性重建；
2. 给应用账号设置 `PASSWORD EXPIRE` 的同时，在监控里加一条"多少天内即将过期"的预警，提前批量改。

### 3.2 双密码：改密不断业务的唯一正解

直接 `ALTER USER ... IDENTIFIED BY '新密码'` 会把旧密码作废。如果应用有多个实例、发布有先后，先改的实例用新密码、没改的实例用旧密码，中间窗口期必然有一批连接失败。

MySQL 8.0.14 起支持双密码，正是为解决这个场景：

```sql
-- 保留旧密码的同时添加新密码
ALTER USER 'app_rw'@'10.0.%' IDENTIFIED BY 'NewP@ssw0rd2026' RETAIN CURRENT PASSWORD;
```

这条语句执行后，新旧两个密码都能登录。然后按发布节奏滚动应用：

1. 第一批实例改用新密码发布；
2. 观察连接数稳定、无认证失败；
3. 剩余实例全部切换完成；
4. 确认旧密码无人使用后，丢弃它：

```sql
ALTER USER 'app_rw'@'10.0.%' DISCARD OLD PASSWORD;
```

`RETAIN CURRENT PASSWORD` / `DISCARD OLD PASSWORD` 这两个子句是生产改密的标准动作，建议写进运维 SOP。配套一条检查语句确认当前有几重密码：

```sql
SELECT user, host,
       (authentication_string NOT LIKE CONCAT('$', SUBSTRING_INDEX(authentication_string,'$',2), '%')
        OR authentication_string LIKE '%$%$%') 
FROM mysql.user;
```

更可靠的判断是看 `mysql.user` 的 `User_attributes` JSON 里是否有 `additional_password` 字段（不同版本字段位置有差异，以官方文档为准）。

### 3.3 密码改到哪里去：接入密钥管理系统

明文密码写在部署脚本、Ansible 变量、K8s Secret 里，都是下一个事故的种子。规范做法：

- 开发/测试环境：Vault、SOPS 之类的密钥管理，或至少 K8s Secret + RBAC 限制读取权限；
- CI/CD：从密钥平台动态取，禁止打进镜像层；
- 应急账号 `breakglass`：纸质或密码柜封存，使用时双人复核，用后即改。

判断标准很简单：**任何一个能登录生产库的人，都不应该在企业微信里直接收到生产密码。**

## 四、失败登录锁定：让爆破无利可图

`validate_password` 保证密码本身难猜，`FAILED_LOGIN_ATTEMPTS` 保证"猜"这个动作代价极高。

### 4.1 账号级锁定（推荐）

MySQL 8.0 起 `CREATE USER` / `ALTER USER` 原生支持：

```sql
ALTER USER 'app_rw'@'10.0.%' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 2;
```

含义：连续 5 次登录失败，锁定 2 天。解锁方式：

```sql
ALTER USER 'app_rw'@'10.0.%' ACCOUNT UNLOCK;
```

这个机制的巧妙之处是**锁的是账号不是 IP**。攻击者换 IP 也没用，而合法用户被锁后找 DBA 解锁的成本很低（且解锁动作本身会被记录）。

`PASSWORD_LOCK_TIME` 的单位是天，可以写小数（如 `0.5` 表示 12 小时）。生产建议：

| 账号类型 | FAILED_LOGIN_ATTEMPTS | PASSWORD_LOCK_TIME |
|---|---|---|
| 应用账号 | 5 | 1 |
| 管理账号 | 3 | 2 |
| 公网可达的对外账号 | 3 | 3 |

### 4.2 全局连接控制（兜底）

如果实例里账号太多、来不及逐个配，可以用 `CONNECTION_CONTROL` 插件做全局响应延迟：

```sql
INSTALL PLUGIN connection_control SONAME 'connection_control.so';
SET PERSIST connection_control_failed_login_threshold = 3;
SET PERSIST connection_control_min_connection_delay = 180000;  -- 毫秒
```

效果是连续失败后，后续每次连接响应都要等 180 秒。它不锁账号，只让爆破变得极其缓慢。这个插件适合作为账号级锁定之外的兜底，不适合替代它——180 秒延迟对攻击者来说只是慢，不是停。

### 4.3 监控怎么配

锁定机制要配合告警才有意义：

```sql
SHOW GLOBAL STATUS LIKE 'Connection_errors_authentication';
```

这个值持续增长说明有人在刷认证。另外 `performance_schema` 里能看锁定状态：

```sql
SELECT user, host, account_locked, password_expired
FROM mysql.user WHERE account_locked = 'Y';
```

**告警规则建议**：`Connection_errors_authentication` 每分钟增量 > 10 触发 P2 告警；出现 `account_locked = 'Y'` 的账号触发 P3 告警（可能是攻击，也可能是运维改密漏改了一台机器）。

## 五、发布系统改造：切换策略前的兼容清单

给一个已经在跑的系统加强密码策略，最怕的是把自动化流程打断。切换前按这张表自查：

| 检查项 | 动作 |
|---|---|
| CI 里建测试账号的语句 | 同步换成符合新策略的密码 |
| 部署脚本中的 `ALTER USER` | 检查是否有硬编码弱密码 |
| 连接池配置模板 | 确认 `maxLifetime` 短于密码有效期 |
| 探活/监控账号 | 优先纳入新策略，它们最常被遗忘 |
| 应急账号 | 单独登记，不要被自动改密流程扫到 |
| 应用报错处理 | 认证失败要有明确告警，不要静默重试耗尽连接 |

切换顺序也有讲究：先在预发环境全量验证一周，再生产按"先管理账号、再应用账号、最后探活账号"的节奏推进。每批之间留观察期，出问题能快速定位是哪一刀切下去的。

## 六、一张生产检查清单

把上面所有内容收拢成可执行的清单，建议每季度过一遍：

1. `validate_password` 组件已安装且为 `SET PERSIST` 配置；
2. 策略等级 ≥ MEDIUM，长度 ≥ 12，开启 `check_user_name`；
3. 核心系统启用 `STRONG` + 字典文件；
4. `default_password_lifetime` ≤ 180 天，核心账号单独缩短；
5. 所有账号配了 `FAILED_LOGIN_ATTEMPTS` ≤ 5；
6. `mysql.user` 中无空密码账号、无残留测试账号；
7. 改密 SOP 走双密码滚动流程，禁用直接 `ALTER USER` 覆盖；
8. 密码统一入密钥管理，无明文散落在脚本里；
9. `Connection_errors_authentication` 增长有告警；
10. 每季度做一次弱口令扫描与离职员工账号回收。

## 七、小结

MySQL 的密码安全是一个体系，不是一条 `CREATE USER`：

- **复杂度**靠 `validate_password` 前移到建号时刻，用 `SET PERSIST` 保证重启不丢；
- **有效期**用两级 `INTERVAL` 管理，改密走 `RETAIN CURRENT PASSWORD` 双密码滚动，避免打断业务；
- **防爆破**用 `FAILED_LOGIN_ATTEMPTS` 锁账号，`CONNECTION_CONTROL` 插件做全局兜底；
- **暴露面**收敛靠 bind-address、SSL 和防火墙，这是另一篇文章的主题。

把这四层都补齐，一次"今晚的暴力破解"就只是一条告警，而不是一次事故。下一篇我们讲 SSL 加密复制：怎么给主从之间的 binlog 传输上锁，以及自签证书和 CA 证书两种方案的区别。
