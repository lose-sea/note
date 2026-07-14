# OC对象的本质

oc的对象, 类, 主要是基于结构体去实现的 

所有的OC对象都继承自NSObject, 类主要是基于结构体去实现的 

```objc
// 类的结构体
struct NSObject_IMPL {
    Class isa; // Class是一个结构体类型, isa是一个结构体指针
}
```

继承自NSObject 的对象结构大致是, 这是一个继承自NSobject 的对象的Student, (被添加了name 和 age 两个属性) 

```objc
struct Struct_IMPL {
    struct NSObject_IMPL NSobject_IVARS; (Class class) 
    int _age; 
    NSString* _name; 
}
```

## OC的实例对象, 类对象. 元类对象

> OC主要包括了3种对象
>
> 1. 实例对象
> 2. 类对象
> 3. 元类对象 

## 类对象

实例对象就是通过类 alloc 出来的对象 , 每一次调用 alloc 都会产生一个新的instance对象 

> 1. isa指针
> 2. 其他成员变量

## 类对象 

通过实例对象的class方法或类的class方法获取到类对象, **每个类在内存中有且只有一个class 对象**

> 1. isa指针
> 2. superclass指针
> 3. 类的属性信息 (@property) 
> 4. 类的对象方法信息 
> 5. 类的协议信息
> 6. 类的成员变量信息 

## 元类对象



**每个类在内存中有且只有一个 元类对象 (meta-class)**

> 1. isa指针
> 2. superclass指针
> 3. 类的方法信息

