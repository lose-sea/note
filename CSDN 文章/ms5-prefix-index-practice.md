# 前缀索引：给长字符串列省空间的取舍

用户表的 `email`、订单表的 `out_trade_no`、日志表的 `url`——字符串列上建索引是刚需，但整列做索引键时存储和比较的开销都大。**前缀索引**只取列的前 N 个字符建索引，用一部分磁盘换一部分性能。这篇文章讲它的机制、前缀长度怎么选、什么时候划算，以及它和哈希列方案的对比。

## 前缀索引的机制：截断才有空间

```sql
-- 完整列索引
CREATE INDEX idx_email ON user(email);              -- utf8mb4，每键存全值

-- 前缀索引：只存前 10 个字符
CREATE INDEX idx_email_p10 ON user(email(10));
```

B+ 树里索引记录只存 `email` 的前 10 个字符。100 万个平均 40 字符的邮箱，全列索引键约 4GB 量级，前缀 10 字符约 1GB——**索引体积直接砍到四分之一**。字符串比较也从"40 字符 vs 40 字符"变成"10 字符 vs 10 字符"。

代价写在冰面上：**前缀相同的行，索引层区分不了**。`alice001@a.com` 和 `alice002@a.com` 前 10 字符都是 `alice001@` 和 `alice002@`——拆开没问题，但如果两人是 `alice001@a.com` 和 `alice001@b.com`，前 10 字符完全一样，索引查找后必须**回表逐行比对完整值**。回表行数 = 前缀碰撞数，这就是前缀索引的隐性成本。

## 前缀长度怎么定：5% 重复率经验法则

长度选短了，碰撞多、回表多；选长了，省不下空间还多花钱。业界的经验法则：**让前缀的不同值数量达到全列不同值数量的 95% 左右**。

```sql
-- 逐步试：看每个长度下有多少个不同前缀值
SELECT COUNT(DISTINCT email) AS full_dcnt,
       COUNT(DISTINCT LEFT(email, 5))  AS p5,
       COUNT(DISTINCT LEFT(email, 8))  AS p8,
       COUNT(DISTINCT LEFT(email, 10)) AS p10,
       COUNT(DISTINCT LEFT(email, 12)) AS p12
FROM user;
```

选让 `pN / full_dcnt >= 0.95` 的最小 N。上面的例子如果 p10 是 99.8 万 / full 100 万（99.8%），p8 是 95 万（95%），选 10——**别只看比例，要看查重后的回表率**：

```sql
-- 平均碰撞行数：前缀相同的行，每组有多少
SELECT AVG(cnt) FROM (
    SELECT COUNT(*) AS cnt FROM user GROUP BY LEFT(email, 10)
) t;
```

平均每组 1.05 行 = 回表成本可控；平均 3 行 = 每次查询回表 3 行，前缀长度该加。

## 什么时候用前缀索引

三个判断维度：

**1. 字符串列长且前缀区分度高**。姓名（前 3 字重复率高的中文场景不适用）、URL（路径部分区分度在域名后）、订单号（前 6 位通常是日期+商户）。**前缀区分度必须先测，不能拍脑袋**。

**2. 查询模式是等值/前缀匹配**。`WHERE email = 'x'`、`WHERE url LIKE 'https://a.com/%'`（LIKE 前缀匹配正好可以用上前缀索引）。范围查询 `WHERE email > 'a'` 也能用，但前缀截断让范围边界模糊。

**3. 写压力不大**。前缀索引的键短，写放大小——这反而是它的优点。

反例场景：**短字符串不要用**。`status CHAR(1)`、`type VARCHAR(10)`——截断省不下几个字节，还引入回表，纯亏。**前缀索引服务的是长字符串**。

## 前缀索引的局限清单

1. **不能覆盖索引**。索引里只存前缀，查询要输出完整列必须回表。`SELECT email FROM user WHERE email = 'x'` 走不到覆盖索引扫描，全字段查询场景性价比打折。
2. **不能用于排序和分组**（准确说：优化器不知道截断前缀能否代表完整值排序，`ORDER BY email` 不能直接用前缀索引的有序性，要 filesort）。`GROUP BY email` 同理。
3. **JOIN 连接列慎用**。被驱动表用前缀索引做连接键，每个驱动行回表比对，join 成本随碰撞率线性涨。
4. **唯一约束不适用**。`UNIQUE(email(10))` 的语义是"前 10 字符唯一"——两个不同邮箱前 10 字符相同就会被判冲突（真正的语义错误）或者需要 InnoDB 额外机制，MySQL 直接不允许这种用法成立完整约束。

## 替代方案：哈希列索引

前缀索引的"碰撞痛点"，另一个解法是**把长字符串哈希成定长值再索引**：

```sql
ALTER TABLE user ADD COLUMN email_hash BINARY(16)
    AS (UNHEX(MD5(email))) STORED,
    ADD UNIQUE INDEX idx_email_hash(email_hash);
-- 查询带哈希
SELECT * FROM user WHERE email_hash = UNHEX(MD5('alice@a.com')) AND email = 'alice@a.com';
```

对比：

| 维度 | 前缀索引 | 哈希列索引 |
|---|---|---|
| 键长 | N 字符（可变） | MD5 16 字节 / SHA1 20 字节（定长） |
| 碰撞 | 有（前 N 同） | 极低（MD5 128 位） |
| 范围/LIKE 查询 | 前缀 LIKE 可用 | 不可用 |
| 唯一约束 | 不可用 | **可用** |
| 查询写法 | 直接 | 必须同时带原列条件（防哈希碰撞） |
| 存储计算 | 截断即可 | 每行算哈希 |

**选择规则**：查询模式是等值 → 哈希列（碰撞可控、能做唯一索引）；需要 LIKE 前缀/范围 → 前缀索引。**两者都不覆盖排序分组场景**——那是覆盖索引的领域。

## 实战：URL 表的前缀索引设计

```sql
CREATE TABLE crawl_url (
    id BIGINT PRIMARY KEY,
    url VARCHAR(2048) NOT NULL,
    ...
);
```

5000 万行 URL，要支持"按域名查该域名下的 URL"，也要支持精确 URL 查重。

方案设计两步走：

```sql
-- 方案一：域名虚拟列 + 索引（支持域名聚合）
ALTER TABLE crawl_url ADD COLUMN domain VARCHAR(255)
    AS (SUBSTRING_INDEX(SUBSTRING_INDEX(url, '//', -1), '/', 1)) STORED,
    ADD INDEX idx_domain(domain);

-- 方案二：完整 URL 去重 → 哈希列唯一索引（等值查重）
ALTER TABLE crawl_url ADD COLUMN url_hash BINARY(32)
    AS (UNHEX(SHA2(url, 256))) STORED,
    ADD UNIQUE INDEX idx_url_hash(url_hash);
```

为什么不用前缀索引？URL 的前 10 字符全是 `https://ww`、`https://do`——**前缀区分度极差**，前缀长度得取到 60+ 才有效，那时省空间的意义也没了。URL 场景的前缀测试会直接否定这条路，改走哈希。

这就是前缀索引的落地纪律：**先测再建**。拿 `COUNT(DISTINCT LEFT(col, N))` 在真实数据上跑一遍，数据说长度，不是经验说长度。

## 小结

前缀索引用"截断前缀建索引"换存储和比较效率，适合长字符串、等值前缀查询、前缀区分度高的列。设计三步：测区分度定长度（95% 不同值法则）、验证回表碰撞率、确认查询模式不触碰覆盖/排序/唯一这些盲区。等值查重场景记得隔壁的哈希列方案。索引优化到这里，下一篇讲索引家族里最"重"的操作——跳过前缀的 Skip Scan Range。
