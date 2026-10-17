# 函数索引：给表达式加索引的正确姿势

`WHERE YEAR(created_at) = 2026`——这种对列套函数的查询，索引 `created_at` 用不上，因为索引存的是原值、WHERE 要的是函数结果。MySQL 8.0 的**函数索引**（Functional Index）解决了这个问题：把表达式结果直接存进索引。这篇文章讲它的机制、创建使用要点、和虚拟列方案的关系，以及一批高频误用场景的修正。

## 问题：函数包住的列，索引失效

```sql
CREATE INDEX idx_created ON orders(created_at);

-- 用不上的原因
SELECT * FROM orders WHERE YEAR(created_at) = 2026 AND MONTH(created_at) = 10;
```

索引 `idx_created` 按完整时间戳排序，查询却问"哪年哪月"——**优化器没法从有序日期推导出"年份=2026 的行连续分布"**（不同年份交错），只能全表扫 + 对每行算 YEAR()。类似的经典失效模式：

- `WHERE DATE(created_at) = '2026-10-16'`（DATE() 截断）
- `WHERE LOWER(email) = 'abc@x.com'`
- `WHERE phone REGEXP '^138'`
- `WHERE JSON_UNQUOTE(JSON_EXTRACT(addr, '$.city')) = '北京'`

老解法是虚拟列，MySQL 8.0 直接把表达式提升为一等公民。

## 函数索引：表达式即索引列

```sql
-- 创建：不是列，是括号包住的表达式
CREATE INDEX idx_year_month ON orders( (YEAR(created_at)), (MONTH(created_at)) );

-- 使用：查询里必须写一模一样的表达式
SELECT * FROM orders WHERE YEAR(created_at) = 2026 AND MONTH(created_at) = 10;
-- EXPLAIN：range scan using idx_year_month ✅
```

关键三件事：

**1. 表达式必须逐字符匹配**。索引是 `YEAR(created_at)`，查询写 `YEAR(o.created_at)`（带表限定）或 `EXTRACT(YEAR FROM created_at)`（等价函数）都未必能用上——优化器对表达式做规范化匹配，等价改写有时能识别（EXTRACT 有时可以），但表限定符这种小改动最保险的写法是保持一致。**函数索引和查询表达式是严格契约关系**。

**2. 确定性函数才能建**。索引要求表达式对同一输入永远返回同一输出——NOW()、RAND()、UUID() 这类非确定性函数不能建。`(created_at + INTERVAL 8 HOUR)` 这种确定性表达式可以。

**3. 表达式里的函数有白名单**。不是所有内置函数都能上索引（一些和字符集、时区、会话状态绑定的函数被排除）。报错 `ERROR 3757` 之类就是在说"这个函数不能用于函数索引"——换写法或退虚拟列。

## 单列多表达式与组合

函数索引支持多表达式组合（上面的年月例子）和混合（普通列 + 表达式）：

```sql
-- 混合：状态等值 + 年份范围
CREATE INDEX idx_status_year ON orders( status, (YEAR(created_at)) );

SELECT * FROM orders WHERE status = 'PAID' AND YEAR(created_at) = 2026;
```

**组合顺序遵循普通联合索引的最左前缀原则**——status 前导等值，YEAR 后做范围。这也是 `(YEAR(x))` 不如 `status, (YEAR(x))` 灵活的原因：单表达式索引只能服务一种过滤，组合索引能复用。

## 函数索引 vs 虚拟列：怎么选

两条路线都能解决"函数查询走索引"，各有性格：

| 维度 | 函数索引 | 虚拟列 + 索引 |
|---|---|---|
| 创建语法 | `CREATE INDEX idx ON t( (expr) )` | 先 `ADD COLUMN c type AS (expr)` 再普通索引 |
| 写查询 | 查询必须写原表达式 | 查询直接 `WHERE c = v`，清爽 |
| 索引选择器 | 优化器自动选（表达式匹配） | 显式列，任何查询都能用 |
| 存储 | 只存索引，表结构不变 | 虚拟列可显式 SELECT、可参与更多操作 |
| 改表达式 | 删索引重建 | 改列定义影响面大 |
| 兼容老代码 | 不需要改 SQL | 查询习惯要改成列 |

**选型建议**：临时优化某个特定慢查询 → 函数索引，一行 SQL 的事；表达式会被多处查询、且希望代码可读 → 虚拟列。函数索引更适合"表达式本身作为查询语言固定下来"的场景，虚拟列更适合"这个派生值就是个逻辑字段"的场景。

虚拟列的两个高级玩法（函数索引给不了的）：**虚拟列可建主键/唯一约束**、**虚拟列可被普通索引以外的东西引用**（生成列的逻辑字段）。如果你的 JSON 字段要拍平 + 加唯一约束，只能虚拟列路线。

```sql
-- 虚拟列全家桶示例
ALTER TABLE product
ADD COLUMN city VARCHAR(50) AS (JSON_UNQUOTE(JSON_EXTRACT(addr, '$.city'))) STORED,
ADD INDEX idx_city(city);
```

STORED（实际存值）vs VIRTUAL（计算列，8.0.23 后默认可选）——频繁查询的派生列用 STORED，读多写少场景收益最大；只在索引里需要、查询也少就 VIRTUAL。**STORED 虚拟列和函数索引一样吃写性能**，CREATE/UPDATE 都要算，别滥用。

## 实战：五个高频场景的修正

**场景一：日期范围查询**。

```sql
-- 慢：函数包列
WHERE YEAR(created_at) = 2026 AND MONTH(created_at) = 10;
-- 快 V1：范围改写（最优，普通索引直接适用）
WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01';
-- 快 V2：确实要函数索引（无法改范围时）
CREATE INDEX idx_ym ON orders( (YEAR(created_at)), (MONTH(created_at)) );
```

**顺序很重要：先想能不能把函数包列改写成范围查询**。范围查询是索引的"母语"，函数索引是"翻译"。`DATE(created_at) = 'x'`、`YEAR(x) = y` 类查询，全部有等价的 `>= AND <` 范围写法——**先改 SQL，后建函数索引**，这个优先级能省一堆索引。

**场景二：大小写不敏感查询**。

```sql
-- 建索引
CREATE INDEX idx_lower_email ON user( (LOWER(email)) );
-- 查询
SELECT * FROM user WHERE LOWER(email) = 'abc@example.com';
```

比把列改成 `utf8mb4_0900_ai_ci` 排序规则（大小写不敏感 collation）影响面小——后者影响该列的所有比较和唯一约束。

**场景三：JSON 字段拍平**。

```sql
CREATE INDEX idx_city ON user( (JSON_UNQUOTE(JSON_EXTRACT(profile, '$.city'))) );
SELECT * FROM user WHERE JSON_UNQUOTE(JSON_EXTRACT(profile, '$.city')) = '北京';
```

JSON 单字段查询的函数索引路线。数组场景还是用上一篇的多值索引。

**场景四：表达式参与连接**。

```sql
-- 两表通过计算后的键 JOIN
CREATE INDEX idx_pad_phone ON user( (CONCAT('86', phone)) );
SELECT * FROM user u JOIN ext e ON CONCAT('86', u.phone) = e.full_phone;
```

少见但真实的场景（对接外部系统的固定格式）。JOIN 条件里的表达式同样吃函数索引。

**场景五：WHERE 里做单位换算**。

```sql
-- 金额存"分"，查询按"元"过滤
CREATE INDEX idx_amount_yuan ON t( (amount / 100) );
SELECT * FROM t WHERE amount / 100 BETWEEN 10 AND 100;
```

整数除法的语义坑注意：MySQL 里 `amount/100` 若是整数除法会截断，`amount DIV 100` 显式化更稳。函数索引存的就是表达式结果——**整数除法做索引，按分查会被除法的精度坑到**。建这类索引前先想清楚类型。

## 监控：函数索引的重灾区

函数索引的三个隐性成本：

1. **写放大**。INSERT/UPDATE 时，每个函数索引都要算一次表达式。5 个函数索引 = 每行写多算 5 次。
2. **优化器不用**。建了索引但查询表达式写错一个字符（空格、别名、大小写函数名之外的等价改写），优化器静默走全表扫——`SHOW STATUS LIKE 'Handler_read%'` 和 EXPLAIN 是发现它的手段。
3. **统计和成本**。表达式索引的选择性估算有时不如普通列准，复杂表达式上优化器可能高估/低估行数，连带 JOIN 顺序决策偏移。

**诊断纪律：建完函数索引，必须 EXPLAIN 一次实际查询确认命中**。"建了"和"用上了"之间隔着一个严格的表达式匹配。

## 小结

函数索引把表达式结果存进 B+ 树，专治"列被函数包住"的查询失效：`WHERE LOWER(email)=x`、`WHERE JSON_EXTRACT(...)=x`、`WHERE YEAR(dt)=y`。三条核心纪律：**查询表达式必须和索引逐字符匹配、优先尝试把函数改写回范围查询、只建确定性函数的索引**。和虚拟列的分工也清晰：一次性慢查询修援救函数索引，逻辑字段复用走虚拟列。索引篇到这里覆盖了索引类型的大部分版图——下一篇讲前缀索引，字符串索引省空间的取舍。
