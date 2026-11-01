# Axis 04 — 子 Agent / inbox / 收到新消息：iOS Session 对齐审计

> 审计对象：官方 DSH Web UI 基线 `7be5505b0b`（`0.2.1-rc.2`）的 **会话页里由子 Agent、后台任务、定时任务、goal、外部事件产生的可见形态**，对照 iOS `examples/probe-app/PhoneDSHProbe` 的当前实现。
> 视觉基准：手机宽度 402pt（CSS px ≈ iOS pt）。全部结论给两侧 `file:line`；说"没有"的地方给搜索证据。
> 本报告只审计、未改任何源码；未跑测试/构建（静态阅读 + 源码 CSS 解析）。

## 0. 结论摘要

- **P0 × 7、P1 × 7、P2 × 5**（另有 2 条 P3）。核心结论：官方"子 Agent 出现在消息流"不是一张卡，而是 **inbox 分流 + turn-trigger 行 + 进程组标题 + 页头 lineage/catalog + 子会话侧栏 + 只读 composer** 六件套；iOS 这六件套 **一件都没有**，只有一处不可达的 `SessionActivityPage` 列表。
- **最致命的一条是数据到 UI 之间的断桥**：`agent/inbox/spliced` 已经被 `DSHEventMapper` 映射成 `Kind.inboxSpliced`（`DSHEventMapper.swift:67-73`），却在 `ChatModel.handle` 里被 `case .userMessage, .inboxSpliced: break` 直接丢弃（`ChatModel.swift:1719-1721`）；历史投影 `NativeTranscriptProjector` 也不处理该事件（`NativeTranscriptProjector.swift:20-146`，`default: continue` 在 144 行）。**数据链路是通的（`session/page` 不过滤事件类型，`history.ts:392-445`），丢的是 UI 层。**
- 官方"子 Agent 完成"落进父会话的形式是 **一条 `user/message`**，`source.kind = 'subagent-settled'`、`form = 'notice'`、带一行 `summary`（`continuation-messages.ts:24-56,115-185`）。iOS 历史重放能把这类消息读出来，但归成"上下文 · N 条"分组、源名不映射、无时间无解释（`ChatPage.swift:453-465`、`NativeChatTimelineChrome.swift:22-66`）；实时流里则是 0 显示。
- 页头层面：官方在 402pt 下渲染 **会话层级 breadcrumb（14px/20px，子会话 12px/18px）** + **子 Agent 目录按钮（`{count} 个子智能体`，12px/18px，28px 高，运行中前置 14px 转圈 StateDot）** + **后台任务按钮**（`ConversationSession.tsx:73-129`、`SubagentHeaderLineage.tsx:497-720`、ui-jobs `index.ts:36-40`）。iOS 页头是 44pt 高、17pt semibold 标题、运行状态点、蓝色省略号菜单（`ChatPage.swift:113-171`），语义完全不同。
- 仓库里 **没有官方 web 截图**：`docs/receipts/ios-baseline-screens/ios-chat-official.png` 实际是 iOS `-uiPreview chat.official` 的自绘页（`INDEX.md:77`、`VISUAL.md:45`），**不能作为官方像素基线**；本报告的官方像素全部从源码 CSS 解析（并用本地 shipped bundle `web-build.json` 校验 commit 一致）。

## 1. 审计范围与方法

**读了什么（官方）**

- 消息分类与 inbox：`packages/client/ui-chat/src/client/conversation-nodes/message.ts`（`waking` → `turn-trigger`）、`inbox.ts`（next-step / next-turn claim）、`event-projection.ts`（`contextProducer`/`contextForm`）。
- 触发通知：`chat/turn-trigger.ts`、`chat/TurnTriggerNodeView.tsx`、`TurnTriggerNodeView.module.css`、`chat/ContextBody.tsx`、`chat/ContextInjectionRow.tsx` + CSS。
- 进程聚合：`conversation-nodes/turn-process.ts`、`process-activity.ts`、`contract/turn-process.ts`、`chat/TurnProcessNodeView.tsx` + CSS、`chat/ChatGroupSeat.tsx` + CSS、`chat/step-process.ts`、`presentation-policy.ts`。
- 工具行：`ui-tool/.../toolviews/details-row.tsx`、`models/control-details-model.ts`、`models/tool-call-model.ts`、`models/details-card-model.ts`、`components/ToolRow.tsx` + CSS、`components/ToolDetails.module.css`；共享 chrome `ui-primitives/src/DisclosureRow.*`。
- 子 Agent 目录/lineage/侧栏/只读 composer：`ui-subagent/src/client/{index.ts,SubagentHeaderLineage.tsx,SubagentHeaderLineage.module.css,SubagentReadOnlyComposer.tsx,SubagentReadOnlyComposer.module.css,sidebar-chat/index.tsx,locales.ts}`；页头容器 `ui-conversation/.../ConversationSession.tsx`、`ConversationRoot.module.css`。
- 手机宽度：`ui-mobile/src/client/{mobile.module.css,HeaderMenuButton.tsx,HeaderMenuButton.module.css,DrawerScrim.module.css,push.ts,frame.ts}`。
- 数据与事件：`packages/core/agent/src/types.ts:89-103`（`agent/inbox/spliced` schema）、`packages/subagent/subagent/src/{continuation-messages.ts,projection-types.ts,control-types.ts}`、`packages/api/session-controller/src/{history.ts,list.ts}`。
- 随附范围（不把 experimental 当默认）：`packages/bundle/web-app/cordis.patch.yml:380-381,548-600`、`presets/standard.patch.yml:33-44,89-110`。
- token：`ui-theme/src/styles/{base.css,design-platform.css}`。
- 行为证据（测试）：`ui-chat/tests/turn-trigger.client.spec.tsx:30-80`、`ui-subagent/tests/{conversation-ui.client.spec.tsx,browser-plugin.client.spec.ts,sidebar-chat.client.spec.tsx}`。

**读了什么（iOS）**

- `ChatPage.swift`（页头 113-171、分组 422-472、渲染 777-805、回到最新 876-887、`ContextInjectionCard` 2363-2411、`ToolRunRow` 2349-2361）。
- `ChatModel.swift`（`handle` 1667-1800、`loadSessionHistory` 1416-1463、queue 标签 2107-2123）、`NativeTranscriptProjector.swift`、`NativeConversationModels.swift`、`NativeChatTimelineChrome.swift`、`NativeMessageRows.swift`、`NativeToolCallModel.swift`、`NativeToolDetailCards.swift`、`NativeChatTheme.swift`、`NativeShell.swift`（RunStatusDot 47-76）、`SessionsPage.swift`、`DSHManagementModel.swift`、`SessionActivityPage.swift`。
- `Sources/PhoneDSHAgentCore/DSH/{DSHEventMapper.swift,DSHMessageSourceClassifier.swift,DSHRemoteHarness.swift}`、`Sources/PhoneDSHAgentCore/AgentHarness.swift`。

**搜索证据（"没有"的穷尽证明）**

```
$ grep -rn "subagent|list_agents|wait_agent|send_message|interrupt_agent|spawn_teammate|team_task" \
    --include=*.swift examples/probe-app/PhoneDSHProbe/ Sources/
→ 命中仅：NativeToolCallModel.swift:51（"子 Agent"）、DSHManagementModel.swift:575(subagentCatalog 解码)、
  662/659(interruptSubagent)、NativeConfigurationModel.swift(设置项文案)、SessionActivityPage.swift(不可达页)
→ 无 send_message / interrupt_agent / list_agents / wait_agent 任何特判。

$ grep -rn "steering" examples/probe-app/PhoneDSHProbe/ Sources/PhoneDSHAgentCore/
→ 仅 ChatModel.swift:1318（本地"补充说明"行）、1582（trajectory 分类）、NativeTranscriptProjector.swift:20,27-29
→ 无 inbox / next-step / next-turn / claimedHuman 任何概念。

$ grep -rn "\"origin\"|origin ==" --include=*.swift examples/probe-app/PhoneDSHProbe/
→ 0 结果（子会话 origin 从未解码）。

$ grep -rn "turn-trigger|turnTrigger" --include=*.swift examples/ Sources/
→ 0 结果。
```

**截图对照（仅作观察，不作事实）**

- `ios-chat-default.png`：iOS 页头（左抽屉 / 中标题 / 右运行点+省略号）实测 44pt 行高、左右 16pt。属"截图观察"。
- `ios-chat-official.png`：**不是官方页**（见 `INDEX.md:77`：它是 `chat.official` 预览，transcript 空白）。据此否决"用该图当官方基线"的做法。

## 2. 官方基线（按 surface 列）

字体基准：正文 `--dsh-content-font-size = 14px`（fallback 定义在 `TurnTriggerNodeView.module.css:25` 等处），次级 `--dsh-content-font-size-secondary = 13px`（`design-platform.css` 尾部公式：`min(size−1, max(13, size−2))`），小号 `--dsw-font-xxs-12 = 12px/18px`，代码 `--ds-font-family-code`。
圆角：`xs 4 / sm 8 / md 12 / lg 16 / xl 20 / panel 28`（`base.css:23-30`）。
颜色（light → dark）：`label-primary #0F1115 → #F9FAFB`、`label-secondary #61666B → #CFD3D6`、`label-tertiary #81858C → #ADB2B8`、`label-caption #ADB2B8 → #81858C`、`border-l1 rgba(0,0,0,.04) → rgba(255,255,255,.06)`、`border-l2 rgba(0,0,0,.1) → .12`、`interactive-bg-hover rgba(38,49,72,.06) → rgba(255,255,255,.08)`、`markdown-code-block #F9FAFB → #1B1B1C`（`design-platform.css:166-282, 284-...`）。
402pt 内容列宽：`.scroll` 横向 padding = `16px + --dsh-composer-side-clearance(16px)` = **32px/侧**（`ChatView.module.css:22-28`、`ConversationRoot.module.css:384-390`）→ **消息列 ≈ 338pt**；输入卡宽 = 列宽 + 32 = **370pt**（`--dsh-composer-card-max-width`，`ConversationRoot.module.css:388,516`）。

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| A1 | **turn-trigger 行**（非人类消息唤醒了新 Turn） | `message.ts:76-91,90`（`waking`→kind `turn-trigger`）、`message.ts:113-130,125`、`TurnTriggerNodeView.tsx:40-58`、`TurnTriggerNodeView.module.css:1-35` | 一条可展开的独立 notice：`[icon 14] gap10 [title] … auto → [time 12px] gap? [chevron 12]`；展开后 `[explanation 12px] + [content 12px pre-wrap, max-h 240, 可滚]` | 容器：`border .5px border-l1`、`radius 20`、`bg = turn-trigger-bg(#F9FAFB)`；header padding `12px 16px`、gap 10、色 `label-tertiary`、hover→`label-secondary`；title 14px（行高未声明，继承）；time `12px/18px`、`margin-left:auto`；chevron 12、展开 `rotate(180deg)`；body `padding 0 16px 12px 40px`；explanation `margin 8px 0`、`12px/18px`、`label-secondary`；content `12px/18px`、`max-height 240px`、`overflow auto`、`pre-wrap`、`overflow-wrap anywhere`；过渡 `background-color/color 100ms ease`；reduced-motion 关闭过渡 | 标题按 source 家族：`收到执行请求`(默认) / `继续执行目标` / `收到任务消息` / `收到团队消息` / `子任务状态更新` / `收到 GitHub 事件` / `收到外部事件` / `自动化任务` / `后台任务状态更新` / `插件状态更新`；解释固定 `这条通知触发了本轮回复。`；时间 `HH:mm`（同一天）或 `{m}月{d}日 HH:mm` / `{y}年{m}月{d}日 HH:mm` | 默认折叠；`aria-expanded` + `aria-controls`；点击整行切换；`<time dateTime=ISO>`；hover 背景变 `interactive-bg-hover` | `user/message`（`source.kind ≠ user`）且被 `inbox-next-turn` 认领，或 idle-steer 的 step1 纯非人批次（`message.ts:83-86`） |
| A2 | 同上，10 种 source 家族 → 图标 | `turn-trigger.ts:17-64`、`TurnTriggerNodeView.tsx:14-25` | 图标映射表 | 一律 14×14，颜色继承 tertiary | — | `request=IconContextInjectionOutlineRegular`、`goal=IconGoalOutlineRegular`、`agent=IconPaperPlaneOutlineRegular`、`team/subagent=IconAgentPresetOutlineRegular`、`github=IconBranchOutlineRegular`、`webhook=IconGlobeOutlineRegular`、`schedule=IconClockOutlineRegular`、`job=IconQueueOutlineRegular`、`plugin=IconCordisPluginOutlineRegular` | 同 A1 |
| A3 | **运行中被注入的非人类消息**（父会话 running，子 Agent 发消息 / 子 Agent 完成） | `message.ts:76-91`（非 user → `context` 节点）、`ContextInjectionRow.tsx:70-110`、`ContextInjectionRow.module.css:1-58`、`event-projection.ts:60-76` | 24px 单行 disclosure：`[16px leading 图标 14] gap6 [标题 13/24] gap8 [2px 圆点] gap8 [source 13/24] gap8 [summary 13/24 单行省略]`；展开 body = 代码块容器 + `OpaqueBody`（模型原文 + source 字段 dl） | 行高 24px；标题 `13/24`、`label-tertiary`；圆点 2×2、`label-caption`、`margin 0 8px`；source/summary `13/24` tertiary、单行 ellipsis；body：`width calc(100% − 22px)`、`max-height 141px`、`margin 4px 0 0 22px`、`padding 10px 16px 12px 12px`、`radius 12`、`bg markdown-code-block`、`font 400 11px/16px code`；source 字段 dl `gap 2`、`border-top .5px border-l2`、`padding-top 8`、key 最小宽 96px、色 `label-caption` | 标题 `上下文注入`（role=recall 时 `跨会话召回`）；source 名 = `source.kind` 原文（未注册 producer 时，`event-projection.ts:71-75`），即 `subagent-settled` / `agent-message` / `goal` / `schedule` / `tool-jobs`；`notice` form 时右侧还有一行 `summary`（`ContextBody.tsx` noticeSummary） | 默认折叠；hover 图标→chevron、色→secondary；`prefers-reduced-motion` 关过渡 | `user/message` with `source.kind ≠ user`，未被 next-turn 认领 |
| A4 | **进程组标题里的 subagent 计数 / "协调子智能体"** | `process-activity.ts:8-24`（`subagent`/`subagent_*` → `subagents` 类）、`ChatGroupSeat.tsx:44-52,150-175`、`ChatGroupSeat.module.css:1-100,136-150`、`step-process.ts:11-33`、`locale.ts:18,45,31` | 24px 级组头：`[16px leading(图标 14 / hover 换 chevron)] gap6 [标题]`；标题文本由活动分类排名合成 | 图标 `IconAgentPresetOutlineRegular` 14；标题 14px、`label-tertiary`、hover `label-secondary`；leading 16×16；chevron 与图标叠放、opacity 100ms 交叉；运行中文本走 `TextShimmer`；展开时 `padding-bottom 8px`；组体 `max-height min(400px,50vh)`、组内 flow gap 6、可滚 + 上下 24px 渐隐 mask | 运行中：`正在协调子智能体` / `准备协调子智能体`；完成：`已协调子智能体`；与其他类并列时取前 3 类：`正在读取文件，并准备运行命令` / `已读取文件、已编辑文件` / `…等` | 计数不出现在组头文本里；`{count} 个 subagent` 这条 locale **存在但 shipped UI 未使用**（`locale.ts:153-154`，全仓仅 locale 与 `.d.ts` 命中） | `tool/call` 中 `name==='subagent'` 或 `subagent_*`（`contract/turn-process.ts:44-49`） |
| A5 | **Turn 折叠控制（"已完成，用时 X"）** | `TurnProcessNodeView.tsx:20-60`、`TurnProcessNodeView.module.css:1-40`、`locale.ts:64-66,155-157` | 一行 button：`[label] [chevron 14]`，底部 0.5px 分隔线 | 高 `calc(33px + font-delta)`、`padding 0 0 8px`、`border-bottom .5px border-l2`、label 14/24 单行省略、chevron 14×14 `margin-left 4`、展开 rotate 180；数字用 code 字体 + `tabular-nums`；颜色 tertiary→hover secondary；不可折叠时 `disabled` | `已完成` / `已完成，用时 {duration}` / `处理失败` / `已停止` | 展开/收起受“工作详情”模式控制；运行中/停止/出错时强制展开（`turnProcessAlwaysOpen`，`contract/turn-process.ts:53-60`） | `turn/start` + 本 Turn 的 `tool/call`/`assistant/message`（`turn-process.ts:209-300`） |
| A6 | **`subagent` 工具行**（创建子 Agent） | `details-row.tsx:98`（注册 key `subagent`）、`tool-call-model.ts:103`（标题 key）、`control-details-model.ts:147-151`、`locales.ts:157` | 24px ToolRow：`[16 leading 图标 14] gap6 [标题 13/24] gap8 [2px 点] gap8 [summary 13/24 省略]`；展开 body = `ToolDetails` 卡（`radius 16`、`border .5px border-l1`、`bg #F9FAFB`、`13/20`） | 图标 `IconAgentPresetOutlineRegular` 14；标题 `label-tertiary`→hover `label-secondary`；summary 单行 ellipsis；`ToolDetails`：`margin 4px 0 4px 4px`、item `padding 10px 14px`、`max-height 320px`；badge 11px（`ToolDetails.module.css:153-174`） | 标题 `创建子智能体`；成功启动时 summary = `<prompt 首行>` + ` · 已启动`，字段 `智能体 ID`；非 receipt 时 summary = `智能体回复`，body 为回复 markdown + 分组 `任务内容` = prompt；caption `调用结果` | 运行中 spinner/shimmer；`preparing` 无展开箭头；error 用 first line + `state-error-primary` | `tool/call{name:'subagent'}` + `tool/result`（render 文本 `started subagent <id>`，`tool-subagent/src/index.ts:273`） |
| A7 | **`send_message` 工具行** | `details-row.tsx:27-31,100`（`TEAMMATE_TOOLS` → `IconUsersOutlineRegular`）、`control-details-model.ts:133-139` | 同上 ToolRow + receipt 卡 | 图标 `IconUsersOutlineRegular` 14；badge 色 `state-success-primary #22C55E`（info/success/warning 见 `ToolDetails.module.css:171-174`） | 标题 `发送消息`；summary = `<agent_id> · 消息已送达`；description = 消息正文 | 成功 badge `消息已送达`（success）；成功文本匹配 `message delivered to agent <id>`（`tool-subagent-control/src/index.ts:53-56`） | `tool/call{name:'send_message'}` |
| A8 | **`interrupt_agent` 工具行** | `details-row.tsx:27-31,101`、`control-details-model.ts:140-142` | 同上 | 同上 | 标题 `中断智能体`；badge `已请求中断`（warning，`#F59E0B`） | 匹配 `interrupt requested for agent <id>` | `tool/call{name:'interrupt_agent'}` |
| A9 | **`list_agents` 工具行** | `details-row.tsx:27-31,99`、`control-details-model.ts:22-41` | ToolRow + 实体列表卡 | 每行：title=label（无 label 时 id）、subtitle=id、badge=state；summary=`{count} 个智能体` | 标题 `查看子智能体`；summary `{count} 个智能体`；空 `(no subagents)` → `0 个智能体`；行文本正则 `id [state] parent=… depth=… — title` | 状态 badge 文案来自 `detail.status.*`（`locales.ts:186-197`） | `tool/call{name:'list_agents'}`（`tool-subagent-control/src/list-agents.ts:87`） |
| A10 | **页头 lineage / breadcrumb** | `ConversationSession.tsx:25-43`（`deriveAncestry`）、`:69-130`（titleRow）、`ConversationRoot.module.css:14-20`（header 76px）、`:102-152`（crumbs） | `header` grid，左 padding 20 右 28：`[titleCluster: crumbs + headerActions] [headerUtilities] [headerCorner]`；crumbs 内 `crumbSeg` 用 `/` 分隔 | header `min-height 76px`（有 tab 时）/`padding-bottom 10`（无 tab）；titleRow `min-height 30px`；`.crumbs{gap 4}`；`.crumb`: `max-width 220px`、`padding 4px 8px`、`radius 12`、`14px/20px`、色 tertiary；**current crumb** `font-weight 500`、`label-primary`；`.crumbSubagent` 覆盖为 **12px/18px**；`.crumbSep` `14px/20px`、`label-caption`；headerActions `gap 8`；手机端**无任何覆盖**（`mobile.module.css` 全文 1-207 无 header/crumb 规则） | `aria-label="会话层级"`；`/` 分隔 | 非当前 crumb 是 `<button>`，点击 `open(sessionId)`；当前 crumb 是 `<span>`（不可点，`ConversationSession.tsx:80-86` 注释说明原因） | `SessionListState.byId[].{id,displayTitle,origin,parentId}`（`service.ts:27-54`），循环上溯到非 subagent 根 |
| A11 | **子 Agent 目录（catalog）按钮 + 下拉树** | `ui-subagent/src/client/index.ts:82-93`（header.actions, order 10）、`SubagentHeaderLineage.tsx:760-783`（`SubagentCatalogAction`）、`:454-756`（`CatalogDropdown`）、`.module.css:1-140` | 根会话：`[StateDot(14, running)] [count 12px] [chevron 12]`；子会话：`[当前子 Agent 标题 12px/500 主色] [switcher 图标 16]` + 同级目录按钮 | trigger/switcherTrigger：`min-height 28px`、`padding 3px 2px`、`radius 8`、`font-size 12px`、`line-height 18px`、`gap 4`、tertiary→hover primary；switcher `max-width 244px`、`font-weight 500`、`label-primary`；menu：`width 336px`、`max-width min(400px, 100vw−32)`、`max-height min(560px, 100vh−140px)`、`padding 4`、`radius 16`、`box-shadow elevation-prominent`、`bg rgba(248,249,250,.58) + backdrop-filter blur(40px) saturate(150%)`（`::before` 承载）；行 `min-height 44px`、`padding 6px 7px 6px 9px`、`radius 12`、`12px/17px`；`.summary/.metrics` `10px/15px`、`label-tertiary`、`tabular-nums`；children 缩进 `margin-left 16` + 0.5px 树线；空态/错误 11px/16px | 计数：`{count} 个子智能体`；运行中读屏 `{count} 个子智能体，正在运行`；模式 `一次性` / `可继续` / `外部任务` / `模式未知`；状态 `正在运行` / `已完成` / `当前未运行`；行副标题拼接 `title · mode · activity`；指标 `{tok} · {duration}`；菜单 `在侧边栏打开`；加载 `正在加载子智能体…`；错误 `无法加载子智能体` + `重试`；迁移 `需要迁移` | visible 条件：catalog 有子项或 error（空 loading 不显示，`SubagentHeaderLineage.tsx:617-624`）；hover 150ms 开 / 120ms 关，点击 pin；键盘 ↑↓ Home End Escape；`role="tree"/"treeitem"`、`aria-level`、`aria-expanded`、`aria-current`；行点击 `openChild` 进子会话、右侧按钮 `openChildAside` 开侧栏 | `projectionsBySession[parent].subagentCatalog[]`（`projection-types.ts:12-30`）+ `sessions.byId[id].running` / `subagentTiming` |
| A12 | **子会话只读 composer** | `index.ts:37-56`（`selectReadOnlySubagent`）、`:94-102`（composer 注册，priority −10）、`SubagentReadOnlyComposer.tsx:19-31`、`.module.css:1-20`、`locales.ts` | 一条横向提示条替代输入卡 | `margin 0 24px 20px`、`min-height 54px`、`padding 10px 16px`、`gap 8`、`border .5px border-l4`、`radius 16`、`bg bg-layer-1`、`13px/20px`、`label-tertiary`；`strong` 为 `label-primary`、`font-weight 510` | 一次性：标题 `一次性子智能体记录` + `一次性任务不支持后续消息，可在这里查看完整执行记录。`；父离线：`此子智能体暂时只读` + `父会话当前不在线，重新打开父会话后即可继续发送消息。`；未知：`此子智能体暂时只读` + `读取子会话后才能确定是否可继续。` | `role="status"`；`mode==='continuable'` 且 `parentAvailable!==false` 时不接管（用普通 composer）；运行中的父离线可继续子会话仍给 Stop | `session.subagent.address.mode` + `session.subagent.parentAvailable` |
| A13 | **子会话侧栏 chat（手机 = 右侧抽屉）** | `ui-subagent/src/client/sidebar-chat/index.tsx`（资源地址 `dsh-resource://subagentchat/session/{child}?parent=&mode=`）、`mobile.module.css:94-110` | 右侧栏 tab，移动端变整高抽屉 | 抽屉：`position fixed`、`top/bottom 0`、`right 0`、`width min(100vw, 480px)` → 402pt 下 **全宽 402**、`transform translateX(102%)` → 0、`transition 240ms cubic-bezier(.4,0,.2,1)`、`box-shadow elevation-prominent`；无圆角；遮罩 `z 35`、`color-mix(bg-overlay 70%)`；`reduced-motion` 关过渡 | tab 标题 = 子 Agent label，回落 `聊天` | 点遮罩关闭；`canOpen` 校验地址 | `sessions.retain(address)`（`sidebar-chat/index.tsx:102-119`） |
| A14 | **父会话运行中指示 / 深度求索中** | `RunningStatus.tsx:22-46`、`ChatView.module.css`（`running/runningDivider/runningContent`）、`locale.ts:89-90` | 内容尾部：`[细分隔线] [whale tail] [shimmer 文本]` | shimmer + 每秒刷新用时；文本 14px | `深度求索中` / `深度求索中，用时 {duration} ···` | 只在 running 时挂载；`role="status" aria-live` | turn 状态 |
| A15 | **回到底部（跟随中断）** | `ChatView.tsx:238-248`、`ChatView.module.css:249-296` | 固定右下角圆形按钮 | `34×34`、`radius 100px`（round corner-shape）、`bg button-floating-fill`、`box-shadow elevation-panel`、图标 `IconChevronDownOutlineRegular`、`bottom 16`、`padding-right max(32px, (100%−列宽)/2)`；hover `button-floating-hover` | `aria-label="回到底部"`（`locale.ts:88`） | `followingTail` 为 false 时出现 | scroll follow 状态 |

**随附判定（重要）**

- 随附：`ui-subagent`（`cordis.patch.yml:380-381`）、`ui-mobile`（`:595-596`）、`subagent` / `subagent_fork` / `send_message` / `interrupt_agent` / `list_agents`（`presets/standard.patch.yml:89-103`，默认 preset = `standard`，`:agent-preset-registry.default`）。
- **不随附**：`wait_agent`、`spawn_teammate`、`team_task_*` 的**工具**（只存在于 `packages/experimental/tool-agent-team/src/index.ts:250`、`packages/experimental/agent-team/`，未出现在 `cordis.patch.yml` / presets）。但 `tool.call.toolview` 对它们的注册在 ui-tool 里存在（`details-row.tsx:111-115`）→ shipped bundle 里有 5 个不可达的 keyed 注册。`team-message` source 同属 agent-team，`webhook`/github 属 `packages/experimental/webhook`，均不随附。

## 3. iOS 现状（按 surface 列）

| # | Surface | iOS 实现（file:line） | 现在画成什么 | 行为 | 与官方的差 |
|---|---|---|---|---|---|
| B1 | 非人类 user 消息（实时） | `ChatModel.swift:1719-1721` | **什么都不画**。注释写 "The composer already appends the local prompt row; these durable projections exist for transcript/audit consumers." | 事件被 `break`；`items` 不新增 | 官方 A1/A3 两种形态全无。子 Agent 完成、子 Agent 发消息、goal round、schedule 到点、job 完成，**实时全都看不见** |
| B2 | 非人类 user 消息（历史重放） | `NativeTranscriptProjector.swift:20-45`、`DSHMessageSourceClassifier.swift:12-20` | `.context` item，title `"DSH context · \(source)"` | 归入 `timelineRows` 的 `.contexts` 分组（`ChatPage.swift:453-465`） | 与官方 A3 形似而神不似：无 `form`、无 `summary`、无 producer 映射、无 source 字段；也不区分"唤醒"（A1） |
| B3 | 上下文分组行 | `NativeChatTimelineChrome.swift:22-66` | `DisclosureGroup`：`[square.stack.3d.up caption] [上下文 footnote medium] [· N 条 footnote]` + 单条时才显示源名，`minHeight 44`、`.font(.footnote)`(=13pt)、`padding(.leading,-4)` | 组内逐条：`arrow.turn.down.right` + 源名（仅 4 种可映射）+ 复制按钮 + 正文 | 官方每条是独立 24px 行（A3），**不合并成组**；iOS 合并后 N 条只剩一个头，且头文案是"上下文"而非官方标题体系 |
| B4 | 源名映射 | `NativeChatTimelineChrome.swift:105-115` | 仅 `user-approval/你同意的`、`file/读过的文件`、`command/命令输出`、`search/搜到的` 四种；其余 `nil` → **不显示源名** | — | `subagent-settled`/`agent-message`/`goal`/`schedule`/`tool-jobs` 全部无源名，用户只看到"上下文 · 1 条" |
| B5 | 单条上下文卡（未被合并时） | `ChatPage.swift:2363-2411` | `info.circle` 14pt + `"上下文注入 · \(source)"` 13pt + `chevron.right` 12pt semibold + 高 28pt | 展开 = 横向+纵向可滚 `Text`，caption monospaced，`maxHeight 360` | 官方 A3 是 24px 行 + 11/16 code body（max-h 141）+ 圆点 + summary；iOS 行高 28pt、无圆点、无 summary、无 2×2 分隔点、body 高 360 |
| B6 | turn-trigger | 无 | — | — | A1/A2 全缺（`grep turn-trigger` 0 结果） |
| B7 | inbox 分流 | 无 | — | — | `agent/inbox/spliced` 只被映射成 `Kind.inboxSpliced(messages:)`（`DSHEventMapper.swift:67-73`），**丢掉 `target`/`start`/`removedCount`/`outcome`**；`ChatModel` 丢弃；projector 不处理 → next-step steering / next-turn waking / context 三态无法判定 |
| B8 | 进程组 / Turn 折叠 | `ChatPage.swift:453-472`、`2349-2361` | 所有 toolCall/toolResult **平铺成一组连续行**（`ToolRunRow` 只是 `VStack(spacing:6)` 循环 `NativeToolCallRow`），**无组头、无计数、无折叠、无时长** | 无折叠交互 | 官方 A4/A5 双件套全缺。子 Agent 运行中父会话的"正在协调子智能体"不存在 |
| B9 | 工具行 | `NativeToolDetailCards.swift:6-35`、`NativeMessageRows.swift:5-55` | 24pt 行：`[ZStack 16×16 图标 14/展开时 chevronDown 旋转] padding-trailing 6 [title 13pt 固定宽] [2×2 点 8px 间距] [summary 13pt tertiary shimmer]` | 点击展开（0.16s easeOut） | **行几何与官方 DisclosureRow 高度一致**（16+6 / 13/24 / 2×2 dot / 8px）——这是正面证据；差在：title `fixedSize(horizontal:true)` 不截断、无 hover 图标→chevron 交叉、无组头 |
| B10 | subagent 工具行 | `NativeToolCallModel.swift:51` | 标题 `"子 Agent"`，`variant = .others`，图标 `sparkle`(DSHSparkle)，summary = 参数里第一个字符串 | 展开 = `NativeIOCard`（pretty JSON IN/OUT） | 官方 `创建子智能体` + `IconAgentPresetOutlineRegular` + receipt（`已启动` + `智能体 ID`）/`智能体回复` card。**文案、图标、卡型三处不同** |
| B11 | send_message / interrupt_agent / list_agents | `NativeToolCallModel.swift:44-63`（无特判 → `default` → variant `.others` → 标题 `工具调用`） | 三者的行标题都是 **`工具调用`**，summary 为参数首个字符串，图标 sparkle | 展开 = 通用 IN/OUT | 官方 A7/A8/A9 三张不同卡（`发送消息`+送达 badge / `中断智能体`+warning badge / `查看子智能体`+实体列表） |
| B12 | 页头 | `ChatPage.swift:113-171` | `ZStack`：居中标题（17pt semibold `#111114`，左右各 104pt 预留）+ 左 `sidebar.left` 20pt（32×44） + 右 `RunStatusDot`（11pt 文案 + dot）+ 蓝色 `ellipsis` 20pt（44×44）；整行 **44pt**、左右 16pt | 点标题改名；省略号菜单只有 2 项（导出 / 本会话设置） | 官方 A10/A11 全缺：无 breadcrumb、无 lineage switcher、无子 Agent 目录按钮、无后台任务按钮；行高 44 vs 30、标题 17pt/600 vs 14pt/500、无 0.5px 底部分隔线、无 10/20/28 padding 节奏 |
| B13 | 子 Agent 列表 | `DSHManagementModel.swift:575-580`、`SessionActivityPage.swift:66-82` | `ActivityRow(title: label ?? "子 Agent \(id.prefix(8))", detail: "\(mode) · \(id)", status: mode)`，正文里一个"中断子智能体"按钮 | **页面不可达**：`showActivity` 只在 `ChatPage.swift:51` 声明、`292` 用作 sheet，全仓无 `showActivity = true`（grep 仅 2 处命中） | 官方 A11 是页头一级入口 + 树 + 状态点 + tokens/时长 + 点进子会话；iOS 是"能列出来但点不到"的页，且无 running 状态、无 tokens/时长、无跳转 |
| B14 | 子会话身份 | `AgentHarness.swift:110-145`（`HarnessSessionRequest`/`HarnessSession` 无 parent/child）、`DSHManagementModel.swift:11-20`（`ManagedSession.parentSessionID`） | 列表能解码 `parentSessionId`，但**从不解码 `origin`、从不使用 `parentSessionID` 做任何分组/导航** | `SessionsPage` 把子会话当普通会话平铺（`SessionsPage.swift:198,255,539`） | 官方 A10 的 breadcrumb 与 A11 的树都依赖 `origin/parentId/displayTitle`，iOS 拿得到但不用 |
| B15 | "收到新消息" | `ChatPage.swift:795-887`、`876-887` | 跟随滚动由 `nearBottom`/`userScrolledAway` 决定；离开底部时出现胶囊按钮 `Label("回到最新", systemImage:"arrow.down")` 12pt semibold accent、`padding 12/8`、`radius 12`、`1pt separator 描边`、`bottom 12` | 新行到达 + 在底部 → 自动滚；不在底部 → 只出现按钮，**无未读计数、无"新消息"提示、无锚点提示** | 官方 A15 是 34×34 圆钮、纯图标、`elevation-panel`；且官方在 `TurnNavigator` 侧有 turn 级导航与 `data-chat-following-tail` 状态。iOS 的胶囊在形态与层级上都不同 |
| B16 | 主题 token | `NativeChatTheme.swift:7-28` | primary `#111114/#F4F4F5`、secondary `#66666B/#A1A1AA`、tertiary `#9A9AA2/#81858C`、caption `#ADB2B8/#81858C`、code `#F6F6F8/#1D1D20`、border `#E4E4E8/#3A3A3E`、accent `#3964FE` | body 14 / secondary 13 / caption 12 / code 12 | tertiary 亮色 **`#9A9AA2` vs 官方 `#81858C`（Δ ≈ 25/24/26）**；code surface `#F6F6F8` vs `#F9FAFB`；无 `border-l1 .04` 这种 hairline 语义 |

## 4. 差距清单（核心交付）

> "像素/行为对齐合同"列写的是**可直接落到 SwiftUI 的目标值**，不是"参考官方"。

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
|---|---|---|---|---|---|---|---|---|---|
| SB-01 | **P0** | 非人类 user 消息在**实时流**被丢弃（子 Agent 完成/发消息、goal、schedule、tool-jobs 全不可见） | `message.ts:76-91,125`；`continuation-messages.ts:115-185`；`turn-trigger.ts:43-46` | `ChatModel.swift:1719-1721` | 派了子 Agent、子 Agent 干完了，父会话页**一点反应都没有**；只有重新进会话才可能看到一行"上下文" | `case .userMessage(let text, let source)`：`source != "user"` 时不 `break`，先入 `turnTriggers` 缓冲（`source/kind/time/summary/form`），并让 `.inboxSpliced` 至少把 `inserted[]` 投成待分类队列；**禁止**把非人消息画成右侧用户气泡 | `HarnessEvent.Kind.userMessage(text:source:)` 已有 source（`DSHEventMapper.swift:62-66`），需补 `summary`/`form` | 在 `handle` 里新增 `.turnTrigger`/`.contextInjected` 两个 kind；先把当前 `break` 改成 `recordIncoming(event)` | 单测：喂一条 `user/message{source.kind:'subagent-settled'}` 后 `model.items` 必须新增一条 `.turnTrigger`；再喂 `source.kind:'user'` 仍走右侧气泡 |
| SB-02 | **P0** | 没有 turn-trigger 这一行（图标/标题/时间/展开 body/解释文案） | `TurnTriggerNodeView.tsx:40-58`；`TurnTriggerNodeView.module.css:1-35`；`turn-trigger.ts:17-64`；`locale.ts:53-63` | 无（`grep turn-trigger` 0） | 官方"这条通知触发了本轮回复"的整条信息带完全缺失 | 新建 `NativeTurnTriggerRow`：容器 `.background(#F9FAFB)`、`border 0.5pt #0000000A`、`cornerRadius 20 (continuous)`；header `padding 12/16`、`gap 10`、内容色 `label-tertiary→#81858C`、按下/高亮 `interactive-bg-hover`；图标 14×14；title 14pt；time `12pt/18pt` 右对齐 `HH:mm`（同日）/`M月d日 HH:mm`（同年）/`yyyy年M月d日 HH:mm`；chevron 12pt，展开 `rotate 180°`；body `padding leading 40 / trailing 16 / bottom 12`、说明 12pt/18pt `#61666B`、正文 12pt/18pt `pre-wrap`、`maxHeight 240` 可滚；`transition 100ms ease`，`accessibilityReduceMotion` 关掉 | source.kind、time、content、summary | 先做 subagent-settled / schedule / tool-jobs / goal 四个家族（shipped），team/webhook 留空 | 快照：一条 `subagent-settled` 渲染后 header 高 ≈ 41pt（12+17+12，见 §8 未知）、展开后正文可见；VoiceOver 读 `title + time` |
| SB-03 | **P0** | inbox 三态分流缺失（next-step steering / next-turn waking / context），iOS 连"这条消息是唤醒还是注入"都无法判断 | `inbox.ts:115-135`（两个 target）；`inbox.ts:40,79-113`（claim/`claimedHuman`）；`message.ts:76-106` | `DSHEventMapper.swift:67-73`（丢 target/start/removedCount/outcome）、`ChatModel.swift:1719` | 同一条子 Agent 消息，官方在 idle 显示"子任务状态更新"卡、在 running 显示 24px 上下文行；iOS 两者都无，将来接入也会画错形态 | 补 `HarnessInboxSplice{target:'next-step'|'next-turn', start, removedCount, inserted:[HarnessUserInput], outcome}`；`ChatModel` 维护 `claimedByNextTurn:Set<id>`/`claimedByNextStep:Set<id>`；判定规则照抄 `message.ts:83-86`（`idleSteer` 的 5 个条件含 `claimedHuman == false`） | `agent/inbox/spliced` 全字段（`packages/core/agent/src/types.ts:96-103`） | 把 `Kind.inboxSpliced` 扩成带 target 的结构体，不要新增第 4 个事件；`handle` 里维护 claim 表，`userMessage` 到达时查表决定 kind | 3 条单测：idle+next-turn → `.turnTrigger`；running+next-step → `.context`；running+next-step+人类 → 右侧气泡 |
| SB-04 | **P0** | 子 Agent 运行状态在消息流里不存在（无组头、无"正在协调子智能体"、无 shimmer、无 subagent 计数用于折叠判定） | `process-activity.ts:8-24`；`ChatGroupSeat.tsx:44-52,150-175`；`step-process.ts:11-33`；`locale.ts:18,45`；`contract/turn-process.ts:44-49` | `ChatPage.swift:453-472`（只有平铺 `.tools`）、`2349-2361`（`ToolRunRow` 无头） | 用户看不出"模型正在等一个子 Agent"，也看不出这一轮叫了几个子 Agent | 工具区加一层 `NativeProcessGroup`：组头 `[16×16 图标区(14pt IconAgentPreset 等)] gap6 [14pt 标题 tertiary]`，运行中 `TextShimmer` + 文案 `正在协调子智能体`，完成 `已协调子智能体`；`subagent`/`subagent_*` 计入 subagent 类而不是工具类；组体 `maxHeight min(400pt, 50vh)`、组内 gap 6、上下 24pt 渐隐 | `tool/call.name`（已映射，`DSHEventMapper.swift:89-93`）即可，无需新事件 | 先做"运行中标题 + 完成后标题"两态，折叠交互可与 SB-10 合并 | 喂 `subagent` + `tool/call` 各一条：组头出现 `正在协调子智能体`；`turn/end` 后变 `已协调子智能体` |
| SB-05 | **P0** | 子会话导航链路全缺：breadcrumb、lineage switcher、catalog 树、侧栏 chat | `ConversationSession.tsx:25-43,69-130`；`ConversationRoot.module.css:102-152`；`SubagentHeaderLineage.tsx:760-783`；`ui-subagent/index.ts:82-102`；`sidebar-chat/index.tsx`；`mobile.module.css:94-110` | `ChatPage.swift:113-171`（无）、`DSHManagementModel.swift:918`（`parentSessionID` 解码后未用）、`grep origin` 0 | 从父会话无法进子会话，也不知道自己在子会话里、更回不到父会话 | 页头左侧插入 crumb 段：`/` 分隔（14pt/20pt `#ADB2B8`）、crumb `padding 4/8`、`cornerRadius 12`、非当前 14pt/20pt `#81858C`、当前 14pt/20pt 500 `#0F1115`、**子会话 crumb 12pt/18pt**、单 crumb `maxWidth 220`；有子 Agent 时右侧加目录按钮 `12pt/18pt`、`minHeight 28`、`padding 3/2`、`cornerRadius 8`、运行中前置 14pt 转圈点；目录用 bottom sheet（手机替代 336×≤560 的 popover），行 `minHeight 44`、`12pt/17pt`、副标题/指标 `10pt/15pt` | `subagentCatalog[]`、`SessionSummary.origin/parentId/displayTitle`、`running`、`subagentTiming` | Wave 2；先做"标题 + 返回父会话"最小可用，再做树 | 在子会话里：crumb 显示 `父标题 / 子标题`，点父标题回到父会话；根会话里目录按钮显示 `N 个子智能体` |
| SB-06 | **P0** | 唯一列出子 Agent 的页面**不可达**，且内容不足（无 running/时长/tokens、不能进子会话） | `SubagentHeaderLineage.tsx:497-720`；`locales.ts:22,31-33,45-48` | `ChatPage.swift:51,292`（`showActivity` 从未置 true）；`SessionActivityPage.swift:66-82`；`DSHManagementModel.swift:575-580` | 用户**零入口**看到"这个会话有哪些子 Agent" | 见 SB-05 的目录合同；若保留 `SessionActivityPage`，必须从页头"更多"菜单给出入口，并为每行加 `StateDot`（running=14 转圈 / completed=绿 / inactive=灰）、`{tok} · {duration}`、点行进子会话 | `subagentCatalog[].activity`（**当前被丢弃**）、`subagentTiming`、`tokenUsage` | 1 行修复即可先给入口（`Button("会话动态"){ showActivity = true }`），内容再补 | 手测：页头菜单 → 会话动态 → 能看到子 Agent；或直接进 SB-05 的目录 |
| SB-07 | **P0** | `subagent`/`send_message`/`interrupt_agent`/`list_agents` 四个 shipped 工具行的**标题、图标、详情卡**全错 | `tool-call-model.ts:103-106,121`；`details-row.tsx:27-31,98-101`；`control-details-model.ts:22-41,133-151`；`locales.ts:157-160,248-267` | `NativeToolCallModel.swift:44-63`（`subagent`→`子 Agent`，其余→`工具调用`）；`NativeToolDetailCards.swift:6-35` | 用户看到"工具调用"三个字 + 一坨 JSON，完全不知道刚才派了谁、发给了谁、结果如何 | 标题：`创建子智能体` / `发送消息` / `中断智能体` / `查看子智能体`；图标：`subagent`=`IconAgentPresetOutlineRegular`、另三个=`IconUsersOutlineRegular`（14pt）；`subagent` 成功 → 卡内 title=prompt、badge `已启动`（`#4176E6`）、字段 `智能体 ID`=child id；非 receipt → `智能体回复`（markdown）+ 分组 `任务内容`；`send_message` → summary `<id> · 消息已送达`（badge `#22C55E`）+ 正文；`interrupt_agent` → `已请求中断`（`#F59E0B`）；`list_agents` → summary `{n} 个智能体` + 每行 label/badge | 仅 `tool/call{name}` + `tool/result` 文本（已有） | 纯 UI 层改造，无数据依赖 → 可最先做 | 4 条快照：4 个工具名分别渲染出不同标题+图标；`send_message` 结果含 `message delivered to agent` 时出"消息已送达" |
| SB-08 | P1 | 历史重放把这类消息合并进"上下文 · N 条"，无源名、无时间、无解释、无 form 语义 | `ContextInjectionRow.tsx:70-110`；`event-projection.ts:60-76`；`ContextBody.tsx`（notice/opaque） | `ChatPage.swift:453-465`；`NativeChatTimelineChrome.swift:22-66,105-115` | 重进会话后看到"上下文 · 1 条"，点开是一段英文流程话术，不知道是谁触发的 | 每条独立成行（24pt）；标题 `上下文注入`；圆点 2×2 `#ADB2B8`、`margin 0 8`；source 13pt `#81858C`（= `source.kind` 原文或用映射表补 `子Agent完成`/`目标续跑`/`定时任务`/`后台任务`）；`notice` form 时右侧 summary 13pt 单行省略；body `margin 4/0/0/22`、`maxHeight 141`、`radius 12`、`bg #F9FAFB`、11pt/16pt code | `source.kind`、`source.summary`、`source.form`、`senderSessionId`（projector 均可从 data 读到） | 与 SB-02 共用渲染器，只在"是否有时间/解释"上分叉 | 重放一条 `subagent-settled`：出现 24pt 行 + 源名 + summary 一行 |
| SB-09 | P1 | 页头排版/结构整体不符（44pt vs 30px 标题行、17pt/600 vs 14pt/500、无 0.5px 分隔线、无 action 带） | `ConversationRoot.module.css:14-20`；`ConversationSession.tsx:69-130`；`mobile.module.css`（无 header 覆盖） | `ChatPage.swift:113-171` | 一眼看出不是官方 | 标题行 `minHeight 30`、水平 padding `20/28`、底部 `0.5pt border-l3`；标题 14pt/20pt + weight 500、色 `#0F1115`；整块 `padding-top 10`；动作区 `gap 8`；手机抽屉按钮 `36×36`、`cornerRadius 10`、icon 16（官方 `HeaderMenuButton.tsx:29-46`、`.module.css:1-30`） | `displayTitle` | 与 SB-05 一起做（否则标题区域要改两次） | 量高：页头应有 30pt 标题行 + 10+10 padding = 50pt（无 tab） |
| SB-10 | P1 | 无工具过程折叠（缺 TurnProcess 的"已完成，用时 X"+0.5 分隔线+chevron） | `TurnProcessNodeView.tsx:20-60`；`TurnProcessNodeView.module.css:1-40`；`locale.ts:64-66` | `ChatPage.swift:453-472` | 长会话里工具行无限堆积，官方是"一轮一次折叠" | 行高 33pt、`padding-bottom 8`、底部 `0.5pt border-l2`、label 14pt/24pt 单行省略、chevron 14pt `margin-left 4`、展开旋转 180°；文案 `已完成` / `已完成，用时 {h小时}{m分}{s秒}` / `处理失败` / `已停止`；数字 `monospacedDigit`；运行中/出错/停止强制展开 | `turn/start`+`turn/end`+tool 计数（已有） | Wave 3；与 SB-04 同属"过程层" | 一轮结束：出现一行"已完成，用时 3秒"，点开铺开工具行 |
| SB-11 | P1 | 会话列表把子会话当普通会话平铺 | `ConversationSession.tsx:25-43`（只把 subagent 放进树）；`service.ts:34-36`（`parentId`/`origin`） | `DSHManagementModel.swift:918`（只解码 `parentSessionId`）、`SessionsPage.swift:198,255,539` | 抽屉里混进 `Subagent xxx` 之类条目，找不到主会话 | 列表过滤 `parentSessionId != nil` 的行（或折叠到父行下方、默认收起）；解码 `origin` | `parentSessionId`/`origin`（已在 `session/list` 响应里，`list.ts:351-363`） | 小改动，1 个 filter | 有子会话时抽屉条目数不增加 |
| SB-12 | P1 | 消息列宽 370pt（官方 338pt），"输入卡比消息列宽 32pt"的关系丢失 | `ChatView.module.css:22-28`；`ConversationRoot.module.css:384-390,516` | `ChatPage.swift:799`（transcript `padding(.horizontal,16)`）；输入卡 `padding(.horizontal,16)`（`1227`） | 所有行右边缘差 16pt；长消息行长差 ~9% | transcript 横向 padding = **32pt**；输入卡保持 16pt（卡宽 370） | 无 | 改 1 个数（`16`→`32`），同时检查 `NativeContextSourceGroup` 的 `.padding(.leading,-4)` 与工具行缩进 | 量宽：一条满长消息的宽度应为 338pt |
| SB-13 | P1 | 无 steering（父会话运行中收到的人/子 Agent 消息）气泡与等待态 | `ChatView.tsx:147-190`（`inboxSteering`/`pendingInputs`）；`MessageItem.tsx:163-213`（右侧气泡，`data-pending-steering`）；`MessageItem.tsx:297-320`（已落库 steering 同形） | `ChatModel.swift:2107-2123`（只有本地 `queueLabel`：`已排队`/`发送中…`/`已并入当前任务`） | 官方在运行中发出的"补充说明"会以右侧气泡出现且与最终落库一致；iOS 只有一个行内小标签 | 待定稿 steering 气泡 = 右侧气泡同款（复用现有 `userBubble`），下方 `NativeMessageActions` 用 `clock="start"`；inbox claim 后转正式行，**不重复渲染** | `inbox next-step.claimed` + 本地提交 id（`rpcId`） | 与 SB-03 同批（同一张 claim 表） | 运行中发一条：立即出现右侧气泡；`user/message` 到达后仍只有 1 条 |
| SB-14 | P1 | "回到最新"胶囊 ≠ 官方 34×34 圆钮 | `ChatView.module.css:249-296`；`ChatView.tsx:238-248` | `ChatPage.swift:876-887` | 形态、位置、层级都不同 | 改为 `34×34` 圆形、图标 `chevron.down` 15pt、`bg #FFFFFF`、`shadow (0 0 0 0.5pt rgba(0,0,0,.16), 0 4px 16px rgba(0,0,0,.03), 0 0 24px rgba(0,0,0,.03))`、右下 `bottom 16` / `trailing 32`、无文字 | 无 | 独立小改 | 截图比对：圆形无文字 |
| SB-15 | P2 | tertiary 色偏亮 | `design-platform.css:225`（`#81858C`） | `NativeChatTheme.swift:10`（`#9A9AA2`） | 工具行/上下文行整体"浅"一档 | 亮色 `#81858C`（dark 保持 `#81858C`，官方 dark = `bluish-400 #ADB2B8`，需按官方 dark 改） | 无 | 改 token | 取色器比对 |
| SB-16 | P2 | 缺 hairline 容器语义（0.5pt `border-l1` / `radius 20` / `#F9FAFB` 底 / hover 100ms） | `TurnTriggerNodeView.module.css:1-8`；`base.css:23-30` | 无对应控件 | 通知块没有"卡片感" | 见 SB-02 | 无 | 随 SB-02 | — |
| SB-17 | P2 | 工具行 title `fixedSize(horizontal:true)` 永不截断；无 hover 图标→chevron 交叉 | `DisclosureRow.module.css:22-40,55-70,95-115` | `NativeMessageRows.swift:28-30`（`fixedSize`）、`22-27`（ZStack 切换而非 opacity 交叉） | 402pt 下长标题（如 `创建子智能体`+长 summary）会挤压 summary 到 0 | title 允许压缩、summary `lineLimit(1)+truncationMode(.tail)`；图标/chevron 用 opacity 100ms 交叉（iOS 无 hover，改为"点击瞬间交叉"或常显 chevron） | 无 | 随 SB-07 | 402pt 长参数下 summary 仍可见 |
| SB-18 | P2 | 缺官方动效细节（100ms color/background 过渡、`TextShimmer`、`prefers-reduced-motion` 关闭） | `TurnTriggerNodeView.module.css:6,18,33-35`；`ChatGroupSeat.module.css:5-85,136-150`（shimmer + reduced-motion）；`DisclosureRow.module.css:95-118` | `NativeMessageRows.swift:19` 只有 `withAnimation(.easeOut(duration:0.16))`；`ShimmerText` 仅用于工具 summary（`:36-38`） | 观感为硬切，而非官方那种轻过渡 | 统一 100ms `ease`（颜色/背景）；运行中组头用 `ShimmerText`；`@Environment(\.accessibilityReduceMotion)` 时关过渡 | 无 | 随 SB-02/SB-04 | 录屏慢放：颜色变化有 100ms 过渡 |
| SB-19 | P2 | 缺进程组体的官方容器语义（`max-height min(400px,50vh)`、组内 gap 6、上下 24px 渐隐 mask、`scrollbar-gutter: stable`） | `ChatGroupSeat.module.css:86-134`（`max-height min(400px,50vh)` + fade mask）`；`ChatView.module.css:66-96,119-122`（flow gap 6/12/16 三档） | `ChatPage.swift:2349-2361`（`VStack(spacing:6)`，无上限、无 mask、无 gutter） | 子 Agent 与工具多时一组会顶满整屏 | 组体 `frame(maxHeight: min(400, viewportH*0.5))` + 裁切 + 上下 24pt 渐变 mask；组内 `spacing 6`；组间 12pt（status/error 6pt） | 无 | 随 SB-04/SB-10 | 15 条工具调用时组体不超高、上下边缘有渐隐 |

## 5. 隐藏/条件控件清单

| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 备注 |
|---|---|---|---|---|
| turn-trigger 行 | `user/message` 且 `source.kind≠user` 且被 `inbox-next-turn` 认领（或 idle-steer） | 消息流中，Turn 开头 | ❌ | 10 个 source 家族（见 A2） |
| `context` 注入行 | 同上但注入到运行中的 Turn | 消息流中，Turn 内 | ⚠️ 只有历史重放、合并成组 | 形态错（SB-08） |
| 进程组标题（"正在协调子智能体"） | Turn 内有 tool/call，且当前视图模式分组 | 工具行上方 | ❌ | 默认 web = `detailed`，运行中平铺、完成后折叠（`chat-settings.ts:44`、`presentation-policy.ts:37-42`） |
| Turn 折叠控制 | Turn `closed` | 工具行上方 | ❌ | `TurnProcessNodeView.tsx:27`（`status!=='closed'` 时 return null） |
| 页头 breadcrumb | 当前会话 `origin==='subagent'` 或祖先链 >1 | header.titleRow | ❌ | 根会话只有 1 段 |
| 子 Agent 目录按钮 | 根会话且 `subagentCatalog.length>0` 或 error | header.actions（order 10） | ❌ | 空 catalog 不显示 |
| 子 Agent 切换器（switcher） | 子会话 | header.lineage（替换 crumb） | ❌ | 「父目录里选中我」+ 同名兄弟切换 |
| 侧栏 chat tab | 用户点目录行右侧按钮 | 右侧栏（手机=整高抽屉） | ❌ | `dsh-resource://subagentchat/...` |
| 子会话只读 composer | `mode==='one-shot'` 或 `parentAvailable===false`（且未运行） | composer 位置 | ❌ | 3 种文案 |
| 后台任务页头按钮 | 有 job | header.actions（order 20） | ❌ | `ui-jobs/index.ts:36-40` |
| 回到底部 | 用户离开底部 | 右下角浮钮 | ✅（形态不同） | SB-14 |
| 运行中"深度求索中" | Turn running | 内容尾部 | ⚠️ | iOS 有 `ProgressView` + 状态行，非 shimmer 文案（属 Axis 02/05） |
| `wait_agent` 行 | 仅 experimental agent-team 启用 | 工具行 | ❌ | **不随附**，不必补（P3） |
| `spawn_teammate`/`team_task_*` 行 | 同上 | 工具行 | ❌ | 同上 |
| PWA push 通知 | 安装 PWA + 授权 | 浏览器/系统通知 | ❌ | `ui-mobile/src/client/push.ts`；iOS 对应本地通知（P3，轴外） |

## 6. 数据链路缺口

| 事件/字段 | 官方消费方 | iOS 映射/投影 | 缺失后果 | 需要补什么 |
|---|---|---|---|---|
| `agent/inbox/spliced` 的 `target` | `inbox.ts:115-135`（next-step / next-turn 两个 definition） | `DSHEventMapper.swift:67-73` **只取 inserted[].content+source**，`target/start/removedCount/outcome` 全丢 | 无法区分"唤醒"与"注入"→ turn-trigger 与 context 两种形态都画不出 | `HarnessInboxSplice{target,start,removedCount,inserted,outcome}` |
| `inserted[].id` | `inbox.ts:52-133`（claim 集合）、`message.ts:93-94` | 丢弃（`HarnessUserInput` 只有 text+source） | 无法把 `inbox` claim 与随后 `user/message` 对齐 → steering 气泡会重复或丢失 | `HarnessUserInput{id, text, source, sourceSummary, sourceForm}` |
| `claimedHuman` | `message.ts:85`（idle-steer 分支的关键条件） | 无 | 人+非人混在同一批时会误判成"通知唤醒" | 由 splice 的 `source.kind` 集合派生，随 inbox 状态维护 |
| `user/message.source.form` / `.summary` / `.senderSessionId` | `event-projection.ts:47-53`（`contextForm`）、`ContextBody.tsx`（notice summary）、`RelayBody` | 未读（`DSHMessageSourceClassifier.swift:12-20` 只读 `kind`） | `subagent-settled` 丢掉"一行结论"；`agent-message` 丢掉"来自会话 xxx" | `HarnessUserInput` 增 3 字段 |
| `user/message`（非 user source）实时投影 | `message.ts:76-130` | `ChatModel.swift:1719` 丢弃 | 实时完全不可见（SB-01） | 新增 `Kind.turnTrigger` / `Kind.contextInjected` |
| `subagentCatalog[].activity` | `SubagentHeaderLineage.tsx:497-499,705-718` | `DSHManagementModel.swift:575-580` 只取 `label/mode/id` | 目录/列表无法显示"正在运行/已完成/未运行" | `ActivityRow` 增 `activity`，并合并 `sessions.byId[id].running` |
| `subagentCatalog[].createdAt` | 排序与"新建"提示 | 未读 | 列表顺序不稳定 | 增字段 |
| `subagentTiming`（`settledMs`/`active`/`lastTurnCompleted`） | `SubagentHeaderLineage.tsx:77-90`（时长）、`:251-256`（已完成判定）、`:206-211`（running 时 1s tick） | 完全未读（全仓无 `subagentTiming` 字样） | 目录里没时长、无法区分"跑完"与"没跑" | 读 `projections.subagentTiming` 并按 1s tick（仅 running 行） |
| `tokenUsage`（4 桶） | `SubagentHeaderLineage.tsx:57-69` | 有 `NativeTokenUsage`，但未用于子 Agent 行 | 目录无 token 指标 | 复用 `NativeTokenUsage` |
| `projections.subagent`（子会话身份 `mode/label`） | `SubagentReadOnlyComposer` 选择器（`index.ts:37-56`） | 未读；`HarnessSessionRequest` 无 parent/child（`AgentHarness.swift:110-145`） | 无法判断"当前页是子会话/只读/父是否在线" | `HarnessSessionInfo{parentSessionID, mode, label, parentAvailable}` |
| `session/list` 的 `origin` / `parentSessionId` | `service.ts:34-36`、`ConversationSession.tsx:25-43` | `DSHManagementModel.swift:918` 只解码 `parentSessionId`，`origin` 未解码 | 抽屉无法过滤子会话（SB-11） | 解码 `origin`，`SessionsPage` 过滤 |
| `web-build.json` 版本对齐 | — | 本地 `Bundle/worker/web/web-build.json` 的 `commit = 7be5505b0b…` | 无（正面证据） | — |

**结论**：**子 Agent 消息在 iOS 现有通道里是"到达但被 UI 丢掉"，不是通道过滤**——`session/page` 返回全部事件（`history.ts:392-445`），`session/follow` 也不过滤（`history.ts:196-230`）。因此本轴**不是 Axis 01 的 P0 数据卡点**，而是 UI+模型的 P0；唯一真正缺数据的是 `subagentTiming` / `origin` / `activity` 这三项"目录用"字段。

## 7. 实施顺序建议

**Wave 1（P0 里"纯 UI、无新数据"的一刀切；1–2 天）**
1. SB-07：四个 shipped 工具行的标题/图标/详情卡（只依赖 `tool/call` + `tool/result`，已有）。
2. SB-06：给 `SessionActivityPage` 一个入口（1 行），先把"看得到子 Agent"兜住。
3. SB-17 / SB-15 / SB-12：工具行截断、tertiary 色、消息列 32pt（低风险像素修正）。

**Wave 2（P0 的消息流形态；依赖数据结构扩展）**
4. SB-01 + SB-03：扩展 `HarnessUserInput`（id/form/summary/senderSessionId）+ `HarnessInboxSplice`（target/start/removedCount），`ChatModel` 建 claim 表。
5. SB-02 + SB-08：同一套行渲染器出两种形态（turn-trigger 卡片 / 24pt context 行）。
6. SB-04：进程组头（先两态文案，不做折叠）。
7. SB-13：steering 气泡（复用现有右侧气泡）。

**Wave 3（导航与过程层）**
8. SB-05 + SB-09：页头 crumb + 目录 sheet + 标题排版（一次改完，避免二次动页头）。
9. SB-11：抽屉过滤子会话。
10. SB-10：Turn 折叠控制 + 组内 fade mask。
11. SB-14：回到底部圆钮。

**不做（P3）**：`wait_agent` / `spawn_teammate` / `team_task_*` 的专用卡（工具不随附）；PWA push 的 iOS 对等能力（另立轴）。

## 8. 未知与需确认

1. **turn-trigger 行高**：`TurnTriggerNodeView.module.css:25` 的 `.title` 只声明 `font-size: 14px`，**没有 line-height**；本 checkout 里也没有全局 `body{font-size/line-height}`（`base.css` 全文 39 行只有变量；shipped bundle 里 `body` 只设 font-family/color/background）。因此行高在 14/22 假设下 ≈ 46px，在 14/normal ≈ 41px。**需真机/DevTools 实测**，本报告按 ≈41pt 写合同。
2. **官方 402pt 页头是否溢出**：`mobile.module.css`（1-207 行）对 header/crumbs/actions **无任何覆盖**；402pt 下 `crumb`（max 220）+ 目录按钮（`N 个子智能体`）+ 后台任务按钮 + 手机菜单按钮（36pt）是否会挤压标题，**未实测**。若溢出，说明官方手机端在该处依赖截断而非重排——iOS 应给 bottom sheet 而非照抄横排。
3. **子会话侧栏在 402pt 下的圆角/阴影**：`mobile.module.css:94-110` 只设 `width min(100vw,480px)` / `shadow elevation-prominent` / 无 `border-radius`；抽屉是否带圆角需实测（官方预览图不可得）。
4. **`detailed` 模式下"运行中平铺"的最终观感**：web 默认 `detailed`（`chat-settings.ts:44`，非桌面壳），运行中 Turn 不分组（`ChatGroupSeat.tsx` 的 `grouped` 仅在 `history` 且 Turn 结束时为真）。因此"正在协调子智能体"在**默认 web 设置下运行中并不显示**，只在 `standard/compact` 显示。这一点会影响 iOS 该不该在运行中显示组头——**建议按 `detailed` 对齐（运行中平铺、完成后折叠），但产品需确认**。
5. **`message.turnProcess.subagents.{one,other}` 是死文案**：`locale.ts:153-154` 在 shipped UI 里无消费方（全仓命中仅 locale 与构建产物 `.d.ts`）。iOS **不要**照抄这行计数，除非官方后续接上。
6. **`team-message` / `webhook` / github**：属 `packages/experimental/*`，不随附；但 `turn-trigger.ts:57-62` 分支仍在 shipped 代码里（接收端兼容）。iOS 是否需要为它们预留（且永不触发）——建议只留 `default → 收到执行请求` 兜底。
7. **`subagent_fork`**：`isSubagentDelegationTool` 用前缀匹配（`contract/turn-process.ts:44-49`）→ `subagent_fork` 也算 subagent 委托；但 `ToolRow` 标题表里只有 `subagent`（`tool-call-model.ts:103`），`subagent_fork` 会掉到 `tool.title.generic`（`工具调用`）。**官方自身的不一致**，iOS 对齐时应选择：跟随 toolview 实际表现（`工具调用`），或按语义补 `创建子智能体`——需产品决策。
8. **官方 `IconAgentPresetOutlineRegular` / `IconUsersOutlineRegular` 的 SF Symbol 对等物**：官方是自绘 20×20 viewBox 图标（`TurnTriggerNodeView.tsx:14-25`、`details-row.tsx:19-20`）。iOS 现有资产表 `NativeChatIcon.Name`（`NativeChatTheme.swift:41-77`）没有 agent/users 图标；改用 SF Symbol（`person.2`、`person.badge.plus`）会与官方字形不同，需设计确认是否新增 asset。
9. **子 Agent 消息回流是否触发 "未读"**：官方**没有**站内未读/角标机制（`grep "unread"` 无命中；只有 `chat.toBottom` 与 `TurnNavigator`）；PWA push 是唯一"站外新消息"通道（`ui-mobile/src/client/push.ts:21-96`，只在 `enabled && permission==='granted'` 时订阅）。因此 iOS **不应**发明未读红点；若要做，属于超出官方的产品增强，需显式标注。
10. **`SessionActivityPage` 的定位**：它同时承载了 todos / goal / schedules / jobs / subagents（`SessionActivityPage.swift:14-120`），是"运行活动"聚合页，与官方"页头目录 + todo dock + goal bar + jobs 面板"是四种不同承载。是否保留为 iOS 的聚合替代入口，需产品决策（本报告只把它当"最小可用入口"）。

## 9. 验收场景（≥10）

| # | 场景 | 官方期望（402pt） | iOS 当前 | 验收方法 |
|---|---|---|---|---|
| 1 | 派一个子 Agent（运行中） | 工具行 `创建子智能体 · <prompt> · 已启动`；父 Turn 运行中 | 行 `子 Agent · <首个参数>` + sparkle 图标 | 快照对比标题/图标/summary |
| 2 | 子 Agent 完成（父空闲 → 唤醒新 Turn） | turn-trigger：`子任务状态更新` + 时间 + chevron；展开 `这条通知触发了本轮回复。` + summary + closing message | 无任何新行 | 实时观察 + `model.items` 计数 |
| 3 | 子 Agent 完成（父运行中 → 注入当前 Turn） | 24pt `上下文注入 · subagent-settled · <summary>` 行 | 无任何新行 | 同上 |
| 4 | 子 Agent 用 `send_message` 给父会话发消息 | 父会话出现 `收到任务消息`（turn-trigger，`IconPaperPlaneOutlineRegular`）或 `上下文注入 · agent-message` | 无 | 同上 |
| 5 | 子 Agent `send_message` 失败/未送达 | 工具行 error 态，首行错误文本，`state-error-primary` | 通用 IN/OUT 卡 | 快照 |
| 6 | 从父进子（页头目录） | 点 `N 个子智能体` → 树 → 点行 → 进入子会话；子会话页头显示 `父 / 子` crumb | 无入口 | 手测 |
| 7 | 从子回父（breadcrumb） | 点父 crumb 回到父会话 | 无 | 手测 |
| 8 | 子会话只读（one-shot） | composer 位置显示 `一次性子智能体记录` + `一次性任务不支持后续消息，可在这里查看完整执行记录。` | 仍显示普通可输入 composer（且 iOS 根本进不去子会话） | 手测 |
| 9 | 子会话可继续（continuable） | 普通 composer；运行中给 Stop | N/A | 手测 |
| 10 | 目录里多个子 Agent、其中一个在跑 | 目录按钮前 14pt 转圈点；行 activity `正在运行`；行右侧 `{tok} · {duration}` | 列表无状态、无 metrics、且不可达 | 手测/快照 |
| 11 | 等待子 Agent 超时 / 无活跃子 Agent | `wait_agent` 行：`子智能体状态` + `等待超时` / `没有正在运行的子智能体` + 原因 | 无（且工具不随附） | 仅当启用 agent-team 时才验收（P3） |
| 12 | 后台任务完成唤醒 | turn-trigger `后台任务状态更新`（`IconQueueOutlineRegular`） | 无 | 同上 |
| 13 | 定时任务到点唤醒 | turn-trigger `自动化任务`（`IconClockOutlineRegular`）；展开 body 为提醒正文 | 无 | 同上 |
| 14 | goal round 唤醒 | turn-trigger `继续执行目标`（`IconGoalOutlineRegular`） | 无（goal 只出现在 composer 上方 goalBar，`ChatPage.swift:1136`） | 同上 |
| 15 | 子 Agent 消息到达但用户已上滚 | 不动滚动；右下出现 34×34 圆钮（`回到底部`） | 出现"回到最新"胶囊 | 快照 |
