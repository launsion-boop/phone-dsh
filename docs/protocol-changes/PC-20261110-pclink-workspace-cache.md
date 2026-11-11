# PC-20261110-pclink-workspace-cache

## 0. 摘要（機器可讀，保持這個格式）

```yaml
change: PC-20261110-pclink-workspace-cache
contracts: [P18, P09]
status: frozen
breaking: false
version_decision: 轉錄快照改為帶版本的 envelope（舊裸陣列仍可讀），新增診斷檔；無 wire 變更
base: 6f4bed1f7
contract_revision: spec/README.md@working-tree（§3.1 P18 追加）
```

本單是 `PC-20261110-pclink-pc-roster-snapshot` 之後的後半段：轉錄快照的有界化、診斷日誌、四態 presence 與「離線可讀」的抽屜，以及切換會話時的「先畫快取」。

## 1. 識別與角色

- 具體 trigger → 現況 → 期望：
  - **轉錄快照無界**：`persistTranscriptSnapshot()` 舊寫法是裸陣列、每項文字全量、最多 400 項 → 一場帶大型工具輸出的對話可以把快取檔推到 MB 級，且沒有數量上限、沒有排除備份。
  - **離線時沒有可讀內容**：`PCDrawerPhase` 只有 ready/offline 兩態，`showsPCState` 直接把整個列表換成離線卡；`startPCModel()` 在非在線時直接 return，連本機快取轉錄都不還原。
  - **「電腦離線」實為手機側判斷**：`PCWorkspaceConnection.offline` 與 `.connecting` 都投影成 `.offline`，所以回前台重撥的視窗也叫離線。
  - **切換會話每次全量重讀**：`openAndActivateSession()` 只有在啟動時還原過一次快取，切換到另一個已快取的會話時仍是空白等待網路。
- 期望：轉錄快照有界且帶版本；手機能把「重連中」與「真的連不上」分開講；連不上時仍可讀上次的清單與對話；切換到已快取的會話先畫再同步。
- 協調者兼 contract owner：本單作者（P18/P09）。
- 受影響 producer／consumer：iOS App 進程內（`examples/probe-app/{ProbeKit,PhoneDSHProbe}`）。`Sources/PhoneDSHPCLink/**`、`pclink/**`、`relay/**` 不受影響；Android 未實作 PC 工作區（GAP-35）。
- Owning spec：`spec/README.md` §3.1 P18；頁面契約 `spec/ui/v1/pages/**`。
- 共享 fixtures：Swift 單元測試（`PhoneDSHSimTests/PCLinkWorkspaceSimTests`）覆蓋值格式的正例、舊格式、未知版本、越界與淘汰。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 轉錄快照格式 | 裸 `[item]` → `{"v":1,"capturedAtMilliseconds","backend","sessionID","lastSeq","items":[…]}`；讀取先試 envelope 再試裸陣列；`backend`／`sessionID` 不符、未知 `v`、壞位元組一律忽略 |
| 轉錄快照上限 | 400 項、單檔 512 KiB、單項文字 4096 字元；超出時從最舊丟棄，單一巨大項先截斷 |
| 轉錄快照目錄屬性 | 新增 `isExcludedFromBackup = true`；保留檔數上限 200，超出時按修改時間淘汰，**當前會話檔永不被淘汰** |
| 診斷檔 | 新增 `Documents/pclink-diag.log`（輪替為 `pclink-diag.1.log`，各 256 KiB）。內容只有：狀態投影、`PCLinkOfflineReason` 類名、重連間隙秒數；不含標題、訊息、金鑰、指紋 |
| presence 語義 | `PCWorkspacePresence.Reachability = online｜reconnecting｜offline`；`reconnecting` 覆蓋 `.connecting` 與 8 s 重連寬限內的 `.offline`；`.offline` 需寬限到期 |
| 抽屜 | `PCLinkDrawerPolicy.phase(selected:hasRecord:presence:)`（原 `connection:` 參數移除）；有快取列時，`connecting`／`offline` 仍渲染列表，並在其上顯示一行狀態 strip |
| 頁面契約 | `home-drawer` 新增 `pc-cached-list-note` 一行（純文字、無新動作）；ChatPage 的 PC strip 與空時間軸文案分流為三態；`chat`／`runtime-details` 重抽 |
| 抽屜狀態卡判定 | `PCLinkDrawerPolicy.showsStateCard(phase:pcRowCount:)`，`pcRowCount` **只取 PC scope**（`pcManagement`）。改前用 `management.sessions`（未配對時回退到手機模型），未配對的 PC 分段會渲染手機列表並藏起「連接電腦」卡（review A） |
| 快取預覽閘門 | `CachedPreviewGate`：預覽期間 `canSend == false`；`currentSessionID` 在預覽時回報被預覽的會話；切換失敗／取消時以快照還原 items／statusLine／transcript 旗標（review P0） |
| 離線可讀 | PC 未連線時：`startPCModel()` 先還原快取再判斷連線；抽屜點擊已快取會話經 `performSelect` 走 `showCachedPreview` 回 `.opened`（不報錯、不可發送）；未快取會話才報錯，且文案分 `connecting`／`offline`（review B） |
| 轉錄快照位元組上限 | 估算改用 JSON 轉義後的位元組；再於編碼後檢查實際大小並丟棄最舊列直到 ≤ 512 KiB，使上限成為保證而非估算；`title` 另設 256 字元上限（review 次要項） |
| wire／schema／錯誤碼／retry／idempotency | 不變 |

自檢：沒有第二種表達（presence 是唯一的抽屜判斷輸入，`connection` 只用於投影）；新欄位有明確缺省與拒絕規則；沒有放寬任何既有驗證；沒有新增 enum 值影響 wire。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old app → new transcript file | 舊 build 以裸陣列解新 envelope → 解碼失敗 → 視為無快取，畫面照常由引擎填；不崩不誤用 |
| new app → old transcript file | 裸陣列仍可讀，`lastSeq` 為 nil |
| new → new | envelope v1 |
| persisted old data → new／rollback | 不遷移；舊檔原地保留，新寫入覆蓋同一路徑 |

- 版本／adapter 決定：envelope `v:1`；未知版本忽略。
- 更新順序：無部署限制。
- `target` 條款差異：P18 為既有 `target`；本單不改其狀態。

## 4. 分工與證據

- 獨占路徑：`examples/probe-app/{ProbeKit/**,PhoneDSHProbe/**,PhoneDSHSimTests/PCLinkWorkspaceSimTests.swift}`、`spec/ui/v1/pages/**`、`spec/ui/v1/tokens.json`、`spec/README.md` 的 P18 列。
- 驗收命令：
  - `xcodebuild test -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/PCLinkWorkspaceSimTests`
  - `xcodegen generate` + `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
  - `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance`
  - `swift test --filter PhoneDSHPCLinkTests`（確認 P28 客戶端未被本次 App 改動波及）
- 真實 producer／consumer 測試：需要真機一次「冷啟動（有快取）→ 抽屜立即可見」、「切換到已快取會話先看到內容」、「飛航模式開啟後仍可讀列表與轉錄」，並匯出 `pclink-diag.log`。
- 本次 review 修正的回歸（`xcodebuild test -only-testing:PhoneDSHSimTests/PCLinkWorkspaceSimTests`）：
  - `testStateCardDecisionUsesThePCOwnRows`：未配對（`.pair`、PC 0 列）恆顯示卡片，即使手機有會話（A）
  - `testCachedPreviewBlocksSendingUntilItEnds`：預覽期間 `allowsSend` 為 false；結束後恢復（P0）
  - `testTranscriptCacheRespectsTheByteBoundAfterEscaping`：病態轉義內容下編碼後仍 ≤ 512 KiB（次要項）
- 仍未覆蓋：`WorkspaceModels.pcRowCount`／`performSelect` 的 PC 分支屬 App target，hostless sim 測試無法驅動，只能靠純規則測試 + 代碼審查；真機的「離線點擊已快取會話」仍需驗證。
- 剩餘風險：寬限 8 s 是經驗值（重撥上限 1 s + 握手）；`session/list` 的 `seq` 增量補齊仍未實作（本單只做「先畫」）；真機證據未取得。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| working-tree | 本單作者 | 初版：把快取後半段（有界化、診斷、四態、先畫）一次凍結 | P09（App 頁面）、P18（本地持久化） |
