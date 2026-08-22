# PySpark数据计算 



PySpark 的数据计算, 都是基于RDD对象来进行的

RDD对象内置丰富的成员方法 (算子)

## map 方法

功能: map算子, 是将RDD的数据一条条处理, (处理的逻辑基于map算子中接收的处理函数), 返回新的RDD 

语法: 

```python
rdd.map(func)
# func :    f:(T) → U

```

>  f:  表示这是一个函数(方法)
>(T) → U 表示的是方法的定义:
> ()  表示传入参数,  (T) 表示 传入1个参数 , () 表示没有传入参数
> T 是泛型的代称, 在这里表示 任意类型
> U 也是泛型代称, 在这里表示 任意类型
>   
> → U  表示返回值
> 
> (T) → U 总结起来的意思是: 这是一个方法, 这个方法接受一个参数传入, 传入参数类型不限.  返回一个返回值, 返回值类型不限.
> 
> (A) → A 总结起来的意思是: 这是一个方法, 这个方法接受一个参数传入, 传入参数类型不限.  返回一个返回值, 返回值和传入参数类型一致
> 

例如: 

通过`map()` 方法将列表中每一个数字乘以 10 

```python
from pyspark import SparkConf, SparkContext

conf = SparkConf().setMaster("local").setAppName("PySpark_test")

sc = SparkContext(conf = conf)

rdd = sc.parallelize([1, 2, 3, 4, 5])

def func(data):
    return data * 10
# 通过map 方法将全部数据乘以 10
# rdd2 = rdd.map(func)

# 匿名函数
rdd2 = rdd.map(lambda x : x * 10)

print(rdd2.collect()) # [10, 20, 30, 40, 50]
```

## 链式调用

对于返回值是新的 RDD 的算子, 可以通过链式调用的方法多次调用算子

例如: 给列表中的数据乘以 10 再加上 5

```python
from pyspark import SparkConf, SparkContext

conf = SparkConf().setMaster("local").setAppName("PySpark_test")

sc = SparkContext(conf = conf)

rdd = sc.parallelize([1, 2, 3, 4, 5])

# 链式调用
# 给列表中的数据乘以 10 再加上 5
rdd2 = rdd.map(lambda x : x * 10).map(lambda x : x + 5)

print(rdd2.collect()) # [15, 25, 35, 45, 55]
```

## flatMap 方法

功能: 对 rdd 执行 map 操作, 然后进行接触嵌套操作 

什么是接触嵌套呢; 请看下面示例: 

```python
# 嵌套的list 
list = [[1, 2, 3], [4, 5, 6], [7, 8, 9]] 

# 解除了嵌套
list = [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

>  通过collect() 返回的是以一个 list

```python
from pyspark import SparkConf, SparkContext

conf = SparkConf().setMaster("local").setAppName("PySpark")

sc = SparkContext(conf = conf)

lst = ["hello world", "hello xinyan", "I am John"]

rdd = sc.parallelize(lst)
print(rdd.collect())

rdd2 = rdd.map(lambda x: x.split(" "))
print(rdd2.collect()) # [['hello', 'world'], ['hello', 'xinyan'], ['I', 'am', 'John']]

rdd3 = rdd.flatMap(lambda x: x.split(" "))
print(rdd3.collect()) # ['hello', 'world', 'hello', 'xinyan', 'I', 'am', 'John']
```

flatMap算子的计算逻辑和map一样, 只是比 map 多出了一层解除嵌套的逻辑 

## reduceByKey 算子 

功能: 针对KV型 RDD, 自动按照 key 分组, 然后根据提供的聚合逻辑, 完成 组内数据 (value) 的聚合操作

> KV 型RDD:  存储的数据是二元元组 (元组中的数据只有两个)

用法; 

```python
rdd.reduceByKey(func) 
# func: (v, v) -> v
# 接受两个参数(类型要求一致), 返回一个返回值, 类型和传入的参数类型要求一致
```



```python
from pyspark import SparkConf, SparkContext

conf = SparkConf().setMaster("local").setAppName("PySpark")

sc = SparkContext(conf = conf)

tuple1 = (('a', 1), ('b', 2), ('a', 3), ('b', 4))

rdd = sc.parallelize(tuple1)

rdd2 = rdd.flatMap(lambda x: x) # ['a', 1, 'b', 2, 'a', 3, 'b', 4]
print(rdd2.collect())

result = rdd.reduceByKey(lambda x, y: x + y)
print(result.collect()) # [('a', 4), ('b', 6)]
```

reduceByKey 中的聚合逻辑: 

例如: 有[1, 2, 3, 4, 5], 然后聚合函数是: `lambda a, b: a + b` 

![image-20260822160026381](C:\Users\Lenovo\AppData\Roaming\Typora\typora-user-images\image-20260822160026381.png)

## filter 方法 

功能: 过滤想要的数据进行保留 

语法: 

```python
rdd.filter(func) 
# func: (T) -> bool 传入一个任意类型参数, 返回值必须是一个True 或者 False
```

函数对 RDD 数据逐个处理, 得到 True 的保留至返回值的 RDD 中

返回True 的数据保留, 返回 False 的数据被丢弃



```python
from pyspark import SparkConf, SparkContext

conf = SparkConf().setMaster("local").setAppName("pySpark_test_App")
sc = SparkContext(conf = conf)

lst = [1, 2, 3, 4, 5]
rdd = sc.parallelize(lst)

rdd2 = rdd.filter(lambda x: x % 2 == 0)

print(rdd2.collect()) # [2, 4]
```



## distinct 方法

功能: 对RDD数据进行去重: 返回新的RDD 

语法: 

```python 
rdd.distinct() # 无需传参
```



```python
from pyspark import SparkConf, SparkContext

conf = SparkConf().setMaster("local").setAppName("pySpark_test_App")
sc = SparkContext(conf = conf)

lst = [1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 3, 3, 3, 4, 3, 2, 2, 2, 1]
rdd = sc.parallelize(lst)

rdd2 = rdd.distinct()

print(rdd2.collect()) # [1, 2, 3, 4, 5]
```

>  distinct 返回的顺序不一定严格`[1,2,3,4,5]`，RDD 是分布式，输出顺序不保证

## sortBy 方法

功能: 基于指定的排序依据对RDD数据进行排序

语法: 

```python
rdd.sortBy(func, ascending = False, numPartitions = 1) 
# func: (T) -> U: 告知按照rdd中的哪个数据进行排序, 比如 lambda x: x[1], 表示按照 rdd 中的第二个元素进行排序
# ascending  True升序, False降序
# numPartitions: 用多少区排序
```



```python
from pyspark.sql import SparkSession
spark = SparkSession.builder.master("local").appName("SparkName").getOrCreate()
sc = spark.sparkContext

rdd = sc.parallelize((('a', 1), ('b', 3), ('c', 9), ('d', 7), ('e', 5)))
rdd2 = rdd.sortBy(lambda x: x[1], ascending=False, numPartitions=1)
print(rdd2.collect()) # [('c', 9), ('d', 7), ('e', 5), ('b', 3), ('a', 1)]
```

全局排序需要设置分区数为 1
