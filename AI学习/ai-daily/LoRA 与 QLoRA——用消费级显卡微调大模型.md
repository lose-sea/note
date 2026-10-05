<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# LoRA 与 QLoRA——用消费级显卡微调大模型

**承上**：9-1 讲完 SFT——用"指令-回答"数据教模型守规矩。但结尾那张翻车表里，"显存炸了"这条还没解决：全量 SFT 要更新 7B 模型的**全部 70 亿参数**的反向传播，单张消费级显卡（比如 24GB 的 3090/4090）根本装不下。难道个人开发者就与大模型微调无缘？

**本篇**：讲清 **LoRA** 怎么用"只训练极小一部分参数"就逼近全量微调的效果——可训练参数只占 **0.39%**；再讲 **QLoRA** 怎么把基座量化到 4-bit，让 7B 模型在 **3.5GB 显存** 就能微调（相比 fp16 的 14GB 省 75%）。这是个人开发者微调大模型的**唯一现实路径**。

**启下**：阶段 9 还剩量化（9-3，把模型压小好部署）和训练监控（9-4，怎么看 loss 曲线判断训没训好）。但在动微调之前，有个前提动作——你得先有"能跑推理的模型"。阶段 10 会讲怎么用 vLLM 把模型加速部署、用 FastAPI 封装成服务。不过在那之前，先把手上这些微调知识在 9-3/9-4 收尾。

**学完这一节，你能动手做**：

1. 说清 LoRA 的核心思想（冻结基座 + 低秩适配）和它为什么省显存
2. 算清 LoRA 的可训练参数占比（0.39%）和 QLoRA 的显存节省（75%）
3. 用 `peft` 库给一个模型挂上 LoRA 适配器并训练
4. 判断"我该用 LoRA 还是全量微调"

---

## 一、LoRA 的核心思想：别动基座，只学"补丁"

全量微调为什么贵？因为你要对 70 亿参数都算梯度、存优化器状态（Adam 还要存一阶/二阶动量，显存再 ×3）。

LoRA（Low-Rank Adaptation，2021 微软）的洞察很妙：

> **模型在适配新任务时，权重的"变化量"ΔW 其实是一个"低秩矩阵"——可以用两个瘦长的小矩阵 A、B 来近似表示，而不必动原始的 W。**

数学上：

```
原前向：  y = W · x          （W 是 d×d，冻结，不训练）
LoRA：    y = W · x + B · A · x   （A 是 d×r，B 是 r×d，只有 A、B 训练，r << d）
```

- `W`：**冻住**，反向传播不更新它（省了它的梯度 + 优化器状态）；
- `A`、`B`：**可训练**，但它们又瘦又小（r 通常取 8/16/32，远小于 d=4096）。

所以 LoRA 只往模型里"插"了一组极小的补丁矩阵，训练时**只更新这些补丁**。训练完，把 `B·A` 加到原 `W` 上（合并），推理时和原模型一模一样快——**LoRA 不增加任何推理延迟**。

## 二、到底省多少？用数字说话

我们实打实算一笔账（代码已跑过）：

```python
in_dim, out_dim, r = 4096, 4096, 8
full = in_dim * out_dim                 # 16,777,216  （一个 Linear 全量参数）
lora = r * (in_dim + out_dim)           # 65,536       （A + B 的可训练参数）
print(lora / full * 100)                # 0.391 %
```

**结论**：对一个典型 Linear 层，LoRA 把可训练参数从 1677 万压到 **6.5 万，仅占 0.391%**。

放大到整个 7B 模型（约 300 个这类 Linear 层）：

| 方案 | 可训练参数 | 占比 |
|---|---|---|
| 全量微调 | ~5.03 B | 100% |
| LoRA (r=8) | ~19.7 M | **0.391%** |

**0.39%** 是什么概念？原来要更新 70 亿个参数的梯度和优化器状态，现在只更新约 2000 万——显存从"必须多卡"降到"单张 24GB 卡也能跑"。而且因为基座冻结，你可以用**同一份基座 + 多个不同的 LoRA 适配器**，对应多个业务（客服/翻译/写作），切换时只换补丁、不换底座。

## 三、QLoRA：把基座再压到 4-bit

LoRA 解决了"训练参数少"，但基座本身还是 fp16（每个参数 2 字节），7B 基座就要 14GB 显存，24GB 卡勉强、更小卡直接没戏。

QLoRA（2023）补了最后一刀：**训练时把基座量化成 4-bit（每个参数 0.5 字节）**，只在"前向/反向经过基座"的瞬间临时反量化成高精度计算，梯度只更新 LoRA 补丁。

实算显存（仅权重，不含优化器状态）：

```python
bytes_fp16  = 7000e6 * 2      # 14.0 GB
bytes_4bit  = 7000e6 * 0.5    # 3.5 GB
print(1 - 0.5/2)              # 0.75  → 省 75%
```

**结论**：4-bit 量化的 7B 基座只占 **3.5GB**，一张 8GB 甚至 6GB 的消费卡都能微调。QLoRA 论文里的原话就是——"在单个 48GB GPU 上微调 65B 模型"。对个人开发者，这是**真正的破壁**。

## 四、动手：用 peft 给模型挂 LoRA

`peft`（Parameter-Efficient Fine-Tuning）是 HuggingFace 的官方库，几行就把 LoRA 挂上：

```python
from transformers import AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training

# 1) QLoRA：4-bit 量化加载基座（省显存）
bnb = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype="bfloat16")
model = AutoModelForCausalLM.from_pretrained("Qwen/Qwen2.5-7B", quantization_config=bnb)
model = prepare_model_for_kbit_training(model)

# 2) 定义 LoRA 配置：挂哪些层、秩 r 多大
lora_cfg = LoraConfig(
    r=8,                         # 秩，越大容量越高、越费显存
    lora_alpha=16,               # 缩放系数，通常 = 2*r
    target_modules=["q_proj","v_proj"],  # 只给注意力里的 Q、V 挂适配器（最常用）
    lora_dropout=0.05,
)
model = get_peft_model(model, lora_cfg)
model.print_trainable_parameters()
# 输出类似：trainable params: 19.7M || all params: 7.0B || trainable%: 0.391
```

**几个关键参数**：

| 参数 | 作用 | 怎么选 |
|---|---|---|
| `r` | 适配器容量 | 8/16 起步；任务难就调大，但显存线性涨 |
| `target_modules` | 给哪些层挂 | 常见 `q_proj,v_proj`；要更强可加 `k_proj,o_proj,gate_proj` |
| `lora_alpha` | 缩放 | 一般 `2*r` |

挂好后，训练循环和 9-1、4-4 完全一致——区别在于 `model` 现在只有那 0.39% 的参数会更新，显存友好得多。

## 五、LoRA vs 全量微调：什么时候选哪个？

| 维度 | 全量微调 | LoRA / QLoRA |
|---|---|---|
| 显存 | 多卡起步（>80GB） | 单张 8~24GB 消费卡 |
| 训练速度 | 慢（所有参数动） | 快（只动补丁） |
| 多任务 | 每任务存一份全模型 | 一份基座 + 多个小适配器 |
| 效果上限 | 略高（容量大） | 接近，绝大多任务无感差异 |
| 适用 | 大厂、数据极大、追求极致 | **个人/小团队/快速迭代（默认选它）** |

**实务建议**：除非你是大厂且有海量数据+多卡，否则 **LoRA/QLoRA 是默认选项**。它快、省、灵活，配合阶段 9-1 的 SFT 数据，个人开发者完全能在自己的机器上微调出可用的专用模型。

## 六、一个常见误区：LoRA 不是"免费午餐"

1. **r 太小会欠拟合**：如果任务离预训练分布很远（比如让中文模型学全新领域术语），r=8 可能不够，调到 16/32 试试。
2. **基座能力决定天花板**：LoRA 是在基座上"微调风格/格式"，不能凭空让小基座学会它原本不会的知识。要能力跃迁，得换更大的基座或做全量。
3. **合并后才是最终模型**：训练完记得 `model.merge_and_unload()` 把补丁并回基座，否则部署时还要额外加载适配器文件。

## 七、本篇小结

1. **LoRA 思想**：冻结 70 亿参数的基座，只训练插在旁边的低秩补丁 `B·A`（r<<d），**训练完合并、零推理延迟**。
2. **省多少（已实算）**：可训练参数仅占 **0.391%**（19.7M / 5.03B）；7B 基座 fp16 占 14GB。
3. **QLoRA**：基座 4-bit 量化 → **3.5GB**，省 75%，单张消费卡即可微调，是破壁关键。
4. **动手**：`peft` 的 `LoraConfig` + `get_peft_model` 几行挂上；`target_modules` 常取 `q_proj,v_proj`，`r=8, alpha=16`。
5. **默认选 LoRA/QLoRA**：除非大厂多卡+海量数据；注意 r 太小欠拟合、合并后才算最终模型。

> 本篇是《大模型开发从 0 到 1》专栏第 47 篇，阶段 9「微调与训练」第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
