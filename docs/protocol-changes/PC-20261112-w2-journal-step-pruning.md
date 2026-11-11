<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-w2-journal-step-pruning — W2 journal and step-record pruning

## 0. 摘要

```yaml
change: PC-20261112-w2-journal-step-pruning
contracts: [P03, P17]
status: frozen
breaking: false
version_decision: 無版本變更。把 budgets.md §5 既有的「修剪 journaled 且 durable 的 journal 條目」寫精確，並把 exec.md §4 的 step 記錄收斂條件寫下；不改 journal 線格式、不改 jseq 域、不改 JOURNAL_ACK 語義、不放寬 64 MiB 配額。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
contract_revision: spec/v1/budgets.md@2026-11-12-rev2 + spec/README.md@GAP-39 + spec/v1/golden/plan/memory-input.json@rev1（rev 1 spec commit 773fa69d081917adefc2a6ad114ee6d88b5832ce；rev 2 freeze commit 見交接 head）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - Trigger：`budgets.md` §5 的 Journal quota 行寫「Prune entries whose step is `journaled` and durable; still over → `Failed`」。但 `Sources/PhoneDSHLog/LogQuota.swift` 沒有可丟棄集合，`JournalLog` 到 64 MiB 就永久拒寫；`JournalLog` 的 `recoveredBodies` 每條都留在內存。`StepMachine` 也從不清理 `steps/`。這是規範已要求、實作缺失。
  - 期望：明確定義哪些 journal 條目與 `steps/` 記錄可刪、何時刪、用什麼原子順序、崩潰後如何恢復，並保證 `JOURNAL_ACK` 語義與「未 journaled 的步驟永不刪」不變。對應 GAP-38。
- **Coordinator / contract owner**：`contracts`。**Implementer**：`w2-stability`（`Sources/PhoneDSHLog/{JournalLog,LogQuota,LogSupport}.swift`、`Sources/PhoneDSHController/StepMachine.swift`、Bot Store、`PhoneDSHHost` 記憶採樣、`chat-status.log`）；不改 `spec/`。
- **Owning spec / fixtures**：[budgets.md](../../spec/v1/budgets.md) §8（新增）、§5（row 仍是 quota 權威）、§3（rev 2：engine-memory input sources）；[exec.md](../../spec/v1/exec.md) §7（新增）；[README.md](../../spec/README.md) §7 GAP-38（修剪）與 GAP-39（缺少 heap probe）；`golden/plan/retention.json`（9 valid／3 invalid）與 `golden/plan/memory-input.json`（2 valid／6 invalid），checker `plan_cases_check.py`。
- **受影響 producer / consumer**：P03 Swift controller/journal、`PhoneDSHLog`；Kotlin `android/controller/**` 與 `android/dsh/**/journal`；`plugins/tool-journal` 的 journal 條目寫入端。所有端都讀同一批 retention fixture。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| Journal 可刪條件 | 「journaled 且 durable」→ 同時要求：completed record 存在且 state `journaled`、該 record 已 level-2 durable（JOURNAL_ACK level 2 或後續 epoch close 覆蓋）、沒有 open recovery 持有、沒有 retained `start` 需要它。缺 terminal record 的 step 永不刪。 |
| 刪除單位 | 未定義 → 整個 entry 刪除；不得半刪、不得改寫欄位、`jseq` 永不复用。 |
| Step 可刪條件 | `StepMachine` 從不清理 → 最後一行是終態（`journaled` 或 `abandoned`），且對應 journal record durable 或 abandonment durable；沒有 live exec/dedup replay 引用；先整檔重寫只留存活行。open step 的最新行與定位行永不刪。 |
| 何時 | 只說「still over」→ 每次成功 epoch close（D18 step 5 之後）與 quota overflow 的 fail-loud 之前；全程靜默，不新增提示。 |
| 原子性 | 未定義 → `*.tmp` + fsync + rename + 目錄 fsync；rename 前任一點被殺留舊檔，rename 後留新檔；`Recovering` 不修剪。torn final line 載入時忽略、重寫時移除。 |
| `JOURNAL_ACK` | 不變 → level 1 仍是 append `write()`、level 2 仍是 checkpoint/epoch fsync；修剪不發 ACK、不降低已發出的 level、不刪未 durable 的 record。修剪後 entry 只是不再 replay，不是「已確認卻遺失」。 |
| `recoveredBodies` | 無界 → 只保留尚未 journaled+durable 的 body；修剪時同步丟棄，不得無界增長。 |
| 配額 | 64 MiB 不變；仍超限才 `Failed`。不得以提高配額或 `Failed` 取代修剪。 |
| 用戶可見 | 無新增；不因修剪出任何提示、banner 或 disabled 狀態。 |

自檢（baseline §5.1）：沒有新增第二種 journal 格式或第二個 ACK 級別；沒有刪除既有 member；沒有把 quota 放寬。`exec.md` §7 與 `budgets.md` §8 是同一規則的兩端敘述，不是兩套門檻。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊 journal 檔不需 migration：新端照舊讀，只是開始在某個 epoch close 後刪掉符合條件的 entry。舊端若讀到被新端修剪過的同一個 workspace（回滾），只會少掉已 durable 的 entry，replay 不會重跑；未終態 entry 仍在。 |
| new → old | 新端沒有改 journal 行格式或 jseq 域；舊端讀同一檔案。舊端的 `JOURNAL_ACK` 語義不變。被刪的 entry 對舊端等於「沒有這個 entry」，不會誤判為 corruption。 |
| new → new | 兩端用同一 retention fixture（journal 9 種、step 5 種組合）與同一原子重寫順序；修剪後 kill 再恢復的測試是必要證據。 |
| persisted old data → new／rollback | 無格式 migration。舊資料（已 journaled+durable）可在第一次 close 後被刪；未終態或未 durable 的資料一定留著。回滾不重建被刪的 entry，但因為已 durable，工具結果不變。 |

- **版本決定**：無。journal 行格式、`jseq`、`JOURNAL_ACK` 都不變；`budgets.md`／`exec.md` 只把既有語義寫精確。
- **部署順序**：`w2-stability` 可與 contract freeze 分開落地；修剪必須在 manifest/epoch close 成功之後，否則會刪掉未 durable 的資料。Swift、Kotlin、tool-journal 三端可獨立更新，因為沒有新 bytes。
- **仍保留的差異**：Kotlin 與 tool-journal 目前沒有對應的修剪實作，本輪 `not started`；不得用 Swift unit test 宣稱三端已完成。

## 4. 分工與證據

- **獨占路徑（contracts）**：`spec/v1/budgets.md` §8、`spec/v1/exec.md` §7、`spec/README.md` GAP-38、`spec/v1/golden/plan/retention.json`、checker 與其 mutation test。
- **w2-stability 路徑**：`Sources/PhoneDSHLog/{JournalLog,LogQuota,LogSupport}.swift`、`Sources/PhoneDSHController/StepMachine.swift`、`Sources/PhoneDSHBot/Store/**`、`Sources/PhoneDSH/PhoneDSHHost.swift`、`Sources/PhoneDSH/Background/**`、`Tests/PhoneDSHLogTests`、`Tests/PhoneDSHControllerTests`、`Tests/PhoneDSHBotTests`、`Tests/PhoneDSHTests`。不得改 `spec/`。
- **共享 fixtures**：`golden/plan/retention.json`；checker 以 `journaled`/`durable`/`referenced`/`terminal`/`abandonedDurable` 五個輸入算出 keep/prune，negative 必須真的違反同一條件。
- **Exact commands → result**（Linux 容器）：
  - `python3 spec/v1/tools/plan_cases_check.py` → PASS（7 files，0 error；retention 9 valid/3 invalid；memory-input 2 valid/6 invalid）。
  - `python3 -m unittest spec.v1.tools.test_plan_cases_check` → PASS（11 tests，含 prune-before-durable、sampled-heap、action-order mutations）。
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（103 files，0 error）。
  - `swift test --filter 'PhoneDSHLogTests|PhoneDSHControllerTests'` → NOT_RUN（Linux 無 Apple Swift 工具鏈）。
- **未執行**：修剪後 kill 再恢復的 Swift runtime 測試、真機 8 小時穩定性、掉電；一律 NOT_RUN，由呼叫方在本機執行。
- **風險／GAP**：GAP-38 需 `w2-stability` 的單元測試與真機（進程被殺／掉電）證據才可關閉；在關閉前不得把 64 MiB 拒寫當成可接受行為。

## 5. Rev 2 — memory input amendment, 2026-11-12

Status: **frozen**（rev 2）。Trigger: `w2-stability` 的 CONTRACT CHANGE REQUEST（lead 已接受）。
Scope: 只改契約與 fixtures；不改實作、不改任何數字預算、不改 wire/schema/持久化資料。

### 5.1 Trigger → 現況 → 期望

- **Trigger.** W2 第 3 項要求把 `PhoneDSHHost.reportEngineHeapBytes` 接上生產的 engine heap 採樣路徑，並加系統內存警告處理，動作沿用 `clearTmp → plannedRestart`。
- **現況.** 倉庫沒有生產 heap producer：`PhoneDSHEngine` 沒有公開 heap probe（`evaluateJavaScript` 為 private），`WebEngineScripts` 只有 console/boot，`reportEngineHeapBytes` 的每個調用者都是測試。實作端只能接上平台記憶體警告；sampled heap 這條輸入無法在不改 `Sources/PhoneDSHEngine`（超出該單元路徑）或不發明新 bridge message 的前提下完成。
- **期望.** 契約明確區分「本輪唯一生產輸入 = 系統記憶體警告」與「sampled heap = `target`，等 P04 只讀 probe」；不把缺樣本當成 0 或 headroom，不因此提高預算，也不新增用戶提示。GAP-39 追蹤缺少的 probe 與 seam。

### 5.2 CCR 原文（w2-stability → lead/all，已接受）

```text
CONTRACT CHANGE REQUEST (w2-stability)
Contract: P03 @ e654fe99 / spec/v1/budgets.md §3 (memory proxy input)
Problem: W2 asks to connect reportEngineHeapBytes to a production engine heap sampling path. The repository has no such producer: PhoneDSHEngine exposes no public heap probe (evaluateJavaScript is private), WebEngineScripts only carries console/boot, and every reportEngineHeapBytes caller is a test. Implementing a probe would require editing Sources/PhoneDSHEngine (outside this unit) or inventing a new bridge message. This unit therefore wired the platform memory-warning adapter and the existing clearTmp→plannedRestart order (clearTmp is a no-op because /dsh/tmp is Worker-volatile and never materialized, documented in code), but the sampled-heap input remains unimplemented.
Proposal: add a read-only WebContent heap probe to the P04/P08 seam (e.g. a WebEngine method backed by performance.memory), or state in budgets.md that a system memory warning is the only engine-memory input until that seam exists. Affects: PhoneDSHEngine/P04, P08, App caller.
```

### 5.3 決定

1. **本輪唯一生產輸入是系統記憶體警告**（平台 memory warning / `DispatchSource` 等價物）。`clearTmp → plannedRestart` 的既有順序不變；`clearTmp` 在 `/dsh/tmp` 是 Worker-volatile、永不 materialize 的前提下是 no-op，這一點照實記錄，不假裝有回收效果。
2. **`reportEngineHeapBytes` 保留為 injection point**：測試與未來的 P04 probe 都經它注入；它目前沒有生產調用者，不得在報告中寫成「已接上」。
3. **sampled heap 是 `target`**：`budgets.md` §3 的 memory-proxy 列與 §4 的 sampled-engine-heap 句子仍是未來規則，但本輪不可用、不宣稱、不作為准入或預算動作的輸入。缺樣本不得解讀為 0、headroom 或提高預算的理由。
4. **無用戶可見變化**：不新增提示、banner、錯誤或禁用態。
5. **GAP-39 已登記**（`spec/README.md` §7）：缺的是 P04 只讀 WebContent heap probe 與其 seam；在 probe 落地並以真機 sampled heap + warning 兩條輸入驗證前，sampled heap 保持 `target`。

### 5.4 若要接上 sampled heap（本輪明確 out of scope）

需要一個 P04 **只讀** WebContent heap probe，最小形狀是：

- `PhoneDSHEngine` 的公開 API（目前 `evaluateJavaScript` 是 private），回傳 sampled bytes 或明确的 unavailable，不暴露頁面內容或憑證；
- Worker 端 JS 讀 `performance.memory.usedJSHeapSize`（或等價的 runtime heap 指標），在既有 bridge 上做一次唯讀查詢；不新增第二種 envelope、不加可寫入能力；
- 對應測試：正常 sample、probe 不可用時回 unavailable、不因缺值而觸發預算動作、跨 WebContent 重啟後不沿用舊 sample；
- 真機證據：sampled heap 與 system warning 兩條輸入分別與同時觸發時，`clearTmp → plannedRestart` 的順序與零提示不變。

上述任一項都需要改 `Sources/PhoneDSHEngine` 與 P04 bridge，超出 W2 單元；本輪不實作，交由 GAP-39 追蹤。

### 5.5 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊版沒有 sampled heap producer，本來就只靠系統警告；新契約把這件事寫明，不改變舊版行為。`reportEngineHeapBytes` 仍是同一個 injection point，舊測試呼叫不受影響。 |
| new → old | 新契約沒有新增 wire member、schema、環境變數或持久化欄位；舊版讀不到 sampled heap 時照舊只處理系統警告。 |
| new → new | 兩端都只把系統警告當生產輸入；sampled heap 在 GAP-39 關閉前維持 `target`，不得一端自行接上並要求另一端。 |
| persisted old data → new／rollback | 不適用：沒有格式、migration 或配額數字變更。回滾只需忽略本註記；`budgets.md` 的數字與既有條款未改。 |

**版本決定**：無版本變更。`budgets.md` 只新增 input-source 段落（306 行，仍在 D16 cap 320 內，無需改 cap）；`spec/README.md` 新增 GAP-39；新增 `golden/plan/memory-input.json`（2 valid／6 invalid）並把 `memory-input` 加入 `plan-cases.schema.json` 的 vector enum。沒有新 wire field、沒有放寬 schema、沒有刪除或弱化既有條款。

## 6. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結 journal/steps 修剪條件並登記 GAP-38 | all（contract freeze 公告） |
| 2（本檔） | contracts | 接受 w2-stability 的 CONTRACT CHANGE REQUEST：本輪 engine-memory 生產輸入只有系統記憶體警告，sampled heap 維持 `target`，新增 GAP-39 與 `memory-input` fixture | all（amendment 公告） |
