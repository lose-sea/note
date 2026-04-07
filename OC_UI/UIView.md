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

### 在不同阶段调用的方法

#### 

```objc
// 第一次程序加载视图时调用
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    UIView* view = [[UIView alloc] init];
    view.frame = CGRectMake(100, 100, 100, 200]; 
    view.backgroundColor = [UIColor orangeColor];
    self.view.backgroundColor = [UIColor blueColor];
    [self.view addSubview: view];
}
```

第一次程序加载视图时候会调用`viewDidLoad()`方法

当内存过低的时候会调用`didReceiveMemoryWarning()` 方法 

```objc
// 当内存过低时, 会发起警告, 调用此函数
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    ... 
}
```

视图分为: 

1. 显示前
2. 正在处于显示状态
3. 已经被隐藏 

当视图即将显示时候, 会调用`viewWillAppear: (BOOL)animated` 方法  

后面的BOOL类型参数表示是用动画切换后显示

```objc
// 当视图即将调用的时候, 会调用此函数
- (void)viewWillAppear:(BOOL)animated {
    NSLog(@"视图即将显示"); 
}
```

当视图已经显示到屏幕后的瞬间调用`viewDidAppear: (BOOL)animated` 函数 

参数: 表示是否用动画切换显示的 

当前状态已经显示到屏幕

```objc
// 当视图已经显示在屏幕后的瞬间调用吃函数
- (void)viewDidAppear: (BOOL)animated {
    NSLog(@"视图已经显示在屏幕");
}
```

当视图即将消失的时候, 会调用`viewWillDisappear: (BOOL)animated` 方法  

后面的BOOL类型参数表示是用动画切换后消失 

当前的状态: 视图还是显示在屏幕上的

```objc
// 当视图即将消失的时候, 会调用此函数
- (void)viewWillDisappear:(BOOL)animated {
    NSLog(@"视图即将消失"); 
}
```

 当视图已经消失的时候, 会调用`viewDidDisappear: (BOOL)animated` 方法  

后面的BOOL类型参数表示是否动画切换显示的

当前的状态: 视图已经从屏幕上消失

```objc
// 当视图已经消失的时候, 会调用此函数
- (void)viewDisappear:(BOOL)animated {
    NSLog(@"视图已经消失");
}
```

  

### `viewWillAppear:` 和 `viewDidLoad` 的区别

+ `viewWillAppear: `在每一次显示都会调用
+ `viewDidLoad ` 只有在第一次加载视图的时候才会调用

