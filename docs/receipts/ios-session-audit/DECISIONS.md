# 平台决策记录（DECISIONS）

> 基线 `deepseek-harness 7be5505b0b`（0.2.1-rc.2），手机视口 402pt（CSS px = pt）。
> 本文件裁决「官方有、iOS 平台没有等价物或产品明确不做」的五处缺口。**三条都是平台适配（adaptation），不是 parity 实现**：不用「看起来像」代替「做不到」，不新增位置像官方而语义不同的控件。
> 每条格式：Context / Official / iOS constraint / Options / Decision / Consequences / Revisit trigger。
> 官方路径相对 `deepseek-harness` 仓根，iOS 路径相对本仓根。`ChatPage.swift` 行号取自 11:03 快照（工作流 B 正在改该文件），引用请以符号名为准。
> 关联：[08-composer.md](08-composer.md) S3–S5 / C-06、[09-scanner-gaps.md](09-scanner-gaps.md) §3、[00-MASTER.md](00-MASTER.md) §6/§11。

## 0. 结论速览

| # | 官方位置 | iOS 现状 | 决策 | 定性 |
|---|---|---|---|---|
| D-01 | `header.utilities` order −10 `open-in-app` | 无入口；无宿主应用目录 | **A 不做，记 N/A** | 官方显示谓词在 iOS 恒为空 |
| D-02 | `header.corner` `sidebar-right` | 无右侧栏；`NativeWorkbenchPage` sheet 仅从路径链接进 | **B corner + `.large` sheet**（先腾页头预算） | 官方 402pt 本来也是全屏抽屉 |
| D-03 | 设置 → 通用 `collapseTiming` | 固定 completion-time | **A 页头 more（…）菜单 + `NativeChatPreferences`（AppStorage 持久化），默认 completion** | 本地偏好，不同步 host/Web |
| D-04 | `conversation.view` 对话/轨迹 tab | 曾实现 76pt 双 tab | **移除 tab，页头 50pt；轨迹入口不做** | 产品裁剪，非 parity |

## D-01 `open-in-app`（页头 utilities order −10）

**Context** 官方会话页头有「在本地打开」按钮（按应用为「用 {app} 打开」；`ui-open-in-app/src/client/locales.ts:42,47`），iOS 没有（08 S4/C-06；09 §3 记 P2 新缺口）。要定：做不做、做什么。

**Official**
- 注册 `conversation.session.header.utilities`，`id:'open-in-app'`，`order:-10`（`packages/client/ui-open-in-app/src/client/index.ts:102-105`）。
- 显示谓词：会话有 `cwd` **且** host 解析出可用应用；任一为空即返回 `null`，页头不出现按钮（同文件 `:95-101`；`OpenInAppAction.tsx:43-44`）。
- 应用目录与启动都在 **host 侧**：`GET OPEN_IN_APP_APPS_ROUTE` 取已装 app id，`POST OPEN_IN_APP_OPEN_ROUTE` 让 host 打开 `{app, path}`（`controller.ts:77-93, 95-110`）。
- host 目录只为 `darwin | win32 | linux` 声明条目，其它平台解析为空（`packages/host/open-in-app/src/catalog.ts:9-10`）；落地形态是 argv 子进程或 OS 的 open 动词（同文件 `:19-37`）。

**iOS constraint**
- 无宿主桌面应用目录：Host 是 App 内嵌 JSCore Worker（`plugins/worker-entry/src/jsc-compat.ts:96`），没有宿主进程/子进程能力（`capabilities.ts:442`「no host process」）→ 官方目录规则在此解析为空，`OpenInAppAction` 返回 `null`，argv / OS-open 通道也不存在。
- 会话 `cwd` 是 host VFS 路径（`ManagedSession.cwd`，`DSHManagementModel.swift:17`），设备上落在 App 沙箱 `Documents/chat-host/materialized/workspace/`（`WebHostModel.swift:137-153`）；别的 App 无法「打开这个目录」，且 `Config/PhoneDSHProbe-Info.plist` 无 `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`（82 行全文 0 命中），「文件」App 也不可见。
- 现成等价物只有**按文件**的：ShareLink（页头已用于导出会话记录，`ChatPage.swift·chatHeaderTitleRow` 内两处，约 274/294 行）、QuickLook 预览（`FilesPage.swift`）。二者都是「拷一份 / 在本 App 里看」，不是「在原处由宿主打开」。
- 页头右簇已近满：agentPreset 胶囊 + 子 Agent（≤150）+ 后台任务 28 + 定时任务 28 + 导出 28 + 状态点 + `...` 44（`ChatPage.swift·chatHeaderTitleRow`，约 204–313 行）；再加 28pt 会在「全都有」时压标题。

**Options**

| | 做法 | 保留什么 | 丢什么 / 风险 |
|---|---|---|---|
| A | 不做，记录 | 官方谓词的结果（不显示） | 无（本来就解析为空） |
| B | ShareLink 分享 cwd / 工作区 | 一个「发出去」的动作 | 语义变拷贝；整目录外发的体积与隐私风险 |
| C | Files/QuickLook 预览 cwd | 按文件的预览 | 要先选文件，已偏离 cwd 语义；与既有 FilesPage 重复 |

**Decision** A。
1. 按官方谓词，iOS 的正确取值就是「不显示」——这是**规则一致**（predicate parity），不是遮羞布。
2. B/C 把「打开（原处、宿主执行）」换成「导出副本（拷到别处）」，是另一个用户承诺。
3. 页头无预算；该能力也不解决当前任何阻塞（会话记录已可分享）。

**Consequences**
- 页头不变；验收矩阵里 `open-in-app` 记 **N/A + 本文件依据**，不再算待补缺口。
- 未来若做「导出/交付工作区」，是**新功能**（新文案、新入口、新风险：体积/覆盖/隐私），不得挂 parity 名。
- 不产生假按钮、无死状态。

**Revisit trigger** iOS 出现文件夹级「文件」App 可见性（File Provider，或打开上述两个 plist 键）且产品确认工作区应暴露；或出现「把单个产物交给别的 App」的真实需求（届时做文件级，走 FilesPage/QuickLook，不占页头）；或 iPad/macCatalyst 上 host 与屏幕重新分离，官方谓词可能真为真。

## D-02 `sidebar-right`（页头 corner）

**Context** 官方 corner 槽是右侧栏的入口；iOS 无右侧栏、无 corner 槽（08 S5/C-06；09 §3 记 P2 设计决策）。

**Official**
- corner 注册 `conversation.session.header.corner`（`packages/client/ui-sidebar-right/src/client/index.ts:238-243`），组件 `ExpandButton`：`IconPanelLeftOutlineRegular` 镜像、`sm` 按钮、aria「打开右侧边栏」、快捷键 `sidebar.right.toggle`，**只在面板收起时渲染**（`shell/ExpandButton.tsx:1-53`；`locales.ts:24-25`）。
- 面板是按 session 的停靠区：多 tab、分屏、浮动、拖拽停靠、布局持久化（`labels.ts:29-46`、`persistence.ts`、`tab-inventory.ts`）；tab 类型不止文件——文件、文档预览、终端、浏览器、交付物、定时任务、子 Agent / 计划视图都注册进 `sidebarRightTabs`（`ui-sidebar-{files,documentpreview,terminal,browser}`、`ui-deliverables`、`ui-schedule`、`ui-subagent`、`ui-plan`）。
- **402pt 官方就是全屏抽屉**，不是并排：`autoFullscreen = viewportWidth < 768`、`track = shown && !autoFullscreen`（`shell/SidebarRight.tsx:360, 367`）；手机层再把 rightbar 变 `position:fixed`、右缘滑入 240ms、`width: min(100vw, 480px)`、`elevation-prominent`（`ui-mobile/src/client/mobile.module.css:94-110`，断点 `<640px`）。

**iOS constraint**
- 没有并排位，也不该有：官方在 402pt 自己就不并排（上面两条阈值 640 / 768 都命中）；iOS 侧未使用 `NavigationSplitView` / `HSplitView` / `horizontalSizeClass`（全库 0 命中），会话页单列，抽屉在左（`NativeShell.swift`）。
- 已有等价内容：`NativeWorkbenchPage` 注释即「Compact presentation of DSH's right sidebar」，文件 / 命令两段，sheet `.large`（`NativeWorkbenchPage.swift:4-6, 37`）；但入口只有转录里的路径链接（`ChatPage.swift` 的 `showWorkbench` 赋值处，约 583/646/2376 行，随 B 编辑位移）。
- 页头最右现在是 `...` 44×44（`ChatPage.swift·chatHeaderTitleRow`），corner 位被占，右簇同样无预算（见 D-01）。

**Options**

| | 做法 | 保留什么 | 丢什么 |
|---|---|---|---|
| A | 不做 | 现状 | 页头没有回面板的入口：官方可发现性缺失 |
| B | corner → `.large` sheet（复用 `NativeWorkbenchPage`） | 官方 402pt 的覆盖式表现、常驻入口、会话作用域、文件/命令两段 | 多 tab、分屏、浮动、拖拽、布局持久化、官方 tab 全集 |
| C | split view 真并排 | 宽视口官方行为（保留 track） | 402pt 不可行；须先有 iPad 目标与 size class 分支 |

**Decision** B，附两个前置条件：
1. **入口预算先还**：corner 键必须在最右（官方在 utilities 之后），因此先把 `...` 左移，并把可收纳项（agentPreset 只读标签、后台任务、定时任务）并入一个 actions 菜单，否则「全都有」时标题被压。
2. **语义与文案**：仅本会话有工作区/cwd 时出现；文案 / a11y 用官方的「打开侧边栏 / 打开右侧边栏」（`locales.ts:24-25`），图标 `sidebar.right` 是左抽屉 `sidebar.left` 的镜像；内容复用 `NativeWorkbenchPage`，不新造面板。

选 B 而非 C：官方 402pt 本来全屏，`.large` sheet 是**同宽度下的同一表现**；C 留给 iPad。

**已实现（2026-11-01）**：`sidebar.right` 作为 more（…）菜单项打开现有 `NativeWorkbenchPage` `.large` sheet；为满足“右上只留一个 icon”，子 Agent/后台任务/定时任务/产物/导出/运行状态/agentPreset/右侧边栏全部收进 more（…）菜单。

**Consequences**
- 保留：corner 入口、覆盖式面板、会话作用域、文件/命令两段。
- 不保留：并排阅读、多 tab、分屏、浮动、拖拽停靠、按 session 布局持久化、官方 tab 全集、「链接默认开在右侧栏」（官方 `linkOpening:'sidebar'`）。
- 过渡不同：sheet 自下而上，官方自右缘滑入 240ms；本轮不自造右滑动画，验收只比几何与内容，不比动效。
- 术语与验收：402pt 下官方本身就是全屏，UI 可以叫「右侧边栏」；但文档必须同时写明「sheet 呈现、无停靠 / 并排 / 多 tab」，不得把 sheet 说成与官方停靠面板一致。

**Revisit trigger** iPad / regular width 进入目标（改 `NavigationSplitView` trailing column，sheet 退为窄宽回退）；或真实需求是「边读转录边看文件」；或官方某 tab 类型变成必须常驻（交付物 / 审批）。

## D-03 `On next message` 折叠时机

**Context** 官方是 host 持久化设置；iOS 原先固定 completion-time；现在页头 more 菜单与「设置 → 聊天外观」两处都可改，值存 `NativeChatPreferences`。要定：放哪、存哪、默认什么、算不算 parity。

**Official**
- 字段 `collapseTiming ∈ {completion, next-input}`，默认 `completion`，存 host 用户设置文档 `ui-chat`（`packages/client/ui-chat/src/chat-settings.ts:12-21, 74-80`）。
- 入口是**设置 → 通用**的 `settings.general.item` 一行 `PreferenceRow`，不在会话页头（`ui-chat/src/client/settings/TranscriptViewRow.tsx:62-69`）。
- 文案：「工作步骤收起时机」「选择何时自动收起工作步骤」「回答结束后」「下次有新消息时」（`ui-chat/src/client/locale.ts:105-108`）。
- 语义：`next-input` 时刚完成的一轮保持运行态外观，直到下一条输入（`presentation-policy.ts:54-59`、`ChatView.tsx:70`）。

**iOS constraint**
- 没有「设置 → 通用」这一层放会话偏好：`SettingsPage` 是 App 设置，`NativeConfigurationPage` 是 host 插件/模型设置且只白名单 4 个 namespace（`NativeConfigurationModel.swift:458-463`），`ui-chat` 不在其中；`settings/update`（`:318`）虽能写 host，但通用渲染只认 boolean/number/string，枚举会退化成文本字段。
- 页头 `...` 菜单已在（导出、本会话设置），加一项边际成本最低，且无需新页面。
- 需要本地持久化 → `NativeChatPreferences`（UserDefaults），页头菜单与设置页共享。

**Options**

| | 做法 | 保留什么 | 丢什么 |
|---|---|---|---|
| A | 页头 more 二选一 + `NativeChatPreferences`（UserDefaults） | 官方两个语义、四条文案、默认值 | 与 host / Web 不同步 |
| B | 写 host `ui-chat.collapseTiming`（`settings/update`） | 跨端一致 | 要给 `ui-chat` 加白名单与枚举控件；那是「高级设置」不是通用设置；本轮成本最高 |
| C | 不做 | 零成本 | `next-input` 用户永远没有 |

**Decision** A，并规定：
- 默认 `completion` = 「回答结束后」= 官方默认；菜单项显示当前值。
- `true` 时，只有本轮之后出现新的 user / steering / trigger 输入，才自动收起该轮；最新 exchange 保持展开；手动展开不被后续自动收起覆盖（沿用当前「手动展开记账」的做法，符号名以 B 合入后为准）。
- 文案逐字用官方四条，不自造第二套名词（不写「排入下一轮」式改写）。
- 定性：**适配，不是 parity**——官方入口在设置页、值在 host；iOS 是页头菜单 + 聊天外观页 + 本地值。

**Consequences**
- 不设置时与官方同值，默认表现一致；显式选 `next-input` 后只在 iOS 生效。
- 不同步 Web、不跨设备、重装丢；同一 host 上 Web 与 iOS 可同时存在两个值。
- 将来若读 host 值，须先定迁移规则（本地优先还是 host 播种），不能两头都写。

**Revisit trigger** 出现「Web 与 iOS 偏好不一致」的实际投诉；或 `ui-chat` 进入 iOS 设置页白名单（届时开关迁过去、本地值一次性播种、保留一个版本双读）。

## D-04 `conversation.view` 对话 / 轨迹 tab（产品决策）

**Context** 官方会话页头在 402pt 也渲染「对话 / 轨迹」tab；iOS 曾按官方实现 76pt 双 tab（Wave 1），但产品方 2026-11-01 明确「移动端不需要看到轨迹」。

**Decision** 移除 tab 行，页头回到 50pt；轨迹数据/`NativeTrajectoryRow` 仍保留但无入口。
**定性** 有意的产品裁剪，不是 parity 实现；官方 402pt 仍有该 tab。
**Consequences** 移动端更简洁；`conversation.view` 的 P1 审计项按“产品不做”关闭，不再算待补缺口；若以后恢复，需重新评估页头 76pt 与轨迹状态。

---

## D-05 Settings 页面（产品决策）

**Decision** 设置页以 iOS 原生版式为准，分 4 个 tab（通用/工具/手机权限/关于），不逐像素复刻官方 Web 的 Settings 页面；但官方 DSH 的设置能力（权限模式、手机权限中心）要补齐。
**Consequences** 设置页不做官方 Web 的 DOM/排版 parity；手机权限中心独立成页，走系统 API 与 Info.plist usage strings。

---

## 4. 五条共同的边界

- 都不是 parity；验收矩阵标「适配」，不计入逐像素 / 逐行为一致。
- 不新增「位置像官方、语义不同」的控件（D-01 的 B/C、假的右侧栏一律不做）。
- 页头容量是共同约束：任何新页头键先还预算（收进菜单），否则 402pt 下标题被挤。

## 5. 需人拍板

1. **D-02 入口预算**：是否同意把 agentPreset 标签 / 后台任务 / 定时任务收进一个 actions 菜单，把 corner 腾出来？（会改变页头信息密度）
2. **iPad / regular width 是否本阶段目标**：不进入 → D-02 只做 sheet；进入 → 先定 split 分支，sheet 退为窄宽回退。
3. **D-03 是否需要与 Web 一致**：需要 → 改走 host `ui-chat`（选项 B），B3 的实现与验收都改。
4. **D-01 是否把「导出工作区副本」列为新功能**（非 parity）？
