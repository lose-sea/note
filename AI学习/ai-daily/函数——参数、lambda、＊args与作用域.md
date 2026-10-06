<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 函数——参数、lambda、*args/**kwargs 与作用域

**承上**：上一篇《控制流》我们写出了训练循环骨架，但循环体里的重复逻辑越堆越多。

**本篇**：本篇用函数把重复逻辑封装起来，搞懂参数传递、lambda、*args/**kwargs 与作用域。

**启下**：下一篇《面向对象——class、self 与继承》进一步把「数据 + 函数」打包成可复用的工具。

**学完这一节，你能动手做**：

1. 把数据清洗、指标计算封装成可测试的小函数
2. 用 *args/**kwargs 写出能接任意模型参数的通用封装
3. 避开可变默认参数、全局变量污染这两大作用域陷阱


前面我们写的代码都是"一段一段往下跑"。但当逻辑要复用（比如每次都要清洗文本、每次都要算 loss），复制粘贴就既不优雅也难维护。这一篇讲**函数**：怎么把一段逻辑封装起来反复调用，怎么灵活传参，以及最容易踩的**作用域**坑。大模型项目里，从数据预处理到评估指标，几乎全是函数。

## 一、为什么要用函数

三个理由：

1. **复用**：清洗文本的逻辑写一次，到处调用。
2. **可读性**：`train_model(config)` 比一百行流水账清楚得多。
3. **可测试**：小函数单独测，出问题容易定位。

```python
def clean_text(text):
    """去掉首尾空白并转小写（文档字符串）"""
    return text.strip().lower()

print(clean_text("  Hello World  "))   # hello world
print(clean_text("  Python  "))        # python
```

`def` 定义函数，`return` 返回结果。三引号里的说明叫**文档字符串（docstring）**，用 `help(函数名)` 能看到，强烈建议写。

## 二、参数：位置参数、默认参数、关键字参数

```python
def build_prompt(question, context="", max_len=512):
    """拼接 prompt；context 和 max_len 有默认值"""
    prompt = f"问题：{question}"
    if context:
        prompt += f"\n参考：{context}"
    return prompt[:max_len]

# 1. 位置参数：按顺序传
print(build_prompt("什么是 Transformer？"))

# 2. 位置参数 + 覆盖默认
print(build_prompt("什么是 Transformer？", "注意力机制相关材料"))

# 3. 关键字参数：指定名字传，顺序随意、可读性最好
print(build_prompt(question="什么是 RAG？", max_len=256))
```

规则：
- **必填参数在前，有默认值的在后**；
- 调用时推荐用**关键字参数**（`max_len=256`），尤其参数多的时候，别人一眼看懂在传什么。

⚠️ **默认参数不要用可变对象**（列表/字典），这是经典坑（见第六节）。

## 三、`*args` 与 `**kwargs`：接收任意数量参数

当你不知道会收到多少参数时用它们：

```python
def log_metrics(name, *args, **kwargs):
    """*args 收集多余的位置参数成 tuple，**kwargs 收集关键字参数成 dict"""
    print(f"[{name}]")
    print("  位置参数:", args)      # tuple
    print("  关键字参数:", kwargs)  # dict

log_metrics("train", 0.1, 0.05, epoch=3, lr=1e-4)
```

**运行结果：**

```
[train]
  位置参数: (0.1, 0.05)
  关键字参数: {'epoch': 3, 'lr': 0.0001}
```

这在写**装饰器、框架回调、转发参数**时非常常见。比如你想包一层大模型调用，但不想关心对方具体有哪些参数：

```python
def safe_call(model_fn, *args, **kwargs):
    """统一给模型调用加异常保护"""
    try:
        return model_fn(*args, **kwargs)   # 原样转发
    except Exception as e:
        print("调用失败:", e)
        return None
```

`*args` 和 `**kwargs` 在调用端也能用——`fn(*list)` 把列表拆成位置参数，`fn(**dict)` 把字典拆成关键字参数。

## 四、lambda：一行小函数

```python
# 普通函数
def square(x):
    return x * x

# lambda 等价写法
square2 = lambda x: x * x

print(square2(5))   # 25
```

lambda 适合**简短、用完即弃**的场合，最典型的是配合 `sorted`、`map`、`filter` 的 key：

```python
vocab = [("大模型", 120), ("数据", 45), ("微调", 8)]

# 按词频（第 2 个元素）排序
print(sorted(vocab, key=lambda x: x[1]))
# [('微调', 8), ('数据', 45), ('大模型', 120)]
```

**建议**：超过一行的逻辑别用 lambda，写成普通 `def` 更好读。

## 五、作用域：变量在哪里"可见"

Python 的作用域遵循 **LEGB** 规则（由内到外查找）：

- **L**ocal：函数内部
- **E**nclosing：外层嵌套函数
- **G**lobal：模块顶层
- **B**uilt-in：内置（如 `len`、`print`）

```python
learning_rate = 1e-4        # 全局变量

def show_lr():
    print(learning_rate)    # 函数内可以读取全局

def change_lr():
    learning_rate = 1e-3    # ❌ 这只是创建了一个局部变量！全局没变
    print("函数内:", learning_rate)

show_lr()        # 0.0001
change_lr()      # 函数内: 0.001
print("全局:", learning_rate)   # 0.0001（没被改）
```

想在函数里修改全局变量，必须用 `global` 声明：

```python
def really_change():
    global learning_rate
    learning_rate = 1e-3

really_change()
print(learning_rate)   # 0.001，这次真改了
```

**但强烈建议少用 `global`**——全局变量会让代码难以追踪。更好的做法是把值作为参数传进去、作为返回值传出来（纯函数）。

内层函数要修改外层变量，用 `nonlocal`（闭包场景）：

```python
def counter():
    n = 0
    def inc():
        nonlocal n      # 声明：改的是外层的 n
        n += 1
        return n
    return inc

c = counter()
print(c(), c(), c())   # 1 2 3
```

## 六、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 可变默认参数 | `def f(x=[])` 多次调用共享同一个列表 | 默认用 `None`，函数内 `x = x or []` |
| 忘记 return | 函数返回 `None` | 确认每个分支都有 return |
| 局部变量遮蔽全局 | 想改全局却只建了局部 | 用 `global`（但不推荐） |
| 参数顺序错 | 传错了位置 | 多用关键字参数 |
| 修改传入的可变对象 | 外部列表被函数改掉 | 函数内先 `copy()`，或明确文档说明 |

**头号坑：可变默认参数**，展开说：

```python
# ❌ 错误：默认列表在定义时就创建，所有调用共享
def add_token(t, tokens=[]):
    tokens.append(t)
    return tokens

print(add_token("我"))    # ['我']
print(add_token("爱"))    # ['我', '爱']  ← 上一轮的还在！

# ✅ 正确：用 None 占位
def add_token_ok(t, tokens=None):
    tokens = tokens if tokens is not None else []
    tokens.append(t)
    return tokens

print(add_token_ok("我"))   # ['我']
print(add_token_ok("爱"))   # ['爱']
```

## 七、函数设计小建议

| 建议 | 说明 |
|---|---|
| 一个函数只做一件事 | 便于复用和测试 |
| 参数控制在 5 个以内 | 太多就考虑用 dict 或数据类 |
| 必填在前、默认在后 | 语言强制要求 |
| 写 docstring | 说明干什么、参数、返回值 |
| 尽量"纯函数" | 不修改外部状态，同样的输入给同样的输出 |
| 别用 `global` | 用参数和返回值传递状态 |

## 八、本篇小结

1. 函数用 `def` 定义，靠**缩进**和 `return` 组织，写 docstring 是好习惯。
2. 参数分**位置参数、默认参数、关键字参数**；多参数时优先用关键字传，可读性最好。
3. `*args` 收集多余位置参数（tuple），`**kwargs` 收集关键字参数（dict），常用于转发和装饰器。
4. **lambda** 适合一行小函数，常配合 `sorted(key=...)`。
5. 作用域遵循 **LEGB**；函数内改全局要 `global`，闭包改外层要 `nonlocal`，但都应尽量少用。
6. **可变默认参数**是头号坑，一律用 `None` 占位。

下一篇讲**面向对象**——class、self 与继承。你会学到怎么把"一个分词器""一个模型封装"写成一个类，让代码从"一堆函数"升级成"可复用的组件"，这也是 PyTorch 里 `nn.Module` 的核心思想。

> 本篇是《大模型开发从 0 到 1》专栏第 6 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
