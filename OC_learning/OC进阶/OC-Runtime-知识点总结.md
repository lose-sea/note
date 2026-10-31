# Objective-C Runtime 知识点总结

> 根据 Runtime 学习对话整理 · 2026-10-29
>
> 主线：**发送消息 → 找到方法 → 执行实现 → 找不到时怎么办 → 如何在运行时改变行为**

---

[toc]

---

## 一、一句话理解 Runtime

> **Runtime 是 Objective-C 的运行时系统，负责在程序运行期间管理对象、类、方法和消息发送的一套机制。**

它回答的核心问题只有三个：

| 问题 | 对应的知识 |
| --- | --- |
| `person` 是什么对象？属于哪个类？从哪开始找？ | 对象、Class、`isa`、继承、元类 |
| `[person eat]` 怎么找到 `eat` 的实现？ | `SEL`、`Method`、方法列表、父类链、方法缓存 |
| 找到之后执行哪段代码？找不到怎么办？ | `IMP`、动态方法解析、消息转发、方法交换 |

把这三问串起来，Runtime 就不再是一堆零散的 API。

---

## 二、知识地图：四层结构

```
第一层  对象模型        实例对象 / 类对象 / 元类 / isa / superclass
   │
第二层  消息发送与查找   objc_msgSend / SEL / Method / IMP / 方法列表 / 方法缓存
   │
第三层  动态行为         动态方法解析 / 快速转发 / 完整转发 / 方法交换
   │
第四层  工程应用         Category / 关联对象 / 元数据 API / Swizzling
```

学习顺序建议按层推进：先把第二层（一次方法调用的完整过程）真正弄懂，再进入第三层，否则会出现"每个词都认识，连起来看不懂"的情况。

---

## 三、对象模型：对象、类、元类、isa

### 3.1 三个实体

| 实体 | 说明 |
| --- | --- |
| 实例对象（`person`） | 保存实例数据，通过 `isa` 关联所属的类 |
| 类对象（`Person`） | 描述这一类对象：方法列表、属性、父类关系等 |
| 元类（`Person` 的元类） | 保存**类方法**相关的方法信息 |

关键认知：**类本身也是一个对象**。所以类对象也有自己的 `isa`，指向它的元类。

### 3.2 两条指针，两种关系

| 指针 | 表达的关系 |
| --- | --- |
| `isa` | 这个对象对应哪个类对象 / 元类 |
| `superclass` | 这个类或元类在继承体系中的父级 |

两者可以交叉连接，并不矛盾：`isa` 负责"我是谁"，`superclass` 负责"我继承谁"。

### 3.3 完整的指针关系

```
实例对象 person
    │ isa
    ▼
Person 类对象 ──── superclass ────▶ 父类对象 ────▶ … ────▶ NSObject 类对象
    │ isa                                                      │ isa
    ▼                                                          ▼
Person 元类 ── superclass ──▶ 父元类 ──▶ … ──▶ NSObject 元类（根元类）
                                                    │ isa
                                                    ▼
                                              NSObject 元类（指向自己）
                                                    │ superclass
                                                    ▼
                                              NSObject 类对象（根类）
```

### 3.4 根类与根元类的三条特殊关系（重点）

1. `NSObject` **类对象**的 `isa` → `NSObject` **元类**
2. `NSObject` **元类**的 `isa` → **它自己**（根元类的 isa 指向自身）
3. `NSObject` **元类**的 `superclass` → `NSObject` **类对象**

**易错点**：根元类的 `superclass` 指向根类，但根元类本身**不是**根类，它是根类对应的元类。"继承"和"指针指向"要分开理解。

### 3.5 元类的关键结论

- 元类的方法列表里放的是**类方法**（`+` 方法）。
- 元类也有继承链，且与类的继承链平行。
- **元类不是实例方法查找完父类之后才进入的下一站。** 走哪条链，由消息接收者是实例还是类决定。

---

## 四、方法三要素：SEL、Method、IMP

### 4.1 对照表

| 概念 | 含义 | 回答的问题 |
| --- | --- | --- |
| `SEL` | 方法选择器，标识方法名 | 我要调用**哪个**方法？ |
| `Method` | Runtime 中描述方法的元数据结构 | 这个方法的**信息**是什么？ |
| `IMP` | 方法实现的函数指针 | 这个方法对应**哪段代码**？ |

### 4.2 SEL 的细节

```objc
SEL selector = @selector(sayHello);
```

- `SEL` 只标识方法，**不代表实现本身**。
- 选择器由**方法名 + 参数标签（冒号）**构成，**不包含参数类型和返回类型**。

```objc
- (void)eat:(NSString *)food;
- (void)eat:(NSInteger)count;
```

这两个方法的选择器**都是 `eat:`**。因此 Objective-C 不允许同一个类中定义仅参数类型不同的"重载"。

### 4.3 Method 的内部构成（简化）

`Method` 是 Runtime 描述方法的结构，包含：方法选择器、类型编码、实现入口（`IMP`）。

```
Method
 ├── SEL  method_name   → 方法名
 ├── IMP  method_imp    → 实现入口
 └── const char *types  → 类型编码（参数 / 返回值）
```

### 4.4 IMP 的细节

```objc
typedef id (*IMP)(id, SEL, ...);
```

- 指向方法实现函数的入口。
- `SEL` 与 `IMP` **不是永久一一绑定**：不同类可以为同一个 `SEL` 提供不同 `IMP`；运行时也能改变这个对应关系（这正是方法交换的基础）。

### 4.5 三者的关系

```
SEL（找哪个方法） ──▶ Method（方法元数据） ──▶ IMP（执行哪段代码）
```

不是简单的三层包含，而是"标识 → 描述 → 实现"三个层面。

---

## 五、方法查找的两条路径

**这是最容易混淆的地方。** 查找不是"对象 → 父类 → 元类"依次进行，而是先看发的是**实例方法**还是**类方法**。

### 5.1 实例方法：沿普通类继承链

```objc
Dog *dog = [[Dog alloc] init];
[dog eat];          // eat 定义在 Animal 中
```

```
dog（实例） ──isa──▶ Dog 类 ──未找到──▶ Animal 类 ──找到 eat 的 IMP──▶ 执行
```

- 实例对象本身**不保存**方法实现，只是通过 `isa` 确定查找起点。
- 子类找不到，才沿 `superclass` 往上找。

### 5.2 类方法：沿元类继承链

```objc
[Dog run];          // +run 定义在 Animal 中
```

```
Dog 类对象 ──isa──▶ Dog 元类 ──未找到──▶ Animal 元类 ──找到 +run──▶ 执行
```

### 5.3 对照表

| 调用方式 | 主要查找路径 |
| --- | --- |
| `[dog eat]` | `Dog` 类 → `Animal` 类 → 父类 … |
| `[Dog run]` | `Dog` 元类 → 元类继承链 … |
| `[NSObject new]` | 类方法机制，沿元类继承关系查找 |

> **一句话记住**：实例方法沿普通类链查找，类方法沿元类链查找。元类不是实例方法查找的"下一站"。

### 5.4 子类与父类都实现同名方法

```objc
@implementation Animal
- (void)eat { NSLog(@"Animal 吃饭"); }
@end

@implementation Person : Animal
- (void)eat { NSLog(@"Person 吃饭"); }
@end

[person eat];   // 输出：Person 吃饭
```

原因：接收者是 `person`，`isa` 指向 `Person`，`Person` 自己就实现了 `eat`，因此直接使用，不再向父类查找 —— 这就是**方法覆盖（Override）**在消息派发中的表现。

---

## 六、方法列表与方法缓存

### 6.1 方法列表：描述"类自己拥有什么"

```
Person 类对象
 └── 方法列表（概念示意）
      ├── eat  → SEL: eat,  IMP: 吃饭的实现
      └── run  → SEL: run,  IMP: 跑步的实现
```

**关键区别**：类的方法列表 = 这个类**直接拥有**的方法，**不等于**这个类**能够调用**的所有方法。

`Person : Animal` 能调用 `eat`，但 `eat` 在 `Animal` 的方法列表里，Runtime 沿父类链找到即可，**不会把父类方法复制进子类的方法列表**。

### 6.2 为什么需要方法缓存

连续调用同一方法时：

```objc
[person eat];
[person eat];
[person eat];
```

如果每次都从当前类逐层扫到父类，开销会重复累积。Runtime 因此引入**方法缓存（Cache）**。

| 场景 | 过程 |
| --- | --- |
| 第一次调用（未命中） | 查缓存 → 查本类方法列表 → 沿 `superclass` 找父类 → 找到 `IMP` → 执行，并缓存结果 |
| 后续调用（命中） | 查缓存直接得到 `IMP` → 执行 |

### 6.3 缓存里存什么

概念上是一组 **`SEL` → `IMP`** 的映射：

| SEL | 缓存的实现入口 |
| --- | --- |
| `eat` | 吃饭方法的 `IMP` |
| `run` | 跑步方法的 `IMP` |

注意三点：

1. 缓存是**加速查找**的数据结构，**不是**方法本身，也**不是**方法列表。
2. **缓存未命中 ≠ 方法不存在**，只表示这次没直接找到，仍可继续查找。
3. 方法实现被动态修改时，Runtime 会做必要的缓存维护 / 失效处理，不会让后续调用一直用旧结果。具体机制属于源码级内容，现阶段不必深究 `cache_t`、哈希与扩容。

### 6.4 方法调用的完整主线

```
isa 确定查找起点 → Cache 加速 → 方法列表与父类链 → 找到 IMP 并执行
```

---

## 七、消息发送：objc_msgSend

### 7.1 为什么叫"消息发送"

```objc
[person eat];
```

- **C 函数调用**：调用一个明确的函数，直接传参。
- **Objective-C 消息发送**：向接收者 `person` 发送 `eat` 消息，由 Runtime 根据运行时信息决定怎么处理。

### 7.2 概念上的等价形式

```objc
objc_msgSend(person, @selector(eat));
```

| 部分 | 含义 |
| --- | --- |
| `objc_msgSend` | 执行消息派发 |
| `person` | 消息接收者 |
| `@selector(eat)` | 消息对应的选择器 |

> 说明：真实编译结果受架构、参数、返回值、编译器优化影响，不是所有调用都机械等价于这一行。

### 7.3 objc_msgSend ≠ IMP

| 概念 | 职责 |
| --- | --- |
| `objc_msgSend` | 消息**派发**的入口 |
| `IMP` | 某个方法**实现**的入口 |

派发过程中，Runtime 根据查找结果找到合适的 `IMP` 并执行。

### 7.4 完整流程（概念模型）

```
① 发送消息        [person eat]
② 确定查找起点    person --isa--> Person 类
③ 查找方法        先查缓存；未命中则查方法列表 + 父类链
④ 找到并执行      在 Animal 中找到 eat 的 IMP → 执行
```

各知识点的角色：

| 知识点 | 在流程中的作用 |
| --- | --- |
| `isa` | 确定查找起点 |
| `SEL` | 标识要查找的方法 |
| 方法缓存 | 加速查找 |
| `superclass` | 连接父类，支持继承查找 |
| `IMP` | 指向具体实现 |
| `objc_msgSend` | 负责消息派发 |

---

## 八、找不到方法之后：动态解析与消息转发

### 8.1 总体流程

```
正常方法查找失败（缓存 + 本类 + 父类链都没有）
        │
        ▼
① 动态方法解析    resolveInstanceMethod: / resolveClassMethod:
        │           尝试动态补充方法实现
        ▼
② 快速消息转发    forwardingTargetForSelector:
        │           把消息交给另一个对象
        ▼
③ 完整消息转发    methodSignatureForSelector: + forwardInvocation:
        │           通过 NSInvocation 灵活处理 / 转发
        ▼
④ 仍无法处理      doesNotRecognizeSelector: → unrecognized selector 异常
```

> **核心认知**：方法查找失败 ≠ 立刻崩溃。Runtime 还留了三道"补救"机会。

### 8.2 第一阶段：动态方法解析

```objc
+ (BOOL)resolveInstanceMethod:(SEL)sel;   // 实例方法
+ (BOOL)resolveClassMethod:(SEL)sel;      // 类方法
```

注意：`resolveInstanceMethod:` 本身是**类方法**（`+`），但解决的是**实例方法**能否被补充。

```objc
#import <objc/runtime.h>

static void danceImplementation(id self, SEL _cmd) {
    NSLog(@"动态添加的 dance 方法");
}

@implementation Person

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    if (sel == @selector(dance)) {
        class_addMethod(self, sel, (IMP)danceImplementation, "v@:");
        return YES;
    }
    return [super resolveInstanceMethod:sel];
}

@end
```

参数拆解：

| 参数 | 含义 |
| --- | --- |
| `self` | 当前接收类方法消息的**类对象**（这里是 `Person`） |
| `sel` | 当前尝试解析的选择子 |
| `(IMP)danceImplementation` | 符合调用约定的 C 函数 |
| `"v@:"` | 类型编码：`v` = void 返回；`@` = 隐含参数 `self`；`:` = 隐含参数 `_cmd` |

关键细节：

- **返回 `YES` 不等于方法一定添加成功**。真正添加实现的是 `class_addMethod`，通常应先确认添加成功再返回 `YES`。
- `class_addMethod` 不会覆盖类中**已存在**的同名选择子。
- 实现函数的签名必须与类型编码、实际调用约定匹配（有参数/返回值时要相应调整）。
- 为什么能用普通 C 函数？因为 Objective-C 方法的底层本质就是一个函数入口，`IMP` 就是它的指针。

### 8.3 第二阶段：快速消息转发

```objc
- (id)forwardingTargetForSelector:(SEL)aSelector;
```

语义：**我处理不了这条消息，能不能换一个对象来接收？**

```objc
- (id)forwardingTargetForSelector:(SEL)aSelector {
    if (aSelector == @selector(drive)) {
        return self.driver;          // 交给 Driver 处理
    }
    return [super forwardingTargetForSelector:aSelector];
}
```

特点：

- 不要求把方法加到 `Person` 上，只是**换接收者**。
- 转发的是**原消息**，不是自己调用同名方法。
- 返回 `nil`，或目标对象也处理不了，则进入完整转发。
- 注意转发目标的生命周期，以及**不要把消息转发回自己**（可能死循环）。

### 8.4 第三阶段：完整消息转发

```objc
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector;
- (void)forwardInvocation:(NSInvocation *)anInvocation;
```

| 方法 | 职责 |
| --- | --- |
| `methodSignatureForSelector:` | 提供**方法签名**：告诉 Runtime 参数、返回值等调用结构 |
| `forwardInvocation:` | 接收封装好的 `NSInvocation`，决定**怎么处理这次调用** |

为什么需要签名？因为 Runtime 不只要知道方法叫什么，还要知道参数个数、类型、返回值，才能正确构造调用。

```objc
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    if (aSelector == @selector(dance)) {
        return [self.dancer methodSignatureForSelector:aSelector];
    }
    return [super methodSignatureForSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    if ([self.dancer respondsToSelector:anInvocation.selector]) {
        [anInvocation invokeWithTarget:self.dancer];
    } else {
        [super forwardInvocation:anInvocation];
    }
}
```

完整转发的六步：

1. 正常查找 `Person` 的 `dance` 失败；
2. 动态解析、快速转发都没解决；
3. Runtime 向 `Person` 请求 `dance` 的方法签名；
4. `Person` 返回 `Dancer` 的签名；
5. Runtime 把调用封装成 `NSInvocation`，交给 `forwardInvocation:`；
6. `Person` 用 `invokeWithTarget:` 把调用交给 `Dancer`。

**必须提供有效签名**，否则 Runtime 无法构造调用，最终仍会抛 `unrecognized selector`。

### 8.5 三种机制对比

| 机制 | 核心方法 | 解决的问题 | 本质 |
| --- | --- | --- | --- |
| 动态方法解析 | `resolveInstanceMethod:` | 让方法"变得存在" | **补实现** |
| 快速消息转发 | `forwardingTargetForSelector:` | 换一个对象处理 | **换接收者** |
| 完整消息转发 | `methodSignatureForSelector:` + `forwardInvocation:` | 检查、改造、记录、动态转交 | **换处理方式** |

> 动态方法解析是"把方法补上"；消息转发是"我仍然没有这个方法，但可以让别的逻辑来处理这条消息"。

### 8.6 补充说明

用转发模拟出来的方法，`respondsToSelector:` 默认仍可能返回 `NO`。如果外部依赖它判断能力，需要自行重写以保持行为一致。

---

## 九、Method Swizzling（方法交换）

### 9.1 本质

> 交换的是 **`SEL` 与 `IMP` 的对应关系**，不是交换源代码，也不是交换对象。

交换前：

| 选择子 | 对应实现 |
| --- | --- |
| `eat` | `eat` 的实现 |
| `sleep` | `sleep` 的实现 |

交换后：

| 选择子 | 对应实现 |
| --- | --- |
| `eat` | 原本 `sleep` 的实现 |
| `sleep` | 原本 `eat` 的实现 |

### 9.2 基本用法

```objc
#import <objc/runtime.h>

Method eatMethod   = class_getInstanceMethod([Person class], @selector(eat));
Method sleepMethod = class_getInstanceMethod([Person class], @selector(sleep));

method_exchangeImplementations(eatMethod, sleepMethod);

[person eat];     // 现在执行的是 sleep 的实现
[person sleep];   // 现在执行的是 eat 的实现
```

为什么调用结果变了？因为 `objc_msgSend` 仍然按 `SEL` 查找，只是 `SEL` 现在关联到了另一个 `IMP`。

### 9.3 经典用法：Category + `+load` 包装原方法

```objc
@implementation Person (Logging)

+ (void)load {
    Method originalMethod = class_getInstanceMethod(self, @selector(eat));
    Method swizzledMethod = class_getInstanceMethod(self, @selector(log_eat));

    if (originalMethod && swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

- (void)log_eat {
    NSLog(@"开始执行 eat");
    [self log_eat];          // 看起来像递归，其实不是
    NSLog(@"结束执行 eat");
}

@end
```

**为什么 `[self log_eat]` 不会无限递归？**

交换后：

| 选择子 | 对应实现 |
| --- | --- |
| `eat` | Category 中的 `log_eat` 实现 |
| `log_eat` | **原始 `eat` 的实现** |

所以 `[person eat]` → 进入 `log_eat` 实现 → 其中 `[self log_eat]` 实际调用的是**原始 `eat`** → 输出"原始 eat 方法"。

最终输出：

```
开始执行 eat
原始 eat 方法
结束执行 eat
```

这就是"包装原方法"的标准套路。

### 9.4 为什么用 `+load`

- `+load` 在**类/分类加载阶段**被调用，早于正常业务代码执行，适合尽早完成交换。
- 与 `viewDidLoad` 之类的生命周期方法完全不同层次。
- 必须保证**只执行一次**，重复交换会让实现关系再次颠倒。

### 9.5 四个风险

| 风险 | 说明 |
| --- | --- |
| 重复交换 | 每交换一次关系就再颠倒一次，行为可能反转 |
| 继承方法陷阱 | `class_getInstanceMethod` 可能返回**父类**的方法，直接交换会波及父类和其他子类 |
| 签名不兼容 | 被交换的两个方法必须有兼容的参数与返回值约定，交换不会自动适配类型 |
| 修改系统类 | 例如交换 `UIViewController` 生命周期方法，会影响整个 App |

更稳妥的写法：先判断方法是否由当前类自己实现，必要时配合 `class_addMethod` / `class_replaceMethod`。

---

## 十、四个修改方法的 API 对比

| API | 作用 | 能否添加方法 | 能否替换实现 | 参数形态 |
| --- | --- | --- | --- | --- |
| `class_addMethod` | 向指定类添加方法 | ✅ | ❌ 不覆盖已有同名方法 | `Class` + `SEL` |
| `class_replaceMethod` | 替换指定类的方法实现 | ✅ 不存在时添加 | ✅ | `Class` + `SEL` |
| `method_setImplementation` | 修改已有 `Method` 的 `IMP` | ❌ | ✅ | `Method` |
| `method_exchangeImplementations` | 互换两个方法的实现 | ❌ | ✅（交换） | 两个 `Method` |

### 10.1 class_addMethod

```objc
class_addMethod(Class cls, SEL name, IMP imp, const char *types);
```

- 返回 `YES` 成功，`NO` 失败（例如该类**自己**已经有这个方法）。
- 检查的是目标类**自己的方法列表**，不是"这个类能不能响应该方法"。

典型用途：**给子类添加自己的实现，从而覆盖继承来的方法，而不改动父类。**

```objc
// Student : Person，Person 实现了 eat，Student 没有
class_addMethod(Student.class, @selector(eat), (IMP)studentEat, "v@:");
// 之后 [student eat] 输出 Student 的版本，[person eat] 不受影响
```

### 10.2 class_replaceMethod

```objc
class_replaceMethod(Class cls, SEL name, IMP imp, const char *types);
```

- 目标类**已有**该方法 → 替换实现；
- 目标类**没有自己的**该方法 → 在**该类**上添加。

关键区分：

| 操作对象 | 效果 |
| --- | --- |
| 替换 `Person` 自己的方法 | 影响 `Person` 及其所有未覆盖该方法的子类 |
| 在 `Student` 上替换一个继承来的方法 | 实际是在 `Student` 上**新建**实现，父类不变 |

### 10.3 method_setImplementation

```objc
IMP oldIMP = method_setImplementation(Method m, IMP imp);
```

- 直接修改已有 `Method` 的 `IMP`，返回**旧的 `IMP`**。
- 不会创建新方法，必须先拿到 `Method`。
- 若 `Method` 来自父类（`class_getInstanceMethod` 可能返回继承方法），修改会影响共享该方法的父类。

---

## 十一、Category（分类）

### 11.1 Category 是什么

```objc
// Person+Run.h
@interface Person (Run)
- (void)run;
@end

// Person+Run.m
@implementation Person (Run)
- (void)run { NSLog(@"Person 正在跑步"); }
@end
```

- `(Run)` 是**分类名**，不是新建了一个 `PersonRun` 类。
- 不修改原类源码即可扩展方法。
- 实例仍然是 `Person` 对象，`isa` 仍指向 `Person` 类对象。

### 11.2 Category vs 继承

| 对比 | Category | 继承 |
| --- | --- | --- |
| 是否创建新类 | 不创建 | 创建子类 |
| 方法属于谁 | 扩展已有类 | 子类实现或继承 |
| 是否改变继承关系 | 不改变 | 建立父子关系 |
| 能否直接加实例变量 | **不能** | 子类可以定义自己的 |

### 11.3 为什么能加方法

编译后，Category 形成**独立的运行时元数据**；程序启动、类加载过程中，Runtime 处理这些元数据，使分类方法**参与所属类的方法查找**。

注意措辞：不是"编译器把分类源码合并进了 `Person.m`"，而是"分类方法最终能通过原有类的消息发送机制被找到"。

### 11.4 为什么不能加实例变量

对象创建后，**实例存储布局必须与所属类匹配**。如果分类能随意加实例变量，就要改变已确定的对象布局、重新安排存储空间 —— 而 Category 的设计不是重新定义一个类，也不创建新的实例布局。

必须区分两个概念：

| 概念 | 含义 |
| --- | --- |
| 增加属性**声明** | 只在接口里写 `@property`，不产生存储 |
| 增加属性**存储** | 需要真实的存储机制 + 可用的 getter/setter 实现 |

在 Category 中只写 `@property`，**不会**自动合成实例变量、getter、setter。直接调用通常会因找不到方法而崩溃。

### 11.5 多个 Category 同名方法

原类 + 分类 A + 分类 B 都实现 `eat` 时：

- 一次 `[person eat]` **只会调用一个**实现，不会依次调用三个。
- 不能简单认为"分类一定覆盖原类"，也**不能保证**某个分类永远优先。
- 常见 Apple Runtime 行为中，后加入方法列表的实现可能优先被找到，但**不应作为业务逻辑依赖**。
- 结论：**避免在多个 Category 中重写同一个选择器。**

> Category 负责"提供方法"，Method Swizzling 负责"改变 SEL 与 IMP 的绑定"。分类常用来组织 Swizzling 代码，但分类本身不等于方法交换。

---

## 十二、关联对象 Associated Objects

### 12.1 解决什么问题

Category 不能加实例变量，但有时又需要给已有类的对象附加数据 —— 关联对象提供了一种**不改变实例布局**的额外存储机制。

### 12.2 三个核心 API

```objc
#import <objc/runtime.h>

objc_setAssociatedObject(id object, const void *key, id value, objc_AssociationPolicy policy);
id  objc_getAssociatedObject(id object, const void *key);
void objc_removeAssociatedObjects(id object);
```

| API | 作用 |
| --- | --- |
| `objc_setAssociatedObject` | 设置 / 更新关联数据 |
| `objc_getAssociatedObject` | 读取关联数据 |
| `objc_removeAssociatedObjects` | 移除该对象的**全部**关联数据 |

### 12.3 给 Category 增加属性的标准写法

```objc
// 1. 头文件声明
@interface Person (Info)
@property (nonatomic, assign) NSInteger age;
@end

// 2. 实现文件
#import "Person+Info.h"
#import <objc/runtime.h>

@implementation Person (Info)

static char ageKey;

- (void)setAge:(NSInteger)age {
    objc_setAssociatedObject(self, &ageKey, @(age), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSInteger)age {
    NSNumber *number = objc_getAssociatedObject(self, &ageKey);
    return number.integerValue;
}

@end
```

要点：

- `static char ageKey;` 只用它的**地址** `&ageKey` 作为唯一 key，它本身不存任何数据。
- 关联值必须是**对象**，所以 `NSInteger` 要包装成 `NSNumber`。
- 未设置过时读到 `nil`，`nil.integerValue` 为 `0`。
- 每个独立属性必须用**不同的 key**，否则会互相覆盖。

### 12.4 内存管理策略

| 策略 | 含义 |
| --- | --- |
| `OBJC_ASSOCIATION_ASSIGN` | 不强持有关联值；**不提供可靠的弱引用语义** |
| `OBJC_ASSOCIATION_RETAIN_NONATOMIC` | 强持有，无原子性保证 |
| `OBJC_ASSOCIATION_COPY_NONATOMIC` | 复制，无原子性保证 |
| `OBJC_ASSOCIATION_RETAIN` | 强持有，有原子性保证 |
| `OBJC_ASSOCIATION_COPY` | 复制，有原子性保证 |

三个易混点：

- `RETAIN` ≠ `COPY`：持有 vs 复制。
- `NONATOMIC` ≠ 线程安全：它只表示不提供原子性保证。
- `ASSIGN` ≠ `WEAK`：不会自动清零，可能悬空。

### 12.5 两个注意点

- 关联对象通常随目标对象生命周期清理；但若关联值**强引用回目标对象**，会形成循环引用。
- `objc_removeAssociatedObjects(person)` 会清掉**所有**关联（包括别人加的）。只想删一项，应把对应 key 的 value 设为 `nil`。

### 12.6 三者的关系

```
@property           →  声明属性接口（名称、类型）
getter / setter  →  真正的读写行为（Category 中需自己实现）
关联对象 API      →  为对象附加数据，不改变实例布局
```

声明属性不会自动创建关联对象；关联对象也不会自动生成 getter/setter。需要手动把它们连起来。

---

## 十三、Runtime 元数据 API

### 13.1 三个概念先分清

```objc
@interface Person : NSObject {
    NSInteger _age;              // 实例变量 Ivar
}
@property (nonatomic, copy) NSString *name;   // 属性 Property
- (void)eat;                                  // 方法 Method
@end
```

| 概念 | 说明 | 对应 API |
| --- | --- | --- |
| 属性 Property | 描述"对象有一个叫 name 的属性接口" | `class_copyPropertyList` |
| 实例变量 Ivar | 对象实例中真正存储数据的槽位 | `class_copyIvarList` |
| 方法 Method | 对象能响应的一种消息 | `class_copyMethodList` |

普通类中 `@property name` 通常会自动合成 `_name` 和 getter/setter；Category 中不会。**属性描述、实际存储、方法实现是三个层面。**

### 13.2 属性列表

```objc
unsigned int count = 0;
objc_property_t *properties = class_copyPropertyList(Person.class, &count);

for (unsigned int i = 0; i < count; i++) {
    objc_property_t property = properties[i];
    const char *name = property_getName(property);          // 属性名
    const char *attrs = property_getAttributes(property);   // 属性特征串
    NSLog(@"属性名称：%s", name);
}
free(properties);   // 必须释放数组
```

- `objc_property_t` 是属性元数据类型。
- `outCount` 是输出参数，接收数量。
- `free` 释放的是**属性列表数组**，不是对象、也不是属性本身。

### 13.3 实例变量列表

```objc
unsigned int count = 0;
Ivar *ivars = class_copyIvarList(Person.class, &count);

for (unsigned int i = 0; i < count; i++) {
    Ivar ivar = ivars[i];
    const char *name = ivar_getName(ivar);                 // 变量名，如 _age
    const char *type = ivar_getTypeEncoding(ivar);         // 类型编码
    NSLog(@"变量名：%s，类型编码：%s", name, type);
}
free(ivars);
```

属性名与实例变量名不是一回事：属性 `name`、实例变量 `_name`、getter `name`、setter `setName:`，是四份不同的元数据。

### 13.4 方法列表

```objc
unsigned int count = 0;
Method *methods = class_copyMethodList(Person.class, &count);

for (unsigned int i = 0; i < count; i++) {
    SEL selector = method_getName(methods[i]);
    NSLog(@"方法名称：%@", NSStringFromSelector(selector));
}
free(methods);
```

若 `Person` 实现了 `eat` 且 `name` 自动合成，列表可能包含：`eat`、`name`、`setName:`。

### 13.5 三个 API 的共同陷阱

| API | 获取内容 | 是否自动包含父类 |
| --- | --- | --- |
| `class_copyPropertyList` | 属性元数据 | **否** |
| `class_copyIvarList` | 实例变量元数据 | **否** |
| `class_copyMethodList` | 方法列表 | **否** |

三者都**只返回该类自己声明的**内容。要收集整条继承链，需要配合：

```objc
Class superclass = class_getSuperclass(Student.class);
```

逐级向上遍历。

> 这与消息查找不同：**能调用的方法 ≠ 本类自己实现的方法**。`Student` 能调用 `eat`，但 `eat` 可能只出现在 `Person` 的方法列表里。

### 13.6 获取单个实例变量

```objc
Ivar ivar = class_getInstanceVariable(Person.class, "_age");
const char *name   = ivar_getName(ivar);
ptrdiff_t   offset = ivar_getOffset(ivar);   // 相对对象起始位置的偏移量
```

与 `class_copyIvarList` 不同，`class_getInstanceVariable` **会沿继承链查找**。

偏移量属于 Runtime 元数据中的布局信息，**不代表**可以在业务代码里随意做指针运算改内存。

---

## 十四、总表与十个易错点

### 14.1 各机制解决什么问题

| 机制 | 核心 API / 概念 | 解决的问题 |
| --- | --- | --- |
| 对象模型 | `isa`、`superclass`、元类 | 对象属于哪个类？从哪开始找？ |
| 方法标识 | `SEL`、`Method`、`IMP` | 找哪个方法？信息是什么？执行哪段代码？ |
| 消息派发 | `objc_msgSend` | 一条消息如何被派发出去 |
| 方法查找 | 方法列表、父类链、Cache | 去哪里找实现？如何加速重复查找？ |
| 动态方法解析 | `resolveInstanceMethod:`、`class_addMethod` | 方法不存在时，如何补上实现 |
| 快速转发 | `forwardingTargetForSelector:` | 换一个对象来接收消息 |
| 完整转发 | `methodSignatureForSelector:`、`forwardInvocation:` | 用 `NSInvocation` 灵活处理消息 |
| 方法交换 | `method_exchangeImplementations` | 改变已有方法与实现的绑定 |
| 分类 | Category 元数据 | 不修改源码扩展方法 |
| 关联对象 | `objc_set/getAssociatedObject` | 不改变实例布局附加数据 |
| 元数据读取 | `class_copy*List`、`class_getInstanceVariable` | 观察类声明了什么 |

### 14.2 十个易错点

1. **根元类的 `superclass` 指向根类**，但根元类不是根类。
2. **`isa` 与 `superclass` 是两种关系**，可以交叉连接，不矛盾。
3. **方法查找不是"对象 → 父类 → 元类"**：实例方法走类链，类方法走元类链。
4. **元类不是实例方法查找的下一站**，走哪条链由接收者类型决定。
5. **缓存未命中 ≠ 方法不存在**，只是这次没直接命中。
6. **找到父类方法 ≠ 复制进子类方法列表**，继承靠沿链查找实现。
7. **`SEL` 不含参数类型**，`eat:` 无法靠参数类型重载。
8. **`class_getInstanceMethod` 可能返回父类方法**，直接交换/修改会波及父类。
9. **Category 中 `@property` ≠ 有存储、有 getter/setter**。
10. **`OBJC_ASSOCIATION_ASSIGN` ≠ `weak`**，不会自动清零。

### 14.3 一条主线收尾

```
[person eat]
   │
   ├─ isa 找到 Person 类
   ├─ 查 Cache ──命中──▶ IMP ──▶ 执行
   │      └─未命中─▶ 方法列表 ─▶ superclass 链 ─▶ IMP ─▶ 执行（并缓存）
   │
   └─ 全部失败
          ├─ 动态方法解析：补实现
          ├─ 快速转发：换接收者
          ├─ 完整转发：NSInvocation 处理
          └─ doesNotRecognizeSelector: → 崩溃
```

Runtime 的所有知识点，都是这条链上的不同环节，而不是彼此独立的 API 清单。

---

## 十五、自测清单

能不看笔记回答出来，说明这一节掌握了：

- [ ] 画出实例对象、类对象、元类、根类、根元类之间的 `isa` 与 `superclass` 关系。
- [ ] 解释为什么根元类的 `isa` 指向自己，而 `superclass` 指向根类。
- [ ] 说明 `SEL`、`Method`、`IMP` 各自回答什么问题，以及为什么 `SEL` 不能区分仅参数类型不同的方法。
- [ ] 说出实例方法和类方法各自沿哪条链查找，并解释"元类不是下一站"。
- [ ] 解释方法缓存为什么存在、缓存的是什么、未命中意味着什么。
- [ ] 用一句话说明 `objc_msgSend` 与 `IMP` 的区别。
- [ ] 按顺序说出方法查找失败后的三个补救阶段及各自的核心方法。
- [ ] 解释 `+load` 中 Swizzling 后 `[self log_eat]` 为什么不递归。
- [ ] 区分 `class_addMethod`、`class_replaceMethod`、`method_setImplementation`、`method_exchangeImplementations`。
- [ ] 解释 Category 为什么能加方法却不能加实例变量，以及关联对象如何弥补。
- [ ] 说明 `class_copyMethodList` 为什么拿不到父类方法，以及怎么补。
- [ ] 说出 `OBJC_ASSOCIATION_ASSIGN` 与 `weak` 的区别。

---

## 附：建议的复习顺序

如果某些部分仍然模糊，按这个顺序回看，每一步只解决一个问题，并始终用同一组 `Person` / `Animal` / `Dog` 例子：

1. 对象、类与 `isa`：实例对象和类对象是什么关系。
2. `SEL`、`IMP` 与方法查找：`[person eat]` 到底怎么找到实现。
3. 父类链、元类链与方法缓存：两条查找路径 + 加速机制。
4. 动态方法解析与消息转发：调用失败后的异常路径。
5. 方法交换与 Category：如何在运行时改变行为。

> 不必一次啃完所有源码细节（`cache_t` 结构、哈希扩容、汇编优化）。先把"消息如何找到并执行方法"这条主线走通，后面的内容才有位置可放。
