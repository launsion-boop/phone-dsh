# UI 交互契約批次：sheet、長按選單、push/返回、發送鍵、按壓、折疊（P09）

```yaml
change: PC-20261112-ui-interaction-batch
contracts: [P09]
status: draft
breaking: false
version_decision: tokens.json 仍是 version 1。六個新 `interaction.*` 組與三個新 motion token 都是可選新增；既有 token 不改名、不改值，`interaction.required` 仍只有 `drawer`。
base: 56e7b6ce
contract_revision: <待 contract owner 凍結後填寫>
```

Protocol impact: P09

P09 — 在已凍結的會話抽屜契約（`PC-20261111-ui-drawer-interaction`、`interaction.md` §1、
`golden/drawer-gesture.golden.json`、`ui_check.py` 規則 12）之上，把下一個交互批次寫成同一結構：
sheet、長按選單、push/返回、發送鍵、按壓態、折疊。iOS probe app 是出處與 provenance，不是權威；
所有數值逐字錨在 Swift 行上，系統提供的動效不猜數字，一律 `needsDeviceMeasure: true`。

## 1. 識別與角色

- Trigger → 現況 → 期望：
  - **Sheet**：iOS 有 49 個 `.sheet(`、13 個 `.presentationDetents` 站點，detent 集合只有
    `default` / `medium` / `large` / `medium+large` 四種；`homeSheetChrome()` 給 grabber + `HomeSpec.page` 背景，
    ConnectorsPage 額外把圓角設成 32，子代理目錄隱藏 grabber、透明背景、圓角 16。Android 目前沒有共用 sheet 契約。
  - **長按選單**：iOS 11 個 `.contextMenu`，23 個動作 + 1 個 info 列；Android 用 `combinedClickable` + `DropdownMenu`，
    沒有共用 items/order/role 契約。
  - **Push/返回**：iOS 四個 tab 各一個系統 `NavigationStack`，沒有自訂轉場；`pushedTabs` 控制 tab bar 進出。
    README §5 `back-gesture` 已允許 Android 預測性返回，但沒有 state 序列可測。
  - **發送鍵**：`motion.composerSend` 只有 120 ms easeOut，缺 scale/opacity 參數與 `canSubmit` 真值表。
  - **按壓/折疊**：抽屜 pill 0.06、列 0.7、120 ms、無縮放；折疊 body 160 ms、文件夾 180 ms，皆未進 spec。
  - 期望：六組值、規則、golden 與 checker 一次凍結，Android wave 2 按元件實作，wave 3 才改頁面。
- 協調者兼 contract owner：Claude。本變更的 spec drafter：DSH wave-1 worker（本檔）。
  Reviewer／integrator：Claude。Android implementer：wave 2 六個 worker（§4）。
- Owning 檔案與 shared fixtures：
  - `spec/ui/v1/tokens.json`（`motion.*` 三個新 token、`interaction.*` 六個新組）
  - `spec/ui/v1/schema/tokens.schema.json`（六個 strict 子 schema）
  - `spec/ui/v1/interaction.md` §2–§7
  - `spec/ui/v1/golden/sheet-detents.golden.json`、`context-menu-items.golden.json`、`push-back.golden.json`、
    `composer-send.golden.json`、`pressed-states.golden.json`、`disclosure-motion.golden.json`
  - `spec/ui/v1/tools/ui_check.py`、`spec/ui/v1/tools/test_ui_check.py`、`spec/tools/cross_check.py`（GOLDEN_READERS 六行）
- Producer／consumer：
  - iOS `examples/probe-app/PhoneDSHProbe/**`：出處，本批**不改**。
  - Android `android/lib`：wave 2 consumer，本批不實作，只凍結契約。
  - HarmonyOS：不讀 tokens.json，本批不涉及。
  - `ui_check.py`／`cross_check.py`：契約 gate，本批擴充。

## 2. 契約 delta

只列改動；未變的抽屜語意仍以 `interaction.md` §1 與 `PC-20261111-ui-drawer-interaction` 為準。

### 2.1 新 motion token（既有 `motion` 組）

| token | 值 | provenance（tier page） | expect 片段 |
| --- | --- | --- | --- |
| `motion.pressed` | 120 ms easeOut once | `HomeDrawer.swift:694` | `.easeOut(duration: 0.12), value: configuration.isPressed` |
| `motion.folderCollapse` | 180 ms easeOut once | `HomeDrawer.swift:460` | `.easeOut(duration: 0.18), value: collapsedFolderIDs` |
| `motion.chevron` | 120 ms easeInOut once | `NativeSubagentCatalogSheet.swift:267` | `.easeInOut(duration: 0.12), value: isExpanded` |

### 2.2 新 `interaction.sheet`

| 鍵 | 值 | 出處 |
| --- | --- | --- |
| `defaultDetents` | `default`（系統默認 large） | `ChatPage.swift:479` |
| `mediumFraction` | 系統比例，`needsDeviceMeasure: true` | 系統 API，源碼不可讀 |
| `detentSets` | `default` / `medium` / `medium+large` / `large` 四列 | 4 個 detent 站點 |
| `pageDetents` | 13 列，逐頁 detent | 13 個 `.presentationDetents` 站點 |
| `grabberVisible` / `grabberHidden` | `visible` / `hidden` | `HomeSpec.swift:213` / `NativeSubagentCatalogSheet.swift:434` |
| `background` / `backgroundClear` | `colors.page` / `Color.clear` | `HomeSpec.swift:214` / `NativeSubagentCatalogSheet.swift:435` |
| `cornerRadiusDefault` | 系統，`needsDeviceMeasure: true` | 系統 API |
| `cornerRadiusConnector` / `cornerRadiusCatalog` | 32 pt / 16 pt | `ConnectorsPage.swift:107` / `NativeParityTokens.swift:114` |
| `presentMotion` / `dismissMotion` | 系統，`needsDeviceMeasure: true` | 系統 API |

逐頁 detent（`pageDetents`，黃金逐列重算）：

| page id | detents | 出處 |
| --- | --- | --- |
| `previewShare` | `mediumLarge` | `PreviewSurface.swift:321` |
| `subagentCatalogCompact` | `mediumLarge` | `NativeSubagentCatalogSheet.swift:433` |
| `chatSessions` | `large` | `ChatPage.swift:484` |
| `chatSubagentCatalog` | `mediumLarge` | `ChatPage.swift:544` |
| `chatJobs` | `mediumLarge` | `ChatPage.swift:552` |
| `chatSchedules` | `mediumLarge` | `ChatPage.swift:560` |
| `chatArtifacts` | `mediumLarge` | `ChatPage.swift:566` |
| `dailyBriefSource` | `medium` | `DailyBriefPage.swift:155` |
| `configurationInfo` | `mediumLarge` | `NativeConfigurationPage.swift:81` |
| `composerStats` | `medium` | `NativeComposerStats.swift:125` |
| `connectors` | `mediumLarge` | `ConnectorsPage.swift:104` |
| `workbench` | `large` | `NativeWorkbenchPage.swift:40` |
| `turnUsage` | `medium` | `NativeMessageActions.swift:92` |

### 2.3 新 `interaction.contextMenu`

`preview = system`（11 個站點都是無參 `.contextMenu` 閉包，沒有自訂 preview）。`surfaces` 11 列、24 個 item：

| surface | 出處 | items（依序；role/kind/when） |
| --- | --- | --- |
| `drawerFolder` | `HomeDrawer.swift:465` | 在這裡新建會話（always）；重命名（foldersEnabled）；刪除文件夾（destructive, foldersEnabled） |
| `drawerSession` | `HomeDrawer.swift:565` | 編輯名稱；歸檔 |
| `subagentRow` | `NativeSubagentCatalogSheet.swift:250` | 打開子會話（notExternal）；在側邊欄打開（hasAside） |
| `userBubble` | `ChatPage.swift:4279` | 複製（hasText）；分享（share, hasText） |
| `assistantBody` | `ChatPage.swift:4291` | 複製全文（hasText） |
| `disclosurePayload` | `ChatPage.swift:5098` | 複製事件數據 |
| `botLink` | `BotWorkCardView.swift:224` | 打開鏈接；複製鏈接 |
| `botRow` | `BotDrawer.swift:324` | 改名；外觀；設為主 Bot（notMainBot）；隱藏／取消隱藏；分隔線；刪除 Bot（destructive, notLastBot）或 info 列（lastBot） |
| `botMessageRow` | `BotChatPage.swift:758` | 複製；查看來源 |
| `hostAddress` | `NativeShell.swift:621` | 刪除這個地址（destructive） |
| `sessionsRow` | `SessionsPage.swift:612` | 重命名會話；歸檔會話 |

item 的 `when` 由 Android 以 row 狀態求值；`label` 是 zh 字面值（這些站點沒有 `NativeText` 雙語）。
`botRow` 的 `altLabel` 是「取消隱藏」，`dividerBefore` 在刪除/info 之前。

### 2.4 新 `interaction.push`

| 鍵 | 值 | 出處／說明 |
| --- | --- | --- |
| `stackScope` | `perTab` | `NativeShell.swift:234` |
| `rootBack` | `exit` | README §5 `back-gesture` |
| `backOrder` | `sheet,drawer,stack,root` | 返回逐層消費 |
| `barVisibleAtRoot` | `true` | `NativeShell.swift:225` |
| `barHiddenWhenPushed` | `true` | `NativeShell.swift:1203` |
| `predictiveBack` | `allowed` | README §5 `back-gesture` 白名單 |
| `systemMotion` | 系統，`needsDeviceMeasure: true` | 無 `.navigationTransition` / `matchedTransitionSource` |

push/pop 深度 ±1 是規則（`interaction.md` §4 規則 3），不是可調數值；golden 以規則重算 state 序列。

### 2.5 新 `interaction.composerSend`

| 鍵 | 值 | 出處 |
| --- | --- | --- |
| `motion` | `motion.composerSend` | `ChatPage.swift:2462` |
| `transitionScale` | 0.8 | `ChatPage.swift:2461` |
| `transitionOpacity` | 0（`.opacity` transition） | `ChatPage.swift:2461` |
| `buttonSize` | `geometry.sendButton`（36 pt） | `HomeSpec.swift:72` |
| `enabledFill` / `enabledInk` | `colors.primaryButton` / `colors.primaryButtonInk` | `ChatPage.swift:2454-2456` |
| `disabledFill` / `disabledInk` | `colors.userBubble` / `colors.iconMuted` | `ChatPage.swift:2454-2456` |
| `disabledRule` | `canSubmit` | `ChatPage.swift:2460` |
| `stopRule` | `turnRunning && !canSubmit` | `ChatPage.swift:2448` |

### 2.6 新 `interaction.pressed`

| 鍵 | 值 | 出處 |
| --- | --- | --- |
| `motion` | `motion.pressed` | `HomeDrawer.swift:694/707` |
| `pillOverlay` / `pillOverlayColor` | 0.06 / `Color.black` | `HomeDrawer.swift:693` |
| `rowFill` / `rowFillOpacity` | `colors.userBubble` / 0.7 | `HomeDrawer.swift:706` |
| `primaryPressedOpacity` | 0.8 | `HomeSpec.swift:241` |
| `primaryDisabledOpacity` | 0.25 | `HomeSpec.swift:240` |
| `scale` | 1.0（no scaling） | `HomeDrawer.swift:689` |

### 2.7 新 `interaction.disclosure`

| 鍵 | 值 | 出處 |
| --- | --- | --- |
| `bodyMotion` | `motion.disclosure`（160 ms easeOut） | `NativeMessageRows.swift:31` |
| `folderMotion` | `motion.folderCollapse`（180 ms easeOut） | `HomeDrawer.swift:460` |
| `chevronMotion` | `motion.chevron`（120 ms easeInOut） | `NativeSubagentCatalogSheet.swift:267` |
| `reducedMotion` | `snap` | `NativeQuestionComposer.swift:627` |

### 2.8 Schema

- `interaction.required` 維持 `["drawer"]`：六個新組都是 optional property（schema diff 非 breaking）。
- 每組 `additionalProperties: false`，key 集合在 schema 與 checker 兩邊都凍結。
- 成員三態：`token` 引用（組別限定 family）、`value` 參數（number/string/boolean + `unit`）、
  `needsDeviceMeasure` 系統值（只准 `unit`/`note`，不得帶 value）。
- 表格列（`detentSets`、`pageDetents`、`contextMenu.surfaces`/`items`）各自 strict item schema。
- 既有 `interaction.drawer` schema 一個字都沒改。

### 2.9 Golden

| golden | kind | 重算內容 | row 數 |
| --- | --- | --- | --- |
| `sheet-detents.golden.json` | `sheet-detents` | default 組、detent 組 id 集合、13 頁 → detent | 17 |
| `context-menu-items.golden.json` | `context-menu-items` | 11 surface、24 item 的 label/role/kind/order | 24 |
| `push-back.golden.json` | `push-back` | 11 個 state 序列（push/back/predictive-cancel、overlay 優先序） | 11 |
| `composer-send.golden.json` | `composer-send` | 10 個 `canSubmit` / send-visible / stop-visible 案例 | 10 |
| `pressed-states.golden.json` | `pressed-states` | 3 個 surface 的 rest/pressed/disabled/scale | 3 |
| `disclosure-motion.golden.json` | `disclosure-motion` | 3 條 motion 的 duration/curve + reduced-motion | 3 |

### 2.10 Checker

`ui_check.py` 規則 12 由「只查 `interaction.drawer`」推廣成「查每個 `interaction.*` 組」：

- group key 集合凍結、未知組直接失敗；
- token 引用必須解析，且 family 符合該組（sheet 只准 `colors`，composerSend 准 geometry/colors/motion，…）；
- `source` + `expect` 逐行反查（probe app 不在時跳過，與規則 4b 一致）；
- 數值參數的 `value` / `valueLiteral` 必須出現在 `expect`；`needsDeviceMeasure` 例外；
- 系統值不得帶 value；數字不得無錨點；
- 表格列數、id 唯一、detent 引用、menu label 唯一、`.contextMenu` 站點數與自訂 preview 掃描；
- 六個 golden 全部由 token 重算。

新增 mutation tests（`test_ui_check.py`）：sheet（6）、contextMenu（3）、push（4）、composerSend（2）、
pressed（3）、disclosure（2）、通用（2），連同既有 drawer 測試與真實檔案的 green run。

### 2.11 自檢

- 沒有第二種表達：六組值只存在 tokens.json；golden 從 token 重算，checker 不重抄數字。
- 新欄位／新組全部可選；schema 的 `additionalProperties: false` 只作用在組內，不是要求組存在。
- 沒有放寬任何既有校驗：drawer 的 schema、golden、22 個案例都不變；README 345 行上限未動（本批不改 README）。
- 沒有新增平台分支或別名欄位；沒有改 `spec/ui/v1/pages/**`。
- 所有系統值（sheet medium 比例、系統 sheet 圓角、sheet/push 動效）都沒有寫數字，標 `needsDeviceMeasure: true`。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old tokens → new Android | 舊檔仍通過 schema（新組 optional）。wave 2 的 Android 生成器若缺它讀的組，必須 fail loud，不得補預設值；本批不提供 runtime fallback。 |
| new tokens → old Android | 舊生成器忽略未知 `interaction.*` 組與新 motion token，可建置；只是沒有新行為。 |
| new → new | 本變更。`ui_check.py` 要求七組都存在，golden 與 token 同步。 |
| persisted old data → new／rollback | 不適用：tokens 是建置期輸入，不落盤到使用者裝置。 |

- 版本決定：tokens.json version 1；不新增 schema 版本、不做 adapter。依據 owning version rule（optional additions）。
- 移除舊路徑的條件：無舊路徑可移除；抽屜契約原樣保留。
- `target`／`draft` 條款中，本次實作與仍保留的差異：本批只凍結契約與 checker，Android 實作在 wave 2；
  系統動效與 `.medium` 比例仍待真機量測。

## 4. 分工與證據

### 4.1 Wave 2 file ownership（每個 contract 一個 Android worker，路徑不相交）

| worker | contract | 獨占路徑（新檔為主） | 驗收 |
| --- | --- | --- | --- |
| W2-SHEET | `interaction.sheet` | `android/lib/src/main/kotlin/com/phonedsh/ui/sheet/**`、`android/lib/src/test/**/UiSheetContractTest.kt` | `:lib:testDebugUnitTest` |
| W2-MENU | `interaction.contextMenu` | `android/lib/src/main/kotlin/com/phonedsh/ui/menu/**`、`android/lib/src/test/**/UiContextMenuContractTest.kt` | 同上 |
| W2-NAV | `interaction.push` | `android/lib/src/main/kotlin/com/phonedsh/ui/nav/BackCoordinator.kt`、`ui/nav/PushBackState.kt`、`android/lib/src/test/**/UiPushBackContractTest.kt` | 同上 |
| W2-COMPOSER | `interaction.composerSend` | `android/lib/src/main/kotlin/com/phonedsh/ui/composer/**`、`android/lib/src/test/**/UiComposerSendContractTest.kt` | 同上 |
| W2-PRESS | `interaction.pressed` | `android/lib/src/main/kotlin/com/phonedsh/ui/press/**`、`android/lib/src/test/**/UiPressedContractTest.kt` | 同上 |
| W2-DISCLOSURE | `interaction.disclosure` | `android/lib/src/main/kotlin/com/phonedsh/ui/disclosure/**`、`android/lib/src/test/**/UiDisclosureContractTest.kt` | 同上 |

- wave 2 不改任何既有頁面檔（`ui/page/**`、`ui/nav/HomeDrawer.kt`、`ui/nav/HomeTabBar.kt`）；頁面採用是 wave 3，
  每個頁面檔在 wave 3 只有一個 owner。
- 若 contract owner 要把抽屜的 Bot 複本也納入 pressed adoption，需另開一條 `HomeDrawer.kt` 的單檔指派，
  不可與其他 worker 並行改同一檔。
- 每個 worker 的測試必須從磁碟讀 `spec/ui/v1/golden/<name>.golden.json`，不得手抄案例（lessons §4）。

### 4.2 Shared fixtures

六個 golden 是正例與邊界；反例（token 引用失效、source 漂移、value 不在 expect、未知 detent、
menu 站點數不符、未知 back layer、canSubmit 反向）由 `test_ui_check.py` 的 mutation tests 覆蓋。

### 4.3 Exact commands → 結果

| 命令 | 結果 |
| --- | --- |
| `python3 spec/ui/v1/tools/ui_check.py` | PASS（12 files；七個 interaction golden 全重算） |
| `python3 -m unittest spec.ui.v1.tools.test_ui_check` | PASS（78 tests） |
| `python3 -m unittest discover -s spec/tools -p 'test_*.py'` | PASS（91 tests） |
| `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | phone-spec PASS、phone-cross-tree PASS；phone-p0-conformance 只餘 main 既有的 7 個 page-structure 差異（`ui_check: ok`）；整體 exit 1，非本批引入 |

### 4.4 剩餘風險

- **系統動效未量測**：sheet 彈出/收起、push/pop、`.medium` 比例、系統圓角都標 `needsDeviceMeasure: true`；
  30/60/120 Hz 的實際時長與曲線要真機錄屏後改 revision。
- **Android 預測性返回的 OEM 差異**：`backOrder` 與 state 序列可測，但手勢進度回調與 cancel 行為需真機。
- **選單 chrome 不等價**：iOS 系統 context menu 有預覽與模糊背景，Android `DropdownMenu` 沒有；
  本契約只保證 items/order/role/label/關閉時機。label 是 zh 字面值，繁中/英文語系沒有 `NativeText` 可用。
- **sheet detent 逐頁表會漂移**：新增 sheet 或改 detent 必須同步三處（tokens、golden、checker 站點數）；
  這是刻意的 gate，不是可以順手改的白名單。
- **48 個 deferred 站點**：本批只覆蓋六個交互面；循環動效、toast、banner、sidebar、process row 100 ms、
  question pager、plan card pressed 都留給後續批次，Appendix A 逐站點列了理由。
- **Android wave 2 尚未開始**：所有 Android 實作與真機／模擬器驗收都是 NOT_RUN。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | DSH wave-1 worker（drafter） | 初版 draft；待 Claude 以 contract owner 身分 freeze／改 revision | — |

## Appendix A. 交互站點清單（95）

抽取方式：`examples/probe-app/PhoneDSHProbe/**/*.swift` 中所有 `withAnimation(`、`.animation(`、`.transition(`
（逐行 regex，含子目錄）。95 個命中裡有 3 個是 `TimelineView(.animation)` 的取樣頻率，不是轉場，列為「非動效」；
其餘 92 個逐一歸類。狀態：`本批 covered`（六個契約之一）、`既有 token`（抽屜/shimmer，本批不改值）、`deferred`（附理由）。

統計：本批 covered 27、既有 token 17、deferred 48、非動效 3。

| # | site | construct | token | 狀態 | 理由／覆蓋章節 |
| --- | --- | --- | --- | --- | --- |
| 1 | `Bot/BotActivityLine.swift:103` | `withAnimation` | `—` | deferred | activity 呼吸 1.1 s，循環動效不在本批 |
| 2 | `Bot/BotActivityLine.swift:128` | `.transition` | `—` | deferred | activity 文字替換轉場 |
| 3 | `Bot/BotActivityLine.swift:134` | `.animation` | `—` | deferred | activity 文字淡入 350 ms |
| 4 | `Bot/BotActivityLine.swift:186` | `withAnimation` | `motion.shimmer` | 既有 token | §1，本批不改值 |
| 5 | `Bot/BotActivityLine.swift:189` | `withAnimation` | `—` | deferred | activity 呼吸 1.2 s |
| 6 | `Bot/BotCardView.swift:180` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 7 | `Bot/BotChatPage.swift:263` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 8 | `Bot/BotChatPage.swift:297` | `withAnimation` | `—` | deferred | scroll 對位，不是元件轉場 |
| 9 | `Bot/BotChatPage.swift:346` | `.transition` | `—` | deferred | activity line 插入位移 |
| 10 | `Bot/BotChatPage.swift:422` | `.animation` | `—` | deferred | activity line 顯示 250 ms |
| 11 | `Bot/BotDrawer.swift:123` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 12 | `Bot/BotDrawer.swift:129` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 13 | `Bot/BotDrawer.swift:831` | `.animation` | `motion.pressed` | 本批 covered | §6 |
| 14 | `Bot/BotDrawer.swift:843` | `.animation` | `motion.pressed` | 本批 covered | §6 |
| 15 | `Bot/BotFixtures.swift:455` | `.transition` | `—` | deferred | Bot fixture banner；非產品路徑 |
| 16 | `Bot/BotFixtures.swift:504` | `withAnimation` | `motion.drawerOpen` | 既有 token | §1，本批不改值 |
| 17 | `Bot/BotFixtures.swift:575` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 18 | `Bot/BotFixtures.swift:595` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 19 | `Bot/BotFixtures.swift:597` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 20 | `Bot/BotFixtures.swift:604` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 21 | `Bot/BotHeaderActivityIcon.swift:39` | `.animation` | `—` | 非動效 | TimelineView(.animation) 取樣頻率，不是轉場 |
| 22 | `Bot/BotHeaderActivityIcon.swift:47` | `.animation` | `—` | 非動效 | TimelineView(.animation) 取樣頻率，不是轉場 |
| 23 | `Bot/BotWorkCardView.swift:87` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 24 | `Bot/Fish/BotFishView.swift:92` | `.animation` | `—` | 非動效 | TimelineView(.animation) 取樣頻率，不是轉場 |
| 25 | `ChatPage.swift:1429` | `withAnimation` | `—` | deferred | transcript 尾部 scroll 200 ms |
| 26 | `ChatPage.swift:1452` | `.transition` | `—` | deferred | session 切換指示器淡出 |
| 27 | `ChatPage.swift:1457` | `.animation` | `—` | deferred | session 切換指示器 160 ms easeInOut；曲線語意與 disclosure 不同 |
| 28 | `ChatPage.swift:1976` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 29 | `ChatPage.swift:2461` | `.transition` | `motion.composerSend` | 本批 covered | §5 |
| 30 | `ChatPage.swift:2462` | `.animation` | `motion.composerSend` | 本批 covered | §5 |
| 31 | `ChatPage.swift:3322` | `withAnimation` | `—` | deferred | slash menu scroll 120 ms |
| 32 | `ChatPage.swift:4406` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 33 | `ChatPage.swift:4518` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 34 | `ChatPage.swift:4756` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 35 | `DSHComponents.swift:56` | `withAnimation` | `motion.shimmer` | 既有 token | §1，本批不改值 |
| 36 | `HomeDrawer.swift:65` | `.transition` | `—` | deferred | 錯誤列淡出 |
| 37 | `HomeDrawer.swift:76` | `.animation` | `—` | deferred | 錯誤列 150 ms |
| 38 | `HomeDrawer.swift:93` | `.transition` | `—` | deferred | 歸檔 toast 淡入 |
| 39 | `HomeDrawer.swift:221` | `.transition` | `—` | deferred | 新會話受阻說明淡入 |
| 40 | `HomeDrawer.swift:226` | `.animation` | `—` | deferred | 新會話受阻 150 ms |
| 41 | `HomeDrawer.swift:460` | `.animation` | `motion.folderCollapse` | 本批 covered | §7 |
| 42 | `HomeDrawer.swift:668` | `withAnimation` | `—` | deferred | 歸檔 toast 顯示 |
| 43 | `HomeDrawer.swift:670` | `withAnimation` | `—` | deferred | 歸檔 toast 收起 |
| 44 | `HomeDrawer.swift:681` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 45 | `HomeDrawer.swift:694` | `.animation` | `motion.pressed` | 本批 covered | §6 |
| 46 | `HomeDrawer.swift:707` | `.animation` | `motion.pressed` | 本批 covered | §6 |
| 47 | `NativeChangedFilesCard.swift:77` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 48 | `NativeChatTimelineChrome.swift:21` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 49 | `NativeChatTimelineChrome.swift:48` | `.transition` | `motion.disclosure` | 本批 covered | §7 |
| 50 | `NativeMessageRows.swift:31` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 51 | `NativePlanCard.swift:257` | `.animation` | `—` | deferred | plan card 按壓態（自己的 fill，不在 drawer pressed 契約） |
| 52 | `NativePlanReviewCard.swift:219` | `.animation` | `—` | deferred | plan review 按壓態 120 ms |
| 53 | `NativeProcessGroupHeader.swift:103` | `.animation` | `—` | deferred | process group 100 ms |
| 54 | `NativeQuestionComposer.swift:449` | `.animation` | `—` | deferred | 選項 highlight 120 ms |
| 55 | `NativeQuestionComposer.swift:472` | `.animation` | `—` | deferred | 選項 active 120 ms |
| 56 | `NativeQuestionComposer.swift:562` | `withAnimation` | `—` | deferred | question pager 200 ms |
| 57 | `NativeQuestionComposer.swift:569` | `withAnimation` | `—` | deferred | question pager 200 ms |
| 58 | `NativeQuestionComposer.swift:580` | `withAnimation` | `—` | deferred | question pager 200 ms |
| 59 | `NativeQuestionComposer.swift:627` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 60 | `NativeQuestionReplyBubble.swift:140` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 61 | `NativeRunningStatus.swift:92` | `withAnimation` | `motion.shimmer` | 既有 token | §1，本批不改值 |
| 62 | `NativeShell.swift:147` | `.transition` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 63 | `NativeShell.swift:237` | `withAnimation` | `—` | deferred | 寬屏常駐側欄；§1 明示範圍外 |
| 64 | `NativeShell.swift:261` | `withAnimation` | `—` | deferred | 寬屏常駐側欄 |
| 65 | `NativeShell.swift:278` | `withAnimation` | `—` | deferred | 寬屏常駐側欄 |
| 66 | `NativeShell.swift:296` | `withAnimation` | `—` | deferred | 寬屏常駐側欄 |
| 67 | `NativeShell.swift:386` | `withAnimation` | `motion.drawerOpen` | 既有 token | §1，本批不改值 |
| 68 | `NativeShell.swift:392` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 69 | `NativeShell.swift:408` | `withAnimation` | `motion.drawerClose` | 既有 token | §1，本批不改值 |
| 70 | `NativeShell.swift:446` | `withAnimation` | `—` | deferred | 寬屏側欄收起 |
| 71 | `NativeShell.swift:686` | `.transition` | `—` | deferred | 新增主機列淡入 |
| 72 | `NativeSubagentCatalogSheet.swift:267` | `.animation` | `motion.chevron` | 本批 covered | §7 |
| 73 | `NativeSubagentHeaderButton.swift:62` | `.animation` | `motion.chevron` | 本批 covered | §7 |
| 74 | `NativeSubagentHeaderButton.swift:105` | `withAnimation` | `motion.shimmer` | 既有 token | §1，本批不改值 |
| 75 | `NativeSubagentToolRows.swift:170` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 76 | `NativeSubagentToolRows.swift:180` | `.transition` | `motion.disclosure` | 本批 covered | §7 |
| 77 | `NativeSubagentToolRows.swift:224` | `.animation` | `—` | deferred | tool 詳情 100 ms |
| 78 | `NativeSubagentToolRows.swift:263` | `withAnimation` | `—` | deferred | 呼吸 1.2 s |
| 79 | `NativeTodoDock.swift:283` | `withAnimation` | `motion.shimmer` | 既有 token | §1，本批不改值 |
| 80 | `NativeToolCardChrome.swift:192` | `withAnimation` | `—` | deferred | 複製回饋 120 ms |
| 81 | `NativeToolCardChrome.swift:195` | `withAnimation` | `—` | deferred | 複製回饋 120 ms |
| 82 | `NativeToolCardChrome.swift:351` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 83 | `NativeToolDetailsCard.swift:542` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 84 | `NativeToolOutputFold.swift:147` | `withAnimation` | `motion.disclosure` | 本批 covered | §7 |
| 85 | `NativeTurnProcessRow.swift:208` | `.animation` | `—` | deferred | process row 100 ms |
| 86 | `NativeTurnTriggerRow.swift:159` | `withAnimation` | `—` | deferred | trigger row 100 ms |
| 87 | `PCPairingPage.swift:161` | `withAnimation` | `—` | deferred | 配對頁選項 disclosure 180 ms；語意不是文件夾 |
| 88 | `RootView.swift:31` | `.transition` | `—` | deferred | PCLink notice banner 移入 |
| 89 | `RootView.swift:59` | `withAnimation` | `—` | deferred | notice 關閉 180 ms |
| 90 | `SessionsPage.swift:192` | `.animation` | `—` | deferred | 新會話受阻 200 ms |
| 91 | `SessionsPage.swift:200` | `.transition` | `—` | deferred | 受阻說明淡入 |
| 92 | `SessionsPage.swift:363` | `.transition` | `—` | deferred | 歸檔 toast 淡出 |
| 93 | `SessionsPage.swift:647` | `withAnimation` | `—` | deferred | 歸檔 toast 顯示 |
| 94 | `SessionsPage.swift:649` | `withAnimation` | `—` | deferred | 歸檔 toast 收起 |
| 95 | `SessionsPage.swift:679` | `.animation` | `—` | deferred | session row 按壓 150 ms（與 drawer row 不同值） |
