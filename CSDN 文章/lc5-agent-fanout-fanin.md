# 扇出扇入：并发的子任务怎么并行跑、又怎么收回来

「读这 20 份 PDF，各自总结要点」——这种任务天然适合并行。但真写起来你会发现：**并行发出去很容易，把结果完整收回来很难。**

丢了一个子任务的结果没发现？某个子任务超时把整个流程卡死？结果顺序乱了导致报告串行？这就是扇出（fan-out）和扇入（fan-in）要解决的问题。

这一篇讲清楚并发调度的实现、结果聚合的几种策略、以及失败处理的核心原则。

---

## 一、扇出扇入在什么时候是必要的

先判断值不值得上并发。

### 1.1 三个必要条件

1. **子任务之间无依赖**——有依赖的必须串行，强上并发只会得到错乱的结果
2. **单个子任务耗时不可忽略**——如果每个只要 1 秒，并发的调度开销可能反而更慢
3. **结果需要汇总**——纯粹的「通知多个系统」是扇出不需要扇入，那是另一类问题

### 1.2 典型场景

- 多文档并行摘要 / 多来源并行检索
- 多模型投票（同一个问题问三个模型）
- 多方案并行生成与择优
- 批量数据清洗的执行阶段

**特征都是「N 个同构任务 + 1 个聚合」。** 这是扇出扇入的标准形态。

---

## 二、扇出：怎么把任务发出去

### 2.1 线程池还是 asyncio

两个选择，差别在任务类型：

- **IO 密集型**（LLM 调用、HTTP 请求、数据库）→ **asyncio**，单线程能扛上千并发
- **CPU 密集型**（本地数据处理、解析）→ 线程池/GIL 受限，用多进程（`ProcessPoolExecutor`）

Agent 场景绝大多数是 IO 密集，**asyncio 是默认选择**。

```python
import asyncio

async def fan_out(subtasks: list[SubTask], max_concurrency: int = 5):
    sem = asyncio.Semaphore(max_concurrency)

    async def run_one(task: SubTask):
        async with sem:
            return await execute_subtask(task)

    tasks = [asyncio.create_task(run_one(t)) for t in subtasks]
    return await asyncio.gather(*tasks, return_exceptions=True)
```

### 2.2 并发度不是越大越好

直觉是「并发越高越快」，但有四个上限：

| 限制因素 | 说明 |
|---------|------|
| **API 限流** | 最常撞的墙。TPM/RPM 一超就 429，堆并发只会全批失败 |
| **后端容量** | 并发打同一个数据库，连接池打满 |
| **收益递减** | 从 1 到 5 提速明显，从 10 到 20 提升很小 |
| **成本守恒** | 并发的 token 总量不变，只是时间压缩了 |

**并发度的测定方法**：拿 20 个真实子任务，分别用 3、5、8、12 并发跑，看总耗时和失败率。找到「耗时下降开始变平」的那个点。

我的经验值：**打 LLM API 的场景，5~8 是甜点区**（取决于你的 rate limit 档位）。

### 2.3 每个子任务必须能独立定位

```python
@dataclass
class SubTask:
    id: str                    # 唯一，聚合时用来对账
    description: str
    input_path: str | None
    output_path: str           # 结果落盘路径
    timeout: float = 120.0
    retry: int = 1
```

**给每个子任务一个 id 和一个输出路径**，是后续对账的基础。少了这两样，聚合阶段就是在猜。

---

## 三、扇入：结果怎么收

这是整个模式里最容易出错的部分。核心问题是：**怎么保证 N 个子任务的结果，一个不少地回到主流程手里。**

### 3.1 策略一：全成功才算成功

```python
results = await asyncio.gather(*tasks, return_exceptions=True)

failures = []
successes = []
for task, res in zip(subtasks, results):
    if isinstance(res, Exception):
        failures.append((task.id, res))
    else:
        successes.append((task.id, res))

if failures:
    # 全有或全无：任何一个失败就整体失败
    raise FanInError(f"{len(failures)}/{len(subtasks)} 个子任务失败: {failures}")
```

**适用**：子任务结果需要互相一致（比如生成一份完整报告的各个章节，缺一章就没法用）。**不适用**：20 份文档摘要丢 1 份——整体报告做个「19 份摘要」也比全丢强。

### 3.2 策略二：部分成功，降级处理（更常用）

```python
def fan_in_degrade(subtasks, results, min_success_ratio: float = 0.8):
    successes, failures = split_results(subtasks, results)

    if len(successes) / len(subtasks) < min_success_ratio:
        raise FanInError("成功的子任务不足 %.0f%%，放弃" % (min_success_ratio * 100))

    report = f"成功 {len(successes)}/{len(subtasks)}。"
    if failures:
        report += "未完成的部分：" + "、".join(fid for fid, _ in failures)
    return successes, report
```

**关键设计：失败要被「点名」而不是静默丢弃。** 报告里必须列出哪些失败了——否则用户以为 20 份全处理了，实际只有 17 份。

**多数生产场景用这个策略。**

### 3.3 策略三：按序重组

如果结果有顺序依赖（比如报告章节 1、2、3），扇入时必须重排：

```python
# gather 返回顺序和传入顺序一致，但如果用了 as_completed 就乱了
async def fan_out_ordered(subtasks):
    tasks = {t.id: asyncio.create_task(run_one(t)) for t in subtasks}
    # 按原顺序等待，先完成的先产生结果但不阻塞后面
    ordered = []
    for t in subtasks:
        ordered.append(await tasks[t.id])
    return ordered
```

**注意**：`asyncio.gather` 天然保序（按传入顺序返回），`asyncio.as_completed` 是按完成顺序。要顺序就 gather，要「先完成先处理」就 as_completed，**别混用还以为有顺序**。

### 3.4 对账：一个都不能少

聚合后做一次显式核对：

```python
def reconcile(subtasks: list[SubTask], results: dict) -> list[str]:
    """返回缺失的 task id 列表。空列表 = 完整。"""
    return [t.id for t in subtasks if t.id not in results]
```

**这个函数应该在任何聚合逻辑前跑一次。** 我见过不止一个系统，子任务失败被 `return_exceptions` 静默吞掉，聚合时按「收到的结果」写报告，永远少几份却没人发现。**对账是防这个的最低成本手段。**

---

## 四、失败与超时处理

### 4.1 单个子任务超时

```python
async def run_with_timeout(task: SubTask):
    try:
        return await asyncio.wait_for(execute_subtask(task), timeout=task.timeout)
    except asyncio.TimeoutError:
        return SubtaskResult(id=task.id, status="timeout", error=f"超过 {task.timeout}s")
```

**超时要转成结果，不要让它炸掉整个 gather。** 否则一个慢子任务会拖延整个批次的完成时间。

### 4.2 单个子任务失败重试

```python
async def run_with_retry(task: SubTask):
    for attempt in range(task.retry + 1):
        try:
            return await execute_subtask(task)
        except RetryableError as e:
            if attempt == task.retry:
                return SubtaskResult(task.id, "failed", str(e))
            await asyncio.sleep(2 ** attempt)
    # 不可重试的错误直接返回，不浪费尝试
```

**区分可重试/不可重试错误**：限流、超时、5xx 可重试；参数错误、鉴权失败重试也没用。

### 4.3 整批限流失败

如果 20 个子任务全部因为 429 挂了，不要重试 20 次——那是火上浇油。

```python
async def adaptive_fan_out(subtasks, initial_concurrency=5):
    concurrency = initial_concurrency
    results = {}
    idx = 0
    while idx < len(subtasks):
        batch = subtasks[idx:idx + concurrency]
        outcomes = await asyncio.gather(*[run_one(t) for t in batch],
                                        return_exceptions=True)
        rate_limited = sum(1 for o in outcomes
                           if isinstance(o, Exception) and is_rate_limit(o))
        if rate_limited:
            concurrency = max(1, concurrency // 2)      # 降一半
            await asyncio.sleep(5)
            continue                                     # 重跑这一批
        for t, o in zip(batch, outcomes):
            results[t.id] = o
        idx += concurrency
        # 全部成功可以试着加一点并发
        if not any(isinstance(o, Exception) for o in outcomes) and concurrency < 10:
            concurrency += 1
    return results
```

**核心思想：限流时降并发、全成功时缓慢升。** 比固定并发更适应真实的 API 环境。

---

## 五、结果聚合

拿到 N 个结果后，有三种处理方式。

### 5.1 拼接（最简单）

```python
final = "\n\n".join(f"## {r.title}\n{r.content}" for r in successes)
```

适合同构结果（N 份摘要 → 一份汇总）。

### 5.2 归并（去重合并）

```python
# 多个子任务检索到的文档，合并去重
all_docs = []
seen = set()
for r in successes:
    for d in r.documents:
        if d.id not in seen:
            seen.add(d.id)
            all_docs.append(d)
```

**多路径检索（向量 + BM25 + 多查询）后必须归并去重**，否则同一篇文档在上下文里出现三遍。

### 5.3 归纳（要模型参与）

```python
SUMMARY_PROMPT = """下面是 {n} 个子任务的处理结果。请归纳成一份总结。

要求：
1. 提炼共同结论，不要简单罗列；
2. 明确标注哪些子任务没有结果（输入里会标）；
3. 如果结果之间矛盾，如实呈现分歧。

子任务结果：
{results}"""

summary = await llm.ainvoke(SUMMARY_PROMPT.format(n=len(successes),
                                                  results=formatted))
```

**归纳时要把失败情况也告诉模型**，它会生成「有 3 个子任务未完成」的说明。这是上一条「点名失败」的自然延伸。

---

## 六、一个完整实现

```python
import asyncio
from dataclasses import dataclass, field

@dataclass
class SubResult:
    task_id: str
    status: str          # done / failed / timeout
    content: str = ""
    error: str = ""
    tokens: int = 0

async def fan_out_fan_in(
    subtasks: list[SubTask],
    executor,
    max_concurrency: int = 5,
    min_ratio: float = 0.8,
) -> dict:
    sem = asyncio.Semaphore(max_concurrency)

    async def run(task: SubTask) -> SubResult:
        async with sem:
            for attempt in range(task.retry + 1):
                try:
                    content, tokens = await asyncio.wait_for(
                        executor(task), timeout=task.timeout)
                    return SubResult(task.task_id, "done", content, tokens=tokens)
                except asyncio.TimeoutError:
                    return SubResult(task.task_id, "timeout",
                                     error=f"超过 {task.timeout}s")
                except RateLimitError:
                    await asyncio.sleep(3 * (attempt + 1))
                except Exception as e:
                    if attempt == task.retry:
                        return SubResult(task.task_id, "failed", error=str(e))
            return SubResult(task.task_id, "retry_exhausted")

    results_list = await asyncio.gather(*[run(t) for t in subtasks])

    # 对账
    results = {r.task_id: r for r in results_list}
    missing = [t.task_id for t in subtasks if t.task_id not in results]
    assert not missing, f"对账失败，缺失: {missing}"

    done = [r for r in results_list if r.status == "done"]

    # 比例检查
    if len(done) / len(subtasks) < min_ratio:
        raise FanInError(
            f"仅 {len(done)}/{len(subtasks)} 成功，低于阈值 {min_ratio:.0%}，"
            f"失败详情: {[(r.task_id, r.error) for r in results_list if r.status != 'done']}"
        )

    return {
        "results": results_list,          # 完整，含失败项
        "success_ratio": len(done) / len(subtasks),
        "total_tokens": sum(r.tokens for r in results_list),
        "failed": [(r.task_id, r.error) for r in results_list if r.status != "done"],
    }
```

注意三处设计：

- `results_list` 保留**全部**结果（含失败），聚合层自己决定怎么用
- **对账 assert**：宁可崩掉也不要静默丢结果
- `failed` 字段显式返回失败清单，上层负责在最终输出里点名

---

## 七、常见误区

**误区一：以为并发一定更快。** 子任务太小（< 1 秒）时，调度开销占比过高，并发反而慢。

**误区二：并发度拉满。** API 限流是硬墙。从 5 开始试，找拐点。

**误区三：`return_exceptions=True` 之后不检查异常。** gather 会「成功」返回一堆 Exception 对象，你不 Check 就全当成功了。

**误区四：用 `as_completed` 却以为结果有序。** gather 保序，as_completed 按完成序，用途不同。

**误区五：超时不设。** 一个卡死的子任务能拖住整个 `gather`。

**误区六：聚合后不对账。** 少几个结果没人发现，报告永远「看起来完整」。**对账函数必须显式调用。**

**误区七：失败静默丢弃。** 最终输出必须点名哪些失败了，用户才有依据判断可信度。

---

## 小结

- 扇出扇入的标准形态是 **N 个同构无依赖任务 + 1 个聚合**。三个必要条件：无依赖、单任务耗时可观、需要汇总。
- 扇出用 **asyncio + Semaphore**，并发度从 5 开始实测（API 限流是硬墙），**限流时降并发、全成功时缓升**比固定并发更稳。
- 扇入的核心不是「拿到结果」，而是「**一个不少地拿到**」：**对账函数必须显式跑**，`return_exceptions=True` 之后必须检查异常。
- 聚合策略三种：拼接（同构）、归并（去重，多路检索后必做）、归纳（模型参与，且要把失败情况告诉它）。
- 扇入策略选**部分成功 + 点名失败**（更常用），只有结果必须互相一致时才用全有或全无。
- 三个必须：**必须设超时（否则卡死一个拖住全部）、必须区分可重试/不可重试错误、必须在最终输出里点名失败项**。

并发的收益上限取决于 API 侧，但**扇入的正确性完全取决于你自己**。前者省几分钟，后者决定报告可不可信。
