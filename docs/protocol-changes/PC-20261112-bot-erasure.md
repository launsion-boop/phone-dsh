<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-bot-erasure — 事件载荷分离、物理抹除与两个删除强度（S6）

```yaml
change: PC-20261112-bot-erasure
contracts: [P25, P26, P27, P09]
status: implemented
breaking: true
version_decision: "P25 storage v3 is breaking: bot_events splits into bot_event_headers + bot_event_payloads; old App versions refuse user_version 3 under the existing schemaTooNew rule. Event envelope schemaVersion stays 1; `erasure` is an additive durable event type and `record_erased` an additive phone-record error code, so old readers never see a changed existing shape."
base: 724f47a89
contract_revision: spec/bot/v1/README.md@erasure-v1 + spec/bot/v2/README.md@memory-erasure-v1
```

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 总方案 S6 第一步要求事件头与载荷分离，抹除作用于事件、记忆和派生
  视图，并把「忘记」与「抹除」分成两个强度。现况：`bot_events.payload` 保存完整 `BotEvent` JSON；
  记忆页的「抹除」实际写 `memory.document_deleted`（逻辑删除），历史版本、事件载荷和检索派生
  仍然保留；单份文档没有物理抹除入口。期望：事件头只追加、序号无缺口；载荷单独存放，仅宿主抹除
  路径可清空；清空后保留摘要并写一条 `erasure` durable 事件；`record://event` 读取返回
  `record_erased`；记忆页单文档/`agent/`/共享 `user/` 三个入口走物理抹除，文案如实说明
  「DSH 会话日志暂未覆盖」。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s2-s6`（分支
  `s2/s6-erasure`）兼任四角色；先冻结本单、`spec/bot/v1`/`v2` owning 文件和向量，再实现 Swift
  宿主、App 页面、eval 断言。第二步（session log 会话语义）只做 spike，不在本单实现。
- **Owning contract / schema / fixtures.** P25：`spec/bot/v1/README.md` §§1、4.6、
  `event-envelope.schema.json`、`erasure-event.schema.json`、`golden/event-envelope.phone.json`、
  `golden/erasure-event.phone.json`；P26：`spec/bot/v2/README.md` §§1.1–1.2、1.8、
  `golden/memory-erasure.json`；`record://` 已抹除语义：`spec/bot/v1/README.md` §§4.2、4.4、
  `record-query.schema.json`、`golden/record-query.phone.json`；P27/P09：
  `spec/ui/v1/pages/bot-info.md`。
- **受影响 producer / consumer.** Swift 宿主 `Sources/PhoneDSHBot/{Store,Journal,Memory,Rows,MCP}`；
  iOS Bot 信息页 `examples/probe-app/PhoneDSHProbe/Bot/**`；eval `scripts/ci/bot-e2e/**`；spec
  checkers `spec/bot/{v1,v2}/tools/validate_vectors.py`、`spec/tools/bot/check_golden.py`。
  Android/HarmonyOS 没有 Bot runtime，不需要跟进。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| SQLite schema | `user_version=2`，`bot_events(commit_seq,event_id,event_type,payload)` 存完整事件 → `user_version=3`，`bot_event_headers(commit_seq,event_id,event_type,payload_digest,payload_size,header_meta)` + `bot_event_payloads(commit_seq,payload,erased_at,erasure_commit_seq)`；只读视图 `bot_events` 重建旧读取形状。 |
| 载荷摘要 | 无 → `payload_digest = sha256(canonical JSON of data)`（sorted keys、不转义 `/`）；载荷清空后摘要仍可证明被清除的是哪一条。 |
| 事件头只追加 | `bot_events` UPDATE/DELETE 触发器 → `bot_event_headers` UPDATE/DELETE 触发器；`bot_event_payloads` 只允许「payload → NULL + erased_at + erasure_commit_seq」的 UPDATE，拒绝 DELETE。 |
| 序号校验 | 从 `bot_events` 顺序读取 → 从 `bot_event_headers` 顺序读取；`events(after:)`/`verifyIntegrity` 仍要求从 1 连续、`eventId` 去重、摘要匹配、被抹除行指向更晚的 `erasure`。 |
| 抹除事件 | 无 → durable `erasure`（P25 additive type），payload 由 `erasure-event.schema.json` 冻结：目标 scope/path、每路径版本号、被清除事件引用/类型/摘要/字节数、`legacyFactIDs`、未覆盖 `record://session/...`。 |
| `record://` 已抹除 | 引用存在即可读原文 → `record://event` 载荷被清除后 `read` 返回 `ok:false, error.code="record_erased", message="该记录已被抹除"`；`search` 跳过；`resolveEvidence` 拒绝。`record://session` 不在第一步范围。 |
| 记忆删除强度 | `delete`/页面「抹除」都是逻辑删除 → 「忘记」保持逻辑删除；新增宿主物理抹除单文档/`agent/`/`user/`，清除全部历史版本与事件载荷，追加 `erasure`。模型工具仍不能触发物理抹除。 |
| P27/P09 行与页面 | 记忆页单文档只有「忘记」，两个根「抹除」文案称已移除派生视图但实现不完整 → 单文档新增「抹除这份文档和全部历史版本」；三个入口都有范围确认和不可撤销提示；文案写明会话日志暂未覆盖。已抹除事件不再投影为 UI 行。 |

自检（`spec/README.md` §5.1）：没有第二套 envelope、别名字段或既有错误码的复用；序号域不变；
`erasure` 是 additive durable type，`record_erased` 是 additive error code；旧的 `memory.document_*`
事件仍可回放；存储格式的破坏性只落在 SQLite `user_version`，由现有 `schemaTooNew` 拒绝旧 App。

## 3. 兼容性

| Producer → Consumer | 处理 |
| --- | --- |
| old App → new DB | `user_version=3 > 编译期上限 2` → `SQLiteDomainStoreError.schemaTooNew(3)`；不打开、不迁移、不删除。 |
| old reader → new DB（仓内旧读取路径） | 只读视图 `bot_events` 继续返回 `commit_seq/event_id/event_type/payload`；已抹除行的 `payload` 是可解码 envelope，`data` 为 `{"$erased":true,"$erasureCommitSeq":N}`。Wake/Routine 快照读取不因拆分改 SQL。 |
| new App → old DB | v1/v2 打开时在单事务内解码旧 `payload`、拆分、重建 nonce 表并设 `user_version=3`；失败回滚，旧库保持原样；重复打开幂等。 |
| new → new | 所有新事件同时写头与载荷；`erasure` 事件和 `record_erased` 由同一批向量驱动 Python/Swift。 |
| persisted old data → new / rollback | 已写入的 `memory.document_written` 等事件原样保留内容和版本语义；回滚到 v2 App 会被 `schemaTooNew` 明确拒绝（本变更是破坏性存储变更），需要旧版可读时保留升级前备份。 |
| 模型工具面 | `UpdateMemory.action=delete` 仍是逻辑「忘记」；S6 没有新增物理抹除 action，模型不能触发物理抹除。 |

**版本决定。** SQLite `user_version` 2→3 是 breaking，理由是把完整事件载荷从事件头所在表移走，
旧二进制无法在缺少列的表上继续写；按现有“拒绝更高版本”规则处理，不做双写、不保留旧表别名列。
`event-envelope.schemaVersion` 保持 1；`erasure`、`record_erased` 都是 additive。
Worker 插件与 Swift 宿主需一起发布；`phone record` 的 `record_erased` 在旧宿主上不会出现（旧
宿主读到的是旧数据库，或拒绝新数据库），不会静默返回原文。

## 4. 共享向量与校验

- `spec/bot/v1/golden/erasure-event.phone.json`：2 个有效（单文档全版本、共享 user root）与 5 个
  非法（缺 targets、`record://event/0`、非 SHA-256、负字节、未知未覆盖原因）；Python 校验 schema、
  记录唯一、版本排序、`erasedBytes == sum(payloadBytes)`，并做 3 个 mutation。
- `spec/bot/v1/golden/event-envelope.phone.json`：追加 `erasure` envelope 正例；其 `data` 同时由
  `erasure-event.schema.json` 校验。
- `spec/bot/v1/golden/record-query.phone.json`：追加 `record_erased` 失败向量，`message` 固定为
  `该记录已被抹除`。
- `spec/bot/v2/golden/memory-erasure.json`：4 个有效（单文档全版本+派生副本、agent 跨 Bot 隔离、
  共享 user 跨 Bot、已删除历史仍计数）与 4 个非法目标；Python 参考实现校验路径/scope、版本计数、
  surviving paths 和 uncovered session refs，并做 3 个 mutation。
- `python3 spec/bot/v1/tools/validate_vectors.py`（内部调用 v2）与
  `python3 spec/tools/bot/check_golden.py --root .` 是静态门禁；Swift 测试用真实 codec/SQLite 驱动
  同一批事件/抹除语义。

## 5. 实现与失败路径

- **迁移。** `SQLiteDatabase.init` 在 `user_version` 1/2 时读旧 `bot_events.payload`，用真实
  `BotEventEnvelopeCodec` 解码，写头/载荷，重命名 nonce 表引用到 `bot_event_headers`，删旧表并建
  视图；全部在 `BEGIN IMMEDIATE` 内，失败回滚。
- **抹除提交。** `SQLiteDomainStore.erasePayloads` 在同一事务追加 `erasure` 事件、把目标载荷置
  NULL 并写入 `erased_at/erasure_commit_seq`；提交后 `PRAGMA wal_checkpoint(TRUNCATE)`、`VACUUM`、
  再 truncate WAL，保证主库和 WAL 不保留原文字节。
- **记忆规划。** 宿主按目标收集全部版本、路径事件、相同文本/唯一标记副本、指向被清除事件的
  redaction/observation 内容；`agent/` 只匹配同一 Bot，`user/` 跨 Bot；session 引用只进
  `uncoveredRecords`。
- **失败。** 单文档不存在 → `memory-not-found`；scope 无文档 → `ok, removed=0`；非法路径/scope
  mismatch → `memory-path-invalid`；载荷事件不存在 → `invalidTransition`；重复抹除不再写第二条
  `erasure`。任何失败都不伪称成功。
- **已知边界。** 第一步不覆盖 DSH session log；记忆页文案和 `erasure.uncoveredRecords` 都如实
  记录。会话纪元的可行性与风险见 `docs/research/bot-session-erasure-spike-20261112.md`（只取证，
  不实现）。

## 6. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| erasure-v1 | s2-s6 contract owner | 总方案 S6 第一步；P25 存储破坏性变更、`erasure`、`record_erased`、v2 记忆物理抹除、P09 页面 | Swift、iOS App、eval、spec checkers |

## 7. 验证（2026-11-12，s2-s6 worktree）

| 命令 | 结果 |
| --- | --- |
| `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS（497 tests，0 failures；含 `BotEventStorageTests` 的 v2→v3 迁移/幂等/摘要/序号/已抹除视图/头与载荷表拒绝非抹除变更，`MemoryErasureTests` 的单文档全版本+DB 字节、scope 隔离、幂等回放、观察信封/脱敏留痕引用清除） |
| `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（v2：erasure 4 valid / 4 invalid / 3 mutations；v1：erasure-event 2 valid / 5 invalid / 3 mutations；record-query 5 valid / 5 invalid） |
| `python3 spec/tools/bot/check_golden.py --root .` | PASS（29 files，16 upstream，13 overlays） |
| `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS（phone-spec 14s、phone-cross-tree 15s；8 invariants / 87 tests） |
| `python3 spec/ui/v1/tools/ui_check.py --root .` | PASS（5 files，13 contrast pairs，0 unmeasured surface items） |
| `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --upstream mock` | PASS（12/12 runnable；含 `BOT-SELFTEST-MEMORY-ERASE` 的 `erasure` 与 `no_bot_event payload_contains`） |
| `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/catalog.json --only BOT-E07 --upstream mock` | PASS（5/5 assertions：reply 不含词、visible memory 不含词、header 事件仍在、`erasure` 事件存在、`memory.document_written` 载荷不再含词） |
| `xcodegen generate` + `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/s2-s6-dd ... build CODE_SIGNING_ALLOWED=NO`（`HOME`/`CFFIXED_USER_HOME=/tmp/s2-s6-home`、`OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox`） | PASS（`** BUILD SUCCEEDED **`） |
| `scripts/ci/bot-ui/capture.sh`（沙箱绕行、`BOT_UI_SKIP_UI_TESTS=1`） | capture app `** BUILD SUCCEEDED **`，fixture conformance PASS（21 checks）；XCUITest `NOT_RUN`（沙箱 Pseudo Terminal）。全量 76 张截图在时间预算内只完成 8 张后改为用同一 app `simctl launch -BotUIFixture infoMemory` 截取所需记忆页：`/tmp/s2-s6-shots/{light,dark}/infoMemory.png`，两页均显示两个根各自的「含全部版本」抹除入口；截图后已 `simctl terminate` 并确认无 `PhoneDSHBotUICapture` 进程。 |

第二步只读证据见 [bot-session-erasure-spike-20261112.md](../research/bot-session-erasure-spike-20261112.md)；
本单未改 P02/WAL、未实现会话区间改写，也未在界面宣称覆盖会话日志。后续
[PC-20261112-bot-session-epoch](PC-20261112-bot-session-epoch.md) 已实现会话纪元、P02 §5.3 受控改写和
`record://session` 的 `record_erased`，并把界面文案改为覆盖已关闭会话纪元。
