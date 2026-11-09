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
  - **P09**：`HomeDrawer` 只有手機工作區；新增「手機 | PC」分段、PC 未配對／離線空狀態、配對頁、已連接的電腦頁、PC 能力隱藏與版本提示。Android 無對應實作，按 GAP-34 只記錄。
  - **P18**：會話、草稿、標題提示、轉錄快照與收合文件夾仍以裸 `sessionID` 儲存；PC 與手機可能出現同 ID。改為 `<BackendID.storageScope>／<sessionID>`，並新增 `phone-dsh.drawer.backend`（`phone`/`pc`，缺省 `phone`）。舊資料一次性複製到 `phone`，舊鍵保留。
  - **P28**：不修改 `spec/pclink/**`；App 以現有 `PCLinkClient`／`RelayDSHTransport`／`DSHRemoteHarness` 接線。
- 協調者兼 contract owner（P09/P18/P28 本單）：iOS D2 實作者。
- Owning spec：P09 `spec/ui/v1/README.md`、`spec/ui/v1/pages/**`、`spec/ui/v1/tokens.json`；P18 `spec/README.md` §3.1 P18 行；P28 `spec/pclink/v1/README.md`（本單只消費）。
- 受影響 producer／consumer：iOS App（consumer，`examples/probe-app/**`）；Android（未實作，GAP-34）；PC plugin／relay（不改，既有 consumer）。

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
- GAP-34：`spec/README.md` §7 如實登記 **12 + 5 = 17** 處基線外差異（見 §4.4）。
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

### 4.4 GAP-34 實際新增

`python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → **FAIL (17)**：

- 既有 12 處：`connectors` missing-section；`daily-brief` extra-action「取消」；`files` missing-action「完成」；`home-drawer` extra-action「設置」；`native-automation` missing-action「完成」；`session-artifacts` extra-action「完成」；`settings` 2 missing-section + 4 missing-action。
- 本單新增 5 處（全部在 GAP-34）：
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
| `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (17)**：既有 12 + GAP-34 新增 5 | `/tmp/pclink-d2-pagecheck-final.txt` |
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
| `python3 -B spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` | **FAIL (17)**：既有 12 + GAP-34 5，與 §4.4 完全一致（pc-pairing / connected-computer 之名稱因 provenance 重新產生而變，條數不變） | `/tmp/pclink-fix1-ci-p0.log` |
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

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `pclink-d2-r1` | iOS D2 implementer / contract owner | 初始凍結 P09/P18；P28 只消費；GAP-34 登記 12+5 | iOS；android-parity；P18 owner |
| `pclink-d2-r2` | iOS D2 implementer | 實作後以提取工具更新 provenance；E2E 發現 CCR-1/2/3，未在本地繞過 | P28 C/D owner；android-parity |
| `pclink-fix1-r1` | PCLink fix1 implementer（iOS/C/D） | 關閉 CCR-1/2/3；配對自動完成並進 PC 工作區；`phone-sdk` filter 加 `PhoneDSHPCLinkTests`；以機械提取更新兩個頁面 provenance；重跑三端 E2E 與 CI | P28 C/D owner；P09 owner；android-parity（頁面 provenance） |
