NSSet 集合不允许包含相同的元素, 入如果视图把两个相同的元素放在同一个NSset 集合中, 则只会保留一个元素 

## NSSet 功能与用法

NSSet 不能保证元素的添加顺序，顺序有可能发生变化。与 NSArray 相比，NSSet 最大的区别是元素没有索引，因此不能根据索引来操作元素，前面介绍 NSArray 时提到过的所有有关索引的方法都不适用于 NSSet。

实际上，NSArray 与 NSSet 依然有大量的相似之处，NSSet 与 NSArray 在如下方面的调用机制都非常相似。

+ 都可通过 count 方法获取集合元素的数量。
+ 都可通过快速枚举遍历集合元素。
+ 都可通过 objectEnumerator 方法获取 NSEnumerator 枚举器对集合进行遍历。由于 NSSet 集合本身是无序的，因此，提供反向迭代器没有意义。
+ 都提供了 makeObjectsPerformSelector:、makeObjectsPerformSelector:withObject: 方法对集合元素整体调用某个方法，以及 enumerateObjectsUsingBlock: enumerateObjectsWithOptions:usingBlock: 对集合整体或部分元素迭代执行代码块。

> NSSet 同样提供了类方法和实例方法来初始化NSSet集合 , 以 set 开头的是类方法, 以 init 开头的是实例方法

除了与 NSArray 相似的方法之外, NSSet 还提供了如下常用方法: 

> + setByAddingObject: 向集合中添加一个元素, 返回添加元素后的新集合
>
> + setByAddingObjectsFromSet: 使用NSset 集合向集合中添加多个新元素, 返回添加元素后的新集合 
>
> + setByAddingObjectsFromArray: 使用NSArray 集合向集合中添加多个新元素,  返回添加元素后的新集合
>
> + allObjects: 返回该集合中所有元素组成的NSArray. 
>
> + allObject: 返回该集合中的某个元素, 该方法返回的元素是不确定的, 但该方法并不保证随机返回集合元素  
>
> + > NSSet 底层采用 Hash 表（其实就是数组）来保存元素，但集合元素位于底层 Hash 表的位置对开发者是透明的，因此，该方法返回的元素对开发者是透明的。但只要一个 NSSet 没有发生改变，无论多少次调用该方法，返回的都是同一个集合元素。
>
> + containObject: 判断集合是否包含指定元素  
>
> + ObjectPassingTest: 需要传入一个代码块对集合元素进行过滤, 满足该代码块条件的集合元素被保留下来并组成一个新的NSSet 集合作为返回值
>
> + ObjectsWithOptions: passingTest: 与前一个方法的功能基本相似, 只是可以额外地传入一个NSEnuerationOptions 迭代选项参数  
>
> + inSubsetOfSet: 判断当前 NSSet 集合是否为另一个集合的子集合, 调用该方法需要传入另一个集合
>
> + intersectsSet: 判断集合的元素是否具有相同的元素, 也就是计算两个集合是否有交集 
>
> + isEqualToSet: 判断两集合的元素是否相等

## NSSet 判断集合元素重复的标准

当向 NSSet 集合中存入一个元素时，NSSet 会调用该对象的 hash 方法来得到该对象的 hashCode，然后根据该 hashCode 值决定该对象在底层 Hash 表中的存储位置，如果根据 hashCode 值计算出该元素在底层 Hash 表中的存储位置已经不相同，那么系统直接将它们保存在不同的位置。

如果两个元素的 hashCode 值相同，接下来就要通过 isEqual: 方法判断两个元素是否相等，若两个元素通过 isEqual: 方法比较返回 NO，那么 NSSet 依然认为它们不相等，NSSet 会把它们存在底层 Hash 表的同一个位置，只是将在这个位置形成链；如果它们通过 isEqual: 方法比较返回 YES，那么 NSSet 认为两个元素相等，后面的元素添加失败。

简单地说，NSSet 集合判断两个元素相等的标准如下。

+ 两个对象通过 isEqual: 方法比较返回 YES。
+ 两个对象的 hash 方法返回值也相等。

```objective-c
int main(int argc, char* argv[]) {
    @autoreleasepool {
        NSSet* set = [[NSSet alloc] initWithObjects:
                        [[FKUser alloc] initWithName: @"sun" pass: @"123"],
                        [[FKUser alloc] initWithName: @"xin" pass: @"456"],
                        [[FKUser alloc] initWithName:@"sun" pass:@"123"],
                        [[FKUser alloc] initWithName:@"xun" pass:@"432"],
                        [[FKUser alloc] initWithName: @"liu" pass: @"543"],
                      nil];
        NSLog(@"The count of set is %ld", [set count]);
        
    }
    return 0;
}
```

输出: 

```objective-c
5
```

留意到上面程序中创建的 NSSet 集合中第 1、3 个 FKUser 对象的 name、pass 相等，因此这两个 FKUser 对象通过 isEqual: 比较将会返回 YES。但由于程序并没有重写它们的 hash 方法，因此这两个 FKUser 的 hashCode 值不相等，NSSet 依然认为它们不相等，NSSet 会同时存储两个元素。

为FKUser重写Hash方法, 重写Hash方法时根据name, pass两个属性的值进行计算

```objective-c
- (NSUInteger) hash {
    NSUInteger namehash = _name == nil ? 0 : [_name hash];
    NSUInteger passhash = _pass == nil ? 0 : [_pass hash];
    return namehash * 31 + passhash;
}
```

重写之后, 输出`4`, 此时集合中只包含有4个元素

hash 方法对于 NSSet 是非常重要的，下面给出重写 hash 方法的基本规则。

+ 在程序运行过程中，同一个对象多次调用 hash 方法应该返回相同的值。
+ 当两个对象通过 isEqual: 方法比较返回 YES 时，这两个对象的 hash 方法应返回相等的值。
+ 对象中作为 isEqual: 方法比较标准的成员变量，都应该用来计算 hashCode 值。

下面给出重写 hash 方法的一般步骤。

① 把对象内每个有意义的成员变量（即每个用作 isEqual: 方法比较标准的实例变量）计算出一个 int 类型的 hashCode 值。

② 用第 1 步计算出来的多个 hashCode 值组合计算出一个 hashCode 值返回。例如，如下代码：

`return [f1 hash] + [f2 hash]; `

为了避免直接相加产生偶然相等（两个对象的 f1、f2 实例变量并不相等，但它们的 hashCode 值和恰好相等），可以通过为各实例变量的 hashCode 值乘以任意一个质数后再相加。例如，如下代码：

`return [f1 hash] * 31 + [f2 hash]; `

## NSMutableSet 的功能与用法

NSMutableSet 继承了 NSSet，它代表一个集合元素可变的 NSSet 集合。由于 NSMutableSet 可以动态地添加集合元素，因此，创建 NSMutableSet 集合时可指定底层 Hash 表的初始容量。

类似于 NSMutableArray 与 NSArray 的关系，NSMutableSet 主要在 NSSet 基础上增加了添加元素、删除元素的方法，并增加了对集合计算交集、并集、差集的方法。

+ addObject:：向集合中添加单个元素。
+ removeObject:：从集合中删除单个元素。
+ removeAllObjects：删除集合中的所有元素。
+ addObjectsFromArray:：使用 NSArray 数组作为参数，向 NSSet 集合中添加参数数组中的所有元素。
+ unionSet:：计算两个 NSSet 集合的并集。
+ minusSet:：计算两个 NSSet 集合的差集。
+ intersectSet:：计算两个 NSSet 集合的交集。
+ setSet:：用后一个集合的元素替换已有集合中所有的元素。

## NSCountSet 的功能和用法

NSCountedSet 是 NSMutableSet 的子类，与普通 NSMutableSet 集合不同的是，NSCountedSet 为每个元素额外维护一个添加次数的状态。当程序向 NSCountedSet 中添加一个元素时，如果 NSCountedSet 集合中不包含该元素，那么 NSCountedSet 真正接纳该元素，并将该元素的添加次数标注为 1；当程序向 NSCountedSet 中添加一个元素时，如果 NSCountedSet 集合中已经包含该元素，那么 NSCountedSet 不会接纳该元素，但会将该元素的添加次数加 1。

当程序从 NSCountedSet 集合中删除元素时，NSCountedSet 只是将该元素的添加次数减 1，只有当该元素的添加次数变为 0 时，该元素才会真正从 NSCountedSet 集合中删除。

NSCountedSet 提供了如下方法来返回某个元素的添加次数。

+ countForObject:：获取指定元素的添加次数。

## 有序集合 (NSOrderedSet 与 NSMutableOrederedSet) 

NSOrderedSet 和 NSMutableOrderedSet 是两个非常奇怪的集合，它们既具有 NSSet 集合的特征，也具有 NSArray 类似的功能。

+ NSOrderedSet 不允许元素重复，这与 NSSet 集合相同。
+ NSOrderedSet 可以保持元素的添加顺序，而且每个元素都有索引，可以根据索引来操作元素。这与 NSArray 的功能类似。

> + **索引 = 添加顺序**：NSOrderedSet 会按你调用 `addObject:`/`initWithObjects:` 的顺序为元素分配索引（从 0 开始），不会对元素做任何自动排序（比如数字大小、字符串字母序）。
> + **去重但保序**：如果添加重复元素，NSOrderedSet 会忽略重复项，且不会改变原有元素的索引；只有新元素会按添加顺序追加到末尾，分配新索引。

**NSOrderedSet 集合还有一个NSMutableOrderedSet 子类, 该子类与NSOrderedSet 的关系, 就像 NUMutableSet 与 NSSet 一样, 就是增加了添加元素, 删除元素, 替换元素, 集合排序, 以及计算的交集, 并集, 搽剂等功能**
