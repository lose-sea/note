# tableView

tableView 的本质是 **一个高性能的滚动列表容器**  



必须要实现两个协议: 

```objc
<UITableViewDataSource> 
<UITableViewDelegate>
```



DataSource (数据源) 表示的是 “显示什么” 

必须实现两个协议 (@required)

`- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section;` 决定了每组有多少行的内容  

```objc
// 设置每个section 有多少行
- (NSInteger) tableView: (UITableView*)tableView numberOFRowsInsection: (NSInteger) section {
    return 10; 
}
```



`- (UITableViewCell*) tableView: (UITableView*) tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath; ` 设置单元格内容 

```objc
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CellID" 
                                                            forIndexPath:indexPath];
    cell.textLabel.text = self.dataArray[indexPath.row];
    return cell;
}
```

> Cell 的详细内容, 下文会详细讲解



可选实现: 

```objc
// 设置组数
// 默认是 1 
- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
} 

// 设置行高
- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 100;
}

// 头标题
- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"title of head";
}

// 尾标题
- (NSString*) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"title of tail";
} 

// 获取头部高度
- (CGFloat) tableView: (UITableView*) tableView heightForHeaderInSection:(NSInteger)section {
    return 100;
}

// 尾部高度
- (CGFloat) tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 200;
}
```



DataSource = 提供数据 + 创建 Cell



Delegate (代理) 决定的是 “怎么交互” 

常用的方法有: 

```objc
// 行被点击的时候调用的方法
- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    NSLog(@"选中了 %ld %ld", indexPath.section, indexPath.row); 
} 

// 取消选中(切换选中时调用)
- (void) tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    NSLog(@"取消选中单元格: %ld %ld", indexPath.section, indexPath.row);
} 
```



## Cell 的创建及复用机制

`- (UITableViewCell*) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath ` 方法有两种写法

写法一: 

```objc
- (UITableViewCell*) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString* str = @"cell";
    UITableViewCell* cell = [_tableView dequeueReusableCellWithIdentifier: str];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle: UITableViewCellStyleDefault reuseIdentifier: str];
    }
    cell.textLabel.text = _arrayData[indexPath.row];
    return cell;
}
```

`UITableViewCell* cell = [_tableView dequeueReusableCellWithIdentifier: str];` 的意思是向 tableView 要一个 **可以重复使用的 cell**  

它的流程是: 

1. 屏幕上显示 10 个 cell
2. 你往下滑
3. 上面的 cell 滑出屏幕
4. 这些 cell 被放进“复用池”
5. 新出现的位置 → 从池子里拿 cell 

如果池子里面有, 就返回一个旧的 cell

如果没有就返回 nil  



写法二:  

首先必须要在 `viewDidDown` 中注册cell 

```objc
[self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"CellID"];
```

这行代码的意思就是

告诉 tableView：如果没有可复用的 cell，就用这个类（UITableViewCell）创建一个，标识叫 CellID

然后在`UITableViewCell* cell = [_tableView dequeueReusableCellWithIdentifier: str]` 的方法中就可以这样写: 

```objc
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CellID" 
                                                            forIndexPath:indexPath];
    cell.textLabel.text = self.dataArray[indexPath.row];
    return cell;
}
```

这段代码的流程是: 

1. 去复用池找 CellID 的 cell
2. 有 → 直接拿（旧 cell）
3. 没有 → 用 UITableViewCell 自动创建一个
4. 返回（保证一定不为 nil） 

因为已经注册了,系统知道如何去创建, 反之, 如果没有在 viewDidLoad 中写`[self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"CellID"]` cell的注册, 系统就不知道如何去创建, 程序就会崩溃



### Cell的复用机制

在 iOS 里，UITableView 的 **cell 复用机制（reuse mechanism）** 是它性能高的核心原因之一。可以把它理解成一个“对象池”。 

**一旦 cell 不在可见区域，就会被回收进复用池**
  **当需要新 cell 时，会优先从池子里拿来用**  

**cell 滑出屏幕 –>  进入复用池（备用）–>  当需要新 cell 时 –>  优先从池子拿**



如果一个列表有 1000 行，不可能真的创建 1000 个 cell。

 实际上只会创建：

屏幕可见的 cell（比如 10 个）

以及少量缓存（比如 2~3 个）

其余的都靠 **复用（reuse）**。
