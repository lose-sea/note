<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 指令微调 SFT——数据与训练流程

**承上**：阶段 8 我们把 Agent 玩明白了——它能调工具、有记忆、会协作。但有个底层事实一直没变：**Agent 跑在"通用大模型"上**。你靠 Prompt 临时告诉它"你是客服""用口语"，但它骨子里还是个通用模型，未必真懂你家的产品话术。阶段 5-6 讲过预训练（MLM/CLM）让模型"学会语言"，但没教它"听人话办事"。

**本篇**：讲清什么是**指令微调（SFT，Supervised Fine-Tuning）**——用"指令-回答"配对数据，把通用模型教成"会按你的格式和要求办事"的专用模型。重点是**数据长什么样、训练流程怎么走、以及为什么数据质量比数量重要一百倍**。这是你第一次真正"改造模型本身"，而不是只在 Prompt 里忽悠它。

**启下**：SFT 全量微调要更新模型**所有**参数，一张消费级显卡根本装不下 7B 模型的反向传播。下一篇 **9-2《LoRA / QLoRA——用消费级显卡微调大模型》** 讲怎么只训练"极小一部分参数"就达到接近全量微调的效果——这是个人开发者微调大模型的唯一现实路径。

**学完这一节，你能动手做**：

1. 说清预训练、SFT、RLHF 三者的分工（模型成长的三阶段）
2. 写出符合规范的 SFT 数据（Alpaca 格式与 ShareGPT 格式）
3. 讲清楚一次 SFT 训练的标准流程（数据→模板→loss mask→反向传播）
4. 列出 SFT 最常见的"翻车"原因（数据脏、格式乱、过拟合）

---

## 一、先定位：SFT 在模型成长链里的位置

一个能用的对话模型，通常经历三个阶段（阶段 5-6 提过预训练，这里补全）：

```
① 预训练 (Pre-training)   海量无标注文本，学"语言和知识"。对应 5-6 的 CLM。
        ↓
② 指令微调 (SFT)          用"指令→回答"数据，学"听懂人话、按格式答"。← 本篇
        ↓
③ 对齐 (RLHF/DPO)         用人类偏好，学"答得有用、安全、不胡说"。
```

**一句话区分**：预训练让模型"有知识"，SFT 让模型"守规矩、听指挥"，对齐让模型"讨人喜欢、不伤人"。

对绝大多数个人/小团队，**做到 SFT 这步就够用了**——RLHF 成本高、收益相对小，先把 SFT 玩透。

## 二、SFT 到底在"调"什么？一个关键认知

回到阶段 4-4 的训练循环：模型预测下一个 token，用交叉熵算 loss，反向传播更新**所有参数**。

SFT 用的**完全是同一套机制**，唯一区别在数据：

- 预训练数据：一大段连续的文本（"今天天气…"），模型学"接着写"；
- SFT 数据：**指令 + 回答**（"请翻译这句话：…→ 翻译结果"），模型学"给定指令，生成对应回答"。

所以 SFT 不是新算法，而是**用"任务化"的数据，把已经会的语言模型，重新对齐到"指令-回答"的分布上**。这也是为什么它能在相对少的数据（几百到几万条）上生效——模型底子（语言、知识）预训练时已经打好了。

## 三、SFT 数据长什么样？两种主流格式

### 格式 A：Alpaca（单轮，结构化）

```json
{
  "instruction": "把下面的句子翻译成英文",
  "input": "今天天气真好",
  "output": "The weather is really nice today."
}
```

`input` 是可选的（有些指令不需要额外输入）。这种格式清晰、好批量化。

### 格式 B：ShareGPT（多轮，对话式）

```json
[
  {"role": "system",    "content": "你是一个严谨的翻译助手"},
  {"role": "user",      "content": "把下面的句子翻译成英文：今天天气真好"},
  {"role": "assistant", "content": "The weather is really nice today."},
  {"role": "user",      "content": "再翻一句：我们去看电影吧"},
  {"role": "assistant", "content": "Let's go to the movies."}
]
```

多轮对话用这个。无论哪种，**质量远比数量重要**——1000 条干净、多样、格式正确的数据，胜过 10 万条脏数据。

## 四、训练流程：五步走（和 4-4 对照看）

```python
# 伪代码，展示 SFT 的标准流程（真实现用 transformers + Trainer / peft）
from transformers import AutoModelForCausalLM, AutoTokenizer

tokenizer = AutoTokenizer.from_pretrained("Qwen/Qwen2.5-0.5B")
model     = AutoModelForCausalLM.from_pretrained("Qwen/Qwen2.5-0.5B")

def build_sft_example(sample):
    # 1) 把指令/回答拼成对话模板（不同模型模板不同）
    text = (f"<|im_start|>user\n{sample['instruction']}<|im_end|>\n"
            f"<|im_start|>assistant\n{sample['output']}<|im_end|>")
    ids = tokenizer(text, return_tensors="pt").input_ids[0]
    labels = ids.clone()
    # 2) 关键：把"指令部分"的 loss mask 掉（设 -100），只算"回答部分"的 loss
    instr_len = len(tokenizer(sample['instruction']).input_ids)
    labels[:instr_len] = -100
    return ids, labels

# 3) 构造 dataset（每条 = input_ids + labels）
# 4) 训练：model.train()，标准反向传播（见 4-4）
# 5) 保存：model.save_pretrained("./my-sft-model")
```

**最关键的一行是 `labels[:instr_len] = -100`**——这和阶段 5-6 讲的 **loss masking** 完全一致：我们**只让模型为"它该生成的回答"负责，不为"用户给的指令"负责**。否则模型会学着去"预测用户的提问"，那就南辕北辙了。

## 五、SFT 最常见的翻车原因

| 翻车现象 | 根因 | 对策 |
|---|---|---|
| 训完变成"复读机" | 数据太单一/重复 | 增加多样性，覆盖多种问法 |
| 格式乱套（输出不带指定结构） | 训练数据格式不统一 | 全量数据统一模板，清洗 |
| 遗忘旧能力（catastrophic forgetting） | 训练步数太多/学习率太大 | 减小 lr、早停、混合部分预训练数据 |
| 过拟合（训练 loss 很低但实测很烂） | 数据少 + epoch 多 | 减少 epoch、加验证集、早停 |
| 显存炸了 | 全量微调 7B 太大 | 见下篇 9-2，上 LoRA/QLoRA |

## 六、一个常被问的问题：SFT 和 RAG 怎么选？

| 需求 | 选 SFT | 选 RAG |
|---|---|---|
| 让模型"学会一种固定话术/格式" | ✅ | ❌ |
| 让模型"记住并实时引用最新私有文档" | ❌（知识会过时） | ✅ |
| 小样本、要改模型行为 | ✅（改参数） | ⚠️（只能靠 Prompt 约束） |
| 知识频繁更新 | ❌（要重训） | ✅（只更新向量库） |

**实务里常常两者结合**：SFT 把模型调成"懂业务话术的基模"，RAG 在推理时喂最新资料。先用 RAG 验证需求，真要固化行为再上 SFT。

## 七、本篇小结

1. **模型成长三阶段**：预训练（有知识）→ SFT（听指挥）→ 对齐（讨人喜欢）。个人/小团队做到 SFT 通常就够。
2. **SFT 不是新算法**，是"用指令-回答数据跑阶段 4-4 那套训练"——底子（语言/知识）预训练已打好，所以少量数据就生效。
3. **数据两种格式**：Alpaca（单轮结构化）、ShareGPT（多轮对话）。**质量 >> 数量**。
4. **loss masking 是灵魂**：只算"回答部分"的 loss（labels 指令段设 -100），和 5-6 一致。
5. 五大翻车原因各有对策；显存炸了 → 下篇 LoRA/QLoRA 解决。

> 本篇是《大模型开发从 0 到 1》专栏第 46 篇，阶段 9「微调与训练」第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
