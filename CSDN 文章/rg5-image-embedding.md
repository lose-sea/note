# 图文混排检索实战：图片怎么进向量库、怎么被检索到

技术文档的图表、产品手册的示意图、合同里的印章位置——看图说话类query（"那个架构图里缓存层画在哪"）在纯文本 RAG 里永远答不好，因为图从来没进过索引。但"把图片也向量化"这句话说起来简单，做起来有一连串工程决策：图片用什么表示、描述文本怎么写、图文怎么统一排序、命中之后怎么把原图还给用户。这篇文章把这条链路完整走一遍。

## 一、先想清楚：图片进索引的三种路线

| 路线 | 表示方式 | 检索方式 | 适用 |
|---|---|---|---|
| **A. 描述文本** | VLM 生成描述 → 文本向量 | 文本语义搜索 | 绝大多数场景的首选 |
| **B. 图像向量** | CLIP/SigLIP 编码图像本身 | 图搜图、文搜图 | 以图为主的素材库 |
| **C. 页级视觉** | ColPali 整页编码 | late interaction | 视觉密集文档（前一篇） |

三条路线的选择逻辑：

- 文档里**插图是辅助**（配图说明正文）→ 路线 A，描述文本和正文一起走文本索引，简单有效；
- 素材库以**图为主体**（设计素材、商品图）→ 路线 B；
- 整页都是信息（财报、论文）→ 路线 C。

**路线 A 是主力**，本文重点展开，顺带讲 B 的混合用法。

## 二、路线 A：VLM 描述文本的标准流程

### 2.1 描述生成：提示词决定上限

图片进向量库之前，先用多模态模型生成一段描述文本。这段文本的质量直接决定后续检索质量——**描述里没有的信息，检索永远找不到**。

```python
from openai import OpenAI
import base64

client = OpenAI()

def describe_image(image_path: str, context: str = "") -> str:
    b64 = base64.b64encode(open(image_path, "rb").read()).decode()
    
    prompt = f"""请为这张文档插图生成检索用描述。要求：
1. 说明图的类型（架构图/流程图/截图/照片/示意图）；
2. 概括图的主题和核心内容；
3. 提取图中的关键文字、数字、标签（如果有）；
4. 如果图表达了某种关系、流程、结构，要说清楚。

文档上下文（图片所在章节，可能相关也可能无关）：
{context}
"""
    resp = client.chat.completions.create(
        model="gpt-4o",
        messages=[{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {
                    "url": f"data:image/png;base64,{b64}"
                }}
            ]
        }],
        max_tokens=400
    )
    return resp.choices[0].message.content
```

几个决定成败的细节：

1. **注入章节上下文**：图片在原文里往往依赖上文（"下图展示了..."），把图片前后的标题和段落一起喂给 VLM，描述会准确得多；
2. **要求提取关键文字**：图里的"Q3 营收 18 亿"这种数字，是最高频的检索目标，必须显式要求提取；
3. **结构化优于散文**：让 VLM 按"类型/主题/关键元素/关系"分点输出，切分和 embedding 都受益；
4. **批量 + 缓存**：一次入库几千张图，VLM 调用要并发 + 失败重试，描述结果和图片路径一起落库——**别重复生成**，重跑索引不重复烧钱。

本地开源替代：Qwen-VL、InternVL，消费级显卡能跑 7B 版本，描述质量够用，成本是机器不是 API 费。

### 2.2 切分与入库：图 chunks 怎么组织

描述文本不是孤立入库的，它要嵌回文档结构：

```
图块设计（一个图对应一~两个 chunk）：

chunk-图1: 
  [元数据] 图类型=架构图, 页码=12, 章节=3.2 系统架构, 图片路径=img/p12_fig1.png
  [内容] 图 3-2 系统架构图。该图展示了三层架构：接入层（Nginx+Gateway）、
         服务层（Order/Payment 微服务）、数据层（MySQL 主从 + Redis 集群）。
         图中标注 QPS 峰值为 12k，缓存命中率要求 95%。

chunk-图1-正文关联:
  [内容] 见图 3-2。接入层负责...
```

设计要点：

- **页码 + 章节 + 图片路径进 metadata**：这是后面"原图追溯"的唯一线索；
- **描述里显式写"图 3-2"编号**：用户问"3-2 那张图"时能命中；
- **描述和相邻正文分别成块但互相引用**：检索到任一边，都能带上另一边的上下文。

### 2.3 混合排序：图文结果怎么融

用户查询可能命中文本 chunk，也可能命中图 chunk。两路结果的融合排序是核心问题：

**方案 1：RRF（Reciprocal Rank Fusion）**——无脑融合，不问分数哪来：

```python
def rrf_fuse(text_results, image_results, k=60):
    scores = {}
    for rank, doc in enumerate(text_results):
        scores[doc.id] = scores.get(doc.id, 0) + 1 / (k + rank + 1)
    for rank, doc in enumerate(image_results):
        scores[doc.id] = scores.get(doc.id, 0) + 1 / (k + rank + 1)
    return sorted(scores.items(), key=lambda x: -x[1])
```

**方案 2：rerank 统一打分**——两路结果（文本 chunks + 图 chunks，以及可选的 ColPali 命中页原图）交给 cross-encoder reranker 统一排序，质量最高，成本也多一次模型调用。

**实践建议**：默认 RRF 融合，对质量敏感的核心场景上 rerank。融合时图 chunks 可以适度加权——用户搜"架构图"，命中的图块优先级应该高于顺带提到"架构图"三个字的正文。

## 三、路线 B：CLIP 图像向量的混合用法

有些场景文本描述会失真——摄影图、设计图、UI 截图，VLM 描述能写，但"看起来像不像"这件事描述文本抓不住。这类图加一条 CLIP 向量索引：

```python
from transformers import CLIPModel, CLIPProcessor

model = CLIPModel.from_pretrained("openai/clip-vit-base-patch32")
processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")

# 图 → 向量
inputs = processor(images=[image], return_tensors="pt")
img_vec = model.get_image_features(**inputs)
img_vec = img_vec / img_vec.norm(dim=-1, keepdim=True)

# 文 → 向量（同一空间，可以直接比）
inputs = processor(text=["a dashboard with bar charts"], return_tensors="pt")
txt_vec = model.get_text_features(**inputs)
txt_vec = txt_vec / txt_vec.norm(dim=-1, keepdim=True)

similarity = (txt_vec @ img_vec.T).item()   # 0~1
```

CLIP 索引的角色是**"以图搜图"和视觉相似度兜底**，和文本索引、ColPali 页索引并列成三路，RRF 融合。CLIP 对细粒度文字（图里的小字）不敏感，别指望它做"图里数字是多少"的查询——那是路线 A/C 的活。

**CLIP + 描述文本的最佳拍档**：描述文本负责"图里有什么"（语义层），CLIP 负责"图长什么样"（视觉层）。设计素材库、电商图搜是两个领域的标配组合。

## 四、命中之后：原图追溯与展示

检索到"图 chunk"只是开始，用户体验的最后一公里是**把用户带到图本身**：

1. **答案里带图**：生成阶段，如果召回里有图 chunk，把 `metadata.图片路径` 对应的图片 asset URL 一并放进引用列表，前端渲染成"答案 + 引用卡片（含图缩略）"；
2. **点击定位原文档**：引用卡片记录 `文件名 + 页码`，点击跳转到 PDF 预览并定位到该页该图；
3. **溯源 metadata 标准化**：图块的 metadata 至少包含 `doc_id`、`page`、`figure_no`、`image_path`、`section`——缺一项，追溯链路就断；
4. **图片存储与索引分离**：原图放对象存储，向量库只存路径。重建索引不搬图，CDN 加速展示。

## 五、流水线全景：一张图收尾

```
文档解析（Docling/Unstructured 产出带图片占位的结构）
   │
   ├─ 图片单独提取 → 对象存储（原图 + 缩略图）
   │
   ├─ 图片 + 章节上下文 → VLM 生成描述文本（批量、缓存、并发）
   │
   └─ 描述文本 → chunk 化 → 文本向量索引
                        （metadata: doc_id/page/figure_no/image_path/section）

用户查询
   │
   ├─ 文本索引检索 ──┐
   ├─ CLIP 索引检索 ──┼→ RRF/rerank 融合 → Top-K
   └─（可选）ColPali ─┘
   │
   └→ 生成阶段：召回的图 chunk → 带上原图 URL → 前端"答案 + 带图引用"
```

## 六、成本与质量检查清单

**成本控制**：

- [ ] VLM 描述调用：批量并发 + 结果落库缓存，重建索引不重复调用；
- [ ] 描述文本控制在 200~400 token，别让 VLM 写小作文；
- [ ] 低价值图片（logo、装饰线）提前过滤进库——用尺寸/位置启发式规则，别无脑全描述。

**质量检查**：

- [ ] 抽 20 张人工评 VLM 描述：关键数字、关系、类型是否抓准；
- [ ] 构造图查询测试集（"那张三层架构图"、"Q3 营收柱状图"），验证图召回率；
- [ ] 混合排序调参：图块权重上界下界各测一轮；
- [ ] 端到端验证：答案引用里的图片能点开、页码对得上。

## 七、小结

图文混排检索的四句话：

- **首选路线是 VLM 描述文本**：注入章节上下文、要求提取关键文字、结构化输出、结果缓存；
- **从没人检索的图 = 不存在的图**：描述里没写的信息，查询永远命中不了，描述质量就是图上限；
- **融合排序走 RRF 起步**，图块适度加权，核心场景再上 rerank；
- **metadata 决定追溯**：`doc_id/page/figure_no/image_path/section` 五件套配齐，"点击引用看到原图"的体验才闭环。

下一篇讲 GraphRAG：微软开的知识图谱增强检索，怎么用图的多跳能力补向量检索的短板。
