# ColPali 实战：不解析、不切分，把 PDF 页面当图片做检索

传统 RAG 对 PDF 的处理链条是"解析 → 切分 → 向量化"——链条越长，信息损失越多，而且文档里那些**真正承载信息的视觉元素**（图表、排版、连线、印章位置）在纯文本化时全丢了。ColPali 提出了一个激进思路：**PDF 页面本身就是最好的文档表示**，跳过解析，直接把页面截图编码成向量。这篇文章讲透这个范式：ColPali 怎么工作、late interaction 是什么、精度到底强多少、什么场景值得上、以及工程上的成本账。

## 一、传统管线的病灶在哪里

先复盘一下经典 RAG 管线在文档检索上的三重损失：

1. **解析损失**：表格被拉平、图表没文字、复杂排版阅读顺序错乱。前两篇文章讲的 Docling/Unstructured 都在跟这个搏斗；
2. **切分损失**：一个跨页的表格、一段被图断开的说明文，切完语义破碎；
3. **语境损失**：chunk 离开原文档后，"这段属于哪个产品手册的哪一章"要靠元数据勉强维系。

ColPali 的思路是把这三层全部掀翻：**不做解析、不做切分**，文档库的每一页渲染成一张图，用视觉语言模型（PaliGemma 系）编码成一个多向量表示。查询进来，也是向量比对。图表里的信息？原样在图像里，没损失。表格结构？视觉模型看得见。

## 二、ColPali 的技术核心：late interaction

ColPali 的三个关键词，逐个拆：

### 2.1 文档 = 图像（page-as-image）

每一页 PDF 渲染成 1024×1024 左右的图像，**不提取任何文字**。编码器是 PaliGemma（Google 的视觉语言模型），输出不是单个向量，而是一个**多向量序列**——类似 ColBERT 的思路：每个 patch（图像块）对应一个向量。一页文档 ≈ 1000 个 patch 向量。

### 2.2 Late Interaction（迟交互）

双塔模型（分别编码查询和文档，最后内积）的问题：查询和文档在编码时互相看不见，细粒度匹配被压成一个向量。ColBERT/ColPali 的 late interaction 反过来——两边都保留 token/patch 级别的向量序列，**在检索时才做细粒度交互**：

```python
# 示意：查询每个 token 找文档里最匹配的 patch，求和
score = sum(max_similarity(query_token_vec, doc_patch_vecs) 
            for query_token_vec in query_vectors)
```

含义："查询里的'柱状图'这个词，在文档第 3 个 patch 里找到强匹配；'Q3 营收'在第 7 个 patch 也有"——**词级别的多点匹配**，比单向量内积精确得多，尤其适合"多个信息点组合"的查询。

### 2.3 视觉 token 化（PaliGemma）

PaliGemma 把图像切成 patch 后线性投影成"伪 token"，和文本 token 混在一起过 Transformer。所以 ColPali 编码文档时，每个图像 patch 都是一个 token；编码查询时就是普通文本 token。两边在同一个语义空间里——这是"文本查图像"能成立的根本。

## 三、上手：索引 1000 页 PDF 要多久

```bash
pip install colpali-engine
```

```python
import torch
from colpali_engine.models import ColPali, ColPaliProcessor
from PIL import Image

model = ColPali.from_pretrained(
    "vidore/colpali-v1.2",
    torch_dtype=torch.float16
).to("cuda")
processor = ColPaliProcessor.from_pretrained("vidore/colpali-v1.2")

# 1. 编码查询
queries = ["2026 年第三季度华东区销售额是多少？"]
batch_queries = processor.process_queries(queries).to("cuda")
with torch.no_grad():
    Q = model(**batch_queries)   # [查询数, token数, 128]

# 2. 编码文档页（这里是一页 PDF 的渲染图）
images = [Image.open("page_027.png")]
batch_images = processor.process_images(images).to("cuda")
with torch.no_grad():
    D = model(**batch_images)     # [页数, patch数, 128]

# 3. 打分（late interaction）
scores = processor.score_multi_vector(Q, D)   # 内置 MaxSim 实现
print(scores)   # [[0.87]] 越高越相关
```

真实体验：T4 显卡上，单页编码约 0.3 秒，1000 页 PDF ≈ 5 分钟。**建立索引是一次性的**，之后查询侧快到毫秒级（只编码查询那几句话）。存储账：每页 1030 个 128 维向量 ≈ 525KB，1000 页 ≈ 500MB——比文本 chunk 索引大了几十倍，这是真实的成本，要用支持多向量检索的向量库（Qdrant、Vespa 支持 multi-vector；传统单向量库要改造）。

## 四、效果：ViDoRe benchmark 上的碾压

ColPali 论文在 ViDoRe（视觉文档检索基准）上对比传统管线，结论是**全面领先**，尤其是这几类文档：

| 文档类型 | ColPali 优势 | 原因 |
|---|---|---|
| 图表密集（财报、仪表盘） | 极大 | 文本管线根本抽不出图表里的数字 |
| 表格密集 | 大 | 表格结构视觉上一目了然 |
| 扫描件/手写 | 大 | OCR 差的场景，VLM 直接读 |
| 图文混排（论文、杂志） | 明显 | 阅读顺序天然正确 |
| 纯文字连续文档 | 小 | 文本管线本来就擅长 |

**但要清醒**：领先是相对"朴素文本管线"的领先。如果你已经用 Docling 做了高质量解析、表格单独成块、图片走 VLM 描述，文本管线的效果不一定输——**ColPali 打的是"低质量解析"的场景**。领域越专业（医学报告、工程图纸、财报），视觉信息的比重越大，ColPali 的优势越明显。

## 五、ColPali 与文本 RAG 的合体：混合检索

生产系统的务实姿势不是二选一，而是**两条索引并行，结果融合**：

```
查询进入
  ├─→ 文本向量索引（chunk 级）──→ 命中 chunk A1, A2, A3
  └─→ ColPali 图像索引（页级）──→ 命中页 P12, P30, P31
        ↓
  RRF 融合排序（两个榜单取交集靠前者加权）
        ↓
  生成阶段：文本 chunk + 命中页面原图一起喂给 VLM
```

混合架构的几个要点：

1. **生成侧升级成 VLM**：既然检索到了页面图像，答案生成就可以直接看图讲图——GPT-4o、Claude、Qwen-VL 这一代模型对图表的理解远超"图表文字化再读"；
2. **页级粗排 + chunk 级精排**：ColPali 命中"页"，再在页内定位具体 chunk，兼顾视觉优势和粒度；
3. **索引成本分开管**：文本索引便宜，全库都建；ColPali 索引贵，只对"视觉密集"的文档子集建（按解析时统计的图片占比路由）；
4. **答案溯源更强**：ColPali 命中直接对应原始页面，引用溯源天然精确到"第几页第几图"，比文本 chunk 的定位更硬。

## 六、成本与限制：上生产前算清账

**成本三笔账**：

1. **索引成本**：每页一次 VLM 编码，GPU 时长和页数线性相关。10 万页文档 ≈ 8 小时 T4——离线跑，可接受，但要规划；
2. **存储成本**：多向量索引是文本索引的几十倍（上面算过 500MB/千页），内存驻留成本更高；
3. **生成成本**：走 VLM 生成比纯文本 LLM 贵（按 token 算，图像 token 消耗大），每次问答都带图的话，成本翻几倍。

**能力边界**：

- **小字/密表有上限**：1024 分辨率下，8pt 以下的密表格，人眼看着都费劲，模型也一样。高分辨率扫描件要先评估；
- **纯文本检索精度**：对纯文字段落级的细粒度匹配（"第三段第二句"），文本索引 + BM25 仍不可替代；
- **多语言**：PaliGemma 基座的多语言能力一般，中文文档要测试（社区有中文微调版，注意许可证）；
- **不能做传统的"附近块扩展"**：向量检索的上下文扩展策略（取命中 chunk 前后各一段）在页级粒度上不适用，要靠别的机制补。

## 七、落地路线建议

分三步走，别一步到位：

1. **验证期**：拿 200 页你们最典型的"难文档"（表格图密集的），人工标注 20 个查询，对比文本管线和 ColPali 的 Top-5 命中率——用你们的数据说话；
2. **混合期**：确认视觉文档子集收益后，搭混合架构——文本索引全量 + ColPali 只覆盖视觉密集子集，生成侧试点 VLM；
3. **优化期**：按检索日志分析哪类查询走哪条链路，做查询路由；监控索引成本和检索质量，调路由阈值。

## 八、小结

ColPali 的三句话：

- **文档即图像**：跳过解析和切分，页面原样编码，表格图表信息零损失，视觉密集文档（财报、论文、扫描件）上碾压文本管线；
- **late interaction 是精度之源**：查询 token 与文档 patch 做多点 MaxSim 匹配，抓住"多信息点组合"的查询；
- **生产上走混合架构**：文本索引全量 + ColPali 覆盖视觉密集子集，生成侧用 VLM 直接读图，成本和精度各取所需。

下一篇讲图文混排检索的工程细节：图片怎么描述、怎么和文本统一索引、以及命中图之后怎么追溯原图。
