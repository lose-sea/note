# 递归切分的分隔符顺序：为什么这个顺序很重要

> `RecursiveCharacterTextSplitter` 是 RAG 里用得最多的切分器。
> 它的"递归"体现在哪？分隔符顺序为什么是这个顺序？
>
> 理解这两点，你才能把它调对。

## 一、它为什么叫"递归"

**递归的含义：优先用第一级分隔符切，切完的片段如果还太长，就用第二级继续切。**

```python
RecursiveCharacterTextSplitter(
    separators=["\n\n", "\n", " ", ""],
    chunk_size=800,
)
```

流程：

```
原文（2000 字）
  ↓ 用 "\n\n" 切
段落 A（900 字） ← 超过 800
段落 B（600 字） ← 合适
段落 C（500 字） ← 合适
  ↓ A 还太长，对 A 用 "\n" 切
A1（500 字） ← 合适
A2（400 字） ← 合适
```

**从"大的结构边界"往"小的结构边界"逐级退让。** 这就是递归。

## 二、默认分隔符顺序的问题

LangChain 的默认顺序是给英文设计的：

```python
separators=["\n\n", "\n", " ", ""]
```

**对中文文档，问题很大**：

```
中文文档里，段落内通常没有空格。
所以 "\n\n" 切完后，如果某段还是很长，就直接落到 " "，
而 " " 在中文里基本不存在 → 落到最后一级 ""，也就是"硬切字符"
```

结果就是**中文长段落被从句子中间硬切**：

```
...订单需要在 7 天内申请退
款，且商品需要保持未拆封状态...
```

## 三、中文的正确分隔符顺序

```python
from langchain_text_splitters import RecursiveCharacterTextSplitter

splitter = RecursiveCharacterTextSplitter(
    chunk_size=800,
    chunk_overlap=80,
    separators=[
        "\n\n",      # 1. 段落
        "\n",        # 2. 行
        "。",        # 3. 句号
        "！",        # 4. 感叹号
        "？",        # 5. 问号
        "；",        # 6. 分号
        "，",        # 7. 逗号（最后的结构边界）
        " ",         # 8. 空格（中英混排时有）
        "",          # 9. 最后兜底：硬切
    ],
    keep_separator=True,        # 保留分隔符，避免句子末尾缺标点
)
```

**顺序的原则：从"最大的结构单元"到"最小的"**：

```
段落 > 行 > 句子 > 子句 > 词 > 字符
```

**为什么标点要按这个顺序**？

```
句号分割的是"完整意思"
逗号分割的是"半个意思"
所以句号要优先于逗号
```

如果逗号在句号前面，会出现：

```
块：订单需要在 7 天内申请退款，
```
**句子被从逗号处切断，语义不完整。**

## 四、不同文档类型的分隔符

**Markdown 文档**

```python
separators=["\n## ", "\n### ", "\n\n", "\n", "。", " ", ""]
```

把标题也作为分隔符——**按标题切比按段落切更符合语义**。

更好的做法是用 `MarkdownHeaderTextSplitter`：

```python
from langchain_text_splitters import MarkdownHeaderTextSplitter

splitter = MarkdownHeaderTextSplitter(
    headers_to_split_on=[("#", "h1"), ("##", "h2"), ("###", "h3")],
    strip_headers=False,
)
```

**代码文档**

```python
from langchain_text_splitters import RecursiveCharacterTextSplitter, Language

splitter = RecursiveCharacterTextSplitter.from_language(
    language=Language.PYTHON,
    chunk_size=1000,
    chunk_overlap=0,
)
```

**它会用 Python 的语法分隔符**（`class `、`def `、`\n\n`）来切——比按字符切好得多。

**HTML**

```python
from langchain_text_splitters import HTMLHeaderTextSplitter

splitter = HTMLHeaderTextSplitter(headers_to_split_on=[
    ("h1", "h1"), ("h2", "h2"), ("h3", "h3"),
])
```

**LaTeX / 论文**

```python
separators=["\n\\section", "\n\\subsection", "\n\n", "\n", ". ", " ", ""]
```

**日文**

```python
separators=["\n\n", "\n", "。", "、", " ", ""]      # 日文用「、」不用「，」
```

## 五、`keep_separator` 的作用

```python
# keep_separator=False（默认行为，部分版本）
"订单在7天内。商品未拆封。"  →  切成 ["订单在7天内", "商品未拆封"]

# keep_separator=True
"订单在7天内。商品未拆封。"  →  切成 ["订单在7天内。", "商品未拆封。"]
```

**保留标点更好**——因为：

1. 句子末尾有标点更自然；
2. 有些模型对"缺标点的句子"理解会差一点。

**注意**：不同版本的 LangChain 对 `keep_separator` 的处理方式不一样。**升级版本后要重新检查一下切分结果。**

## 六、`length_function`：怎么算"长度"

默认是 `len`（字符数）。但对中文，**字符数不等于 token 数**：

```python
import tiktoken

enc = tiktoken.get_encoding("cl100k_base")

splitter = RecursiveCharacterTextSplitter(
    chunk_size=300,                                      # 300 token
    length_function=lambda t: len(enc.encode(t)),        # 按 token 计数
    separators=[...],
)
```

**什么时候用 token 计数**：

| 情况 | 用哪个 |
|---|---|
| embedding 模型限制 token 数 | **必须用 token** |
| 想控制上下文成本 | 用 token |
| 只是粗调切分 | 用字符数（快） |

**典型错误**：用 `chunk_size=1000`（字符）喂给只支持 512 token 的 embedding 模型 → **超限部分被静默截断**，后半个块等于没进向量。

```python
# bge-base-zh 支持 512 token
# 1000 个中文字 ≈ 1200 token ← 超了！
splitter = RecursiveCharacterTextSplitter(chunk_size=1000)   # ❌ 危险

# 正确：按 token 控制在 400 以内
splitter = RecursiveCharacterTextSplitter(
    chunk_size=400,
    length_function=lambda t: len(enc.encode(t)),
)                                                            # ✅
```

## 七、验证切分结果

**切分完一定要看一眼**——这是最容易被跳过的步骤。

```python
def inspect_chunks(chunks, n=5):
    print(f"共 {len(chunks)} 个块")
    lens = [len(c.page_content) for c in chunks]
    print(f"长度：min={min(lens)} max={max(lens)} avg={sum(lens)/len(lens):.0f}")

    print("\n--- 前几个块 ---")
    for i, c in enumerate(chunks[:n]):
        text = c.page_content
        print(f"\n[{i}] {len(text)} 字")
        print(repr(text[:120]))          # repr 能看到换行和空格
        print("...")
```

**用 `repr` 而不是 `print`**——能看到 `\n` 和空格，更容易发现切分问题。

**要检查的四件事**：

```
① 有没有超长块（应该不会超过 chunk_size 太多）
② 有没有超短块（< 50 字，可能是标题孤块）
③ 块的结尾是不是完整句子
④ 有没有把表格/代码切碎
```

**自动检查**：

```python
def check_chunks(chunks, max_expected=1200, min_expected=50):
    problems = []
    for i, c in enumerate(chunks):
        n = len(c.page_content)
        if n > max_expected:
            problems.append(f"[{i}] 超长块：{n} 字")
        elif n < min_expected:
            problems.append(f"[{i}] 过短块：{n} 字：{c.page_content[:30]!r}")
    return problems
```

**过短块通常是"孤立的标题"**——它自己成为一个块，检索时可能命中但没有任何内容。解决办法是**把小块合并到相邻块**：

```python
def merge_short_chunks(chunks, min_len=100):
    out = []
    for c in chunks:
        if len(c.page_content) < min_len and out:
            out[-1].page_content += "\n" + c.page_content
        else:
            out.append(c)
    return out
```

## 八、一个完整的中文切分配置

```python
import tiktoken
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_core.documents import Document

enc = tiktoken.get_encoding("cl100k_base")

def make_splitter(chunk_tokens: int = 400, overlap_tokens: int = 50):
    return RecursiveCharacterTextSplitter(
        chunk_size=chunk_tokens,
        chunk_overlap=overlap_tokens,
        length_function=lambda t: len(enc.encode(t)),
        separators=[
            "\n\n", "\n",
            "。", "！", "？", "；",
            "，",
            " ", "",
        ],
        keep_separator=True,
        is_separator_regex=False,
    )

def split_documents(docs: list[Document]) -> list[Document]:
    splitter = make_splitter()
    chunks = splitter.split_documents(docs)

    # 合并过短的块
    chunks = merge_short_chunks(chunks, min_len=100)

    # 加标题上下文（如果文档有标题）
    for c in chunks:
        heading = c.metadata.get("h1") or c.metadata.get("h2")
        if heading and not c.page_content.startswith(heading):
            c.page_content = f"【{heading}】\n{c.page_content}"

    return chunks
```

**这个配置处理了四件事**：

```
① 按 token 计数（不超 embedding 上限）
② 中文标点作为分隔符（不硬切句子）
③ 合并过短块（不留孤立标题）
④ 加标题上下文（小块也能自解释）
```

## 九、小结

```python
separators=["\n\n", "\n", "。", "！", "？", "；", "，", " ", ""]
```

**顺序原则**：

```
大结构 → 小结构
段落 > 行 > 句子 > 子句 > 词 > 字符
```

**四条实践**：

```
1. 中文必须自定义 separators（默认只支持英文）
2. 用 token 计数，避免超 embedding 上限被静默截断
3. keep_separator=True，保留句末标点
4. 切完要看一眼，合并过短块
```

**一句话：`RecursiveCharacterTextSplitter` 的"递归"是"从大边界退到小边界"，而分隔符的顺序决定了这个退让的次序。** 顺序对了，切出来的块天然就在语义边界上——**这比任何后处理都有效**。
