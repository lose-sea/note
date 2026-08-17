# json 格式 

## 什么是json

+ JSON 是一种轻量级的数据交互格式, 可以按照JSON指定的格式去组织和封装数据
+ JSON 本质上是一个带有特定格式的字符串 

### 主要功能

json 就是一种在各个编程语言中流通的数据格式, 负责不同编程语言中的数据传递和交换



各种编程语言存储数据的容器不尽相同, 在 Python 中有字典 dict 这样的数据类型, 而其他语言可能没有字典

为了让不同的语言都能够相互通用的互相传递数据, JSON 就是一种非常良好的数据格式. 

以python 和 C语言互传数据为例: 

![image-20260816022519984](C:\Users\Lenovo\AppData\Roaming\Typora\typora-user-images\image-20260816022519984.png)

# json 格式数据转化

json 格式的数据要求很严格

```python
 # json 格式可以是: 
{"name": "admin", "age": 19}
# 也可以是: 
[{"name": "admin", "age": 19}, {"name": "admin", "age": 19}]
```

在python语言中, python 和 json 格式是无缝切换的, json就是python的列表或者字典, **如果是列表, 就要求列表内部嵌套的是字典**, 

### python数据和JSON数据的相互转化

在python内置的json模块中, 在json模块中, 提供了两个方法可以完成python 数据和 json 数据的相互转化  

#### 导入json模块并准备符合json格式要求的python数据  

```python
import json
data = [{"name": "张三", "age": 19}, {"name": "admin", "age": 19}]
```



#### 通过json.dumps(data)方法将python数据转化为 json 数据

```python
jsondata = json.dumps(data)
print(jsondata) # [{"name": "\u5f20\u4e09", "age": 19}, {"name": "admin", "age": 19}]
print(type(jsondata)) # <class 'str'>
```

**json 本质上就是一个字符串 ** 

这里打印json数据中文变成了 `\u 5f20\u4e09`, 这是因为中文在转化的时候会涉及到一个编码问题, 要解决这个问题,只需要在传入参数的时候再传入一个参数 `ensure_ascll = False`, 表示不使用ASCll 去转换它, 而是直接输出 

```python
jsondata = json.dumps(data, ensure_ascii=False)
```

这样中文就可以正常打印了

#### 通过json.loads(jsondata) 方法将是json 数据转化为python 数据

```python
data = json.loads(jsondata)
```

