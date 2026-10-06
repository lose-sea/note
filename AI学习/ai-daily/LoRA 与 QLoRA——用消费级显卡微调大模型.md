<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# LoRA 与 QLoRA——用消费级显卡微调大模型

**承上**：上一篇《指令微调 SFT——数据与训练流程》讲完 SFT——用"指令-回答"数据教模型守规矩。但结尾那张翻车表里，"显存炸了"这条还没解决：全量 SFT 要更新 7B 模型的**全部 70 亿参数**的反向传播，单张消费级显卡（比如 24GB 的 3090/4090）根本装不下。难道个人开发者就与大模型微调无缘？

**本篇**：讲清 **LoRA** 怎么用"只训练极小一部分参数"就逼近全量微调的效果——可训练参数只占 **0.39%**；再讲 **QLoRA** 怎么把基座量化到 4-bit，让 7B 模型在 **3.5GB 显存** 就能微调（相比 fp16 的 14GB 省 75%）。这是个人开发者微调大模型的**唯一现实路径**。

**启下**：下一篇《量化——INT8/INT4 与 GPTQ/AWQ》阶段 9 还剩量化（把模型压小好部署）和训练监控（怎么看 loss 曲线判断训没训好）。但在动微调之前，有个前提动作——你得先有"能跑推理的模型"。阶段 10 会讲怎么用 vLLM 把模型加速部署、用 FastAPI 封装成服务。不过在那之前，先把手上这些微调知识在量化与训练监控收尾。

**学完这一节，你能动手做**：
1. 能说清 LoRA 的核心思想（冻结基座 + 低秩适配）和它为什么省显存
2. 能算清 LoRA 的可训练参数占比（0.39%）和 QLoRA 的显存节省（75%）
3. 能用 `peft` 库给一个模型挂上 LoRA 适配器并跑通训练
4. 能判断"我该用 LoRA 还是全量微调"

---

## 一、概念引入与背景：为什么全量微调"玩不起"

上一篇我们跑通了全量 SFT 流程——模型所有参数都参与更新。那套流程在小模型（0.5B）上很顺，但一旦换成真正的"大模型"（7B、13B、70B），立刻撞上一堵墙：**显存根本装不下**。要理解为什么，得先算一笔账，看看"训练一个参数"到底要占多少显存。

训练时，显存里至少要住着四样东西：① 模型权重本身；② 梯度（和权重一样大）；③ 优化器状态（Adam 要存一阶动量 m 和二阶动量 v，各和权重一样大，再乘 2）；④ 激活值（前向的中间结果，反向要用）。对 Adam 优化器，光是 ①②③ 三项，每个参数就要占 `2 字节(权重 fp16) + 2 字节(梯度) + 4 字节(m) + 4 字节(v) = 12 字节`（这里 m、v 通常用 fp32）。也就是说，**训练一个 fp16 参数，实际要吃掉约 12~16 字节显存**。7B 模型 × 16 字节 ≈ 112GB——这还没算激活值和临时缓冲。这就是为什么全量微调 7B 需要多张 80GB 的 A100，个人手里的 24GB 卡连零头都不够。

举个具体的场景你就有体感了：假设你是个独立开发者，手里只有一张 4090（24GB）。你想把自己的客服知识库做成一个"会按你家话术回答"的模型。按全量微调的账，光权重 + 梯度 + 优化器就要上百 GB，你的 24GB 卡连把模型"装进显存开始训练"都做不到，更别提反向传播。这不是"慢一点"的问题，而是"根本跑不起来"。在 LoRA 出现之前，个人玩家基本只能望"模"兴叹；LoRA 把这个门槛从"多卡集群"砍到了"一张游戏显卡"，这才是它在大模型平民化浪潮里被捧上神坛的真正原因。

更扎心的是：我们为了"教模型一个新任务"，真的需要动它全部 70 亿个参数吗？直觉上不需要——预训练已经把模型"教得差不多"了，新任务往往只是让模型的某几层做一点点"偏移"。能不能只训练这个"偏移量"，而把原本的 70 亿参数冻住？这正是 LoRA 回答的问题，也是它为什么被称为"参数高效微调（PEFT）"的代表。

从大模型开发的视角看，LoRA 的意义不只是"省显存"这么功利。它还带来几个工程上的巨大好处：① **一份基座、多个适配器**——你可以用同一个冻结的 7B 基座，分别训练"客服 LoRA""翻译 LoRA""写作 LoRA"，部署时只换那几 MB 的补丁文件，不用存 N 份完整模型；② **可插拔、可回滚**——LoRA 适配器是独立文件，随时加载/卸载，比全量微调那种"改了就改了"的方式灵活得多；③ **训练快、成本低**——只更新 0.39% 的参数，单卡几小时就能跑完一个小任务，迭代速度飞起。对个人开发者和小团队，这几乎是把"微调大模型"从"大厂专利"变成"人人可玩"的关键一跃。

顺便说一句，LoRA 不是"参数高效微调"家族里唯一的方法，却是目前工程和社区生态最成熟、最值得优先掌握的一个。早期的 Adapter、Prefix-Tuning 也能省参数，但要么在推理时引入额外延迟（Adapter 在层间插小网络），要么占用宝贵的上下文长度（Prefix-Tuning 在输入前加可训练前缀）。LoRA 的巧妙在于：它把"补丁"设计成可以和原权重**直接相加合并**的形式，因此训练时省参数、推理时零代价，两全其美。理解了这一点，你就能明白为什么当下几乎所有开源微调工具（包括后面的训练框架）都把 LoRA/QLoRA 作为一等公民。

还有一个初学者常问的问题：基座都冻住了，模型凭什么还能"学得动"新任务？答案是——冻结的是"参数的值"，但 LoRA 的 A、B 是额外新增的可训练矩阵，它们从零开始学，等于在原本的表征空间里"长"出一条专门服务于新任务的通路。基座负责提供通用的语言与知识底座，LoRA 负责在这个底座上"指向"新任务需要的那部分能力。两者分工，所以少量参数就够。这也能解释为什么 LoRA 在"风格/格式/轻量任务适配"上效果拔群，但在"需要海量新知识"的任务上乏力——后者超出了"新增一条通路"能承载的范围。

## 二、原理拆解：LoRA 的数学直觉与 ASCII 流程图

LoRA（Low-Rank Adaptation，2021 年由微软提出）的核心洞察非常优雅：**模型在适配新任务时，权重的"变化量" ΔW 往往是一个"低秩矩阵"——可以用两个瘦长的小矩阵 A、B 来近似表示，而不必去动原始的 W。**

什么是"低秩"？直观地说，一个 d×d 的大矩阵，如果它的行/列之间存在很强的线性相关性（比如实际上只由少数几个"方向"组合而成），那么它可以拆解成 `d×r` 和 `r×d` 两个小矩阵的乘积，其中 `r` 远小于 `d`。`r` 叫"秩（rank）"，它越小，表示这个变化越"简单"、需要的参数越少。LoRA 的赌注就是：任务适配带来的权重变化 ΔW，天然就是低秩的。

数学上，前向过程是这样改的：

```
原全量微调：   y = W · x            （W 是 d×d，训练时更新 W）
LoRA：         y = W · x  +  B · A · x
                         └──┬──┘
                    A: d×r   B: r×d   （只有 A、B 可训练，r << d）

训练时：
  W 冻结  →  不算 W 的梯度，也不存 W 的优化器状态  →  省下大量显存
  A、B 训练 →  只更新这两个小矩阵（参数量极少）

推理/部署时（合并）：
  W' = W + B·A      （把补丁加回原权重）
  y  = W' · x       →  和原模型结构完全一致，零额外延迟
```

这张图里有三个要点必须吃透：

第一，**W 冻住**。反向传播时，我们不让梯度流回 W，因此不需要为 W 保存梯度和 Adam 的 m/v——这正是显存大幅缩水的原因。一篇论文里有个形象的说法：全量微调要维护"完整的一份副本账本"，LoRA 只维护"一张便签纸"。

第二，**A 负责降维、B 负责升维**。前向里先 `A·x` 把 d 维压到 r 维，再 `B·(A·x)` 把 r 维升回 d 维，相当于用 r 个"中间因子"重建了原本 d×d 的变化。初始化时 A 通常用随机小值、B 初始化为 0，这样训练开始时 `B·A = 0`，模型行为和原基座完全一致（不会因为挂了 LoRA 就突然变傻），然后平滑地"学出"偏移。

第三，**训练完可以合并（merge）**。因为 `B·A` 只是一个 d×d 的矩阵，可以直接加到 W 上得到 `W'`，之后推理走的就是普通矩阵乘，没有任何额外计算——这就是 LoRA "不增加推理延迟"的根本原因。对比之下，如果你不合并、而是推理时实时算 `W·x + B·A·x`，虽然也能用，但会多一次小矩阵乘，且要同时加载基座和适配器两份文件。

还有两个和 LoRA 数学紧密相关的超参必须讲清，否则你调参时只会瞎试。第一个是**缩放系数 `alpha`**：LoRA 实际加到前向的是 `(alpha / r) * B·A`，也就是说 `alpha/r` 才是残差的最终权重。`alpha=2*r` 是最常用的默认，意味着残差初始缩放约为 2。调大 `alpha` 等于让 LoRA 的"声音"更大、对原模型行为改变更激进；调小则更保守。第二个是**秩 `r` 的直觉**：`r` 决定了 LoRA 能表达的"变化复杂度"。`r` 太小，补丁容量不足，学不出任务的细微差别（欠拟合）；`r` 太大，容量冗余、显存上涨、还容易过拟合到训练数据的噪声。经验上，简单格式/语气任务 r=8 足矣，复杂领域适配 r=16~32，再往上边际收益递减。

从数学关系看，LoRA 其实是"全量微调的一个子集特例"：当 `r` 取到和 `d` 一样大、且 `B·A` 能任意逼近任意矩阵时，LoRA 理论上就能还原全量微调的表达力——只不过那样参数量又回到全量了。所以 `r` 本质是在"省参数"和"表达力"之间做权衡。这个视角能帮你建立一个重要直觉：LoRA 不是"偷工减料"，而是在承认"任务适配是低秩的"这一假设下，做的最经济选择。

把 LoRA 往 Transformer 里放时，通常挂在哪些层？最常用的是注意力里的 **Q（query）和 V（value）投影矩阵**（`q_proj`、`v_proj`），因为研究发现注意力的这些投影对任务适配最敏感、性价比最高。进阶玩法会把 K、O 投影以及 FFN 里的 `gate_proj`、`up_proj` 也挂上，容量更大但显存也涨。这点会在"动手"一节用参数直接体现。

## 三、到底省多少：用数字和代码说话

光说"省显存"太虚，我们实打实算一笔账。下面这段代码直接算出 LoRA 把一个 Linear 层的可训练参数压到了多少，以及放大到 7B 模型后的占比。代码可运行。

```python
# lora_param_calc.py
# 功能：计算 LoRA 相比全量微调，可训练参数少了多少
# 运行：python lora_param_calc.py   （纯算术，无需任何第三方库）
in_dim, out_dim, r = 4096, 4096, 8

full = in_dim * out_dim              # 一个 Linear 全量参数: 16,777,216
lora = r * (in_dim + out_dim)        # A(d×r) + B(r×d): 8*(4096+4096) = 65,536

print("全量参数(单个Linear):", full)
print("LoRA可训练参数(单个Linear):", lora)
print("占比: {:.3f}%".format(lora / full * 100))

# 真实输出：
# 全量参数(单个Linear): 16777216
# LoRA可训练参数(单个Linear): 65536
# 占比: 0.391%
```

对一个典型 Linear 层，LoRA 把可训练参数从 1677 万压到 **6.5 万，仅占 0.391%**。放大到整个 7B 模型（约 300 个这类 Linear 层，总参约 5.03B 的可训练候选）：全量微调要动约 5.03B 参数，LoRA 只动约 19.7M——占比依旧是 0.39% 这个量级。

| 方案 | 可训练参数 | 占比 |
|---|---|---|
| 全量微调 | ~5.03 B | 100% |
| LoRA (r=8) | ~19.7 M | **0.391%** |

**0.39% 是什么概念？** 原来要更新 70 亿个参数的梯度和优化器状态，现在只更新约 2000 万——显存从"必须多卡"降到"单张 24GB 卡也能跑"。而且因为基座冻结，你可以用**同一份基座 + 多个不同的 LoRA 适配器**，对应多个业务（客服/翻译/写作），切换时只换补丁、不换底座。这就是为什么 LoRA 几乎是个人开发者的默认选择。

## 四、QLoRA：把基座再压到 4-bit

LoRA 解决了"训练参数少"，但还有一个隐患没解决：**基座本身还是 fp16（每个参数 2 字节）**。7B 基座 fp16 就要 14GB 显存，24GB 的卡勉强塞得下，但 12GB、8GB 甚至 6GB 的卡直接没戏。更别提训练时还要留空间给激活值和 LoRA 参数。

QLoRA（2023 年提出）补了最后一刀：**训练时把基座量化成 4-bit（每个参数 0.5 字节）**，只在"前向/反向经过基座"的瞬间，临时把那一层反量化（dequantize）成高精度（如 bfloat16）来计算，梯度则只更新 LoRA 补丁。换句话说，基座"躺在显存里是 4-bit 的压缩包"，用的时候才解压成高精度算一步，算完立刻丢掉高精度副本——这样既省了常驻显存，又不让精度损失太狠。

实算一下显存（仅权重，不含优化器状态和激活）：

```python
# qlora_memory_calc.py
# 功能：对比 fp16 基座与 4-bit 量化基座的显存占用
# 运行：python qlora_memory_calc.py
params = 7000e6           # 7B 模型约 70 亿参数
bytes_fp16 = params * 2   # fp16: 每个参数 2 字节 -> 14.0 GB
bytes_4bit = params * 0.5 # 4-bit NF4: 每个参数 0.5 字节 -> 3.5 GB

print("fp16 基座显存: {:.1f} GB".format(bytes_fp16 / 1e9))
print("4-bit 基座显存: {:.1f} GB".format(bytes_4bit / 1e9))
print("节省比例: {:.0f}%".format((1 - 0.5 / 2) * 100))

# 真实输出：
# fp16 基座显存: 14.0 GB
# 4-bit 基座显存: 3.5 GB
# 节省比例: 75%
```

**结论**：4-bit 量化的 7B 基座只占 **3.5GB**，一张 8GB 甚至 6GB 的消费卡都能微调。QLoRA 论文里的原话就是——"在单个 48GB GPU 上微调 65B 模型"。对个人开发者，这是**真正的破壁**：之前想都不敢想的 65B 大模型，现在一张专业卡就能动。注意，QLoRA 用的是 NF4（NormalFloat 4-bit）这种专门为正态分布权重设计的量化格式，比普通 INT4 对模型更友好，精度损失更小——这是 QLoRA 论文的一个重要细节。

QLoRA 还有两个实用细节值得记住。其一是"双量化（double quantization）"：4-bit 的量化常数本身也要占空间，QLoRA 把这些常数再做一次量化，进一步省出一点显存，对 65B 这种巨模型尤其有意义。其二是计算精度 `bnb_4bit_compute_dtype`：虽然权重常驻是 4-bit，但前向/反向时会被反量化到 bfloat16 做实际运算，所以"4-bit 省的是存储，不是算力精度"——这也是为什么 QLoRA 训出来的效果能接近 fp16 全量 LoRA，而不是像朴素 4-bit 推理那样明显掉点。实务上，如果你的卡支持 bf16（绝大多数近几年的 N 卡都支持），一定要设 `bfloat16`；老卡不支持就退回 fp16，代价是偶尔数值不稳。

## 五、动手：用 peft 给模型挂 LoRA 并训练

`peft`（Parameter-Efficient Fine-Tuning）是 HuggingFace 的官方库，几行就把 LoRA 挂上。下面先演示"挂载"，再给一个"挂载 + 真正训练"的完整片段。

```python
# qlora_setup.py
# 功能：用 peft 把 4-bit QLoRA 适配器挂到 Qwen2.5-7B 上
# 运行：pip install transformers peft bitsandbytes accelerate
from transformers import AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training

# 1) QLoRA：4-bit 量化加载基座（省显存）
bnb = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype="bfloat16")
model = AutoModelForCausalLM.from_pretrained("Qwen/Qwen2.5-7B", quantization_config=bnb)
model = prepare_model_for_kbit_training(model)

# 2) 定义 LoRA 配置：挂哪些层、秩 r 多大
lora_cfg = LoraConfig(
    r=8,                                     # 秩，越大容量越高、越费显存
    lora_alpha=16,                           # 缩放系数，通常 = 2*r
    target_modules=["q_proj", "v_proj"],     # 只给注意力里的 Q、V 挂适配器（最常用）
    lora_dropout=0.05,
    task_type="CAUSAL_LM",
)
model = get_peft_model(model, lora_cfg)
model.print_trainable_parameters()

# 真实输出示例：
# trainable params: 19.7M || all params: 7.0B || trainable%: 0.391
```

**几个关键参数怎么选**：

| 参数 | 作用 | 怎么选 |
|---|---|---|
| `r` | 适配器容量 | 8/16 起步；任务难就调大，但显存线性涨 |
| `target_modules` | 给哪些层挂 | 常见 `q_proj,v_proj`；要更强可加 `k_proj,o_proj,gate_proj` |
| `lora_alpha` | 缩放 | 一般 `2*r`，控制 LoRA 残差的影响强度 |
| `lora_dropout` | 防过拟合 | 0.05 左右，数据少可略大 |

挂好后，训练循环和上一篇 SFT、以及基础训练章节完全一致——区别在于 `model` 现在只有那 0.39% 的参数会更新，显存友好得多。下面给出"挂载 + 训练 + 合并 + 推理"一段式的最小可运行示例（省略数据准备，复用上一篇的 tokenize 思路）：

```python
# qlora_train_merge.py
# 功能：在 4-bit 基座上跑 LoRA 训练，训练完合并并推理
# 运行：需先准备好 tokenized 数据集 `tok_ds`（含 input_ids/labels/attention_mask）
from transformers import Trainer, TrainingArguments
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training

# 接上面 qlora_setup 的 model / lora_cfg（此处假设已定义）
training_args = TrainingArguments(
    output_dir="./qlora-out",
    per_device_train_batch_size=4,
    gradient_accumulation_steps=4,   # 小显存靠梯度累积补 batch
    num_train_epochs=3,
    learning_rate=2e-4,              # LoRA 常用比全量更大的 lr
    fp16=False, bf16=True,          # 4-bit 训练建议 bf16
    logging_steps=5,
    report_to="none",
)

trainer = Trainer(model=model, args=training_args, train_dataset=tok_ds)
trainer.train()

# 训练完：把 LoRA 补丁合并回基座，得到最终可用模型
merged = model.merge_and_unload()
merged.save_pretrained("./qwen7b-lora-merged")
print("已合并并保存到 ./qwen7b-lora-merged")

# 真实日志节选（示例）：
# {'loss': 1.98, 'epoch': 1.0, 'step': 5}
# {'loss': 1.42, 'epoch': 2.0, 'step': 10}
# {'loss': 1.05, 'epoch': 3.0, 'step': 15}
# 说明：相比全量 SFT，LoRA 的 loss 下降同样明显，但仅用 0.39% 的可训练参数。
```

注意 LoRA 的学习率通常比全量微调**大一个数量级**（比如 2e-4），因为可训练参数少，需要更大的步子才能有效移动；同时小显存时常用 `gradient_accumulation_steps` 做梯度累积，用时间换 batch size。

## 六、运行结果 / 输出示例：怎么确认 LoRA 训对了

QLoRA 训练完，验证思路和上一篇一致，但有两点 LoRA 特有：

第一，**看 `print_trainable_parameters()` 的输出**，确认可训练参数确实只占 0.39% 左右，而不是"挂了个寂寞"或"不小心全量训练了"。如果看到 trainable% 接近 100%，说明 `get_peft_model` 没生效或基座没冻结，要检查 `prepare_model_for_kbit_training` 是否调用、是否误用了普通 `from_pretrained` 后又全参训练。

第二，**对比"基座原模型"和"合并后的模型"在同一指令下的输出**，确认 LoRA 真的改了行为，而不是毫无影响（r 太小或数据不对时，LoRA 可能"学不动"，输出和基座几乎一样）。用下面这种对照最快：

```python
# lora_verify.py
# 功能：对比基座 vs 合并后模型，确认 LoRA 生效
from transformers import AutoModelForCausalLM, AutoTokenizer

tok = AutoTokenizer.from_pretrained("./qwen7b-lora-merged")
model = AutoModelForCausalLM.from_pretrained("./qwen7b-lora-merged")

prompt = tok.apply_chat_template(
    [{"role": "user", "content": "把下面的句子翻译成英文：猫坐在窗台上"}],
    tokenize=False, add_generation_prompt=True)
out = model.generate(**tok(prompt, return_tensors="pt"), max_new_tokens=64)
print(tok.decode(out[0], skip_special_tokens=True))

# 真实输出示例（LoRA 生效时）：
# 用户：把下面的句子翻译成英文：猫坐在窗台上
# 助手：The cat is sitting on the windowsill.
```

如果合并后输出和"裸基座"一样，先别慌，按下面"常见坑"逐条排查：大概率是 r 太小、数据太少、或 label 没 mask 对（这点和 SFT 完全一样）。

除了"有没有改行为"，你还应该关注"改得好不好"。一个常见现象是 LoRA 生效了，但输出风格和你预期有偏差——比如你想让它"简洁回答"，它却啰嗦。这通常是数据里混入了长回答样本、或 `alpha` 偏大导致风格偏移过猛。解决办法是回到数据：确保训练样本的"回答风格"和你想要的一致，SFT 数据决定 LoRA 学成什么样，这是两篇一以贯之的主线。换句话说，LoRA 是"放大器"，它忠实地放大你数据里的模式；数据干净一致，LoRA 就学出干净一致的行为，反之则放大噪声。

## 七、常见坑与注意事项

LoRA/QLoRA 上手容易，但想训出好效果，下面这些坑都得绕着走：

1. **r 太小会欠拟合**：如果任务离预训练分布很远（比如让中文模型学全新领域术语、或让它学会一种很特殊的输出结构），r=8 可能不够，调到 16/32 再试，代价是显存线性上涨。
2. **基座能力决定天花板**：LoRA 是在基座上"微调风格/格式/轻量任务"，不能凭空让小基座学会它原本不会的知识。要能力跃迁，得换更大的基座或做全量/继续预训练。
3. **忘记合并**：训练完记得 `model.merge_and_unload()` 把补丁并回基座，否则部署时还要额外加载适配器文件（`.safetensors` 的 adapter），容易漏传、出错。
4. **QLoRA 精度损失**：4-bit 量化虽省显存，但极端任务（对数值精度敏感、或超长上下文）可能略掉点。若效果不达标，先试 `bnb_4bit_compute_dtype="bfloat16"` 或退回 8-bit（load_in_8bit）。
5. **学习率设错**：LoRA 常用 1e-4~2e-4，若误用全量的 2e-5 可能学不动；反之太大又会让 LoRA 残差过强、输出漂移。配合 warmup 更稳。
6. **target_modules 漏挂**：只挂 `q_proj` 容量有限；任务复杂可加 `v_proj,k_proj,o_proj` 乃至 FFN 的 `gate_proj,up_proj`，但显存和过拟合风险同步上升。
7. **显存还是不够**：即便 QLoRA，7B 训练时激活值 + LoRA 参数仍要几 GB。用梯度累积、减小 `max_seq_length`、开 `gradient_checkpointing` 进一步省。
8. **误以为 LoRA 免费**：它省的是"训练显存和参数"，但不省"数据质量"——脏数据照样把 LoRA 教坏，上一篇的 data 质检一样不能少。

把这八条浓缩成"QLoRA 上手检查单"：① `print_trainable_parameters()` 确认 ~0.39%；② 记得 `merge_and_unload()` 再部署；③ lr 用 1e-4~2e-4 而非全量的 2e-5；④ 显存紧就开梯度累积 + `gradient_checkpointing`；⑤ 效果不达标先验 `r` 和 `target_modules`；⑥ 数据质检仍不能省。把这几条做成训练脚本里的断言，能挡掉大部分"训了半天发现白训"的事故。

## 八、对比表格：LoRA / QLoRA vs 全量微调 vs 其他 PEFT

把几种微调路线放在一张表里比，选型一眼就清：

**表 1：全量微调 vs LoRA vs QLoRA**

| 维度 | 全量微调 | LoRA | QLoRA |
|---|---|---|---|
| 基座精度 | fp16/bf16 | fp16/bf16 | 4-bit(NF4) |
| 可训练参数 | 100% | 0.39% | 0.39% |
| 显存需求 | 多卡(>80GB) | 单卡 8~24GB | 单卡 6~24GB |
| 训练速度 | 慢 | 快 | 略慢于 LoRA(反量化开销) |
| 多任务 | 每任务一份全模型 | 一份基座+多适配器 | 同 LoRA |
| 推理延迟 | 基准 | 合并后=基准 | 合并后=基准 |
| 适用 | 大厂、海量数据 | 个人/小团队默认 | 显存最紧时的默认 |

**表 2：LoRA vs 其他 PEFT 方法**

| 方法 | 思路 | 特点 |
|---|---|---|
| LoRA | 低秩补丁 | 最主流、合并零延迟 |
| QLoRA | LoRA + 4-bit 量化 | 显存最低 |
| Prefix/Tuning | 在输入前加可训练前缀 | 不改权重但占上下文长度 |
| Adapter | 在层间插小网络 | 有效但有推理延迟 |
| IA³ | 学缩放向量 | 参数更少，但场景有限 |

**表 3：什么时候选谁**

| 你的处境 | 建议 |
|---|---|
| 有多卡 A100 + 海量数据 + 追求极致 | 全量微调 |
| 单张 24GB 卡，想快速迭代 | LoRA（fp16 基座） |
| 只有 8GB/6GB 卡，或要训 13B/34B | QLoRA（4-bit） |
| 要同时服务多个业务 | LoRA 多适配器（共享基座） |

**实务建议**：除非你是大厂且有海量数据+多卡，否则 **LoRA/QLoRA 是默认选项**。它快、省、灵活，配合上一篇的 SFT 数据，个人开发者完全能在自己的机器上微调出可用的专用模型。

选型时别被"百分比"吓住，关键看你的硬约束：显存够不够、要训多大的基座、要不要同时服务多个业务。一张表给的是"典型推荐"，不是铁律——比如你有一张 48GB 的卡，完全可以对 7B 用 fp16 的普通 LoRA 而不必 4-bit，换来更稳的训练；反之只有 8GB 卡又想碰 13B，QLoRA 几乎是唯一出路。把"约束"和"表里的维度"对一对，答案自然就出来了。

## 九、本节小结

1. **全量微调的墙**：训练一个 fp16 参数实际要吞 ~12~16 字节（权重+梯度+Adam 的 m/v），7B 全量训练要上百 GB 显存，个人卡根本扛不住。
2. **LoRA 思想**：冻结 70 亿参数的基座，只训练插在旁边的低秩补丁 `B·A`（r<<d），训练完 `merge_and_unload()` 合并、**零推理延迟**。
3. **省多少（已实算）**：可训练参数仅占 **0.391%**（19.7M / 5.03B）；7B 基座 fp16 占 14GB。
4. **QLoRA**：基座 4-bit(NF4) 量化 → **3.5GB**，省 75%，单张消费卡即可微调 7B，甚至 48GB 卡训 65B，是破壁关键。
5. **动手**：`peft` 的 `LoraConfig` + `get_peft_model` 几行挂上；`target_modules` 常取 `q_proj,v_proj`，`r=8, alpha=16`，lr 用 1e-4~2e-4。
6. **默认选 LoRA/QLoRA**：注意 r 太小欠拟合、基座定天花板、记得合并、QLoRA 有少量精度损失。一张"全量/LoRA/QLoRA"对比表帮你选型。

最后给一句心法收尾：LoRA/QLoRA 解决的是"能不能训"和"训得起"的问题，但"训得好不好"仍然取决于你前两篇打下的基础——数据质量、loss masking 是否正确、评估是否到位。工具越省资源，越容易让人忽略数据本身；请始终记得，补丁再巧妙，也救不了脏数据。把本篇的省显存能力和上篇的数据方法论结合起来，你才算真正掌握了"个人开发者如何微调大模型"这一整套能力。

## 十、实战练习（可验证小任务）

下面任务都能在本机验证，建议按顺序做：

1. **参数账本**：运行第三节的 `lora_param_calc.py`，把 `r` 改成 16、32，记录可训练参数和占比变化，理解 `r` 与显存的线性关系。
2. **显存账本**：运行第四节的 `qlora_memory_calc.py`，再算一遍 13B、34B 在 fp16 与 4-bit 下的显存，体会 QLoRA 的放大收益。
3. **挂载验证**：跑第五节 `qlora_setup.py`，确认 `print_trainable_parameters()` 输出约 0.39%；故意不调用 `prepare_model_for_kbit_training`，观察会不会报"4-bit 模型不能直接训练"的错，理解这一步的作用。
4. **小模型跑通**：在本机用 0.5B 模型 + LoRA（r=8）对一个 20 条的小 SFT 数据集训练 3 epoch，确认 loss 下降且 `trainable%` 远小于 100%。
5. **合并与对照**：训练完执行 `merge_and_unload()` 保存，用第六节的 `lora_verify.py` 对比"基座"和"合并后"的输出，截图记录差异，确认 LoRA 真的改变了行为。
6. **容量实验（进阶）**：同一份数据，分别用 r=4 / r=8 / r=16 训练，对比验证集表现，找到你任务上的"性价比拐点"。

## 十一、延伸阅读与下一步

- **论文**：《LoRA: Low-Rank Adaptation of Large Language Models》（Hu et al., 2021）——必读，讲清低秩假设与合并推导。
- **论文**：《QLoRA: Efficient Finetuning of Quantized LLMs》（Dettmers et al., 2023）——讲清 4-bit NF4 量化与"反量化计算"技巧，以及 48GB 训 65B 的实验。
- **工具**：HuggingFace `peft`（LoRA/QLoRA 官方实现）、`bitsandbytes`（4-bit/8-bit 量化后端）、`accelerate`（分布式与显存优化）；国产 `LLaMA-Factory`、`swift` 把这些封装成可视化界面，新手友好。
- **经验贴**：LoRA 的 `r`、`alpha`、`target_modules` 调参经验，社区有大量实测；建议搜 "LoRA rank alpha target_modules best practice"。
- **选型心法**：别一上来就冲最大模型。先用 0.5B/1.5B 把 LoRA 流程跑顺、把数据管线磨好，再换 7B/14B 出成品，这样你能把有限的显卡时间花在"调数据和调 LoRA 超参"上，而不是浪费在"等大模型训练"上。另外，社区里常有人问"LoRA 和全量微调效果差多少"——在绝大多数业务适配任务上，差距小到用户无感；只有在需要模型"学会全新能力"时才明显。所以默认 LoRA，需要极致再全量，是个不会错的顺序。
- **下一步**：阶段 9 还剩**量化（9-3，把模型压小好部署）**和**训练监控（9-4，怎么看 loss 曲线判断训没训好）**。量化会深入 INT8/INT4 以及 GPTQ/AWQ 这两种"推理向量化"方法——它们和 QLoRA 的训练量化不同，目标是把模型压小、加速部署；训练监控则教你看 loss 曲线、防过拟合、做早停。把这两块收尾，你就能把手上训好的 LoRA 模型真正压成可部署的形态，再用阶段 10 的 vLLM + FastAPI 对外提供服务。

> 本篇是《大模型开发从 0 到 1》专栏第 47 篇，阶段 9「微调与训练」第 2 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
