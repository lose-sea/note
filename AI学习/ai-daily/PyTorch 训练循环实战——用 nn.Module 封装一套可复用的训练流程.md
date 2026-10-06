<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# PyTorch 训练循环实战——用 nn.Module 封装一套可复用的训练流程

## 一、为什么"会写张量"不等于"会训练模型"

很多人学 PyTorch 的第一步是搞懂张量和自动求导，但真正动手时发现：`torch.tensor` 会用，`backward()` 会调，可一旦要把它们**串成一个能跑通的训练流程**，就乱了。

问题出在——训练循环不是一个 API，而是一套**固定范式**：

```
前向传播 → 计算损失 → 梯度清零 → 反向传播 → 更新参数
   ↑                                                │
   └──────────────── 重复 N 轮 ─────────────────────┘
```

这五步的顺序、位置、少一步会出什么问题，比任何张量操作都值得先弄清楚。这篇就写一套**能直接复用到别的项目上的训练框架**，包括 `nn.Module` 封装、`Dataset` 封装、训练/验证分离、早停与最优权重保存。

## 二、整体结构先看一遍

```
┌──────────────────────────────────────────────────────────┐
│                    训练系统结构                            │
├──────────────────────────────────────────────────────────┤
│  数据层  OrderDataset / DataLoader                        │
│            │  产出 (features, label) 批次                  │
│            ▼                                              │
│  模型层  class Net(nn.Module)                             │
│            │  forward() 返回 logits                        │
│            ▼                                              │
│  训练层  Trainer.fit()                                     │
│            ├─ train_one_epoch()   前向+反向+更新            │
│            ├─ validate()          只前向，no_grad          │
│            └─ 早停 + 保存 best.pt                           │
│            ▼                                              │
│  产物    best.pt（最优权重）/ metrics 曲线                   │
└──────────────────────────────────────────────────────────┘
```

## 三、第一段代码：数据与模型封装

```python
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader

torch.manual_seed(42)
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

# ---------- 1. 造一份二分类数据 ----------
def make_data(n=4000, d=12):
    X = np.random.randn(n, d).astype("float32")
    w = np.random.randn(d, 1).astype("float32")
    logits = X @ w + 1.5 * X[:, :1] ** 2          # 故意加一点非线性
    y = (1 / (1 + np.exp(-logits.squeeze())) > 0.5).astype("float32")
    return X, y.reshape(-1, 1)

X, y = make_data()
X_tr, y_tr = torch.from_numpy(X[:3200]), torch.from_numpy(y[:3200])
X_va, y_va = torch.from_numpy(X[3200:]), torch.from_numpy(y[3200:])

# ---------- 2. Dataset 封装 ----------
class TabularDataset(Dataset):
    """把 (特征, 标签) 张量包装成 Dataset，供 DataLoader 批量化"""
    def __init__(self, X, y):
        self.X, self.y = X, y

    def __len__(self):                 # DataLoader 靠它决定 epoch 长度
        return self.X.shape[0]

    def __getitem__(self, i):          # 每次返回一个样本（含标签）
        return self.X[i], self.y[i]

train_loader = DataLoader(TabularDataset(X_tr, y_tr), batch_size=128, shuffle=True)
val_loader = DataLoader(TabularDataset(X_va, y_va), batch_size=512, shuffle=False)

# ---------- 3. nn.Module 封装模型 ----------
class MLP(nn.Module):
    def __init__(self, in_dim, hidden=64):
        super().__init__()             # 必须调用，否则参数注册不上
        self.net = nn.Sequential(
            nn.Linear(in_dim, hidden), nn.ReLU(),
            nn.Dropout(0.2),
            nn.Linear(hidden, hidden // 2), nn.ReLU(),
            nn.Linear(hidden // 2, 1),   # 输出 1 个 logit
        )

    def forward(self, x):
        return self.net(x)             # 返回 logits，不接 sigmoid

model = MLP(in_dim=X.shape[1]).to(device)
print(model)
print("参数量：", sum(p.numel() for p in model.parameters()))
```

**两个必须记住的约定：**

1. `forward()` 返回 **logits**（未过激活的原始输出），不要在里面加 `sigmoid`。因为 `BCEWithLogitsLoss` 内部已经把 sigmoid + 交叉熵合并了，数值上更稳定（避免 `log(0)` 带来的溢出）。
2. `super().__init__()` 一定要写。`nn.Module` 靠它初始化内部的 `_parameters`、`_modules` 字典；漏写时 `model.parameters()` 会是空的，优化器什么都学不到。

## 四、第二段代码：可复用的 Trainer

把训练循环抽成类，好处是换模型、换数据集时不用重写流程。

```python
class Trainer:
    def __init__(self, model, train_loader, val_loader,
                 lr=1e-3, weight_decay=1e-4, patience=5):
        self.model = model.to(device)
        self.train_loader, self.val_loader = train_loader, val_loader
        self.criterion = nn.BCEWithLogitsLoss()
        self.optimizer = torch.optim.AdamW(
            model.parameters(), lr=lr, weight_decay=weight_decay
        )
        # 学习率调度：验证指标不降时自动减半，比手动调 lr 省心
        self.scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(
            self.optimizer, mode="min", factor=0.5, patience=2
        )
        self.patience = patience
        self.history = {"train_loss": [], "val_loss": [], "val_acc": []}

    def _run_epoch(self, loader, train: bool):
        self.model.train(train)
        total_loss, correct, n = 0.0, 0, 0
        for xb, yb in loader:
            xb, yb = xb.to(device), yb.to(device)
            with torch.set_grad_enabled(train):
                logits = self.model(xb)
                loss = self.criterion(logits, yb)
                if train:
                    self.optimizer.zero_grad()   # ① 先清零上轮梯度
                    loss.backward()              # ② 再反传，累积新梯度
                    self.optimizer.step()        # ③ 最后更新参数
            total_loss += loss.item() * xb.size(0)
            pred = (torch.sigmoid(logits) > 0.5).float()
            correct += (pred == yb).sum().item()
            n += xb.size(0)
        return total_loss / n, correct / n

    def fit(self, epochs=50):
        best_loss, best_state, wait = float("inf"), None, 0
        for ep in range(1, epochs + 1):
            tr_loss, tr_acc = self._run_epoch(self.train_loader, train=True)
            va_loss, va_acc = self._run_epoch(self.val_loader, train=False)
            self.scheduler.step(va_loss)

            self.history["train_loss"].append(tr_loss)
            self.history["val_loss"].append(va_loss)
            self.history["val_acc"].append(va_acc)

            if va_loss < best_loss - 1e-4:
                best_loss, wait = va_loss, 0
                best_state = {k: v.clone() for k, v in self.model.state_dict().items()}
            else:
                wait += 1

            if ep % 5 == 0 or ep == 1:
                print(f"epoch {ep:3d} | train {tr_loss:.4f}/{tr_acc:.3f} "
                      f"| val {va_loss:.4f}/{va_acc:.3f} "
                      f"| lr {self.optimizer.param_groups[0]['lr']:.2e}")

            if wait >= self.patience:          # 早停：连续 patience 轮没进步就停
                print(f"早停于 epoch {ep}（验证损失 {self.patience} 轮未下降）")
                break

        self.model.load_state_dict(best_state)  # 回滚到最优权重
        torch.save(best_state, "best.pt")
        return self.history

trainer = Trainer(model, train_loader, val_loader)
hist = trainer.fit(epochs=60)
```

典型输出：

```
epoch   1 | train 0.5231/0.741 | val 0.4118/0.812 | lr 1.00e-03
epoch   5 | train 0.3394/0.858 | val 0.3321/0.869 | lr 1.00e-03
epoch  10 | train 0.3182/0.869 | val 0.3226/0.874 | lr 5.00e-04
epoch  20 | train 0.3087/0.875 | val 0.3211/0.876 | lr 2.50e-04
早停于 epoch 25（验证损失 5 轮未下降）
```

## 五、训练循环里最关键的三个"顺序问题"

这三步写错顺序，模型会安静地学不动——不报错，只是指标上不去，最难排查。

```
错误写法 ①：先 step 再 zero_grad
   step() → zero_grad() → backward()
   ✗ 结果：梯度被清掉了，参数永远不更新

错误写法 ②：忘记 zero_grad
   backward() → step() → backward() → step()
   ✗ 结果：梯度跨轮累加，等效学习率不断变大，损失震荡发散

正确写法：
   zero_grad() → backward() → step()
   ✓ 清零 → 反传 → 更新
```

还有一个同样隐蔽的问题：**验证阶段忘了 `model.eval()` 和 `torch.no_grad()`**。

```python
# 验证必须显式切换，否则两个坑都会踩
model.eval()                       # 关掉 Dropout / 改写 BatchNorm 为推理模式
with torch.no_grad():              # 不建计算图，省显存、提速
    logits = model(X_va.to(device))
    val_loss = nn.BCEWithLogitsLoss()(logits, y_va.to(device))
    val_acc = ((torch.sigmoid(logits) > 0.5).float() == y_va.to(device)).float().mean()
print(f"验证集 loss={val_loss.item():.4f} acc={val_acc.item():.4f}")
```

漏掉 `model.eval()` 的后果：Dropout 在验证时还在随机丢神经元，指标会莫名抖动；漏掉 `no_grad()` 的后果：显存占用翻倍，大模型直接 OOM。

顺带补一个几乎零成本、但能立刻提速的改动——**混合精度训练（AMP）**。它让前向和反向用 fp16 计算、参数仍用 fp32 保存，在支持 Tensor Core 的显卡上通常能省 30%~50% 显存、提速 1.5~2 倍：

```python
scaler = torch.cuda.amp.GradScaler()          # 处理 fp16 梯度下溢

for xb, yb in train_loader:
    xb, yb = xb.to(device), yb.to(device)
    with torch.autocast(device_type=device.type, dtype=torch.float16):
        logits = model(xb)
        loss = criterion(logits, yb)           # 损失在 autocast 内计算

    scaler.scale(loss).backward()              # 放大损失再反传，防止梯度变 0
    scaler.unscale_(optimizer)                 # 还原真实梯度后才能裁剪
    nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    scaler.step(optimizer)                     # 内部会自动跳过 inf/nan 的更新
    scaler.update()
    optimizer.zero_grad()
```

三个容易踩的点：`clip_grad_norm_` 必须放在 `unscale_` 之后（否则裁剪的是被放大过的梯度）；验证阶段也要用 `autocast` 才能享受提速；CPU 上 AMP 收益很小，可以不启用。

## 六、训练技巧对比

| 问题现象 | 常见原因 | 对应调整 |
|---|---|---|
| 训练 loss 不降 | 学习率太小 / 梯度被 zero_grad 顺序搞乱 | 调大 lr，检查调用顺序 |
| 训练 loss 震荡发散 | 学习率太大 / 忘 zero_grad / 没做归一化 | 降 lr，加 `weight_decay` |
| 训练 loss 降、验证 loss 升 | 过拟合 | 加 Dropout、早停、数据增强 |
| 两者都不降 | 模型太小或数据本身无信号 | 加深网络、检查特征 |
| 验证指标剧烈抖动 | 漏 `model.eval()` / batch 太小 | 补 eval()，增大 batch |
| 显存 OOM | 漏 `no_grad()` / batch 太大 | 补 no_grad()，降 batch |

## 七、几个常见的坑

**坑 1：把 `loss` 累加时不乘 `batch_size`。**
常见的 `total_loss += loss.item()` 在小 batch 场景下会让最后一个小 batch 权重过大，指标失真。正确写法是 `loss.item() * xb.size(0)`，最后再除以总样本数。

**坑 2：`BCEWithLogitsLoss` 前面又加了一次 sigmoid。**
这会导致梯度被压平，模型几乎学不动。记住：**用 `BCEWithLogitsLoss` 就不要在 `forward` 里加 sigmoid**；如果一定要自己在 forward 里加 sigmoid，损失函数要换成 `BCELoss`。

**坑 3：早停后忘了回滚最优权重。**
很多实现一发现早停就直接 break，模型停在"已经变差的那一轮"。一定要像上面那样把 `best_state` 存下来，训练结束 `load_state_dict` 回滚。

**坑 4：`best_state` 用的是引用而不是拷贝。**
`state_dict()` 返回的是张量引用，直接存下来会随训练一直变。必须 `{k: v.clone() ...}` 深拷贝一份。

**坑 5：`DataLoader` 忘了 `shuffle=True`（训练集）。**
不打乱时，样本按类别顺序排列会让每个 batch 的分布极度偏斜，收敛变慢甚至不收敛。训练集开 shuffle，验证/测试集关掉。

## 八、小结

这套流程的价值在于**可复用**：换任务时，你只需要改三处——`Dataset` 的 `__getitem__`、`MLP` 的网络结构、以及损失函数。

```
换任务时要改的          不用改的
─────────────────────  ─────────────────────────
Dataset 读取逻辑        Trainer.fit()
模型 forward 结构       训练/验证循环
损失函数（BCE→CE）      zero_grad/backward/step 顺序
                       早停 + 最优权重保存
                       lr 调度策略
```

先把这套骨架背下来、跑通一遍，后面再看别人的开源项目代码就会非常快——因为你会发现，**几乎所有 PyTorch 训练脚本，都是这五步循环的不同包装而已**。
