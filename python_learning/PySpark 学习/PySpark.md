# PySpark

## 什么是pySpark

Spark 是 Apache 基金会旗下的顶级开源项目, 用于对海量数据进行大规模分布式计算 

PySpark 是Spark 的Python实现 ,是Spark 为python开发者提供的编程入口, 用于以Python 代码完成spark 任务的开发 

pyspark 不仅可以作为python第三方库使用, 也可以将程序提交到spark 集群环境中, 调度大规模集群进行执行 

## 构建PySpark 执行环境入口对象

想要使用PySpark库完成数据处理, 首先需要构建一个执行环境入口

PySpark 的执行入口对象是: 类SparkContex: 的类对象

```python
# 导包
from pyspark import SparkConf, SparkContext

# 创建SparkConf 类对象
conf = SparkConf().setMaster("local[*]").setAppName("test_spark_app")

# 基于 SparkConf 类对象创建的 SparkContext 类对象
sc = SparkContext(conf = conf)

# 打印 PySpark 的运行版本
print(sc.version)

# 停止 SparkContext 对象的运行 (停止 PySpark 程序)
sc.stop()
```

`conf = SparkConf().setMaster("local").setAppName("test_spark_app")` 

这段代码是 PySpark 配置对象的初始化代码, 用来创建 Spark 的配置实例 conf,

参数含义: 

1. `.setMaster("local")`

指定运行模式为本地模式，不连接集群，在本机单机运行 Spark；

- `	local`：使用 1 个 CPU 线程运行；
- 常用变体：`local[*]` 使用本机所有 CPU 核心（开发测试最常用）。

2. `.setAppName("test_spark_app")`

给这个 Spark 应用起名字

```
test_spark_app
```

这个名字会显示在 Spark WebUI 监控页面，方便识别程序。

`sc = SparkContext(conf=conf)` 

这段代码就是根据前面写的配置, 正式启动 Spark 程序



现在 Spark 更推荐用 SparkSession (DataFrame API)，而不是老式 SparkContext RDD

新版的构建入口对象方法: 

```python
from pyspark.sql import SparkSession
spark = SparkSession.builder.master("local").appName("SparkName").getOrCreate()
sc = spark.sparkContext
```

+ `spark = SparkSession.builder.master("local").appName("SparkName").getOrCreate()` 

这是链式调用: 

1. .builder

   + 静态属性, 返回Builder 构建器对象

   + 用于配置 SparkSession 参数 (类似建造者设计模式) 

2. .master(“local”)
   + 指定运行模式 
   + `“local”` : 单线程本地模式
   + `“local[*]”`使用所有CPU 核心
3. .appName(“SparkName”) 
   + 设备应用名称
4. .getCreate() 
   + 首次调用: 根据配置创建新的 SparkSession
   + 后续调用: 如果已经存在相同配置的 SparkSession , 直接复用(避免直接创建)
   + 比旧版的 SparkContext 更加灵活, 支持懒加载和单例模式



+ `sc =  spark.sparkContext` 
  + 新版 SparkSession 内部自动创建了 SparkContext 
  + 通过这个属性可以获取到底层的 RDD 操作接口

## PySpark 的编程模型

SparkContext 类对象, 是PySpark 编程中一切功能的入口 

PySpark 的编程, 只要分为以下三个步骤

<img src="C:\Users\Lenovo\AppData\Roaming\Typora\typora-user-images\image-20260821224315765.png" alt="image-20260821224315765" style="zoom: 200%;" />

通过SparkContext 对象, 完成对数据的输入

输入数据后得到转换为 RDD 对象 ,调用RDD的成员方法进行迭代计算 

最终通过RDD对象的成员方法, 将结果输出到 list ,元组, 字典, 文本文件, 数据库等

![image-20260821224749980](C:\Users\Lenovo\AppData\Roaming\Typora\typora-user-images\image-20260821224749980.png)