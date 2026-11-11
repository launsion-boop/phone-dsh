<!-- SPDX-License-Identifier: MIT -->

# BotDock / 四入口底部导航（superseded proposal）

> **Status: superseded proposal (2026-11-12, CCR-4 option b). Do not implement this file.**
> The target is the shipped four equal columns in `examples/probe-app/PhoneDSHProbe/HomeTabBar.swift`:
> Bot / DSH / 发现 / 我的, each an equal-width column. There is no standalone 64pt Chat circle and no
> three-item floating capsule; the Chat/Personal Agent surface is the Bot tab. This file is retained
> only as the rejected alternative so the two designs are not mistaken for two authorities. The Bot
> tab's page, row and accessibility contract stays in [bot-chat.md](bot-chat.md) §1/§6.
> Everything below records the rejected proposal and is non-normative.

契约：P09（历史）。原提案实现路径：`examples/probe-app/PhoneDSHProbe/BotDock/**`。图标视觉仅以用户指定的 参考仓库 main `2c18fd848bffaeef88feae237cc4b88457f9fb57` 为参考：`MainTabs.swift`、`Primitives/Quiet.swift` 的 `LineIcon`、`Resources/Assets.xcassets/Icons/ic-tab-*.svg`，以及该提交 `ServiceCatalogFallback` 由填充图标改为线性图标的风格。颜色、字号和语义仍只使用 phoneDSH `tokens.json`，不引入 参考仓库 品牌、色板或依赖，也不搬入三环日记、引导或其他页面。

## 1. 结构与几何

- 顺序固定为 Chat（Personal Agent）、DSH、发现、个人。Chat 是最左侧独立主入口，另外三项位于同一浮动胶囊；不改变现有 DSH 高级工作台或四入口行为。
- 常规屏左右外边距 16，主入口与胶囊间距 10，胶囊最小高度 60；底部间距使用 safe area。窄屏优先压缩胶囊内可用宽，不能裁切图标或将命中区降到 44pt 以下。
- Chat 使用 64×64 独立圆形主入口和 24pt 线性图标，不显示文字标签但必须有 VoiceOver label；选中时使用 `primaryButton` / `primaryButtonInk`，未选中时使用 `surface` / `textPrimary`。另外三项使用 22pt 图标、`tabLabel` 标签，选中为 `textPrimary` + semibold，未选中为 `textTertiary` + regular。
- 胶囊使用系统材质和 `sessionBorderL2` 发丝描边；iOS 版本不支持新材质时使用系统 material + `surface` 的兼容呈现。不能增加发光、渐变、重投影或第二套色值。

## 2. 图标契约

- 四个图标在同一 24×24 网格中用 SwiftUI 矢量路径绘制，基准 stroke 1.75、round cap/join；Chat 显示 24，其余显示 22。不得混用不同视觉重量的 SF Symbol、emoji、位图缩放或品牌图标。
- Chat：与该版本 `ic-tab-chat` 一致的简洁圆角对话气泡，不自行添加填充、三个点或多余装饰；DSH：圆角终端框、`>` 和 `_`；发现：与该版本 `ic-tab-services` 一致的四个等大圆角方格；个人：圆形头部和肩部轮廓。路径只描述通用功能，不使用 参考仓库 的品牌标志。
- 图标本体可小于 44，但按钮命中区域至少 44×44。按下有轻微、同角色的背景/透明度反馈；选中不只靠颜色，还由字重、主入口反色和 accessibility selected trait 区分。

## 3. 行为与可访问性

- 每项都有明确 VoiceOver label 和 selected trait，支持键盘/控制器 focus（平台可用时）、正常/按下/禁用状态。标签不做动态翻译 key 拼接，沿用 App 当前语言，不在切换语言时重启 runtime。
- 切换只改变选中页面，隐藏页面不可点击且从 accessibility 树移除；页面状态保留。深度链接到 Bot 时仍选择 Chat。
- 使用短促、非弹簧选中过渡；开启 Reduce Motion 时取消位移/缩放动画。动态字体下标签可读、不截断，必要时增加胶囊高度而不是缩小命中区。

## 4. 验收

- 正式 App target 编译和 `phone-xcode-resolve,phone-p0-conformance` 通过。
- 在模拟器验证四入口切换、Chat 深链选中、页面状态保留和至少 44pt 命中区。
- 浅色/深色各提交 Chat、DSH、发现、个人选中态截图，另覆盖窄屏、动态字体和 Reduce Motion。组件预览不能冒充最终 RootView 集成证据；最终接入后重新截图。
