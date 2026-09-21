# Spotify 项目仿写难点总结



## **`alpha <= 0.01` 时 UIKit 会跳过该视图的事件分发**。

这个是笔者在写一个项目的抽屉视图的时候遇到的一个问题, 

```objc
- (void) closeMenu {
    [self.menuViewController.view mas_remakeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.equalTo(self.view);
        make.right.mas_equalTo(self.view.mas_left);
        make.width.mas_equalTo(self.menuWidth);
        
    }];
    
    self.maskView.userInteractionEnabled = NO;
    
    [UIView animateWithDuration:0.3 animations:^{
            self.maskView.alpha = 0;

            [self.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            self.isMenuOpen = NO;
        }];
    
}


// 展开菜单视图
- (void) openMenu {
    [self.menuViewController.view mas_remakeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.mas_equalTo(self.view);
        make.left.mas_equalTo(self.view);
        make.width.mas_equalTo(self.menuWidth);
    }];
    self.maskView.userInteractionEnabled = YES;
    
    self.maskView.alpha = 0.01; 
    
//    [UIView animateWithDuration:0.3 animations:^{
//            self.maskView.alpha = 0.5;
//
//            [self.view layoutIfNeeded];
//        } completion:^(BOOL finished) {
//            self.isMenuOpen = YES;
//        }];
}
```

这里是两个方法, `openMenu` 方法和 `closeMenu` 方法,分别是打开菜单视图和关闭菜单视图 

这里笔者在菜单视图和主视图之间添加了一个遮罩层

```objc
- (void) setUpMaskView {
    self.maskView = [[UIView alloc] init];
    self.maskView.backgroundColor = [UIColor blackColor];
    self.maskView.alpha = 0;
    
    self.maskView.userInteractionEnabled = NO;
    
    [self.view insertSubview: self.maskView belowSubview: self.menuViewController.view];
    [self.maskView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.edges.equalTo(self.view);
    }];
}
```

同时还为遮罩层添加了手势 

```objc
- (void) setUpGesture {
    NSLog(@"添加手势");
    
    // 点击主视图上的遮罩层关闭菜单
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget: self action: @selector(closeMenu)];
    tap.delegate = self;
    [self.maskView addGestureRecognizer: tap];
}
```

这个手势的作用就是在菜单视图展开后可以通过点击遮罩层  maskView 来调用 `closeMenu` 方法收起菜单视图 

这里将 遮罩层 maskView 添加到了菜单视图的正下方,在开始添加之后设置 `self.maskView.userInteractionEnabled = NO;` 不可交互 



之后会调用`openMenu` 方法来打开菜单视图 ,但是打开之后笔者就发现,点击遮罩层无法收起菜单视图 ,当在打开菜单视图的时候同时将遮罩层的透明度设置为0.5, 又可以通过点击遮罩层收起菜单视图了, 于是这里笔者通过查询得知了, **`alpha <= 0.01` 的 UIView，在命中测试中被视为隐藏，不接收任何触摸事件。**



> ```objc
> + (void)animateWithDuration:(NSTimeInterval)duration
>                  animations:(void (^)(void))animations
>                  completion:(void (^)(BOOL finished))completion;
> ```
>
>  参数说明
>
> | 参数         | 含义                                          |
> | :----------- | :-------------------------------------------- |
> | `duration`   | 动画持续时长，单位秒。这里是 0.3 秒           |
> | `animations` | 一个 block，里面写**要改变的最终属性值**      |
> | `completion` | 动画结束后的回调，`finished` 表示是否正常播完 |



## 在导航栏添加头像按钮 

在导航栏中添加一个带图片的按钮(UIBarButtonItem)



## 一、两种创建方式对比

| 方式                             | 代码示例                                                     | 优点                           | 缺点                                                    | 适用场景                     |
| -------------------------------- | ------------------------------------------------------------ | ------------------------------ | ------------------------------------------------------- | ---------------------------- |
| **常规方式** initWithImage:      | [[UIBarButtonItem alloc] initWithImage:avatar style:UIBarButtonItemStylePlain target:self action:@selector(...)] | 代码简单                       | 1. 默认被 tint 成单色 2. 很难做成圆形 3. 系统会加内边距 | 普通图标（放大镜、设置等）   |
| **推荐方式** initWithCustomView: | 先创建 UIButton，再 initWithCustomView:                      | 可完全控制尺寸、圆形、点击区域 | 代码稍多                                                | **圆形头像、复杂自定义按钮** |

**结论**：想做圆形头像，必须用 UIButton + initWithCustomView:。

------

## 二、必须注意的关键点

### 1. 图片必须先缩小

+ 原图太大（几百/上千像素）时，按钮 intrinsicContentSize 过大。
+ 导航栏放不下 → 系统自动把 Item 折叠进右边的「三个点」溢出菜单。
+ **推荐尺寸**：32 ~ 40 点（常用 36）。

```objc
UIImage *avatar = [self croppedToSquare:original size:CGSizeMake(36, 36)];
```

#### 缩小图片

```objc
- (UIImage *)croppedToSquare:(UIImage *)image size:(CGSize)size {
    CGSize imgSize = image.size;
    CGFloat side = MIN(imgSize.width, imgSize.height);
    CGRect cropRect = CGRectMake((imgSize.width - side) / 2,
                                 (imgSize.height - side) / 2,
                                 side, side);

    CGImageRef cgImage = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    UIImage *cropped = [UIImage imageWithCGImage:cgImage
                                           scale:image.scale
                                     orientation:image.imageOrientation];
    CGImageRelease(cgImage);

    // 缩放到目标尺寸
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    [cropped drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}
```





### 2. 必须设置 UIImageRenderingModeAlwaysOriginal

否则系统会把图片当成模板，用 tintColor 染色，照片会变成一片黑色。

Objective-C

```
avatar = [avatar imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
```

### 3. UIButton 必须设置 frame

initWithCustomView: 依赖 frame 来确定尺寸，不设置可能变成 0 大小。



```
imageButton.frame = CGRectMake(0, 0, 36, 36);
```

### 4. 做圆形头像的正确写法



```
imageButton.clipsToBounds = YES;
imageButton.layer.cornerRadius = 18;   // 必须 = 宽高的一半
```

同时建议让图片填满按钮：



```
imageButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
imageButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
imageButton.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
```

### 5. 系统会强制调整尺寸（重要现象）

即使你设置了 36×36，在 Lookin 里经常看到变成 **44×44**；设置 44×44 可能变成 **52×44**。

原因：

+ UIBarButtonItem 有最小交互尺寸要求（约 44pt，保证点击热区）。
+ 系统会自动给 customView 加左右 padding。

这是正常行为，不是 bug。视觉圆形仍按你设置的尺寸显示，只是外层容器被撑大了。

