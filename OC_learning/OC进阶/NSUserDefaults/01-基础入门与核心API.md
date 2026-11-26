# 01 - `NSUserDefaults` 基础入门与核心 API

本文面向完全没有接触过 `NSUserDefaults` 的新手，带你彻底掌握它的日常用法。

---

## 一、核心概念：键值对（Key-Value）

`NSUserDefaults` 的使用方式和 `NSDictionary`（字典）非常像，都是通过 **Key（键，必须是 `NSString`）** 来存、取 **Value（值）**。

```
Key（键）                Value（值）
-----------------------------------------
@"isNightMode"    --->   YES
@"userName"       --->   @"小明"
@"fontSize"       --->   16
@"searchHistory"  --->   @[@"天气", @"美食"]
```

---

## 二、第一步：获取 `NSUserDefaults` 对象

`NSUserDefaults` 是一个**单例**（整个 App 运行期间共享同一个默认实例）。使用它之前，先拿到这个单例：

```objc
NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
```

> **提示**：你不需要也不能用 `[[NSUserDefaults alloc] init]` 来获取标准存储区（虽然 `init` 能调用，但官方推荐统一用 `[NSUserDefaults standardUserDefaults]`）。

---

## 三、它支持存储哪些数据类型？

`NSUserDefaults` 底层基于 **Property List（属性列表，简称 plist）**，所以它**只能直接存储以下数据类型**：

### 1. Objective-C 对象类型（6 种）
- `NSString`（字符串）
- `NSNumber`（数字对象，如 `@123`、`@YES`、`@3.14`）
- `NSData`（二进制数据）
- `NSDate`（日期时间）
- `NSArray`（数组 —— **注意：数组里的元素也必须是这 6 种类型之一！**）
- `NSDictionary`（字典 —— **注意：Key 必须是 `NSString`，Value 也必须是这 6 种类型之一！**）

### 2. 系统提供便捷方法支持的类型（5 种）

为了方便开发者，`NSUserDefaults` 还专门封装了几个常用类型的存取方法：
- `BOOL`（布尔值）
- `NSInteger`（整型）
- `float`（单精度浮点型）
- `double`（双精度浮点型）
- `NSURL`（网址/文件 URL，底层会被归档成 `NSData` 存储）

> **重要警告**：不能直接存自定义的 Model 对象（比如 `Person *p`）、`UIImage`、`UIColor` 或 `NSNull`！直接存会导致 App **直接崩溃**。怎么存自定义对象请看下一篇 [02-存储自定义对象与实战场景.md](./02-存储自定义对象与实战场景.md)。

---

## 四、增、删、改、查（CRUD）完整示例

### 1. 存数据（增 / 改）

如果 Key 不存在就是**新增**；如果 Key 已经存在，再次写入就会**覆盖修改**旧值。

```objc
NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

// 1. 存基本数据类型
[defaults setBool:YES forKey:@"isAutoLogin"];
[defaults setInteger:18 forKey:@"userAge"];
[defaults setFloat:1.5f forKey:@"playbackSpeed"];
[defaults setDouble:34.25833 forKey:@"latitude"];

// 2. 存对象类型
[defaults setObject:@"张三" forKey:@"userName"];
[defaults setObject:[NSDate date] forKey:@"lastLoginDate"];
[defaults setObject:@[@"苹果", @"香蕉"] forKey:@"favoriteFruits"];
[defaults setObject:@{@"city": @"西安", @"code": @101} forKey:@"locationInfo"];

// 3. 存 NSURL（注意：要用专门的 setURL:forKey:，不能用 setObject:forKey:）
NSURL *url = [NSURL URLWithString:@"https://www.apple.com"];
[defaults setURL:url forKey:@"homepageURL"];
```

### 2. 取数据（查）

取值时，建议**存的时候用什么类型，取的时候就用对应的专用方法**：

```objc
NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

// 1. 取基本数据类型
BOOL isAutoLogin = [defaults boolForKey:@"isAutoLogin"];           // 不存在时返回 NO
NSInteger age = [defaults integerForKey:@"userAge"];               // 不存在时返回 0
float speed = [defaults floatForKey:@"playbackSpeed"];             // 不存在时返回 0.0f
double lat = [defaults doubleForKey:@"latitude"];                  // 不存在时返回 0.0

// 2. 取对象类型（推荐使用具体类型的读取方法，有类型安全保障）
NSString *name = [defaults stringForKey:@"userName"];              // 不存在或类型不对返回 nil
NSArray *fruits = [defaults arrayForKey:@"favoriteFruits"];        // 不存在或类型不对返回 nil
NSDictionary *info = [defaults dictionaryForKey:@"locationInfo"];  // 不存在或类型不对返回 nil
NSData *data = [defaults dataForKey:@"someData"];                  // 不存在或类型不对返回 nil
NSArray<NSString *> *strArr = [defaults stringArrayForKey:@"favoriteFruits"]; // 确保内部全是 NSString

// 3. 通用取对象方法（NSDate 等没有专用方法，用 objectForKey:）
NSDate *lastLogin = [defaults objectForKey:@"lastLoginDate"];

// 4. 取 NSURL
NSURL *url = [defaults URLForKey:@"homepageURL"];
```

#### 对比：`stringForKey:` vs `objectForKey:` 有什么区别？

| 方法 | 如果存的是 `NSString` | 如果存的是 `NSNumber`（如 `@123`） | 如果存的是 `NSArray` |
| :--- | :--- | :--- | :--- |
| `objectForKey:` | 返回 `NSString` | 返回 `NSNumber` | 返回 `NSArray` |
| `stringForKey:` | 返回 `NSString` | **自动转为 `@"123"`** | 返回 `nil`（更安全！） |

- `objectForKey:` 拿出来的是 `id` 类型，如果别人不小心往同一个 Key 存了错误类型，你拿它当字符串调用方法可能会直接崩溃。
- 专用方法（如 `stringForKey:`、`arrayForKey:`、`dictionaryForKey:`）会帮你做类型检查，类型不匹配直接返回 `nil`，更安全。

### 3. 判断某个 Key 是否存在

**新手常见误区**：用 `if ([defaults boolForKey:@"isNightMode"])` 来判断用户是否设置过夜间模式。
这是错的！因为用户“没设置过”返回 `NO`，用户“手动关闭了”也返回 `NO`。

**正确做法**：用 `objectForKey:` 判断是否为 `nil`：

```objc
if ([defaults objectForKey:@"isNightMode"] == nil) {
    NSLog(@"用户从未设置过夜间模式");
} else {
    BOOL isNight = [defaults boolForKey:@"isNightMode"];
    NSLog(@"用户设置过，当前值为：%@", isNight ? @"开启" : @"关闭");
}
```

### 4. 删数据（删）

#### (1) 删除单个 Key

```objc
NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
[defaults removeObjectForKey:@"userName"];

// 等价写法：传 nil 也会删除该 Key
// [defaults setObject:nil forKey:@"userName"];
```

#### (2) 清空当前 App 的所有 `NSUserDefaults` 数据（如退出登录/重置设置）

```objc
NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bundleID];
```

> **注意**：千万不要直接遍历 `[[defaults dictionaryRepresentation] allKeys]` 去盲目删除，虽然能删掉自己的 Key，但也可能把系统自动记录的一些键也遍历到（虽然系统域的删不掉，但不如 `removePersistentDomainForName:` 干净高效）。

---

## 五、超级实用的隐藏技巧：`registerDefaults:`

假设你的 App 有一个设置项叫“允许推送通知”（`isPushEnabled`），你希望**用户第一次安装打开 App 时，它默认是开启（`YES`）的**。

如果你不做任何处理，直接调用 `[defaults boolForKey:@"isPushEnabled"]`，拿到的是 `NO`！

这时候，`registerDefaults:` 就派上用场了。通常在 `AppDelegate` 的 `application:didFinishLaunchingWithOptions:` 中调用：

```objc
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 注册“出厂默认值”
    NSDictionary *defaultValues = @{
        @"isPushEnabled": @YES,
        @"fontSize": @16,
        @"themeName": @"Light"
    };
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaultValues];
    
    return YES;
}
```

### `registerDefaults:` 的两大神奇特性：

1. **不覆盖已保存的值**：如果用户以前手动把 `isPushEnabled` 改成了 `NO`，再次启动调用 `registerDefaults:` **不会**把它改回 `YES`。它只在“硬盘里找不到这个 Key”时作为兜底值返回。
2. **只存在于内存，不写入硬盘**：所以每次 App 启动时都需要重新注册一遍。

---

## 六、关于 `synchronize`：到底还要不要写？

你在网上查老教程时，几乎每段代码后面都会跟一句：

```objc
[[NSUserDefaults standardUserDefaults] synchronize];
```

### 以前为什么写它？

在很早的 iOS 版本（iOS 7 之前），`NSUserDefaults` 写入数据后不会立刻写进硬盘，而是定期异步保存。如果刚好写完数据 App 就崩溃了，数据可能会丢，所以以前大家习惯手动调用 `synchronize` 强制立刻写盘。

### 现在（iOS 12+）还需要写吗？
**不需要！官方已经明确表示 `synchronize` 是过时且多余的。**
- 在现代 iOS 系统中，数据写入由系统后台守护进程 `cfprefsd` 自动高效管理，即使 App 马上崩溃，写入操作也已经安全提交给系统了。
- 频繁调用 `synchronize` 反而会阻塞当前线程，影响 App 流畅度。
- **结论**：看懂老代码里的 `synchronize` 是干嘛的就行，自己写新代码时**不需要再调用它**。

---

## 七、本节核心要点回顾

1. 通过 `[NSUserDefaults standardUserDefaults]` 获取单例。
2. 只能直接存 plist 支持的类型（字符串、数字、布尔、日期、二进制、数组、字典、URL）。
3. 读取时优先用带类型的方法（`stringForKey:`、`boolForKey:` 等），判断是否存在用 `objectForKey: != nil`。
4. 需要“首次启动默认值为 `YES` 或非 0”时，在启动时用 `registerDefaults:`。
5. 现代 iOS 开发不再需要手动调用 `synchronize`。
