# MySQL TIMESTAMP 的 2038 问题：四字节时间到底还能用多久

`CREATE TABLE t_order (created_at TIMESTAMP)` ——这个写法遍布无数历史系统，也埋着一个确定会爆炸的雷：2038 年 1 月 19 日，TIMESTAMP 将达到存储上限。更麻烦的是它还有个平时不显眼、迁移时才炸毛的特性：**时区依赖**。这篇文章把 TIMESTAMP 与 DATETIME 的差异、2038 的来龙去脉、时区怎么影响你的数据、以及什么场景该迁到 DATETIME，一次讲清。

## 一、先看一次现场复现

```sql
CREATE TABLE t_demo (t1 TIMESTAMP, t2 DATETIME);
INSERT INTO t_demo VALUES ('2038-01-19 11:14:07', '2038-01-19 11:14:07');
-- 再来一秒
INSERT INTO t_demo VALUES ('2038-01-19 11:14:08', '2038-01-19 11:14:08');
-- ERROR 1292 (22007): Incorrect datetime value: '2038-01-19 11:14:08' for column 't1'
```

DATETIME 存得下，TIMESTAMP 直接报错——因为 TIMESTAMP 只有 4 字节，能表示的范围是：

| 类型 | 存储 | 范围 |
|---|---|---|
| `TIMESTAMP` | 4 字节 | `1970-01-01 00:00:01 UTC` ~ `2038-01-19 03:14:07 UTC` |
| `DATETIME` | 8 字节（5.6 前 5 字节支持小数秒前到 5.6.4） | `1000-01-01 00:00:00` ~ `9999-12-31 23:59:59` |

2038-01-19 03:14:07 UTC 就是 2^31-1 秒——这就是"2038 问题"的全部数学：Unix 时间戳用有符号 32 位整数存秒数，到顶就溢出。Linux 内核（64 位）、现代语言（64 位 time_t）早就解决了这个问题，但**MySQL 表里的 TIMESTAMP 列没有**——这是数据库层的遗留约束。

## 二、TIMESTAMP 与 DATETIME 的五个差异

只知道范围不够，实际选型要看全套：

| 维度 | TIMESTAMP | DATETIME |
|---|---|---|
| 存储空间 | 4 字节 | 8 字节 |
| 范围 | 1970~2038 | 1000~9999 |
| 时区 | **存 UTC，按会话时区显示** | 存字面值，不涉及时区 |
| 默认值/自动更新 | 支持 `DEFAULT CURRENT_TIMESTAMP` / `ON UPDATE CURRENT_TIMESTAMP` | **MySQL 5.6.5+ 也支持**（很多人还以为只有 TIMESTAMP 行） |
| 插入 NULL | 自动设为当前时间（旧行为） | 就是 NULL |

逐条讲透：

### 2.1 时区：最大的行为差异

TIMESTAMP 存的是 UTC 秒数，写入时按会话 time_zone 转成 UTC 存储，读取时再转回会话时区显示：

```sql
SET time_zone = '+00:00';
INSERT INTO t_demo (t1) VALUES ('2038-01-19 03:14:07');  -- 按 UTC 理解

SET time_zone = '+08:00';
SELECT t1 FROM t_demo;   -- 显示 2038-01-19 11:14:08（已转换，同一条数据）
```

DATETIME 则是"所见即所存"：存 `'2038-01-19 11:14:07'`，任何时区下读出来都是这个字符串，不做任何转换。

**这个差异的工程含义**：如果你的服务跨时区部署（比如新加坡节点写、北京节点读），TIMESTAMP 天然适合——它存的是绝对时间点，各节点按自己时区看到正确的本地时间；DATETIME 存的是字面量，各节点看到的都是写入方的本地时间，需要应用层自己约定。

### 2.2 自动时间戳：5.6 之后 DATETIME 也行了

经典教程说"只有 TIMESTAMP 能做 `DEFAULT CURRENT_TIMESTAMP`"——**从 MySQL 5.6.5 起，DATETIME 也支持**：

```sql
CREATE TABLE t_order (
  id BIGINT PRIMARY KEY,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
```

这意味着"想用自动时间戳"不再是选 TIMESTAMP 的理由。而且 DATETIME 的自动时间戳同样支持小数秒（`CURRENT_TIMESTAMP(6)`）和多列。

### 2.3 隐含的坑：NOT NULL 与零值

TIMESTAMP 列在 5.6 之前默认 `NOT NULL DEFAULT CURRENT_TIMESTAMP`，且显式插入 NULL 会被静默替换为当前时间——这个魔法行为坑过很多 ORM。还有 `NO_ZERO_DATE` 模式：`sql_mode` 严格后，`'0000-00-00 00:00:00'` 这种零值会被拒，历史库里残留的零值数据迁移时会集中报错。

## 三、2038 之后会发生什么

三种结局，取决于你的系统：

**结局一：写入直接失败。** 像开头演示的那样，超过 `2038-01-19 03:14:07 UTC` 的值插入报 `Incorrect datetime value`。对从没清理过日志表的系统，这个错误会在 2038 年某天集中爆发——日志、订单、审计表全部写不进去。

**结局二：读出来是 NULL 或错值。** 有些客户端/驱动在读取越界 TIMESTAMP 时返回 NULL 或最小时间，界面显示 1970。

**结局三：时间相关计算整体崩坏。** 排序、区间统计、归档逻辑一旦跨过 2038 边界，结果不可预期。

**现在离 2038 还有十年多，但这恰恰是现在就要处理的原因**：这类数据通常保存在长生命周期的系统里——征信、审计、日志、订单，存十年的表比比皆是。今天建的表，2038 年可能还在跑。**2038 年前不改，迁移窗口只会越来越贵**（数据量只增不减）。

## 四、时区三个变量：为什么你显示的时间"不对"

TIMESTAMP 的时区行为由全局和会话两层控制：

```sql
SHOW VARIABLES LIKE '%time_zone%';
-- time_zone: 全局默认时区（常为 SYSTEM，即操作系统时区）
-- system_time_zone: 跟随 OS（容器里尤其容易踩坑）
```

三个经典事故场景：

**场景 1：容器时区没设。** Docker 里 MySQL 的 `system_time_zone` 默认是 UTC，而开发机是 `+08:00`。同一个 TIMESTAMP 字段，开发环境读出来和容器里差 8 小时。解法：启动容器加 `-e TZ=Asia/Shanghai`，或 MySQL 配置 `default-time-zone='+08:00'`。

**场景 2：连接没设时区。** 驱动连接串不带 `serverTimezone=Asia/Shanghai`（JDBC 老版本），服务端时区对但连接协商用了别的。解法：连接串显式声明，或服务端 `init_connect='SET time_zone="+08:00"'`。

**场景 3：跨时区同步/迁移。** 从 A 机（UTC）dump 出的 `TIMESTAMP` 数据，用 mysqldump 导入 B 机（+08:00）时，SQL 文本里的字面时间是按 A 的时区还是 UTC？——mysqldump 导出 TIMESTAMP 时输出的是**会话时区下的字面值**，如果导入端会话时区不同，静默错 8 小时。**迁移涉及 TIMESTAMP 时，务必先 `SET time_zone='+00:00'` 再导出导入，两端一致。**

## 五、DATETIME(6) 与小数秒

现代 MySQL 时间字段的最佳实践之一：**用 `DATETIME(6)` 而不是 `DATETIME`**。

```sql
CREATE TABLE t_order (
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
);
```

`(6)` 表示微秒精度。理由：

- 同一秒内的多条记录，`DATETIME` 秒级精度无法排序先后，用 `id` 兜换不如直接微秒；
- 分布式系统里"同一时刻创建"的记录，微秒精度让 `created_at` 接近唯一有序；
- TIMESTAMP 同样支持 `(6)`：`TIMESTAMP(6)`，时区行为不变。

代价是 8 字节 ± 1~3 字节（小数部分另存），完全值得。

## 六、还有两个选项：UNIX 时间戳列和 DATE

完整的时间类型地图：

| 类型 | 存什么 | 适合 |
|---|---|---|
| `TIMESTAMP` | UTC 秒 | 需要时区自动转换的**短周期**字段，2038 年前够用 |
| `DATETIME` / `DATETIME(6)` | 字面本地时间 | 绝大多数业务字段，新库默认选它 |
| `DATE` | 年月日 | 生日、统计日期 |
| `TIME` | 时分秒 | 时长、营业时间 |
| `YEAR` | 年份 | 归档年份 |
| `BIGINT` 存 Unix 秒/毫秒 | 绝对数值 | 高性能计算、与外部系统对齐 |

**BIGINT 存时间戳是另一个流派**：应用层完全控制、无时区歧义、索引和范围查询效率最高，代价是失去 MySQL 的日期函数（要靠 `FROM_UNIXTIME()` 转）。微秒级用 `BIGINT` 存毫秒/微秒的也不少。适合写多读少、计算密集的系统，不适合要人看的报表字段。

## 七、迁移决策：TIMESTAMP → DATETIME 什么时候做

**建议迁移的信号：**

1. 字段存的是"未来日期"：预约、到期、合同截止——这些本来就超过 2038 的设计寿命；
2. 系统内不涉及时区转换，或应用层自己管时区；
3. 历史库 5.5/5.6 时代遗产，列上还有零值日期；
4. 跨时区同步场景下，DATETIME + 应用层约定反而比隐式转换更可控。

**可以保留 TIMESTAMP 的信号：**

1. 短周期数据（会话、日志），2038 年前系统已下线；
2. 明确需要 UTC 绝对时间点语义，且团队接受隐式时区行为；
3. 历史包袱太重，迁移风险大于收益（那就做好 2038 前迁移的排期）。

**迁移操作：**

```sql
-- 先全量改列类型（会锁表，大表走 gh-ost）
ALTER TABLE t_order MODIFY created_at DATETIME(6) NOT NULL;

-- 注意：TIMESTAMP → DATETIME 的语义转换
-- TIMESTAMP 存 UTC，DATETIME 存字面值。
-- 直接用 ALTER MODIFY 会把 UTC 秒数"按会话时区显示后写入"，
-- 如果会话时区 = 写入时区，数据在原地看着不变，但语义已切换正确。
```

**关键认知**：`ALTER TABLE MODIFY` 改类型时，MySQL 会做"读出来（按当前会话时区）→ 按新类型存"的转换。如果当前会话时区就是业务时区，转换后 DATETIME 里的字面值 = 原来 TIMESTAMP 显示的本地时间——这正是想要的。但如果你在 UTC 会话下执行这个 ALTER，DATETIME 里存的就是 UTC 字面值，之后按本地时间读就少了 8 小时。**执行迁移前，先 `SET time_zone='+08:00'`（你的业务时区），这是迁移 checklist 的第一条。**

**迁移 checklist：**

1. 确认业务时区，迁移会话 `SET time_zone` 为业务时区；
2. 全备 + 记录 binlog 位点；
3. 从库先执行，校验抽样数据（挑几条比对转换前后显示值）；
4. 主库窗口期 gh-ost 在线改；
5. 应用回归：写入/读取/日期计算/报表；
6. 慢查询观察（DATETIME 索引大小比 TIMESTAMP 大一倍，索引页翻倍，极端场景注意 Buffer Pool）。

## 八、时区配置落地清单

无论迁移与否，时区配置都应规范化：

- [ ] 服务器 OS 时区设为业务时区（`timedatectl set-timezone Asia/Shanghai`）；
- [ ] 容器部署显式 `TZ` 环境变量；
- [ ] MySQL `default-time-zone = '+08:00'` 或 `SYSTEM`（二选一，全集群统一）；
- [ ] 驱动连接串带 `serverTimezone`；
- [ ] 跨机迁移/同步时，导出导入两端会话时区一致；
- [ ] 审计字段统一 `DATETIME(6)` 或 `TIMESTAMP(6)`，全库一个规范；
- [ ] 新表默认 `DATETIME(6)`，禁止再建裸 `TIMESTAMP`（除非明确短周期）。

## 九、小结

TIMESTAMP 的三个核心结论：

- **4 字节 = 2038 年 1 月 19 日**，越界直接写入失败，长生命周期系统必须迁 `DATETIME(6)`；
- **TIMESTAMP 存 UTC、按会话时区显示**，DATETIME 存字面值——时区语义是选型第一决策点，容器和驱动是时区事故高发区；
- **5.6.5 之后 DATETIME 也支持自动时间戳**，"要 CURRENT_TIMESTAMP 只能选 TIMESTAMP"已是过时认知，新表一律 `DATETIME(6) DEFAULT CURRENT_TIMESTAMP(6)`。

下一篇讲 ENUM 的坑：这个"看起来很方便"的类型，怎么在排序、索引和字符串函数上给你惊喜。
