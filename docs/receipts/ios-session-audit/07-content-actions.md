# Axis 07 — 消息内容 / 行类型 / 消息动作 / Turn Tail — iOS Session 对齐审计

> 官方基线：`deepseek-harness` @ `7be5505b0be06009d74891c869063c9cf19a0df0`（`0.2.1-rc.2`）。
> iOS：`phone-dsh` 工作区当前状态（未改动任何文件）。
> 视觉基准：手机宽度 402pt，CSS px ≈ iOS pt。

## 0. 结论摘要

- 官方 `conversation.chat.node` 实际注册 **20 个 kind**（ui-chat 本体 15 个，`register-node-renderers.ts:40-89`；ui-tool 的 `tool-call`，`ui-tool/src/client/apply.ts:34-41`；插件贡献 `command-input`/`workflow-run`/`submitted-plan`/`question-reply`），iOS 的 `ChatItem.Kind` 只有 **12 个**、`ChatMessageRow` 只有 **9 个分派分支**，其中 `systemEvent` 一个 kind 吃掉压缩/重试两类语义（`NativeConversationModels.swift:8-12`、`ChatPage.swift:2252-2287`）。官方可见行里 **turn-trigger、system-prompt、command、compaction（结构化）、model-retry（链）、unknown-surface、question-reply、workflow-run、submitted-plan** 在 iOS 上没有任何等价行。
- **P0 两条**：① 用户/助手图片被画成“文件 chip”，既无缩略图网格也无 lightbox 入口（用户发的图在 iOS 上看不到图像本身）；② 非人类输入触发的 **turn-trigger** 行完全不存在，而这正是用户点名的「收到新消息」可见位。
- **P1 十二条**，最扎眼的是排版密度：官方 assistant 正文 **14px/24px**（`AssistantMarkdown.module.css:12-13`），iOS 用 `.system(size:14)` 的自然行高（≈17pt），**每行少 7pt**；官方 transcript 左右各留 32pt（内容宽 338），iOS 留 16pt（370），且官方行距 6/12/16，iOS 12/20/8（`ChatView.module.css:28,72-84` vs `ChatPage.swift:422-443`）。
- 用户气泡是**色相级差异**：官方 `--dsw-specific-bubble` = `rgb(237,243,254)`（浅蓝），iOS `selector` = `#F2F3F5`（中性灰）；padding 10/16、圆角 20、行高 22、最大宽 277pt，iOS 分别 12、22、24、296pt（`MessageItem.module.css:22-40` vs `ChatPage.swift:2331-2345`）。
- 数据链路**不是瓶颈**：历史页 `session/page` 返回的原始 journal 已包含 `system/message`、`command/run|done`、`request/header`、`agent/inbox/spliced`，iOS 自己也在 `ChatModel.trajectoryEntries` 里读过这些类型（`ChatModel.swift:1570-1600`），只是 `NativeTranscriptProjector.items` 的 `default: continue`（`NativeTranscriptProjector.swift:144-145`）和 `DSHEventMapper.map` 的 `default: break`（`DSHEventMapper.swift:108-109`）把它们丢掉；补投影即可拿到 80% 的行，不需要新协议。
- 计数：**P0 = 2，P1 = 12，P2 = 14**（清单见第 4 节）。

## 1. 审计范围与方法

读的官方文件（基线 commit，路径相对 `deepseek-harness/`）：

- 注册与契约：`packages/client/ui-chat/src/client/chat/register-node-renderers.ts`、`conversation-nodes/register.ts`、`conversation-nodes/*.ts` 的 `ChatNodeDataMap` 声明、`contract/chat-nodes.ts`
- 行渲染：`chat/{MessageItem,AssistantNodeView,AssistantMarkdown,UserContent,ContextInjectionRow,ContextBody,SystemPromptRow,CommandNodeView,GenericCommandCard,CompactionCommandCard,CompactionItem,TurnTriggerNodeView,TurnTailNodeView,TurnUsagePanel,MessageIconActions,ReasoningRow,ReasoningContent,UnknownNodeView(TurnErrorItem),StatsPills}.tsx` + 同名 `.module.css`
- 原语：`packages/client/ui-primitives/src/{DisclosureRow,TextShimmer,StateDot,CodeToolbar,ImagePreview,ImageLightbox}.tsx`、`markdown/{MarkdownText,render,parse,CodeBlock}.tsx` + CSS、`CodeCard.module.css`
- 附件/交付物/反馈/提问/计划：`packages/client/ui-attachment/src/{MessageImage.tsx,MessageImage.module.css}`、`ui-deliverables/src/client/{ChangedFiles.tsx,ChangedFiles.module.css,locales.ts}`、`ui-message-feedback/src/client/{MessageFeedbackActions.tsx,MessageFeedbackActions.module.css,locales.ts}`、`ui-user-questions/src/client/{QuestionReplyView.tsx,QuestionReplyView.module.css,locales.ts}`、`ui-plan/src/client/{index.ts,PlanCard.tsx}`
- tokens：`packages/client/ui-theme/src/styles/{design-platform.css,base.css,gradient-shadow-text.css,corner-shape.css}`
- 手机宽度覆盖：`packages/client/ui-mobile/src/client/mobile.module.css`、`ui-conversation/src/client/skeleton/ConversationRoot.module.css`
- shipped composition：`packages/bundle/web-app/cordis.patch.yml`（`ui-conversation:326`、`ui-approval:329`、`ui-chat:332`、`ui-attachment:339`、`ui-tool:343`、`ui-deliverables:352`、`ui-workflow-run:366`、`ui-subagent:380`、`ui-schedule:398`、`ui-goal:402`、`ui-message-feedback:408`、`ui-plan:451`、`ui-user-questions:454`、`ui-mobile:595`）——本轴涉及的包全部在 **web-app 正式组合**里，不是 experimental。
- 官方测试（行为证据）：`ui-chat/tests/{chat-font-axis-styles,turn-tail-spacing,reasoning-row,user-content,system-prompt-row,turn-usage-panel,turn-trigger,image-labels}.client.spec.*`、`ui-primitives/tests/{code-block,code-card-controls,markdown,markdown-compact,markdown-dom-parity,image-preview,disclosure-row-styles}.client.spec.*`

读的 iOS 文件（路径相对 `phone-dsh/`）：

- `examples/probe-app/PhoneDSHProbe/ChatPage.swift`（`timelineRows`/`spacing`/`transcript`/`cardsRegion`/`ChatMessageRow`/`ContextInjectionCard`/`MarkdownContent`）
- `NativeMessageRows.swift`、`NativeChatTimelineChrome.swift`、`NativeMessageActions.swift`、`NativeChatTheme.swift`、`NativeChatFormatting.swift`、`NativeAttachmentList`（`NativeMessageRows.swift:112-148`）
- `NativeMarkdownBody.swift`、`NativeMarkdownModel.swift`、`NativeCodeHighlighter.swift`、`Components.swift`（`DSSCodeBlock:153-228`）、`DSHComponents.swift`（`ShimmerText`、`DSHJsonBlock`）
- `NativeChangedFilesCard.swift`、`NativeConversationModels.swift`、`NativeTranscriptProjector.swift`
- `Sources/PhoneDSHAgentCore/DSH/DSHEventMapper.swift`、`examples/probe-app/PhoneDSHProbe/ChatModel.swift`
- 测试：`examples/probe-app/PhoneDSHSimTests/{NativeChatPresentationTests,NativeMarkdownTests}.swift`（共 8 个 test）
- 截图：`docs/receipts/ios-baseline-screens/{ios-chat-assistant,ios-code-block,ios-chat-official}.png`（1206×2622 @3x → 402×874pt）

用到的搜索（“没有”类结论的证据）：

```bash
# iOS: 官方文案零命中
grep -rn "系统提示词" examples/probe-app/PhoneDSHProbe/ Sources/            # 0
grep -rn "收到执行请求" examples/probe-app/PhoneDSHProbe/ Sources/          # 0
grep -rn "子任务状态更新" examples/probe-app/PhoneDSHProbe/ Sources/        # 0
grep -rn "后台任务状态更新" examples/probe-app/PhoneDSHProbe/ Sources/      # 0
grep -rn "未知 surface" examples/probe-app/PhoneDSHProbe/ Sources/          # 0
grep -rn "上下文已压缩" examples/probe-app/PhoneDSHProbe/ Sources/          # 0
grep -rn "本轮运行失败" examples/probe-app/PhoneDSHProbe/ Sources/          # 0
grep -rn "等待重试模型请求" examples/probe-app/PhoneDSHProbe/ Sources/      # 0
grep -rn "引用会话" examples/probe-app/PhoneDSHProbe/ Sources/              # 0
# iOS: 官方 node kind 零命中
grep -rn "turn-trigger\|turnTrigger" examples/probe-app/PhoneDSHProbe/ Sources/        # 0
grep -rn "question-reply\|questionReply" examples/probe-app/PhoneDSHProbe/ Sources/    # 0
grep -rn "manual-compaction\|command-input\|workflow-run\|submitted-plan" ...           # 0
```

## 2. 官方基线（按 surface 列）

`kind` 全部来自 `register-node-renderers.ts:40-89` 与各包 `ChatNodeDataMap` 声明；`tool-call`/`turn-process` 属 Axis 02/05，本轴只列位。

### 2.1 行类型清单与结构

| # | kind（注册点） | 结构 | 402pt 像素规格 | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|
| 1 | `user` / `steering`（`register-node-renderers.ts:40-43`） | `.userRow` flex column align-end gap 6 → `UserContent`（`.userStack` gap 8：附件行 / 气泡 / 引用摘要）+ `MessageIconActions` | 气泡 `max-width: min(0.702×--dsh-chat-content-width, 82%)` → 402pt 下 **277pt**；`padding:10px 16px`；`border-radius:20px`（`--dsw-radius-xl`）；`font:14/22`；`background:#EDF3FE`；`white-space:pre-wrap`；`word-break:break-word`（`MessageItem.module.css:3-40`） | 无标题；引用摘要 `引用会话 · {labels}`（`locale.ts:128`） | 动作行 hover 才现（`:has(~ user)` 规则，`MessageIconActions.module.css:42-61`）；触屏无 hover → 常显 | `user/message`、`agent/steering/message` |
| 2 | `context`（`:44-45`） | `DisclosureRow` 24pt 头 + 展开 141pt 代码壳 | 头：leading 16box+14glyph+`margin-right:6`、title `13/24`、sep 2×2 点 `margin:0 8px`、source `13/24`、summary `13/24` ellipsis（`DisclosureRow.module.css:36-105`、`ContextInjectionRow.module.css:18-48`）；正文：`margin:4px 0 0 22px`、`width:calc(100%-22px)`、`max-height:141px`、`padding:10px 16px 12px 12px`、`radius:12`、`bg:#F9FAFB`、`font:400 11/16 等宽`、`color:#81858C`（`:50-64`） | `上下文注入` / `跨会话召回` / `已添加工具：{name}` / `新增 {count} 个` / `工具已更新`（`locale.ts:126-129,118-125`） | 点击整行展开；跳变 chevron 只在 hover 出现（`DisclosureRow.module.css:84-98`）；form 6 种：instructions/catalog/snapshot/recall/relay/opaque（`ContextBody.tsx`） | `user/message`（`source.kind != 'user'` 且未被 inbox 认领为本轮唤醒）、`developer/message` |
| 3 | `turn-trigger`（`:46-47`） | 独立卡片：icon + title + time + chevron，展开 explanation + body | 卡 `border:0.5px #0000000a`、`radius:20`、`bg:#F9FAFB`、hover 变 `rgba(38,49,72,.06)`；header `padding:12px 16px` gap 10；icon 14；title 14；time `12/18` 右推；chevron 12（`TurnTriggerNodeView.module.css:1-31`）；body `padding:0 16px 12px 40px`、content `max-height:240 12/18 pre-wrap` | 10 种 title：`收到执行请求`/`继续执行目标`/`收到任务消息`/`收到团队消息`/`子任务状态更新`/`收到 GitHub 事件`/`收到外部事件`/`自动化任务`/`后台任务状态更新`/`插件状态更新`；展开横幅 `这条通知触发了本轮回复。`（`locale.ts:53-63`） | 点击展开；icon 按 source.kind 10 选 1（`turn-trigger.ts:15-26`） | **`user/message` 且 `source.kind != 'user'` 且被 inbox 认领为本轮唤醒**（`waking = nextTurn.currentClaimed.has(id) \|\| idleSteer`，`message.ts:75-92,125-129`） |
| 4 | `system-prompt`（`:48-49`） | `DisclosureRow` + 141pt 代码壳（与 context 同壳） | 行 24pt；title `13/24`；正文同 #2 但 `font:400 11/16`、`max-height:141px`（`SystemPromptRow.tsx:25-42`） | `系统提示词` / `系统提示词更新`（`locale.ts:116-117`） | 默认可见（首个 request、series start、system 变更时 `showsPrompt=true`，`request-prompt.ts:120-127`） | `system/message`、`request/header` |
| 5 | `assistant-step`（`:50-59`） | `AssistantMarkdown.root`（`font:14/24`）→ `.body` flex column **gap 16** → text / reasoning / image 块；`streaming` 时 `data-streaming`；interrupted 追加 `.stopped` | `.root{font-size:14px;line-height:24px}`；`.body{gap:16px}`；`.stopped{align-self:start;padding:0 6px;radius:8px;bg:rgba(38,49,72,.06);11/18;#81858C}`（`AssistantMarkdown.module.css:9-21,63-71`）；宽表 breakout `100cqw`（`:33-43`） | `已停止`（`message.stopped`） | running/settled/interrupted 三态共用同一实例（`AssistantNodeView.tsx:9-50`） | `assistant/message` |
| 6 | `command`（`:60-65`） | `DisclosureRow`，icon `IconApiOutlineRegular`，title=命令名，sep + summary（可多行时展开 `<pre>`） | 行 24pt、title `13/24`；summary `13/24` ellipsis；error 用 `#EC1313`；body `max-height:260`、`margin:4px 0 4px 4px`、`padding:12px 16px`、`border:0.5px`、`radius:16`、`bg:#F9FAFB`、`font:11/16`（`GenericCommandCard.module.css`） | `指令` / `执行中…` / `指令失败` / `已完成` / `运行中` / `失败`（`locale.ts:190-195`） | running 走 `TextShimmer`；`outcome===null` 才算 running（`GenericCommandCard.tsx:12-15`） | `command/run`、`command/done` |
| 7 | `manual-compaction`（`:66-67`） | 复用 `CompactionItem`，title 换成命令名 | 同 #8 | `compact`（`message.compaction.commandTitle`） | 与会话压缩事务合并且不重复（`CompactionCommandCard.tsx:13-25`） | `command/*` + `compaction/*` |
| 8 | `compaction`（`:68-69`） | 单行 24pt：leading（context icon ↔ chevron 互换）+ title + 2px 点 + summary；展开 body | `--dsh-compaction-header-height:24px`；title/summary `13/24`；点 2×2 `margin:0 8px`；body `padding:4px 0 4px 22px`、`13/24`、`#81858C`；**展开时 toggle sticky top 0、z-index 7、直角、底色 `bg-base`**（`MessageItem.module.css:53-196`） | `上下文已压缩` / `正在压缩…` / `已压缩 {items} 条历史记录（约 {tokens} tokens）` / `点击查看压缩摘要` / `压缩摘要不可用`（`locale.ts:140-145`） | 只有 `summary !== null` 可展开；不可展开时 button disabled（`CompactionItem.tsx:39,53`） | `compaction/summary`、`compaction/checkpoint` |
| 9 | `model-retry`（`:70-71`） | `<details>`：summary（TextShimmer 状态串）+ 折叠的 delay/failure 两行 | summary `inline-flex fit-content`、`padding:2px 0`、gap 7、其后 6×6 三角（`border-right/bottom:1.5px`，`rotate(-45deg)`，展开 `rotate(45deg)`，`transition:transform 120ms`）；文本 `13/20`；details `grid gap 2`、`margin-top:3`、`padding-left:14`、`13/18`；label `#61666B`（`MessageItem.module.css:198-270`） | 状态串 `{label}（{retry}/{maximum}） · {seconds}s`；`正在重试模型请求` / `模型请求重试已取消` / `已重试模型请求` / `等待重试模型请求`；明细 `重试延迟：` + `{n}毫秒`、`失败原因：`；`maximum` 在 `mode==='normal'` 时为 maxRetries 否则 `∞`（`MessageItem.tsx:63-128`） | 250ms 间隔倒计时，到 1s 停（`MessageItem.tsx:81-97`） | `llm/retry`、`llm/retry-started` |
| 10 | `turn-error`（`:72-73`） | `grid-template-columns:10px minmax(0,1fr) auto`，gap 8，`padding:2px 0` | StateDot 10box/6paint（`StateDot.module.css:1-15`）+ `margin-top:5px`；title `#EC1313` 600 `margin-right:6`；message `#61666B`；code `font:11/16 等宽 #81858C`；整体 `13/20`（`MessageItem.module.css:272-304`） | `本轮运行失败`；`任务已停止`（ACCOUNT_SIGNED_OUT/INTERRUPTED）；错误码映射 `API 密钥无效`/`当前请求的额度已用尽`/`任务已因退出 DeepSeek 登录而停止。`（`locale.ts:167-175`、`MessageItem.tsx:51-61,140`） | `code` 不是 INTERRUPTED 时右对齐显示；`role="status"` | `turn/end.reason.kind==='error'` |
| 11 | `turn-max-tokens`（`:74-75`） | 同 #10 网格，dot=warning | title `#F59E0B` 600；hint `#61666B`；`13/20`（`MessageItem.module.css:306-310`） | `已达到输出 token 上限` + `回答被截断，已有输出保留在对话中。发送“继续”可让模型接着输出。`（`locale.ts:173-175`） | 无操作按钮（靠输入“继续”） | `turn/end.reason.kind==='max-tokens'` |
| 12 | `turn-tail`（`:78-87`） | `.root` flex column **gap 16** → `conversation.chat.turnTail` list（deliverables/plan/schedule…）+ `MessageIconActions`（clock=end） | `.root{gap:16px}`；`.actions{margin-top:4px;margin-left:-6px}`（`TurnTailNodeView.module.css`）；动作行高 28、gap 8；复制/分支 glyph 17px、其余 15px | 见 #14 | 无 closing 时只渲染 slot；`data-actions-reveal='always'` 仅当本轮以回答结尾（`TurnTailNodeView.tsx:36-61`） | `turn/end` + `assistant/message` |
| 13 | `unknown`（`:88-89`） | `.contextRow`（`padding:2px 0`）内一个 `JsonBlock` | label 即 title；body 走 JsonBlock 折叠 | `未知 surface 事件：{type}`、`… 已截断，共 {total} 字符`（`locale.ts:147`） | 任何未被认领的 append 事件（`fallback.ts:19`） | 兜底 |
| 14 | `question-reply`（`ui-user-questions/src/client/question-reply.ts:38-43`） | 右对齐气泡（可点开答案明细）+ 时间/复制动作行 | `.row` align-end gap 6 `padding:4px 0`；`.bubble` **max-width:72%**、`padding:10px 16px`、`radius:20`、`bg:#EDF3FE`、`14/22`、`white-space:pre-wrap`（`QuestionReplyView.module.css:1-20`） | `回答先前等待中的问题` / `展开问题详情` / `收起问题详情` / `回答：` / `已跳过` | 气泡即 toggle，`role="group"`；时间 `HH:mm` | `user-question/answered`（迟到回答） |
| 15 | `workflow-run`（`ui-workflow-run`）/ `submitted-plan`（`ui-plan`）/ `command-input`（`ui-goal`） | 独立 chat node（workflow：成员与进度卡；submitted-plan：`ui-plan` 的 node 定义 + turn-tail `PlanCards` 卡） | PlanCards 卡：icon 20 + title + `preview.document` + `preview.action`（`PlanCard.tsx:41-58`） | `计划待审` / `同意执行` / `拒绝` / `要求修改`（`ui-user-questions/locales.ts:32-35`） | 点击开右侧栏 | `tool/ptc-dispatch`、workflow 事件 |

### 2.2 消息动作（`MessageIconActions`）

| 项 | 规格 | 出处 |
|---|---|---|
| 行容器 | `display:flex; align-items:center; gap:8px; height:28px` | `MessageIconActions.module.css:5-10` |
| 按钮 | `28×28`、`padding:6px`、`radius:8`、`color:#81858C`、hover `bg rgba(38,49,72,.06)` + `#61666B` | `:63-92` |
| glyph | 15px；`clock='end'` 时 17px | `:79-87` |
| 顺序（user） | `time`（`13/24 #81858C` `padding-right:12`）→ copy → extraActions → branch | `MessageIconActions.tsx:82-113` |
| 顺序（assistant/tail） | copy → extraActions（👍👎 + 失败提示）→ branch → usageAction → time（`12/24`） | `:110-112`；`TurnTailNodeView.tsx:64-78` |
| copy 反馈 | 图标切 check，1000ms 复原；tooltip `复制` → `复制成功` | `:62-76`；`locale/zh.ts:6-7` |
| branch | `aria-disabled` + `opacity:.4` + tooltip `仅可从已完成轮次的最后一条消息分支`；文案 `在新对话中分支` | `MessageItem…`→`MessageIconActions.tsx:91-109`；`locale.ts:158-159` |
| 点赞/点踩 | `好的回答` / `有问题的回答`（选中 = 实心 icon + `data-active`）；点击**打开反馈 dialog**（分类 + 详情），再提交 | `ui-message-feedback/src/client/{locales.ts:5-8,MessageFeedbackActions.tsx:95-133}` |

### 2.3 turn-tail 内容与用量

| 项 | 规格 | 出处 |
|---|---|---|
| 用量 pill | icon `IconDatabaseOutlineRegular` 15 + label `用量 {total}`，`height:28`、`padding:6px 8px`、`radius:8`、`13-1=12px/24`、`tabular-nums`、`#81858C` | `TurnUsagePanel.module.css:17-47` |
| **≤480px 特化** | pill 收敛成 **28×28 纯图标**、`padding:6px`、label `display:none`、相邻 pill `margin-left:0` | `TurnUsagePanel.module.css:59-73` |
| 数字格式 | `<1000` 原样；`<1e6` `{x}K`；≥1e6 `{x}M`；`x>=100` 取整否则一位小数（`formatTokens`）；精确值用 `,` 分组 | `token-format.ts:9-30`；`locale/zh.ts:42-43` |
| 弹层 | `position:fixed` 锚定触发器的 popover：`padding:16`、`radius:16`、`bg --dsw-specific-menu` + `backdrop-filter blur(40px) saturate(150%)`、`elevation-prominent`、`12/18 #61666B`、`min-width:min(300,100vw-24)`、`z-index:1100` | `stat-dialog.module.css:10-31` |
| 弹层内容 | 标题行（icon+`本轮用量` + 精确 total）、0.5px 分隔线、`dl`：`提供方 / 模型`、`缓存命中`、`未缓存输入`、`缓存读取`、`缓存写入`、`输出`（+`（其中推理 {tokens}）`） | `TurnUsagePanel.tsx:60-104`；`locale.ts:177-186` |
| tail 其余 slot | `ui-deliverables`（改动文件卡）、`ui-plan`（计划卡）、`ui-schedule`（定时任务卡） | `web-app/cordis.patch.yml:352,451,398` |

### 2.4 改动文件卡（deliverables，turn-tail 贡献）

| 项 | 规格 | 出处 |
|---|---|---|
| 卡 | `margin-top:4`、`border:0.5px --dsw-alias-border-l2`、`radius:16`、`bg --dsw-alias-bg-layer-1` | `ChangedFiles.module.css:2` |
| header | `height:60`、`padding:8px 10px`、gap 10、bg `neutral-50`（hover `neutral-100`）、`transition:background-color 120ms` | `:5-9` |
| tile | 40×40、`border:0.5px l1`、`radius:10`、`bg color-mix(neutral-00 50%, transparent)` | `:10` |
| title | `13/20` **500** ellipsis | `:13` |
| stat | `10/16` `#81858C`、counts 等宽 `gap:6`、`+{n}` `#22C55E`、`-{n}` `#EC1313`、千分位 `Intl` | `:14-21`；`ChangedFiles.tsx:20-28` |
| hover | counts 换成 `presented.preview` 提示（无 hover 设备不显示） | `:16-18` |
| 文件行 | `padding:7px 18px 7px 14px`、`min-height:24`（`pointer:coarse` → **44**）、path 12px 无衬线、counts 11/18 等宽 | `:23-32` |
| 折叠 | `>4` 行折叠，按钮 `padding:10px 18px 10px 14px`、12/18、gap 4、icon 14 | `:29-31` |

### 2.5 Markdown / 代码（renderer 与 primitives）

| 项 | 官方规格（402pt 生效值） | 出处 |
|---|---|---|
| 正文 | `14/24`，`overflow-wrap:anywhere`，`margin:16px 0` 段落；首尾块 margin 归零 | `MarkdownText.module.css:5-10,45-47,277-285` |
| 标题 | h1 `21/30 700`、h2 `19/28 700`、h3 `18/26 700`、h4 `14/24 600`；**h1–h3 margin `32px 0 16px`**，h4 `16px 0`；h5/h6 = base-strong `14/24 600` `16px 0` | `:16-43`；`gradient-shadow-text.css:65-105` |
| 链接 | `#4176E6`、weight 500、无下划线；hover/focus 才 `underline dotted` + `underline-offset:3px`；3px 透明边框 + 负 margin 扩热区；前置 `linkIcon` 1.1em | `:58-100` |
| 行内代码 | `font:12/19 等宽` 后再 `font-size:.875em !important` → **≈10.5px**；`bg #FAFAFA`；`border:0.5px --dsw-alias-border-l1`；`radius:8`；`padding:0 5px`；`inline-flex` | `:163-174`；`gradient-shadow-text.css:163-168` |
| 列表 | `margin:16px 0`、`padding-left:18`；项间 `margin-top:6`；嵌套 `margin-top:4`；marker `line-height:24` `#61666B`；task list 用真 checkbox `margin:0 8px 0 0` + `accent-color` | `:102-190` |
| 引用 | `border-left:2px solid #ADB2B8`、`margin:16px 0 0`、`padding-left:14` | `:151-155` |
| 分割线 | `height:0.5px`、`margin:32px 0`、`background --dsw-alias-border-l2` | `:143-149` |
| 表格 | th `13/22 500`、td `13/22 400`、`padding:10px 16px`、首列 `padding-left:0`、末列 `padding-right:0`、th 下框 `0.5px l3`、td 下框 `0.5px l2`、`max-width:min(30vw,320)`、`min-width:100`；**<4 列铺满 100% 自动换行；≥4 列自然宽 + hover 才出横向滚动条**（`.md-table-wide`）；表头**无底色** | `:192-275`；`render.tsx:475-500` |
| 代码块（正文 fence，`toolbarLabels` 分支） | 卡 `margin:16px 0`、`radius:16`、`bg:#F9FAFB`；header `padding:10px 18px 8px 22px`、gap 12、`11/18` 无衬线、语言名等宽 `#81858C`；动作按钮 **24×24**、gap 4、icon 14（换行 + 复制）；`pre` **`padding:6px 22px 20px`**、`font:11/19 等宽`、默认 `white-space:pre-wrap` + `overflow-wrap:anywhere`，取消换行时 `white-space:pre` + `overflow-x:auto`；**无高度上限、无行号**（`lineNumbers` 默认 false） | `CodeBlock.module.css:4-121`；`CodeCard.module.css:10-82`；`CodeToolbar.tsx:38-59` |
| 数学 | katex；流式不过 math 语法（`$` 保持段落），settled 才 TeX；`katex-display` 横向可滚 | `parse.ts:22-45`；`render.tsx:390-393` |
| 脚注 | 编号 `<sup>` 1..N（按首次引用顺序）；文末 section 用 `markdown.footnotes`=`脚注` | `render.tsx:700-712`；`locale/zh.ts:40` |
| 图片 | 正文图 `ImagePreview`：`frame` 180 高、`radius:8`、`bg bg-base`、loading/failed status `12/18`；点击由上层开 `ImageLightbox` | `ImagePreview.module.css:1-24` |
| 宽表 breakout | `.md-table-wide` 在 `.body` 内用 `100cqw` 溢出到 transcript 全宽、`padding-left` 补偿 | `AssistantMarkdown.module.css:33-51` |
| 流式 | 无 caret；未闭合 fence 用 `StreamingHighlightSession` 增量高亮；reasoning 标题走 `TextShimmer`（1.5s / delay .3s / `steps(48,end)` / 105° 遮罩 40–60%） | `CodeBlock.tsx:97-149`；`TextShimmer.module.css:34-77` |

### 2.6 手机宽度（<640px）结论

`ui-mobile/src/client/mobile.module.css` 只改外壳：安全区、`100dvh`、工具栏、composer 固定、输入 16px、tooltip 关闭。**transcript 的行距、气泡、行内边距没有任何手机特化** —— 所以 402pt 下官方 transcript 就是用 `ChatView.module.css:28` 的 `padding:16px calc(16px+16px)`，即 **左右各 32pt，内容宽 338pt**（`.column` 的 `max-width:680px` 在 402pt 下不生效）。唯一与 402 直接相关的组件级特化是 `TurnUsagePanel` 的 `@media (max-width:480px)` 纯图标化。

## 3. iOS 现状（按 surface 列）

### 3.1 `ChatItem.Kind` 与官方 kind 的映射矩阵

| 官方 kind | iOS `ChatItem.Kind` | iOS 渲染 | 缺口类型 |
|---|---|---|---|
| `user` | `.user` | 右对齐气泡 + 附件列表 + 动作行（`ChatPage.swift:2258-2266,2331-2345`） | 有但像素不符 |
| `steering` | `.user`（title 仅用于导出） | 与 user 完全相同，无任何标记（`NativeTranscriptProjector.swift:27-29`） | 无区分 |
| `context` | `.context` | `NativeContextSourceGroup` 把**连续多条合成一行**“上下文 · N 条”（`NativeChatTimelineChrome.swift:22-65`） | 结构被改写 |
| `developer/message` | — | 无（`message.ts:139-152` 官方把它也渲染成 context 行；iOS 投影无此分支） | **完全缺失** |
| `turn-trigger` | — | 无 | **完全缺失** |
| `system-prompt` | — | 无（`system/message` 只进调试 ledger，`ChatModel.swift:1580`） | **完全缺失** |
| `assistant-step` | `.assistant` | `NativeMarkdownBody` + 可选改动文件卡 + 动作行（`ChatPage.swift:2267-2275,2289-2312`） | 有但像素不符 |
| `reasoning` | `.reasoning` | `NativeThinkingRow`（`NativeMessageRows.swift:57-85`） | 位置/间距不符 |
| `command` / `manual-compaction` | — | 无（slash 命令结果只弹 `CommandExecutionResultPage` sheet，`ChatPage.swift:2734+`） | **完全缺失** |
| `compaction` | `.systemEvent` | 6pt 圆点 + 13 medium 标题 + 12 正文，不可展开（`NativeMessageRows.swift:87-110`） | 结构坍缩 |
| `model-retry` | `.systemEvent` | 同上，单行文本（`NativeTranscriptProjector.swift:131-137`） | 结构坍缩 |
| `turn-error` | `.turnError` | 同上，红点 + 标题 + 正文 | 颜色/字重/文案错 |
| `turn-max-tokens` | `.maxTokens` | 同上，橙点 + 标题 + 正文 | 颜色/字重/字号错 |
| `turn-tail` | 附着在 closing assistant 上 | `NativeChangedFilesCard` + `NativeMessageActions`（`ChatPage.swift:2301-2309`） | 有但缺 slot 体系 |
| `unknown` | `.unknown`（仅未知 assistant block） | `DSHJsonBlock(text:)`，无 label（`ChatPage.swift:2282-2283`） | 语义不同 |
| `question-reply` | — | 无（回答后气泡消失） | **完全缺失** |
| `workflow-run` / `submitted-plan` / `command-input` | — | 无 | **完全缺失** |

### 3.2 逐 surface 现状与差值

| # | Surface | iOS 实现 | 现在画成什么 | 行为 | 与官方的差 |
|---|---|---|---|---|---|
| 1 | 用户气泡 | `ChatPage.swift:2331-2345` | `Text` + `lineSpacing(7)`、`padding(12)`、`RoundedRectangle(22, continuous)`、`--selector #F2F3F5`、`frame(maxWidth:296)`、`ViewThatFits` 先试单行 | 不可点、可选中 | 底色（蓝→灰）、radius 22 vs 20、padding 12 vs 10/16、行高 24 vs 22、max 296 vs 277、**内容宽 370 vs 338** |
| 2 | 用户动作行 | `NativeMessageActions.swift:15-69` | `HStack(spacing:8)` 后接 `Spacer()` → **左对齐**；copy / 👍👎 / branch / **share** / usage / clock | 常显（无 hover 概念） | 对齐方向、多出 ShareLink、缺 hover reveal、copy 图标 17 vs 15、glyph 无 28 命中框一致（有 28 frame 但仅 copy） |
| 3 | assistant 正文 | `NativeMarkdownBody.swift:26-42` | `VStack(spacing:16)` + 每个 block | 可选中 | `font 14` 无 24 行高；段落无 16 上下 margin（靠 stack gap 近似）；块首尾不归零 |
| 4 | 流式指示 | `ChatPage.swift:2291` | 行首 `ProgressView().controlSize(.mini)` | — | 官方行内无任何 spinner（只有 flow 末尾 `RunningStatus`） |
| 5 | reasoning | `NativeMessageRows.swift:15-55,77-84` | 24pt 行：icon/chevron 16box+6 + `思考` 13 + 2px 点 + shimmer 摘要；展开 body `padding(.leading,22).vertical 4`、`.compact` 变体 | 点击展开，0.16s easeOut | 结构基本对；行内没有 `data-streaming` 的 48px 渐隐；shimmer 1.5s 线性无 0.3s delay、无 `steps(48)` |
| 6 | context 行 | `ChatPage.swift:2363-2411`；`NativeChatTimelineChrome.swift:22-102` | **聚合行**：`square.stack.3d.up` + `上下文` + `· N 条` + 单一来源名，28pt 高；展开后每条：箭头 + 中文来源名 + 44pt 复制按钮 + 13/20 正文（无底色） | DisclosureGroup | 行高 28 vs 24；**官方逐条一行、iOS 聚合**；icon 不同；缺 sep 点、producer label 段、141pt/22 缩进/11-16 等宽代码壳；官方把未知 producer 的 durable `kind` 原样显示（`event-projection.ts:71-75`），iOS 用 `NativeSourceName.chinese` 白名单过滤后隐藏（`NativeChatTimelineChrome.swift:103-114`），策略相反 |
| 7 | 压缩行 | `NativeMessageRows.swift:87-110` | 6pt 圆点 + `上下文已整理` 13 medium + 摘要 12 | 不可展开 | 文案错（官方 `上下文已压缩`）；无 icon 互换、无 2px 点、无 24pt 行、无展开摘要 + sticky toggle |
| 8 | 重试行 | `NativeMessageRows.swift:87-110` | `模型请求重试` + 失败原因单行 | 不可展开、无倒计时 | 缺 `（{retry}/{max}） · {n}s`、`∞`、delay 行、`TextShimmer`、chevron |
| 9 | 错误行 | `NativeMessageRows.swift:87-110` | 6pt 红点（`#C0392B`）+ `本轮执行失败` 13 medium + 12 正文 | — | 文案错（`本轮运行失败`）、色 `#C0392B` vs `#EC1313`、title 应 600、无 code chip、dot 无 10px 槽、dot 基线对齐怪 |
| 10 | max-token 行 | 同上 | 橙点 + `已达到输出 token 上限` + 12 正文（secondary，非 warn） | — | 标题应 `#F59E0B` 600、正文应 13/20、官方 dot 用 warning 语义 |
| 11 | 未知块 | `ChatPage.swift:2282` | `DSHJsonBlock(text:)` 直接摊 JSON | 可展开 | 缺 `未知 surface 事件：{type}` label；`unknown-surface` 事件根本不到 UI |
| 12 | 动作行（assistant） | `ChatPage.swift:2305-2308` → `NativeMessageActions` | copy + 👍👎 + usage + clock，无 branch（`onBranch` 未传） | — | 缺 branch（官方按 `session/fork` 权限给）、文案 `有用/没用` vs `好的回答/有问题的回答`、反馈直接 `rateMessage` 不走 dialog、usage 文案多 ` tok`、时钟非 `tabular-nums` |
| 13 | 用量弹层 | `NativeMessageActions.swift:66-92` | `.sheet` + `NavigationStack` + `List` + `LabeledContent`，`.medium` detent | sheet | 官方是锚定 popover（16px padding / radius 16 / menu 材质 / 12-18）；字段名 iOS `其中推理` vs 官方 `（其中推理 {tokens}）`；缺 `提供方 / 模型` 行 |
| 14 | 改动文件卡 | `NativeChangedFilesCard.swift` | 60 高 header + 40 tile + 13 medium 标题 + 10 号等宽 `+n/-n` + 4 行折叠 | 点开工作台 | radius 12 vs 16；counts 无千分位；缺 hover 预览提示；`tile` 底/描边色取 `input`/`border` 而非 `neutral-50`/`l1` |
| 15 | 加载更早 | `ChatPage.swift:732-749` | `.buttonStyle(.bordered)` + `加载更早消息` + 44 高 | — | 官方 `加载更早`、12px、`radius 8`、`padding 4px 12px`、`bg interactive-bg-hover-solid`、居中 |
| 16 | 历史加载失败 | `ChatPage.swift:750-757` | 橙色 `Label` + 橙底圆角 12 | — | 官方 `chat.loadError` = `历史加载失败：{message}（{code}）`，13/18 `#EC1313`，无底色 |

### 3.3 Markdown 支持矩阵（iOS vs 官方）

| 能力 | 官方 | iOS | 判定 |
|---|---|---|---|
| 段落/粗斜/删除线 | GFM + `cjkFriendlyStrong` | 有（`NativeMarkdownModel.swift:198-219`） | 一致（iOS 无 cjk 友好加粗规则） |
| 标题 h1–h6 | 21/19/18/14 + 32/16 margin | 24/22/20/17/14，**无 margin**（`NativeMarkdownBody.swift:128-137`） | 有但不一致 |
| 有序/无序/任务列表 | 18 indent、marker `#61666B`、真 checkbox | 12 indent（`padding(.leading,4)` + gap 8）、`•`/`1.` 文本、`checkmark.square.fill` | 有但不一致 |
| 嵌套列表 | 4px 顶距 | 同间距递归 | 基本一致 |
| 表格 | th 500、无底色、<4 列铺满换行、首末列 padding 归零、宽表 hover 滚动 | th 600、**header 加 `#F2F3F5` 底色**、强制横滚、cell `minWidth 100 maxWidth 320`（`NativeMarkdownBody.swift:140-164`） | 有但不一致 |
| 引用 | 2px、14 缩进、`margin:16px 0 0` | 2px、14 缩进、间距 12 | 基本一致 |
| 分割线 | `0.5×32/0` | `0.5` + `padding(.vertical,16)` | 差 16pt |
| 行内代码 | 10.5px、0.5 边框、radius 8、padding 0 5 | 12.25 号、无边框/圆角/padding、`#F0F0F3`（`NativeMarkdownBody.swift:202-213`） | 有但不一致 |
| 链接 | `#4176E6` 500 + 透明 3px 热区 + hover 虚线 | `#3964FE` 500 + `underlineStyle:.single` **常显下划线** | 有但不一致 |
| 代码块 | 见 2.5 | `DSSCodeBlock`（`Components.swift:153-228`） | 有但不一致 |
| 数学 | katex 行内+块级 | SwiftMath：块级 `MTMathUILabel`、行内渲染成图片（`NativeMarkdownBody.swift:116-119,263-283`） | 有但不一致 |
| 脚注 | `<sup>` 数字 + 文末 `脚注` section | `[id]` 上标 9 号 + 硬编码“脚注”段（`NativeMarkdownModel.swift:51-59`） | 有但不一致 |
| 图片 | `ImagePreview` + Lightbox | `AsyncImage` + sheet（`NativeMarkdownBody.swift:285-341`） | 有但不一致 |
| 原始 HTML | 白名单外渲染为文本 | `Text(value)` 文本 | 一致 |
| Mermaid | 无 | 无 | 一致 |
| 流式未闭合 fence | 增量高亮、无 caret | 每 chunk `NativeMarkdownParser.parse` 全量重解析，无 caret | 行为一致、性能不同 |
| 宽表 breakout | `100cqw` 溢出 | 无（`ScrollView(.horizontal)` 内滚动） | 缺失 |

## 4. 差距清单（核心交付）

> 像素合同均按 402pt。`—` 表示该项不依赖新数据。P0 = 2，P1 = 12，P2 = 14。

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
|---|---|---|---|---|---|---|---|---|---|
| C-01 | P0 | 图片被画成文件 chip，无缩略图网格与 lightbox | `AssistantMarkdown.tsx:108-130`（assistant 图 → `conversation.chat.message.images`，`align:'start'`）；`UserContent.tsx:23-46`（user 图 → `conversation.chat.user.images`，`align:'end'`，`compact = count>1`）；`MessageImage.tsx:31-48,155-177`；`MessageImage.module.css:1-45` | `ChatPage.swift:2264`（user 附件 → `NativeAttachmentList`）；`2278-2279`（`.image` → `NativeAttachmentList`）；`NativeMessageRows.swift:112-148` | 用户发的图、模型产出的图**都只显示文件名**；没有“查看原图”入口 | 容器 `display:flex; flex-wrap:wrap; gap:10px; max-width:100%`；**多图 = 64×64 + 64×64 网格 tile**，`radius:20`、`border:0.5px l2-thin`、`object-fit:cover`；**单图**长边 240pt、比例夹 [0.25,4]、`object-fit:cover`、极端比例 `object-position:center top` / `left center`；失败态 `max-width:240`+`padding:10px 12px`+`radius:12`+点击重试；loading `12/18 #81858C`；点击开 lightbox，`aria-label="{label}，点击查看原图"`；文件 chip 为 **240pt 定宽**、`min-height:64`、`padding:8px 12px`、`gap:10`、`radius:16`、name `14/22 500`、meta `12/15 #81858C` | `ChatItem.attachments` 已有（`NativeMessageAttachment.payload`），缺授权图片 loader | 新建 `NativeMessageImageGrid`（single/tile 两分支）+ `NativeImageLightbox`；`.image` 与 user 附件行改走它；文件 chip 收成 240 宽 | 快照：单图/两图/四图/失败图；断言 `singleFit` 的夹取与不放大；对照官方 gallery |
| C-02 | P0 | 非人类输入触发行（turn-trigger）完全缺失 | `register-node-renderers.ts:46-47`；`TurnTriggerNodeView.tsx:29-48`；`TurnTriggerNodeView.module.css:1-31`；`turn-trigger.ts:21-70`；`message.ts:34-35,75-92,125-129`（`waking` 判定） | `grep -rn "turn-trigger\|turnTrigger" examples/probe-app/PhoneDSHProbe/ Sources/` → **0**；`NativeTranscriptProjector.swift:144-145` `default: continue`；非 `user` 来源的 `user/message` 一律被判成 `.context`（`DSHMessageSourceClassifier.swift:15-21`） | 定时任务/子 Agent/goal/webhook 唤醒的轮次，被折叠成一条灰色“上下文”行，看不出是谁触发的 | 卡：`border:0.5px rgba(0,0,0,.04)`、`radius:20`、`bg:#F9FAFB`、hover `rgba(38,49,72,.06)`、`transition:background-color 100ms`；header `padding:12px 16px`、`gap:10`、icon 14、title 14、time `12/18` `margin-left:auto`、chevron 12（展开 rotate 180）；body `padding:0 16px 12px 40px`；explanation `margin:8px 0`、`12/18 #61666B`；content `max-height:240`、`12/18`、`pre-wrap`、`overflow-wrap:anywhere`；10 种 title/icon 映射；`aria-expanded`+`aria-controls` | `user/message.source` 全量（现仅取 `source.kind` 字符串，`DSHEventMapper.swift:126-129`）+ inbox claim 关系（现整条丢弃） | 新增 `ChatItem.Kind.turnTrigger(source:)`；先判 `waking` 再决定 turnTrigger / context | 10 种 `source.kind` fixture 断言 title/icon；卡高 12+18+12+1≈43pt |
| C-03 | P1 | 用户气泡色相、尺寸、圆角全偏 | `MessageItem.module.css:3-40` | `ChatPage.swift:2331-2345` | 官方是浅蓝气泡、277pt 宽、行高 22；iOS 是中性灰、296pt、行高 24 —— 一屏之内最容易被认出的差异 | `padding:10px 16px`；`border-radius:20`（`--dsw-radius-xl`）；`font:14/22`；`bg:#EDF3FE`（dark `#2C2C2E`）；`color:#0F1115`；`max-width:277`（`min(0.702×338,82%)`）；`white-space:pre-wrap`；`word-break:break-word`；单行高 42pt | — | 改 `userBubble`：`lineSpacing(22-17)`、`padding(.vertical,10).padding(.horizontal,16)`、`cornerRadius 20`、`maxWidth 277`、底色换新 token | 同 prompt 快照与官方并排；量单行高 42、两行 64 |
| C-04 | P1 | assistant 正文缺 24pt 行高，整页密度偏紧 | `AssistantMarkdown.module.css:9-21`；`MarkdownText.module.css:5-10,45-47,277-285` | `NativeMarkdownBody.swift:26-42,57-62` | 官方 14/24，iOS 用 `.system(size:14)` 的自然行高（≈17），**每行少 7pt**；10 行回答少 70pt，长回答整页节奏全变 | `font-size:14`、`line-height:24`；块间 `gap:16`；段落 `margin:16px 0` 且首块 `margin-top:0`、末块 `margin-bottom:0`；`overflow-wrap:anywhere` | — | 正文与段落统一加 `lineSpacing(24-17)`；块 gap 保 16；补首尾归零 | 10 行文本量高度 = 240pt；与 `ios-chat-assistant.png` 对比 |
| C-05 | P1 | transcript 内边距与行距不匹配官方宽度轴 | `ChatView.module.css:22-34`（`padding:16px calc(clearance+16)`）、`:68-84`（`--dsh-chat-flow-gap` 6 / response 12）、`:116-121`（turn-process 16）；`ConversationRoot.module.css:384-395`（`--dsh-chat-content-width: clamp(680px, 0.64×W, 920px)`、`--dsh-composer-side-clearance:16`） | `ChatPage.swift:799`（`.padding(.horizontal,16)`）、`:800`（`.padding(.top,22)`）、`:422-443`（12 同kind / 20 异kind / 8 工具 / 8 上下文 / 6 状态） | 官方正文列 338pt、iOS 370pt（**宽 32pt**）；行距官方 6/12/16，iOS 12/20/8 —— 同一段对话在 iOS 上明显更“松”且更宽 | 左右各 32pt（内容 338，扣除滚动条 2pt 为 336）；顶部 16pt；行距 **6**（默认）/ **12**（`groupPart=response`）/ **16**（`turn-process`）；底部留 `--dsh-composer-height` | — | 改 transcript padding 为 32/16；把 `spacing(before:in:)` 改为按“是否 response 组 / 是否 turn-process”判定 | 量 402pt 下正文列宽 338；量 user→assistant 间距 12 |
| C-06 | P1 | 代码块 banner、控件、字体、折叠全不符 | `CodeCard.module.css:1-82`；`CodeBlock.module.css:4-121`；`CodeToolbar.tsx:38-59` | `Components.swift:153-228`；`NativeCodeHighlighter.attributed` | banner 底色比正文深一档（`#E9E9ED` vs 官方同色）、语言名 11pt 但色不对、右侧是“复制”文字 + 换行按钮、长代码多出一个官方没有的“展开全部 N 行” | 卡 `margin:16px 0`、`radius:16`、`bg:#F9FAFB`；header `padding:10px 18px 8px 22px`、`gap:12`、`font:11px/18px` 无衬线、语言名 `font-family:code`、`color:#81858C`；按钮 **24×24**、`gap:4`、icon 14、`radius:8`、hover `rgba(38,49,72,.06)`；`pre` **`padding:6px 22px 20px`**、`font:11px/19px 等宽`、默认 `white-space:pre-wrap`+`overflow-wrap:anywhere`，取消换行时 `white-space:pre`+`overflow-x:auto`；**无高度上限、无行号、无展开控件**；复制只有图标，tooltip `复制`→`复制成功`（1000ms） | — | 重写 `DSSCodeBlock`；banner 与 body 同底色；文案改 tooltip | 快照：短代码/长代码/取消换行/复制成功态 |
| C-07 | P1 | 标题阶梯字号与上下留白不符 | `MarkdownText.module.css:16-43`；`gradient-shadow-text.css:65-105` | `NativeMarkdownBody.swift:128-137` | iOS 标题偏大 3–6pt 且**完全没有上下 margin**，标题与小节之间贴在一起 | h1 `21/30 700`、h2 `19/28 700`、h3 `18/26 700`、h4 `14/24 600`、h5/h6 `14/24 600`；h1–h3 `margin:32px 0 16px`；h4–h6 `margin:16px 0`；h4–h6 后接列表时 8px | — | 改 `headingFont`；块模型补 `marginTop/marginBottom` | 快照 h1–h6 连续块 |
| C-08 | P1 | 消息动作行左对齐、多出分享、缺分支 | `MessageIconActions.tsx:45-114`；`MessageIconActions.module.css:5-103`；`locale.ts:158-159` | `NativeMessageActions.swift:15-69`；`ChatPage.swift:2305-2308`（`onBranch` 未传） | iOS 动作行整体靠左（官方右对齐贴气泡），多一个系统分享按钮，assistant 行没有“在新对话中分支” | 行 `height:28`、`gap:8`；按钮 `28×28`、`padding:6`、`radius:8`、`#81858C`，hover `bg rgba(38,49,72,.06)`+`#61666B`；glyph 15（`clock='end'` 时 17）；user 顺序 `时钟 → 复制 → 反馈 → 分支`，assistant 顺序 `复制 → 反馈 → 分支 → 用量 → 时钟`；user 时钟 `13/24` `padding-right:12`，assistant 时钟 `12/24`；分支不可用时 `opacity:.4`+`aria-disabled` | `session/fork` 权限 | 动作行加 `.frame(maxWidth:.infinity, alignment:.trailing)`；删 ShareLink；补 branch；文案按 locale | 单行/多行/权限关闭三种态快照 |
| C-09 | P1 | context 注入行被聚合、结构与像素全偏 | `ContextInjectionRow.tsx:50-92`；`ContextInjectionRow.module.css:1-64`；`DisclosureRow.module.css:36-105`；`event-projection.ts:60-76`（未知 producer 照显 `kind`） | `NativeChatTimelineChrome.swift:22-65`（聚合）、`ChatPage.swift:2363-2411`（单条）、`NativeChatTimelineChrome.swift:103-114`（白名单洗掉未知名） | 官方一行一条 24pt 细体；iOS 合成一行“上下文 · N 条”28pt，宿主名被换成中文或直接隐藏 | 行 24pt；leading 16box + 14 glyph + `margin-right:6`；title `13/24`；sep 2×2 `margin:0 8px #ADB2B8`；producer `13/24` ellipsis（`session-reference`→引用标签、`agent-instructions`→文件路径、`skill-invocation`→技能名、其余按 durable `kind` 原样）；summary 同上；展开 body `margin:4px 0 0 22px`、`width:calc(100%-22px)`、`max-height:141px`、`padding:10px 16px 12px 12px`、`radius:12`、`bg:#F9FAFB`、`font:400 11/16 等宽`、`#81858C`；hover 时 icon 换 chevron；`data-open` 时 `padding-bottom:4` | `user/message.source.{kind,label,form}`；`developer/message` 同用此行 | 取消聚合；新增 `NativeContextRow`；producer 三段特例 + 原样兜底 | fixture：6 种 form + 未知 kind + 无 label |
| C-10 | P1 | 系统提示词行缺失 | `register-node-renderers.ts:48-49`；`SystemPromptRow.tsx:25-42`；`request-prompt.ts:120-144`（默认 `showsPrompt`）；`locale.ts:116-117` | `grep -rn "系统提示词"` → 0；`ChatModel.swift:1580` 只进调试 ledger；transcript 丢弃 | 官方每个“首个请求 / 系列起点 / system 变更”都有折叠卡，iOS 一条都没有 | 与 context 同壳：行 24pt；`IconBrowseOutlineRegular` 14；title `系统提示词`（更新时 `系统提示词更新`）`13/24 #81858C`；展开 `max-height:141`、`11/16 等宽`、`#81858C`、`bg:#F9FAFB`、`radius:12` | `system/message`（records 已含） | projector 新增分支；抽共享 `NativeCodeShellBody` 供 context/system-prompt/command 复用 | fixture：两条 system/message → 第二行 title 为“更新” |
| C-11 | P1 | 命令执行结果行缺失 | `register-node-renderers.ts:60-65`；`GenericCommandCard.tsx:29-74`；`GenericCommandCard.module.css:1-49`；`locale.ts:190-195` | `grep -rn "command-input\|manual-compaction"` → 0；slash 命令只弹 sheet（`ChatPage.swift:2734+`），transcript 无记录 | 执行 `/plan`、`/compact` 等命令后，官方在消息流留下可展开命令卡，iOS 只在历史里留空 | 行 24pt：`IconApiOutlineRegular` 14 + 命令名 `13/24` + sep 2×2 `margin:0 8px` + summary `13/24` ellipsis；error 文字 `#EC1313`；running 走 TextShimmer；展开 `<pre>` `max-height:260`、`margin:4px 0 4px 4px`、`padding:12px 16px`、`border:0.5px l1`、`radius:16`、`bg:#F9FAFB`、`font:11/16`、`pre-wrap` | `command/run`、`command/done`（records 已含，`ChatModel.swift:1592` 已读） | projector 新增 command 行，outcome 取 `command/done` | fixture：running / ok / error / 多行 |
| C-12 | P1 | 压缩行坍缩为普通事件行，文案也错 | `CompactionItem.tsx:31-75`；`MessageItem.module.css:53-196`；`locale.ts:140-145` | `NativeTranscriptProjector.swift:138-143`（`title: "上下文已整理"`）；`NativeMessageRows.swift:87-110` | 官方是 24pt 细行 + 可展开摘要；iOS 是两行文本块，文案 `上下文已整理` ≠ 官方 `上下文已压缩`，也没有“已压缩 N 条历史记录” | `padding:2px 0`；button `height:24`；leading 16×16+14 glyph+`margin-right:6`（context icon ↔ chevron，仅 hover 换）；title `上下文已压缩` `13/24`；sep 2×2 `margin:0 8px #ADB2B8`；summary `已压缩 {items} 条历史记录（约 {tokens} tokens）` `13/24` ellipsis；body `padding:4px 0 4px 22px`、`13/24`、`#81858C`；展开时 toggle `sticky top:0 z-index:7`、直角、`bg:bg-base`；无摘要时 `disabled` | `compaction/summary` 的 `shadowedItemCount`/`shadowedTokenCount`（现只读 `summary` 字符串） | 新增 `.compaction` 行；改文案；sticky 用 `pinnedViews` 或自绘 | 三态 fixture：有计数 / 无计数 / 无摘要；sticky 快照 |
| C-13 | P1 | 重试链坍缩为单行事件，无倒计时/次数/上限 | `MessageItem.tsx:63-129`；`MessageItem.module.css:198-270`；`retry.ts:10-21`；`locale.ts:160-166` | `NativeTranscriptProjector.swift:131-137`（`模型请求重试`）；`NativeMessageRows.swift:87-110` | 看不到 `（2/5） · 8s`、看不到 `∞`、也看不到结构化的延迟与失败原因 | summary `inline-flex fit-content`、`padding:2px 0`、`gap:7`、`13/20 #81858C`；其后 6×6 三角（`border-right/bottom:1.5px`、`rotate(-45deg)`、`margin-right:2`、`transition:transform 120ms`，展开 `rotate(45deg)`）；文本 `{label}（{retry}/{maximum}） · {seconds}s`，`maximum = mode==='normal' ? maxRetries : '∞'`；running 用 TextShimmer + 250ms 刷新到 1s 停；details `grid gap:2`、`margin-top:3`、`padding-left:14`、`13/18`，两行 `重试延迟：{n}毫秒` / `失败原因：{msg}` | `delayMs`/`mode`/`maxRetries`/`retry`/`retryState`/`failure.code`（现只取 message） | 新增 `.modelRetry(...)`；用 `TimelineView(.periodic(by:0.25))` | fixture：scheduled / active / started / cancelled × normal / infinite |
| C-14 | P1 | 错误行文案、配色、字重、结构不一致 | `MessageItem.tsx:131-146`；`MessageItem.module.css:272-304`；`locale.ts:167-175` | `NativeTranscriptProjector.swift:119-125`（`title: "本轮执行失败"`）；`NativeMessageRows.swift:87-110` | 标题文案、红色色值、字重、缺少错误码 chip 四处同时不同 | `grid-template-columns:10px minmax(0,1fr) auto`、`gap:8`、`padding:2px 0`、`13/20`；StateDot 10 槽 6 填充 + `margin-top:5`；title `本轮运行失败` `#EC1313` **600** `margin-right:6`；message `#61666B`；code chip `11/16 等宽 #81858C`；`role="status"`；code ∈ {ACCOUNT_SIGNED_OUT, INTERRUPTED} → title 变 `任务已停止` 且不显示 code | `turn/end.reason.error.code`（现丢弃） | 统一成 3 列 grid；改文案与 token；透传 code | fixture：5 种 code + 无 code + INTERRUPTED |
| C-15 | P2 | max-token 行配色与字号 | `MessageItem.tsx:148-161`；`MessageItem.module.css:306-310` | `NativeTranscriptProjector.swift:113-118`；`NativeMessageRows.swift:87-110` | 官方琥珀色 600 标题 + 13/20 正文；iOS 是次级 13 medium + 12 号 | title `#F59E0B` 600 `margin-right:6`；hint `#61666B`；`13/20`；dot=warning | — | 与 C-14 共用网格组件 | 快照 |
| C-16 | P2 | 未认领事件没有兜底行 | `fallback.ts:9-21`；`MessageItem.tsx:358-370`；`locale.ts:147` | `NativeTranscriptProjector.swift:144-145` 丢弃；`.unknown` 只用于未知 assistant block（`:58`） | 新版本事件在 iOS 上静默消失 | `.contextRow`（`padding:2px 0`）内 `JsonBlock`；label `未知 surface 事件：{type}`；截断尾 `… 已截断，共 {total} 字符` | 任意未认领 append 事件 | projector `default` 改产出 `.unknown` | 伪造 type fixture |
| C-17 | P2 | 中断态没有「已停止」标记 | `AssistantMarkdown.tsx:149-152`；`AssistantMarkdown.module.css:60-71`；`locale.ts:157` | `ChatItem` 无 interrupted 字段；`turn/end` 只把工具标 stopped（`NativeTranscriptProjector.swift:126-130`） | 被中断的回复看起来像正常结束 | `.stopped`：`align-self:flex-start`、`padding:0 6px`、`radius:8`、`bg rgba(38,49,72,.06)`、`#81858C`、**`11/18`**、无动画 | `turn/end.reason.kind ∈ {aborted,interrupted}` | closing assistant 打 interrupted，正文尾追加 tag | fixture + 快照 |
| C-18 | P2 | 行内代码 / 表格 / 分割线 / 列表细节 | `MarkdownText.module.css:102-190,143-149,163-174,192-275`；`render.tsx:475-500` | `NativeMarkdownBody.swift:63-137,140-164` | 表格最明显：iOS 三列表也横滚、表头有灰底、th 用到 600 | 行内码 `≈10.5px`、`border:0.5px l1`、`radius:8`、`padding:0 5px`、`bg:#FAFAFA`；表格 th `13/22 500` **无底色**、td `13/22 400`、`padding:10px 16px`、首列 0 / 末列 0、th 下框 `0.5 l3`、td 下框 `0.5 l2`；**<4 列 `width:100%` 自动换行，≥4 列自然宽**；分割线 `height:0.5`、`margin:32px 0`；列表 `padding-left:18`、项间 6、marker `#61666B`、task 用真 checkbox | — | 表格按列数分支；行内码加边框/圆角/padding；列表 indent 18 | 快照 3 列 / 5 列表格 |
| C-19 | P2 | markdown 正文图片查看器 | `ImagePreview.module.css:1-24`；`ImageLightbox.tsx` | `NativeMarkdownBody.swift:285-341` | 官方是 `radius:8` 容器 + Lightbox；iOS 是黑底全屏 sheet | 容器 180 高、`radius:8`、`bg:bg-base`；loading/failed `12/18 #81858C`；点击开 lightbox；`alt` 兜底 `italic #81858C` | — | 复用 C-01 的 lightbox | 快照 + 加载/失败态 |
| C-20 | P2 | 脚注编号与 section 形态 | `render.tsx:700-712`；`locale/zh.ts:40` | `NativeMarkdownModel.swift:51-59,230-231` | 官方按首次引用顺序编号上标；iOS 打 `[id]` 且固定 9pt | `<sup>` 1..N；文末 section 标题 `脚注`；上标随 base 字号 | — | 记录首次引用顺序并编号 | 快照 |
| C-21 | P2 | steering 无区分、缺引用摘要行 | `MessageItem.tsx:297-321`；`UserContent.tsx:53-57`；`locale.ts:128` | `NativeTranscriptProjector.swift:27-29`；无 `referenceLabels` | 官方 steering 与 user 视觉一致（本就如此），但引用摘要行 `引用会话 · {labels}` 缺失 | 摘要 `13/18 #81858C`，气泡下方 | `source.references[].label` | 投影补 labels；气泡下加摘要 | 快照 |
| C-22 | P2 | 流式 spinner 是 iOS 发明 | `AssistantNodeView.tsx`（行内无 spinner）；`ChatView.module.css:142-160`（`RunningStatus` 在 flow 末尾） | `ChatPage.swift:2291` `ProgressView().controlSize(.mini)` | 官方只在流末尾显示“深度求索中”，iOS 每轮助手正文顶上多一个转圈 | 删除行内 spinner，改由 `RunningStatus` 承担（Axis 05） | — | 直接删 | 快照 |
| C-23 | P2 | 用量 pill 文案、图标与手机收缩形态 | `TurnUsagePanel.module.css:17-47,59-73`；`TurnUsagePanel.tsx:40-51`；`locale.ts:178` | `NativeMessageActions.swift:45-56` | iOS 常显 `用量 1.2K tok`，官方是 `用量 1.2K` 且 **≤480px 收成纯图标**（402pt 命中） | 标签 `用量 {total}`（无 ` tok`）；icon 15；`12/24`；`tabular-nums`；`height:28`、`padding:6px 8px`、`radius:8`；**≤480px：28×28、padding 6、label 隐藏**；`aria-haspopup="dialog"`+`aria-expanded` | — | 加宽度分支 | 402pt 快照 + 展开态 |
| C-24 | P2 | 反馈 dialog 缺失 | `MessageFeedbackActions.tsx:95-133`；`FeedbackDialog.tsx`；`locales.ts:5-12` | `ChatPage.swift:2323-2328` 直接 `rateMessage` | 官方 👍/👎 打开 `提交反馈`（分类 + 详情），iOS 点了就提交 | 文案 `好的回答` / `有问题的回答`；选中态实心 icon + `aria-pressed`；dialog 标题 `提交反馈`、`反馈分类`、`反馈详情`、提示 `填写详情以帮助我们改进体验，提交内容会包括当前对话的日志` | `messageFeedback` remote | 补 dialog + 实心态 | 快照 |
| C-25 | P2 | 改动文件卡细节 | `ChangedFiles.module.css:2-32`；`ChangedFiles.tsx:20-28` | `NativeChangedFilesCard.swift:15-99` | 结构已很接近，差在圆角、千分位、tile 底色 | `radius:16`；counts 千分位 `+{n}`/`-{n}`；tile `bg neutral-50`、`border:0.5px l1`、`radius:10`；header 60 高已对；path 12px、counts `11/18` 已对 | — | 改 3 处常量 | 快照 |
| C-26 | P2 | turn-tail slot 贡献缺失（计划卡/定时任务卡） | `register-node-renderers.ts:78-87`；`TurnTailNodeView.tsx:47-78`；`ui-plan/index.ts:79-80`；`ui-schedule/index.ts:189-190`；`ui-deliverables/index.ts:62-64` | `ChatPage.swift:2301-2309` 只挂改动文件卡 + 动作行 | 计划卡、定时任务卡在 iOS 没有位置（计划本体见 Axis 03） | `.root` flex column **gap:16**；slot 在动作行上方；`.actions{margin-top:4;margin-left:-6}` | `submitted-plan`、schedule 事件 | 留 `turnTailContributions` 插槽 | 快照 |
| C-27 | P2 | 加载更早 / 历史错误 / 空态形态 | `ChatView.module.css:227-245,136-140`；`locale.ts:86-87` | `ChatPage.swift:732-767` | 官方是 12px 灰底胶囊按钮；iOS 是 44 高 bordered 按钮 + 橙色错误块 | 按钮 `padding:4px 12px`、`12px`、`radius:8`、`bg interactive-bg-hover-solid`、居中、文字 `加载更早`；错误 `历史加载失败：{message}（{code}）`、`13/18 #EC1313`、无底色 | — | 改样式与文案 | 快照 |
| C-28 | P2 | question-reply 行结构缺失（与 Axis 03 重叠，主要由 03 报） | `question-reply.ts:38-43`；`QuestionReplyView.module.css:1-20`；`locales.ts:17-21` | `grep -rn "question-reply"` → 0；`ChatPage.swift:2139-2245` 只有待答卡 | 回答后官方留一条右对齐气泡（可展开答案明细 + 复制/时间），iOS 什么都不留 | `.row` align-end `gap:6` `padding:4px 0`；`.bubble` **max-width:72%**、`padding:10px 16px`、`radius:20`、`bg:#EDF3FE`、`14/22`、`pre-wrap`；label `回答先前等待中的问题`；`已跳过`；`回答：`；动作行 `HH:mm` + 复制 | `user-question/answered` | 见 Axis 03；行级复用 C-03 气泡 | fixture |

## 5. 隐藏/条件控件清单

| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 备注 |
|---|---|---|---|---|
| turn-trigger 卡 | `user/message` 且 `source.kind != 'user'` 且被 inbox 认领为本轮唤醒（`waking`） | `conversation.chat.node:turn-trigger` | 否 | 10 种标题映射；未认领时落 `context` 行 |
| system-prompt 行 | 首个 request、series start、system 变更 | `conversation.chat.node:system-prompt` | 否 | 默认可见，非调试开关 |
| 压缩行展开摘要 | `compaction/summary` 且 `summary !== null` | `CompactionItem.tsx:39,72-73` | 否 | 展开时标题 sticky |
| 压缩行 pinned 摘要计数器 | `shadowedItemCount`/`shadowedTokenCount` 存在 | `CompactionItem.tsx:41-45` | 否 | 文案 `已压缩 {items} 条历史记录（约 {tokens} tokens）` |
| manual-compaction | `/compact` 命令 + 压缩事务 | `conversation.chat.node:manual-compaction` | 否 | title 用命令名 |
| command 卡 | 任意 slash 命令 | `conversation.chat.node:command` | 否 | 分 running/ok/error |
| 重试倒计时 | `llm/retry` 且 `retryState==='scheduled'` | `RetryNodeView` + `ModelRetryItem` | 否 | 250ms 刷新 |
| 无限重试 `∞` | `mode !== 'normal'` | `MessageItem.tsx:72` | 否 | — |
| 错误码 chip | `turn-error.code` 且非 `INTERRUPTED` | `MessageItem.tsx:143` | 否 | 等宽 11/16 |
| 「任务已停止」变体 | code ∈ {ACCOUNT_SIGNED_OUT, INTERRUPTED} | `MessageItem.tsx:140` | 否 | 与 `本轮运行失败` 二选一 |
| 「已停止」尾标 | `assistant-step.status === 'interrupted'` | `AssistantMarkdown.tsx:149-152` | 否 | 11/18 细标 |
| 未知 surface JSON | 未认领 append 事件 | `fallback.ts:19` | 否 | 现在事件被 `default` 丢掉 |
| question-reply 气泡 | 迟到回答 | `conversation.chat.node:question-reply` | 否 | 72% 宽 |
| 计划卡（tail） | 本轮有 `submitted-plan` | `ui-plan` → `conversation.chat.turnTail` | 否 | 开右侧栏 |
| 定时任务卡（tail） | 本轮创建/更新 schedule | `ui-schedule` → turn tail | 否 | — |
| 改动文件卡 | 本轮有 git 变更摘要 | `ui-deliverables` → turn tail | **是**（`NativeChangedFilesCard`） | 细节差 |
| 用量 pill | `performanceUsage === 'detailed'` 且 `tokenUsage` 存在 | `TurnTailNodeView.tsx:74-76` | **是** | ≤480px 形态不符 |
| 反馈 dialog | 点 👍/👎 | `ui-message-feedback` overlay | 否（直接提交） | — |
| 图片 lightbox | 点任意消息图片 | `ImageLightbox` | 否（transcript 内） | markdown 内有 sheet |
| 分支动作 | `session/fork` 权限 + 本轮末尾 | `TurnTailNodeView.tsx:70-71` | 否（`onBranch` 未接） | — |
| reference 摘要 | 消息引用会话 | `UserContent.tsx:53-57` | 否 | `引用会话 · {labels}` |
| 折叠：改动文件 >4 | `files.length > 4` | `ChangedFiles.tsx:48,98-104` | **是** | 一致 |
| 表格宽表 breakout | ≥4 列 | `render.tsx:475-490` + `AssistantMarkdown.module.css:33-43` | 否 | 402pt 下 ≥4 列极常见 |

## 6. 数据链路缺口

| 事件/字段 | 官方消费方 | iOS 映射/投影 | 缺失后果 | 需要补什么 |
|---|---|---|---|---|
| `user/message.source.kind`（10 种） | `turn-trigger.ts:21-70`、`message.ts:34-35` | `DSHEventMapper.userInputSource` 仅保留 kind 字符串（`:126-129`）；projector 只用它分 user/context（`NativeTranscriptProjector.swift:31-38`） | 无法区分“人类输入”与“定时任务/子 Agent/goal 唤醒” | 把完整 `source`（含 `provider`、`label`）带进 `ChatItem`；新增 turnTrigger kind |
| `system/message`（append / surfaceOp） | `SystemPromptRow`、`request-prompt.ts:62-83` | 只进调试 ledger（`ChatModel.swift:1580`）；transcript 丢弃 | system-prompt 行不可得 | projector 新增分支 + `update` 标记（需要上一次 effective prompt 做 diff，或直接用 surfaceOp） |
| `command/run`、`command/done` | `GenericCommandCard`、`command.ts` | 只进调试 ledger（`ChatModel.swift:1592`） | 命令行不可得 | projector 新增 command 行（name / args / outcome.text / outcome.kind） |
| `compaction/summary` 的 `shadowedItemCount`/`shadowedTokenCount` | `CompactionItem.tsx:41-45` | 只读 `summary` 字符串（`NativeTranscriptProjector.swift:140`） | 没有“已压缩 N 条” | 读计数；`compaction/checkpoint` 关联 |
| `llm/retry` 的 `delayMs`/`mode`/`maxRetries`/`retry`/`retryState`/`failure.code` | `ModelRetryItem` | 只取 `failure.message` 或 `reason`（`:131-137`） | 无倒计时/次数/上限 | 扩展 `ChatItem` 或专门 payload struct |
| `turn/end.reason.error.code` | `TurnErrorItem` code chip | 丢弃（`:119-125` 只取 message） | 无错误码 | 透传 code |
| `assistant/message.status`（interrupted 判定） | `AssistantChatData.status` | 无字段；只有 `turn/end.reason` | 「已停止」不可得 | projector 在 `turn/end` 时回写到该 turn 的 closing assistant |
| `agent/inbox/spliced`（含 claim 序列） | 子 Agent / 后台消息行（Axis 04）；本轴用它判 `waking` → turn-trigger vs context（`message.ts:75-92`） | `case .userMessage, .inboxSpliced:` 直接 `break`（`ChatModel.swift:1719-1722`） | 子 Agent 消息不可见，且无法判定“谁唤醒了这一轮” | 见 Axis 04；本轴需要 claim 关系 |
| `unknown-surface`（未认领 append 事件） | `fallback.ts` + `UnknownNodeView` | 丢弃（`:144-145`） | 新事件静默消失 | projector `default` 产出 `.unknown` |
| `developer/message` | `message.ts:139-152`（context 行） | 丢弃（`NativeTranscriptProjector.swift:144-145`） | 开发者注入消息看不到 | 复用 C-09 的 context 行 |
| `user-question/answered`（迟到回答） | `question-reply` | 无 | 回答痕迹消失 | 见 Axis 03 |
| `turn-tail.tokenUsage` 的 `routes` | `TurnUsagePanel` 的 `提供方 / 模型` | `NativeTurnUsage` 无 routes | 用量弹层缺一行 | 投影 `provider/model` 组合 |
| 图片 durable 引用（`attachment.attachmentId`） | `ImageLoader` 授权读取 | `NativeMessageAttachment.payload` 已有，但无 loader/授权 URL | 图片不能显示 | 加 workspace/attachment 读取通道（Axis 06 已有部分） |

**关键结论**：`session/page` 返回的 records 是全量 journal，`ChatModel.trajectoryEntries`（`ChatModel.swift:1570-1600`）已经把 `system/message`、`command/run|done`、`request/header`、`agent/inbox/spliced`、`compaction/*` 分类过一遍，证明**数据在设备上**。缺口是 `NativeTranscriptProjector.items`（历史）与 `DSHEventMapper.map`（实时）两处 `default` 丢弃。所以本轴 80% 的行补齐 = 投影 + 视图，不需要新协议。

## 7. 实施顺序建议

**Wave 1（纯常量改动，观感立刻接近官方；全部不依赖新数据）**

1. C-04 assistant 行高 14/24 + C-05 transcript 32pt 内边距与 6/12/16 行距 —— 两处改动同时做，整页密度与宽度一次到位。
2. C-03 用户气泡（`#EDF3FE` / radius 20 / padding 10-16 / 行高 22 / max 277）。
3. C-08 动作行右对齐 + 去 ShareLink + glyph 15/17 + 时钟位置与样式。
4. C-06 代码块（banner 同底色、24×24 图标按钮、`pre` padding 6/22/20、去掉“展开全部 N 行”）。
5. C-07 标题阶梯 + C-18 表格（去表头灰底、th 500、<4 列铺满换行）。
6. C-15 / C-17 / C-22 / C-23 / C-27 小项合并成一个 PR。

**Wave 2（行类型补齐，只改投影 + 一个共享代码壳）**

7. 抽 `NativeCodeShellBody`（`max-height:141`、`11/16 等宽`、`#81858C`、`#F9FAFB`、`radius:12`、`22px` 缩进），给 context / system-prompt / command 三处复用。
8. C-10 system-prompt 行 → C-09 context 行去聚合 → C-11 command 行。
9. C-12 压缩行结构化（含文案修正与 sticky）→ C-13 重试链 → C-14/C-15 错误与 max-token 网格统一 → C-16 未知事件兜底 → C-17 中断尾标。

**Wave 3（P0 与需要新数据的行）**

10. C-01 图片网格 + lightbox（需要授权图片 loader）——P0。
11. C-02 turn-trigger（需要 `source` 全量 + inbox claim）——P0。
12. C-24 反馈 dialog、C-26 turn-tail slot、C-19 markdown 图片查看器、C-20 脚注、C-25 改动文件卡、C-28 question-reply（与 Axis 03 协同）。

## 8. 未知与需确认

- **官方 402pt 实测未做**：本报告的 338/277pt 等宽度是从 `ChatView.module.css:28`、`ConversationRoot.module.css:384-395`、`MessageItem.module.css:20` 的 CSS 静态推算（`--dsh-composer-side-clearance:16`、`scrollbar-gutter:stable` 在 iOS 覆盖滚动条下取 0）。若实际 shell 走的是 `.embeddedBody`（`--dsh-chat-content-width: min(100%-32px,920)`、clearance 8），那么 transcript 左右只有 24pt、内容 354pt。需要用官方 Web 在 402×874 下量一次 DOM 才能定死。
- `--dsh-alias-bg-layer-1` 解析为 `neutral-bluish-00`（纯白），改动文件卡 header 用的是 `--dsw-static-neutral-50`（#FAFAFA）；两者在浅色下几乎同色，深色分别 #232324 / #2C2C2E。截图无法分辨，需真机取色确认。
- `ui-secret-mask`（`web-app/cordis.patch.yml:388`）会在发送的用户文本里对凭据做遮罩，iOS 完全没有这一层；属于内容呈现，但不在本轴 26 条清单内，建议单列。
- iOS 的 markdown 解析每次 chunk 全量重解析（`NativeMarkdownBody.swift:35-40`），官方是增量（`incremental.ts`）。流式长回答的掉帧/闪烁程度需要真机测量才能定严重度，本报告未计入 P 级。
- `MessageItem.module.css:101-103` 的“压缩摘要里代码块 banner 下移”规则依赖 sticky；iOS 若照抄需确认 SwiftUI `LazyVStack` 内 sticky header 的实现方式（官方是 CSS sticky，iOS 需 `pinnedViews` 或自绘），这会影响 C-12 的实现成本。
- `question-reply` 的 72% 与 user 的 82% 两个上限是否在手机端被 ui-mobile 覆盖：`mobile.module.css` 没有任何相关规则，故按未覆盖处理；但官方是否另有运行时宽度变量（`--dsh-chat-user-width`）在手机端被写入，未能在源码中确证。
