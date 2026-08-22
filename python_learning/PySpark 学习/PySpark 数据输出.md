# PySpark 数据输出

## 将 RDD 转换为 python 对象 

### collect 算子

功能: 将 RDD 各个分区内的数据, 统一收集到Driver 中, 形成一个 LIst 对象

用法: 

```python
rdd.collect()
```

返回值是一个 列表 

```python
from pyspark.sql import SparkSession
spark = SparkSession.builder.master("local").appName("SparkName").getOrCreate()
sc = spark.sparkContext

rdd = sc.parallelize((('a', 1), ('b', 3), ('c', 9), ('d', 7), ('e', 5)))
rdd2 = rdd.sortBy(lambda x: x[1], ascending=False, numPartitions=3)
print(rdd2.collect()) # [('c', 9), ('d', 7), ('e', 5), ('b', 3), ('a', 1)]
```

### reduce 算子

功能: 对RDD对象根据传入的逻辑进行聚合

语法: 

```python
rdd.reduce(func) 
# func: (T, T) -> T
# 传入 2 个参数, 1 个返回值, 返回值和参数要求类型一致
```





