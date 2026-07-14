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

