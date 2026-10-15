# 多表 SQL 智能体：让它先看懂表结构，再写 SQL

> "帮我查上个月每个渠道的复购率"。
> 这句话背后是 3 张表、2 个 JOIN、1 个窗口函数。
>
> 单表 Text-to-SQL 已经不太好做，多表更是难上加难。
> 这篇讲怎么把复杂度控制在模型能力范围内。

## 一、多表为什么难

| 难点 | 具体表现 |
|---|---|
| 表名无语义 | `t_ord_h` 是什么？模型只能猜 |
| JOIN 关系不明 | 哪两张表能 JOIN？走哪个键？ |
| 字段重复 | 5 张表都有 `status`，含义各不同 |
| 业务口径 | "复购率" 在不同公司定义不同 |
| 数据量差异 | 大表要加时间过滤，小表不用 |

**核心矛盾：模型看不到数据库，只能看你给的描述。**

## 二、第一步：把 schema 描述清楚

不要给 `CREATE TABLE` 语句，要给**带注释的、精简的**结构：

```python
SCHEMA = """
## 表：orders（订单表）
- order_id      BIGINT   订单号，主键
- user_id       BIGINT   用户ID，关联 users.user_id
- channel_id    INT      渠道ID，关联 channels.id。1=自然流量 2=投放 3=私域
- amount        DECIMAL  订单金额（元），含税
- status        TINYINT  1=待支付 2=已支付 3=已退款。**已支付才算有效订单**
- created_at    DATETIME 下单时间

## 表：users（用户表）
- user_id       BIGINT   用户ID，主键
- register_at   DATETIME 注册时间
- city          VARCHAR  城市

## 表：channels（渠道表）
- id            INT      渠道ID，主键
- name          VARCHAR  渠道名
"""
```

三个原则：

1. **只给相关的表**。20 张表全塞进去，模型会挑错；
2. **写明枚举值和业务含义**（"已支付才算有效订单"）；
3. **写明关联键**（"关联 users.user_id"）。

## 三、第二步：先做表选择，再写 SQL

**两步走的准确率远高于一步到位**：

```python
from pydantic import BaseModel, Field

class TableSelection(BaseModel):
    tables: list[str] = Field(description="完成这个查询需要哪些表，只填表名")
    reasoning: str = Field(description="为什么需要这些表")

selector = llm.with_structured_output(TableSelection)

def select_tables(question: str, all_schema: str) -> list[str]:
    result = selector.invoke(f"""从下面的数据库中选出回答问题所需的表。

问题：{question}

数据库表结构：
{all_schema}

只选**必需**的表，不要多选。""")
    return result.tables
```

然后只把选中的表放进 SQL 生成的提示词：

```python
def generate_sql(question: str, tables: list[str], full_schema: str) -> str:
    # 从完整 schema 里截取选中表的描述
    partial_schema = extract_schema(full_schema, tables)
    return sql_llm.invoke(f"""根据下面的表结构写出 SQL。

表结构：
{partial_schema}

问题：{question}

要求：
1. 只输出 SQL，不要解释；
2. 使用标准 MySQL 语法；
3. 大表查询必须带时间范围过滤（orders.created_at）；
4. 字段名用反引号包裹。""").content
```

**表选择这一步是准确率的分水岭**——多表场景下能提升 15~30 个百分点。

## 四、第三步：给模型"业务口径"字典

"复购率"、"活跃用户"、"有效订单"这类词，必须显式定义：

```python
METRICS = {
    "复购率": "同一用户在统计周期内下单 >= 2 次的占比，分母是周期内有下单的用户数",
    "活跃用户": "统计周期内有过有效订单（status=2）的用户",
    "有效订单": "status = 2 的订单，不含已退款",
    "GMV": "有效订单的 amount 之和，不含退款",
    "客单价": "GMV / 下单用户数（去重）",
    "新客": "register_at 在统计周期内的用户",
}

GLOSSARY = "\n".join(f"- {k}：{v}" for k, v in METRICS.items())

SQL_PROMPT = """根据表结构写 SQL。

【业务口径】（必须严格遵守）
{glossary}

【表结构】
{schema}

【问题】
{question}
"""
```

**没有口径字典，模型会按自己的常识猜**——它猜的"复购率"多半和你的定义不一样。

## 五、第四步：给几个 few-shot 例子

多表 JOIN 的写法，一个例子胜过一段说明：

```python
EXAMPLES = """
【示例 1】
问题：统计每个渠道的订单数
SQL：
SELECT c.name AS channel_name, COUNT(*) AS order_cnt
FROM orders o
JOIN channels c ON o.channel_id = c.id
WHERE o.status = 2
  AND o.created_at >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
GROUP BY c.name
ORDER BY order_cnt DESC;

【示例 2】
问题：找出下单超过 3 次的用户
SQL：
SELECT u.user_id, u.city, COUNT(*) AS cnt
FROM users u
JOIN orders o ON u.user_id = o.user_id
WHERE o.status = 2
  AND o.created_at >= DATE_SUB(CURDATE(), INTERVAL 90 DAY)
GROUP BY u.user_id, u.city
HAVING COUNT(*) > 3;
"""
```

**示例要覆盖你最常用的 JOIN 模式**：一对多、多对多、自关联各来一个。

## 六、第五步：SQL 校验（关键）

**永远不要直接执行模型生成的 SQL。**

**① 语法校验**

```python
import sqlglot

def validate_syntax(sql: str, dialect: str = "mysql") -> tuple[bool, str]:
    try:
        sqlglot.parse_one(sql, read=dialect)
        return True, ""
    except Exception as e:
        return False, str(e)
```

**② 安全性校验**

```python
FORBIDDEN = ("insert", "update", "delete", "drop", "truncate", "alter",
             "create", "grant", "revoke", "into outfile", "load_file")

def is_read_only(sql: str) -> tuple[bool, str]:
    lowered = sql.lower()
    for kw in FORBIDDEN:
        if re.search(rf"\b{kw}\b", lowered):
            return False, f"检测到非只读操作：{kw}"
    if not lowered.strip().startswith(("select", "with")):
        return False, "只允许 SELECT / WITH 查询"
    return True, ""
```

**③ 表名白名单**

```python
ALLOWED_TABLES = {"orders", "users", "channels", "products"}

def check_tables(sql: str) -> tuple[bool, str]:
    parsed = sqlglot.parse_one(sql, read="mysql")
    used = {t.name for t in parsed.find_all(sqlglot.exp.Table)}
    illegal = used - ALLOWED_TABLES
    if illegal:
        return False, f"使用了未授权的表：{illegal}"
    return True, ""
```

**④ 语法解析能拿到真实表名，比正则可靠**。上面用 `sqlglot` 的 AST 来提取表名——正则会被子查询、别名、注释绕过。

## 七、第六步：执行 + 结果校验

```python
def run_sql(sql: str, conn) -> list[dict]:
    # 1. 加超时和行数限制
    safe_sql = sql if "limit" in sql.lower() else f"{sql.rstrip(';')} LIMIT 1000"

    # 2. 只读事务
    with conn.cursor() as cur:
        cur.execute("SET SESSION TRANSACTION READ ONLY")
        cur.execute(f"SET SESSION MAX_EXECUTION_TIME=5000")     # 5 秒超时
        cur.execute(safe_sql)
        return cur.fetchall()
```

**三个保护**：

1. **`LIMIT`** —— 防止返回百万行打爆内存；
2. **`MAX_EXECUTION_TIME`** —— 防止全表扫描拖垮数据库；
3. **只读连接** —— 用只读账号，物理上不可能写。

## 八、出错时让模型自己修

SQL 执行报错，是**最有价值的学习信号**：

```python
def text_to_sql(question: str, conn, max_attempts: int = 3):
    tables = select_tables(question, SCHEMA)
    error_history = []

    for attempt in range(max_attempts):
        sql = generate_sql(question, tables, error_history)

        ok, err = validate_syntax(sql)
        if not ok:
            error_history.append({"sql": sql, "error": f"语法错误：{err}"})
            continue

        ok, err = is_read_only(sql)
        if not ok:
            raise PermissionError(err)          # 安全问题不该重试

        try:
            rows = run_sql(sql, conn)
            return sql, rows
        except Exception as e:
            # 数据库报错：把错误信息回灌
            error_history.append({"sql": sql, "error": str(e)[:300]})

    raise RuntimeError("多次尝试后仍无法生成可执行的 SQL")
```

`generate_sql` 把 `error_history` 拼进提示词：

```python
if error_history:
    hist = "\n\n".join(
        f"尝试 {i+1}：\n{sql}\n错误：{err}"
        for i, (sql, err) in enumerate(error_history)
    )
    prompt += f"\n\n【之前的失败尝试】\n{hist}\n\n请修正上述错误。"
```

**数据库的错误信息（"Unknown column 'x'"、"Table 'y' doesn't exist"）比模型的猜测精确得多**，是第一手的修复线索。

## 九、一个完整的 Agent 形态

用 LangGraph 组装起来：

```python
from langgraph.graph import StateGraph, MessagesState, START, END

class SQLState(MessagesState):
    question: str
    tables: list[str]
    sql: str
    rows: list
    attempts: int

builder = StateGraph(SQLState)
builder.add_node("select_tables", select_tables_node)
builder.add_node("write_sql", write_sql_node)
builder.add_node("validate", validate_node)
builder.add_node("execute", execute_node)
builder.add_node("fix", fix_sql_node)
builder.add_node("answer", answer_node)

builder.add_edge(START, "select_tables")
builder.add_edge("select_tables", "write_sql")
builder.add_edge("write_sql", "validate")
builder.add_conditional_edges("validate", lambda s: "execute" if s["valid"] else "fix")
builder.add_conditional_edges("execute",
    lambda s: "answer" if s["rows"] is not None else "fix")
builder.add_edge("fix", "write_sql")
builder.add_edge("answer", END)
```

这个图的形状是：**写 → 校验 → 执行，任何一步失败都回到"写"（带上错误）**。

## 十、几个实践要点

**① 表结构描述要维护成"活文档"。**
库加了字段，描述忘了更新，模型就会报"未知字段"。**把 schema 描述生成做成脚本**，从 `information_schema` 自动拉。

**② 大表的过滤条件要写进 schema 描述。**

```
## 表：orders（订单表，约 8000 万行）
⚠️ 查询必须带 created_at 范围过滤，否则会全表扫描
```

**③ 别让模型自己决定要不要加 LIMIT。**
在提示词里写死"必须加 LIMIT"，或者在执行层强制加。

**④ 结果也要让模型解读。**
返回 200 行原始数据给用户没意义。让模型**基于结果数据**写一句话总结，但**禁止它凭空编数据**：

```python
ANSWER_PROMPT = """根据查询结果回答用户问题。

【用户问题】{question}
【执行的 SQL】{sql}
【查询结果】{rows}

**严格要求**：
- 只依据上面的结果数据回答，不要推测、不要补充不存在的数据；
- 结果是空的就直说"没有查询到数据"；
- 涉及数值时直接引用结果里的数字。"""
```

**⑤ 多轮追问要带上下文。**

```
用户：查每个渠道的订单数
（模型执行，返回结果）
用户：那换成上季度呢
```

第二轮的"那"依赖第一轮的 SQL。做法是**把上一轮的 SQL 一起放进上下文**，让模型做增量修改。

## 十一、小结

多表 Text-to-SQL 的六步：

```
① schema 描述清楚（带注释、带枚举、带关联）
② 先选表，再写 SQL
③ 业务口径字典（必须显式定义）
④ few-shot 示例（覆盖常见 JOIN 模式）
⑤ 安全 + 语法校验（sqlglot 解析 AST）
⑥ 执行出错就回灌修复
```

一句话：**别指望模型一步写出正确的多表 SQL。** 把它拆成"选表 → 写 → 校验 → 修"的循环，每一步都做小，成功率才有保障。
