# iOS 原生 Session 会话页 × 官方 DSH 0.2.1-rc.2 — 基线对齐审计（Master）

> 审计日期：2026-10-31 / 2026-11-01
> 官方基线：`deepseek-harness` @ `7be5505b0be06009d74891c869063c9cf19a0df0`（`0.2.1-rc.2`，与 `plugins/dsh-pin.json` 一致）
> iOS 基线：`phone-dsh` 当前工作区（未修改任何源码）
> 视觉基准：手机宽度 **402×874 pt**（截图 1206×2622 @3x；CSS px ≈ iOS pt）
> 范围：**只看 session 内容会话线**（transcript、composer、页头、消息流内的条件控件、支撑它们的数据链路）。不含会话列表、设置、工作区、MCP 配置等。

---

## 0. 结论摘要（先看这 12 条）

1. **用户的直觉是对的：缺口不是“几个控件”，而是三条结构性断层。** 官方会话页 = **Turn 过程模型 + composer 接管链 + projection 驱动的一批条件 surface**；iOS = **平铺消息 + 页顶卡片 + 只接了 5 个 projection key**。三条断层不补，单个控件补了也会“位置不对/状态不对/刷新后变样”。
2. **数据大多已经到了 iOS，但被 UI 层丢掉了。** `session/follow` 的 snapshot 已带 `projections`（官方 `history.ts:190-213`），iOS 只读 `cursor` 就关闭（`ChatModel.swift:1500-1538`）；`agent/inbox/spliced` 已经映射成 `Kind.inboxSpliced`（`DSHEventMapper.swift:67-73`），却在 `ChatModel.handle` 里直接 `break`（`ChatModel.swift:1719-1721`）；历史 projector 也不处理（`NativeTranscriptProjector.swift:19-146`）。**“收到新消息”实时永远不出现，杀进程重开才“凭空”出现。**
3. **事件覆盖面约 12% / 18%。** 官方 durable session 事件 **66** 个 + 1 个 live-only（`known-event-types.ts:22-84`、`events.ts:8-19`）；iOS 实时 mapper 认 **8** 个，历史 projector 认 **12** 个。事件目录不是“补几个 case”，是要建立“官方事件 → 行/卡/状态”的完整投影层。
4. **子 Agent 不是一张卡，是六件套。** 官方 = inbox 分流 + `turn-trigger` 行 + 进程组“正在协调子智能体” + 页头 breadcrumb/目录 + 子会话侧栏 + 只读 composer（`ui-subagent`、`message.ts`、`inbox.ts`、`ChatGroupSeat`）。iOS **六件套一件都没有**；唯一列出子 Agent 的 `SessionActivityPage` 还是**不可达死页面**（`ChatPage.swift:51,292` 的 `showActivity` 从未置 true）。
5. **“计划”有两层，iOS 两层都没有。** ① TodoPanel（composer 上方任务条，官方 `TodoPanel.tsx:65-118`）——iOS 无；② Plan mode chip / plan review / 已提交计划卡（`PlanModeControl.tsx:19-70`、`PlanReviewPanel.tsx:29-91`、`PlanCard.tsx:43-60`）——iOS 无。iOS 反而把 `"plan"` 当成一个**权限档位**翻成“只出方案”（`ChatModel.swift:119`），而官方权限档位里没有 plan。
6. **“提问”不只一张待答卡。** 官方 = composer 接管（分页、推荐、跳过、收起、倒计时、只读 review）+ 已回答工具行 + `question-reply` 右对齐气泡 + plan review 分流（`QuestionComposer.tsx`、`QuestionReplyView.tsx`、`ask-question-row.tsx`）。iOS = 页顶一张蓝色 `QuestionCard`（`ChatPage.swift:2139-2245`），答完什么都不留；迟到的回答被当成“上下文注入”显示**原始 JSON**。
7. **Turn 时间线不是消息列表。** 官方每轮有 `turn-process` 控制行（33pt，“已完成，用时 …”/“已停止”/“处理失败”）、过程分组（组头分类摘要、6pt 行距、400pt 上限、24pt 渐隐）、运行态鲸鱼计时、turn-tail 动作行（`TurnProcessNodeView`、`ChatGroupSeat`、`RunningStatus`、`TurnTailNodeView`）。iOS 只有“连续工具折成一个 VStack”，没有轮级折叠/完成行/运行时钟。
8. **工具卡是 54 vs 7。** 官方 shipped web-app 注册 **54 个 `tool.call.toolview` key**（37 个 DetailsRow + bash/read/read_image/search/web/todo/ask/skill/present/cordis 等），iOS 只有 7 个 variant + 6 条标题特判。更严重的是：实时 `tool/result` **不写 `meta`**（只有历史 projector 写），所以同一个工具调用“运行时是通用 IN/OUT，刷新后才变专用卡”（`DSHEventMapper.swift:108-116`、`ChatModel.swift:1731-1752`、`NativeTranscriptProjector.swift:95,107`）。
9. **像素差异是系统性的，不是零散 1pt。** 官方内容列宽 **338pt**，iOS **370pt**（`ChatView.module.css:26-28` vs `ChatPage.swift:799`）；官方 assistant 正文 **14/24**，iOS 14 自然行高 ≈17（`AssistantMarkdown.module.css:12-13` vs `NativeMarkdownBody.swift:57-62`）；官方用户气泡 `#EDF3FE`/20 圆角/10×16 内距/最大 277，iOS `#F2F3F5`/22/12/296（`MessageItem.module.css:22-40` vs `ChatPage.swift:2331-2345`）；官方 composer 370×98/圆角 **28**，iOS 370×94/圆角 **22**。
10. **两个“代码在、数据恒 nil”的字段路径 bug：** goal 读 `values.goal.current.goal`，官方 wire 是 `values.goal.goal`（`DSHRemoteHarness.swift:103-115` vs `goal/index.ts:163-169`）；会话标题读 `values.title.title`，官方是字符串 `values.title`（`DSHManagementModel.swift:906`）。**按当前 wire 形状，GoalBar 恒 nil；标题一直用本地猜的名字。**
11. **审计基线本身有缺口：仓库里没有官方 402pt 截图。** `docs/receipts/ios-baseline-screens/ios-chat-official.png` 经 04/05/06/08 四份报告与 `INDEX.md:77` 互证，是 iOS `-uiPreview chat.official` 的自绘页（transcript 空白），不是官方 Web。[01](01-data-path.md) 与 [02](02-plan-todo.md) 的 §1 把它称作“官方页”，应以此处纠正为准。所有官方像素值是 **CSS/TSX 静态解析**，不是实测。要做“近像素级”，第一步必须补一套官方 402×874 golden 截图。
12. **规模：** 8 份轴报告（01–08）合计 **P0 38 / P1 79 / P2 64 / P3 14**（含跨轴重复）；去重后本 master 收敛为 **24 条 P0**、**18 类 P1 热点**。09 设计 token 未独立成文，关键值已由 05–08 的逐组件规格汇总到 §6。建议按“数据地基 → 会话核心 → 工具/内容 → 像素收尾”四波推进。
13. **脚本补扫（2026-11-01）：** `scripts/ios-parity/audit.py` 独立扫描官方注册表，确认 **20/20 chat node kind、54/54 toolview key 都被 01–08 报告按名字覆盖**；但发现 **1 个整块漏项 + 1 组 header 控件漏项**：① `conversation.view` 的 **「对话 / 轨迹」双 tab + Trajectory view**（iOS 有 trajectory 数据与死代码 `NativeTrajectoryRow`，但没有 tab/入口）；② header 的 `agent-preset` / `job-list` / `schedule-catalog` / `open-in-app` / `session-log-download` / `sidebar-right corner`（08 只审了槽位几何，没有逐个审贡献控件；`agentPreset` projection 未被任何报告提到）。这两项是 P1/P2，不改变 24 条 P0，但需补进 Wave 2/3 与验收矩阵。详见 [09-scanner-gaps.md](09-scanner-gaps.md)。

---

## 1. 审计范围、基线与方法

### 1.1 基线

| 项 | 值 |
|---|---|
| 官方仓 | `/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness` |
| 官方 commit | `7be5505b0be06009d74891c869063c9cf19a0df0`（`0.2.1-rc.2`） |
| shipped 组合 | `packages/bundle/web-app/cordis.patch.yml`；`packages/experimental/*` 不计入默认随附 |
| iOS 仓 | `/Users/leilangsheng/Desktop/TonoTeam/phone-dsh` |
| iOS 入口 | `examples/probe-app/PhoneDSHProbe/ChatPage.swift`、`ChatModel.swift`、`NativeTranscriptProjector.swift`、`NativeConversationModels.swift` |
| 数据层 | `Sources/PhoneDSHAgentCore/{AgentHarness.swift,DSH/*}`、`plugins/{channel,worker-entry,surface-phone}`、`Sources/PhoneDSHGateway` |
| 视觉基准 | 402×874pt，`ui-mobile` 断点 `<640px` |

### 1.2 方法

- 8 条轴并行成文：01 数据链路、02 计划/Todo、03 提问、04 子 Agent/inbox、05 Turn 时间线、06 工具卡、07 消息内容/动作、08 Composer/页头；09 设计 token 未独立成文（token 值已由 05–08 的逐组件规格 + 本 master §6 覆盖）。
- 每条轴都要求：官方 + iOS 双侧 `file:line`、缺失的穷尽搜索证据、402pt 像素合同、数据依赖、实施建议、验收方式。
- 官方行为优先用 **源码 + 官方测试/golden** 取证；截图只作佐证。
- 8 份报告落盘后，再用 `scripts/ios-parity/audit.py` 独立扫官方注册表（20 node / 54 toolview / 35 slot / 29 projection / 23 surface / 405+193 token），复核“报告有没有整块漏项”。结果见 [09-scanner-gaps.md](09-scanner-gaps.md)。
- 审计阶段未修改源码；实施阶段的变更、构建与截图见 [10-wave0-implementation.md](10-wave0-implementation.md)。

### 1.3 基线证据缺口（必须先补）

- **没有官方 402pt 截图。** 四份独立报告（04 §1、05 §1、06 §1、08 §0）与 `INDEX.md:77` 都确认 `ios-chat-official.png` 是 iOS `chat.official` 预览页。官方像素值全部来自 CSS 计算。
- **没有官方 402pt 长会话 fixture**（含 tool/plan/question/subagent/stop）。现有 iOS baseline 截图也不覆盖提问、计划、子 Agent、turn 折叠。
- 因此“近像素级”验收目前只能做“源码值对齐”，不能做“截图逐像素 diff”。第 9 节给出补法。
- **置信度分层：** 结构性结论、缺失性结论、事件映射、字段路径 = 高（源码 + 穷尽搜索）；402pt 像素值 = 中（CSS 推导，无官方截图）；少数跨端行为 = 待实测（live host 上的 goal/title 路径、phone 通道的 `session/control`、timed question 的 `attachWait`、402pt 页头是否溢出）。

---

## 2. 五个系统性结论

### 2.1 官方是 Turn 过程模型，iOS 是平铺消息

官方一个 Turn 的可见结构（`conversation-nodes/README.md:30-41`）：

```
user input
├ turn-process 控制行（「已完成，用时 …」/「已停止」/「处理失败」；33pt + 8pt 下内距 + 0.5pt 下边线）
├ 过程区（受控制行支配）
│   ├ G1: reasoning + read + bash（组头 = 分类摘要 + 16pt leading + shimmer）
│   ├ 中间回复（独立行，但折叠时随过程一起隐藏）
│   └ G2: reasoning + run_code
├ 最终回答（保护在过程折叠之外；它的 reasoning 仍属过程）
└ turn-tail（动作/用量/计划卡/交付物/改动文件）
```

iOS 只有 `NativeTranscriptRow.item / contexts / tools` 三种行（`NativeChatTimelineChrome.swift:7-20`），`timelineRows` 只把相邻 `toolCall/toolResult` 塞进一个 `VStack`（`ChatPage.swift:453-475`），没有轮级容器、没有组头、没有完成状态行、没有运行指示。**这是最大的一处“看起来不像官方”的来源**（05 T-01…T-04，P0 4 条）。

### 2.2 官方是 composer 接管链，iOS 是页顶卡片区

官方 `conversation.composer` 是一条 **chain**（`ConversationContent.tsx:170-187`）：待审批、待提问、plan review、子 Agent 只读会话会**整条替换 composer**；`QuestionComposer`、`ApprovalPanel`、`PlanReviewPanel`、`SubagentReadOnlyComposer` 都注册在这个链上。iOS 把待审批/待提问画在**页头与 transcript 之间**的 `cardsRegion`（`ChatPage.swift:181-194, 480-551`），composer 仍然常驻但被 `disabled`（`:1604-1610`）。

后果：
- 用户视线在屏幕上方，手指在底部；长会话时要向上翻很久才看到问题（03 Q-07、08 C-05）。
- 官方的“收起/关闭/最小化/分页/倒计时”外壳全都没有。
- 审批/问题的优先级也反了：官方 plan-review(2) > question(1) > approval(0)，iOS 是 permission 压 question（03 Q-11）。

### 2.3 官方有 projection 层，iOS 有 RPC 但只接了 5 个 key

官方 `session/follow` 的 snapshot 携带 `{header, cursor, records, hasMore, projections, assistantStream}`（`history.ts:190-213`），并且有 `session/control` 逐 key 推送。iOS：
- `loadSessionHistory` 只读 `cursor` 就 `mux.close()`（`ChatModel.swift:1500-1538`）；
- `refreshNativeMetrics` 只读 `sessionStats/tokenUsage/contextPressure/contextBreakdown`（`:1881-1895`）；
- `refreshAccessModes` 只读 `permissions`（`:310-321`）；
- `DSHManagementModel.refreshActivity` 读了 `plan/todos/goal/subagentCatalog`，但那是**独立的、不可达的活动页**（`DSHManagementModel.swift:500-585`、`SessionActivityPage.swift`）。

官方 projection 里已经有：`todos`、`plan{active,pending}`、`inbox{next-step,next-turn}`、`userQuestions{active,settled}`、`subagentCatalog`、`subagentTiming`、`subagent`、`goal`、`title`、`permissions`、`modelSelection`、`tokenUsage` 等。**iOS 不需要新协议就能拿到计划/待办/子 Agent 列表/待答/队列/标题**；缺的是“订阅 + 解码 + 接进会话页”。

### 2.4 官方事件目录 66 + 1，iOS 8 / 12

官方 `KNOWN_SESSION_EVENT_TYPES` 66 个 durable + `assistant/live-chunk` 1 个 live-only（01 §0-1）。iOS mapper 处理 8 个：`user/message`、`agent/inbox/spliced`、`turn/start`、`turn/end`、`step/start`、`assistant/message`、`tool/call`、`tool/result`；历史 projector 处理 12 个。缺的包括（只列影响会话页的）：

`step/end`、`assistant/attempt`、`tool/ptc-dispatch*`、`developer/message`、`system/message`、`request/header`、`approval/asked|decided`、`plan/mode`、`todo/write`、`subagent/*`、`goal/*`、`command/run|done`、`compaction/*`（结构化字段）、`workspace/changes`、`deliverables/presented`、`job/registered|settled`、`schedule/change`、`user-question-reply`、`model/selection`、`permission/preset`、`sandbox/mode`、`approval/policy`。

这不是“多映射几个事件”的问题：官方每个事件都对应一个 Chat node / toolview / dock / trigger，iOS 需要建同构的投影层。

### 2.5 官方 54 个 toolview，iOS 7 个 variant

官方 54 个 key 分 12 个视觉族（06 §2.1）：bash、read、read_image、search（grep/glob）、web（search/fetch）、write/edit、todo、ask、subagent/team、job/schedule/goal、workflow/inspection、generic details。iOS 只有 7 个 variant，37 个 details key 一律落到“工具调用”+ 原始 IN/OUT 卡。

同时，实时链路**丢 `meta`**：`tool/result.meta` 是官方工具卡的展示载荷（diff/行号/退出码/搜索分组/web 来源），iOS mapper 不搬、`ChatModel` 不写，只有历史 projector 写。于是“同一轮对话，运行时和刷新后工具卡不一样”（06 T-01、01 DP-09）。

---

## 3. 用户点名的四条线

### 3.1 计划（Todo / Plan mode / Plan review / Plan card）

| Surface | 官方 | iOS 当前 | 严重度 |
|---|---|---|---|
| TodoPanel（composer 上方任务条） | 338×36 折叠条，圆角 16，默认折叠，可展开 `max-height 180`；`tasks` 进度 + 三态点（`TodoPanel.tsx:65-118`、`TodoPanel.module.css`） | **无**；`ChatPage` 内 `todo` 0 命中；`todos` projection 只有活动页读（`DSHManagementModel.swift:562-566`） | **P0** |
| Plan mode chip | 28pt 高、圆角 8、`#E4EDFD` 底、`#4176E6` 字；`plan{active,pending}` 为真时显示；点 = `/plan off`（`PlanModeControl.tsx:19-70`） | **无**；只有 `"plan"` → “只出方案”的假权限档映射（`ChatModel.swift:119`） | **P0** |
| Plan review | `intent.kind='plan-review'` 的单条提问 → `PlanReviewPanel` 接管 composer：338 宽、圆角 20、琥珀 strip「计划待审」、标题/描述、`要求修改` + `同意执行` 36pt 按钮（`PlanReviewPanel.tsx:29-91`） | 被降级成通用 `QuestionCard`；`header/detail/intent` 在事件映射处丢失，**计划正文看不到**（`DSHRemoteHarness.swift:410-422`） | **P0** |
| 已提交计划卡 | turn tail 60pt 卡：40×40 markdown 图标、标题 13/20、副标题 10/16、右侧“打开”；点开右栏/手机全宽抽屉 Markdown 预览（`PlanCard.tsx:43-60`） | **无**；`exit_plan_mode` 没有特判 | **P0** |
| `todo_write` 工具行 | 折叠行 `更新任务清单 · 1/3 已完成 · 当前项` + `+N`；展开差异卡（新增/更新/移除/顺序）（`todo-row.tsx`、`todo-diff-model.ts`） | 通用行，summary 退化成 `todo_write` 原始工具名 | P1 |

**结论**：计划线 4 条 P0，且数据侧 `todos/plan` 已经在 `session/projections` 里，属于“接上就能做”的部分；plan review/card 依赖 question 数据和 `exit_plan_mode` 参数，也已具备。

### 3.2 提问（ask_user_question）

| Surface | 官方 | iOS 当前 | 严重度 |
|---|---|---|---|
| 待答 composer | 接管 composer：338 宽、圆角 20、`max-height min(60vh,520)`；分页 `1/N`、推荐项、跳过、收起/关闭、倒计时/慢慢回答、提交中/失败重试（`QuestionComposer.tsx`） | 页顶 `QuestionCard`（370 宽、蓝底 9%、无圆角/阴影、单行 TextField、无分页/跳过/收起/倒计时）；composer 仅 disabled（`ChatPage.swift:2139-2245`） | **P0** |
| 已回答 | 工具行 `提问 · 1/1 已回答` + `查看回答` 只读面板 + 问答卡（`ask-question-row.tsx`） | 通用行；只有原始 IN/OUT | **P0** |
| 迟到回复 | 右对齐 `question-reply` 气泡：`max-width 72%`、10×16、圆角 20、`#EDF3FE`、可展开答案/时间/复制（`QuestionReplyView.tsx:30-105`） | 被分类为“上下文注入”，展开是**原始 JSON** | **P0** |
| 数据字段 | `header/detail/options[].description/intent{kind,approve,callId}/wait{callId,timed}/state` | `HarnessQuestionItem` 只有 id/prompt/options(String)/multiple（`AgentHarness.swift:298-327`） | **P0** |
| 优先级 | plan-review(2) > question(1) > approval(0)，多张卡可轮换 | permission 压 question；`pendingQuestion` 单值覆盖，后来的问题顶掉前一个 | P1 |

**结论**：提问线 5 条 P0。最刺眼的是“答完不留痕”和“迟到回答显示 JSON”。

### 3.3 子 Agent（运行状态 / 目录 / 子会话 / 工具）

官方六件套：

1. **inbox 分流**：`agent/inbox/spliced` 的 next-step/next-turn claim → user / steering / context / turn-trigger（`inbox.ts:79-134`、`message.ts:62-120`）。
2. **turn-trigger 行**：子任务完成 `source.kind='subagent-settled'` → “子任务状态更新”卡（`TurnTriggerNodeView.tsx:29-58`、`turn-trigger.ts:21-70`）。
3. **进程组标题**：`subagent/subagent_*` 计入 subagent 类，运行中“正在协调子智能体”、完成“已协调子智能体”（`process-activity.ts`、`ChatGroupSeat.tsx`、`turn-process.ts:44-49`）。
4. **页头 lineage/catalog**：父/子 breadcrumb（子 crumb 12/18）、`N 个子智能体` 目录按钮、运行中 14pt 转圈点、树形 popover（`ConversationSession.tsx:25-130`、`SubagentHeaderLineage.tsx:497-720`）。
5. **子会话侧栏**：`dsh-resource://subagentchat/...` 右栏 chat（手机 = 全宽抽屉）（`ui-subagent/sidebar-chat`）。
6. **只读 composer**：one-shot / parent-unavailable / unknown 三态（`SubagentReadOnlyComposer.tsx`）。

iOS 当前：
- `agent/inbox/spliced` 实时 `break`，历史不投影 → **子 Agent 完成/发消息实时完全不可见**（`ChatModel.swift:1719-1721`、`NativeTranscriptProjector.swift:19-146`）。
- 没有 turn-trigger 行；没有进程组 subagent 计数/标题。
- 页头只有 44pt 标题 + 状态点 + 更多菜单，没有 breadcrumb/catalog（`ChatPage.swift:113-171`）。
- `subagentCatalog` 只在不可达的 `SessionActivityPage` 里读（`DSHManagementModel.swift:575-580`）。
- `subagent` 工具行只有标题“子 Agent”，`send_message/list_agents/interrupt_agent` 全部通用“工具调用”（`NativeToolCallModel.swift:44-63`）。
- 没有子会话地址/`kind:'subagent'` follow；`parentSessionId` 解码后只用于 interrupt（`DSHManagementModel.swift:918`）。

**结论**：子 Agent 线 7 条 P0，是四条里缺口最大的一条；但数据侧 `subagentCatalog` 已可读，缺 `subagentTiming`/`origin`/`activity` 三个目录字段和子会话寻址。

### 3.4 收到新消息（inbox / turn-trigger / steering）

官方语义（重要，避免做错）：

- **不是所有非人类消息都可见。** 官方把 `user/message.source.kind != 'user'` 的消息分成：
  - 被 `next-turn` claim（唤醒新一轮）→ **turn-trigger 卡**（可见）；
  - 运行中 `next-step` 且是 idle steer → **turn-trigger/steering**；
  - 其余注入到运行中的 Turn → **普通 context**，`isVisibleChatNode` **默认不显示**（只有 tool-addition/removal 的 context 才显示）（`chat-visibility.ts:10-19`、`message.ts:120-152`）。
- **官方没有站内未读红点/角标。** `grep unread` 无命中；只有“回到底部”和 PWA push（`ui-mobile/src/client/push.ts`）。不要发明未读红点。
- 可见的“新消息”主要是：`subagent-settled` → “子任务状态更新”；`goal` → “继续执行目标”；`schedule` → “自动化任务”；`tool-jobs` → “后台任务状态更新”；`agent-message` → “收到任务消息”（experimental team 不随附）；`webhook` → “收到外部事件”；`cordis-host-runner` → “插件状态更新”；未知 → “收到执行请求”（`turn-trigger.ts:21-70`、`locale.ts:52-63`）。
- turn-trigger 卡规格：`#F9FAFB` 底、0.5pt 边、圆角 20、header `12/16`、icon 14、title 14、time 12/18 右对齐、chevron 12、body `0 16 12 40`、说明 12/18 `#61666B`、正文 12/18 可滚 `max-height 240`（04 SB-02）。

iOS 当前：
- 实时 `user/message` 整体 `break`；`inboxSpliced` 也 `break`（`ChatModel.swift:1719-1721`）。
- 历史里非 user 消息被归成“DSH context · source”，聚合为“上下文 · N 条”，展开是原始文本/JSON；没有 turn-trigger、没有时间、没有解释、没有 source 中文名（`NativeChatTimelineChrome.swift:22-66`、`NativeTranscriptProjector.swift:20-45`）。
- 没有 inbox claim 表，无法区分“唤醒”与“注入”；因此即使强行显示也会画错形态。
- 没有 steering 行；本地“已排队/发送中/已并入当前任务”只是行内小标签（`ChatModel.swift:2107-2123`）。

**结论**：新消息线 4 条 P0（inbox 状态机、实时 user/message、turn-trigger 行、steering 行），且是“计划/子 Agent”多条线的共同地基。

---

## 4. 去重后的 P0 清单（24 条）

> 编号是本 master 的；括号内是各轴原始 ID。完整像素/行为合同见对应轴报告。P0 = 官方有、iOS 完全没有入口/状态，或关键交互不可用。

| ID | 主题 | 差距 | 关键证据 | 轴 |
|---|---|---|---|---|
| M-P0-01 | 数据地基 | `session/follow` snapshot 的 `projections` 被整块丢弃；无 `session/control` 订阅；66 事件只认 8/12 | 官方 `history.ts:190-213`；iOS `ChatModel.swift:1500-1538,1719-1721`；`DSHEventMapper.swift:61-110` | 01 DP-02/DP-13/DP-16 |
| M-P0-02 | 新消息 | 实时 `user/message` 与 `agent/inbox/spliced` 被丢弃；非人类输入/子 Agent 消息实时不可见 | `ChatModel.swift:1719-1721`；`NativeTranscriptProjector.swift:19-146` | 01 DP-03、04 SB-01/03 |
| M-P0-03 | 新消息 | 无 turn-trigger 行（10 种来源的标题/图标/时间/展开 body/解释文案） | 官方 `TurnTriggerNodeView.tsx:29-58`；iOS 0 命中 | 04 SB-02、07 C-02 |
| M-P0-04 | Turn | 无 Turn 容器、过程折叠、完成状态行（“已完成/已停止/处理失败”） | 官方 `TurnProcessNodeView.tsx:10-61`、`.css:1-18`；iOS 0 命中 | 05 T-01/T-04 |
| M-P0-05 | Turn | 无过程分组（组头分类摘要、6pt 行距、400pt 上限、24pt 渐隐、subagent 计数） | 官方 `ChatGroupSeat.tsx:115-202`、`.css`；iOS `ToolRunRow` 只是 VStack | 05 T-02、04 SB-04 |
| M-P0-06 | Turn | 无运行指示（鲸鱼 14 + “深度求索中，用时 …”12/22 + shimmer + 0.5pt 分隔线） | 官方 `RunningStatus.tsx:20-40`；iOS 仅 composer spinner | 05 T-03 |
| M-P0-07 | 计划 | 无 TodoPanel（338×36、圆角 16、默认折叠、`max-height 180`） | 官方 `TodoPanel.tsx:65-118`；iOS 0 命中 | 02 PLAN-01、08 C-01 |
| M-P0-08 | 计划 | 无 Plan mode chip/入口/退出；`"plan"` 被误当权限档 | 官方 `PlanModeControl.tsx:19-70`；iOS `ChatModel.swift:119` | 02 PLAN-02、08 C-02 |
| M-P0-09 | 计划 | Plan review 降级为通用提问卡，计划正文丢失；composer 未接管 | 官方 `PlanReviewPanel.tsx:29-91`；iOS `ChatPage.swift:2139-2245` | 02 PLAN-03、03 Q-06 |
| M-P0-10 | 计划 | 无已提交计划卡（turn tail）与计划预览 | 官方 `PlanCard.tsx:43-60`；iOS 0 命中 | 02 PLAN-04 |
| M-P0-11 | 提问 | 待答卡不是 composer 接管；无分页/推荐/跳过/收起/关闭/倒计时/失败重试 | 官方 `QuestionComposer.tsx`；iOS `ChatPage.swift:2139-2245` | 03 Q-03/04/07、08 C-05 |
| M-P0-12 | 提问 | 已回答问答在 transcript 完全缺失；迟到回复显示原始 JSON | 官方 `ask-question-row.tsx`、`QuestionReplyView.tsx`；iOS `NativeTranscriptProjector.swift:20-45` | 03 Q-01/02、07 C-12 |
| M-P0-13 | 提问 | 数据字段丢失：header/detail/options[].description/intent/callId/wait/state | `AgentHarness.swift:298-327`；`DSHRemoteHarness.swift:410-422` | 03 Q-05、01 DP-04 |
| M-P0-14 | 子 Agent | 无页头 breadcrumb / catalog / 子会话导航 / 侧栏 chat | 官方 `ConversationSession.tsx:25-130`、`SubagentHeaderLineage.tsx:497-720`；iOS `ChatPage.swift:113-171` | 04 SB-05、01 DP-05/DP-17 |
| M-P0-15 | 子 Agent | 无子 Agent 运行状态（进程组标题/计数/shimmer）；工具行只有“子 Agent”/“工具调用” | 官方 `process-activity.ts`、`details-row.tsx`；iOS `NativeToolCallModel.swift:44-63` | 04 SB-04/SB-07 |
| M-P0-16 | 子 Agent | 唯一子 Agent 列表 `SessionActivityPage` 不可达；无 running/时长/tokens/进入子会话 | `ChatPage.swift:51,292`；`SessionActivityPage.swift:66-82` | 04 SB-06 |
| M-P0-17 | 工具 | 实时 `tool/result` 丢 `meta` 和 `error.code`，实时/历史卡片不一致 | `DSHEventMapper.swift:108-116`；`ChatModel.swift:1731-1752`；`NativeTranscriptProjector.swift:95,107` | 06 T-01、01 DP-09 |
| M-P0-18 | 工具 | 无嵌套 subcall（`tool/ptc-dispatch*` / 父子缩进轨） | 官方 `ToolCallTree.tsx:61-102`；iOS 0 命中 | 06 T-02、01 DP-14 |
| M-P0-19 | 工具 | 无 preparing 行（参数流式到达时先出现一行；`{KB}` 后缀） | 官方 `tool.ts:60-95`；iOS `.preparing` 无赋值、live `tool-call-delta` 被丢 | 06 T-03、01 DP-18 |
| M-P0-20 | 工具 | 37 个 Details 工具卡（goal/schedule/job/subagent/team/terminal/session/lsp/workflow/cordis）全部退化为 IN/OUT | 官方 `details-row.tsx:79-116`、`ToolDetails.tsx`；iOS `NativeToolDetailCards.swift:37-71` | 06 T-04 |
| M-P0-21 | 内容 | 用户/助手图片被画成文件 chip，无缩略图网格/灯箱 | 官方 `MessageImage.tsx`；iOS `ChatPage.swift:2264,2278-2279` | 07 C-01 |
| M-P0-22 | 审批 | 审批只在一次连接里；无 durable `approval/asked|decided` 行/关联详情；未接管 composer | 官方 `ApprovalPanel.tsx`、`user-approval/types.ts`；iOS `DSHRemoteHarness.swift:403-409` | 01 DP-06、08 C-05 |
| M-P0-23 | 队列 | Queue dock 是“从 transcript 标签拼出来的假队列”；无 inbox 投影/编辑/删除/插话/附件；`SessionQueuePage` 也不可达 | 官方 `QueueDock.tsx:105-140,236-319`；iOS `ChatPage.swift:1103-1132`、`SessionsPage.swift:99,350` | 08 C-04、01 DP-01 |
| M-P0-24 | 页头/空态 | 无空白会话 hero（fish 34×25 + 26/32 标题 + 预览徽 + workspace chip + 52pt 输入） | 官方 `EmptyHero.tsx:38-62`；iOS 0 命中 | 08 C-03 |

**未列入 P0 但必须尽快修的两个字段路径 bug：**

| ID | 问题 | 证据 | 影响 |
|---|---|---|---|
| M-BUG-01 | goal 读 `values.goal.current.goal`，官方是 `values.goal.goal` | `DSHRemoteHarness.swift:103-115` vs `goal/index.ts:163-169` | GoalBar 恒 nil，`/goal` 建了也看不到 |
| M-BUG-02 | title 读 `values.title.title`，官方是字符串 `values.title` | `DSHManagementModel.swift:906` vs `session-title/src/types.ts:86-92` | 会话标题永远用本地猜名 |

---

## 5. P1 热点（20 类，不是全部）

| # | 主题 | 差距 | 关键值 |
|---|---|---|---|
| P1-01 | 正文排版 | assistant 正文行高不足；官方 14/24，iOS 14 自然行高 ≈17 | 需 `lineSpacing(24-17)` 或自绘固定行高（07 C-15） |
| P1-02 | 内容列宽 | 官方 338pt，iOS 370pt；transcript 左右各 32 vs 16，顶部 16 vs 22，底部 16+composer vs 48 | 05 T-15、07 C-16、08 C-25 |
| P1-03 | 用户气泡 | 官方 `#EDF3FE`/20 圆角/10×16/最大 277；iOS `#F2F3F5`/22/12/296 | 07 C-14 |
| P1-04 | Composer 几何 | 官方 370×98/圆角 28/padding-top 8/gap 12/发送键 34 行内；iOS 370×94/22/4pt/浮层 | 08 C-07/C-19 |
| P1-05 | 页头 | 官方 50pt、标题 14/20 500 左对齐、0.5pt 底边、四段槽位；iOS 44pt、17/600 居中、可点改名、无面包屑 | 08 C-06/C-18 |
| P1-06 | 输入 | 官方手机 16px、Enter 发送、Shift+Enter 换行、`enterkeyhint=send`；iOS 14pt、回车换行 | 08 C-11/C-12 |
| P1-07 | 控制行顺序 | 官方手机：`+` → plan → model → send → access mode（最右）；iOS：`+` → access → model → 浮层 send | 08 C-08 |
| P1-08 | 发送/停止 | 官方同一个 34 蓝圆，空草稿才显示停止；iOS 灰 24 停止 + 蓝 34 发送可能并列 | 08 C-09 |
| P1-09 | 工具行状态 | 无退出码胶囊、`+N -M`、error/stopped 语义色；标题/图标 37+ 个不对 | 06 T-07/08/09/14/15 |
| P1-10 | 工具卡几何 | 圆角 12 vs 16、描边 `#E4E4E8` vs `rgba(0,0,0,.04)`、代码 12 vs 11、卡底 `#F6F6F8` vs `#F9FAFB` | 06 T-12/T-13 |
| P1-11 | Read/Search/Diff 折叠 | 无 banner、无 8/9 行折叠、无“…其余 N 行” | 06 T-16 |
| P1-12 | 特殊行 | system-prompt/command/compaction/model-retry/turn-error/max-tokens/unknown/workflow-run/submitted-plan 全部无等价行或坍缩成 systemEvent | 07 C-03…C-09 |
| P1-13 | 上下文行 | 官方默认隐藏普通 context；iOS 聚合显示“上下文 · N 条”，且 source 中文名只认 5 个不存在的 kind | 07 C-11、01 DP-15 |
| P1-14 | 消息动作 | 无 branch（`session/fork`）、无 feedback dialog（点踩直接提交）、share 为 iOS 自加；官方顺序 复制→反馈→分支→用量→时钟 | 07 C-19/C-22 |
| P1-15 | 错误/停止 | `aborted/interrupted` 历史无行，实时/历史工具状态不一致；错误无 code | 05 T-04、06 T-10、01 DP-12 |
| P1-16 | Stats/Context | 官方 12/13pt、264 宽定位面板、三段色条；iOS 统一 11pt、medium sheet、无三段条 | 08 C-15/C-16/C-27 |
| P1-17 | Slash/@ 菜单 | 官方锚定浮层、分组、键盘高亮、滚动/骨架；iOS 是流内块，会顶起 transcript | 08 C-13 |
| P1-18 | 附件 | 官方卡内 64×64 缩略图 + 18 删除钮；iOS 卡上方胶囊 + 44 热区 + 仅图片 | 08 C-14 |
| P1-19 | 会话视图 tab | 官方页头下方有「对话 / 轨迹」双 tab（`ui-trajectory` shipped）；iOS 曾实现后按产品决策移除（D-04），轨迹数据保留无入口 | 09b §2 / DECISIONS D-04 |
| P1-20 | Header 贡献控件 | 08 只审了 header 槽位几何，未逐个审 `agent-preset` / `job-list` / `schedule-catalog` / `open-in-app` / `session-log-download` / `sidebar-right corner`；`agentPreset` projection 未被任何报告提到 | 09b §3 |

---

## 6. 像素基线（402pt；官方值来自 CSS/TSX 静态解析）

### 6.0 基线原则（本项目的硬约束）

- **字体大小、行高、字重、间距、圆角、颜色，一律以官方远程（shipped web-app 的 CSS/TSX 解析值）为准**；iOS 现值只作为“偏差对照”，不作为设计依据。
- 只有当官方**没有手机端等价实现**时（深色模式、Dynamic Type/字号设置、PWA push、未读红点、Android 系统返回手势等），才允许做产品决策，并在报告里显式标注“设计决策/增强”，不能混入“对齐”。
- 远程值里带 `--dsh-content-font-size` / `--dsh-content-font-delta` 的组件（正文、用户气泡、工具行、turn 控制行等）要保留官方同款“字号设置整体缩放”的机制；iOS 不能只抄默认 14/24 而把缩放轴丢掉。
- 官方值是 CSS px，402pt 视口下 1 CSS px = 1 pt；不要按 @3x 再乘一次。

### 6.0.1 字体/排版远程值速查

| 场景 | 远程值（默认 402pt） |
|---|---|
| assistant 正文 | 14 / 24，块间距 16 |
| 用户气泡 | 14 / 22，padding 10×16，圆角 20 |
| 工具行标题 / summary | 13 / 24（secondary tier） |
| Turn 控制行 | 14 / 24，33pt 高（含 8pt 下内距） |
| 运行指示 | 12 / 22，`rgb(52,94,186)` |
| Composer 草稿 | 14 / 24；手机端 `ui-mobile` 强制 16px |
| 代码块 | 11 / 19（小号 11/16） |
| Transcript 内容列 | 338pt（左右各 32） |
| Composer 卡 | 370×98，圆角 28 |
| 页头 | 50pt，标题 14/20 w500 |
| 行间距 | 6 默认 / 12 response / 16 turn 边界 |
| 圆角阶梯 | 4 / 8 / 12 / 16 / 20 / 28 |

### 6.1 全局 token（官方 light / dark）

| Token | 官方值 | iOS 当前 | 判定 |
|---|---|---|---|
| `label-primary` | `#0F1115` / `#F9FAFB` | `#111114` / `#F4F4F5` | 偏亮/偏灰 |
| `label-secondary` | `#61666B` / `#CFD3D6` | `#66666B` / `#A1A1AA` | 偏亮 |
| `label-tertiary` | `#81858C` / `#ADB2B8` | `#9A9AA2` / `#81858C` | **明暗近似互换** |
| `label-caption` | `#ADB2B8` / `#81858C` | `#ADB2B8` / `#81858C` | ✅ |
| `specific-bubble` | `#EDF3FE` / `#2C2C2E` | `#F2F3F5` / `#343437` | 色相错 |
| `specific-input-major` | `#FFFFFF` / `#2C2C2E` | `#FFFFFF` / `#242426` | 暗色偏黑 |
| `specific-selector` | `#F5F6F7` / `#353638` | `#F2F3F5` / `#343437` | 近似 |
| `state-error-primary` | `#EC1313` / `#F25A5A` | `#C0392B` / `#F07568` | 偏暗 |
| `state-success-primary` | `#22C55E`（两主题） | `#27865A` / `#55B986` | 偏暗 |
| `state-warn-label` | `#DD8629` | `#B45309` | 偏暗 |
| radius | 4 / 8 / 12 / 16 / 20 / 28 | 4/8/10/12/16/20/22 混用 | 缺 28/20 体系 |
| 字体 | 系统栈（`-apple-system` + PingFang） | `.system` | ✅ 栈一致 |
| 代码字体 | SF Mono/JetBrains 11/19 | `.monospaced` 12 | 大 1pt、行高不同 |

### 6.2 关键组件（官方 vs iOS）

| 组件 | 官方 402pt | iOS 当前 | 差距 |
|---|---|---|---|
| Transcript 内容列 | 338pt（左右各 32） | 370pt（左右各 16） | **+32pt** |
| Assistant 正文 | 14/24 | 14 / ~17 | 行高 **−7pt** |
| 用户气泡 | `#EDF3FE`、圆角 20、padding 10×16、max 277、14/22 | `#F2F3F5`、22、12、max 296、14/24 | 色/尺寸/圆角 |
| Composer 卡 | 370×98、圆角 28、padding-top 8、gap 12 | 370×94、圆角 22、4、gap 9 | **−4pt / −6 圆角** |
| 发送键 | 34 圆，控制行内，`#3964FE` | 34 圆，浮层右下，`#3964FE` | 位置 |
| 页头 | 50pt、标题 14/20 500、左对齐、0.5pt 底边 | 44pt、17/600 居中、无底边 | **−6pt / +3pt 字号** |
| 工具行 | 24pt、16 盒+6、13/24、2×2+8、13/24 | 同几何 | ✅ 骨架；tertiary 色差 |
| Turn 控制行 | 33pt（含 8pt 下内距）、0.5pt 下边线、14/24、chevron 14 | 无 | 整行缺失 |
| Running 指示 | 12/22、`rgb(52,94,186)`、鲸鱼 14、shimmer 1.5s steps(48)、0.5pt 分隔线 | 无（仅 spinner） | 整行缺失 |
| TodoPanel | 338×36、圆角 16、13/24 + 13/20、列表 180 | 无 | 缺失 |
| Question 卡 | 338、圆角 20、max-height min(60vh,520)、选项 40 行 | 370、无圆角、蓝底 9%、选项 44 | 体系不同 |
| Plan review | 338、圆角 20、strip `#FEF5E7`、title 15/22、按钮 36 | 无 | 缺失 |
| Turn trigger | 338、圆角 20、`#F9FAFB`、header 12/16、title 14、body 12/18 | 无 | 缺失 |
| 代码块 | 圆角 16、header 11/18、`pre` 11/19、banner `#F9FAFB` | 圆角 12、12pt、banner `#E9E9ED` | 偏差明显 |
| Stats | 12/13pt、264 面板、三段色条 | 11pt、medium sheet、无三段条 | 密度/交互 |

> 所有官方值都是 CSS 计算；没有官方 402pt 截图实测。`ios-chat-official.png` 是 iOS 预览页，不能用作官方基线。

---

## 7. 数据链路修复清单（按依赖排序）

### 7.1 先修“数据真相”

1. **修 goal/title 字段路径**（M-BUG-01/02）：`values.goal.goal`、`values.title` 字符串。
2. **在 `ChatModel` 增加 projection store**：从 `session/follow` snapshot 的 `projections` 读 `todos/plan/inbox/subagentCatalog/subagentTiming/subagent/userQuestions/goal/title`；订阅 `session/control` 或至少在一次 `session/projections` 调用里读全 key。
3. **统一实时/历史分类器**：`user/message` 的 source（kind/form/summary）、`inboxSpliced` 的 target/id、`tool/result` 的 meta/error.code、`turn/end` 的完整 reason。
4. **补 live 帧**：`tool-call-delta`/`block-start`/`block-end` → preparing 行；`assistantStream` baseline 回填；`step/end`。
5. **补事件族**：`tool/ptc-dispatch*`、`approval/asked|decided`、`plan/mode`、`todo/write`、`subagent/*`、`command/run|done`、`compaction/*` 结构字段、`workspace/changes`、`deliverables/presented`、`job/schedule`、`user-question-reply`、`surfaceOp/sourceEventSeqs` 替换语义。
6. **子会话寻址**：`HarnessSubagentAddress{parentSessionId,childSessionId,mode}`；`follow/page` 用 `kind:'subagent'` 地址，不能当普通 session。
7. **timed question**：`userQuestions.attachWait` 等价调用 + deadline/countdown；否则 `mode:'timed'` 的问题可能根本不显示。
8. **审批关联**：`callId` → tool 详情；`approval/asked|decided` durable 行（若要“事后可查”）。

### 7.2 不需要改后端的部分

- 计划/待办/子 Agent 目录/待答/队列：官方 projection 已存在，iOS 的 `session/projections` 已能拿到；主要工作是客户端解码 + UI。
- 已提交计划卡：`exit_plan_mode` 的 args 已在 `tool/call` 里。
- 子 Agent 工具行：`tool/call` + `tool/result` 文本已够做标题/图标/详情卡（06 SB-07）。
- 大部分工具卡：`tool/result.meta` 已在 durable 事件里，只是实时路径没搬。

### 7.3 需要协议/后端确认的部分

- `session/control` 逐 key 推送在 phone Worker 通道上是否可用（官方 `control.ts:26-60`）。
- 子会话 `kind:'subagent'` 地址在 phone Worker 的 follow/page 上是否已开放（官方 `history.ts:341-392`）。
- timed question 的 `attachWait` 在 phone 的 `$events` 流里是否暴露。
- `approval/asked|decided` 是否在当前 DSH 版本随附（官方 `interaction/user-approval`）。

---

## 8. 实施波次（建议）

### Wave 0 — 数据真相 + 低风险像素（1–2 天）

1. 修 goal/title 路径（M-BUG-01/02）。
2. `ChatModel` 读 `projections` 的 `todos/plan/subagentCatalog/inbox/userQuestions`（先只存值，不画）。
3. 实时 `user/message`/`inboxSpliced` 不再 `break`：先落一条 `.context`/`.status` 占位，保证“不丢”。
4. 给 `SessionActivityPage` 一个入口（`showActivity = true` 一行），先兜住“看得到子 Agent/计划/待办”。
5. 低风险像素：transcript 侧距 32pt、assistant `lineSpacing(24-17)`、用户气泡 `#EDF3FE`/20/10×16/277、composer 圆角 28、页头 50/14-20/0.5pt 底边、tertiary `#81858C`。

### Wave 1 — 会话核心（1–2 周）

6. Turn 模型 + `turn-process` 控制行 + 过程分组 + 运行指示 + 停止/失败/four-state（05 T-01…T-04）。
7. inbox 状态机 + turn-trigger 行 + steering 行 + 新消息/来源标题（04 SB-01/02/03、07 C-02）。
8. 提问 composer 接管 + 分页/跳过/收起/倒计时 + 已回答/迟到回复 + 字段直通（03 Q-01…Q-07）。
9. 计划：TodoPanel + Plan chip + Plan review + 计划卡/预览（02 PLAN-01…04）。
10. 子 Agent：进程组计数 + 页头 breadcrumb/catalog + 子会话打开 + 四个工具行（04 SB-04/05/06/07）。
11. composer 接管链：审批/提问/plan review/子会话只读统一（08 C-05、01 DP-06）。

### Wave 2 — 工具 / 内容 / Composer 细节（2–3 周）

12. 实时 `tool/result.meta` + `error.code`；preparing；嵌套 subcall；Details 37 key（06 T-01…T-04）。
13. 工具标题/图标表 54 key、退出码、diff totals、error/stopped 色、read/search/diff 折叠、代码卡几何（06 T-05…T-16）。
14. 特殊行：system-prompt/command/compaction/model-retry/turn-error/max-tokens/unknown/workflow-run/submitted-plan（07 C-03…C-09）。
15. 图片网格/灯箱、feedback dialog、branch、queue dock、slash/@ 浮层、附件 rail（07 C-01/C-22、08 C-04/C-13/C-14）。
16. 空白 hero、stats 面板、context meter、goal bar 单行、页头四段（08 C-03/C-15/C-16/C-17/C-06）。
17. **会话视图 tab（对话 / 轨迹）**：把 `NativeTrajectoryRow` 接进 session 页；页头下加 tab strip（09b §2）。
18. **Header 贡献控件**：`agent-preset` / `job-list` / `subagent-catalog` 上页头；`agentPreset` projection 解码（09b §3）。

### Wave 3 — 像素收尾 / 验收（1 周）

19. token 统一（radius/字色/代码字体/阴影）、动效曲线、reduced motion、VoiceOver、Dynamic Type。
20. 官方 402pt golden 截图 + iOS 对照截图 + 逐像素 diff；显示模式 4 档（05 T-10）。
21. 回归：长会话分页、键盘、深色、错误/停止/压缩/重试；`schedule-catalog` / `open-in-app` / `session-log-download` / `sidebar-right` 等价物（09b §3）。

---

## 9. 验收矩阵（近像素级的可执行口径）

### 9.1 必补的官方 golden（402×874）

| # | 状态 | 要覆盖的 surface |
|---|---|---|
| G1 | 空白会话 | hero、workspace chip、52pt 输入、无 stats |
| G2 | 纯文本一轮 | user 气泡、turn 控制行、assistant 14/24、turn-tail 动作 |
| G3 | 纯工具一轮 | 组头、工具行 24pt、折叠、完成行 |
| G4 | 长过程 + 中间回复 | 组 G1/G2、中间回复、最终回答、折叠规则 |
| G5 | TodoPanel | 折叠/展开、三态点、进度文案 |
| G6 | Plan mode + plan review | chip、strip、计划正文、两个按钮 |
| G7 | 已提交计划卡 | 60pt 卡、标题、预览 |
| G8 | 提问待答 | 分页、推荐、选项、自定义、跳过/关闭 |
| G9 | 提问已回答/迟到 | 工具行 `1/1 已回答`、`查看回答`、question-reply 气泡 |
| G10 | 子 Agent 触发 | 进程组“正在协调子智能体”、`subagent-settled` trigger 卡 |
| G11 | 子会话页头 | breadcrumb、目录按钮、只读 composer |
| G12 | 停止/失败/max tokens | 控制行三态、运行指示消失、工具 stopped |
| G13 | Queue dock | 1 条/多条、折叠、编辑/删除/插话 |
| G14 | 图片 | 单图/多图 tile、灯箱、失败态 |
| G15 | 轨迹 tab | 对话/轨迹双 tab、轨迹事件序列、加载更早 |
| G16 | Header 贡献 | 子 Agent/agent preset/后台任务/定时任务/导出已接；open-in-app 记 N/A、sidebar-right 记 sheet 适配（见 DECISIONS.md） |

### 9.2 像素口径

- 尺寸/间距/圆角：目标值 ±1pt；行高 ±1pt；字号 ±0.5pt。
- 颜色：目标 RGB ±2（或 ΔE ≤ 2）；暗色另测。
- 图标：同 viewBox/线宽/14pt 盒；没有官方 SVG 的用 SF Symbol 时必须记录为“近似”。
- 文本：官方中文原文逐字；标点/全角半角/省略号一致。
- 动效：duration/easing 误差 ≤ 20ms；reduced motion 必须静态。
- 滚动：加载更早锚点 Y 位移 ≤ 1pt；跟随阈值 25pt；新消息不把读者拉走。

### 9.3 自动化

- 投影/分类器单测：`NativeProjectionDecoderTests`、`NativeMessageClassifierTests`、`NativeInboxStateTests`。
- 工具卡快照：54 key 至少覆盖 12 个族 + 37 个 Details key 的标题表。
- 真实链路 smoke：一个 turn 内 `read/bash/edit` + 一次 todo + 一次 question + 一次 subagent；断言实时与重放 `ChatItem` 逐字段相等。
- 截图 golden：官方 Web 402×874 + iOS 模拟器 402×874；用同一组 fixture/状态。

---

## 10. 未决与风险

1. **官方 402pt 实测缺失**：所有官方像素值是 CSS 推导；`title` 行高、turn-trigger 行高、手机页头是否溢出等需要 DevTools/真机确认。
2. **深色模式**：官方支持 light/dark；iOS `PhoneDSHProbeApp` 强制 `.preferredColorScheme(.light)`。是否对齐深色是产品决策（功能测试计划当前写“保持浅色”）。
3. **Dynamic Type / 字号设置**：官方有 `--dsh-content-font-size` 设置；iOS 全部固定 `.system(size:)`。若要“近像素级”，需决定是否支持官方同款字号缩放。
4. **Plan/Goal 的 activation 语义**：官方有 `activation`（armed/disarmed）与 `goal/activation-changed`；iOS 只有 phase。goal bar 的“暂停/恢复”与 disarmed 的差异需产品确认。
5. **子 Agent 目录在 402pt 的收纳**：官方 402pt 页头可能溢出（breadcrumb + catalog + jobs + menu）；若溢出，应改 bottom sheet，而不是照抄横排（04 §8-2）。
6. **`subagent_fork` 标题**：官方自身 title 表没有 `subagent_fork`，会掉到 generic；iOS 要跟随实际表现还是按语义补，需决策。
7. **PWA push**：官方站外通知依赖 PWA/推送；iOS 本地通知是否要做，超出会话页范围，另立轴。
8. **未读红点**：官方没有；不要发明。若产品坚持，需标注为增强而非对齐。
9. **402pt 下「对话 / 轨迹」tab 与 header 贡献是否同排溢出**：官方 `ui-mobile` 没有隐藏 tabs/header actions 的覆盖；402pt 需真机确认是“title 先截断”还是“actions 收进 mobile-menu”。未确认前，按“tabs 常显、header actions 可收纳”设计（09b §2/§3）。

---

## 11. 子报告索引

| 轴 | 报告 | P0 | P1 | P2 | P3 | 核心交付 |
|---|---|---|---|---|---|---|
| 01 | [数据链路与事件目录](01-data-path.md) | 6 | 12 | 6 | 0 | 66 事件覆盖矩阵、projection 修复、goal/title bug |
| 02 | [计划/Todo/Plan 模式](02-plan-todo.md) | 4 | 5 | 6 | 2 | TodoPanel/Plan chip/Plan review/Plan card 合同 |
| 03 | [提问 ask_user_question](03-questions.md) | 6 | 9 | 6 | 2 | composer 接管/分页/已回答/迟到回复/字段 |
| 04 | [子 Agent / inbox / 新消息](04-subagent-inbox.md) | 7 | 7 | 5 | 2 | 六件套、turn-trigger、lineage/catalog、claim 表 |
| 05 | [Turn 时间线](05-timeline.md) | 4 | 6 | 7 | 2 | Turn 过程/分组/运行指示/滚动 |
| 06 | [工具行与工具卡](06-tools.md) | 4 | 16 | 9 | 4 | 54 toolview 清单、meta/preparing/subcall/details |
| 07 | [消息内容/动作/Turn Tail](07-content-actions.md) | 2 | 12 | 14 | 0 | 20 node kind、Markdown/图片/动作/turn tail |
| 08 | [Composer / 页头](08-composer.md) | 5 | 12 | 11 | 2 | 4 dock、页头四段、键盘/输入、stats |
| 09 | 设计 token / 像素（未独立成文） | — | — | — | — | 值已分散在 05–08 的逐组件规格；本 master §6 汇总 |
| 09b | [脚本补扫发现](09-scanner-gaps.md) | 0 | 3 | 4 | 1 | 20/20 node、54/54 toolview 覆盖确认；新增轨迹 tab + header 贡献控件 |
| 10 | [Wave 0/1 实施回执](10-wave0-implementation.md) | — | — | — | — | 5 个并行 Agent、20 个新文件、已接线 surface、构建/截图、剩余清单 |
| — | [实施计划](IMPLEMENTATION_PLAN.md) | — | — | — | — | 并行工作流、文件所有权、集成顺序、验收 |
| — | [402pt golden 状态](GOLDEN.md) | — | — | — | — | 官方 golden 缺口、复现脚本、补齐路径 |
| — | [收口计划](CLOSEOUT_PLAN.md) | — | — | — | — | 3 路并行收口、文件所有权、验收 |
| — | [收口状态](STATUS.md) | — | — | — | — | 会话线各面状态矩阵、证据、明确不做项 |

> 阅读顺序建议：先读本 master，再按用户关心的线读 02/03/04；做实现时以对应轴的“差距清单”表为准，表里有完整 `file:line`、像素合同、数据依赖、实施建议、验证方式。
