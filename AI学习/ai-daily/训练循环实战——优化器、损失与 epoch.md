<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 训练循环实战——优化器、损失与 epoch

**承上**：上一篇《用 nn.Module 搭建你的第一个神经网络》我们搭好了网络，但训练循环还是简版。

**本篇**：本篇升级成工程级模板：DataLoader、AdamW、warmup 调度、早停与 checkpoint。

**启下**：下一篇《CNN 与计算机视觉》用这套模板处理图像数据。

**学完这一节，你能动手做**：

1. 写出可直接抄进任何项目的训练 + 验证 + 早停 + 存盘模板
2. 用梯度累积在显存不足时模拟大 batch
3. 看懂优化器与学习率策略，知道大模型为什么都用 AdamW + warmup


上一篇我们用 `nn.Module` 搭出了 MLP，训练循环还是手写的简版。这一篇把它升级成**可以直接抄进任何项目的工程级模板**：

- `Dataset` / `DataLoader` 批量加载与打乱
- SGD / Adam / AdamW 优化器对比（大模型为什么都用 AdamW）
- 学习率调度（warmup + 余弦衰减，大模型标配）
- 早停、checkpoint 保存、梯度裁剪
- 完整训练 + 验证 + 曲线绘制

**这份模板会一直用到微调大模型那一步**，值得反复读。

## 一、Dataset 与 DataLoader：数据管道

自己切 batch 太麻烦，PyTorch 提供了标准解法。

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

**注意 `y` 是 `x` 右移一位**——这就是语言模型"用前 n 个词预测下一个词"的数据构造方式，自监督标签是数据自己给的。

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

## 二、优化器：SGD vs Adam vs AdamW

```python
model = nn.Sequential(nn.Linear(10, 64), nn.ReLU(), nn.Linear(64, 3))

sgd    = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
adam   = torch.optim.Adam(model.parameters(), lr=1e-3)
adamw  = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
```

### 2.1 三者对比

| 优化器 | 思路 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| **SGD(+momentum)** | 沿梯度走，加动量惯性 | 泛化好、显存省 | 需精调 lr、收敛慢 | CV 任务（ResNet 论文用法） |
| **Adam** | 自适应学习率（一阶+二阶动量） | 收敛快、对 lr 不敏感 | 泛化略差、weight decay 有坑 | 默认首选 |
| **AdamW** | Adam + 正确的权重衰减 | ✅ 解耦正则，泛化更好 | — | **大模型微调标配** |

**为什么大模型都用 AdamW？** 因为 Adam 里的 L2 正则实现方式有问题（与自适应学习率耦合），AdamW 把权重衰减**解耦**出来，直接在参数更新时衰减，效果明显更好。

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

对数坐标下能清楚看到：Adam/AdamW 下降快得多，SGD 需要更大的 lr 才追得上。

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

**为什么需要 warmup？** 训练初期模型参数是随机的，梯度方向很不稳定。如果一开始就用大学习率，参数会被"带跑偏"甚至训练崩溃（大模型尤其明显）。**warmup 让学习率从小慢慢升上来，先稳住再加速。**

## 四、损失函数怎么选

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

## 九、本篇小结

1. **`Dataset` + `DataLoader`** 是标准数据管道；语言模型的数据构造是"输入 x / 目标 = x 右移一位"。
2. **AdamW 是大模型标配**（解耦权重衰减），SGD 在 CV 仍有优势；`weight_decay` 控制正则。
3. **warmup + 余弦衰减**是标准学习率策略：先小步稳住，再大步加速，最后精细收敛。
4. 完整模板八大要素：设备抽象、梯度清零、梯度裁剪、lr 调度、train/eval 切换、no_grad 评估、早停存最优、checkpoint。
5. **梯度累积**可以在显存不足时模拟大 batch。

下一篇 **CNN 与计算机视觉**：处理图像需要全新的层——卷积。你会理解卷积核如何"提取特征"、为什么参数比全连接少得多、池化的意义，并用 PyTorch 搭一个 CNN 分类器。**顺便理解：为什么大模型最终抛弃了 CNN 而选择 Transformer。**

> 本篇是《大模型开发从 0 到 1》专栏第 25 篇，阶段 4「深度学习与 PyTorch」第 4 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
