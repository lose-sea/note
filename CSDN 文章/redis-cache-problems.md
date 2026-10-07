# 缓存穿透、击穿、雪崩：三个经典问题与完整解决方案

> 这三个问题是 Redis 面试必考，也是线上事故高发区。
> 名字相似但成因和解决方式完全不同，混着说一定是没真懂。
>
> 本篇把三者的成因、区别、解决方案讲透，
> 每种方案都给可直接用的代码。

## 一、先分清三个概念

| 问题 | 一句话 | 关键特征 |
|---|---|---|
| **穿透** | 查询**根本不存在**的数据 | 缓存和 DB 都没有，每次都打到 DB |
| **击穿** | **单个热点 key 过期** | 某一个 key 失效瞬间，大量请求涌向 DB |
| **雪崩** | **大批 key 同时过期** | 同一时间大量 key 失效，DB 压力陡增 |

快速区分：
- 查的是**不存在的 id**（比如 id = -1）→ 穿透
- 查的是**存在的热点**，只是恰好过期 → 击穿
- **一大批** key 一起没了 → 雪崩

## 二、缓存穿透

### 2.1 成因

```python
def get_user(user_id):
    data = redis.get(f"user:{user_id}")
    if data is None:
        data = db.query("SELECT * FROM users WHERE id = %s", user_id)
        if data:
            redis.setex(f"user:{user_id}", 3600, json.dumps(data))
        return data        # ← 查不到时，不写缓存，直接返回 None
    return json.loads(data)
```

问题在最后一步：**DB 查不到时不写缓存**。
于是每次请求同一个不存在的 id，都会打到 DB。

正常业务中这类请求很少，但如果是**恶意攻击**
（用脚本遍历不存在的 id），DB 会被打垮。

### 2.2 解决方案一：缓存空值

```python
def get_user(user_id):
    key = f"user:{user_id}"
    data = redis.get(key)
    if data is not None:
        return None if data == b"__NULL__" else json.loads(data)

    data = db.query("SELECT * FROM users WHERE id = %s", user_id)
    if data:
        redis.setex(key, 3600, json.dumps(data))
    else:
        # ✅ 空值也缓存，但 TTL 要短（比如 60 秒）
        redis.setex(key, 60, "__NULL__")
    return data
```

要点：
- 用一个**特殊标记**（`__NULL__`）表示"确实不存在"
- **TTL 要短**（60 秒 vs 正常的 3600 秒），
  否则万一后来真插入了这条数据，会长时间读不到

代价：会占用一些内存存空值。如果攻击者用海量随机 id，
仍会产生大量空 key（所以还要配合下面的方案）。

### 2.3 解决方案二：布隆过滤器

**原理**：把所有**存在的 key** 预先放进一个位数组，
查询时先过一遍——布隆过滤器说"不存在"，那就**一定不存在**，
直接返回，不用查 DB。

```python
# pip install pybloom-live  或用 Redis 的 BF.* 模块
from pybloom_live import ScalableBloomFilter

bf = ScalableBloomFilter(initial_capacity=100000, error_rate=0.001)

# 初始化：把所有有效 id 加进去
for uid in db.query_all_ids():
    bf.add(uid)

def get_user(user_id):
    if user_id not in bf:        # ✅ 一定不存在，直接返回
        return None
    # 后续照常走缓存逻辑
    ...
```

**用 Redis 原生布隆过滤器**（需要 RedisBloom 模块）：

```bash
BF.RESERVE user_filter 0.001 1000000      # 误判率 0.1%，容量 100 万
BF.ADD user_filter 1001
BF.EXISTS user_filter 1001                # 1 = 可能存在
BF.EXISTS user_filter -1                  # 0 = 一定不存在
```

**关键特性**：
- ✅ **说"不存在"就一定不存在**（不会漏判）
- ⚠️ **说"存在"可能其实不存在**（有误判率，通常设 0.1%~1%）
- ❌ **不支持删除**（标准布隆过滤器）；要删除得用 Counting Bloom Filter

**适用场景**：id 集合**相对稳定**（不会频繁新增）。
如果要频繁新增，需要维护过滤器和 DB 的一致性。

### 2.4 解决方案三：参数校验 + 限流

```python
def get_user(user_id):
    # 1. 基础校验：id 必须为正整数且在合理范围
    if not isinstance(user_id, int) or user_id <= 0 or user_id > 10**9:
        return None

    # 2. 对同一 IP 的请求限流
    if not rate_limiter.allow(request.ip):
        raise TooManyRequests()
    ...
```

这是**第一道防线**，成本最低。
比如 id 不可能是负数、不可能超过 10 亿，直接在接口层拦掉。

### 2.5 三种方案对比

| 方案 | 实现难度 | 效果 | 副作用 |
|---|---|---|---|
| 缓存空值 | 低 | 好 | 占内存，TTL 要短 |
| 布隆过滤器 | 中 | 最好 | 有误判，不支持删除 |
| 参数校验 + 限流 | 低 | 兜底 | 只能挡规则明确的攻击 |

**生产建议：参数校验 + 缓存空值**（成本最低，覆盖大多数场景）。
数据量特别大且 id 稳定时再加布隆过滤器。

## 三、缓存击穿

### 3.1 成因

某个**极热点的 key**（比如首页推荐、爆款商品）在某一刻过期，
此时**成千上万**个请求同时发现缓存没了，
全部涌向 DB 去重建缓存。

区别穿透的关键：**这个数据是存在的**，只是缓存恰好失效。

### 3.2 解决方案一：互斥锁（最常用）

只允许**一个**线程去 DB 查并重建缓存，其他线程等待。

```python
import uuid, time
import redis

r = redis.Redis()

def get_with_mutex(key, ttl=3600, lock_ttl=3):
    data = r.get(key)
    if data:
        return data

    lock_key = f"lock:{key}"
    token = str(uuid.uuid4())

    # 尝试获取锁（NX + EX 是原子操作）
    if r.set(lock_key, token, nx=True, ex=lock_ttl):
        try:
            data = db_query(key)            # 只有拿到锁的去查 DB
            if data:
                r.setex(key, ttl, data)
            else:
                r.setex(key, 60, "__NULL__")   # 顺带防穿透
            return data
        finally:
            # ⚠️ 必须用 Lua 保证"判断 value 再删"的原子性
            r.eval("""
                if redis.call('get', KEYS[1]) == ARGV[1] then
                    return redis.call('del', KEYS[1])
                end
                return 0
            """, 1, lock_key, token)
    else:
        # 没拿到锁：短暂等待后重试
        time.sleep(0.05)
        return get_with_mutex(key, ttl, lock_ttl)
```

🔑 **三个关键点**：

1. `SET lock_key token NX EX 3` —— **NX（不存在才设）+ EX（过期时间）必须一起用**，
   否则进程崩溃锁永不释放，死锁
2. **释放锁必须用 Lua 脚本**比对 token 再删。
   否则可能删掉别人的锁（自己的锁超时了，别人已经拿到锁，
   你一删把别人的删了）
3. `lock_ttl` 要**大于 DB 查询耗时**，但不要太大

### 3.3 解决方案二：逻辑过期（永不过期）

**不给 key 设物理 TTL**，而是把过期时间**存进 value 里**。

```python
import json, time

def set_logical(key, value, logical_ttl=3600):
    payload = {
        "value": value,
        "expire_at": time.time() + logical_ttl,
    }
    r.set(key, json.dumps(payload))      # 注意：不设 EX

def get_logical(key):
    raw = r.get(key)
    if raw is None:
        return None                       # 真的没有（走正常流程）

    payload = json.loads(raw)
    if time.time() < payload["expire_at"]:
        return payload["value"]           # 没过期，直接返回

    # 逻辑上过期了：返回旧值，同时异步重建
    if r.set(f"lock:{key}", 1, nx=True, ex=3):
        threading.Thread(target=rebuild, args=(key,)).start()
    return payload["value"]               # ✅ 先返回旧数据，不阻塞
```

**优点**：
- 永远不会有"大量请求同时等待"的情况
- 请求不会阻塞，体验好

**缺点**：
- 会短暂返回**过期数据**（最终一致）
- 实现复杂，要处理异步重建的并发

**适用**：对一致性要求不高、但并发极高的场景（比如商品详情、排行榜）。

### 3.4 两种方案怎么选

| | 互斥锁 | 逻辑过期 |
|---|---|---|
| 一致性 | 强（拿到的一定是新的） | 弱（可能返回旧数据） |
| 性能 | 有等待，吞吐受限 | 无等待，吞吐高 |
| 实现 | 简单 | 复杂 |
| 适用 | 一般场景 | 极热 key，允许短暂陈旧 |

## 四、缓存雪崩

### 4.1 成因

**大批 key 在同一时刻集体过期**，
或者 **Redis 实例直接挂了**，
导致所有请求瞬间打到 DB。

常见触发场景：
- 上线时批量预热缓存，全都设了相同的 TTL
- 定时任务在整点刷新缓存
- Redis 集群宕机

### 4.2 解决方案一：TTL 加随机值

```python
import random

def set_with_jitter(key, value, base_ttl=3600):
    # 基础 TTL + 随机 0~300 秒的抖动
    ttl = base_ttl + random.randint(0, 300)
    r.setex(key, ttl, value)
```

**就这么简单，但极其有效**。
原本 10 万个 key 都在 3600 秒后同时失效，
加上随机抖动后，它们会分散在 3600~3900 秒之间陆续过期，
DB 的压力从"一瞬间的尖峰"变成"平滑的小坡"。

### 4.3 解决方案二：多级缓存

```
请求 → 本地缓存(Caffeine/Guava) → Redis → DB
```

即使 Redis 全挂，本地缓存还能挡一部分。
代价是**一致性更难保证**（本地缓存无法主动失效，
只能靠短 TTL 或消息通知）。

### 4.4 解决方案三：Redis 高可用

这是**根本解法**：

- **主从 + 哨兵**：主库挂了自动切从库
- **Redis Cluster**：分片 + 高可用
- **限流降级**：Redis 挂了就限流，保住 DB

```python
# 降级：Redis 不可用时直接返回兜底数据，不去打 DB
def get_with_degrade(key):
    try:
        return r.get(key)
    except redis.ConnectionError:
        log.error("Redis 不可用，走降级")
        return get_fallback(key)      # 返回静态兜底数据或空
```

### 4.5 解决方案四：缓存预热

系统启动/大促前，主动把热点数据加载到缓存，
并**错开 TTL**。

```python
def warmup():
    for item in hot_items:
        set_with_jitter(f"item:{item.id}", item.to_json())
```

## 五、一个完整的缓存封装

把上面所有方案组合起来：

```python
import json, time, random, uuid, threading
import redis

r = redis.Redis()

class Cache:
    NULL = "__NULL__"

    def __init__(self, base_ttl=3600, jitter=300, null_ttl=60, lock_ttl=3):
        self.base_ttl, self.jitter = base_ttl, jitter
        self.null_ttl, self.lock_ttl = null_ttl, lock_ttl

    def _ttl(self):
        return self.base_ttl + random.randint(0, self.jitter)   # 防雪崩

    def get(self, key, loader):
        """
        loader: 缓存未命中时的 DB 查询函数，返回 None 表示不存在
        """
        raw = r.get(key)

        # 命中（含空值标记）
        if raw is not None:
            return None if raw.decode() == self.NULL else json.loads(raw)

        # 未命中 → 互斥锁重建（防击穿）
        lock_key = f"lock:{key}"
        token = str(uuid.uuid4())
        if r.set(lock_key, token, nx=True, ex=self.lock_ttl):
            try:
                data = loader()
                # 空值也缓存（防穿透）
                if data is None:
                    r.setex(key, self.null_ttl, self.NULL)
                else:
                    r.setex(key, self._ttl(), json.dumps(data))
                return data
            finally:
                r.eval("""
                    if redis.call('get', KEYS[1]) == ARGV[1] then
                        return redis.call('del', KEYS[1])
                    end
                    return 0
                """, 1, lock_key, token)

        # 没拿到锁 → 等一下重试
        time.sleep(0.05)
        return self.get(key, loader)

# 使用
cache = Cache()
user = cache.get(f"user:{uid}", lambda: db_find_user(uid))
```

这一个 `get` 方法同时解决了：
- **穿透**（空值缓存）
- **击穿**（互斥锁）
- **雪崩**（TTL 随机抖动）

## 六、三个问题的排查方法

| 现象 | 判断 | 排查 |
|---|---|---|
| DB 有大量**查不到**的查询 | 穿透 | 看 DB 慢日志里失败的 id |
| 某个 key 的 DB 查询**集中爆发** | 击穿 | 监控缓存命中率的突变点 |
| DB QPS **整体陡增** | 雪崩 | 看是不是批量 key 同时过期 |

```bash
# 监控缓存命中率
INFO stats
# keyspace_hits: 1000000
# keyspace_misses: 50000
# 命中率 = hits / (hits + misses) = 95%
```

**命中率突然下降**是最直接的信号。
正常业务应该在 90% 以上。

## 七、小结

| 问题 | 核心解法 | 备选 |
|---|---|---|
| **穿透** | **缓存空值（短 TTL）** | 布隆过滤器、参数校验限流 |
| **击穿** | **互斥锁（SET NX EX + Lua 释放）** | 逻辑过期（允许旧数据） |
| **雪崩** | **TTL 加随机抖动** | 多级缓存、高可用、预热、降级 |

三个必须记住的细节：
1. **空值缓存的 TTL 要短**（60 秒），否则新增数据读不到
2. **释放锁必须用 Lua 比对 token**，否则可能删掉别人的锁
3. **TTL 随机抖动**是成本最低、收益最高的雪崩防护

下一篇讲分布式锁——本篇的互斥锁只是一个简化版，
真正的分布式锁还要考虑可重入、自动续期、Redlock 等一堆问题。
