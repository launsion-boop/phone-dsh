<!-- SPDX-License-Identifier: MIT -->

# PC-20261116-bot-message-admission — Bot 用户消息持续接纳与官方 steer

## 0. 摘要（機器可讀）

```yaml
change: PC-20261116-bot-message-admission
contracts: [P26]
status: frozen
breaking: false
version_decision: no wire/schema/row change. The delta is Bot admission behaviour; it reuses the official DSH session/prompt mode=steer and the existing user-action/row shapes. No new row kind, field, route or env var.
base: 908d582b9ee91886ba197bebd54b863c8093cced
contract_revision: spec/bot/v2/message-admission.md @ aha/integration-20261116 freeze commit (SHA in CONTRACT-FREEZE.md)
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** 用户要求：Bot 忙时输入/发送始终可用、消息立即显示并可靠接收；
  补充/纠正通过官方 DSH steer 进入当前工作，不要求用户选择排队/插队/等待；空闲时正常开回合；
  内部串行调度不暴露为队列 UI；不丢/不重复、不无条件取消有副作用工作、不伪造已理解。
  现况（基线源码）：`BotChatModel.send` 已立即本地回显并可「发送并 steering」；
  `BotDSHRemoteRuntime.runTurn` 在 `canSteer` 为真时用 `session/prompt mode:"steer"`，
  否则走 `queuedTurns` 等前序结算后**新开回合**；`canSteer` 要求 `promptAccepted` 且
  `queuedTurns[sessionId] == nil`。因此仍有两个用户可感知的缺口：
  (a) 回合已打开但尚未 accepted 的窗口里，消息会被排成下一回合而不是 steer；
  (b) 一旦有一条消息排进 `queuedTurns`，后续纠正也全部排队，当前回合收不到。
- **Coordinator / contract owner：** C。**Implementer：** R（`BotDSHRemoteRuntime.swift`、
  `Sources/PhoneDSHBot/Rows/**` 的 action dispatcher、`examples/probe-app/PhoneDSHProbe/Bot/**`
  的 Bot 会话页/模型、对应 tests）。`BotMCPRuntime.swift` 仍归 M，R 不改；若实现必须改它，
  R 给 C 最小 diff 请求，由 C 调 M 落地。**Reviewer：** Q。
- **Owning spec：** 新 `spec/bot/v2/message-admission.md`（P26 的 Bot runtime 行为；
  不改变 P27 的 `row`/`user-action` wire 形状，也不改 DSH 官方 `session/prompt`/`session/cancel` 语义）。
- **受影響 producer／consumer：** iOS Bot 页面/模型（发送、停止、状态行）与 Bot 宿主 runtime；
  DSH 官方 Worker 只收到既有 `mode:"steer"` prompt，不改 DSH 源码/pin。

## 2. 契約 delta

| 項目 | Before → After／依據 |
| --- | --- |
| 忙时发送 | UI 已可用，但 runtime 在 `promptAccepted == false` 或已有 `queuedTurns` 时把消息排成“下一回合” → 必须进入**待投递缓冲**，在该回合 accepted 后按序 steer；见 message-admission §2 |
| 纠正进入当前回合 | 只有 `canSteer` 为真才 steer；一旦有一条排队就全部排队 → 同一会话的待投递用户消息都必须 steer 进当前 chat 回合（同一会话、同一回合），除非回合结束/被停止/传输替换 |
| 队列表述 | 内部 `queuedTurns` 串行调度存在但不暴露 → 明确不为用户提供排队/插队/等待选项，不显示队列位置/数量；内部缓冲有界（16）且超限显式失败 |
| 忙→闲边界 | 回合结束瞬间到达的消息可能被当作下一回合 → 允许但必须不丢失、保持顺序、只投递一次 |
| 重连/传输替换 | `fenceSupersededTurnState` 丢弃旧 generation 的排队状态 → 未确认的用户消息必须用同一 requestId 重试；已确认的不重发；不得产生重复回合 |
| 停止 | `stop()` 取消当前回合 → 明确只取消当前回合；已显示消息保留；待投递消息不被静默吞掉 |
| 审批/工具 | 无明文 → steer 不取消等待中的审批或进行中的工具；只有显式 stop 取消 |
| UI | 发送/停止按钮已有三态 → 忙碌时 composer 保持可用；空文本+运行中才是停止；不新增队列 UI；失败消息保留可重试；可见文案/可及性标签不得出现 steer/排队/插队术语 |
| 审批 | `BotChatModel.send` 每次发送会自动 deny 全部 pending approvals（约 632–655）→ 普通文本发送**不得**自动拒绝等待中的审批；审批只由显式选择/显式停止/既有超时路径改变 |
| 不伪造理解 | 无明文 → 投递失败/未接收必须可观察，不得显示成已理解/已完成 |

**自檢（spec/README.md §5.1）：** 没有新增 wire 字段/行种类/路由/环境变量；复用官方 DSH steer；
消息 requestId 仍是既有幂等键；没有收紧既有合法输入；没有删除或重用名称；不新增第二套队列协议。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式 |
| --- | --- |
| 旧 App → 新 runtime | 旧 UI 仍按“发送后等回合”工作；runtime 的新缓冲只在收到同一会话的多条消息时生效，旧路径不受影响 |
| 新 App → 旧 runtime | 新 UI 不依赖新接口（仍是 `sendUserMessage` + 既有 action）；若 runtime 未升级，行为退回基线的排队语义，UI 不崩 |
| 新 → 新 | 按 message-admission §2 的接纳表 |
| 持久化/回滚 | 不新增持久格式；待投递缓冲是运行时状态，传输替换按 requestId 重试；回滚不要求迁移 |

- **版本决定：** 不升 schema/row 版本；无 DSH wire 变化。
- **发布边界：** 只 iOS；Android/HarmonyOS 不改、不声称对齐。不改 DSH 官方源码/pin/官方页面。

## 4. 分工與證據

### 4.1 獨占路徑

- R：`Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`、`Sources/PhoneDSHBot/Rows/**`（dispatch 相关）、
  `examples/probe-app/PhoneDSHProbe/Bot/{BotChatModel,BotChatPage,BotLiveTurn,...}.swift`（Bot 会话页）、
  `Tests/PhoneDSHBotTests/MCP/**`、`Tests/PhoneDSHBotTests/Rows/**`、`examples/probe-app` 的 Bot 测试。
- **不写**：`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift`（M）、`spec/**`（C）、
  `scripts/ci/bot-e2e/**`／`scripts/evals/**`（E）、Android/HarmonyOS、DSH 源码/pin。

### 4.2 驗收命令

- `swift test --filter 'BotDSHRemoteRuntimeTests|BotChatModelTests|BotUserAction'`（新增用例必须真实
  驱动 runtime/dispatcher/chat model）。
- 既有回归：`swift test --filter 'BotRuntimeMultiplexingTests'`、`python3 spec/bot/v2/tools/validate_vectors.py`。
- 真实模型/真机/弱网：只有实际运行才记 PASS，否则 NOT_RUN。

必须覆盖 message-admission §4 的 9 类场景（含“发送不自动 deny 审批”和“真实模型请求证明纠正被消费”）；不得用关闭 composer、加队列 UI、把 steer 降级成新回合、
放宽审批/取消断言来“通过”。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| r1 | C | 用户新增验收：Bot 持续接纳 + 官方 steer + 无队列 UI；基线 `canSteer/queuedTurns` 存在两个可感知缺口 | R、E、Q |
