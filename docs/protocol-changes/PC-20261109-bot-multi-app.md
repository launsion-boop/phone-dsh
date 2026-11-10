# 多 Bot 的 App 组装与接线（P09/P26）

```yaml
change: PC-20261109-bot-multi-app
contracts: [P09, P26]
status: implemented
breaking: false
version_decision: No wire, schema or event change. The App now composes one shared BotMCPRuntime/HTTP server/outbox with per-Bot DSH remotes, schedulers, wake inboxes and row/info services; all legacy `"main"` defaults are replaced by the roster main-Bot pointer. The library contracts (P26) are unchanged.
base: b4c3cca0901b6c08ad0c39a4012a8296a1070231
contract_revision: docs/protocol-changes/PC-20261109-bot-multi-app.md@app-wiring-v1
```

Protocol impact: P09 — Bot app wiring; P26: none — library contracts unchanged; P27: none — rows produced by existing projection.

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 第 1 波已有名册（`BotProfileStore`）、每 Bot 记忆（`BotMCPRuntime.memory(for:)`）、多订阅 live frames（`BotDSHRemoteRuntime`）和团队工具宿主 seam；App 仍把 `BotRuntimeComposition` 当作单 Bot 组合根：一个 remote、一个 scheduler、一个 wake inbox、一个字面 `"main"`，设备任务结果只投给固定 inbox，信息页「抹除全部记忆」会连共享 user scope 一起清掉。期望：整个 App 共享唯一 MCP runtime/server/outbox，名册里每个 Bot 有自己的一套运行时；选中 Bot 持久化；删除 Bot 做完整级联；未读、主 Bot 指针、每 Bot 记忆、keep-alive 与皇冠都按指针工作。
- **Coordinator / contract owner / implementer / reviewer-integrator:** `bm-app` 单元（本工作树）。P26 的 owning contract 仍是 `spec/bot/v1/**`；本单元**不修改** `spec/**`、`Sources/PhoneDSHBot/**`、插件或 `Bot/Fish/**`。
- **Affected ends:** 只有 App 的 `examples/probe-app/PhoneDSHProbe/Bot/**`、`ChatModel` 的 Bot 组装/保活段、`BotSessionRegistry`、`ProbeKit/DeviceTaskManager` 的结果投递路由（未改动），以及 CI fixture/e2e 工程文件。没有 Worker、Kotlin/Rust/Android 或协议面变化。
- **Base / head:** `b4c3cca0901b6c08ad0c39a4012a8296a1070231` / 本单元工作区（未提交，按沙箱要求）。

## 2. 组装

- **共享（硬约束）：** `BotRuntimeComposition` 只创建一个 `BotMCPRuntime`、一个 `BotMCPHTTPServer`、一个 `BotProductionEffectRunner`，Worker 仍只拿到一个 `PDSH_PHONE_MCP_URL`。
- **每 Bot：** `BotRuntimeUnit` 持有该 Bot 的 `BotDSHRemoteRuntime(botId:)`、`RoutineScheduler`、`WakeInbox`、`BotRemoteActionPlanner`、`BotProductionRowService` 和 `BotProductionInfoService`。按需创建：打开/选中该 Bot、收到发给它的消息、`SendToAgent` 投递、设备任务结果或例行任务需要时；`rosterUpdates()` 删除 Bot 时同步拆除。启动时选中 Bot 与所有已有例行任务的 Bot 会被附加；其余保持惰性。例行任务的 runner 用 `BotRoutineActivityFlag` 计数，因此隐藏例行回合也计为 running 并参与侧边栏/keep-alive。
- **主 Bot 指针：** 空名册时 `prepare` 先 `bootstrapMainIfNeeded`（首次仍写历史记录 id `main`，之后它只是普通 Bot）；已有名册绝不追加合成记录，随后始终读 `BotProfileStore.roster().mainBotID`。`BotProfileCenter(botID:)`、`BotRuntimeContext`、设备任务结果、未来默认例行任务归属、深链都通过 `BotMainPointerRouting`，不再有生产默认字面 `"main"`。
- **每 Bot 记忆：** 组装时 `memoryForBot: { await runtime.memory(for: $0) }`；每个 unit 的 `BotProductionEnvironment.memory` 是 `runtime.memory(for: botID)`；信息页/记忆页读取同一个 authority。队例、`user` scope 仍由所有 Bot 共享。
- **保活：** `ChatModel` 每秒读 `rosterModel.anyBotRunning`；后台 keep-alive、idle timer、`finishBackgroundKeepAlive` 都使用 `turnRunning || botTurnsRunning`，任一 Bot 回合结束且 DSH 回合也结束才停音频/停车。

## 3. 侧边栏 API（第 3 波消费）

`examples/probe-app/PhoneDSHProbe/Bot/BotRosterModel.swift`：

```swift
@MainActor @Observable final class BotRosterModel {
    var roster: BotRoster { get }                 // 插入顺序 + 修复后的指针
    var selectedBotID: String? { get }
    var entries: [BotRosterEntry] { get }         // 主 Bot 置顶，含隐藏 Bot
    var visibleEntries: [BotRosterEntry] { get }  // 排除 hiddenByUser
    var selectedEntry: BotRosterEntry? { get }
    var selectedIsMainBot: Bool { get }
    var anyBotRunning: Bool { get }
    var mainBotID: String? { get }
    var loadError: String? { get }
    var actionError: String? { get }
    var deletionError: String? { get }
    func select(_ botID: String) async             // 持久化 + markRead
    func refresh() async
    func setMain(_ botID: String) async
    func setHidden(_ botID: String, hidden: Bool) async
    @discardableResult
    func create(name:description:color:hairstyle:) async throws -> BotProfile
    func noteMessage(to:bumpUnread:at:) async      // touch + 可选 incrementUnread
    func setRuntimeState(_:for:)                  // composition 每秒喂入
    func runtimeState(for:) -> BotRosterRuntimeState
    func appearance(for:) / profile(for:) / displayName(for:)
}

struct BotRosterEntry: Identifiable, Equatable {
    let id: String
    var name, description: String
    var appearance: BotFishAppearance
    var isMainBot, isHidden: Bool
    var unreadCount: Int
    var lastMessageAt: Int64?
    var fishState: BotFishLifecycle
    var activity: BotActivity?
    var isRunning: Bool
    var pendingApprovalCount: Int
    var runtimeState: BotRuntimeState
}
```

`BotProductionHub`（`BotProductionPage.swift`）额外暴露 `chatModel`、`infoModel`、`selectedIsMainBot`、`appearance(for:)`、`handleDeepLink(_:)`、`select(_:)`、`deleteBot(_:)`，并缓存每个 Bot 的 `BotChatModel`/`BotInfoModel`/`BotProfileCenter`。选择写入 `UserDefaults("phoneDSH.bot.selectedBotID")`，启动时恢复；缺失/已删除时回落主 Bot 指针。

## 4. 团队工具宿主

`BotRuntimeComposition: BotTeamHost`，`runtime.registerTeamTools(BotTeamTools(host: composition))`。

| 能力 | 实现 |
| --- | --- |
| `roster` / `createBot` | `BotProfileStore`；创建后刷新 `BotRosterModel`。 |
| `agentCommContext` | 每 Bot 的深度/chain + 当前 DSH 回合号（`runtime.currentTurnID`）+ 已分配 `t<turn>u` id 集；`inbound` 回合由 `deliverToAgent` 设置，返回后清除。 |
| `existingAgentCommThread` | 扫描 durable `agent.comm` outbound 行，按 sender+requestId 缓存；新行写入时同步缓存。 |
| `deliverToAgent`（now） | 目标空闲 → 用目标 remote `sendUserMessage(promptText)` 开可见回合，等最后 assistant 文本。目标忙 → 写 `agent-held` 到目标 wake inbox，等目标当前回合结束 `wakeWithHeldMessages()`，再取该唤醒回合的最后 assistant 文本。 |
| `deliverToAgent`（queued） | `BotTeamTools` 直接走 `enqueueHeld`；宿主也保留 `queueHeldOnly` 分支。 |
| `enqueueHeld` | 目标 `WakeInbox.enqueue(item)`（requestId 去重，满 200 fail-closed），并登记下一次回合的 hand-off 上下文。 |
| `recordAgentComm` | durable `agent.comm` 事件（沿用现有投影）+ 未读/touch：outbound 给目标、inbound 给发送方、incoming/reply 给行所属 Bot；当前选中 Bot 不加。 |

**工具列表差异（需要库层改动）：** `BotMCPHandler.rpc("tools/list")` 仍编码静态 `BotToolCatalog.allDefinitions`。`tools/list` 没有 Bot 会话身份，handler 也没有 catalog-provider 钩子，App 无法把 `BotToolCatalog.allDefinitions(roster:callerBotID:)` 挂到 wire 上；`BotRuntimeComposition.toolDefinitions(callerBotID:)` 已提供该入口，但只有库层加 provider（或按会话返回 catalog）后才能真正替换。错误信息里的 available-bots 列表与 execute 路由已使用名册语义。

## 5. 删除级联

`BotRuntimeComposition.deleteBot(_:)` 用 `BotDeletionPlan` 顺序执行；资料记录在最后一步删除，失败时已执行的步骤按逆序回滚内存缓存/选择，不删除记录：

1. `abort-turns` — `cancelMainTurn()` + `remote.workerRestarted()`（只影响该 Bot 的 remote）。
2. `deny-approvals` — 扫描该 Bot 的 pending `approval.requested`，逐条 `resolve(.deny)`（库层没有 per-bot `cancelAll`）。
3. `revoke-auth` — `gateway.tokens.revokeBot(botID)` + `grants.revokeBot(botID)`。
4. `archive-sessions` — 扫描 `gb-<botID>`、`runtime.started`、routine/task 事件涉及的 session id，`workspace/archiveSession` 尽力归档。
5. `clear-routines` — 删除该 Bot 全部例行任务。
6. `clear-held` — 清空该 Bot 的 wake inbox（staged/pending 一起）。
7. `erase-memory` — `runtime.deleteBotMemory(for:)`，只删 agent scope。
8. `forget-memory` — `runtime.forgetMemory(for:)` 丢缓存。
9. `unregister-sessions` — `BotSessionRegistry.shared.unregister` 所有扫描到的 id。
10. `delete-profile` — `BotProfileStore.deleteBot(id:)`（最后一个 Bot 抛 `.lastBot`）。
11. `teardown-caches` — 移除 unit、comm tracker/thread cache、`BotChatModel`/`BotInfoModel`/`BotProfileCenter` 缓存；若删的是选中 Bot，选主指针/第一个。

失败时 `rosterModel.deletionError` 与抛出的 `BotDeletionFailure` 都带步骤名；信息页显示原文（`.lastBot` 显示「这是最后一个 Bot，不能删除。」）。`BotDeletionPlan.run()` 负责逆序 rollback，fixture 覆盖「失败步骤不执行 delete-profile / 回滚顺序」。

## 6. 未读、皇冠、消息行

- **未读：** 规则集中在 `BotUnreadRules`。`recordAgentComm` 按方向给非选中接收方 +1；routine 投递（`BotRoutineOutboxRouter.apply`）和设备任务结果（主 Bot 指针）投递给非选中 Bot 时 +1；`touch(lastMessageAt)` 同时更新。当前选中 Bot 永不加。
- **设备任务结果：** `DeviceTaskManager` 的 settlement 回调仍由唯一 composition 安装；收到后解析 `roster().mainBotID`，按需创建主 Bot unit 并写它的 wake inbox，不再写固定单 Bot inbox。
- **皇冠：** `BotChatPage(isMainBot:)` 头部与空状态、`BotInfoPage(isMainBot:)` 顶部头像/外观预览/发型缩略图传 `crowned: isMainBot`。
- **agent-comm 行：** `BotTranscriptRow` 在 `BotAgentCommRendering.presentation(for:)` 命中时显示一行「已传消息给 X / X 回复 / X 传来消息 / 已回复 X」+ 28pt 小头像；点击整行切到 peer Bot，完整视觉留给第 3 波。
- **深链：** `BotProductionHub.handleDeepLink` 按 URL 的 botID 解析；不存在的旧 `main` 链接映射到当前主指针，其他不存在 id fail-closed；切 Bot 后再打开原行。

## 7. 记忆

`BotProductionInfoService.eraseMemories()` 改为 `BotMemory.eraseAll(scope: .agent)`；新增 `eraseSharedMemories()` → `.user`。信息页记忆列表分「本 Bot」（非 user scope）与「共享」（user scope），共享清除需要两步 confirmation。`forget(factID:)` 仍由 `BotMemory` 在 agent/user 两 scope 查找。每 Bot 的 unit/environment/info 都使用自己的 `memory(for:)`，共享 user scope 只通过显式入口擦除。

## 8. 改动文件

- App 运行时/模型：`Bot/BotRuntimeComposition.swift`、`Bot/BotRuntimeUnit.swift`（新）、`Bot/BotRuntimeState.swift`（新）、`Bot/BotRosterModel.swift`（新）、`Bot/BotAppWiringLogic.swift`（新）、`Bot/BotAgentCommRendering.swift`（新）、`Bot/BotProfileStorage.swift`（新）、`Bot/BotProductionServices.swift`、`Bot/BotProductionUIAdapters.swift`、`Bot/BotProductionPage.swift`。
- App 页面：`Bot/BotChatModel.swift`、`Bot/BotChatPage.swift`、`Bot/BotInfoPage.swift`、`Bot/BotProfileCenter.swift`、`Bot/BotUIModels.swift`。
- 保活/会话：`ChatModel.swift`（Bot 组装与保活段）；`BotSessionRegistry` 的 `unregister` 由删除级联调用，文件本身未改。
- Fixtures/CI：`Bot/BotFixtures.swift`（新增 5 组真实断言 + `agentComm`/皇冠 fixture）、`scripts/ci/bot-ui/capture.sh`（沙箱 flag / XCUITest skip 的 fixture fallback）、`scripts/ci/bot-e2e/app/project.yml`、`TestsChatModel/BotChatModelTests.swift`、`scripts/ci/bot-e2e/app/Sources/BotTurnProcessShim.swift`（新，仅 E2E target 编译 shim）。
- 本文档。

## 9. 验证

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Bot library tests（原样） | `swift test --filter PhoneDSHBotTests` | FAIL（环境）：SwiftPM manifest 的巢状 `sandbox-exec` 被工作树沙箱拒绝（`sandbox_apply: Operation not permitted`）。 |
| Bot library tests（沙箱关闭） | `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS，351 tests，0 failures。 |
| Xcode project | `cd examples/probe-app && xcodegen generate` | PASS。 |
| iOS app build（原样） | `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-app-dd build CODE_SIGNING_ALLOWED=NO` | FAIL（环境）：SwiftPM 写 `~/Library/Caches/org.swift.swiftpm/manifests` 被拒。 |
| iOS app build（沙箱 workaround） | `HOME=/tmp/bm-app-home XDG_CACHE_HOME=/tmp/bm-app-home/.cache CFFIXED_USER_HOME=/tmp/bm-app-home xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-app-dd -packageCachePath /tmp/bm-app-pkg-cache build CODE_SIGNING_ALLOWED=NO 'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'` | PASS（`** BUILD SUCCEEDED **`）。`Package.resolved` 已还原为 HEAD。 |
| Bot UI fixture/capture（原样） | `bash scripts/ci/bot-ui/capture.sh --appearance light,dark --out /tmp/bm-app-shots --device 90F24C75-9E2A-41C4-8E56-0BAB7460DE1C` | FAIL（环境）：XCUITest runner 与 SwiftPM/macro plugin 被沙箱拒绝。 |
| Bot UI fixture/capture（workaround） | 同上 + `HOME`/`CFFIXED_USER_HOME`、`BOT_UI_OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`、`BOT_UI_SKIP_UI_TESTS=1` | PASS：60 张 light/dark 截图（含 `agentComm` 与主 Bot 皇冠 fixture）；`Bot UI conformance checks: PASS (… main-pointer-routing, unread-rules, team-delivery-now-busy-queued, delete-cascade-order-rollback, agent-comm-row-minimal-render …)`；manifest `interactions: NOT_RUN`（XCUITest runner 被沙箱阻止，fixtures/截图经 `simctl launch` 真实运行）。 |
| Bot E2E（原样） | `bash scripts/ci/bot-e2e/run.sh --simulator --scenario conversation-card-approval-routine-held` | FAIL（环境）：scripted `swift test` 在 manifest 沙箱阶段失败；simulator 未开始。 |
| Bot E2E scripted（workaround） | `swift test --disable-sandbox --filter BotConversationE2ETests` | PASS，1 test，0 failures。 |
| Bot E2E simulator（workaround） | `xcodegen generate --spec app/project.yml` + `xcodebuild build-for-testing … 'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'` | `** TEST BUILD SUCCEEDED **`；随后 `xcodebuild test` 在启动 runner 时报 `Pseudo Terminal Setup Error`，沙箱阻止，**simulator NOT_RUN**（不是测试断言失败）。 |
| Diff hygiene | `git diff --check` | PASS。 |

- **Not verified:** 真机、真实模型 E2E、桌面 dsh-bot 端、生产 Worker 上的实际 `SendToAgent`/`CreateTeammate` 回合、物理断电/进程杀死后的删除重试。未把单测、fixture 或截图升级为 device/Wire 证据。
- **Remaining risks:**
  1. `tools/list` 仍是静态目录（缺库层 provider，见 §4）；`toolDefinitions(callerBotID:)` 已就绪，等 library hook。
  2. 删除是「先清理、最后删记录」：如果 `erase-memory`/`delete-profile` 失败，授权、例程、held 与归档可能已生效，记录仍在；重试会重复清理，但不会出现「记录已删、数据还在」的半删。`BotDeletionPlan` 只回滚内存状态，不伪造不可逆授权恢复。
  3. 隐藏 routine 回合不产生 live chat frame，侧边栏 `isRunning` 已由 routine activity flag 覆盖，但 `fishState` 只能到 `working`、`activity` 无细节；第 3 波可接 routine run 事件补足。
  4. `BotTeamHost` 的 queued/busy 上下文只在目标下一次 team-tool 调用时消费；目标若从不调用 team tools，该 pending context 会留到之后（不产生错误，只是多一个旧 chain）。
  5. XCUITest runner 与 simulator E2E runner 在本沙箱均为 NOT_RUN，需在有 runner 权限的 CI/真机重跑。
