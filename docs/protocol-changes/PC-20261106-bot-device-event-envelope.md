<!-- SPDX-License-Identifier: MIT -->

# CCR：phoneDSH Bot 设备事件编码与执行点授权

```yaml
change: PC-20261106-bot-device-event-envelope
contracts: [P07, P23, P24]
status: frozen
breaking: true
base: 9b3b31e7291695530765c7d61a32753d902748f9
contract_revision: PC-20261106-bot-device-ingress@2 + PC-20261106-bot-device-event-envelope@2
version_decision: P07 DeviceEnvelope 仍为 v=1，新增可选 epoch（缺省 0）；BotEvent 仍为 schemaVersion=1，不新增事件类型；held-inbox-item 设备分支条件必填；同 App bundle 配对升级，不混部新旧 Worker/宿主。
```

Protocol impact: P07; P23; P24。

## CONTRACT CHANGE REQUEST（@1，保留历史）

- Contract: P23/P24 @ `2126266a38921b295f9405773aed215e3766fdbb`
- Clause: `PC-20261106-bot-device-ingress.md` §2；`event-envelope.schema.json`。
- Problem: 已冻结的 `device.event` 要求 `principal.kind=device` 和 `origin.source=device:<transport>:<device_id>`，但事件 schema 和真实 Swift codec 只接受原有枚举。`device.reply.staged` 也未登记，真实 append 在唤醒前失败。
- Proposal: 增加 `device.event`、`device.reply.staged`、`device` kind；local origin 新增严格匹配的 `device:(bluetooth|lan):<P07 device_id>` 形式，不接受任意来源字符串。附正向 device event 与反向未知 transport golden。
- Affects: Swift BotEvent producer/consumer、SQLite replay、Python schema validator。旧 reader 不支持新 kind，不混部；旧数据不需要迁移。

## 修订 @2（PR #60 修复）

### 2.1 P07 epoch 与 seq 域

- `DeviceEnvelope.v` 仍为 `1`，新增可选 `epoch`（非负整数，缺省 `0`）。语义：同一设备的 session incarnation。设备每次重启/序号回绕必须递增 epoch；同一 epoch 内 `seq` 按方向单调，epoch 变化时接收端重置 expected watermark。
- `seq`/`epoch` 上限 `2^63-2`；`seq=Int64.max` 在 schema 和 Swift 校验中拒绝，接收端递增用溢出安全运算。设备发送更低 epoch 视为过期（`sequence` 错误）。
- 旧 producer → 新 consumer：缺少 `epoch` 解码为 `0`，可继续工作。新 producer → 旧 consumer：旧 decoder 会拒绝未知 `epoch`，因此只允许同 App bundle 配对升级，不混部；设备 ingress 尚未随版本发布，无旧持久数据迁移。
- 落地：`spec/host/v1/schema/device-envelope.schema.json`、`spec/host/v1/golden/device-envelope-{uplink-voice,downlink-text}.json`、`spec/host/v1/README.md` §2.1。

### 2.2 去重、唯一 seq 与事件身份

- 去重键改为 `(device_id, epoch, msg_id)`；同一 `(device_id, epoch, seq)` 只允许一个 msg，冲突拒绝。`device.event` 的 `eventId/traceId/correlationId` 和 held 的 `id/requestId` 为 `dev:<device_id>:<epoch>:<msg_id>`；同设备同 seq 冲突在重开时按 commitSeq 先到者胜，不让整个 ingress 失败。
- `device.event.data.receivedAt` 记录宿主接收时间（毫秒），不信任设备 `ts_ms` 来判定缺口等待。`spec/bot/v1/golden/event-envelope.json` 与 held-inbox golden 已更新；held 新增可选 `deviceEpoch`，设备分支条件必填 `deviceID/transport/deviceSeq`（`spec/bot/v1/held-inbox-item.schema.json`）。

### 2.3 连续交付与可见缺口

- 交付水位为每 `(device_id, epoch)` 的 delivered seq，保存在同一 bot 的 WakeInbox 快照（`deviceCursors`）中；接受后只把 `seq == watermark+1`（或首个缓冲 seq）的连续消息入 held，重开不重放已入队历史。
- 缺口等待超过 30 s 或同 epoch 乱序缓存超过 32 条时跳过缺口：先写 durable `ui.notice`（`data.kind=device.gap`，含 deviceID/epoch/fromSeq/toSeq/reason/text），把水位推进到下一可用 seq-1，再继续交付。低于已推进水位的迟到消息按过期拒绝。
- 落地：`Sources/PhoneDSHBot/Providers/BotDeviceIngress.swift`、`BotDeviceEnvelope.swift`、`Sources/PhoneDSHBot/Wake/WakeInbox.swift`。

### 2.4 回复来源设备（P24 工具面扩展）

- 新增 p0 工具 `ReplyToDevice`，参数只有 `message`（1…1000），模型不能指定 device/transport/session。宿主只从本回合 staged 的 `device-event` held 项解析来源；一次 stage 只含一个设备（`WakeInbox.stage` 设备分支），多设备或来源事件缺失/不一致时 fail-closed。
- 执行点效果为 `tool=ReplyToDevice, operation=device.reply, resource=device:<transport>:<device_id>, target=<映射的传输 session>, mutability=external-send, policy=ask`。stage 校验：来源 `device.event` 与 transport/session/deviceID/epoch 一致，授权 decision 的 bot/session 与来源事件一致且 effect 的 resource/target 完全匹配；不满足即 `unauthorized`。
- 下行 `seq` 由宿主持久化出站游标分配（从 `device.reply.staged` 恢复，取每 `(device,transport)` 最大值+1），msg_id 由 `(device,epoch,来源 msg_id)` 派生；重开用同一 effectKey 重试，不换 ID 盲发。`writer.send` 返回 nil 视为 unknown outcome，不是成功。
- 工具 schema 与效果向量：`spec/bot/v1/tool-catalog.schema.json`、`golden/tool-catalog.json`、`golden/tool-effects.json`、`spec/bot/v1/README.md` §2。

### 2.5 未知结果对账

- `needs_reconciliation` 的 device-reply effect 在设备重连/绑定 attach 时经 `BotDeviceReceiptQuerying` 对账：能确认 applied → `ackReconciled`；明确未应用 → `retryNeedsReconciliation`；无法确认或查询失败 → 保持 `needs_reconciliation` 并写一条去重的 `ui.notice` 用户可见提示行。
- transient（确认断连、未发送）与 unknown（可能已发送）分开：transient 记 `errorClass=transient` 可重试；unknown 进入 `needs_reconciliation`。落地：`BotDeviceReplyService.swift`、`examples/probe-app/ProbeKit/Bot/Providers/BotDeviceProviderBinding.swift`；组合根需在设备重连和 Host 重建后调用 `reconcileOnReconnect()`（接口见该文件）。

### 2.6 held 注入防护

- `HeldMessages.block` 对设备正文、deviceID、transport 等做单行转义（换行/控制字符/`<`/`>`/`&` 编码），设备无法伪造 `</held_agent_messages>` 或额外行。`held-inbox-item.schema.json` 对 `device-event` 条件必填 Swift 端要求的三个字段。

## 兼容与回滚

- 旧 producer → 新 consumer：无 epoch 的 P07 envelope 按 epoch 0 处理；旧 device.event（若有）按 envelope 身份去重，不迁移表结构。
- 新 producer → 旧 consumer：不支持 epoch/Scoped ID/ReplyToDevice/新 held 必填；必须同 bundle 升级。`device-event` 本身 @1 已声明不混部。
- WakeInbox 快照新增可选 `deviceCursors`，旧 reader 忽略未知成员；回滚前停止设备 ingress，避免新 ID/游标被旧版本误读。
- @2 之前的 device ingress 数据没有 delivered 游标（且使用未 scoped 的 `dev:<msg>` ID）。设备 ingress 尚未随发布版本交付，不承诺迁移：升级后的首次同步会把仍保留的旧 accepted event 视为待交付并重新入队；测试库如跨 @2 保留设备数据，应先停止 ingress 并清空/重建该 Bot 的 device-event 与 held 数据。生产回滚同理。
- P07 `v=1`、P19 envelope、P25 Row/UserAction 不变；未新增 BotEvent 类型。

## 验收

- `swift test --filter BotDeviceProviderTests`、`swift test --filter PhoneDSHBotTests`：真实 SQLite/decoder/stage 状态机、epoch/缺口/去重/崩溃恢复/回复/对账/转义。
- `python3 spec/bot/v1/tools/validate_vectors.py`：正向与反向 schema/golden。
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`：契约及登记。

真机蓝牙/LAN、系统权限与端到端回执未实现/未运行，不能由这些检查推断通过。

## 修訂（PR #60 集成）

- `ReplyToDevice` 不再繞過通用分類器。`BotToolEffectClassifier` 以 `golden/tool-effects.json` 的 `hostExtensions` 形狀（`operation=device.reply`、`resource=device:*`、`target=*`、`external-send`、`ask`、`execution=device-reply`、`known=true`）登記它；`execute` 先解析本回合 staged 來源，再用 `BotDeviceReplyTool.requiredEffect` 的具體 `device:<transport>:<device_id>`／映射 session 走 classify → 授權 → 執行。工具只消費這次已授權的 decision，不重複授權；`requiredEffect` 帶 `execution=device-reply`，使 `.once` grant 延後到執行點只消費一次。模型仍不能命名目的設備；來源缺失、多設備、session 不匹配與未知工具都 fail-closed。
- 回歸：`BotGoldenVectorTests.testReplyToDeviceHostExtensionMatchesSharedGolden` 與 `BotDeviceProviderHardeningTests.testReplyToDeviceIsClassifiedAndConsumesTheOnceGrantOnce`。
