# PC-20261110-pclink-ios-app — iOS PC 工作区（PCLink D2）

## 0. 摘要（機器可讀）

```yaml
change: PC-20261110-pclink-ios-app
contracts: [P09, P18, P28]
status: implemented
breaking: false
version_decision: PCLink v1（pclink-v1.3）不變；P09 新增頁面／動作，P18 新增鍵與一次性遷移
base: 627aed351484f98fc9e29c4f238937e6c818c8cf
contract_revision: spec/ui/v1/pages/home-drawer.json@pclink-d2-r1
```

## 1. 識別與角色

- 具體 trigger → 現況 → 期望：
  - **P09**：`HomeDrawer` 只有手機工作區；新增「手機 | PC」分段、PC 未配對／離線空狀態、配對頁、已連接的電腦頁、PC 能力隱藏與版本提示。Android 無對應實作，按 GAP-35 只記錄。
  - **P18**：會話、草稿、標題提示、轉錄快照與收合文件夾仍以裸 `sessionID` 儲存；PC 與手機可能出現同 ID。改為 `<BackendID.storageScope>／<sessionID>`，並新增 `phone-dsh.drawer.backend`（`phone`/`pc`，缺省 `phone`）。舊資料一次性複製到 `phone`，舊鍵保留。
  - **P28**：不修改 `spec/pclink/**`；App 以現有 `PCLinkClient`／`RelayDSHTransport`／`DSHRemoteHarness` 接線。
- 協調者兼 contract owner（P09/P18/P28 本單）：iOS D2 實作者。
- Owning spec：P09 `spec/ui/v1/README.md`、`spec/ui/v1/pages/**`、`spec/ui/v1/tokens.json`；P18 `spec/README.md` §3.1 P18 行；P28 `spec/pclink/v1/README.md`（本單只消費）。
- 受影響 producer／consumer：iOS App（consumer，`examples/probe-app/**`）；Android（未實作，GAP-35）；PC plugin／relay（不改，既有 consumer）。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| P09 頁面動作 | `home-drawer` 增加「手機」「PC」兩個 action 與選中態；新增 `pc-pairing`、`connected-computer` 兩個 `*Page` 契約；`settings` 增加「已連接的電腦」action。未加 whitelist，未改 `_baseline.json`。 |
| P09 provenance | `extract_ios_pages.py` 重新產生受行號影響的頁面契約；手寫 `home-drawer`、`_spec-required.json` 與 `tokens.json` 的 `file:line` 逐項更新。 |
| P18 UserDefaults 鍵 | 新增 `phone-dsh.drawer.backend`（封閉值域 `phone`/`pc`，缺省 `phone`）。新增 `chat.dsh.currentSession.<scope>`、`chat.drafts.v2`、`phone-dsh.session.title-hints.v2`、`phone-dsh.sidebar.collapsed-workspaces.v2`、`phone-dsh.storage.scope-migration.v1`。`chat.dsh.retryableRequestIDs` 不改 key，但 fingerprint 加入 scope 與 sessionID。 |
| P18 檔案鍵 | `Documents/transcript-snapshots/<scope>/<sessionID>.json`；舊 `Documents/transcript-snapshots/<sessionID>.json` 保留。 |
| 舊資料 | 一次**複製**（不刪除）；舊裸鍵、舊草稿、舊標題提示、舊收合文件夾與舊 snapshot 永遠可讀。回滾新版會看到遷移前的舊鍵。 |
| 相容性 | PCLink v1 不變；P09/P18 是 App 本地契約，沒有舊 consumer 強制升級。 |

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 舊鍵一次性複製到 `phone` scope；舊鍵保留。`PCLinkWorkspaceSimTests.testMigrationCopiesLegacyKeysAndIsIdempotent`。 |
| new → old | 舊版只讀舊鍵；D2 之後寫入的新草稿／會話不會出現在舊版。回滾影響：PC 工作區消失、手機會話回到遷移前快照（PC 資料仍在 `pc:<machineId>` scope 內，不刪除）。 |
| new → new | scope 由 `BackendID.storageScope` 唯一決定（`phone`／`pc:<machineId>`）；同一 `sessionID` 的兩端草稿、當前會話、快照、標題提示與收合文件夾互不覆蓋。 |
| persisted old data → new／rollback | 無損複製（含 snapshot 檔案）；`phone-dsh.storage.scope-migration.v1` 使第二次運行 no-op；強制重跑只補缺值。 |

## 4. 分工與證據

### 4.1 契約凍結（先於代碼）

- P18 權威登記：`spec/README.md` §3.1 P18 行（`phone-dsh.drawer.backend` 值域、`<scope>／<sessionID>` 鍵、遷移與回滾）。
- P09：`spec/ui/v1/pages/home-drawer.json`（手機／PC actions）、新增 `pc-pairing.json`、`connected-computer.json`、`settings` 的「已連接的電腦」action；`spec/ui/v1/README.md` §1 頁面清單補兩個新頁。
- GAP-35：`spec/README.md` §7 如實登記 **12 + 5 = 17** 處基線外差異（見 §4.4）。
- 產生器鏡像：`spec/registry.json` 由 `registry_build.py --write` 重新產生（P18 row 變更的必要鏡像；超出「只改 spec/README.md + spec/ui」的字面路徑清單，見 §4.7 範圍說明）。

### 4.2 實現端與路徑

- App：`examples/probe-app/PhoneDSHProbe/**`
  - `WorkspaceModels.swift`：`(BackendID → ChatModel/DSHManagementModel)` registry、抽屜選擇持久化、PC 模型生命週期。
  - `PCLinkWorkspace.swift`：`PCLinkClient` 啟停、狀態/notice 流、10 分鐘長離線、DEBUG 檔案身分 store（unsign 模擬器）。
  - `PCDrawerSection.swift`：手機 | PC 分段、PC 未配對／離線／長離線、版本提示條、設定頁「屬於手機」提示。
  - `PCPairingPage.swift`：相機掃碼（AVFoundation）、粘貼鏈接（DEBUG 與正式版都保留）、手動 16 位碼、本機 12 位指紋、首次配對告知、等待批准／逾時或槽銷毀錯誤態、明確確認。
  - `ConnectedComputerPage.swift`：單台電腦名稱／DSH 版本／在線狀態／本機指紋／中繼／解除配對（二次確認）／配對新電腦（先解除）。
  - `ChatModel.swift`：`PCWorkspaceRuntime`、PC `/dsh/workspace` 不適用、provider 選擇僅手機、PC 離線 `canSend=false`、scoped current session／snapshot／retryable fingerprint、PC 檔案不本地預覽。
  - `DSHManagementModel.swift`：per-backend 實例、`title-hints` scoped、phone-only `phone/*`／Bot／device session filter。
  - `ChatPage.swift`：按 backend 注入 model、PC 副標題、版本提示與離線條、審批卡沙箱升級警示、PC 產物「在電腦上」佔位。
  - `HomeDrawer.swift`：分段、「PC 工作區 · <電腦名>」默認分組、PC 空狀態、新會話禁用原因。
  - `NativeShell.swift`：兩個 backend 的 ChatPage 同時存活（草稿／滾動位置／turn 互不影響）。
  - `SettingsPage.swift`：我的 › 已連接的電腦。
  - `RootView.swift`：`pclink.notice` 橫幅、簽名 `unpaired` 二次確認 alert。
  - `project.yml`：App／ProbeKit／SimTests link `PhoneDSHPCLink`。
- ProbeKit：`Backends/WorkspaceStorage.swift`（P18 鍵與遷移）、`Backends/PCWorkspaceBackend.swift`（`PCWorkspaceBackend`、PC lifecycle no-op、注入 seam、配對狀態機、抽屜策略）。
- SimTests：`PhoneDSHSimTests/PCLinkWorkspaceSimTests.swift`（9 tests）。
- **不修改**：`Sources/**`、`spec/pclink/**`、`relay/**`、`pclink/**`、`android/**`。

### 4.3 能力隱藏與固定手機面

- PC backend `capabilities = (phoneOnlyEndpoints:false, supportsHostLifecycle:false, localFilePreview:false)`；`pause/resume/keepAlive` no-op。
- PC 不調 `phone/*`：`createSchedule`／`refreshAutomations`／`loadToolInventory` 以 `backendID == .phone` 為門；Bot session／device session 過濾只在 phone 生效。
- Bot runtime、`DeviceTaskManager`、設備會話、MCP/模型/Agent 預設仍固定手機；設定頁在 PC 分段顯示「這些設定屬於手機」的 safe-area 提示。
- PC 產物引用走 `openWorkspaceResult` 的 `localFilePreview == false` 分支，只提示「在電腦上」。

### 4.4 GAP-35 實際新增

> 本節是 D2 當時（main `da10d7466` 之前）的記錄。合入 `a3e41f853`（#69、#70）後的新數字與逐條歸屬見 §4.13.2；舊「12 + 5 = 17」已被 **1 + 6 = 7** 取代。

`python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → **FAIL (17)**：

- 既有 12 處：`connectors` missing-section；`daily-brief` extra-action「取消」；`files` missing-action「完成」；`home-drawer` extra-action「設置」；`native-automation` missing-action「完成」；`session-artifacts` extra-action「完成」；`settings` 2 missing-section + 4 missing-action。
- 本單新增 5 處（全部在 GAP-35）：
  1. `home-drawer` missing-action「手機」；
  2. `home-drawer` missing-action「PC」；
  3. `pc-pairing` missing-section `<android-screen>`；
  4. `connected-computer` missing-section `<android-screen>`；
  5. `settings` missing-action「已連接的電腦」（該分組首行變為「已連接的電腦」，故 2 條 missing-section 的名稱由「Phone DSH」「設置」變為「Phone DSH」「已連接的電腦」，條數不變）。
- 未加 whitelist、未改或增長 `_baseline.json`。

### 4.5 命令 → 結果

環境：Xcode 26.5（17F42）、iOS 26.5 模擬器 `pclink-iPhone17Pro`（`620D518D-D125-4154-B1B7-32A65327482B`）、macOS 宿主沙箱；SwiftPM 需 `CFFIXED_USER_HOME`／`-disable-sandbox`，XCTest 走 `simctl spawn`（ADAPTED，沿用 D1b）。

| 命令 | 結果 | 證據 |
| --- | --- | --- |
| `swift build --disable-sandbox` | **PASS** `Build complete! (35.53s)` | `/tmp/pclink-d2-swift-build.log` |
| `swift test --disable-sandbox --filter PhoneDSHPCLinkTests` | **PASS** 47 tests, 1 skipped, 0 failures | `/tmp/pclink-d2-swift-test.log` |
| `cd examples/probe-app && xcodegen generate` | **PASS** | 生成工程 |
| ADAPTED `xcodebuild -scheme PhoneDSHProbe ... build`（`CFFIXED_USER_HOME=/tmp/pclink-d2-home`、`OTHER_SWIFT_FLAGS=… -disable-sandbox`） | **PASS** `** BUILD SUCCEEDED **` | `/tmp/pclink-d2-build13.log`、`/tmp/pclink-d2-buildtests-final.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHSim ... build-for-testing` | **PASS** `** TEST BUILD SUCCEEDED **` | `/tmp/pclink-d2-buildtests-final.log` |
| ADAPTED `simctl spawn … xctest -XCTest PCLinkWorkspaceSimTests,ProbeKitHistoryTests,ProbeKitManagementTests,ProbeKitBackendTests,MessageFeedbackTests,ChatInputRecoveryTests,NativeChatPresentationTests,ChatWorkflowTests,ChatEventPumpTests,ComposerQueueTests,ProbeScenePhaseForwardingTests,PhoneAudioSessionLeaseTests` | **PASS** 79 tests, 0 failures（含新增 9 個） | `/tmp/pclink-d2-xctest-final.log` |
| `python3 -B spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS** `contracts up to date` | 終端 |
| `python3 -B spec/ui/v1/tools/ui_check.py --root .` | **PASS** `ok (…13 contrast pairs…)` | 終端 |
| `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (17)**：既有 12 + GAP-35 新增 5 | `/tmp/pclink-d2-pagecheck-final.txt` |
| `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance` | `phone-spec` **PASS**；`phone-cross-tree` **PASS**；`phone-p0-conformance` **FAIL**，唯一失敗是上述 17 處 page-structure | `/tmp/pclink-d2-ci-final.log` |

### 4.5.1 pclink-fix1 修復驗證（本次）

環境同 §4.5；`PATH=/tmp/node24/bin:$PATH`、`PDSH_NODE=/tmp/node24/bin/node`。所有命令均在本 head 的髒工作樹上實跑，未 commit。

| 命令 | 結果 | 證據 |
| --- | --- | --- |
| `cd relay && npm test` | **PASS** 54 tests, 0 fail | `/tmp/pclink-fix1-relay-test.log` |
| `cd pclink && npm test` | **PASS** 94 tests, 0 fail, 0 skip；含真實 DSH 0.2.2 整合（`approval answered … outcome=null`）與新的真實 relay 重啟回歸 | `/tmp/pclink-fix1-pclink-test.log` |
| `swift build --disable-sandbox` | **PASS** `Build complete! (8.11s)` | 終端 |
| `swift test --disable-sandbox --filter PhoneDSHPCLinkTests` | **PASS** 48 tests, 1 skipped, 0 failures | 終端 |
| `cd examples/probe-app && xcodegen generate` | **PASS** | 終端 |
| ADAPTED `xcodebuild -scheme PhoneDSHProbe … build CODE_SIGNING_ALLOWED=NO`（`CFFIXED_USER_HOME=/tmp/pclink-d2-home`、`OTHER_SWIFT_FLAGS=… -disable-sandbox`、derived data `/tmp/pclink-fix1-dd`） | **PASS** `** BUILD SUCCEEDED **` | `/tmp/pclink-fix1-build3.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHSim … build-for-testing` | **PASS** `** TEST BUILD SUCCEEDED **` | `/tmp/pclink-fix1-buildtests-final.log` |
| ADAPTED `simctl spawn … xctest -XCTest PCLinkWorkspaceSimTests,ProbeKitHistoryTests,…,PhoneAudioSessionLeaseTests` | **PASS** 80 tests, 0 failures（含新增 pairing-stream 1 個） | `/tmp/pclink-fix1-xctest-final.log` |
| `python3 -B spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS** `contracts up to date` | 終端 |
| `python3 -B spec/ui/v1/tools/ui_check.py --root .` | **PASS** `ok (…13 contrast pairs…)` | 終端 |
| `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (17)**：既有 12 + GAP-35 5，與 §4.4 完全一致（pc-pairing / connected-computer 之名稱因 provenance 重新產生而變，條數不變） | `/tmp/pclink-fix1-ci-p0.log` |
| `CI_PROTOCOL_BASE=627aed351484f98fc9e29c4f238937e6c818c8cf PDSH_NODE=/tmp/node24/bin/node bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance,phone-sdk,phone-modules` | `phone-spec` **PASS**、`phone-cross-tree` **PASS**、`phone-p0-conformance` **FAIL**（僅上述 17 處 page-structure）、`phone-modules` **PASS**、`phone-sdk` **FAIL（宿主限制，非 PhoneWire SKIP）**：`swift test` 的 SwiftPM manifest 呼叫 `sandbox-exec` 被宿主拒絕（`sandbox_apply: Operation not permitted`），與 §4.5 的「SwiftPM 需 `-disable-sandbox`」一致；同一工作樹的 `swift test --disable-sandbox --filter PhoneDSHPCLinkTests` 已 **PASS** | `/tmp/pclink-fix1-ci-final.log`：`CI GATE: FAIL`，唯一非預期失敗是 phone-sdk 的宿主 sandbox |

### 4.6 真實三端 E2E（模擬器 + 本機中繼 + 真 DSH 0.2.2）

設定：`relay` 於 `127.0.0.1:3240`（`PCLINK_PUBLIC_ORIGIN=http://127.0.0.1:3240`）；PC `dsh web` 於 `127.0.0.1:3241`，`DSH_HOME` 為 `.spike/` 下 mkdtemp，憑證由 pclink-c 的 `.spike/home/.credentials.yaml` 複製且 `0600`（未列印）；`--patch` 以絕對 `pclink/plugin/index.js` 載入；PC 名稱 `D2 Test PC`。App 於專用模擬器。

**宿主限制（ADAPTED）**：
- `script`／`pty.openpty` 被宿主沙箱禁止（`openpty: Operation not permitted` / `out of pty devices`），因此無法跑 `script -q /dev/null … pclink pair` 的 CLI TTY 路徑；改用同一插件的 admin API（`AdminClient.pair/approve`）完成等價的 compare-the-phone 流程。**CLI TTY 批准路徑：NOT_RUN**。
- 未簽名模擬器 build 的 Keychain identity 回 `errSec`（截圖 `00-pairing-keystore-error.png`）；App 以 DEBUG-only `PDSH_PCLINK_FILE_IDENTITY=1` 的 0600 檔案 seed store 跑 E2E。正式版仍用 `PCLinkKeychainIdentityStore`。真機 Keychain：NOT_RUN。
- 宿主無法向 Simulator App 容器寫檔；自動化命令檔以 `xcrun simctl spawn <udid> /bin/sh` 寫入容器（同一 App 讀取），UI 操作（切段、發送、批准）由 DEBUG 自動化呼叫同一 `ChatModel`／`PCPairingFlow` API。未使用 point-and-tap。

| # | 步驟 | 結果 | 截圖／證據 |
| --- | --- | --- | --- |
| 1 | 啟動 relay + PC `dsh web --patch` | **PASS**：`[pclink] started relay=http://127.0.0.1:3240`；`dsh web: http://127.0.0.1:3241/?token=…`（token 不記錄） | PC job log；`curl /healthz` → `{"ok":true}` |
| 2 | PC 開配對，App 配對頁粘貼 `pclink://pair?...` | **PASS**：頁面顯示本機指紋 `mo5e-abda-tzel`、§4.6 完整告知、電腦名稱；PC 以同一指紋批准，`pair.final` 完成 | `01-pairing-fingerprint.png`、`02-pairing-awaiting.png`；PC log `pairing completed` |
| 3 | 切 PC 分段 → PC 會話列表 → 新會話 | **PASS**：抽屜「PC 工作區 · D2 Test PC」、1 個會話；`session-21fca880-…` | `05-pc-drawer.png`、`06-pc-drawer-session.png` |
| 4 | 發「只回复 OK」 | **PASS**：真實模型回 `OK`，串流與用量正常 | `08-pc-chat-ok.png` |
| 5 | 發「请使用 bash 工具执行 date 命令」→ 逐个审批 | **PARTIAL**：審批卡以既有 UI 顯示工具 `date`、原因與「沙箱升級到完全權限」警示；批准後同一 turn 出現第二張 `whoami` 審批，逐個回答；PC 實際執行 `date` 並回傳結果。**但** App 收到 `bad_frame: rpc.result ok/result mismatch`，卡片不會自動消失（CCR-1）。 | `09/10/14`、`26-multi-approval-1.png`、`27-multi-approval-2.png`、`28-multi-approval-done.png` |
| 6 | 關 relay → App 離線（停在 PC）→ 重啟 relay | **PARTIAL**：App 正確顯示「電腦離線」、發送停用、草稿保留、不自動切回手機；抽屜離線空狀態 + 重試（`16`、`17`）。Relay 重啟後手機端持續重連，但 **PC plugin 沒有再連上 relay**（log `relay socket error: non-101` 後停止；CCR-3），因此純 relay 重啟未恢復。手動重啟 PC `dsh web` 後同一 App 自動重連、會話列表與當前會話補齊（`18`）。 | `16-pc-offline.png`、`17-pc-offline-drawer.png`、`18-pc-reconnected-drawer.png`；relay log 顯示 phone 每 ~27s 重連、PC 無新連線 |
| 7 | PC `unpair --all`（admin API，無 TTY） | **PASS**：App 收到簽名 `unpaired`，彈「電腦已解除與此手機的配對」；保留記錄則不刪；確認後 `acknowledgePCUnpair()` 刪除本機記錄並停在 PC 未配對空狀態。 | `19-pc-unpaired-alert.png`、`20-pc-unpaired-after.png` |
| 8 | 已連接的電腦頁 | **PASS**：名稱／版本（驗證範圍）／在線／本機指紋／中繼／配對時間／配對新電腦（先解除）／解除配對。 | `21-connected-computer.png`；dark `25-connected-computer-dark.png` |
| 9 | 手機分段抽屜與聊天回歸 | **PASS**：手機工作區、會話、聊天 UI 與改動前一致（只多了頂部分段）。 | `22-phone-drawer.png`、`23-phone-chat.png` |
| 10 | 關鍵頁 dark | **PASS**：PC 聊天與已連接的電腦在 dark 下可讀。 | `24-pc-chat-dark.png`、`25-connected-computer-dark.png` |

**相機掃碼：NOT_RUN**（模擬器無相機；頁面顯示無相機 fallback 並保留粘貼／手動入口）。**真實公網 WSS 中繼：NOT_RUN**（本機 `ws://127.0.0.1:3240`）。**真機：NOT_RUN**。

### 4.6.1 pclink-fix1 三端 E2E（本次重跑）

設定與 §4.6 相同但全部重新起：真實 `relay/relay.mjs` 於 `127.0.0.1:3240`（`PCLINK_PUBLIC_ORIGIN=http://127.0.0.1:3240`）；真實 DSH 0.2.2 `dsh web` 於 `127.0.0.1:3241`（`DSH_HOME` 為 `.spike/` 下 mkdtemp；憑證複製為 0600，未列印）；插件以絕對 `pclink/plugin/index.js` 載入並使用測試用 `dsh-approval-policy.mjs`（每個 bash 都經真實 `ctx.approval` 問一次）；PC 名稱 `Fix1 Test PC`。App 為本 head 建置的未簽名模擬器 build，於專用模擬器 `620D518D-D125-4154-B1B7-32A65327482B`，使用 DEBUG 的 0600 檔案身分 store 與 DEBUG 自動化命令檔；UI 掃描截圖，操作呼叫同一 `ChatModel`／`PCPairingFlow` API。**未使用 point-and-tap**。

| # | 步驟 | 結果 | 截圖／證據 |
| --- | --- | --- | --- |
| 1 | 起真實 relay + PC `dsh web --patch` | **PASS**：plugin `relay socket open` → `relay=connected`；admin status 的 relay state `connected` | `/tmp/pclink-fix1-relay.log`、`/tmp/pclink-fix1-web.log`、`/tmp/pclink-fix1-e2e-steps.json` |
| 2 | App 配對頁（真實 fingerprint + §4.6 告知）→ PC 以同一指紋批准；**手機自動完成並進入 PC 工作區**（無第二次點擊） | **PASS**：PC `pairing awaiting approval` → approve → `pair.final`；App 自動切到 `backend=pc` 且 `peerDshVersion=0.2.2-rc.1`；未按「完成」 | `01-pairing-waiting.png`（等待批准＋指紋＋按鈕）、`02-pc-workspace-after-pairing.png`（已進入 PC 工作區） |
| 3 | PC 會話列表／新會話 | **PASS**：`session-fea30415-…`（本次 run）建立；抽屜顯示「PC 工作區 · Fix1 Test PC」1 個會話 | `03-pc-session.png`、`11-pc-drawer-after-recovery.png` |
| 4 | 發「只回复 OK」 | **PASS**：真實模型回 `OK`，turn 完成、無 `userFacingError` | `04-pc-chat-ok.png` |
| 5 | bash 審批逐個回答；卡片消失、無 `bad_frame` | **PASS**：1 個 `bash` 審批；回答後 `pendingPermission=""`，`userFacingError=""`（沒有 `bad_frame`/`invalidResponse`），工具實際執行 `date` 並回傳輸出；turn 正常結束 | `05-approval-1.png`（卡片）、`06-approval-answered-1.png`（卡片已消失、命令已執行）、`07-approval-turn-done.png` |
| 6 | 殺 relay → 等待 → 同埠重啟 relay；**不重啟 dsh web** | **PASS**：App 先顯示「電腦離線」；重啟後 plugin **1226 ms** 重新鑑權並重發 `relay.allow`，App **6265 ms** 自動回到在線；`dsh web` PID 不變（4497）、PC machineId 不變；重連後再發「只回复 OK」成功 | `08-pc-offline.png`、`09-pc-reconnected.png`、`10-pc-chat-after-reconnect.png`；plugin 日誌有第二次 `relay socket open` |
| 7 | 已連接的電腦頁顯示實際 DSH 版本 | **PASS**：`DSH 版本 0.2.2-rc.1`，在線；範圍內不顯示「版本未驗證」常駐提示 | `12-connected-computer-version.png` |
| 8 | PC `unpair --all` → App 簽名 reject 二次確認刪除 | **PASS**：PC 記錄清零；App 收到簽名 `unpaired` 提示（保留/刪除二選一），確認後本機記錄刪除、`paired=false`，停在 PC 未配對狀態 | `13-pc-unpaired-alert.png`、`14-pc-unpaired-after.png` |

**ADAPTED／NOT_RUN**：CLI 的 TTY 批准與 `unpair` 確認仍受宿主 pty 限制，E2E 以同一插件的 admin API 做 compare-the-phone 批准、以 `runUnpair(..., stdinIsTTY:true, confirm:'yes')` 跑 CLI 命令實作；**真實 TTY 路徑 NOT_RUN**。**真機 Keychain／相機掃碼／公網 WSS：NOT_RUN**。E2E 的「我已批准，繼續配對」由 DEBUG `PDSH_PCLINK_AUTOCONFIRM=1` 代替人手點擊（僅為無人值守）；按鈕與狀態流本身由 `testPairingCompletesFromClientUpdateStreamAfterPCConfirm` 覆蓋。結束已關閉 relay／dsh web／App，並刪除臨時 `DSH_HOME`。

### 4.7 CCR / 缺口（D2 發現；處置見 §4.7.1）

1. **CCR-1（P28 / C 端 PC plugin）**：`$events/result` 等 DSH 端點在沒有 `result.value` 時，PC plugin 產生 `{type:"rpc.result", ok:true}` 而沒有 `result` 成員；`spec/pclink/v1/schema/inner-message.schema.json` 要求 `result` 必填，Swift `PCLinkClient.dispatchResult` 因此報 `bad_frame: rpc.result ok/result mismatch`。證據：E2E 批准後 `Permission response failed: invalidResponse("bad_frame: rpc.result ok/result mismatch")`；PC 實際已執行工具；`goals/get` 亦同。**Proposal**：PC plugin 對 `ok:true` 永遠輸出 `result`（無值時 `null`），或契約明確允許缺省並由 Swift 接受；在 C 端修復前不改 Swift/Sources 繞過。
2. **CCR-2（P28 / D API）**：`PCLinkClientStatus` 只暴露超出範圍時的 `versionWarning.dshVersion`；握手成功且在驗證範圍內時，App 無法顯示電腦的實際 DSH 版本（「已連接的電腦」只能顯示「驗證範圍內」）。**Proposal**：在 `PCLinkClientStatus` 增加 `peerDshVersion: String?`（及可選 `peerAppName`），由已驗證的 `peer.hello` 填入；wire 不變。owner P28。
3. **CCR-3（P28 / C 端 PC plugin）**：relay 重啟後 PC plugin 只嘗試一次並在 `relay socket error: non-101` 後停止重連；手機端持續重連。需要 C 端 relay 重連監督修正並用真實 relay 重啟回歸；owner P28 B/C。
4. **宿主 pty 限制**：`script`／`openpty` 不可用，CLI TTY 批准路徑 NOT_RUN；admin API 等價流程已跑通。不是產品缺陷。
5. **未簽名模擬器 Keychain**：`PDSH_PCLINK_FILE_IDENTITY=1` 只為 E2E；正式版仍 Keychain。真機 Keychain 未驗證。
6. `Package.resolved` 在 build 過程被 Xcode 寫入 app 本地 SwiftMarkdown/SwiftMath pin；已手動還原，未提交（P24 無變更）。

### 4.7.1 CCR 處置（pclink-fix1，已關閉）

協調者裁定三條 CCR 都是實作偏離既有契約，**不改 `spec/**` 與 `relay/**`**；契約 revision 保持 `pclink-v1.3`。

| CCR | 根因 | 修復位置 | 測試／證據 |
| --- | --- | --- | --- |
| **CCR-1**（C 端） | `rpc.call` 的成功回應在 DSH 無 `value`（`$events/result`、`goals/get` 等）時省略 `result`，`JSON.stringify` 也不會補 `undefined`；違反 `inner-message.schema.json` 的 `required:["…","result"]`。 | `pclink/plugin/session-manager.mjs`：`ok:true` 一律 `result: body.result.value ?? null`；`sendCallResult` 對編碼器拒絕的結果回一個合法的 correlated error，不再送出非法幀。`pclink/core/inner.mjs`：`encodeInnerMessage` 先 `JSON.stringify`，再 strict parse 後 `validateInnerMessage`，以**序列化後**的內容自檢（可抓到 `undefined` 被丟掉的成員）。`pclink/core/chunking.mjs`：`encodeUnaryResult` 先驗證序列化後的 `rpc.result`（含 `ok:true` 的 `result`），再決定單幀或 chunk。 | `pclink/test/session.test.mjs`：`ok:true always carries result; absent DSH values become null ($events/result, goals/get)`、`PC never emits an ok rpc.result without an own result member`；`pclink/test/vectors.test.mjs`：`encoder self-checks the serialized rpc.result and refuses a missing result`；真實 DSH 整合：`[integration] approval answered … outcome=null`（若缺 result，這段無法成立）。修改前後二個 session 回歸會分別因 `result` 缺失／編碼器未自檢而失敗。 |
| **CCR-3**（C 端） | relay 重啟期間的 `error`（例如非 101）之後若 runtime 沒送 `close`，監督器只記 log，永遠不再排程；連線卡住也沒有上限。 | `pclink/plugin/relay-link.mjs`：新增冪等的 `disconnectSocket` 單一失敗出口；`error` 後 250 ms 寬限，沒有 `close` 就主動斷線並進入退避；每次連線有 15 s 鑑權 watchdog；`close`／心跳逾時／協議錯誤／建構子例外全部走同一退避；`scheduleReconnect` 去重；只有 `replaced` 使用契約最少 30 s（實作為 30–36 s），其餘 0.5 s→30 s（±20 %），60 s 穩定後重置。 | `pclink/test/relay-link.test.mjs`：`a connection error without a close event still enters backoff and reconnects`、`a connect attempt that never authenticates times out and reconnects`、既有 `a replaced relay connection waits at least 30 seconds before reconnecting`；`pclink/test/relay-restart.test.mjs`：`PC relay supervisor re-authenticates and re-sends relay.allow after a real relay restart`，直接載入真實 `relay/src/server.mjs`（不是 `relay-stub`），同 origin/port 重啟，記錄真實 WebSocket 上的第二次 `relay.allow`。E2E §4.6.1 #6：plugin 1226 ms、App 6265 ms 自動恢復。 |
| **CCR-2**（D API） | `PCLinkClientStatus` 只在超範圍時透過 `versionWarning.dshVersion` 暴露 DSH 版本，範圍內無法顯示實際版本。 | `Sources/PhoneDSHPCLink/PCLinkClient.swift`：新增 `peerDshVersion`、`peerAppName`、`peerAppVersion`，由已驗證的 `peer.hello` 在 `install`／rekey 時填入；unpair／ack／remove／新配對時清除。`examples/probe-app/PhoneDSHProbe/PCLinkWorkspace.swift` 暴露同名讀取；`ConnectedComputerPage.swift` 顯示實際版本，超範圍時加「（未驗證）」並把常駐提示移到 footer（在線與離線都顯示）。 | `Tests/PhoneDSHPCLinkTests/RelayDSHTransportTests.swift`：`testPeerHelloExposesDshAndAppMetadataInRange`、`testOutOfRangeDSHVersionIsOnlyAWarning`（含 `peerDshVersion=0.3.0`）；E2E `12-connected-computer-version.png` 顯示 `0.2.2-rc.1`。 |
| **配對自動完成**（順帶 4） | 原本只有按鈕的 `confirmPairing` 會寫入記錄；頁面等待只能靠一次按鈕呼叫。 | `PCLinkClient` 新增 `PCLinkPairingUpdate` 與 `pairingUpdates()`（`awaitingApproval`／`completed`／`failed`）；`PCPairingFlow` 訂閱該流，收到 `pair.confirm` 後的 `.completed` 即進 `.paired`（`finish` 冪等）。`PCPairingPage` 在 `.paired` 時自動 `models.select(.pc)` 並於 0.9 s 後關閉配對頁；「我已批准，繼續配對」按鈕保留為明示同意／逾時重試入口，footer 說明此行為。 | `PhoneDSHSimTests/PCLinkWorkspaceSimTests.swift`：`testPairingCompletesFromClientUpdateStreamAfterPCConfirm`（confirm 呼叫仍 pending 時，狀態流送達 `.completed` 即 `.paired`，`confirmCalls==1`，無第二次按鈕）；E2E §4.6.1 #2：PC 批准後 App 自動進 PC 工作區，未按「完成」。 |
| **CI 門禁**（順帶 5） | `phone-sdk` 的 `sdk_filter` 沒有 `PhoneDSHPCLinkTests`，沒有門禁執行它。 | `scripts/ci/check.sh` 的 `sdk_filter` 加入 `PCLink`（`PhoneDSH(…|PCLink)Tests` 覆蓋既有 `PhoneDSHPCLinkTests` target；未改其他階段）。 | 本 head 的 `phone-sdk` 仍因宿主 SwiftPM manifest sandbox 失敗（見 §4.5.1），但 filter 已能匹配；同一 target 的 `swift test --disable-sandbox --filter PhoneDSHPCLinkTests` **PASS** 48 tests。 |

**契約影響**：wire 與 relay 皆未變；`spec/pclink/**`、`relay/**` 零修改。App 頁面文案／自動導航變更僅機械更新 `spec/ui/v1/pages/connected-computer.json` 與 `pc-pairing.json` 的 `file:line` provenance（由 `extract_ios_pages.py` 產生；`extract --check` PASS，`page_structure` 仍為既有 17 處）。

### 4.8 Protocol impact（建議提交）

```text
Protocol impact: P09; P18; P28; P24: none — project.yml links the existing local PhoneDSHPCLink product, Package.resolved unchanged; P12: none — no Package.swift/native ABI change; P06: none — PC harness reuses DSHRemoteHarness without event semantics change; P14: none — relay transport consumes the existing DSHRemoteTransport/mux; P16: none — no PDSH_* env or Worker URL change; P27: none — no Bot row/user-action change.
```

理由：P09 新增/更新页面契约与 provenance；P18 新增持久化键、scope 与一次性迁移；P28 App 接现有 PCLink client/transport/harness（不改 PCLink 契约）。

pclink-fix1 的建議提交訊息與 impact（§4.7.1）：

```text
fix(pclink): always send rpc.result.result, keep reconnecting after relay restarts, expose peer DSH version

Protocol impact: P28; P09; P18: none — no storage key, scope or migration change; P24: none — Package.resolved restored unchanged; P12: none — no Package.swift/native ABI change; P06: none — no DSH event semantics change; P14: none — reuses the existing DSHRemoteTransport/mux; P16: none — no PDSH_* env or Worker URL change.
```

理由：P28 是 C 端插件/編碼器行為與 D 端 `PCLinkClientStatus`/配對狀態流的修復（wire 與 `spec/pclink` 不變）；P09 是已連接的電腦頁版本列與配對頁自動導航／文案，及由提取工具機械產生的 provenance 更新。


### 4.9 pclink-f2s 全分支审查修复（本轮）

Base `2fc4dbf29`，分支 `fix/pclink-f2-swift`，脏工作树，未 commit。冻结契约仍是 `pclink-v1.3`；本轮未发现需要 `CONTRACT CHANGE REQUEST` 的契约缺口，`spec/pclink/**` 零修改。AEAD 解密失败按 §5.4「Any change to v/type/sid/seq/from/to fails decryption (`auth_failed`)」映射为 `auth_failed`（不是 `bad_frame`）；`seq` 顺序错误仍按 §5.4 分成 `replay`/`bad_frame`。

#### 4.9.1 问题 → 修复 → 回归测试

| # | 问题 | 修复位置 | 回归测试 |
| --- | --- | --- | --- |
| 1 High | mux 局部 `events`/`follow` 原样上线；同会话第二次 follow 被 PC 以 streamId 重用拒绝 | `PCLinkE2E.allocateWireStreamID()` 每会话计数器；`PCLinkClient.MuxState.wireToLocal`/`StreamState.wireStreamID` 双向映射，路由按 `(sid, 线上 ID)`，收帧换回局部 ID | `RelayDSHTransportTests.testWireStreamIDsAreSessionUniqueAcrossMuxesAndSessions`、`testMuxStreamItemsAndEnd`、`testMuxCancelReachesPCAndEndsStream`；`FakePCServer.registerOpenStreamID` 强制唯一并发 `rpc.stream.error` |
| 2 High | `seal` 后 `await relay.send`/`socket.send` 让出，线上 seq 可能乱序 | `PCLinkClient` 单 outbound writer：seal+入队同一 actor 临界区；`PCLinkRelayClient` 单 socket writer（FIFO），所有发送经 writer | `RelayDSHTransportTests.testConcurrentCallsKeepWireSeqStrictlyIncreasing`（48 并发 + 奇偶延迟注入，断言 PC 收到 seq 严格连续）；`testStopWaitsForOldLoopAndStartIsIdempotent` |
| 3 Medium | 旧 `chat.drafts.v1` 是 `@AppStorage` JSON **字符串**，迁移/回退按字典读；marker 后仍回退旧键 | `WorkspaceStorage.legacyDraftsMap` 先 `string(forKey:)` JSON 解码、再兼容字典；`legacyFallbackAllowed` 在 marker 后关闭 current-session/drafts/title-hints/collapsed 旧键回退 | `PCLinkWorkspaceSimTests.testMigrationCopiesLegacyKeysAndIsIdempotent`（改用 JSON 字符串）、`testLegacyDraftJSONStringAndDictionaryCompatibility`、`testClearedDraftAndCollapsedSetDoNotReviveAfterMigration` |
| 4 Medium | `relay.offline` 把所有 pending call 判 `peer_offline`，已发出的 unsafe 应为 `unknown_outcome` | `PCLinkClient.handleRelayOffline`/`failPendingForRelayDrop`：仅匹配 `id` 的帧确定未送达；`sid`-only 已发调用走 `PCLinkSessionLost`（§7 决定 unknown_outcome/重试） | `testRelayOfflineForSentUnsafeCallIsUnknownOutcome`、`testRelayOfflineWithCorrelationIDIsPeerOffline` |
| 5 Medium | `peer.hello` 能力无交集只抛错，未发 `session.close{version_unsupported}`，未禁止重试 | `PCLinkClient.sendVersionUnsupportedClose`（握手阶段可 seal）、`handleSessionError(.versionUnsupported)` 终止并置 `offline(.versionUnsupported)`；UI 文案提示升级 | `testNoCapabilityIntersectionClosesVersionUnsupportedAndDoesNotRetry`、`testVersionUnsupportedCopyTellsTheUserToUpgrade` |
| 6 Medium | `rate_limited` 被忽略，调用悬挂 | `PCLinkClient.handleRelayEvent(.rateLimited)` 拆会话、记录 `retryAfterMs`，连接循环以 `max(backoff,retryAfter)` 重连；pending 按 §7 处理 | `testRateLimitedTearsDownWaitsRetryAfterAndReconnects`（3 s 上限，旧实现会失败而非挂起） |
| 7 Medium | `stop()` 先 await 旧 task，旧循环停在 `waitForDisconnect` 时会死锁；快速 stop/start 可能双循环 | `performStop` 先 `signalDisconnect()` + teardown，再 await 旧 task；`connectionGeneration` 防旧循环接管；`start` 等待在途 stop | `testStopWaitsForOldLoopAndStartIsIdempotent`（重复 start + 5 次 stop/start，连接数精确） |
| 8 Medium | `beginPairing` 在加载记录前检查「已有配对」，可能覆盖磁盘记录 | 先 `loadIdentityAndRecordIfNeeded()` 再检查 `record` | `PCLinkPairingFlowTests.testBeginPairingLoadsRecordBeforeAlreadyPairedCheck`（注入立即失败的 factory，旧代码会走到网络路径） |
| 9 Medium | `relay.ready` 早于 `awaitReady` 安装等待者时被丢 | `PCLinkRelayClient` 缓存 `readyReceived`（并同样缓存早到 challenge） | `PCLinkRelayClientTests.testReadyArrivingBeforeWaiterIsCached` |
| 10 Medium | 默认中继占位是 `wss://`，而 origin 校验只接受 http(s) | `ProbeKit/PCLinkRelayConfiguration.swift` 单点占位 `https://relay.example.invalid`；DEBUG 环境 loopback 归一化为 http，`PCLinkValidation.websocketURL` 统一派生 ws(s) | `testQRAndManualOriginsDeriveWSSURLs`、`testRelayPlaceholderOriginAndLoopbackNormalization`、`testOriginOnlyAllowsHTTPSOrLoopbackHTTP` |
| 11 Medium | scenePhase 只转给 `ChatModel.shared`，PC 后端回前台不重连/不补帧 | `PhoneDSHProbeApp` 转发 `WorkspaceModels.scenePhaseChanged(true)`；`PCLinkWorkspace` 调 `foregroundResumed`；`ChatModel.foregroundResumedForPC` 从 `lastSeq` 重开 follow；`PCLinkClient.foregroundResumed` 替换挂起连接 | `PCLinkWorkspaceSimTests.testForegroundWakesPCClient`、`RelayDSHTransportTests.testForegroundResumedReplacesTheSuspendedConnection` |
| 12 Low | `PDSH_DEBUG_DRAWER` 在 Release 仍被读取 | `ProbeKit/NativeDebugDefaults.drawerOpen` 的 `#if DEBUG` 分支；`NativeShell` 只调该 helper | `PCLinkWorkspaceSimTests.testDebugDrawerDefaultIsEnvironmentGated`；Release 分支由编译条件保证 |
| 13 Low | PC 返回的 sessionId 直接拼文件路径，可穿越 | `WorkspaceStorage.isValidSessionID`（DSH 字符集、拒绝 `/`/`..`）；`transcriptSnapshotURL`/legacy 返回 `nil`；`ChatModel` 拒绝写入 | `PCLinkWorkspaceSimTests.testSessionIDPathValidationRejectsTraversal` |
| 14 Low | 解除配对后残留 `pc:<machineId>` 草稿/快照 | `PCLinkWorkspace` 在 unpair/ack/remove 确认删除后调 `WorkspaceStorage.removeLocalData(for:)`（只删该 scope） | `PCLinkWorkspaceSimTests.testUnpairCleanupRemovesOnlyScopedDraftsAndSnapshots` |
| 15 Low | 迁移 snapshot 用 `copyItem`，非原子 | 迁移改为 `Data.write(.atomic)`（临时文件 + rename） | `testMigrationCopiesLegacyKeysAndIsIdempotent`（内容/幂等；原子性由 `.atomic` API 保证） |
| 16 Low | `rpc.result` 未知成员被忽略；流分块超限不发 cancel；closeMux 用错 chunk 键；AEAD 失败映射成 `bad_frame` | `dispatchResult` 使用 `closedObject` 拒未知成员；`handleStreamFrame` 超限后 `rpc.stream.cancel`；`closeMux` 用 wire id 清 `streamChunks`；`PCLinkE2ESession.open` AEAD 失败抛 `auth_failed` | `testRpcResultWithUnknownMemberIsBadFrame`、`testOversizedStreamChunkSendsCancel`、`testCloseMuxClearsPartialChunkBufferByWireKey`、`testAEADFailureMapsToAuthFailed` |
| 17 Low | 非 loopback `http` origin 被接受 | `PCLinkValidation.origin` 仅允许 `https` 或 loopback `http`（`127.0.0.1`/`localhost`） | `testOriginOnlyAllowsHTTPSOrLoopbackHTTP`、`testQRAndManualOriginsDeriveWSSURLs` |
| 18 Low | 「已连接的电脑」显示 ISO 原文 | `PCLinkWorkspaceText.pairedAtDisplay`（RFC 3339 → 本地化 long date + short time）；`ConnectedComputerPage` 使用它 | `PCLinkWorkspaceSimTests.testPairedAtIsLocalizedNotISO`（zh_CN/UTC 断言 `2026年11月10日 03:13`） |

#### 4.9.2 命令 → 结果（本轮实跑）

| 命令 | 结果 | 证据 |
| --- | --- | --- |
| `swift build --disable-sandbox` | **PASS** `Build complete! (7.29s)` | `/tmp/pclink-f2-build-final3.log` |
| `swift test --disable-sandbox --filter PhoneDSHPCLinkTests` | **PASS** 63 tests, 1 skipped, 0 failures | `/tmp/pclink-f2-test-final4.log` |
| `cd examples/probe-app && xcodegen generate` | **PASS** | `/tmp/pclink-f2-xcodegen2.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHProbe ... build`（模拟器 `620D518D-D125-4154-B1B7-32A65327482B`、`/tmp/pclink-f2-dd`、`CFFIXED_USER_HOME=/tmp/pclink-f2-home`、`-disable-sandbox`） | **PASS** `** BUILD SUCCEEDED **` | `/tmp/pclink-f2-xcodebuild-final2.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHSim ... build-for-testing` | **PASS** `** TEST BUILD SUCCEEDED **` | `/tmp/pclink-f2-buildtests-final.log` |
| ADAPTED `simctl spawn … xctest -XCTest PCLinkWorkspaceSimTests,ProbeKitHistoryTests,ProbeKitManagementTests,ProbeKitBackendTests,MessageFeedbackTests,ChatInputRecoveryTests,NativeChatPresentationTests,ChatWorkflowTests,ChatEventPumpTests,ComposerQueueTests,ProbeScenePhaseForwardingTests,PhoneAudioSessionLeaseTests` | **PASS** 89 tests, 0 failures | `/tmp/pclink-f2-simtests-final.log` |
| `python3 -B spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS** `contracts up to date` | `/tmp/pclink-f2-extract-check3.log` |
| `python3 -B spec/ui/v1/tools/ui_check.py --root .` | **PASS** `ok (13 contrast pairs, 6 deferred AA pairs…)` | `/tmp/pclink-f2-ui-check3.log` |
| `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (17)**：既有 12 + GAP-35 的 5，与 §4.4 一致 | `/tmp/pclink-f2-page-check3.log` |

**NOT_RUN**：真实 relay + 真 DSH 的三端 E2E（本轮未重跑）、真机 Keychain/相机、公网 WSS、`xcodebuild test`（改用同 bundle 的 `simctl spawn`）、Release 配置的独立构建。**ADAPTED**：xcodebuild 走本机模拟器与 `-disable-sandbox`；`simctl spawn` 为同 bundle 的既有回退路径。`Package.resolved` 被 Xcode 改写后已按 HEAD 恢复，未纳入改动。

#### 4.9.3 建议提交信息（Protocol impact）

```text
fix(pclink): session-unique stream ids, ordered E2E sends and iOS app fixes

Protocol impact: P28; P09; P18; P24: none — Package.resolved restored unchanged; P12: none — no Package.swift/native ABI change; P06: none — no DSH event semantics change; P14: none — reuses the existing DSHRemoteTransport/mux; P16: none — no PDSH_* Worker URL/env change; P01/P02/P04/P05/P10/P11/P13: none — no relay wire, WAL, bridge, loopback HTTP or plugin protocol change.
```

理由：P28 是 PCLink 客户端会话/流/发送顺序与 relay 事件处理；P09 是「已连接的电脑」配对时间显示与 provenance；P18 是旧草稿格式读取与解除配对后的本地清理/路径校验。契约 revision 保持 `pclink-v1.3`。

### 4.10 `pclink-pacing` P18 追加（`pclink-v1.5`）

PC 新會話的工作區選擇需要記住「上次使用的工作區」，這是本單新增的 P18
持久化鍵，先登記再改代碼：

- **鍵**：`phone-dsh.pc.last-workspace.<machineId>`；`<machineId>` 為配對記錄
  的 PC machineId（26 字元 base32），與 `BackendID.storageScope` 的
  `pc:<machineId>` 同源。
- **值域**：單一 DSH `workspaceId` 字串（伺服器簽發，非使用者文字）；空字串、
  缺失或該工作區已不在 `workspace/follow` baseline 時，回退到最近活動的工作區
  （`recentWorkspaceID`），不阻止新建會話。
- **寫入時機**：只在 PC 分段、新會話/空會話的工作區選擇器變更時寫入；不隨
  每個會話寫。手機分段不讀不寫本鍵。
- **清理**：解除配對（`removeLocalData(for: .pc(...))`）時刪除該 machineId 的
  鍵；不刪除其他 PC 或其他 scope 的鍵。
- **相容／回滾**：全新鍵，沒有舊 consumer；舊版 App 忽略本鍵，回滾後只失去
  「上次選擇」，不影響配對、會話或草稿。
- **實作**：`ProbeKit/Backends/WorkspaceStorage.swift`
  （`WorkspaceStorageKeys.pcLastWorkspacePrefix` 與存取函式）、
  `PhoneDSHProbe/ChatPage.swift` 的工作區膠囊、
  `PhoneDSHProbe/DSHManagementModel.swift` 的 `createSession`。
- **權威登記**：`spec/README.md` §3.1 P18 行（本單追加句）。

修訂紀錄：`pclink-pacing-r1` 只追加 P18 鍵；P28 的 `pclink-v1.5` 變更見
`PC-20261109-pclink-v1.md` §4.16。

### 4.11 `pclink-pacing` P09 UI 變更（本輪）

- **分段位置**：`HomeDrawer.body` 的「手机 | PC」由「新会话」上方移到下方；
  `pages/home-drawer.json` 的 `sectionNote`、`source.renderedFrom`、action
  provenance 與 note 同步；`spec/ui/v1/README.md` §1 抽屜描述同步。Android
  仍無 PC 分段，差異留在 GAP-35，`page_structure_check --baseline` 仍為
  **17**（不新增 baseline/whitelist）。
- **抽屜讀取狀態**：PC 分段在 `session/list` 進行中顯示「正在读取 PC
  会话…」；失敗時顯示既有錯誤列（訊息 + 重試），且不再落到「还没有 PC
  会话」空狀態。規則抽成 `PCLinkDrawerPolicy.listState(isLoading:error:sessionCount:)`，
  `PCLinkPacingSimTests.testDrawerListStateNeverShowsEmptyWhileLoadingOrAfterAnError` 覆蓋。
- **大列表**：分組容器由 `VStack` 改為 `LazyVStack`（保留既有 ScrollView、
  自訂列樣式、contextMenu 與摺疊狀態；未改成 `List`，避免改寫整頁 chrome
  與 Android 對齊）。3,000+ 行只建立可視列；取捨記錄在此。
- **PC 工作區分組**：PC 分段不再把全部會話放進「PC 工作區 · <電腦名>」。
  組名直接用 `workspace/follow` 的 DSH workspace title；`sessionIds` 未收錄
  的會話按 `cwd` 最長路徑前綴歸組（`PCLinkWorkspaceGrouping`），其餘 PC
  會話單列「未分组」；手機分段的預設「手机工作区」規則不變。
  `PCLinkPacingSimTests.testPCWorkspaceGroupingUsesMembershipThenLongestCwd` 覆蓋。
- **Pin 依據**：DSH 0.2.2 的 Web 新會話由 `workspace/follow` 取得
  workspace baseline（`packages/api/workspace-controller/src/index.ts` 的
  `workspace/follow`），再以 `session/create` 的 `request.workspaceId`（或
  `request.cwd`）建立會話（`packages/api/session-controller/src/index.ts`
  的 `SessionCreateRequest`；Web e2e 以 `payload.args.request.workspaceId`
  斷言）。`spec/pclink/v1/endpoints.json` 已列這兩個端點，無需新增重試類別。
- **PC 新會話工作區選擇器**：`ChatPage` 輸入框工具列（與模型膠囊同一行、
  同樣式、PC-only）新增工作區膠囊；可選期間為新會話/空白會話，預設
  P18 `phone-dsh.pc.last-workspace.<machineId>` → 最近活動工作區；選到不同
  工作區時建立一個新的空白 DSH 會話（空白會話不能在工作區間移動）。第一個
  回合後只顯示目前工作區、無選單。手機分段不顯示。實現為
  `PCWorkspaceMenu` 同檔 sibling view；未新增可比較的 Android action，
  避免把 page-structure ratchet 從 17 變成 18（Android 對等由 GAP-35 追蹤）。
- **安裝引導**：`PCLinkInstallGuide`（`ProbeKit/Backends/PCLinkRelayConfiguration.swift`，
  與中繼 origin 同一個配置點）提供唯一命令字串；PC 未配對空狀態與
  `PCPairingPage` 都渲染同一個 `PCPluginInstallGuide`（等寬命令 + 複製按鈕，
  文案說明需 DSH 0.2.2+）。`pclink/README.md` 安裝段同步同一條
  `dsh plugin --profile web add 'github:launsion-boop/phone-dsh#main&path:/pclink'`
  與 `~/.dsh/profiles/web/node_modules/.bin/pclink pair`。`#main` 在包含
  `pclink/` 的 PR 合併後才生效；本輪在臨時 `DSH_HOME` 用 PR head commit
  `fd2b97e98` 的 git spec 實測安裝/啟動/配對（見 §4.11.1）。
- **P18**：`phone-dsh.pc.last-workspace.<machineId>` 已在 `spec/README.md`
  §3.1 P18 行與本記錄 §4.10 先行登記；`removeLocalData(for:)` 會刪除該 PC
  的鍵，其他 PC 與手機鍵不動。

#### 4.11.1 命令 → 結果（本輪）

| 命令 | 結果 | 日誌 |
| --- | --- | --- |
| `python3 -B spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS** `contracts up to date` | `/tmp/pclink-pacing-extract-check.log` |
| `python3 -B spec/ui/v1/tools/ui_check.py --root .` | **PASS** `ok (…)` | `/tmp/pclink-pacing-ui-check.log` |
| `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (17)**：既有 12 + GAP-35 的 5，未新增 | `/tmp/pclink-pacing-page-check.txt` |
| ADAPTED `xcodegen generate` + `xcodebuild -scheme PhoneDSHProbe ... build` | **PASS** `** BUILD SUCCEEDED **` | `/tmp/pclink-pacing-build.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHSim ... build-for-testing` | **PASS** `** TEST BUILD SUCCEEDED **` | `/tmp/pclink-pacing-buildtests.log` |
| ADAPTED `simctl spawn … xctest -XCTest <13 classes>` | **PASS** 94 tests, 0 failures（含新增 `PCLinkPacingSimTests` 5 個） | `/tmp/pclink-pacing-simtests.log` |
| 臨時 `DSH_HOME`：`dsh plugin --profile web add 'github:launsion-boop/phone-dsh#fd2b97e980956bb1206cd5c5203a51cc32786764&path:/pclink'` | **PASS**：pnpm 安裝 `dsh-pclink`、profile `node_modules/.bin/pclink` 存在、`dsh web`（臨時 home，port 3282）載入插件並連上 port 3280 中繼；`pclink status` 顯示 connected；PhonePeer 以 admin 審批配對後 handshake、`session/list`、`session/create` 均成功 | `/tmp/pclink-install.log`、`/tmp/pclink-install-dsh.log` |

**NOT_RUN**：真機 Keychain/相機、公網 WSS、Android 端（GAP-35）。截圖見 §4.11.2。

#### 4.11.2 截圖

`docs/receipts/pclink-pacing/`（light/dark，模擬器 `620D518D-D125-4154-B1B7-32A65327482B`）：

| 場景 | light | dark |
| --- | --- | --- |
| 抽屜新佈局（分段在新會話下方；PC 按 DSH 工作區分組） | `drawer-light.png` | `drawer-dark.png` |
| PC 新會話工作區選擇器 | `workspace-picker-light.png` | `workspace-picker-dark.png` |
| 未連接電腦安裝引導（抽屜 empty state） | `install-guide-light.png` | `install-guide-dark.png` |
| 配對頁安裝引導 | `pairing-guide-light.png` | `pairing-guide-dark.png` |

截圖使用獨立的第二個 App bundle（`dev.phone-dsh.probe.pacing`）與臨時 DSH
的合成工作區/會話，未顯示使用者真實會話標題；使用者已安裝的 App、配對記錄
與資料未卸載、未清空、未解除配對（第二個 bundle 已卸載）。靜態截圖沒有展開
工作區選單（宿主無 accessibility 點擊權限）；選單狀態由
`PCLinkPacingSimTests` 與頁面契約覆蓋。

### 4.12 合入 main da10d7466（merge-only）

**范围**：`git merge --no-ff --no-commit origin/main`（`origin/main` = `da10d7466`，merge base `627aed35`，分支 head `fd2b97e98`），只做合并、不加功能、不 commit；合并状态留给协调者。14 个冲突文件逐个解决；main 的 #75/#76/#77/#78/#79 语义与 PCLink 的每后端模型、P18 scope、PC 分支全部保留。合并后由协调者提交。

#### 4.12.1 冲突处置

| 文件 | main（da10d7466） | feat/pclink | 合并方式与理由 |
| --- | --- | --- | --- |
| `ChatModel.swift`（8 处） | `ChatEngineLifecycle`/`canStartBySending`、`isReloadingSession`、D24 backoff retry 取消、`openAndActivateSession`（自动 session reload 共用体，裸 `currentSessionDefaultsKey`）、`WorkspaceFileRefresh`/`fileIndex`、`ResourceMeter` 采样、scene-phase 取消回退 | `pcRuntime` 分支（`startPCModel`/`stop`/`scenePhaseChanged`）、`canSend`/`canSteer` 的 `pcOnline`、`workspaceBackend.harness()`、PC `workspace:nil`、provider 仅手机、P18 scoped current session、PC 不本地预览/扫描 | `canSend`/`canSteer` 同时保留 `!isReloadingSession`（main）与 `pcOnline`（D2）；`canStartBySending` 只留一份，PC 直接 `false`；`start()` 先 PC 分支，再委托 main 的 `start(autoRecover:backoffRetry:)`；`stop()`/`scenePhaseChanged` 先执行 main 的 backoff/session-reload 取消，再走 PC 分支（PC 无 host lifecycle）；`openManagedSession` 保留 main 的 `cancelSessionReload()`，device-session 判断加 `pcRuntime == nil`，harness 改走 `workspaceBackend.harness()`，复用 main 的 `openAndActivateSession`；共用体按后端决定 `workspace`、provider 仅手机、当前会话写回 `WorkspaceStorage.setCurrentSessionID(..., for: backendID)`（P18）；`refreshFiles(debounced:)` 保留 main 的去抖扫描但包在 `localFilePreview` 门内；`refreshFilesAndWait()` 加同一门；`ResourceMeter.beginTurn()` 只在手机分支调用 |
| `ChatPage.swift`（3 处） | #77 chat-title-only（删除副标题 VStack 与 `projectSubtitle`）、`timelineCache`/`timelineSnapshot`、`scrollTrace.contentHeight`、ResourceMeter 横幅、perf counters | `projectSubtitle` 的 PC 默认文件夹/PC 工作区名、滚动 finite 守卫与安全 `integer()` 诊断、PC 版本/离线横幅 | 采用 main 的 title-only 并删除 `projectSubtitle`；PC 工作区名仍在抽屉的 `手机｜PC` 分段与 `PC 工作区 · <电脑名>` 分组，信息未丢；滚动判断保留 main 的 `scrollTrace.contentHeight` 并叠加 ours 的 `isFinite` 守卫；诊断保留安全 `integer()`；PC 横幅保留；perf 循环抽成 `reportPerfCounters()`（仅拆表达式，行为不变） |
| `HomeDrawer.swift`（4 处） | #76 会话顺序持有（`sessionOrder`/`rememberSessionOrder`/`inHeldOrder`）、`switchingSessionID`/`errorMessage` 切换期抑制、`HomeDrawerNewSessionPolicy`（`busy` 只禁用不显示原因、固定高度原因行） | `手机｜PC` 分段、PC 未配对/离线状态与配对 sheet、按 backend 刷新/折叠、PC 空态与新会话阻止 | `showsPCState` 分支包住 main 的错误行 + 文件夹区；`.task(id: backendTaskID)` 合并 per-backend 刷新与 main 的顺序持有，并在 backend 切换时清空 `sessionOrder`（同 ID 两端不串，P18）；`newSessionBlocked` 先 PC 原因再 `policy.reason`，`newSessionDisabled` 先 PC 相位再 `policy.isDisabled`；`errorMessage` 用 main 的切换期抑制 |
| `NativeShell.swift` | `@Environment(AppModel.self)`（Bot 离屏/后台暂停） | `@Environment(\.workspaceModels)`（手机/PC 两个 ChatPage 同时存活） | 两个环境值都保留 |
| `NativeConversationModels.swift` | `NativeRenderRevision` + `renderRevision` + `bumpRenderRevision()` | 类型公开（文件已移入 ProbeKit） | `public var renderRevision` + `public mutating func bumpRenderRevision()`，使 App/测试能用 main 的缓存键；`NativeRenderRevision` 仍为文件私有 |
| `project.yml`（2 处） | 把新的 perf/render 源文件加入两个测试 target 的显式 sources | 把 `NativeConversationModels`/`NativeTranscriptProjector` 移入 `ProbeKit/Transcript`，测试 target 改 import ProbeKit | 保留 main 的列表但去掉两个已移动文件；perf helpers 按 4.12.2 移入 `ProbeKit/Perf` 并从测试列表移除；`xcodegen generate` PASS |
| `spec/ui/v1/pages/{chat,egress-allow-list,runtime-details,settings-about,workspace-folders}.json` | main 的页面结构/action 变化 | D2 的 PC 页面与 action | 不手工拼 provenance：解决结构冲突后由 `extract_ios_pages.py --root .` 从合并后的 Swift 整体重生成，`--check` PASS |
| `spec/ui/v1/pages/_spec-required.json` | 行号随 ChatPage 移动 | D2 的 2 条既有条目 + 格式 | 采用 D2 结构；3 条 `ChatPage.swift` 引用按合并后源码更新为 `3845`/`3812`/`262` |
| `spec/ui/v1/pages/home-drawer.json` | 原因行固定高度、`newSessionDisabled` 条件、`errorMessage` 抑制、`switchingSessionID` failure 条件 | `手机`/`PC` action、配对 sheet、PC 空态 | 以 D2 的手写契约结构为底，叠加 main 的语义，再按 `anchor` 机械刷新全部 `HomeDrawer.swift:line`；未改 `_baseline.json`/whitelist |
| `spec/ui/v1/tokens.json` | `textSubtle`/`navSubtitle` 改为页面/抽屉弱化文字（title-only 后聊天页头不再有副标题）；`textSubtle/page` 对比度站点改 `HomeSpec.swift:34`；大量行号 | D2 的行号更新 | 采用 main 的语义，所有 `file:line`（含 notes/sites）用 main→合并树的机械行映射刷新，再按 `ui_check.py` 的 expect/值判据逐条校验；`ui_check` PASS |

main 的其余改动（Bot 卡片/鱼渲染缓存、Android P09 行、`plugins/wasi-toolbox/git`、worker-entry、bot-ui 脚本等）自动合并且已复核未覆盖 D2 目录；`spec/README.md` 在 `da10d7466` 上**没有** main 侧改动，D2 的 GAP-35 条目原样保留（main 无 GAP 行可合并）。

#### 4.12.2 编译必需的模块迁移

main 的 `NativeTranscriptProjector` 改为调用 `NativeDiffLineCountsCache`，而 D2 已把 projector 移入 `ProbeKit/Transcript`，App 模块不能反向依赖。按既有 probe-kit 提取方式，把 main 新增的 4 个 UI-free perf helper 移到 `ProbeKit/Perf/`：`NativeDiffCache.swift`、`NativeBoundedCache.swift`、`NativeStableHash.swift`、`NativePerfCounters.swift`，公开 App/测试实际使用的 API（`NativeDiffLineCountsCache`/`NativeChangesCache`/`NativeBoundedCache`/`NativeStableHash`/`NativePerfCounters`），并给 8 个使用方补 `import ProbeKit`。这样 `NativePerfCounters.shared`、diff changes cache 在进程内仍只有一份，不是把同一实现编进两个模块。`xcodegen` 后 App build 与 `build-for-testing` 均 PASS。

#### 4.12.3 P18 检查结论

| main 新增的会话/本地状态 | 是否持久化 | 结论 |
| --- | --- | --- |
| `openAndActivateSession` 里的 `UserDefaults.standard.set(session.id, forKey: currentSessionDefaultsKey)` | 是 | **必须 scope**：已改为 `WorkspaceStorage.setCurrentSessionID(session.id, for: backendID)`；裸键不再被合并结果写回，否则 PC/手机会话会互相覆盖 |
| `HomeDrawer.sessionOrder` | 否（纯内存） | 抽屉打开期间持有；在 `.task(id: backendTaskID)` 中按 backend 清空重建，避免 P18 同 `sessionID` 两端串序 |
| `NativeTimelineCache`/`NativeRowSummaryCache`/`NativeMarkdownParseCache`/`NativeMathImageCache`/`NativeDiffLineCountsCache`/`NativeChangesCache`/`NativeBoundedCache` | 否 | 键为 item id + `renderRevision`、turn+signature 或内容 hash；不落 UserDefaults/文件，没有 `(BackendID, sessionID)` 键可加 |
| `NativePerfCounters` | 否 | 进程内计数；Release 开关 `chat.perfCounters` 是 App 级设置，不是会话键 |
| `WorkspaceFileIndex`/`WorkspaceFileRefresh` | 否 | 每个 `ChatModel`（即每个 backend）实例一份，由 `files` 派生；`files` 是 backend 的 workspace 级快照，不需要 session 键。PC 的 `capabilities.localFilePreview == false` 在 `refreshFiles` 与 `refreshFilesAndWait` 两个入口都直接清空返回，**不会**扫描手机 `Documents/.../materialized/workspace` |
| `ResourceMeter` | 否 | `attach(host:workspaceRoot:)` 只在 `adoptRunningHost`（手机）调用；PC 没有 host/workspaceRoot，`beginTurn` 已按 `pcRuntime == nil` 门控，PC 不会启动手机资源采样/目录测量 |
| 自动 session reload（`isReloadingSession`/`sessionReloadTask`/token） | 否 | 每个 `ChatModel` 实例一份；只在手机 host adoption/resume 路径调度，PC 的 `scenePhaseChanged` 提前返回，不会把 PC 会话当本地 host 会话重载 |
| `foldedTurns`/`collapseOnNextMessage` 等页面态 | 否 | 前者是视图内 per-session 临时态（README 已声明折叠态不跨会话保留）；后者是 App 级偏好，非会话键 |

**结论**：main 新增的本地状态没有需要本次补 `(BackendID, sessionID)` 键的持久化项；唯一被 main 重新引入的裸 `sessionID` 写入已改回 P18 scoped API。PC 分段下不会扫描手机工作区、不会 attach 手机资源监测、不会把 PC 会话当本地 host 会话处理。**已知缺口：无**（本轮未发现需要登记的新 P18 GAP）。

#### 4.12.4 命令 → 结果（本轮实跑）

环境同 §4.5；`PATH=/tmp/node24/bin:$PATH`、`PDSH_NODE=/tmp/node24/bin/node`；模拟器 `620D518D-D125-4154-B1B7-32A65327482B`（只 `simctl spawn xctest`，未安装/卸载/清数据）。

| 命令 | 结果 | 证据 |
| --- | --- | --- |
| `swift build --disable-sandbox` | **PASS** `Build complete! (6.84s)` | `/tmp/pclink-merge-swift-build.log` |
| `swift test --disable-sandbox --filter "PhoneDSHPCLinkTests"` | **PASS** 63 tests, 1 skipped, 0 failures | `/tmp/pclink-merge-swift-test.log` |
| `cd examples/probe-app && xcodegen generate` | **PASS** | 终端 |
| ADAPTED `xcodebuild -scheme PhoneDSHProbe … build CODE_SIGNING_ALLOWED=NO`（`/tmp/pclink-merge-dd`、`CFFIXED_USER_HOME=/tmp/pclink-merge-home`、`-disable-sandbox`） | **PASS** `** BUILD SUCCEEDED **` | `/tmp/pclink-merge-xcodebuild-final.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHSim … build-for-testing` | **PASS** `** TEST BUILD SUCCEEDED **` | `/tmp/pclink-merge-buildtests-final.log` |
| ADAPTED `simctl spawn … xctest -XCTest` 13 个 PCLink 类 + 10 个 main 新增/修改类（`PCLinkWorkspaceSimTests,ProbeKitHistoryTests,ProbeKitManagementTests,ProbeKitBackendTests,MessageFeedbackTests,ChatInputRecoveryTests,NativeChatPresentationTests,ChatWorkflowTests,ChatEventPumpTests,ComposerQueueTests,ProbeScenePhaseForwardingTests,PhoneAudioSessionLeaseTests,UnpairedPCHeaderStructureTests,ChatBackoffRetryTests,ChatSessionReloadTests,HeavyOperationHintTests,HomeDrawerNewSessionPolicyTests,LogRedactionTests,NativeRenderPerformanceTests,NativeStreamAccumulatorTests,ResourceLevelTests,WorkspaceFileIndexTests,WorkspaceFileRefreshTests`） | **PASS** 169 tests, 0 failures | `/tmp/pclink-merge-simtests-final.log` |
| `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) PDSH_NODE=/tmp/node24/bin/node bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance,phone-modules` | `phone-spec` **PASS**；`phone-cross-tree` **PASS**；`phone-modules` **PASS**；`phone-p0-conformance` **FAIL**，唯一原因是 `page-structure: FAIL (17)`（既有 12 + GAP-35 5，全部已逐条登记，未加 whitelist/未改 `_baseline.json`） | `/tmp/pclink-merge-ci.log`、`/tmp/pclink-merge-pagestructure3.log` |
| `python3 spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS** `contracts up to date` | 终端 |
| `python3 spec/ui/v1/tools/ui_check.py --root .` | **PASS** `ok (5 files, 13 contrast pairs, 6 deferred AA pairs, 1 unmeasured tokens, 0 unmeasured surface items, 50 geometry tokens)` | 终端 |
| `cd relay && npm test` | **PASS** 65 tests, 0 fail | `/tmp/pclink-merge-relay-test.log` |
| `cd pclink && PCLINK_SKIP_MODEL=1 npm test` | **PASS** 107 tests, 106 pass, 1 skipped (`PCLINK_SKIP_MODEL=1`), 0 fail | `/tmp/pclink-merge-pclink-test.log` |

`Package.resolved` 被 Xcode 自动写入 app 本地 SwiftMath/SwiftMarkdown pin 后已按合并结果（HEAD）还原，未纳入改动。

#### 4.12.5 已知缺口与剩余风险

1. **合并目标固定为 `da10d7466`**：本会话运行期间 `origin/main` 又被其他 worker 推进（观察到的 `43013ec`＝PR #69，随后远端为 `a3e41f8`）。本单元严格按任务冻结的 `da10d7466` 合并；更新的 main（含 Android PR #69 的 5 个新文件与 `spec/README` GAP-33 关闭）**未合入**，由协调者决定是否再合一次。差异不是本合并丢文件：`da10d7466` 的 35 个新增文件全部在合并结果中。
2. **`page_structure_check` 17 处**：既有 12（connectors、daily-brief、files、home-drawer 设置、native-automation、session-artifacts、settings 2 sections + 4 actions）+ D2/GAP-35 5（home-drawer 手机/PC、pc-pairing/connected-computer、settings 已连接的电脑）；与 §4.4 完全一致，未关闭、未新增。
3. **PC 副标题移除**：main #77 的 title-only 与 D2 的 PC 副标题直接冲突，取 main 的标题修复；PC 工作区名仍在抽屉分段与 `PC 工作区 · <电脑名>` 分组。不是信息丢失，但 PC 聊天页头不再显示文件夹副标题。
4. **模块迁移**：`NativeBoundedCache`/`NativeStableHash`/`NativePerfCounters`/`NativeDiffCache` 从 `PhoneDSHProbe/` 移到 `ProbeKit/Perf/`，公开 API 比 main 宽（App+测试需要）。若后续有文件按旧路径引用，`project.yml` 的测试 target 列表已同步移除；单一共享实例不变。
5. **未验证**：真实设备、真机 Keychain/相机、公网 WSS、真实 relay+DSH 三端 E2E（本轮未重跑，§4.6.1 的旧证据仍是上一单元）；UI 截图验收未重跑。`xcodebuild test` 仍以同 bundle 的 `simctl spawn` 替代。
6. **宿主限制**：本 worktree 的 `.git` 元数据在 workspace 外且沙箱只读，无法写 canonical gitdir。为执行真实 merge，worktree 的 `.git` 指针临时指向 `/tmp/pclink-a-merge-git`（含 `commondir`、`MERGE_HEAD`、resolved index；对象写 `/tmp`、读共享对象库）。交接给协调者后：可直接在该 worktree `git commit`（refs/objects 共享），或先 `git add -A` 再提交；提交后可用 `git reset` 刷新原 canonical worktree 的 index。该临时 gitdir 不在提交内容中。

#### 4.12.6 建议的合并提交信息

```text
Merge origin/main (da10d7466) into feat/pclink

Protocol impact: P09; P18; P27: none — #75 only renders and caches Bot cards under examples/probe-app/PhoneDSHProbe/Bot, with no spec/bot row/user-action or wire change; P24: none — project.yml only moves existing app sources between existing targets and Package.resolved is unchanged; P28: none — no spec/pclink/**, relay/**, pclink/** or Sources/PhoneDSHPCLink change; P12: none — no Package.swift/native ABI change; P06: none — reuses the existing AgentHarness and host event semantics; P14: none — reuses the existing DSHRemoteTransport/mux; P16: none — no PDSH_* env or Worker URL change; P01/P02/P04/P05/P10/P11/P13/P15/P17: none — merge only, no relay wire, WAL, bridge, loopback HTTP or plugin protocol change.
```

理由：P09 是 `spec/ui/v1/**` 重新生成与 `home-drawer`/`tokens` 合并；P18 是把 main 新引入的裸当前会话键改回 scoped API 并确认 PC 不误扫/误测；其余为合并带入的既有实现，wire 契约不变。契约 revision 保持 `pclink-v1.3`。

### 4.13 合入 main a3e41f853（#69、#70，merge-only）

**範圍**：`git merge --no-ff --no-commit origin/main`（`origin/main` = `a3e41f853`，merge base `da10d7466`，分支 head `7c7a14f04`），只做合併、不加功能、不 commit；合併狀態留給協調者。8 個衝突檔：`spec/README.md`、`spec/registry.json`、`spec/ui/v1/pages/{archived-sessions,conversation-settings,font-size-settings,licenses,permission-defaults,settings}.json`；`examples/probe-app/PhoneDSHProbe/SettingsPage.swift`、`spec/ui/v1/README.md`、`spec/tools/{cross_check,registry_build}.py` 為自動合併，逐項複核後保留雙方語義。

#### 4.13.1 衝突處置

| 檔案 | main（a3e41f853） | feat/pclink | 合併方式與理由 |
| --- | --- | --- | --- |
| `spec/README.md` §3 P18 | 權威欄新增 `tono-account` 會話記錄（`spec/v1/tono-account.md` §3） | D2 `phone-dsh.drawer.backend`、scoped 鍵與 v1.5 `phone-dsh.pc.last-workspace.<machineId>` | 兩邊條目都保留：權威欄採 main，evidence 欄保留 PCLink D2/v1.5 追加句；沒有刪除任一端的契約 |
| `spec/README.md` §7 GAP | GAP-33 關閉（#69），並新增 tono-account 上游細節 GAP-34 | GAP-33 僅記錄、GAP-35 = PCLink Android 抽屜 PC 工作區 | GAP-33 採 main 的關閉記錄；main 已發布的 tono-account **GAP-34 保持不變**（`spec/v1/tono-account.md` 與 `PC-20261108-tono-account-login.md` 與 origin/main 一致）；PCLink 的 Android 抽屜 PC 工作區條目與其編號衝突，改為 **GAP-35**（§4.13.2 的 page-structure 6 條同屬 GAP-35） |
| `spec/README.md` §3 P05/P28 | P05 加入 tono-account 權威與 golden | P28 PCLink 列（main 無此列） | P05/P28 由自動合併保留；P28 列與 §4 trigger 仍以 `spec/pclink/v1/**` 為準，本輪不改 PCLink 契約 |
| `spec/registry.json` | — | — | 不手工拼接；先解決 README，再 `python3 spec/tools/registry_build.py --root . --write` 重建（28 contracts、484 path/glob refs），`--check` 與 `registry_check.py` 均 PASS |
| `spec/ui/v1/pages/*.json`（6 個衝突檔） | #69 的 SettingsPage 重構 provenance | PCLink 的 PC 頁與 action | 不手工拼 provenance；由 `extract_ios_pages.py --root .` 從合併後 Swift 整體重生成，`--check` PASS。`settings.json` 同時含 PCLink `已连接的电脑` 與 #70 `Tono 账号` 入口 |
| `SettingsPage.swift`（自動合併） | #69 `SettingsPageMode`、新的我的/設置分組；#70 `Tono 账号` link | D2 `已连接的电脑` + `connectedComputerValue` | 自動合併保留兩者：`modelsSection(includesProviders:)` 的 Tono 账号（sheet）與 `tabSections` 的已连接的电脑（我的）；`spec/ui/v1/README.md` 同時保留兩個頁面描述 |
| `spec/tools/*`（自動合併） | #70 的 tono golden reader / registry projections | P28 的 pclink golden reader / projections | 雙方新增項都保留，無重複 ID；由 phone-spec/phone-cross-tree 驗證 |

> GAP 編號：main 的 tono-account GAP-34 已發布、編號不改；PCLink 的 Android 抽屜 PC 工作區條目與其編號衝突，PCLink 條目改為 GAP-35。本單歷史記錄中的 PCLink 條目編號已同步改為 GAP-35。

#### 4.13.2 GAP-35 與 page-structure 實測

`python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → **FAIL (7)**，即 main 既有剩餘 **1** 處 + GAP-35 的 PCLink 條目 **6** 處：

| 歸屬 | 差異 | 條數 |
| --- | --- | --- |
| GAP-32(d)（main 既有） | `files` missing-action「完成」 | 1 |
| GAP-35（PCLink） | `home-drawer` missing-action「手机」 | 1 |
| GAP-35（PCLink） | `home-drawer` missing-action「PC」 | 1 |
| GAP-35（PCLink） | `pc-pairing` missing-section `<android-screen>` | 1 |
| GAP-35（PCLink） | `connected-computer` missing-section `<android-screen>` | 1 |
| GAP-35（PCLink） | `settings` missing-action「已连接的电脑」 | 1 |
| GAP-35（PCLink） | `settings` missing-section「已连接的电脑」（該分組 first-clickable-row 判據行） | 1 |

#69 已關閉 GAP-33 的 11 處，並補齊舊 GAP-32/GAP-35 文字列出的 `connectors`、`daily-brief`、`session-artifacts`、`native-automation`、`home-drawer`「设置」、`settings` 兩個 section 與四個 action；因此舊 GAP-35 的「12 + 5 = 17」不再成立。#69 後 Android `settings` 已有「Phone DSH」section，舊文字預期的「Phone DSH」missing-section 也不再成立；目前 `settings` 只差 PCLink 的「已连接的电脑」判據行與 action。GAP-35 文字已如實更新為 **1 + 6 = 7**；未加 whitelist、未改 `_baseline.json`。

#### 4.13.3 #70 tono-account 的 P18 檢查（不合併即靜默的項目）

- **持久化粒度**：`spec/v1/tono-account.md` §3 規定「one session per app install」。iOS 用 Keychain service `dev.phone-dsh.tono-account`、account `session`；Android 用 `SecureStore` key `tono-account.session`。沒有 `sessionID`、`BackendID` 或 `pc:<machineId>` 維度，因此不屬於 P18 D2 的 per-backend/per-session scoping，也不需要新增或遷移 PCLink 的 `phone-dsh.*` 鍵。合併後 `phone-dsh.drawer.backend`、`phone-dsh.pc.last-workspace.<machineId>` 與 tono session 三者互不覆寫。
- **設定頁入口**：`Tono 账号` 只在 `SettingsPage.modelsSection(includesProviders: true)`（settings sheet）出現；`已连接的电脑` 在「我的」tab 的 `tabSections`。`settings.json` 由提取器同時收錄兩者，沒有把其中一個當成另一個的替代。
- **「這些設置屬於手機」頁頭**：`PhoneOwnedSettingsNotice` 只掛在 `ModelProviderSettingsPage`、`MCPSettingsPage`、`NativeAgentPresetsPage` 三個「編輯手機 DSH 設定」的頁面；settings index 與 `TonoAccountPage` 沒有該 notice。Tono 賬號是 App 級憑據（登入後取代手機雲端模型/網頁搜索的 API key），不讀寫 PC backend 或 PC DSH 設定，因此不是 PC backend 的「屬於手機」頁頭衝突。**結論：不需要按 P18 新增 scope/遷移或改頁頭**；若日後把該入口移到 PC 工作區表面，必須同時補 notice 與 P09 契約，屆時另立變更單。
- **已驗證**：`swift test --filter 'TonoAccountSessionTests|TonoCloudResponsePolicyTests'` PASS 17 tests（13 + 4）；Android 端只由 #70 的 Kotlin 測試覆蓋，本輪未跑 Gradle（見 §4.13.5）。

#### 4.13.4 命令 → 結果（本輪實跑）

| 命令 | 結果 | 證據 |
| --- | --- | --- |
| `swift build --disable-sandbox` | **PASS** `Build complete! (25.28s)` | `/tmp/pclink-mm2-swift-build.log` |
| `swift test --disable-sandbox --filter PhoneDSHPCLinkTests` | **PASS** 70 tests, 1 skipped, 0 failures | `/tmp/pclink-mm2-swift-test-pclink.log` |
| `swift test --disable-sandbox --filter 'TonoAccountSessionTests\|TonoCloudResponsePolicyTests'` | **PASS** 17 tests, 0 failures（#70 新增的 iOS 測試類；它們在 SwiftPM target，不在 simulator bundle） | `/tmp/pclink-mm2-swift-test-tono.log` |
| `cd examples/probe-app && xcodegen generate` | **PASS** | `/tmp/pclink-mm2-xcodegen.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHProbe … build CODE_SIGNING_ALLOWED=NO`（`/tmp/pclink-mm2-dd`、`CFFIXED_USER_HOME=/tmp/pclink-mm2-home`、`OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox`） | **PASS** `** BUILD SUCCEEDED **` | `/tmp/pclink-mm2-xcodebuild.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHSim … build-for-testing` | **PASS** `** TEST BUILD SUCCEEDED **` | `/tmp/pclink-mm2-xcodebuild-tests.log` |
| ADAPTED `simctl spawn <udid> xctest -XCTest <24 classes>`（上輪 24 類；#70 沒有新增 simulator 測試類） | **PASS** 174 tests, 0 failures | `/tmp/pclink-mm2-simtests.log` |
| `cd relay && npm test` | **PASS** 65 tests, 0 fail | `/tmp/pclink-mm2-relay-test.log` |
| `cd pclink && PCLINK_SKIP_MODEL=1 npm test` | **PASS** 119 tests, 118 pass, 1 skipped, 0 fail | `/tmp/pclink-mm2-pclink-test.log` |
| `python3 spec/tools/registry_build.py --root . --check` | **PASS** byte-identical | 終端 |
| `python3 spec/tools/registry_check.py --root .` | **PASS** 28 contracts, 484 path/glob refs | 終端 |
| `python3 spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS** `contracts up to date`（46 pages） | 終端 |
| `python3 spec/ui/v1/tools/ui_check.py --root .` | **PASS** `ok (5 files, 13 contrast pairs, …)` | 終端 |
| `python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (7)**：GAP-32(d) 1 + GAP-35 6，與 §4.13.2 一致 | `/tmp/pclink-mm2-pagecheck-after.txt` |
| `CI_PROTOCOL_BASE=da10d7466… PDSH_NODE=/tmp/node24/bin/node bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance,phone-modules` | `phone-spec` **PASS**；`phone-cross-tree` **PASS**；`phone-modules` **PASS**；`phone-p0-conformance` **FAIL**，唯一原因是 `page-structure: FAIL (7)`；`CI GATE: FAIL` | `/tmp/pclink-mm2-ci.log` |
| `git show HEAD:Package.resolved > Package.resolved` | 已還原，工作樹無 `Package.resolved` 變更 | 終端 |

**ADAPTED**：xcodebuild 走本機模擬器（`620D518D-D125-4154-B1B7-32A65327482B`，只 `simctl spawn xctest`，未安裝/卸載/清資料）；`simctl spawn` 為同 bundle 的既有回退路徑。**NOT_RUN**：Android Gradle 編譯/單元測試、真機、真實 relay+DSH 三端 E2E、公網 WSS、相機掃碼、`xcodebuild test`。

#### 4.13.5 剩餘風險

1. **`phone-p0-conformance` 仍 FAIL (7)**：全部是已逐條登記的 GAP-32(d) 1 + GAP-35 6；本輪按任務不加 whitelist、不改 `_baseline.json`。Android 對等由 android-parity owner 關閉。
2. **#70 tono-account 未跑 Android Gradle**：本輪只跑 SwiftPM 的 iOS tono 測試；Android 的 `TonoAccountSessionTest`/`TonoAccountCasesTest` 未執行，不能宣稱 Android 端 runtime 通過。
3. **Tono 賬號入口只在 settings sheet**：`includesProviders` 只在 `.sheet` 模式為 true；「我的」tab 不顯示該入口（main 的既有產品結構，不是本合併引入）。若產品要求在「我的」露出，需另立 P09 變更。
4. **#70 沒有 simulator 測試類**：新增的 iOS 測試是 SwiftPM target 的 `TonoAccountSessionTests`、`TonoCloudResponsePolicyTests`；本輪以 `swift test` 實跑，沒有把它們混入 `simctl spawn` 的 24 類。
5. **main 已前進**：本單只合 `a3e41f853`；之後 main 再前進需另一次合併。

### 4.14 合入 main 31c0cab73（#84 bot-multi，merge-only）

**範圍**：`git merge --no-ff --no-commit origin/main`（`origin/main` = `31c0cab73`，merge base `a3e41f853`，分支 head `c961a47c5`），只做合併、不加功能、不 commit；合併狀態留給協調者。#84 的意圖（`31c0cab73^2` 提交訊息）：多 Bot 能力對齊 DSH bot——Bot 列表側邊欄、創建與管理、Bot 間通信、主 Bot 皇冠、表情反應；共 30 個 commit、153 個檔案。7 個衝突檔；`Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`、`examples/probe-app/PhoneDSHProbe/Bot/BotLiveTurn.swift`、`spec/registry.json`、`Tests/PhoneDSHBotTests/MCP/BotRemoteTestSupport.swift` 為自動合併，逐項複核。

#### 4.14.1 衝突處置

| 檔案 | main（31c0cab73，#84） | feat/pclink | 合併方式與理由 |
| --- | --- | --- | --- |
| `examples/probe-app/PhoneDSHProbe/ChatModel.swift`（2 處） | `startBotTurnPolling`／`applyBotTurnsRunning`／`stopBotTurnPolling` 與 `botTurnsRunning`；後台 keep-alive 條件改為 `(turnRunning || botTurnsRunning)`，空閒計時器與 `finishBackgroundKeepAlive` 同條件 | `startPCModel`（PC 啟動、離線不落回手機）；`beginKeepAlive()` 統一設定 `keepAlive.onEvent` 並啟動音訊 | 第一個衝突是兩邊在同一插入點新增不同方法：`startPCModel` 與 Bot polling 方法全部保留，各自閉合。第二個衝突取 #84 的 `(turnRunning || botTurnsRunning)` 條件，動詞體保留 feat/pclink 的 `try beginKeepAlive()`（它已設定 `onEvent`），刪掉 #84 內聯的重複 `keepAlive.onEvent`，避免同一個回調被覆寫兩次 |
| `examples/probe-app/PhoneDSHProbe/NativeShell.swift`（1 處） | `@Environment(AppModel.self) private var appModel`；`botPageActive` 與 Bot 抽屜／大肥魚共用同一暫停值 | `@Environment(\.workspaceModels) private var models`；`ChatModel.shared` 改名為 `model` 的 AppModel 環境值 | 兩個環境值都保留：`models`（每個 backend 的 ChatPage 同時存活）與 `appModel`（#84 新增的 `botPageActive` 全檔引用）。AppModel 屬性名採用 #84 的 `appModel`，不再保留 feat/pclink 的 `model`，避免同一環境聲明兩次 |
| `scripts/ci/check.sh`（2 處） | `phone-spec` 描述加入 Bot golden split/manifest；stage 內新增 `validate_vectors.py` 與 `check_golden.py --root` | `phone-spec` 描述加入 PCLink v1 vectors；stage 內新增 `check_samples.py` 與 `vectors.mjs --check`（Node 缺失 SKIP）；`phone-sdk` 的 `sdk_filter` 加 `PhoneDSHPCLinkTests` | 描述行合併兩邊文字；stage 內兩組檢查全部保留（先 spec unittest／Bot golden，再 PCLink schema／Node vectors），並保留 feat/pclink 的 `|| return 1`。`sdk_filter` 由自動合併保留 PCLink 類；`bash -n` 與 `--list` 均 PASS |
| `spec/README.md`（1 處） | P26 的 prose 改為多 Bot／Team 工具邊界；P26／P27 trigger 加 `spec/bot/v1/golden/*.phone.json` | P28 PCLink 列（P 表與 trigger 表） | trigger 表衝突取 #84 的 P26／P27 新 glob，並在其後保留 P28 列；P26 prose 自動合併保留 #84 語義。P 表與 GAP 表無其他衝突：#84 沒有新增 GAP；main 的 tono-account 仍為 **GAP-34**，PCLink 的 Android 抽屜 PC 工作區仍為 **GAP-35**，不讓號 |
| `spec/ui/v1/pages/egress-allow-list.json`（24 處）、`settings-about.json`（17 處）、`workspace-folders.json`（21 處） | NativeShell 抽屜／Bot 抽屜改寫造成 `provenance`／`id` 行號位移 | D2 的 PC 頁面與 action | 衝突全部是行號 provenance，不手工拼接：先解決 Swift，再由 `python3 spec/ui/v1/tools/extract_ios_pages.py --root .` 從合併後源碼整體重生成；`--check` PASS（46 pages、179 sections、531 rows、377 actions） |
| `spec/registry.json`（自動合併） | #84 的 P26／P27 phone overlay glob 與 P26 prose | P28 與 D2 P18 evidence | 不手工改；由 `registry_build.py --root . --write` 重建，`--check` 與 `registry_check.py` 均 PASS（28 contracts、486 path/glob references） |

自動合併複核（兩邊都改過的檔案）：

| 檔案 | 兩邊改動 | 合併結果 |
| --- | --- | --- |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift` | feat/pclink：`session/list` 補 `_request` 並把 cwd lookup 失敗寫 `runtime.stderr`；#84：多 observer `subscribeLiveFrames`／`liveFrames`、held inbox wake、`parentBotId` task 隔離、per-Bot executor | 兩組改動並存（`session/list` 帶 `_request` + 診斷；live observer 字典與兼容 `setLiveObserver`；`wakeWithHeldMessages`；`snapshot.parentBotId == botId`），無互相覆寫 |
| `examples/probe-app/PhoneDSHProbe/Bot/BotLiveTurn.swift` | feat/pclink：`import ProbeKit`；#84：`import PhoneDSHBot` + `BotDisplayContract.isToolCallVisible` | 兩個 import 與 #84 的可見性判定都保留 |
| `Tests/PhoneDSHBotTests/MCP/BotRemoteTestSupport.swift` | feat/pclink：`failSessionList`／`sessionListArguments`；#84：`createdCwd` | 三個測試支援 API 全部保留 |
| `spec/registry.json` | 見上表 | 生成器重建，無手寫 |

#### 4.14.2 #84 與 PC 後端的交互檢查（D2 約定：Bot 固定手機）

| 檢查項 | 事實 | 結論 |
| --- | --- | --- |
| Bot runtime 歸屬 | `ChatModel.shared` 是手機單例；`ChatModel(pcRuntime:)` 不建立 `botLaunch`，`startPCModel` 在 `prepareBotRuntime` 之前返回；PC 的 `stop()`／`scenePhaseChanged()` 在 Bot 清理之前提前返回；`BotProductionPage` 固定 `ChatModel.shared`；`botRuntime` 註釋明寫 PHONE-ONLY | PC 後端不會啟動、停止或讀取手機 Bot runtime；#84 的多實例（`BotRuntimeUnit`、`BotRosterModel`、`BotTeamHost`）只在手機側 |
| #84 新增持久狀態 | `BotSessionRegistry`（`phoneDSH.botSession.registry.v1`，`gb-` 前綴 session）、`BotSelectionDefaults.key`（`phoneDSH.bot.selectedBotID`）、`BotProfileStorage`（Application Support `PhoneDSHBot/`，agents-index／runtime-settings）、每 Bot memory SQLite、held inbox／team 狀態 | 寫入端只有手機 Bot runtime；讀取端是 Bot 表面與 `DSHManagementModel` 的 Bot 路徑／session 排除（同一 read point）。PC 模型沒有 botLaunch、不呼叫 `prepareBotRuntime`、不寫 Bot 狀態；沒有新增 `(BackendID, sessionID)` 鍵，`phone-dsh.drawer.backend`／PC scoped 鍵不變；不需要 P18 遷移，也不存在 PC 與 Bot 狀態互相覆寫的路徑 |
| Bot session 過濾 | `DSHManagementModel.refresh()` 以 `phoneOnlyFilters = backendID == .phone` 決定是否對 `session/list` 套用 `BotSessionRegistry` 與 device-session 過濾；手機的單一讀取點仍丟棄 `gb-`／已登記 Bot id；`decodeWorkspace`／`applyWorkspaceBaseline`／`upsertWorkspace` 的 `/dsh/workspace/.dshbot` 路徑與 workspace 內 Bot session id 排除不區分 backend | 手機 Bot 會話在 DSH 頁仍隱藏；PC 的 `session/list` 來自 PC transport，不套手機 Bot registry，所以手機 Bot 會話不會漏到 PC；PC 分段仍共用 Bot workspace/session 排除，`.dshbot` 私有工作區不會露出。**Bot 會話過濾在 PC 分段仍隱藏** |
| PCLink 每後端模型 | `WorkspaceModels`／`pcChat`／`pcManagement` 未改；`pcRuntime`、`pcOnline` 仍在 `canSend`／`canSteer`／`canStartBySending`；`startPCModel`、P18 `WorkspaceStorage` scoped keys、`localFilePreview` 門控的檔案刷新、PC `scenePhaseChanged` 走 PCLink／`foregroundResumed`、PC 不啟用 `ResourceMeter` | 全部保留；24 個 simulator 類（含 `PCLinkWorkspaceSimTests`、`PCLinkPacingSimTests`）與 SwiftPM `PhoneDSHPCLinkTests` 均 PASS |

**結論**：#84 的 Bot 多實例／多會話與 PCLink 的每後端模型互不干擾；Bot 固定手機後端，PC 不啟動 Bot runtime、不寫 Bot 持久狀態、session list 不套手機 Bot registry，但 Bot 私有 workspace/session 排除在 PC 分段仍生效；Bot 會話在手機與 PC 分段都不會出現在 DSH 會話清單。未發現需要新登記的 P18/GAP；既有 GAP-35 的 page-structure 條數不變。

#### 4.14.3 GAP-35 與 page-structure 實測

`python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → **FAIL (7)**，與合併前相同：main 既有剩餘 **1** 處 + GAP-35 的 PCLink 條目 **6** 處：

| 歸屬 | 差異 | 條數 |
| --- | --- | --- |
| GAP-32(d)（main 既有） | `files` missing-action「完成」 | 1 |
| GAP-35（PCLink） | `home-drawer` missing-action「手机」 | 1 |
| GAP-35（PCLink） | `home-drawer` missing-action「PC」 | 1 |
| GAP-35（PCLink） | `pc-pairing` missing-section `<android-screen>` | 1 |
| GAP-35（PCLink） | `connected-computer` missing-section `<android-screen>` | 1 |
| GAP-35（PCLink） | `settings` missing-action「已连接的电脑」 | 1 |
| GAP-35（PCLink） | `settings` missing-section「已连接的电脑」（該分組 first-clickable-row 判據行） | 1 |

#84 沒有新增 Android 頁面契約，也沒有改 GAP-35 的六條；未加 whitelist、未改 `_baseline.json`。

#### 4.14.4 命令 → 結果（本輪實跑）

環境：`PATH=/tmp/node24/bin:$PATH`、`PDSH_NODE=/tmp/node24/bin/node`；模擬器 `620D518D-D125-4154-B1B7-32A65327482B`（只 `simctl spawn xctest`，未安裝／卸載／清資料；為執行 spawn 先 boot，未動 App 資料）。

| 命令 | 結果 | 證據 |
| --- | --- | --- |
| `swift build --disable-sandbox` | **PASS** `Build complete! (14.34s)` | `/tmp/pclink-mm3-swift-build.log` |
| `swift test --disable-sandbox --filter PhoneDSHPCLinkTests` | **PASS** 70 tests, 1 skipped, 0 failures | `/tmp/pclink-mm3-swift-test-pclink.log` |
| `swift test --disable-sandbox --filter '<22 個 #84 新增/修改 PhoneDSHBotTests 類>'` | **PASS** 132 tests, 0 failures（含 `BotFishActionEffectTests`、`BotRosterTests`、`BotRuntimeMultiplexingTests`、`BotTeamToolsTests`、`BotMemoryIsolationTests` 等） | `/tmp/pclink-mm3-swift-test-bot.log` |
| `cd examples/probe-app && xcodegen generate` | **PASS** | `/tmp/pclink-mm3-xcodegen.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHProbe … build CODE_SIGNING_ALLOWED=NO`（`/tmp/pclink-mm3-dd`、`CFFIXED_USER_HOME=/tmp/pclink-mm3-home`、`-disable-sandbox`） | **PASS** `** BUILD SUCCEEDED **` | `/tmp/pclink-mm3-xcodebuild.log` |
| ADAPTED `xcodebuild -scheme PhoneDSHSim … build-for-testing` | **PASS** `** TEST BUILD SUCCEEDED **` | `/tmp/pclink-mm3-xcodebuild-tests.log` |
| ADAPTED `simctl spawn … xctest -XCTest '<上輪 24 類>' PhoneDSHSimTests.xctest` | **PASS** 174 tests, 0 failures（含 `PCLinkWorkspaceSimTests`、`PCLinkPacingSimTests`；#84 沒有新增／修改 SimTests 類） | `/tmp/pclink-mm3-simtests.log` |
| `cd relay && npm test` | **PASS** 65 tests, 0 fail | `/tmp/pclink-mm3-relay-test.log` |
| `cd pclink && PCLINK_SKIP_MODEL=1 npm test` | **PASS** 131 tests, 130 pass, 1 skipped, 0 fail | `/tmp/pclink-mm3-pclink-test.log` |
| `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main)`（解析為 `a3e41f853`）`PDSH_NODE=/tmp/node24/bin/node bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance,phone-modules` | `phone-spec` **PASS**（含 Bot golden 27 files、PCLink samples/vectors）；`phone-cross-tree` **PASS**（8/8 invariants、registry、schema diff）；`phone-modules` **PASS**；`phone-p0-conformance` **FAIL**，唯一原因是 `page-structure: FAIL (7)`（1 + 6 已逐條登記）；`CI GATE: FAIL` | `/tmp/pclink-mm3-ci.log`、`/tmp/pclink-mm3-ci-final.log` |
| `python3 spec/tools/registry_build.py --root . --write` / `--check` | **PASS** byte-identical；`registry_check.py` PASS（28 contracts、486 refs） | 終端 |
| `python3 spec/ui/v1/tools/extract_ios_pages.py --root . --check` | **PASS** `contracts up to date` | 終端 |
| `python3 spec/ui/v1/tools/ui_check.py --root .` | **PASS** `ok (5 files, 13 contrast pairs, 6 deferred AA pairs, 1 unmeasured tokens, 0 unmeasured surface items, 50 geometry tokens)` | 終端 |
| `bash -n scripts/ci/check.sh` / `bash scripts/ci/check.sh --list` | **PASS** | `/tmp/pclink-mm3-check-list.log` |
| `git show HEAD:Package.resolved > Package.resolved` | 已還原；`git status` 無 `Package.resolved` 變更 | 終端 |
| 全倉衝突標記掃描 | **無** `<<<<<<<`／`=======`／`>>>>>>>` | 終端 |

**ADAPTED**：xcodebuild 走本機模擬器；`simctl spawn` 為同 bundle 的回退路徑。**NOT_RUN**：Android Gradle、真機、真實 relay+DSH 三端 E2E、公網 WSS、`xcodebuild test`、Bot UI 截圖、`scripts/ci/bot-e2e`。

#### 4.14.5 剩餘風險

1. **`phone-p0-conformance` 仍 FAIL (7)**：全部是已逐條登記的 GAP-32(d) 1 + GAP-35 6；本輪按任務不加 whitelist、不改 `_baseline.json`。Android 對等由 android-parity owner 關閉。
2. **#84 的 Bot 多實例只由 SwiftPM/模擬器測試覆蓋**：`scripts/ci/bot-ui` 截圖、`scripts/ci/bot-e2e` 的 `BotChatModelTests`、真 Worker/真 DSH 的 team/held inbox/routine 路徑未在本輪重跑；不能把這些當作 runtime E2E 證據。
3. **未跑 Android**：GAP-35 的 6 條仍是 iOS 契約側記錄；Android 端未編譯或測試。
4. **main 已前進**：合併期間觀察到 `origin/main` = `218d3cddf`（#80 resume-reliability，已含 #84）；本單嚴格只合任務凍結的 `31c0cab73`，未把 #80 合入。`CI_PROTOCOL_BASE` 仍解析為 `a3e41f853`（merge base 未變）。合入 main 前需在最新 main（`218d3cddf`）上再合一次或確認協調者已另行處理 #80。
5. **模擬器狀態**：為 `simctl spawn` boot 了 `620D518D-…`；未安裝、卸載或清除 App 資料。

#### 4.14.6 建議的合併提交信息

```text
Merge origin/main (31c0cab73, #84 bot-multi) into feat/pclink

Protocol impact: P09; P16; P25; P26; P27; P18: none — #84's new Bot selection/registry/profile state is phone-only (written by the phone Bot runtime; PC never writes it), and no new (BackendID, sessionID) key or migration is introduced; P28: none — no spec/pclink/**, relay/**, pclink/** or Sources/PhoneDSHPCLink change in #84 or in conflict resolution; P24: none — Package.resolved restored to HEAD; P12: none — no Package.swift/native ABI change; P06: none — reuses the existing AgentHarness and host event semantics; P14: none — the Bot remote runtime reuses the existing DSHRemoteTransport/mux; P01/P02/P04/P05/P10/P11/P13/P15/P17: none — merge only, no relay wire, WAL, bridge, loopback HTTP or plugin protocol change.
```

理由：P09 是頁面契約重生成與 `NativeShell`／`ChatModel` 合併；P16 是 #84 的 `plugins/profile/phone.worker.cordis.patch.yml` `phone-bot` preset；P25／P26／P27 是 #84 的 Bot golden／row／tool surface；P18／P28 經 §4.14.2 檢查後不改契約。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `pclink-d2-r1` | iOS D2 implementer / contract owner | 初始凍結 P09/P18；P28 只消費；GAP-35 登記 12+5 | iOS；android-parity；P18 owner |
| `pclink-d2-r2` | iOS D2 implementer | 實作後以提取工具更新 provenance；E2E 發現 CCR-1/2/3，未在本地繞過 | P28 C/D owner；android-parity |
| `pclink-fix1-r1` | PCLink fix1 implementer（iOS/C/D） | 關閉 CCR-1/2/3；配對自動完成並進 PC 工作區；`phone-sdk` filter 加 `PhoneDSHPCLinkTests`；以機械提取更新兩個頁面 provenance；重跑三端 E2E 與 CI | P28 C/D owner；P09 owner；android-parity（頁面 provenance） |
| `pclink-f2s-r1` | PCLink f2s implementer（iOS/App） | 全分支審查：session 內唯一線上 streamId、單寫者 FIFO、relay.offline/rate_limited/version_unsupported、stop/start、ready 缓存、origin/路徑/快照/日期等 18 項；PCLink v1.3 不變 | P28 D/App owner；P09/P18 owner；android-parity（頁面 provenance） |
| `pclink-pacing-r1` | P28 contract owner（本單） | P18 追加 `phone-dsh.pc.last-workspace.<machineId>`（PC 新會話上次工作區）；P09「手機\|PC」分段移到新會話下方、抽屜錯誤/加載態、PC 工作區分組、新會話工作區選擇器與安裝引導；P28 升 `pclink-v1.5`（見 `PC-20261109-pclink-v1.md` §4.16） | iOS/App；P09/P18 owner；android-parity（GAP-35 條目如實更新） |
| `pclink-merge-main-r1` | merge-main implementer（iOS/App） | 合入 `da10d7466`：解決 14 個衝突；保留 #75/#76/#77/#78/#79 與 D2 每後端/P18；main 的裸 current-session 鍵改回 scoped；perf helpers 移入 `ProbeKit/Perf`；頁面契約重生成、`tokens` 語義採 main 並機械刷新 provenance；PCLink v1.3 與 P09/P18 契約值不變 | P09/P18 owner；P28 D/App owner；android-parity（頁面 provenance 與 17 處已登記差異） |
| `pclink-merge-main2-r1` | merge-main2 implementer（iOS/App） | 合入 `a3e41f853`（#69、#70）：解決 8 個衝突；P18/P05 兩端條目並存；GAP-33 採關閉記錄、GAP-35 保留 PCLink 6 條並實測 1+6=7、main 的 tono-account 條目保持 GAP-34（與 origin/main 一致）；registry 由生成器重建；頁面契約由提取器重生成；#70 tono 賬號按 §4.13.3 檢查（app 級持久化，不按 P18 scope） | P09/P18/P05 owner；P28 D/App owner；android-parity（GAP-35 6 條） |
| `pclink-merge-main3-r1` | merge-main3 implementer（iOS/App） | 合入 `31c0cab73`（#84 bot-multi）：解決 7 個衝突；#84 的多 Bot 實例／會話／持久狀態與 PCLink 每後端模型並存；Bot 固定手機；PC session list 不套 Bot registry，Bot workspace/session 排除仍生效；GAP-35 仍 1+6=7、tono-account 保持 GAP-34；registry 與頁面契約由生成器重建 | P09/P16/P25/P26/P27 owner；P28 D/App owner；android-parity（GAP-35 6 條） |
