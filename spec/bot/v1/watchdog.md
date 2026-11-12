<!-- SPDX-License-Identifier: MIT -->

# Bot watchdog v1

状态：`target`。本文件冻结 `watchdog.schema.json` 的 config、工作单元、评估、flag payload 与
mobile host signal 语义。行为权威是 `Sources/PhoneDSHBot/Watchdog/{BotWatchdog,
BotWatchdogChecks,BotWatchdogMonitor}.swift`；本文件只把已实现的行为写成 Kotlin 可移植的条款。
watchdog 只观察，不 nudge、不 stop、不取消回合。

## 1. 范围

watchdog 对一个工作单元（unit）做六类检查：deadline、heartbeat、重复工具签名、重复工具错误、
unit 配额，以及手机 host signal 组（WebContent terminated、thermal、battery）。每个
`(unit, check)` 最多产生一次 `watchdog.flagged`。所有 flag 都是 durable BotEvent；写入失败只记录
诊断日志，不阻塞回合，下一次评估可重试同一检查。

P0 已有 production caller：`BotDSHRemoteRuntime` 在 `turn/start` 调 `startUnit`、在事件/用量/工具
调用时观察、在 `turn/end` 调 `finishUnit`，并由宿主按 `tickMs` 调 `tick()`。P0 **没有**
production caller 调用 `observeMobile`；Android 若接 thermal/battery/WebContent 信号，是新行为，
必须同时定义信号来源与节流预算（§6）。

## 2. Config

`schema/config` 的 13 个成员全部 optional；缺省值如下。reader 必须先套缺省再评估。

| 成员 | 缺省 | 语义 |
| --- | ---: | --- |
| `heartbeatTimeoutMs` | 120000 | 静默超过此毫秒数才 flag；`0` 关闭 |
| `turnDeadlineMs` | 900000 | turn 的默认 deadline；`0` 表示没有 deadline |
| `taskDeadlineMs` | 600000 | task 的默认 deadline；`0` 表示没有 deadline |
| `routineDeadlineMs` | 660000 | routine 的默认 deadline；`0` 表示没有 deadline |
| `repeatedToolCalls` | 5 | 同名+同参数摘要计数 `>=` 此值才 flag；`0` 关闭 |
| `repeatedToolErrors` | 3 | 同工具+同错误计数 `>=` 此值才 flag；`0` 关闭 |
| `maxUnitTokens` | 200000 | unit token 严格 `>` 此值才 flag；`0` 关闭 token 配额 |
| `maxUnitCostUsd` | 2 | unit 成本严格 `>` 此值才 flag；`0` 关闭成本配额 |
| `goalMaxTotalTokens` | 0 | goal 级总额度；`0` 表示未配置。P0 只执行 per-unit 配额 |
| `goalMaxTotalCostUsd` | 0 | goal 级总额度；`0` 表示未配置。P0 只执行 per-unit 配额 |
| `tickMs` | 5000 | 宿主调用 `tick()` 的节拍；monitor 自身不 sleep |
| `historyLimit` | 200 | 内存 recent flags 上限；存储 cap 为 `max(1, value)`，`flags(limit:)` 按配置值截断（0 返回空） |
| `maxUnits` | 1000 | tracked units 上限；超过时淘汰 `lastEventAt`（无则 `startedAt`）最旧者 |

边界规则：

- **缺省。** 缺成员等于取表中缺省；显式 `null` 不是缺省，类型错误。
- **非正数。** 负数被 reader 拒绝；`0` 合法，按上表关闭对应检查/额度。`historyLimit` 与
  `maxUnits` 的 `0` 在运行时按 `1` 处理。
- **未知成员。** config 是关闭对象；未知成员被 reader 拒绝，不静默忽略。这是契约验证层的规则；
  旧文档没有 production persisted config，因此没有迁移负担。
- **类型/溢出。** 必须是 JSON integer（`maxUnitCostUsd`/`goalMaxTotalCostUsd` 可为 number）；
  超出有符号 64-bit 范围、布尔、字符串、`null` 都拒绝。

错误码（validator/reader 边界；path 相对一份 config 对象）：

| code | path | 触发 |
| --- | --- | --- |
| `watchdog.config.type` | `/config/<field>` | 类型不符或无法表示为 integer/number |
| `watchdog.config.range` | `/config/<field>` | 负数或超出 64-bit 范围 |
| `watchdog.config.unknown` | `/config/<field>` | 未知成员 |

`config` 的 schema 是跨端 writer 的关闭形状；Swift `BotWatchdogConfig` 解码同样 reject 上述三类，
缺成员套缺省。Kotlin 不得只做 `additionalProperties` 忽略或把负数 clamp 成 0。

## 3. 工作单元

kind 是 `turn|task|routine|goal`。unit key 是 `(kind, id)`，`id` 去前后空白后不得为空。

- `startUnit(kind,id,botId?,sessionId?,startedAt?,deadlineOverrideMs?,at?)`：
  - 空白 id 返回空，不建 unit。
  - `startedAt` 缺省为 `at ?? clock()`；`lastEventAt` 初值为 `at ?? clock()`。
  - `deadlineAt = startedAt + deadlineMs`，其中 `deadlineMs` 依次取正数
    `deadlineOverrideMs`、该 kind 的 config deadline；`goal` 没有默认 deadline，因此
    `deadlineAt = null`。`deadlineMs <= 0` 也表示没有 deadline。
  - 同 `(kind,id)` 再次 `startUnit` 是幂等更新，不重置 `startedAt`/`deadlineAt`；只在原
    `botId`/`sessionId` 为 nil 时补上，并把 `lastEventAt` 推到 `max(old, at)`。返回该次评估的 flags。
- `finishUnit(kind,id)`：删除 unit 与该 unit 的内存 seen 集合；重复调用是 no-op。删除后同 key
  再 `startUnit` 会新建 unit 状态，但 durable event id 仍按 `(kind,id,check)` 去重；同一 key 在
  同一 store 中**不会**因为 finish/restart 再发第二条同 check 事件。
- `maxUnits` 淘汰只删除最旧 unit，不清别的 unit 的 seen。
- `unit(kind,id)` 返回当前状态；已 finish/被淘汰返回 nil。

`goal` 目前只作为 unit kind 与 goal 级 config 的载体；P0 没有独立的 goal 聚合检查。

## 4. 评估与 once-per-unit

- 宿主每 `tickMs` 调一次 `tick(at?)`，并在每个被观察事件后立即评估该 unit；两者都对当前状态跑
  §5 的检查。`tick` 按 `(kind,id)` 排序遍历，顺序稳定。monitor 不创建 timer，`tickMs` 是 caller
  契约，不是内部 sleep。
- 一个 flag 的 identity 是 `(unitKind,unitId,check)`。内存 `seen` 与 durable event id 共同保证
  幂等：event id 为 `watchdog.flagged:<kind>:<id>:<check>`；原文超过 400 字符时，id 中间段换成
  该原文 SHA-256 的前 32 个 hex 字符。
- 同一 flag 在写入前先占 pending；append 失败会释放 pending，下一次 tick 可重试。写入成功后
  `seen` 才永久生效。并发同 check 是 single-flight。
- 新 monitor 进程/重新打开 store 时，`seen` 为空；append 前按 event id 查 durable store，已存在
  则只把该 key 放入 `seen`，不重复发事件。因此 `(kind,id,check)` 的实际生命周期是 store 的
  durable 事件，而不是 unit 的内存状态。
- `finishUnit` 清掉该 unit 的内存 seen；不同 unit 或不同 check 互不影响。同 key restart 后再次
  评估是允许的，但 durable event id 已存在时只重建 `seen`，不再写第二条事件。
- 所有检查一起评估；一个检查写失败不阻止同一轮其他检查写入。
- flag 不改变 unit 状态，不停止回合。

## 5. Flag payload

每个 flag 是一个 durable BotEvent：

- `type = "watchdog.flagged"`；`origin = local/watchdog`；`principal.kind = "watchdog"`；
  `principal.botId`/`sessionId` 来自 unit（可为 null）；`correlationId = unitId`；
  `traceId = "trace:watchdog:<eventId>"`；`time = at`（epoch ms）。
- `data` 是关闭对象，成员固定为：

| 成员 | 类型 | 说明 |
| --- | --- | --- |
| `check` | enum | §5 的八个 check 值之一 |
| `unitKind` | enum | `turn|task|routine|goal` |
| `unitId` | string | 非空，已 trim |
| `botId` | string \| null | 缺失时 writer 写显式 `null`（Swift 现状） |
| `sessionId` | string \| null | 缺失时 writer 写显式 `null`（Swift 现状） |
| `at` | integer | 评估时刻 epoch ms，与 event `time` 相同 |
| `evidence` | object | 下表；可为空对象（mobile 允许空） |

`data` 的 schema 在 `watchdog.schema.json#$defs.flagData`。flag payload 是 `data`（开放对象）内
的关闭 shapes；未来新增成员需要新的 PC，不得在同名 check 下换 evidence 语义。

| check | evidence |
| --- | --- |
| `deadline` | `{deadlineAt, now, elapsedMs}`；`elapsedMs=max(0,now-startedAt)` |
| `heartbeat` | `{lastEventAt, now, silentMs, thresholdMs}`；`lastEventAt` 缺省用 `startedAt` |
| `repeated_tool_signature` | `{signature, count, threshold}`；signature 为 `name\|argumentsDigest` 或只有 name |
| `repeated_tool_error` | `{errorSignature, count, threshold}`；errorSignature 为 `name\|sha256(error text)` |
| `quota` | `{tokens, maxTokens, costUsd, maxCostUsd, reason}`；reason `tokens|cost|tokens_and_cost`，负用量按 0 |
| `webcontent_terminated` / `thermal_pressure` / `battery_pressure` | host 提供的读数字段；不可得时不得伪造，见 §6 |

数值 evidence 用 JSON number 写入（整数也用 number 编码），字符串/缺失值按 Swift 的
`BotJSONValue` 编码。

## 6. 检查语义

- **deadline**：只有 `deadlineAt != null && deadlineAt > 0 && now > deadlineAt` 才 flag；等号不
  flag。goal 通常没有 deadline。
- **heartbeat**：`pendingApproval <= 0 && heartbeatTimeoutMs > 0` 时，令
  `lastEventAt = unit.lastEventAt ?? startedAt`；`now-lastEventAt > threshold` 才 flag。等待审批
  不算静默。事件观察、工具调用/结果、usage、mobile 都会推进 `lastEventAt`。
- **repeated_tool_signature**：`repeatedToolCalls > 0` 且同 signature 连续计数 `>=` 阈值。
  signature 由 `name` + `argumentsDigest` 组成；参数摘要不同即重新计数。非连续的同签名不会累加。
- **repeated_tool_error**：`repeatedToolErrors > 0` 且同 errorSignature 连续计数 `>=` 阈值；
  任意非 error 结果清零错误计数。error 文本优先 `error`，否则 result digest，再否则 `"error"`；
  signature 用 SHA-256（`sha256:` 前缀与 Swift 一致）。
- **quota**：tokens/cost 分别按非负值累计；`maxUnitTokens > 0 && tokens > max` 或
  `maxUnitCostUsd > 0 && cost > max` 才 flag。两者同时超限时 reason `tokens_and_cost`，只有
  tokens 超限为 `tokens`，否则 `cost`。等号不 flag。
- **mobile group**：三个 check 都是 observe-only、每 unit 一次。它们不要求该 unit 已被
  `startUnit` 追踪；调用方直接给出 `kind/id/botId?/sessionId?/evidence/at`。WebContent terminated
  是宿主事件；thermal/battery 是宿主信号。evidence 是 host 读数（例如 pressure/level），必须来自
  真实信号；信号不可用、读取失败或平台没有该 API 时**不**发 flag，也不得写 0/正常值冒充读数。
  读数的语义与 Android 映射建议见 `docs/protocol-changes/PC-20261113-bot-watchdog-d7.md` §4。

## 7. 兼容性

- config 从无约束 object 收紧为具名 optional 成员：所有既有合法字段不变，缺成员新增缺省；未知
  成员和负数从“Swift 旧 decoder 恰好忽略/接受”变为明确拒绝。生产没有持久化 config，故无数据迁移。
- flag payload 只新增 `sessionId` 与 `at` 两个 data 成员，且 `data` 是开放对象；旧 reader 忽略
  未知 data 成员仍可读。event type、event id 算法、check 名称、once-per-unit 语义不变。
- 不新增 durable event type、SQLite schema、wire frame 或 route。
