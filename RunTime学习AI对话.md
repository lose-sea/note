那根元类是继承根类的

对，你可以这样理解，不过要把“继承”和“指针指向”区分开。

在典型的 Apple Objective-C Runtime 模型中，根元类的 `superclass` 指向根类 `NSObject` 的普通类对象。 因此，从 `superclass` 指针关系来看，根元类的父类就是 `NSObject` 普通类对象。

我们把这条链单独列出来：

NSObject 元类（根元类）



superclass 指向

NSObject 普通类对象（根类）

这里有两个容易混淆的概念：

+ 根类：普通类继承体系中的根节点，例如 `NSObject`。
+ 根元类：元类继承体系中的根节点，也就是 `NSObject` 的元类。

同时，根元类还有另一条不同的指针关系：

```
NSObject 元类 —isa→ NSObject 元类自身
```

所以要记住：

+ `superclass`：根元类 → `NSObject` 普通类对象。
+ `isa`：根元类 → 根元类自身。

结论：根元类的 `superclass` 指向根类，但根元类本身不是根类；它是根类对应的元类。

但是根类的isa指针又指向根元类

对！你现在发现了 Objective-C Runtime 类层级中一个非常关键的关系：根类的 `isa` 指向根元类，而根元类的 `superclass` 又指向根类。

这两个指针连接起来，就形成了一个特殊的结构。

## 一、把三个关系放在一起看

在典型的 Apple Objective-C Runtime 模型中：

NSObject 普通类对象

isa ↓



NSObject 元类（根元类）

isa 指向自己



根元类的 superclass 指回 NSObject 普通类对象

具体来说：

1. `NSObject` 普通类对象的 `isa` → `NSObject` 元类。
2. `NSObject` 元类的 `isa` → `NSObject` 元类自身。
3. `NSObject` 元类的 `superclass` → `NSObject` 普通类对象。

## 二、为什么这不矛盾？

因为 `isa` 和 `superclass` 表达的是两种完全不同的关系。

| 指针         | 表达的关系                         |
| ------------ | ---------------------------------- |
| `isa`        | 这个对象对应哪个类对象或元类       |
| `superclass` | 这个类对象或元类在继承体系中的父类 |

所以，根类的 `isa` 指向根元类，说明根类对象也有对应的元类；根元类的 `superclass` 指向根类，则是元类继承体系中的特殊连接。

你可以把它理解为：`isa` 负责连接类与元类，`superclass` 负责连接继承关系。两种关系可以交叉连接，并不冲突。

那isa这一块我基本我基本掌握了,继续给我讲解Runtime

既然你已经基本掌握了 `isa`，我们就继续学习 Objective-C Runtime。

接下来我建议进入 Runtime 的第二个核心知识点：方法的本质与方法查找机制。你刚刚已经理解了普通类、元类、`isa` 和 `superclass` 的关系，现在正好可以把这些知识串联起来，理解 Objective-C 调用一个方法时，底层究竟发生了什么。

# 下一节：Objective-C Runtime 的方法机制

## 一、先明确 Runtime 到底负责什么

Objective-C Runtime 是 Objective-C 的运行时系统。它让程序能够在运行过程中处理对象、类、方法以及消息发送等操作。

例如：

```
Person *person = [[Person alloc] init];
[person sayHello];
```



我们平时把 `[person sayHello]` 理解为调用 `person` 的 `sayHello` 方法。

但从 Runtime 的角度来看，这段代码涉及几个重要步骤：

1. 发送消息

向 person 发送 sayHello 消息



2. 确定查找起点

通过 isa 找到 Person 类



3. 查找方法

查询缓存，再根据需要查找方法列表及父类



4. 执行方法实现

找到对应的 IMP，并按调用约定执行

这是一种便于学习的概念模型。实际 Runtime 还涉及消息派发的具体实现、缓存和动态方法解析等细节。

## 二、方法在 Runtime 中是什么？

先看一个普通的 Objective-C 类：

```
@interface Person : NSObject

- (void)sayHello;

@end

@implementation Person

- (void)sayHello {
    NSLog(@"Hello");
}

@end
```



这里有三个概念需要掌握：

| 概念     | 含义                         | 示例                           |
| -------- | ---------------------------- | ------------------------------ |
| `SEL`    | 方法选择器，标识要调用的方法 | `@selector(sayHello)`          |
| `Method` | Runtime 中描述方法的结构     | 包含方法相关信息               |
| `IMP`    | 方法实现的入口               | 指向 `sayHello` 对应的实现函数 |

这三个概念是理解 Runtime 方法机制的基础。

### 1. SEL：方法选择器

```
SEL selector = @selector(sayHello);
```



`SEL` 表示方法的选择器，可以理解为 Runtime 用来识别方法名称的标识。

例如：

```
- (void)sayHello;
- (void)run;
```



它们分别对应不同的选择器：

```
@selector(sayHello)
@selector(run)
```



需要注意：`SEL` 标识的是方法，不代表方法实现本身。

而且，选择器主要由方法名及参数标签构成，不包含参数类型和返回类型。例如：

```
- (void)eat:(NSString *)food;
- (void)eat:(NSInteger)count;
```



这两个方法的选择器都是 `eat:`，即使参数类型不同，选择器也相同。因此，Objective-C 不允许同一个类同时定义这两个仅参数类型不同的方法作为独立重载。

### 2. IMP：方法实现

`IMP` 是指向方法实现函数的指针。

例如：

```
- (void)sayHello {
    NSLog(@"Hello");
}
```



编译后，方法实现会对应一段可执行代码，Runtime 可以通过相应的 `IMP` 找到这段实现。

你可以先这样记：

+ `SEL`：我要调用哪个方法？
+ `IMP`：这个方法对应哪段实现代码？

但要注意，`SEL` 和 `IMP` 并不是一一永久绑定的。不同类可以针对同一个 `SEL` 提供不同的 `IMP`；运行时机制也可以改变方法对应的实现。

### 3. Method：方法描述信息

`Method` 是 Runtime 用来描述方法的结构，包含方法选择器、类型编码以及实现入口等信息。

可以用下面这个简化关系帮助理解：

SEL

标识方法名称，例如 `sayHello`

Method

描述方法的相关信息

IMP

指向具体的方法实现

这只是概念上的关系图，并不表示 `SEL`、`Method`、`IMP` 是简单的三层包含结构。

## 三、把刚学的 `isa` 和方法机制连接起来

假设：

```
@interface Animal : NSObject
- (void)eat;
@end

@interface Person : Animal
@end
```



现在执行：

```
Person *person = [[Person alloc] init];
[person eat];
```



你已经知道，`person` 的 `isa` 指向 `Person` 类对象。

接下来，Runtime 就可以从 `Person` 类开始查找 `eat`：

1. 检查 `Person` 类的方法缓存。
2. 如果没有命中，查找 `Person` 的方法列表。
3. 如果仍然没有找到，沿 `superclass` 找到 `Animal` 类。
4. 找到 `eat` 对应的方法实现后，执行相应的 `IMP`。

这里有一个重要细节：`Person` 即使没有自己实现 `eat`，也可以继承并调用 `Animal` 的 `eat`。

这就是你前面学习的 `isa`、`superclass` 和现在的 `SEL`、`Method`、`IMP` 之间的联系。

## 四、接下来应该按什么顺序学？

建议按照以下顺序推进，不需要一下子深入所有 Runtime 细节。



第一阶段：对象与类的结构

`isa`、元类、`superclass`、根元类。

基本掌握



第二阶段：方法机制

`SEL`、`Method`、`IMP`、方法列表、方法缓存和方法查找。

当前学习



第三阶段：动态消息机制

动态方法解析、快速转发、完整消息转发。



第四阶段：Runtime 实际应用

Method Swizzling、Category、关联对象等。

下一步我们就从 `SEL`、`Method`、`IMP` 的区别开始深入，再讲方法缓存为什么存在、Runtime 如何查找方法。 先把这条主线理解透，再进入动态方法解析和消息转发，就不会只是零散地记 Runtime 知识点。

继续

我们继续学习 Objective-C Runtime。上一节已经讲了 `SEL`、`Method`、`IMP` 的基本区别，这一节继续深入：Runtime 的方法列表是什么、方法缓存为什么存在，以及一次方法查找究竟是怎样完成的。

这部分是连接你已经学过的 `isa`、`superclass` 和后续动态方法解析的关键。

# 一、类里面究竟保存了什么方法信息？

先看一个简单的类：

```
@interface Person : NSObject

- (void)eat;
- (void)run;

@end

@implementation Person

- (void)eat {
    NSLog(@"吃饭");
}

- (void)run {
    NSLog(@"跑步");
}

@end
```



编译之后，Runtime 会通过类的相关结构管理方法信息。为了便于理解，可以把 `Person` 类想象成拥有一份方法列表：

Person 类对象

包含指向类相关运行时数据的引用



方法列表（概念示意）

```
eat
```

SEL： `eat`

IMP：对应的吃饭实现

```
run
```

SEL： `run`

IMP：对应的跑步实现

这张图是帮助理解的简化模型，不代表 Runtime 内部只有这样一个固定数组。

每个方法都可以关联到一些重要信息：

+ `SEL`：方法选择器，标识方法名称。
+ 类型编码：描述方法的参数、返回值等类型信息。
+ `IMP`：方法实现的入口。

例如，`eat` 和 `run` 是不同的方法选择器，也对应不同的方法实现。

这里还有一个关键区别：类的方法列表描述这个类直接拥有的方法，不等于这个类能够调用的所有方法。

例如：

```
@interface Animal : NSObject
- (void)eat;
@end

@interface Person : Animal
- (void)run;
@end
```



`Person` 可以调用 `eat`，但 `eat` 是 `Animal` 定义的方法。正常的继承关系下，Runtime 可以沿父类链找到它，而不必把父类的每个方法都复制进 `Person` 的方法列表。

# 二、Runtime 为什么需要方法缓存？

如果每次调用方法都从当前类开始，逐个检查方法列表，再沿着父类不断向上查找，会产生额外开销。

例如：

```
Person *person = [[Person alloc] init];

[person eat];
[person eat];
[person eat];
```



假设 `eat` 定义在 `Animal` 中，而 `Person` 没有实现它。

第一次查找时，Runtime 可能需要：

1. 检查 `Person` 的缓存。
2. 检查 `Person` 的方法列表。
3. 沿 `superclass` 找到 `Animal`。
4. 在 `Animal` 中找到 `eat` 对应的实现。

那么第二次、第三次调用，还需要完整重复这套查找吗？

通常不需要，因为 Runtime 使用方法缓存（Cache）来加速后续查找。

## 1. 第一次调用：缓存未命中

```
[person eat]
```



查询 Person 的方法缓存

未命中



检查 `Person` 的方法列表

没有找到 eat



检查 Animal 的方法

找到 eat 对应的实现

## 2. 后续调用：缓存命中

```
[person eat]
```



查询 Person 的方法缓存

命中

直接获得对应的实现入口

可以把缓存理解为一种加速机制：Runtime 记录已经查找到的方法信息，以便之后更快地定位实现。

需要注意，真实 Runtime 的缓存会受到方法替换、缓存清理等机制影响，因此不是某个方法一旦缓存，就永远不再发生查找。

# 三、方法缓存里面保存的是什么？

这是一个很重要的问题。

在概念层面，方法缓存可以理解为一组映射关系：

SEL⟶IMPSEL⟶IMP

例如：

| SEL   | 对应的 IMP         |
| ----- | ------------------ |
| `eat` | 吃饭方法的实现入口 |
| `run` | 跑步方法的实现入口 |

当 Runtime 需要查找 `eat` 时，可以通过选择器找到对应的实现入口。

不过要注意：缓存的组织方式和实际存储结构由 Runtime 实现决定。上表是理解用的示意，不代表内部就是普通的字典或简单数组。

还有一点容易混淆：

+ 方法列表用于描述类的方法信息。
+ 方法缓存用于加速方法查找。
+ `IMP` 是方法实现的入口。

三者有关联，但并不是同一个东西。

# 四、如果子类没有方法，父类的方法会缓存在哪里？

继续看这个例子：

```
@interface Animal : NSObject
- (void)eat;
@end

@interface Person : Animal
@end
```



执行：

```
Person *person = [[Person alloc] init];
[person eat];
```



这里的 `eat` 定义在 `Animal` 中。

假设第一次调用时，Runtime 沿继承链找到了 `Animal` 的 `eat`，那么需要特别理解：

找到父类的方法，并不意味着这个方法会被复制到子类的方法列表中。

方法缓存是另外一回事。Runtime 可以将查找到的实现缓存到与当前查找相关的缓存中，以便加速后续调用。具体缓存细节取决于 Runtime 的实现，不能简单理解为“父类方法被复制进了子类”。

你只需要牢牢记住：

1. 继承让子类能够使用父类的方法。
2. 方法查找沿继承关系进行。
3. 缓存是优化查找的机制，不等于继承本身。

# 五、把整个方法查找过程串起来

现在将你已经学过的知识整合起来。

当执行：

```
Person *person = [[Person alloc] init];
[person eat];
```



概念上的过程可以这样理解：

发送消息

向 person 发送 eat 消息



通过 isa 确定 Person 类



查询方法缓存

命中则快速获得实现；未命中则继续查找



查找方法列表及父类

通过 superclass 沿继承链查找



获得 IMP 并执行方法实现

如果正常方法查找最终失败，Runtime 还可能进入动态方法解析和消息转发机制，这就是后面要学习的内容。

## 六、这一节最重要的四个结论

+ `SEL` 标识要查找的方法。
+ `Method` 描述方法相关信息。
+ `IMP` 指向方法实现的入口。
+ 方法缓存 用来加速方法查找，减少重复搜索的开销。

你现在可以把 Runtime 方法机制的主线记成：

```
isa 确定查找起点 → Cache 加速查找 → 方法列表与父类链 → 找到 IMP 并执行
```

下一步最合适的是继续理解 `objc_msgSend`：为什么 `[person eat]` 不只是普通的函数调用，以及 Objective-C 的消息发送机制如何与方法查找配合工作。

继续学习

我们继续。上一节你已经了解了 `SEL`、`Method`、`IMP`、方法列表和方法缓存。现在进入下一个核心知识点：`objc_msgSend`——Objective-C 的消息发送机制。

这一节最重要的不是记函数名，而是理解：为什么我们写的是 `[person eat]`，Runtime 却能根据对象的实际类型找到对应的方法实现。

# 一、Objective-C 为什么叫“消息发送”？

先看一段熟悉的代码：

```
@interface Person : NSObject
- (void)eat;
@end

@implementation Person

- (void)eat {
    NSLog(@"吃饭");
}

@end

Person *person = [[Person alloc] init];
[person eat];
```



在 Objective-C 中：

```
[person eat];
```



通常称为向 `person` 发送 `eat` 消息。

它和普通 C 函数调用的思路有所不同。

普通 C 函数调用

```
add(1, 2);
```



调用一个明确的函数，传入参数。

Objective-C 消息发送

```
[person eat];
```



向接收者 person 发送 eat 消息，由 Runtime 根据运行时信息确定如何处理。

这并不意味着 C 函数调用一定没有间接调用，也不意味着 Objective-C 每次调用都要从头遍历整个继承链。关键区别在于：Objective-C 的方法调用机制包含运行时的消息派发。

# 二、`objc_msgSend` 是什么？

`objc_msgSend` 是 Objective-C Runtime 中负责消息派发的核心函数之一。

我们写：

```
[person eat];
```



在概念层面，可以理解为：

```
objc_msgSend(person, @selector(eat));
```



这段代码用于说明消息发送的基本关系。实际编译生成的调用还会受到架构、参数、返回值以及编译器优化等因素影响，不能把所有 Objective-C 方法调用都机械地替换成这一行代码。

这行示意代码包含三个关键部分：

| 部分             | 含义                       |
| ---------------- | -------------------------- |
| `objc_msgSend`   | 执行消息派发               |
| `person`         | 消息接收者                 |
| `@selector(eat)` | 要发送的消息所对应的选择器 |

你之前学过的 `SEL` 就在这里发挥作用。

`@selector(eat)` 得到的是一个 `SEL`，用来标识 `eat` 这个方法选择器。

注意：`objc_msgSend` 不等于 `IMP`。

+ `objc_msgSend` 负责消息派发。
+ `IMP` 是某个方法实现的入口。
+ 消息派发过程中，Runtime 会根据查找结果找到适当的实现并执行。

# 三、`objc_msgSend` 如何利用你学过的 `isa`？

现在把前面学过的知识全部串起来。

假设有：

```
@interface Animal : NSObject
- (void)eat;
@end

@interface Person : Animal
@end
```



并且 `eat` 定义在 `Animal` 中。

调用：

```
Person *person = [[Person alloc] init];
[person eat];
```



概念上的过程如下：

① 发送消息

```
[person eat]
```



② 确定查找起点

`person` 的 `isa` 关联到 `Person` 类



③ 查找方法

先查缓存，必要时检查方法列表和父类



④ 找到实现并执行

在 `Animal` 中找到 `eat` 对应的 `IMP`

现在你可以看出各个知识点之间的联系了：

+ `isa`：帮助确定查找起点。
+ `SEL`：标识要查找的方法。
+ 方法缓存：加速查找。
+ `superclass`：连接父类，支持继承查找。
+ `IMP`：指向具体的方法实现。
+ `objc_msgSend`：负责消息派发。

这些不是互不相关的知识点，而是同一套消息机制中的不同部分。

# 四、如果子类和父类都实现了同一个方法呢？

这是理解消息派发的一个重要场景。

```
@interface Animal : NSObject
- (void)eat;
@end

@implementation Animal

- (void)eat {
    NSLog(@"Animal 吃饭");
}

@end

@interface Person : Animal
@end

@implementation Person

- (void)eat {
    NSLog(@"Person 吃饭");
}

@end
```



调用：

```
Person *person = [[Person alloc] init];
[person eat];
```



输出：

```
Person 吃饭
```

为什么？

因为消息接收者是 `person`，它的 `isa` 指向 `Person` 类。正常的实例方法查找会先从 `Person` 开始。

既然 `Person` 自己就实现了 `eat`，Runtime 就会使用 `Person` 对应的实现，而不是继续向父类查找同名方法。

这就是方法覆盖（Override）在消息派发中的表现。

需要注意：Runtime 并不是简单地按方法名在所有类中寻找一个随意的实现，而是根据接收者、选择器和类的继承关系进行派发。

# 五、如果找不到方法，会发生什么？

现在假设：

```
@interface Person : NSObject
@end

Person *person = [[Person alloc] init];
[person eat];
```



`Person` 和它的父类都没有提供可用的 `eat` 实现。

Runtime 并不一定会在第一次查找失败后立刻报错，而是还可能进入后续的消息处理机制。

主要包括：

1. 动态方法解析：给类机会动态提供方法实现。
2. 快速消息转发：尝试把消息交给另一个对象处理。
3. 完整消息转发：通过方法签名和 `NSInvocation` 等机制进一步处理消息。
4. 如果仍然无法处理，通常会触发 `doesNotRecognizeSelector:`，最终导致异常。

这些机制就是你后面要学的动态方法解析和消息转发。

这里先记住：方法查找失败，不等于 Runtime 立刻停止处理；它还有后续机制可以尝试处理这条消息。

# 六、你现在应该建立的 Runtime 主线



对象与类的关系

```
isa`、元类、`superclass
```

已学习



方法查找机制

`SEL`、`Method`、`IMP`、Cache、继承查找

已学习基础



消息派发

`objc_msgSend`、消息接收者、选择器、方法实现

当前学习



消息处理失败后的机制

动态方法解析、快速转发、完整消息转发



Runtime 实际应用

Method Swizzling、Category、关联对象

下一步，我们可以继续深入 `objc_msgSend` 的完整查找流程：缓存命中与未命中、父类查找、动态方法解析之间的关系。这样你就能把消息发送、方法查找和消息转发真正连成一条主线。

继续学习

我们继续学习 Objective-C Runtime。上一节已经讲到 `objc_msgSend`，接下来把方法查找、缓存、动态方法解析这几个概念真正串起来。

这一节先不涉及 Method Swizzling 等后续内容，重点是弄清楚：当你调用一个对象的方法时，Runtime 到底是怎样找到并执行对应代码的。

# 一、从一行代码开始

假设我们有下面的类：

```
@interface Person : NSObject
- (void)eat;
@end

@implementation Person

- (void)eat {
    NSLog(@"Person 正在吃饭");
}

@end
```



调用：

```
Person *person = [[Person alloc] init];
[person eat];
```



表面上看，你是在调用 `person` 的 `eat` 方法。

但从 Runtime 的角度看，关键问题是：

当前对象是谁？要调用的方法是什么？这个方法对应的实现代码在哪里？

这三个问题分别对应消息接收者、`SEL` 和 `IMP`。



1. 消息接收者：`person`

决定从哪个类开始查找方法。



2. 方法选择子：`@selector(eat)`

标识这次消息想调用的方法。



3. 方法实现：`IMP`

指向最终要执行的实现代码入口。

# 二、`objc_msgSend` 怎样查找方法？

你可以先把 `[person eat]` 理解为一次 Objective-C 消息发送。概念上，它会进入 `objc_msgSend` 对应的消息派发机制。

完整的高层流程如下：

发送消息

```
[person eat]
```



确定查找起点

```
person → isa → Person
```



查询方法缓存 Cache

命中

取得实现入口

未命中

继续查找



查找方法列表，必要时沿继承链查找



找到 `IMP`，执行方法实现

注意，这是一张帮助理解的概念图，不是 Runtime 内部每条指令的精确执行顺序。实际实现会涉及缓存优化和不同版本的内部机制。

## 1. 为什么先查 Cache？

假设 `person` 已经调用过多次 `eat`。

如果每次调用都重新扫描 `Person` 的方法列表，甚至继续查找父类，会产生不必要的开销。

所以 Runtime 使用方法缓存，记录已经找到的方法实现，以便后续快速查找。

你可以把它理解为：

+ 第一次查找： 可能需要在方法列表和继承链中寻找。
+ 后续查找： 如果缓存命中，就可以更快地获得方法实现。

缓存不是另外一套方法，也不是方法本身。它是为了加速方法查找而使用的数据结构。

## 2. 缓存没有命中怎么办？

例如：

```
@interface Animal : NSObject
- (void)eat;
@end

@implementation Animal

- (void)eat {
    NSLog(@"Animal 正在吃饭");
}

@end

@interface Person : Animal
@end

@implementation Person
@end
```



现在调用：

```
Person *person = [[Person alloc] init];
[person eat];
```



假设 `Person` 自己没有实现 `eat`，并且缓存中也没有对应条目。

Runtime 会继续查找方法实现。概念上：

1. 检查 `Person` 的方法列表。
2. 如果没有找到，沿着 `Person` 的 `superclass` 关系找到 `Animal`。
3. 在 `Animal` 中找到 `eat` 的实现。
4. 执行该实现。

这里再次体现了你之前学过的两个关键关系：

+ `isa`：确定从哪个类开始查找。
+ `superclass`：决定沿着哪条继承链继续查找。

# 三、如果整个继承链都找不到方法呢？

这是接下来最重要的部分。

假设你写了：

```
Person *person = [[Person alloc] init];
[person dance];
```



但 `Person`、`Animal` 和 `NSObject` 都没有提供 `dance` 方法的实现。

Runtime 不会凭空执行一个不存在的实现。它会进入后续的动态处理机制。

在正常的方法查找无法解决问题时，可以先记住这条高层流程：

正常方法查找失败



动态方法解析

```
resolveInstanceMethod:` 或 `resolveClassMethod:
```



如果仍未解决，尝试消息转发



最终仍无法处理

通常抛出 `unrecognized selector` 异常

需要注意：这是便于学习的总体顺序。动态方法解析如果成功添加了实现，Runtime 可以重新尝试派发；消息转发也不是简单地把原方法实现“找回来”，而是提供其他处理这条消息的机会。

接下来我们先只研究动态方法解析，不把消息转发的细节混在一起。

# 四、动态方法解析是什么？

动态方法解析的核心思想是：

当 Runtime 找不到某个方法时，允许类在特定回调中动态提供这个方法的实现。

对于实例方法，使用：

```
+ (BOOL)resolveInstanceMethod:(SEL)sel;
```



注意这里有两个容易混淆的地方：

1. `resolveInstanceMethod:` 本身是一个类方法，所以声明前面是 `+`。
2. 它要解决的问题是：某个实例方法能否被动态补充。

例如，调用：

```
[person dance];
```



如果正常查找失败，Runtime 可以调用 `Person` 的动态解析方法，让类有机会为 `dance` 提供实现。

## 用代码理解动态添加方法

```
#import <objc/runtime.h>

static void danceImplementation(id self, SEL _cmd) {
    NSLog(@"动态添加的 dance 方法");
}

@implementation Person

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    if (sel == @selector(dance)) {
        class_addMethod(self,
                        sel,
                        (IMP)danceImplementation,
                        "v@:");

        return YES;
    }

    return [super resolveInstanceMethod:sel];
}

@end
```



当调用：

```
Person *person = [[Person alloc] init];
[person dance];
```



假设这次调用进入动态解析，并且添加方法成功，那么 `danceImplementation` 就成为 `dance` 对应的实现。

这里几个细节必须弄清楚。

+ `sel`：当前尝试解析的方法选择子，这里是 `dance`。
+ `class_addMethod`：尝试给指定的类添加方法。
+ `self`：在这个类方法中，代表当前接收类方法消息的类对象，也就是这里的 `Person`。
+ `danceImplementation`：真正执行的 C 函数。
+ `"v@:"`：方法类型编码，表示无返回值、包含接收者参数和选择子参数，不包含其他显式参数。

`class_addMethod` 的返回值表示是否成功添加。如果方法已经存在，或者添加失败，就不能仅凭这次调用认定添加成功。

此外，`resolveInstanceMethod:` 返回 `YES` 表示解析处理已完成；通常意味着方法已被成功提供，Runtime 随后可以重试查找。返回 `YES` 本身并不会自动创建方法，真正添加实现的是 `class_addMethod`。

这段代码的目的不是让你现在背诵 API，而是建立一个重要认知：

以前我们认为方法实现是在编译时就写好的；而通过 Runtime，类也可以在运行时为某个选择子补充实现。

## 本节的知识主线

到这里，你需要把四个概念连接起来：

| 概念                    | 作用                                   |
| ----------------------- | -------------------------------------- |
| `objc_msgSend`          | 进入 Objective-C 消息派发机制          |
| Cache                   | 加速已经查找过的方法的派发             |
| 方法列表与 `superclass` | 在缓存未命中时寻找可用实现             |
| 动态方法解析            | 正常查找失败时，允许类动态补充方法实现 |

下一步适合继续学习 消息转发机制：为什么动态方法解析失败后，Runtime 还会给对象一次处理消息的机会，以及 `forwardingTargetForSelector:`、`methodSignatureForSelector:` 和 `forwardInvocation:` 分别承担什么职责。













继续

我们继续学习 Objective-C Runtime 第五课：方法查找机制与方法缓存（Method Cache）。

前面你已经学过：

+ `objc_msgSend`：消息发送机制的核心入口之一。
+ `SEL`：标识要调用的方法。
+ `IMP`：指向方法实现的函数指针。
+ `isa`：帮助对象关联到所属的类。
+ `super`：指定父类方法查找的起点，而不是更换消息接收者。

现在，我们把这些知识连接起来，回答一个关键问题：

当你执行 `[dog eat]` 时，Runtime 究竟如何找到 `eat` 的实现？为什么同一个方法调用多次，通常不会每次都从头查找？

# 一、先理解方法查找的基本过程

假设我们有两个类。

```
@interface Animal : NSObject
- (void)eat;
@end

@implementation Animal

- (void)eat {
    NSLog(@"Animal eat");
}

@end
```



子类：

```
@interface Dog : Animal
- (void)bark;
@end

@implementation Dog

- (void)bark {
    NSLog(@"Dog bark");
}

@end
```



注意，`Dog` 没有实现 `eat`，只有父类 `Animal` 实现了它。

现在执行：

```
Dog *dog = [[Dog alloc] init];

[dog eat];
```



最终输出：

```
Animal eat
```

为什么？

因为 `Dog` 继承了 `Animal`，因此 `Dog` 对象可以调用从 `Animal` 继承来的实例方法。

我们可以先把 Runtime 的方法查找过程理解为：

1. 发送消息

```
[dog eat]
```



2. 从 Dog 类的查找体系开始

查找选择子 `eat`



3. 当前类没有找到对应实现

沿父类关系继续查找



4. 在 Animal 类中找到实现

执行 `Animal` 的 `eat`

这是帮助理解的逻辑流程。实际 Runtime 还会检查方法缓存，另外，动态方法解析和消息转发也会影响最终处理过程。

## 二、类的方法信息是怎样组织的？

在 Objective-C 中，一个类关联着它的方法信息。方法信息中包含了识别方法、定位实现所需的数据。

可以用下面这个简化模型理解：

| 方法选择子 `SEL` | 方法实现 `IMP`               |
| ---------------- | ---------------------------- |
| `eat`            | `Animal` 中 `eat` 的实现入口 |
| `bark`           | `Dog` 中 `bark` 的实现入口   |

这张表只是概念示意，并不是 Runtime 内部结构的完整定义。

这里有个非常重要的区别：

+ `SEL` 表示要找哪个方法。
+ `IMP` 指向具体的方法实现。
+ 类的方法信息负责将方法选择子与对应的实现关联起来。

而继承意味着：子类可以使用父类的方法，不必把父类的每个方法实现都复制一份到子类中。

因此，当 `Dog` 调用 `eat` 时，Runtime 可以通过继承关系找到 `Animal` 中的实现。

# 三、为什么 Runtime 需要方法缓存？

现在来看本节最重要的知识点。

假设你连续调用同一个方法很多次：

```
Dog *dog = [[Dog alloc] init];

[dog eat];
[dog eat];
[dog eat];
[dog eat];
```



如果每次调用都必须从 `Dog` 开始，逐层检查 `Animal`、`NSObject` 等父类，才能找到 `eat`，就会产生重复的查找工作。

Runtime 因此使用了方法缓存（Method Cache），来加快后续的方法查找。

你可以先这样理解：

+ 第一次查找时，如果缓存中没有对应的方法，Runtime 需要进一步查找。
+ 找到方法实现后，运行时可以缓存相关的查找结果。
+ 后续相同类的相同方法调用，有机会直接命中缓存，快速取得 `IMP`。

这里说的是一般情况下的逻辑模型。实际缓存的填充、查找、失效和更新机制由 Runtime 实现管理。

## 1. 缓存命中（Cache Hit）

假设第一次调用：

```
[dog eat];
```



Runtime 找到了 `Animal` 中 `eat` 的实现。

在适当的情况下，相关结果会被缓存。

之后再次执行：

```
[dog eat];
```



如果对应的缓存项仍然有效，就可能直接命中缓存，不必再次进行完整的方法查找。

发送消息

```
[dog eat]
```



检查方法缓存





缓存命中

取得缓存的 `IMP`



执行方法实现

## 2. 缓存未命中（Cache Miss）

如果缓存中没有对应的方法，Runtime 就需要继续进行方法查找。

例如：

```
Dog *dog = [[Dog alloc] init];

[dog eat];
```



假设相关缓存中没有 `eat`：

1. 从 `Dog` 的方法查找体系开始。
2. 检查 `Dog` 是否有对应的实现。
3. 如果没有，继续沿父类关系查找。
4. 在 `Animal` 中找到 `eat` 的实现。
5. 执行该实现，并在适当情况下缓存查找结果。

发送消息

```
[dog eat]
```



检查方法缓存



缓存未命中

继续查找方法



```
Dog` → `Animal
```

在 `Animal` 中找到 `eat`



执行实现，并在适当情况下更新缓存

这里有一点需要特别注意：缓存未命中不等于方法不存在。 它只表示当前这次缓存查找没有直接找到结果，Runtime 仍然可以继续查找。

# 四、方法缓存究竟缓存什么？

你可能会有一个疑问：

> Runtime 是缓存 `SEL`，还是缓存 `IMP`？

从概念上讲，可以把方法缓存理解成保存了方法选择子到方法实现入口的对应关系。

例如：

| `SEL`  | 缓存的实现入口 |
| ------ | -------------- |
| `eat`  | 对应的 `IMP`   |
| `bark` | 对应的 `IMP`   |

这只是便于理解的表格，不是实际缓存结构的完整表示。

Runtime 在收到消息时，既需要知道要找哪个方法，也需要获得可以执行的实现。因此，缓存方法查找结果能够减少重复工作。

还有一点：方法缓存与类的方法列表不是同一个东西。

+ 方法列表及相关类元数据：用于描述类的方法等信息。
+ 方法缓存：用于加速方法查找。

不要把二者混为一谈。

# 五、方法实现改变后，缓存怎么办？

这是一个很有价值的问题。

Objective-C Runtime 支持动态修改方法实现。例如，开发者可以使用 `method_setImplementation` 或 `method_exchangeImplementations` 等 API 修改方法实现。

假设原本：

```
- (void)eat {
    NSLog(@"Original eat");
}
```



后来通过 Runtime 相关 API 修改了这个方法对应的实现。

那么，之前的缓存还能一直使用旧实现吗？

不能简单地这样理解。

Runtime 必须保证方法实现发生变更时，相关缓存不会导致后续消息调用一直使用失效的结果。 Runtime 会根据具体操作执行必要的缓存维护或失效处理。

具体如何维护缓存，取决于使用的 API 和运行时实现。你目前不需要自己手动管理 Runtime 内部的缓存。

这也说明了 Runtime 的动态性：方法的实现并不总是永远固定不变。

# 六、把方法查找与缓存联系起来

现在回到你最初学习的消息发送：

```
[dog eat];
```



你已经知道它可以从概念上理解为：

```
objc_msgSend(dog, @selector(eat));
```



将本节知识结合起来，就能建立更完整的理解：

发送消息

接收者 `dog`，选择子 `eat`



查找方法缓存



缓存命中

快速取得实现入口



缓存未命中

继续方法查找



取得方法实现并执行

如果常规查找失败，再考虑动态方法解析与消息转发

这张图把前面几节的核心知识连接了起来：消息发送、`SEL`、`IMP`、继承查找和方法缓存。

## 七、本节需要掌握的内容

你现在只需要重点理解四件事：

1. Runtime 可以根据消息接收者所属的类和 `SEL` 查找方法实现。
2. 方法查找涉及继承关系，因此子类可以调用父类实现的方法。
3. 方法缓存用于加速查找；缓存命中不必进行完整的方法查找。
4. 动态修改方法实现时，Runtime 会处理必要的缓存维护，保证机制正常工作。

暂时不用研究 `cache_t` 的内部结构、哈希计算、缓存扩容和源码里的汇编优化。这些属于更深入的 Runtime 源码学习。

下一课：方法查找失败后会发生什么？

我们将学习 Objective-C Runtime 的动态方法解析与消息转发，包括 `resolveInstanceMethod:`、`forwardingTargetForSelector:` 和 `forwardInvocation:`。它们能帮助你理解，为什么一个对象即使最初没有实现某个方法，也不一定会立即崩溃。

方法查找的顺序是从对象开始,顺着父类,元类的顺序吗

不是。你这里把实例方法查找、父类查找、元类查找这几个概念混在一起了。Runtime 的方法查找不是简单地从「对象 → 父类 → 元类」依次进行。

关键是：先看你发送的是实例方法还是类方法，再确定从哪条继承链查找。

## 1. 实例方法：从对象所属的类开始

例如：

```
@interface Animal : NSObject
- (void)eat;
@end

@interface Dog : Animal
@end

Dog *dog = [[Dog alloc] init];
[dog eat];
```



`Dog` 没有实现 `eat`，但 `Animal` 实现了。

实例方法的查找过程可以简化为：

Dog 实例对象 `dog`

通过 isa 找到 Dog 类



Dog 类

查找 eat，未找到



Animal 类

找到 eat 对应的实现 IMP

这里有两个重点：

+ 对象本身通常不直接保存 `eat` 这个方法的实现，而是通过 `isa` 找到所属的类。
+ 如果所属类找不到方法，就沿着父类继承链继续查找。

因此，实例方法的常规查找路径可以记成：

实例对象 → Dog 类 → Animal 类 → 更上层的父类……

注意，这里的“实例对象 → Dog 类”主要表示通过 `isa` 确定从哪个类开始查找，并不是说实例对象自身有一张普通的方法列表供 Runtime 逐个搜索。

## 2. 类方法：从元类相关的继承链查找

再看一个类方法：

```
@interface Animal : NSObject
+ (void)run;
@end

@interface Dog : Animal
@end

[Dog run];
```



这里调用的是 `+run`，也就是类方法。

可以把查找过程简化为：

Dog 类对象

Dog 这个类本身也是一个对象



Dog 的元类（Dog metaclass）

查找类方法 run



沿元类的继承关系继续查找

最终可能找到 Animal 的类方法实现

这里需要特别理解：

+ `Dog` 本身是一个类对象。
+ 类对象也有自己的 `isa`，在 Runtime 的模型中，它指向对应的元类。
+ 元类保存类方法相关的方法信息。
+ 类方法继承也有对应的继承查找机制。

所以，类方法的查找不能简单理解成「先查 Dog 的实例方法列表，再查父类的实例方法列表」。

## 3. 那元类什么时候参与查找？

记住下面这张对照表就够了：

| 调用方式         | 主要查找路径                           |
| ---------------- | -------------------------------------- |
| `[dog eat]`      | `Dog` 类 → `Animal` 类 → 父类          |
| `[Dog run]`      | `Dog` 的元类 → 元类继承链              |
| `[NSObject new]` | 类方法查找机制，沿相关元类继承关系查找 |

还有一个容易混淆的地方：元类也有自己的继承关系，但这不意味着实例方法查找完父类后，就会自动转去元类查找。 这两种查找路径是由消息接收者及其类型决定的。

另外，前面讲过的方法缓存也会影响实际查找过程：如果缓存中已经有对应的方法实现，Runtime 可以直接使用缓存，而不必每次都从头遍历。

你现在可以先牢牢记住这句话：

实例方法主要沿普通类的继承链查找；类方法主要沿元类的继承链查找。元类不是普通实例方法查找完成后才进入的下一站。

继续

我们继续学习 Objective-C Runtime。上一节你已经理解了一个关键点：

+ 实例方法：从对象所属的类开始，沿普通类的继承链查找。
+ 类方法：通过元类相关的继承链查找。
+ 方法缓存：如果已经缓存了对应实现，就可能直接命中，不需要每次从头查找。

接下来进入 Runtime 的下一个重要知识点：动态方法解析与消息转发。

它要解决的问题是：如果一个对象收到了某个消息，但是 Runtime 没有找到对应的方法实现，会发生什么？

## 第六课：动态方法解析与消息转发

### 一、先理解问题：找不到方法就一定崩溃吗？

例如：

```
@interface Person : NSObject
@end

@implementation Person
@end

Person *person = [[Person alloc] init];
[person run];
```



`Person` 没有声明或实现 `run` 方法。

编译器可能会针对这个未知方法给出警告（具体取决于上下文和声明情况）；如果程序运行到这里，Runtime 也找不到正常的 `run` 实现。

那么，程序是不是立刻就崩溃？

不一定会立刻结束方法查找流程。 Objective-C 提供了动态方法解析和消息转发机制，让对象有机会动态处理这个消息。

可以先记住这个概念流程：

1. 正常方法查找

检查缓存、当前类及继承链



2. 动态方法解析

尝试动态添加方法实现



3. 快速消息转发

尝试把消息交给另一个对象



4. 完整消息转发

通过 NSInvocation 处理或转发消息



5. 仍然无法处理

通常触发 doesNotRecognizeSelector:，抛出异常

这是一张便于学习的概念图。实际运行时还有缓存重试等细节，但掌握这条主线，就能理解后续的三个机制。

### 二、第一阶段：动态方法解析 `resolveInstanceMethod:`

动态方法解析的核心思想是：

方法一开始不存在，但可以在运行时动态地把方法添加进去。

例如，`Person` 没有实现 `run`，我们可以在 Runtime 发现它找不到 `run` 时，动态添加这个方法。

```
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@implementation Person

void runIMP(id self, SEL _cmd) {
    NSLog(@"动态添加的 run 方法");
}

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    if (sel == @selector(run)) {
        class_addMethod(
            self,
            sel,
            (IMP)runIMP,
            "v@:"
        );
        return YES;
    }

    return [super resolveInstanceMethod:sel];
}

@end
```



调用：

```
Person *person = [[Person alloc] init];
[person performSelector:@selector(run)];
```



如果动态添加成功，输出：

```
动态添加的 run 方法
```

下面逐个解释关键代码。

1. `resolveInstanceMethod:` 是什么？

```
+ (BOOL)resolveInstanceMethod:(SEL)sel
```



它是一个类方法。当 Runtime 无法正常找到某个实例方法时，会给相应的类机会，让它尝试解决这个问题。

+ `sel`：当前找不到的实例方法的选择子。
+ 返回 `YES`：表示已经处理这个方法解析问题。
+ 返回 `NO`：表示没有解决，后续可以进入消息转发流程。

这里有个重要细节：返回 `YES` 本身不等于方法实现一定正确。通常应该先成功添加方法，再返回 `YES`。

2. `class_addMethod` 做了什么？

```
class_addMethod(self, sel, (IMP)runIMP, "v@:");
```



这个函数用于给指定的类添加方法。

| 参数          | 含义                                    |
| ------------- | --------------------------------------- |
| `self`        | 当前正在解析的类，也就是这里的 `Person` |
| `sel`         | 要添加的方法选择子，即 `run`            |
| `(IMP)runIMP` | 方法对应的 C 函数实现                   |
| `"v@:"`       | 方法类型编码                            |

`"v@:"` 可以这样理解：

+ `v`：返回类型为 `void`。
+ `@`：隐含参数 `self`，即对象。
+ `:`：隐含参数 `_cmd`，即方法选择子。

因此，`runIMP` 的函数签名要与这个方法的实际调用约定相匹配。如果方法有参数或返回值，类型编码和实现也必须相应调整。

另外，`class_addMethod` 不会覆盖类中已经存在的同名选择子对应的方法。

3. 为什么可以使用普通 C 函数作为实现？

```
void runIMP(id self, SEL _cmd) {
    NSLog(@"动态添加的 run 方法");
}
```



这是因为 Objective-C 方法的底层实现本质上是一个函数入口，Runtime 使用 `IMP` 来表示它。

正常情况下，编译器会帮你生成方法实现和相应的元数据；这里则是我们主动把一个符合约定的函数注册为方法实现。

注意：示例中的 `run` 没有声明在 `Person` 的接口中，因此 `performSelector:` 只是为了避免直接调用未声明方法时的编译器警告，并不是动态方法解析的必要条件。

### 三、第二阶段：快速消息转发 `forwardingTargetForSelector:`

如果动态方法解析没有解决问题，Runtime 还可以尝试把消息转交给另一个对象。

例如，`Person` 不会开车，但 `Driver` 会开车。我们可以让 `Person` 把 `drive` 消息转发给 `Driver`。

```
@interface Driver : NSObject
- (void)drive;
@end

@implementation Driver

- (void)drive {
    NSLog(@"Driver 正在开车");
}

@end

@interface Person : NSObject
@property (nonatomic, strong) Driver *driver;
@end

@implementation Person

- (instancetype)init {
    self = [super init];
    if (self) {
        _driver = [[Driver alloc] init];
    }
    return self;
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if (aSelector == @selector(drive)) {
        return self.driver;
    }

    return [super forwardingTargetForSelector:aSelector];
}

@end
```



调用：

```
Person *person = [[Person alloc] init];
[person performSelector:@selector(drive)];
```



输出：

```
Driver 正在开车
```

这里最关键的是：

```
return self.driver;
```



它告诉 Runtime：这个消息可以交给 `Driver` 对象处理。

因此，`drive` 最终由 `Driver` 的方法实现执行，而不是 `Person` 自己实现了 `drive`。

有两个注意事项：

+ 转发目标必须能够处理这个选择子，否则问题仍然无法解决。
+ 不要把消息转发回自己，否则可能形成循环。未处理的消息应按正常转发流程继续处理。

快速转发适合把消息简单地委托给另一个对象，它不需要我们手动创建 `NSInvocation`。

### 四、第三阶段：完整消息转发 `forwardInvocation:`

如果快速转发也没有解决问题，Runtime 还可以进入完整消息转发机制。

它涉及两个重要方法：

```
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector;

- (void)forwardInvocation:(NSInvocation *)anInvocation;
```



它们的职责不同。

+ `methodSignatureForSelector:`：提供方法签名，让 Runtime 知道这个调用的参数、返回值等类型信息。
+ `forwardInvocation:`：接收封装了此次调用的 `NSInvocation`，可以检查调用并将它转发给其他对象。

一个简化示例：

```
@interface Person : NSObject
@property (nonatomic, strong) Driver *driver;
@end

@implementation Person

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    if (aSelector == @selector(drive)) {
        return [self.driver methodSignatureForSelector:aSelector];
    }

    return [super methodSignatureForSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    if ([self.driver respondsToSelector:anInvocation.selector]) {
        [anInvocation invokeWithTarget:self.driver];
    } else {
        [super forwardInvocation:anInvocation];
    }
}

@end
```



这里把 `Driver` 已有的 `drive` 方法签名交给 Runtime，再把实际调用转发给 `Driver`。

完整消息转发比快速转发更灵活，因为它可以处理 `NSInvocation`，例如检查参数、选择不同的转发目标，或在适当情况下调整调用过程。

不过，这段代码假定 `Driver` 已经实现了 `drive`，并且 `Person` 的其他初始化代码已正确设置 `driver`。

### 五、三种机制的区别

| 机制         | 核心方法                                            | 作用                               |
| ------------ | --------------------------------------------------- | ---------------------------------- |
| 动态方法解析 | `resolveInstanceMethod:`                            | 尝试动态添加方法实现               |
| 快速消息转发 | `forwardingTargetForSelector:`                      | 把消息交给另一个对象               |
| 完整消息转发 | `methodSignatureForSelector:`、`forwardInvocation:` | 通过 `NSInvocation` 处理或转发调用 |

如果这些机制最终仍无法处理消息，Runtime 通常会调用 `doesNotRecognizeSelector:`，并抛出异常。

## 六、你现在应该建立的理解

把它和之前学习的方法查找联系起来：

1. Runtime 先尝试正常查找方法，包括缓存及类的继承链。
2. 如果找不到实例方法，可以进入动态方法解析阶段。
3. 如果解析没有解决问题，可以尝试快速消息转发。
4. 快速转发没有解决问题时，还可以尝试完整消息转发。
5. 如果最后仍没有有效处理方式，就会产生无法识别选择子的异常。

最重要的区别是：动态方法解析尝试让方法变得可用；消息转发则是在原本的查找无法解决调用时，尝试让其他对象或转发逻辑处理这个调用。

对于普通 iOS 开发，你不需要经常手动使用这些机制，但理解它们有助于理解 Runtime、代理机制以及一些动态行为。

下一节可以继续学习 Runtime 的方法交换 `method_exchangeImplementations`，这也是理解分类（Category）和方法替换机制时很重要的一部分。

继续

继续学习 Objective-C Runtime。上一节我们讲了动态方法解析和消息转发，这一节学习 方法交换 `method_exchangeImplementations`。

它是 Runtime 中很实用的机制，尤其是理解 Category、方法替换和一些系统行为扩展时。

# 第七课：Runtime 方法交换

## 一、先理解：什么是方法交换？

假设有一个 `Person` 类，有两个方法：

```
@implementation Person

- (void)eat {
    NSLog(@"吃饭");
}

- (void)sleep {
    NSLog(@"睡觉");
}

@end
```



正常调用：

```
Person *person = [[Person alloc] init];

[person eat];
[person sleep];
```



输出：

```
吃饭 睡觉
```

现在，如果我们希望调用 `eat` 时执行原来的 `sleep` 实现，而调用 `sleep` 时执行原来的 `eat` 实现，应该怎么办？

一种思路是修改方法与实现之间的对应关系。

这就是方法交换的核心思想。

在 Objective-C Runtime 中，方法通常可以理解为由以下两部分关联起来：

+ `SEL`：方法选择子，用于标识方法名称。
+ `IMP`：方法实现对应的函数指针。

例如：

| 方法选择子 | 原本对应的实现 |
| ---------- | -------------- |
| `eat`      | `eat` 的实现   |
| `sleep`    | `sleep` 的实现 |

交换之后：

| 方法选择子 | 交换后对应的实现    |
| ---------- | ------------------- |
| `eat`      | 原本 `sleep` 的实现 |
| `sleep`    | 原本 `eat` 的实现   |

注意，交换的是方法选择子与实现之间的关联，不是把两个方法的源代码互换，也不是交换对象本身。

## 二、`method_exchangeImplementations` 怎么使用？

先引入 Runtime 头文件：

```
#import <objc/runtime.h>
```



然后获取两个方法对应的 `Method`：

```
Method eatMethod =
    class_getInstanceMethod([Person class], @selector(eat));

Method sleepMethod =
    class_getInstanceMethod([Person class], @selector(sleep));
```



这里有两个重要函数：

+ `class_getInstanceMethod`：获取指定类的实例方法。
+ `@selector(eat)`：获取 `eat` 方法对应的 `SEL`。

接下来交换实现：

```
method_exchangeImplementations(eatMethod, sleepMethod);
```



交换后再执行：

```
Person *person = [[Person alloc] init];

[person eat];
[person sleep];
```



在这个简单例子中，输出会变成：

```
睡觉 吃饭
```

因为 `eat` 现在关联着原本 `sleep` 的实现，反过来也一样。

## 三、为什么方法交换经常和 Category 一起出现？

这是方法交换最值得理解的应用场景之一。

假设我们有一个 `Person` 类，原本的 `eat` 方法如下：

```
@implementation Person

- (void)eat {
    NSLog(@"原始 eat 方法");
}

@end
```



现在希望调用 `eat` 时，既执行额外逻辑，又保留原始行为。

一种常见做法是通过 Category 添加一个替代方法，并在适当时机交换两个方法的实现。

例如：

```
#import "Person.h"
#import <objc/runtime.h>

@implementation Person (Logging)

+ (void)load {
    Method originalMethod =
        class_getInstanceMethod(self, @selector(eat));

    Method swizzledMethod =
        class_getInstanceMethod(self, @selector(log_eat));

    method_exchangeImplementations(
        originalMethod,
        swizzledMethod
    );
}

- (void)log_eat {
    NSLog(@"开始执行 eat");

    [self log_eat];

    NSLog(@"结束执行 eat");
}

@end
```



这里有个看起来很奇怪的地方：

```
[self log_eat];
```



为什么在 `log_eat` 方法里面，又调用了 `log_eat`？这看起来像无限递归。

关键就在于：方法交换改变了 `log_eat` 对应的实现。

交换前：

| 选择子    | 对应实现                |
| --------- | ----------------------- |
| `eat`     | 原始 `eat`              |
| `log_eat` | Category 中的 `log_eat` |

交换后：

| 选择子    | 对应实现                |
| --------- | ----------------------- |
| `eat`     | Category 中的 `log_eat` |
| `log_eat` | 原始 `eat`              |

因此，当外部执行：

```
[person eat];
```



实际执行过程是：

1. 通过 `eat` 进入 Category 中的 `log_eat` 实现。
2. 输出“开始执行 eat”。
3. 执行 `[self log_eat]`。
4. 由于 `log_eat` 现在关联的是原始 `eat` 实现，因此执行原始业务逻辑。
5. 输出“结束执行 eat”。

最终输出：

```
开始执行 eat 原始 eat 方法 结束执行 eat
```

这就是方法交换的巧妙之处：通过交换实现，让原本调用自己的代码转而执行另一个实现。

## 四、为什么这里使用 `+load`？

```
+ (void)load
```



`load` 是 Objective-C 提供的类方法生命周期钩子。对于正常加载的类和 Category，Runtime 会在程序启动时的类加载阶段调用它。

在这个例子中，使用 `+load` 是为了让交换操作尽早执行，使后续调用 `eat` 时能使用交换后的实现。

但要注意：

+ `+load` 的调用时机与普通的 `viewDidLoad` 不同，它发生在类加载阶段。
+ 方法交换应确保只执行一次，避免重复交换导致实现关系再次颠倒。
+ 如果多个 Category 都交换同一个方法，交换顺序和彼此的兼容性可能会变得复杂。

因此，不能把方法交换当成随时可以随意调用的普通工具。

## 五、实际开发中需要注意什么？

方法交换能力很强，但也有风险。

1. 避免重复交换

每交换一次，两个方法的实现关联就会再次颠倒。重复执行可能导致最终行为与预期相反。

2. 注意继承关系

`class_getInstanceMethod` 可能返回继承自父类的方法。如果直接交换继承而来的方法，需要特别谨慎，否则可能意外影响父类或其他子类的行为。更稳妥的实现通常需要先判断方法是否由当前类自己实现，并在必要时使用 `class_addMethod`、`class_replaceMethod` 处理。

3. 不要忽略方法签名

被交换的两个方法应当具有兼容的调用约定，包括参数和返回值类型。交换实现并不会自动改变方法的参数类型，也不会让不兼容的函数变得兼容。

4. 谨慎修改系统类

例如，直接交换 `UIViewController` 的生命周期方法可能影响整个应用中的多个控制器。只有明确理解影响范围时才应该考虑这样做。

## 六、把这一课和前面的知识联系起来

到目前为止，你已经接触到几种不同的 Runtime 能力：

| 知识点                           | 解决的问题                       |
| -------------------------------- | -------------------------------- |
| `objc_msgSend`                   | 如何发送消息并触发方法查找       |
| `isa`、类与元类                  | Runtime 如何关联对象与类信息     |
| 方法查找与缓存                   | 如何找到并复用方法实现           |
| 动态方法解析                     | 如何在运行时补充方法实现         |
| 消息转发                         | 找不到原始实现时如何尝试处理消息 |
| `method_exchangeImplementations` | 如何交换两个方法对应的实现       |

接下来建议学习 Category 的底层机制，重点理解 Category 的方法如何参与类的方法列表、为什么 Category 可以添加方法却不能直接添加实例变量，以及多个 Category 出现同名方法时需要注意什么。这些知识会帮助你把 Runtime 的方法机制与实际的 Objective-C 工程联系起来。

我学到这里已经好多地方看不懂了

你现在出现这种感觉是正常的。我觉得我们应该先调整一下学习方式，而不是继续往后讲新的 Runtime 知识点。

你从方法查找一路学到了元类、方法缓存、动态方法解析、消息转发、方法交换。这些内容涉及 Objective-C 的底层运行机制，概念之间又有联系。如果前面的基础还没有完全消化，后面的内容就很容易变成“每个词都认识，但连起来就看不懂”。

我建议你暂时停止学习新知识，回头把已经学过的内容串起来。不是从头全部重学，而是先找到你真正卡住的地方。

## 一、先把 Runtime 简化成一条主线

你先不必记住所有 API，只要理解下面这张图。

## 发送消息

```
[person eat]
```

希望 person 执行 eat 方法



### 寻找方法

`person` → `Person` 类 → 父类

找到 eat 对应的实现



### 执行实现

```
IMP
```

可以把它先理解为方法实现的入口

如果正常查找失败，才需要进一步理解动态方法解析和消息转发。方法交换则是另一种修改方法实现关联的机制。

你可以先把 Runtime 理解成：Objective-C 在程序运行时，如何找到、决定并执行一个方法的一套机制。

这句话先理解透，比背下十几个 API 更重要。

## 二、我们接下来怎么学？

我建议暂时退回最核心的基础，用最简单的代码逐步解释，不再一开始就引入大量底层术语。

例如从这段代码重新梳理：

```
@interface Person : NSObject
- (void)eat;
@end

@implementation Person

- (void)eat {
    NSLog(@"吃饭");
}

@end

Person *person = [[Person alloc] init];
[person eat];
```



我们只需要依次弄清楚四件事：

1. `person` 到底是什么，和 `Person` 类有什么关系？
2. `[person eat]` 为什么能够调用 `eat`？
3. Runtime 怎么知道应该执行哪段代码？
4. 如果 `Person` 没有 `eat`，又会发生什么？

等这四件事理解清楚，再回到方法缓存、动态方法解析和消息转发，你会更容易理解它们分别解决什么问题。

## 三、我想先确认一下你具体卡在哪里

不用担心回答得不专业，也不需要组织复杂的语言。你可以直接选择最接近自己情况的一项。

A. 很多术语都不理解，比如 `SEL`、`IMP`、`isa`、元类。

B. 单独解释时好像懂了，但不知道这些知识点之间有什么联系。

C. 看不懂代码，特别是 Runtime 的函数、方法交换和消息转发。

D. 前面的方法查找、类与元类就没真正理解，后面基本听不懂。

我们不用赶进度，也不用急着学完 Runtime。先真正理解，再继续深入。

我学习 Objective-C Runtime 时，单独听每个知识点似乎能懂，但不知道它们之间的联系。请帮我重新梳理主线。

我们这次先不学新的 Runtime API，而是把你之前学过的内容重新组织起来。

我认为你目前最需要建立的，不是更多知识点，而是一个整体认识：Runtime 为什么存在？每个知识点解决什么问题？它们之间是什么关系？

# 一、先抓住 Objective-C Runtime 的核心

先看一段你已经很熟悉的 Objective-C 代码：

```
Person *person = [[Person alloc] init];

[person eat];
```



这段代码表面上很简单，但从 Runtime 的角度看，涉及三个问题：

1. `person` 是什么对象？它属于哪个类？
2. `[person eat]` 是如何找到 `eat` 方法的？
3. 找到之后，究竟执行哪段代码？

你之前学过的大部分 Runtime 知识，都可以放进这三个问题里。



问题一：对象与类

相关知识：对象、Class、isa、继承、元类

解决的问题：对象属于哪个类？Runtime 从哪里开始查找？





问题二：方法查找

相关知识：SEL、方法列表、父类继承链、方法缓存

解决的问题：Runtime 如何找到对应的方法实现？





问题三：方法执行与动态处理

相关知识：IMP、动态方法解析、消息转发、方法交换

解决的问题：找到实现后如何执行？找不到时怎么办？如何动态改变行为？

先记住这个结构。后面我们把每部分拆开理解。

# 二、第一部分：对象、类、isa 和元类

这是整个 Runtime 的基础。

假设我们定义了一个类：

```
@interface Person : NSObject
- (void)eat;
@end

@implementation Person

- (void)eat {
    NSLog(@"吃饭");
}

@end
```



然后创建对象：

```
Person *person = [[Person alloc] init];
```



这里存在两个不同的东西：

+ `Person`：类对象，描述 `Person` 这一类对象的相关信息。
+ `person`：一个 `Person` 实例对象。

可以这样理解：

person（实例对象）

保存实例相关的数据，并通过 isa 关联所属的类



Person（类对象）

包含方法元数据、父类关系等信息



Person 的元类

保存与类方法有关的方法信息

上图是帮助理解的简化关系图，不是完整的 Runtime 对象结构图。

你之前容易混淆的地方是：元类不是实例方法查找完父类之后才去查找的地方。

当你调用：

```
[person eat];
```



这是向实例对象发送消息，主要沿普通类的继承链查找。

当你调用：

```
[Person someClassMethod];
```



这是向类对象发送消息，类方法的查找涉及元类及其继承关系。

所以，`isa` 和元类解决的是 Runtime 中“对象、类、类方法之间如何关联”的问题，而不是直接负责执行方法。

# 三、第二部分：SEL、IMP、方法查找和方法缓存

现在你已经知道 `person` 属于 `Person` 类。

接下来执行：

```
[person eat];
```



Runtime 需要解决一个新问题：它怎么知道 `eat` 对应哪段代码？

这里出现了两个关键概念。

| 概念  | 你现在可以怎么理解                             |
| ----- | ---------------------------------------------- |
| `SEL` | 方法的标识，可以理解为方法名称对应的选择子     |
| `IMP` | 方法实现的函数指针，可以先理解为执行代码的入口 |

例如：

```
SEL selector = @selector(eat);
```



这相当于取得 `eat` 对应的选择子。

而一个方法在 Runtime 中还关联着实际的实现，也就是 `IMP`。

可以先用这个简化模型理解：

发送消息

```
[person eat]
```



识别方法

```
SEL = eat
```



查找对应实现

```
SEL → IMP
```



执行方法实现

`IMP` 对应的函数被调用

这不是说 Runtime 内部只有一个简单的 `SEL → IMP` 字典，而是先用这种方式理解方法查找的核心。

## 那方法查找和方法缓存又是什么关系？

假设：

```
[person eat];
[person eat];
[person eat];
```



每次都重新遍历整个类的继承链，会有额外开销。

因此，Runtime 使用方法缓存来加速查找。

概念上可以理解为：

1. 先检查相关类的方法缓存。
2. 如果命中，就可以快速获得实现。
3. 如果没有命中，就继续查找方法元数据和父类继承链。
4. 找到实现后，在适当情况下缓存查找结果，便于后续调用。

所以这三个知识点的关系是：

+ `SEL`：要找哪个方法。
+ 方法查找：去哪里找这个方法的实现。
+ 方法缓存：如何加速重复查找。
+ `IMP`：最终找到的实现入口。

它们不是四个互相独立的知识点，而是同一条方法调用链上的不同环节。

# 四、第三部分：如果找不到方法怎么办？

现在假设 `Person` 只有 `eat`，没有 `run`：

```
Person *person = [[Person alloc] init];

[person run];
```



正常方法查找无法找到 `run` 的实现。

这时候，之前学习的动态方法解析和消息转发就出现了。

它们不是普通方法查找的同义词，而是正常查找失败后，Runtime 提供的进一步处理机制。

发送消息：`[person run]`



正常查找失败

缓存、当前类及父类中都没有可用实现



第一步：动态方法解析

`resolveInstanceMethod:` 可以尝试动态添加 `run` 的实现。



第二步：快速消息转发

`forwardingTargetForSelector:` 可以把消息交给其他对象。



第三步：完整消息转发

通过方法签名和 `NSInvocation` 尝试处理或转发调用。



最终仍无法处理

通常抛出无法识别选择子的异常

这张图最重要的不是让你背下顺序，而是让你明白：

动态方法解析和消息转发，都是在正常方法查找无法解决调用时，尝试处理消息的机制。

它们的目的不同：

+ 动态方法解析：尝试补充方法实现。
+ 快速消息转发：把消息交给另一个对象。
+ 完整消息转发：通过 `NSInvocation` 等机制灵活地处理或转发调用。

如果你暂时不明白这些 API 的具体代码，也没关系。先知道它们为什么存在。

# 五、第四部分：方法交换放在哪里？

你之前学过：

```
method_exchangeImplementations(method1, method2);
```



它和前面的动态方法解析、消息转发不是同一类机制。

方法交换解决的是另一个问题：

两个方法已经有实现了，我希望改变它们的选择子与实现之间的对应关系。

例如，原来：

| 方法选择子 | 对应实现       |
| ---------- | -------------- |
| `eat`      | `eat` 的实现   |
| `sleep`    | `sleep` 的实现 |

交换后：

| 方法选择子 | 对应实现            |
| ---------- | ------------------- |
| `eat`      | 原本 `sleep` 的实现 |
| `sleep`    | 原本 `eat` 的实现   |

因此：

+ 方法查找：找到方法的实现。
+ 动态方法解析：尝试动态增加实现。
+ 消息转发：尝试将消息交给其他处理逻辑。
+ 方法交换：改变已有方法与实现的关联。

它们都涉及 Runtime，但解决的问题并不相同。

# 六、把你学过的 Runtime 知识放回整张地图

## Objective-C Runtime 知识地图

### 第一层：对象模型

对象与类

isa

Class

元类

继承

理解对象、类与方法元数据之间的关系。

### 第二层：消息发送与方法查找

objc_msgSend

SEL

IMP

方法列表

方法缓存

理解消息如何找到并执行对应的方法。

### 第三层：动态行为

动态方法解析

快速转发

完整转发

方法交换

理解运行时如何补充、转发或改变方法行为。

### 第四层：常见应用与深入机制

Category

关联对象

动态属性

运行时反射

把基础机制应用到实际 iOS 开发。

你之前的学习顺序并不是完全错误，只是我们在你还没有把第二层串起来时，就继续讲了第三层的一些内容。因此，现在先整理主线更合适。

## 七、接下来我建议这样安排

不用把已经学过的内容全部推倒重来。我们按下面的顺序重新梳理：

1. 对象、类与 `isa`：明确实例对象和类对象的关系。
2. `SEL`、`IMP` 与方法查找：弄懂 `[person eat]` 到底如何找到实现。
3. 父类、元类与方法缓存：把两条查找路径及缓存放在一起理解。
4. 动态方法解析与消息转发：等前面的调用过程清楚后，再解释异常情况。
5. 方法交换与 Category：最后再看如何动态修改类的行为。

每一步只解决一个核心问题，用同一组 `Person`、`Animal`、`Dog` 示例贯穿，而不是每次都换一套代码和术语。

我建议下一步就从第二层开始，重新完整地梳理一次 `[person eat]` 的调用过程。 这一步是整条 Runtime 主线的枢纽。只要真正弄清楚消息、方法查找、`SEL`、`IMP` 和缓存之间的关系，后面的内容就更容易找到位置。















我们继续学习 Objective-C Runtime。上一节讲了动态方法解析，这一节进入它后面的机制：消息转发（Message Forwarding）。

这部分的核心问题是：

当 Runtime 找不到某个方法，而且类也没有通过动态方法解析补充实现时，为什么对象仍然有机会处理这条消息？

# 一、先理解消息转发要解决什么问题

假设有下面的代码：

```
Person *person = [[Person alloc] init];
[person dance];
```

如果 `Person` 没有实现 `dance`，它的父类也没有提供对应实现，那么 Runtime 就无法通过正常方法查找找到 `dance` 的 `IMP`。

动态方法解析也没有解决问题时，Runtime 还会尝试消息转发。

你可以把目前学过的过程串起来：

发送消息

```
[person dance]
```

正常方法查找

Cache → 方法列表 → 父类

动态方法解析

尝试动态添加方法实现

消息转发

尝试寻找其他处理方式

如果仍无法处理

`unrecognized selector` 异常

这里有个重要区别：

+ 动态方法解析： 尝试为这个类补充方法实现。
+ 消息转发： 即使原对象没有这个方法，也可以尝试把消息交给其他对象，或者通过其他方式处理。

# 二、消息转发分成两个阶段

Objective-C 的消息转发机制中，有两个最重要的阶段。

## 第一阶段：快速转发

对应的方法是：

```
- (id)forwardingTargetForSelector:(SEL)aSelector;
```

它的意思是：

当前对象无法正常处理这个选择子时，能不能指定另一个对象来接收这条消息？

例如，假设 `Person` 不会跳舞，但 `Dancer` 会跳舞。

```
@interface Dancer : NSObject
- (void)dance;
@end

@implementation Dancer

- (void)dance {
    NSLog(@"Dancer 正在跳舞");
}

@end
```

`Person` 可以这样处理：

```
@implementation Person

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if (aSelector == @selector(dance)) {
        return [[Dancer alloc] init];
    }

    return [super forwardingTargetForSelector:aSelector];
}

@end
```

当调用：

```
Person *person = [[Person alloc] init];
[person dance];
```

如果前面的动态方法解析没有解决问题，消息转发进入快速转发阶段，那么 `Person` 可以返回一个 `Dancer` 对象。

Runtime 接下来会尝试让 `Dancer` 处理 `dance` 消息。

最终打印：

```
Dancer 正在跳舞
```

### 快速转发的特点

1. 不要求把 `dance` 的实现添加到 `Person` 类中。
2. 返回的是一个能够接收该消息的对象。
3. 转发的是原消息，而不是让 `Person` 自己调用一个同名方法。
4. 返回 `nil`，或者返回的对象仍然无法处理消息时，通常会进入后续的完整消息转发流程。

本质：快速转发是在寻找另一个消息接收者。

实际开发中，返回的对象必须有合适的生命周期管理。上面的示例使用临时创建的对象，只用于说明机制；实际设计时通常应考虑复用或持有转发目标。

# 三、第二阶段：完整消息转发

如果快速转发没有解决问题，Runtime 还会尝试完整消息转发。

这一阶段涉及两个方法：

```
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector;

- (void)forwardInvocation:(NSInvocation *)anInvocation;
```

它们经常一起出现，但职责完全不同。

## 1. `methodSignatureForSelector:`

这个方法负责提供方法签名。

为什么需要方法签名？

因为 Runtime 不仅要知道方法叫什么，还需要知道方法的参数和返回值类型，才能正确组织这次调用。

例如：

```
- (void)dance;
```

与：

```
- (NSInteger)add:(NSInteger)a to:(NSInteger)b;
```

显然不是同一种调用。第二个方法需要两个参数，并且有返回值。

`methodSignatureForSelector:` 提供的 `NSMethodSignature`，就是描述这些调用信息的对象。

## 2. `forwardInvocation:`

这个方法接收一个 `NSInvocation` 对象。

`NSInvocation` 可以把一次方法调用封装起来，包含选择子、参数以及与调用相关的信息。这样就可以在运行时检查、修改或转交这次调用。

简单对比：

| 方法                          | 主要职责                     |
| ----------------------------- | ---------------------------- |
| `methodSignatureForSelector:` | 提供方法签名，说明调用的结构 |
| `forwardInvocation:`          | 决定如何处理封装好的调用     |

完整转发的灵活性比快速转发更高，但实现也更复杂。

# 四、用一个例子把完整转发串起来

假设 `Person` 没有 `dance` 方法，我们希望它把这次调用转交给一个 `Dancer` 实例。

```
@interface Person : NSObject
@property (nonatomic, strong) Dancer *dancer;
@end

@implementation Person

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

@end
```

这里假设 `self.dancer` 已经被正确创建和赋值，而且 `Dancer` 实现了 `dance`。

调用：

```
Person *person = [[Person alloc] init];
person.dancer = [[Dancer alloc] init];

[person dance];
```

完整转发的大致过程是：

1. Runtime 无法正常找到 `Person` 的 `dance` 实现。
2. 动态方法解析和快速转发都没有解决这次调用。
3. Runtime 向 `Person` 请求 `dance` 的方法签名。
4. `Person` 返回 `Dancer` 对应的方法签名。
5. Runtime 将这次调用封装为 `NSInvocation`，交给 `forwardInvocation:`。
6. `Person` 通过 `invokeWithTarget:` 把调用交给 `Dancer`。

需要注意：完整转发的实现必须为需要处理的选择子提供有效的方法签名。否则，Runtime 无法正确构造这次调用，通常会导致无法识别选择子的异常。示例中的 `respondsToSelector:` 检查也不是完整转发的强制要求，而是用来避免转交给不支持该选择子的目标。

# 五、快速转发和完整转发怎么选？

### 快速转发

```
forwardingTargetForSelector:
```

适用于：你只需要把消息交给另一个对象处理，不需要检查或修改调用参数。

### 完整转发

```
methodSignatureForSelector:` + `forwardInvocation:
```

适用于：你需要检查、改造、记录或动态转交这次调用，或者需要更灵活的消息分发策略。

这两种方式都不意味着 `Person` 原本就实现了 `dance`。它们是在消息无法通过正常查找解决后，为这次消息提供替代处理方式。

另外，`respondsToSelector:` 默认主要反映对象是否能够识别相应选择子；如果你使用消息转发模拟额外方法，可能还需要根据自己的设计覆盖它，避免外部调用者得到与实际行为不一致的结果。

# 六、把 Runtime 的这条主线重新连起来

目前你已经学过的机制可以分为三层：

1. 正常派发： `isa`、`superclass`、Cache、方法列表和 `IMP`，负责寻找并执行已有实现。
2. 动态方法解析： `resolveInstanceMethod:` 和 `resolveClassMethod:`，允许类动态补充方法。
3. 消息转发： `forwardingTargetForSelector:`、`methodSignatureForSelector:` 和 `forwardInvocation:`，允许消息通过其他方式被处理。

如果这些机制都无法解决调用，最终通常就会出现 `unrecognized selector sent to instance` 之类的异常。

下一步，我们可以继续学习 Category（分类）与 Runtime 的关系：为什么分类可以给类增加方法，却不能像普通类那样直接增加实例变量，以及多个分类实现同名方法时会涉及哪些 Runtime 行为。

继续讲解





我们继续学习 Objective-C Runtime。前面你已经学完了消息发送、动态方法解析和消息转发，接下来学习 Category（分类）与 Runtime 的关系。

这一节重点理解三个问题：

1. Category 为什么能给已有类增加方法？
2. Category 为什么不能直接增加实例变量？
3. 多个 Category 实现同名方法时，Runtime 会发生什么？

# 一、Category 是什么？

在 Objective-C 中，Category 可以让我们在不修改原类源代码的情况下，为已有类增加方法。

例如，原本有一个 `Person` 类：

```
@interface Person : NSObject

- (void)eat;

@end
```

现在想为 `Person` 增加一个 `run` 方法。

不一定要修改 `Person.h` 和 `Person.m`，可以创建一个分类。

```
// Person+Run.h

@interface Person (Run)

- (void)run;

@end
// Person+Run.m

@implementation Person (Run)

- (void)run {
    NSLog(@"Person 正在跑步");
}

@end
```

使用时：

```
Person *person = [[Person alloc] init];
[person run];
```

这样就可以调用 `run` 方法。

注意，`(Run)` 是分类的名称，不是新建了一个叫 `PersonRun` 的类。分类中的方法最终是为 `Person` 类增加的。

## Category 与继承有什么区别？

| 对比                   | Category   | 继承                       |
| ---------------------- | ---------- | -------------------------- |
| 是否创建新类           | 不创建     | 创建子类                   |
| 方法属于谁             | 扩展已有类 | 通常由子类实现或继承       |
| 是否改变继承关系       | 不改变     | 建立父子类关系             |
| 是否能直接增加实例变量 | 不能       | 子类可以定义自己的实例变量 |

理解 Category 的关键是：它扩展的是已有类的能力，而不是创建一个新的类层级。

# 二、Category 为什么能增加方法？

这是 Runtime 相关知识的核心。

先回忆你之前学过的内容：

+ 类对象维护与方法查找有关的信息。
+ 方法包含选择子 `SEL` 和实现入口 `IMP` 等信息。
+ `objc_msgSend` 会根据接收者的类及继承关系寻找方法。

那么，Category 增加方法后，为什么下面的代码能够执行？

```
Person *person = [[Person alloc] init];
[person run];
```

原因是：Objective-C Runtime 会在运行时处理分类携带的方法等元数据，使分类中的方法能够参与所属类的方法查找。

可以把它理解为以下过程：

编译后的类信息

`Person` 原本的方法

分类元数据

`Person (Run)` 中的方法

Runtime 处理分类信息

`run` 可以参与 `Person` 的方法查找

这里有一个需要准确理解的细节：分类的方法并不一定是在编译时就直接写进原类最初的那份方法列表。分类有自己的元数据，Runtime 会处理这些信息；在现代 Apple Runtime 的实现中，还涉及分类方法列表的合并与方法列表组织等内部机制。

因此，你可以先建立这个认知：

Category 增加方法，本质上是通过 Runtime 的类元数据和方法派发机制，让这些方法能够被找到和调用。

# 三、为什么 Category 不能直接增加实例变量？

接下来理解一个经常被问到的问题。

假设你想给 `Person` 增加一个属性：

```
@interface Person (Info)

@property (nonatomic, copy) NSString *nickname;

@end
```

这段代码看起来很正常，但它有一个关键问题：

`@property` 声明本身，不等于自动生成了实例变量、`getter` 和 `setter` 的完整实现。

对于普通类，编译器通常会根据属性声明和实现，为属性生成相应的访问方法及存储机制。

但对于 Category，单纯声明：

```
@property (nonatomic, copy) NSString *nickname;
```

并不会自动为 `nickname` 创建实例存储空间，也不会自动生成可用的访问方法实现。

如果直接这样使用：

```
person.nickname = @"小明";
NSLog(@"%@", person.nickname);
```

而没有另外提供 `setter` 和 `getter` 的实现，通常会出现找不到方法实现的问题。

## 为什么不能像普通类一样增加实例变量？

一个对象创建后，其实例存储布局需要与它所属的类相匹配。

例如，假设 `Person` 的实例中已经有：

+ `name`
+ `age`

如果分类可以随意增加新的实例变量，就会涉及如何改变已经确定的对象实例布局、如何为新变量安排存储空间等问题。

普通类的实例布局由类的定义及其继承关系决定。Category 的设计并不是重新定义一个类，也不是创建一个新的实例布局，所以它不能像普通类或子类那样直接增加实例变量。

这里要区分两个概念：

+ 增加属性声明： 只是在接口中声明一个属性。
+ 增加属性存储： 必须有实际的存储机制和正确的访问方法实现。

二者并不是一回事。

# 四、Associated Objects：通过 Runtime 为对象关联数据

既然 Category 不能直接增加实例变量，那么我们要如何让分类拥有类似属性的能力？

一个常见方案是 Associated Objects（关联对象）。

它允许我们通过 Objective-C Runtime，把某个值与某个对象关联起来。

例如：

```
#import <objc/runtime.h>

static char nicknameKey;

@implementation Person (Info)

- (void)setNickname:(NSString *)nickname {
    objc_setAssociatedObject(self,
                             &nicknameKey,
                             nickname,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (NSString *)nickname {
    return objc_getAssociatedObject(self, &nicknameKey);
}

@end
```

对应的属性声明仍然需要存在于分类的头文件中：

```
@interface Person (Info)

@property (nonatomic, copy) NSString *nickname;

@end
```

这样就可以使用：

```
Person *person = [[Person alloc] init];

person.nickname = @"小明";

NSLog(@"%@", person.nickname);
```

## 关联对象是怎样工作的？

### 1. `objc_setAssociatedObject`

建立关联

将指定的值与目标对象、关联键和内存管理策略关联起来。

### 2. `objc_getAssociatedObject`

读取关联

根据目标对象和关联键，获取之前关联的值。

### 3. `nicknameKey`

标识这份关联数据

用于区分不同的关联数据。这里通过静态变量的地址作为键。

这里的 `OBJC_ASSOCIATION_COPY_NONATOMIC` 表示关联时采用类似 `copy` 属性的复制语义，并且不提供原子性保证。

关联对象并不是给 `Person` 的实例布局真正添加了一个 `nickname` 实例变量。它是 Runtime 提供的另一种关联存储机制。

还需要注意，关联对象通常会随目标对象的生命周期进行清理，但如果关联值又强引用目标对象，就可能形成循环引用。

# 五、多个 Category 实现同名方法，会发生什么？

这是 Category 与 Runtime 关系中另一个非常重要的知识点。

假设原类实现了：

```
@implementation Person

- (void)eat {
    NSLog(@"Person 原本的 eat");
}

@end
```

现在有两个分类。

分类 A：

```
@implementation Person (A)

- (void)eat {
    NSLog(@"Category A 的 eat");
}

@end
```

分类 B：

```
@implementation Person (B)

- (void)eat {
    NSLog(@"Category B 的 eat");
}

@end
```

调用：

```
Person *person = [[Person alloc] init];
[person eat];
```

到底会执行哪一个？

不能简单地认为“分类一定覆盖原类”，也不能保证某个特定分类永远优先。

当多个分类为同一个类提供同名方法时，实际调用结果可能与分类的加载、方法列表的组织以及具体 Runtime 实现有关。

在常见的 Apple Runtime 行为中，分类方法会参与所属类的方法查找；多个分类存在同名方法时，后加入查找顺序的实现可能优先被找到。但具体顺序不应当作为可靠的业务逻辑依赖。

因此，不建议用多个分类中的同名方法来设计程序行为。

## 如果我确实想调用原来的实现呢？

这就引出了一个后续主题：Method Swizzling（方法交换）。

它通过 Runtime 提供的接口交换两个方法的实现入口，使方法派发到不同的实现上。

不过，方法交换和 Category 中同名方法的加载顺序不是同一件事。我们后续会单独讲解，避免把两者混在一起。

# 六、把今天的知识与前面的 Runtime 主线连接起来

你现在可以把 Category 放回之前学习的整体框架：

类与元数据

`isa`、`superclass`、方法列表和类对象描述类的结构与方法信息。

消息派发

`objc_msgSend` 根据接收者和选择子查找并执行实现。

Category

分类为已有类提供额外方法，并通过 Runtime 参与方法派发。

Associated Objects

利用 Runtime 为已有对象关联额外数据，而不是直接改变实例变量布局。

接下来最自然的学习顺序是 Method Swizzling（方法交换）。学完之后，再把 Category、关联对象、方法替换与消息派发整合起来，你对 Objective-C Runtime 的整体机制就会更完整。





我们继续学习 Objective-C Runtime。前面你已经学完了消息发送、动态方法解析和消息转发，接下来学习 Category（分类）与 Runtime 的关系。

这一节重点理解三个问题：

1. Category 为什么能给已有类增加方法？
2. Category 为什么不能直接增加实例变量？
3. 多个 Category 实现同名方法时，Runtime 会发生什么？

# 一、Category 是什么？

在 Objective-C 中，Category 可以让我们在不修改原类源代码的情况下，为已有类增加方法。

例如，原本有一个 `Person` 类：

```
@interface Person : NSObject

- (void)eat;

@end
```

现在想为 `Person` 增加一个 `run` 方法。

不一定要修改 `Person.h` 和 `Person.m`，可以创建一个分类。

```
// Person+Run.h

@interface Person (Run)

- (void)run;

@end
// Person+Run.m

@implementation Person (Run)

- (void)run {
    NSLog(@"Person 正在跑步");
}

@end
```

使用时：

```
Person *person = [[Person alloc] init];
[person run];
```

这样就可以调用 `run` 方法。

注意，`(Run)` 是分类的名称，不是新建了一个叫 `PersonRun` 的类。分类中的方法最终是为 `Person` 类增加的。

## Category 与继承有什么区别？

| 对比                   | Category   | 继承                       |
| ---------------------- | ---------- | -------------------------- |
| 是否创建新类           | 不创建     | 创建子类                   |
| 方法属于谁             | 扩展已有类 | 通常由子类实现或继承       |
| 是否改变继承关系       | 不改变     | 建立父子类关系             |
| 是否能直接增加实例变量 | 不能       | 子类可以定义自己的实例变量 |

理解 Category 的关键是：它扩展的是已有类的能力，而不是创建一个新的类层级。

# 二、Category 为什么能增加方法？

这是 Runtime 相关知识的核心。

先回忆你之前学过的内容：

+ 类对象维护与方法查找有关的信息。
+ 方法包含选择子 `SEL` 和实现入口 `IMP` 等信息。
+ `objc_msgSend` 会根据接收者的类及继承关系寻找方法。

那么，Category 增加方法后，为什么下面的代码能够执行？

```
Person *person = [[Person alloc] init];
[person run];
```

原因是：Objective-C Runtime 会在运行时处理分类携带的方法等元数据，使分类中的方法能够参与所属类的方法查找。

可以把它理解为以下过程：

编译后的类信息

`Person` 原本的方法

分类元数据

`Person (Run)` 中的方法

Runtime 处理分类信息

`run` 可以参与 `Person` 的方法查找

这里有一个需要准确理解的细节：分类的方法并不一定是在编译时就直接写进原类最初的那份方法列表。分类有自己的元数据，Runtime 会处理这些信息；在现代 Apple Runtime 的实现中，还涉及分类方法列表的合并与方法列表组织等内部机制。

因此，你可以先建立这个认知：

Category 增加方法，本质上是通过 Runtime 的类元数据和方法派发机制，让这些方法能够被找到和调用。

# 三、为什么 Category 不能直接增加实例变量？

接下来理解一个经常被问到的问题。

假设你想给 `Person` 增加一个属性：

```
@interface Person (Info)

@property (nonatomic, copy) NSString *nickname;

@end
```

这段代码看起来很正常，但它有一个关键问题：

`@property` 声明本身，不等于自动生成了实例变量、`getter` 和 `setter` 的完整实现。

对于普通类，编译器通常会根据属性声明和实现，为属性生成相应的访问方法及存储机制。

但对于 Category，单纯声明：

```
@property (nonatomic, copy) NSString *nickname;
```

并不会自动为 `nickname` 创建实例存储空间，也不会自动生成可用的访问方法实现。

如果直接这样使用：

```
person.nickname = @"小明";
NSLog(@"%@", person.nickname);
```

而没有另外提供 `setter` 和 `getter` 的实现，通常会出现找不到方法实现的问题。

## 为什么不能像普通类一样增加实例变量？

一个对象创建后，其实例存储布局需要与它所属的类相匹配。

例如，假设 `Person` 的实例中已经有：

+ `name`
+ `age`

如果分类可以随意增加新的实例变量，就会涉及如何改变已经确定的对象实例布局、如何为新变量安排存储空间等问题。

普通类的实例布局由类的定义及其继承关系决定。Category 的设计并不是重新定义一个类，也不是创建一个新的实例布局，所以它不能像普通类或子类那样直接增加实例变量。

这里要区分两个概念：

+ 增加属性声明： 只是在接口中声明一个属性。
+ 增加属性存储： 必须有实际的存储机制和正确的访问方法实现。

二者并不是一回事。

# 四、Associated Objects：通过 Runtime 为对象关联数据

既然 Category 不能直接增加实例变量，那么我们要如何让分类拥有类似属性的能力？

一个常见方案是 Associated Objects（关联对象）。

它允许我们通过 Objective-C Runtime，把某个值与某个对象关联起来。

例如：

```
#import <objc/runtime.h>

static char nicknameKey;

@implementation Person (Info)

- (void)setNickname:(NSString *)nickname {
    objc_setAssociatedObject(self,
                             &nicknameKey,
                             nickname,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (NSString *)nickname {
    return objc_getAssociatedObject(self, &nicknameKey);
}

@end
```

对应的属性声明仍然需要存在于分类的头文件中：

```
@interface Person (Info)

@property (nonatomic, copy) NSString *nickname;

@end
```

这样就可以使用：

```
Person *person = [[Person alloc] init];

person.nickname = @"小明";

NSLog(@"%@", person.nickname);
```

## 关联对象是怎样工作的？

### 1. `objc_setAssociatedObject`

建立关联

将指定的值与目标对象、关联键和内存管理策略关联起来。

### 2. `objc_getAssociatedObject`

读取关联

根据目标对象和关联键，获取之前关联的值。

### 3. `nicknameKey`

标识这份关联数据

用于区分不同的关联数据。这里通过静态变量的地址作为键。

这里的 `OBJC_ASSOCIATION_COPY_NONATOMIC` 表示关联时采用类似 `copy` 属性的复制语义，并且不提供原子性保证。

关联对象并不是给 `Person` 的实例布局真正添加了一个 `nickname` 实例变量。它是 Runtime 提供的另一种关联存储机制。

还需要注意，关联对象通常会随目标对象的生命周期进行清理，但如果关联值又强引用目标对象，就可能形成循环引用。

# 五、多个 Category 实现同名方法，会发生什么？

这是 Category 与 Runtime 关系中另一个非常重要的知识点。

假设原类实现了：

```
@implementation Person

- (void)eat {
    NSLog(@"Person 原本的 eat");
}

@end
```

现在有两个分类。

分类 A：

```
@implementation Person (A)

- (void)eat {
    NSLog(@"Category A 的 eat");
}

@end
```

分类 B：

```
@implementation Person (B)

- (void)eat {
    NSLog(@"Category B 的 eat");
}

@end
```

调用：

```
Person *person = [[Person alloc] init];
[person eat];
```

到底会执行哪一个？

不能简单地认为“分类一定覆盖原类”，也不能保证某个特定分类永远优先。

当多个分类为同一个类提供同名方法时，实际调用结果可能与分类的加载、方法列表的组织以及具体 Runtime 实现有关。

在常见的 Apple Runtime 行为中，分类方法会参与所属类的方法查找；多个分类存在同名方法时，后加入查找顺序的实现可能优先被找到。但具体顺序不应当作为可靠的业务逻辑依赖。

因此，不建议用多个分类中的同名方法来设计程序行为。

## 如果我确实想调用原来的实现呢？

这就引出了一个后续主题：Method Swizzling（方法交换）。

它通过 Runtime 提供的接口交换两个方法的实现入口，使方法派发到不同的实现上。

不过，方法交换和 Category 中同名方法的加载顺序不是同一件事。我们后续会单独讲解，避免把两者混在一起。

# 六、把今天的知识与前面的 Runtime 主线连接起来

你现在可以把 Category 放回之前学习的整体框架：

类与元数据

`isa`、`superclass`、方法列表和类对象描述类的结构与方法信息。

消息派发

`objc_msgSend` 根据接收者和选择子查找并执行实现。

Category

分类为已有类提供额外方法，并通过 Runtime 参与方法派发。

Associated Objects

利用 Runtime 为已有对象关联额外数据，而不是直接改变实例变量布局。

接下来最自然的学习顺序是 Method Swizzling（方法交换）。学完之后，再把 Category、关联对象、方法替换与消息派发整合起来，你对 Objective-C Runtime 的整体机制就会更完整。







我们继续学习 Objective-C Runtime。上一节讲了 Category 和关联对象，今天进入下一个知识点：Method Swizzling（方法交换）。

这部分会把你之前学过的 `Method`、`IMP`、Category 和 `objc_msgSend` 真正联系起来。

# 一、Method Swizzling 是什么？

Method Swizzling，通常翻译为“方法交换”，是指在运行时交换两个方法的实现。

先看一个普通的 `Person` 类：

```
@interface Person : NSObject
- (void)eat;
- (void)run;
@end

@implementation Person

- (void)eat {
    NSLog(@"正在吃饭");
}

- (void)run {
    NSLog(@"正在跑步");
}

@end
```

正常情况下：

```
Person *person = [[Person alloc] init];

[person eat]; // 正在吃饭
[person run]; // 正在跑步
```

假设我们希望调用 `eat` 时执行原来的 `run` 实现，而调用 `run` 时执行原来的 `eat` 实现。

方法交换就可以改变这两个方法与实现代码之间的对应关系。

## 先回忆三个概念

| 概念     | 含义                       |
| -------- | -------------------------- |
| `SEL`    | 方法选择子，标识一个方法   |
| `Method` | Runtime 中描述方法的元数据 |
| `IMP`    | 方法实现的入口             |

例如，原本可以把方法关系理解为：

```
eat
```

`eat` 的实现

```
run
```

`run` 的实现

交换之后，概念上变成：

```
eat
```

`run` 的实现

```
run
```

`eat` 的实现

这里最重要的理解是：

方法交换改变的是方法与实现之间的对应关系，而不是把两个方法的名字改掉。

# 二、Runtime 如何交换方法？

Objective-C Runtime 提供了相关 API：

```
#import <objc/runtime.h>

Method method1 = class_getInstanceMethod(Person.class,
                                         @selector(eat));

Method method2 = class_getInstanceMethod(Person.class,
                                         @selector(run));

method_exchangeImplementations(method1, method2);
```

核心 API 是：

```
method_exchangeImplementations(method1, method2);
```

它交换两个 `Method` 对应的实现。

交换后：

```
Person *person = [[Person alloc] init];

[person eat]; // 正在跑步
[person run]; // 正在吃饭
```

为什么调用结果变了？

因为消息发送时，`objc_msgSend` 仍然根据接收者和选择子查找方法，只不过方法对应的实现已经被交换了。

也就是说：

+ `[person eat]` 发送的选择子依然是 `eat`。
+ Runtime 找到的仍然是 `eat` 对应的方法入口。
+ 但该方法现在关联的是原本 `run` 的实现。

这就是方法交换和消息派发之间的联系。

# 三、为什么实际项目中经常结合 Category 使用？

实际开发中，我们通常不希望为了修改 `Person` 的行为而直接改动原类源码。

这时可以创建一个 Category，并在合适的时机执行方法交换。

例如，希望给 `Person` 的 `eat` 方法增加日志，同时保留原来的功能。

可以创建 `Person+Logging` 分类。

```
#import "Person.h"
#import <objc/runtime.h>

@implementation Person (Logging)

+ (void)load {
    Method originalMethod =
        class_getInstanceMethod(self, @selector(eat));

    Method customMethod =
        class_getInstanceMethod(self, @selector(logging_eat));

    if (originalMethod && customMethod) {
        method_exchangeImplementations(originalMethod,
                                       customMethod);
    }
}

- (void)logging_eat {
    NSLog(@"开始调用 eat");

    [self logging_eat];

    NSLog(@"结束调用 eat");
}

@end
```

这里有一个容易让初学者困惑的地方：

```
[self logging_eat];
```

看起来像是调用自己，为什么不会无限递归？

因为在方法交换之前：

+ `eat` 对应原来的吃饭实现。
+ `logging_eat` 对应分类中的日志实现。

交换之后：

+ `eat` 对应分类中的日志实现。
+ `logging_eat` 对应原来的吃饭实现。

因此，执行 `eat` 时会进入 `logging_eat`，然后执行 `[self logging_eat]` 时，会调用交换后挂在 `logging_eat` 这个选择子上的原始 `eat` 实现。

最终的输出大致是：

```
开始调用 eat
正在吃饭
结束调用 eat
```

这是一种常见的“包装原方法”的思路。

## `+load` 是什么？

上面的代码使用：

```
+ (void)load
```

`load` 是 Objective-C Runtime 的类和分类加载机制之一。类及其分类的 `load` 方法会在程序启动时的加载阶段被调用，通常早于应用进入正常运行流程。

它经常被用于演示方法交换，因为交换可以在普通业务代码开始调用相关方法之前完成。

不过，实际工程中要谨慎使用：

+ 避免多个分类重复交换同一个方法。
+ 避免不同组件之间产生难以预测的行为冲突。
+ 不要把方法交换当作普通业务逻辑的默认实现方式。

# 四、这里有一个重要陷阱：父类方法与 `class_getInstanceMethod`

前面的方法交换示例为了突出原理，假设两个方法都由 `Person` 自己实现。

但实际项目中，有时会遇到：

```
Method method = class_getInstanceMethod(Person.class,
                                        @selector(description));
```

`description` 可能是从父类继承来的。

`class_getInstanceMethod` 不仅可以获取类自己实现的实例方法，也可以沿继承关系找到继承的方法。

因此，拿到一个 `Method`，不代表这个方法一定属于当前类本身。

如果直接交换继承来的方法实现，可能影响到父类或其他子类的行为，具体取决于方法列表和 Runtime 的处理方式。

所以，在实际交换之前，需要弄清楚：

1. 方法是否由当前类直接实现。
2. 是否会影响父类和其他子类。
3. 交换是否可能与其他 Category 或第三方库冲突。

这些问题比记住一行交换 API 更重要。

# 五、方法交换与动态方法解析有什么区别？

你之前学习过动态方法解析，现在把它们放在一起比较。

| 对比                     | 动态方法解析                 | Method Swizzling                 |
| ------------------------ | ---------------------------- | -------------------------------- |
| 主要目的                 | 为无法找到的方法动态提供实现 | 交换两个已有方法的实现           |
| 常见 API                 | `class_addMethod`            | `method_exchangeImplementations` |
| 是否一定需要已有两个方法 | 不需要                       | 通常需要两个可交换的方法实现     |
| 典型用途                 | 动态补充方法                 | 日志、埋点、行为拦截等           |
| 与消息派发的关系         | 影响后续是否能找到方法       | 改变找到方法后执行的实现         |

这两个机制都属于 Runtime 提供的动态能力，但解决的是不同问题。

# 六、把今天的内容接回 Runtime 主线

你现在已经接触了 Runtime 的几项重要能力：

+ 消息派发： 根据接收者、选择子和类的元数据找到实现。
+ 动态方法解析： 在方法查找失败时，尝试补充实现。
+ 消息转发： 在常规查找无法解决时，为消息寻找其他处理方式。
+ Category： 为已有类提供额外方法。
+ 关联对象： 将额外数据关联到对象。
+ Method Swizzling： 在运行时交换方法实现。

这些知识不是彼此孤立的。它们都围绕同一个核心：Objective-C 的方法调用不是简单地把方法名直接绑定到固定代码，而是通过 Runtime 的类信息、方法元数据和消息派发机制来完成。

下一步适合学习 `class_addMethod`、`class_replaceMethod`、`method_setImplementation` 这几个 API 的区别。它们可以帮助你进一步理解：动态添加方法、替换方法实现、交换方法实现，到底是三种什么不同的操作。

 我们继续学习 Objective-C Runtime。上一节讲了 Method Swizzling（方法交换），这节把三个经常一起出现的 Runtime API 串起来：

+ `class_addMethod`
+ `class_replaceMethod`
+ `method_setImplementation`

它们都能影响方法的实现，但操作对象和适用场景不同。

## 一、先理解三个 API 的区别

| API                        | 作用                         | 能否添加方法         | 能否替换实现             |
| -------------------------- | ---------------------------- | -------------------- | ------------------------ |
| `class_addMethod`          | 向指定类添加方法             | 可以                 | 不替换该类已有的同名方法 |
| `class_replaceMethod`      | 替换指定类的方法实现         | 方法不存在时可以添加 | 可以                     |
| `method_setImplementation` | 修改已有 `Method` 的实现指针 | 不可以               | 可以                     |

先记住这三个关键词：

+ `class_addMethod`：添加
+ `class_replaceMethod`：按类和方法名替换
+ `method_setImplementation`：直接修改 Method 的 IMP

要真正理解它们，还需要知道一个重要概念：方法是自己定义的，还是从父类继承的。

## 二、理解 `class_addMethod`

### 1. 它的作用

```
class_addMethod(Class cls,
                SEL name,
                IMP imp,
                const char *types);
```

四个参数分别是：

+ `cls`：要添加方法的目标类。
+ `name`：方法选择器，例如 `@selector(eat)`。
+ `imp`：方法对应的实现函数。
+ `types`：方法类型编码，例如 `"v@:"`。

返回值是 `BOOL`：

+ `YES`：添加成功。
+ `NO`：添加失败，例如目标类已经直接拥有这个方法。

注意：这里检查的是目标类自己的方法列表，而不只是这个类能不能响应该方法。

### 2. 一个典型例子：子类继承了父类的方法

```
@interface Person : NSObject
- (void)eat;
@end

@implementation Person
- (void)eat {
    NSLog(@"Person 正在吃饭");
}
@end

@interface Student : Person
@end

@implementation Student
@end
```

此时，`Student` 没有自己实现 `eat`，但它继承了 `Person` 的 `eat`。

所以：

```
Student *student = [[Student alloc] init];
[student eat];
```

输出：

```
Person 正在吃饭
```

现在，我们使用 Runtime 为 `Student` 添加一个自己的 `eat` 方法。

```
#import <objc/runtime.h>

static void studentEat(id self, SEL _cmd) {
    NSLog(@"Student 正在吃饭");
}

// 在某处执行
class_addMethod(Student.class,
                @selector(eat),
                (IMP)studentEat,
                "v@:");
```

执行成功后：

```
Student *student = [[Student alloc] init];
[student eat];
```

输出变为：

```
Student 正在吃饭
```

而 `Person` 的方法没有被修改：

```
Person *person = [[Person alloc] init];
[person eat];
```

仍然输出：

```
Person 正在吃饭
```

这里发生了什么？

Student 类

新增自己的 eat 方法

Student 原本继承 Person 的 eat，现在优先找到自己的实现

Person 类

原有 eat 方法保持不变

这正是 `class_addMethod` 一个很重要的用途：给子类添加一个方法实现，从而覆盖它继承来的方法，而不直接修改父类。

这里的“覆盖”并不是传统意义上编译时写出的 `override`，而是通过 Runtime 动态地向子类添加方法。

## 三、理解 `class_replaceMethod`

它的声明是：

```
class_replaceMethod(Class cls,
                    SEL name,
                    IMP imp,
                    const char *types);
```

它和 `class_addMethod` 最大的区别是：如果目标类已经有这个方法，`class_replaceMethod` 会替换它的实现；如果目标类没有自己的这个方法，则会在该类添加方法。

继续使用刚才的 `Person` 和 `Student`。

假设我们想替换 `Person` 自己的 `eat` 实现：

```
static void newPersonEat(id self, SEL _cmd) {
    NSLog(@"新的 Person 吃饭实现");
}

class_replaceMethod(Person.class,
                    @selector(eat),
                    (IMP)newPersonEat,
                    "v@:");
```

之后：

```
Person *person = [[Person alloc] init];
[person eat];
```

输出：

```
新的 Person 吃饭实现
```

因为 `Student` 没有自己的 `eat`，它继承的是 `Person` 的方法，所以在没有其他覆盖的情况下，`Student` 调用 `eat` 也会使用新的实现。

但如果目标是 `Student`：

```
class_replaceMethod(Student.class,
                    @selector(eat),
                    (IMP)studentEat,
                    "v@:");
```

由于 `Student` 没有自己的 `eat`，Runtime 会为 `Student` 添加自己的实现，而不是直接替换 `Person` 的方法。

因此要区分两件事：

+ 替换父类自己的方法：影响父类，以及依赖该实现的子类。
+ 在子类上替换一个继承来的方法：实际上是在子类建立自己的实现，不直接改动父类。

这也是为什么 Runtime 操作继承方法时，必须弄清楚目标类和方法的归属。

## 四、理解 `method_setImplementation`

它的声明是：

```
IMP method_setImplementation(Method m, IMP imp);
```

前两个 API 接收的是 `Class` 和 `SEL`，而这个 API 接收的是一个已经取得的 `Method` 对象。

例如：

```
Method method = class_getInstanceMethod(Person.class,
                                        @selector(eat));

IMP oldIMP = method_setImplementation(method,
                                      (IMP)newPersonEat);
```

这里：

+ `class_getInstanceMethod`：取得实例方法对应的 `Method`。
+ `method_setImplementation`：将这个 `Method` 的实现改为 `newPersonEat`。
+ `oldIMP`：返回修改之前的实现指针。

注意，`class_getInstanceMethod` 也可能返回从父类继承来的方法。因此，如果你对继承的方法直接调用 `method_setImplementation`，可能影响父类共享的那个方法实现，而不只是子类。具体操作时必须谨慎。

另外，`method_setImplementation` 不负责创建一个新方法。它要求你已经拿到了对应的 `Method`。

## 五、这三个 API 和 Method Swizzling 有什么关系？

你已经学过：

```
method_exchangeImplementations(method1, method2);
```

它的目的，是交换两个方法的实现。

现在可以把四个 API 放在同一张图里理解：

### `class_addMethod`

目标类的方法列表中没有该方法时，添加一个方法实现。

### `class_replaceMethod`

通过目标类和选择器定位方法，替换实现；目标类没有自己的方法时则添加。

### `method_setImplementation`

已经有 Method 对象，直接修改它对应的实现。

### `method_exchangeImplementations`

将两个方法的实现互换，常见于 Method Swizzling。

它们的共同点是都涉及 `IMP`，但不能简单理解成四个完全等价的替换工具：前三个关注添加或设置实现，最后一个关注两个实现之间的交换。

## 六、把它们放回 Runtime 的主线

你目前学过的内容可以这样串起来：

发送消息

```
[student eat]
```

方法查找

查找类的方法列表、缓存和父类链

找到了 Method 和对应的 IMP

执行对应实现

Runtime 动态修改

添加方法、替换 IMP、交换 IMP

核心关系是：消息发送决定要查找哪个方法；方法查找决定使用哪个实现；Runtime API 可以在运行期间改变类的方法表或方法实现，从而影响后续的消息调用。

还有一个细节值得记住：`SEL` 只是方法的选择器标识，`Method` 是运行时方法元数据，`IMP` 才是实际执行的实现入口。调用这些 API 时，它们扮演的是不同角色。

下一步可以继续学习 Runtime 中的 Category 底层机制：分类的方法是怎样进入类的方法查找体系的，以及为什么多个 Category 实现同名方法时会产生冲突。这会把你之前学过的 Category、方法列表和方法查找真正连接起来。







我们继续 Runtime。上一节学了 `class_addMethod`、`class_replaceMethod`、`method_setImplementation`，接下来学习 Category（分类）的底层机制：分类的方法是怎样参与类的方法查找的。

这一节会把你之前学过的几个知识点串起来：类对象、方法列表、继承链、IMP，以及方法交换。

## 一、先回顾 Category 能做什么

假设你有一个 `Person` 类：

```
@interface Person : NSObject
- (void)eat;
@end

@implementation Person

- (void)eat {
    NSLog(@"Person eat");
}

@end
```

现在想给 `Person` 增加一个 `run` 方法，但暂时不想修改原来的 `Person.m`。

可以使用 Category：

```
@interface Person (Sport)
- (void)run;
@end

@implementation Person (Sport)

- (void)run {
    NSLog(@"Person run");
}

@end
```

调用时：

```
Person *person = [[Person alloc] init];
[person run];
```

输出：

```
Person run
```

这里有个关键问题：`run` 明明写在 `Person (Sport)` 分类里，为什么 `Person` 对象可以直接调用它？

答案是：Category 的方法会被 Objective-C Runtime 纳入相应类的方法查找体系。

但是，理解这一点还不够。我们需要进一步区分：分类和原始类的方法，到底是怎样组织起来的。

## 二、Category 并不是创建了一个新类

先纠正一个容易出现的误解。

写下：

```
@implementation Person (Sport)
```

并不会创建一个叫作 `Sport` 的新类，也不会创建一个 `PersonSport` 子类。

实际上：

+ `Person` 仍然是原来的类。
+ `Sport` 是分类的名称。
+ 分类为 `Person` 增加方法等运行时元数据。
+ `Person` 的实例仍然是 `Person` 对象，`isa` 仍然指向 `Person` 类对象。

因此，分类与继承的区别是：

继承：创建新的子类

`Student` 类

superclass 指向

`Person` 类

分类：扩展现有类

`Person` 原始实现

`Person (Sport)` 分类提供的方法

分类不是新的类对象，也没有独立的实例继承链。

这里要注意：分类通常可以增加方法，但不能直接给已有类增加实例变量。分类中声明 `@property` 也不会自动生成对应的实例变量和存取方法。

## 三、Runtime 如何找到分类中的方法？

这是本节最重要的内容。

先看原始类和分类分别实现了不同的方法：

```
@implementation Person

- (void)eat {
    NSLog(@"原始类的 eat");
}

@end
```

分类中：

```
@implementation Person (Sport)

- (void)run {
    NSLog(@"分类的 run");
}

@end
```

从概念上理解，Runtime 需要能够找到这两处实现的方法元数据：

+ 原始类提供的 `eat`。
+ 分类提供的 `run`。

当执行：

```
[person eat];
[person run];
```

Runtime 都能根据相应的选择器找到方法实现，再通过对应的 `IMP` 执行代码。

但要注意：分类的方法元数据并不意味着编译器把分类的源码直接合并进了原始 `Person.m` 文件。

编译阶段，分类通常会形成独立的运行时元数据；程序启动和类加载过程中，Runtime 会处理这些元数据，使分类方法参与对应类的方法查找。

具体内部数据结构和加载细节会随 Objective-C Runtime 的实现版本而有所不同。学习时先抓住这个稳定的概念：分类的方法最终能够通过原有类的消息发送机制被查找到。

## 四、多个 Category 都实现同一个方法，会发生什么？

现在进入一个非常重要的场景。

原始类：

```
@implementation Person

- (void)eat {
    NSLog(@"原始类 eat");
}

@end
```

分类 A：

```
@implementation Person (A)

- (void)eat {
    NSLog(@"分类 A eat");
}

@end
```

分类 B：

```
@implementation Person (B)

- (void)eat {
    NSLog(@"分类 B eat");
}

@end
```

现在，三个地方都实现了同一个选择器 `eat`。

这意味着它们都提供了一个名为 `eat` 的方法实现，但一次普通的：

```
[person eat];
```

不会依次调用三个实现，而是只会根据 Runtime 最终采用的方法查找结果调用一个实现。

不要依赖分类之间同名方法的固定优先级。 实际结果可能受到分类加载顺序、链接配置及 Runtime 实现细节等因素影响。

如果多个分类都定义同名方法，可能造成原有实现被遮蔽，程序行为也会难以预测。

这就是为什么我们应该避免随意在多个 Category 中重写同一个选择器。

## 五、Category 和 Method Swizzling 是怎样联系起来的？

你之前学过 Method Swizzling，它通常会在分类中实现一个包装方法，再把包装方法与原方法的 `IMP` 交换。

例如：

```
@implementation Person (Logging)

- (void)logging_eat {
    NSLog(@"开始吃饭");

    [self logging_eat];

    NSLog(@"结束吃饭");
}

@end
```

单看这段代码，`[self logging_eat]` 会再次调用 `logging_eat`，看起来似乎会无限递归。

但是在正确执行方法交换后：

+ `eat` 对应包装方法的 `IMP`。
+ `logging_eat` 对应原始 `eat` 的 `IMP`。

因此，包装方法内部调用 `[self logging_eat]` 时，实际上会进入原始的吃饭实现，而不是再次进入包装方法。

这也说明了一个核心区别：

+ Category：提供分类方法，让这些方法参与类的方法查找。
+ Method Swizzling：交换方法实现，让某个选择器最终调用另一个实现。

分类经常被用来组织 Swizzling 代码，但分类本身并不等于方法交换。

## 六、把 Category 放回 Runtime 的整体主线

你现在可以把这几个知识点连成一条完整的逻辑链：

Category 提供方法

Runtime 处理分类元数据

使分类方法参与类的方法查找体系

发送消息并查找方法

根据 SEL 查找可用实现

调用 IMP

执行最终找到的方法实现

你之前学习的 `class_addMethod`、`class_replaceMethod` 和 `method_setImplementation`，也都可以放在这条主线上理解：它们从不同角度影响方法的可用性或实现。

下一节建议学习：Category 为什么不能直接添加实例变量，以及关联对象（Associated Objects）如何弥补这个限制。 这会进一步解释 `objc_setAssociatedObject`、`objc_getAssociatedObject` 的用途，并与之前学过的 Category 知识衔接起来。





我们继续学习 Objective-C Runtime。上一节讲了 Category 的方法如何参与 Runtime 的方法查找，这一节继续下一个知识点：关联对象（Associated Objects）。

它主要解决一个问题：不能直接在 Category 中添加实例变量，但有时又希望给已有类的对象附加额外的数据，怎么办？

## 一、为什么 Category 不能直接添加实例变量？

假设你有一个已经写好的 `Person` 类：

```
@interface Person : NSObject

@property (nonatomic, copy) NSString *name;

@end
```

现在，你想通过分类给 `Person` 增加一个 `age` 属性：

```
@interface Person (Info)

@property (nonatomic, assign) NSInteger age;

@end
```

这段代码可以通过编译，但它不会自动生成 `age` 对应的实例变量，也不会自动生成可用的 getter 和 setter 实现。

例如，下面这样直接调用，通常会因为缺少对应方法实现而导致运行时异常：

```
Person *person = [[Person alloc] init];
person.age = 18;
```

为什么？

先回忆一下普通类中的属性：

```
@interface Person : NSObject
@property (nonatomic, copy) NSString *name;
@end
```

在常规的 `@implementation Person` 中，编译器通常会为 `name` 自动合成存取方法，并为实例存储安排相应的实例变量。

但是 Category 是对已有类的扩展。它不能像定义新类那样，改变已有实例的内存布局，直接给每个对象增加一个新的实例变量。

因此，Category 中声明 `@property`，本身并不等于实现属性。

## 二、关联对象是什么？

Objective-C Runtime 提供了一组关联对象 API，可以把额外的数据与某个对象关联起来。

最常用的是三个：

| API                            | 作用                       |
| ------------------------------ | -------------------------- |
| `objc_setAssociatedObject`     | 设置或更新关联数据         |
| `objc_getAssociatedObject`     | 读取关联数据               |
| `objc_removeAssociatedObjects` | 移除指定对象的全部关联数据 |

使用前需要导入：

```
#import <objc/runtime.h>
```

这里的核心思想是：

不修改对象原本的实例变量布局，而是通过 Runtime 维护额外的对象与数据之间的关联。

可以把它理解成一张逻辑上的映射表：

Person 对象

原本就存在的对象

Runtime 维护关联

关联数据

例如 age = 18

注意，这只是便于理解的概念图，并不意味着 Runtime 内部一定使用一张简单的字典来实现所有关联操作。

## 三、实际实现：给 Category 增加 `age` 属性

我们分成三个步骤：声明属性、实现 getter、实现 setter。

### 第一步：声明 Category

```
#import <Foundation/Foundation.h>

@interface Person (Info)

@property (nonatomic, assign) NSInteger age;

@end
```

这里仅声明属性，不会自动生成存取方法。

### 第二步：实现 getter 和 setter

```
#import "Person+Info.h"
#import <objc/runtime.h>

@implementation Person (Info)

static char ageKey;

- (void)setAge:(NSInteger)age {
    objc_setAssociatedObject(self,
                             &ageKey,
                             @(age),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSInteger)age {
    NSNumber *number = objc_getAssociatedObject(self, &ageKey);
    return number.integerValue;
}

@end
```

现在逐步理解这段代码。

1. `static char ageKey;`

它用来提供一个唯一的关联标识。

这里使用 `&ageKey`，是因为关联对象 API 接收的是一个 `const void *` 类型的 key。使用静态变量的地址，可以在这个实现文件中稳定地标识 `age` 这项关联数据。

key 不需要真的保存年龄；它只负责区分不同的关联属性。

2. `objc_setAssociatedObject`

```
objc_setAssociatedObject(self,
                         &ageKey,
                         @(age),
                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
```

四个参数分别是：

+ `self`：要关联数据的对象。
+ `&ageKey`：关联数据的唯一标识。
+ `@(age)`：将基本整数包装成 `NSNumber` 对象。
+ `OBJC_ASSOCIATION_RETAIN_NONATOMIC`：指定关联对象的内存管理策略。

这里必须包装整数，是因为关联对象存储的 value 是对象类型，而 `NSInteger` 是基本整数类型。

3. `objc_getAssociatedObject`

```
NSNumber *number = objc_getAssociatedObject(self, &ageKey);
return number.integerValue;
```

它使用相同的对象和 key 查找关联值，再将 `NSNumber` 转换回 `NSInteger`。

如果之前没有设置过这个值，读取结果通常是 `nil`，而 `nil.integerValue` 会得到 `0`。

### 第三步：使用这个属性

```
Person *person = [[Person alloc] init];

person.age = 18;

NSLog(@"%ld", (long)person.age);
```

输出：

```
18
```

这样，`Person` 的分类就拥有了可用的 `age` 存取方法，而且没有直接修改 `Person` 原有的实例变量布局。

## 四、为什么要使用不同的关联 key？

假设一个分类增加两个属性：

```
@property (nonatomic, copy) NSString *nickname;
@property (nonatomic, copy) NSString *city;
```

它们应该使用不同的 key。

例如：

```
static char nicknameKey;
static char cityKey;
```

设置昵称：

```
objc_setAssociatedObject(self,
                         &nicknameKey,
                         nickname,
                         OBJC_ASSOCIATION_COPY_NONATOMIC);
```

设置城市：

```
objc_setAssociatedObject(self,
                         &cityKey,
                         city,
                         OBJC_ASSOCIATION_COPY_NONATOMIC);
```

如果两个属性误用了相同的 key，那么读取时就无法通过 key 区分它们，后续设置也可能覆盖之前的关联值。

所以要记住：

每一个需要独立存储的关联属性，都应该使用能够稳定区分它的 key。

## 五、关联对象的内存管理策略

`objc_setAssociatedObject` 的最后一个参数决定关联对象的持有方式。

| 策略                                | 含义                                   |
| ----------------------------------- | -------------------------------------- |
| `OBJC_ASSOCIATION_ASSIGN`           | 不强持有关联值；不提供可靠的弱引用语义 |
| `OBJC_ASSOCIATION_RETAIN_NONATOMIC` | 强持有关联值，不提供原子性保证         |
| `OBJC_ASSOCIATION_COPY_NONATOMIC`   | 复制关联值，不提供原子性保证           |
| `OBJC_ASSOCIATION_RETAIN`           | 强持有关联值，具有原子性保证           |
| `OBJC_ASSOCIATION_COPY`             | 复制关联值，具有原子性保证             |

这里有三个容易混淆的地方：

+ `RETAIN` 不等于 `COPY`：前者持有传入的对象，后者复制对象。
+ `NONATOMIC` 不等于线程安全：它表示关联操作不提供原子性保证。
+ `ASSIGN` 不等于 `WEAK`：它不会自动提供安全的弱引用清零行为。

对于字符串等不可变类型属性，常见做法是使用 `OBJC_ASSOCIATION_COPY_NONATOMIC`。

对于整数等基本类型，通常先包装为 `NSNumber`，再使用合适的对象关联策略。

## 六、关联对象和 `@property` 到底是什么关系？

这是本节最需要建立的认知。

```
@property
```

声明属性接口，描述属性的名称和类型等信息。

getter / setter

提供真正的读取和写入行为。Category 中通常需要自己实现。

关联对象 API

为对象附加和读取额外的数据，而不需要直接增加实例变量。

这三者不是同一个概念：声明属性并不会自动创建关联对象；关联对象也不会自动生成 getter 和 setter。需要我们将存取方法与关联对象 API 连接起来。

还有一个补充：`objc_removeAssociatedObjects(person)` 会移除 `person` 的全部关联对象，可能影响其他代码添加的关联数据。因此，一般不应把它当作删除某一个属性的常规方法。若需要移除单项关联值，可以将对应 key 的 value 设置为 `nil`。

## 七、把这一节放回 Runtime 的主线

你已经学过：

1. `isa` 和 `superclass`：对象如何找到所属类，类如何组织继承关系。
2. `SEL`、`Method` 和 `IMP`：方法如何被识别、查找和执行。
3. 动态方法解析与消息转发：常规查找失败后，Runtime 如何处理消息。
4. Category：如何扩展已有类的方法。
5. Method Swizzling：如何交换方法的实现。
6. 关联对象：如何给现有对象附加额外的数据。

它们都围绕同一个核心问题展开：Objective-C 对象、类、方法和消息之间的关系，如何由 Runtime 在运行时管理。

下一节适合学习 Runtime 的属性与实例变量相关 API，例如 `class_copyPropertyList`、`class_copyIvarList`、`class_getInstanceVariable`。这样你就能进一步理解：Runtime 如何读取类的属性元数据、实例变量元数据，以及它们与实际对象内存布局之间的区别。







我们继续学习 Objective-C Runtime。上一节讲了关联对象，这一节学习 Runtime 如何获取类的属性、实例变量和方法等元数据。

这部分很重要，因为它会把你之前学过的 `Class`、`Method`、`IMP` 和对象内存布局连接起来。

# 一、先区分三个概念：属性、实例变量、方法

先看一个类：

```
@interface Person : NSObject {
    NSInteger _age;
}

@property (nonatomic, copy) NSString *name;

- (void)eat;

@end
```

这里有三个不同的概念。

### 1. 属性 Property

`name` 是属性，描述对象具有一个名为 `name` 的属性接口。

Runtime API：`class_copyPropertyList`

### 2. 实例变量 Ivar

`_age` 是实例变量，用于在对象实例中存储数据。

Runtime API：`class_copyIvarList`

### 3. 方法 Method

`eat` 是实例方法，描述对象可以响应的一种消息。

Runtime API：`class_copyMethodList`

它们之间有关联，但不能画等号。

例如，普通类中的 `@property name` 通常会由编译器自动合成实例变量和 getter、setter；但 Category 中声明属性，并不会自动合成这些内容。

因此，理解 Runtime 元数据时，必须分清楚：属性描述、实际存储、方法实现是三个不同层面。

# 二、获取类的属性列表：`class_copyPropertyList`

先看这个 API：

```
objc_property_t *class_copyPropertyList(
    Class cls,
    unsigned int *outCount
);
```

它的作用是获取指定类自己声明的属性列表。

例如：

```
#import <objc/runtime.h>

unsigned int count = 0;

objc_property_t *properties =
    class_copyPropertyList(Person.class, &count);

for (unsigned int i = 0; i < count; i++) {
    objc_property_t property = properties[i];

    const char *name = property_getName(property);

    NSLog(@"属性名称：%s", name);
}

free(properties);
```

假设 `Person` 声明了 `name` 属性，输出可能是：

```
属性名称：name
```

这里有几个需要理解的细节。

### 1. `objc_property_t` 是什么？

它是 Runtime 用来表示属性元数据的类型。

你可以把它理解成一个属性描述对象，通过相应的 API 可以获取属性名、属性特征等信息。

例如：

```
const char *name = property_getName(property);
```

获取属性名称。

而：

```
const char *attributes = property_getAttributes(property);
```

获取属性的特征字符串。

### 2. `outCount` 是什么？

`outCount` 是输出参数，用于接收返回的属性数量。

例如，假设类有两个属性：

```
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSInteger age;
```

那么 `count` 通常就是 `2`。

### 3. 为什么要调用 `free`？

`class_copyPropertyList` 返回的是需要由调用者释放的动态分配数组。

所以遍历完成后，需要：

```
free(properties);
```

这释放的是属性列表数组的内存，不是 `Person` 对象，也不是属性本身。

还有一个非常重要的细节：

`class_copyPropertyList` 不会自动递归获取父类的属性。

如果 `Student : Person`，调用：

```
class_copyPropertyList(Student.class, &count);
```

获取的是 `Student` 自己声明的属性，而不是 `Person` 的全部属性。

如果想收集整个继承链上的属性，就需要从子类开始，逐级遍历 `class_getSuperclass`。

# 三、获取实例变量列表：`class_copyIvarList`

接下来是实例变量。

```
Ivar *class_copyIvarList(
    Class cls,
    unsigned int *outCount
);
```

这个 API 获取指定类自己声明的实例变量。

例如：

```
unsigned int count = 0;

Ivar *ivars = class_copyIvarList(Person.class, &count);

for (unsigned int i = 0; i < count; i++) {
    Ivar ivar = ivars[i];

    const char *name = ivar_getName(ivar);
    const char *type = ivar_getTypeEncoding(ivar);

    NSLog(@"变量名：%s，类型编码：%s", name, type);
}

free(ivars);
```

如果 `Person` 中有：

```
@interface Person : NSObject {
    NSInteger _age;
}
@end
```

那么获取到的实例变量列表中会包含 `_age`。

`ivar_getName` 获取变量名，`ivar_getTypeEncoding` 获取类型编码。

需要注意，实际类型编码与具体类型和平台有关，不应把所有类型编码都当成普通字符串名称。

## 属性和实例变量为什么不能混淆？

例如：

```
@property (nonatomic, copy) NSString *name;
```

在普通 Objective-C 类的自动合成机制下，编译器通常会生成一个对应的实例变量，常见名称是 `_name`。

但：

+ 属性名是 `name`。
+ 实例变量名通常是 `_name`。
+ getter 是 `name`。
+ setter 是 `setName:`。

这是不同的元数据。

另外，`class_copyIvarList` 同样只获取指定类自己声明的实例变量，不会自动把父类的实例变量一起列出来。

# 四、获取方法列表：`class_copyMethodList`

你已经学过 `Method` 和 `IMP`，现在把它们放进实际代码里。

```
Method *methods = class_copyMethodList(Person.class, &count);

for (unsigned int i = 0; i < count; i++) {
    Method method = methods[i];

    SEL selector = method_getName(method);

    NSLog(@"方法名称：%@",
          NSStringFromSelector(selector));
}

free(methods);
```

假设 `Person` 自己实现了 `eat`，并且编译器为 `name` 合成了 getter 和 setter，那么方法列表中可能包含：

+ `eat`
+ `name`
+ `setName:`

这里的重点是：属性和方法列表不是同一份列表。

`name` 作为属性可以出现在属性列表中，而它对应的 getter、setter 又可以出现在方法列表中。

还要注意，`class_copyMethodList` 获取的是指定类自己直接实现的方法列表，不会自动包含父类的方法。

例如，`Student` 继承 `Person`，但没有实现 `eat`：

```
Student *student = [[Student alloc] init];
[student eat];
```

即使调用成功，`eat` 也不一定出现在 `Student` 自己的方法列表中，因为它可能是从 `Person` 继承来的。

这与你之前学过的消息查找机制完全一致：一个对象能够调用的方法，不等于它所属类自己实现的方法。

# 五、三个 API 的区别

| API                      | 获取内容       | 是否自动包含父类 |
| ------------------------ | -------------- | ---------------- |
| `class_copyPropertyList` | 属性元数据     | 否               |
| `class_copyIvarList`     | 实例变量元数据 | 否               |
| `class_copyMethodList`   | 方法列表       | 否               |

如果你想知道一个子类能够使用哪些继承方法，就不能只依赖 `class_copyMethodList`。

需要结合：

```
Class superclass = class_getSuperclass(Student.class);
```

沿着 `superclass` 逐级查找。

概念上可以理解成：

Student 类

自己的属性、实例变量、方法

class_getSuperclass

Person 类

父类自己的属性、实例变量、方法

NSObject 类

不过，继承链上的方法查找与属性、实例变量的枚举是不同的问题，不能认为三种 `class_copy...List` 都会像消息查找一样自动沿着父类链遍历。

# 六、再深入一点：获取某个指定实例变量

前面讲的是获取整个列表。

如果你只想获取一个实例变量，可以使用：

```
Ivar ivar = class_getInstanceVariable(Person.class, "_age");
```

它的作用是根据类和实例变量名获取对应的 `Ivar`。

与 `class_copyIvarList` 不同，`class_getInstanceVariable` 会沿继承链查找，因此可以获取类自身或其父类中声明的实例变量。

获得 `Ivar` 后，还可以读取：

```
const char *name = ivar_getName(ivar);
```

获取变量名，或者：

```
ptrdiff_t offset = ivar_getOffset(ivar);
```

获取实例变量相对于对象实例起始位置的偏移量。

这里需要注意：偏移量是 Runtime 元数据中的布局信息，并不意味着你应该在业务代码中随意通过指针运算修改对象内部内存。对象布局、内存管理和访问权限都有相应约束。

# 七、把本节放回 Runtime 的主线

现在可以把 Runtime 的几个核心层次进一步连起来：

Class 类对象

### 属性元数据

```
objc_property_t
```

属性名、属性特征

### 实例变量元数据  

```
Ivar
```

变量名、类型、偏移量

### 方法元数据

```
Method` → `IMP
```

方法选择器、类型信息、实现入口

这几个 API 是观察 Runtime 元数据的工具。它们帮助你了解类声明了什么，但读取到元数据不等于直接读取了属性的实际值，也不等于修改了对象的内存布局。

下一节可以继续学习 `class_getInstanceSize`、`class_getInstanceVariable` 和对象内存布局之间的关系，进一步理解 `isa`、实例变量偏移量与对象实际占用空间之间的联系。