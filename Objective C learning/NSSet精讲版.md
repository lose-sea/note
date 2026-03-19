# NSSet

NSSet不允许有重复的元素, 把对象丢进集合, 多个对象之间没有明显的顺序,把多个相同的元素放在同一个NSSet集合中, 只会保留一个元素 

NSSet与NSArray有很多相似之处: 

1. 可以通过[set count]; 获取集合的元素个数 
2. 可以通过快速枚举来遍历集合元素 
3. 可以通过`objectEnumerator` 方法获取NSEnumerator 枚举器对集合元素进行遍历 
4. 可以`makeObject Per formSelctor` , `makeObjectPerformSelector: withObject:`方法对集合整体调用某个方法, 以及`enumerateObjectUsingBlock: ` 和`enumerateObjectsWithOptions: usingBlock: `对集合整体或部分元素迭代执行代码块

## 创建 

## 类方法

### `[NSSet set]`创建一个空集合

### 创建单个元素的集合

```objc
[NSSet setWithObject: @"hello"]; 
```

### 创建多个元素的集合

```objc
NSSet* set = [NSSet setWithObjects: @"hello", @"xinyan", nil];
```

**注意一定要以 nil 结尾**

### 从数组创建

```objc
NSArray* arr = [NSArray arrayWithObject: @"hello"];
NSSet* set = [NSSet setWithArray: arr];
```

### 从另一个集合创建

```objc
NSSet* set1 = [NSSet setWithObject: @"hello"];
NSSet* set = [NSSet setWithSet: set1];
```

## 实例方法

**实例方法同上, 以init开头** 

**实例方法没有`initWithObject`, 只有`initWithObjects: ... nil`**

```objc
NSSet* set = [[NSSet alloc] init]; // 空集合 
NSSet* set = [[NSSet alloc] initWithObects: @"hello", nil];  // 创建含多个元素的集合
   // 从数组创建 
NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", nil];
NSSet* set = [[NSSet alloc] initWithArray: arr]; 
// 从另一个集合创建
NSSet* set1 = [[NSSet alloc] initWithObjects: @"hello", @"xinyan" ,nil];
NSSet* set = [[NSSet alloc] initWithSet: set1]; 
```

## 添加元素 (返回添加元素后的新集合) 

### 添加一个元素 

```objc
        NSSet* set = [[NSSet alloc] initWithObjects: @"hello", @"xinyan", nil];
        set = [set setByAddingObject: @"swift"];
```

### 使用NSArray集合向集合中添加多个元素 

```objc
        NSSet* set = [[NSSet alloc] initWithObjects: @"hello", @"xinyan", nil];
        NSArray* arr = [[NSArray alloc] initWithObjects: @"python", nil]; 
        set = [set setByAddingObjectsFromArray: arr];
```

### 使用NSSet 集合向集合中添加多个元素

```objc
        NSSet* set = [[NSSet alloc] initWithObjects: @"hello", @"xinyan", nil];
        NSSet* set1 = [[NSSet alloc] initWithObjects: @"python", nil];
        set = [set setByAddingObjectsFromSet: set1];
```

## 取出元素

### `allObjects:` 返回该集合中所有元素组成的NSArray 

```objc
int main(int argc, char* argv[]) {
    @autoreleasepool {
        NSSet* set = [[NSSet alloc] initWithObjects: @"hello", @"xinyan", nil];
        NSSet* set1 = [[NSSet alloc] initWithObjects: @"python", nil];
        set = [set setByAddingObjectsFromSet: set1];
        NSLog(@"%@", set);
        NSArray* arr = [set allObjects];
        NSLog(@"%@", arr);
    }
    return 0;
}
```

### `anyObject:` 返回该集合中的某个元素 ,该方法返回的元素是不确定的, 但是并不保证随机返回集合元素

```objc
int main(int argc, char* argv[]) {
    @autoreleasepool {
        NSSet* set = [[NSSet alloc] initWithObjects: @"hello", @"xinyan", nil];
        NSSet* set1 = [[NSSet alloc] initWithObjects: @"python", nil];
        set = [set setByAddingObjectsFromSet: set1];
        id a = [set anyObject];
        NSLog(@"%@", a); 
    }
    return 0;
}
```

> 只要一个NSSet 没有发生改变, 无论多少次调用该方法, 返回的都总是同一个元素

## 查找

containObject: 判断集合是否包含指定元素  

```objc
NSString* str = @"hello";
NSLog(@"%d", [set containsObject: str]);
```

member: 判断该集合是否包含与该参数相等的元素, 如果包含, 返回相等的元素, 否则返回nil 

```objc
NSString* str = @"hello"; 
NSLog(@"%@", [set member: str]);
NSLog(@"%@", [set member: @"swift"]);
```

输出: 

```objc
1
hello
(null)
```

## 过滤

`objectsPassingTest: `需要传入一个代码块对集合元素进行过滤, 满足该代码块条件的集合元素被保留下来并组成一个新的NSset 集合作为返回值 

`objectsWithOptions: passingTest: `与前一个方法功能基本相似, 只是可以额外地传入一个`NSEnumerationOptions `迭代选项参数

```objc
int main(int argc, char* argv[]) {
    @autoreleasepool {
        NSSet* set = [[NSSet alloc] initWithObjects: @"hello", @"xinyan", nil];
        NSSet* set1 = [set objectsPassingTest: ^(id obj, BOOL* stop) {
            return (BOOL)([obj length] > 5);
        }];
        NSLog(@"%@",set1);
    }
    return 0;
} 
输出: xinyan
```

## 判断

`isSUbsetOfSet: `判断当前NSset集合是否为另一个集合的子集合 

`intersectsSet`判断两个集合是否有相同的元素, (判断是否有交集) 

`isEqualToSet: 	`判断两个集合的元素是否相等 

# NSSet 判断集合元素重复的标准



```objc
int main(int argc, char* argv[]) {
    @autoreleasepool {
        User* user1 = [[User alloc] initWithName:@"xinyan" pass:@"123"];
        User* user2 = [[User alloc] initWithName:@"xinyan" pass:@"123"];
        User* user3 = [[User alloc] initWithName:@"John" pass:@"123"];
        NSSet* set = [NSSet setWithObjects: user1, user2, user3, nil];
        NSLog(@"%ld", [set count]);	// 输出: 3
    }
    return 0;
}
```

NSSet 的去重逻辑是：

1. 先比较 `hash` 值，hash 不同 → 直接认为不同对象
2. hash 相同 → 再调用 `isEqual:` 判断是否真正相等



从输出可以看出, user1 和 user2 的name 和pass 都相等, 但由于程序没有重写他们的hash方法, 因此这两个User 的 hashCode 值不相等 ,NSSet 依然认为他们不相等,NSset 会同时存储两个元素



为User类重写hash 方法, 重写hash 方法根据name , pass两个成员变量的值进行计算

```objc
```

