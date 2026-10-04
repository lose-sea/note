<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# Python 进阶——迭代器、生成器、装饰器与 asyncio

基础语法到这里就齐了，这一篇是**阶段 0 的收官**，讲四个让代码从"能跑"变成"专业"的特性：**迭代器**（遍历的本质）、**生成器**（大数据集不炸内存）、**装饰器**（统一给函数加能力）、**asyncio**（并发调用 API 提速）。这四个在大模型工程里天天见——`for batch in loader` 是迭代器、流式读语料是生成器、`@torch.no_grad()` 是装饰器、批量调 API 要靠 asyncio。

## 一、生成器：大数据集的救命稻草

假设你有个 10GB 的语料文件。如果 `lines = f.readlines()`，内存直接爆掉。**生成器**的思路是：**要一条给一条，不一次性全给**。

用 `yield` 关键字定义生成器函数：

```python
def read_lazy(path):
    """惰性读取：一次只产一行"""
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            yield line.strip()      # 产出后暂停，下次从这里继续

# 使用：和遍历普通列表一样，但内存只占一行
for line in read_lazy("big_corpus.txt"):
    process(line)        # 处理完这行，内存就释放了
```

关键区别：`return` 是一次性返回并结束函数；`yield` 是**产出一个值并暂停**，下次调用从暂停处继续。这就是"惰性求值"。

**生成器表达式**（比列表推导式省内存）：

```python
# 列表推导式：立刻算出全部，占内存
squares_list = [x * x for x in range(10_000_000)]

# 生成器表达式：要一个算一个，几乎不占内存
squares_gen = (x * x for x in range(10_000_000))
print(next(squares_gen))    # 0
print(next(squares_gen))    # 1
```

区别就一个符号：`[]` vs `()`，但内存占用天差地别。

## 二、迭代器：for 循环背后的机制

生成器是一种**迭代器**。任何实现了 `__iter__()` 和 `__next__()` 的对象都是迭代器：

```python
items = ["a", "b", "c"]
it = iter(items)      # 拿迭代器
print(next(it))       # a
print(next(it))       # b
print(next(it))       # c
# next(it)           # 抛 StopIteration，for 循环靠它知道结束
```

所以 `for x in 某物` 的本质就是：**拿迭代器 → 反复 next → 遇到 StopIteration 停止**。

⚠️ **迭代器只能用一次**：遍历完了就空了，要再来一遍必须重新 `iter()`。这是新手常踩的坑（生成器尤其明显）。

## 三、装饰器：不改动原函数就给它加能力

装饰器本质是"**接收函数、返回函数**"的高阶函数，用 `@` 语法糖使用。

先看原理：

```python
def my_decorator(func):
    def wrapper(*args, **kwargs):
        print("函数执行前")
        result = func(*args, **kwargs)   # 调用原函数
        print("函数执行后")
        return result
    return wrapper

@my_decorator
def say_hi():
    print("hi")

say_hi()
# 函数执行前 / hi / 函数执行后
```

`@my_decorator` 等价于 `say_hi = my_decorator(say_hi)`。

### 实用场景 1：计时装饰器

```python
import time
from functools import wraps

def timer(func):
    @wraps(func)                    # 保留原函数的名字和文档
    def wrapper(*args, **kwargs):
        start = time.time()
        result = func(*args, **kwargs)
        print(f"[{func.__name__}] 耗时 {time.time() - start:.3f}s")
        return result
    return wrapper

@timer
def train_one_epoch():
    time.sleep(0.5)     # 假装训练
    return "done"

print(train_one_epoch())
# [train_one_epoch] 耗时 0.502s
# done
```

### 实用场景 2：重试装饰器（调 API 必备）

```python
from functools import wraps

def retry(times=3):
    """失败自动重试（带参数的装饰器）"""
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            for i in range(1, times + 1):
                try:
                    return func(*args, **kwargs)
                except Exception as e:
                    print(f"第 {i} 次失败: {e}")
                    if i == times:
                        raise
        return wrapper
    return decorator

@retry(times=3)
def call_llm_api(prompt):
    import random
    if random.random() < 0.6:        # 模拟 60% 概率失败
        raise ConnectionError("网络抖动")
    return "模型回答"

print(call_llm_api("你好"))
```

**`@wraps(func)` 必须加**——否则被装饰函数的 `__name__`、`__doc__` 会变成 wrapper 的，日志和文档全乱。

大模型里你见过的装饰器：`@torch.no_grad()`（推理时不算梯度，省显存）、`@staticmethod`、`@property`、`@app.post()`（FastAPI 路由）。

## 四、asyncio：并发调用 API 提速

调用大模型 API 时，大部分时间在**等网络响应**。串行调用 10 次 = 等 10 次网络；**并发**则几乎同时发出，总时间≈最慢那次。

```python
import asyncio
import time

async def call_api(prompt, delay):
    """async 定义协程；await 表示"这里可以让出控制权" """
    print(f"发出请求: {prompt}")
    await asyncio.sleep(delay)          # 模拟网络等待（非阻塞）
    return f"{prompt} 的回答"

async def main():
    start = time.time()
    # 并发执行多个任务
    tasks = [call_api(f"问题{i}", 1.0) for i in range(5)]
    results = await asyncio.gather(*tasks)
    print(results)
    print(f"并发耗时: {time.time() - start:.2f}s")

asyncio.run(main())
```

**运行结果：**

```
发出请求: 问题0
发出请求: 问题1
...
['问题0 的回答', '问题1 的回答', ...]
并发耗时: 1.00s      ← 5 个请求一起等，只花 1 秒
```

如果串行写，5 个请求各等 1 秒 = **5 秒**。并发后 **1 秒**，吞吐直接 ×5。这就是批量调用大模型 API 的核心提速手段（真实场景用 `aiohttp` 或 `openai.AsyncOpenAI`）。

三个关键词：

- `async def`：定义**协程**（可以被挂起的函数）；
- `await`：等待一个协程，**等待期间控制权交还事件循环**，去跑别的任务；
- `asyncio.gather()`：并发跑多个协程并收集结果；
- `asyncio.run()`：启动事件循环（入口）。

## 五、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 生成器只能用一次 | 第二次遍历是空的 | 重新生成，或转成 list |
| 装饰器丢元信息 | `func.__name__` 变成 wrapper | 用 `@wraps(func)` |
| 在 async 里用阻塞代码 | `time.sleep()` 会卡住整个循环 | 用 `await asyncio.sleep()` |
| 忘记 `await` | 拿到的是协程对象不是结果 | 协程前必须 `await` |
| 在非 async 函数里 `await` | 语法错误 | 调用链要一路 async 上去 |
| 用 `next()` 越过界 | 抛 StopIteration | 用 for 遍历更安全 |

重点提醒：**asyncio 里千万别用 `time.sleep()` / `requests`** 这类阻塞式调用，它们会卡死整个事件循环，并发直接退化成串行。要用 `asyncio.sleep()` 和 `aiohttp` / 异步 SDK。

## 六、四个特性对比

| 特性 | 解决什么问题 | 典型场景 |
|---|---|---|
| 迭代器 | 统一遍历接口 | `for batch in dataloader` |
| 生成器 | 大数据集省内存 | 流式读 10GB 语料、逐条产出样本 |
| 装饰器 | 不侵入地加能力 | 计时、重试、缓存、`@torch.no_grad()` |
| asyncio | 提高 IO 并发吞吐 | 批量调用大模型 API |

## 七、阶段 0 总结

到这里，**Python 基础语法阶段（0-1 ~ 0-10）全部完成**。我们走完了：

1. 环境搭建与虚拟环境 → 2. 变量与类型 → 3. 字符串 → 4. 容器 → 5. 控制流 → 6. 函数 → 7. 面向对象 → 8. 模块与包 → 9. 文件与异常 → 10. 迭代器/生成器/装饰器/asyncio。

你现在应该能读懂并写出结构完整、有异常处理、能处理大数据的 Python 脚本了。

**阶段 1 我们进入科学计算三件套**：先用 **NumPy** 搞懂"大模型的每一次计算都是矩阵乘法"，再用 **Pandas** 管理训练数据与实验记录，最后用 **Matplotlib** 把训练曲线画出来。这三件套是从"会写 Python"到"能做 AI 实验"的桥梁。

> 本篇是《大模型开发从 0 到 1》专栏第 10 篇，也是阶段 0「Python 基础语法」的收官篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
