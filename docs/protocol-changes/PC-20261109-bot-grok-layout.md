<!-- SPDX-License-Identifier: MIT -->

# Bot 页 Grok 式改版（P09 页面契约修訂）

```yaml
change: PC-20261109-bot-grok-layout
contracts: [P09, P27]
status: implemented
base: 832f34dcf1e63897e4736a477500815ef7bc582a
contract_revision: PC-20261109-bot-grok-layout@2
version_decision: 复用 pdsh.ui.page-structure/1、既有 P27 BotRows/UserAction 與 tokens；不新增 schema 欄位、wire frame、事件或版本，同 App bundle 配對升級。
```

Protocol impact: P09; P27: none — Bot 頁只消費既有 BotRows/UserAction，未改 schema、事件、投影或 wire。

## 1. 觸發與現狀

- Bot 頁頭部原本是左側 44pt 靜態頭像（唯一設置入口）加左對齊名字／副標題；右側無膠囊。
- 空狀態是 72pt 靜態頭像，放在 `LazyVStack` 內用 `.padding(.top, 120)` 近似置中。
- 頭像全部是 `Image("BotAvatar")` 靜態圖；`BotRuntimePresentation { fishState, runningTurnID, activity }` 已由 runtime 算出，但 UI 沒有任何消費者。
- 輸入區是 DSH 白色 r24 卡片，底部並排停止與發送兩顆 36pt 按鈕。
- 運行指示是 `NativeRunningStatus`「深度求索中，用時 …」，不是上游 `ActivityLine`。

## 2. 契約凍結（current → expected）

| 項 | current | expected |
| --- | --- | --- |
| Bot 頭部 | 左 44pt 靜態頭像 + 左對齊標題塊 | 整屏水平居中的 44pt 膠囊：32pt 實時大肥魚 + 17pt semibold 名字；點按開 Bot 信息（id `bot.info.open`）；名字尾部截斷且不與右側膠囊重疊 |
| 右側膠囊 | 無 | 與 DSH 頁同一個 `HeaderActionPill`：連接設備（id `bot.connect-device`、同一個 `NativeDeviceConnectionPage`、同一個在線圓點）＋「…」菜單（id `bot.header.menu`） |
| Bot 設置入口 | 頭像按鈕 | 移入「…」菜單；菜單頂部是不可點的「跟進中 N · 需要你處理 M」，下面為 Bot 信息與設置、記憶、例行任務、審批記錄 |
| 需要你處理 | 副標題文字 | 頭像膠囊右上角 6pt 提示圓點；菜單頂部仍保留文字說明 |
| 空狀態 | 72pt 靜態頭像 + top padding 120 | 96pt 實時大肥魚（可戳）在消息區可用高度內垂直／水平居中；標題 15/22 semibold、正文 13/18、間距 12；id `bot.chat.empty` |
| 頭像 | 整張靜態 PNG | `BotFishView(state:size:still:allowsPoke:)` 分層渲染器；全部 `BotFishLifecycle` 狀態、表情 sprite、彈簧、眨眼與裝飾由真實事件驅動；資源缺失回退 `Image("BotAvatar")` |
| 運行指示 | `NativeRunningStatus` 在 transcript 底部 | 輸入框上方左對齊一條 `bot.activity.line`：20pt 實時大肥魚 + 13/18 單行文字 + shimmer；thinking／tool-running／streaming 輪換或工具 detail；正文開始流式輸出後隱藏；不攔截觸摸 |
| 輸入區 | DSH r24 卡片、兩顆按鈕 | Grok 式白色膠囊：最小高 52、r26、細描邊 + 浮動陰影、左右內距 16、多行上限約 5 行；右側只有一顆 36pt 發送／停止按鈕；無麥克風、無語音模式、無「+」 |
| 待審批／60s 閒置 | 無魚狀態覆蓋 | 有待審批 → alerting；運行結束後 60s → sleeping；任何輸入、發送或點按喚醒 |
| DSH 頁 | 私有膠囊代碼 | 僅抽取共享 `HeaderActionPill`；外觀、行為、`chat.connect-device` 等 id 不變；`chat.json` 無觀感差異 |

## 3. 兼容性

| 場景 | 結論 |
| --- | --- |
| 舊 App bundle → 新 bundle | 沒有 wire／持久化／環境變量變更；BotRows 與 durable event 照常讀取，舊資料可直接顯示。 |
| 新 App → 舊 Android/Harmony 端 | iOS 專有頁面改版；Android/Harmony 沒有 Bot 頁，不存在共同頁面契約的鏡像變更。 |
| P27 BotRows／UserAction | 未新增或修改 row、batch、projection、user action、action result schema；UI 只讀既有 driver。 |
| 回滾 | 刪除本頁改版只影響 iOS Bot 頁呈現；Bot durable rows、MCP、Host 與魚狀態機不受影響。 |
| 頁面契約檢查 | `ui_check.py` 的 token 來源行因 `ChatPage.swift` 抽取共享膠囊而重釘；值與對比度不變。`bot-chat.md` 仍為 target，模擬器證據由調用方補。 |

沒有新增 wire frame、JSON-RPC method、環境變量、BotEvent 類型、schema 版本或 protocol surface。

## 4. 驗收

- `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（容器內已跑：5 files、13 contrast pairs、6 deferred AA pairs、0 failures）。
- `python3 spec/ui/v1/tools/page_structure_check.py --root . --page chat --strict` → PASS（0 divergences）。
- `python3 spec/ui/v1/tools/page_structure_check.py --root . --page runtime-details --strict` → PASS（0 divergences）。
- `CI_PROTOCOL_BASE=832f34dcf1e63897e4736a477500815ef7bc582a bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` → phone-spec PASS、phone-cross-tree PASS；phone-p0-conformance FAIL，原因是此 checkout 的 12 個既有 divergence（connectors/daily-brief/files/home-drawer/native-automation/session-artifacts/settings 等；在未修改的 base worktree 上以同一命令重現相同 12 個），本改版的 chat/runtime-details 頁面本身為 0 divergence。
- `git diff --check` → PASS。
- `cd examples/probe-app && xcodegen generate && xcodebuild … build` → NOT_RUN（容器無 Xcode／iOS SDK）。
- `swift test --filter PhoneDSHBotTests` → NOT_RUN（容器無 Swift/Xcode 工具鏈）。
- `bash scripts/ci/bot-ui/capture.sh --appearance light,dark` 與模擬器手測 → NOT_RUN（容器無 Xcode；截圖場景由 `fish-renderer` 寫入 capture.sh）。

## 5. 第 2 輪本機驗收修復（r2，base `d2d56f64dbaef802c67b6ea7be35aa1bb4c6a62d`）

第一輪集成交付在本機 `xcodebuild` 失敗並暴露三處 UI 回退；r2 只修正 iOS Bot 頁呈現，不改 P09 頁面契約、P27 BotRows/UserAction、wire、投影或 durable 資料。

| 項 | r1 現狀 | r2 修正 |
| --- | --- | --- |
| 編譯 | `BotRuntimePresentation.swift` 把字典字面量賦給 `[BotJSONValue]`，`make(...)` 與 `var timed` 黏在同一行；`BotActivityLine.swift` 缺 `import PhoneDSHBot` | 改為 `[String: PhoneDSHBot.BotJSONValue]`、恢復換行、補 import |
| 運行中發送 | 運行中輸入區只剩停止按鈕，steering 無入口，但「發送會併入當前回合…」提示仍在 | 單按鈕三態：空閒發送（無文字置灰）／運行中空輸入停止／運行中帶文字發送並 steering；保留 `bot.composer.send`、`bot.composer.stop` |
| 發送按鈕位置 | HStack `.bottom`、按鈕無內距，36pt 按鈕貼 52pt 膠囊底邊 | 自訂 layout：單行上下各 8pt 垂直居中，多行貼底 8pt，右側內距 8；TextField 與按鈕中心對齊 |
| 頭部活動 | 32pt 頭像動作位移約 1/13，肉眼看不到 | 膠囊內名字右側新增 14pt 活動小圖標：thinking/無正文 streaming 三點（1.2s，.35→1→.35，錯開 .2s）、tool-running 鉛筆（1.4s，.72↔1）、待審批紅色「!」、空閒隱藏；reduce motion 靜止 |
| Tab 切換 | 四頁保持掛載，切到 DSH tab 後 Bot 魚仍每幀渲染 | Bot tab 頁套 `.environment(\.botFishPaused, selectedTab != .bot)`；渲染器契約為 `EnvironmentValues.botFishPaused`（fish-renderer 單元提供），true 時停幀並保留最後一幀 |

`spec/ui/v1/pages/bot-chat.md` 已同步頭部活動小圖標與輸入膠囊三態/幾何；`bot-info.md` 不受影響。DSH 頁外觀、行為與 id 不變。

Protocol impact: P09; P27: none — 只改 Bot 頁 UI 呈現與共享環境值，未改 BotRows、UserAction、投影、事件或 wire。

### r2 驗收（容器內如實記錄）

- `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（5 files、13 contrast pairs、6 deferred AA pairs、1 unmeasured token、0 failures；132 個 file:line provenance anchor 全部解析）。
- `bash scripts/ci/check.sh --only phone-spec` → PASS。
- `CI_PROTOCOL_BASE=d2d56f64dbaef802c67b6ea7be35aa1bb4c6a62d bash scripts/ci/check.sh --only phone-cross-tree` → PASS（8/8 invariants、registry byte-identical、89 schemas 0 breaking finding）。
- `bash scripts/ci/check.sh --only phone-p0-conformance` → FAIL：page-structure 的 12 個 divergence 均為 baseline 既有（在 `d2d56f64d` 乾淨 worktree 以同一 `--baseline spec/ui/v1/pages/_baseline.json` 命令重現同樣 12 個）；本次改動的 chat/runtime-details/egress 等頁面沒有新增 stale line 或 divergence。其餘 37+115 個 checker tests 全 PASS。
- `git diff --check` → PASS。
- `xcodebuild`、`swift test`、`bot-ui` 截圖與模擬器手測 → NOT_RUN（容器無 Xcode/Swift/iOS SDK；由調用方本機執行）。
