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



