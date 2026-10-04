<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 容器类型全家桶——list/tuple/dict/set 与推导式

单个变量只能装一个值，但大模型处理的是**成批的数据**：一批句子、一份配置、一个词表。这就需要**容器类型**。这一篇把 Python 的四大容器（list、tuple、dict、set）和推导式一次讲透。你会发现，后面写数据加载、写训练配置、构建词表，用的全是这几个东西。

## 一、为什么大模型代码里全是容器

看一眼真实场景：

- **list**：一个 batch 的 32 条文本、模型的 12 层隐藏状态；
- **dict**：训练超参 `{"lr": 1e-4, "batch_size": 32}`、模型的 state_dict；
- **set**：**词表去重**——把几百万个 token 去重后得到唯一集合；
- **tuple**：不可变的结构，比如 tensor 的形状 `(batch, seq_len, hidden)`。

可以说，**容器的选择直接决定代码的清晰度和性能**。选错了（比如该用 set 去重却用 list 遍历），数据量一大就卡死。

## 二、list：最常用的可变序列

```python
tokens = ["我", "爱", "大模型"]     # 创建
tokens.append("开发")                # 末尾追加
tokens.insert(0, "其实")             # 指定位置插入
tokens.extend(["真的", "很强"])       # 批量追加
last = tokens.pop()                  # 弹出末尾元素
print(tokens[0], tokens[-1])         # 下标访问，-1 是最后一个
print(tokens[1:3])                   # 切片：['爱', '大模型']
print(len(tokens))                   # 长度
```

list 是**可变**的，可以增删改。它的下标和切片用法，和上一篇讲的字符串完全一致——因为两者都是"序列"。

**嵌套 list 就是矩阵**，这是理解 batch 的关键：

```python
batch = [
    [101, 2023, 2003],   # 第 1 条样本的 token id
    [101, 3002, 1029],   # 第 2 条
    [101, 2088],         # 第 3 条（长度可以不同）
]
print(batch[0])        # 取第一条样本
print(batch[1][2])     # 取第 2 条第 3 个 token：1029
```

## 三、tuple：不可变的"安全容器"

tuple 用小括号，一旦创建就不能改：

```python
shape = (32, 512, 768)   # batch=32, seq=512, hidden=768
print(shape[0])          # 32
# shape[0] = 64          # 报错！tuple 不可变
```

为什么需要它？三个场景：

1. **保护数据不被误改**：模型形状、常量配置，用 tuple 防止哪天被顺手改掉。
2. **可以作为字典的 key**：list 不行（因为可变），tuple 可以。
3. **函数返回多个值**：实际上返回的就是一个 tuple。

```python
def stat(text):
    return len(text), len(set(text))   # 返回 (总长度, 去重后长度)

total, unique = stat("大模型大模型")     # 自动解包
print(total, unique)   # 5 4
```

## 四、dict：键值对的天然配置容器

dict 用大括号，存"键 → 值"映射：

```python
config = {
    "model_name": "qwen-7b",
    "learning_rate": 1e-4,
    "batch_size": 32,
    "use_lora": True,
}

print(config["batch_size"])            # 32
print(config.get("epochs", 3))         # 键不存在时返回默认值 3，不报错
config["epochs"] = 10                  # 新增/修改
config.setdefault("warmup", 100)       # 没有就设默认值

for key, value in config.items():      # 遍历键值对
    print(f"{key} = {value}")
```

**dict 是大模型配置的绝对主力**：无论是 `TrainingArguments` 的参数字典，还是模型权重的 `state_dict`（`{"layer1.weight": tensor, ...}`），本质都是 dict。用 `get(key, default)` 而不是 `config[key]`，能避免 KeyError 直接崩掉训练。

## 五、set：去重与集合运算

set 是无序、不重复的集合，最大的用途是**去重**：

```python
corpus = ["我", "爱", "我", "爱", "大模型"]
vocab = set(corpus)
print(vocab)                    # {'我', '爱', '大模型'}（顺序不保证）
print(len(vocab))               # 3，重复项被去掉

# 集合运算
train_vocab = {"我", "爱", "你"}
print(vocab & train_vocab)      # 交集：{'我', '爱'}
print(vocab | train_vocab)      # 并集
print(vocab - train_vocab)      # 差集：{'大模型'}（训练集里没见过的词）
```

**这就是构建词表的核心动作**：把整个语料的 token 丢进 set，去重后排序、编号，就得到一个词表。差集运算还能找出"训练时没见过的词"（OOV）。

## 六、推导式：一行写出高效转换

推导式（comprehension）是 Python 的标志性语法，把"遍历 + 处理 + 收集"压缩成一行：

```python
sentences = ["我爱大模型", "大模型很强", "我要学大模型"]

# 列表推导式：把每条句子转成 token 列表
tokenized = [list(s) for s in sentences]
print(tokenized[0])            # ['我', '爱', '大', '模', '型']

# 带条件的推导式：只要长度 > 4 的句子
long_ones = [s for s in sentences if len(s) > 4]
print(long_ones)               # ['大模型很强', '我要学大模型']

# 字典推导式：词 → 长度
word_len = {s: len(s) for s in sentences}
print(word_len)                # {'我爱大模型': 5, '大模型很强': 5, '我要学大模型': 6}

# 集合推导式：所有出现过的字符
all_chars = {c for s in sentences for c in s}
print(all_chars)
```

推导式比 `for + append` 更快也更简洁。但**别嵌套超过两层**，否则可读性会崩。

## 七、从语料构建词表的完整例子

把上面几个容器串起来，做一个真实任务——**从语料构建词表并给句子编码**：

```python
corpus = [
    "大模型 需要 大量 数据",
    "数据 质量 决定 大模型 效果",
    "高质量 数据 很难 获得",
]

# 1. set 去重得到词表
all_tokens = [t for line in corpus for t in line.split()]
vocab = sorted(set(all_tokens))              # 排序保证每次结果一致
print("词表大小:", len(vocab))

# 2. dict 建立 词 -> id 的映射
word2id = {w: i for i, w in enumerate(vocab)}
print(word2id)

# 3. 把一条句子编码成 id 列表
sentence = "大模型 需要 高质量 数据"
ids = [word2id[w] for w in sentence.split()]
print("编码结果:", ids)

# 4. 反查 id -> 词
id2word = {i: w for w, i in word2id.items()}
print("解码:", [id2word[i] for i in ids])
```

**运行结果：**

```
词表大小: 7
{'大模型': 0, '数据': 1, '大量': 2, '质量': 3, '需要': 4, '效果': 5, '决定': 6, ...}
编码结果: [0, 4, 5, 1]
解码: ['大模型', '需要', '高质量', '数据']
```

你看，短短十几行就完成了"语料 → 词表 → 编码 → 解码"这条完整的 NLP 链路。这就是 tokenizer 最朴素的版本——真实的 BPE tokenizer 比它复杂，但核心思想一模一样：**用 set 去重、用 dict 建映射、用 list 存序列**。

## 八、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| list 别名共享 | `a = [1]; b = a; b.append(2)` → a 也变了 | 用 `b = a.copy()` 或 `list(a)` |
| 遍历时修改列表 | `for x in lst: lst.remove(x)` 会漏元素 | 遍历副本 `for x in lst[:]` 或用推导式 |
| dict 键不存在 | `config["epochs"]` 抛 KeyError | 用 `config.get("epochs", 默认值)` |
| set 无序 | 不能按下标取元素 | 需要顺序就先 `sorted()` |
| 推导式过度嵌套 | 三层以上读不懂 | 拆成普通 for 循环 |

两个重点：

1. **list 的别名共享**：`b = a` 不是复制，是给同一个列表贴了第二个标签。要复制必须用 `a.copy()`（浅拷贝）或 `copy.deepcopy()`（深拷贝，嵌套结构用）。
2. **遍历时不要修改容器**："边遍历边删"会让下标错位，漏掉元素。要么遍历副本，要么用推导式生成一个新列表。

## 九、四种容器对比

| 容器 | 语法 | 可变 | 有序 | 典型用途 |
|---|---|---|---|---|
| list | `[1, 2]` | ✅ | ✅ | 序列数据、batch、结果收集 |
| tuple | `(1, 2)` | ❌ | ✅ | 形状常量、多返回值、字典 key |
| dict | `{"a": 1}` | ✅ | ✅(3.7+) | 配置、映射表、state_dict |
| set | `{1, 2}` | ✅ | ❌ | 去重、集合运算、词表 |

选择口诀：**要顺序用 list，要不改用 tuple，要映射用 dict，要去重用 set**。

## 十、本篇小结

1. **list** 是最常用的可变序列，嵌套 list 就是矩阵，天然对应 batch 数据。
2. **tuple** 不可变，适合形状常量、多返回值和字典 key。
3. **dict** 是配置与映射的主力，用 `get(k, default)` 避免 KeyError。
4. **set** 负责去重和集合运算，是构建词表的第一道工序。
5. **推导式**一行完成转换，但别嵌套过深。
6. 我们用这四件套，从零实现了"语料 → 词表 → 编码解码"的 mini tokenizer。

下一篇讲**控制流**——if、for、while 与可迭代对象。你会看到训练循环、早停（early stopping）、数据过滤这些核心逻辑，全都是控制流在驱动。

> 本篇是《大模型开发从 0 到 1》专栏第 4 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
