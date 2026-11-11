<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-w1-browse-outbox — W1 read-only session projection and durable send outbox

## 0. 摘要

```yaml
change: PC-20261112-w1-browse-outbox
contracts: [P02, P06, P18]
status: frozen
breaking: false
version_decision: 無 wire／proto 版本變更。新增的是「materialized/home/sessions 的只讀投影」邊界登記與 host 端持久 outbox 的磁盤格式；materialized 寫入禁令不變，outbox 是新的 host 私有持久資料，rpcId 為訊息本身的 `source.rpcId`，不改 P01 frame、P06 event 或 P18 既有設定鍵。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
contract_revision: 見交接 head（本單與 spec 同一 commit）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - **只讀投影（P02/P18）。** 現況：W1-A 需要瀏覽會話時直接讀宿主 `materialized/home/sessions/`，但 v3 的硬約束是「禁止直接操作 materialized/」，沒有任何條款登記例外的讀者、範圍與新鮮度；各端只能猜。期望：在 `wal.md` §11 登記唯一的只讀投影：只有 App 的 UI／model 層與既有 Bot `phone record` 路徑可讀，只讀 `materialized/home/sessions/**`，絕不寫入、刪除、移動、rename、chmod；資料是 materialized 快照，可能落後 WAL／Worker 內存最多一個 epoch，不是進行中回合的權威；引擎就緒後用既有 `session/list`、`session/page` 增量對齊，引擎為準。
  - **持久 outbox（P06）。** 現況：發送先落內存陣列 `queuedPromptsDuringRecovery`；引擎未起或傳輸中斷時消息可能不在時間線，崩潰會丟失。期望：發送先落盤並立即顯示 `queued`，以入隊時生成的 UUIDv4 `rpcId` 投遞；狀態機 `queued → submitting → accepted → durable` 加 `outcomeUnknown`；只有在權威歷史看到同一 `rpcId` 的 user_message 才刪；傳輸中斷先回讀核對再決定，不盲目重送。
- **Coordinator / contract owner**：本單元 `contracts`。**Implementers**：`w1-browse` 只改 probe app 的 Chat／Session／抽屜與 `ProbeKit/Transcript`、`ProbeKit/Outbox`、`ProbeKit/Lifecycle`、`PhoneDSHSimTests`；不改 `spec/`、不改 `Sources/`。
- **Owning spec / schema / fixtures**：
  - [wal.md](../../spec/v1/wal.md) §11（只讀投影）。
  - [host/v1/README.md](../../spec/host/v1/README.md) §10（持久 outbox）；[outbox-entry.schema.json](../../spec/host/v1/schema/outbox-entry.schema.json)；正向 golden `outbox-entry-queued.json`、`outbox-entry-outcome-unknown.json`；負向 `tools/outbox_invalid_cases.json` 與 `tools/test_outbox_contract.py`（UUID、欄位、五個非法轉移）。
  - `spec/v1/tools/spec_golden.py` 的 §5.2 上限修訂（wal.md 416 → 510，W1／W3／W4 共用）。
- **受影響 producer / consumer**：
  - App/Swift：`ChatModel`、`SessionsPage`、`DSHManagementModel`、`ProbeKit/Transcript`、`ProbeKit/Outbox`、`ProbeKit/Lifecycle`；引擎 RPC 仍由 host 提供。
  - host contract P06：Kotlin `android/core/**` 目前沒有這個 outbox，另一支 App 端必須跟隨；本輪不宣稱 Kotlin 已實作。
  - P18：`materialized/` 不是設定檔；新增的 outbox 不寫進 UserDefaults，也不是 `dsh/home/*.json`。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 只讀投影的讀者 | 無 → App 的 UI／model 層（`ProbeKit/Transcript`）與既有 Bot `phone record`。Worker、device、remote host、任意進程不可透過此例外讀。 |
| 只讀範圍 | 無 → `materialized/home/sessions/**`；`materialized/workspace/**` 不在例外內。開啟方式只讀，禁止 create/write/append/truncate/delete/move/rename/chmod。 |
| 新鮮度語義 | 無 → materialized 快照，可能落後 WAL 與 Worker 內存最多一個 open epoch；不是進行中回合的權威；torn final line 忽略；檔案被 rename/remove 時重試或回退；不修復、不對账。 |
| 引擎對齊 | 無 → 引擎 ready 後用既有 `session/list`、`session/page` 增量對齊；引擎與投影不一致時以引擎為準；starting/failed/absent 不阻塞投影。 |
| 不作為輸入 | 無 → 投影不得用於重建 VFS mutation、WAL record、journal 決策或 durable marker。 |
| outbox 檔案 | 內存陣列 → `send-outbox/<rpcId>.json`，每筆一檔；temp + fsync + rename + dir fsync，先落盤再投遞。 |
| `rpcId` | 無 → 入隊時生成的 lowercase UUIDv4，終身不變；是 user_message 的 `source.rpcId`，權威端用它去重。 |
| 狀態機 | 無 → `queued → submitting → accepted → durable`，加 `submitting → outcomeUnknown`；只允許 `outcomeUnknown → accepted`（回讀找到）與 `outcomeUnknown → queued`（回讀證明不存在）。`durable` 之後刪檔。 |
| 刪除條件 | 無 → 僅當權威歷史出現同 `rpcId` 的 user_message 且 entry 為 `durable`；本地 accepted 不夠；`outcomeUnknown` 未解決不刪。 |
| outcomeUnknown | 無 → 傳輸中斷後不自動重送；先回讀權威歷史，找到 → accepted/durable，可證明不存在 → 同 `rpcId` 回 queued，回讀不可用 → 停留並停止重送。 |
| 排序與崩潰點 | 無 → 同 session 按 `createdAtMs` FIFO；session 間獨立；五個 kill 點（落盤前、落盤後未投遞、投遞中、accepted 未 durable、durable 未刪）不丟不重。啟動掃描 `send-outbox/` 續跑，不生成新 `rpcId`。 |
| 用戶可見 | 無 → 只新增既有的「排队中」投影；不再以「引擎还没启动」或「请先等待当前回合结束」拒絕查看／發送。這兩條文案的移除由 W1 實作端完成，但契約只登記 outbox 狀態與投影邊界。 |
| unknown field／version | outbox 是新增 host 私有格式 `v:1`；舊 App 沒有這個目錄，忽略即可。無 enum／錯誤碼新增。 |

自檢（baseline §5.1）：投影不是第二份會話權威，而是 §6 materialized 副本的視圖；outbox 沒有第二個 envelope、沒有第二個 idempotency key（就是 `source.rpcId`）；沒有刪除或改名任何既有 member；沒有放寬 materialized 的寫入禁令。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊 App 不讀投影、不寫 `send-outbox/`；新 App 讀舊 `materialized/` 與舊 UserDefaults 不受影響。舊 App 沒有 outbox 時，新 App 也不會假造一筆。 |
| new → old | 新 App 產生的 materialized 檔案仍是同一 v1 會話 JSONL；舊 App 照舊讀。`send-outbox/` 是舊 App 不認得的新目錄：舊 App 忽略它，不刪、不動；回滾後新 App 的排隊訊息不會由舊 App 投遞，但檔案仍在，重新升級可續跑。 |
| new → new | 兩端都遵守同一 `rpcId` 與 state machine；權威端以 `source.rpcId` 去重，崩潰後重播同一個 `rpcId` 不會重複。 |
| persisted old data → new／rollback | materialized 沒有 migration，仍是 §6 格式。outbox 是新資料：升級時目錄不存在即空；回滾不刪除它，但舊 App 不投遞。不得把內存 `queuedPromptsDuringRecovery` 遷移成 outbox 而不經使用者可見的 queued 狀態（本輪不遷移，舊陣列清空）。 |

- **版本決定**：無 proto／wire 版本變更；`proto 1`、P06 event、P18 既有鍵、materialized v1 不變。outbox 是 host 私有 `v:1`，不是 P01 frame。
- **部署順序**：App 與 Worker 可獨立更新；投影與 outbox 只在 App 端，Worker 不需要知道。PC 工作區（`pcRuntime != nil`）行為不變。
- **仍保留的差異**：Kotlin/Android 沒有這個 outbox 與投影讀取器，本輪 `not started`；不得用 Swift 測試宣稱 Kotlin 已實作。

## 4. 分工與證據

- **獨占路徑**：`spec/v1/wal.md` §11、`spec/host/v1/{README.md,schema/outbox-entry.schema.json,golden/outbox-entry-*.json,tools/outbox_invalid_cases.json,tools/test_outbox_contract.py}`、`docs/protocol-changes/PC-20261112-w1-browse-outbox.md`。
- **w1-browse 路徑**：`examples/probe-app/PhoneDSHProbe/{ChatModel,ChatPage,ChatEngineStoppedNoticePolicy,HomeDrawer,HomeDrawerNewSessionPolicy,HomeDrawerSwitchPolicy,SessionsPage,DSHManagementModel}.swift`、`examples/probe-app/ProbeKit/{Transcript,Outbox,Lifecycle}`、`examples/probe-app/PhoneDSHSimTests`。不得改 `Sources/` 或 `spec/`。
- **共享 fixtures**：outbox 正向 2 筆、負向 10 筆（5 schema、5 transition）；`test_outbox_contract.py` 同時驗 schema 與狀態機。
- **Exact commands → result**（Linux 容器）：
  - `python3 spec/host/v1/tools/host_check.py --root .` → PASS（45 files，0 error）。
  - `python3 -m unittest discover -s spec/host/v1/tools -p 'test_*.py'` → PASS（31 tests）。
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（102 files，0 error）。
  - `swift test --filter PhoneDSHSimTests` → NOT_RUN（Linux 沒有 Xcode/Swift Apple 工具鏈；由呼叫方在本機執行）。
- **未執行**：iOS 真機的 0.5 秒切換、10 連切、5 崩潰點實測；XCTest、xcodebuild、XCUITest 一律 NOT_RUN。
- **風險／GAP**：投影的新鮮度只到「最多一個 epoch 落後」，進行中回合的顯示仍可能落後；W1 驗收需真機證明。outbox 的 `outcomeUnknown` 回讀來源必須是與 `durable` 判定相同的權威歷史，不得用本地快取冒充。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結只讀投影與持久 outbox | all（contract freeze 公告） |
