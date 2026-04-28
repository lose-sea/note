## UITableViewCell的创建及复用机制

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

首先必须要在 `viewDidLoad` 中注册cell 

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



这种写法不能设置副标题,而老式写法可以通过创建的方法设置副标题

```objc

```





注册时的 ID 和取 Cell 时的 ID **必须完全一致**，ID 是复用池的钥匙，不一致直接崩溃。

 也就是说

```objc
[_tableView registerClass: [UITableViewCell class] forCellReuseIdentifier: @"cell"]; 


- (UITableViewCell*) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell* cell = [_tableView dequeueReusableCellWithIdentifier: @"cellID" forIndexPath: indexPath];
    if (indexPath.row == 0) {
        cell.textLabel.text = @"hello ";
    } else {
        if (indexPath.row < _arrayData.count) {
            cell.textLabel.text = _arrayData[indexPath.row];
        }
    }
    
    return cell;
}
```



设置单元格的效果

```objc
// 单元格显示状态
- (UITableViewCellEditingStyle) tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 默认显示删除状态
//    return UITableViewCellEditingStyleDelete;

    // 插入状态
//    return UItableViewCellEditingStyleInsert;
    // 空状态
//    return UITableViewCellEditingStyleNone;

    // 多选状态
//    return UITableViewCellEditingStyleDelete|UITableViewCellEditingStyleInsert;

    return UITableViewCellEditingStyleDelete;
}
```

> 多选状态编译器不会自动补全,需要手动实现,  `UITableViewCellEditingStyleDelete|UITableViewCellEditingStyleInsert;`

选中单元格和取消选中单元格调用的方法

```objc
// 选中单元格时调用
- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
//    NSLog(@"选中单元格: %ld %ld", indexPath.section, indexPath.row);
}

// 取消选中(切换选中时调用)
- (void) tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    NSLog(@"取消选中单元格: %ld %ld", indexPath.section, indexPath.row);
}
```



### 复用流程

注册 → 取出 → 填数据 → 显示，三个环节 ID 必须是同一个字符串。 



总结一下就是

> 注册什么 ID，取的时候就写什么 ID，字符串必须一模一样。 

如果在配置cell 的时候使用的 ID 是没有被注册的, 那就会报错

### Cell的复用

在 iOS 里，UITableView 的 **cell 复用机制（reuse mechanism）** 是它性能高的核心原因之一。可以把它理解成一个“对象池”。 

**一旦 cell 不在可见区域，就会被回收进复用池**
  **当需要新 cell 时，会优先从池子里拿来用**  

**cell 滑出屏幕 –>  进入复用池（备用）–>  当需要新 cell 时 –>  优先从池子拿**



如果一个列表有 1000 行，不可能真的创建 1000 个 cell。

 实际上只会创建：屏幕可见的 cell（比如 10 个）,以及少量缓存（比如 2~3 个）

其余的都靠 **复用（reuse）**。

> 当有cell滑出屏幕时，会将其放入到一个set中（相当于一个重用池），当UITableView要求返回cell的时候，datasource会先在集合中查找是否有闲置的cell，若有则会将数据配置到这个cell中，并将cell返回给UITabelView。 这大大减少了内存的开销。
> 因为我在滚动的过程中会出现一个将cell滚出屏幕外的时候，这时候如果我们一直创建cell的话，如果cell太多了就会出现一个内存开销过多的一个问题。所以我们要采用这个复用的方式来提高内存利用率。 

## 编辑TableView 的数据

可以通过为导航栏添加按钮来实现对tableView 中单元格的数据进行编辑  

用一个可变数组来作为tebleView 的数据源

```objc
for (int i = 0; i < 20; i++) {
        NSString* str = [NSString stringWithFormat: @"%d 号数据", i + 1];
        [_arrayData addObject: str];
//        [_tableView reloadData];
    }
```

在cell 配置的时候设置显示 可变数组中的内容

```objc
cell.textLabel.text = _arrayData[indexPath.row];
```

然后向导航栏添加按钮来通过事件的调用来编辑

```objc
- (void) createBtn {
    _btnEdit = [[UIBarButtonItem alloc] initWithTitle: @"Edit" style: UIBarButtonItemStylePlain target: self action: @selector(pressEdit)];
    self.navigationItem.rightBarButtonItem = _btnEdit;
    
    _btnDelete = [[UIBarButtonItem alloc] initWithTitle: @"删除" style: UIBarButtonItemStylePlain target: self action: @selector(pressDelete)];
    
    _btnFinish = [[UIBarButtonItem alloc] initWithTitle: @"完成" style: UIBarButtonItemStylePlain target: self action: @selector(pressFinish)];
    
    self.navigationItem.rightBarButtonItem = _btnEdit;
} 
```



```objc
- (void) pressEdit {
    _isEdit = YES;
    self.navigationItem.rightBarButtonItem = _btnFinish;
    [_tableView setEditing: YES];
    self.navigationItem.leftBarButtonItem = _btnDelete;
}
- (void) pressDelete {
    NSLog(@"press the delete");
}

- (void) pressFinish {
    self.navigationItem.rightBarButtonItem = _btnEdit;
    [_tableView setEditing: NO];
    self.navigationItem.leftBarButtonItem = nil;
}
```

上述按钮事件中 `[_tableView setEditing: YES]; `的作用是进入编辑状态

`[_tableView setEditing:YES animated:YES];` 是带动画的写法 



向导航栏添加按钮

```objc
- (void) createBtn {
    _btnEdit = [[UIBarButtonItem alloc] initWithTitle: @"Edit" style: UIBarButtonItemStylePlain target: self action: @selector(pressEdit)];
    self.navigationItem.rightBarButtonItem = _btnEdit;
    
    _btnDelete = [[UIBarButtonItem alloc] initWithTitle: @"删除" style: UIBarButtonItemStylePlain target: self action: @selector(pressDelete)];
    
    _btnFinish = [[UIBarButtonItem alloc] initWithTitle: @"完成" style: UIBarButtonItemStylePlain target: self action: @selector(pressFinish)];
    
    self.navigationItem.rightBarButtonItem = _btnEdit;
}
```

然后通过`tableView commitEditingStyle: forRowAtIndexPath:` 来对数据进行操作 

例如下面删除操作: 

```objc
- (void) tableView: (UITableView*) tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    // 删除数据源对应的数据
    [_arrayData removeObjectAtIndex: indexPath.row];

    // 当数据发生变化, 重新加载数据
    [_tableView reloadData];
    NSLog(@"delete");
}
```

直接对数据源的可变数组进行编辑, 然后让 cell  从可变数组重新读取, 就实现了对数据的编辑

> 注意: 在对数据进行操作之后, 一定要重新加载数据, 
>
> 调用 [_tableView reloadData]; 方法, 否则无法显示不会改变 

