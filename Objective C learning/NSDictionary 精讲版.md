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

`keysOfEntriesWithOption: passingTest: ` 



