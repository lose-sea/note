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

