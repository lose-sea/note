# 按 Markdown 标题切分：有结构就别用字数

> 文档已经有 Markdown 标题了。
> 你还用 800 字一刀切——**等于把作者标注的语义边界全部忽略。**

## 一、标题是免费的语义标注

作者写标题时，已经在告诉你：

```
## 退款政策          ← 这是一个主题
### 申请条件         ← 这是主题下的一个方面
### 到账时间         ← 这是另一个方面
```

**这些标题是作者对文档结构的人工标注**，比任何算法切分都准。

**用标题切分的三个好处**：

| 好处 | 说明 |
|---|---|
| 边界天然正确 | 不切碎主题 |
| 块自带上下文 | 标题本身说明"这块在讲什么" |
| 可溯源 | 能定位到具体章节 |

## 二、基础用法

```python
from langchain_text_splitters import MarkdownHeaderTextSplitter

splitter = MarkdownHeaderTextSplitter(
    headers_to_split_on=[
        ("#", "h1"),
        ("##", "h2"),
        ("###", "h3"),
    ],
    strip_headers=False,        # 关键：保留标题在内容里
)

chunks = splitter.split_text(markdown_doc)

for c in chunks[:3]:
    print(c.metadata)           # {'h1': '产品手册', 'h2': '退款政策', 'h3': '申请条件'}
    print(c.page_content[:100])
    print("---")
```

**`strip_headers=False` 是关键参数**。设为 `True` 时标题只进 metadata 不进内容——但最好**两边都要**：

- **进 metadata** → 可以按标题过滤、可以显示来源路径；
- **进内容** → 块自己"知道"在讲什么主题。

## 三、标题路径要拼进内容

只保留 `h3` 标题是不够的，因为**标题需要完整路径才有意义**：

```
### 申请条件        ← 孤立看，不知道是"什么"的申请条件
```

**正确做法**：把完整路径拼上。

```python
def enrich_with_heading_path(chunks):
    for c in chunks:
        path = " > ".join(
            c.metadata[k] for k in ("h1", "h2", "h3") if k in c.metadata
        )
        if path:
            c.page_content = f"【{path}】\n{c.page_content}"
    return chunks
```

效果：

```
【产品手册 > 退款政策 > 申请条件】
1. 订单在 7 天内；2. 商品未拆封。
```

**现在这个块即使被单独检索出来，也能自解释。**

## 四、标题切分后的"超大块"问题

**按标题切分会产生长度极不均匀的块**：

```
## 概述           ← 200 字
## 快速上手       ← 1500 字  ⚠️ 太长
## API 参考       ← 8000 字  ⚠️ 太长了
```

**两级策略：先按标题切，超长的再按长度切。**

```python
from langchain_text_splitters import (
    MarkdownHeaderTextSplitter,
    RecursiveCharacterTextSplitter,
)

header_splitter = MarkdownHeaderTextSplitter(
    headers_to_split_on=[("#", "h1"), ("##", "h2"), ("###", "h3")],
    strip_headers=False,
)

text_splitter = RecursiveCharacterTextSplitter(
    chunk_size=800,
    chunk_overlap=80,
    separators=["\n\n", "\n", "。", "！", "？", "；", "，", " ", ""],
)

def split_markdown(doc: str):
    # 1. 先按标题切
    sections = header_splitter.split_text(doc)

    # 2. 超长的section再按长度切，并继承标题元数据
    out = []
    for s in sections:
        if len(s.page_content) <= 1200:
            out.append(s)
        else:
            for piece in text_splitter.split_text(s.page_content):
                out.append(Document(
                    page_content=piece,
                    metadata={**s.metadata},        # 继承标题元数据
                ))
    return out
```

**这个两级策略是最实用的做法**——既保留结构边界，又控制块长。

## 五、标题切分的元数据妙用

标题进 metadata 后，可以做很多事：

**① 按章节过滤检索**

```python
retriever = vectorstore.as_retriever(
    search_kwargs={
        "k": 5,
        "filter": {"h1": "售后服务"},        # 只在售后章节里检索
    }
)
```

用户问售后问题，就不该检索到"产品介绍"章节。

**② 显示来源路径给用户**

```python
def format_with_path(doc):
    path = " > ".join(v for k, v in sorted(doc.metadata.items()) if k.startswith("h"))
    return f"[来源：{path}]\n{doc.page_content}"
```

用户看到"产品手册 > 退款政策 > 申请条件"，**信任度明显提高**。

**③ 用标题做重排加权**

```python
def boost_by_heading(docs, query):
    """标题里含查询词的块加权"""
    for d in docs:
        heading = " ".join(v for k, v in d.metadata.items() if k.startswith("h"))
        if any(w in heading for w in query.split()):
            d.metadata["score"] = d.metadata.get("score", 0) + 0.1
    return sorted(docs, key=lambda x: -x.metadata.get("score", 0))
```

## 六、没有 Markdown 标题怎么办

**很多文档是"伪结构化"的**——用了 `1.`、`一、`、`（一）` 这样的编号，但不是 Markdown。

**做法一：先转换成 Markdown**

```python
import re

def number_headers_to_markdown(text: str) -> str:
    """把「一、」「1.」这类编号提升为 Markdown 标题"""
    lines = text.split("\n")
    out = []
    for line in lines:
        s = line.strip()
        # 一、二、三、  或  1. 2. 3.
        if re.match(r"^[一二三四五六七八九十]+[、.]\s*\S{0,30}$", s):
            out.append(f"## {s}")
        elif re.match(r"^\d+[\.、]\s*\S{0,30}$", s) and len(s) < 40:
            out.append(f"### {s}")
        else:
            out.append(line)
    return "\n".join(out)
```

**做法二：用正则自己切**

```python
def split_by_numbering(text: str):
    pattern = r"(?m)^(?=[一二三四五六七八九十]+[、.]|\d+[\.、])"
    parts = re.split(pattern, text)
    return [p.strip() for p in parts if p.strip()]
```

**做法三：用 LLM 生成结构**

```python
STRUCTURE_PROMPT = """下面的文档没有明确的标题结构。
请为它生成一个 Markdown 标题层级（# ## ###），然后把内容按这个结构重新组织。

原文：
{text}

要求：
- 不要修改任何原文内容
- 只插入标题行
- 标题简明，不超过 15 字
"""
```

**注意**：方法三会改动词条（虽然只是插标题），**要评估风险**。对于法律、医疗类文档不建议用。

## 七、HTML 和 PDF 的标题

**HTML**：

```python
from langchain_text_splitters import HTMLHeaderTextSplitter

splitter = HTMLHeaderTextSplitter(
    headers_to_split_on=[("h1", "h1"), ("h2", "h2"), ("h3", "h3")],
)
chunks = splitter.split_text(html_string)
```

**它也支持按 URL 直接抓**：

```python
chunks = splitter.split_text_from_url("https://example.com/doc")
```

**PDF**：PDF 没有"标题"的概念，需要靠字体大小推断。

```python
from unstructured.partition.pdf import partition_pdf

elements = partition_pdf("doc.pdf", infer_table_structure=True)

# 按字体大小判断标题层级
def is_heading(el) -> int | None:
    if el.category != "Title":
        return None
    size = float(el.metadata.font_size or 0)
    if size >= 20:
        return 1
    if size >= 16:
        return 2
    return 3
```

`unstructured` 能识别 `Title` 类型的元素——**这是 PDF 里最接近"标题"的信号**。

## 八、几个坑

**① 标题层级不连续。**

```markdown
# 一级标题
### 三级标题      ← 跳过了二级
```

`MarkdownHeaderTextSplitter` 会把 `h2` 留空。**要处理缺失层级**：

```python
def fill_missing_levels(meta):
    last = None
    for k in ("h1", "h2", "h3"):
        if k in meta:
            last = meta[k]
        elif last:
            meta.setdefault(k, last)      # 用上级填充
    return meta
```

**② 表格和代码块会被标题切分打断。**

如果一个 Markdown 表格跨在两个 `##` 标题之间——**几乎不可能**，但代码块里有 `#` 开头的注释时会误判：

````markdown
## 配置示例
```python
# 这是 Python 注释，不是 Markdown 标题
config = {}
```
````

`MarkdownHeaderTextSplitter` 会**正确忽略代码块内的 `#`**（它能识别 fenced code block）。但**自己写正则切分时要小心**。

**③ 标题本身是问题。**

```markdown
## 常见问题
```

这个标题没有任何信息量。切出来的块内容是"## 常见问题"，检索时会匹配到一堆无意义的块。

**处理方式**：过滤掉只有标题、没有内容的块：

```python
chunks = [c for c in chunks if len(c.page_content.strip()) > 60]
```

**④ 标题切分后仍要合并过短的块。**

```python
def merge_small(chunks, min_len=150):
    out = []
    for c in chunks:
        if len(c.page_content) < min_len and out:
            prev = out[-1]
            # 只在同一父标题下合并
            if prev.metadata.get("h2") == c.metadata.get("h2"):
                prev.page_content += "\n\n" + c.page_content
                continue
        out.append(c)
    return out
```

## 九、小结

```python
# 两级切分：先按标题，超长的再按长度
splitter = MarkdownHeaderTextSplitter(
    headers_to_split_on=[("#", "h1"), ("##", "h2"), ("###", "h3")],
    strip_headers=False,        # 保留标题在内容里
)
chunks = splitter.split_text(md)
chunks = [split_long(c) for c in chunks if len(c.page_content) > 1200] or chunks
chunks = enrich_with_heading_path(chunks)      # 拼完整路径
chunks = merge_small(chunks)                    # 合并过短块
```

四条原则：

```
1. 有标题就按标题切——作者已经标好了语义边界
2. 把完整标题路径拼进内容（【A > B > C】）
3. 超长的 section 再按长度二次切分
4. 标题进 metadata，用于过滤、加权和溯源
```

**一句话：文档结构是作者留给你的礼物。** 忽略它去用字数切分，等于把已经标注好的答案丢掉重新猜。
