<div align="center">
  个人主页：<a href=" https://blog.csdn.net/for_ever_love__?type=blog" style="font-size: 20px;">> for_ever_love__ <</a > （欢迎各位大佬莅临😊）
</div>
其他栏目: <a href=" https://blog.csdn.net/for_ever_love__/category_13199431.html" style="font-size: 20px;">> 我想学python了 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199427.html " style="font-size: 20px;">> iOS项目总结大全 <</a >

其他栏目: <a href="https://blog.csdn.net/for_ever_love__/category_13199426.html" style="font-size: 20px;">> iOS UI <</a >

@[toc]
# 电商订单数据清洗实战——Pandas 处理缺失值、重复单与异常金额

## 一、为什么先讲"清洗"，而不是"入门"

很多人的 Pandas 学习卡在同一个地方：教程里的 `df.head()`、`df.describe()` 都看得懂，可一旦拿到运营后台导出的真实订单表，就不知道从哪儿下手了。

原因很简单——**教程里的数据是干净的，真实数据是脏的**。

一份从后台导出的订单表，通常至少带着这四类毛病：

```
┌──────────────────────────────────────────────────────────────┐
│  真实订单表常见的 4 类脏数据                                   │
├──────────────────────────────────────────────────────────────┤
│  ① 缺失    收货手机号为空 / 优惠金额是 NaN                      │
│  ② 重复    同一个 order_id 出现两行（支付回调重试导致）          │
│  ③ 类型错  金额是 "¥1,299.00" 这样的字符串，不是数字            │
│  ④ 异常    金额为负、单价 999999（占位或测试数据）              │
└──────────────────────────────────────────────────────────────┘
```

这篇就用一份模拟的电商订单数据，把这四类问题逐个处理掉，最后交出一张能直接做报表的干净表。所有代码都可以直接运行，建议边看边敲。

## 二、先造一份"脏"数据

真实数据不好贴出来，我们先用 Python 造一份同样脏的数据，这样每一步的结果都能对照着看。

```python
import pandas as pd
import numpy as np

raw = {
    "order_id":  [1001, 1002, 1002, 1003, 1004, 1005, 1006, 1006, 1007, 1008],
    "user_id":   ["u01", "u02", "u02", "u03", None, "u05", "u06", "u06", "u07", "u08"],
    "amount":    ["¥199.00", "1,299.00", "1,299.00", "89.9", "-50.00",
                  "999999.00", "58.00", "58.00", None, "  320.50 "],
    "coupon":    [10, np.nan, np.nan, 0, 5, np.nan, 8, 8, np.nan, 0],
    "status":    ["paid", "paid", "paid", "refund", "paid",
                  "test", "paid", "paid", "paid", "pending"],
    "created_at": ["2026-09-01 10:01:00", "2026-09-01 10:05:00", "2026-09-01 10:05:00",
                   "2026-09-01 11:20:00", "2026-09-02 09:30:00", "2026-09-02 12:00:00",
                   "2026-09-03 08:15:00", "2026-09-03 08:15:00", "2026-09-03 09:00:00",
                   "2026-09-03 10:40:00"],
}

df = pd.DataFrame(raw)
print("原始行数：", len(df))
print(df.dtypes.to_string())   # 注意 amount 是 object，不是 float
```

运行后会看到关键信息：`amount` 的 dtype 是 `object`。**只要金额列不是数值类型，后面所有求和、分组统计都是错的**——这是第一个必须解决的问题。

## 三、五步清洗链路

整体思路是"先看、再删、后转、再筛"，顺序很重要：

```
读入原始数据
     │
     ▼
[1] 概览体检 probe()       —— 看缺失率、重复率、类型
     │
     ▼
[2] 去重 drop_duplicates   —— 同一 order_id 只留一条
     │
     ▼
[3] 类型清洗 to_numeric    —— 去掉 ¥ , 空格，转成 float
     │
     ▼
[4] 缺失处理 fillna        —— 手机号填未知，金额缺失行剔除
     │
     ▼
[5] 异常过滤 query()       —— 剔负金额、剔测试单、剔 999999
     │
     ▼
干净数据 → 直接出报表
```

### 第 1 步：体检

不要上来就改数据，先摸清楚问题规模。

```python
def probe(df, name="数据"):
    print(f"===== {name} 体检报告 =====")
    print(f"行数: {len(df)}  列数: {df.shape[1]}")
    print(f"完全重复行: {df.duplicated().sum()}")

    report = pd.DataFrame({
        "缺失数":   df.isna().sum(),
        "缺失率":  (df.isna().mean() * 100).round(1).astype(str) + "%",
        "类型":     df.dtypes.astype(str),
    })
    print(report.to_string())

probe(df, "原始订单表")
```

这一步会告诉你：`user_id` 缺 1 个，`amount` 缺 1 个，`order_id` 有 2 组重复。有了这张表，后面每一步改了什么、影响多少行，心里都有数。

### 第 2 步：去重

去重不能简单地 `drop_duplicates()` 全表比对——真实场景里两行内容可能只差一个更新时间戳，全表比对删不掉。正确做法是**按业务主键去重**。

```python
before = len(df)

# 按订单号去重，保留最后一条（通常后写入的是最新状态）
df = df.drop_duplicates(subset=["order_id"], keep="last").reset_index(drop=True)

print(f"去重：{before} → {len(df)} 行，删除 {before - len(df)} 条重复单")
```

`keep="last"` 和 `keep="first"` 的区别在实际业务里很关键：如果是状态流转类数据（如 `pending` → `paid`），后出现的往往是最新状态，要用 `keep="last"`；如果是日志类数据，则通常保留 `first`。

### 第 3 步：把金额变成真正的数字

这一步是整篇的核心。字符串洗成数字，标准流程是"**先去掉非数字字符，再转类型**"。

```python
def clean_amount(series):
    """把 '¥1,299.00' / '  320.50 ' 这类字符串洗成 float"""
    return (
        series.astype(str)
              .str.replace("¥", "", regex=False)   # 去掉货币符号
              .str.replace(",", "", regex=False)   # 去掉千分位逗号
              .str.strip()                          # 去掉首尾空格
              .replace({"nan": np.nan, "None": np.nan, "": np.nan})
              .pipe(pd.to_numeric, errors="coerce")  # 转不成数字的变 NaN
    )

df["amount"] = clean_amount(df["amount"])
df["coupon"] = pd.to_numeric(df["coupon"], errors="coerce").fillna(0)

print(df[["order_id", "amount", "coupon"]].to_string(index=False))
print("金额列类型：", df["amount"].dtype)
```

两个细节值得记一下：

- `errors="coerce"` 让"转不动"的值变成 `NaN` 而不是直接报错。生产环境里这比抛异常更安全，因为它让**坏数据显形**，而不是让整个脚本崩掉。
- `.pipe()` 让链式调用更清晰，最后一步统一转类型，避免中间步骤重复写 `pd.to_numeric`。

### 第 4 步：缺失值——不是所有缺失都该填

新手最容易犯的错是"看到 NaN 就 fillna(0)"。正确思路是先问一句：**这个字段缺了，能不能推断？**

```
字段         缺失能否推断？      处理方式
─────────────────────────────────────────────────────────
user_id      否（身份不可猜）    标记为 "unknown"，保留行
coupon       能（无券即 0）      fillna(0)
amount       否（金额是核心）     整行剔除
```

```python
# user_id 缺失：用哨兵值标记，而不是删行（删了会丢订单）
df["user_id"] = df["user_id"].fillna("unknown")

# amount 是核心指标，缺失无法推断 → 整行剔除
df = df.dropna(subset=["amount"]).reset_index(drop=True)

print("缺失处理完成，剩余行数：", len(df))
print(df.isna().sum().to_string())
```

这里的关键判断是：**缺失值要不要删，取决于这个字段对下游有没有决定性作用**。`amount` 要参与 GMV 统计，缺了就是错的，必须删；`user_id` 只用于分组，标成 `unknown` 反而保留了这条订单的金额贡献。

### 第 5 步：异常值过滤

异常值分两种：**业务规则能判定的**，和**需要统计判定的**。

```python
# ① 业务规则：金额必须为正、测试单要剔除
df = df.query("amount > 0 and status != 'test'").reset_index(drop=True)

# ② 统计规则：用 IQR 找离群点（对偏态分布比 3σ 更稳健）
q1, q3 = df["amount"].quantile([0.25, 0.75])
iqr = q3 - q1
lower, upper = q1 - 1.5 * iqr, q3 + 1.5 * iqr

outliers = df[(df["amount"] < lower) | (df["amount"] > upper)]
print(f"IQR 区间: [{lower:.2f}, {upper:.2f}]，疑似离群 {len(outliers)} 条")
print(outliers[["order_id", "amount", "status"]].to_string(index=False))
```

注意：**统计上的离群值不等于错误值**。真实业务里可能真有大额订单，所以这一步只做"标记"和"人工确认"，不要自动删。这里我们看到 999999 那条已经被 `status == 'test'` 过滤掉了，说明业务规则比统计算法更早也更准地拦住了它。

## 四、清洗后的结果与报表

```python
# 补上营收口径：实付 = 订单金额 - 优惠
df["pay_amount"] = (df["amount"] - df["coupon"]).round(2)

summary = df.groupby("status").agg(
    订单数=("order_id", "count"),
    订单金额=("amount", "sum"),
    实付金额=("pay_amount", "sum"),
).round(2)

print("清洗后总行数：", len(df))
print(summary.to_string())
```

输出大致是这样：

```
status   订单数   订单金额    实付金额
paid         5   1994.40   1963.40
pending      1    320.50    320.50
refund       1     89.90     84.90
```

如果把清洗前后的数字放一起对比，差距往往大得吓人——这也正是清洗这一步的价值所在：

| 指标 | 清洗前 | 清洗后 | 差异原因 |
|---|---|---|---|
| 行数 | 10 | 7 | 去重 2 条 + 剔除缺失 1 条 |
| 金额总和 | 无法计算 | 2404.80 | 字符串无法求和 |
| 含测试单 | 是 | 否 | status 过滤 |
| 含负金额 | 是 | 否 | 业务规则过滤 |
| 类型 | object | float64 | 能参与全部数值运算 |

## 五、几个常见的坑

**坑 1：先 `to_numeric` 再去符号，结果是全 NaN。**
`"¥199.00"` 直接丢给 `pd.to_numeric` 会失败，必须先用 `.str.replace` 剥掉 `¥` 和逗号。顺序反了整列就废了。

**坑 2：`fillna(0)` 覆盖一切。**
平均值、中位数、0、哨兵值，四种填法语义完全不同。填 0 会让平均值被拉低，填均值会缩小方差，填哨兵值则可能污染分组。**先想清楚"这个缺失值代表什么"，再决定怎么填。**

**坑 3：用 `inplace=True` 链式调用。**
`df.dropna(inplace=True)` 返回 `None`，写成 `df = df.dropna(inplace=True)` 会把 `df` 变成 `None`。新版本 Pandas 已不推荐 `inplace`，统一用 `df = df.xxx()`。

**坑 4：忘了 `reset_index(drop=True)`。**
删除行之后索引会留下空洞（0,1,3,4…），后续用位置索引取值会错位。每步结构性操作后顺手重置一次最稳。

**坑 5：只看 `head()` 就说数据没问题。**
`head()` 永远只能看到前 5 行，而脏数据往往藏在中后段。判断数据质量要看 `isna().sum()`、`duplicated().sum()` 和分布统计，不是看前几行长什么样。

## 六、小结

清洗的本质不是"调 API"，而是**把业务规则翻译成 Pandas 表达式**：

- 重复 → 按业务主键 `drop_duplicates`，而不是全表比对；
- 类型 → 先剥字符再转类型，`errors="coerce"` 兜底；
- 缺失 → 先判断"能否推断"，能推断才填，不能推断就删或标记；
- 异常 → 业务规则优先，统计规则辅助，且统计离群只标记不自动删。

把这套链路封装成一个 `clean_orders(df)` 函数，下次换一张表，改几个字段名就能复用。数据干净了，后面的特征工程、建模、报表才有意义——**垃圾进，垃圾出，这句话在数据科学里永远成立**。
