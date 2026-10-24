# 人机协同：用 interrupt 把控制权交给你

很多 Agent 场景不能让模型「自己一路跑到黑」：发邮件前要确认、执行删除前要授权、关键决策要人拍板。LangGraph 用 **interrupt（中断）** 机制，让图在某个节点暂停、把控制权交还给调用方，等人给出答复后再继续。

## 一、在节点里调用 interrupt

```python
from langgraph.types import interrupt, Command
from langgraph.graph import StateGraph, START, END, MessagesState
from langgraph.checkpoint.memory import MemorySaver
from langchain_core.messages import HumanMessage, AIMessage

def human_review(state: MessagesState):
    # 运行到这里会暂停，把问题抛给外部
    decision = interrupt({"question": "确定要发送这封邮件吗？"})
    return {"messages": [AIMessage(content=f"人类决定：{decision}")]}

graph = StateGraph(MessagesState)
graph.add_node("human_review", human_review)
graph.add_edge(START, "human_review")
graph.add_edge("human_review", END)
app = graph.compile(checkpointer=MemorySaver())
cfg = {"configurable": {"thread_id": "h-1"}}
```

## 二、第一次跑：图停在中断处

```python
app.invoke({"messages": [HumanMessage(content="发邮件给老板")]}, cfg)
# 图在这里暂停，human_review 还没返回
```

此时 `app.get_state(cfg).next` 会是 `('human_review',)`，表示正卡在这个节点。

## 三、人给答复：用 Command 恢复

```python
app.invoke(Command(resume="确认发送"), cfg)
# human_review 里的 interrupt 收到 "确认发送"，节点继续执行
```

`Command(resume=...)` 把人输入的值塞回 `interrupt` 的返回值，节点从这行往下跑完，图正常结束。

## 四、为什么比「在外面 if 判断」好

把「等待人」做成图里的一个节点，有几个实在好处：状态被 Checkpointer 完整保存，重启后还能 resume；暂停点清晰可追溯；多个中断点可以同时存在于不同分支。它把「人机交互」从脚本外的胶水代码，变成图的一等公民。

典型用法：敏感操作前 `interrupt` 要授权、生成结果后 `interrupt` 让人审核、工具调用前 `interrupt` 让人改参数。让人在最关键的地方点一下，比全自动驾驶稳得多。
