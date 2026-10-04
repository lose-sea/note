<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# CNN 卷积神经网络——从卷积核到手写数字识别

## 一、全连接层的致命缺陷

假设你要处理一张 224×224 的彩色图片，做图像分类。

如果直接用全连接层（每个像素连到下一层的每个神经元），第一层假设有 1000 个神经元，参数量是多少？

```
输入维度：224 × 224 × 3 = 150,528
参数量：  150,528 × 1000 ≈ 1.5 亿
```

**1.5 亿个参数，只为了第一层。** 这还只是个小网络。这么大的参数量带来三个问题：

1. **显存爆炸**：光存参数就要几百 MB，训练时的梯度、优化器状态更是翻倍
2. **必然过拟合**：参数量远超实际数据量，模型会把训练集背下来
3. **丢失空间结构**：把图片拉平成一维向量后，"左上角第 3 个像素"和"它右边那个像素"的相邻关系彻底消失了——而相邻关系恰恰是图像最重要的信息

CNN 用两个核心思想解决了这些问题：**局部感受野** 和 **权值共享**。

一句话概括：**人眼识别某个物体时，不需要一次看完整张图，而是先看局部的边缘、纹理，再逐层组合成高级语义。CNN 就是在模仿这个过程。**

## 二、卷积到底在做一件事：找特征

### 1. 卷积核滑动示意

想象一个 3×3 的小窗口（卷积核）在图片上从左到右、从上到下滑动，每停一次就做一次"对应位置相乘再求和"：

```
输入图片（5×5）              卷积核（3×3）           输出特征图（3×3）
┌──┬──┬──┬──┬──┐           ┌──┬──┬──┐
│ 1│ 1│ 1│ 0│ 0│           │ 1│ 0│-1│            第一步算左上角：
├──┼──┼──┼──┼──┤           ├──┼──┼──┤            1×1 + 1×0 + 1×(-1)
│ 0│ 1│ 1│ 1│ 0│     *     │ 1│ 0│-1│  ───────▶  0×1 + 1×0 + 1×(-1)
├──┼──┼──┼──┼──┤           ├──┼──┼──┤            0×1 + 0×0 + 1×(-1)
│ 0│ 0│ 1│ 1│ 1│           │ 1│ 0│-1│            = 0 + 0 - 1 + 0 + 0 - 1 + 0 + 0 - 1 = -3
├──┼──┼──┼──┼──┤           └──┴──┴──┘
│ 0│ 0│ 1│ 1│ 0│
├──┼──┼──┼──┼──┤
│ 0│ 1│ 1│ 0│ 0│           这个卷积核的特点：左列全 1、右列全 -1
└──┴──┴──┴──┴──┘           → 它专门找"左亮右暗"的竖直边缘
```

这就是卷积的本质：**卷积核是一种"特征探测器"**。上面这个核会强烈响应竖直边缘，因为它左右两列一正一负——如果图片里存在从左到右由亮变暗的跳变，输出值就会很大。

至于为什么叫"卷积"：数学上的卷积要先把核翻转 180°，而深度学习里大家都不翻转（其实是互相关），但约定俗成继续叫卷积。

### 2. 三个关键超参数

| 参数 | 作用 | 常见取值 |
| --- | --- | --- |
| kernel_size | 核大小，决定"每次看多大范围" | 3×3（最主流）、5×5、7×7 |
| stride | 步长，决定"每次挪多远" | 1（保细节）、2（做下采样） |
| padding | 边缘补零，控制输出尺寸是否会缩小 | 0、1（same padding） |

输出尺寸计算公式，出问题的时候第一个就该算它：

```
H_out = (H_in + 2×padding - kernel_size) / stride + 1
```

举例：输入 32×32，kernel=3，padding=1，stride=1 → (32+2-3)/1+1 = 32，尺寸不变。这就是所谓的 **same padding**。

### 3. 权值共享：参数量为什么炸不了

同样是找边缘，**图片的左上角和右下角用的是同一个卷积核**。这就是权值共享——一个 3×3 的核从头到尾只有 9 个参数（外加 1 个 bias），不管图片多大。

对比一下：

| 方案 | 参数量 | 说明 |
| --- | --- | --- |
| 全连接 | 输入维度 × 输出神经元数 | 随图片尺寸平方增长 |
| 卷积 | kernel_h × kernel_w × in_channels × out_channels | **与图片尺寸完全无关** |

一个 3×3 卷积处理 64 通道输入、输出 128 通道：3×3×64×128 ≈ 7.4 万参数，比全连接的 1.5 亿少了三个数量级。

## 三、动手实现：先看 numpy 版，再看 PyTorch 版

理解原理最好的方式是亲手实现一次二维卷积。下面这段代码不依赖任何深度学习框架：

```python
import numpy as np

def conv2d_numpy(image, kernel, stride=1, padding=0):
    """
    手写二维卷积（单通道版本），理解 sliding window 用
    image:  (H, W)
    kernel: (kH, kW)
    """
    if padding > 0:
        image = np.pad(image, pad_width=padding, mode="constant", constant_values=0)

    H, W = image.shape
    kH, kW = kernel.shape
    H_out = (H - kH) // stride + 1
    W_out = (W - kW) // stride + 1

    output = np.zeros((H_out, W_out))
    for i in range(H_out):
        for j in range(W_out):
            # 取出当前窗口，与核逐元素相乘后求和
            h_start, w_start = i * stride, j * stride
            window = image[h_start:h_start + kH, w_start:w_start + kW]
            output[i, j] = np.sum(window * kernel)
    return output

# 构造一张"左半边亮、右半边暗"的测试图，中间有一条竖直边缘
img = np.zeros((6, 6))
img[:, :3] = 10
img[:, 3:] = 0

# 竖直边缘检测核
vertical_edge = np.array([[1, 0, -1],
                          [1, 0, -1],
                          [1, 0, -1]])

result = conv2d_numpy(img, vertical_edge, stride=1, padding=0)
print("输入图片：\n", img)
print("\n卷积结果：\n", result)
print(f"\n输出尺寸: {result.shape}")
```

运行结果：

```
输入图片：
 [[10. 10. 10.  0.  0.  0.]
 [10. 10. 10.  0.  0.  0.]
 ...（共 6 行）

卷积结果：
 [[  0.  30.   0.   0.]
 [  0.  30.   0.   0.]
 [  0.  30.   0.   0.]
 [  0.  30.   0.   0.]]
输出尺寸: (4, 4)
```

看到中间那一列醒目的 `30` 了吗？那正是 pic 里从第 3 列跳到第 4 列的竖直边界。卷积核精准地"点亮"了边缘位置——这就是 CNN 第一层在做的事。

真实项目当然用框架。下面是 PyTorch 版本的完整 CNN，跑 MNIST 手写数字识别：

```python
import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision import datasets, transforms
from torch.utils.data import DataLoader

# 1. 数据预处理：注意 ToTensor 会把像素值从 [0,255] 缩到 [0,1]
transform = transforms.Compose([
    transforms.ToTensor(),
    transforms.Normalize((0.1307,), (0.3081,)),   # MNIST 的均值和标准差
])

train_set = datasets.MNIST("./data", train=True, download=True, transform=transform)
test_set  = datasets.MNIST("./data", train=False, download=True, transform=transform)
train_loader = DataLoader(train_set, batch_size=64, shuffle=True)
test_loader  = DataLoader(test_set,  batch_size=1000, shuffle=False)

# 2. 定义 CNN：卷积 → 池化 → 卷积 → 池化 → 全连接
class SimpleCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 32, kernel_size=3, padding=1)   # 1→32 通道
        self.conv2 = nn.Conv2d(32, 64, kernel_size=3, padding=1)  # 32→64 通道
        self.pool = nn.MaxPool2d(2, 2)                            # 2×2 池化，尺寸减半
        self.dropout = nn.Dropout(0.5)
        self.fc1 = nn.Linear(64 * 7 * 7, 128)   # 关键：28→14→7，两次池化后是 7×7
        self.fc2 = nn.Linear(128, 10)           # 10 类数字

    def forward(self, x):
        x = self.pool(F.relu(self.conv1(x)))   # (1,28,28) → (32,14,14)
        x = self.pool(F.relu(self.conv2(x)))   # (32,14,14) → (64,7,7)
        x = torch.flatten(x, 1)                # 展平成 (batch, 64*7*7)
        x = F.relu(self.fc1(x))
        x = self.dropout(x)
        return self.fc2(x)                     # 最后一层不加激活，交给 CrossEntropyLoss

model = SimpleCNN()
optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
criterion = nn.CrossEntropyLoss()

# 3. 训练循环
def train(epochs=3):
    model.train()
    for epoch in range(epochs):
        total_loss = 0.0
        for batch_x, batch_y in train_loader:
            optimizer.zero_grad()            # ① 清零梯度（忘了必炸）
            out = model(batch_x)             # ② 前向
            loss = criterion(out, batch_y)   # ③ 算损失
            loss.backward()                  # ④ 反向传播
            optimizer.step()                 # ⑤ 更新参数
            total_loss += loss.item()

        # 每个 epoch 后评估一次
        model.eval()                         # ⑥ 切到评估模式，关掉 dropout
        correct = 0
        with torch.no_grad():                # 评估时不需要计算梯度，省显存
            for tx, ty in test_loader:
                pred = model(tx).argmax(dim=1)
                correct += (pred == ty).sum().item()
        acc = correct / len(test_set)
        print(f"Epoch {epoch+1}/{epochs} | loss={total_loss/len(train_loader):.4f} | 测试准确率={acc:.4f}")
        model.train()

train(3)
```

典型输出（CPU 上 3 个 epoch 约 2-4 分钟）：

```
Epoch 1/3 | loss=0.1532 | 测试准确率=0.9812
Epoch 2/3 | loss=0.0521 | 测试准确率=0.9885
Epoch 3/3 | loss=0.0374 | 测试准确率=0.9907
```

一个手写的两层 CNN 就能在 MNIST 上做到 **99% 准确率**，这就是卷积结构的威力。

## 四、五个高频踩坑

| 坑 | 现象 | 解决 |
| --- | --- | --- |
| 全连接层输入维度算错 | `RuntimeError: mat1 and mat2 shapes cannot be multiplied` | 用公式反推每层的 H/W，或先 `print(x.shape)` 看实际尺寸 |
| 忘记 `flatten` | 卷积输出是 4 维，直接喂全连接报错 | `torch.flatten(x, 1)` 保留 batch 维 |
| 通道顺序搞混 | 图像颜色错乱 | PyTorch 是 **NCHW**，numpy/OpenCV 是 **HWC**，用 `permute` 转换 |
| 输入没归一化 | loss 不降、训练震荡 | `Normalize` 到均值 0 附近，加速收敛 |
| 忘了 `model.eval()` | 测试准确率莫名比训练低很多 | 评估前切 eval，`torch.no_grad()` 包住推理 |

其中**维度计算**是新手最大的噩梦。记住这条链式推导习惯写法：

```
输入 28×28
conv(padding=1)  → 28×28      [(28+2-3)/1+1 = 28]
pool(2)          → 14×14
conv(padding=1)  → 14×14
pool(2)          → 7×7
flatten          → 64×7×7 = 3136
```

不确定时就 `print(x.shape)`，比猜快十倍。

## 五、经典网络演进一览

| 网络 | 年份 | 核心贡献 | Top-5 错误率 |
| --- | --- | --- | --- |
| LeNet-5 | 1998 | CNN 开山之作，用于支票识别 | — |
| AlexNet | 2012 | ReLU + Dropout + GPU 训练，深度学习复兴 | 15.3% |
| VGG | 2014 | 全部用 3×3 小卷积堆叠，结构规整 | 7.3% |
| GoogLeNet | 2014 | Inception 多尺度并行 | 6.7% |
| ResNet | 2015 | **残差连接**，解决深层网络退化问题 | 3.6% |

ResNet 的残差连接值得单独说一句：网络深到一定程度后，再加层反而让训练误差变大。何恺明等人的解法是加一条"捷径"，让层学习"残差"而不是直接学习目标映射：

```
输入 x ─────────────┐
  │                 │（恒等映射，直接加到输出）
  ▼                 │
权重层 F(x) ────────┴──→ 输出 H(x) = F(x) + x
```

这样一来，即使某层学不到有用特征，让 F(x) → 0 就能退化成恒等映射，**至少不会比不加这层更差**。这个朴素的思想把网络深度从几十层推到了上千层。

## 六、小结

1. CNN 解决的三个问题：**参数量爆炸、丢失空间结构、必然过拟合**，靠的是局部感受野 + 权值共享
2. 卷积核本质是**特征探测器**：固定的一组权重，专门抽出某种边缘/纹理模式
3. 尺寸公式 `(H + 2p - k) / s + 1` 必须手算得出来，不然搭网络时会卡死
4. PyTorch 搭 CNN 的套路：**卷积(+padding=1) → 池化(/2) → 重复 → flatten → 全连接**
5. 数据维度是 NCHW，归一化、eval 模式、no_grad，这三个忘了就会得到奇怪的结果

下一篇我会接着讲 CNN 的实战进阶：数据增强、迁移学习，以及如何用预训练模型在几百张图的小数据集上做出可用的分类器。

> 一句话总结：**全连接记住的是"像素的位置"，卷积学到的是"特征的模式"。**
