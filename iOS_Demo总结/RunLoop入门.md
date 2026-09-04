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

### RunLoop Mode

RunLoop 并不是把所有的事件全部一起处理, 它通过Mode对事件进行分类

常见的 Mode 有: 

```objc
NSDefaultRunLoopMode
NSRunLoopCommonModes
UITrackingRunLoopMode
```

