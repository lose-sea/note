# Masonry

## Masonry 是什么

Masonry 是对 Auto Layout 的链式封装，将冗长的 `NSLayoutConstraint` API 压缩为可读性极强的点语法链。
 本质：帮你生成并自动添加 `NSLayoutConstraint`，同时自动关闭 `translatesAutoresizingMaskIntoConstraints`。

引入：

```objc
#import <Masonry/Masonry.h>
```

> 使用 CocoaPods 安装：`pod 'Masonry'`



**`mas_equalTo` vs `equalTo` 的区别：**

```objc
make.width.mas_equalTo(100);        // 传数值，自动包装为 NSNumber
make.width.equalTo(@100);           // 也可以，但要手动包装
make.left.equalTo(self.view);       // 传视图，建立相对约束
make.left.mas_equalTo(self.view);   // 同上，两者等效
```

简单记忆：传数字用 `mas_equalTo`，传视图用 `equalTo` 或 `mas_equalTo` 都行。

## 基本结构

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

## 点语法速查表 

## 

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

###  距离父视图边距

```objc
// 上下左右各 20
make.edges.equalTo(self.view).insets(UIEdgeInsetsMake(20, 20, 20, 20));

// 分别设置
make.top.equalTo(self.view.mas_top).offset(20);
make.left.equalTo(self.view.mas_left).offset(20);
make.right.equalTo(self.view.mas_right).offset(-20);
make.bottom.equalTo(self.view.mas_bottom).offset(-20);
```

offset 的参数大于 0 : 向右或者向下 

offset 的参数小于 0 : 向左或者向上

------------------------------------------------





## Masonry 黄金法则

 **同一个方向上不要“既定边距又定尺寸”**

| 方向 | 不要同时写            |
| ---- | --------------------- |
| 水平 | left + right + width  |
| 垂直 | top + bottom + height |

写法一: 

用边距（推荐布局自适应）

```objc
[view mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.offset(20);
    make.bottom.offset(-300);
    make.left.offset(10);
    make.right.offset(-10);
}];
```

不要再写 width / height 



写法二:  

用固定尺寸 + 定位

```objc
[view mas_makeConstraints:^(MASConstraintMaker *make) {
    make.top.offset(20);
    make.left.offset(10);
    
    make.width.mas_equalTo(100);
    make.height.mas_equalTo(200);
}];
```

不要再写 right / bottom



### 设置优先级

```objc
[self.fatherView mas_makeConstraints:^(MASConstraintMaker *make) {
  make.width.mas_equalTo(200).priorityHigh();//高优先级
  make.height.mas_equalTo(100).priorityLow();//低优先级
  make.width.mas_equalTo(200).priorityMedium();//中等优先级
}];
```

比如：

```
make.left.equalTo(self.view).offset(10);
make.right.equalTo(self.view).offset(-10);
make.width.mas_equalTo(400).priorityLow();
```

如果屏幕不够宽：

+ 系统会**优先满足左右边距**
+ 自动放弃 width=400 



优先级 = 冲突时的“让步规则”，不冲突时等于没写. 

如果两个约束不可能同时成立，就需要优先级 



## mas_属性速查

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
