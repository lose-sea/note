# Docling 实战：把 PDF 变成 RAG 能吃的干净 Markdown

RAG 系统的召回质量，一半死在"入库"这一关。用 `pypdf` 一把梭导出的文本，标题和正文粘在一起、表格变成乱码、两栏排版读起来像洗牌过的纸条——后面 embedding 得再好，也救不回被破坏的结构。Docling 是 IBM 开源的版面感知解析库，出路就在这：它不做"纯文本提取"，而是先理解版面（标题、段落、表格、图），再输出结构化结果。这篇文章讲透 Docling 怎么用、输出什么、怎么接进 RAG 管线、以及和 Unstructured 怎么选。

## 一、为什么"解析"是 RAG 的第一道生死线

先看一组对比。一篇典型的技术 PDF，用朴素方式提取：

```
3.2 索引优化 CREATE TABLE t (id INT, ...) 图3-1 B+树结构 ... InnoDB 使用 B+树作为默认索引结构，其高度通常为3层...
```

标题、代码块、图注、正文全糊在一起。这种文本进向量库的后果：

- **切分（chunking）失控**：按 512 字硬切，半句代码半段正文，语义完整性归零；
- **检索串味**：用户搜"索引高度"，召回的是混着图注和代码的片段，答案靠模型硬编；
- **表格报废**：财务表、对比表被拉平成一行行数字，"列"的信息全丢。

**解析的质量上限，就是召回质量的上限。** 这就是版面感知解析工具存在的意义。

## 二、Docling 是什么

Docling（IBM 开源，2024 年发布）的核心能力：

| 能力 | 说明 |
|---|---|
| **版面分析** | 识别标题、段落、表格、图片、列表、代码块、页眉页脚 |
| **阅读顺序还原** | 多栏排版按正确阅读顺序输出，不是按 PDF 绘制顺序 |
| **表格结构识别** | 输出带表头的结构化表格（HTML/Markdown），不是拉平文本 |
| **公式识别** | LaTeX 公式识别（基于 Nougat 系模型） |
| **多格式输入** | PDF、DOCX、PPTX、HTML、图片 |
| **本地运行** | 模型可完全本地跑，无 API 依赖 |

安装：

```bash
pip install docling
```

## 三、上手：从 PDF 到 Markdown 十分钟

### 3.1 最小用例

```python
from docling.document_converter import DocumentConverter

converter = DocumentConverter()
result = converter.convert("report.pdf")

# 导出 Markdown
md = result.document.export_to_markdown()
print(md)

# 带完整路径
from pathlib import Path
Path("output/report.md").write_text(md, encoding="utf-8")
```

跑完后看输出——标题会是 `#` 层级，表格是标准 Markdown 表格，图片留 `<!-- image -->` 占位。**这一步的输出质量，直接替代传统 `pdfplumber + 正则洗数据` 的几百行脏活。**

### 3.2 命令行批处理

```bash
docling report.pdf --output output_dir
# 支持整个目录
docling ./pdfs/*.pdf --output output_dir
```

### 3.3 结构化输出：JSON 文档树

Markdown 之外，Docling 还能导出**带坐标和元数据的文档树**：

```python
doc = result.document

# 遍历文档结构
for item in doc.iterate_items():
    print(item.label, item.text[:50])   # 'title' / 'table' / 'paragraph' ...

# 拿到所有表格（结构化的）
for table in doc.tables:
    print(table.export_to_dataframe())  # 直接转 pandas DataFrame
```

**这个 JSON 树是精细化 RAG 的原料**：可以按"标题层级 + 表格"组成智能 chunk——比如"以三级标题为界切 chunk，表格整体作为一个 chunk 附带表头上下文"，比无脑按字数切好一个量级。

### 3.4 表格导出的正确姿势

```python
from docling.document_converter import DocumentConverter

converter = DocumentConverter()
result = converter.convert("financial_report.pdf")

for i, table in enumerate(result.document.tables):
    df = table.export_to_dataframe()
    print(f"表格 {i}: {df.shape}")
    print(df.head())
```

表格整体进 chunk 时，建议在表前注入一句话上下文（"下表为 2026 年 Q1 各区域营收"）——表格单独进向量库时，"这是哪张表"的上下文丢失，是表格检索的头号问题。

## 四、接进 RAG 管线

标准接入代码：

```python
from docling.document_converter import DocumentConverter
from langchain_text_splitters import MarkdownHeaderTextSplitter
from langchain_openai import OpenAIEmbeddings
from langchain_chroma import Chroma

# 1. 解析
converter = DocumentConverter()
result = converter.convert("manual.pdf")
md = result.document.export_to_markdown()

# 2. 按 Markdown 标题层级切分（保留标题上下文）
splitter = MarkdownHeaderTextSplitter(
    headers_to_split_on=[("#", "H1"), ("##", "H2"), ("###", "H3")]
)
chunks = splitter.split_text(md)

# 3. 向量化入库
emb = OpenAIEmbeddings()
vs = Chroma.from_documents(chunks, emb, persist_directory="./db")
```

这套组合的关键：**MarkdownHeaderTextSplitter 按标题切**，每个 chunk 自动带上所属 H1/H2/H3 路径前缀，检索时"这段属于哪章哪节"的信息不丢。Docling 输出规范 Markdown，两者是天作之合。

### 4.1 图片和图表怎么处理

Docling 默认在 Markdown 里留图片占位符。两种后续策略：

1. **VLM 描述法**（推荐）：对每个图片调多模态模型（如 GPT-4o、Qwen-VL）生成描述文本，把描述文本当作 chunk 入库，并在占位处替换。检索到描述就定位到原图。
2. **纯视觉检索**：图片走 CLIP/ColPali 多模态向量库（下一篇展开），和文本检索结果融合。

**注意图片描述的质量是检索质量的上限**：描述要包含"图类型 + 主题 + 关键数据"，比如"图3：公司 2026 年营收趋势柱状图，Q1 12 亿、Q2 15 亿、Q3 18 亿"。只写"一张柱状图"等于没写。

### 4.2 速度与资源

Docling 的版面分析基于视觉模型，**比纯文本解析慢一个量级**：单页 PDF 约 1~3 秒（GPU 更快）。实操建议：

- 批量入库走离线批处理，别在线同步转换；
- 页数多的大文档先试试 `--num-threads` 并行；
- 纯文本型 PDF（无复杂版面）可以考虑降级到 `pypdf`，Docling 的重量级模型用在刀刃上。

## 五、Docling vs Unstructured：怎么选

两大主流解析工具的对比：

| 维度 | Docling | Unstructured |
|---|---|---|
| 出身 | IBM 开源 | Unstructured AI（商业公司） |
| 开源完整度 | 完全开源 | 开源版功能阉割，高级特性在付费版 |
| 表格识别 | 强（TableFormer） | 强（商业版更强） |
| 部署 | pip 装完本地跑 | 需 API/自建服务（Docker） |
| 输出格式 | Markdown/JSON/Doctag | JSON/elements |
| LangChain 集成 | 有官方 loader | 有官方 loader |
| 费用 | 免费 | 按页计费（API）或订阅（自建高级版） |

**选型建议**：

- 数据敏感、要本地部署、预算有限 → **Docling**，pip 一行装完，全本地；
- 已在使用 Unstructured API 且不介意费用 → 继续用；
- 表格是核心资产（财报、合同）→ 两个都试，各导 20 页人工评估表格还原度，**用你的数据测，别看 benchmark**。

## 六、落地检查清单

- [ ] 抽样 10 份代表性文档（覆盖表格、多栏、图文）人工评估输出质量；
- [ ] 确认阅读顺序正确（多栏文档重点看）；
- [ ] 表格识别抽查：表头对齐、合并单元格、数字精度；
- [ ] chunking 策略定为"标题层级切 + 表格整体 chunk + 图片描述注入"；
- [ ] 图片描述模板确定（图类型+主题+关键数据）；
- [ ] 批处理流水线化：解析 → 校验 → 入库，失败重试；
- [ ] 解析产物（Markdown + JSON）单独归档，重建索引不用重解析——**解析是重活，缓存是必须的**。

## 七、小结

Docling 的三句话：

- **RAG 的召回上限由入库质量决定**，纯文本提取丢掉的标题、表格、阅读顺序，后面拿不回来；
- **Docling 的产出是规范 Markdown + 结构化 JSON**，按标题层级 chunk、表格整体成块、图片走 VLM 描述，三步即成高质量管线；
- **解析是重计算，产物必须缓存**——Markdown 和 JSON 归档好，重建索引零成本。

下一篇讲 Unstructured：另一条技术路线怎么把 PDF/Word/邮件统一转成 elements 流，以及它和 Docling 的分工。
