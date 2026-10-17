# 窗口函数进阶：NTILE 分桶、RANK 家族与累计求和的艺术

上篇 LAG/LEAD 解决了"行间对比"，这篇文章讲窗口函数的另一半版图：**分桶（NTILE）、排名（ROW_NUMBER / RANK / DENSE_RANK）、以及之光函数（FIRST_VALUE / LAST_VALUE）**。它们撑着 BI 报表的"Top N、分层、累计占比"三大件，也藏着最多"看起来对、结果错"的坑。

## NTILE：把数据切成 N 桶

`NTILE(n)` 把窗口内的行尽量均匀地分成 n 个桶，返回每行所属的桶号（1 到 n）。核心用途：**百分位分层**。

```sql
-- 把用户按消费额分成 4 个等级（四分位）
SELECT user_id, total_spend,
       NTILE(4) OVER (ORDER BY total_spend DESC) AS quartile
FROM user_stats;
```

消费额前 25% → quartile=1，最后 25% → quartile=4。 مربع 1 到 N 的桶号直接就是"等级"，前端渲染、运营圈人都方便。

NTILE 的三个关键行为：

**1. 行数除不尽时的分配规则**。10 行分 3 桶，前两桶各 4 行、第三桶 2 行——**前面的桶多分**。规则：前 `行数 % n` 个桶每个多 1 行。别指望"绝对均匀"，要么行数是 n 的倍数，要么接受前面桶稍多。

**2. ORDER BY 并列值的影响**。两个用户消费额一样，NTILE 判谁进前桶？不稳定——加唯一键进 ORDER BY。**分层逻辑必须可复现**，否则运营今天圈的人明天变了。

**3. 可以加 PARTITION BY**。"每个城市内的消费前 10%"：

```sql
SELECT city, user_id, total_spend,
       NTILE(10) OVER (PARTITION BY city ORDER BY total_spend DESC) AS decile
FROM user_stats;
```

这个组合是"分层抽样"的标准 SQL。

**业务语义常需要倒置**："VIP 前 5%" 该是桶 1 但只占 5%——`NTILE(20)` 取 `decile = 1`，而不是 NTILE(5)（那每桶 20%）。**NTILE 的 n 是"切成几等份看其一"，不是"取百分之几"**——这个理解偏差在需求沟通里高频出现。

## RANK 家族：三种排名，三种语义

三兄弟共享语法 `XXX() OVER (ORDER BY ...)`，差别全在**并列值怎么处理**：

| 函数 | 并列名次 | 名次跳跃 | 示例（3 人同分在第 2 名） |
|---|---|---|---|
| `ROW_NUMBER()` | 不重要（强行区分） | 1,2,3,4,5 | 1,2,3,4,5 |
| `RANK()` | 同名次 | 跳号（占位） | 1,2,2,4,5 |
| `DENSE_RANK()` | 同名次 | 不跳号 | 1,2,2,3,4 |

选型口诀：

- **唯一排名、取 Top N 绝对名次** → ROW_NUMBER。但它要求 ORDER BY 能定唯一序（加 ID 进 ORDER BY），否则同分行"谁是第 2"随机——取 Top 10 可能这次带张三下次带李四。
- **体育比赛式排名（同分同名次，后面跳过几个位置）** → RANK。金牌并列第 1，下一个是第 3。
- **分层/等级排名（同分同等级，等级连续）** → DENSE_RANK。"90 分以上是 A 等，80 分以上 B 等"。

Top N 查询的经典写法（比 LIMIT 稳，因为可以带并列）：

```sql
-- 每个品类销售额前 3 的商品（含并列）
WITH ranked AS (
    SELECT category, product, amount,
           DENSE_RANK() OVER (PARTITION BY category ORDER BY amount DESC) AS rk
    FROM product_sales
)
SELECT * FROM ranked WHERE rk <= 3;
```

注意用 DENSE_RANK 而不是 RANK 的语义选择：如果"第 3 名有 5 个并列"，RANK 会跳到 8，`WHERE rk <= 3` 全保留是对的；DENSE_RANK 下并列第 3 也返回 3，同样全保留。**两者在这里等价，但 DENSE_RANK 语义更像"等级门槛"**。

## FIRST_VALUE / LAST_VALUE：窗口内的头尾

取窗口内第一行/最后一行的某列值，也是"取目标行整体"的入口：

```sql
-- 每个用户的首次和末次订单信息
SELECT user_id, order_id, amount,
       FIRST_VALUE(order_id) OVER w AS first_order,
       LAST_VALUE(order_id) OVER w AS last_order
FROM orders
WINDOW w AS (PARTITION BY user_id ORDER BY created_at
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING);
```

**惊天大坑在这**：LAST_VALUE 的默认窗口框架是 `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`——**默认只到"当前行"**！不显式改成 `ROWS BETWEEN ... AND UNBOUNDED FOLLOWING`，每行的 LAST_VALUE 都是它自己。这是窗口函数最高频的错误，写一次坑一次。

`FIRST_VALUE` 也受框架影响，但默认框架从窗口开头到当前行——第一行永远不变，所以看起来对，掩盖了问题。**显式写清框架是好习惯**：`ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` 才是"真窗口"。

## 累计求和的两种姿态

报表里最常见的"年初至今累计"：

```sql
SELECT ym, revenue,
       SUM(revenue) OVER (ORDER BY ym
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ytd
FROM monthly;
```

默认框架恰好就是"从开头到当前行"，累计直接用 `SUM(revenue) OVER (ORDER BY ym)` 即可。但**框架语义必须懂**，因为换 `ORDER BY ym DESC`（倒序累计）时，默认框架变成"从窗口开头（最新月）到当前行"，累计的是"未来至今"，不是"年初至今"——要倒序累计得反过来想清楚框架边界。

占比计算同样经典：

```sql
SELECT product, amount,
       ROUND(amount / SUM(amount) OVER () * 100, 2) AS pct
FROM sales;
-- SUM() OVER () 空窗口 = 全表总和，每行除以它
```

## 窗口函数与性能

**排序是成本的瓶颈**。窗口函数必须对分区内数据排序。`(PARTITION BY 列, ORDER BY 列)` 的联合索引让执行计划出现 "Window function with optimization"——免 filesort，这是天花板优化。没有索引时大表窗口函数会 sort spill 到磁盘，`Sort_merge_passes` 告警。

**多个窗口可以共享排序**。`OVER w1`（PARTITION BY a ORDER BY b）和 `OVER w2`（PARTITION BY a ORDER BY c）需要两套排序；改成统一 `ORDER BY b, c` 再按需偏移，有时能省一次排序。**窗口定义的复用（WINDOW 子句）不只为了代码干净，也可能影响性能**。

**窗口函数结果不能下推过滤**。`WHERE rk <= 3` 不能用（窗口结果在 WHERE 之后算）——必须套 CTE/子查询。这也是 Top N 查询必须两段式写法的原因。

## 小结

NTILE 分桶做分层、RANK 家族做排名（并列语义决定选 RANK 还是 DENSE_RANK）、FIRST_VALUE/LAST_VALUE 取头尾值、SUM OVER 做累计占比。四件套的共同纪律：**ORDER BY 加唯一键保确定性、LAST_VALUE 记得扩框架到 FOLLOWING、窗口结果套子查询再过滤、PARTITION/ORDER 列建联合索引**。窗口函数写完先问自己"并列值和框架边界处理了吗"，比跑出数再调成本低得多。下一篇讲递归 CTE——用 SQL 处理树形和层级数据。
