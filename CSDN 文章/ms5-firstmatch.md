# FirstMatch 策略：semi-join 里那个"见好就收"的执行器

半连接六种策略里（第一篇 semi-join 专篇讲过全景），FirstMatch 是最容易被忽视、却在日常查询里最常悄悄发挥作用的那个。它的思想一句话：**外层每行只要能找到一行匹配就收工，绝不多找**。这篇文章把它的机制、适用场景、和 materialization/dupsweedout 的取舍讲清楚，并教你怎么辨认它在工作。

## 机制："短路求值"的数据库版

回顾 semi-join 的语义：`WHERE o.customer_id IN (SELECT id FROM vip)` 对 orders 的每一行，只关心"vip 里有没有匹配的 id"，有就保留，没有就丢掉——**哪怕 vip 里有三行匹配，orders 这行也只输出一次**。

FirstMatch 就是按这个语义"字面执行"的算法：

```
外层（orders）逐行：
    拿着 customer_id 的值去 vip 表索引里找第一行匹配
    找到了 → orders 这行输出，立即收工，不继续扫 vip
    没找到 → orders 这行丢弃
```

对应的执行计划长这样：

```
-> Nested loop inner join
    -> Table scan / Index scan on orders        (外层驱动)
    -> Index lookup on vip using idx_id (id=o.customer_id)
                                    → 第一次命中即停
```

关键点：**被驱动表必须走索引查找**。FirstMatch 的"见好就收"依赖 B+ 树定位到第一个匹配的能力——没有索引，就没有"第一行"可言，只能全表扫，也就不存在 firstmatch 了。这也是为什么 FirstMatch 几乎总是和"被驱动表有连接列索引"绑定出现。

## 它和 materialization 的分工

同样是 `IN` 子查询，优化器什么时候选 FirstMatch、什么时候选 Materialization？核心变量是**数据量和执行方向**：

**FirstMatch 的适用场景**：外层行数少（或外层有强过滤条件），被驱动表有索引。此时外层的每一行都是一次廉价的索引点查，找到第一行匹配的成本低到可以忽略。30 万订单、每个订单查一次 vip 索引定位到即停——总共 30 万次点查，每次几微秒，总耗时几百毫秒。

**Materialization 的适用场景**：外层行数多、子查询结果集小且可复用。物化把 vip 全表算一次建临时索引，外层 30 万行全部来查临时索引。如果外层行数继续涨到千万级，物化的一次性成本被摊薄，就更划算。

一句话概括：**FirstMatch 是"按需查找"，Materialization 是"批量建索引"**。小外层用 FirstMatch 避免物化开销，大外层用 Materialization 摊薄成本。

## 它和 DuplicateWeedout 的分工

DuplicateWeedout 解决的是另一个问题：当连接本身一对多会产生重复时，先把 join 跑完再用临时表去重。它的成本和 FirstMatch 的对比：

| 维度 | FirstMatch | DuplicateWeedout |
|---|---|---|
| 执行方式 | 每行找到匹配即停 | join 全跑完，临时表去重 |
| 内存开销 | 无（不用建临时表） | 需要 weedout 临时表 |
| 重复处理 | 天然无重复（只取一行） | 事后清理 |
| 对被驱动表索引的依赖 | **强依赖** | 也可以无索引（BNLJ + weedout） |
| 适用 | 被驱动表有索引的连接列 | 无索引、一对多、结果需去重 |

**如果被驱动表的连接列有索引，FirstMatch 几乎总是优于 DuplicateWeedout**——没有临时表开销、没有重复产生和处理。这也是为什么加对了索引的查询，执行计划里经常能看到 firstmatch 形态。

## 一个重要认知：EXISTS 是 FirstMatch 的天然载体

日常写 `IN (SELECT ...)` 时 MySQL 会先物化子查询再 semi-join；写 `EXISTS (SELECT 1 FROM b WHERE b.id = a.id)` 时，十有八九走 FirstMatch。两条 SQL 语义等价，执行路径不同。**当外层大、被驱动表有索引时，把 IN 改写成 EXISTS，是引导 FirstMatch 最可靠的手段**（比重写 hint 稳）。

```sql
-- IN 版：可能物化
SELECT * FROM orders o WHERE o.customer_id IN (SELECT id FROM vip WHERE type='gold');
-- EXISTS 版：更可能 FirstMatch
SELECT * FROM orders o WHERE EXISTS (
    SELECT 1 FROM vip v WHERE v.id = o.customer_id AND v.type='gold'
);
```

为什么 EXISTS 天然导向 FirstMatch？EXISTS 只问"有没有"，优化器把外层当驱动、被驱动侧只要能回答"有"即可——找到一行就能回答。IN 的子查询则被当成"一个集合"，集合要先算出来，于是倾向物化。**写法的微小差别，执行器的大路分歧。**

## 辨认与验证

在 TREE 格式里认 FirstMatch：

```
-> Nested loop inner join
    -> ... (外层)
    -> Index lookup on b using idx_x (x=a.y)  → 就这个形态
```

光看 EXPLAIN 看不出"即停"行为，需要 EXPLAIN ANALYZE 实测看两件事：

1. **被驱动表的 loops 和 rows**。loops 应等于外层驱动行数，每次 rows 应该接近 1（FirstMatch 保证最多取一行；若平均 rows 明显大于 1 且没触发去重，说明相关场景走了全 join）。
2. **被驱动表的实际耗时**。点查耗时应该在外层能接受的量级，说明"找到即停"真的发生了。

想强制走 FirstMatch：

```sql
SELECT /*+ SEMIJOIN(@subq FIRSTMATCH) */ * FROM orders o
WHERE o.customer_id IN (SELECT id FROM vip);
```

但重申一遍纪律：**能用 EXISTS 改写就别用 hint**。hint 绑死数据分布的前提，EXISTS 让优化器自己判断。

## 反面教材：FirstMatch 失效的三种情况

1. **被驱动表连接列没索引**。算法直接不可用，优化器只能换 DuplicateWeedout 或 BNLJ。看懂"为什么 FirstMatch 没生效"，十有八九是先查索引。
2. **子查询里有 LIMIT**。LIMIT 让子查询不能简单反嵌套，FirstMatch 无从谈起。去掉或改写 LIMIT 逻辑。
3. **优化器预估外层行数过小、实际巨大**。预估 100 行走 FirstMatch，实际 3000 万行，点查次数爆炸。这是统计信息失真的锅，`ANALYZE TABLE` + EXPLAIN ANALYZE 实测行数校准。

## 小结

FirstMatch 是 semi-join 家族里最"贴合语义"的执行策略：外层每行只问存在性，找到一行就停。它的成本公式是"外层行数 × 一次索引点查"，适用小外层、被驱动表有索引的场景，和 Materialization 的大小外层分工、和 DuplicateWeedout 的有无索引分工界限清晰。日常写 EXISTS 而不是 IN，就是最顺手的 FirstMatch 引导术。下一篇讲 LIMIT 下推——分页语句在优化器手里怎么变形。
