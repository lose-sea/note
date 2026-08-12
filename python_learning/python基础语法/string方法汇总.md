## Python 字符串（String）所有方法汇总

Python 字符串是**不可变序列**，所有方法都**返回新字符串**，不修改原字符串。我按功能分类整理如下：

------

## 一、大小写转换（6个方法）

| 方法           | 说明                                     | 示例                                      |
| :------------- | :--------------------------------------- | :---------------------------------------- |
| `capitalize()` | 首字母大写，其余小写                     | `"hello".capitalize()` → `"Hello"`        |
| `title()`      | 每个单词首字母大写                       | `"hello world".title()` → `"Hello World"` |
| `upper()`      | 全部转为大写                             | `"hello".upper()` → `"HELLO"`             |
| `lower()`      | 全部转为小写                             | `"HELLO".lower()` → `"hello"`             |
| `swapcase()`   | 大小写互换                               | `"Hello".swapcase()` → `"hELLO"`          |
| `casefold()`   | 更强大的小写转换（用于不区分大小写比较） | `"ß".casefold()` → `"ss"`                 |

python

```
# 示例
text = "hello world"
print(text.capitalize())  # "Hello world"
print(text.title())       # "Hello World"
print(text.upper())       # "HELLO WORLD"

# casefold 与 lower 的区别
print("ß".lower())        # "ß"  (德语尖锐s)
print("ß".casefold())     # "ss" (用于比较时更准确)
```



------

## 二、查找与统计（7个方法）

| 方法                             | 说明                                    | 示例                                |
| :------------------------------- | :-------------------------------------- | :---------------------------------- |
| `find(sub, start, end)`          | 查找子串第一次出现的位置，找不到返回 -1 | `"hello".find("l")` → `2`           |
| `rfind(sub, start, end)`         | 从右向左查找，找不到返回 -1             | `"hello".rfind("l")` → `3`          |
| `index(sub, start, end)`         | 查找子串，找不到报错 `ValueError`       | `"hello".index("l")` → `2`          |
| `rindex(sub, start, end)`        | 从右向左查找，找不到报错                | `"hello".rindex("l")` → `3`         |
| `count(sub, start, end)`         | 统计子串出现次数                        | `"hello".count("l")` → `2`          |
| `startswith(prefix, start, end)` | 是否以指定前缀开头                      | `"hello".startswith("he")` → `True` |
| `endswith(suffix, start, end)`   | 是否以指定后缀结尾                      | `"hello".endswith("lo")` → `True`   |

python

```
# 示例
text = "hello world"
print(text.find("l"))        # 2
print(text.find("x"))        # -1
print(text.index("l"))       # 2
# print(text.index("x"))     # ValueError
print(text.count("l"))       # 3
print(text.startswith("he")) # True
print(text.endswith("ld"))   # True

# 指定搜索范围
print(text.find("l", 3, 7))  # 从索引3到7之间查找 → 3
```



------

## 三、判断类型（9个方法）

| 方法          | 说明                                   | 示例                               |
| :------------ | :------------------------------------- | :--------------------------------- |
| `isalpha()`   | 是否全是字母（含中文）                 | `"Hello".isalpha()` → `True`       |
| `isdigit()`   | 是否全是数字                           | `"123".isdigit()` → `True`         |
| `isalnum()`   | 是否全是字母或数字                     | `"Hello123".isalnum()` → `True`    |
| `isdecimal()` | 是否全是十进制数字                     | `"123".isdecimal()` → `True`       |
| `isnumeric()` | 是否全是数字（含中文数字）             | `"一二三".isnumeric()` → `True`    |
| `isspace()`   | 是否全是空白字符（空格、换行等）       | `" \n".isspace()` → `True`         |
| `islower()`   | 是否全是小写                           | `"hello".islower()` → `True`       |
| `isupper()`   | 是否全是大写                           | `"HELLO".isupper()` → `True`       |
| `istitle()`   | 是否符合标题格式（每个单词首字母大写） | `"Hello World".istitle()` → `True` |

python

```
# 示例
print("Hello123".isalnum())   # True
print("123".isdigit())        # True
print("一二三".isdigit())      # False
print("一二三".isnumeric())    # True
print("  ".isspace())         # True
print("Hello World".istitle()) # True

# isalpha vs isalnum
print("Hello".isalpha())      # True (纯字母)
print("Hello123".isalpha())   # False (包含数字)
print("Hello123".isalnum())   # True (字母或数字)
```



------

## 四、填充与对齐（5个方法）

| 方法                      | 说明                       | 示例                              |
| :------------------------ | :------------------------- | :-------------------------------- |
| `center(width, fillchar)` | 居中对齐，用指定字符填充   | `"hi".center(5, "*")` → `"*hi**"` |
| `ljust(width, fillchar)`  | 左对齐                     | `"hi".ljust(4, "*")` → `"hi**"`   |
| `rjust(width, fillchar)`  | 右对齐                     | `"hi".rjust(4, "*")` → `"**hi"`   |
| `zfill(width)`            | 右侧填充0（常用于数字补0） | `"42".zfill(5)` → `"00042"`       |
| `expandtabs(tabsize)`     | 将制表符替换为空格         | `"a\tb".expandtabs(4)` → `"a b"`  |

python

```
# 示例
print("Python".center(10, "*"))   # "**Python**"
print("Python".ljust(10, "*"))    # "Python****"
print("Python".rjust(10, "*"))    # "****Python"
print("42".zfill(5))              # "00042"
print("-42".zfill(5))             # "-0042"  (负号保留在最前面)
```



------

## 五、去除空白（3个方法）

| 方法            | 说明                             | 示例                            |
| :-------------- | :------------------------------- | :------------------------------ |
| `strip(chars)`  | 去除两端指定字符（默认去除空白） | `" hello ".strip()` → `"hello"` |
| `lstrip(chars)` | 去除左侧指定字符                 | `" hello".lstrip()` → `"hello"` |
| `rstrip(chars)` | 去除右侧指定字符                 | `"hello ".rstrip()` → `"hello"` |

python

```
# 示例
text = "  hello world  "
print(text.strip())    # "hello world"
print(text.lstrip())   # "hello world  "
print(text.rstrip())   # "  hello world"

# 去除指定字符
text = "***hello***"
print(text.strip("*"))   # "hello"
print(text.lstrip("*"))  # "hello***"
print(text.rstrip("*"))  # "***hello"

# 去除多个字符
text = "  \t hello \n  "
print(text.strip())      # "hello"

# 去除指定多个字符
text = "abchelloabc"
print(text.strip("abc"))  # "hello"
```



------

## 六、分割与合并（6个方法）

| 方法                    | 说明                                   | 示例                                            |
| :---------------------- | :------------------------------------- | :---------------------------------------------- |
| `split(sep, maxsplit)`  | 按分隔符分割成列表（默认按空白分割）   | `"a,b,c".split(",")` → `['a','b','c']`          |
| `rsplit(sep, maxsplit)` | 从右向左分割                           | `"a,b,c".rsplit(",", 1)` → `['a,b', 'c']`       |
| `splitlines(keepends)`  | 按行分割成列表                         | `"a\nb".splitlines()` → `['a','b']`             |
| `partition(sep)`        | 分成三部分：分隔符前、分隔符、分隔符后 | `"a,b,c".partition(",")` → `('a', ',', 'b,c')`  |
| `rpartition(sep)`       | 从右向左分割成三部分                   | `"a,b,c".rpartition(",")` → `('a,b', ',', 'c')` |
| `join(iterable)`        | 用字符串连接可迭代对象（重要！）       | `",".join(['a','b'])` → `"a,b"`                 |

python

```
# 示例 - split
text = "apple,banana,orange"
print(text.split(","))           # ['apple', 'banana', 'orange']
print(text.split(",", 1))        # ['apple', 'banana,orange'] (最多分割1次)

# 默认按空白分割
text = "hello world python"
print(text.split())              # ['hello', 'world', 'python']

# splitlines
text = "line1\nline2\nline3"
print(text.splitlines())         # ['line1', 'line2', 'line3']
print(text.splitlines(True))     # ['line1\n', 'line2\n', 'line3'] (保留换行符)

# partition
print("a,b,c".partition(","))    # ('a', ',', 'b,c')
print("a,b,c".rpartition(","))   # ('a,b', ',', 'c')

# join (重要！)
print("-".join(['2026', '08', '12']))  # "2026-08-12"
print("".join(['H', 'e', 'l', 'l', 'o'])) # "Hello"
```



------

## 七、替换与修改（6个方法）

| 方法                       | 说明                 | 示例                                    |
| :------------------------- | :------------------- | :-------------------------------------- |
| `replace(old, new, count)` | 替换子串（指定次数） | `"hello".replace("l", "x")` → `"hexxo"` |
| `translate(table)`         | 根据映射表替换字符   | 见下方示例                              |
| `maketrans(x, y, z)`       | 创建翻译映射表       | 配合 `translate()` 使用                 |
| `lstrip()`                 | 见第五部分           | -                                       |
| `rstrip()`                 | 见第五部分           | -                                       |
| `strip()`                  | 见第五部分           | -                                       |

python

```
# replace
text = "hello world"
print(text.replace("l", "x"))       # "hexxo worxd"
print(text.replace("l", "x", 1))    # "hexlo world" (只替换第一个)

# translate + maketrans
text = "hello"
# 创建映射表：h→H, e→E, l→L
table = str.maketrans("hel", "HEL")
print(text.translate(table))        # "HELLo"

# 删除字符（第三个参数指定删除的字符）
table = str.maketrans("", "", "aeiou")  # 删除所有元音
print("hello world".translate(table))   # "hll wrld"
```



------

## 八、格式化（4个方法）

| 方法                      | 说明                           | 示例                                    |
| :------------------------ | :----------------------------- | :-------------------------------------- |
| `format(*args, **kwargs)` | 格式化字符串                   | `"{} {}".format("Hello", "World")`      |
| `f-string`                | Python 3.6+ 格式化（不是方法） | `f"{name}"`                             |
| `%` 操作符                | 旧式格式化（不是方法）         | `"%s %s" % ("Hello", "World")`          |
| `format_map(mapping)`     | 用字典格式化                   | `"{name}".format_map({'name':'Alice'})` |

python

```
# format
print("{} {}".format("Hello", "World"))  # "Hello World"
print("{1} {0}".format("World", "Hello")) # "Hello World"
print("{name} is {age}岁".format(name="Alice", age=18))

# format_map
data = {'name': 'Alice', 'age': 18}
print("{name} is {age}岁".format_map(data))  # "Alice is 18岁"

# f-string (Python 3.6+，推荐)
name = "Alice"
age = 18
print(f"{name} is {age}岁")  # "Alice is 18岁"
```



------

## 九、编码与解码（3个方法）

| 方法                       | 说明                                 | 示例                            |
| :------------------------- | :----------------------------------- | :------------------------------ |
| `encode(encoding, errors)` | 字符串编码为字节                     | `"hello".encode()` → `b'hello'` |
| `decode(encoding, errors)` | 字节解码为字符串（字符串没有此方法） | `b'hello'.decode()` → `"hello"` |

python

```
# encode
text = "hello 世界"
print(text.encode())              # b'hello \xe4\xb8\x96\xe7\x95\x8c'
print(text.encode('gbk'))         # b'hello \xca\xc0\xbd\xe7'

# 字符串没有 decode 方法
# "hello".decode()  # ❌ 报错！

# 使用 bytes 对象解码
b = b'hello'
print(b.decode())                 # "hello"
```



------

## 十、其他实用方法（4个方法）

| 方法        | 说明                       | 示例                                        |
| :---------- | :------------------------- | :------------------------------------------ |
| `len()`     | 获取字符串长度（内置函数） | `len("hello")` → `5`                        |
| `in` 运算符 | 检查子串是否存在           | `"h" in "hello"` → `True`                   |
| `join()`    | 见第六部分                 | -                                           |
| `sorted()`  | 对字符串字符排序           | `sorted("hello")` → `['e','h','l','l','o']` |

python

```
# 长度
print(len("hello"))          # 5

# 成员检查
print("h" in "hello")        # True
print("x" not in "hello")    # True

# 排序
print(sorted("hello"))       # ['e', 'h', 'l', 'l', 'o']

# 字符串反转（Python的切片技巧）
print("hello"[::-1])         # "olleh"
```



------

## 十一、完整方法速查表

python

```
# 按字母排序的所有字符串方法
str.capitalize()       # 首字母大写
str.casefold()         # 小写转换（用于比较）
str.center()           # 居中对齐
str.count()            # 统计子串出现次数
str.encode()           # 编码为字节
str.endswith()         # 判断结尾
str.expandtabs()       # 扩展制表符
str.find()             # 查找子串（左到右）
str.format()           # 格式化
str.format_map()       # 用字典格式化
str.index()            # 查找子串（找不到报错）
str.isalnum()          # 是否字母或数字
str.isalpha()          # 是否全是字母
str.isascii()          # 是否全是 ASCII
str.isdecimal()        # 是否十进制数字
str.isdigit()          # 是否全是数字
str.isidentifier()     # 是否合法标识符
str.islower()          # 是否全小写
str.isnumeric()        # 是否全是数字（含中文）
str.isprintable()      # 是否可打印
str.isspace()          # 是否全是空白
str.istitle()          # 是否符合标题格式
str.isupper()          # 是否全大写
str.join()             # 连接序列
str.ljust()            # 左对齐
str.lower()            # 转小写
str.lstrip()           # 去除左侧字符
str.maketrans()        # 创建翻译表
str.partition()        # 分割成三部分（左）
str.removeprefix()     # 删除前缀 (Python 3.9+)
str.removesuffix()     # 删除后缀 (Python 3.9+)
str.replace()          # 替换子串
str.rfind()            # 查找子串（右到左）
str.rindex()           # 查找子串（右到左，报错）
str.rjust()            # 右对齐
str.rpartition()       # 分割成三部分（右）
str.rsplit()           # 从右分割
str.rstrip()           # 去除右侧字符
str.split()            # 分割成列表
str.splitlines()       # 按行分割
str.startswith()       # 判断开头
str.strip()            # 去除两端字符
str.swapcase()         # 大小写互换
str.title()            # 标题格式
str.translate()        # 翻译替换
str.upper()            # 转大写
str.zfill()            # 补零填充
```



------

## 十二、常用技巧与最佳实践

### 1. 字符串是不可变的

python

```
# ❌ 错误：不能直接修改字符串
s = "hello"
# s[0] = "H"  # TypeError

# ✅ 正确：创建新字符串
s = "H" + s[1:]  # "Hello"
```



### 2. 拼接字符串的性能

python

```
# ❌ 不推荐：大量拼接用 + 会创建很多临时对象
result = ""
for s in ["a", "b", "c"]:
    result += s  # 每次创建新字符串

# ✅ 推荐：用 join
result = "".join(["a", "b", "c"])
```



### 3. 判断字符串是否为空

python

```
s = ""
if not s:          # ✅ 推荐
    print("空字符串")
if len(s) == 0:    # 也可以用，但不够 Pythonic
    print("空字符串")
```



### 4. 去除换行符

python

```
line = "hello\n"
print(line.strip())        # "hello"（同时去除空白）
print(line.rstrip("\n"))   # "hello"（只去除换行）
```



### 5. 分割文件名和扩展名

python

```
filename = "image.jpg"
name, ext = filename.split(".")
print(name)  # "image"
print(ext)   # "jpg"
```