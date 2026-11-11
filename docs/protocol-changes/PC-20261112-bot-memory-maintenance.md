<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-bot-memory-maintenance — 后台记忆整理（maintainer，S3 后半）

## 0. 摘要（机器可读）

```yaml
change: PC-20261112-bot-memory-maintenance
contracts: [P25, P26, P27, P09, P18, P16]
status: frozen
breaking: false
version_decision: Additive durable event types, principal kind, memory source kind, ledger purpose and an optional UpdateMemory argument. The memory document/write/read wire shapes are otherwise unchanged; old readers ignore the new types/fields, old data stays readable, and rollback simply stops running the maintainer. No version field or second envelope is introduced.
base: 724f47a89
contract_revision: spec/bot/v2/README.md@PC-20261112-bot-memory-maintenance-r3 + spec/ui/v1/pages/bot-info.md@PC-20261112-bot-memory-maintenance
```

Protocol impact: P25 — additive `memory.maintenance_started` / `memory.maintenance_finished` /
`memory.maintenance_rolled_back` durable event types, `maintainer` principal kind, and a
`memory-maintenance` LLM-ledger purpose; P26 — maintainer preset surface, maintenance batch data,
`UpdateMemory.marked_contradiction`, `memory.review_requested` / `memory.review_resolved` usage;
P27 — one held inbox item kind `memory-maintenance` reuses the existing held-item envelope;
P09 — memory page "上次整理" card, batch rollback and the maintenance switch; P18 — UserDefaults
key `phone-dsh.bot.memory-maintenance.v1`; P16: none — no `PDSH_*` env, init frame or Worker URL
change.

## 1. 识别与角色

- **Trigger → 现状 → 期望.** S2 之后记忆是文档树，但没有任何人回头对照原始记录核验；写错的记忆
  只会一直留着。方案 §3.4 / §6 决定 2 要求：独立的后台 maintainer 会话直接整理（不是只提建议），
  版本前提保证单一作者，用宿主机械检查和整批回滚控制风险，默认关闭、凭评测证据开启。
- **Coordinator / contract owner / implementer.** 本单元 `s2-s3m`（分支 `s2/s3-maintainer`）
  兼任三角色；先在 `spec/bot/v2`、`spec/bot/v1`、`spec/ui/v1` 冻结，再实现 Swift 宿主、
  Worker preset 和 App 两端。
- **Owning spec / schema / fixtures.** `spec/bot/v2/README.md` §4；新增
  `memory-maintenance.schema.json`、`memory-maintenance-start.schema.json`、
  `memory-maintenance-rollback.schema.json`；`memory-write-request.schema.json` 的
  `marked_contradiction`；`golden/memory-maintenance.json`；`golden/memory-write.json` 的
  maintainer boundary cases；`spec/bot/v1/event-envelope.schema.json` 与
  `golden/event-envelope.phone.json`；`llm-ledger.schema.json`、
  `model-purpose-policy.schema.json` 与 `golden/llm-ledger.phone.json`；
  `spec/ui/v1/pages/bot-info.md`；P18 key 登记在 `spec/README.md` §3.2。
- **受影响的 producer / consumer.** Swift `Sources/PhoneDSHBot/{Memory,MCP,Gateway,Journal,Ledger}`；
  Worker `plugins/lifecycle-gate`（maintainer-scope）、`plugins/profile`（preset）、
  `plugins/bot-runtime`（preset 选择）；App `examples/probe-app/PhoneDSHProbe/Bot/**`
  （控制器接线、记忆页、设置开关）。Android 与 HarmonyOS 没有 Bot runtime，没有实现端。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| 会话 | 没有维护会话 → 宿主签发 `gb-maintainer-<…>`，principal kind `maintainer`，hidden turn；无法写用户行、不能派 Task。`spec/bot/v2` §4.1 |
| preset | 只有标准 Bot preset → `phone-bot-maintainer`：`tools.restrict` allow-list + guard，只留 `bash`（实参仅 `phone record search/read`）、`UpdateMemory`、`ReadMemory`、`RecallMemory`；`plugins/profile` 与 `plugins/lifecycle-gate/maintainer-scope`。会话控制器在发布 `agent/created` 前就锁定 preset，所以宿主在 `session/create` 请求里显式带 `agentPreset`，并核对返回值；不一致 fail-closed。另加全局 `maintainer-guard`（按 `gb-maintainer-` 前缀）作为执行点兜底。 |
| 写入规则 | `source.kind` 只有 user-turn/hidden-wake/agent-message/routine/task → 新增 `maintenance`；maintainer 写 `user/` 不套 user-turn 来源，但仍需至少一条 `user` 证据且必须是主 Bot；证据引用已抹除事件时按 S6 返回 `record_erased`，不降级 trust。`spec/bot/v2` §1.3、§1.5、§4.2 |
| 矛盾标记 | 无轻量入口 → `UpdateMemory.marked_contradiction: true`；写入成功后宿主写 `memory.review_requested`，整理批次处理后写 `memory.review_resolved`。 |
| 批次 | 无 → durable `memory.maintenance_started` / `memory.maintenance_finished` / `memory.maintenance_rolled_back`；每个写入事件 `correlationId = memory-maintenance:<batch_id>`；批次可见、可整批回滚。 |
| 机械检查 | 无 → 四个宿主检查：引用可解析、索引 ≤1,500、文档不超证据原文、单次 ≤12 文档/24,000 scalar；不过则整批回滚。`spec/bot/v2` §4.4 |
| 触发/候选 | 无 → 写入数 >40、索引 ≥1,350、未处理 contradiction；候选 = inbox/contradiction/index/most-read/most-changed/least-verified/overlong，最多 12。`spec/bot/v2` §4.6 |
| 预算 | 无 → 单次 32,000 token、每 UTC 日 96,000 token；账本 purpose `memory-maintenance`。 |
| 让路 | 无 → 主对话忙/待审批不跑；用户新回合取消运行，已提交写入保留，仍跑检查。 |
| 多 Bot | 无 → 每个 Bot 只整理自己的 `agent/`；共享 `user/` 只由主 Bot 的 maintainer 写。 |
| 开关 | 无 → 默认关；P18 key `phone-dsh.bot.memory-maintenance.v1`。 |
| UI | 记忆页只有两个根的文档树 → 增加默认关闭的开关、最近一次批次卡片和整批回滚。 |
| 事件/账本 | P25 principal kind 与 ledger purpose 枚举 → 各增一个 additive 值。 |

自检（`spec/README.md` §5.1）：没有第二种 envelope 或别名字段；新增事件类型/枚举值都是 additive，
旧 reader 忽略未知值；没有放宽仍被两端读取的输入；失败路径（检查不过、预算超限、回滚冲突、
非主 Bot 写 user/）都 fail-closed 并留下 durable 记录。

## 3. 兼容性

| Producer → Consumer | 处理 |
| --- | --- |
| old → new | 旧事件/文档没有 maintenance 字段或事件，新 reader 只按事件类型读取；没有 maintenance 事件时记忆页不显示批次、开关取缺省关。旧 `memory.document_written` 仍按原 data 解码。 |
| new → old | 旧 App 不认识新事件类型和 `source.kind = maintenance`；P25 未知 durable 事件的读取规则保持不变，旧 App 不会把新事件当必需。回滚到旧 App 后 maintainer 不再运行，已写文档仍留在文档树中可读。 |
| new → new | 批次写入用 correlationId 归组；机械检查只看 durable 事件；回滚用 S2 restore 产生新版本；并发的其他写者会让该文档回滚冲突并被报告，不覆盖。回滚目标若已被 S6 物理抹除，该路径跳过并记入 `conflicts`，不复活原文；同一批其他路径照常恢复。 |
| persisted old data → new／rollback | 没有 SQLite schema 变化；没有新表。旧记忆历史版本可直接作为批次回滚目标。 |

- 版本决定：不升 v2 schema 版本、不改 P25 envelope 形状；新增的是 `target` 契约里的 additive 表面。
- bundle／image 顺序：Worker 需要重建 bundle 才拿到 maintainer preset、全局 guard 和 plugin 排布；宿主侧先认领
  `maintainer` principal，旧 Worker 不认识时 `phone/botClaimSession` 会失败关闭（整理不运行，主对话不受影响）。
  旧 Worker 也不会在 `session/create` 返回值里报告 `agentPreset`；maintainer 会话因此拒绝运行，这是有意的
  fail-closed，不会退化为用户面工具面。
- `target` 差异：真机后台（`processing` 窗口）不实现，标 NOT_VERIFIED；真实模型评测由主会话统一跑。

## 4. 分工与证据

- 独占路径：`spec/bot/v2/**`、`spec/bot/v1/{event-envelope,llm-ledger,model-purpose-policy}.schema.json`、
  `spec/bot/v1/golden/{event-envelope.phone,llm-ledger.phone}.json`、`spec/bot/v1/export-manifest.json`、
  `spec/ui/v1/pages/bot-info.md`、`spec/README.md`、`docs/protocol-changes/**`、
  `Sources/PhoneDSHBot/{Memory,MCP,Gateway,Journal,Ledger}/**`（新 principal/事件/purpose 与维护编排）、
  `plugins/{lifecycle-gate,profile,bot-runtime}/**`（preset/guard/选择）、
  `examples/probe-app/PhoneDSHProbe/Bot/**`、`scripts/ci/bot-e2e/**`、对应测试。
- 共享 fixtures：`memory-maintenance` 的批次/检查/回滚/候选/跨 Bot 向量；`memory-write` 的
  maintainer boundary cases；`event-envelope.phone` 的 maintainer principal 与三类事件；
  `llm-ledger.phone` 的 maintenance purpose。
- 各端真实测试：Swift `Tests/PhoneDSHBotTests/Memory/MemoryMaintenanceTests.swift` 驱动真实
  `BotMemory`/`BotMCPRuntime`/SQLite 事件库和 fake turn runner；Python 参考解析器；
  plugins `tests/bot-maintainer-preset.test.ts`；App 通过 mock eval 场景与 UI 截图验证。
- 命令 → 结果见交接报告；未验证：真实模型 E2E、真机后台窗口、Android/HarmonyOS 实现。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| PC-20261112-bot-memory-maintenance | coordinator | S3 总方案 §3.4 / §6 决定 2；maintainer 与批次 | Swift、Worker preset、iOS UI、spec checkers |
| PC-20261112-bot-memory-maintenance-r2 | coordinator | 实测发现 `agent/created` 时 preset 已锁定：改为 `session/create` 指定 `agentPreset` 并核对；新增全局 `maintainer-guard` 与 `tools/change` 后的可见面收敛；`bash` 实参限制 | Swift MCP、Worker profile、lifecycle-gate、eval selftest |
| PC-20261112-bot-memory-maintenance-r3 | coordinator | 与 S6 集成分支合并：维护写入引用的 `record://event` 已被物理抹除时返回 `record_erased`（不降级 trust）；整批回滚遇到已抹除载荷跳过并记 `conflicts`，不复活原文；maintenance 事件沿用 P25 v3 头/载荷存储 | Swift `BotMCPRuntime`/`BotMemoryMaintenance`、v1/v2 向量与 Swift 测试 |
| PC-20261112-bot-memory-maintenance-r4 | s2-int integrator | 与 S3v 合并：maintainer 与 verifier 共用同一受限会话机制（`restricted-session`/`restricted-guard`、创建头核对、`gb-<kind>-` 前缀、volatile 同处排除），旧 `maintainer-guard` 行由单一全局 guard 取代；本节 delta 与语义不变 | Swift 宿主、Worker profile/lifecycle-gate、spec、eval |
