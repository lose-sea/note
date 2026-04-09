# main.m

整个APP程序的入口是main 函数 

整个App程序的主函数, 入口函数

```objc
int main(int argc, char * argv[]) {
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
```

> UIKit框架结构的启动函数
>  参数一: argc: 启动时带有参数的个数
>  参数二: argv[] 参数列表
>  参数三: 要求传入一个主框架类对象, 如果为nil, 系统会自动用默认的框架作为主框架类名
>  参数四: 主框架的代理类对象名字

```objc
return UIApplicationMain(argc, argv, nil, appDelegateClassName); 
```

# AppDelegate.m

当程序框架初始化成功后调用一下函数, 用来初始化整个框架结构, 是整个程序iOS开发工程师的入口函数

```objc
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    return YES;
}
```

创建一个视图对象 

`UIView* view = [[UIView alloc] initWithFrame: [UIScreen mainScreen].bounds];` 

> 1. `UIScreen`: 表示屏幕硬件类 
> 2. mainScreen. 获取主屏幕的信息 (当前手机屏的大小) 

# UIController 控制器

所有的视图控制器都是继承于 官方的UIViewController 

当视图控制器第一次加载视图时, 调用 `viewDidLoad`方法, 功能是初始化视图, 初始化资源

```objc
// 第一次程序加载视图时调用
- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"第一次加载视图"); 
}
```



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



当系统内存过低时, 会发起警告信息, 同时调用 `didReceiveMemoryWarning` 方法

```objc
- (void) didReceiveMemoryWarning { 
    [super didReceiveMenoryWarning]; 
    NSLog(@"内存过低"); 
}
```

