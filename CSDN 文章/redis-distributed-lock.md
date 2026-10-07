# Redis 分布式锁讲透：从 SETNX 到 Redlock 的所有坑

> 分布式锁看起来简单——`SETNX` 加锁，`DEL` 释放。
> 但真到生产环境，你要处理：进程崩溃锁不释放、
> 删了别人的锁、业务没执行完锁就过期、
> 主从切换导致锁失效……
>
> 本篇把这些坑一个个列出来，给出能用的解法，
> 最后说清楚 Redlock 到底该不该用。

## 一、分布式锁的最低要求

一个可用的分布式锁至少要满足：

1. **互斥性**：任意时刻只有一个客户端能持有
2. **不会死锁**：持有者崩溃后锁能自动释放
3. **加锁和解锁是同一个客户端**（不能删别人的锁）
4. **容错性**：部分 Redis 节点宕机时仍能工作

## 二、演进：五个版本的写法

### v1：SETNX + DEL（❌ 会死锁）

```python
r.setnx("lock", 1)
try:
    do_something()
finally:
    r.delete("lock")
```

**问题**：如果 `do_something()` 时进程崩溃，
`finally` 不会执行，**锁永远不释放**，死锁。

### v2：SETNX + EXPIRE（❌ 非原子）

```python
r.setnx("lock", 1)
r.expire("lock", 30)      # 加过期时间
```

**问题**：这两条命令**不是原子的**。
如果 `setnx` 成功后进程崩溃，还没来得及 `expire`，
又是死锁。

### v3：SET NX EX（✅ 可用，但仍有问题）

```python
r.set("lock", token, nx=True, ex=30)
```

Redis 2.6.12+ 支持 `SET key value NX EX seconds`，
**加锁和设过期时间是原子的**。这是正确的基础写法。

但仍有问题——**会删掉别人的锁**：

```python
# 客户端 A 加锁，超时 30 秒
# A 的业务执行了 35 秒（超过 30 秒），锁已自动释放
# 客户端 B 拿到锁
# A 执行完，DEL 删除锁 ← 把 B 的锁删了！
```

### v4：Lua 脚本原子释放（✅ 生产可用）

释放锁时**先比对 value 再删除**，用 Lua 保证原子性：

```python
import uuid
import redis

r = redis.Redis()

def acquire(lock_key, ttl=30):
    token = str(uuid.uuid4())          # 唯一标识
    ok = r.set(lock_key, token, nx=True, ex=ttl)
    return token if ok else None

def release(lock_key, token):
    # ⚠️ 必须是 Lua：GET 和 DEL 要原子执行
    script = """
    if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('del', KEYS[1])
    else
        return 0
    end
    """
    return r.eval(script, 1, lock_key, token)

# 使用
token = acquire("lock:order:123", ttl=30)
if token:
    try:
        do_something()
    finally:
        release("lock:order:123", token)
else:
    print("没拿到锁")
```

🔑 **为什么必须用 Lua？**

```python
# ❌ 错误：两步操作非原子
if r.get(lock_key) == token:      # 判断时是我的锁
    # 恰好这一刻锁过期了，B 拿到了锁
    r.delete(lock_key)             # 删掉了 B 的锁
```

`GET` 和 `DEL` 之间有时间窗口，必须合并成一个原子操作。

### v5：自动续期（看门狗）

**问题**：业务执行时间不确定，30 秒可能不够。

**解法：看门狗（Watchdog）**——
加锁成功后起一个后台线程，
每隔 TTL/3 时间检查锁还在不在，在就延长。

```python
import threading, time

class RedisLock:
    def __init__(self, r, key, ttl=30):
        self.r, self.key, self.ttl = r, key, ttl
        self.token = None
        self._timer = None

    def __enter__(self):
        self.token = str(uuid.uuid4())
        if not self.r.set(self.key, self.token, nx=True, ex=self.ttl):
            self.token = None
            raise RuntimeError("获取锁失败")
        self._start_watchdog()
        return self

    def __exit__(self, *exc):
        self._stop_watchdog()
        self._release()

    def _start_watchdog(self):
        """每 ttl/3 秒续期一次"""
        def renew():
            if self.token:
                # 只有锁还是我的才续期
                self.r.eval("""
                    if redis.call('get', KEYS[1]) == ARGV[1] then
                        return redis.call('pexpire', KEYS[1], ARGV[2])
                    end
                    return 0
                """, 1, self.key, self.token, self.ttl * 1000)
            self._timer = threading.Timer(self.ttl / 3, renew)
            self._timer.daemon = True
            self._timer.start()
        self._timer = threading.Timer(self.ttl / 3, renew)
        self._timer.daemon = True
        self._timer.start()

    def _stop_watchdog(self):
        if self._timer:
            self._timer.cancel()
            self._timer = None

    def _release(self):
        if self.token:
            self.r.eval("""
                if redis.call('get', KEYS[1]) == ARGV[1] then
                    return redis.call('del', KEYS[1])
                end
                return 0
            """, 1, self.key, self.token)
            self.token = None

# 使用
with RedisLock(r, "lock:order:123"):
    do_something()      # 执行多久都不怕，看门狗会自动续期
```

这就是 **Redisson 的 `watchdog` 机制**的原理。

## 三、用现成的库：Redisson

**Java 项目直接用 Redisson**，上面所有功能它都实现好了：

```java
RLock lock = redissonClient.getLock("lock:order:123");

// 自动续期（默认 30 秒 TTL，每 10 秒续一次）
lock.lock();
try {
    doSomething();
} finally {
    lock.unlock();
}

// 或者指定超时时间（不续期）
boolean acquired = lock.tryLock(10, 30, TimeUnit.SECONDS);
```

Redisson 额外提供的能力：
- **可重入锁**：同一线程可多次加锁（内部用 Hash 记重入次数）
- **公平锁**：按请求顺序获取
- **读写锁**：`RReadWriteLock`
- **联锁 / 红锁**

**Python 对应的是 `redis-py` 的 `Lock`**，但功能弱很多，
没有看门狗。生产建议自己封装或用 `redlock-py`。

## 四、主从切换导致的锁失效

这是**单 Redis 实例方案的根本缺陷**：

```
1. 客户端 A 在 master 上加锁成功
2. master 还没把锁同步给 slave，就宕机了
3. slave 被提升为新 master
4. 客户端 B 在新 master 上加锁 ← 也成功了！
5. A 和 B 同时持有锁 → 互斥性被破坏
```

### 解决方案：Redlock

Redlock 的思路：**向 N 个独立的 Redis 实例（通常 5 个）依次加锁，
超过半数（N/2 + 1）成功才算加锁成功**。

```
客户端
  ├─→ Redis 1  ✓
  ├─→ Redis 2  ✓
  ├─→ Redis 3  ✓   ← 3/5 成功，加锁成功
  ├─→ Redis 4  ✗
  └─→ Redis 5  ✗
```

关键约束：
1. N 个实例**互相独立**（不是同一个集群的分片，也不是主从）
2. 加锁有**超时时间**，超时就跳过这个节点
3. 总耗时必须**小于锁的 TTL**，否则认为失败
4. 释放时向**所有**实例发删除请求

```python
from redlock import Redlock

dlm = Redlock([
    {"host": "redis1", "port": 6379},
    {"host": "redis2", "port": 6379},
    {"host": "redis3", "port": 6379},
    {"host": "redis4", "port": 6379},
    {"host": "redis5", "port": 6379},
])

lock = dlm.lock("lock:order", 1000)      # TTL 1000 毫秒
if lock:
    try:
        do_something()
    finally:
        dlm.unlock(lock)
```

### ⚠️ Redlock 有争议，谨慎使用

Redis 作者 antirez 和分布式系统专家 Martin Kleppmann
曾就此激烈争论。主要的质疑：

1. **依赖时钟**：Redlock 假设各节点时钟大致同步。
   如果发生**时钟跳跃**（NTP 调整、运维改时间），
   锁的 TTL 计算会出错
2. **GC 停顿**：客户端 GC 停顿期间锁可能过期，
   但客户端以为自己还持有
3. **复杂度高，收益存疑**：为了极小概率的主从切换场景，
   引入 5 个实例和可观的延迟

**现实建议**：

| 场景 | 建议 |
|---|---|
| 一般业务（防止重复扣款、防止并发写） | **单实例 + Lua 释放 + 看门狗**，够用 |
| 对正确性要求极高（金融） | **别用 Redis 锁**，用数据库的乐观锁 / ZooKeeper / etcd |
| 必须用 Redlock | 确保有 **fencing token**（递增序号）做最终兜底 |

🔑 **fencing token 是什么**：
每次加锁返回一个**单调递增的序号**，
操作数据时带上这个序号，存储层拒绝处理序号更小的请求。
这样即使锁失效了（GC 停顿导致），
旧的请求也会被存储层挡住。这才是真正的兜底。

## 五、分布式锁的替代方案

很多时候**根本不需要分布式锁**。

### 5.1 数据库乐观锁（推荐）

```sql
UPDATE products
SET stock = stock - 1, version = version + 1
WHERE id = 1001 AND stock >= 1 AND version = 5;
-- 影响行数 0 说明被别人改过，重试
```

用 **CAS + 版本号**，不需要 Redis，
且天然和数据库事务一致。**扣库存这类场景首选这个**。

### 5.2 数据库悲观锁

```sql
BEGIN;
SELECT * FROM products WHERE id = 1001 FOR UPDATE;   -- 行锁
UPDATE products SET stock = stock - 1 WHERE id = 1001;
COMMIT;
```

简单可靠，但要**注意锁的范围和事务时长**（见 MySQL 锁那篇）。

### 5.3 Lua 脚本原子操作

很多时候"锁"要解决的是**多个操作的原子性**，
那不如直接把多个操作写成一个 Lua 脚本：

```python
# 扣库存：判断 + 扣减一步完成，不需要锁
script = """
local stock = tonumber(redis.call('get', KEYS[1]))
if stock <= 0 then
    return -1
end
redis.call('decr', KEYS[1])
return stock - 1
"""
r.eval(script, 1, "stock:1001")
```

**Lua 脚本在 Redis 里是原子执行的**，
这是最高效的"锁替代方案"。

### 选型建议

| 场景 | 方案 |
|---|---|
| 单纯防止重复执行 | 数据库唯一索引 / 乐观锁 |
| 扣库存、改余额 | **Lua 脚本** 或 DB 乐观锁 |
| 需要跨多个资源的原子操作 | 分布式锁 |
| 定时任务只在一台机器跑 | 分布式锁（或 K8s Lease） |
| 金融级强一致 | **别用 Redis**，用 etcd / ZK |

## 六、八个必须知道的坑

**坑 1：忘了设过期时间** → 死锁。用 `SET NX EX` 一步到位。

**坑 2：DEL 之前不比对 token** → 删别人的锁。用 Lua。

**坑 3：TTL 太短，业务没跑完锁就没了** → 用看门狗续期。

**坑 4：把锁的粒度设得太大**

```python
with lock("global_lock"):      # ❌ 全局锁，所有请求串行
    ...
with lock(f"order:{order_id}"):   # ✅ 按资源加锁
    ...
```

**坑 5：锁重入**

```python
def a():
    with lock: b()      # 外层加了锁
def b():
    with lock: ...      # ❌ 不可重入的话这里死锁
```

需要可重入就用 Redisson，或者自己用 Hash 记重入次数。

**坑 6：锁的 value 用了固定值**
必须用 UUID 等唯一标识，否则无法区分持有者。

**坑 7：Redis 单实例宕机** → 锁服务不可用。
要么接受（多数场景可接受），要么上 Redlock，要么换 etcd。

**坑 8：主从切换丢锁**（前面详述）→ 这是单实例方案的固有缺陷。

## 七、一份可以直接用的实现

```python
import uuid, threading, time
import redis

class DistLock:
    """生产可用的 Redis 分布式锁（单实例版）"""
    _RELEASE = """
    if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('del', KEYS[1])
    end
    return 0
    """
    _RENEW = """
    if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('pexpire', KEYS[1], ARGV[2])
    end
    return 0
    """

    def __init__(self, r, key, ttl=30, auto_renew=True, retry=0, retry_delay=0.1):
        self.r, self.key, self.ttl = r, key, ttl
        self.auto_renew = auto_renew
        self.retry, self.retry_delay = retry, retry_delay
        self.token = None
        self._timer = None

    def acquire(self):
        self.token = str(uuid.uuid4())
        for i in range(self.retry + 1):
            if self.r.set(self.key, self.token, nx=True, ex=self.ttl):
                if self.auto_renew:
                    self._schedule_renew()
                return True
            if i < self.retry:
                time.sleep(self.retry_delay)
        self.token = None
        return False

    def release(self):
        if not self.token:
            return
        if self._timer:
            self._timer.cancel()
            self._timer = None
        self.r.eval(self._RELEASE, 1, self.key, self.token)
        self.token = None

    def _schedule_renew(self):
        def renew():
            if self.token:
                try:
                    self.r.eval(self._RENEW, 1, self.key,
                                self.token, int(self.ttl * 1000))
                except Exception:
                    pass
                self._timer = threading.Timer(self.ttl / 3, renew)
                self._timer.daemon = True
                self._timer.start()
        self._timer = threading.Timer(self.ttl / 3, renew)
        self._timer.daemon = True
        self._timer.start()

    def __enter__(self):
        if not self.acquire():
            raise RuntimeError(f"获取锁失败: {self.key}")
        return self

    def __exit__(self, *exc):
        self.release()

# 使用
with DistLock(r, "lock:order:123", ttl=30, retry=3):
    do_something()
```

## 八、小结

- **最低可用写法**：`SET key token NX EX 30` + **Lua 比对 token 释放**
- **必须加过期时间**，且加锁和设 TTL 要**原子**（`NX EX` 一起用）
- **释放锁必须 Lua**，否则 `GET` 和 `DEL` 之间的窗口会删掉别人的锁
- 业务耗时不确定 → **看门狗自动续期**（每 TTL/3 续一次）
- **单实例方案的主从切换会丢锁**，这是固有缺陷
- **Redlock 有争议**，谨慎使用；真要强一致请上 **etcd / ZooKeeper**
- **很多场景根本不需要锁**：扣库存用 Lua 或 DB 乐观锁更好
- 锁的粒度要**按资源**分，别用全局锁

下一篇讲过期与淘汰策略——锁解决并发控制，
淘汰策略解决"内存满了怎么办"，两者都是 Redis 运维的必修课。
