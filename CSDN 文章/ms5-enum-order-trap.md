# MySQL ENUM 的坑：为什么 ORDER BY 排出的顺序"不正常"

一张状态表，`status ENUM('pending','paid','shipped')`，用 `ORDER BY status` 排序——结果第一条是 `pending`，看起来很对。但某天你 `ALTER` 加了一个新状态 `cancelled`，排序突然乱了；想把状态的值取出来做判断，`WHERE status = 2` 居然也能查；导出 CSV 发现 `status` 变成数字……ENUM 这个"省事小棉袄"，坑都藏在细节里。这篇文章一次讲透：ENUM 到底怎么存、排序为什么反直觉、和字符串比较的陷阱、什么时候该用它、以及什么时候必须换成查找表。

## 一、ENUM 的本质：数字加映射

ENUM 不是字符串，它的物理存储是**整数索引 + 值列表**：

```sql
CREATE TABLE t_order (
  id BIGINT PRIMARY KEY,
  status ENUM('pending','paid','shipped')
);
```

MySQL 内部维护的事实在 `information_schema` 里：

```sql
SELECT column_name, column_type, extra 
FROM information_schema.columns 
WHERE table_name='t_order' AND column_name='status';
-- column_type: enum('pending','paid','shipped')
```

实际存储时，每个值对应一个序号：

| 字面值 | 内部索引 |
|---|---|
| `pending` | 1 |
| `paid` | 2 |
| `shipped` | 3 |
| `''`（错误插入的空串） | 0 |
| `NULL` | NULL |

存储只占 1~2 字节（值多于 255 个时 2 字节）。**这意味着三件事：排序按索引比、空串是合法值且索引为 0、修改列表会牵动所有索引。**

## 二、陷阱一：ORDER BY 按索引排序，不是按字母

这是 ENUM 最经典的问题：

```sql
INSERT INTO t_order (status) VALUES ('shipped'),('pending'),('paid');

SELECT * FROM t_order ORDER BY status;
-- 结果顺序：pending, paid, shipped（按定义顺序 1,2,3，不是字母序）
```

**定义顺序即排序规则**，`ORDER BY status DESC` 则完全反过来：`shipped, paid, pending`。如果业务期望"按字母/按创建时间/按自定义优先级"，ENUM 默认行为基本一定不符合预期——而开发者往往到上线后才发现"排序怎么是乱的"。

想要别的排序，得显式处理：

```sql
-- 按字母排（把枚举值当字符串）
SELECT * FROM t_order ORDER BY status + 0, status;   -- +0 是历史 hack
-- 正确做法：按字符串比较
SELECT * FROM t_order ORDER BY CAST(status AS CHAR);

-- 按自定义优先级：FIELD() 函数
SELECT * FROM t_order ORDER BY FIELD(status, 'paid','pending','shipped');
```

`FIELD()` 有个好处：**顺序完全可控**，且新加状态时只改这一处 SQL。但 `ORDER BY FIELD(...)` 和 `CAST` 都用不上索引——大表排序走 filesort，这是 ENUM 排序的隐性成本。

**生产建议**：任何"状态需要按业务优先级排序展示"的列表页，用 `FIELD()` 显式排，并在代码注释里写清楚优先级定义。

## 三、陷阱二：空串索引 0 —— "脏值"是合法插入

ENUM 有一个魔鬼细节：插入一个不在列表里的值，行为取决于 `sql_mode`：

```sql
-- 严格模式（默认）：直接报错
INSERT INTO t_order (status) VALUES ('cancelled');
-- ERROR 1265 (01000): Data truncated for column 'status' at row 1

-- 非严格模式（老库常见）：静默插入空串 ''
```

非严格模式下插入 `'cancelled'` → 存进 `''`（索引 0）。这个空串在业务上等于"未知状态"，但它是合法值、能查出来、还会参与统计——`COUNT(*) WHERE status=''` 一脸懵。

更坑的是排序：空串索引 0 **永远排在最前**：

```sql
SELECT * FROM t_order ORDER BY status;
-- '', pending, paid, shipped   —— 空串永远第一个
```

**防御动作**：

1. 确认 `sql_mode` 含 `STRICT_TRANS_TABLES`（8.0 默认严格）；
2. 插入前应用层校验枚举值；
3. 定期扫脏值：`SELECT DISTINCT status FROM t_order WHERE status = ''`；
4. **禁止在非严格模式的历史库上继续写 ENUM 表**。

## 四、陷阱三：数字和字符串混用比较

ENUM 的"半数字半字符串"人格，让 `WHERE` 条件写法充满误区：

```sql
-- 这三种写法都能工作，但含义不同！
SELECT * FROM t_order WHERE status = 2;        -- 按索引比，等价于 'paid'
SELECT * FROM t_order WHERE status = 'paid';   -- 按字符串比
SELECT * FROM t_order WHERE status = '2';      -- 字符串 '2'，无此值，查不到东西
```

- `status = 2` 走索引比较，能用上索引；
- `status = '2'` 是字符串字面量，列表里没有 `'2'` 这个值 → 返回空（非严格模式下还可能有意外行为）；
- `status = 0` / `status = ''` 查到的是脏值空串。

索引能正常用上——`WHERE status='paid'` 和 `WHERE status=2` 都会走索引，这点 ENUM 表现合格。但**可读性是灾难**：`WHERE status=2` 这种代码，三个月后没人知道 2 是什么。规范：**永远用字符串字面量比较，禁止用数字索引。**

## 五、陷阱四：ALTER 改列表 = 危险的全局操作

给 ENUM 加一个值，看起来人畜无害：

```sql
ALTER TABLE t_order MODIFY status 
  ENUM('pending','paid','shipped','cancelled') NOT NULL;
```

实际上发生的是：**全表扫描重建这一列的所有值映射**。MySQL 会重新给每个值编号——在**末尾追加**是安全的（原有序号不变），但如果你把新值插在中间：

```sql
-- 把 refunded 插在中间！
ALTER TABLE t_order MODIFY status 
  ENUM('pending','refunded','paid','shipped') NOT NULL;
-- 原来的 'paid'(2) 变成 3，'shipped'(3) 变成 4
```

序号全变，`ORDER BY status` 的排序结果全变，任何依赖旧序号的应用逻辑（`WHERE status=2`）全线出错。**这是 ENUM 最大的坑：一次 ALTER 改变全表数据的排序语义。**

**安全操作纪律：**

1. **新值只追加到末尾**，绝不插中间；
2. 改列表走 gh-ost/pt-osc，与应用发布解耦（先加值、发代码用新值、再清理旧值）；
3. 改完立即验证：`SELECT status, COUNT(*) FROM t_order GROUP BY status` 看映射是否符合预期；
4. 想彻底重排？别改 ENUM 定义，用 `ORDER BY FIELD()` 在查询层做——改定义的重建成本太高。

还有个细节：`ALTER` 改 ENUM 在大表上会重建表（MySQL 5.6 前），即使只是在末尾加值——在线 DDL 工具能缓解锁表，但 binlog 里仍会产生全行更新，从库延迟要盯。

## 六、字符串函数对 ENUM 都有效——以及它们的坑

因为 ENUM 在多数上下文里表现像字符串，这些函数全都能用，但结果未必如你所愿：

```sql
SELECT UPPER(status) FROM t_order;      -- 'PENDING' 返回大写
SELECT CONCAT('订单状态: ', status);     -- 拼接正常
SELECT LENGTH(status) FROM t_order;     -- 返回值的字符长度，不是索引
SELECT status + 0 FROM t_order;         -- ！返回索引数字，老 hack
```

`status + 0` 这个 hack 在 8.0 已失效（会报错或返回 0），老代码里的 `ORDER BY status + 0` 要注意兼容。另外：

- `LIKE` 可用但不走索引，且 `status LIKE 'pa%'` 匹配的是枚举值字符串；
- 日期/数字函数对 ENUM 无效；
- `GROUP BY status` 按字符串分组（视觉上），底层还是索引。

## 七、ENUM vs 查找表：什么时候必须换

ENUM 适合的场景其实很窄：**值极少（≤5 个）、永不变、无附加属性、不需要外键关联**。比如性别（虽然现在也不建议）、星期、是否标记（这个用 `TINYINT` 或 `BIT` 更好）。

| 需求 | ENUM | 查找表 + 外键 |
|---|---|---|
| 值很少且固定 | ✅ | 过度设计 |
| 值经常增减 | ❌ ALTER 重建全表 | ✅ 日常 INSERT |
| 值有附加属性（名称、颜色、图标、排序权重） | ❌ | ✅ |
| 需要 JOIN 查名称/多语言 | ❌ | ✅ |
| 需要强约束 + 外键 | ❌ | ✅ FK 保证 |
| 存储紧凑 | ✅ 1 字节 | ❌ 4~8 字节 |
| 修改需要 DBA/发版 | ❌ | ✅ 应用可管理 |

**判断口诀**：如果某个状态值"下个版本可能加第五个、第六个"，或者"运营想改状态显示名"，立刻换查找表。 ENUM 的紧凑优势在这些需求面前一文不值。

**查找表标准模式：**

```sql
CREATE TABLE t_order_status (
  id TINYINT PRIMARY KEY,
  code VARCHAR(20) NOT NULL UNIQUE,     -- 'paid'
  label VARCHAR(50) NOT NULL,           -- '已支付'
  sort_weight TINYINT DEFAULT 0,        -- 排序权重
  UNIQUE KEY uk_code (code)
) ENGINE=InnoDB;

CREATE TABLE t_order (
  id BIGINT PRIMARY KEY,
  status_id TINYINT NOT NULL,
  KEY idx_status (status_id),
  CONSTRAINT fk_order_status FOREIGN KEY (status_id) REFERENCES t_order_status(id)
);
```

查询展示名和排序：

```sql
SELECT o.*, s.label 
FROM t_order o JOIN t_order_status s ON o.status_id = s.id
ORDER BY s.sort_weight;
```

值管理变成 `INSERT INTO t_order_status ...`，不需要动表结构。**这是"状态机会变"类需求的唯一正解**，ENUM 在灵活性上没法比。

## 八、SET 类型：ENUM 的兄弟，更冷门

顺带说说 `SET`——多选版 ENUM：

```sql
tags SET('urgent','vip','trial')
INSERT INTO t_order (tags) VALUES ('urgent,vip');
```

- 存储是位图，最多 64 个成员；
- 用 `FIND_IN_SET('vip', tags)` 查，`LIKE` 部分匹配有陷阱；
- 同样有 ALTER 重建问题。

SET 的现代替代方案是 JSON 列或多对多关联表。除非极限压缩存储，新系统不建议用 SET，历史库遇到了按 ENUM 的坑同样防。

## 九、落地检查清单

对存量系统做一次 ENUM 清查：

- [ ] 列出所有 ENUM/SET 列：`SELECT * FROM information_schema.columns WHERE column_type LIKE 'enum(%' OR column_type LIKE 'set(%'`；
- [ ] 每个 ENUM 评估：值会变吗？有附加属性吗？需要 JOIN 吗？→ 命中任一，规划迁查找表；
- [ ] 检查脏值：`WHERE status = ''` 是否有数据；
- [ ] 检查 `ORDER BY status` 的排序是否符合业务预期，不符的改 `FIELD()`；
- [ ] 检查代码里有没有 `status = 2` 这种数字比较，全部改为字符串；
- [ ] 新值只追加末尾的纪律，写进 DDL 评审规范。

## 十、小结

ENUM 的四句话总结：

- **本质是整数索引 + 值列表**：排序按定义顺序、空串索引 0 且永远排最前、非严格模式静默吞脏值；
- **`ORDER BY status` 几乎永远不是你要的**，用 `FIELD()` 显式排，代价是 filesort；
- **`ALTER` 改列表会重建全表**，新值只准追加末尾，插中间 = 全表序号错乱；
- **值会变、有属性、要 JOIN 的场景立刻换查找表**，ENUM 只适合"≤5 个、永不变"的窄场景。

下一篇讲自增 ID 的空洞：为什么删了几行、事务回滚、批量插入都会让 id 跳变，以及唯一 ID 场景该怎么设计。
