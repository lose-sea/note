# NSString类簇 



`stringWithString:` 本质是**复制传入的字符串**，传什么类型就返回什么类型，传字面量编译器直接优化返回同一对象，并不总是在堆区。 



```objc
NSString *str1 = @"hello";
NSString *str2 = [NSString stringWithFormat:@"hi"];
NSString *str3 = [NSString stringWithFormat:@"hello12345"];
NSMutableString *str4 = [NSMutableString stringWithString:@"hello"];

NSLog(@"%@", [str1 class]); // __NSCFConstantString
NSLog(@"%@", [str2 class]); // NSTaggedPointerString
NSLog(@"%@", [str3 class]); // __NSCFString
NSLog(@"%@", [str4 class]); // __NSCFString
```

### 三种私有子类 



| 私有子类                | 创建方式                         | 存储位置 |
| ----------------------- | -------------------------------- | -------- |
| `__NSCFConstantString`  | `@"..."` 字面量                  | 常量区   |
| `NSTaggedPointerString` | Format，≤9字符                   | 指针中   |
| `__NSCFString`          | Format，>9字符 / NSMutableString | 堆区     |

**① __NSCFConstantString（常量字符串）**

```objc
NSString *str = @"hello"; // 字面量
// 存储在常量区
// 引用计数无限大，永远不会释放
// 相同字面量全程只有一份
NSString *str2 = @"hello";
NSLog(@"%p %p", str, str2); // 同一地址
```

**② NSTaggedPointerString（Tagged Pointer字符串）**

```objc
NSString *str = [NSString stringWithFormat:@"hi"]; // ≤ 9个字符
// 值直接存在指针中
// 不在堆区，不需要内存管理
// 最高位 bit = 1，标识为 Tagged Pointer
```

**③ __NSCFString（普通堆区字符串）**

~~~objc
NSString *str = [NSString stringWithFormat:@"hello12345"]; // > 9个字符
NSMutableString *mStr = [NSMutableString stringWithString:@"hello"];
// 存储在堆区
// 受 ARC 管理

```
~~~

> **NSMutableString 也是_NSCFString 类型**

### 继承链

```objc
NSString（抽象类）
    ├── __NSCFConstantString
    ├── NSTaggedPointerString
    └── __NSCFString
            └── NSMutableString
```

```objc
// isMemberOfClass 永远失败
[str isMemberOfClass:[NSString class]]; // NO

//  用 isKindOfClass
[str isKindOfClass:[NSString class]];   // YES
```

