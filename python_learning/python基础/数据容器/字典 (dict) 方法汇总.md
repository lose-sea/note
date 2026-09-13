## Python 字典（Dictionary）所有方法汇总

字典是 **键值对（key-value）** 数据结构，键必须唯一且不可变，值可以是任意类型。我按功能分类整理如下：

------

## 一、字典方法速览（共 11 个）

| 分类     | 方法           | 说明                           |
| :------- | :------------- | :----------------------------- |
| **获取** | `get()`        | 安全获取值（不存在返回默认值） |
|          | `setdefault()` | 获取值，键不存在则设置默认值   |
|          | `keys()`       | 返回所有键的视图               |
|          | `values()`     | 返回所有值的视图               |
|          | `items()`      | 返回所有键值对的视图           |
| **修改** | `update()`     | 合并另一个字典                 |
|          | `pop()`        | 删除并返回指定键的值           |
|          | `popitem()`    | 删除并返回最后一个键值对       |
|          | `clear()`      | 清空字典                       |
| **复制** | `copy()`       | 浅拷贝                         |
| **特殊** | `fromkeys()`   | 从序列创建字典（类方法）       |

------

## 二、获取元素（5个方法）

### 1. `get(key, default)` - 安全获取值



```
# 基本用法
d = {'name': 'Alice', 'age': 25}

print(d.get('name'))        # 'Alice'
print(d.get('city'))        # None (键不存在返回 None)
print(d.get('city', 'Beijing'))  # 'Beijing' (自定义默认值)

# 对比直接访问
# print(d['city'])          # KeyError
print(d.get('city'))        # 返回 None

# 应用场景
count = {}
words = ['apple', 'banana', 'apple', 'orange']
for word in words:
    count[word] = count.get(word, 0) + 1
print(count)  # {'apple': 2, 'banana': 1, 'orange': 1}
```



### 2. `setdefault(key, default)` - 获取或设置



```
# 基本用法
d = {'name': 'Alice'}

# 键存在：返回存在的值
value = d.setdefault('name', 'Bob')
print(value)   # 'Alice'
print(d)       # {'name': 'Alice'}

# 键不存在：设置并返回默认值
value = d.setdefault('age', 25)
print(value)   # 25
print(d)       # {'name': 'Alice', 'age': 25}

# 不指定默认值，默认为 None
d.setdefault('city')
print(d)       # {'name': 'Alice', 'age': 25, 'city': None}
```



**get() vs setdefault() 对比：**



```
d = {'a': 1, 'b': 2}

# get：只获取，不修改字典
value = d.get('c', 3)
print(value)  # 3
print(d)      # {'a': 1, 'b': 2}  ← 字典未修改

# setdefault：获取并可能修改字典
value = d.setdefault('c', 3)
print(value)  # 3
print(d)      # {'a': 1, 'b': 2, 'c': 3}  ← 字典被修改
```



### 3. `keys()` - 获取所有键



```
d = {'name': 'Alice', 'age': 25, 'city': 'Beijing'}

# 返回视图对象（动态，随原字典变化）
keys = d.keys()
print(keys)  # dict_keys(['name', 'age', 'city'])

# 遍历键
for key in d.keys():
    print(key, d[key])

# 转为列表
keys_list = list(d.keys())
print(keys_list)  # ['name', 'age', 'city']

# 视图是动态的
d['country'] = 'China'
print(keys)  # dict_keys(['name', 'age', 'city', 'country'])  ← 自动更新
```



### 4. `values()` - 获取所有值



```
d = {'name': 'Alice', 'age': 25, 'city': 'Beijing'}

# 返回视图对象
values = d.values()
print(values)  # dict_values(['Alice', 25, 'Beijing'])

# 遍历值
for value in d.values():
    print(value)

# 转为列表
values_list = list(d.values())
print(values_list)  # ['Alice', 25, 'Beijing']

# 去重（统计不同值）
unique_values = set(d.values())
```



### 5. `items()` - 获取所有键值对



```
d = {'name': 'Alice', 'age': 25}

# 返回视图对象（元组列表）
items = d.items()
print(items)  # dict_items([('name', 'Alice'), ('age', 25)])

# 最常用：遍历键值对
for key, value in d.items():
    print(f"{key}: {value}")

# 转为列表
items_list = list(d.items())
print(items_list)  # [('name', 'Alice'), ('age', 25)]

# 解包
for key, value in d.items():
    print(key, value)
```



**keys() / values() / items() 对比：**

| 方法       | 返回       | 用途       | 示例                    |
| :--------- | :--------- | :--------- | :---------------------- |
| `keys()`   | 所有键     | 遍历键     | `for k in d.keys()`     |
| `values()` | 所有值     | 遍历值     | `for v in d.values()`   |
| `items()`  | 所有键值对 | 遍历键和值 | `for k, v in d.items()` |

------

## 三、修改元素（3个方法）

### 1. `update(other)` - 合并字典



```
# 合并另一个字典
d1 = {'a': 1, 'b': 2}
d2 = {'b': 3, 'c': 4}
d1.update(d2)
print(d1)  # {'a': 1, 'b': 3, 'c': 4}  ← 相同的键被覆盖

# 使用键值对列表
d = {'a': 1}
d.update([('b', 2), ('c', 3)])
print(d)  # {'a': 1, 'b': 2, 'c': 3}

# 使用关键字参数
d = {'a': 1}
d.update(b=2, c=3)
print(d)  # {'a': 1, 'b': 2, 'c': 3}

# update 等同于
d = {'a': 1, 'b': 2}
d |= {'b': 3, 'c': 4}  # Python 3.9+ 合并运算符
print(d)  # {'a': 1, 'b': 3, 'c': 4}

# 合并多个（Python 3.9+）
d1 = {'a': 1}
d2 = {'b': 2}
d3 = {'c': 3}
merged = d1 | d2 | d3
print(merged)  # {'a': 1, 'b': 2, 'c': 3}
```



### 2. `pop(key, default)` - 删除并返回值



```
d = {'name': 'Alice', 'age': 25, 'city': 'Beijing'}

# 删除指定键并返回值
removed = d.pop('age')
print(removed)  # 25
print(d)        # {'name': 'Alice', 'city': 'Beijing'}

# 删除不存在的键会报错
# d.pop('country')  #  KeyError

# 指定默认值，不存在返回默认值
removed = d.pop('country', 'China')
print(removed)  # 'China'
print(d)        # {'name': 'Alice', 'city': 'Beijing'}

# 删除并检查是否存在
value = d.pop('city', None)
if value:
    print(f"删除了: {value}")
```



### 3. `popitem()` - 删除并返回最后一个键值对



```
d = {'a': 1, 'b': 2, 'c': 3}

# Python 3.7+ 删除最后一个插入的键值对
key, value = d.popitem()
print(key, value)  # 'c', 3
print(d)           # {'a': 1, 'b': 2}

key, value = d.popitem()
print(key, value)  # 'b', 2
print(d)           # {'a': 1}

# Python 3.6 及以前是随机删除

# 空字典调用会报错
# d = {}
# d.popitem()  # ❌ KeyError: 'popitem(): dictionary is empty'
```



### 4. `clear()` - 清空字典



```
d = {'a': 1, 'b': 2, 'c': 3}
d.clear()
print(d)  # {}
```



------

## 四、复制字典（1个方法）

### `copy()` - 浅拷贝



```
# 基本用法
d = {'name': 'Alice', 'age': 25}
copy_d = d.copy()
print(copy_d)  # {'name': 'Alice', 'age': 25}

# 修改拷贝不影响原字典
copy_d['age'] = 30
print(d)       # {'name': 'Alice', 'age': 25}
print(copy_d)  # {'name': 'Alice', 'age': 30}

# 浅拷贝的陷阱：嵌套字典
d = {'name': 'Alice', 'info': {'age': 25, 'city': 'Beijing'}}
copy_d = d.copy()
copy_d['info']['age'] = 30
print(d)  # {'name': 'Alice', 'info': {'age': 30, 'city': 'Beijing'}}  ← 被修改！

# 深拷贝（完全独立）
import copy
deep_copy = copy.deepcopy(d)
deep_copy['info']['age'] = 40
print(d)  # {'name': 'Alice', 'info': {'age': 30, 'city': 'Beijing'}}  ← 不变
```



------

## 五、特殊方法（1个）

### `fromkeys(seq, value)` - 从序列创建字典（类方法）



```
# 从列表创建
keys = ['a', 'b', 'c']
d = dict.fromkeys(keys)
print(d)  # {'a': None, 'b': None, 'c': None}

# 指定默认值
d = dict.fromkeys(keys, 0)
print(d)  # {'a': 0, 'b': 0, 'c': 0}

# 从字符串创建
d = dict.fromkeys('abc', 1)
print(d)  # {'a': 1, 'b': 1, 'c': 1}

#  警告：使用可变对象作为默认值
keys = ['a', 'b', 'c']
d = dict.fromkeys(keys, [])  # 所有键共享同一个列表
d['a'].append(1)
print(d)  # {'a': [1], 'b': [1], 'c': [1]}  ← 所有值都被修改！

#  正确做法：使用字典推导式
d = {key: [] for key in keys}
d['a'].append(1)
print(d)  # {'a': [1], 'b': [], 'c': []}
```



------

## 六、其他常用操作（虽然不是方法，但很常用）

### 1. 直接访问 - `[]` 和赋值



```
d = {'name': 'Alice', 'age': 25}

# 访问（键不存在会报错）
print(d['name'])  # 'Alice'
# print(d['city'])  # ❌ KeyError

# 赋值
d['city'] = 'Beijing'   # 键不存在 → 添加
d['age'] = 26           # 键存在 → 修改
print(d)  # {'name': 'Alice', 'age': 26, 'city': 'Beijing'}
```



### 2. `in` 和 `not in` - 成员检查



```
d = {'name': 'Alice', 'age': 25}

print('name' in d)      # True
print('city' in d)      # False
print('Alice' in d)     # False (检查的是键，不是值)
print('Alice' in d.values())  # True (检查值)
```



### 3. `len()` - 获取键值对数量



```python
d = {'a': 1, 'b': 2, 'c': 3}
print(len(d))  # 3
```



### 4. `del` - 删除键值对



```python
d = {'a': 1, 'b': 2, 'c': 3}
del d['b']
print(d)  # {'a': 1, 'c': 3}

# 删除不存在的键会报错
# del d['x']  #  KeyError
```



------

## 七、完整示例



```python
# 创建字典
d = {'name': 'Alice', 'age': 25}

# 获取
print(d.get('name'))       # 'Alice'
print(d.get('city', 'BJ')) # 'BJ'
print(d.setdefault('city', 'BJ'))  # 'BJ' (并设置)
print(d.keys())            # dict_keys(['name', 'age', 'city'])
print(d.values())          # dict_values(['Alice', 25, 'BJ'])
print(d.items())           # dict_items([('name', 'Alice'), ('age', 25), ('city', 'BJ')])

# 修改
d.update({'age': 26, 'country': 'China'})
print(d)  # {'name': 'Alice', 'age': 26, 'city': 'BJ', 'country': 'China'}

removed = d.pop('age')
print(removed)  # 26
print(d)        # {'name': 'Alice', 'city': 'BJ', 'country': 'China'}

key, value = d.popitem()
print(key, value)  # 'country', 'China'
print(d)           # {'name': 'Alice', 'city': 'BJ'}

# 复制
copy_d = d.copy()
copy_d['name'] = 'Bob'
print(d)       # {'name': 'Alice', 'city': 'BJ'}
print(copy_d)  # {'name': 'Bob', 'city': 'BJ'}

# 清空
d.clear()
print(d)  # {}

# fromkeys
d = dict.fromkeys(['a', 'b', 'c'], 0)
print(d)  # {'a': 0, 'b': 0, 'c': 0}
```



------

## 八、Python 3.9+ 新特性



```python
# 合并运算符 |
d1 = {'a': 1, 'b': 2}
d2 = {'b': 3, 'c': 4}
d3 = d1 | d2
print(d3)  # {'a': 1, 'b': 3, 'c': 4}

# 更新运算符 |=
d1 |= d2
print(d1)  # {'a': 1, 'b': 3, 'c': 4}
```



------

## 九、常见应用场景

### 1. 统计词频



```python
text = "hello world hello python world"
words = text.split()
freq = {}
for word in words:
    freq[word] = freq.get(word, 0) + 1
print(freq)  # {'hello': 2, 'world': 2, 'python': 1}
```



### 2. 分组



```python
# 按首字母分组
words = ['apple', 'banana', 'cherry', 'avocado', 'blueberry']
groups = {}
for word in words:
    first = word[0]
    groups.setdefault(first, []).append(word)
print(groups)
# {'a': ['apple', 'avocado'], 'b': ['banana', 'blueberry'], 'c': ['cherry']}
```



### 3. 缓存/记忆化



```
cache = {}
def fibonacci(n):
    if n in cache:
        return cache[n]
    if n <= 1:
        return n
    result = fibonacci(n-1) + fibonacci(n-2)
    cache[n] = result
    return result

print(fibonacci(10))  # 55
print(cache)          # {0: 0, 1: 1, 2: 1, 3: 2, ...}
```



### 4. 映射转换



```
# 状态码转描述
status_map = {
    200: 'OK',
    404: 'Not Found',
    500: 'Internal Server Error'
}
print(status_map.get(200, 'Unknown'))   # 'OK'
print(status_map.get(403, 'Unknown'))   # 'Unknown'
```