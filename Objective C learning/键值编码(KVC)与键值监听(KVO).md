Objective-C还支持一种更灵活的操作, 这种方式允许以字符串形式间接操作对象的属性,这种方式的全称是Key Value Coding, 即键值编码

## 简单的KVC 

最基本的KVC 由 NSKeyValueCoding 协议提供支持, 最基本的操作属性的两个方法如下 :

> setVaule: 属性值 forKey : 属性名: 为指定属性设置值
>
> valueForKey: 属性名: 获取指定属性的值

```objective-c
@interface FKUser : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* pass;
@property (nonatomic, copy) NSDate* birth;
@end

@implementation FKUser
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        FKUser* user = [[FKUser alloc] init];
        [user setValue: @"孙悟空" forKey: @"name"];
        [user setValue: @"1455" forKey: @"pass"];
        [user setValue: [[NSDate alloc] init] forKey: @"birth"];
        
        NSLog(@"user 的 name为：%@", [user valueForKey: @"name"]);
        NSLog(@"user 的 pass为：%@", [user valueForKey: @"pass"]);
        NSLog(@"user 的 birth为：%@", [user valueForKey: @"birth"]);
    }
    return 0;
}
```



输出: 

```objective-c
user 的 name为：孙悟空
user 的 pass为：1455
user 的 birth为：2026-03-07 08:33:42 +0000 
```

在KVC编程方式中, 无论调用setValue:forKey: 方法, 还是调用valueForKey: 方法, 都是通过NSString对象来指定被操作属性的, 其中forKey标签用用于传入属性名 

对于``setValue: 属性值 forKey@"name"`代码, 底层的执行机制如下: 

1. 程序优先考虑调用 “setName: 属性值”, 代码通过setter方法完成设置 
2. 如果该类没有setName:方法, 那么KVC机制会搜索该类名为 _name的成员变量
3. 如果该类既没有setName方法, 也没有定义_name成员变量, 那么KVC机制会搜索该类中名为name的成员变量, 无论该成员变量是在类接口部分定义, 还是在类实现部分定义, 也无论用哪个访问符控制符修饰, 这条KVC代码底层实际上就是对name成员变量赋值  
4. 如果上面3步都没有找到, 那么系统就会执行该对象的 `setValue forUndefinedKey:`方法

`valueforKey@"name"`的底层执行机制同上, 程序优先调用“name;”代码来获取getter方法的返回值

同理, 如果没有上面3步,那么系统就会执行该对象的 `ValueForUndefinedKey:`方法 

默认的`setValue: forUndefinedKey:`和``valueForUndefinedKey:`方法的实现就会引发一个异常, 这个异常就会导致程序因为异常结束

### 处理不存在的key

当使用KVC方式操作属性时, 这些属性可能并不存在– 既不存在对应的setter.getter方法, 也不存在对应的成员变量, KVC将会自动调用setValue: forUndefinedKey: 和 valueForUndefinedKey: 方法 , 但系统默认实现的这两个方法仅仅是引发异常,并没有进行任何特殊的处理 

```objective-c
@interface FKApple : NSObject
@end

@implementation FKApple
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        FKApple* app = [[FKApple alloc] init];
        [app setValue: @"大苹果" forKey: @"name"];
        [app valueForKey: @"name"]; 
    }
    return 0;
}
```



上面程序中name并不存在, 因此引发了NSUnknownKeyException 异常 

```objective-c
Terminating app due to uncaught exception 'NSUnknownKeyException', reason: '[<FKApple 0x600000ed4000> setValue:forUndefinedKey:]: this class is not key value coding-compliant for the key name.'
terminating due to uncaught exception of type NSException
```

这段信息就是setValue: forUndefinedKey: 方法默认的实现: 该实现引发一个NSUnknownKeyException 异常, 并结束程序, 这个默认方法的实现也许并不适合业务, 也许实际业务并不想结束该程序, **此时可以考虑重写setValue: forUnfinedKey: 方法和 `valueForUnfinedKey`方法**

```objective-c
@interface FKApple : NSObject
@end

@implementation FKApple
- (void) setValue: (id) value forUndefinedKey: (id) key {
    NSLog(@"您尝试设置的key: [%@]并不存在", key);
    NSLog(@"你尝试设置的value为: %@", value);
}
- (id) valueForUndefinedKey: (id)key {
    NSLog(@"您尝试访问的key [%@]不存在", key);
    return key;
}
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        FKApple* app = [[FKApple alloc] init];
        [app setValue: @"大苹果" forKey: @"name"];
        [app valueForKey: @"name"];
    }
    return 0;
}
```

输出: 

```objective-c
您尝试设置的key: [name]并不存在
你尝试设置的value为: 大苹果
您尝试访问的key [name]不存在
```

此时可以看到当KVC操作并不存在key是, KVC机制总是调用重写过的方法进行处理, 通过这种处理机制, 可以非常方便地定制自己的处理行为 

### 处理nil值

当调用KVC来设置对象的属性时, 如果属性时基本类型, (int, float, double), 且程序传入了对应类型的值, 那么程序可以正确的进行设置, 但如果尝试为基本类型的属性设置一个nil, 则有可能引发错误 

```objective-c
@interface FKItem : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, assign) int price;
@end

@implementation FKItem

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        FKItem* item = [[FKItem alloc] init];
        [item setValue:nil forKey:@"name"];
        [item setValue:nil forKey:@"price"];
        NSLog(@"item de name is %@", [item valueForKey:@"name"]);
        NSLog(@"item de price is %@", [item valueForKey:@"price"]);
    }
    return 0;
}
```



```objective-c
erminating app due to uncaught exception 'NSInvalidArgumentException', reason: '[<FKItem 0x6000011d10e0> setNilValueForKey]: could not set nil as the value for the key price.'
*** First throw call stack
```



会引发一个`NSInvalidArgumentExcepton`异常, 这是由于int类型的属性不能接受nil值所导致的 

上面的提示信息实际上是有程序的 setNiValueForKey: 方法所产生的, 当程序尝试为某个属性设置为nil 值时, 如果该属性并不接受nil值, 那么程序将会自动执行该对象的setNiValueForkey: 方法, 为了定制这个行为, 同样可以重写setNiValueForKey: 方法来实现, 

```objective-c
@interface FKItem : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, assign) int price;
@end

@implementation FKItem
- (void) setNilValueForKey:(NSString *)key {
    // 如果尝试将key为price的属性设置为 nil
    if ([key isEqualToString: @"price"]) {
        // 将该_peice设置为 0
        _price = 0;
    } else {
        // 回调父类的setNiValueForKey: 执行默认行为
        [super setNilValueForKey: key];
    }
}
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        FKItem* item = [[FKItem alloc] init];
        [item setValue:nil forKey:@"name"];
        [item setValue:nil forKey:@"price"];
        NSLog(@"item de name is %@", [item valueForKey:@"name"]);
        NSLog(@"item de price is %@", [item valueForKey:@"price"]);
    }
    return 0;
}
```



输出: 

```objective-c
item de name is (null)
item de price is 0
```

### key路径

KVC除了可以操作对象的属性之外, 还可以操作对象的“复合属性”, KVC机制将其称为key路径,例如: FKOrder对象内包含一个FKItem类型的item属性, 而FKItem对象有包含了 name属性和price属性, 那么KVC可以通过item.name, item.price这种key路径来支持操作 FKOrder对象的item属性的name, price属性 

在KVC协议中操作key路径的方法如下 

> `setValue: forKeyPath: `根据key路径设置属性值 
>
> `valueForKeyPath: `根据key路径获取属性值 

```objective-c
@interface FKItem : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, assign) int price;
@end

@interface FKOrder : NSObject
@property (nonatomic, strong) FKItem* item;
@property (nonatomic, assign) int amount;
- (int) totalPrice;
@end

@implementation FKItem
@end

@implementation FKOrder
- (int) totalPrice {
    return _amount * _item.price;
}
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        FKOrder* order = [[FKOrder alloc] init];
        // 使用KVC方式为amount设置属性值
        [order setValue: @"12" forKey: @"amount"];
        [order setValue: [[FKItem alloc] init] forKey: @"item"];
        // 使用setValue: forKeyPath: 设置item属性的name属性
        [order setValue: @"书包" forKeyPath: @"item.name"];
        [order setValue: [NSNumber numberWithInt: 20] forKeyPath: @"item.price"];
        //valueForKeyPath来获取复合属性值
        NSLog(@"订单包含%@个%@, 总价为%@", [order valueForKey: @"amount"], [order valueForKeyPath: @"item.name"], [order valueForKey: @"totalPrice"]);
    }
    return 0;
}

```

实际上, 通过KVC操作对象的性能比通过setter, getter方法操作的性能更差, 使用KVC的优势在于编程更加灵活, 更适合提一些通用性质的代码, **由于KVC方式允许通过字符串形式来操作对象属性, 这个字符即可是常量, 也可以是变量吗, 因此具有极高的灵活性**

## 键值监听 (KVO) 

在iOS应用开发过程中, iOS应用通常会把应用程序组件分开成数据模型组件和视图组件, 其中数据模型组件负责维护应用程序的状态数据, 而视图组件则负责显示数据模型组件内部的状态数据

对于上面的设计结构, 如果程序存在的需求是: 在数据模型组件的状态数据发生改变时, 视图组件能动态地更新自己, 及时显示数据模型组件更新后的数据

实际上, iOS提供了更优秀的解决方案, 利用KVO (Key Value ObServing, 键值监听)机制. NSObject的子类, (所有的Objective-C类都是NSObject的子类)都可以使用该协议中的方法. 

该协议包含了如下常用方法用于注册监听器

> addObserver: forKeyPath: options: context: 注册一个监听器用于监听指定的key路径
>
> removeObserve: forKeyPath: 为key路径删除指定的监听器
>
> removeObserve: forKeyPath: context: 为key路径删除指定的监听器,只是多了一个context参数

对于上面的需求, 很容易想到可以让视图组件来监听数据模型组件的改变,当数据模型组件的key路径对应的属性值发生改变时, 作为监听器的视图组件将会被覆盖, 激发时就会回调监听器自身的监听方法; 该监听方法如下; 

`observeValueFerKeyPath: ofObject: change: context:  `

由此可见,作为监听器的视图组件需要重写observeValueForKeyPath:ofObject:change:context:方法,重写该方法时就可以得到最新修改的数据,从而使用最新的数据来更新视图组件的显示。

从上面的介绍不难看出，KVO编程的步骤非常简单。

1. 为被监听对象(通常是数据模型组件)注册监听器
2. 重写监听器的 observeValueForKeyPath:ofObiiect:change:context:方法