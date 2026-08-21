# pymysql 

除了使用图形化工具以外, 我们也可以使用编程语言来执行 SQL 从而操作数据库 

在python中, 使用第三方库: pymysql 来完成对 MySQL 数据库的操作

## 链接 MySQL

获取链接对象: 

```python
Connection (主机, 端口, 账户, 密码)
```

关闭链接

```python
链接对象.close() 
```





```python
# 导入包
from pymysql import Connection

# 获取到 MySQL 数据库的链接对象
conn = Connection(
    host = 'localhost', # 主机名
    port = 3306,   # 端口
    user = 'root', # 账户名
    passwd = '******' # 密码
)

# 打印 MySQL 数据库软件信息
print(conn.get_server_info())

# 关闭到数据库的链接
conn.close()
```

## 执行 SQL 语句

首先执行导包, 链接数据库的操作

```python
# 导入包
from pymysql import Connection

# 获取到 MySQL 数据库的链接对象
conn = Connection(
    host = 'localhost', # 主机名
    port = 3306,   # 端口
    user = 'root', # 账户名
    passwd = 'wuxiaxiu1' # 密码
)
```



### 获取游标对象

通过链接对象调用 cursor() 方法 得到里游标对象

```python
cursor = conn.cursor()
```



### 选择数据库

选择数据库可以通过 `select_db(数据库名)` 的成员方法

```python
# 选择数据库
conn.select_db("test") 
```



### 执行 SQL非插入 语句

基础语法: 

```python
游标对象.execute(sql语句)
```



```python
# 使用游标对象, 执行 sql 语句
cursor.execute("create table test_pymysql(id int);")
```

这里是执行非查询性质的sql语句 



```python
cursor = conn.cursor()
cursor.execute("select * from world.student;")
result = cursor.fetchall()

print(type(result)) # <class 'tuple'>

print(result)

for i in result:
    print(i)
```

通过`cursor.fetchall()` 的成员方法来获取查询到的信息

这里执行查询性质的 sql 语句, 查询到的数据以 tuple 的类型返回

## 插入数据 

```python
from pymysql import Connection

conn = Connection(
    host = "localhost",
    port = 3306,
    user = "root",
    passwd = "*******"
)

conn.select_db("world")

cursor = conn.cursor()

cursor.execute("insert into student (name) values ('hello'), ('hello'), ('hello')")

conn.close()
```

上面的代码执行是无法将数据插入到数据表中的

pymysql 在执行数据插入或其他产生护数据更改的 SQL 语句时候, 默认是需要提交更改的, 即: 需要通过代码“确认” 这种更改行为 

通过`链接对象.commit()` 即可确认此行为

```python
from pymysql import Connection

conn = Connection(
    host = "localhost",
    port = 3306,
    user = "root",
    passwd = "wuxiaxiu1"
)

conn.select_db("world")

cursor = conn.cursor()

cursor.execute("insert into student (name) values ('hello'), ('hello'), ('hello')")

conn.commit() # 添加这一行代码
conn.close()
```

### 自动 commit

如果不想手动commit 确认, 可以在构建链接对象的时候, 设置自动 commit 属性 

```python
conn = Connection(
    host = "localhost",
    port = 3306,
    user = "root",
    passwd = "*******", 
    autocommit = True
)
```

