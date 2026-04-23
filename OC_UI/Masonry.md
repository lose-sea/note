# Masonry

Masonry 是一个对 `NSLayoutConstraint` 进行封装的轻量级框架，它提供了一套链式调用的 DSL（领域特定语言），让同样的约束写起来像自然语言一样简洁



**`mas_equalTo` vs `equalTo` 的区别：**

```objc
make.width.mas_equalTo(100);        // 传数值，自动包装为 NSNumber
make.width.equalTo(@100);           // 也可以，但要手动包装
make.left.equalTo(self.view);       // 传视图，建立相对约束
make.left.mas_equalTo(self.view);   // 同上，两者等效
```

简单记忆：传数字用 `mas_equalTo`，传视图用 `equalTo` 或 `mas_equalTo` 都行。



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






## Masonry 黄金法则（很重要）

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
