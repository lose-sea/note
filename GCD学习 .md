 

[TOC]



# GCD

GCD是苹果基于C语言打造的一套**线程池管理框架**。你不需要手动创建或销毁线程，只需要把任务（Block）扔进队列（Queue）里，GCD会自动帮你调度CPU资源。

### 第一阶段：认知篇——两个核心概念

在敲代码之前，必须死磕两个概念：**队列（Queue）** 和 **任务（Task）**。

1. **任务（Task）**：就是你放在 `block` 里的那段代码。GCD只有两种执行方式：
   + **同步执行（Sync）**：`dispatch_sync`。函数不返回，任务不执行完，当前线程就卡在那里不动（阻塞）。
   + **异步执行（Async）**：`dispatch_async`。函数立即返回，任务被丢到后台排队，当前线程爱干嘛干嘛，不阻塞。
2. **队列（Queue）**：存放任务的“容器”，遵循**先进先出（FIFO）**原则。队列只有两种类型：
   + **串行队列（Serial）**：任务一个个按顺序执行，前一个没干完，后一个永远等着。
   + **并发队列（Concurrent）**：任务虽然是按顺序“取出”的，但GCD会把它丢给多个空闲线程**同时**执行（注意：同时执行的数量由系统内核决定）。

> **核心铁律（必记）**：
> **同步（Sync）** 只负责“等待”，不具备开启新线程的能力；
> **异步（Async）** 具备开启新线程的能力，但**不一定**会开（如果是在主队列异步，就不会开新线程）。

------

### 第二阶段：用法篇——系统提供的4个队列

苹果已经给你准备好了现成的队列，你不用自己创建：

1. **主队列（Main Queue）**：`dispatch_get_main_queue()`
   + 本质是一个**串行队列**，运行在主线程上。
   + **专门负责刷新UI**。所有关于界面的操作（改Label、换图片）都必须在这里执行。
2. **全局并发队列（Global Queue）**：`dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)`
   + 本质是一个**并发队列**，系统提供了4个优先级（High、Default、Low、Background）。
   + 专门用来执行**耗时操作**（网络请求、读写大文件、复杂计算）。



#### 队列类型

| 类型                         | 说明                               | 常用场景                   |
| ---------------------------- | ---------------------------------- | -------------------------- |
| **串行队列（Serial）**       | 同一时间只执行一个任务，按顺序执行 | 保护共享资源、保证执行顺序 |
| **并发队列（Concurrent）**   | 可以同时执行多个任务               | 多个独立的耗时任务         |
| **主队列（Main Queue）**     | 特殊的串行队列，绑定主线程         | **所有 UI 更新必须放这里** |
| **全局队列（Global Queue）** | 系统提供的并发队列                 | 大多数后台任务             |

------

### 第三阶段：进阶篇——必须攻克的“死锁”与“线程通信”

这是面试必考题，也是你写出不卡顿App的关键。

#### 1. 什么是死锁（Deadlock）？

**死锁发生在“同步（Sync）” + “当前串行队列”**。
经典的错误代码如下，运行必崩溃：

objectivec

```
// 这段代码跑在主线程（主队列是串行的）
dispatch_sync(dispatch_get_main_queue(), ^{
    NSLog(@"我执行了吗？"); // 永远不会打印！APP卡死！
});
```



**原理图解**：主队列是串行的，里面正放着当前这个 `viewDidLoad` 任务。现在你往主队列里同步追加一个Block，同步意味着“我必须等你执行完，我才能往下走”。但主队列在等 `viewDidLoad` 执行完才能处理Block，而 `viewDidLoad` 在等Block执行完才结束。**互相等待 -> 死锁**。

#### 2. 线程通信（回到主线程更新UI）

这是日常开发使用频率最高的代码模板：

objectivec

```
// 1. 在后台（全局并发队列）异步执行耗时任务
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    // 这里做网络请求或解析数据
    NSData *data = [NSData dataWithContentsOfURL:url];
    
    // 2. 异步回到主队列（注意！用的是异步，防止死锁）
    dispatch_async(dispatch_get_main_queue(), ^{
        // 这里刷新UI
        self.label.text = @"下载完成";
    });
});
```



------

### 第四阶段：实战篇——GCD在实际开发中的3大杀手锏

只懂理论不会用等于零，我直接给你上工作中最常用的三种场景代码：

#### 1. 栅栏函数（dispatch_barrier_async）——处理“读写锁”

**场景**：多线程读取同一个可变数组没问题，但**写入**时必须阻塞所有读取。
**用法**：在并发队列中，栅栏之前的任务会全部先执行完，栅栏执行期间队列阻塞，栅栏执行完后再恢复并发。

objectivec

```
// 必须使用自己创建的并发队列，不能用全局队列
dispatch_queue_t queue = dispatch_queue_create("com.data.queue", DISPATCH_QUEUE_CONCURRENT);

// 读操作：可以并发
dispatch_async(queue, ^{ NSLog(@"读1"); });
dispatch_async(queue, ^{ NSLog(@"读2"); });

// 写操作：栅栏会等待读1、读2完成，并阻止后面的任务开始
dispatch_barrier_async(queue, ^{
    NSLog(@"⚠️正在写入数据，禁止任何访问");
    // 写入NSMutableArray等操作
});

// 栅栏执行完后，继续并发读取
dispatch_async(queue, ^{ NSLog(@"读3"); });
```



#### 2. 信号量（dispatch_semaphore）——控制最大并发数

**场景**：同时发起100个网络请求，服务器扛不住。我只允许同时最多发5个。

objectivec

```
// 创建信号量，初始值设为5
dispatch_semaphore_t semaphore = dispatch_semaphore_create(5);
for (int i = 0; i < 100; i++) {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        // 资源-1，如果当前已经发了5个，这里会阻塞等待
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        
        NSLog(@"开始请求 %d", i);
        // 模拟网络请求耗时
        [NSThread sleepForTimeInterval:1];
        NSLog(@"结束请求 %d", i);
        
        // 资源+1，释放一个并发位置
        dispatch_semaphore_signal(semaphore);
    });
}
```



#### 3. 调度组（dispatch_group）——监听多个异步任务都完成

**场景**：界面上有3个独立的接口需要同时去请求，等3个全部返回后，统一刷新UI。

objectivec

```
dispatch_group_t group = dispatch_group_create();

// 进入组（注意配对）
dispatch_group_enter(group);
dispatch_async(dispatch_get_global_queue(0, 0), ^{
    [NSThread sleepForTimeInterval:1]; // 模拟请求1
    NSLog(@"接口1完成");
    dispatch_group_leave(group);
});

dispatch_group_enter(group);
dispatch_async(dispatch_get_global_queue(0, 0), ^{
    [NSThread sleepForTimeInterval:2]; // 模拟请求2
    NSLog(@"接口2完成");
    dispatch_group_leave(group);
});

// 全部完成后通知主线程
dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    NSLog(@"所有接口完成，刷新UI！");
});
```

