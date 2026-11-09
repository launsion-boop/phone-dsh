# 協議變更單

## 0. 摘要（機器可讀，保持這個格式）

```yaml
change: PC-20261109-dsh-drawer-bot-filter
contracts: [P09]
status: implemented
breaking: false
version_decision: not applicable (display-only UI contract; no wire field or persisted format changes)
base: ff79c6aa13e271cb0f71d12890a40f881699a6ce
contract_revision: spec/ui/v1/pages/home-drawer.json (working tree; contract owner lead reviews at integration)
```

## 1. 識別與角色

- Trigger → 現況 → 期望：
  - `session/list` / `workspace/follow` 把 Bot 的 `gb-` 會話與 Bot 私有目錄回給 DSH 頁 → 抽屜的合成「日常」、資料夾、封存、`@` 會話候選、定時任務/活動標題都可能列出 Bot 資料 → DSH 頁只列使用者自己的 DSH 會話；Bot 私有工作區資料夾不顯示。
  - Worker 預設資料夾 title 是 `default-workspace`（真機顯示原名） → 使用者只看到「日常」或原始英文 → 手機顯示「手机工作区」，英文介面顯示「Phone Workspace」；合成「日常」併入同一組，序號沿用「手机工作区 2」。
  - 抽屜「新会话」是 44pt 普通列 → 使用者要求的整寬白色膠囊主按鈕沒有呈現 → 改為 52pt 全寬膠囊，圖示 `plus.bubble` + 17 medium 文字，置中；不可用時整顆置灰，原因以 13pt 次要色放在下方。
  - 抽屜仍有「定時任務」入口，與「我的」頁重複 → 使用者要求移除 → 抽屜刪除入口與只服務它的 sheet；設定頁入口保留，聊天頁依會話的「定時任務（N）」保留。
- 角色：caller owner；lead coordinator/contract owner；`dsh-filter` implementer；`bot-root` owns the frozen `BotSessionRegistry` implementation；reviewer-integrator = lead/caller。
- Owning contract：`spec/ui/v1/pages/home-drawer.json`、`spec/ui/v1/README.md`；Android 對應 `HomeDrawer.kt`、`SessionsPage.kt`、`UiStrings.kt`。
- 受影響 producer/consumer：iOS `DSHManagementModel` 讀 host 的 session/workspace catalog（P09 顯示層）；iOS `HomeDrawer`/`SessionsPage`/`ChatPage`/`NativeAutomationPage` 消費同一份已過濾 model；Android `HomeDrawer`/`SessionsPage` 讀自己的 host facts。P14/P15 Worker URL、參數與 wire 不變。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| Bot session 的可見性 | DSH 的所有 session 列表來源改為 `DSHManagementModel.sessions` 的單一讀取點；任何 `gb-` 前綴或 `BotSessionRegistry.shared.isBotSession(id)` 為真的 id 一律丟棄。`BotSessionRegistry` 是 bot-root 的凍結 App 單例，dsh-filter 只讀。 |
| Bot 工作區資料夾 | `workspace/follow` baseline / upsert 以 `BotSessionRegistry.shared.isBotWorkspacePath(path)` 過濾；workspace 的 `sessionIds` 同時剔除 Bot id。使用者真實建立但為空的資料夾不受影響。 |
| 合成「日常」 | 不再生成獨立「日常」組；主機 `defaultWorkspaceId`（若提供）為第一判定，否則 `DrawerTitles.isDefaultWorkspace` 接受 `workspace`、`工作区`、`工作文件夹`、`default`、`default-workspace`。未分組會話併入該預設資料夾；沒有預設資料夾時仍以同一顯示名成為臨時組。使用者手動改名的預設資料夾保留其名稱。 |
| 預設資料夾顯示名 | `default-workspace` 顯示「手机工作区」/「Phone Workspace」；第二個及以後顯示「手机工作区 N」/「Phone Workspace N」。漏空或只有路徑時仍走既有 `lastSegmentName`。只是顯示名，不改 Worker `workspace.json` title。 |
| 新會話入口 | iOS：整寬 52pt 白色膠囊，`HomeSpec.surface`、`borderList` 0.5pt、圓角 26、左右 16、`plus.bubble` 20 + 17 medium、間距 10；按下輕微變暗。Android：相同結構，`PdshIcon.NEW_CHAT_PLUS`（新增 plus-bubble 向量）。不可用時兩端都置灰禁用，原因顯示在膠囊下方置中。`HomeDrawerTags.NEW_SESSION` / accessibility label 保留。 |
| 抽屜定時任務 | 刪除 iOS `entriesCard` 定時任務列與 `showSchedules` sheet；刪除 Android 定時任務列與 `HomeDrawerTags.SCHEDULES`，`onOpenSchedules`/`scheduleCount` 從抽屜 facts 移除。設定頁「定時任務」與聊天頁按會話的入口不變。 |
| Android 同步 | `UiStrings.DRAWER_DEFAULT_FOLDER(_INDEXED)` 改為「手机工作区」並新增英文常數；`workspaceTitle`、`SessionsScreenState.from`、`HomeDrawer` 顯示同規則；`SessionWorkspace.isDefault`（可選，舊 host 省略）讓主機宣告的預設資料夾併入未分組會話；缺少時仍以 `workspace` / `default-workspace` title 判定。Android 無 Bot runtime/`BotSessionRegistry`（此基線沒有 Bot producer），因此不新增第二套 gb 過濾實作。 |
| 未知欄位 | `workspace/follow` 的 `defaultWorkspaceId` 是選擇性讀取；缺少時完全回退到既有 title 規則，舊 Worker 不需改動。 |
| 錯誤／重試／持久化 | 不涉及 wire error、cursor、retry 或持久化格式；過濾是顯示層，Bot 資料庫與 DSH 會話 cwd 不變。 |

自檢：沒有新增第二種 session 表達；沒有改 P14/P15 參數、URL 或 Worker VFS 路徑；沒有放寬任何 UI gate 或刪除斷言；Android 不是把 iOS 的 Bot 過濾硬編碼成第二份實作（該平台此基線沒有 Bot producer）。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old Worker → new iOS | `defaultWorkspaceId` 缺省，title `default-workspace` 已在新名單；`gb-` 前綴不依賴 Worker 新欄位。 |
| new Worker → old iOS | 舊 App 不認識 `defaultWorkspaceId` 時照舊顯示，wire 無新增必填欄位；本單不改 Worker。 |
| new iOS → new iOS | Bot 會話在 model 讀取點就被丟棄，所有 DSH 頁共用。 |
| persisted old data → new / rollback | 顯示層無遷移；Bot→DSH 會話重建屬 `bot-root` 單元，不在本單。 |

- `workspace/follow` 若未來正式加入 `defaultWorkspaceId`，本單已把它當 optional unknown 讀取；不需版本 bump。
- Android 與 iOS 的資料來源不同：Android 此基線沒有 Bot 會話，故只同步顯示名、預設組併入、膠囊按鈕與移除定時任務入口。

## 4. 分工與證據

- `dsh-filter` 獨占：`examples/probe-app/PhoneDSHProbe/{DSHManagementModel,HomeDrawer,SessionsPage,ChatPage}.swift`、`android/lib/src/main/kotlin/com/phonedsh/ui/**`、`android/lib/src/test/**`、`spec/ui/v1/**`、本 PC。
- 必需的最小 app 接線：`android/app/.../HostShell.kt` 移除已刪除的抽屜排程 callback/fact，並把 `preferences.language?.id` 傳入 `HomeDrawerFacts.languageId`；不改 app 的會話/排程資料。
- 導航校驗：`android/tools/verify-nav-entries.sh` 的定時任務入口由抽屜改為「設定 › 定時任務」，與 HomeDrawer 的刪除同步。
- `bot-root` 獨占 `examples/probe-app/PhoneDSHProbe/BotSessionRegistry.swift`；本單不建立、不複製該類型。凍結介面見 `contract-bot-session-registry.md` revision 1。
- 共享 fixtures：無新 wire fixture；UI gate 為 `spec/ui/v1/pages/home-drawer.json`、`sessions.json`、Android structure/page checks。
- Exact commands → 結果：
  - `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（本工作樹）
  - `python3 spec/ui/v1/tools/page_structure_check.py --root . --page sessions` → PASS（0 divergence）
  - `python3 spec/ui/v1/tools/page_structure_check.py --root . --page home-drawer` → FAIL（僅既有 Android `设置` extra-action；該差異在本 diff 前已存在，未用 baseline 放寬）
  - `python3 spec/ui/v1/tools/page_structure_check.py --root .` → FAIL（工具報既有 stale `chat` / `runtime-details` 契約與其他 baseline 外 divergence；`sessions` 本頁 0）
  - `bash scripts/ci/check.sh --only phone-spec` → PASS
  - `bash scripts/ci/check.sh --only phone-android-structure` → FAIL（既有 `readme-map: unregistered Sources modules: PhoneDSHBot`；與本 diff 無關，未在本單修改）
  - `bash scripts/ci/check.sh --only phone-cross-tree` → FAIL（8/8 invariants 與 registry PASS；schema diff 因 `git ... Needed a single revision` 無法解析 comparison base，環境問題）
  - `git diff --check` → PASS
  - `xcodebuild` / `swift test --filter PhoneDSHBotTests` / XCUITest bot-ui light+dark 截圖 → NOT_RUN（容器無 Xcode/模擬器；由 caller 本機執行）
- 剩餘風險：
  - Bot 私有資料夾的最終路徑由 `bot-root` 決定；本單只透過 `isBotWorkspacePath` 判定，未硬編碼。
  - iOS 需最終裝配提供 `BotSessionRegistry.swift`；若缺檔會編譯失敗，這是 lead 的合併檢查項。
  - Android 的 Bot 過濾在無 Bot runtime 的基線不可端到端驗證；不得把本次 iOS 過濾結果當成 Android 已驗證。
  - `page_structure_check` 的既有 `home-drawer` `设置` extra-action 與 `phone-android-structure` 的 `readme-map` 失敗需由對應 owner 追蹤。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | dsh-filter | 實作第 4 輪目標 1、3、4、5、6；消費 lead 凍結的 BotSessionRegistry v1 | lead / caller / bot-root |
