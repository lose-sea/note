# SQL 与数据库

无论是何种开发语言, 亦或是何种开发方向, SQL都是开发人员无法绕开的话题.

数据库就是存储数据的库

数据库可以分为 3 个层级: 库, 表, 数据 

数据库是用来存储数据的，在这个过程中，会涉及到：

- 数据的新增
- 数据的删除
- 数据的修改
- 数据的查询
- 数据库、数据表的管理

而 SQL 语言，就是一种对数据库、数据进行操作、管理、查询的工具。

简单来说, SQL语言就是操作数据库的专用工具 

使用数据库软件去获得库 -> 表 -> 数据，这种数据组织、存储的能力, 并借助 SQL 语言，完成对数据的增删改查等操作

由于数据库管理系统 (数据库软件) 功能非常多, 不仅仅是存储数据, 还要包含: 数据个管理, 表的管理, 库的管理, 账户管理, 权限管理等. 

所以, 操作数据库的SQL语言, 也基于功能, 可以划分为 4 类: 



+ 数据定义: DDL (Data Definition Lanauage)
  + 库的创建删除, 表的创建删除等
+ 数据操纵: DML (Data Manipulation Language)
  + 新增数据, 删除数据, 修改数据等
+ 数据控制: DCL (Data Control Language) 
  + 新增用户, 删除用户, 密码修改, 权限管理等
+ 数据查询: DQL (Data Query Language) 
  + 基于需求查询和计算数据



## SQL 的语法特征

1. SQL 语言大小写不敏感
2. SQL 可以单行或者多行书写, 最后以 ; 号结束
3. SQL 支持注释: 
   + 单行注释:  `-- 注释内容`, (`--`后一定要有一个空格)
   + 单行注释:  `# 注释内容` (# 后可以不加空格, 推荐加上) 
   + 多行注释: `/* 注释内容 */`



```sql
-- 注释 

# 注释

/*
 注释
 */
```



在终端输入以下命令就可以进入MySQL 的命令行环境了

```python
 mysql -uroot -p
```



## DDL 

### 库的相关操作

基础命令及功能: 



| 命令                            | 功能                       |
| ------------------------------- | -------------------------- |
| show databases;                 | 查看哪些数据库             |
| use 数据库名 [charset UTF8mb4]; | 使用某个数据库             |
| exit                            | 退出MySQL的命令行环境      |
| create databases 数据库名;      | 创建自己的数据库           |
| select database();              | 查看当前正在使用哪个数据库 |
| drop database 数据库;           | 删除数据库                 |





```sql
-- 查看数据库
show databases; 

-- 创建数据库 
-- create database world;  
-- 默认 utf8mb4
create database world charset utf8mb4;

-- 使用数据库 
use world

-- 查看当前正在使用的数据库 
select database()

-- 删除数据库 
drop database world;
```



### 表的相关操作

基本命令及功能

| 命令                        | 功能                     |
| --------------------------- | ------------------------ |
| show tables;                | 查看当前数据库内有哪些表 |
| drop table 表名称           | 删除表                   |
| drop table if exists 表名称 | 删除表                   |



#### `drop table 表名`

直接删除表。

-  如果**表存在**：正常删掉表（表结构 + 全部数据一起消失）
-  如果**表不存在**：直接报错，整条 SQL 脚本停止往下执行。

> 示例：student 已经被删掉，再执行
>
> `drop table student;` → 报错误：Table 'world.student' doesn't exist，后面的 SQL 不再运行。

#### `drop table if exists 表名`

`if exists` = **如果存在才执行删除**

-  表存在：删除表，和上面效果一模一样
-  表不存在：**不报错，静默跳过，继续执行后面的 SQL**



创建表

```sql
create table 表名称( 
	列名称 列类型, 
	列名称 列类型, 
	...
); 
```

列类型有: 

| 名称              | 类型                             |
| ----------------- | -------------------------------- |
| int               | 整数                             |
| float             | 浮点数                           |
| varchar(最大长度) | 文本, 长度为数字, 做最大长度限制 |
| date              | 日期类型                         |
| timestamp         | 时间戳类型                       |



```sql
use world

-- 创建一个学生表
create table Student(
	id int, 
	-- 括号内表示最大长度限制
	name varchar(10),  
	age int
);  

-- 查看当前库中的表
show tables;  

-- 删除表 
drop table Student; 
```

