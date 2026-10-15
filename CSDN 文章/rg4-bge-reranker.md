# BGE Reranker 实战：模型选择、批处理与性能优化

> 上一篇讲了交叉编码器的原理。
> 这篇讲**具体怎么用**——选哪个模型、怎么部署、怎么把延迟压到 200ms 以内。

## 一、BGE Reranker 家族

| 模型 | 参数量 | 语言 | 速度（GPU） | 效果 |
|---|---|---|---|---|
| `bge-reranker-base` | 278M | 中英 | 快 | 好 |
| `bge-reranker-large` | 560M | 中英 | 中 | 更好 |
| `bge-reranker-v2-m3` | 568M | **多语言** | 中 | 最好 |
| `bge-reranker-v2-gemma` | 2B | 多语言 | 慢 | 最强 |
| `bge-reranker-v2-minicpm` | 2.7B | 多语言 | 慢 | 最强 |

**选择建议**：

```
中文、延迟敏感    → bge-reranker-base
中文、质量优先    → bge-reranker-large
多语言            → bge-reranker-v2-m3 ⭐
极致质量（有资源） → v2-gemma / v2-minicpm
```

**`v2-m3` 是当前的"默认推荐"**——多语言支持好，性能均衡。

## 二、加载与基础用法

**直接用 FlagEmbedding**：

```python
from FlagEmbedding import FlagReranker

reranker = FlagReranker(
    "BAAI/bge-reranker-v2-m3",
    use_fp16=True,                   # GPU 用 fp16，快一倍
)

scores = reranker.compute_score([
    ("退款要多久到账", "退款流程：7个工作日到账"),
    ("退款要多久到账", "账户余额查询指南"),
])
print(scores)          # [0.98, 0.01]
```

**`compute_score` 接受"配对列表"**——一次打多个分。

**在 LangChain 里**：

```python
from langchain_community.cross_encoders import HuggingFaceCrossEncoder
from langchain.retrievers.document_compressors import CrossEncoderReranker
from langchain.retrievers import ContextualCompressionRetriever

cross_encoder = HuggingFaceCrossEncoder(
    model_name="BAAI/bge-reranker-v2-m3",
    model_kwargs={"device": "cuda", "trust_remote_code": True},
)

reranker = CrossEncoderReranker(model=cross_encoder, top_n=4)

retriever = ContextualCompressionRetriever(
    base_compressor=reranker,
    base_retriever=hybrid_retriever,
)
```

## 三、批处理：性能的核心

**逐条打分 vs 批处理**（20 个候选，CPU）：

```python
# ❌ 逐条
scores = [reranker.compute_score([(q, d.page_content)]) for d in docs]
# 耗时：约 2.0 秒

# ✅ 批量
pairs = [(q, d.page_content) for d in docs]
scores = reranker.compute_score(pairs, batch_size=32)
# 耗时：约 0.4 秒
```

**5 倍的差距。**

**batch_size 的选择**：

| 设备 | batch_size | 说明 |
|---|---|---|
| CPU | 8~16 | 太大反而慢（内存带宽瓶颈） |
| GPU（8 GB） | 32~64 | 显存限制 |
| GPU（16 GB+） | 64~128 | 吞吐更高 |

**动态确定 batch_size**：

```python
def auto_batch_size(device: str, model_size: str) -> int:
    if device == "cpu":
        return 16
    # GPU：按显存估算
    import torch
    if torch.cuda.is_available():
        mem_gb = torch.cuda.get_device_properties(0).total_memory / 1e9
        if model_size == "large":
            return 32 if mem_gb < 12 else 64
        return 64 if mem_gb < 12 else 128
    return 16
```

## 四、部署成服务（推荐）

**在生产环境，别在应用进程里加载模型**——用一个独立的推理服务。

**用 `text-embeddings-inference`**（官方推荐）：

```bash
docker run -d --gpus all -p 8080:80 \
  -v $PWD/data:/data \
  ghcr.io/huggingface/text-embeddings-inference:latest \
  --model-id BAAI/bge-reranker-v2-m3 \
  --max-batch-tokens 16384 \
  --dtype float16
```

**调用**：

```python
import requests

def rerank(query: str, documents: list[str], top_n: int = 4):
    resp = requests.post(
        "http://localhost:8080/rerank",
        json={"query": query, "documents": documents, "top_n": top_n},
        timeout=10,
    )
    return resp.json()

result = rerank("退款要多久", [d.page_content for d in docs], top_n=4)
for item in result:
    print(item["index"], item["score"])
```

**服务化的三个好处**：

```
① 应用进程轻量（不用加载 1 GB 的模型）
② 多个应用共享一个 GPU
③ 可以独立扩缩容
```

## 五、把延迟压到 200ms 以内

**延迟构成**：

```
初筛（向量 + BM25）：20~50ms
重排（30 个候选）：100~300ms（GPU）
生成：500~2000ms
```

**优化重排延迟的五个手段**：

**① 减少候选数**

```
30 个候选 → 100ms
20 个候选 → 70ms
```

**先看"减少候选"会不会掉召回**——很多场景 20 个就够。

**② 缩短输入长度**

交叉编码器的耗时和"输入 token 数"近似线性：

```python
def truncate_for_rerank(text: str, max_chars: int = 400) -> str:
    """只取前 400 字"""
    return text[:max_chars]
```

**400 字 vs 1500 字，耗时差 3 倍。**

**但要验证截断会不会漏掉关键信息。**

**③ 用 fp16 / bf16**

```python
reranker = FlagReranker("BAAI/bge-reranker-v2-m3", use_fp16=True)
```

**GPU 上快约 2 倍，精度损失可忽略。**

**④ 用更小的模型**

```
bge-reranker-large  → 280ms
bge-reranker-base   → 150ms
```

**先用 base，效果不够再升级。**

**⑤ 并行化**

```python
import asyncio

async def parallel_rerank(query: str, docs: list, batch_size: int = 16):
    """分批并行调用"""
    batches = [docs[i:i+batch_size] for i in range(0, len(docs), batch_size)]

    async def score(batch):
        return await asyncio.to_thread(
            reranker.compute_score,
            [(query, d.page_content) for d in batch],
        )

    results = await asyncio.gather(*[score(b) for b in batches])
    all_scores = [s for r in results for s in r]
    return sorted(zip(docs, all_scores), key=lambda x: -x[1])
```

## 六、和向量模型配对

**BGE 系列的设计是"配对使用"**：

| 向量模型 | 配对的 reranker | 说明 |
|---|---|---|
| `bge-large-zh-v1.5` | `bge-reranker-large` | 同源，配合好 |
| `bge-m3` | `bge-reranker-v2-m3` | 多语言配对 |
| `bge-base-zh-v1.5` | `bge-reranker-base` | 轻量组合 |

**不一定要"同源配对"**——但同源的模型在训练数据分布上更一致，**通常效果更稳**。

**换模型时的检查清单**：

```
□ 向量模型和 reranker 的语言支持一致吗？
□ reranker 的分数范围是什么（0~1 还是 -10~10）？
□ 是否需要归一化分数？
```

## 七、分数怎么用

**BGE reranker 的输出**：

```python
scores = reranker.compute_score([(q, d) for d in docs], normalize=True)
# normalize=True 时输出 [0, 1] 之间的分数
```

**不归一化时是原始 logits**（可能是 -10 到 +10）。

**用分数过滤**：

```python
def rerank_and_filter(query, docs, reranker, min_score: float = 0.3, top_n: int = 4):
    pairs = [(query, d.page_content) for d in docs]
    scores = reranker.compute_score(pairs, normalize=True)

    ranked = sorted(zip(docs, scores), key=lambda x: -x[1])
    filtered = [(d, s) for d, s in ranked if s >= min_score]

    if not filtered:
        return []                  # 触发"无答案"处理
    return [d for d, _ in filtered[:top_n]]
```

**`min_score` 的校准**：

```python
def calibrate_rerank_threshold(eval_set, reranker):
    pos, neg = [], []
    for item in eval_set:
        candidates = retriever.invoke(item["question"])
        pairs = [(item["question"], d.page_content) for d in candidates]
        scores = reranker.compute_score(pairs, normalize=True)
        for d, s in zip(candidates, scores):
            (pos if d.metadata["id"] == item["expected_id"] else neg).append(s)

    print(f"正样本 P5={np.percentile(pos,5):.3f}")
    print(f"负样本 P95={np.percentile(neg,95):.3f}")
    return np.percentile(pos, 5)
```

**BGE reranker 的典型分布**（实测）：

```
正样本：0.4 ~ 0.99（P5 约 0.35）
负样本：0.001 ~ 0.3（P95 约 0.25）
```

**阈值 0.3 附近是个合理的起点。**

## 八、几个实践要点

**① 别用 reranker 替换向量检索。**
它不能"从 100 万里找"——**只能"从 30 个里排"**。

**② 候选数控制在 20~50。**

```
< 10：重排收益小（排序空间有限）
> 50：延迟明显上升
```

**③ 重排后要保留原始分数。**
给调试用：

```python
d.metadata["_rerank_score"] = score
d.metadata["_vector_score"] = original_score
```

**④ 处理"候选全都不相关"的情况。**

```python
scores = reranker.compute_score(pairs, normalize=True)
if max(scores) < LOW_THRESHOLD:
    return "资料中没有找到相关内容。"
```

**重排分数是最可靠的"有无答案"信号**——比向量相似度可靠得多。

**⑤ 注意模型的语言。**
用 `bge-reranker-base`（中英）处理日语文档，效果会差。**多语言场景用 `v2-m3`**。

**⑥ 显存要留余量。**

```
bge-reranker-v2-m3 (fp16)：约 1.2 GB
batch_size 64 时的中间激活：额外 2~3 GB
→ 建议至少 6 GB 显存
```

## 九、一个生产级实现

```python
class RerankService:
    def __init__(self, model_name: str = "BAAI/bge-reranker-v2-m3",
                 device: str = "cuda", use_fp16: bool = True,
                 max_chars: int = 500):
        from FlagEmbedding import FlagReranker
        self.model = FlagReranker(model_name, use_fp16=use_fp16)
        self.max_chars = max_chars
        self.device = device

    def rerank(self, query: str, docs: list, top_n: int = 4,
               min_score: float = 0.3, batch_size: int = 32):
        if not docs:
            return []

        pairs = [(query, d.page_content[:self.max_chars]) for d in docs]
        scores = self.model.compute_score(pairs, normalize=True, batch_size=batch_size)

        ranked = sorted(zip(docs, scores), key=lambda x: -x[1])

        for d, s in ranked:
            d.metadata["rerank_score"] = float(s)

        filtered = [d for d, s in ranked if s >= min_score]
        if not filtered:
            return []

        return filtered[:top_n]
```

**配一个超时保护**：

```python
import asyncio

async def rerank_with_timeout(service, query, docs, timeout: float = 1.0):
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(service.rerank, query, docs),
            timeout=timeout,
        )
    except asyncio.TimeoutError:
        log.warning("重排超时，回退到初筛结果")
        return docs[:4]                # 降级：直接用初筛结果
```

**"重排超时就降级"是很实用的容错**——总比整个请求失败好。

## 十、成本估算

```
自建（单张 A10 GPU）：
  云 GPU 约 3~8 元/小时
  或本地显卡一次性投入
  吞吐：约 200~500 次重排/秒（batch 32）

API（Cohere Rerank）：
  约 $2 / 1000 次查询
  免部署，但延迟略高（网络往返）
```

**自建 vs API 的取舍**：

```
调用量大（> 100 万次/月）→ 自建更省
调用量小 → API 更省事
数据敏感 → 必须自建
```

## 十一、小结

```python
# 推荐配置
model = "BAAI/bge-reranker-v2-m3"
use_fp16 = True
batch_size = 32
max_chars = 500          # 截断长度
top_n = 4
min_score = 0.3          # 校准得出
```

五条要点：

```
1. 中文推荐 v2-m3（多语言 + 效果好）
2. 必须批处理（batch_size 32）
3. 生产环境部署成独立服务
4. 候选数控制在 20~50，输入截断到 400~500 字
5. 用 rerank 分数做"有无答案"判断（比向量分数可靠）
```

**一句话：BGE Reranker 是 RAG 里"投入产出比最高"的组件之一。** 它能把前 3 个结果的精确率从 0.58 提到 0.89——**而最终给模型的就是那前几个结果**，所以这个提升会直接传递到答案质量上。
