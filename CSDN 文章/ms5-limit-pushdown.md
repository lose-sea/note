# LIMIT 下推：分页语句在优化器手里怎么变形

`SELECT ... FROM t WHERE ... ORDER BY ... LIMIT 100` 是查询里最高频的形态之一。大多数人盯着索引和 ORDER BY，却不知道 MySQL 对 LIMIT 本身也做了一整套优化：**把 LIMIT 参数下推到联合查询的每个分支、推到 JOIN 的内层、推到 semi-join 的子查询**。这篇文章讲下推的规则、三种典型场景的变形、以及它不生效时怎么兜底。

## 为什么 LIMIT 值得专门优化

本质上 LIMIT 是"提前终止信号"：一旦输出够数，剩下的计算全是浪费。问题在于复杂查询里 LIMIT 在最外层，而真正干活的是 JOIN、UNION、子查询——**优化器要把"提前终止"传导到每一层**，让内层也知道"不用全算了"。

```sql
SELECT * FROM (SELECT ... UNION ALL SELECT ...) t ORDER BY x LIMIT 10;
```

不下推的话：两个分支全量算 → 全量 UNION ALL → 全量排序 → 取 10 行。下推之后：每个分支各自带 LIMIT 限制（配合排序条件下推）→ 更少的行进 UNION → 排序 20 行而不是 200 万 → 取 10。

## 场景一：UNION / UNION ALL 的 LIMIT 下推

最经典的推变形。规则：

```sql
-- 原始
(SELECT a, x FROM t1) UNION ALL (SELECT a, x FROM t2) ORDER BY x LIMIT 10;

-- 下推后（逻辑等价，内层各带 LIMIT）
(SELECT a, x FROM t1 ORDER BY x LIMIT 10)      ← 加了 ORDER BY + LIMIT
UNION ALL
(SELECT a, x FROM t2 ORDER BY x LIMIT 10)      ← 同上
ORDER BY x LIMIT 10;
```

每个分支各自排序取前 10，合起来 20 行再总体排序取 10。**结果不变、工作量从 2N 降到 2×10**。执行计划里能看到内层子查询上出现了 Sort + Limit 节点。

两个限制条件：**仅 UNION ALL**。UNION（去重）不能这么推——分支一 10 行、分支二 10 行去重后可能少于 10 行，而全量 UNION 的 top10 语义要求"全局去重后再取前 10"，下推后丢了行。**UNION ALL 无脑推，UNION 不能推**，这是面试高频考点，也是生产高频错误。

## 场景二：JOIN 的 LIMIT 下推

```sql
SELECT * FROM a JOIN b ON a.id = b.a_id ORDER BY a.ts LIMIT 100;
```

如果驱动表 a 已经能确定排序键（a.ts 上有索引），优化器可以把 LIMIT 推到驱动表侧：先扫 a 取 100 行，再去 b 做 100 次点查，而不是 JOIN 全量再 LIMIT。**前提是排序键属于驱动表且被驱动表的连接不改变行数**——LEFT JOIN 场景不能推（左表行可能因连接而重复，先取 100 行可能不够 JOIN 后的 100 行）。

LEFT JOIN / RIGHT JOIN 的下推是"改了语义"的红线，优化器只在保证结果一致时才做。这就是为什么有些 JOIN + LIMIT 慢——你以为它会推，其实它不能。

## 场景三：派生表的 LIMIT 与 merge

上一篇讲 derived table 时提过：**LIMIT 是 merge 的阻断器**。带 LIMIT 的派生表不能合并，通常走物化——物化了还要在外层套 LIMIT，反而更慢。

```sql
SELECT * FROM (SELECT * FROM orders ORDER BY amount DESC LIMIT 100) t
WHERE t.status = 'paid';
```

正确姿势是手动把条件下推到 LIMIT 之前（语义分析过）：

```sql
SELECT * FROM orders WHERE status = 'paid' ORDER BY amount DESC LIMIT 100;
```

**先过滤再排序再 LIMIT vs 先排序取 100 再过滤——差 100 倍**。这个坑的本质是"用派生表阻挡了条件下推"，写复杂 SQL 时值得条件反射式地检查。

## 下推失效时的兜底：手动改写

优化器的自动下推有它的边界，失效时手动改写出路。社区总结的"延迟关联"是深分页的经典武器：

```sql
-- 深分页：第 10000 页，每页 20 条
SELECT * FROM orders ORDER BY id LIMIT 200000, 20;
-- 慢因：按序扫 200020 行，扔掉前 200000
-- 改写：子查询只取 id，延迟关联回表
SELECT o.* FROM orders o
JOIN (SELECT id FROM orders ORDER BY id LIMIT 200000, 20) t
  ON o.id = t.id;
```

后者只扫 id 索引（覆盖索引）定位 20 行，再回表 20 次。**深分页优化的核心就是"让 LIMIT 的输入行数最小化"**——这正是 LIMIT 下推思想的手动版。

配套的两种衍生写法：

```sql
-- 写法 B：WHERE 定位（要求排序键唯一且连续/可比较）
SELECT * FROM orders WHERE id > 200000 ORDER BY id LIMIT 20;
-- 写法 C：游标分页（keyset pagination），同 B，API 上传 last_id
```

B/C 的代价是只能顺序翻页，不能跳页——但深分页场景里用户真的跳到第 500 页吗？99% 是顺序翻或搜索。**API 设计成游标分页，顺手根治深分页**。

## 深分页为什么慢：本质不是 LIMIT 的锅

深分页慢的根源：**OFFSET 要求"跳过 N 行"，这 N 行必须被读取、计数、丢弃**。LIMIT 100 OFFSET 500000，引擎老老实实读 500100 行。任何"先读取全文再定位"的存储都逃不掉。MySQL 能做的优化是把"读"从回表读变成覆盖索引读——这就是延迟关联做的事。

所以优化方向排序：

1. **消灭深分页**：游标分页（keyset）> 延迟关联 > 裸 LIMIT OFFSET。
2. **缩小单次扫描宽度**：覆盖索引（SELECT 只取索引列）。
3. **预计算/缓存**：搜索引擎（ES/OpenSearch）或物化视图承载深翻页场景。

## 优化器 trace 验证

怀疑 LIMIT 没下推？用 optimizer_trace 看：

```sql
SET optimizer_trace='enabled=on';
SELECT ... LIMIT 100;
SELECT * FROM information_schema.optimizer_trace\G
```

trace 的 `join_execution` 段能看到每层实际拿到 limit 参数没有。诊断 LIMIT 相关性能问题时，这是比 EXPLAIN 更直接的手段——执行计划可能看不出 limit 参数被传到哪一层，trace 里 limit 的流转一览无余。

## 小结

LIMIT 下推是优化器对"提前终止"信号的传导：UNION ALL 分支各自带 LIMIT 收窄输入、JOIN 驱动侧带 LIMIT 减少被驱动查找、派生表带 LIMIT 则阻断 merge（挡住条件下推）。自动下推失效时，手动改写三件套——条件下推到 LIMIT 前、延迟关联回表、游标分页——按场景选。深分页的终极答案是"别让引擎读它要跳过的行"。下一篇讲 GROUP BY 的 ROLLUP——一次查询出小计和合计的魔法。
