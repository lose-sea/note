<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 面向对象——class、self 与继承，写出可复用的 LLM 工具

**承上**：上一篇《函数》我们把重复逻辑封装成了函数，但当多个函数要共享一堆状态时，参数会越传越多。

**本篇**：本篇用 class 把「数据 + 行为」打包成一个对象，理解 self、继承与组合。

**启下**：下一篇《模块与包——import 机制与 requirements》把多个类拆成文件，组织成可安装的工程。

**学完这一节，你能动手做**：

1. 封装一个 PromptBuilder 类，管理多轮对话模板与变量填充
2. 用继承抽出「模型基类」，派生出不同厂商的实现而不用改调用方
3. 判断什么时候该用类、什么时候一个函数就够，避免过度设计


到目前为止我们的代码是"数据 + 函数"。但当你要封装一个**分词器**、一个**模型**、一个**RAG 检索器**时，光有函数就不够了——这些组件既有**状态**（词表、权重、索引），又有**行为**（编码、前向、检索）。**面向对象（OOP）**就是把"状态 + 行为"打包成一个对象。这一篇是理解 PyTorch `nn.Module` 的关键前置知识。

## 一、为什么大模型离不开类

想一想 PyTorch 里你一定会写的代码：

```python
class MyModel(nn.Module):
    def __init__(self, hidden_size):
        super().__init__()
        self.linear = nn.Linear(hidden_size, 2)

    def forward(self, x):
        return self.linear(x)
```

- `__init__` 里定义**状态**（层的权重）；
- `forward` 定义**行为**（怎么算）；
- `self` 让每个方法都能访问到自己的状态。

不懂类和 `self`，这段代码就是天书。所以这一篇必须吃透。

## 二、类与对象：图纸和房子

```python
class Tokenizer:
    """最简单的分词器：类就是图纸"""

    def __init__(self, vocab):
        # 初始化方法，创建对象时自动调用
        # self 代表"这个对象自己"
        self.word2id = {w: i for i, w in enumerate(vocab)}
        self.id2word = {i: w for w, i in self.word2id.items()}

    def encode(self, text):
        """把文本变成 id 列表"""
        return [self.word2id[w] for w in text.split() if w in self.word2id]

    def decode(self, ids):
        """把 id 列表还原成文本"""
        return " ".join(self.id2word[i] for i in ids)


# 创建对象（按图纸造房子）
tok = Tokenizer(["我", "爱", "大模型"])

print(tok.encode("我 爱 大模型"))   # [0, 1, 2]
print(tok.decode([2, 1, 0]))        # 大模型 爱 我
```

关键点：

- `class 类名:` 定义类；
- `__init__` 是**构造方法**，创建对象时自动调用，用来初始化状态；
- **第一个参数必须是 `self`**，代表对象自己；调用时不用传，Python 自动传入；
- `self.xxx` 是**实例属性**，每个对象各有一份；
- 定义在类里的函数叫**方法**，通过 `对象.方法()` 调用。

## 三、`self` 到底是什么

很多新手对 `self` 发懵。一句话解释：**`self` 就是"当前这个对象"**。

```python
tok1 = Tokenizer(["我", "爱"])
tok2 = Tokenizer(["数据", "质量"])

print(tok1.word2id)   # {'我': 0, '爱': 1}
print(tok2.word2id)   # {'数据': 0, '质量': 1}
```

两个对象的 `word2id` 互不影响——因为它们各自的 `self` 指向不同的对象。如果不写 `self`（写成局部变量 `word2id = ...`），那这个变量在方法结束就消失了，对象根本存不住状态。

## 四、继承：复用别人的代码

继承让你基于现有类创建新类，只写"不一样的部分"：

```python
class BaseTokenizer:
    """基类：提供通用能力"""
    def __init__(self, vocab):
        self.word2id = {w: i for i, w in enumerate(vocab)}

    def vocab_size(self):
        return len(self.word2id)


class SimpleTokenizer(BaseTokenizer):
    """子类：继承基类，并加上自己的编码/解码"""
    def __init__(self, vocab):
        super().__init__(vocab)          # 调用父类的初始化
        self.id2word = {i: w for w, i in self.word2id.items()}

    def encode(self, text):
        return [self.word2id[w] for w in text.split() if w in self.word2id]


t = SimpleTokenizer(["我", "爱", "大模型"])
print(t.vocab_size())          # 3 ← 继承自父类的方法
print(t.encode("我 爱"))        # [0, 1] ← 自己的方法
```

- `class 子类(父类)` 表示继承；
- `super().__init__(...)` 调用父类的构造方法（**必须写**，否则父类状态没初始化）；
- 子类自动拥有父类的方法，还能**重写**或新增。

**这就是 `nn.Module` 的工作方式**：你写 `class MyModel(nn.Module)` 并 `super().__init__()`，然后只需实现 `forward`，其余能力（参数管理、`to(device)`、`eval()`）全从父类继承。

## 五、魔术方法：让对象支持内置语法

以 `__` 开头结尾的方法叫**魔术方法**，能让你自定义对象行为：

```python
class Vocab:
    def __init__(self, words):
        self.words = sorted(set(words))
        self.index = {w: i for i, w in enumerate(self.words)}

    def __len__(self):
        return len(self.words)              # 支持 len(v)

    def __getitem__(self, w):
        return self.index[w]                # 支持 v["我"]

    def __contains__(self, w):
        return w in self.index              # 支持 "我" in v

    def __repr__(self):
        return f"Vocab(size={len(self.words)})"   # print 时的显示


v = Vocab(["我", "爱", "我", "大模型"])
print(len(v))          # 3（去重后）
print(v["大模型"])      # 1
print("爱" in v)       # True
print(v)               # Vocab(size=3)
```

常用的还有 `__str__`（转字符串）、`__eq__`（比较相等）、`__call__`（让对象像函数一样被调用——**PyTorch 的 `model(x)` 就是靠它实现的**）。

## 六、实战：一个可复用的提示词构造器

把 OOP 用起来，封装一个真实的 LLM 工具：

```python
class PromptBuilder:
    """构造结构化 prompt，支持角色设定与少样本示例"""

    def __init__(self, role="你是一个有帮助的 AI 助手"):
        self.role = role
        self.examples = []          # 少样本示例列表

    def add_example(self, question, answer):
        """添加一个问答示例（返回 self 以支持链式调用）"""
        self.examples.append((question, answer))
        return self

    def build(self, question):
        """拼装完整 prompt"""
        parts = [self.role, ""]
        if self.examples:
            parts.append("参考示例：")
            for q, a in self.examples:
                parts.append(f"Q: {q}\nA: {a}")
            parts.append("")
        parts.append(f"Q: {question}")
        parts.append("A:")
        return "\n".join(parts)

    def __len__(self):
        return len(self.examples)


# 链式调用，很像 LangChain 的风格
pb = (PromptBuilder("你是一个资深 Python 讲师")
      .add_example("什么是列表？", "列表是有序可变序列")
      .add_example("什么是字典？", "字典是键值对映射"))

print(pb.build("什么是类？"))
print("示例数量:", len(pb))
```

**运行结果：**

```
你是一个资深 Python 讲师

参考示例：
Q: 什么是列表？
A: 列表是有序可变序列
Q: 什么是字典？
A: 字典是键值对映射

Q: 什么是类？
A:
示例数量: 2
```

注意 `add_example` 里 `return self` 这个小技巧——它让方法可以**链式调用**，这在很多框架（LangChain、PyTorch 的部分 API）里非常常见。

## 七、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 忘记写 `self` | 方法里访问不到属性，或报参数数量错 | 实例方法的第一个参数必须是 `self` |
| 子类忘了 `super().__init__()` | 父类状态没初始化，报属性不存在 | 子类 `__init__` 首行调用 `super().__init__()` |
| 类属性被实例共享 | 一个实例改了，其他实例也变 | 状态放在 `__init__` 里的 `self.xxx` |
| 可变默认参数 | 同函数的经典坑 | 用 `None` 占位 |
| 过度设计 | 简单逻辑也强行套类 | 数据+几个函数就够时，用函数更简单 |

**类属性 vs 实例属性**要分清：

```python
class A:
    shared = []        # ❌ 类属性：所有实例共享同一份
    def __init__(self):
        self.own = []  # ✅ 实例属性：每个实例独立一份
```

## 八、本篇小结

1. **类**是图纸、**对象**是实例；`__init__` 初始化状态，方法定义行为。
2. **`self`** 代表当前对象，让方法能访问自己的状态；不写 `self` 就存不住数据。
3. **继承**用 `class 子(父)`，必须 `super().__init__()`，可复用并扩展父类能力——这正是 `nn.Module` 的用法。
4. **魔术方法**（`__len__`、`__getitem__`、`__call__` 等）让对象支持内置语法。
5. 实战封装了 `PromptBuilder`，并用 `return self` 实现链式调用。

下一篇讲**模块与包**——import 机制与 requirements 依赖管理。你会学到怎么把自己的代码拆成多个文件、怎么组织一个像样的项目结构，以及如何用 `requirements.txt` 锁住依赖让环境可复现。

> 本篇是《大模型开发从 0 到 1》专栏第 7 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
