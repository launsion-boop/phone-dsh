# Composer / approval geometry tokens（P09）

```yaml
change: PC-20261112-ui-geometry-composer-approval
contracts: [P09]
status: frozen
breaking: false
version_decision: tokens.json 仍是 version 1。四個 `geometry.*` 都是可選新增 leaf；既有 token 不改名、不改值，signatureSurfaces 只是多列四個已實作的讀取。Android consumer 在同一個 head，iOS 不變。
base: 2a957357
contract_revision: 3d92e545a31e5897c12c502bf31f6499ef006b2a
```

Protocol impact: P09

P09 — `ChatMetrics.kt` / `UiMetrics.kt` 收斂（T1）需要四個 composer / approval 幾何 leaf。值全部逐字取自
current `examples/probe-app/PhoneDSHProbe/ChatPage.swift`；iOS probe app 是出處與 provenance，不是權威，
本次不改任何 Swift。

## 1. 識別與角色

- Trigger → 現況 → 期望：`ChatMetrics` 四個 live 常數（`COMPOSER_OUTER_MARGIN_BOTTOM_PT`、
  `COMPOSER_PORT_LEADING_PT`、`COMPOSER_PORT_TRAILING_PT`、`PERMISSION_CARD_SPACING_PT`）是 signature
  composer / approval surface 的實值，但 `tokens.json` 沒有對應 leaf，Android 只能保留 literal。
  期望：新增四個 additive geometry leaf，Android 同一 head 改讀 generated `UiTokenData`，page geometry
  ownership test 不再看到 orphan。
- Coordinator / contract owner：本任務的 P09 owner。Implementer / reviewer-integrator：T1 worker。
- Owning spec：`spec/ui/v1/tokens.json`（`geometry.*` + `provenance` + `signatureSurfaces`）。
- Producer / consumer：iOS `ChatPage.swift` 是 provenance（不改）；Android `ChatMetrics.kt` 是唯一
  consumer（同 head），`Composer.kt` / `ApprovalCard.kt` 透過公開常數讀取，`ComposerTokens` /
  `ApprovalCardTokens` 登記 surface roles。HarmonyOS 不讀 tokens.json，不受影響。

## 2. 契約 delta

四個新增 leaf；`unit` 都是 `pt`，`scalesWith: null`：

| token | 值 | provenance | expect | owner |
| --- | ---: | --- | --- | --- |
| `geometry.composerOuterMarginBottom` | 0 | `ChatPage.swift:2352` | `.padding(.bottom, 0)` | signature `composer` |
| `geometry.composerPortLeading` | 11 | `ChatPage.swift:2409` | `.padding(.leading, 11)` | signature `composer` |
| `geometry.composerPortTrailing` | 8 | `ChatPage.swift:2410` | `.padding(.trailing, 8)` | signature `composer` |
| `geometry.approvalCardSpacing` | 10 | `ChatPage.swift:5210` | `VStack(alignment: .leading, spacing: 10)` | signature `approvalCard` |

- 沒有第二種表達：值只存在 `tokens.json`；`UiTokenData` 由 generator 產生，Android 不重抄數字。
- 沒有新欄位語意、沒有 enum、沒有版本欄位；四個 leaf 都是 optional additive property。
- 既有 `geometry.composerControl*`、`geometry.card*`、`geometry.chromeInset` 等 leaf 一個字都沒改。
- `signatureSurfaces.composer.tokens` 追加三個 composer leaf，`signatureSurfaces.approvalCard.tokens`
  追加 `geometry.approvalCardSpacing`；`componentCompatibility` 不重複宣告。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由 |
| --- | --- |
| old tokens.json → new Android | 不適用：Android 與 spec 同 repository、同 head 發佈；舊 APK 不讀新 JSON。 |
| new tokens.json → old Android | 不適用：舊 Android 沒有這四個常數的 token 讀取，維持原 literal；新增 leaf 不被舊 consumer 讀取。 |
| new → new | Android 由 `UiTokenData` 讀取；`PageGeometryTokenTest` 以 signature surface 驗證 ownership。 |
| persisted old data → new／rollback | 不適用：純 UI token，沒有持久化資料。 |

- 版本／adapter 決定：不需要 bump；四個 leaf 是 additive、optional，generator 對舊 consumer 沒有破壞。
- 回滾：移除四個 leaf 與 Android 的 token read 即回到 literal；沒有資料遷移。
- 本次沒有 `target` / `draft` 條款。

## 4. 分工與證據

- Implementer 獨占路徑：`android/lib/src/main/kotlin/com/phonedsh/ui/ChatMetrics.kt`、`UiMetrics.kt`、
  `spec/ui/v1/tokens.json`（四個 leaf）、本變更單；
  consumer 只在 duplicate consolidation / four new reads：`Composer.kt`、`ApprovalCard.kt`、
  `ChatPage.kt`、`NativeDeviceSessionPage.kt`。
- Shared fixtures：`spec/ui/v1/tokens.json` 本身是唯一值表；Android unit tests 直接讀它
  （`SpecFixtures.tokens`），沒有 hand-copied case。
- Exact commands → 結果見 T1 handoff；本變更單不替代 gate 證據。
- 剩餘風險：四個 leaf 的 Swift 行號是第一波 iOS source 的 current snapshot；若 iOS 再編輯
  `ChatPage.swift`，provenance 必須照 lessons §8 同步。Android 沒有 device/screenshot 驗證。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 3d92e545a31e5897c12c502bf31f6499ef006b2a | T1 worker | 初次凍結：四個 additive composer / approval geometry leaf | Android（同 head）；iOS 不變 |
