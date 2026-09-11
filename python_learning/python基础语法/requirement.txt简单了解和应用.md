[toc]

# requirements.txt

`requirements.txt` 是一个**纯文本文件**，用来记录一个 Python 项目所依赖的第三方包及其版本。它的作用是让其他人（或另一台机器）能够**一键复现**项目所需的运行环境。

```bash
pip install -r requirements.txt
```

一行命令，就能把所有依赖装好。

## requiremtnes 长什么样?

最简单的形式，每行一个包名：

```
requests
flask
numpy
```

带版本约束：

```
requests==2.31.0
flask>=3.0.0
numpy~=1.26.0
```



还可以加注释和空行：

```
# Web 框架
flask==3.0.0

# 数据处理
pandas==2.2.0
numpy==1.26.4
```

### 版本约束符号

| 写法    | 含义             | 示例                                        |
| :------ | :--------------- | :------------------------------------------ |
| `==`    | 精确等于         | `flask==3.0.0`                              |
| `>=`    | 大于等于         | `numpy>=1.20`                               |
| `<=`    | 小于等于         | `numpy<=2.0`                                |
| `~=`    | 兼容版本（推荐） | `numpy~=1.26.0` 等价于 `>=1.26.0, ==1.26.*` |
| `!=`    | 排除某版本       | `flask!=3.0.1`                              |
| `>` `<` | 严格大于/小于    | `django>4.0`                                |
| 不写    | 装最新版         | `requests`                                  |

**`~=` 是最实用的**：它允许补丁版本更新（修 bug），但不允许次版本升级（避免破坏性变更）。比如 `~=1.26.0` 会装 `1.26.1`、`1.26.9`，但不会装 `1.27.0`。

组合约束用逗号：

```
django>=4.2,<5.0
```

## 生成 requirements.txt 

### 方法一: 手动写

直接写出你确定要用的包，推荐用 `==` 锁定版本

#### 方法二: 自动导出当前环境

```objc
pip freeze > requirements.txt
```

`pip freeze` 会列出当前虚拟环境中所有已经安装的包 (包括间接依赖), 输出成 `包名 == 格式`格式 

生成的内容可能很长：

例如: 

```
blinker==1.7.0
click==8.1.7
Flask==3.0.0
itsdangerous==2.1.2
Jinja2==3.1.3
MarkupSafe==2.1.5
Werkzeug==3.0.1
```

**注意：这会包含所有间接依赖，环境迁移最保险，但文件不"干净"。**

#### 方法四: 只导出直接依赖 

用 poetry / pipenv 管理

现代工具会分开管理 “直接依赖” 和 “锁定文件” 

```objc
# Poetry
poetry add requests
poetry export -f requirements.txt --output requirements.txt
```



## 实际工作流



```
# 1. 创建虚拟环境
python -m venv venv

# 2. 激活（Linux/Mac）
source venv/bin/activate
# Windows
venv\Scripts\activate

# 3. 安装依赖
pip install -r requirements.txt

# 4. 开发中装了新包
pip install requests

# 5. 更新 requirements.txt
pip freeze > requirements.txt
```