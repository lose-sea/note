# GROUP BY WITH ROLLUP：一次查询出小计与合计

"各个区域的销售额，加上每个区域的小计，再加总计"——这种报表需求，新手写法是 UNION 拼三条查询，或者查出来在代码里累加。MySQL 用 `WITH ROLLUP` 一个修饰符就能做到。这篇文章讲 ROLLUP 的语义、输出行的识别、和 UNION 写法的性能对比，以及分页统计的常见坑。

## ROLLUP 是什么：加修饰符，出小计

```sql
SELECT region, product, SUM(amount) AS total
FROM sales
GROUP BY region, product WITH ROLLUP;
```

不加 ROLLUP，输出每个 (region, product) 组合一行；**加了 ROLLUP，输出在普通分组之外，追加所有层级的小计和总计**。以三区域 × 两产品为例，输出行：

| region | product | total | 说明 |
|---|---|---|---|
| 华东 | A | 1000 | 普通分组 |
| 华东 | B | 800 | 普通分组 |
| 华东 | NULL | **1800** | region=华东 的小计 |
| 华北 | A | 500 | 普通分组 |
| 华北 | B | 300 | 普通分组 |
| 华北 | NULL | **800** | region=华北 的小计 |
| NULL | NULL | **2600** | 总计 |

规律：**小计行的分组列为 NULL**。GROUP BY 第一列是 region，那么 region=NULL、product=NULL 是总计；region 有值、product=NULL 是该 region 的小计。**NULL 是小计行的标记**——这也是它的坑：如果原始数据里 region 或 product 本来就可能是 NULL，小计行和真实行就分不清了。

## 多层级与组合爆炸

ROLLUP 按 GROUP BY 的列顺序逐级汇总。三列 GROUP BY a, b, c WITH ROLLUP 会输出：

- 每个 (a,b,c) 明细行
- 每个 (a,b) 的小计（c=NULL）
- 每个 (a) 的小计（b=NULL, c=NULL）
- 总计（全 NULL）

总共 (a 不同值 × b 不同值) + (a 不同值) + 1 个层级。**列越多、基数列的基数越大，小计行涨得越快**——但相比 UNION 写法，它只扫一遍表，这是它的核心优势。

还有两个兄弟修饰符：

| 写法 | 语义 | 输出 |
|---|---|---|
| `WITH ROLLUP` | 层级小计（按列顺序逐级） | 明细 + 各层级小计 + 总计 |
| `WITH CUBE` | 所有维度组合 | MySQL **不支持**（其他数据库有） |
| `GROUPING SETS` | 自定义分组集合 | MySQL **不支持** |

MySQL 只有 ROLLUP，Hive/PG 有 CUBE 和 GROUPING SETS。遇到"要所有维度组合"的需求，MySQL 里只能 UNION 拼。

## 识别小计行：GROUPING() 函数

既然小计行靠 NULL 标记，模糊场景怎么区分"小计 NULL"和"本来数据就是 NULL"？MySQL 8.0 提供 `GROUPING()` 函数：

```sql
SELECT region, GROUPING(region) AS is_subtotal, SUM(amount)
FROM sales GROUP BY region WITH ROLLUP;
```

`GROUPING(region)` 在该行是 region 的小计行时返回 1，普通分组行返回 0。写报表 SQL 时用它区分两类 NULL：

```sql
SELECT
    CASE WHEN GROUPING(region) = 1 THEN '总计' ELSE region END AS region_label,
    SUM(amount) AS total
FROM sales
GROUP BY region WITH ROLLUP;
```

没有 GROUPING() 的版本（8.0 之前），业界土法是 `IFNULL(region, '总计')`——数据本身有 NULL 时会误标，能不用就不用。

## 性能对比：ROLLUP vs UNION

同一个需求两种写法：

```sql
-- 写法 A：ROLLUP
SELECT region, SUM(amount) FROM sales
WHERE dt = '2026-10-01' GROUP BY region WITH ROLLUP;

-- 写法 B：UNION
SELECT region, SUM(amount) FROM sales WHERE dt='2026-10-01' GROUP BY region
UNION ALL
SELECT '总计', SUM(amount) FROM sales WHERE dt='2026-10-01';
```

性能差异的来源：**ROLLUP 扫一遍表、在内存里逐层累加；UNION 各分支各扫一遍**。表 5000 万行时，ROLLUP 一次全扫 vs UNION 两次全扫，差距直接翻倍。数据量大、列层级多时，ROLLUP 的优势是数量级的。

还有工程上的隐性收益：**ROLLUP 在 SQL 层一次算完，应用层拿到的直接是可用的层级数据**；UNION 写法需要在结果集里区分"哪行是总计"（通常靠 NULL 判断或排序位置），还得处理列类型不一致（varchar 的 '总计' 混进数值列）。ROLLUP + GROUPING() 是更干净的语义。

## 常见坑

**坑一：ORDER BY 和小计行**。ROLLUP 的小计行不在 ORDER BY 的目标里"自然有序"，它插在各组之间：

```sql
-- 想要总计在最后、各组小计跟在组内，需要显式排序
SELECT region, product, SUM(amount) FROM sales
GROUP BY region, product WITH ROLLUP
ORDER BY region IS NULL, region, product IS NULL, product;
-- region IS NULL 把总计行沉底，product IS NULL 把小计行沉到组尾
```

**坑二：分页统计的经典错误**。很多人想"每页 20 条 + 这页的小计"，于是 `LIMIT 20` 加上 ROLLUP——**小计是基于全量数据的，LIMIT 先把 ROLLUP 前的行截断了**。正确姿势：ROLLUP 全量算完，应用层按 NULL 标记拆"明细行"和"小计行"，再对明细行分页。SQL 分页和统计小计混在一起，一定有坑。

**坑三：COUNT(*) + ROLLUP**。有些报表想要"行数小计"，`SUM(amount), COUNT(*)` 一起 ROLLUP 没问题；但想把汇总后的 COUNT 当"条件"用（HAVING 过滤小计），逻辑要小心——小计行也是 HAVING 的评估对象，`HAVING SUM(amount) > 1000` 会把大部分小计行也滤掉，输出结构就残缺了。要么 HAVING 加 `GROUPING(x)=0` 条件，要么应用层处理。

**坑四：列有 NULL**。上面说过，业务列本身允许 NULL 时，小计行和真实行撞脸。用 GROUPING() 区分，或者从 schema 设计上给业务列 NOT NULL + DEFAULT '' 的约定。

## 与窗口函数的取舍

ROLLUP 出的是"额外行"，窗口函数出的是"每行带汇总值"：

```sql
-- ROLLUP：输出里多出小计/总计行
SELECT region, SUM(amount) FROM sales GROUP BY region WITH ROLLUP;

-- 窗口函数：每行 all 携带总计，没有额外行
SELECT DISTINCT region, SUM(amount) OVER () AS grand_total
FROM (SELECT region, SUM(amount) AS amount FROM sales GROUP BY region) t;
```

选择依据是下游怎么用：表格报表展示（"明细 + 小计行 + 总计行"）用 ROLLUP；JSON API/前端渲染（每条明细自带占比、总计）用窗口函数。**两者不是替代关系，是输出形态的差异。**

## 小结

WITH ROLLUP 是 MySQL 原生的层级汇总工具：按 GROUP BY 列序逐级出小计，总计行全 NULL，GROUPING() 函数可靠区分小计行。一次全表扫描完成 UNION 要扫 N 遍的活，大表报表里是数量级优势。注意三条红线：小计行靠 ORDER BY 手工归位、分页统计要应用层拆行、业务列有 NULL 时必须上 GROUPING()。下一篇讲窗口函数三件套——LAG、LEAD 和 NTILE。
