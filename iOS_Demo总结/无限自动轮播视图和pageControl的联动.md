# 无限自动轮播视图和pageControl的联动

目前为止, 在zara和share的项目中都用到了无限轮播视图和pageControl的结合, 通过定时器来控制视图自动切换,同时还要是pageControl跟随scrollView同步更新, 这就需要用到scrollView的代理

在练习zara和share的时候, 遇到实现无线轮播视图和pageControl的时候都遇到了困难, 例如scrollView的偏移量(scrollView.contentOffset). pageControl 的索引的设置, 在滑动scrollView的时候要停止stop, 滑动完成之后再开启定时器 等, 解决这些困难的时候都花费了很多时间, 下面将这一知识点做一总结和整理

### scrollView 的添加与配置

首先创建UIScrolView并将其添加到视图

```objc
- (void) setScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    // 按页翻动
    self.scrollView.pagingEnabled = YES;
    // 允许滑动
    self.scrollView.scrollEnabled = YES;
    
    [self.contentView addSubview: self.scrollView];
    [self.scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.mas_equalTo(self.contentView);
    }];
    self.scrollView.delegate = self;
}
```

然后需要设置画布(scrollView.contentView)的大小 

因为Masonry在设置完约束之后,是没有立即生效的, 所以此时的 scrollView的宽和高都是 0 , 要使用scrollView 的width 和 height 来设置画布的大小,需要使用`  [self.scrollView layoutIfNeeded]; `方法来强制属性布局,来使约束强制生效  

在添加视图的时候,我们需要实现无限轮播的效果, 就需要在添加轮播视图的图片数组中添加临时界面,在开头插入一张要展示的界面的最后一张图片, 在末尾插入一张要展示的第一张图片, 之后在滑动到开头的临时界面的时候我们可以直接跳转到最后一张要展示的界面, 当滑动到默认的临时界面的时候直接跳转到第一张要展示的界面的, 这样在视觉效果上就实现了无限轮播

然后接可以向滚动视图中添加视图了, 注意这里的视图添加的时候需要计算好偏移量, 一般是每个视图的宽度设置为scrollView的width, 然后是每个视图在添加的时候, x坐标就偏移几个scrollView.width

```objc
- (void) configureData:(NSMutableArray *)images {
    // 设置总页数
    self.pageControl.numberOfPages = images.count - 2;
    
    self.scrollView.contentSize = CGSizeMake(self.contentView.bounds.size.width * images.count, self.contentView.bounds.size.height);
    self.scrollView.contentOffset = CGPointMake(self.contentView.bounds.size.width, 0);
    
    for (int i = 0; i < images.count; i++) {
        UIImage* image = images[i];
        UIImageView* iView = [[UIImageView alloc] initWithImage: image];
        iView.contentMode = UIViewContentModeScaleAspectFill;
        iView.clipsToBounds = YES;
        [self.scrollView addSubview:iView];
        [iView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.mas_equalTo(self.scrollView).offset(self.contentView.bounds.size.width * i);
            make.top.mas_equalTo(self.scrollView);
            make.width.height.mas_equalTo(self.contentView);
        }];
    }
}
```

在添加imageView的时候, 我设置了图片等比填充和裁剪边缘超出部分,这样就会使图片不会被拉伸变形

```objc
iView.contentMode = UIViewContentModeScaleAspectFill;
iView.clipsToBounds = YES;
```

### pageControl 的添加与配置

pageControl 用于显示当前轮播图所在的页码，需要注意的是 `numberOfPages` 要设置为图片数组去掉首尾两张临时图片之后的真实数量

```objc
- (void) setpageControl {
    self.pageControl = [[UIPageControl alloc] init];
    
    self.pageControl.currentPageIndicatorTintColor = [UIColor redColor];
    self.pageControl.pageIndicatorTintColor = [UIColor grayColor];
    
    // 当只有一页时隐藏 pageControl
    self.pageControl.hidesForSinglePage = YES;
    
    [self.contentView addSubview: self.pageControl];
    [self.pageControl mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.mas_equalTo(self.contentView);
        make.bottom.mas_equalTo(self.contentView).offset(-10);
        make.height.mas_equalTo(30);
        make.width.mas_equalTo(200);
    }];
    self.pageControl.currentPage = 0;
    
    // 监听 pageControl 点击事件
    [self.pageControl addTarget: self action: @selector(pageChange) forControlEvents: UIControlEventValueChanged];
}
```

在 `configureData:` 中设置真实页数（去掉首尾两张临时图片）

为什么说不在创建的时候直接设置总页数呢, 是因为在我们创建pageControl的时候,homeModel还没有接收外部传入的值, 此时self.homeModel为nil, homeModel.scrollViewImages.count 为 0 

```objc
self.pageControl.numberOfPages = images.count - 2;
```

------

### pageControl 变化时更新 scrollView

当用户点击 pageControl 切换页码时，需要同步更新 scrollView 的偏移量。注意 scrollView 中 index 为 0 的位置是临时图片，所以真实第一张图片的偏移量是 `scrollView.bounds.size.width * 1`，因此需要对 pageControl 的 index 加 1 来计算出正确的偏移量

```objc
- (void) pageChange {
    [self stopTimer];
    
    NSInteger index = self.pageControl.currentPage;
    [self.scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (index + 1), 0) animated: YES];
    
    [self setTimer];
}
```

------

### scrollView 滑动时更新 pageControl

scrollView 在滑动过程中需要实时更新 pageControl 的当前页码，这里通过 `scrollViewDidScroll:` 代理方法来实现

首先需要一个计算当前页码的方法，通过当前偏移量除以单页宽度来获取，加上 `0.5 * width` 是为了让翻页时机在滑过一半时触发，视觉效果更自然

```objc
- (CGFloat) currentPage {
    NSInteger page = (self.scrollView.contentOffset.x + 0.5 * self.scrollView.bounds.size.width) / self.contentView.bounds.size.width;
    return page;
}
```

然后在 `scrollViewDidScroll:` 中更新 pageControl，注意 scrollView 中的 page 比 pageControl 的 index 多 1（因为开头有一张临时图片），所以要减 1。另外还需要处理边界情况，当滑动到临时图片区域时，pageControl 要显示对应的真实页码

```objc
- (void) scrollViewDidScroll:(UIScrollView *)scrollView {
    NSInteger page = [self currentPage] - 1;
    // 滑动到末尾的临时图片时，pageControl 显示第 0 页
    if (page == self.homeModel.scrollImages.count - 2) {
        page = 0;
    // 滑动到开头的临时图片时，pageControl 显示最后一页
    } else if (page == -1) {
        page = self.pageControl.numberOfPages - 1;
    }
    self.pageControl.currentPage = page;
}
```

------

### 定时器的设置与停止

定时器用于控制轮播图自动翻页，每隔一定时间触发一次 `nextPage` 方法。在创建定时器之前先判断是否已经存在，避免重复创建导致翻页速度异常

```objc
- (void) setTimer {
    if (self.timer == nil) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(nextPage) userInfo:nil repeats:YES];
    }
}

- (void) stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}
```

`nextPage` 方法负责计算下一页的偏移量并滚动到对应位置，不需要手动修改 pageControl，因为 `scrollViewDidScroll:` 会自动同步。这里直接让 scrollView 往后滚动一页，当滚动到末尾临时图片时，由 `scrollViewDidEndScrollingAnimation:` 无动画跳回真实的第一张

```objc
- (void) nextPage {
    NSInteger page = self.pageControl.currentPage + 1;
    // 不重置 page，让 scrollView 继续往后滚动到末尾临时图片
    // scrollViewDidEndScrollingAnimation 会处理无动画跳回逻辑
    [self.scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (page + 1), 0) animated: YES];
}
```

------

### 用户滑动时停止定时器，结束后重新开启

用户手动滑动时需要停止定时器，避免自动翻页和手动滑动冲突。通过 `scrollViewWillBeginDragging:` 在用户开始滑动时停止定时器，通过 `scrollViewDidEndDecelerating:` 在滑动结束减速完成后重新开启

```objc
// 用户开始滑动时停止定时器
- (void) scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self stopTimer];
}

// 用户滑动结束减速完成后重新开启定时器
- (void) scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    NSInteger page = [self currentPage];
    if (page == 0) {
        [scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (self.homeModel.scrollImages.count - 2), 0) animated: NO];
    } else if (page == self.homeModel.scrollImages.count - 1) {
        [scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * 1, 0) animated: NO];
    }
    [self setTimer];
}
```

------

### 无动画跳转实现无限循环

当代码触发的动画滚动结束时（`scrollViewDidEndScrollingAnimation:`），需要判断当前是否滚到了临时图片的位置，如果是则无动画直接跳转到对应的真实图片，由于没有动画，用户感知不到跳转，视觉上就实现了无限循环

```objc
- (void) scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    NSInteger page = [self currentPage];
    // 滚到了开头的临时图片，无动画跳转到真实的最后一张
    if (page == 0) {
        [scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (self.homeModel.scrollImages.count - 2), 0) animated: NO];
    // 滚到了末尾的临时图片，无动画跳转到真实的第一张
    } else if (page == self.homeModel.scrollImages.count - 1) {
        [scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * 1, 0) animated: NO];
    }
}
```

下面用展示设置动画的前后效果对比

设置有动画

<img src="/Users/lose_sea/Desktop/pintures/CleanShot 2026-05-24 at 12.02.29.gif" alt="CleanShot 2026-05-24 at 12.02.29" style="zoom:50%;" />

设置无动画

<img src="/Users/lose_sea/Desktop/pintures/CleanShot 2026-05-24 at 12.01.23.gif" alt="CleanShot 2026-05-24 at 12.01.23" style="zoom: 50%;" />

可以看到, 在设置有动画就会导致到达临时页的时候有一个向前翻页的动画, 而关闭动画之后就直接跳转,显得更加顺畅