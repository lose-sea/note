# Unstructured 实战：把企业里的"脏"文档变成可检索的干净块

RAG 系统的天花板，一半在检索，另一半在**你喂给它的文本质量**。企业真实的文档长什么样：扫描版 PDF（其实是图片）、带页眉页脚和水印的合同、三栏排版的学术论文、嵌套表格的财报——直接 `PyPDFLoader` 抽出来的文本，经常是全文没有段落分隔的字符瀑布，表格内容散落成一堆没有语义词。Unstructured 就是专门收拾这些脏文档的库，这篇文章讲它的架构、怎么用、怎么和 LangChain 串成生产管道。

## 先认清问题：文档解析到底在解什么

把"PDF → 文本"拆开，其实要同时决策五件事：

1. **版面识别**：这段文字是标题、正文、表格还是页脚？多栏排版怎么还原阅读顺序？
2. **元素切分**：按什么粒度输出？段落、句子、还是带层级的 "element"？
3. **表格结构**：表格是保成 HTML table 结构，还是拍平成文字？丢了表头的表格数据毫无用处。
4. **图片和 OCR**：扫描件要 OCR；内嵌图表、示意图要不要抽取描述？
5. **元数据继承**：页码、标题层级、文档路径，这些要跟着块走，检索时做过滤和引用全靠它们。

`PyPDFLoader` 这类朴素加载器只做了第 1 件事的一半（甚至有字符顺序问题），后面全丢给你自己。Unstructured 的价值在于把这五件事都工程化了。

## 架构：core + partition + chunk + staging

Unstructured 的代码组织本身就反映了它的设计哲学：

- **partition 系列**：核心解析能力。`partition_pdf`、`partition_docx`、`partition_html`……按格式选入口。
- **chunking**：把解析出的 elements 按标题层级组合成语义块，带 `chunking_strategy`（basic / by_title）。
- **staging**：把解析结果送到下游（S3 桶、向量库、Delta Table），生产管道里用来归档"解析后的中间产物"。
- **core**：Element 数据结构、清洗规则（remove_invisible_characters 之类）。

API 有本地开源库和 SaaS（Unstructured API / Serverless）两档。**产出物的核心是统一的数据结构：Element**。

## 从一段 PDF 开始

```bash
pip install "unstructured[all-docs]"  # 全格式；只要 PDF 可以选 unstructured[pdf]
```

最小可用：

```python
from unstructured.partition.pdf import partition_pdf

elements = partition_pdf(
    filename="contract.pdf",
    strategy="hi_res",              # 关键参数，下面详解
    infer_table_structure=True,     # 输出 HTML 表格结构
)

for el in elements[:10]:
    print(type(el).__name__, "|", str(el)[:80])
    # NarrativeText | 甲方应当按照本合同约定…
    # Title | 第三条 付款条款
    # Table | <table><thead><tr><th>期限</th>…
```

输出不是字符串列表，而是带类型的 element 列表。`NarrativeText`（正文）、`Title`（标题）、`Table`（表格）、`Image`（图片）、`Header`/`Footer`（页眉页脚，通常要丢掉）——**类型信息就是后面所有智能处理的基础**。

### strategy 参数：速度和质量的开关

- `fast`（默认）：纯文本层提取，走 pdfminer，不 OCR。数字原生的 PDF 够用，秒级出结果。
- `hi_res`：版面检测模型（基于 Detectron2 的文档版面分析）先识别版面区域，再逐区域提取。表格还原质量高一个档次，但**首次运行要下载模型（几百 MB），且慢 5~10 倍**。扫描件必须 hi_res。
- `ocr_only`：整页 OCR，扫描保单、发票这类纯图片 PDF 用。

生产上的经验：**按文档来源分流**。电子版走 fast，扫描件和表格重的走 hi_res，入口加个自动探测（PDF 文本层长度 < 阈值 → 判定扫描件）。全部 hi_res 的解析成本很多团队扛不住。

## 表格是分水岭

`infer_table_structure=True` 后表格出来的是带 `<table>` 结构的 HTML。这解決了"表格拍平后检索失真"的经典问题。看一个真实差异：

拍平模式（PyPDFLoader 风格）：
```
Q1 营收 1200 Q2 营收 1500 Q3 营收 1100
```
检索"Q3 营收"能命中，但答案里模型看不到行列关系，经常把 Q3 的值张冠李戴到 Q2。

HTML 表格模式：
```html
<table>
  <thead><tr><th>季度</th><th>营收(万)</th></tr></thead>
  <tbody><tr><td>Q1</td><td>1200</td></tr><tr><td>Q3</td><td>1100</td></tr></tbody>
</table>
```
行列结构清楚，LLM 理解成本大幅下降。对财报、参数表这类文档，**表格还原质量直接决定 RAG 敢不敢用于严肃问答**。

## 接进 LangChain 管道

Unstructured 官方提供了 LangChain 的 loader，但生产里我更推荐自己组管道——因为要加清洗和元数据管理：

```python
from unstructured.partition.pdf import partition_pdf
from unstructured.chunking.title import chunk_by_title
from unstructured.documents.elements import NarrativeText, Table
from langchain_core.documents import Document

def load_and_chunk(path: str) -> list[Document]:
    elements = partition_pdf(path, strategy="hi_res", infer_table_structure=True)

    # 1. 清洗：丢掉导航性噪音
    cleaned = [
        el for el in elements
        if el.category not in ("Header", "Footer", "PageNumber")
        and str(el).strip()
    ]

    # 2. 按标题层级组合成语义块
    chunks = chunk_by_title(cleaned, max_characters=1500, combine_under_n_chars=200)

    # 3. 转 LangChain Document，把元数据盘活
    docs = []
    for chunk in chunks:
        meta = {
            "source": path,
            "category": chunk.category,
            "page_number": getattr(chunk.metadata, "page_number", None),
            "filetype": "pdf",
        }
        # 表格块单独打标，检索时可以优先/加权
        if isinstance(chunk, Table):
            meta["is_table"] = True
            meta["text_as_html"] = chunk.metadata.text_as_html
        docs.append(Document(page_content=str(chunk), metadata=meta))
    return docs
```

`chunk_by_title` 是 Unstructured 特有的切分逻辑：尊重标题边界，标题下内容太短时往前合并，输出的块天然是"一个完整语义单元"。比固定窗口的 `RecursiveCharacterTextSplitter` 更保语义，代价是块大小不均（索引和检索时要容忍）。

元数据里几个关键字段的用途：`page_number` 用来给最终答案带引用（"见 P.23"）；`is_table` 用来给表格块做检索加权或单独建表级索引；`source` 用来做权限过滤。

## 生产管道的四个补丁

照着教程跑通和上生产之间，还差这些工程补丁：

**补丁一：解析结果先落盘**。hi_res 解析一份 100 页 PDF 要好几分钟，失败了从头再来是灾难。解析 → JSON → 落 S3，下游切分/入库读 JSON。改切分策略不用重新解析，改 embedding 模型不用重新解析。**把最贵的步骤和后续步骤解耦**，这是所有数据管道的通则。

**补丁二：OCR 质量抽检**。OCR 出来的文本是"机器眼里的字"，错一个字检索就差之千里。建一个抽检流程：每天随机抽 N 个扫描件，人看 OCR 文本对照原图。Unstructured 支持指定 OCR 语言（`languages=["chi_sim", "eng"]`），中文扫描件必须加 `chi_sim`，否则默认英文模型会把汉字识别成乱码方块。

**补丁三：图片元素别直接扔**。`Image` 类 element 说明文档里有图。图里的信息对检索可能是关键（架构图、流程图）。两条路：用带视觉能力的模型（GPT-4o、Claude）给图片生成文字描述，作为独立块入索引；MinerU/ColPali 这类专门做图文混排解析的方案（后面 RAG 连载里有专篇），按文档类型选。

**补丁四：内存和超时管好**。Unstructured 的本地 hi_res 模式是出了名的吃内存（版面模型 + PDF 渲染常驻 2GB+）。生产部署时单独给它一个 worker/容器，`strategy="hi_res"` 的任务走队列异步化。别把解析放在 API 请求线程里同步等——一次扫描件解析 3 分钟，HTTP 连接早断了。

## Unstructured vs 其他解析器

- **vs pdfplumber/PyPDF2**：后者是纯文本抽取库，没有版面概念。要求不高、追求极致速度时它们仍是最优解。
- **vs MinerU / Marker**（专攻 PDF→Markdown 的解析器）：学术论文、技术文档场景，输出 Markdown 的管道公式化更强（公式转 LaTeX、图表描述）。Unstructured 胜在多格式统一和与 RAG 管道的集成度。
- **vs 云厂商文档智能 API**（Textract、文档智能）：扫描件和企业表格识别准确率通常更高，但按量计费 + 数据出境问题。内网部署选 Unstructured 或开源模型，云上且预算够可以试云 API 做双跑对比。

## 结语

文档解析是 RAG 的"原料关"，Unstructured 把这项脏活做成了结构化工程：element 类型体系、标题级 chunking、表格 HTML 还原，加上解析结果落盘、按来源分流的工程补丁，就能够支撑起企业级文档入库的质量。下一篇专门讲另一个解析路线——Docling 的版面感知转换，看看它和 Unstructured 各适合什么场景。
