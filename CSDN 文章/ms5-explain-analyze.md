# EXPLAIN ANALYZE：从"优化器以为"到"实际执行"的真相

上两篇文章我们读了 EXPLAIN 的输出——那是优化器的**计划**，它打算怎么执行。但计划和现实之间隔着一整套执行器：预估行数可能差之千里，排序可能真的落到磁盘，JOIN 可能用了另一条分支。EXPLAIN ANALYZE 要做的，就是把 SQL 真的跑一遍，把**实际的执行统计**打在计划旁边。这篇文章讲它怎么读、和普通 EXPLAIN 的差异在哪、以及那些真正决定性能的隐藏列。

## 语法与一个最小示例

```sql
EXPLAIN ANALYZE
SELECT o.id, c.name
FROM orders o JOIN customer c ON o.customer_id = c.id
WHERE o.created_at >= '2026-01-01'
ORDER BY o.amount DESC
LIMIT 20;
```

注意两件事：**它会真的执行这条 SQL**。对 SELECT 这没问题；如果语句本身有副作用（`UPDATE`、`DELETE`、`INSERT ... SELECT`），EXPLAIN ANALYZE 也会照做——在生产和测试环境都要留神，先用 BEGIN 包起来 ROLLBACK，或者至少确保 WHERE 范围受控。MySQL 8.0.18+ 还支持 `EXPLAIN ANALYZE FORMAT=TREE`（默认树形）和 `FORMAT=JSON`，READ COMMITTED 下会显示实际读到的行数统计。

树形输出长这样：

```
-> Limit: 20 row(s)  (actual time=0.412..0.419 rows=20 loops=1)
    -> Sort: o.amount DESC  (actual time=0.410..0.413 rows=20 loops=1)
        -> Stream results: (actual time=0.072..0.385 rows=1732 loops=1)
            -> Nested loop inner join  (actual time=0.068..0.337 rows=1732 loops=1)
                -> Filter: (o.created_at >= DATE'2026-01-01')  
                    (cost=112.50 rows=1721) (actual time=0.037..0.176 rows=1732 loops=1)
                    -> Table scan on o  (cost=112.50 rows=9865)
                        (actual time=0.035..0.143 rows=9865 loops=1)
                -> Single-row index lookup on c using PRIMARY (customer_id=o.customer_id)
                    (cost=1.00 rows=1) (actual time=0.0001..0.0002 rows=1 loops=1)
```

## 看懂三个关键元信息

### 1. actual time=首行..末行

每个操作都给出**首行返回时间**（time=后面第一个数）和**全部行返回时间**（第二个数）。差异本身就是信息：排序、聚合这类物化操作，首行和末行差得远（要等所有行到齐才能出第一行）；流式操作（Stream results）两者接近。

定位慢查询的第一刀就看这个数：从最外层往最内层读，**第一个 actual time 绝对值突增的操作，通常就是瓶颈所在**。上例里 0.072 → 0.385 的 Stream results 表示整个查询的肉都埋在 join 里，而不是排序里——排序只花了 0.03 秒。

### 2. rows=实际行数

每个操作的 rows 显示了它实际处理了多少行。这个连起来看非常有信息量：

- **rows 与预估差一个数量级** → 统计信息过期，优化器在做错误决策。这张表该 ANALYZE TABLE 了，或者选择性太高的列该加直方图。
- **rows 随 loops 放大** → 嵌套循环里，内层每次 loop 处理多少行决定了总工作量。loops=1732、每次 rows=1 是健康形态；loops=9865、每次 rows=50 的 nested loop 就是灾难前兆。

### 3. loops=循环次数

只在 JOIN/子查询里出现，表示这个子操作被执行了多少次。**loops × rows = 这个操作的真实总工作量**。这个乘积经常让人后背发凉：EXPLAIN 里一个 `rows=1` 的索引查找，在 loops=1,000,000 的驱动下就是一百万次。

## EXPLAIN vs EXPLAIN ANALYZE：什么时候用哪个

| 维度 | EXPLAIN | EXPLAIN ANALYZE |
|---|---|---|
| 是否执行 | 不执行 | **执行** |
| 数字含义 | 预估（估算成本/行数） | 实测（时间/行数） |
| 副作用 | 无 | 有（写语句会真写） |
| 时间成本 | 微秒 | 等于查询本身耗时 |
| 主要用途 | 看索引选择、看 join 顺序 | 找真瓶颈、验证预估偏差 |

日常工作流：**先用 EXPLAIN 砍掉明显的烂计划（全表扫描、错误索引），再用 EXPLAIN ANALYZE 定位真问题**。因为 ANALYZE 要跑真查询，慢查询（比如十秒的报表）每次调试都跑十秒，先用预估版筛一轮更高效。

## 四个实战判断范式

### 范式一：预估和实测差了十倍

```
-> Filter: (status = 'active')  (cost=85.50 rows=8) (actual ... rows=8420 loops=1)
```

预估 8 行实际 8420。优化器基于这个错误预估选择了后续的 nested loop join（它以为驱动表出来就 8 行，被驱动表少查几次无所谓），实际因为 8420 行多查了八千次。修法：

```sql
ANALYZE TABLE orders;              -- 最基本的修正
-- 还不行，说明分布倾斜，用直方图（8.0+）
ANALYZE TABLE orders UPDATE HISTOGRAM ON status;
-- 或者显式矫正
SELECT * FROM orders IGNORE INDEX(idx_status) WHERE ...;
```

### 范式二：Sort 落盘了

```
-> Sort: o.amount DESC  (actual time=95.3..97.1 rows=20000 loops=1)
      -> ...
        -> 出现 "Sorting files" / 或内存不足告警
```

`sort_buffer_size` 装不下要排序的数据，MySQL 就会用文件排序（归并排序到临时文件），磁盘 IO 让排序慢十倍。一眼判断：actual time 里排序阶段占了大头，输出里伴随临时表/文件提示。修法：加匹配 ORDER BY 的索引、减小排序列宽度、临时调大 sort_buffer（会话级）。

### 范式三：loops 炸弹

```
-> Nested loop inner join  (actual time=95.0..120.0 rows=50000 loops=1)
    -> Index scan on o  (rows=50000)
    -> Index lookup on c  (rows=1 loops=50000)   ← 这里
```

loops=50000，每次都做一次索引查找——**看起来每次 rows=1 很便宜，乘以 50000 就是全表扫描级别的工作量**。这时候该考虑：驱动表是不是选错了？该用 hash join（8.0.18+ 自动启用）还是给被驱动表加更好的索引？或者干脆把 join 改写成 semi-join 结构？

### 范式四：Using where 比 Using index 慢

```
-> Index scan on orders using idx_created (actual ... rows=9865)
    -> Filter: (amount > 1000)  (actual ... rows=1732)
```

回表 + 过滤后只剩 1732 行。这说明索引只命中了 WHERE 的一个条件，另一个条件要回表才能判。看 `Filter` 的实测行数 vs 上层 rows，可以判断这个"先宽取再筛"的策略是否划算。尝试把 amount 条件做成联合索引的一部分，或者干脆用覆盖索引。

## 几个容易忽略的细节

**actual rows 是四舍五入前的近似**。行数统计每 loops 会采样，输出显示的是平均值。loops 很大时，看平均数不如看总数（需要自己乘）。MySQL 8.0.x 有些版本对 rows 的显示精度做了取舍，不要拿它做毫秒级审计。

**Cache hit 信息要看 EXPLAIN FORMAT=JSON**。树形格式看不到缓冲池命中率，JSON 格式里有更完整的执行细节。想深挖缓存行为，切 JSON 输出。

**并发影响实测**。EXPLAIN ANALYZE 跑在一次真实查询上，缓冲池冷热、并发负载都影响结果。同一 SQL 在空闲时和业务高峰时跑，actual time 可能差几倍。性能结论要区分"这条 SQL 本身多大开销"和"当前负载下多大开销"。

**不要在生产直接 EXPLAIN ANALYZE 一个大查询**。它等于把慢查询再跑一遍。线上诊断的规矩：先在从库跑、或者复制 schema + 造数到离线环境跑。想在生产直接跑，至少加 `LIMIT` 缩小规模——虽然 LIMIT 会改变计划（下一篇讲下推），但看大体结构够用。

## 结语

EXPLAIN ANALYZE 是 MySQL 优化师的"无影灯"：计划是猜测，实测才是手术台上的实况。actual time 看时间花在哪、rows 和 loops 看工作量乘在哪、预估与实测的偏差看统计信息要不要修。把这三个信号读熟，你就从"看 EXPLAIN 猜"进化到"看 ANALYZE 断"。下一篇讲 EXPLAIN 的 JSON 输出——同样的信息，机器可读的格式里藏着更多细节。
