**一、这次改了什么**



 **HomeView.h / .m** — 真正的页面布局

 \- tableView（UITableViewStyleGrouped）铺满，底部 contentInset 预留 88pt 给全局 mini player，避免最后一行被挡

 \- tableHeaderView：标题「为你推荐」+ 横向 UICollectionView（卡片 150×212，间距 12，左右缩进 16）

 \- 删掉了头文件里那 4 个 player 控件属性：playerCoverView/playerTitleLabel/playerArtistLabel/playerPlayButton

 — 它们从未被创建，而 mini player 已经由 DrawerViewController 全局挂在底部，再建一份就是重复 UI



 **HomePlayListCardCell.m** — 补齐 +cardSize / configureWithData:（封面 150 方形 + 歌单名 + 两行描述），并加

 prepareForReuse



 **HomeViewTableViewCell.h / .m** — 歌曲行：56 封面 + 歌名 + 歌手 + 更多按钮，+rowHeight /

 configureWithSong:，删掉 awakeFromNib



 **HomeViewController.m** — 用 loadView 挂载 HomeView（而不是注释掉的 setUpInterface）；实现

 tableView/collectionView 的 dataSource + delegate：

 \- 点歌曲行 → [[PlayerViewController sharedInstance] playSong:]

 \- 点歌单卡片 → push SongListShowViewController

 \- 私有方法 croppedToSquare:size: 移到类扩展里声明，清掉注释残留



 **二、已实现部分的不规范之处**



 **会崩 / 会白屏（优先修）**

1. HomeViewController.m:18 声明了 <UITableViewDelegate, UITableViewDataSource> 却一个方法都没实现 →

 编译警告，一旦设为 delegate 必崩。现在已补齐。

2. homeView 属性声明了但从未创建，setUpInterface 被注释掉 → 首页全白。
3. HomePlayListCardCell.h 声明了 +cardSize / configureWithData:，.m 是空的 →

 调用即崩；声明与实现不一致是最危险的一类。

4. DrawerViewController.m:95 insertSubview:self.maskView belowSubview:self.menuViewController.view —— 此时

 menu 的 view 还没加进层级，层级关系不可靠；应先加 main → mask → menu。

5. DrawerViewController.m:56 在 viewDidLoad 里用 self.view.bounds.size.width 算 menuWidth，此时 bounds

 尚未确定；应放 viewDidLayoutSubviews 或改用比例约束。



 **命名与组织**

6. HomePlayListCardCell（PlayList 大写 L）和复用标识 HomePlaylistCardCellID（Playlist）大小写不一致；目录

 HomeViewCell 装的是 HomeViewTableViewCell，HomePlayListCardCell 目录又是 HomePlayListCardCell — 建议「目录名

 = 文件名 = 类名」。

7. 文件头注释与文件名不符：SongListCard.h 写 PlayListView.h、SongListShowViewController.m 写

 SongListViewController.m、DrawerViewController 写 DrawViewController。

8. 保留了 awakeFromNib / drawRect 等 xib 模板注释，纯代码项目应删。



 **头文件暴露过头**

9. HomeView.h 重复 import Masonry 两遍，还 import 了没用到的 Song.h / Singer.h；Masonry 属于实现细节，只应在

 .m 引。

10. SongListCard.h:13-14 把 UIImageView / UILabel 直接暴露成可写的 strong 属性 —— 子控件应放进 .m

 的类扩展，对外只给一个 configure 方法（我在两个 Cell 里就是这么做的）。

11. Masonry 引用写法不统一：有的 #import <Masonry/Masonry.h>，有的 #import "Masonry.h"。



 **架构耦合**

12. HomeModel.samplePlaylistCards 返回 NSDictionary 当模型用，View 里 data[@"image"]

 完全没有编译期检查；项目里已经有 SongListCard / SongListModel 却闲置 —— 建议建一个 Playlist 模型。

13. HomeModel.m:33 模型层直接 [UIImage imageNamed:] 持有 UIImage，模型不该管图片资源，应只存图片名/URL，由

 View 层用 SDWebImage 加载。

14. pressMenuButton 直接取 window.rootViewController 强转 DrawerViewController —— VC

 之间硬耦合，改用通知/delegate/responder 链更合适。

15. PlayerViewController 做成 sharedInstance 单例 VC 再被 addChildViewController，viewDidLoad

 只走一次且内存常驻；mini player 做成 UIView 单例更稳。



 **其它小问题**

16. PlayerViewController.m:19 有个多余的文件作用域 static PlayerViewController *instance = nil;，与

 sharedInstance 内部的 static 同名，删掉。

17. PlayerView.m:32-33 连续两次赋值 backgroundColor（systemRed 立刻被覆盖）—— 调试残留。
18. SceneDelegate.m:49 菜单页又套了一层 UINavigationController（菜单通常不需要导航栏）；搜索 tab 的

 selectedImage 和 image 是同一个图标，选中态看不出变化。

19. Podfile 写 platform :ios, '13.0'，工程实际是 26.2；leadingItemGroups 是 iOS 16+

 API，两边不一致时容易埋坑。