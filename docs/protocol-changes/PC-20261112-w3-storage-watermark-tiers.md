<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-w3-storage-watermark-tiers — W3 storage reclamation, cache tiering and aggregate budget

## 0. 摘要

```yaml
change: PC-20261112-w3-storage-watermark-tiers
contracts: [P02, P03, P05, P17]
status: frozen
breaking: false
version_decision: 無 wire／proto 版本變更。WAL 的 droppable 定義不變，只把「每次 epoch close 成功後即可回收」寫成觸發；response-log 仍是 cache，新增「已 journaled+durable、非 Recovering、無續傳引用」的刪除條件與 `bodyLocation` 可選欄位（舊資料省略即 documents）；可重建內容移到 Library/Caches；budgets.md 新增 hostInternalBytes 總口徑與五級動作，所有絕對配額不變。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
contract_revision: 773fa69d081917adefc2a6ad114ee6d88b5832ce（spec/schema/golden 的凍結 commit；本單另存於其後的 docs commit）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - **WAL 回收。** 現況：`compactDroppableSegments()` 只在 `WALWriter` 與 `WorkspaceLogService` 的兩個超配額調用點；進程不重啟就一直漲到 512 MiB 才壓縮。期望：每次 epoch close 的 D18 step 5 成功（manifest durable、level-2 ACK 發出）之後，立刻回收所有符合 wal.md §9 的 droppable 段；droppable 條件一個都不放寬，512 MiB 仍是 fail-loud backstop。
  - **response-log body。** 現況：128 MiB LRU，沒有「step 已 journaled」的回收條件，body 長期留在 Documents。期望：只有「對應 step journaled 且 level-2 durable、宿主不在 Recovering、沒有續傳請求引用、entry 完整」時才刪 whole entry；replay 回 missing，不回 partial、不換成別的 response。已 durable 的 entry body 可移到 Library/Caches。
  - **分層。** 現況：overlay 快取、transcript 快照、部分 response body 都在 Documents，系統不會清。期望：可重建內容移到 `Library/Caches/pdsh/<workspace_id>/`；系統清掉後自動重建且不報錯；權威資料（WAL、materialized、journal、steps、未滿足條件的 response-log）留在原處；舊安裝一次性遷移、可重入。
  - **總預算。** 現況：各 store 配額相加超過 1 GB，超限直接 Failed，沒有 aggregate 口徑。期望：`Budgets.swift` 加 `hostInternalBytes` 與 `availableImportantBytes`，按五級表自動動作；0–2 靜默、3 只產出結構化信號、4 才給明確錯誤；永遠不自動刪 `home/`、`workspace/`、會話、未 journaled 步驟。
- **Coordinator / contract owner**：`contracts`。**Implementer**：`w3-storage`（`Sources/PhoneDSHLog`、`ResponseLog.swift`、`ModelGateway.swift`、`Budgets.swift`、`Sources/PhoneDSH`、`ProbeKit/{Backends,Storage}`、對應 tests）；不改 `spec/`。依賴 `w1-browse`、`w2-stability`、`w7-stream`。
- **Owning spec / fixtures**：[wal.md](../../spec/v1/wal.md) §12；[gateway-security.md](../../spec/v1/gateway-security.md) §11；[budgets.md](../../spec/v1/budgets.md) §9；`golden/plan/storage-levels.json`（5 valid／3 invalid），checker `plan_cases_check.py`。
- **受影響 producer / consumer**：P02 Swift `PhoneDSHLog`、Kotlin `android/core/**/log`、Rust `pdsh-wal`；P05/P17 `ResponseLog`／`ModelGateway`；P03 `Budgets`；probe app 的 container 路徑。TS `plugins/channel` 無 response-log 消費端。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| WAL 回收時機 | 只在超配額 → 每次 epoch close 成功後；manifest 先寫、再 unlink、再 fsync 被刪段產生的 materialized 檔／目錄。droppable 條件沿用 §9：全部 mseq ≤ watermark、epoch ≤ last_durable_epoch 且 listed、不是最新 close 段、不是 open epoch。 |
| 回收崩潰 | 未寫 → kill 在 level-2 ACK 與 unlink 之間只留下可再分類的段，下次 boot 再次回收；kill 在短 manifest 與 unlink 之間留下 unlisted 段，§7.2 stale replay + 重新列入，不靜默刪。 |
| response-log 刪除條件 | 只有 LRU → 加上 step journaled+durable、非 Recovering、無續傳引用、entry 完整；刪 whole entry；replay missing。partial 永不記、永不重播。 |
| response-log 位置 | 全部 Documents → 已 journaled+durable 的 entry 可移到 `Library/Caches/pdsh/<workspace_id>/response-log/`；entry 加可選 `bodyLocation`（documents/caches）。無 marker 的舊資料視為 documents，reader 先 documents 再 caches；cache 被清 → replay missing，不報錯、不重送非 replay-safe 寫。 |
| 可重建目錄 | 散落 Documents → `Library/Caches/pdsh/<workspace_id>/{overlay,transcript-snapshots,response-log}`。被系統清掉後 overlay 從 materialized 重建、snapshot 重抓、body 回 missing。 |
| 舊安裝遷移 | 無 → 一次性、後台、可重入；遷移期間只讀瀏覽可用；新佈局校驗通過前不刪任何舊資料。transcript 快照舊路徑 `Documents/transcript-snapshots/` 仍可讀，成功寫新路徑後才刪舊檔。 |
| 總口徑 | 無 → `hostInternalBytes` = WAL + materialized + journal + steps + exec + 未可刪 response-log + overlay cache + transcript snapshots；`availableImportantBytes` = 重要用途可用容量（沒有時用 volume available）。 |
| 級別 0 | 無 → 每次 epoch close 回收 droppable WAL 與符合條件的 response entry；靜默。 |
| 級別 1 | 無 → `hostInternalBytes > 1.3 × workspaceLogicalBytes`：先做 level 0，再清 caches／cold snapshots，按需重建；靜默。門檻是 policy default，不是量測。 |
| 級別 2 | 無 → `availableImportantBytes < max(512 MiB, 10% volume)` 或系統低空間：更激進清可重建內容，暫停新建快取；不動 §5 權威 store 的自身規則；靜默。 |
| 級別 3 | 無 → `workspaceLogicalBytes ≥ 90% workspace bucket`：產出一個結構化信號（最大檔案與大小），App 在回合結束後出卡，每 workspace 每天至多一次。 |
| 級別 4 | 無 → 已無可回收且下一次寫入會失敗：明確 quota error，說明原因與處理辦法；沿用既有 quota 錯誤詞彙，不加第二種錯誤碼。 |
| 永不刪 | 未變 → `home/`、`workspace/`、會話、未 journaled 步驟永不自動刪；只刪可重建內容。 |
| 配額 | 不變 → WAL 512 MiB、response log 128 MiB、journal 64 MiB、video、domain stores 全部沿用 §5；aggregate 不是第二個 quota。 |

自檢（baseline §5.1）：droppable 條件沒有放寬（只改觸發時機）；response entry 是 cache 不是第二權威；`bodyLocation` 是可選、有缺省（documents）的新 member；沒有新增第二個錯誤碼；沒有刪除既有路由或 quota 名稱。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊 WAL／response log 照舊讀。新端第一次 boot 看到的舊 response entry 沒有 `bodyLocation`，視為 documents；舊 transcript 快照從舊路徑讀。舊 WAL 段在第一次 close 後才被回收（如果當時已 droppable），不影響舊資料可讀。 |
| new → old | 新端沒有改 WAL record 或 manifest schema；舊端讀同一段。response 新 entry 多一個舊端不認得的 `bodyLocation`；舊端忽略 unknown member 並在 documents 找，若 body 已移到 caches，舊端 replay missing（response log 本來就不是權威）。舊端不認得 Caches 佈局，但不會刪它。 |
| new → new | 兩端用同一 droppable 條件、同一刪除條件、同一五級表；storage-levels fixture 是 oracle。 |
| persisted old data → new／rollback | 無 WAL/response 格式 migration；cache 搬家是檔案位置，不是 bytes。遷移可重入：中斷後 boot 重新掃描、校驗新佈局後才刪舊檔。回滾到舊版：WAL、materialized、journal、steps 不動；Caches 目錄被忽略；response 在 documents 的 entry 照舊。不得在回滾時刪 Caches 或把 body 搬回去。 |

- **版本決定**：無 proto／wire 版本變更。`bodyLocation` 是 response-log cache 的可選 member；WAL format 1、manifest schema、segment 名稱、mseq 域不變。`Library/Caches` 是平台/路徑決定，不進 wire。
- **部署順序**：`w3-storage` 在 `w1-browse`、`w2-stability`、`w7-stream` 之後；遷移必須在後台完成，期間 W1 的只讀瀏覽照常可用。Swift 先行，Kotlin/Rust 只跟隨 WAL 回收時機（bytes 不變）。
- **仍保留的差異**：Kotlin/Rust 的回收時機實作尚未開始；冷會話壓縮只做調研報告（`docs/research/cold-session-compression-20261112.md`），本輪不實現。

## 4. 分工與證據

- **獨占路徑（contracts）**：`spec/v1/wal.md` §12、`spec/v1/gateway-security.md` §11、`spec/v1/budgets.md` §9、`golden/plan/storage-levels.json`、checker、本單。
- **w3-storage 路徑**：`Sources/PhoneDSHLog/**`、`Sources/PhoneDSHGateway/{ResponseLog,ModelGateway}.swift`、`Sources/PhoneDSHController/Budgets.swift`、`Sources/PhoneDSH/**`、`examples/probe-app/ProbeKit/{Backends,Storage}/**`、`Tests/PhoneDSH{Log,Gateway,Controller}Tests`、`Tests/PhoneDSHTests`、`docs/research/**`。不得改 `spec/`。
- **共享 fixtures**：`storage-levels.json` 5 個級別與 3 個 negative（level 3 降級、靜默級別出錯、刪 home）；positive 也檢查 `expectedActions` 與 `userSurface`。
- **Exact commands → result**（Linux 容器）：
  - `python3 spec/v1/tools/plan_cases_check.py` → PASS（storage-levels 5 valid/3 invalid）。
  - `python3 -m unittest spec.v1.tools.test_plan_cases_check` → PASS（含 level 3 降級 mutation）。
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（102 files，0 error）。
  - `swift test --filter 'PhoneDSHLogTests|PhoneDSHGatewayTests|PhoneDSHControllerTests'` → NOT_RUN（Linux 無 Apple Swift 工具鏈）。
- **未執行**：30 天等效負載、真機 Caches 被清空、遷移中途被殺、WAL kill 矩陣、`scripts/perf` 容器大小統計（若 `w0-baseline` 已提供）——一律 NOT_RUN，由 `w3-storage` 與呼叫方執行。
- **風險／GAP**：1.3× 與 level-2 512 MiB/10% 是 policy default，不是量測；若真機基線顯示不合理，需以新 revision 改常數。response log 在 Caches 被清後 replay missing 是預期，但非 replay-safe 寫不得因此重送。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結回收時機、response 刪除、Caches 分層與五級預算 | all（contract freeze 公告） |
