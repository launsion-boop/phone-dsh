# Axis 08 — Composer / 输入区 Dock / 会话页头

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只审 **会话页顶栏与底部输入区**（含 composer 内部控件、上方 docks、下方统计、页头按钮），不重复消息流内部（05–07）和 plan/todo 的完整状态机（02）。

报告路径：`docs/receipts/ios-session-audit/08-composer.md`

## 目标

官方手机宽度下的 conversation 页头 + composer 是一个高度定制、条件控件很多的区域。iOS 目前有自绘页头、一个 composer 卡片、权限/模型/发送、goal bar、排队条、slash/@ 菜单和统计行，但结构和细节与官方有差距。请把官方的完整组合拆出来，给出像素合同。

## 必须覆盖

### A. 页头

1. 官方 `ConversationHeader` / `ConversationSessionHeader`（`ConversationRoot.module.css`）
   - 高度、padding、border-bottom、titleRow、leading、titleCluster、headerActions、headerUtilities、headerCorner
   - 普通会话 vs 空会话（blank）vs 无 session（sessionless）的差异
   - 手机宽度（<640px）下如何收缩/隐藏；`ui-mobile` 的 mobile-menu、drawer 触发
   - 标题/面包屑（与 Axis 04 的子 Agent lineage 分工：这里写通用布局）
   - 运行状态/模型/会话操作/任务列表/agent preset/mobile menu 等 slot 的位置与顺序
2. iOS `chatHeader`（`ChatPage.swift:126-181`）
   - 44pt 高度、左抽屉 32×44、标题 17 semibold、运行状态点、更多菜单、右侧 padding
   - 与官方的结构差异：没有面包屑、没有 utilities/actions 分区、没有任务/子 Agent/预设入口、标题可点改名（官方是否可点？）
   - 官方手机宽度下页头实际保留哪些元素（从截图 + CSS 推断）

### B. Composer 卡片

3. 官方 `InputBar`（`InputBar.tsx` + `InputBar.module.css`）
   - 卡片：宽度、max-width、padding-top、gap 12、圆角 `--dsw-radius-panel`、边框/阴影、背景、dark 态
   - 文本区：min-height 36、padding 4 8 0 14、字体 14/24、placeholder、14 行上限、滚动条、自动增长、IME
   - toolbar 行：attach(+) 14、plan 控件、read-only/权限、model、activity、send/stop
   - 发送按钮：34px 圆、#3964FE、禁用态、stop 态、hover/pressed、aria
   - busy Enter：queue / steer 的切换、按钮文案、快捷键、`resolveSubmitMode`、Enter/⌘Enter
   - 附件：图片/文件 chip、缩略图、大小、移除、上传中、限制/错误 toast
   - slash 命令菜单、@ 引用菜单、command chip、reference chip、focus/键盘导航
   - 草稿持久化、失败恢复、发送中/排队中的本地提交态
   - 手机宽度：固定 seat、`--dsh-composer-height`、16px 输入字号、safe-area、键盘、overscroll
4. 官方 docks（`conversation.input.dock`）：`goal`、`queue`、`todo`
   - 顺序、间距、与 composer 的贴合（queue 的 panel 顶部圆角/底部方角）、宽度/inset、背景/阴影/边框
   - 各自展开/折叠、手机端 max-height、滚动
   - 与 iOS `goalBar` / `queuedStrip` 的结构差异（iOS 是简单 HStack + 圆角块，无折叠/编辑/发送/删除/附件）
5. 官方 `conversation.composer.dock`：`activity`、`usage`
   - 位置（composer 下方）、内容、字号、颜色、数字格式、点击展开（stats/usage 面板）
   - iOS `NativeComposerStats` 的字段/格式/顺序对照（轮/步、tok/s、context、cache、百分比）
6. 官方 `conversation.input.overlay`：`command-popup`、`slash-menu`、`feedback-dialog`
   - 触发、锚点、宽高、最大高度、滚动、键盘导航、分组、空态/加载/错误
   - iOS slashCommandMenu / referenceMenu 的对照
7. 官方 `conversation.composer`：user-questions 接管、subagent 只读 composer（与 03/04 分工，写结构差异即可）
8. 上下文压力/ContextMeter：
   - 官方何时显示、位置、颜色阈值、点击、tooltip；iOS `NativeComposerStats` 里的压力展示
9. 输入区空态/禁用/忙碌/停止中/权限等待/问题等待的状态机；iOS 当前的 disabled 条件（send/steer 等）。

### C. iOS 现状

10. `ChatPage.composer`（1134 起）、`composerControls`、`actionButton`、`stopButton`、`goalBar`、`queuedStrip`、`attachmentStrip`、`slashCommandMenu`、`referenceMenu`、`NativeComposerStats`。
11. 逐项对照：布局尺寸/圆角/阴影/颜色/字体/图标/按钮/间距/placeholder/行高/最大高度/键盘行为。
12. 页头与 composer 在 402pt 下的实际截图测量（可用 `ios-chat-official.png` / `ios-chat-default.png`；标注截图观察）。
13. 官方中文文案（`ui-conversation/src/client/locales.ts` 的 `input.*`、`placeholder.*`、`session.*`、`queue.*`、`todo.*`、`goal.*`）vs iOS 文案。

### D. 像素规格（402pt）

14. 页头、composer 卡片、toolbar、发送/停止、附件条、queue dock、todo dock、goal bar、stats 行、slash/@ 弹层、context meter。
15. 每个控件给：尺寸/位置/内边距/字号/行高/颜色（light/dark）/圆角/边框/阴影/图标/状态/动效。
16. 手机宽度下的键盘/safe-area/滚动行为；官方 `mobile.module.css` 的具体规则。

### E. 验收场景

至少 12 个：空会话、有历史、运行中（停止/排队/补充）、权限等待、问题等待、附件、slash 菜单、@ 引用、模型切换、access mode 切换、plan mode、goal bar、queue dock、todo dock、长草稿、键盘弹起、浅色/深色。

## 参考起点

- 官方：`packages/client/ui-conversation/src/client/skeleton/{ConversationRoot,ConversationHeader,ConversationSession,InputBar,ContextMeter,EmptyHero}.tsx` + CSS；`queue/QueueDock.*`；`skeleton/TodoPanel.*`；`ui-goal/src/client/GoalBar.*`；`ui-mobile/src/client/mobile.module.css`；`ui-chat/src/client/chat/StatsPills.*`、`TurnUsagePanel.*`
- 官方 slots：`conversation.input.dock`、`conversation.composer.dock`、`conversation.input.overlay`、`conversation.session.header.*` 的注册点
- 官方 locale：`ui-conversation/src/client/locales.ts`（`input.*`、`placeholder.*`、`session.*`、`queue.*`）、`ui-goal/src/client/locales.ts`
- 官方测试：`ui-conversation/tests/` 中 input/queue/composer/header 相关 spec；`ui-mobile/tests/`
- iOS：`ChatPage.swift`（chatHeader/composer/composerControls/actionButton/stopButton/goalBar/queuedStrip/slashCommandMenu/referenceMenu/NativeComposerStats）、`NativeComposerStats.swift`、`NativeChatTheme.swift`、`ChatModel.swift`（canSend/busyEnter/queue/attachments）
- 截图：`ios-chat-official.png`（官方手机宽度空态）、`ios-chat-default.png`（iOS 运行中）、`ios-chat-queued.png`、`ios-chat-draft.png`、`ios-chat-long.png`

不要改源码。报告中文，证据 `file:line`。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
