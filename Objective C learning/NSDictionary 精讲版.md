# NSDictionary 

NSDictionary 用于保存具有映射关系的数据, NSDictionary 集合里保存着两组值, 一组值用于保存NSDictionary 里的key, 另一组值用于保存NSDictionary 里的value, key 和 value 都可以

key 和 value 之间存在单向一对一的关系, 通过指定的key, 总能找到唯一确定的value, 从NSDictionary 中取出数据时, 只要给出指定的key, 就可以取出对应的value. 

## 创建 

NSDictionary 集合由多个key-value 对组成, 因此创建 NSDictionary 时需要同时指定多个key-value对, NSDictionary 分别提供了类方法和实例方法来创建NSDictionary, 两种创建方式需要传入的参数基本相似, 只是类方法以 dictionary 开头, 实例方法以init开头

### 创建一个不包含任何key-value对的 NSDictioinary

```objc
NSDictionary* dict = [NSDictionary dictionary]; //创建一个不包含任何key-value对的 NSDictioinary
```

### 从文件中创建

`distionaryWithContentsOfFile: / initWithContentsOfFile: ` 读取指定文件的内容, 使用指定的文件内容来初始化NSDictionary, 该文件通常是由 NSDictionary 输出生成的 

### 使用单个key-value 对创建

`NSDictionary* dict = [NSDictionary dictionaryWithObject: @"hello" forKey: [NSNumber numberWithInt: 5]];`

### 使用两个NSArray 分别指定key, value 集合, 可以创建包含多个key-value对的NSDictionary 

`NSDictionary* dict = [NSDictionary dictionaryWithObjects: [NSArray arrayWithObjects: @"hello", @"xinyan", nil] forKeys: [[NSArray alloc] initWithObjects: [NSNumber numberWithInt: 4], [NSNumber numberWithInt: 6], nil]];`

**注意: **

1. 两个NSArray 中的元素是按顺序一一对应的
2. 两个NSArray 中元素的个数要是相等的, 否则会报错 



### 使用已有的NSDictionary 包含的key-value

`NSDictionary* dict = [NSDictionary dictionaryWithDictionary: dict1];`

### 创建包含多个 key-value 对的Dictionary

`NSDictionary* dict = [NSDictionary dictionaryWithObjectsAndKeys: @"hello", [NSNumber numberWithInt: 4], @"xinyan", [NSNumber numberWithInt: 5], nil]; `

调用这个方法的时候, 需要按照vale1, key1, value2, key2, …nil 的格式传入多对 key- value对

### 简化语法创建

` NSDictionary* dict = @{[NSNumber numberWithInt: 5]: @"hello", [NSNumber numberWithInt: 7]: @"xinyan"}; `



## 其他功能

### `count` 返回NSDictionary的 key-value 对的数量 

### `allKeys` 返回NSDictionary 的全部key  

### `allKeysForObject: ` 返回指定的 velue 对应的全部key  (多个key对应的value相同)

### `objectForKeySubscript:` 通过方法支持, 允许NSDictionary 通过下标来获取指定key 的value 

获取value 有两种方法

> 1. 调用NSDictionary 的objectForKey: 方法即可根据key来获取对应的value 
> 2. 直接使用下标法根据key 来获取对应的 value 

下面两行代码的功能是一样的

```objc
[dictionary objectForKey: key]; 
dictionary[key]; 
```

后一种方法实际上就是调用NSDictionary的`objectForKeyedSubscript: `方法进行访问 

### `keyEnumerator: ` 返回用于遍历该NSDictionary 所有key 的NSEnumerator 对象

```objc
        NSEnumerator* en = [dict keyEnumerator];
        NSString* key;
        while ((key = [en nextObject])) {
            NSLog(@"%@ %@", key, dict[key]);
        }
```



### `enumerateKeyAndObjectsUsingBlock: `使用指定代码块来迭代执行该集合中所有的key-value对

```objc
[dict enumerateKeysAndObjectsUsingBlock: ^(id key, id value, BOOL* stop) {
    NSLog(@"key 的值为 %@, value 的为%@", key, value);
}]; 
```



## 对NSDictionary 的key进行排序

`keysSortedByValueUsingSelector: `根据NSDictionary 的所有value 的指定方法的返回值对key排序, 调用value 的该方法必须返回NSObjectedAscending, NSObjectedDescending, NSOrederedSame 三个枚举值之一. 

> 返回 Ascending  → a 排 b 前面（a < b，升序） 
>
> 返回 Descending → a 排 b 后面（a > b，降序） 
>
> 想要反向排序   → 把 a、b 对调即可

`keysSortedValueWithOption: usingComparator: ` 可以额外传入一个NSEnumerationOptiond参数

```objc
NSArray* arr = [dict keysSortedByValueUsingComparator: ^(id value1, id value2) {
    if ([value1 length] > [value2 length]) {
        return NSOrderedAscending;
    } else if ([value1 length] < [value2 length]) {
        return NSOrderedDescending;
    }
    return NSOrderedSame;
}];
```

## 对NSDictionary 的key进行过滤

`keysOfEntriesPassingTest:`使用代码块迭代处理NSDictionary 的每一个key-value 对, 该代码块必须返回BOOL 类型的值, 当返回yes时, 该key 才会bei留下来, 该代码块可以接受 3 个参数, 第一个参数代表正在迭代处理的key, 第二个参数代表正在处理的value, 第三个参数代表是否还需要继续迭代, 如果将第三个参数设置为YES,迭代就会停止.  

`keysOfEntriesWithOption: passingTest: ` 可以额外传入一个附加的 NSEnumerationOption选项参数

```objc
int main(int argc, char* argv[]) {
    NSDictionary* dict = [NSDictionary dictionaryWithObjectsAndKeys: @"hello", [NSNumber numberWithInt: 8], @"xinyan", [NSNumber numberWithInt: 3], @"pythonswift", [NSNumber numberWithInt: 7], nil];
    NSSet* set = [dict keysOfEntriesPassingTest: ^(id key, id value, BOOL* stop) { 
        // 筛选出value 的长度大于 5 的元素的key值, 返会由符合条件的key组成的set
        return (BOOL)([value length] > 5);
    }];
    NSLog(@"%@", set);
    NSLog(@"%@", [dict objectsForKeys: [set allObjects] notFoundMarker: @"not found"]);
    return 0;
}
```

## 使用自定义的类作为NSDictionary的key值

要使用自定义的类作为NSDictionary的key值, 这自定义的类必须满足如下两个条件

1. 该自定义类正确重写过isEqual: 和 hash 方法, (两个对象通过isEqual: 方法判断相等时, 两个对象的hash 方法的返回值也相等)
2. 该自定义类必须实现了copyWithZone: 方法, 最好返回该对象的不可变副本

当程序把多个key-value 对放入NSDictionary 集合之后, 对于NSDictionary而言, key是非常重要的, NSDictionary 需要根据key来访问 value, 如果key 是可变的, 就可能导致NSDictionary 的索引被破坏, 从而导致NSDictionary 的完整性被破坏

为了避免上面的问题, NSDictionary 采用了更安全的做法, 只要程序把任何对象都作为key 返图NSDictionary 中, NSDictionary 总会调用key的copy 方法来复制该对象的不可变副本, 然后使用该副本作为NSDictionary 的key

```objc
#import"User.h"
int main(int argc, char* argv[]) {
    NSDictionary* dict = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"one", [[User alloc] initWithName: @"John" Pass: @"123"],
                          @"two", [[User alloc] initWithName: @"make" Pass: @"345"],
                          @"three", [[User alloc] initWithName: @"xinyan" Pass: @"654"],
                    nil];
    NSLog(@"%ld", [dict count]);
    NSLog(@"%@", dict);
    return 0;
}
```

输出: 

```objc
====== copy =========
====== copy =========
====== copy =========
3
{
    "Name = make, pass = 345" = two;
    "Name = xinyan, pass = 654" = three;
    "Name = John, pass = 123" = one;
}
```



# NSMutableDictionary

NSMutableDictionary 主要新增了如下方法: 

1. `setObject: forKey:`设置一个key-value对, 如果NSDictionary 中没有包含与该 key 相同的key-value 对, 那么NSDictionary 将会增加一个 key-value 对, 否则key-value 对将会覆盖已有的 key-value 对 

   `[dict setValue: @"java" forKey: @"one"];`

2. `setObject: forFromDictionary: `将另一个NSDictionary中的key-value对添加到当前NSDictionary中  

   `[dict1 addEntriesFromDictionary: dict];`

3. `setDictionary: ` 用另一个NSDictionary 中的key-value对替换当前NSDictionary中的key-value 对 

   `  [dict1 setDictionary: dict];`

4. `removeObjectForKey: `根据key 来删除key-value对

   `dict1 removeObjectForKey: @"one"];`

5. `removeAllObject `清空该 NSDictionary  

   `[dict1 removeAllObjects];`

6. `removeObjectsForKeys: ` 使用**多个key组成的key组成的NSArray** 作为参数, 同时删除多个key-value 

`[dict removeObjectsForKeys: [NSArray arrayWithObjects: @"one", @"two",  nil]];`

