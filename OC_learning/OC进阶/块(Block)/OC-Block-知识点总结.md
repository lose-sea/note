# Objective-C Block 知识点总结

> 配套详解：[OC-Block-知识详解.md](file:///Users/lose_sea/Documents/github/note/OC_learning/OC进阶/块(Block)/OC-Block-知识详解.md)
>
> 主线：**写出来 → 捕获了什么 → 住在哪块内存 → 怎么改外部变量 → 怎么不泄漏**

---

## 一、一句话理解 Block

> **Block 是「一段代码」+「这段代码用到的外部变量」打包成的一个 Objective-C 对象。**

三个关键词：代码（能执行）、捕获（记得上下文）、对象（有 `isa`，可传递可持有）。

---

## 二、知识地图

```text
第一层  语法        声明 / 定义 / 赋值 / 调用 / typedef / 参数 / 返回值 / 属性
   │
第二层  本质        结构体 / isa / FuncPtr / Desc / copy / dispose
   │
第三层  捕获        auto 值捕获 / static 地址捕获 / 全局不捕获 / 对象指针 / self
   │
第四层  内存        Global / Stack / Malloc / copy 行为 / ARC 自动 copy
   │
第五层  工程        循环引用 / weak-strong / 回调设计 / 常见坑
```

---

## 三、语法

### 3.1 一条公式

```text
返回值类型 (^变量名)(参数类型列表) = ^返回值类型(参数名列表) { 代码 };
```

| 部分 | 规则 |
| --- | --- |
| 返回值 | 声明里不能省；定义里可省（编译器推断） |
| `^名字` | 脱字符不能省，整体要在括号里 |
| 参数类型 | 无参数写 `void`，不能空着 |
| 参数名 | 定义里必须有；声明里可省 |

### 3.2 常见写法

```objc
// 无参无返回
void (^hello)(void) = ^{ NSLog(@"hi"); };

// 有参有返回
int (^add)(int, int) = ^(int a, int b) { return a + b; };

// typedef（项目里最常用）
typedef void (^CompletionBlock)(NSData *data, NSError *error);
@property (nonatomic, copy) CompletionBlock completion;

// 作为参数
- (void)request:(NSString *)url completion:(void (^)(NSData *, NSError *))completion;

// 作为返回值
- (TaskBlock)makeTask;
```

### 3.3 语法坑

| 写法 | 问题 |
| --- | --- |
| `void (^blk)()` | 表示"参数未指定"，会警告，应写 `(void)` |
| `void ^blk(void)` | `^` 位置错 |
| 声明了没赋值就调用 | 崩溃 |
| 字面量后忘加分号 | 编译报错 |

---

## 四、本质

### 4.1 是对象

```text
__NSGlobalBlock__ / __NSStackBlock__ / __NSMallocBlock__
        ↓
      NSBlock
        ↓
     NSObject
```

### 4.2 四个结构体

```c
// ① 公共头
struct __block_impl {
    void *isa;        // 是哪种 block
    int   Flags;
    int   Reserved;
    void *FuncPtr;    // 真正执行的函数
};

// ② 这个 block 的完整结构
struct __main_block_impl_0 {
    struct __block_impl impl;
    struct __main_block_desc_0 *Desc;
    int age;          // ← 捕获的变量就是这里加的成员
};

// ③ 真正执行的代码
static void __main_block_func_0(struct __main_block_impl_0 *__cself) {
    int age = __cself->age;   // bound by copy
    // ...
}

// ④ 描述信息（捕获对象时多 copy/dispose）
struct __main_block_desc_0 {
    size_t reserved;
    size_t Block_size;
    void (*copy)(...);       // block 搬到堆时调用 → _Block_object_assign → retain
    void (*dispose)(...);    // block 销毁时调用 → _Block_object_dispose → release
};
```

### 4.3 核心认知

- **捕获一个变量 = 在结构体里加一个成员。**
- **调用 block = 取出 `FuncPtr`，把 block 自己当第一个参数传进去。**
- clang 重写出来的 `isa` 永远是 `_NSConcreteStackBlock`，**不能用它推断 block 类型**。

---

## 五、变量捕获

### 5.1 总表（背下来）

| 变量 | 是否捕获 | 方式 | 能否改 | 看到的值 |
| --- | --- | --- | --- | --- |
| 局部 auto（基本类型） | ✅ | 值 | ❌ | 定义时的快照 |
| 局部 auto（对象指针） | ✅ | 值（指针） | ❌ 改指针；✅ 改对象 | 定义时那个对象 |
| 局部 static | ✅ | 地址 | ✅ | 调用时最新值 |
| 全局 / 全局 static | ❌ | 直接访问 | ✅ | 调用时最新值 |
| `__block` 局部 | ✅ | byref 指针 | ✅ | 永远最新 |
| 成员变量 `_ivar` | ✅（经 `self`） | 值（`self`） | ❌ 改 self | 同一个 self |
| C 数组 | ❌ 不能捕获 | — | — | 编译报错 |
| 结构体 | ✅ | 值（整体） | ❌ | 定义时快照 |

### 5.2 四条金句

1. **捕获的是变量，不是对象。**
2. **捕获的时机是定义时，不是调用时。**
3. **能改对象，不能改变量。**（`[arr addObject:]` ✅ / `arr = ...` ❌）
4. **捕获指针 ≠ 复制对象。**

### 5.3 对照实验

```objc
int g = 5;
auto   int a = 10;
static int s = 20;
__block int b = 30;

void (^blk)(void) = ^{
    NSLog(@"a=%d s=%d b=%d g=%d", a, s, b, g);
    s = 2; b = 3; g = 4;        // a 不能改
};
a = 100; s = 200; b = 300; g = 500;
blk();
```

```text
a=10 s=200 b=300 g=500      ← a 是快照，其它都是最新
```

### 5.4 捕获对象会不会 retain

| block 状态 | `__strong` 捕获对象 |
| --- | --- |
| 栈上 | **不 retain** |
| copy 到堆 | **retain**（`desc->copy`） |
| 堆 block 销毁 | **release**（`desc->dispose`） |

### 5.5 捕获 self

```objc
self.blk = ^{ NSLog(@"%@", _ivar); };           // 隐式 self
self.blk = ^{ NSLog(@"%@", self->_ivar); };     // 显式 self
self.blk = ^{ NSLog(@"%@", self.description); };// 调方法
```

**三种都捕获 `self`**，编译器都会警告 `capturing 'self' strongly ... likely to lead to a retain cycle`。

---

## 六、`__block`

### 6.1 两种用法

```objc
// ① 在 block 内修改局部变量
__block BOOL found = NO;
[array enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
    if ([obj isEqual:@"x"]) { found = YES; *stop = YES; }
}];

// ② 打破循环引用（ARC，需手动置 nil + 必须调用）
__block Person *p = [Person new];
p.block = ^{ p = nil; };
p.block();
```

### 6.2 限制

```objc
__block static int s = 0;    // ❌ error: only allowed on local variables
__block int g = 0;           // ❌ 全局变量不能加（也不需要）
```

### 6.3 底层

```c
struct __Block_byref_age_0 {
    void *__isa;                        // 也是对象
    __Block_byref_age_0 *__forwarding;  // 指向"当前有效的那一份"
    int __flags;
    int __size;
    int age;                            // 真正的值
};
```

访问方式：

```c
(age->__forwarding->age) = 20;            // 写
NSLog(@"%d", age->__forwarding->age);     // 读
```

### 6.4 `__forwarding` 的作用

| 阶段 | 栈上原件 | 堆上副本 |
| --- | --- | --- |
| copy 前 | `__forwarding` → 自己 | 不存在 |
| copy 后 | `__forwarding` → **堆副本** | `__forwarding` → 自己 |

**保证内外访问最终落在同一块内存。** 实测：copy 后连调两次堆 block 得 12，再调栈 block 得 13（连续累加，证明是同一份）。

### 6.5 ARC vs MRC

| 环境 | `__block` 中的对象 |
| --- | --- |
| ARC | 按 `__strong`/`__weak`/`__unsafe_unretained` 处理，`__strong` **会 retain** |
| MRC | **不 retain** |

所以 **MRC 下 `__block` 天然破环，ARC 下必须手动置 nil**。

---

## 七、三种类型与 copy

### 7.1 类型表

| 类型 | 内存 | 条件 | 生命周期 |
| --- | --- | --- | --- |
| `__NSGlobalBlock__` | 数据段 | 不捕获 auto | 程序结束 |
| `__NSStackBlock__` | 栈 | 捕获 auto，未 copy | 作用域结束 |
| `__NSMallocBlock__` | 堆 | 栈 block 被 copy | 引用计数 |

### 7.2 copy 矩阵（必背）

| 原类型 | copy 后 |
| --- | --- |
| Global | 什么都不做，类型不变 |
| Stack | → Malloc，引用计数 1 |
| Malloc | 引用计数 +1，类型不变 |

### 7.3 ARC 自动 copy 的三种情况

1. 赋给**强指针**
2. 作为**函数/方法返回值**
3. 作为 **GCD** 或 **`usingBlock`** API 的参数

### 7.4 关键澄清

| 说法 | 真相 |
| --- | --- |
| "写 `^{}` 就是堆 block" | ❌ `[^{...} class]` 是 `__NSStackBlock__`，**决定类型的是它被怎么接住** |
| "传参就会 copy" | ❌ 实测 `probe(^{...})` 在 MRC callee 侧仍是 `__NSStackBlock__` |
| "block 属性不能用 strong" | ⚠️ **`strong` 会被 clang 自动改写成 `copy`**（实测编码 `T@?,C`），ARC 下安全 |
| "block 属性不能用 retain" | ✅ 正确，`retain` **不会**被改写（实测 `T@?,&`），编译器还会警告 |
| "assign 也能用" | ❌ 编码 `T@?,N`，不改写、不 retain，必崩 |

### 7.5 属性写法

```objc
@property (nonatomic, copy) void (^completionBlock)(void);   // ✅ 唯一推荐
```

MRC setter：

```objc
- (void)setCompletionBlock:(void (^)(void))completionBlock {
    if (_completionBlock != completionBlock) {
        [_completionBlock release];
        _completionBlock = [completionBlock copy];
    }
}
```

---

## 八、循环引用

### 8.1 成因

```text
self ──strong──> block ──strong──> self
```

### 8.2 解法

| 方案 | 写法 | 缺点 |
| --- | --- | --- |
| `__weak`（首选） | `__weak typeof(self) w = self;` | 使用时可能 nil |
| `__weak` + `__strong` | 见下方模板 | 代码稍长 |
| `__unsafe_unretained` | 同 weak 但不置 nil | 野指针 |
| `__block` + 置 nil | 需 `__block` + 置 nil + 必须调用 | 不调用就白搭 |

### 8.3 标准模板（背下来）

```objc
__weak typeof(self) weakSelf = self;
self.block = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;   // ① 先保活
    if (!strongSelf) return;                           // ② 再判空
    [strongSelf doSomething];                           // ③ 全程用它
};
```

> ⚠️ 顺序不能反：**先转 strong，再判空**。先判空再转 strong 会出现"判断时活着、使用时已释放"。

### 8.4 哪些不是环

| 场景 | 是否环 | 原因 |
| --- | --- | --- |
| `dispatch_after` / `dispatch_async` | ❌ | 执行完队列就释放 |
| `UIView animate...` | ❌ | 动画结束释放（`repeat` 除外） |
| `enumerateObjectsUsingBlock:` | ❌ | 遍历完即释放 |
| `self.timer = [NSTimer ... target:self]` | ✅ | timer 强引用 target（不是 block 的锅） |

### 8.5 MRC 方案

- `__unsafe_unretained`（MRC 没有 `__weak`）
- 直接 `__block`（MRC 下 byref 不 retain，天然不成环）

---

## 九、工程实践

### 9.1 命名

```objc
typedef void (^XLNetworkCompletion)(NSData *data, NSError *error);
typedef BOOL (^XLValidator)(NSString *input);
```

以 `Block` / `Handler` / `Completion` 结尾。

### 9.2 回调 API 设计

1. 一个方法**最多一个** block 参数
2. block 放**最后一个**参数
3. block 参数**必须判空**再调用

### 9.3 Block vs Delegate vs Notification

| 维度 | Block | Delegate | Notification |
| --- | --- | --- | --- |
| 耦合 | 低 | 中 | 最低 |
| 代码量 | 少 | 多 | 中 |
| 一对多 | ❌ | ❌ | ✅ |
| 适合 | 单次回调 | 稳定关系 | 跨模块广播 |

### 9.4 其他

| 场景 | 要点 |
| --- | --- |
| 批量任务 | 存数组时显式 `[task copy]` |
| 链式调用 | block 返回 `self`；**block 存在 self 上时必须 `__weak`** |
| 线程安全 | `__block` 不保证原子性，需加锁或串行队列 |
| 只调一次 | `__block BOOL hasCalled` 或 `dispatch_once` |
| 大对象 | 只捕获需要的最小值，别整个数组捕获 |

---

## 十、坑总表

| # | 坑 | 解决 |
| --- | --- | --- |
| 1 | block 属性用 `assign` | 改 `copy` |
| 2 | block 属性用 `retain`（不 copy） | 改 `copy`（`strong` 会被改写，`retain` 不会） |
| 3 | block 内改局部变量 | 加 `__block` |
| 4 | `self` 循环引用 | `__weak` |
| 5 | 用 `_ivar` 以为没事 | 同样捕获 self，要 `__weak` |
| 6 | `weakSelf` 中途变 nil | `__strong` 保活 + 判空 |
| 7 | 先判空再转 strong | 先转 strong 再判空 |
| 8 | 调用未赋值的 block | 调用前判空 |
| 9 | 捕获 C 数组 | 用指针或 NSArray |
| 10 | `void (^blk)()` | 写 `(void)` |
| 11 | 多线程改 `__block` | 加锁 / 串行队列 |
| 12 | 捕获大对象 | 只捕获需要的值 |
| 13 | 存数组忘 copy | `[task copy]` |
| 14 | 以为 GCD 一定有环 | 临时持有不是环 |
| 15 | MRC 用 `__weak` | 用 `__unsafe_unretained` |
| 16 | ARC 以为 `__block` 不成环 | ARC 下会 retain，要置 nil |
| 17 | `__block` 修饰全局/静态 | 编译报错，不需要 |
| 18 | 字面量后忘 `;` | 补上 |

---

## 十一、一页速查

```text
┌──────────────────────────────────────────────────────────┐
│ 语法    返回值 (^名字)(参数类型) = ^(参数名){ ... };       │
│         无参数写 (void)，不是 ()                          │
├──────────────────────────────────────────────────────────┤
│ 本质    isa + Flags + Reserved + FuncPtr + Desc + 捕获变量 │
│         继承：__NSXxxBlock__ → NSBlock → NSObject          │
├──────────────────────────────────────────────────────────┤
│ 捕获    auto     → 值（快照，只读）                        │
│         static   → 地址（可改，读最新）                    │
│         全局     → 不捕获（可改，读最新）                  │
│         __block  → byref 指针（可改，内外同步）            │
│         对象     → 指针；堆 block 才 retain                │
│         C 数组   → 不能捕获                                │
├──────────────────────────────────────────────────────────┤
│ 内存    Global  数据段  不捕获 auto   copy 无操作          │
│         Stack   栈      捕获 auto     copy → Malloc        │
│         Malloc  堆      已 copy       copy → 计数 +1       │
├──────────────────────────────────────────────────────────┤
│ 破环    __weak typeof(self) weakSelf = self;               │
│         __strong typeof(weakSelf) strongSelf = weakSelf;   │
│         if (!strongSelf) return;                           │
├──────────────────────────────────────────────────────────┤
│ 属性    @property (nonatomic, copy) void (^blk)(void);     │
└──────────────────────────────────────────────────────────┘
```

---

## 十二、自测（20 题）

1. 写一个"输入两个 int，返回和"的 block 并调用。
2. `void (^blk)()` 和 `void (^blk)(void)` 有什么区别？
3. 用 typedef 声明"接收 NSData 和 NSError、无返回值"的 block 类型。
4. block 的继承链？
5. `__block_impl` 有哪四个字段？
6. 为什么 block 能放进 `NSArray`？
7. `int a = 10; blk = ^{ NSLog(@"%d", a); }; a = 64; blk();` 打印什么？
8. 为什么 `static` 变量在 block 里能改？
9. 全局变量会被捕获吗？
10. `__block` 变量被包成什么结构体？成员有哪些？
11. `__forwarding` 的作用？
12. block 从栈 copy 到堆时 `__block` 变量会怎样？
13. `__NSGlobalBlock__` 调用 `copy` 会怎样？
14. `__NSStackBlock__` 调用 `copy` 会怎样？
15. ARC 下哪三种情况自动 copy？
16. ARC 下 block 属性用 `strong` 会崩吗？为什么？
17. 循环引用怎么产生？画引用关系。
18. `__weak` 和 `__unsafe_unretained` 的区别？
19. 为什么 `__weak` 之后还要 `__strong`？
20. `__block` 解决循环引用需要哪三个条件？

<details>
<summary>参考答案</summary>

1. `int (^add)(int,int) = ^(int a,int b){ return a+b; }; add(1,2);`
2. `()` = 参数未指定（有警告，可乱传）；`(void)` = 明确无参数。
3. `typedef void (^NetCompletion)(NSData *data, NSError *error);`
4. `__NSXxxBlock__` → `NSBlock` → `NSObject`。
5. `isa`、`Flags`、`Reserved`、`FuncPtr`。
6. block 是 OC 对象，有 `isa`，继承自 `NSBlock`。
7. **10**（值捕获，定义时快照）。
8. static 存在数据段、全程有效，捕获的是**地址**。
9. 不会，直接访问全局符号。
10. `__Block_byref_x_0`：`__isa`、`__forwarding`、`__flags`、`__size`、`x`（对象时多 copy/dispose）。
11. 保证 copy 到堆后，栈和堆访问同一份数据。
12. byref 也复制到堆；栈上原件的 `__forwarding` 改为指向堆副本。
13. 无操作，类型不变。
14. → `__NSMallocBlock__`，引用计数 1。
15. ① 赋强指针 ② 作为返回值 ③ GCD / `usingBlock` 参数。
16. 不会崩。一是 ARC 插入 `objc_retainBlock`，二是 **clang 把 block 属性的 `strong` 改写成 `copy`**（但 `retain` 不会被改写，会警告）。
17. `self` 强引用 block（copy 属性），block 强引用 `self`（捕获）。
18. weak 自动置 nil（安全）；unsafe_unretained 不置 nil（野指针）。
19. 保证 block 执行期间对象存活，避免执行到一半变 nil。
20. ① `__block` 修饰 ② block 内置 nil ③ block 必须被调用。

</details>

---

## 十三、相关笔记

- 详解版：[OC-Block-知识详解.md](file:///Users/lose_sea/Documents/github/note/OC_learning/OC进阶/块(Block)/OC-Block-知识详解.md)
- 原始草稿：[块的详解01.md](file:///Users/lose_sea/Documents/github/note/OC_learning/OC进阶/块(Block)/块的详解01.md)、[块的详解02.md](file:///Users/lose_sea/Documents/github/note/OC_learning/OC进阶/块(Block)/块的详解02.md)
- 相邻主题：[GCD入门.md](file:///Users/lose_sea/Documents/github/note/OC_learning/OC进阶/GCD/GCD入门.md)、[OC-Runtime-知识详解.md](file:///Users/lose_sea/Documents/github/note/OC_learning/OC进阶/Runtime/OC-Runtime-知识详解.md)

## 参考资料

1. [pro648 / Block的用法](https://github.com/pro648/tips/blob/master/sources/Block%E7%9A%84%E7%94%A8%E6%B3%95.md)
2. [pro648 / Block的本质](https://github.com/pro648/tips/blob/master/sources/Block%E7%9A%84%E6%9C%AC%E8%B4%A8.md)
3. [Working with Blocks — Apple](https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/WorkingwithBlocks/WorkingwithBlocks.html)
4. [How blocks are implemented (and the consequences)](https://www.cocoawithlove.com/2009/10/how-blocks-are-implemented-and.html)
