# 先做个"笨"的 RAG 再说：200 行代码跑通基线

> 一上手就想做"多路召回 + 重排 + 查询改写 + 自省"？
> 结果两周后还在调参数，却不知道到底哪一步带来了提升。
>
> **正确的做法是先做一个最朴素、能跑通的版本，把它当作基线。**

## 一、为什么必须先有基线

**没有基线，就没有进步。**

```
❌ 改了一堆东西 → 效果从"感觉不行"到"感觉还行"
   → 到底是哪个改动作的用？不知道

✅ 基线：10 道题答对 4 道
   加了 A 改动：答对 5 道（+1）
   再加上 B 改动：答对 7 道（+2）
   → 每一步的收益都是可量化的
```

**基线的第二个价值：暴露真正的瓶颈。** 一个朴素 RAG 如果只能答对 40%，你就知道有一半问题出在基础环节（分块、检索），而不是"缺少高级技巧"。

## 二、最小可用的 RAG：四步

```
① 加载文档 → ② 切分 → ③ 向量化入库 → ④ 检索 + 生成
```

**不需要的**：查询改写、重排、混合检索、多路召回、自省。

**需要的**：一个能读取的文档、一个切分器、一个 embedding 模型、一个向量库、一个 LLM。

## 三、完整实现（约 200 行）

**① 加载与切分**

```python
from pathlib import Path
from langchain_community.document_loaders import TextLoader, PyPDFLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter

def load_documents(dir_path: str) -> list:
    docs = []
    for p in Path(dir_path).rglob("*"):
        if p.suffix == ".txt" or p.suffix == ".md":
            docs.extend(TextLoader(str(p), encoding="utf-8").load())
        elif p.suffix == ".pdf":
            docs.extend(PyPDFLoader(str(p)).load())
    return docs

def split_documents(docs: list, chunk_size: int = 800, overlap: int = 100) -> list:
    splitter = RecursiveCharacterTextSplitter(
        chunk_size=chunk_size,
        chunk_overlap=overlap,
        separators=["\n\n", "\n", "。", "！", "？", "；", " ", ""],
        length_function=len,
    )
    return splitter.split_documents(docs)
```

**注意 `separators`**：中文文档要加中文标点，否则会按空格切得乱七八糟。

**② 向量化入库**

```python
from langchain_chroma import Chroma
from langchain_openai import OpenAIEmbeddings

def build_index(chunks: list, persist_dir: str = "./chroma_db"):
    embeddings = OpenAIEmbeddings(model="text-embedding-3-small")

    # 给每个块加上来源信息
    for i, c in enumerate(chunks):
        c.metadata["chunk_id"] = i
        c.metadata["source"] = c.metadata.get("source", "unknown")

    vectorstore = Chroma.from_documents(
        documents=chunks,
        embedding=embeddings,
        persist_directory=persist_dir,
        collection_name="baseline",
    )
    return vectorstore
```

**③ 检索**

```python
def retrieve(vectorstore, question: str, k: int = 4) -> list:
    return vectorstore.similarity_search(question, k=k)
```

**④ 生成**

```python
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser

RAG_PROMPT = ChatPromptTemplate.from_messages([
    ("system", """你是一个文档问答助手。

**只依据下面提供的资料回答问题。**
如果资料中没有相关信息，直接回答"资料中没有找到相关内容"，不要编造。

资料：
{context}"""),
    ("human", "{question}"),
])

def build_chain():
    llm = ChatOpenAI(model="gpt-4o-mini", temperature=0)
    return RAG_PROMPT | llm | StrOutputParser()

def format_docs(docs: list) -> str:
    parts = []
    for i, d in enumerate(docs, 1):
        src = Path(d.metadata.get("source", "?")).name
        parts.append(f"[资料 {i}] 来源：{src}\n{d.page_content}")
    return "\n\n---\n\n".join(parts)
```

**⑤ 串起来**

```python
class BaselineRAG:
    def __init__(self, persist_dir: str = "./chroma_db"):
        self.embeddings = OpenAIEmbeddings(model="text-embedding-3-small")
        self.vectorstore = Chroma(
            persist_directory=persist_dir,
            embedding_function=self.embeddings,
            collection_name="baseline",
        )
        self.chain = build_chain()

    def ask(self, question: str, k: int = 4) -> dict:
        docs = self.vectorstore.similarity_search(question, k=k)
        answer = self.chain.invoke({
            "context": format_docs(docs),
            "question": question,
        })
        return {
            "answer": answer,
            "sources": [d.metadata.get("source") for d in docs],
            "docs": docs,
        }
```

**⑥ 建索引的入口**

```python
def main():
    docs = load_documents("./docs")
    print(f"加载 {len(docs)} 个文档")

    chunks = split_documents(docs)
    print(f"切分成 {len(chunks)} 个块")

    build_index(chunks)
    print("索引构建完成")

    rag = BaselineRAG()
    while True:
        q = input("\n问题：").strip()
        if not q:
            break
        result = rag.ask(q)
        print(f"\n回答：{result['answer']}")
        print(f"来源：{result['sources']}")
```

**这就是一个能跑的 RAG。** 不要小看它——很多生产系统的基础版本就是这样的。

## 四、基线必须配评测集

**没有评测集的基线，等于没有基线。**

准备 20~30 道题，每道题标注"标准答案应该在哪个文档里"：

```python
EVAL_SET = [
    {
        "question": "退款需要几个工作日？",
        "expected_source": "售后服务条款.md",
        "expected_keywords": ["7", "工作日"],
    },
    {
        "question": "发票怎么申请？",
        "expected_source": "财务流程.md",
        "expected_keywords": ["申请", "发票"],
    },
    # ... 20~30 道
]
```

**评测两个层次**：

**① 检索命中率**（不需要 LLM 判分，快且客观）

```python
def eval_retrieval(rag, eval_set):
    hits = 0
    for item in eval_set:
        docs = rag.vectorstore.similarity_search(item["question"], k=4)
        sources = [Path(d.metadata.get("source", "")).name for d in docs]
        if item["expected_source"] in sources:
            hits += 1
    return hits / len(eval_set)

print(f"检索命中率：{eval_retrieval(rag, EVAL_SET):.1%}")
```

**这个指标最有价值**——如果检索命中率只有 60%，那么答案准确率不可能超过 60%。

**② 答案正确率**（用关键词匹配或 LLM 判分）

```python
def eval_answers(rag, eval_set):
    correct = 0
    for item in eval_set:
        result = rag.ask(item["question"])
        answer = result["answer"]
        # 简单版：关键词都在答案里
        if all(kw in answer for kw in item["expected_keywords"]):
            correct += 1
    return correct / len(eval_set)
```

更严格的话用 LLM 判分（后面 RAGAS 那篇会讲）。

## 五、基线的作用：定位瓶颈

跑完基线，你会得到两个数字：

```
检索命中率：62%
答案正确率：45%
```

**解读**：

- 检索命中率 62% → **检索侧是主要瓶颈**，先优化分块和 embedding；
- 答案正确率比检索命中率低 17 个百分点 → **生成侧也有问题**（可能是有噪声干扰，或者提示词约束不够）。

**如果反过来**：

```
检索命中率：90%
答案正确率：50%
```

**检索没问题，问题全在生成侧**。这时候去优化检索是白费力气——该改提示词、换模型、加引用约束。

**这个判断能让你的优化方向少走一大半弯路。**

## 六、基线之后的第一批优化（按性价比排序）

**① 调块大小**（10 分钟，收益大）

```python
for size in [400, 600, 800, 1200, 1600]:
    chunks = split_documents(docs, chunk_size=size, overlap=size // 8)
    build_index(chunks, persist_dir=f"./db_{size}")
    rag = BaselineRAG(f"./db_{size}")
    print(size, eval_retrieval(rag, EVAL_SET))
```

**选命中率最高的那个**。这一步经常能带来 10 个百分点的提升。

**② 加混合检索**（1 小时，收益中）

向量检索对"精确词"不敏感——用户问"ERR_1024 怎么解决"，向量可能召回一堆"错误处理"的通用内容。

```python
from langchain_community.retrievers import BM25Retriever
from langchain.retrievers import EnsembleRetriever

bm25 = BM25Retriever.from_documents(chunks, k=4)
vector = vectorstore.as_retriever(search_kwargs={"k": 4})

hybrid = EnsembleRetriever(
    retrievers=[bm25, vector],
    weights=[0.4, 0.6],
)
```

**③ 加重排**（1 小时，收益中）

```python
from langchain.retrievers import ContextualCompressionRetriever
from langchain.retrievers.document_compressors import CrossEncoderReranker
from langchain_community.cross_encoders import HuggingFaceCrossEncoder

reranker = CrossEncoderReranker(
    model=HuggingFaceCrossEncoder(model_name="BAAI/bge-reranker-base"),
    top_n=3,
)
compression = ContextualCompressionRetriever(
    base_compressor=reranker,
    base_retriever=hybrid,
)
```

**④ 加查询改写**（半天，收益看场景）

多轮对话场景收益最大，单轮问答收益一般。

**注意顺序：一次只改一个，每次都跑评测。** 同时改三个，你永远不知道哪个有用。

## 七、基线代码要保留

**别在基线上直接改**。做法是：

```
rag_baseline.py     ← 基线，永远保持可运行
rag_v2.py           ← 加混合检索
rag_v3.py           ← v2 + 重排
rag_v4.py           ← v3 + 查询改写
```

每加一个能力就新建一个文件，评测结果记在一张表里：

| 版本 | 改动 | 检索命中率 | 答案正确率 | 平均延迟 |
|---|---|---|---|---|
| baseline | - | 62% | 45% | 1.2s |
| v2 | +混合检索 | 74% | 58% | 1.4s |
| v3 | +重排 | 81% | 71% | 2.1s |
| v4 | +查询改写 | 83% | 76% | 3.4s |

**这张表是你做技术决策的唯一依据**。

而且要能回答："v3 比 v2 慢了 0.7 秒，换来 13 个百分点的提升，值不值？"

## 八、什么时候基线就够了

**别过度优化。** 以下情况，朴素 RAG 就是最优解：

- 文档量小（< 1000 篇）
- 问题类型单一（都是事实查询）
- 用户能接受 2 秒延迟
- 准确率要求 70% 左右就够

**优化的边际收益是递减的**：从 45% 提到 75% 相对容易，从 75% 提到 90% 要付出几倍的成本。

## 九、小结

```python
# 基线四步
docs = load_documents("./docs")           # 1. 加载
chunks = split_documents(docs)            # 2. 切分
build_index(chunks)                       # 3. 向量化入库
rag = BaselineRAG(); rag.ask(question)    # 4. 检索 + 生成
```

四条原则：

```
1. 先跑通，再优化——别一上来就堆高级技巧
2. 基线必须配评测集（20~30 道题起步）
3. 一次只改一个变量，每次都跑评测
4. 保留每个版本，记录效果对比
```

**"笨"的 RAG 不是浪费时间，它是你后续所有优化的基准线。** 没有它，你做的每一个"改进"都是在黑暗中摸索。
