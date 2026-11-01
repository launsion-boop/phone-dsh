# PDSH UI 参考 v1 — 双端共同规范（normative）

Status: P0 · spec 版本 1 · MIT。适用端：iOS 基线（`examples/probe-app/PhoneDSHProbe/`，只读、不改）与 Android 承接端。

**镜像对象：已上线外壳（Chat + 抽屉）**，不是 `docs/design/phone-dsh-app/DESIGN.md` 的五 Tab 目标稿；该设计稿只作参考，不作为 parity 依据（owner 决定，2026-10-31）。

本目录回答一个问题：**同一串 Harness 事件，两个平台必须画出同一个界面状态**。规范从「事件 → UiState 投影」反写，
不从 SwiftUI 代码抽取实现细节；只有颜色/字号/间距/几何这类要镜像现状的值，才逐项标注来源 `file.swift:line`。

术语（本目录内定义，出现即此义）：

| 术语 | 含义 |
|---|---|
| 行（row） | UiState 树里的一个可见单位，颜色/字号/折叠态都挂在行上。 |
| 折叠（folded） | 连续的同类行（工具、上下文）合并成一行；展开只改内容可见性，不改行序。折叠态不跨会话保留。 |
| 签名面（signature surface） | 只做像素对表的 6 个组件，见 §4；其余一律按语义一致验收。 |
| 镜像 | Android 用固定 token 复现 iOS 默认外观；iOS 基线不做像素级改造（方案 §14.3-3）。 |
| fail-loud | 失败必须上屏、可重试、不静默降级；禁止只写日志。 |
| 未测项（unmeasured） | 值读不到；记 `null` + `provenance.tier = unmeasured`（来源可写定义处 `file:line`），**禁止编造**。 |
| 语义等价 | 两端交互结果相同；呈现形式允许不同，差异必须落在 §5 白名单内。 |

MUST / SHOULD / MAY 按 RFC 2119 读。权威顺序：**Harness 事件序列 > 交互状态机 > 语义一致 > 视觉一致**；
截图只作辅证，验收比对的是投影出的行序列。

自校验（失败退出 1；`--strict` 连 §4 的已登记无障碍债一起判失败）：

```
python3 spec/ui/v1/tools/ui_check.py --root . && python3 -m unittest discover -s spec/ui/v1/tools -p 'test_*.py' -v
```

checker 强制：tokens 过 schema；6 个签名面的 token 引用全部存在且含页面层几何；每个叶子 token 都有 `file:line` 来源
（缺来源、来源过期、颜色不来自 `NativeChatTheme.swift` 除非标了 `baselineInconsistency`，都失败）；WCAG 对比度
（正文 4.5 / 大字与非文本 3.0，已登记债在 `--strict` 下失败）；8 条平台差异与 §5 逐条对齐并带 type-role 映射；
页面清单覆盖基线里真实存在的每个 `*Page`；README ≤ 280 行；数据文件里不出现外链、邮箱、绝对用户路径。

`tokens.json` 是 token 的唯一来源；`golden/tokens.golden.json` 只是 schema 示例，不是规范来源。
来源分级：**颜色除 `onAccent`（平台常量）与 `ctaOverride`（页面层覆盖，已标 baselineInconsistency）外，一律来自
`NativeChatTheme.swift`；字号与间距来自三个 token 文件**（NativeChatTheme / Components / DSHComponents）；
**圆角、描边、动效与页面层几何允许来自页面层**，标 `tier: page`；系统语义字号标 `tier: system` 且 `needsDeviceMeasure: true`。取不到就 `unmeasured`。

## 1. 页面清单

页面按真实文件反推。入口 = 从哪儿打开；导航关系 = 打开后怎么回去。P5 列：`must` = 必须 parity，`later` = 可延后。

| 页面 | 职责 | 入口 | 导航关系 | P5 |
|---|---|---|---|---|
| ChatPage | 对话、输入坞、审批/问题卡、目标条 | RootView 的默认原生面（NativeShell） | 根页；自绘页头：抽屉 / 改名 / 运行状态 / `⋯` | must |
| SessionsPage | 会话列表、重命名、删除、开关 | 页头左按钮拉出抽屉（抽屉主体就是它） | 抽屉内常驻；选中会话即关闭抽屉 | must |
| SessionActivityPage | 单会话的步骤/用量/上下文 | **触发点缺失（sheet 已接线但无人置位，基线不可达）** | sheet | later |
| SessionHistoryPage | 历史回合列表与单回合详情 | 页头 `⋯` →「历史」，或 ChatPage 的目标行 | push；回合详情复用 ChatPage 的折叠规则 | later |
| GoalDetailPage | 单个目标的 objective / 状态 / 动作 | ChatPage 的目标条 | sheet；打开失败保留上一个目标（fail-quiet） | later |
| FilesPage | 工作区文件树、预览、导入 | 抽屉「工作文件夹」里点某个文件夹 | 页面栈；预览子页 FilePreviewPage | must |
| NativeWorkbenchPage | 会话内工作面板（文件 / 命令两段） | 对话里点工具写出的文件路径（含待预览路径补开） | sheet，`完成` 关闭 | must |
| PDSHShellPage | 只读加速器命令（argv 来自 caps） | 工作面板第二段、设置行「命令」 | 段内页面 | must |
| WorkspaceFoldersPage | 工作区文件夹增删与切换 | 抽屉「工作文件夹」 | push；每行打开 FilesPage | must |
| SettingsPage | 设置总入口与分组 | 抽屉底行「设置」 | sheet（NavigationStack） | must |
| ModelProviderSettingsPage | 模型服务、密钥、编解码 | 设置首行、起手卡「去配置模型服务」、启动失败横幅 | sheet | must |
| WebSearchSettingsPage | 网页搜索开关与后端 | 设置行、配置页 | push / sheet | must |
| MCPSettingsPage | MCP 服务器列表与编辑 | 设置行 | push / sheet；编辑子页 MCPEditorPage | must |
| NativeConfigurationPage | 会话级与插件配置 | 页头 `⋯` → 本会话设置 | sheet | must |
| NativeAutomationPage | 定时任务、计划详情与历史 | 抽屉「定时任务」、会话页入口 | push；子页 ScheduleDetailPage、ScheduleHistoryPage、ScheduleEditorPage | must |
| EgressAllowListPage | 出网白名单 | 设置行 | push | must |
| RuntimeDetailsPage | 运行时状态、停止与重启 | 页头运行状态点、设置行 | sheet | must |
| SettingsAboutPage | 版本、许可、开发者入口 | 设置 | push；子页 LicensesPage | must |
| WebSurfacePage | 完整 DSH 页面（WebView 宿主） | RootView 的默认面（引擎就绪时） | 全屏容器，不做返回栈 | must |
| MemoryPage | 记忆条目与来源 | 设置 → 探针工具（仅 DEBUG） | push | later |
| ProbesPage | 设备探针与报告 | 设置 → 探针工具（仅 DEBUG） | push | later |
| BackgroundPage | 后台保活诊断 | 设置 → 探针工具（仅 DEBUG） | push | later |
| TaskScreenPage | 任务屏预览 | 设置 → 探针工具（仅 DEBUG） | push | later |
| ExportPage | 导出诊断包 | 设置 → 探针工具（仅 DEBUG） | push / sheet | later |
| DailyBriefPage | 每日简报 | **基线无入口（孤页）** | 不可达 | later |

内嵌子页随父页实现、不单独排期：CommandExecutionResultPage、ModelProviderEditorPage、SessionQueuePage、PermissionDefaultsPage、DevelopmentToolsPage、DeveloperPage。开发者页由连续点击版本号进入，仅 DEBUG 存在。

页面结构另有机器可读契约：`pages/<page-id>.json`（分区 / 行 / 动作 / 呈现，每项带 `file:line` 来源，由 `tools/extract_ios_pages.py` 从基线抽取），`tools/page_structure_check.py` 用它比对 Android 页面；平台被迫差异只走 `pages/_whitelist.json`（每条 MUST 引用 `spec/platform/whitelist.json` 的 id），已知差异记 `pages/_baseline.json` 且只减不增，`--strict` 输出待对齐清单。非 `Section` 的分组（`PageSection` / `GroupBox` / 粗体标题 `Text`）记 `kind: region`，识别不出的记 `implicit`（不整页跳过）；`states` 只作人读（`"advisory": true`，比较器不读）；Android 无 iOS 对应的页登记在 `pages/_android-only.json`，有 `public fun *Page()` 却既无契约也不在该文件里即失败。
契约标题 MUST 是**渲染形态**：`dynamicTitle:true` 只表示「固定模板 + 一个可变量」（`title:"Rows (N)"` + `titleTemplate:"Rows ({model.probeRows.count})"`，比较用 template、数字与模板槽归一到 `#`）；标题**就是数据**（`Section(fileGroupTitle)`）记 `title:null` + `titleSource:"expression"` + `titleExpression` + `criterion`，不许冒充 `dynamicTitle`；`title` 里出现源码表达式即契约错误，Android 把表达式当字面量渲染 → `extra-section`。
无标题/数据即标题的分区 MUST 带 `criterion`（首个可点行 / 首行标签）：checker 找该行、看它之前**有没有** Android 标题——没有=一致，有=`extra-section`，找不到行=`missing-section`；确无字面判据的项登记在 `pages/_unrecognized.json`（owner + reviewBy + 理由，stale 即失败）；基线自身的死 UI 在契约里标 `deadUi` + 证据，由 checker 归类为「已确认、勿实现」，整页一坨的页记 `sectionModel:"single-region"` + 说明。
Android 侧的分区 / 动作 MUST 走 `SessionSectionLabel`、`SectionHeader(title=...)`、`*SectionView(_, title)` 与 `SessionTextAction(label=...)`、`InfoRow(..., onClick=...)`；标题是表达式时记 `unresolved`，不当作一致。车道统一用 `SessionTextAction` 会让 gate 变精确——`Row(.clickable){BasicText}` 与 `ImeAction.Search` 搜索框只是兜底启发式。
判据（决定冲突往哪边修）：gate 看不见正确实现时修 gate；实现把信息藏起来（数据驱动标题、拼出来的字符串）时修实现——区别是信息是否在源码里显式可见。
标准控件也算动作：`Button`/`OutlinedButton`/`TextButton`/`FilledTonalButton`、`SegmentedButton`/`FilterChip`、`Switch`/`Checkbox`、`DropdownMenuItem`、页内 `label:` 包装器取内容里第一个 `Text(text=…)`；`Switch` 只认同一 `Row`/`Column` 直接子节点里最近的 `Text`。

### 1.1 已知基线观察（只记录，不改基线）

| 观察 | 证据 | P5 处置 |
|---|---|---|
| SessionActivityPage 的 sheet 已接线但无人置位 | `ChatPage.swift:51` 声明、`ChatPage.swift:292` 接线，全仓无 `showActivity = true` | 不实现；iOS 恢复入口再开 |
| DailyBriefPage 没有任何入口 | `DailyBriefPage.swift:8` 有页面，全仓无调用点 | 不实现；iOS 恢复入口再开 |
| NativeTab 四 Tab 枚举是死代码 | `NativeShell.swift:12` 定义、全仓无引用；实际外壳 = Chat + 抽屉 | 按 §1 的抽屉外壳实现，不实现 Tab 栏 |
| ChatPage 自带一份调色板，与主题层不一致 | `ChatPage.swift:716` accent #2F5BFF、`ChatPage.swift:717` surface #F2F3F5、`ChatPage.swift:723` hairline #DDDCE2 vs `NativeChatTheme.swift:20/14/18` | accent 记为 `colors.ctaOverride`（§4 债表）；hairline/surface 只记录 |

## 2. 组件语义清单

行为定义，不写像素。每条都能从事件序列判定真值。

| 组件 | 出现 | 折叠 / 展开 | 消失 |
|---|---|---|---|
| 工具行（tool run） | 首个 `tool_call` 起；**连续**的工具行（不分回合）合并为一行 | 默认折叠，行内只留标题 + 首行摘要；运行中摘要扫光；`tool_result` 到达只改状态与摘要，不移动行位；点标题展开，无详情时按钮 disabled | 只随会话切换/回合清理消失，不因结果到达而移除 |
| thinking_pill（思考行） | `assistant_message` 的 `reasoning` 块且文本非空 | 默认折叠；流式中摘要 = 最后一个双换行段的首行，去 `**`；流式结束保留摘要、停扫光 | 文本为空则整行不出现 |
| 审批卡 | `permission_requested` | 与问题卡共用一个槽位，合计最多 2 项；两张同时待办时审批卡在上、问题卡折成「还有 1 个待确认」一行；卡片区最高 40% 屏高，超出内部滚动；键盘弹起且未手动展开时整区折成「N 项需要处理」 | 允许一次 / 拒绝后立即消失；停止或切会话时本地清除 |
| 问题卡 | `question_requested` | 单选/多选/自定义答案，全部必答才能提交；折叠与槽位规则同上 | 提交后消失；同时刻最多一张 |
| NativeChangedFilesCard | 回合末最后一条非流式 assistant 行 | 按 `turn` 聚合成功的 `write`/`edit`/`str_replace_editor`；同路径后者覆盖前者；>4 个文件只列 4 个 + 「全部 N 个文件」 | 回合结束仍保留；清除随会话切换 |
| composer | 常驻页面底部 | 有字/无字/运行中三态；运行中发送键变停止键；`steer` 模式插话、`queue` 模式排队（排队显示「排队中 N 条」）；`/` 开指令、`@` 引用 | 审批卡或问题卡在屏时整体禁用（不是隐藏） |
| fail-loud 横幅 | 发送被拒、回合失败、工具失败 | 发送失败：草稿保留 + 失败行贴在原消息下；回合失败：顶部横幅 + 重试 + 关闭；工具失败：工具行内失败卡 | 只能由用户手势关闭，或下一次发送成功；不允许自动消失 |

页头 `⋯` 里的「导出对话记录」是**页内动作**，parity 到 Android 的平台分享 affordance（形态差异见 §5 `share-sheet`）；Android 不注册为外部分享目标、不做深链。

## 3. 交互状态机

Event 是 Harness 事件或用户动作；事件名一律用 host kind（`spec/host/v1/schema/harness-event.schema.json`）。
标 synthetic 的两族没有 host kind，是投影行，规则见 `spec/host/v1/event-kinds.md`。Transition 表即投影规则，两端必须逐行一致。

| Event | From | To | Side effect |
|---|---|---|---|
| 用户发送（idle） | idle | running | 清空草稿；插入 user 行；滚到尾部 |
| 用户发送（running，queue） | running | running | 插入 user 行；行下标签「已排队」；输入坞显示排队条 |
| 用户发送（running，steer） | running | running | 发 steer；行下标签「已并入当前任务」 |
| `turn_started` | running | running | 队列标签「已排队」→「发送中…」 |
| `turn_ended` ok | running | idle | 清全部排队/发送中标签；结束流式 |
| `turn_ended` error | running | failed | 顶部横幅；失败行；失败消息 id；与「发送中…」互斥 |
| `turn_ended` aborted / interrupted | running | idle | 本回合 running 的工具行 → stopped |
| 点击折叠行标题 | collapsed | expanded | 只改该行内容可见性；行序与滚动位置不变 |
| 展开时新结果到达 | expanded | expanded | 内容原地更新，不自动折叠 |
| 会话切换 / 回合清理 | 任意 | idle | 折叠态、排队标签、待回答卡全部重置 |
| 键盘弹起（有待回答卡） | pending | pending | 卡片区折成「N 项需要处理」，点开后恢复 |
| 停止键 | running | stopping | 清待回答卡；发 cancel，3 s 上限；到期本地结束并写状态行 |
| 发送被拒（无产生行） | idle | idle | 草稿回填；失败行；不丢用户输入 |
| `llm/retry*`（synthetic） | running | running | 系统事件行「模型请求重试」 |
| `compaction/*`（synthetic） | running | running | 系统事件行「上下文已整理」 |
| 目标读取成功 | 任意 | goal 可见 | 目标条：阶段 + 目标一行 + 暂停/继续 + 清除 |
| 目标 phase=active | goal 可见 | goal 可见 | 显示「暂停」；paused/blocked 显示「继续」 |
| 清除目标 | goal 可见 | goal 不可见 | 发 `/goal clear` 后重读 |
| 目标读取失败 | 任意 | 不变 | 保留上一个目标（fail-quiet，只记状态行） |
| `permission_requested` | running | pending | 审批卡上屏；composer 禁用 |
| 允许一次 / 拒绝 | pending | running | 发 permissionResponse；卡片消失；清错误 |
| 停止 / 切换会话 | pending | none | 本地清除待回答，不阻塞后续操作 |
| 切换会话（pending 未答） | pending | pending | 拒绝切换并给出原因；会话不变 |
| `question_requested` | running | pending | 问题卡上屏；composer 禁用 |
| 提交回答 | pending | running | 发 questionResponse；卡片消失 |
| 工具结果 isError | running | running | 工具行 state=error + 失败卡；可展开看输出 |
| 宿主状态 fail | 任意 | failed | 状态行「失败」；提供停止/重启入口 |

### 3.1 Two layers: UiState and ScreenState

Parity is asserted on **two different object graphs**, and conflating them is how a port drifts.

| Layer | What it is | Where it is specified | How parity is asserted |
|---|---|---|---|
| **UiState** | The ordered, event-anchored projection of a harness event stream: one node per row that a trace can point at. Its node ids are `session/<sid>/turn/<tid>/event/<seq>[/<slot>]`. | `spec/v1/trajectory.md` §7, `spec/v1/schema/ui-state-sequence.schema.json` | same event stream on both hosts → byte-identical UiState sequence (after trajectory normalisation) |
| **ScreenState** | The view-local state a screen owns on top of UiState: composer draft, focus, collapsed/expanded rows, scroll anchor, transient banners. It has **no event anchor** by design, so it cannot live in the UiState sequence. | this section | same UiState + same local UI event script → same ScreenState sequence |

**Rules.**

1. A node that cannot be given a legal UiState id belongs to ScreenState, not UiState. `composer` is the canonical example: it reflects local input, not a harness event.
2. A rendering convenience is ScreenState even when it looks like it re-groups UiState rows. "Consecutive tool calls fold into one row" is a fold over UiState **at render time**; the UiState sequence keeps one node per event so a trace can still be located.
3. ScreenState is a **pure function** of (UiState, local UI events). **On a page with no harness
   event anchor** (settings, tools, files, memory, about) the UiState-side input is the host's
   read-only snapshot of that page's facts; the same purity and the same sequence assertion apply.
   A page may not read the clock, the network or the engine directly on either kind of page. It may not read the clock, the network, or the engine directly. That is what makes it replayable in a JVM test.
4. A parity assertion that needs a screenshot is a **third** thing and is limited to the six signature surfaces (§4); it never substitutes for 1 or 3.

This section exists because the first implementation hit exactly this fork: `composer` had no legal UiState id and folding had no place in the sequence. Recording the split here beats deciding it once per port.

## 4. 签名面

只有这 6 个面做像素对表。页面层几何已按 owner 决定吸收进 `tokens.json` 的 `geometry`（值 + 单位 + `scalesWith`），
下表引用的就是比对基值；其余页面按语义一致验收。表中每面写出的 token 与 `tokens.json` 的 `signatureSurfaces.<面>.tokens` **集合相等**，由 checker 双向强制（少写、多写都失败），表头也必须给每个 token family 留一列。

| 签名面 | 颜色 / 字号 / 圆角 / 描边 / 动效 / 间距（`spacing.*`） | 页面层几何（`geometry.*`） |
|---|---|---|
| 气泡 | `colors.selector` `colors.primary` `colors.secondary` `typography.body` `typography.secondary` `radius.bubble` | `bubblePadding` `bubbleLineSpacing` `bubbleMaxWidth` |
| 工具行 | `colors.code` `colors.codeBanner` `colors.border` `colors.secondary` `colors.tertiary` `typography.code` `typography.secondary` `typography.codeLabel` `radius.codeBlock` `stroke.hairline` `motion.disclosure` | `disclosureRowHeight` `disclosureIconGap` `toolDetailIndent` `toolDetailVertical` `toolCardInset` `terminalCardMaxHeight` |
| thinking_pill | `colors.secondary` `colors.tertiary` `colors.caption` `typography.secondary` `typography.shimmer` `motion.shimmer` | `disclosureRowHeight` `summaryDotDiameter` `summaryDotGap` `thinkingContentIndent` `thinkingContentVertical` |
| 审批卡 | `colors.selector` `colors.primary` `colors.ctaOverride` `colors.onAccent` `colors.secondary` `typography.headline` `typography.subheadline` `radius.card` `spacing.iconText` | `cardPadding` `cardOuterMarginH` `cardOuterMarginV` `primaryButtonHeight` `secondaryButtonHeight` `cardAreaMaxHeightRatio` |
| composer | `colors.input` `colors.borderLight` `colors.accent` `colors.onAccent` `colors.tertiary` `colors.secondary` `colors.primary` `typography.body` `typography.secondary` `radius.composer` `stroke.hairline` `spacing.iconText` | `composerMinHeight` `composerMaxHeight` `composerControlSize` `sendButtonDiameter` `inlineStopDiameter` `composerTrailingReserve` `composerOuterMarginH` `composerOuterMarginTop` `composerOuterMarginBottom` `statPillMinHeight` |
| fail-loud 横幅 | `colors.warning` `colors.danger` `colors.secondary` `typography.secondary` `typography.caption` | `bannerGap` `bannerInsetH` `bannerInsetV` `toolFailureBannerInset` |

本轮实测的页面层几何**全部是固定值**（iOS 用固定 `frame`，全仓无 `@ScaledMetric`），所以每条 `scalesWith` 都是
`null`；若 P5 要让某条几何随字号派生，必须把 `scalesWith` 指向对应 `typography.*` 并走评审——checker 会拒绝
指向不存在的字号 token 的派生。

审批卡的标题/副标题是系统语义字号，记成 `tier: system` 的 token：`headline` 17pt/600、`subheadline` 15pt/400，
来源 `platform default, not measured in this repo` 且 `needsDeviceMeasure: true`；仍走 `baseSize × 平台缩放系数`，
不写死渲染尺寸。Android 的 type-role 映射见 §5。

字体映射（两端都不打包字体；字形差异归 §5 的 cjk-fallback）：

| 角色 | iOS | Android | 字重 |
|---|---|---|---|
| 正文 / 次要文字 | 系统 SF Pro Text | 系统默认无衬线（Roboto 或厂商替代） | 400 |
| 强调（标题、主按钮） | SF Pro Text + semibold | 系统默认 + w600 | 600 |
| 等宽（代码、终端、JSON） | SF Mono（monospaced 设计） | `monospace` 等宽族 | 400 |

### Baseline accessibility debt（已登记基线无障碍债）

按镜像决定保留现值，**不改 token 值**（改值等于改 iOS 外观，方案 §14.3-3 已明确不做）。checker 逐条打印实测比值，
`--strict` 下全部失败；deferred 上限 8 条，**新增 deferred 或超出上限必须走评审**。Android 镜像 iOS 默认外观，
因此继承这笔债：`owner` 与 `reviewBy` 就是复核入口，到期未复核即视为未处置。

| 配对 | 类 | 实测（light / dark） | owner | reviewBy | 为什么镜像现状会低于 AA |
|---|---|---|---|---|---|
| `onAccent/accent` | 文本（大字号） | 4.74 / **2.66** | iOS UI owner | 2027-03-31 | composer 发送键把白箭头压在 token 深色 accent 上 |
| `success/selector` | 文本 | **4.07** / 5.12 | iOS UI owner | 2027-03-31 | 变更卡 +N 用 success 墨色 |
| `danger/selector` | 文本 | 4.90 / **4.40** | iOS UI owner | 2027-03-31 | 变更卡 -N 用 danger 墨色 |
| `tertiary/input` | 文本 | **2.79** / **4.18** | iOS UI owner | 2027-03-31 | 文件名行用弱墨 tertiary |
| `caption/code` | 文本 | **1.98** / 4.54 | iOS UI owner | 2027-03-31 | 读文件卡的行号列 |
| `border/input` | 非文本（纯装饰） | **1.27** / **1.37** | iOS UI owner | 2027-03-31 | 纯装饰分隔线，无文本承载；描边不是唯一可见边界 |
| `borderLight/input` | 非文本（纯装饰） | **1.15** / **1.18** | iOS UI owner | 2027-03-31 | 纯装饰分隔线，无文本承载；输入坞还有投影与底色 |

`onAccent/accent` 的 2.66 是按 token 深色值算的；审批卡 CTA 实际用页面固定色 #2F5BFF（白字 5.17），已记为
`colors.ctaOverride` 并单独配对 `onAccent/ctaOverride`（required，5.17 通过）。也就是说这条债不是「iOS 现状读不出来」，
而是「**照 token 镜像会倒退**」：P5 前必须裁决 accent 取 token（#3964FE/#679EFE）还是取页面固定值（#2F5BFF）。

P5 工作项：由 `tokens.json` 生成 Swift/Compose token 文件（P0 不做，消费者在 P5 才存在）；生成物必须与源一同校验。

### 页面级几何（page-level geometry）

`geometry` 里没有被任何 `signatureSurfaces.*.tokens` 引用的条目就是页面级 token；当前 5 条（`pageOuterMarginH` `pageHeaderMinHeight` `pageRowMinHeight` `pageListRowMinHeight` `statusDotDiameter`）。
`PageGeometryTokenTest` 把它收敛成一条不变量：**每条 geometry 要么被某个签名面引用，要么被 ≥2 个页面源文件使用**——孤儿 token（既无签名面、又不足 2 个页面）直接红。

可以进 token：跨 ≥2 个页面、语义独立于签名面。允许继续复用签名面几何：只有一个页面用的长度（搜索框高度 `composerMinHeight`、分节标签纵向内边距 `cardOuterMarginV`、列表行距 `disclosureIconGap`），
以及签名面自己的尺寸（审批卡 `cardAreaMaxHeightRatio`），这些调用点保留 `unverified geometry`。页面级值对齐 iOS `NativeHeaderStyle`：页头 `pageHeaderMinHeight` 44、
状态点 `statusDotDiameter` 8（原 48/2 是误用主按钮高度与误抄摘要点，已修正）。页面级 token 暂记在 `geometry` 与 `provenance`（`tier: page`）：
`signatureSurfaces` 被 checker 固定为 6 个面，schema 还没有页面 surface 概念。

## 5. 平台差异白名单

只有下表 8 条允许两端呈现不同（方案 §9.2-5 的 7 条 + owner 追加的 `share-sheet`）；每条都要「语义等价声明」，
未列入按语义一致验收（像素对表仍限 §4 的 6 个面）。

| id | Android | iOS | 语义等价声明 |
|---|---|---|---|
| back-gesture | 系统预测性返回：页面栈逐级出栈，根页面退出应用 | 左上返回按钮 + 边缘右滑 | 返回后所处页面与栈深度相同；Android MAY 用预测性动画，state 变更序列 MUST 一致 |
| font-scale | `fontScale` × 基准字号（sp） | Dynamic Type × 基准字号 | 只读系统缩放系数；**缩放曲线由平台决定，可能是非线性**；不裁剪、不横滚。判据见 §5.1 容差 |
| ime | IME 候选栏与 insets 动画由系统驱动 | 键盘安全区推挤 composer | composer 始终可见于 IME 之上；发送后列表位置与内容一致 |
| insets | targetSdk 35 强制 edge-to-edge，显式消费系统栏 insets | safe area | 内容不被系统栏遮挡；页头与 composer 的可点区域等价 |
| scroll-refresh | 下拉刷新在列表顶部，带平台惯性 | 下拉刷新 + 尾部跟随 | 刷新后停留位置等价；「跟随尾部」在两端都是同一条件触发 |
| fgs-notification | 前台服务常驻通知：回合状态 + 进度 + 「停止」按钮 | 后台保活静默期，无通知 | 通知是回合执行中的唯一界面；「停止」走同一 cancel 路径，副作用与 App 内停止一致 |
| cjk-fallback | 系统 CJK 回退链，等宽字形按字体族回退 | 系统 CJK 回退链 | 同一字符串两端字形可不同，但行数、换行点、复制结果 MUST 一致 |
| share-sheet | 页内动作「导出对话记录」调系统 share sheet | 系统 activity sheet | 同一动作、同一内容，面板形态由平台提供；**不注册外部分享目标、不做深链** |

系统语义字号的 type-role 映射（只这两档走平台字号；其余字号仍是固定 token）：

| token | iOS | Android | 容差 |
|---|---|---|---|
| `headline`（17/600） | `.headline` | Material `titleMedium` | 平台角色无 17 档，允许 ±2pt，不做像素级 |
| `subheadline`（15/400） | `.subheadline` | Material `titleSmall` | 同上 |

```json
{"platformDivergences": [
  {"id": "back-gesture", "android": "预测性返回逐级出栈，根页退出", "ios": "返回按钮与边缘右滑", "equivalence": "返回后页面与栈深度相同，state 序列一致", "tokens": ["motion.disclosure"]},
  {"id": "font-scale", "android": "fontScale 乘基准字号", "ios": "Dynamic Type 乘基准字号", "equivalence": "只读系统缩放系数；曲线可为非线性，按 §5.1 的 ±2sp 容差判定", "tokens": ["typography.body", "typography.secondary"], "mapping": {"typography.headline": "Material titleMedium", "typography.subheadline": "Material titleSmall"}},
  {"id": "ime", "android": "IME 候选栏与 insets 动画由系统驱动", "ios": "键盘安全区推挤输入坞", "equivalence": "输入坞始终在 IME 之上，发送后列表位置一致", "tokens": ["geometry.composerOuterMarginH"]},
  {"id": "insets", "android": "targetSdk 35 强制 edge-to-edge 并消费 insets", "ios": "safe area 自动内缩", "equivalence": "内容不被系统栏遮挡，可点区域等价", "tokens": ["geometry.composerOuterMarginTop"]},
  {"id": "scroll-refresh", "android": "列表顶部下拉刷新，平台惯性", "ios": "下拉刷新加尾部跟随", "equivalence": "刷新后停留位置等价，跟随尾部条件相同", "tokens": ["motion.disclosure"]},
  {"id": "fgs-notification", "android": "前台服务通知含回合状态、进度与停止按钮", "ios": "后台保活静默期无通知", "equivalence": "通知是回合执行中的唯一界面，停止走同一 cancel 路径", "tokens": ["motion.composerSend"]},
  {"id": "cjk-fallback", "android": "系统 CJK 回退链，等宽族回退", "ios": "系统 CJK 回退链", "equivalence": "字形可不同，行数与换行点及复制结果一致", "tokens": ["typography.code", "typography.jsonBody"]},
  {"id": "share-sheet", "android": "系统 share sheet", "ios": "系统 activity sheet", "equivalence": "同一页内动作与同一内容；不注册外部分享目标，不做深链", "tokens": []}
]}
```

### 5.1 Font scaling is not linear (measured), and parity needs a tolerance

Android 14 and later apply a **non-linear** font-scale converter. Measured during the port: `14sp` at
`fontScale = 2` renders **26px, not 28px**. A rule that says "rendered size = baseSize × factor" is
therefore wrong on the platform it is meant to describe, and a test built on it fails a correct
implementation.

- A type token carries a **base size in `sp`** (iOS: points). It never carries a pixel value.
- The rendered size comes from the platform's own scaling, linear or not. Implementing the platform's
  scaling is correct; re-deriving a linear value and then fighting the platform is not.
- **Parity tolerance** for a signature surface's typography: same base size, and rendered sizes within
  **±2sp** of each other at the same user font scale. Dynamic Type and Android font scale are
  different curves; exact equality is not something either platform can promise.
- A layout assertion that depends on text height must use the measured height, never a computed one.

**Tool-row shimmer belongs to `thinking.pill` only.** The component list in §2 asks for a running
summary sweep; the token inventory for `toolRow` never had `motion.shimmer` / `typography.shimmer`.
The sweep is the thinking pill's signature effect, and a second animated row competes with it for the
same attention. `toolRow` therefore shows static state text; the sweep stays on `thinking.pill`.

