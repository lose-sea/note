# share项目总结

## 登录与注册界面

在登录注册界面,难点大概就是要实现点击账号密码的输入框,键盘弹出的时候, 需要让整个界面上移, 收起键盘,需要让界面恢复,这里可以使用键盘的通知监听,在键盘弹出个收起的时候调用方法来操作界面的偏移

设置监听

```objc
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
```

设置键盘弹出和收起的事件

```objc
- (void)keyboardWillShow:(NSNotification *)notification{
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = keyboardFrame.size.height;
    [UIView animateWithDuration:0.25 animations:^{
        self.signin.transform = CGAffineTransformMakeTranslation(0, -keyboardHeight / 3.0);
    }];
}
 
- (void)keyboardWillHide:(NSNotification *)notification{
    [UIView animateWithDuration:0.25 animations:^{
        self.signin.transform = CGAffineTransformIdentity;
    }];
}
```

在`keyboardWillShow:`方法中,

```objc
CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = keyboardFrame.size.height;
```

获取键盘的高度,

然后使用transform 来移动界面,笔者在实现这部分功能的时候,最初是直接通过修改self.view.frame 来控制界面的上移, 但这样会因为frame 和 AutoLayout 冲突,导致界面卡死等问题, 后来改用franform 解决

然后就是当登录成功后,就需要跳转到主页面, 我是采取直接替换更视图控制器的方法来实现的 

将根视图控制器切换为 UITabBarController 

```objc
// 登陆成功, 跳转至主界面
- (void) switchToHomepage {
    
    SceneDelegate* sceneDelegate = (SceneDelegate*)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject.delegate;    
    HomepageController* homePageController = [[HomepageController alloc] init];
        UINavigationController* homeNav = [[UINavigationController alloc] initWithRootViewController: homePageController];
        homePageController.tabBarItem = [[UITabBarItem alloc] initWithTitle: @"首页" image: [UIImage systemImageNamed: @"house"] selectedImage: [UIImage systemImageNamed: @"house.fill"]];
        
        SearchPageController* searchPageController = [[SearchPageController alloc] init];
        UINavigationController* searchNav = [[UINavigationController alloc] initWithRootViewController: searchPageController];
        searchPageController.tabBarItem =  [[UITabBarItem alloc] initWithTitle: @"搜索" image: [UIImage systemImageNamed: @"magnifyingglass"] selectedImage: [UIImage systemImageNamed: @"magnifyingglass"]];
        
        ArticlesCategoryController* articlesCategoryController = [[ArticlesCategoryController alloc] init];
        UINavigationController* articlesCategoryNav = [[UINavigationController alloc] initWithRootViewController: articlesCategoryController];
        articlesCategoryController.tabBarItem =  [[UITabBarItem alloc] initWithTitle: @"文章分类" image: [UIImage systemImageNamed: @"square.and.pencil"] selectedImage: [UIImage systemImageNamed: @"square.and.pencil.fill"]];
        
        ActivityController* activityController = [[ActivityController alloc] init];
        UINavigationController* activityNav = [[UINavigationController alloc] initWithRootViewController: activityController];
        activityController.tabBarItem =  [[UITabBarItem alloc] initWithTitle: @"活动" image: [UIImage systemImageNamed: @"trophy"] selectedImage: [UIImage systemImageNamed: @"trophy.fill"]];
        
        
        MyPageController* myPageController = [[MyPageController alloc] init];
        UINavigationController* myPageControllerNav = [[UINavigationController alloc] initWithRootViewController: myPageController];
        myPageController.tabBarItem =  [[UITabBarItem alloc] initWithTitle: @"我的" image: [UIImage systemImageNamed: @"person"] selectedImage: [UIImage systemImageNamed: @"person.fill"]];
        
        
        UITabBarController* tabbarController = [[UITabBarController alloc] init];
        tabbarController.viewControllers = @[homeNav, searchNav, articlesCategoryNav, activityNav, myPageControllerNav];
    sceneDelegate.window.rootViewController = tabbarController;
}
```

## 首页  

在首页界面, 有一个无限视图, 还要展示文章目录, 需要实现当滑动文章目录时候,无限视图也需要同步滑动, 这里就可以想到使用 UITableView 结合自定义 cell 来实现

创建一个自定义cell, 在其中加入一个 UIScrollView, 和 一个定时器, 无限视图的内容笔者在之前的有一篇博客详细讲解, 这里就不再讲解

```objc
#import "ScrollViewCell.h"

@implementation ScrollViewCell
- (instancetype) initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setScrollView];
        [self setpageControl];
        [self setTimer];
    }
    return self;
}
// 添加 scrollView
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

- (void) scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    NSInteger page = [self currentPage];
    if (page == 0) {
        [scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (self.homeModel.scrollImages.count - 2), 0) animated: NO];
    } else if (page == self.homeModel.scrollImages.count - 1) {
        [scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * 1, 0) animated: NO];
    }
}

// 手动滑动
- (void) scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    NSInteger page = [self currentPage];
    if (page == 0) {
        [scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (self.homeModel.scrollImages.count - 2),  0) animated: NO];
    } else if (page == self.homeModel.scrollImages.count - 1) {
        [scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * 1, 0) animated: NO];
    }
    NSInteger offset = self.scrollView.contentOffset.x / self.contentView.bounds.size.width;
    if (offset == self.homeModel.scrollImages.count - 1) {
        [self.scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width, 0)];
    }
    [self setTimer];
}

// 添加 pageControl
- (void) setpageControl {
    self.pageControl = [[UIPageControl alloc] init];
    
    self.pageControl.currentPageIndicatorTintColor = [UIColor redColor];
    self.pageControl.pageIndicatorTintColor = [UIColor grayColor];
    
    // 当只有一页时隐藏pgaeControl
    self.pageControl.hidesForSinglePage = YES;
    
    [self.contentView addSubview: self.pageControl];
    [self.pageControl mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.mas_equalTo(self.contentView);
        make.bottom.mas_equalTo(self.contentView).offset(-10);
        make.height.mas_equalTo(30);
        make.width.mas_equalTo(200);
    }];
    self.pageControl.currentPage = 0;
    
    [self.pageControl addTarget: self action: @selector(pageChange) forControlEvents: UIControlEventValueChanged];
}

#pragma mark - pageControl改变滑动scrollView
- (void) pageChange {
    [self stopTimer];
    
    NSInteger index = self.pageControl.currentPage;
    [self.scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (index + 1), 0) animated: YES];
    
    [self setTimer];
}


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

#pragma mark - 滑动scrollView时更新pageControl
// 获取当前页码
- (CGFloat) currentPage {
    NSInteger page = (self.scrollView.contentOffset.x + 0.5 * self.scrollView.bounds.size.width) / self.contentView.bounds.size.width;
    return page;
}

// 滑动scrollView 更新pageControl
- (void) scrollViewDidScroll:(UIScrollView *)scrollView {
    NSInteger page = [self currentPage] - 1;
    if (page == self.homeModel.scrollImages.count - 2) {
        page = 0;
    } else if (page == -1) {
        page = self.pageControl.numberOfPages - 1;
    }
    self.pageControl.currentPage = page;
}

- (void) scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self stopTimer];
    NSLog(@"开始滑动");
}


#pragma mark - 定时器
- (void) setTimer {
    if (self.timer == nil) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval: 1 target: self selector: @selector(nextPage) userInfo: nil repeats: YES];
    }
    
    //添加到 CommonModes，滑动时也能触发
    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode: NSRunLoopCommonModes];
}

    
- (void) stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (void) nextPage {
//    NSLog(@"=== nextPage 开始 ===");
//    NSLog(@"1. 改变前 pageControl.currentPage = %ld", self.pageControl.currentPage);
    NSInteger page = self.pageControl.currentPage + 1;
    if (page == self.pageControl.numberOfPages) {
        page = 0;
    }
    self.pageControl.currentPage = page;
    if (page == 0) {
        [self.scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (page + 1), 0) animated: NO];
    } else {
        [self.scrollView setContentOffset: CGPointMake(self.scrollView.bounds.size.width * (page + 1), 0) animated: YES];
    }
}
- (void)awakeFromNib {
    [super awakeFromNib];
    // Initialization code
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    // Configure the view for the selected state
}
@end
```

在文章展示的部分, 也是采用了一个自定义cell 来显示, 包括文章的封面, 标题, 作者, 简介, 点赞量, 浏览量, 收藏量 

```objc
#import "CustomCell.h"

@implementation CustomCell

- (instancetype) initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle: style  reuseIdentifier: reuseIdentifier];
    if (self) {
        [self setUI];
    }
    return self;
}

- (void) setUI {
    // 图片
    self.iView = [[UIImageView alloc] init];
    self.titleLabel = [[UILabel alloc] init];
    self.massageLabel = [[UILabel alloc] init];
    self.authorLabel = [[UILabel alloc] init];
    
    self.likeButton = [UIButton buttonWithType: UIButtonTypeCustom];
    self.saveButton = [UIButton buttonWithType: UIButtonTypeCustom];
    
    UIImage* like01 = [UIImage systemImageNamed: @"heart"];
    UIImage* like02 = [UIImage systemImageNamed: @"heart.fill"];
    if (self.article.isLike == NO) {
        [self.likeButton setImage: like01 forState: UIControlStateNormal];
    } else {
        [self.likeButton setImage: like02 forState: UIControlStateNormal];
    }
    self.viewImageView = [[UIImageView alloc] initWithImage: [UIImage systemImageNamed: @"eye"]];
    UIImage* save01 = [UIImage systemImageNamed: @"star"];
    UIImage* save02 = [UIImage systemImageNamed: @"star.fill"];
    if (self.article.isSave == YES) {
        [self.saveButton setImage: save01 forState: UIControlStateNormal];
    } else {
        [self.saveButton setImage: save02 forState: UIControlStateNormal];
    }
    
    [self.likeButton addTarget: self action: @selector(pressLikeButton) forControlEvents: UIControlEventTouchUpInside];
    [self.saveButton addTarget: self action: @selector(pressSaveButton) forControlEvents: UIControlEventTouchUpInside];
    
    self.likeLabel = [[UILabel alloc] init];
    self.viewLabel = [[UILabel alloc] init];
    self.saveLabel = [[UILabel alloc] init];
    
    [self.contentView addSubview: self.iView];
    [self.iView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.mas_equalTo(self.contentView).offset(20);
        make.top.mas_equalTo(self.contentView).offset(20);
        make.width.mas_equalTo(100);
        make.height.mas_equalTo(110);
    }];
    
    [self.contentView addSubview: self.titleLabel];
    self.titleLabel.font = [UIFont systemFontOfSize:22];
    [self.titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.mas_equalTo(self.contentView).offset(10);
        make.left.mas_equalTo(self.iView.mas_right).offset(20);
        make.height.mas_equalTo(25);
        make.right.mas_equalTo(self.contentView).offset(-20);
    }];
    
    [self.contentView addSubview: self.authorLabel];
    self.authorLabel.font = [UIFont systemFontOfSize:17];
    [self.authorLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.mas_equalTo(self.titleLabel.mas_bottom);
            make.left.mas_equalTo(self.iView.mas_right).offset(20);
            make.height.mas_equalTo(30);
            make.right.mas_equalTo(self.contentView).offset(-20);
    }];
    
    [self.contentView addSubview: self.massageLabel];
    self.massageLabel.font = [UIFont systemFontOfSize:15];
    [self.massageLabel mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.mas_equalTo(self.authorLabel.mas_bottom);
            make.left.mas_equalTo(self.iView.mas_right).offset(20);
            make.height.mas_equalTo(60);
            make.right.mas_equalTo(self.contentView).offset(-20);
        }];
    
    [self.contentView addSubview: self.likeButton];
    [self.likeButton mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.mas_equalTo(self.massageLabel.mas_bottom);
            make.left.mas_equalTo(self.iView.mas_right).offset(20);
            make.height.mas_equalTo(20);
            make.width.mas_equalTo(20);
    }];
    
    [self.contentView addSubview: self.likeLabel];
    self.likeLabel.font = [UIFont systemFontOfSize:14];
    [self.likeLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.mas_equalTo(self.massageLabel.mas_bottom);
        make.left.mas_equalTo(self.likeButton.mas_right).offset(10);
        make.width.mas_equalTo(40);
        make.height.mas_equalTo(20);
    }];
    
    [self.contentView addSubview: self.viewImageView];
    [self.viewImageView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.mas_equalTo(self.massageLabel.mas_bottom);
            make.left.mas_equalTo(self.likeLabel.mas_right).offset(20);
            make.height.mas_equalTo(20);
            make.width.mas_equalTo(20);
    }];
    
    [self.contentView addSubview: self.viewLabel];
    self.viewLabel.font = [UIFont systemFontOfSize:14];
    [self.viewLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.mas_equalTo(self.massageLabel.mas_bottom);
        make.left.mas_equalTo(self.viewImageView.mas_right).offset(10);
        make.width.mas_equalTo(40);
        make.height.mas_equalTo(20);
    }];
    
    [self.contentView addSubview: self.saveButton];
    [self.saveButton mas_makeConstraints:^(MASConstraintMaker *make) {
            make.top.mas_equalTo(self.massageLabel.mas_bottom);
            make.left.mas_equalTo(self.viewLabel.mas_right).offset(20);
            make.height.mas_equalTo(20);
            make.width.mas_equalTo(20);
    }];

    [self.contentView addSubview: self.saveLabel];
    self.saveLabel.font = [UIFont systemFontOfSize:14];
    [self.saveLabel mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.mas_equalTo(self.massageLabel.mas_bottom);
        make.left.mas_equalTo(self.saveButton.mas_right).offset(10);
        make.width.mas_equalTo(40);
        make.height.mas_equalTo(20);
    }];
}

- (void) pressLikeButton {
    NSLog(@"点击likeButton");
    self.article.isLike = !self.article.isLike;
    if (self.article.isLike == YES) {
        self.article.likeCount++;
    } else {
        self.article.likeCount--;
    }
    [self configureWithArticle: self.article];
}


- (void) pressSaveButton {
    NSLog(@"点击saveButton");
    self.article.isSave = !self.article.isSave;
    if (self.article.isSave == YES) {
        self.article.saveCount++;
    } else {
        self.article.saveCount--;
    }
    [self configureWithArticle: self.article];
}

- (void) configureWithArticle:(article *)article {
    self.iView.image = article.image;
    self.titleLabel.text = article.name;
    self.authorLabel.text = article.author;
    self.massageLabel.text = article.massage;
    UIImage* like01 = [UIImage systemImageNamed: @"heart"];
    UIImage* like02 = [UIImage systemImageNamed: @"heart.fill"];
    if (self.article.isLike == NO) {
        [self.likeButton setImage: like01 forState: UIControlStateNormal];
    } else {
//        self.article.likeCount++;
        [self.likeButton setImage: like02 forState: UIControlStateNormal];
    }
    
    UIImage* save01 = [UIImage systemImageNamed: @"star"];
    UIImage* save02 = [UIImage systemImageNamed: @"star.fill"];
    if (self.article.isSave == NO) {
        [self.saveButton setImage: save01 forState: UIControlStateNormal];
    } else {
        [self.saveButton setImage: save02 forState: UIControlStateNormal];
    }
    self.likeLabel.text =  [NSString stringWithFormat: @"%ld", (long)article.likeCount];
    self.viewLabel.text =  [NSString stringWithFormat: @"%ld", (long)article.viewCount];
    self.saveLabel.text =  [NSString stringWithFormat: @"%ld", (long)article.saveCount];
}
 
- (void)awakeFromNib {
    [super awakeFromNib];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
}

@end
```

在cell中, 我设置了一个article类型的属性, 这个是我设置的文章类, 包括封面, 标题, 作者, 简介, 点赞量, 浏览量, 收藏量 等属性, 方便在tableView 加载数据的时候, 可以直接传递一个article 类型的对象来设置cell的展示内容

```objc
#import "HomepageController.h"

@interface HomepageController ()

@end

@implementation HomepageController

- (void)viewDidLoad {
    [super viewDidLoad];
//    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"首页"; 
    // Do any additional setup after loading the view.
    [self initData];
    [self setHomepageView];
    
}

- (void) setHomepageView {
    self.homepageView = [[HomepageView alloc] init];
    [self.view addSubview: self.homepageView];
    self.homepageView.tableView.backgroundColor = [UIColor systemCyanColor]; 
    [self.homepageView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.right.top.bottom.mas_equalTo(self.view);
    }];
    self.homepageView.tableView.delegate = self;
    self.homepageView.tableView.dataSource = self;
}

- (void) initData {
    self.homeModel = [[HomepageModel alloc] init];
    self.homeModel.articles = [[NSMutableArray alloc] init];
    article* a = [[article alloc] initWitImage: [UIImage imageNamed: @"1.jpg"] Name: @"假日" autoor: @"share小白" massage: @"这个家伙很懒, 什么也没有留下"];
    article* a1 = [[article alloc] initWitImage: [UIImage imageNamed: @"1.jpg"] Name: @"假日" autoor: @"share小白" massage: @"这个家伙很懒, 什么也没有留下"];
    article* a2 = [[article alloc] initWitImage: [UIImage imageNamed: @"2.jpg"] Name: @"国外画册欣赏" autoor: @"share小白" massage: @"这个家伙很懒, 什么也没有留下"];
    article* a3 = [[article alloc] initWitImage: [UIImage imageNamed: @"3.jpg"] Name: @"体面" autoor: @"share小白" massage: @"这个家伙很懒, 什么也没有留下"];
    article* a4 = [[article alloc] initWitImage: [UIImage imageNamed: @"4.jpg"] Name: @"还会记得我吗" autoor: @"share小白" massage: @"这个家伙很懒, 什么也没有留下"];
    article* a5 = [[article alloc] initWitImage: [UIImage imageNamed: @"5.jpg"] Name: @"collection扁平化设计" autoor: @"share小白" massage: @"这个家伙很懒, 什么也没有留下"];
    [self.homeModel.articles addObjectsFromArray: @[a, a1, a2, a3, a4, a5]];
    
    
    self.homeModel.scrollImages = [[NSMutableArray alloc] init];
    for (int i = 0; i < 4; i++) {
        NSString* imageName = [NSString stringWithFormat: @"%d.jpg", i + 19];
        UIImage* image = [UIImage imageNamed: imageName];
        [self.homeModel.scrollImages addObject: image];
    }
    [self.homeModel.scrollImages addObject: [self.homeModel.scrollImages firstObject]];
    [self.homeModel.scrollImages insertObject: [self.homeModel.scrollImages objectAtIndex: self.homeModel.scrollImages.count - 2]  atIndex: 0];
    
}
                         
    
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) {
        return 200; 
    }
        return 150;
}
- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.homeModel.articles.count;
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) {
        ScrollViewCell* cell = [tableView dequeueReusableCellWithIdentifier: @"scrollViewCellID" forIndexPath: indexPath];
        cell.homeModel = self.homeModel; 
        [cell configureData: self.homeModel.scrollImages];
        return cell;
    }
    CustomCell* cell = [tableView dequeueReusableCellWithIdentifier: @"customCellID" forIndexPath: indexPath];
    article* article = self.homeModel.articles[indexPath.row];
    cell.article = article; 
    [cell configureWithArticle: article];
    return cell;
}


- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath: indexPath animated: YES];
    if (indexPath.row == 0) {
        return; 
    }
    self.indexPath = indexPath;
    ArticlePageController* vc = [[ArticlePageController alloc] init];
    CustomCell* cell = [tableView cellForRowAtIndexPath: indexPath];
    cell.article.viewCount++;
    vc.title = cell.article.name;
    vc.article = self.homeModel.articles[indexPath.row];
    vc.delegate = self;
    [self.navigationController pushViewController: vc animated: YES];
}

- (void) refreshArticle:(article *)article {
    self.homeModel.articles[self.indexPath.row] = article;
    [self.homepageView.tableView reloadData]; 
}

@end

```

有一个需要注意的点,就是我们把滚动视图的tableView的第一个cell中, 在调试的过程中, 会发现当我们在滑动tableView的时候, 第一个cell中的定时器会暂停, 然后当停止滑动的时候, 视图会连续翻页,这里涉及到了RootLoop 与 Mode 的知识, 笔者还不太了解, 解决方法就是在创建定时器的时候加上下面这段代码

```objc
[[NSRunLoop currentRunLoop] addTimer:self.timer forMode: NSRunLoopCommonModes];
```



