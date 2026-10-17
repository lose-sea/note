# 窗口函数实战：LAG 与 LEAD 做行间对比，告别自关联

"每个用户的两次订单间隔""本月与上月的环比""股价的每日涨跌"——凡是需要**拿一行去比另一行**的需求，老写法是自关联或相关子查询，新写法是窗口函数 `LAG` / `LEAD`。这篇文章用真实场景讲透这两个函数：语义、语法细节、索引配合、以及与自关联写法的性能对比。

## LAG / LEAD 语义：前后行访问器

一句话：**LAG 取"前 N 行"的值，LEAD 取"后 N 行"的值**，都是在同一个结果集（窗口分区）内相对当前行的偏移访问。

```sql
LAG(expr [, offset [, default]]) OVER (PARTITION BY ... ORDER BY ...)
LEAD(expr [, offset [, default]]) OVER (PARTITION BY ... ORDER BY ...)
```

- `expr`：要取哪列的值。
- `offset`：偏移几行，默认 1。
- `default`：够不到时的默认值（默认 NULL）。**这个参数很多人漏掉，边界行出 NULL 导致下游计算崩**。
- `PARTITION BY`：按什么分组（每个用户、每个区域）。
- `ORDER BY`：窗口内的排序——**前后行的"前后"完全由它定义**，没写 ORDER BY 的 LAG 结果不确定。

看个最小例子——每个订单和该用户上一单的时间差：

```sql
SELECT order_id, customer_id, amount, created_at,
       LAG(created_at) OVER w AS prev_at
FROM orders
WINDOW w AS (PARTITION BY customer_id ORDER BY created_at);
```

对每个客户的第一单，`prev_at` 是 NULL——没有"上一单"嘛。

## 实战一：环比计算

电商月报的经典需求："每品类本月销售额、上月销售额、环比增幅"。

```sql
WITH monthly AS (
    SELECT category,
           DATE_FORMAT(created_at, '%Y-%m') AS ym,
           SUM(amount) AS revenue
    FROM orders
    WHERE created_at >= '2026-01-01'
    GROUP BY category, ym
)
SELECT category, ym, revenue,
       LAG(revenue, 1, 0) OVER w AS last_revenue,
       CASE WHEN LAG(revenue) OVER w IS NULL OR LAG(revenue) OVER w = 0
            THEN NULL
            ELSE ROUND((revenue - LAG(revenue) OVER w) / LAG(revenue) OVER w * 100, 2)
       END AS mom_pct
FROM monthly
WINDOW w AS (PARTITION BY category ORDER BY ym);
```

三个细节注意：

1. **`LAG(revenue, 1, 0)` 的 default=0**：避免首月返回 NULL 影响聚合，但除法前还要判零。
2. **`WINDOW w AS (...)` 命名窗口**：SQL 的窗口定义复用语法，避免三个地方写三遍 `PARTITION BY category ORDER BY ym`——这是 MySQL 8.0 支持的写法，代码干净一个档次。
3. **除零保护**：上月销售额为 0 时环比分母炸掉。报告展示 NULL（"无上月数据"）比 `inf` 或错误体面。

老写法长什么样？自关联：

```sql
SELECT a.category, a.ym, a.revenue,
       b.revenue AS last_revenue
FROM monthly a LEFT JOIN monthly b
  ON a.category = b.category AND b.ym = 上一个月(a.ym);
```

"上一个月"这个计算本身就要函数（`DATE_FORMAT(DATE_SUB(...),'%Y-%m')`），跨年、闰月全是坑。自关联还要对 monthly 扫两遍做 join。窗口函数一次扫描搞定。

## 实战二：事件序列与间隔

更硬核的场景——统计每个用户两次登录的间隔天数：

```sql
SELECT user_id, login_at,
       TIMESTAMPDIFF(
           SECOND,
           LAG(login_at) OVER w,
           login_at
       ) AS gap_seconds
FROM login_log
WINDOW w AS (PARTITION BY user_id ORDER BY login_at);
```

再包一层就是"平均登录间隔""有多少次间隔超过 30 天（流失预警）"：

```sql
SELECT user_id,
       AVG(gap_seconds) AS avg_gap,
       MAX(gap_seconds) AS max_gap,
       SUM(CASE WHEN gap_seconds > 30*86400 THEN 1 ELSE 0 END) AS churn_risk_count
FROM (上一层的查询) t
GROUP BY user_id;
```

**窗口函数 + 子查询分层是复杂分析的标准范式**：窗口函数做行间对比，外层做分组聚合。这个模式比写一大坨嵌套自关联可读性高一个数量级。

## 实战三：同比与移动平均

**同比**（今年 3 月 vs 去年 3 月）用 `LAG(revenue, 12)` 按月分区排序即可——offset=12 就是去年同月。前提是序列连续无空洞，否则要先补齐缺失月份（用日历表 LEFT JOIN 再窗口）。

**移动平均**是窗口函数的另一个主场：

```sql
SELECT dt, amount,
       AVG(amount) OVER (ORDER BY dt ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS ma7,
       SUM(amount) OVER (ORDER BY dt ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumsum
FROM daily_sales;
```

`ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` 是 7 日窗口（物理行偏移）；`RANGE` 则是值域偏移。三者区别是面试高频：**ROWS 按行数、RANGE 按 ORDER BY 的值、GROUPS 按同值的组**。日交易数据想去重后统计，用 RANGE 注意处理大量并列值。

## 性能：窗口函数 vs 自关联

同样是"比前后行"，两种实现的成本差异：

| 维度 | 窗口函数 | 自关联 |
|---|---|---|
| 扫描次数 | **一次**（排序后用内存游标） | 两遍 + join |
| 排序 | 一次（PARTITION/ORDER 决定） | 索引可用时可能免排序 |
| 大分区内存 | 分区大时缓冲压力 | 无此问题 |
| 深分页 | 需先排序全量 | 索引定位可省 |

**小到中等结果集，窗口函数通常快 3~10 倍**——少了自关联的重复扫描。但有两个大分区注意点：

1. **内存压力**。窗口函数要按 PARTITION BY + ORDER BY 排序，分区内数据进缓冲。一个分区几百万行且不能 spilled 时，内存飙。`Sort_merge_passes` 飙升的信号。
2. **索引**。`(PARTITION BY 列, ORDER BY 列)` 的联合索引能让排序阶段走索引有序扫描，免掉 filesort。MySQL 8.0 对窗口函数的排序有专门优化（window function optimization），执行计划里出现 `Window function with optimization` 就是命中索引的迹象。

**如果自查询能走索引**（比如"比上一行"能靠自增 ID 直接定位），自关联仍可能更快——窗口函数的优势在复杂偏移（offset 12、动态 N 窗口）和多指标复用（一个窗口定义算 LAG/LEAD/SUM/AVG）。

## 边界与陷阱

**NULL 传播**。`LAG(NULL 列) OVER w` 的语义是取前一行的值，该值是 NULL 就 NULL。别把"取到的值是 NULL"和"没有前一行"（也是 NULL）混在一起，用 `ROWS` 边界和 default 参数区分。

**ORDER BY 不稳定**。ORDER BY 的键有并列值时（同日期两行），LAG/LEAD 取哪行不确定——**加上唯一键进 ORDER BY**（`ORDER BY created_at, id`）让游标行为可预期。这是线上出过鬼怪 bug 的经典源头：同一数据同一 SQL，两次运行结果不同。

**窗口不能的部分**。窗口函数不能出现在 WHERE / GROUP BY 里（要用它的结果做过滤，套一层子查询）；不能直接嵌套窗口函数；LAG 的 offset 不能是负的（负向用 LEAD）。

## 小结

LAG/LEAD 是行间对比的标准工具：环比、间隔、同比、移动平均，全部从"自关联"变成"一次扫描 + 游标访问"。掌握三个关键：**ORDER BY 必须稳定（并列加唯一键）、default 参数兜边界、PARTITION/ORDER 列建联合索引免排序**。分层范式记牢：窗口函数算行间值，子查询外层做聚合。下一篇讲窗口函数的另一翼——NTILE 分桶和排名函数族。
