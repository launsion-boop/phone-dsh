# Axis 01 — 数据链路与事件目录：iOS Session 对齐审计

> 官方基线：`deepseek-harness` @ `7be5505b0b`（`0.2.1-rc.2`，与 `plugins/dsh-pin.json` 一致）
> iOS 基线：本仓库当前工作区（未修改任何源码）
> 手机宽度基准：402pt（官方 `ui-mobile` <640px 覆盖 + 402×874 截图）
> 本轴只看**事件/数据链路**；视觉像素合同由其他轴负责，但凡是“UI 想画也拿不到数据”的点都在本文列全。

---

## 0. 结论摘要

1. **官方的事件面远比 iOS 认识的大**：官方 `KNOWN_SESSION_EVENT_TYPES` 共 **66** 个 durable 事件类型（`packages/core/session/src/known-event-types.ts:22-84`），加上 1 个 live-only 类型 `assistant/live-chunk`（`packages/api/session-controller/src/client/contract/events.ts:8-19`）。iOS 实时映射器只认 **8** 个（`Sources/PhoneDSHAgentCore/DSH/DSHEventMapper.swift:61-110`）；历史投影器的 `switch` 只有 9 个 case，其中 `agent/steering/message` 在官方**不存在**（全仓 0 命中），真正命中的官方 type 共 **11** 个（含 `compaction/*` 前缀匹配的 4 个，`NativeTranscriptProjector.swift:19-146`）。覆盖面约 **12% / 17%**。
2. **最致命的一刀不是“少映射了几个”，而是官方把会话状态放在 projection 里，而 iOS 既不订阅 projection 推送、又把 follow 首帧里的 projection 基线整块扔掉**。官方 `session/follow` 的 snapshot 携带 `{header, cursor, records, hasMore, projections, assistantStream}`（`packages/api/session-controller/src/history.ts:190-213`），iOS 只读 `cursor` 就 `close()`（`ChatModel.swift:1500-1538`）。todo / plan / subagent 目录 / userQuestions / title / modelSelection 全在这块里。
3. **三条 P0 级“永远看不到”**：`agent/inbox/spliced` 在 `ChatModel.handle` 里直接 `break`（`ChatModel.swift:1719-1722`），导致 steering / 非人类输入（goal 轮次、schedule 提醒、子 Agent relay、subagent-settled）在**实时**流里永远不出现，刷新历史后才“凭空多出来”；子 Agent 只有“活动页”的一个只读列表，**没有子会话地址、不能 follow 子会话**；问答只有“待回答卡”，**没有已回答形态**。
4. **两个已确认的字段路径 bug，让两个官方控件在 iOS 上恒为 nil**：goal 读 `values.goal.current.goal`（官方是 `values.goal.goal`，`packages/goal/goal/src/index.ts:167`），title 读 `values.title.title`（官方是 `values.title` 字符串，`packages/session/session-title/src/types.ts:86-92`）。GoalBar 视图存在但永不显示（`ChatPage.swift:1046-1077`、`1136`）。
5. **iOS 会画出官方故意隐藏的东西**：官方 `isVisibleChatNode` 明确把普通 `context` 行、`system-prompt` 行排除在消息流之外（`chat-snapshot-builder.ts:525`、`chat-visibility.ts:10-19`）；iOS 则把每一段注入上下文折成一行「上下文 · N 条」。这是“画错”而不是“少画”。
6. 统计：**P0 × 6、P1 × 12、P2 × 6**（共 24 条，完整清单见 §4）。

---

## 1. 审计范围与方法

### 1.1 读过的官方代码（shipped web-app composition 为准）

组合以 `packages/bundle/web-app/cordis.patch.yml` 为唯一依据：
- UI 插件：`ui-conversation`(L326)、`ui-approval`(L330)、`ui-chat`(L333)、`ui-tool`(L344)、`ui-deliverables`(L353)、`ui-workflow-run`(L367)、`ui-subagent`(L381)、`ui-jobs`(L394)、`ui-schedule`(L399)、`ui-goal`(L403)、`ui-message-feedback`(L409)、`ui-model-selection`(L413)、`ui-plan`(L452)、`ui-user-questions`(L455)、`ui-trajectory`(L458)、`ui-mobile`(L596)。
- Host 服务：`api-session-controller`(L122)、`schedule`(L140)、`workspace-changes`(L358)。
- **`packages/experimental/*`（agent-team、hook-protocol、webhook 等）不作为默认随附**，仅在事件目录里标注为 experimental。

事件/协议侧读的文件：
- `packages/core/session/src/known-event-types.ts`（66 类型全表）
- `packages/core/session/src/types.ts:282-429`（core `SessionEventMap`）、`:463-479`（`SurfaceOp`）、`:192-230`（`TurnEndReason`）
- `packages/core/agent/src/types.ts:43-66,96-104`（`InboxState` / `agent/inbox/spliced`）
- `packages/llm/llm/src/message.ts:41-115,162-180`（`MessageSource` / `UserMessage`）、`:470-482`（`StreamChunk`）
- `packages/api/session-controller/src/history.ts`、`control.ts`、`list.ts`、`index.ts:594-613`、`types.ts:413-520,560-613`
- `packages/api/remotes/src/remote-events.ts:26-55`（唯一一份 `$events` 转发白名单）
- `packages/client/ui-chat/src/client/conversation-nodes/*`（约 20 个 node 定义 + 注册表）
- `packages/client/ui-conversation/src/client/{conversation/event-registry.ts,queue/QueueDock.tsx,skeleton/TodoPanel.tsx}`
- `packages/client/ui-subagent`、`ui-user-questions`、`ui-plan`、`ui-goal`、`ui-approval`、`ui-jobs`、`ui-schedule`、`ui-deliverables`、`ui-tool`
- 各域 projection 声明：`goal`、`todos`、`plan`、`inbox`、`userQuestions`、`subagentCatalog/subagentTiming/subagent`、`permissions`、`title`、`tokenUsage/contextPressure/contextBreakdown`、`sessionStats`、`turnOutline`、`sessionListMetadata`

### 1.2 读过的 iOS 代码

- 五段管线：`plugins/worker-entry/src/{mux-bridge.ts,entry.ts}` → `Sources/PhoneDSHAgentCore/DSH/{DSHRemoteTransport,DSHRemoteHarness,DSHEventMapper,DSHMessageSourceClassifier}.swift` → `Sources/PhoneDSHAgentCore/AgentHarness.swift` → `ChatModel.swift` → `NativeTranscriptProjector.swift` → `ChatPage.swift` / `NativeChatTimelineChrome.swift` / `DSHManagementModel.swift`
- 通道：`Sources/PhoneDSH/ChannelDSHTransport.swift`、`PhoneDSHHost.swift:2457-2480`
- 测试：`examples/probe-app/PhoneDSHSimTests/NativeChatPresentationTests.swift`（115 行，4 个用例，全是历史投影器）

### 1.3 用过的穷举搜索（用于“没有”的证明）

```bash
# 官方：事件类型是否真的不存在
grep -rn "agent/steering" --include=*.ts --include=*.tsx <official>   # 0 命中
grep -n "'user-question" <official>/packages/core/session/src/known-event-types.ts  # 0 命中（没有 user-question/* 事件）
grep -rn "@mode waterfall" <official>/packages | grep -v tests        # 只转发 2 个：approval/request、user-questions/request

# iOS：是否处理过某些事件/字段
grep -rn "surfaceOp\|sourceEventSeqs\|ignorable" --include=*.swift <ios>        # 0 命中
grep -rn "todo/write\|todos" --include=*.swift <ios>                            # 只命中 Activity 页（DSHManagementModel:562）
grep -rn "plan/mode\|planActive" --include=*.swift <ios>                        # 只命中 Activity 页（:560）
grep -rn "question-reply\|user-question-reply\|settled" --include=*.swift <ios> # 只命中无关的 PhoneDSHAbortEscalation/PhoneDSHHost
grep -rn "inbox\|next-turn\|next-step" --include=*.swift <ios>                  # 只有 .inboxSpliced 的 break
```

### 1.4 截图对照

`docs/receipts/ios-baseline-screens/ios-chat-official.png`（402×874pt；**审计后校正：按 `INDEX.md:77`，这是 iOS `-uiPreview chat.official` 的自绘页，不是官方 Web**。此处仅作 iOS composer/stats 的观察）：composer 下方统计行是 `5 轮 17 步 · 54 tok/s 🗄 1.0M tok · 缓存命中 75% ◔ 10%`，即 `sessionStats` + `tokenUsage` + `contextPressure` 三个 projection 驱动；**截图观察**，非源码事实。iOS 对应实现见 `NativeComposerStats.swift` 与 `ChatModel.refreshNativeMetrics`（`ChatModel.swift:1881-1897`）。

---

## 2. 官方基线（按 surface 列）

### 2.1 官方 session 会话线的数据形状（五条事实）

| # | 事实 | 证据 |
|---|---|---|
| F1 | journal 是**完整**事件日志，seq 密集从 0；`session/page` 返回的是**连续事件窗口**（不只是消息），按消息边界切页，`hasMore` 表示更早还有 | `history.ts:77-119`、`paginate` `history.ts:392-418` |
| F2 | `session/follow` 首帧 = `{header, cursor, records, hasMore, projections, assistantStream?}`，之后是 gapless durable 事件（**seq 断裂直接抛错**） | `history.ts:120-260`、`SessionFollowFrame` `types.ts:565-578` |
| F3 | 每个事件先过 **event registry**，按 `event.type` 路由到 node definition（15 个 definition、约 20 条路由），输出的是**带 anchor/visibility/groupTree 的 node store**，不是扁平数组 | `event-registry.ts:73-90`、`register-node-renderers.ts:41-89`、`chat-snapshot-builder.ts:520-540` |
| F4 | 消息分类**不靠事件 type**，靠 `agent/inbox/spliced` 折叠出的 claim 状态：本 step 认领 → `steering`；next-turn 认领 → `turn-trigger`(waking)；其余非 user source → `context` | `conversation-nodes/inbox.ts:79-134`、`message.ts:56-120` |
| F5 | 会话级状态走 **projection**：follow 首帧基线 + Host 全局 `session/control` 流（baseline + 每 key 一帧） | `history.ts:295-302`、`control.ts:26-60`、`projection-store.ts:1-30` |

### 2.2 官方事件 → 可见 UI 目录（按族）

> “可见 UI”列只写**会话页**上会出现的；对话框/composer 记作 “composer”；只进 projection 不直接出行的记作 “投影”。

| 族 | 事件 | 关键字段 | live/replay | 官方消费者（file:line） | 影响会话页可见 UI |
|---|---|---|---|---|---|
| 轮次骨架 | `turn/start` `{turn}` | turn | both | `turn-process`/`turn-tail`/`turn-error`/`turn-max-tokens`/`deliverables` 的 start anchor（`turn-process.ts:313`、`turn-tail.ts:151`、`turn-error.ts:83`、`deliverables/…/turn-deliverables.ts:180`） | ✅ turn 分组、TurnNavigator、turn-tail 卡 |
| | `turn/end` `{turn, reason}` | `reason.kind` ∈ completed/aborted(其 `reason.kind`)/blocked/error(`LlmFailure`)/max-tokens/interrupted/forked | both | `turn-error`(`:84`)、`turn-max-tokens`(`:42-51`)、`turn-tail`(`:152`) | ✅ 错误行、上限行、tail |
| | `step/start` / `step/end` | turn, step | both | `assistant-step`(`assistant.ts:367`)、`turn-process`(`:319-320`)、`turn-tail`(`:158-159`) | ✅ step 折叠、过程区 |
| 助手 | `assistant/message` `{turn, step, message, stream, usage?, interrupted?}` | 全部 content blocks + usage + interrupted | both | `assistant.ts:238,315`、`turn-process`、`turn-tail` | ✅ 正文/思考/图片/tool-call 块 |
| | `assistant/attempt` `{turn, step, stream}` | 失败/重试/取消的尝试流 | both | `turn-tail.ts:156`（retry 链） | ✅ 重试链行 |
| | **`assistant/live-chunk`**（live-only） | `chunk: StreamChunk`（block-start/text-delta/reasoning-delta/**tool-call-delta**/block-end/usage/finish） | live | `tool.ts:296-302`（tool-call-delta 开准备态）、`assistant.ts:298` | ✅ 流式文本/思考、**preparing 工具行** |
| 工具 | `tool/call` `{turn, step, callId, name, arguments(原始 JSON 串)}` | 名字+原始参数 | both | `tool.ts:304,318` | ✅ 工具行 |
| | `tool/result` `{…, message, error?:{name,code,reason}, meta?}` | `meta` = 工具私有展示数据（diff/path/exitCode…） | both（replace 型用于压缩） | `tool.ts:305-306,323`、`rootResult` `tool.ts:100-120` | ✅ 工具结果/差异卡 |
| | `tool/ptc-dispatch-start` / `tool/ptc-dispatch` `{rootCallId,…}` | root + 子调用 | both | `tool.ts:200-230,308-312` | ✅ 嵌套 subcall 树 |
| 输入 | `user/message`（`MessageSourceMap` 多 kind） | `content`, `source.kind` / `form` / `summary` / `references` / `name` / `callId` | both（replace 型 = 压缩检查点） | `message.ts:62-120`（用户/steering/context）、`question-reply.ts:136-190`（`user-question-reply` → `question-reply` 行）、`request-prompt` 忽略 `compact-checkpoint` | ✅ 用户气泡 / steering / 隐藏 context / 问答回执 |
| | `agent/inbox/spliced` `{target, start, removedCount?, inserted: UserMessage[], outcome?}` | 两条 pending 列表的规范化变更 | both | `inbox.ts:79-134`（仅状态机，`publication: 'none'`）、`QueueDock` 读 `inbox` 投影 | ✅ 分类依据 + queue dock |
| | `developer/message` | turn, step, message | both | `message.ts:137-149` | ✅ 工具增删通知（context 形态） |
| | `system/message` / `request/header` | 系统提示 / 请求头快照 | both | `request-prompt.ts:66-160` → `system-prompt` node | ⛔ 被 `isVisibleChatNode` 隐藏（见 F4/`chat-visibility.ts:10-19`） |
| 问答 | *没有 `user-question/*` 事件*（穷举 `known-event-types.ts` 无此项） | 待答：`user-questions/request` **waterfall**；答案：`tool/result` 文本 JSON 或 `user/message`(`source.kind='user-question-reply'`)；状态：`userQuestions` projection | waterfall + both | `ui-user-questions/src/client/index.ts:222-320,396`、`question-reply.ts:153-190`、`ui-tool/.../ask-question-row.tsx:90-200` | ✅ 待答面板（composer takeover）+ `question-reply` 行 + 工具卡已回答形态 |
| 审批 | `approval/asked` `{id, toolName, callId?, reason?}` / `approval/decided` `{id, outcome}` / `approval/policy` | 审计对 | both（log-only） | `ui-approval/ApprovalPanel.tsx`（composer takeover，`conversation.approval.detail` 槽）、`chat/ApprovalCommand.tsx` | ⚠️ 不作为 transcript 行；composer takeover + 审计可查（`ChatView.tsx:232-233` 明确注释：问答与审批都接管 composer，不做流程卡） |
| 计划 | `plan/mode` `{active}` | 布尔 | both | `ui-plan/PlanModeControl.tsx:20`（`useProjection('plan')`）、`conversation.chat.turnTail` 计划卡（`ui-plan/src/client/index.ts:80-95`） | ✅ composer 计划位 + turn 尾计划卡 |
| | `todo/write` `{todos: [{content, status}]}` | 整表替换 | both | `ui-conversation/skeleton/TodoPanel.tsx:106-107`（`useProjection('todos')`）+ `tool.call.toolview key:'todo_write'` | ✅ 输入 dock 的 todo 面板 + todo 工具卡 |
| 目标 | `goal/change`（`{kind:'goal/change', operation, goal, roundsStarted, …}` 或 clear 墓碑） | 整值快照 | both | `goal` projection（`goal/index.ts:163-169`，wire = `state.current`）→ `GoalBar.tsx:187-192`；`goal/activation-changed` 走 `$events` | ✅ composer 上方 GoalBar |
| 子 Agent | `subagent/catalog` `{version, childId, childCreatedAt, mode, label?}`（父会话） / `subagent/descriptor`（子会话自身） / `subagent/model-selection-policy` | 目录/身份/标签/模式 | both | `subagentCatalog`/`subagent` projection（`projection-types.ts:70-90`）、`manager.ts:160-175`（`subagentAddress`）、`SubagentHeaderLineage.tsx:464,492,793` | ✅ 页头 lineage、子会话入口、只读 composer |
| 后台任务 | `job/registered` / `job/settled` | job 记录 | both | `ui-jobs` 会话头 roster + `job/list` 流（`job/*` Remote） | ✅ 会话头按钮 + 记录面板 |
| 定时 | `schedule/change` | 提醒变更 | both | `ui-schedule` + `schedule/catalog`、turnTail `schedule-created`（`ui-schedule/src/client/index.ts:190`） | ✅ turn 尾「已创建任务」卡 + 会话头 |
| 工作流 | `tool-workflow/{run-start,run-end,agent-start,agent-end}` | runId/name/seq/label/childId/phase | both | `ui-workflow-run/workflow-definition.ts:158-170` → `workflow-run` node | ✅ 工作流面板卡 |
| 命令 | `command/run` / `command/done` | name/args/source；done 带结果 | both | `command.ts:178-200` → `command` node；`command-input`(ui-goal) | ✅ 斜杠命令行 |
| 压缩 | `compaction/{start,summary,end,prune}` | summary:ContentBlock[]、shadowedRange/Seqs | both | `compaction.ts:39-60` → `compaction` node；`command.ts` 关联手动压缩 | ✅ 压缩行（手动 = manual-compaction） |
| 重试 | `llm/retry` / `llm/retry-started` | provider/retry/maxRetries/delayMs/failure | both | `retry.ts:24-70` → `model-retry` node；`tokenUsage` 用它关账 | ✅ 重试行 |
| 交付物 | `deliverables/presented` `{turn, callId, files}` + `workspace/changes {turn}` | 文件清单 / git 摘要句柄 | both | `turn-deliverables.ts:172-215`、`ui-deliverables/src/client/index.ts:59-82` | ✅ turn 尾交付卡 + 改动文件卡 |
| 上下文记号 | `image/offload`、`request/context`、`model/selection`、`permission/preset`、`sandbox/mode`、`agent-preset/selected`、`working-directory/change`、`session/title`、`webhook`*、`hook/*`*、`team/*`* | — | both | 各自 projection / 列表 / 设置 | 投影为主（* = experimental，不随附） |

### 2.3 官方 history / replay 契约

| 项 | 官方行为 | 证据 |
|---|---|---|
| 分页键 | `throughSeq`（含）+ `beforeSeq`（不含）+ `maxMessages`（默认 50）+ `turnWindow{minMessages,minTurns}`；切点对齐 turn 起点，保证**不把一轮从中间切开** | `history.ts:392-418`、`types.ts:501-517` |
| 冷读 | `session/page` 不激活 Agent；`sourceFor` 用 `sessionQuery.observeSession`，只在 follow 时带 projection | `history.ts:239-300` |
| 子会话寻址 | `SessionAddress` = `{kind:'session', sessionId}` 或 `{kind:'subagent', parentSessionId, childSessionId, mode}`；服务端校验 `header.origin==='subagent'`、父 id 一致、`subagent` 身份 projection 的 seq ≥ 继承长度、mode 一致 | `types.ts:423-432`、`history.ts:341-392` |
| 重放 | 打开即重放整个窗口；`assistantStream` 基线提供**流式中**文本的累积量与 revision | `types.ts:513-530`、`history.ts:196-213` |
| 去重/连续性 | 客户端按 `revision`+`change`（replace/prepend/append/settle-assistant）合并窗口；服务端遇 seq 断裂直接 `gateway/internal: session event stream skipped seq` | `contract/events.ts:90-131`、`history.ts:217-231` |
| 折叠 | 历史页**只 prepend 原始事件**，所有 node（含 group tree、turn 导航、turn-process 折叠）由同一条事件管线重算，因此分页不影响分组 | `session.ts:640-750`、`chat-snapshot-builder.ts:520-600` |

---

## 3. iOS 现状（五段管线逐段）

### 3.1 段 1：Worker / 通道 / Gateway

| 检查点 | 结论 | 证据 |
|---|---|---|
| Worker 是否转发完整 journal？ | **是**。`serveApiRequests` 把 `/api/*` 原样交给被捕获的 DSH webserver listener，只有 `/api/remote.mux` 走 mux bridge | `plugins/worker-entry/src/entry.ts:1083-1140`、`mux-bridge.ts:1-35` |
| 是否过滤/截断事件？ | **否**。通道是保序字节通道，iOS 侧 `ChannelDSHTransport` 把 unary 变 `API_REQ`、流式变 `API_RES`/`API_END` | `Sources/PhoneDSH/ChannelDSHTransport.swift:1-35,122-158` |
| mux 承载能力 | `send`/`receive`/`close` 三个 unary；`receive` 是 NDJSON 长请求，因此 **`session/control`、`session/follow`、`$events` 都能开** | `ChannelDSHTransport.swift:43-69`、`mux-bridge.ts:35-70` |
| history 接口返回什么 | 与官方同一 Remote：`session/page` 全事件、`session/list` 带 `parentSessionId`/`origin`/`projections` 提示 | `history.ts`、`list.ts:353-363` |

> **结论：数据在 HTTP/通道层是完整的。所有缺口都在 iOS 客户端怎么用。**

### 3.2 段 2：`DSHEventMapper`

只处理 8 个 type（`DSHEventMapper.swift:61-110`）：

| type | 产出 | 丢失的字段 |
|---|---|---|
| `user/message` | `.userMessage(text, source=source.kind)` | `content` 里 image/file 块、`source.form/summary/references/name/callId`、`surfaceOp`、`message.id` |
| `agent/inbox/spliced` | `.inboxSpliced(messages:[text,source])` | `target`、`start`、`removedCount`、`outcome`、每条 message 的 id/content |
| `turn/start` | `.turnStarted(turnID)` | 无（turn 号够用） |
| `turn/end` | `.turnEnded(reason)` + `rawTurnEndKind`/`rawTurnEndCause` | `aborted.reason`、`error.code/status`、`interrupted` 与 `aborted` 的区分（都折成 `.cancelled`，`:145-152`） |
| `step/start` | `.progress(phase:"step", step:)` | `turn`、step 结束 |
| `assistant/message` | `.assistantMessage(texts only)` + `.usage(input,output)` | **reasoning/image blocks 全丢**（`texts()` 只取 `type=="text"`，`:156-160`）、`message.id`、`interrupted`、cache 桶 |
| `tool/call` | `.toolCall(callID,name,arguments)` | 无（arguments 解析失败退化为字符串，`:91`） |
| `tool/result` | `.toolResult(isError, summary≤280)` + `toolResultDetail` | **`meta`**、`error.name/code`、`message.source.name`、完整文本（UI 侧 280 字符封顶，`:162-165`） |

`partsPerEvent = 8`（`:25`），harness seq = `dshSeq*8 + part`，回推见 `position(of:)`（`:32-34`）。

### 3.3 段 3：`HarnessEvent.Kind` 类型系统

`AgentHarness.swift:390-412` 共 14 个 case：`assistantDelta, reasoningDelta, assistantMessage, toolCall, toolResult, permissionRequested, questionRequested, userMessage, inboxSpliced, turnStarted, turnEnded, progress, sessionStatus, usage, exited`。

类型系统本身缺（对比 §2.2 的可见 UI 需求）：

| 缺口 | 说明 |
|---|---|
| 无 todo/plan/goal/subagent/schedule/job/workflow/deliverable/compaction/command/systemPrompt 事件 case | 只能靠 remote 轮询，或干脆没有 |
| 无 `contextMessage`（带 form/summary/references/skillName） | 上下文只能塞进 `text` + `source` 字符串 |
| 无 `turnTrigger`（waking） | 「收到新消息」不可表达 |
| 无 `questionSettled` / 无 `questionPending(callId,state,timed,remainingMs)` | 已回答/计时的两种官方形态不可表达 |
| 无 `approvalAsked/decided` | 审批审计不可表达 |
| 无 `stepEnded` / `attempt` / `retrySettled` | turn-process 折叠与重试链不可表达 |
| 无 `ptcDispatch` | 嵌套工具树不可表达 |
| `HarnessQuestion` 字段太少（`AgentHarness.swift:298-327`）：只有 `id/prompt/options[String]/multiple` | 缺 `detail`、`header`、`options[].description`、`intent{kind:'plan-review',approve,callId}`、`wait{callId,timed}`、`state(open/continued)` |
| `HarnessGoal`（`:456-477`）缺 `id/revision/createdAt/updatedAt/activation(armed/disarmed)` | GoalBar 的「已暂停/恢复」与 CAS 动作需要 |
| `ToolRisk` 只有 readOnly/sideEffect/ui，审批 summary 是客户端拼的 `"Allow \(tool)?"` | 官方有 `reason`/`displayReason` 本地化 |

### 3.4 段 4：`ChatModel`

| 方法 | 行为 | 丢弃/错误 |
|---|---|---|
| `startPump` `:1644-1665` | 用 harness seq 做游标；断线 300ms 重试 | 不校验 seq 断裂（官方抛错）；不处理 `snapshot.assistantStream` |
| `handle` `:1667-1829` | 逐 Kind 处理 | **`.userMessage`/`.inboxSpliced` → `break`（`:1719-1722`）**；无 todo/plan/context |
| `.questionRequested` `:1760-1762` | 只置 `pendingQuestion` + 追加英文 Host 状态行 `"The agent asks: …"` | 无 header/detail/description/intent；无 answered 形态；单值（并发问题互相覆盖） |
| `.permissionRequested` `:1756-1759` | 置 `pendingPermission`（从不落进 transcript） | 无 `approval/asked` 记录 |
| `.usage` `:1814-1823` | `inputTokens += input; outputTokens += output`，给“最后一条 assistant”挂 usage | cache read/write/reasoning 全丢；与 `tokenUsage` projection 双源 |
| `.progress(step)` `:1804-1807` | 设 `activeStep`，`modelRequests += 1` | 无 `step/end` |
| `.turnEnded` `:1770-1803` | 收尾 + 失败/取消时把 running 工具标 stopped | 不读 `rawTurnEndCause`；`.failed("blocked")` 变普通失败 |
| `loadSessionHistory` `:1416-1464` | ① 开 `session/follow` 只为拿 `snapshot.cursor` 然后 `close()`；② `session/page throughSeq=cursor&maxMessages=60`；③ `session/list` 取 running | **projections / header / assistantStream 全丢**；无 `turnWindow` |
| `loadEarlierTranscript` `:1468-1498` | 用 `beforeSeq` 翻页、按 id 去重后 prepend | 投影器无跨页状态（turn/工具配对按页重算） |
| `refreshTrajectory` `:459-499` | 每个 durable 事件（500ms 防抖）重读最后 60 条，全 type 分类 | 只服务 Debug/Trajectory 面板；长会话 O(n) 重复读 |
| `refreshGoal` `:1857-1870` | `harness.goal()` | **路径 bug → 恒 nil**（见 DP-07） |
| `refreshNativeMetrics` `:1881-1897` | 读 `session/projections` 的 `sessionStats/tokenUsage/contextPressure/contextBreakdown` | 只这 4+1（permissions）个 key，且是**事件后轮询**，不是订阅 |
| `send` / `steer` `:1268-1325` | `mode:"queue"` / `mode:"steer"`，本地乐观插行 | 无 `session/queue`/`updateQueue`；`"已排队"`/`"已并入当前任务"` 是纯本地标签（`:2107-2123`） |

### 3.5 段 5：`NativeTranscriptProjector` + SwiftUI

| type | iOS 产出 | 与官方差异 |
|---|---|---|
| `user/message` / `agent/steering/message` | `.user` / `.context`，title 为 `"You"` 或 `"DSH context · <kind>"` | `agent/steering/message` **官方不存在**（0 命中）；无 form/summary；无 steering 判定 |
| `assistant/message` | 逐 block：`text→.assistant`、`reasoning→.reasoning`、`image→.image`、`tool-call→continue` | ✅ 结构接近；但不读 `interrupted`、不建 step 分组 |
| `tool/call` / `tool/result` | 按 callID 配对，`meta → toolMetadata`，`error.code=="interrupted"` 标 stopped | ✅ 历史侧保留 meta（实时侧丢，见 DP-09） |
| `turn/end` | 只处理 `max-tokens` 和 `error` 两种 | `blocked`/`aborted`/`interrupted`/`forked` 不出行 |
| `llm/retry(-started)` | `.systemEvent("模型请求重试")` | 无 attempt/次数/延迟 |
| `compaction/*` | `.systemEvent("上下文已整理")`，summary 取 `data["summary"].stringValue`（实际是 ContentBlock[] → 恒失败） | 无 shadowedRange 折叠 |
| 默认 | `default: continue`（`:144-146`） | 其余全部丢弃 |

- 行合成：`ChatPage.timelineRows`（`:453-475`）把**连续 context** 折成 `.contexts`、**连续工具**折成 `.tools`；官方是 `turn-process`（按 turn+step）+ 逐条工具行。
- 可见性：iOS 显示 context 组；官方隐藏普通 context（`chat-visibility.ts:10-19`）。
- turn 尾：`ChatPage.swift:2301-2308` 用 `NativeTranscriptProjector.changes(forTurn:)`（从 write/edit 参数推导）与 `usage(forTurn:)`（加总 message usage），不是官方的 `deliverables/presented`+`workspace/changes`+`tokenUsage`/`sessionStats`。

---

## 4. 差距清单（核心交付）

> 严重度按 BRIEF §5.3。本轴 P0 = **数据层 blockage：即便 UI 写对了也画不出来**；P1 = 数据到了但形状/字段错，用户能一眼看出；P2 = 细节/边界。

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
|---|---|---|---|---|---|---|---|---|---|
| **DP-01** | P0 | 没有 inbox 状态机：`agent/inbox/spliced` 实时被丢弃、`inbox` projection 从不读 | `conversation-nodes/inbox.ts:79-134`（applySplice）；`message.ts:62-120`（steering/waking 判定）；`QueueDock.tsx:105-109`（`useProjection('inbox')`）；事件形状 `core/agent/src/types.ts:96-104` | `DSHEventMapper.swift:67-73` 只留 text+source；`ChatModel.swift:1719-1722` 直接 `break`；`.inboxSpliced` 在历史投影器无对应分支（`NativeTranscriptProjector.swift:19-146`） | ① steering 消息和普通用户消息长得一样（官方是 `steering` 行，形态不同）；② 非人类输入不计入 `turn-trigger`；③ 队列 dock 完全缺失；④ 重开后同一句话的归类会变（实时=无，历史=普通 user 气泡） | 行为合同：维护 `next-turn`/`next-step` 两条 claim 序列，`claimedHuman`；`user/message.source.kind==='user'` 且在本 step claim 内 → `steering`；非 user 且在 next-turn claim 内（或 idle-steer 条件）→ `turn-trigger`；否则 → `context`。402pt 下 steering 与 user 必须能区分（官方 UserMessageNodeView 按 `kind` 分支） | `session/follow` 的 `agent/inbox/spliced`（durable，replay 也有）+ `inbox` projection | 新增 `HarnessEvent.Kind.inboxSpliced(target:start:removedCount:inserted:[{id,text,source}])`；`ChatItem.Kind` 增 `steering`/`turnTrigger`；在 projector 里实现同构 fold（`applySplice` 的 Swift 移植） | 用官方 `inbox.spec.ts`/`contract-regressions.spec.ts` 的事件序列做 fixture，断言三分类；`git grep` 保证没有 `agent/steering/message` 残留 |
| **DP-02** | P0 | 会话级 projection 既不实时订阅，follow 首帧基线也整块丢弃；只用 5 个 key 事后轮询 | `history.ts:190-213`（snapshot.projections）；`control.ts:26-60`（Host 全局 `session/control`：baseline + 每 key 帧）；`projection-store.ts:1-30`（seq 高者胜）；`client/transport.ts:120-124` | `ChatModel.swift:1500-1538` 只读 `cursor` 后 `mux.close()`；`ChatModel.swift:1885-1893` 只读 `sessionStats/tokenUsage/contextPressure/contextBreakdown`；`:310-321` 只读 `permissions`；`goal` 走 `harness.goal()`（DP-07） | todo 面板、plan 位、子 Agent 目录/时长、userQuestions、标题、模型选择、agent preset、workingDirectory 全部只能靠“进 Activity 页手动刷”或干脆没有 | 行为合同：`projections` 必须按 key 订阅、按 `asOfSeq` 单调合并；40pt 的 dock 高度由 projection 有无决定（key 缺失=控件不渲染，不是空控件） | `session/follow.snapshot.projections`（`{asOfSeq, values}`）+ `session/control`（`{type:'baseline' 或 'projection', sessionId, key, value, seq}`） | 新增 `HarnessProjectionStore`（actor，key→(value,seq)，高 seq 胜）；`DSHRemoteHarness` 开 `session/control` 流；`ChatModel` 消费 key 变化 | 用官方 `session-projections.host.spec.ts:550,565,701` 的 values 形状做解码测试（含 `values.title` 是字符串） |
| **DP-03** | P0 | 实时 `user/message` 被整体丢弃 | `message.ts:62-120`（所有 source.kind 都要出行/分类） | `ChatModel.swift:1719-1722`：`.userMessage, .inboxSpliced: break`；本地只在 composer 侧乐观插一行（`:1289-1300`） | **“收到新消息”永远不出现**：goal 继续轮（`source.kind='goal'`）、schedule 提醒（`'schedule'`）、子 Agent relay（`'agent-message'`）、`'subagent-settled'` notice、`'user-question-reply'`、webhook —— 实时不可见，杀进程重开才“凭空”出现；且此前的 `context` 行位置/分组会重排 | 行为合同：每一个 `user/message` 必须实时产出一行（user/steering/context/turn-trigger 之一），与历史投影**同一套分类函数**；id 用 `message.id` 而不是 seq | durable `user/message`（live + replay） | `handle` 里改为走同一个分类器（把 projector 的分类逻辑抽成 `NativeMessageClassifier` 供实时/历史共用） | 用 `test-support/session-snapshot` 造的 goal/schedule/agent-message 事件各一条，断言实时与重放产出完全一致（行数、kind、位置） |
| **DP-04** | P0 | 问答只有“待回答”一半，且字段大面积缺失 | `user-questions/src/types.ts:8-140`（`detail/header/options[].description/intent/wait{callId,timed}/state`）；`userQuestions` projection（`projection.ts:317-331`）；`question-reply.ts:136-190`（`source.kind='user-question-reply'` → `question-reply` 行）；`ask-question-row.tsx:90-200`（answered/unanswered 两种卡） | `HarnessQuestion`（`AgentHarness.swift:309-327`）只有 prompt/options/multiple；`DSHRemoteHarness.swift:410-422` 只取 `question`/`options[].label`/`multiSelect`；`ChatModel.swift:1760-1762` 置单值 + 英文状态行；`ChatPage.swift:2139-2244` 只有待答卡；`respondToQuestion`（`:1393-1403`）答完即丢 | ① 答完后**没有任何回执行**（官方有 `question-reply` 行：问 + 你选的）；② `intent.kind='plan-review'` 的“批准/拒绝方案”被降级成普通选项；③ 多个并发问题互相覆盖；④ 超时/`continued` 重答没有入口；⑤ `detail`/`header`/选项副标题全丢 | 行为合同：待答面板读 `wait.callId` 做 key；`timed` 显示倒计时（官方 `attachWait` 每秒 `{remainingMs}`）；答案提交后本地插一条 `question-reply` 行（key = callId），并在 `userQuestions.settled` 到达后以 projection 为准；plan-review 的 approve 用 `intent.approve` 的标签而不是位置 | `$events` 的 `user-questions/request`（含 `wait`）、`userQuestions` projection、`user/message`(`user-question-reply`)、`userQuestions.answer(sessionId,callId,…)` Remote | 扩 `HarnessQuestion`（含 `HarnessQuestionItem.detail/header/optionDescriptions/intent/wait`），加 `questionSettled` Kind；`ChatItem.Kind` 加 `questionReply` | 官方 `question-composer.e2e.ts` 场景；断言 `answered`/`skipped` 文案与选项回显（`ask-question-row.tsx` 的 `pairAnswers`） |
| **DP-05** | P0 | 子 Agent 只有“列表”，没有子会话数据通路 | `SessionAddress` 子会话寻址（`types.ts:423-432`）；`validateAddress`（`history.ts:341-392`）；`subagentCatalog/subagentTiming/subagent` projection（`projection-types.ts:70-90`）；`manager.ts:160-175`（`subagentAddress`）；`SubagentHeaderLineage.tsx:464,492,793` | `subagentCatalog` 仅在 Activity 页被读（`DSHManagementModel.swift:575-580`），**从不构造 `kind:'subagent'` 地址、从不开子会话 follow**（全仓 `grep "kind\".*subagent"` 无命中）；`DSHEventMapper` 无 `subagent/*` | 用户点不到子 Agent 的会话：看不到子 Agent 的消息流、运行时长、状态；子 Agent 的 `subagent-settled` 回流也只以一条沉默的 context 出现（DP-03） | 行为合同：父会话的 `subagentCatalog` → `PanelRow`（label + mode + 状态点）；点击进入子会话时必须以 `{kind:'subagent', parentSessionId, childSessionId, mode}` 打开 follow/page，不能当普通 session（服务端会 `session/agent-busy` 拒绝，`history.ts:347-353`）；页头 lineage 显示父链 | `subagentCatalog`（父）+ `subagent`（子身份）+ `subagentTiming` + `subagent/descriptor` | 新增 `HarnessSubagentAddress`；`DSHRemoteHarness` 增加 `follow(address:)`/`page(address:)`；`ChatModel` 增加 `childSession` 模式 | 用官方 `history.ts:341-392` 的四类报错做负例（`subagent/unauthorized`、`catalog-diagnostic`），正例走 `test-support/session-snapshot` 的双会话 |
| **DP-06** | P0 | 审批只活在一次连接里，没有 durable 记录 | `approval/asked`/`approval/decided`（`interaction/user-approval/src/types.ts:36-70`）；`ApprovalPanel.tsx`（composer takeover）；`ChatView.tsx:232-233`（明确不做流程卡） | `DSHRemoteHarness.swift:403-409` 把 waterfall 变成 `permissionRequested`（`seq` 为 nil）；`ChatModel.swift:1756-1759` 只是置卡，回答后 `:1381-1390` 只追加英文状态行；mapper 无 `approval/*` | 审批在 transcript 里**没有任何痕迹**：重开会话后不知道当时批过什么、为什么；`ChatPage` 的权限卡是屏幕上方的浮层（`ChatPage.swift:2907`），与官方「接管 composer + 有 tool 关联详情」不同 | 行为合同：审批卡必须在 composer 位置接管（官方 `ApprovalPanel`），并绑定 `callId` 的 tool 详情（`conversation.approval.detail` 槽 → `ApprovalCommand.tsx`）；`approval/asked`+`decided` 至少要能还原“何时问了什么、结论” | `$events` waterfall（含 `callId/reason/displayReason`）+ durable `approval/asked`/`approval/decided` | 加 `Kind.approvalAsked(...)/approvalDecided(...)`；`ChatModel` 维护 `pendingApprovals[requestId]` 并与 tool call 关联 | 官方 `approval` 相关 host spec + 402pt 截图比对 composer 接管态 |
| **DP-07** | P1 | `goal` projection 读错层级 → GoalBar 恒 nil | wire 值是 `state.current` = `{goal, roundsStarted, createdAt, updatedAt} \| null`（`goal/index.ts:163-169`）；消费者 `GoalBar.tsx:187-192`（`projection.goal`） | `DSHRemoteHarness.swift:103-115` 读 `values.goal.current.goal`；`ChatModel.swift:1860-1861` 只有这一条写入路径；`ChatPage.swift:1136` 用 `model.goal` | goal 条永远不出现；`/goal` 建了目标也看不到、暂停/恢复按钮无从点 | 行为合同：`values.goal == null` → 不渲染；`values.goal.goal.phase` 决定文案；`activation` 需另走 `goal/activation-changed`（`$events` 已转发，`remote-events.ts:39`） | `session/projections.values.goal` | 改 `current` → 直接 `goal`；补 `id/revision/activation` | 用 `goal.e2e.ts:63` 的 `{goal:{revision,objective,phase,maxGoalRounds}}` 形状做解码测试 |
| **DP-08** | P1 | `title` projection 读错层级 → 会话标题永远不是 Host 的 | `title` wire = 字符串（`session-title/src/types.ts:86-92`、`session-title/src/index.ts:270-281`）；测试里就是 `values:{title:'Forked title'}`（`session-projections.host.spec.ts:701`） | `DSHManagementModel.swift:906` 读 `values.title.title` | 会话页头/列表显示本地猜的名字（`SessionTitleHints` 或「未命名会话」），与官方自动标题不一致 | 行为合同：`values.title` 为 string 直接用；`null` 才回退 | `session/list.projections.values.title` 或 `session/projections` | 去掉一层下标 | 解码测试用 `session-projections.host.spec.ts:701` 的字面值 |
| **DP-09** | P1 | 实时 `tool/result` 丢 `meta` 和 `error.name/code` → 实时与历史不一致 | `tool/result.data.meta` 是工具私有展示载荷（`core/session/src/types.ts:360-386`），`tool.ts:100-120` 用它建 diff/路径 | `DSHEventMapper.swift:94-107` 只产 summary/detail；`ChatModel.swift:1738-1753` 不写 `toolMetadata`；而历史投影器保留（`NativeTranscriptProjector.swift:95,107`） | 同一轮对话：流式时工具卡没有 diff/路径/退出码，杀进程重开后**卡片内容变了**（差异卡才出现） | 行为合同：工具卡的“详情”必须来自 `meta`（官方 `ToolDetails`/`detail-card-model`），`summary` 只做单行摘要；重放后不得新增字段 | durable `tool/result.meta` | `HarnessEvent.toolResult(..., meta:)`；`ChatModel` 写入 `toolMetadata` | 同一事件序列跑实时与重放，断言 `ChatItem` 逐字段相等 |
| **DP-10** | P1 | 不认 `surfaceOp` / `sourceEventSeqs` → 压缩替换被当成追加 | `SurfaceOp`（`core/session/src/types.ts:463-479`）；`isAppendSurfaceEvent`/`isReplacementSurfaceEvent` 是官方每条过滤的前提（`message.ts:40`、`tool.ts:305`、`compaction.ts:22-60`） | 全仓 `grep surfaceOp` 0 命中 | 发生压缩后：$N$ 条被摘要替代的旧行**仍然显示**，并且多出一条 `DSH context · compact-checkpoint` 的 context 行；工具结果替换同理 | 行为合同：`surfaceOp != 'append'` 的事件不得新增行；替换时按 `shadowedRange`/`sourceEventSeqs` 删除旧行并插一条压缩行 | 事件信封 `surfaceOp`/`sourceEventSeqs`（`SessionWireEvent` `types.ts:486-500`） | `ChatItem` 增 `surfaceOp` 与 `replacementOf:[Int]`，projector 做替换折叠 | 用 `compaction-basic` 的日志 fixture 断言：压缩后行数 = 压缩前 − shadowedSeqs + 1 |
| **DP-11** | P1 | usage 桶丢失 + 双源打架 | `TokenUsage`（`llm/src/types.ts:175-189`）；`tokenUsage` projection 的 `totals`（`usage-projection.ts:14-26,118`）；`assistant/message.usage` 随消息落盘 | `DSHEventMapper.swift:85-88` 只取 input/output；`ChatModel.swift:1814-1823` 覆盖最后一条 assistant 的 usage；`NativeTurnUsage` 虽支持 cache/reasoning（`NativeConversationModels.swift:82-122`）却无人填 | 每轮尾部统计与 composer 统计对不上官方（官方截图：`缓存命中 75%`）；重试/多 step 会重复累加 | 行为合同：单轮统计 = `tokenUsage` 差值（官方 last-wins 覆盖同 turn+step），cache 桶必须真值；`assistant/message.usage` 只作 per-step 兜底 | `TokenUsage` 全字段 + `tokenUsage`/`contextPressure` projection | mapper 保留 5 个桶；`ChatModel` 以 projection 为准、事件为辅 | 官方 `turn-usage.ts` 语义做对照（同 turn+step 替换，不累加） |
| **DP-12** | P1 | turn 结束语义压缩过度 | `TurnEndReasonMap`（`core/session/src/types.ts:192-230`）：`aborted.reason.kind ∈ user/parent/hook/disposed/legacy`；`error: LlmFailure{message,code,status,providerRetryAfterMs,requestId}`；`interrupted`/`forked` 是特殊收尾 | `DSHEventMapper.swift:143-152`：`blocked→.failed("blocked")`、`interrupted→.cancelled`、`forked→.completed`；`ChatModel.swift:1770-1803` 不读 `rawTurnEndCause` | 用户看不出“是你取消的 / 父 Agent 取消的 / hook 取消的 / 崩溃补记的”，错误也没有 code | 行为合同：`aborted` 的四种 cause、`error.code`、`interrupted`（崩溃补记）与 `max-tokens` 必须各自有文案分支（官方 `turn-error.ts:54-119`、`turn-max-tokens.ts:42-51`） | `turn/end.reason` 完整结构 | `HarnessTurnEnd` 增 `cancelled(cause:)`/`interrupted` 与 `LlmFailure(code:)` | 官方 `turn-error` 测试的 reason 矩阵逐条断言 |
| **DP-13** | P1 | 没有 step/attempt/retry 链 → 没有 turn-process 折叠 | `turn-process.ts:310-325`（9 类事件驱动）、`turn-tail.ts:148-163`（11 类）、`retry.ts:24-70` | mapper 无 `step/end`、`assistant/attempt`、`llm/retry-started`；`ChatModel` 只有 `.progress`；projector 把 retry 压成一个 systemEvent | 官方“一个可折叠的过程块（含步骤、工具、重试）”在 iOS 上变成散落的工具行 + 一行“模型请求重试” | 行为合同：turn 内按 step 聚合；重试链显示 `retry/maxRetries` 与 `delayMs`；折叠默认收起（402pt 下首屏只留 N 行） | `step/start,step/end,assistant/attempt,llm/retry,llm/retry-started` | 加 `Kind.stepStarted/stepEnded/attempt/retry`；`ChatItem.Kind` 加 `turnProcess`（聚合节点） | 官方 `turn-process-tail.client.spec.ts` 的场景 |
| **DP-14** | P1 | 嵌套工具调用（PTC）不可见 | `tool.ts:200-230,308-312`（`rootCallId` 挂到 root 的 children） | mapper/projector 无 `tool/ptc-dispatch*` | `run_code`/PTC 场景里官方是一棵树，iOS 只有一串平铺的工具行且缺子调用 | 行为合同：`rootCallId` 相同的 dispatch 归到 root 的 children，缩进一级（官方 ToolCallTree） | `tool/ptc-dispatch-start`/`tool/ptc-dispatch` | `ChatItem` 增 `children:[ChatItem]`/`parentCallID` | 官方 `ToolCallTree` 测试 + 402pt 缩进截图 |
| **DP-15** | P1 | 上下文分类只到 kind 字符串，且显示了官方隐藏的行 | 官方 `contextProducer`/`contextForm`（`event-projection.ts:60-100`）、`KNOWN_FORMS`（`:44-48`）、`isVisibleChatNode`（`chat-visibility.ts:10-19`，`chat-snapshot-builder.ts:525`） | `DSHMessageSourceClassifier.swift:15-21` 只分 user/context；title 拼成 `"DSH context · <kind>"`（`NativeTranscriptProjector.swift:36`），再被 `NativeChatTimelineChrome.swift:26-27` 字符串反解析；`NativeSourceName.chinese`（`:105-115`）只认 5 个**并不存在**的 kind | ① 每条注入上下文都占一个「上下文 · N 条」行，官方不显示（只有含 tool-addition/removal 的 context 才显示）；② 真实 kind（`agent-instructions`/`session-reference`/`skill-invocation`/`plan-mode`/`goal`/`schedule`/`time-context`…）全部没有中文名 | 行为合同：`form` 决定展开形态（`notice` 单行 `summary`、`snapshot` 分节、`instructions` 按 path、`recall` 按 label、`relay` 按发送者）；可见性规则照抄 `isVisibleChatNode` | `user/message.source` 的 `kind/form/summary/sections/references/name` | `ChatItem` 增 `contextSource: {kind, form, summary, sections, references, skillName}`；可见性过滤放到行构建阶段 | 官方 `event-projection` 单测 + 402pt 下“一次完整会话”截图对比行数 |
| **DP-16** | P1 | 一大批族完全未消费（命令/压缩摘要/系统提示/交付物/改动文件/后台任务/定时） | `command.ts:178-200`、`compaction.ts:39-60`、`request-prompt.ts:66-160`、`turn-deliverables.ts:172-215`、`ui-deliverables/src/client/index.ts:59-82`、`ui-schedule/src/client/index.ts:185-196`、`job/*` Remote | 见 §6 覆盖矩阵：`command/run`+`command/done`、`compaction/summary`（ContentBlock 被当字符串）、`system/message`、`request/header`、`deliverables/presented`、`workspace/changes`、`job/registered`+`job/settled`、`schedule/change`、`developer/message` 全部 ❌ | 斜杠命令没有行；压缩只有一句兜底文案；turn 尾没有“交付文件/改动文件/已创建任务”卡；后台任务只能在 Activity 页看 | 行为合同：`workspace/changes{turn}` 才允许出「改动文件」卡（官方数据来自 host git 摘要，不是从 write/edit 参数猜）；`deliverables/presented` 出文件卡；`schedule-created` 出任务卡 | 对应事件 + `workspaceChanges.summary/diff`、`deliverables` Remote | 逐族补 Kind + projector 分支；turn 尾用一个 `turnTail` 容器节点 | 每族一条官方 fixture；断言“事件在 → 卡在，事件无 → 卡无” |
| **DP-17** | P1 | 子会话混在普通会话列表里，页头不知道自己在子会话 | `session/list` 行含 `parentSessionId`/`origin`（`list.ts:353-363`、`types.ts:178-191`）；页头 lineage 用 `subagentCatalog` 建链（`SubagentHeaderLineage.tsx:464,492,793`） | `DSHManagementModel.swift:918` 解了 `parentSessionId` 但**只存不用**（全仓仅 `SessionActivityPage.swift:186` 用于 interrupt）；页头无 lineage | 用户从列表点进子会话，看到的是一个“独立会话”，没有父会话面包屑、没有返回父会话入口 | 行为合同：`origin=='subagent'` 的会话在列表里要么折叠到父项下，要么带“子会话”标记；页头显示 `父标题 / 子 label` | `session/list` 的 `parentSessionId/origin` + `subagent` projection | 建 `SessionTree` 索引；页头加 lineage 行 | 造一个父+两个子会话，断言列表折叠与页头链路 |
| **DP-18** | P1 | 实时流帧只认 text/reasoning delta | 官方 `assistant/live-chunk` 的 `tool-call-delta`/`block-end` 驱动 `preparing` 工具行（`tool.ts:296-302`）、`start/end` 帧带 revision/index（`types.ts:527-560`） | `DSHRemoteHarness.swift:350-364` 只处理 `chunk` + `text-delta`/`reasoning-delta`；`start`/`end` 帧直接 `break`；snapshot 的 `assistantStream` 基线不读（`:324-345`） | ① 工具行在 `tool/call` 落盘那一刻才出现（官方先出现 1 行的 preparing 态）；② 流式中途重连，已流出的半段文本**消失**（要等 `assistant/message`） | 行为合同：`block-start`/`tool-call-delta` → `preparing` 行（含参数增量）；`end{committed seq}` 用于把临时行交给 durable 行；`snapshot.assistantStream.activeAttempt.stream` 用于重连回填 | live-only 帧 + baseline | `Kind.assistantFrame(start/chunk/end)`；`ChatItem.Kind` 加 `preparingTool` | 官方 `assistant-stream.client.spec.ts` 的帧序列回放 |
| **DP-19** | P2 | 重连不校验 seq 断裂、不记录 gap | 官方遇 seq 不连续直接抛 `gateway/internal`（`history.ts:224-231`）；客户端窗口合并有 revision/change（`contract/events.ts:90-131`） | `ChatModel.swift:1650-1656` 只做 `seq <= current` 跳过；异常只 `reportError("Event stream interrupted")`，不区分“丢事件”和“网络断” | 通道抖动后可能出现“少了几条但没人知道”，用户看到一段莫名缺失的对话 | 行为合同：durable 事件 seq 必须连续（harness seq 连续同样成立，`dshSeq*8+part` 单调）；断号要显式提示并触发整段重读 | `SessionSeq` 语义 | 记录 `expectedSeq`，断号时重跑 `loadSessionHistory` | 注入一次缺帧（channel 单测）后断言 UI 出现“重新同步”状态 |
| **DP-20** | P2 | 历史分页不按 turn 切、投影器无跨页状态 | `turnWindow{minMessages,minTurns}` + turn 起点切分（`history.ts:392-418`、`types.ts:501-517`） | `ChatModel.swift:1443-1451`、`:1473-1478` 只用 `maxMessages:60`，从不传 `turnWindow` | 402pt 下“加载更早”可能把一轮切成两半：上半页的 turn 尾卡（改动文件/统计）出现在页边界之外；跨页的同一 turn 会算出两份 usage | 行为合同：分页必须落在 `turn/start`；`usage/changed-files` 以 turn 为单位跨页聚合 | `turnWindow` | 传 `turnWindow:{minMessages:40,minTurns:2}`；投影器接受“开放 turn”状态 | 长会话（>200 事件）翻页后断言 turn 不被切开 |
| **DP-21** | P2 | 轨迹面板每条事件重读 60 条 + 逐行 O(n) 扫描 | 官方窗口是增量 concat 树，`prepend/append` O(1)（`contract/events.ts:56-84`） | `ChatModel.swift:1562-1568`（500ms 防抖）、`:459-499`（每事件全量重读）；`ChatPage.swift:2302,2307,2319-2321`（每行 `filter` 全表 → O(n²)） | 长会话（数千事件）滚动掉帧、发烫 | 行为合同：滚动必须维持 60fps；不得在行渲染里做全表扫描 | — | 行构建期一次性预算 `turnUsage`/`turnChangedFiles` 字典；轨迹面板改增量或按需 | Instruments + 2000 事件 fixture 的滚动耗时 |
| **DP-22** | P2 | 死分支 `agent/steering/message` | 官方 0 命中（`grep -rn "agent/steering"` ⇒ 无输出），`known-event-types.ts` 无此类型 | `NativeTranscriptProjector.swift:20,27`、`ChatModel.swift:1582` 共 3 处 | 不会崩，但会误导后续实现（以为 steering 是独立事件类型） | — | — | 删除并改用 inbox claim | `grep` 归零 |
| **DP-23** | P2 | 工具结果 UI 侧 280 字符封顶 | 官方工具卡显示完整输出并可展开/分页（`ToolDetails`/`terminal-card-model`），超限走 spill | `DSHEventMapper.swift:162-165`（`truncate(280)`）是 UI 唯一来源；64KB 全文本只进 `toolResultDetail` 给 scenario | `bash`/`read` 的长输出被截成一行；用户点开看不到全部 | 行为合同：单行摘要 ≤ 280 字符；展开后必须给完整文本（官方 spill 有“查看完整记录”路径） | `toolResultDetail`（已有） | UI 展开时用 `toolResultDetail.text`，超出 64KB 时给 spill 入口 | 官方 `terminal_card`/`ToolDetails` 的长输出截图 |
| **DP-24** | P2 | 实时行的 turn/step/messageID 靠“当前状态”猜 | 官方事件自带 `turn/step/message.id`（`assistant/message` 事件结构 `core/session/src/types.ts:342-350`） | `ChatModel.swift:1712-1716` 用 `activeTurn/activeStep`，`messageID` 从不设置（`:127-133` 之外无写入） | 并发/乱序（`$events` 与 follow 两条流）时 assistant 行可能挂到错误的 turn 下；按 messageID 去重的统计失效 | 行为合同：行的 turn/step/messageID 必须来自事件本身，不来自 UI 当前态 | 事件内 `turn/step/message.id` | `Kind.assistantMessage(..., messageID:turn:step:usage:)` | 打乱两条流的到达顺序，断言归属不变 |

---

## 5. 隐藏/条件控件清单（本轴视角：数据是否到位）

| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 数据是否拿得到 | 备注 |
|---|---|---|---|---|---|
| todo 输入 dock | `todos` projection 非空 | `TodoPanel.tsx:106-117`（`conversation.input.dock` id `todo`, order 0） | ❌（仅 Activity 页列表） | ✅ `session/projections.values.todos`（Activity 已读，`DSHManagementModel.swift:562`） | 数据在，UI 没接进会话页 |
| plan 模式位 | `plan` projection 存在 | `PlanModeControl.tsx:20` + `conversation.composer.dock` | ❌（仅 Activity 页一行字） | ✅ `values.plan` | 同上 |
| plan 审阅卡（turn 尾） | 本轮有 `submitted-plan` | `ui-plan/src/client/index.ts:80-95`（`conversation.chat.turnTail`） | ❌ | ⚠️ 需要 chat target 的 `turnDataSource`，iOS 无等价物 | 依赖 DP-13/DP-02 |
| question 待答面板 | `user-questions/request` waterfall | composer takeover（`ui-user-questions/src/client/index.ts:380-400`） | ⚠️ 有卡，位置错（transcript 上方 `ChatPage.swift:481-540`） | ⚠️ 字段缺（DP-04） | — |
| question 已回答回执 | `user/message`(`user-question-reply`) 或 `userQuestions.settled` | `question-reply.ts:153-190` → `question-reply` 行 | ❌ | ❌ 事件未映射 | 官方有“跳过/已答”文案 |
| question 计时等待 | `wait.timed` + `attachWait` | `ui-user-questions/src/client/index.ts:222-227` | ❌ | ❌ 需 `userQuestions.attachWait` 流 | 官方 402pt 下有倒计时 |
| approval 接管 | `approval/request` | `ApprovalPanel.tsx`（composer） | ⚠️ 有 `PermissionCardView`（页顶浮层，`ChatPage.swift:2907`） | ⚠️ 有请求，无 `reason/displayReason/callId` 关联 | — |
| approval 审计行 | `approval/asked/decided` | 无 transcript 行（官方刻意不做） | ❌ | ❌ 事件未映射 | 若要“事后可查”，需自建 |
| subagent 页头 lineage | 父会话有 `subagentCatalog` | `SubagentHeaderLineage.tsx` | ❌ | ⚠️ 父会话数据可拿（Activity 已读），未接 | — |
| 子会话入口/只读 composer | `subagent.mode==='continuable'` | `ui-subagent/sidebar-chat`、`SubagentReadOnlyComposer.tsx` | ❌ | ❌ 无子会话寻址/订阅 | 官方手机宽度是 push/右侧栏 |
| 后台任务 roster | `job/*` + `job/list` | `ui-jobs` 会话头 | ⚠️ Activity 页 | ✅ `job/list` 流可用（`DSHManagementModel.swift:583-616`） | 位置与形态都不对 |
| 定时任务已创建卡 | `schedule/change` → turnTail | `ui-schedule/src/client/index.ts:185-196` | ❌ | ⚠️ `schedule/catalog` 可用，事件未映射 | — |
| 交付文件卡 | `deliverables/presented` | `turn-deliverables.ts:172-215` | ❌ | ❌ 事件未映射 | — |
| 改动文件卡 | `workspace/changes{turn}` | `ui-deliverables` turnTail | ⚠️ 有，但是从 write/edit 参数猜（`ChatPage.swift:2302`） | ⚠️ 官方数据源是 host git 摘要 | 结果会漏掉 bash 改的文件 |
| turn 过程折叠 | turn + ≥1 step | `TurnProcessNodeView` | ⚠️ 有“工具 run”折叠，粒度不同（`ChatPage.swift:462-469`） | ✅ 事件够，但 `step/end` 未映射 | — |
| 工作流 run 卡 | `tool-workflow/*` | `ui-workflow-run` `workflow-run` node | ❌ | ❌ 事件未映射 | 手机宽度也要有 |
| 手动压缩行 | `command/run(/compact)` + `compaction/*` | `manual-compaction` node | ⚠️ 一句“上下文已整理” | ⚠️ summary 解析失败 | — |
| 重试链 | `llm/retry*` + `assistant/attempt` | `model-retry` node | ⚠️ 一行 systemEvent | ⚠️ 次数/延迟丢失 | — |
| 系统提示 / 请求头 | `system/message` / `request/header` | 建了 node 但被 `isVisibleChatNode` 隐藏 | ❌ | ❌ 未映射 | 官方不显示，iOS 不显示 = 对齐 |
| steering 行 | inbox next-step claim | `steering` node | ❌（显示成普通 user） | ❌ 无 claim | DP-01 |
| turn-trigger 行 | next-turn claim 的非人类输入 | `turn-trigger` node | ❌ | ❌ | DP-01 |
| 队列 dock | `inbox.next-turn` 非空 | `QueueDock.tsx:105-109` | ❌（只有本地标签） | ❌ 无 `inbox` | — |
| GoalBar | `goal` projection 非空 | `GoalBar.tsx` | ⚠️ 代码在，数据恒 nil | ❌ 路径 bug | DP-07 |
| 上下文行 | 任意 `user/message` 非 user source | 官方**隐藏**普通 context | ⚠️ 显示为「上下文 · N 条」 | ⚠️ 只有 kind | DP-15 |

---

## 6. 数据链路缺口

### 6.1 事件覆盖矩阵（官方 66 durable + 1 live-only）

列含义：**Mapper** = `DSHEventMapper`；**ChatModel** = 实时处理；**历史投影** = `NativeTranscriptProjector`；**可见 UI** = 用户是否看得到。
✅ 完整 / ⚠️ 部分或形状错 / ❌ 无。

| 官方事件 | Mapper | ChatModel | 历史投影 | 可见 UI | 说明 |
|---|---|---|---|---|---|
| `turn/start` | ✅ | ✅ | ❌ | ⚠️ | 历史侧不建 turn 边界，只靠每事件 `data.turn` |
| `turn/end` | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 只 2 种 reason 出行（DP-12） |
| `step/start` | ⚠️ | ⚠️ | ❌ | ⚠️ | 只当 `activeStep` |
| `step/end` | ❌ | ❌ | ❌ | ❌ | 无 step 关闭 |
| `assistant/message` | ⚠️ | ⚠️ | ✅ | ✅ | 实时丢 reasoning/image/usage 桶 |
| `assistant/attempt` | ❌ | ❌ | ❌ | ❌ | 重试链缺 |
| `assistant/live-chunk`（live-only） | ⚠️ | ⚠️ | — | ⚠️ | 只 text/reasoning delta（DP-18） |
| `tool/call` | ✅ | ✅ | ✅ | ✅ | — |
| `tool/result` | ⚠️ | ⚠️ | ✅ | ⚠️ | 实时丢 meta/error.code（DP-09） |
| `tool/ptc-dispatch` | ❌ | ❌ | ❌ | ❌ | DP-14 |
| `tool/ptc-dispatch-start` | ❌ | ❌ | ❌ | ❌ | DP-14 |
| `user/message` | ⚠️ | ❌ | ✅ | ⚠️ | 实时整体丢弃（DP-03） |
| `agent/inbox/spliced` | ✅ | ❌ | ❌ | ❌ | DP-01 |
| `developer/message` | ❌ | ❌ | ❌ | ❌ | 工具增删通知 |
| `system/message` | ❌ | ❌ | ❌ | （官方也隐藏） | — |
| `request/header` | ❌ | ❌ | ❌ | （官方也隐藏） | — |
| `request/context` | ❌ | ❌ | ❌ | 投影 | `contextPressure` 已由 remote 读 |
| `model/selection` | ❌ | ❌ | ❌ | 投影 | `modelSelection` 未读 |
| `permission/preset` | ❌ | ❌ | ❌ | 投影 | `permissions` ✅（唯一读对的） |
| `sandbox/mode` | ❌ | ❌ | ❌ | 投影 | 并入 `permissions` |
| `approval/policy` | ❌ | ❌ | ❌ | 投影 | 并入 `permissions` |
| `approval/asked` | ❌ | ❌ | ❌ | ❌ | DP-06 |
| `approval/decided` | ❌ | ❌ | ❌ | ❌ | DP-06 |
| `plan/mode` | ❌ | ❌ | ❌ | ⚠️ Activity | DP-02 |
| `todo/write` | ❌ | ❌ | ❌ | ⚠️ Activity | DP-02 |
| `goal/change` | ❌ | ❌ | ❌ | ❌ | DP-07 |
| `subagent/catalog` | ❌ | ❌ | ❌ | ⚠️ Activity | DP-05 |
| `subagent/descriptor` | ❌ | ❌ | ❌ | ❌ | DP-05 |
| `subagent/model-selection-policy` | ❌ | ❌ | ❌ | 设置页 | — |
| `command/run` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `command/done` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `compaction/start` | ❌ | ❌ | ✅（前缀匹配） | ⚠️ | 文案兜底 |
| `compaction/summary` | ❌ | ❌ | ⚠️ | ⚠️ | `summary` 是 ContentBlock[]，被当字符串读 |
| `compaction/end` | ❌ | ❌ | ✅ | ⚠️ | 与 start 出重复行 |
| `compaction/prune` | ❌ | ❌ | ✅ | ⚠️ | — |
| `image/offload` | ❌ | ❌ | ❌ | 投影 | 图片占位替换 |
| `llm/retry` | ❌ | ❌ | ✅ | ⚠️ | 一行兜底 |
| `llm/retry-started` | ❌ | ❌ | ✅ | ⚠️ | 同一行 |
| `job/registered` | ❌ | ❌ | ❌ | ⚠️ Activity | `job/list` 兜底 |
| `job/settled` | ❌ | ❌ | ❌ | ⚠️ Activity | — |
| `schedule/change` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `deliverables/presented` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `workspace/changes` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `tool-workflow/run-start` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `tool-workflow/run-end` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `tool-workflow/agent-start` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `tool-workflow/agent-end` | ❌ | ❌ | ❌ | ❌ | DP-16 |
| `session/title` | ❌ | ❌ | ❌ | ⚠️ 读错路径 | DP-08 |
| `session/title-llm-request` | ❌ | ❌ | ❌ | ❌ | — |
| `session/end-seed` | ❌ | ❌ | ❌ | — | fork 边界，仅日志 |
| `working-directory/change` | ❌ | ❌ | ❌ | 投影 | 会话页页头/工作区 |
| `agent-preset/selected` | ❌ | ❌ | ❌ | 投影 | 设置 |
| `feedback/message-put` | ❌ | ❌ | ❌ | 投影 | iOS 只写不读（`ChatModel.swift:1900-1915`） |
| `feedback/message-delete` | ❌ | ❌ | ❌ | 投影 | 删除后的行不应再显示 |
| `feedback/record` | ❌ | ❌ | ❌ | — | — |
| `hook/invoked`（experimental） | ❌ | ❌ | ❌ | — | 不随附 |
| `hook/result`（experimental） | ❌ | ❌ | ❌ | — | 不随附 |
| `team/*`（4 个，experimental） | ❌ | ❌ | ❌ | — | 不随附 |
| `webhook` 源（experimental） | ❌ | ❌ | ❌ | — | 仅事件源 |
| `session-log-deepseek/delivery-accepted` | ❌ | ❌ | ❌ | — | 持久化实现细节 |
| `web/deepseek-search-llm-request` | ❌ | ❌ | ❌ | — | 搜索审计 |

统计：✅ 5 个（`tool/call`、`assistant/message`(历史)、`tool/result`(历史)、`agent/inbox/spliced`(仅 mapper)、`compaction/*`(仅历史)）——**真正端到端 ✅ 的只有 `tool/call`**。

### 6.2 字段缺口表

| 官方字段 | 位置 | iOS 对应 | 丢失后果 |
|---|---|---|---|
| `user/message.data.source.form` | `llm/src/message.ts:61-99` | 无 | 无法区分 notice/snapshot/relay/recall，官方每种形态渲染不同 |
| `source.summary` | `ContextFormed 'notice'` | 无 | notice 行没有单行说明（官方不展开就有一行） |
| `source.sections[{name,text}]` | `'snapshot'` | 无 | 快照型上下文无法分节 |
| `source.references[{sessionId,label}]` | `session-reference/src/types.ts` | 无 | recall 行没有来源标签（官方 `sessionRecallLabels`） |
| `source.name`（skill） | `skill/src/index.ts:155-159` | 无 | skill 注入行没有技能名 |
| `source.callId/outcome`（`user-question-reply`） | `user-questions/src/types.ts:108-117` | 无 | 无法把回执绑到那次提问 |
| `source.senderSessionId`（`agent-message`/`subagent-settled`） | `subagent/continuation-messages.ts:14-44` | 无 | 无法显示“来自哪个子 Agent” |
| `message.id` | `MessageBase` | 仅历史 block 行有（`NativeTranscriptProjector.swift:64`） | 实时行无 id → 反馈/去重/编辑都缺 key |
| `turn/step` | 每个事件 | 实时用 `activeTurn/activeStep` 猜（DP-24） | 乱序时归属错 |
| `surfaceOp` / `sourceEventSeqs` | `core/session/src/types.ts:463-479` | 无 | 压缩替换/阴影范围不可折叠（DP-10） |
| `usage.{cacheReadTokens,cacheWriteTokens,reasoningTokens,totalTokens}` | `llm/src/types.ts:175-189` | 实时丢；模型支持但无人填（`NativeConversationModels.swift:82-107`） | 缓存命中率/推理 token 错（DP-11） |
| `tool/result.meta` | `core/session/src/types.ts:376-386` | 历史有、实时无 | 工具卡实时缺 diff/路径/退出码（DP-09） |
| `tool/result.error.{name,code}` | 同上 `:380-385` | 只用作 isError | 失败原因不可分（超时 vs 拒绝 vs 中断） |
| `reason.error.{code,status,providerRetryAfterMs,requestId}` | `LlmFailure` | 只取 message | 错误行没有可操作信息 |
| `assistant/message.interrupted` | `core/session/src/types.ts:342-350` | 无 | 被取消的前缀与正常完成长得一样 |
| `ask_user_question` 的 `detail/header/options[].description/intent/wait` | `user-questions/src/types.ts:20-68` | 无 | 见 DP-04 |
| `userQuestions.active[].{callId,state}` / `settled[].answers` | `user-questions/src/types.ts:70-140` | 无 | 已回答/继续答不可表达 |
| `subagentCatalog[].{id,createdAt,mode,label}` | `subagent/projection-types.ts:12-24` | Activity 部分解析（label/mode，丢 createdAt） | 目录排序/时长不可用 |
| `subagentTiming.{settledMs,active,lastTurnCompleted}` | 同上 `:26-40` | 无 | 子 Agent 运行时长/状态点缺失 |
| `inbox.{next-turn,next-step}[].{id,content,source}` | `core/agent/src/types.ts:43-60` | 无 | 队列和分类（DP-01） |
| `turnOutline[]` | `session-turn-outline/src/types.ts:45-48` | 无（自己数 turn） | TurnNavigator 不可做（视觉轴） |
| `sessionStats.{turns,steps,llmMs,toolMs,ttftMs,ttftSteps,decodeMs,decodeTokens}` | `session-stats/src/projection.ts:72-86` | ✅ 全字段 | — |
| `tokenUsage` 五桶 | `usage-projection.ts:14-26` | ✅ 模型支持，✅ 读 | 但事件侧丢（DP-11） |
| `contextPressure.{pressureTokens,projectedTokens,contextWindow}` + `claim` | `usage-projection.ts:100-110` | 读 3 个字段（`NativeConversationModels.swift:160-177`） | `claim`（压缩阴影计价）未用 |
| `goal.{goal,roundsStarted,createdAt,updatedAt}` | `goal/src/types.ts:106-124` | 期望 `goal.current.goal`（错） | DP-07 |
| `plan.{active,pending}` | `plan-mode/src/types.ts:20-26` | Activity 页 ✅，会话页 ❌ | DP-02 |
| `todos[].{content,status}` | `tool-todo/src/types.ts:19-46` | Activity ✅，会话页 ❌ | DP-02 |
| `permissions.currentValue` | `permission-presets/src/types.ts:35-40` | ✅ | — |
| `title`（字符串） | `session-title/src/types.ts:86-92` | 期望 `title.title`（错） | DP-08 |

### 6.3 需要新增的 `HarnessEvent.Kind` / 数据模型（按 UI 依赖排序）

```jsonc
// 1) 输入分类（DP-01/DP-03）——最高优先，steering/turn-trigger/queue 全靠它
{ "kind": "inboxSpliced",
  "target": "next-turn" | "next-step",
  "start": 0, "removedCount": 0,
  "inserted": [ { "id": "msg_…", "text": "…", "source": "user" } ],
  "outcome": "canceled" | null }

// 2) 结构化上下文（DP-03/DP-15）
{ "kind": "contextMessage",
  "messageId": "msg_…", "turn": 3, "step": 1,
  "content": [ { "type": "text", "text": "…" } ],
  "source": { "kind": "agent-instructions", "form": "instructions",
              "summary": null, "sections": null,
              "references": null, "skillName": null, "senderSessionId": null },
  "waking": false }

// 3) 问答全生命周期（DP-04）
{ "kind": "questionRequested",
  "requestId": "…", "callId": "call_…", "timed": true,
  "state": "open",
  "questions": [ { "id": "q1", "header": "…", "question": "…",
                   "detail": "…", "multiSelect": false,
                   "options": [ { "label": "批准", "description": "…" } ],
                   "intent": { "kind": "plan-review", "approve": "批准", "callId": "call_…" } } ] }
{ "kind": "questionSettled",
  "callId": "call_…",
  "answers": [ { "id": "q1", "selected": ["批准"], "custom": null } ],
  "outcome": "answered" }

// 4) 审批审计（DP-06）
{ "kind": "approvalAsked",  "id": "appr_…", "toolName": "bash", "callId": "call_…", "reason": "…" }
{ "kind": "approvalDecided","id": "appr_…", "outcome": "allowed-once" }

// 5) 子 Agent（DP-05/DP-17）
{ "kind": "subagentCatalog",
  "entries": [ { "id": "sess_child", "createdAt": 0, "mode": "continuable", "label": "查日志" } ] }
{ "kind": "subagentTiming",
  "settledMs": 12000, "active": { "since": 0, "through": 0 }, "lastTurnCompleted": true }

// 6) 轮次过程（DP-13/DP-14）
{ "kind": "stepEnded", "turn": 3, "step": 1 }
{ "kind": "assistantAttempt", "turn": 3, "step": 1, "text": "…", "failureCode": "RATE_LIMIT" }
{ "kind": "ptcDispatch", "rootCallId": "call_root", "callId": "call_sub", "name": "read",
  "arguments": { }, "phase": "start" | "settled" }

// 7) 工具结果补字段（DP-09/DP-18）
{ "kind": "toolResult", "callID": "call_…", "isError": false,
  "summary": "…", "meta": { "diffs": [], "path": "src/a.ts", "exitCode": 0 },
  "errorName": null, "errorCode": null }
{ "kind": "toolPreparing", "callID": "call_…", "name": "bash", "argumentsDelta": "{\"command\":" }

// 8) turn 尾与压缩（DP-10/DP-16）
{ "kind": "deliverablesPresented", "turn": 3, "callId": "call_…", "files": [ { "path": "a.md" } ] }
{ "kind": "workspaceChanges", "turn": 3 }
{ "kind": "compactionSummary", "compactionId": "cmp_…", "summary": "…",
  "shadowedSeqs": [4,5,6], "shadowedRange": { "start": 4, "end": 6 } }
{ "kind": "commandRun", "commandId": "…", "name": "compact", "args": "" }
{ "kind": "commandDone", "commandId": "…", "result": "…" }

// 9) 轮次/会话级状态（DP-07/DP-12）
{ "kind": "goalChanged", "goal": { "id": "…", "revision": 2, "objective": "…",
  "phase": "paused", "maxGoalRounds": 8 }, "roundsStarted": 3,
  "activation": "disarmed" }
{ "kind": "turnEnded", "turnID": "3", "reason": { "kind": "aborted",
  "cancelCause": "hook", "failureCode": null } }
```

配套模型改动：
- `ChatItem.Kind` 增：`steering`、`turnTrigger`、`questionReply`、`compaction`、`command`、`turnProcess`、`deliverable`、`changedFiles`、`systemPrompt`（若以后要显示）。
- `ChatItem` 增：`seq: Int?`、`surfaceOp`、`messageID`（实时也要有）、`contextSource`、`children:[String]`（PTC）、`meta`（实时）。
- 抽出 `NativeConversationClassifier`：实时与历史共用同一套 `user/steering/context/turnTrigger` 判定，禁止两套。

---

## 7. 实施顺序建议

**Wave 1（P0，先修“数据进不来”）**
1. DP-02 projection 通路：`DSHRemoteHarness` 开 `session/control`；`follow.snapshot.projections` 落地；建 `HarnessProjectionStore`（key→(value,seq)，高 seq 胜）。
2. DP-01 + DP-03：`inbox` claim fold + 单一分类器；`handle` 不再丢 `user/message`。
3. DP-07/DP-08 两个路径 bug（一行级修复，先摘果子，验证 projection 通路确实通了）。
4. DP-06 审批：`approval/{asked,decided}` 映射 + composer 接管。

**Wave 2（P0 剩余 + P1 主干）**
5. DP-04 问答全生命周期（含 `question-reply`、`attachWait`、plan-review intent）。
6. DP-05 + DP-17 子会话地址/订阅/lineage。
7. DP-09/DP-11/DP-12/DP-13/DP-14：mapper 字段与 Kind 扩展。
8. DP-10 `surfaceOp`（压缩折叠）——依赖 DP-16 的 `compaction/summary`。
9. DP-15 上下文分类与可见性规则。

**Wave 3（P1 收尾 + P2）**
10. DP-16 其余族（command/deliverables/workspace-changes/schedule/jobs/workflow）。
11. DP-18 流式帧（preparing 工具 + 重连回填）。
12. DP-20 分页 `turnWindow`；DP-21 性能预算；DP-22/23/24 清理与补全。

依赖图要点：DP-01 依赖 DP-02 的 projection 通道（也可以只用 durable `agent/inbox/spliced` 先跑通，但 queue dock 必须要 projection）；DP-05 依赖 DP-02（`subagentCatalog`）；DP-13/DP-16 依赖 DP-02（turn 尾卡片要从 projection 读统计，不能自己加）。

---

## 8. 未知与需确认

1. **`session/control` 在手机通道上的实际吞吐**：`ChannelDSHTransport` 的 `receive` 是 NDJSON unary 长请求，Host 全局 control 流会对**所有会话**推送 projection 帧；在手机上是否需要按 session 过滤（官方客户端是 Host-全局订阅、客户端自己按 `sessionId` 分派）。需实测一次多会话并发时通道压力。
2. **子会话在 402pt 下的导航形态**：官方手机宽度把右侧栏换成抽屉/整页；子会话聊天用 push 还是 sheet 属于产品决策（BRIEF §5.2 要求“给出官方手机端替代路径，不要默默发明”）。官方 `ui-mobile` 只覆盖布局，没有把 sidebar-chat 改成 push 的显式代码——需真机确认。
3. **timed question 的倒计时起点**：`attachWait` 只给 `{remainingMs}`，没有绝对截止时刻；断线重连后由谁决定剩余时间需实测。
4. **`workspace/changes` 的 host 侧 git 快照**在手机 Worker（无 git 或受限）上是否可用 —— 若不可用，改动文件卡只能退回 tool-args 推导，必须在报告/产品上明示差异。
5. **`assistantStream` 基线的 `stream: JsonValue[]`** 具体是 `AssistantStreamRecord[]` 还是压缩帧，需要在真实流中抓一次（官方类型 `AssistantStreamRecord` 未在客户端展开）。
6. **`partsPerEvent=8` 的上限**：一个事件最多拆 8 个 harness part；`assistant/message`（文本 + usage）用 2，但若未来一个事件要拆更多（如多 block），需确认 `part` 溢出行为（`DSHEventMapper.swift:25-29` 无保护）。
7. **`session/list` 是否包含无 cwd 的子会话**：`list.ts:144` 对 cold 行要求 `header.cwd !== undefined`，子 Agent 若未继承 cwd 则不出现 —— 需确认 Worker 的 subagent 创建路径是否写入 cwd。
8. **iOS 端是否已有未启用的 projection 读取代码**（如某些 `values[...]` 键在别处被读）——本次只审了 `ChatModel`/`DSHManagementModel`/`ChatPage` 三处主路径，`NativeConfigurationModel` 等设置页未逐行核对。

---

## 附录 A：官方 node kind 全集（shipped renderers）

`user`、`steering`、`context`、`turn-trigger`、`system-prompt`、`assistant-step`、`command`、`command-input`(ui-goal)、`manual-compaction`、`compaction`、`model-retry`、`turn-error`、`turn-max-tokens`、`turn-process`、`turn-tail`、`unknown`、`tool-call`、`question-reply`(ui-user-questions)、`workflow-run`(ui-workflow-run)。

证据：`chat/register-node-renderers.ts:41-89`、`ui-goal/src/client/index.ts:82`、`ui-user-questions/src/client/index.ts:395-400`、`ui-workflow-run/src/client/index.ts:28-40`。

iOS 有对应渲染的：`user`、`context`、`assistant`、`reasoning`、`image`、`toolCall`(折成 run)、`toolResult`、`systemEvent`(retry/compaction)、`turnError`、`maxTokens`、`status`。
缺失：`steering`、`turnTrigger`、`turnProcess`、`turnTail`、`command`、`commandInput`、`compaction`(真卡)、`modelRetry`(真卡)、`questionReply`、`workflowRun`、`deliverables`、`changedFiles`(官方数据源版)。

## 附录 B：官方 composer/input 槽位（数据来源）

| 槽 | 注册者 | 数据来源 |
|---|---|---|
`conversation.input.dock` id `todo` | `TodoPanel.tsx:117` | `todos` projection |
`conversation.input.dock` id `queue` | `QueueDock.tsx:395` | `inbox` projection |
`conversation.input.dock` id `goal` | `ui-goal/src/client/index.ts:103` | `goal` projection + `goal/activation-changed` |
`conversation.composer.dock` id `activity`/`usage` | `ui-chat/src/client/apply.ts:325,328` | `sessionStats`/`tokenUsage`/`contextPressure` |
`conversation.input.overlay` `command-popup` | `ui-commands/src/client/index.ts:65` | `commands/list` |
`conversation.input.overlay` `slash-menu` | `ui-input-trigger/src/client/index.ts:66` | 触发词表 |
`conversation.input.overlay` `feedback-dialog` | `ui-message-feedback/src/client/index.ts:116` | `messageFeedback` |
`conversation.chat.turnTail`（多贡献） | deliverables / ui-plan / ui-schedule / ui-deliverables | `deliverables/presented`、`workspace/changes`、`submitted-plan`、`schedule/changed` |

iOS 对应：`NativeComposerStats.swift`（activity/usage 的本地近似）、`ChatPage` 的 queued 标签、`/` 菜单（`loadCommands`）。`todo`/`queue`/`goal` 三个 dock 的数据通路见 DP-01/02/07。
