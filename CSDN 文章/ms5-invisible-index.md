# 不可见索引：删除索引前的安全观察期

"这个索引好像没用了，删了吧"——删索引容易，回滚难。生产环境上，索引一删，某个半夜批处理的执行计划瞬间劣化，查询从上毫秒变成上分钟，等你早上发现，积压已经压垮队列。MySQL 8.0 的 **INVISIBLE 索引**给了这个决策一个安全缓冲区：先藏起来观察，确认无害再删。这篇文章讲它的机制、使用流程和注意事项。

## 不可见索引是什么

```sql
-- 创建时直接设为不可见
CREATE INDEX idx_email ON user(email) INVISIBLE;

-- 已存在的索引改为不可见 / 恢复可见
ALTER TABLE user ALTER INDEX idx_email INVISIBLE;
ALTER TABLE user ALTER INDEX idx_email VISIBLE;
```

**不可见索引对优化器完全透明**：生成执行计划时当它不存在，查询走其他索引或全表扫。但对维护操作完全透明：**数据写入时它照常维护**——INSERT/UPDATE/DELETE 照样更新它的 B+ 树。

这个双重性是它的核心价值：**保留维护成本、去掉优化器可见性**，让你观察"没有这个索引"的真实世界，同时保留"恢复它"的一秒钟能力（ALTER 回 VISIBLE，不用重建）。

## 使用流程：观察三件事

标准动作：怀疑索引无用 → 藏起来 → 观察 → 处置。观察期内盯三类信号：

**1. 查询性能回归**。慢日志是否出现新的慢查询？如果有查询原本走这个索引，现在慢了——说明它有用，ALTER VISIBLE 恢复，索引保留。这是最直接的检验。

**2. 写性能提升**。索引维护占的写入开销是否消失？如果写入吞吐明显提升，说明删除收益真实存在。用 `SHOW GLOBAL STATUS LIKE 'Innodb_row_lock_time'` 或业务监控的写入 QPS/延迟对比。

**3. 执行计划漂移**。`performance_schema` 里看有没有查询从 index scan 退化成 table scan。有些查询只在特定参数下用这个索引（比如某个定时任务的稀有 WHERE），慢日志不一定抓到，performance_schema 的统计更全。

观察周期建议**覆盖一个完整业务周期**——至少 7 天（覆盖周报批处理）、最好 30 天（覆盖月度任务）。"藏了三天没出事就删"和"不藏直接删"的差别，只是把风险延后三天。

## 与软删除配合：服务器批量失效场景

不可见索引还有一个教科书级用法：**配合 optimize 批量把若干索引下架**。DBA 怀疑一批索引冗余，不敢一次删五个：

```sql
-- 第一步：五个全部藏起来
ALTER TABLE orders ALTER INDEX idx_a INVISIBLE,
                          ALTER INDEX idx_b INVISIBLE,
                          ...;

-- 第二步：观察期，逐个恢复发现有用的
ALTER TABLE orders ALTER INDEX idx_b VISIBLE;   -- 有慢查询了，救回来

-- 第三步：确认四个真没用，删除（写放大消失）
DROP INDEX idx_a ON orders;
DROP INDEX idx_c ON orders;
...
```

逐个恢复的能力是"批量失效"和"直接删除"的本质区别——**删除没有中间态**。

## INVISIBLE 的限制与坑

1. **主键不能 INVISIBLE**。聚簇索引是表的骨架，优化器必须用它。唯一索引里被外键引用的也要小心藏——外键约束检查时可不管索引可见性，但删除后约束性能受损。
2. **optimizer_switch 有全局开关**：
   ```sql
   SET SESSION optimizer_switch='use_invisible_indexes=on';   -- 让本会话看得到不可见索引
   ```
   **调试利器**：怀疑某个查询变慢和索引被藏有关，开这个 switch 对比 EXPLAIN，不用改索引状态。默认 off，全局也默认 off。
3. **写开销没有省**。这是最大的认知误区——索引不可见 ≠ 不维护。数据量大的表，索引维护是写入成本大头，INVISIBLE 期间这部分开销照付。**INVISIBLE 不是"停用索引"，是"对优化器停用"**。只有物理 DROP 才释放写成本。
4. **复制环境行为一致**。binlog 记录的是语句，从库执行 ALTER 的时机可能不同步，观察期内主从索引可见状态理论上会短暂不一致——生产观察期避开 DDL 频繁期，且确认从库已同步到位再做后续决策。
5. **视图和存储过程**。优化器对视图定义里的查询同样遵守 INVISIBLE 规则——但别忘了视图可能被物化执行计划缓存，观察期发现异常 EXPLAIN 时确保缓存已刷新。

## 和 DROP INDEX 的安全对比

| 维度 | DROP INDEX | ALTER INDEX INVISIBLE |
|---|---|---|
| 恢复成本 | 重建（大表小时级，期间查询无索引） | ALTER VISIBLE（秒级元数据操作） |
| 写开销 | 立即释放 | **继续付** |
| 观察能力 | 无（删了才知道） | 有（真实查询反馈） |
| 元数据锁 | DROP 期间锁表 | ALTER INVISIBLE 同样要元数据锁但极快 |

**核心结论：INVISIBLE 省的是"决策错误成本"，不是"资源成本"**。判断删除收益的阶段看写性能提升，最终删除才释放资源。两阶段别混。

## 与 DROP 的衔接动作

确认可删的标准流程：

```sql
-- 1. 观察期满，记录证据
SELECT * FROM sys.statement_analysis WHERE ...;   -- 慢查询对比
SHOW GLOBAL STATUS LIKE 'Innodb_data_writes';      -- 写 IO 对比

-- 2. 删除
DROP INDEX idx_unused ON orders;

-- 3. 观察期延续。删除后的一周继续盯慢日志——有些月度任务可能还没跑过
-- 4. 兜底：DDL 语句留档（git 或变更系统），最坏情况秒级重建脚本
ALTER TABLE orders ADD INDEX idx_unused(email);   -- 有备份语句，重建不慌
```

**DDL 变更系统和 git 留档是删除索引的真正兜底**——不可见索引给你缓冲区，回滚脚本给你后悔药。

## 小结

INVISIBLE 索引是"删索引前先藏起来看"的安全机制：优化器不再用它，写入照常维护，ALTER VISIBLE 秒级恢复。标准流程：批量藏 → 覆盖完整业务周期观察慢日志和写性能 → 有用的恢复 → 确认没用的才 DROP。记住它的边界——不省写开销、不覆盖月度任务就没删，恢复是秒级但得有备份脚本。下一篇讲 Skip Scan Range：多列索引不写前导列也能用的黑科技。
