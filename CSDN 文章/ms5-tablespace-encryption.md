# MySQL InnoDB 表空间加密实战：keyring、master key 与轮换

备份文件被人拷走、云盘快照被误分享、硬盘拿去报修——这些场景下，数据没丢但"没了"。TDE（透明数据加密）就是对付这类风险的：落盘的数据文件本身加密，没钥匙拿到文件也读不出内容。这篇文章把 MySQL 的 InnoDB 表空间加密讲透：由哪几个组件构成、怎么一步步开启、master key 怎么轮换、性能影响多少、以及它不防什么。

## 一、加密的边界：TDE 管什么、不管什么

先把边界画清楚，这是评估收益的前提：

| 层次 | TDE 是否覆盖 | 说明 |
|---|---|---|
| InnoDB 数据文件（.ibd） | ✅ 加密 | 落盘即密文 |
| redo log、undo log | ✅ 加密（8.0.30+ 完整支持） | 老版本部分支持 |
| binlog | ❌ 默认不加密 | 要 `binlog_encryption=ON` 单独开 |
| 临时表、排序文件 | 部分 | 8.0.16+ 可加密临时表 |
| **传输中的链路** | ❌ 不覆盖 | 那是 SSL 的领域，见前文 |
| **已经连上库的会话** | ❌ 不覆盖 | 正常登录的用户该看到什么还看到什么 |
| 内存中的数据页 | ❌ 不覆盖 | 内存中始终是明文，加密只在 buffer pool 刷盘路径上 |

一句话总结：**TDE 防"文件被窃取"，不防"活人查数据"**。所以它是合规（等保、GDPR）的必要项，但不是万能药——权限体系、审计、传输加密各有分工。

## 二、架构：三级密钥体系

MySQL 的 TDE 不是"一把钥匙锁所有"，而是三级结构：

```
表空间密钥（tablespace key）
  └── 加密每个表空间的数据，每个表一把
      └── 被 master key 加密后存在表空间头部
          └── master key 存在 keyring 插件里
              └── keyring 插件负责 key 的安全存储与轮换
```

关键设计：**数据文件里不存明文密钥**。表空间密钥以密文形式存在 `.ibd` 文件头，解密它需要 master key，master key 又在 keyring 里。三个组件的关系：

1. **keyring 插件**： master key 的保险箱。MySQL 8.0 主流是 `keyring_file`（存文件，简单）和 `component_keyring_file`（新版组件式，推荐）。企业版有 `keyring_encrypted_file`（更强的加密文件）、`keyring_okv`（KMIP 硬件）、`keyring_aws`（KMS）。
2. **InnoDB 表空间加密开关**：建表时 `ENCRYPTION='Y'`。
3. **master key 轮换**：`ALTER INSTANCE ROTATE INNODB MASTER KEY`。

## 三、第一步：装 keyring 插件

MySQL 8.0.24+ 推荐的组件式方案（老版本用插件式 `keyring_file`）：

```ini
# my.cnf（8.0.24+ 组件式）
[mysqld]
component_keyring_file = file:///var/lib/mysql-keyring/component_keyring_file
```

或在运行时通过 manifest 安装组件（以具体版本的官方文档为准）。装完确认：

```sql
SELECT * FROM performance_schema.keyring_component_status;
-- 或老版本
SHOW PLUGINS;  -- 看 keyring_file 状态 ACTIVE
```

**关键认知：keyring 文件丢了 = 数据永久读不出。** 这不是备份问题，是密钥管理问题。所以：

- keyring 文件必须纳入备份策略，且与数据备份**分开存放、同样安全等级**（甚至更高——加密的数据没 key 是垃圾，key 丢了数据也是垃圾）；
- 权限收紧：`600`、mysql 属主、独立目录；
- 生产建议：有条件就上 `component_keyring_encrypted_file` 或云 KMS（keyring_aws/okv），key 不落本地明文。

## 四、第二步：开表加密

三种粒度，按需选：

```sql
-- 1. 单表加密
CREATE TABLE t_sensitive (
  id BIGINT PRIMARY KEY,
  id_card VARCHAR(32)
) ENCRYPTION='Y';

-- 2. 改存量表（注意：这是全表重写操作，走 gh-ost！）
ALTER TABLE t_sensitive ENCRYPTION='Y';

-- 3. 表空间级（整个库默认加密）
-- 在 my.cnf 里：default_table_encryption=ON
-- 之后 CREATE TABLE 不显式声明也默认加密
-- 或运行时 SET PERSIST default_table_encryption = ON;
```

`default_table_encryption=ON` 是省心的全库方案，新表自动加密；schema 级可以覆盖默认：

```sql
CREATE DATABASE db_plain DEFAULT ENCRYPTION 'N';  -- 这个库不加密
CREATE TABLE t (id INT) ENCRYPTION='Y';           -- 单表仍可加密
```

**判断表是否加密**：

```sql
SELECT name, encryption FROM information_schema.innodb_tablespaces 
WHERE encryption='Y';
```

## 五、master key 轮换：必须排期的运维动作

master key 是整套体系的根。轮换它 = 重新加密所有表空间密钥——听起来动静很大，实际相当轻量（表空间密钥很短，重加密不碰数据本身）：

```sql
ALTER INSTANCE ROTATE INNODB MASTER KEY;
```

**为什么要轮换**：合规要求（很多等保/行业规范要求密钥定期更换）；keyring 文件可能泄露过；管理员离职。频率按规范来，常见是半年到一年。

**轮换的铁律：先备份 keyring，再轮换。** 因为轮换过程会更新 keyring 文件，如果中途 crash，旧 key 已部分失效——有备份就能回滚到某个一致状态。

另一个常配的参数是**表空间密钥的自动轮换间隔**（这是新的、不同的机制——轮换的是每张表的 tablespace key，不是 master key）：

```sql
SET PERSIST innodb_redo_log_encrypt = ON;      -- redo 加密（需带 undo/binlog 一起规划）
SET PERSIST binlog_encryption = ON;            -- binlog 加密
```

注意：redo/undo/binlog 加密各自独立开关，开了就要一起测，别只开一个。

## 六、加密带来的限制清单

上生产前必须知道的坑：

1. **DDL 限制**：加密表不能 `ALTER TABLE ... DISCARD TABLESPACE` / `IMPORT TABLESPACE`（迁移表空间的经典手段被禁）；`ALTER TABLE ... ENCRYPTION` 本身触发全表重写。
2. **复制限制**：加密表的 binlog 事件不含明文数据？——错，ROW 格式 binlog 里记录的是应用层数据（解密后的），加密只影响落盘的 ibd。但**未加密的 binlog + 加密的 ibd** 组合下，binlog 文件反而成了明文泄露面，所以开了表加密就该同步开 `binlog_encryption=ON`。
3. **xtrabackup 行为**：备份加密表需要 xtrabackup 2.4.11+ 且显式支持 keyring；备份文件**默认不自动加密**，要备份加密要么开 xtrabackup 的加密选项，要么靠备份存储层加密。这是最常被误解的一点——TDE 不等于备份加密。
4. **性能**：AES-256-XTS + AES-NI 硬件加速下，吞吐影响通常在 5%~15%（写重负载更明显，读基本无感）。但对延迟敏感的核心库，上线前拿真实负载压测。
5. **临时表空间**：8.0.16+ 可加密临时表（`innodb_temp_tablespace_encrypt=ON` 或对应变量），不配的话临时文件是明文。
6. **mysqldump**：dump 出来的是明文 SQL——TDE 不保护导出文件，导出的安全靠文件权限和存储加密。

## 七、和备份、SSL 的关系：三件套

数据安全是组合拳，TDE 只是其中一件：

| 威胁 | 防护手段 |
|---|---|
| 文件/快照被窃取 | **TDE（表空间加密）** |
| 备份文件被窃取 | 备份加密（xtrabackup `--encrypt` 或存储层加密） |
| 链路被抓包 | **SSL 传输加密** |
| 活人越权查询 | 权限体系 + 审计 |

典型合规场景（等保三级）通常会同时要求三件套。只做 TDE 不做备份加密，等于把明文备份留在裸奔状态——这是最常见的合规死角。

## 八、落地检查清单

- [ ] keyring 组件已安装且 ACTIVE，keyring 文件权限 600；
- [ ] keyring 文件纳入备份（与数据备份同等级、异地）；
- [ ] 核心敏感表 `ENCRYPTION='Y'`，或全局 `default_table_encryption=ON`；
- [ ] binlog 加密同步开启；
- [ ] redo/undo 加密按版本支持情况开启；
- [ ] master key 轮换计划写入年检（先备份 keyring 再轮换）；
- [ ] 备份链路加密确认（xtrabackup/存储层）；
- [ ] 上线前真实负载压测吞吐与延迟；
- [ ] 写进 runbook：keyring 丢失的应急响应（= 数据不可用，只能从备份恢复，所以备份有效性必须定期演练）。

## 九、小结

InnoDB 表空间加密三句话：

- **TDE 防文件窃取、不防活人**：它和数据备份加密、SSL 传输加密是三道独立的门，别混为一谈；
- **密钥是根**：keyring 文件比数据更重要，丢了加密数据就是永久损坏，备份和演练要做在钥匙上；
- **轮换和加密一起做才完整**：`ALTER INSTANCE ROTATE INNODB MASTER KEY` 轮换根密钥，binlog/redo 加密补齐落盘明文面，一次规划全做齐。

下一篇进入 ms5-9 收尾篇，讲慢日志分析：怎么从海量慢查询里找出真正该优化的那几条，以及 pt-query-digest 的标准用法。
