## 一、Homebrew 安装软件的固定目录规则

### 1. Apple Silicon（M1/M2/M3）芯片

+ 真实程序存放根目录：

  ```
  /opt/homebrew/Cellar/
  ```

  

  例如 git-lfs：

  ```
  /opt/homebrew/Cellar/git-lfs/版本号/
  ```

+ 软链接（终端调用入口）：`/opt/homebrew/bin/git-lfs`

### 2. Intel 芯片 Mac

+ 真实程序存放根目录：

  ```
  /usr/local/Cellar/
  ```

  

  例如 git-lfs：

  ```
  /usr/local/Cellar/git-lfs/版本号/
  ```

+ 软链接（终端调用入口）：`/usr/local/bin/git-lfs`

所有 brew 安装的工具都会统一放在 `Cellar` 下，brew 统一管理升级、卸载、多版本切换。

------

## 二、官网 `.pkg` 手动安装（其他方式）路径

Git LFS 官方 pkg 安装包，会把程序直接放到**系统全局目录**：

1. 二进制程序：`/usr/local/bin/git-lfs`
2. 配套资源文件：`/usr/local/share/git-lfs/`
3. 不会存在 Cellar 目录，不受 Homebrew 管理CSDN博...

### 核心差异对比表

表格







| 安装方式       | 真实文件存放位置                                             | 管理方式                           |
| :------------- | :----------------------------------------------------------- | :--------------------------------- |
| Homebrew       | `/opt/homebrew/Cellar`（M 系列）`/usr/local/Cellar`（Intel） | brew 统一升级 / 卸载 / 切换版本    |
| 官网 pkg 安装  | `/usr/local/bin` + `/usr/local/share`                        | 系统安装器管理，卸载需要手动删文件 |
| 手动解压二进制 | 你自己指定文件夹（如～/Downloads）                           | 完全手动维护，无自动更新           |

------

## 三、容易混淆的点：软链接看起来 “路径一样”

不管 brew 还是 pkg，最终 `git-lfs` 可执行文件都会出现在 `/usr/local/bin` 或 `/opt/homebrew/bin`，终端直接输入 `git lfs` 都能运行，**但这只是软链接，真实本体存放位置完全不同**。

### 验证命令（查看真实路径）

bash



运行





```
# 查看git-lfs真实存放位置
which git-lfs
# 追踪软链到源文件
ls -l $(which git-lfs)
```

+ brew 安装：输出会指向 Cellar 目录
+ pkg 安装：直接指向 `/usr/local/bin` 原生二进制

------

## 四、实用建议

1. 不要同时用两种方式安装同一个工具，会出现命令冲突、版本错乱；
2. 如果你已经用 `brew install git-lfs`，就不要再装官网 pkg；反之同理；
3. 卸载 brew 版：`brew uninstall git-lfs`，一键清理所有文件；
4. 卸载 pkg 版：需要手动删除 `/usr/local/bin/git-lfs` 和 share 目录，无一键清理。

通过brew下载的可以通过AppClear卸载吗

# 结论：不建议用 AppCleaner 卸载 brew 安装的程序，清理不干净，还容易出问题

## 一、核心原因

1. Homebrew 软件不在 /Applications 文件夹

   

   AppCleaner 的扫描逻辑主要针对：

+ `/Applications/` 下的 `.app` 图形化应用

+ ```
  ~/Library
  ```

   关联配置

  

  brew 安装的命令行工具（git-lfs、git、node 等）本体在 

  ```
  /opt/homebrew/Cellar
  ```

  （M 芯片）、

  ```
  /usr/local/Cellar
  ```

  ，

  AppCleaner 默认扫描不到 Cellar 目录

  ，只会漏掉绝大部分文件。

1. **brew 存在依赖联动关系**

   brew 会管理软件依赖：A 软件依赖 B 库，`brew uninstall` 会自动处理依赖冗余；

   AppCleaner 只是单纯删文件，无法识别依赖，删不干净还会残留大量无用库、缓存、软链接。

2. 残留文件会引发的问题

+ 终端执行命令报 `command not found`、版本冲突
+ `brew doctor` 检测出大量文件污染报错
+ 重新安装同工具时出现软链接冲突

## 二、两种正确卸载方式（brew 官方标准）

### 1. 普通卸载（保留缓存，可重装）

bash



运行





```
# 卸载git-lfs举例
brew uninstall git-lfs
```

### 2. 彻底卸载（连带缓存、配置全部清理）

bash



运行





```
brew uninstall --zap git-lfs
```

`--zap` 参数会同时删除该软件所有本地缓存、偏好、残留配置，等效干净卸载。

### 3. 清理全局无用依赖（卸载后执行）

bash



运行





```
brew autoremove
```

自动删掉不再被任何软件依赖的冗余库，释放磁盘空间。

## 三、如果你已经用 AppCleaner 删了 brew 工具怎么修复

执行 brew 自检，自动修复文件缺失、软链接异常：

bash



运行





```
brew doctor
```

根据终端提示执行修复命令，或重装对应软件：

bash



运行





```
brew reinstall git-lfs
```

## 补充区分：什么时候能用 AppCleaner

只有**从官网下载 .app 拖拽到 Applications 的图形软件**（如 VSCode、Postman、Figma）适合用 AppCleaner；

**brew、pkg、终端命令行工具一律不要用 AppCleaner 管理**。