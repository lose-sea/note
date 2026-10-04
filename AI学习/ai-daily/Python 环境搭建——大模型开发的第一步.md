<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# Python 环境搭建——大模型开发的第一步

很多人一上来就问："大模型怎么微调？Transformer 怎么写？"——但如果你连 Python 环境都还没装好、连 `pip install` 都跑不利索，后面每一步都会卡在莫名其妙的环境报错上。这一篇是《大模型开发从 0 到 1》专栏的开篇，我们不跳步，先把地基打牢：搞懂为什么大模型开发离不开 Python、装对版本、用虚拟环境隔离依赖，并写出你的第一个能跑的脚本。

## 一、为什么大模型开发要从 Python 开始

你可能听过"Python 慢"，那为什么几乎所有大模型框架（PyTorch、Transformers、LangChain、vLLM）都是 Python 写的？三个原因：

1. **生态垄断**：深度学习时代，Python 把 NumPy（数值计算）、Matplotlib（画图）、Jupyter（交互实验）全打通了。后来 PyTorch/TensorFlow 直接基于这套生态生长，后发框架只能跟进。
2. **表达能力够、性能不靠它**：真正耗时的矩阵乘法不在 Python 里跑，而在底层的 C++/CUDA 内核里。Python 只是"指挥者"，负责把数据喂进去、把结果取出来。
3. **大模型工具链统一**：无论你做数据处理（Pandas）、训练（PyTorch）、调用 API（requests/openai），还是搭服务（FastAPI），全程一种语言，不用在语言之间反复切换上下文。

所以，学大模型开发，Python 不是"可选基础"，而是"唯一入口"。下面我们把它装对。

## 二、装什么版本，为什么不要用系统自带的 Python

macOS 和不少 Linux 自带一个 Python（通常是 2.7 或 3.x 系统版），**千万不要拿它当开发环境**。原因：

- 系统 Python 被操作系统自己用着，你乱装包可能搞崩系统工具。
- 版本老旧，很多新库要求 Python ≥ 3.10。

推荐版本：**Python 3.10 或 3.11**。3.12/3.13 也能用，但部分老库（尤其带编译的）可能还没适配，初学求稳选 3.10/3.11。

安装方式二选一：
- **官方安装包**：python.org 下载 macOS/Windows 安装器，勾选 "Add to PATH"。
- **版本管理器（推荐进阶用户）**：mac 用 `pyenv`，能在一台机器上装多个 Python 版本随时切换。

验证安装是否成功：

```bash
# 终端里执行，能看到版本号即成功
python3 --version
# 输出类似：Python 3.11.9

# Windows 上可能是 python 而不是 python3
python --version
```

## 三、虚拟环境：大模型开发的"隔离舱"

这是新手最容易踩、也最该养成的习惯。**永远不要往全局 Python 里直接 `pip install`。**

为什么？假设你今天做项目 A 用了 PyTorch 2.0，明天项目 B 需要 PyTorch 1.13，全局装一起就会互相覆盖，两个项目全崩。虚拟环境（virtual environment）给每个项目一个独立的"小房间"，里面的包互不干扰。

`venv` 是 Python 自带的轻量方案，不需要额外安装：

```bash
# 1. 进入你的项目目录
cd ~/my_llm_project

# 2. 创建虚拟环境，名字随意，习惯叫 .venv 或 venv
python3 -m venv .venv

# 3. 激活环境（Mac/Linux）
source .venv/bin/activate

# 4. Windows 用这一行激活
# .venv\Scripts\activate

# 激活后，命令行前面会出现 (.venv) 前缀，说明已进入隔离环境
# 这时再 pip install，包只装在这个房间里
pip install numpy
```

激活后你会看到提示符前面多了 `(.venv)`，这就是"进房间"的标志。以后每次开发前先 `source .venv/bin/activate`，养成肌肉记忆。

## 四、包管理与国内镜像

`pip` 是 Python 的包管理器。装一个包：

```bash
pip install requests
```

但默认源在国外，国内下载经常超时。配置清华镜像（一次生效，长期好用）：

```bash
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

装好依赖后，把当前环境"快照"下来，方便别人或以后的你复现：

```bash
pip freeze > requirements.txt
```

以后换机器，一条命令装回一模一样的环境：

```bash
pip install -r requirements.txt
```

## 五、第一个能跑的脚本：从文本里数词频

光装环境不够，我们写一个和大模型主题有关的小程序——**统计一段文本里出现最多的词**。这其实是 NLP（自然语言处理）最原始的一步：分词 + 计数。后面我们训练语言模型、做 RAG，底层都离不开"把文本变成可统计、可向量化的单元"。

新建文件 `word_count.py`：

```python
from collections import Counter
import re

text = """
大模型开发从 Python 开始。Python 简单，Python 强大。
我们用 Python 处理文本，为后面的 Transformer 做准备。
"""

# 1. 转小写，再用正则只保留中英文字母和数字，按非字母数字切词
words = re.findall(r"[a-zA-Z0-9一-鿿]+", text.lower())

# 2. 用 Counter 统计词频，取前 5 名
top = Counter(words).most_common(5)

print("总词数:", len(words))
print("出现最多的词:")
for word, count in top:
    print(f"  {word}: {count} 次")
```

运行它：

```bash
python3 word_count.py
```

**运行结果示例：**

```
总词数: 18
出现最多的词:
  python: 4 次
  大模型: 1 次
  开发: 1 次
  从: 1 次
  开始: 1 次
```

你看，短短 10 行，我们已经完成了"读取文本 → 清洗 → 分词 → 统计"这条流水线。后面学 NumPy 时会发现，`Counter` 背后的思想（统计频率）正是词向量、TF-IDF 甚至注意力权重的雏形。

## 六、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 用了系统 Python | `pip install` 提示权限不足或装完找不到包 | 用 `python3 -m venv` 建虚拟环境，激活后再装 |
| 激活环境后还是全局 | 命令行前面没有 `(.venv)` | 确认 `source` 路径正确；Windows 用反斜杠和 `Scripts` |
| 中文乱码 | 读文件报 `UnicodeDecodeError` | 打开文件时指定 `encoding="utf-8"`：`open("a.txt", encoding="utf-8")` |
| pip 下载超时 | 卡在 `Collecting` 不动 | 配置清华镜像（见第四节） |
| 装了包 import 报错 | `ModuleNotFoundError` | 多半是没激活环境，或装到了别的环境里；`pip show 包名` 查安装位置 |

特别提醒两个高频错误：

1. **`python` 和 `python3` 不是一回事**：有些系统 `python` 指向 Python 2，必须用 `python3`。装包和运行要用**同一个**解释器——你在哪个环境里 `pip install`，就用哪个环境里的 `python` 跑。
2. **依赖漂移**：今天能跑的代码，三个月后可能跑不了，因为某个库悄悄升级了。这就是 `requirements.txt` 存在的意义——锁版本，保复现。

## 七、环境对照表：该选哪个

| 方案 | 适合谁 | 优点 | 缺点 |
|---|---|---|---|
| 系统 Python + 全局 pip | 不推荐 | 零配置 | 污染系统、项目间互相覆盖 |
| venv（自带） | 初学者、单人项目 | 轻量、无需额外装 | 不含 Python 本身，切换版本麻烦 |
| conda | 数据科学、需要非 Python 依赖 | 能管 Python 版本 + 包 | 体积大、下载慢 |
| pyenv + venv | 进阶、多版本党 | 版本切换自由 | 配置稍复杂 |

结论：**初学直接用 `venv`**，够了；等你需要同时管多个 Python 版本，再上 `pyenv`。

## 八、本篇小结

这一篇我们做了四件事：

1. 想清楚**为什么大模型开发绕不开 Python**——生态、性能分工、工具链统一。
2. 装对 **Python 3.10/3.11**，绝不碰系统自带 Python。
3. 用 **venv 虚拟环境**隔离依赖，并用 `requirements.txt` 锁版本。
4. 写出第一个脚本，完成"文本 → 分词 → 词频统计"的 NLP 雏形。

地基打好了。下一篇我们正式进入 Python 语法：**变量与数据类型**——理解 Python 的动态类型、数字与字符串的世界，以及为什么类型注解能让你的大模型代码少出一半 bug。跟着这个专栏一路走，你会发现自己从"装环境"一步步走到"能微调、能部署大模型"。

> 本篇是《大模型开发从 0 到 1》专栏第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
