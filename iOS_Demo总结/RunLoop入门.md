# RunLoop

RunLoop 本质上是一个事件循环机制, 让线程在没有任务是休眠, 有事件时被唤醒并处理事件 

普通线程：

```objc
- (void)threadMain {
    NSLog(@"开始执行");

    // 执行完
    // 线程结束
}
```

如果希望线程一直存活：

```objc
while (YES) {
    // 等待任务
}
```

这种方式会导致 CPU 空转。 

RunLoop 解决的就是：

```
        没有事件
           ↓
       线程进入休眠
           ↓
        有事件到来
           ↓
       唤醒线程
           ↓
       处理事件
           ↓
        继续等待
```

所以可以把它理解成：

> **RunLoop = 线程的“事件调度中心” + 休眠/唤醒机制** 



 **RunLooP作用**

+ 保持线程 (尤其是主线程) 持续运行, 不退出
+ 处理 App 中的各种事件 (触摸, Timer, performSelector, GCD主队列任务, 界面刷新) 
+ 节省CPU 资源: 有事做事, 无事休眠

## RunLoop 和 线程的关系

一个线程对应一个RunLoop, 但不是说每个线程启动后都有一个已经运行的RunLoop, 

主线程: 

```objc
    NSRunLoop* runLoop = [NSRunLoop mainRunLoop]; 
```

主线程的RunLoop会被系统自动启动 

子线程则不同: 

```objc
NSThread *thread = [[NSThread alloc] initWithBlock:^{
    NSLog(@"子线程");

    [[NSRunLoop currentRunLoop] run];
}];

[thread start];
```

如果不调用: `[[NSRunLoop currentRunLoop] run];`,那么子线程执行完任务之后就结束了



+ 主线程的 RunLoop 在App启动时自动创建并执行 
+ 子线程默认没有RunLoop, 需要手动获取并启动 (否则线程执行完成任务就退出) 



## 为什么 RunLoop 能让线程休眠

底层并不是简单的：

```objc
while (1)
```

而是：

```
RunLoop
   ↓
检查有没有事件
   ↓
有事件 → 处理
   ↓
没事件 → 让线程进入休眠
   ↓
Mach Port / Source / Timer 等事件到来
   ↓
系统唤醒线程
```

所以 RunLoop 的核心价值之一就是：

> **避免线程在没有任务的时候持续占用 CPU。**

 **RunLoop的核心组成: Mode, Source, Timer, Observer** 

## RunLoop Mode (运行模式)

RunLoop 并不是把所有的事件全部一起处理, 它通过Mode对事件进行分类

Mode：

| Mode 名称                                    | 说明                                                         |
| -------------------------------------------- | ------------------------------------------------------------ |
| kCFRunLoopDefaultMode / NSDefaultRunLoopMode | 默认模式，App 平时运行在这里                                 |
| UITrackingRunLoopMode                        | 界面追踪模式（UIScrollView 滑动时切换到这个模式）            |
| kCFRunLoopCommonModes / NSRunLoopCommonModes | **伪模式 / 标记**，不是真实 Mode。默认包含 Default + Tracking |
| UIInitializationRunLoopMode                  | App 启动时的临时 Mode，启动完成后不再使用                    |
| GSEventReceiveRunLoopMode                    | 系统内部接收事件用（一般碰不到）                             |

常见的 Mode 有: 

```objc
NSDefaultRunLoopMode
NSRunLoopCommonModes
UITrackingRunLoopMode
```

主线程的 RunLoop 是在 UIApplicationMain 内部自动创建并启动的 (最终调用CFRunLoop), 所以App可以一直运行

#### Timer 在滚动的时候会失效

例如: 

```objc
[NSTimer scheduledTimerWithTimeInterval:1
                                 target:self
                               selector:@selector(test)
                               userInfo:nil
                                repeats:YES];
```

默认Timer被加入 **`NSDefaultRunLoopMode`**

那么这时候有一个TableView, 在滑动TableView的时候, Timer就会失效

这是因为在UITableView上滑动的时候: 

```objc
RunLoop
    ↓
进入 UITrackingRunLoopMode
    ↓
Default Mode 暂时不处理
    ↓
Timer 不触发
```

那么如何解决这个问题呢? 

只需要将 Timer 加入到 `NSRunLoopCommonModes` 就可以解决这个问题

```objc
NSTimer *timer =
[NSTimer timerWithTimeInterval:1
                         target:self
                       selector:@selector(test)
                       userInfo:nil
                        repeats:YES];

[[NSRunLoop mainRunLoop] addTimer:timer
                          forMode:NSRunLoopCommonModes];
```



### NSRunLoopCommonModes

`NSRunLoopCommonModes` 不是一个独立运行的 Mode 

它可以理解为 Mode集合, 包含多个Common Mode 

当把 Timer 加入到 `NSRunLoopCommonModes` , 就是相当于就把 Timer 添加到当前RunLoop标记为  Common 的那些 Mode 中 

## RunLoop 的 Source 

Source 是 RunLoop 的事件来源

常见可以分为: 

**Source 0**

需要手动唤醒/处理的事件源 

例如: 

```objc
performSelector
```

这类机制可以和 Source 0 联系起来 

**Source 1**

 基于 Mach Port 等底层事件机制

例如: 

```objc
触摸事件
IPC
系统事件
```

可以粗略理解为：

```
Source 1
    ↓
底层事件到达
    ↓
唤醒 RunLoop
    ↓
处理事件
```

## Timer

`NSTimer` 也是RunLoop 的一个输入源, 这里需要注意的是: NSTimer 本身不是一个独立线程

例如: 

```objc
NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval: 1
                                                  target: self
                                                selector: @selector(sayHello)
                                                userInfo: nil
                                                 repeats: YES];
```

Timer 是注册到 RunLoop 中

```objc
NSTimer
   ↓
RunLoop
   ↓
时间到了
   ↓
RunLoop 检查
   ↓
执行 selector
```

如果 RunLoop 不运行, NSTimer 就不会正常触发 



```objc
- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. 创建一个 Timer，每隔 1 秒执行一次 tick 方法
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0 
                                                      target:self 
                                                    selector:@selector(tick) 
                                                    userInfo:nil 
                                                     repeats:YES];
    
    for (int i = 0; i < 5; i++) {
        sleep(1); // 休眠 1 秒，模拟重度计算
        NSLog(@"正在计算... 第 %d 秒", i + 1);
    }
}

- (void)tick {
    NSLog(@"定时器触发！");
}
```

打印: 

`````
正在计算... 第 1 秒
正在计算... 第 2 秒
正在计算... 第 3 秒
正在计算... 第 4 秒
正在计算... 第 5 秒
定时器触发
`````

从上面的代码运行结果可以观察到, 定时器事件在for循环结束之前没有触发

让我们看看 CPU 实际执行指令的顺序: 

`````
// ========== RunLoop 的伪代码 ==========
function CFRunLoopRun() {
    while (true) {                        // ← RunLoop 的 while 循环
        // 1. 检查 Timer
        // 2. 检查 Source
        // 3. 如果没有事件，休眠
        // 4. 如果有事件，执行它
        
        if (有事件需要处理) {
            // 这里会调用你的代码
            [target performSelector:action];  // ← 在这里调用了 viewDidLoad
            // 你的代码执行完后，才继续下一轮循环
        }
    }
}
`````



## Observer

Observer 用来监听 RunLoop 的状态变化

例如: 

```objc
RunLoop 即将进入
        ↓
处理 Timer
        ↓
处理 Source
        ↓
即将休眠
        ↓
被唤醒
        ↓
退出 RunLoop
```

 

可以通过`CFRunLoopObserver` 监听

常见状态: 

```objc
kCFRunLoopEntry
kCFRunLoopBeforeTimers
kCFRunLoopBeforeSources
kCFRunLoopBeforeWaiting
kCFRunLoopAfterWaiting
kCFRunLoopExit
```

## RunLoop 一次完整运行过程



```
          RunLoop 开始
               ↓
        BeforeTimers
               ↓
        BeforeSources
               ↓
       处理 Timer / Source
               ↓
        是否还有事件？
          ↙          ↘
        有             没有
        ↓               ↓
      继续          BeforeWaiting
                        ↓
                     休眠
                        ↓
              事件到达 / Timer 到期
                        ↓
                  AfterWaiting
                        ↓
                  处理事件
                        ↓
                     循环
```

可以把它浓缩成：

```
进入
 ↓
处理事件
 ↓
没有事件
 ↓
休眠
 ↓
被唤醒
 ↓
处理事件
 ↓
循环
```

## RunLoop 和 线程保活

比如创建一个常驻线程: 

```objc
    NSThread* thread = [[NSThread alloc] initWithBlock:^{
        
        [[NSRunLoop currentRunLoop] addPort:
               [NSPort port]
               forMode:NSDefaultRunLoopMode];

           [[NSRunLoop currentRunLoop] run];
    }];
```

**`NSThread* thread = [[NSThread alloc] initWithBlock:^{ ... }];`** 

+ 作用: 创建一个新的子线程对象
+ `initWithBlock`: 告诉这个线程; “当启动时候,执行 Block 里面的代码” 
+ 此时,线程还没有启动, 知识准别好了 

```objc
 [[NSRunLoop currentRunLoop] addPort:
       [NSPort port]
       forMode:NSDefaultRunLoopMode];

   [[NSRunLoop currentRunLoop] run];
```

**`[NSRunLoop currentRunLoop]`**

+ 获取当前线程的 RunLoop 
+ 因为这段代码写在 Block 里, 而 Block 会在子线程中执行, 所以这里拿到的是子线程的 RunLoop 

**`[NSPort port]`** 

+ 创建一个 Port (端口) 
+ 可以把它理解成一个虚拟的 “信箱“,, 有了这个信箱, RunLoop 就会认为: “我有东西要监听,不能退出”

**`add:forMode:`**

+ 把上面的信箱加入到 RunLoop 中 
+ 作用: 给RunLoop添加一个永久有效的事件源, 让它有事可做, 不会空转退出

**`[thread start]`**

+ 启动子线程
+ 这时, 子线程开始执行 Block 里的代码

###  为什么必须要有 `addPort`？

这是一个**极其关键**的问题。

### 没有 `addPort` 的情况：

```
[[NSRunLoop currentRunLoop] run];
```

+ RunLoop 启动后，会检查自己有没有**事件源**（比如 Timer、Port、Observer）。
+ 如果**什么都没有**，RunLoop 会认为：“我没事可做，没必要继续跑。”
+ 于是，**RunLoop 立即退出**，子线程执行完所有代码，**线程被销毁**。

### 有 `addPort` 的情况：

```
[[NSRunLoop currentRunLoop] addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
[[NSRunLoop currentRunLoop] run];
```



+ 添加 Port 后，RunLoop 发现：“我有一个 Port 要监听，我不能退出。”
+ 于是，**RunLoop 进入永久等待状态**，线程永不销毁。

## RunLoop 与 performSelector

`performSelector` 是 **NSObject** 提供的一系列方法，允许你**延迟执行**或**在指定线程上执行**某个方法。

```objc
[self performSelector:@selector(test)
             onThread:thread
           withObject:nil
        waitUntilDone:NO];
```

### 常见的几种形式：

| 方法                                                         | 作用                     |
| :----------------------------------------------------------- | :----------------------- |
| `[obj performSelector:@selector(method)]`                    | 在当前线程立即执行       |
| `[obj performSelector:withObject:afterDelay:]`               | 延迟执行（依赖 RunLoop） |
| `[obj performSelector:onThread:withObject:waitUntilDone:]`   | 在指定线程执行           |
| `[obj performSelectorOnMainThread:withObject:waitUntilDone:]` | 在主线程执行             |
