<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# NumPy 数组运算——Python 数据处理从零到一

## 一、为什么要学 NumPy

做 AI 的第一步不是模型，而是**数据处理**。你从 CSV、数据库、图片里拿到的原始数据，最终都要变成"张量"喂给模型，而这条路上最基础的工具就是 NumPy。

一句话概括它的价值：**Python 原生 list 慢在"每次运算都是解释执行"，NumPy 快在"把运算下沉到 C 语言的连续内存块上批量执行"**。

我们先用一组数据感受差距：

```python
import numpy as np
import time

# 纯 Python：对 1000 万元求和再平方
py_list = list(range(10_000_000))
t1 = time.time()
py_result = [x * 2 + 1 for x in py_list]
print(f"纯 Python 耗时: {time.time() - t1:.3f}s")

# NumPy：同样的运算
np_arr = np.arange(10_000_000)
t2 = time.time()
np_result = np_arr * 2 + 1
print(f"NumPy 耗时: {time.time() - t2:.3f}s")
```

运行结果（M 系列芯片实测，数值因机器而异）：

```
纯 Python 耗时: 0.612s
NumPy 耗时: 0.021s
```

接近 **30 倍**的差距。数据量越大、运算越复杂，差距越明显。这就是"向量化"（Vectorization）的威力：**把 for 循环交给库，把精力留给逻辑**。

## 二、ndarray：NumPy 的核心对象

### 1. 创建数组的常用方式

```python
import numpy as np

a = np.array([[1, 2, 3], [4, 5, 6]])   # 从列表创建，2 行 3 列
b = np.zeros((2, 3))                    # 全 0
c = np.ones((2, 3))                     # 全 1
d = np.arange(0, 10, 2)                 # 等差序列 [0,2,4,6,8]
e = np.linspace(0, 1, 5)                # 等分序列 [0, 0.25, 0.5, 0.75, 1]
f = np.random.randn(2, 3)               # 标准正态分布随机数

print(a.shape)   # (2, 3)  形状
print(a.dtype)   # int64   元素类型
print(a.ndim)    # 2       维度
```

三个属性是理解一切的前提：

- **shape**：形状，`(2, 3)` 表示 2 行 3 列。AI 里常说的 batch、特征数，全部体现在 shape 上
- **dtype**：元素类型。整数、浮点精度（float32/float64）直接影响内存和训练速度
- **ndim**：维度数。一维是向量，二维是矩阵，三维以上统称张量

### 2. 索引与切片

```python
a = np.array([[1, 2, 3],
              [4, 5, 6],
              [7, 8, 9]])

print(a[1, 2])      # 6      第 2 行第 3 列（下标从 0 开始）
print(a[0, :])      # [1 2 3]  第 1 行全部
print(a[:, 1])      # [2 5 8]  第 2 列全部
print(a[a > 4])     # [5 6 7 8 9]  布尔索引：所有大于 4 的元素
```

**布尔索引**是数据清洗的利器，"筛出所有评分大于 4 的电影"这类需求一行就够，你之前爬虫项目里筛选数据时的思路和它完全一致。

## 三、广播机制：不同形状也能运算

NumPy 最容易被初学者忽略、又最能提效的特性是**广播**（Broadcasting）：形状不同的数组运算时，小数组会被"自动拉伸"去匹配大数组。

```python
a = np.array([[1, 2, 3],
              [4, 5, 6]])      # shape (2, 3)
b = np.array([10, 20, 30])     # shape (3,)

print(a + b)
# [[11 22 33]
#  [14 25 36]]
# b 被沿着行方向"复制"成了 (2, 3)
```

广播的规则：**从最后一个维度往前对齐，两个维度要么相等、要么其中一个是 1，否则报错**。

```python
# 实战：数据归一化（减均值、除标准差）
data = np.random.randn(100, 5)          # 100 个样本、5 个特征
mean = data.mean(axis=0)                # 每列均值，shape (5,)
std = data.std(axis=0)                  # 每列标准差，shape (5,)
normalized = (data - mean) / std        # 广播：一行代码完成整列归一化
print(normalized.mean(axis=0))          # ≈ [0. 0. 0. 0. 0.]
```

`axis=0` 表示"沿行的方向压扁"，即对每一列求统计量——这是初学者最容易搞混的点，记住口诀：**axis=0 消灭行、算列；axis=1 消灭列、算行**。

## 四、常见坑与注意事项

| 坑 | 现象 | 正确做法 |
| --- | --- | --- |
| 浅拷贝 | `b = a; b[0]=99` 后 `a` 也变了 | 用 `b = a.copy()` |
| dtype 溢出 | `np.array([200], dtype=np.int8)` 得到负数 | 明确指定足够大的类型 |
| 整数除法 | 老版本 `/` 与 `//` 混淆 | 统一用浮点运算 |
| axis 搞反 | 统计结果形状对不上 | 先想清楚"消灭谁" |

浅拷贝问题展开说一下：

```python
a = np.array([1, 2, 3])
b = a          # 只是引用，指向同一块内存
b[0] = 99
print(a)       # [99  2  3]  ← 原数组被改了！

c = a.copy()   # 真正的独立副本
c[0] = -1
print(a)       # [99  2  3]  ← 不受影响
```

## 五、NumPy list vs Python list 对比

| 对比项 | Python list | NumPy ndarray |
| --- | --- | --- |
| 元素类型 | 可以混装 | 必须统一 |
| 内存布局 | 分散存储 | 连续内存块 |
| 运算速度 | 慢（解释执行） | 快（C 批量执行） |
| 数学函数 | 需手写循环 | 内置向量化函数 |
| 适用场景 | 小规模通用数据 | 数值计算 / AI 数据 |

## 六、小结

今天掌握的核心内容：

1. NumPy 的本质是**连续内存 + 向量化运算**，比原生 list 快一个数量级
2. `shape / dtype / ndim` 三个属性是理解数组的钥匙
3. **布尔索引**做数据筛选，**广播机制**做批量变换
4. `axis=0 算列、axis=1 算行`，归一化是广播的典型应用
5. 赋值是引用、改数据要 `copy()`——这是调试时最常见的幽灵 bug

明天我们进入机器学习基础：用今天学到的数组操作，手写一个线性回归和梯度下降，真正理解模型是怎么"学"的。

> 一句话总结：**NumPy 把"循环"变成了"表达式"，数据处理的速度和代码可读性同时起飞。**
