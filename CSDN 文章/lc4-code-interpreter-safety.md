# 代码解释器的安全边界：别让模型在你服务器上 rm -rf

> Agent 有了执行代码的能力，能做的事一下子多了很多：
> 数据分析、画图、算数、跑测试。
>
> 但它也可能执行 `os.system("rm -rf /")` 或者
> `open("/etc/passwd").read()` 然后发到外网。

## 一、先想清楚：你到底需要多强的执行能力

不同的需求，隔离等级差别巨大：

| 场景 | 需要的权限 | 隔离等级 |
|---|---|---|
| 算数学题 | 无 IO、无网络 | 极低（用 AST 求值即可） |
| 画图表 | 文件读写（沙箱内） | 低（容器 + 临时目录） |
| 数据分析 | 读用户上传的文件 | 中（容器 + 资源限制） |
| 跑单元测试 | 完整 Python 环境 | 中高（容器 + 无网络） |
| 装依赖、访问网络 | 完整系统权限 | 高（独立 VM） |

**最常见的错误是"用最高等级的方案解决最低等级的需求"**——为了算个数起了个 Docker 容器。

## 二、最简单的场景：根本不用执行代码

如果只是"算一下 234 * 567 + 89"，用 AST 安全求值：

```python
import ast
import operator

OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.Pow: operator.pow,
    ast.USub: operator.neg,
    ast.Mod: operator.mod,
}

def safe_eval(expr: str) -> float:
    """只允许算术表达式，不允许任何函数调用或属性访问"""
    def _eval(node):
        if isinstance(node, ast.Constant):
            if not isinstance(node.value, (int, float)):
                raise ValueError("只支持数字")
            return node.value
        if isinstance(node, ast.BinOp):
            op = OPS.get(type(node.op))
            if op is None:
                raise ValueError(f"不支持的操作符：{type(node.op).__name__}")
            return op(_eval(node.left), _eval(node.right))
        if isinstance(node, ast.UnaryOp):
            op = OPS.get(type(node.op))
            if op is None:
                raise ValueError("不支持的一元操作")
            return op(_eval(node.operand))
        raise ValueError(f"不支持的语法：{type(node).__name__}")

    tree = ast.parse(expr.strip(), mode="eval")
    return _eval(tree.body)
```

它的安全性来自**白名单**——只有列出的节点类型才允许。`__import__`、`open`、`eval` 这些根本走不到。

**注意：绝对不要用 `eval()`。** 即使加了"过滤危险字符"，也总有人能绕过：

```python
# ❌ 这些都能绕过简单的黑名单
eval("().__class__.__bases__[0].__subclasses__()")
eval("getattr(__builtins__, '__import__')('os')")
```

## 三、需要 pandas 分析：子进程 + 白名单导入

数据分析和纯算术之间，有个中间形态：**允许用一批库，但禁止危险操作**。

做法是**在子进程里执行，并在代码里插入守卫**：

```python
import subprocess
import tempfile
import textwrap

FORBIDDEN_PATTERNS = [
    r"\bimport\s+os\b", r"\bimport\s+sys\b", r"\bimport\s+subprocess\b",
    r"\bimport\s+socket\b", r"\bimport\s+shutil\b", r"\bimport\s+ctypes\b",
    r"\b__import__\b", r"\beval\s*\(", r"\bexec\s*\(",
    r"\bopen\s*\(", r"\bos\.", r"\bsys\.", r"\bsubprocess\.",
    r"\bpickle\b", r"\bglobals\s*\(", r"\blocals\s*\(",
]

def screen(code: str) -> tuple[bool, str]:
    for pat in FORBIDDEN_PATTERNS:
        if re.search(pat, code):
            return False, f"代码包含被禁止的用法：{pat}"
    return True, ""
```

然后在一个受限环境里跑：

```python
def run_in_subprocess(code: str, timeout: int = 30, workdir: str | None = None):
    ok, err = screen(code)
    if not ok:
        return {"error": err}

    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "user_code.py"
        script.write_text(code, encoding="utf-8")

        try:
            proc = subprocess.run(
                ["python", "-I", "-S", str(script)],     # -I 隔离模式，-S 不加载 site
                cwd=workdir or tmp,
                capture_output=True,
                text=True,
                timeout=timeout,
                env={"PATH": "/usr/bin", "HOME": tmp},    # 极简环境变量
            )
            return {"stdout": proc.stdout[-5000:], "stderr": proc.stderr[-2000:]}
        except subprocess.TimeoutExpired:
            return {"error": f"执行超时（{timeout} 秒）"}
```

**`-I` 参数的含义**：isolated mode，忽略 `PYTHONPATH`、不加载用户 site-packages、不读 `PYTHON*` 环境变量。这是 Python 自带的轻量隔离。

**注意：正则黑名单是"降低风险"，不是"消除风险"。** 攻击者可以用字符串拼接绕过：

```python
# 绕过 "import os"
__import__("o" + "s")
```

所以**黑名单必须配白名单一起用**（见下一节）。

## 四、真正可靠的做法：容器隔离

黑名单不可靠，**可靠的是隔离**——让代码即使"想作恶"也作不了。

```python
import docker

client = docker.from_env()

def run_in_container(code: str, timeout: int = 30, memory: str = "512m"):
    script = f"""
import json, sys
try:
    {textwrap.indent(code, "    ")}
except Exception as e:
    print(json.dumps({{"error": str(e)}}))
"""

    try:
        container = client.containers.run(
            "python:3.11-slim",
            command=["python", "-c", script],
            remove=True,
            network_disabled=True,                    # ✅ 禁网
            mem_limit=memory,                         # ✅ 内存上限
            cpu_period=100000,
            cpu_quota=50000,                          # ✅ 0.5 核
            pids_limit=64,                            # ✅ 进程数上限
            read_only=True,                           # ✅ 根文件系统只读
            tmpfs={"/tmp": "size=64m"},               # ✅ 只有 /tmp 可写
            user="nobody",                            # ✅ 非 root
            security_opt=["no-new-privileges"],       # ✅ 禁止提权
            timeout=timeout,
        )
        return {"stdout": container.decode()[-5000:]}
    except docker.errors.ContainerError as e:
        return {"error": e.stderr.decode()[-2000:]}
```

**安全参数逐条解释**：

| 参数 | 作用 | 缺了会怎样 |
|---|---|---|
| `network_disabled` | 禁网 | 数据外泄、挖矿、拉恶意依赖 |
| `mem_limit` | 内存上限 | OOM 拖垮宿主机 |
| `cpu_quota` | CPU 上限 | 满核跑死循环 |
| `pids_limit` | 进程数上限 | fork 炸弹 |
| `read_only` | 根目录只读 | 篡改系统文件 |
| `user="nobody"` | 非 root | 提权后逃逸 |
| `no-new-privileges` | 禁提权 | setuid 提权 |
| `timeout` | 时间上限 | 无限挂起 |

**八个都要设。** 少一个就是留一个洞。

## 五、数据进出的方式

容器里怎么读用户的数据、怎么把结果带回来？

**输入**：挂载只读目录

```python
client.containers.run(
    ...,
    volumes={host_data_dir: {"bind": "/data", "mode": "ro"}},   # 只读挂载
)
```

**输出**：只允许写 `/tmp`，跑完从容器里拷出来

```python
# 代码里只往 /tmp 写
# container 跑完后：
bits, stat = container.get_archive("/tmp/output.png")
```

**绝对不要**挂载宿主机的敏感目录（`/etc`、`~/.ssh`、docker socket）。

⚠️ **特别警告：不要挂 `docker.sock`**。挂了 sock 等于把宿主机控制权交出去——容器里能启动新的特权容器。

## 六、白名单导入：限制可用库

黑名单容易绕过，**白名单更稳**：

```python
ALLOWED_MODULES = {
    "pandas", "numpy", "matplotlib", "math", "statistics",
    "datetime", "json", "re", "collections", "itertools",
}

def check_imports(code: str) -> tuple[bool, str]:
    tree = ast.parse(code)
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                root = alias.name.split(".")[0]
                if root not in ALLOWED_MODULES:
                    return False, f"不允许导入模块：{root}"
        elif isinstance(node, ast.ImportFrom):
            root = (node.module or "").split(".")[0]
            if root not in ALLOWED_MODULES:
                return False, f"不允许导入模块：{root}"
    return True, ""
```

**用 AST 而不是正则**——正则会被 `import` 的写法变化绕过（`__import__`、`importlib`）。

不过要注意：**AST 检查也不是万无一失的**。`pandas` 本身就能读写文件：

```python
# 通过 pandas 绕过 open() 限制
pd.read_csv("/etc/passwd")
```

所以**AST 检查是"第一道筛子"，容器隔离才是真正的墙**。两层都要有。

## 七、把工具接进 Agent

```python
from langchain_core.tools import tool, ToolException

@tool
def execute_python(code: str) -> str:
    """执行 Python 代码并返回结果。

    可用于数据分析、计算和画图。支持 pandas / numpy / matplotlib。
    不支持网络访问，不支持读写沙箱外的文件。
    要输出结果请使用 print()。
    """
    # 1. 静态检查
    ok, err = check_imports(code)
    if not ok:
        raise ToolException(f"{err}。可用的库：{sorted(ALLOWED_MODULES)}")

    # 2. 容器执行
    result = run_in_container(code, timeout=30)

    if "error" in result:
        # 把错误回灌给模型，让它自己改
        raise ToolException(f"执行失败：{result['error']}")

    return result["stdout"] or "（无输出）"
```

用 `ToolException` 让模型看到错误并自行修正（参考"工具报错怎么让模型自愈"那一篇）。

**docstring 要写清楚限制**——模型知道不能用网络，就不会写出 `requests.get()` 来撞墙。

## 八、几个必须注意的点

**① 不要在 Agent 主进程里 `exec`。**

```python
# ❌ 再"小心"也不行
exec(code, {"__builtins__": {}})
```

空 `__builtins__` 也不是安全的——`().__class__` 这条链依然能拿到一切。**永远用独立进程或容器。**

**② 限制执行次数和时间。**

```python
class RateLimiter:
    def __init__(self, max_per_minute=10, max_total_seconds=120):
        ...
```

一个 Agent 反复执行超时代码，会持续占资源。**总时长也要设上限**，不只是单次。

**③ 日志要脱敏。**
执行代码的日志里可能含用户数据。**日志记录代码哈希和输出摘要，不要记录完整内容。**

**④ 代码缓存要绑定用户。**
如果做了"相同代码复用执行结果"的缓存，key 必须带 `user_id`——否则 A 能看到 B 的执行结果。

**⑤ 别忘了资源回收。**
容器跑完要 `remove=True`；超时的容器要主动 kill，不然会累积。

```python
def cleanup_stale_containers(prefix="agent-exec-", max_age=300):
    for c in client.containers.list(all=True, filters={"name": prefix}):
        if time.time() - parse_time(c.attrs["Created"]) > max_age:
            c.kill()
            c.remove(force=True)
```

## 九、小结

按需求选隔离等级：

```
只算数          → AST 白名单求值（几行代码）
用 pandas 分析  → 子进程 + 导入白名单 + 资源限制
跑测试 / 装包   → 容器隔离（禁网、限内存、只读根）
要联网          → 独立 VM + 网络策略
```

**核心原则：把代码当作"不可信输入"来对待。**

三条铁律：

1. **永不 `eval` / `exec` 在主进程**；
2. **容器隔离必须全参数配齐**（八个参数缺一不可）；
3. **AST 检查 + 容器隔离两层都要**，别指望单层。

代码解释器是 Agent 能力的一次巨大跃升，**也是最需要小心的一步**——给它执行能力的同时，也给了它破坏能力。
