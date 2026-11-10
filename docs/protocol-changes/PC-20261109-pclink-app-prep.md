# PCLink D1b — iOS App 为 PC 工作区做准备（库层下沉 + wire 形状修复 + 后端抽象骨架）

```yaml
change: PC-20261109-pclink-app-prep
contracts: [P09, P14]
status: implemented
breaking: false
version_decision: 无 wire/版本变更；App 的 DSH Remote 调用形状对齐既有 DSH 0.2.2-rc.1 P14 契约
base: 627aed351484f98fc9e29c4f238937e6c818c8cf
contract_revision: DSH 0.2.2-rc.1 @ 66491b05；PCLink v1 freeze @ pclink-v1（只读）；本单不改任何契约文件
```

> 本单是 D 阶段（iOS App 接 PC 后端）之前的准备单元：不接 PC、不加 UI。
> 三件事：修正 App 的 wire 参数形状；把渲染投影/解码下沉到 ProbeKit；加
> `WorkspaceBackend` 骨架并只启用手机实现。

## 0. 交接证据（AGENTS.md §3.5）

```text
Base / head:        627aed351484f98fc9e29c4f238937e6c818c8cf / 工作区改动（未 commit）
Protocol impact:    P09; P14; P26; P25: none — no event envelope/schema/durable event change, only the existing ephemeral runtime.stderr diagnostic; P06: none — backend seam only, no harness/event format; P13: none — no plugin contract change; P16: none — no Worker env/launch change; P18: none — persisted key/format unchanged (inventory + D2 plan); P24: none — project.yml source membership only, package locks restored; P27: none — no Bot row/user-action contract change
Contract revision:  DSH 0.2.2-rc.1 @ 66491b05；PCLink v1 @ pclink-v1（只读）；未改契约文件
Changed files:      examples/probe-app/PhoneDSHProbe/**（wire 修复、backend 接线、电话固定标注）
                    examples/probe-app/ProbeKit/{Transcript,Management,Backends}/**（新）
                    examples/probe-app/PhoneDSHSimTests/{ProbeKitHistoryTests,MessageFeedbackTests}.swift
                    Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift（session/list + 诊断）
                    Tests/PhoneDSHBotTests/MCP/{BotDSHRemoteRuntimeTests,BotRemoteTestSupport}.swift
                    examples/probe-app/project.yml（移出已搬移文件的 source membership）
                    spec/ui/v1/pages/*.json、spec/ui/v1/tokens.json（机械 provenance）
                    docs/protocol-changes/PC-20261109-pclink-app-prep.md（本单）
Status per end:     iOS App/ProbeKit: implemented
                    PC backend (D2): not started
                    Android / Harmony / relay: not started
Commands → result:  xcodebuild build (adapted, r2 final) → PASS
                    xcodebuild test → FAIL (host pty); simctl spawn xctest →
                    PASS 57 tests (includes MessageFeedbackTests 4) and PASS 13
                    scene-phase/audio-lease tests
                    swift build --disable-sandbox → PASS
                    swift test --disable-sandbox --filter PhoneDSHBotTests → PASS 290 tests
                    extract_ios_pages --check → PASS
                    page_structure_check → FAIL (same 12 pre-existing ratchet only)
                    ui_check → PASS
                    r1 CI phone-spec → PASS; phone-cross-tree → PASS;
                    phone-p0-conformance → FAIL (only the same 12 ratchet rows; not rerun in r2)
Not verified:       real model reply (no credentials), live dsh web pin, real iPhone,
                    Android/Harmony, PC backend/relay, drawer touch injection,
                    live messageFeedback/put and goals/get against a real DSH
Remaining risks:    goals/get may wake the open session's agent (documented; only
                    current-session callers); retryableRequestIDs fingerprint not
                    backend-scoped; workspace/follow reconnect and PC cwd remain D2 work
```

## 1. 识别与角色

- **Trigger → 现状 → 期望**：方案 v2 §6.2、§12.2 第 4/5 条要求 D 阶段前先修 App
  的 DSH Remote 参数形状、把 `NativeTranscriptProjector`/`ChatItem`/管理解码/历史读取
  下沉到可复用库，并加 `WorkspaceBackend` 抽象，让 D2 能接入第二个后端。
- **Coordinator / contract owner**：本单不改契约；P09/P14 的 owning contract 与
  `PC-20261109-pclink-v1` freeze 仍由原 owner 维护。
- **Implementer**：iOS App/ProbeKit（本工作区 `feat/pclink-app-prep`）。
- **Owning contract / fixtures**：P09 `spec/ui/v1/**`；P14
  `Sources/PhoneDSH/ChannelDSHTransport.swift`（本单未改）。App 侧真实调用形状由
  DSH 0.2.2-rc.1 生成的 `typert.host.js` descriptor 与
  `spec/pclink/v1/endpoints.json`（pclink-a worktree，只读）对照。
- **受影响 producer/consumer**：iOS App/ProbeKit 调用方，以及 `PhoneDSHBot` 的
  MCP remote runtime（本轮只改它的 `session/list` 参数与失败诊断）；DSH pin、PCLink
  插件、relay、Android、Harmony 均未改。P14 的 owning source
  `Sources/PhoneDSH/ChannelDSHTransport.swift`、`spec/pclink/**`、`plugins/**`、
  `android/**`、`Package.swift` 未改。

## 2. 契约 delta

**P14（DSH Remote 调用形状）**：不新增字段、不新增版本、不改 mux 格式。只把 App 已经
在用的端点改成 DSH 0.2.2-rc.1 网关本来就要求的形状：

| 端点 | Before | After | 依据 |
| --- | --- | --- | --- |
| `session/list` | `args: {}` | `args: {"_request": {}}` | `session-controller/src/index.ts:274,279`；`gateway/src/index.ts:1636-1655` (`assertExactArguments`) |
| `session/follow` | `request.assistantStream: false` | 省略该成员（或 `true`） | `session-controller/src/types.ts:493`（`assistantStream?: true`）；`gateway/src/index.ts:1698`；生成 descriptor 为 `z.literal(true).optional()` |
| `goals/get` | `args: {"sessionId": ...}` | `args: {"agentId": ...}` | `goal/lib/typert.host.js`：`agentId` 是 scope/lookup wire 名；旧形状会 `gateway/arguments-invalid: unexpected "sessionId"; missing "agentId"` |
| `goals/pause`/`resume`/`complete` | `args: {"sessionId": ..., "ref": ...}` | `args: {"agentId": ..., "ref": ...}` | 同上 |
| `messageFeedback/put` | 参数直接平铺 `{sessionId,...}` | 包一层 `{"request": {...}}` | `message-feedback/lib/typert.host.js`：唯一 wire 参数是 `request` |

没有改 schema、golden、版本或错误码；DSH 对旧形状的拒绝行为保持不变。

Bot MCP remote runtime（`Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`）的
`remoteSessionCwd` 使用同一个 `session/list`，本轮也改为 `_request`；失败诊断写入
Bot journal 既有的 ephemeral `runtime.stderr` 类型，不新增 schema、durable event 或
wire 字段（P26；P25 无变化）。

**P09（UI 页面契约）**：搬移导致行号变化，只机械更新 provenance/anchor 与
line-derived id；没有新增/删除 action、section 或 state，`_baseline.json` 与
whitelist 未改。

**P13/P06/P18/P24/P25/P27**：无契约变化（见 §4.7 的 impact 声明与理由）。

自检（spec/README.md §5.1）：没有新增第二种表达、没有放宽/收紧两端都读的格式、
没有新增 enum 或错误码、没有删除/复用名称。App 只是把非法参数改为 pin 已定义的合法
参数。

## 3. 兼容性

| Producer → Consumer | 行为 |
| --- | --- |
| old App → new DSH | 保持原样：旧形状在 PC 网关和手机本地 Worker 网关都会失败（不是只有 PC 才失败）。 |
| new App → new DSH | 合法；本单新增的 strict-shape 单测覆盖 `_request`、省略 `assistantStream`、`agentId`、`request` 包装。 |
| new App → old DSH | DSH 0.2.2-rc.1 之前的网关同样接受这些字段（`request`/`agentId` 是既有 scope 语义）；本单没有改测试范围。 |
| 旧持久化数据 → 新代码 / 回滚 | 不改存储格式。`(BackendID, sessionID)` 键方案见 §4.6，留给 D2/P18。 |
| 页面契约 | 9 个 pages JSON 只有 `file`/`line`/`anchor`/line-derived `id`/`presentations.span` 变化；`tokens.json` 只有 `NativeMessageRows.swift` 等 4 个文件的 27 处 `file:line` +1。用规范化比较确认 labels/actions/sections 无语义变化。 |

版本决定：无。PCLink v1 freeze 明确不改 P14/P06/P09 消息；本单也只是调用方参数修正。

## 4. 实现与证据

### 4.1 Wire 形状修复清单（file:line 前后）

输入基线行号来自 base `627aed35`；After 为本工作区最终行号。

| # | Before | After | 说明 |
| --- | --- | --- | --- |
| 1 | `ChatModel.swift:1748` `session/list {}` | `ChatModel.swift:1815` `{"_request":{}}` | 后台恢复后的 running 探针 |
| 2 | `ChatModel.swift:2186` `session/list {}` | `ProbeKit/Transcript/SessionHistoryReader.swift:106`（`requireRunningState` 路径） | 已随历史读取下沉 |
| 3 | `ChatModel.swift:2193` `session/list {}` | `SessionHistoryReader.swift:115`（可选 running 探针） | 下沉 + 失败进 `diagnostics` |
| 4 | `DSHManagementModel.swift:189` `session/list {}` | `DSHManagementModel.swift:175` | 抽屉列表主路径；这个本来就是“会显示错误”的路径，不是被吞 |
| 5 | `ChatModel.swift:2143` `assistantStream:false` | `SessionHistoryReader.swift:183-189`（省略） | 历史 follow |
| 6 | `ChatModel.swift:2300` `assistantStream:false` | `SessionHistoryReader.swift:184`（`followCursor` 复用同一 opening） | 轨迹 cursor 探针 |
| 7 | `NativeDeviceSessionPage.swift:297` `assistantStream:false` | `NativeDeviceSessionPage.swift:289` → `SessionHistoryReader.followCursor` | 设备会话只读监视 |
| 8 | `DSHManagementModel.swift:524` `goals/get {sessionId}` | `DSHManagementModel.swift:516` `{agentId}` | 额外发现的真实 bug；原来 `try?` 吞掉。`goals/get` 会 `resolveAgent`，只允许对当前已打开会话调用（见 §4.2） |
| 9 | `DSHManagementModel.swift:633` `goals/{op} {sessionId,ref}` | `DSHManagementModel.swift:625` `{agentId,ref}` | 额外发现；错误进 activityErrors |
| 10 | `ChatModel.swift:2934` `messageFeedback/put` 平铺参数 | `ProbeKit/Management/MessageFeedbackClient.swift:44` `{"request": {...}}` | 额外发现；本轮同时检查业务 `ok` 与 version-conflict 重试 |
| 11 | `PhoneDSHSimTests/WorkerCapabilityTests.swift:145,152` `session/list {}` | 同文件 `:145,152` `{"_request":{}}` | 测试也驱动真实 phone Host，同一网关切法；不属于 App 产品调用 |
| 12 | `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:831` `session/list {}` + `catch {}` | `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:834` `{"_request":{}}` + ephemeral `runtime.stderr` 诊断 | 本轮允许修改 Sources；失败仍回退重建主会话 |

**其它端点的审计**：用 DSH pin 的 36 个 `lib/typert.host.js` descriptor（含
`packages/api/**` 之外的 schedule/goal/commands/agent-presets 等）核对 App 的 47 个
`call`/mux `endpoint` 调用点。除上表 11 处 App/测试调用外，其余参数的 top-level wire 名与 descriptor
一致（`request`/`agentId`/`childSessionId`/`ns`/`patch` 等），嵌套形状也与本次实际跑通的
路径一致。`workspaceFiles/stat` 只在注释中出现，App 未调用。

**本轮新增的 Sources 修复（#12）**：`BotDSHRemoteRuntime.remoteSessionCwd` 原来发送
`session/list {}` 并 `catch {}`，DSH 0.2.2-rc.1 会以 `arguments-invalid` 拒绝，
导致每次 `runtime.started` 缺 cwd 的恢复都静默回退到重建。现在改为
`{"_request":{}}`，失败把诊断写入 Bot journal 既有的 ephemeral `runtime.stderr`
缓冲；重建回退行为不变。`Sources/...:1052` 的 `assistantStream:true` 是合法的。

### 4.2 实际行为变化（本轮修订后真正生效）

修正 wire 参数并不只是“少报一次参数错误”。下列用户可见行为在本轮修订后
才真正生效：

| 行为 | 现在的真实行为 | 代码/测试 |
| --- | --- | --- |
| 打开会话时的 `turnRunning` | 打开/恢复会话时 `session/list {_request:{}}` 成功则以权威 `running` 为准；只有探针失败才回退到本页 `turn/start`/`turn/end` 推断 | `SessionHistoryReader.load` → `ChatModel.loadSessionHistory`；`ProbeKitHistoryTests.testLoadSendsGatewayLegalWireShapes...` |
| 后台恢复后的 running 探针 | `reconcileTurnStateAfterResume` 在 resume 后查询 `session/list`；`running=false` 且本地仍认为在跑时清空回合/队列状态，避免永远卡在“处理中” | `ChatModel.reconcileTurnStateAfterResume`；探针失败写 `chat-status.log` |
| 事件流重同步 | 中断后的 `synchronizeInterruptedSession` 要求 `session/list` 给出权威 running；拿不到就失败并保留“重新同步中”，不再用本页推断猜测 | `SessionHistoryReader.load(requireRunningState:)`；`ChatModel.synchronizeInterruptedSession` |
| 目标面板 | `goals/get {agentId}` 能读到目标；暂停/恢复/完成用 `{agentId,ref}`。**新副作用**：`goals/get` 会走 pin 的 `resolveAgent`，可能唤起该会话的 Agent；本 App 只在当前已打开会话（ChatPage 的 current-session 任务/作业与计划 sheet、由它打开的 SessionActivityPage）调用，列表页只用 `session/projections.values.goal` | `DSHManagementModel.refreshActivity`；`ChatPage` `.task(id: model.currentSessionID)` / `SessionActivityPage` |
| 反馈评分 | `messageFeedback/put` 现在检查业务 `ok`；`version-conflict` 用 `error.current.version` 重试一次，`target-not-found` 及其它业务失败走现有 `reportError`，不再把失败当成功 | `ProbeKit/Management/MessageFeedbackClient.swift`；`ChatModel.rateMessage`；`MessageFeedbackTests` |
| Bot 主会话 cwd 探测 | Bot runtime 的 `session/list` 改用 `_request` 形状；失败写入 Bot journal 既有的 ephemeral `runtime.stderr` 诊断，仍按原逻辑回退到重建主会话 | `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`；`BotDSHRemoteRuntimeTests` |

`requireRunningState` 的失败类型从 base 的 `PhoneDSHError.invalidResponse` 变为
`ProviderError.invalidResponse("session running state is unavailable")`。同一 pin 在
`DSHRemoteTransport` 层用 `ProviderError` 表达响应形状错误；已核对
`synchronizeInterruptedSession` 及所有调用方都只 `throws`/记日志，没有按
`PhoneDSHError` 类型匹配的分支，因此错误类型变化没有改变调用方行为。

### 4.3 原先吞错误的位置与处理

| 位置 | 原行为 | 现在 |
| --- | --- | --- |
| `ChatModel.reconcileTurnStateAfterResume` catch（base `:1757`） | 空 `catch`，running 探针失败无痕迹 | `ChatModel.swift:1830` `Self.appendDiagnostic("session/list resume probe failed: …")`；不改 UI |
| `ChatModel.loadSessionHistory` 的 `try? session/list`（base `:2193`） | 失败当 running=nil，无日志 | `SessionHistoryReader` 返回 `diagnostics`；`ChatModel.swift:2191-2206` 写 `chat-status.log` |
| `DSHManagementModel` `goals/get` 的 `try?`（base `:524`） | 目标读取失败静默显示“没有目标” | `DSHManagementModel.readOptional`（`:938`）记录 diagnostic，仍不改变页面文案 |
| `DSHManagementModel` goals mutation（base `:633`） | 参数错，`activityErrors` 显示错误 | 参数修正后正常；失败仍进 `activityErrors` |
| `messageFeedback/put`（base `:2934`） | 参数错，`reportError` 显示“反馈没有提交成功”；业务 `{ok:false}` 仍被当成功 | `MessageFeedbackClient` 检查 `ok` 并按 `version-conflict` 重试一次；其它失败仍走 `reportError` |
| `BotDSHRemoteRuntime.remoteSessionCwd`（`Sources/...:831-833`） | `session/list {}` + `catch {}` | 参数改为 `_request`；失败写 ephemeral `runtime.stderr` 诊断，返回 nil 的恢复策略不变 |

### 4.4 下沉到 ProbeKit 的类型与新位置

新增目录由 `project.yml` 的 `ProbeKit` 目录 glob 自动包含；没有新增 target，也没有复制
两份。App 侧旧文件已删除，App 与 `PhoneDSHSimTests` 都改为 `import ProbeKit`。

| 新位置 | 内容 |
| --- | --- |
| `ProbeKit/Transcript/NativeConversationModels.swift` | `ChatItem`（含 `Kind`）、`NativeToolState`、`NativeTokenUsage`、`NativeTurnUsage`、`NativeImageLimits`、`NativeSessionStats`、`NativeContextPressure`、`NativeContextBreakdown`、`NativeMessageAttachment`、`NativeChangedFile`、`NativeChangedFiles`；全部 public，显式 public init |
| `ProbeKit/Transcript/NativeTranscriptProjector.swift` | `NativeTranscriptProjector.items/restoring/inputReceipts/acceptInput/acknowledgeInput/changes/usage`；随文件下沉的 `nativeText`/`nativeJSON`/`nativePrettyJSON`（public） |
| `ProbeKit/Transcript/SessionHistoryReader.swift` | `SessionTurnFacts`、`SessionHistorySnapshot`、`SessionHistoryReader.load/followCursor/turnFacts/isTurnRunning`：follow snapshot + `session/page` 回翻 → 原始 records、cursor、`inputReceipts`、running 探针、诊断。只吃 `DSHRemoteTransport`，不碰 App singleton |
| `ProbeKit/Management/ManagementModels.swift` | `ManagedSession`、`ManagedWorkspace`、`ManagementDecoding.decodeSessions/decodeWorkspace`。title hint 与 Bot session 过滤是闭包参数，App 传 `SessionTitleHints`/`BotSessionRegistry`，库本身不依赖手机 Bot 策略 |
| `ProbeKit/Management/MessageFeedbackClient.swift` | `MessageFeedbackClient.rate` 与 `MessageFeedbackError`：解析 `messageFeedback/put` 的业务 `{ok,...}` envelope、按 `error.current.version` 做一次 compare-and-set 重试、把 `target-not-found`/其它失败作为 typed error 抛出。App 的 `ChatModel.rateMessage` 只负责 `reportError`；`PhoneDSHSimTests.MessageFeedbackTests` 用 fake transport 驱动同一实现 |

**刻意留在 App 的部分（行为不变）**：

- `ChatModel.transcriptItems` / `compactionMarkers` 与 `NativeCompaction`（compaction
  文案和折叠是渲染层行为）；`SessionHistoryReader` 只返回原始记录。
- `ChatModel.SessionHistory`（带 items 的呈现包装）、`SessionTitleHints`、
  `BotSessionRegistry` 过滤、`DeviceTranscriptProjector`（设备会话专用）。
- 因为这些留在 App，`NativeTranscriptProjector` 的 `items` 行为没有变化，仍由
  `transcriptItems` 在有 compaction checkpoint 时折叠。

### 4.5 `WorkspaceBackend` 接口

位置：`ProbeKit/Backends/WorkspaceBackend.swift`。理由：ProbeKit 已同时被 App 和
`PhoneDSHSimTests` 链接；协议不依赖 App singleton（传输/harness/生命周期都由闭包注入），
D2 的 PC 后端可以直接在 ProbeKit 或独立模块实现，不需要把 App target 变成库。

```swift
public enum BackendID: Hashable, Codable, Sendable {
    case phone
    case pc(machineId: String)
    public var storageScope: String   // "phone" / "pc:<machineId>"（D2 键规划用）
}

public struct BackendCapabilities: Equatable, Sendable {
    public var phoneOnlyEndpoints: Bool
    public var supportsHostLifecycle: Bool
    public var localFilePreview: Bool
}

@MainActor public protocol WorkspaceBackendLifecycle: AnyObject {
    var supportsHostPause: Bool { get }
    var supportsKeepAlive: Bool { get }
    func pause() async throws
    func resume() async throws
    func startKeepAlive() async throws
    func stopKeepAlive() async
}

@MainActor public protocol WorkspaceBackend: AnyObject {
    var id: BackendID { get }
    var displayName: String { get }
    var capabilities: BackendCapabilities { get }
    var lifecycle: any WorkspaceBackendLifecycle { get }
    func transport() async throws -> any DSHRemoteTransport
    func harness() async throws -> any AgentHarness
}
```

`PhoneWorkspaceBackend` 与 `PhoneWorkspaceBackendLifecycle` 也放在 ProbeKit，由 App 注入
闭包包住现有路径：

- transport → `ChatModel.host.makeTransport()`；
- harness → 复用 `ChatModel.harness` 缓存，否则 `host.harness()`；
- lifecycle → App 的 `ChatModel.parkHost`/`resumeHost`，不直接调 `host.park()/resume()`：
  `parked`、`hostLifecycleTransition`、transition watchdog、`endBackgroundTask()`、
  `reconcileTurnStateAfterResume()` 和 scenePhase 的排队语义仍由 App 持有唯一状态源；
- keep-alive → App 的 `beginKeepAlive`/`endKeepAlive` helper，与 `scenePhaseChanged`
  共用 `keepingAlive`、`SilentAudioKeepAlive`、background heartbeat 和 background task；
  `scenePhaseChanged` 现有分支行为不变。本单没有任何调用方切换 scenePhase 到 lifecycle；
  D2 再把 `scenePhaseChanged` 接过来。

接线：

- `ChatModel.shared` 保留，文档标注为 phone backend 的实例；新增
  `ChatModel.workspaceBackend`（当前恒为 `PhoneWorkspaceBackend`，`id == .phone`）。
- `ChatModel.transportForManagement()` 改为 `workspaceBackend.transport()`；78 处
  `ChatModel.shared` 未动。
- `ChatModel.openManagedSession` 的 harness 获取改为 `workspaceBackend.harness()`。
- `DSHManagementModel` 的 4 处 transport 获取改为
  `ChatModel.shared.workspaceBackend.transport()`。
- `DSHManagementModel` 的 `session/list` 与 App 的其它 DSH 调用没有走新的 PC 分支；
  本单只有 `.phone`。

**显式标注为固定在手机后端的部分**（注释，不改行为）：

- `ChatModel.botRuntime` / Bot runtime（PHONE-ONLY）；
- `DeviceTaskManager.swift` 顶部、`NativeDeviceSessionPage.swift` 顶部（设备任务/设备会话）；
- `MCPSettingsModel.swift`、`MCPSettingsPage.swift`、`NativeAgentPresetsPage.swift`、
  `NativeConfigurationModel.swift`、`ModelProviderSettingsPage.swift` 顶部（v1 设置页固定手机）；
- `DSHManagementModel` 的 `phone/createSchedule` 与 `phone/listTools` 调用点。

### 4.6 裸 `sessionID` 键清单与 D2 改造方案（本单不改存储）

| # | 存储 | 位置 | 键/形状 |
| --- | --- | --- | --- |
| 1 | UserDefaults `chat.dsh.currentSessionID` | `ChatModel.swift:352`（读 `:1370`、`:2929`；写 `:1381`、`:1495`） | 单个裸 sessionID |
| 2 | UserDefaults `chat.drafts.v1` | `ChatPage.swift:36`；key 计算 `:153` | `[sessionKey: draft]`，`sessionKey = currentSessionID ?? "new"` |
| 3 | UserDefaults `phone-dsh.session.title-hints` | `DSHManagementModel.swift:1048` | `[sessionID: title]` |
| 4 | 文件 `Documents/.../transcript-snapshots/<sessionID>.json` | `ChatModel.swift:2882-2887`、`:2954`、`:2929-2930` | 文件名裸 sessionID |
| 5 | UserDefaults `phoneDSH.botSession.registry.v1` | `BotSessionRegistry.swift:26` | `[sessionID]`（Bot 私有；手机固定） |
| 6 | UserDefaults `tonoteam.deviceSessions.v1` | `ProbeKit/Devices/DeviceSessionMapping.swift:49` | `[DeviceSessionMapping]`，含 `sessionID`（手机固定） |
| 7 | 文件 `.../materialized/home/sessions/<sessionID>/session.v*.jsonl` | `Bot/BotProductionServices.swift:163-174` | Bot 持久会话日志（手机固定） |
| 8 | 通知 | `ProbeKit/Bot/Notifications/BotUserNotificationDelivery.swift:43-50` | `UNNotificationRequest.identifier` 由调用方给；`userInfo["deepLink"]`；当前 App 未接生产构造器 |
| 9 | Deeplink | `Bot/BotUIModels.swift:484-496` | `phonedsh://bot/<botID>/row/<rowID>`（botID，手机 Bot；无持久化 sessionID 键） |
| 10 | UserDefaults `phone-dsh.sidebar.collapsed-workspaces` | `HomeDrawer.swift:21`、`SessionsPage.swift:115` | workspaceID 数组（相邻，非 sessionID；D2 同样要加 backend 维度） |
| 11 | UserDefaults `chat.dsh.retryableRequestIDs` | `ChatModel.swift:353`、`:3241-...` | 内容 fingerprint → requestID；**不含 sessionID/backend**，同文本跨后端会复用同一 requestId（见风险） |

**D2 键改造方案**（本单不实施；由 P18 变更单冻结）：

1. 定义 `SessionStorageKey { backend: BackendID, sessionID: String }`，编码为
   `<backend.storageScope>|<sessionID>`（sessionID 本身由 DSH 产生，不含 `|`）；
   文件路径用 `transcript-snapshots/<scope>/<sessionID>.json`。
2. `currentSessionID` 改为 per-backend：保留旧 `chat.dsh.currentSessionID` 作为 phone 的
   读回退，新写 `chat.dsh.currentSession.<scope>`；P18 迁移旧值到 `phone`。
3. drafts/title hints 改成两层字典或给 key 加 scope；旧一层字典只迁移到 `phone`。
4. bot registry、device mapping、bot session log 保持无 backend（只属于 phone）；
   若 D2 在 PC 上也有 Bot，则另起 scope。
5. 通知 identifier/deeplink 在生成时带 `BackendID.storageScope`；当前没有生产通知构造，
   先记录约定。
6. collapsed workspaces 改成 `(scope, workspaceID)`；deep link 的 botID 保持 phone-only。
7. `chat.dsh.retryableRequestIDs` 的 fingerprint 加入 `backend.storageScope` 和 sessionID，
   避免手机/PC 同文本复用同一 requestId。
8. 迁移/回滚：旧数据永远可读；新键写失败时回退旧键只对 phone；P18 需给出迁移审计和
   回滚路径。影响面：ChatModel/DSHManagementModel/ChatPage/BotSessionRegistry/
   DeviceSessionMapping（约 11 个存储点，见上表）。

### 4.7 Protocol impact 声明

规范声明行见 §0 的交接证据。分项理由：

```text
P09; P14; P26; P25: none — no event envelope/schema/durable event change, the new failure diagnostic reuses the existing ephemeral `runtime.stderr` type; P06: none — backend seam only, no harness/event format or semantics change; P13: none — App still consumes existing phone/* Remote shapes, no plugin contract change; P16: none — no PDSH_* environment, Worker URL parameter or boot frame change; P18: none — no UserDefaults/file key format change (inventory + D2 plan only); P24: none — project.yml only adjusts source membership of moved files, no package/lock change; P27: none — no Bot row/user-action/projection contract change.
```

P26 的具体 delta：Bot MCP remote runtime 的 `remoteSessionCwd` 把 `session/list`
从 `{}` 改为 `{"_request":{}}`（`session/list argument shape`），失败诊断写既有
ephemeral `runtime.stderr`。P14 的 App 侧 delta 见 §2 表。

### 4.8 验证命令与结果（如实）

环境：Xcode 26.5（17F42）、iOS 26.5 模拟器 `pclink-iPhone17Pro`
（`620D518D-D125-4154-B1B7-32A65327482B`）、macOS 宿主沙箱。宿主沙箱禁止
SwiftPM 写 `~/Library/Caches`、禁止 pty，并让嵌套 `sandbox-exec` 失败；因此部分命令
需要 `CFFIXED_USER_HOME=/tmp/pclink-d1b-home`、`OTHER_SWIFT_FLAGS=-disable-sandbox`
或改用 `simctl spawn` 的 XCTest agent。下文的 **ADAPTED** 都指这些环境适配，不是
产品代码差异。

```bash
# 1. 生成工程
cd examples/probe-app && xcodegen generate

# 2. 用户要求原样命令（宿主沙箱 -> exit 74）
xcodebuild -scheme PhoneDSHProbe \
  -destination 'platform=iOS Simulator,id=620D518D-D125-4154-B1B7-32A65327482B' \
  -derivedDataPath /tmp/pclink-d1b-dd build CODE_SIGNING_ALLOWED=NO

# 3. ADAPTED 最终 App build（PASS）
CFFIXED_USER_HOME=/tmp/pclink-d1b-home xcodebuild -scheme PhoneDSHProbe \
  -destination 'platform=iOS Simulator,id=620D518D-D125-4154-B1B7-32A65327482B' \
  -derivedDataPath /tmp/pclink-d1b-dd build CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'

# 4. 用户要求的 -only-testing 选择（pty 被宿主禁止，xcodebuild 未启动 runner）
CFFIXED_USER_HOME=/tmp/pclink-d1b-home xcodebuild test -scheme PhoneDSHSim \
  -destination 'platform=iOS Simulator,id=620D518D-D125-4154-B1B7-32A65327482B' \
  -derivedDataPath /tmp/pclink-d1b-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  -only-testing:PhoneDSHSimTests/ProbeKitHistoryTests \
  -only-testing:PhoneDSHSimTests/ProbeKitManagementTests

# 5. ADAPTED 同一个 XCTest bundle，经 simctl spawn（PASS 7 tests）
PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
PRODUCTS=/tmp/pclink-d1b-dd/Build/Products/Debug-iphonesimulator
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$PRODUCTS:$PLATFORM/Developer/Library/Frameworks" \
SIMCTL_CHILD_DYLD_LIBRARY_PATH="$PRODUCTS:$PLATFORM/Developer/usr/lib" \
SIMCTL_CHILD_OBJC_PRINT_DUPLICATE_CLASSES=NO \
  xcrun simctl spawn 620D518D-D125-4154-B1B7-32A65327482B \
  "$PLATFORM/Developer/Library/Xcode/Agents/xctest" \
  -XCTest PhoneDSHSimTests.ProbeKitHistoryTests,PhoneDSHSimTests.ProbeKitManagementTests \
  "$PRODUCTS/PhoneDSHSimTests.xctest"

# 6. ADAPTED 最终合并 run（PASS 53 tests；同一 -XCTest 机制）：
#    ProbeKitHistoryTests, ProbeKitManagementTests, ProbeKitBackendTests,
#    ChatInputRecoveryTests, NativeChatPresentationTests, ChatWorkflowTests,
#    ChatEventPumpTests, ComposerQueueTests。

# 7. 页面契约 / UI token
python3 -B spec/ui/v1/tools/extract_ios_pages.py --root . --check
python3 -B spec/ui/v1/tools/page_structure_check.py --root . \
  --baseline spec/ui/v1/pages/_baseline.json
python3 -B spec/ui/v1/tools/ui_check.py --root .

# 8. 必需 CI
CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) \
  bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance

# 9. SwiftPM（.build 从别的 worktree 克隆，先清 ModuleCache）
swift build --disable-sandbox
rm -rf .build/arm64-apple-macosx/debug/ModuleCache   # 仅构建产物
swift build --disable-sandbox                        # PASS: Build complete! (34.58s)
```

| 命令 | 结果 | 证据 |
| --- | --- | --- |
| `cd examples/probe-app && xcodegen generate` | PASS | 生成成功 |
| 用户给定的 `xcodebuild ... build CODE_SIGNING_ALLOWED=NO`（原样） | **FAIL (exit 74)**：SwiftPM manifest 诊断文件写入 `~/Library/Caches/...` 被沙箱拒绝 | `/tmp/pclink-d1b-baseline-build.log` |
| ADAPTED `CFFIXED_USER_HOME=/tmp/pclink-d1b-home xcodebuild ... build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` | **PASS**：`** BUILD SUCCEEDED **`，0 error（最终 App build 以此命令复跑） | `/tmp/pclink-d1b-build-final2.log` |
| `xcodebuild test -scheme PhoneDSHSim ... -only-testing:…` | **FAIL**：`Pseudo Terminal Setup Error` / Operation not permitted（宿主禁止 pty，测试 runner 未启动） | `/tmp/pclink-d1b-test-probekit2.log` |
| ADAPTED `simctl spawn <UDID> <iPhoneSimulator.platform>/Developer/Library/Xcode/Agents/xctest -XCTest PhoneDSHSimTests.ProbeKitHistoryTests,PhoneDSHSimTests.ProbeKitManagementTests <built .xctest>` | **PASS**：7 tests, 0 failures | `/tmp/pclink-d1b-xctest-probekit5.log` |
| ADAPTED 同上，`-XCTest PhoneDSHSimTests.ChatInputRecoveryTests,PhoneDSHSimTests.NativeChatPresentationTests,PhoneDSHSimTests.ChatWorkflowTests,PhoneDSHSimTests.ChatEventPumpTests,PhoneDSHSimTests.ComposerQueueTests` | **PASS**：45 tests, 0 failures | `/tmp/pclink-d1b-xctest-related.log` |
| ADAPTED 最终合并 run（ProbeKitHistory/Management/Backend + 上述 45 个相关类） | **PASS**：53 tests, 0 failures | `/tmp/pclink-d1b-xctest-final3.log` |
| `python3 -B spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS**（`contracts up to date`） | 终端输出 |
| `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (12)**：与 base 627aed35 完全相同的既有棘轮，无新增 | 终端输出 |
| `python3 -B spec/ui/v1/tools/ui_check.py --root .` | **PASS**（provenance 修正后） | 终端输出 |
| `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance` | phone-spec **PASS**；phone-cross-tree **PASS**；phone-p0-conformance **FAIL**，唯一失败是上述 12 处既有 page-structure 棘轮（其它 p0 子树全 PASS） | `/tmp/pclink-d1b-ci-check4.log` |
| `swift build --disable-sandbox`（首次） | **FAIL**：`.build` 是从 `wal-recovery` 克隆的，ModuleCache 记录了旧绝对路径（p0 spike §0.1 同款） | `/tmp/pclink-d1b-swift-build.log` |
| `rm -rf .build/arm64-apple-macosx/debug/ModuleCache && swift build --disable-sandbox` | **PASS**：`Build complete! (34.58s)` | `/tmp/pclink-d1b-swift-build2.log` |

#### r2 复跑（代码审查修订后）

| 命令 | 结果 | 证据 |
| --- | --- | --- |
| `cd examples/probe-app && xcodegen generate` | PASS | 生成成功 |
| ADAPTED `CFFIXED_USER_HOME=/tmp/pclink-d1b-home xcodebuild -scheme PhoneDSHProbe ... build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` | **PASS**：`** BUILD SUCCEEDED **`，0 error；`ChatModel.swift` 与 `MessageFeedbackClient.swift` 无新增 warning | `/tmp/pclink-d1b-build-r2b.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHSim ... build-for-testing CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` | **PASS**：`** TEST BUILD SUCCEEDED **` | `/tmp/pclink-d1b-buildtests-r2.log` |
| ADAPTED `simctl spawn ... xctest -XCTest PhoneDSHSimTests.ProbeKitHistoryTests,PhoneDSHSimTests.ProbeKitManagementTests,PhoneDSHSimTests.ProbeKitBackendTests,PhoneDSHSimTests.MessageFeedbackTests,PhoneDSHSimTests.ChatInputRecoveryTests,PhoneDSHSimTests.NativeChatPresentationTests,PhoneDSHSimTests.ChatWorkflowTests,PhoneDSHSimTests.ChatEventPumpTests,PhoneDSHSimTests.ComposerQueueTests <built .xctest>` | **PASS**：57 tests, 0 failures（含新增 `MessageFeedbackTests` 4 个） | `/tmp/pclink-d1b-xctest-r2.log` |
| ADAPTED `simctl spawn ... xctest -XCTest PhoneDSHSimTests.ProbeScenePhaseForwardingTests,PhoneDSHSimTests.PhoneAudioSessionLeaseTests <built .xctest>` | **PASS**：13 tests, 0 failures（scenePhase/keep-alive 行为回归） | `/tmp/pclink-d1b-xctest-scene-r2.log` |
| `swift build --disable-sandbox`（清理 `.build/arm64-apple-macosx/debug/ModuleCache` 后） | **PASS**：`Build complete! (11.33s)` | `/tmp/pclink-d1b-swift-build-r2.log` |
| `swift test --disable-sandbox --filter PhoneDSHBotTests` | **PASS**：290 tests, 0 failures；新增 `testSessionListCwdLookupFailureIsLoggedAndRebuilds` 与更新后的 `testLegacyRuntimeStartedWithoutCwdLooksUpTheSessionCwd` 均通过 | `/tmp/pclink-d1b-swift-test-r2.log` |
| `python3 -B spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS**（`contracts up to date`） | 终端输出 |
| `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (12)**：与 base 627aed35 相同的既有棘轮，无新增 | `/tmp/pclink-d1b-page-structure-r2.log` |
| `python3 -B spec/ui/v1/tools/ui_check.py --root .` | **PASS** | `/tmp/pclink-d1b-ui-check-r2.log` |
| `xcodebuild test -scheme PhoneDSHSim ...` | **NOT_RUN (r2)**：沿用 r1 的宿主 pty 限制；用上面的 `build-for-testing` + `simctl spawn` 跑同一 bundle | — |

### 4.9 模拟器冒烟测试

安装并启动真实 App（`/tmp/pclink-d1b-dd/Build/Products/Debug-iphonesimulator/PhoneDSHProbe.app`），
宿主机无模型凭据；`PDSH_CHAT_AUTOPROMPT` 发送链路实测：

- list：sessions sheet 显示「手机工作区 · 1 个会话」和「新建会话」；
- new：清空 `chat.dsh.currentSessionID` 后冷启动，host 日志出现新的
  `Session created: session-0a3404f3-...`（与 `newSession()` 同一路径）；
- send：`phase=prompt-rpc-start` → `phase=prompt-rpc-accepted`（`delivered=true`），
  随后 turn 以 `no credential is configured for the upstream host` 失败；助手回复
  **NOT_RUN**（没有真实模型凭据）；
- 历史：把当前 session 切回旧 session 后冷启动，`Session resumed` + 历史行（多轮
  retry 与 `turn/end` error）正常显示。
- 抽屉：宿主沙箱没有 pty/辅助功能，无法注入触摸；使用 App 自带的
  `PDSH_DEBUG_SHEET=sessions` 打开生产 `SessionsPage`（抽屉列表同一数据面）截图；
  抽屉本身只截到入口按钮。未把这个限制升级成“抽屉已点开”的结论。
- 新建会话是走 `newSession()` 的同一数据路径（清空 `chat.dsh.currentSessionID`
  后冷启动）验证，不是点击 UI 上的「新建会话」按钮；按钮本身在
  `04-sessions-after-new.png` 中可见。

截图：

- `/tmp/pclink-d1b-shots/01-launch.png`（启动、host ready）
- `/tmp/pclink-d1b-shots/03-sessions-sheet.png`（会话列表）
- `/tmp/pclink-d1b-shots/04-sessions-after-new.png`（新建后的 2 个会话）
- `/tmp/pclink-d1b-shots/05-history-old-session.png`（切回旧会话后的历史）

### 4.10 未验证 / 剩余风险

- **NOT_RUN**：真实模型回复（无凭据；发送 RPC 已接受，随后 turn 以
  `no credential is configured for the upstream host` 失败）；真实 `dsh web` 的 live
  pin 兼容回归（本单用 strict descriptor + fake transport 单测；p0 spike 的 live 证据
  仍有效但不属于本单）。
- **NOT_RUN**：真实 iPhone/真机、Android、PC 后端、relay、`workspace/follow` 重连。
- `goals/get` 会 `resolveAgent` 并可能唤起当前会话 Agent；本轮已确认所有调用点都是
  当前已打开会话（ChatPage/SessionActivityPage），列表页不要改用该调用。
- `messageFeedback/put` 的 ok/version-conflict/target-not-found 分支用 fake transport
  单测；真实 DSH 上的反馈写入仍未跑（无凭据/未接 PC）。
- Bot `runtime.stderr` 诊断当前只进 ephemeral journal 缓冲，没有 App 端 UI 消费者。
- `chat.dsh.retryableRequestIDs` 的 fingerprint 不含 backend/session；D2 键改造时要修。
- `openManagedSession` 仍硬编码 `/dsh/workspace`；D2 用 PC `workspace/follow` 的 cwd/id。
- `$events`、`session/control` 等未在本单延伸验证的部分保持 p0 spike 结论。
- 页面契约的 line-derived id 会随行号变化；`extract_ios_pages.py --check` 现在通过，
  但后续编辑 UI 文件仍要重跑。

### 4.11 建议提交信息

```text
iOS: prepare for PC workspace backend (PCLink D1b)

- Fix DSH Remote argument shapes for the 0.2.2-rc.1 gateway:
  session/list carries _request (App and Bot runtime); session/follow omits
  assistantStream; goals/* use agentId; messageFeedback/put wraps request.
- Treat messageFeedback/put's business result as a result envelope: check ok,
  retry version-conflict once with error.current.version, report other
  rejections; cover ok/version-conflict/target-not-found with tests.
- Route transport/harness and host lifecycle through the WorkspaceBackend
  seam; pause/resume/keep-alive delegate to the App's scene-phase owners.
- Move the transcript projector, conversation models, management
  decoders and session-history reader into ProbeKit (no duplicate copies).
- Refresh P09 page provenance mechanically; no page/action changes.
- Inventory bare-sessionID stores and record the D2 (BackendID, sessionID)
  plan without changing the persisted format.

Protocol impact: P09; P14; P26; P25: none — no event envelope/schema/durable event change, the failure diagnostic reuses the existing ephemeral runtime.stderr type; P06: none — backend seam only, no harness/event format change; P13: none — no plugin contract change; P16: none — no Worker env/launch change; P18: none — storage format unchanged (inventory + D2 plan only); P24: none — project source membership only; P27: none — no Bot row/user-action contract change.
```

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| `app-prep-r1` | iOS D1b implementer | 初始实现；发现并修复 goals/* 与 messageFeedback/put 的额外形状 bug；goals/* 与 Bot `session/list` 已登记给后续阶段 | iOS；D2/P18 owner（键方案） |
| `app-prep-r2` | iOS D1b implementer（代码审查修订） | messageFeedback/put 检查业务结果并按 version-conflict 重试；lifecycle 改走 App park/resume/keep-alive；修掉未使用绑定；Bot runtime `session/list` 改 `_request` 并记录诊断；补实际行为变化与 P26 impact | iOS；P25/P26 owner（Bot 诊断）；D2/P18 owner（键方案） |
