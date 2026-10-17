# EXPLAIN TREE 格式：逐层读执行计划，从根节点看穿 JOIN 顺序

前面讲了 EXPLAIN ANALYZE 实测执行，这篇回头讲最常用的 EXPLAIN 本身。MySQL 8.0.16 之后默认输出变成了 **TREE 格式**——比老表格格式更能体现"计划是棵树"这个事实。读树有读树的方法：从根到叶，逐层剥开。这篇文章讲清每一层在问什么、从哪里读，把执行计划彻底变成你随手可查的工具。

## 为什么是树，而不是表

老版 EXPLAIN 表格的经典痛点：join 顺序要"从下往上找第一个非 eq_ref/ref 的表"，id 相同时按执行顺序排列，一套规则记半天。树格式直接把这个认知过程固化了——**根节点是最后执行的操作，叶子节点是最先执行的**。子节点先算完，父节点拿子节点的结果。LET 的 EXPLAIN 输出：

```sql
EXPLAIN SELECT o.id, oi.qty FROM orders o
JOIN order_item oi ON oi.order_id = o.id
WHERE o.status = 'paid' AND oi.qty > 100;
```

```
-> Nested loop inner join  (cost=1780.15 rows=187)
    -> Nested loop inner join  (cost=1208.08 rows=864)
        -> Index lookup on o using idx_status (status='PAID')  
            (cost=67.20 rows=418)
        -> Index lookup on oi using idx_order_id (order_id=o.id)  
            (cost=1.42 rows=4)
    -> Index lookup on p using idx_order_id (order_id=oi.order_id)  
        (cost=0.35 rows=3)
```

（这个例子简化过，真实输出会更复杂，但树的结构不变。）

## 读树四步法

### 第一步：找到根，知道"最后一步在做什么"

根节点是整个查询最终形态的操作：Limit（分页）、排序、聚合、Distinct、临时表物化。本例根节点是 Nested loop inner join——最终结果由三表连接产生。**根节点告诉你这个查询的"长相"**：如果根是 `Sort` + `Limit`，你要关心排序是否用索引、临时文件；如果根是 `Stream results`，恭喜，没有物化，全流式。

### 第二步：逐层往下，每个子树是"一个数据来源"

嵌套循环节点的每个子节点就是一个被连接的表/数据源。从上到下数子节点的顺序，**第一个子节点是驱动表，后面是被驱动表**。这是树格式比表格格式直观的地方——驱动关系变成树形结构，不用再翻 id 列。

本例：驱动表是 o（用 idx_status），然后连接 oi，再连接 p。连接顺序直接印在结构上。

### 第三步：看叶子，追踪"每次数据访问的代价"

叶子节点是真正的表访问操作。常见的几种：

| 叶子形态 | 含义 | 优化方向 |
|---|---|---|
| `Table scan on t` | 全表扫描 | 加索引，或确认必须全扫的数据量是否可接受 |
| `Index scan on t using idx_x` | 索引扫描（回表） | 宽索引、覆盖索引尝试 |
| `Index range scan on t using idx_x` | 索引范围扫描 | 范围是否过宽，联合索引列序 |
| `Index lookup on t using PRIMARY (col=...)` | 聚簇索引点查 | 通常最优 |
| `Single-row index lookup` | 唯一索引等值查 | 无需优化 |
| `constant row` | 常量表，查一次 | — |

每个叶子后面跟着 `(cost=起始..总 cost=总 cost)` 和 `rows=预估行数`。cost 是优化器的内部成本单位，跨查询比较没意义，**同一查询的不同子树之间比较才有意义**。

### 第四步：看连接方式的特殊标记

子节点上常见的连接算法标记：

- `Nested loop inner join` / `Nested loop left join`：嵌套循环。内层每个被驱动表行都走一次索引查找。判断依据是 loops（EXPLAIN ANALYZE 里看）。
- `Hash join`（8.0.18+）：哈希连接。大数据量等值连接的利器，优化器自动在合适场景选。**被驱动表没索引时，SQL 也能跑快了**。
- 标记 `Using join buffer (hash join)`：使用 join buffer 块嵌套循环，被驱动表无可用索引时的兜底。

## 三种输出格式全家福

| 格式 | 语法 | 特点 | 适用场景 |
|---|---|---|---|
| TREE（默认，8.0.16+） | `EXPLAIN SELECT ...` | 树形，最贴近执行逻辑 | 日常读计划 |
| TRADITIONAL | `EXPLAIN FORMAT=TRADITIONAL SELECT ...` | 老表格格式，字段全（Extra 列信息量大） | 看 Using where/filesort/temporary 标记 |
| JSON | `EXPLAIN FORMAT=JSON SELECT ...` | 机器可读，字段最全 | 程序化处理、深挖细节 |

一个常见困惑：TREE 格式里没有了 `Using filesort` / `Using temporary` 这类老标记——它们没消失，只是变成树里的显式节点（`Sort` / `Temporary table`）。TREE 格式下物化操作从"Extra 里的一个标记"升级为"树上可见的一层"，这是进步：你能看到临时表是在哪一步产生的。

## 树格式实战：三表 JOIN 的优化推演

上个例子继续。EXPLAIN 显示：

```
-> Nested loop inner join  (cost=1780.15 rows=187)
    -> Index range scan on o using idx_status (status='PAID')  (rows=418)
    -> Index lookup on oi using idx_order_id (order_id=o.id)  (rows=4)
    -> Index lookup on p using idx_order_id (order_id=oi.order_id)  (rows=3)
```

三个判断：

1. **驱动表选得对**。`status = 'PAID'` 用到了 idx_status，预估 418 行。如果实际 PAID 的订单占了全表 60%，范围扫描就退化成接近全表——EXPLAIN 的 rows 与全表行数一对比就知道。
2. **连接顺序合理**。先用条件收窄驱动表，再逐个索引查找被驱动表。若优化器选了另一个驱动表（比如从 oi 出发），树的第一层子节点就会是它，那时要问"为什么"，多半是驱动表的预估行数被低估了。
3. **每层 rows 的量级递增正常**。418 × 4 = 1672，1672 × 3 ≈ 5000，和根节点 187 差得远——说明有过滤下推了（qty > 100 之类），或者这么看 rows 只是每层"平均"输出。要准确算工作量，还得靠 EXPLAIN ANALYZE 的 loops。

一个经典错误读法：**只看根节点的 cost**。cost=1780 和 cost=120 单独比没意义（不同查询）。有价值的比较是"同一个查询，加索引前后"：根 cost 从 1780 降到 210，说明索引起效了。

## EXPLAIN 看不懂时的三板斧

1. **看 Extra 列**。切 FORMAT=TRADITIONAL，Extra 列信息密度最高：Using where（服务层过滤）、Using index（覆盖索引，胜利）、Using temporary（用了临时表）、Using filesort（文件排序，警报）。
2. **对比例子**。把慢的 EXPLAIN 和快的 EXPLAIN 并排放，diff 树结构——连接顺序变了？某层的访问方式从 range 退化成 index？差异自己会说话。
3. **OPTIMIZER_TRACE**。终极武器，看优化器为什么这么选：

```sql
SET SESSION optimizer_trace='enabled=on';
SELECT ...你的查询...;
SELECT * FROM information_schema.optimizer_trace\G
```

trace 里能查到"为什么没走 idx_amount"——是成本估算、还是统计信息缺失。排查优化器选错索引的问题时，这是直接从优化器嘴里问答案。

## 小结

EXPLAIN TREE 格式把执行计划变成了一棵能逐层读的树：根节点看最终形态，子节点顺序看 JOIN 顺序，叶子节点看每个数据源的访问方式，cost 和 rows 在各层间横向比较。配着 FORMAT=TRADITIONAL 的 Extra 列和 optimizer_trace 的决策记录，从"计划是什么"到"为什么是这个计划"的链路就完整了。下一篇看 JSON 格式——机器可读的输出里，藏着树格式不显示的字段级细节。
