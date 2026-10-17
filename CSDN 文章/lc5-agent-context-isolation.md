# Agent 上下文隔离：为什么子任务之间不能共用一个上下文

多 Agent 系统里最常见的一类事故，是「串味」。客户 A 的客服 Agent 返回了客户 B 的订单信息；或者同一个 Agent 在处理第二份工单时，还在引用第一份工单里的参数；更隐蔽的——子 Agent 明明只该看自己那一摊数据，却因为继承了父 Agent 的完整上下文，看到了全局配置。

这些不是提示词写歪了，是**上下文没有隔离**。这一篇讲清楚隔离的粒度怎么定、实现上有几种做法、以及为什么这是 Agent 系统安全与质量的地基。

---

## 一、为什么上下文要隔离

### 1.1 上下文的三个副作用

我们一般把上下文理解为「喂给模型的信息」。但在多 Agent 场景下，它同时承担了三个危险角色：

**它是状态污染源。** 上下文里任何一条信息，模型都会当成当前任务的既定事实。上一个任务的残留（比如「刚才那份数据用的是测试库」）会影响下一个任务的判断，而模型不会主动声明「这个信息可能过时了」。

**它是权限边界。** 谁的信息进了上下文，谁的信息就能被模型看见。子 Agent 的上下文里有客户 B 的订单，它就可能把客户 B 的数据返回给客户 A。这是数据泄露，不是模型幻觉。

**它是成本放大器。** 父 Agent 攒了 50 轮推理的上下文，子 Agent 全部继承，光是读一遍就是几千 token。而且**这几十轮里的试错、纠偏、无关探索**，对子任务毫无价值，甚至是干扰。

### 1.2 一个具体的事故

一个 SaaS 客服系统，主 Agent 处理会话，遇到复杂问题派发给「技术排查」子 Agent：

```python
# 错误做法：把整个对话历史塞给子 Agent
sub_agent.invoke({
    "messages": parent_history      # ← 包含前面三位不同客户的对话
})

# 结果：子 Agent 回答时混用了前一位客户的工单号
```

第一版没人在意，因为单客户会话一直很正常。直到一位客户问「我的工单到哪一步了」，子 Agent 准确报出了上一个客户的工单号——**准确得让客户以为是系统在跨客户读取他的数据**。这是个严重的合规事故。

修复方向很明确：子 Agent 只能收到**与当前客户、当前任务相关的**上下文。

---

## 二、隔离的四个层次

上下文隔离不是二元的（隔离/不隔离），它有粒度。从粗到细分四层：

### 2.1 层一：任务间隔离

**不同任务之间不共享任何上下文。**

这是最基础的。一个在线客服 Agent 同时服务多个会话，会话 A 的上下文绝不能流向会话 B。

实现上，只要**用 thread_id / session_id 把状态分桶**就行：

```python
# LangGraph 里用 thread_id 天然隔离
config = {"configurable": {"thread_id": f"conversation_{conversation_id}"}}
agent.invoke({"messages": [...]}, config=config)
```

看起来简单，但漏配 thread_id 是所有事故里最常见的一种——本地测试时只有一个会话，看不出问题，上线多并发立刻暴露。

### 2.2 层二：Agent 间隔离

**父 Agent 的推理过程，不自动流入子 Agent。**

```python
# 错误：子 Agent 继承了父的全部消息历史
sub_agent.invoke({"messages": parent_state["messages"]})

# 正确：只传任务描述 + 必要输入
sub_agent.invoke({
    "messages": [("human", SUBTASK_TEMPLATE.format(
        description=task["description"],
        inputs=task["inputs"],        # 只给这个子任务需要的输入
        output_format=task["output_format"],
    ))]
})
```

父 Agent 的思考过程对它自己有价值（它据此做了分派决策），对子 agent 是**噪音**。子 Agent 拿到一个干净的、只描述「你要干什么」的上下文，产出更稳定。

### 2.3 层三：Agent 内部的多角色隔离

**同一个 Agent 内部，不同阶段的上下文也要分。**

典型例子：一个「先检索、再分析、再生成」的 Agent。检索阶段会抓到大量原始材料（几千字），但如果全留在上下文里，后面的分析和生成阶段就被噪声占满。

```python
# 阶段化：每阶段只把产出传给下一阶段，不传过程
raw_docs = search(query)                    # 阶段1
relevant = filter_and_rank(raw_docs)        # 阶段2，只看 raw_docs
findings = analyze(relevant)                # 阶段3，只看 relevant
answer = generate(findings)                 # 阶段4，只看 findings
```

这就是链式调用的上下文隔离版。**每一层只收到上一层的「结论」，不收到「过程」。**

### 2.4 层四：租户/用户级隔离

**不同用户或租户的数据上下文严格分离。**

这不只是上下文问题，是所有存储层的隔离。但上下文是最后一道关口：

```python
def build_context_for_user(user_id: str, query: str):
    # 检索时就把 ACL/租户过滤做在检索层，而不是指望模型自己过滤
    docs = vectorstore.search(
        query,
        filter={"tenant_id": user_id, "visibility": "public"},
    )
    return docs
```

**核心原则：隔离必须在检索层、存储层做，不能指望模型在生成层「自觉不看」。** 上下文里出现的东西，模型就可能说出来。

---

## 三、几种隔离实现方案

### 3.1 方案一：会话隔离（最简单）

```python
class AgentContextManager:
    def __init__(self):
        self.sessions: dict[str, list] = {}

    def get(self, session_id: str) -> list:
        return self.sessions.get(session_id, [])

    def append(self, session_id: str, role: str, content: str):
        if session_id not in self.sessions:
            # 新会话只继承系统提示，不继承任何其他会话
            self.sessions[session_id] = [("system", SYSTEM_PROMPT)]
        self.sessions[session_id].append((role, content))
```

适用：绝大多数单用户交互场景。**关键是 session_id 必须由外部可靠地传进来**，不能由模型自己决定或从请求里推测。

### 3.2 方案二：任务上下文对象

把「一个任务的完整输入」封装成一个显式对象，只把必要字段传给下游：

```python
@dataclass(frozen=True)
class TaskContext:
    task_id: str
    user_id: str
    intent: str
    inputs: dict          # 只有这个任务需要的输入
    constraints: dict     # 权限、时限、可用工具
    # 注意：没有 parent_history，没有其他任务的字段
```

`frozen=True` 防止中途被污染。下游节点只认这个对象，拿不到别的东西——**这是用类型系统做隔离**，比约定更可靠。

### 3.3 方案三：按需读取（文件/存储桥接）

父 Agent 和子 Agent 之间不传内容，只传路径：

```python
@tool
def handoff_task(task_description: str, input_path: str, output_path: str) -> str:
    """派发子任务。输入数据放在 input_path，子 Agent 把结果写到 output_path。"""
    sub_agent.run(task_description, read=input_path, write=output_path)
    return f"完成，详见 {output_path}"
```

好处：子 Agent 只读它需要的文件，上下文里永远只有路径而不是全文。这是 DeepAgents 那套架构的核心，也是**处理长任务时的最优解**。

### 3.4 方案四：工具级隔离

不隔离上下文，而是**从根上限制子 Agent 能调用的工具**。技术排查子 Agent 只有只读运维工具，没有发邮件的工具——就算上下文里带了不该带的东西，它也做不出越权操作。

```python
TECH_AGENT_TOOLS = [query_metric_ro, view_log_ro, query_alarm_ro]
# 注意：没有 deploy、没有 send_email、没有 delete_*
```

**工具隔离是最后一道物理防线。** 上下文隔离靠的是「不出错」，工具隔离保证「出错了也做不了坏事」。两者都要有。

---

## 四、什么时候该共享上下文

隔离不是绝对的，有些场景共享是对的。判断标准是**对任务完成是否必要，以及信息是否在同一授权范围内**。

### 4.1 该共享的三类

**同一会话内的多轮对话**：用户第二句「那涨价了吗」必须能看到第一句的指代对象。这是正常的会话连续性。

**上下级任务的必要衔接**：上级要求下级「基于刚才那份分析，写一个简报」。下级必须看到「刚才那份分析」——但要看到的是**分析结论**，不是上级自己的试错过程。

**同租户内的通用配置**：用户的企业名称、业务线、常用系统——这些对同租户内所有 Agent 都成立，且不敏感。

### 4.2 不该共享的三类

**跨租户的一切。** 没有任何例外。

**Task 执行过程。** 试错、纠偏、被否决的方案，对下游是噪声。

**用户的原始凭证/隐私字段。** 手机号、身份证、token——在上下文里多停留一毫秒都是风险，能脱敏就脱敏，能不到上下文就不进上下文。

### 4.3 一个实用的灰度判据

写代码时问自己三个问题，全过才共享：

1. 下游任务是否**必须**这条信息才能完成？
2. 这条信息和下游任务是否在**同一授权范围**内？
3. 如果这条信息泄露给下游 Agent 的其他用户，风险有多大？

三个都答「否」，就别传。

---

## 五、隔离带来的代价与对冲

隔离不是免费的，有两个明确代价，要有对冲手段。

### 5.1 代价一：子 Agent 缺背景，产出偏题

传太少的上下文，子 Agent 不知道该按什么风格、什么约束做。

**对冲**：把「背景」拆成结构化字段传，而不是整段对话历史。

```python
handoff(
    task="写一份系统复盘简报",
    background={
        "audience": "客户的技术负责人，熟悉 K8s",
        "tone": "客观、不推责、聚焦处置过程",
        "facts": ["事故时间 10-12 09:30~10:05", "影响支付成功率", "已回滚"],
        "forbidden": ["不要提内部团队名", "不要写具体故障代码"],
    },
)
```

比「把整段对话塞给它」干净得多，也比「什么都不给」好得多。

### 5.2 代价二：父 Agent 需要做更多「翻译」

父 Agent 要把自己的意图翻译成子 Agent 能消化的独立描述。这个翻译本身要花 token，还可能出错。

**对冲**：用 `task` 工具的模板化参数把翻译标准化，见上面那段——固定字段比自由发挥稳。

### 5.3 代价三：排障变难

隔离之后，trace 是断的。子 Agent 内部发生了什么，父 trace 里看不到。

**对冲**：**加 trace_id 贯穿全链路**。所有 Agent 调用都带同一个 trace_id 和 span_id，排障时能拼回完整链路。

```python
@app.post("/chat")
def chat(req: ChatReq):
    trace_id = f"trace-{uuid4().hex[:12]}"
    logger.info("request.start", extra={"trace_id": trace_id, **req.model_dump()})
    # 所有下游调用都带 trace_id
```

这是「隔离」和「可观测」之间唯一的桥梁，缺了它，隔离就等于把系统变成黑盒。

---

## 六、一套检查清单

上线前对着过一遍：

**会话与身份**
- [ ] 每个请求都必须显式传入 session_id / user_id，不接受从内容推断
- [ ] thread_id 在每次请求里正确设置，没有落到默认桶

**Agent 间**
- [ ] 子 Agent 只收到结构化任务描述，不收到父 Agent 的完整历史
- [ ] handoff 的数据传递是显式白名单，不是「把所有 state 都给它」

**检索与数据**
- [ ] 检索层就带租户/ACL 过滤，不依赖模型自觉
- [ ] 上下文里没有用户凭证、隐私字段的原始值
- [ ] 子 Agent 写文件/读文件的路径限制了工作区

**工具与权限**
- [ ] 子 Agent 的工具集按最小必要裁剪，没有高危写操作
- [ ] 高危操作（删除、部署、外发）有独立确认步骤

**可观测**
- [ ] trace_id 贯穿父 Agent、子 Agent、所有工具调用
- [ ] 每次 handoff 记录「传了什么、为什么传」

---

## 七、常见误区

**误区一：只在 prompt 里写「不要泄露其他用户信息」。** 提示词不是安全边界。上下文里有，模型就可能说。隔离要在数据和工具层做。

**误区二：把上下文隔离理解成「少给信息」。** 它是「给对的信息，且只在授权范围内」。给太少会偏题，给错了会出事故。

**误区三：父 Agent 的推理链路是宝贵资产，要全传下去。** 那是父 Agent 的资产，不是子 Agent 的。传结论，别传过程。

**误区四：隔离之后不做 trace 串联。** 隔离让排障变难，不补 trace 就是留个黑盒给自己。

**误区五：只在单租户环境下测过就上线。** 隔离类 bug 在单会话下几乎 100% 看不出来，必须用多用户并发测试。

---

## 小结

- 上下文隔离是多 Agent 系统安全与质量的地基，**不是可选的优化**。它同时防三件事：状态污染、数据越权、成本膨胀。
- 四个隔离层次：**会话间、Agent 间、Agent 内阶段间、租户级**。粒度从粗到细，越靠后越接近安全边界。
- 实现靠四样东西：**会话分桶（session/thread_id）、结构化任务上下文对象、路径传递替代内容传递、工具集最小化**。其中工具隔离是物理防线——前三个出错，它还能兜住。
- 隔离的原则：**隔离在检索层和数据层做，不能指望模型自觉**。提示词不是安全边界。
- 隔离有代价（子 Agent 缺背景、翻译成本、排障变难），对冲手段分别是结构化 background、handoff 模板、trace_id 全链路贯穿。
- 上线前三问：下游是否必须、是否同授权范围、泄露风险多大。三问不过，不传。

多 Agent 系统的复杂度不在「有几个 Agent」，而在「它们之间流动什么」。把流动的边界画清楚，系统才既聪明又安全。
