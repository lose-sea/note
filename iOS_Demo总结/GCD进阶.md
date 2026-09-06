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
> | 优先级常量                           | 含义                                     | 使用场景                                                     |
> | :----------------------------------- | :--------------------------------------- | :----------------------------------------------------------- |
> | `DISPATCH_QUEUE_PRIORITY_HIGH`       | **高优先级**（QOS_CLASS_USER_INITIATED） | 用户**正在等待结果**的操作，比如下拉刷新、点击按钮后加载数据。系统会分配更多 CPU 资源给它，让它尽快完成。 |
> | `DISPATCH_QUEUE_PRIORITY_DEFAULT`    | **默认优先级**（QOS_CLASS_DEFAULT）      | 大多数常规任务。介于 High 和 Low 之间。                      |
> | `DISPATCH_QUEUE_PRIORITY_LOW`        | **低优先级**（QOS_CLASS_UTILITY）        | **耗时但不紧急**的操作，比如下载大文件、数据同步、数据库备份。系统会在 CPU 空闲时执行它，不影响 UI 流畅度。 |
> | `DISPATCH_QUEUE_PRIORITY_BACKGROUND` | **后台优先级**（QOS_CLASS_BACKGROUND）   | **用户不感知**的任务，比如数据预加载、清理缓存。系统会在**极低功耗**状态下执行，甚至可能推迟到设备充电时执行。 |
>
> > **iOS 8+ 后，苹果推荐使用新的 `QOS_CLASS_\*`（服务质量），但为了兼容老代码，`DISPATCH_QUEUE_PRIORITY_\*` 依然随处可见。两者是对应的。**
>
>  参数2：保留标志位（Flags）
>
> **这个参数目前没有实际意义，是为了苹果未来扩展预留的。**
> **你必须永远传 `0`**。如果你传了其他值，代码依然能运行，但苹果文档明确说了“传 0 即可”。

## 自定义队列

```objc
```

