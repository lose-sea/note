<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# Matplotlib——把训练曲线和分布画出来

**承上**：上一篇《Pandas 基础》我们把数据整理进了 DataFrame，但数字躺在表里你依然看不见趋势。

**本篇**：本篇把数据画出来：训练曲线、分布直方图、混淆矩阵热力图。

**启下**：下一篇进入阶段 2《线性代数入门》，补上理解大模型运算本质的数学工具。

**学完这一节，你能动手做**：

1. 画 train/val 双曲线，一眼判断过拟合、欠拟合与学习率是否合适
2. 用直方图决定 max_length、截断阈值等预处理参数（常用 p95）
3. 画混淆矩阵定位模型到底把哪两类搞混了


上一篇我们用 Pandas 学会了管理训练数据和实验记录。但数据躺在 DataFrame 里，你依然"看不见"它。**人眼识别趋势的能力远强于阅读数字**——一行 loss 从 2.3 降到 0.4 的数字你可能无感，但一条平滑下坠的曲线会立刻告诉你"模型在学"。

这一篇我们补上科学计算三件套的最后一块：**Matplotlib**。学完你会做这些事：画出训练/验证 loss 双曲线判断过拟合、画出数据分布直方图决定要不要截断、画出混淆矩阵热力图定位模型错在哪类、把实验结果批量出图存档。

## 一、先搞清楚 Matplotlib 的三层结构

很多初学者用 Matplotlib 用得很痛苦，是因为没搞清它的三层对象：

```
Figure（画布，整张图）
 └── Axes（子图/坐标系，真正画图的地方）
      └── Artist（图上的一切元素：线、点、文字、刻度、图例…）
```

- **Figure** 是"纸"，一张纸上可以画好几张小图；
- **Axes** 是"坐标系"，一条折线图、一个直方图都活在 Axes 里；
- **Artist** 是具体的线条、文字、刻度。

对应两种写法：

```python
import matplotlib.pyplot as plt

# 写法 A：plt.xxx（隐式，用"当前"的 Axes）—— 快，适合随手画
plt.plot([1, 2, 3], [1, 4, 9])
plt.title("quick plot")
plt.show()

# 写法 B：ax.xxx（显式面向对象）—— 推荐，画多子图时不会乱
fig, ax = plt.subplots(figsize=(6, 4))
ax.plot([1, 2, 3], [1, 4, 9])
ax.set_title("explicit plot")
plt.show()
```

**建议从一开始就习惯写法 B**：`fig, ax = plt.subplots()`。因为一旦你要画 2×2 四张子图、要给每张图单独设标题和坐标轴，`plt.xxx` 就会开始"不知道自己在操作哪张图"。

## 二、折线图：训练 loss 曲线（最常用）

假设我们训练了 20 个 epoch，记录了 train/val loss：

```python
import matplotlib.pyplot as plt
import numpy as np

epochs = np.arange(1, 21)
train_loss = 2.3 * np.exp(-0.18 * epochs) + 0.15 + np.random.rand(20) * 0.05
val_loss   = 2.3 * np.exp(-0.12 * epochs) + 0.42 + np.random.rand(20) * 0.08
val_loss[12:] += 0.06 * (epochs[12:] - 12)   # 模拟后期过拟合回升

fig, ax = plt.subplots(figsize=(8, 5))
ax.plot(epochs, train_loss, marker="o", ms=4, lw=2, label="train loss")
ax.plot(epochs, val_loss,   marker="s", ms=4, lw=2, ls="--", label="val loss")

ax.set_xlabel("epoch")
ax.set_ylabel("loss")
ax.set_title("Training vs Validation Loss")
ax.legend()               # 显示图例（依赖 label=）
ax.grid(alpha=0.3)        # 淡网格，方便读数
plt.tight_layout()
plt.show()
```

**怎么读这张图**（这是真正重要的部分）：

| 现象 | 判断 | 该做什么 |
|---|---|---|
| train↓ val↓ | 还在正常学习 | 继续训 |
| train↓ val 平 | 接近收敛 | 可以降低学习率 |
| train↓ val↑ | **过拟合** | 加正则/dropout、早停、加数据 |
| train 平 val 平且都高 | **欠拟合** | 加大模型、加特征、调学习率 |
| loss 剧烈震荡 | 学习率太大或 batch 太小 | 调小 lr / 增大 batch |
| loss 变 NaN | 梯度爆炸或 lr 过大 | 梯度裁剪、降 lr、检查数据 |

**这条"看曲线下诊断"的能力，是做模型训练最核心的实操技能之一。**

## 三、多子图：subplots 一次出多张

对比实验时经常要并排放几张图：

```python
fig, axes = plt.subplots(1, 3, figsize=(15, 4))   # 1 行 3 列
axes = np.array(axes)   # 保证能用 axes[i] 索引

for i, lr in enumerate([0.1, 0.01, 0.001]):
    loss = 2.0 * np.exp(-lr * 50 * epochs / 20) + 0.2
    axes[i].plot(epochs, loss, color=f"C{i}")
    axes[i].set_title(f"lr={lr}")
    axes[i].set_xlabel("epoch")
    axes[i].set_ylabel("loss")
    axes[i].grid(alpha=0.3)

plt.suptitle("Learning Rate Comparison", fontsize=14)
plt.tight_layout()
plt.show()
```

`figsize=(宽, 高)` 单位是英寸，`dpi` 默认 100，所以 `figsize=(8,5)` 就是 800×500 像素。

## 四、直方图与散点图：看数据分布

大模型做数据清洗时，先看分布再动手，比瞎猜强一百倍。

```python
np.random.seed(0)
token_lens = np.random.gamma(shape=4, scale=60, size=5000)   # 模拟文本长度：长尾分布

fig, axes = plt.subplots(1, 2, figsize=(12, 4))

axes[0].hist(token_lens, bins=50, color="steelblue", edgecolor="white")
axes[0].axvline(np.mean(token_lens), color="r", ls="--", label=f"mean={np.mean(token_lens):.0f}")
axes[0].axvline(np.percentile(token_lens, 95), color="g", ls=":", label=f"p95={np.percentile(token_lens, 95):.0f}")
axes[0].set_title("Token Length Distribution")
axes[0].set_xlabel("tokens")
axes[0].set_ylabel("count")
axes[0].legend()

# 长尾分布看不清，画对数坐标
axes[1].hist(token_lens, bins=50, color="salmon", edgecolor="white", log=True)
axes[1].set_title("Same data, log scale on Y")
axes[1].set_xlabel("tokens")
axes[1].set_ylabel("count (log)")

plt.tight_layout()
plt.show()
```

**实战意义**：如果你在准备 RAG 语料或 SFT 数据集，这条分布图直接决定你的 `max_length` 和切分策略设多少——设太小丢信息，设太大浪费显存。业界常用 **p95 分位数** 当截断阈值，而不是拍脑袋写 512。

散点图用来看两个变量的关系：

```python
x = np.random.randn(300)
y = 0.7 * x + np.random.randn(300) * 0.4

fig, ax = plt.subplots(figsize=(6, 4))
ax.scatter(x, y, s=20, alpha=0.6, c=np.abs(y), cmap="viridis")
ax.set_xlabel("feature A")
ax.set_ylabel("feature B")
ax.set_title("Scatter with color mapping")
plt.colorbar(ax.collections[0], ax=ax, label="|y|")
plt.tight_layout()
plt.show()
```

## 五、柱状图：指标对比

```python
models = ["Baseline", "+Prompt", "+RAG", "+RAG+Finetune"]
acc = [0.52, 0.63, 0.78, 0.86]

fig, ax = plt.subplots(figsize=(7, 4))
bars = ax.bar(models, acc, color=["#ccc", "#7fb3d5", "#48a9a6", "#e76f51"])
ax.set_ylim(0, 1.0)
ax.set_ylabel("accuracy")
ax.set_title("Ablation Study")

for b, v in zip(bars, acc):        # 在柱顶标数值
    ax.text(b.get_x() + b.get_width()/2, v + 0.02, f"{v:.2f}", ha="center")

plt.tight_layout()
plt.show()
```

**消融实验（ablation）柱状图**是论文和汇报里的常客，一定要会画。

## 六、混淆矩阵热力图：定位模型错在哪

```python
from sklearn.metrics import confusion_matrix
import itertools

y_true = np.array([0]*30 + [1]*30 + [2]*30)
y_pred = y_true.copy()
noise = np.random.choice(len(y_true), 18, replace=False)
y_pred[noise] = np.random.randint(0, 3, 18)    # 注入一些错误预测

cm = confusion_matrix(y_true, y_pred)
classes = ["cat", "dog", "bird"]

fig, ax = plt.subplots(figsize=(5, 4))
im = ax.imshow(cm, cmap="Blues")
ax.set_xticks(range(3)); ax.set_xticklabels(classes)
ax.set_yticks(range(3)); ax.set_yticklabels(classes)
ax.set_xlabel("Predicted"); ax.set_ylabel("True")
ax.set_title("Confusion Matrix")

for i, j in itertools.product(range(3), range(3)):
    ax.text(j, i, cm[i, j], ha="center", va="center",
            color="white" if cm[i, j] > cm.max()/2 else "black")

plt.colorbar(im, ax=ax)
plt.tight_layout()
plt.show()
```

对角线越亮越好；**非对角线上的亮点告诉你模型把哪两类搞混了**，这比单看一个 accuracy 有信息量得多。

## 七、保存图片与中文显示

训练脚本通常跑在服务器上没界面，要存成文件：

```python
plt.savefig("loss_curve.png", dpi=150, bbox_inches="tight", facecolor="white")
```

- `dpi=150`：清晰度，论文用 300；
- `bbox_inches="tight"`：去掉白边，防止标签被裁掉；
- `savefig` 必须写在 `plt.show()` **之前**（`show()` 会清空画布）。

**中文乱码**是新手必踩的坑——Matplotlib 默认字体不含中文，画出来是方框：

```python
import matplotlib
matplotlib.rcParams["font.sans-serif"] = ["SimHei", "Arial Unicode MS", "Heiti TC"]
matplotlib.rcParams["axes.unicode_minus"] = False   # 解决负号变方块
```

macOS 用 `Arial Unicode MS`，Windows 用 `SimHei`，Linux 需要手动装中文字体。更稳的做法是换回英文标签——**技术图表用英文标签其实是国际惯例，能避免一堆麻烦**。

## 八、常见坑与注意事项

| 坑 | 现象 | 解决 |
|---|---|---|
| 中文变方框 | 图上 □□□ | 设 `font.sans-serif`，或干脆用英文 |
| `savefig` 存出空白图 | 图片全白 | `savefig` 要放在 `show()` 之前 |
| 多子图互相串 | 标题跑到别的图上 | 用 `ax.set_xxx` 而非 `plt.xxx` |
| Jupyter 里不显示 | 无输出 | 加 `%matplotlib inline` |
| 内存泄漏 | 循环里画几千张图后卡死 | 每张图后 `plt.close(fig)` |
| 图例不显示 | `legend()` 空的 | 画图时必须传 `label=` |
| 坐标轴重叠 | 标签糊在一起 | `plt.tight_layout()` |

服务端批量出图务必记得关图：

```python
for exp in experiments:
    fig, ax = plt.subplots()
    ax.plot(exp["loss"])
    fig.savefig(f"{exp['name']}.png")
    plt.close(fig)      # 关键！否则几千张图全驻留内存
```

## 九、本篇小结

1. Matplotlib 三层结构：**Figure → Axes → Artist**，推荐 `fig, ax = plt.subplots()` 显式写法。
2. **折线图看训练曲线**，train/val 双线走势是判断过拟合、欠拟合、学习率是否合适的第一手依据。
3. **直方图看分布**，决定了 `max_length`、截断阈值等数据预处理参数（常用 p95）。
4. **柱状图做消融对比**，**热力图画混淆矩阵**定位错分类别。
5. 保存用 `savefig(dpi=150, bbox_inches="tight")`，且必须在 `show()` 之前；循环出图记得 `plt.close()`。

到这里**阶段 1 科学计算三件套完结**：NumPy 负责算、Pandas 负责管、Matplotlib 负责看。这三样是后面所有实验的基础工具。

下一篇进入 **阶段 2：数学基础**。别紧张——我们不学证明，只学"大模型里真正用到的那几个概念"：向量与矩阵（注意力在算什么）、概率分布（模型怎么"选下一个词"）、导数与链式法则（反向传播凭什么能算梯度）。我会全程用 NumPy 代码把公式跑出来给你看。

> 本篇是《大模型开发从 0 到 1》专栏第 13 篇，阶段 1「科学计算三件套」第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
