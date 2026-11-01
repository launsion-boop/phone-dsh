# Axis 06 — 工具行 / 工具卡 / 嵌套调用

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只审 **工具调用在 transcript 里的所有呈现**，包括折叠行、展开卡、状态、嵌套 subcall、错误/停止/准备中。

报告路径：`docs/receipts/ios-session-audit/06-tools.md`

## 目标

官方有约 **51 个 `tool.call.toolview` key**，每个 key 落到不同卡片/详情模型；iOS 只有 7 个 variant + 少量标题特判。请给出完整的 key 对照表，并把高频/控制类工具卡的像素级差距讲透。

## 必须覆盖

### A. 官方全量 toolview 清单

1. 穷尽官方 `tool.call.toolview` 注册（`grep -rn "name: 'tool.call.toolview'"`），列出：key、注册文件、组件、详情模型、所属视觉族（bash/read/write-edit/search/web/image/todo/ask/subagent-team/job-schedule-goal/workflow/inspection/generic/...）。
2. 对每个 key 标：折叠态标题/图标/summary 来源；展开态是哪种 card（terminal/diff/read/search/web/image/details/ask/todo/generic）；preparing/running/error/stopped 的行为；是否可嵌套 subCalls。
3. 说明 **fallback**：没有专用 view 的 key 落到 `GenericToolCard` 时是什么样；自动审核拒绝（autoReviewDenied）走 generic 的规则。
4. 说明 **ToolCallTree**：root + `tool/ptc-dispatch*` 子调用如何嵌套、缩进/连接线、展开策略、最大深度、subcall 的 callId 来源；iOS 是否支持嵌套。
5. 说明 **准备中（preparing）行**：`assistant/live-chunk` 的 tool-call delta 如何在参数还没齐时先出现一行、标题/图标如何选、是否可展开、与最终 `tool/call` 的衔接；iOS 是否有。
6. 说明 **状态与摘要**：`ToolRowState`、`summarySuffix`、diff totals、exit code badge、errorSummary、stopped、auto-review denial、`summary` 的截断/非截断分段；行高/字号/颜色/shimmer。
7. 说明 **展开 body 的通用结构**：Input/Output 分区、代码块、Read/Search/Web/Terminal/Diff/Details/Ask 卡、复制/打开文件/检查（inspect）入口、最大行数/截断/滚动/折叠。
8. 说明工具行的 **点击/键盘/焦点/aria** 与移动端触控目标。

### B. iOS 现状

9. `NativeToolCallModel` 的 7 个 variant 与标题映射；`NativeToolDetailCards` 的实际卡片；`NativeToolCallRow`（`ChatPage.swift` 内）如何组合；`NativeDisclosureRow` 的 24pt 行高、图标/标题/summary/chevron 规则。
10. 对照 A 的全量清单，给每个 key 标：iOS 专用卡 / 通用卡 / 完全无（例如 `todo_write` 只显示“更新任务清单”通用卡，`ask_user_question` 只显示“向你提问”，`subagent` 只显示“子 Agent”，`exit_plan_mode` 无特判）。
11. iOS 的 `ToolRunRow` 把连续 tool call/result 合成一组，组内仍逐条 `NativeToolCallRow`；没有官方的 process group 折叠/计数/实时标题（与 Axis 05 的边界写清）。
12. iOS 的 preparing 状态：`NativeToolState` 有 preparing，但事件管线是否会产生？`ChatModel` 的 live delta 是否创建 preparing 行？如果没有，写明。
13. iOS 的工具结果：`toolResultDetail`（完整文本）vs `summary`（280 字单行）；哪些卡用 detail、哪些用 summary；大输出截断/滚动；`toolMetadata`/`meta`（exitCode、diffs、path）是否保留。
14. iOS 的嵌套 subcall：`tool/ptc-dispatch*` 是否映射/渲染；`subCalls` 字段是否存在。
15. iOS 的错误/停止：`toolState` 的 error/stopped 展示、错误行、summary 取首行、重试入口（如果有）。

### C. 像素规格（402pt）

16. 至少为以下族给精确规格（折叠/展开/运行中/错误/停止）：
   - bash/terminal（命令、描述、exit badge、输出、行数、等宽字体、换行/水平滚动）
   - read（路径、行号、代码、折叠）
   - write/edit/diff（+/- 计数、diff 颜色、行号、hunk、文件头、打开）
   - search（pattern、命中数、文件/行、分组）
   - web_search/web_fetch（query/url、结果列表、favicon/标题/摘要）
   - image（缩略图/网格/查看器）
   - todo_write（与 Axis 02 分工：这里只写工具行折叠/展开，不重复 TodoPanel）
   - ask_user_question（与 Axis 03 分工：这里只写工具行）
   - subagent/team（与 Axis 04 分工：这里只写工具行）
   - job/schedule/goal/workflow/details/generic
17. 通用：行高、图标 14/16、标题 13/14、summary 13、间距 6/8、chevron 12、展开 body 的 padding/背景/圆角/分割线、代码字体 12、最大高度。
18. 官方中文文案（`ui-tool/src/client/locale.ts`、`ui-conversation/src/client/locales.ts`）与 iOS 当前文案（`NativeToolCallModel`、`ToolWording`）对照。

### D. 验收场景

至少 10 个：bash 成功/失败/停止、read 长文件、edit diff、write 新文件、grep 多命中、web_search、image 结果、todo_write、ask_user_question、subagent、preparing→running→ok、嵌套 subcall、超大输出、非法 JSON、工具名未知。

## 参考起点

- 官方：`packages/client/ui-tool/src/client/tool/` 全部；`toolviews/` 注册；`components/ToolRow.tsx`、`ToolDetails.tsx`、`AskQuestionCard.tsx`、`ExitCodeBadge.tsx`；`models/` 全部；`ToolRow.module.css`、`ToolCallTree.module.css`、`ToolDetails.module.css`、`AskQuestionCard.module.css`
- 官方 primitives：`packages/client/ui-primitives/src/`（CodeBlock/DiffBlock/ReadBlock/SearchBlock/TerminalBlock/WebBlock/DisclosureRow/TextShimmer）
- 官方 locale：`ui-tool/src/client/locale.ts`、`ui-conversation/src/client/locales.ts`
- 官方测试：`ui-tool/tests/` 全部相关 spec
- iOS：`ChatPage.swift`（`ChatMessageRow`、`ToolRunRow`、`NativeToolCallRow`、`ChatPage.spacing`）、`NativeToolCallModel.swift`、`NativeToolDetailCards.swift`、`NativeMessageRows.swift`、`ToolWording.swift`、`NativeChatTheme.swift`
- 截图：`ios-chat-assistant.png`（工具行/代码块）、`ios-chat-default.png`、`ios-chat-official.png`

不要改源码。报告中文，证据 `file:line`。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
