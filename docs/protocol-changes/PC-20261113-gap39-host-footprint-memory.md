<!-- SPDX-License-Identifier: MIT -->
# PC-20261113-gap39-host-footprint-memory — R1：engine-memory 輸入改為宿主 `phys_footprint` ＋ 記憶體壓力警告

## 0. 摘要

```yaml
change: PC-20261113-gap39-host-footprint-memory
contracts: [P03]
status: frozen
breaking: false
version_decision: 無版本變更。這是宿主側輸入來源與條款措辭的修訂：`proto 1`、WAL `format 1`、manifest、channel 幀、任何 schema／golden／持久化位元組都不動；`budgets.md` §4 的所有既有數字、`clearTmp → plannedRestart` 動作順序與零提示都不變。sampled engine heap 由「等待 producer」改記為**永久 `target`**，不是把它宣告成已實現。
base: f6b447dfbc83f6e768a5c802184013d2c9b67e26
contract_revision: 本單所屬 commit（R1 freeze）——`spec/v1/budgets.md` §3／§4、`spec/v1/golden/plan/memory-input.json`、`spec/v1/tools/plan_cases_check.py`、`spec/v1/tools/test_plan_cases_check.py`、`spec/v1/schema/plan-cases.schema.json`（description）、`spec/README.md` §7 GAP-39
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** `perf-stability-20261111` 的 W2 把 sampled engine heap 降為 `target`、以系統記憶體警告作唯一生產輸入（`budgets.md` §3 rev 2）。問題是 §3／§4 的 engine-memory 輸入在 iOS 上**根本不可觀測**：WKWebView 的 WebContent 是獨立進程、宿主沒有公開 API，WebKit 也沒有 `performance.memory`（GAP-39 的關閉條件正是要求它，因此永遠做不出來）。期望：把輸入換成**宿主進程 `phys_footprint`（`task_info`／`TASK_VM_INFO`）＋記憶體壓力警告（`DispatchSource.makeMemoryPressureSource`）**，刪掉不可實作的 `performance.memory` 路徑，並用一句話明確記錄「WebContent 進程記憶體不可觀測；sampled engine heap 永久留在 `target`，不得被當成已實現」。
- **Coordinator / contract owner**：`contracts-1113`（本 worktree，唯一能改 `spec/` 與 `docs/protocol-changes/`）。**Implementer（下一單元）**：`perf-r1`（Swift `Sources/PhoneDSH/**` 的 footprint 取樣器與 `Sources/PhoneDSHController/**` 的預算讀取端；Kotlin `android/controller/**` 對齊）。實作者不改 `spec/`。
- **Owning spec / fixtures / schema**：[budgets.md](../../spec/v1/budgets.md) §3（memory proxy 列與 input-source 段落）、§4（memory-proxy bullet 與其數字列）；`golden/plan/memory-input.json`（2 valid／12 invalid）；checker [`plan_cases_check.py`](../../spec/v1/tools/plan_cases_check.py) 的 `memory_input_problem`；envelope schema `schema/plan-cases.schema.json`（本次只改 description，不動結構）。**沒有 wire、沒有持久化格式、沒有新 schema 成員。**
- **受影響 producer／consumer**：
  - **P03 Swift controller**：`Sources/PhoneDSHController/Budgets.swift`（`heapExceeds` 讀 sample）、`Signals/PlatformHostSignals.swift`（`engineHeapBytes` 注入閉包，預設 `{ nil }`）、`RestartPolicy.swift`（75% × tier、連續 3 個 1 分鐘樣本 → `heapPressure`）。這幾處的**契約不變**；變的是被餵進來的量。
  - **P03 Swift host**：`Sources/PhoneDSH/PhoneDSHHost.swift`（`currentEngineHeapBytes`／`reportEngineHeapBytes` 仍是注入點，`reportEngineHeapBytes` 維持 test-only；footprint 由新取樣器提供，實作單落地）。
  - **P03 Kotlin controller**：`android/controller/src/main/**` 的預算/訊號讀取端；同一份 §3／§4 語義，不得自行新增第二種輸入。
  - **P04**：**無 delta**。不新增 bridge kind、不改 handler、不改 `WebEngineScripts`；R1 只是承認「從頁面讀 heap」在 WebKit 上不存在。
  - **未被本修訂要求**：`examples/probe-app/ProbeKit/ProcessMetrics.swift` 是本倉既有的 `phys_footprint`（`task_info`/`TASK_VM_INFO`）與 `os_proc_available_memory()` 實作，但它在 probe app target，SwiftPM 的 `PhoneDSH` 不能 import；等價程式碼放哪裡屬實作單（P12 只影響放哪個模組），本單不指定。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| memory proxy 的 engine-memory 輸入 | 唯一生產輸入＝系統記憶體警告；sampled engine heap 是「等 producer 的 `target`」 → **兩個生產輸入**：記憶體壓力警告（`DispatchSource.makeMemoryPressureSource`／`didReceiveMemoryWarning`）＋宿主進程 `phys_footprint`（`task_info`／`TASK_VM_INFO`）。依據 §3 input-source 段落（R1）。 |
| footprint 的計帳位置 | 無此輸入 → **記一次，記在 §4 `App process` 列**（8 GiB 機 ≤ 230 MB），**永不**加到 Engine heap 列。理由：footprint 含 App process，把它比 448 MB 的 Engine heap 列就是重複計帳與錯的門檻語義。依據 §3／§4。 |
| WebContent 記憶體 | 隐含可由 sampled heap 觀測 → **明寫不可觀測**（WKWebView 獨立進程、無公開 API、WebKit 無 `performance.memory`）；`sampled engine heap` **永久 `target`**，MUST NOT 被報告為 implemented，也 MUST NOT 當輸入。依據 §3。 |
| §4 的 Engine heap 列 | ≤ 832／448／256／192／144 MB 的常數 → **數字全部不變**；列由「被 sampled heap 驅動」改記為 `target` 常數（不可觀測的量），不參與比較。依據 §4 bullet。 |
| 動作順序與使用者可見 | `clearTmp → plannedRestart → handoff`、warning 路徑零提示 → **完全不變**；`userVisible` 仍為 `false`，`budgetNumbersChanged` 仍為 `false`。 |
| 缺失樣本語義 | 缺樣本不得讀成 0／headroom／加預算的理由 → **不變**（`reportEngineHeapBytes` 仍是 test-only 注入點）。 |
| GAP-39 的關閉條件 | 「`PhoneDSHEngine` 公開 API ＋ Worker JS `performance.memory` 讀取」→ 刪掉；改為「等 Apple／upstream 提供可觀測的 WebContent 讀數」，並註明 `performance.memory` 在 WebKit 不存在。依據 [spec/README.md](../../spec/README.md) §7 GAP-39。 |
| fixtures | `memory-input.json` 2 valid／6 invalid（`productionInputs == ["system-memory-warning"]`）→ 2 valid／12 invalid：兩個生產輸入的集合、footprint 的來源與計帳列、`sampledHeap` 永久 `target`、動作順序、零提示、數字不變；負例新增「舊的單一輸入集合」「只給 footprint」「只給 warning」「記到 engine-heap-row」「相加」「來源不是 task_info」「缺 footprint 帳」「sampled-heap 當輸入」「sampled heap 假稱 implemented」。 |
| 條款狀態 | §3／§4 的輸入條款由 rev 2 改為 R1（仍 normative）；sampled engine heap 由「`target`（等 producer）」改為「`target`（永久，無 producer）」。 |

**自檢（spec/README.md §5.1）。** 沒有新增第二種表達：仍然只有一個 memory proxy、一個動作順序；`phys_footprint` 是**取代** sampled heap 的位置，不是與它並存的第二個權限。沒有放寬任何配額或數字：§4 五個 tier 的 heap／VFS／single-file／WASM／App process／Peak 全部逐字不變，`clearTmp → plannedRestart` 不變。沒有收緊或放寬兩端都讀的訊息：本修訂沒有 wire 訊息（channel／bridge／gateway schema 不動）。沒有新增 enum 或錯誤碼。沒有刪除或重用任何名稱或編號；刪掉的只有一條**做不到的關閉路徑**（`performance.memory`），並在原地寫明它不存在。`budgets.md` 仍在 D16 的 320 行上限內（實測 320 行，未刪任何既有條款或數字，只重排散文行寬）。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | **行為等價或更嚴，不中斷。** 舊實作沒有 footprint 輸入 → 只是少一個訊號，warning 路徑與 `clearTmp → plannedRestart` 完全相同；`PlatformHostSignals.engineHeapBytes` 的預設 `{ nil }` 在新舊都仍是「不觸發」。新實作多一個 footprint 訊號時，門檻是 §4 `App process` 列（比 448 MB 的 heap 列**更嚴**），不是放寬。共享 fixture：`memory-input.json` 的 `footprint-and-warning-production-inputs` 與兩個負例（舊單一輸入集合、只給 footprint）都必須被 checker 判對。 |
| new → old | **無資料語義變化。** 本修訂不產生任何 wire／持久化位元組；舊版讀不到「新格式」這種東西，回滾不需要遷移。唯一差異是文件不再承諾一個舊版也從未實作的 `performance.memory` 路徑。 |
| new → new | 同一份 `memory-input.json` 由 `plan_cases_check.py` 判；四端（Swift／Kotlin／Rust／TS）在本修訂沒有 decoder 變更，也不需要新 golden 位元組。 |
| persisted old data → new／rollback | **不適用**：沒有持久化格式變更；WAL、manifest、materialized、journal、steps 一個位元組都不動。回滾＝直接回到舊版，行為與今天相同。 |

- **版本決定**：不升任何版本。`proto 1`、WAL `format 1`、manifest、bot／PCLink schema 不變。理由：這是**宿主私有輸入**與條款措辭的修訂，沒有任何跨端位元組或語義被新舊端同時讀取；把它包成新版本只會製造一個沒有消費者的版本欄位。
- **部署順序**：spec（本 commit）→ 實作單（footprint 取樣器 ＋ controller 讀取端 ＋ Kotlin 對齊）→ 真機量測（W0 畫像夾具）後才談門檻是否合理。任一端未接 footprint 時，報告必須寫「只有 warning 輸入」，不得聲稱 footprint 已生效。
- **`target` 與仍保留的差異**：`sampled engine heap` 永久 `target`，不是「待辦」；GAP-39 保持 open，關閉條件改為等 Apple／upstream 提供可觀測的 WebContent 讀數。`budgets.md` §4 的 Engine heap 數字維持常數，但**沒有生產 producer 可以比對**，因此它不是可執行的門檻；任何「engine heap 預算已生效」的說法都不成立。

## 4. 分工與證據

- **本單獨占路徑（已在本 commit 完成）**：`spec/v1/budgets.md` §3／§4、`spec/v1/golden/plan/memory-input.json`、`spec/v1/tools/{plan_cases_check,test_plan_cases_check}.py`、`spec/v1/schema/plan-cases.schema.json`（description）、`spec/README.md` §7 GAP-39、本單。
- **下一實作單（`perf-r1`）路徑**：`Sources/PhoneDSH/**`（footprint 取樣器與 host 接線）、`Sources/PhoneDSHController/**`、`android/controller/src/main/**`、對應 test target；**不改 `spec/`**、不改 `Package.swift`（等價程式碼放進既有模組即可；若需新 target 依賴，另開 P12 變更單）。
- **共享 fixtures**：`spec/v1/golden/plan/memory-input.json` — 2 valid（兩個生產輸入＋footprint 記在 App process 列；`reportEngineHeapBytes` 只作 test injection）／12 invalid（sampled heap 當輸入、無輸入、舊單一輸入集合、只給 footprint、footprint 來源不是 `task_info/TASK_VM_INFO`、記到 engine-heap-row、與 heap 相加、缺 footprint 帳、動作順序顛倒、新提示、改數字、sampled heap 假稱 implemented）。
- **各端真實 proof 命令（由實作單執行；本單只跑 Linux/macOS 可跑的 spec 檢查）**：
  - Swift：`swift test --filter PhoneDSHBudgetTests`（footprint 取樣器與 `heapExceeds` 讀取端）＋ `--filter PhoneDSHRestartPolicyTests`（75%／3 樣本不變）。本輪 **NOT_RUN**（未改原始碼）。
  - Kotlin：`bash scripts/ci/check.sh --only phone-android-tests` 的 controller 預算測試。本輪 **NOT_RUN**。
  - 真機：host `phys_footprint` 與 jetsam 的相關性 **NOT_VERIFIED**（`ProcessMetrics.swift` 自述；本輪未量測）。
  - 本單實跑見 §4.1。
- **剩餘風險／open questions**：代理門檻是否會誤觸 `heapPressure` 重啟 **未量測**（建議第一輪只記錄、不觸發，由實作單決定）；`§3` 的「engine heap > 75% for 3 samples」觸發條件在 sampled heap 永久 `target` 下**不可達**——本輪不動它（數字與 §4 的 75%／3 樣本必須原樣保留），實作單不得把它當成已生效的觸發，也不得用 footprint 冒充那個百分比；§4 `App process` 列的 230 MB 對 `phys_footprint` 是否合理需要一次真機基線（W0 畫像夾具就是為此存在）；`os_proc_available_memory()` 是**餘量**不是用量，本修訂沒有把它列為輸入（列了就會是第二種語義）；GAP-39 不再有本倉可做的關閉路徑。

### 4.1 命令 → 結果（本 commit 實跑）

```bash
python3 spec/v1/tools/plan_cases_check.py
python3 -m unittest spec.v1.tools.test_plan_cases_check
python3 spec/v1/tools/spec_golden.py --full
bash scripts/ci/check.sh --only phone-cross-tree
bash scripts/ci/check.sh --only phone-spec
wc -l spec/v1/budgets.md
```

結果見交付回報（全部原樣記錄；`phone-spec` 若因環境無法完成記 `NOT_RUN`，不得寫成 PASS）。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts-1113（contract owner） | owner 於 2026-11-13 裁定 R1：engine-memory 輸入改為宿主 `phys_footprint` ＋記憶體壓力警告，刪除不可實作的 `performance.memory` 路徑，sampled heap 永久 `target`；動作順序與數字不變。凍結 §3／§4 與 `memory-input` fixture。 | all（contract freeze 公告）；P03／P04（受影響端）；upstream（GAP-39 關閉路徑改為等 OS／runtime 讀數） |
