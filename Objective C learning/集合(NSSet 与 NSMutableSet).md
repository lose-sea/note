NSSet 集合不允许包含相同的元素, 入如果视图把两个相同的元素放在同一个NSset 集合中, 则只会保留一个元素 

## NSSet 功能与用法

NSSet 不能保证元素的添加顺序，顺序有可能发生变化。与 NSArray 相比，NSSet 最大的区别是元素没有索引，因此不能根据索引来操作元素，前面介绍 NSArray 时提到过的所有有关索引的方法都不适用于 NSSet。

实际上，NSArray 与 NSSet 依然有大量的相似之处，NSSet 与 NSArray 在如下方面的调用机制都非常相似。

+ 都可通过 count 方法获取集合元素的数量。
+ 都可通过快速枚举遍历集合元素。
+ 都可通过 objectEnumerator 方法获取 NSEnumerator 枚举器对集合进行遍历。由于 NSSet 集合本身是无序的，因此，提供反向迭代器没有意义。
+ 都提供了 makeObjectsPerformSelector:、makeObjectsPerformSelector:withObject: 方法对集合元素整体调用某个方法，以及 enumerateObjectsUsingBlock: enumerateObjectsWithOptions:usingBlock: 对集合整体或部分元素迭代执行代码块。

