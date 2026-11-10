# 多 Bot 團隊工具、agent-comm 行與 held 回覆（P26/P27）

```yaml
change: PC-20261109-bot-team-tools
contracts: [P26, P27]
status: implemented
breaking: false
version_decision: Additive tool names, effect classifications, an additive agent.comm UI event and the already-declared agent-held kind. No P25 envelope field, no schema enum widening, no new version field, and no old-row replacement; old documents and old readers keep their current behaviour.
base: 408dd55eb79cdff65265b60ec46aa1c235840820
contract_revision: spec/bot/v1/README.md@multi-bot-v1 + spec/bot/v1/golden/{held-inbox,tool-catalog.phone,tool-effects.phone}.json
```

Protocol impact: P26 — team tools and prompts; P27 — agent comm rows and held-inbox agent-held; P25: none — envelope unchanged

## 1. 識別與角色

- **Trigger → 現況 → 期望.** 名冊、逐 Bot runtime 與逐 Bot 記憶已在第 1 波合入，但模型仍只有單 Bot 工具面：沒有 `SendToAgent`/`CreateTeammate`，held inbox 的 `agent-held` 分支未轉義，行投影沒有 agent-comm metadata。本變更補齊工具契約、宿主 seam、行與 held 語義，以及 Worker persona 的團隊工具說明。
- **Coordinator / contract owner / implementer / reviewer-integrator:** `bm-team` 單元（本工作樹）依 AGENTS.md §3 產出凍結與實作證據。Owning contracts：P26 `spec/bot/v1/README.md`、`held-inbox-item.schema.json`、`tool-catalog`/`tool-effects` golden 與 phone delta；P27 `row*` schema 的既有 `additionalProperties` 與 phone golden。
- **Affected ends:** Swift `Sources/PhoneDSHBot/{Team,Rows,Wake,MCP,Authz}`；App `examples/probe-app/PhoneDSHProbe/Bot`（由 `bm-app` 以 `BotTeamHost` 接線）；Worker `plugins/bot-runtime/{src,protests}` 與 `plugins/profile` 的 persona 副本。Kotlin、Rust、firmware 沒有 Bot 頁或 team tool consumer，不變。
- **Upstream reference:** dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6` 的 `tools/bots.cjs`、`tools/aliases.cjs`、`tools/teammates.cjs`、`mcp/dshbotServer.cjs`、`dshAgent.cjs`、`agentComm.cjs`、`renderer/lib/agentComm.js`、`wakeInbox.cjs`。上游原文不進公共倉庫。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| `SendToAgent` 工具 | 新增，僅在 phoneDSH 工具目錄與 Worker persona 中可見。`agent_id`（接受 id 或名字；別名 `target_id`/`bot_name`/`agentId`）與 `message`（別名 `text`）必填；可選 `title`。必須提供 `priority: Bool` 或 `delivery: "now"|"queued"`：缺失返回上游原句 `SendToAgent requires priority (true = wake now, false = hold for their next turn).`；`priority` 非 boolean 返回 `priority must be a boolean (true = wake now, false = hold for their next turn)`；`delivery` 非 now/queued 返回 `delivery must be "now" or "queued"`；兩者衝突返回 `priority <json> implies delivery "<x>" but delivery "<y>" was also given`。 |
| Sender attribution | 只使用已登記 `principal.botId`；不從工具參數推導 sender。目標按 id（大小寫不敏感）或名字解析；錯誤列出可見且非自己的名冊。 |
| Loop safety | 目標等於 sender 拒絕；`inbound depth + 1 > 2` 拒絕；目標已在目前 hand-off `chain` 中按 `delegation cycle detected` 拒絕。上游 DSH 路徑缺的環路檢查由本變更補上。 |
| Idempotency | `requestId = MCP call id`。相同 sender + requestId 已存在 outbound thread 時直接返回既有 `threadId`，不重寫行、不重送、不重複入 held inbox。 |
| `queued` | 寫 sender `outbound` 行（`status=held`）並向目標 enqueue `kind=agent-held` 的 `WakeInboxItem`（fromAgentId/Name、title、text、threadId、requestId）；不喚醒目標。回覆文案：`已扣住給 <name>：訊息會在對方下一個回合開頭交付，不會喚醒對方。` |
| `now` | 先寫 sender `outbound` 行，再透過 `BotTeamHost.deliverToAgent` 開可見目標回合或排在目標目前回合之後（不中斷）。目標回合最後 assistant 文本在 300 秒內返回；成功後寫 sender `inbound` 行，目標行 id 為上游 `t<turn>u`。逾時/失敗也寫一條 `inbound` error 行，不寫回覆 held。 |
| 回覆 held（有意差異） | 成功回覆除 sender `inbound` 行外，再以 `kind=agent-held`、`fromAgentId/Name=<目標>`、`title=回复[：<原 title>]`、`threadId=<同 thread>`、`requestId=reply:<call id>` 寫回 **sender** 的 held inbox，於 sender 下一回合進入上下文，不喚醒 sender。 |
| `CreateTeammate` | 新增；只有 `roster.mainBotID == principal.botId` 可呼叫，其他 Bot 返回 `permission_denied` 與明確句子。`name` trim 後 1–60 個 UTF-16 unit；`description` 截 300；`color` 15 色、`hairstyle` 4 髮型枚舉；`section_id` 接受但忽略。成功文案沿用上游格式並含 `agent_id`。 |
| 工具目錄 description | `SendToAgent` 與 `CreateTeammate` 描述附 `Available bots: <name> (id: <id>[, main Bot])`，由 `roster.visibleBots` 排除呼叫者自己與 `hidden_by_user` 生成；`BotToolCatalog.allDefinitions(roster:callerBotID:)` 是 App 的動態入口，靜態 `allDefinitions` 保留可發現性。 |
| 工具效果 | `SendToAgent` = `external-send + auto`（`dshbot.SendToAgent`），`CreateTeammate` = `write + auto`（`dshbot.CreateTeammate`）。兩者仍寫審計，但不向使用者再出審批卡；`BotToolEffectClassifier` 與 Worker `AUTO_TOOLS` 一致。 |
| Agent-comm 行 | 新增 `BotAgentCommDirection`（outbound/inbound/incoming/reply）、`BotAgentRef`、`BotAgentComm`、`BotTeamAgentCommRecord`。事件型別為 additive `agent.comm`，data 帶 `toAgent`/`fromAgent`/`agentComm{direction,targetId,targetName,fromAgentId,fromAgentName,message,replyText,requestId,threadId,firstEntryId,replyEntryId,delivery,status,title,hop,callId,error}`。既有 `transcriptWire` 的 `additionalProperties` 承載，沒有新增 row schema 欄位。 |
| Row identity | `outbound: agent-outbound-<sha256(sender\0target\0requestId\0seq)>`；`threadId=<rowID>@<seq>:agent-comm`；`inbound: t<turn>u`（同回合碰撞加 `2`、`3`…）。與上游 `agentComm.cjs` 一致。 |
| 顯示與彙總 | `outbound`/`inbound` 投影為 `agent-comm`；`incoming`/`reply` 仍是普通 `bubble`。`team-bot` 不再被 phoneP0 隱藏。`BotAgentCommSummarizer` 提供上游 `single`/`fanout`/`thread` 與 peers/messageCount。 |
| Held 轉義 | `HeldMessages.block` 的 `[agent]` 分支對 `fromAgentName`、`fromAgentId`、`title`、`text`、`msg id` 使用 `escapedHeldField`；注入 `</held_agent_messages>`、換行與 forged bullet 都不能跳出 held block。`held-inbox` golden 新增 `agentHeld`。 |
| Persona | 兩種語言的 Worker persona 都聲明 `SendToAgent`/`CreateTeammate`、`priority|delivery` 規則、主 Bot 才能建立隊友，並把「只有一個會話 / 沒有團隊」改成多 Bot；`plugins/profile` 的 `personaPrefix` 同步。 |

Self-check（`spec/README.md` §5.1）：沒有第二種 envelope、欄位別名或錯誤碼；team tool 名是 additive 且不改上游 P0 enum；`agent.comm` 是既有 UI event 的新值，舊 projector 忽略未知 type；`agent-held` kind 早已存在，本變更只加 golden 與轉義；新增 enum 都是封閉集合，未知值 fail-closed 或按既有 default 行為；沒有重用名稱或編號。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 舊客户看到既有 P0；未知 team tool 不會被呼叫。舊 `held-inbox.json` 沒有 `agentHeld`，Swift decoder 照舊解碼。舊 agent-comm 行只有 `toAgent`/`fromAgent`，`agentCommDirection` fallback 為 outbound/inbound。 |
| new → old | 新工具是 additive；舊 Worker/persona 不認識就不宣告。`agent.comm` 對舊 projector 是 unknown type → 不產生 row，但 durable event 可重放。`agent-held` 舊 reader 已按既知 kind 處理。 |
| new → new | `requestId` 去重跨重啟成立（由 host 的 durable outbound thread 查詢）；`agent-held` 以 requestId 去重；`threadId` 由 sender/target/requestId/seq 決定。Swift row/held/golden 與 Python golden 檢查同時覆蓋。 |
| persisted old data → new／rollback | 名冊、held inbox、BotEvent 格式都不變；rollback 後 `agent-held` 仍是既有 kind，`agent.comm` 事件保留但舊 UI 不畫。沒有 schema 版本提升或資料遷移。 |

- 版本／adapter 決定：P26 additive tool/effect/golden 與 P27 additive row metadata；不升 major，不新增 wire/version 欄位。
- `target` 條款中仍保留的差異：`now` 的 host 等待（最多 300 秒）是工具層行為；上游回覆是非同步立即返回。此差異是為了在同一個宿主呼叫中產生 `inbound` 行與回覆 held；逾時不取消目標回合，目標仍可完成。
- iOS 接線順序：`bm-app` 必須先以 `BotProfileStore` (+`BotDSHRemoteRuntime`) 實作 `BotTeamHost`，再 `registerTeamTools(BotTeamTools(host:))`；工具描述需使用 `BotToolCatalog.allDefinitions(roster:callerBotID:)` 才會帶名冊行。
- Unknown consumers：Kotlin/Rust/Android 沒有 Bot 頁；本變更不要求他們的 adapter，也不改 P01/P02。

## 4. 分工與證據

- Contract owner / Swift implementer：`Sources/PhoneDSHBot/{Team,Rows,Wake,MCP/BotToolCatalog,Authz/BotToolEffects}`、`Tests/PhoneDSHBotTests/{Team,Rows,Wake,MCP}`、`spec/bot/v1/golden/{held-inbox,tool-catalog.phone,tool-effects.phone}.json`、`spec/bot/v1/export-manifest.json`、`spec/bot/v1/README.md`、`spec/README.md` P26、本變更單。
- Worker implementer：`plugins/bot-runtime/{src/prompt/assemble.ts,src/approval-gate.ts,prompts/*}`、`plugins/tests/{bot-persona,bot-team-persona,bot-identity-approval}.test.ts`；`plugins/profile/phone.worker.cordis.patch.yml` 的 persona 副本由本單元同步（機械生成，非第二權威）。
- App consumer：由 `bm-app` 實作 `BotTeamHost`：roster/create、`agentCommContext`、`existingAgentCommThread`、`deliverToAgent`、`enqueueHeld`、`recordAgentComm`，並用 `BotDSHRemoteRuntime.sendUserMessage` 排隊目標回合。Exact signatures 見 §6。
- Shared fixtures：`spec/bot/v1/golden/held-inbox.json` 的 `agentHeld`、`tool-catalog.phone.json`、`tool-effects.phone.json`。Swift 測試以真實 `WakeInbox`、`BotSessionLogProjector`、`BotDisplayContract`、`BotToolEffectClassifier`、`BotTeamTools` 驅動；Python `validate_vectors.py` 只驗上游批次，phone delta 由 Swift 覆蓋。
- Exact commands → result / Not verified：見 §6。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `multi-bot-v1`（本凍結） | Coordinator `bm-team` | 首個多 Bot 工具與 agent-comm 行版本；含三項有意差異（主 Bot 才能 CreateTeammate、回覆 held 不喚醒 sender、環路檢查 + description 排除自己/隱藏）。 | Swift、Worker、App（`bm-app`）、規格審查 |

## 6. 宿主接口與實測記錄

### 6.1 需要 `bm-app` 接線的完整簽名

```swift
public protocol BotTeamHost: Sendable {
    func roster() async throws -> BotRoster
    func createBot(name: String, description: String,
                   color: BotFishColor?, hairstyle: BotFishHairstyle?) async throws -> BotProfile
    func agentCommContext(for botID: String) async -> BotAgentCommContext
    func existingAgentCommThread(botID: String, requestID: String) async -> String?
    func deliverToAgent(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply
    func enqueueHeld(_ request: BotTeamHeldRequest) async throws -> WakeInboxEnqueue
    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws
}

public actor BotTeamTools: BotTeamToolHandling {
    public init(host: any BotTeamHost,
                timeoutMilliseconds: Int = 300_000,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) })
    public nonisolated func handles(_ toolName: String) -> Bool
    public func execute(name: String, arguments: BotJSONValue,
                        principal: BotGatewayPrincipal,
                        context: BotMCPRequestContext) async -> BotMCPCallResult
}

public struct BotAgentCommContext: Sendable, Equatable {
    public var depth: Int
    public var chain: [String]
    public var turn: Int
    public var existingRowIDs: Set<String>
}

public struct BotAgentDeliveryRequest: Sendable, Equatable {
    public var sender: BotAgentRef
    public var target: BotAgentRef
    public var promptText: String
    public var message: String
    public var title: String?
    public var threadId: String
    public var requestId: String
    public var delivery: String
    public var hop: Int
    public var chain: [String]
}

public struct BotAgentDeliveryReply: Sendable, Equatable {
    public var text: String
    public var replyEntryId: String?
    public var status: String?
}

public struct BotTeamHeldRequest: Sendable, Equatable {
    public var botID: String
    public var item: WakeInboxItem
}

public struct BotTeamAgentCommRecord: Codable, Sendable, Equatable {
    public var rowID: String
    public var botID: String
    public var direction: BotAgentCommDirection
    public var role: String
    public var text: String
    public var fromAgent: BotAgentRef?
    public var toAgent: BotAgentRef?
    public var threadID: String
    public var requestID: String
    public var delivery: String?
    public var status: String?
    public var title: String?
    public var hop: Int?
    public var turn: Int?
    public var callID: String?
    public var replyEntryID: String?
    public var error: String?
}

public enum BotAgentCommDirection: String, Codable, Sendable { case outbound, inbound, incoming, reply }

public struct BotAgentRef: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String?
}

public struct BotAgentComm: Codable, Sendable, Equatable { /* direction + optional upstream fields */ }

public enum BotAgentCommIdentity {
    public static func outboundRowID(senderAgentID: String, targetID: String,
                                     requestID: String?, seq: Int64) -> String
    public static func threadID(rowID: String, seq: Int64?) -> String
    public static func turnRowID(turn: Int, existingIDs: Set<String> = []) -> String
}

public struct BotAgentCommSummary: Codable, Sendable, Equatable {
    public var kind: BotAgentCommSummaryKind
    public var direction: BotAgentCommDirection?
    public var peer: BotAgentRef?
    public var peers: [BotAgentRef]
    public var messageCount: Int
}

public enum BotAgentCommSummarizer {
    public static func isCommRow(_ row: BotRow) -> Bool
    public static func summarize(_ rows: [BotRow]) -> BotAgentCommSummary?
    public static func summarize(_ rows: [[String: BotJSONValue]]) -> BotAgentCommSummary?
}

public enum BotToolCatalog {
    public static let teamToolNames: [String]
    public static let baseTeamDefinitions: [BotMCPToolDefinition]
    public static func teamDefinitions(roster: BotRoster, callerBotID: String?) -> [BotMCPToolDefinition]
    public static func allDefinitions(roster: BotRoster, callerBotID: String?) -> [BotMCPToolDefinition]
    public static func availableBotEntries(roster: BotRoster, callerBotID: String?) -> [String]
    public static func availableBotsLine(roster: BotRoster, callerBotID: String?) -> String
}
```

**Host 必須維持的語義：**
1. `agentCommContext(for:)` 的 `depth` 是該 Bot 當前 inbound hop 深度；`chain` 包含目前 hand-off 已訪問的 Bot id（含呼叫者）。`deliverToAgent` 返回後，host 應用 `request.hop` 與 `request.chain` 更新目標 context，讓目標下一次 `SendToAgent` 能檢查 depth/cycle。
2. `deliverToAgent` 不得中斷目標正在跑的回合；忙時排隊。取消等待 Task 應停止等待（目標回合可繼續）。
3. `existingAgentCommThread` 必須 durable：重啟後同一 sender+requestId 仍返回原 thread。
4. `recordAgentComm` 寫 durable 行並在 sender/target 非當前選中時 +1 未讀；不得為 `agent-held` 回覆喚醒 sender。
5. `enqueueHeld` 直接用 `item.requestId` 去重，滿 200 條 fail-closed。

### 6.2 實測記錄

實作於 base `408dd55eb79cdff65265b60ec46aa1c235840820` 的工作樹，未提交。

| 檢查 | 命令 | 結果 |
| --- | --- | --- |
| Swift build | `swift build --target PhoneDSHBot --disable-sandbox` | PASS（11.6s，Build complete）。 |
| Swift tests | `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS，343 tests，0 failures；含新增 Team 18、Rows 5、Wake 3 與 catalog/HTTP/persona 斷言更新。 |
| Bot vectors | `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（schemas, positive vectors, negative vectors）。 |
| Plugin typecheck | `cd plugins && npm run typecheck` | PASS（tsc，無輸出錯誤）。 |
| Plugin focused bot suite | `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` | PASS，43 subtests（42 pass、1 skipped、0 fail）；含 `bot-team-persona`、`bot-persona`、`bot-identity-approval` 的 team 自動審批案例。 |
| Plugin full suite | `cd plugins && npm test` | INCOMPLETE：跑到第 1271 個 subtest 後 10 分鐘以上無新輸出，沒有 fail/summary；終止後改跑上列 bot suite。此 hang 在本次未觸及的 Python/WASI/其他外掛測試段，不能算 PASS。 |
| Spec/CI | `CI_PROTOCOL_BASE=$(git merge-base HEAD feat/bot-grok-ui) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS；phone-spec 13s、phone-cross-tree 13s（8/8 invariants、registry byte-identical、87 mutation tests OK）。`spec/registry.json` 因 P26 行文字更新而重新產生（僅 `source.evidence` 一行）。 |
| App build（使用者命令） | `cd examples/probe-app && xcodegen generate && xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-team-dd build CODE_SIGNING_ALLOWED=NO` | FAIL（環境限制）：DSH 沙箱拒寫 `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading`；即使加 `-packageCachePath` 仍被拒。另一次帶 `HOME` override 的建置進入編譯後，`swift-plugin-server` 因 `sandbox-exec: sandbox_apply: Operation not permitted` 失敗。 |
| App build（沙箱 workaround） | `CFFIXED_USER_HOME=/tmp/bm-team-home HOME=/tmp/bm-team-home xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-team-dd8 -packageCachePath /tmp/bm-team-pkg-cache 'OTHER_SWIFT_FLAGS=-disable-sandbox -Xfrontend -disable-availability-checking -enable-experimental-feature BuiltinModule -enable-experimental-feature Lifetimes -enable-experimental-feature InoutLifetimeDependence -enable-experimental-feature AddressableParameters -enable-experimental-feature AddressableTypes -enable-experimental-feature SuppressedAssociatedTypesWithDefaults' build CODE_SIGNING_ALLOWED=NO` | PASS：`** BUILD SUCCEEDED **`。`OTHER_SWIFT_FLAGS` 是為了繞過 Xcode 26.5 / swift-collections 1.7.5 對 package experimental feature 與 deployment target 的環境差異，不是本單元的 App 程式碼變更；`Package.resolved` 已還原。 |
| App 解析 | 上述 xcodebuild 的 SwiftPM 解析 | 需要先把 Xcode package cache 指到 `/tmp`；自動解析成功，`SwiftMath`/`swift-markdown`/`swift-collections` 都由已快取的 pin 解析。 |

Not verified: iOS device/simulator runtime, model E2E, real delivery to a live Worker (host is implemented in `bm-app`), and physical power-loss/reconnect. App compile is claimed only for the sandbox-workaround xcodebuild PASS; the exact user command in this DSH sandbox fails before/inside compilation for environment reasons, not for a source error. The full plugin suite is INCOMPLETE, not PASS.
