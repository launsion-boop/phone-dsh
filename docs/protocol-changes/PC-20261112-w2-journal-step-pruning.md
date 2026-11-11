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
contract_revision: 見交接 head（本單與 spec 同一 commit）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - Trigger：`budgets.md` §5 的 Journal quota 行寫「Prune entries whose step is `journaled` and durable; still over → `Failed`」。但 `Sources/PhoneDSHLog/LogQuota.swift` 沒有可丟棄集合，`JournalLog` 到 64 MiB 就永久拒寫；`JournalLog` 的 `recoveredBodies` 每條都留在內存。`StepMachine` 也從不清理 `steps/`。這是規範已要求、實作缺失。
  - 期望：明確定義哪些 journal 條目與 `steps/` 記錄可刪、何時刪、用什麼原子順序、崩潰後如何恢復，並保證 `JOURNAL_ACK` 語義與「未 journaled 的步驟永不刪」不變。對應 GAP-38。
- **Coordinator / contract owner**：`contracts`。**Implementer**：`w2-stability`（`Sources/PhoneDSHLog/{JournalLog,LogQuota,LogSupport}.swift`、`Sources/PhoneDSHController/StepMachine.swift`、Bot Store、`PhoneDSHHost` 記憶採樣、`chat-status.log`）；不改 `spec/`。
- **Owning spec / fixtures**：[budgets.md](../../spec/v1/budgets.md) §8（新增）、§5（row 仍是 quota 權威）；[exec.md](../../spec/v1/exec.md) §7（新增）；[README.md](../../spec/README.md) §7 GAP-38；`golden/plan/retention.json`（9 valid／3 invalid），checker `plan_cases_check.py`。
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
  - `python3 spec/v1/tools/plan_cases_check.py` → PASS（6 files，0 error；retention 9 valid/3 invalid）。
  - `python3 -m unittest spec.v1.tools.test_plan_cases_check` → PASS（8 tests，含 prune-before-durable mutation）。
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（102 files，0 error）。
  - `swift test --filter 'PhoneDSHLogTests|PhoneDSHControllerTests'` → NOT_RUN（Linux 無 Apple Swift 工具鏈）。
- **未執行**：修剪後 kill 再恢復的 Swift runtime 測試、真機 8 小時穩定性、掉電；一律 NOT_RUN，由呼叫方在本機執行。
- **風險／GAP**：GAP-38 需 `w2-stability` 的單元測試與真機（進程被殺／掉電）證據才可關閉；在關閉前不得把 64 MiB 拒寫當成可接受行為。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結 journal/steps 修剪條件並登記 GAP-38 | all（contract freeze 公告） |
