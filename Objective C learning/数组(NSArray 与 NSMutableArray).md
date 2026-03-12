NSArray 代表元素有序、可重复的一个集合，集合中每个元素都有其对应的顺序索引。NSArray 集合允许使用重复元素，可以通过索引来访问指定位置的集合元素。因为 NSArray 集合默认按元素的添加顺序设置元素的索引，第一次添加的元素索引为 0，第二次添加的元素索引为 1……

## NSArray 的功能与用法

NSArray 分别提供了类方法和实例方法来创建 NSArray，两种创建方式需要传入的参数基本相似，只是类方法以 array 开头，而实例方法则以 init 开头。

+ array：创建一个不包含任何元素的空 NSArray。
+ arrayWithContentsOfFile:/initWithContentsOfFile:：读取文件内容来创建 NSArray。
+ 创建只包含指定元素的 NSArray
  + arrayWithObject: 
  + initWithObjects: (**必须用复数 `Objects`** 来传入多个对象（包括单个对象），且**必须用 `nil` 收尾**。)

+ arrayWithObjects:：(**必须用复数 `Objects`** 来传入多个对象（包括单个对象），且**必须用 `nil` 收尾**。) 

> **实例方法没有 `initWithObject:`（单数），只有`initWithObjects:`（复数），哪怕只有 1 个元素也要用复数 +`nil`；**

除此之外，还可使用如下简化语法来创建 NSArray 对象：

`@[元素 1，元素 2，元素 3，……]` 

```objective-c
// 创建
int main(int argc, char* argv[]) {
    @autoreleasepool {
        NSArray* array = [NSArray array];
        NSLog(@"%@", array);
        
        NSArray* array1 = [NSArray arrayWithContentsOfFile: @"myFile.txt"];
        NSLog(@"%@", array1);
        
        NSArray* array2 = [[NSArray alloc] initWithContentsOfFile: @"myFile.txt"];
        NSLog(@"%@", array2);
        
        NSArray* array3 = [NSArray arrayWithObject:@"hello"];
        NSLog(@"%@", array3);
        
        NSArray* array4 = [[NSArray alloc] initWithObjects:@"world", nil];
        NSLog(@"%@", array4);
        
        NSArray* array5 = [NSArray arrayWithObjects: @"xinyan", nil];
        NSLog(@"%@", array5);
        
        NSArray* array6 = @[@"hello", @"xinyan", @"鑫研"];
        NSLog(@"%@", array6);
    }
    
    return 0;
}
```

一旦得到 NSArray 对象，接下来就可以调用它的方法来操作 NSArray 集合。NSArray 集合最大的特点是集合元素有索引，因此，读者查阅 NSArray 类的参考手册时会注意到它的绝大部分方法都与集合元素的索引有关。

参 NSArray 集合的方法大致包含如下几类。

+ 查询集合元素在 NSArray 中的索引。
+ 根据索引值取出 NSArray 集合中的元素。
+ 对集合元素整体调用方法。
+ 对 NSArray 集合进行排序。
+ 取出 NSArray 集合中的部分集合组成新集合。

```objective-c
#import <Foundation/Foundation.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // 创建包含多个字符串的NSArray
        NSArray *array = [NSArray arrayWithObjects:
                          @"疯狂iOS讲义", @"疯狂Android讲义",
                          @"疯狂Ajax讲义", @"疯狂XML讲义",
                          @"疯狂Swift讲义", nil];
        
        // 访问指定索引的元素
        NSLog(@"第一个元素：%@", [array objectAtIndex:0]);
        NSLog(@"索引为1的元素：%@", [array objectAtIndex:1]);
        NSLog(@"最后一个元素：%@", [array lastObject]);
        
        // 从索引2开始，取3个元素组成新集合
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 3)];
        NSArray *arr1 = [array objectsAtIndexes:indexSet];
        NSLog(@"%@", arr1);
        
        // 获取元素在集合中的位置
        NSLog(@"疯狂Android讲义的位置为：%ld",
              [array indexOfObject:@"疯狂Android讲义"]);
        
        // 获取元素在指定范围(2~5)内的位置
        NSLog(@"在2~5范围疯狂Android讲义的位置为：%ld",
              [array indexOfObject:@"疯狂Android讲义" inRange:NSMakeRange(2, 3)]);
        
        // 向数组末尾追加一个元素（原数组不变，返回新数组）
        array = [array arrayByAddingObject:@"孙悟空"];
        
        // 向数组末尾追加另一个数组的所有元素（原数组不变，返回新数组）
        array = [array arrayByAddingObjectsFromArray:
                 [NSArray arrayWithObjects:@"宝玉", @"黛玉", nil]];
        
        // 遍历输出所有元素
        for (int i = 0 ; i < array.count; i++) {
            NSLog(@"%@", [array objectAtIndex:i]);
            // 简化写法：NSLog(@"%@", array[i]);
        }
        
        // 截取索引5开始的3个元素组成新数组
        NSArray *arr2 = [array subarrayWithRange:NSMakeRange(5, 3)];
        
        // 将新数组写入文件（写入当前目录的myFile.txt）
        [arr2 writeToFile:@"myFile.txt" atomically:YES];
    }
    return 0;
}
```

上面程序开始创建了一个 NSArray 对象，创建 NSArray 对象时可直接传入多个元素，其中最后一个 nil 表示 NSArray 元素结束，其实这个 nil 元素并不会存入 NSArray 集合中。 

> 上面程序中还用到了一个 NSIndexSet 集合，这个集合与 NSSet 集合的功能基本相似，区别只是 NSIndexSet 集合主要用于保存索引值，因此，它的集合元素都是 NSUInteger 对象。

程序遍历NSArray集合时, 既可以通过调用NSArray的``objectIndex: index `方法来访问指定索引处的元素, 也可以直接使用类似于普通数组的下标表示法来访问元素, 

```objective-c
[array objectAtIndex: i] 
array[i]; 
```

以上两种方式是等价的. 

### 在NSArray集合后面追加元素

+ 使用`arrayByAddingObject: `方法追加单个元素 
+ 使用 `arrayWithObjects: `方法将另一个数组中所有的元素追加到原数组的后面

不管使用那种方法,**都不会对原来的NSArray对象产生任何修改, (因为NSArray本身是不能修改的), 程序只是返回一个新的NSArray对象.** 

上面 NSArray 中需要大量判断指定元素位于 NSArray 集合中的索引，这就涉及一个标准：NSArray 怎么判断集合是否包含指定元素呢？

标准只有一条：只有某个集合元素与被查找元素通过 isEqual: 方法比较返回 YES 时，才可认为该 NSArray 集合包含该元素，并不需要两个元素是同一个元素。

```objective-c
#import<Foundation/Foundation.h>

@interface FKUser : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* pass;
- (id) initWithName: (NSString*) aName pass: (NSString*) aPass;
- (void) say: (NSString*) content;
@end

@implementation FKUser

- (id)initWithName:(NSString *)name pass:(NSString *)pass {
    if (self = [super init]) {
        self->_name = name;
        self->_pass = pass;
    }
    return self;
}

// say方法实现
- (void)say:(NSString *)content {
    NSLog(@"%@说：%@", self->_name, content);
}

- (BOOL)isEqual:(id)other {
    if (self == other) {
        return YES;
    }
    if ([other class] == FKUser.class) {
        FKUser* target = (FKUser*)other;
        return [self->_name isEqualToString:target->_name]
        && [self->_pass isEqualToString:target->_pass];
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<FKUser[name=%@, pass=%@]>",
            self->_name, self->_pass];
}
@end 
    
    
int main(int argc, char* argv[]) {
    @autoreleasepool {
        // 使用简化语法创建NSArray对象
        NSArray* array = @[
            [[FKUser alloc] initWithName:@"sun" pass:@"123"],
            [[FKUser alloc] initWithName:@"bai" pass:@"345"],
            [[FKUser alloc] initWithName:@"zhu" pass:@"654"],
            [[FKUser alloc] initWithName:@"tang" pass:@"178"],
            [[FKUser alloc] initWithName:@"niu" pass:@"155"]
        ];
        // 查找指定新FKUser对象在集合中的索引
        FKUser* newUser = [[FKUser alloc] initWithName:@"zhu" pass:@"654"];
        NSUInteger pos = [array indexOfObject:newUser];
        NSLog(@"newName 的位置是: %ld", pos);
        NSLog(@"%@", array[0]); 
    }
    return 0;
}
```

## 对集合元素整体调用方法

NSArray 允许对集合中所有的元素或部分元素整体调用方法, 如果只是简单地调用集合元素的方法, 则可以通过NSArray 的如下两种方法来实现. 

+ makeObjectsPerfromSelector: 依次调用NSArray 集合中每个元素的指定方法, 该方法需要传入一个SEL 参数, 用于指定调用哪个方法. 
+ makeObjectsPerfromSelector: withObject: 依次调用NSArray 集合中每个元素的指定方法, 该方法的第一个SEL 参数用于指定调用哪个方法, 第二个参数用于调用集合元素的方法时传入的参数. 

如果希望对集合中的所有元素进行隐式遍历，并使用集合元素来执行某段代码，则可通过 NSArray 的如下方法来完成。

+ enumerateObjectsUsingBlock:：遍历集合中的所有元素，并依次使用元素来执行指定的代码块。
+ enumerateObjectsWithOptions:usingBlock:：遍历集合中的所有元素，并依次使用元素来执行指定的代码块。该方法可以额外传入一个参数，用于控制遍历的选项，如反向遍历。
+ enumerateObjectsAtIndexes:options:usingBlock:：遍历集合中指定范围内的元素，并依次使用元素来执行指定的代码块。该方法可传入一个选项参数，用于控制遍历的选项，如反向遍历。

上面 3 个方法都需要传入一个代码块参数，该代码块必须带 3 个参数，第 1 个参数代表正在遍历的集合元素，第 2 个参数代表正在遍历的集合元素的索引，第 3 个参数就是用于遍历集合元素的代码块。

```objective-c
int main(int argc, char * argv[])
{
    @autoreleasepool
    {
        // 使用简化语法创建NSArray对象
        NSArray* array = @[
            [[FKUser alloc] initWithName:@"sun" pass:@"123"],
            [[FKUser alloc] initWithName:@"bai" pass:@"345"],
            [[FKUser alloc] initWithName:@"zhu" pass:@"654"],
            [[FKUser alloc] initWithName:@"tang" pass:@"178"],
            [[FKUser alloc] initWithName:@"niu" pass:@"155"]
        ];
        
        // 对集合元素整体调用方法
        [array makeObjectsPerformSelector:@selector(say:)
        withObject:@"下午好，NSArray 真强大!"];
        
        NSString* content = @"疯狂iOS讲义";
        
        // 迭代集合内指定范围内的元素，并使用该元素来执行代码块
        [array enumerateObjectsAtIndexes:
            [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2,2)]
            options:NSEnumerationReverse
        // 代码块的第一个参数代表正在遍历的集合元素
        // 代码块的第二个参数代表正在遍历的集合元素的索引
        // 代码块的第三个参数用于控制是否停止遍历，将该参数设置为NO即可停止遍历
        usingBlock: ^(id obj, NSUInteger idx, BOOL *stop)
        {
            NSLog(@"正在处理第%ld个元素：%@", idx, obj);
            [obj say:content];
        }];
    }
}
```

> 不需要反向，就把 `NSEnumerationReverse` 换成 `0` 即可： 
>
> 在 Objective-C 的枚举方法中，**`options` 参数总是传 `0`** 代表使用默认行为。只有当你需要特定附加功能（如倒序）时，才传入对应的枚举常量。
>
> 代码块的第三个参数是一个 **`BOOL \*` 类型的指针**（注意是指针，不是普通 BOOL 值），核心作用是：**让你在遍历过程中手动控制是否「立即停止遍历」**。 
>
> ```objective-c
> #import <Foundation/Foundation.h>
> 
> int main(int argc, const char * argv[]) {
>     @autoreleasepool {
>         NSArray *fruitArray = @[@"苹果", @"香蕉", @"橙子", @"葡萄", @"芒果"];
>         
>         // 遍历数组，找到"橙子"后立即停止
>         [fruitArray enumerateObjectsWithOptions:0 // 正向遍历
>                                      usingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
>             NSLog(@"正在遍历：%@（索引%ld）", obj, idx);
>             
>             // 找到"橙子"后，触发停止开关
>             if ([obj isEqualToString:@"橙子"]) {
>                 *stop = YES; // 关键：修改指针指向的BOOL值为YES
>                 NSLog(@"找到目标，停止遍历！");
>             }
>         }];
>     }
>     return 0;
> }
> ```

NSArray 既可以对集合所有的元素整体调用某个功能, 也可以通过NSIndexSet 来控制只对集合中部分元素迭代调用指定的代码块, 虽然程序只是调用NSArray 的方法, 但程序在执行这些方法时, 底层实际上会使用循环进行迭代处理每个集合元素, 因此, 这些方法都可以称为迭代方法. 

## 对NSArray进行排序 

NSArray 提供了大量的方法对集合元素进行排序，这些排序方法都以 sorted 开头，最常用的排序方法如下。

➤ sortedArrayUsingFunction:context：该方法使用排序函数对集合元素进行排序，该排序函数必须返回 NSOrderedDescending、NSOrderedAscending、NSOrderedSame 这些枚举值，用于代表集合元素的大小。该方法返回一个排序好的新 NSArray 对象。

➤ sortedArrayUsingSelector：该方法使用集合元素自身的方法对集合元素进行排序，集合元素的该方法必须返回 NSOrderedDescending、NSOrderedAscending、NSOrderedSame 这些枚举值，用于代表集合元素的大小。该方法返回一个排序好的新 NSArray 对象。

➤ sortedArrayUsingComparator：该方法使用代码块对集合元素进行排序，该代码块必须返回 NSOrderedDescending、NSOrderedAscending、NSOrderedSame 这些枚举值，用于代表集合元素的大小。该方法返回一个排序好的新 NSArray 对象。

> 实际上，sortedArrayUsingComparator: 方法是 sortedArrayUsingFunction:context: 方法的简化版本。

```objective-c
#import<Foundation/Foundation.h>
// 定义比较函数，根据两个对象的intValue进行比较
NSComparisonResult intSort(id num1, id num2, void *context)
{
    int v1 = [num1 intValue];
    int v2 = [num2 intValue];
    if (v1 < v2)
        return NSOrderedAscending;
    else if (v1 > v2)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}

int main(int argc, char * argv[])
{
    @autoreleasepool{
        // 初始化一个元素为NSString的NSArray对象
        NSArray* array1 = @[@"Objective-C", @"C", @"C++",
                            @"Ruby", @"Perl", @"Swift"];
        // 使用集合元素的compare:方法进行排序
        array1 = [array1 sortedArrayUsingSelector: @selector(compare:)];
        NSLog(@"%@", array1);
        
        // 初始化一个元素为NSNumber的NSArray对象
        NSArray* array2 = @[ [NSNumber numberWithInt:20],
                             [NSNumber numberWithInt:12],
                             [NSNumber numberWithInt:-8],
                             [NSNumber numberWithInt:50],
                             [NSNumber numberWithInt:19] ];
        // 使用intSort函数进行排序
        array2 = [array2 sortedArrayUsingFunction:intSort
                                          context:nil];
        NSLog(@"%@", array2);
        
        // 使用代码块对集合元素进行排序
        NSArray* array3 = [array2 sortedArrayUsingComparator: ^(id obj1, id obj2) {
           // 该代码块就是根据集合元素的 intValue 进行比较
           if ([obj1 intValue] > [obj2 intValue])
           {
               return NSOrderedDescending;
           }
           if ([obj1 intValue] < [obj2 intValue])
           {
               return NSOrderedAscending;
           }
           return NSOrderedSame;
       }];
        NSLog(@"%@", array3);
    }
}
```

> `NSOrderedDescending`、`NSOrderedAscending`、`NSOrderedSame` 是 Objective-C 中定义的 **枚举常量**（属于 `NSComparisonResult` 枚举类型），核心作用是**表示两个对象的比较结果**，是集合排序、对象比较的核心判断依据。 
>
> | `NSOrderedAscending`  | 升序（上升） | a < b | 前一个对象 < 后一个对象 |
> | --------------------- | ------------ | ----- | ----------------------- |
> | `NSOrderedDescending` | 降序（下降） | a > b | 前一个对象 > 后一个对象 |
> | `NSOrderedSame`       | 相同         | a = b | 前一个对象 = 后一个对象 |

> 在数组排序的代码块中，返回这三个常量就是告诉系统「当前两个元素该怎么排」：   
>
> ```objective-c
> NSArray *array = @[@20, @12, @-8, @50, @19];
> // 按「升序」排序（从小到大）
> NSArray *sortedArray = [array sortedArrayUsingComparator:^(id obj1, id obj2) {
>     int v1 = [obj1 intValue];
>     int v2 = [obj2 intValue];
>     
>     if (v1 < v2) {
>         // 前小后大 → 升序，系统会把 obj1 放在 obj2 前面
>         return NSOrderedAscending;
>     } else if (v1 > v2) {
>         // 前大后小 → 降序，系统会把 obj1 放在 obj2 后面
>         return NSOrderedDescending;
>     } else {
>         // 相等，位置不变
>         return NSOrderedSame;
>     }
> }];
> NSLog(@"升序结果：%@", sortedArray); // 输出 (-8, 12, 19, 20, 50)
> 
> // 如果想改成「降序」排序，只需调换返回值即可
> NSArray *descArray = [array sortedArrayUsingComparator:^(id obj1, id obj2) {
>     int v1 = [obj1 intValue];
>     int v2 = [obj2 intValue];
>     
>     if (v1 < v2) {
>         return NSOrderedDescending; // 前小后大 → 强制返回降序，把 obj1 放后面
>     } else if (v1 > v2) {
>         return NSOrderedAscending; // 前大后小 → 强制返回升序，把 obj1 放前面
>     } else {
>         return NSOrderedSame;
>     }
> }];
> NSLog(@"降序结果：%@", descArray); // 输出 (50, 20, 19, 12, -8)
> ```
>
> 

集合元素本身可比较大小，而且直接利用集合元素比较大小的方法进行排序的方式也被称为自然排序；对于通过比较函数或代码块来指定自定义比较规则的方式，则被称为定制排序。

## 使用枚举器遍历NSArray 集合元素 

对于NSArray 对象, 除了可以根据集合元素的索引来遍历集合元素之外, 还可以调用NSArray 对象的如下两个方法来返回枚举器. 

- `objectEnumerator: `返回NSArray集合的顺序枚举器
- `reverseObjectEnumerator: `返回NSArray 集合的逆序枚举器 

两个方法都返回一个NSEnumerator: 枚举器, 该枚举只包含如下两种方法. 

- allObjeecs: 获取被枚举集合中的所有元素 
- nextObject: 获取被集合中的下一个元素 

借助 nextObject 方法即可对集合元素进行枚举：程序可采用循环不断获取 nextObject 的返回值，直到该方法的返回值为 nil 结束循环。

```objective-c
#import <Foundation/Foundation.h>

int main(int argc , char * argv[])
{
    @autoreleasepool
    {
        NSArray* array = @[@"Objective-C", @"C", @"C++",
                            @"Ruby", @"Perl", @"Swift"];
        // 获取NSArray的顺序枚举器
        NSEnumerator* en = [array objectEnumerator];
        id object;
        while(object = [en nextObject])
        {
            NSLog(@"%@", object);
        }
        NSLog(@"------下面逆序遍历------");
        // 获取 NSArray 的逆序枚举器
        en = [array reverseObjectEnumerator];
        while(object = [en nextObject])
        {
            NSLog(@"%@", object);
        }
    }
}
```

## 快速枚举 

Objective-C 还提供了一种快速枚举的方法来遍历集合 (包括 NSArray、NSSet、NSDictionary 等集合)，使用快速枚举遍历集合元素时，无须获得集合的长度，也无须根据索引来访问集合元素，即可快速枚举自动遍历集合的每个元素。

快速枚举的语法格式如下：

plaintext







```objc
for(type variableName in collection) {
    // variableName 自动访问每个元素…
}
```

> 在上面的语法格式中，type 是集合元素的类型，variableName 是一个形参名，快速枚举将自动将集合元素依次赋给该变量。

**如果使用快速枚举来遍历 NSDictionary 对象，那么快速枚举中循环计数器将依次代表 NSDictionary 的每个 key 的值。**

> 类似于C++中的范围for

```objective-c
#import <Foundation/Foundation.h>

int main(int argc, char * argv[])
{
    @autoreleasepool{
        NSArray* array = @[@"Objective-C", @"C", @"C++",
                                    @"Ruby", @"Perl", @"Swift"];
        for(id object in array) {
            NSLog(@"%@", object);
        }
    }
}
```

##  可变数组 (NSMutableArray) 

NSArray 代表集合元素不可变的集合，一旦 NSArray 创建成功，程序就不能向集合中添加新的元素，不能删除集合中已有的元素，也不能替换集合元素。

> NSArray 只是保存对象的指针，因此，NSArray 只保证这些指针变量中的地址不能改变，但指针变量所指向的对象是可以改变的。

NSArray 有一个子类：NSMutableArray，因此它可作为 NSArray 使用。与此同时，它代表的是一个集合元素可变的集合，因此，程序可以向集合中添加新的元素，可以删除集合中已有的元素，也可以替换集合元素。

NSMutableArray 代表集合元素可变的集合，而 NSMutableArray 底层采用传统数组来容纳集合元素，因此，创建 NSMutableArray 时可通过参数指定底层数组的初始容量。

NSMutableArray 主要新增了如下方法：

+ 添加集合元素的方法：这类方法以 add 开头。
+ 删除集合元素的方法：这类方法以 remove 开头。
+ 替换集合元素的方法：这类方法以 replace 开头。
+ 对集合本身排序的方法：这类方法以 sort 开头。

> NSMutableArray 同样提供了 sortUsingSelector:、sortUsingComparator:、sortUsingFunction:context: 这三个方法，这三个方法与前面介绍的 NSArray 提供的三个排序方法的用法基本相似，区别是 NSArray 的排序方法是返回一个新的、排序好的 NSArray 对象，而 NSMutableArray 的排序方法则对集合本身排序。

```objective-c
#import <Foundation/Foundation.h>

// 定义一个函数，该函数用于把 NSArray 集合转换为字符串
NSString* NSCollectionToString(NSArray* array)
{
    NSMutableString* result = [NSMutableString stringWithString:@"["];
    for(id obj in array)
    {
        [result appendString:[obj description]];
        [result appendString:@", "];
    }
    NSUInteger len = [result length]; // 获取字符串长度
    // 去掉字符串最后的两个字符
    [result deleteCharactersInRange:NSMakeRange(len - 2, 2)];
    [result appendString:@"]"];
    return result;
}


int main(int argc , char * argv[])
{
    @autoreleasepool
    {
        // 读取前面写入磁盘的文件，用文件内容来初始化NSMutableArray集合
        NSMutableArray* array = [NSMutableArray arrayWithContentsOfFile:@"myFile.txt"];
        [array addObject:@"疯狂iOS讲义"]; // 向集合最后添加一个元素
        NSLog(@"最后追加一个元素后：%@", NSCollectionToString(array));
        
        // 使用NSArray向集合尾部添加多个元素
        [array addObjectsFromArray:[NSArray arrayWithObjects:@"张飞", @"关羽", nil]];
        NSLog(@"最后追加两个元素后：%@", NSCollectionToString(array));
        
        // 向集合的指定位置插入一个元素
        [array insertObject:@"疯狂Ajax讲义" atIndex:2];
        NSLog(@"在索引为2处插入一个元素后：%@", NSCollectionToString(array));
        
        // 使用NSArray向集合指定位置插入多个元素
        [array insertObjects:[NSArray arrayWithObjects:@"武松", @"林冲", nil]
                    atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(3, 2)]];
        NSLog(@"插入多个元素后：%@", NSCollectionToString(array));
        
        [array removeLastObject]; // 删除集合最后一个元素
        NSLog(@"删除最后一个元素后：%@", NSCollectionToString(array));
        
        [array removeObjectAtIndex:5]; // 删除集合中指定索引处的元素
        NSLog(@"删除索引为5的元素后：%@", NSCollectionToString(array));
        
        [array removeObjectsInRange:NSMakeRange(2, 3)]; // 删除索引为2-4处的元素
        NSLog(@"删除索引为2-4处的元素后：%@", NSCollectionToString(array));
        
        // 替换索引为2处的元素
        [array replaceObjectAtIndex:2 withObject:@"疯狂Android讲义"];
        NSLog(@"替换索引为2处的元素后：%@", NSCollectionToString(array));
    }
}

```

