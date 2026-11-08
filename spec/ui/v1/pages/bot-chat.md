<!-- SPDX-License-Identifier: MIT -->

# BotChatPage / Bot 卡片页面（target）

契约：P09、P27。上游：dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6` 的 `FEISHU-CARD-SYSTEM.md`、`CARD-UX-AUDIT.md`、`displayContract.js`、`cardPayloads.cjs`、卡片组件、Transcript、Composer、ActivityLine 和 FishDirector。目标实现路径：`examples/probe-app/PhoneDSHProbe/Bot/**`；当前不声明已有页面或运行时证据。

## 1. 页面与 session

- 首屏为单栏主 Bot 对话。顶栏使用 DSH Bot 的真实大肥鱼头像资产、runtime-context 注入的 Bot 名（默认“大肥鱼”）和状态胶囊“跟进中 N · 需要你处理 M”。素材授权已明确；使用 `public/assets/fish` 的 512×512 RGBA PNG/JSON，FishDirector 的纯状态机在 Swift 中按共享事件实现，不运行 JavaScript/Canvas。主 Bot 的皇冠身份由真实 principal 决定，不能按名称伪造。
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
- 活动行：composer 上方保留一条无头像的活动行，只在实际运行状态展示。状态来自当前 turn 的最新工具/流式事件，不生成消息行；流式正文出现时隐藏。按 `ActivityLine`/`liveActivity.js` 的状态和工具摘要规则实现，并处理取消与迟到结果。
- 简洁回复：persona 与 runtime context 必须保留最新简洁回复预算和明确 next-step 文案，不允许为了显示卡片强凑选项；卡片是否提供由 Agent 根据真实下一步价值决定。
- 头像状态：`turn_started → thinking`、`model.delta → speaking/thinking`、工具调用 → working、审批/Watchdog → alerting、成功 → celebrate、失败/拒绝 → sad、turn_end → idle 的优先级、one-shot TTL 和去重沿最新 FishDirector。状态只来自当前 Bot 的真实事件，不能由 UI 自报或虚构。
- 头像资产采用真实 `expressions/*.png` 与 `manifest.json`，36/60/120pt 使用同一 anchor；深浅色不套用错误色相。P0 生命周期所需 idle/thinking/streaming/working/sleeping/alerting/listening/speaking/happy/sad 必须有资源；其他状态按实际事件接入。

## 5. 验收

每种 P0 卡片在浅色和深色模拟器截图，逐项对照上游内容模型、空状态、超限、按钮层级和交互。覆盖窄屏、长标题、动态字体、44pt 命中区、卡片关闭/选择、重复点击、迟到结果和 progress 同 key 更新。另需覆盖真实鱼头像的 idle/working/alerting/celebrate/sad、活动行显隐和推荐色对比度。模拟器结果不得写成真机结果。
