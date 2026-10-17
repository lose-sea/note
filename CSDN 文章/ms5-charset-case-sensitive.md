# MySQL 排序规则实战：为什么查 "cn" 查不到 "CN"

`SELECT * FROM t_user WHERE username = 'admin'` 查不到 `ADMIN`；两个表 JOIN 报 `Illegal mix of collations`；用户名要做大小写敏感比较，`=` 却天生不分大小写——这些问题的源头都是同一个东西：**排序规则（collation）**。字符集决定"能存什么字符"，排序规则决定"怎么比、怎么排"。这篇文章把 collation 讲透：命名规则怎么读、常见几种的区别、列级怎么覆盖、连接混用怎么排查，以及用户系统该选哪种。

## 一、字符集和排序规则的分工

先建立最基础的认知：MySQL 里字符集和排序规则是两个独立设置，通常是 `字符集_排序规则` 一起声明。

```sql
CREATE TABLE t_demo (
  name VARCHAR(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci
);
```

- **字符集（charset）**：决定能存哪些字符、每个占几字节。`utf8mb4` 才是真 UTF-8（1~4 字节），MySQL 的 `utf8` 是 3 字节的假货。
- **排序规则（collation）**：决定两个字符串怎么比较是否相等、`ORDER BY` 怎么排序、索引怎么利用。

查一下当前库默认用什么：

```sql
SHOW VARIABLES LIKE 'collation%';       -- 连接层与服务器默认
SHOW TABLE STATUS LIKE 't_demo';        -- 表级默认 collation
SHOW FULL COLUMNS FROM t_demo;          -- 列级实际 collation（最可信）
```

一个表里不同列可以有不同的 collation——这就是"连接混用"报错的根源。

## 二、collation 命名规则：看懂名字就会选

以 `utf8mb4_0900_ai_ci` 为例拆解：

| 片段 | 含义 |
|---|---|
| `utf8mb4` | 字符集 |
| `0900` | 基于 Unicode 9.0 标准（MySQL 8.0 新增的排序规则系列） |
| `ai` | Accent Insensitive，**口音不敏感**（é = e） |
| `as` | Accent Sensitive，口音敏感 |
| `ci` | Case Insensitive，**大小写不敏感**（A = a） |
| `cs` | Case Sensitive，大小写敏感 |

老命名的 `utf8mb4_general_ci`：基于 Unicode 的简化排序，没有 `ai/as` 粒度控制，精度粗糙但兼容性好（5.7 默认）。新命名的 `utf8mb4_0900_ai_ci`：8.0 默认，排序更符合 Unicode 标准，性能也更好。

**MySQL 5.7 与 8.0 常见的 utf8mb4 排序规则对照：**

| 排序规则 | 大小写 | 口音 | 出现版本 | 备注 |
|---|---|---|---|---|
| `utf8mb4_general_ci` | 不敏感 | 不敏感 | 老默认 | 对中文排序近似，兼容老库 |
| `utf8mb4_unicode_ci` | 不敏感 | 不敏感 | 老 | 比 general 更准 |
| `utf8mb4_0900_ai_ci` | 不敏感 | 不敏感 | 8.0 默认 | 推荐新库 |
| `utf8mb4_0900_as_ci` | 不敏感 | 敏感 | 8.0 | 区分 é/e |
| `utf8mb4_0900_as_cs` | **敏感** | 敏感 | 8.0 | 用户名等精确匹配场景 |

还有一类 `_bin`：`utf8mb4_bin` 是**二进制比较**，逐字节对比，大小写、口音全敏感，且比较速度最快（不需要查排序权重表）。

## 三、为什么 "cn" 查不到 "CN"

这是问得最多的问题。默认 `utf8mb4_0900_ai_ci` 下 `A` 和 `a` 相等，所以：

```sql
-- 列 collation 是 ci（默认），下面两条等价
SELECT * FROM t_demo WHERE name = 'CN';
SELECT * FROM t_demo WHERE name = 'cn';
```

那什么时候"查不到"？两种情况：

**情况一：列本身是 `_bin` 或 `_cs`。** 比如从 PostgreSQL 迁移过来的库、或建表时手写了 `COLLATE utf8mb4_bin`，那 `='cn'` 就真的只匹配小写。

```sql
ALTER TABLE t_demo MODIFY name VARCHAR(50) COLLATE utf8mb4_bin;
SELECT * FROM t_demo WHERE name = 'cn';   -- 只匹配小写 cn
```

**情况二：连接字符集/排序规则不匹配导致隐式转换。** 连接语句带的 collation 和列不一样时，MySQL 会按优先级转换，某些转换路径下比较行为会变。更常见的是客户端压根没发对字符——比如页面 GBK、连接 utf8mb4，发过去的数据已经不对了，查不到很正常（这属于字符集链路问题，不是 collation 问题）。

**验证当前比较行为的最快方法：**

```sql
SELECT 'CN' = 'cn' COLLATE utf8mb4_0900_ai_ci;  -- 1（相等）
SELECT 'CN' = 'cn' COLLATE utf8mb4_0900_as_cs;  -- 0（不等）
SELECT 'CN' = 'cn' COLLATE utf8mb4_bin;         -- 0（不等）
```

`COLLATE` 子句可以直接写在表达式后面做临时覆盖——这是排查和兜底的利器。

## 四、用户系统选哪种：一个反直觉的结论

"我要精确匹配，是不是该用 `_bin`？"——多数场景恰恰相反。

MySQL 的 collation 选择要分场景：

| 场景 | 推荐 | 理由 |
|---|---|---|
| 用户名、登录账号 | `_bin` 或 `_as_cs` | 安全 + 防混淆：`Admin` 和 `admin` 是两个账号 |
| 邮箱 | 一律小写化后存 `_bin` | 邮箱本地部分理论大小写敏感，实际几乎都小写；先 `LOWER()` 再存，比较用 `_bin` 最快 |
| 昵称、展示名 | `_ai_ci` | 用户感受优先，搜"TOM"应命中"Tom" |
| 标签、枚举 | `_ai_ci` | 同上 |
| 校验和、UUID、Token | `_bin` | 二进制比较，最快且零歧义 |
| 中文内容字段 | `_0900_ai_ci` | 8.0 默认即可 |

**为什么用户名不推荐 `_bin` 一路莽？** 三个理由：

1. **大小写重复**：`_bin` 下 `Admin` 和 `admin` 是两个用户，业务上多半不希望这样，需要在应用层做唯一性归一（小写化后再存），否则数据里会有看起来一样的两个账号。
2. **排序反直觉**：`ORDER BY` 时 `_bin` 按字节排，大写字母全部排在小写前面（ASCII 顺序），产品看到"Zhang"排在"alan"前面会来提 issue。
3. **性能差异极小**：`_ai_ci` 的比较开销在现代硬件上可以忽略，除非你是每秒百万次的逐行比对。

**折中做法（生产常见）**：存的时候统一 `LOWER(username)`，列 collation 用 `_bin`，查询也用 `LOWER(?)` 参数——比较走二进制，语义完全精确，也不怕大小写重复。索引建在 `username` 列上，`WHERE LOWER(username) = LOWER(?)` 能用上索引（MySQL 8.0 函数索引场景也可直接建表达式索引）。

## 五、Illegal mix of collations：连接两表报错怎么破

两个 collation 不同的列做比较，MySQL 要决定用哪个，当它们无法隐式统一时报错：

```sql
SELECT * FROM a JOIN b ON a.name = b.name;
-- ERROR 1267 (HY000): Illegal mix of collations (utf8mb4_0900_ai_ci,IMPLICIT) 
--   and (utf8mb4_general_ci,IMPLICIT) for operation '='
```

**原因**：5.7 建的库默认 `utf8mb4_general_ci`，8.0 新建的库默认 `utf8mb4_0900_ai_ci`，两个库互查就撞上了。MySQL 的 collation 合意性（coercibility）规则有限，非同系列之间不能自动转换。

**解法三种，按推荐程度：**

1. **统一 collation（根治）**：把一边的列 `ALTER TABLE ... MODIFY ... COLLATE utf8mb4_0900_ai_ci`，让全库一致。这是 8.0 升级后的标准动作。
2. **查询时显式 COLLATE（临时）**：
   ```sql
   SELECT * FROM a JOIN b ON a.name = b.name COLLATE utf8mb4_0900_ai_ci;
   ```
   注意：**显式 `COLLATE` 会让索引失效**——因为比较的是转换后的值，不是列上的索引原值。大表上慎用，仅适合临时查询。
3. **建新库/表时统一指定**：`CREATE DATABASE ... COLLATE utf8mb4_0900_ai_ci`，从源头杜绝混生。

**排查全库 collation 分布**，一条 SQL 看清家底：

```sql
SELECT table_schema, table_name, column_name, collation_name, COUNT(*) 
FROM information_schema.columns
WHERE table_schema NOT IN ('mysql','sys')
GROUP BY table_schema, table_name, collation_name;
```

看到 `general_ci` 和 `0900_ai_ci` 混在一起，就是定时炸弹。

## 六、排序规则与索引：性能视角

collation 影响索引效率，这是选型时容易忽略的一面：

1. **`_ci` 系列比较慢于 `_bin`**：`ci` 要把字符映射到排序权重再比较，`_bin` 直接逐字节。全表扫描场景下差异明显，索引等值查询差异可忽略（索引比较本身就是按 collation 规则走）。
2. **前缀索引长度受 collation 影响**：`VARCHAR(255)` 的普通索引，utf8mb4 下 255×4=1020 字节，超过 3072 上限会报 `Specified key was too long`——这时用前缀索引 `name(191)`（191×4=764 字节）。这和 collation 无关但和字符集有关，是 utf8mb4 改造时的连带坑。
3. **`LOWER(列)` 让索引失效**：除非建函数索引：
   ```sql
   CREATE INDEX idx_username_lower ON t_user ((LOWER(username)));
   SELECT * FROM t_user WHERE LOWER(username) = 'admin';
   ```
   MySQL 5.7+ 支持函数索引，这是"大小写归一 + 走索引"的标准解法。
4. **`LIKE 'abc%'` 能用索引，`LIKE '%abc'` 不能**：这与 collation 无关，但 `_ci` 下 `LIKE` 的前缀匹配依然走索引范围扫描；注意 `_ci` 会让 `LIKE 'ABC%'` 也命中 'abc...' 的数据。

## 七、修改 collation 的标准操作与风险

线上改 collation 属于表结构变更，按规矩来：

```sql
-- 单列
ALTER TABLE t_user MODIFY username VARCHAR(50) 
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NOT NULL;

-- 整表所有列（注意：只转字符列的 collation）
ALTER TABLE t_user CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
```

风险清单：

- **大表重建**：`MODIFY` 列可能触发表重建，用 gh-ost / pt-osc 在线做；
- **索引失效**：改 collation 后，所有相关索引会被重建，执行期间锁表（取决于 DDL 在线能力）；
- **数据行为变化**：`general_ci` → `0900_ai_ci` 后，某些原本"相等"的数据可能变得"不等"（`general_ci` 把部分不同字符视为相同，`0900` 更严格）——**改完必须全量跑一遍重复值检查**：
  ```sql
  SELECT username, COUNT(*) FROM t_user GROUP BY username HAVING COUNT(*) > 1;
  ```
- **回滚**：改回去容易，但改 collation 期间如果唯一索引上冒出新重复，写入会失败，业务要先发归一化代码。

**安全顺序**：先在从库改、观察一天 → 预发验证唯一性 → 主库窗口期 gh-ost 执行 → 应用发版统一连接层 collation → 监控慢查询与写入失败。

## 八、连接层的 collation 也要看

服务端 collation 对了还不够，连接时协商的结果才是实际比较用的：

```sql
SHOW VARIABLES LIKE 'collation_%';
-- collation_connection  连接字符集的默认 collation
-- collation_database    当前库默认
-- collation_server      服务器默认
```

客户端发起连接时，驱动会声明 `character_set_client` / `collation_connection`。如果连接协商出的 collation 和列的 collation 混不到一起，同样可能报 mix 错。**统一原则：库、表、列、连接四层 collation 全部一致**，这是最省心的状态。

MySQL 8.0 的 `SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci` 可以一次把链路三个变量都设好，驱动连接串里带 `charset=utf8mb4` 即可（新驱动默认走 8.0 推荐值）。

## 九、小结

排序规则的三句话总结：

- **名字会读就会选**：`_ci` 大小写不敏感、`_cs` 敏感、`_ai` 口音不敏感、`_bin` 二进制，`utf8mb4_0900_ai_ci` 是 8.0 新默认；
- **精确匹配场景**（用户名、Token、邮箱）用 `_bin` 配合 `LOWER()` 归一；展示类字段用 `_ai_ci`；
- **报 mix 错**：一边显式 `COLLATE` 临时解（伤索引），一边统一 collation 根治；线上改 collation 走 gh-ost 并先查重复值。

下一篇讲 TIMESTAMP 的 2038 问题：这个只有 4 字节的类型为什么还没被淘汰、时区怎么影响它、以及什么时候该换 DATETIME。
