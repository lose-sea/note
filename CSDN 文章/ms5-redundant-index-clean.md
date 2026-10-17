# 冗余索引清理：重复索引、前缀重复与清理的正确姿势

一个跑了三年的业务库，索引数量经常比表数量还多——历史需求层层叠加，每个开发都"顺手加个索引"。冗余索引（Redundant Index）吃三份成本：存储、写放大、优化器选择困难。这篇文章讲清冗余的三种形态、怎么系统地找出来、以及清理的标准流程。

## 冗余索引的三种形态

### 形态一：完全重复

两个索引列完全相同（名字不同而已）：

```sql
CREATE INDEX idx_a ON orders(user_id);
CREATE INDEX idx_b ON orders(user_id);   -- 除了名字，一模一样
```

常见来源：不同开发、不同时间点，"不知道已有索引"重复创建。**完全等价，删谁留谁无所谓**。

### 形态二：前缀重复（最隐蔽）

一个索引是另一个的**最左前缀**：

```sql
CREATE INDEX idx_wide ON orders(user_id, status, created_at);
CREATE INDEX idx_narrow ON orders(user_id);          -- 是 idx_wide 的前缀！
CREATE INDEX idx_mid ON orders(user_id, status);     -- 也是 idx_wide 的前缀！
```

因为联合索引 `(user_id, status, created_at)` 的 B+ 树里，数据本身就按 user_id 分组、组内按 status 排序——**优化器查 `WHERE user_id = x` 或 `WHERE user_id = x AND status = 'y'` 时，用 idx_wide 完全能替代两个窄索引**。窄索引的物理存在是纯冗余。

这是最容易积累的形态：先建了 `(user_id)`，后来需求加了联合索引 `(user_id, status)`，没人回去删第一个。**判断规则：如果索引 A 的列序列是索引 B 的连续前缀，A 冗余于 B**（A 可被 B 替代，除非 A 有特殊性质，见下）。

### 形态三：功能性重复

不是列完全相同，但服务完全相同的查询场景：

```sql
CREATE INDEX idx_phone ON user(phone);
CREATE INDEX idx_phone_hash ON user( (MD5(phone)) );   -- 哈希列索引
-- 如果查询全是等值查找且哈希索引全接管，普通 phone 索引逐渐失去存在意义
```

或者唯一索引和普通索引并存：

```sql
CREATE UNIQUE INDEX uk_email ON user(email);
CREATE INDEX idx_email ON user(email);   -- 普通索引完全被唯一索引覆盖
```

## 怎么找：三个层次的排查

### 层次一：查 information_schema

MySQL 没有直接暴露"索引冗余关系"的视图，用统计信息 + 模式判断：

```sql
-- 列出每张表的所有索引（含列组成）
SELECT TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'your_db'
GROUP BY TABLE_NAME, INDEX_NAME
ORDER BY TABLE_NAME;
```

拿到清单后人工过前缀规则：**同表内，一个索引的 cols 是另一个 cols 的开头 → 前缀重复，窄的那个待清理**。表少的库十分钟搞定；表多的库写个脚本：

```python
# 伪代码：前缀重复检测
for table, indexes in all_indexes.items():
    for a, b in combinations(indexes, 2):
        if b.cols.startswith(a.cols):   # a 是 b 的前缀
            print(f"{table}: {a.name} 冗余于 {b.name}")
```

### 层次二：查实际使用

```sql
-- 改表对象，看索引被读的次数
SELECT * FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE OBJECT_SCHEMA = 'your_db'
ORDER BY COUNT_STAR;
```

COUNT_STAR = 0 且 COUNT_READ = 0 的索引：观察期内优化器从未用过。**"从未用过"是删除候选，不是删除判决**——先过 INVISIBLE 流程。

```sql
-- sys 库封装好的视图
SELECT * FROM sys.schema_redundant_indexes;
SELECT * FROM sys.schema_unused_indexes;
```

`schema_redundant_indexes` 直接按前缀规则列出候选清单。

### 层次三：EXPLAIN 验证替代性

前缀重复的索引，删之前要**验证宽索引真的能替代窄索引的角色**：

```sql
-- 窄索引的典型查询
EXPLAIN SELECT * FROM orders WHERE user_id = 12345;
-- 原本用 idx_narrow，删掉后确认优化器改用 idx_wide 且计划不劣化
```

注意一个反例：**宽索引体积大，树比窄索引高**。百万级数据差异微小；十亿级数据、或者窄索引命中覆盖索引场景（`SELECT user_id ... WHERE user_id`），窄索引反而更快。**验证不能省**——理论上可替代，实测有时打折。

## 清理流程：标准五步

```
① inventory   盘点全部索引（information_schema）
② classify    分类：重复 / 前缀重复 / 未使用 / 保留
③ hide        ALTER INDEX INVISIBLE 观察期
④ monitor     慢日志 + 写性能双指标观察
⑤ drop        确认无回归后 DROP，DDL 语句归档
```

第三步的 INVISIBLE 是核心——**它让你在不承担删除风险的前提下，拿到真实环境的反馈**。观察期覆盖完整业务周期（7 天起步，月度任务跑过再删）。

## 清理的收益量化

清理前先算收益，值不值得动手：

```sql
-- 索引的物理大小
SELECT
    DATABASE_NAME, TABLE_NAME, INDEX_NAME,
    STAT_NAME, STAT_VALUE * @@innodb_page_size / 1024 / 1024 AS size_mb
FROM mysql.innodb_index_stats
WHERE STAT_NAME = 'size' AND DATABASE_NAME = 'your_db'
ORDER BY size_mb DESC;
```

三个收益维度：

1. **空间回收**。冗余索引的 size_mb 总和，直接是磁盘回收量。大表清理经常一次省几十 GB。
2. **写性能提升**。每行写入的索引维护数减少。**对写入密集的表，删冗余索引是最高 ROI 的写优化**——比调 buffer pool 简单，比改代码安全。
3. **优化器决策变清晰**。索引少了，优化器选错计划的概率下降，drop 掉从不使用的索引同时缩短 CBO 的选择时间。

判断标准：单表索引数超过 5 个就该审查——不是绝对上限，是提醒信号。OLTP 表 3~4 个精心设计的索引通常比 10 个堆积的索引快。

## 清理的三个反例（别删这些）

**1. 支持外键/约束的索引**。外键约束依赖被引用列的索引。删了约束性能爆炸甚至锁表。

```sql
-- 查外键约束在用哪些列
SELECT * FROM information_schema.KEY_COLUMN_USAGE
WHERE REFERENCED_TABLE_NAME IS NOT NULL;
```

**2. 唯一约束承担数据完整性**。`uk_email` 不只是索引，是防重复注册的底线。普通 idx_email 可以删，uk_email 不能动。

**3. 主键**。删主键 = 删表结构。永远不在清理范围。

## 治理：别让冗余再长回来

清理是一时的，治理才是一世的。三个机制：

1. **建索引走评审**。每个新索引的 PR 必须回答："服务的查询是什么、现有索引为什么不覆盖、有 EXPLAIN 证据吗、观察过写入影响吗"。没有这套 review 流程的团队，一年后索引数量回到原点。
2. **上线前 EXPLAIN 留档**。变更记录里带 EXPLAIN 输出，季度回顾时能看出哪些索引"上线时有用、现在没人用"。
3. **慢查询驱动的索引生命周期**。索引因慢查询而生（有据可查），因无人使用而死（INVISIBLE 观察删除）——**每个索引都有查询出处，删除时就有信心**。查不到出处的索引，多半是历史包袱。

## 小结

冗余索引三形态：完全重复（删谁都行）、前缀重复（窄删宽留）、功能重复（验证替代性）。排查靠 information_schema + performance_schema 双视图，清理走 INVISIBLE 观察五步法，保留外键/唯一约束/主键三大禁区。写性能收益最实在，空间回收最可见，优化器减负最隐性——三个都值得。治理靠评审 + EXPLAIN 留档，让索引从"只进不出"变成有生命周期的资产。
