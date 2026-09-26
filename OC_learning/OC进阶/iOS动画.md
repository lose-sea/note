[TOC] 

# CABasicAnimat。ion

`CABasicAnimation` 是 **Core Animation 框架里最基础、最常用的动画类**，用来做「某个属性从一个值平滑变化到另一个值」的补间动画。你项目里封面旋转就是它。下面从概念到实战系统讲一遍。

## 一、Core Animation 的分层

先建立整体图景。iOS 动画分几层：

text

```
UIKit 层    UIView animateWithDuration:        ← 最简单，做一次性动画
              ↓（底层转成）
Core Animation 层
    ├── CAAnimation（抽象基类）
    │     ├── CAPropertyAnimation（抽象）
    │     │     ├── CABasicAnimation      ← 从 A 到 B
    │     │     └── CAKeyframeAnimation   ← 沿路径/多个关键点
    │     ├── CAAnimationGroup            ← 多个动画组合
    │     └── CATransition                ← 转场动画
    └── CALayer                            ← 动画作用的载体
```



**关键认知**：UIKit 的动画 API 是 Core Animation 的封装。想做无限循环、精确控制缓动、组合动画，就得直接下到 Core Animation 层用 `CABasicAnimation`。

## 二、动画作用在 CALayer 上，不是 UIView

`UIView` 和 `CALayer` 是「一个视图两层」：

+ **UIView**：负责响应事件、处理触摸、布局
+ **CALayer**：负责**绘制和动画**

每个 `UIView` 背后都有一个 `layer`（`view.layer`）。**所有 Core Animation 的动画都是加到 layer 上的**：

objc

```
[self.coverImageView.layer addAnimation:rotation forKey:@"coverRotation"];
//                    ↑ 注意是 layer，不是 view
```



**为什么要分两层**：layer 更轻量，可以在没有 UIView 的情况下独立存在（比如 `CALayer` 可以单独做粒子效果），动画性能也更好。

## 三、CABasicAnimation 的三个核心要素

一个 `CABasicAnimation` 回答三个问题：

| 问题             | 对应属性                                         |
| :--------------- | :----------------------------------------------- |
| **改哪个属性？** | `keyPath`                                        |
| **从哪到哪？**   | `fromValue` / `toValue`（或 `byValue`）          |
| **怎么变？**     | `duration` / `repeatCount` / `timingFunction` 等 |

### 1. keyPath —— 要动画的属性

objc

```
CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
```



`keyPath` 是**字符串**，指向 layer 上某个**可动画的属性**。常用的：

| keyPath                     | 含义        | 效果                           |
| :-------------------------- | :---------- | :----------------------------- |
| `position`                  | 位置        | 移动                           |
| `position.x` / `position.y` | 单轴位置    | 单方向移动                     |
| `opacity`                   | 透明度      | 淡入淡出                       |
| `bounds.size`               | 尺寸        | 缩放（改尺寸）                 |
| `transform.scale`           | 缩放        | 缩放                           |
| `transform.scale.x`         | X 轴缩放    | 横向缩放                       |
| `transform.rotation`        | 旋转        | 旋转                           |
| `transform.rotation.z`      | 绕 Z 轴旋转 | **屏幕平面内旋转**（你的封面） |
| `transform.rotation.x`      | 绕 X 轴旋转 | 上下翻转                       |
| `backgroundColor`           | 背景色      | 颜色渐变                       |
| `cornerRadius`              | 圆角        | 圆角变化                       |
| `borderWidth`               | 边框宽度    | 边框变化                       |

**注意 keyPath 支持点语法**，可以精确到子属性：

objc

```
@"position"              // 整个 position
@"position.x"            // 只动 x
@"transform.rotation.z"  // 只绕 z 转
@"bounds.size.width"     // 只改宽度
```



**关键**：不是所有属性都能动画。layer 上「可动画属性」有明确清单，写错了会**运行时崩溃**（报 `NSUnknownKeyException`）。常见的就是上面表里那些。

### 2. fromValue / toValue / byValue —— 动画的起点终点

三种组合方式：

objc

```
// 方式 1：从 A 到 B（最常用）
anim.fromValue = @0;
anim.toValue = @(M_PI * 2);

// 方式 2：从当前值变化 delta（相对动画）
anim.byValue = @100;   // 在当前值基础上 +100

// 方式 3：只给 toValue，fromValue 取当前值
anim.toValue = @1.0;   // 从当前值变到 1.0
```



**重要概念**：`fromValue` / `toValue` 是 `id` 类型，所以要装箱：

objc

```
@0              // NSNumber，int
@(M_PI * 2)     // NSNumber，double
@(YES)          // NSNumber，BOOL
[UIColor redColor]   // 颜色直接是对象
[NSValue valueWithCGPoint:...]  // 结构体用 NSValue 包
```



**基本类型用 `@()` 装箱，对象类型直接用。**

### 3. 时长与控制

objc

```
anim.duration = 20.0;                    // 一次动画持续 20 秒
anim.repeatCount = HUGE_VALF;            // 无限重复
anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
anim.autoreverses = YES;                 // 到达终点后反向回到起点
anim.beginTime = CACurrentMediaTime() + 1.0;  // 延迟 1 秒开始
anim.speed = 2.0;                        // 2 倍速
```



常用控制属性：

| 属性             | 作用                           |
| :--------------- | :----------------------------- |
| `duration`       | 一次完整动画的时长（秒）       |
| `repeatCount`    | 重复次数，`HUGE_VALF` 是无限   |
| `repeatDuration` | 重复的总时长                   |
| `autoreverses`   | 到终点后是否反向               |
| `timingFunction` | 缓动曲线（匀速、加速、减速等） |
| `beginTime`      | 延迟开始时间                   |
| `speed`          | 动画速度倍率                   |

**缓动曲线（timingFunction）**：

| 常量                                  | 效果                       |
| :------------------------------------ | :------------------------- |
| `kCAMediaTimingFunctionLinear`        | 匀速                       |
| `kCAMediaTimingFunctionEaseIn`        | 慢进快出（加速）           |
| `kCAMediaTimingFunctionEaseOut`       | 快进慢出（减速）           |
| `kCAMediaTimingFunctionEaseInEaseOut` | 慢进慢出                   |
| `kCAMediaTimingFunctionDefault`       | 默认（类似 EaseInEaseOut） |

## 四、把动画加到 layer

objc

```
[layer addAnimation:anim forKey:@"someKey"];
```



`forKey:` 是**动画的标识**，不是 keyPath。作用是：

1. **查询**：`[layer animationForKey:@"someKey"]` 拿到这个动画
2. **移除**：`[layer removeAnimationForKey:@"someKey"]` 移除
3. **替换**：同一个 key 再加动画会替换旧的
4. **去重**：用 key 判断是否已添加

**key 可以为 nil**，但那样就无法查询和精确移除了，不推荐。

## 五、动画的「表现层」和「模型层」

这是 Core Animation **最重要、最容易踩坑**的概念。

### 模型层（Model Layer）

你直接读写的属性：

objc

```
layer.position      // 读到的永远是「真实」值
layer.transform
layer.opacity
```



### 表现层（Presentation Layer）

屏幕上实际显示的属性：

objc

```
layer.presentationLayer.position   // 动画进行中的「当前显示值」
```



### 关键规则

**动画播放时，模型层的值不变，只有表现层在变。**

objc

```
CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"opacity"];
anim.fromValue = @1.0;
anim.toValue = @0.0;
anim.duration = 2.0;
[layer addAnimation:anim forKey:@"fade"];

// 动画进行中：
layer.opacity                  // 还是 1.0（模型层没变）
layer.presentationLayer.opacity // 0.5 左右（表现层在变）

// 动画结束后：
layer.opacity                  // 还是 1.0！跳回原值
```



**动画结束后，layer 立即「跳回」到模型层的值。** 这就是为什么：

+ 你的封面停止旋转时，**立即回到未旋转状态**（模型层 `transform` 从没变过）
+ 如果你想让 layer **停留**在终点，必须**同时修改模型层**：

objc

```
// 动画结束后停留在终点
anim.fromValue = @1.0;
anim.toValue = @0.0;
anim.removedOnCompletion = NO;      // 动画结束后不移除
anim.fillMode = kCAFillModeForwards; // 保持终点状态
[layer addAnimation:anim forKey:@"fade"];

// 但这只改了表现层，模型层还是 1.0
// 正确做法：动画结束后手动改模型层
layer.opacity = 0.0;
```



**对你的封面旋转**：因为动画是无限循环，停止时回到原位正是想要的效果，所以不需要处理模型层。这是**简化**，不是 bug。

## 六、完整示例：四种常见动画

### 1. 淡出

objc

```
CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
fade.fromValue = @1.0;
fade.toValue = @0.0;
fade.duration = 0.3;
fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
[layer addAnimation:fade forKey:@"fadeOut"];
layer.opacity = 0.0;   // 同时改模型层，动画结束后保持
```



### 2. 缩放

objc

```
CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
scale.fromValue = @1.0;
scale.toValue = @1.5;
scale.duration = 0.2;
scale.autoreverses = YES;   // 放大后自动缩回
[layer addAnimation:scale forKey:@"pulse"];
```



### 3. 旋转（你的封面）

objc

```
CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
rotation.fromValue = @0;
rotation.toValue = @(M_PI * 2);
rotation.duration = 20.0;
rotation.repeatCount = HUGE_VALF;
rotation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]; // 匀速
[layer addAnimation:rotation forKey:@"coverRotation"];
```



**注意**：你的原代码**没设 timingFunction**，默认是 `kCAMediaTimingFunctionDefault`（缓入缓出），这意味着**每圈开头和结尾会减速再加速**，转起来不是匀速的，视觉上会「一顿一顿」。如果你想要匀速旋转，应该显式设 `kCAMediaTimingFunctionLinear`。这是个可以优化的小点。

### 4. 沿 X 轴平移

objc

```
CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position.x"];
move.fromValue = @(layer.position.x);
move.toValue = @(layer.position.x + 100);
move.duration = 0.5;
[layer addAnimation:move forKey:@"moveRight"];
```



## 七、CABasicAnimation 的局限

`CABasicAnimation` 只能做**两个值之间的直线插值**。以下场景它做不了：

| 需求                         | 用什么                                   |
| :--------------------------- | :--------------------------------------- |
| 沿曲线/路径移动              | `CAKeyframeAnimation`（配 `path`）       |
| 多个关键点的复杂动画         | `CAKeyframeAnimation`                    |
| 多个动画同时/顺序播放        | `CAAnimationGroup`                       |
| 视图控制器转场               | `CATransition` 或自定义转场              |
| 物理效果（弹簧、重力）       | `UIAttachmentBehavior` 等 UIKit Dynamics |
| 交互式动画（可中断、可反向） | `UIViewPropertyAnimator`（iOS 10+）      |

**`CAKeyframeAnimation` 示例**（沿路径移动）：

objc

```
CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"position"];
UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:...];
anim.path = path.CGPath;
anim.duration = 2.0;
[layer addAnimation:anim forKey:@"moveAlongPath"];
```



## 八、性能与注意事项

**1. 尽量用 `transform`，别用 `frame` / `bounds`**

`transform` 动画由 GPU 处理，性能好；改 `frame` / `bounds` 会触发重新布局，性能差。

**2. 动画的 key 要唯一且语义化**

用 `static NSString * const kCoverRotationKey = @"coverRotation";` 而不是裸字符串，避免冲突和手误。

**3. 移除动画后模型层不变**

如果动画是「一次性」的（比如淡出），记得**同时改模型层**，否则移除动画后会跳回。

**4. 视图销毁时动画自动停止**

动画加在 layer 上，view 被释放时 layer 也释放，动画自然停止。但如果 view 还在但不再需要动画，要手动 `removeAnimationForKey:`。

**5. `removedOnCompletion` 默认是 YES**

动画播完自动移除。如果设成 NO，动画会一直留在 layer 上（但不再播放），配合 `fillMode = kCAFillModeForwards` 可以「保持终点状态」。

**6. 不要在 `layoutSubviews` 里加动画**

`layoutSubviews` 会多次调用，每次都加动画会叠加。应该在其他时机加，或者在 `layoutSubviews` 里用 key 检查避免重复。