<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 变量与数据类型——动态类型、类型注解与 Python 的数字世界

**承上**：上一篇《Python 环境搭建》我们把环境跑通了，写出了第一个能运行的脚本。

**本篇**：学变量与五种基本类型、搞懂"动态类型"到底意味着什么，以及类型注解如何让大模型代码更稳。

**启下**：下一篇《字符串处理——f-string、切片与正则》专攻文本，那是清洗语料的第一把刀。

**学完这一节，你能动手做**：

1. 正确使用 int、float、str、bool、None 并避开 float 精度陷阱
2. 用类型注解标注变量与函数签名，让 IDE 帮你提前发现错误
3. 用 isinstance 做健壮的类型检查，避免线上崩溃

上一步我们把 Python 环境装好了，写出了第一个能跑的脚本。这一篇继续打地基：**变量与数据类型**。你可能会想"这太基础了吧"——但等你真正写大模型代码时会发现，变量和类型无处不在：模型的配置参数、一批 token 的 id 列表、张量的 `float32`/`float16` 精度，全都是"数据 + 类型"的组合。把这一篇吃透，后面读 PyTorch、Transformers 源码时才不会一头雾水。

## 一、为什么大模型代码里全是变量和类型

随便翻开一段训练脚本：

```python
batch_size = 32
learning_rate: float = 1e-4
token_ids = [101, 2023, 2003, 1037]   # 一句话的 token
weights = model.float()               # 转成 float32 张量
```

- `batch_size` 是个整数，决定一次喂多少数据；
- `learning_rate` 标了 `float` 类型注解，说明它是浮点数；
- `token_ids` 是个列表，里面是整数——模型吃进去的不是文字，是这些 id；
- `weights` 是张量，但底层数据类型是 `float32`。

你会发现：**大模型项目对"数据是什么类型"极其敏感**。一个该是 `float32` 的张量被当成 `float16`，可能直接数值溢出；一个该是列表的配置被传成字符串，训练会莫名其妙报错。所以这一篇，我们把 Python 的类型系统讲清楚。

## 二、动态类型：赋值即定义

Python 是**动态类型**语言——变量不需要提前声明类型，第一次赋值就决定了它此刻的类型，而且类型还能随时变：

```python
x = 10          # x 现在是 int
print(type(x))  # <class 'int'>

x = "hello"     # x 变成了 str，完全合法
print(type(x))  # <class 'str'>

x = [1, 2, 3]   # x 又变成了 list
print(type(x))  # <class 'list'>
```

注意一个关键点：**Python 的变量更像"贴在某个对象上的标签"，而不是"装数据的盒子"**。同一个对象可以贴多个标签（`a = b = []`），一个标签也能随时撕下来贴到别的对象上。理解这一点，后面才不会在"可变对象共享"的坑里栽跟头。

## 三、基本数据类型一览

| 类型 | 字面量例子 | 说明 |
|---|---|---|
| `int` | `10`、`-3`、`0b1010` | 任意精度整数，不会溢出 |
| `float` | `3.14`、`1e-4` | 双精度浮点（64 位） |
| `bool` | `True`、`False` | 整数 1 和 0 的子类 |
| `str` | `"hello"`、`'你好'` | 不可变Unicode 文本 |
| `NoneType` | `None` | 表示"空/无"，常作默认值 |

`bool` 其实是 `int` 的子类，`True == 1`、`False == 0` 成立，但不要拿来做算术，容易把人看晕。

## 四、数字的世界：int 不会溢出，float 要小心

### 4.1 int 任意精度

C/Java 里的 `int` 有固定位数（32 位最大约 21 亿），超了就溢出。Python 的 `int` 是**任意精度**——只要内存够，多大都行：

```python
big = 2 ** 1000
print(big)        # 一个 302 位的巨大整数，不会溢出
print(big.bit_length())   # 1001
```

这对大模型有意义吗？有。比如你处理超长文档的字符偏移、大语料的行号，不用担心溢出。

### 4.2 float 的精度陷阱

浮点数遵循 IEEE 754，存在二进制无法精确表示小数的问题：

```python
print(0.1 + 0.2)        # 0.30000000000000004，不是 0.3！
print(0.1 + 0.2 == 0.3) # False
```

**这正是大模型要用 `float32`/`float16` 而不是无限精度的原因**——硬件只能用有限位存小数。所以比较浮点数要用容差，而不是直接 `==`：

```python
def approx_equal(a, b, tol=1e-9):
    return abs(a - b) < tol

print(approx_equal(0.1 + 0.2, 0.3))   # True
```

当你日后看到 loss 从 `2.3456` 变成 `2.3457` 就认为"没变化"，或者做 `if loss == 0.0` 的判断，记住这个坑。

## 五、类型注解：让大模型代码更好读、更稳

Python 是动态类型，但现代大模型库（PyTorch、Transformers、vLLM）**大量使用类型注解**。为什么？因为项目太大，没有类型提示，人和 IDE 都看不懂函数该传什么。

```python
from typing import List, Optional

def build_prompt(question: str, context: List[str]) -> str:
    """拼接一个问题 + 若干上下文，返回完整 prompt"""
    parts: List[str] = [f"问题：{question}"]
    for i, c in enumerate(context, 1):
        parts.append(f"参考{i}：{c}")
    return "\n".join(parts)

config: Optional[dict] = None   # 可能是 dict，也可能是 None
```

- `question: str` 表示参数应是字符串；
- `-> str` 表示返回值类型是字符串；
- `List[str]` 表示"字符串组成的列表"，来自 `typing` 模块；
- `Optional[dict]` 表示"可能是 dict，也可能是 None"。

类型注解**运行时不做强制检查**（写错了不会报错），但配合 `mypy` 这类静态检查工具，能在运行前抓出一大类 bug。强烈建议从一开始就养成写注解的习惯。

## 六、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 可变默认参数 | `def f(x=[]): x.append(1)` 多次调用共享同一个列表 | 默认用 `None`，函数内再 `x = x or []` |
| `==` 与 `is` 混淆 | `a == b` 比"值"，`a is b` 比"是不是同一个对象" | 比值得用 `==`；比 None 用 `is None` |
| 浮点直接 `==` | `0.1+0.2 == 0.3` 为 False | 用容差比较（见第四节） |
| 动态类型运行时才报错 | `x = "5"; x + 3` 报 TypeError | 写注解 + mypy，提前发现 |
| None 当默认值踩坑 | 把 `None` 当 0 或空串参与运算报错 | 显式判断 `if x is None` |

两个高频错误重点说：

1. **可变默认参数**：这是 Python 头号经典坑。函数的默认参数在函数**定义时**就创建好了，之后所有调用共享它。正确写法永远是用 `None` 占位。
2. **`is` 不是 `==`**：`is` 判断"两个变量指向内存里同一个对象"，`==` 判断"值相等"。比如两个内容相同的列表 `a == b` 为 True，但 `a is b` 为 False。只有和单例（如 `None`、`True`）比较时才用 `is`。

## 七、本篇小结

这一篇我们搞清了：

1. Python 是**动态类型**语言，变量是"贴在对象上的标签"，类型可随时变。
2. 五种基本类型 `int / float / bool / str / NoneType`，其中 `int` **任意精度不会溢出**，`float` 有精度陷阱。
3. 浮点数比较要用**容差**，不能直接 `==`。
4. **类型注解**（`str`、`List[str]`、`Optional`）让大模型项目可读、可静态检查，强烈推荐用起来。
5. 避开可变默认参数、`is`/`==` 混淆等经典坑。

下一篇我们聊**字符串处理**——f-string 格式化、切片、以及用正则清洗文本。毕竟大模型吃的"粮食"就是文本，学会干净利落地处理字符串，是后面做分词、做 prompt 工程的前提。

> 本篇是《大模型开发从 0 到 1》专栏第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
