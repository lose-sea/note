# 把 MCP 接进 LangChain：一次接入，处处可用

> 你给 Agent 写了一个查天气的工具。
> 下一个项目又要写一遍，再下一个项目还写一遍。
>
> MCP（Model Context Protocol）要解决的就是这个：**工具描述标准化**，
> 写一次，任何支持 MCP 的客户端都能用。

## 一、MCP 解决什么问题

传统做法里，工具和框架是**绑死**的：

```
LangChain 工具   → 只能在 LangChain 用
OpenAI 的 tools  → 只能在 OpenAI 用
自研框架         → 只能在自己框架用
```

MCP 把它变成**三件套解耦**：

```
┌──────────┐         ┌──────────┐         ┌──────────┐
│  MCP     │  ←→    │  MCP     │  ←→    │  MCP     │
│  客户端   │         │  协议层   │         │  服务端   │
│(Claude/  │         │(JSON-RPC)│         │(工具/资源)│
│ Cherry/  │         └──────────┘         └──────────┘
│ LangChain)│
└──────────┘
```

**服务端只描述"我有哪些工具"，客户端负责"把工具交给模型"。** 换框架不用改服务端。

## 二、MCP 的三种能力

| 能力 | 说明 | 例子 |
|---|---|---|
| **Tools** | 可调用的函数 | 查天气、发邮件、跑 SQL |
| **Resources** | 可读取的数据 | 文件内容、数据库记录 |
| **Prompts** | 预置的提示词模板 | "代码审查"模板 |

LangChain 主要对接 **Tools**——这是最常用的。

## 三、两种连接方式

**方式一：stdio（本地进程）**

```python
from langchain_mcp_adapters.client import MultiServerMCPClient

client = MultiServerMCPClient({
    "filesystem": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/workspace"],
        "transport": "stdio",
    },
})
```

**方式二：HTTP / SSE（远程服务）**

```python
client = MultiServerMCPClient({
    "internal_tools": {
        "url": "https://mcp.internal.company.com/sse",
        "transport": "sse",
        "headers": {"Authorization": f"Bearer {TOKEN}"},
    },
})
```

生产环境推荐 HTTP 方式——**服务端可以独立部署、独立扩缩容、独立升级**。

## 四、拿到工具并接进 Agent

```python
import asyncio
from langchain_mcp_adapters.client import MultiServerMCPClient
from langgraph.prebuilt import create_react_agent

async def main():
    client = MultiServerMCPClient({
        "filesystem": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/workspace"],
            "transport": "stdio",
        },
        "search": {
            "url": "http://localhost:8000/sse",
            "transport": "sse",
        },
    })

    # 关键：工具列表是异步获取的
    tools = await client.get_tools()
    print([t.name for t in tools])

    agent = create_react_agent(llm, tools)
    result = await agent.ainvoke({"messages": [("user", "列出 workspace 里的文件")]})
    print(result["messages"][-1].content)

asyncio.run(main())
```

**`tools` 拿到的是标准的 LangChain `BaseTool` 对象**——可以和本地工具混用：

```python
from langchain_core.tools import tool

@tool
def my_local_tool(x: str) -> str:
    """本地的工具。"""
    return x.upper()

all_tools = await client.get_tools() + [my_local_tool]
agent = create_react_agent(llm, all_tools)
```

这一点很重要：**MCP 工具不是"另一套体系"，而是无缝融入现有链。**

## 五、工具按需加载：别一次全拉

MCP 服务端可能暴露几十个工具。全拉进来会导致：

1. 上下文被工具 schema 占满；
2. 模型选错工具的概率上升。

**按用途分组，只加载需要的**：

```python
async def get_tools_for(task: str) -> list:
    """根据任务类型加载相关工具"""
    SERVERS = {
        "file_ops": ["filesystem"],
        "data_query": ["database", "filesystem"],
        "web_research": ["search", "fetch"],
    }
    needed = SERVERS.get(task, list(ALL_SERVERS))
    client = MultiServerMCPClient({k: ALL_SERVERS[k] for k in needed})
    return await client.get_tools()
```

更细粒度的话，可以在拿到工具后**按名字过滤**：

```python
tools = await client.get_tools()
relevant = [t for t in tools if any(kw in t.name for kw in ["read", "list", "search"])]
```

## 六、工具名前缀：避免冲突

多个 MCP 服务端可能有同名工具（都是 `search`）。**加前缀区分**：

```python
def prefix_tools(tools, prefix: str):
    for t in tools:
        t.name = f"{prefix}__{t.name}"
    return tools

fs_tools = prefix_tools(await client.get_tools(server_name="filesystem"), "fs")
search_tools = prefix_tools(await client.get_tools(server_name="search"), "web")
```

模型看到 `fs__read_file` 和 `web__search`，能更准确地区分用途。

**注意**：部分模型对工具名有格式要求（只允许 `[a-zA-Z0-9_-]`），用双下划线而不要用点号或斜杠。

## 七、把 MCP 工具包装成更友好的形态

MCP 返回的工具描述往往是机器生成的，对模型不够友好。**可以二次包装**：

```python
from langchain_core.tools import StructuredTool

async def wrap_mcp_tool(mcp_tool, description: str):
    async def _run(**kwargs):
        return await mcp_tool.ainvoke(kwargs)

    return StructuredTool.from_function(
        coroutine=_run,
        name=mcp_tool.name,
        description=description,        # 用自己的描述
        args_schema=mcp_tool.args_schema,
    )
```

**描述质量直接决定工具调用准确率**——值得花时间重写。

## 八、Resources：把数据也接进来

MCP 的 Resources 可以当"数据源"用：

```python
async def load_mcp_resources(client, server: str, uri: str) -> str:
    session = await client.get_session(server)
    result = await session.read_resource(uri)
    return result.contents[0].text
```

典型用途：把 MCP 服务端暴露的配置、知识库文档拉进来做 RAG 的语料。

## 九、生命周期管理

MCP 连接是**有状态**的。stdio 方式启动的是子进程，**必须正确关闭**：

```python
class MCPManager:
    def __init__(self):
        self.client = None
        self.tools = None

    async def start(self):
        self.client = MultiServerMCPClient(SERVERS)
        self.tools = await self.client.get_tools()

    async def close(self):
        if self.client:
            await self.client.close()       # 关掉所有子进程/连接
            self.client = None
```

在 FastAPI 里用 lifespan 管理：

```python
from contextlib import asynccontextmanager

@asynccontextmanager
async def lifespan(app):
    mgr = MCPManager()
    await mgr.start()
    app.state.mcp = mgr
    yield
    await mgr.close()                        # 进程退出时清理

app = FastAPI(lifespan=lifespan)
```

**不关的话，stdio 模式会留下僵尸进程**——跑一天几百个。

## 十、几个实践要点

**① 工具列表要缓存，不要每次请求都拉。**

```python
class CachedMCP:
    def __init__(self, ttl=300):
        self._tools = None
        self._expire_at = 0
        self.ttl = ttl

    async def get_tools(self):
        if self._tools is None or time.time() > self._expire_at:
            self._tools = await self.client.get_tools()
            self._expire_at = time.time() + self.ttl
        return self._tools
```

每次请求都拉工具列表，会额外增加 1~2 秒延迟。

**② 给 MCP 调用加超时。**

```python
async def call_with_timeout(tool, args, timeout=30):
    try:
        return await asyncio.wait_for(tool.ainvoke(args), timeout=timeout)
    except asyncio.TimeoutError:
        raise ToolException(f"工具 {tool.name} 执行超时")
```

**③ 错误处理要统一。**
MCP 服务端挂了，整个 Agent 不应该崩。用 `ToolException` 把错误变成可读消息。

**④ 权限在服务端做。**
MCP 服务端应该验证调用方的身份，**不要靠客户端"只加载有权限的工具"**。

```python
client = MultiServerMCPClient({
    "internal": {
        "url": "...",
        "headers": {"Authorization": f"Bearer {user_token}"},   # 带上用户身份
    },
})
```

**⑤ MCP 服务端也要防注入。**
如果 MCP 工具返回的内容里含恶意指令，同样要按"不可信输入"处理。**MCP 只是传输协议，不提供安全保证。**

**⑥ 版本兼容。**
MCP 协议还在演进，`langchain-mcp-adapters` 的 API 也变过。**固定版本号**，别用 `latest`。

```toml
[project.optional-dependencies]
mcp = ["langchain-mcp-adapters==0.1.6", "mcp==1.2.0"]
```

## 十一、什么时候值得用 MCP

**值得用**：

- 工具要在**多个框架/客户端**之间复用（Claude Desktop + LangChain + 自研）；
- 工具由**其他团队维护**，你只想调用；
- 需要**标准化的权限和审计**。

**不值得用**：

- 只有一个项目用，且工具很简单 → 直接写 `@tool` 更快；
- 对延迟极度敏感 → MCP 多一层进程间通信；
- 工具需要访问框架内部状态 → MCP 是隔离的，拿不到。

**一句话判断：当"工具"开始具备"服务"的属性（多消费者、独立部署、需要鉴权）时，就该考虑 MCP。**

## 十二、小结

```python
# 1. 建客户端
client = MultiServerMCPClient({"fs": {...}, "search": {...}})

# 2. 拉工具（异步）
tools = await client.get_tools()

# 3. 接进 Agent（和本地工具混用）
agent = create_react_agent(llm, tools + [my_local_tool])

# 4. 用完关闭
await client.close()
```

四个要点：

```
1. 工具列表缓存，别每次拉
2. 工具名加前缀，避免冲突
3. 用途分组，别全量加载
4. 连接要正确关闭，别留僵尸进程
```

**MCP 的价值不在"少写代码"，而在"工具可以跨框架复用"**。当你开始维护第二、第三个 AI 应用时，它的价值会突然变得很明显。
