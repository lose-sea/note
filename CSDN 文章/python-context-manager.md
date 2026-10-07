# Python 上下文管理器讲透：with 语句与 contextlib

> `with open(...) as f:` 谁都会写，但多数人不知道它为什么能保证关闭文件，
> 也不知道自己怎么写一个。
>
> 本篇从 `__enter__` / `__exit__` 协议讲起，
> 覆盖类实现、`contextmanager` 装饰器、以及 `contextlib` 里那堆好用的工具，
> 最后给出几个生产环境真正会用到的场景。

## 一、为什么需要 with

先看不用 `with` 的写法有什么问题：

```python
f = open("data.txt")
data = f.read()        # 如果这里抛异常...
f.close()              # ← 永远执行不到，文件句柄泄漏
```

`try/finally` 能解决：

```python
f = open("data.txt")
try:
    data = f.read()
finally:
    f.close()          # ✅ 一定会执行
```

但每个资源都要写一遍 `try/finally` 太啰嗦。
`with` 就是把这个模式**语法化**：

```python
with open("data.txt") as f:
    data = f.read()
# 出了这个缩进，文件一定被关闭——不管有没有异常
```

**核心价值：保证清理代码一定执行。**
这是资源管理问题的通用解，不只是文件。

## 二、协议：只有两个方法

任何实现了 `__enter__` 和 `__exit__` 的对象都是上下文管理器。

```python
class Managed:
    def __enter__(self):
        print("进入：获取资源")
        return self          # 这个返回值会赋给 as 后的变量

    def __exit__(self, exc_type, exc_val, exc_tb):
        print("退出：释放资源")
        return False         # False = 不吞异常（让异常继续往外抛）
```

`with` 的执行顺序：

```python
with Managed() as m:
    print("干活")
# 输出顺序：
# 进入：获取资源
# 干活
# 退出：释放资源
```

即使 with 块里抛异常，`__exit__` **依然会执行**：

```python
with Managed() as m:
    raise ValueError("出错了")
# 进入：获取资源
# 退出：释放资源        ← 依然执行了
# ValueError: 出错了    ← 异常照常抛出
```

### `__exit__` 的三个参数

```python
def __exit__(self, exc_type, exc_val, exc_tb):
    # exc_type：异常类（没异常时是 None）
    # exc_val ：异常实例
    # exc_tb  ：traceback 对象
    print(exc_type, exc_val)
```

**返回值决定异常是否被吞掉**：

```python
class Suppress:
    def __enter__(self): return self
    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is ValueError:
            print("ValueError 我吞了")
            return True       # ← True 表示"已处理"，异常不再往外抛
        return False          # 其他异常照常抛

with Suppress():
    raise ValueError("这个不会冒出去")
print("程序继续")    # ✅ 能执行到这里
```

**经验法则：默认 `return False`（或不写 return）**。
吞异常要非常小心，只在明确知道怎么处理时才吞。

## 三、写一个真实可用的：数据库事务

这是上下文管理器最经典的应用：

```python
import sqlite3

class Transaction:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        self.conn.execute("BEGIN")
        return self.conn.cursor()

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is None:
            self.conn.commit()      # 没异常 → 提交
            print("事务已提交")
        else:
            self.conn.rollback()    # 有异常 → 回滚
            print("事务已回滚", exc_val)
        return False                # 异常继续往外抛

conn = sqlite3.connect(":memory:")
conn.execute("CREATE TABLE t (id INTEGER, name TEXT)")

with Transaction(conn) as cur:
    cur.execute("INSERT INTO t VALUES (1, 'a')")
    cur.execute("INSERT INTO t VALUES (2, 'b')")
# 事务已提交

with Transaction(conn) as cur:
    cur.execute("INSERT INTO t VALUES (3, 'c')")
    raise RuntimeError("中途炸了")
# 事务已回滚 RuntimeError('中途炸了')
print(conn.execute("SELECT COUNT(*) FROM t").fetchone())   # (2,)  ← 只有 2 条
```

这个模式的价值：**提交/回滚的逻辑写一次，所有业务代码都能用**，
而且不可能忘记——因为 `with` 语法强制你待在块里。

## 四、更简单的写法：@contextmanager

用类写要定义两个方法，有点重。`contextlib` 提供了生成器版本：

```python
from contextlib import contextmanager

@contextmanager
def transaction(conn):
    conn.execute("BEGIN")
    try:
        yield conn.cursor()      # ← yield 处就是 with 块执行的地方
    except Exception:
        conn.rollback()
        raise                    # 别吞异常
    else:
        conn.commit()

with transaction(conn) as cur:
    cur.execute("INSERT INTO t VALUES (4, 'd')")
```

对应关系非常清楚：

| 类写法 | 装饰器写法 |
|---|---|
| `__enter__` 的内容 | `yield` **之前**的代码 |
| `yield` 的值 = as 的变量 | `yield xxx` |
| `__exit__` 的内容 | `yield` **之后**的代码（放在 `finally`/`except` 里） |

**必须用 try/finally 保证清理执行**：

```python
@contextmanager
def managed_resource():
    print("获取")
    try:
        yield "资源"
    finally:
        print("释放")        # finally 保证异常时也执行
```

不写 `try/finally` 的话，with 块里抛异常时 `yield` 之后的代码**不会执行**——
这是 `@contextmanager` 的头号坑。

### 两种写法怎么选

- **简单、一次性** → `@contextmanager`（代码少一半）
- **需要状态、需要复用、要被继承** → 类
- **需要多次进入同一个 with** → 类（生成器版的上下文管理器通常只能用一次）

## 五、contextlib 工具箱

### 5.1 suppress：替代 try/except/pass

```python
import os
from contextlib import suppress

# 之前
try:
    os.remove("temp.txt")
except FileNotFoundError:
    pass

# 现在
with suppress(FileNotFoundError):
    os.remove("temp.txt")
```

干净得多。**但只用于"明确知道要忽略"的异常**，别用来掩盖 bug。

### 5.2 redirect_stdout：捕获输出

```python
import io
from contextlib import redirect_stdout

buf = io.StringIO()
with redirect_stdout(buf):
    print("这行不会打印到控制台")
print("捕获到:", buf.getvalue())    # 捕获到: 这行不会打印到控制台
```

测试老代码、调用第三方库时很有用。

### 5.3 ExitStack：动态数量的上下文

需求：同时打开**数量不定**的多个文件。

```python
from contextlib import ExitStack

def read_all(paths):
    with ExitStack() as stack:
        files = [stack.enter_context(open(p, encoding="utf-8")) for p in paths]
        return [f.read() for f in files]
```

`ExitStack` 会按**相反顺序**依次退出所有注册的上下文。
不用它的话，你得手写嵌套的 with，而数量不确定时根本写不出来。

```python
# ExitStack 还能动态决定是否注册
with ExitStack() as stack:
    if debug:
        stack.enter_context(redirect_stdout(log_file))
    if use_temp_dir:
        stack.enter_context(TemporaryDirectory())
    do_work()
```

### 5.4 nullcontext：条件性上下文

```python
from contextlib import nullcontext

def process(data, lock=None):
    # 有锁就用锁，没锁就用空上下文——代码不用写两遍
    with lock or nullcontext():
        do_something(data)
```

### 5.5 closing：给没有 with 的对象兜底

```python
from contextlib import closing
import urllib.request

with closing(urllib.request.urlopen("https://example.com")) as page:
    print(page.read()[:100])
```

对那些只有 `.close()` 但没实现上下文协议的老对象很有用。
生成器也适用——前面讲过，生成器的 `finally` 需要 `close()` 才可靠触发。

## 六、async 版本

异步代码要用 `async with`：

```python
import asyncio

class AsyncResource:
    async def __aenter__(self):
        print("异步获取")
        await asyncio.sleep(0.1)
        return self
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        print("异步释放")
        await asyncio.sleep(0.1)
        return False

async def main():
    async with AsyncResource() as r:
        print("干活")

asyncio.run(main())
```

方法名是 **`__aenter__`** / **`__aexit__`**（多了个 a），
且都必须是 `async def`。

```python
# 生成器版
from contextlib import asynccontextmanager

@asynccontextmanager
async def async_transaction(conn):
    await conn.execute("BEGIN")
    try:
        yield conn
    except Exception:
        await conn.rollback(); raise
    else:
        await conn.commit()
```

`aiohttp`、`asyncpg`、`aiomysql` 都是这么设计的。

⚠️ **同步的 `with` 不能用在异步上下文管理器上**，反之亦然。
混用会报 `TypeError`。

## 七、四个生产场景

### 1. 计时

```python
import time
from contextlib import contextmanager

@contextmanager
def timer(name="block"):
    t0 = time.perf_counter()
    try:
        yield
    finally:
        print(f"{name} 耗时 {time.perf_counter()-t0:.4f}s")

with timer("数据库查询"):
    query()
```

### 2. 临时改变工作目录

```python
import os
from contextlib import contextmanager

@contextmanager
def chdir(path):
    old = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(old)      # 一定切回去

with chdir("/tmp"):
    ...
print(os.getcwd())    # 回到原目录
```

### 3. 临时环境变量

```python
import os
from contextlib import contextmanager

@contextmanager
def env(**kwargs):
    old = {k: os.environ.get(k) for k in kwargs}
    os.environ.update(kwargs)
    try:
        yield
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

with env(DEBUG="1", API_KEY="test"):
    run()
```

写测试时非常常用。

### 4. 临时打补丁（unittest.mock 内置）

```python
from unittest.mock import patch

def get_user(): return real_db_query()

with patch("__main__.real_db_query", return_value={"name": "fake"}):
    print(get_user())     # {'name': 'fake'}
```

## 八、四个常见坑

**坑 1：`@contextmanager` 忘记 try/finally**

```python
@contextmanager
def bad():
    print("获取")
    yield
    print("释放")      # ❌ with 块抛异常时这行不执行
```

**坑 2：上下文管理器被复用**

```python
@contextmanager
def once():
    yield 1

cm = once()
with cm: pass
with cm: pass      # RuntimeError: generator didn't yield
```

`@contextmanager` 生成的**只能用一次**。
要复用就写成类，或者每次重新调用函数。

**坑 3：`__exit__` 返回 True 吞掉了异常**

```python
def __exit__(self, *exc):
    return True     # ❌ 所有异常都被静默吞掉，bug 查不到
```

只在你确实处理了的异常上返回 True。

**坑 4：with 里 return，清理还执行吗？**

```python
@contextmanager
def cm():
    print("in")
    try:
        yield
    finally:
        print("out")

def f():
    with cm():
        return 1
f()
# in
# out      ← 依然执行！finally 在 return 之前跑
print(f())  # 输出 in / out / 1
```

**执行，这是 finally 的语义保证**，不用担心。

## 九、小结

- `with` 的本质是 **`try/finally` 的语法糖**，保证清理代码一定执行
- 协议只有两个方法：**`__enter__`**（返回值给 as）、**`__exit__`**（三个异常参数）
- `__exit__` 返回 **True 才吞异常**，默认别返回 True
- `@contextmanager` 用生成器写：`yield` 前 = enter，`yield` 后 = exit，
  **必须用 try/finally**
- 类写法用于复用/有状态，装饰器写法用于一次性场景
- `ExitStack` 处理**数量不定**的上下文，`suppress` 替代 `except: pass`
- 异步版本是 **`async with` + `__aenter__` / `__aexit__`**
- 典型场景：**事务、计时、临时改目录/环境变量、锁、测试打补丁**

到这里 Python 进阶六篇就写完了：装饰器、生成器、asyncio、GIL 并发、
魔术方法、上下文管理器。这六块是所有 AI 工程代码的底层功底——
LangChain 用装饰器注册工具，异步框架靠协程和上下文管理器管理连接，
理解它们才能真正读懂源码而不是只会调 API。
