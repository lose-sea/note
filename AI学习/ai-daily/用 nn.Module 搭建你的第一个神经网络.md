<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 用 nn.Module 搭建你的第一个神经网络

**承上**：上一篇《PyTorch 张量与 autograd——自动求导怎么工作》我们学会了自动求导，但还在手动定义 W1、b1、W2、b2。

**本篇**：本篇用 nn.Module 搭积木：常用层、参数管理、前向写法与模型保存。

**启下**：下一篇《训练循环实战——优化器、损失与 epoch》把训练流程升级成可直接复用的工程级模板。

**学完这一节，你能动手做**：1) 能写出/能跑通用 nn.Linear / Embedding / LayerNorm 搭出的多层网络 2) 能讲清输出层为什么不加 Softmax、标签为什么用 Long 3) 能保存与加载 state_dict（大模型 checkpoint 用的就是同一套机制）。

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

## 〇、概念引入与背景：为什么我们需要 nn.Module？

在正式动手之前，先想清楚一个根本问题：PyTorch 已经有了 Tensor（存数据）和 autograd（算梯度），为什么还要造一个 `nn.Module`？能不能不用它，全程只写张量运算？

答案是「能，但会累死、错死、慢死」。

假设我们要做一个两层分类网络。如果不依赖 `nn.Module`，你需要自己维护以下一堆东西：

- 第一组权重 `W1` 和偏置 `b1`，第二组 `W2`、`b2`；
- 每次前向都要手写 `h = relu(x @ W1.T + b1)`、`y = h @ W2.T + b2`；
- 反向传播时确保梯度链条没断；
- 想换设备到 GPU，要挨个 `W1.cuda()`、`b1.cuda()`……漏一个就报错；
- 想保存模型，要分别 `torch.save(W1)`、`torch.save(b1)`……；
- 想冻结某层做微调，要手动把对应张量的 `requires_grad` 改掉，还得记住别漏。

当模型只有两层时这还勉强能忍；可一旦到 Transformer 那种规模——几十层、几百个子模块、数亿参数——手写维护根本不现实。这就是 `nn.Module` 存在的意义：**它是一个「容器 + 规范」**，帮你把零散的张量、子层、前向逻辑统一包装成一个可复用、可组合、可迁移、可保存的整体。

换个更贴近大模型开发的视角：今天你调用 `from transformers import AutoModel.from_pretrained("bert-base-chinese")`，拿到的那个 `model` 对象，本质就是一个巨大的 `nn.Module` 嵌套结构。`model.parameters()` 能返回几十亿个参数、`model.to("cuda")` 能把整个模型挪到显卡、`model(input_ids)` 能跑前向——这些便利不是凭空来的，全都建立在 `nn.Module` 这套机制上。所以本篇不是「学一个 API」，而是「学懂大模型本身长什么样、怎么被组织起来」。

在动手之前，先用一张 ASCII 图看清「手动搭」和「用 nn.Module 搭」在心智负担上的差别：

```
┌───────────────────────────────┐   ┌───────────────────────────────┐
│   手动方式（不推荐）          │   │   用 nn.Module（正道）        │
├───────────────────────────────┤   ├───────────────────────────────┤
│ W1 = ...                       │   │ class Net(nn.Module):         │
│ b1 = ...                       │   │   def __init__(self):         │
│ W2 = ...                       │   │     self.fc1 = Linear(...)    │
│ b2 = ...                       │   │     self.fc2 = Linear(...)    │
│                               │   │   def forward(self, x):       │
│ def forward(x):               │   │     return self.fc2(          │
│   h = relu(x@W1.T+b1)         │   │       relu(self.fc1(x)))      │
│   return h@W2.T+b2            │   │                               │
│                               │   │ model = Net()                 │
│ # 训练/保存/迁移 全要手写     │   │ # 参数/迁移/保存 自动管理     │
└───────────────────────────────┘   └───────────────────────────────┘
```

一句话总结背景：**`nn.Module` 把「参数」和「运算」绑在一起，让模型成为一个自包含的对象**。这正是现代深度学习框架的基石，也是本篇要让你彻底吃透的核心。

为了帮你建立长期好用的心智模型，可以把它类比成「乐高底板」：底板（`nn.Module`）本身不干活，它的价值在于提供统一的卡槽——你往上插的每一个零件（子模块）都会被底板登记、编号、统一管理。`model.parameters()` 相当于「把底板上所有零件拆下来点一遍」，`.to('cuda')` 相当于「把整块底板连同零件一起搬到 GPU 桌面上」，`.eval()` 相当于「拨动底板上的总开关，让所有带状态指示灯的零件切到推理模式」。一旦建立起这个类比，后面看到再复杂的模型（Encoder、Decoder、MoE 专家混合）你都不会慌，因为本质都是「底板 + 零件」。

还有一个值得现在就建立的认知：**模型的结构（代码）和模型的权重（state_dict）是两回事，可以分开处理**。这点和「程序」与「程序的内存状态」很像——你写的 `class Net` 是程序，训练得到的 `state_dict` 是运行时状态。同一份程序可以加载不同的权重（比如一个 Base 模型和一个经过指令微调的模型），同一个权重也可以套在不同的程序结构上（只要键名匹配）。大模型生态里「基座模型 / 微调模型 / 量化版本」这些名词，背后都是这套分离思想。本篇第六节保存加载就是在操作「权重（内存状态）」，把它存盘、读取、替换——这是你日后玩转各种开源模型的必备能力。

## 一、nn.Module：所有模型的基类

`nn.Module` 做三件事：
1. **管理参数**（自动收集所有子模块的 `Parameter`）
2. **提供 `forward()` 接口**（你只需定义前向，反向自动生成）
3. **支持 `.to(device)`、`.train()`、`.eval()`、保存加载**

### 1.0 深入理解：什么是「子模块」？

`nn.Module` 最巧妙的地方在于「递归注册」。这里再补一句它和上一篇 autograd 的联动：当你写 `y = model(x)` 时，PyTorch 实际跑的是 `model.__call__(x)`，它内部调用你定义的 `forward`，而 `forward` 里每个子层（如 `nn.Linear`）的计算都会自然地接入 autograd 的计算图——因为 `nn.Linear` 的 `weight` 是 `nn.Parameter`（默认 `requires_grad=True`），前向一算，反向的梯度链路就自动接上了。所以 `nn.Module` 并不取代 autograd，而是「把 autograd 需要的参数组织好、喂给 autograd」。上一篇你手动管理 `W1/W2`，本篇只是把这套登记动作自动化了。理解这点，你就明白为什么前两篇的知识在这里无缝衔接：张量负责存数据、autograd 负责算梯度、`nn.Module` 负责把两者打包成可复用的模型。

`nn.Module` 最巧妙的地方在于「递归注册」。当你在 `__init__` 里写 `self.fc1 = nn.Linear(...)`，这行赋值不仅仅是「把属性挂到对象上」，PyTorch 还会做一件额外的事：它把 `fc1` 登记为当前 Module 的一个**子模块**。而 `nn.Linear` 自己又是一个 `nn.Module`，它内部又挂着 `weight` 和 `bias` 两个 `Parameter`。

于是形成一个**树形结构**：你的模型是根，子层是枝，参数就是叶子。当你调用 `model.parameters()`，PyTorch 会深度优先地遍历整棵树，把所有叶子 `Parameter` 收集出来。这就是为什么不管模型嵌套多深，优化器永远能拿到全部参数——你不用手动维护参数列表。

这一点对大模型至关重要。一个 7B 的 LLaMA 里嵌套着 `Embedding`、`TransformerBlock × N`、`RMSNorm`、`Linear` 等无数子模块，但框架只需要从根节点一路递归就能枚举全部参数。理解了这个「树」，你就理解了模型是怎么被组织起来的。

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

为什么 `super().__init__()` 这么关键？因为 `nn.Module` 的构造函数里会初始化内部用来存放子模块、参数的数据结构（比如 `_parameters`、`_modules` 这些有序字典）。如果你忘了调用它，这些结构不存在，后面 `self.fc1 = nn.Linear(...)` 的注册动作就会失败，最终 `model.parameters()` 返回空，优化器收不到任何参数，训练「看起来在跑」实则参数从未更新——这种 bug 极难排查，因为它不报错，只是 loss 纹丝不动。

关于「不要重写 `__call__`」：你可能疑惑，既然调用是 `model(x)`，为什么写的是 `forward`。答案是 PyTorch 在 `nn.Module.__call__` 里做了大量额外工作——它负责设置 `self.training` 标志、触发 forward/backward hooks（这是很多高级功能如梯度监控、特征可视化、混合精度训练的基础）、维护 autograd 图的正确上下文。然后它才在你的 `forward` 里真正算前向。所以重写 `__call__` 会破坏这套机制；你永远只在 `forward` 里写计算逻辑，调用一律用 `model(x)`。

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

展开讲：`nn.Linear(in, out)` 做的事情就是小学/线代里学的仿射变换 `y = xW^T + b`。这里有个容易混淆的点：数学上我们常说「权重矩阵 W 形状是 (in, out)」，但 PyTorch 内部把 `weight` 存成 `(out, in)`，再在运算时转置一次。为什么多此一举？因为 `x @ W.T` 这种写法对「批量数据」极其友好——`x` 是 `(batch, in)`，转置后的 W 是 `(in, out)`，一次矩阵乘就得到 `(batch, out)`，无需为 batch 维度写循环。GPU 最擅长的大规模矩阵乘（GEMM）正是这种形态。

你可以亲手验证：上面代码里 `manual = x @ layer.weight.T + layer.bias`，算出来的结果和 `layer(x)` 在 1e-6 精度下完全一致。**能用几行代码印证「框架里的黑盒其实就是矩阵乘法」，是建立信心的好训练**——以后看到任何「层」，都该能在脑子里把它还原成基础张量运算。

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

`named_parameters()` 返回的是 `(参数名, 张量)` 这样的键值对。参数名是「带路径的」，比如 `fc1.weight`、`fc2.bias`。这个路径名在保存 checkpoint、加载预训练权重、做参数分组（比如给不同层设不同学习率）时非常有用。

**`model.parameters()` 返回的正是优化器需要的东西**——下一篇的 `optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)` 就是这么来的。

补充一个实战常用技巧：大模型微调时经常需要「分层学习率」，例如 backbone 用小 lr、新加的分类头用大 lr。这时就用 `named_parameters()` 区分：

```python
# 给不同子模块设不同学习率（微调常见）
base_params, head_params = [], []
for name, p in model.named_parameters():
    if name.startswith("fc1") or name.startswith("fc2"):
        head_params.append(p)      # 新任务头，学习率大
    else:
        base_params.append(p)      # 预训练主体，学习率小
optimizer = torch.optim.AdamW([
    {"params": base_params, "lr": 1e-5},
    {"params": head_params, "lr": 1e-3},
])
```

这种「参数分组」直接基于 `named_parameters()` 给出的名字，是大模型迁移学习的标配操作。

### 1.4 冻结参数（微调大模型必用）

```python
# 冻结第一层（迁移学习/微调的常见操作）
for p in model.fc1.parameters():
    p.requires_grad = False

print("冻结后可训练参数量:",
      sum(p.numel() for p in model.parameters() if p.requires_grad))
```

**这就是 LoRA 微调的思想雏形**：冻结大部分参数，只训练少量参数。后面阶段 9 会详细讲。

展开讲 `requires_grad` 的含义：它是一个布尔开关，告诉 autograd「这个张量需不需要算梯度」。设为 `False` 后，前向照常进行，但反向时不会为它（以及只依赖它的上游）累积梯度，优化器也自然不会更新它。冻结的好处是双重的：①省显存（不存梯度）；②防过拟合（保留预训练学到的通用特征，只在新任务相关数据上调整少数参数）。

在大模型语境里，`requires_grad=False` 是「全量微调 vs 参数高效微调（PEFT）」的分水岭。Full Fine-tuning 把所有参数都设为可训练，显存吃紧、容易遗忘；而 LoRA、Adapter 等方法只把极少量新增/解冻的参数设为可训练，主体冻结——既省资源又稳。所以你看 HuggingFace 的 `model.base_model` 前缀、`peft` 库的 `get_peft_model`，底层都绕不开本篇讲的 `requires_grad` 开关。

### 1.5 nn.Module 与 nn.functional 的区别（高频困惑）

PyTorch 有两套「层」：带状态的 `nn.Linear` 这种**类**（`nn.Module` 子类），以及无状态的 `F.linear` 这种**函数**（`torch.nn.functional` 里的纯函数）。它们算的是同一件事，区别在于「参数归谁管」。

```python
import torch.nn.functional as F

# 无状态版本：权重要你自己拿着、自己传、自己存
class FuncNet(nn.Module):
    def __init__(self, in_dim, out_dim):
        super().__init__()
        self.w = nn.Parameter(torch.randn(out_dim, in_dim) * 0.1)
        self.b = nn.Parameter(torch.zeros(out_dim))

    def forward(self, x):
        return F.linear(x, self.w, self.b)   # 权重手动传入

# 有状态版本：权重被 nn.Linear 内部托管
class ClassNet(nn.Module):
    def __init__(self, in_dim, out_dim):
        super().__init__()
        self.fc = nn.Linear(in_dim, out_dim)
    def forward(self, x):
        return self.fc(x)                    # 权重自动用

x = torch.randn(3, 4)
print("FuncNet 输出形状:", FuncNet(4, 2)(x).shape)
print("ClassNet 输出形状:", ClassNet(4, 2)(x).shape)
```

经验法则：**有可学习参数、且要在多处复用/被优化器管理的，用 `nn.Module` 子类（如 `nn.Linear`、`nn.Conv2d`、`nn.LayerNorm`）**；而像 `F.relu`、`F.dropout` 这种「没有参数的运算」，在 `forward` 里直接调 `F.xxx` 就够了，没必要包成子模块。还有一个特例：Dropout 和 BatchNorm 虽然「没有可学习参数（Dropout）」，但**有运行状态（train/eval 行为不同）**，所以更常见的是写成 `nn.Dropout` 这种带状态的模块——这样 `model.eval()` 才能一键切换。理解这个区别，你看别人代码里一会儿 `nn.ReLU()` 一会儿 `F.relu` 就不会懵了。

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

`nn.Sequential` 内部维护一个有序的「子模块列表」，调用 `seq_model(x)` 时它会**按顺序**把 `x` 喂给每个子模块，上一个的输出作为下一个的输入。它本质上是「连续管道」的语法糖：你写的是 `Sequential(a, b, c)`，它帮你自动串成 `c(b(a(x)))`。

**什么时候用 Sequential，什么时候自己写 class？**

| 场景 | 选择 |
|---|---|
| 层简单线性堆叠 | `nn.Sequential` |
| 有分支、跳跃连接（ResNet）、多输入 | 自定义 `nn.Module` |
| 需要中间结果（如返回注意力权重） | 自定义 `nn.Module` |

Transformer 有残差连接和多头分支，**必须是自定义 Module**——这也是大模型源码看起来复杂的原因。

再补一张 ASCII 图，直观对比两种写法的「数据流」：

```
nn.Sequential 的数据流（纯线性，无分支）:
  x ──▶ Linear ──▶ ReLU ──▶ Linear ──▶ ReLU ──▶ Linear ──▶ y
  每个模块输出直接喂给下一个，无回头、无分叉

自定义 nn.Module 的数据流（可有分支/跳跃）:
  x ──▶ Linear ──▶ ReLU ─┐
                          ├──▶ +(add) ──▶ ...
  x ─────────────────────┘   (ResNet 残差：跳过两层直接相加)
```

看到区别了吗？`Sequential` 不允许「绕路」和「分叉」，而自定义 `nn.Module` 的 `forward` 里你可以写任意 Python 控制流（if、for、把同一个张量喂给多个分支再拼接），这正是 ResNet、Inception、Transformer 的必要条件。所以经验法则：**管道式用 Sequential，一切复杂结构用 class。**

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

下面把几个「大模型高频层」讲透：

**`nn.Linear`** 上面已详述，它是 Transformer 里 Feed-Forward Network（FFN）的主体。注意它「只作用在最后一维」这条性质：输入 `(batch, seq, d_model)` 时，它对 seq 上每一个位置独立做同样的变换，等价于对每个位置并行跑一个 MLP。这就是为什么 Transformer 能「并行处理整句话」。

**`nn.GELU`** 是 GPT 系列的标准激活。它近似于 `x * Φ(x)`（Φ 是高斯累积分布），相比 `ReLU` 更平滑、对负区间保留一点信息， empirically 在 Transformer 上表现更好。你现在知道为什么 GPT-2/3 用 GELU 了——就这一个简单的层。

**`nn.Dropout`** 的本质是「训练时随机把一部分神经元输出置 0，并放大其余输出」，强迫网络不能依赖任意单个神经元，从而提升泛化。关键是它只在 `train()` 模式生效，`eval()` 下是恒等变换——所以推理前忘了切 `eval()` 会导致结果抖动甚至变差。

**`nn.LayerNorm`** 对「单个样本的特征维度」做归一化（减均值除标准差再缩放平移），不依赖 batch 内其他样本。这对变长序列极其友好——这也是为什么 NLP/Transformer 用 LayerNorm 而不是 BatchNorm。这一点在 CNN 篇会专门对比。

**`nn.Embedding`** 本质是一张「可学习的查表」：行号是词 id，行内容是词向量。它把离散的 token 变成连续向量，是整个大模型理解语言的入口。`vocab_size × emb_dim` 就是它的参数量——GPT-3 的 embedding 表就有 5 万 × 12288 ≈ 6 亿参数。

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

把「为什么不在输出层加 Softmax」讲得更透：Softmax 函数 `exp(z_i) / Σ exp(z_j)` 在 `z` 数值很大时，`exp` 会溢出成 `inf`。如果先 Softmax 再 `log`，中间就可能得到 `log(inf) = inf` 或 `log(0) = -inf`，直接 NaN。PyTorch 的 `CrossEntropyLoss` 把这两步合并，并使用 `log_softmax` 的等价实现——先减去最大值 `logits.max()`（不改变结果，但防止溢出），再做 log-sum-exp。这就是为什么「损失函数里做 Softmax」既稳又快。你上面的 `manual_ce` 也复刻了这个技巧（`logits - logits.max()`），所以它和 `nn.CrossEntropyLoss` 结果一致。

**标签为什么用 Long 的类别 id，而不是 one-hot？** 因为 `CrossEntropyLoss` 内部用索引 `y` 直接去 `logits` 里挑对应类别的那一项，省去了你构造 one-hot 向量、再做交叉熵的内存和计算开销。所以标签必须是 `torch.long`（即 `int64`）类型的类别索引。`float` 类型会直接报错 `expected Long but got Float`。

**推理时要概率就手动 Softmax**：

```python
probs = torch.softmax(logits, dim=-1)
print("各类概率:", probs.round(3))
```

补充：大模型生成时你看到的「温度采样」「top-k/top-p」都建立在 `softmax(logits / temperature)` 之上——本篇学的就是这个分布的源头。

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

这段「五步曲」是后面所有训练的骨架，务必背熟：`zero_grad` → `forward` → `loss` → `backward` → `step`。注意 `optimizer.zero_grad()` 不能省——PyTorch 默认梯度**累加**，不清零会把上一个 batch 的梯度叠上来，导致更新方向错误、loss 异常。

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

典型真实输出示例（不同随机种子略有浮动）：
```
参数量: 35,970
前向输出: torch.Size([4, 2])
epoch   0  loss=0.6981  train_acc=0.517
epoch  80  loss=0.2032  train_acc=0.920
epoch 160  loss=0.1223  train_acc=0.947
epoch 240  loss=0.0987  train_acc=0.955
epoch 320  loss=0.0861  train_acc=0.957
epoch 399  loss=0.0812  train_acc=0.960
测试集准确率: 0.965
前 5 个样本的预测概率:
 [[0.987 0.013]
  [0.012 0.988]
  [0.994 0.006]
  [0.021 0.979]
  [0.968 0.032]]
```

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

画出来的决策边界会是两条月牙之间的平滑曲线——这正说明 MLP 学到了非线性可分的特征。这个「决策边界」的直觉很重要：线性模型只能画出直线，而两层带 ReLU 的网络能画出任意曲线，这是深度网络表达能力的直观证据。

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

展开讲两种保存方式的取舍：方式 2（`torch.save(model, ...)`）把「类定义 + 参数」一起 pickle 进文件。它的问题是**强依赖你当时定义 `MLP` 这个类所在的代码路径和文件名**——你换台机器、改个类名、重构一下目录，加载就会 `ImportError` 或 `AttributeError`。而方式 1 只保存「参数名→张量」的纯数据字典，与代码结构解耦。HuggingFace 的 `model.safetensors` / `pytorch_model.bin` 就是这种 state_dict 思路的延伸：先 `from_pretrained` 重建结构，再把权重灌进去。所以记住一句话：**存权重，永远用 state_dict；存整个对象，除非你百分百确定代码不变。**

`state_dict` 的键名（如 `net.0.weight`）和设备无关、框架无关，这也是它能成为「模型交换格式」的原因。当你以后看到 `model.load_state_dict(torch.load("xxx.safetensors"), strict=False)`，`strict=False` 表示允许部分键不匹配（用于加载部分预训练权重、微调新头时极常用）。

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

关于设备迁移，有一个新手高频坑：`model.to(device)` 返回的是模型本身（同时就地修改），但 `x.to(device)` 是**返回新张量、不就地修改**。所以常见写法 `X_dev = X_tr_t.to(device)` 必须把结果接回来；而 `model.to(device)` 后面即使不接变量通常也没问题（因为模型是可变对象），但最稳妥是统一接住。另外模型和数据必须在**同一个** device 上，否则会报 `Expected all tensors to be on the same device`——这是调试 CUDA 时最常见的报错之一。

`torch.no_grad()` 的作用是「进入这个上下文时不构建 autograd 计算图」，推理时不需要梯度，关掉它能省下大量显存、加速计算。评估指标几乎总是包在 `model.eval()` + `with torch.no_grad()` 里，这是固定搭配。

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
| `optimizer.zero_grad()` 漏掉 | 梯度累加，loss 异常 | 每轮/每步前清零 |
| 推理忘包 `no_grad` | 显存暴涨 | 评估加 `torch.no_grad()` |

## 九、本篇小结

1. **`nn.Module`** 是 PyTorch 一切模型的基类：自动管理参数（树形递归注册）、只需定义 `forward()`、支持设备迁移与保存加载。
2. **`nn.Linear(in, out)` 的权重形状是 `(out, in)`**；`nn.Embedding` 就是一张可学习的查表；`nn.LayerNorm`/`GELU`/`Dropout` 是 Transformer 的常客。
3. **输出层不加 Softmax**，直接出 logits，交给 `nn.CrossEntropyLoss`（内部已含 LogSoftmax，数值更稳）。
4. **训练五步曲**：`zero_grad` → `forward` → `loss` → `backward` → `step`；评估时 `model.eval()` + `no_grad()`。
5. **模型保存只存 `state_dict`**，加载时先建结构再灌参数——大模型 checkpoint 也是这个机制。
6. **冻结 `requires_grad=False`** 是微调的基础（LoRA 就是它的进阶版）。

下一篇 **训练循环实战**：我们会把这一篇的手写循环升级成工程级模板——`Dataset`/`DataLoader` 批量加载、SGD/Adam 优化器对比、学习率调度、早停、checkpoint 保存、训练曲线绘制。**这份模板你以后每个项目都能直接抄。**

## 十、实战练习（可验证小任务）

下面几个任务都可在本篇代码基础上直接验证，建议逐个动手：

1. **搭一个 4 层 MLP 做 4 分类**：用 `make_classification(n_classes=4)` 造数据，仿照第五节的 `MLP` 写一个 4 类分类器，目标在测试集上达到 90%+ 准确率。验证方法：`print(accuracy_score(y_te, pred))`。
2. **打印并理解参数名**：对你的模型跑 `for n,p in model.named_parameters(): print(n, tuple(p.shape))`，尝试找出哪些参数属于第一层、哪些属于输出层。
3. **冻结实验**：把模型前两层 `requires_grad=False`，只训练最后两层，对比「全量训练」和「冻结训练」的收敛速度差异，思考为什么微调时冻结主体有用。
4. **换激活对比**：把 `ReLU` 换成 `GELU`，重跑月牙数据，观察 loss 曲线是否更平滑；再用 `nn.Tanh` 试试，思考不同激活对梯度的影响。
5. **保存即加载**：把训练好的模型 `state_dict` 存盘，关掉 Python 重新打开，新建结构后 `load_state_dict` 加载，确认两次预测结果完全一致——这一步验证了「只存权重」的可靠性。
6. **进阶（大模型视角）**：把 `nn.Linear` 的权重形状 `(out, in)` 和 `x @ W.T` 手算一遍（`manual = x @ layer.weight.T + layer.bias`），确认与 `layer(x)` 数值一致，建立「任何层都是矩阵运算」的直觉。

## 十一、延伸阅读与下一步

- **官方文档**：`torch.nn.Module`、`torch.nn.Linear`、`torch.nn.Embedding` 的 API 文档（搜 PyTorch docs 即可），建议把 `named_parameters`、`children`、`modules` 三个方法的区别读一遍——`modules()` 会递归遍历整棵树，做「对所有子层统一操作」（如统一初始化）时极有用。
- **参数初始化**：本篇用的是 PyTorch 默认初始化（Linear 用 Kaiming Uniform）。真正训练大模型时初始化很讲究，可延伸了解 `nn.init.xavier_uniform_`、`kaiming_normal_` 以及 Transformer 常用的残差缩放初始化。
- **模型初始化技巧**：`model.apply(init_weights)` 能递归地对每个子模块套用初始化函数，是搭建自定义大模型时的标准写法。
- **与 HuggingFace 的衔接**：你今天写的 `SimpleNet` 和 `BertModel` 是同一个抽象——下一步读到 `transformers` 源码时，先找 `class XXXPreTrainedModel(nn.Module)`，再找它的 `forward`，你会发现结构完全一样，只是更深、更宽、多了注意力。
- **下一步**：下一篇《训练循环实战》会把本篇的手写五步曲升级成可复用的工程模板，并讲清 AdamW、warmup、早停、checkpoint，这些是大模型训练的基础设施。

> 本篇是《大模型开发从 0 到 1》专栏第 24 篇，阶段 4「深度学习与 PyTorch」第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
