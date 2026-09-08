[TOC]

# GCD常用高级API

常用的高级API有: 

+ dispatch_once 单例
+ dispatch_group 多任务完成通知
+ dispatch_barrier 读写锁思想
+ dispatch_semapbore 控制并发数量

## dispatch_once: 只执行一次

这是GCD最简单, 也是最经典的API 



```objc
- (void) viewDidLoad { 
    [super viewDidLoad]; 
    for (int i = 0; i < 4; i++) {
        [self test];
        NSLog(@"执行完成");
    }
}

- (void) test {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"只执行一次");
    });
}
```

打印结果如下: 

![image-20260908170926757](/Users/lose_sea/Desktop/pintures/image-20260908170926757.png) 

可以观察到, 无论这个代码被调用多少次, 最终Block 只会执行一次

### 最经典的用途: 单例 

```objc
+ (instancetype)sharedInstance {
    static MyManager *instance;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MyManager alloc] init];
    });
    
    return instance;
}
```

第一次：

```objc
调用 sharedInstance
        ↓
dispatch_once
        ↓
创建 instance
        ↓
返回
```

第二次：

```objc
调用 sharedInstance
        ↓
发现已经执行过
        ↓
不再执行 Block
        ↓
直接返回 instance
```

### 为什么这里不用 if 

可能有人会想到: 

```objc
static MyManager *instance;

if (instance == nil) {
    instance = [[MyManager alloc] init];
}
```

这段代码在单线程的情况下看起来没问题

但是如果是多线程

```objc
线程 A                  线程 B

instance == nil         instance == nil
       ↓                       ↓
创建 instance            创建 instance
```

两个线程可能同时进入, 这就是典型的 **竞态问题**

dispatch_once 专门解决这种: 某段代码在整个进程生命周期中只需要安全地执行一次

## dispatch_after 

```objc 
    NSLog(@"start");
    
    dispatch_after(
       dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
       dispatch_get_main_queue(), ^{
           NSLog(@"2秒后");
       }
    );
```

看起来像: 2 秒后执行, 但是更准确地说: **至少等待执行时间后, 再把任务提交到指定队列** 

### 它不是“创建一个定时线程”

错误理解：

```
dispatch_after
      ↓
创建线程
      ↓
睡眠2秒
      ↓
执行
```

不是这样。

可以理解成：

```
dispatch_after
      ↓
等待时间到达
      ↓
任务变得可以被调度
      ↓
提交到 queue
      ↓
queue 决定什么时候执行
```

所以 dispatch_after 并不是严格保证 2 秒后的时候执行, 而是: 2 秒后才有资格执行

## dispatch_group: 等待多个异步任务完成

这是非常重要的的API 

假设：

```
下载图片 A
下载图片 B
下载图片 C

全部完成以后
刷新 UI
```

如果分别：

```objc
dispatch_async(queue, ^{
    // A
});

dispatch_async(queue, ^{
    // B
});

dispatch_async(queue, ^{
    // C
});
```

我们不知道什么时候三个任务全部完成。

这时候使用：

```objc
dispatch_group_t group =
    dispatch_group_create();
```

### group_enter / group_leave

```objc
    dispatch_queue_t queue =  dispatch_queue_create("concurrent_queue", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    dispatch_async(queue, ^{
        NSLog(@"A完成");
        
        dispatch_group_leave(group);
        
    });
    
    dispatch_group_enter(group);
    dispatch_async(queue, ^{
        NSLog(@"B完成");
        dispatch_group_leave(group);
    });
    
    dispatch_group_enter(group);
    dispatch_async(queue, ^{
        NSLog(@"C完成");
        dispatch_group_leave(group);

    });
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSLog(@"A, B, C 全部完成");
    });
```

理解成一个计数器：

```
enter
  ↓
+1

enter
  ↓
+1

enter
  ↓
+1

当前：
3
```

A 完成：

```
leave
 ↓
2
```

B 完成：

```
leave
 ↓
1
```

C 完成：

```
leave
 ↓
0
```

然后：

```
notify
 ↓
执行
```

### group 的核心思想

可以把它记成：

```
多个任务
   ↓
Group
   ↓
全部完成
   ↓
Notify
```

实际开发非常常见的模式：

```
请求用户信息
       \
        \
请求订单信息 ----→ 全部完成 → 刷新页面
        /
请求商品信息
```

### dispatch_group_async 

如果任务本身就是通过GCD提交, 可以进一步简化

```objc
dispatch_group_t group =
    dispatch_group_create();

dispatch_group_async(group, queue, ^{
    NSLog(@"A");
});

dispatch_group_async(group, queue, ^{
    NSLog(@"B");
});

dispatch_group_async(group, queue, ^{
    NSLog(@"C");
});

dispatch_group_notify(
    group,
    dispatch_get_main_queue(),
    ^{
        NSLog(@"全部完成");
    }
);
```



dispatch_group_async 的写法是系统自动管理 enter 和 leave, 不需要手动调用 

#### 使用场景: 

| 使用场景                                                     | 推荐写法                                        | 是否需要手动 enter/leave           |
| :----------------------------------------------------------- | :---------------------------------------------- | :--------------------------------- |
| **任务内部没有异步操作**（如：计算、读写文件、sleep）        | `dispatch_group_async`                          | 不需要，系统自动管理               |
| **任务内部有异步回调**（如：网络请求、GCD 延迟、UIView 动画） | `dispatch_group_enter` + `dispatch_group_leave` | 需要手动管理，在回调里调用 `leave` |

### notify 和 wait 

Group 有两个非常重要的方法

```objc
dispatch_group_notify()
dispatch_group_wait()
```

#### notify

```objc
dispatch_group_notify(group, queue, ^{
    NSLog(@"完成"); 
}); 
```

特点: 异步等待

当前线程: 

提交 notify -> 继续执行 

**wait**

```objc
dispatch_group_wait(group, DISPATCH_TIME_FOREVER); 
```

特点: 当前线程阻塞等待

这和之前的 sync 与 async 是一样的 



## diaptch_barrier: 并发队列中的“屏障” 

假设有：

```
读取
读取
读取
写入
读取
读取
```

我们希望：

```
读1 ──────
读2 ──────
读3 ──────

        ↓

写入

        ↓

读4 ──────
读5 ──────
```

也就是：

> 前面的读任务全部完成以后，执行写任务；写任务完成以后，后面的读任务才能执行。

这就是 barrier。 

代码

```objc
dispatch_queue_t queue =
    dispatch_queue_create(
        "com.demo.database",
        DISPATCH_QUEUE_CONCURRENT
    );

dispatch_async(queue, ^{
    NSLog(@"读 A");
});

dispatch_async(queue, ^{
    NSLog(@"读 B");
});

dispatch_barrier_async(queue, ^{
    NSLog(@"写入");
});

dispatch_async(queue, ^{
    NSLog(@"读 C");
});

dispatch_async(queue, ^{
    NSLog(@"读 D");
});
```

可以理解成：

```
       Concurrent Queue

A ──────────────┐
B ──────────────┤
                ↓
             Barrier
                ↓
             写入
                ↓
C ──────────────┐
D ──────────────┘
```



 **barrier 不是所有队列都有效**

> `dispatch_barrier_async` 真正具有上述屏障意义, 主要针对: **自己创建的 concurrent queue**, 在全局队列或者串行队列上, `dispatch_barrier_async`   的行为会退化为普通的`dispatch_async`  ,完全失去隔离效果



## dispath_semaphore: 信号量

假设有100个任务 ,但是同时最多允许 3  个任务执行,怎么办, 这个时候使用 semaphore 非常合适



### 创建 semaphore

```objc
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(3); 
```

这里参数中的 3 可以理解成 3 个“许可证”

第一个任务 `dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER); ` 拿走一个“许可证”, 执行任务

完成任务后, `dispatch_semaphore_signal(semaphore)` “归还许可证”

```objc
dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    
    dispatch_queue_t queue = dispatch_queue_create("concurrent_queue", attr);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(3);
    
    for (int i = 0; i < 100; i++) {
        dispatch_async(queue, ^{

            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
            NSLog(@"task %d start", i);
            
            NSLog(@"task %d end", i);
            
            dispatch_semaphore_signal(semaphore);

        });
    }
```

### wait 与 signal 

wait -> 拿资源 

signal -> 还资源 

所以: 

```objc
dispatch_semaphore_wait(semaphore, ...); 
    使用资源
dispatch_semaphore_signal(semaphore); 
```

