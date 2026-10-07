# Python GIL 与并发选型：线程、进程、协程到底怎么选

> "Python 的多线程是假的"——这句话对了一半。
> 本篇把 GIL 到底是什么、它真的影响什么、以及
> **什么时候用线程 / 进程 / 协程**的决策路径讲清楚，
> 附带可以直接抄的并发模板。

## 一、GIL 是什么

GIL（Global Interpreter Lock，全局解释器锁）是 **CPython 解释器**的一把互斥锁。
它的规则很简单：

> **任意时刻，只有一个线程能执行 Python 字节码。**

注意三个限定词：**CPython**（Jython、IronPython 没有 GIL）、
**字节码**（不是机器码）、**一个**。

### 为什么要有 GIL

不是设计失误，是**权衡的结果**。

CPython 的内存管理用**引用计数**：每个对象记着有多少人引用它，
归零就释放。这个计数器不是线程安全的——如果两个线程同时给同一个对象
加引用，`refcount` 可能算错，导致内存泄漏或者提前释放（野指针）。

最朴素的解决办法是给每个对象都加锁，但那样：
- 单线程性能大幅下降（每次引用计数都要加解锁）
- 容易出现死锁（多个对象互相引用）

GIL 的做法是**只加一把大锁**：简单、单线程性能无损、
不会死锁。代价就是多核 CPU 上，**Python 线程无法真正并行执行字节码**。

1990 年代做这个决定的时候多核还是稀罕物，这个权衡很合理。
现在成了历史包袱。

### GIL 什么时候释放

关键：**GIL 不是一直握着的**。

1. **执行 N 个字节码后释放**（默认 `sys.getswitchinterval()` = 5ms）
2. **遇到 I/O 操作时释放**（文件读写、网络收发、sleep）
3. **执行 C 扩展中的耗时操作时释放**（NumPy 的矩阵运算会主动释放）

第 2 条是重点：**I/O 期间 GIL 是放开的**。
所以多线程处理 I/O 任务依然能提速——线程们大部分时间在等 I/O，
而不是在抢 GIL。

## 二、实测：三种任务的表现

写段代码实测，比讲理论有说服力。

```python
import threading, multiprocessing, time

# ---------- 任务 A：CPU 密集 ----------
def cpu_task(n=30_000_000):
    while n: n -= 1

# ---------- 任务 B：I/O 密集 ----------
def io_task():
    time.sleep(0.5)

def run(fn, worker, n=4):
    t0 = time.perf_counter()
    ts = [worker(target=fn) for _ in range(n)]
    [t.start() for t in ts]; [t.join() for t in ts]
    return time.perf_counter() - t0

if __name__ == "__main__":
    print(f"CPU 密集 单线程: {cpu_task.__call__ and 0 or 0}")  # 占位
    print(f"CPU 密集 4 线程: {run(cpu_task, threading.Thread):.2f}s")
    print(f"CPU 密集 4 进程: {run(cpu_task, multiprocessing.Process):.2f}s")
    print(f"I/O  密集 4 线程: {run(io_task, threading.Thread):.2f}s")
```

在一台 8 核机器上的典型结果：

| 任务 | 串行 | 4 线程 | 4 进程 |
|---|---|---|---|
| CPU 密集（纯计算） | 3.0s | **3.2s**（更慢！） | **0.9s** |
| I/O 密集（sleep） | 2.0s | **0.5s** | 0.6s |

结论非常清晰：

- **CPU 密集：线程不仅没用，还因为切换开销变慢了**
- **I/O 密集：线程效果好，接近线性加速**

## 三、决策图：到底用什么

```
                    你的任务是什么类型？
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
    CPU 密集            I/O 密集            混合
  （计算/图像处理）    （网络/磁盘/DB）          │
        │                   │                   │
        │                   │          拆分：计算走进程，
   multiprocessing    并发量大吗？         I/O 走线程/协程
   / ProcessPool          │
        │         ┌───────┴───────┐
        │         │               │
        │      < 1000 并发     >= 1000 并发
        │         │               │
        │    threading        asyncio
        │    (简单够用)      (必须上协程)
        │
   CPU 密集 + 需要共享大量数据？
   → 考虑 numpy/PyTorch（它们在 C 层释放 GIL）
```

一句话总结：

| 场景 | 方案 |
|---|---|
| CPU 密集 | **多进程** `ProcessPoolExecutor` |
| I/O 密集，并发量小 | **多线程** `ThreadPoolExecutor` |
| I/O 密集，并发量大 | **协程** `asyncio` |
| 数值计算 | **直接用 NumPy**（C 层已释放 GIL） |
| 简单跑个后台任务 | 单线程 + 队列就够了 |

## 四、多进程：CPU 密集的正解

### 4.1 ProcessPoolExecutor（推荐）

```python
from concurrent.futures import ProcessPoolExecutor, as_completed

def heavy(n):
    return sum(i*i for i in range(n))

if __name__ == "__main__":          # Windows 上必须有这一行！
    with ProcessPoolExecutor(max_workers=4) as pool:
        # 方式一：map（保序）
        for r in pool.map(heavy, [10_000_000]*4):
            print(r)

        # 方式二：submit + as_completed（谁先完处理谁）
        futs = [pool.submit(heavy, n) for n in [10_000_000]*4]
        for f in as_completed(futs):
            print(f.result())
```

⚠️ **`if __name__ == "__main__":` 在 Windows 上是强制的**。
因为 Windows 用 `spawn` 启动子进程，会重新 import 主模块，
不保护的话会无限递归创建进程。这是 Windows 上最常见的坑。

### 4.2 进程间通信

进程有独立内存空间，**全局变量不共享**：

```python
counter = 0

def inc():
    global counter
    counter += 1        # 每个进程改的是自己的副本！

# 结果：4 个进程跑完 counter 还是 0
```

要共享得显式用 `Manager` 或 `Value`：

```python
from multiprocessing import Process, Value, Lock

def worker(counter, lock):
    for _ in range(1000):
        with lock:                  # ❗必须加锁，Value 默认不加锁
            counter.value += 1

if __name__ == "__main__":
    counter = Value("i", 0)         # 'i' 表示 int
    lock = Lock()
    ps = [Process(target=worker, args=(counter, lock)) for _ in range(4)]
    [p.start() for p in ps]; [p.join() for p in ps]
    print(counter.value)            # 4000  ✅
```

注意 `Value` 默认**不带锁**，`counter.value += 1` 不是原子操作，
必须配 `Lock`。或者直接用 `multiprocessing.Value` 的 `lock=True` 参数。

**更推荐的做法**：用 `Queue` 传数据，让父进程汇总，
避免共享状态。共享状态是万恶之源。

```python
from multiprocessing import Process, Queue

def worker(q, n):
    q.put(heavy(n))          # 结果放队列

if __name__ == "__main__":
    q = Queue()
    ps = [Process(target=worker, args=(q, n)) for n in [1_000_000]*4]
    [p.start() for p in ps]
    results = [q.get() for _ in ps]      # 父进程汇总
    [p.join() for p in ps]
```

### 4.3 多进程的代价

- **启动开销大**：fork/spawn 一个进程几毫秒到几十毫秒，比线程重 100 倍
- **内存占用高**：每个进程一份独立内存，4 进程就是 4 倍
- **序列化成本**：传参和返回值都要 pickle，大对象传输很慢
- **不能传不可 pickle 的对象**：lambda、文件句柄、数据库连接都不行

所以**任务太小就别用多进程**，进程启动开销可能比计算本身还大。

## 五、多线程：I/O 密集的正解

```python
from concurrent.futures import ThreadPoolExecutor
import requests

URLS = ["https://example.com"] * 20

def fetch(url):
    return requests.get(url, timeout=5).status_code

with ThreadPoolExecutor(max_workers=10) as pool:
    for url, code in zip(URLS, pool.map(fetch, URLS)):
        print(url, code)
```

线程的两个优势：**共享内存（不用序列化）**、**启动快**。

### 5.1 线程安全

虽然是 I/O 场景，但**共享可变状态仍要加锁**：

```python
import threading

counter = 0
lock = threading.Lock()

def inc():
    global counter
    for _ in range(100_000):
        with lock:             # 不加锁结果会小于预期
            counter += 1
```

⚠️ 注意：`counter += 1` 在字节码层面是**读-改-写三步**，
即使有 GIL，线程也可能在这三步之间被切走。所以 **GIL 不能替代锁**。

### 5.2 该开多少线程

经验公式：**I/O 密集型线程数 = CPU 核数 × (1 + 等待时间/计算时间)**。

简单场景：
- 纯 I/O（几乎不计算）：核数 × 5 ~ 10，或者干脆直接设 20~50
- 混合型：核数 × 2

太多线程会导致上下文切换开销反超收益。

### 5.3 常见线程工具

```python
from threading import Thread, Lock, Event, Condition, local

# Event：一个线程通知另一个"可以开始了"
ready = Event()
def worker():
    ready.wait()            # 阻塞直到 ready.set()
    print("开始干活")
ready.set()

# Thread-local：每个线程独立的变量（Flask/Django 的 request 就这么存）
tls = local()
tls.user = "Tom"            # 只在当前线程可见

# 定时任务
import threading
timer = threading.Timer(5.0, lambda: print("5秒后执行"))
timer.start()
```

## 六、绕开 GIL 的三条路

### 6.1 用 C 扩展（NumPy / PyTorch）

NumPy 的矩阵运算在 C 层实现，**执行前释放 GIL**：

```python
import numpy as np
# 这个运算期间 GIL 是放开的，多线程能真正并行
a = np.random.rand(5000, 5000)
b = np.random.rand(5000, 5000)
c = a @ b
```

所以**数值计算不要自己写 Python 循环**，用 NumPy 向量化——
它既快又能绕开 GIL。

### 6.2 用无 GIL 的实现

- **PyPy**：JIT 编译快，但仍有 GIL
- **Jython / IronPython**：无 GIL，但生态滞后
- **PEP 703（nogil）**：CPython 官方的可选无 GIL 构建，
  Python 3.13 开始提供实验性的 `--disable-gil` 编译选项

现状：**短期内生产环境还是按"有 GIL"来设计**。

### 6.3 把计算丢给外部服务

最省事的路：Celery + Redis 做分布式任务队列，
重计算丢给 worker 集群。这其实是生产环境最常见的做法。

## 七、一个混合场景的完整例子

需求：下载 100 张图片，对每张做 CPU 密集的图像处理。

```python
from concurrent.futures import ThreadPoolExecutor, ProcessPoolExecutor
import requests

def download(url):                    # I/O 密集
    return requests.get(url, timeout=10).content

def process(data):                    # CPU 密集
    # 假设这是 PIL 的耗时操作
    return len(data)

def pipeline(urls):
    with ThreadPoolExecutor(max_workers=20) as io_pool:      # I/O 用线程
        images = list(io_pool.map(download, urls))

    with ProcessPoolExecutor(max_workers=4) as cpu_pool:     # CPU 用进程
        results = list(cpu_pool.map(process, images, chunksize=10))

    return results
```

`chunksize` 是个实用的优化：
**把任务分批提交，减少进程间通信次数**。
任务多且每个很小时，设 `chunksize` 能显著提速。

## 八、四个常见误区

**误区 1：多线程能加速所有任务** — 错，CPU 密集反而更慢。

**误区 2：有 GIL 就不用锁** — 错，`x += 1` 不是原子操作。

**误区 3：多进程一定比多线程快** — 错，进程启动和序列化开销很大，
小任务用进程是负优化。

**误区 4：asyncio 能加速 CPU 计算** — 错，asyncio 是单线程，
CPU 密集用它会让整个循环卡死。

## 九、小结

- GIL 是 **CPython 的一把大锁**，保证引用计数安全，代价是字节码无法并行
- **GIL 在 I/O 期间会释放**，所以多线程对 I/O 任务依然有效
- **CPU 密集 → 多进程；I/O 密集小并发 → 多线程；I/O 大并发 → asyncio**
- Windows 上多进程**必须** `if __name__ == "__main__":`
- 进程间**不共享内存**，共享要 `Value` + `Lock`，更推荐 `Queue` 传数据
- **GIL 不能替代锁**，`x += 1` 仍需 `Lock`
- 数值计算用 **NumPy**，C 层已经释放 GIL

下一篇讲魔术方法——并发是"怎么同时做多件事"，
魔术方法是"怎么让你自己的类像内置类型一样好用"，
两者都是写出专业 Python 代码的必备功底。
