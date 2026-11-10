# PC-20261110-pclink-pc-roster-snapshot

## 0. 摘要（機器可讀，保持這個格式）

```yaml
change: PC-20261110-pclink-pc-roster-snapshot
contracts: [P18, P09]
status: frozen
breaking: false
version_decision: 新增一個本地鍵與一種帶版本的值格式；舊鍵與裸格式仍可讀，無遷移
base: 0989d550f
contract_revision: spec/README.md@working-tree（§3.1 P18 追加）
```

## 1. 識別與角色

- 具體 trigger → 現況 → 期望：
  - 打開 PC 工作區（冷啟動或切回 App）→ 現況：`DSHManagementModel` 對 PC 後端**完全不讀也不寫**會話清單快照（`performRefresh()` 的 `guard chat.isStarted` 分支只給手機 `restoreCachedSnapshot()`，寫入點有 `if backendID == .phone` 守衛），所以抽屜在 `session/list` 回來之前是空的，離線時整個列表被「電腦離線」卡片取代。
  - 期望：PC 後端也有自己的清單快照，**先畫再核實**：模型建立時立即還原上次成功的 `session/list` 投影，背景刷新回來後覆寫；失敗或離線不清空、不覆蓋。
- 協調者兼 contract owner：本單作者（P18/P09）。
- 受影響 producer／consumer：僅 iOS App 進程內的持久化讀寫（`examples/probe-app/{ProbeKit,PhoneDSHProbe}`）；`Sources/PhoneDSHPCLink/**`、`pclink/**`、`relay/**` **不受影響**（不新增任何 wire 或 DSH Remote 呼叫）。Android 尚未實作 PC 工作區（GAP-35）。
- Owning spec：`spec/README.md` §3.1 P18（本地持久化鍵與格式）。
- 共享 fixtures：不需要新 wire fixture；本單的值格式由 Swift 單元測試（正例、裸格式、壞值）覆蓋。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| UserDefaults 鍵 | 新增 `phone-dsh.pc.session-snapshot.<machineId>`（PC scope）。手機既有 `dsh.management.sessionSnapshot.v1` **不變**，不遷移、不刪 |
| 值格式 | PC 鍵的值是 envelope：`{"v":1,"capturedAtMilliseconds":<double>,"backend":"pc:<machineId>","payload":<ChatSessionSnapshot>}`。`ChatSessionSnapshot` 結構本身不變（sessions / workspaces / workspaceOrder / pinnedSessionIDs / archivedIDs） |
| 讀取規則 | 先試 envelope，再試裸 `ChatSessionSnapshot`（相容手寫或舊值）；兩者都失敗即忽略，**不得**清空目前列表 |
| 寫入規則 | 只在 `session/list` 刷新**成功**後寫；空快照不寫（沿用既有 `isEmpty` 守衛）；手機與 PC 各自寫自己的鍵 |
| 清除規則 | `WorkspaceStorage.removeLocalData(for:)`（解除配對、PC 換機）一併刪除該 PC 鍵；手機鍵不受影響 |
| 內容限制 | 只含 `session/list` 與 `workspace/follow` 的投影（id、標題、時間、running/blank、cwd、parent、搜尋摘要、工作區分組、pinned/archived）。**不含**待審批、待回答、佇列、串流內容、工具輸出、密鑰 |
| error code／retryable／idempotency／auth | 不變 |

自檢：沒有第二種表達同一語義（envelope 是唯一新格式，裸格式只為相容而讀）；新欄位皆為必要成員且有缺省判定（解不出即忽略）；沒有收緊或放寬任何兩端都讀的 wire 訊息；沒有新增 enum 值影響 wire。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old app → new data | 舊 build 只讀手機鍵與裸格式；PC 鍵不在它的讀取路徑上，看到也不解 → 無影響 |
| new app → old data | 手機裸格式照舊解；PC 沒有舊資料（本單之前從未寫過） |
| new → new | envelope v1 |
| persisted old data → new／rollback | 不遷移任何既有鍵。回滾後 PC 鍵變成沒人讀的死資料，可由 `removeLocalData` 或下次解除配對清除；手機行為與今日完全相同 |

- 版本／adapter 決定：`v:1` 是 envelope 的格式版本，未知 `v` 一律忽略（不猜測、不升級）。
- 更新順序：無 wire／artifact 變更，無部署順序限制。
- `target` 條款中仍保留的差異：P18 為既有 `target`；本單只追加一個本地鍵，不改變其狀態。

## 4. 分工與證據

- 獨占路徑：`examples/probe-app/PhoneDSHProbe/DSHManagementModel.swift`、`examples/probe-app/ProbeKit/{ChatSessionSnapshot.swift,Backends/WorkspaceStorage.swift}`、`examples/probe-app/PhoneDSHSimTests/PCLinkWorkspaceSimTests.swift`、`spec/README.md` 的 P18 列。
- 驗收命令：
  - `xcodebuild test -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/PCLinkWorkspaceSimTests`（scope 隔離、envelope／裸格式、壞值忽略、解除配對清除）
  - `xcodegen generate` + `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
  - `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree`
- 真實 producer／consumer 測試：需要真機一次「冷啟動 → 抽屜立即可見 → 背景刷新覆寫」，並記錄 `session/list` 的實際呼叫次數；模擬器不算。
- 剩餘風險：本單只做「先畫」，尚未做 `seq` 增量補齊與離線時的唯讀列表呈現（後續工作包）；envelope 的 `capturedAtMilliseconds` 目前只用於測試斷言與未來 staleness 呈現，不參與任何寫入決策。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| working-tree | 本單作者 | 初版：使用者回報「每次打開 PC 工作區都要重新加載」 | P09（App）、P18（本地持久化） |
