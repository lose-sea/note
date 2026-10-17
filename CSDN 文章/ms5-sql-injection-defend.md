# MySQL SQL 注入防御：预编译、白名单与最小权限

某公司安全演练，红队用一条 `' OR '1'='1` 登进了后台——不是他们技术差，是登录语句长这样：`"SELECT * FROM users WHERE name='" + name + "' AND pwd='" + pwd + "'"`。字符串拼 SQL，是这个行业里最古老、最简单、也最顽固的漏洞。MySQL 层面的防御手段其实很清晰，这篇文章把它们系统讲一遍：预编译为什么能根治、`NO_BACKSLASH_ESCAPES` 和 `sql_mode` 各自管什么、存储过程和 ORM 为什么不是免死金牌、以及怎么用 general_log 和审计插件做事后溯源。

## 一、注入的根因只有一条：数据和代码没有分离

先看一个最小复现。假设表结构：

```sql
CREATE TABLE t_user (
  id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(50) NOT NULL,
  pwd  VARCHAR(100) NOT NULL
);
INSERT INTO t_user(name, pwd) VALUES ('alice', 'P@ss1234');
```

漏洞版本（Java 风格伪代码）：

```java
String sql = "SELECT * FROM t_user WHERE name='" + name + "' AND pwd='" + pwd + "'";
```

攻击者提交 `name = admin' -- `，注意后面有个空格，拼出来是：

```sql
SELECT * FROM t_user WHERE name='admin' -- ' AND pwd='任意值'
```

`--` 在 MySQL 里是注释符（**后面必须有空格或控制字符**，否则不是注释），于是密码条件整段被注释掉，查询退化成"查名叫 admin 的用户"。更激进的 `name = ' OR 1=1 -- ` 直接变成：

```sql
SELECT * FROM t_user WHERE name='' OR 1=1 -- '
```

返回全表。再进一步，配合 `UNION SELECT` 可以拖 `information_schema.tables` 把库表结构整个摸走。

**注意 MySQL 和 SQL Server 的差异**：MySQL 不支持堆叠查询（`;` 后接第二条语句，Connector/J 默认禁止，CLI 也需显式开 `--multi-statements`），所以 MySQL 注入的主要目标是**数据外带**（UNION）、**布尔盲注**、**时间盲注**（`SLEEP(5)`、`BENCHMARK`）和**报错注入**（`extractvalue`、`updatexml`），而不是直接执行第二条语句。防御思路不变，但利用面不同。

不管怎么变着花样利用，根因只有一个：**用户输入被当作 SQL 代码执行**。所以防御的核心也是一个：**让输入永远是数据**。

## 二、预编译：唯一值得信任的方案

预编译（Prepared Statement）的原理是把 SQL 拆成两段：先送"结构"给服务端，再送"数据"：

```
客户端 → 服务端：COM_STMT_PREPARE  "SELECT * FROM t_user WHERE name=? AND pwd=?"
服务端 → 客户端：stmt_id + 参数元信息
客户端 → 服务端：COM_STMT_EXECUTE  [参数: name='alice', pwd='x']
```

服务端在 prepare 阶段就把 SQL 解析、优化成执行计划，参数在 execute 阶段只是**纯数据**，走的是二进制协议，永远不可能被解析为 SQL 语法。攻击者就算提交 `' OR 1=1 --`，服务端也只会把它当作一个"名叫 `' OR 1=1 --` 的用户"去查，查不到就是查不到。

各语言的标准写法：

**Java（JDBC）**

```java
String sql = "SELECT * FROM t_user WHERE name = ? AND pwd = ?";
try (PreparedStatement ps = conn.prepareStatement(sql)) {
    ps.setString(1, name);   // 参数绑定，绝不拼字符串
    ps.setString(2, pwd);
    try (ResultSet rs = ps.executeQuery()) { /* ... */ }
}
```

**Python（PyMySQL / mysql-connector）**

```python
cur.execute("SELECT * FROM t_user WHERE name = %s AND pwd = %s", (name, pwd))
```

注意占位符是 `%s` 而不是 `?`，且参数必须走第二个位置参数——`cur.execute(f"... {name}")` 依旧是注入。

**Go（database/sql）**

```go
db.QueryRow("SELECT * FROM t_user WHERE name = ? AND pwd = ?", name, pwd)
```

**PHP（PDO）**

```php
$stmt = $pdo->prepare("SELECT * FROM t_user WHERE name = ? AND pwd = ?");
$stmt->execute([$name, $pwd]);
```

用 PDI 时有一个经典错误：`$pdo->query("SELECT ... {$name}")` 或者 `setAttribute(PDO::ATTR_EMULATE_PREPARES, true)` 后依然在客户端拼参数。前者明显是注入；后者是伪预编译——PDO 把参数转义后在客户端拼 SQL 发过去，**字符集不一致时会出绕过**（GBK 宽字节注入的原理），所以生产建议 `ATTR_EMULATE_PREPARES = false`，走服务端真预编译。

### 2.1 什么时候不能预编译

不是所有位置都能参数化，典型的有三类：

| 场景 | 为什么不能参数化 | 正确做法 |
|---|---|---|
| 表名/列名作为参数 | 标识符不能是占位符 | 白名单映射，绝不用传参拼 |
| `IN (...)` 列表 | 数量固定才好写占位符 | 按数量生成 `?,?,?` 占位符 |
| `ORDER BY` 方向 / `LIMIT` 动态 | 语法结构 | 白名单枚举 + 数字强转 |

**表名/列名的白名单**是重灾区。错误写法：

```java
String orderCol = request.getParameter("col");   // "name; DROP TABLE t_user --"
String sql = "SELECT * FROM t_user ORDER BY " + orderCol;
```

正确写法是维护一个映射，只允许出现在集合里的值通过：

```java
private static final Map<String, String> ALLOWED = Map.of(
    "name", "name", "id", "id", "created", "created_at"
);
String col = ALLOWED.getOrDefault(request.getParameter("col"), "id");
String sql = "SELECT * FROM t_user ORDER BY " + col;
```

`IN` 列表则按参数个数生成占位符：

```java
List<Integer> ids = List.of(1, 2, 3);
String sql = "SELECT * FROM t_user WHERE id IN (" +
    ids.stream().map(i -> "?").collect(Collectors.joining(",")) + ")";
```

记住一个原则：**凡是"结构"要动态变，就用白名单枚举；凡是"值"要动态传，就用参数绑定。**

### 2.2 预编译的两个误区

**误区一："用了预编译就可以随便 whitelist/escape 混着来"。** 混用等于没防——一条拼接语句就够把库拖走。防御要全链路，漏一个入口全盘皆输。

**误区二："预处理有性能开销，热点接口不用"。** MySQL 的 prepare 有解析优化开销，但 `PreparedStatement` 对象本身可以复用（连接池层面缓存），实际开销很小。真正需要注意的是**执行计划固化**：预编译后执行计划在第一次 execute 时确定，如果数据分布倾斜（比如 prepare 时扫描 10 行，执行时参数是热点值导致扫描 1000 万行），可能会选错索引。MySQL 8.0 有执行计划自动重优化机制，但极端场景下仍建议对参数分布差异巨大的语句不用预编译或拆分。这是性能权衡，不是安全豁免。

## 三、存储过程不是免死金牌

"我们把逻辑都收进存储过程，应用只传参数，是不是就安全了？"——不一定，取决于存储过程**内部**怎么写。

```sql
-- 不安全：内部依然是拼接
CREATE PROCEDURE get_user(IN p_name VARCHAR(50))
BEGIN
  SET @sql = CONCAT('SELECT * FROM t_user WHERE name = ''', p_name, '''');
  PREPARE stmt FROM @sql;
  EXECUTE stmt;
  DEALLOCATE PREPARE stmt;
END;
```

这里 `CONCAT` + `PREPARE` 就是存储过程版字符串拼接，注入原样复现。安全写法是用存储过程的参数做条件，或者内部用 `PREPARE ... FROM '... WHERE name = ?'` + `EXECUTE ... USING`：

```sql
CREATE PROCEDURE get_user_safe(IN p_name VARCHAR(50))
BEGIN
  SET @sql = 'SELECT * FROM t_user WHERE name = ?';
  PREPARE stmt FROM @sql;
  EXECUTE stmt USING @p_name;
  DEALLOCATE PREPARE stmt;
END;
```

但说实话，存储过程的注入防御收益有限，成本很高（难调试、难版本管理、难单元测试）。**用存储过程防注入，收益还不如全链路参数化。** 它真正解决的问题是"收口数据访问逻辑"，跟注入防御是两回事。另外 `DEFINER` 权限的存储过程还有提权面——`DEFINER=root@%` 的过程被低权限用户调用时以 root 权限执行，过程内部如果被注入，破坏力反而更大。

## 四、ORM 与框架的注入面

用了 MyBatis / Hibernate / JPA 不代表免疫，注入面通常藏在这几个地方：

**1. MyBatis 的 `${}`**

MyBatis 的参数占位符有两个：`#{}` 是预编译参数，`${}` 是字符串替换。

```xml
<!-- 安全 -->
<select id="getUser">SELECT * FROM t_user WHERE name = #{name}</select>

<!-- 注入！${name} 会被直接替换进 SQL -->
<select id="getUserOrder">SELECT * FROM t_user ORDER BY ${col}</select>
```

`${}` 只应该出现在**无法参数化且已做白名单**的位置（如排序字段），且必须有全局代码规范约束。很多历史项目里的注入都是 `ORDER BY ${col}` 或者 `LIKE '%${keyword}%'` 这种写法。

**2. 原生 SQL 混在 ORM 里**

```java
// Hibernate 里的 createSQLQuery，拼接照样注入
session.createSQLQuery("SELECT * FROM t_user WHERE name = '" + name + "'");
```

ORM 提供的原生 SQL 接口没有任何保护，拼了就中。

**3. LIKE 的正确写法**

```java
// Java
ps.setString(1, "%" + keyword + "%");   // 通配符作为"值"传入

// MyBatis
<if test="keyword != null"> AND name LIKE CONCAT('%', #{keyword}, '%') </if>
```

注意 `LIKE` 的参数里如果用户输入了 `%` 或 `_`，那是**通配符注入**（DoS 面：`%` 开头导致全表扫描），不是 SQL 注入。对这类要转义：`ESCAPE` 子句 + 转义函数，或干脆对关键字做长度限制。

**4. 分页插件**

`PageHelper` 之类在拦截器里拼 `LIMIT`，一般会做强转，但如果自己写分页 SQL 拼接字符串，就回到了拼接的老路。

## 五、纵深防御：MySQL 侧还能做什么

应用层参数化之后，数据库侧这几层是"兜底"，不是主攻：

### 5.1 最小权限——注入成功也拿不到多少

这条被严重低估。**如果应用账号对 `t_user` 只有 `SELECT`，注入成功最多拖数据，写不进去；如果只有业务库权限，`information_schema` 能看到但摸不到其他库。**

```sql
-- 应用的账号，只给业务库的 CRUD
CREATE USER 'app_web'@'10.0.%' IDENTIFIED BY '...';
GRANT SELECT, INSERT, UPDATE ON bizdb.* TO 'app_web'@'10.0.%';

-- 拒绝访问 information_schema 以外的东西
-- MySQL 8.0：确认没有多余全局权限
SHOW GRANTS FOR 'app_web'@'10.0.%';
```

绝对禁止的三件事：应用账号带 `FILE` 权限（`LOAD_FILE` / `INTO OUTFILE` 可读写服务器文件）、带 `SUPER`/`PROCESS` 权限、能访问 `mysql` 库（`GRANT` 提权、改账号密码）。用 `GRANT` 精确到表级甚至列级，是注入后损失控制的最后一道墙。

### 5.2 sql_mode 与字符集设置

- `NO_BACKSLASH_ESCAPES`：这个模式关掉反斜杠转义，某些框架配合特定字符集可以消除一部分宽字节绕过，但它同时让 `\'` 失效，**不是为防注入设计的**，改它要全局评估。
- 统一 `utf8mb4`：GBK 等宽字节字符集的 `%df%27` 宽字节绕过是经典攻击面，全库 utf8mb4 可以消除这一类。
- `sql_mode` 里开 `STRICT_TRANS_TABLES`：和注入无直接关系，但严格模式能拦截很多异常写入，减少被注入后的脏数据。

### 5.3 用日志做溯源

漏防被拖库后，"是谁、从哪、什么时候进来的"要靠日志回答：

```sql
-- general log（开销大，仅临时开）
SET GLOBAL general_log = ON;
SET GLOBAL general_log_file = '/var/log/mysql/general.log';

-- 更好的选择：performance_schema 或审计插件
SELECT * FROM performance_schema.events_statements_history_long
WHERE SQL_TEXT LIKE '%UNION%' OR SQL_TEXT LIKE '%SLEEP(%';
```

慢日志也可以捞（`long_query_time = 0` 全记，仅排查期）。这些是重负载手段，只应在演练或事发后开启。

## 六、一份可执行的整改清单

给已有项目做一轮注入整改，按这个顺序推：

1. **全库扫描拼接点**：grep 代码里的 `"SELECT` / `"UPDATE` / `"DELETE` / `"INSERT` 拼字符串，以及 MyBatis XML 里的 `${`，列出清单；
2. **热点接口先改**：登录、搜索、导出、订单查询，按暴露面排序；
3. **动态结构白名单化**：排序字段、IN 列表、表名，全部枚举；
4. **账号权限回收**：应用账号去掉 `FILE`、`mysql` 库访问、`SUPER`，按库按表授权；
5. **字符集统一 utf8mb4**，顺带消除宽字节绕过面；
6. **演练验证**：用 sqlmap 对预发环境扫一轮（`--batch --level 3 --risk 2`），确认无告警再上线；
7. **长期防线**：CI 里加 SQL 拼接静态扫描规则，新增代码违规即卡住。

## 七、小结

MySQL 注入防御的要点，浓缩成几句可以背下来的话：

- 根因只有一个：**输入被当成代码执行**；对策只有一个：**参数绑定**。
- **预编译是唯一值得信任的方案**，且要全链路——漏一个拼接点，前面全白做。
- 表名、列名、排序、IN 列表这类**结构动态化**，用白名单枚举，永远不要拼接传参。
- **存储过程和 ORM 都不是免死金牌**，`${}`、原生 SQL、`CONCAT` 拼过程都是经典翻车点。
- 事后兜底靠**最小权限**（砍 `FILE`、砍 `mysql` 库）和**日志溯源**（general_log / events_statements_history）。

下一篇讲 MySQL 审计插件：怎么把"谁在什么时候动了什么数据"变成不可抵赖的记录，满足等保的审计要求。
