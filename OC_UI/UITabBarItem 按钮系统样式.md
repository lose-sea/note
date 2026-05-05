# UITabBarItem 按钮系统样式

## 常用样式 

通过系统样式来创建按钮 

```objc
UITabBarItem* tabbarItem = [[UITabBarItem alloc] initWithTabBarSystemItem: UITabBarSystemItemSearch tag: 1];
```



| 枚举值                        | 效果     |
| ----------------------------- | -------- |
| `UITabBarSystemItemSearch`    | 🔍 搜索   |
| `UITabBarSystemItemFavorites` | ⭐ 收藏   |
| `UITabBarSystemItemBookmarks` | 📖 书签   |
| `UITabBarSystemItemHistory`   | 🕐 历史   |
| `UITabBarSystemItemContacts`  | 👤 联系人 |
| `UITabBarSystemItemMore`      | ··· 更多 |





# 通过图片来创建按钮

首页: 

```objc
    //创建系统风格按钮
    UITabBarItem* tabbarItem = [[UITabBarItem alloc] initWithTitle: @"搜索" image: [UIImage systemImageNamed: @"Search"] selectedImage: [UIImage systemImageNamed: @"Search.fill"]];
    self.tabBarItem = tabbarItem;
```

效果: 

<img src="/Users/lose_sea/Desktop/pintures/image-20260505180037782.png" alt="image-20260505180037782"  />

```objc
// 首页, 按钮为一个房子形状
    homepage.tabBarItem = [[UITabBarItem alloc] initWithTitle: @"首页" image: [UIImage systemImageNamed: @"house"] selectedImage:[UIImage systemImageNamed: @"house.fill"]];
    
    // 搜索,按钮为一个放大镜形状
    // magnifyingglass  放大镜
    searchpage.tabBarItem = [[UITabBarItem alloc] initWithTitle: @"搜索" image:[UIImage systemImageNamed: @"magnifyingglass"] selectedImage:[UIImage systemImageNamed: @"magnifyingglass.fill"]];
    
    searchpage.tabBarItem = [[UITabBarItem alloc] initWithTabBarSystemItem: UITabBarSystemItemSearch tag: 1];
    
    // 购物, 按钮为一个购物车形状
    shoppage.tabBarItem = [[UITabBarItem alloc] initWithTitle: @"购物" image: [UIImage systemImageNamed: @"cart"] selectedImage: [UIImage systemImageNamed: @"cart.fill"]];
    
    // 我的,按钮为一个人的形状
    mypage.tabBarItem = [[UITabBarItem alloc] initWithTitle: @"我的" image: [UIImage systemImageNamed: @"person"] selectedImage: [UIImage systemImageNamed: @"person.fill"]];
```

