<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 逻辑回归与 Softmax——分类问题的数学骨架

**承上**：上一篇《线性回归与梯度下降》我们让模型输出连续值。

**本篇**：本篇用 Sigmoid 与 Softmax 把它压成概率，变成分类器——大模型输出层用的正是 Softmax。

**启下**：下一篇《决策树与随机森林》换一条完全不同的思路做预测（选修视野）。

**学完这一节，你能动手做**：

1. 从零实现 Softmax 回归，完成训练、评估并与 sklearn 对比
2. 理解「Softmax + 交叉熵的梯度 = p − y」为什么这么简洁
3. 看懂大模型最后一层 logits → softmax → 采样的完整链路


上一篇我们让模型输出连续值（回归）。这一篇要解决**分类**：怎么让模型说"这是猫，不是狗"？

答案是一个极其重要的函数——**Softmax**。而我要提前剧透一个关键事实：

> **大模型预测下一个词时，最后一步就是 Softmax。** 词表 5 万个词，模型输出 5 万个分数（logits），Softmax 把它们变成概率，然后采样出下一个词。

所以这一篇是理解大模型输出层的**最后一块拼图**。

## 一、从回归到分类：需要"压扁"输出

线性回归输出 `ŷ = w·x + b`，取值范围是 `(-∞, +∞)`。但分类要的是**概率**，必须在 `[0, 1]` 之间。

解决方案：套一个"压缩函数"。

| 任务 | 输出个数 | 压缩函数 | 损失函数 |
|---|---|---|---|
| 二分类 | 1 个（正类概率） | **Sigmoid** | BCE |
| 多分类 | C 个（C 个类的概率） | **Softmax** | Cross-Entropy |

## 二、Sigmoid：二分类的开关

```python
import numpy as np

def sigmoid(z):
    return 1 / (1 + np.exp(-z))

z = np.array([-6.0, -2.0, 0.0, 2.0, 6.0])
print("z      :", z)
print("sigmoid:", sigmoid(z).round(4))
```

| z | sigmoid(z) | 含义 |
|---|---|---|
| -6 | 0.0025 | 几乎肯定是负类 |
| 0 | 0.5 | 五五开，最不确定 |
| +6 | 0.9975 | 几乎肯定是正类 |

**Sigmoid 把任意实数压到 (0,1)，且在 z=0 处最敏感**、两端饱和（导数趋于 0）。

它的导数有个非常优美的性质，让反向传播极其简洁：

```python
def sigmoid_grad(z):
    s = sigmoid(z)
    return s * (1 - s)

# 验证：与数值导数一致
eps = 1e-6
numeric = (sigmoid(z + eps) - sigmoid(z - eps)) / (2 * eps)
print("解析导数:", sigmoid_grad(z).round(6))
print("数值导数:", numeric.round(6))
```

`σ' = σ(1-σ)`——**只用输出值就能算导数，不需要保存输入**。这是它当年的巨大优势。

## 三、Softmax：多分类的归一器

```python
def softmax(z):
    """z: (C,) 或 (N, C)，沿最后一维归一化"""
    z = np.asarray(z, dtype=float)
    z = z - np.max(z, axis=-1, keepdims=True)   # ① 减最大值，防溢出
    e = np.exp(z)
    return e / np.sum(e, axis=-1, keepdims=True)  # ② 归一化，和为 1

logits = np.array([2.0, 1.0, 0.1])
p = softmax(logits)
print("概率:", p.round(4), " 和 =", p.sum())
```

**Softmax 做两件事**：
1. 用 `exp` 放大差距（大的更大，小的更小）；
2. 归一化成和为 1 的概率分布。

### 为什么要减最大值？

```python
bad = np.exp(np.array([1000, 1001, 1002]))     # 溢出！
print("直接 exp:", bad)                          # [inf inf inf]
print("减最大值后:", softmax(np.array([1000, 1001, 1002])).round(4))
```

数学上 `softmax(z) == softmax(z - c)`（常数约掉），但数值上减最大值能避免 `exp` 溢出。**这是必须写在代码里的标准操作**。

### 温度参数（重温）

```python
def softmax_t(logits, T=1.0):
    z = np.asarray(logits, dtype=float) / T
    z = z - np.max(z)
    e = np.exp(z)
    return e / np.sum(e)

print("T=0.5:", softmax_t(logits, 0.5).round(3))
print("T=1.0:", softmax_t(logits, 1.0).round(3))
print("T=2.0:", softmax_t(logits, 2.0).round(3))
```

**这就是大模型 API 里 `temperature` 参数的实现**——改的是 Softmax 的输入缩放。现在你知道调温度的时候，底层在算什么了。

## 四、Softmax + 交叉熵：梯度美到令人惊叹

这是深度学习里最漂亮的一个结论。

设 logits 为 `z`，真实类别为 `k`（one-hot 标签 `y`），则：

```
p = softmax(z)
L = -log(p_k)
∂L/∂z = p - y
```

**交叉熵对 logits 的梯度，就是"预测概率 减 真实标签"**。没有复杂的连乘，一行搞定。

```python
def softmax_cross_entropy(logits, y_onehot):
    p = softmax(logits)
    loss = -np.sum(y_onehot * np.log(np.clip(p, 1e-12, 1.0)))
    grad = p - y_onehot          # ← 就是这么简单
    return loss, grad, p

logits = np.array([2.0, 1.0, 0.1])
y = np.array([1.0, 0.0, 0.0])    # 真实类别 = 第 0 类

loss, grad, p = softmax_cross_entropy(logits, y)
print("loss :", round(loss, 4))
print("probs:", p.round(4))
print("grad :", grad.round(4))   # 正类的梯度是负的（要增大），其余为正

# 数值验证
eps = 1e-6
num_grad = np.zeros(3)
for i in range(3):
    lp = logits.copy(); lp[i] += eps
    lm = logits.copy(); lm[i] -= eps
    l1, _, _ = softmax_cross_entropy(lp, y)
    l2, _, _ = softmax_cross_entropy(lm, y)
    num_grad[i] = (l1 - l2) / (2 * eps)
print("数值grad:", num_grad.round(4))
```

完全一致。**这个 `p - y` 的简洁性，是交叉熵成为分类标配损失的核心原因。**

## 五、从零实现 Softmax 回归（多分类）

现在完整实现一个分类器。任务：三分类的合成数据。

```python
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler

np.random.seed(0)
X, y = make_classification(n_samples=1500, n_features=4, n_informative=4,
                           n_redundant=0, n_classes=3, random_state=42)

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42, stratify=y)

scaler = StandardScaler()
X_train_s = scaler.fit_transform(X_train)
X_test_s  = scaler.transform(X_test)

def one_hot(y, C):
    out = np.zeros((len(y), C))
    out[np.arange(len(y)), y] = 1.0
    return out

C = 3
Y_train = one_hot(y_train, C)     # (N, 3)
print("one-hot 样例:\n", Y_train[:3])
```

### 5.1 前向与反向

```python
def forward(X, W, b):
    """X:(N,d) W:(d,C) b:(C,) → logits:(N,C)"""
    return X @ W + b

def compute_loss_grad(X, Y, W, b):
    N = X.shape[0]
    logits = forward(X, W, b)                 # (N, C)
    p = softmax(logits)                       # 每行归一化
    loss = -np.sum(Y * np.log(np.clip(p, 1e-12, 1.0))) / N
    dz = (p - Y) / N                          # (N, C) ← 核心梯度
    dW = X.T @ dz                             # (d, C)
    db = np.sum(dz, axis=0)                   # (C,)
    return loss, dW, db
```

注意 `dW = X.T @ dz`：形状 `(d,N) @ (N,C) → (d,C)`，与 `W` 同形。

### 5.2 训练

```python
def train_softmax(X, Y, C, lr=0.5, epochs=500, batch_size=64, seed=0):
    rng = np.random.default_rng(seed)
    N, d = X.shape
    W = np.random.randn(d, C) * 0.01
    b = np.zeros(C)
    history = []

    for epoch in range(epochs):
        idx = rng.permutation(N)
        for s in range(0, N, batch_size):
            bidx = idx[s:s + batch_size]
            loss, dW, db = compute_loss_grad(X[bidx], Y[bidx], W, b)
            W -= lr * dW
            b -= lr * db
        if epoch % 100 == 0 or epoch == epochs - 1:
            full_loss, _, _ = compute_loss_grad(X, Y, W, b)
            acc = np.mean(np.argmax(forward(X, W, b), axis=1) == np.argmax(Y, axis=1))
            history.append((epoch, full_loss, acc))
            print(f"epoch {epoch:3d}  loss={full_loss:.4f}  train_acc={acc:.3f}")
    return W, b, history

W, b, hist = train_softmax(X_train_s, Y_train, C, lr=0.5, epochs=500)
```

loss 一路下降，train accuracy 会上升到 0.85 左右。

### 5.3 在测试集评估

```python
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix

probs = softmax(forward(X_test_s, W, b))
pred = np.argmax(probs, axis=1)

print("测试集 accuracy:", round(accuracy_score(y_test, pred), 4))
print(classification_report(y_test, pred))
print("混淆矩阵:\n", confusion_matrix(y_test, pred))

# 看一下模型对第一个样本的"信心"
print("第1个样本各类概率:", probs[0].round(3), " 真实:", y_test[0])
```

## 六、和 sklearn 对比

```python
from sklearn.linear_model import LogisticRegression

sk_model = LogisticRegression(max_iter=1000, C=1.0)
sk_model.fit(X_train_s, y_train)
sk_pred = sk_model.predict(X_test_s)

print("sklearn accuracy:", round(accuracy_score(y_test, sk_pred), 4))
print("手写   accuracy:", round(accuracy_score(y_test, pred), 4))
print("权重形状对比:", W.shape, sk_model.coef_.T.shape)
```

两者准确率接近（差 1% 以内，源于正则化和优化器差异）。**我们的 Softmax 回归实现对了。**

注意 sklearn 的 `LogisticRegression` 默认带 **L2 正则**（`C` 是正则强度的倒数，`C` 越小正则越强），我们手写的没加——这会导致手写版在训练集上略高、测试集上略低，正是过拟合的迹象。

## 七、加正则化：抑制过拟合

```python
def compute_loss_grad_reg(X, Y, W, b, l2=1e-3):
    N = X.shape[0]
    logits = forward(X, W, b)
    p = softmax(logits)
    loss = -np.sum(Y * np.log(np.clip(p, 1e-12, 1.0))) / N
    loss += 0.5 * l2 * np.sum(W ** 2)         # L2 正则项
    dz = (p - Y) / N
    dW = X.T @ dz + l2 * W                    # 梯度也要加 l2*W
    db = np.sum(dz, axis=0)
    return loss, dW, db

W2, b2, _ = train_softmax(X_train_s, Y_train, C, lr=0.5, epochs=500)
print("无正则  测试 acc:", round(accuracy_score(y_test, np.argmax(softmax(forward(X_test_s, W2, b2)), 1)), 4))
```

正则项 `l2*W` 会持续把权重往 0 拉，防止模型死记训练样本。下一篇会系统讲这件事。

## 八、这和大模型的关系（重点）

现在把视野拉回大模型：

```python
# 模拟大模型最后一层：词表 8 个词，隐藏维度 6
np.random.seed(1)
vocab = ["我", "爱", "吃", "苹果", "鱼", "猫", "的", "。"]
d_model = 6
hidden = np.random.randn(1, d_model)         # 当前上下文的隐藏状态 (1, 6)
W_vocab = np.random.randn(d_model, len(vocab))   # 输出投影矩阵 (6, 8)

logits = hidden @ W_vocab                    # (1, 8) 每个词的分数
probs = softmax_t(logits[0], T=0.8)          # 变成概率

for w, p in sorted(zip(vocab, probs), key=lambda t: -t[1]):
    print(f"{w}: {p:.1%}")
```

**这就是大模型生成下一个词的全部流程**：

```
上下文 → Transformer 若干层 → 隐藏状态 h
                              ↓
                    logits = h @ W_vocab      (词表大小的分数)
                              ↓
                    probs = softmax(logits/T) (概率)
                              ↓
                    next_token = sample(probs) (采样)
```

词表从 8 个变成 5 万个，隐藏维度从 6 变成 12288，**但数学完全一样**。你现在能读懂大模型推理代码里最关键的那一层了。

**为什么大模型训练慢？** 因为要算 5 万类的 Softmax 和交叉熵，还要对所有参数求梯度。业界为此发明了各种优化（分层 Softmax、采样损失等）。

## 九、常见坑与注意事项

| 坑 | 现象 | 解决 |
|---|---|---|
| Softmax 溢出 | `nan` 或全 0 | 先减 `np.max` |
| `log(0)` | loss = inf | `np.clip(p, 1e-12, 1)` |
| 忘了除以 N | loss 随 batch 大小变化 | 梯度除以 `batch_size` |
| 标签没 one-hot | 形状不匹配 | `one_hot()` 转换 |
| 用 MSE 做分类 | 收敛极慢 | 换交叉熵 |
| 权重初始化为 0 | 对称性问题（多层网络尤其严重） | 随机小值初始化 |
| 学习率过大 | loss 震荡 | Softmax 回归常用 0.1~1.0 |

**权重初始化为什么不能全 0？** 单层 Softmax 回归还行，但多层神经网络里，全 0 初始化会导致所有神经元算出相同梯度、永远对称，网络退化成一个神经元。**所以必须随机初始化**。

## 十、本篇小结

1. **Sigmoid** 压到 (0,1) 做二分类，导数 `σ(1-σ)` 便于反向传播。
2. **Softmax** 把任意实数向量变成概率分布；实现时必须**先减最大值防溢出**；除以温度 T 就是大模型的 temperature 参数。
3. **Softmax + 交叉熵的梯度 = `p - y`**，简洁到不可思议，这也是交叉熵成为分类标配的原因。
4. 我们**从零实现了完整的 Softmax 回归**（前向/反向/mini-batch/评估），与 sklearn 准确率相当。
5. **大模型输出层就是一个超大 Softmax**：`logits = h @ W_vocab` → `softmax` → 采样。

下一篇 **决策树与随机森林**：换一条完全不同的思路做预测——不靠梯度，靠"问一系列是非题"。理解它，你才能明白为什么"神经网络不是万能的"，以及大模型为什么最终选择了神经网络这条路。

> 本篇是《大模型开发从 0 到 1》专栏第 19 篇，阶段 3「机器学习基础」第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
