# 字典 (NSDistionary 与 NSMutableDictionary)

NSDictionary 用于保存具有映射关系的数据，因此，NSDictionary 集合里保存着两组值，一组值用于保存 NSDictionary 里的 key，另一组值用于保存 NSDictionary 里的 value。注意，key 和 value 都可以是任何指针类型的数据，NSDictionary 的 key 不允许重复。

key 和 value 之间存在单向一对一关系，即通过指定的 key，总能找到唯一的、确定的 value。从 NSDictionary 中取出数据时，只要给出指定的 key，就可以取出对应的 value。

## NSDictionary 的功能与用法

NSDictionary 集合由多个key-value 对组成, 

NSDictionary 集合由多个 key-value 对组成，因此创建 NSDictionary 时需要同时指定多个 key-value 对。NSDictionary 分别提供了类方法和实例方法来创建 NSDictionary，两种创建方式需要传入的参数基本相似，只是类方法以 dictionary 开头，而实例方法则以 init 开头。下面是创建 NSDictionary 对象的几类常见的方法。

➤ dictionary：创建一个不包含任何 key-value 对的 NSDictionary。

➤ dictionaryWithContentsOfFile:/initWithContentsOfFile:：读取指定文件的内容，使用指定的文件内容来初始化 NSDictionary。该文件通常是由 NSDictionary 输出生成的。

➤ dictionaryWithDictionary:/initWithDictionary:：使用已有的 NSDictionary 包含的 key-value 对来初始化 NSDictionary 对象。

➤ dictionaryWithObject:forKey:：使用单个 key-value 对来创建 NSDictionary 对象。

➤ dictionaryWithObjects:forKeys:/initWithObjects:forKeys:：使用两个 NSArray 分别指定 key、value 集合，可以创建包含多个 key-value 对的 NSDictionary。

➤ dictionaryWithObjectsAndKeys:/initWithObjectsAndKeys:：调用该方法时，需要按 value1,key1,value2,key2,…,nil 的格式传入多个 key-value 对。

除此之外，还可使用如下简化语法来创建 NSDictionary 对象：

@{key1: value1, key2: value2, ….}

一旦得到 NSDictionary 对象，接下来就可以通过方法来访问该集合所包含的 key 或 value。NSDictionary 提供了如下常用的方法。

➤ count：该方法返回该 NSDictionary 所包含的 key-value 对的数量。

➤ allKeys：该方法返回该 NSDictionary 所包含的全部 key。

➤ allKeysForObject:：该方法返回指定 value 对应的全部 key。

➤ allValues：该方法返回该 NSDictionary 所包含的全部 value。

➤ objectForKey:：该方法获取该 NSDictionary 中指定 key 对应的 value。

➤ objectForKeyedSubscript:：通过该方法的支持，允许 NSDictionary 通过下标法来获取指定 key 对应的 value。

➤ valueForKey:：该方法获取该 NSDictionary 中指定 key 对应的 value。

➤ keyEnumerator：该方法返回用于遍历该 NSDictionary 所有 key 的 NSEnumerator 对象。

➤ objectEnumerator：该方法返回用于遍历该 NSDictionary 所有 value 的 NSEnumerator 对象。

➤ enumerateKeysAndObjectsUsingBlock:：使用指定的代码块来迭代执行该集合中所有的 key-value 对。

➤ enumerateKeysAndObjectsWithOptions:usingBlock:：使用指定的代码块来迭代执行该集合中所有的 key-value 对。该方法可以传入一个额外的 NSEnumerationOptions 参数。

➤ writeToFile:atomically:：将该 NSDictionary 对象的数据写入指定文件。

程序可以根据key来获取NSDictionary 中对应的value, 通过key获取value 有如下两种语法: 

1. 直接调用NSDictionary 中对应 的objectForKey; 方法即可根据key 来获取对应的value ` [dictionary objectForKey: key]; ` 
2. 直接使用下标法根据key 来获取对应的value `dictionary[key]; ` 

两种代码的功能是一样的

## 对 NSDictionary 的key 排序

NSDictionary 还提供了方法对NSDictionary 的所有key执行排序, 这些方法执行完成后将返回排序号好的所有key 组成的 NSArray ,  

+ keysSortedByValueUsingSelector: 根据 NSDictionary 的所有 value 的指定方法的返回值对 key 排序；调用 value 的该方法必须返回 NSOrderedAscending、NSOrderedDescending、NSOrderedSame 这三个枚举值之一。
+ keysSortedByValueUsingComparator: 该方法使用指定的代码块来遍历 key-value 对，并根据执行结果（执行结果必须返回 NSOrderedAscending、NSOrderedDescending、NSOrderedSame 这三个枚举值之一）对 NSDictionary 的所有 key 进行排序。
+ keysSortedByValueWithOptions:usingComparator: 与前一个方法的功能相似，只是该方法可以传入一个额外的 NSEnumerationOptions 参数。 

```objective-c
@interface NSDictionary (print)
- (void) print;
@end

@implementation NSDictionary (print)
- (void) print {
    NSMutableString* result = [NSMutableString stringWithString: @"["];
    for (id key in self) {
        [result appendString: [key description]];
        [result appendString: @" = "];
        // [result appendString: [self [key] description]];
        [result appendString: [self objectForKey: key]];
        [result appendString: @", "];
    }
    NSUInteger len = [result length];
    // 去掉字符串的最后两个字符
    [result deleteCharactersInRange: NSMakeRange(len - 2, 2)];
    [result appendString: @"]"];
    NSLog (@"%@", result);
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        // 使用简化的语法创建NSDictionary 对象
        NSDictionary* dict = @{@"one": @"Objective-C", @"two": @"Ruby", @"three": @"Python", @"four": @"Perl"};
         // 打印dict 集合中所有的元素
        [dict print];
        // 获取所有直接调用value的compare: 方法对所有的key排序
        // 返回排好序的所有key组成的 NSArray
        NSArray* keyArr1 = [dict keysSortedByValueUsingSelector: @selector(compare:)];
        NSLog(@"%@", keyArr1);
        [dict print];
        NSArray* keyArr2 = [dict keysSortedByValueUsingComparator: ^(id value1, id value2) {
            // 定义比较规则
            if ([value1 length] > [value2 length]) {
                return NSOrderedDescending;
            }
            if ([value1 length] < [value2 length]) {
                return NSOrderedAscending;
            }
            return NSOrderedSame;
        }];
        NSLog(@"%@", keyArr2);
        [dict print];
    }
    return 0;
}
```

输出; 

```objective-c
[four = Perl, one = Objective-C, three = Python, two = Ruby]
(
    one,
    four,
    three,
    two
)
[four = Perl, one = Objective-C, three = Python, two = Ruby]
(
    four,
    two,
    three,
    one
)
[four = Perl, one = Objective-C, three = Python, two = Ruby]
```

## 对NSDictionary 的 key 进行过滤

- NSDictionary 还提供了方法对 NSDictionary 的所有 key 执行过滤，这些方法执行完成后将返回满足过滤条件的 key 组成的 **NSSet**。NSDictionary 提供了如下过滤方法。

  + `keysOfEntriesPassingTest: `：使用代码块迭代处理 NSDictionary 的每个 key-value 对，对 NSDictionary 的 key-value 对进行过滤，该代码块必须返回 BOOL 类型的值，只有当该代码块返回 YES 时，该 key 才会被保留下来；该代码块可以接受 3 个参数，其中第一个参数代表正在迭代处理的 key，第二个参数代表正在迭代处理的 value，第三个参数代表是否还需要继续迭代，如果将第三个参数设为 YES，那么该迭代会立即停止。 

  + > 默认第三个参数传递的是NO

  + `keysOfEntriesWithOptions:passingTest`：该方法的功能与前一个方法的功能基本相同。只是该方法可以额外传入一个附加的 NSEnumerationOptions 选项参数。

```objective-c
#import <Foundation/Foundation.h>

@interface NSDictionary (print)
- (void)print;
@end


@implementation NSDictionary (print)
- (void)print
{
    NSMutableString *result = [NSMutableString stringWithString:@"["];
    for (id key in self) {
        [result appendString:[key description]];
        [result appendString:@" = "];
        [result appendString:[key description]];
        [result appendString:@", "];
    }
    NSUInteger len = [result length];
    if (len > 2) {
        // 去掉字符串最后一个", "
        [result deleteCharactersInRange:NSMakeRange(len - 2, 2)];
    }
    [result appendString:@"]"];
    NSLog(@"%@", result);
}
@end

int main(int argc , char * argv[])
{
    @autoreleasepool
    {
        // 使用简化语法创建NSDictionary对象
        NSDictionary* dict = @{
            @"Objective-C": [NSNumber numberWithInt:89],
            @"Ruby": [NSNumber numberWithInt:69],
            @"Python": [NSNumber numberWithInt:75],
            @"Perl": [NSNumber numberWithInt:109]
        };

        // 打印dict集合的所有元素
        [dict print];
        // 对NSDictionary的所有key进行过滤
        NSSet* keySet = [dict keysOfEntriesPassingTest:
            // 使用代码块对NSDictionary的key-value对进行过滤
            ^(id key, id value, BOOL* stop)
            {
                // 当value的值大于80时返回YES
                // 这意味着只有value的值大于80的key才会被保存下来
            // *stop = YES;
                return (BOOL)([value intValue] > 80);
            }];
        NSLog(@"%@", keySet);
    }
}
```

> 返回值为 YES 时, 将key 加入到当前结果

