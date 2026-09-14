# **`alpha <= 0.01` 时 UIKit 会跳过该视图的事件分发**。

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



之后会调用`openMenu` 方法来打开菜单视图 ,但是打开之后笔者就发现,点击遮罩层无法收起菜单视图 ,当在打开菜单视图的时候同时将遮罩层的透明度设置为0.5, 又可以通过点击遮罩层收起菜单视图了, 于是这里笔者通过查询得知了, **`alpha <= 0.01` 时 UIKit 会跳过该视图的事件分发**, 当UIView的alpha小于等于 0.01, 这个UIView 就不会接受点击