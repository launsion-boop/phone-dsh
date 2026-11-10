<!-- SPDX-License-Identifier: MIT -->

# Bot 回合来源（turn origin）契约冻结（P26/P27）

```yaml
change: PC-20261110-bot-turn-origin
contracts: [P26, P27]
status: frozen
breaking: false
version_decision: Contract freeze only. No wire field, schema enum, persistent format or upstream golden changes. source.rpcId prefixes become normative classification input; unknown or absent prefixes stay visible with the lowest-trust memory source (agent-message), so old readers, old session logs and old data keep working while WP4 implements producer and consumer against this revision.
base: 31c0cab73058e801fac1a145c7f6201d7428d5d2
contract_revision: spec/bot/v1/README.md@turn-origin-v1 + spec/bot/v1/golden/turn-origin.phone.json@turn-origin-v1
```

Protocol impact: P26, P27; P25: none — `event-envelope.schema.json`、`dshbot-pin.json` 和事件 envelope 未改，只有离线 golden 清单校验器增加一个显式注册的手机专属向量。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 宿主已经在 `session/prompt` 的 `requestId` 里编码了 routine、Task、held 和用户动作等来源，DSH 会把它记录为 `user/message` 事件的 `data.source.rpcId`，但 phoneDSH 从未把这组前缀登记成契约。结果是：隐藏回合仍靠消息文本 `[SAND_HIDDEN_PROMPT]` 判断；Bot 间即时消息用发送方工具调用的裸 `callId` 当 `requestId`，在目标 Bot 看来与用户消息相同，按会话类型被记成 `user-turn`，可以写共享的 `user` 范围和 `profile` 层。本变更只冻结判定规则、正反向量和嵌入文本规则；WP4 负责按此修订实现生产方和消费方。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s0-wp0`（分支 `s0/wp0-contract`）依 AGENTS.md §3.1 产出 contract freeze。contract owner 只改 `spec/bot/v1/**`、`spec/tools/bot/check_golden.py`（必要的手机专属向量登记支持）和本变更单；不改任何生产代码。
- **Owning contract / schema / fixtures.** P26 `spec/bot/v1/README.md` §4.1（新增回合来源与嵌入文本）、§5（投影判定）、§8.1（覆盖文件）；`spec/bot/v1/golden/turn-origin.phone.json`；`spec/bot/v1/tools/validate_vectors.py`；`spec/bot/v1/export-manifest.json`。没有新增 schema：`source.rpcId` 是 DSH 既有字段，本变更只登记 phoneDSH 如何解释它。
- **受影响 producer / consumer.** Swift 宿主 `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`（生成 `requestId`，并在 WP4 消费回合来源）、`Sources/PhoneDSHBot/Team/BotTeamTools.swift`（`SendToAgent` 的 `requestId`）、`Sources/PhoneDSHBot/Rows/BotSessionLogProjection.swift` 与 App Bot 目录的 `BotRuntimeComposition.swift`／`BotLiveTurn.swift`（投影和投递）；Worker `plugins/bot-runtime/src/{steering,stream-forward}.ts`（隐藏判断）。Kotlin、Rust、firmware 没有 Bot 会话，不在本轮。

## 2. 代码依据（基线 `31c0cab73`）

### 2.1 DSH 把 `requestId` 记录为 `source.rpcId`

- `/private/tmp/dsh-0.2.2/packages/api/session-controller/src/commands.ts:304` 的 `prompt(request, source)` 接收调用方构造的 `source`；`:542` 的 `hasPromptRequest` 在 `user/message` 事件上按 `source.kind === 'user' && 'rpcId' in source && source.rpcId === requestId` 做幂等匹配（`:545`、`:552`）。
- 同一 checkout 的 `packages/api/session-controller/src/types.ts:398` 定义 `'user-rpc': { kind: 'user'; rpcId: SessionRequestId; clientTimeZone?: string; principal?: Principal }`。因此 `source.rpcId` 是 DSH 已有字段，不是本变更新增的 wire 字段；`source.kind` 仍是 `user`。
- 结论：`session/prompt` 的 `requestId` 进入 session log 的 `user/message.data.source.rpcId`，可作为回合来源的唯一判据。

### 2.2 宿主现有的 `requestId` 前缀（逐条核实）

| 位置 | 代码 | 现况 |
| --- | --- | --- |
| `Sources/PhoneDSHBot/Rows/BotRemoteActionPlanner.swift:71` | `"user-action:\(action.nonce)"` | 用户动作的幂等键 |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:1067` | `requestId ?? "bot-\(UUID().uuidString.lowercased())"` | 默认可见 chat 回合 |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:211` | `deliveryRequestId(prefix: "held", items:)` | 回合开头有 held 块时替换 requestId，前缀为 `held:` |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:350` | `"routine:\(request.runId)"` | routine 唤醒，`hidden: true` |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:479` | `"task-turn:\(taskId)"` | Task 子会话回合，`hidden: true` |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:504` | `"task-settled:\(taskId)"` | 子代理完成唤醒父对话，`hidden: true` |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:589` | `"task-interrupted:\(taskId)"` | Worker 重启后中断唤醒父对话，`hidden: true` |
| `Sources/PhoneDSHBot/Team/BotTeamTools.swift:117` | `let requestID = context.callId` | Bot 间即时消息，**没有前缀** |
| `examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift:831-832` | `unit.remote.sendUserMessage(request.promptText, requestId: request.requestId)` | Bot 间即时消息经可见用户回合送入 |

与总文档逐条对照：`BotDSHRemoteRuntime.swift` 的 `:211`、`:350`、`:479`、`:504`、`:589`、`:1067` 和 `BotTeamTools.swift:117`、`BotRuntimeComposition.swift:831-832` 均一致。总文档的「现状」段落只列了 `BotDSHRemoteRuntime.swift` 的六处，另外两处补充为：`user-action:` 的实际构造在 `BotRemoteActionPlanner.swift:71`，`held:` 的实际构造在 `BotDSHRemoteRuntime.swift:211` 的 `deliveryRequestId`。没有发现需要推翻总文档的差异。

### 2.3 现况为什么产生错误信任

- `Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift:74-81` 的默认映射按调用 principal 的会话类型推导记忆来源：`.chat → .userTurn`，`.task → .task`，`.routine → .routine`，team／proactive／watchdog → `.hiddenWake`；生产装配没有传入别的映射。
- 同文件 `:525-527` 只对 hidden 文本会话和 held 会话做降级（held → `agentMessage`），`agent:` 尚不存在。Bot 间即时消息是普通 chat、非 hidden、没有 held 标记，因此被记成 `user-turn`。
- `Sources/PhoneDSHBot/Memory/BotMemory.swift:257` 的 `memory-source-boundary` 只拒绝非 `user-turn` 写 `scope:"user"` 或 `tier:"profile"`；只要来源被误判成 `user-turn`，共享记忆就能写入。WP4 修复的是来源判定，边界本身不放宽。
- 隐藏回合目前靠文本：`plugins/bot-runtime/src/steering.ts:8`、`stream-forward.ts:34`、`Sources/PhoneDSHBot/Rows/BotSessionLogProjection.swift:201`、`examples/probe-app/PhoneDSHProbe/Bot/BotLiveTurn.swift:48` 都检查 `[SAND_HIDDEN_PROMPT]` 前缀。`BotSessionLogProjection.swift:706` 的 `isInjected` 和 `:711` 的 `stripHeldMessages` 也按文本判断。

## 3. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 判定输入 | 消息文本前綴或会话类型 → DSH `user/message.data.source.rpcId`（`source.kind == "user"` 的 `user-rpc`）。只在 offset 0 做 ASCII 大小写敏感匹配；前缀后必须至少有一个非空白字符，否则按「其他或缺失」。 |
| `user-action:`、`bot-` | 未登记 → 用户回合：可见（`hidden=false`）、无 held 块、记忆来源 `user-turn`。 |
| `held:` | 未登记 → 用户回合但开头有 held 块：可见、`held=true`、记忆来源 `agent-message`（沿用现有 held 降级）。只有该来源允许剥 held 块。 |
| `agent:`（新增） | 未登记，且 WP4 前 Bot 间消息用裸 `callId` → 其他 Bot 的即时消息：可见、无 held 块、记忆来源 `agent-message`。这是 phoneDSH 新增的 requestId 前缀，不新增 DSH `source.kind`。 |
| `routine:` | 代码有前缀但未登记 → routine 唤醒：隐藏、无 held 块、记忆来源 `routine`。 |
| `task-turn:` | 代码有前缀但未登记 → Task 子会话回合：隐藏、无 held 块、记忆来源 `task`。 |
| `task-settled:`、`task-interrupted:` | 代码有前缀但未登记 → 子代理结束唤醒父对话：隐藏、无 held 块、记忆来源 `hidden-wake`。 |
| 其他或缺失 | 未定义 → 未知：可见（`hidden=false`，不静默隐藏）、无 held 块、记忆来源 `agent-message`（最低信任）；不能写 `scope:"user"` 或 `tier:"profile"`，沿用 `memory-source-boundary` 拒绝。 |
| `hidden` / `held` 不变量 | 新登记 → `hidden` 当且仅当来源是 `routine`／`task`／`task-wake`；`held` 当且仅当来源是 `held`。 |
| 嵌入文本 | 只有 `[agent]` 分支和部分 held 字段转义 → 宿主拼进 prompt 的所有非宿主文本按 `HeldMessages.escapedHeldField` 转义：`\`、换行、回车、制表、`<`、`>`、`&`、U+2028/U+2029、控制／格式字符都变成单行 `\uXXXX`／`\n` 形式。适用位置：`HeldMessages.block` 的 routine／subagent／card-dismissed／device-task／agent 分支；`task-settled`、`task-interrupted` 子代理唤醒 prompt 的标题、状态、task id 与结果摘录。普通用户消息正文和 agent 消息正文是消息内容，不改写。 |
| 相关性／幂等 | `requestId` 仍是 DSH 回合的幂等键。WP4 把 Bot 间消息改为 `agent:<发送方 callId>` 后，必须保留旧 `agent.comm` 事件的幂等查找：旧记录里是裸 `<callId>`；新代码不能因为前缀变化对同一次工具调用再写一条 outbound 行或重复投递。 |
| 兼容 | 没有新增／删除字段、enum、错误码或版本号；不改上游 dsh-bot golden。旧 session log 里宿主发起的 routine／Task／唤醒回合本来就有前缀，重放仍隐藏；旧 Bot 间消息的裸 `callId` 按未知处理（可见、`agent-message`）。 |

自检（`spec/README.md` §5.1）：没有第二种表达、没有新增 wire 字段、没有放宽 `memory-source-boundary`、没有新增 enum 值到 `source.kind`；未知值规则是「可见、最低信任」，比现状更严格；没有删除或重用既有名称。

## 4. 共享向量与校验

- 新增 `spec/bot/v1/golden/turn-origin.phone.json`，`"upstream": []` 表示没有 dsh-bot 同名导出文件。向量字段 `origin` 固定为 `user`、`held`、`agent`、`routine`、`task`、`task-wake`、`unknown` 之一；`hidden` 当且仅当 `origin` 为 `routine`／`task`／`task-wake`，`held` 当且仅当 `origin` 为 `held`。`valid` 覆盖表中每一行（`task-settled:` 与 `task-interrupted:` 分开）；`invalid` 覆盖空串、每个前缀只有前缀、大小写不同、前缀出现在中间／带前导空白、纯空白 payload、缺失／`null`、未知相似前缀，以及 WP4 前的裸 `callId`／`toolu_` 形态。所有 `invalid` 必须解析为 `unknown`（可见、无 held、`agent-message`），不是解析失败。
- `validate_vectors.py` 用参考解析器逐条比对 `origin`／`hidden`／`held`／`memorySource`，强制 `held` 与 `hidden` 的不变量、前缀覆盖和边界覆盖；内部跑 7 个 mutation（改记忆来源、改隐藏、让 unknown 隐藏、删 `rpcId`、重复用例名、删前缀覆盖、删边界覆盖），只要校验器没有拒绝就失败。
- `check_golden.py` 原来要求每个 `.phone.json` 都有同名上游；本变更只对它显式登记的 `turn-origin.phone.json` 允许 `upstream: []`，跳过 append-only 合并，仍校验 `vector`、`source.checkout`、`delta`、`files`／`sha256` 和 `phoneOverlays` 清单。`validate_vectors.py` 的 `check_overlays()` 做同样的显式允许。
- `export-manifest.json` 把新文件列入 `files`、`phoneOverlays` 与 `sha256`；导出器 `--out` 仍会把所有 `.phone.json` 原样保留，重跑导出不会覆盖本文件。

## 5. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 session log 的 routine／task-turn／task-settled／task-interrupted 回合带原前缀，新读者仍隐藏；旧 routine／Task 的记忆来源不变。旧 Bot 间即时消息的 `source.rpcId` 是裸 `callId`，新读者按未知处理：可见、`agent-message`，不能写共享 `user`／`profile`。旧 `agent.comm` 的 outbound 行仍按裸 `callId` 存放，WP4 必须同时查 `agent:<callId>` 与旧裸 `<callId>` 以保持幂等。 |
| new → old | 旧读者不读新向量、不读 `agent:`，仍按会话类型和文本前缀工作；`agent:` 回合对旧读者是普通可见用户回合，行为不比现状差。没有新增 wire 字段或版本，旧 reader 不会解析失败。 |
| new → new | 生产方写 `agent:<callId>`，消费方按同一表解析；`held:` 由 `deliveryRequestId` 继续生成，`routine:`／`task-*` 不变；`BotMemory` 仍按 `memory-source-boundary` 拒绝 `agent:`／unknown 的 `user`／`profile` 写入。共享向量由 Python、Swift、TS 读取。 |
| persisted old data → new／rollback | BotEvent、session log、held inbox 的持久化形状不变；没有迁移。回滚到旧 App 后，旧代码仍按会话类型／文本判断，不会因为新前缀而崩溃；`agent:` 回合会退回「可见用户回合」的旧行为。旧 `agent.comm` 的裸 requestId 保留，不回写。 |

- 版本决定：不升 P26／P27 版本，不新增 wire／schema 版本；这是语义收窄和既有字段的登记，不是新格式。`source.kind` 仍由 DSH 定义，不新增取值。
- bundle／image 顺序：WP4 的 Swift 与 Worker 插件消费方应在同一变更内更新；旧 Worker 不认识 `agent:` 也不影响 DSH 会话，旧 App 仍可读旧前缀。没有 native artifact 或数据库迁移。
- `target`／`draft` 差异：本契约仍为 `target`；WP4 的运行时证据（`swift test`、plugins 测试、模拟器 E2E、E08）齐备后才可改为 `implemented`。

## 6. 分工、路径与验收

路径纪律：各工作包只改自己的独占路径；需要跨包改动时先写 `CONTRACT CHANGE REQUEST`，不得在本分支打补丁。

| 工作包 | 独占路径 | 验收命令／证据 |
| --- | --- | --- |
| WP1 评测运行器 | `scripts/ci/bot-e2e/**`（新增 `eval.sh`、测试源、目录 schema）；必要时 `scripts/ci/scenario_batch.py`、`scenario_evidence.py` 及其测试。不改 `Sources/PhoneDSHBot/**` 和 App Bot 目录。 | mock 上游自检场景通过，且人为改坏每种断言后自检失败；`bash scripts/ci/check.sh --only phone-gate-contracts,phone-hygiene,phone-license`；`bash scripts/ci/bot-e2e/run.sh --simulator --scenario production-composition`；真实模型最小场景的 `report.json` 中 `upstream` 为 `real`。 |
| WP3 安全 spike | `docs/research/bot-egress-spike-*.md`、新增测试文件；不改生产代码。 | 四个问题都有「能／不能／未能验证」结论；没有「推断」充当结论；新增测试能在本机重跑。 |
| WP4 回合来源与嵌入文本（依赖 WP0） | `plugins/bot-runtime/src/{steering,stream-forward,turn-origin}.ts`、`plugins/tests/bot-*.test.ts`、`Sources/PhoneDSHBot/Wake/{BotTurnOrigin,WakeInbox}.swift`、`Sources/PhoneDSHBot/Rows/BotSessionLogProjection.swift`、`Sources/PhoneDSHBot/MCP/{BotDSHRemoteRuntime,BotMCPRuntime}.swift`（后者只动记忆来源推导）、`Sources/PhoneDSHBot/Team/BotTeamTools.swift`（只动 `requestId` 构造）、App Bot 目录的 `BotLiveTurn.swift` 和 `BotRuntimeComposition.swift`（只动 `deliverToAgent`）、`Tests/PhoneDSHBotTests/{Rows,Wake,MCP,Memory,Team}/**`。 | `swift test --filter PhoneDSHBotTests`；`bash scripts/ci/check.sh --only phone-plugins,phone-bundle-fresh,phone-sdk`；`bash scripts/ci/bot-e2e/run.sh --simulator --scenario conversation-card-approval-routine-held`；全仓搜索除 prompt 构造处和测试外没有代码再读 `[SAND_HIDDEN_PROMPT]`；收尾评测 E08 通过。 |
| WP6 persona 如實化 | `plugins/bot-runtime/prompts/system-prompt{,.zh-CN}.md`、`plugins/bot-runtime/src/prompt/assemble.ts`、`plugins/profile/phone.worker.cordis.patch.yml`（仅 `personaPrefix` 段）、`plugins/tests/bot-persona.test.ts`。 | `node plugins/bot-runtime/scripts/check-prompt.mjs`；`bash scripts/ci/check.sh --only phone-plugins,phone-bundle-fresh`；收尾评测不退步（集成者判定）。 |
| WP7 persona 消融（依赖 WP2；WP6 合入后） | `plugins/bot-runtime/prompts/**`、`plugins/profile/phone.worker.cordis.patch.yml`（仅 `personaPrefix` 段）、`plugins/tests/bot-persona.test.ts`、`docs/research/bot-persona-register-*.md`。 | 登记表齐全；删节后在集成分支重跑全部场景不退步；`check-prompt.mjs` 和 plugins 测试通过。 |

WP4 的运行时验收还必须覆盖本契约的 7 条回归：Bot 间即时消息写 `user`／`profile` 被拒绝、写自己的 `agent` 成功且来源 `agent-message`；真实用户回合行为不变；用户消息以 `[SAND_HIDDEN_PROMPT]` 开头仍显示／steer／推流；用户消息含完整 held 标签时气泡原样显示；routine 或子代理结果含 `</held_agent_messages>` 与换行加 `- [agent]` 时块结构不破；既有隐藏回合仍隐藏；旧 session log 重建结果与改动前一致（旧 Bot 间消息除外，按本单兼容说明处理）。

## 7. 实测记录（本契约修订）

环境：worktree `s0-wp0`，分支 `s0/wp0-contract`，基线 `31c0cab73058e801fac1a145c7f6201d7428d5d2`；DSH 只读 checkout `/private/tmp/dsh-0.2.2`。

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Bot 向量 | `python3 spec/bot/v1/tools/validate_vectors.py` | PASS：8 个有效回合来源用例、27 个无效用例、7 个 mutation 自检 |
| golden 清单 | `python3 spec/tools/bot/check_golden.py --root .` | PASS：28 files / 22 upstream / 6 overlays |
| 协议 CI（合并命令） | `CI_PROTOCOL_BASE=31c0cab73 bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | `phone-spec` PASS、`phone-cross-tree` PASS；`phone-p0-conformance` FAIL。失败项是既有 `files` missing-action `完成` 的 page-structure divergence，不在本 diff；在干净的 `HEAD`（`git archive` 到 `/tmp/s0-wp0-head`）上运行同一 checker 也得到相同 FAIL。没有因此放宽 baseline。 |
| 协议 CI（分开复跑） | `CI_PROTOCOL_BASE=31c0cab73 bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS：`phone-spec` 22s、`phone-cross-tree` 33s；详见交接报告。 |
| 交付检查 | `bash scripts/ci/check.sh --only phone-license,phone-hygiene` | `phone-license` PASS；`phone-hygiene` FAIL，全部 finding 位于本 diff 未改的既有文件，本 diff 的 6 个文件用同一 `hygiene.scan_line` 检查为 0 finding。没有添加 allowlist。 |
| 外部 mutation（向量） | 复制 `spec/` 到 `/tmp/s0-wp0-mutation`，把 `turn-origin.phone.json` 的一个有效用例 `memorySource` 改错后运行同一校验器 | 复制件按预期 FAIL（`memorySource does not match origin 'user'`）；仓库原件仍 PASS。 |
| 外部 mutation（清单） | 复制 `spec/` 到 `/tmp/s0-wp0-golden-mut`，分别从 `phoneOverlays` 删除新文件、改错 `sha256` 后运行 `check_golden.py` | 两次都按预期 FAIL（`upstream + phoneOverlays != files`、`sha256 mismatch`）。 |

Not verified: 没有运行 Swift、plugins、模拟器或真实模型；WP4 的实现和 E08 尚未发生。本单只冻结契约。`check_golden.py --checkout` 未运行（没有 dsh-bot checkout），因此只证明离线清单/摘要/覆盖语义，不宣称“上游 = 原样导出”。

## 8. 剩余风险与未决项

- `RoutineWakeBuilder` 的 routine 唤醒 prompt 仍把 routine 名称和保存的指令直接拼进 `<user_query>`；本契约的嵌入文本规则只覆盖 held 块和子代理唤醒 prompt（WP4 的路径范围）。如果审查认为 routine 唤醒 prompt 也属于「宿主拼进 prompt 的非宿主文本」，需要另行分配 `Sources/PhoneDSHBot/Wake/RoutineWake.swift` 并补一条 WP4 验收；本单不扩大 WP4 路径。
- `sendHiddenInteraction` 当前没有生产调用方；如果未来用它发隐藏回合，必须改用表中的隐藏前缀，不能依赖 `hidden:` 参数或文本前缀。
- 旧 `agent.comm` 事件的 `requestId` 是裸 `callId`。WP4 必须做双键查找或读取时归一化，否则同一次工具调用的重放会产生第二条 outbound 行；本单在 §3 与 §5 写明，但没有生产代码可验证。
- `turn-origin.phone.json` 没有 schema；形状由 `validate_vectors.py` 手工校验。WP4 的 Swift／TS 读取器应消费同一文件，而不是复制前缀表；如果实现发现字段不够，按 §3.3 写 `CONTRACT CHANGE REQUEST`，不在本地加字段。

## 9. 修订记录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `turn-origin-v1` | Coordinator `s0-wp0` | 首次冻结回合来源表、正反向量与嵌入文本规则；处理「phone-only `.phone.json` 没有上游」的登记冲突（只在 `check_golden.py` 显式允许 `turn-origin.phone.json`）。 | Swift 宿主、Worker 插件、App Bot 目录、spec/CI owner；WP4 实现方 |
