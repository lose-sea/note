<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 模块与包——import 机制与 requirements 管理依赖

**承上**：上一篇《面向对象》我们把工具封装成了类，但所有类挤在一个文件里迟早失控。

**本篇**：本篇学 import 机制、包结构组织与 requirements 依赖管理，把脚本变成工程。

**启下**：下一篇《文件与异常——open、json、with 与 try-except》让程序读写真实数据并处理出错。

**学完这一节，你能动手做**：

1. 把一个大脚本拆成规范的包结构并正确 import（含相对导入）
2. 用 requirements.txt 锁定版本，复现别人的环境不再报「我这里能跑」
3. 理解 if __name__ == "__main__" 的作用与循环导入的成因


到目前为止我们写的代码都在一个文件里。但真实的大模型项目少则十几个、多则上百个 `.py` 文件：数据加载、模型定义、训练循环、评估脚本各管一摊。**模块与包**就是 Python 组织代码的方式。这一篇讲清楚 import 怎么用、项目怎么拆、依赖怎么锁——这三件事做不好，项目一大就会变成"import 报错地狱"。

## 一、为什么大模型项目必须拆模块

一个典型的训练项目长这样：

```
my_llm_project/
├── data/
│   ├── __init__.py
│   ├── loader.py        # 数据加载
│   └── preprocess.py    # 清洗与分词
├── model/
│   ├── __init__.py
│   └── transformer.py   # 模型定义
├── train.py             # 训练入口
├── evaluate.py          # 评估脚本
└── requirements.txt     # 依赖清单
```

拆开的好处：**职责清晰**（改数据不动模型）、**可复用**（别的脚本能 import 同一份加载逻辑）、**可测试**（单独测某个模块）。

## 二、import 的四种写法

```python
import numpy                      # 1. 导入整个模块，用时加前缀
import numpy as np                # 2. 导入并起别名（最常用）
from transformers import AutoModel  # 3. 只导入需要的对象
from torch import nn, optim       # 4. 一次导入多个
```

用法对比：

```python
import numpy as np
a = np.array([1, 2, 3])          # 必须带 np. 前缀

from numpy import array
b = array([1, 2, 3])             # 直接调用，不用前缀
```

**建议**：优先用 `import 模块 as 别名`（尤其 numpy→np、pandas→pd、torch→nn 这类约定俗成的缩写）。`from x import *`（星号导入）是**反面教材**——它会把名字全塞进当前命名空间，很容易覆盖你自己的变量，永远不要用。

## 三、写一个自己的模块

**一个 `.py` 文件就是一个模块**，文件名就是模块名。

新建 `text_utils.py`：

```python
"""文本处理工具模块（模块顶部的字符串是模块文档）"""

import re

VERSION = "1.0.0"          # 模块级变量

def clean(text):
    """去掉首尾空白并压缩多余空格"""
    return re.sub(r"\s+", " ", text.strip())

def word_count(text):
    """统计词数"""
    return len(re.findall(r"[\u4e00-\u9fa5a-zA-Z0-9]+", text))


# 只有"直接运行本文件"时才执行，被 import 时不执行
if __name__ == "__main__":
    print(clean("  你好   世界  "))    # 你好 世界
    print(word_count("你好 世界"))      # 2
```

在同目录的另一个文件里使用：

```python
import text_utils

print(text_utils.VERSION)              # 1.0.0
print(text_utils.clean("  a   b  "))   # a b

# 或者按需导入
from text_utils import word_count
print(word_count("大模型 开发"))        # 2
```

## 四、`if __name__ == "__main__"` 是什么

这是 Python 非常重要的惯用法。每个模块都有一个 `__name__` 变量：

- **直接运行**该文件时，`__name__ == "__main__"`；
- **被 import** 时，`__name__` 是模块名（如 `"text_utils"`）。

所以上面那段 `if` 的意思是：**"我这个文件被直接运行时才跑测试代码，被别人 import 时别跑"**。这让模块既能独立测试，又能安全地被引用。

## 五、包：把多个模块装进目录

**包 = 含 `__init__.py` 的目录**。`__init__.py` 可以是空文件，作用是告诉 Python"这是个包"。

```
data/
├── __init__.py          # 可以是空的
├── loader.py
└── preprocess.py
```

使用：

```python
from data import loader              # 导入包里的模块
from data.loader import load_csv     # 导入模块里的具体函数
import data.preprocess as pp         # 起别名
```

`__init__.py` 里也可以写导入，让用户更方便：

```python
# data/__init__.py
from .loader import load_csv
from .preprocess import clean_text

# 这样用户可以直接：from data import load_csv, clean_text
```

## 六、绝对导入 vs 相对导入

```python
# 绝对导入（推荐）：从项目根目录写全路径
from data.loader import load_csv

# 相对导入（只能在包内部使用）：. 表示当前包，.. 表示上级
from .loader import load_csv          # 同包内
from ..model.transformer import MyModel  # 上级目录的包
```

**建议用绝对导入**。相对导入只在包内部模块之间用，且**不能直接运行**含相对导入的文件（会报 `ImportError: attempted relative import with no known parent package`），必须通过 `python -m 包名.模块名` 运行。

## 七、常用标准库（不用装，开箱即用）

| 模块 | 用途 | 典型用法 |
|---|---|---|
| `os` / `pathlib` | 路径与文件系统 | `os.path.join()`、`Path("a/b.txt")` |
| `sys` | 解释器相关 | `sys.argv`（命令行参数）、`sys.path` |
| `json` | JSON 读写 | `json.load()`、`json.dump()` |
| `re` | 正则 | `re.findall()`、`re.sub()` |
| `time` / `datetime` | 时间 | `time.time()` 计时 |
| `random` | 随机 | `random.seed(42)` 固定随机种子 |
| `collections` | 容器增强 | `Counter`、`defaultdict` |
| `logging` | 日志（比 print 专业） | `logging.info()` |

## 八、依赖管理：requirements.txt

第三方库（numpy、torch、transformers）用 pip 装，但**必须记录版本**，否则换台机器就跑不起来：

```bash
# 安装（在虚拟环境里）
pip install numpy==1.26.4 pandas==2.2.2

# 导出当前环境的完整依赖快照
pip freeze > requirements.txt
```

`requirements.txt` 内容示例：

```
numpy==1.26.4
pandas==2.2.2
torch==2.1.2
transformers==4.36.0
```

换机器复现环境：

```bash
pip install -r requirements.txt
```

**这就是"环境可复现"的关键**。做实验时务必固定随机种子 + 锁依赖版本，否则"同一份代码两次结果不一样"会让你怀疑人生。

## 九、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 循环导入 | A import B，B 又 import A，报 ImportError | 重构：把公共部分抽到第三个模块 |
| 模块名撞车 | 你写了 `json.py`，`import json` 导入了你自己的 | 别用标准库名字命名文件 |
| 相对导入报错 | `attempted relative import...` | 用绝对导入，或 `python -m` 运行 |
| 忘写 `__init__.py` | 目录不被识别为包（Python 3.3+ 可省略，但建议保留） | 加上空 `__init__.py` |
| 找不到模块 | `ModuleNotFoundError` | 确认在项目根目录运行，或把根目录加入 `PYTHONPATH` |
| 用 `from x import *` | 命名空间污染 | 永远别用 |

两个高频问题：

1. **`ModuleNotFoundError: No module named 'xxx'`**：先确认你在**项目根目录**运行脚本，因为 Python 会把"运行脚本所在目录"加入 `sys.path`（模块搜索路径）。
2. **循环导入**：`a.py` 顶部 `import b`，`b.py` 顶部 `import a` → 互相等对方加载完，直接报错。解法是把共享的东西抽到 `common.py`，或者把 import 放到函数内部延迟导入。

## 十、本篇小结

1. **模块 = 一个 `.py` 文件**，用 `import` 引入；优先用 `import x as 别名`，禁用 `from x import *`。
2. **`if __name__ == "__main__"`** 让文件既能独立运行测试，又能安全被 import。
3. **包 = 含 `__init__.py` 的目录**，用来组织多个模块；推荐**绝对导入**。
4. 常用标准库 `os/pathlib`、`json`、`re`、`random`、`collections`、`logging` 开箱即用。
5. **依赖必须锁版本**：`pip freeze > requirements.txt`，换机器 `pip install -r requirements.txt`。

下一篇讲**文件与异常**——`open/json/with` 与 `try-except` 的工程写法。你会学到怎么读写训练数据、加载 JSON 配置，以及怎么写"读一万条数据遇到一条坏的也不崩"的健壮代码。

> 本篇是《大模型开发从 0 到 1》专栏第 8 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
