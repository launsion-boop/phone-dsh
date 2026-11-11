<!-- SPDX-License-Identifier: MIT -->

# BotDrawer / Bot 列表侧边栏（target）

契约：P09、P26、P27。目标实现：`examples/probe-app/PhoneDSHProbe/Bot/BotDrawer.swift`，由 `NativeShell.swift` 的同一抽屉机制承载。上游参考仅用于交互语义（`Sidebar.jsx` 的 dock 状态徽标、`NameBotDialog.jsx` 的创建对话框）；视觉值只用 phoneDSH 的 `HomeSpec` / `NativeParityTokens`。

## 1. 入口与抽屉机制

- Bot 页头部左上角是 44pt 圆形抽屉入口，样式、16pt 左边距和 44pt 命中区与任务页「打开会话列表」按钮相同；accessibility label「打开 Bot 列表」，id `bot.drawer.open`。头部中央 Bot 胶囊和右侧共享设备/「…」胶囊位置不变。
- 抽屉复用 `NativeShell` 的现有机制：宽 320，左侧贴边，右侧上下圆角 22；手机从左侧滑出，点遮罩关闭，横向左滑关闭；宽屏常驻侧栏。遮罩、宽度、动画、无障碍 escape 动作都和会话抽屉一致。
- 抽屉内容按 `selectedTab` 选择：任务 tab 显示现有 `HomeDrawer`，Bot tab 显示 `BotDrawerPanel`。离开 Bot tab 时关闭；DSH 页的会话抽屉行为、截图和 id 不变。
- `BotDrawerPanel` 的 accessibility label 为「Bot 列表」；客户端把抽屉内容从 accessibility 树移除的规则与 `SessionsDrawerPanel` 相同。

## 2. Bot 列表

- 数据唯一来源是 `BotRosterModel`：`visibleEntries`（主 Bot 置顶、排除 `hidden_by_user`、其余按插入顺序）与每个 entry 的 live `fishState` / `activity` / `isRunning` / `pendingApprovalCount` / `unreadCount` / `lastMessageAt`；不另建 roster 或运行状态。
- 每行 38pt 实时大肥鱼（`fishState` 驱动；主 Bot `crowned: true`；`reaction` 与聊天页同一 reaction id）、15pt semibold 名字、12.5pt 单行状态、可选未读角标。行高 60，左右 10，选中用 `HomeSpec.userBubble` r12 高亮并带 selected trait；id `bot.drawer.row.<botID>`。
- 状态行优先级：待审批 `N 项待审批`（warning 色）> 运行中 activity 的同一状态文字（与聊天页共用 `BotActivity.detail`；模型写的 `description`/`summary`/`label` 优先并截 20 字，否则类别短语，能带目标时附「 · 目标」；thinking/reviewing/generic 无详情时用该类别首句，如「思考中 / 看看结果 / 处理中」；同一活动超过 60s 追加「 · N 分钟」）> 空闲最后消息相对时间（刚刚 / N 分钟前 / N 小时前 / M月d日）；无消息显示「还没有消息」。
- 未读数大于 0 时在行尾显示 20pt 红色胶囊角标，超过 99 显示 `99+`；accessibility 读「N 条未读」，id `bot.drawer.unread.<botID>`。
- 点击行调用宿主的选择动作并关闭抽屉；生产宿主用 `BotProductionHub.select(_:)`，因此头部名字、外观、皇冠、聊天页模型和侧边栏选中态同步切换。
- 顶部「Bot」标题右侧「…」按钮打开「管理 Bot」列表，id `bot.drawer.manage`。列表上方固定全宽「添加 Bot」胶囊，52pt 高、白底 r26、细描边，与 DSH 抽屉「新会话」同一规格；id `bot.drawer.add`。

## 3. 添加 Bot 对话框

- 只保留名字 + 发型 + 颜色：名字输入在 binding setter 中即按字素簇安全截断到最多 60 个 UTF-16 单元（输入与粘贴同一路径，绝不切坏 emoji/组合字符），因此不会出现超长态；输入框下方不显示任何校验或字数提示，也不留空白占位（不存在的 `bot.add.name.hint` 不再渲染）。去空格后为空时禁用「创建」；名字非空时输入框右侧有清除按钮（id `bot.add.name.clear`）；默认 `long` + `blue`。
- 104pt 实时预览随发型/颜色即时更新；发型和颜色直接复用信息页的 `BotAppearancePicker`（4 个 40pt 发型静帧 + 15 个 24pt 色点，44pt 命中区）。
- 「创建」调用 `create(name:description:color:hairstyle:)`；成功后选中新 Bot 并关闭抽屉；失败在对话框内显示错误，不关闭。UI 的 60 单元截断只限制可编辑文本；模型层 `BotRosterModel.create` / `BotProfileStore.validateName` 仍拒绝空白和超过 60 个 UTF-16 单元的名字（fixture 的 create 路径直接验证该拒绝）。id：`bot.add.name`、`bot.add.name.clear`、`bot.add.create`、`bot.add.cancel`、`bot.add.error`。

## 4. 管理 Bot

- 行内长按 context menu 和「管理 Bot」列表共用同一组动作：改名、外观、设为主 Bot（已是主 Bot 时隐藏）、隐藏/取消隐藏、删除 Bot。
- 改名对话框与添加对话框使用同一规则：输入框在输入/粘贴时按字素簇安全截断到 60 个 UTF-16 单元，不显示规则或字数提示；去空格后为空时保存走既有错误面。模型层仍只接受去空格后的非空 ≤ 60 个 UTF-16 单元。外观打开该 Bot 的 `BotInfoPage` 外观区（同一个 picker、同一个 profile 写入）；设为主 Bot 走 `setMain`；隐藏/取消隐藏走 `setHidden`，隐藏后从抽屉消失但仍在管理列表。
- 管理列表是唯一显示隐藏 Bot 的地方，行上有「主 Bot」皇冠和「已隐藏」标签；id `bot.manage.row.<botID>`，每行菜单 id `bot.manage.menu.<botID>`。
- 删除必须二次确认，文案说明会中止回合、拒绝待审批、撤销授权、归档 DSH 会话，并删除该 Bot 的记忆、例行任务和待处理消息；生产宿主调用 `BotProductionHub.deleteBot(_:)`，走完整级联。最后一个 Bot 不显示可用的删除动作，而是显示「这是最后一个 Bot，不能删除。」

## 5. 状态与反应

- 侧边栏行的 `fishState` / `activity` 与聊天页使用同一个 `BotLiveFishProjection`：实时 `turn/start` → thinking，`tool/call` → working，`streamStart`/`textDelta` 合成的 `model.delta` → speaking/streaming，待审批 → alerting，60s 无回合/事件/触摸 → sleeping；失败 turn/end 或运行时错误合成 `error` → sad 一次性状态。
- `FishAction` 的 `tool/call` 生成 `BotFishReaction`，同一 Bot 的头部、空状态、状态行和侧边栏行都传 `reaction:`；其他 Bot 不受影响。`FishAction` 不进入过程行或回合工具列表（`BotDisplayContract.hiddenToolNames`）。
- agent-comm 行的小头像使用对方 Bot 的外观，对方是主 Bot 时带皇冠；主 Bot 自己的聊天页头部和空状态同时显示皇冠。

## 6. 验收

- `scripts/ci/bot-ui/capture.sh` 的 `drawer` / `drawerAdd` / `drawerManage` / `reactionLive` fixture 在 light/dark 下截图；`drawerAdd` 是空的普通填写态（不再展示错误或提示）。另有 capture-only `reactionHeader` 证明抽屉关闭时头部同样消费 `reaction:`。交互测试覆盖打开抽屉 → 点第二个 Bot → 抽屉关闭且头部切换、添加 Bot（空名禁用且无提示 → 输入 61 单元截断为 60 → 清空后创建并切换头部）、左滑关闭。
- 宽屏常驻侧栏、窄屏滑出抽屉、遮罩点击关闭、减少动态效果、长名字和 99+ 未读都要在模拟器核对；模拟器结果不写成真机结果。
