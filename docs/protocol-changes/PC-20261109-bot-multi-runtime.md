# Bot 运行时多路化与每 Bot 记忆（P26）

```yaml
change: PC-20261109-bot-multi-runtime
contracts: [P26]
status: implemented
breaking: false
version_decision: No schema or version change. Additive Swift runtime API plus memory replay rules; memory events keep the existing P25 envelope and SQLite schema, and the already-defined principal.botId becomes authoritative for agent scope. Historical events with botId == nil are read as "main".
base: dc823973e5bfa9dcb9bab1e0b6c00d35982812e7
contract_revision: Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift@bot-multi-runtime-v1 + Sources/PhoneDSHBot/Memory/SQLiteBotMemoryFactStore.swift@bot-multi-runtime-v1
```

Protocol impact: P26 — per-bot memory scope and runtime multiplexing; P25: none — event envelope unchanged, botId already in principal; P27: none — no row/action change; P09: none — the only app-side edit is a one-line persona-closure arity adaptation in `BotRuntimeComposition.swift`, with no page, token, projection or interaction change.

## 1. 識別與角色

- **Trigger → 現況 → 期望。** `BotMCPRuntime` 只有一個 `BotMemory(botID: "main")`，SQLite memory 回放不按 Bot 過濾，memory 事件寫 `botId: nil`；所有 `BotDSHRemoteRuntime` 以 `attachTaskExecutor(self)` 互相覆蓋同一個 `tasks`；每個 remote 只有一個 live-frame observer；`restorePersistedTasks` 恢復所有 Bot 的任務；persona closure 拿不到 botId。期望：同一 Host 可同時承載多個 Bot，agent 記憶與任務執行器按 principal.botId 隔離，user 記憶共享，舊資料歸 main，側邊欄可同時訂閱多個 Bot 的 live frame。
- **Coordinator / contract owner / implementer / reviewer-integrator:** `bm-runtime` 單元（本工作樹）依 AGENTS.md §3 產出凍結與實作證據。P26 的 owning contract 仍是 `spec/bot/v1/README.md`、`spec/bot/v1/memory-*.schema.json`、`held-inbox-item.schema.json` 等；本單**不修改** `spec/**`，只把既有 P26 語義落成 Swift runtime 的多 Bot 綁定規則，因此沒有新的 schema/golden revision。
- **Affected ends:** 只有 Swift `Sources/PhoneDSHBot/{MCP,Memory}`。Worker 的 P25 event envelope／identity／approval 鏈路、P27 row／user action、插件端與 Android 均未改。dsh-bot 上游未被 patch。
- **Base / head:** `dc823973e5bfa9dcb9bab1e0b6c00d35982812e7` / 本單元 candidate commit（hash 見交接訊息）。

## 2. 契約 delta

| 項目 | Before → After／依據 |
| --- | --- |
| Memory event 身分 | `memory.written`／`memory.forgotten` 等事件原本可由 `SQLiteBotMemoryFactStore(botID: nil)` 寫成 `botId: nil`。現在 production 每個 Bot 的 store 都帶真實 botID，事件寫 `principal.botId`；`botID == nil` 只保留給舊資料／舊 store，讀取時視為 `"main"`。P25 envelope 不變。 |
| Agent scope 可讀範圍 | 回放 `memory.written`／`memory.forgotten` 時，agent scope 事件只屬於 `event.principal.botId` 等於本 store 的 Bot；`nil` 事件只屬於 `"main"`。其他 Bot 的 agent 事實不可見。 |
| User scope 共享 | user scope 事件不做 Bot 過濾；任何 Bot 寫入的 user 事實對所有 Bot 可見，任一 Bot 的 forget/erase 也對所有 Bot 生效。 |
| Memory event id | main／nil 仍使用原本的 `evt-memory-{write,touch,forgotten}-<digest(factID…)>` 格式，舊事件可原樣重放；非 main Bot 把 botID 加入 digest，避免兩個 Bot 使用同一 fact id 時在共用 SQLite event log 上碰撞。 |
| Memory API | 新增 `public func memory(for botID: String) -> BotMemory`，按需建立並快取；`public let memory` 保留為 `memory(for: "main")` 的相容檢視。`UpdateMemory`／`RecallMemory` 依 `call.principal.botId` 取 store，不再固定 main。 |
| Task executor 路由 | `attachTaskExecutor(_:botID:)`／`detachTaskExecutor(botID:)`；舊無 botID 版本等於 `"main"`。`Task`／`AwaitTask`／`StopSubagent` 以 `call.principal.botId` 取執行器。沒有執行器時回 `unavailable` 並在 message 指名該 Bot，**不回退**到 main 或其他 Bot。 |
| Task 恢復 | `restorePersistedTasks` 只接受 `persistedTask.parentBotId == self.botId` 的快照；其他 Bot 的任務不會出現在本 remote 的 `taskStates`。`workerRestarted()` 通知所有已附加且相異的 executor。 |
| Live frame 訂閱 | 新增 `BotLiveFrameSubscription`、`subscribeLiveFrames(_:) -> BotLiveFrameSubscription`、`unsubscribeLiveFrames(_:)`、`liveFrames() -> AsyncStream<BotLiveTurnFrame>`。多個 observer 同時收到同一 frame；取消一個不影響其他。舊 `setLiveObserver(_:)` 保留為只管理自己的相容槽位。 |
| Persona | `BotDomainVolatileContextProvider` 的 persona closure 改為 `(botId, sessionId, kind) -> String`（async 版本同）；`snapshot` 以 principal 的 botId 呼叫，預設 persona 保留。新增可選 `memoryForBot` async resolver，讓 volatile memory 區塊也能按 Bot 取記憶；未提供時沿用單一 `memory`。 |
| 團隊工具掛鉤 | 新增 `BotTeamToolHandling`（`handles(_:)`、`execute(name:arguments:principal:context:)`）與 `registerTeamTools(_:)`。工具目錄、`tools/list` 與任何工具名都未改。已註冊且被 handler 認領的非目錄工具可完成 identity 登記，`execute` 先走既有 attribution／classifier／authorization，再交給 handler。未註冊名稱仍回 `unknown_tool`；host built-in（bash/write/edit/phone/device tools）不可被 handler 覆寫。 |
| Held message 喚醒 | 新增 `public func wakeWithHeldMessages() async throws`：只處理 pending held item；沒有 executor 無所謂，若該 Bot 沒有 running／queued chat turn，則用既有的 `sendUserMessage` 路徑開一個可見回合，prompt 開頭是 `HeldMessages.block`，request id 仍由 item ids 派生（`held:<digest>`），成功 commit、失敗 revert。running／queued 時 no-op，items 留給下一回合。沒有新增 event、row 或 wire frame。 |
| 錯誤／冪等 | 缺執行器：`BotMCPCallResult.failure("unavailable", …)`，不建立 `task.started`。wake：`wakeInFlight` 防重入；held request id 由 item ids 派生，沿用既有 idempotency。memory 事件 id 保持 main 兼容，非 main 以 botID 區分。 |

自檢（`spec/README.md` §5.1）：沒有新增第二種 envelope 或工具名；P25 event 形狀、P27 row/action 形狀與 SQLite schema 都沒改；新 API 是 additive，舊 `BotMCPRuntime` 呼叫端（`runtime.memory`、無 botID 的 `attachTaskExecutor`、`setLiveObserver`）仍可編譯；nil botId 舊資料有明確歸屬；沒有刪除或重用任何既有名稱。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old data → new | `memory.written`／`forgotten` 的 `principal.botId == nil` agent 事實由 `"main"` store 讀取；user 事實照舊共享。main 的 write/touch/forgotten event id 保持原 digest 格式，舊事件不會因 id 規則變更而失效。舊 `persistedTask` 若 `parentBotId == "main"` 由 main remote 恢復；其他 Bot 的 remote 不會誤收。 |
| new → old | P25 envelope 與 SQLite schema 不變，舊 App 可開啟同一個 DB；它只會按舊規則把全部 agent 事實當成 main 的回放結果（舊 reader 沒有 bot 過濾能力）。這是 rollback 的已知限制：在已產生非 main Bot agent 記憶後回滾，main 會暫時看到那些事實；需在回滾前刪除／歸檔非 main Bot 資料，或升級到支援 per-bot 的 build。本單不新增 migration，也不改 schema version。 |
| new → new | 兩個 Bot 的 `SQLiteBotMemoryFactStore` 可同時讀寫同一個 SQLite event log：agent 事實互不可見、user 事實共享、相同 fact id 在 agent scope 可各自存在（event id 含 botID）。兩個 remote 各自持有 live observer 集合與 task 執行器；同一任務只由 `parentBotId` 對應的 remote 恢復。 |
| persisted old data → new／rollback | 無 schema migration；nil botId 事實歸 main；舊 `task.created` 快照保留 `parentBotId` 欄位不變。回滾風險同上，沒有需要回滾的 durable 序號或 side effect。 |

- **版本／adapter 決定：** 不新增版本欄位。P26 的記憶 scope 與 wake 語義不變，只是把 Bot 身分落到既有 `principal.botId`；因此不需要 schema revision。日後若要跨 Bot 共享／轉移 agent 記憶，才需新的 P26 revision。
- **仍保留的差異：** 本單不新增工具名、不改 `tools/list`、不做 `SendToAgent`／`CreateTeammate` 的實際工具與授權效果分類（第 2 波 `bm-team`）；`BotTeamToolHandling` 只是路由 seam。App 的多 Bot 組裝（共享 MCP、每 Bot 環境、側邊欄）仍屬第 2／3 波。

## 4. 分工與證據

- **獨占路徑（本單）：** `Sources/PhoneDSHBot/MCP/**`、`Sources/PhoneDSHBot/Memory/**`、`Tests/PhoneDSHBotTests/MCP/**`、`Tests/PhoneDSHBotTests/Memory/**`、本變更單。沒有修改 `Profile/**`、`Wake/**`、插件或既有 spec/golden。
- **最小 app 呼叫點適配：** `examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift` 只把 `personaAsync: { _, _ in` 改成 `{ _, _, _ in`，跟隨凍結的 persona 簽名；UI/行為不變（P09: none）。
- **共享 fixtures：** 無新增 spec golden。測試以真實 `SQLiteDomainStore`、`SQLiteBotMemoryFactStore`、`BotMCPRuntime`、`BotDSHRemoteRuntime`、`BotScriptedRemoteTransport` 驅動；記憶隔離與 nil→main 用真實 SQLite 事件回放，不手寫 reader。
- **真實 producer／consumer 測試：** `BotMemoryIsolationTests`（per-Bot agent 隔離、user 共享、nil→main、重開 SQLite 後仍隔離、同 fact id 兩 Bot）；`BotRuntimeMultiplexingTests`（A/B 兩個 remote 的 Task 使用各自 botId/botRoot、未知 Bot 明確錯誤、detach 後不再路由、只恢復自己的任務、多 live subscriber、team hook 路由與未註冊拒絕、`wakeWithHeldMessages` 空閒／running）；`BotVolatileContextTests`（persona 收到 botId、per-Bot memory resolver）。
- **Exact commands → result：**
  - `swift build --target PhoneDSHBot` → **FAIL（環境）**：本工作樹的 DSH file sandbox 拒絕 SwiftPM 內部 `sandbox-exec`（`sandbox_apply: Operation not permitted`）。
  - `swift build --disable-sandbox --target PhoneDSHBot` → **PASS**。
  - `swift test --filter PhoneDSHBotTests` → **FAIL（環境，同上）**；`swift test --disable-sandbox --filter PhoneDSHBotTests` → **PASS，300 tests，0 failures**（既有 289 + 本單新增 11；既有測試未刪除、未跳過）。
  - `cd examples/probe-app && xcodegen generate` → **PASS**；`xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-runtime-dd build CODE_SIGNING_ALLOWED=NO` → 原樣 **FAIL（環境）**：SwiftPM manifest cache 寫入 `~/Library` 被檔案沙箱拒絕；把 `HOME`／`XDG_CACHE_HOME`／`CFFIXED_USER_HOME` 指到 `/tmp/bm-runtime-home` 後改為 **FAIL（環境）**：Xcode 以巢狀 `sandbox-exec` 啟動 macro plugin server（`sandbox_apply: Operation not permitted`）。再加上 `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`（只停用 macro plugin 子程序的巢狀沙箱，不改任何原始碼）後 → **BUILD SUCCEEDED**，完整命令見 §6。建置後 `Package.resolved` 只被 Xcode 改寫 `originHash`，已還原為 HEAD 版本。
- **Not verified:** 真機、模型 E2E、多 Bot 的 app 組裝（第 2 波）、實際 `SendToAgent`／`CreateTeammate` 工具與插件 prompt、桌面 dsh-bot 端。未把 SwiftPM 單元測試當作 device 或 Wire 證據。
- **Remaining risks:** rollback 到舊 build 後 main 可能讀到非 main agent 事實（§3 已記錄；由刪除／歸檔流程或升級處理）。`BotTeamToolHandling` 的效果分類仍沿用現有 unclassified→ask 鏈路，第 2 波需為真實工具提供 grant/分類；本單不搶先定義。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `bot-multi-runtime-v1`（本實作） | `bm-runtime`（contract owner / implementer） | 首次把 P26 的每 Bot 記憶、任務執行器、live frame、persona 與 team seam 落成 Swift runtime；nil botId 舊資料歸 main；未新增工具名。 | 第 2 波 `bm-team`／`bm-app`、第 3 波 `bm-drawer`、lead |

## 6. 實測記錄

實作於 base `dc823973e5bfa9dcb9bab1e0b6c00d35982812e7`；本單以 candidate commit 交接（hash 見交接訊息，避免變更單記錄自身 hash 後 amend 失效）。

| 檢查 | 命令 | 結果 |
| --- | --- | --- |
| Bot library build（原樣） | `swift build --target PhoneDSHBot` | FAIL（環境）：SwiftPM manifest 的巢狀 `sandbox-exec` 被工作樹沙箱拒絕（`sandbox_apply: Operation not permitted`） |
| Bot library build（工作樹沙箱關閉） | `swift build --disable-sandbox --target PhoneDSHBot` | PASS |
| Bot tests（原樣） | `swift test --filter PhoneDSHBotTests` | FAIL（環境，同上） |
| Bot tests（工作樹沙箱關閉） | `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS，300 tests，0 failures（既有 289 + 新增 11） |
| Xcode project | `cd examples/probe-app && xcodegen generate` | PASS |
| iOS app build | `HOME=/tmp/bm-runtime-home XDG_CACHE_HOME=/tmp/bm-runtime-home/.cache CFFIXED_USER_HOME=/tmp/bm-runtime-home xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-runtime-dd build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` | PASS（`** BUILD SUCCEEDED **`；只有既有 dependency-scan warnings） |

Not verified: 真機、模型 E2E、多 Bot app 組裝（第 2 波）、實際 `SendToAgent`／`CreateTeammate` 工具與插件 prompt、桌面 dsh-bot 端。`swift test` 的 PASS 不升級為 device 或 Wire 證據；原樣 command 的 FAIL 是工作樹沙箱環境，不是編譯或測試斷言失敗。

## 7. 第 2 波 `bm-memory` 修訂：recall scope、增量回放與按作用域擦除

- **Revision:** `bot-multi-memory-v2`（基於 `bot-multi-runtime-v1`；仍然只改 Swift `Sources/PhoneDSHBot/{Memory,MCP}` 的執行規則與 additive API）。
- **Base / head:** `466d9e672`（`bm/memory`，含 `feat/bot-multi` 的 per-Bot scope）/ 本單元 candidate（hash 見交接訊息，未 commit）。
- **Protocol impact:** P26 — memory recall scope and per-bot erase semantics; P25: none — events unchanged.

### 7.1 RecallMemory 的 scope 契約

| 呼叫 | Before → After | 依據 |
| --- | --- | --- |
| `RecallMemory` 指定 `scope: "agent"` / `"user"` | 先合併兩個 store 取 top-N、再按 scope 過濾，指定 scope 可能少於 `limit` → 只查指定 store，用完整 `limit` | 上游 `src/main/dshAgent.cjs:2314-2322` |
| `RecallMemory` 未指定 scope（或 `"all"`） | 合併 agent+user 排序取 top-N；若 top-N 全屬同一 scope 而另一 scope 有命中，保留最後一格給缺少的 scope | 不變；上游 `src/main/memory.cjs:1509-1537` |
| `BotMemory.recall` | 新增 `scope: BotMemoryScope? = nil` 參數；`nil` 保持合併，非 nil 只查該 store 並觸碰該 store 的命中 | additive Swift API |

### 7.2 增量回放與壞事件隔離

- **共用 feed：** 同一個 `SQLiteDomainStore`（同一個開啟中的 durable log）的所有 `SQLiteBotMemoryFactStore` 共用一個 process-wide `BotMemoryReplayFeed`；feed 只做一次從 commit 0 開始的全量掃描，記錄 cursor（已處理 commitSeq）與 memory 事件的 append-only 歷史。之後每次 `facts()`／`recall()`／`injection()` 只拉 `commitSeq > cursor` 的增量。
- **每個 authority 一次：** 每個 `SQLiteBotMemoryFactStore` 保留自己的 history index 與 replay state；agent 事實仍按 `principal.botId` 隔離，user 事實仍由所有 Bot 共享。第二個 authority、以及之後才建立的 authority，都從共用 feed 的歷史套用事件，不重新查 SQLite；因此 SQLite 只全量回放一次，每個事件在每個 store 只套用一次。
- **寫入可見性：** 任何 `append`／`remove`／`eraseAll`／`touch` commit 後，下一次讀取會同步新 commit 的增量，因此同一 authority 與其他 authority（含已暖機的 `memory(for:)`）都不會讀到舊值。
- **重開：** 新的 `SQLiteDomainStore` 是新 feed，會做一次新的全量回放；回放結果與關閉前一致。
- **壞事件：** 單條 `memory.written`／`memory.forgotten` 的 payload 解碼失敗（`DecodingError`）會被跳過並記入 `skippedEventIDs`；其他事件照常套用，不再讓整個 Bot 的記憶不可用。結構性損壞（缺 `commitSeq`、同一 fact id 的互相矛盾 payload）仍 fail closed，與原行為一致。
- **診斷 API：** `SQLiteBotMemoryFactStore.replayDiagnostics`（async read-only property）回傳 `BotMemoryReplayDiagnostics`：`fullReplayCount`（共用 feed 從 0 掃描次數）、`incrementalReplayCount`、`scannedEventCount`、`processedMemoryEventCount`、`skippedEventIDs`、`lastProcessedCommitSeq`。

### 7.3 按作用域擦除與刪除 Bot

| API | 作用範圍 | 語義 |
| --- | --- | --- |
| `BotMemory.eraseAll(scope: .agent)` | 只影響當前 `BotMemory` 所屬 Bot 的 agent scope | 對每個 live agent fact 寫入 text-free `memory.forgotten(reason: "erase")` tombstone；不改 user scope、其他 Bot、也不會讓被擦除 id 復活 |
| `BotMemory.eraseAll(scope: .user)` | 影響共享 user scope（所有 Bot 下一次讀取都會看到） | 同上；當前 Bot 的 agent facts 不受影響 |
| `BotMCPRuntime.deleteBotMemory(for: botID)` | 只影響 `botID` 的 agent scope | 先 `eraseAll(scope: .agent)`，再 `forgetMemory(for:)` 移除 `memory(for:)` 快取；供 bm-app 刪除 Bot 級聯呼叫 |
| `BotMCPRuntime.forgetMemory(for: botID)` | 只清快取 | 不動 durable facts；回傳是否真的移除了快取。之後 `memory(for:)` 會從事件重新建立 |

`BotMemoryEraseScopeResult` 回傳 `ok`、`scope`、`botID`、`removed`/`removedFacts`、`factIDs`、剩餘 `count`。`botID` 是執行擦除的 authority；`scope: .user` 的影響範圍仍是所有 Bot（文件註解已寫明）。`BotMemoryFactStore` 新增 `eraseAll(scope:)` 需求，並提供逐條 tombstone 的預設實作；`SQLiteBotMemoryFactStore` 覆寫為單一 durable batch。

### 7.4 相容性

| Producer → Consumer | 結果 |
| --- | --- |
| old data → new | 事件 envelope、`memory.written`／`memory.forgotten` 欄位與 event id 規則均不變；舊資料照舊回放。壞事件現在被跳過而不是阻塞全部記憶，這是可觀察的錯誤處理改善，不是格式變更。 |
| new → old | 不新增事件型別、schema 欄位或版本；舊 reader 仍能解碼 `memory.written` 與 `memory.forgotten(reason: "erase")`。`eraseAll` 只是對同一格式寫入多條 tombstone。 |
| new → new | 同一 durable log 的多個 Bot store 共用一次 SQLite 全量掃描；agent 隔離、user 共享與 event id 代次規則不變。重開或新 process 各自重新全量回放一次。 |
| rollback | 不需要 migration；已寫入的 erase tombstone 由舊 reader 按 `reason: "erase"` 處理。沒有新的 durable 序號或 side effect。 |

### 7.5 實測記錄（本工作樹）

| 檢查 | 命令 | 結果 |
| --- | --- | --- |
| Bot library build（原樣） | `swift build --target PhoneDSHBot` | FAIL（環境）：SwiftPM manifest 的巢狀 `sandbox-exec` 被工作樹沙箱拒絕（`sandbox_apply: Operation not permitted`） |
| Bot library build（工作樹沙箱關閉） | `swift build --disable-sandbox --target PhoneDSHBot` | PASS |
| Bot tests（原樣） | `swift test --filter PhoneDSHBotTests` | PASS，325 tests，0 failures（含本單新增 8 tests；既有測試未刪除、未跳過、未放寬） |
| Bot tests（工作樹沙箱關閉） | `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS，325 tests，0 failures |
| 效能（新測試） | `swift test --disable-sandbox --filter BotMemoryIncrementalReplayTests` | PASS；5 Bots × 400 + 25 user = 2,025 memory events；250 次 `facts()` + 250 次 `recall()` 約 2.6–10.7 秒（單獨執行 2.6–2.9 秒；全套並行負載下 4.2–10.7 秒，測試上限 60 秒只在防止意外的每呼叫全量回放）；所有 store 的 `fullReplayCount == 1`，`processedMemoryEventCount == 2025` 不隨讀取次數成長，寫入一條新事實後只增量 +1 |
| Xcode project | `cd examples/probe-app && xcodegen generate` | PASS |
| iOS app build（原樣） | `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-memory-dd build CODE_SIGNING_ALLOWED=NO` | FAIL（環境）：package manifest cache 寫入 `~/Library` 被檔案沙箱拒絕 |
| iOS app build（工作樹沙箱關閉＋既有 package cache） | `HOME=/tmp/bm-memory-home XDG_CACHE_HOME=/tmp/bm-memory-home/.cache CFFIXED_USER_HOME=/tmp/bm-memory-home xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-memory-dd -clonedSourcePackagesDirPath /tmp/bm-runtime-dd/SourcePackages -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` | PASS（`** BUILD SUCCEEDED **`；只有既有 dependency-scan warnings） |

- **Not verified:** 真機、模型 E2E、bm-app 的刪除級聯與設置頁接線（後續單元）、桌面 dsh-bot 端。`swift test` 不升級為 device 或 Wire 證據。
- **Remaining risks:**（1）共用 feed 保留 memory 事件歷史以支撐晚建立的 authority；目前不做壓縮，長期執行時記憶體隨 memory 事件數成長，若日後需要可加 snapshot/trim，但不改本次協議語義。（2）rollback 到不含 `eraseAll` 的舊 build 時，App 無法主動整批擦除；已寫入的 tombstone 仍由舊 reader 正確處理。（3）`forgetMemory(for: "main")` 不會移動 `memory` 相容 view，App 應在刪除主 Bot 前先完成 pointer 切換；本單不改 app。
