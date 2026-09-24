# **WCDB 主键 & 自增 知识点整理**

### 1. 核心结论

+ **代码里有没有写 WCDB_PRIMARY_xxx 宏**，和**磁盘上表实际有没有主键**，是两回事。
+ createTable:withClass: 用的是 CREATE TABLE IF NOT EXISTS，**不会修改已有表的主键/唯一约束**。
+ 所以经常出现「代码已经改了，但插入还是冲突」的情况 → 原因是旧表结构还在。

------

### 2. 三种常见情况对比

| 情况 | 代码里是否有 PRIMARY 宏 | 磁盘上表是否已有主键 | 能否插入相同 userID 的数据       | 说明         |
| ---- | ----------------------- | -------------------- | -------------------------------- | ------------ |
| A    | 有（自增）              | 有                   | 不能（除非设置 isAutoIncrement） | 正常主键冲突 |
| B    | 没有                    | 有（旧表残留）       | **不能**                         |              |
| C    | 没有                    | 没有（删表重建后）   | 能                               | 真正没有主键 |

------

### 3. 正确使用自增主键的写法

**模型绑定（MyWCDB.mm）：**



```objc
WCDB_IMPLEMENTATION(MyWCDB)
WCDB_SYNTHESIZE(userID)
WCDB_SYNTHESIZE(name)
WCDB_SYNTHESIZE(array)

WCDB_PRIMARY_AUTO_INCREMENT(userID)   // 声明支持自增
```

**插入时必须加这一句：**

`user.isAutoIncrement = YES; `

```objc
MyWCDB *user = [[MyWCDB alloc] init];
user.isAutoIncrement = YES;           
user.name = @"张三";
user.array = @[@"iOS", @"Python"];

[self.database insertObject:user intoTable:@"MyWCDB"];
```

+ isAutoIncrement = YES 的作用：
  WCDB **忽略**对象上当前的 userID 值，改用数据库自增（取当前最大值 +1）。
+ 插入成功后，真正的自增值会回填到 user.userID 或 user.lastInsertedRowID。

------

### 4. 为什么「不绑 userID」就能插相同数据？

因为不绑定后，表创建时根本没有 userID 这一列，也没有主键/唯一约束，SQLite 允许完全重复的行存在。

------

### 5. 常见踩坑与解决办法

**坑1：改了宏，但插入还是冲突**

+ 原因：旧表结构残留。

+ 解决：

  

  ```objc
  [self.database dropTable:@"MyWCDB"];  // 调试用
  [self createTable];
  ```

  或者删除 App / 删除模拟器里的 

  myTest.db

   后重跑。

**坑2：写了 WCDB_PRIMARY_AUTO_INCREMENT，但不设置 isAutoIncrement = YES**

+ 结果：对象默认 userID = 0，第二次插入直接主键冲突。

**坑3：以为「不写 PRIMARY 宏 = 没有主键」**

+ 错！必须保证磁盘上的表也是按当前定义创建的。

------

### 6. 一句话记忆

> **代码声明 + 对象设置 isAutoIncrement + 表结构干净**，三者缺一不可。
>  否则要么插不进去，要么插进去了但主键行为不符合预期。