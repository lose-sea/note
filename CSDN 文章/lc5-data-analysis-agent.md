# 数据分析 Agent：让模型跑代码，而不是猜答案

"上季度哪个区域增长最快？"这份数据 340MB，塞不进上下文；就算塞得进，让模型心算增速排名也是灾难。数据分析 Agent 的标准解法和图表 Agent 一脉相承：**模型负责理解意图、写代码、解读结果；Python 解释器负责精确执行**。这篇文章讲这套"NL2Code"范式的完整工程实现——从沙箱执行到结果解读，从数据安全到测试方法。

## 为什么必须是"生成代码"模式

先排除两个不靠谱的替代方案：

**让模型直接算**：把 CSV 塞进上下文让模型回答。数据量一大（几十万行）上下文就爆；更致命的是模型的数字计算不可靠——它是在"预测下一个 token"，不是在做算术。数字敏感的活交给解释器。

**让模型调封装好的分析 API**（内置 ten 种统计函数）：意图稍微复杂点（"按月环比且剔除异常值后再分组对比"）API 就不够用，最后还是回到写代码。

所以生产级方案几乎一边倒：**模型生成 Python/pandas 代码 → 沙箱执行 → 模型解读输出**。这个模式把"不可验证的概率推理"转化成"可验证的确定计算"，唯一的代价是沙箱工程。

## 整体架构

```
用户问题
  → ① 意图解析 + 数据 schema 匹配（模型）
  → ② 生成 pandas 代码（模型）
  → ③ 沙箱执行（Docker/本地 subprocess 隔离）
  → ④ 结果回填：stdout / 图表 / DataFrame 摘要
  → ⑤ 模型解读结果 → 自然语言答案（模型）
  → ⑥（可选）用户追问迭代
```

拆开看每一步的工程要点。

### ① Schema 注入：别让模型猜列名

第一课就把数据的结构告诉模型。数据加载后生成一份结构画像：

```python
def profile_df(df: pd.DataFrame) -> str:
    lines = [f"共 {len(df)} 行 × {len(df.columns)} 列"]
    for col in df.columns:
        dtype = str(df[col].dtype)
        uniq = df[col].nunique()
        sample = df[col].dropna().unique()[:5]
        # 数值列加范围，类别列加 top 值
        if pd.api.types.is_numeric_dtype(df[col]):
            lines.append(f"- {col}（{dtype}，连续）范围 [{df[col].min():.2f}, {df[col].max():.2f}]")
        else:
            lines.append(f"- {col}（{dtype}，{uniq} 个取值）样例: {list(sample)}")
    return "\n".join(lines)
```

把这份画像放进系统提示词。没有它，模型会臆造列名（`df['销售额']` vs 实际 `df['sales']`），代码必崩。**schema 注入是代码生成成功率的最大单一因子**。

### ② 代码生成：约束模型写出能跑的代码

提示词工程的几个硬规则：

```python
CODE_PROMPT = """你是数据分析助手。可用数据（已加载为变量 df）：
{schema}

规则：
1. 只用 df 和 pandas/numpy/python 标准库，禁止 import 其他任何包（无 sklearn、无 requests、无 os）。
2. 禁止访问网络和文件系统，不要读写任何文件。
3. 最终结果必须用 print() 输出。要输出数值结果，不要只输出解释性文字。
4. 禁用 df.to_string() 输出全表，只输出聚合后的结果。
5. 代码包在 ```python ... ``` 中。

问题：{question}"""
```

注意第 1、2 条不只是风格建议——**它就是沙箱白名单的镜像**。模型能用的库必须和沙箱允许安装的库一一对应，否则生成一堆跑不了的代码。生产环境这个列表通常收紧到 `pandas, numpy, datetime, json, statistics, math`——违反直觉的是，给模型越多的库，它引入不可执行代码的概率越高。

### ③ 沙箱执行：安全是设计前提

让模型生成的代码在服务器上裸跑等于把 shell 交出去——`os.system("rm -rf /")`、读 `/etc/passwd`、往外网发数据，一次注入全齐。隔离方案按成本排序：

```python
# 方案一：subprocess + 资源限制（轻隔离，内部可信场景）
import subprocess, resource, os

def run_code_sandboxed(code: str, timeout: int = 30) -> dict:
    # 预置环境：df 已 pickle 到磁盘，脚本只做读取
    script = f"""
import pandas as pd
df = pd.read_pickle('/safe/data/df.pkl')
{code}
"""
    def limit():
        resource.setrlimit(resource.RLIMIT_AS, (1 << 30, 1 << 30))  # 1G 内存
    proc = subprocess.run(
        ["python", "-I", "-c", script],   # -I 隔离环境变量
        capture_output=True, text=True,
        timeout=timeout,
        preexec_fn=limit,
        cwd="/safe/sandbox",
        env={"PATH": "/usr/bin"},          # 环境变量最小化
    )
    return {"stdout": proc.stdout[-4000:], "stderr": proc.stderr[-2000:],
            "rc": proc.returncode}
```

`python -I`（isolated mode）+ 资源限制 + cwd 隔离 + 空环境变量，四个组合起来挡住了大部分意外，但**这不是安全边界**——root 下 subprocess 隔离对蓄意绕过形同虚设。

生产必须上容器级隔离（Docker 或 gVisor/Firecracker 微虚拟机）：

```dockerfile
FROM python:3.12-slim
RUN pip install pandas numpy
RUN useradd -m sandbox   # 非 root 运行
USER sandbox
# 只读挂载数据，无网络，内存 512M，CPU 配额
# docker run --rm --network=none --memory=512m --cpus=0.5 \
#            --read-only -v data:/data:ro sandbox python script.py
```

镜像里只有 numpy/pandas，没网（`--network=none`）、非 root、只读文件系统、资源封顶。**沙箱的第一性原则：假设代码是敌人写的**。每次执行起一个容器跑完即焚，成本一次几百毫秒，安全收益完全值回票价。云上也有现成的服务可选（Modal、E2B、 Daytona）。

### ④ 结果回填：给模型的输出要"够且不过量"

执行结果的三类去向：

- **stdout**：print 出来的数字、聚合表。回传给模型解读。
- **错误**：stderr + 非零退出码。这是迭代闭环的关键——模型改代码重试的依据。
- **图表**：代码里 savefig 出来的 PNG。和图表 Agent 一样走文件服务出 URL。

stdout 要截断（代码里 `df.to_string()` 一次吐十万行谁都不好看， prompt 里禁了，沙箱层也截），错误信息保留前 2000 字符（ traceback 通常前几行就够定位）。

### ⑤ 结果解读：防幻觉最后一道关

模型拿到执行结果后的解读，仍可能跑偏——数字看错、单位搞混、把季度末值当月均值讲。工程上的缓解：

- 提示词里明确要求"所有陈述必须引用执行输出中的具体数字"，不允许补充输出里没有的信息；
- 对数字类回答做**交叉验证**：让第二轮 prompt 把"问题、代码、输出、结论"都给它，问"结论中的每个数字是否都能在输出中找到？"——LLM 检查 LLM，能挡掉相当一部分低级错误；
- 界面设计上**数字高亮带链接**——每个关键数字 hover 显示对应的代码行和 stdout 行，用户能溯源，比让模型"说得准"更可靠。

## 迭代闭环与失败恢复

真实使用不是一问一答.Code 报错 → 修复这个闭环必须做进 Agent 循环：

```python
def analyze(question: str, df, llm, max_retries: int = 3):
    history = [{"role": "user", "content": build_prompt(question, profile_df(df))}]
    for i in range(max_retries):
        code = extract_code(llm.chat(history))
        result = run_in_sandbox(code)
        if result["rc"] == 0 and result["stdout"].strip():
            return interpret(question, code, result["stdout"], llm)
        # 报错回填，让模型续着修
        history.append({"role": "assistant", "content": code})
        history.append({"role": "user",
            "content": f"代码执行失败：\n{result['stderr']}\n请修正后输出完整新代码。"})
    return "分析失败，已自动重试 3 次。请尝试描述得更具体，或缩小数据范围。"
```

注意几个工程判断：**最多重试 3 次**——超过三次通常是问题描述不清或数据不支持，继续重试只会烧钱；**报错原样回填**，不要替模型"总结错误"，完整的 traceback 信息量才够；最终失败给可操作的建议，不是干巴巴的"出错了"。

## 更大场景：多轮分析与报告生成

单次分析之上，资深的数据 Agent 有两个进阶形态：

**多轮探查式分析**。用户说"看看有没有异常"，这不是一个可一次性代码化的问题。Agent 应该规划分析路径：先跑数据质量探查（缺失、分布、异常值）→ 定位候选异常 → 针对性深挖 → 出图验证。这是 Plan-and-Execute 模式在分析场景的落地——上一篇图表 Agent 是单步工具，这里是多步编排，规划能力（LangGraph  PlanningAgent）就是为这类任务设计的。

**报告生成**。分析结论 + 图表按模板组成 HTML/PDF 报告。报告的每个结论段引用对应的分析 task_id——**报告是可执行的**：用户点结论里的"环比 +23%"，能展开看那段代码、那段输出。这种可解释性是数据分析 Agent 和"ChatGPT 手动传文件"的本质分野。

## 测试策略

数据分析 Agent 的测试是个硬骨头，三层都要：

1. **沙箱安全性测试**（最重要）：用一组恶意代码（import os 执行、写文件、读环境变量、死循环耗 CPU、fork 炸弹）跑沙箱，断言全部被拦。这是每次改沙箱配置必跑的回归。
2. **代码生成正确性**：构造"问题 + 期望答案（精确数值）"数据集，跑端到端流程断言最终答案里的数字正确。期望答案用确定性脚本（不用模型）算好，避免循环依赖。
3. **解读质量**：LLM-as-judge 评测，判据聚焦"结论是否忠于输出数据"，套路和前面的评测框架一致。

## 结语

数据分析 Agent 的范式一句话：**让模型当大脑，解释器当计算器，沙箱当牢房**。Schema 注入决定代码生成质量，容器级沙箱决定安全底线，报错闭环决定成功率，可溯源设计决定可信度。这四件事做到了，模型就不再是"概率性的猜数手"，而是真正可靠的取数引擎。下一篇看同一范式在代码生成 Agent 里的应用。
