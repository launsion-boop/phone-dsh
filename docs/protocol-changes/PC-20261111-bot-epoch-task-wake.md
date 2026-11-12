<!-- SPDX-License-Identifier: MIT -->

# PC-20261111-bot-epoch-task-wake — 主会话纪元切换后的 Task 父唤醒

```yaml
change: PC-20261111-bot-epoch-task-wake
contracts: [P26]
status: implemented
breaking: false
version_decision: "P26 行为补充，无新字段、事件类型、错误码或版本号。Task 的自身会话与 durable parentSessionId 不变；旧数据仍按原 owner 读取。"
base: de47c0ee
contract_revision: spec/bot/v1/README.md@bot-epoch-task-wake-v1
```

## 1. 识别与角色

- **Trigger → 现况 → 期望.** `BotDSHRemoteRuntime.switchMainSessionForErasure` 把主对话切到新纪元后，
  切换前由旧主会话派生的 Task 仍以旧主会话为 durable `parentSessionId`。Task 完成 / 拒绝 / 中断后的
  唯一父唤醒发往已归档的旧会话，失败被吞掉，新主会话收不到。期望：同一 Bot 的当前主会话收到该
  唯一唤醒；Task 自身会话不变；`AwaitTask`/`StopSubagent` 对新主会话可用，对其他会话仍拒绝；
  team / routine 派生的 Task 不受影响；Worker 重启后行为不变。
- **方案选择：B（唤醒时按 Bot 解析当前主会话）.** 选择理由：durable Task 记录保留真正派发它的会话
  作为审计归属，不制造一次 owner 改写；唤醒在投递点解析，不需要迁移历史快照；重启后依据既有
  `runtime.started` 主会话纪元历史恢复同一解析，不新增持久字段。A（切换时重映射 owner）也能满足
  功能，但会改写 `task.updated` 的 principal/parentSessionId，并需要一个额外的旧父会话兼容别名，
  改动和回滚面更大。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `task-wake`
  （worktree `dsh-work/task-wake`，分支 `bot/epoch-task-wake`）兼任四角色。
- **Owning spec / fixtures.** P26：[spec/bot/v1/README.md](../../spec/bot/v1/README.md) §2.7、§4.6。
  本次不新增 schema、golden 或 fixture 文件；回归在真实 Swift actor / event store / scripted DSH
  transport 上驱动。
- **受影响 producer / consumer.** Swift 宿主 `BotDSHRemoteRuntime`（Task 记录、父唤醒、
  `AwaitTask`/`StopSubagent` 归属校验）。App/Worker 行投影和 event envelope 不变；Android/HarmonyOS
  没有 Bot runtime，不需要跟进。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| Task 自身会话 / `persistedTask.sessionId` | 不变。 |
| `persistedTask.parentSessionId` | 不变；仍记录实际派发 Task 的会话。 |
| 父唤醒目标 | owner 是本 Bot 前一主会话且已被纪元切换归档 → 同一 Bot 的当前主会话；否则保持 owner。每次终态仍恰好一条唤醒。 |
| 唤醒 requestId | 不变：`task-settled:<taskId>`、`task-settled:<taskId>:approval:<approvalID>`、`task-interrupted:<taskId>`。 |
| `AwaitTask`/`StopSubagent` 父会话校验 | 原父会话仍可读/停；本 Bot 当前主会话作为原父会话的纪元继任者同样可读/停；其他 Bot/会话仍 `unauthorized`。live Task 的 incarnation 校验只在原父会话直接访问时保留。 |
| team / routine 派生 Task | 不变；`parentKind` 非 `chat` 不进入继任规则，唤醒行为保持原样。 |
| 重启恢复 | 从既有 durable `runtime.started` 重建主会话纪元集合；不新增事件、字段或迁移。 |
| 条款状态 | §2.7 的“主会话纪元与 Task 唤醒”和 §4.6 的纪元切换补充是新规范；无 target → implemented 状态提升。 |

自检：没有第二套 owner/唤醒表达；没有新增字段或事件；错误码、序号域、去重和 requestId 均不变；
只收紧了“已归档旧主会话不再接收唤醒”和“当前主会话可继任读取/停止”这两个明确语义。

## 3. 兼容性

| Producer → Consumer | 处理 |
| --- | --- |
| old → new | 旧数据没有纪元切换后的新行为；按原 owner 唤醒，和旧版一致。新宿主读取既有 `runtime.started`，不需要新事件。 |
| new → old | 新宿主写出的 Task 记录形状与旧版相同；回滚后旧宿主按原逻辑向 owner 唤醒，可能复现旧限制，但不损坏记录。 |
| new → new | 唤醒目标、requestId 和 single-delivery 语义一致。 |
| persisted old data → new／rollback | 旧 snapshot 的 `parentSessionId` 可直接读取；新逻辑只在它是本 Bot 前一主会话时重定向。回滚不丢 Task 记录。 |

**版本决定.** 非 breaking：P26 行为补充，不新增 wire/event/schema 字段。App、Worker、旧数据可独立升级；
Worker（DSH）不感知该变更。

## 4. 分工与证据

- **实现路径（本单独占）.** `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`、
  `Tests/PhoneDSHBotTests/MCP/BotTaskEpochWakeTests.swift`、本 PC 与
  `spec/bot/v1/README.md`。
- **共享 fixtures.** 无新增 golden。回归复用 `BotScriptedRemoteTransport` 和真实
  `SQLiteDomainStore`；覆盖完成、拒绝、中断、`AwaitTask`/`StopSubagent` 授权、非主会话来源、
  Worker 重启恢复。
- **真实 producer/consumer 测试.** `BotTaskEpochWakeTests` 驱动真实 `BotDSHRemoteRuntime` actor、
  durable event store 和 scripted DSH mux；不是 schema checker 或手写状态副本。
- **Exact commands.** 见 §7，结果按实际运行填写。
- **剩余风险.** 切换进行中与同一 Task 的终态唤醒并发时仍有既有的 actor 重入窗口；本单保证切换
  完成后的唤醒语义。未验证真实模型、真机、断电/掉电、Android/HarmonyOS。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| bot-epoch-task-wake-v1 | task-wake contract owner | 修复 PR #117 记录的纪元切换后旧父会话唤醒丢失 | Swift 宿主、P26 spec |

## 6. 实现摘要

- `BotDSHRemoteRuntime` 在启动恢复时从 `runtime.started`（本 Bot、`kind=chat`）重建
  `mainSessionEpochs`；`recordRuntimeStarted` 和成功的纪元切换继续补充该集合。
- 三处父唤醒（完成、拒绝、Worker 重启中断）统一经过 `parentWakeSessionId(for:)`：只有 owner 是本
  Bot 前一主会话时改用当前主会话。
- `ownedTask` 的父会话校验增加“当前主会话是原父会话的纪元继任者”这一条；原父会话和其他会话的
  判定保持原样。
- 不修改 Task 自身会话、`persistedTask` 形状或任何事件类型。

## 7. 验证（2026-11-12，task-wake worktree）

| 命令 | 结果 |
| --- | --- |
| `swift build --disable-sandbox` | PASS（Build complete） |
| `swift test --disable-sandbox --filter 'PhoneDSHBotTests'` | PASS（569 tests, 0 failures；含新增 `BotTaskEpochWakeTests` 5 个与既有 `BotTaskApprovalPauseTests` 3 个） |
| `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（bot v1 全向量；v2 一并 PASS） |
| `python3 spec/tools/bot/check_golden.py --root .` | PASS（31 files, 16 upstream, 15 overlays） |
| `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS（phone-spec 14s、phone-cross-tree 16s；CI GATE: PASS） |
| `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --results /tmp/task-wake-selftest` | FAIL：17/18 PASS；`BOT-SELFTEST-PROACTIVE` 在 `advance_clock` 等待 due routine 超时。该失败在把 `BotDSHRemoteRuntime.swift` 临时还原为 `de47c0ee` 后同样复现，故与本单无关，未修。另：base `de47c0ee` 的 eval harness 缺少 `BotUIFormat.swift` 符号链接，首次运行在编译期失败；本次用临时（未提交）符号链接才跑通 harness，见报告。 |

未验证：真实模型 E2E、真机、断电/掉电、Android/HarmonyOS（无 Bot runtime）。
