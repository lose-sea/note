## alpha 和 opaque 总结

------

## alpha

+ 控制**实际显示效果**（透明度）
+ 范围 `0.0 ~ 1.0`
+ 影响视图本身和**所有子视图**

objc

```objc
view.alpha = 0.0;  // 完全透明
view.alpha = 0.5;  // 半透明
view.alpha = 1.0;  // 完全不透明（默认）
```

------

## opaque

+ 只是给 **GPU 的提示**，不影响显示效果
+ 告诉系统**要不要做透明混合计算**
+ 默认值是 `YES`

objc

```objc
view.opaque = YES;  // 告诉系统：不用做透明处理，直接画
view.opaque = NO;   // 告诉系统：需要做透明混合计算
```

