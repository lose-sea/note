<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# 卷积神经网络实战——手算一次卷积与池化，彻底搞懂 CNN 为什么能看懂图

## 一、先想清楚一个问题：全连接网络为什么处理不了图片

拿一张 224×224 的彩色图片算笔账：224 × 224 × 3 = 150,528 个像素值。

如果用全连接层，第一层就设 1000 个神经元，参数量是：

```
150,528 × 1,000 = 150,528,000  ≈ 1.5 亿个参数
```

仅仅第一层就 1.5 亿参数，还不算内存和计算量。更致命的是——**全连接层把每个像素当成独立特征，完全丢掉了图像的空间结构**。把图片整体平移 3 个像素，对全连接网络来说就是一组全新的输入。

CNN 用两个核心假设解决了这个问题：

```
┌──────────────────────────────────────────────────────────────┐
│  CNN 的两个关键假设（归纳偏置）                                │
├──────────────────────────────────────────────────────────────┤
│  ① 局部性  一个像素只和它周围的一小块像素强相关                 │
│            → 用一个小卷积核（如 3×3）在整张图上滑动             │
│  ② 平移不变性  猫挪到图片左边还是右边，它都是猫                │
│            → 同一组卷积核权重在整张图上共享（权值共享）         │
└──────────────────────────────────────────────────────────────┘
```

这两个假设把参数量从 1.5 亿降到几千个，而且让模型真正"看得懂"图。下面我们把卷积的每一步手算一遍。

## 二、卷积到底在算什么

一句话：**卷积核在输入上滑动，每个位置做一次"逐元素相乘再求和"。**

用一个 4×4 输入和 3×3 卷积核举例：

```
输入 (4×4)              卷积核 (3×3)
 1   2   0   1          1   0   1
 0   1   2   1          0   1   0
 1   0   1   0          1   0   1
 2   1   0   1
```

卷积核先盖在左上角 3×3 区域上，做点积：

```
 1×1 + 2×0 + 0×1
+0×0 + 1×1 + 2×0
+1×1 + 0×0 + 1×1
= 1 + 0 + 0 + 0 + 1 + 0 + 1 + 0 + 1 = 4
```

然后把核向右滑一格，再算一次，直到滑完：

```
输出 (2×2)
 4   5
 3   4
```

这个过程用 ASCII 画出来就是：

```
步长 stride=1, 无 padding
输入 4×4            扫描位置            输出 2×2
┌───────────┐      ┌─────┐
│ 1  2  0  1│      │▣▣▣  │  → 4
│ 0  1  2  1│      │▣▣▣  │
│ 1  0  1  0│      └─────┘
│ 2  1  0  1│        ┌─────┐
└───────────┘        │ ▣▣▣ │  → 5
                     │ ▣▣▣ │
                     └─────┘
   ... 共 (4-3+1) × (4-3+1) = 4 个位置
```

**输出尺寸公式**（必须记住）：

```
输出边长 = (输入边长 - 卷积核边长 + 2×padding) / stride + 1(向下取整)

例：(4 - 3 + 0) / 1 + 1 = 2      → 输出 2×2
```

## 三、代码实战：用 NumPy 手写卷积

先用最原始的双重循环实现一遍——虽然慢，但能把每一步看清。

```python
import numpy as np

def conv2d_naive(image, kernel, stride=1, padding=0):
    """最朴素的二维卷积实现，便于理解每一步在做什么"""
    if padding > 0:
        # np.pad 在四周补 padding 圈 0
        image = np.pad(image, padding, mode="constant", constant_values=0)
    h, w = image.shape
    kh, kw = kernel.shape
    # 输出尺寸公式
    out_h = (h - kh) // stride + 1
    out_w = (w - kw) // stride + 1
    out = np.zeros((out_h, out_w), dtype=np.float32)

    for i in range(out_h):
        for j in range(out_w):
            r, c = i * stride, j * stride          # 滑动到当前窗口左上角
            window = image[r:r + kh, c:c + kw]      # 取出感受野
            out[i, j] = np.sum(window * kernel)     # 逐元素相乘再求和
    return out

image = np.array([[1, 2, 0, 1],
                  [0, 1, 2, 1],
                  [1, 0, 1, 0],
                  [2, 1, 0, 1]], dtype=np.float32)
kernel = np.array([[1, 0, 1],
                   [0, 1, 0],
                   [1, 0, 1]], dtype=np.float32)

print("朴素卷积输出：\n", conv2d_naive(image, kernel))
print("输出形状：", conv2d_naive(image, kernel).shape)
```

输出：

```
朴素卷积输出：
 [[4. 5.]
  [3. 4.]]
输出形状： (2, 2)
```

和我们手算的结果完全一致。现在换成 PyTorch 的 `nn.Conv2d` 验证一下，确保理解没错：

```python
import torch
import torch.nn as nn

x = torch.tensor(image).view(1, 1, 4, 4)          # (batch, channel, H, W)
conv = nn.Conv2d(1, 1, kernel_size=3, stride=1, padding=0, bias=False)
with torch.no_grad():
    conv.weight.copy_(torch.tensor(kernel).view(1, 1, 3, 3))

print("PyTorch 卷积输出：\n", conv(x).squeeze().numpy())
assert np.allclose(conv(x).squeeze().numpy(), conv2d_naive(image, kernel))
print("✓ 手写实现与 PyTorch 结果一致")
```

## 四、池化：把特征图"浓缩"

池化（Pooling）的作用是**下采样**——保留显著特征，同时缩小尺寸、减少计算量，并带来一定的平移鲁棒性。

最常见的两种：

```
最大池化 Max Pooling          平均池化 Average Pooling
取窗口内最大值                 取窗口内平均值

    输入 4×4（2×2窗口，stride=2）
┌─────────────┐
│ 1  3 │ 2  4 │
│ 5  6 │ 1  0 │      max →   6   4
├──────┼──────┤      avg →   3.75  1.75
│ 2  1 │ 7  8 │
│ 0  4 │ 3  2 │
└─────────────┘
   每个 2×2 窗口压成 1 个数 → 输出 2×2
```

代码实现和验证：

```python
def maxpool2d_naive(feature_map, size=2, stride=2):
    h, w = feature_map.shape
    oh, ow = (h - size) // stride + 1, (w - size) // stride + 1
    out = np.zeros((oh, ow), dtype=np.float32)
    for i in range(oh):
        for j in range(ow):
            out[i, j] = feature_map[i*stride:i*stride+size,
                                    j*stride:j*stride+size].max()
    return out

fm = np.array([[1, 3, 2, 4],
               [5, 6, 1, 0],
               [2, 1, 7, 8],
               [0, 4, 3, 2]], dtype=np.float32)

print("手写最大池化：\n", maxpool2d_naive(fm))

# 用 PyTorch 对照
pool = nn.MaxPool2d(kernel_size=2, stride=2)
print("PyTorch MaxPool2d：\n",
      pool(torch.tensor(fm).view(1, 1, 4, 4)).squeeze().numpy())
```

输出：

```
手写最大池化：
 [[6. 4.]
  [4. 8.]]
PyTorch MaxPool2d：
 [[6. 4.]
  [4. 8.]]
```

**注意 MaxPool2d 没有可学习参数**——它只做取最大值，不需要训练；`Conv2d` 才有 weight 和 bias 需要学习。

## 五、搭一个真正能跑的小 CNN

把卷积、池化、全连接串起来，做一个手写数字识别（用随机数据演示结构，换成 MNIST 即可直接用）：

```python
import torch
import torch.nn as nn
import torch.nn.functional as F

class SmallCNN(nn.Module):
    """输入 1×28×28 灰度图，输出 10 分类"""
    def __init__(self, num_classes=10):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 16, kernel_size=3, padding=1)    # 28×28 → 28×28
        self.conv2 = nn.Conv2d(16, 32, kernel_size=3, padding=1)   # 14×14 → 14×14
        self.pool = nn.MaxPool2d(2)                                 # 尺寸减半
        self.dropout = nn.Dropout(0.25)
        self.fc = nn.Linear(32 * 7 * 7, num_classes)                # 32×7×7 → 10

    def forward(self, x):
        x = self.pool(F.relu(self.conv1(x)))   # 28→14
        x = self.pool(F.relu(self.conv2(x)))   # 14→7
        x = torch.flatten(x, 1)                # 展平成向量，从第1维开始展
        x = self.dropout(x)
        return self.fc(x)                      # 返回 logits

model = SmallCNN()
dummy = torch.randn(4, 1, 28, 28)
print("输入:", dummy.shape, "→ 输出:", model(dummy).shape)

# 逐层打印特征图尺寸变化，这是调 CNN 时最实用的排查手段
def trace_shapes(model, x):
    print(f"input          {tuple(x.shape)}")
    x = model.pool(F.relu(model.conv1(x)));  print(f"conv1+pool     {tuple(x.shape)}")
    x = model.pool(F.relu(model.conv2(x)));  print(f"conv2+pool     {tuple(x.shape)}")
    x = torch.flatten(x, 1);                 print(f"flatten        {tuple(x.shape)}")
    x = model.fc(x);                         print(f"fc(logits)     {tuple(x.shape)}")

trace_shapes(model, dummy)
```

输出：

```
输入: torch.Size([4, 1, 28, 28]) → 输出: torch.Size([4, 10])
input          (4, 1, 28, 28)
conv1+pool     (4, 16, 14, 14)
conv2+pool     (4, 32, 7, 7)
flatten        (4, 1568)
fc(logits)     (4, 10)
```

`flatten` 后的 1568 = 32 × 7 × 7。**如果全连接层输入维度写错，报错信息通常是 "mat1 and mat2 shapes cannot be multiplied"，这时就用 `trace_shapes` 一路打出来看形状在哪一步对不上。**

## 六、卷积参数速查表

| 概念 | 含义 | 关键取值 / 影响 |
|---|---|---|
| kernel_size | 卷积核尺寸 | 3×3 最常用（参数少、感受野够）；5×5、7×7 参数更多 |
| stride | 滑动步长 | 1 保持尺寸（配 padding=1）；2 尺寸减半 |
| padding | 边缘补零圈数 | 3×3 核配 padding=1 可保持尺寸不变 |
| channels | 输出通道数 | 逐层递增（16→32→64），形成多组特征检测器 |
| 感受野 | 一个输出点能看到输入多大范围 | 层数越多、核越大，感受野越大 |
| 参数量 | `(k×k×in_c + 1) × out_c` | 3×3、in=16、out=32 → (9×16+1)×32 = 4640 |

对照感受一下两种实现方式的代价差异：

```
3×3 卷积（in=16, out=32）：  4,640 个参数
同样输入输出的全连接：       16×32 × ... 参数量随尺寸平方增长
```

这就是 CNN 能在图像任务上取代全连接网络的根本原因。

## 七、几个常见的坑

**坑 1：把 `flatten` 的起始维度写错。**
`x.view(-1)` 会把整个 batch 拍平成一维，彻底丢掉 batch 维度；必须用 `torch.flatten(x, 1)` 或 `x.view(x.size(0), -1)`，从第 1 维（channel）开始展平。

**坑 2：`padding=1` 与 `kernel=3` 的关系记反。**
保持特征图尺寸不变的条件是 `padding = (kernel - 1) / 2`，所以 3×3 配 1，5×5 配 2。写成 3×3 配 2 尺寸反而会变大。

**坑 3：以为池化层有参数要训练。**
`MaxPool2d` 和 `AvgPool2d` 都是纯计算，无参数。打印 `model.parameters()` 时看不到它们，不要以为模型没加载成功。

**坑 4：卷积核权重可视化当成"图像"。**
卷积核是学出来的数值矩阵，不是图片。用 `matplotlib.imshow(weight[0,0])` 能看到边缘检测器的纹理，但它本身没有语义。

**坑 5：忘记 `channels` 通道对应关系。**
输入是彩色图时 `in_channels=3`，灰度图是 1；`Conv2d(in, out, ...)` 的 `in` 必须等于上一层输出的通道数，两层之间通道数对不上就会报错。

## 八、小结

CNN 的全部魔法可以压缩成两句话：

```
卷积 = 用共享的小核在图上滑动，提取局部特征（权值共享 → 参数少）
池化 = 按窗口降采样，保留显著特征、提升平移鲁棒性（无参数 → 不训练）
```

理解了"滑窗 + 点积 + 权值共享"，你就理解了 CNN。剩下的 LeNet、VGG、ResNet，无非是在**层数更深、通道更多、加了残差连接**上做工程优化，核心机制没有任何变化。

建议动手做一遍：把手写卷积的 `conv2d_naive` 改成支持多通道，再换成 MNIST 数据集跑 1 个 epoch，看着准确率从 10% 涨到 95%+ ——那个瞬间，CNN 就真的从公式变成了你的工具。
