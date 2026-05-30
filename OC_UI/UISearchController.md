# UISearchController

`UISearchController` 是苹果提供的一个控制器，专门用来管理搜索功能。它帮你做了三件事：

+ 显示一个搜索框（`searchBar`）
+ 监听用户输入
+ 通知你去更新搜索结果

## 协议

首先, 需要遵守协议, 用于在搜索栏中输入后更新搜索结果

```objc
<UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
```

> + UISearchResultsUpdating是用于当UISearchController中的搜索文本发生变化时，通知搜索结果控制器更新结果的协议。
> + 只有一个方法：updateSearchResultsForSearchController:。
> + 通常在里面获取searchBar.text，然后根据文本过滤数据源，刷新tableView。
> + 配合UISearchController的searchResultsUpdater属性使用。
> + 适用于动态过滤本地数据

这里做一展示

![CleanShot 2026-05-30 at 22.08.57](/Users/lose_sea/Desktop/pintures/CleanShot 2026-05-30 at 22.08.57.gif)

可以看到, 当用户在搜索框中输入、删除或修改文字时，系统会自动调用该协议中唯一的方法：`- (void)updateSearchResultsForSearchController:(UISearchController *)searchController `方法 

在这个方法中, 可以根据搜索框中的文本(UISearchController.searchBar.text) 来刷新UITableView 或者 UICollectionView   

## 声明属性

```objc
// ViewController.m

@interface ViewController ()

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;

@property (nonatomic, strong) NSArray<NSString *> *allData;       // 原始数据，永远不动
@property (nonatomic, strong) NSArray<NSString *> *filteredData;  // 显示用的数据

@end
```

我们定义声明一个 UITableView 来实时显示我们的搜索结果, 并声明两个NSArray 来作为 UITableView的数据源, allData 用来存储全部的数据, filteredData 这用来存储根据搜索结果筛选的数据 

```objc
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"搜索";
    // Do any additional setup after loading the view.
    
    // ① 准备数据
    self.allData = @[@"Apple", @"Banana", @"Cherry", @"Date", @"Fig", @"Grape"];
    self.filteredData = self.allData;
    
    [self setupTableView];
    [self setupSearchController];
    
    if (@available(iOS 26.0, *)) {
            self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
            self.navigationItem.searchBarPlacementAllowsToolbarIntegration = NO; // 设置不允许将UISearchController放在工具栏中,保证UISearchController在上方的导航栏中
        }
}
```

> 在iOS26之后, UISearchController 默认是添加到toolbar中的,也就是显示在屏幕的下方, 如果要想让 UISearchController 显示在导航栏中, 就需要添加以下代码, 用来规定UISearchController 的位置
>
> ```objc
> if (@available(iOS 26.0, *)) {
>     self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
>     // 设置不允许将UISearchController放在工具栏中,保证UISearchController在上方的导航栏中    
>     self.navigationItem.searchBarPlacementAllowsToolbarIntegration = NO; 
> } 
> ```
>

 

## 创建 UISearchController

```objc
 self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
```

参数 nitWithSearchResultsController 表示显示结果的页面,传 nil 表示在当前界面显示搜索结果

注意,如果要跳转界面进行结果展示, 需要要将searchResultsUpdater 代理对象设置为要跳转的视图控制器,否则无法观察到搜索结果

```objc
    MyViewController* vc = [[MyViewController alloc] init];
    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController: vc];
    
    searchController.searchResultsUpdater = vc;               // 设置结果更新代理
```



这里展示跳转界面展示搜索结果

![CleanShot 2026-05-30 at 22.55.10](/Users/lose_sea/Desktop/pintures/CleanShot 2026-05-30 at 22.55.10.gif)