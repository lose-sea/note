# UILabel

`UILabel` 是 iOS 开发（UIKit 框架）中最常用的控件之一，专门用于在界面上**显示只读的文本**。

## 常用属性

| **属性**                        | **功能描述**                                          |
| ------------------------------- | ----------------------------------------------------- |
| **`text`**                      | 设置显示的普通字符串。                                |
| **`textColor`**                 | 设置文字颜色（默认为黑色）。                          |
| **`frame`**                     | 设置位置                                              |
| **`font`**                      | 设置字体大小和样式。                                  |
| **`textAlignment`**             | 对齐方式（左对齐、居中、右对齐）。                    |
| **`numberOfLines`**             | 行数限制。设置为 `0` 表示不限制行数，自动换行。       |
| **`lineBreakMode`**             | 断行模式（比如末尾显示省略号 `...`）。                |
| **`adjustsFontSizeToFitWidth`** | 设为 `YES` 时，如果文字过长会自动缩小字号以适应宽度。 |
| **`alpha`**                     | 设置透明度                                            |

## 基本功能

### 创建和初始化

```objc
UILabel* label = [[UILabel alloc] init]; 
// 设置位置 
// 左, 上, 宽, 高
label.frame = CGRectMake(100, 100, 200, 80);    
// 背景颜色
label.backgroundColor = [UIColor whiteColor];
```

### 设置文本

```objc
label.text = @"hello Mobile xxxxxxxxxxx";
// 设置文字的大小, 系统默认的大小是12
label.font = [UIFont systemFontOfSize: 24]; 
// 文字颜色
label.textColor = [UIColor systemCyanColor]; 

// 文字对齐模式       // 默认左对齐
label.textAlignment = NSTextAlignmentLeft;  // 左对齐
label.textAlignment = NSTextAlignmentRight;  // 右对齐
label.textAlignment = NSTextAlignmentCenter;  // 居中对齐 

// 设定label文字显示的行数, 默认是 1 行来显示
// 其他 > 0 的行数, 文字会尽量按照设定行数来显示
// 如果设为0, 会自动计算需要的行数
label.numberOfLines = 0;
```

### 设置文本阴影

文本阴影主要有两个属性: 

1. 阴影颜色
2. 阴影的偏移量

```objc
// 设置阴影
label.shadowColor = [UIColor greenColor];
label.shadowOffset = CGSizeMake(20, 10);  // 左偏移量, 下偏移量
```



### 设置Label的透明度

```objc
//设置透明度
// 1. alpha = 1  不透明
// 2. alpha = 0 透明
// 3. alpha = 0.5  半透明
label.alpha = 0.5;
```

### 是否显示不透明

```objc
// 是否显示不透明(不会影响透明度)
label.opaque = NO;
```

### 用法总结

```objc
- (void) createUILabel03 {
    UILabel* label = [[UILabel alloc] init];
    label.backgroundColor = [UIColor systemCyanColor];
    label.frame = CGRectMake(100, 100, 200, 100);
    
    label.text = @"hello world xxxxxxxxxxxxx";
    label.textColor = [UIColor systemRedColor];
    // 字体大小
    label.font = [UIFont systemFontOfSize: 24];
    // 居中对齐
    label.textAlignment = NSTextAlignmentCenter;
    
    label.shadowColor = [UIColor blackColor];
    // 阴影偏移  左, 下
    label.shadowOffset = CGSizeMake(10, 10);
    
    // 文字行数
    // 设为 0 自适应, 默认为 1
    label.numberOfLines = 0;
    
    // 行数不够时候自动缩小字体适应Label宽度
    label.adjustsFontSizeToFitWidth = YES;
    
    [self.view addSubview: label];
}
```

