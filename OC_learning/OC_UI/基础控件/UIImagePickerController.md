# UIImagePickerController

`UIImagePickerController` 是 iOS 中用于选择或拍摄媒体（图片、视频）的系统视图控制器。它提供了访问设备相册和摄像头的标准界面。 

## 主要用途 

+ 从相册选择图片/视频
+ 使用相机拍摄照片/视频
+ 支持简单的图片编辑（裁剪）

使用 UIImagePickerController 需要实现 `UIImagePickerControllerDelegate` 和 `UINavigationControllerDelegate` 

## 核心属性

### sourceType 图片来源

```objc
	UIImagePickerControllerSourceTypePhotoLibrary,  // 相册
    UIImagePickerControllerSourceTypeCamera,        // 相机
    UIImagePickerControllerSourceTypeSavedPhotosAlbum // 相机胶卷
```



### mediaTypes 媒体类型

```objc
// 默认只显示图片
picker.mediaTypes = @[(NSString *)kUTTypeImage];
// 显示图片和视频
picker.mediaTypes = @[(NSString *)kUTTypeImage, (NSString *)kUTTypeMovie];
```



### allowEditing 是否允许编辑

```objc
picker.allowsEditing = YES; // 允许用户裁剪图片
```



## 代理方法

### 选择完成时候调用

```objc
- (void)imagePickerController:(UIImagePickerController *)picker 
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    
    // 获取原始图片
    UIImage *originalImage = info[UIImagePickerControllerOriginalImage];
    
    // 获取编辑后的图片（如果 allowsEditing = YES）
    UIImage *editedImage = info[UIImagePickerControllerEditedImage];
    
    // 获取图片URL（如果是视频）
    NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
    
    // 获取媒体类型
    NSString *mediaType = info[UIImagePickerControllerMediaType];
    
    // 获取图片的原始元数据
    NSDictionary *metadata = info[UIImagePickerControllerMediaMetadata];
    
    [picker dismissViewControllerAnimated:YES completion:nil];
}
```



### 取消选择时调用

```objc
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
```

效果如下: 

![CleanShot 2026-08-06 at 16.19.16](/Users/lose_sea/Desktop/pintures/CleanShot 2026-08-06 at 16.19.16.gif)

## 完整代码如下

```objc
//
//  ViewController.m
//  UIImagePickController
//
//  Created by lose_sea on 2026/8/6.
//

#import "ViewController.h"
#import <Masonry/Masonry.h>
@interface ViewController () <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@property (nonatomic, strong) UIImageView* imageView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    UIButton* button = [UIButton buttonWithType: UIButtonTypeSystem];
    [self.view addSubview: button];
    [button mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.mas_equalTo(self.view).offset(50);
        make.left.mas_equalTo(self.view).offset(50);
        make.width.height.mas_equalTo(100);
    }];
    button.backgroundColor = [UIColor systemRedColor];
    [button setTitle: @"选择图片" forState: UIControlStateNormal];
    [button addTarget: self action: @selector(pressButton) forControlEvents: UIControlEventTouchUpInside];
    
    // 显示在 ImageView 上
    UIImageView* imageView = [[UIImageView alloc] init];
    [self.view addSubview: imageView];
    [imageView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.mas_equalTo(self.view);
        make.width.height.mas_equalTo(200);
    }];
    imageView.backgroundColor = [UIColor systemCyanColor];
    self.imageView = imageView;
}

- (void) pressButton {
    UIImagePickerController* imagePickerController = [[UIImagePickerController alloc] init];
    imagePickerController.delegate = self;
    imagePickerController.allowsEditing = YES;
    //  选择图片来源: 相册
    imagePickerController.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
    
    // 展示UIiamgePickerController
    [self presentViewController: imagePickerController animated: YES completion: nil];
}


- (void) imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    
//    UIImage* image = info[UIImagePickerControllerOriginalImage];
    
    // 获取编辑后的图片（如果 allowsEditing = YES）
    UIImage *editedImage = info[UIImagePickerControllerOriginalImage];
    
    self.imageView.image = editedImage;
    
    [picker dismissViewControllerAnimated: YES completion: nil];
    
    NSLog(@"choose");
}

- (void) imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    NSLog(@"cancel");
    [picker dismissViewControllerAnimated: YES completion: nil];
}


@end

```

