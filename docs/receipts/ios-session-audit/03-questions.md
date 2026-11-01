# 03 — 提问（ask_user_question）iOS Session 对齐审计

> 审计对象：官方 DSH 0.2.1-rc.2 @ `7be5505b0b` 的「提问」全部形态 vs phone-dsh iOS 原生会话页。
> 视觉基准：手机宽度 **402 pt**（官方截图 402×874；代码里 CSS px ≈ pt）。
> 只读审计：未改任何源码、未动 git、未跑测试/构建。所有结论均为静态源码推断 + 既有截图/度量（标注「截图观察」）。

---

## 0. 结论摘要

- **官方不是「一张待回答卡」**，而是一条完整的双域链路：**待回答** = 接管 composer 的 `QuestionComposer`（带分页、推荐项、跳过、丢弃整组、收起、倒计时、只读 review 面板、与 plan review 共用同一座位并按 `intent.kind === 'plan-review'` 分流）；**已回答** = 工具行 `AskQuestionRow`（`{answered}/{total} 已回答` + 展开的问答卡 + `查看回答` 只读面板）+ 迟到回复的 `question-reply` 右对齐气泡（"回答先前等待中的问题"）。
- iOS 侧：**只有 `ChatPage.swift:2139-2244` 一个 `QuestionCard`**，渲染在**页面顶部**（`ChatPage.swift:181-194`，`cardsRegion` 在页头与 transcript 之间），**不是** composer 接管；同时 composer 被整体禁用（`ChatPage.swift:1605`）。数据层只保留了 `id / question / options[].label / multiSelect`（`DSHRemoteHarness.swift:410-422`），**header / detail / description / intent / wait.callId 全部丢失**，因此官方 6 个 surface（eyebrow / detail / 选项描述 / 推荐 / plan-review / review 面板）在 iOS 上**不可能出现**。
- **P0 共 6 条**：①已回答问答在 transcript 里完全缺失（无 `1/1 已回答`、无问答卡、无 `查看回答` 面板）②迟到回复被画成「上下文注入 · user-question-reply」并直接显示原始 JSON ③多题无分页/进度/自动前进 ④无跳过（`跳过`）与丢弃整组（`放弃整组问题`）⑤数据层丢字段（header/detail/description/intent/callId）⑥plan-review 路由缺失。
- **P1 共 9 条**：composer 接管 IA 差异、视觉体系整体不同、推荐项、提交校验/冻结/重试、pending 优先级、工具行文案/图标/面板按钮、草稿持久化、倒计时等待态、单选互斥与多选语义。
- 正面结论（避免误判）：iOS 的**应答 wire 格式是对的**——`{answers:[{id,selected,custom}]}` 由 `DSHRemoteHarness.questionAnswer(_:questions:)`（`DSHRemoteHarness.swift:205-227`）归一化，与官方 `AskUserQuestionAnswer` 一致；工具行折叠态的 24pt 行高 / 16pt 图标位 / 13pt 标题 / 2pt 中点 / 13pt summary（`NativeMessageRows.swift:21-45`）也已与官方 `DisclosureRow` 基本对齐——**缺的是内容与卡片，不是骨架**。

---

## 1. 审计范围与方法

### 1.1 官方（只读）

| 包 / 文件 | 读法 |
|---|---|
| `packages/client/ui-user-questions/src/client/*`（`contract/slots.ts`、`QuestionComposer.tsx`、`QuestionComposer.module.css`、`QuestionReplyView.tsx(.module.css)`、`question-reply.ts`、`PlanReviewPanel.tsx(.module.css)`、`draft-store.ts`、`locales.ts`、`index.ts`） | 全文 |
| `packages/client/ui-tool/src/client/tool/toolviews/ask-question-row.tsx`、`components/AskQuestionCard.tsx(.module.css)`、`components/QuestionToolRow.tsx(.module.css)`、`models/ask-question-card-model.ts`、`components/ToolRow.module.css` | 全文 |
| `packages/interaction/user-questions/src/types.ts`、`packages/interaction/tool-ask-user/src/index.ts` | 全文 |
| `packages/bundle/web-app/cordis.patch.yml`（shipped composition）、`presets/standard.patch.yml`、`presets/ptc.patch.yml`、`presets/cordis.patch.yml` | 定位 `ui-user-questions` 与 `tool-ask-user` 挂载方式 |
| `packages/client/ui-conversation/src/client/skeleton/{ConversationContent.tsx,ConversationRoot.module.css,InputBar.module.css}`、`contract/slots.ts` | composer 链与座位 |
| `packages/client/ui-session/src/client/index.ts` | pending-interaction 优先级/占座 |
| `packages/client/ui-mobile/src/client/mobile.module.css` | `<640px` 手机特化 |
| `packages/client/ui-theme/src/styles/{design-platform.css,base.css,gradient-shadow-text.css}` | token 解析 |
| `packages/client/ui-primitives/src/{Button.module.css,DisclosureRow.module.css,StateDot.module.css}` | 按钮/披露行原子 |
| locale：`ui-user-questions/src/client/locales.ts`、`ui-conversation/src/client/locales.ts`、`ui-chat/src/client/locale.ts`、`locale/src/locales/zh.ts` | 中文文案原文 |
| 测试/golden：`ui-user-questions/tests/{user-questions-composer.client.spec.tsx,QuestionReplyView.client.spec.tsx,pending-question.client.spec.ts,plan-review-panel.client.spec.tsx,question-draft-store.client.spec.ts}`、`ui-tool/tests/ask-question-row.client.spec.tsx`、`apps/web/tests/question-composer.e2e.ts`、`snapshots/web/question-composer/{ui,answered,answered-expanded,cancelled,late-answered,queued}.expected.md` | 行为与 ARIA 证据 |

### 1.2 iOS（只读）

`examples/probe-app/PhoneDSHProbe/{ChatPage.swift, ChatModel.swift, NativeConversationModels.swift, NativeTranscriptProjector.swift, NativeMessageRows.swift, NativeChatTimelineChrome.swift, NativeToolCallModel.swift, NativeToolDetailCards.swift, NativeChatTheme.swift}`、`Sources/PhoneDSHAgentCore/{AgentHarness.swift, DSH/DSHRemoteHarness.swift, DSH/DSHEventMapper.swift, DSH/DSHMessageSourceClassifier.swift}`、测试 `examples/probe-app/PhoneDSHSimTests/ChatWorkflowTests.swift`、截图 `docs/receipts/ios-baseline-screens/{VISUAL.md,INDEX.md,ios-chat-permission.png,ios-chat-default.png}`。

### 1.3 用到的搜索（含「没有」的证据）

```bash
# iOS 侧穷尽搜索（examples/probe-app/PhoneDSHProbe + Sources 全量）
grep -rn "plan-review|planReview|countdown|skipQuestion|上一题|下一题|推荐|recommended|user-question-reply|question-reply|已回答|进度|minimized" --include=*.swift .
#   → 全部 0 命中（"intent"/"deadline" 的 132/306 命中经二次过滤 question 后为 0）
grep -rn "deadline" --include=*.swift . | grep -i question      # 0
grep -rn "intent"   --include=*.swift . | grep -i question      # 0
grep -rn "attachWait" --include=*.swift .                       # 0
grep -rn "userQuestions" --include=*.swift .                    # 0（含 remote 调用与 projection 读取）
grep -rn "ask_user_question" --include=*.swift .                # 仅 1 处：NativeToolCallModel.swift:50
# 官方侧注册点搜索
grep -rn "conversation.composer" packages/client --include=*.ts   # 找到 4 个 chain 贡献（question/approval/subagent/plan）
grep -rn "conversation.plan-review.actions" packages/client --include=*.ts
grep -rn "ask.rowTitle|ask.answered|ask.review" packages/client/ui-conversation/src/client/locales.ts
```

**关键否定证据**：iOS 全仓库没有任何 `question reply` / `ask` 行 / `plan review` / 倒计时 / 草稿 / 跳过 的代码路径（上表 0 命中）；`plugins/channel`、`plugins/worker-entry`、`plugins/surface-phone` 源码里 `question` 也是 0 命中（`grep -rn "question" plugins/*/src/*.ts`），即**通道从未转发问题事件**，问题链路只走 mux waterfall（`DSHRemoteHarness.swift:397-429`）。

### 1.4 截图对照

- `ios-chat-permission.png` / `ios-chat-default.png`：iOS 待处理卡区与卡片风格（**截图观察**：44 pt 折叠条、`#F2F3F5` 底、12 pt 圆角、20 pt 标题、17 pt 正文、341.7×47.7 主按钮 `#2F5BFF`，见 `VISUAL.md:61-83`）。**没有任何一张 baseline 截图覆盖提问卡**（`INDEX.md:75-82` 的 8 张 chat 预览里无 question 状态），所以 iOS 侧提问卡的像素只能从源码读。
- 官方手机宽度视觉基线只能靠 `ui.expected.md` 的 ARIA 树 + CSS 静态值，**未做 Web 实测**（见 §8）。

---

## 2. 官方基线（按 surface 列）

### 2.1 Surface 总表

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| A1 | 接管 composer 的提问卡（阻塞式 `ask_user_question` 一发起即出现） | `ui-user-questions/index.ts:382-393`；`ConversationContent.tsx:170-186`；`ui-slots/src/index.ts:279-288` | `frame > section.card > header(标题块+操作组) / body(detail+options+custom) / footer(pager+feedback+actions)`；链选举后**原 InputBar 被 `display:none` 保留**（不卸载） | 卡片宽 **338**（402 − 2×(16 clearance + 16)），圆角 **20**，`max-height: min(60vh,520px)`，`padding: 0 0 10px`；frame `padding: 6px 32px 10px` | 见 §2.2 | `open` / `continued` / 收起 / busy / 校验错误 / 通道不可用 | waterfall `user-questions/request`，或 `userQuestions` projection 的 `active`（`slots.ts:226-294`、`index.ts:286-359`） |
| A2 | 题头 | `QuestionComposer.tsx:438-444`，`css:78-104` | eyebrow(可选) + `h2` 标题（`aria-labelledby` 于 `section`） | `padding: 10px 12px 0 18px`（≤720px）；eyebrow `11/16` + `margin-bottom:5`；title `15/21` `500`（>720 时 `16/22`）；`gap:16` | 题目原文；header 原文 | 收起时 `padding-bottom:14` | `question.question` / `question.header` |
| A3 | 头部操作组 | `QuestionComposer.tsx:445-484`，`css:56-74,135-157` | `waitStatus` + 「慢慢回答」+ 收起 + 关闭，`gap:4` | `iconButton` **24×24**，圆角 **999**，色 `label-tertiary`；`waitStatus` `12/24` `label-secondary`；`Button outline` 高 36 | `收起问题卡片` / `展开问题卡片`；`放弃整组问题`（无 callId）/ `收起问题面板，可从工具调用重新打开`（有 callId） | hover 背景 `interactive-bg-hover`；busy 时 disabled（色 `label-dimmed`） | `PendingQuestion.dismissal`（`slots.ts:250`） |
| A4 | 选项列表 | `QuestionComposer.tsx:498-537`，`css:168-232,272-305` | `role=radiogroup`（单选）/ `role=group`（多选）；每行 `button` 带 `role=radio` 或 `role=checkbox` 与 `aria-checked` | 列表 `padding: 4px 8px`、`gap:1px`、`margin-top:8`；行 `min-height:40`、`padding: 8px 6px`（≤720）、`gap:8`、圆角 **12**、`border:1px transparent`；选中 `background: rgba(38,49,72,.06)` + `border: rgba(0,0,0,.1)`；指示器 **20×20**（数字：圆角 4、底 `#E9ECF2`、色 `#61666B`、`12/18 500`；多选：14×14 方框 `0.5px rgba(0,0,0,.16)`+勾 12px）；label `14/24 500`；description `14/24 400 tertiary`；推荐徽章 `11/18 600`、`padding 0 4`、圆角 4、底 `#E4EDFD`、字 `#4176E6` | `推荐` | hover/selected 过渡 **120ms**（`prefers-reduced-motion` 关掉）；Enter 键=提交（`tsx:511-515`）；单选点选后自动进下一题（`tsx:326-336`） | `question.options[]`、`question.multiSelect` |
| A5 | 自定义答案行 | `QuestionComposer.tsx:543-577`，`css:317-424` | 有选项时：选项形状的行 + 内联 textarea；无选项时：整块 `customBlock` | 行同 A4；`customBlock`：`min-height:64`、`margin: 0 12px`、`border:0.5px rgba(0,0,0,.16)`、圆角 **16**、底 `#F5F6F7`、`padding: 8px 12px`；focus 边框 `#4176E6`；文本 `14/24`，**手机端被 ui-mobile 提到 16px**（`mobile.module.css:170-175`）；自增高上限 **144px = 6 行**（`css:380-385`），超出 textarea 自己滚 | placeholder `输入你的答案` | Enter 提交 / Shift+Enter 换行 / IME 保护（`tsx:64-68,413-417`）；单选输入自定义会清掉选项（`tsx:403-411`） | `draft.custom` |
| A6 | 底栏 | `QuestionComposer.tsx:596-634`，`css:110-133,426-443` | pager（‹ `1 / N` ›）+ feedback（`role=status`）+ actions（跳过 / 下一题\|提交） | `margin-top:12`，`padding: 0 10px`（≤720），`gap:12`，`align-items:flex-end`；pager `gap:6`，进度 `14/24 500` `padding 0 4` `word-spacing:-2`；feedback `flex:1` `min-height:16` `11/16` `#EC1313` 右对齐；按钮 `Button md` 高 **36**、圆角 **12**、`padding 0 14`、`14/22`；主按钮底 **`#0F1115`**、字 `#FFFFFF`（`Button.module.css:36-39` + `design-platform.css:192,204`）；次按钮 `0.5px rgba(0,0,0,.12)` 描边 | `上一题`/`下一题`/`跳过`/`下一题`/`提交`/`正在提交…` | 末题且无通道时提交禁用；校验错误 `请先完成这道问题。`/`请选择一个选项或填写自定义答案。`/`当前无法提交，请稍候再试。`/`回答未送达，工作已继续，请再提交一次。`/`回答已发送；面板未能关闭。` | `draft`/`error`/`busy` |
| A7 | 等待/倒计时态 | `slots.ts:204-219,328-351,364-384,444-509`；`tsx:446-463` | 头部多出 `waitStatus` + 「慢慢回答」 | `12/24` secondary；按钮 36 高 outline | `{seconds} 秒后继续工作` / `已暂停 · 剩余 {seconds} 秒` / `会一直等你回答` / `已继续工作，仍可回答` / `慢慢回答` | `waitState`: `counting → focused → editing → waiting → continued`；每秒 tick，到点 `ASK_TIMED_OUT`（卡片保留） | `wait.timed` + `attachWait` claim（`index.ts:222-257`） |
| A8 | 只读 review 面板（已答/已跳过） | `index.ts:182-192`；`tsx:163-204,464,539-592,617-633` | 同一 `QuestionFlow`，`locked`，草稿由 `review[].answers` 还原 | 同 A1–A6；被跳过时插入 `reviewNote`（`padding: 8px 12px`，`14/24` tertiary）；答案用 `14/24` 主色 | `已回答`（状态徽标）/`这道问题当时被跳过。`/`关闭`=`收起问题面板…` | 输入全 disabled；pager 可走；无跳过/提交 | `PendingQuestion.review` = 工具行给的 `UserQuestionRecord` |
| A9 | 已回答的工具行（transcript） | `ask-question-row.tsx:214-368`；`QuestionToolRow.tsx:20-64` | 24pt 披露行：`[16 图标] 6 [提问 13/24] 8 [2×2 点] 8 [summary 13/24 截断] [胶囊按钮]` | 行高 **24**；图标 16 盒 / 14 字形；`sep` 2×2 圆角 1、色 `label-caption`；胶囊 `height:22`、`padding: 0 10`、`margin-left:8`、圆角 999、底 `#FFFFFF`（dark `#2C2C2E`）、`12px` 字、13px 图标 | 标题 `提问`；summary `{answered}/{total} 已回答`；按钮 `回答` / `查看回答`；运行中 `等待回答`；取消 `已取消`；中断 `已中断`；已结束 `已结束` | `data-state` = running/ok/stopped；运行中标题 shimmer | `tool/call.arguments` + `tool/result` + `userQuestions` projection（`ask-question-row.tsx:224-241`） |
| A10 | 展开的问答卡 `AskQuestionCard` | `AskQuestionCard.tsx:11-40`；`css:1-67` | answered：`dl` 每项 `dt 问题 / dd 答案行`；unanswered：`verdict` + `ul` 问题列表 | 卡 `margin: 4px 0 4px 4px`、`padding: 16px 20px`、`gap:16`、`max-height:360` 滚动、`border:0.5px rgba(0,0,0,.04)`、圆角 **16**、底 `#FFFFFF`；问题 `14/24` tertiary；答案 `14/24` primary；未答列表 `padding-left:20`、`gap:8` | 未答 verdict：`等待中的问题仍可在输入框中回答` / `该问题已结束，结果见下方对话` / `本轮已取消，未提交回答` / `本轮已中断，未提交回答`；未答答案 `未回答` | 只读 | `answers[]` 按 `id` 配对（`ask-question-row.tsx:124-148`） |
| A11 | 迟到回复气泡 `QuestionReplyView` | `question-reply.ts:149-187`；`QuestionReplyView.tsx:30-105`；`css:1-166` | 右对齐：`bubble(可折叠) + actions(时间 + 复制)`，`role=group aria-label` | 行 `align-items:flex-end` `gap:6` `padding: 4px 0`；气泡 `max-width:72%`、`padding: 10px 16px`、圆角 **20**、底 **`#EDF3FE`**（dark `#2C2C2E`）、`14/22`；label `13/18` secondary + caret 12px；summary `margin-top:3`；details `margin-top:8`+`padding-top:8`+`border-top:1px rgba(97,102,107,.24)`；`dt 12px`、header/detail/options `11px`、`dd margin-top:4`、answer `14`、answerLabel `12`；actions 高 28、`gap:8`；时间 `13/24`；复制按钮 28×28 圆角 8、图标 15 | `回答先前等待中的问题`；副标题 `展开问题详情`/`收起问题详情`；`回答：`/`已跳过`；复制 `复制`/`复制成功` | 折叠显示 summary（答案逗号拼接）；展开逐题；复制含"问题 — 答案"整块 | `user/message` with `source.kind='user-question-reply'`（`question-reply.ts:134-143`）；payload JSON 解析失败回落 `data.text` |
| A12 | plan review 分流 | `slots.ts:54-101`（`planReviewOf`）；`QuestionComposer.tsx:139-154`；`PlanReviewPanel.tsx:29-91`；`css:1-109` | 同一 composer 座位换成决策卡：`warn strip + 摘要 + [要求修改][同意执行]`，右上角 `conversation.plan-review.actions`（`ui-plan/src/client/index.ts:97-98`） | 卡同 A1；strip `padding: 12px 16px`、底 `#FEF5E7`、字 `#F59E0B`、`14/20`、`gap:8`、StateDot 10px 琥珀；summary `padding: 14px 16px 12px`；title `15/22 500` 单行省略；description `14/24` secondary `-webkit-line-clamp:2`；footer `padding: 8px 12px 10px`（≤720）；按钮 36 高，左 `要求修改` 带 14px 图标 | `计划待审`/`同意执行`/`拒绝`/`要求修改` | 判定条件：单题 + `intent.kind==='plan-review'` + 有 detail + 非多选 + ≤2 选项 + approve 命中标签 | `question.intent` + `question.detail`（plan markdown） |
| A13 | 迟到/并发问题与 pending 优先级 | `index.ts:371-374`（precedence）、`index.ts:117-156`（reveal/hide）、`ui-session/src/client/index.ts:468-486` | 每个 prompt 只能占一个座位；**precedence 数值大者胜**：approval `0`（`ui-approval/src/client/index.ts:88-90`）< question `1` < plan-review `2`；同分后注册者覆盖 | — | — | 占座者被换下时**不结束请求**（`hide`），时间仍在走；卡片始终可从工具行 `回答` 重新占座 | pending-interaction registry |
| A14 | 手机宽度特化 | `mobile.module.css:143-175`；`ConversationRoot.module.css:384-397`；`InputBar.module.css:10,35` | composer 座位 `position: fixed; bottom: 0; z-index:31`；滚动区 `padding-bottom: var(--dsh-composer-height,152px)` | 输入卡宽 = 402−32 = **370**；提问卡宽 = **338**（比输入卡窄 32）；输入类控件强制 `font-size:16px`；`[data-composer-seat]` 固定后键盘弹起不改 DOM 位置 | — | `overscroll-behavior-y: contain` 防橡皮筋 | — |

### 2.2 官方文案（中文原文，逐字）

```
[question ns — ui-user-questions/src/client/locales.ts:4-36]
error.incomplete   请先完成这道问题。
error.unanswered   请选择一个选项或填写自定义答案。
error.unavailable  当前无法提交，请稍候再试。
error.resubmit     回答未送达，工作已继续，请再提交一次。      ← 注意官方用「工作已继续」不是「仍可回答」
status.sent        回答已发送；面板未能关闭。
wait.takeTime      慢慢回答
wait.countdown     {seconds} 秒后继续工作
wait.paused        已暂停 · 剩余 {seconds} 秒
wait.held          会一直等你回答
wait.continued     已继续工作，仍可回答
review.status      已回答
review.skipped     这道问题当时被跳过。
reply.label        回答先前等待中的问题
reply.open         展开问题详情     reply.close  收起问题详情
reply.answerLabel  回答：           reply.skipped 已跳过
nav.prev 上一题   nav.next 下一题
nav.minimize 收起问题卡片   nav.maximize 展开问题卡片
nav.cancel   放弃整组问题
nav.close    收起问题面板，可从工具调用重新打开
option.recommended 推荐
custom.placeholder 输入你的答案
action.skip 跳过     action.next 下一题
plan.header 计划待审  plan.approve 同意执行  plan.decline 拒绝  plan.discuss 要求修改

[conversation ns — ui-conversation/src/client/locales.ts:290-303]
ask.rowTitle        提问
ask.waiting         等待回答
ask.pending         已继续工作，仍可回答
ask.pendingDetail   等待中的问题仍可在输入框中回答
ask.reopen          回答
ask.review          查看回答
ask.closed          已结束
ask.closedDetail    该问题已结束，结果见下方对话
ask.cancelled       已取消
ask.cancelledDetail 本轮已取消，未提交回答
ask.interrupted     已中断
ask.interruptedDetail 本轮已中断，未提交回答
ask.answered        {answered}/{total} 已回答
ask.skipped         未回答

[common ns — packages/client/locale/src/locales/zh.ts:6-22]
copy 复制   copied 复制成功   submit 提交   submitting 正在提交…

[chat ns — ui-chat/src/client/locale.ts:47]（过程分组标题）
message.stepProcess.done.questions 向用户提出了问题      prepare.questions 准备提问
```

### 2.3 官方状态机（`QuestionCardSnapshot`，`slots.ts:204-219`）

| 维度 | 取值 | 触发 | 视觉后果 |
|---|---|---|---|
| `state` | `open` / `continued` | 投影行状态 | `continued` → 头部 `wait.continued` 徽标，仍可答（走 RPC） |
| `waitState` | `counting` / `focused` / `editing` / `waiting` / `continued` | 焦点 / 首次编辑 / 「慢慢回答」/ 已继续 | `counting` 显示倒计时；`focused`/`editing`/`waiting` 显示 `会一直等你回答`；blocking（无 deadline）**完全不显示等待态**（官方测试 `user-questions-composer.client.spec.tsx:202-217`） |
| `countdown` | `{remainingMs, running}` \| undefined | `wait.timed=true` | `wait.countdown` / `wait.paused`（focus 冻结时 `running:false`） |
| `channel` | `waterfall` / `rpc` / `none` | 请求来源 | `none` → 提交/丢弃报 `error.unavailable` |
| `closed` | bool | 卡片移除 | 清草稿 |

> **shipped 组合的重要事实**：`tool-ask-user` 的 `Config.mode` 默认 `'legacy'`（`packages/interaction/tool-ask-user/src/index.ts:23-26`），而 shipped 预设挂载时**不传 config**（`packages/bundle/web-app/presets/standard.patch.yml:110-111`、`ptc.patch.yml:113`、`cordis.patch.yml:110`），因此官方随附的是**阻塞式**提问：没有倒计时、没有 `continued`、没有 `pending` 结果，`Answered` golden 里也确认了这一点（`snapshots/web/question-composer/ui.expected.md:1-15` 头部只有标题 + 两个 24px 按钮，没有等待文案）。**倒计时/`已继续工作`/`查看回答` 属于 `mode: timed` 才可达的 surface**（`late-answered.expected.md`、`queued.expected.md` 是 timed 的 golden）。iOS 侧不需要"默认"实现倒计时，但必须留出数据/状态位（见 Q-14）。

---

## 3. iOS 现状（按 surface 列）

| # | Surface | iOS 实现（file:line） | 现在画成什么 | 行为 | 与官方的差 |
|---|---|---|---|---|---|
| B1 | 待处理区入口 | `ChatPage.swift:480-551`（`cardsRegion`）、`ChatPage.swift:181-194`（位于页头与 transcript 之间） | 页头下方一条独立区域，`ScrollView` 上限 `UIScreen.height*0.4`（874→**349.6pt**） | 键盘弹起且未展开时折成一行 `N 项需要处理`（44pt 行，`Circle` 8pt `#B45309` + `13pt` 文本 + `chevron.down` 12pt） | 官方在 **composer 座位**（底部、固定、接管输入条）；iOS 在**页面顶部**，且输入条仍在 |
| B2 | 提问卡 | `ChatPage.swift:2139-2244` | `VStack(spacing:14)` + `padding(14)` + `frame(maxWidth:.infinity)` + 底 **`accentColor.opacity(0.09)`**（≈`#2F5BFF` 9%），**无圆角、无描边、无阴影**；宽 = 402−32 = **370pt** | 纯本地 `@State` 三个字典 | 官方 338 宽、20 圆角、白底、panel 阴影、内容内边距分段 |
| B3 | 题头 | `ChatPage.swift:2164-2168` | `Label("需要你的回答", systemImage:"questionmark.circle.fill").font(.headline)`（**17pt semibold**）+ 可选 `question.prompt`（13pt secondary） | 无 eyebrow / 无 `h2` / 无 `aria-labelledby` 类比 | 官方 eyebrow 11/16 + 标题 15/21 500，且**没有图标**、没有"需要你的回答"这类自造标题 |
| B4 | 选项 | `ChatPage.swift:2182-2219` | 每题一个小卡：`padding(10)`、`spacing(8)`、圆角 **12**、底 `Color(.secondarySystemBackground)`(`#F2F2F7`)；行 `minHeight: 44`；SF Symbol `circle`/`largecircle.fill.circle`/`square`/`checkmark.square.fill`（≈17pt）；文本默认 **17pt**；选中整行变 `accentColor` | 单选立即生效；多选 toggle | 官方：40pt 行、**20pt 数字chip / 14pt 方框**、无圆圈图标、`14/24 500`、整行底色+描边而非文字变色、无内层小卡 |
| B5 | 自定义答案 | `ChatPage.swift:2208-2212` | `TextField(item.options.isEmpty ? "输入回答" : "其他回答")` + `.textFieldStyle(.roundedBorder)`，**单行**、~36pt 高、系统描边 | `onChange` 里单选清空选项 | 官方：自增高 textarea（6 行上限 144px）、`14/24`（手机 16px）、Enter 提交 / Shift+Enter 换行 / IME 保护、placeholder `输入你的答案` |
| B6 | 提交 | `ChatPage.swift:2172-2174, 2227-2243` | `Button("提交回答", systemImage:"arrow.up").buttonStyle(.borderedProminent)`，`disabled(!canSubmit)`（`canSubmit` 在 `:2152-2160`） | 一次提交全部题目 | 官方底栏：pager + feedback + `跳过` + `提交`（36pt 高、12 圆角、近黑 `#0F1115` 底），校验失败**就近** 11pt 红字 |
| B7 | 分页 | 无（`grep 上一题/下一题/进度` 0 命中） | 题目全部平铺 | — | 官方 `1 / N` + ‹ › + 单选自动前进 |
| B8 | 跳过 | 无（`grep 跳过/skipQuestion` 0 命中） | 只能每个问题都答 | — | 官方 `跳过` 且"跳过后仍可提交整组"，跳过的题在历史里记 `未回答` |
| B9 | 取消整组 | 无 | 只能答完 | — | 官方 `放弃整组问题` → `ASK_CANCELLED`，工具行变 `已取消` + `本轮已取消，未提交回答` |
| B10 | 收起/关闭 | 无（`grep minimized` 0 命中） | — | — | 官方两个 24pt 按钮 |
| B11 | 推荐项 | 无（`grep 推荐/recommended` 0 命中） | 官方标记 `(Recommended)`/`（推荐）` 的标签被**原样显示成选项文本** | — | 官方剥掉后缀 + 显示 `推荐` 徽章 + 默认选中 |
| B12 | 已回答 transcript | `NativeTranscriptProjector.swift:72-110` + `NativeToolCallModel.swift:44-108` | 只是普通工具行：标题 `向你提问`、图标 `DSHSparkle`、summary = **`ask_user_question`**（原始工具名，`NativeToolCallModel.swift:104-105` 对 `.others` 的回退），展开后是 `NativeIOCard`（原始 input/output JSON） | 无状态机 | 官方 `提问 · 1/1 已回答` + 问答卡 + `查看回答` 胶囊 |
| B13 | 迟到回复 | `DSHMessageSourceClassifier.swift:15-21` → `.context("user-question-reply")`；`NativeChatTimelineChrome.swift:26-63` | 一条 `上下文 · 1 条` 分组 → 展开后 **13pt 灰字原始 JSON**（`{"kind":"answer_to_pending_question",...}`）；来源名不翻译（`NativeChatTimelineChrome.swift:114-122` 的 `chinese()` 无此 case → 返回 nil） | 只读、可复制 | 官方右对齐气泡 + 折叠 + 复制 + 时间 |
| B14 | plan review | 无（`grep plan-review/planReview` 0 命中） | — | — | 官方同座位换成决策卡 |
| B15 | composer 关系 | `ChatPage.swift:1605-1610` `composerEnabled` 在 `pendingQuestion != nil` 时 false；`:1409`、`:1487` 的权限/模型按钮同样禁用 | **输入条照旧渲染但整体禁用** | 用户想"先打一句别的"做不到 | 官方输入条被 `display:none` 隐藏，卡片占位；草稿保留 |
| B16 | 优先级 | `ChatPage.swift:512-545`：`pendingPermission` 优先渲染，question 折成 `还有 1 个待确认`（12pt） | 权限卡压问题卡 | 必须先把权限点掉 | 官方 precedence：plan-review(2) > question(1) > approval(0)，**问题压权限** |
| B17 | 并发多问 | `ChatModel.swift:1760-1762` `pendingQuestion = question` **直接覆盖** | 后来的问题把前一个顶掉，前一个再无 UI 入口 | 前一个请求悬挂（`pending[eventID]` 仍在 `DSHRemoteHarness` 里） | 官方每个 call 一张卡 + 座位轮换，旧卡可从工具行回到座位 |

---

## 4. 差距清单（核心交付）

> 「像素/行为对齐合同」= 402pt 下必须落到的数值/结构；「数据依赖」= 上游要先补的东西。

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
|---|---|---|---|---|---|---|---|---|---|
| **Q-01** | **P0** | 已回答问答在 transcript **完全不存在**：无 `提问 · {n}/{m} 已回答` 行、无问答卡、无 `查看回答` 只读面板 | `ask-question-row.tsx:158-174,297-334,346-351`；`AskQuestionCard.tsx:11-40`；`index.ts:182-192` | `NativeToolCallModel.swift:44-108`（只有通用行）；`grep 已回答/查看回答` = 0 | 用户滑回历史看不到"我问了什么、答了什么"，只看到一坨 JSON 在工具行里 | 工具行：24pt 高、16 图标盒 + 6 gap + `提问` 13/24 + 8 + 2×2 点 + 8 + summary 13/24 截断 + 右侧胶囊（h22 / `padding 0 10` / 999 圆角 / 12px）；展开卡：`padding 16 20`、圆角 16、`0.5px rgba(0,0,0,.04)`、底 `#FFFFFF`、`gap 16`、问题 14/24 tertiary、答案 14/24 primary、未答项 `未回答` tertiary | tool/call + tool/result 的 `{answers}` 配对（已有：`NativeTranscriptProjector.swift:88-110`），需新增 `ChatItem.Kind.questionAnswered` 或 `toolMetadata.questionRecord` | 新增 `NativeAskQuestionCard` + 在 `NativeToolCallRow` 对 `ask_user_question` 特判（`variant = .question`）；`summary` 走 `{answered}/{total} 已回答` | 快照/单测：给定 args+result JSON，行 summary 文本 == `1/1 已回答`，展开含 `题目`/`答案` 两条文本 |
| **Q-02** | **P0** | 迟到回复（`user-question-reply`）被画成「上下文 · 1 条」+ **原始 JSON**（且来源名不翻译） | `question-reply.ts:134-187`；`QuestionReplyView.tsx:30-105`；`css:1-166`；`late-answered.expected.md:26-29` | `DSHMessageSourceClassifier.swift:15-21`；`NativeChatTimelineChrome.swift:114-122`；`NativeTranscriptProjector.swift:20-45` | 用户看到模型层的内部 JSON，完全不知道这是"我对刚才那个问题的回答" | 右对齐：`align-items:flex-end`、`gap:6`、`padding:4px 0`；气泡 `max-width:72%`、`padding:10px 16px`、圆角 20、底 `#EDF3FE`（dark `#2C2C2E`）、`14/22`；首行 caret 12 + label 13/18 secondary（`回答先前等待中的问题`）；折叠 summary `14` primary `margin-top:3`；展开 `details` 上边框 `1px rgba(97,102,107,.24)`、`dt 12px`、answer 14 + `回答：` 12 secondary；右下 actions 高 28：时间 `13/24` + 复制 28×28 圆角 8 图标 15 | 需要保留 `user/message.source`，并解析 content[0].text 的 JSON（`questions/answers`） | 新增 `ChatItem.Kind.questionReply`；projector 在 `user/message` 分支先判 `source.kind == "user-question-reply"`；新组件 `NativeQuestionReplyBubble` | 单测：喂 `late-answered` 的 session JSONL 片段 → 产生 1 个 `questionReply` item，渲染文本含 `回答：Green, Answered after the timeout` |
| **Q-03** | **P0** | 多题没有分页/进度/逐题导航/单选自动前进 | `QuestionComposer.tsx:596-613`（pager）、`:326-336`（自动前进）、`:387-398`（continueFlow） | `ChatPage.swift:2169-2171`（`ForEach` 平铺） | 4 题时卡片把屏幕塞满（上限 349.6pt 内滚动），用户不知道"还有几题 / 我答到哪" | 底栏左：‹ 24×24（`disabled` 色 `#E1E5EE`）+ 6 + `1 / N`（14/24 500 secondary、`padding 0 4`、`word-spacing:-2`）+ 6 + › 24×24；首题 ‹ 禁用、末题 › 禁用；单选点选后自动 `index+1`（末题不前进） | 无（纯 UI 状态） | 把 `QuestionCard` 改成"索引 + 每题一屏"（`@State index`），末题才显示 `提交` | 3 题 fixture：初始 `1 / 3`，选第 1 题选项后变 `2 / 3` |
| **Q-04** | **P0** | 无 `跳过`、无 `放弃整组问题`、无 `收起/展开`、无 `关闭` | `tsx:419-430`（skip）、`:294-314`（dismissFlow）、`:465-482`（两个 24pt 按钮）、`css:46-54` | `grep 跳过/skipQuestion/nav.cancel/minimized` = 0 | 用户被迫回答不想答的题；也不能把卡片收起来看对话 | `跳过`= outline 36h/12r/`0.5px rgba(0,0,0,.12)`/14-22/`padding 0 14`；`提交`=近黑填充；头部两个 24×24 圆形按钮（收起用 chevron，关闭用 ✕），收起后卡高 = header（`padding-bottom:14`） | 无 | 三个动作：`skipCurrent`、`dismissAll`（`$events/result` outcome `UserQuestionError/ASK_CANCELLED` 或让 Host 结束）、`minimized` 布尔 | 手测 + 单测：skip 末题直接提交，答案里该题 `selected: []` 无 `custom` |
| **Q-05** | **P0** | 数据层丢字段：`header`、`detail`、`options[].description`、`intent{kind,approve,callId}`、`wait{callId,timed}` | `types.ts:38-53`（`AskUserQuestionItem`）、`:128-146`（`wait`） | `DSHRemoteHarness.swift:410-422`（只取 `id/question/options.label/multiSelect`）；`HarnessQuestionItem` `AgentHarness.swift:298-307` 只有 4 个字段 | eyebrow、plan markdown、选项说明、plan review、按 call 重开——**全部不可达** | 不做像素，做字段直通 | 无（协议已有） | 扩 `HarnessQuestionItem`（+header/detail/description/selected 推荐标记）与 `HarnessQuestion`（+callID/intent/kind）；`DSHRemoteHarness` 直接透传 `questions` 原始 JSON 更稳 | 单测：喂带 header/detail/description/intent 的 request → 解析后字段齐全 |
| **Q-06** | **P0** | plan-review 路由缺失：问题入口不分流，无决策卡 | `slots.ts:81-101`；`QuestionComposer.tsx:139-154`；`PlanReviewPanel.tsx:29-91` | `grep plan-review/planReview/intent+question` = 0 | 计划审阅在 iOS 上退化成普通单选题，`同意执行` 语义丢失 | strip：`padding 12 16`、底 `#FEF5E7`/dark `#27241F`、字 `#F59E0B`、14/20、gap 8、StateDot 10 琥珀 + `计划待审`；摘要 `padding 14 16 12`、title 15/22 500 单行省略、desc 14/24 secondary 两行截断；footer 两个 36pt 按钮（`要求修改` outline+14px 图标、`同意执行` 近黑填充） | Q-05 的 `intent` + `detail` | 与 Axis 02 共享组件；在 `QuestionCard` 顶部加 `if let review = planReviewOf(...)` 分流 | 单测：intent=plan-review 的请求渲染出 `计划待审` 而不是选项列表 |
| **Q-07** | P1 | 不是 composer 接管：卡片在页面顶部，输入条仍在且被禁用 | `ConversationContent.tsx:170-186`；`ui-slots/src/index.ts:279-288`；`css:4-8` | `ChatPage.swift:181-194`、`:1605-1610` | 提问时用户无法边看对话边答、无法撤销输入；整体"不是官方那个东西" | 卡片落到底部输入条位置、宽 **338**（比输入条窄 32）、frame `padding 6 32 10`、`position: fixed bottom:0`（手机）、滚动区 `padding-bottom = 卡高` | 无 | Wave 2：把 `QuestionCard` 移入 `safeAreaInset(edge:.bottom)` 的 composer 槽位，与 composer 互斥 | 截图：402×874 下卡片底边贴安全区、宽 338、输入条不可见 |
| **Q-08** | P1 | 视觉体系整体不同：无圆角/无阴影/蓝底 9%/系统字体系统控件/17pt | `css:12-36,78-104,176-232,426-443`；`Button.module.css:2-57` | `ChatPage.swift:2162-2179,2197-2220` | 一眼不是官方 | 卡 = 白底 `#FFFFFF`（dark `#2C2C2E`）、圆角 **20**、阴影 `0 0 0 .5px rgba(0,0,0,.1) + 0 3px 8px rgba(0,0,0,.031) + 0 0 16px rgba(0,0,0,.02)`、`max-height min(60vh,520)`；标题 15/21 500；选项 40h/12r/14-24-500；主按钮 36h/12r/`#0F1115` | 无 | 引入 `NativeChatTheme` 新 token：`panelShadow`、`bubble`(#EDF3FE/#2C2C2E)、`warnSurface`(#FEF5E7)、`warnInk`(#F59E0B)、`primaryButtonFill`(#0F1115/#F9FAFB)、`hoverSurface`(rgba(38,49,72,.06)) | 像素比对：卡片宽/圆角/阴影、按钮高宽 |
| **Q-09** | P1 | 无推荐项：标签不剥离、无 `推荐` 徽章、无默认选中 | `tsx:35-46`（`parseRecommendedLabel` + `recommendedFirstOption`）；`css:290-298`；测试 `spec.tsx:219-233` | `ChatPage.swift:2185-2207` 直接 `option` 原文 | 官方会把 `工程落地型（推荐）` 变成 `工程落地型` + 蓝徽章并预选；iOS 让用户读到 `(Recommended)` 英文括号 | 正则 `/\s*(?:\((?:recommended\|推荐)\)\|（(?:recommended\|推荐)）)\s*$/i`；徽章 `padding 0 4`、圆角 4、底 `#E4EDFD`（dark `#353638`）、字 `#4176E6`（dark `#7AAAFF`）、`11/18 600`；仅**第一项**带标记时预选 | 无（args 里有原文） | 在 `HarnessQuestionItem` 上算 `displayLabel/recommended`；初始 `singleSelections[first]` | 单测：`A（推荐）` → 显示 `A` + `推荐`，且默认选中 |
| **Q-10** | P1 | 提交无校验文案/无 busy 冻结/无失败重试/错误跑到页头 banner | `tsx:196-214,343-385,614-616`；`css:436-443` | `ChatPage.swift:2172-2174`（只有 disabled）；错误走 `reportError` → 页顶 `errorBanner`（`ChatPage.swift:187-189`） | 点了没反应/失败不知道为什么 | feedback 位 `flex:1 / min-height:16 / 11-16 / #EC1313` 右对齐，紧贴按钮左侧；提交中文案 `正在提交…`；失败后按钮恢复可点并保留草稿 | 无 | 加 `busy`/`error` 状态；失败保留输入 | 手测：断网提交 → 卡片内 11pt 红字，输入不丢 |
| **Q-11** | P1 | pending 优先级反了：权限卡压问题卡，问题折成 `还有 1 个待确认` | `index.ts:371-374`；`ui-session/src/client/index.ts:468-486`（`>=` 大者胜）；approval `0`（`ui-approval/src/client/index.ts:88-90`） | `ChatPage.swift:512-545` | 权限一来问题就看不见了；官方相反 | 只保留**一个**占座者；问题（1）压过审批（0），plan-review（2）压过问题；被换下的不销毁，仍可从工具行/队列回到座位 | 需要 `pendingQuestion` 改成多张注册表（`[String: HarnessQuestion]`） | 引入 `pendingQuestions` 字典 + `presentedQuestionKey`；权限改为"另一张卡，等座" | 单测：同时有 permission+question → 展示 question；回答后 permission 自动上座 |
| **Q-12** | P1 | 工具行文案/图标/summary/面板按钮全不对 | `ui-conversation/src/client/locales.ts:290`（`提问`）；`QuestionToolRow.tsx:31,39-43`；`QuestionToolRow.module.css:1-29` | `NativeToolCallModel.swift:50`（`向你提问`）、`:40`（`.sparkle` 图标）、`:104-105`（summary 回落成 `ask_user_question`） | 行上直接暴露英文工具名，标题/图标都不是官方 | 标题 `提问`；图标 = 问号（官方 `IconQuestionOutlineRegular`，16 盒 / 14 字形）；无 summary 时留空（不显示工具名）；有答案时 summary `{n}/{m} 已回答`；右侧胶囊 `回答` / `查看回答` | Q-01 | 给 `NativeToolCallModel` 加 `.question` variant + `NativeChatIcon.Name.question`（asset `DSHQuestion` 或 SF `questionmark.circle`） | 快照：行文本 == `提问 · 1/1 已回答` |
| **Q-13** | P1 | 无草稿持久化：切会话/重挂载后答案丢失 | `draft-store.ts:43-63`（`persist: 'dsh.user-questions.drafts.v1'`）；`tsx:183-195`；测试 `question-draft-store.client.spec.ts` | `ChatPage.swift:2143-2145` 纯 `@State` | 后台被调度/切走回来，勾选全丢 | key = `question:{sessionId}:{callId}`；存 `{index, drafts:[{selected,custom,skipped}], wait}`；卡片关闭时清理；只保留 live key | Q-05（callId） | 用 `@SceneStorage`/`UserDefaults` + `Codable` 进度结构 | 单测：写入草稿 → 重建 View → 选项/自定义文本/页码还原 |
| **Q-14** | P1 | 无倒计时/等待态/`慢慢回答`/`已继续工作`（timed 模式不可用） | `slots.ts:204-219,364-384,444-509`；`tsx:446-463`；`locales.ts:11-15`；golden `late-answered.expected.md` | `grep countdown/deadline+question/attachWait` = 0；`HarnessQuestion` 无 deadline 字段 | 若上游开 `mode: timed`，iOS 不会 claim，问题可能根本不显示；用户也看不到"还有几秒" | `waitStatus` 12/24 secondary；`慢慢回答` outline 36h；每秒刷新；0 秒发 `ASK_TIMED_OUT` 且卡片保留；focus 冻结、编辑后转无限等待 | `wait.timed` → 需 `remote.userQuestions.attachWait` 等价调用（当前 Swift 侧 0 处） | 先只做数据/状态位 + 文案，等 Host 支持 claim 再上倒计时 | 单测：deadline 到达后卡片仍在、状态文案变 `会一直等你回答` |
| **Q-15** | P1 | 单选互斥与多选语义不全：单选点选后不自动进下一题；多选时"选项 + 自定义"可同时存在（这条**与官方一致**，但 iOS 的 UI 没有勾选框样式表达） | `tsx:326-336,403-411`；`css:516-522,555-568` | `ChatPage.swift:2189-2212` | 交互节奏与官方不同；多选缺少方形勾选框（用的是 SF 方形图标 + 整行变色） | 多选：20pt 席位内 14×14 方框 + 0.5px 边框 + 12px 勾；单选：20pt 数字 chip | 无 | 重写选项行（见 Q-08） | 快照：多选行显示方框、单选行显示数字 |
| **Q-16** | P2 | 无 Enter 提交 / Shift+Enter 换行 / IME 保护（用了单行 `TextField`） | `tsx:64-68,413-417`；测试 `spec.tsx:330-348,372-408` | `ChatPage.swift:2208` | 中文输入法回车会误提交/无法换行 | 多行 textarea + 组合输入判断；Enter 走 `continueFlow`，Shift+Enter 换行 | 无 | 换 `TextEditor`/`TextField(axis:.vertical)` + `.onSubmit` 区分 | 手测：中文拼音输入回车上屏不断行 |
| **Q-17** | P2 | 无自增高上限（6 行 144px）与内部滚动 | `css:349-401`；e2e `question-composer.e2e.ts:44-73`（`CAP_LINES = 6`） | `ChatPage.swift:2208`（单行） | 长答案输入体验差 | 行高 24，6 行 = 144；超出后字段内部滚动，卡片不继续长 | 无 | 同上 | 手测：40 行文本 → 字段高稳定在 144 |
| **Q-18** | P2 | 键盘弹起把整卡折成一行 `N 项需要处理` | 无对应（官方卡片固定在底部，靠 `100dvh` + 固定座位） | `ChatPage.swift:203-209,486-506` | 打字时看不到题目，必须再点一下 | 不应折叠；卡片应为键盘上方固定面板 | 无 | 与 Q-07 一起改，删掉折叠分支 | 截图：键盘态卡片完整可见 |
| **Q-19** | P2 | 无障碍语义缺失：无 `role=group/radiogroup`、`aria-checked`、`aria-expanded`、`role=status`、无 `aria-label` 组合 | `tsx:436,469,477,498,506-508,614`；`QuestionReplyView.tsx:46,51` | `ChatPage.swift:2189-2205`（`Label` + `.plain`）、`:2172` | VoiceOver 只会念"按钮"，读不出选中态/还有几题 | 选项 `.accessibilityAddTraits(.isSelected)` + `.accessibilityValue("已选中"/"未选中")`；进度念 `第 2 题，共 3 题`；错误用 `.accessibilityLiveRegion` 等价（`UIAccessibility.post`） | 无 | 逐控件补 label/value/trait | Accessibility Inspector 走查 |
| **Q-20** | P2 | 无动效/无 reduced-motion 处理 | `css:198,254,335`（120ms bg/border）、`:478-483` | `ChatPage.swift` 无 `.animation` | 生硬 | 背景/描边 120ms ease；`accessibilityReduceMotion` 时改为 none | 无 | `.animation(.easeOut(duration:0.12), value: selected)` | 手测 |
| **Q-21** | P2 | 指示器细节：iOS 用 17pt SF Symbol 圆圈，官方是 12px 数字/12px 勾 | `css:214-232,234-270` | `ChatPage.swift:2198-2200` | 视觉重量差一档 | 数字 `12/18 500`、20×20、圆角 4、底 `#E9ECF2`；勾 12px、勾底 `#0F1115`、勾色 `#FFFFFF` | 无 | 自绘 chip/checkbox | 截图逐像素 |
| **Q-22** | P3 | 边角状态文案缺失：`已结束`/`该问题已结束，结果见下方对话`/`等待回答`/`已取消`/`已中断` | `ask-question-row.tsx:258-315`；`locales.ts:291-303` | 无（状态机整体缺失） | 工具行读不出问题结局 | 按 `error.code` 分流：`ASK_CANCELLED`→`已取消`(state ok)、`ASK_ABORTED`→`已中断`(state stopped)、running→`等待回答`(shimmer) | Q-01 | 随 Q-01 一起 | 快照三态 |
| **Q-23** | P3 | 写入「计划待审」strip 与 `同意执行/拒绝/要求修改` 三键的完整像素（与 Axis 02 重叠） | `PlanReviewPanel.module.css:28-92` | 无 | — | 见 Q-06 | Q-05/Q-06 | 移交 Axis 02 | — |

**统计：P0 = 6（Q-01…Q-06），P1 = 9（Q-07…Q-15），P2 = 6（Q-16…Q-21），P3 = 2（Q-22、Q-23）。**

---

## 5. 隐藏/条件控件清单

| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 备注 |
|---|---|---|---|---|
| 提问卡接管输入条 | 任一 `ask_user_question` 发起（阻塞或 timed） | `conversation.composer` 链（`index.ts:382-393`） | ❌ 改为页顶卡区 | 官方输入条 `display:none` 但 DOM 保留（草稿不丢） |
| eyebrow（`header`） | `question.header` 存在 | `tsx:440`；golden `ui.expected.md:2` 的 `text: Pick one` | ❌（数据也丢了） | |
| plan markdown（`detail`） | `question.detail` 存在 | `tsx:495-497`（`MarkdownText`） | ❌（数据也丢了） | plan-review 的正文就靠它 |
| 选项描述 | `option.description` 存在 | `tsx:530-532` | ❌（数据也丢了） | 14/24 tertiary |
| 推荐徽章 + 预选 | label 以 `(Recommended)`/`（推荐）` 结尾 | `tsx:35-46,527-529` | ❌ | |
| 分页 | `questions.length > 1` | `tsx:596-613` | ❌ | |
| 跳过 | 有答案通道 | `tsx:620-622` | ❌ | |
| 放弃整组 | 卡片无 callId（阻塞请求） | `tsx:475-482` + `slots.ts:548-555` | ❌ | 发 `ASK_CANCELLED` |
| 收起/展开 | 总是 | `tsx:465-474` | ❌ | 收起只留 header |
| 倒计时 + 慢慢回答 | `wait.timed`（**非 shipped 默认**） | `tsx:446-457` | ❌ | 见 §2.3 |
| `已继续工作，仍可回答` | 投影 `state='continued'` | `tsx:458` | ❌ | |
| 只读 review 面板（`已回答`） | 从工具行 `查看回答` | `index.ts:182-192` | ❌ | 同一 composer 组件、`locked` |
| `未回答`（跳过的题） | review 中该题无选项无自定义 | `tsx:539-541` | ❌ | |
| 工具行 `回答` 胶囊 | 该 call 仍在 `userQuestions.active` | `QuestionToolRow.tsx:39-43` | ❌ | 把卡片重新放回座位 |
| 工具行 `查看回答` 胶囊 | 该 call 已 settled 且能配对 | `ask-question-row.tsx:326-331` | ❌ | |
| 问答卡（answered） | 工具行展开 + result 有 `{answers}` | `AskQuestionCard.tsx:24-39` | ❌ | |
| 问答卡（unanswered/verdict） | 取消/中断/已结束/仍可答 | `AskQuestionCard.tsx:12-23` | ❌ | 4 种 verdict 文案 |
| 迟到回复气泡 | `user/message` 且 `source.kind='user-question-reply'` | `question-reply.ts:149-187` | ⚠️ 有，但画成上下文 JSON（Q-02） | |
| plan review 决策卡 | `intent.kind='plan-review'` 且可归纳 | `slots.ts:81-101` | ❌ | Axis 02 重叠 |
| 排队中的回复（read-only 提交态） | inbox 有 `answer_to_pending_question` | `ask-question-row.tsx:68-75,335-345` | ❌ | golden `queued.expected.md:20-25` |
| 多个 pending 的占座轮换 | 同时有 approval/question/plan-review | `index.ts:371-374` | ❌（覆盖式） | iOS 只有单槽 |

---

## 6. 数据链路缺口

| 事件/字段 | 官方消费方 | iOS 映射/投影 | 缺失后果 | 需要补什么 |
|---|---|---|---|---|
| `user-questions/request.request.questions[].header` | `QuestionComposer.tsx:440` | `DSHRemoteHarness.swift:417-422` 丢弃 | 无 eyebrow | `HarnessQuestionItem.header` |
| `…[].detail` | `tsx:495-497`；`planReviewOf` 的 plan 正文 `slots.ts:86` | 同上丢弃 | 无 plan 正文/无 plan review | `HarnessQuestionItem.detail` |
| `…[].options[].description` | `tsx:530-532` | `:420` 只取 `label` | 无选项说明 | `HarnessQuestionItemOption{label,description}` |
| `…[].intent{kind,approve,callId}` | `planReviewOf`（`slots.ts:81-101`） | 丢弃 | plan-review 分流不可能 | `HarnessQuestionIntent` |
| `…[].multiSelect` | `tsx:498` | `:421` 取 `multiSelect`（**大小写正确**） | — | 已 OK |
| `request.wait{callId,timed}` | `PendingQuestion.key/callId/timed`（`slots.ts:236,390-401`） | `:399-400` 只记 `agentId/eventId`，`requestID = eventID` | 无法按工具 call 关联、无法从工具行重开、无法去重 | `HarnessQuestion.callID` + `timed` |
| `user/message`（`source.kind='user-question-reply'`） | `question-reply.ts:134-187` | `DSHMessageSourceClassifier.swift:15-21` → `.context` | 原始 JSON 上屏（Q-02） | 新增分类分支 + `ChatItem.Kind.questionReply` |
| `tool/call` + `tool/result`（`{answers}`） | `ask-question-row.tsx:297-334` 配对 | 只做 callID 拼接（`NativeTranscriptProjector.swift:88-110`） | 无计数/无问答卡 | 在 projector 里解析 `answers` 写入 `item.toolMetadata`（或专有字段） |
| `userQuestions` projection（`active`/`settled`） | `ask-question-row.tsx:224-241` 决定 `回答`/`查看回答`/`已结束` | `grep userQuestions` = 0，从不读取 | 工具行永远读不出"还能不能答" | 历史投影新增：扫 `ask_user_question` 的 call/result + reply source 重建 `active/settled` |
| `remote.userQuestions.attachWait`（timed claim） | `index.ts:222-257` | `grep attachWait` = 0 | `mode: timed` 时问题可能不送达/立即超时 | `$events`/`userQuestions` 的 claim 调用 |
| turn 中断 → `ASK_ABORTED` | `ask-question-row.tsx:265-271` | `ChatModel` 只清 `pendingQuestion`（`ChatModel.swift:874,922,939`） | 无 `已中断` 记录 | 停止时把该 call 标记 `stopped` |
| pending 的**并发多卡** | `QuestionCards` map + 座位轮换（`index.ts:82-205`） | 单变量覆盖（`ChatModel.swift:1760-1762`） | 第二个问题顶掉第一个 | `pendingQuestions: [String: HarnessQuestion]` + `presentedKey` |

---

## 7. 实施顺序建议

**Wave 1（数据先行，1 个 PR）**
1. Q-05：`HarnessQuestionItem/HarnessQuestion` 扩字段 + `DSHRemoteHarness` 透传（含 `callID/intent/header/detail/description`）。
2. Q-06 的判定函数 `planReviewOf` 移植（纯函数）+ 单测。
3. Q-02：`DSHMessageSourceClassifier` 增加 `user-question-reply` 分支 + `ChatItem.Kind.questionReply` + projector 解析 `questions/answers`。
4. Q-01 的历史重建：projector 里把 `ask_user_question` 的 call/result 配对成 `toolMetadata.questionRecord`。

**Wave 2（结构对齐，最大视觉收益）**
5. Q-07 + Q-18：把提问卡移进 composer 槽位（与输入条互斥），键盘态不折叠。
6. Q-08 + Q-21 + Q-16/Q-17：重写卡片视觉与答案输入（选项行 40pt、数字/方框指示器、36pt 按钮、自增高 textarea）。
7. Q-03 + Q-04：分页/进度/跳过/收起/放弃整组。
8. Q-11 + Q-17（并卡）：pending 多卡 + 优先级按官方 precedence。

**Wave 3（记录与细节）**
9. Q-01 渲染：工具行 `提问 · {n}/{m} 已回答` + 展开问答卡 + `查看回答` 只读面板（复用 Wave 2 的卡片，`locked`）。
10. Q-02 渲染：右对齐气泡 + 折叠 + 复制 + 时间。
11. Q-09 / Q-10 / Q-13 / Q-19 / Q-20 / Q-22：推荐项、校验/重试、草稿、无障碍、动效、边角文案。
12. Q-14：仅在确认要开 `mode: timed` 时实施（否则只留状态位）。

---

## 8. 未知与需确认

1. **未做官方 Web 实测**：本报告的手机宽度数值全部来自 CSS 静态解析 + ARIA golden；`402pt` 下 `.footer` 的 `feedback` 只剩约 68px 宽（pager ~90 + actions ~136 + gaps/padding ~44），`请先完成这道问题。` 在 11px 下约 88px，**推断会折成两行**——需真机/Playwright 确认。
2. **`--dsh-chat-content-width` 在 402 的实际值**：`clamp(680px, 0.64×列宽, 920px)` 的 min 是 680 > 338，所以 `.card` 的 `max-width` 不起作用、`width:100%` 决定 338；但没有 `<640px` 覆写这一层，若上游将来改 clamp 下限，338 会被 `max-width` 截断——属**设计决策点**，不是当前差异。
3. **手机端答案框字号**：`mobile.module.css:170-175` 把 `textarea` 强制 16px，但 `.fieldMirror`（高度标尺）是 `div` 仍是 14px（`QuestionComposer.module.css:359-385`）——**推断官方在手机上镜像与输入框行数会不一致**（官方 e2e 的 `CAP_LINES` 断言在桌面视口跑）。iOS 原生实现建议统一 16px/24px，不要复刻这个潜在缺陷；需与产品确认手机端字号。
4. **键盘与固定座位**：官方手机端 composer 座位 `position: fixed; bottom:0`（`mobile.module.css:143-159`），iOS Safari 键盘弹起时固定元素是否跟随 visual viewport **未实测**；iOS 原生侧建议用 `safeAreaInset` + 键盘通知（现有 `ChatPage.swift:200-209` 已是这个模型）。
5. **`ASK_CANCELLED` 的发送路径**：iOS 目前 `HarnessCommand` 只有 `questionResponse(requestID:answer:String)`（`AgentHarness.swift:260`），没有"取消问题"的 outcome kind。官方客户端 cancellation 走 `waterfall.reject('ASK_CANCELLED')`（`slots.ts:548-555`）。iOS 需要新增 outcome（`{kind:"error", ...}` 还是 `{kind:"result"}` 的特定 error 形状）——需查 Host 端 `$events/result` 的 rejection 编码，本轮未展开。
6. **`{answered}/{total}` 的分母**：官方用 `answers.length`（`ask-question-row.tsx:163,166`），不是题目数；被跳过的题仍计入 total。iOS 实现时不要用 `questions.count`。
7. **plan review 与 Axis 02 的边界**：`PlanReviewPanel` 的 `conversation.plan-review.actions`（`ui-plan/src/client/index.ts:97-98`）在 iOS 上完全没有对应宿主（无右侧栏）。手机端官方就是把审批按钮放在 footer；iOS 需要产品确认"计划全文"如何查看（底部 sheet / 整页 push），本轮不发明。
