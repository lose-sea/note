<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 文件与异常——open、json、with 与 try-except 的工程写法

模型跑在内存里，但**数据、配置、日志、checkpoint 全在磁盘上**。这一篇讲两件事：**文件读写**（怎么把训练数据读进来、把结果写出去）和**异常处理**（怎么让程序遇到坏数据不崩）。这两样是大模型工程里最日常、也最容易写出 bug 的部分。

## 一、为什么这两件事决定工程健壮性

想想真实场景：

- 读一个 5GB 的语料文件——不能一次全读进内存；
- 加载 `config.json` 配置——文件不存在要给默认值；
- 遍历一万条样本——第 37 条格式坏了，**不能因此让整个训练中断**；
- 保存 checkpoint——写一半断电，文件损坏。

处理不好这些，"跑 8 小时的训练在第 3 小时崩掉"就是家常便饭。

## 二、open 与 with：读写文件

```python
# 1. 一次性读完
with open("data.txt", "r", encoding="utf-8") as f:
    text = f.read()
    print(len(text))

# 2. 按行读（大文件推荐，省内存）
with open("data.txt", "r", encoding="utf-8") as f:
    for line in f:
        print(line.strip())

# 3. 写入（w 覆盖，a 追加）
with open("out.txt", "w", encoding="utf-8") as f:
    f.write("第一行\n")
    f.write("第二行\n")
```

**关键：一定要用 `with`**。`with` 是上下文管理器，它保证文件**无论中间是否出错都会被正确关闭**。不用 `with` 而手写 `f.close()`，一旦中间抛异常就永远不会执行 close，文件句柄泄漏。

文件模式对照：

| 模式 | 含义 | 文件不存在时 |
|---|---|---|
| `r` | 只读（默认） | 报错 |
| `w` | 只写，**清空原内容** | 新建 |
| `a` | 追加写 | 新建 |
| `r+` | 读写 | 报错 |

## 三、JSON：配置与结构化数据的首选

大模型项目的配置、数据集标注、API 返回，几乎都是 JSON。

```python
import json

# 写：Python dict -> JSON 文件
config = {
    "model_name": "qwen-7b",
    "learning_rate": 1e-4,
    "batch_size": 32,
    "use_lora": True,
}
with open("config.json", "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

# 读：JSON 文件 -> Python dict
with open("config.json", "r", encoding="utf-8") as f:
    loaded = json.load(f)
print(loaded["model_name"])    # qwen-7b

# 字符串 <-> 对象（处理 API 返回值时用）
s = json.dumps({"a": 1}, ensure_ascii=False)   # dict -> str
d = json.loads(s)                              # str -> dict
```

两个参数的讲究：

- `ensure_ascii=False`：让中文正常显示，否则会变成 `\u5927\u6a21\u578b`；
- `indent=2`：格式化缩进，方便人看。

注意区别：`json.load(f)` 读**文件**，`json.loads(s)` 读**字符串**（`s` = string）。写的时候是 `dump`（文件）和 `dumps`（字符串）。

## 四、路径处理：别硬编码

```python
from pathlib import Path

# 推荐 pathlib（面向对象，跨平台）
data_dir = Path("data")
file_path = data_dir / "train.jsonl"     # / 拼接路径，Windows 也正常
print(file_path.exists())                # 是否存在
print(file_path.name, file_path.suffix)  # train.jsonl .jsonl

data_dir.mkdir(parents=True, exist_ok=True)   # 建目录，已存在不报错

# 遍历目录下所有 txt
for p in Path(".").glob("*.txt"):
    print(p)
```

**永远用 `pathlib` 或 `os.path.join()` 拼路径**，别手写 `"data/" + name`——Windows 的反斜杠会让你调试半天。

## 五、异常处理：try / except / else / finally

```python
try:
    with open("config.json", "r", encoding="utf-8") as f:
        config = json.load(f)
except FileNotFoundError:
    print("配置文件不存在，使用默认配置")
    config = {"learning_rate": 1e-4}
except json.JSONDecodeError as e:
    print(f"配置格式错误：{e}")
    config = {}
except Exception as e:
    print(f"未知错误：{e}")
    raise          # 重新抛出，不要吞掉
else:
    print("配置加载成功")     # 没出异常才执行
finally:
    print("无论如何都会执行")  # 常用于释放资源
```

四条原则：

1. **捕获具体异常**（`FileNotFoundError`），不要裸写 `except:`——它会连 `Ctrl+C` 都吞掉；
2. **`else`** 放"成功后的逻辑"，`finally` 放"清理逻辑"；
3. **不要静默吞异常**：至少打印日志，或者 `raise` 重新抛出；
4. 用 `raise ValueError("...")` **主动抛出**异常来校验参数。

## 六、实战：健壮的数据加载器

把文件 IO + 异常处理结合起来，写一个"读一万条、坏几条也不崩"的加载器：

```python
import json
from pathlib import Path
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def load_dataset(path, required_keys=("text", "label")):
    """逐行读取 JSONL 数据集，跳过坏样本并记录日志"""
    good, bad = [], 0
    path = Path(path)

    if not path.exists():
        raise FileNotFoundError(f"数据文件不存在: {path}")

    with open(path, "r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue                     # 跳过空行
            try:
                item = json.loads(line)
                # 校验必需字段
                missing = [k for k in required_keys if k not in item]
                if missing:
                    raise KeyError(f"缺少字段 {missing}")
                good.append(item)
            except (json.JSONDecodeError, KeyError) as e:
                bad += 1
                logger.warning("第 %d 行跳过：%s", line_no, e)
                continue

    logger.info("加载完成：有效 %d 条，损坏 %d 条", len(good), bad)
    return good


# 造一个含坏数据的样本文件
sample = """{"text": "这个模型很好用", "label": 1}
{"text": "效果一般", "label": 0}
{"text": "缺少 label 字段"}
这不是 JSON
{"text": "再来一条", "label": 1}
"""
Path("demo.jsonl").write_text(sample, encoding="utf-8")

data = load_dataset("demo.jsonl")
print("有效样本:", data)
```

**运行结果：**

```
WARNING:__main__:第 3 行跳过：'缺少字段 [\'label\']'
WARNING:__main__:第 4 行跳过：Expecting value: line 1 column 1 (char 0)
INFO:__main__:加载完成：有效 3 条，损坏 2 条
有效样本: [{'text': '这个模型很好用', 'label': 1}, {'text': '效果一般', 'label': 0}, {'text': '再来一条', 'label': 1}]
```

这就是工业级数据加载的雏形：**逐行流式读取**（不占内存）+ **逐条 try/except**（坏数据不影响整体）+ **日志记录**（事后可追溯）。真实的 `datasets` 库也是这个思路，只是更完善。

## 七、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 忘记 `encoding="utf-8"` | 中文乱码或 UnicodeDecodeError | 所有 open 都显式指定 utf-8 |
| 不用 `with` | 异常时文件没关闭，句柄泄漏 | 一律用 `with` |
| `w` 模式误用 | 原文件被清空 | 追加用 `a`，写前先备份 |
| 裸 `except:` | 吞掉所有错误，bug 难查 | 捕获具体异常类型 |
| 一次 read 大文件 | 内存爆掉 | 逐行 `for line in f` |
| 硬编码路径分隔符 | Windows 上路径错 | 用 `pathlib` |
| JSON 中文变 `\uXXXX` | 可读性差 | `ensure_ascii=False` |

## 八、本篇小结

1. **文件读写一律用 `with`**，保证关闭；模式 `r`(读) / `w`(覆盖写) / `a`(追加)。
2. **JSON** 用 `load/dump`（文件）和 `loads/dumps`（字符串），中文记得 `ensure_ascii=False`。
3. **路径用 `pathlib`**，`/` 拼路径，跨平台安全。
4. **异常捕获要具体**，`else` 放成功逻辑、`finally` 放清理，别裸 `except:`。
5. 实战写出了**逐行流式 + 逐条容错 + 日志记录**的数据加载器——工业级数据管道就是这个雏形。

下一篇讲 **Python 进阶**——迭代器、生成器、装饰器与 asyncio。你会学到怎么用生成器处理"大到读不进内存"的数据集、用装饰器给函数统一加计时/重试、用 asyncio 并发调用大模型 API（这是把吞吐提上去的关键）。

> 本篇是《大模型开发从 0 到 1》专栏第 9 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
