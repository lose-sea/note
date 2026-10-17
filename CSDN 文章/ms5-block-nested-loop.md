# 块嵌套循环（BNLJ）：无索引 JOIN 的兜底算法

上一篇文章讲过优化器怎么在嵌套循环和哈希连接之间选。这篇文章深入 **BNLJ（Block Nested-Loop Join，块嵌套循环连接）** 的机制：它怎么工作、什么时候被选中、性能边界在哪、以及它和 hash join 的红线区别。理解 BNLJ 的价值不只是"看懂一条慢查询"，更是理解"没有索引的 JOIN 到底慢在哪、能不能救"。

## 先回顾：朴素嵌套循环慢在哪

最朴素的嵌套循环：外层遍历驱动表每一行，内层对被驱动表做一次完整扫描（假设被驱动表无可用索引）。

```
驱动表 N 行，被驱动表 M 行 → 内层扫描 N × M 次
```

两个 100 万行的表 join，比较次数轻松上 10^12。这不是索引能救的——**被驱动表连接列没有索引时，朴素嵌套循环就是灾难**。MySQL 当然不能这么干，于是有了 BNLJ。

## BNLJ 的核心思想：批量缓冲

BNLJ 的改进一句话：**把驱动表的多行打包进 join buffer，一次扫描被驱动表同时和 buffer 里所有驱动行比较。**

```
1. 读入驱动表的 K 行（K 由 join_buffer_size / 行宽 决定），装入 join buffer
2. 全表扫描被驱动表一遍
3. 对每个被驱动表行，与 buffer 中 K 行逐一比较 join 条件
4. 匹配的输出，不匹配的丢弃
5. buffer 用完，回到步骤 1，驱动表前移 K 行
```

比较次数从 N×M 降到 **ceil(N/K) × M**。K 是主导变量：buffer 能装多少行，扫描遍数就减少多少倍。这就是"用内存换扫描次数"的含义——数据访问没有变少（被驱动表还是要扫 N/K 遍），但**每遍的 CPU 比较从 1 次变成 K 次**，而 CPU 比较远快于磁盘/缓冲池访问。

## Join Buffer 里装的是什么

一个常见误解："BNLJ 把整个驱动表装进 buffer"。不是的。join_buffer_size 通常 256KB~8MB，装不下大表。实际装的是：

- **join 条件需要的列**（连接键），以及 SELECT/WHERE 里引用到的被驱动表条件相关列——full row 模式会装整行，但绝大多数优化场景只装必要列。
- buffer 满即换批，所以大驱动表被切成若干批处理。

这也解释了一个现象：**两条看起来一样的 JOIN，一条快一条慢，可能就差在 SELECT 列数**——select * 让 buffer 里每行变宽，一次能装的驱动行变少，扫描遍数上升。面试常考，实战常踩。

## 执行标志识别

EXPLAIN 输出里 BNLJ 的特征：

```
-> Nested loop inner join  (cost=... )
    -> Table scan on tmp      (驱动表，cost 随行数线性)
    -> Hash join buffer       ← 出现这个就是 BNLJ/Hash 的信号
    -> Table scan on orders   (被驱动表，无索引访问)
-> Filter: ...
```

传统格式下 Extra 列显示 `Using join buffer (block nested loop)`；TREE 格式里 BNLJ 的信息藏在节点属性里，需要看 `Using join buffer` 字样或其对应的哈希连接标记。执行计划里看到被驱动表 `access_type: ALL` + 连接方式是 nested loop，基本就是 BNLJ 在工作。

## 性能边界与调优

BNLJ 的三个真实边界：

**边界一：IO 下不来**。被驱动表要扫 ceil(N/K) 遍。驱动表 1000 万行、buffer 装 1 万行/批 = 扫 1000 遍。表在缓冲池里时还行，表比内存大时就是磁盘在哭泣。判断标准：`(N/K) × M` 的总行访问量。

**边界二：CPU 比较的隐性成本**。buffer 里装 1 万行，被驱动表每行要和这 1 万行逐一比较 join 列。行宽越大、比较越频繁，CPU 先于 IO 成为瓶颈。这是为什么"减小 buffer 行宽"（只 select 必要列）有时比调大 buffer 更有效。

**边界三：memory 的连锁反应**。`join_buffer_size` 是**每个 join 线程独立分配**的。一条 SQL 三个 BNLJ 就要三份 buffer，200 个并发连接 = 200×3 份。设 16MB 上限，单连接峰值 48MB，并发一上来 OOM 是早晚的事。**默认 256KB 是保守的甜点，生产调到 1~4MB 且盯内存水位**。

调优三板斧，按优先级：

1. **给被驱动表连接列加索引**。把 BNLJ 变成索引嵌套循环，直接从算法上消灭问题。这是治本。
2. **只 select 必要列**。窄行让 buffer 多装几倍驱动行，扫描遍数下降。
3. **调 join_buffer_size**（配合监控）。只在前两条做完仍有大批量无索引 join 时用。

## 强制与禁用

MySQL 8.0.32 GA 了 hash join 后，BNLJ 更多是兜底（哈希表装不下内存、或连接条件非等值）。可以用 hint 干预：

```sql
-- 强制对 o, c 的连接使用 BNLJ
SELECT /*+ NO_HASH_JOIN(o, c) */ ... FROM o JOIN c ...;

-- 也控制 join order
SELECT /*+ JOIN_ORDER(o, c) */ ...
```

什么场景想强制 BNLJ？**被驱动表极小**（比如字典表 100 行）时，嵌套循环 + 全表扫描比建哈希表还快——哈希连接的 build 阶段本身有开销。优化器通常会正确评估，但预估行数失真时它会选错。

## BNLJ vs Hash Join 的决策红线

| 维度 | BNLJ | Hash Join |
|---|---|---|
| 连接条件 | 等值、非等值（<、>、BETWEEN）都行 | **仅等值** |
| 被驱动表索引 | 不需要 | 不需要 |
| 内存 | join_buffer_size，超了继续分块扫描 | build 的哈希表要装进内存，超了分区落盘 |
| 驱动表极小时的额外开销 | 无（直接扫） | 建哈希的开销可能不值 |
| 复杂度 | O(ceil(N/K) × M) | O(N + M) |

非等值连接（`ON a.amount < b.threshold`）只有 BNLJ 一条路——这也是"范围 JOIN 慢"的根因：它的天花板就是线性扫描加比较，索引只能优化驱动侧，被驱动侧的每条记录终究要过一遍条件。

## 实战案例：一条被 BNLJ 拖垮的报表 SQL

```sql
SELECT COUNT(*) FROM big_fact a
JOIN dim_table b ON a.cat_id = b.id      -- b 是维表，有主键
WHERE a.dt = '2026-10-01' AND a.region_id = 3;
```

诊断：EXPLAIN 显示 big_fact 全表扫描（dt、region_id 没走联合索引），BNLJ join dim_table。big_fact 3 亿行，一次报表 = 全表扫 3 亿 × 每行与 buffer 里 dim 行比较。跑 40 分钟。

修复路径：**根本不是 JOIN 的问题，是驱动表没有过滤索引**。加 `(dt, region_id)` 联合索引后，驱动行从 3 亿降到 80 万，join 变成索引嵌套循环，报表 3 秒。BNLJ 在这条链里只是"暴露了上游没有索引"的受害者。**看到 BNLJ 先别急着调 buffer，先问驱动表为什么没有被 WHERE 收窄**——十次有八次问题在上游。

## 小结

块嵌套循环是无索引 JOIN 的兜底算法：批量缓冲驱动行、减少被驱动表扫描遍数，用内存和 CPU 换 IO。它的边界由 join_buffer_size 和行宽共同决定，优化优先级永远是"加索引 → 收窄行 → 最后才调 buffer"。8.0.32 之后，等值连接大表场景尽量引导优化器走 hash join，把 BNLJ 留给"非等值、小表、连接表装得下"的场景。下一篇讲哈希连接的内部机制和内存管理。
