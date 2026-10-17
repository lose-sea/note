# 图表生成 Agent：让 AI 画图，不是让它编图

"帮我画一个三季度销售趋势图"——用户说完这句， Agent 的噩梦开始：让模型直接生成图片？多数模型没有多模态输出能力；让模型写 HTML/SVG 代码？它经常在 CSS 和坐标计算上翻车；让模型调用一个图表工具？数据从哪来、参数怎么传、图错了谁背锅？这篇文章讲一个可靠的图表生成 Agent 怎么搭：**不让模型"画"图，让模型"写代码"画图**。

## 核心架构决策：模型不直接出图

先定架构。三个候选路线：

**路线一：模型直接生成图片**。DALL·E、GPT Image 这类可以做，但用于数据图表是灾难——它擅长画"感觉像"的图，不擅长精确反映数据。你要的柱高比例 3:2，它给你画个 5:4，"颜值尚可，数据全错"。数据可视化的底线是数据保真，此路出局。

**路线二：模型生成 Python/matplotlib 代码并执行**。主流方案。模型写代码，后端执行代码出图。数据准确性问题转化为"代码对不对"的问题——可验证、可测试、可调试。风险是代码执行安全，沙箱里跑，下一篇会详述隔离方案。

**路线三：模型生成图表 DSL/配置**。比如 ECharts 的 option JSON、Vega-Lite 规范。数据保真没问题，但表达力被 DSL 限制——用户要个稍微定制的组合图，DSG 不支持就卡住。

生产系统常是**路线三为主、路线二兜底**：常规图表（柱线饼散点）走 DSL 配置，安全可控；用户描述含定制需求（双轴、组合、特殊标注）时让模型写 Python 代码。这篇文章按这个混合架构展开。

## 数据从哪来：图表 Agent 的前提

图表 Agent 不能凭空画图，它必须挂在一个**数据源**上。三种形态：

1. **用户上传的数据**（CSV/Excel）：Agent 管道读文件 → DataFrame，图表请求基于这份数据。
2. **数据查询工具**：Agent 通过 NL2SQL 或内部查询 API 拿数据。
3. **上下文里的表格**：对话历史或文档里有现成的数据表。

不管哪种，最终都收敛到一个统一抽象：**一份 DataFrame + 一句自然语言意图**。Agent 的任务就是这两样 → 一张图。

```python
# 统一入口
@dataclass
class ChartRequest:
    df: pd.DataFrame          # 已就绪的数据
    intent: str               # "画各区域销售额的柱状图，按降序"
    style: dict = field(default_factory=dict)  # 可选：主题色、尺寸
```

## 模型的任务：生成不可执行的 JSON，执行器干粗活

关键设计：**模型只负责"结构化描述"，不直接写最终代码**。让它输出一个中间表示（IR），核心字段：

```json
{
  "chart_type": "bar",
  "encoding": {
    "x": {"field": "region", "type": "nominal", "sort": "descending"},
    "y": {"field": "sales", "type": "quantitative", "aggregate": "sum"}
  },
  "filters": [{"field": "quarter", "op": "==", "value": "Q3"}],
  "options": {"title": "Q3 各区域销售额", "stacked": false, "top_n": 10}
}
```

这个 IR 就是 Vega-Lite 的子集。执行器把 IR 编译成 ECharts option、matplotlib 代码、或直接渲染。模型做它擅长的**意图理解 + 图表语义决策**（哪个字段做维度、怎么聚合、要不要 topN），执行器做它擅长的**精确渲染**。

这个设计的三个好处：

- **数据保真有保证**：聚合、过滤、排序都由执行器代码完成，没有模型"心算"的环节。
- **可校验**：IR 是结构化的，渲染前可以跑校验——字段是否存在于 DataFrame、聚合函数是否支持、图表类型是否在白名单。校验失败直接抛回让模型改，比代码执行错了再 debug 高效。
- **可渲染到多端**：同一个 IR，Web 端出 ECharts option，报告模式出 matplotlib PNG。模型侧零改动。

## 实现：带校验闭环的生成器

```python
import json

ALLOWED_CHART_TYPES = {"bar", "line", "pie", "scatter", "area", "heatmap"}
ALLOWED_AGGS = {"sum", "mean", "count", "max", "min", "median"}

def build_ir(df: pd.DataFrame, intent: str, llm) -> dict:
    """生成 IR + 校验 + 反馈重试闭环"""
    schema = describe_df(df)  # "region(str), sales(float), quarter(str)"
    prompt = f"""数据 schema：
{schema}
样本：
{df.head(3).to_csv(index=False)}

用户意图：{intent}

输出图表 IR JSON（严格按此 schema）：
- chart_type: 只能取 {ALLOWED_CHART_TYPES}
- encoding: 每个维度含 field(必须存在于 schema)/type/aggregate(only for y)
- filters: 可选
- options: title 必填
"""

    messages = [{"role": "user", "content": prompt}]
    feedback = None
    for attempt in range(3):
        resp = llm.chat(messages)
        ir = safe_json_parse(resp)          # 容忍 code fence
        ok, err = validate_ir(ir, df)       # 见下
        if ok:
            return ir
        messages.append({"role": "assistant", "content": resp})
        messages.append({"role": "user", "content": f"IR 校验失败：{err}，请修正"})
        # 最后一次仍失败 → 降级
        if attempt == 2:
            raise ChartGenError("IR 连续三次校验失败")

def validate_ir(ir: dict, df: pd.DataFrame) -> tuple[bool, str]:
    if ir.get("chart_type") not in ALLOWED_CHART_TYPES:
        return False, f"不支持的图表类型：{ir.get('chart_type')}"
    for axis in ("x", "y"):
        enc = ir.get("encoding", {}).get(axis)
        if not enc or enc["field"] not in df.columns:
            return False, f"{axis} 轴字段不存在：{enc and enc.get('field')}"
        if axis == "y" and enc.get("aggregate") not in ALLOWED_AGGS:
            return False, f"不支持的聚合：{enc.get('aggregate')}"
    return True, ""
```

`validate_ir` 是整个方案的安全带：**模型输出永远先校验再执行**。校验失败把错误原因喂回去让它修，比执行时报错友好得多。

## 执行器：IR → matplotlib / ECharts

以 matplotlib 为例：

```python
def render_matplotlib(ir: dict, df: pd.DataFrame, path: str) -> str:
    data = apply_filters(df, ir.get("filters", []))
    agg = ir["encoding"].get("y", {}).get("aggregate", "sum")
    grouped = data.groupby(ir["encoding"]["x"]["field"],
                           observed=True)[ir["encoding"]["y"]["field"]].agg(agg)
    if ir["options"].get("top_n"):
        grouped = grouped.sort_values(ascending=False).head(ir["options"]["top_n"])

    import matplotlib
    matplotlib.use("Agg")
    plt = matplotlib.pyplot
    fig, ax = plt.subplots(figsize=ir.get("options", {}).get("size", (10, 6)))
    grouped.plot(kind=ir["chart_type"], ax=ax)
    ax.set_title(ir["options"].get("title", ""))
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
    return path
```

工程细节都在看不见处：`observed=True` 防 category 型分组报未使用组合的警告；topN 先排序再截断；中文字体要显式设置（`plt.rcParams["font.sans-serif"] = ["SimHei"]`），不然中文标签全是方框。

## 工具集设计：把图表能力挂进 Agent

一个完整图表 Agent 的工具面：

| 工具 | 用途 | 参数 |
|---|---|---|
| `load_data` | 用户上传文件 → DataFrame（缓存 session 级） | file_id |
| `describe_data` | schema + 列统计，模型生成 IR 前必调 | df_id |
| `generate_chart` | IR → 渲染图片/URL | df_id, ir |
| `get_data_sample` | 取前 N 行，模型校验字段语义用 | df_id, n |
| `edit_chart` | 在上一张图基础上增量改（换字段/改类型/加过滤） | chart_id, 变更描述 |

`edit_chart` 很重要——真实用户的图形需求是对话式演进的："对，换成折线""把上海去掉""再加个同比线"。每次全量重生成，上下文丢了；维护一个 chart_id → IR 的映射，增量修改走同一个校验闭环。

陷阱提醒：**图表 Agent 的图要能点**。图片是死物：用户看到 8 月有个尖峰，想问"8月发生了什么"，纯图片 Agent 接不住。更好的产品形态是图 + 底层数据表链接，用户追问"8 月"时直接把对应行数据进上下文。图是入口，数据是本体。

## 测试：图表对错如何断言

图表生成的正确性是"像素级 diff 没意义，语义级 diff 难自动化"的经典难题。实践三个层次：

- **单元层测执行器**：给定 IR + 固定 DataFrame，断言渲染出的数据序列正确（直接断言聚合用的中间结果 grouped 序列，比断言 PNG 靠谱）。
- **校验层测 validate_ir**：对一组坏 IR 构造测试集，断言每个都被拦住且错误信息准确。
- **端到端走评测集**：20~50 个"数据 + 意图 → 期望 IR 结构"对，跑生成全流程，比对 IR 的关键字段（chart_type、聚合函数、过滤条件）而不是全量比对。这就是前几篇文章评测框架的变形用法。

## 结语

图表生成 Agent 的核心心法：**模型管语义，执行器管精确，IR 做契约**。让模型输出结构化的中间表示，校验器守门，渲染引擎精确执行，既拿到 LLM 的意图理解能力，又守住数据可视化不可妥协的数据保真底线。配上对话式的增量编辑和可回溯的数据底表，这个 Agent 才从"玩具"变成"工具"。下一篇把同一套思路搬到更大的场景：数据分析 Agent。
