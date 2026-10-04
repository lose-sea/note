<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 控制流——if、for、while 与可迭代对象

上一篇我们用容器把数据装好了，这一篇让代码"动起来"——**控制流**。为什么它重要？因为大模型里最核心的几段逻辑，本质都是控制流：**训练循环**（for epoch）、**早停**（if + break）、**数据过滤**（if）、**生成直到结束符**（while）。把控制流写顺，你就能读懂甚至写出训练脚本的主干。

## 一、if / elif / else：做判断

```python
loss = 0.023

if loss < 0.01:
    print("收敛得很好，可以停了")
elif loss < 0.1:
    print("还在下降，继续训练")
else:
    print("loss 太高，检查数据或学习率")
```

注意 Python 用**缩进**（通常 4 个空格）划分代码块，不用大括号。缩进错了逻辑就错了，这是新手最常见的编译期错误。

### 真值测试：空容器是"假"

```python
if not []:
    print("空列表是假")          # 会执行
if not "":
    print("空字符串是假")         # 会执行
if 0:
    print("0 是假")              # 不会执行
if "0":
    print("非空字符串'0'是真")    # 会执行！注意和数字 0 的区别
```

记住：**空容器 `[] {} () ""`、数字 `0`、`None` 都是假**，其余为真。这个特性让判断写得很简洁，但也要小心 `0` 和 `"0"` 的区别。

## 二、for 循环：遍历序列

```python
epochs = [1, 2, 3]
for e in epochs:
    print(f"第 {e} 轮训练")
```

三个高频搭档：

```python
words = ["我", "爱", "大模型"]

# enumerate：同时拿到下标和值
for i, w in enumerate(words):
    print(i, w)          # 0 我 / 1 爱 / 2 大模型

# range：生成数字序列
for step in range(0, 100, 10):    # 从 0 到 100（不含），步长 10
    print(step)

# zip：同时遍历两个列表
questions = ["Q1", "Q2"]
answers = ["A1", "A2"]
for q, a in zip(questions, answers):
    print(f"{q} -> {a}")
```

## 三、while 与 break / continue / else

`while` 在条件为真时一直循环，适合"不知道要循环多少次"的场景：

```python
# 生成式任务：一直生成，直到遇到结束符或达到最大长度
generated = []
max_len = 20
while len(generated) < max_len:
    token = "下一个词"          # 假装模型输出
    if token == "<EOS>":
        break                  # 遇到结束符，跳出循环
    generated.append(token)
else:
    print("循环正常结束（没触发 break）")
```

- `break`：直接跳出整个循环；
- `continue`：跳过本次，进入下一轮；
- `for/while ... else`：循环**没有被 break 中断**时才执行 else（这个语法很冷门但有用）。

## 四、可迭代对象：for 背后到底在干什么

你之所以能 `for x in 列表`，是因为列表是**可迭代对象**。它背后其实做了两件事：拿到迭代器 → 反复 `next()`。

```python
words = ["我", "爱", "大模型"]
it = iter(words)          # 拿到迭代器
print(next(it))           # 我
print(next(it))           # 爱
print(next(it))           # 大模型
# print(next(it))         # 抛 StopIteration，for 循环就是靠它结束的
```

理解这一点，后面读 `enumerate`、`zip`、生成器（yield）就不会懵——它们本质上都是"可迭代对象"。

## 五、实战：一个带早停的训练循环

把控制流串起来，写一个真实感很强的训练主干（不依赖任何深度学习库，用假数据模拟）：

```python
import random

random.seed(42)
loss = 2.5                      # 初始 loss
best_loss = float("inf")        # 记录历史最好
patience = 3                    # 连续 3 轮不改善就停
no_improve = 0

for epoch in range(1, 21):      # 最多训 20 轮
    # 模拟每轮 loss 下降（带一点随机波动）
    loss = loss * 0.85 + random.uniform(-0.02, 0.02)

    print(f"epoch {epoch:2d} | loss = {loss:.4f}")

    # 判断是否有改善
    if loss < best_loss - 1e-4:
        best_loss = loss
        no_improve = 0
        print(f"  ✔ 有改善，保存模型（best={best_loss:.4f}）")
    else:
        no_improve += 1
        print(f"  ✘ 无改善（{no_improve}/{patience}）")

    # 早停
    if no_improve >= patience:
        print(f"连续 {patience} 轮无改善，提前停止训练")
        break
else:
    print("20 轮全部跑完")

print(f"最终 best loss = {best_loss:.4f}")
```

**运行结果示例：**

```
epoch  1 | loss = 2.1274
  ✔ 有改善，保存模型（best=2.1274）
epoch  2 | loss = 1.8069
  ✔ 有改善，保存模型（best=1.8069）
...
epoch  8 | loss = 0.6532
  ✘ 无改善（1/3）
epoch  9 | loss = 0.6610
  ✘ 无改善（2/3）
epoch 10 | loss = 0.6498
  ✘ 无改善（3/3）
连续 3 轮无改善，提前停止训练
最终 best loss = 0.6512
```

这段代码包含了真实训练脚本的全部控制流骨架：**固定轮次的 for**、**判断改善的 if**、**计数与早停的 break**、**兜底的 else**。以后你看到 PyTorch 的训练循环，会发现结构完全一样，只是把"假 loss"换成了真实的 `loss.backward()`。

## 六、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 缩进不一致 | `IndentationError` 或逻辑错乱 | 统一 4 空格，别混用 Tab |
| 遍历时修改容器 | 漏元素或无限循环 | 遍历副本 `lst[:]`，或用推导式 |
| `range` 边界 | `range(1,10)` 不含 10 | 记住"左闭右开" |
| while 死循环 | 程序卡死不退出 | 确保条件会变化，或加最大次数保护 |
| 用 `==` 判断 None | 判断失效 | 用 `is None` / `is not None` |
| 浮点数做循环条件 | 精度误差导致多跑/少跑一轮 | 用整数计数，或用容差 |

两个重点提醒：

1. **`range(n)` 不含 n**：`range(1, 10)` 是 1~9。这是"左闭右开"惯例，和切片一致，习惯就好。
2. **while 一定要有出口**：循环体里必须让条件朝"假"的方向变化，否则死循环。稳妥做法是加一个 `max_steps` 上限（像上面 `range(1, 21)` 那样）。

## 七、for 与 while 怎么选

| 场景 | 推荐 | 原因 |
|---|---|---|
| 遍历已知序列（列表、range） | `for` | 简洁，自动处理结束 |
| 轮次固定的训练 | `for epoch in range(n)` | 轮数明确 |
| 次数未知，满足条件就停 | `while` | 如"生成到 EOS" |
| 需要下标 | `for i, x in enumerate(...)` | 比 `range(len())` 优雅 |
| 同时遍历多个序列 | `zip` | 自动对齐长度 |

口诀：**能数得清用 for，数不清用 while**。

## 八、本篇小结

1. `if/elif/else` 靠**缩进**分块；空容器、`0`、`None` 都是"假"。
2. `for` 配 `enumerate`（带下标）、`range`（数字序列）、`zip`（并行遍历）是三大高频用法。
3. `while` 适合次数未知的循环，`break` 跳出、`continue` 跳过、`else` 在未 break 时执行。
4. 可迭代对象背后是 `iter()` + `next()`，这是理解生成器和迭代器的钥匙。
5. 我们用控制流搭出了**带早停的完整训练循环骨架**——真实 PyTorch 脚本的主干结构一模一样。

下一篇讲**函数**——参数、lambda、`*args/**kwargs` 与作用域。你会学到怎么把重复逻辑封装成可复用的工具，这也是写出整洁大模型代码的关键一步。

> 本篇是《大模型开发从 0 到 1》专栏第 5 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
