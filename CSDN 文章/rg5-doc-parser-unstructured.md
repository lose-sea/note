# Unstructured 实战：把 PDF、Word、邮件统一成 elements 流

企业级 RAG 的知识源从来不是规整的 PDF 说明书：有 Word 合同、PPT 汇报、EML 邮件、扫描件、Excel 附件，格式五花八门。Unstructured 解决的就是"统一入口"问题——不管什么格式进来，都拆成带类型标注的 elements 流，再走同一套清洗和切分。这篇文章讲透 Unstructured 的核心概念、开源版和 API 的分界、LangChain 接入方式，以及它和 Docling 的选型逻辑。

## 一、核心概念：一切皆 element

Unstructured 的模型很简单：**文档 = 元素（element）流**。每个元素带一个类型标签：

| 元素类型 | 含义 |
|---|---|
| `Title` | 标题 |
| `NarrativeText` | 正文段落（最常见） |
| `ListItem` | 列表项 |
| `Table` | 表格 |
| `Image` | 图片 |
| `Formula` | 公式 |
| `Header` / `Footer` | 页眉页脚（通常可丢弃） |
| `PageBreak` | 分页符 |

解析的产物不是"一整块文本"，而是一个 `Element` 列表，每个元素可独立处理。**这个设计的价值：不同类型的元素走不同的 RAG 处理策略**——Table 整体成块、Image 走 VLM 描述、Footer 直接扔、Title 用来重建文档层级。这是 Unstructured 和"直接抽全文"的本质区别。

## 二、两种用法：开源库 vs API

这是选 Unstructured 第一个要做的决策，两者能力差距很大。

### 2.1 开源版（免费，本地跑）

```bash
# 这行会拉进 PDF/DOCX/PPTX/EML 等全部依赖，几百 MB
# 只处理 PDF 可以精简：pip install "unstructured[pdf]"
pip install "unstructured[all-docs]"
```

```python
from unstructured.partition.pdf import partition_pdf

elements = partition_pdf(
    filename="contract.pdf",
    strategy="hi_res",              # hi_res = 版面模型识别；fast = 纯文本提取
    infer_table_structure=True,     # 识别表格结构，输出带 thead/tbody 的 HTML
    extract_images_in_pdf=True,     # 提取图片
)
```

遍历结果：

```python
from unstructured.staging.base import elements_to_dicts
for el in elements:
    print(el.category, "|", str(el)[:80])
    # Title | 第一章 总则
    # Table | <table><thead>...
    # NarrativeText | 本合同由甲方...
```

转成 LangChain 文档：

```python
from langchain_unstructured import UnstructuredLoader

loader = UnstructuredLoader(
    file_path="contract.pdf",
    strategy="hi_res",
    infer_table_structure=True,
)
docs = loader.load()
# docs 是 Document 列表，每个元素的 metadata 里有 category、page_number、filename
```

### 2.2 API（付费，功能全）

```python
from unstructured_client import UnstructuredClient
from unstructured_client.models import operations, shared

client = UnstructuredClient(api_key_auth="your-key")

with open("contract.pdf", "rb") as f:
    req = operations.PartitionRequest(
        partition_parameters=shared.PartitionParameters(
            files=shared.Files(content=f.read(), file_name="contract.pdf"),
            strategy=shared.Strategy.HI_RES,
            chunking_strategy=shared.ChunkingStrategy.BY_TITLE,   # 直接按标题分好块！
            languages=["chi_sim", "eng"],
        ),
    )
    res = client.general.partition(request=req)
```

**API 独有能力**（开源版没有或受限的）：

- `chunking_strategy`：直接按标题（`by_title`）或基本页分块，省掉自己写切分逻辑；
- 更好的表格识别（付费模型）；
- 无运维成本，不烧本地 GPU/CPU。

**费用按页计**，量大不便宜——**量大的生产环境建议开源版本地部署**，成本只是机器钱。

### 2.3 strategy 怎么选

| strategy | 原理 | 速度 | 质量 | 适用 |
|---|---|---|---|---|
| `fast` | 纯文本流提取 | 秒级 | 丢结构 | 简单文本 PDF、纯 HTML |
| `hi_res` | 检测 + 识别两阶段视觉模型 | 每页 1~5 秒 | 标题/表格/阅读顺序都准 | 扫描件、复杂版面、正式文档 |

**生产建议**：默认 `hi_res`，对已知纯文本文档（比如系统导出的文本型 PDF）用 `fast` 提速。混合流水线：先探测，再路由。

## 三、清洗流水线：elements 流的最大价值

拿到 elements 只是开始，Unstructured 真正的工程价值是**可以在元素级别做精细清洗**：

```python
from unstructured.cleaners.core import clean, replace_unicode_quotes
from unstructured.documents.elements import Footer, Header, PageBreak

def clean_elements(elements):
    out = []
    for el in elements:
        # 1. 丢掉页眉页脚和分页符
        if isinstance(el, (Footer, Header, PageBreak)):
            continue
        # 2. 文本清洗：修引号、去多余空白、统一破折号
        text = clean(
            str(el),
            extra_whitespace=True,
            dashes=True,
            bullets=True,
            trailing_punctuation=False,
        )
        text = replace_unicode_quotes(text)
        # 3. 太短的元素（孤立的页码、水印）扔掉
        if len(text.strip()) < 10:
            continue
        el.text = text
        out.append(el)
    return out
```

**为什么这段清洗很关键**：页眉"XX公司机密文件"会出现在每一页，进向量库后每页 chunk 都带这句噪音，检索时"机密文件"的权重被污染；统一全角半角、引号，能避免同一意思因为符号差异被算成不同向量。**入库前的清洗，直接决定检索信噪比。**

## 四、多格式混合入库的统一架构

一个典型企业 RAG 的解析层架构：

```
共享盘/对象存储
   ├── PDF 合同 ──→ partition_pdf(hi_res)
   ├── DOCX 方案 ─→ partition_docx
   ├── PPTX 汇报 ─→ partition_pptx
   ├── EML 邮件 ──→ partition_email
   └── 扫描图片 ──→ partition_pdf(hi_res + OCR 中文包)
        ↓
   统一 elements 流
        ↓
   类型路由：Title→层级 / Table→整体块 / Image→VLM 描述 / Footer→丢弃
        ↓
   按策略切分（by_title 或语义切分）
        ↓
   带 metadata（文件名、页码、元素类型）入库
```

metadata 是关键：每个 chunk 入库时带上 `filename`、`page_number`、`category`、`department`——后面做**引用溯源**（答案标注出处文档和页码）、**权限过滤**（按 department 过滤可见文档），全靠这些字段。

**中文 OCR 注意**：扫描件要装中文语言包

```bash
# 安装 tesseract 后，pip 侧加语言
pip install "unstructured[pdf]"
# 下载 chi_sim.traineddata 到 tesseract 语言目录
```

开源版 hi_res 的 OCR 用的是 tesseract，中文效果一般。**中文扫描件多的场景，建议用 PaddleOCR 自建解析层**，或者评估商业 API——识别质量差一点，后面全靠补。

## 五、常见坑与排错

1. **`partition_pdf` 报缺少依赖**：开源版按格式分包，PDF 要显式 `pip install "unstructured[pdf]"`，装全量 `[all-docs]` 省心但体积大；
2. **内存爆炸**：hi_res 模式逐页做视觉检测，大文件（几百页）建议按页 range 分批处理，别一次性灌进内存；
3. **表格输出是 HTML 字符串**：直接存进 chunk 前转成 Markdown 更紧凑，或按列转文本行；
4. **API 限流**：批量任务加并发控制和退避重试，一次提交上千页容易被限；
5. **元素顺序错乱**：`partition_*` 返回的元素自带顺序，但自己过滤/排序时别打乱——阅读顺序是版面分析的核心产出；
6. **EML 邮件解析**：`partition_email` 会把邮件头和附件分开，附件要单独再解析一遍，别漏。

## 六、Docling vs Unstructured 最终选型

| 场景 | 推荐 |
|---|---|
| 格式杂（邮件/PPT/扫描件都要）+ 预算足 | Unstructured API |
| 格式杂 + 要本地部署 + 预算敏感 | Unstructured 开源版本地 |
| 主要是 PDF，要极致 Markdown 质量 | **Docling** |
| 数据绝不出内网 | Docling 或 Unstructured 开源本地版 |
| 已用 LangChain，要快速出效果 | 两者都有官方 loader，看文档质量 |

**务实的答案**：两者都试，用**你自己的 10 份文档**做人工评估——同样的 PDF，各跑一遍，看表格还原、阅读顺序、中文表现。RAG 的解析环节没有普世最优，只有"你的数据上的最优"。

## 七、小结

Unstructured 的三句话：

- **一切皆 element**：标题、表格、图片、页眉各有类型标签，类型路由是精细化 RAG 的基础；
- **开源版本地够用，API 买省心和更强表格**，量大的生产环境走本地部署控成本；
- **elements 流的价值在清洗**：丢页眉页脚、统一符号、过滤短噪音——入库前的清洗决定检索信噪比，别跳过。

下一篇讲 ColPali：不解析、不切分，直接把 PDF 页面当图像做检索的多模态新范式。
