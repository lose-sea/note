# gh-ost 与 pt-online-schema-change 选型：在线改表的工程决策

线上要给一张两亿行的订单表加索引，直接 `ALTER TABLE` 会锁表半小时，业务崩给你看。上在线改表工具——`pt-online-schema-change`（pt-osc）和 `gh-ost` 是唯二的标准答案。但两者原理不同、坑点不同、适用场景也不同。这篇文章把选型逻辑讲透：各自的工作机制、六维对比、四个决策场景、以及两类工具都不该用的例外。

## 一、先理解为什么直接 ALTER 不行

MySQL 的 `ALTER TABLE` 改表结构，传统路径是"重建表"：建新表 → 拷贝数据 → 锁原表做最终增量同步 → 表名切换。这个过程中，原表长时间不可写（老版本）或者可写但延迟高（InnoDB 在线 DDL，取决于操作类型和版本）。

关键事实：**InnoDB 从 5.6 起支持"在线 DDL"**，很多 `ALTER` 其实可以不锁表：

```sql
ALTER TABLE t_big ADD INDEX idx_user (user_id), ALGORITHM=INPLACE, LOCK=NONE;
```

`ALGORITHM=INPLACE`（原地改，不重建全表）+ `LOCK=NONE`（不阻塞读写）能cover加索引、加列（末尾）、改字符集（部分）等场景。**能用原生在线 DDL 的场景，优先用原生**——不引入外部工具就是最低风险。但两类操作原生 DDL 搞不定：改列类型、改主键，以及 5.5/5.6 老版本——这时才轮到 pt-osc / gh-ost。

## 二、pt-osc：影子表 + 触发器

`pt-online-schema-change` 是 Percona Toolkit 的组件，工作流程是经典的三步：

```
1. 建影子表 t_new（新结构）
2. 以块为单位从原表拷贝数据到影子表（chunked copy）
   同时在原表上创建 AFTER INSERT/UPDATE/DELETE 三个触发器，
   拷贝期间的增量变更实时同步到影子表
3. 数据追平后，RENAME TABLE t TO t_old, t_new TO t
   名字切换是瞬时的原子操作
   最后删掉 t_old 和触发器
```

一条命令长这样：

```bash
pt-online-schema-change \
  D=prod,t=t_order \
  --alter "ADD INDEX idx_user_id (user_id)" \
  --execute \
  --chunk-size 2000 \
  --max-lag 5s \
  --critical-load Threads_running=50 \
  --check-interval 2s
```

参数解释（这些是保命参数，不是可选项）：

| 参数 | 作用 |
|---|---|
| `--chunk-size 2000` | 每批搬 2000 行，太小慢、太大锁行长 |
| `--max-lag 5s` | 从库延迟超过 5 秒就暂停，防止把从库拖死 |
| `--critical-load` | 主库负载超过阈值就暂停（Threads_running=50 是常用线） |
| `--check-interval` | 每隔多久检查一次上述两个阈值 |
| `--no-drop-old-table` | 切换后保留旧表，人工确认没问题再删 |

**优势**：功能全、生态成熟、支持 swap 前的检查、有 swap 期间的可控回滚（`--swap-tables` 前的 checks）、`--dry-run` 预演。

**坑点**：触发器是硬伤。三个触发器让每次原表写入都变成"写原表 + 写影子表"，写入吞吐下降明显（实测 20%~50%，看负载）；如果原表上已有触发器，pt-osc 会直接拒绝（或产生触发器嵌套混乱）；外键表 RENAME 可能违反 FK 约束（`--alter-foreign-keys-method` 处理，复杂）。

## 三、gh-ost：binlog 增量回放

`gh-ost` 是 GitHub 开源的方案，思路完全不同：**不碰原表的写入路径**。

```
1. 建影子表 t_ghost（新结构），从原表拷历史数据（同样的 chunked copy）
2. 把自己伪装成 MySQL 从库，订阅主库 binlog，
   把原表相关的 binlog 事件翻译成对影子表的操作并回放
3. 数据追平后执行与 pt-osc 相同的 RENAME 切换（cutover）
```

```bash
gh-ost \
  --host=prod-master \
  --user=ghost --password=xxx \
  --database=prod --table=t_order \
  --alter="ADD INDEX idx_user_id (user_id)" \
  --execute \
  --chunk-size=2000 \
  --max-lag-millis=5000 \
  --critical-load=Threads_running=50 \
  --initially-drop-ghost-table \
  --cut-over=critical-load \
  --nice-ratio=0.5
```

`--nice-ratio` 是 gh-ost 的独家能力：控制自己最多占用多少比例的写入能力（0.5 = 最多占一半），动态降速，把影响压在可预期范围内。

**优势**：

1. **零触发器**：不在原表挂任何触发器，写入性能几乎无感（这是最大卖点）；
2. **可暂停可恢复**：任务随时 `Ctrl-C`，重启用相同参数会接着上次进度（内部状态在 `_t_order_gho` 表）；
3. **可测试**：`--test-on-replica` 在从库演练，不影响生产；
4. **binlog 即真相**：它消费真实 binlog，连并发冲突都模拟得和主库一致；而且因为它是"从库"，天然融入现有复制拓扑，从库上观察到的行为与生产一致。

**坑点**：要求 binlog 是 ROW 格式（statement 格式下没法精确回放，基本出局）；依赖主库 binlog 可用权限（`REPLICATION SLAVE` + `REPLICATION CLIENT`）；把心跳写进目标库时多一点点开销；cutover 阶段仍需要短暂锁（`RENAME` 期间），大表 cutover 要做好预案（gh-ost 会等一个"低负载窗口"再切，可以配置）。

## 四、六维对比

| 维度 | pt-osc | gh-ost |
|---|---|---|
| 增量同步机制 | 触发器 | 伪装从库消费 binlog |
| 对原表写入影响 | 触发器开销 20%~50% | 几乎无 |
| 已有触发器的表 | ❌ 拒绝/混乱 | ✅ 无所谓 |
| binlog 格式要求 | 无 | **必须 ROW** |
| 任务恢复 | 从头再来 | 断点续传 |
| 演练能力 | `--dry-run`（较浅） | `--test-on-replica`（深） |

再加两条实操差异：

- **权限**：pt-osc 需要 `PROCESS`、`SUPER`（部分场景）；gh-ost 需要 `REPLICATION SLAVE`、`REPLICATION CLIENT`、`CREATE/DROP/ALTER`。安全团队的偏好有时决定选型。
- **生态**：pt-osc 是 Percona Toolkit 全家桶一员，和 pt-query-digest、pt-table-checksum 一起用是经典 DBA 组合；gh-ost 社区活跃、文档好、GitHub issue 响应快。

## 五、四个决策场景

**场景 1：默认情况，直接选 gh-ost。**

新系统、 MySQL 8.0、binlog=ROW（默认就是 ROW）、团队第一次引入在线 DDL 工具。无触发器、可恢复、可演练，三个优势全部命中。pt-osc 唯一赢面是团队已经有成熟的 pt-osc 脚本体系和 runbook。

**场景 2：表上已有触发器，只能 gh-ost。**

pt-osc 遇到已有触发器会直接拒绝执行（或产生不可控的触发器叠加）。如果业务合理要求表上有触发器（审计类表），pt-osc 出局。当然也可以临时删触发器→改表→重建触发器，但那风险更大。

**场景 3：binlog 是 STATEMENT/MIXED，或拿不到复制权限 → pt-osc。**

gh-ost 强依赖 ROW binlog。老库还是 statement 格式的、或者云 RDS 限制了 `REPLICATION SLAVE` 权限（某些托管实例限制自建从库），gh-ost 直接不可用，用 pt-osc。顺便说一句：还在用 statement binlog 的系统，本来就有数据一致性隐患，升级 ROW 应该排上日程。

**场景 4：极端大表 + 极端敏感写入 → gh-ost + nice-ratio。**

几十亿行、写入密集型、对延迟极度敏感的表（比如交易流水），gh-ost 的 `--nice-ratio` 能精细控制资源占用，pt-osc 的触发器在大写上太伤了。

**都不用的场景**：表小（百万行以下）、读写低谷期、操作是"纯在线 DDL"能 cover 的（加索引、末尾加列）——直接用 `ALTER TABLE ... ALGORITHM=INPLACE, LOCK=NONE`，几秒完成，引工具反而是负担。工具链越重，操作风险越大。

## 六、通用操作规范（两个工具都适用）

工具选好只是开始，执行纪律才是保命的：

1. **预演**：在生产同规格的从库/预发环境完整跑一遍，计时、看负载曲线；
2. **低峰执行**：虽然是在线工具，cutover 仍是瞬时操作，选业务低谷；
3. **限速护从库**：`--max-lag`（pt-osc `--max-lag 5s`；gh-ost `--max-lag-millis 5000`）必须配，把从库延迟当红线；
4. **保压**：`--critical-load` 配置主库 Threads_running 阈值，超了就自动暂停，别让 DDL 把生产压垮；
5. **不自动删旧表**：pt-osc `--no-drop-old-table`，gh-ost 默认 `--initially-drop-ghost-table`（删的是自己的影子表，旧表由 gh-ost 在 cutover 后保留）。旧表至少观察一天再删；
6. **备份先行**：改表前确认有可恢复的全备 + binlog；
7. **验证**：改完对比行数、`CHECKSUM TABLE`、抽查结构 `SHOW CREATE TABLE`；
8. **回滚预案**：如果是"删索引"这类操作，回滚 = 重新加索引，时间成本要先算清；
9. **避开批量窗口**：别跟大促前的数据迁移、月度结算这类任务撞车；
10. **单个跑**：一张表一个任务，别并发改多张表（触发器/binlog 消费互相干扰，负载叠加）。

**执行后的标准观察项**：主库 QPS/TPS 曲线、从库延迟（`Seconds_Behind_Master`）、错误日志、慢查询突增、以及业务侧接口成功率。这些监控，改表前就该打开。

## 七、排错速查

| 症状 | 大概率原因 | 处理 |
|---|---|---|
| 任务频繁 pause/resume | `--max-lag` 太严或从库本身慢 | 放宽到 10s；先查从库延迟根因 |
| 拷贝阶段极慢 | chunk 太大锁行长 / chunk 太小往返多 | 2000~5000 行试；gh-ost 调 `--nice-ratio` |
| cutover 卡住 | 等一个"无长事务写入"窗口 | 找长事务源（`information_schema.innodb_trx`），杀掉或等 |
| gh-ost 启动即失败 | binlog 非 ROW / 权限不足 | `SHOW VARIABLES LIKE 'binlog_format'`；授权 |
| pt-osc 报触发器冲突 | 原表已有触发器 | 换 gh-ost |
| 从库延迟飙高不降 | 速度超过从库回放能力 | 降速，等延迟恢复 |

## 八、小结

在线改表选型的三句话：

- **能用原生 `ALGORITHM=INPLACE, LOCK=NONE` 就不引工具**，工具链是最后手段；
- **默认选 gh-ost**：零触发器、可恢复、可演练，唯一硬要求是 binlog=ROW；
- **pt-osc 的保留场景**：statement binlog 老库、无复制权限的托管实例、已有 pt 工具链的团队——但已有触发器的表它直接出局。

下一篇讲表空间加密：InnoDB 静态加密怎么配、master key 怎么轮换、以及它和备份加密的关系。
