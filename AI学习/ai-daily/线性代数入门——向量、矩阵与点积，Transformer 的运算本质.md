<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 线性代数入门——向量、矩阵与点积，Transformer 的运算本质

**承上**：阶段 1 我们掌握了计算（NumPy）、管理（Pandas）与可视化（Matplotlib）三件套。

**本篇**：本篇进入阶段 2：向量、矩阵、点积——大模型表示与运算的语言。

**启下**：下一篇《概率与统计》解释模型如何「选出下一个词」。

**学完这一节，你能动手做**：

1. 把词理解成向量、把一句话理解成矩阵，建立 shape 直觉
2. 用点积与余弦相似度做语义检索（向量数据库就在算这个）
3. 手算一次 Self-Attention，彻底读懂 QKV 矩阵


很多人一听说"学大模型要学线性代数"就劝退了。其实你真正需要的核心概念**只有四个**：向量、矩阵、矩阵乘法、点积。剩下的（特征值、SVD、行列式）在入门阶段几乎用不上。

这一篇我会用一个贯穿始终的例子讲清楚：**大模型是怎么用向量和矩阵"理解"一句话的**。学完你再看注意力公式 `softmax(QK^T/√d)V`，会觉得很自然。

## 一、向量：一个词就是一个箭头

### 1.1 什么是向量

向量就是**一串有序的数字**。比如用一个 4 维向量表示"猫"这个词：

```python
import numpy as np

cat   = np.array([0.9, 0.1, 0.8, 0.2])   # 4 维向量
dog   = np.array([0.8, 0.2, 0.7, 0.3])
table = np.array([0.1, 0.9, 0.0, 0.5])

print(cat.shape)   # (4,)
```

你可以把这 4 个数想象成 4 个"语义维度"（当然是简化的）：

- 第 1 维：是不是动物
- 第 2 维：是不是家具
- 第 3 维：是不是毛茸茸
- 第 4 维：是不是常见宠物

真实大模型里，一个词的向量通常是 **768 维、1024 维甚至 12288 维**（GPT-3 就是 12288）。维度越多，能表达的语义细节越丰富。这个向量有个专门名字——**Embedding（词嵌入）**。

### 1.2 向量的几何意义

2 维、3 维向量可以画成空间里的箭头。高维向量画不出来，但**几何直觉是通用的**：

- **方向** = 语义（哪个词？）
- **长度** = 强度（这个词被强调多少？）

这就是为什么大模型能"算"语义：**猫和狗的向量方向接近，猫和桌子的向量方向远离**。

## 二、点积：两个词有多"相关"

点积（dot product）是两个向量对应位置相乘再求和：

```python
# a · b = a1*b1 + a2*b2 + ... + an*bn
print(np.dot(cat, dog))     # 0.9*0.8 + 0.1*0.2 + 0.8*0.7 + 0.2*0.3
print(np.dot(cat, table))   # 明显更小
print(cat @ dog)            # 等价写法，@ 就是矩阵乘法/点积
```

输出大概是 `cat·dog ≈ 1.36`，`cat·table ≈ 0.28`。

**关键结论：点积越大，两个向量方向越接近，语义越相似。**

但点积有个毛病：它受向量长度影响。一个"很重要但方向偏"的向量可能点积也不小。所以工程上更常用**余弦相似度**——先归一化长度再点积：

```python
def cosine_similarity(a, b):
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))

print(f"cat vs dog   : {cosine_similarity(cat, dog):.3f}")
print(f"cat vs table : {cosine_similarity(cat, table):.3f}")

# 自己手算一遍，验证理解
def cos_manual(a, b):
    norm_a = np.sqrt(np.sum(a ** 2))       # 向量长度（L2 范数）
    norm_b = np.sqrt(np.sum(b ** 2))
    return np.sum(a * b) / (norm_a * norm_b)

print(cos_manual(cat, dog))    # 与上面一致
```

余弦相似度取值 `[-1, 1]`：1 表示完全同向，0 表示垂直无关，-1 表示完全相反。**向量数据库（Milvus / Chroma / FAISS）做语义检索，本质就是算这个**。

## 三、矩阵：把一堆向量摞起来

### 3.1 矩阵 = 多个向量的集合

一句话有 3 个词，每个词 4 维，摞起来就是一个 3×4 矩阵：

```python
# 一句话："猫 追 狗"
sentence = np.array([
    [0.9, 0.1, 0.8, 0.2],   # 猫
    [0.3, 0.4, 0.1, 0.6],   # 追
    [0.8, 0.2, 0.7, 0.3],   # 狗
])
print(sentence.shape)   # (3, 4) = 3 个 token，每个 4 维
```

深度学习的约定：**行 = 样本（token），列 = 特征（维度）**。这个约定要刻在脑子里，后面所有形状问题都源于它。

### 3.2 矩阵乘法：维度的"变换器"

矩阵乘法规则：`(m, k) @ (k, n) → (m, n)`，**中间维度必须相等**。

```python
X = sentence                                  # (3, 4)
W = np.random.randn(4, 6)                     # (4, 6) 权重矩阵

Y = X @ W                                     # (3, 4) @ (4, 6) → (3, 6)
print(Y.shape)
```

**直观理解：`W` 是一个"翻译机"，把 4 维的表示变成 6 维的表示。** 大模型的每一层都在做这件事——把 token 表示从 768 维变换到另一个 768 维，每变换一次就"想清楚一点"。

再手算一个小例子验证规则：

```python
A = np.array([[1, 2],
              [3, 4]])      # (2, 2)
B = np.array([[5, 6],
              [7, 8]])      # (2, 2)

# C[0,0] = A 第0行 · B 第0列 = 1*5 + 2*7 = 19
print(A @ B)
# [[19 22]
#  [43 50]]

# 逐元素相乘（Hadamard 积）是完全不同的东西！
print(A * B)
# [[ 5 12]
#  [21 32]]
```

**`*` 是逐元素相乘，`@` 是矩阵乘法**——这是新手最容易搞混的点，混了就会得到"形状对但数值全错"的诡异结果。

### 3.3 形状对齐：90% 的报错来源

```python
try:
    bad = np.random.randn(3, 4) @ np.random.randn(5, 6)
except ValueError as e:
    print("报错:", e)   # shapes (3,4) and (5,6) not aligned: 4 != 5
```

调试口诀：**中间那两个数字必须一样**。看到 `(3,4)` 和 `(4,6)` 就知道能乘，得 `(3,6)`。

## 四、把三者合起来：亲手算一次 Self-Attention

现在我们用向量、点积、矩阵乘法，**从零实现 Transformer 的核心——自注意力**。

任务：3 个 token，每个 4 维。让每个 token "看看"其他 token，决定该关注谁。

```python
np.random.seed(42)

# 1) 输入：3 个 token 的 embedding，形状 (3, 4)
X = np.random.randn(3, 4)

# 2) 三个投影矩阵：把 X 分别变成 Q(查询)、K(键)、V(值)
d_model, d_k = 4, 4
W_Q = np.random.randn(d_model, d_k) * 0.1
W_K = np.random.randn(d_model, d_k) * 0.1
W_V = np.random.randn(d_model, d_k) * 0.1

Q = X @ W_Q     # (3,4) 每个 token 的"我想找什么"
K = X @ W_K     # (3,4) 每个 token 的"我能提供什么"
V = X @ W_V     # (3,4) 每个 token 的"我的实际内容"

# 3) 算注意力分数：Q 和 K 两两做点积 → (3,3) 的分数矩阵
scores = Q @ K.T          # (3,4) @ (4,3) → (3,3)
print("原始分数:\n", scores.round(2))

# 4) 缩放：除以 √d_k，防止点积太大把 softmax 推到饱和区
scores = scores / np.sqrt(d_k)

# 5) softmax：每行归一化成概率（每行和为 1）
def softmax(x):
    x = x - np.max(x, axis=-1, keepdims=True)   # 减最大值防溢出
    e = np.exp(x)
    return e / np.sum(e, axis=-1, keepdims=True)

attn = softmax(scores)
print("注意力权重(每行和=1):\n", attn.round(3))
print("每行求和:", attn.sum(axis=1))

# 6) 用注意力权重对 V 加权求和
out = attn @ V            # (3,3) @ (3,4) → (3,4)
print("输出形状:", out.shape)
```

**逐行解释这在干什么**：

| 步骤 | 公式 | 含义 |
|---|---|---|
| 投影 | `Q=XW_Q, K=XW_K, V=XW_V` | 把每个 token 变成三种角色 |
| 打分 | `S = QK^T` | token i 对 token j 的"关注度"（点积=相似度） |
| 缩放 | `S / √d_k` | 防止数值过大导致 softmax 梯度消失 |
| 归一化 | `softmax(S)` | 变成"我要把多少注意力分给你"的百分比 |
| 加权 | `attn @ V` | 按百分比把所有 token 的内容混合起来 |

**一句话总结注意力**：`softmax(QK^T/√d)V` = 用点积算相似度 → 归一化成权重 → 按权重混合信息。

看输出那 3×3 的注意力矩阵：`attn[i][j]` 就是"第 i 个词在多大程度上关注第 j 个词"。真实的注意力可视化图（那些花花绿绿的方块）画的正是这个矩阵。

### 加个 mask 看看（因果语言模型）

GPT 这类生成模型在预测第 i 个词时**不能偷看后面的词**，所以要加下三角 mask：

```python
n = scores.shape[0]
mask = np.triu(np.ones((n, n)), k=1) * -1e9   # 上三角填 -1e9
masked_scores = (Q @ K.T) / np.sqrt(d_k) + mask
causal_attn = softmax(masked_scores)
print("因果注意力(上三角≈0):\n", causal_attn.round(3))
```

`-1e9` 经过 softmax 后接近 0，等于"屏蔽掉"。**这就是 Decoder-only 模型能自回归生成的原因**。

## 五、范数与归一化：训练稳定的关键

```python
v = np.array([3.0, 4.0])

print(np.linalg.norm(v))          # 5.0  L2 范数（欧氏距离）
print(np.sqrt(3**2 + 4**2))       # 手算一致
print(np.linalg.norm(v, ord=1))   # 7.0  L1 范数（绝对值和）

# 归一化成单位向量
unit = v / np.linalg.norm(v)
print(unit, np.linalg.norm(unit))   # [0.6 0.8] 1.0
```

深度学习里到处都在归一化：**LayerNorm** 让每层的输入保持稳定的尺度，**余弦相似度**检索前先归一化 embedding。它们背后的数学就是"除以范数"。

## 六、常见坑与注意事项

| 坑 | 现象 | 解决 |
|---|---|---|
| `@` 和 `*` 混用 | 结果形状对但数值错 | 矩阵乘法永远用 `@` |
| 忘记转置 | `shapes (3,4) and (3,4) not aligned` | 该用 `K.T` 的地方别忘了 |
| softmax 溢出 | 出现 `nan`/`inf` | 先减 `max`，别直接 `exp` |
| 维度约定搞反 | 模型跑不通 | 记住：行=样本(token)，列=特征 |
| `np.random.randn` 未设 seed | 每次结果不一样，没法复现 | 调试时 `np.random.seed(42)` |
| 广播意外扩大 | 得到 (3,3) 而不是 (3,) | 明确 `reshape`，别靠广播猜 |

## 七、本篇小结

1. **向量** = 一串数字 = 一个词的语义（Embedding）。真实模型 768～12288 维。
2. **点积/余弦相似度** = 两个向量的相似程度，是语义检索和注意力打分的数学基础。
3. **矩阵** = 多个向量摞起来（行=token，列=维度）；**矩阵乘法** `(m,k)@(k,n)→(m,n)` 是"维度变换器"。
4. **注意力公式 `softmax(QK^T/√d)V` 我们已经手算跑通了**——打分、缩放、归一化、加权四步。
5. **范数与归一化**是训练稳定的基础设施（LayerNorm、余弦检索都用它）。

你可能已经发现：所谓"大模型在思考"，拆开就是矩阵乘法 + softmax。**数学不神秘，它只是把直觉写成了公式。**

下一篇 **概率与统计**：语言模型本质上是在建模"下一个词的概率分布"。我们会学到概率分布、条件概率、交叉熵，以及最关键的——**困惑度 perplexity** 和**采样策略（temperature / top-p）为什么能让同一个模型说出不同的话**。同样全程配代码。

> 本篇是《大模型开发从 0 到 1》专栏第 14 篇，阶段 2「数学基础（LLM 视角）」第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
