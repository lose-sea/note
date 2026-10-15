# 相似度度量怎么选：余弦、点积、欧氏距离的适用场景

> 你已经归一化了，也用余弦了，但检索结果还是"不太对"。
> 问题可能不在度量，**在"相似度分数怎么用"。**
>
> 这篇讲清楚：该选哪个度量，以及分数怎么用才有意义。

## 一、三种度量的几何意义

```
余弦（cosine）：看方向，不看长度
  a = [1, 0], b = [10, 0]  →  cos = 1.0（完全同向）

点积（dot）：方向 × 长度
  a·b = 10   ← 受 b 的长度影响

欧氏（L2）：看距离
  ‖a - b‖ = 9   ← 也被长度影响

归一化后（|a| = |b| = 1）：
  cosine = dot
  L2² = 2 - 2·cosine
  → 三者对排序等价
```

**核心结论：归一化后，三者对排序是等价的。差异只体现在"分数的绝对值"上。**

## 二、选哪个：看模型怎么训练的

**这是唯一的判断依据**——不是"哪个更好"，而是"模型训练时用哪个"。

| 模型 | 训练目标 | 应该用 |
|---|---|---|
| `text-embedding-3-*` | 余弦 | Cosine |
| `bge-*` | 余弦（需归一化） | Cosine |
| `e5-*` | 余弦 | Cosine |
| `m3e-*` | 余弦 | Cosine |
| 部分多模态模型 | 点积 | Dot |
| `all-MiniLM-*` | 余弦 | Cosine |

**为什么重要**：模型训练时优化的目标函数就是某个度量。用别的度量，**相当于在错误的函数上找最优**。

**查模型文档的方式**：

```python
# HuggingFace 模型卡里通常写明了
# "This model is trained with cosine similarity"
# 或者看它的 loss 函数配置
```

## 三、实践建议：默认用余弦

**如果没有特别理由，就用余弦 + 归一化。**

理由：

```
① 绝大多数模型是余弦训练的
② 余弦排除了文本长度的影响（长文档不会因为"模长大"而占优）
③ 向量库对余弦的支持最好
④ 分数范围固定（[-1,1] 或 [0,1]），便于设阈值
```

**标准配置**：

```python
vecs = l2_normalize(model.encode(texts))
vectorstore = Chroma(..., collection_metadata={"hnsw:space": "cosine"})
```

## 四、什么时候用点积

**两种场景**：

**① 模型明确用点积训练**

```python
# 比如某些多模态检索模型
model = SentenceTransformer("model-trained-with-dot")
# 不要归一化！
vecs = model.encode(texts, normalize_embeddings=False)
vs = Chroma(..., collection_metadata={"hnsw:space": "ip"})   # inner product
```

**② 想利用"模长"编码的额外信息**

有些模型会把"重要性"或"置信度"编码进模长——**归一化会丢掉这个信息**。

```
模长大的向量 = 模型更"确信"
→ 保留模长能让"确信的"排更前
```

**这种情况很少见**，且需要模型专门这样训练。

## 五、什么时候用欧氏距离

**现代 embedding 场景几乎不用欧氏距离。**

少数场景：

```
① 向量本身有物理意义（坐标、特征）
② 某些图像检索模型
③ 需要绝对距离而非相对相似度
```

**如果要用，记得归一化**——归一化后：

```
L2² = 2 - 2·cos
→ 排序与余弦一致（L2 越小，cos 越大）
```

**注意：L2 距离是"越小越好"，余弦是"越大越好"。** 搞反了会把最不相关的排最前。

## 六、真正的问题：分数怎么用

**这才是实践中出问题的地方。**

```python
# ❌ 常见错误：直接拿余弦值当"相关度百分比"
"这个结果的相似度是 0.72"   ← 用户以为 72% 相关，其实无法这样解释
```

**余弦 0.72 到底算不算"相关"？** 取决于你的数据和模型：

```
模型 A：不相关文本的余弦约 0.1，相关文本约 0.8
  → 0.72 算比较相关

模型 B：不相关文本的余弦约 0.5，相关文本约 0.9
  → 0.72 算不相关
```

**必须在自己数据上校准。**

## 七、校准方法

```python
def calibrate_scores(eval_set, vectorstore):
    """统计正样本和负样本的分数分布"""
    pos, neg = [], []

    for item in eval_set:
        results = vectorstore.similarity_search_with_relevance_scores(
            item["question"], k=10
        )
        for doc, score in results:
            if item["expected_id"] == doc.metadata["id"]:
                pos.append(score)
            else:
                neg.append(score)

    print(f"正样本：均值 {np.mean(pos):.3f}，P10 {np.percentile(pos,10):.3f}，"
          f"P50 {np.percentile(pos,50):.3f}")
    print(f"负样本：均值 {np.mean(neg):.3f}，P90 {np.percentile(neg,90):.3f}")

    # 建议阈值：正样本 P10 附近（保证 90% 的正样本能通过）
    threshold = np.percentile(pos, 10)
    print(f"建议阈值：{threshold:.3f}")
    return threshold
```

**典型的输出**：

```
正样本：均值 0.78，P10 0.65，P50 0.79
负样本：均值 0.42，P90 0.61
建议阈值：0.65
```

**注意正负分布的重叠区域**：

```
正样本 P10 = 0.65
负样本 P90 = 0.61

→ 重叠区间 [0.61, 0.65] 里，无法区分正负
→ 这个区间是"不确定区"，只能靠重排或规则处理
```

**如果重叠很大**（比如正样本 P10 < 负样本 P90），说明**当前检索方式区分度不够**——该改进检索策略，而不是调阈值。

## 八、分数转换：给用户一个可解释的值

**余弦值不能直接用。做一次单调映射。**

```python
def to_readable_score(cos: float, floor: float = 0.4, ceil: float = 0.9) -> int:
    """把 [floor, ceil] 映射到 [0, 100]"""
    if cos <= floor:
        return 0
    if cos >= ceil:
        return 100
    return int((cos - floor) / (ceil - floor) * 100)
```

**如果用这个，必须在 UI 上说明**"这是相对分数，不是概率"。

**更好的做法：用"高中低"三档，不暴露数字**：

```python
def to_level(cos: float, high: float = 0.8, mid: float = 0.6) -> str:
    if cos >= high:
        return "高度相关"
    if cos >= mid:
        return "相关"
    return "弱相关"
```

**用户对"高度相关"的理解，比"0.82"要准确得多。**

## 九、L2 和余弦的转换公式

**如果向量已归一化**：

```python
def l2_to_cosine(l2_dist: float) -> float:
    """L2 距离转余弦（要求向量已归一化）"""
    # L2² = 2 - 2cos  →  cos = 1 - L2²/2
    return 1 - (l2_dist ** 2) / 2

def cosine_to_l2(cos: float) -> float:
    return math.sqrt(max(0, 2 - 2 * cos))
```

**这个转换在"向量库返回 L2，但你想用余弦阈值"时很有用**：

```python
# FAISS 返回 L2 距离
D, I = index.search(qvec, k=10)
scores = [l2_to_cosine(d) for d in D[0]]        # 转成余弦
filtered = [i for i, s in zip(I[0], scores) if s >= THRESHOLD]
```

## 十、几个坑

**① 把"距离"当成"相似度"。**

```python
# ❌ FAISS 返回 L2 距离，越小越好
docs = sorted(results, key=lambda x: -x[1])     # 反了！

# ✅
docs = sorted(results, key=lambda x: x[1])
```

**这是最高频的错误**。不同库的返回含义不同：

| 库 | 返回 | 方向 |
|---|---|---|
| FAISS | L2 距离 | 小 = 相似 |
| Chroma | 距离 | 小 = 相似 |
| Qdrant | 相似度 | 大 = 相似 |
| Milvus | 相似度（COSINE） | 大 = 相似 |
| Redis | 距离 | 小 = 相似 |
| ES | `_score` | 大 = 相似 |

**用之前一定要确认。**

**② 归一化只用在一侧。**
文档归一化了，查询没归一化 → 余弦结果偏。

**③ 混淆"相似度阈值"和"相关性判断"。**
相似度高不等于"这个问题有答案"。**检索到 0.9 相似度的文档，也可能回答不了这个问题**——那是"答案存在性"的判断，不是相似度能解决的。

**④ 用绝对值阈值跨模型。**
0.8 在模型 A 里是"很相关"，在模型 B 里可能是"不相关"。**阈值必须和模型绑定。**

**⑤ 忘了记录索引用的度量。**
换度量不重建索引，结果会完全错乱。

```python
INDEX_META = {
    "model": "text-embedding-3-small",
    "normalized": True,
    "metric": "cosine",
}
```

**⑥ `similarity_search_with_relevance_scores` 的坑。**
LangChain 的这个方法会做归一化转换，**不同向量库的转换方式不同**。**它返回的"relevance score"和原始余弦值可能不一样。**

**要确定的话，用 `similarity_search_with_score` 拿原始值，自己转换。**

## 十一、决策表

| 你的情况 | 选什么 |
|---|---|
| 不确定（默认） | **余弦 + 归一化** |
| 模型文档说用点积 | 点积（不归一化） |
| 想利用模长信息 | 点积 |
| 向量有物理意义 | 欧氏 |
| 用 FAISS 返回 L2 | 换算或直接按升序 |

**无论选哪个，都要做的事**：

```
① 在自己数据上校准阈值
② 记下索引用的模型 + 度量
③ 搞清楚库返回的是"距离"还是"相似度"
④ 给用户展示时做单调映射（或用"高中低"）
```

## 十二、小结

```python
# 标准配置（90% 场景适用）
vecs = l2_normalize(model.encode(texts))          # 归一化
metric = "cosine"                                  # 余弦
threshold = calibrate(eval_set)                    # 校准阈值
display = to_level(score)                          # 展示用"高中低"
```

五条原则：

```
1. 默认用余弦 —— 除非模型明确用别的
2. 归一化后三种度量对排序等价
3. 分数不能直接当"相关度百分比"，必须校准
4. 搞清楚库返回的是距离还是相似度（最高频的坑）
5. 阈值和模型绑定，换模型必须重新校准
```

**一句话：度量的选择本身很简单（默认余弦），难的是"分数怎么解释和怎么用"。** 大多数检索效果不好的问题，**不是度量选错了，而是阈值没校准、距离方向搞反、或者把相似度当成了相关性**。
