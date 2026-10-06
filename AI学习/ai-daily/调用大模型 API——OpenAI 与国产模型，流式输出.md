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

### 1.0 从本地推理到云端 API：大模型开发的两种入口

在真正写代码前，先建立一张"大模型开发全景图"：要让模型干活，你基本只有两条路。其一是**本地推理**——把模型权重下载到自己的显卡上，用 vLLM / Ollama / llama.cpp 起一个服务，自己当运维；其二是**调用云端 API**——把模型托管在厂商机房，你只管发 HTTP 请求、按 token 付费。本篇聚焦第二种，因为它**门槛最低、迭代最快**：你不需要几万块的显卡，有个 API Key 就能让最强的大模型为你打工。

但两条路并不互斥，反而常常结合：开发期用云端 API 快速验证想法，上线期为合规或成本切到本地私有部署。而本篇要教你的"OpenAI 兼容协议"，恰好是连接这两条路的**通用接口**——同一套 `messages` 格式、同一个 `client.chat.completions.create` 调用，换个 `base_url` 就能在云端和本地之间无缝切换。理解了这点，你就握住了大模型应用"可移植性"的钥匙。

### 1.1 一切都是"消息列表"

所有聊天模型（chat model）的输入都是**一个消息列表**，每条消息带一个 `role` 和一个 `content`。这是现代大模型 API 的通用契约，几乎成了行业标准。理解它，是你写任何大模型代码的第一步。

```python
messages = [
    {"role": "system",    "content": "你是一位资深 Python 工程师。"},   # 人设/全局指令
    {"role": "user",      "content": "用 Python 写一个快排。"},         # 用户说的
    {"role": "assistant", "content": "def quicksort(..."},              # 模型之前说的（多轮对话要带上）
    {"role": "user",      "content": "改成非递归版本。"},                # 用户又说
]
```

为什么是"列表"而不是"一句问题"？因为聊天是**有上下文的**：模型要看到你前面说过什么、它自己回答过什么，才能接着聊。这个列表就是"对话剧本"，你每次调用都把截止到当前的所有有效内容完整传进去。

### 1.2 三个角色的分工与心智模型

| role | 作用 | 注意 |
|---|---|---|
| `system` | 设定人设、全局规则、输出格式 | 一般只放 1 条，放开头 |
| `user` | 用户的输入 | 多轮对话里可以有多条 |
| `assistant` | 模型的回复 | **多轮对话必须把历史回复拼进去**，模型本身没有记忆 |

用一个比喻：`system` 是"给演员的剧本设定"（你演一个怎样的人），`user` 是"对手戏演员的台词"，`assistant` 是"你上一轮的表演"。下一轮你要把这三样一起交给模型，它才知道戏接在哪。

### 1.3 一个反直觉但致命的事实：模型没有记忆

> ⚠️ **模型没有记忆**。每次调用都是独立的，你必须自己维护对话历史并每次完整发送。这也是为什么"多轮对话越长越贵"——下一段会讲怎么管理。

这是新手最容易踩的坑，我单列一节强调。很多人体验 ChatGPT 网页版觉得"它记得我上一句"，那是因为**前端帮你把历史拼进 messages 了**，模型本身是无状态的。一旦你用 API 自己写代码，就必须自己充当那个"前端"：每轮把 `user → assistant → user → assistant …` 一路累积，连同 `system` 一起重发。

这带来两个工程后果：
1. **成本随轮数线性增长**：第 10 轮要把前 9 轮内容再发一遍（下一篇的上下文管理专治此病）。
2. **你必须自己管理历史**：清理、截断、摘要都由你负责，模型不会帮你"忘掉"东西。

### 1.4 一次完整的请求-响应流程（ASCII 拆解）

```
你(代码)                 OpenAI 兼容 API                模型(后端)
   │                          │                            │
   │  1. POST /v1/chat/       │                            │
   │     completions          │                            │
   │  {model, messages, ...}  │                            │
   │ ───────────────────────> │  2. 把 messages 编码成    │
   │                          │     token 序列             │
   │                          │ ─────────────────────────> │
   │                          │                            │ 3. 自回归逐个生成
   │                          │                            │    token，拼成回答
   │                          │ <───────────────────────── │
   │  4. 返回 JSON:           │                            │
   │     {choices, usage}     │                            │
   │ <─────────────────────── │                            │
   │                          │                            │
```

`usage` 字段（第 4 步）是你做成本控制的唯一依据，一定要把它记录下来——它告诉你这次调用烧了多少 token。

### 1.5 返回结构逐字段拆解

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

几个要点：
- `choices` 是数组，因为你可以设 `n>1` 让模型一次生成多个候选（做自洽投票时有用）。
- `finish_reason == "length"` 意味着**输出被 `max_tokens` 截断了**——拿到的是半截内容。这在使用 JSON 输出时尤其致命（解析不出来的半截 JSON）。务必检测。
- `usage` 里的 `prompt_tokens` 是你发给模型的全部 token，`completion_tokens` 是模型生成的。计费 = 前者 × 输入单价 + 后者 × 输出单价。

### 1.6 system 提示词的写法（与上一篇的呼应）

`system` 段是你"钳制"模型行为最有力的地方，它对应上一篇讲的"角色设定 + 全局约束"。写好 system 的几条经验：

- **放在开头且保持稳定**：system 通常只对第一条消息生效（后续多轮你依然要把它放在 messages 最前面重发）。它越稳定，越容易被服务商的"Prompt 缓存"命中，既省钱又快（这一点下一篇会展开）。
- **把"不可违反的规则"写进 system**：比如"只能回答与电商相关的问题，其余一律拒绝""输出必须是合法 JSON"。把这类硬约束放 system，比散落在 user 里更不容易被模型忽略。
- **不要塞太多无关内容**：system 会随每一轮重发计费（呼应下一篇的 O(n²) 成本），写太长等于给每次调用加税。精炼为王。
- **与 tokenization 的关系**：你写的 `messages` 最终会被 tokenizer 切成 token 再送进模型。同一个意思，不同的写法 token 数可能差很多（比如中文里"请勿"比"请不要"省 token）。这不影响质量，但影响成本——这也是为什么下一篇要把"精简 system"列为降本第一招。

从更宏观的视角看：你发的 `messages`，在模型眼里就是一段被拼接好的 token 序列，模型用它在预训练阶段学过的"预测下一个 token"能力（呼应阶段 5 的 CLM 目标）去续写。你写的 system / user / assistant，本质上都是在"给模型一个最强的开头偏置"。理解这一点，prompt 工程就不再是玄学，而是"如何构造一个让模型续写出你想要内容的前缀"。

## 二、为什么国产模型能直接用 OpenAI SDK？

### 2.1 "事实标准"是怎么形成的

因为 OpenAI 的 `/v1/chat/completions` 协议成了事实标准。这一切源于 2023 年前后，OpenAI SDK（Python 的 `openai` 库）成了开发者最熟悉的接口。国内厂商和本地推理框架（vLLM、Ollama、LM Studio）为了让用户"零改代码"迁移，几乎都提供了**兼容模式**——接口路径、请求体、返回体都与 OpenAI 保持一致，你只改 `api_key` 和 `base_url` 两个参数，业务代码一行不用动。

这不仅是个便利，更是个**架构决策**：它让你的业务代码和模型供应商**解耦**。哪天要换模型、或者从云端切到本地私有化部署，只改配置，不动逻辑。

### 2.2 一套代码对接多家（含本地）

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

**这个设计的价值再强调一次**：你的业务代码和模型供应商**解耦**。设想你的产品先用了便宜的小模型跑通，后来要上更强的大模型，或者因为合规要切到公司内网私有部署——只要供应商提供 OpenAI 兼容接口，你改一个 `base_url` 就完事，上层几百行业务逻辑纹丝不动。这是大模型应用能"快速试错、随时换引擎"的底气。

### 2.3 本地模型的特殊价值

注意上面列表里的"本地 vLLM / 本地 Ollama"——它们的 `base_url` 是 `localhost`。这意味着同一套代码既能调云端 API，也能调你**自己机器上跑的开源模型**。本地部署的价值在于：数据不出内网（合规）、无调用费用（一次性硬件成本）、可微调可调试。对想深入大模型开发的你来说，用 Ollama 在笔记本上跑一个 7B 模型做实验，是零成本练手的最佳路径。后面 Function Calling 和 RAG 的很多示例，你都可以用本地模型离线跑通。

### 2.4 怎么选模型：大模型开发的"选引擎"思维

既然一套代码能换任意模型，那"选哪个"就成了工程决策，而不是代码决策。给一个实用的选型框架：

| 维度 | 怎么权衡 |
|---|---|
| **能力** | 复杂推理、长文档理解、强对齐，优先大模型（GPT-4o、Claude、Qwen-Max、DeepSeek-V3）；简单分类/抽取用 7B~14B 小模型足够 |
| **成本** | 小模型通常便宜一个数量级；高频场景（每天百万次）优先小模型，把成本压下来 |
| **延迟** | 本地小模型首字延迟低、不依赖网络；云端大模型网络往返 + 排队会慢 |
| **合规** | 数据敏感的选本地私有部署或国产合规模型 |
| **上下文窗口** | 要塞长文档的选 128K+ 的模型，否则要靠下一篇的上下文管理或 RAG |

一句话：**先小后大、按需升级**。先用最便宜的模型把链路跑通，发现能力不够再换大的；不要一上来就挂最贵最强模型，那样你既看不出瓶颈，也浪费钱。这也是为什么本专栏反复强调"把模型当可替换组件"——你的架构天生就该支持热插拔。

### 2.5 base_url 到底是什么：一次 HTTP 请求的真相

理解 `base_url` 能帮你彻底去掉"调用大模型"的神秘感。本质上，`client.chat.completions.create(...)` 干的事就是向 `base_url + "/chat/completions"` 发一个 HTTP POST 请求，body 是 JSON（含 `model`、`messages`、`temperature` 等），然后解析返回的 JSON。所谓"国产模型兼容 OpenAI"，就是它们的服务端**也实现了这个接口**。所以：

- `https://api.openai.com/v1` + `/chat/completions` = OpenAI 官方端点；
- `https://api.deepseek.com` + `/chat/completions` = DeepSeek 端点（接口形状一致）；
- `http://localhost:8000/v1` + `/chat/completions` = 你本地 vLLM 起的端点。

明白了这一点，你就知道：哪怕没有 `openai` 库，用 `requests.post` 也能调通任何一家——SDK 只是把这个过程封装得更优雅、自带重试和流式解析而已。当你遇到某家文档"画的和 OpenAI 不一样"时，别慌，多半只是参数名的小差异，核心契约（messages + 返回 choices/usage）八成是相通的。

## 三、代码实战 1：流式输出（打字机效果）

### 3.1 为什么需要流式

非流式调用（上面的例子就是）要等模型把整段话生成完才返回，可能要等十几秒。在用户面前干等十几秒，体验是很差的。流式则是**生成一个字就返回一个字**，体验完全不同——这就是 ChatGPT 那种"打字机"效果的来历。

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

### 3.2 三个千万不能漏的细节

1. `stream=True` 打开流式；
2. 每个 chunk 的 `delta.content` 可能是 `None`（最后一个 chunk 通常是空的，或者只剩 `finish_reason`），要做判空，否则会报 `NoneType` 错误；
3. `flush=True` 才能真正实现"一个字一个字跳出来"，否则会被缓冲区攒着一起打印（看到的是整段瞬间出现，失去打字机效果）。

### 3.3 流式背后的数据形态

流式不是魔法，它只是把一次完整响应**切成很多小块（chunk）**逐块推送，协议上用的是 SSE（Server-Sent Events）。每一块里只携带"相比上一段新增的内容"（所以叫 `delta`，增量）。你把它们依次拼起来，就是完整回答。理解 `delta` 是"增量"而非"全量"，是写对流式代码的关键。

> 在 Web 应用里，流式通常配合 **SSE（Server-Sent Events）** 或 WebSocket 推给前端。FastAPI 里返回 `StreamingResponse` 即可（阶段 10 部署篇会实战）。如果你做的是命令行工具或脚本，上面这段 `print(..., flush=True)` 就足够了。

### 3.4 流式输出的工程取舍

流式不是银弹，它有自己的代价和适用边界，别无脑全开：

- **优点**：首字延迟低，用户立刻看到内容在"动"，体感好；长回答能把等待感打散；配合前端能做出进度感。
- **缺点**：流式接口**不太方便做"整体校验"**——你拿到的是增量碎片，要等全部拼完才能对完整结果做 JSON 解析或长度检查；而且如果中途网络断了，已经吐出的部分就浪费了，需要整段重来。
- **何时用**：对话、写作、代码生成这类"越长越爽"的场景，必开流式。而**结构化抽取 / 需要一次性拿到完整 JSON** 的场景，用非流式更省心——你直接拿到完整对象再解析，逻辑最简单。
- **折中**：有些框架支持"流式吐字但最后补一个结构化结果"，或者用两次调用（先流式给个概要，再非流式出 JSON）。具体取舍取决于你的产品形态。

一句话：**对话用流式，抽取用非流式**，这是多数生产系统的默认配置。

## 四、代码实战 2：生产级客户端（重试 + 超时 + 计费）

### 4.1 真实环境必须处理什么

Demo 能跑≠生产可用。真实环境必须处理：网络抖动、限流（429）、服务端错误（5xx）、超时，以及——**把每次调用的 token 消耗记下来做成本统计**。下面是一个可直接用的封装：

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

### 4.2 这段代码里的三个工程要点

1. **指数退避重试**：第 n 次失败等 `2^n` 秒（1s、2s、4s…）。直接密集重试会加重限流，把本就拥塞的服务打得更死。生产环境建议再加上**随机抖动（jitter）**——在 `2^n` 基础上叠加一个随机小数，避免大量客户端"同步重试"造成惊群效应。
2. **只重试"可重试"的错误**：限流（429）、连接错误、服务端 5xx 值得重试；**参数错误（400）、鉴权失败（401）重试一万次也没用**，应该立刻抛错。代码里 `RETRYABLE` 元组正是这个名单。把不可重试错误也重试，是线上常见的"假死"根源。
3. **超时必须设**：默认超时往往过长。用户等 60 秒没反应就走了，不如早点失败走降级（返回缓存答案或兜底文案）。`timeout=30` 是个常见的起步值，按业务容忍度调。

### 4.3 线程安全与统计

注意 `UsageStats` 用了 `threading.Lock`——如果你的应用是多线程并发调模型的（很多 Web 服务都是），不加锁地累加 `prompt_tokens` 会出现竞态，统计数字会偏小甚至错乱。这个细节在单体脚本里看不出问题，一上并发就暴露。把统计做成线程安全，是"能上线"和"玩具"的差别之一。

### 4.4 高并发怎么办：异步客户端

上面 `LLMClient` 用的是同步 `OpenAI` 客户端，一次调用阻塞一个线程。如果你要同时发成百上千个请求（比如批量处理用户评论），同步模型会让线程数爆炸。这时应该用 **异步客户端** `AsyncOpenAI`：

```python
import asyncio
from openai import AsyncOpenAI

async def main():
    client = AsyncOpenAI(api_key="sk-xxx", base_url="https://api.deepseek.com")
    # 同时发 10 个请求，用 asyncio.gather 并发
    tasks = [client.chat.completions.create(
        model="deepseek-chat",
        messages=[{"role": "user", "content": f"用一句话形容数字 {i}"}],
    ) for i in range(10)]
    results = await asyncio.gather(*tasks)
    for i, r in enumerate(results):
        print(i, r.choices[0].message.content)

asyncio.run(main())
```

异步客户端在 IO 等待期间不占线程，能轻松支撑高并发。但要注意：并发太高会触发服务商限流（429），所以需要配合信号量（如 `asyncio.Semaphore(8)`）做并发上限，并在拿到 429 时按退避逻辑重试——这正是 6.2 节提到的限流防护在异步世界的对应实现。

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

这是最容易被忽略的坑——**被截断的 JSON 是解析不出来的**，必须检测并重试。完整的处理可以结合上一篇的 `extract_json`：如果 `finish_reason == "length"`，就把 `max_tokens` 调大重试一次。

### 5.1 temperature 与 top_p 的关系

这两个参数都在控制"随机性"，但角度不同：`temperature` 直接缩放 logits 的 softmax 温度，`top_p`（核采样）则是"只从累积概率达到 p 的最小候选集里选"。实践中**二选一调即可**，同时大幅调两个会互相打架。经验值：`temperature=0` 是"贪心/确定性"最强（同输入同输出，适合需要稳定的抽取任务），`temperature≈1` 最发散（适合头脑风暴）。

### 5.2 seed 的真相

很多新手以为设了 `seed` 就能完全复现。现实是：**它只能让结果"更可能"一致，不保证逐字相同**。因为底层推理涉及 GPU 浮点非确定性、批处理顺序等。如果要严格可复现，需要更底层的设置（如固定批大小、关闭某些优化），通常只有评测场景才需要。日常开发别把 `seed` 当银弹。

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

### 6.1 关于 API Key 安全（展开讲）

把 `sk-xxx` 直接写进源码并提交到 git，是**最高频也最危险**的失误。一旦仓库被推到 GitHub 公开库，机器人几分钟就能扫到你的 key 并疯狂刷量，账单分分钟上万。**正确做法**：

```python
import os
client = OpenAI(
    api_key=os.environ["OPENAI_API_KEY"],
    base_url=os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1"),
)
```

把密钥放进 `.env` 文件（且 `.env` 加入 `.gitignore`），用 `python-dotenv` 加载。本地模型（localhost）不需要 key，但云端一律走环境变量。

### 6.2 客户端单例与连接复用

`OpenAI(...)` 内部维护着 HTTP 连接池。如果你在 for 循环里每次都 `OpenAI(...)` 新建，连接无法复用，不仅慢，还可能在高并发下把文件描述符打满。正确做法是**一个进程建一个 client 实例**（单例），所有调用共用它——这也是上面 `LLMClient` 把 `self.client` 放进构造函数的原因。

### 6.3 限流（429）的深层处理

`429 Too Many Requests` 是生产环境最常见的"可重试"错误，但处理它有三个进阶要点，新手常漏：

1. **读懂 `Retry-After` 头**：服务端在 429 响应里常常带一个 `Retry-After` 字段，告诉你"多久后再来"。专业的客户端应该读这个值来定重试等待，而不是盲目用固定 `2^n` 退避——否则可能等太久（浪费时间）或等太短（马上又撞墙）。
2. **区分"硬限流"和"突发限流"**：有的限流是"每分钟 N 次"的硬配额，有的只是瞬时突发保护。前者重试也大概率继续 429，应该走"排队 + 降速"而不是疯狂重试；后者稍等即可。
3. **退避要加抖动**：固定 `1s/2s/4s` 退避在"很多客户端同时被 429"时会同步重试、再次撞墙（惊群）。加上随机抖动（如 `wait = 2^n + random(0,1)`）能把重试错开，整体更快恢复。

把这三点和 4.2 节的"指数退避 + 只重试可恢复错误"结合起来，你的客户端才算真正经得起生产拷打。

## 七、本篇小结

1. **输入是 messages 列表**，模型**没有记忆**——多轮对话必须自己拼接历史。
2. OpenAI 协议是事实标准，**换模型只改 `api_key` + `base_url`**，业务代码零改动（云端 ↔ 本地同理）。
3. **流式输出**用 `stream=True`，注意 `delta.content` 判空与 `flush=True`。
4. 生产客户端必备三件套：**指数退避重试、超时、usage 统计**；只对可恢复错误重试。
5. `finish_reason == "length"` 意味着**输出被截断**，必须检测——这是"JSON 解析失败"最常见的原因。

## 八、实战练习（可验证小任务）

1. **跑通一套代码多模型**：用本篇第二节的 `providers` 字典，把同一个问题分别发给两个不同 `base_url` 的模型（可含一个本地 Ollama 模型），确认只改配置即可，并对比两者 `usage.total_tokens`。
2. **流式 vs 非流式**：分别用 `stream=True` 和默认调用问同一道题，记录各自的"首字延迟"感受，验证流式确实边生成边返回。
3. **重试验证**：故意传一个错误的 `base_url`（连不上的地址），观察 `LLMClient.chat` 是否按 1s/2s/4s 退避重试并最终抛错，确认 `stats.errors` 被正确累加。
4. **截断复现**：把 `max_tokens` 设成一个很小的值（如 20），问一道需要长答案的题，确认 `finish_reason == "length"`，并实现"调大 max_tokens 重试"的逻辑。
5. **成本统计**：连续调用 10 次，打印 `llm.stats`，用返回的 `cost()` 算出这 10 次的总预估花费。

## 九、延伸阅读与下一步

- **OpenAI SDK 官方文档**：`chat.completions` 全部参数语义，建议通读一遍 `messages`、`stream`、`response_format` 的说明。
- **SSE 与流式协议**：理解 Server-Sent Events，掌握前端如何消费流式接口（对做 Web 应用至关重要）。
- **限流与退避算法**：学习"指数退避 + 抖动（Exponential Backoff with Jitter）"的经典实现，比固定退避更稳。
- **密钥管理**：了解 `.env`、Vault、云厂商的密钥服务，把"别把 key 写进代码"变成工程习惯。
- **批处理 API（Batch）**：OpenAI / 各家都提供 24 小时异步批处理，价格通常腰斩，适合离线大批量任务。

**下一篇**：现在模型能说会道了，但它**只能说，不能做**——不知道今天的天气、查不了你的数据库、算不了实时汇率。下一篇《Function Calling——让大模型调用你的函数》打通这条链路：定义工具的 JSON Schema，让模型自己决定调哪个、传什么参数，然后写一个完整的"模型 → 工具 → 回填 → 再回答"循环，跑通一个真正能干活的助手。

> 本篇是《大模型开发从 0 到 1》专栏第 35 篇，阶段 6「提示词工程与大模型 API」第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
