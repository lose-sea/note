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

## RunLoop Mode

RunLoop 并不是把所有的事件全部一起处理, 它通过Mode对事件进行分类

常见的 Mode 有: 

```objc
NSDefaultRunLoopMode
NSRunLoopCommonModes
UITrackingRunLoopMode
```

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

## TImer 

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

