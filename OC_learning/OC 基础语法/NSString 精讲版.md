# NSString

## 创建 

### 实例方法 (allod + init)

#### - (Instancetype) initWithCharacters: (const unichar *)charactors length: length


- `(instancetype)initWithCharacters: (const unichar *)characters length:(NSUInteger)length `

**两个参数：**

+ `characters` — 传入一个 `unichar` 数组（Unicode 字符数组）
+ `length` — 告诉方法数组里有几个字符

```objective-c
int main(int argc, char* argv[]) {
    unichar data[6] = {97, 98, 99, 100, 101, 102};
    NSString* str = [[NSString alloc] initWithCharacters: data length: 5];
    NSLog(@"%@", str); 
    return 0;
}
```

输出: 

  ```objective-c
  abcde
  ```

#### 从C字符串转换

`- (Instancetype) initWithUTF8String: (const char *)CString `

`+ (instancetype) stringWithUTF8String:` 是把 **C语言字符串** 转换成 **NSString** 的方法。

+ `(instancetype) stringWithUTF8String:(const char *)nullTerminatedCString `

```objective-c
int main(int argc, char* argv[]) {
    char* data = "hello";
    NSString* str = [[NSString alloc] initWithUTF8String: data];
    NSLog(@"%@", str);
    return 0;
}
```

#### 普通初始化	

```objective-c
NSString* str = [[NSString alloc] initWithString:@"hello"];
```

### 字面量

```objective-c
NSString* str = @"hello world"; 
```

### 类方法 

#### 普通初始化

`[NSString stringWithString: @"hello"]; `

#### 格式化

```objective-c
int main(int argc, char* argv[]) {
    NSString* str = [NSString stringWithFormat: @"hello %d", 8];
    NSLog(@"%@", str);
    return 0;
}
```

输出: 

```objective-c
hello 8
```

#### 从C字符串转换

`+ (instancetype) stringWithUTF8String: (const char*) Cstr; `

```objective-c
int main(int argc, char* argv[]) {
    char* data = "hello";
    NSString* str = [NSString stringWithUTF8String: data];
    NSLog(@"%@", str);
    return 0;
}
```

## NSString常用功能

### 字符串追加固定字符串

`[str stringByAppendingstring: ]`

```objective-c
int main(int argc, char* argv[]) {
    char* data = "hello";
    NSString* str = [NSString stringWithUTF8String: data];
    NSLog(@"%@", str);
    str = [str stringByAppendingString: @" world"];
    NSLog(@"%@", str);
    return 0;
}
```

### 获取对应的C 风格字符串 

`[str UTF8String]; `

### 追加带变量的字符串

`[str stringByAppendFormat: ]`   

```objective-c
int main(int argc, char* argv[]) {
    char* data = "helloabcdefghigk";
    NSString* str = [NSString stringWithUTF8String: data];
    NSLog(@"%@", str);
    str = [str stringByAppendingFormat: @" hello %d", 7];
    NSLog(@"%@", str);
    return 0;
}
```

输出: 

`````
helloabcdefghigk
helloabcdefghigk hello 7
`````

### 获取字符串长度

`[str length]; ` 

### 获取前n个字符 

`[str substringToIndex: index]`

```objective-c
int main(int argc, char* argv[]) {
    char* data = "helloabcdefghigk";
    NSString* str = [NSString stringWithUTF8String: data];
    NSLog(@"%@", str);
    str = [str substringToIndex: 6];
    NSLog(@"%@", str);
    return 0;
}
```

输出: 

```objective-c
helloa
```

### 获取从索引为 n 的字符开始, 与后面的所有字符组成的字符串

`[str substringFromIndex: index]; `  

### 获取从索引为 m 的字符开始, 与后面的4个字符组成的字符串

`[str substringWithRange: NSMakeRange (m, n)]; `

### 获取某字符串在字符串中出现的初始位置

```objective-c
int main(int argc, char* argv[]) {
    char* data = "helloabcdefghigk";
    NSString* str = [NSString stringWithUTF8String: data];
    NSLog(@"%@", str);
    NSRange pos = [str rangeOfString: @"abc"];
    NSLog(@"abc 出现的开始为位置为: %ld,长度为 %ld", pos.location, pos.length);
    return 0;
}
```

> NSRange 类型的变量，NSRange 并不是一个类，它只是一个结构体，它包括了 location 和 length 两个 unsigned int 整型值，分别代表起始位置和长度。Objective-C 还提供了 NSMakeRange()函数来创建 NSRange 变量。实际上，后面还会见到 Objective-C 提供的大量 NSXxx 结构体类型，而且 Objective-C 也会提供对应的 NSXxxMake()函数来创建对应的结构体变量。

输出: 

```objective-c
helloabcdefghigk
abc 出现的开始为位置为: 5,长度为 3
```

### 将字符串的所有字符串转换为大写

`[str uppercaseString]; `

### 将字符串的所有字符串转换为小写

`[str lowercaseString]; `

# NSMutableString 

## 追加固定字符串

`[str appendString: @“hello”]; ` 

## 追加带变量字符串

`[str appendStringFormat: @"hello %d", 8];  `

## 插入字符串 

`[str insertString: NSString atIndex: index]`

```objective-c
int main(int argc, char* argv[]) {
    NSMutableString* str = [NSMutableString stringWithString: @"helloabcdefg"];
    NSLog(@"%@", str);
    
    [str insertString: @" xinyan " atIndex: 6];
    NSLog(@"%@", str);
    return 0;
}
```

输出: 

```objective-c
helloabcdefg
helloa xinyan bcdefg
```

## 删除从位置 m 开始, 长度为 n 的所有字符 

`[deleteCharactersInRange: NSMakerange(m, n)] `

```objective-c
int main(int argc, char* argv[]) {
    NSMutableString* str = [NSMutableString stringWithString: @"helloabcdefg"];
    NSLog(@"%@", str);
    
    [str deleteCharactersInRange: NSMakeRange(4, 5)];
    NSLog(@"%@", str);
    return 0;
}
```

## 将从位置 m 开始, 长度为 n 的所有字符替换

`[str replaceCharatersInRange: NSMakeRange(m, n) withString: @"hello"]; `

```objective-c
int main(int argc, char* argv[]) {
    NSMutableString* str = [NSMutableString stringWithString: @"helloabcdefg"];
    NSLog(@"%@", str);
    
    [str replaceCharactersInRange: NSMakeRange(4, 5) withString: @"xxxx"];
    NSLog(@"%@", str);
    return 0;
}
```

输出; 

```objective-c
helloabcdefg
hellxxxxefg
```



