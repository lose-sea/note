# 代码仓库怎么切分：按语法，不按长度

> 把代码按 800 字一刀切，会切出这样的块：
> ```python
>             return None
>
>     def process(self, data):
>         """处理数据"""
> ```
>
> **一个函数的前半在上一块，后半在这一块——两块都没法用。**

## 一、代码为什么不能按长度切

| 问题 | 例子 |
|---|---|
| 函数被切断 | 签名和实现分离 |
| 缩进错乱 | 块开头是一堆缩进 |
| 类被切碎 | 方法散落在多个块 |
| 跨文件引用丢失 | `import` 在一个块，用法在另一个 |

**代码的语义边界是语法结构（函数、类、模块），不是字符数。**

## 二、按语言切分：LangChain 的方案

```python
from langchain_text_splitters import RecursiveCharacterTextSplitter, Language

splitter = RecursiveCharacterTextSplitter.from_language(
    language=Language.PYTHON,
    chunk_size=1000,
    chunk_overlap=0,               # 代码通常不需要重叠
)
```

**它用的分隔符是语法级的**：

```python
# Python 的分隔符（大致）
["\nclass ", "\ndef ", "\n\tdef ", "\n\n", "\n", " ", ""]
```

**优先在 `class` 和 `def` 前切**——这样"函数"成了最小的切分单元。

支持的语言：

```python
Language.PYTHON, Language.JS, Language.TS, Language.JAVA,
Language.GO, Language.RUST, Language.CPP, Language.C,
Language.HTML, Language.SOL, Language.RUBY, Language.PHP,
```

## 三、更好的方案：用 AST 按函数切

`from_language` 还是"文本级"的——它只是找 `def ` 这个字符串。**真正按语法切要用 AST。**

```python
import ast

def split_python_by_ast(source: str) -> list[dict]:
    """按顶层函数/类切分 Python 代码"""
    tree = ast.parse(source)
    lines = source.splitlines()
    chunks = []

    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            start = node.lineno - 1
            # 包含前面的装饰器和注释
            while start > 0 and (lines[start-1].strip().startswith("@")
                                 or lines[start-1].strip().startswith("#")):
                start -= 1
            end = node.end_lineno

            code = "\n".join(lines[start:end])
            chunks.append({
                "name": node.name,
                "type": type(node).__name__,
                "start_line": start + 1,
                "end_line": end,
                "content": code,
            })

    return chunks
```

**得到的是结构化的块**：

```python
[
    {"name": "Embedding", "type": "ClassDef", "start_line": 5, "end_line": 42, "content": "..."},
    {"name": "search", "type": "FunctionDef", "start_line": 44, "end_line": 61, "content": "..."},
    ...
]
```

**关键收益：每个块是一个完整可用的代码单元。**

## 四、加"代码上下文头"

单独一个函数块，模型不知道它属于哪个模块、依赖什么。**给每个块加一个头部**：

```python
def enrich_code_chunk(chunk: dict, file_path: str, module_doc: str) -> str:
    header = f"""# 文件：{file_path}
# 模块：{module_doc or '(无模块说明)'}
# 定义：{chunk['type']} {chunk['name']}（第 {chunk['start_line']}-{chunk['end_line']} 行）
"""
    return header + chunk["content"]
```

效果：

```python
# 文件：src/embedding.py
# 模块：文本向量化模块，提供向量生成与相似度计算
# 定义：FunctionDef search（第 44-61 行）
def search(query: str, top_k: int = 5) -> list[Result]:
    ...
```

**现在这个块是自解释的**——检索出来之后，模型知道这是什么文件、什么模块、哪个函数。

## 五、类怎么处理

一个类有 500 行，切不切？**分情况**：

```python
def split_class(node, lines, max_lines: int = 80):
    """类太大就按方法拆，否则整类保留"""
    if node.end_lineno - node.lineno <= max_lines:
        return [extract(node, lines)]           # 整类保留

    chunks = []
    # 类签名 + 类级属性和文档字符串
    header_end = node.body[0].lineno - 1 if node.body else node.lineno
    header = "\n".join(lines[node.lineno-1 : header_end])
    header += f"\n    # ... 以下为 {node.name} 的方法 ..."

    # 每个方法单独成块，带上类名
    for item in node.body:
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
            code = extract(item, lines)
            chunks.append({
                "name": f"{node.name}.{item.name}",
                "type": "Method",
                "content": f"class {node.name}:\n" + indent(code, 4) + "\n" + header,
            })
    return chunks
```

**每个方法块都带上类名**（`Embedding.encode`），检索时能准确匹配。

## 六、非 Python 语言怎么办

**JavaScript / TypeScript**：用 `tree-sitter`

```python
from tree_sitter import Language, Parser
import tree_sitter_python

parser = Parser(Language(tree_sitter_python.language()))

def split_by_treesitter(code: str, target_nodes=("function_declaration",)) -> list[str]:
    tree = parser.parse(code.encode())
    chunks, src = [], code.encode()

    def walk(node):
        if node.type in target_nodes:
            chunks.append(src[node.start_byte:node.end_byte].decode())
        for child in node.children:
            walk(child)

    walk(tree.root_node)
    return chunks
```

`tree-sitter` 支持几乎所有主流语言，**是跨语言代码切分的标准工具**。

**通用兜底**：按"空行 + 缩进"分块

```python
def split_by_blank_lines(code: str, max_len: int = 1500) -> list[str]:
    """按空行分段，超长的再合并或再切"""
    blocks = [b.strip() for b in code.split("\n\n") if b.strip()]
    out, cur = [], ""
    for b in blocks:
        if len(cur) + len(b) > max_len and cur:
            out.append(cur)
            cur = b
        else:
            cur = cur + "\n\n" + b if cur else b
    if cur:
        out.append(cur)
    return out
```

**这个兜底方案在缩进规范的代码上效果不错**——因为程序员本来就用空行分隔逻辑段落。

## 七、代码的检索要带上下文

**代码检索有个特殊需求：找到函数后，往往还需要"调用示例"。**

**做法一：把 docstring 单独作为一块**

```python
docstring_chunk = f"{func_name} 的说明：{docstring}"
```

**做法二：把测试用例关联进来**

```python
# 找到测试这个函数的测试代码
tests = find_tests_for(func_name)
for t in tests:
    chunks.append({"type": "test", "related_to": func_name, "content": t})
```

**做法三：检索时返回"函数 + 它的依赖"**

```python
def get_with_deps(func_name: str, depth: int = 1):
    """返回函数及其直接调用的其他函数"""
    func = code_index[func_name]
    calls = extract_calls(func.content)
    related = [code_index[c] for c in calls if c in code_index][:3]
    return [func] + related
```

## 八、元数据设计

代码块的 metadata 是**检索质量的关键**：

```python
metadata = {
    "file_path": "src/embedding.py",
    "language": "python",
    "type": "function",              # function / class / method / test
    "name": "search",
    "qualified_name": "Embedding.search",
    "start_line": 44,
    "end_line": 61,
    "module": "embedding",
    "imports": ["numpy", "typing"],   # 依赖，用于判断可用性
    "docstring": "...",
}
```

**可以按类型过滤**：

```python
# 只检索函数定义，不检索测试代码
retriever = vectorstore.as_retriever(
    search_kwargs={"filter": {"type": "function"}}
)
```

**可以按文件过滤**：

```python
search_kwargs={"filter": {"file_path": {"$regex": "^src/"}}}
```

## 九、几个坑

**① 别把整个文件当一个块。**
一个 2000 行的文件，向量表示会非常模糊。

**② 别切掉 `import` 语句。**
"这个函数用了什么库"是重要信息。做法：**把文件的 import 汇总拼到每个块头部**。

```python
imports_block = "\n".join(f"import {i}" for i in file_imports)
chunk_content = f"# 依赖：\n{imports_block}\n\n{chunk_content}"
```

**③ 缩进要保留。**
Markdown 渲染时缩进会被吃掉，但检索和模型理解都需要。**用代码块包裹**：

````python
f"```{language}\n{code}\n```"
````

**④ 长函数要标记"未完整展示"。**
如果函数超过 max_len 被截断，要明确标注：

```python
if len(code) > max_len:
    code = code[:max_len] + f"\n# ... (函数共 {total} 行，此处截断) ..."
```

**⑤ 别在切分时做"代码格式化"。**
不要试图重新缩进或美化——**会改变行号**，且可能引入错误。

## 十、小结

```python
# 优先级：AST > tree-sitter > from_language > 空行分段
chunks = split_python_by_ast(source)          # 最准
chunks = [enrich_code_chunk(c, path, doc) for c in chunks]
```

五条原则：

```
1. 按语法边界切，按长度切是下策
2. 每个块加上下文头（文件/模块/函数名/行号）
3. 每个块带上 import 汇总
4. 大类的每个方法单独成块，带类名
5. metadata 记全（路径/类型/限定名/行号）
```

**一句话：代码的"语义单元"是函数和类，不是字符数。** 按语法切，每个块就是一个可用的代码单元；按长度切，每块都是残缺的碎片。
