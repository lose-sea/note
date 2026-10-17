# 多列索引列序设计：不止是"最左前缀"四个字

建联合索引时把哪列放前面？这个问题的标准答案是"最左前缀匹配"——但真到设计场景，你会发现它只解释了"查询怎么用索引"，没回答"索引该怎么建列顺序"。这篇文章把列序设计的完整决策框架给出来：等值列、范围列、排序列、基数，四个维度各有什么规矩。

## 重温最左前缀：一个不完整的答案

```sql
CREATE INDEX idx_abc ON t(a, b, c);

-- 能用上索引的查询：从左往右连续匹配
WHERE a = 1               -- ✅ 用到 a
WHERE a = 1 AND b = 2     -- ✅ 用到 a, b
WHERE a = 1 AND b = 2 AND c = 3   -- ✅ 全用
WHERE b = 2               -- ❌ 从中间断，a 没用上
WHERE b = 2 AND c = 3     -- ❌ 同上
WHERE a = 1 AND c = 3     -- ⚠️ 只用到 a（c 是跳过 b 的，只能回表过滤）
```

铁律是"从左往右连续使用"。但只看这条会漏掉 80% 的真实决策——列顺序的真正学问在下面。

## 原则一：等值列在前，范围列在后

**同一层级里，等值条件的列放前面，范围条件的列放后面**——这是列序设计的头号规则。

```sql
-- 慢：范围在前，等值在后
CREATE INDEX idx_wrong ON orders(status, created_at);
SELECT * FROM orders WHERE created_at > '2026-01-01' AND status = 'PAID';
-- status 用上后，created_at 的范围在 status 值内做范围扫——如果 status 3 个值，每个值内扫 created_at
-- 看起来很对？换个顺序看反例

-- 对：等值在前，范围在后
CREATE INDEX idx_right ON orders(status, created_at);
-- 同样的索引！关键在于 WHERE 条件写法与索引列序的匹配：
SELECT * FROM orders WHERE status = 'PAID' AND created_at > '2026-01-01';
-- 先 status='PAID' 等值定位，再在 PAID 组内 created_at 范围扫
```

上面两个例子同一个索引，区别在 WHERE 的列顺序无所谓——**优化器不看你 WHERE 怎么写，它按索引列序匹配**。真正决定性能的是**索引列序本身**：

```sql
-- 反例设计：范围列在前，等值列在后
CREATE INDEX idx_bad ON orders(created_at, status);
SELECT * FROM orders WHERE status = 'PAID' AND created_at > '2026-01-01';
```

`created_at` 范围扫描先筛出大段数据，`status = 'PAID'` 只能在这个大段里回表过滤。**范围列一旦放前面等值列，等值列的选择性再强也用不上**——B+ 树没法在"created_at > x" 这个连续大范围里直接跳到 status='PAID' 的子区。

口诀：**先等值定位一个点，再范围扫一小段**。反过来的顺序，范围先扫一大片，等值只能擦屁股。

## 原则二：把 ORDER BY / GROUP BY 的列纳入设计

排序和分组不产生过滤，但它们对索引有序性有强需求——**设计列序时把排序列放最后，且方向一致**：

```sql
-- 高频查询：某用户的订单按时间倒序
SELECT * FROM orders WHERE user_id = 12345 ORDER BY created_at DESC LIMIT 20;

-- 好索引：(user_id, created_at)——等值定位用户，索引天然按时间有序
CREATE INDEX idx_user_time ON orders(user_id, created_at);
-- 无 filesort，LIMIT 20 走 20 行就停

-- 坏索引：created_at 在前
CREATE INDEX idx_bad ON orders(created_at, user_id);
-- user_id 等值后…… 不对，user_id 在前导列 created_at 范围之后根本用不上
-- ORDER BY created_at 还要 filesort
```

**关键动作**：设计联合索引时，把"过滤列 + 排序列"组装成一个整体，过滤列在前定位，排序列殿后提供有序性。`(用户, 时间)` 是互联网系统最高频的索引形状——用户对话、订单、日志，全都这个模式。

**方向一致性**：MySQL 8.0 支持混合方向索引：

```sql
CREATE INDEX idx_mixed ON orders(user_id ASC, created_at DESC);
-- 完美匹配 WHERE user_id = x ORDER BY created_at DESC
```

倒序索引让"正序查用户、倒序查订单"两种模式都免 filesort。不是所有查询都值得——普通升序 `(user_id, created_at)` 也能服务 ORDER BY created_at ASC；DESC 场景才需要混合方向索引。

**GROUP BY 同理**：`GROUP BY user_id, DATE(created_at)` 这种，函数包住的列用不上普通索引——需要函数索引或改写范围（上一篇讲过）。

## 原则三：基数不是列序的决定因素

新手常见误区："把基数高的列放前面，区分度大所以先筛它"。**错**。基数（不同值的数量）决定的是"这个索引值不值得建、选择性好不好"，不决定列顺序。列序由**查询模式**决定：

```sql
-- status 基数 3，user_id 基数百万
-- 查询总是 WHERE user_id = x AND status = 'y'
CREATE INDEX idx ON orders(status, user_id);   -- 错的理由不是 status 基数低

-- 为什么错：status 等值后是 1/3 的数据，user_id 在 status 组内做等值——其实也能用！
-- 但换个查询模式就死：WHERE user_id = 12345（不带 status），status 前导没写，整个索引作废
```

**真正的判据**：把最常被单独查的列放前面。user_id 出现在所有查询里、status 只出现在一半查询里 → `(user_id, status)`。索引是查询模式的投影，不是数据分布的投影。

基数的作用在另一处：**决定要不要单独建索引**。user_id 基数百万，单独一个 `(user_id)` 索引可能值得；status 基数 3，单独索引优化器都懒得用（全表扫 3 选 1 可能更快）。基数低到一定程度的列，放进联合索引当前导都是浪费——除非它是 Skip Scan 的场景（上一篇）。

## 原则四：窄列优先与覆盖预留

同等贡献下，**窄列放前面**。索引键短，一个页放更多记录，树更矮，IO 更少：

```sql
-- user_id BIGINT(8字节) vs status TINYINT(1字节)
-- (status, user_id) 比 (user_id, status) 索引体积略小
-- 但上一篇说了列序由查询模式定——两者冲突时查询模式优先
-- 窄列优先只在"列序无差别"时做 tiebreaker
```

更高级的打法是**为覆盖索引预留空间**。覆盖索引（Using index）免回表，查询的 SELECT 列也要考虑进索引设计：

```sql
SELECT user_id, status, amount FROM orders WHERE user_id = 12345;
-- (user_id) 索引：回表取 status 和 amount
-- (user_id, status, amount) 索引：覆盖，不回表
-- 但索引变大，写变慢——覆盖是要付费的
```

覆盖索引的决策看查询频率：高频查询值得用覆盖换读性能，一次性查询别惯着。**order_id 这样的查询，SELECT 列少就设计覆盖；管理后台的 select * 查询永远别指望覆盖**。

## 实拍案例：订单表索引重构

```sql
-- 原始索引
CREATE INDEX idx_time ON orders(created_at);          -- 按时间查
CREATE INDEX idx_user ON orders(user_id);              -- 按用户查

-- 实际查询模式（日志统计 Top 3）：
-- Q1: WHERE user_id = x ORDER BY created_at DESC LIMIT n     占 60% 流量
-- Q2: WHERE user_id = x AND status = 'PAID'                  占 25%
-- Q3: WHERE created_at BETWEEN ... AND status = 'PAID'       占 15%

-- 重构后
CREATE INDEX idx_user_time ON orders(user_id, created_at);
-- Q1 免 filesort 走 20 行（原方案 user_id 索引 + filesort 全量排序）
CREATE INDEX idx_time_status ON orders(created_at, status);
-- 注意 Q3 是范围 created_at 在前——这是它的查询形态决定的（没有等值前导列可用）
```

idx_user_time 服务了 85% 的流量，idx_time_status 服务剩下 15%。原方案 Q1 慢（filesort）、Q3 全表扫（status 没索引）。**重构思路就是"数查询模式，按模式组索引"**——不是拍基数，不是抄模板。

## 自检清单：设计联合索引时问自己

1. 查询的等值列是哪些？放前面。
2. 查询的范围列是哪些？放后面，范围列之后不再放列（后面的列在范围内只能回表过滤）。
3. 查询的 ORDER BY/GROUP BY 列是哪些？殿尾提供有序性，方向要不要混合？
4. 哪几个列单独出现在查询里？它们该做前导。
5. 高频查询的 SELECT 列能不能塞进索引做覆盖？值不值得？
6. 有没有低基数列该当前导的错觉？跳scan 场景单独评估。

六个问题过一遍，比背十遍"最左前缀"管用。**最左前缀是表象，查询模式的投影才是本质**。

## 小结

联合索引列序设计的四原则：等值前范围后、排序列殿尾、查询模式定前导（而非基数）、窄列和覆盖做微调。判断标准永远是这套索引服务哪些查询、查询长什么样——列序是查询模式的函数。下一篇讲索引的选择性与基数：怎么量化一个索引"好不好"。
