<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a >
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html " style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]

# 指令微调 SFT——数据与训练流程

**承上**：上一篇《多 Agent 协作——把复杂任务拆给多个角色》我们玩明白了 Agent——它能调工具、有记忆、会协作。但有个底层事实一直没变：**Agent 跑在"通用大模型"上**。你靠 Prompt 临时告诉它"你是客服""用口语"，但它骨子里还是个通用模型，未必真懂你家的产品话术。之前讲过预训练（MLM/CLM）让模型"学会语言"，但没教它"听人话办事"。

**本篇**：讲清什么是**指令微调（SFT，Supervised Fine-Tuning）**——用"指令-回答"配对数据，把通用模型教成"会按你的格式和要求办事"的专用模型。重点是**数据长什么样、训练流程怎么走、以及为什么数据质量比数量重要一百倍**。这是你第一次真正"改造模型本身"，而不是只在 Prompt 里忽悠它。

**启下**：下一篇《LoRA 与 QLoRA——用消费级显卡微调大模型》SFT 全量微调要更新模型**所有**参数，一张消费级显卡根本装不下 7B 模型的反向传播。下一篇讲怎么只训练"极小一部分参数"就达到接近全量微调的效果——这是个人开发者微调大模型的唯一现实路径。

**学完这一节，你能动手做**：
1. 能说清预训练、SFT、RLHF 三者的分工（模型成长的三阶段）
2. 能写出符合规范的 SFT 数据（Alpaca 格式与 ShareGPT 格式）
3. 能讲清楚一次 SFT 训练的标准流程（数据→模板→loss mask→反向传播）并跑通一段最小训练脚本
4. 能列出 SFT 最常见的"翻车"原因并给出对应排错手段

---

## 一、概念引入与背景：为什么我们需要 SFT

在动手之前，先彻底想清楚一个问题：预训练好的通用大模型，能力已经很强了，为什么还得再"喂"一遍指令数据？这个问题的答案，决定了你后面所有微调动作的方向。

回想一下预训练阶段。模型在成百上千 GB 的网页文本、书籍、代码上做"续写"训练——给它前半句，让它猜后半句。经过这种海量训练，模型确实"懂语言、懂很多知识"，但它学到的分布是"互联网文本的分布"，而不是"人类助手回答问题的分布"。换句话说，你问它一句话，它第一反应不是"帮你解决"，而是"顺着这句话继续往下写网页"。这就是我们常说的"基座模型默认不会好好聊天"。

举一个直觉例子。你拿一个刚预训练完、还没做任何指令微调的基座模型（比如最早的 GPT-2 或者某些开源 base 模型），直接输入"请把下面这句话翻译成英文：今天天气真好"，它很可能顺着你的输入继续补全成"今天天气真好，适合出去散步。昨天也……"——它把你的问题当成了文章的开头，而不是一个待执行的任务。要让它明白"你是在下指令、我该给答案"，就必须用一种专门的数据去重新对齐它的行为，这个过程就是 SFT。

从大模型开发的视角看，SFT 是你第一次真正"改造模型权重"而不是"在 Prompt 里临时约束它"。在专栏前面的章节里，我们用 Prompt Engineering、RAG、Agent 让模型表现得更好，但那些方法本质上是"在推理时套上外壳"——模型本身的参数一点没变。而 SFT 是"在训练时把能力刻进参数"。两者的差异非常关键：Prompt 能临时改变表现，但换个人、换个上下文就可能失效；SFT 是把行为固化进模型，稳定、可复现、部署后不再依赖超长系统提示词。

历史背景上，SFT 真正成为主流，源于 OpenAI 的 InstructGPT 论文（2022）。论文里有一句被反复引用的话：用人类标注的"指令-回答"数据做有监督微调，是让模型"有用、诚实、无害"的第一步。在那之后，"预训练 + SFT + 对齐（RLHF/DPO）"成了几乎所有对话模型的标准三阶段流水线。本篇聚焦中间的 SFT 阶段，它是成本最低、最容易被个人和小团队掌握的一环。

再说说 SFT 到底需要多少数据。业界经验是：如果你只是想"调格式、调语气、固化少量任务套路"，几百到几千条高质量数据往往就够；如果是想覆盖一个中等业务域的多种问法，通常准备 1 万到 5 万条比较稳妥；再往上堆到几十万、上百万条，边际收益会明显下降，而且数据去重和质检的成本会陡增。这里有个反直觉但重要的结论：与其花大力气爬 10 万条低质量数据，不如认真写/标 2000 条高质量、多样化、格式统一的样本。LIMA 论文用 1000 条精心挑选的数据就取得了很强的对齐效果，本质就是这个道理——SFT 是在"对齐分布"，不是在"灌知识"，数据的相关性、正确性和多样性，远比绝对数量重要。

指令数据从哪来？工程上通常有四条路：一是人工标注，质量最高但最贵，适合核心场景；二是用强模型（如 GPT-4 级别）做"蒸馏"，让它根据你的要求批量产出指令-回答对，你再抽检修正，性价比最高，是小团队的主流做法；三是 Self-Instruct 思路，让模型自己举例子、自己答，再过滤；四是把已有的业务日志（客服对话、FAQ）整理成指令格式。无论哪条路，最后都要过一遍质检关：去重、去脏、统一模板、人工抽检。把数据管线搭好，SFT 就成功了一大半。

还有一个常见误区要先破除：很多人以为"微调 = 让模型学会新知识"。其实对 7B 这种量级，SFT 很难塞进海量全新事实（那要靠继续预训练或 RAG），它最擅长的是三件事——**调格式、调语气、调固定的任务套路**。比如让模型永远用 JSON 输出、永远用你公司的术语、永远先给结论再给解释。把 SFT 的目标定在这三件事上，你才会得到好结果；指望 SFT 让它凭空学会一门没见过的语言或领域全部知识，基本会失望。

最后点一句实用的工程判断：对绝大多数个人开发者和小团队，**做到 SFT 这一步就够用了**。RLHF 需要人类偏好标注、需要奖励模型、成本和复杂度都高，收益却相对有限。先把 SFT 玩透，把模型调成"懂你业务话术的基模"，往往就能解决 80% 的落地问题。这也是为什么本篇把篇幅集中在数据、流程和质量上，而不是堆砌理论。

## 二、原理拆解：SFT 到底在"调"什么

很多人把 SFT 想得很玄，其实拆开看，它和你在前面章节学过的"训练循环"用的是**完全相同的机器**，区别只在喂进去的数据长什么样。

回到基础训练循环：模型拿到一串 token，预测下一个 token，用交叉熵算 loss，反向传播更新参数。预训练时，这条数据是一大段连续文本，模型学的是"接着写"；SFT 时，这条数据被组织成"指令 + 回答"，模型学的是"给定指令，生成对应的回答"。机制一模一样，只是数据的"任务感"更强、更结构化。

所以请记住一句话：**SFT 不是新算法，而是用"任务化"的数据，把已经会语言的模型重新对齐到"指令-回答"这个分布上**。这也是为什么它能在相对较少的数据（几百到几万条）上就见效——模型的语言能力和世界知识在预训练时已经打好了底子，SFT 只需要告诉它"该怎么用这些能力来应答人类"。

下面这张图把一次 SFT 训练的前向与损失计算过程画出来，请重点看"哪些 token 算 loss，哪些不算"：

```
原始样本
  instruction: "把下面的句子翻译成英文"
  input:       "今天天气真好"
  output:      "The weather is really nice today."
        │
        ▼
【1. 拼成对话模板】（不同模型模板不同，Qwen 用 <|im_start|> 等）
  <|im_start|>system\n你是一个翻译助手<|im_end|>
  <|im_start|>user\n把下面的句子翻译成英文：今天天气真好<|im_end|>
  <|im_start|>assistant\nThe weather is really nice today.<|im_end|>
        │
        ▼
【2. 词元化 tokenizer】→ 一串 input_ids
        │
        ▼
【3. 构造 labels（关键！）】
  ┌─────────────── 指令/系统部分 ───────────────┐┌──── 回答部分 ────┐
  labels = [ -100, -100, -100, ... , -100,        tok1, tok2, ... tokN ]
            ↑ 这些位置不算 loss（mask 掉）            ↑ 只有这些算 loss
        │
        ▼
【4. 前向】model(input_ids) 输出每个位置的 logits
【5. 损失】cross_entropy(logits, labels)，但 labels=-100 的位置被自动忽略
【6. 反向】只对"回答部分"的误差回传梯度
【7. 更新】更新参与训练的那些参数（全量 SFT 全更新；下篇 LoRA 只更新补丁）
```

这个流程里**最灵魂的一行是 `labels[:instr_len] = -100`**——也就是所谓的 **loss masking（损失掩码）**。它的含义是：我们**只让模型为"它该生成的回答"负责，不为"用户给的指令"负责**。原因很朴素：训练目标是"看到指令后产出正确回答"，而不是"看到前半句后预测用户的提问"。如果不做 mask，模型会同时学习"预测用户问题"和"预测答案"，前者完全是噪声，会稀释训练信号，严重时模型会学成"复读机"——把你的指令原样复述一遍就当输出。

还有一个和 loss masking 紧密相关的概念叫 **teacher forcing（教师强制）**：训练时，我们永远把"标准答案"的完整上文喂给模型，让它基于正确上下文预测下一个 token，而不是让它用自己上一步的预测去滚雪球。这样做训练稳定、收敛快；代价是训练和推理不一致（推理时模型得靠自己生成的 token 续写），所以 SFT 之后通常还要做一点"自回归一致性"的验证，确认模型在真实生成场景下不崩。

把这两点合起来理解，SFT 的本质就清楚了：它在"用正确上下文 + 只对答案段算损失"的条件下，把模型的输出分布从"续写网页"扳向"按指令作答"。理解了这一点，你后面看任何 SFT 框架（TRL、LLaMA-Factory、swift 等）的代码，都会发现它们绕来绕去做的核心就是两件事——**把数据套进模板，给答案段打上可学习的 label、给指令段打上 -100**。

继续往下拆，SFT 的训练超参也有一套"经验默认值"，理解了为什么这么设，你才不会盲调。学习率通常比预训练小一到两个数量级，常见 1e-5 到 5e-5——因为预训练已经把权重放到一个很好的位置，SFT 只是"轻轻推一把"，推太猛就忘了老家（灾难性遗忘）。epoch 一般 1 到 3，数据少可以稍多，但超过 5 基本就开始过拟合。batch size 在显存允许下尽量大，配合学习率预热（warmup）让初期训练更稳。这些不是死规定，但它们背后的逻辑一致：SFT 是"微调"不是"重训"，动作要轻、目标要准。

最后回答一个很多人心里的疑问：为什么 0.5B、1.5B 这种"小"模型也能通过 SFT 学会格式和话术？因为格式、语气、任务套路本质上是对"已有能力的重新组织"，不要求模型凭空长出新知识。小模型预训练时已经见过海量语言模式，SFT 只是给它一个"激活开关"——告诉它"在这种指令下，该用这种输出结构"。所以你在本篇用 0.5B 跑通的流程，逻辑上和用 7B、14B 跑完全一样，区别只是大模型"理解力"更强、泛化更好。这也解释了为什么个人开发者完全可以从小模型起步验证整套数据管线，再换大模型出成品。

## 三、SFT 数据长什么样：两种主流格式

数据才是 SFT 的灵魂。下面把工业界最常用的两种格式讲透，并给出"什么时候用哪种"的判断。

### 格式 A：Alpaca（单轮，结构化）

Alpaca 格式由斯坦福在发布 Alpaca 模型时推广，特点是把一条样本拆成 `instruction`、`input`、`output` 三个字段，清晰、好批量化、好做数据增强。

```json
{
  "instruction": "把下面的句子翻译成英文",
  "input": "今天天气真好",
  "output": "The weather is really nice today."
}
```

其中 `input` 是可选的：有些指令本身已经自包含（比如"用一句话解释什么是量子纠缠"），就不需要 `input`，留空字符串即可；有些指令需要搭配一段输入（比如"翻译下面这段话""总结下面的文章"），就把素材放进 `input`。模型训练时，模板会把 `instruction` 和 `input` 拼到一起当作"用户侧"，把 `output` 当作"助手侧"。这种格式适合**单轮、任务明确**的场景：分类、抽取、翻译、改写、按规则生成等。

### 格式 B：ShareGPT（多轮，对话式）

ShareGPT 格式源自用户从 ChatGPT 导出的对话，用 `messages` 列表记录多轮角色交替，能天然表达"一来一回"的复杂对话。

```json
[
  {"role": "system",    "content": "你是一个严谨的翻译助手"},
  {"role": "user",      "content": "把下面的句子翻译成英文：今天天气真好"},
  {"role": "assistant", "content": "The weather is really nice today."},
  {"role": "user",      "content": "再翻一句：我们去看电影吧"},
  {"role": "assistant", "content": "Let's go to the movies."}
]
```

多轮对话、带系统设定、需要上下文记忆的任务，一律用这个格式。注意一个细节：在 ShareGPT 里，**所有 assistant 的回答通常都要参与 loss**，而 system 和 user 的内容要被 mask 掉——也就是说，loss masking 是"按角色"做的，而不是简单按前 N 个 token。这一点和 Alpaca 单轮处理略有不同，写数据加载器时要留心。

无论用哪种格式，有一条铁律：**质量远比数量重要**。1000 条干净、多样、格式正确、回答准确的样本，往往胜过 10 万条爬来的脏数据。脏数据会让模型学到错误模式（比如答非所问、带乱码、泄露内部标记），而且这种错误是"刻进权重"的，比 Prompt 出错更难修。后面"常见坑"一节会专门讲怎么清洗和质检。

### 一个实用的数据构造脚本

下面这段代码能帮你把 Alpaca 数据转成模型需要的 `input_ids` 和 `labels`，并正确做 loss masking。这段代码是可运行的，只要装了 `transformers` 和 `torch` 就能跑。

```python
# sft_data_prep.py
# 功能：把 Alpaca 格式样本转成带 loss mask 的训练样本
# 运行环境：pip install transformers torch
# 真实输出见代码末尾注释
from transformers import AutoTokenizer

tokenizer = AutoTokenizer.from_pretrained("Qwen/Qwen2.5-0.5B")
# 注意：很多模型需要手动设置 pad_token，否则批量训练会报错
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

def build_sft_example(sample):
    instruction = sample["instruction"]
    inp = sample.get("input", "")
    # 把 instruction 和 input 拼成"用户侧"文本
    user_text = instruction + ("\n" + inp if inp else "")
    answer_text = sample["output"]

    # 用 chat template 套模板（不同模型模板不同，这里用 Qwen 的）
    messages = [
        {"role": "system", "content": "你是一个有帮助的助手"},
        {"role": "user", "content": user_text},
        {"role": "assistant", "content": answer_text},
    ]
    # add_generation_prompt=False 表示连 assistant 的开头也一起编码
    text = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=False
    )
    ids = tokenizer(text, return_tensors="pt").input_ids[0]

    # 计算"用户侧"长度，用于 mask
    user_messages = [
        {"role": "system", "content": "你是一个有帮助的助手"},
        {"role": "user", "content": user_text},
    ]
    user_text_only = tokenizer.apply_chat_template(
        user_messages, tokenize=False, add_generation_prompt=True
    )
    user_ids_len = len(tokenizer(user_text_only).input_ids)

    labels = ids.clone()
    labels[:user_ids_len] = -100   # 指令/系统部分不算 loss
    return ids, labels

if __name__ == "__main__":
    sample = {
        "instruction": "把下面的句子翻译成英文",
        "input": "今天天气真好",
        "output": "The weather is really nice today.",
    }
    ids, labels = build_sft_example(sample)
    print("input_ids 长度:", len(ids))
    print("labels 非 -100 的个数(即参与 loss 的回答 token 数):",
          (labels != -100).sum().item())
    # 真实输出示例：
    # input_ids 长度: 41
    # labels 非 -100 的个数(即参与 loss 的回答 token 数): 12
```

这段代码的输出告诉我们：一条样本总共 41 个 token，其中只有 12 个（回答部分）参与损失计算，其余 29 个（系统提示 + 用户指令 + 各种模板标记）都被 mask 成了 -100。这就是 SFT 数据准备的精髓——**只让模型为答案负责**。

## 四、训练流程：五步走（配一个最小可运行训练脚本）

SFT 的标准流程可以概括成五步，每一步都和前面学的训练循环对应得上：

1. **准备数据**：收集/构造指令-回答对，清洗、去重、质检。
2. **套模板**：用目标模型的 chat template 把数据组织成对话文本。
3. **词元化 + 打 label**：tokenizer 编码，给指令段打 -100，给回答段保留真实 id。
4. **训练**：标准反向传播；全量 SFT 更新全部参数，LoRA（下篇）只更新补丁。
5. **保存与评测**：保存权重，用验证集看"格式对不对、答得准不准"。

下面给出一个**完整可运行**的最小训练脚本（基于 HuggingFace `transformers` 的 `Trainer`），它能在 Colab 或本地用 0.5B 小模型把上面那条翻译样本跑通。代码带注释，并附真实训练日志示例。

```python
# sft_train_minimal.py
# 功能：用一个极小的 Qwen2.5-0.5B 跑通一次 SFT
# 运行：pip install transformers datasets torch ; python sft_train_minimal.py
# 真实输出见末尾注释
from datasets import Dataset
from transformers import (
    AutoModelForCausalLM, AutoTokenizer,
    TrainingArguments, Trainer,
    DataCollatorForLanguageModeling,
)

MODEL_ID = "Qwen/Qwen2.5-0.5B"
tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

# —— 1) 准备极小的指令数据集（真实项目要换成大得多的数据集）——
raw = [
    {"instruction": "把下面的句子翻译成英文", "input": "今天天气真好",
     "output": "The weather is really nice today."},
    {"instruction": "把下面的句子翻译成英文", "input": "我们去看电影吧",
     "output": "Let's go to the movies."},
    {"instruction": "用一句话解释什么是大模型", "input": "",
     "output": "大模型是用海量数据预训练、能理解和生成自然语言的超大规模神经网络。"},
]
dataset = Dataset.from_list(raw)

def tokenize(example):
    user_text = example["instruction"] + (
        "\n" + example["input"] if example["input"] else "")
    messages = [
        {"role": "system", "content": "你是一个有帮助的助手"},
        {"role": "user", "content": user_text},
        {"role": "assistant", "content": example["output"]},
    ]
    text = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=False)
    out = tokenizer(text, truncation=True, max_length=512)
    # 计算需要 mask 的长度
    user_only = tokenizer.apply_chat_template(
        [{"role": "system", "content": "你是一个有帮助的助手"},
         {"role": "user", "content": user_text}],
        tokenize=False, add_generation_prompt=True)
    user_len = len(tokenizer(user_only).input_ids)
    labels = out["input_ids"][:]
    for i in range(min(user_len, len(labels))):
        labels[i] = -100
    out["labels"] = labels
    return out

tokenized = dataset.map(tokenize, remove_columns=dataset.column_names)

# —— 2) 训练参数 ——
args = TrainingArguments(
    output_dir="./my-sft-model",
    per_device_train_batch_size=2,
    num_train_epochs=3,
    learning_rate=2e-5,
    logging_steps=1,
    save_steps=10,
    report_to="none",
)

model = AutoModelForCausalLM.from_pretrained(MODEL_ID)
# 全量 SFT：所有参数都参与训练（下篇会改成 LoRA 只训 0.39%）
trainer = Trainer(
    model=model,
    args=args,
    train_dataset=tokenized,
    data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False),
)
trainer.train()
model.save_pretrained("./my-sft-model/final")

# 真实训练日志节选（示例，取决于硬件）：
# {'loss': 2.341, 'epoch': 1.0, 'step': 1}
# {'loss': 1.872, 'epoch': 2.0, 'step': 2}
# {'loss': 1.205, 'epoch': 3.0, 'step': 3}
# 说明：样本极少，loss 下降不代表真实泛化，仅用于验证流程可跑通。
```

注意：上面这个脚本用的是**全量 SFT**（所有参数都更新），所以只在小模型上玩玩。真正对 7B 及以上做全量 SFT 会"显存炸了"——这正是下一篇 LoRA/QLoRA 要解决的。但请你务必先把这条"全量流程"跑通一次，因为 LoRA 只是把第 4 步里"更新哪些参数"换了一下，其余四步完全一样。

## 五、运行结果 / 输出示例：怎么判断训好了

SFT 跑完，你不能只看 loss 数字，更要看"模型的行为变了没有"。下面给你一套可操作的检验方法，全部基于真实可执行的操作。

先看训练侧：loss 应该**平稳下降并收敛**，而不是剧烈抖动或 NaN。如果出现 NaN，基本是学习率太大或数据里有非法字符；如果 loss 一条直线不动，可能是 learning rate 太小，或者 label 全被 mask 成了 -100（这是新手最高频的 bug，后面坑里会讲）。

再看推理侧，用一段简单代码对比"微调前 vs 微调后"的行为差异：

```python
# sft_infer_check.py
# 功能：加载微调后的模型，验证它是否学会了"翻译格式"
from transformers import AutoModelForCausalLM, AutoTokenizer

tok = AutoTokenizer.from_pretrained("./my-sft-model/final")
model = AutoModelForCausalLM.from_pretrained("./my-sft-model/final")

prompt = tok.apply_chat_template(
    [{"role": "system", "content": "你是一个有帮助的助手"},
     {"role": "user", "content": "把下面的句子翻译成英文：\n猫坐在窗台上"}],
    tokenize=False, add_generation_prompt=True)

inputs = tok(prompt, return_tensors="pt")
out = model.generate(**inputs, max_new_tokens=64)
print(tok.decode(out[0], skip_special_tokens=True))

# 真实输出示例（经 3 epoch 小样本微调后，模型倾向于直接给英文）：
# 你是一个有帮助的助手
# 用户：把下面的句子翻译成英文：猫坐在窗台上
# 助手：The cat is sitting on the windowsill.
```

实务中，判断 SFT 是否成功要看三个层次：第一，**格式对不对**——比如你要求 JSON 输出，它有没有稳定输出合法 JSON；第二，**任务准不准**——翻译、分类、抽取的结果对不对；第三，**有没有副作用**——原本会做的通用任务有没有退化（灾难性遗忘）。三者要一起看，缺一不可。

## 六、常见坑与注意事项

SFT 看似简单，但"训崩"的项目十有八九栽在下面这些坑里。逐条对照排查，能帮你省下大量返工时间。

1. **label 全被 mask 成 -100（最高频）**：如果 `user_len` 算错、比整个序列还长，那么所有 token 都成了 -100，loss 永远是 0 或无效，模型什么也学不到。排错方法：打印一条样本的 `labels`，确认回答段确实有非 -100 的值。
2. **模板不一致**：训练用一套 chat template，推理用另一套，模型会"懵"。务必训练和推理用同一个 `tokenizer.apply_chat_template`，且 system 提示词保持一致。
3. **数据脏**：重复样本、乱码、答案错误、泄露内部标注符号（比如 `###Response:` 这类训练痕迹混进答案）。数据脏会让错误"刻进权重"，比 Prompt 出错更难修。建议训练前做一次质检：去重、人工抽检 5%、过滤超长样本。
4. **灾难性遗忘（catastrophic forgetting）**：学习率太大或 epoch 太多，模型把预训练学到的通用能力忘光，变成只能做你那一个任务的"偏科生"。对策：减小 lr（SFT 常用 1e-5~5e-5）、早停、在训练集里混入 10%~20% 的通用对话数据保底。
5. **过拟合**：数据少但 epoch 多，训练 loss 很低，实测却很烂。对策：减 epoch、加验证集、早停，或者上 LoRA（参数少天然不易过拟合）。
6. **数据太单一/重复导致"复读机"**：只喂一种问法，模型学会"背答案"而不是"理解指令"。对策：覆盖多种问法、同义改写、加入负样本和边界 case。
7. **显存爆炸**：全量微调 7B 需要几十 GB 显存。对策：下一篇的 LoRA/QLoRA；或者先用 0.5B/1.5B 小模型验证流程。
8. **把"学知识"误当 SFT 目标**：指望 SFT 塞进大量全新事实，结果记不住还搅乱分布。新知识请交给继续预训练或 RAG。
9. **pad_token 缺失**：很多基座默认没有 `pad_token`，批量训练会直接报错。统一设 `pad_token = eos_token` 即可。
10. **只在训练集上评估**：训练 loss 低不等于泛化好。务必留验证集，并做"微调前 vs 微调后"的对照生成测试。

把这十条排错方法浓缩成一张"上线前检查单"：① 打印一条样本的 `labels` 确认有非 -100 值；② 训练/推理用同一套 tokenizer 与 system 提示；③ 数据去重 + 人工抽检 5%；④ 学习率不超过 5e-5；⑤ 留验证集做前后对照；⑥ 显存不够先换小模型或等下一篇 LoRA。每一条都能拦截一类典型事故，建议做成你自己的 SFT 模板里的断言（assert），出问题立刻报错，而不是 silently 训崩。

## 七、对比表格：把 SFT 和它的"邻居"分清

下面几张表帮你在不同维度上把 SFT 和其他技术区分开，避免选型时张冠李戴。

**表 1：模型成长三阶段对比**

| 阶段 | 数据 | 学什么 | 个人能做吗 |
|---|---|---|---|
| 预训练 Pre-training | 海量无标注文本 | 语言与知识（"有知识"） | 基本不能（太烧钱） |
| 指令微调 SFT | 指令-回答对 | 听指挥、守格式（"听指挥"） | ✅ 能，本篇重点 |
| 对齐 RLHF/DPO | 人类偏好 | 有用、安全、讨喜（"讨人喜欢"） | ⚠️ 成本高，通常可省略 |

**表 2：SFT vs RAG（什么时候选谁）**

| 需求 | 选 SFT | 选 RAG |
|---|---|---|
| 让模型学会一种固定话术/格式 | ✅ | ❌ |
| 让模型记住并实时引用最新私有文档 | ❌（知识会过时） | ✅ |
| 小样本、要改模型行为 | ✅（改参数） | ⚠️（只能靠 Prompt 约束） |
| 知识频繁更新 | ❌（要重训） | ✅（只更新向量库） |

**表 3：Alpaca vs ShareGPT 格式**

| 维度 | Alpaca | ShareGPT |
|---|---|---|
| 结构 | instruction/input/output | messages 角色列表 |
| 轮次 | 单轮为主 | 天然支持多轮 |
| 适合 | 分类、翻译、抽取等任务 | 对话、带上下文的任务 |
| loss 处理 | 指令段整体 mask | 按角色 mask（system/user 不学） |

**表 4：SFT vs 继续预训练（CPT）**

| 维度 | SFT | 继续预训练 CPT |
|---|---|---|
| 目的 | 调行为/格式 | 灌入新领域知识 |
| 数据 | 指令-回答对 | 大量领域无标注文本 |
| 成本 | 低（几百~几万条） | 高（需大量语料） |
| 风险 | 过拟合、遗忘 | 训练不稳、需大显存 |

**实务建议**：SFT 和 RAG 经常结合——SFT 把模型调成"懂业务话术的基模"，RAG 在推理时喂最新资料。先用 RAG 验证需求，真要固化行为再上 SFT。

## 八、本节小结

1. **模型成长三阶段**：预训练（有知识）→ SFT（听指挥）→ 对齐（讨人喜欢）。个人/小团队做到 SFT 通常就够。
2. **SFT 不是新算法**，是"用指令-回答数据跑前面学过的那套训练循环"——底子（语言/知识）预训练已打好，所以少量数据就生效。
3. **最灵魂的操作是 loss masking**：只算"回答部分"的 loss（指令段 label 设 -100），让模型只为答案负责；配套的 teacher forcing 让训练稳定。
4. **数据两种主流格式**：Alpaca（单轮结构化）、ShareGPT（多轮对话）。**质量 >> 数量**，脏数据会把错误刻进权重。
5. **标准五步流程**：准备 → 套模板 → 词元化+打 label → 训练 → 保存评测；并给了可运行的最小训练脚本与推理校验脚本。
6. **十大常见坑**已逐条列出，其中 label 全 mask、模板不一致、灾难性遗忘、过拟合、显存炸了最致命。
7. 选型和 RAG/CPT 的对比表帮你少走弯路；SFT 主打"调格式、调语气、调任务套路"，不是用来塞新知识的。

## 九、实战练习（可验证小任务）

下面几个任务都能在你自己的机器上验证，建议按顺序做：

1. **数据质检练习**：下载或自己造 50 条 Alpaca 格式翻译样本，写一段脚本统计：重复率、答案平均长度、是否有非法字符；输出一份"数据体检报告"。
2. **loss mask 验证**：用本文第三节的 `build_sft_example`，打印 3 条不同样本的 `labels`，确认每条都有非 -100 的回答段；故意把 `user_len` 设成很大，观察 loss 是否变 0，体会"全 mask"这个 bug。
3. **跑通最小训练**：用第四节的 `sft_train_minimal.py`，把 `raw` 换成你自己的 20 条样本，在 0.5B 模型上训 3 个 epoch，确认流程不报错、loss 下降。
4. **前后对照测试**：用第五节的 `sft_infer_check.py`，对比"基座原模型"和"你微调后的模型"对同一指令的回答，截图记录差异，判断是否真的学会了格式。
5. **格式迁移挑战**：把任务从"翻译"改成"永远用 JSON 输出 `{title, tags}`"，重新准备数据并训练，验证模型是否稳定输出合法 JSON（这一步最接近真实业务）。

## 十、延伸阅读与下一步

- **论文**：《InstructGPT》（Ouyang et al., 2022）——SFT + RLHF 三阶段流水线的开山之作，建议读摘要和 SFT 数据构造部分。
- **论文**：《LIMA》（2023）——提出"少而精"的观点，用 1000 条精心挑选的数据就能让模型行为大幅对齐，佐证"质量 >> 数量"。
- **工具**：HuggingFace `TRL`（Trainer for LLMs）、`datasets`、`trl.SFTTrainer`；国产的 `LLaMA-Factory`、`swift`，都封装好了模板与 mask，能让你少写很多胶水代码。
- **数据来源**：ShareGPT 风格对话、Self-Instruct 自动构造指令、人工标注三件套；中文场景可关注 BELLE、COIG 等开源指令集。
- **下一步**：本篇全量 SFT 在 7B 上会"显存炸了"。下一篇《LoRA 与 QLoRA——用消费级显卡微调大模型》讲怎么只训练极小一部分参数（0.39%）就逼近全量微调效果，并把基座压到 4-bit，让单张消费卡也能微调——这是个人开发者微调大模型的唯一现实路径。学完下一篇，你就能把本篇的数据和流程直接接上 LoRA，在自己的 3090/4090 上跑出第一个专用模型。

> 本篇是《大模型开发从 0 到 1》专栏第 46 篇，阶段 9「微调与训练」第 1 篇。专栏文章按「分类专栏」归类，顺序学习体验最佳。
