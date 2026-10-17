# Skip Scan：不写前导列也能用上多列索引的黑科技

联合索引 `(gender, age)`，查询 `WHERE age = 25`——按最左前缀原则，gender 没出现在 WHERE 里，索引用不上，全表扫描。这是你学了索引第一天就记住的铁律。MySQL 8.0.13 的 **Skip Scan Range**（索引跳跃扫描）打破了这个铁律的一部分：**在特定条件下，跳过前导列也能走联合索引**。这篇文章讲它的原理、触发条件和适用边界。

## 问题：最左前缀的"信息死角"

```sql
CREATE TABLE user (
    id BIGINT PRIMARY KEY,
    gender TINYINT,     -- 只有 0/1/2 三个值
    age INT,
    INDEX idx_gender_age(gender, age)
);

-- 最左前缀铁律：没写 gender，用不上索引
SELECT * FROM user WHERE age = 25;
```

这个铁律背后的逻辑：联合索引按 (gender, age) 排序，第一层是 gender，gender 值相同的才按 age 排。优化器不知道 age=25 的行散落在哪些 gender 组里，索引的有序性帮不上定位。

但注意 gender 的特殊性——**它只有 3 个不同值**。MySQL 8.0 之后的优化器学会了"跳"：既然 gender 只有 3 种可能，我把每种都查一遍不就行了？

## Skip Scan 的执行逻辑

```
传统：无法定位 → 全表扫描
Skip Scan：
  1. 从索引里取出 gender 的去重值列表：[0, 1, 2]（索引跳跃，很快）
  2. 对每个 gender 值，在联合索引里定位 (gender, 25)：
     - gender=0 且 age=25 的范围
     - gender=1 且 age=25 的范围
     - gender=2 且 age=25 的范围
  3. 合并三次范围扫描的结果
```

执行计划特征（TRADITIONAL 格式 Extra 列）：

```
Using index for skip scan
```

TREE 格式里能看到多个 range scan 子节点或明显的 skip 标记。EXPLAIN FORMAT=JSON 里 `access_type` 是 `range`，配合 Extra 的 skip scan 标记。

## 触发条件：不是所有联合索引都能跳

Skip Scan 有明确的适用画像，三条同时满足：

**1. 查询只用了联合索引的后导列**。前导列没在 WHERE 出现（或只出现范围条件）。`WHERE gender = 1 AND age = 25` 是普通范围扫描，用不着跳。

**2. 前导列基数极低**。MySQL 内部有阈值——前导列不同值数量少（默认 `eq_range_index_dive_limit` 相关，以及 skip scan 自己的启发式）。**gender 3 个值可以，order_no 100 万个值不行**——跳 100 万次比全表扫还慢。优化器按成本估算，不值得时不会选。

**3. 后导列的选择性足够好**。`WHERE age = 25` 命中 5% 的行，跳 3 次值得；要是命中 80% 的行，跳来跳去扫了半张表，不如全表扫。

反过来，**执行计划里没有 skip scan 标记，就是没触发**。想强制它，用 optimizer hint：

```sql
SELECT /*+ SKIP_SCAN(user) */ * FROM user WHERE age = 25;
```

但强制之前先用 `EXPLAIN ANALYZE` 看优化器为什么没选——多半是它算过成本，跳了不划算。**Skip Scan 是启发式优化，不是万能钥匙**。

## 实战场景：三个典型用例

**场景一：状态位 + 时间的组合**。

```sql
-- 订单表 5000 万行，status 只有 4 种状态
CREATE INDEX idx_status_time ON orders(status, created_at);

-- 查最近一个小时的订单（不限定 status）
SELECT * FROM orders WHERE created_at >= NOW() - INTERVAL 1 HOUR;
-- Skip Scan：4 个 status 值分别跳，比全表扫 5000 万行快得多
```

这是 Skip Scan 的主场：**前导列低基数（状态、性别、类型）、后导列有时间范围**。传统写法下这个查询全表扫；加 skip scan 后执行计划变成 4 次范围扫描的合并。

**场景二：分区模拟**。

```sql
-- region 4 个值 + user_id 精确查
CREATE INDEX idx_region_user ON log(region, user_id);
SELECT * FROM log WHERE user_id = 12345;
```

region 4 个值跳 4 次 vs 全表扫 2 亿行。**区域日志的"跨区精确查"场景**，以前必须拆分区表或加冗余索引，现在一个索引搞定。

**场景三：多租户表上的全局查询**。

```sql
-- tenant_id 5 个值 + 业务键
CREATE INDEX idx_tenant_key ON order_item(tenant_id, sku);
SELECT * FROM order_item WHERE sku = 'ABC' AND qty > 10;
```

租户少的 SaaS 系统，运营侧查"全租户某 SKU 的订单"——跳过 5 个租户分别查。**这解决了"索引前导列租户 ID 导致跨租户查询全表扫"的经典架构矛盾**，虽然跳的次数有限，租户数不能涨。

## 边界与陷阱

1. **前导列基数涨了就失效**。今天 gender 3 个值跳得动，明天产品加了自定义性别 20 种，跳 20 次成本逼近全表扫，优化器自动放弃——**这不是问题，是保护机制**。但你的查询可能在基数变化后从毫秒回到秒级，监控盲区在这。
2. **只能跳范围，不能覆盖全部场景**。Skip Scan 官方定义是 "range access method"，WHERE 里后导列的范围条件才触发。后导列的函数、JOIN 条件不在这个能力圈。
3. **多范围合并的开销**。跳 3 次 range + 合并结果，比直接一次 range 慢——这就是为什么前导列写了的查询根本不会走 skip scan。别指望它替代最左前缀，它是"无奈之选"。
4. **版本红线**。MySQL 8.0.13+ 才有。MariaDB 没有这个特性，用 MariaDB 的团队别按这个设计。
5. **优化器误判时用 hint 校正**。跳得动但优化器因为统计信息失真选了全表扫，`/*+ SKIP_SCAN(t) */` 强制。反过来它选了跳但其实全表更快，`/*+ NO_SKIP_SCAN(t) */`。**hint 是核对统计信息之后的最后手段**。

## 与其他方案对比：什么时候宁可换索引

Skip Scan 是"不新建索引的优化"。但真实系统里你还有这些选择：

| 方案 | 做法 | 适用 |
|---|---|---|
| Skip Scan | 用现有联合索引跳 | 前导列低基数、临时优化、不想加索引 |
| 加后导列索引 | `CREATE INDEX idx_age ON user(age)` | age 查询高频、值得一个独立索引 |
| 列顺序翻转 | `(age, gender)` 替代 `(gender, age)` | 大部分查询不写 gender 只写 age——**这才是根治** |
| IN 显式展开 | `WHERE gender IN (0,1,2) AND age=25` | 让 SQL 自己展开，等价于告诉优化器怎么跳 |

**最容易被忽略的是第四种**——查询里显式写 `gender IN (0,1,2)`，优化器直接走普通范围扫描，行为确定且不需要依赖 skip scan 的启发式。基数低且已知时，这写法比赌优化器聪明更稳。

还有一个结构性判断：**若 gender 基数永远 3，age 查询是主场景，索引就该是 `(age, gender)`**——skip scan 存在不等于你可以把索引设计得随便。它是补丁，不是设计方法论。

## 小结

Skip Scan 让联合索引在前导列低基数、后导列高选择性的组合下"跳过前缀"也能用，执行计划里的 `Using index for skip scan` 是它的签名。低基数字段（状态、性别、区域）+ 后导时间/业务键的查询是它的甜区；前导列高基数、后导列低选择性时优化器自动放弃。别神话它——多数场景该问的是"索引列顺序对不对"，skip scan 只是不建新索引时的备选答案。
