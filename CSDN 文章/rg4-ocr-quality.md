# OCR 质量决定 RAG 上限：错字会让检索直接失效

> 扫描件 OCR 出来是这样：
>
> ```
> 退款申请需妄满足以下条件：订单在7天内，商品未拆封。
> ```
>
> **"需妄" 而不是 "需要"。**
> 用户问"退款需要什么条件"，检索**永远匹配不上这一段**。

## 一、OCR 错误为什么致命

它破坏的是**检索的匹配基础**：

| 错误类型 | 例子 | 后果 |
|---|---|---|
| 形近字 | 需**妄** ↔ 需**要** | 关键词检索失效 |
| 数字错 | **l**200 ↔ **1**200 | 数值全部不可信 |
| 空格错乱 | 商品 未 拆封 | 分词边界错 |
| 标点丢失 | 条件订单在7天内 | 句子边界错 |
| 整行乱码 | 盍夔藜 | 完全不可用 |

**向量检索能"容忍"一定的错别字**（语义相似度仍然较高），但**关键词/BM25 检索会直接失效**——而混合检索里，关键词部分往往是最准的。

## 二、OCR 质量的决定因素

```
原始扫描质量  >  预处理  >  引擎选择  >  参数调优
     ⭐⭐⭐        ⭐⭐       ⭐⭐        ⭐
```

**扫描质量是天花板**。300 DPI 的清晰扫描，用免费引擎也能拿到 95%+ 的准确率；150 DPI 的歪斜扫描，用最好的引擎也救不回来。

## 三、预处理：提升 OCR 准确率的关键

**① 转灰度 + 二值化**

```python
from PIL import Image
import numpy as np

def preprocess(img: Image.Image) -> Image.Image:
    # 转灰度
    gray = img.convert("L")

    # 自适应二值化（比全局阈值好，能处理光照不均）
    arr = np.array(gray)
    binary = adaptive_threshold(arr)
    return Image.fromarray(binary)

def adaptive_threshold(arr: np.ndarray, block: int = 31, c: int = 10) -> np.ndarray:
    """局部均值 + 偏移，处理光照不均"""
    import cv2
    return cv2.adaptiveThreshold(
        arr, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY, block, c,
    )
```

**② 去噪**

```python
def denoise(img):
    import cv2
    arr = np.array(img.convert("L"))
    return Image.fromarray(cv2.medianBlur(arr, 3))
```

**③ 倾斜校正**

```python
def deskew(img: Image.Image) -> Image.Image:
    import cv2
    arr = np.array(img.convert("L"))
    # 用最小外接矩形估算倾斜角
    coords = np.column_stack(np.where(arr < 128))
    if len(coords) < 100:
        return img
    angle = cv2.minAreaRect(coords)[-1]
    if angle < -45:
        angle = 90 + angle
    if abs(angle) < 0.5:
        return img
    h, w = arr.shape
    m = cv2.getRotationMatrix2D((w // 2, h // 2), angle, 1.0)
    return Image.fromarray(cv2.warpAffine(arr, m, (w, h),
                                          flags=cv2.INTER_CUBIC,
                                          borderMode=cv2.BORDER_REPLICATE))
```

**倾斜 2 度以上，OCR 准确率会明显下降**，这一步很值。

**④ 适当放大**

```python
def upscale(img: Image.Image, factor: float = 1.5) -> Image.Image:
    w, h = img.size
    return img.resize((int(w * factor), int(h * factor)), Image.LANCZOS)
```

**小字扫描件放大 1.5~2 倍后，OCR 准确率显著提升**——因为字符高度进入了 OCR 引擎的最佳识别区间（约 30~40 像素）。

## 四、引擎选择

| 引擎 | 中文支持 | 速度 | 准确率 | 部署 |
|---|---|---|---|---|
| Tesseract | 一般 | 快 | 中 | 本地 |
| PaddleOCR | **好** | 中 | **高** | 本地 |
| EasyOCR | 好 | 慢 | 中高 | 本地 |
| 商业 API（百度/腾讯） | **很好** | 快 | **很高** | 云 |

**中文文档首选 PaddleOCR**——它是针对中文优化的，且开源免费。

```python
from paddleocr import PaddleOCR

ocr = PaddleOCR(use_angle_cls=True, lang="ch")

def paddle_ocr(img_path: str) -> list[dict]:
    result = ocr.ocr(img_path, cls=True)
    lines = []
    for page in result:
        if not page:
            continue
        for box, (text, conf) in page:
            lines.append({"text": text, "confidence": conf, "box": box})
    return lines
```

**关键：`confidence` 字段**——它是后续修正的依据。

## 五、用置信度筛出"可疑文本"

```python
def split_by_confidence(lines: list[dict], low: float = 0.6):
    """分高置信和低置信"""
    good = [l for l in lines if l["confidence"] >= low]
    bad = [l for l in lines if l["confidence"] < low]
    return good, bad
```

**低置信的文本有三种处理**：

**① 直接用 LLM 修正**

```python
FIX_PROMPT = """下面是 OCR 识别出的文本，可能包含识别错误。
请修正明显的错别字和格式问题。

规则：
- 只修正明显的 OCR 错误，不要改写内容
- 保持原文的专有名词、数字不变（除非明显是形近字错误）
- 保留原有换行结构

OCR 文本：
{text}

输出修正后的文本。"""

def llm_fix(text: str) -> str:
    return (llm | StrOutputParser()).invoke(FIX_PROMPT.format(text=text))
```

**② 用语言模型做后处理校验**

```python
def check_with_language_model(text: str) -> list[str]:
    """找出不像正常中文的片段"""
    suspicious = []
    for sent in re.split(r"[。！？]", text):
        if not sent.strip():
            continue
        # 用一个小的语言模型打分
        score = lm.score(sent)
        if score < THRESHOLD:
            suspicious.append(sent)
    return suspicious
```

**③ 标记为"低可信"并在检索时降权**

```python
Document(
    page_content=text,
    metadata={"confidence": avg_conf, "source": path},
)
```

检索后按 confidence 重排：

```python
def rerank_by_confidence(docs):
    for d in docs:
        d.metadata["score"] = d.metadata.get("score", 0) * (0.5 + 0.5 * d.metadata.get("confidence", 1))
    return sorted(docs, key=lambda x: -x.metadata["score"])
```

## 六、常见 OCR 错误与修正规则

**① 数字形近字**

```python
DIGIT_FIXES = [
    (r"(?<=[\d])O(?=[\d])", "0"),      # 数字中的 O → 0
    (r"(?<=[\d])l(?=[\d])", "1"),      # 数字中的 l → 1
    (r"(?<=\d)S(?=\d)", "5"),
    (r"(?<=\d)B(?=\d)", "8"),
]

def fix_digits(text: str) -> str:
    for pat, repl in DIGIT_FIXES:
        text = re.sub(pat, repl, text)
    return text
```

**② 中文形近字（用词典）**

```python
COMMON_ERRORS = {
    "需妄": "需要",
    "返诬": "返还",
    "帐号": "账号",       # 简繁/异体
    "定单": "订单",
    "支忖": "支付",
}

def fix_common_errors(text: str) -> str:
    for wrong, right in COMMON_ERRORS.items():
        text = text.replace(wrong, right)
    return text
```

**这张表要针对你的领域来建**——从实际的错字样本里统计。

**③ 空格处理**

```python
def fix_spaces(text: str) -> str:
    # 中文字符之间的空格去掉
    text = re.sub(r"(?<=[\u4e00-\u9fa5])\s+(?=[\u4e00-\u9fa5])", "", text)
    # 多个空格合并
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text
```

**中文里字与字之间不该有空格**——OCR 经常误插空格。

## 七、混合检索：OCR 场景的必需品

**OCR 有错字时，纯向量检索比纯关键词检索更鲁棒**，但**两者结合效果最好**：

```python
# 关键词检索（可能因为错字失效）
bm25 = BM25Retriever.from_documents(docs, k=5)

# 向量检索（对错字更鲁棒）
vector = vectorstore.as_retriever(search_kwargs={"k": 5})

# 混合
hybrid = EnsembleRetriever(retrievers=[bm25, vector], weights=[0.3, 0.7])
```

**权重偏向向量**（0.7）——因为 OCR 错字对向量的影响小于对关键词的影响。

**另一种补充手段：模糊匹配**

```python
from rapidfuzz import fuzz

def fuzzy_search(query: str, docs: list, threshold: float = 70):
    """编辑距离模糊匹配，容忍错字"""
    hits = []
    for d in docs:
        score = fuzz.partial_ratio(query, d.page_content)
        if score >= threshold:
            hits.append((score, d))
    return [d for _, d in sorted(hits, reverse=True, key=lambda x: x[0])]
```

## 八、建一个"错字对照表"持续改进

**最有价值的做法：收集真实查询失败案例，反推 OCR 错误。**

```python
def analyze_failures(failed_queries: list[str], expected_docs: list[str]):
    """分析检索失败的原因"""
    report = []
    for q, expected in zip(failed_queries, expected_docs):
        # 在原文里找到应该匹配的片段
        actual = find_closest(expected_doc_content, q)
        # 逐字对比，找出 OCR 错误
        for a, b in zip(q, actual):
            if a != b:
                report.append({"expected": a, "actual": b})
    return Counter((r["expected"], r["actual"]) for r in report).most_common(20)
```

**跑几次之后，你会得到一张真实的错字表**——把它加进 `COMMON_ERRORS`，**下一次索引时就修正了**。

## 九、几个坑

**① 别用 LLM 大改 OCR 结果。**
LLM 会"顺手改写"内容，破坏原文。**要用明确的提示词限制它"只修 OCR 错误，不改写"**，并且在关键字段（数字、专有名词）上做二次校验。

**② 别把整篇 OCR 后一次性送去修。**
长文本会超上下文，且 LLM 修到后面会"忘记规则"。**按块修**。

**③ 保留原始 OCR 结果。**
修正结果和原始结果都要存——**出问题时能对比**。

```python
Document(
    page_content=fixed_text,
    metadata={"raw_ocr": raw_text, "confidence": conf},
)
```

**④ 扫描件和电子版要区分。**
优先用电子版（`extract_text()` 的结果）；**只有电子版拿不到文字时才走 OCR**。不要对电子 PDF 做 OCR。

**⑤ 表格 OCR 特别难。**
表格的单元格边界、行列对齐，OCR 都很难还原。**表格建议用专门的表格识别模型**（如 `PaddleOCR` 的表格识别，或 `unstructured` 的 `infer_table_structure`）。

**⑥ 质量差到一定程度就别用了。**
如果 OCR 置信度普遍低于 0.5，**这份文档不适合进知识库**——它会污染检索结果。**宁缺毋滥。**

## 十、小结

```
流程：预处理 → 引擎选择 → 后处理 → 质量评估
      ① 灰度/二值化/去噪/纠偏/放大
      ② PaddleOCR（中文首选）
      ③ 数字修正 + 常见错字表 + 空格处理
      ④ 置信度统计，低质量的标记或剔除
```

五条原则：

```
1. 预处理比换引擎的收益大（300 DPI + 纠偏 + 放大）
2. 中文用 PaddleOCR，置信度是重要信号
3. 数字和领域错字要用规则修正
4. 混合检索（向量权重更高）能缓解错字问题
5. 置信度太低的文档，宁可不入库
```

**一句话：OCR 是 RAG 的"输入质量"环节。** 输入错了，后面所有的检索优化、重排、提示词工程都是在错误的基础上打补丁——**在源头修一比在末端修十次更有效**。
