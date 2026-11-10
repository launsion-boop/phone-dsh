# WAL 舊段回收與恢復快速路徑對齊 §9（P02）

```yaml
change: PC-20261109-wal-durable-epoch-truncation
contracts: [P02]
status: frozen
breaking: false
version_decision: 無 wire、schema 或 manifest 版本變更：manifest 仍是 format 1 且欄位不變，Swift 只是把既有的 §9 讀法實作對齊；Kotlin 已符合，Rust planner 不執行 unlink/compaction。
base: 3781dbdc960ba0119edf64dec398d63c3492034e
contract_revision: spec/v1/wal.md@wal-durable-epoch-truncation
```

Protocol impact: P02；P05: none — response-log 只新增 `isExcludedFromBackup` 目錄屬性，記錄、淘汰、重放與 128 MiB 配額全部不變；P17: none — exec-bridge／journal 的載體與語義不變，本次未改任何 P17 檔案。

## 1. 識別與角色

- **Trigger → 現況 → 期望.** 真機 `chat-host` 的 manifest 是 `last_durable_epoch=232`, `last_mseq=12662`, `materialized_upto_mseq=12662`；`segments[]` 仍列 epoch 215、218、219（皆無自己的 close 記錄）與 220–228，另有一個未列入的 `00000217`。舊 Swift `WALSegmentLifecycle.durableEpochs` 只認「段內有 close 記錄」的 epoch，因此這些段永遠不可刪（`isDroppable`）；`RecoveryManager.hasUnclosedHistory` 又用同一個定義，讓每次冷啟動都放棄快速路徑、執行全量 `checkAndRepair`（實測 recovery=7914 ms，正常啟動 34–41 ms）。期望：依 §9 已裁決的讀法，以 manifest 的 `last_durable_epoch` + `segments[]` 證明 epoch 持久；列在 manifest 且 epoch ≤ `last_durable_epoch` 的段可回收，也不再算「未關閉歷史」。最新 close 段仍是 backstop。
- **Coordinator / contract owner / implementer / reviewer-integrator:** 本任務單一 agent 兼任，依 AGENTS.md §3 產出 freeze 與實作證據。Owning contract：P02，`spec/v1/wal.md` §9、§10 與 `spec/v1/golden/wal/**`。
- **Affected ends:** Swift `Sources/PhoneDSHLog/{WALSegmentLifecycle,WALWriter,RecoveryManager,WALReader,WorkspaceLogService}.swift`；Swift `Sources/PhoneDSHGateway/ResponseLog.swift`（只加備份屬性）。Kotlin 實作不改（`DroppableRule` 已是此讀法），Rust `shell/crates/pdsh-wal` 實作不改。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 可刪條件 | Swift 舊：段內必須有 close 記錄 + 水位 + 非最新 close + 非 current。新：列在已持久 manifest `segments[]`、`epoch ≤ last_durable_epoch`、段自己的每條 mutation ≤ `materialized_upto_mseq`、非 current、非保留段中最新 close。最後一項仍是 backstop。§9 decided reading；Kotlin `DroppableRule.isDroppable` 已如此。 |
| 持久證明 | `last_durable_epoch` + `segments[]` 是唯一必要證明；close 記錄只是最新 close 段的 backstop，不是第二必要條件。刪除「`lastDurableEpoch` 永遠不能代替 close 記錄」的相反註釋。 |
| 未關閉歷史 | 只指 `epoch > last_durable_epoch` 的保留段，或未列入 manifest 且含記錄的保留段；列在 manifest 且 `epoch ≤ last_durable_epoch` 的段不再阻塞快速路徑。 |
| 崩潰尾巴 | epoch 高於持久標記，或任何水位以上的記錄，仍走 tail replay 加全量校驗；`tailReplayNeeded` 明確保留此行為，不放寬。 |
| 未列入段 | 嚴格 §7.2：無水位以上 mutation → replay、stale、重新列入，**當次 recovery 不 unlink**；有 mutation → adopted tail；零長度 → 於新 manifest 持久後刪除。舊 Swift 已有 stale/adopted 分類，缺的是零長度的獨立分類（原本 newest 零長度被當 torn header、非 newest 直接 `WAL_CORRUPT`），本次補上。 |
| 刪除順序 | 不變：先 fsync 待刪段產生的 materialized 檔與父目錄（由呼叫端既有 D18 路徑保證）→ 原子寫不再列出它的 manifest → unlink 整段 → fsync `wal/`（§9、§7.1）。 |
| 歷史 close | 不補寫任何舊 epoch close，也不向舊 boot 的段追加（wal.md §1 第 29 行附近）。 |
| 配額 | 512 MiB、`enforceQuota` 觸發方式、`LogQuota` 皆不改。 |
| 備份屬性 | `response-log/`、`overlay-<boot>.tar`、`overlay-cache.tar` 設 `URLResourceValues.isExcludedFromBackup = true`；WAL、journal、steps、materialized、manifest 不設。response-log 的記錄／淘汰／重放不變（P05 none）。 |
| golden | 新增 `spec/v1/golden/wal/lifecycle/*.json`（5 個），Python checker 重算 expected；Swift 用真實 `RecoveryManager` 跑，Rust 用真實 `RecoveryPlan` 跑 §7.2 部分。 |
| 條款狀態 | 無 target→implemented 變更；§9 文字只是把既有 decided reading 寫明，語義不變。 |

Self-check（`spec/README.md` §5.1）：沒有新增第二種 manifest 表達、欄位、alias、錯誤碼或版本欄位；沒有放寬任何兩端都讀的訊息；沒有刪除或重用名稱。manifest 仍只由 `last_durable_epoch` + `segments[]` 表達持久 epoch。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old App 讀新 manifest | manifest format 1、成員與範圍不變；舊 Swift 只會更保守（它仍要求 close 記錄，所以不會回收舊段），不會讀錯或刪錯。 |
| new App 讀舊數據 | 第一次 boot 即套用新判定：列在舊 manifest 且 epoch ≤ `last_durable_epoch` 的無 close 段被回收；未列入的 217 依 §7.2 先 replay／重新列入，不在同一 boot 直接刪。之後的 boot 走快速路徑。 |
| new → new | 同一個判定由 `WALSegmentLifecycle.isDroppable` 提供給 recovery 與 live writer；manifest 寫入先於 unlink，崩潰落在 manifest 與 unlink 之間時，該段下次以 listed/missing 或 stale 安全處理。 |
| persisted old data → new／rollback | 舊 manifest、舊 WAL bytes 全部可讀；rollback 後舊 App 仍可讀新 manifest（format 不變），只是再次變慢、不會遺失資料。 |
| 升級後第一次啟動 | recovery 用 boot 時的 manifest watermark 判定可刪段，寫入不含它們的新 manifest 後 unlink；舊的無 close epoch 因此一次回收。未列入段若無新 mutation 只重新列入，下一次 boot 才可能回收；最新 close 段與 crash tail 不動。 |

- 版本／adapter 決定：無版本升版；不新增 adapter，因為 manifest 格式與欄位完全未變，Kotlin 已是目標讀法。
- 更新順序／回滾限制：Swift 可獨立先更新；Kotlin 不需要更新；Rust 只要不實作 unlink 就不受影響。回滾到舊 Swift 只會停止回收，不會使資料不可讀。
- `target`／`draft` 條款中，本次與仍保留的差異：無；本次只把 §9 的既有 decided reading 寫成明確句子。

## 4. 分工與證據

- **Swift WAL：** `Sources/PhoneDSHLog/WALSegmentLifecycle.swift`、`WALWriter.swift`、`RecoveryManager.swift`、`WALReader.swift`；測試 `Tests/PhoneDSHLogTests/RecoveryDurableEpochTruncationTests.swift`、`WALReaderTests.swift`、`WALWriterTests.swift`、`RecoveryFastPathTests.swift`、`RecoveryManagerTests.swift`。
- **Swift P05 備份屬性：** `Sources/PhoneDSHGateway/ResponseLog.swift`、`Sources/PhoneDSHLog/WorkspaceLogService.swift`；測試 `ResponseLogTests.swift`、`OverlayCacheTests.swift`。記錄、淘汰、重放程式碼未改。
- **Spec/golden：** `spec/v1/wal.md` §9 decided-here、`spec/v1/golden/wal/lifecycle/*`、`spec/v1/golden/README.md`、`spec/v1/tools/spec_golden.py`、`spec/v1/tools/test_spec_golden.py`、`spec/tools/cross_check.py`（golden reader 登記）。
- **Rust 端調查：** `shell/crates/pdsh-wal/src/recovery.rs` 明文是 classification-only planner：「this crate only classifies, never unlinks」；沒有 §9 quota／compaction／unlink 實作，因此若把「段回收」當成 Rust 端義務，答案是**不適用**，本輪不改 Rust 實作。為讓新 golden 被 Rust 真實執行，新增 `shell/crates/pdsh-wal/tests/lifecycle_golden.rs`，用真實 `RecoveryPlan` 驗證每個 fixture 的 §7.2 listed/adopt/stale/replay 分類與 bytes；§9 可刪判定由 Swift 與 Python checker 覆蓋。**GAP（登記一行）：Rust pdsh-wal 沒有 §9 可刪／quota/unlink 階段，故 lifecycle golden 的回收結果沒有 Rust 對應實作；不是本次 Swift 對齊造成的分歧，owner 為 P02 Rust，待 Rust 端長出 quota 階段時關閉。**
- **Kotlin：** `DroppableRule` 已是 manifest `listedLastMseq` + `durableEpoch` + `watermark` 讀法；未改 Kotlin 實作。Android WAL golden 測試若可跑，只記錄結果，不改程式。
- **Shared fixtures：** `spec/v1/golden/wal/lifecycle/` 五個案例（fast path、above-watermark replay、listed crash epoch above durable、stale re-list、adopted tail），另有 Swift synthetic 的 second-boot drop、unlisted zero-length、listed zero-length-above-watermark 反例。
- **Exact commands → PASS/FAIL/SKIP/INCOMPLETE/NOT_RUN、環境及證據位置：** 見 §6。
- **剩餘風險／未支援平台：** 真機 126 MB 副本的實測需主審查者設定 `PDSH_WAL_REPLAY_DIR` 後執行；本輪未在實機上驗證 7914 ms → 快速路徑的端到端時間。Rust 無 §9 回收實作（GAP 已記）。Kotlin 沒有段回收的 recovery 快速路徑程式（其 quota 在寫入路徑），本輪未改。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `wal-durable-epoch-truncation`（本凍結） | Coordinator | 把 §9 decided reading 寫明並讓 Swift 對齊；Kotlin 已符合，Rust planner 不執行回收。 | Swift WAL、Swift P05、spec/golden；Rust/Kotlin 僅記錄不改 |

## 6. 實測記錄

實作於 base `3781dbdc960ba0119edf64dec398d63c3492034e` 的工作樹，未提交。

| 檢查 | 命令 | 結果 |
| --- | --- | --- |
| Log | `swift test --disable-sandbox --filter PhoneDSHLogTests` | PASS，140 tests，2 skipped（含 opt-in 真機 replay、既有 skipped），0 failures；新增 `RecoveryDurableEpochTruncationTests` 5 tests 全過。 |
| Gateway | `swift test --disable-sandbox --filter PhoneDSHGatewayTests` | PASS，152 tests，0 failures；含 response-log 備份屬性測試。 |
| Kill | `swift test --disable-sandbox --filter PhoneDSHKillTests` | PASS，10 tests，0 failures（20 次強殺矩陣 25.9 s）。 |
| Spec | `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS；phone-spec（95 files, 0 error；237 tests OK），phone-cross-tree（8/8 invariants、87 mutation tests、registry byte-identical、schema diff 0 breaking）。 |
| Rust | `bash scripts/ci/check.sh --only phone-rust-tests` | PASS，2 s；`cargo test -p pdsh-wire -p pdsh-wal` 共 138 passed、1 ignored，包含新 `lifecycle_golden` 2 tests。 |
| Android WAL golden | `cd android && GRADLE_USER_HOME=/tmp/gradle-home JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=$HOME/Library/Android/sdk gradle :core:test --tests 'com.phonedsh.wire.NativeWalGoldenTest' --tests 'com.phonedsh.log.WalGoldenRecoveryTest' --tests 'com.phonedsh.log.WalReplayFixtureTest'` | NOT_RUN；sandbox 不允許寫 `~/.gradle`，改寫 `/tmp` 後 Gradle 9.8.2 無法解析 Android Gradle Plugin 8.7.3（Google/MavenRepo 不可達）。未改 Kotlin 程式。 |
| Real-device replay | `PDSH_WAL_REPLAY_DIR=<chat-host workspace> swift test --disable-sandbox --filter WALRealDeviceReplayTests` | NOT_RUN（本輪未提供真機副本；測試默認 skip，主審查者設定後執行並打印 recovery 秒數／fast path／回收段／bytes）。 |

Not verified: 真機 126 MB `chat-host` 副本的 7914 ms → 快速路徑端到端時間；Android JVM WAL golden 與 Kotlin `DroppableRule` 的執行（無 Java/Gradle 依賴快取）；Rust 的 §9 回收（未實作，GAP 已記）。
