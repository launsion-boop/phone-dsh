<!-- SPDX-License-Identifier: MIT -->

# Bot 会话必须使用 phone-bot preset（P26）

```yaml
change: PC-20261111-bot-phone-preset
contracts: [P26]
status: implemented
breaking: false
version_decision: Additive P26 revision. The ordinary Bot session kinds now send the existing immutable `agentPreset` creation header (`phone-bot`) and verify the returned composition; no wire field, schema, event type, enum value, sequence domain or storage shape is added. Existing sessions are migrated in place with DSH's per-agent `tools.restrict`; a session whose target surface cannot be read fails closed instead of running wider.
base: 82ae59dc5593d0ab20fdee29f1cb37eaf3826eea
contract_revision: spec/bot/v1/README.md@bot-phone-preset-v1
```

Protocol impact: P26; P25: none — no Bot event type, envelope, payload or sequence domain changed;
P27: none — no row, row-batch, user-action or projection shape changed; P16: none — no Worker URL
parameter, `PDSH_*` environment variable or init field changed (the preset header is a DSH
`session/create` argument); P13: none — no plugin Remote method changed; P06: none — the Worker
enforcement uses the existing `agent/created` event and `tools.restrict`, not a new harness event;
P03/P05/P12/P17: none — no controller, gateway, shell or ledger path changed.

## 1. 识别与角色

- **Trigger → 现况 → 期望.** S2 调查发现 `BotDSHRemoteRuntime.requestedPreset(for:)` 对
  `.chat`、`.task`、`.routine` 返回 `nil`，所以 `session/create` 不带 `agentPreset`；Worker 用
  控制器默认 `standard` 并写进不可变创建头。之后 `agent/created` 按 `gb-` 前缀补选
  `phone-bot` 时，已经启动过回合的会话得到 `agent-preset/locked`，于是 Bot 会话一直运行在
  `standard` 面：`subagent`/`subagent_fork` 可绕过 Task 授权子集与独立验证，`schedule_*` 与
  App RoutineMachine 形成第二套调度，另有 `skill`、`plan`/`exit_plan_mode`、原生
  `ask_user_question`、`present` 等 phone persona 未讲授的工具。现期望：新 Bot 会话在
  `session/create` 显式使用 `phone-bot` 并核对返回；升级前创建的 `standard` 会话在不重建、
  不丢对话的前提下被运行时收窄到同一工具面；两道行为都有回归测试与评测工具面断言。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s2-preset`
  （分支 `s2/bot-preset-fix`）兼任，按 AGENTS.md §3.1 先改本变更单与 owning spec，再实现
  Swift 与 Worker 两端，最后跑评测自检。
- **Owning contract / fixtures.** P26：[spec/bot/v1/README.md](../../spec/bot/v1/README.md)
  §2.8（新增“Bot 会话必须使用 `phone-bot`”与“已有会话的兼容”）。没有新增 schema 或 golden；
  现有 `tool-catalog` 的 phone-bot 面不变。
- **受影响 producer / consumer.** Swift 宿主：
  `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`（创建头 + 返回值核对）；
  Worker：`plugins/bot-runtime/src/volatile-context.ts`（对旧 `standard` agent 施加
  `tools.restrict`）、`plugins/lifecycle-gate/src/restricted-session.ts`（复用创建头读取）；
  评测：`scripts/ci/bot-e2e/{catalog.schema.json,eval_catalog.py,selftest.json,catalog.json,EVAL.md}`
  与 harness 断言。profile preset 定义不需要变更：`phone-bot` 已存在且由
  `dshbot-volatile-context.botAgentPreset` 指定。Android/HarmonyOS 没有 Bot runtime，无需跟进。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 新 Bot 会话创建头 | 无（`session/create` 省略 `agentPreset`，控制器默认 `standard`）→ chat/task/routine 的宿主会话发送 `agentPreset:"phone-bot"` 并核对返回值；team/proactive/watchdog 复用这些会话，`requestedPreset` 也映射到同一值以覆盖任何创建路径。缺失或不同都 fail-closed，不运行该回合、不认领会话凭证。verifier/maintainer 的受限创建头不变。 |
| Bot 工具面 | 由 `agent/created` 在首回合前补选 `phone-bot` → 创建头是唯一权威；插件补选只是兼容兜底。`phone-bot` 不暴露 `subagent`/`subagent_fork`、`schedule_*`、`skill`、`plan`/`exit_plan_mode`、原生 `ask_user_question`、`present`、workflow 等。 |
| 已有会话/全局行 | 无迁移（继续 `standard`，且镜像继承 `dsh-base` 全局工具行）→ 每个普通 Bot agent 在创建和恢复时按契约工具集收窄：只保留 `phone-bot` 的 native 工具与 `mcp__phone__` 命名空间，其余用 `tools.restrict` 从可见面移除；同一谓词的 per-agent `tools.guard` 拦截快照之后才注册的名字，`tools/change` 收敛可见面。每次恢复重新施加；restriction/guard 随 agent 作用域销毁解除。没有 scoped tool registry 或当前面为空时 fail-closed。 |
| 评测工具面 | 无 → 新增 mock 模型请求的 `tool_surface` 断言（`present`/`absent`），在 selftest 中登记；它读取 Worker 实际发给模型的 `tools/list`，不是另一份手写清单。产品目录不能在 real 上游下提供该证据，因此不登记，避免把“无证据”当成通过。 |

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old Swift → new Worker | 旧宿主不带 `agentPreset`：`phone-bot` 不存在于创建头，Worker 仍会按 `gb-` 前缀尝试选择；已启动的会话被 `agent-preset/locked` 挡下后走新的运行时收窄。不会因缺少创建头而更宽。 |
| new Swift → old Worker | 旧 Worker 若不回显 `agentPreset`（或回显不同），新宿主 fail-closed 并给出明确错误，不在错误 preset 上运行 Bot 回合。Worker bundle 与 App 同包发布，正常升级不会遇到。 |
| old data → new | 升级前持久化的会话头是 `standard`；同一 session log、对话和 `record://` 引用都保留。新 Worker 每次恢复该 agent 时重新收窄可见面，不重建 session、不迁移会话文件。主对话保持连续；Task/routine 会话同样收窄，无需重建。 |
| new → new | Swift 在 `session/create` 写入 `phone-bot`；Worker 用 `agentPresets.acquireScope`/`tools.restrict` 与同一批全局工具集合推导兼容面；评测用 mock 上游的 `tools/list` 断言端到端一致。 |
| rollback | 回滚到旧 App/旧 Worker：旧代码不再发送/收窄，会话回到旧行为（可能再次使用 `standard`），但不破坏会话、事件或记忆。没有 schema 或存储版本需要回滚。 |

- 版本决定：不升任何 schema/wire 版本；`agentPreset` 是 DSH 既有 `session/create` 字段，
  `tools.restrict` 是既有 DSH 作用域机制，`tool_surface` 只是评测断言。
- bundle／image 顺序：Worker 插件与 Swift 宿主必须一起重建（`phone-bundle-fresh`）；
  不存在“新宿主 + 旧 Worker”可接受的生产组合，因为新宿主会核对返回值并 fail-closed。
- `target`／`draft` 差异：P26 仍为 `target`；本单不声称真实模型或真机端到端。

## 4. 测试与证据

- Swift：`PhoneDSHBotTests` 断言 chat/task/routine 三个创建头都是 `phone-bot`，且 Worker
  回显 `standard` 时 `session/create` 失败、没有 claim、没有回合。
- Worker 插件：`plugins/tests/bot-preset-narrowing.test.ts` 用真实 `tools.restrict`/guard
  语义：新的 `phone-bot` 会话与恢复的 `standard` 会话都只剩契约面 + App MCP；基座全局
  `subagent`/`skill`/`working_directory`/`read_image`/MCP resource 不可见也不可执行；
  `schedule_create`/`exit_plan_mode` 同理；其他会话不受影响；快照之后注册的基座工具被
  `tools/change` 隐藏且 guard 拒绝，晚到的 App MCP 工具保持可见可执行；没有 scoped tool
  registry 或空面时 handler 拒绝回合。
- 评测：`selftest.json` CORE 断言主 Bot 的模型面含 `bash`/`read`/`todo_write`/
  `mcp__phone__UpdateMemory` 且不含标准面工具；EXPECT-FAIL 反向断言。`eval_catalog_test.py`
  校验 `tool_surface` 形状。selftest 的 mock 上游能提供请求 body；real 上游不提供，故产品
  目录不登记该断言（不作为“通过”）。
- 残余风险：可见面由 `tools/change` 收敛，执行面由 allow 谓词 guard 保证；如果将来
  `phone-bot` 新增 native 工具，必须同时更新 `PHONE_NATIVE_TOOLS`（现有测试会因 preset 与
  persona 不一致而失败）。晚到的非 App MCP 全局工具在极端竞态下可能短暂出现在模型面，
  但 guard 会拒绝执行，下一次 `tools/change` 会隐藏它。收窄失败时该回合 fail-closed；当前
  没有自动“开新会话”的宿主 notice 路径，因为收窄机制本身可用。
