# 时间旅行：回退状态重放某一步

有了 Checkpointer，图的每一步都被存成了快照。这带来的一个「超能力」叫 **时间旅行（Time Travel）**：你可以回到历史某一步的状态，改一改，再往下重放，而不用从头跑整张图。调试 Agent 时这比打日志高效得多。

## 一、取出任意历史状态

```python
states = app.get_state_history(cfg)   # 按时间倒序列出所有检查点
for s in states:
    print(s.config, s.metadata, s.values)
```

`get_state_history` 返回这张图在这个 thread_id 下的完整「时间线」，每个元素是当时那一瞬间的状态。

## 二、用 update_state 改写过去

假设第 3 步模型答错了，你想改它的输出再重放后面几步：

```python
# 取历史里第 3 步那个检查点
target = list(app.get_state_history(cfg))[2]
# 把那一步的 messages 改掉，并指定「从哪个节点之后」继续
app.update_state(
    target.config,
    {"messages": [AIMessage(content="修正后的正确回答")]},
    as_node="step3",     # 以 step3 为基准重放
)
```

`update_state` 会基于你给的新值，从 `as_node` 指定的节点往后重新执行后续边，生成新的检查点。

## 三、为什么叫「时间旅行」

因为你可以：

- **回到过去**：查看任意历史检查点的状态；
- **改写过去**：用 `update_state` 覆盖某步的输出；
- **重放未来**：从改写点往后重新跑，观察不同输入带来的不同结局。

这相当于给 Agent 装了「存档/读档」。对比传统做法（改代码、重新发请求、祈祷能复现），时间旅行直接在已发生的轨迹上做实验，确定性高得多。

## 四、典型用途

- **调试**：哪一步答错，回去改那一步重放，定位问题；
- **AB 对比**：同一个前半段，换不同后半段策略重放，比较效果；
- **纠错补偿**：发现早期状态有误，改写后重放，避免整轮重算。

前提依然是 Checkpointer——没有快照，「旅行」就没有站点。把图跑出「时间线」，调试 Agent 就从碰运气变成可复现的工程。
