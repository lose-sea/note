# EXPLAIN FORMAT=JSON：机器可读的计划里藏着什么

前两篇读了 TREE 格式的树和 ANALYZE 的实测，有些信息在两者里都不直接显示：缓冲池命中率、每个过滤条件的选择性估算、成本计算的明细、分区裁剪的实际效果。这些都在 `FORMAT=JSON` 的输出里。这篇文章讲 JSON 格式怎么读、哪些字段值得盯、怎么程序化利用它。

## 拿到 JSON

```sql
EXPLAIN FORMAT=JSON
SELECT c.id, c.name, SUM(o.amount)
FROM customer c JOIN orders o ON o.customer_id = c.id
WHERE o.created_at BETWEEN '2026-01-01' AND '2026-03-31'
GROUP BY c.id;
```

返回一行 text 类型字段，里面是 JSON。可以用 MySQL 客户端命令格式化后阅读：

```sql
EXPLAIN FORMAT=JSON SELECT ...\G
```

## 结构总览

JSON 输出的顶层结构：

```json
{
  "query_block": {
    "select_id": 1,
    "cost_info": { "query_cost": "18540.25" },
    "ordering": {"could_be_ordered_by_key": true},
    "grouping": {"using_filesort": false, "using_temporary_table": false},
    "join": {
      "nested_loop": [
        { "table": {"table_name": "c", ...} },
        { "table": {"table_name": "o", ...} }
      ]
    }
  }
}
```

复杂查询会有嵌套的 query_block（子查询）、层层 join 描述。和 TREE 格式信息同源，但 JSON 有三个 TREE 不给的东西：**cost_info 明细、attached_condition、rows_produced_per_join 等精确字段**。

## 最值得盯的五个字段

### 1. cost_info.query_cost

整个查询的总成本，优化器横向比较不同计划的依据。单看没有绝对意义，但"加索引前后 query_cost 的变化"是优化有效性的硬指标。

### 2. read_cost / eval_cost / prefix_cost（cost_info 里）

成本被拆成三块，这个拆分有实际指导意义：

```json
"cost_info": {
  "read_cost": "15200.40",
  "eval_cost": "339.85",
  "prefix_cost": "15540.25",
  "data_read_per_join": "1M"
}
```

- **read_cost**：IO 成本——从表/索引读数据的开销。大头，优化器的努力方向。
- **eval_cost**：CPU 成本——比较、条件判断的开销。
- **data_read_per_join**：每次 join 预计读的数据量。**这个数爆表（几百 M、几个 G）意味着中间结果过大，JOIN 策略迟早要崩**。

### 3. rows_examined_per_scan / rows_produced_per_join

```json
"join": {
  "nested_loop": [
    {
      "table": {
        "rows_examined_per_scan": 9865,
        "rows_produced_per_join": 418,
        "filtered": "4.24",
        ...
      }
    }
  ]
}
```

TREE 也显示行数，但 JSON 多了 **filtered 字段——过滤后剩余百分比**。上例：扫了 9865 行，只有 4.24% 通过过滤。这个百分比直接告诉你这个过滤条件有多"毒"：4% 意味着几乎全扫全扔，条件要么加索引，要么确认它本身就该这么低（比如查某个稀有状态）。

### 4. attached_condition

```json
"table": {
  "table_name": "o",
  "attached_condition": "(`o`.`created_at` between '2026-01-01' and '2026-03-31')"
}
```

**优化器把这个条件下推到引擎层执行**——它是索引条件（如果是索引列）还是回表后过滤，一目了然。出现在 attached_condition 里的非索引列条件，就是"回表过滤"的元凶。和 TREE 格式里的 Filter 对应，但 JSON 里每个条件的归属更清楚。

### 5. buffer_result / 缓冲池命中

某些版本会显示 `cache_hit` 相关字段（信息在 Optimizer trace 里更全）。TREE 完全不给这类信息，这也是 JSON 格式的独有价值。

## 一个完整 JSON 的逐段解读

```json
{
  "query_block": {
    "select_id": 1,
    "cost_info": {"query_cost": "18540.25"},
    "grouping": {"using_filesort": false, "using_temporary_table": false},
    "ordering": {},
    "join": {
      "nested_loop": [
        {
          "table": {
            "table_name": "c",
            "access_type": "index",
            "key": "idx_name",
            "used_key_parts": ["name"],
            "key_length": "102",
            "rows_examined_per_scan": 5000,
            "rows_produced_per_join": 5000,
            "filtered": "100.00",
            "cost_info": {"read_cost": "5000.00", "eval_cost": "500.00"}
          }
        },
        {
          "table": {
            "table_name": "o",
            "access_type": "ref",
            "key": "idx_customer",
            "used_key_parts": ["customer_id"],
            "rows_examined_per_scan": 3,
            "rows_produced_per_join": 12500,
            "filtered": "33.33",
            "attached_condition": "(`o`.`created_at` between ... )",
            "cost_info": {"read_cost": "12500.40", "eval_cost": "2500.00"}
          }
        }
      ]
    }
  }
}
```

三层解读：

1. **customer 表走全索引扫描**（access_type: index）。没有 WHERE 条件收窄它，5000 行全参与。如果业务上 customer 表很大（百万级），这里就该反思：GROUP BY c.id 是否需要全表。
2. **orders 表 ref 查找**，每行 customer 查出约 3 条订单，但 filtered 33%——created_at 条件把多数订单滤掉了。**idx_customer 只覆盖了 customer_id，created_at 是回表条件**。优化方向：把 created_at 纳入联合索引 `(customer_id, created_at)`，过滤率直接反应到 read_cost 上。
3. **查询总成本 18540，其中 read_cost 占大头**。典型的"join 读太多"，JOIN 结构本身有优化空间（是否所有 customer 都要连 orders？半连接能否改写）。

## 程序化利用：把 EXPLAIN 接进工作流

JSON 格式的最大价值是**能被程序解析**。三个实战场景：

**场景一：慢查询自动分析器**。从慢日志收集 SQL，对每条自动 EXPLAIN FORMAT=JSON，提取 `access_type=ALL`（全表扫描）的记录告警：

```python
import json, subprocess

def find_full_scans(sql: str) -> list:
    out = subprocess.run(
        ["mysql", "-e", f"EXPLAIN FORMAT=JSON {sql}"],
        capture_output=True, text=True).stdout
    plan = json.loads(out)
    hits = []
    def walk(node):
        if isinstance(node, dict):
            t = node.get("table", {})
            if t.get("access_type") == "ALL":
                hits.append(t.get("table_name"))
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(plan)
    return hits
```

**场景二：回归测试**。发布前跑一遍核心 SQL 的 EXPLAIN，把 query_cost 记录成基线。新版本 query_cost 涨了 30%？索引被误删或者统计信息出问题的信号。比等用户投诉快一个数量级。

**场景三：索引设计的量化评估**。打算加 `(customer_id, created_at)` 联合索引？先在测试库建索引，前后 EXPLAIN 对比 read_cost：从 12500 降到 800，预期收益到手，再上生产。**用数据说话，别拍脑袋加索引**。

## JSON vs TREE：日常怎么选

结论：**人读用 TREE，机器读用 JSON，深挖细节用 JSON**。TREE 的树形结构符合人的思维习惯，JSON 的扁平字段符合程序的处理逻辑。但下面这几个问题只有 JSON 能干净回答：

- 这个条件的过滤率是多少（filtered）？
- 成本里 IO 占多少、CPU 占多少（read_cost/eval_cost）？
- 优化器把这个条件放在哪层执行（attached_condition 的嵌套层级）？
- 每次 join 预计读多少数据（data_read_per_join）？

这些问题在深度优化时是决策依据，TREE 要么不给、要么给得不全。**日常扫一眼用 TREE，准备动刀用 JSON。**

## 细节：JSON 输出的坑

1. **JSON 里没有 costs 的绝对基准**。跨 MySQL 版本比较 cost 数值意义不大，同环境同类查询比较才有意义。
2. **执行计划是采样估算的，不一定全**。直方图、预计算统计不到的场景，JSON 里的行数估算照样会偏。偏差大时，回 EXPLAIN ANALYZE 用实测数据校准。
3. **输出可能很长**。复杂子查询的 JSON 上千行，用客户端命令（`\G`）分行看，或者 jq 提取字段：`... | jq '.query_block.join.nested_loop[1].table.filtered'`。

## 结语

EXPLAIN FORMAT=JSON 把执行计划从"人看的树"变成"程序能读的结构"。filtered 告诉你条件有多毒，read_cost 告诉你 IO 负担在哪，attached_condition 告诉你过滤发生在哪一层。把它接进慢查询分析、发布回归和索引评估的自动化流程，执行计划就从调试时的临时检查，变成了持续运行的质量信号。下一篇开始谈重头戏：JOIN 算法——优化器怎么在嵌套循环和哈希连接之间做选择。
