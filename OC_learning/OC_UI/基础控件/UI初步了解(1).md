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



# UIButton

## 创建

**如果需要让按钮显示图片原色, 需要选择自定义类型的按钮**

自动定义类型的按钮 (图片)

```objc
- (void) createImageBtn {
    // 创建一个自定义类型的Btn
    UIButton* btnImage = [UIButton buttonWithType: UIButtonTypeCustom];
    btnImage.frame = CGRectMake(100, 200, 100, 100);
    UIImage* icon01 = [UIImage imageNamed: @"btn01.png"];
    UIImage* icon02 = [UIImage imageNamed: @"btn02.png"];
    
    // 设置按钮图片
    // p1: 显示的图片对象
    // p2: 控件的状态
    [btnImage setImage: icon01 forState: (UIControlStateNormal)];
    [btnImage setImage: icon02 forState :UIControlStateHighlighted];
    [self.view addSubview: btnImage]; 
}
```

创建系统类型按钮并设置基础属性

```objc
// 系统类型按钮 
UIButton* btn = [UIButton buttonWithType: UIButtonTypeSystem];
btn.frame = CGRectMake(100, 400, 100, 100); 
btn.backgroundColor = [UIColor systemCyanColor];
```

设置按钮文字内容

```objc
// 设置按钮的文字内容
// p1: 字符床类型, 显示到按钮上的文字
// p2: 设置文字显示的状态类型: UIControlStateNormal --> 正常状态
[btn setTitle: @"btn" forState: UIControlStateNormal];

// 显示文字类型: UIControlStateHighlighted --> 按下状态
[btn setTitle: @"btn is pressed" forState: UIControlStateHighlighted]; 
// 设置按钮文字颜色
[btn setTitleColor: [UIColor greenColor] forState: UIControlStateNormal];


// 设置按钮风格颜色
// 设置之后, 所有的状态都按照此风格 
// 优先级低于 setTitleColor
[btn setTintColor: [UIColor whiteColor]];

// title.Label: UILabel 空间
// 文字字体大小
btn.titleLabel.font = [UIFont systemFontOfSize: 18]; 

// 按钮背景颜色
// 这里不是按钮的颜色,只是包裹按钮文字的Label的颜色
btn.titleLabel.backgroundColor = [UIColor redColor]; 
```

### 为按钮添加事件



> 向按钮添加事件函数
>
> 1. p1: "谁" 来实现事件函数, 实现的对象就是谁
> 2. p2: @selctor(pressBtn): 函数对象, 当按钮满足p3事件类型时, 系统调用函数
> 3. p3: UIControlEvent: 事件处理函数模型
>
> 
>
> 事件调用的状态
>
> 1.  UIControlEventTouchUpInside: 当手指离开屏幕时并且手指的位置在按钮范围内触发事件函数
> 2.  UIControlEventTouchUpOutside: 当手指离开屏幕时并且手指的位置在按钮范围外触发事件函数 (按下在范围内, 松开在范围外)
> 3.  UIControlEventTouchDown: 当手指触碰到按钮上时候触发
> 4.  UIControlEventTouchDown: 当手指多次连续触碰到按钮 (双击)

```objc
[btn addTarget: self action: @selector(pressBtn) forControlEvents: UIControlEventTouchUpInside];
[btn addTarget: self action: @selector(touchDown) forControlEvents: UIControlEventTouchDown];

// 事件方法
- (void) touchDown {
   NSLog(@"touched");
} 
- (void) pressBtn {
   NSLog(@"Btn pressed");
}
```

可以通过为按钮设置标签来为事件添加参数调用事件

```objc
// 设置按钮的标记值
btn.tag = 101;
btn02.tag = 102; 

// 带参数
- (void) pressBtn: (UIButton*) btn {
   if (btn.tag == 101) {
       NSLog(@"btn01 is pressed");
   } else if (btn.tag == 102) {
       NSLog(@"btn02 is pressed");
   }
}
```

# UIView

UIView 是iOS视图对象, 是显示在屏幕上的所有的对象的基础类, 所有显示在屏幕上的对象一定继承于UIView

UIView 是一个矩形对象, 有背景属性, 可以显示, 有层级关系

### 创建

```objc
UIView* view = [[UIView alloc] init];
view.frame = CGRectMake(100, 100, 100, 200);
[self.view addSubview: view];

view.backgroundColor = [UIColor orangeColor];

self.view.backgroundColor = [UIColor blueColor];
```

### 将新建的视图添加到父亲视图上

1. 将新建的视图显示到屏幕上
2. 将视图对象作为父亲视图的子视图管理起来

```objc
// 将新建的视图添加到父亲视图上
// 1. 将新建的视图显示到屏幕上
// 2. 将视图作为父亲视图的子视图管理起来
[self.view addSubview: view];
```

### 隐藏视图 

属性 hidden 为YES时隐藏, 为NO时不隐藏, 默认为NO

```objc
view.hidden = YES; 
```

#### 设置透明度

1. alpha = 1 不透明

2. alpha = 0 透明

3. alpha = 0.5 半透明

```objc
view.alpha = 0.5;
```

### 从父视图删除

```objc
// 将自己从父亲视图删除
[view removeFromSuperview];
```

## UIView的层级关系

​     **sunviews 是管理所有self.view 的子视图的数组**

​	 subview是将添加的视图按照添加顺序存储的, (先添加的在最下面), 但是在subviews中索引是靠前的
 	bringSubviewToBack 是将子视图移动到 subviews[0] (subviews 的第一个),

```objc
- (void) viewStage {
    UIView* view01 = [[UIView alloc] init];
    view01.frame = CGRectMake(100, 100, 150, 150);
    view01.backgroundColor = [UIColor blueColor];
    
    UIView* view02 = [[UIView alloc] init];
    view02.frame = CGRectMake(125, 125, 150, 150);
    view02.backgroundColor = [UIColor orangeColor];
    
    UIView* view03 = [[UIView alloc] init];
    view03.frame = CGRectMake(150, 150, 150, 150);
    view03.backgroundColor = [UIColor greenColor];
```



```objc
// 哪一个视图先添加到父亲视图上, 就先绘制哪一个视图
[self.view addSubview: view01];
[self.view addSubview: view02];
[self.view addSubview: view03];
```



```objc
// 将某一个视图调整到最前面显示
//    [self.view bringSubviewToFront: view01];
//
//    // 将某一个视图调整到最后面
//    [self.view sendSubviewToBack: view02];
    
    // sunviews 管理所有self.view 的子视图的数组
    // subview是将添加的视图按照添加顺序存储的, (先添加的在最下面), 但是在subviews中索引是靠前的
    // bringSubviewToBack 是将子视图移动到 subviews[0] (subviews 的第一个),
    [self.view sendSubviewToBack: view02];
    // sunviews 管理所有self.view 的子视图的数组
//    UIView* viewFront = self.view.subviews[2];
    
    UIView* viewBack = self.view.subviews[0];
    
    // 从父亲视图删除
    [view02 removeFromSuperview];
    
    if (viewBack == view02) {
        NSLog(@"相等");
    }
}
```

