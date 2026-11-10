# 設備任務終態以只讀 held 消息交給 Bot（P26）

```yaml
change: PC-20261109-bot-device-task-results
contracts: [P26]
status: frozen
breaking: false
version_decision: Additive optional held-inbox item branch and phoneDSH-only golden vector; P25 event envelope, P07 task-delegation/journal/runner/grant and all existing WakeInboxItem fields stay unchanged, so old documents remain decodable and old readers ignore the unknown kind.
base: 246881c45b5131b0ace462fac1204a9d43b7ad12
contract_revision: spec/bot/v1/held-inbox-item.schema.json@device-task-result-v1 + spec/bot/v1/golden/held-inbox.json@deviceTaskResult
```

Protocol impact: P07; P26; P09; P25: none — the Bot event envelope、event log、effects 與 P25 golden 不變；P27: none — 不新增或修改 row、row batch、user action 或 row service。P07 僅新增 executor 的本地同步觀察者；[task-delegation](../../spec/device/v1/task-delegation.md) 的隔離會話、preset、runner、grant、journal 格式和設備回報語義全部不變。P09 僅 app 接線，不新增頁面或 UI 契約。

## 1. 識別與角色

- **Trigger → 現況 → 期望.** 設備任務在隔離、無工具的 `pdsh-device-task` 會話中跑完後，終態只回報設備；Bot 完全看不到結果。期望：journal 終態落盤後，把「設備、目標摘要、結果」作為一條只讀 held 消息交給 Bot，於下一個主回合開頭看到。Bot 不替設備執行工具，也不能把回覆發回設備。
- **Coordinator / contract owner / implementer / reviewer-integrator:** 本任務（單一 agent 兼任），依 AGENTS.md §3 產出凍結與實作證據。Owning contract：P26 held inbox，`spec/bot/v1/held-inbox-item.schema.json` 與 `golden/held-inbox.json`。
- **Affected ends:** Swift `Sources/PhoneDSHDeviceTasks`（settlement producer）、`Sources/PhoneDSHBot`（notice/item 與 held 渲染）、`examples/probe-app/PhoneDSHProbe`（App 接線）。Kotlin、Rust、TS、Worker 與 firmware 無 held inbox consumer，不變。

## 2. 契約 delta

| 項目 | Before → After |
| --- | --- |
| `held-inbox-item.schema.json` | 一個分支（`kind` ∈ agent-held/subagent-result/routine-result/card-dismissed）→ 新增第二個 `oneOf` 分支：`kind=const device-task-result`，除通用必填外必填 `taskId`（非空字串）、`status`、`requestId`（非空字串）；`status` ∈ completed/denied/unavailable/expired/failed/unknown_outcome。`additionalProperties` 維持 true，WakeInboxItem 不新增欄位。 |
| Item identity | 新增 `id = device-task-result-<hex>`、`requestId = device-task:<hex>`；`hex` 為 UTF-8 device ID、一個 NUL、UTF-8 idempotency key 的 SHA-256 小寫 hex。`WakeInbox.enqueue` 既有的 requestId 去重使同一任務只留一條。 |
| Content | `title` 為設備顯示名（≤80 字符）；`taskId`/`status` 使用既有可選欄位；`text` 為目標摘要（≤120 字符）加結果，最終 ≤1200 字符，符合 `WakeInboxItem.validate`。 |
| Rendering | `HeldMessages.block` 對 `device-task-result` 新增單行：`- [device-task] <設備名> · task <id> · <status>: <text>`；設備名、任務 ID、status 與 text 全部經 `escapedHeldField`。只有存在此 kind 時，開頭說明句追加「设备任务结果」／"device task results"；否則輸出不變。 |
| Delivery | 設備任務終態 journal 寫入成功後、向設備 `report` 前，同步呼叫一次可選 observer。既有終態記錄的重放只重送 report，不再通知。無 journal 補投；at-most-once。 |

Self-check（`spec/README.md` §5.1）：沒有第二種 envelope、欄位別名或錯誤碼；新分支是 additive，舊文檔可解碼，未知 kind 的舊 reader 不會誤讀為已知 kind；新增 enum 是封閉的 `status`，未知值由 schema 拒絕；沒有重用名稱或編號。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 舊 held 文檔沒有 `device-task-result`，Swift decoder 以可選欄位解碼並照舊渲染；schema 第一分支不變。`WakeInboxGoldenTests`、`RoutineWakeGoldenTests` 維持通過。 |
| new → old | 舊 reader 只讀既有 kind；未知 kind 不是錯誤，只會落到其 default 分支，不會產生工具或回覆設備。`WakeInboxItem` 沒有新增 required 欄位。 |
| new → new | 同一個 hex derivation 與 requestId 去重跨重啟成立；重複 enqueue 返回既有 item。以 Swift 測試與 Python golden 驗證。 |
| persisted old data → new／rollback | SQLite held inbox 事件格式不變；rollback 後 `device-task-result` 留在 inbox，舊版本照常讀取（未知 kind），不回滾、不重放設備任務。 |

- 版本／adapter 決定：P26 additive optional branch；不升 major，不新增 wire/version 欄位。
- `target` 條款中仍保留的差異：通知只在 Bot composition 在運行時安裝；App 未啟動時的結果不補投，這是本變更明示的 at-most-once 語義，不是實作缺口。

## 4. 分工與證據

- Contract owner：`spec/bot/v1/README.md`、`held-inbox-item.schema.json`、`golden/held-inbox.json`、`spec/bot/v1/tools/validate_vectors.py`、本變更單。
- Swift device：`Sources/PhoneDSHDeviceTasks/DeviceTaskExecutor.swift`、`Tests/PhoneDSHDeviceTasksTests/DeviceTaskSettlementTests.swift`。
- Swift Bot：`Sources/PhoneDSHBot/Wake/{DeviceTaskResultNotice,WakeInbox}.swift`、`Tests/PhoneDSHBotTests/Wake/DeviceTaskResultNoticeTests.swift`。
- App：`examples/probe-app/PhoneDSHProbe/{DeviceTaskManager.swift,Bot/BotRuntimeComposition.swift}`；`PDSH_TEST_HOOKS` 下新增 `testSettlementDisplayNameAndOwnerScopedCallback`（在 `examples/probe-app/PhoneDSHDeviceTests/RealDeviceTaskModelTests.swift`），以 `testEngine` 覆蓋顯示名映射與 owner-scoped callback。executor 觀察者本身由 `PhoneDSHDeviceTasksTests` 覆蓋；iOS App 建置由主審查者在沙箱外執行。
- Commands → result：見 §6 實測記錄。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `device-task-result-v1`（本凍結） | Coordinator | 方案 A：以既有 held inbox 傳遞設備任務終態，不新增 Bot 工具、不改 event envelope。 | Swift device、Swift Bot、App |

## 6. 實測記錄

實作於 base `246881c45b5131b0ace462fac1204a9d43b7ad12` 的工作樹，未提交。

| 檢查 | 命令 | 結果 |
| --- | --- | --- |
| DeviceTasks | `TZ=America/Los_Angeles swift test --disable-sandbox --filter PhoneDSHDeviceTasksTests` | PASS，67 tests，0 failures；含新增 7 個 settlement 測試（fresh completion、failed、expired、timeout、terminal replay、report failure、no observer）。 |
| Bot | `TZ=America/Los_Angeles swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS，250 tests，0 failures；含新增 6 個 notice/rendering/golden 測試。 |
| Vectors | `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（schemas, positive vectors, negative vectors）。 |
| Registry | `python3 spec/tools/registry_build.py --write` 後 `--check` | PASS，registry.json byte-identical。 |
| CI | `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS；phone-spec 11s、phone-cross-tree 12s（8/8 invariants、registry、schema diff 0 breaking、87 mutation tests OK）。 |
| App syntax | `xcrun swiftc -parse examples/probe-app/PhoneDSHProbe/DeviceTaskManager.swift examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift examples/probe-app/PhoneDSHDeviceTests/RealDeviceTaskModelTests.swift` | PASS（parse only）。`xcodebuild ... build` 在此沙箱因 SwiftPM manifest 快取 `~/Library/Caches/org.swift.swiftpm` 被拒（Operation not permitted）而 NOT_RUN；iOS App 完整建置與 `PhoneDSHDeviceTests` 執行由主審查者於沙箱外驗證。 |

Not verified: iOS App build / simulator or physical-device run; BLE display-name path uses the same manager code but no physical BLE task fixture was exercised. App compile beyond parse is therefore not claimed.
