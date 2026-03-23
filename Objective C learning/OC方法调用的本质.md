# OC 方法调用的本质是 消息的发送

OC 中对象本身只存储实例变量, (成员变量) 和 一个 `isa` 指针, 不存方法, 方法都存储在类对象中 

# 实例对象（instance）

```
instance
├── isa → Class
└── ivars（成员变量）
```

### 特点：

- 存储数据（属性、本质是 ivar） 

    > `ivar`（instance variable）是**实例变量**，用于在对象中存储数据，是属性（property）的底层实现。
    >
    > property = ivar + getter/setter 方法

- 不存方法

- 每个对象一份

```
Person *p = [[Person alloc] init];
```

# 四、类对象（Class）

```
Class
├── isa → meta-class
├── superclass → 父类
├── cache（方法缓存）
├── method list（实例方法）
└── ivar list（成员变量信息）
```

### 存什么？

- 实例方法（`-` 方法）
- 属性信息
- 协议等

所有实例共享同一个 Class



# 元类对象（meta-class）

```
meta-class
├── isa → 根元类
├── superclass → 父类的 meta-class
├── cache
└── method list（类方法）
```

### 存什么？

**类方法（+ 方法）**

```
+ (void)test;
```

和类对象一样, 一个类对象只有一个元类对象



# SEL 是什么？

```
SEL sel = @selector(test);
```

### 本质：

 `SEL` 是一个**方法名的唯一标识（类似 key）**

- 底层是一个字符串（但做了唯一化）
- 相同方法名 → 同一个 SEL

```
@selector(test)
```

本质类似：

```
"test"
```

但 runtime 会优化成唯一 ID（提高查找效率）

------

# IMP 是什么？

```
typedef id (*IMP)(id, SEL, ...);
```

本质：**函数指针**

- 指向方法真正的实现代码
- 是最终被 CPU 执行的东西

------

# Method 是什么？

运行时里还有一个结构：

```
struct method_t {
    SEL name;   // 方法名
    IMP imp;    // 方法实现
};
```

 可以理解为一张表：

| SEL（方法名） | IMP（函数地址） |
| ------------- | --------------- |
| test          | 0x123456        |

# 完整调用流程

Objective-C 的方法调用，本质是 runtime 通过 `isa` 找到类，利用 `SEL` 在 **cache → method list → 父类链** 中查找对应的 `IMP`，命中后执行函数；若未找到，则进入动态方法解析与消息转发流程。

# 一、从一行代码开始（所有一切的起点）

```
[obj run];
```

编译器会做两件事

------

# 二、Step 0：selector table（方法名 → SEL）

```
@selector(run)
```

 会被注册到一张**全局表：selector table**

```
"run" → SEL(0x1111)
```

 同一个方法名 → 永远同一个 SEL
  本质：**把字符串变成唯一指针（加速比较）**

------

# 三、Step 1：变成消息发送

```
objc_msgSend(obj, SEL)
```

 OC 没有“直接调用方法”，全是**发消息**

------

# 四、Step 2：找到类（isa）

```
obj → isa → Class
```

 对象只存：

- ivar（数据）
- isa（指向类）

 方法都在类里 

------

# 五、Step 3：先查 cache（最快)

```
Class.cache：

SEL → IMP
```

 如果有：

```
run → 0x123456
```

 直接执行 IMP（结束）

------

# 六、Step 4：查 method list（真正数据源）

```
Class.method list：

SEL → IMP 本质结构：
```

```
struct method_t {
    SEL name;
    IMP imp;
};
```

 找到后：

 拿到 IMP
  写入 cache（优化）

------

# 七、Step 5：查父类（继承链）

```
Class → superclass → superclass → ...
```

每一层都：

```
cache → method list
```

------

# 八、Step 6：还找不到 → runtime 动态流程（你刚刚那张图）

------

## ① 动态方法解析

```
+ (BOOL)resolveInstanceMethod:(SEL)sel
```

 你可以**动态加方法（IMP）**

------

## ② 快速转发

```
- (id)forwardingTargetForSelector:(SEL)aSelector;
```

 换对象处理：

```
return otherObj;
```

------

## ③ 完整消息转发

```
- methodSignatureForSelector
- forwardInvocation
```

 你自己完全接管调用

------

## ④ 还不行 → 崩溃

```
unrecognized selector sent to instance
```

------



# 九、Step 7：最终执行 IMP（本质）

```
imp(obj, SEL);
```

👉 IMP 本质是函数指针：

```
void run(id self, SEL _cmd) {
    // 方法实现
}
```