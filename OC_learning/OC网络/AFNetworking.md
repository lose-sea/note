# AFNetworking

之前笔者学习了网络请求的相关内容, 网络请求主要分为一下几个步骤: 

1. 创建请求地址
2. 创建请求类
3. 配置会话
4. 创建会话
5. 生成任务
6. 启动任务

下面是以获取城市的天气信息为例, 展示一下创建网络请求的几个步骤

```objc
- (void) createURL {
    // 创建请求地址
    NSString* str = @"https://api.weatherapi.com/v1/forecast.json?key=3557d02150d248e6b0735224252907&q=西安&days=1";
    NSURL* url = [NSURL URLWithString: str];
    
    // 创建请求类
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url];
    // HTTP 方法
    request.HTTPMethod = @"GET";
    // 时间阈值
    request.timeoutInterval = 15;
    
    // 配置会话
        // 使用默认配置
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    // 创建会话
    NSURLSession* session = [NSURLSession sessionWithConfiguration: config
                                                          delegate: nil
                                                     delegateQueue: [NSOperationQueue mainQueue]];

        // 创建任务
            // 通过URL 进行创建
    //    NSURLSessionDataTask* task = [session dataTaskWithURL: url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
    //
    //    }];
    
    
        // 通过 Request 创建
    NSURLSessionDataTask* task = [session dataTaskWithRequest: request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            NSLog(@"请求失败: %@", error);
        } else {
            NSError* jsonError = nil;
            // 调用苹果原生 API 将服务器返回的二进制数据 (NSData) 转换为 Objective-C对象
            // 传入错误指针的地址, 如果二进制数据不是合法的 JSON 格式（比如缺了一个引号，或者是 HTML 报错页），jsonError 就会被赋值为一个包含具体错误原因的对象，而方法本身会返回 nil。
            id dict = [NSJSONSerialization JSONObjectWithData: data options:0 error: &jsonError];
            if (jsonError) {
                NSLog(@"JSON 解析失败");
            } else {
                NSLog(@"%@", dict);
            }
        }
    }];
    
    [task resume];
}
```

详细的讲解可以看笔者的上一篇博客 [iOS: 网络请求再学习](https://editor.csdn.net/md?articleId=163443102) ,详细讲解了创建网络请求的几个步骤和对应的方法

这里笔者介绍一下 第三方库的使用 - AFNetworking 

简单来说，`AFNetworking` 是对 `NSURLSession` 的一次**高度封装**。它保留了原生技术的强大能力，但将复杂的底层细节隐藏起来，提供了一套更简洁、更现代的 API，极大地提升了开发效率

下面使用 AFNetworking 实现上面的获取城市天气信息的功能 

```objc
// 使用AFNetworking创建网路请求
- (void) createAFNetworking {
    // 创建管理器
    AFHTTPSessionManager* manager = [AFHTTPSessionManager manager];
    
    // 设置超时时间 对应原生的 request.timeoutInterval
    manager.requestSerializer.timeoutInterval = 15;
    
    // 设置响应格式 默认为JSON
    manager.responseSerializer = [AFJSONResponseSerializer serializer];

    // 拆解 URL 参数
    NSDictionary* parameters = @{@"key": @"3557d02150d248e6b0735224252907", @"q": @"西安", @"days": @"1"};
    
    //发起GET请求
    [manager GET: @"https://api.weatherapi.com/v1/forecast.json"
      parameters: parameters
         headers: nil
        progress:nil
         success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSLog(@"%@", responseObject);
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSLog(@"请求失败");
    }];
}
```



## 创建管理器

```objc
AFHTTPSessionManager* manager = [AFHTTPSessionManager manager];
```

`AFHTTPSessionManager` 是 AFNetworking 中最核心的类, 专门用于处理 HTTP/HTTPS 请求, 它继承自 AFURLSessionManager, 后者直接与NSURLSession 交互

+ **`manager` 类方法**：这是一个工厂方法，内部创建了一个使用 `defaultSessionConfiguration` 的 `AFHTTPSessionManager` 实例。该实例拥有自己的 `NSURLSession`，并配置了默认的请求/响应序列化器。
+ **单例或属性**：通常我们会将 `manager` 作为属性或单例持有，以便复用（如设置统一的超时、Header 等）。这里作为局部变量，请求结束后会释放，但 AFNetworking 内部会持有任务直到完成，所以不影响使用。

## 属性设置

### 设置超时时间

```
manager.requestSerializer.timeoutInterval = 15;
```



+ **`requestSerializer`** 是 `AFHTTPRequestSerializer` 或其子类的实例，负责将参数、文件等编码成 `NSURLRequest`。
+ **`timeoutInterval`** 对应原生 `NSMutableURLRequest.timeoutInterval`，即**从请求开始到接收到服务器第一个响应包的最大等待时间**。设置为 15 秒，覆盖了 AFNetworking 默认的 60 秒。
+ 注意：这里设置的是该 manager **所有请求**的默认超时。如果有不同请求需要不同超时，可以在每次调用前修改，或者使用 `requestWithMethod:...` 单独构建。

### 设置响应格式

```
manager.responseSerializer = [AFJSONResponseSerializer serializer];
```

+ **`responseSerializer`** 负责将服务器返回的原始 `NSData` 转换为对象。
+ **`[AFJSONResponseSerializer serializer]`** 创建一个 JSON 解析器，它会将合法的 JSON 数据自动转换成 `NSDictionary` 或 `NSArray`，并作为 `success` 回调的 `responseObject` 参数传入。
+ 这行可以省略, 因为 `AFHTTPSessionManager` 的 `responseSerializer` 默认就是 `AFJSONResponseSerializer` 的实例。如果不写这一行，AFNetworking 依然会自动解析 JSON。只有在需要返回原始数据（如下载图片、解析 XML）时，才需要显式改为 `[AFHTTPResponseSerializer serializer]`。

> 在原生 `NSURLSession` 中,对于服务器返回的二进制数据 (NSData), 需要我们手动调用系统的API进行转换, 例如,在上面的例子中, 我们调用了`id dict = [NSJSONSerialization JSONObjectWithData: data options:0 error: &jsonError];` 



## URL 参数拆解

```
NSDictionary* parameters = @{@"key": @"3557d02150d248e6b0735224252907", @"q": @"西安", @"days": @"1"};
```



+ 这里将原本直接拼接到 URL 后的查询参数，写成了一个字典。
+ **AFNetworking 会自动处理参数编码**：
  + 对于 GET 请求，会将字典中的键值对按 `key=value` 格式拼接，并**自动进行 URL 百分号编码**（例如“西安”会被编码为 `%E8%A5%BF%E5%AE%89`），然后添加到 URL 的 `?` 之后。
  + 对于 POST 请求，默认会将参数编码为 `application/x-www-form-urlencoded` 放在请求体中；若需要 JSON 格式的 Body，可切换 `requestSerializer` 为 `AFJSONRequestSerializer`。
+ 这种字典传参方式远比手动拼接字符串更安全、更清晰，且避免了手动编码错误。

## 发起GET请求

```objc
[manager GET: @"https://api.weatherapi.com/v1/forecast.json"
   parameters: parameters
      headers: nil
     progress: nil
      success: ^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
         NSLog(@"%@", responseObject);
     } failure: ^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
         NSLog(@"请求失败");
     }];
```

#### 1. `GET: @"https://..."` —— 请求 URL（基础地址）

+ 这里传入的 URL **不带任何查询参数**，因为参数单独放在 `parameters` 中，由 AFNetworking 自动拼接。

#### 2. `parameters: parameters` —— 请求参数

+ 传入参数字典，AFNetworking 会将其序列化并附加到 URL 后（因为这是 GET 请求）。

#### 3. `headers: nil` —— 自定义请求

+ 如果需要添加额外的 HTTP Header（如 `Authorization`、`Content-Type`），可在此传入一个字典。这里传 `nil` 表示不添加额外头部。

#### 4. `progress: nil` —— 下载进度回调

+ 用于跟踪请求的进度（如文件下载）。由于这是一个简单的数据请求，不需要进度监控，所以传 `nil`。

#### 5. `success` 块 —— 请求成功

+ **`task`**：当前执行的数据任务对象，可用于获取任务信息。
+ **`responseObject`**：已经由 `responseSerializer` 解析好的对象。因为我们是 JSON 序列化器，所以这里是一个 `NSDictionary`（包含天气信息）。**无需手动调用 `NSJSONSerialization`**，AFNetworking 已经完成了转换。
+ 代码中直接打印 `responseObject`，控制台会输出解析后的字典。

#### 6. `failure` 块 —— 请求失败

+ **`error`**：包含失败原因的 `NSError` 对象，可能是网络超时、证书问题、服务器返回 4xx/5xx 状态码或 JSON 解析失败等。
+ 当前代码只打印 `@"请求失败"`，未输出具体错误信息。**建议改为** `NSLog(@"请求失败: %@", error);` 以便调试。

# AFNetworking 中的GET请求 和 POST请求

无论是 GET 还是 POST 请求，都可以通过 `AFHTTPSessionManager` 的相应方法来发起。它们的方法签名非常相似，保持了 API 的一致性。

#### GET 请求

通常用于从服务器**获取**数据。

```objc
[manager GET:URLString
   parameters:parameters
      headers:headers
     progress:progress
      success:successBlock
      failure:failureBlock];
```

#### POST 请求

通常用于向服务器**提交**数据。

```objc
[manager POST:URLString
    parameters:parameters
       headers:headers
      progress:progress
       success:successBlock
       failure:failureBlock];
```

可以看到，两者的调用方式几乎一模一样。 

下面是一个POST请求的例子

```objc
- (void) createAFNetworkingPOST {
    AFHTTPSessionManager* manager = [AFHTTPSessionManager manager];
    manager.requestSerializer.timeoutInterval = 15;
    
    NSDictionary* parameters = @{@"title": @"exersice",
                                 @"body": @"hello xinyan",
                                 @"userId": @"1"};
    
    [manager POST: @"https://jsonplaceholder.typicode.com/posts"
       parameters: parameters
          headers: nil
         progress: nil
          success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
    
            NSLog(@"POST 请求成功, 返回数据: %@", responseObject);

            NSLog(@"任务是 %@", task);
        
            // 你可以在这里尝试取出服务器返回的 id
            if ([responseObject isKindOfClass:[NSDictionary class]]) {
                NSNumber *newId = responseObject[@"id"];
                NSLog(@"创建资源的 ID 是: %@", newId);
            }
            
        } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
            NSLog(@"请求失败");
        }];
}
```

最终打印: 

![image-20260803201249409](/Users/lose_sea/Desktop/pintures/image-20260803201249409.png)

GET 和 POST 的区别主要是语义和参数的传递方式, GET请求 的参数是附加在 URL 后面, 而POST请求的参数是放在HTTP请求的Body中的, 
