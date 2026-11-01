# Axis 07 — 消息内容 / 行类型 / 消息动作 / Turn Tail

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只审 **除了工具卡和 turn 结构之外的消息内容呈现**：assistant Markdown、reasoning、user/steering/context、命令/压缩/重试/错误/系统提示等特殊行、消息动作、图片/附件、turn tail 的统计与操作。

报告路径：`docs/receipts/ios-session-audit/07-content-actions.md`

## 目标

官方消息流里的“行”远不止 user/assistant/tool。请把 `conversation.chat.node` 的所有 kind 与它们的内容渲染、动作、状态全部拆开，对照 iOS 的自绘 Markdown/动作，给出像素级差距。

## 必须覆盖

### A. 行类型（chat node kind）

逐个覆盖官方 `conversation.chat.node` 注册的 kind（以实际注册为准）：

1. `assistant-step`（`AssistantNodeView`、`AssistantMarkdown`）
   - streaming / settled / interrupted 三态
   - 正文、reasoning 的位置（inline reasoning 规则）、图片、usage、finalNode
   - 中间回复 vs 最终回复的呈现
2. `user` / `steering`（`MessageItem.tsx` / `UserText.tsx`）
   - 右对齐气泡、最大宽度、padding、圆角、字号/行高、换行/长英文/代码、引用/reference summary、图片、attachments、时间、动作
   - steering 与 user 的视觉差异（官方是否显示 “steering”、位置、标签）
3. `context` / `turn-trigger`（`ContextMessageNodeView`、`TurnTriggerNodeView`、`ContextBody`）
   - 哪些 context 可见、哪些隐藏在 node store；form/producer/source 的标题/图标/展开 body
   - turn-trigger 的标题/图标/时间/说明/展开（与 Axis 04 分工：这里写通用结构，04 写 subagent 等具体来源）
4. `system-prompt`（`SystemPromptRow`）
   - 何时可见、折叠、标题/摘要、展开内容
5. `command` / `command-input` / `manual-compaction`（`CommandNodeView`、`GenericCommandCard`、`CompactionCommandCard`）
   - slash 命令执行的结果卡、命令名/输入/输出/错误、折叠
   - 手动压缩命令与压缩事务
6. `compaction`（`CompactionItem`）
   - “上下文已整理” 行、摘要、展开、pinned toggle、代码块 banner 的偏移
7. `model-retry`（`RetryNodeView`）
   - 重试链、attempts、当前 attempt、失败原因、折叠、时间
8. `turn-error` / `turn-max-tokens`（`TurnErrorNodeView`、`TurnMaxTokensNodeView`）
   - 图标/颜色/标题/正文/操作（重试/继续/复制）
9. `unknown` / `fallback`（`UnknownNodeView`）
   - 未知事件的兜底展示，是否隐藏
10. `workflow-run`（`ui-workflow-run`）
    - 何时出现在 transcript、面板结构、状态、进度、展开/跳转、手机宽度
11. `question-reply`（与 Axis 03 分工：这里只写它在行结构中的位置/右对齐/时间/动作，不重复问答 UX）
12. `turn-tail`（与 Axis 05 分工：这里写它的内容组成——usage、actions、deliverables/plan/schedule/test-file 等 slot 贡献、按钮、stats；05 写折叠/位置）
13. 附件/图片/文件：
    - 用户图片、assistant 图片、工具图片的查看器（lightbox）、网格、alt/加载/失败、下载/分享
    - 文件附件 chip、大小、图标、打开
14. 消息动作：
    - `MessageIconActions`、`TurnTailNodeView` 的 actions、feedback（点赞/点踩）、copy、retry、edit、branch/fork、quote/reference、share
    - 出现条件（hover? 长按? 手机端 always?）、位置、图标、tooltip、确认/失败/已选状态
    - iOS `NativeMessageActions` 的实际能力（用户消息时间/复制、assistant 复制/反馈、turn closing 的 changed files/usage）
15. `StatsPills` / `TurnUsagePanel` / `ContextMeter`（如果属于会话页内容）：
    - 位置、字段、数字格式、紧凑/展开、移动端
16. 空态/加载态：`EmptyHero`、骨架、错误重试（如果属于会话页）

### B. Markdown / 代码渲染

17. 官方 `AssistantMarkdown` + renderer/primitives：
    - 标题层级/字号/行高/间距
    - 段落/粗斜体/删除线/行内代码/链接/引用/分割线
    - 有序/无序/任务列表、嵌套
    - 表格（宽表 breakout、对齐、边框、header 背景、手机横向滚动）
    - 代码块（banner、语言图标、语言名、复制、换行切换、行号、语法高亮、横向滚动、最大高度、流式未闭合）
    - TeX/数学（行内/块级）、脚注、图片、HTML、mermaid（若有）
    - 流式光标/ shimmer / 未完成 Markdown 的容错
18. iOS `NativeMarkdownBody` / `NativeMarkdownModel` / `NativeMarkdownTests` 的实际支持矩阵；逐项对照，指出“有但不一致”和“完全没有”。
19. 复制/选中/链接打开/文件提及（`nativeFileMention`）的行为差异；外部链接确认；workspace 文件打开。

### C. 像素规格（402pt）

20. 用户气泡、assistant 正文、heading 1–4、列表、引用、表格、代码块、行内代码、链接、分割线、图片网格、附件 chip、context 行、trigger 行、命令卡、压缩行、重试行、错误行、max-token 行、turn tail。
21. 官方 token 解析值（light/dark）；iOS 当前值。字号/行高/间距/圆角/颜色/边框/阴影。
22. 官方中文文案原文 vs iOS 文案；特别看标点、全角/半角、省略号、数字/时间格式。

### D. 验收场景

至少 12 个：纯文本、标题/列表/表格/代码/数学/脚注、流式未闭合代码、长英文换行、用户长文本/图片、assistant 图片、命令结果、压缩、重试、错误、max tokens、未知事件、feedback、复制、turn tail usage。

## 参考起点

- 官方：`packages/client/ui-chat/src/client/chat/{AssistantNodeView,AssistantMarkdown,MessageItem,UserContent,ContextBody,ContextInjectionRow,SystemPromptRow,CommandNodeView,GenericCommandCard,CompactionCommandCard,CompactionItem,MessageIconActions,StatsPills,TurnTailNodeView,TurnUsagePanel,QuotaNoticeHost}.tsx` + 对应 CSS
- 官方 renderer/primitives：`packages/client/ui-renderer/`、`packages/client/ui-primitives/src/`（MarkdownText/CodeBlock/DiffBlock/Image/…）
- 官方 locales：`ui-chat/src/client/locale.ts`、`ui-conversation/src/client/locales.ts`、`ui-message-feedback/`、`ui-workflow-run/src/client/locales.ts`
- 官方测试：`ui-chat/tests/*assistant*`、`*message*`、`*markdown*`、`*retry*`、`*compaction*`、`*turn-tail*`、`*command*`；`ui-renderer/tests/`；`ui-primitives/tests/`
- iOS：`NativeMarkdownBody.swift`、`NativeMarkdownModel.swift`、`NativeCodeHighlighter.swift`、`NativeChatFormatting.swift`、`NativeMessageActions.swift`、`NativeMessageRows.swift`、`NativeChangedFilesCard.swift`、`ChatPage.swift`（ChatMessageRow/assistantBody/userBubble/ContextInjectionCard/PermissionCardView）、`NativeChatTheme.swift`
- 截图：`ios-chat-assistant.png`（代码块/工具）、`ios-chat-long.png`（长文本/输入框）、`ios-code-block.png`、`ios-chat-official.png`

不要改源码。报告中文，证据 `file:line`。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
