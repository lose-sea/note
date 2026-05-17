# 创建自定义 Cell

```objc
@interface ProductCell : UITableViewCell

@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *priceLabel;

@end
```



# 初始化 UI

```objc
@implementation ProductCell

- (instancetype) initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle: style reuseIdentifier: reuseIdentifier];
    if (self) {
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.textColor = [UIColor redColor];
        self.titleLabel.frame = CGRectMake(0, 0, 200, self.bounds.size.height);
        // contentView 是UITableView内部的容器视图, 应该把所有的UI元素加入到它里面
        self.btn = [[UIButton alloc] init];
        _btn.frame = CGRectMake(100, 10, 40, 20);
        _btn.backgroundColor = [UIColor blueColor];
        [self.contentView addSubview: self.titleLabel];
        [self.contentView addSubview: self.btn];
    }
    return self;
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



# 布局（Masonry）

```objc
- (void)layoutSubviews {
    [super layoutSubviews];

    self.iconView.frame = CGRectMake(10, 10, 60, 60);

    self.titleLabel.frame = CGRectMake(80, 10, 200, 30);

    self.priceLabel.frame = CGRectMake(80, 40, 200, 30);
}
```