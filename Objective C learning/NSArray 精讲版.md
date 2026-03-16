# NSArray

## 创建

### 类方法 (array开头)

#### array: 创建一个不包含任何元素的空NSArray

`NSArray* arr = [NSArray array];`

#### 单个元素

`NSArray* arr = [NSArray arrayWithObject: @"hello"]; `

#### 多个元素 (nil结尾)

`NSArray* arr = [NSArray arrayWithObjects: @"hello", @"xinyan", **nil**];`

#### 从另一个数组创建

```objective-c
int main(int argc, char* argv[]) {
    NSArray* arr = [NSArray arrayWithObjects: @"hello", @"xinyan", nil];
    NSArray* arr1 = [NSArray arrayWithArray: arr];
    NSLog(@"%@", arr1);
    return 0;
}
```

输出: 

```objective-c
(
    hello,
    xinyan
)
```

### 字面量创建

`NSArray* arr = @[@"hello", @"xinyan", @"Jack"];`

### 实例方法 (alloc + init 开头) 

#### 空数组

`[[NSArray alloc] array]; `

#### 多个元素 (以 nil 结尾) 

`NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"Jack"]; ` 

#### 从另一个数组创建

```objective-c
int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", nil];
    NSArray* arr1 = [[NSArray alloc] initWithArray: arr];
    NSLog(@"%@", arr1);
    return 0;
}
```

**注意: 实例方法没有以 `initWithObject`,以单个元素创建也要用`initWithObejcts: `, 结束要写 nil** 

## 取出数组中的元素

```objective-c
int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"world", @"iOS", nil];
    // 取出第一个元素
    NSLog(@"%@", [arr objectAtIndex: 0]);
    
    // 取出索引为 2 的元素
    NSLog(@"%@", [arr objectAtIndex: 2]);
    
    // 取出最后一个元素
    NSLog(@"%@", [arr lastObject]);
    return 0;
}
```

程序遍历NSArray集合时, 既可以通过调用NSArray的``objectIndex: index `方法来访问指定索引处的元素, 也可以直接使用类似于普通数组的下标表示法来访问元素,  

```objective-c
[arr objectAtIndex: i]; 
arr[i]; 
```

以上两种方式是等价的

## 从索引 m 开始, 与后面 n 个元素组成新集合

```objc
int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"world", @"iOS", nil];
    NSIndexSet* indexSet = [NSIndexSet indexSetWithIndexesInRange :NSMakeRange(1, 3)];
    NSArray* arr1 = [arr objectsAtIndexes: indexSet];
    NSLog(@"%@", arr1);
    return 0;
}
```

输出: 

```objc
(
    xinyan,
    world,
    iOS
)
```

> 上面程序中用到了一个 NSIndexSet 集合，这个集合与 NSSet 集合的功能基本相似，区别只是 NSIndexSet 集合主要用于保存索引值，因此，它的集合元素都是 NSUInteger 对象。

## 获取元素在集合中的位置

```objective-c
int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"world", @"iOS", nil];
    NSLog(@"xinyan 在集合中的位置为: %ld", [arr indexOfObject: @"xinyan"]);
    return 0;
}
```

输出 :

```objective-c
1
```



> 如果要查找的元素不在集合中, 就会返回一个超大的数值, 这个超大的数字就是 **`NSNotFound`**，它的定义是：
>
> `#define NSNotFound NSIntegerMax  // 即 9223372036854775807（64位系统）` 
>
> 查找元素时，**必须判断是否等于 `NSNotFound`**，否则会用一个错误的索引去访问数组导致崩溃	

## 获取元素在指定范围的位置 

```objective-c
int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"world", @"iOS", @"C++", @"swift", nil];
    NSLog(@"xinyan 在集合(1, 3)的位置为: %ld", [arr indexOfObject: @"xinyan" inRange: NSMakeRange(1, 3)]);
    return 0;
}
```

输出: 

```objective-c
1
```

如果在索引 (m, n) 的范围没有要查找的元素, 就会返回`NSNotFound (9223372036854775807)` 如果找到, 就返回该元素在数组中的索引

## 向一个数组末尾追加一个元素 (原数组不变, 返回新数组)

`arr = [arr arrayByAddingObject: @"swift"]; ` 

## 向一个数组末尾追加另外一个数组的所有元素

```objective-c
int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"world", @"iOS", nil];
    NSArray* arr1 = [NSArray arrayWithObjects: @"swift", @"python", nil];
    arr = [arr arrayByAddingObjectsFromArray: arr1];
    NSLog(@"%@", arr);
    return 0;
}
```

## 截取索引 m 开始 n 个字符组成新的数组

`arr = [arr subArrayWithRange: NSMakeRange(2 ,3)]; `

# 对集合整体调用方法

`[makeObjectsPerformSelector: @selector(方法名)]; `  

依次掉用NSArray中的每一个元素的指定方法, 需要传入一个SEL 参数指定调用哪个方法

`[makeObjectsPerformSelector: @selector(方法名) withObject: 参数]` 

依次掉用NSArray中的每一个元素的指定方法, 需要传入一个SEL 参数指定调用哪个方法, 第二个参数用于传入调用集合的方法是传入的参数

```objective-c
@interface NSString (fk)
- (void) say: (NSString* )str;
@end

@implementation NSString (fk)
- (void) say: (NSString*) str {
    NSLog(@"%@ say %@", self, str);
}
@end

int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"world", @"iOS", nil];
    NSLog(@"%ld", [arr count]);
    // 对集合整体调用方法
    [arr makeObjectsPerformSelector: @selector(say:) withObject: @"hello"];
    return 0;
}
```

输出: 

> ```objective-c
> (
>     hello,
>     xinyan,
>     world,
>     iOS,
>     swift,
>     python
> )
> 6
> hello say hello
> xinyan say hello
> world say hello
> iOS say hello
> swift say hello
> python say hello
> ```

如果希望对集合中的所有元素进行隐式遍历，并使用集合元素来执行某段代码，则可通过 NSArray 的如下方法来完成。

+ enumerateObjectsUsingBlock:：遍历集合中的所有元素，并依次使用元素来执行指定的代码块。
+ enumerateObjectsWithOptions:usingBlock:：遍历集合中的所有元素，并依次使用元素来执行指定的代码块。该方法可以额外传入一个参数，用于控制遍历的选项，如反向遍历。
+ enumerateObjectsAtIndexes:options:usingBlock:：遍历集合中指定范围内的元素，并依次使用元素来执行指定的代码块。该方法可传入一个选项参数，用于控制遍历的选项，如反向遍历。 

上面 3 个方法都需要传入一个代码块参数，该代码块必须带 3 个参数，第 1 个参数代表正在遍历的集合元素，第 2 个参数代表正在遍历的集合元素的索引，第 3 个参数就是用于遍历集合元素的代码块。

```objective-c
@interface NSString (fk)
- (void) say: (NSString* )str;
@end

@implementation NSString (fk)
- (void) say: (NSString*) str {
    NSLog(@"%@ say %@", self, str);
}
@end

int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"world", @"iOS", nil];
    NSArray* arr1 = [NSArray arrayWithObjects: @"swift", @"python", nil];
    arr = [arr arrayByAddingObjectsFromArray: arr1];
    NSLog(@"%@", arr);
    // 对集合整体调用方法
    [arr enumerateObjectsAtIndexes: [NSIndexSet indexSetWithIndexesInRange: NSMakeRange(2, 2)] options: NSEnumerationReverse usingBlock: ^(id obj, NSUInteger idx, BOOL* stop) {
        NSLog(@"正在处理第 %ld 个元素 %@", idx, obj);
    }];
    return 0;
}
```

输出: 

```objective-c
(
    hello,
    xinyan,
    world,
    iOS,
    swift,
    python
)
正在处理第 3 个元素 iOS
正在处理第 2 个元素 world
```

> 不需要反向，就把 `NSEnumerationReverse` 换成 `0` 即可： 
>
> 在 Objective-C 的枚举方法中，**`options` 参数总是传 `0`** 代表使用默认行为。只有当你需要特定附加功能（如倒序）时，才传入对应的枚举常量。
>
> 代码块的第三个参数是一个 **`BOOL` 类型的指针**（注意是指针，不是普通 BOOL 值），核心作用是：**让你在遍历过程中手动控制是否「立即停止遍历」**。 
>
> ```objective-c
> #import <Foundation/Foundation.h>
> 
> int main(int argc, const char * argv[]) {
>  @autoreleasepool {
>      NSArray *fruitArray = @[@"苹果", @"香蕉", @"橙子", @"葡萄", @"芒果"];
> 
>      // 遍历数组，找到"橙子"后立即停止
>      [fruitArray enumerateObjectsWithOptions:0 // 正向遍历
>                                   usingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
>          NSLog(@"正在遍历：%@（索引%ld）", obj, idx);
> 
>          // 找到"橙子"后，触发停止开关
>          if ([obj isEqualToString:@"橙子"]) {
>              *stop = YES; // 关键：修改指针指向的BOOL值为YES
>              NSLog(@"找到目标，停止遍历！");
>          }
>      }];
>  }
>  return 0;
> }
> ```

## 对NSArray进行排序

```objc
// 定义比较函数
NSComparisonResult intSort(id num1, id num2, void* conrtext) {
    int v1 = [num1 intValue];
    int v2 = [num2 intValue];
    if (v1 > v2) {
        return NSOrderedAscending;
    }
    if (v1 < v2) {
        return NSOrderedDescending;
    }
    return NSOrderedSame;
}
int main(int argc, char* argv[]) {
    NSArray* arr = @[[NSNumber numberWithInt: 3], [NSNumber numberWithInt: 6], [NSNumber numberWithInt: 5]];
    NSArray* arr1 = [arr sortedArrayUsingFunction: intSort context: nil];
    NSLog(@"%@", arr);
    NSLog(@"%@", arr1);
    return 0;
}
```

输出: 

```objc
(
    3,
    6,
    5
)
(
    6,
    5,
    3
)
```

> 返回 NSOrderedAscending  → num1 排在 num2 **前面**
> 返回 NSOrderedDescending → num1 排在 num2 **后面**

# 使用枚举器遍历NSArray集合 

除了根据集合的索引类遍历集合之外, 还可以调用NSArray对象的如下两种功能方法来返回枚举器 

+ `objectEnumerator: `返回NSArray集合的顺序枚举器 

+ `reverseObjectEnumerator: `返回 NSArray 集合的逆序枚举器

  上面两个方法都返回一个NSEnumerator 枚举器, 该枚举器只包含如下两种方法

  + `allObject: `获取被枚举集合中的所有集合 
  + `nextObject: `获取被枚举集合中的下一个元素 

可以借助nextObject 方法即可对集合元素进行枚举, 程序可采用循环不断获取nextObject 方法的返回值, 直到该方法的返回值为nil 结束循环

```objc
int main(int argc, char* argv[]) {
    NSArray* arr = @[[NSNumber numberWithInt: 3], [NSNumber numberWithInt: 6], [NSNumber numberWithInt: 5]];
    NSLog(@"%@", arr);
    arr = [arr arrayByAddingObjectsFromArray: [NSArray arrayWithObjects: [NSNumber numberWithInt: 4], [NSNumber numberWithInt: 9], [NSNumber numberWithInt: 5], nil]];
    NSEnumerator* en = [arr objectEnumerator];
    id object;
    while (object = [en nextObject]) {
        NSLog(@"%@", object);
    }
    NSLog(@"%@", object);
    NSLog(@"开始逆序便利");
    en = [arr reverseObjectEnumerator];
    while (object = [en nextObject]) {
        NSLog(@"%@", object);
    }
    return 0;
}
```

# 快速枚举

Objective-C还提供了一种快速枚举的方法来遍历集合 使用快速枚举遍历集合元素时, 无需获得集合的长度, 也无须根据索引来访问集合元素, 即可快速枚举自动遍历集合的每个元素 

```objc
int main(int argc, char* argv[]) {
    NSArray* arr = @[[NSNumber numberWithInt: 3], [NSNumber numberWithInt: 6], [NSNumber numberWithInt: 5]];
    arr = [arr arrayByAddingObjectsFromArray: [NSArray arrayWithObjects: [NSNumber numberWithInt: 4], [NSNumber numberWithInt: 9], [NSNumber numberWithInt: 5], nil]];
    NSLog(@"%@", arr);
    for (id object in arr) {
        NSLog(@"%@", object);
    }
    return 0;
}
```

# mutableArray 

## 添加一个元素

`[array addObject: @"hello"]; `

## 添加多个元素

`[array addObjectsFromArray: [NSArray arrayWithObjects: @"hello", @"world", nil]]; `

## 向指定位置插入一个元素

`[array insertObject: @"hello" atIndex: 2]; `

## 向指定位置插入多个元素

`[array insertObject: [NSArray arrayWithObject: @"hello", @"xinya", niil] atIndexes: [NSIndexSet indexSetWithIndexInrange: NSMakeRange(3, 3)]]; ` 

**NSMakeRange (m, n) 中第一个参数是插入位置的索引, 第二个参数是插入元素的个数, 如果参数和实际插入元素的数量不符, 就会报错**

## 删除最后一个元素

`[array removeLastsObject]; ` 

