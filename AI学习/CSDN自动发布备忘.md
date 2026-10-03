# 2026-10-03

## CSDN 自动发文（agent-browser）
- 用户 CSDN 账号：for_ever_love__，通过弹出的可见浏览器窗口微信扫码登录（agent-browser，Chromium 独立 profile，非用户 Chrome）。
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
- 用户偏好：标题不带书名号《》；反感"一大坨"无格式文本；曾要求重复发 9 篇（被劝阻，判定灌水风险高，只发 1 篇）。用户之前确实手动重复发过同一篇文章多次（166951054/166951050/166951046... 同标题同内容）。
- 21:56 又发爬虫文修复版 166997134（导入 md 方式，322行/6729字，封面+确认上传成功）。用户后来要求再发 7/2 遍重复内容，均拒绝；最终改为发不同主题的 RunLoop 文章（用户自己提供内容，与旧文 164885823《iOS: RunLoop入门》内容基本相同，换新封面 iOS封面.jpg 重发一次，新文章 166999733，560行/6437字，标签 iOS/学习/RunLoop，已建议用户删除旧文避免同内容并存）。标签面板会自动预选推荐标签（ios/cocoa/macos），需用 .el-tag__close 点掉多余的。
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
- **草稿箱优先发布（用户新规则，2026-10-03 04:10）**：以后每次发布，**先把草稿箱清空再写新文章**，草稿篇数计入当天额度。草稿箱入口：mp.csdn.net/mp_blog/manage/article → tab「草稿箱(N)」；`mp_blog/manage/draft` 是 404，不能用。取编辑链接的 eval：`(()=>{const a=[...document.querySelectorAll('a')].filter(x=>x.textContent.trim()==='编辑');return a.map(x=>x.href).join('\n')})()`。
  - **必须按标题查重**：草稿 articleId 不能作为是否已发布的依据（曾出现草稿 id=167014746 与线上已发布文章同号、草稿 id=167013646 与线上 167005760 同题）。做法：管理页搜索框输入标题 + 切「已发布」tab 核对；已存在就删草稿，不重复发。
  - 当前草稿箱遗留（2026-10-03 额度用尽未发）：① 167014746「RAG 检索增强生成——让大模型只根据你的材料回答」（与线上第 6 篇同题，大概率重复，发前查重）② 167013646「NumPy 数组运算——Python 数据处理从零到一」（与线上 167005760 同题）。
- **脱离 WorkBuddy 工作区**：用户想把 ~/WorkBuddy 删掉。已做迁移准备：①发布经验备忘复制到 /Users/lose_sea/Documents/github/note/AI学习/CSDN自动发布备忘.md；②自动化 id=8ea5297c cwds 改为 /Users/lose_sea/Documents/github/note/AI学习，prompt 内所有路径同步为笔记库路径，不再引用 /Users/lose_sea/WorkBuddy。注意：WorkBuddy 应用自身数据在 ~/.workbuddy（隐藏目录），删 ~/WorkBuddy 不会损坏应用，只丢会话工作区与项目记忆。
