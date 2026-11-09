<!-- SPDX-License-Identifier: MIT -->

# BotChatPage / Bot 卡片页面（target）

契约：P09、P27。上游：dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6` 的 `FEISHU-CARD-SYSTEM.md`、`CARD-UX-AUDIT.md`、`displayContract.js`、`cardPayloads.cjs`、卡片组件、Transcript、Composer、ActivityLine 和 FishDirector。目标实现路径：`examples/probe-app/PhoneDSHProbe/Bot/**`；当前不声明已有页面或运行时证据。

## 1. 页面与 session

- 首屏为单栏主 Bot 对话。顶栏采用 Grok 式：整屏水平居中的头像胶囊（32pt 实时大肥鱼 + 17pt semibold Bot 名 + 14pt 活动小图标），点按打开 `BotInfoPage`（id `bot.info.open`）；右侧是与 DSH 页共享的 92×44「连接设备 + …」胶囊（`bot.connect-device`、`bot.header.menu`），连接设备打开与 DSH 页相同的 `NativeDeviceConnectionPage`。左侧不放按钮（tab 根页面无返回）。Bot 设置入口只在「…」菜单内：菜单顶部是不可点的「跟进中 N · 需要你处理 M」说明行，下面是 Bot 信息与设置、记忆、例行任务、审批记录；「需要你处理」大于 0 时头像胶囊右上角显示 6pt 提示圆点。名字过长按尾部截断，不能与右侧胶囊重叠。
- 14pt 活动小图标固定在名字右侧、胶囊内部：thinking 或尚无正文的 streaming 显示三个依次起伏的点（1.2s 循环，透明度 .35→1→.35，相邻错开 .2s）；tool-running 显示铅笔（`pencil`，透明度 .72↔1，1.4s）；有待审批时显示红色「!」；空闲不显示。reduce motion 时静止在全不透明状态。图标不新增点击目标，整颗胶囊仍打开 Bot 信息。
- 大肥鱼头像是 dsh-bot 分层渲染器的 SwiftUI/Canvas 移植，由当前 Bot 的真实运行时事件驱动（`BotFishLifecycle` 全部状态，见 §4）；不是按状态切整张静态 PNG。素材授权已明确；使用 `public/assets/fish` 同构的 512×512 RGBA PNG/JSON，`bot/fish` 渲染器在 Swift 中执行模型、弹簧、表情 sprite 与装饰，不运行 JavaScript。主 Bot 的皇冠身份由真实 principal 决定，不能按名称伪造。
- 空状态在消息区可用高度内垂直、水平居中：96pt 实时大肥鱼（可戳）、标题「嗨，我是 {name}」15/22 semibold、正文 13/18 次要色居中，间距 12。id `bot.chat.empty`。
- 每个 Bot 只有一条连续主对话；无新建对话、对话列表、回滚和删除单条。向上滚动调用 `history(before:)`。
- 运行中 composer 可用，消息走 steering；用户消息优先于 Task 并发。停止就地取消当前回合，丢弃迟到输出。
- 后台 routine/Task 只投影卡片，不暴露过程 session。隐藏回合不显示用户行和模型散文。
- 有待审批时 composer 上方固定提示。长按消息提供复制、查看来源；桌面 hover 不搬到手机。
- 现有 DSH 多 session 工作台保持独立，不重构成 Bot 主对话。

## 2. 手机尺寸换算

结构、内容模型、空状态、超限处理和交互照 DSH Bot；视觉值只取 phoneDSH `tokens.json`，不复制桌面 CSS 色值或新增第二套 token。用户最新明确要求：所有消息卡片必须比此前紧凑，不能呈现为全宽大窗口。

| DSH Bot 桌面语义 | phoneDSH 手机规则 |
| --- | --- |
| 卡片宽 `min(100%,560px,100%-82px)` | 与同一 assistant 回复气泡共享唯一 `BotMessageColumn`。卡片宽度不得超过该回复气泡；使用同一左右 `geometry.cardOuterMarginH` 和最大宽度，不额外增加 16pt 外边距，不使用全屏/居中模态窗口 |
| 产出卡 r22 | `radius.bubble`（24） |
| 工作卡 r18 | `radius.listCard`（18） |
| 行内提示 r14 | `radius.card`（12） |
| 卡片内距 16、密集 14 | 工作卡使用 `geometry.cardPadding`（14）；question/steps 使用 12pt 紧凑内距；外边距只能来自共享回复列，不重复扣除 |
| 标题 15/500 | `typography.process` 同级的 15pt semibold，不使用更大的页面标题 |
| 正文 14/20 | `NativeParityTokens.bodySize`（14）及紧凑行高；主要回答正文仍用 `typography.body` |
| 密集/辅助 13、备注 12 | `typography.secondary` / `typography.caption` |
| 主、次、文字三按钮层级 | `colors.primaryButton` + `colors.primaryButtonInk`、`colors.sessionSelector` + `colors.sessionPrimary`、透明底 + `colors.sessionSecondary`；触控目标至少 44pt，主要操作按手机视觉动线置于上方 |
| 成功/进行中/警告/失败/失效 | `colors.sessionSuccess` / `colors.sessionAccent` / `colors.sessionWarning` / `colors.sessionDanger` / `colors.sessionTertiary`；每卡最多两个语义色 |
| 描边和表面 | `colors.sessionBorderL1/L2`、`colors.surface` / `colors.sessionSelector`；浅色和深色必须使用同一角色 |

桌面 32px 按钮、28px 密集行、40px 选项行在手机上统一提升到至少 44pt 的可点击区域；视觉图标可以更小，但命中区域不得缩小。question/steps 的选项视觉行高为 44 而非 52，行间 4，选项默认透明，不为每项再套一层厚底卡；recommended 才使用轻 tint、细边和推荐徽标。关闭图形可以紧凑，但命中区仍为 44。

所有卡片高度由实际内容决定，不设置大面积固定高度或用空白撑开。超过 4 个步骤/条目默认折叠，长文档在卡片内局部展开；预览是用户主动打开后的独立行为，不能在 transcript 中直接弹出大窗口。notice 使用行内紧凑提示，Task/routine、审批、progress、checklist、link、attachment、document 与 question/steps 都受同一回复列宽约束。

## 3. 卡片清单

P0 第一版必须实现：question、steps（含 recommended）、task、attachment、document、progress（cardKey 就地更新）、checklist、link、approval、automation routine 运行卡、error/denial notice。

P1 仅登记为 target：table、callout、info、payload、library。第一版不渲染、不注册工具、不进 persona。canvas、product、gift、Bot 间通讯行不实现。

question/steps 选项为整行可点并支持 recommended，提交时只使用宿主写入卡片的 `optionID`；**没有“其他”选项、卡内输入框或自定义答案提交控件**。仅 question 支持关闭：本地立即隐藏并写 durable `card.dismissed`，不产生模型可见回合，宿主在下一次用户回合开头以 held 项告知模型视为不回答；DSH 不可用时关闭仍本地生效。steps 不提供关闭按钮，`cardDismiss` 对 steps 返回 rejected。用户需要自由回答时直接在 composer 输入，作为普通 `chat` 消息，而不是 `cardAnswer.customText`。审批为拒绝/允许一次/总是允许三选项加 alwaysScope，拒绝使用中性文字按钮，禁止把否定语义染红。checklist 本地勾选和回传行为沿上游；link 仅打开 HTTP/HTTPS 且经系统安全外部打开策略。

所有卡片先验证 `body.type`、`cardType` 和必需数据。未登记或数据不足时不渲染，不用空白卡或猜测默认值补齐。

## 4. 最新基线的表现与接线

- Bot 色彩：用户气泡和推荐卡表面使用真实 Bot 色彩，但必须满足 phoneDSH 深浅色与对比度 token；不能把桌面任意色值直接用于正文或背景。推荐色不能掩盖文字层级或失败语义。
- 活动行：composer 上方、左对齐只保留一条运行指示（id `bot.activity.line`），左侧 20pt 实时大肥鱼，右侧 13/18 次要色单行省略文字，带从左到右的柔和高光。只在回合运行中且 `activity != nil` 时显示，回复正文开始流式输出后隐藏，回合结束隐藏；整行不拦截触摸。有工具详情时显示详情（模型写的 description/summary/label 截 80 字，否则「工具标签 · 目标」截 42 字），否则按 thinking / tool-running / streaming 每 2.4s 轮换文案，状态或详情变化时从第一句重新开始。文字变化使用 opacity 0→1、y 2→0、scale .985→1，0.22s `timingCurve(0.2,0.7,0.2,1)`；reduce motion 时无动画。状态来自当前 turn 的实时事件与 `BotRuntimePresentationFactory`/`BotFishDirector`，不另写映射，也不生成消息行。
- 输入区：Grok 式白色胶囊，最小高 52、圆角 26、细描边 + 浮动阴影，左侧内边距 16、右侧内边距 8；占位「向 {name} 提问」，多行增长上限约 5 行。右侧只有一个 36pt 圆形按钮，按状态切换但发送 id 不变：
  - 空闲且有文字 → 黑底白色 `arrow.up` 发送（id `bot.composer.send`）；空闲无文字 → 同一位置置灰禁用；
  - 运行中且输入为空 → 停止（id `bot.composer.stop`）；
  - 运行中且有文字 → 发送，文字并入当前回合（id `bot.composer.send`，accessibilityLabel「发送并 steering」）；不会排队。
  单行时按钮在胶囊内垂直居中（上下各 8pt），TextField 文本与按钮中心对齐；多行增长时按钮保持贴底且底部 8pt。多行 TextField 的回车只换行，不直接发送。**没有麦克风、语音模式或语音入口，也没有无实际功能的「+」附件按钮。** 审批横幅、runtimeNotice、steering 提示保持原功能并与胶囊样式协调。
- 简洁回复：persona 与 runtime context 必须保留最新简洁回复预算和明确 next-step 文案，不允许为了显示卡片强凑选项；卡片是否提供由 Agent 根据真实下一步价值决定。
- 头像状态：`turn_started → thinking`、`model.delta → speaking/thinking`、工具调用 → working、审批/Watchdog → alerting、成功 → celebrate、失败/拒绝 → sad、turn_end → idle 的优先级、one-shot TTL 和去重沿最新 FishDirector。待审批时 UI 覆盖为 alerting；空闲 60s 进入 sleeping，用户任何输入、发送或点按页面唤醒。状态只来自当前 Bot 的真实事件，不能由 UI 自报或虚构。
- 头像资产采用 `BotFish/` 的分层 PNG（body 为灰度，按 `#1680F3` LUT 着色）与 `expressive/{eyes,mouths}.png` 3×4 表情 sprite；36/60/120pt 使用同一 anchor。P0 生命周期所需 idle/thinking/streaming/working/sleeping/alerting/listening/speaking/happy/sad 必须有资源；其他状态按实际事件接入。设置页等静态位置使用 `still: true` 冻结在 650ms 姿态。

## 5. 验收

每种 P0 卡片在浅色和深色模拟器截图，逐项对照上游内容模型、空状态、超限、按钮层级和交互。覆盖窄屏、长标题、动态字体、44pt 命中区、卡片关闭/选择、重复点击、迟到结果和 progress 同 key 更新。另需覆盖真实鱼头像的 idle/working/alerting/celebrate/sad、活动行显隐和推荐色对比度。模拟器结果不得写成真机结果。

## 6. Grok 式改版结构与 id

| 区域 | 结构 | accessibility id |
| --- | --- | --- |
| 居中 Bot 胶囊 | 32pt `BotFishView` + 17pt semibold 名字 + 14pt 活动小图标（三点 / 铅笔 / 红色「!」；空闲隐藏），44pt 高白色 Capsule；右上 6pt 提示圆点 | `bot.info.open` |
| 右侧共享胶囊 | 与 DSH 页同一 `HeaderActionPill`：连接设备（在线 6pt 圆点）+「…」菜单 | `bot.connect-device`、`bot.header.menu` |
| 空状态 | 96pt 动态大肥鱼，标题 15/22 semibold，正文 13/18，间距 12，可用高度居中 | `bot.chat.empty` |
| 工作状态行 | 20pt 动态大肥鱼 + 13/18 单行文字 + shimmer，输入框上方左对齐 | `bot.activity.line` |
| 输入胶囊 | 最小高 52、r26、白色、细描边、浮动阴影；左 16 / 右 8；单按钮三态（空闲发送·置灰 / 运行中空输入停止 / 运行中带文字发送并入当前回合），单行居中、多行贴底 8pt | `bot.composer.input`、`bot.composer.send`、`bot.composer.stop` |

「…」菜单内的记忆、例行任务、审批记录打开与 `BotInfoPage` 数据区相同的三个目标页面；菜单不新增页面或数据源。DSH 页只因共享胶囊抽取而改变源文件组织，外观、行为与既有 accessibility id（`chat.connect-device` 等）保持不变。
