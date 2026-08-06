

```objc
// 强制把图片拉伸、压扁，让它完全填满整个框 (图片会变形)
iView.contentMode = UIViewContentModeScaleToFill;
```





```objc
// 设置允许滑动
    scrollView.scrollEnabled = YES;
    
    // 按页滑动
    scrollView.pagingEnabled = YES;
    
    // 显示 横向 / 纵向 滚动条
    scrollView.showsHorizontalScrollIndicator = YES;
    scrollView.showsVerticalScrollIndicator = NO;
    
    // 超出视图的部分裁剪
    scrollView.clipsToBounds = YES;
```



`scrollViewDidScroll` 这个方法**任何滚动**(包括代码触发的滚动)都会调用,不区分是用户手指拖动的,还是程序调用的。 

`scrollViewWillBeginDragging`,这个方法**只有用户用手指拖动**列表时才会触发



#### 