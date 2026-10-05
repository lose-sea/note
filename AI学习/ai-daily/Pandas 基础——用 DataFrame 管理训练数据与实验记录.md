<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# Pandas 基础——用 DataFrame 管理训练数据与实验记录

**承上**：上一篇《NumPy 基础》我们学会了用矩阵做计算。

**本篇**：本篇学 DataFrame——管理训练数据、清洗语料、记录实验结果的日常工具。

**启下**：下一篇《Matplotlib》把这些数字画成图，收官阶段 1。

**学完这一节，你能动手做**：

1. 加载 CSV/JSON 语料并完成去重、去空、补缺失的清洗流水线
2. 统计标签分布、检查数据是否均衡，决定采样策略
3. 对比多次实验结果并落盘，形成可追溯的实验记录


上一篇我们用 NumPy 搞懂了"大模型里全是矩阵运算"。这一篇进入三件套的第二件：**Pandas**。NumPy 擅长数值计算，而 Pandas 擅长**表格数据**——想想你的训练数据是不是经常长这样：一列文本、一列标签、一列来源？还有跑完几组实验后要对比"哪组学习率效果最好"？这些都是 Pandas 的主场。

## 一、为什么大模型开发离不开 Pandas

| 场景 | Pandas 的作用 |
|---|---|
| 训练数据准备 | 读 CSV/Excel，清洗缺失值、去重、过滤脏样本 |
| 数据分布分析 | 看标签是否均衡、文本长度分布、有没有异常值 |
| 实验结果对比 | 多组超参的结果汇总、排序、找最优 |
| 特征工程 | 构造新列、分组聚合、编码类别变量 |
| 与模型衔接 | 清洗完 `to_csv()` 落盘，再交给 DataLoader 读取 |

一句话：**NumPy 负责"算"，Pandas 负责"管"**。

## 二、Series 与 DataFrame

```python
import pandas as pd

# Series：带标签的一维数组（相当于表格的一列）
s = pd.Series([1, 3, 5, 7], name="奇数")
print(s)
print(s.mean(), s.max())

# DataFrame：二维表格（多行多列）
df = pd.DataFrame({
    "text":   ["这个模型很好用", "效果一般", "非常推荐", "不太行"],
    "label":  [1, 0, 1, 0],
    "source": ["app", "web", "app", "web"],
})
print(df)
```

输出：

```
      text  label source
0  这个模型很好用      1    app
1     效果一般      0    web
2     非常推荐      1    app
3     不太行       0    web
```

**DataFrame = 多个 Series 拼起来的表格**，有行索引（左边 0,1,2,3）和列名。

## 三、快速了解数据

拿到数据先"体检"，这四步是标准动作：

```python
print(df.head(2))       # 看前 2 行（默认 5 行）
print(df.shape)         # (4, 3) 行数、列数
print(df.info())        # 每列的类型、非空数量
print(df.describe())    # 数值列的统计：均值、最值、四分位
```

`df.info()` 能一眼看出**哪些列有缺失值**（non-null 数量少于总行数就说明有空）。

## 四、选择与过滤

```python
# 1. 选列
print(df["text"])                  # 单列 -> Series
print(df[["text", "label"]])       # 多列 -> DataFrame

# 2. 按位置选（iloc：用数字下标）
print(df.iloc[0])                  # 第 0 行
print(df.iloc[0:2, 0:2])           # 前 2 行、前 2 列

# 3. 按标签选（loc：用索引名和列名，可带条件）
print(df.loc[0, "text"])           # 第 0 行的 text 列
print(df.loc[df["label"] == 1])    # 所有正样本

# 4. 布尔过滤（最常用）
positive = df[df["label"] == 1]
long_text = df[df["text"].str.len() > 5]
print(f"正样本 {len(positive)} 条，长文本 {len(long_text)} 条")
```

**`loc` vs `iloc`**：`loc` 按**标签**，`iloc` 按**位置数字**。记混了就报错，记住 **i = integer（位置）**。

## 五、数据清洗三板斧

真实数据永远有脏东西：缺失值、重复行、类型不对。

```python
import numpy as np

raw = pd.DataFrame({
    "text":  ["好评", "差评", None, "好评", "差评"],
    "label": [1, 0, 1, 1, 0],
    "score": [5.0, np.nan, 4.0, 5.0, 2.0],
})

# 1. 查看缺失
print("缺失统计:\n", raw.isnull().sum())

# 2. 处理缺失：删掉或填充
clean = raw.dropna(subset=["text"])          # 只删 text 为空的行
clean = clean.copy()
clean["score"] = clean["score"].fillna(clean["score"].mean())   # 用均值填部分

# 3. 去重
print("重复行数:", clean.duplicated().sum())
clean = clean.drop_duplicates()

print("\n清洗后:\n", clean)
```

三种处理缺失的策略：

| 方法 | 适用 |
|---|---|
| `dropna()` | 缺失很少，直接删掉不影响分布 |
| `fillna(值)` | 用均值/众数/固定值填充 |
| `fillna(method="ffill")` | 时序数据用前值填充 |

## 六、统计与分组

```python
df = pd.DataFrame({
    "text":   ["好用", "一般", "推荐", "不行", "很棒", "凑合"],
    "label":  [1, 0, 1, 0, 1, 0],
    "source": ["app", "web", "app", "web", "app", "web"],
    "score":  [5, 3, 4, 2, 5, 3],
})

# 标签分布（判断是否均衡）
print(df["label"].value_counts())
# 1    3
# 0    3

# 占比
print(df["label"].value_counts(normalize=True))

# 分组聚合：按来源统计平均分
print(df.groupby("source")["score"].mean())
# source
# app    4.666667
# web    2.666667

# 多指标聚合
print(df.groupby("source").agg({"score": ["mean", "max", "count"]}))

# 新增列（基于已有列计算）
df["text_len"] = df["text"].str.len()
print(df.sort_values("text_len", ascending=False).head(3))
```

**`groupby` 是数据分析的灵魂**：`groupby(分组列)[统计列].聚合函数()`。想看"不同来源的评分差异""不同类别的文本长度"，全靠它。

## 七、实战：一条完整的数据清洗流水线

把上面串起来，做一个真实感的训练数据准备流程：

```python
import pandas as pd
import numpy as np

# 1. 造一份"脏"的训练数据并落盘
dirty = pd.DataFrame({
    "text":  ["模型效果不错", "一般般", None, "模型效果不错", "很满意", "", "太差了"],
    "label": [1, 0, 1, 1, 1, 0, 0],
    "score": [5, 3, np.nan, 5, 4, 1, 2],
})
dirty.to_csv("raw_data.csv", index=False, encoding="utf-8-sig")

# 2. 读取（真实场景从这里开始）
df = pd.read_csv("raw_data.csv", encoding="utf-8-sig")
print(f"原始数据: {len(df)} 行")

# 3. 清洗流水线
df = df.dropna(subset=["text"])                       # 去掉空文本
df = df[df["text"].str.strip() != ""]                 # 去掉纯空白
df = df.drop_duplicates(subset=["text"])              # 文本去重
df = df.reset_index(drop=True)                        # 重置索引
df["score"] = df["score"].fillna(df["score"].median())# 中位数填充

print(f"清洗后: {len(df)} 行")

# 4. 质量检查：标签分布
print("\n标签分布:")
print(df["label"].value_counts().sort_index())

# 5. 检查类别是否均衡
ratio = df["label"].value_counts(normalize=True)
print(f"\n正负样本占比: {dict(ratio.round(3))}")
if ratio.max() > 0.8:
    print("⚠️ 样本严重不均衡，建议做采样或加权")

# 6. 落盘，交给后续训练流程
df.to_csv("clean_data.csv", index=False, encoding="utf-8-sig")
print("\n已保存 clean_data.csv")
```

**运行结果：**

```
原始数据: 7 行
清洗后: 5 行

标签分布:
0    2
1    3
Name: label, dtype: int64

正负样本占比: {0: 0.4, 1: 0.6}
已保存 clean_data.csv
```

这条流水线包含了工业实践的核心动作：**去重 → 去空 → 补缺失 → 检查分布 → 落盘**。真实项目里你会在这一步发现很多数据问题（比如某个标签占了 95%），而这些问题的暴露，比后面调参重要得多。

> 小提示：写 CSV 用 `encoding="utf-8-sig"`，这样 Excel 打开中文不会乱码。

## 八、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| `SettingWithCopyWarning` | 切片后赋值不生效并警告 | 切片后加 `.copy()` 再改 |
| 链式索引 `df[a][b] = x` | 改的不是原数据 | 用 `df.loc[a, b] = x` |
| 读 CSV 中文乱码 | 一堆问号 | `encoding="utf-8-sig"`（写）或 `utf-8`/`gbk`（读） |
| `inplace=True` 的困惑 | 有时不生效 | 推荐用赋值 `df = df.dropna()`，别用 inplace |
| 索引断号 | drop 后索引不连续 | `reset_index(drop=True)` |
| 类型不对 | 数字列被读成字符串 | `pd.to_numeric()` 或读时指定 `dtype` |

**链式索引**是头号坑，展开说：

```python
# ❌ 错误：df[df.label==1] 返回的是副本，赋值可能无效
df[df["label"] == 1]["score"] = 5

# ✅ 正确：用 loc 一次性定位
df.loc[df["label"] == 1, "score"] = 5
```

## 九、本篇小结

1. **DataFrame** 是带行列标签的二维表，**Series** 是它的一列。
2. 拿到数据先"体检"：`head / shape / info / describe`。
3. 选择用 **`loc`（标签）** 和 **`iloc`（位置）**，过滤用布尔条件。
4. 清洗三板斧：**去空 `dropna`、填充 `fillna`、去重 `drop_duplicates`**。
5. **`groupby + agg`** 做分组统计，`value_counts` 查标签分布。
6. 实战跑通了"读脏数据 → 清洗 → 检查分布 → 落盘"的完整流水线。

下一篇讲三件套的最后一件：**Matplotlib**——把训练曲线和分布画出来。你会学到怎么画 loss 下降曲线、对比不同超参的实验、画混淆矩阵，让实验结果一目了然。

> 本篇是《大模型开发从 0 到 1》专栏第 12 篇，阶段 1「科学计算三件套」第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
