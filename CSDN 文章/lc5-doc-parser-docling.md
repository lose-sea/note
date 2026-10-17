# Docling：版面感知的文档转换，学术 PDF 的 Markdown 之路

上一篇文章讲了 Unstructured——多格式通吃、和 RAG 管道集成度高的解析老将。这篇看另一条技术路线：Docling。它源自 IBM 研究院，打法很聚焦：**把各种文档高质量转成统一的、结构化的 Docling Document，再导出 Markdown/JSON**。对学术论文、技术报告这类结构复杂的文档，它的输出质量是另一档的存在。

## Docling 解决的核心问题：阅读顺序

先看一个所有 PDF 解析器共同的噩梦。一篇双栏排版的论文，页面上文字块的物理顺序（左栏从顶到底、再读右栏）和阅读顺序完全不同。naive 提取器按坐标顺序扫，抽出来的文本是"左栏第一句 + 右栏第一句 + 左栏第二句 + 右栏第二句"的怪异穿插，语义全毁。

Docling 的核心正是一个 **PDF 版式分析模型**：先对页面做版面分析（区分标题、正文、公式、图表、表格），再重建正确的阅读顺序，输出一个带层级的文档树。再往后，公式识别转 LaTeX、表格识别转结构化 HTML、代码块识别保留代码格式——它做的事本质上是"机器阅读"，而不是"文本抽取"。

## 安装与第一个例子

```bash
pip install docling
```

```python
from docling.document_converter import DocumentConverter

converter = DocumentConverter()
result = converter.convert("paper.pdf")

# 转 Markdown：干净的标题层级 + 表格 + LaTeX 公式
markdown = result.document.export_to_markdown()
print(markdown[:1500])
```

跑一份带公式的论文，输出大致长这样：

```markdown
## 3. Method

### 3.1 Attention Mechanism

We compute the attention weights as:

$$\text{Attention}(Q,K,V) = \text{softmax}(\frac{QK^T}{\sqrt{d_k}})V$$

| Layer | Dimension | Accuracy |
|-------|-----------|----------|
| 1     | 512       | 91.2%    |
| 2     | 1024      | 93.5%    |
```

对比朴素 PDF 抽取器对同一篇的输出——公式变成一串散乱符号、表格数字错位、章节层级全平——差别一眼可见。对"喂给 LLM 的上下文"来说，**阅读顺序正确 + 公式表格结构保留，直接决定模型能不能正确理解论文在讲什么**。

## Docling 的完整能力面

不只会转 PDF，它是一个统一文档转换框架：

- **输入格式**：PDF、DOCX、PPTX、XLSX、HTML、图片（含扫描件 OCR）、Markdown、AsciiDoc、CSV。
- **输出格式**：Markdown、HTML、JSON（DoclingDocument 结构化树）、纯文本。
- **内部模型栈**（全部可本地运行，除 OCR 外默认已带）：
  - 版面分析模型：识别标题、正文、表格、公式、代码块、图表、页眉页脚等约 10 类区域。
  - TableFormer：表格结构识别（行列 + 跨行跨列表头），这是 Docling 口碑最好的部分，解析出来的表格保留合并单元格结构。
  - 公式识别：转 LaTeX。
  - 代码识别：识别代码块区域并保留格式。
  - OCR（EasyOCR/Tesseract/RapidOCR 可选配）：扫描件用。

后端和模型可换：`PdfPipelineOptions` 里能调 OCR 引擎、表格模式（fast/accurate）、要不要生成页面/元素级图片。

## 代码示例：自定义管道

```python
from docling.document_converter import DocumentConverter
from docling.datamodel.pipeline_options import PdfPipelineOptions
from docling.backend.pagenumber import PageNumberTracker

options = PdfPipelineOptions()
options.do_ocr = True                       # 扫描件开 OCR
options.ocr_engine = "rapidocr"             # 中文扫描件比 easyocr 快
options.do_table_structure = True           # 表格结构识别
options.table_structure_mode = "accurate"   # fast 快但牺牲合并单元格识别
options.generate_page_images = True         # 想拿页面截图时开
options.images_scale = 2.0

converter = DocumentConverter(pipeline_options=options)
doc = converter.convert("scan_report.pdf").document

# 遍历结构化文档树：拿到带类型的元素流
for item, level in doc.iterate_items():
    label = item.label if hasattr(item, "label") else item.__class__.__name__
    if label in ("section_header", "title", "table", "formula"):
        print("  " * level, label, "→", str(item.text)[:60])
```

`iterate_items` 这个遍历方式在做**选择性提取**时特别有用：只要标题和表格做目录索引；只要正文做检索。类型化的元素流让你对文档的掌控粒度比"一整块 Markdown"细得多。

## 接进 RAG 管道

Docling 有官方 LangChain 集成：

```python
from langchain_docling import DoclingLoader

loader = DoclingLoader(
    file_path=["paper1.pdf", "paper2.pdf"],
    converter=converter,
)
docs = loader.load()   # 直接出 LangChain Document 列表
```

自己切分的话，Docling 有个别的解析器没有的优势：**它带 hybrid chunk 能力**。`HierarchicalChunker` 按文档层级（章节 → 小节 → 段落）切块，切出来的块自带层级元数据，做引用溯源时能精确到"第 3.2 节的第二段"。

```python
from docling.chunking import HierarchicalChunker

chunker = HierarchicalChunker(max_chunk_size=1200)
for chunk in chunker.chunk(doc):
    print(chunk.text, "| 面包屑:", [h.text for h in chunk.meta.headings])
```

带标题面包屑的块，塞进 prompt 时模型天然知道"这段属于哪个章节"，对多主题混合文档（比如厚财报）的检索质量提升明显。

## Unstructured vs Docling：怎么选

两条路线都摸过了，放一起对比：

| 维度 | Unstructured | Docling |
|---|---|---|
| 出身 | Unstructured AI（商业公司，开源核心） | IBM 研究院 |
| 路线 | 多格式通用 RAG 预处理平台 | 统一文档模型 + 高质量转换 |
| 表格还原 | hi_res 模式较好 | **TableFormer，合并单元格更准** |
| 公式 | 弱（不专门转 LaTeX） | **转 LaTeX，学术场景核心优势** |
| 阅读顺序 | hi_res 版面分析 | 版面分析 + 层级重建 |
| 格式覆盖 | PDF/Office/HTML/邮件等极广 | 同样广，工程名单稍短 |
| 输出 | element 列表（含语义类型） | 统一文档树 → MD/HTML/JSON |
| 速度 | fast 快，hi_res 慢 | 中速（布局模型必需但轻量） |
| 生态集成 | LangChain 官方 loader + staging | LangChain 集成 + chunker |
| 本地部署 | 支持（docker SaaS 也有） | 完全本地，Apache 2.0 |

选择规则很清晰：

- **学术论文、技术文档、含公式和复杂表格**：Docling。这是它的主场，Markdown 输出质量目前开源界第一梯队。
- **企业杂格式文档入库（合同、票据、邮件、扫描件）+ 和 RAG 管道深度集成**：Unstructured。多格式统一、staging 归档、元素过滤这些管道级能力更成熟。
- **两个都要的场景**：实际部署里不少团队确实是"Docling 处理技术文档，Unstructured 处理其他"，入口按文档类型路由。

硬件上两者都是本地模型推理，CPU 可跑（一页数秒），有 GPU 更快。首次运行下载模型（几百 MB 到 1GB+），离线部署要提前把模型文件打进镜像。

## 生产上的三个注意点

1. **解析慢就异步化**。和 Unstructured 一样，accurate 模式的复杂文档一页数秒到数十秒，放消息队列里跑，API 侧只返回 task 状态。
2. **长文档注意内存**。版面模型按页处理，但一个超长合同全 load 成文档树后内存占用可观，配 4G 以上 worker 容器。
3. **中文场景自己测**。Docling 的版面模型训练数据以英文文档为主，中文标题识别、表格表头偶尔有偏差。上线前用自己的中文文档跑一批，和 Unstructured OCR 模式对比着验收——解析质量没有银弹，**只有你自己语料上的实测数据**。

## 结语

Unstructured 和 Docling 代表了文档解析的两个技术极端：一个像瑞士军刀，多格式、管道化、包打企业文档的脏活；一个像手术刀，版面理解深、Markdown/LaTeX 输出干净，专治学术技术文档。RAG 系统的解析层不必二选一，按文档类型路由、产出统一归档，才是成熟的工程答案。下一篇离开文档解析，看怎么把这些干净喂到嘴边的数据变成一个会画表的 Agent。
