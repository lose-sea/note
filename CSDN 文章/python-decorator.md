# Python 装饰器讲透：从闭包到带参数的装饰器

> 装饰器是 Python 面试的必考题，也是很多人"背八股但不知道怎么用"的重灾区。
> 本篇不背结论，从**闭包**这一根基推上去，把装饰器到底是个什么东西、
> 为什么需要 `@wraps`、带参数的装饰器为什么多套一层，一次性讲明白。

## 一、前置：函数是对象

装饰器的全部魔法都建立在一件事上：**Python 里函数是一等对象**。

```python
def greet(name):
    return f"hi, {name}"

f = greet              # 函数可以赋值给变量（注意没加括号）
print(f("Tom"))        # hi, Tom

def call_twice(fn, arg):
    return fn(arg) + " " + fn(arg)

print(call_twice(greet, "Tom"))   # hi, Tom hi, Tom
```

函数能**当参数传进去**、能**当返回值传出来**，装饰器才有可能存在。
如果函数不能当返回值，你就没法"返回一个改造过的新函数"。

## 二、闭包：装饰器真正的地基

闭包 = **函数 + 它引用的外部变量**。看这个例子：

```python
def make_multiplier(n):
    def multiplier(x):
        return x * n          # n 来自外层作用域
    return multiplier

times3 = make_multiplier(3)
times10 = make_multiplier(10)

print(times3(5))    # 15
print(times10(5))   # 50
```

关键点：`make_multiplier(3)` 返回之后，它的局部作用域**按理说应该销毁了**，
但 `multiplier` 还记着 `n=3`。这就是闭包——**内层函数记住了定义它时的环境**。

用两个 dunder 属性可以验证：

```python
print(times3.__closure__)                    # (<cell at 0x...: int object at 0x...>,)
print(times3.__closure__[0].cell_contents)   # 3
print(times3.__name__)                       # 'multiplier'
```

记住最后一行：`times3.__name__` 是 `multiplier` **而不是 `times3`**。
这个细节后面会咬人。

## 三、手写第一个装饰器

需求：给函数加日志，调用前后各打一行，但**不修改原函数代码**。

```python
def log_call(func):                 # 1. 接收一个函数
    def wrapper(*args, **kwargs):   # 2. 定义一个新函数包住它
        print(f"[LOG] 调用 {func.__name__}，参数 {args}")
        result = func(*args, **kwargs)      # 3. 真正调用原函数
        print(f"[LOG] {func.__name__} 返回 {result!r}")
        return result                        # 4. 把结果原样还回去
    return wrapper                           # 5. 返回新函数

def add(a, b):
    return a + b

add = log_call(add)      # 手动装饰
print(add(1, 2))
# [LOG] 调用 add，参数 (1, 2)
# [LOG] add 返回 3
# 3
```

把这五行拆开看：

- `log_call(func)` 是**装饰器函数**，输入函数，输出函数
- `wrapper(*args, **kwargs)` 用不定参数是为了**适配任意签名的被装饰函数**
- `return wrapper` 而不是 `return wrapper()`——返回函数对象本身，不是调用它
- `result = func(...)` / `return result`：**必须透传返回值**，
  否则被装饰的函数会永远返回 `None`，这是新手第一大坑

`@` 语法糖只是把 `add = log_call(add)` 换个写法：

```python
@log_call
def add(a, b):
    return a + b
```

**`@log_call` 完全等价于 `add = log_call(add)`**，没有任何额外魔法。

## 四、丢失的元信息：为什么必须用 @wraps

装饰之后，`add` 已经不是原来的 `add` 了：

```python
@log_call
def add(a, b):
    """两数相加"""
    return a + b

print(add.__name__)   # 'wrapper'   ← 不是 'add'！
print(add.__doc__)    # None        ← 文档丢了！
```

这不只是"看着别扭"，而是**会造成真实故障**：

1. `help(add)` 显示错误信息
2. 日志里打出来的函数名全是 `wrapper`，线上排查时一脸懵
3. **依赖 `__name__` 的框架会失效**——Flask 用函数名注册路由，
   两个视图函数都变成 `wrapper` 就会报 "View function name is not unique"

解决办法是 `functools.wraps`：

```python
from functools import wraps

def log_call(func):
    @wraps(func)                    # ← 加上这一行
    def wrapper(*args, **kwargs):
        print(f"[LOG] 调用 {func.__name__}")
        return func(*args, **kwargs)
    return wrapper

@log_call
def add(a, b):
    """两数相加"""
    return a + b

print(add.__name__)   # 'add'  ✅
print(add.__doc__)    # '两数相加'  ✅
```

`@wraps(func)` 做的事本质上是把 `func` 的
`__name__`、`__doc__`、`__module__`、`__qualname__`、`__dict__`
拷贝到 `wrapper` 上。**写装饰器就养成条件反射：加 `@wraps`。**

## 五、带参数的装饰器：为什么要多套一层

需求变了：希望日志能带级别，`@log_call(level="WARN")`。

先看错误写法：

```python
def log_call(func, level):    # ❌ 装饰器只能接收一个参数：被装饰的函数
    ...
```

`@log_call(level="WARN")` 会被 Python 解释成：
**先调用 `log_call(level="WARN")` 得到一个装饰器，再用这个装饰器去装饰函数**。
所以 `log_call` 必须**返回一个装饰器**，于是多一层：

```python
from functools import wraps

def log_call(level="INFO"):        # 第 1 层：接收装饰器自己的参数
    def decorator(func):           # 第 2 层：真正的装饰器，接收函数
        @wraps(func)
        def wrapper(*args, **kwargs):    # 第 3 层：包装执行
            print(f"[{level}] 调用 {func.__name__}")
            return func(*args, **kwargs)
        return wrapper
    return decorator

@log_call(level="WARN")
def risky():
    print("执行危险操作")

risky()
# [WARN] 调用 risky
# 执行危险操作
```

执行顺序理一遍：

```python
@log_call(level="WARN")
def risky(): ...

# 等价于：
# _dec = log_call(level="WARN")    → 返回 decorator
# risky = _dec(risky)              → 返回 wrapper
```

**记忆口诀**：不带参数的装饰器 2 层，带参数的 3 层。
第 1 层永远只吃"装饰器自己的参数"。

## 六、类装饰器：带状态的场景

装饰器需要**记住状态**（比如调用次数）时，用类更自然：

```python
from functools import wraps

class CountCalls:
    def __init__(self, func):
        wraps(func)(self)          # 类装饰器里手动做 wraps
        self.func = func
        self.count = 0

    def __call__(self, *args, **kwargs):
        self.count += 1
        print(f"{self.func.__name__} 第 {self.count} 次调用")
        return self.func(*args, **kwargs)

@CountCalls
def fetch(url):
    return f"data from {url}"

fetch("a.com")     # fetch 第 1 次调用
fetch("b.com")     # fetch 第 2 次调用
print(fetch.count) # 2   ← 状态挂在实例上，可以直接读
```

原理：`@CountCalls` 执行 `fetch = CountCalls(fetch)`，
`fetch` 变成了一个**实例**；调用 `fetch(...)` 时触发 `__call__`。
状态存在 `self.count` 上，比用闭包变量更直观。

## 七、四个实战装饰器

### 1. 重试（网络请求必备）

```python
import time
from functools import wraps

def retry(times=3, delay=1.0, exceptions=(Exception,)):
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            for i in range(times):
                try:
                    return func(*args, **kwargs)
                except exceptions as e:
                    if i == times - 1:      # 最后一次还失败就抛出
                        raise
                    print(f"第 {i+1} 次失败：{e}，{delay}s 后重试")
                    time.sleep(delay)
        return wrapper
    return decorator

@retry(times=3, delay=0.5, exceptions=(ConnectionError,))
def call_api(url):
    ...
```

### 2. 计时（性能排查）

```python
import time
from functools import wraps

def timer(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        t0 = time.perf_counter()      # 比 time.time() 更适合测耗时
        try:
            return func(*args, **kwargs)
        finally:
            print(f"{func.__name__} 耗时 {time.perf_counter()-t0:.4f}s")
    return wrapper
```

`try/finally` 保证**即使函数抛异常也会打印耗时**——排查超时问题时这点很重要。

### 3. 缓存（memoization）

```python
from functools import wraps, lru_cache

# 能不用自己写就别写：标准库已经有
@lru_cache(maxsize=128)
def fib(n):
    return n if n < 2 else fib(n-1) + fib(n-2)

print(fib(100))              # 秒出
print(fib.cache_info())      # CacheInfo(hits=98, misses=101, maxsize=128, currsize=101)
```

⚠️ `lru_cache` 的两个前提：**参数必须可哈希**（列表、字典不行，得转成元组），
**函数必须是纯函数**（同样输入永远同样输出）。

### 4. 注册器（插件系统）

```python
REGISTRY = {}

def register(name):
    def decorator(func):
        if name in REGISTRY:
            raise ValueError(f"重复注册: {name}")
        REGISTRY[name] = func
        return func          # 注意：这里直接返回原函数，不包装
    return decorator

@register("json")
def dump_json(data): ...

@register("yaml")
def dump_yaml(data): ...

print(REGISTRY)   # {'json': <function dump_json>, 'yaml': <function dump_yaml>}
```

这类装饰器**不改造行为，只做登记**——Flask 的 `@app.route`、
pytest 的 `@pytest.fixture` 都是这个套路。

## 八、装饰器的执行顺序

多个装饰器叠在一起，顺序是从**下往上**执行：

```python
@deco_a
@deco_b
def f(): ...

# 等价于 f = deco_a(deco_b(f))
```

```python
def bold(fn):
    @wraps(fn)
    def w(): return f"<b>{fn()}</b>"
    return w

def italic(fn):
    @wraps(fn)
    def w(): return f"<i>{fn()}</i>"
    return w

@bold
@italic
def text(): return "hi"

print(text())   # <b><i>hi</i></b>
```

**但调用时的执行顺序是相反的**：`bold` 的 wrapper 先跑（它在外层），
进入后才调用 `italic` 的 wrapper，最后才是 `text`。

## 九、三个高频坑

**坑 1：装饰器在导入时执行**

```python
@register("json")     # import 这个模块时就执行了，不管你有没有调用它
def dump_json(): ...
```

这意味着**装饰器体里的副作用会在 import 阶段发生**。
如果装饰器里有网络连接、文件读写，会让 import 变慢甚至失败。

**坑 2：装饰后无法被 pickle**

多进程（`multiprocessing`）传函数需要 pickle，
而 `wrapper` 是局部定义的，pickle 不到。
解决：用 `functools.wraps` 保留 `__qualname__`，或用 `dill` 库。

**坑 3：装饰类方法时 `self` 去哪了**

```python
@timer
def method(self, x): ...      # wrapper 的 *args 会收到 self，没问题
```

因为 wrapper 用 `*args`，`self` 会作为 `args[0]` 正常传进去。
**但如果你想在 wrapper 里访问 `self`，必须通过 `args[0]`**，
不能直接用 `self` 这个名字。

## 十、小结

- 装饰器的地基是**闭包**：内层函数记住外层变量
- `@deco` **完全等价于** `f = deco(f)`，没有额外魔法
- **必须 `@wraps`**，否则元信息丢失会让 Flask 这类框架出问题
- 带参数的装饰器 **3 层**：参数层 → 装饰器层 → wrapper 层
- 需要状态用**类装饰器**（`__call__` + 实例属性）
- 多个装饰器**从下往上装饰，从上往下执行**
- 装饰器在 **import 时**就执行，别在里面放重副作用

下一篇讲生成器——装饰器解决了"怎么包装函数"，
生成器解决的是"怎么处理大到内存装不下的数据"，两者经常组合使用。
