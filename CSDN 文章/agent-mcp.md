# MCP 是什么：给 AI 应用装一个「USB-C 接口」

如果你已经写过 Function Calling，一定遇到过这个麻烦：同样一个「读数据库」的工具，在 A 应用里要写一遍 JSON Schema，换个 B 应用还得再写一遍；模型换了，格式可能又不兼容。

**MCP（Model Context Protocol）就是为了解决这个「重复造轮子」而生的**。它被类比成「AI 应用的 USB-C 接口」——一个开放协议，让工具只实现一次，到处都能用。

这篇讲清楚：**它解决什么问题、架构长什么样、三种能力分别是什么、怎么快速写一个 MCP Server、以及它和 Function Calling 到底是什么关系**。

---

## 一、先看它解决的问题

没有 MCP 的时候，工具集成是这样的：

```
应用 A ──┬── 工具 1（为 A 写一遍）
         ├── 工具 2（为 A 写一遍）
         └── 工具 3（为 A 写一遍）

应用 B ──┬── 工具 1（为 B 再写一遍）   ← 同样的逻辑，重写
         ├── 工具 2（为 B 再写一遍）
         └── 工具 3（为 B 再写一遍）
```

M 个应用 × N 个工具 = **M × N 份集成代码**。

有了 MCP：

```
应用 A ──┐
应用 B ──┼── MCP 协议 ──┬── MCP Server 1（数据库）
应用 C ──┘              ├── MCP Server 2（文件系统）
                        └── MCP Server 3（Git）
```

工具实现一次（MCP Server），所有支持 MCP 的应用都能直接接上。成本从 M×N 降到 **M+N**。

---

## 二、架构：三个角色

MCP 是典型的客户端-服务器架构，只有三个角色：

| 角色 | 是什么 | 例子 |
|---|---|---|
| **Host** | 承载 AI 的主应用 | Claude Desktop、Cursor、你自己写的 Agent |
| **Client** | Host 内部的连接器，一个 Server 对应一个 Client | 由 Host 实现，你通常不用管 |
| **Server** | 提供能力的独立进程 | 数据库 Server、文件 Server、 Slack Server |

关键点：**Server 是独立进程**，通过标准输入输出（stdio）或 HTTP 与 Client 通信。所以它可以用任何语言写——Python、Node、Go 都行。

```
┌──────────────────────────────────────┐
│  Host（如 Claude Desktop）            │
│   ├─ Client ──stdio──► Server A      │
│   ├─ Client ──stdio──► Server B      │
│   └─ Client ──HTTP───► Server C      │
└──────────────────────────────────────┘
```

---

## 三、Server 能提供三种东西

这是很多人只知其一不知其二的地方——MCP 不只是「工具」。

### ① Tools（工具）

模型可以调用的函数，和 Function Calling 里的工具是一回事。这是最常用的一种。

### ② Resources（资源）

**能被读取的数据**，比如文件内容、数据库表、API 返回的文档。区别在于：Tools 是「做事情」，Resources 是「给数据」。

举例：一个文件系统 Server 可以把 `/docs/*.md` 暴露成 Resources，应用就能把这些文档塞进上下文，而不需要模型主动调用工具去读。

### ③ Prompts（提示词模板）

Server 可以预置一些提示词模板，用户通过 `/命令` 触发。比如一个 Git Server 提供 `generate-commit-message` 模板，用户在应用里选一下就能用。

---

## 四、写一个 MCP Server

用官方的 Python SDK，一个能用的 Server 不到 30 行：

```bash
pip install mcp
```

```python
# server.py
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("demo")

@mcp.tool()
def add(a: int, b: int) -> int:
    """计算两个整数的和。当需要做加法运算时使用。"""
    return a + b

@mcp.tool()
def get_user(user_id: int) -> dict:
    """根据用户 ID 查询用户信息，返回姓名和邮箱。"""
    # 真实场景这里查数据库
    return {"id": user_id, "name": "张三", "email": "zhang@example.com"}

@mcp.resource("config://app")
def app_config() -> str:
    """应用的配置信息"""
    return "env=production\nregion=cn-hangzhou"

if __name__ == "__main__":
    mcp.run()          # 默认走 stdio
```

几个要点：

- **`@mcp.tool()` 装饰器的 docstring 就是给模型看的描述**，和 Function Calling 里的 `description` 地位一样，写清楚「什么时候用」；
- **类型注解（`a: int`）会被自动转成 JSON Schema**，所以别偷懒写成 `def add(a, b)`；
- `mcp.run()` 默认用 stdio 通信，由 Host 启动这个进程。

### 在 Host 里配置

以常见的桌面端应用为例，配置文件里加一段：

```json
{
  "mcpServers": {
    "demo": {
      "command": "python",
      "args": ["D:/projects/mcp/server.py"]
    }
  }
}
```

重启应用后，它会自动启动这个进程，并把 `add`、`get_user` 两个工具挂给模型。

---

## 五、MCP 和 Function Calling 是什么关系

这是最常见的困惑。答案是：**不是替代关系，是不同层级**。

| | Function Calling | MCP |
|---|---|---|
| 解决的问题 | 模型怎么**输出**一个调用请求 | 工具怎么**被发现、被分发、被复用** |
| 层级 | 模型 API 层 | 应用集成层 |
| 谁来实现 | 模型厂商 | 工具提供方 |
| 输给模型的是什么 | 你手写的 JSON Schema | 从 MCP Server 拿到的工具列表（**最终也会转成 Schema 交给模型**） |

一句话：**MCP 负责把工具送到应用面前，Function Calling 负责让模型去调它。** 一个 MCP 应用内部，最终仍然是通过 Function Calling（或等价机制）让模型触发工具的。

所以如果你的场景只有一个应用、几个固定工具，直接用 Function Calling 就够了，上 MCP 反而增加复杂度。**MCP 的价值在「跨应用复用」和「工具生态」**。

---

## 六、现状与注意事项

**优点：**

- 工具一次实现、多处复用，社区已经有大量现成 Server（数据库、Git、浏览器、各种 SaaS）；
- 语言和框架无关，Server 是独立进程；
- 权限边界清晰——Server 只暴露你声明的能力。

**要注意的地方：**

- **Server 是本地进程，等于把本机的一部分能力交出去了**。只装你信任的 Server，注意它有没有文件读写、命令执行权限。
- **工具数量会失控**。接了五六个 Server 之后，工具可能有几十上百个，模型挑选准确率会下降。要在 Host 侧控制启用哪些 Server。
- **协议还在演进**。规范更新较快，SDK 版本要留意兼容性。
- **调试相对麻烦**。Server 通过 stdio 通信，出错时日志不明显；建议先用官方的 inspector 工具单独调试 Server，再接进应用。

---

## 七、小结

1. MCP 是**工具复用协议**，把 M×N 的集成成本降到 M+N，被称为 AI 应用的 USB-C。
2. 三个角色：**Host（主应用）/ Client（连接器）/ Server（能力提供方）**，Server 是独立进程。
3. Server 能提供三种能力：**Tools（做事）/ Resources（给数据）/ Prompts（模板）**，别只会用第一种。
4. Python SDK 写个 Server 只要几十行，**docstring 就是给模型的描述**，类型注解会转成 Schema。
5. **它和 Function Calling 不冲突**：MCP 管工具分发，Function Calling 管模型调用，实际是上下游。
6. 注意权限边界和工具数量——别什么都接，模型会被淹没。

到这里 Agent 的四件套（大脑 / 规划 / 工具 / 记忆）里，「工具」这条线就完整了：从 ReAct 的手工解析，到 Function Calling 的原生结构化，再到 MCP 的跨应用复用。下一篇开始讲框架——先看 LangChain 是怎么把这些封装起来的。
