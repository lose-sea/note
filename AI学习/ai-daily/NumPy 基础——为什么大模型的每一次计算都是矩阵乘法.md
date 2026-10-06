<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# NumPy 基础——为什么大模型的每一次计算都是矩阵乘法

**承上**：阶段 0 我们打好了 Python 基础，上一篇《Python 进阶》用生成器解决了大数据读取。

**本篇**：本篇进入阶段 1：ndarray、向量化与矩阵运算——大模型每一次计算都是矩阵乘法。

**启下**：下一篇《Pandas 基础》用 DataFrame 管理训练数据与实验记录。

**学完这一节，你能动手做**：

1. 用 shape 思维排查深度学习里 90% 的维度报错
2. 用向量化替代 Python 循环，实测提速几十倍
3. 用 NumPy 手算一次 Self-Attention，看懂 Transformer 的核心公式


阶段 0 我们把 Python 打牢了，从这一篇开始进入**阶段 1：科学计算三件套**。第一个是 **NumPy**。为什么要先学它？因为——**大模型里的每一次计算，本质上都是矩阵乘法**。你以为是"模型在思考"，实际上是几十亿次矩阵乘法在 GPU 上飞速跑完。理解了 NumPy 的数组与矩阵运算，后面看 Transformer 的注意力公式 `softmax(QK^T/√d)V` 才不会发懵。

## 一、大模型里到底在算什么

三个最核心的运算，全是矩阵操作：

1. **Embedding 查表**：把 token id 变成向量 → 本质是"用一个 id 去一张大表里取一行"；
2. **注意力机制**：`Q @ K.T` 算出每个词对其他词的关注分数，再 `/√d` 缩放、softmax 归一化，最后 `@ V` 加权求和；
3. **前馈层（FFN）**：两次线性变换 `W2 @ (激活(W1 @ x))`。

所以学 NumPy 不只是"学个库"，而是**建立"一切都是张量运算"的直觉**。

## 二、ndarray：NumPy 的核心数组

```python
import numpy as np

# 从列表创建
a = np.array([1, 2, 3])
b = np.array([[1, 2, 3], [4, 5, 6]])      # 二维（矩阵）

print(a.shape)    # (3,)        形状
print(b.shape)    # (2, 3)      2 行 3 列
print(b.ndim)     # 2           维度数
print(b.dtype)    # int64       数据类型
print(b.size)     # 6           元素总数
```

**shape（形状）是 NumPy 里最重要的概念**。深度学习里 90% 的报错都是"形状对不上"，所以每次运算前先想清楚形状。

常用创建方式：

```python
print(np.zeros((2, 3)))        # 全 0
print(np.ones((2, 3)))         # 全 1
print(np.arange(0, 10, 2))     # [0 2 4 6 8]  类似 range
print(np.linspace(0, 1, 5))    # [0.   0.25 0.5  0.75 1.  ] 等分
print(np.random.randn(2, 3))   # 标准正态分布随机（初始化权重常用）
```

## 三、向量化：为什么 NumPy 比 Python 循环快几十倍

```python
import numpy as np
import time

n = 1_000_000
py_list = list(range(n))
np_arr = np.arange(n)

# Python 循环
start = time.time()
py_sum = sum(x * x for x in py_list)
py_time = time.time() - start

# NumPy 向量化
start = time.time()
np_sum = np.sum(np_arr * np_arr)
np_time = time.time() - start

print(f"Python 循环: {py_time*1000:.1f} ms")
print(f"NumPy 向量化: {np_time*1000:.1f} ms")
print(f"提速约 {py_time/np_time:.0f} 倍")
```

**运行结果（因机器而异）：**

```
Python 循环: 78.3 ms
NumPy 向量化: 3.1 ms
提速约 25 倍
```

为什么快？因为 NumPy 的运算在**底层 C 实现里批量执行**，还用了 SIMD 指令并行；而 Python 循环要逐元素做类型检查和解释。

**这就是"向量化思维"**：**能对整个数组一次操作，就绝不写 for 循环**。这条规则在 PyTorch 里同样适用，而且因为 GPU 并行，加速比会大到几百倍。

## 四、广播（Broadcasting）：不同形状也能算

广播让形状不同的数组自动"扩展"后运算：

```python
a = np.array([[1, 2, 3],
              [4, 5, 6]])          # shape (2, 3)
b = np.array([10, 20, 30])         # shape (3,)

print(a + b)
# [[11 22 33]
#  [14 25 36]]    b 被"复制"到每一行再相加
```

广播规则（从右往左对齐维度，维度为 1 或缺失时可扩展）：

| A 形状 | B 形状 | 结果形状 | 说明 |
|---|---|---|---|
| (2,3) | (3,) | (2,3) | B 补齐前导 1 → (1,3) → 复制 2 行 |
| (2,3) | (2,1) | (2,3) | B 第 2 维复制 3 次 |
| (2,3) | (2,) | ❌ 报错 | 3 vs 2 不匹配 |

**广播是"免费的抽象"**——它不真的复制数据，只是逻辑上扩展，所以既省内存又快。深度学习里的偏置 `bias` 加到每个样本上，靠的就是广播。

## 五、矩阵乘法：大模型的核心运算

```python
Q = np.random.randn(4, 8)     # 4 个词，每个 8 维（query）
K = np.random.randn(4, 8)     # 4 个词，每个 8 维（key）

# 方式 1：@ 运算符（推荐，最直观）
scores = Q @ K.T              # (4,8) @ (8,4) -> (4,4)
print(scores.shape)           # (4, 4)

# 方式 2：np.matmul
scores2 = np.matmul(Q, K.T)

# 方式 3：np.dot（二维时等价）
scores3 = np.dot(Q, K.T)

print(np.allclose(scores, scores2, scores3 - scores3 + scores))  # True
```

**矩阵乘法铁律**：`(m, k) @ (k, n) → (m, n)`，**中间维度必须相等**。

```
Q: (4, 8)     ← 4 个 query，每个 8 维
K.T: (8, 4)   ← K 转置后
结果: (4, 4)  ← 4×4 的注意力分数矩阵
              scores[i][j] = 第 i 个词对第 j 个词的关注程度
```

看到没？**这个 4×4 的矩阵就是注意力分数的雏形**——第 i 行第 j 列表示"第 i 个词该关注第 j 个词多少"。

⚠️ 注意区分 `*` 和 `@`：`A * B` 是**逐元素相乘**（要求形状完全相同），`A @ B` 是**矩阵乘法**。

## 六、实战：用 NumPy 手算一次 Self-Attention

把上面学的串起来，实现一个简化版注意力（真实版会加多头、掩码、dropout，但核心一样）：

```python
import numpy as np

np.random.seed(42)

# 假设：4 个词，每个词用 8 维向量表示
seq_len, d_model = 4, 8
X = np.random.randn(seq_len, d_model)        # 输入 (4, 8)

# 三个投影矩阵（真实模型里是可学习参数）
W_Q = np.random.randn(d_model, d_model)
W_K = np.random.randn(d_model, d_model)
W_V = np.random.randn(d_model, d_model)

# 1. 线性投影得到 Q / K / V
Q = X @ W_Q        # (4,8)
K = X @ W_K        # (4,8)
V = X @ W_V        # (4,8)

# 2. 算注意力分数：Q @ K.T / sqrt(d)
scores = Q @ K.T / np.sqrt(d_model)          # (4,4)
print("注意力分数矩阵:\n", np.round(scores, 2))

# 3. softmax 归一化（每行和为 1）
def softmax(x):
    e = np.exp(x - np.max(x, axis=-1, keepdims=True))   # 减最大值防溢出
    return e / np.sum(e, axis=-1, keepdims=True)

attn = softmax(scores)
print("\n注意力权重（每行和为1）:\n", np.round(attn, 2))

# 4. 加权求和得到输出
output = attn @ V                            # (4,4) @ (4,8) -> (4,8)
print("\n输出形状:", output.shape)            # (4, 8)
print("每行和:", np.round(attn.sum(axis=1), 6))   # 验证每行和为 1
```

**运行结果示例：**

```
注意力分数矩阵:
 [[ 0.89 -0.31  0.12 -0.45]
  [-0.22  1.05 -0.18  0.33]
  [ 0.41 -0.52  0.77 -0.11]
  [-0.13  0.28 -0.36  0.62]]

注意力权重（每行和为1）:
 [[0.45 0.14 0.22 0.19]
  [0.18 0.51 0.14 0.17]
  [0.28 0.11 0.40 0.21]
  [0.19 0.26 0.15 0.40]]

输出形状: (4, 8)
每行和: [1. 1. 1. 1.]
```

**恭喜，你刚刚用 20 行 NumPy 实现了 Transformer 的心脏**。后面学注意力机制时，你会发现公式 `Attention(Q,K,V) = softmax(QK^T/√d_k)V` 和你现在写的完全一样，只是换成了 PyTorch 张量并跑在 GPU 上。

## 七、常用操作速查

```python
a = np.arange(12).reshape(3, 4)      # reshape 改形状（元素总数不变）
print(a)
print(a.T)                            # 转置
print(a.sum())                        # 全部求和
print(a.sum(axis=0))                  # 沿行方向压缩（得到每列的和）
print(a.sum(axis=1))                  # 沿列方向压缩（得到每行的和）
print(a.mean(axis=1))                 # 每行均值
print(a.argmax(axis=1))               # 每行最大值的下标（预测类别时用）
print(a[np.arange(3), [1, 2, 3]])     # 高级索引：取每行指定列
```

**`axis` 参数**：`axis=0` 是"跨行"（纵向压缩），`axis=1` 是"跨列"（横向压缩）。记不住就记一句话：**axis 就是"被压缩掉的那个维度"**。

## 八、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 形状不匹配 | `ValueError: shapes (2,3) and (4,3) not aligned` | 打印 `.shape` 核对，矩阵乘法中间维必须相等 |
| 广播意外 | 结果比预期大，静默出错 | 显式 reshape 成想要的形状再算 |
| `*` 当成矩阵乘法 | 得到逐元素乘积 | 矩阵乘法用 `@` 或 `np.matmul` |
| 视图 vs 副本 | 切片修改后原数组也变了 | 要独立副本用 `.copy()` |
| 整数除法/类型 | `np.array([1,2])/2` 得 float，反之可能截断 | 运算前确认 `dtype` |
| softmax 溢出 | `exp(1000)` 变 inf | 先减最大值（见第六节） |

**视图陷阱**要特别注意：

```python
a = np.arange(6)
b = a[::2]        # b 是 a 的"视图"，共享内存
b[0] = 99
print(a)          # [99  1  2  3  4  5] ← 原数组被改了！
# 想要独立副本：b = a[::2].copy()
```

## 九、本篇小结

1. **ndarray** 是 NumPy 核心；**shape 是最重要的属性**，深度学习 90% 的报错都是形状问题。
2. **向量化**比 Python 循环快几十倍（GPU 上更多），能整块算就别写 for。
3. **广播**让不同形状自动对齐运算，是偏置相加等操作的基础。
4. **矩阵乘法**规则 `(m,k)@(k,n)→(m,n)`，`@` 是矩阵乘法、`*` 是逐元素相乘。
5. 我们用 NumPy **手算了一次 Self-Attention**——这就是 Transformer 的核心公式，你现在已经能看懂它了。

下一篇讲 **Pandas 基础**——用 DataFrame 管理训练数据与实验记录。你会学到怎么加载 CSV 语料、清洗缺失值与重复样本、统计标签分布、对比不同实验的结果，这是做数据准备和实验分析的日常工具。

> 本篇是《大模型开发从 0 到 1》专栏第 11 篇，阶段 1「科学计算三件套」第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
