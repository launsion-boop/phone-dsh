# Android parity — blocked evidence（wave 4 收尾，2026-11-13）

本檔記錄 wave 4 目標中**無法在此環境完成**的項目：每一項都附上現況證據、卡住的原因與
解除條件。它不是「已完成」的宣告，而是 goal 要求的 blocked 證據；不得把它當成通過。

## B-1 第 5 波：3D/HTML 預覽

- 需求：`docs/parity/android-parity-roadmap.md:26` 的 wave 5「3D/HTML 預覽（獨立進程 + 安全評審）；
  HarmonyOS 跟進」，狀態欄位就是 `安全評審`。
- 不變式：目前 Android 是「one activity, one WebView (the engine), one loopback origin with a
  launch token」（`docs/receipts/preview-research/04-ux-android.md:221`）。第二個 WebView／HTML
  預覽必須是**新元件**，且永遠不得載入帶 token 的 loopback origin。
- 現況：`spec/ui/v1` 沒有 Android 的預覽元件契約；Android 依不變式顯示「不支援」卡片
  （roadmap 能力表同一列）。沒有可套用的既有實作或 golden。
- 卡住原因：需要安全評審通過的新元件設計（origin 隔離、token 不跨 origin、獨立進程），
  加上 owning spec／CCR；這不是 Bot wave 內可順手改動的 UI。
- 解除條件：安全評審通過 + 預覽元件 spec/CCR + 隔離與 token 不跨越的測試（模擬器或真機）。

## B-2 第 5 波：HarmonyOS

- 現況：`spec/bot/v2/README.md:15` 與 `spec/bot/v1/README.md:60` 都明寫 Android 與 HarmonyOS
  尚無實作端；repo 只有 `android/`，沒有 HarmonyOS 模組／toolchain／建置入口。
- 卡住原因：沒有 owner 決定的 HarmonyOS 產品線與平台樹；本 repo 內沒有可移植的接收端。
- 解除條件：owner 決定 + 新增 HarmonyOS 模組與 toolchain + 契約凍結後才有實作標的。

## B-3 BLE secure session（GAP-16／GAP-20）

- 契約：`spec/device/v1/ble-secure-session.md` @ `secure-session-v2.1`，狀態 `target`；由
  [PC-20261108-ble-secure-session](../protocol-changes/PC-20261108-ble-secure-session.md) 在獨立
  安全審查（`docs/reviews/ble-secure-session-v1-review.md`）後凍結。
- 現況：Swift 與固件只有函式庫實作＋宿主跨執行環境測試，**無真機、無無線電證據**；Android
  只有掃描／標準 GATT（`android/app/.../probe/{AndroidBleScan,AndroidBleDevices}.kt`），
  Link／task decoder 仍是 `target`（GAP-20）。
- 卡住原因：(a) 安全審查列出的人工安全工程項目尚未完成；(b) 真機證據（實體登記按鍵＋指示燈、
  任務往返、跨會話長任務、重連／重啟恢復、偽造／未登記／換鑰／撤銷／換板對端被拒）；
  (c) Android GATT adapter 的可驗證 callback 歸屬（GAP-20）。
- 解除條件：上述三項完成並留下真機報告後，才可啟用與關閉 GAP-16。

## B-4 Instrumented `BotStoreAndroidVectorTest`

- 現況：`android/app/src/androidTest/kotlin/com/phonedsh/probe/bot/store/BotStoreAndroidVectorTest.kt`
  存在，狀態 **NOT_RUN**。主機原本沒有 emulator／system image／AVD；
  `android/tools/*` 只驗證 APK 與 JVM vectors。
- 證據（2026-11-13 本機）：
  - `ls $SDK/emulator/emulator` → 不存在
  - `ls $SDK/system-images` → 不存在
  - `adb devices` → 無裝置
  - sdkmanager 的 `emulator` + `system-images;android-37.2;google_apis_ps16k;arm64-v8a` 安裝
    正在進行（下載緩慢）；若在 goal 結束前完成，會建 AVD 並跑
    `:app:connectedDebugAndroidTest`，以 XML 為證據。
- 卡住原因（若下載／開機失敗）：此環境沒有可用的 Android 執行環境（模擬器或真機）。
- 解除條件：可開機的 emulator/AVD 或實體裝置 + instrumented 測試 XML（不是 JVM 綠燈）。

## B-5 Watchdog／context lint（S6）

- 現況：`docs/design/android-bot-port-plan.md` §3.6 明確標 `spec-partial` 且
  「**Blocked before B4 on D7**」：watchdog config schema 仍是 unconstrained object、
  tick/flag payload 與 unit-kind deadline 未凍結、context-lint thresholds 與 caller 只在程式碼。
- 卡住原因：D7 契約尚未凍結（是契約 lane，不是產品決策）。
- 解除條件：D7 schema + 共享 vectors + spec 段落；之後才能開 `:bot/watchdog` 的 Kotlin lane。

## 不在 blocked 清單、但仍未完成的 Bot 項目

- B6 team／tasks：D12 契約凍結（C8 lane）進行中，完成後即可實作。
- `:app` Bot runtime 接線（K6 lane）：進行中。
- TonoLink 語音 App/UI 接線：已有 JVM codec／cloud client，但接收端與 UI 未接（wave 2 剩餘，
  不屬於安全 blocked）。
