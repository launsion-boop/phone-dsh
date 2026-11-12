# Bot 契约修复冻结（P25/P26/P27/P09）

```yaml
change: PC-20261112-bot-contract-repairs
contracts: [P25, P26, P27, P09]
status: frozen
breaking: false
version_decision: No envelope or document version bump and no adapter. Absent nullable members and explicit null are the same stored value for new readers; old iOS bytes already omit them. The new authz.grant_snapshot enum value is accepted by the old Swift codec through the existing ignorable:true rule. Ephemeral events stay out of durable storage.
base: 9af4d7f3483cbd51a4847fd25fb7ea860a6f6966
contract_revision: c48f5f13831bc17d53afc5a6552ae813520394bb
```

## 1. 识别与角色

- **Trigger → 现况 → 期望.** `docs/design/android-bot-spec-deltas.md` §1 的 CCR-1、CCR-2、CCR-3、CCR-4、CCR-5、CCR-7
  使 Android Bot 无法按现有契约移植。协调者以 contract owner 身份决定其中六项；CCR-6（`spec/README.md`
  状态措辞）仍 deferred。期望：把决定写进 owning schema/golden/normative README，增加共享向量，
  用真实 Swift encoder 证明 iOS 端，并冻结本单。
- **Coordinator / contract owner:** 本任务的协调者。**Implementer / reviewer-integrator:** `BOT-C` worker。
- **Owning spec:** P25 `spec/bot/v1/{event-envelope.schema.json,event-envelope.ephemeral.schema.json,authz-grant-snapshot.schema.json}`；
  P26 `spec/bot/v2/{routine.schema.json,routine-document.schema.json,routine-delivery.schema.json}`；
  P27 `spec/bot/v1/golden/bot-attachments.phone.json`；P09 `spec/ui/v1/pages/{bot-chat,bot-dock}.md`。
- **Affected producers/consumers.** iOS P25 writer/reader（`BotEventEnvelopeCodec`、`SQLiteDomainStore`）、
  iOS grant recovery（`BotGrantSnapshot`）、iOS routine store（`RoutineStore`/`DurableEventSnapshots`）、
  iOS attachment prompt（`BotAttachmentPrompt`）和 Bot UI（`BotAgentCommRendering`）。未来 Kotlin
  B1/B3/B5/B7a/B7b 是同一 schema 的 writer/reader；Android 源码不在本任务内。Worker/TS 没有 envelope
  validator，只有行投影消费者；P03 journal 是另一序号域，不受影响。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| P25 envelope presence | `principal.botId`、`principal.sessionId`、`causationId`、`correlationId` 从 durable schema 的 `required` 移除，类型仍为 `[string, null]`。**absent ≡ null**；reader 接受两者，writer omit nil。见 `spec/bot/v1/README.md` §1.2。 |
| Canonical stored bytes | UTF-8、排序 key、`/` 不转义、无多余空白。iOS 既有 store 和新写入的字节都由同一 codec 产生；Kotlin writer 必须 omit nil 才能得到相同 bytes。 |
| Durable vs ephemeral | `event-envelope.schema.json` 明确为 durable-only（`commitSeq >= 1`）。新增 `event-envelope.ephemeral.schema.json`：封闭 shape、无 `commitSeq`、永不落盘、永不进 durable batch。 |
| `authz.grant_snapshot`（CCR-2） | 新增为 durable `type` enum 成员；`data` 由 `authz-grant-snapshot.schema.json` 冻结：`grants` 数组，entry 恰好 11 个字段，不允许未知成员；`sessionId`/`expiresAt` 为 nil 时 Swift 写显式 `null`。valid vector 由 Swift `BotGrantSnapshot` + `BotEventEnvelopeCodec.encode` 产生。 |
| P26 routine presence（CCR-7） | `run_state`、`quiet_defer`、`next_run_at`、`last_result` 从 `routine.schema.json` 的 `required` 移除；类型仍 nullable。缺省 ≡ null；writer omit nil。 |
| `RoutineDocument` | 新增 `routine-document.schema.json` 冻结 `routine.*` 事件 data 的 `{botId, document:{version, routines, deliveries}}`；新增 `routine-delivery.schema.json` 冻结 delivery 字段。`golden/routine-document.json` 覆盖 new/deferred/started/needs-reconciliation/deleted，五个 data 均由 Swift `DurableEventSnapshots.data(for:botId:)` 产生。 |
| P27 attachments（CCR-5） | 新增 `golden/bot-attachments.phone.json`：`promptBlockPhone`（逐字 phone 句子）、`safeNameCases`（Swift tests 的 9 条）、`importPathCases`（`<botRoot>/imports/attachments-<messageID>/`）。上游 `golden/bot-attachments.json` byte-identical；Swift test 改为读取 overlay，不再替换 Mac 句子。 |
| P09 agent-comm（CCR-3） | `bot-chat.md` §3 从“不实现”移除“Bot 间通讯行”，保留 canvas/product/gift；把它加入 P0 行清单，并与 `bot-drawer.md` §5、`spec/bot/v1/README.md` §1.1 的对方头像/皇冠规则对齐。 |
| P09 bottom bar（CCR-4） | 采用 option (b)：`bot-dock.md` 顶部标为 superseded proposal，指向 shipped `HomeTabBar.swift` 的四等宽列（Bot/DSH/发现/我的）。`HomeTabBar` 代码两端都未改。 |
| 状态与版本 | 不升 `schemaVersion`/`version`，不迁数据库，不改 registry status rows。 |

自检（`spec/README.md` §5.1）：没有第二种 envelope、字段别名、fallback 或平台分支；没有新增错误码；
nullable 成员的缺省语义只有一个；`authz.grant_snapshot` 使用既有 unknown+`ignorable:true` 规则，
未扩大未知 type 的放行范围；ephemeral schema 是封闭的，不把 ephemeral 混进 durable 存储。

## 3. 兼容性与发布

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| old iOS store → new reader | 支持。旧行省略四个 nullable 成员；`decodeIfPresent` 解码为 nil。旧 `authz.grant_snapshot` 行仍由 `BotGrantSnapshot.decode` 恢复；旧 routine snapshot 缺失四个字段时 `Routine` 的 `decodeIfPresent` 使用 nil。向量：`event-envelope.phone.json` absent/null、grant；`routine-document.json`。 |
| new iOS → old reader | 支持新写入的 envelopes：新 writer 仍 omit nil，旧 Swift `decodeIfPresent` 接受；`authz.grant_snapshot` 对旧 Swift codec 是未知 type + `ignorable:true`，因此接受。旧 routine reader 对缺省 nullable 字段同样接受。旧 **schema-only** validator 会拒绝新 enum/新 data 形状；仓库内没有 runtime schema validator，故这不是 iOS 运行时拒绝。 |
| new iOS → new reader | 支持。`BotEventEnvelopeCodec` 与新 schema 都接受 absent/null；grant data 由 `BotGrantSnapshot` 和 schema 双向验证；routine document 由 `DurableEventSnapshots` 和 Swift test 对拍。 |
| persisted old data → new／rollback | 不迁移、不重写、不提升 envelope/document 版本。回滚到旧 writer 会继续 omit nil，新 reader 仍接受；回滚后旧 reader 读到新 grant snapshot 的条件仍是 `ignorable:true`（本单未改该规则）。 |
| future Kotlin writer | MUST omit nil for the four envelope members and the four routine members；MUST 对 grant entry 的 `sessionId`/`expiresAt` 写显式 `null`；MUST 用排序 key 的 canonical JSON；ephemeral MUST 不落盘且不带 `commitSeq`；未知 durable type 仍只在 `ignorable:true` 时跳过；`authz.grant_snapshot` 必须在 durable 分支写出 `data` 的 11 字段 entry。 |
| future Kotlin reader | 接受 absent/null 两种 envelope 和 routine 输入；对 grant snapshot 校验 11 字段/no unknown；对 `version != 1` 的 RoutineDocument fail-closed。 |

版本／adapter 决定：本单是 presence 规则 + additive enum/data schema + phone-only overlay；
按 P25/P26 的既有版本规则不升版本、不新增 adapter。数据库 `user_version` 不变。

## 4. 分工与证据

- **独占路径。** `spec/bot/**`、`spec/ui/v1/pages/{bot-chat,bot-dock}.md`、`Tests/PhoneDSHBotTests/**`、
  `docs/protocol-changes/PC-20261112-bot-contract-repairs.md`。未编辑 `Sources/**`、`examples/**`、
  `android/**`、`spec/README.md`、PCLink 或 UI token 文件。
- **共享 fixtures。** `spec/bot/v1/golden/event-envelope.phone.json`（absent/null、grant、ephemeral、
  durable-missing-commitSeq）、`spec/bot/v1/golden/bot-attachments.phone.json`、
  `spec/bot/v2/golden/routine-document.json`。Swift tests 从磁盘读取合并后的 golden；Python checker
  在 `spec/bot/v1/tools/validate_vectors.py` 和 `spec/bot/v2/tools/validate_vectors.py` 中逐条校验。
- **各端真实 producer/consumer。** iOS：`BotAttachmentGoldenTests`、`BotEventEnvelopeTests`、
  `RoutineDocumentGoldenTests` 用真实 `BotAttachmentPrompt`/`BotEventEnvelopeCodec`/`BotGrantSnapshot`/
  `DurableEventSnapshots` 对拍；`BotGrantRecoveryTests` 继续覆盖恢复路径，`RoutineDurabilityTests` 的 concurrency case 在本机既有崩溃（见下表）。
  Android：没有 runtime，本单只交付 schema/golden；B1/B3/B5/B7a/B7b 仍是 target。

命令与结果（实际输出见任务交接）：

| 命令 | 结果 |
| --- | --- |
| `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（同时运行 v2；新 routine-document 通过） |
| `python3 spec/tools/bot/check_golden.py --root .` | PASS（24 files, 16 upstream, 8 overlays） |
| `python3 -m unittest discover -s spec/tools -p 'test_*.py'` | PASS（91 tests） |
| `bash scripts/ci/check.sh --only phone-bot-eval-catalog` | PASS（24 tests + catalog） |
| `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | phone-spec PASS、phone-cross-tree PASS；phone-p0-conformance FAIL，page-structure 6 个 baseline 外差异：connected-computer/home-drawer/pc-pairing/settings（均 PCLink/GAP-35）；native-configuration 的 5 个已在 baseline 内。未修。 |
| `swift test --filter PhoneDSHBotTests` | INCOMPLETE：包在 `Tests/PhoneDSHPCLinkTests/GoldenVectorTests.swift:578` 被既有 compiler type-check 错误挡住（`unable to type-check this expression in reasonable time`）。用临时本地 workaround（不提交、已 revert）后可编译；同一 workaround 下 `PhoneDSHBotTests` 442 tests PASS，另 `RoutineDurabilityTests.testConcurrentCreateUpdateAndRepeatedFinishDoNotLoseUpdates` 在本机以 signal 6 崩溃（既有并发/SQLite 问题，未改该测试）。 |
| `swift build --target PhoneDSHBotTests` | PASS（新增/修改的 Bot 测试目标编译通过） |
| `bash scripts/ci/check.sh --list` | 已执行；Bot gate 为 `phone-bot-eval-catalog`，已运行。 |

- **CCR-2 finding（不改 runtime Swift）.** `Sources/PhoneDSHBot/Journal/BotEventEnvelopeCodec.swift:27-45`
  的 `durableEventTypes` 没有 `authz.grant_snapshot`；`:134-138` 只在未知 type 且 `ignorable == true`
  时接受；`Sources/PhoneDSHBot/Authz/BotGrantSnapshot.swift:159` 确实设置 `ignorable: true`。因此
  iOS 现有 write/read 仍然正确，但 `BotEventEnvelopeCodec.isDurable("authz.grant_snapshot")` 返回
  `false`，与新的 schema enum 不一致。`isDurable` 目前在 `Sources/**` 中没有调用方（仅定义在
  `:68-70`），所以本任务不改 Swift；下一次 runtime Swift 变更应把该 type 加进 durable set。
- **状态保留（CCR-6 deferred）.** `spec/bot/v1/README.md` 与 `spec/bot/v2/README.md` 顶部仍写
  `状态：target`；`spec/README.md` 的 P09/P25/P26/P27 行和 `spec/registry.json` 未改；P09 Bot 页面
  仍标 target。Registry build 仍是 byte-identical。

## 5. 修订纪录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| c48f5f13831bc17d53afc5a6552ae813520394bb | `BOT-C` | CCR-1（presence/ephemeral）、CCR-2（grant snapshot）、CCR-3（agent-comm rows）、CCR-4（four-column bar）、CCR-5（attachment phone overlay）、CCR-7（routine presence/document）；CCR-6 remains deferred. | Swift/iOS（implemented/tested）；Android B1/B3/B5/B7a/B7b 按此 schema/golden 实现；P09 owner 保留 status rows |
| c48f5f13831bc17d53afc5a6552ae813520394bb (runtime follow-up) | DSH worker | CCR-2 runtime follow-up done: `authz.grant_snapshot` is now in `BotEventEnvelopeCodec.durableEventTypes`; `BotGrantSnapshot` keeps `ignorable: true` for old iOS readers and writes the same bytes, covered against the frozen grant vector. | Swift/iOS |
