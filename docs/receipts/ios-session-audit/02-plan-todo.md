# 计划 / Todo / Plan 模式 — iOS Session 对齐审计

> 官方基线：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`
> commit `7be5505b0be06009d74891c869063c9cf19a0df0`（`0.2.1-rc.2`，与 iOS 仓库 `plugins/dsh-pin.json:1-5` 一致）。
> iOS 端：`/Users/leilangsheng/Desktop/TonoTeam/phone-dsh`。
> 视觉基准：402×874pt（`docs/receipts/ios-baseline-screens/*.png` 为 1206×2622 @3x）；CSS px 记为 pt。
> 本报告只读源码，未修改任何文件、未跑测试/构建。所有"官方渲染结果"均来自官方 golden aria 快照与源码，非实测像素；凡属计算推导均标注"计算"。

## 0. 结论摘要

- **P0 4 条 / P1 5 条 / P2 4 条 / P3 4 条（共 17 条：PLAN-01…PLAN-17）**。计划（plan）这条线在 iOS 原生会话页上**几乎为零**：除了一条文案映射，没有任何 surface。
- **TodoPanel（composer 上方 dock）完全不存在**。官方在 `conversation.input.dock` 的 order 0 位置常驻一个「任务」条（默认折叠、可展开、`max-height:180px`），iOS 的 composer 栈里只有 goal bar 与 queued strip（`ChatPage.swift:1134-1145`）。数据侧：`todo/write` 与 `todos` projection 两边都没接（`DSHEventMapper.swift:108`、`NativeTranscriptProjector.swift:146`、`DSHRemoteHarness.swift:324-345` 丢弃 follow snapshot 的 `projections`）。
- **Plan 模式没有任何入口/状态**。官方是 composer 控制行里的一个「计划」chip（28pt 高，点按即 `/plan off`）；iOS 唯一与 plan 有关的代码是把 `"plan"` 当成一个**访问模式**翻译成「只出方案」（`ChatModel.swift:119`），而官方访问模式只有 仅可查看/工作区内修改/完全权限（+实验性自动审查），**从来没有 plan 档**（`packages/client/ui-permission-presets/src/client/locales.ts:12-14,38-40`）。人一旦在宿主侧进入 plan mode，iOS 无指示、无退出按钮。
- **Plan review 被降级成通用提问卡**。官方 `exit_plan_mode` 的提问带 `intent.kind='plan-review'`，由 `PlanReviewPanel` 接管 **composer**（不是 transcript）渲染计划审阅卡；官方 e2e 明确断言"不得落到 generic question flow"（`apps/web/tests/plan-review.e2e.ts:89-95,114-115`）。iOS 把它画成"需要你的回答"+ 单选 Approve/Keep planning + 「提交回答」（`ChatPage.swift:2139-2245`），**计划正文（`detail`）整段丢失**，且卡片位置在 transcript 上方而不是输入区。
- **已提交的计划卡（turn tail）与计划预览文档都缺失**。官方审批通过后 transcript 尾部出现 `[markdown 图标] 标题 / 计划 · Markdown / 打开` 的 60pt 高卡片（`PlanCard.tsx:43-60`），点开是右栏 Markdown 预览；iOS 无卡片、无右栏、无 sheet 承载计划全文。
- 另有一条**语义级错误**不只是缺功能：`todo_write` 与 `exit_plan_mode` 这两个工具行在 iOS 上 summary 取的是"第一个 string 参数"（`NativeToolCallModel.swift:104-105`），于是 `todo_write` 行显示 `更新任务清单 · todo_write`（内部标识上屏），`exit_plan_mode` 行显示整段计划 Markdown（官方是首行 + 工具名前缀：`工具调用 · exit_plan_mode · # Add ...`，`tool-call-model.ts:321`）。

## 1. 审计范围与方法

**官方侧（只读）**

- 计划 dock / 控件：`packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx` + `.module.css`、`ConversationRoot.module.css`（宽度轴与栈间距）、`InputBar.tsx`（`.modes` 座位）+ `InputBar.module.css`、`ui-mobile/src/client/mobile.module.css`（<640px 覆盖）。
- 状态点：`packages/client/ui-primitives/src/StateDot.tsx` + `.module.css`、`DisclosureRow.tsx/.module.css`、`Button.tsx/.module.css`、`FileTypeIcon.tsx/.module.css`、`icons/index.tsx`（`IconChecklistOutlineRegular:1127-1144`、`IconPlanOutlineRegular:1394-1406`、`IconCloseCircleFillRegular:291-298`）。
- todo 工具行：`ui-tool/.../toolviews/todo-row.tsx`、`toolviews/plan-summary.ts`、`models/todo-diff-model.ts`、`models/todo-history.ts`、`models/details-card-model.ts:33-47`、`models/tool-call-model.ts`（title/summary 推导）、`components/ToolRow.tsx` / `ToolDetails.tsx` 及两份 CSS、`locale.ts`。
- 计划：`packages/client/ui-plan/src/client/{PlanModeControl,PlanCard,PlanPreview,plan,plan-definition,plan-resource,index,locales}.*`、`ui-user-questions/src/client/{PlanReviewPanel.*,QuestionComposer.tsx,contract/slots.ts,locales.ts}`、`packages/plan/plan-mode/src/{index,types}.ts`、`packages/todo/tool-todo/src/{index,types,client}.ts`。
- 行为证据（官方测试/golden）：`apps/web/tests/plan-review.e2e.ts`、`snapshots/web/plan-review/{review,approved,approved-expanded,preview}.expected.md`、`snapshots/web/tool-details/ui.expected.md`（todo 行两种形态）、`snapshots/web/queue-actions/layout.expected.md:17-18`（TodoPanel 的 aria 形态）、`snapshots/web/lifecycle-chrome/plan-active-zh.expected.md`（plan chip 中文 aria + 它和访问模式并存）、`apps/web/tests/plan-control-row.e2e.ts` + `apps/web/tests/expected/plan-narrow-viewport/layout.expected.md`（窄行下 plan chip 不塌陷、模型文本先塌陷）、`ui-conversation/tests/todo-panel.client.spec.tsx`、`ui-tool/tests/todo-row.client.spec.ts` 系列。
- 随附性：`packages/bundle/web-app/package.json:96,146,174`（`dsh-client-ui-plan`、`dsh-plan-mode`、`dsh-tool-todo`）+ `:123`（`ui-user-questions`）；工具目录含 `exit_plan_mode` / `todo_write`（`apps/web/tests/shipped-composition.e2e.ts:480,498`）。**未把 `packages/experimental/*` 计入默认随附。**
- Token：`ui-theme/src/styles/base.css`（radius/font 族）、`design-platform.css`（颜色别名）、`gradient-shadow-text.css`（elevation/backdrop）、`focus.css`、`corner-shape.css`。

**iOS 侧（只读）**

- `examples/probe-app/PhoneDSHProbe/ChatPage.swift`（composer 1134-1240、composerControls 1296-1335、goalBar 1046-1083、queuedStrip 1103-1132、cardsRegion 480-552、QuestionCard 2139-2245、transcript 727-930、timelineRows 453-478）。
- `ChatModel.swift`（AccessModeWording 111-151、handle 1667-1780、pendingQuestion/pendingPermission 219-222）。
- `NativeToolCallModel.swift`、`NativeToolDetailCards.swift`、`NativeMessageRows.swift`、`NativeConversationModels.swift`、`NativeTranscriptProjector.swift`、`NativeChatTheme.swift`、`NativeComposerStats.swift`（经 grep 未命中 todo/plan）。
- 数据链路：`Sources/PhoneDSHAgentCore/{AgentHarness.swift,DSH/DSHEventMapper.swift,DSH/DSHRemoteHarness.swift}`、`examples/probe-app/PhoneDSHProbe/{DSHManagementModel.swift,SessionActivityPage.swift}`。
- 穷尽搜索（见 §6 与 §3 各行的"搜索证据"）：`grep -rn -i "todo"`、`grep -rn "exit_plan_mode"`、`grep -rn "计划模式"`、`grep -rn -i "planmode|plan_mode|planReview|plan/review"` 全部覆盖 `examples/ Sources/ Tests/ plugins/` 的 `*.swift`。
- 截图对照：`ios-chat-official.png`（**审计后校正：按 `INDEX.md:77`，这是 iOS `chat.official` 预览页，不是官方 Web；仅作 iOS 页头/composer/stats 佐证**）、`ios-chat-default.png`、`ios-chat-permission.png`（卡片区位置）。**截图只作佐证，不作源码事实。**

**未做**：官方 Web 实测、iOS 真机/模拟器截图、"手机 WebView 里官方 todo/plan 是否已渲染"（该 bundle 是否包含对应 client plugin 无法从静态产物断定，见 §9）。

## 2. 官方基线（按 surface 列）

### 2.1 总表

| # | Surface / 触发条件 | 官方实现（file:line） | 结构 | 像素规格（402pt） | 文案（zh） | 状态/交互 | 数据来源 |
|---|---|---|---|---|---|---|---|
| O1 | **TodoPanel 折叠态**（`todos` projection 非空时常驻 composer 上方；默认折叠） | `TodoPanel.tsx:65-100`（`useState(true)`:66；空列表 return null:67；注册 `id:'todo', order:0`:112-118） | `section[data-testid=todo-panel][aria-label]` > `.body`(flex column, gap8, padding 6px 12px) > `button.header`（`aria-expanded`）＝ [`.lead` 16×16 图标][`.title`][`.progress` flex:1][`.chevron`] | 宽 = `100% − 2×clearance − 4×dock-inset`，max-width = `card-max − 4×inset` ⇒ **402pt 下 338pt 宽，`margin:0 auto` 居中**（`TodoPanel.module.css:1-33`；clearance 16 / inset 8 见 `ConversationRoot.module.css:388-390`）。折叠高 = 24(标题行高)+12(padding) = **36pt**。圆角 `--dsw-radius-lg` = **16**。底色 `--dsw-specific-menu`（light `rgba(248,249,250,.58)` / dark `rgba(67,69,74,.45)`；darwin 覆盖为 `.94`）+ `backdrop-filter: blur(40px) saturate(150%)` + `box-shadow: var(--dsw-elevation-panel)`＝`0 0 0 .5px <stroke>` + `0 3px 8px rgba(0,0,0,.03)` + `0 0 16px rgba(0,0,0,.02)`，stroke 重绑 border-l1（light `rgba(0,0,0,.04)`）。无 border。`overflow:hidden`。 | 标题「任务」（`locales.ts:81`）；进度「`{done} 已完成 · {active} 进行中 · {pending} 待处理`」，**分隔符是 U+2002 + `·` + U+2002**（`TodoPanel.tsx:56-62`）；零计数的段整体省略（`ui-conversation/tests/todo-panel.client.spec.tsx:51-58,98-104`） | 字：标题 13/24 w500 `label-primary`(#0F1115)；进度 13/20 w400 `label-tertiary`(#81858C) `nowrap+ellipsis`；图标与 chevron `label-tertiary`，均 `aria-hidden`。header gap 10。**chevron 方向：折叠=向上箭头（`IconChevronUp`），展开=向下**（`TodoPanel.tsx:81-83`）——与 transcript 里的 DisclosureRow 相反（`DisclosureRow.tsx:96-105`）。点击整行切换，无展开动画 | `useProjection('todos')`（`TodoPanel.tsx:106-108`）；**null/undefined 都当空**（`todo-panel.client.spec.tsx:114-125`） |
| O2 | **TodoPanel 展开态** | `TodoPanel.tsx:85-96` + `.module.css:88-123` | `ul.list` > `li.item[data-status]`＝[`.glyph` 16×16]**[`.content`] | list：`gap 8`，`max-height: 180px`，`overflow-y:auto`，滚动条用 l2 色（`.module.css:28-32,88-97`）。行 13/20 `label-secondary`(#61666B)，gap 10，单行 ellipsis。折叠→展开之间是 `.body` 的 8pt gap | 无额外文案；每项 `content` 原文 | 状态点（`StateDot.tsx:44-77` + `StateDot.module.css`）：completed→`done` 10pt 槽位 + 居中 **6pt** 实心（`inset:20%`）`#22C55E`；pending→`idle` 同几何 `#D4D4D4`；in_progress→**14pt SVG 环** `stroke-width:2`、颜色 `label-tertiary`，track opacity .25，弧长动画 `1.5s`（spin linear / dash ease-in-out），`prefers-reduced-motion` 下停转并固定 dasharray。**允许多个 in_progress 同时是环**（`todo-panel.client.spec.tsx:86-96`）。每项 `role="img" aria-label=已完成/进行中/待处理` | 同 O1 |
| O3 | **`todo_write` 工具行折叠态**（transcript，任何 todo_write 调用） | `toolviews/todo-row.tsx:30-50`（summary）、`53-78`（组件）、`86-92`（注册 key `todo_write`）；`toolviews/plan-summary.ts:50-59` | 沿用 `ToolRow`→`DisclosureRow`：`[16pt leading 图标][title 13/24][2×2 圆点 · margin 0 8px][summary 省略][suffix 不省略]` | 行高 **24pt**；leading 16×16（内部 svg 14）；title 13/24 400；`summary` 13/24 `ellipsis nowrap`；`summarySuffix` `margin-left:4px` `nowrap`（`ToolRow.module.css:42-86`）。图标 `IconChecklistOutlineRegular`（14，`viewBox 16`，双圆点+双横线）。行色 `label-tertiary`，hover `label-secondary`（`DisclosureRow.module.css:30-50`） | title「更新任务清单」(`todo.rowTitle`)；summary「`{done}/{total} 已完成`」（`locales.ts:288`）＋有活跃项时 ` · {activeContent}`；suffix = `diffSummary` 与 `+{activeExtra}` 用 ` · ` 连接（`todo-row.tsx:68-69`）。golden 实证（en）：`Update to-do list 1/3 completed · Render compact fields and lists 3 added`、`… 2/3 completed 1 added · 1 updated · 1 removed`（`snapshots/web/tool-details/ui.expected.md:10,105`） | 状态：preparing（不可展开）、running（整行 shimmer）、ok、error（summary 用结果首行染 error 色）、stopped（「已停止」染 warn 色）。**多 in_progress 时 `+N` 放在不被省略的 span 里**（`plan-summary.ts:20-34`）。args 非法/JSON 断裂/`todos` 非数组/null item → 回落通用 summary（`todo-row.tsx:30-43`） | 行内容只读 `tool/call.args` + `tool/result`；diff 基线来自 `tool-todo-history` 视图 |
| O4 | **`todo_write` 展开态（差异卡）** | `models/todo-diff-model.ts:17-79` + `ToolDetails.tsx:117-138` + `ToolDetails.module.css` | 展开体 = `ToolDetails` 卡：可选 `caption` + `ul.list` > `li.item[data-change]`＝[状态字][标题][状态文本]，可选 `details.unchanged`（折叠组） | 卡片：`margin: 4px 0 4px 4px`，`border-radius 16`，`0.5px` border-l1，底色 `--dsw-alias-markdown-code-block`(#FAFAFA / dark #0F0F0F…实际 `neutral-bluish-900`)，`font: 13/20`；item padding `10px 14px`，相邻 item `0.5px` 分隔；`max-height:320px` 滚动；caption 12px `label-caption` `padding:10px 14px 6px`；状态字：completed=`✓`(14) / in_progress=`▶`(14) / pending=10×10 空心方框(radius 2)；added 行前缀 `+` 绿色，removed 行前缀 `−` 红色且标题 `line-through` + tertiary；`statusText` 12px caption 右对齐 | caption「首次记录」/「与上次清单相比」/「旧清单不可用」（`locales.ts:102-104`）；diff summary「新增 {n} · 更新 {n} · 移除 {n}」，无变化「清单没有变化」；行标记「新增」「状态变化」「顺序调整」「移除」；未变化组「{n} 项未变化」；空「任务清单为空」（`locales.ts:98-113`）；状态文本「已完成/进行中/待处理」 | 变更状态为 `completed→已完成`；`previousStatus` 时渲染成 `进行中 → 已完成`；order-only 变更标「顺序调整」。**未 settle 的调用没有 details**（`todo-diff-model.ts:23`）→ 展开只剩 IN 卡（args JSON 美化） | `tool/call` + 上一条 `todo/write` 快照（`todo-history.ts:39-56`，用 `reader.previous`） |
| O5 | **Plan 模式 chip**（composer 控制行，与访问模式并排） | `ui-plan/src/client/PlanModeControl.tsx:19-70`；注册 `index.ts:116-125`；座位 `InputBar.tsx:461-466`（`.modes` 内、权限触发之后）；座位声明 `ui-conversation/src/client/apply.ts:456`（`kind:'single', scope:'session'`） | `span.wrap`(inline-flex, gap 6) > `button.chip`＝[`.glyph` 14×14][label]；inline `span.error`（失败时） | chip：**高 28**、`min-width 34`、`padding 0 8`、gap 4、圆角 `--dsw-radius-sm` = **8**；底色 `--dsw-alias-state-business-tertiary` light `#E4EDFD` dark `#34415B`；字色 `--dsw-alias-state-business-primary` light `#4176E6` dark `#7AAAFF`；字 13/20 w500；hover 背景 `color-mix(…, business-primary 6%)`；`:focus-visible` 外环 2px + offset 2；`:disabled` opacity .6；glyph 静息 `IconPlanOutlineRegular`(14)（= `IconListPenOutline` 几何），hover/focus 换成 `IconCloseCircleFillRegular`(14)；错误行 12/18 `state-error-primary`(#EC1313 / #F25A5A)。402pt 下中文「计划」≈ 8+14+4+26+8 = **60pt 宽**（计算） | label「计划」(`locales.ts:5`)；`aria-label`「计划模式已开启，按下关闭」；`title`「计划模式已开启 — 点击关闭（/plan off）」；失败「退出计划模式失败」 | 只在 `plan` projection 存在**且**有效目标为 plan（`pending ? !active : active`）时渲染（`PlanModeControl.tsx:32-34`）；点按 → `remote.commands.execute(session,'/plan off',[])`，失败留在 chip 上；`locked` 或 `leaving` 时 disabled。**手机宽度不塌陷**（`apps/web/tests/expected/plan-narrow-viewport/layout.expected.md`：`Plan chip fully in viewport: true`；塌陷的是模型文本）；手机上控制行被 `display:contents` 拍平、访问模式靠 `order:1;margin-left:auto` 移到最右（`ui-mobile/src/client/mobile.module.css:182-199`） | `useProjection('plan')` = `{active, pending}`（`packages/plan/plan-mode/src/types.ts:14-20`）；`/plan` 命令与 `plan/mode` 事件折叠而来（`index.ts:139-168`） |
| O6 | **已提交计划卡（turn tail）** | `PlanCard.tsx:43-60`；注册 `ui-plan/index.ts:79-95`（`conversation.chat.turnTail`）；宿主 `TurnTailNodeView.tsx:47-56`（tail 在 message actions 之前） | `.cards`(flex column, gap 10) > 每份计划一个 `button.card[data-plan-card]`＝[`.cardIcon` 40×40][`.cardDetails`(title/desc)][`.cardOpen`] | 卡：**高 60**、`padding 8px 10px`、gap 10、圆角 16、`0.5px` border-l1、底色 light `#FAFAFA` / dark `#212123`，hover `#F5F5F5` / `#292929`，`transition background-color 120ms`；width 100%（402pt 下受内容列约束 = **338pt**，`ChatView.module.css:28` 为 `16px calc(clearance+16px)`）。icon 框 40×40、圆角 10、`0.5px` border-l1、底色 `rgba(255,255,255,.5)`（dark 5%），内含 `FileTypeIcon kind="markdown" size={20}`（markdown 用 `deepseek-500 #4176E6`）。title 13/20 w500，desc **10/16** `label-tertiary`。`.cardOpen`：高 28、`padding 4px 8px`、圆角 8、`0.5px` border-l3、底 `button-floating-fill`(#FFF / #2C2C2E)、字 **12/18**。turn tail 根 `gap:16`，actions `margin-top:4`（`TurnTailNodeView.module.css:1-9`） | title = 计划 Markdown 的一级标题文本；desc「计划 · Markdown」；右侧「打开」；`aria-label`「打开计划：{title}」 | 每份被提交过的计划一张卡，含被拒绝/被 dismissed 的（`plan-definition.ts:9`）；点击 → 右栏 plan 资源。**phone 上右栏 = 全宽抽屉**（`mobile.module.css:94-110`：`width:min(100vw,480px)`、`transition transform 240ms`） | `tool/call` 或 `tool/ptc-dispatch*`（`name==='exit_plan_mode'`）的 `args.plan` + `#` 首标题（`plan.ts:32-48`） |
| O7 | **计划预览文档** | `PlanPreview.tsx:24-62` + `PlanPreview.module.css:35-39`；`plan-resource.ts:38-96` | `section[data-plan-preview][aria-label=标题]` > `.document`(MarkdownText) | `.preview`：`padding 20px 24px 40px`，**≤767px 时 `16px 18px 32px`**，`overflow:auto`，`height:100%`。`.document` 14px / **line-height 1.75**（=24.5）`label-primary`，`overflow-wrap:anywhere` | tab 标题「计划」；标题行 `FileTypeIcon kind="other" size={16}` + 计划标题；loading「正在读取计划…」、failed「无法读取计划」、notFound「未找到这份计划」、unavailable「计划预览不可用」、expired「临时计划预览已失效，请从仍在等待审批的卡片重新打开。」 | 只读；滚动手势在文档内部；手机端是全宽右抽屉，需先点页头「打开右侧边栏」（`snapshots/web/lifecycle-chrome/plan-active-zh.expected.md:22`） | `dsh-resource://plan/...` 地址在会话历史里反查那次调用（`plan-resource.ts:71-90`） |
| O8 | **Plan review 接管面板**（`exit_plan_mode` 阻塞时） | `ui-user-questions/src/client/PlanReviewPanel.tsx:29-91` + `.module.css`；路由 `QuestionComposer.tsx:139-154`（`planReviewOf` → 面板，否则通用问题流）；座位 `ui-user-questions/index.ts:382-393`（`conversation.composer` 链，**抢占 composer**） | `.frame`(flex center) > `section.card[data-plan-review-key][aria-busy]` > ①`div.strip`＝[StateDot][「计划待审」][`.previewActions` 右推的「查看全文 ›」] ②`div.summary`＝`h3.title` + `p.description` ③`div.footer`＝[`.feedback role=status`][`.actions`＝要求修改(outline)/同意执行(primary)] | `.frame` padding **6px / (clearance+16)=32px / 10px** ⇒ 卡宽 **338pt**，max-width = 内容列；卡圆角 **20**（`--dsw-radius-xl`）、底色 `--dsw-specific-input-major`(#FFF / #2C2C2E)、`box-shadow: elevation-panel`、无 border。`.strip` `padding 12px 16px` gap 8，底 `--dsw-alias-state-warn-tertiary`(#FEF5E7 / #27241F)、字 `state-warn-primary`(#F59E0B) 14/20，**通栏浅琥珀色带**。`.summary` `padding 14px 16px 12px`；title 15/22 w500 单行 ellipsis；description 14/24 `label-secondary`、`-webkit-line-clamp:2`、margin-top 8。`.footer` `padding 8px 16px 12px`、gap 12、space-between；`.feedback` min-height 16、11/16 error 色；`.actions` gap 8。按钮 = `Button` md：**高 36**、圆角 12、字 14/22、`padding 0 14px`；outline 0.5px border-l3 + 14pt edit 图标（`.discuss gap 6`）；primary 底色 `button-primary-fill`=#0F1115、白字。≤720px 时 footer `align-items:flex-end`、`padding 8px 12px 10px`。估算整卡高 ≈ 204pt（计算） | strip「计划待审」；按钮「同意执行」「要求修改」；「查看全文」；`aria-label` = 提问原文「Approve this plan and leave plan mode?」；`title` = 计划首标题；`description` = 计划首段（等于标题则省略）。golden 实证（en）：`region "Approve this plan and leave plan mode?"` / `text: Plan review` / `button "Open plan in sidebar": View full plan` / `heading [level=3]` / `paragraph` / `status` / 两个 button（`snapshots/web/plan-review/review.expected.md`） | busy 时 strip 的 StateDot 变 `ongoing` 环、两按钮 disabled、`aria-busy=true`；同意 → 回答 `selected:[approve.label]`（原始 label，非本地化串）；要求修改 → dismiss（**不是** reject：`plan-mode/src/index.ts:331-341` 把 dismissed 当"用户要自己说"），拒绝路径文案「The user dismissed the plan review…plan mode remains active.」；成功后工具结果「Plan approved — plan mode exited; carry out the plan starting with your next step.」（`index.ts:291-296`）。**没有独立的"拒绝"按钮**（`plan.decline` 词条存在但面板未用）。面板到达时**自动把计划推进右栏并打开一次**（`PlanCard.tsx:72-82`） | `user-questions/request` 的单条 question：`id='plan-review'`、`header='Plan review'`、`question='Approve this plan and leave plan mode?'`、`detail=<plan markdown>`、options `[Approve, Keep planning]`、`intent:{kind:'plan-review', approve:'Approve', callId}`（`packages/plan/plan-mode/src/index.ts:310-330`） |

### 2.2 组合与叠放（402pt）

| 项 | 官方 | 依据 |
|---|---|---|
| 页面内容列宽 | **338pt**（402 − 2×(16+16)） | `ChatView.module.css:28` |
| composer 卡宽 | **370pt**（402 − 2×16），圆角 28，`elevation-soft`，border-l2 0.5px | `InputBar.module.css:10,41-77`、`ConversationRoot.module.css:388` |
| dock 卡宽（todo / goal / queue） | **338pt**（composer 卡再内缩 16/边） | `TodoPanel.module.css:6-21`、`GoalBar.module.css:6-31`（注释明写"card cap − four insets 与 Todo、Queue 相同"） |
| composer 栈顺序 | `todo(0)` → `goal(10)` → `queue(20)` → composer 卡；栈 `gap: 6px` | `TodoPanel.tsx:117`、`ui-goal/src/client/index.ts:103-106`、`QueueDock.tsx:395-398`、`ConversationRoot.module.css:335-343` |
| 手机（<640px） | 三组控制 wrapper `display:contents`，整行 gap 8；访问模式 `order:1;margin-left:auto` 落到最右；composer 座位 `position:fixed;bottom:0;z-index:31`，滚动区 `padding-bottom: var(--dsh-composer-height,152px)`；输入/搜索框强制 **16px** 字避 iOS 聚焦缩放 | `mobile.module.css:143-175,182-199` |
| 窄容器（≤460px 控制行） | 访问模式触发**丢文字保图标**；plan chip 保文字 | `PermissionSelect.module.css:100-104`、`plan-control-row.e2e.ts` |

### 2.3 官方中文文案母版（必须逐字采用）

| 命名空间 | 原文（zh） | file:line |
|---|---|---|
| conversation | 任务 / `{done} 已完成` / `{active} 进行中` / `{pending} 待处理` / 已完成 / 进行中 / 待处理 / 更新任务清单 | `ui-conversation/src/client/locales.ts:81-88` |
| conversation | `{done}/{total} 已完成` | 同上 `:288` |
| conversation | 首次记录 / 与上次清单相比 / 旧清单不可用 / 清单没有变化 / `新增 {count}` / `更新 {count}` / `移除 {count}` / `{count} 项未变化` / 新增 / 状态变化 / 顺序调整 / 移除 | 同上 `:102-113` |
| conversation | 已完成 / 进行中 / 待处理 / 任务清单为空（detail 前缀） | 同上 `:98-101` |
| conversation | 工具调用 / 运行中 / 正在准备调用 / 失败 / 已停止 / 输入 / 输出 / 查看 | 同上 `:307-317,323` |
| plan | 计划 | `ui-plan/src/client/locales.ts:5-6` |
| plan | 计划待审 / 同意执行 / 拒绝（面板未使用）/ 要求修改 | `ui-user-questions/src/client/locales.ts:32-35` |
| plan | 计划 · Markdown / 打开 / 在侧边栏打开计划 / 查看全文 / 打开计划：{title} / 正在读取计划… / 无法读取计划 / 计划地址无效 / 无法读取会话历史 / 未找到这份计划 / 计划预览不可用 / 临时计划预览已失效… | `ui-plan/src/client/locales.ts:6-18` |
| plan | 计划模式已开启，按下关闭 / 计划模式已开启 — 点击关闭（/plan off）/ 退出计划模式失败 | 同上 `:19-21` |

## 3. iOS 现状（按 surface 列）

| # | Surface | iOS 实现（file:line） | 现在画成什么 | 行为 | 与官方的差 |
|---|---|---|---|---|---|
| I1 | TodoPanel dock | **不存在**。`grep -rn -i "todo" --include=*.swift` 全仓 11 命中，只有 `NativeToolCallModel.swift:49`（工具标题）、`DSHManagementModel.swift:128,562` + `SessionActivityPage.swift:32-46,210-224`（**另一个页面**的只读 List）、`ChatModel.swift:2175` 与 `NativeShell.swift:811`（调试样例串）。composer 栈只有 `goalBar` / `queuedStrip` / `attachmentStrip` / slash / reference（`ChatPage.swift:1134-1161`）。`ChatItem.Kind` 无 todo（`NativeConversationModels.swift:8-12`）；`HarnessEvent.Kind` 无 todo（`AgentHarness.swift:390-409`） | 无 | 无。transcript 里只有 `todo_write` 的通用工具行（见 I3） | 缺整个 O1/O2；宽度轴、材质、状态点、折叠语义、`turn/start` 清空语义全缺 |
| I2 | 计划模式切换 | **不存在**。`grep -rn "计划模式"` 只命中 `SessionActivityPage.swift:26`（活动页一句"此会话尚未启用计划模式。"）；`grep -rn -i "planmode|plan_mode|planReview|plan/review"` **0 命中**；`exit_plan_mode` **0 命中** | 无 chip、无入口。slash 菜单会把宿主的 `/plan` 命令照列出来（`ChatPage.swift:1819-1875` 从 `model.availableCommands` 渲染），选中后只写回草稿文本（`pickCommand:1876-1879`）；命令成功文案只出现在一次性 sheet（`ChatPage.swift:1683-1684` → `showCommandResult`，`266-268`） | 宿主侧 `/plan` 真能生效（`ChatModel.executeCommand` 走宿主 `commands/execute`），但页面上没有任何状态变化 | 唯一与 plan 有关的代码 `ChatModel.swift:119` `case "plan": return "只出方案"` 把 plan 当**访问模式**；官方访问模式只有 `preset.readOnly/workspaceWrite/fullAccess`（+`auto` 实验）——`packages/client/ui-permission-presets/src/client/locales.ts:12-14,38-40,42-57`。这是语义错误而非等价实现：真要选择它，改的是权限而不是计划模式 |
| I3 | `todo_write` 工具行（折叠） | `NativeToolCallModel.swift:18-26`（variant→`.others`）、`46-64`（title = 「更新任务清单」✓）、`84-107`（summary）、`NativeToolDetailCards.swift:6-35` → `NativeMessageRows.swift:5-55` | `更新任务清单 · todo_write`。summary 走 `if variant == .others, let first = args.values.compactMap(\.stringValue).first`（`:104`）→ `todos` 是数组取不到 string → `:105` `return name` = **`todo_write`** 上屏。行高 24（`NativeMessageRows.swift:43`），16×16 leading + 6（`:22-27`），标题 13 `secondaryFont()`，圆点 2×2 padding h8（`:32-35`），summary 13/tertiary（`:36-38`） | 可展开（`hasDetails` = input≠nil，`:110`）；展开是 `NativeIOCard` 的「输入/输出」两段 JSON（`NativeToolDetailCards.swift:67-69,197-228`），输入 = `nativePrettyJSON(arguments)`（`NativeToolCallModel.swift:70-74`）；running 有 shimmer、error/stopped 有 `accessibilityValue` | 差 O3 全部语义：无 done/total、无当前活跃项、无 `+N`、无 diff summary；且把内部工具名当文案 |
| I4 | `todo_write` 工具行（展开） | 同上；`NativeToolDetails` 无 todo 分支（`NativeToolDetailCards.swift:41-69`） | 「输入」= `{"todos":[{"content":…,"status":…}]}` 美化 JSON；「输出」= `Updated todo list: 1 pending, 1 in progress, 1 completed.`；等宽 12、code 底 `#F6F6F8`、圆角 12、0.5 border；输入/输出各限高 150（`:216-223`） | 只读、可选中、可滚动 | 差 O4：无清单行（状态字 + 内容）、无「首次记录 / 与上次清单相比」caption、无新增/状态变化/移除标记、无「N 项未变化」折叠组、无 320 上限分页；官方是"卡片替代 IN/OUT"，iOS 是"IN/OUT 替代清单" |
| I5 | Pending question 呈现（plan review 会落到这里） | `ChatPage.swift:2139-2245`（`QuestionCard`）、`480-552`（`cardsRegion`，位于页头之下、transcript 之上）、`ChatModel.swift:1760-1761`（`pendingQuestion`） | 「❓需要你的回答」+ prompt「Approve this plan and leave plan mode?」+ 两个单选行「Approve」「Keep planning」（系统 `largecircle.fill.circle`）+「其他回答」输入框 +「提交回答」。底 `Color.accentColor.opacity(0.09)`，padding 14 | 选一项 →「提交回答」→ `respondToQuestion` 组装 `{"answers":[{id, selected:[label]}]}`（`DSHRemoteHarness.swift:205-231`）。**计划正文完全不出现**（`detail` 未映射：`DSHRemoteHarness.swift:410-424` 只取 id/question/options/multiSelect） | 与 O8 全线不一致：位置错（transcript 上方卡片区 vs 接管 composer）、无浅琥珀 strip、无计划标题/首段、无「查看全文」、按钮文案是原始英文 label、有官方没有的"其他回答/提交回答"、`header`/`detail`/`intent` 三个字段在映射处被丢弃（`HarnessQuestionItem` 只有 id/prompt/options/multiple，`AgentHarness.swift:298-327`） |
| I6 | 已提交计划卡 | **不存在**。`plan` 相关 0 命中；transcript 尾部只有 message actions（`ChatPage.swift:2246-2348` 的 `ChatMessageRow`/feedback） | 无 | 无 | 缺 O6 |
| I7 | 计划预览 | **不存在**。最接近的承载面是 `NativeWorkbenchPage` 全屏 sheet（`ChatPage.swift:241-244` → `NativeWorkbenchPage.swift:6-36`，分「文件/命令」两段） | 无 | 无 | 缺 O7；也没有官方"自动打开右栏预览"的行为 |
| I8 | 目标条（可复用布局参照） | `ChatPage.swift:1046-1083` | 高 **40**、圆角 **10**、左右 padding 10、gap 8、底色不透明 `#F6F6F8`；`target` 13pt 图标 + 两行（11pt 阶段 / 13pt 目标）+ 暂停/继续/清除 | 与 composer 同栈，无折叠 | 与官方 GoalBar（高 36、圆角 12、`padding 4px 5px 4px 12px`、`specific-menu`+blur 材质+elevation）已经不一致（`GoalBar.module.css:17-31`）——新增 todo 面板时若不统一，会立刻出现"两层卡不同高不同圆角" |
| I9 | 队列条（可复用布局参照） | `ChatPage.swift:1103-1132` | 无外卡：标题行「排队中 N 条」12pt + 每条一个 28pt 高、圆角 8 的 `#F6F6F8` 小卡 | 只读 | 官方 queue dock 是"上圆角 16、下沿藏进 composer 卡"的一体面（`QueueDock.module.css:24-35`） |
| I10 | 视觉 token | `NativeChatTheme.swift:8-28` | primary `#111114`/`#F4F4F5`、secondary `#66666B`/`#A1A1AA`、tertiary `#9A9AA2`/`#81858C`、caption `#ADB2B8`、selector `#F2F3F5`、border `#E4E4E8`、accent `#3964FE`、success `#27865A`、warning `#B45309`、danger `#C0392B` | — | 与官方差异：tertiary 应 `#81858C`（light）而 iOS 是 `#9A9AA2`；secondary 应 `#61666B`；**缺** `state-success-primary #22C55E`、`state-warn #F59E0B`、`state-idle #D4D4D4`、`state-error #EC1313`、`business-primary #4176E6` / `business-tertiary #E4EDFD`、`markdown-code-block #FAFAFA`、`label-caption #ADB2B8`（iOS caption 相等 ✓） |

## 4. 差距清单（核心交付）

> 像素/行为对齐合同均为 402pt。官方颜色给 light / dark 两值。

### PLAN-01 · P0 · TodoPanel（composer 上方任务条）整个 surface 缺失

| 项 | 内容 |
|---|---|
| 差距 | 官方在 `conversation.input.dock` order 0 常驻 todo 条（默认折叠、36pt 高、338pt 宽、可展开清单），iOS 的 composer 栈里没有它，也没有任何替代物 |
| 官方证据 | `TodoPanel.tsx:65-100,112-118`；`TodoPanel.module.css:1-123`；`snapshots/web/queue-actions/layout.expected.md:17-18`（`region "To-dos"` / `button "To-dos 1 completed · 1 in progress"`）；`ui-conversation/tests/todo-panel.client.spec.tsx:42-49`（默认折叠） |
| iOS 证据 | `ChatPage.swift:1134-1145`（栈里只有 goal/queued/attachment/slash/reference）；`grep -rn -i "todo" --include=*.swift` 11 命中全部无关（工具标题 / 活动页 / 调试串） |
| 用户可见影响 | 模型跑多步任务时手机上完全看不到进度列表；这是用户点名"计划"缺口的第一现场 |
| 像素/行为合同 | ① 位置：composer 卡**上方**、与 goal/queue 同一个纵向栈，栈间距 **6pt**（iOS 现为 `VStack(spacing: 9)`，`:1135`；改成 6 会同时影响 goal/queue/attachment，需一起对齐）。② 宽度 `402 − 2×16 − 4×8 = 338pt`，`max-width = composerCardMax − 32`，水平居中。③ 折叠态高 **36pt** = 24 标题行 + 上下各 6 padding；圆角 **16 continuous**；底 `rgba(248,249,250,.58)`+`backdrop-filter blur(40) saturate(150%)`（深色 `rgba(67,69,74,.45)`）→ 原生建议 `.background(.ultraThinMaterial)` 或按 darwin 变体 `rgba(248,249,250,.94)`；描边 `0.5pt rgba(0,0,0,.04)`；阴影 `y3 blur8 rgba(0,0,0,.03)` + `blur16 rgba(0,0,0,.02)`。④ 内容：`checklist` 图标 14pt（不是 SF Symbol `checklist`，官方是"双圆点+双横线"，可用 SF `list.bullet.rectangle` 近似，见 §9）、标题「任务」13/24 **w500** `#0F1115`、进度 13/20 `#81858C` 单行截断、chevron 14pt `#81858C`；gap 10；左右 padding 12。⑤ **chevron 折叠时朝上、展开时朝下**（与 transcript 行相反）。⑥ 展开：8pt 间距后接清单，`max-height 180`、行间 gap 8、行 13/20 `#61666B`、每行 `[16 状态位][内容单行截断]` gap 10；**无展开动画**。⑦ 空列表/`null` 不渲染；`turn/start` 时清空（官方 fold 语义，见 §6） |
| 数据依赖 | `todos` projection 或 `todo/write` 事件（见 PLAN-05 的数据栏与 §6） |
| 实施建议 | 新建 `NativeTodoDock.swift`（View）+ `ChatModel.todos`（`[TodoItem]`）；渲染点插在 `ChatPage.swift:1136` 之后（goalBar 之前，与官方 order 0 一致）；复用 `goalBar` 的栈位，但按上面尺寸重画，并把 goalBar 一起改成官方 36/12/材质，避免两卡不齐 |
| 验证方式 | `-uiPreview chat.todo` 追加一组假 todos；402pt 截图与 `queue-actions/layout.expected.md` 的 aria 结构逐项对齐（`region` 名「任务」、button 名「任务 1 已完成 · 1 进行中」） |

### PLAN-02 · P0 · Plan 模式 chip / 入口 / 状态 / 退出全部缺失，且现有一条"假访问模式"映射

| 项 | 内容 |
|---|---|
| 差距 | 官方 composer 控制行有「计划」chip（28pt 高，亮蓝灰底，点按 `/plan off`，hover 变关闭图标），且 `plan` projection 的 `active/pending` 决定它是否显示；iOS 没有 chip、没有状态、没有退出路径，只有 `AccessModeWording` 里把 `"plan"` 翻成「只出方案」的死映射 |
| 官方证据 | `PlanModeControl.tsx:19-70`、`PlanModeControl.module.css:9-70`、`ui-plan/index.ts:116-125`、`InputBar.tsx:461-466`、`snapshots/web/lifecycle-chrome/plan-active-zh.expected.md:23-24`（「访问模式，当前：工作区内修改」与「计划模式已开启，按下关闭」**并存**）、`apps/web/tests/expected/plan-narrow-viewport/layout.expected.md`、`packages/plan/plan-mode/src/index.ts:232-289`（`/plan` 命令与回执文案）、`types.ts:14-20`（`{active,pending}`） |
| iOS 证据 | `ChatModel.swift:119`（`case "plan": return "只出方案"`）；`grep -rn "计划模式"` → 仅 `SessionActivityPage.swift:26`；`grep -rn -i "planmode\|plan_mode\|planReview\|plan/review"` → 0；`ChatPage.swift:1296-1335`（控制行只有 +、访问模式、Spacer、模型、ProgressView） |
| 用户可见影响 | 宿主侧进入 plan mode 后：页面零提示，用户不知道自己在计划模式；想退出只能凭记忆手打 `/plan off`；同时「只出方案」这个访问模式文案会误导（若宿主下发 id 为 `plan` 的模式，改的是权限档而非计划模式）。plan 待生效（`pending`）时也完全不可见 |
| 像素/行为合同 | ① 位置：composer 卡控制行内，**紧跟访问模式选择器之后**（官方 `.modes` 内顺序：permission → plan）。iOS 插入点：`ChatPage.swift:1322` `accessModeMenu` 之后、`Spacer` 之前。② 尺寸：高 **28**、`min-width 34`、圆角 **8 continuous**、`padding 0 8`、内部 gap 4、左 glyph 14×14。中文「计划」总宽 ≈ **60pt**（8+14+4+26+8，计算）。③ 颜色：底 `#E4EDFD`（dark `#34415B`）、字/图标 `#4176E6`（dark `#7AAAFF`）、字 13/20 **w500**；按下态（hover 在触屏=高亮）底混 6% `#4176E6`；disabled opacity .6。④ 图标：静息 = 官方 `IconPlanOutline`（16 viewBox 的"列表+笔"，描边 1px；SF 近似 `list.bullet.rectangle`）；按下/hover 应换成 `IconCloseCircleFill`（实心圆叉，SF `xmark.circle.fill`）以表达"点了就关"。⑤ 文案：`计划`；可访问性 label「计划模式已开启，按下关闭」、hint「计划模式已开启 — 点击关闭（/plan off）」。⑥ 显示条件：`plan` projection 存在且 `pending ? !active : active`；点按 → 执行 `/plan off`，失败时把「退出计划模式失败」12/18 `#EC1313` 显示在 chip 右侧（gap 6）。⑦ 手机宽度：chip **不塌陷**（塌陷的是模型文本，见 `PermissionSelect.module.css:100-104` 只作用于访问模式）。⑧ 建议同时把 `AccessModeWording` 的 `"plan"` 行删掉，避免与真实 plan 模式混淆 |
| 数据依赖 | `plan` projection（`session/projections` 的 `values.plan`，iOS 已有该 RPC 调用样例：`DSHManagementModel.swift:509-517`）+ `plan/mode` 事件（`packages/plan/plan-mode/src/index.ts:44-50`） |
| 实施建议 | `ChatModel.planMode: PlanModeState?`；`refreshPlanProjection()`（一次性拉 `session/projections`）+ 收到 `plan/mode` 事件即更新；chip 放 `composerControls`；`/plan off` 复用 `runSlashCommand(name:"plan", input:"off")`（`ChatPage.swift:1954-1961`，与 goal 的 `runGoalCommand` 同型） |
| 验证方式 | `-uiPreview chat.plan` 注入 `planMode = (active:true,pending:false)`；断言 chip 文案/尺寸/点按后调用 `/plan off`；另测 `pending:true,active:false`（进入中）与 `active:true,pending:true`（退出中）两态仍在 402pt 一行内不换行 |

### PLAN-03 · P0 · Plan review 面板缺失：`exit_plan_mode` 被降级成通用提问卡，计划正文丢失

| 项 | 内容 |
|---|---|
| 差距 | 官方把 `intent.kind='plan-review'` 的单条提问交给 `PlanReviewPanel` 并**接管 composer**；iOS 一律画成通用 `QuestionCard`（transcript 上方卡片区），且 `header`/`detail`/`intent` 在事件映射处被丢弃 |
| 官方证据 | `ui-user-questions/src/client/PlanReviewPanel.tsx:29-91`、`PlanReviewPanel.module.css:1-109`、`QuestionComposer.tsx:139-154`、`ui-user-questions/index.ts:382-393`（composer 链）、`contract/slots.ts:54-96`（`PlanReview` + `planReviewOf`）、`packages/plan/plan-mode/src/index.ts:310-330`（提问载荷）、`apps/web/tests/plan-review.e2e.ts:85-101,114-131`（**断言 `[data-question-key]` 计数为 0**、"Plan review" 可见、`heading` 含计划标题、「View full plan」可见） |
| iOS 证据 | `ChatPage.swift:2139-2245`（QuestionCard）、`:485-552`（cardsRegion 位置）、`DSHRemoteHarness.swift:410-424`（只取 id/question/options/multiSelect）、`AgentHarness.swift:298-327`（`HarnessQuestionItem` 无 detail/intent/header） |
| 用户可见影响 | 用户收到「Approve this plan and leave plan mode?」却**看不到计划内容**，只能盲选英文 Approve / Keep planning；这是把"决策"降级成"猜"。若点 Keep planning，因为 iOS 走的是 dismiss 语义，plan mode 仍开着，用户也收不到任何解释 |
| 像素/行为合同 | ① 座位：**替换 composer 卡**（不是 transcript 上方）。iOS 需在 `safeAreaInset(edge:.bottom)` 的 `composer` 里分支：有 plan-review 时用 review 卡替代输入卡（键盘收起，`cardsRegion` 不再重复展示它）。② 外框 `padding: 6pt 32pt 10pt`（左右 = clearance 16 + 16），卡宽 338pt 居中。③ 卡：圆角 **20 continuous**、底 `#FFFFFF`（dark `#2C2C2E`）、阴影 `0 0 0 0.5 rgba(0,0,0,.04) + y3 blur8 .03 + blur16 .02`、无描边。④ 顶部通栏 strip：`padding 12pt 16pt`、gap 8、底 `#FEF5E7`（dark `#27241F`）、字 `#F59E0B` 14/20；左端 10pt 状态点（amber `#F59E0B`，提交中变 14pt 旋转环），中间「计划待审」，右端 `查看全文` + 14pt chevron right（`#61666B`，按下 `#0F1115`）。⑤ 主体 `padding 14pt 16pt 12pt`：标题 15/22 w500 `#0F1115` 单行截断；描述 14/24 `#61666B` 最多 **2 行**、上间距 8。⑥ footer `padding 8pt 16pt 12pt`、gap 12、左右分布：左边错误行（min-height 16、11/16 `#EC1313`，成功态留白），右边两个 36pt 高、圆角 12 的按钮 gap 8——「要求修改」outline（0.5pt `rgba(0,0,0,.12)` + 14pt 铅笔图标 + gap 6）、「同意执行」实底 `#0F1115` 白字。⑦ 状态：提交中两按钮 opacity .4 禁用、strip 点转环、`aria-busy`。⑧ 文案：「计划待审」「要求修改」「同意执行」「查看全文」；**不要**加"拒绝"按钮（官方面板只有这两个动作）。⑨ 计划标题/描述取法：标题 = markdown 首行去壳、描述 = 首段（等于标题则省略）。 |
| 数据依赖 | `user-questions/request` 的 `questions[0].header/detail/intent`（已在线上，只需不丢）+ 原始 `questions` JSON（iOS 已存 `PendingRequest.questions`，`DSHRemoteHarness.swift:56,412`） |
| 实施建议 | ① `HarnessQuestionItem` 增 `header/detail/intent`（可选，保持 Codable 向后兼容），`DSHRemoteHarness.swift:416-424` 补齐映射；② `ChatModel` 暴露 `pendingPlanReview`（由 `pendingQuestion` 派生，判断 `intent.kind == "plan-review"` 且只有 1 题）；③ 新建 `NativePlanReviewCard.swift`；④ composer 分支渲染 |
| 验证方式 | 用官方 `snapshots/web/plan-review/review.expected.md` 当 aria 对照表：一个 `region`（label=提问原文）、文本「计划待审」、按钮「查看全文」、标题级=h3、一段描述、一个 status、两个按钮；`data-testid` 等价断言：通用提问卡 **不出现** |

### PLAN-04 · P0 · 已提交计划卡（turn tail）与计划预览文档完全缺失

| 项 | 内容 |
|---|---|
| 差距 | 官方审批通过后，turn 尾部渲染 60pt 高的「计划 · Markdown / 打开」卡（每份被提交的计划一张，含被拒的），点击在右栏（手机=全宽右抽屉）打开 Markdown 全文；iOS 两者都没有 |
| 官方证据 | `PlanCard.tsx:43-60`、`PlanPreview.module.css:1-39`、`plan-definition.ts:15-33`、`plan.ts:32-48`、`ui-plan/index.ts:79-95`、`TurnTailNodeView.tsx:47-56`、`snapshots/web/plan-review/approved.expected.md`（`button "Open plan: Add \`--greeting\` flag to CLI"`: "Add … Plan · Markdown Open"）、`preview.expected.md`（h1 + list 的 Markdown 结构） |
| iOS 证据 | `grep -rn "exit_plan_mode"` → 0；`ChatPage.swift:2246-2348`（行尾部只有 feedback/复制）；`ChatPage.swift:241-244`（唯一的"面板"是工作区 sheet） |
| 用户可见影响 | 计划审完就消失了：事后无法回看这份计划；也无法分享/对照执行情况。这是"计划"这条线最容易被用户感知为"没做完"的一环 |
| 像素/行为合同 | ① 位置：该 turn 的最后一个内容块之后、message actions 之前，间距 = turn tail 根 `16pt` + actions `margin-top 4`。② 卡：高 **60pt**、宽 = 内容列 338pt、`padding 8pt 10pt`、gap 10、圆角 **16 continuous**、`0.5pt` 描边 `rgba(0,0,0,.04)`、底 `#FAFAFA`（dark `#212123`）；按下底 `#F5F5F5`（dark `#292929`），120ms ease。③ 左图标框 40×40、圆角 10、`0.5pt` 描边、底 `rgba(255,255,255,.5)`（dark 5%）、内含 20pt markdown 文件图标（描边色 `#4176E6`）。④ 中间两行：标题 13/20 w500 `#0F1115` 单行截断；副标题 **10/16** `#81858C` 单行。⑤ 右侧「打开」胶囊：高 28、`padding 4pt 8pt`、圆角 8、`0.5pt` 描边 `rgba(0,0,0,.12)`、底 `#FFFFFF`（dark `#2C2C2E`）、字 12/18 `#0F1115`。⑥ 多份计划：竖向 gap **10**。⑦ 预览：标题/正文渲染，正文 14pt / 行高 **1.75**（24.5pt）、`#0F1115`、`padding 16pt 18pt 32pt`（≤767px 口径）；标题栏 16pt 文件图标 + 计划标题；空/失败态「正在读取计划…」「无法读取计划」「未找到这份计划」「计划预览不可用」「临时计划预览已失效…」。⑧ 手机承载面：官方是右抽屉（`width:min(100vw,480px)`→402 全宽、`transform` 240ms）；iOS 建议落在 `NativeWorkbenchPage` 同款全屏 sheet（`presentationDragIndicator(.visible)`），并在页头补一个"打开右侧边栏"式入口（官方 `plan-active-zh.expected.md:17`） |
| 数据依赖 | **已经具备**：`tool/call` 的 `arguments.plan`（iOS 在 `ChatModel.swift:1723-1741` 存了 `argumentsRaw`/`arguments`，projector 同样 `NativeTranscriptProjector.swift:75-85`）。只需 (a) 识别 `name == "exit_plan_mode"`，(b) 取 `plan` 字段 + `#` 首标题，(c) 按 turn 归属 |
| 实施建议 | `ChatItem` 增 `submittedPlan: SubmittedPlan?`（或独立 `ChatModel.submittedPlans[turn]`）；投影时把 exit_plan_mode 的 call 标成"计划提交"而不是普通工具行；turn 尾部渲染 `NativeSubmittedPlanCard`；点击 push 预览页 |
| 验证方式 | 回放官方 `snapshots/web/plan-review/session.v3.jsonl` 到 `ChatModel`（或手工注入一次 exit_plan_mode call），断言：尾部出现一张卡、`accessibilityLabel` == 「打开计划：{首标题}」、文字 == 「{标题} 计划 · Markdown 打开」、被拒的计划也保留 |

### PLAN-05 · P1 · `todo_write` 行 summary 语义缺失，且泄漏内部工具名

| 项 | 内容 |
|---|---|
| 差距 | 官方 summary = `1/3 已完成 · 写组件`，suffix = `3 added` + `+2`（`+N` 不被省略）；iOS summary = `todo_write`，无 suffix |
| 官方证据 | `todo-row.tsx:44-49,68-69`、`plan-summary.ts:50-59`、`locale.ts:288`、`ui-tool/tests/todo-row.client.spec.tsx:89-114`（`1/3 已完成 · 写组件`、`+2` 不在省略段内、活跃项内容不可用时只留计数）、`snapshots/web/tool-details/ui.expected.md:10,105` |
| iOS 证据 | `NativeToolCallModel.swift:100-107`（`.others` 走 `args.values.compactMap(\.stringValue).first` → 取不到 → `return name`） |
| 用户可见影响 | 每看一次 todo 更新都要点开 JSON 才能知道进度；且 `todo_write` 这种内部标识出现在产品文案位置 |
| 像素/行为合同 | 行结构不变（24pt 高、13/20、2pt 圆点 padding h8）；summary 文本＝`"{done}/{total} 已完成"` + （有活跃项）`" · "` + 首个 in_progress 的 `content`；suffix 独立 span（**不参与截断**，`margin-left 4pt`、13/24、`#81858C`）＝`diffSummary` + `+{活跃项数-1}`（用 `" · "` 连接，`+N` 只在 N>0 时出现）；活跃项 content 缺失/空白/非字符串时**只留计数、不留 `+N`**；args 非法 JSON / 非对象 / `todos` 非数组 / item 非对象 → 回落通用 summary（`工具调用 …`），并保持 error/running/stopped 行态 |
| 数据依赖 | 无（只需解析 `arguments`） |
| 实施建议 | 在 `NativeToolCallModel` 加 `todoSummary`；给 `NativeDisclosureRow` 加 `summarySuffix` 参数（对应官方 `summarySuffix`，避免把 `+N` 塞进可截断文本） |
| 验证方式 | 三组 args：`1/3 + 单个 in_progress`、`1/5 + 3 个 in_progress`（断言 `+2` 可见且不在截断段内）、`{content:42,status:'in_progress'}`（断言只显示 `1/2 已完成`）；再来一组 `not json` 断言回落 |

### PLAN-06 · P1 · `todo_write` 展开态缺清单卡与差异卡

| 项 | 内容 |
|---|---|
| 差距 | 官方展开是"清单/差异卡"（caption + 状态字 + 内容 + 变更标记 + 未变化折叠组），iOS 展开是「输入/输出」JSON |
| 官方证据 | `todo-diff-model.ts:17-79`、`ToolDetails.tsx:43-107,117-138`、`ToolDetails.module.css`（item padding 10/14、caption 12px、`max-height:320`、pending 10×10 空心方、`✓`/`▶` 14pt、removed 删除线）、`snapshots/web/tool-details/ui.expected.md:11-21,105-123` |
| iOS 证据 | `NativeToolDetailCards.swift:41-69`（无 todo 分支 → `default` 走 `NativeIOCard`）、`NativeToolCallModel.swift:110`（`hasDetails` 只看 input/output/path） |
| 用户可见影响 | 想核对"哪几项刚完成、哪项新增、哪项被删"必须读 JSON diff——手机上几乎不可读 |
| 像素/行为合同 | 卡：圆角 16、`0.5pt` border-l1、底 `#FAFAFA`（dark 走 markdown-code-block）、字 13/20 `#61666B`、`margin 4 0 4 4`；caption 12px `#ADB2B8` `padding 10 14 6`；item `padding 10pt 14pt`、相邻 `0.5pt` 分隔；左侧状态位 14×18（✓/▶/10×10 空心方框 radius 2），标题 13/20，右侧状态文本 12px `#ADB2B8`；`added` 用 `+` 绿色 `#22C55E`、`removed` 用 `−` 红色 `#EC1313` 且标题 `line-through` + `#81858C`；`previousStatus` → `进行中 → 已完成`；未变化组折叠摘要 `9pt 14pt` + 6pt gap + chevron-right(展开旋转 90°)，文案 `{n} 项未变化`；列表 `max-height 320` 内部滚动；首写 caption「首次记录」、后续「与上次清单相比」、历史不全「旧清单不可用」、无变化「清单没有变化」；空「任务清单为空」。**未 settle 的调用**不显示差异卡（仍是 IN 卡 JSON） |
| 数据依赖 | 需要"上一条 todo_write 的快照"作基线。iOS 可在投影阶段按 turn 顺序缓存（`NativeTranscriptProjector` 单次遍历即可），实时阶段在 `ChatModel` 维护 `lastTodos`；手机端不需要官方的 `hasMore` 三分支，简化为"有基线/无基线"，但**必须**保留「首次记录」与「旧清单不可用」两句文案的语义（历史加载更早前不要谎称首次） |
| 实施建议 | 新建 `NativeTodoDetailCard.swift`，`diff` 计算纯函数（便于单测，对齐 `plan-summary.client.spec` 风格）；`NativeToolDetails` 加 `.todo` 分支 |
| 验证方式 | 单测三例：首写、单项状态变化、新增+移除+1 项未变化；UI 断言 `statusText` 文本与 `line-through` 存在性 |

### PLAN-07 · P1 · `exit_plan_mode` 工具行 summary 用整段 Markdown（官方是首行 + 工具名前缀）

| 项 | 内容 |
|---|---|
| 差距 | 官方通用行公式：`summary = [isGenericTitle ? toolName : '', base].join(' · ')`，`base` = 首个 string 参数的**首行**；于是显示 `工具调用 · exit_plan_mode · # Add --greeting flag to CLI`。iOS 取的是整个 string 值（多行计划全文），且没有工具名段 |
| 官方证据 | `tool-call-model.ts:255-262`（`deriveSummary` 的 `firstLine`）、`:321`（前缀公式）、`snapshots/web/plan-review/approved-expanded.expected.md`（`button "Tool call exit_plan_mode · # Add \`--greeting\` flag to CLI"`） |
| iOS 证据 | `NativeToolCallModel.swift:104`（`return first` 返回完整字符串）、`:46-64`（`exit_plan_mode` 无 case → 标题「工具调用」✓） |
| 用户可见影响 | 一行 24pt 的行里塞进整篇计划（被截断成一串乱码般的首行），且用户看不出这是哪个工具 |
| 像素/行为合同 | 标题「工具调用」（已正确，勿改）；summary = `exit_plan_mode · {plan 的首行}`，单行 ellipsis；行高 24、13/24；更长的正文只在展开态出现（官方展开是 IN 卡里的 args JSON，`formatToolBody('others', …)`） |
| 数据依赖 | 无 |
| 实施建议 | `.others` 分支改为 `first.components(separatedBy:.newlines).first` 并前置 `name`（仅当 title 是通用「工具调用」时，与官方 `titleKey === 'tool.title.generic'` 判断等价） |
| 验证方式 | 断言 summary 恰为一行且以 `exit_plan_mode · ` 开头；`\n` 计数为 0 |

### PLAN-08 · P1 · 计划决策在 transcript 无留痕：回答后没有 `question-reply` 行，被拒后 plan mode 状态无解释

| 项 | 内容 |
|---|---|
| 差距 | 官方把迟到的回答投影成 `question-reply` chat 节点（问答对回放在对话里），`exit_plan_mode` 的结果文案（批准/被拒）留在工具结果里；iOS 回答后卡片消失、transcript 什么都不留 |
| 官方证据 | `ui-user-questions/src/client/question-reply.ts:1-70`、`questionReplyDefinition` 注册 `ui-user-questions/index.ts:394`、`packages/plan/plan-mode/src/index.ts:291-296`（两种结果文案）、`apps/web/tests/plan-review.e2e.ts:85-95,114-115`（批准后 transcript 保留 plan 卡与工具结果） |
| iOS 证据 | `ChatPage.swift:533-548`（回答后 `pendingQuestion = nil` 即消失，`ChatModel.swift:1393-1399`）；`NativeTranscriptProjector.swift:19-147` 无 question 节点；`ChatItem.Kind` 无 question 类 |
| 用户可见影响 | 回看历史时看不到"我当时批了/驳了这份计划"，也看不到模型为什么继续在 plan mode |
| 像素/行为合同 | 回答后在同位置保留一行只读记录（对应官方 `QuestionReplyView`），至少包含：提问短句 + 选项标签 + 时间；被拒时同步更新 chip（仍显示「计划」）并把结果文案（「The user dismissed the plan review to reply in their own words; plan mode remains active.」的等价中文，需与官方一致口径）展示在工具结果里；不新增官方没有的"已拒绝"徽标 |
| 数据依赖 | `user-question-reply` steered message 的 JSON payload（官方从文本里解析 questions/answers，`question-reply.ts:58-70`）。iOS 目前把 `user/message` 与 `agent/inbox/spliced` 直接 `break`（`ChatModel.swift:1719-1722`），需要至少保留 `source.kind == "user-question-reply"` 的那条 |
| 实施建议 | 与 axis 03（提问）共用一处实现：先落 `question-reply` 行，plan 场景只需在内容里显示「Approved」/「Keep planning」 |
| 验证方式 | 批准与被拒各回放一次，断言 transcript 出现 1 行问答记录、chip 状态正确、工具行结果文案正确 |

### PLAN-09 · P1 · 进入/离开计划模式的回执不进 transcript（官方是命令输入行 + 用户消息）

| 项 | 内容 |
|---|---|
| 差距 | 官方 `/plan <task>` 会在对话里留下一条带 `plan` 徽标的用户消息，文本为「Plan mode on. Use /plan off to leave.」+ 任务本身；iOS 的命令成功文案只弹一次性 sheet，且 durable 的 `user/message` 被丢弃 |
| 官方证据 | `snapshots/web/plan-review/approved.expected.md` 第 10 行（`text: "plan Plan mode on. Use /plan off to leave. Plan a small change: …"`）、`packages/plan/plan-mode/src/index.ts:236-289`（命令 handler 与回执文案）、`ui-chat/src/client/conversation-nodes/command.ts:36-58`（`command` 节点） |
| iOS 证据 | `ChatPage.swift:1683-1684`（`showCommandResult = true` → `CommandExecutionResultPage` sheet，`266-268`）；`ChatModel.swift:1719-1722`（`case .userMessage, .inboxSpliced: break`） |
| 用户可见影响 | 关掉 sheet 后，会话里没有任何"我刚进了计划模式"的证据；重新打开会话时更是什么都没有 |
| 像素/行为合同 | 沿用官方用户行（右对齐气泡）＋来源徽标 `plan`；文本原样（宿主串，不翻译）；`command` 回执行按 axis 05 的统一做法（本轴只要保证 `/plan` 不丢） |
| 数据依赖 | `user/message`（`source.kind`）、`command/run` / `command/done` |
| 实施建议 | 依赖 axis 01（数据链）与 axis 05（timeline）；本轴提供验收用例 |
| 验证方式 | 输入 `/plan 帮我看看` → 断言 transcript 出现一条带 `plan` 徽标的用户消息 + 无残留 sheet |

### PLAN-10 · P2 · 视觉语义 token 缺一组（计划/待办直接受影响的颜色与动效）

| 差距 | 官方这套 surface 用到的状态/业务色 iOS 都没有：`state-success-primary #22C55E`（todo 完成点）、`state-idle-primary #D4D4D4`（待处理点）、`state-warn #F59E0B`（review strip）、`state-error #EC1313`（失败文案）、`business-primary #4176E6`（chip 字/图标、markdown 文件图标）、`business-tertiary #E4EDFD`（chip 底）、`label-caption #ADB2B8`、`markdown-code-block #FAFAFA`（卡片底）、`label-tertiary #81858C`（iOS 现为 `#9A9AA2`）、`label-secondary #61666B`（iOS 现为 `#66666B`） |
|---|---|---|
| 官方证据 | `design-platform.css:214-266`（别名）、`StateDot.module.css:16-30`、`PlanModeControl.module.css:18-19`、`PlanReviewPanel.module.css:35-36`、`PlanPreview.module.css:26`、`base.css:19-23`（radius） |
| iOS 证据 | `NativeChatTheme.swift:8-28`（无上述 token；success 用 `#27865A`、warning 用 `#B45309`、accent `#3964FE` 与 business `#4176E6` 不是同一个值） |
| 用户可见影响 | todo 完成点的绿、待办点的灰、计划 chip 的蓝灰、review 的琥珀都会和官方不是同一个颜色——"一眼看出不是官方" |
| 像素/行为合同 | 新增 token 并**按 light/dark 双值**：success `#22C55E`/`#22C55E`、warn `#F59E0B`/`#F59E0B`、idle `#D4D4D4`/`#3C3C3D`（官方 dark `neutral-600`）、error `#EC1313`/`#F25A5A`、business `#4176E6`/`#7AAAFF`、business-tertiary `#E4EDFD`/`#34415B`、label-primary `#0F1115`/`#F9FAFB`、label-secondary `#61666B`/`#CFD3D6`、label-tertiary `#81858C`/`#ADB2B8`、label-caption `#ADB2B8`/`#81858C`、menu-surface `rgba(248,249,250,.58)`/`rgba(67,69,74,.45)`、surface-50 `#FAFAFA`/`#212123`、warn-tertiary `#FEF5E7`/`#27241F`。动效：`ongoing` 环 `1.5s` 线性旋转 + 弧长 ease-in-out，`prefers-reduced-motion`（iOS `accessibilityReduceMotion`）下停转 |
| 数据依赖 | 无 |
| 实施建议 | 与 axis 09（tokens）合并；**不要**用现有 `success`/`warning` 顶替，两者色相差异在深色模式下尤其明显 |
| 验证方式 | 快照断言 light/dark 两套渲染值（可用 `UIColor` trait 收敛断言） |

### PLAN-11 · P2 · TodoPanel / plan chip / plan card / review 的几何与层次细节

| 差距 | 若只按"有功能"实现，会漏掉：dock 卡与 composer 卡的**16pt 内缩关系**（338 vs 370）、栈间距 **6**（iOS 现为 9）、折叠高 **36**、圆角 **16**、`elevation-panel` 三件套、`backdrop-filter`、`max-height 180`、`U+2002 · U+2002` 分隔符、`+N` 不截断、chevron 方向反转、review 卡 `20` 圆角与 32pt 侧边距、按钮 36/12、plan card 60 高与 10pt 卡间距、预览正文 1.75 行高 |
|---|---|---|
| 官方证据 | 见 §2.1 各行"像素规格"列的 file:line |
| iOS 证据 | `ChatPage.swift:1135`（spacing 9）、`:1046-1083`（goalBar 40/10/不透明）、`:1219-1223`（卡圆角 22、0.5 描边、`shadow .06 r12 y3`）、`:1107-1132`（queue 条 28/8） |
| 用户可见影响 | 新面板与既有 goal/queue 卡"不同高、不同圆角、不同材质"，一屏里三种卡片语言 |
| 像素/行为合同 | 见 §2.1 O1/O5/O6/O8；特别提醒 3 条易错点：① 折叠 chevron 朝上、展开朝下（与 transcript 相反）；② `+N` 必须在截断 span 之外；③ 计划进度分隔符是 **U+2002**，不是普通空格 |
| 数据依赖 | 无 |
| 实施建议 | 抽出 `NativeDockCard` 容器（宽 338、圆角 16、menu 材质、elevation），goal/todo 共用，queue 用其"上圆角"变体 |
| 验证方式 | 截图量宽（338/370/36/16）与相邻卡片间距（6） |

### PLAN-12 · P2 · plan chip 在 402pt 控制行的共存约束未验证

| 差距 | 官方在窄行里"先塌模型文本、再塌访问模式文字，plan chip 保文字"，并有 e2e 断言控件不重叠、点击区不相交；iOS 控制行是 `HStack` + `Spacer`，新增 60pt chip 后需重新验证 402pt 不挤压（尤其中文长模型名） |
|---|---|---|
| 官方证据 | `apps/web/tests/plan-control-row.e2e.ts:41-100`、`expected/plan-narrow-viewport/layout.expected.md`（`Click areas disjoint: true`、`Model icon replaces text above a 360px row: true`）、`PermissionSelect.module.css:100-104`、`mobile.module.css:186-199` |
| iOS 证据 | `ChatPage.swift:1296-1335`（`HStack(spacing:8)`：+ 28pt、accessModeMenu、Spacer、modelMenu、ProgressView） |
| 用户可见影响 | 窄屏 + 长模型名（如 `DeepSeek-V4-Flash-Vision-Exp`）时 chip 与模型名重叠或换行 |
| 像素/行为合同 | 402pt：控制行内宽 = 370 − 14 − 40 = 316pt；官方在 ≤460pt 容器让访问模式丢文字（图标 14 + chevron），模型名在放不下时退化为图标。iOS 需实现同样的"先省文字"优先级：plan chip 文字 > 访问模式文字 > 模型名文字 |
| 数据依赖 | 无 |
| 实施建议 | 先按官方优先级手写测量（`LayoutPriority`/`ViewThatFits`），不要用 `minimumScaleFactor` 缩字 |
| 验证方式 | 三种模型名长度 × plan chip 开关 = 6 组截图，断言无重叠、单行、都在卡内 |

### PLAN-13 · P2 · 计划预览的失败/过期态与"自动打开右栏"行为

| 差距 | 官方预览有 7 种状态文案 + "review 到达时自动打开一次右栏"；iOS 若只做"点开才显示"，则与官方行为不同（官方 e2e 在点击前就已可见 `data-plan-preview`） |
|---|---|---|
| 官方证据 | `PlanCard.tsx:62-83`（`opened`/`mounted` 后自动 `openReview`）、`PlanPreview.tsx:41-47`（状态文案）、`locales.ts:11-17`、`apps/web/tests/plan-review.e2e.ts`（`await preview.waitFor({state:'visible'})` 在点击按钮之前） |
| iOS 证据 | 无预览实现 |
| 用户可见影响 | 审阅时官方是"计划先摆在你面前"，iOS 会变成"要自己找" |
| 像素/行为合同 | 首次出现 plan review 时自动打开预览一次；用户手动关闭后不再自动打开（官方 `actions.markOpened(identity)` 去重）；手机上若自动打开全宽抽屉会盖住 review 卡——**这是需要产品决策的点**（见 §9） |
| 数据依赖 | 同 PLAN-04 |
| 实施建议 | 先实现手动入口；自动打开做成开关默认关，待确认 |
| 验证方式 | 同一 review 重复推送不重复弹；关闭后不重开 |

### PLAN-14 · P3 · todo/plan 的边角状态

| 差距 | 官方还有：`todo_write` 的 `preparing` 不可展开态、`stopped`（interrupted）行文案、`todos` 全为 completed 时进度只显示「1 已完成」、`turn` 内先写后清空的时序、`plan` 投影 `pending` 的"正在应用模式变更"提示（活动页有，会话页官方用 chip 的"有效目标"表达） |
|---|---|---|
| 官方证据 | `todo-row.client.spec.tsx:116-131`、`todo-panel.client.spec.tsx:98-104`、`tool-todo/src/index.ts:126-137`、`PlanModeControl.tsx:32-34` |
| iOS 证据 | 无 |
| 用户可见影响 | 低频，但缺了会被认为"没对齐细节" |
| 像素/行为合同 | 全 completed → 只显「N 已完成」；`stopped` → summary 显示「已停止」并染 warn 色；`preparing` → 无 chevron、不可展开 |
| 数据依赖 | 同 PLAN-01 |
| 实施建议 | 跟随主实现一起做，不单独排期 |
| 验证方式 | 三个单测用例 |

### PLAN-15 · P3 · `todo_write` / `exit_plan_mode` 的 task 级可访问性

| 差距 | 官方：todo 每行有 `role="img"` + `aria-label`（已完成/进行中/待处理）、panel header `aria-expanded`、chip `aria-label`/`title`、review 卡 `aria-busy`/`role=status`；iOS 有部分（`NativeDisclosureRow` 的 `accessibilityValue`、`NativeToolCallRow` 的状态值），但新增 surface 容易漏 |
|---|---|---|
| 官方证据 | `TodoPanel.tsx:70-96`、`PlanModeControl.tsx:52-67`、`PlanReviewPanel.tsx:59-72` |
| iOS 证据 | `NativeMessageRows.swift:49-50`（已有）、`ChatPage.swift:2139-2245`（QuestionCard 无 aria 标注） |
| 用户可见影响 | VoiceOver 读不出一行 todo 的状态、读不出"计划模式已开启" |
| 像素/行为合同 | 每个状态点 `.accessibilityLabel("已完成"|"进行中"|"待处理")`、panel header `.accessibilityValue(展开/折叠)`、chip `.accessibilityLabel("计划模式已开启，按下关闭")` |
| 数据依赖 | 无 |
| 实施建议 | 与主实现同 PR |
| 验证方式 | VoiceOver 手测 3 个元素 |

### PLAN-16 · P3 · 计划审阅面板的键盘/滚动/安全区

| 差距 | 官方 review 面板占用 composer 座位，手机上是 `position:fixed;bottom:0` 且滚动区预留 `--dsh-composer-height`；iOS 若把 review 卡塞进 transcript 上方卡片区（现状），键盘弹起时会被 `cardsExpanded` 折叠成一行（`ChatPage.swift:486-505`） |
|---|---|---|
| 官方证据 | `mobile.module.css:143-166`、`PlanReviewPanel.module.css:1-7` |
| iOS 证据 | `ChatPage.swift:486-505`（键盘态折叠成「N 项需要处理」） |
| 用户可见影响 | 审计划时键盘一弹，计划卡被折叠走 |
| 像素/行为合同 | review 卡固定贴底、无键盘折叠；正文若超屏，卡内滚动而不是整页滚动 |
| 数据依赖 | 无 |
| 实施建议 | 跟随 PLAN-03 |
| 验证方式 | 键盘弹出后卡仍在、按钮可点 |

### PLAN-17 · P3 · `todo` 与 `plan` 的"跨 turn 生命周期"

| 差距 | 官方 `todos` 在 `turn/start` 清空、`turn/end` 保留（完成态可见）；`plan` 状态跨 turn 持久（登录态）；iOS 若把 todo 当成永久历史，或把 plan 做成一次性提示，都会错 |
|---|---|---|
| 官方证据 | `packages/todo/tool-todo/src/index.ts:126-137`（fold: `todo/write` → 整表替换；`turn/start` → `null`） |
| iOS 证据 | 无实现 |
| 用户可见影响 | 新一轮开始时旧清单还挂着（用户会以为任务没做完） |
| 像素/行为合同 | 收到 `turn/start` 立即隐藏 todo 条（无退出动画）；`turn/end` 后保持显示；plan chip 不随 turn 消失 |
| 数据依赖 | `turn/start`（iOS 已有该事件映射，`DSHEventMapper.swift:74-75`） |
| 实施建议 | 在 `ChatModel.handle` 的 `turnStarted` 分支清空 `todos` |
| 验证方式 | 两轮对话截图：第一轮结束后 todo 在、第二轮开始瞬间消失 |

## 5. 隐藏/条件控件清单

| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 备注 |
|---|---|---|---|---|
| 任务条（TodoPanel） | `todos` projection 非空（首次 `todo_write` 之后、下一个 `turn/start` 之前） | composer 上方 dock（order 0） | ❌ | 默认折叠；空/`null` 不渲染 |
| 任务清单展开体 | 点任务条 header | 同上（`ul.list`） | ❌ | `max-height 180`（6 行 160pt 放得下，第 7 行起内部滚动） |
| 任务状态点（三态） | 每条 todo 的 `status` | 同上 | ❌ | 多 in_progress 并存合法 |
| `todo_write` 行 `+N` | 同时有 ≥2 个 in_progress | transcript 工具行 suffix | ❌ | `+N` 必须在截断段之外 |
| `todo_write` 差异卡 | 该行已 settle 且 args 合法 | 行展开体 | ❌ | 首写=「首次记录」；历史不全=「旧清单不可用」 |
| 「N 项未变化」折叠组 | 存在未变化项 | 差异卡底部 | ❌ | `<details>`，chevron 旋转 90° |
| 计划 chip | `plan` projection 存在且有效目标为 plan | composer 控制行（访问模式之后） | ❌ | `pending` 与 `active` 的四种组合只有两种显示 |
| chip 失败行 | `/plan off` 执行失败 | chip 右侧 | ❌ | 「退出计划模式失败」 |
| 计划审阅卡 | 收到 `intent.kind='plan-review'` 的单题提问 | 接管 composer 座位 | ❌（被降级为通用提问卡） | 官方 e2e 断言此时通用提问卡不得出现 |
| 「查看全文」 | 审阅卡 strip 右侧 | 同上 | ❌ | 打开右栏/全宽抽屉 |
| 计划预览自动打开 | review 到达且当前会话在屏 | 右栏（手机=抽屉） | ❌ | 每次身份只自动开一次 |
| 已提交计划卡 | turn 中含 `exit_plan_mode`（含被拒/dismissed） | turn tail（actions 之前） | ❌ | 每份计划一张，gap 10 |
| 计划预览文档 | 点计划卡 / 点「查看全文」 | 右栏 pane tab | ❌ | 手机上为全宽抽屉；标题栏带 16pt 文件图标 |
| 预览失败/过期态 | 资源读取失败、临时地址过期 | 预览内部 | ❌ | 5 条文案 |
| `/plan` 命令回执（transcript 行） | 用户执行 `/plan …` | 对话流中（command + 用户消息） | ❌（只有一次性 sheet） | 官方文本带 `plan` 徽标 |
| turn/start 清空 todo | 新一轮开始 | 无 UI，只有消失 | ❌ | 官方 fold 语义 |

## 6. 数据链路缺口

| 事件/字段 | 官方消费方 | iOS 映射/投影 | 缺失后果 | 需要补什么 |
|---|---|---|---|---|
| `todo/write` `{todos:[{content,status}]}` | `SessionProjectionMap.todos`（`packages/todo/tool-todo/src/types.ts:28-46`），fold 见 `index.ts:126-137` | `DSHEventMapper.map` `default: break`（`:108-109`）；`NativeTranscriptProjector` `default: continue`（`:146-147`） | 实时与历史都拿不到任务清单 | `HarnessEvent.Kind.todoWrite(items:)`（或在 projector 内直接产物），`ChatItem`/`ChatModel.todos` 承载 |
| `todos` projection | `TodoPanel`（`useProjection('todos')`） | **完全未读**。`session/projections` 只在管理页调用（`DSHManagementModel.swift:509-517`），且只解 `plan/todos/goal/subagentCatalog` 到 `ActivityRow` | 无法在"没有 todo_write 事件"的会话（如刚打开的历史会话）显示当前清单 | 复用 `session/projections` 的 `values.todos`；或在 follow 快照的 `projections` 里读 |
| `session/follow` snapshot 的 `projections` 字段 | 官方客户端 projection 基线（`packages/api/session-controller/src/types.ts:570-581`；`ui-session` 的 `useProjection` = "Host-computed projection values"） | `DSHRemoteHarness.handleFollow` 只读 `cursor/records/hasMore`（`:324-345`），**`projections` 直接丢弃** | 打开会话首屏没有 todos/plan/goal 基线，必须发额外 RPC | 解析 `value["projections"]["values"]` 并作为初始投影 |
| `session/control` 的 `{type:'projection', key, value, seq}` 增量流 | 官方 `SessionControlFrame`（`types.ts:589-601`） | iOS 未订阅 `session/control`（`grep session/control` 0 命中） | projection 变化（其他端/后台任务改 todos）无法实时同步 | 订阅或退回"从事件流自算"（更简单：todo 用 `todo/write`，plan 用 `plan/mode`） |
| `plan/mode` `{active:boolean}` | `plan` projection（`packages/plan/plan-mode/src/types.ts:44-50`、`index.ts:139-168`） | 无映射（`DSHEventMapper.swift:108`、`NativeTranscriptProjector.swift:146`） | plan 开关状态不可知 | `HarnessEvent.Kind.planMode(active:)` + `ChatModel.planMode` |
| `plan` projection `{active,pending}` | `PlanChip` 的显示条件 | 管理页读了但只放在 `SessionActivityPage`（`DSHManagementModel.swift:558-561`） | 会话页不知道是否在 plan 模式 | 把同一份读取提到 `ChatModel`，或直接在 `session/follow` 基线里取 |
| `user-questions/request` 的 `header` / `detail` / `intent` | `PlanReviewPanel`（`contract/slots.ts:54-96`） | `DSHRemoteHarness.swift:417-424` 只映射 `id/question/options/multiSelect`；`HarnessQuestionItem` 无这三字段（`AgentHarness.swift:298-307`） | 计划正文、按钮文案、审阅判定全丢 → 只能当通用提问 | 上述三字段进 `HarnessQuestionItem`；`ChatModel` 派生 `pendingPlanReview` |
| `tool/call` 的 `arguments.plan`（`exit_plan_mode`） | `submittedPlan()`（`plan.ts:32-48`）→ 计划卡 | 数据**已有**（`ChatModel.swift:1723-1741`、`NativeTranscriptProjector.swift:75-85`），但从未按 `name == "exit_plan_mode"` 识别 | 计划卡/预览无从渲染 | 投影时识别并抽 `{callId, markdown, title(首标题)}`，按 turn 归组 |
| `tool/ptc-dispatch*` 里的 `exit_plan_mode` | 同上（`plan.ts:36`，PTC 子调用也算） | iOS 无 ptc 映射 | 走 PTC 提交的计划不会出现 | 随 axis 06（tools）一起补；本轴只需在识别函数里接受 subCallId |
| `command/run` / `command/done`（`/plan`） | `command` 节点 + 命令回执 | 无映射 | `/plan` 的可见回执只在 sheet 里 | 见 PLAN-09 |
| `todo_write` 结果里的 counts | 官方不用它做 summary（summary 来自 args），只在 IN/OUT 兜底 | iOS 用它当「输出」 | 影响小 | 保持现有 |

**数据层最小改动建议（可直接落地）**

```swift
// AgentHarness.swift
public enum HarnessEvent.Kind { … case todoWrite(items: [HarnessTodoItem]) ; case planMode(active: Bool) }
public struct HarnessTodoItem: Codable, Equatable, Sendable { public var content: String; public var status: String } // pending|in_progress|completed
public struct HarnessPlanReview: Equatable, Sendable { public var markdown: String; public var header: String; public var approveLabel: String; public var callID: String? }

// ChatModel.swift
private(set) var todos: [HarnessTodoItem] = []      // turn/start 清空
private(set) var planMode: PlanModeState?           // {active, pending}
private(set) var submittedPlans: [Int: [SubmittedPlan]] = [:]  // turn -> plans（来自 exit_plan_mode 的 tool/call）

// NativeTranscriptProjector.swift
// case "todo/write": result.append(todoStripItem) —— 或只回填 ChatModel.todos
// case "plan/mode": …
// "tool/call" 分支：if name == "exit_plan_mode" { 抽 plan/title 存 submittedPlans }
```

## 7. 实施顺序建议

**Wave 1（P0，一次 PR 内可独立验收）**

1. **PLAN-03 计划审阅卡**（用户点名、纯 UI + 一个字段映射；数据已在线上）。先补 `HarnessQuestionItem.header/detail/intent`，再写 `NativePlanReviewCard`，最后把 composer 分支接上。这是"从 0 到 1"里最亮的点，也最容易被用户验收。
2. **PLAN-02 计划 chip**（一个 projection 读取 + 一个 60pt 按钮 + `/plan off`）。可与 1 合并成"计划模式三件套"。
3. **PLAN-04 计划卡 + 预览**（数据已具备，只需识别 `exit_plan_mode` 与一个全屏 sheet）。做完这三条，"计划"这条线就从不可见变成完整闭环。

**Wave 2（P0 剩余 + P1）**

4. **PLAN-01 TodoPanel**（需要 `todo/write` 映射 + `todos` 投影基线，是唯一需要动数据层的一条）。同时把 dock 容器（338 宽 / 16 圆角 / menu 材质 / 6pt 栈间距）抽出来，顺手把 goalBar 改成官方 36/12。
5. **PLAN-05 / PLAN-06 todo 行摘要与差异卡**（纯解析 + 卡；差异卡依赖上一条的基线缓存）。
6. **PLAN-07 / PLAN-08 / PLAN-09**（工具行文案修正 + 提问回执留痕 + `/plan` 回执行）。

**Wave 3（P2/P3）**

7. **PLAN-10 token 补齐**（与 axis 09 合并，先补 token 再回填 Wave 1/2 的颜色，避免二次改）。
8. **PLAN-11 / PLAN-12 / PLAN-13 / PLAN-16** 几何与窄屏、自动打开策略、键盘/安全区。
9. **PLAN-14 / PLAN-15 / PLAN-17** 边角状态、可访问性、跨 turn 生命周期。

依赖关系：PLAN-01 ← (todo 数据)；PLAN-06 ← PLAN-01；PLAN-04 预览 ← 计划卡；PLAN-03 的"查看全文" ← 预览；PLAN-12/16 ← PLAN-02/03；PLAN-10 最好最先（token 先行）。

## 8. 验收场景（可复现）

> 前提：`-uiPreview` 新增 `chat.todo` / `chat.plan` / `chat.planreview` / `chat.planapproved` 四个 DEBUG 注入（现有 `-uiPreview sample` 的机制见 `ChatModel.swift:2359-2407`，`ChatPage.swift:600-640`）。所有截图 402×874，light + dark 各一套。

| # | 场景 | 造数据 | 期望（对照官方） |
|---|---|---|---|
| S1 | **todo 首次出现** | 注入 3 条 todo（1 completed / 1 in_progress / 1 pending）+ 一条 `todo_write` 工具行 | composer 上方出现 36pt 高任务条：`任务  1 已完成 · 1 进行中 · 1 待处理  ⌃`；工具行显示 `更新任务清单 · 1/3 已完成 · 写组件  3 added`（首次无 baseline 时 suffix 只有计数语义）；任务条与 composer 卡间距 6pt，宽 338 vs 370 |
| S2 | **运行中更新** | 第一条 in_progress 变 completed、再插入一条 in_progress | 任务条进度改为 `2 已完成 · 1 进行中`（零计数段省略）；工具行 summary 变为 `2/4 已完成 · 跑后台构建 +1`（`+1` 在截断段之外）；计数变化期间任务条不闪、不重排 |
| S3 | **全部完成** | 3 条全 completed | 进度只剩 `3 已完成`（无「·」尾巴）；**仍在**（`turn/end` 保留）；下一轮 `turn/start` 后任务条**立即消失** |
| S4 | **折叠/展开与长列表** | 12 条 todo | 点 header 展开：清单 `max-height 180` 内部滚动，尾部条目滚动可见；chevron 由朝上变朝下；再点收起，header 进度**不含**活跃项名（官方折叠态只给计数）；与 transcript 滚动互不干扰 |
| S5 | **plan mode 开启** | `planMode = (active:true, pending:false)` | 控制行出现「计划」chip（28pt、`#E4EDFD`、`#4176E6`、14pt 列表笔图标）；与访问模式（此时=图标+chevron）同行不重叠；点按后 chip 消失并出现「计划模式已开启 — 点击关闭（/plan off）」提示（或直接执行 `/plan off` 成功）；`(pending:true)` 时 chip 也显示（有效目标） |
| S6 | **plan 提交后批准／拒绝** | 注入带 `intent.kind='plan-review'` 的提问（plan markdown 含 `#` 标题 + 一段正文） | **approve 路径**：composer 被替换成审阅卡（strip 琥珀「计划待审」+ 右「查看全文」；标题=h1 文本；描述 2 行截断；底部「要求修改」「同意执行」）；点「同意执行」→ 卡消失、composer 复原、turn 尾部出现 60pt 计划卡（`{标题} / 计划 · Markdown / 打开`）；点卡 → 全屏预览显示 h1 + 列表，正文 14/1.75。**discuss 路径**：点「要求修改」→ 卡消失、plan chip 仍在、工具结果出现「…plan mode remains active.」等价中文、计划卡**仍然存在**（官方保留被 dismissed 的计划） |
| S7 | **400pt 窄行共存** | plan chip 开 + 模型名 `DeepSeek-V4-Flash-Vision-Exp` | 控制行单行：模型名让位（退化为图标）→ 访问模式退化为图标 → chip 保留「计划」文字；三控件点击区不相交、都在卡内（对应 `expected/plan-narrow-viewport/layout.expected.md`） |
| S8 | **无 todo / 无 plan 的空态** | 新会话，未写过 todo、未开 plan | 任务条与 chip 都不渲染，composer 高度/间距与今天完全一致（回归断言：不能因为新组件多出 6pt 空白） |
| S9 | **历史会话回放** | 回放 `snapshots/web/plan-review/session.v3.jsonl`（或自造含 `todo/write` ×3 + `plan/mode` + `exit_plan_mode` 的 journal） | 打开即见：任务条（取最后一条 `todo/write`，若最后一条在 `turn/start` 之前则按 fold 为 null）、plan chip（按最后一条 `plan/mode`）、turn 尾部的计划卡；历史里的 `todo_write` 行仍展开出差异卡（而非 JSON） |
| S10 | **暗色模式** | S1 + S6 在 dark 下 | 任务条底 `rgba(67,69,74,.45)`、文字 `#F9FAFB`；完成点 `#22C55E`、待处理点 `#3C3C3D`；审阅 strip `#27241F`/`#F59E0B`；计划卡底 `#212123`、`打开` 底 `#2C2C2E` |

## 9. 未知与需确认

1. **TodoPanel 在 iOS 上的材质映射**：官方是 `backdrop-filter: blur(40px) saturate(150%)` + `rgba(248,249,250,.58)`（macOS 上因 `html[data-platform='darwin']` 变 `.94`，`design-platform.css:400-408`）。iOS WebView 的 `data-platform` 取什么值、原生端该用 `.ultraThinMaterial` 还是半透明纯色，需要真机对比截图定；两方案在浅色下差异可见（透过率），建议先用 `.94` 接近不透明的方案再调。
2. **计划审阅到达时是否自动打开全宽抽屉**：官方源码是"每次身份自动打开一次"（`PlanCard.tsx:72-82`），桌面 e2e 也依赖它（`plan-review.e2e.ts` 在点击前就断言 preview 可见）。但手机上是 402 全宽抽屉，会自动盖住刚弹出的审阅卡。**需产品决策**：手机端改为不自动打开，或改成底部半屏 sheet 并降到审阅卡下方。
3. **图标资源**：官方 `IconChecklistOutline`（双圆点 + 双横线）、`IconPlanOutline`（列表 + 笔）、`IconCloseCircleFill` 都是自绘 16-viewBox 描边图标；iOS 现有 asset 目录（`DSHThink/DSHCopy/…`，`NativeChatTheme.swift:47-65`）没有对应资源。需确认是否补 3 个 asset（推荐，像素才可能一致）还是用 SF Symbol 近似（`list.bullet.rectangle` / `xmark.circle.fill`），近似会有 1–2pt 的形态差。
4. **`ongoing` 状态环的动效参数**是否要在 iOS 上照搬（`1.5s` 线性旋转 + dash `12→24→12`）。SwiftUI 可用 `Circle().trim` + 重复动画近似，但相位对齐（官方把所有 loader 固定到文档时间零点）在原生端没有对应概念——是否需要"所有环同相位"，需设计确认。
5. **`todo_write` 差异卡的基线跨历史页**：官方有 `hasMore` 三分支（首写 / 有基线 / 旧清单不可用）。iOS 的 `loadEarlierTranscript`（`ChatPage.swift:731-747`）只追加 items，不重建工具/基线索引。是否要为此重算全部 diff 需确认（成本：一次 O(n) 重扫；建议在"加载更早"后对已渲染行的 diff 做一次重算）。
6. **`plan` 与 access mode 的关系**：官方严格分离（plan mode 只影响 prompt section 与 `exit_plan_mode` 工具可用性，不改沙箱）。iOS 现有 `"plan": "只出方案"` 映射的来源不明（宿主是否会下发 id 为 `plan` 的访问模式，`grep` 未在 iOS 侧找到调用方、官方 preset 也没有该档）。需确认后**删除**该行，避免两套语义并存。
7. **`session/projections` 与 `session/control` 的可用性**：iOS 只在管理页用过一次性 `session/projections`；`session/control` 增量流从未订阅。若 phone 通道（`plugins/channel`）没有转发 projection 增量，就只能靠事件自算（`todo/write` / `plan/mode`），需 axis 01 确认通道能力后再定方案。
8. **手机 WebView 里的官方页是否已经渲染这些 surface**：`examples/probe-app/Bundle/worker/web` 的静态产物里 grep 不到 `todo-panel` / `plan-review` / `Plan review` 等串（本次只做了字符串探测），但 apps/web 的 client plugin 可能按需动态加载，无法据此断言缺失。本轴结论**不依赖**该 bundle（全部证据来自官方源码仓库与 golden），仅在"是否已有可对照的线上实现"上留空。
9. **`/plan` 命令的本地化**：命令目录由宿主下发（`description: 'Enter or leave plan mode'`，`input.hint: '[off|message]'`，`packages/plan/plan-mode/src/index.ts:232-234`），官方 Web 的命令菜单也直接显示这段英文。iOS 的 slash 菜单同样显示英文（`ChatPage.swift:1852-1868`）——是否要为 `/plan` 单独做中文说明，需与 axis 08（composer）统一口径，本轴不单独发明文案。
