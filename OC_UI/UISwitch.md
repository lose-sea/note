# UISwitch

创建 

**注意：UISwitch 大小固定，设置 frame 的宽高无效**

```objc
UISwitch *mySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(100, 100, 0, 0)];
[self.view addSubview:mySwitch];
```

常用属性 

```objc
// 设置/获取开关状态
mySwitch.on = YES;
BOOL state = mySwitch.isOn;

// 带动画切换状态
[mySwitch setOn:YES animated:YES];

// 开启时的颜色（默认绿色）
mySwitch.onTintColor = [UIColor blueColor];

// 关闭时的背景色
mySwitch.tintColor = [UIColor redColor];

// 圆形滑块颜色
mySwitch.thumbTintColor = [UIColor whiteColor];
```

通过开关的状态来调用事件

```objc
// 添加事件
[mySwitch addTarget:self
             action:@selector(switchChanged:)
   forControlEvents:UIControlEventValueChanged];

- (void)switchChanged:(UISwitch *)sender { 
    NSLog(@"开关的状态发生变化"); 
    if (sender.isOn) {
        NSLog(@"开启");
    } else {
        NSLog(@"关闭");
    }
}
```

这里调用事件的时候, 开关的状态是指改变后的状态