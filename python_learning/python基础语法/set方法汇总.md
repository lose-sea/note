## Python 集合（Set）所有方法汇总

集合是**无序、可变、元素唯一**的数据结构，专门用于**去重和集合运算**。我按功能分类整理如下：

------

## 一、集合方法速览（共 15 个）

| 分类         | 方法                            | 说明                         |
| :----------- | :------------------------------ | :--------------------------- |
| **添加**     | `add()`                         | 添加一个元素                 |
|              | `update()`                      | 添加多个元素（合并）         |
| **删除**     | `remove()`                      | 删除指定元素（不存在报错）   |
|              | `discard()`                     | 删除指定元素（不存在不报错） |
|              | `pop()`                         | 随机删除并返回一个元素       |
|              | `clear()`                       | 清空集合                     |
| **集合运算** | `union()` / `|`                 | 并集                         |
|              | `intersection()` / `&`          | 交集                         |
|              | `difference()` / `-`            | 差集                         |
|              | `symmetric_difference()` / `^`  | 对称差集                     |
| **判断**     | `issubset()` / `<=`             | 子集                         |
|              | `issuperset()` / `>=`           | 超集                         |
|              | `isdisjoint()`                  | 是否不相交（无交集）         |
| **更新**     | `intersection_update()`         | 更新为交集                   |
|              | `difference_update()`           | 更新为差集                   |
|              | `symmetric_difference_update()` | 更新为对称差集               |

------

## 二、添加元素（2个方法）

### 1. `add(x)` - 添加单个元素

python

```
s = {1, 2, 3}
s.add(4)
print(s)  # {1, 2, 3, 4}

# 添加已存在的元素不会报错，但不会变化
s.add(2)
print(s)  # {1, 2, 3, 4}

# 只能添加可哈希的元素（不可变对象）
s.add((5, 6))  # ✅ 元组可以
# s.add([5, 6])  # ❌ 列表不可以，TypeError
```



### 2. `update(iterable)` - 添加多个元素

python

```
# 用列表更新
s = {1, 2, 3}
s.update([4, 5, 6])
print(s)  # {1, 2, 3, 4, 5, 6}

# 用元组更新
s.update((7, 8))
print(s)  # {1, 2, 3, 4, 5, 6, 7, 8}

# 用另一个集合更新
s.update({9, 10})
print(s)  # {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}

# 用字符串更新（会拆分成单个字符）
s = {'a', 'b'}
s.update('cd')
print(s)  # {'a', 'b', 'c', 'd'}

# update 等同于 |=
s = {1, 2}
s |= {3, 4}
print(s)  # {1, 2, 3, 4}
```



------

## 三、删除元素（4个方法）

### 1. `remove(x)` - 删除指定元素（不存在报错）

python

```
s = {1, 2, 3, 4}
s.remove(2)
print(s)  # {1, 3, 4}

# ❌ 删除不存在的元素会报错
# s.remove(9)  # KeyError: 9

# ✅ 安全做法
if 9 in s:
    s.remove(9)
```



### 2. `discard(x)` - 删除指定元素（不存在不报错）

python

```
s = {1, 2, 3, 4}
s.discard(2)
print(s)  # {1, 3, 4}

# ✅ 删除不存在的元素不会报错
s.discard(9)  # 安全，什么都不发生
print(s)      # {1, 3, 4}
```



**区别对比：**

python

```
s = {1, 2, 3}
s.remove(9)   # ❌ KeyError
s.discard(9)  # ✅ 不报错，安全

# 推荐：如果确定元素存在用 remove，不确定用 discard
```



### 3. `pop()` - 随机删除并返回一个元素

python

```
s = {1, 2, 3, 4, 5}
removed = s.pop()
print(removed)  # 随机一个元素（不确定）
print(s)        # 剩下的元素

# 对空集合使用 pop 会报错
# s = set()
# s.pop()  # KeyError: 'pop from an empty set'
```



### 4. `clear()` - 清空所有元素

python

```
s = {1, 2, 3, 4, 5}
s.clear()
print(s)  # set()
```



------

## 四、集合运算（4个核心方法）

### 1. `union()` / `|` - 并集

python

```
s1 = {1, 2, 3}
s2 = {3, 4, 5}

# 方法调用
result = s1.union(s2)
print(result)  # {1, 2, 3, 4, 5}

# 运算符
result = s1 | s2
print(result)  # {1, 2, 3, 4, 5}

# 合并多个集合
s3 = {5, 6, 7}
result = s1.union(s2, s3)
print(result)  # {1, 2, 3, 4, 5, 6, 7}
```



### 2. `intersection()` / `&` - 交集

python

```
s1 = {1, 2, 3, 4}
s2 = {3, 4, 5, 6}

# 方法调用
result = s1.intersection(s2)
print(result)  # {3, 4}

# 运算符
result = s1 & s2
print(result)  # {3, 4}

# 多个集合交集
s3 = {4, 5, 6, 7}
result = s1.intersection(s2, s3)
print(result)  # {4}
```



### 3. `difference()` / `-` - 差集

python

```
s1 = {1, 2, 3, 4}
s2 = {3, 4, 5, 6}

# 方法调用
result = s1.difference(s2)  # 在 s1 但不在 s2
print(result)  # {1, 2}

# 运算符
result = s1 - s2
print(result)  # {1, 2}

# 多个集合差集
s3 = {2, 3, 4}
result = s1.difference(s2, s3)
print(result)  # {1}
```



### 4. `symmetric_difference()` / `^` - 对称差集

python

```
s1 = {1, 2, 3, 4}
s2 = {3, 4, 5, 6}

# 方法调用
result = s1.symmetric_difference(s2)
print(result)  # {1, 2, 5, 6} (在 s1 或 s2 但不同时在两者中)

# 运算符
result = s1 ^ s2
print(result)  # {1, 2, 5, 6}
```



------

## 五、更新运算（3个方法）

这些方法**直接修改原集合**，不返回新集合。

### 1. `intersection_update()` - 更新为交集

python

```
s1 = {1, 2, 3, 4}
s2 = {3, 4, 5, 6}

s1.intersection_update(s2)
print(s1)  # {3, 4}  (s1 被修改)
```



### 2. `difference_update()` - 更新为差集

python

```
s1 = {1, 2, 3, 4}
s2 = {3, 4, 5, 6}

s1.difference_update(s2)
print(s1)  # {1, 2}  (s1 被修改)
```



### 3. `symmetric_difference_update()` - 更新为对称差集

python

```
s1 = {1, 2, 3, 4}
s2 = {3, 4, 5, 6}

s1.symmetric_difference_update(s2)
print(s1)  # {1, 2, 5, 6}  (s1 被修改)
```



------

## 六、判断方法（3个方法）

### 1. `issubset()` / `<=` / `<` - 子集判断

python

```
s1 = {1, 2, 3}
s2 = {1, 2, 3, 4, 5}

print(s1.issubset(s2))  # True (s1 是 s2 的子集)
print(s1 <= s2)          # True
print(s1 < s2)           # True (真子集)

print(s1.issubset({1, 2, 3}))  # True
print(s1 <= {1, 2, 3})         # True
print(s1 < {1, 2, 3})          # False (不是真子集)
```



### 2. `issuperset()` / `>=` / `>` - 超集判断

python

```
s1 = {1, 2, 3, 4, 5}
s2 = {1, 2, 3}

print(s1.issuperset(s2))  # True (s1 是 s2 的超集)
print(s1 >= s2)           # True
print(s1 > s2)            # True (真超集)

print(s1.issuperset({1, 2, 3, 4, 5}))  # True
print(s1 >= {1, 2, 3, 4, 5})          # True
print(s1 > {1, 2, 3, 4, 5})           # False (不是真超集)
```



### 3. `isdisjoint()` - 判断是否不相交（无交集）

python

```
s1 = {1, 2, 3}
s2 = {4, 5, 6}
s3 = {3, 4, 5}

print(s1.isdisjoint(s2))  # True (完全没有相同元素)
print(s1.isdisjoint(s3))  # False (有共同元素 3)
```



------

## 七、其他常用操作

### 1. 复制 - `copy()`

python

```
s = {1, 2, 3}
copy_s = s.copy()
print(copy_s)  # {1, 2, 3}

# 赋值 vs 复制
s2 = s          # 引用同一个对象
s3 = s.copy()   # 创建新对象

s.add(4)
print(s)        # {1, 2, 3, 4}
print(s2)       # {1, 2, 3, 4} (被影响)
print(s3)       # {1, 2, 3} (不受影响)
```



### 2. 获取长度 - `len()`

python

```
s = {1, 2, 3, 4, 5}
print(len(s))  # 5
```



### 3. 成员检查 - `in` / `not in`

python

```
s = {1, 2, 3, 4, 5}
print(3 in s)      # True
print(6 in s)      # False
print(6 not in s)  # True
```