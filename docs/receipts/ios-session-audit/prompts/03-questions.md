# Axis 03 — 提问（ask_user_question）

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只审 **遇到问题提问** 在 session 会话页的全部形态。

报告路径：`docs/receipts/ios-session-audit/03-questions.md`

## 目标

用户点名“遇到问题提问”是缺口。官方不止一张待回答卡：它有 composer takeover、分页/多题、推荐项、跳过、自定义、倒计时/等待、提交状态、失败重试、已回答的 transcript 气泡、工具行里的问答卡、以及与 plan review 的路由。请全部找全并对齐 iOS。

## 必须覆盖

### A. 待回答（live）

1. 官方 pending question 的**数据形状**：`PendingQuestion` / `QuestionCardSnapshot` / `question-reply.ts` / `contract/slots.ts`
   - header / question / detail / options(label, description, recommended) / multiple / id / presentation intent / review / outcome / channel / waitState / countdown / closed
   - 与 iOS `HarnessQuestion`/`HarnessQuestionItem`（只有 id/prompt/options/multiple）逐字段对照
2. **QuestionComposer**（`QuestionComposer.tsx` + `QuestionComposer.module.css`）
   - 谁接管 composer、何时接管、和普通 composer 的切换/退出
   - 单题/多题、上一题/下一题、进度、question header/detail、选项（推荐标记、描述）、多选、自定义 textarea（自适应高度/IME/Shift+Enter）、跳过、取消、提交
   - 校验：未答/未完成/不可用/已提交；提交中冻结；waterfall/remote 的 resubmit；错误展示与重试
   - 倒计时/等待态（`waitState`、`countdown`）的视觉与文案；超时/继续
   - 草稿持久化（`draft-store.ts`）跨会话/重挂载恢复；只读 review 模式
   - 手机宽度：占满 composer？键盘、safe area、滚动、底部按钮
3. **PlanReviewPanel 路由**：同一 question carrier 上 `presentation` 为 plan review 时如何切换；不要和 Axis 02 重复细节，但写清“question 入口如何分流”。
4. **通知/焦点**：新问题到达时是否滚动/聚焦/提示；composer 被占用时用户怎么知道；多个 pending 的排队/展示顺序。

### B. 已回答（transcript）

5. **QuestionReplyView**（`QuestionReplyView.tsx` + `.module.css`）
   - 右对齐气泡、label、折叠/展开、summary、每个 question 的 header/question/detail/options、答案（多选逗号）、skipped、copy、时间
   - 何时出现：tool result 后？call 结算后？与工具行的关系？重复/迟到回复
   - 手机宽度换行/最大宽度
6. **AskQuestionCard**（`ui-tool/.../AskQuestionCard.tsx` + `ask-question-card-model.ts`）
   - 工具行展开态里的 answered/unanswered 两种卡；verdict、题目列表、答案、skipped
   - 与 QuestionReplyView 的分工：同一请求会同时出现两者吗？官方如何避免重复？
7. **`ask_user_question` toolview**：折叠态标题/summary/状态；preparing/running/error/stopped；结果非法/未回答时的 fallback。

### C. iOS 现状

8. `QuestionCard`（`ChatPage.swift:2139-2245`）逐项对照：布局、分页缺失、推荐项缺失、header/detail 缺失、skip/cancel 缺失、倒计时缺失、提交错误/重试缺失、草稿缺失、只读 review 缺失、键盘行为。
9. `pendingQuestion` 的数据来自 `HarnessEvent.questionRequested`；查清 worker/channel/DSH 实际发送的问题 payload 是否含官方全部字段（若不含，属于 Axis 01 的数据缺口，也要在这里指出）。
10. 回答后：`respondToQuestion` 发送什么；iOS 是否把回答写回 transcript；历史加载时能否重建已答问题（`user-question/*` 事件是否映射）。
11. iOS 的待处理卡区：`cardsRegion` 与 transcript 的关系（置顶/滚动/键盘折叠/多项折叠）；官方是 composer takeover，二者信息架构差异要写清。
12. 权限卡与问题卡同时存在时的优先级（iOS 当前 permission 优先、question 折成“还有 1 个待确认”）；官方如何处理多个 pending。

### D. 像素规格

13. 对 pending composer（单题/多题/自定义/提交中/错误/倒计时）、QuestionReply 气泡（折叠/展开）、AskQuestionCard、工具行折叠态，分别给：字号/行高/间距/圆角/颜色（light/dark）/按钮尺寸/图标/最大宽度/手机换行/键盘 inset/动效。
14. 官方中文文案原文；iOS 当前文案；标点/全角半角差异。

### E. 验收场景

至少 8 个：单题选项、单题自定义、多题分页、多选题、推荐项、跳过/取消、提交失败重试、已回答历史、超时/继续、键盘弹起、长选项/长问题。

## 参考起点

- 官方：`packages/client/ui-user-questions/src/client/*`（全部）、`packages/client/ui-tool/src/client/tool/toolviews/ask-question-row.tsx`、`components/AskQuestionCard.tsx`、`models/ask-question-card-model.ts`、`packages/interaction/`（问题协议）
- 官方 locale：`ui-user-questions/src/client/locales.ts`、`ui-conversation/src/client/locales.ts`（reply.* / question.*）
- 官方测试：`ui-user-questions/tests/*`、`ui-tool/tests/ask-question-row.client.spec.tsx`、`apps/web/tests/question-composer.e2e.ts`
- iOS：`ChatPage.swift`（QuestionCard/cardsRegion/respond）、`ChatModel.swift`（pendingQuestion/respondToQuestion/handle）、`AgentHarness.swift`（HarnessQuestion）、`NativeMessageRows.swift`
- 截图：`ios-chat-permission.png` 可看 iOS 待处理卡风格；官方截图 `ios-chat-official.png`

不要改源码。报告中文，证据 `file:line`。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
