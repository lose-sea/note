<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# 深度学习入门——PyTorch 张量与自动求导

## 一、为什么深度学习离不开"张量"

上一篇我们手写线性回归时，用的是 NumPy 数组。既然 NumPy 已经能算矩阵乘法、能广播、能求均值，为什么还要引入 PyTorch 的 Tensor？

答案在三个词上：**GPU 加速、自动求导、可组合的计算图**。

- **GPU 加速**：深度学习的核心运算是大规模矩阵乘法，GPU 擅长并行做这件事。NumPy 只在 CPU 上跑，Tensor 可以 `.to('cuda')` 一行搬到 GPU。
- **自动求导**：训练模型的本质是"求梯度"。NumPy 里梯度要你自己推导公式再写代码；PyTorch 会**自动帮你算出梯度**，你只要写前向计算。
- **计算图**：每一次运算都被记录下来，形成一张图，反向传播时沿着图自动回溯。

一句话概括：**NumPy 是科学计算库，Tensor 是"为训练神经网络而生"的数组**。

## 二、张量到底是什么

张量（Tensor）听起来吓人，其实就是**多维数组的统一叫法**：

| 维度 | 名字 | 例子 | shape |
| ---- | ---- | ---- | ----- |
| 0 维 | 标量 scalar | `3.14` | `torch.Size([])` |
| 1 维 | 向量 vector | `[1, 2, 3]` | `torch.Size([3])` |
| 2 维 | 矩阵 matrix | 一张灰度图 | `torch.Size([28, 28])` |
| 3 维 | 三维张量 | 一张 RGB 图 (H, W, C) | `torch.Size([224, 224, 3])` |
| 4 维 | 四维张量 | 一批图片 (N, C, H, W) | `torch.Size([32, 3, 224, 224])` |

深度学习里最常见的是 **4 维张量**：`[批次大小, 通道数, 高, 宽]`。你只要记住一句话：**张量的 shape 就是数据的"形状说明书"，搞懂 shape 就搞懂了一半的 bug**。

### 2.1 创建张量

```python
import torch

# 从 Python 列表创建
a = torch.tensor([1.0, 2.0, 3.0])
print(a)              # tensor([1., 2., 3.])
print(a.dtype)        # torch.float32 —— 注意：整数列表会变成 int64

# 常用构造
z = torch.zeros(2, 3)            # 全 0，形状 2x3
o = torch.ones(2, 3)             # 全 1
r = torch.randn(2, 3)            # 标准正态分布随机
e = torch.eye(3)                 # 3x3 单位矩阵
ar = torch.arange(0, 10, 2)      # tensor([0, 2, 4, 6, 8])

# 从 NumPy 转换（双向都可以）
import numpy as np
np_arr = np.array([[1, 2], [3, 4]])
t = torch.from_numpy(np_arr)     # numpy -> tensor（共享内存！）
back = t.numpy()                 # tensor -> numpy
```

> ⚠️ **坑 1**：`torch.from_numpy()` 与 NumPy 数组**共享内存**，改一个另一个也变。想要独立副本用 `torch.tensor(np_arr)`（会复制）。

### 2.2 形状操作：view / reshape / 转置

这是实际写模型时最高频的操作。

```python
x = torch.arange(12)          # tensor([0,1,...,11])
print(x.shape)                # torch.Size([12])

# 改变形状：变成 3 行 4 列
y = x.view(3, 4)
print(y)
# tensor([[ 0,  1,  2,  3],
#         [ 4,  5,  6,  7],
#         [ 8,  9, 10, 11]])

# -1 表示"让 PyTorch 自己算"
z = x.view(3, -1)             # 等价于 view(3, 4)
print(z.shape)                # torch.Size([3, 4])

# 转置（二维就是矩阵转置）
m = torch.randn(2, 3)
print(m.T.shape)              # torch.Size([3, 2])

# 高维维度交换：把 (N, C, H, W) 变成 (N, H, W, C)
img = torch.randn(16, 3, 224, 224)
print(img.permute(0, 2, 3, 1).shape)   # torch.Size([16, 224, 224, 3])
```

**`view` 和 `reshape` 的区别**：

| 方法 | 要求内存连续 | 不连续时的行为 |
| ---- | ------------ | -------------- |
| `view()` | 必须连续 | 直接报错 |
| `reshape()` | 不要求 | 自动先 copy 再变形，永远不报错 |

> ⚠️ **坑 2**：转置/permute 之后张量内存不再连续，直接 `view()` 会报 `RuntimeError: view size is not compatible`。**保险做法：先 `.contiguous()` 再 `.view()`，或者干脆用 `reshape()`**。

### 2.3 广播机制（Broadcasting）

形状不同也能运算，PyTorch 会自动"扩展"小的一方：

```python
a = torch.ones(3, 4)
b = torch.tensor([1.0, 2.0, 3.0, 4.0])   # shape [4]
c = a + b        # b 被扩展成 3x4，每列都加上对应值
print(c)
# tensor([[2., 3., 4., 5.],
#         [2., 3., 4., 5.],
#         [2., 3., 4., 5.]])
```

广播规则（从**末尾维度**往前对齐）：维度相等，或者其中一个是 1，或者其中一方缺失。

```python
x = torch.randn(2, 1, 3)
y = torch.randn(4, 3)
print((x + y).shape)    # torch.Size([2, 4, 3]) —— x 的第1维 1 被扩成 4
```

## 三、自动求导 Autograd：PyTorch 的灵魂

### 3.1 直观理解

假设有：

```
y = (x + 2)² * 3，当 x = 1 时，dy/dx = ?
```

手算：`dy/dx = 6(x+2) = 6*3 = 18`。

用 PyTorch：

```python
import torch

x = torch.tensor(1.0, requires_grad=True)   # 关键：告诉 PyTorch 要跟踪 x
y = (x + 2) ** 2 * 3

y.backward()        # 反向传播，自动算出梯度
print(x.grad)       # tensor(18.)
```

就这三步：**标记 `requires_grad=True` → 写前向计算 → 调 `backward()`**，梯度自动出现在 `.grad` 里。

### 3.2 背后发生了什么：计算图

当你写 `y = (x+2)**2 * 3` 时，PyTorch 悄悄建了一张图：

```
x (叶子节点, requires_grad=True)
  ↓ add
x+2
  ↓ pow
(x+2)²
  ↓ mul
y = (x+2)² * 3
```

调用 `y.backward()` 时，PyTorch 从 y 出发**沿图反向走**，对每个节点套链式法则，把梯度累积到叶子节点的 `.grad` 上。

```python
x = torch.tensor(1.0, requires_grad=True)
a = x + 2          # a.grad_fn = <AddBackward0>
b = a ** 2         # b.grad_fn = <PowBackward0>
y = b * 3          # y.grad_fn = <MulBackward0>

print(y.grad_fn)        # <MulBackward0>
print(x.is_leaf)        # True —— x 是叶子节点
print(a.is_leaf)        # False —— 中间结果不是叶子
```

**只有 `requires_grad=True` 的叶子节点才会累积 `.grad`**，中间节点的梯度默认不保留（省内存）。

### 3.3 用自动求导重写线性回归

上一篇我们手动推导梯度公式 `dw = 2/n * X.T @ (pred - y)`。现在把求导交给 PyTorch：

```python
import torch

# 1. 造数据：y = 3x + 2 + 噪声
torch.manual_seed(0)
X = torch.rand(100, 1) * 10                       # 100 个样本
y = 3 * X + 2 + torch.randn(100, 1) * 0.5

# 2. 初始化参数（requires_grad=True 表示这两个数要被优化）
w = torch.randn(1, requires_grad=True)
b = torch.zeros(1, requires_grad=True)

lr = 0.01
for epoch in range(1, 501):
    # 3. 前向：算预测值
    pred = X * w + b
    loss = ((pred - y) ** 2).mean()      # 均方误差

    # 4. 反向：自动求梯度
    loss.backward()

    # 5. 更新参数（这一步必须关掉梯度跟踪！）
    with torch.no_grad():
        w -= lr * w.grad
        b -= lr * b.grad

    # 6. 清空梯度，否则会累积
    w.grad.zero_()
    b.grad.zero_()

    if epoch % 100 == 0:
        print(f"epoch {epoch:3d} | loss={loss.item():.4f} | w={w.item():.3f} b={b.item():.3f}")

print(f"\n真实值 w=3, b=2 → 训练结果 w={w.item():.3f}, b={b.item():.3f}")
```

输出（你的随机种子相同时基本一致）：

```
epoch 100 | loss=0.2413 | w=3.021 b=2.305
epoch 200 | loss=0.2401 | w=3.005 b=2.145
epoch 300 | loss=0.2400 | w=3.001 b=2.063
epoch 400 | loss=0.2400 | w=3.000 b=2.031
epoch 500 | loss=0.2400 | w=3.000 b=2.017

真实值 w=3, b=2 → 训练结果 w=3.000, b=2.017
```

**注意这次我们没有手写任何梯度公式**，只写了前向计算，`backward()` 帮我们算出了 `w.grad` 和 `b.grad`。这正是 PyTorch 的核心价值。

### 3.4 这段代码里四个必须懂的细节

**① `with torch.no_grad()`**

参数更新这一步 `w -= lr * w.grad` 本身也是运算，如果不开这个上下文，PyTorch 会把它也记进计算图，导致下次 `backward()` 时图越来越大、甚至报错。**凡是"更新参数/推理预测"这类不需要梯度的操作，都套上它**。

推理时的标准写法：

```python
model.eval()
with torch.no_grad():
    pred = model(X_test)      # 不建图，更快更省内存
```

**② `w.grad.zero_()`**

PyTorch 的梯度是**累加**的，不清零就会把上一轮的梯度叠加进来，训练直接跑飞。这是新手最常犯的错误之一。

**③ `loss.item()`**

`loss` 是一个 0 维张量，`item()` 把它转成 Python 数字。打印/存日志时用它，避免把整个计算图拖进 Python 变量里导致内存泄漏。

**④ `torch.manual_seed(0)`**

固定随机种子，保证每次运行结果一致，debug 时非常有用。

## 四、常见坑与排查清单

| 坑 | 现象 | 解决 |
| -- | ---- | ---- |
| 忘记 `zero_()` | loss 不降反升、参数爆炸 | 每个 iteration 前清梯度 |
| in-place 修改 requires_grad 张量 | `RuntimeError: a leaf Variable that requires grad is being used in an in-place operation` | 用 `with torch.no_grad()` 包裹，或改用非 in-place 写法 `w = w - lr*w.grad` |
| 转置后 `view()` | `view size is not compatible` | 先 `.contiguous()` 或用 `reshape()` |
| 把 tensor 直接累加进 Python list 求 loss | 内存爆炸、显存溢出 | 用 `loss.item()` 取标量 |
| 推理没开 `no_grad` | 显存越来越占、速度慢 | 推理一律包 `with torch.no_grad()` |
| dtype 不匹配 | `expected Double but got Float` | 统一 `.float()`，PyTorch 不像 NumPy 会自动提升类型 |

再补一个隐蔽的：**跨设备**。CPU 张量和 GPU 张量不能直接运算：

```python
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
x = x.to(device)      # 数据与模型要搬到同一个 device
```

## 五、NumPy 与 PyTorch 速查对照

| 操作 | NumPy | PyTorch |
| ---- | ----- | ------- |
| 创建全 0 | `np.zeros((2,3))` | `torch.zeros(2,3)` |
| 矩阵乘法 | `a @ b` | `a @ b` 或 `torch.mm(a,b)` |
| 逐元素乘 | `a * b` | `a * b` |
| 求均值 | `a.mean()` | `a.mean()` |
| 改变形状 | `a.reshape(3,4)` | `a.view(3,4)` / `a.reshape(3,4)` |
| 转置 | `a.T` | `a.T` 或 `a.transpose(0,1)` |
| 最大值索引 | `a.argmax()` | `a.argmax()` |
| 拼接 | `np.concatenate` | `torch.cat` |
| 增加维度 | `np.expand_dims` | `a.unsqueeze(0)` |
| 去掉维度 | `np.squeeze` | `a.squeeze()` |
| **求梯度** | ❌ 手动推公式 | ✅ `loss.backward()` |
| **GPU** | ❌ | ✅ `.to('cuda')` |

可以看到，常用 API 几乎一一对应，从 NumPy 迁过来成本很低。**真正的差异只有两点：自动求导和设备迁移**，这也正是深度学习的刚需。

## 六、本节小结

1. **张量 = 多维数组**，深度学习里最常见的是 4 维 `[N, C, H, W]`；看懂 shape，就解决了一半的报错。
2. **Tensor 相比 NumPy 的两个杀手锏**：自动求导（`backward()`）和 GPU 加速（`.to('cuda')`）。
3. **自动求导三步走**：`requires_grad=True` → 写前向 → `backward()`，梯度自动落到叶子节点的 `.grad`。
4. **训练循环四件套**：前向算 loss → `backward()` → `no_grad` 下更新参数 → `zero_()` 清梯度。顺序不能乱，缺一不可。
5. **两个高危坑**：梯度忘记清零（训练跑飞）、in-place 修改叶子节点（直接报错）。

下一篇我们把这个流程封装成 `nn.Module`，正式进入神经网络：用 PyTorch 搭一个多层感知机做分类，看看"层"是怎么堆起来的。

---

> 一句话记住：**NumPy 让你算得快，Tensor 让你"算得快 + 自动求梯度 + 能上 GPU"——这就是深度学习框架存在的意义。**
