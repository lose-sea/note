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

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {

    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];

    if (self) {

        self.iconView = [[UIImageView alloc] init];
        self.titleLabel = [[UILabel alloc] init];
        self.priceLabel = [[UILabel alloc] init];

        [self.contentView addSubview:self.iconView];
        [self.contentView addSubview:self.titleLabel];
        [self.contentView addSubview:self.priceLabel];
    }

    return self;
}
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