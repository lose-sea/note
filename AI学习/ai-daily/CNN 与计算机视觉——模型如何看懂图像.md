<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# CNN 与计算机视觉——模型如何看懂图像

**承上**：上一篇《训练循环实战——优化器、损失与 epoch》我们有了通用训练模板，但输入一直是扁平向量。

**本篇**：本篇处理图像：卷积、池化、残差连接，并理解 ViT 如何把图像切成 patch。

**启下**：下一篇《RNN 与 LSTM 序列建模——处理文本与时间序列》处理有先后顺序的序列数据，收官阶段 4。

**学完这一节，你能动手做**：1) 能手算一次卷积、并用公式核对任意输入输出尺寸 2) 能搭出完整 CNN 分类器并可视化第一层特征图 3) 能理解 patch 化之后，Transformer 为何能统一处理图文。

前面我们用的都是全连接层（`nn.Linear`），输入是"扁平的一个向量"。但图像是 **H×W×C 的三维结构**（高×宽×通道），直接拍扁会**丢掉空间关系**——像素之间的邻居关系才是图像最重要的信息。

**CNN（卷积神经网络）** 就是为此而生。它用一个天才的设计——**卷积核**——既保留了空间结构，又把参数量降到全连接的几百分之一。

这一篇你会：理解卷积在干什么、亲手实现一个卷积、看懂特征图、搭出完整 CNN 分类器，并最终理解**为什么大模型时代 CNN 让位给了 Transformer**。

## 〇、概念引入与背景：图像到底特殊在哪？

先看一个被忽略的事实：一张 224×224 的彩色照片，对计算机来说不是「一张图」，而是一堆数字。它有三个维度——**高度 H、宽度 W、通道 C（RGB 三通道）**。所谓「通道」，就是 R（红）、G（绿）、B（蓝）三张灰度图叠在一起，每个位置存一个 0~255 的强度值。

关键问题是：**像素之间不是孤立的**。一个「猫耳朵」由几十个相邻像素共同构成，它们彼此的位置关系才是「耳朵」的含义。如果像 MLP 那样把整张图拉成一条 150528 维的向量，左上角像素和它右边像素在向量里可能隔了几百个位置——模型根本无从知道「谁和谁相邻」。这正是全连接处理图像的天花板：**它把空间结构当成了无序的特征袋。**

CNN 的核心洞察只有一句话：**图像里「有用的模式」往往是局部、平移不变的**。「边缘」「角点」「纹理」在图的左上角和右下角，本质是一样的特征，只是位置不同。既然如此，与其给每个位置学一套独立参数（全连接的做法），不如让同一个「小探测器」滑过整张图去探测同一类模式——这就是**卷积**。这套「局部性 + 权值共享」的先验，让 CNN 既省参数又契合图像本质，于是统治 CV 近十年。

从大模型视角看，CNN 是理解 Transformer 的「对照物」：你马上会看到，Transformer 故意放弃了 CNN 这种强先验，改用「注意力」从数据里自己学关系，在大数据下反而赢了。而 ViT（Vision Transformer）又用「把图切成 patch 当词」把两者统一——所以本篇是理解后两篇（RNN、Attention）的关键桥梁。

## 一、为什么全连接不适合图像？

算一笔账：一张 224×224×3 的彩色图，第一个隐藏层 1000 个神经元：

```python
import numpy as np
import torch
import torch.nn as nn

h, w, c = 224, 224, 3
flat = h * w * c
print("拍扁后的维度:", flat)                       # 150,528
print("全连接一层参数量:", flat * 1000)             # 1.5 亿 —— 光一层就炸了
print("还只有一层，且完全忽略了像素的空间邻居关系")
```

两个致命问题：
1. **参数爆炸**（1.5 亿），必然过拟合；
2. **丢失空间结构**——把图像拉成一条线后，"左上角"和"它右边的像素"在向量里可能隔了几百个位置。

CNN 用两个思想解决：**局部感受野** + **权值共享**。

把这两个问题展开讲。参数量 1.5 亿意味着什么？训练一个参数需要它在大量样本上被反复更新、需要存它的梯度和动量——1.5 亿参数即使只占 4 字节也要 600MB 显存，还只是**第一层**，后面还有更多层，更要命的是这么参数需要海量数据才喂得饱，否则必然过拟合（在训练集背答案、测试集懵）。这还没算「空间结构丢失」：全连接对「(10,10) 和 (11,10) 是邻居」一无所知，它把像素当成一个无序的特征列表。CNN 的两个思想正是针对这两点：①**局部感受野**——每个神经元只看输入的一小块（邻域），自然保留局部结构；②**权值共享**——这块「探测器」的参数在整张图上复用，参数从 1.5 亿骤降到几十个。下面逐层看它怎么做到。

## 二、卷积：一个小窗口滑过整张图

### 2.1 直观理解

想象拿一个 3×3 的小窗口（**卷积核 / filter**），在图像上从左到右、从上到下滑动，每停一次就做"对应位置相乘再求和"，得到一个数字。所有数字拼起来就是一张新的图——**特征图（feature map）**。

```python
def conv2d_manual(image, kernel, stride=1, padding=0):
    """从零实现 2D 卷积：image (H,W), kernel (k,k)"""
    if padding > 0:
        image = np.pad(image, padding, mode="constant")
    H, W = image.shape
    k = kernel.shape[0]
    out_h = (H - k) // stride + 1
    out_w = (W - k) // stride + 1
    out = np.zeros((out_h, out_w))
    for i in range(out_h):
        for j in range(out_w):
            region = image[i*stride:i*stride+k, j*stride:j*stride+k]
            out[i, j] = np.sum(region * kernel)
    return out

# 用一个边缘检测核测试
image = np.zeros((8, 8))
image[:, 3:] = 1.0            # 左半黑、右半白 → 中间有一条竖直边缘

edge_kernel = np.array([[-1, 0, 1],
                        [-1, 0, 1],
                        [-1, 0, 1]], dtype=float)

feat = conv2d_manual(image, edge_kernel)
print("原始图像:\n", image.astype(int))
print("\n边缘检测后的特征图:\n", feat.astype(int))
```

**特征图上那条明显非零的列，就是"边缘"的位置**。这就是 CNN "看"世界的方式：第一层找边缘，第二层找纹理，第三层找形状，越往后越抽象。

把卷积的「滑动相乘求和」拆开理解：`region`（窗口盖住的 3×3 小图）和 `kernel`（3×3 的权重）逐元素相乘再求和，等于「这个局部区域的图像，在多大程度上匹配这个核描述的特征」。比如上面的 `edge_kernel`：中间列是 0、左右列是 -1 和 +1——它衡量「左边暗、右边亮」的差值。当窗口盖在「左黑右白」的边缘处，左右差值大，输出就大；盖在纯黑或纯白区域，左右都一致，差值小，输出近 0。于是特征图里**只有在边缘那一列被点亮**——这就是「边缘检测器」的来历。

更重要的一点：**卷积核的权重是可学习的**。上面我们用的是人工设计（Sobel 边缘核），但 CNN 里这些核由反向传播自动学出来——第一层学会「各种朝向的边缘/颜色块」，第二层把边缘组合成「纹理/角」，第三层组合成「眼睛/轮子」，逐层抽象。你在本篇第七节会亲眼看到第一层学到的特征图长什么样，那个「啊哈」时刻很值得等。

再看一遍卷积在空间上的意义——用一张 ASCII 图表示「一次滑动」：

```
图像 (8×8)              卷积核 (3×3)            特征图 (6×6)
┌─────────┐            ┌───────┐            ┌─────────┐
│████████ │            │ -1 0 1│            │ · · · · · │
│████████ │   窗口滑    │ -1 0 1│   相乘求和  │ · · · · · │
│████████ │ ───────▶   │ -1 0 1│ ───────▶   │ · ■ · · · │  ← 边缘处点亮
│........ │   逐格算    └───────┘            │ · · · · · │
│........ │                                  │ · · · · · │
└─────────┘                                  └─────────┘
 黑=1 白=0                                  ■ = 大响应
```

### 2.2 padding 与 stride

```python
print("无 padding 输出尺寸:", conv2d_manual(image, edge_kernel).shape)   # (6,6)
print("padding=1 输出尺寸:", conv2d_manual(image, edge_kernel, padding=1).shape)  # (8,8)
print("stride=2 输出尺寸:", conv2d_manual(image, edge_kernel, stride=2).shape)    # (3,3)
```

**输出尺寸公式**（务必记住）：

```
out = ⌊(in + 2×padding - kernel_size) / stride⌋ + 1
```

| 参数 | 作用 | 常用值 |
|---|---|---|
| `kernel_size` | 卷积核大小（感受野） | 3（最主流）、5、7 |
| `stride` | 步长 | 1（保持尺寸）、2（下采样） |
| `padding` | 边缘补 0 | `kernel//2`（保持尺寸） |

两个超参讲透：`padding`（补零）解决的是「边缘像素被滑到的次数少、信息流失」的问题。不加 padding 时，输出会比输入小（每边少 `(k-1)/2`），叠很多层后图就缩没了；加 `padding=1`（对 3×3 核）让输出尺寸和输入一致，边缘信息也得到照顾。`stride`（步长）是「窗口每次移几格」。`stride=1` 最细，逐像素滑；`stride=2` 相当于边滑边「隔一个采一个」，输出尺寸减半，起到**下采样**作用——CNN 常用 `stride=2` 的卷积代替池化来缩小特征图、扩大感受野、省计算。

**为什么主流是 3×3？** 两个 3×3 卷积的感受野等于一个 5×5，但参数更少（18 vs 25）且多一层非线性。**VGG 就是靠这条洞察堆出深度的。**

这里值得算一笔账证明「小核堆叠优于大核」：一个 5×5 卷积，每个输出位置看 5×5=25 个输入；两个 3×3 卷积串联，第二个 3×3 的每个输出看第一个 3×3 的 3×3，而第一个又看输入 3×3，所以最终每个输出同样看输入 5×5 区域（感受野等价），但参数量 2×(3×3)=18 < 25，且中间多一次非线性激活（ReLU），表达能力反而更强。VGGNet 把这条规律用到极致：整张网只用 3×3 卷积，靠堆叠出 16~19 层，既深又高效。这也是为什么今天你看到的大多数 CNN 默认 `kernel_size=3`。

### 2.3 参数量对比：权值共享的威力

```python
in_c, out_c, k = 3, 64, 3
conv_params = in_c * out_c * k * k + out_c          # 权重 + 偏置
print("卷积层参数量:", conv_params)                   # 1792

# 等价的全连接（输入 224×224×3，输出同尺寸 64 通道）
fc_params = (224*224*3) * (224*224*64)
print("等价全连接参数量:", f"{fc_params:,}")           # 天文数字
print(f"相差 {fc_params/conv_params:,.0f} 倍")
```

**一个卷积核只有 9 个参数，却要滑过整张图**——这就是**权值共享**。它的合理性在于：一条边缘在图的左上角和右下角，"边缘"这个概念是一样的，没必要学两套参数。

把「权值共享」说得更透：全连接里，输出第 (i,j) 个位置和第 (p,q) 个位置用的是**完全不同的参数**；卷积里，整张特征图共用**同一组核参数**。这背后是「平移等变性」假设——「猫在左上方」和「猫在右下方」是同一个概念「猫」，只是位置平移了，理应用同一套探测器。权值共享带来三重好处：①**参数量骤降**（上例差了几亿倍）；②**天然抗平移**（猫挪位置照样认得）；③**更容易泛化**（参数少、不易过拟合）。这正是 CNN 在小数据集上也能训好的根本原因。

## 三、PyTorch 的 nn.Conv2d

```python
# 输入格式：NCHW = (batch, channels, height, width)
x = torch.randn(4, 3, 32, 32)        # 4 张 32×32 的 RGB 图
print("输入形状 (N,C,H,W):", x.shape)

conv = nn.Conv2d(in_channels=3, out_channels=16, kernel_size=3, padding=1)
out = conv(x)
print("卷积后:", out.shape)            # (4, 16, 32, 32) 通道变多，尺寸不变
print("卷积核权重形状:", conv.weight.shape)   # (16, 3, 3, 3) = (out, in, kH, kW)

# 尺寸变化验证
conv_s2 = nn.Conv2d(16, 32, kernel_size=3, stride=2, padding=1)
print("stride=2 后:", conv_s2(out).shape)     # (4, 32, 16, 16) 尺寸减半
```

**务必记住 PyTorch 用 NCHW（通道在前）**，而 NumPy/PIL 图像通常是 HWC。转换用 `.permute(2,0,1)`。

`nn.Conv2d` 的 `weight` 形状是 `(out_channels, in_channels, kH, kW)`——比手动版多了一个 `in_channels` 维，因为彩色图每个卷积核要同时看 R/G/B 三个通道再做加权求和（等价于对每个通道各用一个 3×3 核、再相加）。`out_channels=16` 表示这一层有 16 个不同卷积核，于是输出有 16 个特征图——**通道数 = 卷积核数 = 想提取多少种特征**。`stride=2` 那次，32×32 按公式 `(32+2-3)/2+1=16`，确实减半。注意 NCHW 是 PyTorch 的硬约定：`.permute(2,0,1)` 把 HWC 的 `(32,32,3)` 变成 `(3,32,32)`，否则形状对不上会报错——这是 CV 入门最常踩的坑之一（见第九节）。

## 四、池化：降维 + 平移不变性

```python
pool = nn.MaxPool2d(kernel_size=2, stride=2)
print("最大池化后:", pool(out).shape)      # (4, 16, 16, 16)

avg_pool = nn.AvgPool2d(2)
print("平均池化后:", avg_pool(out).shape)

# 全局平均池化：把每个通道压成一个数（替代全连接，参数更少）
gap = nn.AdaptiveAvgPool2d(1)
print("全局平均池化:", gap(out).shape)     # (4, 16, 1, 1)
```

| 池化 | 作用 |
|---|---|
| MaxPool | 取窗口内最大值，保留最强特征 |
| AvgPool | 取平均，更平滑 |
| AdaptiveAvgPool | 输出固定尺寸，可接任意输入 |

**池化的意义**：
1. **降维**，减少计算量；
2. **平移不变性**：猫往左挪 5 像素，池化后特征基本一致；
3. **扩大感受野**：后面的层能看到更大的区域。

池化的直觉：`MaxPool2d(2)` 把 2×2 的四个数取最大变成一个——相当于「每 2×2 区域只保留最显著的特征」，图尺寸减半、信息量浓缩。平移不变性怎么来的？猫往左挪几像素，经过 2×2 最大池化后，那块「最强响应」大概率还在同一个池化窗口里，输出几乎不变——所以模型对物体稍微错位不敏感，更鲁棒。全局平均池化（`AdaptiveAvgPool2d(1)`）把每个通道压成 1 个数，直接得到 `(N, C)` 的「每通道全局特征」，再接一个线性层做分类——这比「展平后接巨大全连接」参数少得多、过拟合风险低，是现代 CNN（如 ResNet、MobileNet）的标准收尾方式。

## 五、经典 CNN 架构演进

| 网络 | 年份 | 关键创新 | 深度 |
|---|---|---|---|
| LeNet-5 | 1998 | CNN 鼻祖，手写数字识别 | 5 层 |
| AlexNet | 2012 | ReLU + Dropout + GPU，引爆深度学习 | 8 层 |
| VGG | 2014 | 全用 3×3 小卷积，堆深度 | 16-19 层 |
| GoogLeNet | 2014 | Inception 多分支 | 22 层 |
| **ResNet** | 2015 | **残差连接**，突破深度瓶颈 | 152 层 |
| EfficientNet | 2019 | 复合缩放 | — |

把这条演进线讲成「一部解决『深度』问题的历史」：LeNet 证明 CNN 能认数字；AlexNet 用 GPU + ReLU + Dropout 在 ImageNet 上一举夺魁，宣告深度学习时代来临；VGG 用「全 3×3 堆叠」把网络推到 19 层，但再深就训不动了——梯度在反向传播里越传越弱（梯度消失），深层学不到东西；GoogLeNet 用 Inception 多分支在不同尺度上提特征；**ResNet 用残差连接（下一节）彻底打破深度瓶颈，能堆到 152 层甚至上千层**，从此「深」不再是障碍。理解这条线，你看今天任何视觉/大模型架构，都能定位它「解决了什么历史问题」。

### 残差连接：深度学习的里程碑

```python
class ResidualBlock(nn.Module):
    """ResNet 的核心：y = F(x) + x"""
    def __init__(self, channels):
        super().__init__()
        self.block = nn.Sequential(
            nn.Conv2d(channels, channels, 3, padding=1),
            nn.BatchNorm2d(channels), nn.ReLU(),
            nn.Conv2d(channels, channels, 3, padding=1),
            nn.BatchNorm2d(channels),
        )
        self.relu = nn.ReLU()

    def forward(self, x):
        return self.relu(self.block(x) + x)      # ← 加回输入 x

blk = ResidualBlock(16)
y = blk(out)
print("残差块输出形状:", y.shape, "（与输入相同）")
```

**为什么残差连接这么重要？**

- **梯度高速路**：`+x` 让梯度可以无损传回浅层，解决梯度消失；
- **恒等映射易学**：如果这层没用，`F(x)` 学成 0 就行，不会变差；
- **网络能堆到几百层**。

**Transformer 也用了完全相同的残差结构**（`x + Attention(x)`），这是 CNN 留给大模型最重要的遗产。

残差连接的精妙在于 `y = F(x) + x` 里的「+x」：它把学习目标和「恒等映射」对齐——网络只需学「与输入相比要改多少」（残差 F(x)），而不是「从零学出整个输出」。当这层没必要改时，`F(x)≈0` 即可，输出≈输入，网络不会因加深而变差。更关键的是反向传播时，梯度除了走 `F(x)` 那条路，还能直接沿 `+x` 这条「高速路」无损回到浅层（`∂y/∂x` 里有一项恒为 1），彻底缓解梯度消失。这就是为什么 ResNet 能堆到上千层。**注意 Transformer 的 `x + Attention(x)`、`x + FFN(x)` 就是同一个残差思想**——你此刻学的，正是大模型架构的骨架。

## 六、实战：搭一个完整 CNN 分类器

用 CIFAR-10 风格的数据（32×32 RGB，10 类）：

```python
import torch, torch.nn as nn, torch.nn.functional as F
from torch.utils.data import DataLoader
from torchvision import datasets, transforms

# ---- 数据（会自动下载 CIFAR-10，约 170MB；若网络受限可改用随机数据）----
transform = transforms.Compose([
    transforms.ToTensor(),
    transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2470, 0.2435, 0.2616)),
])

try:
    train_set = datasets.CIFAR10(root="./data", train=True, download=True, transform=transform)
    test_set  = datasets.CIFAR10(root="./data", train=False, download=True, transform=transform)
    print("CIFAR-10 加载成功:", len(train_set), "张训练图")
except Exception as e:
    print("下载失败，改用随机数据演示:", e)
    from torch.utils.data import TensorDataset
    Xr = torch.randn(2000, 3, 32, 32); yr = torch.randint(0, 10, (2000,))
    train_set = TensorDataset(Xr, yr); test_set = TensorDataset(Xr[:400], yr[:400])

train_loader = DataLoader(train_set, batch_size=64, shuffle=True, num_workers=0)
test_loader  = DataLoader(test_set,  batch_size=128, shuffle=False, num_workers=0)
```

### 6.1 模型定义

```python
class SimpleCNN(nn.Module):
    """
    输入 (N,3,32,32) → 输出 (N,10)
    结构：[Conv→BN→ReLU→Pool] × 3 → 全局池化 → FC
    """
    def __init__(self, num_classes=10):
        super().__init__()
        self.features = nn.Sequential(
            # 32×32 → 32×32（通道 3→32）→ 池化 16×16
            nn.Conv2d(3, 32, 3, padding=1), nn.BatchNorm2d(32), nn.ReLU(),
            nn.MaxPool2d(2),

            # 16×16 → 8×8（32→64）
            nn.Conv2d(32, 64, 3, padding=1), nn.BatchNorm2d(64), nn.ReLU(),
            nn.MaxPool2d(2),

            # 8×8 → 4×4（64→128）
            nn.Conv2d(64, 128, 3, padding=1), nn.BatchNorm2d(128), nn.ReLU(),
            nn.MaxPool2d(2),
        )
        self.classifier = nn.Sequential(
            nn.AdaptiveAvgPool2d(1),      # (N,128,1,1)
            nn.Flatten(),                 # (N,128)
            nn.Dropout(0.3),
            nn.Linear(128, num_classes),  # (N,10)
        )

    def forward(self, x):
        return self.classifier(self.features(x))

model = SimpleCNN()
print(f"参数量: {sum(p.numel() for p in model.parameters()):,}")

# 验证形状：前几层输出尺寸
with torch.no_grad():
    t = torch.randn(2, 3, 32, 32)
    for i, layer in enumerate(model.features):
        t = layer(t)
        if isinstance(layer, nn.MaxPool2d):
            print(f"  经过 layer{i} 后形状: {tuple(t.shape)}")
```

这个模型把前面所有零件串成一条流水线：`Conv→BN→ReLU→Pool` 重复三次，特征图从 32×32 缩到 4×4、通道从 3 增到 128（每级都在「浓缩信息 + 扩大感受野」）；最后全局平均池化把 4×4×128 压成 128 维向量，Dropout 防过拟合，线性层出 10 类分数。注意 `model.features` 的逐层打印能帮你**验证尺寸链条对不对**——这比等报错了再调公式省事得多，是搭 CNN 的必备调试习惯。

**为什么用 `BatchNorm`？** 让每层的输入分布稳定（均值0方差1），大幅加速收敛并允许更大学习率。**CV 标配，NLP 用 LayerNorm。**

BatchNorm（批归一化）在训练时，用「当前 batch 的均值/方差」把每层输入标准化，再学两个可缩放平移的参数（β、γ）。它的作用：①抵消「前面层参数变动导致后面层输入分布漂移」（内部协变量偏移），让每层输入稳定在合理范围，训练更稳、可用更大 lr；②轻微正则效果。但 BatchNorm 依赖 batch 内有足够样本统计，所以 `batch_size=1` 会报错、小 batch 时效果差——这也是它不适合变长序列（NLP）的原因，NLP 改用 LayerNorm（不依赖 batch、对单样本归一化）。两者分工：CV 用 BatchNorm、Transformer/NLP 用 LayerNorm。

### 6.2 训练

```python
DEVICE = torch.device("cuda" if torch.cuda.is_available()
                      else "mps" if torch.backends.mps.is_available() else "cpu")
model = model.to(DEVICE)
criterion = nn.CrossEntropyLoss()
optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)

def train_epoch(loader):
    model.train()
    tot, n = 0.0, 0
    for X_b, y_b in loader:
        X_b, y_b = X_b.to(DEVICE), y_b.to(DEVICE)
        optimizer.zero_grad()
        loss = criterion(model(X_b), y_b)
        loss.backward()
        optimizer.step()
        tot += loss.item() * len(y_b); n += len(y_b)
    return tot / n

@torch.no_grad()
def evaluate(loader):
    model.eval()
    correct, total = 0, 0
    for X_b, y_b in loader:
        X_b, y_b = X_b.to(DEVICE), y_b.to(DEVICE)
        pred = model(X_b).argmax(dim=1)
        correct += (pred == y_b).sum().item(); total += len(y_b)
    return correct / total

for ep in range(10):
    loss = train_epoch(train_loader)
    acc = evaluate(test_loader)
    print(f"epoch {ep:2d}  loss={loss:.4f}  test_acc={acc:.4f}")
```

这里直接复用上篇的训练模板（五步曲 + `model.train()/eval()` + `no_grad`）。在 CIFAR-10 上跑 10 个 epoch，典型的 `test_acc` 会从 ~0.3 升到 0.7~0.8 区间（加数据增强可更高）。注意 `Normalize` 用的是 CIFAR-10 dataset 的官方均值/标准差——**CV 一定归一化**，否则输入尺度不一、收敛极慢甚至不收敛。`loss` 应稳步下降、`test_acc` 上升，若乱跳，优先查 BatchNorm 的 `train/eval` 是否切对、数据是否归一化。

### 6.3 数据增强（提升泛化的免费午餐）

```python
augment = transforms.Compose([
    transforms.RandomHorizontalFlip(p=0.5),        # 随机水平翻转
    transforms.RandomCrop(32, padding=4),          # 随机裁剪（带 padding）
    transforms.ColorJitter(brightness=0.2, contrast=0.2),  # 颜色抖动
    transforms.ToTensor(),
    transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2470, 0.2435, 0.2616)),
])
print("数据增强 = 用免费的方式扩充数据集，是 CV 最重要的防过拟合手段之一")
```

数据增强的本质是「在不改标签的前提下，人为制造训练样本的新变体」：左右翻转的猫还是猫、稍微裁掉边缘的猫还是猫、调亮调暗的猫还是猫。模型见过这些「扰动版」后，对真实拍摄里的角度/光照变化更鲁棒——相当于**不花一分钱把数据集扩大了无数倍**。这是 CV 里第一重要的防过拟合手段，比加 Dropout 往往更有效。`RandomHorizontalFlip` 对「左右对称」的物体（猫狗车）友好，但对「左右不对称」的（比如「6」和「9」）要小心。把增强写进 `transforms.Compose` 并只在训练集用、验证/测试集只用 `ToTensor+Normalize`（不加随机增强），否则评估指标会失真。

## 七、可视化：CNN 到底看到了什么

```python
import matplotlib.pyplot as plt

@torch.no_grad()
def show_feature_maps(model, x):
    """可视化第一层卷积的输出特征图"""
    model.eval()
    acts = []
    t = x.unsqueeze(0)
    for layer in model.features:
        t = layer(t)
        if isinstance(layer, nn.ReLU):
            acts.append(t.squeeze(0))
            break
    fmaps = acts[0][:8].cpu()      # 取前 8 个通道
    fig, axes = plt.subplots(1, 8, figsize=(14, 2))
    for i, ax in enumerate(axes):
        ax.imshow(fmaps[i], cmap="viridis"); ax.axis("off")
        ax.set_title(f"ch{i}")
    plt.suptitle("Layer-1 Feature Maps"); plt.tight_layout(); plt.show()

# 取一张真实图片
img, label = test_set[0]
show_feature_maps(model, img.to(DEVICE))
```

靠近输入的层能看到边缘、色块；越深的层越抽象（眼睛、轮子、纹理）。

可视化是「CNN 黑盒变白盒」的关键一步。第一层卷积的 32 个核，学出来的大概率是「不同朝向的边缘」「不同颜色的斑块」「明暗渐变」——你会在图里看到有的通道对横向边缘亮、有的对纵向边缘亮。`cmap="viridis"` 把这些响应强度画成颜色（蓝=弱、黄=强）。这个实验的启发：**CNN 不是直接「认猫」，而是从边缘→纹理→部件→整体，逐级拼出来**——和人类的视觉认知过程惊人地相似。对大模型来说，可解释性研究（如注意力图、特征归因）也是同一思路：把中间激活画出来，看模型「关注了什么」。

## 八、为什么大模型最终抛弃了 CNN？

这是本篇最重要的思考题。

| | CNN | Transformer |
|---|---|---|
| 归纳偏置 | **强**：局部性 + 平移不变 | 弱：几乎无假设 |
| 感受野 | 局部，需堆层数扩大 | **全局**：一次注意力看全图/全句 |
| 长距离依赖 | 难（要很多层才能关联远处） | **一步到位** |
| 数据需求 | 少（有强先验） | **极大**（靠数据学出先验） |
| 可扩展 | 一般 | **极强**（ scaling law） |
| 并行性 | 好 | 好 |

**结论**：

- CNN 的**局部性先验**是图像的绝佳假设，所以在中小数据集上 CNN 依然很强（这也是为什么很多工业 CV 系统还在用 ResNet/YOLO）；
- 但当数据足够大时，**"少一点假设、多一点学习能力"的 Transformer 胜出**——它能直接建模任意两个位置的关系；
- 而且 Transformer 的结构（注意力 + FFN）**统一了文本、图像、语音的处理方式**——ViT 把图像切成 16×16 的 patch 当"词"来用，和 NLP 完全同一套架构。这就是**多模态大模型**得以成立的基础。

把「为什么抛弃」讲透，核心是两个词：**归纳偏置（inductive bias）**与**数据规模**。

归纳偏置是「模型天生带的对世界的假设」。CNN 自带「局部性 + 平移不变」——这是图像的真规律，所以**小数据也能训好**（先验帮你省数据）。但凡事一体两面：强先验也限制了表达——CNN 要看清「图左上角和右下角的关系」，得一层层卷积把感受野慢慢扩过去，远距离依赖很难建模（比如「图左上角的猫」和「右下角的老鼠」的关系，要很多层才连得上）。Transformer 几乎**不带先验**（只有「注意力能连任意位置」这个弱假设），于是它初期「啥也不懂」、需要海量数据从头学规律；但一旦数据够大，它能直接对任意两个位置建模，**一步到位**捕捉长程关系，且能堆到极大规模遵循 scaling law（数据/参数越多越强）。

于是历史的转折点是：**当数据从「几万张图」变成「几十亿图文对」时，「少假设+多数据」的 Transformer 反超了「强假设+少数据」的 CNN**。ViT 又补齐了最后一块拼图——把图像切成 patch 当 token，让同一套 Transformer 能处理图。多模态大模型（看图说话、文生图）正是建立在「图文都用 Transformer」之上。所以结论不是「CNN 错了」，而是「在数据爆炸时代，更通用的架构赢了」。理解这一点，你就看懂了深度学习这十年的范式转移。

```python
# ViT 的思想：把图像切成 patch，当成 token 序列
B, C, H, W, patch = 2, 3, 224, 224, 16
num_patches = (H // patch) * (W // patch)
print(f"一张 {H}×{W} 的图切成 {patch}×{patch} patch → {num_patches} 个 token")
print("→ 和一句话有 196 个词完全一样，直接喂给 Transformer")

# 用 Conv2d 一行实现 patch 切分（ViT 的标准做法）
patch_embed = nn.Conv2d(C, 768, kernel_size=patch, stride=patch)
tokens = patch_embed(torch.randn(B, C, H, W))
print("patch embedding 输出:", tokens.shape)         # (2, 768, 14, 14)
print("展平成序列:", tokens.flatten(2).transpose(1, 2).shape)  # (2, 196, 768)
```

**看懂这段代码，你就理解了 ViT 和多模态大模型的第一层。**

这段代码把「图像变 token」这件事落地了：`nn.Conv2d(3, 768, kernel_size=16, stride=16)` 用一个 16×16 的大卷积核、步长 16，等于「每 16×16 一块不重叠地取一次」，输出 14×14 个「像素块特征」（每块 768 维）——正好是 196 个 token。`flatten(2).transpose(1,2)` 把 `(B,768,14,14)` 展平成 `(B,196,768)`，和「一句话 196 个词、每词 768 维」形状完全一致。接下来这一个序列直接喂给 Transformer——**图像和文本在输入形态上已经统一**。这就是 CLIP、BLIP、GPT-4V 等多模态模型能把「图」和「文」放进同一个模型处理的根本原因。你今天写的这几行，就是多模态时代的入口。

## 九、常见坑与注意事项

| 坑 | 现象 | 解决 |
|---|---|---|
| 通道顺序搞错 | 结果全错但不报错 | PyTorch 用 NCHW，PIL/NumPy 是 HWC |
| 尺寸算错 | `RuntimeError: shape mismatch` | 用公式 `⌊(in+2p-k)/s⌋+1` 核对 |
| 忘了 Flatten | FC 层报错 | 卷积输出进 FC 前 `nn.Flatten()` |
| 忘了 Normalize | 收敛慢 | 用数据集的均值/标准差 |
| 评估忘 `model.eval()` | BatchNorm 用batch统计，指标异常 | 切 eval |
| BatchNorm + batch_size=1 | 报错 | 训练时 batch ≥ 2 |
| 卷积层参数量算错 | `in_c × out_c × k × k` | 别忘了加偏置 |

补几个最容易翻车的细节：①**NCHW vs HWC**——`plt.imread`/`PIL` 读出来是 `(H,W,C)`，`transforms.ToTensor()` 会自动转成 `(C,H,W)`，但你自己用 `numpy` 造数据时常忘 `.permute`，导致「通道维被当成高度」，形状对但语义全错、不报错只出垃圾结果。②**尺寸公式必须背**——搭深层 CNN 时每层的 H/W 是链条式的，错一层后面全错，养成「边写边用公式算」的习惯。③**卷积进全连接前必 `Flatten`**——`(B,C,H,W)` 直接进 `Linear` 会把 H、W 当成特征维一起映射，形状错。④**BatchNorm 必须 `train/eval` 切对**——忘切 eval，推理时用的是当前 batch 的统计而非训练时累积的滑动平均，指标会飘。

## 十、本篇小结

1. **卷积 = 小窗口滑过图像做点积**，靠**局部感受野 + 权值共享**把参数量降到全连接的几万分之一。
2. 输出尺寸公式 **`out = ⌊(in + 2p - k)/s⌋ + 1`**；3×3 卷积 + padding=1 保持尺寸，stride=2 减半。
3. **池化**降维 + 提供平移不变性；**BatchNorm** 稳定分布加速收敛（CV 标配，NLP 用 LayerNorm）。
4. **残差连接 `y = F(x) + x`** 解决了梯度消失，让网络能堆到上百层——**Transformer 直接继承了这一设计**。
5. 我们搭了完整的 CNN（Conv→BN→ReLU→Pool ×3 → GAP → FC），并可视化了第一层特征图。
6. **CNN 的强先验在小数据上占优，但 Transformer 的弱先验 + 全局注意力在数据足够大时胜出**，且统一了多模态——这就是为什么 ViT 把图像切成 patch 当 token。

下一篇 **RNN/LSTM 与序列建模**：处理文本这类"有先后顺序"的数据，需要能"记住前面发生什么"的网络。你会理解 RNN 的循环结构、**LSTM 的三道门**（遗忘门/输入门/输出门），以及最关键的——**为什么 RNN 会被 Transformer 取代**（并行性与长距离依赖的双重失败）。**这是理解"注意力为什么必要"的最后一块拼图。**

## 十一、实战练习（可验证小任务）

1. **手算卷积**：用本篇 `conv2d_manual` 手算一个 5×5 随机图、3×3 随机核，再用公式核对输出尺寸 `(5-3)/1+1=3`，确认一致。
2. **改核看效果**：把 `edge_kernel` 换成「模糊核」（全 1/9）、「锐化核」，重跑，观察特征图从「边缘」变成「平滑/增锐」，理解「核 = 特征探测器」。
3. **搭 CNN 跑 CIFAR-10**：把第六节模型跑 10 epoch，目标 `test_acc ≥ 0.7`；验证：`print(evaluate(test_loader))`。
4. **加数据增强对比**：分别用「无增强」和「6.3 增强」训练，对比最终准确率，体会「免费午餐」的增益。
5. **可视化特征图**：跑第七节代码，确认第一层能看到边缘/色块；尝试可视化更深的层（改 `isinstance(layer, nn.ReLU)` 的 break 位置），观察特征是否更抽象。
6. **实现 ViT 第一步**：跑第八节的 patch 切分代码，打印 `(B,196,768)` 形状，确认「图像已变成 token 序列」，为下一篇 Transformer 铺垫。

## 十二、延伸阅读与下一步

- **经典论文**：LeNet（1998）、AlexNet（2012, *ImageNet Classification with Deep CNN*）、VGG（2014）、ResNet（2015, *Deep Residual Learning*）——建议按年份读，体会「深度」问题怎么被一步步解决。
- **可视化工具**：进一步了解 `torchvision.utils.make_grid`、特征图可视化库（如 Quilt、Netron 看模型结构）。
- **现代视觉架构**：EfficientNet（复合缩放）、ConvNeXt（把 CNN 改得像 Transformer）、以及 ViT / Swin Transformer（纯注意力视觉）。
- **与多模态的衔接**：读懂本篇的 patch embedding，下一步读 CLIP（图文对比预训练）就会很顺——它就是把「图 token」和「文 token」拼一起喂 Transformer。
- **下一步**：下一篇《RNN 与 LSTM 序列建模》处理「有先后顺序」的文本/时间序列，你会学到循环记忆、LSTM 三道门，以及为什么 RNN 同样被 Transformer 取代——这是进入阶段 5「注意力机制」前最后一块拼图。

> 本篇是《大模型开发从 0 到 1》专栏第 26 篇，阶段 4「深度学习与 PyTorch」第 5 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
