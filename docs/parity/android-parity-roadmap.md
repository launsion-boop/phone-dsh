# Android 對齊 iOS 路線圖

狀態日期：2026-11-12（wave 4 round 2 後更新）。iOS 是基線，Android 照 spec 實作；兩端都原生，共用的是規範、golden 和驗收。
規則見 [AGENTS.md](../../AGENTS.md)：先凍結契約，再實作；每個檢查點都要附交接證據。
執行者每次開工前，先讀 [lessons.md](lessons.md)。

## 架構決定

- 兩端各寫原生程式碼，不用 KMP 共享 UI，也不做服務端驅動 UI。
- Bot runtime、PCLink 都用 Kotlin 移植，靠 spec 和 golden 保證兩端行為一致。
  不在 iOS 上引入 KMP：Bot runtime 共約 1.6 MB Swift（runtime 約 986 KB，App 端 Bot UI 約 605 KB），改成 KMP 會讓 iOS 大改。
- 交互參數寫進 `spec/ui/v1/tokens.json#interaction.*` 和 [interaction.md](../../spec/ui/v1/interaction.md)，
  每個值都附 iOS 源碼出處，由 `ui_check.py` 檢查。不遷移到 DTCG 格式，也不引入 Style Dictionary。
- 不引入 compose-cupertino、Haze、Maestro 這類第三方 UI 依賴，元件自己寫。
- 跨端門禁比的是元素幾何，不比像素。

## 波次

| 波次 | 內容 | 依賴 |
| --- | --- | --- |
| 0 | 會話抽屜交互契約與 Android 實作（PR #114） | 已完成，待 review 和真機驗收 |
| 1 | 契約起草：UI 交互批次（sheet、長按選單、push/返回、按壓、折疊、發送鍵）、PCLink 納入 Android、Bot 移植規劃、設備能力移植規劃；驗收台；修門禁；ChatMetrics 常量歸類 | 無 |
| 2 | UI 元件實作（每個元件一個 worker）；PCLink Kotlin 模組（線上協議 → 配對 → workspace）；BLE 信任/重連（GAP-20） | 第 1 波的契約凍結 |
| 3 | 頁面遷移（非 Bot 頁）；PC 工作區頁面（GAP-35）；TonoLink 語音；ChatMetrics 收斂 | 第 2 波 |
| 4 | Bot runtime（memory → routines/wake → proactive → MCP → team）；Bot tab、大肥魚；UI-Venus | Bot spec 補齊後凍結 |
| 5 | 3D/HTML 預覽（獨立進程 + 安全評審）；HarmonyOS 跟進 | 安全評審 |
| 常駐 | 防回退：iOS UI PR 必須附 Android 實作或 GAP 條目；驗收台每晚在 main 上跑 | 驗收台 |

## 第 3 波進度（2026-11-12）

驗收分支 `feat/android-parity-w3`，base `cb5401ae`。第 1 回合的頁面採用已合入；
第 2 回合的七個 worker 正在平行進行。

### 第 1 回合：完成（頁面採用）

| 項目 | 合入 |
| --- | --- |
| PCLink C4：workspace/1 RPC、DSH transport、roster cache、presence | `883b3e81` |
| Shell 返回鏈與 per-tab push 狀態（`BackCoordinator`） | `10458c91` |
| Composer：`PdshComposerSendKeys`、統計 sheet、empty geometry | `ec0f4342` |
| Chat rows：shared context menu、pressed、disclosure | `6596d0c5` |
| Drawer：`PdshFolderGroup`、menu、pressed | `23a408d8` |
| Sessions / Subagent catalog：menu、sheet、chevron | `66fe2601` |
| Settings：root row geometry、chrome、disclosure | `e0fd4b64` |
| Page sheets / host-address menu | `2cdb9853` |
| Page chrome：shared pressed 與 disclosure | `8fc77192` |
| Changed-files card：iOS row order 與 180° toggle chevron | `605bf417`（merge `cb5401ae`） |

### 第 2 回合：完成（已併入 `feat/android-parity`，#129／#134）

Per-tab nav、sheet host seam + sheet routes、turn usage、bench host、PCLink C5（GAP-35 收尾）、
settings geometry contract（62 pt row / 57 pt group gap）、dead press constants / legacy session
params / disclosure pressed seam / docs 全部落地；第 3 波最終以 `0a748a8f` 併入
`feat/android-parity`，並隨 PR #129、#134 合入。

## 第 4 波進度（2026-11-13）

base `2153df10`，整合分支 `feat/android-bot-w4`（PR #137，base `feat/android-parity`）。

| 回合 | 內容 | 狀態 |
| --- | --- | --- |
| R1 | 契約凍結（store、session/projection、UI-state seam、BotFish 數值軌跡）＋ `:bot` 模組（rows、user action、card payload、display projection、attachments、profile/roster、fish director）＋五條 CCR 裁決＋素材授權擴到全平台 | 完成（`bd87bd24`，PR #137） |
| R2 | Kotlin store（sqlite vectors）、session runtime／projection（K2b §6.2）、UI 狀態接縫、BotFish 渲染完整移植（K4b）、Bot 聊天頁／model／driver／Bot tab（K5a）、抽屜／資訊頁／外觀（K5b）、`:lib` 頁面接線（K5c） | 完成（`a81d751b`，PR #137） |
| R3 | Kotlin runtime：memory（B2）、routines/wake/held inbox（B3）、proactive（B4）、MCP handler/cards/volatile（B5a1）、authz/gateway（B5a2）、`:net` MCP listener/SSE＋P08 Notifier／P16 WorkerEnvironment（B5b）；契約：D13 MCP（C6）、proactive（C7）、D12 team/tasks（C8）；`:app:assembleDebug` 以 pinned DSH bundle 產出 APK | 部分完成（B2–B5、C6/C7、L1、K6 已併入；K6 交付 `:app` driver/runtime/listener 接線、app tests 453/0、assembleDebug 89 MB APK；instrumented `BotStoreAndroidVectorTest` 於 API 37.2 arm64 emulator PASS（3 tests）；C8 進行中） |

尚未移植的 wave 4 範圍：

- B6 team／SendToAgent／CreateTeammate／durable tasks（D12 契約由 C8 凍結中；B7a agent-comm row model 為前置）。
- watchdog／context lint／ledger（S6/S14 仍 `spec-partial`，未開）。
- UI-Venus；真機 UI 驗證（Bot tab 實機路徑，GAP-38 關閉條件；emulator 上的 instrumented 已 PASS）。
- B4 的 proactive 已由 C7 凍結契約並完成 Kotlin；B5 的 MCP/authz/gateway 已全部落地。

## 能力差距（2026-11-13，wave 4 R3 後）

| 能力 | Android | 規範是否足以移植 |
| --- | --- | --- |
| Bot runtime 及其上層 | **大部分**：store/session/projection/rows/cards/attachments/profile/fish、Bot 聊天頁／抽屜／資訊頁／Bot tab／BotFish 渲染、memory（B2）、routines/wake（B3）、proactive（B4）、MCP/cards/volatile（B5a1）、authz/gateway（B5a2）、`:net` listener/SSE＋P08/P16 seams（B5b）；`:app` 接線（K6）與 ledger（L1）已完成；team、watchdog/context lint 未完成；真機 UI 未驗 | D13（MCP）與 proactive（D12 除外）已凍結；team/tasks 由 C8 凍結中；watchdog/ledger 仍 partial |
| PCLink | **C0–C5 已落地**（PR #122、#129、#134；GAP-35 關閉） | 線上協議完整 |
| TonoLink 語音 | 只有 JVM codec／cloud voice client（`0bc7233c`，2B.1/2B.2）；App/UI 接線未做 | 有 spec；接收端未接 |
| UI-Venus | 無 | 有 spec，但 Android 沒有接收端 |
| BLE 信任/重連/安全會話、設備任務、LAN MCP 連接 | 部分（只有 scan/GATT codec）；secure-session 契約 `target`、未啟用 | 有 spec（GAP-20） |
| 3D/HTML 預覽 | 依單 WebView 不變式顯示「不支援」卡片 | 要先改不變式，並通過安全審評 |
| Tono 帳號、ADB、SSH | 已有 | — |
