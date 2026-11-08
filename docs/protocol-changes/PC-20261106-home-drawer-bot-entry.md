<!-- SPDX-License-Identifier: MIT -->

# HomeDrawer 的 Bot 入口（P09 頁面契約修訂）

```yaml
change: PC-20261106-home-drawer-bot-entry
contracts: [P09, P16, P27]
status: implemented
base: f5e47b2bcc3bc4ae5ca9db598e1cbea09faf5581
contract_revision: PC-20261106-home-drawer-bot-entry@1
version_decision: 复用 pdsh.ui.page-structure/1 與 HomeDrawer 既有頁面契約；不新增 schema 欄位或版本，同 App bundle 配對升級。
```

Protocol impact: P09; P16; P27。

## 1. 觸發與現狀

- `HomeDrawer.swift` 在「新会话／定时任务」之間新增 Bot 入口（`fish` 圖標、detail 只讀
  `chat.botRuntimeState`），並以 `showBot` sheet 呈現 `BotProductionPage`。入口在 runtime
  `idle/preparing/connecting/ready/recovering/failed/stopped` 時都顯示；不可用時由頁面自己顯示
  錯誤與「重试」，不因 Host 未啟動而隱藏入口。
- `spec/ui/v1/pages/home-drawer.json` 是手工登記（`handRegistered`）的 HomeDrawer 契約：
  HomeDrawer 不是 `*Page` struct，`extract_ios_pages.py` 不生成它。本次只把 `source.lines` 與
  受影響 control 的 `provenance` 重新釘到新行號；schema `pdsh.ui.page-structure/1`、
  `sections`、`android` 鏡像對象都不變。
- 生产 Bot 页面不讀 fixture：`BotProductionHub.connect` 在 runtime 缺失時只設置錯誤並提供
  「重试」；fixture 只在 `#if DEBUG` preview 與 `scripts/ci/bot-ui` capture target 可達。

## 2. 契約凍結（current → expected）

| 項 | current | expected |
| --- | --- | --- |
| HomeDrawer 入口 | 新会话 / 定时任务 / 文件夹 / 设置 | 在「新会话」後新增 Bot；不刪改既有入口 |
| Bot 呈現 | 無 | `showBot` sheet → `BotProductionPage`；detail 只鏡像 runtime 狀態，不作為可用性條件 |
| 契約 provenance | 舊 `HomeDrawer.swift` 行號 | 重新釘到新行號；anchor 文字不變 |
| 頁面結構 schema | `pdsh.ui.page-structure/1` | 不變 |
| fixture 可達性 | 生產頁曾可能有 fixture 回退 | 生產頁 only 錯誤＋重试；fixture 限 `#if DEBUG`／capture |

## 3. 兼容性

| 場景 | 結論 |
| --- | --- |
| 舊 App bundle → 新 bundle | 無 wire/持久/環境變量變更；入口只是本機 UI，舊 Bot 資料照常讀取。 |
| 新 App → 舊 Android/Harmony 端 | 本修訂沒有 Android/Harmony Bot 入口。`home-drawer.json` 的可比較 action 集合不新增條目，Android 頁面結構 ratchet 不新增 divergence 行，也不以 allowlist 放行任何新差異（P09 lane F 的 Android Bot 入口是後續獨立契約）。 |
| 回滾 | 刪除 Bot 入口只影響抽屜；Bot 的 durable event、MCP listener 與 Host 資料不變。 |
| 頁面契約檢查 | `page_structure_check.py --baseline` 與 `ui_check.py` 的既有輸出不因該入口改變；provenance 行存在性由 checker 驗證。 |

沒有新增 wire frame、JSON-RPC method、環境變量、BotEvent 類型或 schema 版本。

## 4. 驗收

- `python3 spec/ui/v1/tools/page_structure_check.py --root . --page home-drawer`
- `python3 spec/ui/v1/tools/ui_check.py --root .`
- `bash scripts/ci/check.sh --only phone-p0-conformance,phone-cross-tree`
- 模擬器 UI capture／App 構建由主會話執行；本切片只做靜態契約與單元檢查，不宣稱已跑模擬器。
