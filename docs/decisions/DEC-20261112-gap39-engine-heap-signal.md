<!-- SPDX-License-Identifier: MIT -->
# DEC-20261112-gap39 — engine heap 取樣：契約要改成可量測的量

Protocol impact: none — documentation only

Status: **proposal（供 P03／P04 owner 簽核）**
對應 GAP: [GAP-39](../../spec/README.md)（P03、P04，open）
前置閱讀: [決策備忘](perf-stability-open-gaps-20261112.md) §2 的 D1

---

## 1. 一句結論

**GAP-39 原本登記的關閉路徑不能實作**（Worker JS 讀 `performance.memory`，而 WebKit 沒有這個 API），
宿主也拿不到 WebContent 進程的 heap。因此這不是「補一個 producer」的工作，而是**契約要換一個量**：
把 §3／§4 的 engine-memory 輸入改成「結果型訊號 ＋ 宿主側 footprint 代理」，並把 sampled engine heap
永久留在 `target`（或直接刪列），不要再用一個量不到的數字當預算。

---

## 2. 現況與證據

| # | 證據 | 說明 |
|---|---|---|
| E1 | `Sources/PhoneDSH/PhoneDSHHost.swift:5424`、`:5426` | `currentEngineHeapBytes()`／`reportEngineHeapBytes(_:)` 存在，寫入 `engineHeapBytes` 後跑 `evaluateBudget` |
| E2 | `Tests/PhoneDSHTests/BigFileBudgetTests.swift:254`、`:271` | 全倉**唯一**的呼叫者；沒有生產 producer |
| E3 | `Sources/PhoneDSH/PhoneDSH.swift:653`、`:699-700` | snapshot 的 `engineHeapBytesUsed` 與 `withinBudget` 判定 |
| E4 | `Sources/PhoneDSHController/Budgets.swift:308` | `heapExceeds = sample.engineHeapBytes.map { $0 > table.engineHeapBytes } ?? false`；`nil` 等於「不觸發」，不是 0 |
| E5 | `Sources/PhoneDSHController/Signals/PlatformHostSignals.swift:75-92` | `engineHeapBytes` 是注入閉包，**預設 `{ nil }`** |
| E6 | `Sources/PhoneDSHController/RestartPolicy.swift:34-46`、`:57-75` | 75% × tier 預算、連續 3 個 1 分鐘樣本 → `heapPressure` 重啟（只在 tool-call boundary 執行） |
| E7 | `spec/v1/budgets.md:69`、`:73`、`:111` | 「engine heap > 75% for 3 samples」、memory proxy 列含 sampled engine heap、§4 的 Engine heap 列（8 GiB 機 ≤ 448 MB） |
| E8 | `spec/v1/budgets.md:76-83` | W2 rev 2 已把 sampled heap 記為 `target`，warning 是唯一生產輸入，並明寫「缺樣本不得讀成 0／headroom／加預算的理由」 |
| E9 | `spec/README.md:232` | GAP-39 的關閉條件寫的是「`PhoneDSHEngine` 公開 API ＋ Worker JS `performance.memory` 讀取」 |
| E10 | `Sources/PhoneDSHEngine/WebEngine.swift:763-786` | 引擎**已經會** `view.evaluateJavaScript(...)`，但只在 `runJITProbeOnUI` 這個 private 方法裡（證明「技術上可注入 JS 並取回值」，不是「有 heap 讀數」） |
| E11 | `Sources/PhoneDSHEngine/WebEngineScripts.swift:18`、`:150-173` | 注入腳本只有 observability（console／boot）與 JIT benchmark；沒有任何記憶體讀數 |
| E12 | `examples/probe-app/ProbeKit/ProcessMetrics.swift:1-47` | 倉內**已有**宿主 `phys_footprint`（`task_info` TASK_VM_INFO）與 `os_proc_available_memory()` 的實作 |
| E13 | `examples/probe-app/ProbeKit/ProcessMetrics.swift:4-14`、`examples/probe-app/PhoneDSHProbe/MemoryPage.swift:137-139` | 該檔自己寫明「這兩個都是 proxy，不是 WebContent 測量；能不能追蹤 jetsam 在 iPhone 上 NOT_VERIFIED」 |
| E14 | `spec/v1/budgets.md:117` | §4 另有 **App process** 列（8 GiB 機 ≤ 230 MB）——所以「宿主 footprint」不是沒被記帳的量 |

**外部事實（本輪查證，非推測）：**

| # | 事實 | 來源 |
|---|---|---|
| X1 | `performance.memory` 是**非標準、deprecated**，且「only available in Chromium-based browsers」 | MDN `Performance.memory` 條目 |
| X2 | `performance.memory` 在 Safari／iOS Safari 皆 `false`；替代品 `measureUserAgentSpecificMemory` 也是 `safari: false` | `mdn/browser-compat-data` `api/Performance.json`（`memory.support`、`measureUserAgentSpecificMemory.support`） |
| X3 | WKWebView 沒有公開的 per-WebContent 記憶體讀數；`os_proc_available_memory()` 回的是**呼叫進程**的 headroom，`task_info` 量的是**本進程** footprint | `examples/probe-app/ProbeKit/ProcessMetrics.swift:4-14` 的記載與 `:20-41` 的實作一致 |

**結論：E9 的關閉路徑同時踩到 X1／X2／X3。** 也就是說，即使 P04 owner 今天把
`PhoneDSHEngine` 的公開 probe 寫出來，它也只能回傳 nil、或回傳一個**不是 WebContent** 的數字。

---

## 3. 五個方案

評分欄位固定：**能測到什麼／測不到什麼／要動哪條契約／成本／風險**。

### A. 宿主 `phys_footprint` 當 engine 的代理

- **能測到**：App 進程被系統記帳的 footprint（含 WKWebView 宿主側的記憶體），1 次 `task_info`
  syscall 就有；成長趨勢對「自己在漏」有效。
- **測不到**：WebContent 進程（JS heap、DOM、解碼影像）完全不在裡面；也測不到 jetsam 判定的那個數字。
- **契約**：P03（`budgets.md` §3 的 memory proxy 來源、§4 的列義）。**不必**動 P04。
- **成本**：低。`ProcessMetrics.swift:20-34` 已有可用實作，但它在 probe app 的 Xcode target，SwiftPM 的
  `PhoneDSH` 不能 import；需在 `Sources/PhoneDSH`（或共用模組）放一份等價程式碼（P12 只影響放哪裡）。
- **風險**：**與 §4 的 App process 列重複計帳**（E14）。若把宿主 footprint 直接塞進
  `engineHeapBytes`，`RestartPolicy` 會用 448 MB × 75% 去比一個含 App 的量，門檻語義就錯了。

### B. 透過 P04 bridge 由 JS 側回報

- **能測到**：JS 願意且能算的任何**邏輯**量（例如「目前持有的 VFS 位元組」「items 數量」）。
- **測不到**：JS heap 本身——沒有 API 可讀（X1／X2）。`performance.memory` 在 WebKit 是 `undefined`，
  所以「讀 `performance.memory` 再回報」這條路在 WebKit 上是**空指標**，不是數值偏差。
- **契約**：P04 bridge（新增一種 message kind 或一個 method）＋ P03（把該值定義成什麼量）。
  注意 `bridge.md` 的 unified envelope 大半是 `target`（`spec/README.md:60`、`GAP-01`），現行可用的只有
  `xlEngine` 的 observability 通道（handler 名稱見 `WebEngine.swift:152`，腳本見 `WebEngineScripts.swift:18-148`）；走現行通道加一個 `kind` 比走
  `target` envelope 便宜，但仍是 P04 變更。
- **成本**：中（引擎公開 API ＋ 腳本 ＋ 兩端測試 ＋ P04 文件）。
- **風險**：**回報的數字不是 heap**，若命名為 `engineHeapBytes` 就是第二種語義（AGENTS §2.1 禁止）；
  且 JS 取樣點由頁面決定，Worker 忙時取不到樣本。

### C. `os_proc_available_memory()`

- **能測到**：本進程在 jetsam 之前還剩多少 headroom（系統角度，非本進程用量）。
- **測不到**：誰用掉了記憶體（本進程？WebContent？其他 App？），也測不到 WebContent 本身。
- **契約**：P03（要新增一個「headroom」訊號，而不是改 engine heap 的定義）。
- **成本**：低（`ProcessMetrics.swift:36-41` 已有實作）。
- **風險**：**它不是用量而是餘量**，不能塞進 §4 的 Engine heap 列；但很適合作為「該不該現在重啟」的
  第二個輸入（與 warning 同類）。

### D. 放棄 engine heap，改量宿主總 footprint

- **能測到**：與 A 相同的量，但**語義誠實**：§4 的列改名／改義，不再假裝那是 WebContent。
- **測不到**：同上（WebContent）。
- **契約**：P03：刪掉或降級 §4 的 Engine heap 列，改成「宿主 footprint」列；§3 的 memory proxy 來源表
  跟著改；`budgets.md` 的 §3 rev 2 段落（E8）要一起重寫，否則文件自相矛盾（§4 有列、§3 說量不到）。
- **成本**：低—中（純契約＋一個 1Hz 取樣器）。
- **風險**：拿掉 Engine heap 列等於承認「我們沒有 engine 預算」。若 owner 不接受，就只能選 A 但把語義
  寫清楚（「宿主側代理，含 App process，不得與 §4 App process 列相加」）。

### E. 結果型訊號（outcome-based）：warning ＋ WebContent 終止 ＋ uptime

- **能測到**：真正的壞結果——WebContent 被系統杀掉（`webViewWebContentProcessDidTerminate`，
  `Sources/PhoneDSHEngine/WebEngine.swift:846`）與系統記憶體警告。這兩個是**實際壓力**的證據，不是代理。
- **測不到**：壓力**之前**的趨勢；只能事後反應。
- **契約**：**已經在契約裡**（`budgets.md:68`、`:76-83`；`RestartPolicy.swift:72`）。
- **成本**：零（已交付）。
- **風險**：對「8 小時不進 Failed、無 jetsam」（plan W2 驗收）足夠，對「提前避開」不夠。

### 方案對照

| 方案 | 測到 WebContent？ | 可當 §4 enforcement 輸入？ | 動的契約 | 成本 | 主要風險 |
|---|---|---|---|---|---|
| A 宿主 footprint 代理 | 否 | 只能當代理，且要防重複計帳 | P03 §3／§4 | 低 | 門檻語義錯（448 MB 比 230 MB 的量） |
| B P04 JS 回報 | 否（沒有讀數） | 只能當邏輯量 | P04＋P03 | 中 | 命名成 heap 就是第二種語義 |
| C `os_proc_available_memory` | 否 | 不適合（是餘量） | P03（新訊號） | 低 | 與用量混用 |
| D 改量宿主總 footprint | 否 | 是（改名後） | P03 §3／§4／§4 列 | 低—中 | 明示「沒有 engine 預算」 |
| E 結果型訊號 | 是（死亡即證據） | 是（已生效） | 已存在 | 零 | 只能事後 |

---

## 4. 建議（雙軌，一步一動）

**第一軌（現在就可以做，P03 owner）：**

1. 在 `budgets.md` §3 的 engine-memory 輸入段落（E8 那一段）改寫成三個明確輸入：
   - `warning`（已有，生產）；
   - `webContentTermination`（已有，生產）；
   - `hostFootprint`（**代理**，新增；明寫「含 App process，不得與 §4 App process 列相加」）。
2. §4 的 **Engine heap** 列**保留為 `target`**，並在列名或註腳標明「`target`，無生產 producer」；
   **不要**把宿主 footprint 塞進這一列。若要 enforcement，另立一列 `Host footprint (proxy)` 並寫死
   「超限只記錄，不觸發 planned restart，直到真機量到門檻」。
3. 刪掉 GAP-39 登記裡「Worker JS `performance.memory`」這句話（`spec/README.md:232` 的「期望」欄），
   改成「等 Apple／upstream 提供可讀的 WebContent 讀數；在此之前 sampled heap 永久 `target`」。
   這一步是**必要的誠實修正**：留著一句做不到的關閉條件，下一個 agent 會照著做然後卡住。

**第二軌（可選，P04 owner）：**

4. 若 owner 仍想要「engine 自己說」的通道，唯一可行的是 B 的**邏輯量**版本（例如 Worker 自報目前持有
   的 VFS／response-log 位元組），且**必須另立名字**（`workerReportedLogicalBytes`），不得叫 heap。
   GAP-39 不因它關閉。

**為什麼不選 D 的「直接改名」**：改名會讓 §4 少一列、plan W2 的「內存預算」失去對象；保留 `target` 列
在文件上誠實，成本也低。若 owner 偏好乾淨、不想要一個永遠 `target` 的列，D 是可接受的最小替代，但
要在同一變更裡把 §3 rev 2 段落一起改掉（否則是兩段互相矛盾）。

---

## 5. 兼容性與 breaking

| 邊界 | 改動 | old → new | new → old | breaking |
|---|---|---|---|---|
| P03 `budgets.md` §3／§4 | 訊號來源與列義；無 wire、無 schema、無持久化格式 | 舊實作沒有 `hostFootprint` 輸入 → 只是少一個訊號，行為不變 | 新文件描述的訊號在舊實作不存在 → 舊機照舊 | **否**（文件與私有輸入） |
| P04 bridge | 只有在第二軌被選時才有；additive kind | 舊頁面不送 → 新端視為缺值 | 新頁面送舊端 → 未知 kind 應被忽略（需在 P04 寫明） | 否（additive，但要補「未知 kind 忽略」條款） |
| 使用者可見 | 無新提示；warning 路徑的 `clearTmp → plannedRestart` 順序與零提示不變（`budgets.md:82-83`） |  |  |  |

---

## 6. 需要誰授權什麼

| 授權者 | 要授權的具體事項 | 不做會怎樣 |
|---|---|---|
| **P03 owner** | ①§3 的 engine-memory 輸入改成三輸入（含 `hostFootprint` 代理，且不得與 App process 列相加）；②§4 Engine heap 列的 `target` 標註與（可選）新 `Host footprint (proxy)` 列；③改寫 `budgets.md` §3 rev 2 段落 | GAP-39 永遠 open，且每個新 agent 都會再嘗試一次不可實作的路徑 |
| **P04 owner** | 只在選第二軌時：新增 bridge kind（或 `xlEngine` observability 的新 kind）＋「未知 kind 忽略」條款；**同時**決定是否把「WebContent heap readout」正式登記為 upstream 需求 | 沒有 bridge 變更；不影響第一軌 |
| **owner（產品／計畫）** | 接受「sampled engine heap 永久 `target`，W2 的內存預算改由 warning＋termination＋代理共同驅動」 | 就得接受 §4 有一個永遠量不到的列 |
| **（不在本輪）upstream** | 若未來 Apple 或 DSH runtime 提供 WebContent 讀數，才回來把 `target` 改 `implemented` | GAP-39 的關閉條件永久擱置 |

---

## 7. 未量測 / 開放問題

- **未量測**：WebContent 真實 footprint；宿主 `phys_footprint` 與 jetsam 的相關性（E13 自述
  NOT_VERIFIED）；代理門檻會不會誤觸 `heapPressure`（因此建議第一輪只記錄、不觸發）。
- **未量測**：`budgets.md` §4 的 448 MB 這個數字當初怎麼來的（文件只說「常數」，`budgets.md:3-6`）。
  若改代理，這個數字對新量是否仍合理，**需要一次真機基線**（W0 的畫像夾具就是為此存在）。
- **開放**：`RestartPolicy` 的 75%／3 樣本在代理方案下是否要改成「只對 `webContentTermination` 與
  warning 生效」？本備忘建議 **是**，但這是 P03 的條款選擇，不由本文件決定。
