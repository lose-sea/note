<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 用 nn.Module 搭建你的第一个神经网络

**承上**：上一篇《PyTorch 张量与 autograd》我们学会了自动求导，但还在手动定义 W1、b1、W2、b2。

**本篇**：本篇用 nn.Module 搭积木：常用层、参数管理、前向写法与模型保存。

**启下**：下一篇《训练循环实战》把训练流程升级成可直接复用的工程级模板。

**学完这一节，你能动手做**：

1. 用 nn.Linear / Embedding / LayerNorm 搭出多层网络
2. 理解输出层为什么不加 Softmax、标签为什么用 Long
3. 保存与加载 state_dict（大模型 checkpoint 用的就是同一套机制）


上一篇我们学会了 Tensor 和 autograd，但还是手动定义 `W1`、`b1`、`W2`、`b2`，手动前向、手动更新。参数一多就没人受得了。

这一篇引入 PyTorch 最重要的抽象——**`nn.Module`**。有了它，搭神经网络变成搭积木：

```python
model = nn.Sequential(
    nn.Linear(2, 64), nn.ReLU(),
    nn.Linear(64, 2)
)
```

三行就是一个两层网络。而且**所有参数自动注册、自动管理、自动上 GPU**。

**更重要的是**：你所听说过的所有大模型（BERT、GPT、LLaMA），全都是用 `nn.Module` 搭出来的。学会了它，读 HuggingFace 源码就不发怵了。

## 一、nn.Module：所有模型的基类

`nn.Module` 做三件事：
1. **管理参数**（自动收集所有子模块的 `Parameter`）
2. **提供 `forward()` 接口**（你只需定义前向，反向自动生成）
3. **支持 `.to(device)`、`.train()`、`.eval()`、保存加载**

### 1.1 最小可用模型

```python
import torch
import torch.nn as nn

class SimpleNet(nn.Module):
    def __init__(self, in_dim, hidden, out_dim):
        super().__init__()                    # 必须调用！否则参数注册失败
        self.fc1 = nn.Linear(in_dim, hidden)  # 全连接层：y = xW^T + b
        self.act = nn.ReLU()
        self.fc2 = nn.Linear(hidden, out_dim)

    def forward(self, x):
        x = self.fc1(x)
        x = self.act(x)
        x = self.fc2(x)
        return x                # 输出 logits（不做 Softmax！）

model = SimpleNet(2, 64, 2)
print(model)
```

**两个必须记住的点**：

1. `super().__init__()` **必须在定义任何子模块之前调用**；
2. 只重写 `forward()`，**永远不要重写 `__call__()`**——调用模型时用 `model(x)`，PyTorch 的 `__call__` 会额外处理 hooks 等逻辑。

### 1.2 nn.Linear 到底做了什么

```python
layer = nn.Linear(3, 5)
print("weight 形状:", layer.weight.shape)   # (5, 3)  ← (out_features, in_features)！
print("bias 形状  :", layer.bias.shape)    # (5,)

x = torch.randn(4, 3)                      # batch=4, 特征=3
y = layer(x)
print("输出形状:", y.shape)                 # (4, 5)

# 手算验证：y = x @ W^T + b
manual = x @ layer.weight.T + layer.bias
print("与手算一致:", torch.allclose(y, manual, atol=1e-6))
```

**注意 `weight` 的形状是 `(out, in)`，不是 `(in, out)`**——这是 PyTorch 的约定，因为实现上 `x @ W.T` 对 batch 更友好。看形状时别搞反。

### 1.3 参数管理

```python
# 遍历所有参数
total = 0
for name, p in model.named_parameters():
    print(f"{name:20s} shape={tuple(p.shape)}  requires_grad={p.requires_grad}")
    total += p.numel()
print("总参数量:", total)

# 只取可训练参数（传给优化器）
params = [p for p in model.parameters() if p.requires_grad]
print("可训练参数组数:", len(params))
```

**`model.parameters()` 返回的正是优化器需要的东西**——下一篇的 `optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)` 就是这么来的。

### 1.4 冻结参数（微调大模型必用）

```python
# 冻结第一层（迁移学习/微调的常见操作）
for p in model.fc1.parameters():
    p.requires_grad = False

print("冻结后可训练参数量:",
      sum(p.numel() for p in model.parameters() if p.requires_grad))
```

**这就是 LoRA 微调的思想雏形**：冻结大部分参数，只训练少量参数。后面阶段 9 会详细讲。

## 二、nn.Sequential：快速堆叠

层是简单的线性堆叠时，用 `Sequential` 最省事：

```python
seq_model = nn.Sequential(
    nn.Linear(2, 64),
    nn.ReLU(),
    nn.Linear(64, 64),
    nn.ReLU(),
    nn.Linear(64, 2),
)
print(seq_model)

x = torch.randn(8, 2)
print("输出:", seq_model(x).shape)     # (8, 2)

# 也能按索引/名字访问子模块
print(seq_model[0])                    # 第一层
```

**什么时候用 Sequential，什么时候自己写 class？**

| 场景 | 选择 |
|---|---|
| 层简单线性堆叠 | `nn.Sequential` |
| 有分支、跳跃连接（ResNet）、多输入 | 自定义 `nn.Module` |
| 需要中间结果（如返回注意力权重） | 自定义 `nn.Module` |

Transformer 有残差连接和多头分支，**必须是自定义 Module**——这也是大模型源码看起来复杂的原因。

## 三、常用层速查

```python
batch, seq, d_model = 4, 10, 16

# ① 全连接（对每个位置独立变换）
fc = nn.Linear(d_model, 32)
print("Linear:", fc(torch.randn(batch, seq, d_model)).shape)   # (4,10,32)
# 注意：Linear 只作用在最后一维，前面的维度当 batch 处理

# ② 激活
print("ReLU:", nn.ReLU()(torch.randn(2,3)).shape)
print("GELU:", nn.GELU()(torch.randn(2,3)).shape)   # Transformer 标配

# ③ Dropout（训练时随机失活，eval 时自动关闭）
dp = nn.Dropout(p=0.5)
dp.train()
out_train = dp(torch.ones(2, 6))
dp.eval()
out_eval = dp(torch.ones(2, 6))
print("train 模式:", out_train[0].round(2))
print("eval  模式:", out_eval[0].round(2))   # 不变，且已缩放

# ④ LayerNorm（大模型必备，稳定训练）
ln = nn.LayerNorm(d_model)
x = torch.randn(batch, seq, d_model)
out = ln(x)
print("LayerNorm 后 mean:", out.mean().item().__round__(4),
      " std:", out.std().item().__round__(4))

# ⑤ Embedding（词嵌入：id → 向量）
vocab_size, emb_dim = 50000, 768
emb = nn.Embedding(vocab_size, emb_dim)
ids = torch.tensor([[1, 205, 3000]])
print("Embedding:", emb(ids).shape)    # (1, 3, 768)
print("参数量:", emb.weight.numel())    # 50000*768 = 38,400,000

# ⑥ BatchNorm（CV 常用，NLP 少用）
bn = nn.BatchNorm1d(d_model)
print("BatchNorm1d:", bn(torch.randn(batch, d_model)).shape)
```

**关键层的对比**：

| 层 | 作用 | 用在哪 |
|---|---|---|
| `nn.Linear` | 线性变换 | 到处都是 |
| `nn.ReLU/GELU` | 非线性 | GELU 用于 Transformer |
| `nn.Dropout` | 正则 | 全连接层后 |
| `nn.LayerNorm` | 归一化 | **Transformer 每层都有** |
| `nn.Embedding` | 词 id → 向量 | 模型输入端 |
| `nn.MultiheadAttention` | 注意力 | Transformer 核心 |

注意 `nn.Dropout` 和 `nn.BatchNorm` **在 train/eval 模式下行为不同**，务必用 `model.train()` / `model.eval()` 切换。

## 四、输出层为什么不加 Softmax？

**重要约定：PyTorch 的分类模型输出 logits（未归一化的分数），不做 Softmax。**

```python
# ❌ 不要这样
# self.fc2 = nn.Sequential(nn.Linear(64, 2), nn.Softmax(dim=-1))

# ✅ 应该这样：输出 logits
logits = model(x)

# Softmax 在损失函数里做
criterion = nn.CrossEntropyLoss()      # ← 内部已包含 LogSoftmax
loss = criterion(logits, y)            # y 是类别 id，不是 one-hot！
```

**为什么？** 两个原因：

1. **数值稳定**：`CrossEntropyLoss` 内部用 log-sum-exp 技巧，比"先 Softmax 再取 log"稳定得多；
2. **省计算**：推理时只需要 `argmax`，不必算 Softmax。

```python
# PyTorch 的 CrossEntropyLoss = LogSoftmax + NLLLoss，一步到位且数值稳定
logits = torch.tensor([[2.0, 1.0, 0.1], [0.5, 2.5, 0.3]])
y = torch.tensor([0, 1])               # 类别索引，shape (2,)

ce = nn.CrossEntropyLoss()
print("CrossEntropyLoss:", ce(logits, y).item())

# 手动验证
def manual_ce(logits, y):
    z = logits - logits.max(dim=-1, keepdim=True).values
    log_p = z - torch.log(torch.exp(z).sum(dim=-1, keepdim=True))
    return -log_p[torch.arange(len(y)), y].mean()
print("手算:", manual_ce(logits, y).item())
```

**推理时要概率就手动 Softmax**：

```python
probs = torch.softmax(logits, dim=-1)
print("各类概率:", probs.round(3))
```

## 五、完整实战：用 MLP 分类月牙数据

```python
import torch, torch.nn as nn
from sklearn.datasets import make_moons
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import accuracy_score
import numpy as np

torch.manual_seed(42); np.random.seed(42)

# ---- 1. 数据 ----
X, y = make_moons(n_samples=800, noise=0.18, random_state=42)
X = StandardScaler().fit_transform(X).astype(np.float32)
X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.25,
                                          random_state=42, stratify=y)

X_tr_t = torch.from_numpy(X_tr)
y_tr_t = torch.from_numpy(y_tr).long()      # CrossEntropyLoss 要求 Long 类型
X_te_t = torch.from_numpy(X_te)
y_te_t = torch.from_numpy(y_te).long()
```

### 5.1 定义模型

```python
class MLP(nn.Module):
    def __init__(self, in_dim=2, hidden=128, out_dim=2, dropout=0.1):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(in_dim, hidden), nn.ReLU(), nn.Dropout(dropout),
            nn.Linear(hidden, hidden), nn.ReLU(), nn.Dropout(dropout),
            nn.Linear(hidden, hidden // 2), nn.ReLU(),
            nn.Linear(hidden // 2, out_dim),      # 输出 logits
        )

    def forward(self, x):
        return self.net(x)

model = MLP()
print(f"参数量: {sum(p.numel() for p in model.parameters()):,}")

# 试跑一次前向，确认形状
with torch.no_grad():
    print("前向输出:", model(X_tr_t[:4]).shape)
```

### 5.2 训练（手工循环）

```python
criterion = nn.CrossEntropyLoss()
optimizer = torch.optim.Adam(model.parameters(), lr=1e-2)

epochs = 400
for ep in range(epochs):
    model.train()                          # 开启 Dropout
    optimizer.zero_grad()                  # ① 梯度清零

    logits = model(X_tr_t)                 # ② 前向
    loss = criterion(logits, y_tr_t)       # ③ 算损失

    loss.backward()                        # ④ 反向
    optimizer.step()                       # ⑤ 更新参数

    if ep % 80 == 0 or ep == epochs - 1:
        model.eval()                       # 关掉 Dropout
        with torch.no_grad():
            pred = model(X_tr_t).argmax(dim=1)
            acc = (pred == y_tr_t).float().mean().item()
        print(f"epoch {ep:3d}  loss={loss.item():.4f}  train_acc={acc:.3f}")
```

### 5.3 评估

```python
model.eval()
with torch.no_grad():
    logits_te = model(X_te_t)
    probs = torch.softmax(logits_te, dim=1)
    pred = logits_te.argmax(dim=1)

print("测试集准确率:", round(accuracy_score(y_te, pred.numpy()), 4))
print("前 5 个样本的预测概率:\n", probs[:5].numpy().round(3))
```

通常能到 **96%+**。

### 5.4 决策边界可视化

```python
import matplotlib.pyplot as plt

xx, yy = np.meshgrid(np.linspace(-2.5, 2.5, 200), np.linspace(-2.5, 2.5, 200))
grid = np.c_[xx.ravel(), yy.ravel()].astype(np.float32)
with torch.no_grad():
    Z = model(torch.from_numpy(grid)).argmax(dim=1).numpy().reshape(xx.shape)

plt.figure(figsize=(6, 5))
plt.contourf(xx, yy, Z, alpha=0.3, cmap="coolwarm")
plt.scatter(X[:, 0], X[:, 1], c=y, cmap="coolwarm", edgecolor="k", s=20)
plt.title(f"MLP Decision Boundary (acc={accuracy_score(y_te, pred.numpy()):.3f})")
plt.tight_layout(); plt.show()
```

## 六、模型保存与加载

```python
# 方式 1（推荐）：只存参数（state_dict）
torch.save(model.state_dict(), "mlp.pt")

# 加载：先建结构，再灌参数
model2 = MLP()
model2.load_state_dict(torch.load("mlp.pt", weights_only=True))
model2.eval()

with torch.no_grad():
    p2 = model2(X_te_t).argmax(dim=1)
print("加载后准确率:", round(accuracy_score(y_te, p2.numpy()), 4))

# 方式 2：存整个模型（不推荐，依赖类定义路径）
# torch.save(model, "mlp_full.pt")
```

**只存 `state_dict` 是标准做法**——它只是一个"参数名 → 张量"的字典，跨版本兼容性好。加载大模型（HuggingFace 的 `.bin` / `.safetensors`）用的也是这个机制。

```python
# 看看 state_dict 长什么样
for k, v in list(model.state_dict().items())[:4]:
    print(k, tuple(v.shape))
```

## 七、设备迁移与 train/eval 模式

```python
device = torch.device("cuda" if torch.cuda.is_available()
                      else "mps" if torch.backends.mps.is_available() else "cpu")
model.to(device)
X_dev, y_dev = X_tr_t.to(device), y_tr_t.to(device)

with torch.no_grad():
    print("在设备上输出:", model(X_dev[:2]).shape)

# train/eval 模式的区别（Dropout/BatchNorm）
model.train();  print("training =", model.training)
model.eval();   print("training =", model.training)
```

**三个必须记住的动作**：
- 训练前 `model.train()`
- 评估前 `model.eval()` + `torch.no_grad()`
- 数据模型同一个 `device`

## 八、常见坑与注意事项

| 坑 | 现象 | 解决 |
|---|---|---|
| 忘记 `super().__init__()` | 参数注册失败，优化器报错 | 第一行调用父类构造 |
| 输出层加了 Softmax | 训练慢、数值不稳 | 输出 logits，用 `CrossEntropyLoss` |
| 标签是 float | `expected Long but got Float` | `y.long()` |
| 忘了 `model.eval()` | 测试准确率莫名偏低 | 评估前切 eval |
| 直接重写 `__call__` | hooks 失效 | 只重写 `forward` |
| `nn.Linear` 权重形状搞反 | 永远是 `(out, in)` | 记住约定 |
| 冻结参数后还传全部给优化器 | 浪费/报错 | 过滤 `requires_grad` |
| 保存整个模型而非 state_dict | 换环境加载失败 | 存 `state_dict` |

## 九、本篇小结

1. **`nn.Module`** 是 PyTorch 一切模型的基类：自动管理参数、只需定义 `forward()`、支持设备迁移与保存加载。
2. **`nn.Linear(in, out)` 的权重形状是 `(out, in)`**；`nn.Embedding` 就是一张可学习的查表；`nn.LayerNorm`/`GELU`/`Dropout` 是 Transformer 的常客。
3. **输出层不加 Softmax**，直接出 logits，交给 `nn.CrossEntropyLoss`（内部已含 LogSoftmax，数值更稳）。
4. **训练五步曲**：`zero_grad` → `forward` → `loss` → `backward` → `step`；评估时 `model.eval()` + `no_grad()`。
5. **模型保存只存 `state_dict`**，加载时先建结构再灌参数——大模型 checkpoint 也是这个机制。
6. **冻结 `requires_grad=False`** 是微调的基础（LoRA 就是它的进阶版）。

下一篇 **训练循环实战**：我们会把这一篇的手写循环升级成工程级模板——`Dataset`/`DataLoader` 批量加载、SGD/Adam 优化器对比、学习率调度、早停、checkpoint 保存、训练曲线绘制。**这份模板你以后每个项目都能直接抄。**

> 本篇是《大模型开发从 0 到 1》专栏第 24 篇，阶段 4「深度学习与 PyTorch」第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
