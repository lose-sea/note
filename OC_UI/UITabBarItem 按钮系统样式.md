

# 常用样式

| 枚举值                        | 效果     |
| ----------------------------- | -------- |
| `UITabBarSystemItemSearch`    | 🔍 搜索   |
| `UITabBarSystemItemFavorites` | ⭐ 收藏   |
| `UITabBarSystemItemBookmarks` | 📖 书签   |
| `UITabBarSystemItemHistory`   | 🕐 历史   |
| `UITabBarSystemItemContacts`  | 👤 联系人 |
| `UITabBarSystemItemMore`      | ··· 更多 |

首页: 

```objc
    //创建系统风格按钮
    UITabBarItem* tabbarItem = [[UITabBarItem alloc] initWithTitle: @"搜索" image: [UIImage systemImageNamed: @"Search"] selectedImage: [UIImage systemImageNamed: @"Search.fill"]];
    self.tabBarItem = tabbarItem;
```

效果: 

<img src="/Users/lose_sea/Desktop/pintures/image-20260505180037782.png" alt="image-20260505180037782"  />