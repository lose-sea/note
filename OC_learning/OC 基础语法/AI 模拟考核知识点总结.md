# 委托方持有代理方使用 weak 修饰

@property (nonatomic, weak) id<OrderDelegate> delegate;

为什么 delegate 要用 **`weak`** 修饰，而不是 `strong`？



避免委托方和被委托方之间的循环强引用，防止内存泄漏。

# 委托方在调用协议方法之前要加一个判断 



@optional` 和 `@required` 有什么区别？

如果协议里有一个 `@optional` 方法，Boss 在调用它之前必须加一个判断，这个判断是什么？为什么要加?

 

需要检查代理方是否实现了协议声明的方法, 

```objc
if ([self.delegate respondsToSelector:@selector(didReceiveOrder:)]) {
    [self.delegate didReceiveOrder:food];
}
```



# `NSString` 和 `NSInteger` 有什么区别？

**NSInteger** 本质是基本数据类型的 `typedef`：

```objc
typedef long NSInteger; // 并不是对象，是基本类型
```

所以更准确的区分是：

| 类型          | 属于         | 能否加入集合 |
| ------------- | ------------ | ------------ |
| `NSString`    | OC 对象      | ✅ 能         |
| `NSArray`     | OC 对象      | ✅ 能         |
| `NSInteger`   | 基本数据类型 | ❌ 不能       |
| `int / float` | 基本数据类型 | ❌ 不能       |



# 如果我想把 `NSInteger` 存进 `NSArray` 里，应该怎么做？

需要先将NSInteger 转换为 oc 对象

```objc
// 正确写法
NSInteger num = 18;
[NSNumber numberWithInteger:num]; // 注意是 Integer 不是 NSInteger

// 更简洁的字面量写法
@(num); // 效果一样，推荐！
```



# `NSArray` 和 `NSSet` 都是集合，它们有什么区别？分别适合什么场景使用？

|          | NSArray        | NSSet          |
| -------- | -------------- | -------------- |
| 重复元素 | ✅ 允许         | ❌ 不允许       |
| 有序     | ✅ 有顺序       | ❌ 无顺序       |
| 查找速度 | 慢（逐个遍历） | 快（哈希查找） |

所以：

- 需要**顺序**、允许重复 → 用 `NSArray`
- 需要**去重**、不关心顺序 → 用 `NSSet`



# OC 中 `copy` 和 `strong` 修饰 `NSString` 有什么区别？



**strong：直接持有对象（引用计数+1）**

**copy：持有对象的“拷贝”（生成一个新对象）**

使用 `copy` 修饰的属性，在赋值时会对传入对象执行拷贝操作，使属性持有该对象的副本，因此原对象后续的修改不会影响属性值；而使用 `strong` 修饰的属性，仅对对象进行强引用（增加引用计数），属性与原对象指向同一实例，因此对原对象的修改会反映到属性上。



# insancetype 和 id 的都可以作为返回值类型, 区别

## instancetype

返回类型; 编译器知道是当前类的实例 

编译器回检查

## id

 返回类型: 编译器只知道是某个某个对象, 不确定类型 

编译器不循环 

**instancetype更安全, 有类型检查, 创建对象方法推荐使用 instancetype , **

**id 更灵活, 当失去了类型检查, 比如委托 `id<OrderDelegate> `**这种场景



# id 和 super 的区别

`self` 是当前对象，调用方法时从当前类开始查找；
 `super` 不是对象，而是一个编译器指示符，表示从父类开始查找方法实现。 

#### self 就是当前对象实例,本质是发送消息

### 查找流程：

 从**当前开始 → 父类 → … → 根类

#### super 不是对象

`super` **不是对象**

只是告诉编译器：
 **从父类开始查找方法**

| 对比点         | self         | super        |
| -------------- | ------------ | ------------ |
| 是否是真正对象 | ✔ 是         | ❌ 不是       |
| 方法查找起点   | 当前类       | 父类         |
| 本质           | 普通消息发送 | 修改查找起点 |

 即使写的是 `super`：

```
[super doSomething];
```

### 实际调用者仍然是：**当前对象（self）**

只是： **方法实现从父类找**



# OC 中 `#import` 和 `@class` 都可以引用另一个类，它们有什么区别？分别在什么情况下使用？

|          | `#import`                   | `@class`                       |
| -------- | --------------------------- | ------------------------------ |
| 作用     | 引入完整头文件              | 只告诉编译器"这是个类"         |
| 使用场景 | `.m` 文件，或需要调用方法时 | `.h` 文件中声明属性/参数类型时 |
| 编译速度 | 慢（引入整个文件）          | 快（只是声明）                 |

```objc
// Boss.h 中只需要知道 Secretary 是个类，用 @class 就够了
@class Secretary;

@interface Boss : NSObject
@property (nonatomic, weak) Secretary *secretary;
@end 
    
// Boss.m 中需要调用 Secretary 的方法，必须用 #import
#import "Secretary.h"

@implementation Boss
- (void)notify {
    [self.secretary didReceiveOrder:@"汉堡"]; // 需要知道方法，必须import
}
@end
```

 

# 封装, 继承, 多态

## 封装

**把属性和方法包装在类里，隐藏内部实现，只暴露必要的接口**

## 继承

**子类拥有父类所有的属性和方法，并可以扩展自己的**

## 多态

**核心：父类指针指向子类对象** 

同一个父类指针，指向不同子类，调用同名方法，结果不同



# OC 中子类可以重写父类方法吗？重写时需要注意什么？

可以, 子类的重写的方法会覆盖父类的方法, 如果调用还需要父类的方法 , 需要使用super



# OC 中 `strong`、`weak`、`assign`、`copy` 修饰属性分别用在什么场景？

| 修饰符   | 用途                 | 常见场景               |
| -------- | -------------------- | ---------------------- |
| `strong` | 强引用，持有对象     | 普通OC对象             |
| `weak`   | 弱引用，不持有对象   | delegate、避免循环引用 |
| `assign` | 直接赋值，不管理内存 | 基本数据类型           |
| `copy`   | 复制一份副本         | NSString               |

## 四种修饰符和引用计数的关系

| 修饰符   | 对引用计数的影响                |
| -------- | ------------------------------- |
| `strong` | +1，持有对象                    |
| `weak`   | 不影响，对象销毁时自动置nil     |
| `assign` | 不影响，对象销毁时**不会**置nil |
| `copy`   | +1，但持有的是副本              |

OC对象**不能用** `assign`，会崩溃

基本类型**用** `assign`，因为基本类型没有引用计数



# BOOL类型的本质

```objc
typedef signed char BOOL; // 本质是 signed char，也是整型
#define YES (BOOL)1
#define NO  (BOOL)0
```



# OC 中 `description` 方法是什么？什么时候会用到它？

`description` 是从 NSObject 继承的方法，用于返回对象的字符串描述，通常在 `NSLog`、字符串格式化或集合打印时自动调用。



# OC 中 `#pragma mark` 是什么？有什么作用？

````objc
@implementation Boss

#pragma mark - 初始化
- (instancetype)init {
    ...
}

#pragma mark - 委托方法
- (void)placeOrder {
    ...
}

#pragma mark - 私有方法
- (void)privateMethod {
    ...
}

@end
```

---

在 Xcode 顶部方法列表里会看到清晰的分组：
```
- 初始化
  init
- 委托方法
  placeOrder
- 私有方法
  privateMethod
````



# 每个 OC 对象内部都有一个 `isa` 指针，它指向哪里？有什么作用？

```objc
实例对象 —isa→ 类对象 —isa→ 元类对象 —isa→ 根元类对象
                                              ↑
                                              |（指向自己）
```



# 类对象和元类对象分别存储什么内容？为什么要分开存？

| 存储位置 | 存储内容                         |
| -------- | -------------------------------- |
| 实例对象 | 成员变量的值                     |
| 类对象   | 实例方法、属性信息、成员变量信息 |
| 元类对象 | 类方法                           |

分开存是为了让**方法查找逻辑统一**，同时避免类方法和实例方法命名冲突！

### OC 查找方法的规则

无论实例方法还是类方法，查找逻辑都是：

```
通过 isa 找到对应的对象 → 在里面查找方法
```

### 实例方法查找

```
实例对象 —isa→ 类对象 → 找到实例方法 
```

### 类方法查找

```
类对象 —isa→ 元类对象 → 找到类方法 
```

 # 当调用一个实例方法时，OC 是怎么通过 `isa` 找到这个方法的？



#### 实例方法

```
Dog *dog = [[Dog alloc] init];
[dog bark];

1. dog 通过 isa 找到 Dog 类对象
2. 在 Dog 类对象的方法列表里找 bark
3. 找到了 → 直接调用 ✅
4. 没找到 → 通过 superclass 去父类 Animal 类对象找
5. 还没找到 → 继续往上找，直到 NSObject
6. NSObject 也没有 → 崩溃 ❌
```


```objc
dog —isa→ Dog类对象 —superclass→ Animal类对象 —superclass→ NSObject类对象
               ↓ 没找到              ↓ 没找到              ↓ 没找到
            找bark               找bark               找bark → 崩溃
               ↓ 找到
            调用 ✅
```

#### 类方法

````objc
[Dog createDog];
```
Dog类对象 —isa→ Dog元类对象 —superclass→ Animal元类对象 —superclass→ 根元类对象
                    ↓ 找到
                调用 ✅
```

## 总结
```
实例方法：实例对象 —isa→ 类对象 —superclass→ 父类对象 → ... → NSObject
类方法：  类对象   —isa→ 元类对象 —superclass→ 父元类  → ... → 根元类
````

**这个过程叫做消息发送（objc_msgSend）**



# `superclass` 和 `isa` 有什么区别？

`isa` 指向对象所属的类（用于找到类对象），而 `superclass` 指向父类（用于方法查找的继承关系）。

`isa` → **水平方向**，从实例找到类，从类找到元类

`superclass` → **垂直方向**，从子类找到父类



# 根元类对象的 `superclass` 指向谁？为什么？



`Dog元类 —superclass→ Animal元类 —superclass→ 根元类 —superclass→ NSObject类对象`

这样设计之后, 

````objc
// NSObject 的实例方法
[dog description];  // 实例可以调用 

// 类也可以调用 NSObject 的实例方法！
[Dog description];  // 类也可以调用 
```

查找过程：
```
Dog类对象 —isa→ Dog元类 → 没找到
→ superclass → Animal元类 → 没找到  
→ superclass → 根元类 → 没找到
→ superclass → NSObject类对象 → 找到 description 
````

所有的类都能调用NSObject 中的实例方法



# OC 的方法调用本质上是什么？为什么向 `nil` 发消息不会崩溃？

## **OC 方法调用的本质是消息发送** 

`[dog bark]` 被编译器转换为 `objc_msgSend(dog, @selector(bark)); `

objc_msgSend 接受两个参数: 

1. 消息接收者: dog
2. 消息 bark 方法 

OC 中所有方法调用，底层都会转换成 `objc_msgSend` 函数：

~~~objc
[dog bark];

// 编译器转换成
objc_msgSend(dog, @selector(bark));
```

**本质就是发送消息！**
- `dog` 是消息接收者
- `bark` 是消息名称（SEL）


## objc_msgSend 做了什么？
```
1. 检查接收者是否为 nil
2. 通过 isa 找到类对象
3. 在方法列表里找对应方法
4. 找到 → 调用
5. 找不到 → 通过 superclass 往上找
6. 都找不到 → 崩溃
```
~~~

## 为什么向 nil 发消息不会崩溃？

~~~objc
Dog *dog = nil;
[dog bark]; // 不崩溃！
```

因为 `objc_msgSend` 内部第一步就是：
```
判断消息接收者是否为 nil
→ 是 nil → 直接返回，什么都不做 
→ 不是 nil → 通过 isa 找方法，正常执行
~~~

# 既然方法调用本质是 `objc_msgSend`，那 `@selector` 是什么？它的本质是什么类型？有什么作用？

@selector 本质是 SEL 类型, 是方法名的唯一标识符. 把**方法名字符串 → 转成 SEL** 

SEL 是一个指向结构体的指针

`@selector` 用于在编译期生成方法名对应的 `SEL`，`SEL` 是 runtime 中方法的唯一标识，存储在 selector table 中；在方法调用时，`objc_msgSend` 会通过 `SEL` 在类的 cache 和 method list 中查找对应的 `IMP` 并执行。



# +OC 中 `+(instancetype)new` 和 `+(instancetype)alloc` + `-(instancetype)init` 有什么区别？

底层来说, new 就是 alloc + init 的组合, 但是在实际开发中推荐用 alloc + init, 

```objc
alloc + init 可以用自定义初始化方法
Dog *dog = [[Dog alloc] initWithName:@"旺财"]; // ✅ 可以传参

// new 只能调用默认 init，无法传参
Dog *dog = [Dog new]; // ❌ 没办法传参
```

# 指定初始化方法

**参数最全的那个 init 方法就是指定初始化方法！**

```objc
@interface Dog : NSObject

// 指定初始化方法 — 参数最全
- (instancetype)initWithName:(NSString *)name age:(NSInteger)age;

// 便利初始化方法 — 参数少，内部调用指定初始化方法
- (instancetype)initWithName:(NSString *)name;

@end
```

