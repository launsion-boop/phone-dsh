<!-- SPDX-License-Identifier: MIT -->

# phoneDSH Bot device ingress v1 契约冻结

```yaml
change: PC-20261106-bot-device-ingress
contracts: [P07, P19, P23, P24, P25]
status: frozen
base: 3264365aecc181d1187c6b4dc5cacf22fdbcb576
contract_revision: PC-20261106-bot-device-ingress@2
version_decision: P07 DeviceEnvelope v1 增加可选 epoch（@2）；Bot held-inbox 增加 device-event、deviceEpoch 和 scoped ID；@2 的缺口/去重/回复/对账细则以 PC-20261106-bot-device-event-envelope@2 为准；同 App bundle 配对升级。
```

Protocol impact: P07; P19; P23; P24; P25。

## 1. 统一架构与身份

- 主 Personal Agent 仍只有一条连续主对话。设备消息带消息来源并回到对应设备；不会为每个设备创建一条 Personal Agent 主 session。用户在 DSH 工作台主动管理设备时，继续使用现有 DSH 多 session 管理路径，不改成 Bot 对话。
- `DeviceSessionCoordinator` 的 `deviceID → sessionID` 持久映射只用于既有设备传输。不得为了 Bot 再调用 `install` 替换全局 connector，也不得让 Bot 创建私有扫描、权限或 bridge 实例。Bot 与 DSH 注入同一个全局 connector、PhoneToolBridge 和 mapping store。
- 只有可重放的 P07 `DeviceEnvelope` 能触发唤醒。原始蓝牙扫描结果和 Bonjour service name 只能用于只读发现，不能冒充稳定配对身份或触发 Bot 动作。扫描的 `CBPeripheral.identifier` 和 mDNS 名称都不是授权身份。
- 输入必须使用 `device_id`、`msg_id`、`epoch`（缺省 0、非降序）与 `(device, dir, epoch)` 内单调的 `seq`。`session_id` 仍由宿主现有映射决定，不能采信设备自报。蓝牙和 LAN 的现有 `bluetooth.scan`、`network.browse` 与 P19 envelope 不变，执行仍经 Gateway principal、宿主重新推导 effects、执行点再授权和全局 PhoneCapabilityGate；不得增加私有 read/auto 旁路。

## 2. Durable event 映射

每个有效上行 envelope 先写同一个 `SQLiteDomainStore`，再允许唤醒：

- `BotEvent.type = "device.event"`，`eventId/traceId/correlationId = "dev:" + device_id + ":" + epoch + ":" + msg_id`；`data.receivedAt` 是宿主接收时间。
- `origin = .local(source: "device:<transport>:<device_id>")`；`principal = {botId: 当前主 Bot, sessionId: 当前主 Bot 连续主 session, kind: "device"}`。该 session 与设备传输的既有映射是两种身份，不得混用。
- `time = ts_ms`（缺失时由宿主接收时间决定）；`data` 保留完整 envelope 和 `transport`。device/transport/text 都是不可信输入，不能使用 `SAND_TRUSTED_AUTOMATION_PROMPT`，不能把设备文本当成用户授权或系统指令。
- 去重键是 `(device_id, epoch, msg_id)`；同一键内容完全一致是 duplicate，不能重复唤醒；不同内容或同设备同 `(epoch, seq)` 不同 msg 是 conflict，拒绝并不产生新副作用。按每 `(device, epoch)` 的 delivered waterline 连续交付；缺口等待超过 30 s 或乱序缓存超过 32 条时跳过并写 `ui.notice`（`data.kind=device.gap`），之后继续。进程重开从 durable event 和 WakeInbox `deviceCursors` 重建，不重放已入队历史，重复 committed seq 先到者胜、不阻塞整个 ingress。
- 先有持久接受，才有模型可见投递。发送结果未知、Writer 不可用或 commit 前崩溃都保持 pending/staged，以同一个 `"dev:" + msg_id` 重试并对账，不能换 ID 盲发。

## 3. held inbox 与唤醒

`held-inbox-item.schema.json` 新增 `kind = "device-event"`，并新增可选 `deviceID`、`transport`、`deviceSeq`。这些字段登记在此，不允许另起 snake_case/camelCase 别名。

- `id/requestId = "dev:" + deviceID + ":" + epoch + ":" + msg_id`；`threadId = "device:<deviceID>"`；`fromAgentId = deviceID`；`fromAgentName` 为经校验的设备显示名；`text` 为上行文本，沿用 1200 字上限；设备项条件必填 `deviceID/transport/deviceSeq`，并带 `deviceEpoch`。
- `WakeSignal.reason = "device:<msg_id>"`，不增加 WakeSignal 字段。`HeldMessages.block` 用 `[device]` 明示来源和不可信边界，不渲染成 user-turn 或队友授权。
- held 使用现有 enqueue → stage → commit/revert/recover 和 SQLite 快照原子性。WebContent 不可用时保持 pending/staged，恢复后按每设备 `seq` 补一次。DSH 接受后、commit 前崩溃仍由同一个 requestID 去重。
- 个人 Agent 对设备动作产生的效果继续使用现有 `BotEffect`/outbox/inbox，不把 ingress 和 egress 混成同一个 exactly-once 承诺。来源回复只通过 p0 `ReplyToDevice`（仅 `message`；宿主解析本回合 staged 来源，不能指定设备），效果 `device.reply`/external-send/ask 绑定来源设备与映射 session；下行 `seq` 由持久化出站游标分配，effectKey 持久去重；writer 返回 nil 是 unknown，transient 与 unknown 分开，重连时按 `BotDeviceReceiptQuerying` 对账并给用户可见提示。个人主 Chat 不改变设备传输 session。

## 4. 兼容与回滚

- 旧 producer → 新 consumer：现有 held/agent/routine/subagent 数据与 P07/P19 不变。
- 新 producer → 旧 consumer：不支持。旧 App 可能不识别 `device-event`，不能把未知 kind 当普通 agent 文本或系统指令；不得混部新旧 Worker/宿主。
- 旧持久数据升级不需要改表；沿用 SQLite v2。回滚到不识别 device-event 的 App 前必须停止使用设备 ingress，不宣称未知 kind 可安全展示。
- P07 envelope 的 `v=1`、字段和信任语义不变；P19 工具名/参数/envelope 不变；P25 Row/UserAction 不变。

## 5. 分工与验收

- `Sources/PhoneDSHBot/Providers/**`：传输无关的 envelope 校验、去重、乱序恢复、来源/效果状态和测试。
- `examples/probe-app/ProbeKit/Bot/Providers/**`：绑定全局 connector、PhoneToolBridge、映射、权限和真实执行。
- `Tests/PhoneDSHBotTests/Providers/**`：真实 SQLite 与可控假传输/执行器；不得用纯内存快照替代恢复证据。
- 统一 composition 持有并注入共享实例；不修改 Package.swift、P01/P15 wire 或既有 DSH session 管理代码。

必须覆盖：两个现有工具的授权与拒绝；未归属/standing deny/once 不执行；重复 msg_id、冲突 payload、乱序 seq；断连重连与进程重开；持久化后唤醒前崩溃、接受后 commit 前崩溃、stage 后重开；WebContent 不可用排队恢复；同一 connector/bridge 被 Bot 与 DSH 共用。真机蓝牙/LAN 权限和断连重连仍是单独验收，不能用模拟器或静态检查代替。

## 6. PR #60 集成修訂：event_id 唯一約束

- 設備訊息沒有獨立表：持久化只寫通用 `bot_events`，`eventId = traceId = correlationId = "dev:<device>:<epoch>:<msg>"`。schema 的 `bot_events.event_id TEXT NOT NULL UNIQUE` 已是數據庫級去重權威，因此不需要新增 `(bot_id, device_id, epoch, msg_id)` 列或 migration；SQLite v2 不變。
- ingress 的內存 accepted/seq/watermark 仍是遞交順序的快速路徑；當另一個 ingress 實例（App 重開、第二條 transport）先提交同一 event_id 時，`store.append` 的 UNIQUE 衝突被視為 first-writer-wins：重新讀取已提交 event，校驗 envelope/transport 完全一致後回 `duplicate`，不產生第二行、不重複投遞。內容或 transport 不一致仍是 conflict。
- 回歸：`BotDeviceProviderHardeningTests.testDeviceEventIDIsTheScopedDurableKeyAndIsStoreUnique`（格式、UNIQUE、重開舊資料）與 `testSecondIngressInstanceLosesTheUniqueInsertAndReportsDuplicate`。
