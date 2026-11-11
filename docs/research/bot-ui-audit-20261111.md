# Bot UI 二级页面信息杂乱审计（2026-11-11）

- 审计单元：`ui-audit`
- 分支：`ui/bot-ui-audit`
- 基线（merge-base）：`d988108c1ec0c56903d6087c282cc9278bbdfd19`
- 审计时 HEAD：`1f1c1ea6b287ef0b190108419d331d97dd0b562b`
- 证据：`worktree/.audit-shots/` 下 40 张浅色截图（1206×2622，未改动、未重跑），加上 `examples/probe-app/PhoneDSHProbe/Bot/` 的 SwiftUI 代码与 `spec/ui/v1/pages/bot-*.md`。
- 本单元只读：**没有改任何源码、契约或测试**，唯一新增文件是本报告。

## 0. 结论摘要

1. 共记录 **36 条 UI 问题**：**P1 18 条 / P2 18 条**。按页见 §2。
2. 最明显的杂乱不是单个错字，而是四类系统性问题的叠加：
   - **生产适配层把内部枚举/ID 原样交给 UI**：`held`/`interrupt`、`bot-fixture-1`、`routine:run-2`、`routine.deliver · routine-2:3 · unknown-outcome`、`until`/`session`、`approval-card`、`write.file`、完整路径/URL、`record://`、`v3→v4`、`chat · user-turn`。
   - **SwiftUI 系统默认格式没有中文化**：`Oct 9, 2025 at 10:12 PM`、`11:00 PM`。这是截图里最刺眼的一类。
   - **长文本字段沿用 `LabeledContent`**：短值右对齐、长值换行后左对齐，同一页同一个字段出现两套排版；同时按钮散落在正文里，没有操作区。
   - **页面用大段开发者说明代替用户文案**：外观/在场/打扰 footer、记忆后台整理说明、`只显示最近一次批次…`、`Task 和 routine 只能提交到 agent/inbox/<会话>/`。
3. **截图并不完全等于生产**。`BotFixtures.swift` 直接构造了原始 `delivery`、`creator`、`effectSummary`、`automation.context`，绕过了生产适配器；`infoPresence` 的 footer 也与生产代码不同。这一点很重要：如果只按截图修，可能修的是夹具，线上仍是另一套文案。详见 §5。
4. 截图覆盖有明显空白：**审批记录页、记忆文档详情页没有截图**；`infoEmpty`/`infoError` 只截到页面顶部，看不到空态/失败态；`infoError.png` 与 `info.png` 的 sha256 相同。这些不计入 36 条 UI 问题，单列在 §6。

## 1. 方法与边界

- 逐张打开了 40 张浅色截图（含 `appearanceGrid`、`gallery`、`dynamic-1..3` 这类 capture-only 页），先记录屏幕上实际呈现的文字、对齐、截断、留白、颜色和按钮层级，再回代码定位。
- 代码范围：
  - `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift`（1519 行，信息页/记忆/例行任务/常设授权/审批记录/在场/打扰）
  - `BotWorkCardView.swift`、`BotCardView.swift`、`BotCardKit.swift`（聊天里的卡片）
  - `BotDrawer.swift`（Bot 列表、管理 Bot、添加 Bot）
  - `BotAppearancePicker.swift`、`Sources/PhoneDSHBot/Profile/BotFishAppearance.swift`（外观）
  - `BotProductionUIAdapters.swift`、`BotProductionServices.swift`（生产数据如何变成 UI 模型）
  - `Sources/PhoneDSHBot/Routines/RoutineSchedulerTypes.swift`、`Sources/PhoneDSHBot/Authz/*`（卡片文案的另一处来源）
  - `BotFixtures.swift`、`BotFishGallery.swift`、`scripts/ci/bot-ui/capture.sh`（截图夹具与 capture-only 页）
- 契约范围：
  - `spec/ui/v1/pages/bot-info.md`（P09/P25/P26）
  - `spec/ui/v1/pages/bot-chat.md`（P09/P27）
  - `spec/ui/v1/pages/bot-drawer.md`
  - `spec/bot/v1/README.md` §2 的 routine/grant/approval 语义
- 没有重跑截图、没有构建、没有跑测试；没有真机、深色、动态字体或 VoiceOver 证据。

## 2. 页面清单与截图覆盖

| 页面 / 区块 | 截图 | 审计情况 |
| --- | --- | --- |
| Bot 信息页（名称/外观/在场/打扰/数据入口/删除） | `info.png`、`infoLong.png`、`infoEmpty.png`、`infoError.png`、`infoAppearance.png`、`infoPresence.png` | 顶部与在场区可见；长页 footer 需滚动，代码确认 |
| 记忆页 | `infoMemory.png` | 只截到页面上半部；文档详情未截图 |
| 例行任务页 | `infoRoutines.png`、`infoReconcile.png` | 运行中与待对账两态可见 |
| 常设授权页 | `infoGrants.png` | 完整 |
| 审批记录页 | **无** | 只有代码；`approval.png` 是聊天审批卡，不是审批记录 |
| 管理 Bot | `drawerManage.png` | 完整 |
| 添加 Bot | `drawerAdd.png` | 完整 |
| Bot 抽屉 | `drawer.png`、`reactionLive.png` | 完整（附加观察，不计入 36 条） |
| 任务卡 | `task.png` | 完整，未发现明显问题 |
| 例行任务卡 | `automation.png` | 完整 |
| 审批卡 | `approval.png` | 完整，未发现明显问题（生产文案另有 §3.9 GEN-03） |
| 进度卡 | `progress.png`、`overflow.png` | `overflow` 暴露长文本问题 |
| 检查清单卡 | `checklist.png` | 完整 |
| 链接卡 | `link.png` | 完整 |
| 文档/附件/提问/步骤/通知 | `document.png`、`attachment.png`、`question.png`、`steps.png`、`error.png`、`denial.png` | 完整 |
| 截图专用页 | `appearanceGrid.png`、`gallery.png`、`dynamic-1..3.png` | capture-only，不算产品 UI |

按页统计（不计 §6 证据缺口）：

| 页面 | P1 | P2 | 小计 |
| --- | ---: | ---: | ---: |
| Bot 信息页 | 4 | 4 | 8 |
| 记忆页 | 4 | 4 | 8 |
| 例行任务页 | 5 | 0 | 5 |
| 常设授权页 | 1 | 2 | 3 |
| 审批记录页 | 1 | 1 | 2 |
| 管理 Bot | 0 | 1 | 1 |
| 卡片（含任务/例行/进度/清单/链接） | 2 | 3 | 5 |
| 截图专用页 | 0 | 1 | 1 |
| 跨页/通用 | 1 | 2 | 3 |
| **合计** | **18** | **18** | **36** |

## 3. 问题清单

> 说明：
> - `P1` = 明显杂乱/影响理解/暴露内部信息；`P2` = 可优化、截图专用、或需要先补证据。
> - “截图”里的 `无` 表示没有对应截图，只有代码证据。
> - 契约行号以本报告写作时的 `spec/ui/v1/pages/*.md` 为准。

### 3.1 Bot 信息页

#### INFO-01 分组标题与行标题重复（P2）
- 位置：`BotInfoPage.swift:565-581`（`Section` header `名称` + `HomeFieldRow(title: "名称")`），另 `:553` 顶部又显示一次 Bot 名。
- 截图：`info.png`、`infoLong.png`。
- 现状：页面上依次出现 `大肥鱼`（头部）→ `名称`（分组）→ `名称 大肥鱼`（行）。
- 类别：重复信息。
- 建议：保留头部展示名；把分组标题改成 `Bot 名称` 或删除行内 `名称` 标签；输入框直接占满整行。不要同时保留三处“名称”。
- 契约：`bot-info.md:7` 只要求展示并编辑 Bot 名，没有要求分组标题和行标题都叫“名称”；不需要改契约。

#### INFO-02 外观 footer 是开发者说明（P1）
- 位置：`BotInfoPage.swift:588-590`。
- 截图：`infoAppearance.png`（footer 在首屏下方，代码确认）；`info.png`。
- 现状原文：
  > 只改发型和颜色，与桌面 DSH Bot 一致；点选即保存，自动外观保留给以后的多 Bot 接入。
- 类别：开发者说明 / 内部概念（“桌面 DSH Bot”“自动外观”）。
- 建议：只保留一句用户能理解的结果，例如「点选即保存。」或「只改发型和颜色，点选即保存。」。删除“桌面 DSH”“自动外观”“多 Bot 接入”。
- 契约：`bot-info.md:11-17` 只要求选择器行为，不要求这段解释；不需要改契约。

#### INFO-03 在场 footer 解释后台保活机制（P1）
- 位置：`BotInfoPage.swift:596-598`。
- 截图：`infoPresence.png` 里显示的是夹具自己的说明（`BotFixtures.swift:493`「截图夹具只展示信息页的在场区，组件与真实页面相同。」）；生产代码在 `BotInfoPage.swift:597` 是下面这一段，截图没有覆盖。
- 现状原文：
  > 前台全功能；后台保活靠静音音频继续运行；App 被挂起或杀掉后只能靠预定的本地通知提醒 routine 到期。
- 类别：开发者说明 / 内部机制 / 中英混排（`routine`）。
- 建议：改成用户结果导向的一句话，例如「App 在前台时功能完整；退到后台后会尽量保持运行，被系统挂起后仍会按已登记的时间提醒。」。如果一定要解释机制，放进「了解后台运行」的二级说明，不放在分组 footer。
- 契约：`bot-info.md:34-38` 要求在场数据和文案来自宿主，但没有要求暴露静音音频/挂起细节；不需要改契约。

#### INFO-04 打扰 footer 一段话塞了四件事（P1）
- 位置：`BotInfoPage.swift:604-605`。
- 截图：`infoPresence.png` 夹具显示的是短句「设置对所有 Bot 生效，改动立即持久化。」；生产代码是长段。
- 现状原文：
  > 设置对所有 Bot 生效，改动立即持久化。勿扰关闭所有主动提醒和 routine 到期通知；安静时段延后非紧急提醒，紧急 routine 仍按理由放行。什么值得说、什么算紧急属于记忆偏好，不在这里编辑。
- 类别：开发者说明 / 信息过载 / 中英混排。
- 建议：保留契约要求的一句「设置对所有 Bot 生效」，再补一句结果：「开启勿扰会暂停主动提醒；安静时段内非紧急提醒会延后，紧急提醒仍会送达。」。删除“持久化”“routine”“记忆偏好”“按理由放行”。
- 契约：`bot-info.md:43` 只要求“文案说明设置对所有 Bot 生效”；不需要改契约。

#### INFO-05 安静时段显示英文 12 小时制（P1）
- 位置：`BotInfoPage.swift:1436-1447`（`DatePicker(..., displayedComponents: .hourAndMinute)`）。
- 截图：`infoPresence.png` 明确显示 `11:00 PM` / `8:00 AM`。
- 现状：安静时段开始/结束用系统 Locale 渲染；模拟器是 en_US，因此出现 12 小时制英文 AM/PM。
- 类别：格式不本地化。
- 建议：给 `DatePicker` 加 `.environment(\.locale, Locale(identifier: "zh_CN"))`，并验证在 en_US 设备语言下仍显示 `23:00` / `08:00`；如果系统仍不保证 24 小时制，用一个只读的 `HH:mm` 文本 + 点击弹出时间选择器，显示层始终用 `DateFormatter("HH:mm", zh_CN)`。
- 契约：`bot-info.md:46` 明确要求 `HH:mm` 的 `DatePicker(hourAndMinute)`；当前实现已经违反契约，不需要改契约，直接修实现。

#### INFO-06 当前级别与“预定通知”行文案重复（P2）
- 位置：`BotInfoPage.swift:1391-1397`。
- 截图：`infoPresence.png`。
- 现状：先显示 `当前级别  预定通知`，下一行又是 `预定通知  1 条`。用户会以为两行在说同一件事。
- 类别：重复信息 / 语义不清。
- 建议：第二行改成 `已登记提醒  1 条` 或 `到期提醒  1 条`；不改变含义，只消除重复。
- 契约：`bot-info.md:37` 写的是「一行 `预定通知 N 条`」；如果改文案，需要同步改契约这一行。

#### INFO-07 长 Bot 名在名称行被截断（P2）
- 位置：`BotInfoPage.swift:553-558`（头部展示名）与 `:566-570`（名称编辑行）。
- 截图：`infoLong.png`。
- 现状：头部完整显示「大肥鱼 · 一个用于验证长名称的 Bot」，名称行却显示「大肥鱼 · 一个用于验证长名称...」；用户无法在编辑行读全当前值。
- 类别：截断 / 布局对齐。
- 建议：名称编辑行改为整行无标签的 `TextField`（配合 INFO-01），允许横向滚动编辑；头部展示名保留 `lineLimit(2)`，避免更长名字挤压入场区。
- 契约：不需要改契约；`bot-drawer.md:25` 的 60 UTF-16 上限不变。

#### INFO-08 副标题对所有 Bot 都是同一句（P2）
- 位置：`BotInfoPage.swift:556`。
- 截图：`info.png`、`infoLong.png`。
- 现状原文：`你的私人 Bot，替你跟进任务和提醒`。
- 类别：重复信息 / 内容不准确。管理 Bot 列表里每个 Bot 有独立描述，信息页却不用。
- 建议：优先显示 `BotProfile.description`；没有描述时回退到这句通用文案，或直接不显示副标题。
- 契约：`bot-info.md:7` 只要求展示/编辑名字，不要求副标题；不需要改契约。

### 3.2 记忆页

#### MEM-01 后台整理说明是开发者视角（P1）
- 位置：`BotInfoPage.swift:803-824`。
- 截图：`infoMemory.png`。
- 现状原文：
  > 默认关闭。开启后，只在对话安静、没有待审批且 App 在前台时，宿主才会发起一次独立的后台会话，对照原始记录整理记忆。每次运行是一个批次，检查不过会整批回滚。
- 类别：开发者说明 / 内部术语（宿主、后台会话、批次、整批回滚）。
- 建议：换成用户结果：「开启后，Bot 会在你不聊天时整理记忆；整理失败不会改动现有内容。」如果必须说明触发条件，放到「了解整理规则」的二级说明，主页面只留一句。
- 契约：`bot-info.md:25` 只要求开关、默认关闭、批次卡片和字段；不要求这段说明。不需要改契约。

#### MEM-02 token 用量既技术化又重复出现两次（P1）
- 位置：`BotInfoPage.swift:817-819`（今日预算）与 `:923`（批次用量）。
- 截图：`infoMemory.png`。
- 现状：footer 显示「今日整理已用 12,400/96,000 token。」，批次卡又显示「2 份文档 · 12,400 token · 检查通过」。
- 类别：内部单位（token）/ 重复信息。
- 建议：主视图显示「今日整理额度已用 13%」或「今日额度充足」；批次卡第一行只显示「2 份文档 · 检查通过」，把准确 token 放进「查看详情」。如果产品决定完全不显示 token，需要改契约。
- 契约：`bot-info.md:25` 明确要求批次显示 token 用量；可以折叠到详情（仍然“显示”），不建议直接删除。只有删除才需要改契约。

#### MEM-03 批次行直接显示版本号和内部路径（P1）
- 位置：`BotInfoPage.swift:926-930`。
- 截图：`infoMemory.png`。
- 现状：`v3→v4 · user/INDEX.md`、`v2→v3 · agent/profile.md`。
- 类别：内部 ID / 路径 / 原始版本号。
- 建议：改成「共享索引 INDEX.md：第 3 版 → 第 4 版」「本 Bot 资料 profile.md：第 2 版 → 第 3 版」；完整 `user/`、`agent/` 路径放到「查看详情」。文件名保留是合理的，用户至少知道改了哪份文档。
- 契约：`bot-info.md:25` 要求每个路径的前后版本；人类可读文案 + 详情折叠仍满足。若要从主视图彻底移除路径/版本，需要改契约。

#### MEM-04 “抹除这个 Bot 的 agent 文档”混在文档树里（P1）
- 位置：`BotInfoPage.swift:974-986`（特别是 `:984`）。
- 截图：`infoMemory.png`。
- 现状：在 `agent` 文件夹和文档行下面，直接出现一行黑色文字「抹除这个 Bot 的 agent 文档（含全部版本）」，没有独立分组、没有红色、没有分隔线，看起来像另一条文档。
- 类别：按钮层级 / 危险操作位置。
- 建议：移到独立的 `Section("危险操作")`，用 `BotUIPalette.danger` 的 destructive 按钮，footer 用一句「会永久删除这份文档的全部版本，无法撤销。」。不要放在正常文档列表中间。
- 契约：`bot-info.md:22` 只要求存在该物理删除入口和明确范围说明，不规定位置；不需要改契约。

#### MEM-05 三处开发者脚注（P2）
- 位置：`BotInfoPage.swift:949`、`:842`、`:833`。
- 截图：`infoMemory.png`（`只显示最近一次批次…` 可见；另外两处位于首屏下方/空态）。
- 现状原文：
  - `只显示最近一次批次；本批的每一次写入都带版本前提和引用。`
  - `只属于这个 Bot；其他 Bot 看不到。Task 和 routine 只能提交到 agent/inbox/<会话>/。`
  - `本 Bot 自己的文档和所有 Bot 共享的文档都会显示在这里；两个根下的 INDEX.md 是每回合注入的索引。`
- 类别：开发者说明 / 中英混排 / 内部路径。
- 建议：
  - 第一句保留前半句即可：「只显示最近一次整理。」
  - 第二句改成「这份记忆只属于这个 Bot，其他 Bot 看不到。」，删除 `Task`/`routine`/`agent/inbox/<会话>/`。
  - 空态只留「还没有保存的记忆。」，删除 `INDEX.md`/`每回合注入`。
- 契约：这些都不在契约必需字段里；不需要改契约。

#### MEM-06 分组标题与根文件夹重复、括号半角（P2）
- 位置：`BotInfoPage.swift:839-850`（section 标题）与 `:1002-1010`（文件夹行显示 `agent`/`user`）。
- 截图：`infoMemory.png`。
- 现状：`本 Bot 的工作知识 (agent/)` 下面又是一行 `agent` 文件夹；`共享的用户记忆 (user/)` 同理。括号还是半角 `( )`。
- 类别：重复信息 / 排版细节。
- 建议：section 标题改成「本 Bot 的记忆」「所有 Bot 共享的记忆」；文档树从根的子项开始渲染，不再显示 `agent`/`user` 根文件夹。如果必须保留根路径，使用中文全角括号并把它作为次要说明。
- 契约：`bot-info.md:20` 要求按 `user/` 和 `agent/` 两个根展示；可以不显示根行、只保留分组语义；如果改标题措辞，建议在契约里补一句，避免下个 worker 改回去。

#### MEM-07 文档详情行/来源/作者/标题都技术化（P2）
- 位置：`BotInfoPage.swift:1017-1019`（文档行）、`:1055`（路径）、`:1060`（record 说明）、`:1069`（作者）、`:1091`（版本）、`:1131`（导航标题）。
- 截图：无（记忆文档详情没有截图，代码确认）。
- 现状：
  - `v2 · Oct 9, 2025 at 4:55 PM · 1 条引用`
  - `路径：agent/profile.md`
  - `没有 record:// 引用：这是 agent 的推断或当前 Bot 直接写的。`
  - 作者值来自生产适配器：`chat · user-turn`（`BotProductionUIAdapters.swift:202-203`）
  - 导航标题是整条 `document.path`
- 类别：内部 ID/路径 / 英文格式 / 技术说明。
- 建议：
  - 行摘要：「第 2 版 · 10月9日 22:00 · 1 条来源」。
  - 导航标题用文件名 `profile.md`，路径放到正文 footer。
  - 来源区块主视图显示「来源对话（1 条）」「来源页面（1 条）」，点开再列原始 `record://`。
  - 作者映射为「对话中的你」「这个 Bot」「例行任务」「维护整理」等。
- 契约：`bot-info.md:20` 要求显示完整 Markdown、版本、更新时间、作者/会话类型和 evidence；人类可读标签 + 原始 evidence 折叠仍满足。若要从主视图完全移除路径/URI，需要改契约。

#### MEM-08 抹除确认文案有“事件载荷/派生视图/墓碑/纪元”等实现词（P2）
- 位置：`BotInfoPage.swift:890`、`:901`、`:907`、`:1118`、`:1128`。
- 截图：无（确认弹窗没有截图）。
- 现状示例：
  > 物理删除这个 Bot 的 agent/ 文档树和全部历史版本，并清除事件载荷及派生视图中与它们相同的内容。共享 user/ 不受影响。已关闭会话里的对应聊天原文也会被墓碑替换；对话会接续到新会话。此操作不可撤销。
- 类别：开发者说明 / 内部术语（事件载荷、派生视图、墓碑、纪元）。
- 建议：保留“范围 + 不可撤销”，把实现词换成人话：「会永久删除这份文档和全部历史版本，相关内容也会从旧对话里移除。此操作不可撤销。」共享 user/ 的影响单独用一句。
- 契约：`bot-info.md:22` 要求明确范围与不可撤销，没有要求这些实现词；不需要改契约。

### 3.3 例行任务页

#### ROU-01 内部枚举、内部 ID、effect key 直接显示（P1）
- 位置：`BotInfoPage.swift:1234-1238`、`:1273`；夹具来源 `BotFixtures.swift:331-344`、`:359-363`；生产映射 `BotProductionUIAdapters.swift:223`、`:291-300`、`BotProductionServices.swift:595-598`。
- 截图：`infoRoutines.png`、`infoReconcile.png`。
- 现状原文：
  - `时区  Asia/Shanghai`
  - `交付  held`
  - `设立者  用户回合 · bot-fixture-1`
  - `设立者  经用户确认 · routine:run-2`
  - `已产生的效果：routine.deliver · routine-2:3 · unknown-outcome`
- 类别：原始枚举值 / 内部 ID / 内部路径。
- 建议：
  - `held` → 「下次聊天时送达」；`interrupt` → 「立即提醒」。
  - 时区 → 「上海时间（UTC+8）」（IANA 值放详情）。
  - 设立者 → 「由你在对话中创建」/「你确认后创建」；`bot-fixture-1`、`routine:run-2` 不显示，最多在“详情/长按复制”里给出。
  - 效果 → 「已尝试发送提醒，送达结果未确认」；`routine.deliver · routine-2:3 · unknown-outcome` 不进主文案。
- 契约：`bot-info.md:26` 明确要求展示设立者的 `creator.rpcId／turnId／origin／authorization`，并显示已产生的效果文字摘要。要把原始 ID 从主视图移走，需要先改 `bot-info.md:26`（建议改成“显示 authorization 的人类可读来源；rpcId/turnId/origin 放详情/长按复制”）。delivery 的显示措辞不需要改契约。
- 备注：截图里的 `held` 是夹具直接构造的；生产适配器已经映射成「存入待处理」/「立即打断」。但生产 creator 仍然拼接原始 ID，effectSummary 仍然是裸 `operation · target · reason`，所以这两类线上也会出现。见 §5。

#### ROU-02 约束字段把工具名和 `[quiet]` 原样给用户看（P1）
- 位置：`BotInfoPage.swift:1243-1245`。
- 截图：`infoRoutines.png`。
- 现状原文：`约束  不要调用 SendToUser；没有变化时回复 [quiet]。`
- 类别：内部工具名 / 内部 token。
- 建议：`constraints` 是模型写的自由文本，UI 不应猜着改写。主视图不要把原文铺开；显示一行「约束（原始）」的折叠入口，点开后用等宽字体显示原文。若产品希望有一句人类可读摘要，只能由创建流程写入结构化字段，不能从自由文本推断。同时应在 routine 创建/编辑提示里要求模型不要把 `SendToUser`、`[quiet]` 等内部 token 写进 `constraints`。
- 契约：`bot-info.md:26` 要求展示 `constraints`；折叠“原始设置”仍然展示。不需要改契约，但建议在契约里补一句“约束原文属于高级字段，可折叠”。

#### ROU-03 长字段换行后对齐混乱（P1）
- 位置：`BotInfoPage.swift:1234-1245`。
- 截图：`infoRoutines.png`、`infoReconcile.png`。
- 现状：同一页里「排程/时区/交付/设立者」的值右对齐；「完成条件/约束」在短值时右对齐、长值时换行并从左侧铺满，导致字段和值的关系不稳定。截图第一张卡的「完成条件」在标签下一行左对齐，第二张卡又变成右对齐。
- 类别：布局对齐 / 行高。
- 建议：抽一个 `BotDetailField`：
  - 短字段：两列网格，标签 13pt secondary，值 15pt primary 左对齐（不要右对齐）。
  - 长字段：标签在上、值在下，值 `multilineTextAlignment(.leading)`、`fixedSize(horizontal:false, vertical:true)`。
  - 标签和值都保持左对齐，字段间距统一 6/10。
- 契约：`bot-info.md:26` 只要求展示字段，不规定对齐；不需要改契约。

#### ROU-04 取消/暂停/确认完成/重试/恢复是散落的纯文本按钮（P1）
- 位置：`BotInfoPage.swift:1261-1303`。
- 截图：`infoRoutines.png`、`infoReconcile.png`。
- 现状：
  - `取消运行` 单独一行；
  - 一个约 44pt 的空白后 `暂停` 又单独一行；
  - 对账卡里 `确认完成  重试` 在一行，`恢复` 掉到下一行；
  - 全部黑色、同一字号，没有主次、没有危险色、没有操作区标题。
- 类别：按钮层级 / 间距 / 信息层级。
- 建议：在卡片底部做统一操作区：
  - `确认完成`：主按钮（黑色胶囊）；
  - `重试`：次按钮（浅色胶囊）；
  - `取消运行`：红色文字按钮，和“暂停/恢复”之间加分隔线；
  - `暂停/恢复`：普通文字按钮；
  - 最多两行，按状态只显示相关动作；不要每个动作占一整行 44pt。
- 契约：`bot-info.md:26` 只要求这些动作存在及对账语义；不需要改契约。
- 备注：审批卡的按钮层级（`approval.png`）做得对，可以作为参照；不要动审批卡的“拒绝用中性文字”规则（`bot-chat.md:50`）。

#### ROU-05 对账状态把“结果未知”说了三遍（P1）
- 位置：`BotInfoPage.swift:1256`（`lastResult`）、`:1269`（警告标题）、`:1273`（效果摘要）、`:1277`（原因）。
- 截图：`infoReconcile.png`。
- 现状：
  - `上次执行结果未知：结果是已发送还是未发送无法确认。`
  - `执行结果未知，需要确认`
  - `已产生的效果：routine.deliver · routine-2:3 · unknown-outcome`
  - `原因：投递结果未知：连接在确认前中断`
- 类别：重复信息 / 内部术语。
- 建议：当 `runStatus == "needs-reconciliation"` 时，隐藏或合并 `lastResult`。只保留一个警告块：
  - 标题：「这次运行的结果没有确认」
  - 摘要：「可能已经发送了一条提醒。」
  - 原因：「连接在确认前中断。」
  - 动作：确认完成 / 重试。
- 契约：`bot-info.md:26` 要求显示已产生效果的文字摘要，不要求三处重复；不需要改契约。

### 3.4 常设授权页

#### GRT-01 标题、操作、路径、scope、source、日期全部原样显示（P1）
- 位置：`BotInfoPage.swift:1354-1379`（`:1358` tool、`:1362` scope、`:1364` operation/resource、`:1368` source/date）；生产映射 `BotProductionUIAdapters.swift:242-248`、`BotProductionServices.swift:547-556`；scope 枚举 `Sources/PhoneDSHBot/Authz/BotGrants.swift:5-9`。
- 截图：`infoGrants.png`。
- 现状原文：
  - `write`
  - `write.file · /dsh/workspace/.dshbot/agents/main/reports/**`
  - `来源：approval-card · Oct 9, 2025 at 4:58 PM`
  - `bash`
  - `network-egress · curl https://api.example.test/*`
  - pill：`until`
  - pill：`session`
- 类别：原始枚举值 / 内部路径 / 英文标签 / 英文日期。
- 建议：
  - 标题用人类动作：「写入文件」「网络访问」；tool/operation 原文放详情。
  - resource 摘要：「Bot 报告目录下的所有文件」「允许访问 api.example.test」；完整路径/URL 放「详情」并可复制。
  - `until` → 「长期有效」或「有效至 2025年11月8日」（如果拿到 expiresAt）；`session` → 「本次会话」。
  - `approval-card` → 「来自审批卡」；`approval-standing` → 「来自常设审批」。
  - 日期统一中文化（见 GEN-01）。
- 契约：`bot-info.md:27` 要求列出 tool、operation、resource、scope、sessionId、createdAt、source。人类可读标签仍列出这些字段；如果把完整 resource/ID 放进详情，建议在契约里补一句“resource 可显示摘要，完整值放详情”。直接删除字段才需要改契约。

#### GRT-02 “撤销这条授权”与普通文本同色（P2）
- 位置：`BotInfoPage.swift:1371-1376`。
- 截图：`infoGrants.png`。
- 现状：卡片底部一行黑色 `撤销这条授权`，没有分隔线、没有危险色，和操作说明几乎一样。
- 类别：按钮层级 / 颜色。
- 建议：在卡片底部加一条 hairline，把撤销做成红色文字按钮或红色描边胶囊；不要改变审批卡“拒绝”为中性文字的规则。
- 契约：不需要改契约。

#### GRT-03 契约要求 `sessionId`，页面没有显示（P2）
- 位置：`BotInfoPage.swift:1355-1379`；契约 `bot-info.md:27`。
- 截图：`infoGrants.png`（看不到 session ID）。
- 现状：契约要求列出 `sessionId`；实现里 `BotGrantInfo` 有 `sessionID` 字段，但视图从未使用。
- 类别：契约与实现不一致（不是“杂乱”，而是漏字段）。
- 建议：`session` scope 已经表达“本次会话”，原始 `gb-main` 对用户没有价值。推荐：UI 只显示「本次会话」，同时把 `bot-info.md:27` 的 `sessionId` 从“必须列出”降为“可选/详情字段”。不要为了满足现在的契约把 `gb-main` 加回主视图。
- 契约：需要改 `bot-info.md:27`（把原始 `sessionId` 降为详情/可选）。这是本报告里少数“需要先改契约才能不显示”的项之一。

### 3.5 审批记录页

#### APR-01 生产参数摘要是 `tool/operation · digest` 和 `Grant id · scope · digest` 的裸拼接（P1）
- 位置：`BotInfoPage.swift:1481-1484`；生产来源 `BotProductionServices.swift:700-713`。
- 截图：无（没有 `infoApprovals` 夹具/截图；`approval.png` 是聊天审批卡，不是这个页面）。
- 现状：生产 `approvalRecords()` 生成：
  - `"\($0.tool)/\($0.operation) · \($0.resourceDigest.prefix(16))"`
  - `"Grant \($0.id) · \($0.scope.rawValue) · \($0.resourceDigest.prefix(16))"`
  并以 `\n` 拼接后作为 `parameterSummary`。页面把整段原样显示在白色 List 行里。
- 类别：内部 ID / 原始枚举 / 英文术语 / 技术摘要。
- 建议：在 `BotProductionApproval` 里存结构化字段（动作、目标摘要、decision、scope、时间），UI 生成「写入文件 · 报告目录」「允许一次」等人类可读摘要；digest、Grant ID 放「详情」。如果暂时不做结构化，至少把 `Grant `、`until`、16 位 digest 从主文案移走。
- 契约：`bot-info.md:28` 要求“只显示参数摘要和实际决定”；当前是参数摘要，但不是用户可读摘要。建议在契约里补一句“摘要必须是用户可读文案，不得直接拼接内部 ID/digest”；也可以只修实现，不改契约。
- 备注：这是截图没覆盖、但生产上很可能比 fixture 更乱的一页；建议优先补截图后再动手。

#### APR-02 审批记录只显示“允许/拒绝”，丢失一次/总是/超时（P2）
- 位置：`BotInfoPage.swift:1485-1490`；生产 `BotProductionUIAdapters.swift:235-240`。
- 截图：无（同上）。
- 现状：`record.decision` 在 UI 里直接显示；生产适配器把 `BotGrantDecision.allow` 映射成「允许」、`.deny` 映射成「拒绝」。`allow` 无法区分「允许一次」「本次会话允许」「总是允许」，也没有“已超时/已过期”状态。
- 类别：信息缺失 / 语义不清。
- 建议：给 `BotProductionApproval` 增加 scope/状态字段，显示「允许一次」「本次会话允许」「总是允许」「拒绝」「已超时（视为拒绝）」；颜色只用于状态，不把“拒绝”染红（沿用 `bot-chat.md:50`）。
- 契约：`bot-info.md:28` 要求“实际决定”；补充这些状态是更贴近契约，不需要改契约。

### 3.6 管理 Bot

#### MGR-01 每行描述被限制成一行，长描述直接截断（P2）
- 位置：`BotDrawer.swift:592-596`。
- 截图：`drawerManage.png`。
- 现状：`Text(entry.description ...).lineLimit(1)`；截图第四行显示「一个已经隐藏的 Bot，只在管理列表...」。
- 类别：截断 / 布局。
- 建议：允许 2 行（`lineLimit(2)`）并适当增加行高；或者去掉描述、把描述放到点按后的详情/菜单里。不要用一行截断来承载长描述。
- 契约：`bot-drawer.md:31-33` 只规定行上要有主 Bot 皇冠/已隐藏标签和菜单；没有要求单行描述；不需要改契约。

### 3.7 卡片（任务 / 例行任务 / 进度 / 清单 / 链接）

#### CARD-01 进度卡和例行卡的标题/摘要没有行数上限（P1）
- 位置：`BotCardKit.swift:189-198`（`BotCardHeading` 的 title/detail 都 `fixedSize`，无 `lineLimit`）；`BotWorkCardView.swift:449-456`（automation result 也 `fixedSize`）。
- 截图：`overflow.png`、`automation.png`。
- 现状：`overflow.png` 的进度卡摘要重复到十几行，标题也占三行，整张卡几乎占满一屏；fixture 里自己都写着“长摘要需要限制在两行以内”，但组件没有限制。
- 类别：长文本溢出 / 卡片层级。
- 建议：给 `BotCardHeading` 增加 `titleLineLimit` / `detailLineLimit` 参数（标题 2 行、摘要 2–3 行），超出显示「展开」；`automation` 的 `result` 限制 4 行并支持展开全文。Task 卡验证摘要已有 3 行上限（`BotCardView.swift:230-234`），可以作为参照。
- 契约：`bot-chat.md:22` 要求“超限处理照 DSH Bot”，`bot-chat.md:40` 要求卡片紧凑、按内容决定高度；当前实现没有做超限处理，不需要改契约（但建议在契约里把 title/detail 的行数写清楚，减少歧义）。

#### CARD-02 例行任务卡把 fixture 的 `held` 原样显示出来（P1）
- 位置：`BotWorkCardView.swift:430-444`；夹具 `BotFixtures.swift:146-150`。
- 截图：`automation.png`。
- 现状：`每天 07:30 · Asia/Shanghai · held · 非紧急`。
- 类别：原始枚举值 / fixture 内容 / 原始时区。
- 建议：
  - 夹具改成生产会出现的 `context`（例如「因安静时段延后，原定 07:30」或「紧急：发布截止」），不要用 `held` 这种内部值；
  - 卡片把 schedule/timezone 放在一行 meta，把 quiet/urgent 做成标签，不要把任意 `context` 用 ` · ` 拼在标题下。
- 契约：`bot-chat.md:46` 只要求 automation 卡存在；不需要改契约。

#### CARD-03 检查清单卡的说明是“实现备注”（P2）
- 位置：`BotWorkCardView.swift:134-136`；夹具 `BotFixtures.swift:118-125`。
- 截图：`checklist.png`。
- 现状：摘要「本地勾选不会改写卡片；可手动把结果送回对话。」在用户还没勾选时就出现，像开发者提示。
- 类别：开发者说明 / 冗余文案。
- 建议：删除这句；等用户改动后显示「把勾选结果发给 Bot」按钮即可。如果担心用户不知道，可把说明放进点击后的确认或帮助。
- 契约：不需要改契约。

#### CARD-04 链接卡 fixture 标题暴露内部工作包编号（P2）
- 位置：`BotFixtures.swift:127-136`（特别是 `:133`）。
- 截图：`link.png`。
- 现状：`WP9 SwiftUI 交互层`。
- 类别：内部工作包编号 / 夹具内容。
- 建议：换成真实的产品/文档标题，例如「卡片内容模型」「SwiftUI 交互示例」；`WP9` 只留在测试代码注释里。
- 契约：不需要改契约。

#### CARD-05 `Fixture：<case>` 作为一条 assistant 气泡出现在每个聊天截图（P2）
- 位置：`BotFixtures.swift:57-59`。
- 截图：所有带卡片的聊天截图（`task.png`、`automation.png`、`approval.png`、`progress.png`、`checklist.png`、`link.png`、`overflow.png` 等）。
- 现状：每个 fixture 都先插入一条文本行 `Fixture：task`，看起来像 Bot 真发了一条消息。
- 类别：截图夹具污染 / 用户可见内部标记。
- 建议：只在 `-BotUIDiagnostics` 时显示，或渲染成屏幕顶部的小 `DEBUG` 横幅，不要进入消息流。这样截图审阅时不会误以为是产品文案。
- 契约：这是测试夹具，不属于产品契约；不需要改 UI 契约。

### 3.8 截图专用页

#### CAP-01 外观网格/图库/动态页显示英文 raw value（P2）
- 位置：`BotFishGallery.swift:157-166`（dynamic：`state.rawValue` + `animated`）、`:194-220`（appearanceGrid：`hairstyle.displayName` 后接 `hairstyle.rawValue`，色点下方 `color.rawValue`）；`BotFixtures.swift:493`（infoPresence 夹具说明）。
- 截图：`appearanceGrid.png`、`gallery.png`、`dynamic-1..3.png`、`infoPresence.png`。
- 现状：
  - `经典长卷发 long`、`高双马尾 twin-tail`、`短鲍伯 bob`、`粗侧辫 side-braid`；
  - 每个色点下 `white`、`brown`、`red`、`orange`、`amber`、`green`、`teal`、`blue`、`purple`、`magenta`、`gray`、`black`、`silver`、`peach`、`sky`；
  - dynamic 页 `thinking / animated` 等；
  - infoPresence 页多一句「截图夹具只展示信息页的在场区，组件与真实页面相同。」
- 类别：英文 / capture-only 说明。
- 建议：这些页面是验收对照页（`capture.sh:204-205,332-338`），不是产品 UI。若继续用于 UI 审阅：
  - 主标签只用 `displayName`（中文），raw value 放 accessibility identifier 或右上角小号 `DEBUG`；
  - dynamic 页用中文状态名；
  - infoPresence 的夹具说明改成不进入截图，或放到诊断开关；
  - 如果保留英文用于和桌面 DSH 对照，在报告/截图上标明“capture-only 对照页”，不要拿它当产品页面评估。
- 契约：capture-only 页不在 `spec/ui/v1/pages/*.md` 产品契约里；不需要改契约。

### 3.9 跨页 / 通用

#### GEN-01 所有 `.formatted(date: .abbreviated, time: .shortened)` 都跟随系统英文（P1）
- 位置：`BotInfoPage.swift:919`、`:1019`、`:1070`、`:1095`、`:1368`、`:1490`（共 6 处）。
- 截图：`infoMemory.png`（`Oct 9, 2025 at 10:12 PM`）、`infoGrants.png`（`Oct 9, 2025 at 4:58 PM`）；审批记录无截图。
- 现状：即使 App 全部中文，日期仍是 `Oct 9, 2025 at 4:58 PM`。
- 类别：格式不本地化。
- 建议：新增一个共享 `BotUIFormat`：
  - 今天：「今天 22:12」
  - 今年：「10月9日 22:12」
  - 其他：「2025年10月9日 22:12」
  - 固定 `Locale(identifier: "zh_CN")` + `TimeZone.current`。
  记忆批次、文档行、文档详情、常设授权、审批记录全部换用。
- 契约：`bot-info.md:46` 已经要求 `HH:mm`，其他日期格式没有契约限制；不需要改契约。
- 备注：`BotDrawerTime` 已经是中文（`BotDrawer.swift:799-812`），可以抽成公共格式器，不要复制。

#### GEN-02 危险操作与普通文本同色（P2）
- 位置：`HomeSpec.swift:208`（`.tint(HomeSpec.textPrimary)`）；`BotInfoPage.swift:641-650`（删除 Bot）、`:984`（抹除 agent 文档）、`:1371`（撤销授权）。
- 截图：`infoMemory.png`、`infoGrants.png`；删除 Bot 在 info 页底部，不在首屏。
- 现状：截图里这些 `Button(role: .destructive)` 都是黑色；`homeGroupedList` 在 `HomeSpec.swift:208` 统一设置 `.tint(HomeSpec.textPrimary)`，destructive 的颜色被覆盖/弱化，用户分不清「抹除/撤销/删除」和普通按钮。
- 类别：颜色 / 按钮层级。
- 建议：不要改全局 `HomeSpec` tint（会影响其他页面）。给 Bot 页做一个 `BotDestructiveButtonStyle` 或在按钮 label 上显式 `foregroundStyle(BotUIPalette.danger)`；只用于不可逆的删除/抹除/撤销。审批卡的「拒绝」必须保持中性，不能一起染红。
- 契约：`bot-chat.md:50` 只禁止把审批拒绝染红；没有禁止其他危险操作用红色。不需要改契约。

#### GEN-03 生产代码里有一批繁体中文用户文案，截图夹具把它们盖住了（P2）
- 位置：
  - `Sources/PhoneDSHBot/Routines/RoutineSchedulerTypes.swift:143-187`：`執行已取消`、`執行逾時，已取消`、`執行結果未知，需要確認：…`、`執行失敗：…`、`已完成（沒有新結果）`、`（因安靜時段延後，原定 …）`、`（延遲 N 分鐘觸發）`、`（緊急：…）`、`結果未能交給主對話`、`已通知`、`未通知：…`。
  - `Sources/PhoneDSHBot/Authz/BotToolEffects.swift:129-168,219-221`：`會啟動一個子代理並使用模型額度。`、`傳送訊息給使用者`、`傳送訊息給其他 Bot`、`執行未分類工具 …`、`這個工具沒有在效果分類表中登記…`。
  - `Sources/PhoneDSHBot/Authz/BotApprovalPatterns.swift:36,43`：`這個命令會刪除檔案或目錄…`、`這個命令會捨棄未提交的變更…`。
- 截图：`automation.png`/`approval.png` 使用的是简体 fixture 文案，所以看不到；生产环境会显示这些繁体字。
- 类别：本地化不一致（繁体/简体混排）。
- 建议：统一成简体中文（与 probe app 其余文案一致），或者明确做一套 zh-Hans/zh-Hant 本地化资源；不要在一个界面里混两套字形。routine 的执行结果/延后提示、审批卡的动作/详情都要覆盖。
- 契约：UI 契约没有规定字形/地区；不需要改契约，但这是用户可见文案，建议单独做一轮扫尾。

## 4. 契约要求 vs 实现自加

### 4.1 契约明确要求显示的字段

| 页面 | 契约要求 | 实现位置 | 现状 |
| --- | --- | --- | --- |
| 信息页 | Bot 名、外观 picker、在场 level/count/deferred、打扰 dnd/quiet、数据入口、读取失败不显示 0 | `BotInfoPage.swift:546-721`、`:1387-1448` | 基本实现；footer/标题是自加 |
| 记忆 | `user/`/`agent/` 文档树、完整 Markdown、版本、更新时间、作者/会话类型、evidence、历史版本、忘记/抹除 | `BotInfoPage.swift:776-1134` | 实现；但日期/作者/路径/evidence 显示方式技术化 |
| 记忆 | 后台整理开关、最近一批的状态/时间/文档数/每个路径前后版本/检查/失败码/token 用量/回滚 | `BotInfoPage.swift:803-951` | 实现；token/版本/路径全在主视图 |
| 例行任务 | schedule、timezone、delivery、quiet/urgent、下一次到期/安静延后、运行结果、设立者（rpcId/turnId/origin/authorization）、completion_criteria、constraints、取消/确认完成/重试 | `BotInfoPage.swift:1224-1306` | 实现；creator origin 未显示，next due 未显示；原始 ID 直出 |
| 常设授权 | `scope != once` 的 Grant，tool、operation、resource、scope、sessionId、createdAt、source，每行可撤销 | `BotInfoPage.swift:1327-1385` | 实现；`sessionId` 未显示；其他全为原始值 |
| 审批记录 | 参数摘要 + 实际决定，不显示密钥/完整敏感参数 | `BotInfoPage.swift:1461-1503`；`BotProductionServices.swift:700-713` | 实现；生产摘要是 `tool/operation · digest`、`Grant id · scope · digest` |
| 卡片 | P0 卡片、question/steps/task/progress/checklist/link/approval/automation 等、长内容超限处理 | `BotCardView.swift`、`BotWorkCardView.swift`、`BotCardKit.swift` | 大部分实现；progress/automation 长文本无上限 |

### 4.2 实现自己加的文案/结构（契约没要求）

- 信息页：
  - `名称` 分组标题 + 行内 `名称` 标签（INFO-01）。
  - 外观/在场/打扰三段长 footer（INFO-02/03/04）。
  - 固定副标题「你的私人 Bot，替你跟进任务和提醒」（INFO-08）。
  - 「危险操作」分组的删除说明（可保留，但可缩短）。
- 记忆页：
  - 「后台整理」长说明（MEM-01）。
  - 「今日整理已用 … token」daily budget 行（MEM-02；契约只要求批次 token）。
  - `只显示最近一次批次…`、`Task 和 routine 只能提交到 agent/inbox/<会话>/`、`INDEX.md 是每回合注入的索引`（MEM-05）。
  - `v3→v4 · user/INDEX.md` 的格式（字段本身是契约要求，格式是自加）。
  - `record://` 原文直接铺开（evidence 是契约要求，展示方式自加）。
- 例行任务：
  - `Asia/Shanghai`、`held`/`interrupt`、`用户回合 · bot-fixture-1` 的原始格式（字段是契约要求，格式自加）。
  - `已产生的效果：routine.deliver · …` 的原始格式（摘要字段是契约要求，格式自加）。
  - 按钮散落、无操作区（动作是契约要求，布局自加）。
- 常设授权：
  - `write`/`bash`、`write.file`/`network-egress`、完整路径/URL、`until`/`session`、`approval-card` 的原始格式（字段是契约要求，格式自加）。
- 审批记录：
  - 英文日期、裸参数摘要格式（日期/格式自加）。
- 卡片/截图：
  - `Fixture：` 气泡、`WP9`、`held · 非紧急`、capture-only 英文标签（夹具/测试自加，不是产品契约）。
  - checklist 的「本地勾选不会改写卡片…」说明（自加）。

### 4.3 契约要求但实现未显示的字段

| 字段 | 契约 | 现状 | 建议 |
| --- | --- | --- | --- |
| `routine` 的 `next_due` / 下一次到期 | `bot-info.md:26` | `BotRoutineInfo` 没有 nextDue 字段；页面只显示 schedule 和「安静时段会延后」 | 要么补字段/一行「下次到期 10月10日 07:30」，要么改契约删掉“下一次到期”要求；不要留半实现 |
| `routine` 的 `creator.origin` | `bot-info.md:26` | 生产 `creatorText` 只拼 authorization + `rpcId/turnId/sessionId`，没有 origin | 与 ROU-01 一起改：人类可读来源 + 详情；同时决定是否在契约里保留 origin |
| `grant.sessionId` | `bot-info.md:27` | `BotGrantInfo.sessionID` 有值，但视图没用 | 见 GRT-03：显示 scope 语义或改契约 |
| `approval` 的 “实际决定” scope | `bot-info.md:28` + `bot-chat.md:50` | 生产只映射 allow/deny，丢失一次/总是/会话 | 见 APR-02：补 scope/status |

### 4.4 契约影响结论

**必须改契约才能按建议隐藏/改名**：
1. `bot-info.md:26`：设立者原始 rpcId/turnId/origin、以及 `已产生效果` 的原始格式，改为“人类可读来源 + 详情”。否则主视图继续显示内部 ID 才叫符合契约。
2. `bot-info.md:27`：`sessionId`。要么 UI 显示，要么契约删掉；推荐删掉原始 ID，只保留“本次会话”语义。
3. `bot-info.md:28`：参数摘要必须用户可读，不得直接拼 `tool/operation/digest`；建议把这句话写进契约。
4. `bot-info.md:37`：如果改「预定通知 N 条」这行文案，需要同步契约。
5. `bot-info.md:25` / `:20`：只有在决定**完全不显示** token/路径/版本/evidence 时才需要改；如果只是折叠到“详情”，可以在不改契约的前提下实现。
6. `bot-info.md:26` 的 next due/origin：补 UI 或删契约要求，不能继续空着。

**不需要改契约**：
- 日期中文化、HH:mm、按钮层级/颜色、名称重复、footer 缩短、卡片行数上限、fixture/capture-only 文案、繁体转简体。
- 这些是显示层或测试夹具问题。

## 5. 截图夹具与生产 UI 的偏差（重要）

截图里的问题不全是线上问题；反过来，线上还有截图没暴露的问题。逐条核对如下：

| 截图呈现 | 截图来源 | 生产真实值 | 结论 |
| --- | --- | --- | --- |
| `交付 held` / `interrupt` | `BotFixtures.swift:331-344` 直接构造 | `BotProductionUIAdapters.swift:223` 映射为「存入待处理」/「立即打断」 | 截图不是生产文案；夹具应改用生产显示值，UI 也应对未知值兜底 |
| `设立者 用户回合 · bot-fixture-1`、`routine:run-2` | 夹具原样写字符串 | `BotProductionUIAdapters.swift:291-300` 仍会拼 `authorization · rpcId/turnId/sessionId` | 线上仍会出现内部 ID，需要改 UI + 契约（ROU-01） |
| `已产生的效果：routine.deliver · routine-2:3 · unknown-outcome` | 夹具原样写 | `BotProductionServices.swift:595-598` 仍拼 `operation · target · reason` | 线上仍会出现 effect key，需要结构化/映射（ROU-01） |
| `infoPresence` footer「设置对所有 Bot 生效，改动立即持久化。」 | `BotFixtures.swift:485-506` | `BotInfoPage.swift:604-605` 是长段（含静音音频、routine、记忆偏好） | 截图把生产长文案盖住了；修 INFO-04 时要按生产代码改 |
| `automation` 卡 `held · 非紧急` | `BotFixtures.swift:146-150` | `RoutineAutomation.context`（`RoutineSchedulerTypes.swift:173-187`）是「（因安靜時段延後…）」等繁体文案，且没有 `schedule`/`held` | 截图对例行卡不具代表性；修夹具 + 统一简体（CARD-02/GEN-03） |
| `approval` 卡标题/动作/详情为简体 | `BotFixtures.swift:137-145` | 生产 `BotToolEffects`/`BotApprovalPatterns` 的 zh 文案是繁体；动作/详情来自 `BotProductionServices` 的 effect 记录 | 截图掩盖了繁简混排（GEN-03） |
| 记忆文档作者「chat · 用户消息」 | 夹具 `memoryDocument` 写死 | `BotProductionUIAdapters.swift:202-203` 是 `author.kind.rawValue + source.kind.rawValue`，例如 `chat · user-turn` | 线上文档详情会出现英文枚举（MEM-07） |
| `until` / `session` / `approval-card` | 夹具 | `BotProductionUIAdapters.swift:245,248` 原样传 `scope`/`source` | 截图与生产一致，都是原始值（GRT-01） |
| 英文日期 `Oct 9, 2025 ...` | `formatted` 跟随系统 Locale | 同一代码 | 截图与生产一致（GEN-01） |
| `appearanceGrid` / `gallery` / `dynamic` 英文 | capture-only `BotFishGallery.swift` | 不是产品页面 | 不能当产品 UI 评估（CAP-01） |
| `Fixture：task` 气泡 | `BotFixtures.swift:57-59` | 不是产品消息 | 截图污染（CARD-05） |

**建议**：在改 UI 前先做一个“生产保真”夹具：
- fixture 的 `delivery`/`creator`/`effectSummary`/`approval.parameterSummary`/`memory.author` 都使用生产适配器相同的值或同一映射函数；
- `infoPresence` 直接复用生产 `BotInfoPage` 的 `Section`（如果可能），不要另写一份短 footer；
- 给 `automation` 夹具使用 `RoutineAutomation` 的 context 生成逻辑；
- 增加 `infoApprovals` 和 `memoryDocumentDetail` 两个截图 case。

否则“按截图修”会修错层：截图里的 `held` 可能在生产已经是「存入待处理」，但生产的 creator/effect 又比截图更乱。

## 6. 证据缺口与未验证

### 6.1 截图覆盖缺口（不计入 36 条）

1. **审批记录页没有截图**。`BotUIFixtureCase` 没有 `infoApprovals`；`approval.png` 只是聊天里的审批卡。`APR-01`/`APR-02` 只有代码证据。
2. **记忆文档详情页没有截图**。`infoMemory.png` 只到文档树顶部，`BotMemoryDocumentView` 的路径/来源/版本行没有视觉证据（MEM-07/MEM-08）。
3. **`infoEmpty.png` / `infoError.png` 只截到页面顶部**。空态/失败态在数据入口和子页里，首屏看起来与 `info.png` 一样；`infoError.png` 与 `info.png` 的 sha256 完全相同（`3a75ddd9…`），不能证明失败态。建议补“滚动到数据区”的截图，或单独给空态/失败态做 fixture。
4. **深色截图没有审阅**。任务提供的是浅色 40 张；深色下的 `.tint`、危险色、footer 对比度未验证。
5. **动态字体 / 窄屏 / VoiceOver 未验证**。`infoLong` 只覆盖长名称，不覆盖 Dynamic Type；`overflow` 只覆盖卡片长文本。

### 6.2 未运行

- 未重跑 `scripts/ci/bot-ui/capture.sh`（按要求使用现成截图）。
- 未构建 App、未启动模拟器、未跑 XCUITest。
- 未在真机验证后台保活、通知、挂起/杀进程。
- 未验证深色、动态字体、VoiceOver、横屏/宽屏。

## 7. 建议修复分包

> 目的：方便主会话再派 worker。每包都限定在现有页面框架内，不重构导航/分组列表；先改文案/字段取舍/格式/按钮样式，再补契约和截图。
> “预计改动量”是给排期的粗估，不是实际 diff。

### 包 F（前置）：共享格式化与映射层

- 范围：新增 `BotUIFormat`（日期 `zh_CN`、`HH:mm`、今天/今年相对格式、token 百分比/紧凑数字），以及 `BotGrantScope`/`BotGrantSource`/`RuntimeDelivery`/`RoutineCreator` 的 display mapping。
- 文件：`examples/probe-app/PhoneDSHProbe/Bot/BotUIComponents.swift` 或新增 `BotUIFormat.swift`；必要时在 `Sources/PhoneDSHBot` 加 display-only 扩展。
- 契约：无。
- 预计：1–2 文件，约 50–90 行。
- 依赖：B/C/D 都建议先合入这一层，避免各自复制日期/枚举映射。

### 包 A：例行任务页（对应 ROU-01～ROU-05，5 条 P1）

- 范围：
  - 抽 `BotDetailField`（短字段两列、长字段上下、左对齐）。
  - 底部操作区：确认完成/重试/取消运行/暂停/恢复按状态分组。
  - `delivery`、`creator`、`effectSummary` 的人类可读映射；原始 ID 放详情/长按复制。
  - `needs-reconciliation` 时合并重复的“结果未知”文案。
  - 修 `BotFixtures.swift` 的 delivery/creator/effect 值，避免截图继续展示 `held`/`bot-fixture-1`。
- 文件：`BotInfoPage.swift:1166-1325`、`BotFixtures.swift:330-363`、`BotProductionUIAdapters.swift:217-233,291-300`、`BotProductionServices.swift:588-599`。
- 契约：若要隐藏 creator ID，需要改 `bot-info.md:26`；effect 摘要/布局不需要。
- 预计：4–5 文件，约 220–320 行；截图 `infoRoutines`/`infoReconcile` 需重拍。

### 包 B：记忆页（对应 MEM-01～MEM-08，4 P1 + 4 P2）

- 范围：
  - 重写后台整理说明为 1–2 句；日预算改百分比，token 放详情。
  - 批次主行改「2 份文档 · 检查通过」，路径/版本/完整 token 放「查看详情」。
  - 抹除入口移到独立“危险操作”Section，红色，去掉文档行位置。
  - 删除三处开发者脚注；根文件夹行与 section 标题去重；中文全角括号。
  - 文档详情：导航标题用文件名，路径/`record://`/author 放详情并中文化。
  - 抹除确认文案去“事件载荷/派生视图/墓碑/纪元”。
- 文件：`BotInfoPage.swift:776-1134`、`BotProductionUIAdapters.swift:195-215`、`BotUIFormat`（包 F）。
- 契约：`bot-info.md:20`/`:25` 中“显示 evidence/路径/版本/token”的要求保持不变；折叠到详情即可。若决定完全不显示，先改契约。
- 预计：3–4 文件，约 220–320 行；截图 `infoMemory` 需重拍。

### 包 C：常设授权与审批记录（对应 GRT-01～GRT-03、APR-01～APR-02，2 P1 + 3 P2）

- 范围：
  - `BotGrantScope` 映射：`until` → 「长期有效」/「有效至 …」，`session` → 「本次会话」。
  - tool/operation/resource 的人类可读标题与摘要；完整路径/URL 放详情。
  - source 映射：`approval-card` → 「来自审批卡」，`approval-standing` → 「来自常设审批」。
  - 撤销按钮红色/分隔。
  - 审批记录：生产 `parameterSummary` 结构化/人类可读；决定补 once/always/超时状态；日期中文化。
  - `sessionId`：显示“本次会话”或改契约删掉原始 ID。
- 文件：`BotInfoPage.swift:1327-1503`、`BotProductionUIAdapters.swift:235-248`、`BotProductionServices.swift:700-713`、`BotUIFormat`（包 F）。
- 契约：`bot-info.md:27`（sessionId、resource 摘要）、`:28`（参数摘要可读性）需要小幅修改或明确解释。
- 预计：4 文件，约 180–260 行；新增 `infoApprovals` 截图。

### 包 D：信息页文案与格式（对应 INFO-01～INFO-08，4 P1 + 4 P2）

- 范围：
  - 名称分组/行标签去重；长名称编辑行占满；副标题改用 profile description。
  - 外观/在场/打扰 footer 缩成 1–2 句用户文案。
  - 安静时段强制 `HH:mm`（可用包 F 的格式器 + `DatePicker` locale）。
  - “当前级别/预定通知”文案去重（需改契约 `bot-info.md:37`）。
  - 危险操作红色（与 GEN-02 合并做 `BotDestructiveButtonStyle`）。
- 文件：`BotInfoPage.swift:546-721,1387-1459`、`BotUIComponents.swift`、`BotUIFormat`（包 F）。
- 契约：`bot-info.md:37`（文案）、`:43`（footer 保留一句）、`:46`（HH:mm，已要求）；`:46` 不需要改，只要修实现。
- 预计：2–3 文件，约 140–200 行；截图 `info`/`infoLong`/`infoPresence` 需重拍。

### 包 E：卡片、夹具与截图专用页（对应 CARD-01～CARD-05、CAP-01、GEN-03，2 P1 + 5 P2）

- 范围：
  - `BotCardHeading` 增加 title/detail 行数上限和展开；`automation` result 限行。
  - `automation` 夹具改用生产 context；`checklist` 删除预防性说明；`link` 去掉 `WP9`；`Fixture：` 改为诊断开关。
  - `appearanceGrid`/`gallery`/`dynamic` 主标签中文化，raw value 移到 accessibility/DEBUG；`infoPresence` 夹具说明移出截图。
  - 生产繁体文案统一为简体（`RoutineSchedulerTypes.swift:143-187`、`BotToolEffects.swift`、`BotApprovalPatterns.swift`）。
- 文件：`BotCardKit.swift`、`BotWorkCardView.swift`、`BotFixtures.swift`、`BotFishGallery.swift`、`RoutineSchedulerTypes.swift`、`BotToolEffects.swift`、`BotApprovalPatterns.swift`。
- 契约：`bot-chat.md:22`/`:40` 的“超限处理/紧凑”已有要求；capture-only 与繁体不在产品契约里。不需要改契约（但建议在 `bot-chat.md` 把 title/detail 行数写清楚）。
- 预计：6–7 文件，约 200–320 行；所有相关截图需重拍。

### 包 G：证据补强（不计入 UI 修复，但建议同批做）

- 新增 `infoApprovals` fixture + 截图；新增记忆文档详情截图。
- `info` 空态/失败态改为滚动到数据区截图，或单独 fixture；确认 `infoError.png` 不再与 `info.png` 同图。
- 记录 production-fidelity fixture：用生产适配器生成 `delivery`/`creator`/`effect`/`approval`/`memory.author` 的显示值。
- 文件：`BotFixtures.swift`、`capture.sh`（如果需要滚动动作）、`CaptureUITests.swift`。
- 预计：2–3 文件，约 100–180 行；截图重跑。
- 备注：本单元按任务要求没有重跑截图；这一步留给实现包。

### 依赖与顺序建议

1. 先做 **F**（共享格式/映射），再并行 **A**（例行任务）、**B**（记忆）、**D**（信息页文案）。
2. **C**（授权/审批）依赖 F，且建议先补 `infoApprovals` 截图（G）再动文案。
3. **E**（卡片/夹具/繁体）与 A/B/C/D 独立，但会改动所有截图，建议最后做。
4. 每包完成后都必须重拍 light/dark 并人工看一遍；本报告的截图不能直接当修复后证据。

## 8. 建议提交信息

本次审计本身不提交；给后续 worker 的建议：

```text
fix(bot-ui): humanize routine detail, creator and effect text
Protocol impact: none — UI presentation only; contract amendment listed separately.

fix(bot-ui): simplify memory copy and localize memory dates
Protocol impact: none — UI presentation only.

fix(bot-ui): humanize grants and approval history
Protocol impact: none — UI presentation only; spec/ui change requires owner sign-off.

fix(bot-ui): shorten info footers and fix quiet-time format
Protocol impact: none — UI presentation only.

fix(bot-ui): clamp long card text and clean capture fixtures
Protocol impact: none — cards/fixtures/capture-only labels only.

test(bot-ui): capture approval history and empty/error states
Protocol impact: none — fixtures/screenshots only.
```

如果后续真的编辑 `spec/ui/v1/pages/bot-info.md`，该提交必须按 `AGENTS.md` §3 单独声明实际触发的契约 ID（至少会涉及 P09/P25/P26 中与 UI 页面相关的项），不要把“报告建议”当成已冻结契约。

## 9. 交接证据（AGENTS.md §3.5）

```text
Base / head:        d988108c1ec0c56903d6087c282cc9278bbdfd19 / 1f1c1ea6b287ef0b190108419d331d97dd0b562b
Protocol impact:    none — audit/report only; no source, spec, schema, golden, or test files changed.
Contract revision:  read-only at head 1f1c1ea6; no new contract revision produced.
Changed files:      docs/research/bot-ui-audit-20261111.md (new)
                    .audit-shots/ (pre-existing untracked evidence; not modified/committed)
Status per end:     iOS probe/capture UI inspected; production adapters and Bot package read.
                    Android/HarmonyOS: not applicable (no Bot UI runtime here).
Commands → result:
  git status / grep / read / read_image → PASS (static evidence)
  capture.sh / xcodebuild / xctest → NOT_RUN (per task: use existing screenshots; no build)
  dark mode / Dynamic Type / VoiceOver / device → NOT_RUN
Not verified:        actual production UI runtime, approval-history screen, memory-document detail screen,
                    dark mode, dynamic type, VoiceOver, real-device background keep-alive/notifications.
Remaining risks:     Some P1s are screenshot-fixture-only (held/interrupt, automation context) and are
                    marked in §5; contract changes for creator/grant/approval display must be owner-approved;
                    the 36 count excludes four evidence gaps listed in §6.
```

### 附：本次实际执行的只读命令

- `git rev-parse HEAD` / `git merge-base HEAD origin/main`（确认基线/HEAD）
- `grep` 统计：`formatted(date:` 6 处；`BotInfoPage.swift` 中 `routine:`/`.md`/`/dsh/`/`held`/`interrupt`/`token` 等内部值 13 处；`RoutineSchedulerTypes.swift` 的用户文案 11 处。
- `read` 以上 Swift/契约文件；`read_image` 逐张打开 40 张浅色截图。
- 未改源码、未改 `spec/`、未改测试、未 commit/push。
