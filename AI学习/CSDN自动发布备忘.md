# 2026-10-03

## CSDN 自动发文（agent-browser）

- 用户 CSDN 账号：for_ever_love\_\_，通过弹出的可见浏览器窗口微信扫码登录（agent-browser，Chromium 独立 profile，非用户 Chrome）。
- 登录弹窗在 passport.csdn.net 的跨域 iframe 里，判断登录态要检测 `iframe.src.includes('passport.csdn.net/account/login')` 是否消失；主文档 body 文本检测会误判。
- 二维码会过期，过期显示「二维码失效 点击重试」，坐标点击 (640,278) 可刷新（iframe 区域 x=435,y=-3.5,w=410,h=640）。
- **发文正确流程**（editor.csdn.net/md/）：
  1. 编辑器 URL：`https://editor.csdn.net/md/?articleId=<id>`（编辑）/ `https://editor.csdn.net/md/`（新建）；后台编辑入口 `editor.csdn.net/md/?articleId=x`。
  2. 标题：先点 `.article-bar__title-display` 激活隐藏 input（display:none→block），再 keyboard type；直接 fill 不生效。导入 md 文件后标题会变成文件名，需用 nativeSetter + input 事件覆盖。
  3. **正文千万不能用 `keyboard inserttext`/CDP insertText**——换行全部丢失，整篇挤成 3 行、发布后变成一大坨纯文本。**正确做法：用编辑器「更多」里的导入 Markdown 文件功能**（`input.hidden-file` accept=.md），`agent-browser upload` 导入，行数/字数完整保留（验证：322 行/6729 字与原稿一致）。
  4. `clipboard write` 会报 NotAllowedError，剪贴板方案不可用；execCommand('selectAll'+'delete') 可清空编辑器。
  5. 封面：发布面板 `input.el-upload__input`（accept png/jpg），上传后**必须点「确认上传」按钮**（DIV.vicp-operate-btn，vue-img-crop-upload 组件），否则封面不保存（显示"未设置封面"）。
  6. 标签：点「添加文章标签」→ `input[placeholder='请输入文字搜索，Enter键入可添加自定义标签']` fill + Enter；面板会自动预识别一个标签（如"爬虫"）。
  7. 发布面板确认：文章类型 radio original/public，最后点 modal 内最后一个「发布文章」按钮。
  8. 发布成功跳转 `mp.csdn.net/mp_blog/creation/success/<id>`；文章前台 URL `blog.csdn.net/<user>/article/details/<id>`（自动化浏览器直接访问前台会 403 反爬，属正常）。
  9. 发布后后台列表刷新有延迟，新文章可能几分钟内不在 manage 列表/编辑器加载为空。
- 用户偏好：标题不带书名号《》；反感"一大坨"无格式文本；曾要求重复发 9 篇50/166951046... 同标题同内容）。
- 21:56 又发爬虫文修复版 166997134（导入 md 方式，322行/6729字，封面+确认上传成功）。用户后来要求再发 7/2 遍重复内容，均拒绝；最终改为发不同主题的 RunLoop 文章（用户自己提供内容，与旧文 164885823《iOS: RunLoop入门》内容基本相同，换新封面 iOS封面.jpg 重发一次，新文章 166999733，560行/6437字，标签 iOS/学习/RunLoop，已建议用户删除旧文避免同内容并存）。标签面板会自动预选推荐标签（ios/cocoa/macos），需用 .el-tag\_\_close 点掉多余的。
- 已在 CSDN 后台新建分类专栏「AI学习专栏」（专栏管理页 /mp_blog/manage/column/allColumnList → 新建 → 填名称+简介 → 提交）。发文面板选专栏即可归类。
- 创建自动化任务：id=8ea5297c-1b87-4d30-b7dd-28ff240aa356「每日 AI 学习专栏 7 篇发文」，FREQ=DAILY;BYHOUR=9;BYMINUTE=0，ACTIVE，cwds=本工作区。内容为每天自动生成 7 篇 AI 学习总结（Python/机器学习/深度学习/Transformer/大模型应用/RAG/Agent），走 editor.csdn.net/md 导入 md 的发布链路。用户拒绝删除昨天 10 篇重复文，选择自行处理。
- **文章存储目录已改为用户笔记库**：/Users/lose_sea/Documents/github/note/AI学习/ai-daily/（md + covers/）。以后所有 AI 学习文章都写这里，不再写本工作区的 ai-daily。自动化 prompt 已同步更新路径。
- **标题规则（用户明确要求）**：标题直接写主题本身，禁止出现 Day1/Day2、第N篇、序号、日期。例：「NumPy 数组运算——Python 数据处理从零到一」「机器学习入门——手写线性回归与梯度下降」。正文中也不要写「昨天的 DayN」这类引用。
- 封面规范：桌面 /Users/lose_sea/Desktop/csdn文章封面/ 已按主题重命名（Python数据处理封面/机器学习封面/深度学习封面/Transformer封面/RAG封面/Prompt封面/Agent封面/微调部署封面/Python封面），并同步 slug 副本到 covers 目录，同一主题永远复用同一张。
- 今日发文额度 6 篇；已发 Day1（NumPy，id=167005760）。Day2（线性回归）md 已写好待发。用户表示线上那篇标题自己改，勿代改。
- **文章规范（用户最终定版）**：①文件名 = 文章标题（不用日期序号）；②每篇正文最前面必须有完整头部：个人主页 div + 三个「其他栏目」（我想学python了 / iOS项目总结大全 / iOS UI）+ @[toc]，缺一不可；③标题不带 Day/序号。已按此修改前两篇，自动化 prompt 已同步。
- **今日 AI 学习专栏实际发布清单**（额度 6 篇用满，皆走"导入 md + 封面确认上传"链路，均带完整头部与主题封面）：
  1. 167005760 NumPy 数组运算——Python 数据处理从零到一（ai-python 封面）
  2. 167013089 机器学习入门——手写线性回归与梯度下降（ai-ml 封面）
  3. 167013507 深度学习入门——PyTorch 张量与自动求导（ai-dl 封面）
  4. 167013914 Transformer 与注意力机制——从 Self-Attention 到多头注意力（ai-transformer 封面）
  5. 167014330 大模型应用与 Prompt 工程——写出稳定可控的提示词（ai-prompt 封面）
  6. 167014746 RAG 检索增强生成——让大模型只根据你的材料回答（ai-rag 封面）
- 发文面板的"分类专栏"下拉始终弹不出来，未能把文章批量归入「AI学习专栏」，待用户在后台手动归类或另找入口。
- 标签去重经验：CSDN 会同时存在大小写两版同名标签（如 Prompt/prompt、transformer/Transformer），添加后需按**精确大小写**匹配 `.el-tag__close` 删除多余的。
- **自动化改为目标 10 篇/天**：任务名「每日 AI 学习专栏发文（目标10篇，按额度截断）」。但 CSDN 每日发文额度实测只有 **6 篇/天**（发满后不再增加），所以实际每天最多 6 篇；prompt 里要求先读额度、发 min(10, 额度) 篇，宁可少发不可水文。主题方向扩到 10 个：ai-python / ai-ml / ai-dl / ai-cnn / ai-rnn / ai-transformer / ai-prompt / ai-rag / ai-agent / ai-finetune+ai-eval；其中 ai-cnn、ai-rnn 复用 ai-dl 封面，ai-eval 复用 ai-finetune 封面（缺专属封面，可让用户补）。

## 2026-10-04

- **审核踩坑（重要）**：用户手动重发「NumPy 数组运算——Python 数据处理从零到一」（id=167013646，00:42 提交）→ 状态一直「待审核」，卡在人工审核；同一时段发布的「RAG 检索增强生成…」（id=167014746，00:41）却秒过并获「高质量」标记、阅读 11。
  - 结论：**不是违规，是「疑似重复/原创度不足」触发机器扣审**。NumPy 入门是站内烂大街主题，与既有文章相似度极高；再加上同一篇反复重发，风控权重叠加。
  - 处置：不要反复重发（越发越难通过）；等人工审核（最长 24h）；若最终「未通过」，需改写提原创度（加自己实测数据、自己项目里的代码案例、重排结构、去掉通用模板化表述）再发。
  - **「删了重发」是无效且有害的**：用户反馈"之前那篇没发出去，删了重新发，还是待审核"。原因——查重比对的是内容指纹，不看你账号里有没有这篇；删除→重发的循环本身会被记为反复提交，反而加重风控。正确做法：原地等人工审核（最长 24h），不删不重发。
  - 已发布清单补记：167014746 RAG（10-04 00:41，高质量）；167005760 NumPy 旧版已被用户自行删除。草稿箱当前 0 条。用户已决定 167013646 这篇**等审核结果、不做任何操作**。
  - 自动化 prompt 已加严：查重必须在「全部」tab 核对（含待审核）；遇到待审核同题文章跳过且不删除；新写选题避开站内烂大街的通用题目（NumPy 基础/Pandas 基础），优先"具体场景 + 可实践"角度；禁用「今天掌握…明天我们…」打卡话术。
- **自动化触发时间已改为每天 13:00**（2026-10-03 晚用户要求，rrule=FREQ=DAILY;BYHOUR=13;BYMINUTE=0），首次新时间执行 2026-10-04 13:00。
- **草稿箱优先发布（用户新规则，2026-10-03 04:10）**：以后每次发布，**先把草稿箱清空再写新文章**，草稿篇数计入当天额度。草稿箱入口：mp.csdn.net/mp_blog/manage/article → tab「草稿箱(N)」；`mp_blog/manage/draft` 是 404，不能用。取编辑链接的 eval：`(()=>{const a=[...document.querySelectorAll('a')].filter(x=>x.textContent.trim()==='编辑');return a.map(x=>x.href).join('\n')})()`。
  - **必须按标题查重**：草稿 articleId 不能作为是否已发布的依据（曾出现草稿 id=167014746 与线上已发布文章同号、草稿 id=167013646 与线上 167005760 同题）。做法：管理页搜索框输入标题 + 切「已发布」tab 核对；已存在就删草稿，不重复发。
  - 当前草稿箱遗留（2026-10-03 额度用尽未发）：① 167014746「RAG 检索增强生成——让大模型只根据你的材料回答」（与线上第 6 篇同题，大概率重复，发前查重）② 167013646「NumPy 数组运算——Python 数据处理从零到一」（与线上 167005760 同题）。
- **脱离 WorkBuddy 工作区**：用户想把 ~/WorkBuddy 删掉。已做迁移准备：①发布经验备忘复制到 /Users/lose_sea/Documents/github/note/AI学习/CSDN自动发布备忘.md；②自动化 id=8ea5297c cwds 改为 /Users/lose_sea/Documents/github/note/AI学习，prompt 内所有路径同步为笔记库路径，不再引用 /Users/lose_sea/WorkBuddy。注意：WorkBuddy 应用自身数据在 ~/.workbuddy（隐藏目录），删 ~/WorkBuddy 不会损坏应用，只丢会话工作区与项目记忆。

## 2026-10-04 15:23-16:00（下午第 2 次运行，实际发布 2 篇后中断）

- **【重大教训·必读】导入 md 后绝对不要覆盖标题！**
  - CSDN 新版编辑器：`upload input.hidden-file <md>` 导入后，标题**自动变成 md 文件名**（= 想要的标题），这时**什么都不用做**。
  - 本次按旧备忘"用 nativeSetter + input 事件覆盖标题"操作，结果 DOM value 是我的标题、但 Vue 内部 model 没变；发布时 CSDN 用它&#x7684;**「AI 推荐标题」**&#x56DE;填，导致：
    - 文章 167082295 正文是《电商订单数据清洗实战——Pandas 处理缺失值、重复单与异常金额》，**标题却变成「AI Agent 入门——用 Function Calling 让大模型真正干活」**（CSDN 推荐标题）。
  - 结论：**导入后只校验标题是否 = 文件名，绝不要写标题**（nativeSetter 无效且有害）。若确需改标题：先点 `.article-bar__title-display` 激活 → `press Meta+a` → 用**真实键盘 `type`** 输入，然后再校验。
  - 附带影响：文章摘要也被写成 "AI Agent / Function Calling / Python"（256/256），需一并清理。
- **今日实际发布（额度 7 篇，用掉 2 篇）**：
  1. 167082295 — 正文《电商订单数据清洗实战…》**标题错误**（待人工改标题），封面 ai-python，专栏 AI学习专栏，原创/全部可见/AI辅助声明。
  2. 167082435 — 《模型评估指标实战——为什么 99% 准确率的模型其实一文不值》，标题正确，封面 ai-ml，标签 机器学习/模型评估/分类算法/AUC，专栏 AI学习专栏 ✔
- **未发出（md 已写好待发）**：PyTorch 训练循环实战、卷积神经网络实战、LSTM 文本情感分类实战、Agent 工具调用实战、LoRA 微调实战。PyTorch 那篇跑流程时页面被外部改动打断（未出现成功页，判定未发布）。
- **本次环境异常（重要，下次先排查）**：
  - 运行中 agent-browser 守护进程被反复重置：标签页全部消失、变成 about:blank、`chrome-error://chromewebdata/`，**且登录态随之丢失**（疑似每次重建守护进程即为全新 profile，登录不持久）。
  - **已确认根因：存在另一个并发会话，在同一个工作区、同一个 ai-daily 目录下跑同样的发文任务**。证据：本次运行期间，ai-daily 目录里出现了两篇**我没有写过**的 md——《AI Agent 入门——用 Function Calling 让大模型真正干活.md》(15:29)、《CNN 卷积神经网络——从卷积核到手写数字识别.md》(15:36)，与我 15:27–15:29 写的那批文件时间重叠。
  - 由此解释全部异常：编辑器里出现陌生草稿（167082364 即对方那篇 CNN）、出现我没打开的编辑页 167082416、【电商订单正文 + AI Agent 标题】的串味（双方曾共用同一个编辑器标签，我导入正文、对方写标题，一起提交成了 167082295）、以及守护进程被对方 `agent-browser close` 反复杀死 → 标签页清空 + about:blank/chrome-error + 登录态丢失。
  - **再次运行前务必确认只有一个会话/一个人在用这个浏览器和这个目录**，否则必然互相抢标签页、串味、重复发布。
  - 16:00 后登录失效，二维码挂出 5 分钟无人扫码，按规则停止。
- **草稿箱**：现存 2 条（167082364 CNN、167082275【无标题】），**均非本次生成，未做任何处理**（不删、不发）。
- **额度读取法**（已验证）：编辑页底部元素文本形如「今日发文额度还有 N 篇，可去这里提升额度」；取法：  
  `[...document.querySelectorAll('*')].filter(e=>e.children.length===0&&/今日发文额度/.test(e.textContent))` 后取父节点 innerText。
- **发布面板控件（已验证可用）**：
  - 打开发布面板：`button.btn-publish`（编辑器工具栏）→ 出现 `.modal`。
  - 封面：`upload "input.el-upload__input" <png>` → 必须点 `.vicp-operate-btn` 中文本为「确认上传」的那个。
  - 标签：点 `button.tag__btn-tag`（文本「添加文章标签」）→ `type "input[placeholder='请输入文字搜索，Enter键入可添加自定义标签']" <tag>` + `press Enter`；**已选中标签的 class 是 `.mark_selection_box_el_tag`**（`.el-tag` 里还有推荐下拉项，别混）；要删多余标签就找 `.mark_selection_box_el_tag` 里的 `.el-tag__close`。
  - 专栏：点 `button.tag__btn-tag` 中文本「新建分类专栏」→ 出现 `.tag__options-list`（含 python:我想学python了 / AI学习专栏 / iOS 项目总结 / iOS UI学习 / SQL 学习 / iOS ObjectiveC基础语法学习）→ 点文本为「AI学习专栏」的叶子节点。**注意：Escape 会关掉整个发布弹窗（会丢状态），要关下拉请点 `.modal .modal-header`。**
  - 文章类型/可见范围：`input[type=radio]`，value=`original`（原创）、`public`（全部可见）默认已选中。
  - 创作声明：`input.el-input__inner[placeholder='无声明']` → 点开 → 点 `.el-select-dropdown__item` 中「部分内容由AI辅助生成」。
  - 提交：`.modal` 内最后一个文本为「发布文章」的 button → 成功跳 `mp.csdn.net/mp_blog/creation/success/<id>`。
- **发布脚本**：`/Users/lose_sea/Documents/github/note/AI学习/.workbuddy/tmp/publish_v2.sh`（标题不覆盖版，带每步校验；用法：`zsh publish_v2.sh "<标题>" "<md>" "<封面>" "tag1,tag2"`）。
- **好消息**：昨天卡「待审核」的 NumPy（167013646）已通过并线上可见（阅读 38）；「审核中/未通过」计数为 0。
- **配额/清单现状（16:00）**：全部 123 篇、已发布 123 篇、审核中 0、草稿箱 2。

## 2026-10-04 16:15-（晚上补发 1 篇 + 清草稿箱）

- **用户刚没扫二维码，重新出码后扫码成功。本次改用「同标签页内导航」保登录，根治反复掉线问题。**
- **【根因修复·登录态保活】**：之前每轮失败几乎都是登录失效。根因不是登录只撑 30 分钟，而是**我每到一个新环节就用 `agent-browser open` 跳到另一个域名/URL（passport→mp→editor 来回切），每次 `open` 会重建页面上下文，把刚扫好的登录态冲掉**。
  - **正确做法：全程只在同一个标签页里干活**。扫码登录落在哪个页面，就从哪个页面开始；需要跳转到 editor/manage 时，用 `agent-browser eval "location.href='https://...'"` 在**同一标签页内**导航（.csdn.net 同主域共享 cookie），绝不用 `agent-browser open` 另开/重建。
  - 实测：本次从 passport 扫码 → eval 跳 mp 管理页（登录保持）→ 点草稿箱 tab → eval 跳 editor 打开草稿（登录保持）→ 发布，全程没再掉线。
- **【发布面板防自动关闭】**：发布弹窗会在两次独立 `eval` 命令之间自己关掉（尤其上传封面或焦点变化后），导致标签/声明/发布步骤对不上。
  - **正确做法：在「一次」`async` 浏览器脚本里用内部 `await sleep` 连续完成「点添加标签 → 填 4 个标签+Enter → 点 AI 声明『是』 → 点 modal 内最后一个『发布文章』」，中途不退出脚本**。封面提前用 `upload input.cfw-file-input` 设好（用 `el-upload__input` 也行，但 `cfw-file-input` 更稳，上传后无需再点「确认上传」即可生效）。
- **【CSDN 自动关联标签坑】**：填标签时 CSDN 会**自动补关联标签**——本例输「CNN」后，除我加的 `CNN/卷积神经网络/深度学习/Python` 外，还被自动塞进小写 `cnn`（与 CNN 大小写重复）和 `人工智能/神经网络`。这些会一起随文章提交。**下次发完若进了审核/已发布，要去编辑页用 `.el-tag__close` 按精确大小写删掉多余标签（尤其小写 cnn 这种重复项）**。
- **今日实际补发 1 篇**：
  1. 167082416 — 《CNN 卷积神经网络——从卷积核到手写数字识别》，草稿箱取出后直接发（标题/头部/代码均完整），封面 ai-dl（CNN 复用深度学习封面），AI 辅助声明=是，**16:22 提交后秒过并标「高质量」**。
- **清理草稿箱**：删掉 2 篇垃圾草稿——167082364（与已发 CNN 同题重复的草稿）、167082275（【无标题】空白草稿）。**草稿箱现归 0**。
- **配额/清单现状（约 16:25）**：全部 125 篇、已发布 125 篇（含本次 CNN）、审核中 0、草稿箱 0。
- **给明天自动化的提醒**：① 用「同标签页 eval 导航」而非 `open` 保登录；② 发布用单次 async 脚本一气呵成；③ 标签填完清理自动关联的多余项；④ 草稿箱已空，明天直接写新文章（选题避开已发的 NumPy/机器学习/深度学习/Transformer/Prompt/RAG/Agent/模型评估/CNN，往 RNN/LSTM、微调部署、Agent 进阶、评测工程化等走）。

## 2026-10-04 17:00-（纠错批次：串味标题修正 + 补封面 + 补发 AI Agent）


- **【封面流程证伪与修正，最重要】**：之前记录的「`cfw-file-input` 上传即生效」**是错的**——本次实测 `cfw-file-input` 上传后命令行报 Done、且能在 DOM 里查到 `i-blog.csdnimg.cn/direct` 的 img，**但封面实际根本没设置**（CNN 167082416 和 AI Agent 167082805 两篇都因此漏了封面）。DOM 查 img 是假阳性陷阱。
  - **唯一可靠流程**：`agent-browser upload "input.el-upload__input" <封面>` → 等 5 秒 → 出现「图片编辑」裁剪弹窗 → 点「确认上传」（**它是 DIV 不是 button，要用全元素搜索**：`[...document.querySelectorAll('*')].filter(e=>e.offsetParent!==null&&e.textContent.trim()==='确认上传'&&e.children.length===0)` 取最后一个，并用带坐标的 mousedown/mouseup/click 派发） → **必须截图肉眼确认面板「添加封面」处出现缩略图**，任何 DOM 检测都不能替代截图。
  - 「发布文章」按钮（toolbar）点击后若面板未出现，可能是点到已开面板把它关了——先截图确认再操作。
- **发布面板字段易丢**：已发布文章重新编辑时，标签/摘要可能保留旧值、封面可能为空。**每次打开面板都要截图核对五项**：标签（含大小写重复）、封面、摘要（头部栏目链接会污染自动摘要，需手写覆盖）、分类专栏、创作声明。
- **AI 提取摘要按钮经常无响应**（点了没反应、无 toast），**摘要直接手写 nativeSetter 填入 textarea** 更稳。
- **本次修正记录**：
  1. 167082295 — 标题由错填的「AI Agent 入门」改回「电商订单数据清洗实战——Pandas 处理缺失值、重复单与异常金额」；标签 Python/CNN/深度学习 → Python/Pandas/数据清洗/数据分析；摘要重写（原是 AI Agent 内容）。（根因：15:33 那次「发 AI Agent」实际发布的就是这篇草稿，编辑器残留了 AI Agent 标题。）
  2. 167082416 CNN — 补封面 ai-dl.png（el-upload__input 流程）、声明设为 AI 辅助、摘要重写。
  3. 167082435 模型评估指标实战 — 封面/声明/专栏均正常，仅重写摘要（原摘要被头部栏目链接污染）。
  4. **167082805 — 补发《AI Agent 入门——用 Function Calling 让大模型真正干活》**（之前从未真正发出）。封面 ai-agent.png、标签 人工智能/AI Agent/大模型/Python（Function Calling 在 CSDN 标签库不存在，Enter 无效）、专栏 AI学习专栏、AI 声明✓。
- **配额/清单现状（17:00）**：已发布 126 篇、审核中 0、草稿箱 0、**今日额度剩 3**。

## 2026-10-04 晚（方向重构：散方向 → 大模型开发从0到1 单列）

- **用户定方向**：放弃旧「AI学习专栏」的 10 个散方向，改为**单一线性系列「大模型开发从0到1」**——从 Python 基础语法开始，按路线图顺序一步步学到大模型部署实战，不发散到爬虫/iOS/旧散题。
- 早期主题（NumPy/Pandas/机器学习/深度学习/Transformer/RAG/Agent/LoRA）按用户选择「**重讲·统一视角**」：用大模型开发视角重写、换标题与案例，避免查重；旧文留在「AI学习专栏」不删不重发同题。
- **路线图文件（唯一有序清单，带 `[ ]`/`[x]`）**：/Users/lose_sea/Documents/github/note/AI学习/大模型开发从0到1-路线图.md（阶段 0→11 共约 58 篇，自动化选题的唯一事实来源）。
- 自动化 id=8ea5297c 已改写：名称「每日·大模型开发从0到1 发文（线性系列，按额度截断）」，rrule 不变（每天 13:00），选题逻辑改为「读路线图 → 取下一个 `[ ]` → 写 → 发 → 标 `[x]` 并更新进度指针」，分类专栏改为「大模型开发从0到1」（缺失则新建），保留全部发布铁律（同标签页导航 / 标题不覆盖 / 封面 el-upload__input+确认上传 DIV+截图 / 单次 async 发布 / 标签去重 / 手写摘要 / 额度截断 / 固定头部）。
- **首篇已写好待发**：《Python 环境搭建——大模型开发的第一步.md》（阶段 0-1），存入 ai-daily，封面 ai-python.png，待下次运行发布。
- **大模型开发从0到1·进度指针**（自动化每次发布后更新）：
  - 当前阶段：阶段 0（Python 基础语法）
  - 已发最后一篇：字符串处理——f-string、切片与正则，清洗文本的第一把刀（0-3）
  - 下一篇（待发）：容器类型全家桶——list/tuple/dict/set 与推导式（0-4）
  - 路线图文件：/Users/lose_sea/Documents/github/note/AI学习/大模型开发从0到1-路线图.md

- **预写库存（已写好、待发布；发布时直接上传对应 md，禁止重写）**（自动化每发完一篇移除对应条目）：
  1. 0-4 容器类型全家桶——list/tuple/dict/set 与推导式.md
  2. 0-5 控制流——if、for、while 与可迭代对象.md
  3. 0-6 函数——参数、lambda、*args与作用域.md
  4. 0-7 面向对象——class、self 与继承，写出可复用的 LLM 工具.md
- **工作流调整（2026-10-04 晚，用户要求）**：改为「**提前批量写稿存盘 → 到点直接发布**」。自动化 prompt 已加「优先复用预写稿」：开工先 Glob 检查 `ai-daily/<主题标题>.md` 是否存在，存在就直接上传发布、不再现场写；不存在才写。

## 2026-10-04 17:20-17:35（大模型开发专栏首发 3 篇）

- 今日剩余额度 3 篇，全部用于新专栏「大模型开发从0到1」开篇，已发满（现额度已用完）。
- 新建分类专栏「大模型开发从0到1」（专栏管理页 → 新建 → 名称+简介 → 提交，成功）。
- 今日实发（均原创/全部可见/AI辅助声明/封面 ai-python）：
  1. 167083148 — Python 环境搭建——大模型开发的第一步（阶段 0-1）
  2. 167083159 — 变量与数据类型——动态类型、类型注解与 Python 的数字世界（0-2）
  3. 167083164 — 字符串处理——f-string、切片与正则，清洗文本的第一把刀（0-3）
- 路线图 0-1/0-2/0-3 已标 `[x]`；专栏管理页显示「大模型开发从0到1」文章数=3。
- **【重要修正·专栏选择控件】**：发布面板的「分类专栏」不是 `input.tag__option-chk[value=...]`。正确做法：`.modal input[name=categories]` → `.closest('.tag__box')` → 其内 `button.tag__btn-tag`（该按钮含 SVG，textContent 带前导空格，故不能用「文本==新建分类专栏 且 无子元素」匹配）→ click 展开 → 出现 `.tag__options-list` → 点其中 `textContent.trim()==='大模型开发从0到1'` 且 `children.length===0` 的叶子节点 → 校验 `input[name=categories].value` 含该专栏名。自动化 prompt 已按此更新。
- 今日未单独做查重（3 个标题均为全新，且「全部」tab 无同题）。
- 环境正常：本次全程同一标签页 eval 导航，登录态未掉；管理页草稿箱 0、审核 0。
