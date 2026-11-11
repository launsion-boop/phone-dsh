<!-- SPDX-License-Identifier: MIT -->

# BotInfoPage（target）

契约：P09、P25、P26。目标实现路径：`examples/probe-app/PhoneDSHProbe/Bot/**`。

Bot 信息页使用 phoneDSH 现有设置页分组、列表和导航 token，展示并编辑由 runtime-context 注入的 Bot 名，提供记忆、Routines、审批记录三个真实数据入口，并在同一分组列表内展示在场状态、编辑打扰设置。四个数据入口（含常设授权）**各自独立加载**：一处投影失败只把该入口标成读取失败，不得拖垮其他入口。读取失败的文案必须是用户能看懂的中文，不得显示宿主错误类型名、英文 `localizedDescription`、内部错误码或 `error N`；具体错误只写宿主诊断日志。头部 80pt 头像调用冻结的 `BotFishView(state: .idle, size: 80, appearance: model.appearance, still: true)`（不跑帧循环）；Bot 页「…」菜单可直接打开与数据区相同的记忆／例行任务／审批记录目标页。页面不得伪造条目数、授权状态或后台 session 过程；读取失败显示失败，不显示为零。

## 外观（P26）

名称下方是「外观」区，与桌面 DSH Bot 的 `NameBotDialog`/`InfoPane` 对齐，只暴露发型和颜色：

- 信息页不另设预览，顶部 80pt 头像随发型 / 颜色点选即时更新，不画第二个头像。
- 「发型」一行 4 个 40pt 静帧大肥鱼（`long`、`twin-tail`、`bob`、`side-braid`），每个以当前颜色着色；选中的外圈 44pt；accessibility label 用简体 displayName（经典长卷发、高双马尾、短鲍伯、粗侧辫）。
- 「颜色」15 个 24pt 色点，44pt 点击区，自动换行；选中外圈；accessibility label 用简体 displayName。
- 该外观选择器抽成 `BotAppearancePicker`，信息页与「添加 Bot」对话框共用同一个组件（信息页 id 前缀 `bot.info.appearance`，对话框前缀 `bot.add.appearance`）；是否显示组件内预览由调用方决定。信息页关闭组件内预览；「添加 Bot」对话框没有顶部头像，保留其 104pt 预览和草稿状态，信息页仍点选即保存。
- 点选即保存（`BotProfileStore.upsert` 只带改动字段）并全页实时生效；顶部 80pt 头像、4 个发型缩略图与 Bot 页头部/空状态/状态行同步。
- 本轮不提供「自动」选项；资料模型的 `nil` 保留给以后的多 Bot 导入。页面不显示自动外观标记，也不伪造未保存状态。

- 记忆：按 `user/` 和 `agent/` 两个根分组展示文档树（分组标题为「本 Bot 的记忆」「所有 Bot 共享的记忆」，不再重复渲染 `agent`/`user` 根文件夹行），目录可展开；文档行显示文件名、当前版本、更新时间和来源条数。文档详情显示完整 Markdown、当前版本、更新时间、作者/会话类型的用户可读标签（如「对话中的你」「这个 Bot」「例行任务」「维护整理」）和 evidence（`record://` 引用）；原始 `record://` 引用、完整路径和原始版本号折叠在同一详情页的「来源」「查看详情」里，仍可查看。可查看历史版本列表和每个版本的正文/删除标记。路径、版本和 evidence 均来自宿主 `ReadMemory` 同一权威，不伪造条目或来源。删除有两个强度且文案不能混用：
  - 每份文档的「忘记」是逻辑删除：只移除 live 版本，历史版本和原始记录仍保留。
  - 文档详情的「抹除这份文档和全部历史版本」、记忆页「危险操作」分组里针对本 Bot 的「抹除这个 Bot 的记忆（含全部版本）」和共享 `user/` 根的双重确认「抹除所有 Bot 共享的记忆（含全部版本）」是物理删除：清除文档、全部历史版本、事件载荷、检索/注入/UI 行中的对应内容，并追加 `erasure` 事件；其他 Bot 的 `agent/` 文档不受影响，`user/` 抹除影响所有 Bot。
  - 所有抹除入口都必须有明确范围说明和不可撤销提示。抹除同时命中已关闭会话纪元的聊天记录：命中行被墓碑替换，`record://session` 不再返回原文；主对话切到新会话并显示一行「对话已接续」notice，旧纪元中未命中的内容仍可见。宿主确认后重读权威状态；失败显示失败，不把失败当成功或本地伪装已删除。
  - 不提供第一版未实现的自动抽取、反思或衰减开关，也不在页面内编辑文档正文。accessibility id 前缀 `bot.memory.*`、`bot.info.memory`，单文档抹除为 `bot.memory.document.erase`。
- 记忆页顶部有「后台整理」开关（id `bot.memory.maintenance.toggle`），默认关闭；开关持久化为 P18 键 `phone-dsh.bot.memory-maintenance.v1`（`{enabled, runTokenBudget, dailyTokenBudget}`，所有 Bot 共享）。下方「上次整理」卡片（id `bot.memory.maintenance.batch`）只显示最近一次真实批次：主视图显示状态、时间、改动文档数、人类可读的文档名与前后版本/删除、检查是否通过；完整 `user/`/`agent/` 路径、失败码和准确 token 用量折叠在「查看详情」中，仍可查看。日额度在主视图只以百分比显示一次（如「今日整理额度已用 13%」），准确 token 不出现在主视图。数据来自 durable `memory.maintenance_finished` 事件，不伪造一次运行。批次仍可回滚时显示「回滚这次整理」（id `bot.memory.maintenance.rollback`），确认后调用宿主按 S2 版本恢复整批回滚；已回滚或不可回滚时不显示按钮，历史批次仍保留。页面不显示模型的过程文本，也不提供编辑批次内容的入口。
- Routines：展示 schedule、timezone、delivery、quiet/urgent 标记、下一次到期/安静时段延后、运行结果、设立者、`completion_criteria` 与 `constraints`；动作通过 UserAction/宿主服务，不直接修改数据库。主行使用人类可读值：delivery 显示「下次聊天时送达」/「立即提醒」，时区显示「上海时间（UTC+8）」这类城市名与 UTC 偏移，设立者显示 `creator.authorization`／`creator.origin` 的人类可读来源（例如「由你在对话中创建」「你确认后创建」），运行结果状态显示中文；下一次到期来自 `next_run_at`，安静时段延后来自 `quiet_defer`。`creator.rpcId`／`turnId`／`sessionId`／`origin` 原始值、IANA 时区标识、运行编号和效果记录只放进可展开的「详情」，不进入主行。`completion_criteria` 与 `constraints` 是创建者写入的自由文本：其中包含工具名、提示词标记等内部片段时，主行只显示一句「原文包含执行提示」的说明，原文不改写地放进「详情」；不得从自由文本推断或伪造摘要。运行中（`run_state.status == "started"`）显示「取消运行」并使用危险操作样式；`run_state.status == "needs-reconciliation"` 只显示一处「这次运行的结果没有确认」说明（含已产生效果的人类可读摘要与原因），并提供「确认完成」和「重试」两个独立动作，分别走 `RoutineMachine.resolveReconciliation` 与 `BotEffectOutbox.ackReconciled`／`retryNeedsReconciliation`；原始 effect key/target/reason 只在「详情」展示。取消、对账后重读权威状态；读取失败显示失败，不显示为零。
- 常设授权：单独入口，列出本 Bot 的 `scope != once` Grant（tool、operation、resource、scope、createdAt、source），主行显示人类可读的操作类别、资源摘要、有效范围、来源和创建时间；`tool`、`operation`、完整 `resource` 路径/URL 与原始 `sessionId` 放在该行的「详情」里，详情默认折叠。每行可撤销。撤销调用 `BotGrantStore.revoke(id:)` 并重读；不把 once 授权显示为常设，也不在撤销失败时本地移除。授权状态未知时显示读取失败，不伪造“无授权”。accessibility id 前缀 `bot.grant.*`。
- 审批记录：只显示用户可读的参数摘要和实际决定，不显示密钥或完整敏感参数。参数摘要必须由动作和操作类别组成，不得直接拼接内部 ID、resource digest 或原始枚举。实际决定区分允许一次、本次会话允许、总是允许、拒绝、已超时（视为拒绝）、已过期（视为拒绝）和已取消。
- 深链 `phonedsh://bot/<botID>/row/<rowID>` 定位真实行；未知或过期行显示不可用，不跳到无关会话。routine 到期通知使用 `phonedsh://bot/<botID>/routine/<routineID>`，打开本页的例行任务区并定位该 routine 行；未知或已删除的 routine 显示不可用，不跳到无关页面。
- 上述条目和动作只增不改：分组列表、导航和 token 沿用现有 Bot 信息页，不新增独立页面框架。

## 在场状态（P26 §3.8）

名称编辑与外观之后、数据入口之前增加只读「在场」区，数据和文案来自宿主，不由页面推断：

- 一行「当前级别」：`前台` / `后台保活` / `预定通知`。App 处于 active 时为前台；App 不在前台且静音音频保活开启（任一 Bot 有回合，或保活窗口内有到期的 routine）时为后台保活；否则为预定通知。页面不把「有 routine」写成「正在运行」。
- 一行 `已登记提醒 N 条`：N 是宿主实际登记成功的 routine 到期通知数，不是 routine 总数；登记失败或被系统丢弃时显示实际值或读取失败，不伪造 0。
- 一行只读「桥状态」：仅在宿主内存里存在最近一次失败的身份登记时显示，文案来自宿主保存的本地时间和错误码（例如「最近一次身份登记失败：unauthorized · 11月11日 22:44」）。宿主记录里还有 session id 供诊断，但这一行不显示 token、参数、请求体或完整 session id；成功后宿主清除，页面不推断、不缓存旧错误。没有错误时不显示这一行，也不显示「正常」占位。
- 「因安静时段延后」列表：每项显示 routine 标题、原定时间和延后到的时间，来自 `quiet_defer`；没有延后时不显示假条目。列表只读，运行/暂停仍在例行任务区操作。
- accessibility id：`bot.info.presence`、`bot.info.presence.level`、`bot.info.presence.notifications`、`bot.info.presence.bridge`、`bot.info.presence.deferred.<routineID>`。

## 打扰设置（P26 §3.8）

「数据」区上方增加「打扰」区，编辑宿主授权而不是模型偏好；不在分组底部显示解释性文案，控件规则如下：

- 勿扰开关，id `bot.info.dnd`。关闭后宿主拒绝所有主动提醒候选，并取消 routine 到期本地通知。
- 安静时段开始/结束两个时间选择器，id `bot.info.quiet.start`、`bot.info.quiet.end`，使用 `HH:mm` 的 `DatePicker(hourAndMinute)`；默认 `23:00`–`08:00`。
- 改动立即持久化（`phone-dsh.bot.proactive-settings.v1`）并通知运行中的调度器；无需「保存」，读取失败保留旧值并显示错误，不把失败当成已关闭。
- 页面不提供「什么值得说」「什么算紧急」「用哪一档」的编辑，这些属于 `user/preferences/` 记忆；页面也不新增通知权限或系统设置入口。
- 系统通知权限由「手机权限」页管理；未授权或用户关闭通知时，宿主登记失败并在「已登记提醒」显示实际成功数，页面不伪造。
- 截图：`info` 夹具打开真实页面；capture-only `infoPresence` 夹具用同一 `BotPresenceSection` / `BotDisruptionSection` 组件展示在场与打扰区，不带 footer 说明，截图里不出现夹具说明，light/dark 各一张。
- 浅色、深色、空态、读取失败、长标题和深链定位需要模拟器截图与交互证据；真机后台通知与系统限制仍为 NOT_RUN，不能从模拟器或静态检查推断。
