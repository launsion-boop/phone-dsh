# Axis 09 — 设计 Token / 排版 / 像素测量

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只做 **跨组件的 token、排版、尺寸、颜色与像素测量**，为其他轴提供统一标尺；不要重复完整的组件行为清单。

报告路径：`docs/receipts/ios-session-audit/09-tokens-pixels.md`

## 目标

用户要“近乎像素级”。请把官方手机宽度（402pt）下 session 页使用的设计 token 解析成静态值，建立 **官方 → iOS** 的映射表，找出系统性偏差，并给出可执行的 token 层改造方案。能实测截图的地方尽量实测。

## 必须覆盖

### A. 官方 token 解析

从 `packages/client/ui-theme/src/styles/design-platform.css`、`base.css`、`corner-shape.css`、`focus.css` 以及 session 相关 CSS module 中，解析并列表：

1. **颜色**（light + dark）
   - `--dsw-alias-bg-base`、`bg-layer-*`、`label-primary/secondary/tertiary/caption`、`border-l1..l4`、`specific-bubble`、`specific-input-major`、`specific-menu`、`interactive-bg-hover*`、`state-business-primary`、`danger/warning/success`、`label-deep-diving*`、scrollbar
   - 每个给出：变量名、解析后的 rgb/alpha、使用场景
   - 注意 `color-mix`、`light-dark()`、`.dark`/`[data-theme]` 选择器、`@media (prefers-color-scheme: dark)`
2. **字体**
   - `--dsw-font-family` 的实际栈（正文 / 代码 / brand）；中文 fallback
   - 字号/行高：正文 14/22 或 14/24 的差异出现在哪些组件；secondary 13/18 或 13/20；caption 12/18；标题 h1–h4；code 12/18 等
   - 字体权重（400/500/600/700）、tabular-nums、letter-spacing
   - `--dsh-content-font-size` / `--dsh-content-font-delta*` 的设置机制（字号偏好），手机默认
3. **间距/尺寸**
   - `--dsh-composer-side-clearance`、`--dsh-composer-card-max-width`、`--dsh-composer-dock-inset`、`--dsh-composer-stack-gap`、`--dsh-composer-text-max-height`、`--dsh-composer-height`、`--dsh-chat-content-width`、`--dsh-chat-flow-gap`
   - 402pt 下这些变量的实际值（注意 fallback 与 media query）
4. **圆角**
   - `--dsw-radius-xs/sm/md/lg/xl/panel` = 4/8/12/16/20/28
   - 哪些组件用哪个；`corner-shape`/continuous 的处理；iOS 对应 `RoundedRectangle(cornerRadius:style:)` 的差异
5. **阴影/elevation**
   - `--dsw-elevation-soft/panel/prominent`、`--dsw-elevation-stroke-color`、`--dsw-menu-backdrop-filter`
   - 实际 box-shadow/backdrop-filter 值；iOS 当前的 shadow/material 对应
6. **图标**
   - 官方 icon 组件的尺寸/线宽/颜色规则（14/16/20）；与 iOS SF Symbols/asset 的视觉差异
7. **动效**
   - `--ds-ease-in-out`、duration fast/normal/slow；shimmer/whale/折叠/滚动动画；reduced motion
8. **安全区/手机**
   - `ui-mobile/mobile.module.css` 的 safe-area、固定 composer、16px 输入、`100dvh`、overscroll 等

### B. iOS token 现状

9. `NativeChatTheme.swift` 全部颜色/字号；`ChatPage` 中散落的 magic number（颜色、字号、间距、圆角、阴影）；`NativeComposerStats`/`NativeMessageActions`/`NativeToolDetailCards`/`NativeMarkdownBody` 中的局部值。
10. 建一张 **token 映射表**：官方变量 → 官方值（light/dark）→ iOS 当前值/最接近的 token → 偏差（ΔRGB/Δpt/Δradius）→ 建议。
11. 找出 **系统性偏差**：
    - 圆角（例如 iOS 22 vs 官方 panel 28 / bubble 20）
    - 行高（iOS 24/17 行距 vs 官方 22/24）
    - 字号（iOS 14 body vs 官方 14，但 secondary/caption 是否一致）
    - 颜色（iOS 手写 hex vs 官方 token；是否偏冷/偏暖/对比度）
    - 边框/阴影（iOS 0.5 border + shadow vs 官方 elevation stroke）
    - 间距（iOS 16 页边距 vs 官方 composer clearance / chat content width）
    - 图标（SF Symbol vs 官方 SVG 的线宽/比例）
12. 评估深色模式：iOS `PhoneDSHProbeApp` 强制 `.preferredColorScheme(.light)`；官方支持 light/dark。把“是否要对齐深色”列为设计决策，给出官方 dark token 与 iOS 已有 dark 值（`NativeChatTheme` 有 dark 分支但页面被强制 light）的对照。

### C. 截图测量（尽量做，做不了就写清楚）

13. `docs/receipts/ios-baseline-screens/*.png` 是 1206×2622 @3x = 402×874pt。用 `python3` + PIL（已确认可用）做可验证的测量：
    - 页头高度、标题基线、状态点位置
    - composer 卡片左右边距/顶部位置/高度/圆角（可用像素扫描/边缘检测粗略）
    - 用户气泡的内边距/圆角/最大宽度
    - 正文行高（相邻文本行基线间距）
    - 工具行高度/图标尺寸/文字位置
    - 背景/文字/边框颜色采样（注意抗锯齿，取中心像素/众数）
14. 把 `ios-chat-official.png`（官方手机宽度）与 `ios-chat-default.png`/`ios-chat-assistant.png`（iOS 原生）在可比的元素上做并排测量；**明确区分“截图观察”与“源码事实”**。
15. 如果能在不改环境的前提下用 `examples/probe-app/Bundle/worker/web` 起静态服务并用 Playwright 截官方页，优先做；否则不要强行安装依赖。给出“未实测”的标记。

### D. 交付

16. 一张 **官方 token 全表**（变量、值、light/dark、用途）。
17. 一张 **iOS↔官方映射/偏差表**，按影响面排序（全局 token 优先，组件局部值其次）。
18. 一份 **`NativeChatTheme` 改造建议**：新增/替换哪些 token、保留哪些、如何避免一次性大改；给出建议的 Swift 常量命名与值。
19. 一份 **像素校准清单**：哪些组件需要以官方 CSS 为准重设，优先级 P0/P1/P2。
20. 明确指出“官方并非固定像素”的变量（字号偏好、宽度拖拽、Dynamic Type）以及 iOS 应如何响应。

## 参考起点

- 官方：`packages/client/ui-theme/src/styles/*`、`ui-mobile/src/client/mobile.module.css`、`ui-chat/src/client/chat/*.module.css`、`ui-conversation/src/client/skeleton/*.module.css`、`ui-tool/src/client/tool/**/*.module.css`、`ui-plan/src/client/*.module.css`、`ui-user-questions/src/client/*.module.css`、`ui-goal/src/client/GoalBar.module.css`
- 官方 primitives：`packages/client/ui-primitives/src/` 的 icon/button/typography
- iOS：`NativeChatTheme.swift`、`ChatPage.swift`、`NativeComposerStats.swift`、`NativeMessageActions.swift`、`NativeMarkdownBody.swift`、`NativeToolDetailCards.swift`、`DSHComponents.swift`、`Components.swift`
- 截图：`docs/receipts/ios-baseline-screens/`（全部 chat 相关）
- 测量脚本：可写在 `/tmp` 或报告内联，不要把临时脚本提交到仓库。

不要改源码。报告中文，证据 `file:line` + 测量命令/结果。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
