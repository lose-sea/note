# NSSet

NSSet不允许有重复的元素, 把对象丢进集合, 多个对象之间没有明显的顺序,把多个相同的元素放在同一个NSSet集合中, 只会保留一个元素 

NSSet与NSArray有很多相似之处: 

1. 可以通过[set count]; 获取集合的元素个数 
2. 可以通过快速枚举来遍历集合元素 
3. 可以通过`objectEnumerator` 方法获取NSEnumerator 枚举器对集合元素进行遍历 
4. 可以`makeObject Per formSelctor` , `makeObjectPerformSelector: withObject:`方法对集合整体调用某个方法, 以及`enumerateObjectUsingBlock: ` 和`enumerateObjectsWithOptions: usingBlock: `对集合整体或部分元素迭代执行代码块

# 创建

## `[NSSet set]`创建一个空集合

## 创建单个元素的集合







> 

​		
