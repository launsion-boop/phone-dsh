<!-- SPDX-License-Identifier: MIT -->

# BotInfoPage（target）

契约：P09、P25、P26。目标实现路径：`examples/probe-app/PhoneDSHProbe/Bot/**`。

Bot 信息页使用 phoneDSH 现有设置页分组、列表和导航 token，展示并编辑由 runtime-context 注入的 Bot 名，提供记忆、Routines、审批记录三个真实数据入口。头部 80pt 头像调用冻结的 `BotFishView(state: .idle, size: 80, appearance: model.appearance, still: true)`（不跑帧循环）；Bot 页「…」菜单可直接打开与数据区相同的记忆／例行任务／审批记录目标页。页面不得伪造条目数、授权状态或后台 session 过程；读取失败显示失败，不显示为零。

## 外观（P26）

名称下方是「外观」区，与桌面 DSH Bot 的 `NameBotDialog`/`InfoPane` 对齐，只暴露发型和颜色：

- 112pt 实时预览（idle，可 poke），使用当前 Bot 资料的外观。
- 「发型」一行 4 个 40pt 静帧大肥鱼（`long`、`twin-tail`、`bob`、`side-braid`），每个以当前颜色着色；选中的外圈 44pt；accessibility label 用简体 displayName（经典长卷发、高双马尾、短鲍伯、粗侧辫）。
- 「颜色」15 个 24pt 色点，44pt 点击区，自动换行；选中外圈；accessibility label 用简体 displayName。
- 该外观选择器抽成 `BotAppearancePicker`，信息页与「添加 Bot」对话框共用同一个组件和同一组 accessibility id 前缀；对话框只保留草稿状态，信息页仍点选即保存。
- 点选即保存（`BotProfileStore.upsert` 只带改动字段）并全页实时生效；预览、4 个发型缩略图与 Bot 页头部/空状态/状态行同步。
- 本轮不提供「自动」选项；资料模型的 `nil` 保留给以后的多 Bot 导入。页面不显示自动外观标记，也不伪造未保存状态。

- 记忆：按 `user/` 和 `agent/` 两个根展示文档树，目录可展开；文档详情显示完整 Markdown、当前版本、更新时间、作者/会话类型和 `evidence`（`record://` 引用）；可查看历史版本列表和每个版本的正文/删除标记。路径、版本和 evidence 均来自宿主 `ReadMemory` 同一权威，不伪造条目或来源。每份文档的「忘记」删除该文档（历史仍可查看），两个根各自保留原有的「抹除」二次确认；物理抹除是 S6。不提供第一版未实现的自动抽取、反思或衰减开关，也不在页面内编辑文档正文。
- Routines：展示 schedule、timezone、delivery、quiet/urgent 标记和运行结果，动作通过 UserAction/宿主服务，不直接修改数据库。
- 审批记录：只显示参数摘要和实际决定，不显示密钥或完整敏感参数。
- 深链 `phonedsh://bot/<botID>/row/<rowID>` 定位真实行；未知或过期行显示不可用，不跳到无关会话。

浅色、深色、空状态、读取失败和长文本需要模拟器截图与交互证据；当前状态为 target，不代表页面已经实现。
