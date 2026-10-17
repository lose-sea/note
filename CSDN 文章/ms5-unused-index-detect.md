# 未使用索引检测：找出白吃存储和写放大的"僵尸索引"

上一篇讲了冗余索引的同表和前缀重复，这篇文章讲更广的一类：**未使用索引（Unused Index）**——建了之后优化器一次都没选过的索引。它们是纯粹的负债：占存储、拖慢写入、增加备份恢复时间，却零收益。问题是"未使用"不能靠 DBA 的记忆判断，要用数据和观察说话。这篇文章给出一套可落地的检测流程。

## 为什么"未使用"难判断

难点有三：

1. **调用周期长的任务**。月报季报一年跑几次的查询用的索引，你看一个月的数据，它"从未使用"；跑一次之后，它突然变成关键路径。**短观察期会把低频关键索引误判为僵尸**。
2. **约束型索引表面没人查**。唯一索引平时不参与查询优化，但删了它重复数据立刻进来——它防的是写时的一致性，不是读路径。
3. **优化器有时选错**。某个索引其实能用上，但优化器因为统计信息问题选了别的，看起来"没人用"，删了之后它该用的查询退化成全表扫。

所以检测不能只跑一条 SQL 看 COUNT_STAR=0，要**证据 + 观察期 + 恢复预案**三件套。

## 检测三板斧

### 第一板：performance_schema 用量统计

```sql
-- 索引使用统计：COUNT_STAR=读取次数
SELECT OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME, COUNT_STAR, COUNT_READ
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE OBJECT_SCHEMA = 'your_db'
ORDER BY COUNT_STAR ASC;
```

COUNT_STAR = 0 是候选。但先记住两个盲区：

- **Performance Schema 从上次重启才开始累计**。实例刚重启或开了不全的 instrument，这个表的数据是残缺的。看 `SELECT @@performance_schema` 和表的 FLUSH 时间。
- **它记的是优化器选择，不是查询引用**。查询写了列但优化器没选索引，这里不记账。

### 第二板：sys 库现成视图

```sql
-- 从未使用的索引
SELECT * FROM sys.schema_unused_indexes;

-- 冗余索引（前缀重复等）
SELECT * FROM sys.schema_redundant_indexes;
```

sys 视图就是 performance_schema 的封装，方便但要理解背后的原始数据。

### 第三板：业务查询清单交叉验证

比 SQL 更可靠的方式：**把慢查询日志 + 代码里的查询语句扫一遍，列出实际在跑的 SQL 用到的索引，和库里的索引对比**。

```bash
# 从慢日志提 EXPLAIN，收集用到的索引名
pt-query-digest slow.log --filter 'explain' | grep -oP 'key: \K\w+' | sort -u
```

代码侧同理——grep ORM 的查询定义、`SHOW PROCESSLIST` 抓实时在跑的语句 EXPLAIN 一遍。**这份"实际使用的索引清单"是金标准**：库里存在但清单外的索引，才有资格进候选池。

## 完整的处置流程：候选 → 观察 → 判决

### 阶段一：建候选池

三类索引进池，分开标注理由：

```sql
SELECT 'unused' AS kind, t.object_name, t.index_name
FROM performance_schema.table_io_waits_summary_by_index_usage t
WHERE t.object_schema = 'your_db' AND t.count_star = 0
  AND t.index_name NOT IN ('PRIMARY')            -- 主键除外
  -- 唯一索引和约束相关单独标注
UNION ALL
SELECT 'redundant', ... FROM sys.schema_redundant_indexes;
```

同时**排除禁区**：

- PRIMARY（废话但年年有人踩）
- 唯一约束索引（数据完整性防线）
- 外键关联列的索引（`KEY_COLUMN_USAGE` 查引用）
- 空间索引、全文索引（性能_schema 统计不一定记它们的用法）

### 阶段二：INVISIBLE 观察期

上一篇讲过的手段，这里是标准应用：

```sql
ALTER TABLE orders ALTER INDEX idx_zombie INVISIBLE;
```

观察什么？三个信号：

1. **慢日志新增**：`pt-query-digest` 对比观察期前后，新出现的慢查询如果 EXPLAIN 显示"少了这个索引后计划劣化"，救回来。
2. **写性能变化**：消失的索引维护开销是否让写入 QPS/延迟有可见改善？改善不明显的话，删了收益也有限——重新评估是否值得折腾。
3. **完整业务周期**：7 天是底线，30 天更稳。**月度/季度任务必须跑过一次再判决**。报表类系统月底那几天单独盯。

### 阶段三：执行删除还是恢复

```sql
-- 恢复：观察期发现有用
ALTER TABLE orders ALTER INDEX idx_zombie VISIBLE;

-- 删除：确认无害
DROP INDEX idx_zombie ON orders;
```

删除后 DDL 语句必须归档（变更系统 + git），最好带上原表数据量和当时的判断理由。**半年后有人问"这个索引当初为什么删"，你能回答"观察了 30 天、写性能提升 8%、慢日志无回归"——这就是工程记录和拍脑袋的区别**。

## 大表删除：用 pt-osc 或 gh-ost

千万级以上的表直接 DROP INDEX 会怎样？**DDL 期间表锁定 + 元数据重建**，MySQL 8.0 的 INSTANT 只覆盖加列这类简单操作，删索引通常要走 INPLACE 或 COPY——读写阻塞秒级到分钟级。

生产大表删除的规矩：

```bash
# pt-online-schema-change 无锁删索引
pt-online-schema-change \
  --alter "DROP INDEX idx_zombie" \
  D=your_db,t=orders \
  --execute
```

或者 gh-ost：

```bash
gh-ost --alter="DROP INDEX idx_zombie" \
  --database=your_db --table=orders --execute
```

两者原理都是建影子表、同步增量、原子切换。生产环境删任何索引，先看表大小——**超过 500 万行就走在线工具，别裸 DDL**。mysql 8.0 对 DROP INDEX 支持 `ALGORITHM=INPLACE, LOCK=NONE`，比 5.7 时期好，但 INPLACE 对某些表结构仍降级为 COPY，先 `ALTER ... ALGORITHM=INPLACE, LOCK=NONE` 试跑，报错再上工具。

## 收益度量：删完要复盘

删索引不是删完就完，三个收益要复盘留档：

```sql
-- 1. 空间回收（删前记、删后对比）
SELECT INDEX_NAME, STAT_VALUE * @@innodb_page_size / 1024/1024 AS mb
FROM mysql.innodb_index_stats WHERE STAT_NAME = 'size' AND DATABASE_NAME='your_db';

-- 2. 写入吞吐对比（监控系统的 insert/update QPS 和延迟）
-- 3. 备份恢复时间对比（大表索引对 xtrabackup 耗时影响直接）
```

真实案例的收益分布：单实例清出 30 个僵尸索引后，写入 QPS 提升 12%，备份时间缩短 8 分钟，存储回收 45GB。**索引清理的 ROI 通常是所有 DBA 工作里最高的**——没有新硬件、不改代码、不动业务，纯做减法。

## 建立常态机制：别让僵尸再长回来

1. **月度 report**：`sys.schema_unused_indexes` 出报表，维护索引生命周期看板（新建/使用率/僵尸）。
2. **新索引强制登记**：建索引必须在变更系统登记"服务的查询 + 预估收益"，月度 review 时对照使用率——上线仨月 COUNT_STAR=0 的自动进候选池。
3. **写入敏感表重点盯**：订单、日志、流水这类写大头表，索引数量设上限告警（比如 > 6 触发 review）。

**索引只进不出是腐化的开始，进有据、退有据才是治理。**

## 小结

未使用索引检测 = performance_schema 用量统计 + sys 视图 + 查询清单交叉验证 → 排除主键/唯一/外键禁区 → INVISIBLE 完整业务周期观察 → DROP（大表走 pt-osc/gh-ost）→ 收益复盘留档。核心原则：**数据定候选、观察做判决、记录保追溯**。下一篇谈分区表的第一课——分区裁剪怎么让查询只扫需要的分区。
