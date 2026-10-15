# 从 langchain-community 迁到 core 与 partner 包：一次必要的瘦身

> `pip install langchain` 装了 200 多个依赖包，镜像 1.2 GB。
> 里面 95% 是你永远不会用的集成。
>
> LangChain 从 0.2 开始做了包拆分，**迁过去能让镜像小一半、启动快一倍**。

## 一、包拆分的来龙去脉

早期一个 `langchain` 包什么都装：

```
langchain (巨型包)
├── 核心抽象 (Runnable, Prompt, Chain)
├── 所有模型集成 (OpenAI, Anthropic, 百度, 智谱, Ollama...)
├── 所有向量库 (FAISS, Chroma, Milvus, PGVector...)
└── 所有文档加载器 (PDF, Word, Notion, Confluence...)
```

现在拆成四层：

| 包 | 内容 | 是否需要 |
|---|---|---|
| `langchain-core` | 抽象基类、LCEL、消息、Runnable | **必装** |
| `langchain` | 高层封装（Agent、Chain 组合） | 通常需要 |
| `langchain-community` | 第三方集成（大量、杂、质量参差） | **尽量少用** |
| `langchain-openai` 等 | 官方维护的独立集成包 | 按需 |

**目标：只装真正用的包。**

## 二、第一步：找出你实际用了什么

```bash
# 找出所有 langchain 相关的导入
grep -rhoP "from langchain[\w.]* import" --include="*.py" . | sort -u
```

输出大概长这样：

```
from langchain.chains import RetrievalQA
from langchain_community.vectorstores import FAISS
from langchain_community.document_loaders import PyPDFLoader
from langchain_community.embeddings import HuggingFaceEmbeddings
from langchain_community.llms import Ollama
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
```

按来源归类：

```
langchain_core          → 保留（抽象层）
langchain_openai        → 保留（官方集成）
langchain_community     → ⚠️ 逐个检查能否替换
langchain.chains        → ⚠️ 旧 API，建议重写
```

## 三、万能的迁移对照表

### LLM 与 Embedding

| 旧（community） | 新（partner 包） |
|---|---|
| `langchain_community.chat_models.ChatOpenAI` | `langchain_openai.ChatOpenAI` |
| `langchain_community.chat_models.ChatAnthropic` | `langchain_anthropic.ChatAnthropic` |
| `langchain_community.embeddings.OpenAIEmbeddings` | `langchain_openai.OpenAIEmbeddings` |
| `langchain_community.llms.Ollama` | `langchain_ollama.OllamaLLM` |
| `langchain_community.embeddings.HuggingFaceEmbeddings` | `langchain_huggingface.HuggingFaceEmbeddings` |

### 向量库

| 旧 | 新 |
|---|---|
| `langchain_community.vectorstores.FAISS` | `langchain_community.vectorstores.FAISS`（暂留） |
| `langchain_community.vectorstores.Chroma` | `langchain_chroma.Chroma` |
| `langchain_community.vectorstores.PGVector` | `langchain_postgres.PGVector` |
| `langchain_community.vectorstores.Milvus` | `langchain_milvus.Milvus` |

⚠️ **FAISS 还在 community 里**——它没被拆出去。这类"没拆"的集成是无奈的例外。

### 文档加载器

大部分加载器**还在 community**（因为它们依赖太杂，不适合做官方包）：

```python
from langchain_community.document_loaders import PyPDFLoader        # 保留
from langchain_community.document_loaders import UnstructuredFileLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter  # ✅ 已拆出
```

`langchain_text_splitters` 是拆分出来的独立包，**一定要换**——它是最常用的组件之一。

### 旧的 Chain API

`langchain.chains` 里的东西大部分被 LCEL 取代：

```python
# ❌ 旧：RetrievalQA
from langchain.chains import RetrievalQA
qa = RetrievalQA.from_chain_type(llm=llm, retriever=retriever)
answer = qa.run("问题")

# ✅ 新：LCEL
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser

qa = (
    {"context": retriever | format_docs, "question": RunnablePassthrough()}
    | prompt
    | llm
    | StrOutputParser()
)
answer = qa.invoke("问题")
```

**LCEL 版本不只是"新写法"**——它支持流式、批量、异步、重试，并且每一步在 trace 里可见。旧 Chain 这些都是黑盒。

## 四、动手迁移的步骤

**① 建一个新的依赖清单**（`pyproject.toml`）

```toml
[project]
dependencies = [
    "langchain-core>=0.3.0",
    "langchain>=0.3.0",
    "langchain-openai>=0.2.0",
    "langchain-chroma>=0.1.4",
    "langchain-text-splitters>=0.3.0",
    "langchain-huggingface>=0.1.0",
]

[project.optional-dependencies]
pdf = ["pypdf>=4.0", "langchain-community>=0.3.0"]   # 只在需要 PDF 时装
```

**按功能分组 optional 依赖**，这样基础镜像不会带上 PDF、Office 解析那些重依赖。

**② 逐个替换导入**

从上面的对照表来。遇到 community 里没有替代的：

```python
# 这是唯一"合理"的 community 用法——没有官方替代时
from langchain_community.document_loaders import PyPDFLoader
```

**③ 处理旧的 Chain**

按"有没有 LCEL 等价物"分：

```
RetrievalQA       → LCEL 检索链
ConversationChain → RunnableWithMessageHistory
LLMChain          → prompt | llm | parser
SequentialChain   → 用 | 串起来
```

**④ 装包并测试**

```bash
pip uninstall langchain langchain-community -y
pip install langchain-core langchain langchain-openai langchain-chroma \
            langchain-text-splitters langchain-huggingface
python -c "import langchain; print(langchain.__version__)"
```

## 五、检查是否还有残留

```bash
# 1. 看还有没有引用 community
grep -rn "langchain_community" --include="*.py" .

# 2. 看镜像大小变化
docker images | grep my-app

# 3. 看导入耗时
python -X importtime -c "import langchain" 2>&1 | tail -20
```

**依赖数量能减掉一大半**：

```
迁移前：langchain + langchain-community = 约 230 个包
迁移后：4 个 langchain 包 + 3 个三方库 = 约 60 个包
```

**镜像体积通常能降 60% 以上**，冷启动时间也明显缩短。

## 六、容易踩的坑

**① 版本兼容三角**

`langchain-core`、`langchain`、`langchain-openai` 之间有版本约束。**别手动指定过细的版本**，让 pip 解析：

```bash
pip install "langchain>=0.3" "langchain-openai>=0.2"
```

装完后固定：

```bash
pip freeze | grep -E "langchain|pydantic" > constraints.txt
```

插一句：**pydantic 版本冲突是最高频的问题**（v1 vs v2）。LangChain 0.3 要求 pydantic ≥ 2，如果你的项目里还有依赖 pydantic 1 的库，会冲突。

**② `pydantic_v1` 兼容层**

LangChain 有一段过渡期提供 `langchain_core.pydantic_v1`，现在已废弃：

```python
# ❌ 已移除
from langchain_core.pydantic_v1 import BaseModel

# ✅
from pydantic import BaseModel
```

**③ 隐式的 community 依赖**

有些三方库会偷偷依赖 `langchain-community`。用 `pipdeptree` 查：

```bash
pipdeptree | grep -A3 langchain-community
```

**④ 加载器的"隐性重依赖"**

`UnstructuredFileLoader` 需要 `unstructured` 包（带一批系统库）。如果只用 PDF，直接装 `pypdf` 就够了。

**⑤ 别一次性全改**

**分批改，每批跑测试**：

```
批次 1：模型和 embedding（影响面小）
批次 2：向量库
批次 3：Chain → LCEL（影响面最大）
批次 4：文档加载器
```

一次性全改，出问题不知道是哪一步引起的。

## 七、迁移收益量化

以典型的 RAG 服务为例：

| 指标 | 迁移前 | 迁移后 |
|---|---|---|
| 依赖包数量 | 231 | 58 |
| 镜像大小 | 1.24 GB | 420 MB |
| 冷启动 | 8.2s | 3.1s |
| `import langchain` | 2.4s | 0.6s |

**Serverless 场景收益最大**——冷启动时间直接影响要不要用预热实例。

## 八、关于新项目

**新项目从一开始就用新结构**：

```toml
dependencies = [
    "langchain-core",           # 抽象
    "langchain",                # 高层
    "langchain-openai",         # 官方集成
    "langchain-text-splitters",
]
```

**原则：能用官方 partner 包就用，实在没有才用 community。**

判断标准：

```
这个集成有独立的 langchain-xxx 包吗？
├─ 有 → 用那个
└─ 没有 → 检查 https://python.langchain.com/docs/integrations/providers/
          ├─ 标了 "official" → 用官方包
          └─ 只有 community → 才用 community
```

## 九、小结

```
迁移路径：
  langchain_community.*  →  官方 partner 包
  langchain.chains.*     →  LCEL
  langchain_core.pydantic_v1  →  pydantic
```

四个要点：

1. **先审计再动手**——`grep` 找出实际用了什么；
2. **对照表逐个替换**，找不到替代的才留 community；
3. **分批迁移 + 每批测试**；
4. **固定版本 + 定期升级**。

**包拆分不是"官方折腾你"，是为了让依赖树可控。** 一个装了 200 个包的应用，出安全漏洞要更新 200 个包——这个过程本身就是灾难。
