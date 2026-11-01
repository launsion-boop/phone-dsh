# Axis 02 — 计划 / Todo / Plan 模式

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只审 **计划（todo / plan）在 session 会话页上的全部形态**。

报告路径：`docs/receipts/ios-session-audit/02-plan-todo.md`

## 目标

用户点名“计划”是缺口。请把官方与 plan/todo 相关的**所有**会话页 surface 找全，给出触发条件、状态机、像素规格，并逐项对照 iOS（当前基本为零）。最终让工程同学能直接按报告实现。

## 必须覆盖的官方 surface

1. **TodoPanel（composer 上方 dock）**
   - `packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx` + `.module.css`
   - 触发：`todos` projection 非空；默认折叠/展开；标题、进度文案、chevron、list、max-height、滚动、ellipsis
   - 状态：completed / in_progress / pending 的圆点/颜色/aria；多 in_progress
   - 与 composer 的宽度/inset/圆角/背景/阴影关系；与 queue dock、goal bar 的堆叠顺序
2. **`todo_write` 工具行**
   - `packages/client/ui-tool/src/client/tool/toolviews/todo-row.tsx`、`todo-diff-model.ts`、`todo-history.ts`、`plan-summary.ts`
   - 折叠态 summary：`done/total`、当前 active 内容、`+N`、diff summary；截断/非截断分段
   - 展开态：全部 item、状态、内容、diff（新增/完成/移除/修改？以官方为准）
   - 失败/stopped/空/todos 非法 JSON 的 fallback
3. **Plan mode 控件**
   - `packages/client/ui-plan/src/client/PlanModeControl.tsx` + `.module.css`、`plan-resource.ts`、`failure-line.ts`
   - 在 composer 的什么位置、什么状态（off/on/planning/review?）、文案、图标、切换行为、与 access mode 的关系
   - 与 `exit_plan_mode` 工具、`plan` preset 的关系
4. **Submitted plan 卡片（turn tail）**
   - `packages/client/ui-plan/src/client/PlanCard.tsx` + `PlanPreview.module.css`
   - 何时出现（turn 结束、`exit_plan_mode` 调用）、卡片内容（markdown 文件图标、标题、副标题、打开动作）
   - 点击后官方右栏/手机抽屉如何打开 plan 文档；被拒绝/ dismissed 的 plan 是否保留
5. **Plan review 面板**
   - 官方在 `ui-user-questions/src/client/PlanReviewPanel.tsx`（注意不是 ui-plan 目录）
   - 何时接管 composer、布局、plan 预览、批准/拒绝/继续编辑按钮、快捷键、提交中/失败/重试、与 question composer 的路由
   - 手机宽度下的布局（全屏 sheet？内联？）
6. **Plan 预览文档**
   - `PlanPreview.tsx`、`review-preview.ts`、右侧栏 plan resource（手机端是 drawer/sheet）；标题、Markdown 渲染、滚动、关闭
7. **数据来源**
   - 官方 `todos` projection 如何产生/更新（`packages/todo`、`ui-chat` 的 todo history）；`exit_plan_mode` 的 args/result；plan mode 状态在 session 内的存储
   - iOS 能否从 `todo_write` tool call 历史/实时事件推导出同样的 panel？`exit_plan_mode` 是否出现在 iOS 的工具列表/通用卡中？plan mode 是否完全不存在？
8. **iOS 现状**
   - 穷尽搜索 `todo`、`plan`、`Todo`、`Plan`、`exit_plan_mode`、`todo_write`；区分 access mode 的 `"plan": "只出方案"`、goal、restart policy 等无关命中。
   - 现有 `goalBar`、`queuedStrip` 的布局模式可复用；指出插入位置与状态管理位置。
   - 现有 `ChatItem`/`HarnessEvent` 是否能承载 todo/plan；若不能，给出最小数据模型。
9. **像素规格**
   - 对 TodoPanel、todo row 折叠/展开、PlanModeControl、plan card、PlanReviewPanel、plan preview 分别给：宽高/内边距/字号/行高/颜色（light/dark）/圆角/图标/间距/动效/手机宽度换行。
   - 以官方 CSS 变量解析值为准；402pt 宽。
10. **验收场景**
    - 至少 6 个可复现场景：todo 首次出现、运行中更新、全部完成、折叠/展开、plan mode 开启、plan 提交后批准/拒绝、长 todo 列表滚动、无 todo 空态。

## 参考起点

- 官方：`packages/client/ui-plan/src/client/*`、`packages/client/ui-conversation/src/client/skeleton/TodoPanel.*`、`packages/client/ui-tool/src/client/tool/toolviews/todo-row.tsx`、`packages/todo/`、`packages/plan/`、`packages/client/ui-user-questions/src/client/PlanReviewPanel.*`、`packages/client/ui-chat/src/client/chat/TurnTailNodeView.*`
- 官方 locale：`ui-conversation/src/client/locales.ts`、`ui-tool/src/client/locale.ts`、`ui-plan/src/client/locales.ts`、`ui-user-questions/src/client/locales.ts`
- 官方测试：`ui-plan/tests/`、`ui-conversation/tests/`、`ui-tool/tests/` 中 todo/plan 相关 spec；`apps/web/tests/` 中 plan review 相关
- iOS：`ChatPage.swift`（composer/goalBar/queuedStrip）、`ChatModel.swift`、`NativeConversationModels.swift`、`NativeTranscriptProjector.swift`、`NativeToolCallModel.swift`、`NativeToolDetailCards.swift`、`NativeChatTheme.swift`
- 截图：`docs/receipts/ios-baseline-screens/ios-chat-official.png`（手机宽度官方）、`ios-chat-default.png`（iOS 当前）

不要改源码。报告中文，证据 `file:line`。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
