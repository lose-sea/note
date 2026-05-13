## 数据驱动 Cell 的核心思想

**一句话概括**：Cell 只负责显示数据，不知道自己在第几行、不知道数据从哪来。ViewController 只负责管理数据数组，告诉 TableView 有多少数据，然后把对应的数据模型扔给 Cell 去显示。

text

```
┌─────────────┐     传递数据模型      ┌─────────────┐
│ ViewController │ ─────────────────→ │    Cell     │
│   (数据数组)    │                     │  (只负责显示) │
└─────────────┘                       └─────────────┘
```



------

## 一个完整的最小示例

### 1. 定义数据模型

objectivec

```
// StudentModel.h
@interface StudentModel : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *studentId;
@property (nonatomic, assign) NSInteger age;

- (instancetype)initWithName:(NSString *)name studentId:(NSString *)studentId age:(NSInteger)age;

@end
```



### 2. 自定义 Cell

objectivec

```
// StudentCell.h
@interface StudentCell : UITableViewCell

// 这是数据驱动的核心方法：传入模型，Cell自己决定如何显示
- (void)configWithModel:(StudentModel *)model;

@end
```



objectivec

```
// StudentCell.m
@interface StudentCell ()
@property (weak, nonatomic) IBOutlet UILabel *nameLabel;
@property (weak, nonatomic) IBOutlet UILabel *idLabel;
@property (weak, nonatomic) IBOutlet UILabel *ageLabel;
@end

@implementation StudentCell

- (void)configWithModel:(StudentModel *)model {
    // Cell 只做一件事：把模型里的数据填到 UI 上
    // 不关心这个 model 是数组里的第几个
    self.nameLabel.text = model.name;
    self.idLabel.text = model.studentId;
    self.ageLabel.text = [NSString stringWithFormat:@"%ld岁", (long)model.age];
}

@end
```



### 3. ViewController 管理数据和 TableView

objectivec

```
// ViewController.m
@interface ViewController () <UITableViewDelegate, UITableViewDataSource>

@property (weak, nonatomic) IBOutlet UITableView *tableView;
@property (nonatomic, strong) NSArray<StudentModel *> *dataArray;  // 数据数组

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. 准备数据
    [self setupData];
    
    // 2. 设置 TableView
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.tableView registerNib:[UINib nibWithNibName:@"StudentCell" bundle:nil] 
         forCellReuseIdentifier:@"StudentCell"];
}

- (void)setupData {
    // 数据可以来自本地、网络、数据库，这里硬编码示例
    StudentModel *stu1 = [[StudentModel alloc] initWithName:@"张三" studentId:@"2024001" age:20];
    StudentModel *stu2 = [[StudentModel alloc] initWithName:@"李四" studentId:@"2024002" age:21];
    StudentModel *stu3 = [[StudentModel alloc] initWithName:@"王五" studentId:@"2024003" age:19];
    
    self.dataArray = @[stu1, stu2, stu3];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // 数组里有多少个数据，就有多少行
    return self.dataArray.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    StudentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StudentCell" forIndexPath:indexPath];
    
    // 关键：取出对应位置的数据模型
    StudentModel *model = self.dataArray[indexPath.row];
    
    // 关键：把模型传给 Cell，让 Cell 自己处理显示
    [cell configWithModel:model];
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 80;  // 固定高度，或者根据 model 动态计算
}

@end
```



------

## 数据驱动的几个关键点

### 1. Cell 不存储 indexPath

不要在 Cell 里存 `NSIndexPath *currentIndexPath`，这会破坏数据驱动。

objectivec

```
//  错误做法
cell.currentIndexPath = indexPath;
cell.deleteButton.tag = indexPath.row;

// 通过 Block 或 Delegate 回调
cell.deleteButtonTapBlock = ^{
    // 在 Block 里捕获 model，而不是 indexPath
    [self deleteStudent:model];
};
```



### 2. 刷新数据只改数组，然后 reload

objectivec

```
// 添加新数据
- (void)addNewStudent:(StudentModel *)newStudent {
    NSMutableArray *mutableArray = [self.dataArray mutableCopy];
    [mutableArray addObject:newStudent];
    self.dataArray = [mutableArray copy];
    
    // 刷新 TableView
    [self.tableView reloadData];
    
    // 或者局部刷新
    // NSInteger newIndex = self.dataArray.count - 1;
    // [self.tableView insertRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:newIndex inSection:0]] 
    //                       withRowAnimation:UITableViewRowAnimationAutomatic];
}
```



### 3. 动态高度配合数据驱动

objectivec

```
// 在 Model 里缓存高度
@interface StudentModel : NSObject
// ... 其他属性
@property (nonatomic, assign) CGFloat cachedHeight;
@end

// 在 ViewController 里
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    StudentModel *model = self.dataArray[indexPath.row];
    
    if (model.cachedHeight == 0) {
        // 计算高度并缓存
        model.cachedHeight = [self calculateHeightForModel:model];
    }
    return model.cachedHeight;
}
```