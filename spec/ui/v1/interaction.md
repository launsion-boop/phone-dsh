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
