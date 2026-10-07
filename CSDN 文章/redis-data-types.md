# Redis 数据类型全景：五种基础类型怎么用、什么时候用

> Redis 快不全是因为"在内存里"，**数据结构选对了**才是关键。
> 用 String 存一个用户信息，和用 Hash 存，
> 内存占用和网络传输量能差好几倍。
>
> 本篇把五种基础类型 + 三种扩展类型讲透，
> 重点是**每种类型的适用场景和一个能直接抄的例子**。

## 一、Redis 的键与值

先明确一件事：**Redis 的 key 永远是 String**，
我们说的"数据类型"指的是 **value 的类型**。

```bash
TYPE user:1        # 查看类型
OBJECT ENCODING user:1   # 查看底层编码（很重要，见下文）
```

### 底层编码：同一个类型可能有多种实现

这是 Redis 内存优化的核心机制。比如 Hash：

| 条件 | 编码 | 特点 |
|---|---|---|
| 字段少（≤512）+ 值小（≤64字节） | `ziplist`（紧凑列表） | **省内存**，但查询是 O(n) |
| 超出阈值 | `hashtable` | 查询 O(1)，但内存开销大 |

```bash
HSET small_hash a 1 b 2
OBJECT ENCODING small_hash      # ziplist / listpack

# 塞进 600 个字段后
OBJECT ENCODING small_hash      # hashtable  ← 自动转换
```

⚠️ **转换是单向的**：一旦变成 hashtable，删掉字段也不会变回 ziplist。
所以阈值要提前规划（可在配置里调 `hash-max-listpack-entries`）。

## 二、String：最基础也最常被误用

```bash
SET name "Tom"
GET name                       # "Tom"
SET counter 0
INCR counter                   # 1（原子自增）
INCRBY counter 10              # 11
SETEX token 3600 "abc"         # 设置并指定 3600 秒过期（原子操作！）
SETNX lock_key 1               # 不存在才设置（分布式锁的基石）
MSET k1 v1 k2 v2               # 批量设置，减少网络往返
MGET k1 k2
```

### 适用场景

| 场景 | 例子 |
|---|---|
| 缓存单个值 | 用户信息 JSON、配置 |
| **计数器** | 点赞数、浏览量（`INCR` 原子） |
| **分布式锁** | `SET key value NX EX 30` |
| 限流 | `INCR` + `EXPIRE` |
| Session | token → 用户信息 |

### ⚠️ 常见误用：什么都往 String 里塞

```bash
# ❌ 存整个对象，改一个字段要全量读写
SET user:1 '{"name":"Tom","age":20,"city":"Beijing"}'
GET user:1        # 只想看 age，却要把整个 JSON 传回来
```

如果这个对象经常只改一两个字段，用 **Hash** 更合适。
但如果**每次都是整体读写**（比如缓存整个 HTML 片段），String 反而更好——
因为字符串编码更紧凑。

**判断标准**：
- 整体读写 → String
- 频繁改单个字段 → Hash

## 三、Hash：对象存储的正解

```bash
HSET user:1 name "Tom" age 20 city "Beijing"
HGET user:1 name                  # "Tom"
HMGET user:1 name age             # 批量取
HGETALL user:1                    # 全取（⚠️ 大 hash 会阻塞）
HINCRBY user:1 age 1              # 字段自增
HLEN user:1                       # 字段数
HEXISTS user:1 email              # 字段是否存在
```

### 适用场景

| 场景 | 例子 |
|---|---|
| **对象存储** | 用户信息、商品属性 |
| 购物车 | `cart:userId` → `{商品ID: 数量}` |
| 配置项分组 | 一组相关的配置 |

```bash
# 购物车：key = cart:1001，field = 商品ID，value = 数量
HSET cart:1001 88 2 99 1
HINCRBY cart:1001 88 1        # 加一件
HLEN cart:1001                # 购物车里有几种商品
HDEL cart:1001 99             # 删除
HGETALL cart:1001             # 结算
```

### ⚠️ 两个坑

**坑 1：`HGETALL` 在大 Hash 上会阻塞**
一个 Hash 有 10 万字段，`HGETALL` 会卡住 Redis 几百毫秒。
用 `HSCAN` 分批：

```bash
HSCAN user:big 0 COUNT 100       # 每次 100 个，游标迭代
```

**坑 2：Hash 不能对单个 field 设过期**
过期只能设在 key 上。要单字段过期就得拆成多个 key。

## 四、List：有序可重复

```bash
LPUSH queue a b c          # 左侧插入 → [c, b, a]
RPUSH queue d              # 右侧插入 → [c, b, a, d]
LPOP queue                 # 弹出 c
RPOP queue                 # 弹出 d
LRANGE queue 0 -1          # 范围取
LLEN queue
LTRIM queue 0 99           # 只保留前 100 个（控制长度）
```

### 适用场景

| 场景 | 命令组合 |
|---|---|
| **消息队列** | `LPUSH` + `BRPOP`（阻塞弹出） |
| 最新动态 / Feed 流 | `LPUSH` + `LTRIM` + `LRANGE` |
| 栈 | `LPUSH` + `LPOP` |

```bash
# 简易队列（生产用 Stream 更合适）
LPUSH task_queue "{json}"
BRPOP task_queue 30          # 阻塞等 30 秒，没任务就返回 nil

# 保留最新的 100 条动态
LPUSH feed:1001 "新动态"
LTRIM feed:1001 0 99
LRANGE feed:1001 0 9         # 取最新 10 条
```

⚠️ **List 做队列的两个问题**：
1. 没有 ACK 机制，消费者崩溃消息就丢了
2. 不支持多消费者组

**生产环境用 Stream**（Redis 5.0+），它才是正经的消息队列。

## 五、Set：无序去重

```bash
SADD tags:article1 redis mysql
SREM tags:article1 mysql
SMEMBERS tags:article1        # 全部成员（⚠️ 大集合会阻塞）
SISMEMBER tags:article1 redis # 是否存在 O(1)
SCARD tags:article1           # 成员数

# 集合运算（这是 Set 最独特的能力）
SINTER set1 set2              # 交集
SUNION set1 set2              # 并集
SDIFF set1 set2               # 差集
SINTERSTORE result set1 set2  # 交集存到新 key
```

### 适用场景

| 场景 | 例子 |
|---|---|
| **去重** | 已读文章、UV 统计 |
| **标签系统** | 文章标签、用户兴趣 |
| **社交关系** | 关注列表、好友、共同好友 |
| 抽奖 | `SRANDMEMBER` / `SPOP` |

```bash
# 共同关注
SADD following:u1 alice bob carol
SADD following:u2 bob carol dave
SINTER following:u1 following:u2      # bob, carol

# 判断是否点赞过
SADD liked:article1 u1001
SISMEMBER liked:article1 u1002        # 0 = 没赞过
```

⚠️ 大集合用 `SSCAN` 代替 `SMEMBERS`。

## 六、ZSet（Sorted Set）：排行榜的不二之选

ZSet = Set + 每个元素一个 **score**，按 score 排序。
底层是**跳表（Skip List）+ 哈希表**，
所以既能按成员 O(1) 查找，又能按 score 范围查询 O(log N)。

```bash
ZADD rank 100 "playerA" 85 "playerB" 92 "playerC"
ZSCORE rank playerA              # 100
ZINCRBY rank 10 playerB          # 95（加分）
ZRANGE rank 0 9 WITHSCORES       # 前 10 名（score 升序）
ZREVRANGE rank 0 9 WITHSCORES    # 前 10 名（降序，排行榜用这个）
ZRANK rank playerA               # 排名（从 0 开始，升序）
ZREVRANK rank playerA            # 降序排名
ZCARD rank                       # 总数
ZREM rank playerA
ZREMRANGEBYRANK rank 100 -1      # 删除 100 名之后的所有人（只保留前 100）
```

### 适用场景

| 场景 | 例子 |
|---|---|
| **排行榜** | 积分榜、销量榜、热搜 |
| **延迟队列** | score = 执行时间戳 |
| 优先级队列 | score = 优先级 |
| 时间线 | score = 时间戳，按时间范围取 |

```bash
# 延迟队列：score 存执行时间
ZADD delay_queue 1730000000 "task1"
# 取到期的任务
ZRANGEBYSCORE delay_queue 0 $(date +%s) LIMIT 0 10
# 取出后删除（要用 Lua 保证原子）
```

```bash
# 排行榜 + 只保留前 100
ZADD leaderboard 1500 "user:1"
ZREVRANGE leaderboard 0 9 WITHSCORES      # TOP 10
ZREVRANK leaderboard "user:1"             # 我是第几名
ZREMRANGEBYRANK leaderboard 100 -1        # 定期清理
```

## 七、三种扩展类型

### 7.1 Bitmap：海量布尔值

```bash
SETBIT sign:2026-10 5 1        # 用户 5 在 10 月 5 日签到
GETBIT sign:2026-10 5          # 是否签到
BITCOUNT sign:2026-10          # 这个月签到几天
BITOP AND both d1 d2           # 两天都签到的用户
```

**价值：极省内存**。1 亿用户的签到状态只要约 12 MB。
典型场景：签到、活跃用户标记、布隆过滤器底层。

### 7.2 HyperLogLog：UV 统计

```bash
PFADD uv:20261007 u1 u2 u3 u1
PFCOUNT uv:20261007            # 3（自动去重）
PFMERGE uv:week uv:d1 uv:d2    # 合并多天
```

**0.81% 的误差率，但只占 12 KB 内存**，
不管你塞进去多少数据。统计 UV 用它，精确去重才用 Set。

⚠️ **不能取单个元素**，只能取基数。

### 7.3 Geo：地理位置

```bash
GEOADD shops 116.40 39.90 "shop1" 116.41 39.91 "shop2"
GEODIST shops shop1 shop2 km            # 距离
GEORADIUS shops 116.40 39.90 5 km       # 5 公里内的店铺（已废弃）
GEOSEARCH shops FROMLONLAT 116.40 39.90 BYRADIUS 5 km   # 6.2+ 新命令
```

底层就是 ZSet（GeoHash 编码成 score），所以 ZSet 命令也能用。

### 7.4 Stream：正经的消息队列

```bash
XADD mystream * sensor_id 1234 temp 19.8     # * 表示自动生成 ID
XREAD BLOCK 2000 STREAMS mystream $          # 阻塞读新消息

# 消费者组（支持多消费者、ACK、重试）
XGROUP CREATE mystream group1 0
XREADGROUP GROUP group1 c1 COUNT 1 STREAMS mystream >
XACK mystream group1 <message-id>            # 确认处理完成
XPENDING mystream group1                     # 查看未确认的消息
```

Stream 解决了 List 做队列的所有问题：**多消费者组、ACK、消息持久化、回溯**。

## 八、选型速查表

| 你的需求 | 用什么 |
|---|---|
| 缓存整个对象 / 计数器 / 锁 | **String** |
| 对象，且要频繁改单个字段 | **Hash** |
| 简单队列 / 最新列表 | **List**（或 Stream） |
| 去重、集合运算、共同好友 | **Set** |
| 排行榜、延迟队列、带权重 | **ZSet** |
| 海量布尔标记（签到） | **Bitmap** |
| UV 统计（允许误差） | **HyperLogLog** |
| 附近的人 / 门店 | **Geo** |
| 可靠消息队列 | **Stream** |

## 九、三个通用原则

**1. key 要有命名空间**

```bash
# ❌ 全平铺，容易冲突
SET name "Tom"
SET name "Jerry"     # 覆盖了！

# ✅ 业务:对象:ID:属性
SET user:1001:name "Tom"
SET order:20261007:status "paid"
```

**2. 避免大 key**

| 类型 | 危险阈值 |
|---|---|
| String | > 10 KB（有说 1 MB） |
| Hash/Set/ZSet/List | 元素数 > 5000，或整体 > 10 MB |

大 key 的问题：删除卡顿、迁移失败、网络传输慢、
`HGETALL`/`SMEMBERS` 阻塞。

**3. 一定要设过期时间**

```bash
SET cache:xxx value EX 3600       # 缓存必须有 TTL
```

例外：持久化数据（如用户资料缓存）可以不设，
但**必须有主动更新/删除的机制**。

## 十、小结

- **key 永远是 String**，类型说的是 value
- Redis 会用**不同编码**存同一类型，小数据用紧凑结构省内存（转换单向）
- **String**：整体读写的缓存、计数器、分布式锁
- **Hash**：对象且频繁改单字段；`HGETALL` 大 hash 会阻塞，用 `HSCAN`
- **List**：简单队列和最新列表；生产队列用 **Stream**
- **Set**：去重 + 集合运算（共同好友）
- **ZSet**：**排行榜**首选，底层跳表，范围查询 O(log N)
- **HyperLogLog**：UV 统计，12 KB 固定内存，0.81% 误差，不能取单元素
- key 用 `业务:对象:ID` 命名，**避免大 key**，**缓存必设 TTL**

下一篇讲持久化——内存数据断电就没了，
Redis 靠 RDB 和 AOF 两种机制把数据落到磁盘，
它们的区别和选择是运维必须掌握的知识。
