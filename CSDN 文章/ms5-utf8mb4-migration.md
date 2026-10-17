# MySQL utf8mb4 改造实战：字符集迁移与索引长度墙

一张存用户昵称的表，插进一个 emoji 就报 `Incorrect string value`；一个改字符集的 ALTER，把索引长度顶爆 `Specified key was too long`；还有更冤的——历史库明明是 utf8，用户资料里的生僻字却变成了一串问号。这三个坑，都指向同一件事：MySQL 的 utf8 是个"假 utf8"。这篇文章把 utf8mb4 改造完整过一遍：为什么必须迁、四层字符集怎么设、索引长度墙怎么破、以及存量库灰度改造的标准动作。

## 一、MySQL 的 utf8 为什么是假的

MySQL 的 `utf8` 字符集**最多只存 3 个字节**（utf8mb3），它覆盖 BMP 基本多文种平面，但存不了 Emoji、生僻字、部分数学符号——这些在 UTF-8 里需要 4 字节。

```sql
CREATE TABLE t_demo (name VARCHAR(32)) CHARSET=utf8;
INSERT INTO t_demo VALUES ('😀');   -- ERROR 1366 (HY000): Incorrect string value
```

想存这些，必须用 `utf8mb4`（真正的 UTF-8，1~4 字节）。

另一个坑是：万一客户端连接用的字符集和服务器不匹配，4 字节数据在链路上可能被截断成乱码或直接报错。所以 utf8mb4 改造不是"改个表Charset"就完了，它涉及**库、表、列、连接**四个层次，外加客户端驱动——少一层，改造就不完整。

## 二、MySQL 字符集的四个层级

改造前必须建立的全局观——字符集有四层，从粗到细：

| 层级 | 变量 / 位置 | 默认 | 说明 |
|---|---|---|---|
| 服务器级 | `character_set_server` | utf8mb4（8.0 起） | 新建库的默认 |
| 库级 | `CREATE DATABASE ... CHARSET` | 继承服务器 | 新建表的默认 |
| 表级 | `CREATE TABLE ... CHARSET` | 继承库 | 新建列的默认 |
| 列级 | 列定义里的 `CHARSET` | 继承表 | 最终生效值 |

外加一条独立的链路——**连接字符集**，它不属于上面任何一层，但决定了客户端和服务端之间怎么转换：

| 变量 | 作用 |
|---|---|
| `character_set_client` | 客户端发来的语句用什么编码 |
| `character_set_connection` | 语句被解析时的编码 |
| `character_set_results` | 返回给客户端的结果编码 |

改造要做的就是：**库表列统一 utf8mb4，链路三个变量也统一 utf8mb4。** 只改表不改连接，4 字节字符过不了链路；只改连接不改表，历史表依然存不了。

MySQL 8.0 的默认值已经全面 utf8mb4（`character_set_server=utf8mb4`、`collation_server=utf8mb4_0900_ai_ci`），**新建库直接用默认即可，本文重点讲历史库改造。**

## 三、先盘点：现状是什么样的

改造第一步不是动手，是把家底摸清。

### 3.1 全库字符集分布

```sql
-- 每个库每个表的字符集分布
SELECT table_schema, table_name, column_name, character_set_name, collation_name, data_type
FROM information_schema.columns
WHERE table_schema NOT IN ('mysql','sys','information_schema','performance_schema')
ORDER BY table_schema, table_name, ordinal_position;
```

重点看三类：`character_set_name = 'utf8'`（假 utf8，要迁）、`'latin1'`（西欧，注释可能是乱码）、`'gbk'`（要评估，不是都要迁）。

### 3.2 连接层是不是 utf8mb4

```sql
SHOW VARIABLES LIKE 'character_set_%';
SHOW VARIABLES LIKE 'collation%';
```

如果 `character_set_client/connection/results` 是 utf8（mb3），即便表是 utf8mb4，客户端写入 Emoji 一样会在报错或截断在链路上。

### 3.3 排序规则是否一致

同是 utf8mb4，`utf8mb4_general_ci` 和 `utf8mb4_0900_ai_ci` 的排序行为不同：

- `general_ci`：MySQL 5.7 时代的默认，精度粗，对中日韩字符的排序近似；
- `0900_ai_ci`：MySQL 8.0 默认，基于 Unicode 9.0，`ai` = 口音不敏感（é = e），`ci` = 大小写不敏感；
- `utf8mb4_0900_as_cs`：口音敏感、大小写敏感，适合用户名精确匹配。

**同一条 JOIN 或 UNION 两边的 collation 不一样，会报 `Illegal mix of collations`。** 改造时要么全统一，要么对字段显式 `COLLATE`。

## 四、索引长度墙：改造必踩的坑

utf8mb4 每个字符最多 4 字节，同样 `VARCHAR(255)` 的索引，utf8 下占 765 字节，utf8mb4 下占 1020 字节——于是撞上了 InnoDB 的索引长度限制：

| 限制 | 值 | 说明 |
|---|---|---|
| 单列索引最大字节 | 767 字节 | 对应 antelope 文件格式下 `VARCHAR(255)` utf8mb3 |
| 大前缀后 | 3072 字节 | Barracuda + `innodb_large_prefix`，MySQL 5.7.7+ 默认开启 |

3072 字节 ÷ 4 = **utf8mb4 下单列 VARCHAR 索引最长 768 字符**。所以：

- `VARCHAR(255)` + utf8mb4 + 普通索引 = 1020 字节，**在没开大前缀的老实例上直接报错 `Specified key was too long; max key length is 767 bytes`**；
- 解决路径按优先级：

```sql
-- 方案 1：确认实例已支持大前缀（5.7.7+ 默认，8.0 无此变量，恒支持）
SHOW VARIABLES LIKE 'innodb_large_prefix';   -- 8.0 已移除，永远支持 3072
SHOW VARIABLES LIKE 'innodb_file_format';    -- 应为 Barracuda

-- 方案 2：改前缀索引（保留语义的最优解）
ALTER TABLE t_user ADD INDEX idx_name (name(191));   -- 191 × 4 = 764 < 767

-- 方案 3：改列长度
ALTER TABLE t_user MODIFY name VARCHAR(191) ...;
```

**191 这个魔法数字**就是从 767 字节反推的（767 ÷ 4 = 191.75，取整 191），大量 MyBatis-Plus、Spring Boot 老项目里 `varchar(191)` 的写法就是为绕这个限制。新库如果直接 utf8mb4 + 3072 上限，可以用到 768。

还有个连带坑：`ROW_FORMAT` 也受影响。改 utf8mb4 前建议表已经是 `DYNAMIC`（8.0 默认）；老库如果是 `COMPACT`，先 `ALTER TABLE ... ROW_FORMAT=DYNAMIC` 再改字符集，两次 ALTER 不如合并成一次写。

## 五、改造实施：三种做法选哪个

存量库改造有三种路线，按数据量和停机窗口选。

### 5.1 在线改：ALTER TABLE ... CONVERT TO

```sql
ALTER TABLE t_user CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
```

它会把表和**所有字符列**一起转。三个注意点：

1. **十有八九要重建表**——大表上这是一次 table rebuild，期间锁表（5.6 之前全程 DML 阻塞，5.6+ 有 online DDL，但转换字符集这个操作在部分版本会 fallback 到 copy）。数据量大的表执行时间几十分钟到几小时。
2. 只改表不改列用 `MODIFY`，只改列 charset 用 `ALTER TABLE t MODIFY name VARCHAR(255) CHARACTER SET utf8mb4`。`CONVERT TO` 是全表扫描转换，`MODIFY DEFAULT CHARACTER SET` 只改默认值不影响存量列——**看语义选**。
3. `MODIFY` 列时**必须把完整列定义重写一遍**（类型、是否可空、默认值），MySQL 不允许只改 charset 一个属性。

### 5.2 双写过渡：新库 utf8mb4，老库保持

新业务全部建 utf8mb4；老库维持现状，写代码时对 emoji 做容错（拒绝或替换）。这是最低风险路线，代价是老库永远带着技术债。

### 5.3 工具化：pt-online-schema-change / gh-ost

大表改造的标准姿势：

```bash
pt-online-schema-change \
  --alter "CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci" \
  D=bizdb,t=t_user \
  --execute \
  --chunk-size 2000
```

pt-osc 走"影子表 + 触发器同步增量"的老路，gh-ost 走 binlog 增量更新的新路。两者共同点：**长事务期间对主库压力可控，从库延迟可观测，可随时中止**。各有坑（pt-osc 触发器对写入有开销；gh-ost 需要 row 格式 binlog），使用前读官方文档，先在从库演练。

## 六、端到端配置清单

改造不止数据库，全链路都要 utf8mb4：

### 6.1 服务端

```ini
[mysqld]
character-set-server = utf8mb4
collation-server     = utf8mb4_0900_ai_ci
init_connect         = 'SET NAMES utf8mb4'   # 老版本兜底，8.0 可省
```

对 5.7 老实例，`init_connect` 给没显式 SET NAMES 的老客户端兜底（注意它对 `SUPER` 用户不执行，这是设计使然）。

### 6.2 连接层驱动

| 语言/驱动 | 配置 |
|---|---|
| JDBC | URL 加 `characterEncoding=utf8mb4&useUnicode=true`（新驱动可省） |
| PyMySQL | `charset='utf8mb4'`，连接建立时自动 SET NAMES |
| Go | `collation=utf8mb4_unicode_ci` + `loc` |
| PHP mysqli/PDO | `SET NAMES utf8mb4` 或 DSN 加 `charset=utf8mb4` |
| Node mysql | `charset: 'utf8mb4'` |

**验证方法**：连接后执行 `SHOW VARIABLES LIKE 'character_set_connection'`，三个变量都得是 utf8mb4。很多"明明改了驱动却还报错"的案子，最后发现是连接池里的老连接没重建。

### 6.3 应用侧

- HTML 页面 `<meta charset="utf-8">`；
- HTTP 响应 `Content-Type: ...; charset=utf-8`；
- JSON 序列化 UTF-8；
- 老数据从 GBK/latin1 导出再导入时，先用 `iconv` 转 UTF-8，**不要直接灌**（会把乱码固化进 utf8mb4）。

## 七、灰度与回滚

改造的标准节奏：

1. **预发环境演练**：找数据量最大的表走一遍计时，测读写、测备份恢复；
2. **索引长度预检**：改造前跑一遍"所有索引的字节长度 / 字符长度"，确认全部 < 3072 字节（或 191 字符前缀）；
3. **备份先行**：全备 + binlog 位点记录；
4. **从库先行**：先在从库执行，确认无延迟、无报错后做主库；
5. **窗口期执行**：业务低峰，precheck → ALTER → 校验行数/校验和；
6. **连接层滚动**：应用发版切换驱动配置，观察连接报错；
7. **验证回归**：插一条带 emoji 的数据，查回来比对；跑一遍核心读写；
8. **观察期**：一周内盯慢日志里的字符集转换告警、乱码投诉。

回滚预案：表级回滚就是反向 `ALTER ... CONVERT TO CHARACTER SET utf8`——但**已被截断的数据救不回来**，比如从 latin1 迁到 utf8mb4 时如果源数据本身就是"问号乱码"，迁过去还是乱码。所以改造前要先确认源数据是干净的 latin1 真数据，而不是二次损坏的产物。

## 八、验收清单

- [ ] `SHOW VARIABLES` 确认 server/database/connection/results 全 utf8mb4；
- [ ] `information_schema.columns` 无残留 `utf8`（mb3）/ `latin1` 业务列；
- [ ] 全库索引长度 < 3072 字节，超长的已改前缀索引；
- [ ] 驱动/ORM 连接串全部带 utf8mb4；
- [ ] 插入 emoji 与生僻字回归通过；
- [ ] 无 `Illegal mix of collations` 报错；
- [ ] 老系统（Excel 导入、CSV 导出）抽查无乱码。

## 九、小结

utf8mb4 改造的三条主线：

- **为什么迁**：MySQL 的 `utf8` 是 3 字节假货，emoji 和生僻字存不了，必须迁到 utf8mb4；
- **改什么**：库、表、列、连接四层全改，`CONVERT TO` 或 pt-osc/gh-ost 执行，索引 3072 字节墙用 191/768 前缀绕；
- **怎么稳**：从库先行、窗口期执行、连接层滚动、回滚预案先写好，验收用"插一条 emoji"做黄金判据。

至此 ms5-7 整册 6 篇完成。接下来的 ms5-8 会进入生产运维深水区：慢日志分析与优化、监控告警体系、以及常用性能诊断场景。
