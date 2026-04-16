# Appearance 外观管理 

在iOS13+ , Appearance 的优先级通常更高, 



## 基本概念

Appearance 是系统控件的外观配置对象, 也就是是 皮肤系统

在iOS13 之前, 直接修改控件的属性	

```objc
nav.navigationBar.barTintColor = [UIColor redColor];
nav.navigationBar.tintColor = [UIColor whiteColor];

nav.navigationBar.titleTextAttributes = @{
    NSForegroundColorAttributeName: [UIColor whiteColor]
};
```

特点: 

+ 每个属性单独设置
+ 分散、容易漏
+ 不好维护

iOS13 之后通过 Appearance 统一配置 

```objc
UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];

[appearance configureWithOpaqueBackground];
appearance.backgroundColor = [UIColor redColor];

appearance.titleTextAttributes = @{
    NSForegroundColorAttributeName: [UIColor whiteColor]
};

nav.navigationBar.standardAppearance = appearance;
nav.navigationBar.scrollEdgeAppearance = appearance;
```

特点：

+ 所有样式集中在一个对象里
+ 结构清晰
+ 可复用

## 设置导航栏的外观设置

在iOS13 之前, 直接修改导航栏的属性

### 设置背景不透明的方式

在iOS13 之前

```objc
    // 设置不透明
    // 默认是 YES, 透明
    self.navigationController.navigationBar.translucent = NO;
```

它控制的是 导航栏是否参与系统的半透明/模糊渲染, 默认是YES, 也就是透明的, 要改变导行栏的颜色, 就必须要设置为 NO; 否则不会生效 



在iOS13 之后 

```objc
[appearance configureWithOpaqueBackground];
```

它控制的是 导航栏的视觉样式系统是否为不透明风格

> 是“样式配置”（不是开关）
>
> 属于 UIKit 的统一外观系统
>
> 不直接影响 layout (布局分布)
>
> 可分别控制不同状态（standard / scrollEdge）



例如: 

```objc
    // 设置导航栏的背景颜色
    self.navigationController.navigationBar.barTintColor = [UIColor redColor]; 
```

这个写法现在已经废弃, 尽管编译器不会报错, 但是无法生效 

在iOS13 之前

```objc
   // 背景色
self.navigationController.navigationBar.barTintColor = [UIColor redColor]; 
 // 按钮颜色
self.navigationController.navigationBar.tintColor = [UIColor whiteColor];   
// 标题颜色
self.navigationController.navigationBar.titleTextAttributes = @{
    NSForegroundColorAttributeName: [UIColor whiteColor]
}; 
```

> tintColor 和 backgroundColor 区别
>
> background 指的是导航本身的颜色
>
> 而 barTintColot 则更加侧重于按钮, 图标, 可交互元素的颜色, 
>
> 例如, 在导航栏中, backgroundColor控制的是 导航栏的底色 
>
> 而 tintColor 控制的是导航栏上可以点击的 UI 的颜色 (按钮, 图标)

从 iOS13+开始使用 Appearance 来管理导航栏外观  

先创建一个 `UINavigationBarAppearance`  对象, 然后修改该对象的属性 

```objc
    UINavigationBarAppearance* appearance = [[UINavigationBarAppearance alloc] init];
```

设置背景颜色

```objc
appearance.backgroundColor = [UICOlor redColor]; 
```

设置标题颜色

```objc
    // 标题颜色
    appearance.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor redColor]
    };
```

设置按钮颜色

```objc
    // 按钮颜色(按钮的文字颜色)
    appearance.buttonAppearance.normal.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor blueColor]
    };
```

**在设置好属性之后, 还需要应用才能生效** 

```objc
    // 应用
    UINavigationBar* navbar = self.navigationController.navigationBar;
    navbar.standardAppearance = appearance;
    navbar.scrollEdgeAppearance = appearance;
    navbar.compactAppearance = appearance;
```

这三个其实是同一个导航栏在不同的使用场景下的外观配置

>  `standard`：普通状态
>   `scrollEdge`：滚动到顶部（大标题常见）
>   `compact`：高度变小（横屏 / 特殊场景）