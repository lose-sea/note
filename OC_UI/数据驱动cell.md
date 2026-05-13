## 什么是数据驱动 Cell？

**一句话定义：Cell 的视图状态完全由外部传入的数据模型（Model）决定。**

+ **数据变 → Cell 自动变**：视图是数据的一个“快照”或“投影”。
+ **Cell 无状态**：Cell 自身不持有或记忆任何业务状态（如“是否被选中”应由 Model 记录），它只负责忠实地将当前数据渲染出来。
+ **Controller 作为桥梁**：Controller 负责在 Model 和 View（Cell）之间传递数据。

### 与 MVC 架构模式的关系

数据驱动 Cell 正是 **MVC 设计模式在 `UITableView` / `UICollectionView` 场景下的具体落地实践**。

| 概念                            | 层次                    | 核心思想                                                     |
| :------------------------------ | :---------------------- | :----------------------------------------------------------- |
| **MVC (Model-View-Controller)** | **架构模式**            | 宏观上将代码划分为模型、视图、控制器三层，实现业务逻辑、界面和用户交互的解耦。 |
| **数据驱动 Cell**               | **实现技巧 / 设计原则** | 微观上规定了 View（Cell）如何与 Model 进行交互，是 MVC 中“View 的职责”的具体落实。 |

**关系总结**：MVC 搭建了房子的框架，而数据驱动 Cell 则规定了如何高效、整洁地铺设其中的地板（TableView）。

## 生活类比：电子相框 vs. 记事本

想象一个数码电子相框：

+ **非数据驱动**：相框内部有一个记事本，写着“下一张要显示猫咪照片”。你需要手动去修改记事本的内容，相框才会改变。这样，相框自己“记住”了该显示什么，**视图持有状态**。
+ **数据驱动**：相框只有一个屏幕。你给它一张猫咪照片（数据），它就显示猫咪；你给它一张风景照，它就显示风景。相框本身不关心下一张是什么，它只负责把你给的东西展示出来。**视图不持有状态，只负责渲染**。

**核心思想：** **你给我什么数据，我就显示什么样子。** 这是数据驱动的基石。

## 举例讲解：学生成绩列表

我们设计一个展示学生成绩的 UITableView。

###  Model（数据模型）

Model 的唯一职责是**封装数据**。它应该是“干净”的，不包含任何 UI 逻辑。

```objc
// Student.h
#import <Foundation/Foundation.h>

@interface Student : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSInteger score;  // 0-100分
@property (nonatomic, assign, getter=isPassed) BOOL passed; // 是否及格，可作为业务属性

- (instancetype)initWithName:(NSString *)name score:(NSInteger)score;

@end
```



###  View（Cell 视图）

View 的职责是**根据传入的数据渲染 UI**。它提供一个公开方法（如 `configureWithModel:`）作为数据入口。

```objc
// StudentCell.h
#import <UIKit/UIKit.h>
@class Student; // 前向声明，避免循环引用

@interface StudentCell : UITableViewCell

// 这是数据驱动的核心接口：接收 Model，更新 UI
- (void)configureWithModel:(Student *)student;

@end
```

Cell 的职责：

提供 configureWithStudent: 方法接收数据

根据数据显示 UI

通过代理告诉 Controller 发生了点击 (cell本身不处理数据, 交给controller处理)

在 prepareForReuse 中清空状态哪里调用了这个方法

```objc
// StudentCell.m
#import "StudentCell.h"
#import "Student.h"

@implementation StudentCell

- (void)configureWithModel:(Student *)student {
    // 1. 基础数据绑定
    self.textLabel.text = student.name;
    
    // 2. 业务逻辑驱动的 UI 变化 (如分数不同，颜色和文字不同)
    NSString *scoreText = [NSString stringWithFormat:@"%ld分", (long)student.score];
    self.detailTextLabel.text = scoreText;
    
    if (student.score >= 60) {
        self.detailTextLabel.textColor = [UIColor greenColor];
        self.detailTextLabel.text = [scoreText stringByAppendingString:@" 及格"];
    } else {
        self.detailTextLabel.textColor = [UIColor redColor];
        self.detailTextLabel.text = [scoreText stringByAppendingString:@" 不及格"];
    }
    
    // 3. 根据其他属性修改 UI (例如，及格的学生姓名加粗)
    if (student.isPassed) {
        self.textLabel.font = [UIFont boldSystemFontOfSize:18];
    } else {
        self.textLabel.font = [UIFont systemFontOfSize:17];
    }
}

// 重要：Cell 被重用前会调用此方法，用于清理旧数据。
- (void)prepareForReuse {
    [super prepareForReuse];
    // 重置 UI 到默认状态，避免因复用而显示上一个 Cell 的内容。
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    self.detailTextLabel.textColor = [UIColor blackColor]; // 重置为默认颜色
    self.textLabel.font = [UIFont systemFontOfSize:17];     // 重置为默认字体
}
@end
```

> - (void)prepareForReuse 是系统方法, UITableView 自动调用, 在cell滚出屏幕,进入复用池之前, 通过重写该方法可以清空所有UI状态 
> - 如果是自定义cell, 没有重写该方法, 就会导致滚动时cell显示上一个cell的残留内容, 导致错乱

### Controller（控制器)

Controller 的职责是**协调 Model 和 View**。它持有数据源，并在合适的时机将数据“喂”给 Cell。

objectivec

```objc
// StudentListViewController.m
#import "StudentListViewController.h"
#import "StudentCell.h"
#import "Student.h"

@interface StudentListViewController () <UITableViewDataSource>
@property (nonatomic, strong) NSArray<Student *> *students; // Controller 持有数据源
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation StudentListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 1. 准备数据 (通常来自网络或数据库)
    self.students = @[
        [[Student alloc] initWithName:@"张三" score:95],
        [[Student alloc] initWithName:@"李四" score:45],
        [[Student alloc] initWithName:@"王五" score:78]
    ];
    
    // 2. 设置 TableView
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds];
    self.tableView.dataSource = self;
    [self.tableView registerClass:[StudentCell class] forCellReuseIdentifier:@"StudentCell"];
    [self.view addSubview:self.tableView];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.students.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    StudentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StudentCell" forIndexPath:indexPath];
    
    // 这是数据驱动的关键一步：Controller 取出数据，并通过 Cell 的公开接口传入
    Student *student = self.students[indexPath.row]; 
   
    [cell configureWithModel:student];
    
    return cell;
}
@end
```

在数据驱动cell中, view和model不直接联系, 通过controller 讲数据传递给view显示, 并且当数据改变的时候, (例如点击按钮), 数据也是通过controller 来更新model的



## 数据驱动的核心原则

| 应该做的                                                     | 不应该做的                                          |
| :----------------------------------------------------------- | :-------------------------------------------------- |
| Cell 提供 `configureWithModel:` 等公开方法接收数据。         | Cell 内部自己决定显示什么内容。                     |
| 数据改变时，**修改 Model**，然后**刷新对应的 TableView 行**。 | Cell 内部私自保存上次传入的数据副本（无状态原则）。 |
| Controller 负责管理 Model 数组和处理用户交互。               | Cell 内直接修改 Controller 持有的 Model 数据。      |
| 在 `prepareForReuse` 中清理 Cell 的 UI 状态。                | 假设 Cell 在复用时 UI 是干净的。                    |

## 处理用户交互与数据变更

当用户在 Cell 上进行操作（如点赞、关注、评分），正确的流程是：

1. **Cell 发出通知**：通过 `delegate` 或 `block` 将事件（和必要的 IndexPath）告诉 Controller。
2. **Controller 更新 Model**：Controller 找到对应的 Model，修改其属性。
3. **Controller 刷新 UI**：Controller 调用 `reloadRowsAtIndexPaths:` 方法，触发 TableView 重新渲染该行。

```objc
// StudentCell.h 中添加代理协议
@protocol StudentCellDelegate <NSObject>
- (void)studentCellDidTapPassButton:(StudentCell *)cell; // 假设有一个“修改及格状态”的按钮
@end

// StudentListViewController.m 中实现代理
- (void)studentCellDidTapPassButton:(StudentCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    Student *student = self.students[indexPath.row];
    
    // 1. 修改 Model
    student.passed = !student.isPassed;
    // 假设修改分数为 60 或 0 作为演示
    student.score = student.isPassed ? 60 : 0; 
    
    // 2. 刷新 UI (这会重新调用 cellForRow，进而调用 configureWithModel:)
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}
```



**核心闭环**：**用户操作** → **更新 Model** → **刷新 UI** → **UI 从新 Model 重新渲染**。

## 为什么需要 `prepareForReuse` ？

`UITableView` 的复用机制是为了性能，它会缓存滚出屏幕的 Cell。当一个新的行要出现时，系统会从缓存池中取出一个旧 Cell 给你。

**如果没有 `prepareForReuse` 清理：**
假设一个红色的“不及格”Cell 被复用给一个“及格”的学生，在 `configureWithModel:` 还没来得及将文字颜色改成绿色之前，这个 Cell 短暂地会显示为红色，造成界面闪烁和信息错乱。

**`prepareForReuse` 的作用：**
在 Cell 被放入复用池**之前**，给你最后一次机会将其所有 UI 控件重置为“出厂设置”（如文本 nil，颜色默认）。这样，下一个使用它的 `configureWithModel:` 方法就能在一个干净的环境中重新绘制。

##  数据驱动带来的核心优势

| 维度               | 非数据驱动（Controller 直接操作 Cell 的 UI）                 | 数据驱动（Cell 内部自己渲染）                                |
| :----------------- | :----------------------------------------------------------- | :----------------------------------------------------------- |
| **代码重复**       | 每个 `cellForRow` 的地方都要写一遍 `cell.textLabel.text = xxx`，极易重复。 | 所有 UI 逻辑封装在 Cell 的 `configure` 方法中，只写一次。    |
| **修改 UI**        | 改了 UI 设计，需要在所有用到该 Cell 的 Controller 中逐一修改。 | **只需修改 Cell 的 `configureWithModel:` 方法**，一处改动，全局生效。 |
| **复用性**         | Cell 换个 ViewController 使用，UI 配置代码需要复制粘贴。     | 新的 Controller 只需导入 Cell 头文件并调用 `configureWithModel:` 即可。 |
| **可读性与维护性** | `cellForRow` 方法中混杂着数据提取、UI 定制、布局逻辑，动辄数十行。 | `cellForRow` 方法**仅需 3 行**：取 cell、取 model、传数据。Controller 极度简洁。 |
| **单元测试**       | 很难对 UI 逻辑进行测试。                                     | 可以创建一个 `Student` 实例，调用 `[cell configureWithModel:]`，然后断言 cell 的文字颜色是否符合预期。 |

## 总结

**一句话概括：数据驱动 Cell = Model 决定一切，View 只负责渲染，Controller 负责协调。**

1. **Model**：存储数据和业务状态（名字、分数、是否点赞……）。
2. **View (Cell)**：提供 `configureWithModel:` 这样的统一入口，根据 Model 的值来决定自己长什么样。
3. **Controller**：作为中间人，监听用户交互，更新 Model，并在 Model 变化后重新将数据“喂”给 View。