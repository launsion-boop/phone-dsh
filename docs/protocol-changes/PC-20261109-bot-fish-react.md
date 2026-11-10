<!-- SPDX-License-Identifier: MIT -->

# FishAction 工具、FishDirector 事件映射与头像一次性反应（P26/P27/P09）

```yaml
change: PC-20261109-bot-fish-react
contracts: [P26, P27, P09]
status: implemented
breaking: false
base: b4c3cca0901b6c08ad0c39a4012a8296a1070231
contract_revision: spec/bot/v1/golden/{tool-catalog.phone,tool-effects.phone}.json@fish-react-1 + Sources/PhoneDSHBot/Avatar/BotFish{Reactions,EventMapping}.swift@fish-react-1
version_decision: Additive phone-only tool (`FishAction`), additive phone golden entries, no new wire event type, no new durable event, no schema/enum widening of the upstream catalog, and an optional avatar parameter with a default. Old readers ignore the new phone delta; the BotEvent envelope and the DSH session log keep their existing shapes.
```

Protocol impact: P26 — FishAction tool, effect classification and director event mapping; P27 — FishAction tool row hidden from transcript/process list; P09 — avatar one-shot reactions and gallery fixture. No P25 change: no envelope member, event type, journal row or SQLite schema change.

## 1. 识别与现状

- 上游 `src/main/tools/fish.cjs`、`src/main/fishActions.cjs`、`src/main/mcp/dshbotServer.cjs:202,1032-1039` 已把 `FishAction` 暴露给模型：24 个动作/表情，纯外观、每次回复最多一次、不得当作完成证据。手机端此前没有该工具；`BotFishDirector` 已实现上游 director 状态机，但会话事件与 durable BotEvent 没有统一入口，头像只能显示 lifecycle 状态，不能播放一次性手势/表情。
- 上游 App 的消费链路是 `fish-action` IPC → `playFishReaction(agentId, name)` → 该 Bot 的所有实时 driver；动作播放一个 clip 周期，表情 4 s 后回到 lifecycle。手机端不新增 wire 事件：模型调用 `FishAction` 时 DSH 会话日志本来就会记录 `tool/call`，UI 从该 Bot 的实时帧/会话事件解析 `action` 即可。
- 上游显示契约把所有 `tool-call` 行设为 hidden；手机端保留真实工作的工具过程行，因此需要把外观工具单独排除，避免 wink/鞠躬出现在「回合工具列表」中。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| `FishAction` 工具 | 新增 phone 工具，名字 `FishAction`；`action` 必填，枚举严格等于上游 `FISH_REACTIONS`（16 动作 + 8 表情），`additionalProperties:false`。描述逐句复用上游 `fish.cjs`：一次回复最多一次、只在情绪合适时、不改变任务状态/进度/文件/审批、不得当作完成证据、严肃回答时不要使用。目录由 `BotToolCatalog.allDefinitions` 暴露。 |
| 执行面 | `BotFishActionTool` 实现 `BotTeamToolHandling`。合法 action 返回上游本机工具同义中文：`FishAction: 已在介面播放「<action>」；這只是外觀動作，沒有改變任何工作狀態。`，并带 structured `{ok,action,kind,durationMs}`。缺失/未知 action 返回 `invalid_arguments` 与可用值。不写新 event，不改变任务/记忆/授权状态。 |
| 目录路由 | `FishAction` 被 catalog 宣告，但故意不加入 `isRegistered`/generic dispatch：它和 team tools 一样走 `BotMCPRuntime.registerTeamTools` 的宿主 seam，避免 generic dispatch 落到 `unknown_tool`。App 第 3 波必须调用 `await runtime.registerFishActionTool()`。 |
| 授权分类 | `BotToolEffectClassifier.effect("FishAction")` = `ui.FishAction`、`mutability: read`、`policy: auto`、`ui: true`、`known: true`；`BotToolEffectClassifier.policy` = `auto`。Worker `AUTO_TOOLS` 同步加入 `FishAction`，既不走结构审批，也不会出第二张审批卡。 |
| 显示契约 | `BotDisplayContract.hiddenToolNames = ["FishAction"]`；`project` 对所有 `tool-call` 行保持 hidden（上游同义），并新增 `isToolCallVisible(named:)` / `visibleToolCallNames(_:)` 供手机端过程行列表过滤。`mcp__phone__FishAction`、`mcp__dshbot__FishAction` 都能按 bare name 识别。 |
| Director 事件映射 | `BotFishDirectorEventMapper.event(from:)` 接受 `BotFishEventSource.dshSession(BotDSHSessionEvent)` 或 `.botEvent(BotEvent)`，输出既有 `BotFishEvent`；`BotFishDirector` 及其 golden 完全未改。会话别名：`turn/start→turn.start`、`turn/end→turn.end`、`user/message(role=user)→user.message`、`assistant/stream→model.delta`、`tool/call→tool.start`、`approval/*`、`error`。BotEvent 别名表见 §3。`lifecycle(from:)` 只映射 turn/tool/stream/approval 的可见事实；60 s 空闲→sleeping 仍由 App 现有 `BotChatModel.idleSleeping` 时钟承担。 |
| 一次性反应 | `BotFishReaction { id, botID?, kind(.action/.expression), name, startedAt, durationMs }`；`BotFishReaction.reaction(from: BotFishToolCall, now:)` 只接受 `FishAction`，动作时长取上游 `CLIPS`/`EXTRA_PERIODS` 的一个周期（waving 1600、bowing 2800、clapping 1200、kiss 2600、cheering 1600、shy 3200、smug 2600、crying 2400、sighing 3600、shaking-head 2400、stretching 4200、yawning 4800、high-five 2200、nod 2000、celebrate 1500、dancing 1800），表情固定 4000 ms。id 取工具调用 id（ToolEvent id/DSH eventID/fallback），同 id 在 view 层去重。 |
| 头像播放 | `BotFishView(state:size:appearance:crowned:still:allowsPoke:reaction:)`：`reaction` 为末尾可选参数，默认 nil，现有调用点不变。`BotFishEngine` 按 id 去重；动作完整采样一个 clip，表情只 overlay face/eyeArt/mouthArt 并保持 lifecycle 身体姿态；TTL 到后回到 lifecycle。reduce motion 时仍只切换表情/面部，`step` 将位移归零；表情的 4 s 由 TimelineView 继续驱动以便按时回落。 |
| 画廊 | `BotFishGalleryView` 新增 `reactions` 区，24 格（6 列、64pt、`still:true`），每格 accessiblity id `bot.fish.gallery.reaction.<name>`；静止采样取动作 clip 的 25% 节拍（表情 650 ms），便于截图核对姿态与头朝上。 |

Self-check（`spec/README.md` §5.1）：没有第二种 envelope；`FishAction` 是 additive 名字，不改上游 P0 enum/golden；未知 action fail-closed；没有新增 wire event type、durable event type、frame 或 schema 版本；旧数据无需迁移。

## 3. 手机端事件来源对照表

`BotFishDirector` 的上游事件 → phone 真实来源。表中「映射」指 `BotFishDirectorEventMapper` 已验证的输入；「状态」指来源的生产者/缺口。

| 上游 director 事件 | 手机端真实来源（类型 / 字段） | 映射与状态 |
| --- | --- | --- |
| `turn.start` | 实时：`BotLiveFrame.event` 的 DSH `turn/start`（`data.turn`）；durable：会话日志 `turn/start`；会话日志另含 `conversation.turn_started`（由 `BotRemoteActionPlanner` 为直接用户动作写入） | 已映射；实时 turn/start 由 `BotChatModel.receive` 持有，durable 由 `BotProductionEventReader`/`BotSessionLogProjection` 提供 |
| `user.message` | DSH `user/message` 且 `data.role == "user"`；durable `conversation.user_message`（`BotDSHRemoteRuntime.appendConversation`） | 已映射；隐藏/注入消息须由调用方过滤（现有 projector 已过滤） |
| `model.delta` | durable：会话日志 `assistant/stream`，`data.channel` 缺省按 `text` 处理；ephemeral `model.delta` 类型已声明但当前无生产者；实时文本增量来自 `BotLiveFrame.textDelta`/`.streamStart`，不是 `assistant/stream` event | 映射已支持 event；**实时链路缺口**：第 3 波需从 `textDelta`/`streamStart` 合成 `model.delta`（`channel:"text"`）或直接驱动 `.streaming`/`.speaking` lifecycle |
| `tool.start` | DSH `tool/call`（`data.name`、`data.callId`、`data.arguments`）；durable `conversation.tool_call` | 已映射；`FishAction` 本身也走 `tool.start`，一次性反应叠加在 lifecycle 之上 |
| `approval.requested` | durable BotEvent `approval.requested`（`BotApprovalCoordinator.request`，含 `approvalID/action/detail/effects`） | 已映射；`BotChatModel.fishState` 另有 `pendingApprovalCount → .alerting` |
| `approval.resolved` | durable BotEvent `approval.decided`（`data.decision` = allowOnce/deny/always，`status`）；timeout/cancel 也是 `approval.decided` | 已映射；`isApprovalDenied` 读取 `decision`/`resolution`/`denied` |
| `task.done` ok | durable BotEvent `task.settled`（`data.status` = completed） | 已映射；`BotMCPRuntime`/`BotDSHRemoteRuntime` 写入 |
| `task.done` error | durable BotEvent `task.settled`（`status` = failed/stopped/timeout 等） | 已映射；同上 |
| `error` | **当前无生产者**。`BotEventEnvelopeCodec` 允许 `runtime.exited`，但仓库内没有写入点；DSH `turn/end` 的失败原因在 `data.reason.kind/error` | 映射器支持 `error`/`conversation.error`/`runtime.error`；**第 3 波接线**：要么在 `turn/end` 失败时额外发 ephemeral `error`，要么在 App 侧把失败 turn/end 映射为 `error`（本单元不改会话事件语义） |
| `memory.written` | durable BotEvent `memory.written`（`data.scope` = agent/user） | 已映射；`SQLiteBotMemoryFactStore.writtenEvent` 写入 |
| `turn.end` | 实时 DSH `turn/end`（`data.reason`）；durable 会话日志 `turn/end`；`conversation.turn_ended` 类型已声明但当前无生产者 | 已映射；实时/日志来源足够，durable alias 是备用 |
| `watchdog.flagged` | durable BotEvent `watchdog.flagged`（`data.check/unitKind/unitId/evidence`） | 已映射；`BotWatchdogMonitor` 写入 |

Lifecycle（非 director 事件）来源：

| lifecycle | 手机端真实来源 | 缺口 |
| --- | --- | --- |
| `thinking` | 实时 `turn/start`；durable `BotRuntimePresentationFactory` 从 `turn/start` 推导；无 tool/stream 时 `activity` 默认 thinking | 无 |
| `working` | `tool/call` → `tool.start`；`BotRuntimePresentationFactory.activity` 从最后一个 `tool/call` 推导 | 无 |
| `streaming` | durable `assistant/stream`；App 的 `isReplyStreaming`/`streamingText` 已有真实文本增量 | **实时 fishState 缺口**：`BotRuntimePresentationFactory.live` 只收到 `.event` 帧，`textDelta` 不进入 director；第 3 波需按上表合成 `model.delta` 或直接设置生命周期 |
| `alerting` | `BotChatModel.pendingApprovalCount > 0`；`approval.requested` 也映射 alerting | 无 |
| `sleeping` | `BotChatModel.idleSleeping`：`turn/end` 后 60 s 无输入；用户输入/发送/点按即醒 | 无 |
| `idle` | `turn.end` / `BotFishDirector.setLifecycle(.idle)` | 无 |

## 4. 兼容性与发布

| Producer → Consumer | 支持／拒绝方式及理由 |
| --- | --- |
| old → new | 旧 App/旧 Worker 不宣告 `FishAction`，不会调用；旧 golden/旧 durable 数据不变。`BotToolCatalog.allDefinitions` 新增名字只在手机端目录出现，上游 `tool-catalog.json`/schema 未改。 |
| new → old | 旧客户端收到新增工具名会按未知工具或忽略；没有新增 wire frame/event，因此不存在旧 decoder 解析失败。新工具调用若在旧运行时执行，会得到 `unknown_tool`/工具不可用，而不是状态损坏。 |
| new → new | `FishAction` 的模型调用由 DSH 会话日志的 `tool/call` 记录，UI 与 durable 重放都能从同一条事件解析 reaction；`BotFishReaction` 的 id 取工具调用 id，重复渲染不会重复播放。没有 envelope 版本或迁移。 |
| persisted old data → new／rollback | 头像只消费既有 BotEvent/DSH session event，不新增磁盘字段；回滚 App 后最多回到 lifecycle-only 渲染，`FishAction` tool row 仍按旧行为处理。 |

- 版本决定：P26 additive tool + phone golden；P27 additive hidden-tool rule；P09 additive optional view parameter and gallery section。不升协议版本、不新增未知值规则以外的 wire 面。
- 已知差异：手机端过程行列表由 App 的 `BotTurnProcessProjector` 生成（不在本单元路径），本单元只提供 `BotDisplayContract.isToolCallVisible(named:)`；第 3 波必须在 `BotTurnProcessProjector.isProcessTool` 调用该 helper，否则 FishAction 会以普通工具行出现在「已完成」过程卡。当前 `BotTurnProcessProjector` 未改。

## 5. 分工与证据

- Swift library：`Sources/PhoneDSHBot/MCP/BotToolCatalog.swift`、`Sources/PhoneDSHBot/Authz/BotToolEffects.swift`（既有 FishAction UI label，未改语义）、`Sources/PhoneDSHBot/Rows/BotDisplayContract.swift`、`Sources/PhoneDSHBot/Avatar/BotFishReactions.swift`、`Sources/PhoneDSHBot/Avatar/BotFishEventMapping.swift`、`Sources/PhoneDSHBot/Avatar/BotFishDirector.swift`（未改）。
- Swift tests：`Tests/PhoneDSHBotTests/{Avatar,MCP,Authz,Rows}/**`；`Tests/PhoneDSHBotTests/Team/BotTeamToolsTests.swift` 只把 phone 目录总数 19→20（新增目录成员的直接相关断言）。
- Worker：`plugins/bot-runtime/src/approval-gate.ts` 的 `AUTO_TOOLS` 加 `FishAction`；`plugins/tests/bot-identity-approval.test.ts` 新增自动策略用例。prompt 文件不在本单元修改。
- App：`examples/probe-app/PhoneDSHProbe/Bot/Fish/{BotFishView,BotFishEngine,BotFishGallery}.swift`。`BotRuntimeComposition`、`BotChatModel`、`BotProductionServices`、`BotLiveTurn` 不在本单元路径，第 3 波接线见 §6。
- Shared fixtures：`spec/bot/v1/golden/tool-catalog.phone.json` 的 `fish` 增量；`spec/bot/v1/golden/tool-effects.phone.json` 的 `FishAction` entry。上游 golden/schema 未改；`fish-director.json` 未改，mapping 用 Swift 表驱动测试覆盖每个事件。
- 未改：`patch.yml`、提示词文件、`Bot/Fish/**` 以外的 app 文件、上游私有源码。

## 6. 第 3 波 App 接线接口

```swift
// 1) 注册执行面（BotRuntimeComposition 初始化后）：
await runtime.registerFishActionTool()

// 2) 解析模型调用（实时 DSH tool/call 或 durable conversation.tool_call）：
let call = BotFishToolCall(sessionEvent: sessionEvent)
    ?? BotFishToolCall(botEvent: botEvent)
if let reaction = call.flatMap({ BotFishReaction.reaction(from: $0) }) {
    model.reaction = reaction       // 该 Bot 的所有 BotFishView 传 reaction:
}

// 3) 事件 → director（替换手写 switch，复用既有 BotFishDirector）：
let mapped = BotFishDirectorEventMapper.event(from: .dshSession(sessionEvent))
    ?? BotFishDirectorEventMapper.event(from: .botEvent(botEvent))
if let mapped {
    let result = BotFishDirector.reduce(current, event: mapped)
    // current = result.directorState; apply(result.command) to lifecycle overlay
}

// 4) 显示过滤（BotTurnProcessProjector.isProcessTool）：
guard BotDisplayContract.isToolCallVisible(named: item.toolName ?? "") else { return false }
```

公开签名：

```swift
public enum BotFishReactionVocabulary {
    public static let actions: [String]
    public static let expressions: [String]
    public static let reactions: [String]
    public static let expressionDurationMs: Int64
    public static func kind(for name: String) -> BotFishReactionKind?
    public static func durationMs(for name: String) -> Int64?
    public static func isValid(_ name: String) -> Bool
}

public enum BotFishReactionKind: String, Codable, Sendable { case action, expression }

public struct BotFishReaction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let botID: String?
    public let kind: BotFishReactionKind
    public let name: String
    public let startedAt: Int64
    public let durationMs: Int64
    public var endsAt: Int64 { get }
    public var lifecycle: BotFishLifecycle? { get }
    public static func reaction(from toolCall: BotFishToolCall, now: Int64? = nil) -> BotFishReaction?
}

public struct BotFishToolCall: Sendable, Equatable {
    public init(id: String = "", botID: String? = nil, name: String,
                arguments: BotJSONValue = .object([:]), time: Int64 = 0)
    public init?(sessionEvent: BotDSHSessionEvent)
    public init?(botEvent: BotEvent)
}

public struct BotFishActionTool: BotTeamToolHandling {
    public static let toolName = "FishAction"
    public init()
    public nonisolated func handles(_ toolName: String) -> Bool
    public func execute(name: String, arguments: BotJSONValue,
                        principal: BotGatewayPrincipal,
                        context: BotMCPRequestContext) async -> BotMCPCallResult
}

public extension BotMCPRuntime {
    func registerFishActionTool() async
}

public enum BotFishEventSource: Sendable, Equatable {
    case dshSession(BotDSHSessionEvent)
    case botEvent(BotEvent)
}

public enum BotFishDirectorEventMapper {
    public static func event(from event: BotDSHSessionEvent) -> BotFishEvent?
    public static func event(from event: BotEvent) -> BotFishEvent?
    public static func event(from source: BotFishEventSource) -> BotFishEvent?
    public static func lifecycle(from event: BotDSHSessionEvent) -> BotFishLifecycle?
    public static func lifecycle(from event: BotEvent) -> BotFishLifecycle?
}

public enum BotDisplayContract {
    public static let hiddenToolNames: Set<String>
    public static func isToolCallVisible(named name: String) -> Bool
    public static func visibleToolCallNames(_ names: [String]) -> [String]
}

struct BotFishView: View {   // App 内类型；公共初始签名如下
    init(state: BotFishLifecycle, size: CGFloat,
         appearance: BotFishAppearance = .classic,
         crowned: Bool = false,
         still: Bool = false, allowsPoke: Bool = false,
         reaction: BotFishReaction? = nil)
}
```

## 7. 实测记录

本单元在 base `b4c3cca0901b6c08ad0c39a4012a8296a1070231` 的工作树（分支 `bm/fish-react`）执行，未提交。

- `swift test --disable-sandbox --filter PhoneDSHBotTests` → PASS（374 tests，0 failures）。
- `cd plugins && npm run typecheck` → PASS；`node scripts/run-tests.mjs "tests/bot-*.test.ts"` → PASS（44 tests，43 pass，1 skip）。
- `python3 spec/bot/v1/tools/validate_vectors.py` → PASS（上游 schema/golden；phone fish delta 由 Swift 真实分类器/目录测试驱动）。
- `cd examples/probe-app && xcodegen generate && xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-fish-dd build CODE_SIGNING_ALLOWED=NO`：裸命令在容器内因 SwiftPM 用户缓存不可写失败；加 `CFFIXED_USER_HOME=/tmp/bm-fish-home OTHER_SWIFT_FLAGS='-disable-sandbox'`（隔离本机沙箱的 manifest/macro 子进程限制）后 → BUILD SUCCEEDED。
- `bash scripts/ci/bot-ui/capture.sh --appearance light,dark --out /tmp/bm-fish-shots --device 6E194129-E686-4402-99BC-0C721B421A51`：capture app 构建成功，`PhoneDSHBotUICaptureUITests-Runner` 启动失败（`Pseudo Terminal Setup Error` / `Operation not permitted`）→ UI 测试 NOT_RUN。按任务允许的 fallback，用同一 capture app `simctl launch -BotUIFixture gallery -BotUIAppearance light|dark` 截图；`/tmp/bm-fish-shots/{light,dark}/gallery.png` 已人工检查 reactions 24 格（6×4）姿态与头朝上、light/dark 两种外观。
- `xcodebuild` 的 `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` 只用于绕过容器内嵌套 `sandbox-exec`；未改任何生产构建设置或 project.yml。
