<!-- SPDX-License-Identifier: MIT -->

# phoneDSH Bot v2 契约（记忆、唤醒标记、主动提醒）

状态：`target`。本目录冻结 P26 中由 phoneDSH 主导的三部分：记忆、唤醒标记和主动提醒。
静态 schema/golden 通过不等于 Swift、Worker、模型或真机已经实现。

**权威。** 从 2026-11-10 起，记忆、唤醒标记、主动提醒三部分以本目录为唯一权威，由 phoneDSH
维护，不再跟随 dsh-bot 钉版。移交时 schema 与 golden 逐字节复制自 `spec/bot/v1`（v1 的
上游导出为 dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`）；线格式、字段、默认值和
行为都不变。`spec/tools/bot/export-vectors.mjs` 不再导出或覆盖本目录的任何文件。

其余 Bot 契约仍在 `spec/bot/v1`，仍跟随 dsh-bot 钉版：事件信封、工具面、卡片、行、
回合来源（[v1/README.md §4.1](../v1/README.md#41-回合来源turn-origin)）和 MCP 端点。
Android 与 HarmonyOS 没有 Bot runtime，本目录对它们没有实现端。

本目录没有 `dshbot-pin.json`，也没有 `export-manifest.json`：那两份文件只约束 v1 的原样
上游导出。变更本目录必须按 [AGENTS.md](../../../AGENTS.md) §3 走变更单，并从
[P26](../../README.md) 的登记表/触发表触发；不得把“手机主导”解释成可以放宽未知字段、
版本或失败路径。

## 1. 记忆

facts 是 SQLite 唯一权威。写入归一为单行；注入块逐字对齐；召回使用 CJK 分词、BM25、时近度和重要度；非 `user-turn` 不得写 `scope:user` 或 `profile`，来源只降級；forget/erase 与上游一致。

第一版不实现自动抽取、MemoryPolicy 决策、L2 反思和衰減。facts 中对应字段保留供以后启用；MemoryPolicy 决策契约已按 PC-20261111-bot-v2-unwired 删除，不再保留 schema 或向量。

## 2. 唤醒标记

routine、cron、run-attempt、安静时段、silent/held/interrupt、held inbox、隐藏唤醒和 `<automation_status>` 与上游一致。安静时段延后而不是丢弃；urgent 必须有理由；WebContent 不可用时常驻宿主排队，恢复后依次运行且错过的只补一次。

`HeldMessages.block` 的 `[agent]` 分支对 `fromAgentName`、`fromAgentId`、`title`、`text` 与 `msg id` 全部经 `escapedHeldField` 转义；agent-held 的回复仍是 held 数据与队友内容，不是用户授权，不能触发未经用户要求的动作。

设备任务终态另有一条只读 held 通知：`device-task-result` 只告诉 Bot 哪台设备、任务目标摘要和最终结果，不授予工具，也不提供把回复发回设备的路径。它来自 [device task-delegation](../../device/v1/task-delegation.md) 的终态记录，在 journal 落盘后、向设备回报前入队。

投递语义是 **write-before-enqueue + replay with dedupe**：宿主先把该终态写成一条 durable `comm.inbound` 事件（event id 与 held item id 都由设备 ID＋idempotency key 的 SHA-256 决定），成功入队后再写一条 `comm.reply` 确认事件。Bot 进程启动时重放没有确认事件的终态记录，重新调用 `WakeInbox.enqueue`；inbox 以 `requestId` 去重，所以“事件已写、入队前崩溃”会在下次启动补投，“已入队、确认事件前崩溃”只会生成同一 item 的 duplicate，不产生第二条。确认事件写完后，即使 held item 已被 commit 消费，也不再补投；这保持“同一终态至多交付一次给主对话”的效果，同时消除落盘与入队之间的永久丢失窗口。journal 自身仍不用于回放。`held-inbox-item.schema.json` 的该分支与 `golden/held-inbox.phone.json` 的 `deviceTaskResult` 是 phoneDSH 增量：上游 `held-inbox.json` 保持原样导出，例子放在覆盖文件，由合并加载器交付给真实 inbox codec。

### 2.1 宿主拼入文本的转义

宿主拼进 prompt 的任何非宿主文本一律按既有的 `HeldMessages.escapedHeldField` 规则转义后再放入：`\` → `\\`，换行／回车／制表 → `\n`／`\r`／`\t`，`<`／`>`／`&` → `\u003c`／`\u003e`／`\u0026`，U+2028／U+2029 和其他控制／格式字符 → `\uXXXX`。外部文本不得闭合 `</held_agent_messages>`、伪造 `- [agent]` 行或让 held 块变成多行。适用位置：

- `HeldMessages.block` 的 `[routine]` 分支：routine 名称（`title`）与正文；
- `[subagent]` 分支：task id、status 与结果正文；
- `[card-dismissed]` 分支：标题与正文；
- `[device-task]` 分支：设备／标题、task id、status 与正文；
- `[agent]` 分支：发送方名字、id、title、正文与 msg id（当前已转义，保持）；
- 子代理唤醒 prompt：`task-settled` 的标题、状态、task id 与最多 1,200 字结果摘录；`task-interrupted` 的标题与 task id；
- 以后新增的宿主结构化块／前缀默认同样转义。

普通用户消息正文和其他 Bot 的即时消息正文是消息内容，不是宿主拼进结构化框架的字段，不按本规则改写。该规则只约束宿主插入的 held 块、隐藏唤醒 prompt 和同类结构字段。回合是否隐藏、是否带 held 块、记忆写入算谁说的，仍由 [v1 §4.1](../v1/README.md#41-回合来源turn-origin) 的 `source.rpcId` 前缀决定；本目录不复制那张表。

## 3. 主动提醒

主动提醒只用于 interrupt。保留的规则链只由三道硬限制和通知投递接口组成：

1. **投递对象。** 只有 `delivery == interrupt`、非 quiet、成功的 routine 结果（或失败终态）
   可以进入通知；held 结果只进 held inbox，不通知。
2. **勿扰（DND）。** `ProactiveSettings.dnd == true` 时拒绝所有候选；显式 reminder
   （`reminderId` 非空且 `allowDuringDnd == true`）是唯一例外。
3. **安静时段。** 落在 `quietStart`–`quietEnd` 的候选拒绝；显式 reminder 例外同上。routine
   调度器的安静时段延后（§2）仍在调度层生效，不因通知被拒绝而丢弃运行。
4. **频率保险丝。** 同一 Bot 在一个 `fuseWindowMs`（默认 900,000 ms）窗口内最多
   `fuseMaxWakeups`（默认 4）次 `did`/`would` 决策；达到上限后新的候选记 `fuse` 并跳过。
5. **通知投递接口。** `ProactiveDelivering` 接收 `ProactiveNotification` 并返回
   `ProactiveDeliveryResult`。`dedupeKey` 是通知的稳定标识（用于替换同一通知），不是抑制窗口；
   iOS 深链为 `phonedsh://bot/<botID>/row/<rowID>`。推送中继不在本轮，只保留
   WakeSignalSource 接口。

模式：`off` 只记 `mode-off`，不投递；`would` 记录 `would` 决策但不投递；`on` 对
`deliveryKinds` 内的类别投递，投递失败记 `delivery-failed` 且不消耗保险丝。生产 Bot 装配使用
`on`，并把 `routine-result` 接到 `RoutineScheduler` 的 interrupt 结果；`delivery == held` 的结果
仍只进 held inbox，不进入这条链。

### 3.1 预定本地通知（routine 到期）

iOS 的后台执行不是常驻能力。为了让 App 被挂起或杀掉时仍能告诉用户 routine 到期，宿主在 routine
建立或改期后把**下一次到期**登记为一条 `UNUserNotificationCenter` 本地通知；这条路径不依赖进程存活。

- **内容。** 标题固定 `例行任务到期`，正文 `「<routine title>」到点，点开运行。`，深链
  `phonedsh://bot/<botID>/routine/<routineID>` 定位 Bot 信息页的该 routine 行。它不是主动提醒，
  不消耗保险丝，也不改变 routine 的运行或 held/interrupt 交付档位。
- **标识。** 每条通知的 identifier 为 `routine-due:<botID>:<routineID>:<fireAt>`；同一 routine 改期时
  旧 identifier 取消、新 identifier 登记。`routine-notification.schema.json` 与
  `golden/routine-notification.json` 固定字段、标题、深链和边界。
- **重排。** routine 运行、暂停、删除、改期、启用/恢复或安静时段延后时，宿主取消旧登记并按新的
  `nextRunAt` 重排。App 被杀后系统保留最后一次登记；再次启动时按当前 routine 状态做一次全量对账，
  取消孤儿 identifier。
- **勿扰与安静时段。** `dnd == true` 时不登记任何 routine 到期通知。落在安静时段的非紧急 routine
  把通知 `fireAt` 延到安静时段结束；`urgent == true` 且 `urgent_reason` 非空的 routine 保持原
  `nextRunAt`。安静时段仍由调度层执行“延后而不是丢弃”。
- **上限。** iOS 每个 App 最多保留 64 条 pending 通知。宿主每个 Bot 最多登记 **60** 条 routine
  到期通知，按 `fireAt` 取最早的 60 条；超出部分只影响通知，不影响 routine 本身。多个 Bot 的总数
  超过系统上限时，由系统决定保留哪些；宿主下一次对账会重试被丢弃的登记。系统在低电量或用户关闭
  通知时可能不显示通知，这是平台行为，不能从静态检查或模拟器推断真机结果。
- **失败。** 登记失败不回滚 routine、不阻塞运行；宿主保留当前内存签名，下一次 tick 重试。被系统
  丢弃的 pending 通知在下次启动对账时重新登记。

### 3.2 在场降级梯

宿主按能力逐级降级，并把实际级别暴露给 Bot 信息页；不支持的能力不伪装成在运行：

1. **前台。** App 处于 active，全功能。
2. **后台保活。** App 不在前台，用户开启保活，且任一 Bot 有进行中的回合，或该 Bot 在一个
   **900,000 ms（15 分钟）** 保活窗口内有 enabled、未进入 needs-reconciliation 的 routine
   `nextRunAt`。命中时持有现有静音音频会话；routine 完成后窗口内仍到期时继续持有。
3. **预定通知。** App 被挂起或杀掉后不依赖进程存活，由 §3.1 的本地通知提醒 routine 到期。
   系统通知权限未授予、用户关闭通知或低电量限制时不显示，宿主只能显示实际登记成功数。
4. **系统后台任务／推送中继。** 前者由既有 BGTask 路径补跑到期 routine；后者只保留
   `WakeSignalSource` 接口，本轮不实现。

Bot 信息页的在场区显示当前级别、实际登记的通知数，以及 `quiet_defer` 中因安静时段延后的
routine（标题、原定时间、延后到时间）。没有条目时显示空状态，不伪造运行、通知或延后。

**已删除、不得重新接线的规则**（PC-20261111-bot-v2-unwired）：每日预算、分类配额、冷却、
TTL、去重窗口、模型 triage 和 idle-checkin 来源。它们没有 schema，也不再有 Swift 类型或
事件字段；重新引入需要新的 v2 变更单。

## 4. 一致性向量

`golden/` 中的文件与 v1 移交时逐字节相同（`memory-policy` 已按 WPV-C 删除），覆盖
`memory-fact`、`memory-injection`、`memory-recall`、`wake-routine`、`held-inbox` 及其合并覆盖文件。
`routine-notification` 是本目录新增的 phoneDSH-owned 向量，覆盖正常、安静时段延后、紧急绕过和
四类非法输入。
`held-inbox.phone.json` 的 `upstream` 字段仍指向 `held-inbox.json`，合并语义与
[v1 §8.1](../v1/README.md#81-上游导出与-phonejson-覆盖) 相同：对象按键合并，数组按
`name`／`id`／`nonce`／`action.nonce` 追加或替换，覆盖文件不能删除上游用例。

从仓库根运行：

```bash
python3 spec/bot/v2/tools/validate_vectors.py
```

`spec/bot/v1/tools/validate_vectors.py` 也会调用同一个 v2 校验入口，因此 `phone-spec`
阶段同时覆盖两棵树。重跑上游导出器不会再读写本目录；`--out spec/bot/v1` 的产物里
不包含上面这些文件名，manifest 也只列 v1 剩余的文件。
