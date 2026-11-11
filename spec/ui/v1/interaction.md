# PDSH UI 交互契約 v1（normative）

交互契約的數值全部在 `tokens.json#interaction.*`；iOS 出處由 `ui_check.py` 規則 12 逐行反查，共享 golden 在 `golden/`。

## 1. 會話抽屜

抽屜（任務 tab 的會話列表與 Bot tab 的名單共用外殼）的數值全部在 `tokens.json#interaction.drawer`，共享手勢案例在
`golden/drawer-gesture.golden.json`；`ui_check.py` 規則 12 從 token 值重算每個案例，golden 與 tokens 漂移即失敗。

1. 打開只由導航鈕觸發（任務頁、Bot 頁、PC 佔位頁的抽屜鈕）；**沒有**邊緣右滑打開。已打開時再觸發不做任何事。打開前收起鍵盤。
2. 拖動只跟隨向左：`offset = min(0, dx)`，向左不設下限（與 iOS `NativeShell.swift:400` 一致）。
3. 只有 `|dx| > |dy|` 的移動才跟手（抽屜內上下滑列表不能帶走抽屜）；拖動距離（歐氏）未達 `dragMinimumDistance` 不算拖動。
4. 拖動同時在遮罩和面板上生效。
5. 進度 `progress = max(0, 1 + offset / width)`（打開時，`NativeShell.swift:377`），遮罩不透明度 = `scrimMaxOpacity × progress`。
6. 鬆手：`dx < −closeThreshold × width` **或** `dx + velocity × velocityProjection < −closeThreshold × width` → 以 `closeMotion` 收起；
   否則以 `settleMotion` 回到 0。比較為嚴格小於。`dx` 是鬆手時的原始橫向位移（不經 `min(0, …)`），velocity 單位 pt/s（Android dp/s）。
7. 點遮罩收起（`closeMotion`）。
8. 收起動畫結束前抽屜保持在畫面上（不得瞬間消失）。
9. Android 加項：抽屜打開時系統返回以 `closeMotion` 收起抽屜，不出棧。依據 `README.md` §5 `back-gesture`：抽屜是返回棧之上的臨時層，
   收起後頁面與棧深度不變。iOS 無系統返回，不需對應。
10. 曲線定義：`linear`；`easeOut` = cubic-bezier(0, 0, 0.58, 1)；`easeInOut` = cubic-bezier(0.42, 0, 0.58, 1)（Core Animation 控制點；
    SwiftUI 是否完全一致待錄屏實測）。

| 鍵 | 值 | 說明 |
|---|---|---|
| `width` | `geometry.drawerWidth` | 抽屜寬 320pt，`scalesWith: null` |
| `panelTrailingRadius` | `radius.drawerTrailing` | 右側上下圓角 22 |
| `shadow` | `shadows.drawer` | opacity 0.12 / radius 20 / x 6 / y 0 |
| `openMotion` | `motion.drawerOpen` | 280ms easeInOut once |
| `closeMotion` | `motion.drawerClose` | 220ms easeInOut once |
| `settleMotion` | `motion.drawerClose` | 未過門檻以 220ms 彈回 |
| `closedOverhang` | 32pt | 關閉時 x = −(width + 32)，陰影一併出屏 |
| `scrimMaxOpacity` | 0.28 opacity | 黑色遮罩最大不透明度 |
| `dragMinimumDistance` | 12pt | 起拖最小歐氏距離 |
| `closeThreshold` | 0.5 widthFraction | `valueLiteral: "-drawerWidth / 2"` |
| `velocityProjection` | 0.25s | 速度投影，`needsDeviceMeasure: true` |

共享 golden：`golden/drawer-gesture.golden.json`（`release` / `follow` / `minimumDistance` / `scrim` 四組，浮點比較容差 1e-9）。
範圍外：寬屏常駐側欄（`usesSidebar`，寬 ≥ 900 pt）、抽屜內容與列表、無障礙動作文案。

## 2. 底部 Sheet

所有 modal sheet 的數值在 `tokens.json#interaction.sheet`，逐頁 detent 在 `golden/sheet-detents.golden.json`；
`ui_check.py` 規則 12 會核對 13 個 `.presentationDetents` 站點與 `pageDetents` 一一對應，並重算黃金。

1. sheet 是系統模态 bottom sheet：貼底、全寬、頂部圓角；下拉、點遮罩、系統返回都可關閉。源碼沒有任何
   `.interactiveDismissDisabled`，Android 不得禁用這些關閉路徑。
2. detent 只有四種：`default`（沒寫 `.presentationDetents`，等於系統單檔 large）、`large`、`medium`、`medium+large`。
   每頁用哪一組是契約的一部分，見下表與 `golden/sheet-detents.golden.json`；未列出的 sheet 一律 `default`。
3. `.medium` 的螢幕佔比由系統決定（`mediumFraction`，`needsDeviceMeasure: true`）；不得寫死高度或比例。
4. grabber：`homeSheetChrome()`（`HomeSpec.swift:213`）與 ConnectorsPage（`ConnectorsPage.swift:105`）可見；
   子代理目錄顯式隱藏（`NativeSubagentCatalogSheet.swift:434`）；其餘跟系統默認（隱藏）。
5. 背景：`homeSheetChrome()` 與 ConnectorsPage 用 `colors.page`（`HomeSpec.swift:214`、`ConnectorsPage.swift:106`）；
   子代理目錄用 `Color.clear`（`NativeSubagentCatalogSheet.swift:435`）；其餘系統默認。
6. 圓角：ConnectorsPage 32（`ConnectorsPage.swift:107`）；子代理目錄 16（`NativeParityTokens.swift:114` 的 `radiusLG`）；
   其餘系統默認，源碼不可讀，標 `needsDeviceMeasure: true`，不得猜。
7. 彈出與收起動效由系統提供（`presentMotion` / `dismissMotion`，`needsDeviceMeasure: true`）；源碼沒有自訂 transition。
   Android 用平台 bottom sheet 動效，不自創時長；曲線與時長待真機量測。
8. 鍵盤：sheet 內容由系統避讓（resize / 推擠），app 沒有自訂 keyboard avoidance，也沒有
   `presentationContentInteraction`；聚焦的輸入框必須始終在 IME 之上。inset 動畫由系統決定（`needsDeviceMeasure`）。
9. 一次返回只關最上層 sheet；sheet 內的 `NavigationStack` 先出棧，再關 sheet（Android 加項，理由見 §4 規則 7）。
10. 新增或刪除任何 `.presentationDetents` 站點，必須同步 `detentSets` / `pageDetents` 與黃金；站點數不符即失敗。

| 鍵 | 值 | 出處 |
|---|---|---|
| `defaultDetents` | `default`（系統默認 large） | `ChatPage.swift:479` |
| `mediumFraction` | 系統比例，`needsDeviceMeasure` | 系統 API，源碼不可讀 |
| `detentSets` | `default` / `medium` / `medium+large` / `large` 四組 | 四個站點，見 tokens |
| `pageDetents` | 13 個顯式站點 → detent 組 | 13 個 `.presentationDetents` 站點 |
| `grabberVisible` / `grabberHidden` | 可見 / 隱藏 | `HomeSpec.swift:213` / `NativeSubagentCatalogSheet.swift:434` |
| `background` / `backgroundClear` | `colors.page` / `Color.clear` | `HomeSpec.swift:214` / `NativeSubagentCatalogSheet.swift:435` |
| `cornerRadiusConnector` / `cornerRadiusCatalog` / `cornerRadiusDefault` | 32 / 16 / 系統 | `ConnectorsPage.swift:107` / `NativeParityTokens.swift:114` / 系統 |
| `presentMotion` / `dismissMotion` | 系統，`needsDeviceMeasure` | 系統 API |

範圍外：sheet 內容、內部頁面結構、系統 share sheet 的內容（見 §3 `kind: share`）。

## 3. 長按選單

每個 surface 的項目、順序、角色、標籤在 `tokens.json#interaction.contextMenu.surfaces`；
`golden/context-menu-items.golden.json` 由 token 重算。Android 目前用 `combinedClickable` + `DropdownMenu`，
本節約束語意，不約束 iOS chrome。

1. 觸發：長按。點按仍是原本的 row action；不得用右鍵、雙擊或長按以外的路徑代替。
2. 顯示的項目等於該 surface 的 `items`，順序即上屏順序；`when` 為 false 的項目不顯示（不是 disabled）。
   不得新增、刪除、重排或改寫標籤。這些站點的標籤是單一 zh 字面值（沒有 `NativeText` 雙語）。
3. `role: destructive` 用系統破壞性樣式（紅字）；`role: default` 用一般樣式。角色不改變順序。
   `botRow` 的 `dividerBefore` 在該項之前畫分隔線；分隔線不是可選項。
4. `kind`：`action` 執行動作；`share` 走系統 share sheet（不註冊外部分享目標、不做深鏈）；`info` 是不可點的說明列
   （`botRow` 最後一個 Bot 用）。
5. 狀態相關的標籤：`botRow` 的「隱藏」在已隱藏時顯示「取消隱藏」，`altLabel` 是另一個字面值。
6. 預覽：11 個站點全部是無參 `.contextMenu` 閉包，沒有自訂 preview；iOS 的系統預覽是平台 chrome，
   Android 不要求等價預覽，但選單必須錨定在被按的 row 上。
7. 關閉：選擇一項、點外面、系統返回都關閉選單；一次只執行一次動作。選單關閉後才執行動作，
   Android 也必須先關選單再改底層狀態。
8. 長按震動、選單彈出動效屬平台 chrome，不在本契約。`contextMenu(menuItems:preview:)` 這類自訂 preview
   目前不存在；若新增，`ui_check.py` 會以未覆蓋站點失敗，必須先改契約。

| surface | 出處 | 項目（依序） |
|---|---|---|
| `drawerFolder` | `HomeDrawer.swift:465` | 在這裡新建會話；重命名（foldersEnabled）；刪除文件夾（destructive，foldersEnabled） |
| `drawerSession` | `HomeDrawer.swift:565` | 編輯名稱；歸檔 |
| `subagentRow` | `NativeSubagentCatalogSheet.swift:250` | 打開子會話（notExternal）；在側邊欄打開（hasAside） |
| `userBubble` | `ChatPage.swift:4279` | 複製；分享（share，hasText） |
| `assistantBody` | `ChatPage.swift:4291` | 複製全文（hasText） |
| `disclosurePayload` | `ChatPage.swift:5098` | 複製事件數據 |
| `botLink` | `BotWorkCardView.swift:224` | 打開鏈接；複製鏈接 |
| `botRow` | `BotDrawer.swift:324` | 改名；外觀；設為主 Bot（notMainBot）；隱藏／取消隱藏；分隔線；刪除 Bot（destructive，notLastBot）或「這是最後一個 Bot，不能刪除。」（info，lastBot） |
| `botMessageRow` | `BotChatPage.swift:758` | 複製；查看來源 |
| `hostAddress` | `NativeShell.swift:621` | 刪除這個地址（destructive） |
| `sessionsRow` | `SessionsPage.swift:612` | 重命名會話；歸檔會話 |

## 4. Push 與返回

`tokens.json#interaction.push` 只放可從源碼與平台語意確定的常數；`golden/push-back.golden.json` 由它們重算 state 序列。
本節直接對應 `README.md` §5 的 `back-gesture` 白名單條目：返回後頁面與棧深度相同，state 變更序列必須一致。

1. 每個 tab 一個獨立 `NavigationStack`（`NativeShell.swift:234`，`stackScope: perTab`）；切 tab 不清空目標 tab 的棧。
2. 再點當前 tab 不做任何事（`HomeTabBar` 的 `guard tab != selection`），不得 pop-to-root。
3. push 深度 +1，pop 深度 −1；深度 0 的返回退出應用（`rootBack: exit`，README §5）。
4. tab bar 只在選中 tab 深度 0 且鍵盤收起時顯示（`NativeShell.swift:225`）；push 後隱藏（`NativeShell.swift:1203`），
   pop 回根即恢復。Android 的 bottom bar 必須跟隨當前 tab 的深度，不得全域隱藏。
5. 返回消費順序 `backOrder = sheet,drawer,stack,root`：先關 sheet，再按 §1 規則 9 收抽屜，再出棧，最後退出。
   一次返回只消費一層。
6. 預測性返回允許使用（`predictiveBack: allowed`，README §5 `back-gesture`）；手勢進行中不得提前改 state，
   取消時 depth 與 overlay 不變，提交後的序列與非預測返回完全相同。
7. sheet 內的 `NavigationStack` 屬於 sheet 內部棧：系統返回先 pop 內部棧，深度 0 才關 sheet；不得把 sheet 內容
   push 到宿主棧。（iOS 用左上返回鈕，沒有系統返回，這條是 Android 的對應行為。）
8. 動效：iOS 用系統 `NavigationStack` push/pop，沒有 `.navigationTransition` 或 `matchedTransitionSource`
   （`systemMotion`，`needsDeviceMeasure: true`）；Android 用平台轉場，時長與曲線不得硬編碼。

範圍外：deep link 還原棧、`navigationDestination` 的狀態恢復、tab 切換動效。

## 5. 發送鍵

`tokens.json#interaction.composerSend`，`golden/composer-send.golden.json` 由 `canSubmit` 規則重算可見性與可用性。

1. 發送鍵的可見性：`turnRunning && !canSubmit` 時同一位置顯示停止鍵；其餘時候顯示發送鍵。
   `turnRunning && canSubmit` 時停止鍵與發送鍵並排（停止在前，間距 8）。
2. 發送鍵可用性等於 `canSubmit`：
   `composerEnabled && (steer ? hasText && !hasAttachments : (turnRunning ? hasText : hasText || hasAttachments))`。
   `composerEnabled` 已含 pendingQuestion、pendingPermission、恢復期與 `canSend` / `canSteer` 條件。
3. 可用態：底 `colors.primaryButton`、墨 `colors.primaryButtonInk`；不可用：底 `colors.userBubble`、墨 `colors.iconMuted`。
   不可用鍵仍然顯示（disabled），不得隱藏。
4. 外觀切換用 `motion.composerSend`（120 ms easeOut）加 `.scale(scale: 0.8)` 與 `.opacity`（0→1）轉場；
   動畫的 value 是 `canSubmit`，不是草稿文字，所以打字不觸發整鍵動畫。
5. 尺寸 36 pt 圓鈕（`geometry.sendButton`），點擊區域就是圓；`disabled` 時不得提交。
6. 停止鍵與發送鍵不共享 transition：停止鍵出現/消失不動畫，發送鍵的 scale/opacity 只管自己。
7. 無障礙標籤逐字照抄：發送鍵未運行時「发送消息」，運行中 steer 時「补充当前任务」、queue 時「排入下一轮」
   （`sendButtonLabel`，`ChatPage.swift:3150-3153`）；停止鍵「停止执行」／正在停止時「正在停止」。

| 鍵 | 值 | 出處 |
|---|---|---|
| `motion` | `motion.composerSend`（120 ms easeOut） | `ChatPage.swift:2462` |
| `transitionScale` | 0.8 | `ChatPage.swift:2461` |
| `transitionOpacity` | 從 0（`.opacity`） | `ChatPage.swift:2461` |
| `buttonSize` | `geometry.sendButton`（36 pt） | `HomeSpec.swift:72` |
| `enabledFill` / `enabledInk` | `colors.primaryButton` / `colors.primaryButtonInk` | `ChatPage.swift:2454-2456` |
| `disabledFill` / `disabledInk` | `colors.userBubble` / `colors.iconMuted` | `ChatPage.swift:2454-2456` |
| `disabledRule` / `stopRule` | `canSubmit` / `!canSubmit && model.turnRunning` | `ChatPage.swift:2460` / `2448` |

## 6. 按壓態

`tokens.json#interaction.pressed`，`golden/pressed-states.golden.json` 是 rest / pressed / disabled 的透明度表。

1. 按壓態是暫態：放開或手勢取消立即回到 rest，不得停留在 pressed。
2. 抽屜 pill：按下時疊加黑色 0.06，rest 0；抽屜列：按下時以 `colors.userBubble` 填底 0.7，rest 0。
3. 主操作鈕（`HomePrimaryButtonStyle`）：按下時整體 opacity 0.8；disabled 時底色 alpha 0.25。
4. 按壓回饋用 `motion.pressed`（120 ms easeOut）；pressed 切換不改變版面尺寸。
5. **不得縮放**：`scale` 固定 1.0。Android 不得加 scale、elevation 或 Material ripple；只畫上表規定的 overlay / fill。
6. disabled 的元件不進 pressed 態。Bot 抽屜的 pill/列沿用同一組值（`BotDrawer.swift:831/843`），不另立數值。

| 鍵 | 值 | 出處 |
|---|---|---|
| `motion` | `motion.pressed`（120 ms easeOut） | `HomeDrawer.swift:694/707` |
| `pillOverlay` / `pillOverlayColor` | 0.06 / 黑 | `HomeDrawer.swift:693` |
| `rowFill` / `rowFillOpacity` | `colors.userBubble` / 0.7 | `HomeDrawer.swift:706` |
| `primaryPressedOpacity` / `primaryDisabledOpacity` | 0.8 / 0.25 | `HomeSpec.swift:241` / `240` |
| `scale` | 1.0（no scaling） | `HomeDrawer.swift:689` |

## 7. 折疊

`tokens.json#interaction.disclosure`，`golden/disclosure-motion.golden.json` 由三個 motion token 重算時長與曲線。

1. 折疊內容（過程行、工具卡、變更檔、佇列、事件資料等）展開／收合用 `motion.disclosure`（160 ms easeOut）。
2. 抽屜文件夾分組用 `motion.folderCollapse`（180 ms easeOut），`HomeDrawer.swift:460` 一次動畫覆蓋整組的插入/移除。
3. 子代理 chevron 旋轉用 `motion.chevron`（120 ms easeInOut）；chevron 只旋轉 0→90°，不改變 row 高度。
4. 一次點擊只切換一次狀態；整個折疊 body 作為一個單位做高度/透明度動畫，不做逐列 stagger。
5. 系統關閉動畫（Android animator duration scale 0、iOS `reduceMotion` 站點）時直接落位（`reducedMotion: snap`），
   不得留下中間態。
6. 展開／收合不得讓被點的 row 跳位；下方內容平滑讓位，滾動位置以被點 row 為錨。

| 鍵 | 值 | 出處 |
|---|---|---|
| `bodyMotion` | `motion.disclosure`（160 ms easeOut） | `NativeMessageRows.swift:31` |
| `folderMotion` | `motion.folderCollapse`（180 ms easeOut） | `HomeDrawer.swift:460` |
| `chevronMotion` | `motion.chevron`（120 ms easeInOut） | `NativeSubagentCatalogSheet.swift:267` |
| `reducedMotion` | `snap` | `NativeQuestionComposer.swift:627` |

範圍外：shimmer／呼吸燈等循環動效、toast、頁面切換動效、TimelineView 的取樣頻率。
