# LLM 应用的单元测试：怎么 mock 模型和工具

「LLM 应用没法写单元测试」是个流传很广的说法。听起来有道理——输出不确定、依赖外部 API、还贵。但真正的原因是：**大家在用传统的方式测一个不确定性的东西。**

换个思路就通了：**单元测试的目标不是验证「模型答得对」，而是验证「你的代码逻辑对」。** 模型该答什么，那是评测集的事；单元测试要保证的是：给了输入 A，你的流程走到 B、调了 C、返回了 D。

这篇文章讲怎么 mock LLM、怎么 mock 工具、以及哪些东西该测哪些不该测。

---

## 一、先划清边界：测什么，不测什么

### 1.1 三个层次，别混

| 层次 | 验证什么 | 手段 | 该不该进单元测试 |
|------|---------|------|----------------|
| **我的代码逻辑** | 流程走向、状态管理、错误处理 | 单元测试（mock LLM） | ✅ 必须 |
| **提示词效果** | 模型选对工具/答对问题 | 评测集 + LLM 评判 | ❌ 太慢太贵 |
| **模型能力** | 模型本身聪不聪明 | 模型提供方的事 | ❌ 不是你的事 |

**最常见的错误是把「提示词效果」塞进单元测试**——写一个 test，调用真实 API，断言答案包含「北京」。这个测试又慢（几秒）、又贵（每次跑都花钱）、又 flaky（模型改版就挂）。

### 1.2 单元测试该测的五件事

1. **流程分支**：意图是 X 时走分支 A，是 Y 时走分支 B
2. **工具调用编排**：某条件下调用了正确的工具、参数正确
3. **错误处理**：工具超时/失败时，代码走了降级路径
4. **状态管理**：多轮对话里，上下文正确累积和传递
5. **输出格式**：结构化输出解析失败时有兜底

**这些全都不依赖模型「聪明」**—— mock 掉模型返回，测的就是纯逻辑。

---

## 二、mock 模型：三个层次

### 2.1 层次一：mock 整个 Agent（最粗）

```python
from unittest.mock import AsyncMock, patch

@patch("my_agent.create_agent")
def test_rag_flow(mock_create_agent):
    # mock 掉整个 agent，只测业务编排
    mock_agent = AsyncMock()
    mock_agent.ainvoke.return_value = {
        "messages": [("ai", "已为您查询到订单状态：已发货")]
    }
    mock_create_agent.return_value = mock_agent

    result = await handle_user_request("我的订单到哪了")
    assert "已发货" in result["text"]
    assert result["tool_used"] == "order_query"
```

**适用**：测外层业务逻辑（路由、权限、日志、格式化），不关心 Agent 内部。

### 2.2 层次二：mock LLM 客户端（推荐）

**不 mock 模型本身，只 mock 网络调用。** 这样工具调用、循环、状态管理全是真实代码。

```python
class FakeLLMClient:
    """按脚本返回响应，记录调用。"""

    def __init__(self, responses: list):
        self.responses = list(responses)
        self.calls: list[dict] = []

    async def chat(self, messages, tools=None, **kwargs):
        self.calls.append({"messages": copy.deepcopy(messages), "tools": tools})
        if not self.responses:
            raise AssertionError("FakeLLMClient 的脚本用完了")
        return self.responses.pop(0)

# 用它替换真实客户端
def test_tool_loop():
    fake = FakeLLMClient([
        # 第一轮：模型决定调工具
        {"tool_calls": [{"name": "query_order", "args": {"order_id": "ORD-12345678"}}]},
        # 第二轮：拿到工具结果后给答案
        {"content": "您的订单已发货，预计 10-20 送达。"},
    ])

    agent = build_agent(llm=fake, tools=[real_query_order_mock])
    result = agent.run("我的订单到哪了")

    assert "已发货" in result
    # 关键断言：模型确实被调用了两次，第一次带了工具 schema
    assert len(fake.calls) == 2
    assert fake.calls[0]["tools"] is not None
```

**这是最实用的层次**：编排逻辑、工具分发、循环终止条件全是真实代码，只有 LLM 那一次 HTTP 是假的。

**「脚本用完」要报错**——这能自动捕获「Agent 比预期多跑了几轮」的 bug。

### 2.3 层次三：mock 单个工具函数（最细）

```python
@patch("my_agent.tools.query_order")
async def test_order_flow(mock_query):
    mock_query.return_value = {"status": "cancelled"}

    result = await handle_cancelled_order("ORD-12345678")
    assert "已取消" in result
    mock_query.assert_called_once_with("ORD-12345678")
```

**适用**：测工具周边的逻辑（重试、降级、参数校验）。

---

## 三、mock 工具：关键是语义真实

### 3.1 不要只 mock「成功路径」

```python
# ❌ 只测 happy path
mock_search.return_value = [{"title": "文档A", "content": "..."}]

# ✅ 覆盖这些情况
SCENARIOS = {
    "normal":      {"results": [{"title": "A", "score": 0.9}]},
    "empty":       {"results": []},                      # 检索不到
    "timeout":     TimeoutError("read timeout"),         # 超时
    "rate_limit":  Exception("429 too many requests"),   # 限流
    "bad_json":    "not a json",                         # 返回格式错
    "huge":        {"results": [{"content": "x" * 100000}]},  # 巨大返回
}
```

**「empty」和「bad_json」是最该测的**——它们对应真实系统里最常见的失败，也是幻觉的高发场景。Agent 拿到空结果时是老实说「没找到」还是开始编？这个必须测。

### 3.2 mock 数据要「脏」一点

真实世界的工具返回是这样的：

```python
mock_db_query.return_value = {
    "rows": [
        {"id": 1, "name": None, "amount": "12.50"},   # None 和字符串数字
        {"id": 2, "name": "", "amount": None},
    ],
    "truncated": True,                                  # 结果被截断
    "elapsed_ms": 4500,                                  # 很慢
}
```

**mock 理想数据（干净、完整、格式统一）测不出问题**。加 None、空串、超长字段、类型不一致——这些才是暴露 bug 的。

### 3.3 用契约测试兜住 mock 的失真

mock 最大的风险是「mock 的行为和真实工具不一致了」。

```python
def test_tool_schema_matches_real():
    """确保 mock 工具和真实工具的 schema 一致。"""
    for name, tool in REAL_TOOLS.items():
        fake = FAKE_TOOLS[name]
        assert fake.signature == tool.signature, \
            f"{name} 的 mock 签名和真实不一致，测试已失真"
```

**参数签名不一致 = 测试白跑**（模型按 mock 的 schema 生成参数，真实工具收到却不认）。这个检查几行代码，能挡掉一类系统性失真。

---

## 四、pytest 基础设施

### 4.1 可复用的 fixture

```python
import pytest

@pytest.fixture
def fake_llm():
    """默认脚本：一次工具调用 + 一次回答。"""
    return FakeLLMClient([
        {"tool_calls": [{"name": "query_order", "args": {"order_id": "ORD-1"}}]},
        {"content": "订单已发货。"},
    ])

@pytest.fixture
def agent_with_mocks(fake_llm):
    return build_agent(llm=fake_llm, tools={
        "query_order": Mock(return_value={"status": "shipped"}),
    })

@pytest.fixture
def cost_tracker():
    """重置成本统计，避免测试间互相影响。"""
    CostTracker.reset()
    yield CostTracker
    CostTracker.reset()
```

### 4.2 参数化覆盖场景

```python
@pytest.mark.parametrize("tool_result,expected_behavior", [
    ({"status": "shipped"}, lambda r: "发货" in r),
    ({"status": "cancelled"}, lambda r: "取消" in r),
    (TimeoutError(), lambda r: "稍后" in r),        # 超时要走安抚话术
    ("malformed", lambda r: "格式" in r),           # 脏数据要报错
])
async def test_order_status_handling(agent_with_mocks, tool_result, expected_behavior):
    agent_with_mocks.tools["query_order"].side_effect = tool_result
    result = await agent_with_mocks.run("我的订单状态")
    assert expected_behavior(result)
```

**参数化是 LLM 应用测试的利器**——同一套逻辑，喂不同工具返回，一次跑完所有分支。

### 4.3 时间控制

```python
from freezegun import freeze_time

@freeze_time("2026-10-16 12:00:00")
def test_relative_time_handling(agent_with_mocks):
    """固定时间，让「三天前」这类相对表达变成确定的。"""
    result = await agent.run("三天前的订单")
    # 时间固定，断言才能稳定
    assert "2026-10-13" in result
```

---

## 五、可观测性断言

除了结果，**断言「过程」同样重要**：

```python
def test_no_unnecessary_retries(agent_with_mocks, cost_tracker):
    """工具一次成功时，不应该触发重试（省 token）。"""
    await agent.run("查订单")
    assert cost_tracker.calls_by_stage["retry"] == 0

def test_context_growth_bounded(agent_with_mocks):
    """多轮对话后上下文不能无限膨胀。"""
    for i in range(10):
        await agent.run(f"第 {i} 个问题")
    last_call = fake_llm.calls[-1]
    assert estimate_tokens(last_call["messages"]) < 8000, "上下文失控了"

def test_max_iterations_respected(agent_with_mocks, fake_llm):
    """死循环保护：即使模型一直调工具，也要有上限。"""
    fake_llm.responses = [
        {"tool_calls": [{"name": "loop_tool", "args": {}}]} for _ in range(50)
    ]
    with pytest.raises(MaxIterationsExceeded):
        await agent_with_mocks.run("触发死循环")
    assert len(fake_llm.calls) <= MAX_ITERATIONS + 1
```

**这几个测试抓的是真实生产事故**：无限重试烧钱、上下文膨胀、死循环打满配额。用 mock 脚本（永远返回同一个 tool_call）触发它们，零成本。

---

## 六、测试集的组织

### 6.1 分三类，跑不同时机

```
tests/
├── unit/               # 纯逻辑，毫秒级
│   ├── test_routing.py
│   ├── test_tool_dispatch.py
│   └── test_error_handling.py
├── contract/           # schema 一致性，秒级
│   └── test_tool_schemas.py
└── eval/               # 需要真实模型，分钟级，CI 里单独跑
    ├── eval_set.json
    └── run_eval.py
```

**CI 里的分层**：

- 每次 commit：跑 `unit` + `contract`（秒级）
- 每天 / 每次发版：跑 `eval`（分钟级、花钱）
- 手动：全量 eval + 人工抽检

### 6.2 别写「验答案」的测试

```python
# ❌ 这种测试迟早变 flaky
async def test_answer():
    result = await real_agent.run("北京天气")
    assert "晴" in result          # 模型改版 / 天气变化 → 挂

# ✅ 测结构不测内容
async def test_answer_structure():
    result = await real_agent.run("北京天气")
    assert result.tool_used == "weather"
    assert len(result.text) > 10
    assert result.confidence > 0
```

**内容对不对，交给 eval 集。单元测试只管「形状对不对」。**

---

## 七、常见误区

**误区一：测模型输出内容。** 又慢又贵又 flaky。测流程和结构，内容交给 eval。

**误区二：mock 只给理想数据。** 测不出空结果、超时、脏数据的处理。**必须覆盖失败路径。**

**误区三：mock 工具签名和真实不一致。** 测试全白跑还不报错。用契约测试拦住。

**误区四：FakeLLMClient 脚本用完不报错。** 那 Agent 多跑几轮你完全不知道。脚本耗尽应该是硬错误。

**误区五：只测 happy path。** LLM 应用的 bug 八成在异常路径（工具失败、格式错、上下文超限）。

**误区六：没有循环保护和预算断言。** 「最多跑几轮」「最多花多少 token」这类护栏，用 mock 脚本最容易测。

**误区七：eval 塞进 unit。** CI 每分钟花钱。分层，跑不同时机。

---

## 小结

- LLM 应用**能写单元测试**，但要换目标：测**你的代码逻辑**，不测**模型聪不聪明**（那是 eval 集的事）。
- mock 模型的三个层次：**整个 Agent（测外层）→ LLM 客户端（测编排，最推荐）→ 单个工具函数（测细节）**。中间层让工具分发、循环、状态全是真实代码，最划算。
- **FakeLLMClient 的脚本耗尽必须是硬错误**——它自动捕获「Agent 比预期多跑了几轮」。
- mock 工具必须覆盖：**空结果、超时、限流、格式错、超大返回**。空和脏数据是最该测的（幻觉高发场景）。
- **契约测试**校验 mock 签名和真实工具一致，否则测试系统性失真。
- 必测的四类护栏：**重试次数（不该重试时别重试）、上下文增长上限、最大迭代数、预算上限**——用 mock 脚本触发，零成本。
- CI 分层：unit + contract 每次 commit 跑（秒级），eval 每天跑（花钱），别混。
- 断言**结构不测内容**：`tool_used` 对、长度合理、有 confidence，比断言答案含某个词稳得多。

单元测试拦住的是你的 bug；eval 集管的是模型的效果。两者分工清楚了，才能既快又稳地迭代。
