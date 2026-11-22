# Objective-C 内存管理知识点总结

> 速查版 · 配合 [OC-内存管理-知识详解.md](OC-内存管理-知识详解.md) 使用
>
> 主线：**分配 → 持有 → 释放 → 为什么会漏 → 怎么查**

---

## 目录

- [一、一句话理解](#一一句话理解)
- [二、内存布局](#二内存布局)
- [三、引用计数](#三引用计数)
- [四、MRC 四法则](#四mrc-四法则)
- [五、ARC](#五arc)
- [六、属性关键字](#六属性关键字)
- [七、copy](#七copy)
- [八、Block](#八block)
- [九、weak](#九weak)
- [十、autoreleasepool](#十autoreleasepool)
- [十一、dealloc](#十一dealloc)
- [十二、循环引用](#十二循环引用)
- [十三、泄漏检测与优化](#十三泄漏检测与优化)
- [十四、CF 桥接](#十四cf-桥接)
- [十五、面试速答](#十五面试速答)
- [十六、易错点清单](#十六易错点清单)
- [十七、ARC 方法族（命名约定）](#十七arc-方法族命名约定)
- [十八、现场排查速查表](#十八现场排查速查表)
- [十九、记忆卡](#十九记忆卡)

---

## 一、一句话理解

> **通过引用计数管理堆上对象的生命周期：谁要就 +1，谁不要就 -1，归零就销毁。**

需要管理的只有**堆上的 OC 对象**（`alloc` / `new` / `copy` / `mutableCopy` 出来的）。栈变量由编译器管。

```
alloc ──▶ 计数 1 ──▶ retain +1 ──▶ release -1 ──▶ 0 ──▶ dealloc ──▶ free
```

---

## 二、内存布局

```
高地址
┌──────────────┐
│   内核空间    │
├──────────────┤
│  栈 Stack ↓   │  局部变量、参数；线程私有；自动管理
├──────────────┤
│     ...      │
├──────────────┤
│  堆 Heap ↑    │  OC 对象；ARC/手动管理；进程共享
├──────────────┤
│  BSS（未初始化全局）│
├──────────────┤
│  Data（已初始化全局）│
├──────────────┤
│  常量区 @"..." │
├──────────────┤
│  代码段 __TEXT │
└──────────────┘
低地址
```

| 分区 | 内容 | 生命周期 |
| --- | --- | --- |
| 栈 | 局部变量、参数、返回地址 | 函数调用期间 |
| 堆 | OC 对象、malloc 内存 | 引用计数归零 |
| BSS | `static int a;` | 进程 |
| Data | `static int a = 1;` | 进程 |
| 常量区 | `@"hello"`、字符串常量 | 进程（永不释放） |
| 代码段 | 机器指令 | 进程 |

**关键区分**：

```objc
NSString *s = @"Tom";
// 变量 s（指针）在栈
// 对象 @"Tom" 在常量区

NSString *t = [NSString stringWithFormat:@"Tom"];
// t 在栈，对象在堆
```

### 三个 size

| API | 含义 | NSObject |
| --- | --- | --- |
| `sizeof(obj)` | 指针大小 | 8 |
| `class_getInstanceSize` | 实例结构体大小（8 字节对齐） | 8 |
| `malloc_size` | 堆块大小（16 字节对齐） | 16 |

### 对象内存布局

```objc
@interface Person : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) int age;
@end
// 0x00 isa (8)
// 0x08 _name (8)
// 0x10 _age (4)
// 0x14 padding (4)
// 总计 24 = class_getInstanceSize
// malloc_size = 32
```

### Tagged Pointer（小对象不在堆上）

```objc
NSNumber *n = @(42);       // 0xb0000000000002a2 之类，值编码在指针里
NSString *s = @"hi";       // 常量字符串（不在堆）
```

| 结论 | 说明 |
| --- | --- |
| 不分配堆内存 | 没有 malloc / free |
| 不走引用计数 | `retain` / `release` 空操作，`retainCount` 无意义 |
| 不是真对象 | 但能响应方法（runtime 特判） |
| 判断方式 | `(uintptr_t)obj & (1UL << 63)` 非零 |

```objc
static inline BOOL isTaggedPointer(id obj) {
    return ((uintptr_t)obj & (1UL << 63)) != 0;
}
```

**易错**：Tagged Pointer 不能 `CFRetain`，`weak` 也不会记录它。

---

## 三、引用计数

### 计数器存在哪

**不是**一个简单的 `int` 字段，而是两层：

| 层 | 位置 | 容量 |
| --- | --- | --- |
| 快路径 | `isa.extra_rc`（19 位） | 约 52 万 |
| 慢路径 | `SideTable.refcnts`（哈希表） | 无限 |

```c
union isa_t {
    uintptr_t bits;
    struct {
        uintptr_t nonpointer        : 1;
        uintptr_t has_assoc         : 1;
        uintptr_t has_cxx_dtor      : 1;
        uintptr_t shiftcls          : 33;
        uintptr_t magic             : 6;
        uintptr_t weakly_referenced : 1;
        uintptr_t unused            : 1;
        uintptr_t has_sidetable_rc  : 1;
        uintptr_t extra_rc          : 19;   // 存 count - 1
    };
};
```

- `extra_rc` 存 `count - 1`，因为新对象计数为 1 时 `extra_rc = 0`，省一次赋值；
- 溢出时 `has_sidetable_rc = 1`，计数转移到 `SideTable`；
- `SideTable` 还存 `weak_table`，一个对象只需定位一次。

### retain / release

| 方法 | 语义 |
| --- | --- |
| `retain` | 计数 +1，返回自身 |
| `release` | 计数 -1，归零调 dealloc |
| `autorelease` | 加入池，将来 -1 |
| `retainCount` | 当前计数（**不可靠**） |

**`retainCount` 为什么不可靠**：

1. 常量字符串 / `NSNumber` 小整数不走计数；
2. Tagged Pointer 没有计数；
3. autorelease 延迟释放；
4. 系统框架可能额外 retain；
5. ARC 可能优化掉 retain/release。

### 线程安全

`retain` / `release` 本身原子，但"读指针 + retain"不是原子操作：

```objc
// 线程 A
id obj = _shared;   // ① 读
[obj retain];        // ② 若 B 在 ①② 之间 release，这里野指针

// 线程 B
[_shared release];
_shared = nil;
```

`atomic` 属性只保证单次存取原子，**不保证组合操作**。

---

## 四、MRC 四法则

> 1. **自己生成的对象，自己持有**（`alloc` / `new` / `copy` / `mutableCopy`）
> 2. **非自己生成的对象，自己也能持有**（`retain`）
> 3. **自己持有的对象不再需要时，自己释放**（`release`）
> 4. **非自己持有的对象，不能释放**

```objc
id a = [[NSObject alloc] init];   // 持有
id b = [NSMutableArray array];    // 不持有
[b retain];                        // 持有
[a release];
[b release];
```

### setter 写法

```objc
// 安全写法（自赋值安全）
- (void)setName:(NSString *)name {
    if (_name != name) {
        [_name release];
        _name = [name retain];
    }
}

// 或调换顺序（先 retain 再 release）
- (void)setName:(NSString *)name {
    [name retain];
    [_name release];
    _name = name;
}

// copy setter
- (void)setName:(NSString *)name {
    if (_name != name) {
        [_name release];
        _name = [name copy];
    }
}
```

### dealloc

```objc
- (void)dealloc {
    [_name release];
    [_items release];
    [super dealloc];   // 必须最后
}
```

---

## 五、ARC

> **ARC 不是 GC，是编译器在编译期自动插入 `retain` / `release` / `autorelease`。**

| 维度 | ARC | GC |
| --- | --- | --- |
| 时机 | 编译期插代码 | 运行期扫描 |
| 停顿 | 无 | 有 |
| 循环引用 | 无法解决 | 可解决 |
| 可预测性 | 高 | 低 |

### 插入规则

| 场景 | 插入 |
| --- | --- |
| strong 赋值 | `objc_storeStrong`（retain 新 + release 旧） |
| weak 赋值 | `objc_storeWeak` |
| 局部变量出作用域 | `objc_release` |
| 返回值 | `objc_autoreleaseReturnValue` |
| 接收返回值 | `objc_retainAutoreleasedReturnValue` |

### 四个所有权修饰符

| 修饰符 | 计数 | 自动置 nil | 用途 |
| --- | --- | --- | --- |
| `__strong` | +1 | — | 一级指针默认 |
| `__weak` | 不 +1 | ✅ | delegate、Block |
| `__unsafe_unretained` | 不 +1 | ❌ | 极特殊场景 |
| `__autoreleasing` | 延迟 -1 | — | **二级指针默认**、out-param |

### 核心规则：二级指针默认 `__autoreleasing`

> **ARC 下，所有没有显式指定所有权修饰符的 Objective-C 对象二级指针，其指向物默认是 `__autoreleasing`。**

```objc
NSError **err;       // ≡ NSError * __autoreleasing *err
NSString **str;      // ≡ NSString * __autoreleasing *str
id *obj;             // ≡ id __autoreleasing *obj
```

两级要看清楚：

```objc
NSError * __autoreleasing * p;
//        └──────┬──────┘  └┬┘
//       指向物的修饰符      外层指针（指针本身不参与计数）
```

| 声明 | 展开 | 被调用方写入 |
| --- | --- | --- |
| `NSError **` | `NSError * __autoreleasing *` | **+0**（autoreleased） |
| `NSError * __autoreleasing *` | 同上 | **+0** |
| `NSError * __strong *` | 指向 strong 指针 | **+1**（所有权转移） |
| `id __weak *` | 指向 weak 指针 | 弱引用 |

### 为什么默认是 `__autoreleasing`

1. **兼容 MRC 约定**：out-param 本来返回 autoreleased 对象；
2. **所有权契约最简单**：被调用方写 +0，你不用管释放；
3. **允许 `&strongVar` 隐式转换**：编译器自动插临时变量 + 写回。

### 调用时的隐式转换

```objc
NSError *error = nil;          // __strong
[self doSomething:&error];     // &error 是 __strong *，类型不匹配
```

编译器生成的伪代码：

```objc
NSError *error = nil;

NSError * __autoreleasing tmp = error;   // ① 建临时变量
BOOL ok = [self doSomething:&tmp];        // ② 传临时变量地址
error = tmp;                              // ③ 写回，strong 接管
```

**这就是「二级指针默认 `__autoreleasing`」能安全工作的原因**：方法内部改的是 `tmp`，返回后 ARC 把值写回 `error`，`error` 作为强引用持有它，池 drain 也不会变野指针。

### 举例：标准 out-param 写法

```objc
// 声明（不用写 __autoreleasing）
- (BOOL)loadConfig:(NSDictionary **)outConfig
             error:(NSError **)outError;

// 实现
- (BOOL)loadConfig:(NSDictionary **)outConfig
             error:(NSError **)outError {
    if (出错了) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"Net" code:-1 userInfo:nil];  // +0
        }
        return NO;
    }
    if (outConfig) {
        *outConfig = @{@"timeout": @30};   // +0
    }
    return YES;
}

// 调用
NSDictionary *config = nil;    // strong
NSError *error = nil;          // strong
BOOL ok = [self loadConfig:&config error:&error];
if (!ok) {
    NSLog(@"%@", error);
    return;
}
NSLog(@"%@", config);          // 已被写回，安全
```

**三条纪律**：

1. 进入方法先判 `outXxx != NULL`（调用方可能不关心）；
2. 失败时不要写 `*outConfig`，成功时不要写 `*outError`；
3. 赋给 `*outXxx` 的必须是 **+0** 对象（便捷构造器 / 字面量 / 常量）。

### 坑：把 `alloc` 的对象赋给默认二级指针

```objc
// ❌ 泄漏：alloc 是 +1，但契约要求 +0
- (BOOL)load:(NSString **)outStr {
    *outStr = [[NSString alloc] initWithFormat:@"x"];
    return YES;
}

// ✅ 方案 1：用便捷构造器（+0）
- (BOOL)load:(NSString **)outStr {
    *outStr = [NSString stringWithFormat:@"x"];
    return YES;
}

// ✅ 方案 2：显式声明为 __strong *，契约改为 +1
- (BOOL)load:(NSString * __strong *)outStr {
    *outStr = [[NSString alloc] initWithFormat:@"x"];
    return YES;
}
```

### 坑：`__autoreleasing` 变量长期保存

```objc
// 先定义一个遵守 +0 契约的 load:
- (BOOL)load:(NSString **)outStr {
    if (outStr) *outStr = [NSString stringWithFormat:@"x"];   // +0
    return YES;
}

// 调用方如果把结果存在 __autoreleasing 变量里
NSString * __autoreleasing s = nil;
[self load:&s];
@autoreleasepool { /* 这里 s 还能用 */ }
// 当前池 drain 之后 s 就是野指针

// ✅ 立即转 strong
NSString * __autoreleasing tmp = nil;
[self load:&tmp];
NSString *keep = tmp;   // strong 接管，池 drain 也不影响
```

### 什么时候显式写

| 场景 | 写法 |
| --- | --- |
| 普通 out-param | `NSError **`（默认即可） |
| 强调语义 / 与协议对齐 | `NSError * __autoreleasing *` |
| 所有权转移 | `NSString * __strong *` |
| 弱引用 out-param | `id __weak *` |

**日常业务代码不要写 `__autoreleasing`**，让默认规则生效；只有需要强调所有权时才显式标注。

### ARC 禁止

- `[obj retain]` / `[obj release]` / `[obj autorelease]`
- `[super dealloc]`
- `NSAutoreleasePool` 的 `release`
- OC 对象指针直接当 `void *` 传（需 `__bridge`）
- C 结构体里放强引用对象

### RV 优化

```objc
- (Person *)create {
    return [[Person alloc] init];
}
// 编译为 return objc_autoreleaseReturnValue(p)
// 调用方 objc_retainAutoreleasedReturnValue(...)
// 检测到配对 → 跳过 autorelease
```

---

## 六、属性关键字

| 关键字 | 计数 | 对象销毁时自动置 nil | 用途 |
| --- | --- | --- | --- |
| `assign` | 不 +1 | 否（野指针） | 基本类型 |
| `strong` | +1 | —（强引用下对象不会先销毁） | 一般对象 |
| `weak` | 不 +1 | ✅ | delegate、Block 捕获 |
| `copy` | +1（副本） | —（同 strong） | 字符串、容器、Block |
| `unsafe_unretained` | 不 +1 | 否（野指针） | 兼容老代码 |
| `retain` | 同 strong | — | MRC 遗留 |

### 推荐组合

| 类型 | 写法 |
| --- | --- |
| 基本类型 | `nonatomic, assign` |
| 对象 | `nonatomic, strong` |
| 字符串 / 容器 | `nonatomic, copy` |
| Block | `nonatomic, copy` |
| delegate | `nonatomic, weak` |
| 对外只读 | `nonatomic, readonly, copy` |

### atomic vs nonatomic

| 维度 | atomic | nonatomic |
| --- | --- | --- |
| 加锁 | 是 | 否 |
| 性能 | 慢 | 快 |
| 线程安全 | 仅单次存取 | 不保证 |
| 默认 | 是 | — |
| 实践 | 少用 | 几乎全部 |

`atomic` **不能**保证：

```objc
if (self.count > 0) {
    self.count = self.count - 1;   // 读-改-写，三步非原子
}
```

### 属性 vs ivar

```objc
_name = @"Tom";        // 绕过 setter，不 copy
self.name = @"Tom";    // 走 setter，执行 copy
```

---

## 七、copy

| 消息 | 结果 |
| --- | --- |
| `[immutable copy]` | 返回自身 |
| `[immutable mutableCopy]` | 新可变对象 |
| `[mutable copy]` | 新不可变对象 |
| `[mutable mutableCopy]` | 新可变对象 |

### 浅拷贝 vs 深拷贝

```objc
NSMutableArray *mArr = [@[@1, @2] mutableCopy];
NSArray *arr = [mArr copy];
// arr 和 mArr 不同对象
// arr[0] 和 mArr[0] 是同一个对象（浅拷贝）
```

### 深拷贝三种方式

```objc
// 1. 一层
NSArray *deep1 = [[NSArray alloc] initWithArray:original copyItems:YES];

// 2. 归档（递归，需 NSCoding）
NSData *data = [NSKeyedArchiver archivedDataWithRootObject:original
                                     requiringSecureCoding:NO error:nil];
NSArray *deep2 = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSArray class]
                                                   fromData:data error:nil];

// 3. 手动递归
- (NSArray *)deepCopy:(NSArray *)arr {
    NSMutableArray *result = [NSMutableArray array];
    for (id obj in arr) {
        if ([obj isKindOfClass:[NSArray class]]) {
            [result addObject:[self deepCopy:obj]];
        } else if ([obj conformsToProtocol:@protocol(NSCopying)]) {
            [result addObject:[obj copy]];
        } else {
            [result addObject:obj];
        }
    }
    return [result copy];
}
```

### NSCopying

```objc
- (id)copyWithZone:(NSZone *)zone {
    Person *copy = [[[self class] allocWithZone:zone] init];
    copy->_name = [_name copy];
    copy->_tags = [[NSMutableArray alloc] initWithArray:_tags copyItems:YES];
    return copy;
}
```

### 为什么 NSString 用 copy

```objc
NSMutableString *mStr = [NSMutableString stringWithString:@"Tom"];
self.name = mStr;            // strong: 同一对象
[mStr appendString:@" Lee"];
NSLog(@"%@", self.name);     // "Tom Lee" —— 被意外修改

// copy: _name 是不可变副本，不受影响
```

---

## 八、Block

### 三种类型

| 类型 | isa | 位置 | 捕获 |
| --- | --- | --- | --- |
| 全局 Block | `_NSConcreteGlobalBlock` | 全局区 | 不捕获 |
| 栈 Block | `_NSConcreteStackBlock` | 栈 | 捕获 |
| 堆 Block | `_NSConcreteMallocBlock` | 堆 | 捕获 |

### 捕获规则

```objc
int a = 10;
void (^b)(void) = ^{ NSLog(@"%d", a); };  // 值拷贝
a = 20;
b();   // 输出 10

__block int c = 10;
void (^b2)(void) = ^{ c = 20; };           // 可修改
b2();  // c = 20
```

**访问 ivar 会隐式捕获 self**：

```objc
self.block = ^{
    _count++;   // 隐式 self，循环引用
};
```

### 为什么用 copy

栈 Block 随栈帧销毁，保存到属性/容器/异步回调前必须 copy 到堆。

```objc
@property (nonatomic, copy) void (^completion)(BOOL);
```

### 循环引用

```objc
// ❌
self.block = ^{ [self doSomething]; };

// ✅
__weak typeof(self) weakSelf = self;
self.block = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;
    [strongSelf doSomething];
};
```

### `__block` 在 ARC 下不能打破循环

```objc
// ❌ 仍然循环引用
__block typeof(self) blockSelf = self;
self.block = ^{ [blockSelf doSomething]; };
```

原因：ARC 下 Block copy 到堆时会对 `__block` 对象变量 retain。

---

## 九、weak

> **不增加计数；对象销毁时自动置 nil。**

### 原理

```
对象地址 ──▶ [ &wp1, &wp2, &wp3, ... ]   （weak_table）
```

| 阶段 | 函数 | 动作 |
| --- | --- | --- |
| 注册 | `objc_initWeak` | 加锁，把 `&wp` 加入对象的 weak 表 |
| 赋值 | `objc_storeWeak` | 从旧对象移除，加入新对象 |
| 读取 | `objc_loadWeakRetained` | 加锁读 + retain，保证使用期间有效 |
| 销毁 | `clearDeallocating` | 遍历 weak 表，`*referrer = nil` |

### 对比

| 特性 | weak | unsafe_unretained | assign |
| --- | --- | --- | --- |
| 计数 +1 | 否 | 否 | 否 |
| 自动置 nil | ✅ | ❌ | ❌ |
| 开销 | 哈希 + 锁 | 无 | 无 |
| 安全 | 安全 | 野指针 | 野指针 |

### 多线程注意

```objc
__weak Person *wp = self.person;
Person *strongP = wp;   // 立即强引用
if (strongP) { [strongP doSomething]; }
```

### 弱引用容器

普通集合会强引用元素，想"只观察"就用弱引用容器：

| 容器 | 对应 | 用途 |
| --- | --- | --- |
| `NSHashTable` | `NSSet` | 多 delegate / 观察者 |
| `NSMapTable` | `NSDictionary` | 缓存、关联表 |
| `NSPointerArray` | `NSArray` | 有序弱引用列表 |

```objc
NSHashTable *table = [NSHashTable weakObjectsHashTable];
[table addObject:obj];    // 不增加计数，obj 释放后自动移除

NSMapTable *map = [NSMapTable strongToWeakObjectsMapTable];
[map setObject:value forKey:key];

NSPointerArray *array = [NSPointerArray weakObjectsPointerArray];
[array addPointer:(__bridge void *)obj];
```

**坑**：如果外部没有强引用，对象入容器后立刻释放，容器里就空了。

---

## 十、autoreleasepool

### 哪些对象会进入 autoreleasepool？

遵循 **Cocoa 命名约定**：
- **方法名以 `alloc`、`new`、`copy`、`mutableCopy` 开头**：调用者持有（+1），**不进入** autoreleasepool。
- **其他方法名（如 `stringWithFormat:`、`array`、`date` 等便利构造方法/类工厂方法）**：返回具有 autorelease 语义的对象，**进入** autoreleasepool。
- **显式指定 `__autoreleasing` 修饰符**：强制入池。

| 情况 | 是否进入 autoreleasepool | 说明 |
| --- | :---: | --- |
| `[[Class alloc] init]` | **否** | 调用者持有，不进入池 |
| `[Class new]` | **否** | 调用者持有，不进入池 |
| `[array copy]` / `[array mutableCopy]` | **否** | 调用者持有，不进入池 |
| `[NSString stringWithFormat:]` 等便利构造方法 | **是** | 返回 autorelease 对象，进池 |
| `[NSArray array]`、`[NSDate date]` 等类方法 | **是** | 方法名不以 alloc/new/copy/init 开头 |
| `__autoreleasing` 修饰的对象 | **是** | 显式指定加入当前池 |

### 核心案例对比：进池 vs 不进池

#### 1. 不进入 autoreleasepool

```objc
@autoreleasepool {
    NSString *str = [[NSString alloc] initWithFormat:@"Hello"];
    NSLog(@"%@", str);
}
```

**执行过程**：
1. `alloc init` 创建对象（引用计数 1）。
2. `str` 建立强引用。
3. 离开作用域，ARC 释放 `str` 的强引用。
4. 如果没有其他引用，对象**立即释放**（无需等待池排空）。

#### 2. 进入 autoreleasepool

```objc
@autoreleasepool {
    NSString *str = [NSString stringWithFormat:@"Hello"];
    NSLog(@"%@", str);
}
```

**执行过程**：
1. `stringWithFormat:` 返回具有 autorelease 语义的对象（已注册进当前池）。
2. `str` 建立强引用。
3. 离开作用域，ARC 释放 `str` 的强引用。
4. 自动释放池排空（pool drain），执行之前安排的自动释放操作（向对象发 `release`）。
5. 如果没有其他引用，对象此时才完成释放。

#### 3. 真正的区别：强引用提前消失（`str = nil`）

```objc
// 对比 A：进池对象提前置 nil
@autoreleasepool {
    NSString *str = [NSString stringWithFormat:@"Hello"];
    str = nil;
    NSLog(@"继续执行");
    // str = nil 释放了强引用，但对象还登记在池中尚未执行 release！
    // 因此对象在此期间依然存活，直到右大括号池排空才真正释放。
}

// 对比 B：不进池对象提前置 nil
@autoreleasepool {
    NSString *str = [[NSString alloc] initWithFormat:@"Hello"];
    str = nil;
    NSLog(@"继续执行");
    // str = nil 这一刻，对象引用计数直接归 0 立即释放，完全不依赖自动释放池！
}
```

*(注：验证 dealloc 建议用自定义对象 `Person` 避开 64 位 Tagged Pointer 优化)*

### 结构

```c
class AutoreleasePoolPage {
    id *next;
    pthread_t thread;
    AutoreleasePoolPage *parent, *child;
    // 后面是对象指针数组，每页约 504 个
};
```

- 每线程独立，双向链表；
- `push` 写哨兵，`pop` 释放到哨兵为止。

### 编译展开

```objc
@autoreleasepool {
    // ...
}
// ↓
void *pool = objc_autoreleasePoolPush();
// ...
objc_autoreleasePoolPop(pool);
```

### 什么时候手动加

| 场景 | 原因 |
| --- | --- |
| 大循环 | 避免峰值 |
| 子线程 | 默认无池 |
| 命令行工具 | 无 RunLoop |
| 图片处理 | 及时释放中间对象 |

```objc
for (int i = 0; i < 100000; i++) {
    @autoreleasepool {
        NSString *s = [NSString stringWithFormat:@"%d", i];
        // 处理
    }
}
```

### 主线程

RunLoop 每次迭代自动 push/pop，所以主线程 autorelease 对象通常在**本轮事件结束**时释放。

---

## 十一、dealloc

### 调用链

```
objc_release
  └─ 计数 0
       └─ dealloc
            └─ _objc_rootDealloc
                 └─ objc_destructInstance
                      ├─ C++ 析构
                      ├─ 移除关联对象
                      └─ clearDeallocating（weak 置 nil）
                 └─ free
```

### 该做 / 不该做

| 该做 | 不该做 |
| --- | --- |
| 释放 CF 对象、`free`、`close` | `[super dealloc]`（ARC） |
| 移除通知、KVO、Timer | 开异步任务 |
| `__bridge_retained` 配平 | 访问可能已释放的对象 |
| 关闭文件 / socket | 调用可能触发副作用的方法 |

```objc
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    CFRelease(_cf);
}
```

---

## 十二、循环引用

### 常见场景

| 场景 | 修复 |
| --- | --- |
| delegate | `weak` |
| Block 捕获 self | `__weak` + `__strong` |
| NSTimer | block + weak，或 proxy |
| CADisplayLink | weak proxy |
| 通知 block | `__weak` |
| 单例持有 VC | 及时置 nil |
| 父子对象 | 子 `weak` 指向父 |
| WKWebView handler | weak proxy |

### 打破方式

```objc
// 标准写法
__weak typeof(self) weakSelf = self;
self.block = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;
    // 使用 strongSelf
};
```

### 检测

```objc
// 1. dealloc 打印
- (void)dealloc { NSLog(@"%@ dealloc", [self class]); }

// 2. weak 探测
__weak typeof(self) weakSelf = self;
dispatch_after(..., ^{
    NSLog(@"%@", weakSelf ? @"未释放" : @"已释放");
});
```

工具：Memory Graph（⌘⇧M）、Instruments Leaks。

### Timer / CADisplayLink 的标准解法

```objc
// NSTimer 强引用 target，直接传 self 会导致 dealloc 永不调用
@interface WeakProxy : NSProxy
@property (nonatomic, weak, readonly) id target;
@end

@implementation WeakProxy
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [_target methodSignatureForSelector:sel];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    if ([_target respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:_target];
    }
}
@end

self.timer = [NSTimer scheduledTimerWithTimeInterval:1
                                             target:[WeakProxy proxyWithTarget:self]
                                           selector:@selector(tick)
                                           userInfo:nil
                                            repeats:YES];
```

**为什么用 `NSProxy`**：它是专门的代理基类，消息转发路径更短，且不会像 `NSObject` 子类那样意外响应 `description` 等方法。

### 关联对象也可能循环

```objc
// ❌ self 关联 helper，helper 强引用 self
objc_setAssociatedObject(self, @selector(helper), helper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
helper.owner = self;
```

关联对象在 `dealloc` 时由 `_object_remove_assocations` 自动释放，但如果它反过来强引用 self，就形成环。

---

## 十三、泄漏检测与优化

### 工具

| 工具 | 用途 |
| --- | --- |
| Memory Graph | 可视化引用链，紫色感叹号标泄漏 |
| Instruments Leaks | 检测泄漏对象 |
| Instruments Allocations | 按类看分配/持久对象 |
| Zombie Objects | 检测向已释放对象发消息 |
| Address Sanitizer | 越界、use-after-free |
| MallocStackLogging | 记录 malloc 调用栈 |

### 优化策略

| 策略 | 说明 |
| --- | --- |
| 懒加载 | 用时才创建 |
| 图片降采样 | 按目标尺寸解码 |
| 复用 | Cell 复用 |
| 分页 | 大列表分页 |
| `NSCache` | 自动清理，替代字典 |
| `@autoreleasepool` | 循环中及时释放 |
| 避免循环引用 | weak |
| 及时释放 | `viewDidDisappear` 清理 |

### 图片内存公式

```
内存 = 宽 × 高 × 4 字节（RGBA8888）
```

4000×3000 的图解码后约 **48MB**，与文件大小无关。

```objc
// 降采样
CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
NSDictionary *opts = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel)
};
CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
UIImage *img = [UIImage imageWithCGImage:thumb];
CGImageRelease(thumb);
CFRelease(src);
```

### 几个"内存只涨不降"的元凶

| 现象 | 元凶 |
| --- | --- |
| 阶梯上涨、从不下降 | 单例里的 `NSMutableArray` 只增不减 |
| 打开 H5 后不降 | `WKWebView` handler / `WKProcessPool` |
| 反复进出页面不降 | Block / Timer / 通知 / 单例持有 VC |
| 滚动列表暴涨 | 图片未降采样、Cell 重复加子视图 |
| 后台任务后暴涨 | 子线程缺 `@autoreleasepool` |
| CF 对象持续增长 | `Create` / `Copy` 未 `CFRelease` |

---

## 十四、CF 桥接

| 转换 | 方向 | 谁释放 | 计数 |
| --- | --- | --- | --- |
| `__bridge` | 双向 | 原持有者 | 无变化 |
| `__bridge_retained` | OC → CF | CF 侧 | +1 |
| `__bridge_transfer` | CF → OC | ARC | 转移 |

```objc
// 只转换
CFStringRef cf = (__bridge CFStringRef)nsStr;

// OC → CF，转移所有权
CFStringRef cf = (__bridge_retained CFStringRef)nsStr;
CFRelease(cf);

// CF → OC，ARC 接管
NSString *ns = (__bridge_transfer NSString *)cf;
```

CF 创建规则：`Create` / `Copy` 归你，`Get` 不归你。

---

## 十五、面试速答

| 问题 | 一句话答案 |
| --- | --- |
| OC 内存管理机制 | 引用计数，持有 +1，释放 -1，归零 dealloc |
| MRC 四法则 | 谁创建谁释放，谁 retain 谁 release |
| ARC 是什么 | 编译器在编译期插入 retain/release |
| ARC 与 GC 区别 | ARC 无停顿、可预测、不能解决循环引用 |
| strong / weak / assign / copy | 强引用 / 弱引用自动置 nil / 基本类型 / 副本 |
| 为什么 NSString 用 copy | 防止 NSMutableString 外部修改影响属性 |
| weak 原理 | 全局 weak 表存指针地址，dealloc 时置 nil |
| autorelease 原理 | Page 双向链表 + 哨兵，pop 时批量 release |
| Block 为什么 copy | 栈 Block 随栈帧销毁，copy 到堆延长生命周期 |
| `__block` 作用 | 允许 Block 内修改外部变量；ARC 下不能破循环 |
| retainCount 可靠吗 | 不可靠，常量对象/Tagged Pointer/autorelease 都误导 |
| atomic 线程安全吗 | 不，只保证单次存取，组合操作仍需锁 |
| dealloc 做什么 | 释放 C 资源、移除通知/KVO/Timer |
| 如何检测循环引用 | Memory Graph、Instruments、dealloc 打印 |
| class_getInstanceSize vs malloc_size | 8 字节对齐 vs 16 字节对齐 |
| Tagged Pointer | 小值编码进指针，不分配堆、不走计数 |
| 深拷贝怎么做 | copyItems / 归档 / 手动递归 / copyWithZone |
| CF 三种桥接 | `__bridge` / `__bridge_retained` / `__bridge_transfer` |
| 二级指针默认修饰符 | `__autoreleasing`（指向物），一级指针默认 `__strong` |
| `NSError **` 展开是什么 | `NSError * __autoreleasing *`，写入 +0 对象 |
| 传 `&strongVar` 给 out-param 会发生什么 | ARC 建临时 `__autoreleasing` 变量，调用后写回 |
| `__strong *` 和默认二级指针的区别 | 前者要求被调用方写入 +1，后者 +0 |
| `__autoreleasing` 能修饰属性吗 | 不能，属性只能用 assign/strong/weak/copy |

---

## 十六、易错点清单

| # | 易错点 | 正确理解 |
| --- | --- | --- |
| 1 | 对象都在堆上 | 本体在堆，指针在栈，常量字符串在常量区 |
| 2 | `sizeof` 是对象大小 | 是指针大小 |
| 3 | 引用计数是个 int 字段 | 在 `isa.extra_rc`，溢出进 `SideTable` |
| 4 | `retainCount` 能判断泄漏 | 不可靠 |
| 5 | `release` 后立即消失 | 计数归零才 dealloc |
| 6 | `atomic` = 线程安全 | 只保证单次存取 |
| 7 | `assign` 可修饰对象 | 会野指针 |
| 8 | `copy` = 深拷贝 | 浅拷贝，容器只复制一层 |
| 9 | `copy` 属性初始化也 copy | 直接赋值 ivar 会绕过 |
| 10 | ARC = GC | 编译期插代码 |
| 11 | ARC 能解决循环引用 | 不能 |
| 12 | `__block` 能破循环 | ARC 下不能 |
| 13 | Block 捕获变量当前值 | 捕获定义时的值 |
| 14 | 访问 ivar 不捕获 self | 会隐式捕获 |
| 15 | weak 零成本 | 有哈希和锁 |
| 16 | weak 读取总是安全 | 多线程需 strong 化 |
| 17 | 子线程有自动释放池 | 默认没有 |
| 18 | dealloc 中可随意调用方法 | 可能触发副作用 |
| 19 | 泄漏一定崩溃 | 可能只是缓慢增长 |
| 20 | 图片文件小就不占内存 | 解码后按像素算 |
| 21 | `NSError **` 就是普通二级指针 | 展开是 `NSError * __autoreleasing *` |
| 22 | 所有指针都默认 `__strong` | 一级 `strong`，二级指向物默认 `__autoreleasing` |
| 23 | `__autoreleasing` 变量能长期保存 | 池 drain 后失效，需 strong 接管 |
| 24 | `__autoreleasing` 可用于属性 | 不能，属性只有 assign/strong/weak/copy |
| 25 | 显式 `__strong *` 更安全 | 反而要求写入 +1 对象，写错就过度释放 |

---

## 十七、ARC 方法族（命名约定）

> **`alloc` / `new` / `copy` / `mutableCopy` / `init` 开头 = 调用方拥有（+1）；其他 = 不拥有（+0）。**

| 方法前缀 | 归属 | ARC 行为 |
| --- | --- | --- |
| `alloc` | +1 | 调用方负责 release |
| `new` | +1 | 同上 |
| `copy` | +1 | 同上 |
| `mutableCopy` | +1 | 同上 |
| `init` | +1 | 同上 |
| 其他 | +0 | 通常 autorelease |

### 名字取错的后果

```objc
// ❌ 以 new 开头，但返回 +0 对象
- (NSData *)newRequestData {
    return [self cachedData];
}
// 调用方：ARC 以为 +1，作用域结束 release → 过度释放崩溃
```

```objc
// ❌ 不以 copy 开头，但返回 +1 对象
- (Person *)duplicatePerson {
    return [[Person alloc] init];
}
// 调用方：ARC 以为 +0，不 release → 泄漏
```

### 标注例外

```objc
- (Person *)duplicatePerson NS_RETURNS_RETAINED;    // 这是 +1
- (Person *)newPerson NS_RETURNS_NOT_RETAINED;      // 这是 +0
- (void)getBuffer:(char **)buf NS_RETURNS_INNER_POINTER;
```

### 自定义 init 规范

```objc
- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _name = [name copy];
    }
    return self;   // 失败时返回 nil
}
```

- 返回类型用 `instancetype`，不用 `id`；
- 失败返回 `nil`；
- 不要在 init 里调用多态方法。

### 精确生命周期

```objc
// 默认：最后一次使用后可能就被 release
Person *p = [[Person alloc] init];
[p doSomething];
// 这里 p 可能已经被释放

// 需要保证作用域内存活：
__attribute__((objc_precise_lifetime)) Person *p = [[Person alloc] init];
// 或
NS_VALID_UNTIL_END_OF_SCOPE Person *p = ...;
```

---

## 十八、现场排查速查表

### 按现象查

| 现象 | 首选工具 | 最可能的原因 |
| --- | --- | --- |
| `dealloc` 不打印 | Memory Graph | Block / Timer / 通知 / 单例 / delegate |
| `EXC_BAD_ACCESS` | Zombie + ASan | 野指针、已释放对象、`assign` 修饰对象 |
| 内存阶梯上涨 | Allocations | 单例集合只增不减、缓存无上限 |
| 内存锯齿上涨 | Allocations | 缺 `@autoreleasepool`、图片未降采样 |
| 滚动列表暴涨 | Allocations + Time Profiler | 图片原图解码、Cell 重复加子视图 |
| CF 对象增长 | Leaks + Analyze | `Create`/`Copy` 未 `CFRelease` |
| 崩溃在 `removeObserver` | 断点 + 日志 | KVO 重复移除 / keyPath 不一致 |
| 后台任务后暴涨 | 代码审查 | 子线程缺 `@autoreleasepool` |
| 打开 H5 后不降 | Memory Report | WKWebView handler 强引用 VC |
| 内存警告后崩溃 | 日志 | 清理了正在使用的数据 |

### 按工具查

| 工具 | 入口 | 能解决什么 |
| --- | --- | --- |
| Memory Graph | ⌘⇧M | 引用链、循环引用 |
| Instruments Leaks | ⌘I → Leaks | 不可达对象泄漏 |
| Instruments Allocations | ⌘I → Allocations | 分配量、持久对象、调用栈 |
| Zombie Objects | Scheme → Diagnostics | 向已释放对象发消息 |
| Address Sanitizer | Scheme → Diagnostics | 越界、use-after-free、double-free |
| MallocStackLogging | 环境变量 | malloc 调用栈 |
| Analyze | ⌘⇧B | CF 配对、静态可查问题 |
| MetricKit | 代码集成 | 线上 OOM、卡顿、崩溃 |

### 一段可直接用的泄漏探测代码

```objc
// 在 viewDidDisappear 或 pop 后调用
- (void)checkDeallocAfterDelay:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakSelf) {
            NSLog(@"⚠️ %@ 未释放，检查 Block / Timer / 通知 / 单例",
                  NSStringFromClass([weakSelf class]));
        } else {
            NSLog(@"✅ 已释放");
        }
    });
}
```

---

## 十九、记忆卡

| 概念 | 一句话 |
| --- | --- |
| 引用计数 | 有人要 +1，没人要 -1，归零就死 |
| `alloc` | 堆上开房，isa 入住 |
| `retain` | 我也要它 |
| `release` | 我不要了 |
| `autorelease` | 我稍后不要 |
| `dealloc` | 遗言 + 退房 |
| ARC | 编译器替你记账 |
| `strong` | 我抱着它 |
| `weak` | 我看着它，它没了我自动放手 |
| `assign` | 我只记个地址 |
| `copy` | 我复制一份自己的 |
| 循环引用 | 两个人互相抱着，谁也走不了 |
| weak 表 | 登记所有"看着它"的人 |
| 自动释放池 | 延迟处理的垃圾桶 |
| 内存泄漏 | 人走了，房还占着 |
| Tagged Pointer | 小值不住房，住指针里 |
| `__autoreleasing` | 二级指针的默认住客：先住池里，再搬回家 |
| `NSError **` | 不是"指针的指针"，是"指向池中指针的指针" |
