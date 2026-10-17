# 全本地 RAG 栈实战：数据不出门，私有化部署一条龙

很多企业的硬约束是：**数据不能出内网**。医疗病历、金融研报、军工文档，一旦上传到公有云 embedding / LLM API，合规就过不了。这时候需要一套**全本地 RAG 栈**——从向量库到 embedding 到生成模型，全部跑在自己机器上，数据零出网。

本文给你一套经过验证的本地栈选型 + 部署要点，照着搭就能跑。

## 一、全本地栈的组件清单

一个最小可用的本地 RAG，需要四块都能本地化：

| 组件 | 作用 | 本地选型 |
|------|------|----------|
| 向量数据库 | 存向量 + 检索 | Milvus / Qdrant / Chroma（单机） |
| Embedding 模型 | 文本向量化 | bge-large-zh / bge-m3（本地推理） |
| 生成模型 | 读文档答问题 | Qwen / DeepSeek / Llama 系列（本地推理） |
| 推理框架 | 跑上面两个模型 | Ollama / vLLM / Llama.cpp |

全部开源、可离线安装，不依赖任何外部 API。

## 二、Embedding 本地化

下载一个开源中文友好的 embedding 模型（如 `BAAI/bge-m3`），用本地推理框架加载：

```python
from sentence_transformers import SentenceTransformer
model = SentenceTransformer("BAAI/bge-m3")   # 离线加载本地权重
vec = model.encode("如何配置负载均衡")
```

要点：

- 模型权重提前下载到内网，部署时指定本地路径，不要运行时去 HuggingFace 拉。
- bge 系列需要**在 query 前加 `Represent this sentence for searching relevant passages:` 前缀**（官方约定），召回率差异显著，别忘了。
- 维度一般在 1024~1536，建库时向量索引参数要对齐。

## 三、生成模型本地化：Ollama 最省心

Ollama 是本地跑开源大模型最顺手的工具，一条命令拉起：

```bash
ollama pull qwen2.5:14b     # 中文友好、14B 够用
ollama serve                 # 起本地服务，默认 11434 端口
```

代码里直接调本地端点，和调 OpenAI API 几乎一样：

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")
resp = client.chat.completions.create(
    model="qwen2.5:14b",
    messages=[{"role":"user","content": prompt}]
)
```

如果需要高并发，换 vLLM（吞吐高、支持连续批处理），代价是部署复杂一点。

## 四、向量库本地化：Qdrant / Chroma

小团队单机用 Chroma 最轻（纯 Python，文件级存储）；要上规模用 Qdrant（Rust 写，性能好，支持过滤）。

```python
import chromadb
client = chromadb.PersistentClient(path="/data/chroma")   # 落盘，重启不丢
col = client.get_or_create_collection("kb")
col.add(ids=ids, embeddings=vecs, documents=docs, metadatas=metas)
hits = col.query(query_embeddings=[qvec], n_results=5,
                 where={"tenant": "A"})   # 本地也能做元数据过滤
```

## 五、硬件与性能现实

全本地最大的成本是**显卡**：

- 7B~14B 模型：一张 24G 显存卡（如 RTX 4090）能跑，embedding 和生成可共用。
- 32B 模型：需要 48G+ 显存（A100 / 多卡）。
- 纯 CPU 跑 Llama.cpp 也能用，但延迟高，只适合低并发。

如果显卡紧张，常见折中：**embedding 和 rerank 用本地小模型（不吃显存），生成用稍大模型按需加载**。或者 embedding 本地、生成走内网部署的推理集群。

## 六、和云方案的取舍

全本地不是银弹：

- **优点**：数据零出网、无 API 账单、无外部依赖、可离线。
- **缺点**：要自己养显卡和运维、模型效果上限受限于开源模型、迭代慢。

经验法则：**有强合规 / 数据保密要求 → 全本地；无合规压力、追求效果和省心 → 公有云 API + 私有数据脱敏**。

## 七、落地 checklist

1. 模型权重、依赖全部离线打包，部署机禁外网；
2. embedding / 生成模型本地路径加载，禁止运行时联网；
3. 向量库落盘 + 定期备份；
4. 显存 / 内存预算算清楚，压测并发；
5. 本地也要做降级（生成模型挂了有兜底），别以为本地就永远不挂。

## 小结

全本地 RAG 栈 = 开源 embedding（bge-m3）+ 本地生成模型（Qwen/DeepSeek via Ollama/vLLM）+ 本地向量库（Qdrant/Chroma）。核心是「权重离线、推理本地、数据不出网」。代价是显卡和运维，换来的是合规无忧。照着上面的选型和 checklist，一天就能搭起一个能跑的私有化 RAG。
