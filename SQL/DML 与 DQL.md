# DML

DML 是指数据操作语言, 英文全称是 Data Manipulation Language, 用来对数据库中表的数据记录进行更新 

关键字: 

+ 插入: Insert
+ 删除: delete
+ 更新: update

## 数据插入: insert

 基础语法: 

```sql
insert into 表(列1, 列2, ......, 列N) values (值1, 值2, ......, 值N), (值1, 值2, ......值N), ......((值1, 值2, ......, 值N)
```

创建表

```sql
create table Student(
	id int, 
	name varchar(10), 
	age int
); 
```



插入数据

```sql
insert into student (id) values(1), (2), (3); 
```

插入多列多条数据

```sql
insert into student(id, name, age) values(4, 'John', 32), (5, 'zhangpeng', 33), (6, 'Meke', 12); 
```



## 数据删除 Delete

基础语法: 

```sql
delete from 表名称 [where 条件判断]; 
```

条件判断: 列, 操作符, 值

操作符: =, <, >, <=, >=, != 等, 例如: 

```sql
id =5
id < 4
id != 8
```

不写条件判断,默认将整张表的数据清空

条件之间可以用 **and** 和 **or** 连接

```sql
-- 清空表中所有数据
delete from student; 

delete from student where id = 3

delete from student where id > 1 and id < 3; 

delete from student where id > 4 or id = 1;
```



## 数据更新

基础语法: 

```sql
update 表名 set 列 = 值 [wherer 条件判断]; 
```



例如: 

```sql
update student set name = 'inyan'where id = 2; 
```

不写条件判断默认更新所有行

```sql
update student set name = 'xinyan'; 
```

**注意: 字符串的值, 出现在SQL语句中, 必须要用==单引号==包围==起来**



# DQL



## 基础查询

在SQL中 ,通过 select 关键字开头的SQL语句,来进行数据的查询

基础语法: 

```sql
select 字敦列表 / * from 表 [where 条件判断]
```

含义: 从(from)表中, 选择(select) 某些列进行展示 



```sql
select id, name from student; 
```

使用 * 表示查询全部的列

```sql
select * from student; 

select * from student where id > 1 and id < 4; 
```

不写条件判断默认查询所有 

## 分组聚合

分组聚合应用场景非常多, 例如: 统计班级中, 男女的人数比例 

这种需求就需要: 

+ 按性别分组
+ 统计每个组的人数

这就称之为: 分组聚合



基础语法: 

```sql
select 字段 / 聚合函数 from 表 [where 条件] group by 列
```

聚合函数有: 

+ sum(列) 求和
+ avg(列) 求平均值
+ min(列) 求最小值
+ max(列) 求最大值
+ count(列 / *) 求数量

 

```sql
-- 查询姓名和年纪平均值
select name, avg(age) from student group by name; 

-- 查询年纪最大和最小, 数量
select name, min(age), max(age), count(age) from student group by name; 
```

![image-20260821020453718](C:\Users\Lenovo\AppData\Roaming\Typora\typora-user-images\image-20260821020453718.png)

group by 中出现了哪个列, 哪个列才能出现在 select 中的非聚合中

## 排序分页

### 排序

可以对查询的结果, 使用order by 关键字, 指定某个列进行排序

基础语法: 

```sql
select 列 / 聚合函数 / * from 表
where 判断条件
group by ...
order by ... [ASC / DESC]
```

+ ASC 表示升序排序 (从小到大)
+ DESC 表示降序排序 (从大到小)

例如: 

```sql
select name, count(name) from student where id = 1 group by name order by count(name) asc; 
```

###  结果分页限制 

同样, 可以使用LIMT 关键字, 对查询结果进行数量限制或分页显示,

语法: 

```sql
select 列 / 聚合函数 / * from 表 
where ... 
group by ... 
order by ... [ASC / DESC] 
limit n [, m]
```



```sql
select * from student limit 5; 
```

表示限制 5 条数据 



```sql
select * from student limit 5, 3; 
```

表示跳过 5 条数据, 从第 6 条开始, 向后取 3 条数据