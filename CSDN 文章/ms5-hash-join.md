# 哈希连接（Hash Join）：MySQL 8.0 给大表 JOIN 的答案

BNLJ 解决了"无索引也能 join"，但它的本质还是"扫多遍、比多次"。MySQL 8.0.32 正式 GA 的 **Hash Join** 换了一条路：**一次建哈希，一次探测，把比较的复杂度从 O(N×M) 压到 O(N+M)**。这篇文章把 hash join 的机制、参数、内存管理和调优场景讲透——它可能是 MySQL 近年来对开发者影响最大的一个执行器改动。

## 算法机制：两阶段

哈希连接分两个阶段，所有教科书都这么画：

```
Build 阶段：
  扫描输入 A（通常是预估行数少的那张）
  对每行的连接键值计算哈希值
  把行存入内存哈希表（键 = 连接列值）

Probe 阶段：
  扫描输入 B
  对每行连接键计算哈希
  在哈希表中查找匹配
  命中 → 组合输出
```

为什么 A 通常是"小表"？**哈希表装的是 A，内存是这里的稀缺资源**。优化器会把预估行数小、行宽窄的表放 build 侧。这跟嵌套循环的"驱动表"逻辑相反——嵌套循环里小表也驱动，但 hash join 里小表是被"装进哈希"的那张。读执行计划时注意别搞混驱动方向。

执行计划里的形态（TREE 格式，8.0.32+）：

```
-> Hash join  (cost=...)
    -> Table scan on o                          (Probe 侧)
    -> Table scan on c
        -> Hash
            -> Index range scan on c using idx_type (type='vip')
                                                          (Build 侧)
```

看到 `Hash join` 节点，子节点里带 `Hash` 标记的就是 build 侧。

## 为什么快：省的是扫描遍数

对比同样两张大表各 1000 万行的等值 join：

| 算法 | 被驱动表扫描遍数 | 比较次数 |
|---|---|---|
| 朴素嵌套循环 | 1000 万 | 10^14 |
| BNLJ（buffer 装 1 万行） | 1000 | 10^10 |
| Hash Join | **1** | 10^7 哈希查找 |

哈希查找是 O(1) 均摊，比逐行比较快得多。**一次全表扫描 + 一次哈希查找流**，这就是大表 join 从"分钟级"进"秒级"的原因。代价是 build 侧要全量驻留内存（或落盘分区），所以它不适合"驱动表巨大且无法过滤"的场景。

## 内存管理：哈希表装不下怎么办

这是 hash join 的工程核心。`join_buffer_size` 仍然是它的内存预算（和 BNLJ 共享这个参数），哈希表超出预算时的行为：

**正常路径**：build 侧哈希表装进 buffer，探测侧流式扫一遍，结束。

**溢出路径（Grace Hash Join）**：哈希表超预算时，MySQL 把 build 侧按哈希值**分区**写到磁盘临时文件（平均分成 R 个分区，每个区最终能装进内存），然后对每个分区：load 进内存 → 用探测侧对应分区的行 probe。探测侧同样先按同样的哈希函数分区。

这就是"grace hash"：两次磁盘往返换来内存可控。代价是临时文件 IO——所以 `join_buffer_size` 太小会让 hash join 退化成"写盘 + 读盘"的 BNLJ 变体，反而更慢。

调参实践：

```sql
SET SESSION join_buffer_size = 32 * 1024 * 1024;  -- 大表 join 会话级调大
```

- 默认 256KB 对 hash join 偏小——**build 侧轻易溢出**。生产建议：跑批/报表会话显式调 8~64MB，OLTP 保持默认避免并发 OOM。
- 溢出临时文件在 `tmpdir`，用 `SHOW STATUS LIKE 'Created_tmp_disk_tables'` 观察磁盘临时表增量。
- 8MB buffer 装 1000 万行 build 侧？装不下，必然走 grace 路径。这时候要么加 WHERE 把 build 侧砍小，要么老老实实加索引走嵌套循环。

## 优化器什么时候选它

8.0.32 的 hash join 选择逻辑（简化）：**等值连接、估算成本优于 BNLJ/嵌套循环、且内存够或可溢出的场景**。具体来说：

- **无索引大表等值 join**：优先 hash join。这是它的主场。
- **有索引小表**：优化器往往仍选索引嵌套循环——点查 B+ 树比建哈希便宜，尤其被驱动表有唯一索引时。
- **非等值连接**：只能 BNLJ（上一篇讲过），hash join 不支持。
- **外表是巨大分区表**：如果 build 侧选了大表，宁可强制 join order，让小的走 build。

可以用 hint 精确控制：

```sql
SELECT /*+ HASH_JOIN(o, c) */ * FROM o JOIN c ON o.id = c.o_id;
SELECT /*+ NO_HASH_JOIN(o, c) */ ...   -- 禁用 hash join
SELECT /*+ JOIN_ORDER(c, o) */ ...     -- 固定 c 为 build 侧（驱动）
```

## 实战：一条 40 秒报表的重生

场景：用户行为日志（5 亿行，按 dt 分区）关联用户分群表（800 万行）做留存分析：

```sql
SELECT s.cohort, COUNT(DISTINCT l.user_id)
FROM behavior_log l
JOIN user_segment s ON s.user_id = l.user_id
WHERE l.dt BETWEEN '2026-09-01' AND '2026-09-30'
  AND l.event = 'login';
```

原始执行计划：behavior_log 走分区裁剪扫 5 亿行（dt + event 无联合索引）→ 与 user_segment 做 BNLJ。BNLJ 下 user_segment 被反复扫描，40 秒。

第一步诊断（EXPLAIN ANALYZE）：瓶颈不在 join 算法本身，是驱动表 5 亿行没被过滤收窄。修复：加 `(event, dt)` 联合索引，驱动行降到 2 亿仍然巨大。

第二步：引导 hash join。2 亿行探测 + 800 万 build，加入 hint：

```sql
SELECT /*+ HASH_JOIN(l, s), JOIN_ORDER(s, l) */ ...
```

s（800 万行走 idx 后 build 侧）建哈希，l 2 亿行探测。配合会话级 `join_buffer_size=32MB`，执行时间 40s → 6.5s。剩余时间花在扫 2 亿行上——真要更快，得缩小 dt 范围（业务上一天天跑）或者预聚合。**调优是收益递减的，6.5 秒的报表如果一天跑一次，已经够了。**

## Hash Join 的已知坑

1. **临时文件炸弹**。并发的 grace hash join 同时写 tmpdir，磁盘 IO 打满时拖垮整个实例。监控 `Created_tmp_disk_tables`，把大 join 放低峰期或离线库跑。
2. **和 SSL/加密场景的 CPU 叠加**。哈希计算纯 CPU 活，加密连接的 CPU 开销叠加上来，效果打折。内网跑批用明文连接。
3. **版本兼容**。8.0.32 之前要用 `SET SESSION optimizer_switch='hash_join=on'` 开实验特性，并且行为不稳定；**生产以 8.0.32+ GA 版为准**，别在旧版本上玩 hint。
4. **EXPLAIN 误读**。TREE 格式的 Hash join 节点子节点顺序不代表 build/probe 顺序，认准 `Hash` 标记的子树才是 build 侧。

## 小结

Hash join 用 O(N+M) 的算法优势终结了"无索引大表 join 必跪"的历史，代价是内存预算和可能的临时文件。调优三要素：**build 侧要小（WHERE 过滤 / join order 引导）、内存要够（join_buffer_size 按场景调）、临时 IO 要看（低峰跑 + 监控）**。等值连接的天下已经是它的，非等值和小表点查仍是 BNLJ 和索引嵌套循环的领地。下一篇看 semi-join——MySQL 优化 IN/EXISTS 子查询的六种武器。
