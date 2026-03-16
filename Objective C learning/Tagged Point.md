# Tagged Pointer

**Tagged Pointer** 是 **Objective-C** 在 **Objective-C Runtime** 中的一种**性能优化技术**，主要用于**小对象的存储**，避免频繁的堆内存分配。

**核心思想：**

**把对象的数据直接存进指针本身，而不是在堆上创建对象。**

```objc
正常对象：
指针  ---->  堆内存中的对象
Tagged Pointer：
指针 = 数据
```

也就是说; **对象没有真正分配内存** 



## Tagged Pointer 的结构 

在 **64 位系统**中：**指针 = 8 字节 = 64 bit**, 实际上系统不会用满所有位，例如：

```
地址只使用 48bit
```

剩下的 bit 可以存储：

+ 类型信息
+ 对象数据

于是 Apple 利用这些位实现 **Tagged Pointer**。

Tagged Pointer 是 Objective-C Runtime 的一种优化技术，它把对象数据直接存储在指针中，避免堆内存分配，从而提升性能。常见于 NSNumber、NSString 等小对象。

### 示意结构：

```objc
64 bit pointer

| tag | class | value | 
| 1bit | 3~4bit | 剩余bit | 
```

含义: 

> **tag** — 最高位，只有 **1个bit**，值为 `1` 就代表这是 Tagged Pointer，值为 `0` 就是普通指针。
>
> **class** — 类型标识，告诉系统这个 Tagged Pointer 存的是 `NSString`、`NSNumber` 还是其他类型。
>
> **value** — 存储的实际值，比如字符串内容、数字等。

### NSNumber很快的原因:  

> 因为很多NSNumber 是 Tagged Point



## Tagged Pointer 和普通对象对比

| 特性     | 普通对象 | Tagged Pointer |
| -------- | -------- | -------------- |
| 内存分配 | malloc   | 不需要         |
| 内存位置 | 堆       | 指针           |
| 释放     | ARC      | 不需要         |
| 性能     | 普通     | 更快           |
