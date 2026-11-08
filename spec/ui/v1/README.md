# PDSH UI 参考 v1 — 双端共同规范（normative）

Status: P0 · spec 版本 1 · MIT。适用端：iOS PR22 基线 `examples/probe-app/PhoneDSHProbe/`（只读，不改）与 Android 承接端。

**镜像对象：PR22 的已上线外壳（ChatPage 首页 + HomeDrawer 抽屉）**，设计帧 430×932pt。旧的 402×874 主题和
`docs/design/phone-dsh-app/DESIGN.md` 的五 Tab 目标稿都已 superseded：`NativeChatTheme` 的 402pt 数值只保留历史
出处，不再作为颜色/字号/间距权威。权威顺序：`HomeSpec.swift` 的颜色、字号、间距、尺寸与圆角；HomeSpec 没有定义
的页面层长度来自 owning page，并逐项标 `file:line`。本文件只改 token 层，不改 iOS/Swift 或 Android 代码。

本目录回答一个问题：**同一串 Harness 事件，两个平台必须画出同一个界面状态**。规范从「事件 → UiState 投影」反写，
不从 SwiftUI 代码抽取实现细节；只有颜色/字号/间距/几何这类要镜像现状的值，才逐项标注来源 `file.swift:line`。

术语（本目录内定义，出现即此义）：

| 术语 | 含义 |
|---|---|
| 行（row） | UiState 树里的一个可见单位，颜色/字号/折叠态都挂在行上。 |
| 折叠（folded） | 连续的同类行（工具、上下文）合并成一行；展开只改内容可见性，不改行序。折叠态不跨会话保留。 |
| 签名面（signature surface） | 只做像素对表的 6 个组件，见 §4；其余一律按语义一致验收。 |
| 镜像 | Android 用固定 token 复现 PR22 HomeSpec 默认外观；iOS 基线不做像素级改造。 |
| fail-loud | 失败必须上屏、可重试、不静默降级；禁止只写日志。 |
| 未测项（unmeasured） | 值读不到；记 `null` + `provenance.tier = unmeasured`（来源可写定义处 `file:line`），**禁止编造**。 |
| 语义等价 | 两端交互结果相同；呈现形式允许不同，差异必须落在 §5 白名单内。 |

MUST / SHOULD / MAY 按 RFC 2119 读。权威顺序：**Harness 事件序列 > 交互状态机 > 语义一致 > 视觉一致**；
截图只作辅证，验收比对的是投影出的行序列。

同一轮可有多个独立的过程组。Android 会话列表用每组首个可见事件的完整行 ID
区分它们。事件类型后缀不能用作身份，后续工具结果不应改动组的身份。


本 lane 的自校验（失败退出 1；`--strict` 连 §4 的已登记无障碍债一起判失败）：

```
python3 spec/ui/v1/tools/ui_check.py --root .
python3 -m unittest spec.ui.v1.tools.test_ui_check -v
```

**验收顺序**：除 `ui_check.py --root .` 和 `test_ui_check` 外，P0 还运行页面结构及源码契约检查。
`extract_ios_pages.py --check` 的缺失或过期契约必须修复；不能仅因页面出现在下表就视为结构契约完整。
源码提取不证明条件编译配置或页面行为，相关限制分别见 baseline GAP-19 和 GAP-21。

checker 强制：tokens 过 schema；6 个签名面的 token 引用全部存在且含页面层几何；每个叶子 token 都有 `file:line`
来源，且该行必须仍存在并包含 token 名/值（页面层长度可用 `expect` 片段；来源过期即失败）；颜色、字号、间距必须
来自 `HomeSpec.swift`；仍被 PR22 使用的组件 token（0.5 hairline、ShimmerText 动效、发送/复制动效）保留 owning
page/component 出处；只有页面层几何/动效可标 `tier: page`；WCAG 对比度（正文 4.5 / 大字与非文本 3.0，已登记债
在 `--strict` 下失败）；8 条平台差异与 §5 逐条对齐并带 type-role 映射；页面清单覆盖基线里真实存在的每个 `*Page`；
README ≤ 345 行（PR22 新增类型/几何表，cap 319→345，规则变更记录在 `tools/ui_check.py`，不删页面）；数据文件里
不出现外链、邮箱、绝对用户路径。

`tokens.json` 是生成 Kotlin 的唯一来源；`golden/tokens.golden.json` 只是 schema 示例。来源分级：
**HomeSpec 主题色/字号/行高/间距来自 `HomeSpec.swift`；PR22 仍在用的组件色/字号/几何来自其当前
`NativeParityTokens.swift`、`Components.swift` 等 owning 文件；旧名只通过 `aliases` 指向规范 leaf**，不复制第二张表；
取不到就记 `unmeasured`，不写假值。Swift 只进入已复核的 JSON provenance，生成器不再并行解析 Swift/HTML。

## 1. 页面清单

页面按真实文件反推。入口 = 从哪儿打开；导航关系 = 打开后怎么回去。P5 列：`must` = 必须 parity，`later` = 可延后。

入口分三类，别混。**可达** = 产品里点得到；**预览专用** = 只有 DEBUG 的 `-uiPreview` 路由（`NativeShell.swift` 的 `PreviewScreen`），产品没有入口；**不可达** = 连预览路由都没有，只剩结构体。PR22 把首页改成 ChatPage、抽屉改成 HomeDrawer、设置改成一组分组索引：SessionsPage 只剩预览路由，about / network / 文件夹回到设置行，MCP 与局域网设备、SSH、蓝牙设备及 Android ADB 均有设置入口。

| 页面 | 职责 | 入口 | 导航关系 | P5 |
|---|---|---|---|---|
| ChatPage | PR22 首页：对话、输入坞、审批/问题卡、目标条；空对话也是首页 | RootView 的默认原生面（NativeShell） | 根页；自绘页头：抽屉 / 改名 / 设备+更多（含产物、工作区、运行状态、插件与工具、导出） | must |
| SessionsPage | 抽屉会话列表（PR22 已不是产品首页） | **预览专用（`-uiPreview sessions`、`DrawerPreview`）；产品抽屉换 HomeDrawer** | 预览壳；选中会话即关闭 | later |
| SessionActivityPage | 单会话的步骤/用量/上下文 | **触发点缺失（sheet 已接线但无人置位，基线不可达）** | sheet | later |
| FilesPage | 工作区文件树、导入 | Chat 工具写出路径；文件段内联 | 页面栈；文件行 push `PreviewSurface`（独立预览面，契约 `pages/preview-surface.json`） | must |
| NativeWorkbenchPage | 会话内工作面板（文件 / 命令两段） | 对话里点工具写出的文件路径 | sheet，`完成` 关闭 | must |
| PDSHShellPage | 只读加速器命令（argv 来自 caps） | 文件段旁的「命令」段 | 段内页面 | must |
| WorkspaceFoldersPage | 工作区文件夹增删与切换 | 设置 › 文件夹 | push；每行打开 FilesPage | must |
| SettingsPage | PR22 分组设置索引：模型与智能体 / 权限与隐私 / 对话 / 会话与文件 / 引擎 / 关于 | 抽屉底栏「设置」、Chat `⋯` → 设置 | sheet（NavigationStack）；行 push 子页；`initialTab` 深链仅 `-uiPreview settings.permissions.tab` | must |
| FontSizeSettingsPage / ConversationSettingsPage / ArchivedSessionsPage | 字号 / 工作过程 / 已归档会话（设置内嵌子页） | 设置 › 字号 / 工作过程 / 已归档会话 | 随 SettingsPage 实现、不单独成页；已归档行可恢复 | must |
| NativeShortcutsPage | 快捷键对照与恢复全部默认 | 设置 › 对话 › 快捷键 | push，返回设置索引 | must |
| PhonePermissionsPage | 手机权限清单、能力授权与最近审计 | 设置 › 手机权限（`embedded: true`） | push；授权走系统弹窗 | must |
| NativeAgentPresetsPage | Agent 预设列表、设为默认、配置入口 | 设置 › Agent 预设 | push；预设卡进入会话 | must |
| NativePluginInventoryPage | 内置插件清单、搜索 | 插件与工具 → 已加载插件 | push；搜索/刷新 | must |
| ModelProviderSettingsPage | 模型服务、密钥、编解码 | 设置 › 模型服务；Chat 起手卡/启动失败横幅 | push；编辑子页 ModelProviderEditorPage | must |
| SessionArtifactsPage | 本会话产物、未归属产物与预览 | 页头 `⋯` →「产物」 | sheet；预览子页 SessionArtifactPreviewPage | must |
| SessionArtifactPreviewPage | 单个产物的内容预览 | SessionArtifactsPage 的行点击 | 内嵌 sheet，不单独成页 | must |
| NativeDeviceConnectionPage | 已配对的真机连接与传输能力 | 页头设备按钮 →「设备连接」 | sheet；行打开 NativeDeviceSessionPage | must |
| NativeDeviceSessionPage | 只读的设备会话转录（历史、实时） | NativeDeviceConnectionPage 的行 | push，只读，无写动作 | later |
| NativeConfigurationPage | 会话级与插件配置 | 页头 `⋯` → 本会话设置；设置 › 插件与工具 | sheet | must |
| WebSearchSettingsPage | 网页搜索开关与后端 | 插件配置 → 网页搜索与抓取 | push / sheet | must |
| MCPSettingsPage | MCP 服务器列表与编辑 | 设置 › 权限与隐私 › MCP 与局域网设备 | push；编辑子页 MCPEditorPage | must |
| NativeAutomationPage | 定时任务、计划详情与历史 | 抽屉「定时任务」；`-uiPreview sessions.schedules` | push；子页 ScheduleDetailPage、ScheduleHistoryPage、ScheduleEditorPage | must |
| EgressAllowListPage | 出网白名单 | 设置 › 网络访问 | push | must |
| RuntimeDetailsPage | 运行时状态、停止与重启 | 设置 › 引擎 › 运行状态；Chat 页头运行状态 | sheet | must |
| SettingsAboutPage | 版本、许可、开发者入口 | 设置 › 关于 Phone DSH | push；子页 LicensesPage | must |
| WebSurfacePage | 完整 DSH 页面（WebView 宿主） | **iOS 已删除（495da9b5）；Android 侧是独立全屏宿主，见 `pages/_android-only.json`** | 全屏容器，不做返回栈 | later |
| MemoryPage | 记忆条目与来源 | **不可达（开发者工具页已随 PR #13 删除）** | push | later |
| ProbesPage | 设备探针与报告 | **不可达（同上）** | push | later |
| BackgroundPage | 后台保活诊断 | **不可达（同上）** | push | later |
| TaskScreenPage | 任务屏预览 | **不可达（同上）** | push | later |
| ExportPage | 导出诊断包 | **不可达（全仓无调用点）** | push / sheet | later |
| DailyBriefPage | 每日简报 | **基线无入口（孤页）** | 不可达 | later |
| ChatPreferencesPage | 聊天外观、字号、过程折叠、转录密度 | **不可达（全仓无调用点；设置已改分组索引）** | push | later |
| NativeSettingsDocumentPage | 配置文件的只读查看与分享 | **不可达（全仓无调用点）** | sheet | later |
| SSHSettingsPage | SSH 主机设置；完整结构契约待补 | 设置 › 权限与隐私 › SSH 主机 | push；编辑器与指纹确认需单独核对 | must |
| BluetoothDevicesPage | 蓝牙设备扫描与连接；完整结构契约待补；iOS 断连等待及不可用状态见 [P07 本地授权条款](../../device/v1/ble-link.md#ios-standard-gatt-authorization-ordering) | 设置 › 权限与隐私 › 蓝牙设备 | push；设备任务入口默认关闭 | must |
| AndroidADBSettingsPage | Android ADB 设置；完整结构契约待补 | 设置 › 权限与隐私 › Android ADB | push；测试连接含网络与密钥操作 | must |

内嵌子页随父页实现、不单独排期：CommandExecutionResultPage、ModelProviderEditorPage、SessionQueuePage、PermissionDefaultsPage、LicensesPage、FontSizeSettingsPage、ConversationSettingsPage、ArchivedSessionsPage、ScheduleDetailPage、ScheduleHistoryPage、ScheduleEditorPage。`DevelopmentToolsPage` 已随 PR #13 删除，PR22 无此 struct；memory / probes / background / task-screen 因此仍不可达。

产品抽屉是 `HomeDrawer`（`HomeDrawer.swift:12`，不是 `*Page`）：新会话 / 定时任务、文件夹分组（默认「日常」）、长按重命名/归档、底部设置栏；它用手写契约 `pages/home-drawer.json` 进 gate，`extract_ios_pages.py` 的 `CHROME_CONTRACTS` 钉住文件与 struct。`HomeSpec.swift` 是 430×932 的页面/文字/间距/圆角值来源（#F7F7F7 page、#1A1A1A ink、16/24 body、16 chrome/20 content），不生成页面契约，由 `CHROME_VALUE_FILES` 钉住。`FilePreviewPage` 已删除（PR15），预览是独立面 `PreviewSurface`（`pages/preview-surface.json`）。

页面结构另有机器可读契约：`pages/<page-id>.json`（分区/行/动作/呈现，每项带 `file:line`）由 `tools/extract_ios_pages.py` 抽取，`tools/page_structure_check.py` 比对 Android；平台被迫差异只走 `_whitelist.json`（引用 `spec/platform/whitelist.json` 的 id），已知差异记 `_baseline.json` 只减不增；`states` 只作人读，Android 无对应页登记 `_android-only.json`，有 `public fun *Page()` 无契约即失败。
标题 MUST 是渲染形态：`dynamicTitle` 只给「固定模板+一个可变量」；数据即标题记 `title:null`+`titleSource:"expression"`+`titleExpression`+`criterion`；无字面判据的项登记 `_unrecognized.json`（owner+reviewBy+理由，stale 即失败）；死 UI 标 `deadUi`+证据；整页一坨记 `single-region`。
Android 侧 MUST 走 `SessionSectionLabel`/`SectionHeader(title=…)`/`*SectionView(_, title)` 与 `SessionTextAction`/`InfoRow(..., onClick=…)`；标题是表达式记 `unresolved`；标准控件（`Button`、`FilterChip`、`Switch`、`DropdownMenuItem`、`label:` 包装器）也算动作；判据是 gate 看不见正确实现时修 gate、实现藏信息时修实现。

### 1.1 已知基线观察（只记录，不改基线）

| 观察 | 证据 | P5 处置 |
|---|---|---|
| SessionActivityPage 的 sheet 已接线但无人置位 | `ChatPage.swift:85` 声明、`:547` 接线，全仓无 `showActivity = true` | 不实现；iOS 恢复入口再开 |
| DailyBriefPage 没有任何入口 | `DailyBriefPage.swift:8` 有页面，全仓无调用点 | 不实现；iOS 恢复入口再开 |
| NativeTab 四 Tab 枚举是死代码 | `NativeShell.swift:14` 定义、全仓无引用；实际外壳 = ChatPage + HomeDrawer | 按 §1 的抽屉外壳实现，不实现 Tab 栏 |
| SessionsPage 不再是产品抽屉 | 产品抽屉是 `HomeDrawer`（`NativeShell.swift:238`）；SessionsPage 只在 `-uiPreview sessions`（`:724`）和 DrawerPreview（`:826`） | 不把 SessionsPage 当 Android 首页；首页/抽屉分别按 ChatPage/HomeDrawer 实现 |
| 设置五分页外壳已移除 | `SettingsPage.swift:45` 起是分组 List；`NativeSettingsTab`（`:7`）只剩 `initialTab` 深链，仅 `-uiPreview settings.permissions.tab`（`NativeShell.swift:734`） | 按六个分组索引实现，不保留五 Tab 外壳 |
| HomeSpec 是 PR22 的首页值来源 | `HomeSpec.swift:26` 起 page/ink/surface，#F7F7F7/#1A1A1A、16/24 body、16 chrome/20 content；`ChatPage.swift:1106-1113` 的 accent/surface/hairline 全部委托 HomeSpec/主题，旧的本地 #2F5BFF 调色板已不存在 | 用 HomeSpec 值做 430×932 基准；不再按旧 402pt 主题取色 |
| DevelopmentToolsPage 已删除 | PR #13 删除该页；PR22 全仓无 `struct DevelopmentToolsPage` | memory/probes/background/task-screen 保持不可达，不恢复开发者页 |

| HomeSpec 的 dark 是回退值 | `HomeSpec.swift:5` 明说浅色是参考录像的实测值，dark 用既有 parity 调色板 | 按 HomeSpec 给出的 light/dark 对镜像，不另造色 |
| 用户气泡正文仍调用偏好字号 | `ChatPage.swift:3894` 用 `NativeChatTheme.bodyFont()`，注释却写 16/24；HomeSpec 的 body 是 16 | token 取 HomeSpec 16/24；Android 按 token，不复制旧偏好默认值 |

## 2. 组件语义清单

行为定义，不写像素。每条都能从事件序列判定真值。

| 组件 | 出现 | 折叠 / 展开 | 消失 |
|---|---|---|---|
| 工具行（tool run） | 首个 `tool_call` 起；连续工具行合并为一行 | 默认折叠，行内只留标题 + 首行摘要；`tool_result` 只改状态与摘要；点标题展开，展开后是白底 r18 列表卡 | 只随会话切换/回合清理消失 |
| thinking_pill | `colors.textSecondary` `colors.textTertiary` | `typography.process` |  |  |  | `geometry.processRowHeight` `geometry.processIcon` | `motion.disclosure` `motion.shimmer` |
| 审批卡 | `colors.sessionSelector` `colors.sessionAccent` `colors.sessionOnAccent` `colors.sessionPrimary` `colors.sessionSecondary` | `typography.pageTitle` `typography.process` | `radius.card` |  |  | `geometry.cardPadding` `geometry.cardOuterMarginH` `geometry.cardOuterMarginV` `geometry.primaryButtonHeight` `geometry.secondaryButtonHeight` `geometry.cardAreaMaxHeightRatio` |  |
| 问题卡 | `question_requested` | 单选/多选/自定义答案，全部必答才能提交；折叠与槽位规则同上 | 提交后消失；同时刻最多一张 |
| NativeChangedFilesCard | 回合末最后一条非流式 assistant 行 | 按 `turn` 聚合成功的 write/edit/str_replace_editor；同路径后者覆盖前者；>4 个只列 4 个 + 「全部 N 个文件」 | 回合结束仍保留；清除随会话切换 |
| composer | `colors.surface` `colors.primaryButton` `colors.primaryButtonInk` `colors.userBubble` `colors.inputPlaceholder` `colors.iconMuted` | `typography.body` | `radius.composerOpen` |  |  | `geometry.composerOpenMinHeight` `geometry.sendButton` `geometry.composerIcon` `geometry.chromeInset` `geometry.composerMaxHeight` `geometry.composerControlHeight` |  |
| fail-loud 横幅 | `colors.sessionWarning` `colors.sessionDanger` `colors.sessionAccent` `colors.sessionSecondary` | `typography.secondary` |  |  |  | `geometry.bannerGap` `geometry.bannerInsetH` `geometry.bannerInsetV` |  |

页头 `⋯` 里的「导出对话记录」是页内动作，parity 到 Android 的平台分享 affordance（形态差异见 §5 `share-sheet`）；
Android 不注册为外部分享目标、不做深链。

## 3. 交互状态机

Event 是 Harness 事件或用户动作；事件名一律用 host kind（`spec/host/v1/schema/harness-event.schema.json`）。
标 synthetic 的两族没有 host kind，是投影行，规则见 `spec/host/v1/event-kinds.md`。Transition 表即投影规则。

| Event | From | To | Side effect |
|---|---|---|---|
| 用户发送（idle） | idle | running | 清空草稿；插入 user 行；滚到尾部 |
| 用户发送（running，queue） | running | running | 插入 user 行；行下「已排队」；输入坞显示排队条 |
| 用户发送（running，steer） | running | running | 发 steer；行下「已并入当前任务」 |
| `turn_started` | running | running | 队列标签「已排队」→「发送中…」 |
| `turn_ended` ok | running | idle | 清全部排队/发送中标签；结束流式 |
| `turn_ended` error | running | failed | 顶部横幅；失败行；失败消息 id |
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

Parity is asserted on **two different object graphs**，混用两者就是端口漂移的开始。

| Layer | What it is | Where it is specified | How parity is asserted |
|---|---|---|---|
| **UiState** | 事件锚定的有序投影；节点 id 为 `session/<sid>/turn/<tid>/event/<seq>[/<slot>]` | `spec/v1/trajectory.md` §7、`ui-state-sequence.schema.json` | 同一事件流 → 两侧字节一致的 UiState 序列 |
| **ScreenState** | 屏幕自有的草稿、焦点、折叠、滚动锚点、瞬时横幅；没有事件锚点 | 本节 | 同一 UiState + 同一本地 UI 事件脚本 → 同一 ScreenState 序列 |

1. 不能给出合法 UiState id 的节点属于 ScreenState；`composer` 是标准例子。
2. 渲染便利（连续工具折叠）是渲染时折叠，UiState 仍每个事件一个节点。
3. ScreenState 是 (UiState, 本地 UI 事件) 的纯函数；设置/文件等无事件锚点的页面，其 UiState 输入是宿主只读快照。
4. 需要截图的 parity 断言是第三件事，只限 §4 的 6 个签名面，不能替代 1 或 3。

## 4. 签名面

只有这 6 个面做像素对表。页面层几何已吸收进 `tokens.json` 的 `geometry`（值 + 单位 + `scalesWith`），下表引用的
就是比对基值；表中每面写出的 token 与 `tokens.json` 的 `signatureSurfaces.<面>.tokens` **集合相等**，由 checker
双向强制（少写、多写都失败），表头也给每个 token family 留一列。

| 签名面 | 颜色 `colors.*` | 字号 `typography.*` | 圆角 `radius.*` | 描边 `stroke.*` | 间距 `spacing.*` | 几何 `geometry.*` | 动效 `motion.*` |
|---|---|---|---|---|---|---|---|
| 气泡 | `colors.userBubble` `colors.textPrimary` | `typography.body` | `radius.bubble` |  | `spacing.paragraphGap` | `geometry.contentInset` `geometry.bubblePaddingH` `geometry.bubblePaddingV` `geometry.bubbleMaxWidthRatio` |  |
| 工具行 | `colors.surface` `colors.textSecondary` `colors.textTertiary` `colors.borderList` | `typography.process` `typography.listItem` | `radius.listCard` | `stroke.hairline` | `spacing.disclosureGap` | `geometry.processRowHeight` `geometry.processIcon` `geometry.listRowHeight` | `motion.disclosure` |
| thinking_pill | `colors.textSecondary` `colors.textTertiary` | `typography.process` |  |  |  | `geometry.processRowHeight` `geometry.processIcon` | `motion.disclosure` `motion.shimmer` |
| 审批卡 | `colors.sessionSelector` `colors.sessionAccent` `colors.sessionOnAccent` `colors.sessionPrimary` `colors.sessionSecondary` | `typography.pageTitle` `typography.process` | `radius.card` |  |  | `geometry.cardPadding` `geometry.cardOuterMarginH` `geometry.cardOuterMarginV` `geometry.primaryButtonHeight` `geometry.secondaryButtonHeight` `geometry.cardAreaMaxHeightRatio` |  |
| composer | `colors.surface` `colors.primaryButton` `colors.primaryButtonInk` `colors.userBubble` `colors.inputPlaceholder` `colors.iconMuted` | `typography.body` | `radius.composerOpen` |  |  | `geometry.composerOpenMinHeight` `geometry.sendButton` `geometry.composerIcon` `geometry.chromeInset` `geometry.composerMaxHeight` `geometry.composerControlHeight` |  |
| fail-loud 横幅 | `colors.sessionWarning` `colors.sessionDanger` `colors.sessionAccent` `colors.sessionSecondary` | `typography.secondary` |  |  |  | `geometry.bannerGap` `geometry.bannerInsetH` `geometry.bannerInsetV` |  |

审批卡以实际 `PermissionCardView` 为准（selector、r12、17/15 字号），错误提示以实际 `ChatPage.errorBanner` / `failureLine` 为准；HomeSpec 示例卡不能覆盖仍在使用的组件。气泡段落间距和工具组卡外壳由 `ChatRows` 父级持有，并由检查显式核对。

**颜色（HomeSpec 430×932pt，light / dark）**

| token | light | dark | 用途 |
|---|---|---|---|
| `colors.page` | `#F7F7F7` | `#101012` | 页面底 |
| `colors.surface` | `#FFFFFF` | `#1C1C1E` | 导航钮、输入卡、列表卡 |
| `colors.userBubble` | `#E8E8E8` | `#2C2C2E` | 用户气泡 |
| `colors.primaryButton` | `#191919` | `#F2F2F2` | 主按钮底 |
| `colors.primaryButtonInk` | `#FFFFFF` | `#111111` | 主按钮墨色 |
| `colors.textPrimary` | `#1A1A1A` | `#F2F2F2` | 主文字 |
| `colors.textSecondary` | `#555555` | `#B8B8BD` | 过程行/次要文字 |
| `colors.textTertiary` | `#717171` | `#9C9CA2` | 列表卡步骤行 |
| `colors.textSubtle` | `#7D7D7D` | `#8E8E93` | 导航副标题 |
| `colors.textPlaceholder` | `#888888` | `#7C7C82` | 时间戳/占位值 |
| `colors.inputPlaceholder` | `#8B8B8B` | `#7C7C82` | 输入占位 |
| `colors.iconMuted` | `#A9A9A9` | `#6C6C70` | 禁用图标 |
| `colors.success` | `#3DC979` | `#3DC979` | 状态点/完成对勾 |
| `colors.borderList` | `#E2E2E2` | `#2E2E32` | 列表卡 1pt 描边 |

**字号 / 行高（HomeSpec，默认 weight 400）**

| token | size / line | weight | role | 来源 |
|---|---|---|---|---|
| `typography.navTitle` | 17.5 / 22 | 600 | title | `HomeSpec.swift:43` |
| `typography.navSubtitle` | 14.5 / 20 | 400 | body | `HomeSpec.swift:45` |
| `typography.body` | 16 / 24 | 400 | body | `HomeSpec.swift:47` |
| `typography.process` | 15 / 24 | 400 | body | `HomeSpec.swift:49` |
| `typography.listItem` | 14 / 22 | 400 | body | `HomeSpec.swift:50` |
| `typography.tabLabel` | 10.5 / null | 400 | label | `HomeSpec.swift:52`（行高未测，不编造） |

字体映射：两端都不打包字体；iOS 系统 SF Pro/PingFang SC，Android 系统无衬线（Roboto 或厂商替代）；等宽回退见
§5 `cjk-fallback`。17.5/14.5 这类型值是规范原值，不做取整。`tabLabel` 的 lineHeight 为 null：HomeSpec 只给字号，
PR22 home 也没有 Tab 栏，按未测处理。

**几何（HomeSpec grid；`spacing.*` 单独列出）**

| 组 | 值 | 来源 |
|---|---|---|
| 导航 | `chromeInset`=16 `contentInset`=20 `navTop`=8 `navButton`=44 `navPillWidth`=92 `navIcon`=22 | `HomeSpec.swift:16`、`:18`、`:20`、`:65`–`:67` |
| 过程/列表 | `processRowHeight`=24 `processIcon`=18 `listRowHeight`=22 `tabBarHeight`=50 `tabIcon`=28 | `HomeSpec.swift:68`–`:70`、`:22`、`:74` |
| 输入 | `composerOpenMinHeight`=104 `sendButton`=36 `composerIcon`=24 | `HomeSpec.swift:71`–`:73` |
| 间距 | `blockGap`=20 `paragraphGap`=16 `disclosureGap`=8 | `HomeSpec.swift:57`–`:61` |
| 圆角 | `radius.bubble`=24 `radius.listCard`=18 `radius.composerOpen`=24 | `HomeSpec.swift:78`–`:80` |
| 页面层 | `bubblePaddingH`=16 `bubblePaddingV`=12 `bubbleMaxWidthRatio`=0.8 | `ChatPage.swift:3902`–`:3906` |
| 页面层 | `cardPadding`=14 `cardOuterMarginH`=16 `cardOuterMarginV`=8 `primaryButtonHeight`=48 `secondaryButtonHeight`=44 `cardAreaMaxHeightRatio`=0.4 | `ChatPage.swift:4590`–`:4594`、`:927` |
| 页面层 | `composerMaxHeight`=336 `composerControlHeight`=44 | `ChatPage.swift:1981`、`:2007` |
| 页面层 | `bannerGap`=12 `bannerInsetH`=4 `bannerInsetV`=6 | `ChatPage.swift:1023`、`:1045`–`:1046` |

`geometry` 的 `scalesWith` 全部为 null：HomeSpec 使用固定 `frame` / padding，没有 `@ScaledMetric`；字号本身仍按
`baseSize × 平台缩放系数`。页面级 token 不用 `signatureSurfaces` 的 surface 概念，只在 `geometry` 与 provenance
（`tier: page`）里记录。

**描边 / 动效（仍被 PR22 使用，不属于 HomeSpec 的六个主 type role）**

| token | 值 | 出处 | 用途 |
|---|---|---|---|
| `stroke.hairline` | 0.5pt | `Components.swift:223` | 代码卡/工具卡 0.5pt 描边 |
| `motion.disclosure` | 160ms easeOut once | `NativeMessageRows.swift:28` | 过程/思考行展开折叠 |
| `motion.shimmer` | 1500ms linear forever | `DSHComponents.swift:56` | thinking 行运行中摘要扫光 |
| `motion.composerSend` | 120ms easeOut once | `ChatPage.swift:2076` | 发送键可用态切换 |
| `motion.copyConfirmHold` | 1000ms linear once | `Components.swift:181` | 「已复制」保持时长 |

### Baseline accessibility debt（已登记基线无障碍债）

按镜像决定保留 PR22 原值，**不改 token 值**。checker 逐条打印实测比值，`--strict` 下全部失败；deferred 上限 7,
当前 6 条。这些是 **HomeSpec 源值本身达不到 AA** 的 limitation，不是新调色或豁免：不在本 lane 里发明更深颜色，
也不加新的 deferred 类别。

| 配对 | 类 | 实测（light / dark） | owner | reviewBy | 为什么低于 AA |
|---|---|---|---|---|---|
| `textSubtle/page` | 文本 | **3.84** / 5.83 | iOS UI owner | 2027-03-31 | 导航副标题 14.5pt，PR22 原值 |
| `textPlaceholder/surface` | 文本 | **3.54** / **4.10** | iOS UI owner | 2027-03-31 | 时间戳/占位值，两种外观都低于 4.5 |
| `inputPlaceholder/surface` | 文本 | **3.41** / **4.10** | iOS UI owner | 2027-03-31 | composer 占位文字，PR22 原值 |
| `iconMuted/userBubble` | 非文本 | **1.92** / **2.67** | iOS UI owner | 2027-03-31 | 禁用发送图标，未达 3.0 |
| `success/surface` | 非文本 | **2.14** / 7.96 | iOS UI owner | 2027-03-31 | 成功绿在浅色白面上只有 2.14:1 |
| `borderList/surface` | 非文本 | **1.30** / **1.26** | iOS UI owner | 2027-03-31 | 1pt 描边不是唯一边界，卡片底色与 r18 仍可辨 |

P5 工作项：由 `tokens.json` 生成 Swift/Compose token 文件（P0 不做，消费者在 P5 才存在）；生成物必须与源一同校验。

## 5. 平台差异白名单

只有下表 8 条 + 一个 **`copy-forced` 类**允许两端呈现不同（方案 §9.2-5 的 7 条 + owner 追加的 `share-sheet`）；
每条都要「语义等价声明」，未列入按语义一致验收（像素对表仍限 §4 的 6 个面）。

| id | Android | iOS | 语义等价声明 |
|---|---|---|---|
| back-gesture | 系统预测性返回：页面栈逐级出栈，根页面退出应用 | 左上返回按钮 + 边缘右滑 | 返回后所处页面与栈深度相同；Android MAY 用预测性动画，state 变更序列 MUST 一致 |
| font-scale | `fontScale` × 基准字号（sp） | Dynamic Type × 基准字号 | 只读系统缩放系数；缩放曲线由平台决定，可能是非线性；不裁剪、不横滚。判据见 §5.1 容差 |
| ime | IME 候选栏与 insets 动画由系统驱动 | 键盘安全区推挤 composer | composer 始终可见于 IME 之上；发送后列表位置与内容一致 |
| insets | targetSdk 35 强制 edge-to-edge，显式消费系统栏 insets | safe area | 内容不被系统栏遮挡；页头与 composer 的可点区域等价 |
| scroll-refresh | 下拉刷新在列表顶部，带平台惯性 | 下拉刷新 + 尾部跟随 | 刷新后停留位置等价；「跟随尾部」在两端都是同一条件触发 |
| fgs-notification | 前台服务常驻通知：回合状态 + 进度 + 「停止」按钮 | 后台保活静默期，无通知 | 通知是回合执行中的唯一界面；「停止」走同一 cancel 路径 |
| cjk-fallback | 系统 CJK 回退链，等宽字形按字体族回退 | 系统 CJK 回退链 | 同一字符串两端字形可不同，但行数、换行点、复制结果 MUST 一致 |
| share-sheet | 页内动作「导出对话记录」调系统 share sheet | 系统 activity sheet | 同一动作、同一内容，面板形态由平台提供；不注册外部分享目标、不做深链 |

系统语义字号的 type-role 映射（只这两档走平台字号；17.5/14.5 固定值仍按 sp 输出）：

| token | iOS | Android | 容差 |
|---|---|---|---|
| `navTitle`（17.5/600） | `.headline` 附近 | Material `titleMedium` | 平台角色无 17.5 档，允许 ±2pt，不做像素级 |
| `navSubtitle`（14.5/400） | `.subheadline` 附近 | Material `titleSmall` | 同上 |

```json
{"platformDivergences": [
  {"id": "back-gesture", "android": "预测性返回逐级出栈，根页退出", "ios": "返回按钮与边缘右滑", "equivalence": "返回后页面与栈深度相同，state 序列一致", "tokens": ["motion.disclosure"]},
  {"id": "font-scale", "android": "fontScale 乘基准字号", "ios": "Dynamic Type 乘基准字号", "equivalence": "只读系统缩放系数；曲线可为非线性，按 §5.1 的 ±2sp 容差判定", "tokens": ["typography.body", "typography.navSubtitle"], "mapping": {"typography.navTitle": "Material titleMedium", "typography.navSubtitle": "Material titleSmall"}},
  {"id": "ime", "android": "IME 候选栏与 insets 动画由系统驱动", "ios": "键盘安全区推挤输入坞", "equivalence": "输入坞始终在 IME 之上，发送后列表位置一致", "tokens": ["geometry.composerOpenMinHeight"]},
  {"id": "insets", "android": "targetSdk 35 强制 edge-to-edge 并消费 insets", "ios": "safe area 自动内缩", "equivalence": "内容不被系统栏遮挡，可点区域等价", "tokens": ["geometry.chromeInset"]},
  {"id": "scroll-refresh", "android": "列表顶部下拉刷新，平台惯性", "ios": "下拉刷新加尾部跟随", "equivalence": "刷新后停留位置等价，跟随尾部条件相同", "tokens": ["motion.disclosure"]},
  {"id": "fgs-notification", "android": "前台服务通知含回合状态、进度与停止按钮", "ios": "后台保活静默期无通知", "equivalence": "通知是回合执行中的唯一界面，停止走同一 cancel 路径", "tokens": ["motion.disclosure"]},
  {"id": "cjk-fallback", "android": "系统 CJK 回退链，等宽族回退", "ios": "系统 CJK 回退链", "equivalence": "字形可不同，行数与换行点及复制结果一致", "tokens": ["typography.body", "typography.listItem"]},
  {"id": "share-sheet", "android": "系统 share sheet", "ios": "系统 activity sheet", "equivalence": "同一页内动作与同一内容；不注册外部分享目标，不做深链", "tokens": []}
]}
```

### §5.1 第 9 类：`copy-forced`（措辞强制）

前 8 条是「同一件事，两端呈现方式不同」。`copy-forced` 是另一种：两端描述同一件事，但照抄另一端的说法就会在屏幕上
陈述一个假事实。它没有可命名的 Android 机制可填（`os-forced` 要求 `android_mechanism`），所以单列一类，登记在
`spec/platform/whitelist.json` 的 `platform.phone-worker-copy`。机器可验判据：该 platform 条目必须带非空
`android_mechanism`，值只能取自 `platform-terms.json` 的 `iPhone` / `iPad` / `iOS` / `App Store` / `TestFlight` /
`iCloud`；每条 `_whitelist.json` 行两侧 label 删除这些名词后必须逐字节相等；不满足的条目在门禁里是
`copy-forced-not-forced`。

### 5.1 Font scaling is not linear (measured), and parity needs a tolerance

Android 14 and later apply a **non-linear** font-scale converter. Measured during the port: `14sp` at
`fontScale = 2` renders **26px, not 28px**. A rule that says "rendered size = baseSize × factor" is therefore wrong
on the platform it describes, and a test built on it fails a correct implementation.

- A type token carries a **base size in `sp`** (iOS: points). It never carries a pixel value.
- The rendered size comes from the platform's own scaling, linear or not.
- **Parity tolerance** for a signature surface's typography: same base size, and rendered sizes within **±2sp** at the
  same user font scale. Dynamic Type and Android font scale are different curves; exact equality is not promised.
- A layout assertion that depends on text height must use the measured height, never a computed one.

**Tool-row shimmer belongs to `thinking_pill` only.** The running summary sweep is the thinking pill's signature effect;
`toolRow` shows static state text, so `motion.disclosure` is the only motion token in the tool-row composition.
