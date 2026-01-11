# Git 命令



> 1. clone(克隆) : 从远程仓库中克隆代码到本地仓库
> 2. checkou(检出) : 从本地仓库中检出一个仓库分支然后修订
> 3. add(添加) : 在提交前先将代码提交到暂存区
> 4. commit(提交) : 提交到本地仓库, 本地仓库中保存修改的各个历史版本
> 5. fetch(抓取) : 从远程库, 抓取到本地仓库,不进行任何的合并动作,一般操作比较少
> 6. pull(拉取) : 从远程库拉到本地库,自动进行合并(merge), 然后放到工作区,相当于fetch + merge
> 7. push(推送) : 修改完成之后,需要和团队成员共享代码时,将代码推送到远程仓库

基本的linux指令

+ ls/ll 	查看当前目录
+ cat     查看文件内容
+ touch   创建文件
+ vi    vi编辑器(使用 vi 编辑器) 

1. Git GUI : Git提供的图形界面工具
2. Git Bash: Git提供的命令行工具

# Git最小配置

## 配置user.name 和 user.email

设置用户信息

```c++
1. git config —global [user.name](http://user.name) ‘yuor_name’ 
2. git config —global [user.email](http://user.email) ‘your_email@domain.com’  
```

## 查看配置信息

```C++
git config --list --作用域(global system local)
git config --giobal user.name 
git config --global user.email 
```

## confine的三个作用域

> local 只对某个仓库有效
>
> global对当前用户所有仓库有效
>
> system对系统所有登录的用户有效

```c++
1. git config —local
2. git config —global
3. git config —system
```

# 建立Git仓库

1. 把已有的项目代码纳入Git仓库

``` c++
cd项目代码所在的文件夹
git init 
```

2. 新建的项目直接用Git管理

``` c++
cd某个文件夹
git init   your_project  //会在当前的路径下创建和项目名称同名的文件夹
cd    your_project
```

### 删除创建的git文件

```c++
rm -rf .git
```

在global 和 local 两个作用范围中, local当前设置的属性优先级更高

```C++
export LANG="zh_CN.UTF-8" 
export LC_ALL="zh_CN.UTF_8"
```

# 基础操作指令

Git工作目录下对于文件的修改(增加, 删除, 更新)会存在几个状态, 这些修改的状态会随着我们执行的GIt的命令而发生变化

![3c765a20-8a0e-484b-a912-4b6b807a97a2 (1)](/Users/lose_sea/Downloads/3c765a20-8a0e-484b-a912-4b6b807a97a2 (1).jpeg)

```c++
git add (工作区 -> 暂存区) 
git commit (暂存区 -> 本地仓库)
```

### 查看修改的状态(status) 

> 1. 作用: 查看修改的状态 (暂存区, 工作区) 
> 2. 命令形式: `git status`

### 添加工作区到暂存区 (add)

> 作用: 添加工作区一个或多个文件的修改到暂存区
>
> 命令形式: `git add 单个文件名|通配符` 
>
> ​		`git add .`将所有修改加入到暂存区 

### 清除暂存区的内容

> `git rm --cached 文件名` 
>
> 例如: 
>
> `git rm --cached file01` 

### 提交暂存区到本地仓库 (commit) 

> 作用: 提交暂存区内容到本地仓库的当前分支
>
> 命令形式: `git commit -m"注释内容"`

### 查看提交日志 (log) 

> 作用: 查看提交记录 
>
> 命令形式: git log [option] 
>
>  + option 
>    + --all 显示所用分支
>    + --pretty=oneline 将提交信息显示为一行
>    + --abbrev-commit 使得输出的commitld更简短
>    + --graph 以图的形式显示
>    
>    

### 版本回退 

> 作用: 版本切换
>
> 命令形式: git reset -head commitID
>
> + commitID 可以使用`git -log 或 git log`指令查看
>
> 如何查看已经删除的记录
>
> + `git reflog`
> + 这个指令可以看到已经删除的提交记录

### 添加文件到忽视列表

一般我们总会有些文件无需纳入Git的管理,也不希望它们总出现在未跟踪文件列表,.通常都是些自动生成的文件,比如日志文件, 或者编译过程中创建的文件等,在这种情况下,我们可以在工作目录中创建一个名为`.gitignore`的文件 (**文件名称固定**), 列出要忽视的文件模式,

### 文件重命名

> `git mv 原文件名 新文件名` 
>
> 需要提交重命名, Git 会把 "重命名" 当做一次变更记录

### 删除文件

> `git rm 文件名`  
>
> `rm -rf` 是系统命令,它仅删除本地文件，不会被 Git 版本跟踪，易导致版本不一致

### 清除暂存区

> `git reset --hard` 
>
>  用于**彻底重置当前分支到指定提交版本**的命令，它会直接丢弃目标提交之后的所有提交记录和工作区修改，是一种「破坏性」的重置操作
