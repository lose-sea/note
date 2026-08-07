# PHPicker

之前笔学习了用 `UIImagePickerController` 来访问设备上的图片, 但是UIImagePickerController 有一个很大的局限, 那就是一次只能选择一张图片, 但是很多时候, 我们访问相册之后需要选择多张图片, 于是, 笔者了解到了用 `PHPicker` 来选择访问相册可以选择多张图片. 

下面笔者就来介绍一下 PHPIcker 的使用  

要使用PHPicker主要分为三步, 分别是 `PHPickerConfiguration` 配置,  `PHPickerViewController` 展示和 `PHPickerResult` 结果处理 

首先我们需要引入框架 `<PhotosUI/PhotosUI.h>` 并遵守 `<PHPickerViewControllerDelegate>` 协议, 配置选择器的核心是 `PHPickerConfiguration` 对象 

## 配置并创建相册选择器 

```objc
	// 创建配置
PHPickerController* config = [[PHPickerConfiguration alloc] init]; 
	// 设置筛选类型: 图片
config.filter = [PHPickerFilter imagesFilter]; 
	// 设置最大选择数量 (0 表示不限制) 
config.selectionLimit = 9; 
	// 创建并展示选择器 
PHPickerViewController* picker = [[PHPickerViewController alloc] initWithConfiguration: config]; 
	// 设置代理
picker.delegate = self;  

	// 弹出相册选择的视图
[self presentViewController: picker animated: YES complection: nil]; 
```



## 选择完成图片之后调用方法

```objc
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    
    if (results.count == 0) {
        NSLog(@"cancel");
        return;
    }
    
    // 处理选中的图片
    for (PHPickerResult *result in results) {
        // 获取 UIImage
        if ([result.itemProvider canLoadObjectOfClass:[UIImage class]]) {
            [result.itemProvider loadObjectOfClass:[UIImage class]
                                 completionHandler:^(__kindof id<NSItemProviderReading>  _Nullable object,
                                                     NSError * _Nullable error) {
                if (error) {
                    NSLog(@"加载图片失败: %@", error);
                    return;
                }
                
                UIImage *image = (UIImage *)object;
                [self.images addObject: image];
                // 在主线程更新 UI
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self displayImage];
                });
            }];
        }
        
    }
}
```

当用户选择完成图片之后, 就会调用`- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results` 方法 , 这个方法是 `PHPickerViewControllerDelegate` 协议中**唯一必须实现**的核心方法，当用户在系统相册选择器中完成选择（或取消）时被调用

> 参数一 : picker: 触发这个代理方法的 `PHPickerViewController` 实例本身
>
> 在关闭选择器界面的时候, 需要用到
>
> ```objc
> [picker dismissViewControllerAnimated:YES completion:nil];
> ```



> 参数二 : results 类型是一个 `PHPickerResult` 对象的数组
>
> results有两种状态: 
>
> 1. 用户取消了选择
>
>    results.count == 0; 
>
>    results 是一个空数组, 这个时候需要直接关闭选择器并返回, 不做任何图片处理  
>
> 2. 用户完成了选择 
>
>    results 包含了用户按顺序选中的所有资源对象 
>
>    数组中每一个元素都是一个 `PHPickerResult` 实例, 代表用户点选的一个图片或者视频

`PHPickerResult` 内部并不直接包含图片的 `UIImage` 或 `NSData`，它更像一个**“凭证”或“引用”**，通过其 `itemProvider` 属性（一个 `NSItemProvider` 对象）来按需加载实际数据。这正是系统为了隐私保护而设计的——App 无权直接读取相册，只能通过这个“凭证”去申请加载用户选中的那一份数据。



在方法内部，需要通过 `result.itemProvider` 来加载数据，具体流程是：

1. **检查能力**：调用 `[result.itemProvider canLoadObjectOfClass:[UIImage class]]` 确认能否加载为图片。
2. **异步加载**：调用 `loadObjectOfClass:completionHandler:` 方法。

+ 这是一个**异步操作**，系统会在后台线程解码图片数据。
+ 加载成功后，`object` 参数才是你真正需要的 `UIImage` 对象。
+ `completionHandler` 回调默认在**后台线程**，所以里面所有 UI 更新代码必须包裹在 `dispatch_async(dispatch_get_main_queue(), ^{...});` 中。

常用的类型: 

`[UIImage class]` : 加载完为 UIImage 对象 

`[NSData class]`: 加载为原始图片/视频数据 

`[NSURL class]`: 加载为文件URL 

```objc
- (NSProgress *)loadObjectOfClass:(Class <NSItemProviderReading>)aClass 
                completionHandler:(void (^)(__kindof id<NSItemProviderReading> _Nullable object, 
                                           NSError * _Nullable error))completionHandler;
```

`(void (^)(__kindof id<NSItemProviderReading> _Nullable object, NSError * _Nullable error))completionHandler`

这是一个Block 回调, 在异步加载完成后执行 

##### `object: (__kindof id<NSItemProviderReading> _Nullable)`

+ **类型**：`__kindof` 表示返回的对象是 `aClass` 或其子类的实例。
  + 如果请求 `[UIImage class]`，这里就是 `UIImage *`。
  + 如果请求 `[NSURL class]`，这里就是 `NSURL *`。
+ **状态**：
  +  **成功**：返回实际的数据对象。
  +  **失败**：返回 `nil`（此时 `error` 不为 nil）。

##### `error: (NSError * _Nullable)`

+ **成功时**：`nil`。
+ **失败时**：包含错误信息的 `NSError` 对象。
  + 常见错误码：
    + `NSItemProviderUnavailableError`：类型不支持。
    + `NSCocoaErrorDomain` + `NSFileReadNoPermissionError`：权限问题。
    + 内存不足导致的解码失败等。