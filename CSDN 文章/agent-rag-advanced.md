# RAG 进阶：把准确率从「能跑」拉到「能用」

上一篇跑通了最基础的 RAG。但真拿去做业务，你会发现一个尴尬的现实：**它偶尔很准，偶尔答非所问，而且你不知道为什么**。

问题几乎都出在检索端。这篇讲四个能立竿见影提升准确率的手段：**按文档类型调切分、混合检索、Rerank 重排、查询改写**，最后给一套排查方法论。

---

## 一、切分：别对所有文档用同一把尺子

基础版里我们按段落切。但不同文档的结构完全不同：

| 文档类型 | 问题 | 切法 |
|---|---|---|
| **技术文档 / Markdown** | 按字数切会把代码块切断 | **按标题层级切**，一个二级标题一块 |
| **表格 / Excel** | 切碎后行和表头分离，完全失去意义 | **整表转文本**再存，或按行存但每行带上表头 |
| **法律合同** | 条款之间有引用关系 | 按**条款编号**切，保留编号上下文 |
| **对话记录** | 单句话没有上下文 | 按**会话窗口**切（比如每 5 轮一块） |
| **扫描 PDF** | 提取出来是一堆乱码 | 先做 OCR，再按段落切 |

### 按标题层级切 Markdown

```python
import re

def chunk_by_heading(md: str, max_len=800):
    """按 # / ## 标题切，超长再按段落二次切"""
    blocks, cur_title, cur = [], "", ""
    for line in md.splitlines():
        if re.match(r"^#{1,3}\s", line):
            if cur.strip():
                blocks.append((cur_title, cur.strip()))
            cur_title, cur = line.strip(), ""
        else:
            cur += line + "\n"
    if cur.strip():
        blocks.append((cur_title, cur.strip()))

    # 超长的再按段落拆
    out = []
    for title, body in blocks:
        if len(body) <= max_len:
            out.append(f"{title}\n{body}")
        else:
            buf = ""
            for p in body.split("\n\n"):
                if len(buf) + len(p) > max_len:
                    out.append(f"{title}\n{buf}".strip()); buf = ""
                buf += p + "\n\n"
            if buf: out.append(f"{title}\n{buf}".strip())
    return out
```

关键点：**每个块都带上它的标题**。这样「年假规则」这块的文本里就包含「年假规则」四个字，检索时命中率会高很多——这招叫**上下文增强**，成本几乎为零，效果明显。

---

## 二、混合检索：向量 + 关键词

纯向量检索有个盲区：**它擅长语义相似，不擅长精确匹配**。

用户搜「错误码 5023」，向量可能给你一堆「错误处理」的段落，但就是没有 5023。关键词检索（BM25）则一定能命中那串数字。

反过来，用户问「系统崩了怎么办」，BM25 匹配不到（文档里可能写的是「服务不可用」），但向量能找到。

**两个一起用，互相补盲区**：

```python
def hybrid_search(query, k=5, alpha=0.5):
    """alpha 控制向量/关键词的权重"""
    vec_results  = vector_search(query, k * 2)      # 按相似度排序
    bm25_results = bm25_search(query, k * 2)        # 按关键词打分

    # RRF： reciprocal rank fusion，把两个排名融合
    scores = {}
    for rank, doc in enumerate(vec_results):
        scores[doc.id] = scores.get(doc.id, 0) + alpha / (60 + rank)
    for rank, doc in enumerate(bm25_results):
        scores[doc.id] = scores.get(doc.id, 0) + (1 - alpha) / (60 + rank)

    return sorted(scores.items(), key=lambda x: -x[1])[:k]
```

那个 `1 / (60 + rank)` 是 **RRF（倒数排名融合）**——不需要两个分数可比，只用排名，简单且鲁棒。60 是经验常数，用来压低低位的权重。

---

## 三、Rerank：召回之后再排一次

检索分两步会更准：

```
粗排（召回）：向量/关键词，快，从百万里挑 50 条
重排（Rerank）：交叉编码器，慢，把 50 条精排成 5 条
```

**为什么要两步？** 因为向量检索是「各自算一个向量再比相似度」（双塔），计算快但精度有限；Rerank 是把「问题和文档」**拼在一起**送进模型打分（交叉编码），精度高但慢。先用快的缩小范围，再用准的排顺序。

```python
from sentence_transformers import CrossEncoder

reranker = CrossEncoder("BAAI/bge-reranker-base")   # 中文效果不错

def retrieve_with_rerank(query, k=5):
    candidates = hybrid_search(query, k=50)          # 先粗召回 50 条
    pairs = [(query, doc.text) for doc in candidates]
    scores = reranker.predict(pairs)                 # 精排打分
    ranked = sorted(zip(candidates, scores), key=lambda x: -x[1])
    return [doc for doc, _ in ranked[:k]]
```

实测上，**加一层 Rerank 通常能把命中率提升 10~20 个百分点**，代价是几十毫秒延迟。性价比很高，是进阶 RAG 的第一优先项。

---

## 四、查询改写：用户的问题往往不适合直接检索

用户的问题和文档的语言风格差很远。三种改写手段：

**1. 指代消解**——多轮对话里最常见

```
历史：年假上限是多少？ → 15 天
新问题：那加班呢？        ← 直接检索"那加班呢"必然失败
改写后：加班费如何计算？
```

**2. 拆分子问题**——复杂问题一次检索不够

```
原问题：对比 A 产品和 B 产品的价格和保修期
拆分：A 产品的价格 / B 产品的价格 / A 的保修期 / B 的保修期
```

**3. HyDE**——让模型先「编一个答案」再拿去检索

```python
def hyde(query):
    """先让模型生成一个假答案，用假答案去检索（它更接近文档语言）"""
    fake = llm.invoke(f"请简短地写一段回答（可以不确定）：{query}")
    return retrieve(fake.content)
```

HyDE 听着反直觉（拿幻觉内容去检索？），但有效——因为生成的假答案在**语义空间上更接近真实文档**，比原始问句更容易匹配到。

---

## 五、排查方法论：答案不对时，按这个顺序查

90% 的「RAG 不准」都能定位到具体环节。按这个顺序排查：

```
第 1 步：正确片段有没有被召回来？
        └─ 没有 → 问题在【检索】：换 embedding / 调切分 / 加混合检索
        └─ 有  → 继续第 2 步

第 2 步：召回的片段里，正确答案排在第几位？
        └─ 在 top-5 之外 → 加 Rerank
        └─ 在 top-3 之内 → 继续第 3 步

第 3 步：模型有没有用上这个片段？
        └─ 没用 → 问题在【生成】：改提示词，强调"只用资料"
        └─ 用了但答错 → 继续第 4 步

第 4 步：片段本身是不是不完整？
        └─ 是 → 回去调切分策略
```

**先量化再优化**。建 20~50 条测试问题，每条标注「正确的片段是哪个」，然后测两个指标：

- **召回率@5**：正确片段在前 5 条里的比例；
- **答案准确率**：最终答案对不对。

只看第二个指标会让你瞎调——因为排查不出到底是哪一环出问题。

---

## 六、小结

1. **切分要按文档类型定制**，每个块带上标题（上下文增强），成本近乎零、收益明显。
2. **混合检索**（向量 + BM25 + RRF 融合）能补掉纯向量的精确匹配盲区。
3. **Rerank 是性价比最高的进阶手段**，粗召回 50 条再精排成 5 条，命中率通常能提 10~20 个点。
4. **查询改写**解决「用户问法」和「文档写法」的鸿沟：指代消解、问题拆分、HyDE。
5. **排查要分层**：先查召回、再查排序、最后查生成，建小评测集量化，别凭感觉调。

到这里 RAG 的主线就完整了。下一篇讲向量数据库——它是 RAG 的地基，选型直接影响你能撑多大数据量、多快响应。
