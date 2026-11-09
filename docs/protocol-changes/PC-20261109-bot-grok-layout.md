<!-- SPDX-License-Identifier: MIT -->

# Bot 页 Grok 式改版（P09 页面契约修訂）

```yaml
change: PC-20261109-bot-grok-layout
contracts: [P09, P26, P27]
status: implemented
base: 832f34dcf1e63897e4736a477500815ef7bc582a
contract_revision: PC-20261109-bot-grok-layout@3
version_decision: 复用 pdsh.ui.page-structure/1、P26 Bot 资料、P27 BotRows/UserAction/tokens；r3 只消费 P26/P27 的新增字段与本地资料文件，不新增 wire frame、事件或 schema 版本，同 App bundle 配對升級。
```

Protocol impact: P09; P26; P27。r1/r2 只改 Bot 頁呈現；r3 在 P09 頁面接入 P26 資料（`agents-index.json`/`runtime-settings.json`）與 P27 的 `attachments` 欄位，schema/golden/存儲格式由 profile/attachments 單元擁有，本單元只消費。

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

### r2 驗收（容器內如实記錄）

- `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（5 files、13 contrast pairs、6 deferred AA pairs、1 unmeasured token、0 failures；132 個 file:line provenance anchor 全部解析）。
- `bash scripts/ci/check.sh --only phone-spec` → PASS。
- `CI_PROTOCOL_BASE=d2d56f64dbaef802c67b6ea7be35aa1bb4c6a62d bash scripts/ci/check.sh --only phone-cross-tree` → PASS（8/8 invariants、registry byte-identical、89 schemas 0 breaking finding）。
- `bash scripts/ci/check.sh --only phone-p0-conformance` → FAIL：page-structure 的 12 個 divergence 均為 baseline 既有（在 `d2d56f64d` 乾淨 worktree 以同一 `--baseline spec/ui/v1/pages/_baseline.json` 命令重現同樣 12 個）；本次改動的 chat/runtime-details/egress 等頁面沒有新增 stale line 或 divergence。其餘 37+115 個 checker tests 全 PASS。
- `git diff --check` → PASS。
- `xcodebuild`、`swift test`、`bot-ui` 截圖與模擬器手測 → NOT_RUN（容器無 Xcode/Swift/iOS SDK；由調用方本機執行）。

## 6. 第 3 轮：Bot 资料外观与 composer 附件（r3，base `b0d246c21621462e804cc087e93d85e0a12267d4`）

r3 在 r2 的 Grok 式 Bot 页上接入两项新契约（P26 Bot 资料、P27 user-action 附件）并修复渲染器编译错误。DSH 页（`chat` 页面）、`HeaderActionPill` 外观与既有 id 均不变。

| 项 | r2 现状 | r3 期望 |
| --- | --- | --- |
| Bot 资料 | 名字来自 runtime-context 的最后一次 `renamed` 事件，无持久资料 | 启动时 `BotProfileStore(directory: Application Support/PhoneDSHBot)` 的 `bootstrapMainIfNeeded(legacyName:)` 建立 `main`（显式 blue/long）；名字以资料为准；改名同时写 `renamed` 系统事件与资料 `upsert`；资料写入失败不阻止改名事件 |
| 头像外观 | 所有 `BotFishView` 固定 classic 蓝/长发 | `BotChatModel`/`BotInfoModel` 暴露 `appearance: BotFishAppearance`；头部胶囊、空状态、状态行、信息页预览与 4 个发型缩略图全部传入当前资料外观；旧调用点因 `.classic` 默认值继续编译 |
| 信息页外观区 | 仅 80pt 静态头像 + 名字编辑器 | 名称下方新增「外观」区：112pt 实时预览（可 poke）、4 个 40pt 发型缩略图（当前颜色、选中 44pt 外圈）、15 个 24pt 色点（44pt 点击区、自动换行、选中外圈）；点选即 `upsert` 并全页生效；不暴露「自动」 |
| composer | 左侧 16 内距、无「+」，右侧单按钮 | 左/右 8；左侧 36pt「+」（id `bot.composer.attach`）菜单「照片 / 文件」；中间输入框；右侧 36pt 三态按钮；单行三者居中，多行「+」与按钮贴底 8pt |
| 附件 | 无 composer 附件 | 胶囊上方横向 chip（图标 + 名 + 大小/类型 + ×，id `bot.composer.attachment.<index>`）；最多 10 个、单个 ≤ 25 MiB，超限提示且不加入；有附件可无文字发送，运行中同样可带附件；发送前经 `BotAttachmentImporting.importFiles(botID:messageID:files:)` 写入该 Bot 的 DSH 工作区，失败逐个提示「附件「名」未附加：原因」 |
| 用户行 | 纯文本气泡 | 正文下方显示附件卡片（名字、大小、类型）；无文字但有附件时该行仍渲染 |
| fixtures | 无 | 新增 `composerAttachments`（3 个 chip + 1 个超限提示 + 用户行两张附件卡片）与 `infoAppearance`（紫/双马尾信息页） |

### 6.1 附件导入路径（app 层实现，P27 消费端）

`BotWorkspaceAttachmentImporter` 实现冻结的 `BotAttachmentImporting`，通过注入的 `BotChatModel.attachmentImporter` 使用；session id 来自 `BotDSHRemoteRuntime.ensureMainSessionID()`，写入走 `PhoneDSHWorkspaceImportSink`（`phone/importBegin/Write/Commit`，与 DSH 页 verbatim 文件同一路径）。

实际落盘：`/dsh/workspace/imports/attachments-<messageID>/<safeName>`（`targetDirectory = /dsh/workspace`，`entryName = attachments-<messageID>`），`BotAttachment.path` 取 commit 的 `absolutePath + "/" + safeName`，是模型文件工具可读的绝对 VFS 路径。**偏离计划中的 `attachments/<messageID>/<safeName>`**：Worker directory-import 契约固定写入 `<targetDirectory>/imports/<entryName>/...`，且 `entryName` 只能是一个 path segment；现有 sink 无法生成 `attachments/<messageID>`。没有采用「库层直接写 native workspace root」：native root 只是 materialized 副本，权威在 Worker VFS/WAL，写那里模型读不到。消息删除/会话清理不在本轮 UI 负责。

### 6.2 兼容性

| 场景 | 结论 |
| --- | --- |
| 旧 App bundle → 新 bundle | 无索引时创建 `main`（名字取最后一次 renamed，缺省「大肥鱼」；显式 blue/long），现有鱼外观不变；旧 durable rows 原样显示。 |
| 新 App → 旧 Android/Harmony | iOS 专有页面与本地资料文件；Android/Harmony 没有 Bot 页，无共同页面契约。 |
| P27 UserAction | 消费 `attachments` 可选字段；无附件时编码与旧版一致（字段省略），旧端读新端消息行为不变。 |
| 回滚 | 删除本轮只影响 Bot 页外观/附件呈现；`agents-index.json`/`runtime-settings.json` 中未知字段保留，回滚不丢数据；durable rows、MCP、Host 不受影响。 |

### 6.3 验收（容器内如实记录）

- `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（5 files、13 contrast pairs、6 deferred AA pairs、1 unmeasured token、0 failures）。
- `CI_PROTOCOL_BASE=b0d246c21621462e804cc087e93d85e0a12267d4 bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-spec PASS、phone-cross-tree PASS：8/8 invariants、registry byte-identical、89 schemas 0 breaking finding）。
- `git diff --check` → PASS。
- `xcodebuild`、`swift test --filter PhoneDSHBotTests`、`bash scripts/ci/bot-ui/capture.sh --appearance light,dark`、模拟器手测（改色/发型即时生效且重启保留、选照片/文件生成 chip、发送后用户行附件卡片）→ NOT_RUN（容器无 Xcode/Swift/iOS SDK）。
