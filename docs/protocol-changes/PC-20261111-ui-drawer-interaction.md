# 會話抽屜交互契約：動效、手勢、遮罩寫進 tokens（P09）

```yaml
change: PC-20261111-ui-drawer-interaction
contracts: [P09]
status: implemented
breaking: false
version_decision: tokens.json 仍是 version 1。新增可選頂層組 `interaction` 和可選欄位 `shadows.*.x`（缺省 0）；既有 token 不改名、不改值。
base: bddb6d5b
contract_revision: 0114b516   # 數值與 golden 自 5773807b 起不變；rev 2 只搬移文件位置
```

Protocol impact: P09

P09 — 會話抽屜（任務 tab 的會話列表、Bot tab 的名單共用同一套抽屜外殼）的開合動效、
跟手拖拽、鬆手判定、遮罩與陰影從 iOS 源碼取值寫進 `spec/ui/v1/tokens.json`，並配一份兩端共用的手勢 golden。
這是 Android 對齊 iOS 交互的第一個檢查點；之後的 sheet、長按選單、push 轉場沿用同一結構。

## 1. 識別與角色

- Trigger → 現況 → 期望：
  - iOS（`NativeShell.swift:112-423`）：寬 320；打開 easeInOut 0.28 s，收起 0.22 s；只能左拖關閉，最小拖動 12 pt，
    橫向為主才跟手；拖過一半寬度或預測終點過半就收，否則 0.22 s 彈回；遮罩黑色 0.28 × 進度；陰影 0.12 / 20 / x 6。
  - Android（`android/lib/.../nav/HomeDrawer.kt:285`）：`Dialog` 直接出現和消失，沒有開合動畫，不能拖，沒有陰影。
  - tokens.json 只有 4 個 motion token，沒有抽屜相關的任何值；`UiTokens.easing()` 把 `easeInOut` 映射成 `LinearEasing`。
  - 期望：抽屜的全部數值和規則都在 spec 裡、有 iOS 出處並由 `ui_check.py` 反查；Android 按 spec 實作並用共享 golden 測試。
- 協調者兼 contract owner：Claude。Implementer：DSH worker A（spec 與檢查器，受 owner 指派）、DSH worker B（Android）。
  Reviewer／integrator：Claude。
- Owning contract：`spec/ui/v1/tokens.json`、`spec/ui/v1/schema/tokens.schema.json`、`spec/ui/v1/interaction.md` §1（新增）、
  `spec/ui/v1/golden/drawer-gesture.golden.json`（新增）。
- Producer／consumer：
  - iOS `examples/probe-app/PhoneDSHProbe/NativeShell.swift`：權威來源，本次**不改**。
  - Android `android/lib`（Gradle `generateUiTokens`、`theme/UiTokens.kt`、`nav/HomeDrawer.kt`）：consumer，本次實作。
  - HarmonyOS：不讀 tokens.json，本次不涉及；之後補交互時讀同一份 golden。
  - `spec/ui/v1/tools/ui_check.py`：檢查器，本次擴充。

## 2. 契約 delta

### 2.1 新 token（既有組，不改結構）

| token | 值 | 出處（provenance，tier page） | expect 片段 |
| --- | --- | --- | --- |
| `geometry.drawerWidth` | 320 pt，scalesWith null | `NativeShell.swift:112` | `drawerWidth: CGFloat = 320` |
| `radius.drawerTrailing` | 22 | `NativeShell.swift:445` | `bottomTrailingRadius: isPersistent ? 0 : 22` |
| `motion.drawerOpen` | 280 ms easeInOut once | `NativeShell.swift:401` | `withAnimation(.easeInOut(duration: 0.28)) { drawerOpen = true }` |
| `motion.drawerClose` | 220 ms easeInOut once | `NativeShell.swift:407` | `withAnimation(.easeInOut(duration: 0.22)) { drawerOpen = false }` |
| `shadows.drawer` | opacity 0.12，radius 20，x 6，y 0 | `NativeShell.swift:366`（shadows 自帶 source） | — |

### 2.2 新頂層組 `interaction.drawer`

每一項是 token 引用 `{token, note?, source?, expect?}` 或參數 `{value, unit, source, expect, valueLiteral?, needsDeviceMeasure?, note}`。

| 鍵 | 內容 | 出處 | expect |
| --- | --- | --- | --- |
| `width` | → `geometry.drawerWidth` | | |
| `panelTrailingRadius` | → `radius.drawerTrailing` | | |
| `shadow` | → `shadows.drawer` | | |
| `openMotion` | → `motion.drawerOpen` | | |
| `closeMotion` | → `motion.drawerClose` | | |
| `settleMotion` | → `motion.drawerClose`（未過門檻的彈回） | `NativeShell.swift:423` | `withAnimation(.easeInOut(duration: 0.22)) { dragOffset = 0 }` |
| `closedOverhang` | 32 pt：關閉時 x = −(width + 32)，陰影一併出屏 | `NativeShell.swift:387` | `-(drawerWidth + 32)` |
| `scrimMaxOpacity` | 0.28 opacity，黑色 | `NativeShell.swift:144` | `.opacity(0.28 * drawerProgress)` |
| `dragMinimumDistance` | 12 pt | `NativeShell.swift:411` | `DragGesture(minimumDistance: 12)` |
| `closeThreshold` | 0.5 widthFraction，`valueLiteral: "-drawerWidth / 2"` | `NativeShell.swift:420` | `-drawerWidth / 2` |
| `velocityProjection` | 0.25 s，`needsDeviceMeasure: true` | `NativeShell.swift:419` | `value.predictedEndTranslation.width` |

`unit` 取值：`pt`、`opacity`、`widthFraction`、`s`。

### 2.3 規則（寫進 spec/ui/v1/interaction.md §1，規範性）

1. 打開只由導航鈕觸發（任務頁、Bot 頁、PC 佔位頁的抽屜鈕）；**沒有**邊緣右滑打開。已打開時再觸發不做任何事。打開前收起鍵盤。
2. 拖動只跟隨向左：`offset = min(0, dx)`，向左不設下限（與 iOS `NativeShell.swift:415` 一致）。
3. 只有 `|dx| > |dy|` 的移動才跟手（抽屜內上下滑列表不能帶走抽屜）；拖動距離（歐氏）未達 `dragMinimumDistance` 不算拖動。
4. 拖動同時在遮罩和面板上生效。
5. 進度 `progress = max(0, 1 + offset / width)`（打開時，`NativeShell.swift:392`），遮罩不透明度 = `scrimMaxOpacity × progress`。
6. 鬆手：`dx < −closeThreshold × width` **或** `dx + velocity × velocityProjection < −closeThreshold × width` → 以 `closeMotion` 收起；
   否則以 `settleMotion` 回到 0。比較為嚴格小於。`dx` 是鬆手時的原始橫向位移（不經 `min(0, …)`），velocity 單位 pt/s（Android dp/s）。
7. 點遮罩收起（`closeMotion`）。
8. 收起動畫結束前抽屜保持在畫面上（不得瞬間消失）。
9. Android 加項：抽屜打開時系統返回以 `closeMotion` 收起抽屜，不出棧。依據 §5 `back-gesture`：抽屜是返回棧之上的臨時層，
   收起後頁面與棧深度不變。iOS 無系統返回，不需對應。
10. 曲線定義：`linear`；`easeOut` = cubic-bezier(0, 0, 0.58, 1)；`easeInOut` = cubic-bezier(0.42, 0, 0.58, 1)（Core Animation 控制點；
    SwiftUI 是否完全一致待錄屏實測，見 §4 風險）。

範圍外（不改）：寬屏常駐側欄（`usesSidebar`，寬 ≥ 900 pt）、抽屜內容與列表、無障礙動作文案。

### 2.4 共享 golden `spec/ui/v1/golden/drawer-gesture.golden.json`

由規則 2–6 加上 width 320、門檻 0.5、投影 0.25 s 算出。案例分四組：`release`（鬆手判定）、`follow`（軸向鎖定與向左跟隨）、
`minimumDistance`、`scrim`（偏移→遮罩不透明度）。`ui_check.py` 從 `interaction.drawer` 的值重算每個案例，golden 與 tokens 漂移即失敗。

### 2.5 自檢

- 沒有第二種表達：抽屜數值只存在於 tokens.json；Android 既有的 `SessionsMetrics.DRAWER_WIDTH_PT`／`DRAWER_PANEL_RADIUS_PT` 改為讀生成物或由測試釘到 token。
- 新欄位全部可選且有缺省（`interaction` 缺省為無；`shadows.x` 缺省 0）。
- `curve` 列舉不變；Android `easing()` 對未知曲線改為報錯，不再靜默退化成 linear。
- **有放寬既有校驗（有意）**：`schema_diff` 把 `oneOf/anyOf/allOf` 從「一有變化就判 breaking」改成 variant 數量相同時逐 variant 遞迴比較。原因是 `tokens.schema.json` 在頂層 `oneOf` 的 variant 裡新增可選的 `interaction`；按舊規則，這棵樹會報
  `BREAKING spec/ui/v1/schema/tokens.schema.json#$.oneOf`，屬於誤判。代價是已知漏報：`oneOf` 的 variant 可能由互斥變成重疊，實例從合法變成非法時目前仍放行；要堵住需判斷各 variant 是否互斥，本次不做。此局限由
  `test_oneof_variant_ambiguity_is_known_limitation` 釘住，改這條規則前先看它。

## 3. 相容性與發佈

| Producer → Consumer | 支援方式 |
| --- | --- |
| old tokens → new Android | 生成器把 `interaction` 視為必需：缺失則生成失敗（tokens 與 App 同倉，不存在舊檔案混用） |
| new tokens → old Android | 舊生成器忽略未知頂層鍵與 `shadows.x`，可建置；只是沒有新行為 |
| new → new | 本變更 |
| 持久化舊資料 | 不適用：tokens 是建置期輸入，不落盤到使用者裝置 |

## 4. 分工與證據

- Worker A 獨占：`spec/ui/v1/tokens.json`、`spec/ui/v1/schema/tokens.schema.json`、`spec/ui/v1/README.md`、
  `spec/ui/v1/interaction.md`、`spec/ui/v1/golden/drawer-gesture.golden.json`、`spec/ui/v1/tools/ui_check.py`、
  `spec/ui/v1/tools/test_ui_check.py`、`spec/tools/schema_diff.py`、`spec/tools/test_schema_diff.py`、`spec/tools/cross_check.py`。
  驗收：`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`。
- Worker B 獨占：`android/lib/build.gradle.kts`（生成器段）、`android/lib/src/main/kotlin/com/phonedsh/ui/theme/**`、
  `android/lib/src/main/kotlin/com/phonedsh/ui/nav/HomeDrawer.kt`、新增 `nav/DrawerGesture.kt`、`ui/SessionsMetrics.kt`（抽屜兩個常量）、
  `android/lib/src/test/**`、`android/lib/src/androidTest/**` 中新增的抽屜測試。驗收：`bash scripts/ci/check.sh --only phone-android-tests,phone-android-structure`。
- 共享 fixture：`spec/ui/v1/golden/drawer-gesture.golden.json`；Android 測試必須讀這個檔案，不得手抄案例。
- 剩餘風險：
  - `velocityProjection` 0.25 s 來自社群對 `predictedEndTranslation` 的逆向，未經 Apple 文件確認；需在 iOS 真機記錄 velocity 與 predicted 的比值後改 revision。
  - `easeInOut` 控制點需兩端 60 fps 錄屏抽幀比對。
  - Android 既有窄屏夾取 `min(320, 螢幕寬 − 導航鈕)`：寬 < 364 dp 的裝置抽屜比 iOS 窄，iOS 最小機型 375 pt 不觸發；暫保留並記為已知差異。
  - 真機／錄屏驗收（本變更不涵蓋，記為 NOT_RUN）。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版（draft） | — |
| 2 | Claude | worker A: cross_check 註冊 golden；schema_diff 遞迴 oneOf（CCR，owner 採方案 a）；抽屜規則移入 interaction.md，README 上限維持 345 | — |
| 3 | Claude | 實作完成（worker B，`4bcd7335`）。整合時補 `android/app/.../HostShell.kt`：抽屜在宿主關閉後保持掛載直到收起動畫結束（規則 8），原本 `if (drawerOpen)` 條件掛載會讓選會話、切 tab、導航時瞬間消失。驗證：`:lib:testDebugUnitTest` 1060/0 失敗；`:app:testDebugUnitTest` 338（7 skipped）/0 失敗；`phone-spec`、`phone-cross-tree` PASS；`phone-p0-conformance` 實測為 `page-structure: FAIL (7 new divergence(s) outside the baseline)`，7 條均為 main 既有項：connected-computer `<android-screen>`、files「完成」、home-drawer「手机」/「PC」、pc-pairing `<android-screen>`、settings「已连接的电脑」×2；`phone-android-structure` 僅 main 既有的 readme-map（Bot/PCLink/Venus 未登記）。真機、錄屏：NOT_RUN | Android |
| 4 | Claude | 合入 main（`bddb6d5b`；#118 讓 `NativeShell.swift` 多 15 行）後更新 `tokens.json`、`interaction.md` 與本記錄的 `NativeShell.swift` 行號；補 `anyOf`/`allOf` 逐 variant 測試與 `oneOf` 變體歧義的已知局限測試（`test_oneof_variant_ambiguity_is_known_limitation`）；改正 §2.5 的「沒有放寬」表述；`base` 改為 `bddb6d5b`。驗證：`ui_check: ok`；`test_ui_check.py` 55 tests OK；`test_schema_diff.py` 25 tests OK；`extract_ios_pages.py --check` 為 `contracts up to date`；`phone-spec`/`phone-cross-tree`/`phone-license` PASS，`phone-p0-conformance` 只餘 rev 3 所列 7 條 page-structure divergence | — |
