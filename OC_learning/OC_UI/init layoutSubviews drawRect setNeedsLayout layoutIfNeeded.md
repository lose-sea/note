

init
layoutSubviews
drawRect
setNeedsLayout
layoutIfNeeded



这是 UIView 生命周期中**布局与绘制**的核心方法。我用一个**「盖房子装修」**的比喻帮你记忆它们的顺序和区别。

### 1. `init` (出生)

+ **是什么**：对象的构造函数。无论是通过代码 (`init(frame:)`) 还是 xib/Storyboard (`init(coder:)`) 创建，第一步都是它。
+ **主要任务**：初始化实例变量、子视图对象。此时**还没有**具体的坐标和大小（frame 通常为 0），只是把你需要的子视图（UILabel、UIButton 等）创建好。
+ **注意**：**不要**在这里写视图的布局代码（比如设置 frame），因为这时候视图还没被添加到父视图，尺寸也是错的。

### 2. `layoutSubviews` (摆放家具)

+ **是什么**：最核心的布局方法。**不要手动调用它**，而是由系统在以下时机自动调用：
  1. 视图第一次被显示之前。
  2. 视图的 frame 或 bounds 发生变化（比如旋转屏幕、滚动列表）。
  3. 手动调用了 `setNeedsLayout` 或 `layoutIfNeeded`。
+ **主要任务**：给子视图设定精确的 frame 或更新布局约束。
+ 如果是用代码布局，通常在这里写 `subview.frame = ...`。
+ **比喻**：地板铺好了，现在决定桌子摆哪里、椅子放哪里。

### 3. `drawRect` (刷墙涂色)

+ **是什么**：绘制视图内容的画板。**除非必要，不要重写它**（用 layer、图片、背景色即可）。**不要手动调用它**。
+ **触发时机**：第一次显示、或调用了 `setNeedsDisplay`。
+ **主要任务**：使用 Core Graphics 绘制图形、文字、线条。**注意**：在这个方法执行时，`layoutSubviews` 通常已经执行完了，位置已经定好了。
+ **比喻**：家具摆好了，现在开始给墙壁刷颜色、挂壁画。如果只是挪动家具（改变布局），不需要重新刷墙。

### 4. `setNeedsLayout` (标记待办)

+ **是什么**：一个**标记方法**，非阻塞。
+ **作用**：告诉系统：“我的布局变脏了，在**下一个 RunLoop 循环**里请帮我调用一次 `layoutSubviews`”。
+ **性能**：连点多次 `setNeedsLayout` 只会执行一次 `layoutSubviews`，这样能把多次布局调整合并成一次，提升性能。
+ **比喻**：你撕了一张便利贴贴在脑门上，写着“需要重新摆家具”，等你忙完手头的事就会去处理。

### 5. `layoutIfNeeded` (立刻执行)

+ **是什么**：一个**立即执行**方法，阻塞。
+ **作用**：“别等下一个循环了，**现在、立刻、马上**检查有没有 `setNeedsLayout` 标记。如果有，马上调用 `layoutSubviews`。”
+ **常用场景**：动画。你想在动画块里改变一个约束，必须调用 `[self.view layoutIfNeeded]` 让布局立即刷新，动画才能捕捉到最终位置。
+ **比喻**：你看到脑门上的便利贴，**放下手头所有事**，立刻去把家具摆好。

------

### 运行流程示例

假设你把一个视图的宽度从 100 改成 200：

objc

```
// 1. 改变约束或 frame
view.frame = CGRectMake(0,0,200,100);

// 2. 手动标记
[view setNeedsLayout]; // 此时什么都没发生，只是记了个“待办”

// 3a. 等待... 下一个 RunLoop 到来，系统自动调用 [view layoutSubviews]

// 3b. 或者你等不及了：
[view layoutIfNeeded]; // 立刻触发 layoutSubviews
```



### 常见面试题

1. **为什么在 `init` 里设置 `frame` 没用？**
   + 因为 `init` 时视图还没有被添加到层级中，也没有进行布局。你设置的数值可能会在后面 `layoutSubviews` 中被父视图覆盖。
2. **`layoutSubviews` 和 `drawRect` 哪个更耗性能？**
   + `drawRect` 更耗性能。因为它会触发 GPU/CPU 的大批量绘图操作，而 `layoutSubviews` 主要是改变视图的位置（位移/矩阵变换），成本相对较低。
   + **优化原则**：能用背景色不用 `drawRect`，能用 `layer` 圆角不用 `drawRect`。
3. **`setNeedsLayout` 和 `setNeedsDisplay` 的区别？**
   + `setNeedsLayout` →→ 下一次布局循环调用 `layoutSubviews`（处理位置大小）。
   + `setNeedsDisplay` →→ 下一次绘制循环调用 `drawRect`（处理内容图形）。
   + *注意：改变 frame 通常只会触发 `layoutSubviews`，不会触发 `drawRect`；只有调用了 `setNeedsDisplay` 或内容发生改变（比如图片变了）才会触发 `drawRect`。*