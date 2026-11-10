# PC-20261110-pclink-foreground-resume-presence

## 0. 摘要（機器可讀，保持這個格式）

```yaml
change: PC-20261110-pclink-foreground-resume-presence
contracts: [P28, P09]
status: frozen
breaking: false
version_decision: 無版本變更；純客戶端呈現與退避上限，wire 與 schema 不變
base: 6f4bed1f7
contract_revision: spec/pclink/v1/README.md@working-tree（§10 重連與離線呈現兩條）
```

無 schema／golden 變更：`spec/pclink/v1/schema/**` 與 `golden/**` 不動，本次只改 §10 的敘述性條款與 Swift 客戶端行為。

**修訂標籤決定**：維持 `pclink-v1.6`，不升版。理由：本次沒有改動任何 wire 位元組、schema、golden 或向量檔（`spec/pclink/v1/tools/vectors.mjs` 的 `REVISION`、`golden/pclink-v1-vectors.json`、`pclink/test/vectors.test.mjs` 皆不變），升版只會讓三處向量與測試為了「文案澄清」連動。本條以 `contract_revision: spec/pclink/v1/README.md@working-tree` 記錄，若後續有任何 wire 變更再把標籤一併推進。

## 1. 識別與角色

- 具體 trigger → 現況 → 期望：
  - 手機 App 從背景回前台（`PCLinkClient.foregroundResumed()`）→ 現況：**先把自己標成 `offline(.network)`**，而且下一輪重撥沿用失敗退避（`attempt` 未重設，`delays = [0.5,1,2,4,8,16,30,30]`，只有「連續在線 ≥ 60 s」才重設）→ 使用者看到「電腦離線」最多 30 s，即使 PC 上 DSH 正在跑回合。
  - 期望：使用者主動回前台不算失敗；下一次重撥的上限是第二階（≤ 1 s ± 20 %），期間呈現 `connecting`（「正在連接電腦…」），**不得**在這段期間顯示 `电脑离线`。
- 協調者兼 contract owner：本單作者（P28 D/App）。
- implementer：`Sources/PhoneDSHPCLink/**`（P28）、`examples/probe-app/**`（P09）。
- 受影響 producer／consumer：手機 client（唯一實作）；PC 插件與 relay **不受影響**（wire 不變）；Android 尚未實作 PC 工作區（GAP-35），無需同步。
- Owning spec：`spec/pclink/v1/README.md` §10（重連退避、離線呈現）。
- 共享 fixtures：不需要新增；既有 `Tests/PhoneDSHPCLinkTests/RelayDSHTransportTests.testForegroundResumedReplacesTheSuspendedConnection` 擴充。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 重連退避 | §10「reset after 60 s of successful connection」→ 追加：**使用者主動回前台觸發的重撥，下一次延遲上限為第二階（1 s ± 20 %）**，實作 `attempt = min(attempt, 1)`。失敗累積仍照原規則在 60 s 成功連線後重設；本條不改變失敗流的退避階梯 |
| 離線呈現 | §10「it shows 电脑离线 and a retry」→ 追加：上述受限重撥期間呈現 `connecting`，**MUST NOT** 顯示 `电脑离线`；一次重撥失敗後（或非使用者觸發的斷線），`电脑离线` + 重試的文案仍然強制 |
| `connecting` 的定義 | 新條款：`connecting` = 正在撥號／握手，或使用者主動回前台後的上限內重撥。`offline` = 一次撥號已失敗，或非使用者觸發的連線中斷 |
| fields／encoding／error code／retryable／idempotency／auth | 不變 |
| 條款狀態變化 | P28 維持 `target`；本單不改變其狀態 |

自檢：沒有第二種表達（仍只有 `relay.offline` 一種「送不到」訊號）；沒有新欄位；沒有收緊或放寬兩端都讀的訊息（`relay.offline` 的 `peer_offline`／`unknown_outcome` 判定完全不動）；沒有新增 enum 值影響 wire。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old phone → new PC | 不受影響：PC 插件與 relay 行為未變，仍接受舊 client 的任意重撥頻率 |
| new phone → old PC | 不受影響：只改變手機自己的退避與文案 |
| new phone → new PC | 同上 |
| persisted old data → new／rollback | 不適用：本單不新增也不改寫任何持久化資料或鍵（P18 未觸發） |

- 版本／adapter 決定：不適用（無 wire 與 schema 變更）。
- 回滾：純客戶端改動；回滾後行為回到「回前台可能等最多 30 s 並顯示離線」，無資料影響。
- `target` 條款中仍保留的差異：P28 整體仍為 `target`（兩端 runtime 證據未齊，見 `spec/README.md` §8）。

## 4. 分工與證據

- 獨占路徑：`Sources/PhoneDSHPCLink/PCLinkClient.swift`（P28）、`examples/probe-app/ProbeKit/Backends/PCWorkspaceBackend.swift` 與 `examples/probe-app/PhoneDSHProbe/{PCDrawerSection,HomeDrawer,ChatPage}.swift`（P09）。
- 驗收命令與結果（2026-11-10，macOS 26 / Xcode 26.5 / Swift 6.3.2）：
  - `swift test --filter PhoneDSHPCLinkTests` → **PASS**（72 tests，連續 3 次）
  - `swift test --filter RelayDSHTransportTests/testForegroundResume` → **PASS**（3 tests）
  - `xcodegen generate` + `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**
  - `xcodebuild test -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/PCLinkWorkspaceSimTests` → **PASS**（20 tests）
  - `bash scripts/ci/check.sh --only phone-spec` → **PASS**
  - `bash scripts/ci/check.sh --only phone-cross-tree` → **PASS**
  - `bash scripts/ci/check.sh --only phone-p0-conformance` → **FAIL**：`page-structure: FAIL (7 new divergence(s) outside the baseline)`；同一命令在 `6f4bed1f7` 的乾淨 worktree 上為**完全相同的 7 處**（GAP-35 既有工作量），`ui_check: ok`、`extract_ios_pages.py --check` 為 up to date、無 stale provenance。本單未新增差異
  - `bash scripts/ci/check.sh --only phone-sdk` → **FAIL**：1947 tests，17 failures，全部在 `PhoneDSHADBTests`（node 模組解析）、`PhoneDSHBLETests`（缺 cJSON／mbedTLS／`IDF_PATH` 的 firmware harness）、`PhoneDSHShellTests.ZPhoneSpecGateTests`（轉發同一 BLE 失敗）、`PhoneDSHTests.ProbeScenePhaseWiringTests`（HEAD 上同樣失敗，見下）；**PCLink 測試 0 失敗**
- 真實 producer／consumer 測試：
  - `testForegroundResumedPresentsConnectingOnTheWayOut`：真實 `PCLinkClient` + 測試 relay，斷言離開 `online` 的下一步是 `connecting`（不是 `offline`）
  - `testForegroundResumeDoesNotInheritFailureBackoff`：`FakeRelayNetwork.failNextDials(2)` 讓 loop 進入最長等待（本例 3 s），喚回必須在 1 s 內重連且 dial 次數 = 4
- 未驗證：真實 iPhone 從背景回前台（模擬器與單元測試不算真機證據）；`PhoneDSHTests.ProbeScenePhaseWiringTests` 在 HEAD `6f4bed1f7` 的乾淨 worktree 上同樣失敗（`PCPairingPage.swift` 已含 `scenePhase` 監聽），屬既有債務，本單不修
- 剩餘風險：`replaced` 的 30 s 最小等待不受本上限影響（該等待在 catch 分支內獨立 sleep）；已於 §2 寫明

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| working-tree | 本單作者 | 初版：使用者回報「PC 在跑回合但 App 顯示電腦離線」 | P28 D/App（P09 owner 同源） |
