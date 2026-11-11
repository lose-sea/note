[toc]

# GCD

## 全局队列



```objc
dispatch_queue_t queue =
dispatch_get_global_queue(
    DISPATCH_QUEUE_PRIORITY_DEFAULT,
    0
);
```

它是系统Apple提供的系统队列,它类似 并发队列 (Concurrent Queue), 可以同时执行多个任务



> 之前学过“异步（`dispatch_async`）”，想要异步执行任务，就需要一个“容器”来放这些任务吧, 这个“容器”就是**队列（Queue）, **`dispatch_get_global_queue` 就是获取苹果系统提供给你的**现成的后台队列**。
>
> 
>
> ```objc
> dispatch_queue_t queue = dispatch_get_global_queue(
>     DISPATCH_QUEUE_PRIORITY_DEFAULT,  // 参数1：优先级
>     0                                  // 参数2：保留标志位（永远传0）
> );
> ```
>
> 参数1：优先级（Priority）
>
> 这个参数决定了**这个队列里的任务，能获得多少 CPU 时间片**。
>
> | 含义                                     | 优先级常量                           | 使用场景                                                     |
> | :--------------------------------------- | :----------------------------------- | :----------------------------------------------------------- |
> | **高优先级**（QOS_CLASS_USER_INITIATED） | `DISPATCH_QUEUE_PRIORITY_HIGH`       | 用户**正在等待结果**的操作，比如下拉刷新、点击按钮后加载数据。系统会分配更多 CPU 资源给它，让它尽快完成。 |
> | **默认优先级**（QOS_CLASS_DEFAULT）      | `DISPATCH_QUEUE_PRIORITY_DEFAULT`    | 大多数常规任务。介于 High 和 Low 之间。                      |
> | **低优先级**（QOS_CLASS_UTILITY）        | `DISPATCH_QUEUE_PRIORITY_LOW`        | **耗时但不紧急**的操作，比如下载大文件、数据同步、数据库备份。系统会在 CPU 空闲时执行它，不影响 UI 流畅度。 |
> | **后台优先级**（QOS_CLASS_BACKGROUND）   | `DISPATCH_QUEUE_PRIORITY_BACKGROUND` | **用户不感知**的任务，比如数据预加载、清理缓存。系统会在**极低功耗**状态下执行，甚至可能推迟到设备充电时执行。 |
>
> > **iOS 8+ 后，苹果推荐使用新的 `QOS_CLASS_\*`（服务质量），但为了兼容老代码，`DISPATCH_QUEUE_PRIORITY_\*` 依然随处可见。两者是对应的。**
>
>  参数2：保留标志位（Flags）
>
> **这个参数目前没有实际意义，是为了苹果未来扩展预留的。**
> **永远传 `0`**。如果传了其他值，代码依然能运行，但苹果文档明确说了“传 0 即可”。

## 自定义队列

自定义队列使用 `dispath_queue_create()` 方法

例如: 

```objc
dispatch_queue_t queue = dispatch_queue_create("com.demo.downLoad", DISPATCH_QUEUE_SERIAL); 
```

### 为什么需要自定义队列 

实际开发中：

例如：

图片下载：

```
下载队列
```

数据库操作：

```
DB队列
```

缓存：

```
Cache队列
```

业务隔离：

```
Network Queue
Database Queue
Image Queue
```

------

例如：

```objc
_networkQueue =
dispatch_queue_create(
"network",
DISPATCH_QUEUE_CONCURRENT
);
```

之后：

```objc
dispatch_async(_networkQueue,^{
    
});
```

## 全局队列与自定义队列

全局队列 (global queue) 适合 普通后台任务, 例如

```objc
dispatch_async(
dispatch_get_global_queue(0, 0), A^{
    
}); 
```

自定义队列适合: 需要管理任务关系 

例如: 数据库 

```objc
写 1
写 2
写 3
```

这里为了保证写操作顺序, 使用串行队列 `Serial Queue` 



## Qos (Quality of Service) 

Qos: 服务质量等级

就是告诉系统: 这个任务的重要程度

Apple 定义了几个等级: 

### User Interactive  

最高优先级, 用于 **用户马上看到的操作** 

例如: 

+ UI 动画
+ 触摸响应
+ 页面刷新

### User Initiated 

用户主动触发.

例如: 

+ 打开文件

+ 加载页面数据 

用户正在等待

### Utility

普通耗时任务 

例如: 

+ 下载
+ 导出文件
+ 计算

### Background 

最低优先级 

例如: 

+ 后台同步
+ 日志上传
+ 缓存清理

| 含义                                     | 优先级常量                           | 使用场景                                                     |
| :--------------------------------------- | :----------------------------------- | :----------------------------------------------------------- |
| **高优先级**（QOS_CLASS_USER_INITIATED） | `DISPATCH_QUEUE_PRIORITY_HIGH`       | 用户**正在等待结果**的操作，比如下拉刷新、点击按钮后加载数据。系统会分配更多 CPU 资源给它，让它尽快完成。 |
| **默认优先级**（QOS_CLASS_DEFAULT）      | `DISPATCH_QUEUE_PRIORITY_DEFAULT`    | 大多数常规任务。介于 High 和 Low 之间。                      |
| **低优先级**（QOS_CLASS_UTILITY）        | `DISPATCH_QUEUE_PRIORITY_LOW`        | **耗时但不紧急**的操作，比如下载大文件、数据同步、数据库备份。系统会在 CPU 空闲时执行它，不影响 UI 流畅度。 |
| **后台优先级**（QOS_CLASS_BACKGROUND）   | `DISPATCH_QUEUE_PRIORITY_BACKGROUND` | **用户不感知**的任务，比如数据预加载、清理缓存。系统会在**极低功耗**状态下执行，甚至可能推迟到设备充电时执行。 |

### QoS 的使用

```objc
dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
dispatch_queue_t queue = dispatch_queue_create("download", attr);
```

上面这段代码是创建了一个download queue, Qos为 User Initiated 

第一步: `dispath_queue_attr_t attr = ...` 

 + dispath_queue_attr_t 是队列的属性 (Attribute) 类型 
 + 它是用来描述这个队列是以什么方式运行 (串行, 并发, 优先级)

第二步: `dispatch_queue_attr_make_with_qos_class(...)` 

这个函数接收 3 个参数, 用来组装属性

+ 参数一: `DISPATCH_Queue_SERIAL`, 队列类型, 如果是 `DISPATCH_QUEUE_CONCURRENT` 就是并发
+ 参数er: `QOS_CLASS_USER_INITIATED` 服务质量, 这里是 user Initiated, 任务优先级很高, 用户正在界面上等待结果 
+ 参数三: 0 保留位, 永远写 0 

第三步: 创建队列 `dispatch_queue_create('download', attr); `

第一个参数: `download`: 给队列起的名字,方便调试 

第二个参数: `attr`: 把刚才组装好的属性传传进去
