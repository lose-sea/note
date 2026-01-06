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
$cd项目代码所在的文件夹
$git init
```

2. 新建的项目直接用Git管理

``` c++
$cd某个文件夹
$git init your_project  //会在当前的路径下创建和项目名称同名的文件夹
$cd your_project
```













## 为常用指令配置别名

有些常用的指令参数非常多,每次都要输入好多参数,我们可以使用别名

1. 打开用户目录, 创建`.bashrc`文件

部分windws系统不允许用户创建点好开头的文件, 可以打开gitBash执行`touch ~/.bashrc` 

2. 在`.bashrc`文件中输入如下内容

```c++
#用于输出git提交日志
alias git-log='git log --pretty=oneline --all --graph --abbrev-commit'
#用于输出当前目录所有文件及基本信息
alist ll='ls -al'
```

3. 打开gitBash, 执行`source ~/.bashrc` 

## 解决GitBash乱码问题

1. 打开GitBash执行下面命令

```C++
git config --global core.quotepath false
```

2. $(git_home)/stc/bash.bashrc (git_home 是指git的安装目录) 文件最后加入下面两行



