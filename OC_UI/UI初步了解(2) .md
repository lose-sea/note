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

# 定时器和视图移动

`NSTimmer` 定时器对象 

可以在每隔固定时间发送一个消息, 通过此消息来调用相应的时间函数, 可以通过此函数在固定时间段来发送一个根据时间间隔的的任务 

## 通过按钮来调用触发定时器 

设置一个定时器对象

```objc
@property (nonatomic, strong) NSTimmer* timerView;
```

首先来创建一个按钮

```objc
UIButton* btn = [UIButton buttonWithType: UIButtonTypeSystem];
btn.frame = CGRectMake(100, 200, 200, 80);

[btn setTitle: @"启动定时器" forState: UIControlStateNormal];
btn.backgroundColor = [UIColor redColor];
btn.titleLabel.font = [UIFont systemFontOfSize: 24];
```

给按钮设置时间来触发定时器

```objc
[btn addTarget: self action: @selector(pressStart) forControlEvents: UIControlEventTouchUpInside];
```

## 事件函数, 创建定时器

```objc
- (void) pressStart {
    if (_timerView == nil) {
        _timerView = [NSTimer scheduledTimerWithTimeInterval: 0.2 target: self selector: @selector(updateTimer:) userInfo: @"xinyan" repeats: YES];
    }
}
```

用`[NSTimer scheduleedTimerWithTimeInterval: targer: selector: userInfo: repeats:]` 方法创建了一个每隔 **0.2 秒**重复触发的定时器，每次触发时调用 `self` 的 `timerFired:` 方法，参数为 NSString类型的 “xinyan” , 可以重复调用的定时器 



**这里创建定时器的时候需要进行判空处理, 如果不判空, 就会导致创建定时器覆盖原先的定时器, 导致原先的定时器就无法关闭.** 

>    使用NSTimer类方法创建一个定时器并启动这个定时器  
>
>    + (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval
>                                         target:(id)target
>                                       selector:(SEL)selector
>                                       userInfo:(nullable id)userInfo
>                                        repeats:(BOOL)repeats;
>
>    参数说明: 
>
>    p1: 每隔多长时间调用定时器函数 (以秒为单位)
>
>    p2: 表示实现定时器函数的对象 (指针)
>
>    p3: 定时器函数对象
>
>    p4: 可以传定时器函数中一个参数, 无参数可以传: **nil**
>
>    p5: 定时器是否重复 **YES**: 重复, **NO**: 只完成一次
>
>    返回值为一个新建好的定时器对象

| 参数       | 类型           | 说明                               |
| ---------- | -------------- | ---------------------------------- |
| `interval` | NSTimeInterval | 触发间隔，单位秒                   |
| `target`   | id             | 接收消息的对象，通常是 `self`      |
| `selector` | SEL            | 定时器触发时调用的方法             |
| `userInfo` | id             | 传给回调的额外信息，不需要传 `nil` |
| `repeats`  | BOOL           | `YES` 重复触发，`NO` 只触发一次    |

在启动定时器之后,若定时器的repeats参数为YES; 就会一直调用事件, 要想要停止, 就需要废除定时器.  

与创建定时器一样, 同样设置一个按钮, 通过事件调用来废除已有的定时器

```objc
- (void) pressStop {
    if (_timerView != nil) {
        [_timerView invalidate];
        _timerView = nil;
    }
}
```

**这里在废除定时器的时候, 要进行置空处理, 否则在重新启动定时器的时候, 会因为定时器不为空从而不会创建新的定时器** 

通过定时器调用事件来实现视图的移动

```objc
    UIView* view = [[UIView alloc] init];
    view.backgroundColor = [UIColor systemOrangeColor];
    view.tag = 101;
```

创建一个UIView 对象, 加入的到当前的视图 

然后通过定时器调用事件改变UIView 的坐标, 来实现UIView 的移动效果

```objc
- (void) updateTimer: (NSTimer*) timer {
    NSLog(@"hello, %@", timer.userInfo);
    UIView* view = [self.view viewWithTag: 101];
    view.frame = CGRectMake(view.frame.origin.x + 5, view.frame.origin.y + 5, 60, 60);
}
```

# UISwitch 

创建 

**注意：UISwitch 大小固定，设置 frame 的宽高无效**

```objc
UISwitch *mySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(100, 100, 0, 0)];
[self.view addSubview:mySwitch];
```

常用属性 

```objc
// 设置/获取开关状态
mySwitch.on = YES;
BOOL state = mySwitch.isOn;

// 带动画切换状态
[mySwitch setOn:YES animated:YES];

// 开启时的颜色（默认绿色）
mySwitch.onTintColor = [UIColor blueColor];

// 关闭时的背景色
mySwitch.tintColor = [UIColor redColor];

// 圆形滑块颜色
mySwitch.thumbTintColor = [UIColor whiteColor];
```

通过开关的状态来调用事件

```objc
// 添加事件
[mySwitch addTarget:self
             action:@selector(switchChanged:)
   forControlEvents:UIControlEventValueChanged];

- (void)switchChanged:(UISwitch *)sender { 
    NSLog(@"开关的状态发生变化"); 
    if (sender.isOn) {
        NSLog(@"开启");
    } else {
        NSLog(@"关闭");
    }
}
```

这里调用事件的时候, 开关的状态是指改变后的状态

