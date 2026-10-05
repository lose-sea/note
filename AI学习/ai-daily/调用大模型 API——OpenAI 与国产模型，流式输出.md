<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 调用大模型 API——OpenAI 与国产模型，流式输出

**承上**：上一篇我们写出了结构化的 Prompt，也解决了 JSON 输出的稳定性问题。但它们还只是字符串。

**本篇**：把它们真正**跑起来**。你会学到 OpenAI 的消息格式、为什么国产模型和本地模型都能用同一套代码调用、如何实现流式输出（打字机效果），以及怎么封装一个**带重试、超时、计费统计**的健壮客户端。

**启下**：能对话之后，你很快会想要"让它帮我查天气、算数据、查数据库"。下一篇《Function Calling——让大模型调用你的函数》把大模型和你自己的代码连起来，写出一个真正能干活的助手。

**学完这一节，你能动手做**：

1. 用**一套代码**同时对接 OpenAI、DeepSeek、通义、智谱与本地模型（只改两行配置）
2. 实现流式输出，做出打字机效果
3. 封装带指数退避重试、超时、token 与成本统计的客户端，可直接用于生产

---

## 一、核心数据格式：messages

所有聊天模型的输入都是**一个消息列表**，每条消息带一个 role：

```python
messages = [
    {"role": "system",    "content": "你是一位资深 Python 工程师。"},   # 人设/全局指令
    {"role": "user",      "content": "用 Python 写一个快排。"},         # 用户说的
    {"role": "assistant", "content": "def quicksort(..."},              # 模型之前说的（多轮对话要带上）
    {"role": "user",      "content": "改成非递归版本。"},                # 用户又说
]
```

三个角色的分工：

| role | 作用 | 注意 |
|---|---|---|
| `system` | 设定人设、全局规则、输出格式 | 一般只放 1 条，放开头 |
| `user` | 用户的输入 | 多轮对话里可以有多条 |
| `assistant` | 模型的回复 | **多轮对话必须把历史回复拼进去**，模型本身没有记忆 |

> ⚠️ **模型没有记忆**。每次调用都是独立的，你必须自己维护对话历史并每次完整发送。这也是为什么"多轮对话越长越贵"——下一段会讲怎么管理。

### 返回结构

```python
{
  "choices": [{
      "message": {"role": "assistant", "content": "……"},
      "finish_reason": "stop"          # stop=正常结束 / length=被 max_tokens 截断 / tool_calls=要调工具
  }],
  "usage": {
      "prompt_tokens": 42,             # 输入消耗
      "completion_tokens": 137,        # 输出消耗
      "total_tokens": 179              # 计费依据
  }
}
```

`usage` 是你做成本控制的唯一依据，**一定要把它记录下来**。

## 二、为什么国产模型能直接用 OpenAI SDK？

因为 OpenAI 的 `/v1/chat/completions` 协议成了事实标准。国内厂商和本地推理框架（vLLM、Ollama、LM Studio）几乎都提供**兼容模式**——你只改 `api_key` 和 `base_url` 两个参数，代码一行不用动。

```python
from openai import OpenAI

providers = {
    "openai":      ("https://api.openai.com/v1",                              "gpt-4o-mini"),
    "deepseek":    ("https://api.deepseek.com",                                "deepseek-chat"),
    "qwen(通义)":  ("https://dashscope.aliyuncs.com/compatible-mode/v1",       "qwen-plus"),
    "glm(智谱)":   ("https://open.bigmodel.cn/api/paas/v4",                    "glm-4-flash"),
    "siliconflow": ("https://api.siliconflow.cn/v1",                           "Qwen/Qwen2.5-7B-Instruct"),
    "本地 vLLM":   ("http://localhost:8000/v1",                                "Qwen2.5-7B-Instruct"),
    "本地 Ollama": ("http://localhost:11434/v1",                               "qwen2.5:7b"),
}

# 换服务商 = 改这两行
client = OpenAI(api_key="sk-xxx", base_url="https://api.deepseek.com")
resp = client.chat.completions.create(
    model="deepseek-chat",
    messages=[{"role": "user", "content": "用一句话解释什么是注意力机制"}],
)
print(resp.choices[0].message.content)
print("消耗 token:", resp.usage.total_tokens)
```

> 各家 base_url 与模型名以**官方文档为准**（会随版本更新）。国内厂商在控制台都能找到"OpenAI 兼容"入口。

**这个设计的价值**：你的业务代码和模型供应商**解耦**。哪天要换模型、或者从云端切到本地私有化部署，只改配置。

## 三、代码实战 1：流式输出（打字机效果）

非流式调用要等模型把整段话生成完才返回，可能要等十几秒。流式则是**生成一个字就返回一个字**，体验完全不同。

```python
import sys, time
from openai import OpenAI

client = OpenAI(api_key="sk-xxx", base_url="https://api.deepseek.com")

def stream_chat(messages, model="deepseek-chat"):
    """流式输出，边生成边打印。"""
    resp = client.chat.completions.create(
        model=model,
        messages=messages,
        stream=True,                    # ← 关键开关
        temperature=0.7,
    )
    collected = []
    for chunk in resp:
        delta = chunk.choices[0].delta
        if delta.content:               # 注意：chunk 里 content 可能是 None
            print(delta.content, end="", flush=True)
            collected.append(delta.content)
    print()                             # 换行
    return "".join(collected)

text = stream_chat([
    {"role": "system", "content": "你是一位耐心的编程老师，回答简洁。"},
    {"role": "user",   "content": "用三句话解释什么是 Transformer"},
])
print(f"\n[共生成 {len(text)} 个字符]")
```

**三个细节**：

1. `stream=True` 打开流式；
2. 每个 chunk 的 `delta.content` 可能是 `None`（最后一个 chunk 通常是空的），要做判空；
3. `flush=True` 才能真正实现"一个字一个字跳出来"，否则会被缓冲区攒着一起打印。

> 在 Web 应用里，流式通常配合 **SSE（Server-Sent Events）** 或 WebSocket 推给前端。FastAPI 里返回 `StreamingResponse` 即可（阶段 10 部署篇会实战）。

## 四、代码实战 2：生产级客户端（重试 + 超时 + 计费）

真实环境必须处理：网络抖动、限流（429）、服务端错误（5xx）、超时。下面是一个可直接用的封装：

```python
import time
import threading
from dataclasses import dataclass, field
from openai import OpenAI, APIError, RateLimitError, APIConnectionError

@dataclass
class UsageStats:
    """线程安全的用量统计。"""
    prompt_tokens: int = 0
    completion_tokens: int = 0
    calls: int = 0
    errors: int = 0
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def add(self, usage):
        with self._lock:
            self.calls += 1
            if usage:
                self.prompt_tokens += usage.prompt_tokens
                self.completion_tokens += usage.completion_tokens

    def cost(self, price_in: float, price_out: float) -> float:
        """按 元/百万token 的单价计算成本。"""
        return (self.prompt_tokens / 1e6 * price_in
                + self.completion_tokens / 1e6 * price_out)

    def __str__(self):
        return (f"调用 {self.calls} 次 / 失败 {self.errors} 次 | "
                f"输入 {self.prompt_tokens} + 输出 {self.completion_tokens} token")


class LLMClient:
    """带重试、超时与统计的大模型客户端。"""

    RETRYABLE = (RateLimitError, APIConnectionError, APIError)

    def __init__(self, api_key: str, base_url: str, model: str,
                 timeout: float = 30.0, max_retries: int = 3):
        self.model = model
        self.stats = UsageStats()
        self.max_retries = max_retries
        self.client = OpenAI(api_key=api_key, base_url=base_url, timeout=timeout)

    def chat(self, messages, temperature=0.7, max_tokens=None, **kwargs):
        last_err = None
        for attempt in range(self.max_retries):
            try:
                resp = self.client.chat.completions.create(
                    model=self.model,
                    messages=messages,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    **kwargs,
                )
                self.stats.add(resp.usage)
                return resp.choices[0].message.content
            except self.RETRYABLE as e:
                last_err = e
                self.stats.errors += 1
                wait = 2 ** attempt          # 指数退避：1s, 2s, 4s...
                print(f"[重试 {attempt+1}/{self.max_retries}] {type(e).__name__}，{wait}s 后重试")
                time.sleep(wait)
        raise RuntimeError(f"调用失败（已重试 {self.max_retries} 次）: {last_err}")

    def chat_json(self, messages, **kwargs):
        """强制 JSON 输出（需要模型支持该参数）。"""
        return self.chat(messages, response_format={"type": "json_object"}, **kwargs)


# ---------- 使用 ----------
llm = LLMClient(api_key="sk-xxx",
                base_url="https://api.deepseek.com",
                model="deepseek-chat")

ans = llm.chat([{"role": "user", "content": "Python 里 *args 和 **kwargs 有什么区别？"}],
               temperature=0.2)
print(ans)
print("\n用量:", llm.stats)
print("预估成本: ¥", round(llm.stats.cost(price_in=2.0, price_out=8.0), 6))
```

**这段代码里的三个工程要点**：

1. **指数退避重试**：第 n 次失败等 `2^n` 秒。直接密集重试会加重限流。生产环境建议再加上**随机抖动**（jitter）。
2. **只重试"可重试"的错误**：限流（429）、连接错误、服务端 5xx 值得重试；**参数错误（400）、鉴权失败（401）重试一万次也没用**，应该立刻抛错。
3. **超时必须设**：默认超时往往过长。用户等 60 秒没反应就走了，不如早点失败走降级。

## 五、关键参数速查

| 参数 | 作用 | 建议值 |
|---|---|---|
| `temperature` | 采样温度，越高越发散 | 分类/抽取 0~0.3；对话 0.7；创意 0.9~1.0 |
| `top_p` | 核采样，从累积概率 p 的候选里选 | 0.8~0.95，通常**与 temperature 二选一**调 |
| `max_tokens` | 最大输出长度 | 必设，防止失控（注意它也算钱） |
| `stop` | 遇到指定字符串停止 | 多轮/结构化输出时很有用 |
| `n` | 一次生成几个候选 | 做"自洽投票"时设为 3~5 |
| `seed` | 固定随机种子 | 需要可复现时设置（不保证完全一致） |
| `response_format` | 强制 JSON 输出 | 结构化提取必开 |
| `presence/frequency_penalty` | 抑制重复 | 生成长文本时 0.1~0.5 |

**`finish_reason` 一定要看**：

```python
if resp.choices[0].finish_reason == "length":
    print("⚠️ 输出被 max_tokens 截断了，内容不完整！")
```

这是最容易被忽略的坑——**被截断的 JSON 是解析不出来的**，必须检测并重试。

## 六、常见坑

| 坑 | 现象 | 解法 |
|---|---|---|
| 把 API Key 写进代码 | 泄露、被刷爆 | 用环境变量 `os.environ["OPENAI_API_KEY"]` |
| 不做多轮历史拼接 | 模型"失忆" | 每次请求带上完整 messages |
| 不设 timeout | 请求挂死 | 显式传 `timeout=30` |
| 忽略 `finish_reason` | 拿到半截 JSON | 检测 `length` 并加大 max_tokens |
| 盲目重试所有错误 | 401 也重试 | 只对限流/网络/5xx 重试 |
| 在循环里重复建 client | 连接无法复用 | client 做成单例 |
| 并发直接开 100 线程 | 触发限流 | 用信号量限流（如 `asyncio.Semaphore(8)`） |
| 忘记记 usage | 账单失控 | 每次记录并做日报 |

## 七、本篇小结

1. **输入是 messages 列表**，模型**没有记忆**——多轮对话必须自己拼接历史。
2. OpenAI 协议是事实标准，**换模型只改 `api_key` + `base_url`**，业务代码零改动（云端 ↔ 本地同理）。
3. **流式输出**用 `stream=True`，注意 `delta.content` 判空与 `flush=True`。
4. 生产客户端必备三件套：**指数退避重试、超时、usage 统计**；只对可恢复错误重试。
5. `finish_reason == "length"` 意味着**输出被截断**，必须检测——这是"JSON 解析失败"最常见的原因。

**下一篇**：现在模型能说会道了，但它**只能说，不能做**——不知道今天的天气、查不了你的数据库、算不了实时汇率。下一篇《Function Calling——让大模型调用你的函数》打通这条链路：定义工具的 JSON Schema，让模型自己决定调哪个、传什么参数，然后写一个完整的"模型 → 工具 → 回填 → 再回答"循环，跑通一个真正能干活的助手。

> 本篇是《大模型开发从 0 到 1》专栏第 35 篇，阶段 6「提示词工程与大模型 API」第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
