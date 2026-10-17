# JOIN 算法选择：优化器怎么在嵌套循环与哈希连接之间做决定

前面四篇我们都在读执行计划，现在开始动 JOIN 本身。一条两表 JOIN 的 SQL，优化器要在几十种执行方式里挑一个：驱动表选哪张、用什么 JOIN 算法（嵌套循环还是哈希）、走哪个索引、Join Buffer 开多大。这篇文章把这些决策逐个拆开，讲清优化器的选择逻辑——理解了它，你才能引导它，而不是被它气到。

## 决策一：驱动表选哪张

JOIN 的最底层问题是**谁驱动谁**。嵌套循环 join 里，外层循环遍历驱动表的每一行，内层对每行去被驱动表查匹配。工作量的经验公式：

```
总成本 ≈ 驱动表行数 × 被驱动表单次查找成本
```

单次查找成本由被驱动表的访问方式决定（索引点查远低于全表扫描）。所以优化器选驱动表的核心逻辑是：**让"行数 × 单次成本"最小的那张当驱动表**。

看一个例子：

```sql
SELECT * FROM orders o JOIN customer c ON o.customer_id = c.id
WHERE o.status = 'PAID';
```

假设 orders 有 100 万行，status='PAID' 的有 5000 条（有索引），customer 有 5 万行。两种方案：

- **orders 驱动**：5000 行 × customer 主键点查（单次成本低）= 5000 次点查。优化器几乎一定选这个。
- **customer 驱动**：5 万行 × orders 的 customer_id 索引查找（大概率也走索引）= 5 万次查找，而且其中绝大多数订单不满足 status='PAID'，白白查了。

**WHERE 条件能大幅收窄哪张表，那张表就该当驱动表**——这就是"小表驱动大表"的真相。注意这个"小"不是表小，是**过滤后参与 JOIN 的行数少**。一张百万行的表，WHERE 一过滤只剩几百行，照样是驱动表。

优化器依据什么预估行数？索引的区分度（cardinality）、直方图（8.0+）、行数采样。预估错了，驱动表就选错——这时你可以用 `STRAIGHT_JOIN` 强制顺序，但先要搞清楚它为什么估错（多半是统计信息过期，`ANALYZE TABLE` 就修好了）。

## 决策二：JOIN 算法用哪种

MySQL 8.0.32 之前只有一种：**块嵌套循环（BNL）**；之后 hash join 正式转正，优化器多了一个选择。

### 嵌套循环（Nested Loop）

```
for 驱动表第 i 行:
    用 join 条件去被驱动表查匹配（走索引）
```

适用场景铁律：**被驱动表的 join 列有索引**。每次查找是一次 B+ 树点查，复杂度 O(驱动表行数 × log(被驱动表))。没有索引时退化成"每驱动行全扫被驱动表"，那是 O(n×m) 的灾难。

8.0.32 之前的 BNL：无可用索引时，把驱动表的相关列装进 join buffer（一块内存缓冲区），批量比较，减少被驱动表的扫描次数。本质是"用内存换扫描次数"，比朴素嵌套循环快，但比 hash join 仍差一截。

### 哈希连接（Hash Join，8.0.18 实验 / 8.0.32 GA）

```
build 阶段：扫描被驱动表，join 列的值做哈希表装进内存
probe 阶段：驱动表逐行，拿 join 列值去哈希表探
```

复杂度 O(n + m)——**不需要索引**，一次扫描建哈希，一次扫描探测。这是算法层面的降维打击，但有前提：哈希表要装得进 `join_buffer_size`（可配到几百 MB）。装不下就退化为磁盘哈希（分区落盘再合并），性能打折，但通常仍优于 BNL。

### 优化器怎么选

判据（简化版）：

| 条件 | 选择 |
|---|---|
| 被驱动表 join 列有可用索引 | 嵌套循环（索引查找足够快） |
| 无索引，或预估驱动行数大 + 被驱动表能一次建哈希 | 哈希连接 |
| 估算哈希表超内存 | BNL 或磁盘哈希 |
| 等值连接 | 两者皆可，优化器比成本 |
| 非等值（<、>、BETWEEN） | **只能嵌套循环**（哈希不适用范围） |

注意最后一条：`ON a.amount < b.threshold` 这种范围 JOIN，哈希连接天然不支持，只能嵌套循环。这类查询慢，不是索引问题，是算法问题——要么改写成等值、要么用 range 索引的嵌套循环。

### 怎么确认用了哪种

```sql
EXPLAIN SELECT ...
```

- `Nested loop inner join`：嵌套循环。子节点顺序即驱动顺序。
- `Hash join`（8.0.32+）：直接显示。
- `Nested loop ... Using join buffer (hash join)`：8.0.32 之前用 HJ hint 开了哈希的特征。

想强制某一种，可以用 optimizer hint：

```sql
SELECT /*+ NO_HASH_JOIN(o, c) */ ...          -- 禁哈希
SELECT /*+ HASH_JOIN(o, c) */ ...             -- 强制哈希
SELECT /*+ JOIN_ORDER(o, c) */ ...            -- 固定驱动顺序
```

**hint 是最后手段，先用好 `ANALYZE TABLE` 和 EXPLAIN ANALYZE 诊断。**

## 决策三：连接顺序（多表 JOIN）

多表 join 的排列组合是阶乘级爆炸，优化器不可能穷举所有顺序。它用的是**贪心 + 剪枝**：从成本最低的单表访问开始，逐步把"加入后总成本最低"的表接进来，用系统变量控制搜索深度（`optimizer_search_depth`，默认 62 够用）。

实践中，你可能遇到"明明换一下 ORDER 更快，优化器就是不换"的情况。三个原因：

1. **统计信息误导**：某张表的预估行数被大幅低估，导致它永远被优先选中。`ANALYZE TABLE` + 直方图修正。
2. **搜索深度不够**：表多（10+）且每张都有索引可选时。提高 `optimizer_search_depth` 或干脆用 `STRAIGHT_JOIN` 手写顺序。
3. **隐式转换打断索引**：连接两列字符集/类型不同（`utf8` join `utf8mb4`，或 int join varchar），索引直接失效。这类"优化器再聪明也没用"的坑，靠读 EXPLAIN 的 access_type 发现。

## Join Buffer 的调与实践

块嵌套循环和 hash join 都依赖 join buffer（`join_buffer_size`，默认 256KB）：

- **调大**（1~8MB）对多表 join 加速明显，尤其无索引的扫描型 join。
- **每个 join 单独分配**：一条 SQL 里 4 个 join 就可能占 4 份 buffer，N 个并发连接就是 4N 份。设太大容易 OOM，**单连接 8MB 是经验上限，调完要盯 `Threads_created` 和内存水位**。
- 调它属于"缓解无索引之痛"，治本还是加索引。

## 实战：一条 JOIN 的完整诊断

```sql
-- 慢查询：日均报表，跑了 8 秒
SELECT o.order_id, SUM(oi.qty * oi.price)
FROM orders o
JOIN order_item oi ON oi.order_id = o.order_id
WHERE o.created_at BETWEEN ? AND ?
  AND o.channel = 'app';
```

诊断流程：

1. **EXPLAIN 看驱动顺序**。如果 orders 没走 created_at 索引而全表扫描 1000 万行，先解决这个：`o` 需要 `(created_at, channel)` 联合索引，或者 `(channel, created_at)`——哪个前导列选择性高？
2. **看 JOIN 算法**。如果 order_item 没走 order_id 索引，BNL 扫 500 万行 × 过滤器ning。给 `order_item(order_id)` 加索引，算法切换成嵌套循环点查。
3. **EXPLAIN ANALYZE 验证**。加完索引后跑 ANALYZE：nested loop 的 loops 数 = 驱动行数，每次 rows 应该降到个位数。
4. **确认无隐式转换**。order_id 两边都是 bigint，channel 两边都是 varchar(16) 同字符集。

修完之后这条查询回到 200ms 级别——三个动作分别对应"驱动表收窄""被驱动表索引""类型对齐"，就是 JOIN 优化的标准三段论。

## 小结

JOIN 优化的本质是帮优化器做好三个决定：**驱动表（过滤后小的驱动大的）、连接算法（有索引用嵌套循环，无索引大表用哈希）、连接顺序（贪心搜索，统计信息要准）**。EXPLAIN 告诉你它做了什么决定，EXPLAIN ANALYZE 告诉你这个决定对不对，ANALYZE TABLE 和 hint 是你的干预手段。下一篇深入两个 JOIN 算法的内部实现——块嵌套循环和哈希连接的机制与适用边界。
