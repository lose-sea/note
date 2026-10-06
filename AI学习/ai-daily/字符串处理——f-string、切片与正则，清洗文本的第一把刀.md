<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 字符串处理——f-string、切片与正则，清洗文本的第一把刀

**承上**：上一篇《变量与数据类型》我们认识了 Python 的五种基本类型。

**本篇**：专攻字符串——f-string 格式化、切片截断与反转、常用清洗方法、正则批量提取，以及编码与字节的关系。

**启下**：下一篇《容器类型全家桶——list、tuple、dict、set 与推导式》把清洗后的语料装起来、去重、统计词频。

**学完这一节，你能动手做**：

1. 用 f-string 构造可复用的 Prompt 模板，把变量安全填进提示词
2. 用切片截断过长上下文，保住模型的上下文窗口
3. 用正则批量提取与替换脏文本，完成语料清洗的第一步

上一篇讲了变量与数据类型，这一篇专门攻克**字符串**。为什么把它单独拎出来？因为大模型的世界里，**文本就是一切**：你给模型的 prompt 是字符串，模型吐出来的回答是字符串，训练语料是成千上万字符串，连"分词"本质也是把字符串切成小块再变成数字。可以说，字符串处理是做大模型开发的"第一道 preprocessing 工序"。这一篇把 f-string、切片、常用方法和正则一次讲透。

## 一、字符串是什么：一段不可变的字符序列

Python 的字符串用单引号、双引号或三引号包裹：

```python
s1 = 'hello'
s2 = "你好"
s3 = """这是一段
可以换行的多行文本"""
```

三引号特别适合写**多行 prompt 模板**——后面做 RAG、Agent 时，经常要把一整段指令模板原样保留。

字符串是**不可变**的：你不能修改其中某个字符，任何"修改"其实都生成了新字符串。这个特性后面会反复遇到。

还有**原始字符串** `r"..."`，里面的反斜杠不当作转义：

```python
path = r"C:\Users\name\data"   # 反斜杠原样保留，不转义
```

写正则时几乎必用原始字符串，否则一个 `\d` 会被 Python 先转义掉。

## 二、f-string：最干净的格式化方式

把变量塞进字符串，有三种老法子，但**只推荐 f-string**：

```python
name = "大模型"
score = 0.923

# 老写法（不推荐）
old = "模型：%s，得分：%.3f" % (name, score)
old2 = "模型：{}，得分：{:.3f}".format(name, score)

# f-string（推荐）
new = f"模型：{name}，得分：{score:.3f}"
print(new)   # 模型：大模型，得分：0.923
```

f-string 用 `f"..."`，大括号 `{}` 里直接写变量或表达式，还能用 `:.3f` 这类格式说明符控制小数位。大模型的输出经常要拼成固定格式（比如 `"问题：{q}\n答案：{a}"`），f-string 是最顺手的选择。

## 三、切片：像切黄瓜一样切字符串

字符串是序列，支持切片 `s[start:end:step]`（左闭右开，下标从 0 开始）：

```python
text = "Hello, 大模型"
print(text[0:5])     # Hello
print(text[7:])      # 大模型（从第7个到末尾）
print(text[::-1])    # 型模大 ,olleH（整个反转）

# 取前 10 个字符，避免超长文本炸掉模型上下文
truncated = text[:10]
```

**切片和大模型的"序列"概念是一脉相承的**：后面你学 Transformer，会发现一句话被切成 token 序列，取第 1 到第 K 个 token、反转、截断，用的就是同一套切片思维。这里先建立直觉。

## 四、常用方法：清洗文本的几把快刀

```python
raw = "  【重要】请删除 这段  多余的空格和符号！！  \n"

print(raw.strip())          # 去掉首尾空白
print(raw.lower())           # 转小写（归一化，便于匹配）
print(raw.replace("！", "")) # 替换掉感叹号
print(raw.split())           # 按空白切词：['【重要】请删除', '这段', '多余的空格和符号！！']
print(raw.startswith("  【"))  # True
```

这些方法组合使用，就能把脏文本"洗"干净。比如做数据清洗时，常先 `strip()` 再去重再 `lower()`。

## 五、正则：批量提取与替换的瑞士军刀

当规则稍微复杂（提取邮箱、URL、只留中文、去掉所有标点），字符串方法就不够用了，上 `re` 模块：

```python
import re

messy = "联系方式：alice@example.com，官网 https://ai.com，电话 13800000000。备注：#测试#"

# 1. 提取所有邮箱
emails = re.findall(r"[a-zA-Z0-9_.]+@[a-zA-Z0-9.]+", messy)
print(emails)   # ['alice@example.com']

# 2. 只保留中文字符（清洗噪声）
chinese_only = re.sub(r"[^\u4e00-\u9fa5]", "", messy)
print(chinese_only)   # 联系方式官网电话备注测试

# 3. 把多个空白压缩成一个
clean = re.sub(r"\s+", " ", messy)
print(clean)
```

- `re.findall(pattern, text)`：返回所有匹配，适合"提取"；
- `re.sub(pattern, repl, text)`：替换，适合"清洗"；
- `\s` 匹配空白，`\u4e00-\u9fa5` 是中文 Unicode 区间。

**这正是大模型语料清洗的核心动作**：原始网页/文档充满 HTML 标签、广告、乱码，用正则批量剔除，才能得到干净的训练文本。后面学 tokenizer（把字符串变 token id）之前，这步少不了。

## 六、编码：字符串与字节的桥梁

字符串在内存里是 Unicode，但要存盘或网络传输，得变成字节，这一步叫**编码**：

```python
text = "大模型开发"
b = text.encode("utf-8")      # 变成字节：b'\xe5\xa4\xa7...'
print(len(b))                 # 18（每个汉字约 3 字节）
back = b.decode("utf-8")      # 再解码回字符串
print(back)                   # 大模型开发
```

`encode` 把字符串 → 字节，`decode` 反过来。读文件/接口数据时常见 `UnicodeDecodeError`，多半是编码对不上（中文几乎都用 `utf-8`）。

**和大模型的关系**：tokenizer 做的事，本质上比这更进一层——它把字符串按子词（BPE/WordPiece）切成片段，再映射成整数 id。你现在理解的"字符串 ↔ 字节 ↔ 数字"，正是 tokenizer 把"文本变模型能吃的数字"的思想地基。

## 七、常见坑与注意事项

| 坑 | 现象 | 解决办法 |
|---|---|---|
| 字符串不可变 | `s[0] = 'x'` 报 TypeError | 用切片/替换生成新字符串 |
| 用 `+` 大量拼接 | 循环里 `s += x` 很慢 | 用 `list` 收集后 `"".join()` |
| 忘记原始字符串 | 正则里 `\d` 被转义 | 用 `r"..."` 包裹正则 |
| 正则贪婪匹配 | `a.*b` 吞掉中间所有内容 | 用非贪婪 `a.*?b` |
| 编码不一致 | 读文件报 UnicodeDecodeError | 指定 `encoding="utf-8"` |

两个重点：

1. **`+` 拼接性能陷阱**：字符串不可变，每次 `+` 都生成新对象。在循环里拼几千次会非常慢。正确做法是用列表收集片段，最后 `"".join(parts)` 一次性合并。
2. **正则贪婪 vs 非贪婪**：默认 `.*` 是贪婪的，会尽可能多吃字符。要"少吃"就在后面加 `?` 变成 `.*?`。比如从 HTML 里提取标签内容，几乎都用非贪婪。

## 八、本篇小结

这一篇我们掌握了大模型文本处理的"第一把刀"：

1. 字符串是**不可变**的字符序列，三引号写多行模板、原始字符串 `r"..."` 写正则。
2. **f-string** 是最干净的格式化方式，拼 prompt 首选。
3. **切片** `s[start:end:step]` 用于截断、反转——和后面 token 序列的思维一致。
4. `strip/lower/replace/split` 等方法快速清洗，`re` 模块做复杂提取与替换。
5. `encode/decode` 连接字符串与字节，是 tokenizer 思想的前奏。

下一篇进入**容器类型全家桶**——list、tuple、dict、set 与推导式。你马上会看到，模型的 batch 数据是 list，配置是 dict，去重用 set，而推导式能一行写出高效转换。字符串讲完，我们离"能处理真实数据"又近了一步。

> 本篇是《大模型开发从 0 到 1》专栏第 3 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
