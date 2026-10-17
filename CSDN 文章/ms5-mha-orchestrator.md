# MHA 与 Orchestrator：MySQL 高可用架构的选型与实操

主库宕机的时刻，业务能容忍多久中断？这个问题的答案决定了你的高可用（HA）架构复杂度。MySQL 生态的两大经典答案：**MHA**（日本 DeNA 开源的 Manager + Node 方案）和 **Orchestrator**（GitHub 出品的拓扑管理工具）。这篇文章把两者的架构、failover 能力、选型逻辑和实操要点讲透，帮你避开"以为有 HA、真出事发现不好用"的坑。

## 先想清楚：HA 方案要解决什么

一个完整的 failover 链路要处理的事：

1. **检测**：主库是网络抖动还是真死？误判代价极大（不必要的切换本身是事故）。
2. **选主**：哪个从库晋升？数据最新的那个。GTID 位置/复制延迟是判据。
3. **补偿**：旧主若"复活"，数据可能和新主有分叉，要拦住它别写（binlog 补数据的场景见闪回篇）。
4. **切换**：从库重置复制关系指向新主，应用层连接切换到新主。
5. **VIP/流量**：应用是硬编码 IP 还是走 VIP/服务发现？切换后流量怎么走。
6. **脑裂防护**：双主瞬间、网络分区时两个库都在写——这是 HA 设计的头号敌人。

**MHA 解决 1-4 + 部分 5，Orchestrator 解决 1-4 + 5-6 且可视化更强**。方案能力的天花板在于另一半：应用层是否支持动态发现新主（VIP 或 DNS 或中间件），HA 工具再强也替应用做不了决定。

## MHA：Manager + Node 架构

```
[ Manager 管理机 ]          [ Node1 主库 ] [ Node2 从库 ] [ Node3 从库 ]
   - 探测（SSH）        ←复制—     
   - 决策                  └──────复制──────┘
   - SSH 执行切换脚本
```

核心是那台 Manager：定时 SSH 探测各 Node，主库失联达到阈值（默认 3 次 x 2 秒？实际配置里 `secondary_check_script`、ping 阈值可调）判定故障，执行 `master_ip_failover_script` 完成切换。

MHA failover 做的事：

1. 找出 binlog 位置最新的从库（有 `--relay_log_info` 借助 GTID）；
2. ** salvage 阶段**：尝试从旧主捞回还没传到从库的 binlog 事件（SSH 上去拷 relay log / binlog），补偿复制延迟丢的数据——这是 MHA 的口碑功能；
3. 晋升该从库为新主，其他从库 CHANGE MASTER 指向新主（`MASTER_AUTO_POSITION`）；
4. VIP 漂移（如果用了 keepalived/脚本）；
5. 停掉失联旧主上的所有连接（通过 Manager 的设备控制，防脑裂）。

配置片段感受一下：

```ini
[server default]
manager_workdir=/var/log/masterha/
manager_log=/var/log/masterha/manager.log
master_binlog_dir=/data/mysql
master_ip_failover_script=/usr/local/bin/master_ip_failover
master_ip_online_change_script=/usr/local/bin/master_ip_online_change
password=xxx
repl_password=xxx
ssh_user=root
ping_interval=1
ping_type=SELECT          # 或 CONNECT/INSERT

[server1]
hostname=192.168.1.10
candidate_master=1        # 晋升优先级
check_repl_delay=0        # 延迟超阈值不当候选

[server1] 类的段落每实例一个
```

## Orchestrator：拓扑可视化 + 智能恢复

Orchestrator 是另一种物种：它不依赖 SSH，通过 MySQL 账号直连各实例，持续探测复制拓扑并画成图：

```
MySQL:3306 (master)
  ├── MySQL:3307 (replica)
  │     └── MySQL:3309 (replica of replica)
  └── MySQL:3308 (replica)
```

能力全景：

- **拓扑自动发现**：`discover` 一台，整棵树自动扒出来（顺着 `SHOW SLAVE STATUS` 递归）。
- **可视化 + API**：Web 界面直接看拓扑、拖拽模拟、`orchestrator-client` 命令行和 REST API 驱动一切。
- **智能恢复**：`recover` 一条命令，自动完成"选最新从库 → 晋升 → 其余重指向"，内置多种恢复策略（主动模式还能和 Consul/ProxySQL 联动改路由）。
- **死主检测**：企吐探测策略、`AutoFailover` 可开可关——**默认是"建议模式"，要显式配置才自动切**，这个偏保守的设计是对的。
- **中间主支持**：中继拓扑（A→B→C，B 挂了能提升 C 并接上 A）是 MHA 的短板，Orchestrator 处理得更优雅。
- **GTID 优先**：整个恢复流程假设复制走 `MASTER_AUTO_POSITION`，选主判据就是 `gtid_executed` 集合差。

它的架构是 Center + 后端数据库（MySQL/SQLite 存拓扑数据）+ raft 多节点可选（HA 自身）。

```bash
# 典型恢复调用
orchestrator-client -c recover -i 192.168.1.10:3306
# orchestrator 自动完成整条链路
```

## 正面对比

| 维度 | MHA | Orchestrator |
|---|---|---|
| 架构 | Manager + Node，SSH 依赖 | Center + HTTP agent-less 探测 |
| failover 速度 | 秒级（10~30s 完成） | 秒级，strategy 可调 |
| binlog 补偿 | **强项**：SSH 捞旧主 binlog | 弱：不捞，依赖从库已有数据 |
| 主从延迟从库 | 可排除（check_repl_delay） | 支持，策略更细 |
| 中间主/链式拓扑 | 不支持 | 完整支持 |
| 可视化 | 无 | 拓扑图 + Web + API |
| 脑裂防护 | 靠 Manager 控制旧主 | hooks 脚本可控 + 更完善的状态机 |
| VIP/脚本集成 | 成熟（IP failover 脚本传统） | 通过 PreFailover/PostFailover hooks |
| 维护状态 | 项目活跃度低（社区版 0.58 停在多年前，商业支持走 Percona） | **活跃**，持续迭代 |
| 学习成本 | 低，脚本化 | 中，概念多（cluster/instance/recovery analysis） |

## 选型决策

**选 MHA 的场景**：两从库一主的小规模经典架构、团队有 Shell 脚本维护能力、binlog 补偿是硬需求（主库写入强、复制延迟大时，MHA 的 salvage 能少丢数据）、不想引入新系统。

**选 Orchestrator 的场景**：多集群、大规模实例、复杂拓扑（级联复制）、需要可视化和 API 驱动的自动化、想和 ProxySQL/Consul 联动的现代架构。**新上手的团队（没有历史 MHA 包袱）默认推荐它**，除非 binlog 补偿是核心诉求——那个 MHA 确实强。

**第三个选项：云 RDS 自带的 HA**。阿里云 RDS 的切换、AWS RDS Multi-AZ——如果你已经在云上，内置 HA 是最省事的，把精力放在应用连接层（连接池重连、短暂报错的重试）上。云 HA 的切换时间通常 30~60s，比自建慢但省运维。

## 共同的前提：不管选什么，这些必须先做好

HA 工具只是 failover 的执行器，**没有以下基建，上什么工具都白搭**：

1. **半同步复制（semi-sync）**。这是"选新主不丢数据"的前提——异步复制下，主库已提交但没传到从库的事务，failover 即丢失。`rpl_semi_sync_master_wait_point = AFTER_SYNC` + 至少一个半同步从库，RPO 趋近 0。

2. **从库 `super_read_only=ON`**。防从库被误写导致晋升时数据回退（Orchestrator 有前置检查，MHA 也要自律）。

3. **应用连接层要能failover**。连接池要支持重连 + 失败转移（HikariCP、Druid 都有），硬编码 IP 的服务在切换后全挂。中间件方案（ProxySQL/MyCat）或 VIP 都要提前演练。

4. **定期演练**。**没演练过的 HA 等于没有 HA**。每季度一次真切：kill 主库进程、观察监控、计时恢复、验证数据、应用报错窗口。演练记录归档，RTO 实测值写进容量报告。

5. **监控告警前置**。failover 发生前后，告警要能告诉值班"发生了什么、新主是谁、应用恢复了吗"，不然半夜切完了没人知道，第二天用户投诉才发现。

## 一次 failover 的时间账

理论 vs 现实的差距：

```
检测：  2~10s（心跳间隔 + 确认次数）
决策： <1s
salvage：0s（正常）~ 数分钟（旧主网络分区但活着，SSH 不通切不了）
切换： 秒级
应用恢复：连接池刷新（秒级）~ VIP 漂移 + DNS TTL（分钟级）
总计：  理想 10~30s，现实含应用层 1~5 分钟常见
```

**应用层的恢复时间往往是总 RTO 的大头**——所以演练要端到端：从杀主库到业务服务全绿，计总时长。只测数据库层切换时间的演练是自欺欺人。

## 小结

MHA 和 Orchestrator 是 MySQL 自建 HA 的两条经典路线：前者成熟简单、binlog 补偿强、拓扑简单时可靠；后者可视化强、拓扑管理现代、活跃度高、新系统首选。半同步复制 + super_read_only + 应用连接层支持切换 + 定期演练四个前提比选哪个工具更重要。云 RDS 用户优先用内置 HA，把工程精力放在连接层。下一篇讲备份体系：XtraBackup 的全量、增量与恢复演练。
