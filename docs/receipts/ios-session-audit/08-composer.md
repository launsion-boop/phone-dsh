# Axis 08 — Composer / 输入区 Dock / 会话页头 — iOS Session 对齐审计

> 审计基线：官方 DSH `7be5505b0b`（`0.2.1-rc.2`），iOS 仓库工作区当前 HEAD。
> 视觉基准：手机宽度 **402pt**（CSS px ≈ iOS pt），官方 `ui-mobile` 断点 `<640px`（`packages/client/ui-mobile/src/client/mobile.module.css:13`）。
> 本文只审**页头 + composer 卡片 + 上方 input dock + 下方 composer dock + 输入弹层**；消息流内部见 Axis 05–07，plan/todo 的完整状态机见 Axis 02，提问/审批状态机见 Axis 02/03，子 Agent lineage 见 Axis 04。
> 官方 composition 以 **shipped web-app** 为准：`packages/bundle/web-app/cordis.patch.yml:327-458, 596`（`ui-conversation / ui-approval / ui-chat / ui-attachment / ui-input-trigger / ui-commands / ui-skill / ui-subagent / ui-reference / ui-jobs / ui-schedule / ui-goal / ui-message-feedback / ui-model-selection / ui-permission-presets / ui-plan / ui-user-questions / ui-mobile` 均为随附行）；`packages/experimental/*` 一律不计入默认随附（唯一相关的 `client-ui-voice-input` 只占 `conversation.input.activity`，未随附）。

## 0. 结论摘要

- **页头不是同一个东西**：官方在 402pt 下是一个 50pt 高的四段槽位条（`leading` / `crumb+actions` / `utilities` / `corner`，`ConversationRoot.module.css:15-23, 64-189`），标题是 **14px/20px wt500 左对齐的当前面包屑**、不可点（`crumbCurrent { cursor: default }`，`:150-154`）；iOS 是 **44pt、标题 17pt semibold 居中、可点改名** 的自绘条，右上是官方没有的「运行状态点 + 文字」（`ChatPage.swift:113-171`、`NativeShell.swift:47-76`）。
- **官方 composer 有 4 个 dock（todo / goal / queue 在卡片上方，activity+usage+context 在卡片下方），iOS 只有 1 个半**：goal bar 形态不同、queue 是「从 transcript 标签拼出来的假队列」、todo 完全不存在；`NativeComposerStats` 把官方的 3 个独立控件（activity pill / usage pill / context meter）压成一行 11pt 药丸。
- **实测差异不是「参考官方」级别的**：官方卡片 402pt 下 370×98、圆角 **28**、卡片上方 8pt 内距 + 12pt gap、发送键 **34 圆在控制行内**（不是浮层）、access mode 在手机端被 `order: 1; margin-left: auto` 挪到**发送键右侧最右**（`mobile.module.css:182-199`）；iOS 是 370×94、圆角 **22**、4pt 内距、发送键用 `overlay(.bottomTrailing)` 浮在卡右下角、access mode 在 `+` 右边第二位（`ChatPage.swift:1164-1233, 1296-1331`）。
- **手机端官方把输入字号抬到 16px**（`mobile.module.css:170-175`），iOS 仍是 14pt（`ChatPage.swift:1177`）；官方手机键盘 `enterkeyhint=send` + Enter 直接发送（`mobile-enter-send.ts:14-22`、`keymap.ts:154-156`），iOS 的 `TextEditor` 回车只换行、没有任何 `enterKeyHint`（全库 0 命中）。
- 结论：**P0 = 5，P1 = 12，P2 = 11，P3 = 2（共 30 条）**。P0 全部落在「官方有、iOS 没有入口或没有状态」：todo dock、plan chip、空白会话 hero、可用 queue dock、composer 接管层。
- ⚠️ 证据校正：`docs/receipts/ios-baseline-screens/ios-chat-official.png` **不是官方 Web 截图**，是 iOS `-uiPreview chat.official` 的自绘页（`INDEX.md:77` 已注明「transcript renders blank，只保留 header/composer/stats 作证据」）。仓库内**没有** 402pt 官方 Web 截图，本报告所有官方像素值均由 CSS/TSX 静态推导，标注「源码推导」。

## 1. 审计范围与方法

**官方侧**（`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`，HEAD `7be5505b0be06009d74891c869063c9cf19a0df0`）：

- 组合层：`packages/client/ui-conversation/src/client/skeleton/{ConversationHeader,ConversationSession,ConversationContent,ConversationRoot,InputBar,ContextMeter,TodoPanel,EmptyHero,control-row-layout}.tsx`
- 样式：同目录 `{ConversationRoot,InputBar,TodoPanel,ContextMeter,HeroShell}.module.css`（全读）；`queue/QueueDock.module.css`（246 行全读）
- 手机层：`packages/client/ui-mobile/src/client/{mobile.module.css（207 行全读）,frame.ts,mobile-enter-send.ts,edge-swipe.ts,HeaderMenuButton.tsx,HeaderMenuButton.module.css}`、`packages/client/ui-mobile/src/index.ts`（PWA viewport 注入）
- docks：`packages/client/ui-goal/src/client/{GoalBar.tsx,GoalBar.module.css,locales.ts,index.ts}`、`ui-conversation/src/client/queue/QueueDock.tsx`、`ui-conversation/src/client/skeleton/TodoPanel.tsx`
- composer 内部席位：`ui-permission-presets/src/client/{PermissionSelect.tsx,PermissionSelect.module.css,locales.ts}`、`ui-model-selection/src/client/ModelSelect.module.css`、`ui-plan/src/client/{PlanModeControl.tsx,PlanModeControl.module.css,locales.ts}`、`ui-attachment/src/client/ComposerAttachments.module.css`、`ui-input-trigger/src/client/{MenuView.tsx,MenuView.module.css}`、`ui-commands/src/client/{index.ts,PopupSelectView.module.css}`
- 下方 dock：`ui-chat/src/client/{apply.ts,chat/StatsPills.tsx,chat/StatsPills.module.css,chat/token-format.ts,chat/message-chrome.ts}`
- 接管：`ui-user-questions/src/client/QuestionComposer.module.css`、`ui-approval/src/client/index.ts`
- token：`ui-theme/src/styles/{base.css,design-platform.css,gradient-shadow-text.css}`（半径 `:18-23`、elevation `:33-40`、菜单 blur `:20`、字体阶梯 `:57-59, 234-235`）
- 文案：`ui-conversation/src/client/locales.ts`、`ui-chat/src/client/locale.ts`、`ui-goal/src/client/locales.ts`、`ui-plan/src/client/locales.ts`、`ui-input-trigger/src/client/locales.ts`
- 测试（行为证据）：`apps/web/tests/{mobile-shell.e2e.ts,composer-shortcuts.e2e.ts,composer-placeholder.e2e.ts,composer-draft-scroll.e2e.ts,queue-actions.e2e.ts,goal-bar.e2e.ts,plan-control-row.e2e.ts,context-meter.e2e.ts,shipped-composition.e2e.ts}`、`packages/client/ui-conversation/tests/control-row-layout.client.spec.ts`

**iOS 侧**（`/Users/leilangsheng/Desktop/TonoTeam/phone-dsh`）：

- `examples/probe-app/PhoneDSHProbe/ChatPage.swift`（页头 113-171、composer 1134-1238、actionButton 1241-1261、stopButton 1263-1294、composerControls 1296-1331、accessModeMenu 1355-1418、modelMenu/modelNameBlock 1433-1512、attachmentStrip 1581-1602、composerEnabled/canSubmit 1604-1617、submitDraft 1619-1673、placeholder 1746-1754、slash 1807-1878、reference 1881-1941、goalBar 1046-1098、queuedStrip 1100-1132）
- `NativeComposerStats.swift`（127 行全读）、`NativeChatTheme.swift`（98 行全读）、`NativeShell.swift`（`NativeHeaderStyle:38-43`、`RunStatusDot:47-76`、抽屉 185-245）
- `ChatModel.swift`（`canSend:276`、`canSteer:287`、`queueLabel:2107-2123`、`refreshNativeMetrics:1881-1895`、`handle:1719-1722`）
- `DSHManagementModel.swift`（`refreshQueue:460-484`、`updateQueue:485-497`、`decodeActivityProjections:558-573`）、`SessionsPage.swift`（`SessionQueuePage:652-712`、入口 `:99,350`）、`SessionActivityPage.swift`（21-45）、`SettingsPage.swift`（96-103、442-453）
- 测试：`examples/probe-app/PhoneDSHSimTests/` 21 个文件里 **0 个**断言 composer/页头（`grep -rln "composer|Composer"` 只命中 `WebSurfaceTests.swift`，是 Web 面不是会话页）
- 截图：`docs/receipts/ios-baseline-screens/{ios-chat-default,ios-chat-official,ios-chat-draft,ios-chat-queued,ios-chat-long}.png`（1206×2622 @3x = 402×874pt）——**只作 iOS 侧观察**，见 §0 末尾的校正

**穷尽搜索（0 命中即「iOS 没有」的证据）**：

```bash
cd /Users/leilangsheng/Desktop/TonoTeam/phone-dsh
grep -rn "todo\|Todo" examples/probe-app/PhoneDSHProbe/ChatPage.swift | wc -l            # 0
grep -n "todo\|Todo\|plan\|Plan" examples/probe-app/PhoneDSHProbe/NativeComposerStats.swift | wc -l  # 0
grep -rn "探索未至\|预览版\|hero\|Hero" examples/probe-app/PhoneDSHProbe/*.swift | wc -l  # 0
grep -rn "enterKeyHint\|submitLabel\|onSubmit" examples/probe-app/PhoneDSHProbe/ChatPage.swift | wc -l  # 0
grep -rn "计划模式\|planMode\|PlanChip\|/plan" examples/probe-app/PhoneDSHProbe/ChatPage.swift | wc -l  # 0
grep -rn "queue/update\|\"queue\"" Sources/ examples/probe-app/PhoneDSHProbe plugins/channel plugins/worker-entry | grep -v node_modules   # 只命中 prompt mode:"queue" 与 @AppStorage 键
grep -rn "showActivity" examples/probe-app/PhoneDSHProbe/*.swift                          # 只有声明(51)与 sheet(292)，无赋值 → 不可达
grep -n "selectedQueueSession" examples/probe-app/PhoneDSHProbe/SessionsPage.swift        # 只有 :99 声明与 :350 destination，无赋值 → 不可达
```

## 2. 官方基线（按 surface 列）

> 下列「像素规格」全部是 **402pt 下的源码推导值**：`--dsh-composer-side-clearance: 16px`、`--dsh-composer-card-max-width: calc(--dsh-chat-content-width + 32px)`、`--dsh-chat-content-width: clamp(680px, 64% × 列宽, 920px)`，402pt 时 clamp 取下界 680 → 卡片 `width:100%` 受 `.root` 16px 侧距约束 = **370px**（`ConversationRoot.module.css:384-391`、`InputBar.module.css:2-11, 45-77`）。

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| S1 | **页头**（常驻，有无 session 都在） | `ConversationHeader.tsx:12-26`；`ConversationRoot.module.css:15-23` | `header` = grid `auto / minmax(0,1fr)`；[headerLeading] [titleRow→(titleCluster→crumbs+headerActions) + headerUtilities + headerCorner]；无 tabs 时 `:where(:not(:has(.tabs))) { min-height:0; padding-bottom:10px }`（`:25-28`） | 高 = 10 + 30 + 10 = **50**；`padding: 10px 28px 0 20px`；`border-bottom: 0.5px solid rgba(0,0,0,.12)`（`--dsw-alias-border-l3`，`design-platform.css:189`）；titleRow `min-height 30`、`container-type:inline-size` | — | blank 会话：`min-height:0 / padding-bottom:0 / border-bottom:none`（`:31-35`）；sessionless：无 titleRow 内容 | `session.blank`、`conversationPhase` |
| S2 | **面包屑 / 标题** | `ConversationSession.tsx:25-43, 69-126`；`ConversationRoot.module.css:102-154` | `nav[aria-label=会话层级]` → 每段 `span.crumbSeg{gap4}`＋`/`分隔＋当前段 `<span>`（**不是 button**） | 面包屑 `gap 4`；`/` 14px/20 `#ADB2B8`；段 `padding 4px 8px`、`border-radius 12`、`max-width 220`、`text-overflow ellipsis`、14px/20、祖先 `#81858C`；当前段 `wt500` `#0F1115`、`cursor: default`；子 Agent 段降为 12px/18（`.crumbSubagent`） | 无标题时回退显示 `sessionId`（`:125`） | 点祖先段 → `open(id)`；hover 只对 `button.crumb` 生效（`:146-148`）；**无点击改名** | `sessionById.displayTitle`、`origin==='subagent'`、`parentId` |
| S3 | 页头 actions 槽 | `ui-conversation/src/client/apply.ts:424, 429-435`；`ui-mobile/index.ts:104-111`；`ui-subagent/index.ts:83-90`；`ui-jobs/index.ts:35-53` | `headerActions{flex:none;gap 8}`，按 order 排 | `mobile-menu`：36×36、`border-radius 10`、16px `IconPanelLeftOutlineRegular`、`margin-left 2`、`color #61666B`、hover `rgba(38,49,72,.06)`、`aria-pressed`、`@media(min-width:640px){display:none}`（`HeaderMenuButton.module.css:1-37`）；`mobile-menu order:-10`、`subagent-catalog order:10`、`job-list order:20` | `menu.aria` = 菜单 | 手机端**菜单键在标题之后**（源码顺序 + order），不是最左 | 插槽注入 |
| S4 | 页头 utilities 槽 | `apply.ts:434`；`ui-open-in-app/index.ts:102-105`、`ui-schedule/index.ts:209-220`、`session-log-export/index.ts:51-64` | `headerUtilities{flex:none;gap 8;margin-left 20}`，`:empty{display:none}`（`:163-173`） | order：`open-in-app -10`、`schedule-catalog -5`、`session-log-download 0`；垂直居中 | 打开方式 / 定时任务 / 导出 | 每个都是独立按钮（不是「···更多」） | 各包 projection |
| S5 | 页头 corner 槽 | `apply.ts:435`；`ui-sidebar-right/index.ts:238` | `headerCorner{flex:none;margin-left 8;margin-right -16}`，`:empty{display:none}`（`:179-189`） | 右缘只留 28-16 = **12**pt 与屏幕边 | — | 右侧栏展开 | — |
| S6 | **composer 卡片** | `InputBar.tsx:395-519`；`InputBar.module.css:45-77` | `div.card{flex-col;gap 12;padding-top 8}` → [overlayAnchor(绝对 0 高)] [attachments rail] [DraftEditor(.scroll>.input)] [.row] | **370 × 98**；`border-radius: 28`（`--dsw-radius-panel`，`base.css:23`）；`background: #FFFFFF`（`--dsw-specific-input-major`→`bluish-00`）；`box-shadow: elevation-soft` = `0 0 0 .5px rgba(0,0,0,.1) + 0 4px 16px rgba(0,0,0,.03) + 0 0 24px rgba(0,0,0,.03)`（`InputBar.module.css:60-63` + `gradient-shadow-text.css:33-40`）；dark：`#2C2C2E` | — | 卡片**无 border**，0.5px 描边画在 box-shadow 里 | — |
| S7 | 草稿区 | `InputBar.module.css:128-134, 169-191`；`InputBar.tsx:419-438` | `.scroll{max-height:336;overflow-y:auto;margin-right:4}` > `.grow{position:relative}` > contenteditable | `min-height 36`；`padding: 4px 8px 0 14px`；字号：桌面 `14`、**手机 `<640px` 强制 16px**（`mobile.module.css:170-175`），行高恒 `24`；`white-space: pre-wrap`、`word-break: break-word`、`caret-color: #4176E6`；14 行上限 = 336（`ConversationRoot.module.css:357`） | 见 S10 | 自动增长；IME 组合期 `data-composer-composing`；claim 提示用 `::after { content: var(--dsh-composer-hint) }`（`:196-199`） | `input.draft` |
| S8 | 占位符 | `InputBar.module.css:218-252`；`InputBar.tsx:363-372` | `position:absolute; inset: 4px 8px auto 14px`；`nowrap + ellipsis`；hero 变体 2 行 clamp（`:246-252`） | 14px/24、`#ADB2B8`（`label-caption`）；hero 输入框 `min-height 52` | 见 §附录 C | 组合期隐藏（`[data-composer-composing] + .placeholder{visibility:hidden}`） | — |
| S9 | **控制行 toolbar** | `InputBar.tsx:439-518`；`InputBar.module.css:256-423` | `.row{flex;wrap;space-between;gap 12;padding 2px 8px 6px}` → `.tools{gap12}`[+ / modes[permission, plan] / left] + `.trailing{margin-left:auto;gap12}`[right, model, activity, stop?, send] | 行高 34 + 上下 8 = **42**；`gap` 在 `@container (max-width:560px)` 降为 **8**（卡片内宽 354 → 命中）；`+`：**28 圆**、`--dsw-specific-selector` = `rgb(245,246,247)`、14px `IconPlusOutlineMedium`、`:disabled{opacity .5}`；permission/model 触发器：28 高、`border-radius 8`、`padding 0 4px 0 8px`、13px/20 wt500(perm)/wt400(model)、`#61666B`；model `max-width: min(360px, 45cqw)`；发送：**34 圆**、`background: #4176E6`（`--dsw-alias-button-info-fill`→`deepseek-500`；注释里写的 `#3964FE` 是旧值，以 token 为准）、`color:#fff`、`transform: translateY(-2px)`、`:disabled{opacity .4}`、hover `#7AAAFF` | `input.commands` 添加文件或调用指令；`input.send`/`queue`/`steer` | 手机端重排：`[data-composer-tools]` / `[data-composer-modes]` / `[data-composer-trailing]` 三者 `display:contents` + `[data-input-access-mode]{order:1;margin-left:auto}` → **顺序 = `+` … plan … model … send … access-mode（最右）**（`mobile.module.css:182-199`）；`frame.ts:168-189` 负责打这些 `data-*` | — |
| S10 | 发送/停止语义 | `InputBar.tsx:323-342, 481-516`；`input/submission-policy.ts:28-35`；`input/editor/keymap.ts:134-158` | 主按钮 1 个 +（仅 continuable 子 Agent）独立的 Stop | `primaryStops = running && subagent===null && (empty ‖ blocked)` → 主按钮显示**停止**（同 34 蓝圆内 16×16 viewBox 的 `rect 10×10 rx3`）；否则显示箭头 `path`（16×16）。aria-label 随模式切换：`input.stop`/`input.send.queue`/`input.send.steer` | 停止生成 / 发送消息 / 排队发送 / 插话发送 | 忙时 Enter 行为 = 设置项 `busyEnter`（`queue`/`steer`），`⌘/Ctrl+Enter` 取反；`Shift+Enter` 换行；`event.repeat` 忽略；组合期 Enter 不提交；空草稿 `⌘Enter` = `steerQueue()`（`view-binding.ts:121-124`）；手机端 `enterkeyhint=send`（`mobile-enter-send.ts:14-22`） | `settings.busyEnter` |
| S11 | **input dock：todo** | `TodoPanel.tsx:65-100, 106-118`；`TodoPanel.module.css` 全 | `section[data-testid=todo-panel]` > `.body{flex-col;gap 8;padding 6px 12px}` > [header button] + [ul.list] | 面板 **338 宽**（= 100% − 2×16 − 4×8）、`border-radius 16`（`radius-lg`）、`background: --dsw-specific-menu` + `backdrop-filter: blur(40px) saturate(150%)`、`box-shadow: elevation-panel`；header `gap 10`；图标 16 盒；标题 13px/**24** wt500 `#0F1115`；进度 13px/20 `#81858C` 单行 ellipsis；chevron 16；列表 `max-height 180`、行 `gap 10`、13px/20 `#61666B`、glyph 16×16、条目单行 ellipsis | `todo.title` 任务；进度 `{done} 已完成␠·␠{active} 进行中…`（**U+2002 包住 `·`**，零值段省略）；状态 已完成/进行中/待处理 | 默认**折叠**（`useState(true)`）；`aria-expanded`、`aria-label=任务`；`todos.length===0` → 返回 null | `useProjection('todos')` |
| S12 | **input dock：goal** | `GoalBar.tsx:86, 134-174`；`GoalBar.module.css:5-130` | `div.dock[data-goal-bar]` > `div.bar{flex;gap 10}` [glyph14][label][objective][error?][actions] | 条 **338×36**、`padding 4px 5px 4px 12px`、`border-radius 12`、menu 面 + `backdrop-filter` + `elevation-panel`；label 13/24 wt500 `#0F1115`（`flex:none`）；objective 13/20 `#151517` 单行 ellipsis（`flex:1;min-width:0`，**在 338 宽下会被压到很短**）；动作 28 圆、`gap 10`、14px 图标、`#81858C` | `phase.active` 进行中的目标 / `.disarmed` 已暂停的目标 / `paused` 已暂停的目标 / `blocked` 受阻的目标 | phase `complete` → **不渲染**（`:86`）；pause 只在 `active && activation==='armed'`；resume 在 `paused` 或 `active && disarmed`；edit → 同条内 `InlineEditor`（`min-height 36; height:auto; align-items:flex-end`）；clear 恒在；`tooltip` 走 `side="bottom"` | `useProjection('goal')` + `useGoalActivation` |
| S13 | **input dock：queue** | `QueueDock.tsx:168-387`；`QueueDock.module.css` 全 | `div.dock[data-queue-dock]` > `div.panel{radius 16 16 0 0;padding 2px 0}` > [`.header`(仅 rowCount>1)] + `ul.list` | dock **354 宽**、`padding 0 8px`、`margin: 0 auto calc(0 − 6 − 3)`（**方底贴住卡片 3px**）；panel 338 宽；header **36 高**、`padding 4px 12px`、`gap 10`；count 13/24 wt500 Inter；chevron 14×14；行 `min-height 36`、`padding 4px 5px 4px 12px`、`radius 12`、行间 `inset 0 1px 0 rgba(0,0,0,.04)` 分隔；附件缩略 24×24 `radius 4`、文件 chip `height 24`、`min-width 74`、`flex 0 1 180`、文件名 13/20、大小 10px；动作 28 圆 `gap 10` | `queue.count` {n} 条排队消息；`queue.sending` 发送中…；`queue.edit` 编辑排队消息 / `remove` / `steer` 插话发送；`queue.steer.unavailable` 仅运行中可插话发送；`queue.edit.unsupported` 包含非文本内容，暂不支持编辑 | **1 条：无计数头、直接列出行**；**≥2 条：默认折叠只看计数头**；编辑用 `InlineEditor`；动作失败 → `notify('error', …)`；本地 pending 提交显示 `发送中…` + 三个 disabled 按钮 | `useProjection('inbox')` + `session.pendingSubmissions` + `session/updateQueue` |
| S14 | composer dock：activity / usage | `ui-chat/apply.ts:323-330`；`StatsPills.tsx:237-334`；`StatsPills.module.css` 全 | `.dock{flex;center;gap 12;padding-top 4}`（`InputBar.module.css:13-20`）内：activity(order0)、usage(order1)、ContextMeter（恒在） | pill：字号 **12**（`calc(secondary 13 − 1)`）、行高 20、`padding 1px 8px`、`gap 6`、`radius 8`、图标 14、`#81858C`、`tabular-nums`、hover/展开 → 文字 `#61666B` + 底 `rgba(38,49,72,.06)`；`·` 分隔 span `margin: 0 6px`；点开的是 **portal 面板**（`stat-dialog.module.css`，264 宽级） | `stats.counts` {turns} 轮 {steps} 步；`stats.cacheHit` 缓存命中 {percent}%；`message.tokensPerSecond` {tps} tok/s；`message.turnUsage.*`；面板标题 会话统计 / Token 用量 | compact 模式只留 `tok/s` 或缓存命中（`usePerformanceUsage`）；usage 在 `billedInput==0 && output==0` 时不渲染；activity 在 `steps===0` 且无 speed 时不渲染 | `sessionStats` / `tokenUsage` projection |
| S15 | composer dock：ContextMeter | `ContextMeter.tsx:56-180`；`ContextMeter.module.css:9-154` | `.dock` 内第三个控件：`button.trigger{gap 6;padding 1px 8px}` = [14×14 SVG 环] + `{percent}%` | 字号 **13**（`--dsh-content-font-size-secondary`）、行高 20、`tabular-nums`、`#81858C`；环 viewBox 14、`r=5.5`、`stroke-width 2`、`linecap round`、`rotate(-90)`；轨道 `rgba(0,0,0,.12)`、进度 `#81858C`；点开面板 264 宽、`padding 12`、`radius 16`、`elevation-prominent`；面板内 12px/20 三段色条 `height 4`、`gap 1`、`radius 999`，色 `rgb(173,178,184)` / `rgb(167,139,250)` / `rgb(77,147,248)` | `context.aria` 上下文已用 {percent}%；`context.used` 上下文已用；`context.system/tools/messages` 系统提示词/工具定义/对话消息 | 无阈值变色（永远 tertiary）；`contextPressure` 或 `contextWindow` 缺失 → 不渲染；面板 `role=dialog`、Esc 关闭 | `contextPressure` + `contextBreakdown` |
| S16 | **input.overlay：slash/@ 菜单** | `MenuView.tsx:47-222`；`MenuView.module.css:1-64, 109-274` | 绝对定位浮层，锚在卡片（`overlayAnchor` 0 高、`inset: 0 0 auto`，`InputBar.module.css:119-123`） | `bottom: calc(100% + 4px)`、`left/right: 0`（= 卡片宽 370）、`padding 4`、`radius` 由 `MenuSurface` 给定、`elevation-prominent`、`max-height 400` 且运行时 clamp 到 `TOP_MARGIN 84`（页头 76+8）；行 `min-height 34`、`padding 6px 8px`、`radius 12`、13px/20、图标 14、`gap 6`、名称 `max-width 40%`、别名 12/18、描述右对齐 12/18 `#81858C`；分组标题 11/16 `padding 5px 8px 2px`；骨架 2 行、2s 呼吸；`aria-activedescendant` 高亮、`Tab` 钻取 | 分组标题 指令/技能/子智能体；`loading` 正在加载…；`drill.hint` 进入目录；`drill.key` Tab | 键盘 ↑↓ 高亮（焦点不离开编辑器）、`Tab` 进目录、Esc 关、空分组显示骨架；`data-overflow-below` 底部 16px 渐隐提示 | `input/trigger` 服务 |
| S17 | input.overlay：command-popup / feedback-dialog | `ui-commands/index.ts:65-74`；`PopupSelectView.module.css:1-21`；`ui-message-feedback/index.ts:116` | 同为卡片上方浮层 | `bottom: calc(100% + 4px)`、`min-width: min(220px,100%)`、`max-width: 100%`、`max-height 320` | 命令名/描述 | — | `commandUi` |
| S18 | **附件 rail** | `ui-attachment/ComposerAttachments.module.css:1-68` | 卡片内第一行（在草稿上方） | `.rail{padding: 2px 10px 0; margin-bottom: -6}`；图片 **64×64**、`radius 20`（`radius-xl`）、描边 `0.5px rgba(0,0,0,.1)`；删除钮 18 圆、`top/right 4`、`#61666B` 底、白 `×`、`opacity 0`（`@media(pointer:coarse)` 恒显）；文件卡 见 S13 | `file.uploading` 上传中…；`file.uploadFailed` 上传失败，点击重试；`image.tooMany` 一条消息最多添加 {count} 张图片 | 上传未完成前**发送被 gate**（`InputBar.tsx:85-87, 325`） | `useFileUploads` |
| S19 | **接管：提问/审批顶替整条 composer** | `ConversationContent.tsx:173-187`；`ui-user-questions/index.ts:380-392`；`ui-approval/index.ts:92-100`；`QuestionComposer.module.css:1-46` | `renderSlotChain('conversation.composer', …, {overlay:true})` —— 命中时**整个 fallback（docks + 卡片 + 底部 dock）被替换** | 接管框：`padding 6px calc(16 + 16px) 10px`、`max-width: --dsh-chat-content-width`、`max-height: min(60vh, 520px)`、`radius 20`（`radius-xl`）、`background: #FFFFFF`、`elevation-panel` | 见 Axis 02/03 | 待答/待批准期间**没有可编辑 composer**；`cardMinimized` 可缩成只剩标题条 | `pendingInteraction` |
| S20 | 空白会话 hero | `EmptyHero.tsx:38-62, 132-165`；`HeroShell.module.css:5-63`；`ConversationRoot.module.css:507-518` | `composerStack.composerHero` = [HeroShell:fish+标题] [heroWorkspaceRow:workspace chip + preset + options] [input docks] [InputBar variant=hero] | 居中、`gap 8`、`padding-bottom 32`；标题 **26px/32 wt500** `#0F1115`、fish 34×25、`column-gap 10`；预览徽 `12px/18 wt500`、`padding 1px 7px 0`、`radius 999`、底 `--dsw-alias-state-business-tertiary` `#E4EDFD`、字 `#1E40AF`；workspace chip `min-height 28`、`padding 0 8`、13/20 wt500、`gap 4`、`max-width min(100%,360)`、chevron 12 `#ADB2B8`；hero 输入 `min-height 52` | `hero.headline` 探索未至之境；`hero.preview` 预览版；`hero.chooseWorkspace` 选择工作区；`placeholder.hero` 描述你想要构建的内容, / 调用指令, @ 文件或对话 | fish hover 游泳（1.6s，`prefers-reduced-motion` 下静态）；hero 相位下 **composer.dock 不渲染**（`InputBar.tsx:521`）只有 ContextMeter | `session.blank` |

**官方 token 解析（light / dark）**——`ui-theme/src/styles/design-platform.css`：

| token | light | dark |
|---|---|---|
| `--dsw-alias-label-primary` | `rgb(15,17,21)` | `rgb(249,250,251)` |
| `--dsw-alias-label-secondary` | `rgb(97,102,107)` | `rgb(207,211,214)` |
| `--dsw-alias-label-tertiary` | `rgb(129,133,140)` | `rgb(173,178,184)` |
| `--dsw-alias-label-caption` | `rgb(173,178,184)` | `rgb(129,133,140)` |
| `--dsw-alias-border-l1/l2/l3/l4` | `rgba(0,0,0,.04/.10/.12/.16)` | `rgba(255,255,255,.06/.12/.16/.2)` |
| `--dsw-alias-interactive-bg-hover` | `rgba(38,49,72,.06)` | `rgba(255,255,255,.08)` |
| `--dsw-alias-button-info-fill / hover` | `rgb(65,118,230)` / `rgb(122,170,255)` | `rgb(122,170,255)` / `rgb(65,118,230)` |
| `--dsw-alias-state-business-primary / tertiary` | `rgb(65,118,230)` / `rgb(228,237,253)` | `rgb(122,170,255)` / `rgb(52,65,91)` |
| `--dsw-specific-input-major` | `rgb(255,255,255)` | `rgb(44,44,46)` |
| `--dsw-specific-selector` | `rgb(245,246,247)` | `rgb(53,54,56)` |
| `--dsw-specific-menu` | `rgba(248,249,250,.58)` | `rgba(48,49,54,.94)` |
| `--dsw-alias-bg-base` | `rgb(255,255,255)` | `rgb(21,21,23)` |
| radius | `xs 4 / sm 8 / md 12 / lg 16 / xl 20 / panel 28`（`base.css:18-23`） | 同左 |

## 3. iOS 现状（按 surface 列）

| # | Surface | iOS 实现（file:line） | 现在画成什么 | 行为 | 与官方的差 |
|---|---|---|---|---|---|
| I1 | 页头 | `ChatPage.swift:113-171`；`NativeShell.swift:38-43, 47-76` | `ZStack`：居中标题 `17pt semibold #111114`（左右各留 104 的 padding 防撞）+ 左侧 `sidebar.left` 20pt（32×44 热区）+ 右侧 `HStack(4)`[8pt 圆点 + 11pt「运行中/未启动/后台暂停」][`ellipsis` 20pt，44×44] | 点标题 → 重命名 alert（`:116-126, 223-235`）；点状态点 → `RuntimeDetailsPage` sheet；点 `···` → 系统 Menu[导出对话记录、本会话设置] | 高度 44 vs 50；标题 17 vs 14/20；居中 vs 左对齐；可改名 vs 不可点；有运行状态 chip vs 官方无；无面包屑；无 lineage/actions/utilities/corner 四段；无 0.5pt 底边 |
| I2 | composer 容器 | `ChatPage.swift:1134-1238, 1227-1230` | `VStack(spacing 9)`：goalBar → queuedStrip → attachmentStrip → 错误行 → steer 图片警告 → fileImportNotice → slash 菜单 → reference 菜单 → 卡片 → stats；`padding(.horizontal 16).padding(.top 12).padding(.bottom 8)`、`background(systemBackground)`；以 `.safeAreaInset(edge:.bottom)` 挂载（`:196-202`） | 键盘弹起只抬 composer | 卡片 370×**94**（vs 98）；圆角 22（vs 28）；卡片上内距 4（vs 8）；无 36pt 顶部渐隐；顶部 12pt（官方 0，靠 stack gap 6）；下方 dock 只有一行 stats |
| I3 | 草稿区 | `ChatPage.swift:1164-1197` | `ZStack(topLeading)`：空时叠一行 placeholder（14pt `caption` `#ADB2B8`，`lineLimit 1`，leading 5 / top 8）+ `TextEditor`（14pt、`lineSpacing(24-17)`、`minHeight 36 / maxHeight 336`、`fixedSize(vertical)`）；容器 `padding(.leading 14)(.trailing 8).frame(minHeight 36).padding(.top 4)` | `TextEditor` 回车 = 换行；8000 字截断（`:1189-1197`） | 字号 14 vs 手机端 16；回车行为不同；placeholder 实际起点 x=19/top=12（14+5 / 4+8）vs 官方 14/4；无 claim 提示、无 `enterkeyhint` |
| I4 | 控制行 | `ChatPage.swift:1199-1206, 1296-1331` | 行高 **32**、`padding(.top 10)(.bottom 12)`、`padding(.leading 14)(.trailing 40)`：`HStack(8)`[`+` 28 圆 `#F2F3F5` 14pt][权限 shield 17 + chevron 12，28 高，h-padding 5][`Spacer`][model 名 13pt `#111114`/`#66666B` + chevron 12，28 高][running 时 `ProgressView`] | — | 顺序不同（权限在左二，官方在发送键右侧最右）；行高 42 vs 32+22；发送/停止不在行内（浮层）；权限图标 17 vs 14 |
| I5 | 发送/停止 | `ChatPage.swift:1209-1218, 1241-1261, 1263-1294` | `.overlay(alignment:.bottomTrailing)`，`padding(.trailing 2)(.bottom 2)`；运行中且 `canSubmit` 时**并列** `stopButton(24, icon 9)` + `actionButton(34)` | 发送 34 圆 `accent #3964FE`、`arrow.up` 15pt bold、禁用 0.4、`scale(0.8)+opacity` 0.12s 过渡；停止 24 圆 `#66666B` 底 + `stop.fill` 9pt，点击中显 `ProgressView` | 位置（浮层 vs 行内）；停止颜色灰 vs 蓝；停止尺寸 24 vs 34；出现条件（草稿非空也并列）；无 `排队发送/插话发送` 可访问名称 |
| I6 | goal bar | `ChatPage.swift:1046-1082` | 40 高、`#F6F6F8` 底、`radius 10`、`padding(.horizontal 10)`：`target` 13pt + 两行（11pt 阶段 + 13pt 目标单行）+ 「暂停」/「继续」12pt 文字按钮 + `xmark` 11pt | 走 `/goal` 的 `pause` / `resume` / `clear` 命令；`complete` 仍显示「目标 · 已完成」 | 36 vs 40 高；12 vs 10 圆；menu 面/backdrop vs 实色；无编辑（inline editor）、无 blocked 原因、无 28 圆图标按钮组、阶段文案不同 |
| I7 | queue 条 | `ChatPage.swift:1103-1132` | `model.items` 里 `queueLabel=="已排队"` 的行 → `VStack(4)`：「排队中 N 条」12pt 头（`clock.arrow.circlepath` 12pt）+ 每条 28 高 `#F6F6F8` `radius 8` 单行文本 | 只有展示；无编辑/删除/插话 | 数据源是 transcript 标签而非 `inbox` 投影；无折叠/计数头语义（1 条也带头）、无动作、无附件缩略、无本地 pending 行、尺寸全不同；真正能编辑的 `SessionQueuePage`（`SessionsPage.swift:652-712`）**不可达**（`:99` 声明 `selectedQueueSession`，`:350` destination，全文件无赋值） |
| I8 | stats 行 | `NativeComposerStats.swift:17-56, 99-112` | `HStack(4)`、`.frame(maxWidth:.infinity)`、`padding(.top 4)`；三个 11pt `monospacedDigit` 药丸：〔gauge 14 + `{turns} 轮 {steps} 步` + `·` + `{Int(tps)} tok/s`〕〔database 14 + `{compact} tok` + `· 缓存命中 {n}%`〕〔14 环 + `{n}%`〕 | 点任一 → `.sheet` `presentationDetents(.medium)` 的 `List`（`:57-96`） | 字号 11 vs 12/13；tok/s 取整 vs <10 保一位；usage 用 compact vs 官方 `formatTokens`（同）；分隔 `·` 在 Text 内 vs 独立 span `margin 0 6px`；gap 4 vs 12；点击 → 全屏 sheet vs 264 定位面板；context 未独立成 13pt 控件且无三段色条 |
| I9 | 上下文环 | `NativeComposerStats.swift:114-127` | 14×14 `Circle` 双环，`lineWidth 2`，轨道 `border #E4E4E8`、进度 `caption #ADB2B8`，`trim 0…p/100`、`-90°` | 无阈值 | 进度色应 `#81858C`（tertiary），轨道应 `rgba(0,0,0,.12)`；环径 14 一致 |
| I10 | slash 菜单 | `ChatPage.swift:1831-1874` | composer `VStack` 内的**流内块**：`#F2F3F5` 底、`radius 14`、最多 6 行；行 = `/name` 15pt semibold + 描述 12pt；加载/错误/空态各一行 13pt | 打字触发（前导 `/` + 无空白）；点击写回 `/name ` | 不是锚定浮层（会顶起 transcript）、无分组、无键盘高亮、无 `Tab` 钻取、无骨架、无 `max-height`/滚动、无 `aria-activedescendant` |
| I11 | @ 引用菜单 | `ChatPage.swift:1897-1941` | 同上是内联块：文件行（`FileTypeGlyph` 20 + 路径）+ 会话行（`branch` 16 + 标题）、`secondaryFont`、`radius 14` | 最多 6 文件 + 3 会话 | 同上；官方 `${source}` 分组标题（指令/技能/子智能体）与描述右对齐都缺 |
| I12 | 附件条 | `ChatPage.swift:1581-1602` | 卡片**上方**独立 `ScrollView(.horizontal)`：胶囊「photo 图标 + 文件名 + `xmark.circle.fill`（44×44）」、`.caption`、`Color(.secondarySystemBackground)` | 只支持图片（`:1756-1758`）；上限 20 张 / 20MB / 200MB（`:1771-1783`） | 官方在卡片内、64×64 缩略图、删除钮 18；官方文件卡与图片混排，iOS 文件走「写入工作区」 |
| I13 | 接管 | 无（`pendingQuestion` 画在 transcript 上方，`ChatPage.swift:484-551`；`PermissionCardView` 在 `:703`） | transcript 顶部卡片（`frame(maxHeight: 屏高×0.4)`，键盘弹起时折成一行「N 项需要处理」`ChatPage.swift:487-506`）+ composer 保持常驻（仅 disabled） | 回答后无 reply 行 | 官方整条 composer 被 `QuestionComposer`/`ApprovalPanel` 顶替；官方接管卡高度上限 `min(60vh,520)` 且自带最小化，iOS 是 40% 屏高的可滚区 + 键盘折叠 |
| I14 | 空白会话 | 无 | 空白（只有 composer） | — | 官方 hero：fish + 26/32 标题 + 预览徽 + workspace chip 行 + 52pt 输入 |
| I15 | 键盘/焦点 | `TextEditor` + `@FocusState`；`:1656` 发送后 `inputFocused=false`；无 `enterKeyHint`、无 `submitLabel`、无 IMEC 组合守卫 | 回车换行；键盘「return」 | 发送键必须点 | 官方 Enter 发送、⌘Enter 反向、Shift+Enter 换行、IME 组合期不提交 |

## 4. 差距清单（核心交付）

> 计量单位一律 pt(=CSS px @402)。「官方证据」「iOS 证据」都是 `file:line`。官方像素值除标注外均为**源码推导**（无 402pt 官方截图，见 §0）。

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
|---|---|---|---|---|---|---|---|---|---|
| **C-01** | **P0** | 会话页**没有 todo dock**：任务清单在输入区上方完全没有入口，也没有折叠/进度摘要 | `TodoPanel.tsx:65-100`（面板）、`:106-118`（注册 `conversation.input.dock id:'todo' order:0`）、`TodoPanel.module.css:1-123` | `ChatPage.swift` 内 `todo/Todo` 0 命中；`NativeComposerStats.swift` 0 命中；数据只有 `DSHManagementModel.swift:126-128, 562-566`，而唯一读它的 `SessionActivityPage.swift:31-45` **不可达**（`ChatPage.swift:51` 声明 `showActivity`，全文件无 `= true`） | 用户问「这轮还剩什么没做」时，手机上无处可看；官方是输入框上方一条「任务 · 2 已完成 · 1 进行中 · 3 待处理」 | ① 面板 338 宽、`radius 16`、menu 面 + `blur(40px) saturate(150%)` + `elevation-panel`，放在 composerStack 内、卡片之上（gap 6）；② body `padding 6px 12px`、`gap 8`；③ header `gap 10`：16 盒 checklist 图标 `#81858C` + 「任务」13/**24** wt500 `#0F1115` + 进度 13/20 `#81858C`（单行 ellipsis，U+2002 包 `·`，零值段省略）+ chevron 16；④ 列表 `gap 8`、`max-height 180` 可滚、行 `gap 10`、glyph 16×16（done/ongoing/idle 三态）、文本 13/20 `#61666B` 单行 ellipsis；⑤ 默认折叠，`aria-expanded`、`aria-label=任务`；⑥ `todos` 为空 → 整块不渲染 | `session/projections` 的 `todos`（iOS **已经能拿到**：`ChatModel.swift:1881-1895` 已经在调这个 RPC，只是只取了 4 个 key） | ① `ChatModel` 增加 `todos: [NativeTodoItem]`，在 `refreshNativeMetrics()` 里一并解析 `values["todos"]`（同一次响应，零额外请求）；② 新增 `NativeTodoDock`（纯视图，输入 `todos`）；③ 挂到 `composer` 的 `VStack` 最上面（在 goalBar 之前） | 单测：给定 todos JSON → 断言面板存在、进度串（含 U+2002、零值省略）、默认折叠；快照：与官方 402pt 逐项比 338 宽 / 36 头 / 6-12 内距 |
| **C-02** | **P0** | **没有 plan mode 控件**，也没有 plan 占位文案；iOS 反而把 `plan` 当成一个权限档位（「只出方案」） | `PlanModeControl.tsx:22-85`、`PlanModeControl.module.css:1-60`、`ui-plan/index.ts:116-127`、`ui-plan/locales.ts:4-20`、`InputBar.tsx:69, 372` | `ChatPage.swift` 内 `/plan`、`planMode`、`PlanChip` 0 命中；`ChatModel.swift:119` 把 id `"plan"` 映射成权限档「只出方案」；`DSHManagementModel.swift:126-127` 有 `planActive/planPending` 但只喂不可达的 `SessionActivityPage.swift:21-29` | 用户无法在会话里「只出方案」地对话：既看不到当前处于 plan 模式，也关不掉；官方是控制行里一个常驻 chip + 占位符改写 | ① chip 只在 `pending ? !active : active` 为真时渲染（折叠主机值，不做客户端乐观）；② 几何：28 高、`min-width 34`、`padding 0 8`、`radius 8`、`gap 4`、13/20 wt500、底 `#E4EDFD`（dark `rgb(52,65,91)`）、字 `#4176E6`（dark `#7AAAFF`）；③ 图标位 14×14：静息 `IconPlanOutlineRegular`，hover/focus 换成 `IconCloseCircleFillRegular`（表示「点了是关」）；④ 文案「计划」，`aria-label`「计划模式已开启，按下关闭」，`title`「计划模式已开启 — 点击关闭（/plan off）」；⑤ 点击 = `commands.execute('/plan off')`，失败时条内追加 12/18 `#EC1313` 的「退出计划模式失败」；⑥ plan 生效时 placeholder 变「描述你的任务以生成计划」；⑦ plan 的开启走 `/plan` 命令（不要新造开关） | `plan` projection（`active`/`pending`）+ `/plan off` 命令通道（iOS 已有 `runSlashCommand`，`ChatPage.swift:1954-1961`） | ① `ChatModel` 解析 `values["plan"]`；② 新增 `NativePlanChip` 放在 `composerControls` 的 `.modes` 位（权限之后）；③ placeholder 分支加 plan 判定 | 单测：`plan{active:true}` → chip 出现且文案/颜色正确；`pending:true,active:false` → 不渲染；点 → 调 `/plan off`；快照：chip 28 高 / 8 圆角 / 14 图标 |
| **C-03** | **P0** | **空白会话没有 hero**：官方新会话页是「鲸鱼 + 探索未至之境 + 预览版徽 + 工作区 chip + 52pt 输入下限」的居中态 | `EmptyHero.tsx:38-62, 132-165`、`HeroShell.module.css:5-63`、`ConversationRoot.module.css:507-518`、`ConversationContent.tsx:110-135, 164-171` | `ChatPage.swift` 内 `hero/Hero/探索未至/预览版` 0 命中；空会话只有一个空白 transcript + 底部 composer | 新会话页整块空白，产品第一屏没有品牌与「从哪个工作区开始」；官方还有「hero 相位下不显示 stats pills」的密度差异 | ① `composerStack` 居中、`gap 8`、`padding-bottom 32`；② 标题行：fish **34×25** + `column-gap 10` + 文本 26px/32 wt500 `#0F1115`，整体居中（窄屏时 fish 换到标题上一行，`row-gap 12`）；③ 预览徽：`padding 1px 7px 0`、`radius 999`、`border .5px rgba(38,49,72,.06)`、底 `#E4EDFD`、字 `#1E40AF`、12/18 wt500、等宽字族、`margin-top 2`；④ workspace chip 行：`padding 0 16 0 20`、chip `min-height 28`/`padding 0 8`/13-20 wt500/`gap 4`/folder 16 + chevron 12；⑤ hero 输入区 `min-height 52`、placeholder 允许 2 行；⑥ hero 相位**不渲染** stats pills（只留 ContextMeter）；⑦ 文案见 §附录 C | `session.blank` + `conversationPhase==='blank'`（iOS 侧等价信号：`model.items` 无 user 且 `currentSessionID` 存在；`ChatPage.swift:96-103` 已能区分） | 新增 `NativeEmptyHero` 视图，插在 `queuedStrip` 之前、且 `visibleItems.isEmpty` 时渲染；`ChatPage.swift:1224` 的 stats 在 hero 时隐藏 | 快照：空会话 402pt 与官方 hero 叠图比 fish 34 / 标题 26-32 / 徽 12-18 / chip 28；单测：hero 相位下 stats 不渲染 |
| **C-04** | **P0** | **queue dock 不可用**：iOS 的「排队中 N 条」是从 transcript 标签拼出来的，不是官方 `inbox` 投影；三动作（编辑/删除/插话）、附件缩略、本地 pending 行全缺；唯一能改队列的页面不可达 | `QueueDock.tsx:105-140`（inbox + pendingSubmissions）、`:168-190`（计数头）、`:236-319`（三动作 + InlineEditor）、`:390-411`（注册）、`QueueDock.module.css:4-59, 61-135, 150-246` | `ChatPage.swift:1103-1132`（`queueLabel=="已排队"` 过滤）、`ChatModel.swift:2107-2123`（标签字符串）`ChatModel.swift:1719-1722`（`.inboxSpliced` 直接 break）；`DSHManagementModel.swift:460-497` **有** `refreshQueue`/`updateQueue`（走 `session/projections` 的 `inbox` + `session/updateQueue`），但 `SessionsPage.swift:99` 的 `selectedQueueSession` 全文件无赋值 → `SessionQueuePage` 不可达 | 排队消息既看不出「排在第几轮」，也不能改一个字、不能删、不能「现在就说」；跨设备/重载后排的队完全看不见 | ① dock **354 宽**、`padding 0 8`、`margin-bottom: calc(0 − 6 − 3)`（panel 方底压到卡片下 3pt）；② panel 338 宽、`radius 16 16 0 0`、`padding 2px 0`、`background: menu 面` + backdrop、`::after` 0.5px `rgba(0,0,0,.04)` 描边且**无下边**；③ 计数头 36 高、`padding 4px 12px`、`gap 10`：16 盒 queue 图标 + 「{n} 条排队消息」13/24 wt500 `#0F1115` + chevron 14；④ **1 条时不渲染计数头**，行自己带 queue 图标；**≥2 条默认折叠**（`aria-expanded`、`aria-controls`）；⑤ 行 `min-height 36`、`padding 4px 5px 4px 12px`、`radius 12`、行间 `inset 0 1px 0 rgba(0,0,0,.04)`；⑥ 附件：图片 24×24 `radius 4`，文件 chip 24 高/`min-width 74`/`flex 0 1 180`/文件名 13-20/大小 10px；⑦ 三动作 28 圆 `gap 10`：编辑（非纯文本则 disabled + `title`「包含非文本内容，暂不支持编辑」）、删除、插话（`!running` 时 disabled + title「仅运行中可插话发送」）；⑧ 编辑态换 `InlineEditor`（保存 ✓ / 取消 ✕ 两个 28 圆）；⑨ 本地 pending 提交行：右 `发送中…` 13/20 `#81858C` + 三动作 disabled | `inbox` projection（`next-turn`/`next-step` 两 lane）+ `session/pendingSubmissions` 等价物 + `session/updateQueue` RPC（**iOS 已实现** `DSHManagementModel.swift:485-497`，只是没接到会话页） | ① 把 `refreshQueue` 从 `DSHManagementModel` 迁/复用到 `ChatModel`，在 `refreshNativeMetrics` 同一次 `session/projections` 里解析 `values["inbox"]`；② `.inboxSpliced` 事件到达时也触发一次刷新（`ChatModel.swift:1719-1722` 现在直接 break）；③ 新增 `NativeQueueDock`（含折叠与三动作），替换 `queuedStrip`；④ 删除 `queueLabel` 那一套字符串标签，行内状态改由 pending 列表驱动 | 单测：inbox JSON（2 条）→ 折叠只显示头；1 条 → 无头；edit/remove/steer 各发一次 `session/updateQueue` 且带正确 `action`；快照：方底贴合 3pt、338 宽、36 行高 |
| **C-05** | **P0** | **没有 composer 接管层**：官方待答题/待批准时用 `conversation.composer` chain 把**整条 composer（docks + 卡片 + 底部 dock）顶替**；iOS 只是把卡片放到 transcript 顶部并保持 composer 常驻（仅 disabled） | `ConversationContent.tsx:173-187`、`ui-user-questions/index.ts:380-392`、`ui-approval/index.ts:92-100`、`QuestionComposer.module.css:1-46` | `ChatPage.swift:484-551`（`cardsRegion`：待处理卡在 transcript **上方**）、`:530-538`（权限/问题卡）、`:703`（`PermissionCardView`）、`:1604-1608`（`composerEnabled` 仅在有待答时为 false） | 待答时官方是「输入区变成问题面板」——视线与手指都在底部；iOS 是「问题卡跑到屏幕上方、输入框还在下面但不能用」，长 transcript 下可能要向上翻很久才看到问题 | ① 接管时**不渲染** InputBar 卡片与全部 dock，改渲染接管卡；② 接管卡几何：`padding 6px calc(16 + 16px) 10px`、`max-width 338`、`max-height min(60vh, 520px)`、`radius 20`、`#FFFFFF` + `elevation-panel`、内部 body 可滚；③ 接管卡标题条 `padding 20px 16px 0 24px`、`gap 16`，右侧两个 24 图标钮（最小化/关闭）；④ 最小化态 `padding-bottom 14`、取消高度上限；⑤ 问题/审批的内部状态机归 Axis 02/03，本轴只交付「位置 = composer 座位」与外壳几何 | `pendingInteraction`（iOS 现有 `pendingQuestion` / `pendingPermission` 两个布尔式状态即可先合并判空） | 在 `composer` 的 `VStack` 最前面插入 `if let takeover = model.pendingTakeover { NativeComposerTakeover(...) } else { 现有 composer 内容 }`；`ChatPage.swift:1604-1608` 的禁用条件保留作双保险 | 快照：待答时底部只见接管卡（370×≤520、radius 20）、卡片消失；单测：接管时 stats/docks 都不渲染 |
| C-06 | **P1** | 页头**四段槽位结构**缺失：没有 lineage / actions / utilities / corner，也没有面包屑；入口只靠一个 `···` 菜单 | `ConversationHeader.tsx:18-25`、`ConversationSession.tsx:69-139`、`ConversationRoot.module.css:93-189`、`apply.ts:423-435` | `ChatPage.swift:113-171`、`:151-164`（Menu 只有两项） | 手机上无法从页头看到「这是子 Agent 会话 / 有几个子 Agent / 有几个后台任务 / 有几个定时任务 / 能不能在外部应用打开」 | ① 结构改为 `[leading 槽][titleRow: [crumbs(可滚动、单行 ellipsis、max 220/段)] [actions 槽]][utilities 槽][corner 槽]`；② `actions{flex:none;gap 8}`、`utilities{flex:none;gap 8;margin-left 20}`、`corner{margin-left 8;margin-right −16}`，空槽 `display:none` 不占位；③ 手机端抽屉键 36×36/`radius 10`/16 图标，放在 **crumbs 之后**（`order:-10`），`aria-pressed`；④ 保留 iOS 现成的导出/会话设置到 utilities 位；⑤ 子 Agent 目录、后台任务入口的数据见 Axis 04/09，这里只保证槽位与几何 | 各 projection（`subagentCatalog`、`jobs`、`schedules`） | 把 `chatHeader` 拆成 `leading / titleCluster / utilities / corner` 四段视图；先把抽屉键与导出/设置搬进正确槽位，再按 Axis 04/09 的结论填 actions | 快照：页头 50 高、左 20 右 12、段间距 8/20/8；单测：无子 Agent/任务时 actions/utilities 不占位 |
| C-07 | **P1** | composer 卡片几何与**内部行结构**不同：iOS 把发送键做成覆盖在卡右下的浮层，官方是控制行里的普通 flex 项 | `InputBar.module.css:45-77, 256-272, 377-396`、`InputBar.tsx:439-518` | `ChatPage.swift:1164-1218`（`overlay(alignment:.bottomTrailing)`、`.padding(.trailing 40)`）、`:1219-1223` | 卡片整体比官方矮 4pt、控制行比官方高 8pt 且重心偏上；发送键与 `model` 文字在垂直方向上不对齐（官方同行居中） | ① 卡片高 **98**：`padding-top 8` + 输入区 36 + `gap 12` + 控制行 42（内容 34 + 上 2 + 下 6）；② 控制行 34 高、`padding 2 8 6`、`gap 8`；③ **删除** `overlay` 与 `padding(.trailing 40)`，把 [权限][model][发送] 变成行内 flex 项，发送 `translateY(-2px)`；④ 圆角 22 → **28**（见 C-19） | — | 重写 `composer` 里卡片那一层 `VStack` 的 padding/gap 与 `composerControls` 的尺寸，发送键下移到行内 | 截图量：卡高 98、行高 42、发送圆 34 与行中线差 2pt |
| C-08 | **P1** | 控制行**顺序**与官方手机端不一致：官方把 access mode 用 `order:1;margin-left:auto` 挪到发送键**右侧最右**；iOS 把权限放 `+` 右边第二位 | `mobile.module.css:182-199`（注释明写 "it remains after Send/Stop at the far right"）、`frame.ts:168-189`、`apps/web/tests/mobile-shell.e2e.ts:54-70` | `ChatPage.swift:1296-1331`（`+` → accessModeMenu → Spacer → modelMenu → spinner） | 手指永远先撞到权限键（离发送最近的位置被权限占了）；官方是「`+` … model … 发送 … 权限（最右角）」 | 402pt 下从左到右：`+`(28 圆) → 〔plan chip〕→ 〔left/right 槽〕→ model(≤45cqw) → send/stop(34) → access-mode(28 高，最右)；`gap 8`；access-mode `margin-left:auto` | — | 在 `composerControls` 里把 `accessModeMenu` 移到 `HStack` 末尾并加 `Spacer` 前的 `layoutPriority` 调整（SwiftUI 无 `order`，用顺序 + `Spacer` 实现） | 快照：三键 x 坐标；e2e 等价断言：最右按钮是 access mode |
| C-09 | **P1** | 停止键**形态与出现条件**都不对：官方是**同一个蓝色 34 圆**里的圆角方，且只在「草稿空 / 被 block」时代替发送；continuable 子 Agent 才并列两个 | `InputBar.tsx:323-333, 481-516`、`InputBar.module.css:377-396` | `ChatPage.swift:1211-1214, 1242-1243, 1263-1294` | iOS 上「一边转圈一边有两颗按钮（灰 24 + 蓝 34）」在官方不存在；灰底停止键看起来像禁用态 | ① 停止与发送**同款**：34 圆、`#4176E6`（dark `#7AAAFF`）、白色 16×16 viewBox 内 `rect x3 y3 w10 h10 rx3`；② 主按钮二态：`running && empty`（或 blocked）→ 停止，否则 → 箭头；草稿非空时**只有发送**；③ 只有 continuable 子 Agent 才出现第二个独立的停止圆（同 34）；④ `aria-label` 分别「停止生成」「发送消息」「排队发送」「插话发送」；⑤ 停止中不要叠 `ProgressView`（官方无此态），改为 `disabled` + 保持停止图标 | `turnRunning`、`draft.isEmpty`、blocked 状态 | 合并 `actionButton`/`stopButton` 为一个 `primaryButton`，用状态算图标与 aria；删除 24 直径分支 | 单测：4 种状态（running+空 / running+有字 / idle+空 / subagent running）各自的按钮数、直径、aria |
| C-10 | **P1** | 占位文案与**占位状态机**都不对：官方运行中占位不变、plan 时改写、只有整队插话提示才改写；iOS 用「补充当前任务…/排入下一轮…」代替 | `InputBar.tsx:363-372`、`locales.ts:19-25` | `ChatPage.swift:1746-1749` | 运行中输入框里显示「排入下一轮…」，而官方仍显示完整占位「发消息或创建任务, / 调用指令, @ 文件或对话」——用户看不到 `/` 与 `@` 的教学 | ① 四档优先级（高→低）：`parentOffline` → `disabled` → `canSteerQueue`（整队插话）→ `plan` → default；② default 文案逐字：`发消息或创建任务, / 调用指令, @ 文件或对话`（**半角逗号 + 空格**）；hero：`描述你想要构建的内容, / 调用指令, @ 文件或对话`；plan：`描述你的任务以生成计划`；不可用：`会话不可用`；整队插话：`Cmd/Ctrl+Enter 插话发送全部排队消息`；③ 颜色 `#ADB2B8`、单行 ellipsis（hero 2 行）；④ 组合输入中隐藏 | `busyEnter`、`canSteerQueue`、`plan` | 把 4 档判断写成纯函数 `composerPlaceholder(state) -> String`，逐条照抄原文 | 单测：4 档 + 组合期隐藏，逐字符比对文案（含半角逗号） |
| C-11 | **P1** | 输入字号：官方手机端 **16px**，iOS 14pt | `mobile.module.css:170-175`（`[data-composer-input]{font-size:16px}`） | `ChatPage.swift:1177`（`NativeChatTheme.bodyFont()` = 14）、`NativeChatTheme.swift:25` | 手机上正文比官方小一号：行宽 24 高不变，字更稀；与 iOS 系统输入习惯（≥16 防缩放）不一致 | 草稿 16pt、行高 24；placeholder 保持 14pt（官方 `<input>` 之外的 `.placeholder` 继承卡片 14px，这是官方自身的不一致，照抄）；min-height 36 / max 336 不变 | — | 给 `TextEditor` 用 16pt 专用 font（不要改全局 `bodyFont`），`lineSpacing` 调成 24−16 行的自然行高差 | 截图量：单行文本基线到卡顶 ≤ 8+4+…；与官方 16px 行宽对比 |
| C-12 | **P1** | 键盘行为：官方 Enter 发送、`⌘/Ctrl+Enter` 反向、`Shift+Enter` 换行、`enterkeyhint=send`；iOS 回车只换行，键盘显示 return | `keymap.ts:134-158`、`view-binding.ts:110-141`、`submission-policy.ts:28-35`、`mobile-enter-send.ts:14-22` | `ChatPage.swift:1175-1183`（`TextEditor`）、全库 `enterKeyHint/submitLabel/onSubmit` 0 命中 | 手机键盘右下角是「return」，用户按下去只是多一行空行；官方是「发送」键 | ① 键盘动作键 = 发送（iOS 侧用 `UITextView.returnKeyType = .send` 或 `.submitLabel(.send)`——`TextEditor` 需包一层 `UIViewRepresentable` 才能拿到）；② Enter = 按 `busyEnter` 提交；③ 无硬件键盘时 `⌘Enter` 不适用（iOS 外接键盘时空草稿 + `⌘Enter` = 插话整队）；④ `Shift+Enter`（外接键盘）换行；⑤ 长按 Enter 不连发（`event.repeat` 等价：`textViewShouldChange` 里忽略重复）；⑥ IME 组合期不提交 | `busyEnter`、`canSteer` | 用 `UIViewRepresentable` 包 `UITextView` 替换 `TextEditor`，在 `textView(_:shouldChangeTextIn:)` 里拦 `\n` | 真机：键盘键帽显示「发送」；单测（可测部分）：`resolveSubmitMode` 等价函数 4 组输入 |
| C-13 | **P1** | slash/@ 菜单是**流内块**而不是锚定浮层，且缺分组/键盘/滚动/骨架 | `MenuView.module.css:1-35`、`MenuView.tsx:60-70, 77-133`、`locales.ts:1-20` | `ChatPage.swift:1831-1874, 1897-1941` | 菜单展开时会把整个 transcript 顶上去（输入区高度跳变），官方是**浮在**输入框上方、不挤压内容；也没有「指令 / 技能 / 子智能体」分组 | ① 浮层：锚在卡片顶部，`bottom: calc(100% + 4px)`、`left/right: 0`（= 370）、`padding 4`、`radius 16`、`elevation-prominent` + menu 面/backdrop；② `max-height 400` 且 clamp 到 `屏幕高 − 页头(50) − 8`；③ 行：`min-height 34`、`padding 6 8`、`radius 12`、`gap 6`、名称 13/20（`max-width 40%`、ellipsis）、别名 12/18、描述右对齐 12/18 `#81858C`、图标 14；④ 分组标题 11/16 `#81858C`、`padding 5 8 2`；⑤ 键盘 ↑↓ 移动高亮、`Tab`/点击 chevron 钻取、Esc 关；⑥ 加载 2 行骨架（2s 呼吸）；⑦ 选项数不再固定 6，靠 `max-height` 滚动 | `availableCommands`、`files`、`sessions`、`subagentCatalog` | 把两个菜单从 `VStack` 里挪到卡片的 `.overlay(alignment:.top)`（或 `safeAreaInset` 之上的独立层），并新增高亮索引状态 | 快照：菜单展开时 transcript 不位移；单测：分组排序、↑↓ 索引、Esc |
| C-14 | **P1** | 附件 chip 形态：官方卡内 64×64 圆角缩略图（18 圆删除钮，粗指针常显）；iOS 是卡上方胶囊 + 44pt 删除热区，且只支持图片 | `ComposerAttachments.module.css:1-68`、`ComposerAttachments.tsx:52-60` | `ChatPage.swift:1581-1602, 1756-1758` | 选 3 张图后，iOS 是一条很长的胶囊横排占掉了半行；官方是 64 见方的缩略图排（一眼看到图） | ① rail 在**卡片内**、草稿之上：`padding 2px 10px 0`、`margin-bottom −6`；② 图片 64×64、`radius 20`、`border .5px rgba(0,0,0,.1)`、`object-fit cover`；③ 删除钮 18 圆、`top/right 4`、底 `#545557`、白 `×`，`@media(pointer:coarse)` 常显（手机恒显）；④ 文件 chip 24 高、`min-width 74`、`flex 0 1 180`、`gap 4`、`padding 0 6`、`radius 8`、`border .5px`、文件名 13/20、大小 10px；⑤ 上传中/失败态：`上传中…`/`上传失败，点击重试`（标题/aria）；⑥ 上传未完成 → 发送键 disabled | `pendingAttachments`、`uploads` | 重写 `attachmentStrip` 为卡内 `ScrollView(.horizontal)`；删除热区从 44 收到 18（用 `contentShape` 扩到 30 以内即可，避免违反 44 触控指引时给出替代：整块 chip 可点开预览） | 快照：64/20 圆角、18 删除钮；单测：上传中发送键 disabled |
| C-15 | **P1** | stats pill 的**交互**：官方点开是 264 宽定位小面板（`elevation-prominent`、`padding 12`、12/20 文本、`dt/dd` 两列），iOS 点开是全屏 medium sheet 的 `List` | `StatsPills.tsx:189-231`、`ContextMeter.module.css:46-76`、`stat-dialog.module.css` | `NativeComposerStats.swift:57-96`（`.sheet` + `presentationDetents(.medium)` + `List`） | 点一下 `5 轮 17 步` 会弹起半屏白板，把会话盖住；官方只在药丸上方浮一张小卡 | ① 用 `popover`/自绘浮层：宽 ≤264、`padding 12`、`radius 16`、menu 面 + `elevation-prominent`；② 标题行：图标 14 + 标题 12/20 + 右侧数值 12/20 wt500 `#0F1115`；③ 标题下 0.5px 分隔；④ `dt` 12/20 `#61666B` / `dd` 12/20 `#0F1115` 右对齐、行间 `padding 2 0`、`tabular-nums`；⑤ Esc/点外部关闭、`role=dialog` | `sessionStats` / `tokenUsage` | 把 `.sheet` 换成自绘 `overlay` + 锚点定位（iOS 16+ 可用 `presentationCompactAdaptation` 或直接自绘） | 快照：面板 264 宽不遮全屏；单测：字段顺序与官方 `dl` 一致 |
| C-16 | **P1** | ContextMeter 没有独立成官方那个 13pt 控件，也没有三段色条面板 | `ContextMeter.tsx:89-177`、`ContextMeter.module.css:9-154` | `NativeComposerStats.swift:44-53, 78-87, 114-127` | 上下文占用被压成和 tok/s 同级的小药丸；点开只有 3 行文字，没有官方那条「系统提示词/工具定义/对话消息」比例条 | ① 独立控件：`gap 6`、`padding 1 8`、13/20、`tabular-nums`、`#81858C`；环 14×14、`r 5.5`、`stroke 2`、轨道 `rgba(0,0,0,.12)`、进度 `#81858C`；② 面板：`width: min(264, 屏宽−24)`、`padding 12`、`radius 16`；标题行 `gap 6`：`上下文已用`(12/20 `#81858C`) + `{p}%`(12/20 wt500 `#0F1115`) + 右侧 `~{used} / {window}`(12/20 wt500)；③ 三段条：`margin 10 0 12`、高 4、`radius 999`、`gap 1`、底色 `rgba(38,49,72,.06)`、段色 `rgb(173,178,184)`/`rgb(167,139,250)`/`rgb(77,147,248)`、每段 `min-width 2`；④ 图例三行：8×8 `radius 2` 色块 + 12/20 标签 + 右侧 `~{n}`；⑤ 无 breakdown 时条只显示整段单色 | `contextPressure`、`contextBreakdown`（**iOS 已有**） | 从 `NativeComposerStats` 里把 context 拆成独立 `NativeContextMeter`，放在 dock 里 stats pills 之后（官方恒在、且 activity 展开时隐藏） | 快照：环 14/2、条 4 高、三色；单测：percent 用 `min(100, round(used/window*100))` |
| C-17 | **P1** | goal bar 形态与动作：官方单行 36、menu 面、四个 28 圆图标动作 + 同条内联编辑；iOS 两行 40、实色底、文字按钮、无编辑 | `GoalBar.tsx:86, 88-127, 134-174`、`GoalBar.module.css:5-130`、`locales.ts:4-18` | `ChatPage.swift:1046-1098` | 看不出「目标在编辑中」，也没法改目标；`complete` 的目标还占着一行 | ① 单行 **338×36**、`padding 4px 5px 4px 12px`、`radius 12`、menu 面 + backdrop + `elevation-panel`；② `gap 10`：glyph 14 `#81858C` → label 13/**24** wt500 `#0F1115`（`flex:none`）→ objective 13/20 `#151517` 单行 ellipsis（`flex:1;min-width:0`）；③ 动作 `gap 10`、28 圆、图标 14：`active&&armed` → 暂停；`paused` 或 `active&&disarmed` → 恢复；恒定 → 编辑、清除；④ 编辑态：同条内 `InlineEditor`，`min-height 36;height:auto;align-items:flex-end` + 保存/取消两个 28 圆 + 12/20 红字错误；⑤ phase `blocked` 时整条的 `title` = blockedReason；⑥ phase `complete` → **不渲染**；⑦ 文案：进行中的目标 / 已暂停的目标 / 受阻的目标（**不要**「目标 · 进行中」） | `goal` projection + activation（iOS 无 activation 概念 → 先按 `phase` 退化，见 §8） | 重写 `goalBar` 为单行视图；新增 `runGoalCommand("edit", objective)` 路径（或直接调 `goals/update`） | 快照：36 高、12 圆角、四个 28 圆；单测：phase→按钮组合（4 phase × 2 activation） |
| C-18 | P2 | 页头**排版数值**：44 vs 50 高；标题 17 semibold vs 14/20 wt500；居中 vs 左对齐；无 0.5pt 底边 | `ConversationRoot.module.css:15-23, 64-89, 125-154` | `ChatPage.swift:113-126, 169-170`；`NativeShell.swift:38-43` | 页头高 6pt、标题大 3pt 且更重，整页第一屏的分量不同 | ① 高度 = 10 + 30 + 10 = 50（无 tabs 时）；② 左内距 20、右内距 28（corner 可伸到 12）；③ 标题 14/20 wt500 `#0F1115`、左对齐、`max-width 220` + ellipsis；④ `border-bottom: 0.5px rgba(0,0,0,.12)`；blank 会话无底边；⑤ 移除「点标题改名」（官方不可点，改为长按/更多菜单里改名） | — | 改 `chatHeader` 的 frame/padding/字体，并把改名入口移到 `···` 菜单 | 截图量：页头总高 50、标题基线、底边 0.5 |
| C-19 | P2 | 卡片**圆角/描边/阴影**与官方不是一套值；dark 填充也不同 | `InputBar.module.css:59-63`、`gradient-shadow-text.css:33-40`、`design-platform.css:387-392` | `ChatPage.swift:1219-1223`；`NativeChatTheme.swift:13, 19` | 卡片更「方」、阴影更硬（y 偏移 3 + 6% 黑） | ① `radius 28`（`--dsw-radius-panel`）；② 描边：`0 0 0 0.5px rgba(0,0,0,.10)`（画在阴影里，不加 `border`）；③ 阴影：`0 4px 16px rgba(0,0,0,.03)` + `0 0 24px rgba(0,0,0,.03)`；④ dark：底 `rgb(44,44,46)`、描边 `rgba(255,255,255,.12)`；⑤ 去掉 `shadow(radius: 12, y: 3, black 6%)` | — | 改 3 个修饰符 | 截图取色 + 圆角量测 |
| C-20 | P2 | composer 容器内距与**顶部渐隐**：官方 0 顶内距 + seat 36pt 渐隐；iOS 12pt 实底 | `ConversationRoot.module.css:335-343, 430-453`、`InputBar.module.css:2-11` | `ChatPage.swift:1227-1230` | 消息滚动到输入框后面时是**硬切**；官方是 36pt 渐隐到白 | ① 去掉 `.padding(.top 12)`；② 上方留白由 stack `gap 6`（dock 与卡片之间）承担；③ 在 composer 顶部叠 36pt 线性渐变 `from rgba(255,255,255,0) to #FFFFFF`（dark `rgb(21,21,23)`），px 停靠（不随草稿高度拉伸）；④ 底部内距 4（官方 `.root padding-bottom 4`，安全区另议见 §8） | — | 加一层 `LinearGradient` overlay + 改 padding | 截图：滚动到底后最后一行半透明渐隐 36pt |
| C-21 | P2 | 主题 token 偏差 | `design-platform.css:167, 185-189, 214-225, 269, 274` | `NativeChatTheme.swift:8-21` | 次级文字偏浅、`+` 底色偏冷、暗色 tertiary 偏暗 | tertiary `#9A9AA2` → **`#81858C`**（dark `#ADB2B8`）；secondary `#66666B` → **`#61666B`**（dark `#CFD3D6`）；primary `#111114` → **`#0F1115`**（dark `#F9FAFB`）；selector `#F2F3F5` → **`#F5F6F7`**（dark `#353638`）；border `#E4E4E8` → **`rgba(0,0,0,.10)`**；caption `#ADB2B8` ✓ 已对齐 | — | 改 `NativeChatTheme` 一处（注意 tertiary 全局生效，需回归 Axis 05 的组头/工具行） | 色板单测 + 与 Axis 05 的 T-11 合并验收 |
| C-22 | P2 | `+` 按钮的弹出语义：官方是 `listbox` 型命令面板（`aria-haspopup=listbox`、`aria-expanded`、14px 图标、28 圆 selector 底、hover `interactive-bg-hover-solid`）；iOS 是系统 `Menu`（切换成 dropdown），且塞了「添加图片/添加文件」两项 | `InputBar.tsx:441-454`、`InputBar.module.css:319-340` | `ChatPage.swift:1298-1321` | 系统菜单的圆角/行高/图标与官方面板完全不同；「添加文件」在官方是附件 rail 的拖拽/选择，不占命令菜单 | ① 保留 28 圆 + 14 图标 + `selector` 底（已对齐）；② 点击打开的是卡上方的 listbox 面板（同 C-13 的浮层规格），首分组「指令」，其后再列附件动作；③ `aria-label` = 「添加文件或调用指令」（官方 `input.commands` 原文）、`aria-haspopup=listbox`、`aria-expanded`；④ disabled 时 `opacity .5` | `availableCommands` | 与 C-13 合并实现（同一个浮层组件） | 快照：面板位置与宽度；a11y：aria 属性 |
| C-23 | P2 | model 触发器：官方 13/20 **wt400** + `#61666B` + `max-width: min(360px,45cqw)`，effort 用 `#ADB2B8` 且**先被压缩**；iOS 用 `#111114`（可发送时）且 effort 同名同号同色 | `ModelSelect.module.css:9-63`、`InputBar.module.css:274-277`、`control-row-layout.ts:10-38` | `ChatPage.swift:1491-1512` | 模型名比官方黑得多（抢视觉重心）；`deepseek-flash High` 两个词同权重，没有「主/次」层次 | ① 颜色 `#61666B`（dark `#CFD3D6`）；② wt400；③ `max-width = min(360, 0.45 × 行宽)` = **159**；④ effort 后缀 13/20 `#ADB2B8` 且 `flex-shrink 1000`（先于模型名省略）；⑤ 行内放不下时整段文字换成 16px 图标（`--dsh-composer-model-icon-display`），而不是继续压缩 | — | 改 `modelNameBlock` 的字重/色/上限，effort 单独 `Text` 带 caption 色 | 截图：model 文字色值；窄卡下省略顺序 |
| C-24 | P2 | 权限触发器图标 17 vs 官方 14（触发器内 `svg{width:14;height:14}`），且官方还有 12px chevron + `rotate 180°` 展开动效（120ms） | `PermissionSelect.module.css:44-60`、`:112-118` | `ChatPage.swift:1400-1411` | 图标偏大 3pt，视觉上盖过 `+` | ① 图标 14×14；② chevron 12、`#ADB2B8`、展开 `rotate(180deg)` + `120ms ease`；③ 28 高、`padding 0 4 0 8`、`radius 8`；④ `<460` 容器宽只剩图标（402 已命中，故**不显示档位文字**——与 iOS 一致）；⑤ `aria-label` = 访问模式，当前：{name} | — | 改图标 size 与 chevron 动效 | 截图：图标 14、展开旋转 |
| C-25 | P2 | 上方三 dock 的**宽度与贴合**：官方 338 宽（卡片两侧各内缩 16），queue 方底压卡片 3pt；iOS 的 goal/queue 块与卡片同宽 370 | `TodoPanel.module.css:1-33`、`GoalBar.module.css:5-17`、`QueueDock.module.css:4-37` | `ChatPage.swift:1078-1081`（goal）、`:1126-1129`（queue） | 上方卡片看起来「比输入框宽一圈」，没有官方的「卡片族内缩」层次 | ① 三个 dock 宽 = 屏宽 − 2×16 − 4×8 = **338**，水平居中；② goal/todo 独立圆角 12/16；queue 用 `radius 16 16 0 0` + `margin-bottom: calc(0 − 6 − 3)`；③ dock 之间与卡片之间 `gap 6` | — | 给 dock 加 `.padding(.horizontal, 16)`（16+16=32 → 338） | 截图量：dock 左右各内缩 16 |
| C-26 | P2 | queue 的**折叠/计数头**语义缺失（1 条不该有头、≥2 条默认折叠） | `QueueDock.tsx:128, 139-140, 171-189` | `ChatPage.swift:1107-1116`（恒显「排队中 N 条」） | 只有 1 条排队消息时也多一行头，白白吃掉 20pt 高度 | ① `rowCount === 1` → 不渲染头，行首自带 queue 图标；② `rowCount ≥ 2` → 头 + 默认折叠（`collapsed = true`）；③ 交互中（编辑/请求进行）强制展开；④ 头 `aria-expanded`/`aria-controls`，`disabled` 当交互中 | `inbox` | 并入 C-04 | 单测：1/2/3 条的头与展开态 |
| C-27 | P2 | stats/context 的**字号与数字格式**：官网 12（pill）/13（context）、`tok/s` <10 保一位小数、dock `gap 12`；iOS 统一 11、`tok/s` 取整、`gap 4` | `StatsPills.module.css:5-10`、`ContextMeter.module.css:9-25`、`message-chrome.ts:71-74`、`InputBar.module.css:13-20` | `NativeComposerStats.swift:18, 102`；`ChatPage.swift` 无对应 gap | 数字行比官方细一号且更挤；`0.8 tok/s` 会显示成 `1 tok/s` | ① pill 12pt/20、context 13pt/20；② `tok/s`：≥10 取整、<10 保留 1 位小数（`Math.round(v*10)/10`）；③ dock `gap 12`；④ 保持 `tabular-nums`（iOS `monospacedDigit` ✓）；⑤ `·` 用独立 `Text` 并在两侧各 6pt（`HStack(spacing:6)` + `Text("·")` 已有，只需把 usage 那个挪出来） | — | 改 3 个常量 | 单测：`formatTokensPerSecond(0.84)→"0.8"`、`(54.4)→"54"`；快照：字号 12/13 |
| C-28 | P2 | 可访问性/动效：iOS 无 `accessibilityReduceMotion`、菜单与接管无 `role`/播报、发送态切换无 `announcement`；官方有 `prefers-reduced-motion` 分支（fish 游泳、菜单骨架、删除钮过渡、抽屉过渡） | `HeroShell.module.css:100-107`、`ComposerAttachments.module.css:60-66`、`mobile.module.css:201-206`、`Statistics`/`ContextMeter` 的 `aria-*` | 全库 `accessibilityReduceMotion` 0 命中 | 开「减弱动态效果」后鲸鱼/过渡仍在动；VoiceOver 读不到「排队中」「任务 3 项」这类状态 | ① `@Environment(\.accessibilityReduceMotion)` → fish 静态、菜单骨架停、过渡 0；② 发送/排队/停止切换时各一次 `UIAccessibility.post(notification:.announcement)`；③ 三个 dock 给 `accessibilityElement(children:.contain)` + 语义 label（「任务清单，2 项已完成」「排队消息 3 条」） | — | 统一加环境判断 | 真机开减弱动效 + VoiceOver 走查 |
| C-29 | P3 | activity/usage 的 **compact / detailed** 两档偏好缺失（官方 Settings → 性能显示，`usePerformanceUsage`） | `StatsPills.tsx:237-242, 282-293`、`apply.ts:325-328` | 无（只有一种密度） | 官方可以只留 `tok/s`；iOS 恒定三颗 | 若做：`compact` 只留 `tok/s`（activity）与 `缓存命中 n%`（usage） | 设置存储 | Wave 3 | 单测两档 |
| C-30 | P3 | `conversation.input.left` / `input.right` / `input.activity` 在 shipped composition 里**没有占位者**（只有 experimental 的 voice-input 占 `activity`）——iOS 不需要为它们造结构 | `apply.ts:454-456`、`ui-mobile`/`ui-chat`/`ui-goal` 均未注册（在 `packages/client` 下 grep 这三个 slot 名的 `register({ name: … })`，只命中 `experimental/client-ui-voice-input`） | 无 | 无差异 | **明确不做**；若未来加语音输入，位置=控制行 `.trailing` 内、model 之前 | — | 记录为设计决策 | — |

**计数**：P0 = 5（C-01…C-05）；P1 = 12（C-06…C-17）；P2 = 11（C-18…C-28）；P3 = 2（C-29、C-30，其中 C-30 是「确认不做」）。

## 5. 隐藏/条件控件清单

| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 备注 |
|---|---|---|---|---|
| todo dock | `todos` projection 非空 | `conversation.input.dock` order 0 | ❌ | C-01；数据其实已有（`session/projections`） |
| goal bar | `goal.phase !== 'complete'` 且 goal 非空 | `conversation.input.dock` order 10 | ⚠️ 形态不同 | C-17；`complete` 应消失 |
| goal bar 的内联编辑态 | 点编辑 | 同条内替换为 `InlineEditor` | ❌ | 无编辑入口 |
| queue dock 头 | `rowCount ≥ 2` | panel 顶部 36pt | ⚠️ 恒显 | C-26 |
| queue 三动作 | `queueMutable`（无子 Agent 或 continuable） | 行右侧 28 圆 ×3 | ❌ | C-04；整页不可达 |
| queue 本地 pending 行 | 本地已提交、Host 尚未回执 | 列表末尾 + `发送中…` | ❌ | `ChatPage.swift:2115-2123` 只有字符串标签 |
| plan chip | plan 生效（`pending ? !active : active`） | 控制行 `.modes` | ❌ | C-02 |
| plan 占位文案 | 同上 | 输入框 | ❌ | C-02/C-10 |
| composer 接管（提问） | `pendingInteraction instanceof PendingQuestion` | 顶替整条 composer | ❌（形态为 transcript 卡） | C-05；细节归 Axis 02 |
| composer 接管（审批） | `PendingApproval` | 同上 | ❌（形态为页面上方卡） | C-05；细节归 Axis 03 |
| 接管卡「最小化」 | 待交互期间点最小化 | 卡缩成标题条 | ❌ | 长 transcript 下显著提升可用性 |
| 停 / 发二态 | `running && (empty ‖ blocked)` | 主按钮 | ⚠️ 二态与「并列两键」都不对 | C-09 |
| continuable 子 Agent 的独立停止键 | `running && subagent.address.mode==='continuable'` | 主按钮左侧 | ❌ | 与 C-09 一起做 |
| 忙时 Enter 的「反向」手势 | `⌘/Ctrl+Enter` | 键盘 | ❌ | C-12 |
| 空草稿 `⌘Enter` = 插话整队 | `canSteerQueue` | 键盘 | ❌ | `view-binding.ts:121-124` |
| `/` 触发菜单 | 草稿首个 token 以 `/` 开头 | 卡上方浮层 | ⚠️ 内联块 | C-13 |
| `@` 触发菜单 | 同上 `@` | 同上 | ⚠️ 内联块 | C-13 |
| 命令弹层 `command-popup` | `commandUi` 打开（如 `/model`） | 卡上方浮层 | ❌ | iOS 用系统 Menu 代替 |
| 反馈弹层 `feedback-dialog` | `/feedback` 或点踩 | 卡上方浮层 | ⚠️ | 归 Axis 07 |
| 附件 rail | 有草稿附件 | 卡片内第一行 | ⚠️ 卡外胶囊 | C-14 |
| 上传中/失败态 | 文件上传未 ready / 失败 | 文件卡 + 12/18 文案 | ❌ | C-14；官方发送被 gate |
| 拖放遮罩 | 拖动文件进入 | 卡片上方覆盖 | ❌ | 手机端不适用（记 P3，不列） |
| stats pills | `sessionStats.steps>0` / 有 token 活动 | 卡片下方 dock | ✅（形态不同） | C-15/C-27 |
| ContextMeter | `contextPressure` + `contextWindow` 都有 | 卡片下方 dock，**恒在** | ✅（合并进 stats 行） | C-16 |
| hero 与 workspace chip | `session.blank && phase==='blank'` | 输入区上方居中 | ❌ | C-03 |
| hero 相位隐藏 stats | 同上 | — | — | `InputBar.tsx:521` 只在 `variant==='composer'` 渲染 dock |
| 页头 lineage（子 Agent 面包屑） | 会话 `origin==='subagent'` 或有子 Agent | `conversation.session.header.lineage` | ❌ | C-06；细节归 Axis 04 |
| 页头子 Agent 目录按钮 | 有子 Agent | `header.actions` order 10 | ❌ | C-06 / Axis 04 |
| 页头后台任务按钮 | 有 job | `header.actions` order 20 | ❌ | C-06 / Axis 09 |
| 页头定时任务按钮 | 有 schedule | `header.utilities` order −5 | ❌ | C-06 / Axis 09 |
| 页头「打开方式」 | 有 cwd 且本机有可解析应用 | `header.utilities` order −10 | ❌ | C-06 |
| 页头导出 | 恒有（`session-log-download`） | `header.utilities` order 0 | ✅（在 `···` 菜单里） | C-06 |
| 页头右侧栏展开 | 右侧栏挂载 | `header.corner` | ❌ | C-06 |

## 6. 数据链路缺口

| 事件/字段 | 官方消费方 | iOS 映射/投影 | 缺失后果 | 需要补什么 |
|---|---|---|---|---|
| `session/projections` → `todos` | `TodoDock`（`TodoPanel.tsx:107`） | **同一次响应里已经有**，但 `ChatModel.refreshNativeMetrics` 只取 4 个 key（`ChatModel.swift:1890-1893`） | 任务面板无法渲染 | 在 `refreshNativeMetrics` 里解析 `values["todos"]`，加 `NativeTodoItem{content,status}` |
| `session/projections` → `plan{active,pending}` | `PlanChip`（`PlanModeControl.tsx:34-40`） | 同样已返回，`ChatModel` 丢弃；只有不可达的 `DSHManagementModel.swift:559-561` 读 | plan 态不可见、不可关 | 解析 `values["plan"]`；关闭走 `/plan off` 命令（`runSlashCommand` 已存在） |
| `session/projections` → `inbox{next-turn,next-step}` | `QueueDock`（`QueueDock.tsx:106`） | `DSHManagementModel.refreshQueue` **已实现**（`:460-484`），但只服务不可达的 `SessionQueuePage` | 队列不可见/不可改 | 把这段逻辑搬到 `ChatModel`，并接进 `refreshNativeMetrics`（同一响应，零额外请求） |
| `agent/inbox/spliced`（实时） | 触发队列/消息流刷新 | `ChatModel.handle` 里 `.inboxSpliced` **直接 break**（`:1719-1722`）；`DSHEventMapper.swift:73` 其实已经产出 `.inboxSpliced(messages:)` | 别的端/重载后排的队不会立刻出现 | 在 `.inboxSpliced` 分支上调 `scheduleNativeMetricsRefresh()`（顺带刷新队列与任务） |
| `session/updateQueue`（edit/remove/steer） | `QueueDock.applyAction`（`QueueDock.tsx:142-157`） | `DSHManagementModel.updateQueue` **已实现**（`:485-497`），无 UI 调用者 | 三动作不可用 | 复用该实现，接到新的 `NativeQueueDock` |
| `session/pendingSubmissions`（本地提交回声） | `QueueDock` 的 `pendingQueue`（`:115-122`） | 只有 `queueLabel` 字串（`ChatModel.swift:2107-2123`） | 「发送中…」行与三动作 disabled 态无法正确表达 | 改为 `ChatModel.pendingSubmissions: [PendingSubmission{requestId,text,attachments,placement}]` |
| `settings.busyEnter` | 设置项 + Enter 解析（`submission-policy.ts:60-96`） | `@AppStorage("phone-dsh.composer.busyEnter")`（`ChatPage.swift:30`）✅ 数据在，但**没有 Enter 手势**（C-12） | 偏好无法作用于键盘 | 与 C-12 一起接 `UITextView` 的 return |
| `goal` projection + `useGoalActivation`（armed/disarmed） | `GoalBar.tsx:131-132, 141-154` | `ChatModel.goal`（`HarnessGoal`）有 phase ✓，无 activation | 「已暂停的目标 vs 进行中的目标」无法区分；恢复按钮判定不准 | 先按 phase 退化实现（见 §8），后续补 `goal/activation-changed` 流 |
| `contextPressure` / `contextBreakdown` | `ContextMeter` | `ChatModel.swift:1892-1893` ✅ 已有 | 只差面板样式 | 无需补数据 |
| `sessionStats` / `tokenUsage` | `ActivityPill` / `UsagePill` | ✅ 已有（`:1890-1891`） | — | 数字格式对齐（C-27） |
| `imageLimits`（图片上限） | `InputBar.tsx:100, 220-235`（前置拒绝 + toast） | iOS 硬编码 20 张 / 20MB / 200MB（`ChatPage.swift:1771-1783`），不是投影值 | 与部署配置不一致时提示文案/上限错 | 从 projection 读 `imageLimits`（或至少在文案里标注） |
| `notice`（info/error 条） | `InputBar.tsx:385-389`（`notice.level==='info'` 显示在卡上方） | iOS 只有 `attachmentError` / `fileImportNotice` 两个自造行 | 官方那种 `role=status` 的信息条没有归宿 | 增加 `composerNotice` 状态与 12/18 信息条 |
| `promptError` → Toast（`session/writer-held` 等） | `InputBar.tsx:109-122` + `Toast` | iOS 用 `errorBanner`（页面上方，13pt 警示色） | 位置/形态不同（官方是锚在卡片上的 toast + 警告图标） | 归 Axis 07 统一处理，这里只记录 |

## 7. 实施顺序建议

**Wave 1（P0，先把「官方有、我们没有」的入口补齐；全部可复用已存在的 projection 通道，零新增 RPC）**

1. **数据先行**：`ChatModel.refreshNativeMetrics()` 一次响应里多解析 `todos` / `plan` / `inbox`；`.inboxSpliced` 触发刷新（`ChatModel.swift:1719-1722, 1890-1893`）。这一步不加 UI 就能被单测覆盖。
2. **C-01 todo dock**（纯展示 + 折叠，最快见效）。
3. **C-02 plan chip + plan 占位文案**（依赖 `/plan off` 命令，已存在）。
4. **C-04 queue dock**（迁移 `DSHManagementModel.refreshQueue/updateQueue` 到 `ChatModel`，替换 `queuedStrip`，实现折叠 + 三动作 + pending 行）。
5. **C-05 composer 接管**（与 Axis 02/03 合流：先做外壳几何与「顶替整条 composer」的布局，内部状态机由 02/03 填）。

**Wave 2（P1 的「同一个 composer，不同尺寸」：一次性把卡片/控制行/页头几何改到官方值）**

6. **C-07 → C-08 → C-09**：重排控制行（行内发送、access mode 最右）、合并 primary 按钮二态、卡片 98 高 28 圆角。这三条必须一起改，否则中间态更丑。
7. **C-11 → C-12**：`TextEditor` → `UITextView` 包装，拿回 16pt、`returnKeyType = .send`、Enter/⌘Enter/Shift+Enter 语义。
8. **C-10**：占位文案 4 档纯函数（顺带修全角逗号）。
9. **C-18 → C-19 → C-20 → C-21**：页头 50/14-20/左对齐、卡片描边阴影、36pt 渐隐、token 校正（C-21 与 Axis 05 的 T-11 合并验收）。
10. **C-06**：页头四段槽位（先把已有能力搬进正确槽位，缺口入口等 Axis 04/09 的结论）。

**Wave 3（P1 的浮层与 dock 细节 + P2）**

11. **C-13 + C-22**：统一的「卡上方 listbox 浮层」（slash/@/`+` 共用）。
12. **C-14**：附件 rail 挪进卡片、64 缩略图、18 删除钮、上传态。
13. **C-15 + C-16 + C-27**：stats 面板改定位小卡、context 独立成 13pt 控件 + 三段条、字号与 `tok/s` 格式。
14. **C-17**：goal bar 单行化 + 四个动作 + 内联编辑 + phase 文案。
15. **C-23 … C-28**：model/权限触发器、dock 宽度与贴合、queue 折叠、a11y/动效。
16. **C-29 / C-30**：确认不做或最后做。

**不要做的事**（写进合同，避免后续返工）：`conversation.input.left/right/activity` 不造结构（C-30）；页头标题不做点击改名（官方不可点，C-18）；手机端不要给 composer 加底部安全区之外的额外留白（见 §8 决策点）。

## 8. 未知与需确认

1. **官方手机页头里抽屉键的左右位置**：`ui-mobile/src/client/index.ts:10` 的注释说它注册在「session header's left strip (`conversation.session.header.left`)」，但实际注册的是 `conversation.session.header.actions`（`:104-111`），而 `actions` 在 `titleCluster` 里位于 `crumbs` **之后**（`ConversationRoot.module.css:83-89` + `ConversationSession.tsx:127-129`）。按源码 = 标题右侧；按注释 = 标题左侧。**需真机/官方截图确认**（本仓库没有官方 402pt 截图，见 §0 校正）。
2. **`ios-chat-official.png` 的定性**：它是 iOS 自绘页（`INDEX.md:77`），不是官方 Web 截图。若要逐像素验收，需要一张真正的官方 402pt Web 截图（playwright + `apps/web` dist，本轮未跑，环境未改）。本报告所有官方数值均为 CSS 推导。
3. **底部安全区**：官方 PWA 注入 `viewport-fit=cover`（`ui-mobile/src/index.ts:39`），但 `mobile.module.css` 只处理 `safe-area-inset-top`，composer 座位是 `bottom: 0` + 根 `padding-bottom: 4px`（`:2-11, 143-159`）——即官方在 iPhone 上**不避让** home indicator。iOS 原生用 `safeAreaInset` 会自动留 34pt。这是**产品决策点**：严格对齐官方 = 4pt（会被 home indicator 压住）；可读性优先 = 8~34pt。建议采用 `max(8, safeAreaBottom)` 并在合同里注明「有意偏离」。
4. **goal 的 activation（armed/disarmed）**：官方 `GoalBar` 的暂停/恢复按钮依赖进程内 activation 流（`ui-goal` 的 `useGoalActivation`/`goal/activation-changed`），iOS 没有这个概念。退化方案（按 `phase` 决定按钮）会与官方在「active 但 disarmed」时不一致。需要产品确认是否接受退化。
5. **官方手机端 goal bar 的可读性**：338×36 单行 + 4 个 28 圆动作按钮（=142pt）+ label（如「进行中的目标」约 78pt），objective 只剩约 60pt ≈ 4–5 个字。源码推导如此，但**是否真的这么挤**需要官方 402pt 截图确认；若确实如此，是否照抄（牺牲 objective 可读性）需要拍板。
6. **`--dsw-alias-separator-primary`**：`StatsPills.module.css:57` 使用该变量，但 `design-platform.css` / `gradient-shadow-text.css` 里**没有定义**（`grep -rn separator-primary *.css` = 0）。因此官方 `·` 分隔符实际继承 pill 的 `#81858C`。iOS 现在用独立 `Text("·")`（继承 tertiary），效果等价——不需要额外动作，但如果官方后续补该 token，颜色会变。
7. **`Edit` 类动作在手机端的命中区**：官方 goal/queue 的图标按钮是 28×28（`GoalBar.module.css:107-120`、`QueueDock.module.css:219-232`），低于 iOS HIG 的 44pt 建议。照抄还是放大到 44（用 `contentShape` 扩热区、视觉仍 28）需要产品确认。建议：视觉 28、热区 44。
8. **`question`/`approval` 接管卡的可滚动高度**：`max-height: min(60vh, 520px)`（`QuestionComposer.module.css:22`）。iOS 若用 `60% × 874` ≈ 524 → 取 520 一致；但键盘弹起后 60vh 会再缩，官方也有同样问题（`ConversationRoot` 的 seat 是 sticky/fixed）。需要真机确认键盘 + 接管卡同时出现时的行为。
9. **未实测**：本轮没有跑 `xcodebuild`（HEAD 已知编译失败，见 `docs/receipts/ios-baseline-screens/INDEX.md:5-14`），也没有跑官方 `playwright`。所有 iOS 尺寸均为代码推导 + 截图目测；所有官方尺寸为 CSS 推导。**没有任何一处声称「实测」**。

## 附录 A — 402pt 像素规格总表（一次改到位用）

| 元素 | 官方值（402pt） | iOS 现值 | 文件 |
|---|---|---|---|
| 页头高 | 50（10 + 30 + 10） | 44 | `ConversationRoot.module.css:15-28` / `ChatPage.swift:170` |
| 页头左右内距 | 20 / 28（corner 可 −16） | 16 / 16 | 同上 / `:169` |
| 页头底边 | `0.5px rgba(0,0,0,.12)`（blank 无） | 无 | `:22` / — |
| 标题 | 14/20 wt500 `#0F1115`，左对齐，max 220 | 17 semibold `#111114`，居中 | `:125-154` / `ChatPage.swift:117-126` |
| 面包屑间隔 | `gap 4`，`/` 14/20 `#ADB2B8` | 无 | `:102-123` / — |
| 页头图标按钮 | 36×36 / radius 10 / 16 图标 | 32×44 / 无底 / 20 图标 | `HeaderMenuButton.module.css:1-37` / `ChatPage.swift:132-136` |
| composer 卡 | 370×98 / radius 28 / 白 / soft elevation | 370×94 / radius 22 / 白 / 6% 黑 r12 y3 | `InputBar.module.css:45-77` / `ChatPage.swift:1219-1223` |
| 卡内上内距 | 8 | 4 | `:55` / `ChatPage.swift:1188` |
| 文本→控制行 gap | 12 | 0（靠 padding top 10） | `:52` / `ChatPage.swift:1204` |
| 草稿区 | 36…336 / `4 8 0 14` / 16pt（手机）行高 24 | 36…336 / `4 14/8` / 14pt 行高 24 | `:128-134, 169-185` + `mobile.module.css:170-175` / `ChatPage.swift:1164-1188` |
| 控制行 | 34 + `2 8 6` = 42 / gap 8 | 32 + top 10 bottom 12 = 54 / gap 8 | `:256-272` / `ChatPage.swift:1199-1206` |
| `+` 按钮 | 28 圆 / `#F5F6F7` / 14 图标 | 28 圆 / `#F2F3F5` / 14 图标 | `:319-331` / `ChatPage.swift:1311-1316` |
| 权限触发器 | 28 高 / icon 14 + chevron 12 / `#61666B` | 28 高 / shield 17 + chevron 12 / `#66666B` | `PermissionSelect.module.css:1-60` / `ChatPage.swift:1400-1408` |
| model 触发器 | 28 高 / 13-20 wt400 `#61666B` / max `min(360,45cqw)`=159 | 28 高 / 13 wt(默认) `#111114` / 无上限 | `ModelSelect.module.css:9-30` / `ChatPage.swift:1495-1512` |
| 发送/停止 | 34 圆 `#4176E6` / 白 16×16 viewBox / disabled .4 / `translateY(-2)` | 34 圆 `#3964FE` / arrow.up 15 bold / .4 | `InputBar.module.css:377-405` / `ChatPage.swift:1241-1261` |
| 停止（第二态） | 同 34 蓝圆 + `rect 10×10 rx3` | 24 圆 `#66666B` + `stop.fill` 9 | `InputBar.tsx:481-496` / `ChatPage.swift:1263-1294` |
| 上方 dock 宽 | 338（左右各内缩 16） | 370 | `TodoPanel.module.css:6-21` 等 / `ChatPage.swift:1078-1081` |
| todo 面板 | 338 / radius 16 / menu 面 + blur / `6 12` body / header gap 10 | 无 | `TodoPanel.module.css:1-123` / — |
| goal 条 | 338×36 / radius 12 / `4 5 4 12` / 动作 28×4 | 370×40 / radius 10 / `0 10` / 文字按钮 | `GoalBar.module.css:5-130` / `ChatPage.swift:1046-1082` |
| queue panel | 338 / `radius 16 16 0 0` / 方底压卡 3 / header 36 / 行 36 | 370 宽的独立 28 高行 | `QueueDock.module.css:4-135` / `ChatPage.swift:1107-1132` |
| stats dock | `padding-top 4` / gap 12 / pill 12-20 `#81858C` | gap 4 / 11pt | `InputBar.module.css:13-20` + `StatsPills.module.css:5-55` / `NativeComposerStats.swift:18, 99-112` |
| context meter | 13/20 / 环 14 `r5.5` `stroke2` | 11pt / 环 14 `stroke2` | `ContextMeter.module.css:9-44` / `NativeComposerStats.swift:114-127` |
| 顶栏渐隐 | 36pt 线性渐变到 `bg-base` | 无 | `ConversationRoot.module.css:442-453` / — |
| 附件缩略 | 64×64 / radius 20 / 删除 18 | 胶囊 + 44 热区 | `ComposerAttachments.module.css:12-45` / `ChatPage.swift:1585-1598` |
| 菜单浮层 | 宽 370 / `bottom 100%+4` / pad 4 / 行 34 / max 400 | 内联块 / radius 14 / 6 行 | `MenuView.module.css:1-64` / `ChatPage.swift:1831-1874` |
| 接管卡 | ≤338×`min(60vh,520)` / radius 20 / `6 32 10` | 无 | `QuestionComposer.module.css:1-46` / — |
| 抽屉宽 | `min(78vw, 300px)` = 300 | 320 | `mobile.module.css:78` / `NativeShell.swift:232` |

## 附录 B — 验收场景（16 条）

| # | 场景 | 断言（可像素验收的部分加粗） |
|---|---|---|
| 1 | 空会话（blank） | hero 出现：fish **34×25**、标题 **26/32 wt500**、预览徽 **12/18 + radius 999**、workspace chip **28 高**、输入区 **min 52**；**stats pills 不渲染**，只留 ContextMeter；页头无底边 |
| 2 | 有历史、空闲 | 页头 **50 高**、标题 14/20 左对齐、底边 **0.5pt**；卡片 **370×98 / radius 28**；发送键在控制行内、**34 圆**、实心蓝 |
| 3 | 运行中（草稿空） | 主按钮变**停止**：同 34 蓝圆 + 白色圆角方；只有 1 颗按钮；页头**不出现**运行状态 chip（官方无）；transcript 尾部有运行指示（Axis 05） |
| 4 | 运行中（草稿有字） | 主按钮变**发送**，`aria-label` = **排队发送**（`busyEnter=queue`）或 **插话发送**（steer）；仍然只有 1 颗按钮；占位符**仍是**「发消息或创建任务, …」 |
| 5 | 运行中 + 2 条排队 | queue dock 出现在卡片上方：**338 宽**、计数头 **36 高**、默认**折叠**、方底压卡 **3pt**；展开后每行 **36 高**、右侧三颗 **28 圆** 动作；只有 1 条时**无计数头** |
| 6 | 队列编辑 | 点编辑 → 行内换 `InlineEditor` + 保存/取消两个 28 圆；保存后调 `session/updateQueue{kind:'edit'}`；非纯文本消息编辑键 disabled 且 title=「包含非文本内容，暂不支持编辑」 |
| 7 | 权限等待 | composer 被接管：底部只剩接管卡（**≤338 宽 / radius 20 / padding 6-32-10**），**输入卡片与所有 dock 消失**；最小化后只剩标题条 |
| 8 | 问题等待 | 同上接管；问题选项列表可滚、`max-height min(60vh,520)`；键盘弹起后卡片不被遮 |
| 9 | 附件（3 张图） | 卡内 rail：**64×64 / radius 20**、删除钮 **18 圆** 恒显（粗指针）；上传中发送键 disabled；上传完成恢复 |
| 10 | slash 菜单 | 浮层锚在卡片上方 **4pt**、宽度 = 卡片 **370**、`padding 4`、行 **34**、分组标题 **11/16**；↑↓ 移动高亮、Esc 关闭；**transcript 不位移** |
| 11 | `@` 引用 | 同上浮层；分组标题（指令/技能/子智能体）；描述右对齐 12/18；`Tab` 可钻取目录 |
| 12 | 模型切换 | 触发器 13/20 wt400 `#61666B`、effort 后缀 `#ADB2B8` 且先被省略；展开后菜单从**上方**弹出（`side="top"`），选中项带勾 |
| 13 | access mode 切换 | 触发器在**发送键右侧最右**；图标 **14** + chevron 12（展开 rotate 180，120ms）；402pt 下**不显示档位文字**；确认高危档走二次确认 |
| 14 | plan mode | chip 出现：**28 高 / min-width 34 / radius 8 / 底 #E4EDFD / 字 #4176E6 / 14 图标**；占位符变「描述你的任务以生成计划」；点击 = 关闭（`/plan off`）并恢复占位符；失败时条内红字「退出计划模式失败」 |
| 15 | goal bar | 单行 **338×36 / radius 12**；label 13/24 wt500；objective 单行 ellipsis；动作 **28 圆**（暂停/编辑/清除；恢复按 phase）；编辑态同条内展开；`complete` 时整条消失 |
| 16 | 长草稿 / 键盘 / 深色 | 草稿长到 **336** 封顶并内部滚动（官方 14 行），卡片不再增高；键盘弹起时只有 composer 上移、页头不动；深色下卡 `rgb(44,44,46)`、描边 `rgba(255,255,255,.12)`、菜单面 `rgba(48,49,54,.94)` |

## 附录 C — 官方中文文案对照表（iOS 逐字对齐用）

| key | 官方 zh 原文 | iOS 现值 | 出处 |
|---|---|---|---|
| `placeholder.default` | `发消息或创建任务, / 调用指令, @ 文件或对话` | `发消息或创建任务，/ 调用指令，@ 文件或对话`（全角逗号） | `ui-conversation/locales.ts:20` / `ChatPage.swift:1747` |
| `placeholder.hero` | `描述你想要构建的内容, / 调用指令, @ 文件或对话` | 无 | `:23` |
| `placeholder.plan` = `hint.plan` | `描述你的任务以生成计划` | 无 | `:18-19` |
| `placeholder.unavailable` | `会话不可用` | 无 | `:21` |
| `placeholder.parentOffline` | `父会话已离线，无法继续发送；仍可停止当前运行` | 无 | `:22` |
| `placeholder.steerQueue` | `Cmd/Ctrl+Enter 插话发送全部排队消息` | 无 | `:25` |
| `placeholder.workspace` | `选择一个工作区开始` | 无 | `:24` |
| `input.commands`（`+` 的 aria） | `添加文件或调用指令` | `添加指令、引用或附件` | `:26` / `ChatPage.swift:1321` |
| `input.send` | `发送消息` | `发送消息` ✓ | `:29` / `:1259` |
| `input.send.queue` | `排队发送` | `排入下一轮`（且只用于死代码 `sendButtonLabel`） | `:30` / `ChatPage.swift:1746-1754` |
| `input.send.steer` | `插话发送` | `补充当前任务` | `:31` / 同上 |
| `input.stop` | `停止生成` | `停止执行` | `:28` / `ChatPage.swift:1293` |
| `todo.title` | `任务` | 无 | `:81` |
| `todo.progress.done/active/pending` | `{done} 已完成` / `{active} 进行中` / `{pending} 待处理` | 无（`SessionActivityPage.swift:210-224` 有「已完成/进行中/待办」但不是该组件） | `:82-84` |
| `queue.count` | `{n} 条排队消息` | `排队中 {n} 条` | `:357` / `ChatPage.swift:1112` |
| `queue.sending` | `发送中…` | `发送中…`（`ChatModel.swift:2116`，标签） | `:358` |
| `queue.edit` / `remove` / `steer` | `编辑排队消息` / `删除排队消息` / `插话发送` | `编辑` / `移除` / `设为当前引导`（且不可达） | `:361-366` / `SessionsPage.swift:670-676` |
| `queue.steer.unavailable` | `仅运行中可插话发送` | 无 | `:367` |
| `goal.phase.active` | `进行中的目标` | `目标 · 进行中` | `ui-goal/locales.ts:5` / `ChatPage.swift:1086` |
| `goal.phase.active.disarmed` | `已暂停的目标` | 无 | `:6` |
| `goal.phase.paused` | `已暂停的目标` | `目标 · 已暂停` | `:7` / `:1087` |
| `goal.phase.blocked` | `受阻的目标` | `目标 · 已阻塞` | `:8` / `:1088` |
| `goal.action.pause/resume/edit/clear` | `暂停目标` / `恢复目标` / `编辑目标` / `清除目标` | `暂停` / `继续` / 无 / `清除目标`（a11y） | `:11-14` / `ChatPage.swift:1063-1075` |
| `plan.chip.label` | `计划` | 无 | `ui-plan/locales.ts:5` |
| `plan.chip.on.aria` | `计划模式已开启，按下关闭` | 无 | `:17` |
| `plan.chip.on.title` | `计划模式已开启 — 点击关闭（/plan off）` | 无 | `:18` |
| `plan.chip.exitFailed` | `退出计划模式失败` | 无 | `:19` |
| `context.aria` | `上下文已用 {percent}%` | `10%`（只有数字） | `locales.ts:47` / `NativeComposerStats.swift:48` |
| `context.used` / `system` / `tools` / `messages` | `上下文已用` / `系统提示词` / `工具定义` / `对话消息` | `上下文已用` ✓ / `系统提示` / `工具` / `对话` | `:48-51` / `NativeComposerStats.swift:80-86` |
| `stats.counts` | `{turns} 轮 {steps} 步` | `{turns} 轮 {steps} 步` ✓ | `ui-chat/locale.ts:77` / `NativeComposerStats.swift:23` |
| `stats.cacheHit` | `缓存命中 {percent}%` | `缓存命中 {n}%`（前置 `· ` 在同一 Text 内） | `:78` / `:38` |
| `stats.dialog.title` / `usageTitle` | `会话统计` / `Token 用量` | `会话统计` / `Token 用量` ✓ | `:79-80` / `NativeComposerStats.swift:90` |
| `stats.dialog.llmTime/toolTime/ttft/speed` | `模型用时` / `工具调用用时` / `首 token 平均（TTFT）` / `输出速度（TPS）` | 同 ✓ | `:81-84` / `:64-67` |
| `message.tokensPerSecond` | `{tps} tok/s` | `{Int} tok/s` | `:176` / `NativeComposerStats.swift:26` |
| `message.turnUsage.*`（用量面板 dt） | `本轮用量` / `缓存命中` / `未缓存输入` / `缓存读取` / `缓存写入` / `输出` / `{count} tok` | `未缓存输入`/`缓存读取`/`缓存写入`/`输出`/`合计` + `tok` 后缀 | `:177-186` / `NativeComposerStats.swift:71-77` |
| `hero.headline` / `preview` / `chooseWorkspace` | `探索未至之境` / `预览版` / `选择工作区` | 无 | `locales.ts:77-79` |
| `slash.menu` 分组 | `指令` / `技能` / `子智能体`；`正在加载…`；`进入目录`；`Tab` | 无分组；`正在读取 DSH 命令…` | `ui-input-trigger/locales.ts:7-16` / `ChatPage.swift:1837` |
| `settings.enter.title/description` | `繁忙时的发送行为` / `智能体运行时 Enter 键和发送按钮的行为；Cmd/Ctrl+Enter 使用另一行为` | `发送消息时` / `排队的消息会在当前任务后处理；补充说明会尝试引导正在运行的任务。` | `locales.ts:73-74` / `SettingsPage.swift:96-103, 442-453` |
| `settings.enter.queue/steer` | `排队发送` / `插话发送` | `排到下一轮` / `补充当前任务` | `:75-76` / `SettingsPage.swift:98-99, 445-446` |
