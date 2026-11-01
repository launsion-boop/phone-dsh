# Axis 05 — Turn 时间线 / 过程折叠 / 导航 / 运行指示

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文。你只审 **transcript 的结构、分组、折叠、导航、滚动与运行指示**，不深入每个工具卡内部（Axis 06）和消息内容渲染（Axis 07），但可以引用它们。

报告路径：`docs/receipts/ios-session-audit/05-timeline.md`

## 目标

官方不是“消息列表”，而是一个有 Turn 结构、过程分组、折叠策略、显示模式、导航轨和运行指示的会话时间线。iOS 目前基本是“每条消息 + 所有工具折成一组”。请把官方这套结构完整拆出来，给 iOS 的差距与落地合同。

## 必须覆盖

### A. Turn 结构

1. 官方 Turn / Step / Exchange 的模型：`turn/start`、`step/start`、`turn/end`、`turn.status`、`reason`、`location`、`groupTree`；一个 Turn 内哪些行属于 process、哪些属于 answer、哪些是 input。
2. **`turn-process` 节点**（`conversation-nodes/turn-process.ts`、`TurnProcessNodeView.tsx` + CSS）
   - 出现条件（有过程内容、已加载 start/end、是否可折叠）
   - 标题：running 时的 live 活动（如“正在读取文件”）、completed 的时长/“已完成”、失败/停止/中断的状态；`turn-process-subagents`
   - 过程分组：reasoning / tools / intermediate replies / steering / turn-trigger 如何分段；group 边界
   - 计数：messageCount、toolCallCount、subagentCount；显示/隐藏规则
   - 展开/折叠：默认状态、手动打开、点击目标、键盘焦点、resets
3. **`turn-tail` 节点**（`turn-tail.ts`、`TurnTailNodeView.tsx` + CSS）
   - 完成后的 footer：用时、token usage、操作（复制、重试、重新生成、分支/fork?）、feedback、deliverables/plan/schedule 等 turnTail 贡献
   - 何时不显示；未加载 start 时；失败/停止时
4. **中间回复**：final answer vs intermediate assistant reply 的判定、位置、折叠时的行为
5. **Turn 导航**（`TurnNavigator.tsx` + CSS、`turn-navigation.ts`、`mergeTurnRailItems`）
   - 右侧/左侧轨道、hover/focus、当前 turn 高亮、点击跳转、未读预览、手机宽度是否隐藏/收纳
6. **Running 指示**
   - `RunningStatus.tsx`、`RunningWhaleTail.tsx`、`running-whale@2x.png`、shimmer、elapsed 计时、divider、只有 session 级一处
   - 计时规则（1s 起、60min 用小时）、reduced motion、消失时机
7. **加载更早/分页/滚动锚定**
   - “Load older”按钮位置、加载时锚定规则、折叠 group 的 anchor、滚动补偿、容量上限、`initialized` 前骨架
   - 跟随尾部（following tail）与用户上滑后的行为；“回到最新” pill（官方是否有？位置/样式/出现条件）
   - 键盘/视口变化、`overflow-anchor`、`--dsh-composer-height`
8. **显示模式与折叠时机**
   - Compact / Standard / Detailed / Verbose 的差异（process 标题、body、reasoning preview、折叠）
   - On completion / On next message；profile 设置；默认值（Desktop vs non-Desktop Web）
   - 手机宽度下的默认与行为
9. **行间距/分组间距**
   - `.flowItem` gap 6/12/16 的规则、response 边界、turn-process 边界、空 seat 不占高；iOS 的 8/12/20 对照

### B. iOS 现状

10. `NativeTranscriptRow` 只有 `.item/.contexts/.tools`；`timelineRows` 把连续 tool call/result 合成一组；`spacing(before:in:)` 的 6/8/12/20；没有 turn 概念的分组/折叠/尾部。
11. `ChatPage.transcript` 的滚动：LazyVStack、`.defaultScrollAnchor(.bottom)`、`nearBottom`/`userScrolledAway`、`scheduleTailScroll`、`回到最新` pill、`loadEarlierTranscript` 按钮、初始滚动；与官方对照。
12. 没有 TurnNavigator、没有 running whale/elapsed、没有 turn tail、没有 process 控制、没有显示模式设置。
13. 中间回复/最终回答的区分：iOS `isTurnClosingAssistant` 取该 turn 最后一条 assistant；与官方 final answer 规则对照。
14. 工具组跨 turn/跨回复是否会被错误合并？context/steering 打断时？给具体代码行。
15. iOS 的历史分页 cursor/`loadEarlierTranscript` 与官方 anchor 行为差异；是否会把用户位置弹走/空白。

### C. 像素规格（402pt）

16. Turn process 控制行（高度、字号、图标、spacing、chevron、running shimmer、completed 时间码）
17. Turn tail footer（高度、分割线、字号、按钮、usage 展示、间距）
18. TurnNavigator（宽、位置、item 高、当前态、手机端替代）
19. Running indicator（图标尺寸、文本、shimmer、divider、位置、时序）
20. 加载更早按钮/空态/骨架/“回到最新”
21. 行间距矩阵（user→assistant、assistant→tool、tool→tool、turn 边界、steering、trigger）

### D. 状态机与验收

22. 给一个 Turn 生命周期状态机：open/running/closed/completed/aborted/error/max-tokens/blocked；各状态 process 是否可折叠、tail 是否显示、running 指示是否显示。
23. 至少 10 个验收场景：纯文本 turn、纯工具 turn、思考+工具+中间回复+最终回复、折叠/展开、Verbose、On next message、加载更早、用户上滑后新消息、停止、失败、max tokens、键盘弹起。

## 参考起点

- 官方：`packages/client/ui-chat/src/client/conversation-nodes/{turn-process,turn-tail,process-groups,process-activity,turn-navigation,common}.ts`、`packages/client/ui-chat/src/client/chat/{TurnProcessNodeView,TurnTailNodeView,TurnNavigator,RunningStatus,RunningWhaleTail,use-chat-scroll,use-scroll-follow,use-chat-viewport}.tsx`、`ChatView.module.css`、`ConversationRoot.module.css`、`TurnProcessNodeView.module.css`、`TurnTailNodeView.module.css`、`TurnNavigator.module.css`
- 官方文档：`packages/client/ui-chat/src/client/conversation-nodes/README.md`（非常详细，必读）
- 官方测试：`ui-chat/tests/` 中 `turn-process*`、`turn-tail*`、`turn-navigation*`、`scroll*`、`fold*`、`presentation*`
- 官方 settings：`ui-chat/src/client/settings/*`（transcriptView/collapseTiming）、`ui-chat/src/client/presentation-policy.ts`
- iOS：`ChatPage.swift`（`timelineRows`、`spacing`、`transcript`、`ChatMessageRow`、`isTurnClosingAssistant`）、`NativeChatTimelineChrome.swift`、`NativeMessageRows.swift`、`NativeChatTheme.swift`
- 截图：`ios-chat-default.png`、`ios-chat-long.png`、`ios-chat-official.png`

不要改源码。报告中文，证据 `file:line`。完成后按 BRIEF 的 JSON schema 返回紧凑结果。
