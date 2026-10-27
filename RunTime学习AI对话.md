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