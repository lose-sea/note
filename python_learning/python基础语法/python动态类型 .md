# python动态类型

## 什么是动态类型

**动态类型**是指变量的类型在**运行时**才确定，而不是在编译时确定。变量本身没有固定类型，它只是一个"标签"，指向某个对象，对象的类型决定了这个变量能做什么。

### 与静态类型进行对比



| 特性           | 动态类型（Python） | 静态类型（C/Java） |
| :------------- | :----------------- | :----------------- |
| 类型检查时机   | 运行时             | 编译时             |
| 变量声明       | 不需要声明类型     | 必须声明类型       |
| 变量能否改类型 | 可以               | 不可以             |
| 灵活性         | 高                 | 低（但更安全）     |



### python中动态类型的表现

```python
x = 10          # x 指向 int 对象
print(type(x))  # <class 'int'>

x = "hello"     # 同一个变量，现在指向 str 对象
print(type(x))  # <class 'str'>

x = [1, 2, 3]   # 又变成 list
print(type(x))  # <class 'list'>
```

**变量 `x` 不是"装数据的盒子"，而是"贴在对象上的标签"。每次赋值只是让标签贴到新对象上。**



可以用`id()` 验证

```objc
x = 10
print(id(x))   # 例如 140234...
x = "hello"
print(id(x))   # 地址完全变了，说明指向了新对象
```

> python 中 `id()` 是一个内置函数, 用于返回对象的唯一标识 (identity) 返回一个整数, 表示该对象在当前生命周期内的唯一标识  
>
> `is`运算符本质上就是比较两个对象的 id 

## 动态类型常见错误

### 可变默认参数 

```python
def add_item(item, lst=[]):   # 危险！
    lst.append(item)
    return lst

print(add_item(1))   # [1]
print(add_item(2))   # [1, 2]  ← 期望是 [2]，但默认参数只创建一次
```

当 Python 执行到 `def add_item(...)` 这一行时，它会：

1. 创建一个空列表 `[]`
2. 把这个列表对象**绑定**为 `lst` 的默认值
3. 之后每次调用函数，如果没有传 `lst`，就**复用同一个列表对象**

所以并不是"每次进入函数重新创建"，而是"定义函数时创建一次，之后一直用这一个"。 

### 类型错误在运行时候才会暴露

```python
def add(a, b):
    return a + b

print(add(1, 2))        # 3
print(add("a", "b"))    # "ab"
print(add(1, "b"))      # TypeError，运行到这行才报错
```



### 隐式类型转换带来的困惑

```objc
print(1 == True)     # True（bool 是 int 子类）
print(0 == False)    # True
print("1" == 1)      # False（不会自动转换）
```



## 动态类型的优缺点

**优点**

+ 代码简洁，写起来快
+ 灵活，同一个函数可处理多种类型（鸭子类型）
+ 适合快速原型、脚本、数据分析

**缺点**

+ 类型错误在运行时才暴露，大型项目难维护
+ IDE 提示和重构能力弱
+ 性能略低（每次操作要查类型）



## 弥补动态类型的不足

####  类型注解

```objc
def greet(name: str, age: int) -> str:
    return f"{name} is {age}"


greet("Tom", 20)
```

**注解不影响运行，只是给人和工具看的**

####  鸭子类型（Duck Typing）

"如果它走起来像鸭子，叫起来像鸭子，那它就是鸭子。"

```python
def process(obj):
    obj.read()   # 不关心类型，只要它有 read 方法

process(open("a.txt"))   # 文件可以
process(io.StringIO())   # 内存流也可以
```

#### 运行时类型检查

```python
def add(a, b):
    if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
        raise TypeError("参数必须是数字")
    return a + b
```

> `raise`：主动触发异常（手动制造报错）
>
> `TypeError`：**类型不对**时专用的异常（内置）
>
> + 别的常见内置异常：`ValueError`(值不对)、`IndexError`、`KeyError`
>
> 引号里的字符串：自定义报错提示，会打印在 Traceback 里面