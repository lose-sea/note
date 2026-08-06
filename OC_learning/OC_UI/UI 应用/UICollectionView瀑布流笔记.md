# UICollectionView 瀑布流布局

`UICollectionViewLayout` 是 UICollectionView 的布局引擎，通过继承它可以实现任意自定义布局。瀑布流（Waterfall Layout）就是其中最经典的一种——每列高度不同，item 从高度最小的列开始填充，像瀑布一样自然流下。

## 整体思路

瀑布流布局的核心逻辑只有一句话：**哪列最矮，就往哪列放**。

实现步骤如下：

1. 在 `prepareLayout` 中提前计算所有 item 的位置和大小，缓存起来
2. 在 `layoutAttributesForElementsInRect:` 中返回当前可见区域内的 item 属性
3. 在 `collectionViewContentSize` 中告诉系统内容总共有多高

---

## 声明属性

```objc
// WaterfallLayout.h

@interface WaterfallLayout : UICollectionViewLayout

@property (nonatomic, assign) NSInteger columnCount;    // 列数
@property (nonatomic, assign) CGFloat columnSpacing;    // 列间距
@property (nonatomic, assign) CGFloat rowSpacing;       // 行间距
@property (nonatomic, assign) UIEdgeInsets sectionInset; // 四周内边距

@end
```

```objc
// WaterfallLayout.m

@interface WaterfallLayout ()

@property (nonatomic, strong) NSMutableArray<UICollectionViewLayoutAttributes *> *attributesArray; // 缓存所有 item 的布局属性
@property (nonatomic, strong) NSMutableArray<NSNumber *> *columnHeights; // 记录每列当前的累计高度
@property (nonatomic, assign) CGFloat contentHeight; // 内容总高度

@end
```

> + `attributesArray` 用来缓存所有 item 的布局属性（位置、大小），避免每次都重新计算
> + `columnHeights` 记录每一列当前"长"到哪里了，是找最矮列的依据
> + `contentHeight` 是整个内容区域的总高度，决定 collectionView 能滚多远

`sectionInset` 是 `UIEdgeInsets` 结构体，包含四个属性：

| 属性 | 含义 |
|------|------|
| `top` | 上内边距 |
| `left` | 左内边距 |
| `bottom` | 下内边距 |
| `right` | 右内边距 |

---

## 核心方法：prepareLayout

`prepareLayout` 是整个布局的"总指挥"，在布局开始前被系统调用一次，负责把所有 item 的位置和大小提前算好、存起来。

```objc
- (void)prepareLayout {
    [super prepareLayout];

    UICollectionView *cv = self.collectionView;

    // 初始化每列高度，初始值为上内边距
    self.columnHeights = [NSMutableArray array];
    for (NSInteger i = 0; i < self.columnCount; i++) {
        [self.columnHeights addObject:@(self.sectionInset.top)];
    }

    self.attributesArray = [NSMutableArray array];

    // 计算 item 宽度
    CGFloat totalWidth = CGRectGetWidth(cv.bounds);
    CGFloat availableWidth = totalWidth - self.sectionInset.left - self.sectionInset.right;
    CGFloat itemWidth = (availableWidth - (self.columnCount - 1) * self.columnSpacing) / self.columnCount;

    // 遍历所有 item，计算每个 item 的 frame
    NSInteger itemCount = [cv numberOfItemsInSection:0];
    for (NSInteger i = 0; i < itemCount; i++) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:i inSection:0];

        // 找到最矮的列
        NSInteger targetColumn = [self findSmallestColumn];

        // 取出该列的当前高度
        CGFloat columnY = [self.columnHeights[targetColumn] floatValue];

        // 计算 item 的 y 坐标（非空列需要加行间距）
        CGFloat y = columnY;
        if (columnY > self.sectionInset.top) {
            y += self.rowSpacing;
        }

        // 计算 item 的 x 坐标
        CGFloat x = self.sectionInset.left + targetColumn * (itemWidth + self.columnSpacing);

        // 向数据源询问 item 高度（需要自定义代理协议）
        CGFloat itemHeight = [self.delegate waterfallLayout:self heightForItemAtIndexPath:indexPath itemWidth:itemWidth];

        // 创建布局属性，设置 frame
        UICollectionViewLayoutAttributes *attr = [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:indexPath];
        attr.frame = CGRectMake(x, y, itemWidth, itemHeight);
        [self.attributesArray addObject:attr];

        // 更新该列的累计高度
        self.columnHeights[targetColumn] = @(y + itemHeight);
    }

    //  计算内容总高度 = 最高列的高度 + 底部内边距
    CGFloat maxColumnHeight = [[self.columnHeights valueForKeyPath:@"@max.floatValue"] floatValue];
    self.contentHeight = maxColumnHeight + self.sectionInset.bottom;
}
```

### 为什么初始值是 sectionInset.top

每列从顶部开始放置第一个 item，第一个 item 的 y 坐标就是 `sectionInset.top`（上内边距），所以初始化时每列高度都设为 `sectionInset.top`。

###  item 宽度计算

```objc
totalWidth        = collectionView 的总宽度
availableWidth    = totalWidth - 左内边距 - 右内边距
itemWidth         = (availableWidth - 列间距总和) / 列数
```

列间距总和 = `(columnCount - 1) * columnSpacing`，因为 3 列之间只有 2 个间隔。

举例：totalWidth = 400，左右内边距各 10，3 列，列间距 10

```
availableWidth = 400 - 10 - 10 = 380
itemWidth = (380 - 2 × 10) / 3 = 360 / 3 = 120
```

验证：3 × 120 + 2 × 10 = 380 

> **注意**：左右内边距 ≠ 列间距。
>
> + `sectionInset.left/right` 是内容区域与 collectionView **边界**之间的空白
> + `columnSpacing` 是**列与列**之间的空白



###  item 的 x 坐标计算

```objc
CGFloat x = self.sectionInset.left + targetColumn * (itemWidth + self.columnSpacing);
```

第 0 列：x = 左内边距

第 1 列：x = 左内边距 + 1 × (列宽 + 列间距)

第 2 列：x = 左内边距 + 2 × (列宽 + 列间距)

以此类推，每列的 x 坐标都是固定的。

###  item 的 y 坐标计算

```objc
CGFloat columnY = [self.columnHeights[targetColumn] floatValue];

CGFloat y = columnY;
if (columnY > self.sectionInset.top) {
    y += self.rowSpacing;
}
```

`columnY` 就是该列当前的累计高度，也就是这列最后一个 item 的底部在哪里

如果 `columnY > sectionInset.top`，说明该列已经有 item 了，下一个 item 需要在此基础上加行间距

如果 `columnY == sectionInset.top`，说明该列还是空的，直接从 `sectionInset.top` 开始放，不需要加行间距

---

## 找最矮列：findSmallestColumn

```objc
- (NSInteger)findSmallestColumn {
    NSInteger targetColumn = 0;
    CGFloat minHeight = [self.columnHeights[0] floatValue];

    for (NSInteger i = 1; i < self.columnCount; i++) {
        CGFloat height = [self.columnHeights[i] floatValue];
        if (height < minHeight) {
            minHeight = height;
            targetColumn = i;
        }
    }
    return targetColumn;
}
```

遍历 `columnHeights`，找到高度最小的列的索引，把下一个 item 放到那里，这就是瀑布流"哪里矮往哪里放"的核心逻辑

---

## 返回内容大小：collectionViewContentSize

```objc
- (CGSize)collectionViewContentSize {
    return CGSizeMake(CGRectGetWidth(self.collectionView.bounds), self.contentHeight);
}
```

这个方法告诉 UICollectionView（本质上是 UIScrollView）"我的内容有多大"，系统根据这个值来决定可以滚动多远。

+ 宽度 = collectionView 自身的宽度 → 水平方向不可滚动
+ 高度 = `contentHeight`（在 prepareLayout 中计算好的）→ 垂直方向按内容高度滚动

> **为什么不是自动决定的？**
>
> 使用系统自带的 `UICollectionViewFlowLayout` 时，它内部已经帮你计算好了，不需要手动写。但使用自定义 Layout 时，系统不知道你的排列规则，必须由你亲自告诉它内容有多大。如果不实现，默认返回 `CGSizeZero`，collectionView 无法滚动，甚至不会显示任何 cell。

---

## 返回可见区域的布局属性：layoutAttributesForElementsInRect:

```objc
- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSMutableArray *result = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *attr in self.attributesArray) {
        if (CGRectIntersectsRect(rect, attr.frame)) {
            [result addObject:attr];
        }
    }
    return result;
}
```

系统在滚动时会不断调用这个方法，传入当前可见区域的 `rect`，问你"这个范围内有哪些 item 需要显示？"

`CGRectIntersectsRect(rect, attr.frame)` 判断某个 item 的 frame 是否与可见区域有交集，有交集才加入结果数组返回给系统。

这样做的好处是：不管有多少个 item，每次只返回屏幕上看得见的那十几个，系统只渲染这些，滚动流畅不卡顿。

> 如果不判断直接返回所有 attributes，功能上也能显示，但性能极差——每次滚动系统都要处理全部 item，数量一多就会明显掉帧。

---

## 根据 indexPath 返回单个属性：layoutAttributesForItemAtIndexPath:

```objc
- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    for (UICollectionViewLayoutAttributes *attr in self.attributesArray) {
        if ([attr.indexPath isEqual:indexPath]) {
            return attr;
        }
    }
    return nil;
}
```

系统在某些情况下（比如插入、删除 item 时）会直接通过 indexPath 查询某个 item 的属性，这个方法负责从缓存数组中找到对应的结果返回。

> ```objc
>// 在 prepareLayout 中
> self.attributesDict[indexPath] = attr;
> 
> // 查找时直接返回
>return self.attributesDict[indexPath];
> ```

---

## 响应尺寸变化：shouldInvalidateLayoutForBoundsChange:

```objc
- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    CGRect oldBounds = self.collectionView.bounds;
    if (CGSizeEqualToSize(oldBounds.size, newBounds.size)) {
        return NO;
    }
    return YES;
}
```

这是系统提供的可重写方法，用来控制当 collectionView 的 bounds 变化时，是否需要重新计算布局。

`CGSizeEqualToSize` 会比较两个 `CGSize` 的 `width` 和 `height` 是否都相等。

+ **滚动时**：bounds 的 origin 变化，但 size 不变 → 返回 `NO`，不重新计算，滚动流畅
+ **旋转屏幕时**：宽度发生变化，size 不同 → 返回 `YES`，重新计算所有 item 的位置和宽度

> 系统默认实现返回 `NO`，即 bounds 改变不会自动触发重新布局。瀑布流中 item 宽度依赖 collectionView 宽度，所以旋转屏幕后必须重算，需要重写这个方法。

---

## 方法调用顺序总结

```
prepareLayout                           // 提前算好所有 item 的位置
        ↓
collectionViewContentSize               // 告诉系统内容总高度
        ↓
layoutAttributesForElementsInRect:      // 滚动时返回当前可见区域的 item 属性
        ↓
layoutAttributesForItemAtIndexPath:     // 按需查询某个 item 的属性
```

---

## 完整代码如下: 

```objc
//
//  WaterfallLayout.h
//

#import <UIKit/UIKit.h>

@class WaterfallLayout;

@protocol WaterfallLayoutDelegate <NSObject>
- (CGFloat)waterfallLayout:(WaterfallLayout *)layout
    heightForItemAtIndexPath:(NSIndexPath *)indexPath
                  itemWidth:(CGFloat)itemWidth;
@end

@interface WaterfallLayout : UICollectionViewLayout

@property (nonatomic, weak) id<WaterfallLayoutDelegate> delegate;
@property (nonatomic, assign) NSInteger columnCount;
@property (nonatomic, assign) CGFloat columnSpacing;
@property (nonatomic, assign) CGFloat rowSpacing;
@property (nonatomic, assign) UIEdgeInsets sectionInset;

@end
```

```objc
//
//  WaterfallLayout.m
//

#import "WaterfallLayout.h"

@interface WaterfallLayout ()
@property (nonatomic, strong) NSMutableArray<UICollectionViewLayoutAttributes *> *attributesArray;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *columnHeights;
@property (nonatomic, assign) CGFloat contentHeight;
@end

@implementation WaterfallLayout

- (void)prepareLayout {
    [super prepareLayout];

    UICollectionView *cv = self.collectionView;

    self.columnHeights = [NSMutableArray array];
    for (NSInteger i = 0; i < self.columnCount; i++) {
        [self.columnHeights addObject:@(self.sectionInset.top)];
    }

    self.attributesArray = [NSMutableArray array];

    CGFloat totalWidth = CGRectGetWidth(cv.bounds);
    CGFloat availableWidth = totalWidth - self.sectionInset.left - self.sectionInset.right;
    CGFloat itemWidth = (availableWidth - (self.columnCount - 1) * self.columnSpacing) / self.columnCount;

    NSInteger itemCount = [cv numberOfItemsInSection:0];
    for (NSInteger i = 0; i < itemCount; i++) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:i inSection:0];

        NSInteger targetColumn = [self findSmallestColumn];
        CGFloat columnY = [self.columnHeights[targetColumn] floatValue];

        CGFloat y = columnY;
        if (columnY > self.sectionInset.top) {
            y += self.rowSpacing;
        }

        CGFloat x = self.sectionInset.left + targetColumn * (itemWidth + self.columnSpacing);
        CGFloat itemHeight = [self.delegate waterfallLayout:self heightForItemAtIndexPath:indexPath itemWidth:itemWidth];

        UICollectionViewLayoutAttributes *attr = [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:indexPath];
        attr.frame = CGRectMake(x, y, itemWidth, itemHeight);
        [self.attributesArray addObject:attr];

        self.columnHeights[targetColumn] = @(y + itemHeight);
    }

    CGFloat maxColumnHeight = [[self.columnHeights valueForKeyPath:@"@max.floatValue"] floatValue];
    self.contentHeight = maxColumnHeight + self.sectionInset.bottom;
}

- (NSInteger)findSmallestColumn {
    NSInteger targetColumn = 0;
    CGFloat minHeight = [self.columnHeights[0] floatValue];
    for (NSInteger i = 1; i < self.columnCount; i++) {
        CGFloat height = [self.columnHeights[i] floatValue];
        if (height < minHeight) {
            minHeight = height;
            targetColumn = i;
        }
    }
    return targetColumn;
}

- (CGSize)collectionViewContentSize {
    return CGSizeMake(CGRectGetWidth(self.collectionView.bounds), self.contentHeight);
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSMutableArray *result = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *attr in self.attributesArray) {
        if (CGRectIntersectsRect(rect, attr.frame)) {
            [result addObject:attr];
        }
    }
    return result;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    for (UICollectionViewLayoutAttributes *attr in self.attributesArray) {
        if ([attr.indexPath isEqual:indexPath]) {
            return attr;
        }
    }
    return nil;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    CGRect oldBounds = self.collectionView.bounds;
    if (CGSizeEqualToSize(oldBounds.size, newBounds.size)) {
        return NO;
    }
    return YES;
}

@end
```
