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
+ mkdir  创建文件夹

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

### 不存放到暂存区直接提交

> `git commit -am '注释内容'` 
>
> **注意: 只是针对已经被git跟踪的文件可以直接提交, 如果是创建一个新的文件,没有被git跟踪, 则不可以直接提交**

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
>    + `--n数字` 显示最近几次的提交记录
>
> 

### 版本回退 

> 作用: 版本切换
>
> 命令形式: git reset -head commitID
>
> + commitID 可以使用` git log`指令查看
>
> 如何查看已经删除的记录
>
> + `git reflog`
> + 这个指令可以看到已经删除的提交记录

### 添加文件到忽视列表

一般我们总会有些文件无需纳入Git的管理,也不希望它们总出现在未跟踪文件列表,.通常都是些自动生成的文件,比如日志文件, 或者编译过程中创建的文件等,在这种情况下,我们可以在工作目录中创建一个名为`.gitignore`的文件 (**文件名称固定**), 列出要忽视的文件模式,

### 文件重命名 



> `mv 原文件名 新文件名` 只是改变名字,未保存到暂存区
>
> `git mv 原文件名 新文件名`  重命名, 同时保存到暂存区
>
> 需要提交重命名, Git 会把 "重命名" 当做一次变更记录

### 删除文件

> `git rm 文件名`  
>
> `rm 文件名` 是系统命令,它仅删除本地文件，不会被 Git 版本跟踪，易导致版本不一致 **rm  文件名**只可以删除文件,不可以删除文件夹
>
> 1. `git rm` 可以删除文件夹，但必须加 `-r` 参数，且核心是操作 Git 仓库，而非单纯删除本地文件。
> 2. 仅删除本地文件夹（和 Git 无关）→ 用 `rm -r 文件夹名`；
> 3. 从 Git 仓库移除并删除本地文件夹 → 用 `git rm -r 文件夹名` + `git commit`；
> 4. 仅从 Git 仓库移除但保留本地文件夹 → 用 `git rm -r --cached 文件夹名` + `git commit`。

### 清除暂存区

> `git reset --hard` 
>
> 用于**彻底重置当前分支到指定提交版本**的命令，它会直接丢弃目标提交之后的所有提交记录和工作区修改，是一种「破坏性」的重置操作
>
> **注意: 之后删除git跟踪的文件**

### 打开图形化界面

> gitk 打开图形化界面

### 查看类型

> `git cat-file -t id号`  

### 查看内容

> `git cat-file -p id号` 可以查看文件夹也可以查看文件
>
> `cat	文件名`   只可以查看文件

### 比较两个提交有什么差异

> `git diff 第一个提交的哈希值 第二个提交的哈希值`

### 修改当前分支最近一次提交的massage

> `git commit --amend`

### 修改老旧commit的massage 

> 命令: `git rebase -i 要修改的commit的前一次提交的哈希值`  
>
> `r修改massage

### 把连续的多个commit整理成一个

> `git rebase -i 要合并的几个提交的前一个提交的哈希值` 
>
> `s`    合并commit 

### 把间隔的几个commit整理成一个

> `git rebase -i 要合并的最早的一次commit的前一个commit的哈希值` 
>
> **注意: 要合并的commit需要调整到一起**

### 比较暂存区和HEAD所含文件的差异

> `git diff --cached`

### 比较工作区和暂存区的差异

> `git diff` 比较工作区和暂存区的差异
>
> `git diff --具体文件名` 查看具体文件工作区和暂存区的差异

### 让暂存区恢复成和HEAD的一样 (取消暂存)

> git reset HEAD` 

### 让工作区的文件恢复为和暂存区一样

> `git checkout -- 文件名`

### 取消暂存区部分文件的更改

> `git reset HEAD --文件名` 

### 消除最近的几次commit

> `git reset --hard 想要删除的commit的前一个commit的哈希值` 

### 查看不同提交的指定文件的差异

> `git diff 分支名1 分支名2` 查看两个分支的差异
>
> `git diff 分支名1 分支名2` 文件名  两个分支某个文件的差异

### 删除文件

> `git rm 文件名` 

### 将暂存区的内容暂时存放到一个临时空间

> `git stash`    将暂存区的内容暂时存放到一个临时空间 , 可以进行其他紧急任务
>
> `git stash list`查看临时空间中的内容
>
> `git stash apply` 将临时空间中的内容弹出到暂存区 ,不会清空临时空间
>
> `git stash pop` 将临时空间中的内容弹出到暂存区, 同时清空临时空间
