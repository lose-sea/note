# GCD 

GCD 全称：**Grand Central Dispatch**,

它是 Apple 提供的一套**并发编程 API**。最简单地说：**GCD 负责把任务提交给队列，然后由系统负责调度这些任务执行。** 



## 理解任务, 队列, 线程

先看下面一段代码: 

`````objc
dispatch_async(dispatch_get_global_queue(0, 0), ^{
    NSLog(@"Hello GCD");
});
`````

在这段代码中, 实际上有三个东西: 

任务 -> 队列 -> GCD调度执行

代码中的

```objc
	^{
    NSLog(@"Hello GCD");
}
```

是任务, 而

```objc
dispatch_async(...)
```

是队列, 最后

```objc
dispatch_async(...)
```

就是 **把任务提交给队列**

**注意: 队列不是线程**

任务就是 **我要干什么**

例如: 

```objc
^{
    NSLog(@"下载图片");
}
```

这是一个任务

```objc
^{
    int a = 10;
    int b = 20;
    NSLog(@"%d", a + b);
}
```

这也是一个任务

队列可以理解为任务的管理者, 例如: 

```objc
队列
│
├── 任务 A
├── 任务 B
├── 任务 C
└── 任务 D
```

GCD 会根据队列的规则决定这些任务应该按照什么方式被调度

线程才是真正执行代码的执行实体

## 为什么需要GCD

假如需要加载一张很大的照片

```objc
UIImage *image = [self loadBigImage];
```

这个操作非常耗时

如果它发生在主线程, 就会发生:  `主线程 -> 加载图片 -> 等待 -> 等待 -> 等待 -> UI卡住`

用户就会看到APP卡顿, 界面无法响应, 我们希望: 主线程负责UI, 后台线程负责耗时任务

GCD就可以帮我们完成任务调度, 例如: 

```objc
dispatch_async(dispatch_get_global_queue(0, 0), ^{
    
    UIImage *image = [self loadBigImage];

    dispatch_async(dispatch_get_main_queue(), ^{
        
        self.imageView.image = image;
        
    });
});
```

这里就出现了非常经典的 iOS 开发模式: 

`后台执行耗时操作 -> 得到结果 -> 回到主线程更新 UI`

## 队列

队列有两个核心属性: 

+ 串行 Serial: 一次执行一个任务
+ 并发 Concurrent: 允许多个任务人同时执行

### 串行队列

```objc
    dispatch_queue_t queue = dispatch_queue_create("com.demo.serial", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
        NSLog(@"任务 A");
    });
    dispatch_async(queue, ^{
        NSLog(@"任务 B");
    });
    dispatch_async(queue, ^{
        NSLog(@"任务 C");
    });
}
```

这个队列是串行(Serial) 队列, 所以一定满足: **同一时刻最多执行一个任务**



### 并发队列

```objc
    dispatch_queue_t queue = dispatch_queue_create("com.demo.current", DISPATCH_QUEUE_CONCURRENT);
    dispatch_async(queue, ^{
        sleep(2); 
        NSLog(@"任务 A");
    });
    dispatch_async(queue, ^{
        NSLog(@"任务 B");
    });
    dispatch_async(queue, ^{
        NSLog(@"任务 C");
    });
}
```

并发队列中多个任务可以同时执行

这里有一个需要注意的地方就是:  这里并发队列不一定创建了三个线程

**队列只负责描述任务应该如何被调度**, 真正使用多少线程, 由系统的线程池和调度机制决定

## sync 和 async

`dispatch_sync` 和 `dispatch_async` 也就是 同步提交和异步提交, 这里的 sync 和 async 首先描述的是 提交任务的那个线程, 要不要等待任务执行结束, 而不是 sync = 主线程, async = 子线程 

### 什么是 async

看下面代码: 

```objc
    dispatch_async(queue, ^{
        NSLog(@"task");
    }); 
```

这里可以理解为: 把任务提交给queue, 然后当前线程不用等待这个任务执行完成, 继续向下执行. 

```objc
    dispatch_queue_t queue = dispatch_queue_create("com.demo.current", DISPATCH_QUEUE_CONCURRENT);
    NSLog(@"1");
    dispatch_async(queue, ^{
        NSLog(@"2");
    });
    NSLog(@"3");
```

这里的执行结果是

![image-20260903201457395](/Users/lose_sea/Desktop/pintures/image-20260903201457395.png)

这是因为: 

```
NSLog(@"1");
   ↓
提交任务 2
   ↓
不等待
   ↓
NSLog(@"3")
```

与此同时：

```
任务 2
 ↓
等待 queue 调度
 ↓
执行
```

### 什么是 sync

```objc
dispatch_sync(queue, ^{
    NSLog(@"2");
});
```

这里意思是: 把任务提交给 queue, 然后当前线程必须等待这个任务执行结束, 才能继续往下走. 



所以：

```objc
NSLog(@"1");

dispatch_sync(queue, ^{
    NSLog(@"2");
});

NSLog(@"3");
```

执行顺序一定是：

```
1
↓
2
↓
3
```

因为 `sync` 会等待。



这是 GCD 学习中非常重要的第一条公式：

```
sync
=
提交任务
+
等待任务执行完成
+
当前线程继续
```

而：

```
async
=
提交任务
+
不等待
+
当前线程继续
```

### **并发队列和串行队列与sync 和 async 的关系**

> **`sync/async` 决定“是否阻塞当前线程”和“是否可能开新线程”**
> **`串行/并发队列` 决定“任务如何被取出执行”（一个接一个 vs 同时多个）**



**同步异步函数**
同步函数（sync）和异步函数（async），只能决定能否开启新的线程执行任务，不能决定函数是串行执行还是并行执行

同步:

+ 在当前线程中执行,不具备开启新线程的能力
+ 队列后面的内容需要等到同步函数返回后才可以继续执行

异步: 

+ 拥有开创新线程的能力, 但是不一定会开启新线程
+ 后面的内容不需要等异步函数返回后执行,后面的内容可以直接执行,所以需要开启新线程,因此具备开启新线程的能力



**同步函数: 同步函数会阻塞当前函数的返回, 异步函数会立即执行,执行下面的代码**

> 同步函数后面的内容要等到同步函数返回才可以执行,异步函数后面的内容不需要等异步函数返回才执行,可以直接执行,异步函数里面的内可能需要开启一个新线程来执行

**串行并行队列**
主要影响任务的执行方式.能不能开启新线程取决于上面的函数

并发:多个任务并发执行

串行:一个任务执行完毕后才去执行下一个任务

| 函数       | 队列类型     | 是否开新线程 | 执行方式   | 是否阻塞当前线程 |
| :--------- | :----------- | :----------- | :--------- | :--------------- |
| `async`    | 并发队列     | ✅ 多个       | **并发**   | ❌                |
| `async`    | 串行队列     | ✅ 1个        | **串行**   | ❌                |
| `async`    | 主队列       | ❌            | **串行**   | ❌                |
| **`sync`** | **并发队列** | ❌            | **串行**   | ✅                |
| **`sync`** | **串行队列** | ❌            | **串行**   | ✅                |
| `sync`     | 主队列       | ❌            | **💀 死锁** | ✅                |

**"async/sync 的优先级在队列之上"**

准确地说应该是：

> **`sync/async` 决定"执行机制"（是否阻塞、是否开线程）**
> **队列类型决定"调度策略"（串行还是并发）**
> **但 `sync/async` 的约束会覆盖队列的特性**

## 主队列, 主线程与死锁 

### 什么是主队列

`dispatch_get_queue()`, 它返回的就是: 

主队列: `dispatch_get_main_queue() ` 

**主队列是一个特殊的串行队列**

### 主队列与主线程

**主队列与主线程是两个不同的东西**

```objc
主队列
    ↓
负责管理提交给它的任务

主线程
    ↓
真正执行代码
```

但是主队列和主线程之间存在非常紧密的关系: 

```objc
Main Queue
     ↓
任务
     ↓
Main Thread
     ↓
执行
```

所以在正常情况下, **提交到主线程的任务, 会在主线程执行**

### 死锁（Deadlock）

 **什么是死锁**

**死锁发生在“同步（Sync）” + “当前串行队列”**。
经典的错误代码如下，运行必崩溃：

```objc
// 这段代码跑在主线程（主队列是串行的）
dispatch_sync(dispatch_get_main_queue(), ^{
    NSLog(@"我执行了吗？"); // 永远不会打印！APP卡死！
});
```

主队列是串行的，里面正放着当前这个 `viewDidLoad` 任务。现在往主队列里同步追加一个Block，同步意味着“我必须等你执行完，我才能往下走”。但主队列在等 `viewDidLoad` 执行完才能处理Block，而 `viewDidLoad` 在等Block执行完才结束。**互相等待 -> 死锁**。

## 全局队列

```objc
dispatch_get_global_queue() 
```

什么是全局队列

```objc
dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
```

它是Apple提供的系统队列

特点: 并发队列

它类似: Concurrent Queue, 可以同时执行多个任务

