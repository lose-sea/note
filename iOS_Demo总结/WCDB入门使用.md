[toc]

# WCDB入门使用

WCDB 是微信团队开源的一个**高效、完整、易用**的移动端数据库框架，它基于 SQLite 和 SQLCipher，支持 C++、Java、Kotlin、Swift 和 Objective-C 等多种语言

WCDB通过两个核心设计，能**用面向对象的方式操作数据库**，把复杂的 SQL 语句变成一行简单的代码。

## 准备与配置 

在开始写代码前，需要先完成两件事：

因为我们只使用OC,所以导入WCDB的objc部分

**集成WCDB**：在`Podfile`中添加`pod 'WCDB.objc'`，然后运行`pod install`。

**关键步骤：文件改名**：因为WCDB是用Objective-C++编写的，所有**需要引入或使用WCDB的`.m`文件，都必须把后缀名改为`.mm`**

## 模型定义与ORM绑定

ORM (Object Relational Mapping) 是WCDB的核心，它能把Objective-C的类和数据库的表、字段一一对应起来。这样就不用写SQL来建表了。



![image-20260901194848714](/Users/lose_sea/Desktop/pintures/image-20260901194848714.png)

导入WCDB之后就可以直接按照按照模版创建一个WCDB的使用文档了, 创建新文件,在iOS标签下会出现WCDB模块,点击中间的`TableCodable`,输入文件名可以生成模版文件了

![image-20260901195238545](/Users/lose_sea/Desktop/pintures/image-20260901195238545.png)

### WCDB 模型ORM绑定

在WCDB内，ORM（Object Relational Mapping）是指

1. 将一个ObjC的类，映射到数据库的表和索引；
2. 将类的property，映射到数据库表的字段；
3. 这一过程。通过ORM，可以达到直接通过Object进行数据库操作，省去拼装过程的目的。



在MyWCDB.h 文件中声明需要存入数据库的属性

```objc
// MyWCDB.h

@interface MyWCDB : NSObject

/*
 // An ORM type can be any C types or any ObjC classes which conforms to NSCoding or WCTColumnCoding protocol.
 // An ORM property must contains a setter which can be private
@property (nonatomic, retain) NSString *<#property1#>;
@property (nonatomic, assign) NSInteger <#property2#>;
@property (nonatomic, assign) float <#property3#>;
@property (nonatomic, strong) NSArray *<#property4#>;
@property (nonatomic, readonly) NSDate *<#..........#>;
 */

@property (nonatomic, assign) NSInteger userID;
@property (nonatomic, strong) NSString* name;
@property (nonatomic, strong) NSArray* array; 

@end
```

在 `MyWCDB+WCTTableCoding.h` 中用 `WCDB_PROPERTY` 声明

>  **注意**：这些宏**只负责声明**，它们**不负责执行**。具体的执行工作，是在 `MyWCDB.mm` 文件中通过 `WCDB_IMPLEMENTATION` 和 `WCDB_SYNTHESIZE` 等宏来完成的。



 **为什么要分成两个文件？**

这是 WCDB 设计的一种良好实践，通过 **Category（类别）** 来隔离数据库相关的代码。

+ **优点**：这种设计可以保持主模型类 `MyWCDB.h` 干净、纯粹，不被数据库特定的代码所污染。如果有一天你不想用 WCDB 了，或者要换一种持久化方案，只需要处理这个 Category 文件，而不用去改动 `MyWCDB.h` 的核心业务逻辑。

`````objc
// MyWCDB+WCTTableCoding.h

#import "MyWCDB.h"
#import <WCDBObjc/WCDBObjc.h>

@interface MyWCDB (WCTTableCoding) <WCTTableCoding>
/*
WCDB_PROPERTY(<#property1#>)
WCDB_PROPERTY(<#property2#>)
WCDB_PROPERTY(<#property3#>)
WCDB_PROPERTY(<#property4#>)
WCDB_PROPERTY(<#.........#>)
 */

WCDB_PROPERTY(userID)
WCDB_PROPERTY(name)
WCDB_PROPERTY(array)

@end
`````

 在 `MyWCDB.mm` 中用 `WCDB_SYNTHESIZE` 实现绑定

```objc
// MyWCDB.mm 


#import "MyWCDB+WCTTableCoding.h"
#import "MyWCDB.h"

@implementation MyWCDB

WCDB_IMPLEMENTATION(MyWCDB)
WCDB_SYNTHESIZE(text)
WCDB_SYNTHESIZE(array)
WCDB_SYNTHESIZE(myId)


//// 自定义列名
//WCDB_SYNTHESIZE_COLUMN(<#property5#>, "<#column name#>")   // Custom column name

// 主键, 每次插入新纪录是自动加一
WCDB_PRIMARY_AUTO_INCREMENT(myId)

// 数据库索引
// 为指定创建索引, 用于加速查询速度
//WCDB_INDEX(<#_index_subfix#>, <#property#>)

@end
```

这段代码，是 **WCDB for Objective-C 进行对象关系映射（ORM）的核心配置**。它的作用，就是告诉 WCDB 如何将 `MyWCDB` 类与数据库中的一张表对应起来。

+ **`WCDB_IMPLEMENTATION(MyWCDB)`**
  + **作用**：这是**绑定的“开关”**。它是一个必需的宏，用来为 `MyWCDB` 类初始化 ORM 所需的内部结构。没有这行代码，后面的所有绑定宏都不会生效。
+ **`WCDB_SYNTHESIZE(userID)`**
  + 作用: 将 `MyWCDB` 类的 `userID` 属性，绑定到数据库表中一个同名的列上。
  + 当在代码里写入 `myWCDBObject.userID = 10` 并保存时，WCDB 就知道要把值 `10` 存到表里的 `userID` 这一列。
  + 同理，`WCDB_SYNTHESIZE(name)` 和 `WCDB_SYNTHESIZE(array)` 就是将 `name` 和 `array` 属性也绑定到对应的列。

**定制化配置**

+ **`WCDB_SYNTHESIZE_COLUMN(<#property5#>, "<#column name#>")`**
  + **作用**：用于**自定义数据库中的列名**。
  + 当不想用属性名作为列名时，就可以用它。比如， OC 属性叫 `userID`，但想在数据库里把它命名为 `id`，就可以写成 `WCDB_SYNTHESIZE_COLUMN("id", userID)`。

高级约束

+ **作用**：将 `userID` 列设置为**自增主键**。
  + `userID` 将成为这张表的主键，确保每行数据的唯一
  + 每次插入一个新对象时，只要不手动设置 `userID`，WCDB 就会自动为它分配一个全局唯一的、递增的整数值（1, 2, 3...）。这是建立数据关系（如用户ID关联订单）的基础。
+ **`WCDB_INDEX(<#_index_subfix#>, <#property#>)`**
  + **作用**：为指定的属性列**创建索引**。
  + 想象一下一本书的“索引”章节。如果你经常根据 `name` 字段来查询用户，那么为 `name` 列建立索引，可以极大地提升查询速度，尤其是在数据量很大时。
  + `<#_index_subfix#>` 是你这个索引起的一个后缀名，WCDB 会自动生成完整的索引名（比如表名加后缀）。

## 执行CRUD (增删改查) 

首先,需要将所有需要引入或使用WCDB的`.m`文件，都必须把后缀名改为`.mm`, 例如: 将 `ViewController.m` 改为 `ViewController.mm` , 然后, 在其中完成数据库的初始化和表的创建, 这是所有操作的基础

### 数据库的初始化和表的创建



```objc
// ViewController.mm 
   
#import "ViewController.h"
#import "MyWCDB+WCTTableCoding.h" // 导入 Category 才能让 WCDB 识别 MyWCDB

@interface ViewController ()
// 声明数据库
@property (nonatomic, strong) WCTDatabase* database;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    [self setUpDatabase];
    [self createTable];
}


- (void) setUpDatabase {
    // 获取数据库文件路径
    NSString* docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,  NSUserDomainMask,  YES) firstObject];
    NSString* dbPath = [docPath stringByAppendingPathComponent: @"myTest.db"];
    NSLog(@"数据库路径: %@", dbPath);
    
    // 创建数据库实例
    self.database = [[WCTDatabase alloc] initWithPath: dbPath];
    // 打开数据库（如果打开失败会抛出异常）
    // WCDB 会第一次执行增删改查时自动打开数据库，不需要手动调用open。
//    可以用 canOpen 检测数据库文件是否可以正常初始化；isOpened 判断是否已经打开。
    if (![self.database canOpen]) {
        NSLog(@"数据库打开失败");
        return;
    }
    
    NSLog(@"数据库打开成功");
}


- (void)createTable {
    // 创建表，表名使用类名 "MyWCDB"
    BOOL result = [self.database createTable:@"MyWCDB" withClass:MyWCDB.class];
    if (result) {
        NSLog(@"表创建成功");
    } else {
        NSLog(@"表创建失败");
    }
}
@end
```

1. **获取Documents 目录路径**

   `NSString* docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]; `

   **作用**：获取应用的 Documents 目录路径

   **参数说明**：

   + `NSDocumentDirectory`：指定要查找 Documents 目录
   + `NSUserDomainMask`：指定用户域（应用沙盒）
   + `YES`：是否展开波浪号路径（~）

   **返回值**：路径数组，通过 `firstObject` 获取第一个（也是唯一一个）路径

2. **拼接完整的数据库文件路径**

   `NSString* dbPath = [docPath stringByAppendingPathComponent: @"myTest.db"];` 

   **作用**：在 Documents 目录下创建一个名为 `myTest.db` 的数据库文件

   **参数说明**：

   `@"myTest.db"`：数据库文件名（可以自定义，建议以 `.db` 或 `.sqlite` 结尾）

   示例: `/Users/.../Documents/myTest.db`

3. **创建数据库实例**

   `self.database = [[WCTDatabase alloc] initWithPath: dbPath];`

​	此时数据库并没有真正打开 ,只是创建了对象

​	如果路径目录不存在 ,WCDB会尝试自动创建

4. **检测数据库是否可用**

   ```objc
   if (![self.database canOpen]) {
       NSLog(@"数据库打开失败");
       return;
   }
   ```

   验证数据库文件是否可以被正确初始化和打开

    WCDB 会第一次执行增删改查时自动打开数据库, 可以用 canOpen 检测数据库文件是否可以正常初始化；isOpened 判断是否已经打开。

### 插入数据

```objc
// insert Data
- (void) insertData {
    // 创建一个用户
    MyWCDB* user1 = [[MyWCDB alloc] init];
    user1.name = @"张三";
    user1.array = @[@"iOS", @"Python"];
    
    BOOL success1 = [self.database insertObject: user1 intoTable: @"MyWCDB"];
    if (success1) {
        NSLog(@"数据插入成功, user1: %lu, %@, %@", user1.userID, user1.name, user1.array);
    }
    
    MyWCDB* user2 = [[MyWCDB alloc] init];
    user2.name = @"张三";
    user2.array = @[@"iOS", @"Python"];
    
    BOOL success2 = [self.database insertObject: user2 intoTable: @"MyWCDB"];
    if (success2) {
        NSLog(@"数据插入成功, user2: %lu, %@, %@", user2.userID, user2.name, user2.array);
    }
}
```



### 查询数据 

```objc
// search Data
- (void) queryData {
    // 查询所有数据
    NSArray<MyWCDB*>* results = [self.database getObjectsOfClass: MyWCDB.class fromTable: @"MyWCDB"];
    
    NSLog(@"查询到%ld条数据", results.count);
    for (MyWCDB* item in results) {
        NSLog(@"userID: %lu, name: %@, array: %@", item.userID, item.name, item.array);
    }
}
```



### 更新数据

```objc
- (void) updateData {
    // 将 userID 为 1 的用户改为 "王五"
    BOOL success = [self.database updateTable: @"MyWCDB" setProperty: MyWCDB.name toValue:  @"王五" where: MyWCDB.userID == 1];
    if (success) {
        printf("success");
    } else {
        NSLog(@"fail");
    }
    
    [self queryData];
}
```



### 删除数据

```objc
- (void) deleteData {
    // 删除 userID 为2 的用户
    BOOL success = [self.database deleteFromTable: @"MyWCDB"];
    if (success) {
        NSLog(@"delete success");
    } else {
        NSLog(@"delete failure");
    }
    
    [self queryData];
}
```



