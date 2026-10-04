<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# LoRA 微调实战——用最低显存给大模型做领域适配

## 一、为什么不该直接全参微调

假设你想让一个 7B 模型学会用公司内部的客服话术回答。最直接的想法是全参微调（Full Fine-tuning）：把所有参数都训一遍。

算一下代价：

```
┌────────────────────────────────────────────────────────────────┐
│  7B 模型全参微调的显存账                                        │
├────────────────────────────────────────────────────────────────┤
│  模型权重 (fp16)          7B × 2 byte  = 14 GB                 │
│  梯度        (fp16)       7B × 2 byte  = 14 GB                 │
│  优化器状态  (AdamW fp32) 7B × 8 byte  = 56 GB                 │
│  ─────────────────────────────────────────────────            │
│  合计                                     ≈ 84 GB 起            │
│  再加激活值、临时张量 → 单卡 A100 80G 都吃紧                    │
└────────────────────────────────────────────────────────────────┘
```

而且还有个更现实的问题：**每换一个业务场景，你就要存一份 14GB 的完整模型副本。** 10 个场景就是 140GB 的存储，运维成本极高。

LoRA 的答案非常漂亮：**冻结全部原参数，只训练一小撮新增的低秩矩阵。**

```
┌────────────────────────────────────────────────────────────┐
│  全参微调 vs LoRA                                           │
├────────────────────────────────────────────────────────────┤
│  全参：W (d×k) 全部更新   →  可训练参数 100%                │
│  LoRA：W 冻结，旁路加 ΔW = B·A                              │
│        A (r×k)、B (d×r)，r 很小（如 8）                     │
│        →  可训练参数 通常 < 1%                              │
└────────────────────────────────────────────────────────────┘
```

## 二、LoRA 的原理：用两个小矩阵近似"权重变化量"

核心假设来自一句话：**微调时权重的变化量 ΔW 是低秩的。**

所以不去直接学 ΔW（d×k 太大），而是把它分解成两个小矩阵的乘积：

```
        原始前向：      h = Wx
        加上 LoRA 后：   h = Wx + (α/r) · B·A·x
                                        ↑      ↑
                                  缩放系数  两个低秩矩阵

其中：
  W : (d × k)  冻结，不更新
  A : (r × k)  高斯随机初始化，可训练
  B : (d × r)  零初始化，可训练      ← 保证训练开始时 ΔW = 0
  r : 秩，通常取 4 / 8 / 16 / 32
  α : 缩放超参，通常取 2r
```

结构画出来是这样：

```
    输入 x (k)
       │
       ├──────────────────────────┐
       │                          │
       ▼                          ▼
  ┌─────────┐               ┌──────────┐
  │ W (冻结) │               │ A (r×k)  │  随机初始化
  └────┬────┘               └────┬─────┘
       │                        │
       │                        ▼
       │                   ┌──────────┐
       │                   │ B (d×r)  │  零初始化
       │                   └────┬─────┘
       │                        │
       │                        ▼
       │                     × (α/r)
       └────────────┬───────────┘
                    ▼
              h = Wx + ΔWx   (d)
```

**两处关键初始化必须记住：**

- `B` 初始化为 **0**，所以训练开始时 `ΔW = B·A = 0`，模型行为与原始模型完全一致——**微调不会破坏原有能力**，这是 LoRA 稳定性的来源。
- `A` 用高斯随机初始化，保证一开始就有非零梯度可以更新 `B`（如果两个都是 0，梯度会永远为 0）。

**推理时合并**，这是 LoRA 最实用的特性：

```
W_merged = W + (α/r) · B·A
```

合并后前向计算量**与原模型完全相同**，零额外推理延迟。也就是说：训练时省显存，推理时还不掉速。

## 三、参数量对比：LoRA 到底省了多少

用一个具体例子算清楚。对 7B 模型里的一个 `q_proj` 层（`d = 4096, k = 4096`）：

```
全参微调该层：      4096 × 4096                = 16,777,216 参数

LoRA (r=8) 该层：  A: 8 × 4096 = 32,768
                  B: 4096 × 8 = 32,768
                  合计                         = 65,536 参数

比例： 65,536 / 16,777,216 = 0.39%   ← 约 1/256
```

整个 7B 模型的账：

| 项目 | 全参微调 | LoRA (r=8) |
|---|---|---|
| 可训练参数 | 7,000M (100%) | 约 8.4M (~0.12%) |
| 权重显存 (fp16) | 14 GB | 14 GB（冻结，可用 4bit 压到 4GB） |
| 梯度显存 | 14 GB | **≈ 0.02 GB** |
| 优化器状态 | 56 GB | **≈ 0.07 GB** |
| 训练总显存 | ≈ 84 GB+ | **≈ 16 GB**（配 4bit 量化约 10GB） |
| 单场景存储产物 | 14 GB | **≈ 17 MB** |
| 推理延迟增加 | — | **0**（可合并） |

**从 84GB 到 16GB，从 14GB 存储到 17MB 存储**——这就是 LoRA 能让单张消费级显卡（如 4090 24G）微调 7B 模型的原因。

## 四、代码实战（一）：用 peft 微调一个模型

```python
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model, TaskType, prepare_model_for_kbit_training
from transformers import BitsAndBytesConfig

MODEL_NAME = "Qwen/Qwen2.5-0.5B"   # 演示用小模型；换 7B 只需改这一行
device = "cuda" if torch.cuda.is_available() else "cpu"

# ---------- 1. 4bit 量化加载：把冻结的权重压到 1/4 显存 ----------
bnb = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",             # NF4 量化，比 fp4 更适配正态权重
    bnb_4bit_compute_dtype=torch.float16,
    bnb_4bit_use_double_quant=True,        # 二次量化，再省 ~0.4bit/参数
)
tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME, trust_remote_code=True)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token   # 很多模型没有 pad_token，必须补

model = AutoModelForCausalLM.from_pretrained(
    MODEL_NAME, quantization_config=bnb,
    device_map="auto", trust_remote_code=True,
)
# 关键一步：为 kbit 训练做准备（把 LayerNorm 转 fp32、打开输入梯度）
model = prepare_model_for_kbit_training(model)

# ---------- 2. 配置 LoRA ----------
lora_cfg = LoraConfig(
    task_type=TaskType.CAUSAL_LM,
    r=8,                          # 秩：8 起步，任务越复杂越大
    lora_alpha=16,                # 通常 = 2×r
    lora_dropout=0.05,
    bias="none",                  # 不训练 bias，省参数
    # 只挂在注意力投影层上，性价比最高，也是社区最优实践
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
)
model = get_peft_model(model, lora_cfg)

trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
total = sum(p.numel() for p in model.parameters())
print(f"可训练参数: {trainable:,} / 总参数: {total:,} = {trainable/total:.4%}")

# 打印实际被替换的层 —— 排查"LoRA 没挂上"最直接的手段
model.print_trainable_parameters()
```

典型输出：

```
可训练参数: 1,081,344 / 总参数: 495,032,576 = 0.2184%
trainable params: 1,081,344 || all params: 495,032,576 || trainable%: 0.2184
```

如果 `trainable%` 是 `0.0000%`，说明 `target_modules` 名字写错了（不同模型的层名可能是 `q_proj` / `query` / `c_attn`），要用 `print(model)` 看清真实层名。

## 五、代码实战（二）：完整训练循环 + 保存合并

```python
from torch.utils.data import Dataset, DataLoader

# ---------- 3. 构造指令数据（客服话术场景示例） ----------
SAMPLES = [
    {"instruction": "用户说物流太慢", "output": "非常抱歉给您带来不便，我已为您加急跟进物流，预计 24 小时内更新轨迹。"},
    {"instruction": "用户要退货",     "output": "好的，退货流程很简单：进入订单详情点击申请退货，我们会在 1 个工作日内审核。"},
    {"instruction": "用户问发票",     "output": "支持电子发票，您可在订单完成后于订单详情页自助开具，即时发送到邮箱。"},
    {"instruction": "用户投诉质量",   "output": "非常抱歉商品未达预期，请提供照片，我们优先为您安排补发或全额退款。"},
] * 40   # 演示用，真实场景需要几百到几千条

PROMPT = "### 用户：{instruction}\n### 客服：{output}"

class SFTDataset(Dataset):
    def __init__(self, samples, tok, max_len=256):
        self.items = []
        for s in samples:
            text = PROMPT.format(**s) + tok.eos_token
            enc = tok(text, truncation=True, max_length=max_len,
                      padding="max_length", return_tensors="pt")
            ids = enc["input_ids"].squeeze(0)
            mask = enc["attention_mask"].squeeze(0)
            labels = ids.clone()
            labels[mask == 0] = -100       # 只对真实 token 算损失，屏蔽 padding
            self.items.append({"input_ids": ids, "attention_mask": mask, "labels": labels})
    def __len__(self): return len(self.items)
    def __getitem__(self, i): return self.items[i]

ds = SFTDataset(SAMPLES, tokenizer)
loader = DataLoader(ds, batch_size=2, shuffle=True)

# ---------- 4. 训练 ----------
optimizer = torch.optim.AdamW(
    [p for p in model.parameters() if p.requires_grad], lr=2e-4
)
model.train()
for epoch in range(1, 4):
    total_loss = 0.0
    for batch in loader:
        batch = {k: v.to(device) for k, v in batch.items()}
        loss = model(**batch).loss
        loss.backward()
        optimizer.step()
        optimizer.zero_grad()
        total_loss += loss.item()
    print(f"epoch {epoch} | avg loss {total_loss/len(loader):.4f}")

# ---------- 5. 保存 LoRA 适配器（只有几十 MB） ----------
model.save_pretrained("./lora-customer-service")
tokenizer.save_pretrained("./lora-customer-service")
print("适配器已保存，体积约:", end=" ")
import os
print(f"{sum(os.path.getsize(os.path.join('./lora-customer-service', f)) for f in os.listdir('./lora-customer-service'))/1e6:.1f} MB")

# ---------- 6. 推理：动态挂载适配器 ----------
from peft import PeftModel
base = AutoModelForCausalLM.from_pretrained(MODEL_NAME, device_map="auto",
                                            torch_dtype=torch.float16)
peft_model = PeftModel.from_pretrained(base, "./lora-customer-service")
peft_model.eval()

prompt = PROMPT.format(instruction="用户要退货", output="")
inputs = tokenizer(prompt, return_tensors="pt").to(device)
with torch.no_grad():
    out = peft_model.generate(**inputs, max_new_tokens=60, do_sample=False,
                              repetition_penalty=1.1)
print(tokenizer.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True))

# ---------- 7. 合并权重，推理零开销 ----------
merged = peft_model.merge_and_unload()
merged.save_pretrained("./merged-model")
print("已合并为独立模型，推理时不再需要 peft 库")
```

输出示例：

```
epoch 1 | avg loss 2.1837
epoch 2 | avg loss 1.0246
epoch 3 | avg loss 0.6712
适配器已保存，体积约: 17.3 MB
好的，退货流程很简单：进入订单详情点击申请退货，我们会在 1 个工作日内审核。
```

## 六、超参对照表

| 超参 | 推荐值 | 调大 / 调小的效果 |
|---|---|---|
| `r`（秩） | 8 起步，简单风格模仿 4，复杂知识注入 32~64 | 大多任务 r=8/16 就够；r 越大参数越多、越易过拟合 |
| `lora_alpha` | 2×r（即 16） | 相当于 LoRA 的学习率放大系数；太大易震荡 |
| `lora_dropout` | 0.05~0.1 | 数据少时调大防过拟合 |
| 学习率 | 1e-4 ~ 3e-4（比全参高 10 倍左右） | LoRA 参数少，需要更大的 lr |
| `target_modules` | q/k/v/o_proj | 加上 mlp 层能提升上限，但参数翻倍 |
| batch size | 尽量大 + 梯度累积 | 大模型显存不够时用 `gradient_accumulation_steps` |
| epoch | 2~3 | 超过 5 轮几乎一定过拟合 |

## 七、几个常见的坑

**坑 1：忘了 `prepare_model_for_kbit_training`。**
用 4bit 加载后直接训练，LayerNorm 仍是低精度、输入梯度未开启，训练会不稳定甚至完全学不动。这一步不能省。

**坑 2：`labels` 里的 padding 没设成 -100。**
默认 `labels = input_ids` 会把补齐位也计入损失，模型会花大量精力去学"预测 pad 符号"，表现为 loss 降得很快但生成质量很差。

**坑 3：`target_modules` 名字写错导致没挂上。**
不同模型的注意力层名不同：LLaMA/Qwen 是 `q_proj`，GPT-2 是 `c_attn`，BERT 是 `query`。写完一定用 `print_trainable_parameters()` 确认 `trainable%` 不是 0。

**坑 4：把 LoRA 权重当完整模型加载。**
`AutoModelForCausalLM.from_pretrained("./lora-xxx")` 会报错或加载出随机模型。LoRA 产物是**适配器**，必须 `PeftModel.from_pretrained(基座, 适配器路径)`。

**坑 5：合并后再训练。**
`merge_and_unload()` 之后的模型已经不含 peft 结构，不能再按 LoRA 方式继续训练。要留一份未合并的适配器用于后续迭代。

**坑 6：学习率照抄全参微调的 2e-5。**
LoRA 参数量只有千分之一，用 2e-5 会慢到几乎没变化。LoRA 的学习率通常要高一个数量级（1e-4~3e-4）。

## 八、小结

LoRA 的全部智慧可以浓缩成三道算式：

```
前向： h = Wx + (α/r)·B·A·x        ← 冻结 W，只训 A、B
初始化：B = 0 → 起点与原模型完全一致 ← 不破坏原能力
合并： W' = W + (α/r)·B·A          ← 推理零额外开销
```

要带走的三点：

1. **LoRA 不是"近似"全参微调，而是在低秩约束下找到了更不容易过拟合的解**——参数量小反而常常效果更好；
2. **`r`、`alpha`、`target_modules`、学习率这四个超参决定成败**，其中 `target_modules` 出错的概率最高；
3. **适配器 + 基座**的分离设计，让"一个基座 + N 个业务适配器"成为低成本可运维的方案——这才是 LoRA 在生产环境真正的价值。

下一步建议：把上面的 `SAMPLES` 换成你业务里的几百条真实问答，把模型换成 7B，跑通一遍你就会发现，**在自己的显卡上微调一个大模型，其实只需要十几行配置**。
