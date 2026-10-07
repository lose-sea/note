# Redis 持久化讲透：RDB、AOF 与混合持久化怎么选

> Redis 是内存数据库，断电数据就没了。
> 持久化就是把内存数据落盘的机制。
>
> 本篇讲清楚 RDB 和 AOF 各自的机制、优缺点、
> 混合持久化是什么、以及生产到底该怎么配。

## 一、为什么要两种机制

先说结论：**RDB 和 AOF 是两种完全不同的思路**。

| | RDB | AOF |
|---|---|---|
| 思路 | **快照**：某个时刻的全量数据 | **日志**：记录每一条写命令 |
| 内容 | 二进制压缩数据 | 文本协议格式的命令 |
| 恢复 | 直接加载，快 | 逐条重放，慢 |
| 文件大小 | 小 | 大 |
| 数据安全性 | 丢最后一次快照之后的数据 | 最多丢 1 秒（取决于刷盘策略） |

这个对比决定了它们的定位：
**RDB 适合备份和快速恢复，AOF 适合保证数据安全。**

## 二、RDB：快照

### 2.1 触发方式

**自动触发**（配置 `save` 规则）：

```conf
# redis.conf
save 3600 1        # 3600 秒内有 1 次修改就触发
save 300 100       # 300 秒内有 100 次修改
save 60 10000      # 60 秒内有 10000 次修改
```

满足**任意一个**条件就触发。多个条件是为了在不同写入压力下都能有合理的快照频率。

**手动触发**：

```bash
redis-cli SAVE          # ⚠️ 阻塞！主进程执行，期间不能处理任何请求
redis-cli BGSAVE        # ✅ 后台执行，fork 子进程处理
```

**生产只用 `BGSAVE`，永远不要用 `SAVE`。**

其他触发时机：
- 主从复制时，主库收到 `SYNC` 会自动 `BGSAVE`
- 执行 `SHUTDOWN` 时（如果没开 AOF）
- `FLUSHALL` 也会触发（生成一个空快照）

### 2.2 原理：fork + Copy-On-Write

`BGSAVE` 的过程：

```
1. 主进程 fork() 出一个子进程
   ├─ 子进程和主进程共享同一份内存（页表复制，不复制物理内存）
   │
2. 子进程把内存数据写入临时 RDB 文件
   │
3. 主进程继续处理请求
   ├─ 如果有写请求，被修改的内存页会被复制一份（COW）
   ├─ 主进程改副本，子进程看到的还是 fork 那一刻的快照
   │
4. 子进程写完，用临时文件替换旧的 RDB 文件
```

**关键技术是 Copy-On-Write（写时复制）**：
fork 时并不真的复制内存（那样太慢），
而是让父子进程共享物理页，只有某页被修改时才复制那一页。

⚠️ **COW 的内存开销**：
如果 fork 之后有大量写入，被修改的页都要复制，
**内存占用可能瞬间翻倍**。所以要预留内存：
**Redis 实际使用内存不要超过机器的 45%~50%**。

⚠️ **fork 本身会短暂阻塞**：
虽然 fork 不复制内存，但复制页表需要时间。
内存越大，页表越大，fork 越慢。
**几十 GB 的实例 fork 可能阻塞几百毫秒**。

```bash
# 监控最近一次 fork 耗时（微秒）
INFO stats
# latest_fork_usec: 12345     ← 12ms
```

### 2.3 RDB 的优缺点

✅ **优点**：
- 文件紧凑（二进制压缩），适合备份
- 恢复速度快（直接加载）
- fork 后主进程几乎不受影响
- 适合做**灾难恢复**：把 RDB 文件拷到别的地方

❌ **缺点**：
- **会丢数据**：两次快照之间的数据，宕机就没了
- fork 有阻塞风险（大实例）
- 频繁快照会导致大量磁盘 IO

## 三、AOF：追加日志

### 3.1 原理

每执行一条**写命令**，就把这条命令以 Redis 协议格式追加到 AOF 文件末尾。

```bash
SET name "Tom"
# AOF 文件里记录（RESP 协议格式）：
*3
$3
SET
$4
name
$3
Tom
```

启动时，**重新执行 AOF 文件里的所有命令**来恢复数据。

### 3.2 刷盘策略：决定安全性

这是 AOF 最关键的配置项：

```conf
appendfsync always     # 每条命令都 fsync：最安全，性能最差
appendfsync everysec   # 每秒 fsync 一次：折中（默认）
appendfsync no         # 交给操作系统决定：最快，最不安全
```

| 策略 | 数据安全 | 性能 |
|---|---|---|
| `always` | 最多丢 1 条命令 | 每个写都要刷盘，QPS 大幅下降 |
| **`everysec`（默认推荐）** | **最多丢 1 秒数据** | 很好 |
| `no` | 可能丢很多（OS 通常 30 秒刷一次） | 最好 |

**生产用 `everysec`**，这是安全性与性能的平衡点。

```bash
# 查看配置
CONFIG GET appendfsync
```

### 3.3 AOF 重写：解决文件膨胀

问题：不断追加，文件会越来越大。

```bash
INCR counter     # 执行 1000 次
# AOF 里记录 1000 条 INCR 命令
# 但恢复时只需要最终的 counter = 1000
```

**AOF 重写（Rewrite）**：根据当前内存数据，
生成一份"能重建当前状态的最小命令集"。

```bash
redis-cli BGREWRITEAOF      # 后台重写
```

自动触发配置：

```conf
auto-aof-rewrite-percentage 100    # 比上次重写后增长了 100%
auto-aof-rewrite-min-size 64mb     # 且文件至少 64MB
```

重写原理（跟 RDB 类似）：
1. fork 子进程
2. 子进程读当前内存数据，生成新 AOF（**写的是最终值命令，不是历史命令**）
3. 期间主进程的新写命令，同时追加到**旧 AOF 缓冲区**和**重写缓冲区**
4. 子进程写完，主进程把重写缓冲区的增量命令追加到新 AOF
5. 新 AOF 原子替换旧文件

### 3.4 AOF 的优缺点

✅ **优点**：
- 数据安全性高（`everysec` 最多丢 1 秒）
- AOF 是**文本格式**（虽然协议格式不直观），便于人工检查和修复
- 写错了可以用 `redis-check-aof` 修

❌ **缺点**：
- 文件比 RDB 大
- **恢复慢**：要逐条重放命令
- 重写时有 fork 开销

```bash
# AOF 文件损坏时修复
redis-check-aof --fix appendonly.aof
```

## 四、混合持久化（Redis 4.0+）

这是**现在的最优解**，结合两者优点：

```conf
aof-use-rdb-preamble yes     # 4.0+ 默认开启
```

**机制**：
- AOF 重写时，子进程把当前内存数据以 **RDB 二进制格式**写入新 AOF 文件的开头
- 重写期间的增量命令，以 **AOF 文本格式**追加在后面

```
┌─────────────────────────┐
│  RDB 格式的全量数据       │  ← 恢复时直接加载，快
├─────────────────────────┤
│  AOF 格式的增量命令       │  ← 保证数据完整
└─────────────────────────┘
```

效果：**恢复速度快（RDB 部分）+ 数据丢失少（AOF 部分）**。

```bash
# 查看是否开启
CONFIG GET aof-use-rdb-preamble
# 1) "aof-use-rdb-preamble"
# 2) "yes"
```

## 五、生产怎么配：决策表

| 场景 | 建议 |
|---|---|
| **纯缓存，数据丢了可从 DB 重建** | **可以不开持久化**，`save ""` |
| 一般业务缓存，允许少量丢失 | 只开 RDB |
| **重要数据，不能丢** | **RDB + AOF 都开**（混合持久化） |
| 极致性能，数据不重要 | 全关 |

### 推荐配置（大多数场景）

```conf
# RDB
save 3600 1
save 300 100
save 60 10000
dbfilename dump.rdb
dir /var/lib/redis

# AOF
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes        # 混合持久化
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# 重要：AOF 和 RDB 都开时，启动时用 AOF 恢复（数据更全）
```

### 如果只当缓存用

```conf
save ""              # 关闭 RDB
appendonly no        # 关闭 AOF
maxmemory 4gb
maxmemory-policy allkeys-lru
```

⚠️ 但要注意：即使关了持久化，
**主从复制仍然依赖 RDB**（全量同步时主库要生成 RDB）。
所以完全关掉 RDB 可能导致主从全量同步失败。
稳妥做法是**关 AOF，保留 RDB**。

## 六、启动时加载哪个文件

优先级：**AOF 高于 RDB**。

```
启动时
  ├─ appendonly = yes 且存在 AOF 文件 → 加载 AOF（数据更全）
  └─ 否则                             → 加载 RDB
```

⚠️ 一个坑：如果开着 AOF，但 AOF 文件损坏或为空，
Redis 会**加载空的 AOF**，导致数据看起来"全没了"。
这时候不要慌，关掉 AOF 重启，就能从 RDB 恢复。

```bash
# 应急：临时关闭 AOF 从 RDB 恢复
redis-cli CONFIG SET appendonly no
# 重启后数据从 RDB 加载
# 确认数据没问题再重新开启（会触发一次重写生成新 AOF）
redis-cli CONFIG SET appendonly yes
```

## 七、运维实操

### 7.1 查看持久化状态

```bash
INFO persistence
```

关键字段：

```
rdb_last_bgsave_status:ok          # 上次 BGSAVE 是否成功
rdb_last_save_time:1730000000      # 上次成功保存的时间戳
rdb_changes_since_last_save:15     # 距上次保存后有多少次修改
aof_enabled:1                      # AOF 是否开启
aof_last_bgrewrite_status:ok       # 上次重写是否成功
aof_last_write_status:ok           # ⚠️ 如果这里是 err 要警惕
```

⚠️ **`aof_last_write_status:err` 是危险信号**，
说明 AOF 刷盘失败（通常是磁盘满了），
此时 Redis 会拒绝写入（默认 `no-appendfsync-on-rewrite` 的策略）。

### 7.2 备份策略

```bash
# 定期备份 RDB（crontab）
0 3 * * * cp /var/lib/redis/dump.rdb /backup/redis/dump_$(date +\%Y\%m\%d).rdb
```

**要点**：
- RDB 文件要**异地备份**（不能只在本机）
- 定期验证备份**能否恢复**（很多人备份了从没验证过）
- 保留多份（按天，保留 7~30 天）

### 7.3 监控指标

| 指标 | 命令 | 告警阈值 |
|---|---|---|
| 最近 fork 耗时 | `INFO stats` → `latest_fork_usec` | > 500000（0.5秒） |
| AOF 写入状态 | `INFO persistence` → `aof_last_write_status` | 非 ok |
| 距上次保存的修改数 | `rdb_changes_since_last_save` | 持续增长说明没触发 |
| AOF 文件大小 | 文件系统监控 | 增长过快要检查重写 |

## 八、三个常见误区

**误区 1：开了 AOF 就不会丢数据**
——`everysec` 最多丢 1 秒的数据。
要真的不丢得用 `always`，但性能会崩。
**Redis 的定位本来就不是强一致存储**。

**误区 2：RDB 的 fork 不影响业务**
——fork 会短暂阻塞主进程，大实例（几十 GB）可能阻塞几百毫秒到秒级。
监控 `latest_fork_usec`。

**误区 3：AOF 文件可以直接看懂**
——AOF 是 **RESP 协议格式**，不是可读的 `SET key value`。
虽然比二进制好，但也不算"可读"。

## 九、小结

- **RDB = 快照**：文件小、恢复快、但会丢快照之后的数据
- **AOF = 日志**：数据安全性高（最多丢 1 秒）、文件大、恢复慢
- **生产必用 `appendfsync everysec`**，`always` 太慢，`no` 太危险
- **混合持久化（4.0+ 默认）最优**：AOF 文件里 RDB 全量 + AOF 增量
- Redis 的 fork 靠 **Copy-On-Write**，但 COW 会让内存临时上涨，
  **Redis 内存不要超过机器内存的 50%**
- **启动时 AOF 优先于 RDB**；AOF 损坏时关掉 AOF 可从 RDB 恢复
- 纯缓存可以关持久化，但**建议保留 RDB**（主从复制依赖它）
- 监控 `latest_fork_usec` 和 `aof_last_write_status`
- RDB 要**异地备份并定期验证可恢复**

下一篇讲缓存三大问题——穿透、击穿、雪崩。
这是 Redis 用作缓存时最经典、也最容易引发线上事故的三个场景。
