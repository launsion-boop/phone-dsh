# Android 對齊 iOS 路線圖

狀態日期：2026-11-12。iOS 是基線，Android 照 spec 實作；兩端都原生，共用的是規範、golden 和驗收。
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

## 能力差距（2026-11-12）

| 能力 | Android | 規範是否足以移植 |
| --- | --- | --- |
| Bot runtime 及其上層（多 Bot、Team、SendToAgent、persona、MCP 保活、大肥魚） | 無 | 不夠：bot/v1 只有 schema 和 golden，bot/v2 仍是 target |
| PCLink | 無（GAP-35） | 線上協議完整；spec 仍寫著「Android out of scope」 |
| TonoLink 語音、UI-Venus | 無 | 有 spec，但寫明 Android 沒有接收端 |
| BLE 信任/重連/安全會話、設備任務、LAN MCP 連接 | 部分（只有 codec） | 有 spec（GAP-20） |
| 3D/HTML 預覽 | 依單 WebView 不變式顯示「不支援」卡片 | 要先改不變式，並通過安全評審 |
| Tono 帳號、ADB、SSH | 已有 | — |
