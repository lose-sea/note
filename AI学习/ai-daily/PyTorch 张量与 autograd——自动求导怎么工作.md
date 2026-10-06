<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# PyTorch 张量与 autograd——自动求导怎么工作

**承上**：上一篇《神经网络与反向传播原理》我们手推了每一个梯度，写得很爽也很累。

**本篇**：本篇把它交给 PyTorch：Tensor、requires_grad、backward 自动求导。

**启下**：下一篇《用 nn.Module 搭建你的第一个神经网络》用积木化组件搭真正的网络。

**学完这一节，你能动手做**：

1. 用 autograd 十几行重写之前四十行的训练代码
2. 避开梯度累加、in-place 修改、推理忘关 no_grad 这三大坑
3. 正确把张量与模型搬到 GPU / MPS 设备并统一 dtype


上一篇我们手写了两层网络的前向、反向、梯度检查——写得很爽，但也很累。真实模型有几十亿参数、上百层，手推梯度是不可能的。

**PyTorch 的 autograd（自动求导）就是来解放你的**：你只写前向，它自动帮你算所有梯度。

但要真正用对 autograd，必须理解它**怎么工作**——否则你会踩到"梯度没清零""in-place 报错""推理时显存爆了"这些经典坑。这一篇把它讲透。

## 一、安装与验证

```bash
pip install torch torchvision
```

```python
import torch
print(torch.__version__)
print("CUDA 可用:", torch.cuda.is_available())
print("MPS(Mac GPU) 可用:", torch.backends.mps.is_available())
print("设备:", torch.device("cuda" if torch.cuda.is_available()
                        else "mps" if torch.backends.mps.is_available() else "cpu"))
```

**没有 GPU 也能学完整个专栏**——基础实验 CPU 完全够用，只是大模型训练慢。

## 二、Tensor：PyTorch 的核心数据结构

Tensor 就是"能在 GPU 上跑、能自动求导的多维数组"，可以理解为 NumPy 的升级版。

```python
import torch
import numpy as np

# 创建
a = torch.tensor([1.0, 2.0, 3.0])
b = torch.zeros(2, 3)
c = torch.ones(2, 3)
d = torch.randn(2, 3)                    # 标准正态
e = torch.arange(0, 10, 2)               # [0,2,4,6,8]
f = torch.eye(3)                         # 单位矩阵

print(a, a.shape, a.dtype)

# 与 NumPy 互转
np_arr = np.array([[1, 2], [3, 4]])
t = torch.from_numpy(np_arr)             # numpy → tensor（共享内存！）
back = t.numpy()                         # tensor → numpy

# 常用属性（和 NumPy 一致）
x = torch.randn(3, 4)
print(x.shape, x.dtype, x.device, x.requires_grad)
```

### 与 NumPy 的关键差异

| | NumPy | PyTorch Tensor |
|---|---|---|
| GPU 加速 | ❌ | ✅ `.cuda()` / `.to("mps")` |
| 自动求导 | ❌ | ✅ `requires_grad=True` |
| 维度排列 | HWC（图像常用） | **CHW**（卷积要求） |
| 默认 dtype | float64 | **float32** |

```python
# 类型转换（深度学习几乎都用 float32）
x = torch.tensor([1, 2, 3])              # int64
print(x.dtype)
print(x.float().dtype)                   # float32
print(x.to(torch.float32).dtype)

# 形状操作
y = torch.randn(2, 3, 4)
print(y.reshape(6, 4).shape)             # 或 y.view(6,4)
print(y.unsqueeze(0).shape)              # (1,2,3,4) 加一维（batch 维度常用）
print(y.squeeze().shape)                 # 去掉所有长度为1的维
print(y.permute(2, 0, 1).shape)          # (4,2,3) 维度重排（图像 CHW↔HWC）
```

### 矩阵运算（和 NumPy 几乎一样）

```python
A = torch.randn(3, 4)
B = torch.randn(4, 5)

print((A @ B).shape)                     # (3,5) 矩阵乘法
print(torch.matmul(A, B).shape)
print((A * A).shape)                     # 逐元素相乘（形状不变）

# 求和/均值（深度学习里算 loss 常用）
print(A.sum(), A.mean(), A.mean(dim=0).shape)   # dim=0 沿行方向压缩 → (4,)
```

## 三、autograd：自动求导的心脏

### 3.1 requires_grad：告诉 PyTorch"盯着这个变量"

```python
x = torch.tensor([2.0], requires_grad=True)
w = torch.tensor([3.0], requires_grad=True)
b = torch.tensor([1.0], requires_grad=True)

y = w * x + b              # y = 3*2 + 1 = 7
print("y =", y)
print("y.grad_fn =", y.grad_fn)     # <AddBackward0> ← PyTorch 已记录了运算！
```

**只要输入的 `requires_grad=True`，运算结果就会自动带上 `grad_fn`**——这是构建计算图的痕迹。

### 3.2 backward()：一键算所有梯度

```python
y.backward()               # 从 y 开始反向传播

print("dy/dx =", x.grad)   # 3.0  (= w)
print("dy/dw =", w.grad)   # 2.0  (= x)
print("dy/db =", b.grad)   # 1.0
```

和我们手推的完全一致。**这就是 autograd**：它在前向时记录每张"运算卡片"，`backward()` 时按链式法则倒着走一遍。

### 3.3 计算图长什么样

```python
a = torch.tensor([1.0], requires_grad=True)
b = torch.tensor([2.0], requires_grad=True)
c = a * b          # c = 2
d = c + 1          # d = 3
e = d ** 2         # e = 9

print("c.grad_fn:", c.grad_fn)   # MulBackward
print("d.grad_fn:", d.grad_fn)   # AddBackward
print("e.grad_fn:", e.grad_fn)   # PowBackward

e.backward()
print("de/da =", a.grad)   # 手推: de/da = 2*d*b = 2*3*2 = 12
print("de/db =", b.grad)   # 手推: de/db = 2*d*a = 2*3*1 = 6

# 验算：手算链式法则
print("手算 da:", 2 * (a*b + 1).item() * b.item())
```

### 3.4 非标量输出：需要传 gradient

```python
x = torch.randn(3, requires_grad=True)
y = x * 2
print(y)      # 向量

# 向量对向量求导会报错，需要指定"上游梯度"
try:
    y.backward()
except RuntimeError as err:
    print("报错:", err)

# 正确做法：传一个同形状的权重向量（通常是 loss 的梯度）
y.backward(torch.tensor([1.0, 1.0, 1.0]))
print(x.grad)   # [2,2,2]

# 实践中更常见：先聚合成标量
x2 = torch.randn(3, requires_grad=True)
loss = (x2 * 2).sum()      # 标量
loss.backward()
print(x2.grad)             # [2,2,2]
```

**实践中几乎总是先 `.sum()` 或 `.mean()` 得到标量 loss，再 backward**。

## 四、梯度累加：新手第一大坑

```python
w = torch.tensor([1.0], requires_grad=True)

for step in range(3):
    y = w * 2
    y.backward()
    print(f"step {step}: grad = {w.grad.item()}")

# 期望每次都是 2.0，实际是 2, 4, 6 —— 梯度被累加了！
```

**PyTorch 默认累加梯度**（`grad += new_grad`），不会自动清零。因为有些场景需要累加（比如大 batch 拆成小 batch 模拟）。

**正确写法**：

```python
w = torch.tensor([1.0], requires_grad=True)
optimizer_lr = 0.1

for step in range(3):
    if w.grad is not None:
        w.grad.zero_()          # ← 清零（或者用 optimizer.zero_grad()）
    y = w * 2
    y.backward()
    with torch.no_grad():       # 更新参数时不该被记录进计算图
        w -= optimizer_lr * w.grad
    print(f"step {step}: w = {w.item():.3f}, grad = {w.grad.item()}")
```

**忘记 `zero_grad()` 是深度学习最常见的 bug**——表现为 loss 诡异、训练不收敛。

## 五、torch.no_grad()：推理与参数更新必用

```python
x = torch.randn(3, requires_grad=True)

with torch.no_grad():
    y = x * 2
print("no_grad 下 y.requires_grad =", y.requires_grad)   # False

# 用途 1：参数更新（前面见过）
# 用途 2：推理/评估（省显存、提速）
def predict(model, x):
    with torch.no_grad():          # 推理时不建图，显存占用大减
        return model(x)

# 用途 3：把张量转成普通数值
with torch.no_grad():
    val = x.sum().item()
print("item():", val, type(val))
```

**为什么推理必须用 `no_grad()`？** 因为构建计算图要保存每一层的中间激活，**这部分显存开销巨大**。推理时不需要梯度，省掉它能让 batch 大一倍。

### detach()：把张量从图上摘下来

```python
x = torch.randn(2, requires_grad=True)
y = x * 3
z = y.detach()             # z 与 y 共享数据，但不再参与求导
print("y.requires_grad:", y.requires_grad)   # True
print("z.requires_grad:", z.requires_grad)   # False

# 典型场景：GAN、强化学习中需要截断梯度流
```

## 六、in-place 操作的陷阱

```python
x = torch.randn(3, requires_grad=True)
y = x ** 2

# ❌ 危险：in-place 修改叶子节点
try:
    x.add_(1.0)               # 带下划线 = in-place
    y.backward()
except RuntimeError as e:
    print("报错:", str(e)[:90])

# ✅ 安全写法
x = torch.randn(3, requires_grad=True)
y = (x + 1.0) ** 2            # 用 out-of-place
y.sum().backward()
print("安全:", x.grad)
```

**规则**：带下划线的方法（`add_`、`mul_`、`zero_`）是 in-place，会修改原张量。**不要对需要求导的叶子张量做 in-place 修改**。

不过 `.zero_()` 用在 `.grad` 上是安全的（梯度不需要再被求导）。

## 七、实战：用 autograd 重写线性回归

上一篇手写版要 40 行，PyTorch 版只要十几行：

```python
import torch
torch.manual_seed(42)

# 1) 造数据
n, d = 200, 3
X_np = np.random.randn(n, d)
w_true = np.array([[2.0], [-3.0], [1.5]])
y_np = X_np @ w_true + 0.5 + np.random.randn(n, 1) * 0.3

X = torch.from_numpy(X_np).float()
y = torch.from_numpy(y_np).float()

# 2) 初始化参数（requires_grad=True 让 PyTorch 自动追踪）
W = torch.randn(d, 1, requires_grad=True)
b = torch.zeros(1, requires_grad=True)

# 3) 训练
lr, epochs = 0.1, 300
for ep in range(epochs):
    if W.grad is not None:
        W.grad.zero_(); b.grad.zero_()

    y_pred = X @ W + b                          # 前向
    loss = torch.mean((y_pred - y) ** 2)        # MSE

    loss.backward()                             # 自动反向！

    with torch.no_grad():                       # 更新
        W -= lr * W.grad
        b -= lr * b.grad

    if ep % 60 == 0 or ep == epochs - 1:
        print(f"epoch {ep:3d}  loss={loss.item():.4f}")

print("\n学到的 W:", W.detach().flatten().numpy().round(3))
print("真实的 W:", w_true.flatten())
print("学到的 b:", b.detach().numpy().round(3), " 真实 b: [0.5]")
```

**对比手写版**：梯度那几行（最易出错的部分）全没了，`loss.backward()` 一行搞定。

## 八、手写 autograd 验证：它到底在算什么

为了确信 autograd 不是黑魔法，我们做一次梯度检查：

```python
def check_autograd():
    torch.manual_seed(0)
    W = torch.randn(3, 1, requires_grad=True)
    b = torch.zeros(1, requires_grad=True)
    Xs = torch.randn(10, 3)
    ys = torch.randn(10, 1)

    loss = torch.mean((Xs @ W + b - ys) ** 2)
    loss.backward()

    # 数值梯度
    eps = 1e-4
    for i in range(3):
        W_plus = W.detach().clone(); W_plus[i] += eps
        W_minus = W.detach().clone(); W_minus[i] -= eps
        lp = torch.mean((Xs @ W_plus + b.detach() - ys) ** 2)
        lm = torch.mean((Xs @ W_minus + b.detach() - ys) ** 2)
        numeric = (lp - lm).item() / (2 * eps)
        print(f"W[{i}]  解析={W.grad[i].item(): .6f}  数值={numeric: .6f}  "
              f"误差={abs(W.grad[i].item()-numeric):.2e}")

check_autograd()
```

误差在 `1e-6` 量级——**autograd 算的就是链式法则，和我们在阶段 2 手推的一模一样**。

## 九、设备管理：CPU / GPU / MPS

```python
device = torch.device("cuda" if torch.cuda.is_available()
                      else "mps" if torch.backends.mps.is_available()
                      else "cpu")
print("使用设备:", device)

# 把张量/模型搬到设备上
x_cpu = torch.randn(2, 3)
x_dev = x_cpu.to(device)
print("x_dev.device:", x_dev.device)

# 常见错误：一个在 CPU 一个在 GPU
try:
    if device.type == "cuda":
        bad = x_cpu + x_dev
except RuntimeError as e:
    print("跨设备运算报错（预期）")
```

**训练时的标准写法**：`X, y = X.to(device), y.to(device)` 和 `model.to(device)`。

数据类型也要匹配：

```python
a = torch.randn(2, 3, dtype=torch.float32)
b = torch.randn(2, 3, dtype=torch.float64)
try:
    a + b
except RuntimeError as e:
    print("dtype 不匹配报错:", str(e)[:60])
# 解决：统一 .float() 或 .to(torch.float32)
```

## 十、常见坑与注意事项

| 坑 | 现象 | 解决 |
|---|---|---|
| 忘记 `zero_grad()` | 梯度累加，loss 诡异 | 每步 `optimizer.zero_grad()` |
| 推理没用 `no_grad()` | 显存爆、速度慢 | `with torch.no_grad():` |
| in-place 改叶子张量 | RuntimeError | 用 out-of-place 运算 |
| 设备不一致 | Expected all tensors on same device | 统一 `.to(device)` |
| dtype 不一致 | Expected Float got Double | 统一 `.float()` |
| 对向量直接 backward | grad can be implicitly created only for scalar | 先 `.sum()` 或传 gradient |
| 用 `.data` 改参数 | 绕过追踪，可能出错 | 用 `torch.no_grad()` |
| 忘了 `.item()` | 打印出 tensor(...) | 标量取 `.item()` |

**记忆口诀**：`zero_grad` → `forward` → `loss` → `backward` → `step`（更新），五步循环。

## 十一、本篇小结

1. **Tensor = 能上 GPU + 能自动求导的数组**，API 与 NumPy 高度相似（`@` 矩阵乘法、`*`、`reshape`、`permute`）。
2. **`requires_grad=True`** 让 PyTorch 追踪运算；前向时自动建图（每个输出带 `grad_fn`）。
3. **`loss.backward()`** 沿计算图倒着应用链式法则，把所有 `requires_grad` 变量的梯度填进 `.grad`。
4. **梯度默认累加**，必须手动清零；**推理/更新用 `torch.no_grad()`** 省显存；**避免 in-place 修改叶子张量**。
5. 我们用 autograd 重写了线性回归，并用数值梯度验证——**autograd 算的就是我们手推的链式法则**。
6. 设备管理：统一 `device` 和 `dtype`，`X.to(device)` / `.float()`。

下一篇 **用 nn.Module 搭建你的第一个神经网络**：不再手动定义 `W1/b1/W2/b2`，用 PyTorch 的 `nn.Linear`、`nn.ReLU`、`nn.Sequential` 搭积木，学会参数管理、`forward()` 写法，并搭出一个真正的多层感知机（MLP）。

> 本篇是《大模型开发从 0 到 1》专栏第 23 篇，阶段 4「深度学习与 PyTorch」第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
