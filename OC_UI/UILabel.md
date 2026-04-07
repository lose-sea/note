# UILabel

`UILabel` 是 iOS 开发（UIKit 框架）中最常用的控件之一，专门用于在界面上**显示只读的文本**。

## 常用属性 



| 属性                        | 类型               | 说明         |
| --------------------------- | ------------------ | ------------ |
| `text`                      | NSString           | 文本内容     |
| `font`                      | UIFont             | 字体         |
| `textColor`                 | UIColor            | 文字颜色     |
| `textAlignment`             | NSTextAlignment    | 对齐方式     |
| `numberOfLines`             | NSInteger          | 最大行数     |
| `lineBreakMode`             | NSLineBreakMode    | 换行模式     |
| `attributedText`            | NSAttributedString | 富文本       |
| `shadowColor`               | UIColor            | 阴影颜色     |
| `shadowOffset`              | CGSize             | 阴影偏移     |
| `adjustsFontSizeToFitWidth` | BOOL               | 自动缩小字体 |

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

### 文字多行显示

```objc
// 设定label文字显示的行数, 默认是 1 行来显示
// 其他 > 0 的行数, 文字会尽量按照设定行数来显示
// 如果设为0, 会自动计算需要的行数
label.numberOfLines = 0; 
label.numberOfLines = 2; // 最多两行
```

### 自适应

```objc
// 根据内容自适应大小 (label的大小发生变化,刚好可以容纳文字)
[label sizeToFit];

// 自动缩小字体适应宽度
label.adjustsFontSizeToFitWidth = YES;
```
