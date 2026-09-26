**Objective-C Runtime** 是 ObjC 动态特性的核心基础。它是一套运行时库（主要在 libobjc），让语言在**运行时**完成大量工作：消息发送、方法查找、动态添加方法/属性、Category 合并、方法交换、关联对象等。

与 C++/Swift 的静态特性不同，ObjC 几乎所有面向对象行为都可以在运行时被观察和修改。

------

### 1. 核心思想：一切皆消息

在 ObjC 中，调用方法本质上是**发送消息**：

Objective-C

```
[obj doSomething];
```

编译器会转换成类似：

Objective-C

```
objc_msgSend(obj, @selector(doSomething));
```

objc_msgSend 是 Runtime 最核心的函数。它会：

1. 根据对象的 isa 指针找到它的类。
2. 在类的方法列表（以及父类）中查找对应的 SEL（selector）。
3. 找到后跳转到对应的 IMP（函数指针）执行。
4. 找不到则进入消息转发流程。

------

### 2. 关键数据结构

#### 对象（objc_object）

C

```
struct objc_object {
    Class isa;   // 指向所属的类
};
```

所有对象的第一个成员都是 isa。

#### 类（objc_class）

C

```
struct objc_class {
    Class isa;                    // 指向元类（meta-class）
    Class superclass;             // 父类
    cache_t cache;                // 方法缓存（提高查找速度）
    class_data_bits_t bits;       // 指向 class_rw_t / class_ro_t
};
```

真正的方法列表、属性、协议等信息存在 class_rw_t（可写）和 class_ro_t（只读）中。

#### 方法（Method）

C

```
struct method_t {
    SEL name;           // 方法名（selector）
    const char *types;  // 类型编码（返回值 + 参数类型）
    IMP imp;            // 函数指针
};
```

+ **SEL**：方法选择器，本质上是 C 字符串（全局唯一）。
+ **IMP**：实际执行的函数指针，类型为 id (*)(id, SEL, ...)。
+ **types**：类型编码字符串，例如 @: 表示返回 id，接收 self 和 _cmd。

#### 元类（Meta-class）

+ 类对象本身也是对象，它的 isa 指向元类。
+ 元类的方法列表存放的是**类方法**。
+ 所有元类的 isa 最终指向根元类（NSObject 的元类）。

------

### 3. 消息发送完整流程

text

```
objc_msgSend(obj, SEL)
    ↓
查找 obj->isa 对应的类
    ↓
先查 cache（很快）
    ↓
缓存未命中 → 查方法列表（method list）
    ↓
找到 → 缓存 + 调用 IMP
    ↓
没找到 → 查父类（一路向上）
    ↓
还没找到 → 进入动态方法解析 / 消息转发
```

#### 动态方法解析（resolve）

如果类实现了：

Objective-C

```
+ (BOOL)resolveInstanceMethod:(SEL)sel
+ (BOOL)resolveClassMethod:(SEL)sel
```

可以在这里用 class_addMethod 动态添加方法。

#### 快速转发（forwardingTargetForSelector:）

返回另一个对象，让它来处理这条消息（类似消息重定向）。

#### 完整转发

1. methodSignatureForSelector: 返回方法签名。
2. forwardInvocation: 拿到 NSInvocation，可以修改参数、目标，或者做其他处理。

如果以上全部失败，最终会调用 doesNotRecognizeSelector: 并抛出异常。

------

### 4. 常用 Runtime API（<objc/runtime.h>）

#### 类与对象

Objective-C

```
Class object_getClass(id obj);
Class class_getSuperclass(Class cls);
const char *class_getName(Class cls);
BOOL class_isMetaClass(Class cls);
```

#### 方法操作

Objective-C

```
Method *class_copyMethodList(Class cls, unsigned int *outCount);
SEL method_getName(Method m);
IMP method_getImplementation(Method m);
const char *method_getTypeEncoding(Method m);

// 动态添加方法
BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);

// 方法交换（Method Swizzling 的核心）
void method_exchangeImplementations(Method m1, Method m2);
IMP class_replaceMethod(Class cls, SEL name, IMP imp, const char *types);
```

#### 成员变量

Objective-C

```
Ivar *class_copyIvarList(Class cls, unsigned int *outCount);
const char *ivar_getName(Ivar ivar);
ptrdiff_t ivar_getOffset(Ivar ivar);
```

#### 属性

Objective-C

```
objc_property_t *class_copyPropertyList(Class cls, unsigned int *outCount);
const char *property_getName(objc_property_t property);
const char *property_getAttributes(objc_property_t property);
```

#### 关联对象（Associated Objects）

Objective-C

```
void objc_setAssociatedObject(id object, const void *key, id value, objc_AssociationPolicy policy);
id objc_getAssociatedObject(id object, const void *key);
void objc_removeAssociatedObjects(id object);
```

常用 policy：OBJC_ASSOCIATION_RETAIN_NONATOMIC、OBJC_ASSOCIATION_COPY 等。这是给已有类“添加属性”的标准方式（Category 无法直接加实例变量）。

------

### 5. 重要应用场景

#### Method Swizzling（方法交换）

最经典的用法，例如拦截系统方法：

Objective-C

```
+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(viewDidLoad));
        Method swizzled  = class_getInstanceMethod(self, @selector(my_viewDidLoad));
        method_exchangeImplementations(original, swizzled);
    });
}

- (void)my_viewDidLoad {
    // 做额外事情
    [self my_viewDidLoad]; // 实际调用的是原来的 viewDidLoad
}
```

注意：

+ 尽量在 +load 中做，并用 dispatch_once 保证只执行一次。
+ 优先使用 class_addMethod + class_replaceMethod 的写法，更安全（处理子类没有实现父类方法的情况）。

#### 动态添加方法 / 属性

用于实现类似 KVO、AOP、热修复等功能。

#### 关联对象

给系统类或第三方类添加“属性”：

Objective-C

```
static const void *kKey = &kKey;
objc_setAssociatedObject(self, kKey, someObject, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
```

#### Category 的实现原理

Category 的方法在运行时被合并到主类的方法列表中。如果主类和 Category 有同名方法，后加载的会覆盖前面的（实际取决于加载顺序，不保证）。