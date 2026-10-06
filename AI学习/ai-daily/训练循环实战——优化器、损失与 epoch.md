<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 训练循环实战——优化器、损失与 epoch

**承上**：上一篇《用 nn.Module 搭建你的第一个神经网络》我们搭好了网络，但训练循环还是简版。

**本篇**：本篇升级成工程级模板：DataLoader、AdamW、warmup 调度、早停与 checkpoint。

**启下**：下一篇《CNN 与计算机视觉——模型如何看懂图像》用这套模板处理图像数据。

**学完这一节，你能动手做**：1) 能写出可直接抄进任何项目的训练 + 验证 + 早停 + 存盘模板 2) 能用梯度累积在显存不足时模拟大 batch 3) 能看懂优化器与学习率策略，知道大模型为什么都用 AdamW + warmup。

上一篇我们用 `nn.Module` 搭出了 MLP，训练循环还是手写的简版。这一篇把它升级成**可以直接抄进任何项目的工程级模板**：

- `Dataset` / `DataLoader` 批量加载与打乱
- SGD / Adam / AdamW 优化器对比（大模型为什么都用 AdamW）
- 学习率调度（warmup + 余弦衰减，大模型标配）
- 早停、checkpoint 保存、梯度裁剪
- 完整训练 + 验证 + 曲线绘制

**这份模板会一直用到微调大模型那一步**，值得反复读。

把训练往更底层看一层，它其实在解一个优化问题：**经验风险最小化（Empirical Risk Minimization）**。模型有一堆参数 θ，我们定义「损失函数 L(θ)」衡量它在训练数据上的平均犯错程度，训练的目标就是找到 `θ* = argmin L(θ)`。梯度下降做的就是「沿 L 下降最快的方向（负梯度）一步步挪 θ」。所谓「学习率 lr」，就是每次挪多大步；所谓「epoch」，就是把这组数据反复喂给优化器直到它收敛。这个视角能帮你把本篇所有部件串起来：DataLoader 决定「每次看点什么数据」、优化器决定「往哪挪、挪多大」、损失函数决定「什么叫犯错」、调度器决定「步子随训练进程怎么变」、早停决定「什么时候收手别学歪」。你日后看任何训练脚本，都能套进这个框架。

## 〇、概念引入与背景：训练循环到底在干什么？

在堆代码之前，先把「一次训练」的全局图景讲清楚。很多人刚学时以为训练是某个神秘函数一键完成的，其实它是一套**高度重复的循环**。一句话概括训练的本质：

> 用「一批数据」算出「预测和真实的差距（损失）」，再沿差距反向调整「所有参数」，让下一批的预测更好一点。如此循环成百上千次，模型就从随机变得「懂数据」。

拆开看，一次标准的训练迭代由五步组成（上一篇已见过雏形）：

```
① 取一批样本 (x, y)  ──▶  ② 前向得到预测 ŷ = model(x)
        │                       │
        ▼                       ▼
③ 算损失 loss = criterion(ŷ, y)
        │
        ▼
④ 反向传播 loss.backward()  →  得到每个参数的梯度 ∂loss/∂θ
        │
        ▼
⑤ 优化器 step()  →  用梯度更新参数 θ ← θ - lr·∇
        │
        └──▶  回到 ① 取下一批，直到跑完整个数据集（这叫一个 epoch）
```

这个「五步循环」每个 batch 跑一遍，跑完整个数据集叫一个 **epoch**。模型质量是在**几十到几百个 epoch** 里慢慢磨出来的。本篇要做的，就是把这个朴素循环武装成「生产级」模板：加上批量加载、验证监控、早停、存盘、学习率调度等工程要素——这些不是炫技，而是真实项目里**缺一不可**的部件。

为什么必须升级？因为手写简版有三个致命短板：①一次把全部数据塞进模型会爆显存，必须分批；②没有验证集监控就会「训练集 100% 但测试集拉胯」（过拟合而浑然不知）；③没有 checkpoint 一旦训练中断（服务器掉电、OOM）几天白跑。所以本篇的模板，是「能真正交付」和「只能跑 demo」的分界线。

从大模型视角看，今天 GPT/LLaMA 的训练也是这套循环，只是规模放大到：数据以 TB 计、batch 以千计、epoch 以「token 数」计、优化器是 AdamW、学习率带 warmup 与余弦衰减、并且每隔一段时间就把 `state_dict` 存成 checkpoint。你本篇写的每一行，都对应着大模型训练脚本里的一个真实环节。

## 一、Dataset 与 DataLoader：数据管道

自己切 batch 太麻烦，PyTorch 提供了标准解法。核心是两个抽象：`Dataset`（「数据从哪来、长什么样」）和 `DataLoader`（「怎么把数据分批、打乱、并行加载」）。这种「数据」与「加载」的分离，让同一份数据既能小批量训练、又能整个验证，还能多进程加速。

```python
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader, TensorDataset

# ---- 方式 1：TensorDataset（最简单，张量直接包一层）----
X = torch.randn(1000, 10)
y = torch.randint(0, 3, (1000,))
ds = TensorDataset(X, y)

loader = DataLoader(ds, batch_size=64, shuffle=True, num_workers=0)
batch_X, batch_y = next(iter(loader))
print("一个 batch:", batch_X.shape, batch_y.shape)
```

`TensorDataset` 适合「数据已经是张量」的情况：它只是把多个张量按行对齐包成一个数据集，`__getitem__(i)` 返回第 i 行的 `(x, y)`。最常见的用法就是 sklearn 造好数据 → `TensorDataset` 包一下 → `DataLoader` 分批。

### 1.1 自定义 Dataset

真实数据往往要自定义读取逻辑（读文件、做增强、tokenize）：

```python
class MyDataset(Dataset):
    """自定义数据集：必须实现 __len__ 和 __getitem__"""
    def __init__(self, X, y, transform=None):
        self.X, self.y, self.transform = X, y, transform

    def __len__(self):
        return len(self.X)

    def __getitem__(self, idx):
        x, y = self.X[idx], self.y[idx]
        if self.transform:
            x = self.transform(x)
        return x, y

# 示例：语料类数据集（大模型最常见形态）
class TextDataset(Dataset):
    """把 token id 序列切成定长窗口，用于语言模型训练"""
    def __init__(self, token_ids, seq_len=128):
        self.token_ids = token_ids
        self.seq_len = seq_len

    def __len__(self):
        return (len(self.token_ids) - 1) // self.seq_len

    def __getitem__(self, i):
        start = i * self.seq_len
        chunk = self.token_ids[start:start + self.seq_len + 1]
        x = torch.tensor(chunk[:-1], dtype=torch.long)   # 输入
        y = torch.tensor(chunk[1:],  dtype=torch.long)   # 目标 = 右移一位
        return x, y

tokens = list(range(5000))
text_ds = TextDataset(tokens, seq_len=128)
tx, ty = text_ds[0]
print("输入 x:", tx[:8].tolist())
print("目标 y:", ty[:8].tolist(), " ← 正是 x 右移一位")
print("数据集长度:", len(text_ds))
```

自定义 `Dataset` 只需要实现两个方法：`__len__`（数据集有多少样本）和 `__getitem__(idx)`（取第 idx 个样本）。这层抽象的好处是：你的数据可以是图片文件、JSON 文本、数据库记录，只要能写成 `(特征, 标签)` 返回即可，`DataLoader` 完全不关心内部细节。**`DataLoader` 负责把 `Dataset` 按 batch 拼起来、打乱、多进程读取**。

**注意 `y` 是 `x` 右移一位**——这就是语言模型"用前 n 个词预测下一个词"的数据构造方式，自监督标签是数据自己给的。这一点极关键：大模型预训练不需要人工标注，因为「下一个词」就是天然标签。你看到的 `TextDataset` 正是把一段长文本切成无数个「输入-下一个词」窗口，这就是 GPT 预训练数据的标准形态。理解它，你就理解了「自回归语言模型为什么不需要标注」。

### 1.2 DataLoader 的关键参数

```python
loader = DataLoader(
    ds,
    batch_size=32,
    shuffle=True,          # 训练集要 True，验证/测试集要 False
    num_workers=2,         # 多进程加载（Windows 上可能要设 0）
    drop_last=True,        # 丢弃最后一个不完整的 batch（训练时常用）
    pin_memory=True,       # GPU 训练时加速数据拷贝
)
```

| 参数 | 说明 |
|---|---|
| `batch_size` | 每批样本数，常用 16/32/64/128 |
| `shuffle` | 训练 True，验证 False |
| `num_workers` | 数据加载进程数，IO 瓶颈时调大 |
| `drop_last` | 最后不足一批时丢弃（避免 BatchNorm 报错） |

逐个参数讲透：`batch_size` 是「一次塞给模型多少样本」。它既是显存约束（越大越占显存），也是优化特性——梯度是「一批样本的平均」，batch 越大梯度越稳但越慢，batch 越小越抖但越省显存。大模型常用「梯度累积」来用小的物理 batch 模拟大的逻辑 batch（见第八节）。`shuffle=True` 让每个 epoch 的样本顺序打乱，防止模型「记住顺序」而非「学会规律」；但验证/测试集**绝不可 shuffle**，否则指标没法复现、也失去「评估分布」的意义。`num_workers` 是开几个子进程并行读数据，数据在硬盘上时调大能避免 GPU 等数据（瓶颈在 IO 而非计算时尤其有用），但在 Windows 或某些环境下多进程会报错，这时设 0。`drop_last=True` 丢弃最后一个残批，避免它 batch 维度不一致导致 BatchNorm 报错，也保证每步梯度尺度一致。`pin_memory=True` 把数据锁页到固定内存，GPU 拷贝更快，是 GPU 训练的小提速技巧。

### 1.3 三个必须分清的概念：epoch / batch / iteration

初学者极易混淆的三词，这里一次讲清，全篇统一口径：

- **Sample（样本）**：一条 `(x, y)`，训练的最小单位。
- **Batch（批）**：一次喂进模型的若干样本，`batch_size` 就是它的数量。前向+反向以 batch 为单位。
- **Iteration（迭代）**：跑完**一个 batch** 的五步循环算一次 iteration。一个 epoch 里有 `ceil(样本数 / batch_size)` 次 iteration。
- **Epoch（轮）**：**完整过完一遍整个训练集**算一个 epoch。模型要训很多个 epoch。

用一张图串起来：

```
整个数据集 (N 个样本)
   │  按 batch_size=64 切分
   ▼
 ┌─────────┬─────────┬─────────┬───────┐
 │ batch 1 │ batch 2 │ batch 3 │ ...   │   ← 一个 epoch 里的若干 iteration
 └─────────┴─────────┴─────────┴───────┘
   ▲ 每个 batch 跑一次 五步循环（一次 iteration）
   │
  跑完所有 batch = 1 个 epoch；重复 EPOCHS 次 = 整个训练
```

记法：**epoch 看「数据过了几遍」，iteration 看「参数更新了几次」**。如果 `batch_size=64`、数据 3000 条，那一个 epoch ≈ 47 次 iteration；`EPOCHS=100` 就是约 4700 次参数更新。大模型语境里你常看到的「training steps = 100k」指的就是 iteration 数，而不是 epoch 数（因为语料太大，往往一个 epoch 都跑不完）。分清这几个量，你读任何论文的「we trained for 300B tokens / 1 epoch」才不会懵。

## 二、优化器：SGD vs Adam vs AdamW

参数怎么更新，由**优化器**决定。它做的事情就是 `θ ← θ - lr · 更新量`，区别在于「更新量」怎么算。

```python
model = nn.Sequential(nn.Linear(10, 64), nn.ReLU(), nn.Linear(64, 3))

sgd    = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
adam   = torch.optim.Adam(model.parameters(), lr=1e-3)
adamw  = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
```

### 2.1 三者对比

把三种优化器的「一次更新」写成公式对照，差异一目了然：

```
SGD(+momentum):
  v = β·v - lr·g              # v 是动量（惯性），g 是当前梯度
  θ = θ + v

Adam:
  m = β1·m + (1-β1)·g         # 一阶动量（方向）
  v = β2·v + (1-β2)·g²        # 二阶动量（每个参数的步长尺度）
  m̂ = m/(1-β1^t); v̂ = v/(1-β2^t)   # 偏差修正
  θ = θ - lr·m̂/(√v̂ + ε)      # 每个参数自适应步长

AdamW:
  同上算 m̂, v̂
  θ = θ - lr·λ·θ              # ← 先解耦做权重衰减（独立于自适应更新）
  θ = θ - lr·m̂/(√v̂ + ε)      # ← 再做 Adam 更新
```

这张图把「AdamW 比 Adam 多了哪一步」画得很直白：Adam 把 `λ·θ` 混进梯度 `g` 一起被 `√v̂` 缩放，导致衰减强度被自适应学习率扭曲；AdamW 把 `θ - lr·λ·θ` 拎出来单做，再走 Adam 更新——衰减强度只由 `lr·λ` 决定，干净可控。这就是它泛化更好的数学原因。

| 优化器 | 思路 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| **SGD(+momentum)** | 沿梯度走，加动量惯性 | 泛化好、显存省 | 需精调 lr、收敛慢 | CV 任务（ResNet 论文用法） |
| **Adam** | 自适应学习率（一阶+二阶动量） | 收敛快、对 lr 不敏感 | 泛化略差、weight decay 有坑 | 默认首选 |
| **AdamW** | Adam + 正确的权重衰减 | ✅ 解耦正则，泛化更好 | — | **大模型微调标配** |

**为什么大模型都用 AdamW？** 因为 Adam 里的 L2 正则实现方式有问题（与自适应学习率耦合），AdamW 把权重衰减**解耦**出来，直接在参数更新时衰减，效果明显更好。

展开讲三者原理，帮你建立直觉而不是死记：

- **SGD（随机梯度下降）**：最朴素的 `θ ← θ - lr·g`。问题是所有参数共用一个学习率，而有的参数梯度大、有的小，统一 lr 要么整体太慢、要么个别炸。加 **momentum（动量）** 后，更新量 = 当前梯度 + 上一刻的动量，相当于「带着惯性下坡」，能冲过平坦区、加速收敛，这也是 CV 里 ResNet 等经典网络仍偏好 SGD+momentum 的原因——它的泛化（测试集表现）往往更好。
- **Adam**：同时维护「一阶动量」（梯度的指数滑动平均，类似方向）和「二阶动量」（梯度平方的指数滑动平均，类似每个参数该用多大步长）。它给**每个参数自适应**的学习率：梯度一直很大的参数步长自动变小，稀疏参数步长自动变大。所以 Adam 对 lr 不敏感、收敛快，是多数任务的默认首选。
- **AdamW**：Adam 把 L2 权重衰减（`θ ← θ - lr·λ·θ`）错误地和梯度混在一起，再经过自适应缩放后，正则效果被扭曲。AdamW 把权重衰减**解耦**：先 `θ ← θ - lr·λ·θ`（独立衰减），再走 Adam 的自适应更新。这一改，正则强度不再受自适应学习率干扰，泛化明显更好。**于是 AdamW 成为 Transformer / 大模型训练与微调的事实标准。**

一句话记忆：**想省心快收敛用 Adam，想刷 SOTA 大模型用 AdamW，传统 CV 追求极致泛化可试 SGD+momentum。**

### 2.2 直观对比收敛速度

```python
import copy, numpy as np
import matplotlib.pyplot as plt

torch.manual_seed(0)
Xs = torch.randn(600, 10)
ws_true = torch.randn(10, 1)
ys = Xs @ ws_true + 0.3 + torch.randn(600, 1) * 0.5

def run(opt_name, lr, epochs=150):
    torch.manual_seed(1)
    m = nn.Linear(10, 1)
    if opt_name == "SGD":
        opt = torch.optim.SGD(m.parameters(), lr=lr, momentum=0.9)
    elif opt_name == "Adam":
        opt = torch.optim.Adam(m.parameters(), lr=lr)
    else:
        opt = torch.optim.AdamW(m.parameters(), lr=lr)
    loss_fn = nn.MSELoss()
    hist = []
    for _ in range(epochs):
        opt.zero_grad()
        loss = loss_fn(m(Xs), ys)
        loss.backward()
        opt.step()
        hist.append(loss.item())
    return hist

plt.figure(figsize=(7, 4))
for name, lr in [("SGD", 0.05), ("Adam", 0.01), ("AdamW", 0.01)]:
    plt.plot(run(name, lr), label=f"{name} (lr={lr})")
plt.xlabel("epoch"); plt.ylabel("MSE"); plt.yscale("log")
plt.title("Optimizer Comparison"); plt.legend(); plt.grid(alpha=0.3)
plt.tight_layout(); plt.show()
```

对数坐标下能清楚看到：Adam/AdamW 下降快得多，SGD 需要更大的 lr 才追得上。典型结果（随机种子固定下）：Adam 和 AdamW 在前几十个 epoch 就把 MSE 从 ~1.0 压到 ~0.3 附近，而 SGD(lr=0.05) 下降明显更缓，要到上百 epoch 才接近。这正是「自适应优化器收敛快」的直观证据。注意这只是小回归任务，SGD 的泛化优势在大数据集、深网络上才更明显，所以别因这张图就否定 SGD。

## 三、学习率调度：warmup + 余弦衰减

**大模型训练一定用学习率调度**，尤其是"先热身再衰减"。

```python
from torch.optim.lr_scheduler import (StepLR, CosineAnnealingLR,
                                      ReduceLROnPlateau, LambdaLR)

model = nn.Linear(10, 1)
optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3)

# ① 阶梯衰减：每 30 个 epoch 乘 0.1
s1 = StepLR(optimizer, step_size=30, gamma=0.1)

# ② 余弦退火：平滑降到接近 0
s2 = CosineAnnealingLR(optimizer, T_max=100, eta_min=1e-6)

# ③ 指标不涨就降（最实用）
s3 = ReduceLROnPlateau(optimizer, mode="min", factor=0.5, patience=5)

# ④ 自定义：warmup + 余弦（大模型标配）
def warmup_cosine(epoch, warmup=10, total=100, base=1e-3):
    if epoch < warmup:
        return (epoch + 1) / warmup          # 线性升到 1
    prog = (epoch - warmup) / max(1, total - warmup)
    return 0.5 * (1 + np.cos(np.pi * prog))  # 余弦降到 0

sched = LambdaLR(optimizer, lr_lambda=lambda e: warmup_cosine(e))

lrs = []
for e in range(100):
    lrs.append(optimizer.param_groups[0]["lr"])
    optimizer.step(); sched.step()

plt.figure(figsize=(7, 3.5))
plt.plot([l * 1e3 for l in lrs])
plt.xlabel("epoch"); plt.ylabel("lr × 1e-3")
plt.title("Warmup + Cosine Decay Schedule"); plt.grid(alpha=0.3)
plt.tight_layout(); plt.show()
```

PyTorch 的 `lr_scheduler` 和 `optimizer` 是配套使用的：每个 epoch（或每 step）调一次 `scheduler.step()`，它就会按策略修改 `optimizer.param_groups[0]["lr"]`。四种常见调度：

- **StepLR**：到点乘 `gamma`，阶梯形下降，简单但「断崖式」变化不够平滑。
- **CosineAnnealingLR**：像余弦曲线一样从初始值平滑降到 `eta_min`，训练后期学习率极小、精雕细琢，是 ImageNet 训练经典。
- **ReduceLROnPlateau**：盯着一个指标（如验证 loss），「连续 `patience` 个 epoch 不下降就乘 `factor` 减半」——最适合「指标卡住就降 lr 救一下」的实战场景。
- **自定义 warmup_cosine（大模型标配）**：前 `warmup` 个 epoch 线性把 lr 从 0 升到峰值，之后按余弦平滑降到 0。这兼顾了「稳启动」和「精收敛」。

**为什么需要 warmup？** 训练初期模型参数是随机的，梯度方向很不稳定。如果一开始就用大学习率，参数会被"带跑偏"甚至训练崩溃（大模型尤其明显）。**warmup 让学习率从小慢慢升上来，先稳住再加速。** 这就像赛车起步不能一脚油门到底——先缓给油让车对准赛道，再全速冲。大模型（尤其是几百亿参数）没有 warmup 几乎必崩，所以它是训练脚本里「看似不起眼、少了就废」的关键参数。

再讲「为什么后期要把 lr 降到接近 0」。训练后期模型已经接近最优解，损失面变得很平、很陡的分歧很少，此时若还用大 lr，参数会在最优点附近大幅震荡、永远落不进去——像开车到了家门口却不肯松油门，在门口来回冲。余弦衰减把 lr 平滑压到极小，相当于「最后轻手轻脚地微调」，让模型稳稳停在洼底。这就是为什么「先大步探索、后小步精修」几乎是所有 SOTA 训练的通用节奏。你不加衰减也能收敛，但通常要多训很久，且最终精度略低。

## 四、损失函数怎么选

损失函数是「模型预测和真实标签差距」的量化。差距越大，模型越该被「狠狠纠正」。选错损失函数，训练方向就错了。

```python
criterion_cls  = nn.CrossEntropyLoss()                 # 多分类（内部含 LogSoftmax）
criterion_bce  = nn.BCEWithLogitsLoss()                # 二分类/多标签（含 Sigmoid）
criterion_reg  = nn.MSELoss()                          # 回归
criterion_l1   = nn.L1Loss()                           # 回归（对异常值稳健）

# 类别不平衡：给少数类更大权重
weights = torch.tensor([1.0, 5.0, 2.0])                # 第1类样本少，权重给大
criterion_w = nn.CrossEntropyLoss(weight=weights)
```

**速查表**：

| 任务 | 输出 | 损失函数 |
|---|---|---|
| 二分类 | 1 个 logit | `BCEWithLogitsLoss` |
| 多分类 | C 个 logits | `CrossEntropyLoss` |
| 多标签分类 | C 个 logits（可多选） | `BCEWithLogitsLoss` |
| 回归 | 1 个值 | `MSELoss` / `L1Loss` |

**永远用带 `WithLogits` 的版本**（`BCEWithLogitsLoss` 而非 `BCELoss`）——内部合并了 Sigmoid，数值稳定得多。

补充几个选型要点：`MSELoss`（均方误差）对大误差惩罚极重，适合「预测连续值且误差大致符合高斯」的场景（如房价、温度），但异常值会主导训练；`L1Loss`（平均绝对误差）对异常值更稳健，不易被离群点带偏。`BCEWithLogitsLoss` 用于「每个类别独立二分类」（多标签，比如一张图同时有猫和狗），它和 `CrossEntropyLoss`（互斥多分类）的区别是：前者每个维度是独立的 Sigmoid，后者是整体 Softmax。**类别不平衡**时用 `weight` 给少数类更大权重，等价于在损失里「更在乎少数类被判错」，是处理欺诈检测、罕见病识别等不平衡数据的标配。

### 4.1 怎么看评估指标：accuracy / precision / recall / F1

损失（loss）只反映「模型有多贴近标签」，但业务上更关心「模型有多好用」，这就要看评估指标。本篇模板里算了 `accuracy` 和 `f1`，它们含义不同：

- **Accuracy（准确率）** = 预测对的样本数 / 总样本数。直观，但**在不平衡数据上会骗人**：100 个样本里 99 个负类，模型全猜「负」也能拿 99% 准确率，却毫无用处。
- **Precision（精确率）** = 预测为正的里面真正为正的比例。关心「你报的警报里有多少是真的」——比如垃圾邮件识别，怕误杀正常邮件，就看重 precision。
- **Recall（召回率）** = 真正为正的里面被你找出来的比例。关心「 positives 漏没漏」——比如疾病筛查，怕漏诊，就看重 recall。
- **F1** = precision 和 recall 的调和平均 `2·P·R/(P+R)`，综合两者，是分类任务最常用的「单一成绩单」。本篇用的 `average="macro"` 表示「各类算完 F1 再取平均」，避免大类掩盖小类。

一句话：**accuracy 看整体、F1 看均衡、precision/recall 看业务侧重点**。大模型评测里这些指标换了个名字（如「精确匹配 EM」「F1 分数」「困惑度 perplexity」），但本质仍是「预测和真实有多一致」。理解这四者的取舍，你才不会在验证集上被一个漂亮的 99% 误导。

## 五、完整工程级训练模板（重点，可直接抄）

```python
import torch, torch.nn as nn, numpy as np, os, copy
from torch.utils.data import DataLoader, TensorDataset
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import accuracy_score, f1_score

# ---------- 0. 配置 ----------
DEVICE = torch.device("cuda" if torch.cuda.is_available()
                      else "mps" if torch.backends.mps.is_available() else "cpu")
SEED = 42
torch.manual_seed(SEED); np.random.seed(SEED)

# ---------- 1. 数据 ----------
X, y = make_classification(n_samples=3000, n_features=20, n_informative=10,
                           n_classes=3, random_state=SEED)
X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2,
                                          random_state=SEED, stratify=y)
sc = StandardScaler()
X_tr = sc.fit_transform(X_tr).astype(np.float32)
X_te = sc.transform(X_te).astype(np.float32)

def to_ds(X, y, shuffle):
    return DataLoader(
        TensorDataset(torch.from_numpy(X), torch.from_numpy(y).long()),
        batch_size=64, shuffle=shuffle)

train_loader = to_ds(X_tr, y_tr, True)
test_loader  = to_ds(X_te, y_te, False)

# ---------- 2. 模型 ----------
class Classifier(nn.Module):
    def __init__(self, in_dim, hidden, out_dim, p=0.2):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(in_dim, hidden), nn.ReLU(), nn.Dropout(p),
            nn.Linear(hidden, hidden // 2), nn.ReLU(), nn.Dropout(p),
            nn.Linear(hidden // 2, out_dim),
        )
    def forward(self, x):
        return self.net(x)

model = Classifier(20, 128, 3).to(DEVICE)

# ---------- 3. 损失 / 优化器 / 调度 ----------
criterion = nn.CrossEntropyLoss()
optimizer = torch.optim.AdamW(model.parameters(), lr=3e-3, weight_decay=1e-4)
EPOCHS = 100
scheduler = torch.optim.lr_scheduler.LambdaLR(
    optimizer, lr_lambda=lambda e: warmup_cosine(e, warmup=5, total=EPOCHS))

# ---------- 4. 单轮训练 / 验证函数 ----------
def train_one_epoch(model, loader, criterion, optimizer, device, grad_clip=1.0):
    model.train()
    total_loss, n = 0.0, 0
    for X_b, y_b in loader:
        X_b, y_b = X_b.to(device), y_b.to(device)
        optimizer.zero_grad()
        logits = model(X_b)
        loss = criterion(logits, y_b)
        loss.backward()
        # 梯度裁剪：防止梯度爆炸（RNN/大模型必备）
        torch.nn.utils.clip_grad_norm_(model.parameters(), grad_clip)
        optimizer.step()
        total_loss += loss.item() * len(y_b)
        n += len(y_b)
    return total_loss / n

@torch.no_grad()
def evaluate(model, loader, device):
    model.eval()
    preds, targets = [], []
    for X_b, y_b in loader:
        X_b = X_b.to(device)
        logits = model(X_b)
        preds.append(logits.argmax(dim=1).cpu())
        targets.append(y_b)
    preds = torch.cat(preds); targets = torch.cat(targets)
    return accuracy_score(targets, preds), f1_score(targets, preds, average="macro")

# ---------- 5. 主循环（含早停 + checkpoint）----------
best_f1, best_state, patience, wait = 0.0, None, 12, 0
history = {"loss": [], "acc": [], "f1": [], "lr": []}

for ep in range(EPOCHS):
    loss = train_one_epoch(model, train_loader, criterion, optimizer, DEVICE)
    acc, f1 = evaluate(model, test_loader, DEVICE)
    history["loss"].append(loss)
    history["acc"].append(acc)
    history["f1"].append(f1)
    history["lr"].append(optimizer.param_groups[0]["lr"])
    scheduler.step()

    if f1 > best_f1:
        best_f1 = f1
        best_state = copy.deepcopy(model.state_dict())   # 存最优权重
        wait = 0
    else:
        wait += 1
        if wait >= patience:
            print(f"早停于 epoch {ep}，最优 f1={best_f1:.4f}")
            break

    if ep % 10 == 0 or ep == EPOCHS - 1:
        print(f"epoch {ep:3d}  loss={loss:.4f}  acc={acc:.4f}  f1={f1:.4f}  "
              f"lr={optimizer.param_groups[0]['lr']:.2e}")

# 恢复最优权重并保存
model.load_state_dict(best_state)
os.makedirs("checkpoints", exist_ok=True)
torch.save({"model": model.state_dict(),
            "epoch": ep, "best_f1": best_f1}, "checkpoints/best.pt")
print("最优 f1:", round(best_f1, 4), " 已保存到 checkpoints/best.pt")
```

这段模板是整篇的精华，逐行讲清每个工程要素：

- **配置区（DEVICE/SEED）**：`DEVICE` 一处定义、全局复用，避免「模型在 GPU、数据在 CPU」的报错；`SEED` 固定保证可复现。
- **`to_ds` 封装**：把「造 DataLoader」抽成函数，训练/验证各一行搞定，且验证集 `shuffle=False`。
- **模型 `.to(DEVICE)`**：一开始就上设备，后面数据也上同一设备。
- **`train_one_epoch`**：把「一个 epoch 的训练」封成函数，核心还是五步曲，但多了 `clip_grad_norm_`（梯度裁剪，防爆炸）和「按样本数加权平均 loss」（正确的 epoch 平均损失，而非简单除以 batch 数）。
- **`evaluate` 带 `@torch.no_grad()`**：评估不建图、省显存；`model.eval()` 关 Dropout/BatchNorm 的训练行为。
- **早停（Early Stopping）**：连续 `patience` 个 epoch 验证指标不创新高就停，防止在过拟合区空耗；同时用 `best_state` 记住「历史最优权重」，停止后**恢复最优再保存**——否则你存的是最后一个（可能已过拟合）的权重。
- **checkpoint 字典**：存 `state_dict` + 额外元信息（epoch、best_f1），比裸存权重更利于断点续训和复盘。

典型训练输出（随机种子固定下大体趋势）：
```
epoch   0  loss=1.0980  acc=0.33  f1=0.30  lr=6.00e-04
epoch  10  loss=0.8123  acc=0.61  f1=0.59  lr=2.40e-03
epoch  20  loss=0.5311  acc=0.79  f1=0.78  lr=3.00e-03
...
epoch  90  loss=0.1822  acc=0.95  f1=0.95  lr=1.20e-05
最优 f1: 0.9531  已保存到 checkpoints/best.pt
```
注意 lr 列：先随 warmup 升到 3e-3，再随余弦衰减慢慢降到接近 0——这正是标准曲线。

**这份模板包含的工程要素**：

| 要素 | 代码 | 作用 |
|---|---|---|
| 设备抽象 | `.to(DEVICE)` | CPU/GPU 通用 |
| 梯度清零 | `optimizer.zero_grad()` | 防累加 |
| 梯度裁剪 | `clip_grad_norm_` | 防爆炸 |
| 学习率调度 | `LambdaLR + warmup_cosine` | 稳启动、精收敛 |
| `model.train()/eval()` | 每轮切换 | Dropout 行为正确 |
| `@torch.no_grad()` | 评估函数 | 省显存 |
| 早停 + 最优权重 | `deepcopy(state_dict)` | 防过拟合 |
| checkpoint 保存 | `torch.save({...})` | 断点续训 |

## 六、训练曲线诊断

```python
fig, axes = plt.subplots(1, 3, figsize=(15, 4))
axes[0].plot(history["loss"]); axes[0].set_title("Train Loss"); axes[0].set_xlabel("epoch")
axes[1].plot(history["acc"], label="acc"); axes[1].plot(history["f1"], label="f1")
axes[1].legend(); axes[1].set_title("Val Metrics"); axes[1].set_xlabel("epoch")
axes[2].plot(history["lr"]); axes[2].set_title("Learning Rate"); axes[2].set_xlabel("epoch")
for a in axes: a.grid(alpha=0.3)
plt.tight_layout(); plt.show()
```

看到 loss 平稳下降、acc/f1 上升并收敛、lr 先升后降——**这就是一次健康的标准训练**。

学会「读曲线」是工程师的核心能力，补几类典型异常诊断：

- **训练 loss 不降**：lr 太大（在最优值附近震荡）或太小（几乎不动）、或梯度断链（`requires_grad=False` 漏设）、或数据/标签错位。
- **训练 loss 降但验证指标不升**：过拟合，该加 Dropout/数据增强/L2、或早停。
- **loss 出现 NaN/突变**：梯度爆炸（加梯度裁剪）、或 lr 无 warmup 一上来太大、或数据里有坏样本。
- **验证指标周期性抖动**：验证集太小、或 `shuffle` 误设为 True。
- **lr 曲线平直不衰减**：忘了 `scheduler.step()`，调度器没生效。

把这三张图养成「每次训练必看」的习惯，能省下无数排查时间。

## 七、断点续训

训练大模型动辄几天，必须支持中断恢复：

```python
ckpt = torch.load("checkpoints/best.pt", weights_only=True)
model.load_state_dict(ckpt["model"])
print("恢复到 epoch", ckpt["epoch"], " f1 =", round(ckpt["best_f1"], 4))

# 完整续训还应保存优化器状态
torch.save({"model": model.state_dict(),
            "optimizer": optimizer.state_dict(),
            "scheduler": scheduler.state_dict(),
            "epoch": ep}, "checkpoints/resume.pt")
```

断点续训的关键认知：**要无缝接着训，光存模型权重不够，还要存优化器和调度器的状态**。因为 Adam/AdamW 内部维护着「一阶/二阶动量」（`optimizer.state_dict()` 里有 `exp_avg`、`exp_avg_sq`），调度器记着「当前到了第几个 epoch」（`scheduler.state_dict()` 有 `last_epoch`）。只恢复模型权重、不恢复优化器，相当于「模型回到了当时的参数，但优化器的记忆清零了」，续训初期会抖动。所以真正的 checkpoint 至少包含「模型 + 优化器 + 调度器 + 当前 epoch」。大模型训练脚本里 `resume_from_checkpoint` 做的就是这件事——这也是为什么一次训练中断几小时后还能从断点无缝捡起。

## 八、常见坑与注意事项

| 坑 | 现象 | 解决 |
|---|---|---|
| 忘了 `optimizer.zero_grad()` | 梯度累加，loss 上升 | 每个 batch 前清零 |
| 评估忘了 `model.eval()` | 测试指标偏低且抖动 | `model.eval()` + `no_grad()` |
| 标签类型不对 | `expected Long` | `.long()` |
| 早停后没恢复最优权重 | 拿到的是过拟合模型 | 存并加载 `best_state` |
| lr 太大 + 无 warmup | 初期 loss 爆炸 | 加 warmup |
| `num_workers>0` 在 Windows 报错 | 多进程问题 | 设 0 或加 `if __name__ == "__main__"` |
| 验证集 shuffle=True | 指标不可复现（其实影响不大但不规范） | 验证/测试 shuffle=False |
| 显存溢出 OOM | `CUDA out of memory` | 减小 batch_size / 用 `no_grad` / 梯度累积 |

**显存不够的救命技巧——梯度累积**（用小 batch 模拟大 batch）：

```python
accum_steps = 4
for i, (X_b, y_b) in enumerate(train_loader):
    X_b, y_b = X_b.to(DEVICE), y_b.to(DEVICE)
    loss = criterion(model(X_b), y_b) / accum_steps    # 除以累积步数
    loss.backward()                                     # 只累积梯度
    if (i + 1) % accum_steps == 0:
        optimizer.step()                                # 累积够了才更新
        optimizer.zero_grad()
```

梯度累积的原理：把「大 batch 的梯度」拆成 `accum_steps` 个小 batch 的梯度之和——每小步只 `backward` 不 `step`，并除以 `accum_steps` 保持梯度尺度不变；累积够步数后统一 `step` 再清零。这样「物理 batch = 原 batch_size，`逻辑 batch = 原 batch_size × accum_steps`」，显存只占物理 batch 的，效果近似大 batch 的。大模型在单卡显存有限时，常靠 accum_steps 把逻辑 batch 堆到上千。**注意清零 `zero_grad()` 只在累积满时才调**，否则梯度会被中途冲掉。

显存排查的实战经验也顺带记一笔：遇到 `CUDA out of memory`，先别急着调小模型。按优先级排查——①评估时忘了 `torch.no_grad()` 会撑爆显存（最常见）；②`batch_size` 调小一半往往立竿见影；③开梯度累积用更小物理 batch；④`del` 掉不用的中间张量、及时 `torch.cuda.empty_cache()`；⑤用 `nvidia-smi` 看是不是别的进程占了卡。真正训大模型时，显存管理（mixed precision、`torch.cuda.amp`、ZeRO 分片）是独立的大课题，但本篇的「小 batch + 累积 + no_grad 评估」已经是个人项目够用的三板斧。

## 九、本篇小结

1. **`Dataset` + `DataLoader`** 是标准数据管道；语言模型的数据构造是"输入 x / 目标 = x 右移一位"。
2. **AdamW 是大模型标配**（解耦权重衰减），SGD 在 CV 仍有优势；`weight_decay` 控制正则。
3. **warmup + 余弦衰减**是标准学习率策略：先小步稳住，再大步加速，最后精细收敛。
4. 完整模板八大要素：设备抽象、梯度清零、梯度裁剪、lr 调度、train/eval 切换、no_grad 评估、早停存最优、checkpoint。
5. **梯度累积**可以在显存不足时模拟大 batch。

下一篇 **CNN 与计算机视觉**：处理图像需要全新的层——卷积。你会理解卷积核如何"提取特征"、为什么参数比全连接少得多、池化的意义，并用 PyTorch 搭一个 CNN 分类器。**顺便理解：为什么大模型最终抛弃了 CNN 而选择 Transformer。**

## 十、实战练习（可验证小任务）

1. **抄模板跑通**：把第五节的完整模板原样跑一遍，确认能输出 f1 ≥ 0.9 并生成 `checkpoints/best.pt`。验证：`print(accuracy_score(y_te, pred))` 或用 `torch.load` 重新加载后评估。
2. **换优化器对比**：把 `AdamW` 换成 `SGD(momentum=0.9)`，观察收敛曲线差异，思考为什么大模型偏爱 AdamW。
3. **加 ReduceLROnPlateau**：把 warmup_cosine 调度器换成 `ReduceLROnPlateau`，观察 lr 曲线如何「在指标卡住时自动下降」。
4. **梯度累积实验**：把 `batch_size` 调小到 16，配合 `accum_steps=4`，对比「不开累积」和「开累积」的最终指标是否接近，理解显存与效果的权衡。
5. **早停有效性验证**：故意把 `patience` 设很小（如 3），制造过拟合（减小数据量或增大模型），观察是否提前停止且恢复的是最优权重。
6. **断点续训**：训练到一半把 `checkpoints/resume.pt`（含优化器状态）存下，重启进程加载后接着训，确认 loss 曲线连贯、不回退。

## 十一、延伸阅读与下一步

- **官方教程**：PyTorch 官方「Training a Classifier」「Optimizing Model Parameters」教程，与本篇模板一一对应，建议对照读。
- **优化器深读**：理解 Adam 的 bias correction（`exp_avg` 的偏差修正）为何必要；延伸读 AdamW 原论文 *Decoupled Weight Decay Regularization*。
- **学习率理论**：延伸了解「学习率是训练里最重要的超参」，以及线性缩放规则（Linear Scaling Rule：batch 翻倍 lr 也翻倍）。
- **大模型训练脚本**：HuggingFace `Trainer`、DeepSpeed、Megatron 的训练循环本质就是本篇模板的超大规模版——你今天写的 `train_one_epoch` 对应它们的 `training_step`，早停/checkpoint 对应 `save_strategy`、`load_best_model_at_end`。
- **下一步**：下一篇《CNN 与计算机视觉》会用这套模板处理图像，你会第一次见到「卷积」这种全新层，并理解它为什么适合视觉、又为什么被 Transformer 取代。

> 本篇是《大模型开发从 0 到 1》专栏第 25 篇，阶段 4「深度学习与 PyTorch」第 4 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
