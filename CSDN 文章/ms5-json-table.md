# JSON_TABLE：把 JSON 数组拍平成关系行的黑魔法

JSON 多值索引解决了"数组里找元素"，但如果需求是**把 JSON 数组当表查**——聚合、JOIN、窗口函数都招呼上——就需要另一件武器：`JSON_TABLE`。它把 JSON 数组/对象展开成虚拟的关系表，可以直接 JOIN、GROUP BY、WHERE。这篇文章从语法讲到报表实战，讲清它和多值索引的分工。

## JSON_TABLE 是什么：JSON → 关系行的翻译器

一句话：**在 FROM 子句里定义一个虚拟表，表的数据由一个 JSON 表达式展开而来。**

```sql
SELECT * FROM JSON_TABLE(
    '[{"tag":"5G","score":90},{"tag":"快充","score":80}]',
    '$[*]' COLUMNS (
        tag_name VARCHAR(50) PATH '$.tag',
        score INT PATH '$.score'
    )
) AS jt;
```

输出是一张标准的两行表：

| tag_name | score |
|---|---|
| 5G | 90 |
| 快充 | 80 |

这个虚拟表出现在 FROM 里，**拥有关系表的一切待遇**：JOIN 其他表、WHERE 过滤、GROUP BY 聚合、ORDER BY 排序。JSON 数组从此和 SQL 世界无缝衔接。

## 语法拆解

```sql
JSON_TABLE(
    json_expr,                      -- ① JSON 来源表达式（列、字面量、函数）
    path COLUMNS (                  -- ② path：从哪一层展开（'$[*]' 数组全元素）
        col_name type PATH 'json_path' [NOT NULL] [DEFAULT ...],
        col_name type EXISTS PATH 'json_path',        -- 布尔列：路径存在吗
        NESTED PATH 'json_path' COLUMNS ( ... )        -- 嵌套展开子对象/数组
    )
) AS alias
```

三个关键部分：**来源、展开路径、列映射**。`$[*]` 表示数组的每个元素一行；`$` 顶层；`$.items[*]` 深层数组。要展开对象的字段，`'$[*].name'` 这种 PATH 直接映射到列。

## 实战一：订单行内商品明细的报表

真实场景——orders 表里存了商品 JSON（反范式设计常见的妥协）：

```sql
CREATE TABLE orders (
    id BIGINT PRIMARY KEY,
    customer_id BIGINT,
    items JSON    -- [{"sku":"A1","qty":2,"price":100},{"sku":"B2","qty":1,"price":50}]
);
```

需求："统计每个 SKU 的总销量和销售额"——items 在行内，得先展开：

```sql
SELECT jt.sku,
       SUM(jt.qty) AS total_qty,
       SUM(jt.qty * jt.price) AS total_revenue
FROM orders o,
     JSON_TABLE(o.items, '$[*]' COLUMNS (
         sku VARCHAR(20) PATH '$.sku',
         qty INT PATH '$.qty',
         price DECIMAL(10,2) PATH '$.price'
     )) AS jt
WHERE o.created_at >= '2026-09-01'
GROUP BY jt.sku
ORDER BY total_revenue DESC;
```

`FROM orders o, JSON_TABLE(o.items, ...)` 这种**逗号连接等价于 JOIN**——每行 orders 的 items 展开成若干行 jt，一对多展开。数据模型上这叫"行内数组变行"，是 JSON_TABLE 的核心用途。

## 实战二：和普通表 JOIN

展开后 JOIN 维度表：

```sql
SELECT jt.sku, p.name, SUM(jt.qty * jt.price) AS revenue
FROM orders o
JOIN JSON_TABLE(o.items, '$[*]' COLUMNS (
    sku VARCHAR(20) PATH '$.sku',
    qty INT PATH '$.qty',
    price DECIMAL(10,2) PATH '$.price'
)) jt ON TRUE                                  -- LATERAL 语义必须
JOIN product p ON p.sku = jt.sku
WHERE o.customer_id = 100
GROUP BY jt.sku, p.name;
```

注意 `ON TRUE`——JSON_TABLE 对 o.items 的引用是 **LATERAL 语义**（横向依赖：JSON_TABLE 的输入依赖外层表 o 的当前行），JOIN 条件写 ON TRUE 是强制 lateral 的语法。MySQL 8.0 里 JSON_TABLE 出现在 JOIN 左侧时也天然按 lateral 处理，但显式写 ON TRUE 更清晰、跨版本更稳。

**JOIN 顺序有讲究**：先在 orders 上有过滤（customer_id、created_at），又做了 JSON 展开，最后 JOIN product——三层都由优化器排，但 LATERAL 语义下 JSON_TABLE 必须紧贴它的输入表（orders），不能写到 product 后面。写反了报错。

## 实战三：NESTED 嵌套展开

数组里还有子数组/子对象：

```sql
SELECT jt.order_id, item.sku, it.v
FROM orders o
JOIN JSON_TABLE(
    o.items,
    '$[*]' COLUMNS (
        order_id BIGINT PATH '$.order_id',     -- 有点怪，但为了演示
        sku VARCHAR(20) PATH '$.sku',
        NESTED PATH '$.variants[*]' COLUMNS (
            v VARCHAR(20) PATH '$'
        )
    )
) jt ON TRUE
JOIN JSON_TABLE(...) item ON ...;
```

NESTED PATH 展开更深层结构——外层一个元素，如果它的 `$.variants` 是数组，就再展开出多行。**多层 JSON 的完全关系化，NESTED 是标准路径**。实践中三层以上就该停下来想想这 JSON 是不是该拆表了。

## 性能真相：JSON_TABLE 不快，但省代码

必须坦白：**JSON_TABLE 不加速查询，它是个语法翻译器**。它的执行本质是"对每行源数据解析 JSON、生成临时行流"。评估它的正确姿势：

| 对比项 | JSON_TABLE | 拆表（规范化） |
|---|---|---|
| 查询性能 | 慢（JSON 解析开销每行每次） | 快（索引、连接全优化） |
| 写入性能 | 一次写行内 JSON | 多表写入事务 |
| 数据一致性 | 无外键约束 | 可约束 |
| 查询灵活性 | 拍平后 SQL 全支持 | 原生关系模型 |
| 存储 | 紧凑（反范式） | 膨胀（范式化） |

**JSON_TABLE 的适用判断**：日志型/事件型数据（写一次读少量）、半结构数据（schema 不稳定）、报表低频批处理——用 JSON 列 + JSON_TABLE 省建模成本、性能可接受。**高频查询、核心交易链路，JSON_TABLE 只能是过渡方案**——把热查询的字段拆成正列 + 索引，才是终局。

一个折中模式：JSON 列存"冷字段全集"，把"热查询字段"复制到生成的虚拟列加索引。读走虚拟列索引，写时冗余维护。这就是上一篇 functional index 和本篇的组合拳思路。

## 常见报错与陷阱

1. **LATERAL 引用报错**。JSON_TABLE 引用了外层表列但位置不对（在 JOIN 右侧之前没先 reference）。把 JSON_TABLE 放 FROM 最后、加 ON TRUE，多数情况解决。
2. **PATH 写错静默返回 NULL**。`'$.sku'` 拼成 `'$.skus'`，不报错、列全 NULL——JSON_TABLE 对找不到路径默认给 NULL 而不是错误。**调试时先 SELECT 不套聚合，看展开结果对不对**。
3. **列类型不匹配转换失败**。JSON 里 `"qty":"2"`（字符串），列定义 INT，转换失败行被丢弃。源数据脏 = 展开结果缺行，比报错更危险。
4. **大数组展开爆炸**。一个 items 数组 5000 个元素，每行订单展开 5000 行，JOIN 后结果集爆炸。先在 JSON_TABLE 外层加 LIMIT 或用 WHERE 收缩源行数。
5. **和 GROUP BY 的配合**。展开后的列名直接可用在 GROUP BY/SELECT，但别把 JSON_TABLE 的派生列和源表列搞混——别名冲突时用 `jt.` 限定。

## 小结

JSON_TABLE 把 JSON 数组/对象翻译成关系表：行内商品明细报表、嵌套结构展开、和普通表 JOIN，全靠 FROM 子句里这张虚拟表。它不提供性能魔法——每行 JSON 解析的开销实打实——但把"JSON 当表查"从应用层 for 循环里搬进了 SQL，报表和临时分析场景省的是海量代码。核心链路的高频查询，依然要回归拆表 + 索引。下一篇回到索引主线：函数索引——给表达式加索引的正确姿势。
