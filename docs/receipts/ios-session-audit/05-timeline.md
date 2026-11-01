# Axis 05 — Turn 时间线 / 过程折叠 / 导航 / 运行指示 — iOS Session 对齐审计

> 审计基线：官方 DSH `7be5505b0b`（0.2.1-rc.2），iOS 仓库工作区当前 HEAD。
> 视觉基准：手机宽度 402pt（CSS px ≈ iOS pt），官方 `ui-mobile` 断点 `<640px`。
> 本报告只审 transcript 的结构/分组/折叠/导航/滚动/运行指示；工具卡内部见 Axis 06，消息正文渲染见 Axis 07。

## 0. 结论摘要

- 官方 transcript **不是消息列表**，而是一个三层可见性模型：`whole-Turn(过程折叠)` → `secondary group(过程分组)` → `单条 reasoning/tool disclosure`；可见性「由外向内」生效（`conversation-nodes/README.md:62`）。iOS 只有最内层（每行自己的 `DisclosureRow`），**外层两层完全不存在**（`ChatPage.swift:453-475`、`ChatPage.swift:2349-2361`）。
- iOS 的「工具组」是**假的折叠**：`ToolRunRow` 只是把相邻工具行放进一个 6pt 间距的 `VStack`，没有组头、没有组级折叠、没有 `min(400px,50vh)` 高度上限、没有 24px 边缘渐隐（`ChatPage.swift:2349-2361`）。官方的过程分组是一等公民（`ChatGroupSeat.tsx:132-202` + `ChatGroupSeat.module.css:86-139`）。
- **iOS 完全没有 Turn 级完成状态行**：官方每个已关闭 Turn 在过程块顶部有一条 `turn-process` 控制行（「已完成，用时 1分20秒」/「处理失败」/「已停止」，33px 高 + 8px 内距 + 0.5px 下边线，14px tertiary，右侧 14px chevron）——`TurnProcessNodeView.module.css:1-18`。iOS 里 `turnProcess`/`turn-tail` 搜索 0 命中，`turn/end` 只写进 `statusLine` 字符串（`ChatModel.swift:1770-1801`），`aborted`/`interrupted` 在历史投影里**连行都不产生**（`NativeTranscriptProjector.swift:128-133`）。
- **运行中指示只有 composer 里一个系统 spinner**（`ChatPage.swift:1325-1329`），没有 transcript 级「深度求索中，用时 12秒 ···」+ 鲸鱼图标 + shimmer + 0.5px 分隔线（`RunningStatus.tsx:20-40`、`ChatView.module.css:142-219`）。`.status` 类型的行在 `visibleItems` 里被直接过滤掉（`ChatPage.swift:104-109`），渲染分支是 `EmptyView()`（`ChatPage.swift:2284-2285`）。
- 行间距矩阵与官方不是一套数值：iOS 6/8/12/20（`ChatPage.swift:422-443`），官方 6/12/16（`ChatView.module.css:68-121`）。直接后果是**思考行与工具行之间 20pt/8pt，官方是组内 6px**；turn 边界 20pt，官方不存在「turn 边界额外间距」这个概念。
- 结论：P0 4 条、P1 6 条、P2 7 条、P3 2 条（共 19 条）。**TurnNavigator 不是缺口**——官方在容器宽度 ≤900px 时 `display: none`（`TurnNavigator.module.css:207-211`），402pt 本来就该没有；这是要写进合同的「确认不要做」，而不是待补功能。

## 1. 审计范围与方法

**官方侧**（`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`，HEAD = `7be5505b0be06009d74891c869063c9cf19a0df0`）：

- `packages/client/ui-chat/src/client/conversation-nodes/README.md`（331 行，全读；这是官方自述的业务规则，优先级最高）
- `conversation-nodes/{turn-process,turn-tail,process-groups,process-activity,turn-navigation,turn-process-presentation,common}.ts`
- `contract/{turn-process,group-tree,turn-metrics,process-groups,slots,store}.ts`、`stores.ts`、`presentation-policy.ts`、`transcript-view.ts`、`chat-settings.ts`
- `chat/{TurnProcessNodeView,TurnTailNodeView,ChatGroupSeat,ChatNodeSeat,ChatFlow,ChatView,TurnNavigator,RunningStatus,RunningWhaleTail,MessageIconActions,ReasoningRow,TurnTriggerNodeView}.tsx` 与同名 `.module.css`
- `chat/{use-chat-scroll,use-chat-navigation,use-chat-reading,use-scroll-follow,use-chat-viewport,step-process,turn-rail-items,message-chrome}.ts`
- `ui-conversation`：`skeleton/ConversationRoot.module.css`、`skeleton/InputBar.module.css`
- `ui-mobile`：`src/client/mobile.module.css`（全读 207 行；**没有任何时间线相关的覆盖**）
- `ui-primitives`：`TextShimmer.tsx`、`TextShimmer.module.css`
- `ui-theme/src/styles`：`design-platform.css`、`base.css`、`corner-shape.css`
- 测试（行为证据）：`ui-chat/tests/turn-tail-spacing.client.spec.ts`、`turn-process-tail.client.spec.ts`、`turn-navigation.client.spec.ts`、`turn-rail-items.client.spec.ts`、`fold-follow.client.spec.ts`、`scroll-follow.client.spec.ts`、`running-status.client.spec.ts`、`running-whale-tail.client.spec.ts`、`transcript-view-policy.client.spec.ts`、`presentation-policy.client.spec.tsx`

**iOS 侧**（`/Users/leilangsheng/Desktop/TonoTeam/phone-dsh`）：

- `examples/probe-app/PhoneDSHProbe/{ChatPage,ChatModel,NativeChatTimelineChrome,NativeMessageRows,NativeChatTheme,NativeConversationModels,NativeTranscriptProjector,NativeToolDetailCards,NativeMessageActions}.swift`
- `Sources/PhoneDSHAgentCore/DSH/DSHEventMapper.swift`
- `examples/probe-app/PhoneDSHSimTests/NativeChatPresentationTests.swift`（115 行，无任何 timeline/spacing 断言）

**穷尽搜索（0 结果即「iOS 没有」的证据）**：

```bash
cd /Users/leilangsheng/Desktop/TonoTeam/phone-dsh
grep -rnE --include=*.swift 'turnProcess|turn-process'   examples Sources | wc -l   # 0
grep -rnE --include=*.swift 'turnTail|TurnTail|turn-tail' examples Sources | wc -l   # 0
grep -rnE --include=*.swift 'TurnNavigator|轮次导航'      examples Sources | wc -l   # 0
grep -rnE --include=*.swift '深度求索|deepDiving'         examples Sources | wc -l   # 0
grep -rnE --include=*.swift '回到底部|toBottom'           examples Sources | wc -l   # 0
grep -rnE --include=*.swift '用时'                        examples Sources | wc -l   # 3（全部是 NativeComposerStats/DailyBrief，非 turn 级）
grep -rnE --include=*.swift 'scrollAnchor|scrollPosition|ScrollPosition' \
  examples/probe-app/PhoneDSHProbe | wc -l                                        # 1（仅 .defaultScrollAnchor(.bottom)）
```

反查官方侧是否也「没有」时同样给证据，例如：`grep -rn "turnProcess.toolCalls\|turnProcess.messages\|turnProcess.subagents" --include=*.ts --include=*.tsx packages apps | grep -v locale.ts` → 仅命中 `lib/types/client/locale.d.ts`，说明 `messageCount/toolCallCount/subagentCount` **不显示**，只作为 `data-turn-process-*` 属性存在（`TurnProcessNodeView.tsx:42-44`）。

**截图对照**（只作视觉佐证，不作代码事实）：

- `docs/receipts/ios-baseline-screens/ios-chat-long.png`（截图观察）：iOS 长正文页，左起 16pt 进入正文，正文单列铺满 370pt，无任何 Turn 容器/组头/完成行。
- `docs/receipts/ios-baseline-screens/ios-chat-official.png`（截图观察）：文件名虽为 official，内容实为 **iOS 原生空态页**（页头「新会话/未启动」、`回到最新` 文字胶囊、composer、`5 轮 17 步 · 54 tok/s …` 统计条）——即官方 402pt 视觉基线在本仓库**尚缺**，需补一张真正的官方 Web 402×874 截图。

**未跑测试/构建**：本审计为静态源码阅读，未执行任何 `swift test`、`vitest`、`pnpm build`，故不对「是否通过」作任何声明。

## 2. 官方基线（按 surface 列）

### 2.1 Turn 结构模型（先建模型，再谈像素）

官方 Turn 的概念是 4 个可判定事实，全部来自 `turn-process` 节点：

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| T0.1 | `turn/start` 到达 | `turn-process.ts:212-227`（match）、`:228-238`（start） | 每个 turn 一条 `TurnProcessState`：`turn / assistantStartByStep / messageCountByStep / otherStartSeq / controlAnchorSeq / messageCount / toolCallCount / subagentCount` | — | — | 计数不进 UI，只进 `data-turn-process-*`（`TurnProcessNodeView.tsx:42-44`） | `turn/start`、`assistant/message`、`tool/call`、`tool/result`、`llm/retry`、`step/*`、`turn/end` |
| T0.2 | 生成 `TurnProcessSpec` | `turn-process.ts:124-168` | `processStartSeq / answerAnchorSeq / answerStep / inlineReasoning / controlAnchorSeq`；`answerAnchorSeq` 由「最新 step 的 settled assistant 且有 reply 内容、且无 tool-call block」决定（`:117-122`） | — | — | 无 reply ⇒ `answerAnchorSeq=null`（整轮都是过程） | `assistant-step` 的 `finalNode` |
| T0.3 | 分组树位置 | `contract/group-tree.ts:25-27` | 4 层深度：`exchange(0) → input(1) → turn(2) → process(3)`，`isAtOrOutside` 判定（`:35-37`） | — | — | 位置由 Definition 决定，不看 kind（README:201） | 每个 node 的 `groupTree` |
| T0.4 | 每 turn 两条「turn 级」节点 | `turn-process.ts:294-300`（`groupTree: 'turn'`）、`turn-tail.ts:135-139`（同） | 控制行在 `controlAnchorSeq-0.1`（`common.ts:18`），footer 在 `turn/end.seq+0.1`（`common.ts:20`） | 见 2.2 / 2.4 | 见 2.2 | 两者都与 Assistant 行解耦（`turn-tail.ts:103`） | `turn/end` |

**一个 Turn 的合成顺序**（README:30-41，官方自述的完整例子）：

```
user input
├ turn-process 控制行（「已完成，用时 …」，whole-Turn 折叠开关）
├ 过程区（受控制行支配）
│   ├ G1: reasoning, read, bash
│   ├ 中间回复（独立行，但仍属过程，折叠时一起消失）
│   └ G2: reasoning, run_code
├ 最终回答（保护在过程折叠之外；它的 reasoning 仍算过程）
└ turn-tail（footer：动作/用量/deliverables）
```

### 2.2 `turn-process` 控制行（Turn 级折叠开关 + 完成状态）

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| T1.1 | `turn.status === 'closed'` 才渲染；running 时**不渲染**（节点存在但不画） | `TurnProcessNodeView.tsx:18` | 单个 `<button>`，`display:flex; align-items:center; width:100%` | `height: calc(33px + font-delta)`、`padding: 0 0 8px`、`border-bottom: 0.5px solid var(--dsw-alias-border-l2)`、`font-size: 14px`、`line-height: 24px`、`color: var(--dsw-alias-label-tertiary)` = `rgb(129,133,140)` 亮 / `rgb(173,178,184)` 暗、`border` 亮 `rgba(0,0,0,0.1)`（`TurnProcessNodeView.module.css:1-18, 41-48`；token 见 `design-platform.css:187,225,343`） | 「已完成」/「已完成，用时 1分20秒」/「处理失败」/「已停止」 | 可折叠时右侧 14×14 chevron，`margin-left: 4px`，`[data-open]` 时 `rotate(180deg)`，`transform 100ms ease`；`:hover` 变 `label-secondary`；`disabled`（无内容）时 `cursor:default` 且无 chevron（`TurnProcessNodeView.tsx:19, 58`；CSS `:28-39`、`:24-26`、`:20-22`） | `turn.start.time`、`turn.end.time`、`turn.end.data.reason.kind` |
| T1.2 | 文案算法 | `TurnProcessNodeView.tsx:20-33` | `stopped = reason ∈ {aborted, interrupted}`；`elapsedMs = max(1000, end-start)`；`stopped` 或 `error` 时不显示时长 | 时长数字用 `font-family: var(--ds-font-family-code)` + `font-variant-numeric: tabular-nums`（`.module.css:50-53`） | `t('message.stopped')`→「已停止」；`t('message.turnProcess.failed')`→「处理失败」；`t('message.turnProcess.worked')`→「已完成」；`t('message.turnProcess.took')`→「已完成，用时 」（注意尾随一个半角空格，`locale.ts:64-66`） | — | i18n `duration.*` |
| T1.3 | 时长格式 | `message-chrome.ts:54-64` | 秒→分→时三段；`total>=60` 才出现分钟；`hours>0` 才出现小时；**无前导零** | 例：`1分02秒` 而非 `01分02秒` | 单位 `秒`/`分`/`小时`（`locale.ts:187-189`） | 每 1000ms 刷新（`message-chrome.ts:13`） | — |
| T1.4 | 折叠谓词 | `TurnProcessNodeView.tsx:14,19`；`contract/turn-process.ts:53-58` | `open = !foldable \|\| turnProcess.open`；`canCollapse = foldable && hasContent && !turnProcessAlwaysOpen(node)`；`turnProcessAlwaysOpen` = turn 未关闭 **或** end.reason ∈ {aborted,interrupted,error} | — | — | 默认开/关见 T1.5 | `ChatNodeSeat.tsx:71-113` |
| T1.5 | 默认开合 | `stores.ts:36-43`；`ChatNodeSeat.tsx:60-70` | 读者对「当前 answer 代」的手动选择优先；否则 `defaultOpen` | — | — | `defaultOpen = bottom===true && deferCollapse`（仅 `on next message` 且本 turn 在底部） | Chat store |
| T1.6 | 间距 | `ChatView.module.css:116-121` | 控制行自身与**其后一个** flow 子项都是 16px | 上下各 16px | — | — | — |
| T1.7 | 无障碍 | `TurnProcessNodeView.tsx:36, 46` | `role="status" aria-live="polite" aria-atomic="true"` 隐藏播报（只播「已停止/处理失败/已完成」三种，不含时长）；`aria-expanded = hasContent ? open : undefined` | — | — | 点击后 `event.currentTarget.focus()`（`:48`） | — |

### 2.3 过程分组 `ChatGroupSeat`（组头 + 组体）

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| T2.1 | 分组边界 | `process-groups.ts:147-171`（rebuild 主循环）；README:203-229 | 同一 Turn 内相邻过程内容成组；**reply 结束前一组并自己独立成 `response` 根**；`isAtOrOutside(node,'process')` 的节点（`model-retry`、turn 输入、`turn-error`、`turn-max-tokens`、`turn-tail`、`turn-process`）结束前组并保持独立根；换 Turn/无 Turn 断开；hidden/`system-prompt`/`context`/`permission` 不参与也不断开 | — | — | step 变化**不**切组（README:199） | `input.readTurn(turn)` 顺序 + `readPosition` |
| T2.2 | 组头 DOM | `ChatGroupSeat.tsx:115-128` | `<button>`：`<span.leading>`（活动图标 + chevron 叠放）+ `TextShimmer><span.label>` | `display:flex; gap:6px; max-width:100%`；`font-size: var(--dsh-content-font-size, 14px)`；`color: label-tertiary`；leading 盒 `16×16`，内部 svg `14×14`（`ChatGroupSeat.module.css:5-19, 27-46`） | 见 T2.4 | `:hover` → `label-secondary`；`transition: color 100ms ease`（`:21-23`） | group snapshot |
| T2.3 | 图标/chevron 互换 | `ChatGroupSeat.tsx:38-53`（14 个分类图标）；`ChatGroupSeat.module.css:48-80` | 图标与 chevron **绝对定位叠放在同一 16×16 盒**，用 `opacity` 100ms 互换 | 静息：图标 1 / chevron 0；`:hover`、`:focus-visible`、`[aria-expanded="true"]`：图标 0 / chevron 1；展开时 `padding-bottom: 8px` | — | 触屏无 hover ⇒ 只在展开时看到 chevron | — |
| T2.4 | 组头文案 | `step-process.ts:11-28`；README:155-181 | 关闭组：取 counts 前 3 类 → 中文逗号「，」连接，>3 类接「等」；两类用「{first}并{second}」，且两者都以「已」开头时去掉第二个「已」；0 类 → 「已完成分析」；运行中：live 分类标签（无 live 分类时「正在分析请求」） | 单行 `white-space: nowrap; text-overflow: ellipsis`（`.module.css:94-99`） | 运行：`正在分析请求/正在读取文件/正在读取图片/正在写入文件/正在搜索代码/正在编辑文件/正在运行命令/正在运行代码/正在搜索网页/正在访问网页/正在协调子智能体/正在更新计划/等待你的操作/正在调用工具`；结束：`已完成分析/已读取文件/已读取图片/已写入文件/已搜索代码/修改了文件/执行了命令/运行了代码/已搜索网页/已访问网页/已协调子智能体/更新了计划/向用户提出了问题/已调用工具`（`locale.ts:8-52`） | label 前加 shimmer；`Standard` 追加 ` · {detail}`（`Message.turnProcess.separator` = `' · '`，`locale.ts:156`） | `process-activity.ts` |
| T2.5 | 运行中标题最短驻留 | `ChatGroupSeat.tsx:28, 59-82` | 150ms 内不换标题，只保留最新 pending 标题 | — | — | 完成后**立即**切换为结束摘要（150ms 不适用于完成） | — |
| T2.6 | 组体 | `ChatGroupSeat.tsx:194-199`；`ChatGroupSeat.module.css:86-92, 127-139` | `<div role=region>` 内含 `.content` 列，成员逐个 `ChatNodeSeat` | 组内行距 **6px**（`--dsh-chat-flow-gap: 6px`）；`max-height: min(400px, 50vh)`；`overflow-y:auto`；`overscroll-behavior-y:auto`；`scrollbar-gutter: stable` | — | `Detailed`（运行中）与 `Verbose` 用 `.expandedBody`：`max-height:none; overflow:visible`（`:135-139`） | — |
| T2.7 | 边缘渐隐 | `ChatGroupSeat.module.css:101-117` | 上/下各 24px 的 `mask-image` 渐变，按 `data-scroll-up/down` 出现 | `transparent 0 → #000 24px` | — | — | `use-process-scroll` |
| T2.8 | 展开动效 | `ChatGroupSeat.module.css:142-144` | 成员 `margin-top` 过渡 | `160ms cubic-bezier(0.4, 0, 0.2, 1)`；`prefers-reduced-motion` 关闭（`:146-149`） | — | 手开未关闭组从**底部**开始并跟随增长；手开已关闭组从**顶部**开始且不跟随（README:186） | — |
| T2.9 | 分页锚点 | `ChatGroupSeat.tsx:188`（`data-chat-paging-anchor`） | 折叠组以组头为锚；展开组跳过组头用首成员 | — | — | 见 T7.2 | — |

### 2.4 `turn-tail`（完成后的 footer）

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| T3.1 | `turn/end` 到达且拿到 TurnLocation | `turn-tail.ts:63-101, 135-139` | 独立节点，`anchorSeq = turn/end.seq + 0.1`，`groupTree:'turn'`（永不被 whole-Turn 折叠） | — | — | footer 在所有过程行/工具行**之后**，与最后一条 Assistant 是谁无关（`turn-tail.ts:103` 注释） | `turn/end` |
| T3.2 | 容器 | `TurnTailNodeView.module.css:1-5` | `display:flex; flex-direction:column; gap:16px`（slot 贡献物之间 16px） | — | — | 无 tail 贡献物时不渲染容器（`TurnTailNodeView.tsx:50`） | `conversation.chat.turnTail` slot |
| T3.3 | 动作行 | `TurnTailNodeView.tsx:64-78`；`MessageIconActions.module.css:5-10, 63-87` | `MessageIconActions`：复制 / 👍 / 👎 / 分支 / 分享 / 用量 / 时间 | 行高 `28px`、`gap: 8px`；图标 15px，`[data-clock='end']` 时 **17px**；按钮 28×28、padding 6、`radius-sm`=8px；静息 `label-tertiary`，hover 底色 `interactive-bg-hover` | 时间 `HH:mm`（同日）/`M月D日 HH:mm`（同年） | `margin-top: 4px; margin-left: -6px`（`TurnTailNodeView.module.css:7-11`）；分支不可用时 `data-unavailable`（opacity .4，仍可聚焦出 tooltip） | `closing.finalNode.messageId`、`closing.time` |
| T3.4 | footer 与上一行的真实间距 | `ChatView.module.css:75-84, 116-121` + `TurnTailNodeView.module.css:7-11` | 回答行后 12px（`--dsh-chat-flow-gap:12px`）+ 动作行自身 `margin-top:4px` = **16px**；若上一行是过程/工具行则 6+4 = 10px | — | — | 单测锁定：`turn-tail-spacing.client.spec.ts:13-16` 断言 `gap:16px` 与 `margin-top:4px` | — |
| T3.5 | 分支可用性 | `TurnTailNodeView.tsx:34-35, 71`；`turn-tail.ts:98` | `branchUnavailable = closing===null \|\| latestTranscriptSeq !== closing.finalNode.seq`，再并上 `hasLaterChatNode` | — | — | 权限 `session/fork` 才给 `onBranch`（`:32`） | `useAccess('session/fork')` |
| T3.6 | 用量 | `TurnTailNodeView.tsx:74-76` | 仅 `performanceUsage === 'detailed'` 且拿到 `tokenUsage` 时，把 `TurnUsagePanel` 塞进动作行 | — | — | 默认 `detailed`（`chat-settings.ts:44` 的 `DEFAULT_TRANSCRIPT_VIEW_MODE`；用量档见 `DEFAULT_PERFORMANCE_USAGE`） | `deriveTurnTokenUsage` |

### 2.5 运行指示 `RunningStatus`（session 级，全页只有一处）

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| T4.1 | `session.running === true` | `ChatFlow.tsx:60` | 作为 flow 的**最后一个**子项追加（在 pending submission / steering 气泡之后） | 自身 `--dsh-chat-flow-gap: 12px`（`ChatView.module.css:146`） | — | 不运行时不挂载 ⇒ 直接消失 | `useSession(running)` |
| T4.2 | 结构 | `RunningStatus.tsx:31-40` | `div.running` → 隐藏播报 span + `span.runningDivider` + `span.runningContent`(鲸鱼 + shimmer 文本) | `display:flex; column; align-items:flex-start`；`runningContent`：`inline-flex; align-items:center; gap:6px` | — | — | — |
| T4.3 | 文本 | `RunningStatus.tsx:28-30` | 有 startTime：`chat.deepDivingFor`；无 startTime（当前 Turn start 还没到）：`chat.deepDiving` | `font-size: calc(14px - 2px)` = **12px**；`line-height: calc(22px + delta)`；`color: var(--dsw-alias-label-deep-diving)` = `color-mix(deepseek-500 70%, blue-950)` ≈ **rgb(52,94,186)**（亮）/ `color-mix(deepseek-450 55%, neutral-bluish-400)` ≈ rgb(125,154,222)（暗）；`font-variant-numeric: tabular-nums`（`ChatView.module.css:142-151, 178-181`；`design-platform.css:215-216, 333-334`） | 「深度求索中」/「深度求索中，用时 1分05秒 ···」（`locale.ts:89-90`，注意结尾是空格 + `···` 三个 U+00B7） | 恒 `TextShimmer active`（`RunningStatus.tsx:37`） | `turn/start.time` |
| T4.4 | 鲸鱼图标 | `RunningWhaleTail.tsx:10-18`；`ChatView.module.css:183-219` | 14×14 固定盒（`contain: strict`），默认静态 SVG 描边（`strokeWidth 1`，viewBox 16×16）；支持 mask 且无 reduced-motion 且非 forced-colors 时，改用 `running-whale@2x.png` 作 `mask` + `background: currentColor` 做动画 | 14×14px | — | `aria-hidden="true"`；reduced motion 下静态 | 资产 `running-whale@2x.png` |
| T4.5 | 分隔线 | `ChatView.module.css:153-169` | `.runningDivider` 默认 `display:none`；仅当**倒数第二个可见 flow 子项不是** `user`/`steering`/`turn-trigger`（且不是空 seat）时 `display:block` | `width:100%; height:0.5px; margin:8px 0 10px; background: color-mix(in srgb, border-l1 75%, border-l2)` ≈ `rgba(0,0,0,0.055)` | — | 即「上一条是输入就不画线」 | CSS `:nth-last-child(2 of …)` |
| T4.6 | 计时规则 | `RunningStatus.tsx:21-27`；`message-chrome.ts:13, 54-64` | `setInterval` 1000ms；`formatRunDuration(max(1000, now-start))` | 1 秒起跳、60 分钟起用小时、无前导零 | — | 时钟 tick **不**播报；生命周期变化才有 polite 播报（`RunningStatus.tsx:33`） | — |
| T4.7 | shimmer 参数 | `ui-primitives/TextShimmer.module.css:36-66, 69-80` | 两层：底字 + 遮罩扫光 | 遮罩 `linear-gradient(105deg, transparent 0%, black 40% 60%, transparent 100%)`；`animation-duration: 1.5s`；`delay: 0.3s`；`timing-function: steps(48, end)`；`iteration: infinite`；高光色 `var(--dsw-alias-label-shimmer)`；关键帧 `translateX(±100%)`，在 66.67% 就到位后停住 | — | `prefers-reduced-motion` 下 `.decoration{display:none}` | — |
| T4.8 | 挂载时序 | `ChatFlow.tsx:21-26, 55-60` | `runningStartTime` 取**最后一个 turn 且 status==='open'** 的 `turn.start?.time`；若最新 flow 项是空的 `turn-process`（opening control）且本 turn 不是最后输入 turn，则把 transcript 位置的 pending 气泡插到它之前 | — | — | 保证「先显示发送中的气泡，再显示运行指示」 | — |

### 2.6 Turn 导航 `TurnNavigator`（**手机宽度不显示**）

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| T5.1 | `scroll.initialized` 且 `items.length >= 2` | `ChatView.tsx:199-207`；`TurnNavigator.tsx:227` | 右侧固定间距「刻度梯」：`nav.frame` → `div.scroller`（无滚动条）→ `div.marks`，外加 hover/focus 预览卡 | 桌面：右 12px、宽 28px、`max-height: min(band-64px, 420px)`，垂中；刻度 20×2px、`radius 2`、`scaleX(.6)`，节距 **10px**，两端 inset 6px；未加载刻度 `scaleX(.4)` + opacity .6；当前 `scaleX(1)` + `label-primary`；busy `1s ease-in-out` 闪烁；预览卡 `min(300px, 100cqw-120px)`、`max-height 100px`、`padding 10px 12px`、`radius-lg`=16px、`elevation-panel` | 锚点 `aria-label`：「跳转到第 {turn} 轮」/「加载并跳转到第 {turn} 轮」；预览卡：prompt（13px/20px, 500, 1 行）+ response（12px/18px, `label-caption`, 3 行）；无 prompt 时「第 {turn} 轮」 | 键盘 `focus-visible` 用品牌色描边；`prefers-reduced-motion` 关动效 | `mergeTurnRailItems(loaded, turnOutline)`（`turn-rail-items.ts:63-89`） |
| T5.2 | **手机宽度** | `TurnNavigator.module.css:207-211` | `@container (max-width: 900px) { .frame { display: none } }` | **402pt 下整个 rail 不显示**（容器宽 = 视口宽 - 2×(clearance+16) ≈ 338px ≪ 900px） | — | 官方手机端无替代导航控件；靠 transcript 滚动 + 「回到底部」 | — |

### 2.7 加载更早 / 回到底部 / 历史态

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| T6.1 | `hasMore` | `ChatView.tsx:219-225` | 位于 column 顶部、flow 之前的居中一行 | `.older{display:flex;justify-content:center}`；按钮 `padding:4px 12px; font-size:12px; border-radius: var(--dsw-radius-sm)`=8px；`color: label-secondary`；`background: interactive-bg-hover-solid` = `rgb(241,243,245)`；disabled 时 `cursor:default; opacity:.6`（`ChatView.module.css:227-245`） | 「加载更早」，加载中「加载中…」（`t('loading')`） | 只有按钮，**没有滚到顶自动加载** | `useSession(hasMore/loadingOlder)` |
| T6.2 | 点击「加载更早」 | `use-chat-navigation.ts:93-99`；README:101-103 | `beginPaging()` + `pauseFollowing()` + `loadOlder()`；保留锚点 = 「按钮下方第一个可见内容项」，折叠组锚组头、展开组锚首成员；whole-Turn 折叠时锚第一条仍可见消息（steering/最终回答）；`turn-process` 控制行**不可**当锚 | 补偿不足时不追加底部空间（README:103） | — | 加载中读者滚动优先，滚动停下后的位置成为新锚点（`:123-128`） | viewport preserve |
| T6.3 | `!followingTail` | `ChatView.tsx:240-251` | 浮层槽 `.toBottomSlot` | 槽：`position:absolute; right:0; left:0; bottom:16px; z-index:8`，右内距 `max(clearance+16, (100%-chat-width)/2)`；`[data-conversation-scroll]` 下改 sticky 且 `bottom: calc(var(--dsh-composer-height,152px) + 16px)`；按钮 **34×34**、`border-radius:100px`+`corner-shape:round`、`background: button-floating-fill`（亮=白）、`box-shadow: elevation-panel`、`margin-top:-34px`（`ChatView.module.css:249-299`） | 只有图标（`IconChevronDownOutlineRegular`），无文字 | `aria-label`：**「回到底部」**；hover 底色 `button-floating-hover`；重按后 `followTail()`（`use-chat-scroll.ts:169-173`） | `reading.followingTail` |
| T6.4 | 跟随阈值 | `use-chat-reading.ts:7, 276` | `FOLLOW_THRESHOLD = 24`，实际判定 `24+1 = 25px` 内视作底部 | 25px | — | 有阅读意图（wheel/touchstart/pointerdown/keydown/beforematch，`use-chat-viewport.ts:56-57`）即中断跟随 | — |
| T6.5 | 首次加载 | `ChatView.tsx:213`；`ChatView.tsx:199` | `openState==='loading'` → column 顶部一行提示 | `.hint{font-size:13px; line-height:18px; color: label-tertiary}`（`ChatView.module.css:136-140`） | 「载入历史…」（`locale.ts:85`） | `initialized` 之前 `TurnNavigator` 也不渲染 | — |
| T6.6 | 打开失败 | `ChatView.tsx:214-218` | column 顶部 | `.openError{color: state-error-primary; font-size:13px; line-height:18px}`（`:221-225`） | `chat.loadError` | — | — |

### 2.8 显示模式 / 折叠时机 / 间距矩阵

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| T7.1 | 4 档 work-details | `presentation-policy.ts:23-52` | 每档 = 5 个布尔能力：`foldCompletedTurns / stepGrouping / liveProcessDetail / settledReasoningPreview` | 与字号无关 | Compact / Standard / Detailed / Verbose | `stepGrouping`: collapsed / collapsed / **history** / none；`foldCompletedTurns`: true/true/true/**false** | `ui-chat.transcriptView` |
| T7.2 | 默认值 | `chat-settings.ts:21, 44`；`transcript-view.ts:56-66` | 存储缺省/非法 → 非桌面 Web 用 **`detailed`**，桌面用 `standard`；legacy `normal`/`expanded` 读作 `detailed`（不回写） | — | — | 读默认值不写配置（README:134） | Host 设置 |
| T7.3 | 折叠时机 | `chat-settings.ts:20`；`transcript-view.ts:50-54` | `completion`（默认）/`next-input` | — | Settings → General → Collapse work details | `next-input` 下最新 exchange 完成后保持「运行态外观」，直到下一条输入（README:141） | `ui-chat.collapseTiming` |
| T7.4 | 行间距矩阵 | `ChatView.module.css:68-121` | 相邻 flow 子项 `margin-top: var(--dsh-chat-flow-gap, 6px)`；空 seat 高度 0 且不占间距 | **6px** 默认（组内、过程行之间）；**12px** 回答行自身与其后一行、`.running` 前一行（`--dsh-chat-flow-gap:12px`）；**16px** `turn-process` 控制行自身与其后一行、以及 `[data-turn-process-answer]`；turn-tail 见 T3.4 | — | 行距过渡 160ms（`:99-114`） | — |
| T7.5 | 折叠动效 | `ChatView.tsx:53-54, 210-212`；`ChatView.module.css:99-107` | `MOTION_TAIL_MS = 800`：只在 `next-input` 且（running 或 800ms 尾窗 或 有 pending 输入）时给 column 打 `data-chat-motion` | `160ms cubic-bezier(0.4, 0, 0.2, 1)`；`data-input-fold` 时关闭过渡 | — | 折叠中不再二次滚动（README:143） | — |

## 3. iOS 现状（按 surface 列）

| # | Surface | iOS 实现（file:line） | 现在画成什么 | 行为 | 与官方的差 |
|---|---|---|---|---|---|
| I1 | transcript 容器 | `ChatPage.swift:727-892` | `ScrollViewReader > GeometryReader > ScrollView > LazyVStack(alignment:.leading, spacing:0)`；`.padding(.horizontal,16)`、`.padding(.top,22)`、`.padding(.bottom,48)` | `.defaultScrollAnchor(.bottom)`（`:813`）、`.scrollBounceBehavior(.basedOnSize)`、`.scrollDismissesKeyboard(.interactively)` | 列宽：iOS 内容宽 370pt；官方 `padding: 16px calc(clearance+16px)` = **左右各 32px**、内容宽 **338pt**（`ChatView.module.css:26-28`，`ConversationRoot.module.css:389`，`InputBar.module.css:10`）。顶部官方 16 vs iOS 22；底部官方 16（+ 手机端 `padding-bottom: var(--dsh-composer-height,152px)`，`mobile.module.css:164-166`）vs iOS 48 |
| I2 | 行模型 | `NativeChatTimelineChrome.swift:7-20` | 只有 3 种 `NativeTranscriptRow`：`.item(ChatItem)` / `.contexts([ChatItem])` / `.tools([ChatItem])` | `.id` = item id / `context-group-…` / `tool-run-…` | 官方 19+ 种 chat node kind + 2 级分组 + turn 容器；iOS 没有 turn 概念，没有 `process/response/turn` 位置 |
| I3 | 分组 | `ChatPage.swift:453-475` | 线性扫描：`.context` 相邻并成 `.contexts`；`isToolKind`（`:446-451`）相邻并成 `.tools`；其余逐条 `.item` | 只在**相邻同 kind** 时合并 | 官方按 `groupTree` 位置分组、reply/steering/`model-retry` 都能切组（`process-groups.ts:147-171`）。iOS 违反 3 条官方规则：①`assistant` 回复会断开工具组（官方：reply 也断组 ✓ 但由于 reasoning 是独立行，实际会把「assistant 文本 → 工具」拆成两组而官方是 `G[reasoning] → response → G[tool]` 只有两段，形态不同）②**跨 turn 会把上一轮末尾的工具与本轮开头的工具并成同一个 `.tools` 行**（无 turn 边界检查；turn 之间若没有 user 消息就会出现，例如非人类输入唤醒的连续两轮）③context 在官方不参与分组也不断开（README:210），iOS 会断开工具组 |
| I4 | 「工具组」渲染 | `ChatPage.swift:2349-2361` | `ToolRunRow` = `VStack(alignment:.leading, spacing:6){ ForEach(items){ NativeToolCallRow } }` | **没有组头、没有组级折叠、没有高度上限、没有渐隐** | 官方组是「组头(分类摘要, 14px, 6px gap, 16px leading, 图标/chevron 互换) + 可折叠体(6px 行距, `min(400px,50vh)`, 24px fade)」（T2.2-T2.7）。iOS 只有组内 6pt 行距这一项与官方一致 |
| I5 | 单行 disclosure | `NativeMessageRows.swift:5-55` | `Button{HStack(spacing:0){16×16 图标盒 + 6 trailing; title 13pt; 2×2 圆点 + 左右 8; summary shimmer; Spacer}}`，行高 **24pt** | 展开动画 `.easeOut(duration:0.16)`；展开时图标换成 `chevronDown` 旋转 180°；`disabled` 当不可展开；`accessibilityValue` = 运行中/已展开/已折叠 | 与官方 `DisclosureRow`/`ReasoningRow`（24px 高、2×2 点、8px 边距、13px/20px 摘要、`font-weight:400`）**高度、点、字号基本一致**；差在颜色 token（iOS tertiary `#9A9AA2` vs 官方 `rgb(129,133,140)`）与流式右侧 48px 渐隐（`ReasoningRow.module.css:59-61`）缺失 |
| I6 | 思考行 | `NativeMessageRows.swift:57-85` | 标题固定「思考」，summary = 首行 / 流式时取最后一个完整段落首行，去 `**` | 展开后 `NativeMarkdownBody(variant:.compact)` + `.padding(.leading,22)` | 官方运行中标题是**分类标签**（「正在分析请求」），结束是「已完成分析」，且思考行属于组内成员（6px），iOS 是顶层行（20pt/12pt） |
| I7 | 行间距 | `ChatPage.swift:422-443` | `current==.status→6`；current 为 tool →8；context/nil→8；`current==previous`→12；否则 20 | 施加方式：每个 row `.padding(.top, Self.spacing(before:index,in:rows))`（`:790`） | 官方 6/12/16（T7.4）。逐项差：思考→助手 **20 vs 6**；助手→工具 **8 vs 6**；工具之间 6 vs 6 ✓；助手→用户 20 vs 6；**「换人 20」「同人 12」在官方没有任何对应值** |
| I8 | Turn 完成状态行 | 无（grep `turnProcess` 0 命中） | 不存在 | `turn/end` 只写 `statusLine = "Turn ended: …"`（`ChatModel.swift:1776`），该字符串不进 transcript | 官方 T1.1-T1.7 整条缺失：无「已完成/用时/已停止/处理失败」行，无 turn 级折叠开关 |
| I9 | 停止/失败标记 | `NativeTranscriptProjector.swift:109-133` | `reason.kind == max-tokens` → `.maxTokens` 行；`error` → `.turnError` 行；**`aborted`/`interrupted` 不产生任何行**，只把 `toolState` 改 `.stopped` | `.maxTokens`/`.turnError` 用 `NativeSystemEventRow`（`NativeMessageRows.swift:87-110`）：6×6 圆点 + 13pt medium 标题 + 12pt 正文，`padding(.vertical,4)`，按事件 seq 位置内联 | 官方：三种结束原因都由**turn 尾部的控制行**表达（「已停止」/「处理失败」/正常「已完成，用时 …」），不在流中插行；`.maxTokens` 官方是独立 `turn-max-tokens` 节点但在 `turn-tail` **之前**（`common.ts:15-21` 注释 + `maxTokensNotice: 0.05`）。iOS 的 `.turnError` 会在原位置渲染（可能在 assistant 文本中途），且停止无任何痕迹 |
| I10 | 运行指示 | `ChatPage.swift:1325-1329` | composer 工具条右侧 `ProgressView().controlSize(.small)`（有 `model.turnRunning` 时） | 纯系统 spinner | 官方 T4.1-T4.8 全缺：无 transcript 级运行行、无 14×14 鲸鱼、无「深度求索中，用时 …」、无 12px/22lh 深蓝文本 + shimmer、无 0.5px 分隔线、无 1s tick |
| I11 | 过滤掉的 status 行 | `ChatPage.swift:104-109` + `:2284-2285` | `visibleItems` 排除 `.status`；`case .status: EmptyView()` | — | 说明 iOS 侧曾经有过 status 概念，但**被显式丢弃**；官方所有运行态都在 transcript 里 |
| I12 | Turn tail / 动作行位置 | `ChatPage.swift:2301-2317` | 只有当 `isTurnClosingAssistant`（= 该 turn 内**最后一条** `.assistant` 且非 streaming）时，在**该 assistant 弹窗内部**渲染 `NativeChangedFilesCard` + `NativeMessageActions` | 动作行 28pt 高、gap 8、17px 图标、tertiary（`NativeMessageActions.swift:20-45`）——与官方尺寸一致 | 官方 `turn-tail` 在 `turn/end.seq+0.1`，即**整轮所有内容之后**；iOS 跟在最后一条 assistant 文本后面 ⇒ **当本轮以工具调用结束时，动作行跑到工具行上方**。且官方以「最新 step 的 settled assistant + 有正文 + 无 tool-call block」定义最终回答（`turn-process.ts:117-122`），iOS 只看「最后一条 assistant」 |
| I13 | 最终回答判定所需数据的丢失 | `NativeTranscriptProjector.swift:57` | `case "tool-call": continue` —— assistant message 里的 tool-call block **被丢弃**，该 assistant item 上看不出「本消息带工具调用」 | — | 官方 final-answer 规则的关键条件「no tool-call block」在 iOS 投影后**不可判定**（数据源有，投影层丢） |
| I14 | 加载更早 | `ChatPage.swift:732-749`；`ChatModel.swift:1468-1497` | `Button{ HStack{ ProgressView?; Text("正在加载…"/"加载更早消息") } }.frame(maxWidth:.infinity, minHeight:44).buttonStyle(.bordered)`，位于 LazyVStack 首项 | 请求 `session/page`(`maxMessages:60`) → `items = older + items`；**没有任何滚动锚点补偿**；`loadingEarlierTranscript` 期间 `onChange(transcriptScrollSignature)` 的跟随逻辑被 guard 掉（`:840`） | 官方 T6.1（居中 12px chip、`padding:4px 12px`、radius 8、`#F1F3F5` 底、无 44pt 最小高度）与 T6.2（严格锚点保留）都不同。iOS 在 `LazyVStack` 顶部插入内容后视口数值位置不变 ⇒ 读者眼前的段落**向下跳**，这就是「点加载更早，位置弹走」的根因 |
| I15 | 回到最新 | `ChatPage.swift:875-891` | 浮在 `.overlay(alignment:.bottom)` 的 **文字胶囊**：`Label("回到最新", systemImage:"arrow.down")`，`.caption.weight(.semibold)`(12pt)、`padding(12/8)`、`RoundedRectangle(cornerRadius:12,.continuous)`、底 `#F2F3F5` + `separator` 描边、`.padding(.bottom,12)` | 出现条件 `userScrolledAway && !nearBottom && !visibleItems.isEmpty`；点击 `scrollToLatestTrigger+=1` → `withAnimation(.easeOut 0.2)` 滚到底 | 官方 T6.3：34×34 圆形按钮，只有 chevron，白底 + `elevation-panel` 阴影，**右对齐**到内容列右缘，`bottom:16 + composer height`，文案「回到底部」仅作 `aria-label`。iOS 是居中、带文字、12pt 圆角方块、无阴影 |
| I16 | 跟随阈值 | `ChatPage.swift:818-828` | `nearBottom = tailY >= -1 && tailY <= viewport+44`；`userScrolledAway` 在 `tailY > viewport+44` 时置真 | 需要 `nearBottom && !userScrolledAway` 两个条件同时成立才跟随 / 才显示胶囊 | 官方单一 `followingTail`（25px 阈值 + 意图打断 + 落回底部自动恢复）。iOS 双标志会出现「既不跟随也不显示胶囊」的空档（`userScrolledAway==true` 但 `nearBottom==true` 时胶囊隐藏且不跟随） |
| I17 | 跟随去抖 | `ChatPage.swift:917-931` | `Task.sleep(50ms)` 后若仍 nearBottom 才 `scrollToTail` | 每 1s 打一条 `chat-status.log` 诊断 | 官方用 rAF + `data-chat-following-tail` 时 `overflow-anchor: none`（`ChatView.module.css:36-39`）保证跟随期间不抖；iOS 靠去抖+高度 guard（`transcriptContentHeight > viewport+1` 才滚，`:899`） |
| I18 | 键盘 | `ChatPage.swift:865-871` | 视角高度增大且 nearBottom → `scheduleTailScroll` | `.scrollDismissesKeyboard(.interactively)` | 官方手机端把 composer 改成 `position: fixed` 并用 `padding-bottom: var(--dsh-composer-height)` 预留，避免 iOS 橡皮筋把输入卡顶起来（`mobile.module.css:139-166`）。iOS 是原生键盘安全区，行为等价，但**滚动锚定语义不同**（官方对 composer 高度变化会重算 `--dsh-composer-height`，`ConversationContent.tsx:59`） |
| I19 | 显示模式 | 无（grep `transcriptView`/`compact\|detailed\|verbose` 0 命中） | 固定单一密度 | — | 官方 T7.1-T7.3 全缺（4 档 + 2 种折叠时机 + 默认 detailed） |
| I20 | Turn 导航 | 无（grep `TurnNavigator`/`轮次导航` 0 命中） | — | — | **官方在 ≤900px 容器下也隐藏**（T5.2）⇒ 402pt 上「没有」是正确行为；不构成差距，但需要明确记录为设计决策 |

## 4. 差距清单（核心交付）

> 计量单位一律 pt(=CSS px @402)。「官方证据」「iOS 证据」都是 `file:line`。

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
|---|---|---|---|---|---|---|---|---|---|
| T-01 | **P0** | 完全没有 Turn 容器与「过程折叠」这一层：已关闭的一轮不会把 reasoning/工具/中间回复收进一个可折叠过程块，也没有 turn 级完成状态行 | `README.md:68-96`（whole-Turn folding 规则表）、`turn-process.ts:288-301`、`TurnProcessNodeView.tsx:10-61`、`stores.ts:36-43` | `ChatPage.swift:453-475`（只有 3 种行）、`:2349-2361`；`ChatProcess`/`turnProcess` 全库 0 命中 | 一轮里 12 次工具调用会全部铺满屏幕，答案被顶到很下面；官方是「输入 + 已完成，用时 1分20秒 + 答案 + footer」共 4 块 | ① 新建 `NativeTurn` 视图模型（`turn / startTime / endTime / endReason / status / answerAnchorItemID / hasContent / open`）；② 在 `timelineRows` 之上插入第 4 种 row：`.turn(TurnBlock)`，把一个 turn 的所有「过程成员」收进 `.turn` 的 children；③ 控制行只在 `status == .closed` 时渲染，样式逐字对齐 T1.1（33pt 高含 8pt 下内距 + 0.5pt 下边线 `rgba(0,0,0,0.1)`、14pt/24pt 行高、`#81858C`、右侧 14pt chevron `margin-left:4`、`rotate 180°` 当展开、`transform 100ms ease`）；④ 控制行上下间距 16pt；⑤ 默认折叠：已关闭且非 aborted/interrupted/error、且不是「最新 exchange + next-input」→ 折叠 | `turn/start.time`、`turn/end.time`、`turn/end.reason.kind`（实时已有：`DSHEventMapper.swift:74-78` 产出 `.turnStarted`/`.turnEnded(reason:)`；历史有：journal `turn/start`/`turn/end` 原始记录，但 `NativeTranscriptProjector` 丢弃） | 先补模型字段（`ChatModel.turnStartTime[Int:Date]`、`turnEndReason[Int:String]`），再在 `NativeTranscriptProjector` 增加 `turn/start`/`turn/end` 分支（两者都登记到独立的 `turnFacts` 而不是 `ChatItem`），最后加视图 | 单测：给定 `turn/start(1s)+assistant+tool/tool` 的 journal，断言产生 1 个 turn 块、控制行文案「已完成，用时 2秒」、折叠后可见子项只剩 answer；快照：与官方 402pt 截图逐像素比 33pt 行高与 8pt 内距 |
| T-02 | **P0** | 过程分组不存在：工具/思考没有组头（分类摘要 + 图标 + shimmer）、没有组体高度上限、没有 edge fade、没有组级展开/收起 | `ChatGroupSeat.tsx:115-128, 132-202`、`ChatGroupSeat.module.css:5-19, 48-92, 101-117, 127-139`、`step-process.ts:11-28`、`locale.ts:8-52` | `ChatPage.swift:2349-2361`（`ToolRunRow` 无组头）、`NativeChatTimelineChrome.swift:7-20` | 用户看不到「This turn: 已读取文件并执行了命令」这类一眼可读的过程摘要；一次 8 个工具调用 = 8 行常驻 | ① 新增 `NativeProcessGroup`（header + body）；② header：`HStack(spacing:6)`、leading `16×16` 盒内 14×14 分类图标、标题 14pt/`#81858C`、单行截断；③ 图标集合对齐官方 14 类（`ChatGroupSeat.tsx:38-53`：thinking/read/readImage/search/edit/write/commands/code/webSearch/webFetch/subagents/plan/questions/tools）；④ 关闭态标题按 `processTitle` 规则（前 3 类 + 「并」/「，」/「等」，去重「已」前缀）；运行态标题用 live 分类 + 150ms 最短驻留；⑤ body：行距 6pt、`maxHeight: min(400, 0.5*viewportHeight)`、`overflow: auto`、上下 24pt 渐变遮罩；⑥ 展开时 header `padding-bottom: 8` | 工具名 → 分类映射（`read/read_image/grep\|glob\|*_inspect/write/edit\|apply_patch/bash\|pwsh\|exec_command\|write_stdin\|terminal_*/run_code/web_search/web_fetch/subagent*\|todo_write\|create_goal\|update_goal\|get_goal/ask_user_question\|request_user_input/其余→tools`，README:255-271），iOS 已有 `ChatItem.toolName`（`NativeConversationModels.swift:24`） | 在 `NativeChatTimelineChrome` 里新增 `NativeProcessGroup` + 分类器（纯函数，可测）；`timelineRows` 改为按 turn + 边界规则切组 | 单测：分类表 14 行逐条断言；分组规则 7 条（`process-groups.ts:203-229` 的示例序列 `A1(thought,reply)→T1` 等）逐条断言 roots 结构 |
| T-03 | **P0** | 运行中指示全缺：transcript 尾部没有「深度求索中，用时 X ···」+ 鲸鱼 + shimmer + 分隔线，只有 composer 里一个系统 spinner | `RunningStatus.tsx:20-40`、`RunningWhaleTail.tsx:10-18`、`ChatView.module.css:142-219`、`locale.ts:89-90`、`TextShimmer.module.css:36-66` | `ChatPage.swift:1325-1329`、`:104-109`（`.status` 被过滤）、`:2284-2285` | 手机上看不出「这一轮已经跑了多久」「还在动还是卡住了」；官方是整页唯一的运行时钟 | ① 在 flow 末尾追加 `NativeRunningStatus`，当 `model.turnRunning`；② 结构：0.5pt 分隔线（`margin: 8 0 10`，色 `rgba(0,0,0,0.055)`）+ `HStack(spacing:6)`{14×14 鲸鱼, 12pt/22pt 文本}；③ 文本 `深度求索中` / `深度求索中，用时 1分05秒 ···`（结尾半角空格 + `···`）；④ 颜色 ≈ `rgb(52,94,186)`；⑤ 计时 1s tick、`max(1000ms)`、60 分钟进位、无前导零；⑥ 上一条是输入（user/steering/trigger）时不画分隔线；⑦ shimmer：1.5s、delay .3s、`steps(48,end)`、105° 40%-60% 遮罩；⑧ reduced-motion 下鲸鱼静态、shimmer 关闭；⑨ `role=status aria-live=polite` 只播「深度求索中」 | `turn/start.time`（实时 `HarnessEvent.time` 已有；`ChatModel.swift:1763-1769` 目前只存了 `activeTurn`/`turnRunning`） | 在 `ChatModel` 里存 `runningTurnStart: Date?`（`.turnStarted` 时 = event.time，`.turnEnded` 时清空），视图层用 `TimelineView(.periodic(from:by:1))` 驱动文本 | 单测：`formatRunDuration` 等价函数在 0.4s/1s/59s/60s/3600s/3661s 六个点的输出；快照：与官方 402pt 的 14/22pt 基线对齐 |
| T-04 | **P0** | 停止/失败没有 turn 级标记：`aborted`/`interrupted` 在 transcript 里完全不产生任何 UI；`error` 产生的是流内插行的 `.turnError`，位置与语义都不同 | `TurnProcessNodeView.tsx:20-33`（`stopped`/`failed` 文案）、`contract/turn-process.ts:53-58`（这些状态永不折叠）、`locale.ts:64-66, 157` | `NativeTranscriptProjector.swift:109-133`（aborted/interrupted 无产出）、`ChatModel.swift:1770-1801`（只写 statusLine） | 按了停止以后，屏幕上看不出「这轮被停了」，只留下半截文字和变成「已停止」的工具行；失败时是一行橙点插在流中间 | ① 结束原因归一化为 `completed / stopped / failed / maxTokens`，四态都渲染同一条控制行（T1.1 的样式），文案分别「已完成，用时 …」/「已停止」/「处理失败」/「已达到输出上限」；② `stopped`/`failed` 时**强制 `open == true`** 且隐藏 chevron（不可折叠）；③ 时长：`stopped`/`failed` 不显示；④ turn 尾顺序（官方 `common.ts:15-21`）：`…answer` → `maxTokensNotice(+0.05)` → `turn-tail(+0.1)` | `turn/end.reason.kind`（实时已有；历史 journal 已有，投影丢弃） | 与 T-01 合并实现；把 `.maxTokens`/`.turnError` 从「流内行」改成 turn 级状态 | 单测：四种 reason 各生成一行且文案/可折叠性正确；快照：停止态 |
| T-05 | **P1** | 行间距矩阵与官方不是一套值：iOS 6/8/12/20 vs 官方 6/12/16；「思考 → 助手」20pt（官方组内 6px）、「助手 → 工具」8pt（官方 6px）、turn 边界 20pt（官方无此概念） | `ChatView.module.css:68-84, 116-121`（6/12/16） | `ChatPage.swift:422-443`、`:790` | 一轮多步的会话看起来「散」，行与行之间没有从属关系；官方是同组紧凑、跨组才留白 | 用官方 4 条规则替换 `spacing()`：① 默认 6pt；② 回答行（response）自身与其下一行 12pt；③ `turn-process` 控制行自身与其下一行 16pt；④ 折叠中的过程成员不占间距（`height 0`，`ChatView.module.css:125-127`）。**删掉**「同 kind 12 / 换 kind 20」这两条无出处规则 | 需要 row 带 `role ∈ {turnControl, group, groupMember, response, tail}` | 与 T-01/T-02 一起改（间距必须挂在新的 row 角色上，不能继续按 kind 猜） | 单测：间距矩阵按 row 角色序列断言；快照：`user→(turn控制)→group→response→tail` 五段间距 16/16/12/16 |
| T-06 | **P1** | 工具组会跨 turn 合并：`timelineRows` 只判断相邻 kind，不看 turn 边界；也没有「reply/steering/model-retry 切组」的规则 | `process-groups.ts:147-171`（`isAtOrOutside(node,'process')` 与 reply 切组）、`README.md:203-229` | `ChatPage.swift:462-469` | 上一轮以工具结尾、下一轮以工具开头（非人类输入唤醒）时会合并成同一个 `tool-run-…` 行；因为 id 取首项，列表身份也错位 | 分组输入必须是 `(turn, role, step)` 三元组：turn 变 → 强制切组；`response` 节点 → 切组并独立成根；`steering`/`trigger`/`model-retry`/`turn-error`/`max-tokens`/`turn-tail`/`turn-process` → 切组并独立成根；`context`/`system-prompt`/`permission` → 既不加入也不切断 | `ChatItem.turn`（已有，`NativeConversationModels.swift:21`） | 抽出纯函数 `processRoots(items) -> [Row]`，便于单测 | 单测：官方 README:218-227 的 7 条示例序列逐条断言 |
| T-07 | **P1** | turn tail（动作行）位置错误 + 最终回答判定错误：动作行挂在「最后一条 assistant」内部，会出现在工具行上方；判定只看「最后一条 assistant」 | `turn-tail.ts:63-101, 135-139`（`turn/end.seq + 0.1`，与 assistant 位置解耦）、`turn-process.ts:117-122`（final answer = 最新 step + settled + 有正文 + 无 tool-call block） | `ChatPage.swift:2301-2317`、`NativeTranscriptProjector.swift:57`（`case "tool-call": continue`，tool-call block 被丢弃） | 一轮以工具收尾时，「复制/点赞/分支/用量」跑到工具调用上面，顺序看起来是错的；带工具调用的 assistant 消息也可能被误判成最终回答 | ① 把动作行从 `assistantBody` 里搬到 turn 级 footer 节点，锚在 turn 最后一条内容之后；② 最终回答判定：`step == maxStep` && `settled` && 有可见正文 && 本消息**无** tool-call block；③ footer 间距：上一行是回答 → 12+4=16pt；上一行是过程 → 6+4=10pt（`TurnTailNodeView.module.css:7-11` + `ChatView.module.css:75-84`）；④ `actions` 行 `margin-left: -6`，图标 17pt；⑤ 分支按钮在「本轮之后还有聊天节点」时置灰（`TurnTailNodeView.tsx:34-35, 71`） | 需要保留「本 assistant 消息是否含 tool-call block」→ 投影层加 `ChatItem.hasToolCallBlock`（当前 `continue` 丢掉） | 小改投影 + 移动视图位置 | 单测：`assistant(text, tool-call) → tool` 序列下 footer 必须在 tool 行之后；快照顺序 |
| T-08 | **P1** | 「加载更早」无锚点补偿（位置弹走）+ 按钮规格与官方不同 | `use-chat-navigation.ts:93-99, 114-121`、`README.md:101-103`、`ChatView.module.css:227-245` | `ChatPage.swift:732-749`、`ChatModel.swift:1488-1490`（`items = older + items`）、`:840`（加载中 guard 掉跟随） | 点一下「加载更早消息」，正在读的段落整体往下跳，用户丢失位置 | ① 按钮：居中、12pt、`padding 4pt 12pt`、圆角 8pt、底 `#F1F3F5`、文字 `#61666B`，加载中 `opacity .6` + `disabled`，**去掉 44pt 最小高度和 `.bordered`**；② 锚点：加载前记录「按钮下方第一个可见行」的 `id` + 其相对视口 Y，加载后 `proxy.scrollTo(id, anchor:.top)` 并补偿高度差；折叠组锚组头、展开组锚首成员、turn 控制行不作锚（官方明确排除）；③ 加载中用户滚动优先，滚动结束后的位置成为新锚点 | 需要行级测量（`GeometryReader` preference 已经存在：`TranscriptTailPreference` / `TranscriptContentHeightPreference`，`ChatPage.swift:792-809`） | 先做锚点（用户体验最痛），再做样式 | 手工：加载 3 页观察不跳；单测：给定前后高度，断言补偿值 |
| T-09 | **P1** | 「回到最新」控件形态与行为与官方不同：iOS 居中文字胶囊 / 官方右对齐 34×34 圆形图标按钮；iOS 出现条件用双标志会漏显示 | `ChatView.tsx:240-251`、`ChatView.module.css:249-299`、`use-chat-reading.ts:7`、`locale.ts:88` | `ChatPage.swift:875-891`、`:818-828` | 官方是「回到底部」的小圆钮贴右下；iOS 是屏幕中间一个「回到最新」文字块，和官方视觉语言完全不同 | ① 34×34、`borderRadius 17`（圆形）、白色填充、`shadow`（`elevation-panel`）、只有 chevron 图标；② 右对齐到内容列右缘（`padding-right: max(32, (width-338)/2)`）；③ 距底部 `16pt + composer 高度`；④ 文案只做 `accessibilityLabel("回到底部")`；⑤ 出现条件收敛为单一 `followingTail == false`，阈值 25pt，滚回底部即恢复跟随 | 单一 `followingTail` 状态（现在有 `nearBottom` + `userScrolledAway` 两个） | 先统一跟随状态机，再换皮肤 | 单测：`followingTail` 状态机（滚动离开→false、落底→true、意图打断→false） |
| T-10 | **P1** | 无显示模式（Compact/Standard/Detailed/Verbose）与折叠时机，且默认密度与官方 Web 默认（`detailed`）不一致 | `presentation-policy.ts:23-52`、`chat-settings.ts:21, 44`、`transcript-view.ts:56-66`、`README.md:116-145` | 全库 0 命中（无 `transcriptView`/`collapseTiming`/`verbose`） | iOS 只有一种密度；官方同一条会话在不同模式下「组头有无 / 组体直显与否 / 思考预览有无」差别很大 | 实 4 档能力位（`foldCompletedTurns / stepGrouping / liveProcessDetail / settledReasoningPreview`）+ 2 种时机；默认 `detailed`（非桌面）；`next-input` 时最新 exchange 保持运行态外观直到下一条输入 | 需要持久化（iOS 侧 UserDefaults / 会话设置） | Wave 3；先做 `standard` 与 `verbose` 两端，再补 `compact`/`detailed` | 单测：能力位矩阵 4×2；快照：四档同一 fixture |
| T-11 | P2 | 颜色 token 与官方不完全一致 | `design-platform.css:185-189, 214, 222-225, 343`（tertiary `rgb(129,133,140)`、secondary `rgb(97,102,107)`、caption `rgb(173,178,184)`、border-l2 `rgba(0,0,0,.1)`） | `NativeChatTheme.swift:8-23`（tertiary `#9A9AA2`、secondary `#66666B`、caption `#ADB2B8` ✓、border `#E4E4E8`） | 组头/思考行/工具行读起来比官方「浅一档」，整页偏灰 | tertiary → `#81858C`；secondary → `#61666B`；border → `rgba(0,0,0,0.1)`；新增 `label-deep-diving` ≈ `rgb(52,94,186)` / 暗 `rgb(125,154,222)` | — | 改 `NativeChatTheme` 一处 | 色板单测（新加）+ 截图取色 |
| T-12 | P2 | 单个 streaming assistant 上方有一个 `ProgressView().controlSize(.mini)`；空文本占位「…」 | 官方 assistant 行无 spinner、无占位（`AssistantMarkdown.tsx` 流式靠 markdown 自身；占位无对应） | `ChatPage.swift:2291-2294` | 流式时行首多一个小转圈，官方没有；空文本时先显示「…」 | 删除 per-message spinner（运行态由 T-03 的全局指示承担）；空文本渲染空 | — | 删两行 | 快照 |
| T-13 | P2 | shimmer 参数不同：iOS 只用 `.primary` 色 + 无 `steps(48)`、无 0.3s delay | `TextShimmer.module.css:36-66`（1.5s / steps(48,end) / delay .3s / 105° 40-60% / `label-shimmer`） | `DSHComponents.swift:9-49`（mask 渐变 0/0.4/0.6/1，颜色 `.primary`） | 扫光更「滑」、更亮；官方是 48 档阶梯式 | 改为 `steps(48)`、`1.5s`、`delay 0.3s`、高光色 `rgba(0,0,0,0.3)`（亮）/`rgba(255,255,255,0.45)`（暗） | — | 改 `ShimmerText` | 录屏逐帧比对 |
| T-14 | P2 | reduced-motion / 无障碍缺口：iOS 无 `prefers-reduced-motion` 等价处理（无 `@Environment(\.accessibilityReduceMotion)`），运行态与折叠无 `role=status` 播报 | `ChatView.module.css:204-219`、`TextShimmer.module.css:82-87`、`TurnProcessNodeView.tsx:36`、`RunningStatus.tsx:33`、`ChatGroupSeat.module.css:119-125` | 全库 `accessibilityReduceMotion` 0 命中（`grep -c` = 0） | 开「减弱动态效果」后扫光/旋转仍在动；VoiceOver 不知道这一轮开始/结束了 | ① `@Environment(\.accessibilityReduceMotion)` → shimmer 关闭、鲸鱼静态、折叠过渡改 0；② 运行开始/结束各一次 `UIAccessibility.post(notification:.announcement)`，时钟 tick 不播报 | — | — | 真机开减弱动效 |
| T-15 | P2 | 转录列宽/上下内距与官方不同（16pt vs 32pt 侧距；顶部 22 vs 16） | `ChatView.module.css:26-28`（`padding: 16px calc(clearance + 16px)`）、`ConversationRoot.module.css:389`（`--dsh-composer-side-clearance: 16px`） | `ChatPage.swift:799-803`（`padding(.horizontal,16)`、`.top 22`、`.bottom 48`） | iOS 正文比官方宽 32pt（每侧 16pt），长段落每行字数更多、视觉更「满」 | 侧距 32pt（内容 338pt）、顶 16pt、底 `16pt + composer 高度` | — | 改 3 个 padding（需与 Axis 04 composer 宽度一起改，保持「transcript 比输入卡窄 32pt」） | 截图量像素 |
| T-16 | P2 | 上下文组（`contexts`）有 44pt 最小高度与「N 条」计数，官方 context 不进分组也不显示（被排除在分组输入之外） | `README.md:210`（`Hidden Nodes, system prompts, ordinary Context injection…Excluded`）、`README.md:82` | `NativeChatTimelineChrome.swift:22-65`（`DisclosureGroup` + `minHeight:44` + 「· N 条」） | 官方上下文默认不出现在 chat 流里（只有 turn-trigger notice 才有卡）；iOS 把每条 context 都画成可展开行 | 保持 iOS 现状作为**产品决策**记录在案；若要严格对齐，应默认隐藏、仅在 `turn-trigger` 场景以官方 trigger 卡呈现 | — | 需产品确认 | — |
| T-17 | P2 | 折叠/展开过渡曲线与时长不同：iOS `.easeOut(0.16)`；官方 160ms `cubic-bezier(0.4,0,0.2,1)` | `ChatGroupSeat.module.css:142-144`、`ChatView.module.css:99-107` | `NativeMessageRows.swift:19` | 曲线差异在慢动作下可见 | `animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.16))` | — | — | 录屏 |
| T-18 | P3 | 空 seat 不占高：官方「空/隐藏 seat 高度 0 且不贡献间距」 | `ChatView.module.css:68-73, 125-127` | iOS 没有 seat 概念（`EmptyView` + `ForEach` 已天然不占位）| — | 已一致，无需改 | — | — | — |
| T-19 | P3 | TurnNavigator：官方手机宽度隐藏，iOS 无 | `TurnNavigator.module.css:207-211`（`@container (max-width: 900px) { display:none }`） | 0 命中 | 无差异 | **明确不做**；若未来要在手机上做长会话跳转，必须另行设计（官方未提供手机端替代），不要直接搬桌面 rail | — | 记录为设计决策 | — |

**计数**：P0 = 4（T-01…T-04）；P1 = 6（T-05…T-10）；P2 = 7（T-11…T-17）；P3 = 2（T-18、T-19，其中 T-18 已一致）。

## 5. 隐藏/条件控件清单

| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 备注 |
|---|---|---|---|---|
| `turn-process` 控制行 | `turn.status === 'closed'`（running 时渲染为 `null`） | flow 中该 turn 的第一个位置（`controlAnchorSeq-0.1`） | ❌ | 官方 running 时**看不到**这一行，这也是为什么它需要 T-03 的运行指示补位 |
| 控制行的 chevron | `foldable && hasContent && !turnProcessAlwaysOpen` | 控制行右侧 | ❌ | 无过程内容时只有标题没有箭头（README:95） |
| 控制行「已停止」 | `end.reason.kind ∈ {aborted, interrupted}` | 同上 | ❌ | 且此时永不折叠（`contract/turn-process.ts:57`） |
| 控制行「处理失败」 | `end.reason.kind === 'error'` | 同上 | ❌（iOS 是流内 `.turnError` 行） | |
| 控制行「已完成」（无时长） | `turn.start` 未加载（分页窗口起始于 turn 中部） | 同上 | ❌ | 官方明确「end 加载但 start 缺失 ⇒ 不显示时长」（README:93） |
| 过程组头 | 组有至少 1 个成员 | flow 中该组位置 | ❌ | `Detailed` 在**运行中**隐藏组头、`Verbose` 永远隐藏（README:120-121） |
| 组体直显 | `Detailed` 运行中 / `Verbose` | 组头之后 | ❌ | 官方 `Detailed` 已完成 turn 仍是手动展开（README:121） |
| 组体高度上限 + 渐隐 | 受 `min(400px,50vh)` 限制且有可滚方向 | 组体 | ❌ | `Detailed` 运行中 / `Verbose` 移除上限 |
| 中间回复（intermediate reply）行 | assistant 有 reply 内容但**不是**最终回答 | 组之间，独立行 | ⚠️ 部分 | iOS 渲染成普通 assistant 行，但折叠时不会随过程一起隐藏（因为没有外层折叠） |
| `turn-tail` 动作行 | `turn/end` 已加载 | turn 最后一个节点 | ⚠️ 有但位置错 | 见 T-07 |
| turn-tail slot 贡献（deliverables/plan/schedule/test-files） | 各插件注册 | `turn-tail` 容器内（gap 16px） | ❌ | Axis 03/04 详述 |
| 运行指示 | `session.running` | flow 末尾 | ❌ | 见 T-03 |
| 运行分隔线 | 倒数第二个可见 flow 行不是输入 | 运行指示内部 | ❌ | |
| 「回到底部」按钮 | `!followingTail` | 浮层右下 | ⚠️ 形态不同 | 见 T-09 |
| 「加载更早」 | `hasMore` | column 顶部 | ⚠️ 形态/行为不同 | 见 T-08 |
| 「载入历史…」提示 | `openState === 'loading'` | column 顶部 | ⚠️ 文案不同（iOS：「显示上次对话 · 引擎后台启动中…」） | |
| turn-trigger notice（非人类输入） | 当前 `next-turn` claim 里的非人类消息 | 独立卡（`TurnTriggerNodeView`，0.5px border + radius 20 + 12/16 padding） | ❌ | 属 Axis 02，但它**是过程折叠的边界**：出现后 whole-Turn 折叠失效（README:90） |
| 组头 ikon→chevron 互换 | `:hover` / `:focus-visible` / 展开 | 组头 leading 16×16 | ⚠️ 只有展开态互换 | 触屏无 hover，等价 |
| `sticky` 组头 | 展开的组在滚动时 | 组体顶部 | ❌ | `ReasoningRow.module.css:17-22` 是 reasoning 行的 sticky；组头 sticky 见 `ui-chat` 的 `sticky-header-styles` 测试 |

## 6. 数据链路缺口

| 事件/字段 | 官方消费方 | iOS 映射/投影 | 缺失后果 | 需要补什么 |
|---|---|---|---|---|
| `turn/start.time` | `turn-process`（时长起点）、`RunningStatus`（时钟起点） | 实时：`DSHEventMapper.swift:74-75` → `.turnStarted(turnID:)`，`ChatModel.swift:1763-1769` 只存 `activeTurn`/`turnRunning`，**丢弃 event.time**；历史：`NativeTranscriptProjector` 没有 `turn/start` 分支（`default: continue`，`:144`） | 无法显示任何「用时」 | `HarnessEvent.turnStarted` 增加 `time`（其实 `HarnessEvent.time` 已有，只需存下来）；`ChatModel.runningTurnStart` + `turnStartTimes[turn]`；projector 增加 `turn/start` 分支写入 `turnFacts` |
| `turn/end.reason.kind` | 控制行三态、`turnProcessAlwaysOpen` | 实时：`DSHEventMapper.swift:76-78` → `.turnEnded(reason:)` + `rawTurnEndKind`；`ChatModel.swift:1770-1801` 只转成字符串 `statusLine`；历史：`NativeTranscriptProjector.swift:109-133` 只处理 `max-tokens`/`error`，`aborted`/`interrupted` 无产出 | 停止态不可见、折叠谓词无法计算 | `ChatModel.turnEndReasons[turn]`；projector 保留 reason 到 `turnFacts` |
| `turn/end.time` | 控制行时长终点、tail 时序 | 同上 | 同上 | 同上 |
| assistant 消息是否含 `tool-call` block | 最终回答判定（`turn-process.ts:117-122`） | `NativeTranscriptProjector.swift:57`：`case "tool-call": continue` —— 丢弃，assistant item 上无法判断 | 最终回答误判 ⇒ 动作行位置与折叠边界错 | `ChatItem.hasToolCallBlock: Bool`（或 `blocks: [BlockKind]`） |
| `step`（assistant 的 step 序号） | `messageCountByStep`、`answerStep`、`Detailed` 的 flat/history 切换 | ✅ 已有 `ChatItem.step`（`NativeConversationModels.swift:22`） | — | 直接用 |
| `assistant/message.status`（settled vs interrupted） | `finalNode` 判定 | ⚠️ 只有 `streaming` 布尔（`ChatItem.streaming`） | interrupted 的部分消息与 settled 无法区分 | 加 `settled`/`interrupted` 枚举 |
| `step/start` / `step/end` | turn-process 的 step 边界、`turn-process` 的 150ms/计数 | 实时：只映射成 `.progress(phase:"step")`（`DSHEventMapper.swift:80-81`）；历史：0 处理 | 无法算 step 级边界（对 T-01 的 `answerStep` 判定必需） | 历史 projector 保留 step 时间线；实时保留 `stepStartTimes` |
| `tool/call.arguments` 完整串 | 组头 live detail（160 字符截断）、分类 | ✅ 已有 `ChatItem.arguments` / `argumentsRaw` | — | 直接用 |
| `agent/inbox/spliced`（子 Agent/非人类消息回流） | `ChatFlow` 的 pending 行 + turn-trigger | 实时：`DSHEventMapper.swift:67-73` → `.inboxSpliced`，但 `ChatModel.swift:1719-1721` 直接 `break`；历史：projector 0 处理 | 子 Agent 回流消息完全不可见（→ Axis 02 的 P0） | 交给 Axis 02；但对本轴的影响是：**turn-trigger 边界缺失 ⇒ 分组与折叠谓词的「interleaved input」分支永远为假** |
| `turn.status`(open/closed) | 折叠资格、`ChatFlow` 的空 opening control | ⚠️ 只有 `turnRunning` 一个全局布尔，没有 per-turn status | 多轮同时存在时无法判断哪一轮是 closed | `ChatModel.turnStatus[turn]` |

**结论**：本轴的所有视觉缺口，**数据都在 wire 上**（journal + realtime 都有 `turn/start`/`turn/end`），缺口在 **projector + ChatModel 的投影**。除「是否含 tool-call block」是投影层丢弃导致的信息损失外，**不需要改通道/worker 协议**。

## 7. 实施顺序建议

**Wave 1（结构与状态，P0）**

1. `T-01` Turn 视图模型 + `NativeTurnBlock` 容器（先只做「已关闭轮折叠 + 控制行」，不做分组）。
2. `T-04` 结束原因四态接到控制行（含 `aborted`/`interrupted`）。
3. `T-03` 运行指示（鲸鱼 + 时钟 + shimmer + 分隔线）。

> 这三条一起做，因为它们共享 `turnFacts`（start/end/reason）这一份数据。做完就能用官方 402pt 截图验「一轮 = 输入 + 已完成行 + 答案 + footer」。

**Wave 2（分组与间距，P0/P1）**

4. `T-02` 过程分组（分类器 + 组头 + 组体上限/渐隐）。
5. `T-06` 分组边界规则（按 turn/role，不再按 kind）。
6. `T-05` 间距矩阵替换（6/12/16 + 空 seat 0）。
7. `T-07` 最终回答判定 + turn-tail 归位。

**Wave 3（滚动与细节，P1/P2）**

8. `T-09` 跟随状态机统一 + 「回到底部」重做。
9. `T-08` 加载更早的锚点补偿 + 按钮规格。
10. `T-10` 显示模式 4 档 + 折叠时机。
11. `T-11`/`T-12`/`T-13`/`T-14`/`T-15`/`T-17` token 与动效收尾。

**不做**：`T-19`（TurnNavigator）——官方手机宽度隐藏。

## 8. 未知与需确认

1. **402pt 下 `--dsh-chat-content-width` 的实际解析值**。`ConversationRoot.module.css:384-390` 定义 `clamp(680px, 64% * column-width, 920px)`；手机单列时 64% 只有 ~257px，clamp 会取 680px，故实际由 `.column{width:100%; max-width:var(...)}` 收敛到父宽。由此推导内容列宽 = 视口 402 − 2×(16+16) = **338pt**，与 `InputBar.module.css:10` 的 `padding: 0 var(--dsh-composer-side-clearance)`（16px）推出「输入卡 370、transcript 窄 32」自洽（与 `ChatView.module.css:26-27` 注释一致）。**但这是 CSS 推导，未在官方 Web 402pt 实测**；若实测不是 338，则 T-15 的数值需修正，不改变结论。
2. **官方 402pt 的真实截图缺失**。`docs/receipts/ios-baseline-screens/ios-chat-official.png` 实为 iOS 原生页（见 §1），本轴所有像素值均来自 CSS 静态解析。建议补一张官方 Web 402×874 的「含工具调用的一轮」，用于 T-01/T-02/T-05 的逐像素验收。
3. **`min(400px, 50vh)` 在 874pt 高的手机上**：`50vh = 437pt > 400pt` ⇒ 生效值为 400pt。若键盘弹起（可视高 ~500pt 时 `50vh=250pt`）会变成 250pt——该行为是否随键盘实时变化，源码上 `.body` 的 `max-height` 是 CSS 计算的（会跟随 vh），但 iOS 原生没有 vh 概念，需要产品确认：键盘弹起时组体上限是否也应缩到 `0.5 * 可视高`。
4. **`--dsh-content-font-size` 的默认与设置项**。CSS 里到处是 `var(--dsh-content-font-size, 14px)` 与 `--dsh-content-font-delta`，说明官方有字号设置会整体缩放（含 33px 控制行高与 16px 图标盒）。iOS 全部是固定 `.system(size:)`（无 Dynamic Type），**是否需要支持官方同款字号缩放**是设计决策点（本轴按 14px 基线给合同）。
5. **`Detailed` 模式下「已完成但仍在最新 exchange」的边界**。README:141 说明 `next-input` 时机下最新 exchange 保持运行态外观；`Detailed` 又对已完成 turn 保留组头。两者叠加时（`detailed` + `next-input`）的具体表现，README 只给了原则性描述（`:145`），未给像素级示例，需要官方实测确认。
6. **iOS 侧 `.status` 类型的设计意图**。`ChatItem.Kind` 里有 `.status`、`ChatModel` 里还在写 `statusLine`（`ChatModel.swift:1769, 1776, 1806`），但 UI 层过滤掉（`ChatPage.swift:104-109`）。不确定这是「废弃遗留」还是「给运行详情页用」；若是后者，需确认 T-03 的新指示是否会和它重复。
7. **`scrollbar-gutter: stable`**（`ChatGroupSeat.module.css:91`）在 iOS 上无对应；官方组体滚动条常驻会占位，iOS 若用 `ScrollView` 需决定是否用 `.scrollIndicators(.visible)` 或补内距。视 402pt 下组体是否真的会溢出而定。

## 9. Turn 生命周期状态机

以「turn 级控制行是否渲染 / 是否可折叠 / 过程是否可见 / 运行指示是否显示 / footer 是否显示」为输出，状态由 `(turn.status, end.reason.kind, 是否最新 exchange, 是否加载到 start)` 决定。

| 状态 | 判定条件 | 官方证据 | 控制行 | 可折叠 | 过程可见 | 运行指示 | footer(tail) | iOS 当前 |
|---|---|---|---|---|---|---|---|---|
| `opening`（已开，无过程产出） | `turn/start` 到，尚无 assistant/tool | `ChatFlow.tsx:55-59`（空 opening control）+ `TurnProcessNodeView.tsx:18` 不渲染 | **不渲染**（DOM 占位，`height:0` 不占间距） | — | — | ✅「深度求索中」（无时长） | ❌ | 无（只有 composer spinner） |
| `running` | turn open 且已有过程内容 | `ChatNodeSeat.tsx:62-65`（`liveProcess`） | **不渲染** | — | ✅ 全部可见，组头带 live 标题 + shimmer | ✅「深度求索中，用时 12秒 ···」 | ❌ | 平铺全部行，无指示 |
| `closed/completed` | `turn.status==='closed'`，`reason.kind==='completed'` | `TurnProcessNodeView.tsx:24-30` | ✅「已完成，用时 1分20秒」 | ✅ | 默认折叠（除非最新 exchange + `next-input`） | ❌（消失） | ✅ | 无控制行；过程永远可见 |
| `closed/stopped` | `reason ∈ {aborted, interrupted}` | `contract/turn-process.ts:57` | ✅「已停止」，**无时长** | ❌ 永不折叠 | ✅ 全部可见 | ❌ | ✅ | 无任何标记 |
| `closed/failed` | `reason.kind==='error'` | `TurnProcessNodeView.tsx:28` | ✅「处理失败」，**无时长** | ❌ 永不折叠 | ✅ 全部可见 | ❌ | ✅ | 流内 `.turnError` 行 |
| `closed/max-tokens` | `reason.kind==='max-tokens'` | `common.ts:19`（`maxTokensNotice: 0.05`，在 tail 之前） | ✅（按 completed 处理，保留时长） | ✅ | 按 completed 规则折叠 | ❌ | ✅（且分支仍可用，见 `common.ts:12-14` 注释） | `.maxTokens` 流内行 |
| `closed/blocked`（waiting for input：question/approval） | composer 被 takeover，turn 仍 open | `ChatView.tsx:232-235`（问题/审批接管 composer，不在 flow 里画卡） | 不渲染（open） | — | ✅ | ✅（因为 session 仍在 running） | ❌ | ⚠️ iOS 把待答卡画在 transcript **上方**（`ChatPage.swift:192-193` 把 `cardsRegion` 排在 `transcript` 之前；`:484-560` 是卡片区，`:2139` 是 `QuestionCard` 类型），与官方「接管 composer」位置完全不同（→ Axis 03） |
| `closed/no-start-loaded` | end 已加载、start 未加载 | `README.md:93` | ✅ 有标题、**无时长** | ✅ | 按 closed 规则 | ❌ | ✅（`tokenUsage` 缺失，`turn-tail.ts:90-92`） | 不适用（iOS 一次性 60 条分页，无 throughSeq 语义） |
| `no-start-no-end` | 两者都未加载 | `README.md:94` | **不渲染**（无控制行） | — | ✅ 保持可见 | 按 session 状态 | ❌ | 不适用 |
| `interleaved-input` | 过程起点之后出现输入 | `README.md:90`、`turn-process-presentation.ts:56-60` | ✅ 有标题 | ❌ 整轮折叠失效，只保留组级 disclosure | ✅ 分段保留 + 输入原位 | 按 session | ✅ | 不适用（未实现分组） |

## 10. 验收场景（14 条）

每条都给出「期望可见内容」与「本报告的合同条目」，可直接做成快照。

| # | 场景 | 期望（402pt） | 合同 |
|---|---|---|---|
| A1 | 纯文本一轮：user → assistant(text) → turn end | `user` → 控制行「已完成，用时 1秒」（33pt 行 + 8pt 内距 + 0.5pt 下边线）→ assistant 正文（12pt 上距）→ 动作行（16pt 上距） | T-01, T-05, T-07 |
| A2 | 纯工具一轮：user → tool ×3 → assistant 无正文 → end | `user` → 控制行 → 组头「已调用工具」（或分类摘要）折叠 → 动作行 | T-01, T-02, T-07 |
| A3 | 思考 + 工具 + 中间回复 + 最终回复（README:30-41 的完整例子） | 折叠态：`user` → 控制行 → 最终回答 → 动作行（中间回复/组头都不可见）。展开态：G1 组头 → 中间回复行 → G2 组头 → 最终回答 | T-01, T-02, T-06 |
| A4 | 展开一个组 | 组头 padding-bottom 8pt、组体行距 6pt、高度上限 400pt、上下 24pt 渐隐；再一次点组头收起 | T-02 |
| A5 | `Verbose` 模式 | 无组头、过程行全平铺且直显、控制行保留但**不可折叠**、无 shimmer | T-10 |
| A6 | `On next message` 折叠时机 | 刚完成的一轮**仍显示**运行态外观（组头 + 组体直显），直到下一条输入才折叠，且折叠时无二次滚动 | T-10 |
| A7 | 加载更早（点按钮） | 按钮下方第一个可见行在加载前后**Y 不变**；按钮为居中 12pt chip，加载中变淡且不可点 | T-08 |
| A8 | 用户上滑后新消息到达 | 出现右下 34×34 圆形「回到底部」；滚回底部后自动消失并恢复跟随；上滑期间新内容不把视图拉走 | T-09 |
| A9 | 停止（aborted） | 控制行「已停止」+ chevron 消失（不可折叠）+ 过程全部保持可见 + 运行指示消失 + 工具行「已停止」 | T-04 |
| A10 | 失败（error） | 控制行「处理失败」+ 过程保持可见；不再有流内橙色 error 行 | T-04 |
| A11 | max-tokens | 控制行（正常时长）→ 「已达到输出上限」提示 → 动作行（分支可用） | T-04, T-07 |
| A12 | 键盘弹起（running 中） | 视图跟随到尾部；composer 固定不被橡皮筋顶起；组体上限若随可视高变化需产品确认（§8-3） | T-03, T-15 |
| A13 | 运行中 12 秒 | transcript 末尾：0.5pt 分隔线（8/10pt 边距）+ 14×14 鲸鱼 + 「深度求索中，用时 12秒 ···」（12pt/22pt，`rgb(52,94,186)`，shimmer 1.5s steps(48)） | T-03 |
| A14 | 上一条是 user 消息且正在运行 | 运行指示**不画**分隔线（避免在输入和状态之间加线） | T-03 |

---

**审计者备注**：本报告的 19 条差距中，T-01…T-07 构成一个不可拆的整体（Turn 模型是其余一切的地基）；T-08/T-09 是独立的滚动体验修复，可以不依赖 Turn 模型先落地。官方 `conversation-nodes/README.md` 是本次审计中信息密度最高的一手材料，建议实施 T-01/T-02 时逐条对照其表格。
