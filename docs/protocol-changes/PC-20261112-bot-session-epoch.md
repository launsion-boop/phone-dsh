<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-bot-session-epoch — 会话纪元与已关闭会话日志的受控改写（S6 第二步）

```yaml
change: PC-20261112-bot-session-epoch
contracts: [P02, P25, P26, P27, P09]
status: implemented
breaking: false
version_decision: "P02 manifest format stays 1: no field, record type, mseq domain or recovery state is added; §5.3 defines an ordered use of existing complete-write/append/remove records plus §9 compaction. Old hosts replay the tombstone records as ordinary writes and old data (no tombstone) is unchanged, so both directions are compatible. P25 erasure payload stays schemaVersion 1 with additive optional `erasedSessionRecords`/`sessionEpochs`; old readers ignore them. `record_erased` already exists and is reused for `record://session`; no new error code."
base: d988108c1
contract_revision: spec/v1/wal.md@5.3 + spec/bot/v1/README.md@session-erasure-v1
```

## 1. 识别与角色

- **Trigger → 现况 → 期望.** S6 第二步要求「对某段内容抹除后，DSH 会话日志里的原文不再存在」，
  Worker 重启/resume/从 WAL 恢复都不能复活，且用户看到的对话连续。现况：`record://event` 已能
  返回 `record_erased`，但 `record://session` 仍直接读物化 session log；WAL 只追加，物化副本由
  WAL 派生；DSH 没有关闭后改写接口。期望：抹除触发会话纪元切换，旧会话关闭后宿主按固定顺序在
  WAL 里写入墓碑版本、删除旧 generation，再用既有 compaction 物理移除旧段；新纪元从未抹除的
  原始记录和记忆接续；旧纪元的未命中行仍可读，命中行返回 `record_erased`。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s3-epoch`
  （分支 `s3/session-epoch-erasure`，base `d988108c1`）兼任四角色；先冻结 P02/P25/P09 文本与向量，
  再实现 `Sources/PhoneDSHLog`、`Sources/PhoneDSH`、`Sources/PhoneDSHBot`、
  `examples/probe-app/PhoneDSHProbe/Bot/**` 和 E07。
- **Owning contract / schema / fixtures.** P02：`spec/v1/wal.md` §§5.1、5.3、9、
  `spec/v1/golden/wal/replay-phone/closed-session-rewrite.json`（phone-only，理由见该目录 README）；P25：`spec/bot/v1/README.md` §§4.2、4.6、
  `erasure-event.schema.json`、`golden/erasure-event.phone.json`、`record-query.phone.json`（既有
  `record_erased` 复用）；P09：`spec/ui/v1/pages/bot-info.md`。
- **受影响 producer / consumer.** Swift 宿主 `Sources/PhoneDSHLog/{WorkspaceLog,WALWriter}.swift`、
  `Sources/PhoneDSH/PhoneDSHHost.swift`、`Sources/PhoneDSHBot/{Journal,Rows,Memory,MCP}`；iOS Bot
  信息页/行投影；eval `scripts/ci/bot-e2e/**`（仅 E07 与新增 assertion）。Android/HarmonyOS 没有
  Bot runtime，不需要跟进；Rust `pdsh-wal` 不消费新顺序（它把墓碑记录当普通 write），manifest
  shape 未变，`phone-rust-tests` 不因本次变更需要改。

## 2. 契约 delta（先冻结）

| 项目 | Before → After／依据 |
| --- | --- |
| 已关闭会话可改写 | WAL 只追加；会话文件由 Worker 产生，宿主只能读 → **P02 §5.3** 允许宿主对「已关闭会话纪元」做受控改写：Worker park、无 append、D18 关闭当前纪元且 watermark == tail；改写从新纪元的新段开始，墓碑是普通 `op=1` complete write/`appended` 后缀，旧 generation 是 `op=3` remove。 |
| 改写后的物理抹除 | §9 compaction 只在整段 droppable 时删段 → §9 明确：§5.3 结束后的旧段全部 droppable；改写段因是最新 epoch-close 段而保留。宿主在返回前重扫 `wal/`，仍有旧段就失败，不返回伪成功。 |
| 崩溃窗口 | 无此状态 → §5.3 固定：步骤 3 前旧状态；墓碑 durable 后恢复只能得到墓碑状态；manifest 已缩短而文件未删完时下次 compaction 继续。成功返回后没有复活窗口。 |
| manifest / mseq | format 1，无 erasure 标记 → **不变**。墓碑记录是普通 mutation，mseq 只增不复用；`materialized_upto_mseq`/`last_mseq` 不下降。 |
| 已抹除引用 | `record://session` 无条件读行 → 命中墓碑行时与 `record://event` 相同：`ok:false`、`record_erased`、`该记录已被抹除`；`search` 跳过墓碑行，`resolveEvidence` 拒绝。 |
| `erasure` 事件 | 只有 memory/event 字段 → additive 可选 `erasedSessionRecords`（record/sessionId/seq/epoch）和 `sessionEpochs`（from/to/at_ms）；`uncoveredRecords.reason` 保留旧值并新增 `session-log-session-not-closed`。 |
| 纪元切换 | 主会话固定 `gb-<bot>`，旧行只按 `runtime.started` 恢复 → 主会话可切换到新 id；旧会话 `runtime.exited{reason:"session-erased", replacedBy}` + 新会话 `runtime.started` 是 durable 切换点；旧会话归档；行投影按时间拼接所有主会话 epoch，墓碑行不投影。 |
| 接续上下文 | 新会话没有历史 → 切换时从旧会话未命中行构造一次 seam（最近 user/assistant 文本，剔除墓碑），作为下一条用户消息的 `<system-reminder>` 前缀；模型可见、UI 不投影。 |
| UI 文案 | 所有抹除确认写「DSH 会话日志暂未覆盖」 → 删除该句；成功后在时间线追加一行 notice「已抹除的内容已从旧会话日志移除；对话已接续到新会话，未抹除的内容仍然可用。」 |

自检（`spec/README.md` §5.1）：没有第二套 envelope/record 类型；mseq、`record://` 语法、错误码
`record_erased` 都不变；墓碑是 DSH 的 `ignorable` 未知事件，DSH 不会拒绝加载旧会话。唯一放宽的是
「committed events are never rewritten」，它被限定为宿主专用、已关闭会话、按 §5.3 顺序执行，并且
在返回成功前证明旧段已不存在。

## 3. 兼容性

| Producer → Consumer | 处理 |
| --- | --- |
| old host → new WAL data | 墓碑只是普通 complete write/append/remove；old host 的 replay 得到同一字节。旧段已删、manifest 已缩短，old host 的 §7.2/§9 规则接受保留尾部低于 watermark。 |
| new host → old data | 没有墓碑也没有新 manifest 字段；行为与旧版相同。 |
| old host → new tombstone session file | 旧 `record://session` 会读到墓碑 JSON 而不是原文；这仍不泄露被抹除内容。DSH 用 `ignorable` 忽略未知事件。 |
| new host → old App | App 不读 WAL/manifest；Bot SQLite schema 不变；`erasure` 新增字段是 optional，旧 Swift reader 忽略未知 key。 |
| 模型/Worker 端 | DSH 0.2.2 不 patch；它只看到被改写的 JSONL。墓碑类型 `phone-dsh/session-erasure` + `ignorable: true` 是 DSH 已定义的未知事件保留规则。 |
| 回滚 | 回滚到旧 binary 不恢复已删 WAL 段；旧 App 可继续追加新事件到墓碑后的 session。若需要旧版可读，必须保留升级前备份（契约不承诺备份）。 |

**版本决定。** P02 是**兼容性行为变更**，不是 breaking：manifest `format` 仍 1，没有新 record
type、字段或 error code；旧实现的恢复规则对墓碑段和缩短 manifest 仍然成立。P25 是 additive
optional 字段，`schemaVersion` 仍 1。P09 文案变化不改变 schema。Worker/DSH 不需要一起发布。

## 4. 共享向量与校验

- `spec/v1/golden/wal/replay-phone/closed-session-rewrite.json`：一条 retained WAL 从 mseq 7 开始，先
  complete write 墓碑版本，再 remove 旧 generation；期望回放后旧词不存在、未命中行保留、watermark
  前进。由 `spec/v1/tools/spec_golden.py` 和 Swift `PhoneDSHLogTests` 驱动。
- `spec/bot/v1/golden/erasure-event.phone.json`：2 个有效（含 `erasedSessionRecords` /
  `sessionEpochs`）与 6 个非法；新增 2 个 mutation（session seq 不一致、epoch 身份相同）。
- `record-query.phone.json` 已有 `record_erased` 正例；本次只把 `record://session` 接到同一错误码，
  不新增失败形状。
- `python3 spec/bot/v1/tools/validate_vectors.py`、`python3 spec/v1/tools/spec_golden.py`、
  `python3 spec/tools/bot/check_golden.py --root .`、v2 `validate_vectors.py` 是静态门禁；Swift
  `PhoneDSHLogTests` / `PhoneDSHBotTests` 用真实 WAL、Materializer、SQLite 和 session parser 驱动。

## 5. 实现与失败路径

- **宿主改写（P02）。** `WorkspaceLog` 新增 host-only `compactDroppableSegments()`；
  `PhoneDSHHost.eraseClosedSession(...)` 要求 `.parked`、拒绝 `reconcile.inprogress`、拒绝压缩
  generation；定位 `<sid>/session.v*.jsonl`，把指定 seq 替换成墓碑、删除旧 generation，再
  `closeEpoch → append(complete write/append/remove) → closeEpoch → compact`，重扫 WAL 确认没有
  旧段，删除 overlay cache/staging/recovery-backup。
- **纪元（P25/P27）。** `BotDSHRemoteRuntime.switchMainSessionForErasure()` 创建新会话、claim、
  写 `runtime.exited`/`runtime.started`、归档旧会话；`BotProductionEnvironment` 更新 sessionID；
  `BotSessionLogProjector` 按 epoch 顺序拼接；seam 从旧会话未命中行构造。
- **抹除规划。** 记忆 store 在清空载荷前回调宿主：用 version 文本/唯一标记和 session evidence
  扫描 session log，返回命中的 `record://session` 与无法关闭的引用。`agent/` 只扫本 Bot；
  `user/` 是共享根，会跨 Bot 收集事件里出现过的 Bot id 并扫描它们自有的 session log。只有改写
  成功后才写 `erasure` 事件并清载荷。
- **失败。** 会话不 closed / 宿主未 parked / 有 pending reconcile / 压缩 generation / WAL 复查
  仍有旧段 → 抛错，不写成功、不写 `erasure`；旧会话仍在，可重试。重复抹除幂等；已经全是墓碑
  时不再写第二条 `erasure`。
- **不承诺。** APFS 快照、iOS/iCloud 备份、`recovery-backup/` 之外的历史备份、文件系统空闲块和
  闪存磨损层不承诺物理擦除；界面不宣称更广。

## 6. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| session-erasure-v1 | s3-epoch contract owner | S6 第二步：P02 §5.3 受控改写、P25 抹除事件 session 字段、P09 文案/notice | Swift、iOS App、eval、spec checkers |

## 7. 验证（2026-11-12，s3-epoch worktree）

| 命令 | 结果 |
| --- | --- |
| `swift build --disable-sandbox` | PASS |
| `swift test --disable-sandbox --filter 'PhoneDSHBotTests|PhoneDSHLogTests|PhoneDSHTests'` | 1196 tests, 2 skipped, 1 failure：`ProbeScenePhaseWiringTests.testScenePhaseOnChangeLivesOnlyInAppEntries`（`PCPairingPage.swift` 在基线里也有 `onChange(of: scenePhase)`，本单未改该文件；与本单元无关） |
| `bash scripts/ci/check.sh --only phone-rust-tests` | PASS（4s；pdsh-wal/pdsh-wire 全绿） |
| `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（erasure-event 2 valid / 6 invalid / 5 mutations；record-query 5 valid / 6 invalid） |
| `python3 spec/bot/v2/tools/validate_vectors.py` | PASS |
| `python3 spec/v1/tools/spec_golden.py --full` | PASS（95 files，0 error） |
| `python3 spec/tools/bot/check_golden.py --root .` | PASS（31 files，16 upstream，15 overlays） |
| `python3 spec/ui/v1/tools/ui_check.py --root .` | PASS（5 files，13 contrast pairs） |
| `CI_PROTOCOL_BASE=… bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-bot-eval-catalog` | PASS（phone-spec 24s、phone-cross-tree 20s、phone-bot-eval-catalog 0s） |
| `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --upstream mock` | PASS（15/15） |
| `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/catalog.json --only BOT-E07 --upstream mock` | PASS（6/6 assertions；含 restart_worker 与 `session_log_absent`） |
| `xcodegen generate` + `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/s3-epoch-dd … build CODE_SIGNING_ALLOWED=NO` | PASS（`** BUILD SUCCEEDED **`） |

未验证：真机、断电/掉电、APFS 快照、iCloud/设备备份、真实模型 E2E、Android/HarmonyOS（无 Bot
runtime）。这些不在本单的「不承诺」范围外被伪装成已验证。
