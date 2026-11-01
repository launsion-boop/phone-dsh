# Axis 04 — 子 Agent / inbox / 收到新消息

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只审 **子 Agent 与“非人类输入/新消息”在 session 会话页上的全部可见形态**。

报告路径：`docs/receipts/ios-session-audit/04-subagent-inbox.md`

## 目标

用户点名三件事：
- 派子 Agent 时，信息流里要能看到子 Agent 运行状态；
- 子 Agent 发来的消息（新消息）要能在页面看到；
- 这些官方控件平时藏着、只有被调起才出现。

官方没有一张简单的“子 Agent 卡”。它的可见性分散在：工具行/进程组摘要、`subagent-settled` 触发行、inbox 分流（steering/context/turn-trigger）、页头 lineage/目录、子会话侧栏、只读 composer、后台任务/定时任务/goal 的触发通知、以及浏览器 push。请把这些全部找全，并给出 iOS 的数据与 UI 缺口。

## 必须覆盖

### A. 子 Agent 生命周期在消息流里的呈现

1. 官方如何把一个 `subagent`（以及 `subagent_*` 变体）工具调用放进进程组：
   - `isSubagentDelegationTool`、`TurnProcessSpec.subagentCount`、`TurnProcessNodeView` 的 `data-turn-process-subagents`、进程组标题/摘要（“正在协调子智能体 / 已协调子智能体”“N 个 subagent”）
   - 运行中/完成/失败/停止时分别显示什么；折叠态与展开态；是否显示 child 名称/模型/任务
2. `subagent` / `list_agents` / `send_message` / `interrupt_agent` / `wait_agent` / `spawn_teammate` / `team_task_*` 工具行：
   - 官方 toolview（`details-row.tsx` 等）的标题、图标、summary、details 卡字段、状态、嵌套 subcall
   - `wait_agent` 的 “No active subagents”、超时/进度；`send_message` 的投递/失败；`list_agents` 的状态表
3. **`subagent-settled` 触发行**：
   - `turn-trigger.ts` 的 source.kind 分支、`TurnTriggerNodeView` 的图标（agent-preset）/标题“子任务状态更新”/时间/展开说明/body
   - 它何时是 turn-trigger、何时是 steering、何时是 context；与 `agent/inbox/spliced` 的 next-step/next-turn 关系
   - 它是否显示 child 的结果/消息正文；点击能否跳到子会话
4. **页头 lineage / 子 Agent 目录**：
   - `ConversationSession.tsx` 的 breadcrumb（parent / child、`crumbSubagent`）、`SubagentHeaderLineage`、`SubagentCatalogAction`、`ui-subagent` 的 locales/CSS
   - 从父会话进入子会话、从子会话回父会话、目录里运行状态/数量、手机宽度下如何收纳（header action? mobile menu?）
   - 子会话的只读 composer（`SubagentReadOnlyComposer`：one-shot / parent-unavailable / unknown）、continuable 子会话的普通 composer
5. **子会话侧栏 chat**：
   - `ui-subagent/sidebar-chat` 的资源地址、右侧栏 tab、手机端 drawer/sheet、标题、关闭、与主会话切换
   - iOS 是否有任何对应能力（大概率没有；要查 `SessionsPage`/`DSHManagementModel`/`NativeShell`）
6. **子 Agent 消息回流父会话**：
   - 官方 `subagent` / `send_message` 如何向父会话注入 user-role 消息；source.kind 是什么（`subagent-settled` / `agent-message` / `team-message`?）
   - 父会话在 running（next-step）与 idle（next-turn）两种时机分别如何显示：steering 气泡、turn-trigger 通知、context 行、还是仅内部
   - 是否需要用户操作才能看到；是否有“新消息”提示、滚动跟随、未读标记、通知/push
   - `ChatView` 的 `inboxSteering`/`pendingInputs` 如何把已 admit 的 steering 变成可见气泡；iOS 的 `inboxSpliced` 丢弃造成什么
7. **其他会“叫醒”会话的非人类输入**（同一套 trigger/inbox 机制）：
   - `goal`、`schedule`、`tool-jobs`、`cordis-host-runner`、`webhook`（github）、`agent-message`、`team-message`
   - 每种在消息流里的图标/标题/说明/展开 body；与 `turn-trigger` 的统一/差异
   - 后台任务完成、定时任务到点、goal round、子 Agent 完成时，用户分别看到什么
8. **运行状态/通知**：
   - 子 Agent 运行中时父会话的 running 指示/进程组标题是否变化
   - 官方 PWA/浏览器通知（`ui-mobile/src/push.ts`）的触发与文案；站内是否有 banner/toast/unread
   - iOS 后台保活/本地通知能力现状（只查与本会话可见性相关的部分）

### B. iOS 现状

9. `ChatModel.handle` 的 `.inboxSpliced` 直接 break；`NativeTranscriptProjector` 不处理 `agent/inbox/spliced`；确认“子 Agent 消息完全不可见”。
10. iOS 是否有 `subagent`/`list_agents`/`wait_agent`/`send_message` 的工具特判（`NativeToolCallModel` 只有标题“子 Agent”）；通用卡显示什么。
11. iOS 是否知道当前 session 是子会话、父会话是谁；`HarnessSessionRequest`/`DSHRemoteHarness`/`DSHManagementModel` 是否有 parent/child 字段。
12. iOS 是否能列出/订阅 child session；`SessionsPage` 是否会显示子会话；`list_agents` 结果是否可点开。
13. iOS 页头只有标题 + 运行状态 + 更多；没有 breadcrumb、目录、子会话入口。评估插入位置与手机宽度约束。
14. iOS 的“收到新消息”能力：transcript 自动跟随、`nearBottom`/`userScrolledAway`、`回到最新` 按钮；新行到达时是否有提示/未读；与官方 `TurnNavigator`/scroll 行为的差异（细节可引用 Axis 05，但这里要写“子 Agent 消息到达”的具体表现）。

### C. 数据

15. 官方 child session 的地址/身份：`SubagentAddress`（parentSessionId、childSessionId、mode）、`sessions.retain`、projection `subagent`；iOS 需要哪些字段才能实现 lineage/catalog/side chat。
16. `subagent` 工具结果/metadata 里是否含 child session id、状态、标题、模型、token；`list_agents` 的返回结构；`wait_agent` 的进度结构。
17. `agent/inbox/spliced` 的 data 结构（target、start、removedCount、inserted[].source/content/id）；iOS Mapper 已经映射了 `inboxSpliced`，但 ChatModel 丢弃；历史 projector 不处理。给出修复所需的最小模型。
18. 如果子 Agent 消息在 iOS 现有通道里根本不到达（worker/channel 过滤），明确标注为 Axis 01 的 P0 数据卡点。

### D. 像素规格

19. 对以下给 402pt 下的精确规格：
   - 进程组标题里的 subagent 计数 / “协调子智能体”
   - subagent / wait_agent / send_message 工具行（折叠/展开）
   - `subagent-settled` turn-trigger 行（图标、标题、时间、chevron、展开 body、说明文案）
   - 页头 breadcrumb / 子 Agent 目录按钮 / 手机菜单项
   - 子会话只读 composer 的提示条/按钮
   - 子会话侧栏（手机端 drawer/sheet）宽高、圆角、阴影、关闭
20. 官方中文文案原文（`ui-chat/locale.ts`、`ui-subagent/locales.ts`、`ui-tool/locale.ts`、`ui-conversation/locales.ts`）。

### E. 验收场景

至少 10 个：派一个子 Agent（运行中/完成/失败）、子 Agent 发消息给父会话（父会话 running / idle）、子 Agent 完成后父会话被唤醒、从父进子、从子回父、子会话只读/可继续、目录里多个子 Agent、等待子 Agent 超时、后台任务完成通知、定时任务唤醒、goal round 唤醒。

## 参考起点

- 官方：`packages/client/ui-subagent/src/client/*`、`packages/client/ui-chat/src/client/chat/TurnTriggerNodeView.*`、`turn-trigger.ts`、`conversation-nodes/inbox.ts`、`message.ts`、`contract/turn-process.ts`、`packages/client/ui-conversation/src/client/skeleton/ConversationSession.tsx`、`packages/subagent/src/`、`packages/experimental/agent-team/`、`packages/client/ui-mobile/src/client/push.ts`
- 官方测试：`packages/subagent/tests/`、`packages/client/ui-subagent/tests/`、`apps/web/tests/steering.e2e.ts`、`packages/test-support/session-snapshot/tests/fixtures/subagent-send-message-fence.ts`
- 官方 locale：`ui-chat/src/client/locale.ts`（`message.trigger.*`、`message.stepProcess.*`、`message.turnProcess.subagents.*`）、`ui-subagent/src/client/locales.ts`、`ui-conversation/src/client/locales.ts`（`tool.title.*`）
- iOS：`ChatModel.swift`（handle/loadSessionHistory/startPump）、`NativeTranscriptProjector.swift`、`DSHEventMapper.swift`、`AgentHarness.swift`（HarnessUserInput/InboxSpliced）、`NativeToolCallModel.swift`、`NativeToolDetailCards.swift`、`ChatPage.swift`（transcript/scroll/header）、`NativeShell.swift`、`SessionsPage.swift`、`DSHManagementModel.swift`
- 截图：`ios-chat-default.png`（iOS 页头/消息流）、`ios-chat-official.png`（官方手机宽度）

不要改源码。报告中文，证据 `file:line`。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
