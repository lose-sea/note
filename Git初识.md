# git的最小配置

## 配置user.name 和 user.email

1. git config —global [user.name](http://user.name) ‘yuor_name’ 
2. git config —global [user.email](http://user.email) ‘your_email@domain.com’
   1. 

## confine的三个作用域

1. git config —local
2. git config —global
3. git config —system
   1. 

# 建立Git仓库

1. 把已有的项目代码纳入Git仓库
   1. 

```C++
$cd项目代码所在的文件夹
$git init
```

1. 新建的项目直接用Git管理
   1. 

```C++
$cd某个文件夹
$git init your_project  //会在当前的路径下创建和项目名称同名的文件夹
$cd your_project
```

# Git 命令

> 1. clone(克隆) : 从远程仓库中克隆代码到本地仓库
> 2. checkou(检出) : 从本地仓库中检出一个仓库分支然后修订
> 3. add(添加) : 在提交前先将代码提交到暂存区
> 4. commit(提交) : 提交到本地仓库, 本地仓库中保存修改的各个历史版本
> 5. fetch(抓取) : 从远程库, 抓取到本地仓库,不进行任何的合并动作,一般操作比较少
> 6. pull(拉取) : 从远程库拉到本地库,自动进行合并(merge), 然后放到工作区,相当于fetch + merge
> 7. push(推送) : 修改完成之后,需要和团队成员共享代码时,将代码推送到远程仓库

