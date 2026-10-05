<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# CNN 与计算机视觉——模型如何看懂图像

**承上**：上一篇《训练循环实战》我们有了通用训练模板，但输入一直是扁平向量。

**本篇**：本篇处理图像：卷积、池化、残差连接，并理解 ViT 如何把图像切成 patch。

**启下**：下一篇《RNN 与 LSTM 序列建模》处理有先后顺序的序列数据，收官阶段 4。

**学完这一节，你能动手做**：

1. 手算一次卷积，并用公式核对任意输入输出尺寸
2. 搭出完整 CNN 分类器并可视化第一层特征图
3. 理解 patch 化之后，Transformer 为何能统一处理图文


前面我们用的都是全连接层（`nn.Linear`），输入是"扁平的一个向量"。但图像是 **H×W×C 的三维结构**（高×宽×通道），直接拍扁会**丢掉空间关系**——像素之间的邻居关系才是图像最重要的信息。

**CNN（卷积神经网络）** 就是为此而生。它用一个天才的设计——**卷积核**——既保留了空间结构，又把参数量降到全连接的几百分之一。

这一篇你会：理解卷积在干什么、亲手实现一个卷积、看懂特征图、搭出完整 CNN 分类器，并最终理解**为什么大模型时代 CNN 让位给了 Transformer**。

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

**为什么主流是 3×3？** 两个 3×3 卷积的感受野等于一个 5×5，但参数更少（18 vs 25）且多一层非线性。**VGG 就是靠这条洞察堆出深度的。**

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

## 五、经典 CNN 架构演进

| 网络 | 年份 | 关键创新 | 深度 |
|---|---|---|---|
| LeNet-5 | 1998 | CNN 鼻祖，手写数字识别 | 5 层 |
| AlexNet | 2012 | ReLU + Dropout + GPU，引爆深度学习 | 8 层 |
| VGG | 2014 | 全用 3×3 小卷积，堆深度 | 16-19 层 |
| GoogLeNet | 2014 | Inception 多分支 | 22 层 |
| **ResNet** | 2015 | **残差连接**，突破深度瓶颈 | 152 层 |
| EfficientNet | 2019 | 复合缩放 | — |

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

**为什么用 `BatchNorm`？** 让每层的输入分布稳定（均值0方差1），大幅加速收敛并允许更大学习率。**CV 标配，NLP 用 LayerNorm。**

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

## 十、本篇小结

1. **卷积 = 小窗口滑过图像做点积**，靠**局部感受野 + 权值共享**把参数量降到全连接的几万分之一。
2. 输出尺寸公式 **`out = ⌊(in + 2p - k)/s⌋ + 1`**；3×3 卷积 + padding=1 保持尺寸，stride=2 减半。
3. **池化**降维 + 提供平移不变性；**BatchNorm** 稳定分布加速收敛（CV 标配，NLP 用 LayerNorm）。
4. **残差连接 `y = F(x) + x`** 解决了梯度消失，让网络能堆到上百层——**Transformer 直接继承了这一设计**。
5. 我们搭了完整的 CNN（Conv→BN→ReLU→Pool ×3 → GAP → FC），并可视化了第一层特征图。
6. **CNN 的强先验在小数据上占优，但 Transformer 的弱先验 + 全局注意力在数据足够大时胜出**，且统一了多模态——这就是为什么 ViT 把图像切成 patch 当 token。

下一篇 **RNN/LSTM 与序列建模**：处理文本这类"有先后顺序"的数据，需要能"记住前面发生什么"的网络。你会理解 RNN 的循环结构、**LSTM 的三道门**（遗忘门/输入门/输出门），以及最关键的——**为什么 RNN 会被 Transformer 取代**（并行性与长距离依赖的双重失败）。**这是理解"注意力为什么必要"的最后一块拼图。**

> 本篇是《大模型开发从 0 到 1》专栏第 26 篇，阶段 4「深度学习与 PyTorch」第 5 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
