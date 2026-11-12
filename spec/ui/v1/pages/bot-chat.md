<!-- SPDX-License-Identifier: MIT -->

# BotChatPage / Bot 卡片页面（target）

契约：P09、P27。上游：dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6` 的 `FEISHU-CARD-SYSTEM.md`、`CARD-UX-AUDIT.md`、`displayContract.js`、`cardPayloads.cjs`、卡片组件、Transcript、Composer、ActivityLine 和 FishDirector。目标实现路径：`examples/probe-app/PhoneDSHProbe/Bot/**`；当前不声明已有页面或运行时证据。

## 1. 页面与 session

- 首屏为单栏主 Bot 对话。顶栏采用 Grok 式：左侧是 44pt 圆形「打开 Bot 列表」入口（`bot.drawer.open`，与 DSH 页左上角会话抽屉按钮同款样式/位置，见 `bot-drawer.md`）；整屏水平居中的头像胶囊（32pt 实时大肥鱼 + 17pt semibold Bot 名 + 14pt 活动小图标），点按打开 `BotInfoPage`（id `bot.info.open`）；右侧是与 DSH 页共享的 92×44「连接设备 + …」胶囊（`bot.connect-device`、`bot.header.menu`），连接设备打开与 DSH 页相同的 `NativeDeviceConnectionPage`。Bot 设置入口只在「…」菜单内：菜单顶部是不可点的「跟进中 N · 需要你处理 M」说明行，下面是 Bot 信息与设置、记忆、例行任务、审批记录；「需要你处理」大于 0 时头像胶囊右上角显示 6pt 提示圆点。名字过长按尾部截断，不能与右侧胶囊重叠。主 Bot 的头像胶囊与空状态头像带皇冠；头部、空状态、状态行和侧边栏行共享同一 `reaction:`。
- 14pt 活动小图标固定在名字右侧、胶囊内部：thinking 或尚无正文的 streaming 显示三个依次起伏的点（1.2s 循环，透明度 .35→1→.35，相邻错开 .2s）；tool-running 显示铅笔（`pencil`，透明度 .72↔1，1.4s）；有待审批时显示红色「!」；空闲不显示。reduce motion 时静止在全不透明状态。图标不新增点击目标，整颗胶囊仍打开 Bot 信息。
- 大肥鱼头像是 dsh-bot 分层渲染器的 SwiftUI/Canvas 移植，由当前 Bot 的真实运行时事件驱动（`BotFishLifecycle` 全部状态，见 §4）；不是按状态切整张静态 PNG。素材授权已明确；使用 `public/assets/fish` 同构的 512×512 RGBA PNG/JSON，`bot/fish` 渲染器在 Swift 中执行模型、弹簧、表情 sprite 与装饰，不运行 JavaScript。主 Bot 的皇冠身份由真实 principal 决定，不能按名称伪造。`FishAction` 工具调用只生成该 Bot 的一次性 `BotFishReaction`，叠加在 lifecycle 之上；它不出现在过程行或回合工具列表。agent-comm 行的小头像使用对方 Bot 的外观，对方是主 Bot 时带皇冠。
- 空状态在消息区可用高度内垂直、水平居中：96pt 实时大肥鱼（可戳）、标题「嗨，我是 {name}」15/22 semibold、正文 13/18 次要色居中，间距 12。id `bot.chat.empty`。
- 每个 Bot 只有一条连续主对话；无新建对话、对话列表、回滚和删除单条。向上滚动调用 `history(before:)`。
- 用户消息可带附件：输入框左侧「+」选择照片或文件，生成 chip；发送时先写入该 Bot 的 DSH 工作区，用户行在正文气泡内显示附件卡片（名字、大小、类型）。附件是消息内容的一部分，不是新会话或新页面。
- 运行中 composer 可用，消息走 steering；用户消息优先于 Task 并发。停止就地取消当前回合，丢弃迟到输出。
- 后台 routine/Task 只投影卡片，不暴露过程 session。隐藏回合不显示用户行和模型散文。
- 待审批不在 composer 上方重复提示；审批操作只在消息流里的审批卡片内完成，头部 alerting 与侧边栏「N 项待审批」状态保留。长按消息提供复制、查看来源；桌面 hover 不搬到手机。
- 现有 DSH 多 session 工作台保持独立，不重构成 Bot 主对话。

## 2. 手机尺寸换算

结构、内容模型、空状态、超限处理和交互照 DSH Bot；视觉值只取 phoneDSH `tokens.json`，不复制桌面 CSS 色值或新增第二套 token；卡片表面本轮明确收紧为 16pt 圆角与 12pt 内距。用户最新明确要求：所有消息卡片必须比此前紧凑，不能呈现为全宽大窗口。卡片标题最多 2 行、摘要最多 2 行；超过时显示「展开」，展开后完整显示，不得用无上限的长文本撑开卡片。

| DSH Bot 桌面语义 | phoneDSH 手机规则 |
| --- | --- |
| 卡片宽 `min(100%,560px,100%-82px)` | 与同一 assistant 回复气泡共享唯一 `BotContentWidth`：列宽的 86%，左对齐；卡片宽度不得超过该回复气泡，内容较窄时按内容宽度、不强行撑满；同一左右 `HomeSpec.contentInset`，不额外增加 16pt 外边距，不使用全屏/居中模态窗口 |
| 产出卡 r22 | `radius.bubble`（24） |
| 工作卡 r18 | 卡片表面 r16（本轮从 `radius.listCard` 18 收紧） |
| 行内提示 r14 | `radius.card`（12） |
| 卡片内距 16、密集 14 | 卡片表面统一 12pt 内距；外边距只能来自共享回复列，不重复扣除 |
| 标题 15/500 | 卡片标题 15/22 semibold，不使用更大的页面标题 |
| 正文 14/20 | 卡片正文和列表行 14/20；主要回答正文仍用 `typography.body` |
| 密集/辅助 13、备注 12 | eyebrow / meta 12/18，仍取 `typography.caption` 层级 |
| 主、次、文字三按钮层级 | `colors.primaryButton` + `colors.primaryButtonInk`、`colors.sessionSelector` + `colors.sessionPrimary`、透明底 + `colors.sessionSecondary`；触控目标至少 44pt，主要操作按手机视觉动线置于上方 |
| 成功/进行中/警告/失败/失效 | `colors.sessionSuccess` / `colors.sessionAccent` / `colors.sessionWarning` / `colors.sessionDanger` / `colors.sessionTertiary`；每卡最多两个语义色 |
| 描边和表面 | `colors.sessionBorderL1/L2`、`colors.surface` / `colors.sessionSelector`；浅色和深色必须使用同一角色 |

桌面 32px 按钮、28px 密集行、40px 选项行在手机上统一提升到至少 44pt 的可点击区域；视觉图标可以更小，但命中区域不得缩小。question/steps 的选项视觉行高为 44 而非 52，行间 4，选项默认透明，不为每项再套一层厚底卡；recommended 才使用轻 tint、细边和推荐徽标。关闭图形可以紧凑，但命中区仍为 44。

所有卡片高度由实际内容决定，不设置大面积固定高度或用空白撑开。标题最多 2 行、摘要最多 2 行，超过时提供「展开/收起」；超过 4 个步骤/条目默认折叠，长文档在卡片内局部展开；预览是用户主动打开后的独立行为，不能在 transcript 中直接弹出大窗口。notice 使用行内紧凑提示，Task/routine、审批、progress、checklist、link、attachment、document 与 question/steps 都受同一 86% Bot 内容宽度约束。

会话纪元切换时追加一条 info notice（单个紧凑行）：说明被抹除的内容已从旧会话日志移除、对话已接续到新会话。notice 不得包含被抹除的文本或旧 session id；旧纪元中未命中的行仍按时间与新纪元拼接显示，墓碑行不显示。

## 3. 卡片清单

P0 第一版必须实现：question、steps（含 recommended）、task、attachment、document、progress（cardKey 就地更新）、checklist、link、approval、automation routine 运行卡、error/denial notice。

P1 仅登记为 target：table、callout、info、payload、library。第一版不渲染、不注册工具、不进 persona。canvas、product、gift、Bot 间通讯行不实现。

question/steps 选项为整行可点并支持 recommended，提交时只使用宿主写入卡片的 `optionID`；**没有“其他”选项、卡内输入框或自定义答案提交控件**。仅 question 支持关闭：本地立即隐藏并写 durable `card.dismissed`，不产生模型可见回合，宿主在下一次用户回合开头以 held 项告知模型视为不回答；DSH 不可用时关闭仍本地生效。steps 不提供关闭按钮，`cardDismiss` 对 steps 返回 rejected。用户需要自由回答时直接在 composer 输入，作为普通 `chat` 消息，而不是 `cardAnswer.customText`。审批为拒绝/允许一次/总是允许三选项加 alwaysScope，拒绝使用中性文字按钮，禁止把否定语义染红。checklist 本地勾选和回传行为沿上游；link 仅打开 HTTP/HTTPS 且经系统安全外部打开策略。

所有卡片先验证 `body.type`、`cardType` 和必需数据。未登记或数据不足时不渲染，不用空白卡或猜测默认值补齐。

Task 卡在标题下显示独立验证结论（`body.verification`，P26 §2.8）：`verdict=passed` 显示「验证通过」success，`failed` 显示「验证未通过」danger，`uncertain` 显示「验证不确定」warning；摘要最多 3 行，另显示依据的 `record://` 条数。验证行是已有 Task 卡的附加行，不新增卡片类型，也不把 Task 状态和验证结论合并成一个标签；没有 `verification` 时保持原样。accessibility id 为 `bot.task.verification`。

## 4. 最新基线的表现与接线

- Bot 色彩：用户气泡和推荐卡表面使用真实 Bot 色彩，但必须满足 phoneDSH 深浅色与对比度 token；不能把桌面任意色值直接用于正文或背景。推荐色不能掩盖文字层级或失败语义。
- 活动行：composer 上方、左对齐只保留一条运行指示（id `bot.activity.line`），左侧 28pt 实时大肥鱼，状态行固定使用 App 端 `.lively` 动效档（30fps 上限；28pt 也保留头部/头发/耳朵分层摆动；其他位置默认 `.standard`，行为不变），内层动作取代原先的上下浮动，外层只保留 2.6s 往返的 1.00–1.025 呼吸缩放、不做垂直位移（避免两层动作叠加），右侧 14/20 次要色单行省略文字，带从左到右的柔和高光，文字不变时在 55%–100% 不透明度之间 1.2s 往返呼吸。从点「发送」后（本地用户行已追加、host 尚未开始这一轮）起显示；这一轮开始（`runningTurnID` 被设置或 live 被创建）、发送失败、或附件导入后没有内容而移除本地行时结束等待，120s 内没有开始任何回合则自动隐藏；回合运行中（`runningTurnID != nil` 或 live 尚未结束且未被压住）持续显示，正文流式输出和待审批都不隐藏；用户停止或收到最终回复后状态行立即隐藏并一直压到 `turn/end`，已流出的文字保留到 durable 行接管，不随状态行一起清除，下一次发送或新回合开始时重新显示；整行不拦截触摸。文字按工具类别生成：`BotActivityPhrases` 把 Bot 可调用的 DSH 内置工具和 `mcp__phone__*` 工具映射到 `BotActivity.category`（thinking/reading/searching/browsing/running/writing/memory/messaging/reviewing/waiting/replying/generic）和一句中文动作短语，能带目标时附「 · 文件名/搜索词/网站域名」（沿用现有 target 42 字规则）；工具参数里有 `description`/`summary`/`label` 时优先显示模型写的这句——去首尾空白和句末标点，超过 20 个字符截断加「…」，类别仍按工具名判断。最后一个 `tool/call` 已有对应 `tool/result`、且之后没有新工具或流式输出时，类别为 reviewing、显示「看看结果」类短语（可带该工具目标），不再卡在上一条；`step/start` 后尚未出现新工具时回到 thinking；未知工具显示 generic 的「处理中」，不显示原始工具名；隐藏工具（`FishAction`）不产生状态行。待审批时类别固定为 waiting、文字固定「等你确认」且不轮换；正文正在流出（`pendingDelta`、`streamingText` 或尚未提交的 live buffer 非空）时类别为 replying，通用短语池为「正在回复…」「组织语言…」「写回复中…」，已提交成段的文字不算；waiting/replying 优先于工厂给出的活动，工厂没有活动时（刚发送、host 还没给事件）回退 thinking。子样式按类别选择 `BotFishWorkStyle`：reading、memory → `reading`；searching、browsing → `searching`；running → `running`；writing → `writing`；thinking、reviewing、messaging、waiting、replying、generic → `generic`；它只在 `.lively` 且 lifecycle 为 working 时生效，不是新的 lifecycle 状态。每条活动至少显示 800ms，期间到来的新活动只保留最新一条（latest-wins），到时再切换；只有 thinking/reviewing/generic/replying 且没有模型 description 时才按 2.4s 轮换该类别的通用短语（waiting 固定一句不轮换），每次进入新活动随机起点；具体工具短语和模型 description 不轮换。同一活动持续超过 60s，在末尾追加「 · N 分钟」，按分钟刷新。文字变化时旧文字淡出上移、新文字淡入（y 4→0），0.35s easeInOut；整行出现/消失淡入淡出 0.25s；reduce motion 时以上动画全部关闭。状态来自当前 turn 的实时事件与 `BotRuntimePresentationFactory`/`BotFishDirector`；子样式只映射活动类别，不另写 lifecycle 状态映射，也不生成消息行。
- Bot 消息流只显示用户消息、Agent 文字回答、卡片与审批行、agent-comm 行；不显示工具行、思考行或回合过程行，运行进度只通过 `bot.activity.line` 表达，回合结束后也不保留可展开的过程行。状态行出现或输入区（composerDock）高度变化时消息流滚到最新；发送后等下一个 runloop 再滚一次，保证最新内容不被输入框挤到下面。
- 输入区：Grok 式白色胶囊，最小高 52、圆角 26、细描边 + 浮动阴影；左右内边距各 8，左侧 36pt 圆形「+」、中间输入框、右侧 36pt 圆形发送/停止，三者在单行时垂直居中，多行增长时「+」与按钮贴底 8pt。占位「向 {name} 提问」，多行增长上限约 5 行。右侧按钮按状态切换但发送 id 不变：
  - 空闲且有文字 → 黑底白色 `arrow.up` 发送（id `bot.composer.send`）；空闲无文字 → 同一位置置灰禁用；
  - 运行中且输入为空 → 停止（id `bot.composer.stop`）；
  - 运行中且有文字 → 发送，文字并入当前回合（id `bot.composer.send`，accessibilityLabel「发送并 steering」）；不会排队。
  - 输入胶囊下方不显示回合、排队或停止说明文字；按钮行为和 accessibilityLabel 不变。
  TextField 文本与按钮中心对齐；多行 TextField 的回车只换行，不直接发送。**没有麦克风、语音模式或语音入口。**
- 附件：胶囊左侧 36pt「+」（id `bot.composer.attach`）打开「照片」（`PhotosPicker`，多选）与「文件」（`fileImporter`，`.data`，多选）。选中后在胶囊上方显示横向 chip（类型图标 + 文件名 + 大小/类型 + 移除 ×，id `bot.composer.attachment.<index>`）；每条最多 10 个、单个 ≤ 25 MiB，超限当场提示且不加入。有附件时无文字也可发送；运行中（steering）同样可带附件。发送时先经 `BotAttachmentImporting` 写入该 Bot 的 DSH 工作区，失败的逐个提示「附件「名」未附加：原因」，不阻止其余附件和文字。用户行在正文下方显示附件卡片（名字、大小、类型），复用同一紧凑卡片语言。runtimeNotice、steering 提示保持原功能并与胶囊样式协调。
- 简洁回复：persona 与 runtime context 必须保留最新简洁回复预算和明确 next-step 文案，不允许为了显示卡片强凑选项；卡片是否提供由 Agent 根据真实下一步价值决定。
- 头像状态：`turn_started → thinking`、`model.delta → speaking/thinking`、工具调用 → working、审批/Watchdog → alerting、成功 → celebrate、失败/拒绝 → sad、turn_end → idle 的优先级、one-shot TTL 和去重沿最新 FishDirector。待审批时 UI 覆盖为 alerting；空闲 60s 进入 sleeping，用户任何输入、发送或点按页面唤醒。状态只来自当前 Bot 的真实事件，不能由 UI 自报或虚构。状态行额外使用 App 端 `.lively` 动作档：thinking 头部约 ±6° 慢摆、眼睛上望来回看，三个点按约 0.12s 错开依次上下跳动；working 为点头 + 身体约 ±5.5–7° 左右摆 + 周期性压缩回弹，并可按 App 端 `BotFishWorkStyle` 选择 `generic` / `reading` / `searching` / `running` / `writing`——它只是渲染子样式，不是新的 lifecycle 状态，不进入 `spec/bot/v1/fish-director.schema.json`；streaming/speaking 有嘴型动作和约 ±10° 头部摆动；celebrate/done 为约 1.2s 的开心小跳。所有状态按 3–5s 周期眨眼（0.26s），状态切换用约 320ms 稳定的弹簧过渡；reduce motion、低电量模式、`botFishPaused` 或不可见时仍冻结为单帧。
- 头像资产采用 `BotFish/` 的分层 PNG（body 为灰度，按当前 Bot 资料的颜色 LUT 着色；发型取 `BotFish/base` 或 `BotFish/hair/<style>` 图层）与 `expressive/{eyes,mouths}.png` 3×4 表情 sprite；36/60/120pt 使用同一 anchor。所有头像由 `BotProfileStore` 的 `BotFishAppearance`（颜色 + 发型）渲染，默认 `blue/long`；没有资料时回退 `.classic`。P0 生命周期所需 idle/thinking/streaming/working/sleeping/alerting/listening/speaking/happy/sad 必须有资源；其他状态按实际事件接入。设置页等静态位置使用 `still: true` 冻结在 650ms 姿态。头像只做圆形裁切，不加白色底盘、描边或投影，直接叠在宿主表面上。只有 `bot.activity.line` 的鱼使用 `.lively`；聊天头、抽屉、空状态、个人页等其余位置保持 `.standard`，尺寸、帧率与动作不变。

## 5. 验收

每种 P0 卡片在浅色和深色模拟器截图，逐项对照上游内容模型、空状态、超限、按钮层级和交互。覆盖窄屏、长标题、动态字体、44pt 命中区、卡片关闭/选择、重复点击、迟到结果和 progress 同 key 更新。另需覆盖真实鱼头像的 idle/working/alerting/celebrate/sad、活动行显隐和推荐色对比度。模拟器结果不得写成真机结果。

## 6. Grok 式改版结构与 id

| 区域 | 结构 | accessibility id |
| --- | --- | --- |
| 左侧抽屉入口 | 44pt 圆形白色按钮，两条黑 Capsule 线，16pt 左边距；点按按 `selectedTab` 打开 Bot 列表抽屉 | `bot.drawer.open` |
| 居中 Bot 胶囊 | 32pt `BotFishView`（主 Bot 皇冠，可带 `reaction:`）+ 17pt semibold 名字 + 14pt 活动小图标（三点 / 铅笔 / 红色「!」；空闲隐藏），44pt 高白色 Capsule；右上 6pt 提示圆点 | `bot.info.open` |
| 右侧共享胶囊 | 与 DSH 页同一 `HeaderActionPill`：连接设备（在线 6pt 圆点）+「…」菜单 | `bot.connect-device`、`bot.header.menu` |
| 空状态 | 96pt 动态大肥鱼，标题 15/22 semibold，正文 13/18，间距 12，可用高度居中 | `bot.chat.empty` |
| 工作状态行 | 28pt 浮动大肥鱼 + 14/20 单行文字（从点发送到回合结束都显示；停止或最终回复后立即隐藏、已流出的文字保留；待审批固定「等你确认」，正文流出显示 replying，其余用工具类别短语；模型 description 优先并截 20 字；800ms latest-wins；只有通用短语 2.4s 轮换、60s 后追加「 · N 分钟」；切换淡入淡出、静止时呼吸）+ shimmer，输入框上方左对齐 | `bot.activity.line` |
| 输入胶囊 | 最小高 52、r26、白色、细描边、浮动阴影；左/右 8，左侧「+」、右侧单按钮三态（空闲发送·置灰 / 运行中空输入停止 / 运行中带文字发送并入当前回合），单行居中、多行贴底 8pt | `bot.composer.input`、`bot.composer.attach`、`bot.composer.send`、`bot.composer.stop` |
| 附件 chip / 用户行附件卡片 | 胶囊上方横向 chip（图标 + 名 + 大小/类型 + ×），最多 10 个；用户行气泡内附件卡片（图标 + 名 + 大小/类型） | `bot.composer.attachment.<index>`、`bot.composer.attachment.notice`、`bot.message.attachment` |

「…」菜单内的记忆、例行任务、审批记录打开与 `BotInfoPage` 数据区相同的三个目标页面；菜单不新增页面或数据源。DSH 页只因共享胶囊抽取而改变源文件组织，外观、行为与既有 accessibility id（`chat.connect-device` 等）保持不变。
