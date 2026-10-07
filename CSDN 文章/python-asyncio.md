# Python asyncio 讲透：async/await、事件循环与并发陷阱

> asyncio 是 Python 里最容易被"会用但不懂"的东西：
> 很多人照着教程写出 `async def` + `await`，能跑就不管了，
> 直到某天发现**加了 async 反而更慢**，才意识到自己根本没并发起来。
>
> 本篇讲清楚事件循环怎么调度、什么时候真的并发、以及那些让人抓狂的报错。

## 一、先搞清楚 asyncio 解决什么问题

asyncio 解决的是 **I/O 密集型**的并发，不是 CPU 密集型。

对比三种模型处理"抓取 100 个网页"：

| 模型 | 做法 | 100 个请求耗时 | 代价 |
|---|---|---|---|
| 同步 | 一个一个抓 | 100 × T | 简单，但慢 |
| 多线程 | 开 100 个线程 | ≈ T | 线程开销、GIL、切换成本 |
| **asyncio** | 单线程 + 事件循环 | **≈ T** | 代码要改成 async 风格 |

asyncio 的核心思路：**等待 I/O 的时候不干等，去干别的**。

单线程怎么做到？靠的是——**I/O 操作本身不需要 CPU**。
发起网络请求后，CPU 唯一要做的就是"等"，
这段时间完全可以切去处理另一个请求。

## 二、协程：能暂停的函数

```python
import asyncio

async def say(what, delay):
    print(f"{what} 开始")
    await asyncio.sleep(delay)      # 让出控制权
    print(f"{what} 结束")
    return what

asyncio.run(say("A", 1))
```

三个关键点：

**1. `async def` 定义的是协程函数，调用它不会执行**

```python
coro = say("A", 1)      # 什么都没打印
print(type(coro))       # <class 'coroutine'>
# RuntimeWarning: coroutine 'say' was never awaited   ← 没被 await 就丢掉了
```

跟生成器一模一样：**调用只是创建对象，不执行**。

**2. `await` 是"让出控制权"的信号**

`await asyncio.sleep(1)` 的意思是：
"我要等 1 秒，这期间事件循环你可以去跑别的任务"。

**3. 只有 `await` 才会切换**

这是最重要也最容易搞错的一点：

```python
async def bad():
    time.sleep(1)        # ❌ 阻塞！整个事件循环卡死 1 秒
    return 1

async def good():
    await asyncio.sleep(1)   # ✅ 让出控制权，别的任务可以跑
    return 1
```

**在一个 async 函数里调用阻塞的同步代码，会让所有协程一起卡住。**
这是 "加了 async 反而更慢" 的头号原因。

## 三、事件循环怎么调度

```python
async def main():
    # create_task：把协程注册到事件循环，立刻开始调度
    t1 = asyncio.create_task(say("A", 2))
    t2 = asyncio.create_task(say("B", 1))

    r1 = await t1       # 等 A 完成
    r2 = await t2       # 等 B 完成
    return r1, r2

asyncio.run(main())
# A 开始
# B 开始
# B 结束      ← 1 秒后
# A 结束      ← 2 秒后
# 总共 2 秒，不是 3 秒
```

执行时序：

```
0s    task A 启动 → await sleep(2) → 挂起，让出
0s    task B 启动 → await sleep(1) → 挂起，让出
0s    事件循环：两个都在睡，我也没事干，等着
1s    B 的定时器到了 → 恢复 B → 打印"B 结束"
2s    A 的定时器到了 → 恢复 A → 打印"A 结束"
```

调度规则一句话：**事件循环单线程轮询，遇到 await 就切到下一个就绪的任务**。

### ❌ 常见错误：直接 await 两个协程

```python
async def wrong():
    await say("A", 2)      # 等 A 跑完
    await say("B", 1)      # 才启动 B
    # 总耗时 3 秒，完全串行！

async def right():
    await asyncio.gather(say("A", 2), say("B", 1))   # 并发，2 秒
```

`await coro` 是"等它做完"；
`create_task()` / `gather()` 才是"安排它去做"。
**不包 task 就没有并发。**

## 四、三个并发原语

### 4.1 gather：全部完成，保序返回

```python
results = await asyncio.gather(
    fetch("url1"), fetch("url2"), fetch("url3")
)
# 返回顺序 = 传入顺序，不是完成顺序
```

`return_exceptions=True` 很实用——**一个失败不影响其他**：

```python
results = await asyncio.gather(*tasks, return_exceptions=True)
for r in results:
    if isinstance(r, Exception):
        print("失败:", r)
```

不加的话，一个任务抛异常，`gather` 立刻抛出，
**其他任务仍在后台跑但结果被丢弃**——很容易造成"任务泄漏"。

### 4.2 as_completed：谁先完成处理谁

```python
for coro in asyncio.as_completed([fetch(u) for u in urls]):
    result = await coro
    print("拿到一个:", result)     # 按完成顺序，适合进度展示
```

### 4.3 Semaphore：限制并发数（爬虫必备）

```python
async def fetch_all(urls, limit=10):
    sem = asyncio.Semaphore(limit)

    async def limited(url):
        async with sem:            # 超过 limit 就在这排队
            return await fetch(url)

    return await asyncio.gather(*[limited(u) for u in urls])
```

不限制并发，一次性发 1000 个请求，
要么被对方限流封 IP，要么本地文件描述符耗尽。
**Semaphore 是 asyncio 里最该优先加的保護**。

## 五、在 async 里调用阻塞代码

现实问题：`requests`、某些数据库驱动、CPU 密集计算都是同步的，
直接在 async 函数里调用会卡死事件循环。

**解法：丢到线程池**

```python
import asyncio
from concurrent.futures import ThreadPoolExecutor

executor = ThreadPoolExecutor(max_workers=10)

async def fetch_sync_style(url):
    loop = asyncio.get_running_loop()
    # run_in_executor 把同步函数丢到线程里，返回一个可 await 的 future
    return await loop.run_in_executor(executor, requests.get, url)

async def main():
    return await asyncio.gather(*[fetch_sync_style(u) for u in urls])
```

CPU 密集的用 `ProcessPoolExecutor`（绕开 GIL）：

```python
from concurrent.futures import ProcessPoolExecutor

async def cpu_heavy(n):
    loop = asyncio.get_running_loop()
    with ProcessPoolExecutor() as pool:      # 进程池绕开 GIL
        return await loop.run_in_executor(pool, heavy_compute, n)
```

判断标准：

| 任务类型 | 怎么办 |
|---|---|
| 网络 I/O | 用 `aiohttp` / `httpx` 原生异步 |
| 同步库（requests 等） | `run_in_executor` + 线程池 |
| CPU 密集 | `run_in_executor` + 进程池 |
| 文件 I/O | 通常直接同步读就行（Linux 上没有真正的异步文件 I/O） |

## 六、超时与取消

### 超时

```python
try:
    result = await asyncio.wait_for(fetch(url), timeout=3.0)
except asyncio.TimeoutError:
    print("超时了")
```

⚠️ `wait_for` 超时后会**取消**任务。如果任务持有资源，
取消可能来不及清理。要更精细的控制用 `asyncio.timeout`（3.11+）：

```python
async with asyncio.timeout(3.0):        # 3.11+ 推荐写法
    result = await fetch(url)
```

### 取消的坑

```python
async def worker():
    try:
        await asyncio.sleep(100)
    except asyncio.CancelledError:
        print("被取消了，清理资源")
        raise          # ← 必须重新抛出！吞掉会导致取消失效
```

**`CancelledError` 捕获后必须重新 raise**，否则 Task 会认为取消失败，
`wait_for` / `gather` 的取消语义全部失效。

另外：`asyncio.shield()` 可以保护任务不被取消——
但要注意，被 shield 的任务**仍在后台继续跑**，外部只是不等它了。

## 七、Debug 模式：定位"卡住了"

```python
import asyncio, logging

logging.basicConfig(level=logging.DEBUG)     # 打开 asyncio 的日志
asyncio.run(main(), debug=True)              # 3.10+ 支持
```

Debug 模式会报出：
- 协程**从未被 await**（`never awaited` 警告）
- 慢回调（执行超过 100ms 的回调，通常是误用了阻塞代码）

```python
# 找出所有还没结束的任务
tasks = asyncio.all_tasks()
print([t.get_name() for t in tasks if not t.done()])
```

`asyncio.all_tasks()` 在排查"程序为什么不退出"时非常有用——
通常是某个 task 卡在 I/O 上没人管。

## 八、六个高频错误

### 错误 1：RuntimeError: no running event loop

```python
asyncio.run(fetch(url))     # ❌ 在已经跑着循环的地方调用
```

`asyncio.run()` 是**给程序入口用的**，一个程序只能调一次。
在 async 函数里直接用 `await`。

### 错误 2：协程从未被 await

```python
async def main():
    fetch(url)          # ❌ 忘了 await，什么都不会发生
    asyncio.create_task(fetch(url))   # ⚠️ 创建了但没 await，main 结束就没了
```

第一种完全不执行；第二种**可能执行到一半被取消**。
`create_task` 之后一定要 `await` 或 `gather`。

### 错误 3：在同步函数里 await

```python
def handler():
    result = await fetch(url)     # SyntaxError: 'await' outside function
```

`await` 只能在 `async def` 里用。整个调用链都得是 async——
**async 具有传染性**，这也是它最大的改造成本。

### 错误 4：asyncio.run 在 Jupyter 里报错

Jupyter 已经有一个事件循环在跑，`asyncio.run()` 会冲突。
在 notebook 里直接 `await fetch(url)` 即可（顶层 await）。

### 错误 5：混用 time.sleep

```python
await asyncio.sleep(1)    # ✅
time.sleep(1)             # ❌ 卡死整个循环
```

同理：`requests` ❌ → `aiohttp` ✅。

### 错误 6：全局变量被并发修改

```python
counter = 0

async def inc():
    global counter
    tmp = counter
    await asyncio.sleep(0)     # 这里会让出控制权！
    counter = tmp + 1

await asyncio.gather(*[inc() for _ in range(100)])
print(counter)   # 可能是 1，不是 100
```

虽然 asyncio 是单线程，但 **await 点就是切换点**，
照样有竞态。需要共享状态就用 `asyncio.Lock`：

```python
lock = asyncio.Lock()

async def inc():
    global counter
    async with lock:
        tmp = counter
        await asyncio.sleep(0)
        counter = tmp + 1
```

## 九、什么时候不该用 asyncio

老实说，**多数业务代码不需要 asyncio**。

**不用的情况**：
- 请求量很小（QPS < 10），同步代码完全够
- 团队不熟悉，改造成本高于收益
- 依赖大量同步库，改造会牵一发动全身
- 主要是 CPU 密集计算（asyncio 帮不上忙，反而增加复杂度）

**该用的情况**：
- 单个进程要维持成百上千个并发连接（WebSocket 推送、长连接网关）
- 大量并发的外部 API 调用（聚合服务、爬虫）
- 已经是 FastAPI / aiohttp 技术栈

## 十、小结

- asyncio 解决的是 **I/O 密集型**并发，CPU 密集请用多进程
- `async def` **调用不执行**，要 `await` 或 `create_task`
- **只有 `await` 才切换**——用 `time.sleep` / `requests` 会让整个循环卡死
- `await coro` 是串行；**`gather` / `create_task` 才有并发**
- 并发一定要加 **`Semaphore`** 限流
- 阻塞代码用 `run_in_executor` 丢线程池/进程池
- `CancelledError` 捕获后**必须重新 raise**
- 单线程也有竞态，共享状态要 `asyncio.Lock`
- **多数场景不需要 asyncio**，别为了用而用

下一篇讲 GIL 和并发选型——asyncio 只是三种并发模型之一，
到底什么时候用线程、什么时候用进程、什么时候用协程，需要一张完整的决策图。
