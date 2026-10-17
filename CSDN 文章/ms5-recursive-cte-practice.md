# 递归 CTE：用 SQL 处理组织树、目录树与层级数据

"查一个部门下所有子孙部门""取某个目录的全部子文件""数一数这个分类有多少层后代"——这类层级查询，应用层递归查库（for 循环里发 SQL）是新手做法，MySQL 8.0 的**递归 CTE**（Recursive Common Table Expression）用一条 SQL 搞定。这篇文章从语法结构讲起，跑通组织树、目录树两个真实场景，最后讲递归深度控制和性能边界。

## 语法结构：两段式和自引用

递归 CTE 的骨架永远是两部分：

```sql
WITH RECURSIVE cte_name AS (
    -- ① 初始查询（锚点 member）：递归的起点，返回第一批行
    SELECT ...
    UNION [ALL]
    -- ② 递归查询：引用 cte_name 自身，每次基于上一批结果产生下一批
    SELECT ... FROM cte_name JOIN real_table ...
)
-- ③ 外部使用
SELECT * FROM cte_name;
```

执行器的行为类似迭代：先跑锚点得到初始集，把结果喂给递归部分，递归部分输出新行追加到结果集并成为下一轮输入，**直到递归部分返回空行，递归终止**。这就是"宽度优先"的层级展开。

最小示例——从 1 号部门开始展开子部门：

```sql
WITH RECURSIVE dept_tree AS (
    -- 锚点：根部门
    SELECT id, parent_id, name, 0 AS depth, CAST(id AS CHAR(200)) AS path
    FROM dept WHERE id = 1
    UNION ALL
    -- 递归：上一批部门的直接子部门
    SELECT d.id, d.parent_id, d.name, dt.depth + 1,
           CONCAT(dt.path, ',', d.id)
    FROM dept d
    JOIN dept_tree dt ON d.parent_id = dt.id
)
SELECT * FROM dept_tree ORDER BY path;
```

注意 `path` 这一列——**它是递归查询的保命设计**。层级展示要保序，单纯 id 列表 sort 会乱，把访问路径拼成字符串排序，输出天然是按树的先序排列。这也是递归查询里最常用的技巧。

## 场景一：组织架构树

```sql
WITH RECURSIVE org AS (
    SELECT id, name, manager_id, 0 AS lvl,
           name AS org_path
    FROM employee WHERE name = '张三'          -- 从某人开始查下属
    UNION ALL
    SELECT e.id, e.name, e.manager_id, o.lvl + 1,
           CONCAT(o.org_path, ' / ', e.name)
    FROM employee e
    JOIN org o ON e.manager_id = o.id
)
SELECT lvl, id, name, org_path FROM org ORDER BY org_path;
```

输出形如：

```
lvl | id  | name    | org_path
0   | 1   | 张三    | 张三
1   | 12  | 李四    | 张三 / 李四
2   | 45  | 王五    | 张三 / 李四 / 王五
2   | 46  | 赵六    | 张三 / 李四 / 赵六
1   | 13  | 孙七    | 张三 / 孙七
```

`lvl` 做层级缩进渲染、`org_path` 做前端树形组件的数据源。应用层拿这一份扁平数据自己建树，比递归接口调用快且代码少。

**去重与防环**：真实组织树有环（A 的 manager 是 B，B 的 manger 是 A，脏数据），递归会死循环炸掉 max_execution_time。防环手段：

```sql
-- path 里拿 'A' 格式防环：子部门路径里已经出现过自己就掐断
JOIN dept_tree dt ON d.parent_id = dt.id
WHERE FIND_IN_SET(d.id, dt.path) = 0
```

`FIND_IN_SET` 检查新 id 是否已经在祖先路径里。**生产递归 CTE 必须带这个条件**，脏数据兜底。

## 场景二：目录树与权限过滤

文件目录更典型：

```sql
WITH RECURSIVE folder_tree AS (
    SELECT id, parent_id, name, 0 AS depth
    FROM folder WHERE user_id = 100 AND parent_id IS NULL   -- 根目录
    UNION ALL
    SELECT f.id, f.parent_id, f.name, ft.depth + 1
    FROM folder f
    JOIN folder_tree ft ON f.parent_id = ft.id
    WHERE f.user_id = 100                                     -- 权限过滤
)
SELECT * FROM folder_tree;
```

两个值得注意的点：

1. **权限过滤下推**。每一层都加 `user_id = 100`，没权限的分支不会进递归结果。别在最后才过滤——递归过程中已经带上过滤，效率和语义都对。
2. **叶子判断**。想知道哪些目录没有子目录（叶子），LEFT JOIN 一层或用递归结果里"id 不作为任何 parent_id 出现"判断，按场景选。

## 场景三：累计层级统计

递归 CTE 也能做统计——每个部门的总薪资：

```sql
WITH RECURSIVE org AS (
    SELECT id, manager_id, salary FROM employee WHERE id = 1
    UNION ALL
    SELECT e.id, e.manager_id, e.salary
    FROM employee e JOIN org o ON e.manager_id = o.id
)
SELECT COUNT(*) AS headcount, SUM(salary) AS total_salary
FROM org;
```

先递归取全员再聚合。**注意 SUM(salary) 要明确包含根节点自己**（锚点里选了根），这类"包括自己吗"的语义问题在递归统计里高频出错。

## 深度控制与 max_recursive_iterations

MySQL 8.0 递归默认上限由系统变量控制：

```sql
SELECT @@max_recursive_iterations;   -- 默认 1000
SET SESSION max_recursive_iterations = 65535;  -- 需要更深时调
```

到达上限还没收敛 → 报错 `ER_CTE_MAX_RECURSION_DEPTH`。这不是 bug，是防环保护——**正常业务树（目录、组织）极少超过 100 层**。真需要深层递归（比如展开一个超大分类树），考虑拆批或预先物化路径枚举（路径字符串方案，下篇讲）。默认 1000 撞上限，先怀疑是不是有环或 path 走错。

## UNION ALL vs UNION

递归成员用 `UNION ALL` 还是 `UNION`：**默认 UNION ALL**（不去重，快）。有环时 UNION ALL 死循环；用 UNION（去重）理论上能自行终止——第二轮重复行产生即停。但别指望 UNION 当防环主力（去重比较开销大且不覆盖"多项式重复行插入"的毒场景），**FIND_IN_SET path 防环 + UNION ALL 是标准姿势**。

## 性能边界：递归不是银牌

递归 CTE 的三个已知短板，心里要有数：

1. **索引是必须的**。递归部分 `ON e.manager_id = o.id`，manager_id 没索引 = 每轮全表扫 employee。组织树查询爆炸，先看执行计划里有没有索引查找。
2. **大分支宽度敏感**。树宽（每层节点数）比树深更影响性能——一万个下级节点的层，一次递归轮就是一整批 join。
3. **替代方案**：数据量小（万级以内）直接用递归 CTE；大规模层级频繁查，考虑**路径枚举**（parent_path 字符串，点 LIKE 前缀取子树）或**闭包表**（单独的关系表记录所有祖先-后代对）。路径枚举的子树查询 `WHERE path LIKE '1/3/%'` 走索引比递归快，代价是写路径要维护。

**递归 CTE 是读优化的甜点，写复杂场景（频繁增删层级节点）要转向路径枚举或闭包表。**

## 小结

递归 CTE 三段式：锚点定起点、递归成员自引用扩展、外部消费。path 列排序保树序、FIND_IN_SET 防环、每层权限下推、max_recursive_iterations 兜底——四条纪律守住生产可用性。它把应用层的 for 循环查库收敛成一次 SQL，从组织架构到目录权限都够用；超大规模层级则记住路径枚举和闭包表这两条退路。下一篇谈混合型数据的实操：JSON 列的多值索引。
