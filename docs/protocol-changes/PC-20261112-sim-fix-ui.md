<!-- SPDX-License-Identifier: MIT -->

# 联调回归修复：抹除后的接续 notice、inbox-splice/投影缓存残留、例行任务页刷新与在场提醒

```yaml
change: PC-20261112-sim-fix-ui
contracts: [P02, P09, P26]
status: implemented
breaking: false
version_decision: "P02 §5.3 stays format 1: the tombstone record, rewrite order, mseq domain and manifest are unchanged; the delta only names which existing line is an erased line (a line carrying a copy of an erased message) and adds one derived-copy path to the proof step. P09 is presentation/refresh behavior over the existing row/event shapes; no row schema or event type changes. P26 adds an optional `nextNotificationAt` to the in-process presence value, not to any persisted or wire shape. No new field is required from an old producer."
base: 7a0f7085
contract_revision: spec/v1/wal.md@sim-fix-ui-1 + spec/ui/v1/pages/bot-chat.md@sim-fix-ui-1 + spec/ui/v1/pages/bot-info.md@sim-fix-ui-1
```

Protocol impact: P02, P09, P26; P25: none — the `erasure` event, `erasedSessionRecords` and tombstone payload are unchanged, only the planner's line selection expands to the existing splice copy; P27: none — no row-protocol field, card or action changes; P06: none — the DSH event mapper and `agent/inbox/spliced` shape are unchanged and only read by the host rewrite; P03: none — `journal.xljournal` stays out of scope.

## 1. 识别与角色

- **Trigger → 现况 → 期望（真实联调第二轮 B5/D3/D4）。**
  1. B5 抹除后宿主已把主会话切到 `gb-main-5050…`，但聊天页没有「对话已接续」notice；冷启动仍被误判为“读旧会话”。实际链路：真实 eraser 用的是同一个 `BotProductionUnit.environment`/`rows`；`updateSessionID` 与 row rebuild 都会换到新日志；冷启动 `latestMainSessionEvent()` 选中的也是新会话。断点在 UI：`BotUICardContent.valid(.notice)` 只接受 `error/denied/denial`，把 durable 的 `tone=info` 接续 notice 过滤掉了。旧纪元未命中行本来就应该继续拼接，旧行存在本身不是 bug。
  2. 旧 `gb-main/session.v4.jsonl` 的 `agent/inbox/spliced` 行仍含被抹除用户回合的原文；`materialized/home/storages/session_projcache/sessions/gb-main.json` 同样命中。`erasedSessionRecords` 只覆盖 canonical `record://session/...#seq`，planner 没有把同一 message 的 splice 副本纳入；宿主 §5.3 proof 的 derived-copy 列表也没有 projcache。
  3. 信息页的 `BotInfoModel` 在首次打开后缓存整份 `BotInfoSnapshot`。B4/B5 打开过信息页后，D1 在对话里新建 routine；D3 再次打开例行任务页时，根部 `.task` 只在 `memoryState == .loading` 时刷新，例行任务页自身不刷新，所以页面显示首次快照的空列表。
  4. 在场区的「已登记提醒」行只在 `presence.level == .scheduledNotification` 时渲染；前台时整行消失。契约只要求这一行显示实际登记数，没有把它限定在预定通知级别；矩阵 D4 还要求时间。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `sim-fix-ui`（worktree `dsh-work/sim-fix-ui`，branch `simfix/ui`，base `7a0f7085`）兼任四角色；先改 P02/P09 契约，再改 Swift 宿主/Bot 库/App 页面与测试，不 commit/push。
- **Owning contract / schema / fixtures.** P02：`spec/v1/wal.md` §5.3 step 3/5；P09：`spec/ui/v1/pages/bot-chat.md`（notice 可见性）、`spec/ui/v1/pages/bot-info.md`（数据入口刷新、在场提醒数量与时间）；P26：`RoutinePresence`（进程内展示值）。无 schema/golden 文件变化。
- **受影响的 producer / consumer.** `Sources/PhoneDSH/SessionLogErasure.swift`（宿主 proof）、`Sources/PhoneDSHBot/Journal/BotSessionErasure.swift`（planner）、`Sources/PhoneDSHBot/Routines/{RoutinePresence,RoutineScheduler}.swift`（presence 值）、`examples/probe-app/PhoneDSHProbe/Bot/{BotInfoPage,BotUIModels,BotFixtures}.swift`（UI/夹具）。Android/HarmonyOS 没有 Bot runtime，不跟进。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| P02 §5.3 step 3 | 只对「被引用的 canonical 行」写墓碑 → 明确：一行只要携带被抹除 user/assistant message 的副本（DSH 的 `agent/inbox/spliced` inserted entry），该行也是 erased line，整行替换为同 seq 的墓碑；仍逐行替换、不删除/重排其他行。 |
| P02 §5.3 step 5 | derived copies 列表为 overlay-cache/materialized.staging/recovery-backup → 追加 `materialized/home/storages/session_projcache/sessions/<sessionId>.json`；它是按 session id 可重建的投影缓存，只删除被改写会话的条目。 |
| P09 bot-chat | P0 卡片清单写 `error/denial notice` → 追加 `info notice`；`tone` 只是视觉提示，不是可见性开关。任何非空 `ui.notice` 文本都必须渲染，info 用中性色，不能把纪元接续 notice 过滤掉。 |
| P09 bot-info 数据入口 | 四个入口独立加载，但未规定重进时重读 → 明确每次呈现信息页和每次进入数据入口都重读宿主权威，不复用旧快照；对话中新建的 routine 重进后必须出现。 |
| P09 bot-info 在场 | 「已登记提醒 N 条」只在预定通知级别显示 → 前台/后台保活/预定通知都显示；宿主有已登记通知时同一行追加本地时间（`N 条 · 下次 <时间>`），没有时间只显示数量；0 也是宿主实际值，读取失败显示失败。 |
| P26 presence | `RoutinePresence` 只有 count/deferred/level → 新增 optional `nextNotificationAt`，由 `RoutineScheduler.presenceSnapshot` 从实际登记成功的 `scheduledNotifications` 取最早 `fireAt`；不写数据库、不进事件。 |

自检：没有第二种 envelope、别名或错误码；墓碑仍是既有 `phone-dsh/session-erasure`；`erasure` 事件和 `record://` 语义不变；presence 新增字段只在进程内，旧调用点使用默认 nil。

## 3. 兼容性

| Producer → Consumer | 处理 |
| --- | --- |
| old host → new erased session file | 新增墓碑只是既有 `ignorable` 行；old host 的 replay 得到同一字节，旧 App 不读 WAL。 |
| new host → old data | 没有新 manifest 字段、record type 或 mseq 语义；旧数据没有 splice 匹配时行为不变。 |
| old Worker/DSH → new host | Worker 只看到被改写的 JSONL；`agent/inbox/spliced` 已是 DSH 既有事件，墓碑替换不改变 envelope。 |
| old App → new presence value | 进程内 Swift 值，不跨进程/不持久化；旧调用点继续用默认 nil，不显示时间。 |
| 回滚 | 回滚不恢复已删 WAL 段/投影缓存（契约不承诺备份）；投影缓存会按 DSH 正常路径重建。 |

## 4. 验证

- 先红：`BotSessionErasurePlannerTests.testSpliceCopyOfAnErasedMessageIsIncluded`（`[1]` vs `[1,2]`）与 `SessionLogErasureTests.testRewriteRemovesOriginalBytesFromWalAndSurvivesRecovery`（projcache 仍命中 `QUOKKA_7F3A9`）在实现前失败；实现后同命令 4 tests / 0 failures。
- notice：证据 `.evidence/b5` 的行投影包含 `ui.notice`，但旧 `BotUICardContent` 对 `tone=info` 返回 false；修复后 `PhoneDSHBotTests.BotNoticeVisibilityTests` 覆盖 info/error/denial/空文本，App 的 `BotUICardContent` 调用同一个 `BotNoticeVisibility`。
- routine：`BotProductionChecks` 的 `info-refresh-reads-new-routine` 在首次 load 后新建 routine，再 load 必须看到；页面侧在信息页出现和进入例行任务页时重读同一 driver。
- presence：`RoutineNotificationTests.testPresenceSnapshotReportsRegisteredCountAndEarliestTime` 断言 count 与最早 `fireAt`；UI 截图核验见 worktree 报告。
- 完整命令结果见 `sim-fix-ui-20261112.md`。

## 5. 实现与失败路径

- planner：先按 record/needle 得 canonical seqs，再从这些行的 DSH message `id`/`source.rpcId`/完整文本+producer kind 生成指纹，把同 session 中携带相同 message 的 `agent/inbox/spliced` 行加入同一 target；`tombstoneLines` 仍按 seq 生成既有墓碑。短文本不单独做指纹，避免误伤。
- host：`SessionLogErasure.apply` 成功后按 `request.sessionID` 删除 `session_projcache/sessions/<id>.json`；删除失败不报错（缓存可重建），但 proof 的其他旧段检查仍失败即抛。
- UI：notice 可见性只要求非空文本；信息页在 sheet 出现时 refresh，例行任务页在 `routinesState != .loading` 时再 refresh；presence 行不再按 level 隐藏，时间来自 `nextNotificationAt`。
- 失败：splice 指纹不足时不误删（保留原行）；projcache 删除失败不伪造其他 proof；routine 列表读取失败仍显示“读取失败”，不显示为零。
