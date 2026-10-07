# Python 魔术方法全解：让你的类像内置类型一样好用

> 魔术方法（Magic Method / Dunder Method）是 Python 的"运算符重载"机制。
> 它决定你的对象能不能用 `len()`、能不能 `for x in obj`、
> `a + b` 会发生什么、`obj[...]` 能不能用。
>
> 本篇按**用途分组**讲最常用的一批，每个都给可运行的例子，
> 最后用一个完整案例串起来。

## 一、先理解：魔术方法是"协议"

`len(obj)` 内部实际上调用的是 `obj.__len__()`。

```python
class MyList:
    def __init__(self, data):
        self.data = list(data)
    def __len__(self):
        return len(self.data)

m = MyList([1, 2, 3])
print(len(m))              # 3
print(m.__len__())         # 3   ← 等价
```

所以魔术方法的本质是：**实现了它，你的类就满足了某个协议**，
从而能被内置函数、语法结构识别。

| 你写的 | Python 实际调用 |
|---|---|
| `len(x)` | `x.__len__()` |
| `x[i]` | `x.__getitem__(i)` |
| `x + y` | `x.__add__(y)` |
| `str(x)` | `x.__str__()` |
| `bool(x)` | `x.__bool__()` |
| `for i in x` | `iter(x)` → `x.__iter__()` |
| `with x:` | `x.__enter__()` / `x.__exit__()` |
| `x()` | `x.__call__()` |

**不要直接调用魔术方法**（除了 `super().__init__()`）。
它们的存在是为了被语法触发。

## 二、构造与销毁

### `__new__` vs `__init__`

这是面试必考，也是很多人含糊的地方。

```python
class A:
    def __new__(cls, *args, **kwargs):
        print("__new__ 执行，负责创建实例")
        return super().__new__(cls)      # 必须返回一个实例

    def __init__(self, x):
        print("__init__ 执行，负责初始化")
        self.x = x

a = A(1)
# __new__ 执行，负责创建实例
# __init__ 执行，负责初始化
```

区别一句话：**`__new__` 造对象，`__init__` 填属性**。

- `__new__` 是**静态方法**（隐式），第一个参数是 `cls`，**必须返回实例**
- `__init__` 第一个参数是 `self`，**返回 None**
- 如果 `__new__` 不返回当前类的实例，`__init__` **不会被调用**

### 什么时候需要 `__new__`

三个真实场景：

**1. 单例模式**

```python
class Singleton:
    _instance = None

    def __new__(cls, *args, **kwargs):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

a, b = Singleton(), Singleton()
print(a is b)     # True
```

**2. 不可变类型的子类化**

```python
class UpperStr(str):
    def __new__(cls, value):
        return super().__new__(cls, value.upper())   # str 不可变，必须在 __new__ 改

print(UpperStr("hello"))    # HELLO
```

因为 `str` 不可变，`__init__` 里已经改不了了，只能在创建时动手。

**3. 对象池 / 缓存**（如小整数池）

### `__del__` 不是析构函数

```python
class Resource:
    def __del__(self):
        print("销毁")
```

⚠️ `__del__` 的调用时机**不确定**（取决于 GC），
而且如果对象在 `__del__` 中复活会造成内存泄漏。
**释放资源请用上下文管理器**（`__enter__` / `__exit__`），下一篇讲。

## 三、字符串表示：三个方法

```python
class Point:
    def __init__(self, x, y):
        self.x, self.y = x, y

    def __str__(self):
        return f"Point({self.x}, {self.y})"          # 给用户看的

    def __repr__(self):
        return f"Point(x={self.x!r}, y={self.y!r})"  # 给开发者看的

p = Point(1, 2)
print(str(p))     # Point(1, 2)
print(repr(p))    # Point(x=1, y=2)
print(p)          # Point(1, 2)   ← print 用 __str__
print([p])        # [Point(x=1, y=2)]  ← 容器里用 __repr__
```

三条经验：

1. **`__repr__` 的目标是可复现**：理想情况下 `eval(repr(obj)) == obj`
2. **只写一个就写 `__repr__`**：没定义 `__str__` 时，`str()` 会退化为 `__repr__`
3. `__str__` 面向终端用户，`__repr__` 面向调试

`!r` 是 `repr()` 的简写，在 f-string 里很好用。

## 四、比较与哈希

### `__eq__` 和 `__hash__` 必须成对

这是最容易出 bug 的地方：

```python
class Bad:
    def __init__(self, v): self.v = v
    def __eq__(self, other):
        return self.v == other.v

b = Bad(1)
print({b})        # TypeError: unhashable type: 'Bad'
```

原因：**定义了 `__eq__` 后，`__hash__` 会被自动设为 `None`**。
因为 Python 要求"相等的对象必须有相等的哈希值"，
你改了相等规则却不改哈希规则，它不敢替你保证。

正确做法：

```python
class Good:
    def __init__(self, v): self.v = v
    def __eq__(self, other):
        if not isinstance(other, Good):
            return NotImplemented     # ← 注意是 NotImplemented 不是 False
        return self.v == other.v
    def __hash__(self):
        return hash((self.__class__, self.v))

g = Good(1)
print({g})                  # 正常工作
print({Good(1), Good(1)})   # 1 个元素（去重生效）
```

两个细节：
- 类型不匹配返回 **`NotImplemented`**（不是 `False`），
  这样 Python 会尝试反射操作（`other.__eq__(self)`）
- `__hash__` 用**元组**组合字段哈希，比自己拼字符串靠谱

### `functools.total_ordering`：只写两个，得到六个

```python
from functools import total_ordering

@total_ordering
class Version:
    def __init__(self, s):
        self.parts = tuple(int(x) for x in s.split("."))

    def __eq__(self, other):
        return self.parts == other.parts
    def __lt__(self, other):
        return self.parts < other.parts
    def __repr__(self):
        return f"Version({'.'.join(map(str, self.parts))})"

print(Version("1.2.0") < Version("1.10.0"))    # True  ✅ 按数字比不是按字符串
print(sorted([Version("1.10"), Version("1.2")]))  # [Version(1.2), Version(1.10)]
```

只写 `__eq__` 和 `__lt__`，装饰器自动生成
`__le__`、`__gt__`、`__ge__`。

## 五、容器协议

实现这四个，你的类就"像"一个序列。

```python
class Playlist:
    def __init__(self, songs):
        self._songs = list(songs)

    def __len__(self):
        return len(self._songs)

    def __getitem__(self, index):
        # index 可能是 int 也可能是 slice，都要处理
        if isinstance(index, slice):
            return Playlist(self._songs[index])
        return self._songs[index]

    def __setitem__(self, index, value):
        self._songs[index] = value

    def __contains__(self, item):
        return item in self._songs

    def __iter__(self):
        return iter(self._songs)      # 通常直接委托给内部容器

pl = Playlist(["a", "b", "c"])
print(len(pl))        # 3
print(pl[0])          # 'a'
print(pl[0:2])        # Playlist(['a','b'])  ← slice 处理生效
print("a" in pl)      # True
for s in pl: print(s) # a b c
print(list(reversed(pl)))   # ✅ 实现了 __len__ + __getitem__ 就自动支持 reversed
```

**彩蛋**：只要实现了 `__len__` 和 `__getitem__`，
即使不写 `__iter__`，Python 也能用旧的迭代协议让 `for` 跑起来
（从 0 开始不断 `__getitem__` 直到 `IndexError`）。
但显式写 `__iter__` 更好。

### 迭代器 vs 可迭代对象

```python
class Counter:
    """这是个迭代器：__iter__ 返回自己"""
    def __init__(self, n):
        self.n, self.i = n, 0
    def __iter__(self):
        return self          # 返回自己
    def __next__(self):
        if self.i >= self.n:
            raise StopIteration
        self.i += 1
        return self.i

c = Counter(3)
print(list(c))    # [1, 2, 3]
print(list(c))    # []  ← 一次性，耗尽了
```

关键区别：

| | 可迭代对象（Iterable） | 迭代器（Iterator） |
|---|---|---|
| 方法 | `__iter__` | `__iter__` + `__next__` |
| `__iter__` 返回 | **新的迭代器** | `self` |
| 能遍历几次 | 多次 | 一次 |

**设计建议**：容器类应该是**可迭代对象**（`__iter__` 返回新的迭代器），
这样能被 `for` 多次遍历。列表、字典都是这么做的。

## 六、属性访问控制

### `__getattr__` vs `__getattribute__`

```python
class Lazy:
    def __getattr__(self, name):
        # 只在"常规查找失败"时被调用
        print(f"访问了不存在的属性 {name}")
        return None

class Strict:
    def __getattribute__(self, name):
        # 所有属性访问都会经过这里（包括存在的）
        print(f"访问 {name}")
        return super().__getattribute__(name)
```

**99% 的情况用 `__getattr__`**。`__getattribute__` 会在每次属性访问时触发，
容易写出无限递归（`self.x` 里又调 `__getattribute__`），性能也差。

`__getattr__` 的典型用途：

```python
class Config:
    """配置项懒加载：用到才去读文件"""
    def __init__(self, path):
        self.path = path
        self._cache = {}
    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)     # 别拦截内部属性
        if name not in self._cache:
            self._cache[name] = self._load(name)
        return self._cache[name]
```

⚠️ 在 `__getattr__` 里访问 `self.xxx` 要小心递归：
如果 `xxx` 也不存在，会再次触发 `__getattr__`。
所以要先排除 `_` 开头的内部属性。

### `__setattr__` 做校验

```python
class Validated:
    def __setattr__(self, name, value):
        if name == "age" and not (0 <= value <= 150):
            raise ValueError("age 必须在 0~150")
        super().__setattr__(name, value)     # 必须用 super，否则无限递归

p = Validated()
p.age = 20      # OK
p.age = 200     # ValueError
```

⚠️ **绝对不能在 `__setattr__` 里写 `self.name = value`**，
那会再次触发 `__setattr__`，无限递归。必须用 `super().__setattr__()`
或者 `self.__dict__[name] = value`。

### 更好的方案：property / descriptor

```python
class Person:
    def __init__(self, age): self._age = age

    @property
    def age(self):
        return self._age
    @age.setter
    def age(self, value):
        if not (0 <= value <= 150):
            raise ValueError("age 必须在 0~150")
        self._age = value
```

能用 `property` 就别用 `__setattr__`——**局部生效优于全局拦截**。

## 七、可调用对象 `__call__`

```python
class Adder:
    def __init__(self, n): self.n = n
    def __call__(self, x):
        return x + self.n

add5 = Adder(5)
print(add5(10))     # 15
print(callable(add5))   # True
```

用途：
- **带状态的函数**（比闭包更可控，能加方法）
- **装饰器用类实现**（上一篇讲过）
- **策略模式**：不同实例是不同的策略，`strategy(data)` 统一调用

## 八、`__slots__`：省内存

```python
class Point:
    __slots__ = ("x", "y")       # 不再有 __dict__
    def __init__(self, x, y):
        self.x, self.y = x, y

p = Point(1, 2)
p.z = 3       # AttributeError: 'Point' object has no attribute 'z'
```

效果：
- **内存省约 40%**（不用给每个实例分配 `__dict__`）
- **属性访问略快**
- **不能再动态加属性**

```python
import sys
class Normal:
    def __init__(self, x, y): self.x, self.y = x, y

print(sys.getsizeof(Normal(1,2).__dict__))   # 104 字节（__dict__ 本身）
# 用 __slots__ 的类没有 __dict__
```

适合**大量小对象**的场景（比如 ORM 查询结果有几百万条）。
但别滥用——它牺牲了灵活性，而且会让 pickle、多继承变复杂。

## 九、运算符重载

```python
class Vector:
    def __init__(self, x, y): self.x, self.y = x, y

    def __add__(self, other):
        if not isinstance(other, Vector):
            return NotImplemented
        return Vector(self.x + other.x, self.y + other.y)

    def __mul__(self, k):          # v * 2
        return Vector(self.x * k, self.y * k)
    __rmul__ = __mul__             # 2 * v（反射，参数顺序反过来）

    def __neg__(self):             # -v
        return Vector(-self.x, -self.y)

    def __abs__(self):             # abs(v)  → 模长
        return (self.x**2 + self.y**2) ** 0.5

    def __bool__(self):            # bool(v)
        return self.x != 0 or self.y != 0

    def __repr__(self):
        return f"Vector({self.x}, {self.y})"

v = Vector(3, 4)
print(v + Vector(1, 2))    # Vector(4, 6)
print(2 * v)               # Vector(6, 8)   ← __rmul__ 生效
print(abs(v))              # 5.0
print(bool(Vector(0, 0)))  # False
```

两个要点：
- **`__rmul__`** 处理"左操作数是别的类型"的情况（`2 * v`）
- 定义了 `__len__` 或 `__bool__` 后，**空对象会自动是 falsy**——
  这是 `if my_list:` 能工作的原因

## 十、完整案例：一个好用的配置类

把上面这些串起来：

```python
from collections.abc import Mapping
import json

class Config(Mapping):
    """不可变的、支持点号访问的配置对象"""
    __slots__ = ("_data",)

    def __init__(self, mapping):
        object.__setattr__(self, "_data", dict(mapping))

    # --- Mapping 抽象基类要求的三个方法 ---
    def __getitem__(self, key):
        return self._data[key]
    def __iter__(self):
        return iter(self._data)
    def __len__(self):
        return len(self._data)

    # --- 点号访问 ---
    def __getattr__(self, name):
        try:
            return self._data[name]
        except KeyError:
            raise AttributeError(name) from None

    def __setattr__(self, name, value):
        raise AttributeError("Config 是不可变的")     # 只读

    def __repr__(self):
        return f"Config({self._data!r})"

    @classmethod
    def from_json(cls, path):
        with open(path, encoding="utf-8") as f:
            return cls(json.load(f))

cfg = Config({"host": "localhost", "port": 5432})
print(cfg.host)                  # localhost    ← 点号访问
print(cfg["port"])               # 5432         ← 下标访问
print(len(cfg), "port" in cfg)   # 2 True       ← 容器协议
print(dict(cfg))                 # {'host':..., 'port':...}
cfg.host = "x"                   # AttributeError: Config 是不可变的
```

继承 `collections.abc.Mapping` 是个技巧：
**只实现三个方法，就自动获得 `keys()`、`values()`、`items()`、`get()`、`in` 等十几个方法**。

## 十一、小结

- 魔术方法是**协议**：实现了 `_len__` 就能 `len()`，实现 `__iter__` 就能 `for`
- **`__new__` 造对象，`__init__` 填属性**；`__new__` 必须返回实例
- 只写一个字符串方法就写 **`__repr__`**
- **定义 `__eq__` 必须同时定义 `__hash__`**，否则对象不能进 set/dict
- 类型不匹配返回 **`NotImplemented`**（不是 `False`）
- 容器类做**可迭代对象**（`__iter__` 返回新迭代器），别做一次性迭代器
- **`__setattr__` 里必须用 `super()`**，否则无限递归
- 大量小对象用 **`__slots__`** 省内存
- 继承 `collections.abc.Mapping` / `Sequence` 能白嫖一堆方法

下一篇讲上下文管理器——`__enter__` / `__exit__` 是资源管理的正解，
也是本篇反复提到的"比 `__del__` 靠谱"的那个方案。
