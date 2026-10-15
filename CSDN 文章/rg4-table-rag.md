# 表格数据怎么进 RAG：直接切碎是最糟的选择

> 一份财务报告，最关键的信息在表格里。
> 你把它转成文本、按 800 字切分——
> **表格变成了这样：**

```
2024年 第一季度 营收 1200 万元 成本 800 万元 利润 400 万元
2024年 第二季度 营收 1350 万元 成本 860 万元 利润 490 万元
2024年 第三季度 营收 1180 万
```

**最后一行被切断了，而且丢失了表头（"营收/成本/利润" 的含义）。**

## 一、表格进 RAG 的三种方式

| 方式 | 做法 | 效果 |
|---|---|---|
| ❌ 直接转文本 | 表格 → 空格分隔的文本 | 丢失结构，切分后更难用 |
| ⚠️ 转 Markdown | 保持表格语法 | 好一些，但检索仍是文本匹配 |
| ✅ 结构化 + 文本化 | 转成"自解释的句子" | 检索和生成都友好 |

## 二、为什么"直接转文本"不行

**原始表格**：

| 季度 | 营收 | 成本 | 利润 |
|---|---|---|---|
| Q1 | 1200 | 800 | 400 |
| Q2 | 1350 | 860 | 490 |

**转成文本后**：

```
季度 营收 成本 利润
Q1 1200 800 400
Q2 1350 860 490
```

**问题**：

1. **每一行都是孤立的**——`Q1 1200 800 400` 这行文字，和"哪个季度的利润率是多少"这个问题的语义距离很远；
2. **表头可能丢失**——被切分到上一块；
3. **单位丢失**——"1200"是万元还是元？

**结果**：向量检索根本匹配不上。

## 三、方案一：转成"自解释句子"（推荐）

**每一行转成一句完整的话**，把表头信息嵌入进去：

```python
def table_to_sentences(rows: list[dict], table_context: str) -> list[str]:
    """把表格的每一行转成自然语言句子"""
    sentences = []
    for row in rows:
        # 构造"主体 + 属性 + 值"的句子
        parts = []
        for k, v in row.items():
            if v not in (None, "", "-"):
                parts.append(f"{k}为{v}")
        sentence = f"{table_context}中，" + "，".join(parts) + "。"
        sentences.append(sentence)
    return sentences
```

**实际效果**：

```
原始行：Q1 | 1200 | 800 | 400

转换后："2024年财务数据中，季度为Q1，营收为1200万元，成本为800万元，利润为400万元。"

加上表名后："【表：2024年季度财务数据】财务数据中，季度为Q1，营收为1200万元，..."
```

**现在这句话能被"Q1 的利润是多少"这个问题准确检索到。**

**转换模板**：

```python
TEMPLATES = {
    "record": "{table}中，{key_field}为{key_value}，{attr1}为{v1}，{attr2}为{v2}。",
    "comparison": "{table}中，{entity1}的{attr}为{v1}，{entity2}的{attr}为{v2}。",
    "trend": "{table}中，{entity}的{attr}在{period}为{v}。",
}
```

**关键是让每句话都自带主语（表名或实体名）**——不依赖上下文。

## 四、方案二：保留 Markdown 表格 + 表头

Markdown 表格在很多场景下是可读的，而且模型能正确解析：

```python
def df_to_markdown(df, table_name: str, unit: str = "") -> str:
    md = df.to_markdown(index=False)
    header = f"【表：{table_name}】"
    if unit:
        header += f"（单位：{unit}）"
    return f"{header}\n\n{md}"
```

**输出**：

```
【表：2024年季度财务数据】（单位：万元）

| 季度 | 营收 | 成本 | 利润 |
|---|---|---|---|
| Q1 | 1200 | 800 | 400 |
| Q2 | 1350 | 860 | 490 |
```

**关键点**：

1. **整个表格作为一个块，不切分**——表格切了就废了；
2. **加上表名和单位**——"2024年季度财务数据"是检索的关键词；
3. **用 Markdown 格式**——模型对 Markdown 表格的理解很好。

**如果表格太大（超过 100 行）**，按"行分组"切分，**每组都带表头**：

```python
def split_large_table(df, table_name: str, max_rows: int = 30):
    chunks = []
    for i in range(0, len(df), max_rows):
        part = df.iloc[i:i + max_rows]
        md = part.to_markdown(index=False)
        chunks.append(
            f"【表：{table_name}】（第 {i+1}-{min(i+max_rows, len(df))} 行）\n\n{md}"
        )
    return chunks
```

## 五、方案三：表格进结构化库，检索走 SQL

**如果表格多且需要精确计算**，走这条路：

```
表格 → 结构化存储（SQLite / PostgreSQL）
                ↓
问题 → Text-to-SQL → 查询 → 结果
```

**混合架构**最实用：

```python
class HybridTableRAG:
    def __init__(self, vectorstore, db):
        self.vectorstore = vectorstore      # 存"表格描述 + 句子化数据"
        self.db = db                        # 存原始结构化数据

    def answer(self, question: str):
        # 1. 判断问题类型
        if needs_calculation(question):      # "总和是多少"、"平均"、"对比"
            return self._sql_path(question)
        else:                                # "退款政策是什么"
            return self._vector_path(question)

    def _sql_path(self, question: str):
        # 用 LLM 生成 SQL，查结构化库
        sql = text_to_sql(question, self.schema)
        return self.db.execute(sql)
```

**判断依据**：

| 问题类型 | 走哪条路 |
|---|---|
| "XX 是什么" | 向量检索 |
| "XX 是多少" | 向量检索（数值在句子里） |
| "总和/平均/排名" | SQL |
| "对比 2023 和 2024" | SQL |
| "哪几个季度超过 X" | SQL |

## 六、表头识别：PDF 表格的第一个难关

**从 PDF 提取表格时，最常见的问题是"没有表头"**：

```
|  |  |  |          ← 表头行识别失败
| Q1 | 1200 | 800 |
```

**处理方式**：

**① 用专门工具提取**

```python
import pdfplumber

with pdfplumber.open("report.pdf") as pdf:
    for page in pdf.pages:
        tables = page.extract_tables()
        for t in tables:
            if t and len(t) > 1:
                header, *rows = t
                # 第一行当表头
                df = pd.DataFrame(rows, columns=header)
```

`pdfplumber` 和 `camelot` 比"把 PDF 转文本再猜结构"靠谱得多。

**② 多行表头要合并**

```
|  | 2024年 | 2024年 |   →   |  | 2024年Q1 | 2024年Q2 |
|  | Q1 | Q2 |              （合并成一行）
```

```python
def merge_multiline_header(table):
    header_lines = table[:2]              # 假设两行表头
    merged = []
    for col in zip(*header_lines):
        parts = [p for p in col if p]
        merged.append("".join(dict.fromkeys(parts)))    # 去重合并
    return merged, table[2:]
```

**③ 没有表头时用位置推断**

如果确实识别不出表头，**给列起通用名并说明**：

```python
df.columns = [f"列{i+1}" for i in range(len(df.columns))]
context = f"{table_name}（原表格无表头，列按从左到右编号）"
```

**至少不要静默丢失表头。**

## 七、表格进 RAG 的完整流程

```python
def process_tables(doc_path: str) -> list[Document]:
    docs = []

    with pdfplumber.open(doc_path) as pdf:
        for page_no, page in enumerate(pdf.pages, 1):
            for t_idx, table in enumerate(page.extract_tables()):
                if not table or len(table) < 2:
                    continue

                header, *rows = table
                # 1. 清理空白
                header = [h or f"列{i+1}" for i, h in enumerate(header)]
                df = pd.DataFrame(rows, columns=header).dropna(how="all")

                # 2. 上下文（表名、页码、单位）
                caption = find_caption(page, t_idx) or f"第{page_no}页表格{t_idx+1}"
                unit = find_unit(page, t_idx) or ""
                ctx = f"{caption}{f'（单位：{unit}）' if unit else ''}"

                # 3. 两种表示都存
                docs.append(Document(
                    page_content=f"【表：{ctx}】\n\n{df.to_markdown(index=False)}",
                    metadata={"type": "table", "source": doc_path,
                              "page": page_no, "rows": len(df), "caption": caption},
                ))

                # 4. 句子化版本（提升检索命中率）
                for sent in table_to_sentences(df.to_dict("records"), ctx):
                    docs.append(Document(
                        page_content=sent,
                        metadata={"type": "table_row", "source": doc_path,
                                  "page": page_no, "parent": caption},
                    ))

    return docs
```

**"两种表示都存"是关键**：

- **Markdown 版本** → 给模型看（结构清晰）；
- **句子化版本** → 用于检索（语义匹配更容易命中）。

**检索到句子化版本时，返回它的 Markdown 父表**（用 `parent` 元数据关联）。

## 八、几个坑

**① 表格必须整块保留。**
按字符切表格是灾难。**要么整表一块，要么按行分组（带表头）。**

**② 单位一定要显式写出来。**
"1200" 和 "1200 万元" 的差距很大——模型不知道单位时会瞎猜。

**③ 空值要统一处理。**
`NaN`、`-`、`N/A`、空字符串，统一成 `"-"` 或 `"不适用"`。

**④ 合并单元格要展开。**

```
| 区域 | 城市 |      | 区域 | 城市 |
| 华东 | 上海 |  →   | 华东 | 上海 |
|      | 杭州 |      | 华东 | 杭州 |
```

```python
def fill_merged_cells(df):
    return df.ffill()          # pandas 的向前填充
```

**⑤ 数字格式要一致。**
"1,200" 和 "1200" 和 "1200.00"，统一格式化，否则模型对不齐。

**⑥ 表名很重要。**
"表1" 没有信息量。"2024年季度财务数据" 才是检索的关键词。**从文档上下文中提取表名**：

```python
def find_caption(page, table_idx) -> str | None:
    """找表格上方的文字作为表名"""
    tables = page.find_tables()
    if table_idx >= len(tables):
        return None
    top = tables[table_idx].bbox[1]
    # 在表格上方 50 像素内找文字
    words = [w for w in page.extract_words() if top - 50 < w["top"] < top]
    return " ".join(w["text"] for w in words) or None
```

## 九、小结

```python
# 三种表示并存
① Markdown 表格      → 给模型看（整表不切）
② 句子化描述         → 用于检索（每行一句，含表名）
③ 结构化存储         → 用于精确计算（SQL）
```

五条原则：

```
1. 表格绝不按字符切分（要么整表，要么按行分组带表头）
2. 每句话都带表名/实体名，让句子自解释
3. 单位、页码、表名都要写进内容
4. 句子化版本检索，Markdown 版本喂模型
5. 需要计算的场景，走 SQL 而不是检索
```

**一句话：表格的"语义"在于"行列关系"，切碎就等于把这个关系毁了。** 要么完整保留，要么把它翻译成"自带主语的完整句子"——**中间态（切碎的文本）是最没用的**。
