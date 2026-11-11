<!-- SPDX-License-Identifier: MIT -->

# Bot v2 删除未接线的记忆与主动提醒契约（P26）

```yaml
change: PC-20261111-bot-v2-unwired
contracts: [P26]
status: implemented
breaking: false
version_decision: No wire or version change. The removed surface is `target` and was never wired: there is no production caller in `Sources/` or `examples/`, no schema/golden for the removed proactive rules, and the only durable event (`proactive.considered`) keeps its envelope and required fields. Removing the unused `memory-policy` schema/vector and the unused Swift policy types can be rolled back by restoring the files; old durable events remain readable because `data` is an open object and the reader tolerates the removed optional fields.
base: 871488cfe
contract_revision: spec/bot/v2/README.md@v2-unwired-20261111 + Sources/PhoneDSHBot/Proactive@v2-unwired-20261111
```

Protocol impact: P26; P25: none — `event-envelope.schema.json`、事件日志、effects outbox 和 SQLite schema 未改；`proactive.considered` 只是不再写 `cost`/`spendBudget` 这两个可选 data 字段，旧事件仍可读（回归覆盖）。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** WPV-A 建立 v2 之后，v2 仍带着 `memory-policy` 以及主动提醒的
  每日预算、分类配额、冷却、TTL、去重窗口、模型 triage、idle-checkin 来源。这些规则没有
  接线：`Sources/` 与 `examples/` 里没有 `ProactivePolicyConfiguration`、`ProactivityPolicy`、
  `ProactiveTriage*`、`ProactiveSources`、`idleCheckin` 的生产调用方，只有测试引用
  （2026-11-11 搜索）。方案 §6 决定 2、3 要求后台整理改用 maintainer 会话、主动提醒只保留
  勿扰、安静时段和保险丝。期望：删除这些未接线契约，保留勿扰、安静时段延后、频率保险丝和
  通知投递接口。
- **Coordinator / contract owner / implementer.** 本单元 `s1-v2`（分支 `s1/bot-spec-v2`）
  兼任 contract owner 与 implementer。先按 AGENTS.md §3.1 冻结删除范围，再改 v2 契约和
  `Sources/PhoneDSHBot/Proactive/**`。
- **Owning contract / schema / fixtures.** `spec/bot/v2/README.md` §1/§3；删除
  `spec/bot/v2/memory-policy.schema.json` 与 `spec/bot/v2/golden/memory-policy.json`；
  `Sources/PhoneDSHBot/Proactive/{ProactivePolicy,ProactiveModels,ProactiveEngine,ProactiveSources}.swift`；
  删除 `ProactiveTriage.swift`。
- **受影响的 producer / consumer.** 只有 `Tests/PhoneDSHBotTests/Proactive/**` 和
  `Tests/PhoneDSHBotTests/Wake/WP6TestSupport.swift` 里的测试辅助引用。没有 App/Worker/
  Android/HarmonyOS 端。`RoutineScheduler`、`ProactiveSettings`、`RoutineQuietHours` 和
  `UNUserNotificationProactiveDelivery` 保留。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 记忆 | `memory-policy` schema + golden 存在，但明确“仅作上游兼容证据” → 删除；facts 的保留字段和 `MemoryPolicy` 决策不实现不变。 |
| 主动提醒规则链 | 未接线实现（预算/配额/冷却/TTL/去重窗口/triage/idle）→ 契约只列 retained 链：投递对象、勿扰、安静时段、频率保险丝、通知投递接口；并显式列出已删除规则，重新引入需新变更单。 |
| `ProactivePolicyConfiguration` | `dailyBudget`、`quotas`、`cooldownsMs`、`ttlsMs`、`dedupeTTLMs` → 删除；保留 `fuseWindowMs`、`fuseMaxWakeups`（默认 900,000 ms / 4）。 |
| `ProactivityPolicy` | 重复窗口、TTL、分类配额、冷却、全局预算检查 → 删除；保留空 botId 拒绝、勿扰、安静时段、保险丝。 |
| `ProactiveTriage*` | `ProactiveTriageRequest/Client/Gate/GateResult` → 整个文件删除；`ProactiveEngine` 不再有 triage 依赖。 |
| `ProactiveSources` | idle 计时器、`conversation.turn_ended` 空闲候选、`idle-checkin` 候选 → 删除；保留 task/routine/reminder 来源。TTL 字段删除。 |
| `ProactiveKind` | `.idleCheckin` → 删除；`task-done`、`routine-result`、`reminder` 保留。`restoreAccounting` 跳过已删除/未知 kind 的旧事件，不让它使保留的保险丝记账不可读。 |
| `ProactiveCandidate`/`ProactiveReminder`/`ProactiveDecision` | `ttlMs`、`cost`、`silentForMs` → 删除；通知标识 `dedupeKey` 保留，但只用于稳定通知标识，不再抑制候选。 |
| 持久化事件 | `proactive.considered.data` 不再写 `cost`/`spendBudget`；`fuseRecorded`、`kind`、`botId`、`mode`、`decision`、`reason`、`channel`、`dedupeKey` 保留。`data` 是开放对象，旧事件里有额外字段仍可读。 |
| 保留 | 勿扰（含显式 reminder 例外）、安静时段拒绝与 routine 调度层延后、频率保险丝、`ProactiveDelivering`/`ProactiveNotification`/`ProactiveDeliveryResult`、iOS 深链。 |

自检（`spec/README.md` §5.1）：没有新增第二种表达；删除的是 `target` 且无生产调用方的
表面；没有收窄或放宽任何仍在使用的 wire 输入；没有新增 enum；旧持久化事件仍可读。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 `proactive.considered` 事件带 `cost`/`spendBudget`/`dedupeKey`，新 reader 只读保留字段，未知字段被忽略；旧事件仍参与保险丝恢复（`testOldAccountingFieldsRemainReadable`）。已删除的 `idle-checkin` kind 被跳过，不阻断恢复（`testRemovedIdleCheckinEventDoesNotBreakRestore`）。 |
| new → old | 旧代码若回滚，事件缺少 `cost`/`spendBudget` 时其旧 policy 用默认值处理；没有生产代码消费这些字段，回滚不产生行为差异。 |
| new → new | 新 `ProactiveEngine` 只在 would/did 时记 `fuseRecorded`；投递失败不消耗保险丝；重复候选不再被去重窗口抑制。 |
| persisted old data → new／rollback | 没有 SQLite schema 或事件 envelope 变化；旧事件保留在库中，回滚代码仍能读 envelope。 |

- 版本决定：不升 P26 版本，不新增 schema 版本；删除的是未接线的 target 表面，不是已发布格式。
- bundle／image 顺序：没有 Worker 或 native artifact 变化；无需重建 bundle。
- `target` 差异：v2 仍为 `target`；本次删除后不再保留这些条款的“未来启用”占位。

## 4. 验收命令与证据

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 生产调用方搜索 | `grep -rn "ProactivePolicyConfiguration\\|ProactivityPolicy\\|ProactiveTriage\\|idleCheckin" Sources examples`（排除 `Sources/PhoneDSHBot/Proactive/`） | 0 命中；只有测试引用被删类型 |
| Swift | `swift test --disable-sandbox --filter PhoneDSHBotTests` | 见交接报告；WPV-C 后 431/0 |
| 安静时段延后 | `swift test --disable-sandbox --filter 'RoutineQuietHoursTests\\|RoutineSchedulerTests'` | PASS：8 tests / 0 failures |
| v2 向量 | `python3 spec/bot/v2/tools/validate_vectors.py` | PASS（memory-policy 已移除） |
| v1 + v2 向量 | `python3 spec/bot/v1/tools/validate_vectors.py` | PASS |
| golden 清单 | `python3 spec/tools/bot/check_golden.py --root .` | PASS：22 files / 16 upstream / 6 overlays |
| 协议 CI | `CI_PROTOCOL_BASE=871488cfe bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | 见交接报告：`phone-spec` PASS、`phone-cross-tree` PASS、`phone-p0-conformance` 的 7 条 page-structure 失败在基线 HEAD 上已存在 |
| plugins | `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` | PASS：82 tests / 79 pass / 1 skip / 2 todo，与移交前相同 |
| phone-modules | `bash scripts/ci/check.sh --only phone-modules` | PASS |
| phone-sdk | `bash scripts/ci/check.sh --only phone-sdk`；以及同一 filter 加 `--disable-sandbox` 手工运行 | check.sh FAIL（`sandbox-exec: sandbox_apply: Operation not permitted`）；手工运行 INCOMPLETE，观察到 11 个与本 diff 无关的失败（10 个 BLE cross-runtime 需要 firmware/cJSON/mbedTLS 工具链，1 个 `ProbeScenePhaseWiringTests` 在 `examples/probe-app`），38 分钟后挂起后终止；没有 PhoneDSHBot 测试类在这个 filter 内 |

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| v2-unwired-20261111 | s1-v2 contract owner | 方案 §6 决定 2、3：删除未接线的预算/配额/冷却/TTL/去重/triage/idle 与 memory-policy | Swift、spec registry |
