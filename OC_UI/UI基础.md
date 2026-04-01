子视图的坐标是参照父亲视图, 父视图在移动时, 所有的子视图都会移动

每一个view都有一个window属性， 父视图所有的子视图 view的window都相同，程序只有一个window 

## 设置根视图控制器

```objc
MyWindow* vc = [[MyWindow alloc] init];
UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController: vc];
self.window.rootViewController = nav;
[self.window makeKeyAndVisible];
```



```objc
MyWindow* vc = [[MyWindow alloc] init];
self.window.rootViewController = vc;
```

上面的两段代码效果一样, 有什么区别

## 核心区别

| 对比点              | 代码1                              | 代码2                       |
| ------------------- | ---------------------------------- | --------------------------- |
| 根视图控制器        | `UINavigationController`（导航栈） | `MyWindow` 直接作为根控制器 |
| 导航功能            | ✅ 有导航栏、支持 push/pop          | ❌ 无导航能力                |
| `makeKeyAndVisible` | 手动调用                           | 未调用（可能在别处调用）    |

## 根视图控制器 

#### SceneDelegate.m

```objc
@implementation SceneDelegate


- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    
    // 设置根视图
    // 有导航栏
//            MyWindow* vc = [[MyWindow alloc] init];
//            UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController: vc];
//            self.window.rootViewController = nav;
//            [self.window makeKeyAndVisible];
    

////    // 对窗口的根视图控制器进行赋值操作
////    // 整个UIKit中只有一个根视图控制器， 属于window属性
////    // 用来管理界面和处理界面的逻辑对象
// // // UIViewController* vcRoot = [[UIViewController alloc] init];
//    self.window.rootViewController = vcRoot;
//    // 将window作为主视图并显示出来
//    [self.window makeKeyAndVisible];
//    self.window.backgroundColor = [UIColor blueColor]; 
    
    
//    // 创建一个UIWindow对象
//    // 整个程序只有一个UIWindow 对象
//    // 在程序基本上表示屏幕窗口
//    // UIWindow 也继承于UIView
//    // 是一种特殊的UIView
//    
//    // UIScreen 表示屏幕硬件表示类
//    // mainScreen 获取主屏幕设备信息
//    // bounds 表示屏幕的宽高值
//    self.window = [[UIWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
//    
//    self.window.rootViewController = [[UIViewController alloc] init];
//    
//    self.window.backgroundColor = [UIColor blueColor];
//    // 使window有效并显示
//    [self.window makeKeyAndVisible];
    // 将window作为主视图并显示
//    [self.window makeKeyAndVisible];
    
    // 设置根视图 
    // 无导航栏
    MyWindow* vc = [[MyWindow alloc] init];
    self.window.rootViewController = vc;
}
```

#### AppDelegate.m

```objc
@implementation AppDelegate

// 当程序框架初始化成功后调用此函数
// 用来初始化整个程序框架结构
// 整个程序对iOS开发工程师的入口函数
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    // 创建一个UIWindow对象
    // 整个程序只有一个UIWindow 对象, 属于window属性
    // 在程序基本上表示屏幕窗口
    // UIWindow 也继承于UIView
    // 是一种特殊的UIView
    
    // UIScreen 表示屏幕硬件表示类
    // mainScreen 获取主屏幕设备信息
    // bounds 表示屏幕的宽高值
//    self.window = [[UIWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
//    self.window.rootViewController = [[UIViewController alloc] init];
//    self.window.backgroundColor = [UIColor blueColor];
//    UIView* view = [[UIView alloc] initWithFrame: CGRectMake(100, 100, 150, 150)];
//    view.backgroundColor = [UIColor orangeColor];
//    [self.window addSubview: view];
//    // 使window有效并显示
//    [self.window makeKeyAndVisible];
    
    return YES;
}
```

#### ViewController.m

```objc
// 第一次程序加载视图时调用
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    UIView* view = [[UIView alloc] init];
    view.frame = CGRectMake(100, 100, 100, 200]; 
    view.backgroundColor = [UIColor orangeColor];
    self.view.backgroundColor = [UIColor blueColor];
    [self.view addSubview: view];
}
```

第一次程序加载视图时候会调用`viewDidLoad()`方法

当内存过低的时候会调用`didReceiveMemoryWarning()` 方法 

```objc
// 当内存过低时, 会发起警告, 调用此函数
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    ... 
}
```



视图分为: 

1. 显示前
2. 正在处于显示状态
3. 已经被隐藏 



当视图即将显示时候, 会调用`viewWillAppear: (BOOL)animated` 方法  

后面的BOOL类型参数表示是用动画切换后显示

```objc
// 当视图即将调用的时候, 会调用此函数
- (void)viewWillAppear:(BOOL)animated {
    NSLog(@"视图即将显示"); 
}
```





当视图已经显示到屏幕后的瞬间调用`viewDidAppear: (BOOL)animated` 函数 

参数: 表示是否用动画切换显示的 

当前状态已经显示到屏幕

```objc
// 当视图已经显示在屏幕后的瞬间调用吃函数
- (void)viewDidAppear: (BOOL)animated {
    NSLog(@"视图已经显示在屏幕");
}
```





当视图即将消失的时候, 会调用`viewWillDisappear: (BOOL)animated` 方法  

后面的BOOL类型参数表示是用动画切换后消失 

当前的状态: 视图还是显示在屏幕上的

```objc
// 当视图即将消失的时候, 会调用此函数
- (void)viewWillDisappear:(BOOL)animated {
    NSLog(@"视图即将消失"); 
}
```

  



当视图已经消失的时候, 会调用`viewDidDisappear: (BOOL)animated` 方法  

后面的BOOL类型参数表示是否动画切换显示的

当前的状态: 视图已经从屏幕上消失

```objc
// 当视图已经消失的时候, 会调用此函数
- (void)viewDisappear:(BOOL)animated {
    NSLog(@"视图已经消失");
}
```

  

### `viewWillAppear:` 和 `viewDidLoad` 的区别

+ `viewWillAppear: `在每一次显示都会调用
+ `viewDidLoad ` 只有在第一次加载视图的时候才会调用



## 透明度: alpha

