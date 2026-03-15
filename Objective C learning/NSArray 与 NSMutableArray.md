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

## 从索引 m 开始, 与 n 个元素组成新集合

```objective-c
int main(int argc, char* argv[]) {
    NSArray* arr = [[NSArray alloc] initWithObjects: @"hello", @"xinyan", @"world", @"iOS", nil];
    NSIndexSet* indexSet = [NSIndexSet indexSetWithIndexesInRange :NSMakeRange(1, 3)];
    NSArray* arr1 = [arr objectsAtIndexes: indexSet];
    NSLog(@"%@", arr1);
    return 0;
}
```

输出: 

```objective-c
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