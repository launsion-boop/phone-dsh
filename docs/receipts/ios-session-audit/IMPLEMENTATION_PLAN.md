# iOS Session 对齐 — 实施计划（Wave 0 / 1）

> 依据：[00-MASTER.md](00-MASTER.md)、[09-scanner-gaps.md](09-scanner-gaps.md)、[parity/coverage.md](parity/coverage.md)
> 目标：把 24 条 P0 与 20 类 P1 按依赖拆成可并行的实现流；**远程字体/排版为唯一基准**，iOS 现值只作偏差对照。
> 本轮范围：Wave 0 地基 + Wave 1 核心 surface 的视图与数据接线；Wave 2/3 在后续轮次。
>
> **实施状态（2026-11-01）**：5 个并行子 Agent 已交付 18 个新视图文件；主 Agent 完成数据地基、token/像素基线，并接线 TodoDock / PlanChip / PlanReview / PlanCard / RunningStatus / TurnTrigger / Turn control+fold / Turn tail / QuestionComposer / QuestionReply / AskCard / Subagent header+catalog+tool rows / Tool title table+details / 页头统一 gear 菜单；轨迹 tab 按 D-04 不做。`xcodebuild` 通过，402pt 截图见 [screens/wave0-question-composer.png](screens/wave0-question-composer.png) 与 [screens/wave1-tabs.png](screens/wave1-tabs.png)。已完成/未完成清单见 [10-wave0-implementation.md](10-wave0-implementation.md)。

## 0. 约束

1. **只改 `examples/probe-app/PhoneDSHProbe/` 与会话线数据层**；不碰会话列表、设置、工作区等无关面。
2. **远程值优先**：字号/行高/间距/圆角/颜色以 `09-scanner-gaps`/`00-MASTER` §6 的官方解析值为准；`NativeParityTokens` 是新的共享 token。
3. **并行分工按文件所有权**：每个子 Agent 只新建自己的文件，不改 `ChatPage.swift`/`ChatModel.swift`/`NativeChatTheme.swift`/`project.yml`；共享文件由主 Agent 集成。
4. **不跑设备/后端**：实现用编译 + 单测 + 截图（模拟器）验证；真实回合留给后续验收。
5. **不做“设计再创作”**：官方有手机端行为的照官方；官方没有的（深色、Dynamic Type、sidebar-right）标注为决策，不混入对齐。

## 1. 当前基线（实现前）

- 报告：8 份轴报告 + 09b；24 条去重 P0、20 类 P1。
- 代码：`ChatItem` 12 kind；`ChatModel` 只接 5 个 projection key；`ChatPage` 单文件 2962 行；`NativeChatTheme` 是旧 token。
- 数据：`session/projections` 已能返回 `todos/plan/subagentCatalog/inbox/userQuestions/goal/title`；`session/follow` snapshot 的 `projections` 未读；`inboxSpliced` 被丢弃；`tool/result.meta` 实时丢。
- 官方：20 chat node / 54 toolview / 35 slot / 29 projection；shipped `ui-trajectory`、`ui-agent-preset`、`ui-jobs` 等。

## 2. 并行工作流

### WS-A（主 Agent）数据地基 + 集成

| 项 | 文件 | 内容 |
|---|---|---|
| A1 | `Sources/PhoneDSHAgentCore/DSH/DSHEventMapper.swift` | `user/message` source.form/summary；`inboxSpliced` target/start/removed/inserted id；`tool/result` meta/error.code；`step/end`；`tool/ptc-dispatch*`（可先透传） |
| A2 | `Sources/PhoneDSHAgentCore/AgentHarness.swift` | `HarnessUserInput` 补 id/form/summary；`HarnessEvent` 补 `toolResultMeta`/`toolResultErrorCode`/`inboxTarget` |
| A3 | `examples/probe-app/PhoneDSHProbe/ChatModel.swift` | 修 goal/title 路径；加 `projectionValues`（todos/plan/inbox/userQuestions/subagentCatalog/goal/title）；实时 `userMessage`/`inboxSpliced` 不再 break；tool meta 写入；`turnTrigger`/`steering` 分类 |
| A4 | `examples/probe-app/PhoneDSHProbe/NativeConversationModels.swift` | `ChatItem.Kind` 增 `steering`/`turnTrigger`/`questionReply`/`turnProcess`/`turnTail`；字段 source/id/callID/subCalls/plan/question |
| A5 | `examples/probe-app/PhoneDSHProbe/NativeTranscriptProjector.swift` | 历史与实时共用分类/结果写入；补 `agent/inbox/spliced`、`system/message`、`command/*`、`compaction/*`、`user-question-reply`、subagent/trigger |
| A6 | `examples/probe-app/PhoneDSHProbe/ChatPage.swift` | 接新视图：TodoDock/PlanChip/PlanReview/QuestionComposer/TurnTrigger/TurnProcess/RunningStatus/Subagent header；像素基线（338/24/20/28/50） |
| A7 | `examples/probe-app/PhoneDSHProbe/NativeChatTheme.swift` | 改为 `NativeParityTokens` 的 facade；保留旧名兼容 |

### WS-B（子 Agent 1）计划 / Todo 视图

新建（不改共享文件）：

- `NativeTodoDock.swift` — 338×36 折叠条、圆角 16、13/24 + 13/20、列表 180、三态点；默认折叠；预览。
- `NativePlanChip.swift` — 28pt、圆角 8、`#E4EDFD`/`#4176E6`、计划图标/关闭图标、失败文案。
- `NativePlanReviewCard.swift` — 338、圆角 20、琥珀 strip、标题/描述、要求修改/同意执行 36pt 按钮。
- `NativePlanCard.swift` — 60pt 计划卡（markdown 图标/标题/副标题/打开）。

要求：只依赖 SwiftUI + `NativeParityTokens`；自带 `#if DEBUG` 预览数据；不引用 `ChatItem`/`ChatModel`；文件内类型加 `Native` 前缀避免冲突。

### WS-C（子 Agent 2）提问视图

新建：

- `NativeQuestionComposer.swift` — composer takeover：338、圆角 20、max-height min(60vh,520)、eyebrow/title、分页 1/N、选项 40pt、推荐、多选、自定义、跳过/收起/关闭、倒计时、提交中/错误。
- `NativeQuestionReplyBubble.swift` — 右对齐 72%、10×16、圆角 20、`#EDF3FE`、折叠/展开/复制/时间。
- `NativeAskQuestionCard.swift` — 工具行展开态已回答/未回答卡。

要求同上；计划审阅分流只做“可切换”入口，不实现 plan 逻辑。

### WS-D（子 Agent 3）Turn / 运行 / 触发视图

新建：

- `NativeTurnProcessRow.swift` — 33pt 控制行、8pt 下内距、0.5pt 下边线、14/24、14pt chevron、四态（已完成/已停止/处理失败/运行中）。
- `NativeRunningStatus.swift` — 12/22、`rgb(52,94,186)`、14pt 鲸鱼/星形图形（可用 SF Symbol 近似，标注）、shimmer、0.5pt 分隔线、计时。
- `NativeTurnTriggerRow.swift` — `#F9FAFB`、圆角 20、12/16 header、14 title、12/18 time、chevron、body 40pt 缩进、10 种来源标题/图标、展开。
- `NativeTurnTail.swift` — 动作行 28pt、复制/反馈/分支/用量/时间（可先只做展示，回调可选）。
- `NativeProcessGroupHeader.swift` — 组头 16 盒+6、14pt、shimmer、subagent 计数、展开/折叠。

要求：只依赖 SwiftUI + `NativeParityTokens`；定义本地 `Native...Data` 模型；预览覆盖四态。

### WS-E（子 Agent 4）子 Agent header / catalog

新建：

- `NativeSubagentHeaderButton.swift` — 页头按钮 `{count} 个子智能体` 12/18、28 高、运行中 14pt 点/转圈。
- `NativeSubagentCatalogSheet.swift` — 336/400 宽、44 行、树形/缩进、运行状态、模式、时长/tokens、打开子会话/侧栏。
- `NativeSubagentToolRows.swift` — `subagent`/`list_agents`/`send_message`/`wait_agent`/`interrupt_agent`/`spawn_teammate` 的折叠标题/图标/summary/详情卡。

要求：只依赖 SwiftUI + `NativeParityTokens`；数据模型本地定义；不接 ChatModel。

### WS-F（子 Agent 5）工具卡 / Details

新建：

- `NativeToolCardChrome.swift` — 工具卡统一 chrome：圆角 16、0.5pt 边、`#F9FAFB` 底、header 11/18、代码 11/19、复制/展开。
- `NativeToolDetailsCard.swift` — 37 个 DetailsRow 的通用字段 + 状态徽章 + 分组列表；支持 goal/schedule/job/subagent/team/terminal/session/lsp/workflow/cordis 的字段映射。
- `NativeToolTitleTable.swift` — 54 个 toolview key 的标题/图标映射（官方中文），供 `NativeToolCallModel` 接入。

要求：只依赖 SwiftUI + `NativeParityTokens`；不修改 `NativeToolCallModel`/`NativeToolDetailCards`；提供 `static func` 映射表。

### WS-G（主 Agent）像素与 token

- 新建 `NativeParityTokens.swift`（共享，先于所有子 Agent）。
- `NativeChatTheme` 改为 facade。
- `ChatPage`：transcript 32 侧距、assistant lineSpacing 24、用户气泡 `#EDF3FE`/20/10×16/277、composer 圆角 28/370×98、页头 50/14-20/0.5pt、tertiary `#81858C`、工具行颜色。
- 不改交互逻辑，只改几何/颜色/字体。

## 3. 集成顺序

1. 主 Agent 写 `NativeParityTokens` + 计划文档（本文件）。
2. 并行：WS-B/C/D/E/F 子 Agent 只新建文件；主 Agent 同时做 WS-A 数据层 + WS-G 像素。
3. 子 Agent 完成后，主 Agent 审查/编译新文件（`xcodegen generate` + `xcodebuild`）。
4. 主 Agent 在 `ChatPage` 接线顺序：TodoDock → PlanChip → TurnTrigger/Running → QuestionComposer → TurnProcess/Group → Subagent header；每步编译。
5. 数据接线顺序：projection store → inbox/turn-trigger → question → plan/todo → tool meta → subagent header。
6. 最后跑 `scripts/ios-parity/audit.py` 复扫 + 模拟器截图。

## 4. Wave 对照

| Wave | 本计划覆盖 |
|---|---|
| Wave 0 | A1–A3、A7、G；B/C 的视图骨架；单测 |
| Wave 1 | A4–A6、B/C/D/E 接线；Turn/计划/提问/子 Agent/trigger |
| Wave 2 | F 工具卡接线；队列/图片/命令/压缩等 |
| Wave 3 | 轨迹 tab/header 贡献、golden、像素收尾 |

## 5. 验收

- 每次集成后 `xcodegen generate` + `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`。
- 新增单测：projection decode、inbox 分类、tool meta、theme metrics。
- 模拟器截图：空态、todo、plan review、question、trigger、turn process、header catalog。
- `audit.py` 复跑：`conversation.view` 与 header 贡献仍应列为“待实现”，直到 Wave 3。

## 6. 风险

- 多个子 Agent 同时新建文件不会冲突；但主 Agent 的 `ChatPage`/`ChatModel` 改动较大，必须每步编译。
- 新视图使用本地模型，接线时要做一次映射；不要让视图直接依赖 `ChatItem`。
- 官方 402pt 无 golden；像素值仍是 CSS 推导，截图验收需补官方 golden。
