# Python 生成器讲透：yield 到底做了什么

> 很多人用生成器只停留在"知道它省内存"，
> 但说不清 `yield` 执行时到底发生了什么、为什么 `next()` 一次就停住、
> 以及为什么生成器只能遍历一次。
>
> 本篇从**函数暂停/恢复**这个角度切入，把 yield、send、yield from
> 一次性讲清楚，最后给出几个真正用得上生成器的场景。

## 一、先看问题：列表撑爆内存

```python
def read_all(path):
    with open(path, encoding="utf-8") as f:
        return f.readlines()      # 一次性全部读进内存

lines = read_all("huge.log")      # 10 GB 的日志文件 → 内存直接爆炸
```

改成生成器：

```python
def read_lazy(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            yield line.rstrip("\n")

for line in read_lazy("huge.log"):   # 每次只在内存里放一行
    if "ERROR" in line:
        print(line)
```

区别不是"快一点"，是**从 O(n) 空间降到 O(1)**。
10 GB 文件用生成器处理，内存占用可以稳定在几 MB。

## 二、生成器函数的本质：不是函数，是工厂

这是最关键的一点，理解了它后面全通：

```python
def gen():
    print("开始")
    yield 1
    print("继续")
    yield 2
    print("结束")

g = gen()
print(type(g))       # <class 'generator'>
print(g)             # <generator object gen at 0x...>
```

注意：**调用 `gen()` 时，函数体一行都没执行**。
`"开始"` 没有被打印——因为函数里有 `yield`，
Python 就不把它当普通函数，而是**返回一个生成器对象**。

函数体要等 `next()` 才跑：

```python
g = gen()
next(g)     # 打印"开始"，返回 1，然后卡在 yield 1 这一行
next(g)     # 从上次卡住的地方继续，打印"继续"，返回 2
next(g)     # 打印"结束"，函数结束 → 抛 StopIteration
```

### 执行状态去哪了？

普通函数返回后，局部变量就没了。生成器凭什么记住执行到哪一行？
看这几个属性：

```python
def counter():
    i = 0
    while True:
        yield i
        i += 1

c = counter()
next(c); next(c); next(c)
print(c.gi_frame.f_locals)      # {'i': 3}   ← 局部变量活着
print(c.gi_frame.f_lasti)       # 当前执行到的字节码偏移量
```

**每个生成器对象都持有自己的一个栈帧（`gi_frame`）**。
局部变量和执行位置都存在这个帧里，所以能暂停也能恢复。
这也是生成器比列表**更耗内存 per-item** 的原因——每个生成器都要带一个帧。
数据量小的时候，列表反而更划算。

## 三、生成器协议：三个方法

生成器对象实现了迭代器协议，完整接口其实有四个：

| 方法 | 作用 |
|---|---|
| `__next__()` | 推进到下一个 yield |
| `send(value)` | 推进，**并把 value 作为 yield 表达式的值** |
| `throw(exc)` | 在暂停处抛出异常 |
| `close()` | 强制结束，内部抛 `GeneratorExit` |

### send：双向通信

`yield` 不只是"返回值"，它还是一个**表达式**，可以接收外面送进来的值：

```python
def accumulator():
    total = 0
    while True:
        x = yield total        # yield 右边是"送出去"，左边是"收进来"
        if x is None:
            break
        total += x

acc = accumulator()
next(acc)              # 必须先 next() 启动，让它跑到 yield 处（返回 0）
print(acc.send(10))    # 10   → total=0+10
print(acc.send(20))    # 30   → total=10+20
print(acc.send(5))     # 35
acc.close()
```

**为什么必须先 `next()`？** 因为第一个 `send()` 时生成器还没开始执行，
没有"正在等待的 yield" 来接收值。所以规则是：
**第一次必须 `send(None)`（等价于 `next()`）或用装饰器预激**。

```python
from functools import wraps

def primed(fn):                  # 预激装饰器，省得每次手动 next()
    @wraps(fn)
    def wrapper(*args, **kwargs):
        g = fn(*args, **kwargs)
        next(g)
        return g
    return wrapper

@primed
def accumulator(): ...

acc = accumulator()
print(acc.send(10))    # 直接用，不用先 next
```

## 四、yield from：委托给子生成器

手动遍历子生成器再逐个 yield 很啰嗦：

```python
def chain(*iterables):
    for it in iterables:
        for x in it:          # 两层循环
            yield x
```

`yield from` 一行搞定，而且**不只是省代码**：

```python
def chain(*iterables):
    for it in iterables:
        yield from it
```

它真正做的是**建立一条直通管道**：
`send()` 的值会直接送达子生成器，`throw()` 的异常也会传进去，
子生成器的 `return` 值会成为 `yield from` 表达式的值。

```python
def inner():
    x = yield "inner ready"
    return f"inner got {x}"

def outer():
    result = yield from inner()      # 接收子生成器的返回值
    print("inner 返回:", result)
    yield "outer done"

o = outer()
print(next(o))        # "inner ready"
print(o.send(42))     # 打印 "inner got 42"，然后返回 "outer done"
```

**这就是 `async/await` 的底层形态**——`await` 就是异步版的 `yield from`。
理解了 `yield from`，协程就没那么神秘了。

## 五、生成器表达式：惰性版的列表推导

```python
squares_list = [x*x for x in range(10)]      # 立刻算完，占内存
squares_gen  = (x*x for x in range(10))      # 惰性，几乎不占内存

print(sum(x*x for x in range(10)))           # 285，注意 sum() 里不用再加括号
```

⚠️ **惰性也意味着延迟求值，闭包陷阱会咬人**：

```python
funcs = [lambda: i for i in range(3)]        # 列表推导
print([f() for f in funcs])                  # [2, 2, 2]   ← 全是 2！

# 生成器表达式同样有这个问题
gen = (lambda: i for i in range(3))
print([f() for f in gen])                    # [2, 2, 2]
```

原因是 `i` 是**同一个变量**，lambda 只是引用它，调用时 `i` 已经变成 2 了。
解决：用默认参数固化

```python
funcs = [lambda i=i: i for i in range(3)]
print([f() for f in funcs])                  # [0, 1, 2]  ✅
```

## 六、itertools：生成器最搭的标准库

```python
from itertools import islice, chain, count, cycle, takewhile, groupby, tee

list(islice(count(0, 2), 5))          # [0, 2, 4, 6, 8]  从无限序列取 5 个
list(chain([1,2], "ab"))              # [1, 2, 'a', 'b']

# takewhile：按条件截断（遇到不满足的就停，不是过滤）
list(takewhile(lambda x: x < 5, [1, 3, 6, 2, 1]))   # [1, 3]  ← 6 之后就停了

# groupby：必须先排序才能正确分组（它只合并相邻的相同 key）
data = sorted([("a", 1), ("b", 2), ("a", 3)], key=lambda x: x[0])
for k, g in groupby(data, key=lambda x: x[0]):
    print(k, list(g))                 # a [('a',1),('a',3)]  b [('b',2)]

# tee：一个生成器复制成多个（注意：之后原生成器别再用了）
g = (x for x in range(5))
a, b = tee(g)
```

`groupby` 那个"必须先排序"的坑非常常见，不排序会得到重复的组。

## 七、管道式数据处理

生成器的最佳用法是**串成流水线**，每个环节只做一件事：

```python
def read_lines(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            yield line.rstrip()

def grep(iterable, pattern):
    for line in iterable:
        if pattern in line:
            yield line

def to_upper(iterable):
    for line in iterable:
        yield line.upper()

def take(iterable, n):
    for i, item in enumerate(iterable):
        if i >= n:
            break
        yield item

# 组装：读文件 → 过滤 ERROR → 转大写 → 取前 5 条
pipeline = take(to_upper(grep(read_lines("app.log"), "ERROR")), 5)
for line in pipeline:
    print(line)
```

这个写法的三个好处：

1. **内存恒定**——不管文件多大，同时只有一行在内存里
2. **惰性短路**——`take(5)` 拿到 5 条后，`break` 会让整个链条停止，
   不会读完整个文件
3. **可组合**——每个函数独立可测，随便调换顺序

## 八、生成器的四个坑

**坑 1：只能用一次**

```python
g = (x for x in range(3))
print(list(g))    # [0, 1, 2]
print(list(g))    # []   ← 耗尽了！
```

生成器是一次性的。需要多次遍历就转列表，
或者用 `itertools.tee`，或者干脆封装成函数每次重新调用。

**坑 2：过早耗尽**

```python
g = (x for x in range(10))
if 5 in g:                    # 这里把 g 消耗到 5 了
    print("有 5")
print(list(g))                # [6, 7, 8, 9]  ← 前面的没了！
```

`in`、`any()`、`all()`、`max()` 都会消耗生成器。

**坑 3：finally 不保证执行**

```python
def gen():
    try:
        yield 1
    finally:
        print("清理资源")     # 生成器被 GC 回收时才会执行

g = gen()
next(g)
del g                          # 打印"清理资源"（CPython 的 GC 触发）
```

如果生成器没被显式 `close()`，清理时机取决于 GC，**不确定**。
涉及资源释放（文件、连接）时，**显式 `close()` 或用 `contextlib.closing`**。
更推荐直接用 `with` + 上下文管理器（下一篇讲）。

**坑 4：生成器不是线程安全的**

同一个生成器对象不能在多个线程里同时 `next()`。
要并发就每个线程各自创建自己的生成器。

## 九、生成器 vs 列表：什么时候别用

生成器不是万能的，这几种情况老实用列表：

| 情况 | 原因 |
|---|---|
| 数据量很小（< 1000） | 列表更快，生成器要维护栈帧，有额外开销 |
| 需要多次遍历 | 生成器一次性 |
| 需要索引 / 切片 / len() | 生成器不支持 `g[0]`、`len(g)` |
| 需要随机访问 | 生成器只能顺序推进 |

```python
g = (x for x in range(10))
len(g)      # TypeError: object of type 'generator' has no len()
g[0]        # TypeError: 'generator' object is not subscriptable
```

## 十、小结

- **生成器函数返回的是生成器对象**，函数体要等 `next()` 才执行
- 暂停/恢复靠的是**每个生成器自带的栈帧**（`gi_frame`），局部变量因此活着
- `yield` 是**表达式**：右边送出去，左边收进来（`send()`）
- **第一次必须 `send(None)` / `next()`** 预激
- `yield from` 建立直通管道，是 `await` 的同步形态
- **生成器只能用一次**，`in` / `any()` / `max()` 都会消耗它
- 最佳用法是**串成流水线**：内存恒定、可短路、易组合
- 小数据量、要索引、要多次遍历——**用列表**

下一篇讲 asyncio。生成器解决了"函数能不能暂停"，
而协程要解决的是"**暂停的时候去干点别的**"——那是并发层面的事。
