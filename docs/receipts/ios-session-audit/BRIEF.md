# iOS Session 会话线 — 官方 DSH 对齐审计 BRIEF（v1）

> 本文件是所有审计子 Agent 的共享上下文。先完整读本文件，再读你的轴任务。
> 审计对象是 **session 会话内容页**，不是会话列表、设置、工作区。

## 1. 任务与验收标准

用户要求：**iOS 原生 session 会话页，近乎像素级还原官方 DSH 的 session 消息流**。
当前感觉缺口集中在「只有被调起才出现的控件/信息流」：

- 计划（todo / plan / plan review / plan mode）
- 遇到问题提问（ask_user_question 的待回答与已回答两种形态）
- 派子 Agent 时消息流里的子 Agent 状态、子会话入口、子 Agent 消息回流
- 收到新消息（尤其是子 Agent / 后台任务 / 定时任务 / goal 等非人类输入）
- 其他深藏在官方消息流、条件出现、iOS 完全没画或画错的控件

你的成果不是泛泛的“建议”，而是**可实施的差距清单 + 像素级对齐合同**：
官方每个元素在 402pt 宽度下的真实尺寸/字号/行高/间距/颜色/圆角/图标/文案/状态/动效，
iOS 现在是什么，差多少，数据从哪来，怎么补，怎么验。

## 2. 两个代码库（绝对路径）

### iOS 端（本仓库）

`/Users/leilangsheng/Desktop/TonoTeam/phone-dsh`

- App 与原生 UI：`examples/probe-app/PhoneDSHProbe/`
  - `ChatPage.swift`（约 2962 行）— 整个会话页：自绘页头、待处理卡区、transcript、行渲染、composer、slash/reference 菜单、权限卡、运行详情、Debug 预览
  - `ChatModel.swift`（约 2417 行）— 状态、事件泵、历史加载、发送/steering/停止/排队、question/permission 应答、goal、指标
  - `NativeConversationModels.swift` — `ChatItem` / `ChatItem.Kind` / usage / attachment / context pressure 等投影模型
  - `NativeTranscriptProjector.swift` — durable journal events → `ChatItem`（历史投影）
  - `NativeMessageRows.swift` — 思考行、系统事件行、附件列表
  - `NativeChatTimelineChrome.swift` — 上下文分组行、`NativeTranscriptRow`（item/contexts/tools 三种）
  - `NativeToolCallModel.swift`、`NativeToolDetailCards.swift`、`ToolWording.swift` — 工具行、工具详情卡、工具文案
  - `NativeMessageActions.swift`、`NativeMarkdownBody.swift`、`NativeMarkdownModel.swift`、`NativeCodeHighlighter.swift`、`NativeChatFormatting.swift` — 消息动作、Markdown/代码
  - `NativeChatTheme.swift` — iOS 当前 token 与图标
  - `NativeComposerStats.swift` — composer 底部统计
  - `NativeChangedFilesCard.swift`、`NativeDiffModel.swift`
  - `NativeShell.swift`、`RootView.swift` — 外层导航；只在需要页头/抽屉上下文时看，不是本次主对象
- 数据/协议层：
  - `Sources/PhoneDSHAgentCore/AgentHarness.swift` — `HarnessEvent.Kind`、`HarnessQuestion`、`HarnessGoal`、`HarnessCommand`
  - `Sources/PhoneDSHAgentCore/DSH/DSHEventMapper.swift` — DSH journal event → `HarnessEvent`（**当前只映射很少的事件类型**）
  - `Sources/PhoneDSHAgentCore/DSH/DSHMessageSourceClassifier.swift`
  - `Sources/PhoneDSHAgentCore/DSH/DSHRemoteHarness.swift`、`DSHRemoteTransport.swift`
  - `Sources/PhoneDSHGateway/`、`Sources/PhoneDSHController/`、`Sources/PhoneDSHLoopback/`
  - `plugins/channel/`、`plugins/worker-entry/`、`plugins/phone-shell/`、`plugins/surface-phone/` — Worker/通道事件转发与会话读取
- 现有测试（很薄，可作为缺口证据）：
  - `examples/probe-app/PhoneDSHSimTests/NativeChatPresentationTests.swift`
  - `examples/probe-app/PhoneDSHSimTests/NativeMarkdownTests.swift`
  - `examples/probe-app/PhoneDSHSimTests/ChatWorkflowTests.swift`
  - `Tests/PhoneDSHTests/`、`Tests/PhoneDSHGatewayTests/`
- 现有基线截图：`docs/receipts/ios-baseline-screens/`（1206×2622 @3x，即 402×874 pt）
  - `ios-chat-default.png`、`ios-chat-assistant.png`、`ios-chat-long.png`、`ios-chat-permission.png`、`ios-chat-queued.png`、`ios-chat-failed.png`、`ios-code-block.png`、`ios-chat-official.png` 等
  - 这些是当前原生页（`-uiPreview`）或官方页的截图，可读图对照；不要把它们当作代码事实。

### 官方 DSH（Web UI 基线）

`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`

> 注意：runtime 里写的路径少了一段 `-deepseek`，以上面的为准。
> 基线 commit：`7be5505b0be06009d74891c869063c9cf19a0df0`，版本 `0.2.1-rc.2`，与
> `plugins/dsh-pin.json` 完全一致。**不要 git checkout / fetch / 改工作区。**

- Web UI 入口与 shell：`apps/web/`、`packages/client/`
- session/chat 核心：
  - `packages/client/ui-chat/src/client/` — chat 节点定义、事件投影、行渲染
    - `contract/chat-nodes.ts`（`ChatNodeDataMap` 跨包合并）、`contract/chat-visibility.ts`、`contract/turn-process.ts`
    - `conversation-nodes/` — `inbox.ts`、`message.ts`、`request-prompt.ts`、`assistant.ts`、`tool.ts`、`command.ts`、`compaction.ts`、`retry.ts`、`turn-error.ts`、`turn-max-tokens.ts`、`turn-process.ts`、`turn-tail.ts`、`event-projection.ts`、`process-groups.ts`、`fallback.ts`
    - `chat/` — `ChatView.tsx`、`AssistantNodeView.tsx`、`MessageItem.tsx`、`TurnProcessNodeView.tsx`、`TurnTailNodeView.tsx`、`TurnTriggerNodeView.tsx`、`ReasoningRow.tsx`、`TurnNavigator.tsx`、`RunningStatus.tsx`、`ChatView.module.css`、`MessageItem.module.css`、`AssistantMarkdown.module.css` 等
  - `packages/client/ui-conversation/src/client/` — 会话壳、composer、滚动、queue、todo dock
    - `skeleton/ConversationRoot.tsx`、`ConversationContent.tsx`、`ConversationHeader.tsx`、`InputBar.tsx`、`TodoPanel.tsx`、`ContextMeter.tsx`、`EmptyHero.tsx`、`ConversationRoot.module.css`、`InputBar.module.css`、`TodoPanel.module.css`
    - `queue/QueueDock.tsx` / `.module.css`
    - `input/`（slash/@ trigger、editor、submission machine）、`user-text/`
  - `packages/client/ui-tool/src/client/tool/` — 工具卡
    - `ToolCallTree.tsx`、`components/ToolRow.tsx`、`ToolDetails.tsx`、`AskQuestionCard.tsx`、`ExitCodeBadge.tsx`
    - `toolviews/`（**约 51 个 toolview key**：bash、read、read_image、grep、glob、web_search、web_fetch、write、edit、todo_write、ask_user_question、subagent、wait_agent、send_message、list_agents、spawn_teammate、team_task_*、job_*、schedule_*、create_goal/get_goal/update_goal、workflow、ralph、session_*、lsp、terminal_*、cordis_*、present、probe、skill、mystery 等）
    - `models/`（`tool-call-model`、`ask-question-card-model`、`details-card-model`、`diff-card-model`、`read-card-model`、`search-card-model`、`terminal-card-model`、`image-card-model`、`todo-diff-model`、`todo-history` 等）
  - `packages/client/ui-plan/src/client/` — 计划卡、计划审阅、plan mode 控件
    - `plan-definition.ts`、`PlanCard.tsx`、`PlanPreview.tsx`、`PlanReviewPanel.tsx`（在 ui-user-questions）、`PlanModeControl.tsx`、`review-store.ts`
  - `packages/client/ui-user-questions/src/client/` — 提问
    - `QuestionComposer.tsx`、`QuestionReplyView.tsx`、`PlanReviewPanel.tsx`、`draft-store.ts`、`question-reply.ts`、各自 CSS
  - `packages/client/ui-subagent/src/client/` — 子 Agent 目录、页头 lineage、只读 composer、右侧栏 chat
  - `packages/client/ui-goal/src/client/` — GoalBar、goal command input
  - `packages/client/ui-approval/src/client/` — ApprovalPanel（权限/审批）
  - `packages/client/ui-message-feedback/` — 点赞/点踩
  - `packages/client/ui-commands/`、`ui-input-trigger/`、`ui-shortcuts/` — 命令与输入触发
  - `packages/client/ui-workflow-run/`、`ui-deliverables/`、`ui-jobs/`、`ui-schedule/` — 工作流、交付物、后台任务、定时任务
  - `packages/client/ui-renderer/`、`ui-attachment/`、`ui-primitives/` — Markdown/代码/附件/基础组件
  - `packages/client/ui-mobile/src/client/mobile.module.css` — **手机宽度（<640px）的官方布局覆盖**，非常重要
  - `packages/client/ui-theme/src/styles/design-platform.css`、`base.css`、`corner-shape.css`、`focus.css` — token
- 协议/事件：
  - `packages/session/`、`packages/api/`（session events、wire schema、session controller）
  - `packages/plan/`、`packages/todo/`、`packages/subagent/`、`packages/goal/`、`packages/interaction/`
- 官方中文文案：`packages/client/ui-chat/src/client/locale.ts`（zh/en 同文件）、`ui-tool/src/client/locale.ts`、`ui-plan/src/client/locales.ts`、`ui-user-questions/src/client/locales.ts`、`ui-subagent/src/client/locales.ts`、`ui-conversation/src/client/locales.ts`、`ui-goal/src/client/locales.ts` 等。**iOS 文案应以这些中文串为准**，不要自己发明。
- 官方测试（行为证据）：`packages/client/ui-*/tests/`、`apps/web/tests/*.e2e.ts`（含 `question-composer.e2e.ts`、`steering.e2e.ts`、`shipped-composition.e2e.ts`）

## 3. 范围

**只看 session 内容会话这条线。** 包含：

1. 会话页页头（标题、运行状态、更多、子 Agent lineage/目录、session 级 actions）
2. 消息流（transcript）本身：所有 row/node 类型、顺序、分组、折叠、空态、加载更早、turn 导航、运行指示、滚动/跟随/新消息提示
3. 消息流里条件出现的控件：todo/plan、question、question reply、approval、goal、queue、turn trigger、subagent、workflow-run、schedule card、deliverable、compaction、retry、error、max tokens、command、system prompt、images/attachments、feedback/actions
4. composer 与它上方/内部的 dock：model、access/permission mode、plan mode、slash/@、attachments、queue、todo、goal、context meter、stats、send/stop、busy Enter 行为
5. 工具行/工具卡：所有 toolview 的视觉与展开态、preparing/running/ok/error/stopped、嵌套 subcall、文件/diff/terminal/search/web/image 卡片
6. 支撑以上 UI 的数据链路：DSH event → 通道 → `HarnessEvent` → `ChatModel`/projector → `ChatItem` → SwiftUI；历史加载、重放、cursor、子会话读取
7. 以上全部在手机宽度（402pt）下的视觉/交互，包括键盘、safe area、滚动锚定、动效、深色模式（官方深色 token）

**不包含**（除非直接影响会话页）：会话列表抽屉、设置页、工作区/文件页、模型服务配置、MCP 配置、原生外壳导航、探针页。

## 4. 已核实的 iOS 现状（起点，不是结论；请自己复核并扩展）

- `ChatItem.Kind` 只有：`user, context, assistant, reasoning, image, toolCall, toolResult(isError:), systemEvent, turnError, maxTokens, unknown, status`（`NativeConversationModels.swift:8-12`）。
- 历史投影 `NativeTranscriptProjector.items` 只处理：`user/message`、`agent/steering/message`、`assistant/message`（text/reasoning/image/tool-call）、`tool/call`、`tool/result`、`turn/end`、`llm/retry(-started)`、`compaction/*`；其余 `default: continue`（`NativeTranscriptProjector.swift:18-150`）。**不处理 `agent/inbox/spliced`、`turn/start`、`step/start`、`tool/ptc-dispatch*`、`user-question/*`、`todo/*`、`subagent/*`、`goal/*`、`approval/*`、`command/*`、`system-prompt/*`、`developer/message` 等。**
- 实时映射 `DSHEventMapper.map` 只处理：`user/message`、`agent/inbox/spliced`、`turn/start`、`turn/end`、`step/start`、`assistant/message`、`tool/call`、`tool/result`；其余 `default: break`（`DSHEventMapper.swift:50-116`）。
- `ChatModel.handle` 收到 `.inboxSpliced` 直接 `break`，注释是“durable projections exist for transcript/audit consumers”（`ChatModel.swift:1711-1714`）；历史 projector 也不处理，所以**子 Agent 消息/新消息在 iOS 上完全不可见**。
- `pendingQuestion` 只画成 transcript 上方的待处理卡（`ChatPage.swift:2139-2245`），回答后没有 `question-reply` 行；没有 `ask_user_question` 的工具卡；没有 plan review 形态。
- 没有任何 todo/plan 面板、plan mode、plan card、plan review（grep `todo`/`plan` 只命中 access mode `"plan": "只出方案"` 与 goal/restart 计划，不是会话计划）。
- 没有 subagent 目录/lineage/子会话聊天/只读 composer；`subagent` 工具只有通用标题“子 Agent”（`NativeToolCallModel.swift:51`）。
- 工具卡只有 7 个 variant（search/read/bash/write/edit/code/others）+ 少量特判；官方有 51 个 toolview。
- 权限卡是页面上方的 `PermissionCardView`（`ChatPage.swift:2907`），不是 transcript row；官方是 composer/approval 面板 + transcript 记录。
- 官方 `conversation.chat.node` 注册的 kind 至少有：`assistant-step, command, command-input, compaction, context, manual-compaction, model-retry, question-reply, steering, system-prompt, tool-call, turn-error, turn-max-tokens, turn-process, turn-tail, turn-trigger, unknown, user, workflow-run`。
- 官方 `conversation.input.dock` 有 `goal`、`queue`、`todo` 三个 dock；`conversation.composer.dock` 有 `activity`、`usage`；`conversation.input.overlay` 有 `command-popup`、`feedback-dialog`、`slash-menu`；`conversation.chat.turnTail` 有 deliverables、plan preview、schedule-created、test-file-deliveries 等贡献。
- 官方手机宽度布局由 `ui-mobile/src/client/mobile.module.css` 覆盖：<640px 单列、抽屉、composer 固定、16px 输入字号、`--dsh-composer-height` 预留等；官方截图 402×874pt。
- iOS 当前主题 `NativeChatTheme`：body 14、secondary 13、caption 12、code 12；primary #111114、secondary #66666B、tertiary #9A9AA2、caption #ADB2B8、selector #F2F3F5、border #E4E4E8、accent #3964FE 等（`NativeChatTheme.swift:7-30`）。**不要假设它等于官方 token，逐个核。**

## 5. 审计要求（重要）

### 5.1 证据规则

- 每个结论必须给 **两个仓库的 `file:line`**；缺失也要给“穷尽搜索”的证据（搜索命令 + 0 结果）。
- 官方行为以源码 + 官方测试 + 官方 locale 为准；不要凭截图猜实现。
- 截图可作为视觉佐证，但必须标明“截图观察”，不要写成源码事实。
- 不要修改 `Sources/`、`examples/`、官方 checkout；只允许写你的报告文件。
- 不要运行 `git checkout`、`git reset`、`git clean`、`git fetch`；不要删除任何文件。
- 不要声称跑过测试/构建，除非你真的跑了并给出命令与结果。审计以静态阅读为主；如需跑测试，先确认不会改工作区。

### 5.2 近像素级要求

对每个可见元素，尽量给出：

- **结构**：DOM/视图层级、顺序、对齐轴、最大宽度、是否可折叠、空态
- **排版**：font-family、font-size、font-weight、line-height、letter-spacing、tabular-nums、截断/换行规则
- **间距**：padding、margin、gap、行高、section 间距、dock inset、safe-area
- **颜色**：官方 CSS 变量名 + 解析后的 light/dark RGB/alpha；iOS 当前值
- **形状**：border-radius（注意官方 `corner-shape`/continuous）、border 宽度、阴影/elevation、backdrop-filter
- **图标**：官方 icon 组件名/尺寸/颜色；iOS 当前 SF Symbol 或 asset，差在哪
- **状态**：default/hover/pressed/focus/running/preparing/error/stopped/disabled/empty/overflow
- **动效**：duration、easing、shimmer、折叠/展开、滚动跟随、reduced motion
- **文案**：官方中文原文（含标点、全角/半角、省略号、数字格式）；iOS 当前文案
- **手机宽度特化**：<640px 的覆盖；402pt 下的换行/截断；键盘弹起；safe area
- **可访问性**：aria-label/role/expanded、Dynamic Type、VoiceOver 顺序（能推断就写）
- **交互**：点击区域、长按、滑动、双击、焦点、键盘、滚动锚定、手势冲突

如果官方组件在桌面宽度和手机宽度行为不同，**以手机宽度为准**；官方没有手机特化的桌面交互（如右侧栏），指出这是设计决策点，并给出官方手机端的替代路径（抽屉/底部 sheet/整页 push），不要默默发明。

### 5.3 严重度

- **P0（阻断对齐）**：官方有、iOS 完全没有入口/状态，或关键交互不可用；例如 todo/plan、question reply、subagent 状态与消息回流、turn trigger/inbox、审批记录、折叠/分组。
- **P1（明显不一致）**：功能有但视觉/文案/状态/顺序/密度明显不同，用户一眼能看出不是官方。
- **P2（细节）**：间距 1–4pt、字体权重、圆角、图标、动效曲线、边缘态等像素级差异。
- **P3（增强）**：官方也非核心、低频率的 toolview/边角。

### 5.4 报告模板

写到 `docs/receipts/ios-session-audit/<NN>-<axis>.md`（NN 由任务指定）。结构：

```markdown
# <Axis> — iOS Session 对齐审计

## 0. 结论摘要
- 3–6 条，含 P0/P1 数量

## 1. 审计范围与方法
- 读了哪些文件/包/测试；用了哪些搜索；截图对照

## 2. 官方基线（按 surface 列）
| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
...

## 3. iOS 现状（按 surface 列）
| # | Surface | iOS 实现（file:line） | 现在画成什么 | 行为 | 与官方的差 |
...

## 4. 差距清单（核心交付）
| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
...

## 5. 隐藏/条件控件清单
| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 备注 |
...

## 6. 数据链路缺口
| 事件/字段 | 官方消费方 | iOS 映射/投影 | 缺失后果 | 需要补什么 |
...

## 7. 实施顺序建议
- Wave 1 / 2 / 3，按依赖与用户价值

## 8. 未知与需确认
- 无法从源码确定的视觉/交互；需要真机/截图/产品决策的点
```

报告用中文写；代码标识、类型名、CSS 变量、copy 原文保留英文/原文。表格单元格可以长，但不要贴大段源码；用 `file:line` + 短引用。

### 5.5 返回给编排者的 JSON

除了写报告，最后返回一个**紧凑** JSON（不要重复报告全文）：

```json
{
  "axis": "<NN-axis>",
  "report_path": "docs/receipts/ios-session-audit/NN-axis.md",
  "summary": "3-5 句话",
  "p0_count": 0,
  "p1_count": 0,
  "p2_count": 0,
  "top_gaps": [
    {"id": "...", "severity": "P0", "title": "...", "official": "file:line", "ios": "file:line", "one_line_fix": "..."}
  ],
  "hidden_surfaces_missing": ["..."],
  "data_gaps": ["..."],
  "unknowns": ["..."]
}
```

`top_gaps` 最多 8 条；完整清单在 Markdown 里。

## 6. 建议的取证手法

- `git grep -n` / `rg -n` 在官方包内找 slot 注册、`ChatNodeDataMap`、`tool.call.toolview`、`conversation.input.dock`、`conversation.chat.turnTail`、`message.trigger.*`、`ui-mobile`、`@media (max-width: 639px)`。
- 官方 CSS：直接读 `*.module.css`，把 `var(--dsw-*)` 解析到 `design-platform.css` / `base.css` 的静态值；注意 `color-mix`、`light-dark()`、`@media (prefers-color-scheme: dark)`。
- 官方测试常把行为写成断言：`packages/client/ui-*/tests/*.spec.ts(x)`、`apps/web/tests/*.e2e.ts`；优先引用这些作为“官方行为”证据。
- iOS：从 `ChatPage.swift` 的 `body`/`transcript`/`composer`/`ChatMessageRow`/`NativeToolCallRow` 进入；从 `ChatModel.handle`/`loadSessionHistory`/`NativeTranscriptProjector` 进入数据；从 `NativeChatTheme` 进入 token。
- 截图：`docs/receipts/ios-baseline-screens/` 的 1206×2622 是 @3x，除以 3 得 pt；官方截图 `ios-chat-official.png` 可作手机宽度视觉基线。只看图时标注“截图观察”。
- 需要对比官方 Web 实测时，优先用现有 `examples/probe-app/Bundle/worker/web` 静态产物 + 本地静态服务器 + Playwright（若环境已有），但**不要为此大改环境**；做不到就在报告里写“未实测，源码推断”。

## 7. 重要提醒

- 用户要的是“**近乎像素级**”，不是“功能有了就行”。每个 P0/P1 都要给出可执行的像素合同，而不是“参考官方”。
- 用户特别点名：**计划、提问、子 Agent 运行状态/消息、收到新消息**。这四类必须重点覆盖、给出完整状态机。
- 官方 DSH 的很多控件是 **slot 注入 + 条件渲染**，代码里分散；务必找到所有注册点，而不是只看一个组件。
- 不要被“当前 iOS 已经有的东西”带偏：先建官方清单，再逐项对照 iOS；不要只从 iOS 现有代码反推需求。
- 如果发现 iOS 的数据层根本拿不到某类事件（例如 channel 没转发、worker 没暴露、历史 API 不返回），这比 UI 缺失更优先，必须写进“数据链路缺口”。
