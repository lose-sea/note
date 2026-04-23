# Masonry 约束学习笔记（OC）

## 一、Masonry 是什么

Masonry 是对 Auto Layout 的链式封装，将冗长的 `NSLayoutConstraint` API 压缩为可读性极强的点语法链。
 本质：帮你生成并自动添加 `NSLayoutConstraint`，同时自动关闭 `translatesAutoresizingMaskIntoConstraints`。

引入：

```objc
#import <Masonry/Masonry.h>
```

> 使用 CocoaPods 安装：`pod 'Masonry'`

------

## 二、基本结构

调用前必须先将视图加入父视图，否则约束目标不存在会直接崩溃。

```objc
[self.view addSubview:redView];

[redView mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.equalTo(self.view).offset(100);
    make.left.equalTo(self.view).offset(20);
    make.width.mas_equalTo(200);
    make.height.mas_equalTo(50);
}];
```

------

## 三、点语法速查表

| 点语法 / 方法                  | 类型     | 用途说明                           |
| ------------------------------ | -------- | ---------------------------------- |
| `.top`                         | 属性     | 视图上边                           |
| `.bottom`                      | 属性     | 视图下边                           |
| `.left`                        | 属性     | 视图左边（绝对方向）               |
| `.right`                       | 属性     | 视图右边（绝对方向）               |
| `.leading`                     | 属性     | 首边（推荐，支持 RTL 阿拉伯文等）  |
| `.trailing`                    | 属性     | 尾边（推荐）                       |
| `.width`                       | 属性     | 宽度                               |
| `.height`                      | 属性     | 高度                               |
| `.centerX`                     | 属性     | 水平居中轴                         |
| `.centerY`                     | 属性     | 垂直居中轴                         |
| `.center`                      | 复合属性 | 同时设 centerX + centerY           |
| `.edges`                       | 复合属性 | 同时设 top + left + bottom + right |
| `.size`                        | 复合属性 | 同时设 width + height              |
| `.equalTo(view)`               | 关系方法 | 等于某个视图或 mas_属性，接对象    |
| `.mas_equalTo(value)`          | 关系方法 | 等于某个具体数值，接基本类型       |
| `.greaterThanOrEqualTo(v)`     | 关系方法 | 大于等于                           |
| `.lessThanOrEqualTo(v)`        | 关系方法 | 小于等于                           |
| `.offset(CGFloat)`             | 修饰方法 | 在约束基础上偏移（正负决定方向）   |
| `.insets(UIEdgeInsets)`        | 修饰方法 | 配合 `.edges` 四边内缩             |
| `.multipliedBy(CGFloat)`       | 修饰方法 | 乘以系数，常用于比例宽高           |
| `.dividedBy(CGFloat)`          | 修饰方法 | 除以系数                           |
| `.priority(MASLayoutPriority)` | 修饰方法 | 设置约束优先级                     |

------

## 四、equalTo 与 mas_equalTo 的区别

```objc
// equalTo 接 UIView 或 mas_属性
make.width.equalTo(otherView);
make.top.equalTo(viewA.mas_bottom);

// mas_equalTo 接基本数据类型
make.width.mas_equalTo(100);
make.size.mas_equalTo(CGSizeMake(100, 50));
make.edges.mas_equalTo(UIEdgeInsetsMake(10, 10, 10, 10));
```

> 简单记忆：有 `mas_` 前缀的 = 接数字 / 结构体；没有的 = 接视图。

------

## 五、三个核心方法

```
mas_makeConstraints      第一次添加约束，视图从无到有建立约束
mas_updateConstraints    只更新已存在的某几条约束，其余保留
mas_remakeConstraints    清除全部旧约束，重新编写（常用于布局切换）
```

------

## 六、常用布局写法

```objc
// 贴满父视图
make.edges.equalTo(self.view);

// 四边内缩 16pt
make.edges.equalTo(self.view).insets(UIEdgeInsetsMake(16, 16, 16, 16));

// B 紧贴 A 下方，左边对齐
make.top.equalTo(viewA.mas_bottom).offset(12);
make.left.equalTo(viewA);

// 宽度是父视图的一半
make.width.equalTo(self.view).multipliedBy(0.5);

// 固定宽高比 2:1
make.width.equalTo(redView.mas_height).multipliedBy(2);

// 水平居中 + 指定宽高
make.centerX.equalTo(self.view);
make.width.height.mas_equalTo(100);
```

------

## 七、offset 方向规律

| 属性                | 正值效果               | 负值效果               |
| ------------------- | ---------------------- | ---------------------- |
| `.top.offset(n)`    | 向下移动               | 向上移动               |
| `.bottom.offset(n)` | 向下撑出（超出父视图） | 向上收缩（常用 `-16`） |
| `.left.offset(n)`   | 向右移动               | 向左移动               |
| `.right.offset(n)`  | 向右撑出               | 向左收缩（常用 `-16`） |

> 记忆方法：offset 方向与坐标轴一致，top/left 正数 = 远离边界 = 向内；bottom/right 正数 = 向外扩张，负数才是向内缩进。

------

## 八、约束优先级

```objc
MASLayoutPriorityRequired        // 1000，必须满足（默认）
MASLayoutPriorityDefaultHigh     // 750，高优先级
MASLayoutPriorityDefaultLow      // 250，低优先级
MASLayoutPriorityFittingSizeLevel // 50，自适应尺寸级别

// 用法
make.height.mas_equalTo(200).priority(MASLayoutPriorityDefaultHigh);
make.height.greaterThanOrEqualTo(@44).priority(MASLayoutPriorityRequired);
```

优先级常见场景：同一属性存在多条约束时，高优先级的先被满足，低优先级的在冲突时被忽略。

------

## 九、保存约束引用（动态修改）

```objc
@property (nonatomic, strong) MASConstraint *topConstraint;

[box mas_makeConstraints:^(MASConstraintMaker *make) {
    self.topConstraint = make.top.equalTo(self.view).offset(100);
    make.centerX.equalTo(self.view);
    make.width.height.mas_equalTo(100);
}];

// 后续直接更新，无需 remakeConstraints
[self.topConstraint setOffset:300];  // 推荐写法
// 或
self.topConstraint.offset(300);      // 也可以
[self.view layoutIfNeeded];
```

------

## 十、约束动画

修改约束后必须调用 `layoutIfNeeded` 才能触发重新布局，动画放在它外层。

```objc
[self.box mas_updateConstraints:^(MASConstraintMaker *make) {
    make.top.equalTo(self.view).offset(300);
}];

[UIView animateWithDuration:0.3 animations:^{
    [self.view layoutIfNeeded];
}];
```

> 注意：`layoutIfNeeded` 要对约束所在的**父视图**调用，而不是对子视图调用。

------

## 十一、动态高度（intrinsicContentSize）

`UILabel`、`UIButton`、`UIImageView` 有固有尺寸，不需要手动设宽高。
 `UILabel` 必须设 `numberOfLines = 0` 才能多行自动撑高。

```objc
label.numberOfLines = 0;

[label mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.equalTo(self.view).offset(100);
    make.left.equalTo(self.view).offset(20);
    make.right.equalTo(self.view).offset(-20);
    // 不需要设高度，label 会自动根据内容撑高
}];
```

纯 UIView 没有固有尺寸，必须显式指定 width 和 height，否则大小为 0，不可见。

------

## 十二、ScrollView 标准写法

关键：加一个 `contentView` 作为中间层，`contentView` 宽度锁死等于 `scrollView`，由内容撑开高度。

```objc
UIScrollView *scrollView = [[UIScrollView alloc] init];
UIView *contentView = [[UIView alloc] init];

[self.view addSubview:scrollView];
[scrollView addSubview:contentView];

[scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
    make.edges.equalTo(self.view);
}];

[contentView mas_makeConstraints:^(MASConstraintMaker *make) {
    make.edges.equalTo(scrollView);   // 让 contentView 撑开 scrollView 的 contentSize
    make.width.equalTo(scrollView);   // 锁定宽度，只允许纵向滚动
}];

// 最后一个子视图的 bottom 连到 contentView 才能撑开高度
[lastSubview mas_makeConstraints:^(MASConstraintMaker *make) {
    make.bottom.equalTo(contentView).offset(-20);
}];
```

------

## 十三、UITableView 动态 Cell 高度配合 Masonry

在自定义 Cell 中用 Masonry 布局子视图时，约束必须完整从 `contentView.top` 连到 `contentView.bottom`，Auto Layout 才能计算出 Cell 高度。

```objc
// 在 ViewController 中开启自动高度
self.tableView.estimatedRowHeight = 80;
self.tableView.rowHeight = UITableViewAutomaticDimension;

// 在 Cell 的 initWithStyle:reuseIdentifier: 中
[self.titleLabel mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.left.equalTo(self.contentView).offset(12);
    make.right.equalTo(self.contentView).offset(-12);
}];

[self.subLabel mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.equalTo(self.titleLabel.mas_bottom).offset(8);
    make.left.right.equalTo(self.titleLabel);
    make.bottom.equalTo(self.contentView).offset(-12); // 必须连到 contentView.bottom
}];
```

------

## 十四、常见错误与排查

| 错误现象                 | 原因                                              | 修复方法                                                     |
| ------------------------ | ------------------------------------------------- | ------------------------------------------------------------ |
| 视图不显示，大小为 0     | 普通 UIView 无固有尺寸，缺少 width/height 约束    | 补全宽高约束                                                 |
| 约束冲突警告（红色日志） | 同一属性有两条不兼容约束，如 center 和 top 同时设 | 二选一或调整优先级                                           |
| ScrollView 无法滚动      | contentView 没有锁定宽度，或最后子视图未连 bottom | 补 `make.width.equalTo(scrollView)` 和最后 bottom            |
| 动画没有执行             | 忘记调用 `layoutIfNeeded` 或调用位置在父视图外    | 在 `animateWithDuration` block 内调 `[self.view layoutIfNeeded]` |
| Cell 高度错误            | Cell 内约束链未从 top 连通到 bottom               | 检查最后一个子视图是否有 `bottom.equalTo(contentView)`       |
| `offset` 方向反了        | 混淆了 bottom/right 的正负方向                    | bottom/right 向内缩进用负值                                  |

------

## 十五、进阶：mas_属性速查

当 `equalTo()` 需要对齐另一个视图的某条边时，使用 `mas_` 前缀属性：

| mas_ 属性                      | 对应的边                   |
| ------------------------------ | -------------------------- |
| `view.mas_top`                 | 上边                       |
| `view.mas_bottom`              | 下边                       |
| `view.mas_left`                | 左边                       |
| `view.mas_right`               | 右边                       |
| `view.mas_leading`             | 首边                       |
| `view.mas_trailing`            | 尾边                       |
| `view.mas_centerX`             | 水平中线                   |
| `view.mas_centerY`             | 垂直中线                   |
| `view.mas_width`               | 宽度                       |
| `view.mas_height`              | 高度                       |
| `view.mas_baseline`            | 文字基线（UILabel 对齐用） |
| `view.mas_safeAreaLayoutGuide` | 安全区域（iOS 11+）        |

```objc
// 典型用法：B 的 top 等于 A 的 bottom
make.top.equalTo(viewA.mas_bottom).offset(12);

// 对齐 safeArea
make.top.equalTo(self.view.mas_safeAreaLayoutGuide);
```