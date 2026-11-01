# Axis 01 — 数据链路与事件目录

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只审 **session 会话线的事件/数据链路**，不做纯视觉细节（视觉由其他轴负责），但必须指出“UI 想画也拿不到数据”的所有卡点。

报告路径：`docs/receipts/ios-session-audit/01-data-path.md`

## 目标

建立官方 session 会话线的**完整事件目录**，逐项对照 iOS 的 5 段管线（wire → mapper → ChatModel → projector → SwiftUI），找出每一处丢弃、合成错误、字段缺失、历史/实时不一致、无法读取子会话的问题。最终回答：

> 要让 iOS 原生页能画出官方 session 消息流的全部条件控件，数据层还缺什么？按依赖排序。

## 必须覆盖

### A. 官方事件目录

1. 从官方 `packages/session`、`packages/api`、`packages/client/ui-conversation`、`packages/client/ui-chat` 找出 session journal / wire 的完整事件 union（含 live-only 事件）。不要只看一个文件。
2. 每个事件给：type、关键 data 字段、live/replay、官方消费者（Chat node kind / toolview / dock / trigger / projection）、是否影响会话页可见 UI。
3. 特别覆盖以下族（有就列，没有就说明没有）：
   - `turn/start`、`turn/end`、`step/start`、`step/end`
   - `assistant/message`、`assistant/live-chunk`（text/reasoning/tool-call delta）
   - `tool/call`、`tool/result`、`tool/ptc-dispatch-start`、`tool/ptc-dispatch`
   - `user/message`（所有 `source.kind`）、`agent/inbox/spliced`（next-step / next-turn）、`developer/message`
   - `user-question/*`、`permission/*`、`approval/*`（以官方实际 type 为准）
   - `todo/*`、`goal/*`、`subagent/*`、`schedule/*`、`command/*`、`compaction/*`、`llm/retry*`、`system-prompt/*`、`skill/*`
   - `workflow/*`、`jobs/*`、`deliverable/*`（若存在）
4. 说明官方 Chat 的 **inbox 状态机**如何把 `agent/inbox/spliced` + `user/message` 分类成 user / steering / context / turn-trigger；引用 `conversation-nodes/inbox.ts`、`message.ts`、`turn-trigger.ts`。
5. 说明官方 **Tool 树**（root + subCalls）的事件来源和合并规则；iOS 是否支持。
6. 说明官方 **history/replay** 如何从 journal 重建以上所有节点（不是只重建消息），paging/cursor 的键。

### B. iOS 管线逐段

对以下每一段，列出它认识/丢弃的事件与字段：

1. Worker/通道/Gateway：`plugins/channel/`、`plugins/worker-entry/`、`plugins/phone-shell/`、`plugins/surface-phone/`、`Sources/PhoneDSHGateway/`、`Sources/PhoneDSHController/`、`Sources/PhoneDSHLoopback/`。查清：
   - Worker 是否把完整 journal event 发到通道？还是只发少数类型？
   - 事件是否被过滤/截断/重写（例如 tool result 只留 summary）？
   - history/read 接口返回什么？是否含 seq/cursor/所有事件？是否含子会话？
2. `Sources/PhoneDSHAgentCore/DSH/DSHEventMapper.swift`：映射表、字段投影、`partsPerEvent`、`rawTurnEndKind` 等；列出未映射 type。
3. `HarnessEvent.Kind`（`AgentHarness.swift`）：类型系统本身缺哪些 case？现有 case 携带的字段是否足够画官方 UI（例如 `HarnessQuestion` 是否有 header/detail/option description/presentation/review/outcome/countdown/channel）。
4. `ChatModel.handle` / `startPump` / `loadSessionHistory` / `refreshTrajectory`：哪些事件被忽略、哪些只进 `status`、哪些没有 turn/step/callID、哪些 live 与 history 走不同投影导致重复/丢失。
5. `NativeTranscriptProjector`：逐 type 对照；字段（source、target、message id、tool meta、usage、compaction 等）是否保留。
6. 子会话：iOS 能否列出/读取/流式订阅一个 subagent child session？官方如何做（`sessions.retain(address)`、`SubagentAddress`、`parentSessionId`）？iOS 的 `DSHManagementModel`/`SessionsPage` 是否能拿到父子关系？
7. 断线重连/重放：seq 语义、去重、`after` cursor、重复渲染风险。
8. 性能/边界：大 tool result、历史分页、长会话。

### C. 输出

- 一张 **事件覆盖矩阵**：官方事件 → iOS Mapper → iOS ChatModel → iOS 历史投影 → 可见 UI，四列用 `✅ / ⚠️ / ❌` + 说明。
- 一张 **字段缺口表**：官方字段 → iOS 对应字段/丢失后果。
- 一张 **需要新增的 `HarnessEvent.Kind` / 数据模型**清单（按 UI 依赖排序），并给每个建议的 JSON 形状（从官方事件到 iOS 模型的映射）。
- P0/P1 数据卡点（例如“inboxSpliced 被丢，导致子 Agent 消息永远不可见”“通道不转发 todo 事件，UI 无法显示计划”）。
- 如果发现 iOS 实际能从 tool result / metadata / list_agents 等**间接**拿到某些数据，也要写清可行路径与限制。

## 参考起点

- 官方：`packages/session/src/`、`packages/api/src/`、`packages/client/ui-conversation/src/client/conversation/event-registry.ts`、`packages/client/ui-chat/src/client/conversation-nodes/`、`packages/subagent/src/`、`packages/plan/src/`、`packages/todo/src/`
- 官方测试：`packages/client/ui-chat/tests/`、`packages/api/remotes/tests/remote-events.host.spec.ts`、`packages/api/gateway/tests/gateway-stream.host.spec.ts`、`packages/test-support/session-snapshot/`
- iOS：上面 BRIEF 列的协议层文件 + `examples/probe-app/PhoneDSHSimTests/NativeChatPresentationTests.swift`
- 通道/worker：`plugins/channel/src/`、`plugins/worker-entry/src/`、`plugins/surface-phone/src/`、`Sources/PhoneDSHGateway/`

不要改源码；不要跑会改工作区的命令。报告中文，证据 `file:line`。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
