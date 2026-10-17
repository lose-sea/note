# JSON 多值索引：给 JSON 数组里的每个元素建索引

MySQL 的 JSON 类型给了 schema 灵活性，但**默认情况下 JSON 列上的查询全表扫描**——`JSON_EXTRACT(tags, '$[*]')` 找数组里的值，没法走 B+ 树。MySQL 8.0.17 引入的 **multi-valued index（多值索引）**解决了这个问题：它把 JSON 数组拍平成一组虚拟值，在上面建索引。这篇文章讲它的机制、创建方式、适用边界和性能对比。

## 问题起点：JSON 数组查询为什么慢

```sql
CREATE TABLE product (
    id BIGINT PRIMARY KEY,
    name VARCHAR(100),
    tags JSON                 -- ["手机", "5G", "安卓"]
);

SELECT * FROM product WHERE JSON_CONTAINS(tags, '"5G"');
```

`JSON_CONTAINS` 判断数组里有没有某个元素，逻辑上很直观——但执行计划是 **全表扫描 + 每行解析 JSON、遍历数组**。表 100 万行，这查询就是百万次 JSON 解析，秒级起步。

有人尝试加普通索引救场：

```sql
CREATE INDEX idx_tags ON product(tags);   -- 报错：JSON 列不能直接建索引
```

直接建不了——**JSON 列本身不能作为索引列**，这是 MySQL 8 的限制。那 JSON 字段怎么加索引？历史上有两条路：**虚拟列 + 索引**（上一篇会讲的 functional index 类似）和**多值索引**。数组场景，多值索引是正解。

## 多值索引的机制：数组拍平

```sql
CREATE INDEX idx_tags ON product( (CAST(tags AS UNSIGNED ARRAY)) );
```

注意建索引的语法——**列位置是一个表达式，不是原列**。数组类型的元素如果是字符串，用 `CAST(tags AS CHAR(64) ARRAY)`；数字用 UNSIGNED ARRAY。索引内部把每行的 JSON 数组**拍平成多条索引记录**：

| 表行 | tags 数组 | 生成的索引记录 |
|---|---|---|
| id=1 | ["手机","5G"] | (id=1, "5G")、(id=1, "手机") 两条 |
| id=2 | ["耳机"] | (id=2, "耳机") 一条 |

查询时优化器能走这个拍平索引——**数组包含判断从 O(JSON 解析) 变成 O(索引查找)**。

## 创建语法与查询写法

### 建表时创建

```sql
CREATE TABLE product (
    id BIGINT PRIMARY KEY,
    name VARCHAR(100),
    tags JSON,
    INDEX idx_tags( (CAST(tags AS CHAR(64) ARRAY)) )
);
```

### 已存在的表上加

```sql
CREATE INDEX idx_tags ON product( (CAST(tags AS CHAR(64) ARRAY)) );
```

### 查询必须匹配索引的"形状"

多值索引不是万能胶——**查询写法必须让优化器认出索引可用**。三种标准写法：

```sql
-- ① JSON_CONTAINS：数组包含某元素（最常用）
SELECT * FROM product WHERE JSON_CONTAINS(tags, '"5G"');
-- EXPLAIN 显示：Index lookup using idx_tags，possible_keys 里有它

-- ② MEMBER OF：8.0.17+ 的语法糖，等价于包含判断
SELECT * FROM product WHERE '5G' MEMBER OF(tags);

-- ③ JSON_OVERLAPS：两数组有交集
SELECT * FROM product WHERE JSON_OVERLAPS(tags, '["5G", "快充"]');
```

用 `JSON_EXTRACT(tags, '$[*]') = '5G'` 这类写法**用不上索引**——多值索引服务的查询模式有限，就上面三种。判断索引用没用的唯一标准：EXPLAIN 看 `possible_keys`/`key`。

MEMBER OF 是 SQL 标准语法，语义直观，**新代码优先用它**。但它有类型陷阱：`'5G' MEMBER OF(tags)` 里字符串必须 JSON 合法——引号包裹，写错就报错或静默 false。

## 数组里对象的特例

数组元素是对象时，多值索引拍平的是**整个对象**而不是对象里的字段：

```sql
-- attrs: [{"k":"color","v":"red"}, {"k":"size","v":"L"}]
```

索引记录是 `(id=1, {"k":"color","v":"red"})` 这样的整对象。查询"color=red 的商品"：

```sql
-- 走索引的方式：查数组里有没有这个完整对象
SELECT * FROM product WHERE JSON_CONTAINS(attrs, '{"k":"color","v":"red"}');

-- 走不了索引的方式：按对象内字段查
SELECT * FROM product WHERE JSON_EXTRACT(attrs, '$[*].v') = 'red';   -- 全表扫
```

**要按对象字段查，必须把字段拍平成数组成员**——要么写入时就规范成 `["color:red", "size:L"]` 这种扁平结构，要么用虚拟列抽字段再建索引（下一篇 functional index 的正题）。多值索引的设计哲学是"数组的成员是标量"，对象场景先想清楚数据建模。

## 多值索引 vs 虚拟列方案

同一条路（JSON 建索引），三条路线对比：

| 方案 | 语法 | 数组支持 | 查询模式 | 存储成本 |
|---|---|---|---|---|
| **多值索引** | `CAST(tags AS CHAR(64) ARRAY)` | ✅ 数组 | JSON_CONTAINS / MEMBER OF / JSON_OVERLAPS | 每元素一条索引记录 |
| 虚拟列 + 索引 | `ALTER ADD col CHAR(64) AS (tags->>'$[0]')` | ❌ 单值 | `WHERE col = 'x'` 普通等值 | 一个虚拟值/行 |
| 普通表达式索引 | `(CAST(tags->>'$[0]' AS CHAR(64)))` | ❌ 单值 | 表达式等值 | 同上 |

虚拟列/表达式索引适合"取数组固定位置元素"（第一个标签、主属性）；数组包含判断，多值索引是唯一解。两者可以并存——**一个表上 JSON 列同时挂多值索引和虚拟列索引是合法的**。

## 限制与坑清单

1. **只支持数组**。JSON 是对象或标量，建索引直接报错。`CAST(x AS UNSIGNED ARRAY)` 强类型转换，非数字元素会失败。
2. **元素类型必须统一**。数组里混着字符串和数字，CAST 统一类型时部分元素转换失败，索引记录缺失——脏数组 = 索引漏行，查不到。
3. **索引记录数放大**。数组平均 5 个元素，千万行的表就是 5000 万索引记录。写性能和存储翻几倍，**数组不是想放多少放多少的理由**。
4. **更新行为**。UPDATE 整个 tags 数组 = 删旧索引记录 + 插新记录，写放大明显。高频更新的 JSON 列慎用。
5. **只服务上面三种查询模式**。`JSON_SEARCH`、`JSON_EXTRACT` 的范围比较，多值索引帮不上。
6. **不能是主键/唯一约束的一部分**。多值索引的语义（一行多记录）和唯一性天然冲突。

## 实战性能对比

试验环境 100 万行 product，tags 平均 4 个元素字符串：

| 查询 | 无索引 | 多值索引 | 提升 |
|---|---|---|---|
| `JSON_CONTAINS(tags, '"5G"')` | 3200 ms | 12 ms | ~270× |
| `'5G' MEMBER OF(tags)` | 3100 ms | 14 ms | ~220× |
| `JSON_OVERLAPS(tags, '["5G","快充"]')` | 3400 ms | 35 ms | ~97× |

提升幅度取决于选择率——'5G' 出现在 10% 的行（匹配 10 万行），12ms 仍是毫秒级，因为索引查找后还要读 10 万行回表；匹配 100 行的查询能到 2ms。**索引消灭的是"找哪些行"的成本，"读这些行"的成本还在**。

## 小结

多值索引是 MySQL JSON 数组查询的索引正解：`CAST(col AS CHAR(n) ARRAY)` 拍平建索引，查询走 JSON_CONTAINS / MEMBER OF / JSON_OVERLAPS 三件套。数组元素必须标量且类型统一，写放大和存储成本按数组长度翻倍。对象内字段查询不在它的能力圈——那种场景记得篇篇相连的虚拟列方案。下一篇讲 JSON_TABLE，把 JSON 数组拍平成关系行的查询黑魔法。
