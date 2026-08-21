# RDD对象 与 PySpark 数据输入

PySpark 支持多种数据的输入, 在输入完成后, 都会得到以一个: RDD 对象 

RDD 全称为: 弹性分布式数据集 (Resilient Distributed Datasets) 

PySpark 针对数据的处理, 都是以 RDD 对象作为载体, 即: 

+ 数据存储在RDD 内
+ 各类数据的计算方法, 也都是 RDD 的成员方法
+ RDD 的数据计算方法, 返回值依旧是 RDD 对象

## python 数据容器转 RDD 对象

PySpark 支持通过 SparkContext 对象的paralelize 成员方法, 将 list, tuple, set, dict, str 转换为 PySpark 的RDD 对象 

```python
from pyspark import SparkConf, SparkContext

conf = SparkConf().setmaster("local").setappName("test_saprk_app")

sc = SparkContext(conf=conf) 

rdd = sc.parallelize(数据容器对象) 

# 输出RDD内容
print(rdd.collect())
```

注意: 

+ 字符串会被差分出 1 个个的字符串存入 RDD 对象
+ 字典仅有 key 会被存入 RDD 对象 

如果要查看RDD 中的内容, 需要用 `collect()` 方法

```python
from pyspark import SparkContext, SparkConf

conf = SparkConf().setMaster("local").setAppName("test_spark_App")

sc = SparkContext(conf = conf)

rdd1 = sc.parallelize([1, 2, 3, 4, 5, 'list'])
rdd2 = sc.parallelize((1, 2, 3, 5, 6, 'tuple'))
rdd3 = sc.parallelize("string")
rdd4 = sc.parallelize({1, 2, 3, 4, "set"})
rdd5 = sc.parallelize({1 : 23, 3: 3232, 'dict': 2})

print(rdd1.collect())
print(rdd2.collect())
print(rdd3.collect())
print(rdd4.collect())
print(rdd5.collect())
```

输出: 

```python
[1, 2, 3, 4, 5, 'list']
[1, 2, 3, 5, 6, 'tuple']
['s', 't', 'r', 'i', 'n', 'g']
[1, 2, 3, 4, 'set']
[1, 3, 'dict']
```

## 读取文件转RDD对象

PySark 也支持通过SparkContext 入口对象, 来读取文件, 来构建出RDD对象



```python
from pyspark import SparkConf, SparkContext

conf = SparkConf().setMaster("local").setAppName("PySpark_test_App")

sc = SparkContext(conf = conf)

rdd = sc.textFile("D:/code/hello.c")

print(rdd.collect()) # ['#include<stdio.h> ', 'int main() {', '    printf("hello"); ', '    return 0; ', '}']
```

