<!-- SPDX-License-Identifier: MIT -->

# BotInfoPage（target）

契约：P09、P25、P26。目标实现路径：`examples/probe-app/PhoneDSHProbe/Bot/**`。

Bot 信息页使用 phoneDSH 现有设置页分组、列表和导航 token，展示并编辑由 runtime-context 注入的 Bot 名，提供记忆、Routines、审批记录三个真实数据入口，并在同一分组列表内展示在场状态、编辑打扰设置。头部 80pt 头像调用冻结的 `BotFishView(state: .idle, size: 80, appearance: model.appearance, still: true)`（不跑帧循环）；Bot 页「…」菜单可直接打开与数据区相同的记忆／例行任务／审批记录目标页。页面不得伪造条目数、授权状态或后台 session 过程；读取失败显示失败，不显示为零。

## 外观（P26）

名称下方是「外观」区，与桌面 DSH Bot 的 `NameBotDialog`/`InfoPane` 对齐，只暴露发型和颜色：

- 112pt 实时预览（idle，可 poke），使用当前 Bot 资料的外观。
- 「发型」一行 4 个 40pt 静帧大肥鱼（`long`、`twin-tail`、`bob`、`side-braid`），每个以当前颜色着色；选中的外圈 44pt；accessibility label 用简体 displayName（经典长卷发、高双马尾、短鲍伯、粗侧辫）。
- 「颜色」15 个 24pt 色点，44pt 点击区，自动换行；选中外圈；accessibility label 用简体 displayName。
- 该外观选择器抽成 `BotAppearancePicker`，信息页与「添加 Bot」对话框共用同一个组件和同一组 accessibility id 前缀；对话框只保留草稿状态，信息页仍点选即保存。
- 点选即保存（`BotProfileStore.upsert` 只带改动字段）并全页实时生效；预览、4 个发型缩略图与 Bot 页头部/空状态/状态行同步。
- 本轮不提供「自动」选项；资料模型的 `nil` 保留给以后的多 Bot 导入。页面不显示自动外观标记，也不伪造未保存状态。

- 记忆：按 `user/` 和 `agent/` 两个根展示文档树，目录可展开；文档详情显示完整 Markdown、当前版本、更新时间、作者/会话类型和 `evidence`（`record://` 引用）；可查看历史版本列表和每个版本的正文/删除标记。路径、版本和 evidence 均来自宿主 `ReadMemory` 同一权威，不伪造条目或来源。每份文档的「忘记」删除该文档（历史仍可查看），两个根各自保留原有的「抹除」二次确认；物理抹除是 S6。不提供第一版未实现的自动抽取、反思或衰减开关，也不在页面内编辑文档正文。accessibility id 前缀 `bot.memory.*`、`bot.info.memory`。
- 记忆页顶部有「后台整理」开关（id `bot.memory.maintenance.toggle`），默认关闭；开关持久化为 P18 键 `phone-dsh.bot.memory-maintenance.v1`（`{enabled, runTokenBudget, dailyTokenBudget}`，所有 Bot 共享）。下方「上次整理」卡片（id `bot.memory.maintenance.batch`）只显示最近一次真实批次：状态、时间、改动文档数、每个路径的前后版本/删除、检查是否通过、失败码和 token 用量，数据来自 durable `memory.maintenance_finished` 事件，不伪造一次运行。批次仍可回滚时显示「回滚这次整理」（id `bot.memory.maintenance.rollback`），确认后调用宿主按 S2 版本恢复整批回滚；已回滚或不可回滚时不显示按钮，历史批次仍保留。页面不显示模型的过程文本，也不提供编辑批次内容的入口。
- Routines：展示 schedule、timezone、delivery、quiet/urgent 标记、下一次到期/安静时段延后、运行结果、设立者（`creator.rpcId`／`turnId`／`origin`／`authorization`）、`completion_criteria` 与 `constraints`；动作通过 UserAction/宿主服务，不直接修改数据库。运行中（`run_state.status == "started"`）显示「取消运行」；`run_state.status == "needs-reconciliation"` 显示已产生效果的文字摘要，并提供「确认完成」和「重试」两个独立动作，分别走 `RoutineMachine.resolveReconciliation` 与 `BotEffectOutbox.ackReconciled`／`retryNeedsReconciliation`。取消、对账后重读权威状态；读取失败显示失败，不显示为零。
- 常设授权：单独入口，列出本 Bot 的 `scope != once` Grant（tool、operation、resource、scope、sessionId、createdAt、source），每行可撤销。撤销调用 `BotGrantStore.revoke(id:)` 并重读；不把 once 授权显示为常设，也不在撤销失败时本地移除。授权状态未知时显示读取失败，不伪造“无授权”。accessibility id 前缀 `bot.grant.*`。
- 审批记录：只显示参数摘要和实际决定，不显示密钥或完整敏感参数。
- 深链 `phonedsh://bot/<botID>/row/<rowID>` 定位真实行；未知或过期行显示不可用，不跳到无关会话。routine 到期通知使用 `phonedsh://bot/<botID>/routine/<routineID>`，打开本页的例行任务区并定位该 routine 行；未知或已删除的 routine 显示不可用，不跳到无关页面。
- 上述条目和动作只增不改：分组列表、导航和 token 沿用现有 Bot 信息页，不新增独立页面框架。

## 在场状态（P26 §3.8）

名称编辑与外观之后、数据入口之前增加只读「在场」区，数据和文案来自宿主，不由页面推断：

- 一行「当前级别」：`前台` / `后台保活` / `预定通知`。App 处于 active 时为前台；App 不在前台且静音音频保活开启（任一 Bot 有回合，或保活窗口内有到期的 routine）时为后台保活；否则为预定通知。页面不把「有 routine」写成「正在运行」。
- 一行 `预定通知 N 条`：N 是宿主实际登记成功的 routine 到期通知数，不是 routine 总数；登记失败或被系统丢弃时显示实际值或读取失败，不伪造 0。
- 「因安静时段延后」列表：每项显示 routine 标题、原定时间和延后到的时间，来自 `quiet_defer`；没有延后时不显示假条目。列表只读，运行/暂停仍在例行任务区操作。
- accessibility id：`bot.info.presence`、`bot.info.presence.level`、`bot.info.presence.notifications`、`bot.info.presence.deferred.<routineID>`。

## 打扰设置（P26 §3.8）

「数据」区上方增加「打扰」区，编辑宿主授权而不是模型偏好；文案说明设置对所有 Bot 生效：

- 勿扰开关，id `bot.info.dnd`。关闭后宿主拒绝所有主动提醒候选，并取消 routine 到期本地通知。
- 安静时段开始/结束两个时间选择器，id `bot.info.quiet.start`、`bot.info.quiet.end`，使用 `HH:mm` 的 `DatePicker(hourAndMinute)`；默认 `23:00`–`08:00`。
- 改动立即持久化（`phone-dsh.bot.proactive-settings.v1`）并通知运行中的调度器；无需「保存」，读取失败保留旧值并显示错误，不把失败当成已关闭。
- 页面不提供「什么值得说」「什么算紧急」「用哪一档」的编辑，这些属于 `user/preferences/` 记忆；页面也不新增通知权限或系统设置入口。
- 系统通知权限由「手机权限」页管理；未授权或用户关闭通知时，宿主登记失败并在「预定通知」显示实际成功数，页面不伪造。
- 截图：`info` 夹具打开真实页面；capture-only `infoPresence` 夹具用同一 `BotPresenceSection` / `BotDisruptionSection` 组件展示在场与打扰区，light/dark 各一张。
- 浅色、深色、空态、读取失败、长标题和深链定位需要模拟器截图与交互证据；真机后台通知与系统限制仍为 NOT_RUN，不能从模拟器或静态检查推断。
