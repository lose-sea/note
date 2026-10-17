# MySQL SSL 加密复制：证书配置、MASTER_SSL 与传输强制

主从复制跑在裸 TCP 上，binlog 明文穿过机房网络——这个隐患在等保测评里是一条必查项，在真实的攻防演练里也是一条真实的泄露路径：抓包即得全量数据变更。这篇文章把 MySQL 的传输加密讲透：SSL 怎么验证、CA 证书和自签证书两条路线怎么选、`CHANGE MASTER TO` 的加密参数怎么写、怎么指定账号强制走加密、以及加密后性能掉多少、哪些场景可以不加。

## 一、先搞清楚：MySQL 的 SSL 到底加密哪一段

一个常见误解是"开了 SSL 数据库就安全了"。准确地说，MySQL 的 SSL 只保护**客户端/从库到服务端之间的这一段链路**，它的边界是：

| 范围 | SSL 是否覆盖 | 说明 |
|---|---|---|
| 应用 → MySQL 主库连接 | ✅ 覆盖 | 客户端配 `--ssl-mode=REQUIRED` |
| 从库 IO 线程 → 主库连接 | ✅ 覆盖 | `CHANGE MASTER TO ... MASTER_SSL=1` |
| 主库 → 从库的数据流 | ❌ 不覆盖 | 走的是普通 MySQL 协议连接，需要单独加密（同上） |
| 落盘的数据文件、binlog、redo | ❌ 不覆盖 | 那是表空间加密（TDE）的领域 |
| 半同步复制等待 ACK | 随连接 | ACK 走的是与 IO 线程不同的连接，需单独确认加密 |

所以"传输加密"在这个体系里其实是两件事：**客户端连接加密**和**复制链路加密**。两件的配置方法一致，本质都是 MySQL 服务端启用 SSL 支持 + 连接方声明"必须加密"。

## 二、服务端启用 SSL：开机自检两行

MySQL 8.0 默认会自动生成自签证书并启用 SSL，可以用两行确认：

```sql
SHOW VARIABLES LIKE '%ssl%';
SHOW STATUS LIKE 'Ssl_cipher';
```

关键变量：

| 变量 | 含义 | 判断 |
|---|---|---|
| `have_ssl` / `Ssl_cipher` | SSL 是否可用 | `YES` + 有非空 cipher 才说明真的能用 |
| `ssl_ca` | CA 证书路径 | 空 = 只有自签 |
| `ssl_cert` / `ssl_key` | 服务端证书/私钥 | 自签或正式证书都在这里 |
| `tls_version` | 允许的协议版本 | 生产至少 `TLSv1.2,TLSv1.3` |

**第一件事：把 TLS 1.0/1.1 关掉。** 这两个版本有已知漏洞（BEAST、POODLE 变种），PCI-DSS 和等保都已禁用：

```ini
# my.cnf
[mysqld]
tls_version = TLSv1.2,TLSv1.3
```

改完重启，或用 `SET PERSIST tls_version = 'TLSv1.2,TLSv1.3'` 即时生效。

如果 `have_ssl` 是 `DISABLED`（通常是 `ssl=0` 或证书损坏），先查错误日志里有没有 `SSL initialization failed`，再确认 `ssl_cert`/`ssl_key` 路径下文件存在且权限正确。

## 三、证书路线：自签够用，但 CA 更完整

MySQL 传输加密有两类证书方案，选错路线是实施阶段最常见的返工。

### 3.1 自签证书：十分钟搞定，适合内网闭环

适合：主从都在内网、有统一网络层管控、不强制要求证书链校验的场景。MySQL 8.0 装完会在 datadir 下自动生成一套：

```bash
ls /var/lib/mysql/*.pem
#  ca.pem  client-cert.pem  server-cert.pem  private_key.pem  public_key.pem
```

想手动生成一套自签（能完全控制 SAN 和有效期），标准流程：

```bash
mkdir -p /etc/mysql/ssl && cd /etc/mysql/ssl

# 1. CA 私钥与自签名证书
openssl genrsa 2048 > ca-key.pem
openssl req -new -x509 -nodes -days 3650 -key ca-key.pem -out ca.pem \
  -subj "/CN=MySQL_Internal_CA"

# 2. 服务端私钥与证书请求
openssl req -newkey rsa:2048 -days 3650 -nodes -keyout server-key.pem \
  -out server-req.pem -subj "/CN=mysql-master-01"
openssl rsa -in server-key.pem -out server-key.pem

# 3. 用 CA 签服务端证书（SAN 必须写全所有可能的主机名/IP）
openssl x509 -req -in server-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem \
  -set_serial 01 -out server-cert.pem \
  -extfile <(printf "subjectAltName=DNS:mysql-master-01,DNS:mysql-master,IP:10.0.1.10")

# 4. 客户端证书（从库用）
openssl req -newkey rsa:2048 -days 3650 -nodes -keyout client-key.pem \
  -out client-req.pem -subj "/CN=mysql-replica"
openssl rsa -in client-key.pem -out client-key.pem
openssl x509 -req -in client-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem \
  -set_serial 02 -out client-cert.pem
```

几个容易踩的点：

- **SAN（subjectAltName）必须写**。新版本客户端校验证书时看 SAN 不看 CN，漏配 SAN 会导致连接报证书错误。
- `openssl rsa -in ... -out ...` 是把 PKCS#8 格式转成 MySQL 要的 PKCS#1，不转可能加载失败。
- 私钥文件权限收紧到 `600`，属主是 mysql 用户；`/etc/mysql/ssl` 目录 `750`。

配置文件指向它们：

```ini
[mysqld]
ssl_ca   = /etc/mysql/ssl/ca.pem
ssl_cert = /etc/mysql/ssl/server-cert.pem
ssl_key  = /etc/mysql/ssl/server-key.pem
```

### 3.2 CA 签发证书：大规模、跨公网、要双向认证时必选

适合：从库跨机房/跨公网、需要对客户端做双向认证（mTLS）、有统一证书生命周期管理的场景。区别只在证书来源：向公司 CA 或公共 CA 申请，把签发的证书链配到服务端。注意要配**完整链**（含中间 CA），否则客户端验不过。

MySQL 的 SSL 支持多种客户端模式，这是理解"加密有没有真正生效"的关键：

| ssl-mode | 加密 | 验证证书 | 验证主机名 | 适用 |
|---|---|---|---|---|
| `DISABLED` | 否 | 否 | 否 | 明令禁止的场景 |
| `PREFERRED`（默认） | 服务器支持就加密 | 否 | 否 | ⚠️ 有降级风险 |
| `REQUIRED` | 是 | 否 | 否 | 最低生产要求 |
| `VERIFY_CA` | 是 | 是 | 否 | 防中间人 |
| `VERIFY_IDENTITY` | 是 | 是 | 是 | 跨公网最高规格 |

**生产建议：客户端统一 `REQUIRED` 起步，跨公网的链路升到 `VERIFY_CA`/`VERIFY_IDENTITY`。** 特别注意 `PREFERRED` 这个默认值——它意味着服务端证书坏了、被中间设备劫持了，连接会静默退回明文，谁都不知道。这就是为什么不能只依赖客户端自觉。

## 四、复制链路加密：CHANGE MASTER 的正确写法

给复制通道上锁，改的是从库的 `CHANGE MASTER TO`：

```sql
-- 先停 IO 线程再改
STOP REPLICA IO_THREAD;

CHANGE MASTER TO
  MASTER_HOST = '10.0.1.10',
  MASTER_PORT = 3306,
  MASTER_USER = 'repl',
  MASTER_PASSWORD = 'ReplP@ss2026',
  MASTER_AUTO_POSITION = 1,
  MASTER_SSL = 1,
  MASTER_SSL_CA = '/etc/mysql/ssl/ca.pem',
  MASTER_SSL_CERT = '/etc/mysql/ssl/client-cert.pem',
  MASTER_SSL_KEY = '/etc/mysql/ssl/client-key.pem';

START REPLICA IO_THREAD;
```

参数逐个说明：

| 参数 | 作用 | 要点 |
|---|---|---|
| `MASTER_SSL = 1` | 启用加密 | 不加等于没做 |
| `MASTER_SSL_CA` | 校验服务端证书的 CA | 配了才会进入"验证"模式 |
| `MASTER_SSL_CERT` / `MASTER_SSL_KEY` | 客户端证书 | 服务端要求 mTLS 时必填 |
| `MASTER_SSL_VERIFY_SERVER_CERT` | 是否校验主机名 | 跨公网建议 1 |

**加密是否生效，不是看参数，是看状态：**

```sql
SHOW REPLICA STATUS\G
```

关注两个字段：

```
Master_SSL_Allowed: Yes          -- 服务端支持 SSL
Master_SSL_Cipher: AES256-SHA    -- 非空 = 这条连接真的在加密
Replica_IO_State: Waiting for source to send event
```

`Master_SSL_Cipher` 为空但连接正常，说明连接是明文的——参数没生效，这是复盘时唯一可信的判据。

## 五、账号级强制：REQUIRE SSL

链路加密还有一个死角：**主库上某个账号允许明文连接**。上面配的全是"客户端想加密"，而 `REQUIRE SSL` 是服务端说"你不加密就别连"。

```sql
-- 复制账号强制 SSL
ALTER USER 'repl'@'10.0.%' REQUIRE SSL;

-- 更严：要求证书是某个 CA 签的
ALTER USER 'app_ro'@'10.0.%' REQUIRE X509;

-- 最严：指定证书主题（双向强绑定）
ALTER USER 'app_rw'@'10.0.%' REQUIRE SUBJECT '/CN=app-server-01' AND ISSUER '/CN=MySQL_Internal_CA';
```

四个强度等级：

| 子句 | 加密 | 验证书 | 验身份 | 场景 |
|---|---|---|---|---|
| `REQUIRE SSL` | 必须 | 不验证 | 不验证 | 复制账号标配 |
| `REQUIRE X509` | 必须 | 验 | 不限身份 | 内部信任网络 |
| `REQUIRE CIPHER ...` | 必须 | 不验 | 不限 | 限制算法套件 |
| `REQUIRE SUBJECT/ISSUER` | 必须 | 验 | 限定身份 | 金融核心 |

配了 `REQUIRE SSL` 之后，明文连接会被直接拒绝，报错类似"connections using insecure transport are prohibited"。

一条 SQL 找出所有还允许明文连接的账号，这是等保检查的标准动作：

```sql
SELECT user, host, ssl_type
FROM mysql.user
WHERE ssl_type = '' OR ssl_type = 'ANY';
```

`ssl_type` 为空的账号就是裸奔账号。原则上除本地 `root@localhost` 和明确备案的应急账号外，都应该是 `SSL`、`X509` 或 `SPECIFIED`。

服务端还有个全局开关，是最后一道闸：

```sql
SET PERSIST require_secure_transport = ON;
```

打开后**所有**连接必须走 SSL/socket，一把梭。风险是如果还有脚本用明文硬连，会在打开瞬间被踢下线——所以顺序很重要：先 `ALTER USER ... REQUIRE SSL`，观察几天没有认证失败投诉，再开全局开关。

## 六、性能代价与常见顾虑

"加密会不会把复制拖慢"是推行加密时被问最多的问题。实测结论：

- **CPU 开销**：现代 CPU 有 AES-NI 指令集，TLS 加解密的 CPU 开销通常在 3%~8%，瓶颈在系统调用而非算法本身。
- **延迟影响**：同机房内 RTT < 1ms 时几乎无感；跨公网链路 TLS 握手会多一次往返，长连接场景可忽略（复制链路本来就是长连接）。
- **真实瓶颈判定**：加密前先看 `SHOW REPLICA STATUS` 的 `Seconds_Behind_Source` 和主从间的网络质量。复制延迟 90% 的案子是大事务、DDL、从库单线程回放，跟 SSL 没关系。

不需要加密的场景也存在：同机房、网络层有 MACsec/物理隔离、且经过风险评估明确接受的内部链路。但这个判断要写进安全文档，不能口头默认。

## 七、排错手册：配了加密却连不上的五种原因

按出现频率排序：

1. **证书 SAN 没写主机名/IP**。报错多为证书校验失败。解法：重新签证书，把 `subjectAltName` 写上所有连接方使用的主机名和 IP。
2. **证书过期**。报错 `certificate has expired`。自签证书生成时就给 `-days 3650`；建立到期监控（见下）。
3. **私钥权限/格式不对**。错误日志 `Unable to decrypt` 或 `Private key not found`。检查 mysql 用户读权限和 PKCS#1 格式。
4. **中间设备拦截**。SSL 用的还是 3306 端口，但某些负载均衡/L4 设备对加密流量有检测拦截，表现为握手超时。让网络团队看设备日志。
5. **客户端驱动版本太老**。很老的连接器不支持 `TLSv1.2`，升级 Connector/J 或驱动版本。

**证书到期监控**，一条定期任务：用 `openssl x509 -enddate -noout -in server-cert.pem` 拿过期时间，提前 30 天告警。证书过期导致的主从集体断连，是运维事故里非常冤的一类。

## 八、落地清单

把以上内容整理成可执行步骤：

1. 确认 `have_ssl=YES`、`Ssl_cipher` 非空，`tls_version` 收紧到 `TLSv1.2,TLSv1.3`；
2. 决定证书路线：内网自签 + 内部 CA 管理，跨公网走正式 CA；
3. 从库 `CHANGE MASTER TO` 加 `MASTER_SSL=1` 与证书参数，`START REPLICA` 后用 `Master_SSL_Cipher` 验证真加密；
4. 所有远程账号 `REQUIRE SSL`，核心账号升 `REQUIRE X509` 或指定 `SUBJECT`；
5. 扫描 `mysql.user`，清掉 `ssl_type` 为空的裸奔账号；
6. 观察无投诉后开 `require_secure_transport=ON` 全局强制；
7. 登记证书过期时间，30 天预警；
8. 把 `Master_SSL_Cipher` 纳入从库健康检查，为空即告警。

## 九、小结

MySQL 传输加密的要点可以压成三句话：**服务端要支持**（`have_ssl` + TLS 1.2+）、**链路要声明**（`MASTER_SSL=1` / `--ssl-mode=REQUIRED`）、**服务端要强制**（`REQUIRE SSL` + `require_secure_transport=ON`）。三者缺一，"加密"就只是配置文件里的一行摆设。

加密只是链路安全的一环，下一篇我们讲 SQL 注入防御：预编译为什么能根治注入、存储过程会不会更安全、以及应用层该怎么审计动态 SQL。
