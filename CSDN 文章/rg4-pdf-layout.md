# 复杂 PDF 的版面还原：两栏、表格、页眉页脚怎么处理

> `pdfplumber` 提取出来的文本：
>
> ```
> 第一章 概述 第二章 方法
> 本章介绍系统的 我们提出了一种
> 整体设计思路 新的架构方案
> ```
>
> **两栏排版的论文，被混成了一锅粥。**

## 一、PDF 为什么这么难

PDF 的设计目标是**"精确打印"**，不是"结构化存储"。它记录的是：

```
"把字符 A 放在坐标 (100, 200)，字号 12pt"
```

**它不记录**"这是一个标题"、"这是两栏"、"这是表格"。

所以从 PDF 提取结构，本质是**从坐标反推语义**。

## 二、五种常见版面难题

| 难题 | 症状 |
|---|---|
| 多栏排版 | 左右栏文字交叉混在一起 |
| 页眉页脚 | 每页都插入"第 X 页"、"XX公司内部资料" |
| 表格 | 表格结构丢失，变成乱序文本 |
| 图表标题 | 图注和正文混在一起 |
| 换行连字符 | "informa-\ntion" 断词 |

## 三、文本提取工具选型

```python
# 1. 最基础：pypdf（快，但版面信息少）
from pypdf import PdfReader
text = "\n".join(p.extract_text() for p in PdfReader("doc.pdf").pages)

# 2. 中等：pdfplumber（能拿坐标，适合表格）
import pdfplumber
with pdfplumber.open("doc.pdf") as pdf:
    text = "\n".join(p.extract_text() for p in pdf.pages)

# 3. 最强：unstructured（版面分析 + 元素分类）
from unstructured.partition.pdf import partition_pdf
elements = partition_pdf("doc.pdf", strategy="hi_res", infer_table_structure=True)

# 4. OCR：扫描件（前面讲过）
```

**选型建议**：

| 文档类型 | 工具 |
|---|---|
| 标准论文 / 报告 | `pdfplumber` + 手工处理 |
| 有表格 | `pdfplumber` 或 `camelot` |
| 版面复杂 | `unstructured`（hi_res） |
| 扫描件 | OCR |

## 四、多栏排版：按坐标分栏

**核心思路：根据 x 坐标把文本按栏分组。**

```python
import pdfplumber

def extract_two_column(page):
    """提取两栏排版的文本"""
    width = page.width
    mid = width / 2

    left_words, right_words = [], []
    for w in page.extract_words():
        if w["x1"] <= mid:                      # 完全在左半
            left_words.append(w)
        elif w["x0"] >= mid:                    # 完全在右半
            right_words.append(w)
        else:
            # 跨中线的词，按中心点归属
            (left_words if (w["x0"] + w["x1"]) / 2 < mid else right_words).append(w)

    def to_text(words):
        # 按 y 坐标（top）分行
        words.sort(key=lambda w: (round(w["top"], 1), w["x0"]))
        lines, cur_top, cur = [], None, []
        for w in words:
            if cur_top is None or abs(w["top"] - cur_top) > 3:
                if cur:
                    lines.append(" ".join(cur))
                cur, cur_top = [w["text"]], w["top"]
            else:
                cur.append(w["text"])
        if cur:
            lines.append(" ".join(cur))
        return "\n".join(lines)

    # 先左栏全部，再右栏全部
    return to_text(left_words) + "\n\n" + to_text(right_words)
```

**关键点**：**判断分栏要先看文档**——单栏文档用这个逻辑会切错。自适应：

```python
def detect_columns(page, sample_size: int = 200):
    """通过 x 坐标的分布判断是几栏"""
    xs = [w["x0"] for w in page.extract_words()[:sample_size]]
    if not xs:
        return 1

    # 看中间区域有没有文字（有就是单栏）
    mid = page.width / 2
    middle_count = sum(1 for x in xs if abs(x - mid) < page.width * 0.1)
    return 2 if middle_count < len(xs) * 0.05 else 1
```

**一个经验值**：如果"页面中间 20% 宽度内"几乎没有文字，基本可以断定是两栏。

## 五、页眉页脚：按"重复性"识别

**关键特征：页眉页脚在每一页几乎相同。**

```python
from collections import Counter

def find_headers_footers(pdf, top_ratio=0.08, bottom_ratio=0.92):
    """找出重复出现的页眉页脚"""
    candidates = Counter()

    for page in pdf.pages:
        h = page.height
        for w in page.extract_words():
            if w["top"] < h * top_ratio or w["bottom"] > h * bottom_ratio:
                candidates[w["text"]] += 1

    # 出现在超过 60% 页面里的，判定为页眉/页脚
    threshold = len(pdf.pages) * 0.6
    return {t for t, c in candidates.items() if c > threshold}
```

**用它过滤**：

```python
def clean_page_text(page, noise_words: set) -> str:
    lines = []
    for line in page.extract_text().split("\n"):
        stripped = line.strip()
        # 整行由噪声词组成就跳过
        if stripped and not all(tok in noise_words for tok in stripped.split()):
            lines.append(line)
    return "\n".join(lines)
```

**注意页码是变化的**——"第 3 页"和"第 4 页"不是同一个字符串。需要**归一化**：

```python
import re

def normalize_header(text: str) -> str:
    text = re.sub(r"\d+", "#", text)           # 数字换成 #
    return text.strip()
```

这样"第 3 页"和"第 4 页"都变成"第 # 页"，能被识别为同一个页脚。

## 六、连字符断词

英文 PDF 常见的换行断词：

```
This is important informa-
tion about the system.
```

**处理**：

```python
def fix_hyphenation(text: str) -> str:
    # 行尾连字符 + 换行 → 去掉连字符和换行
    text = re.sub(r"(\w+)-\n(\w+)", r"\1\2", text)
    # 中文的换行不需要处理（中文没有连字符）
    return text
```

**但要注意**：真实的连字符词会被误伤。

```
"state-of-the-art" 跨行时
state-of-the-
art
→ "state-of-theart"  ❌
```

**改进**：只对"不在词典中的合成词"处理，或者用启发式规则：

```python
def smart_fix_hyphenation(text: str) -> str:
    def replace(m):
        left, right = m.group(1), m.group(2)
        # 如果右边是小写开头，且左边不是常见前缀，很可能是断词
        if right[0].islower() and not left.endswith(("non", "pre", "post", "anti")):
            return left + right
        return m.group(0)               # 保留原样
    return re.sub(r"(\w+)-\n(\w+)", replace, text)
```

**中文文档不受影响**——中文换行不产生连字符。

## 七、图注和图表处理

**图注（Figure Caption）通常有固定格式**：

```python
CAPTION_PATTERN = r"^(图|表|Figure|Table)\s*\d+[\s:：.]"

def is_caption(line: str) -> bool:
    return bool(re.match(CAPTION_PATTERN, line.strip(), flags=re.I))

def link_captions(text: str) -> str:
    """把图注和它描述的图/表关联起来"""
    lines = text.split("\n")
    out = []
    for i, line in enumerate(lines):
        if is_caption(line):
            out.append(f"\n[{line.strip()}]\n")     # 加标记，便于后续处理
        else:
            out.append(line)
    return "\n".join(out)
```

**图表本身（图片）如果含有信息**，需要 OCR 或多模态模型描述——**这部分内容是纯文本提取拿不到的**。

## 八、`unstructured` 的用法

它把"版面分析 + 元素分类"做好了：

```python
from unstructured.partition.pdf import partition_pdf

elements = partition_pdf(
    "doc.pdf",
    strategy="hi_res",                  # 高精度（用模型做版面分析）
    infer_table_structure=True,         # 识别表格结构
    languages=["chi_sim", "eng"],       # 中文 + 英文
)

for el in elements:
    print(el.category, "|", el.text[:80])
```

**输出的元素类型**：

```
Title        | 第一章 系统概述
NarrativeText| 本章介绍系统的整体设计思路...
ListItem     | 1. 支持多种数据源
ListItem     | 2. 提供统一接口
Table        | <table><tr><td>...
FigureCaption| 图 1 系统架构图
Footer       | 第 3 页
```

**按类型分组处理**：

```python
def elements_to_documents(elements):
    docs = []
    for el in elements:
        if el.category in ("Footer", "Header"):
            continue                       # 跳过页眉页脚
        if el.category == "Table":
            docs.append(Document(
                page_content=f"[表格]\n{el.text}",
                metadata={"type": "table", "page": el.metadata.page_number},
            ))
        elif el.category == "Title":
            # 标题单独记录，用于给后续内容加路径
            current_heading = el.text
        else:
            docs.append(Document(
                page_content=el.text,
                metadata={"type": "text", "page": el.metadata.page_number,
                          "heading": current_heading},
            ))
    return docs
```

**`hi_res` 模式会调用模型做版面分析**，速度慢但准确率高。**适合离线索引阶段**。

## 九、扫描件：OCR 必须做

**如果 PDF 是图片扫描件**，文本提取会返回空：

```python
def is_scanned(pdf) -> bool:
    """判断是否扫描件：有页面但提取不出文字"""
    for page in pdf.pages[:3]:
        if page.extract_text() and len(page.extract_text().strip()) > 50:
            return False
    return True
```

**扫描件走 OCR**：

```python
from pdf2image import convert_from_path
import pytesseract

def ocr_pdf(path: str, dpi: int = 300, lang: str = "chi_sim+eng"):
    images = convert_from_path(path, dpi=dpi)       # 300 DPI 是精度和速度的平衡点
    texts = []
    for i, img in enumerate(images, 1):
        text = pytesseract.image_to_string(img, lang=lang, config="--psm 6")
        texts.append(f"--- 第 {i} 页 ---\n{text}")
    return "\n\n".join(texts)
```

**DPI 选择**：

| DPI | 精度 | 速度 | 建议 |
|---|---|---|---|
| 150 | 低 | 快 | 草稿 |
| **300** | **高** | **中** | **默认** |
| 600 | 更高 | 慢 | 小字/公式 |

**`--psm 6`** 假设是"一整块统一文本"——对大多数文档比默认值更准。

## 十、验收：怎么知道提取质量

**做一次人工抽查**：

```python
def sanity_check(text: str, sample_pages: list[int] = None):
    problems = []

    # 1. 乱码检测
    if len(re.findall(r"[\ufffd\u0000-\u001f]", text)) > len(text) * 0.02:
        problems.append("乱码比例过高")

    # 2. 换行密度（正常文档约每 40~80 字一个换行）
    lines = [l for l in text.split("\n") if l.strip()]
    avg_len = sum(len(l) for l in lines) / max(len(lines), 1)
    if avg_len < 15:
        problems.append(f"行平均长度只有 {avg_len:.0f} 字，可能是换行过多")

    # 3. 页眉页脚残留
    if re.search(r"第\s*\d+\s*页", text):
        problems.append("检测到页码残留")

    # 4. 连字符断词
    if re.search(r"\w+-\n\w+", text):
        problems.append("检测到未修复的断词")

    return problems
```

**跑一遍，把问题在索引阶段就修掉**——**索引阶段修一次，全生命周期都受益；检索阶段天天修，永远修不完。**

## 十一、一个完整的处理管线

```python
def pdf_to_documents(path: str) -> list[Document]:
    with pdfplumber.open(path) as pdf:
        # 1. 识别并移除页眉页脚
        noise = find_headers_footers(pdf)

        docs = []
        for page_no, page in enumerate(pdf.pages, 1):
            # 2. 判断分栏
            cols = detect_columns(page)
            if cols == 2:
                text = extract_two_column(page)
            else:
                text = page.extract_text() or ""

            # 3. 清理
            text = clean_page_text(page, noise)
            text = fix_hyphenation(text)
            text = link_captions(text)

            # 4. 表格单独处理
            for t_idx, table in enumerate(page.extract_tables()):
                if table and len(table) > 1:
                    header, *rows = table
                    df = pd.DataFrame(rows, columns=header)
                    docs.append(Document(
                        page_content=f"【第{page_no}页表格{t_idx+1}】\n{df.to_markdown(index=False)}",
                        metadata={"type": "table", "page": page_no, "source": path},
                    ))

            if text.strip():
                docs.append(Document(
                    page_content=text,
                    metadata={"type": "text", "page": page_no, "source": path},
                ))

    return docs
```

## 十二、小结

```
五种难题，五种对策：
  多栏     → 按 x 坐标分栏
  页眉页脚 → 按"跨页重复"识别 + 数字归一化
  表格     → 单独提取，整表保留
  图注     → 正则识别，加标记
  断词     → 正则修复（注意误伤）
```

四条原则：

```
1. 先判断文档类型（单栏/多栏、文本/扫描），再选工具
2. 页眉页脚和断词要在索引阶段修掉
3. 表格绝不与正文混在一起提取
4. 提取完做一次 sanity check
```

**一句话：PDF 解析的目标不是"提取文字"，而是"还原结构"。** 只拿到一堆字符的 RAG，等于在噪音里检索——**版面还原做得好不好，直接决定 RAG 的上限**。
