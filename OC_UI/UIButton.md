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
> 3.  p3: UIControlEvent: 事件处理函数模型
>
> 
>
> 事件调用的状态
>
> 1.  UIControlEventTouchUpInside: 当手指离开屏幕时并且手指的位置在按钮范围内触发事件函数
> 2.  UIControlEventTouchUpOutside: 当手指离开屏幕时并且手指的位置在按钮范围外触发事件函数 (按下在范围内, 松开在范围外)
> 3.  UIControlEventTouchDown: 当手指触碰到按钮上时候触发
> 4. UIControlEventTouchDown: 当手指多次连续触碰到按钮 (双击)

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

