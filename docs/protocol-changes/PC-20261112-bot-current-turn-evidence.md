<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-bot-current-turn-evidence — 当前用户回合的可引用证据（P26）

```yaml
change: PC-20261112-bot-current-turn-evidence
contracts: [P26]
status: implemented
breaking: false
version_decision: Additive v2 revision. `UpdateMemory.evidence` accepts one reserved literal in addition to canonical `record://` references. No schema version, event shape, error code, path or trust value changes.
base: e72e8fe49c4f14eb462ec9c6c7eb0e102cedcd97
contract_revision: spec/bot/v2/README.md@memory-current-turn-v1 + spec/bot/v2/memory-write-request.schema.json@memory-current-turn-v1
```

## 1. 识别与角色

- **Trigger → 现况 → 期望.** S2 记忆规则要求写 `user/` 必须带一条指向用户消息的
  `record://` evidence，但真实模型在用户回合里不知道当前消息的 seq：它只能猜测，宿主按规范
  拒绝，模型反复重试（BOT-E02 请求数 31 → 128），最后退而写 `agent/`，共享用户偏好没有进入
  `user/`。期望：当前回合的真实用户消息可以被模型直接引用，宿主仍按原规则校验引用、归属和
  trust，不把模型自报的 session/seq 当作证据，也不让保留值跨回合复用。
- **Coordinator / contract owner / implementer / reviewer.** 本单元 `s2-evid`（分支
  `s2/current-turn-evidence`）兼任三角色；先改契约、schema 和共享向量，再改 Swift 宿主与
  Worker persona，最后跑 mock 与真实模型验收。
- **Owning contract / schema / fixtures.** P26：
  [spec/bot/v2/README.md](../../spec/bot/v2/README.md) §1.5；
  `spec/bot/v2/memory-write-request.schema.json`；
  `spec/bot/v2/golden/memory-write.json` 的 `evidenceCases`、`cases`；
  `spec/bot/v2/tools/validate_vectors.py`。
- **受影响 producer / consumer.** Swift 宿主：`Sources/PhoneDSHBot/Journal/BotRecordService.swift`、
  `Sources/PhoneDSHBot/MCP/{BotMCPRuntime,BotDSHRemoteRuntime,BotToolCatalog}.swift`；
  Worker persona：`plugins/bot-runtime/prompts/system-prompt{,.zh-CN}.md`；
  eval 场景：`scripts/ci/bot-e2e/catalog.json` 的 BOT-E02 mock 路径。
  Android/HarmonyOS 没有 Bot runtime，不实现。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| `evidence` 取值 | 0–8 条规范 `record://` 引用 → 每项仍是规范引用，或逐字保留值 `current-user-turn`。保留值不做 trim／大小写折叠／别名。 |
| 解析点 | 无保留值 → 宿主在 `UpdateMemory` 执行点使用本回合在权威 `session/follow` 流上观察到的 `user/message` 事件（`source.kind == "user"` 且 `source.rpcId` 等于本回合请求 id），解析为 `record://session/<id>#<seq>`。宿主不读取模型提供的 session/seq，也不依赖回合结束后的物化日志。 |
| 回合边界 | 无保留值 → 仅真实用户回合可用；隐藏回合、held 回合、`agent:`、routine、Task、maintainer 回合得到 `memory-evidence-invalid`。 |
| 跨回合 | 无保留值 → 解析结果绑定当前 `rpcId`；下一回合 `rpcId` 不同，旧保留值不指向上一回合消息，不可复用。 |
| 校验与 trust | 引用存在、属于本 Bot、按宿主记录结构推导 trust → 保留值由宿主在权威 `session/follow` 流上观察到的用户消息直接按 `user` trust 写入；显式引用仍走 `resolveEvidence`；`user/` 仍同时要求 `source.kind == "user-turn"` 和至少一条 `user` 引用。 |
| 更正偏好 | persona 只说「更正用 replace 或重写」→ 明确「更正偏好时改写原文档，旧值不保留在正文或索引里（用户明确要求保留历史时除外）」；工具描述同步一句话。 |

自检：没有新增错误码、字段、事件类型或 envelope；没有放宽 `memory-source-boundary` 或
`memory-evidence-required`；保留值无效时仍整条失败，不降级为 `assistant`。

## 3. 兼容性

| Producer → Consumer | 处理 |
| --- | --- |
| old → new | 旧客户端只会发送规范 `record://`，新 schema／宿主继续接受；旧 golden 用例不变。 |
| new → old | 旧宿主不认识 `current-user-turn`，会按非法引用拒绝（`memory-evidence-invalid`），fail-closed；不会静默写入或降级 trust。 |
| new → new | Swift 宿主解析并校验保留值；Python 参考解析器读同一 golden；persona 与工具描述教同一个字面值。 |
| persisted old data → new／rollback | 历史文档的 `evidence` 只存规范化 `record://` 引用，不存保留值；旧数据读取不变。保留值不是持久别名。 |

版本决定：不升 schema 版本；这是 v2 记忆工具 evidence 取值的 additive 扩展。Worker 与 Swift
宿主需一起更新；旧宿主上模型若使用保留值会被拒绝，不会产生错误数据。

## 4. 共享向量与校验

- `memory-write.json` 新增 `evidenceCases.valid`：仅保留值、保留值＋观察引用；新增
  `evidenceCases.invalid`：隐藏回合、held 回合、无当前引用、外来当前引用、拼写不精确。
- 同一 golden 新增 `current-user-turn-write` 成功用例，验证 `memory-write-request.schema.json`
  接受保留值；validator 另拒绝 5 种近似拼写。
- mutation：把保留值用例的回合改成隐藏、把宿主解析结果改成不存在的记录，都必须让参考校验失败。
- 命令：`python3 spec/bot/v1/tools/validate_vectors.py`（内部调用 v2）与
  `python3 spec/tools/bot/check_golden.py --root .`。

## 5. 实现分工

| 端 | 路径 | 说明 |
| --- | --- | --- |
| 契约 | `spec/bot/v2/README.md`、`spec/bot/v2/memory-write-request.schema.json`、`spec/bot/v2/golden/memory-write.json`、`spec/bot/v2/tools/validate_vectors.py` | 本单、schema、正反向量与参考解析器 |
| Swift 运行时 | `Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift` | 在 `UpdateMemory` 执行点解析保留值；用 `turnAuthority.isUserTurn` 守回合边界；`beginTurn`/`endTurn` 清空观察，跨回合不可复用 |
| Swift 流观察 | `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift` | 从权威 `session/follow` 流观察 `user/message`，把 host 生成的 `record://session/<id>#<seq>` 交给运行时；模型不参与 |
| 记录校验 | `Sources/PhoneDSHBot/Journal/BotRecordService.swift` | 显式 `record://` 引用仍走 `resolveEvidence`；保留值使用宿主观察结果，不把模型自报当引用 |
| 工具描述 | `Sources/PhoneDSHBot/MCP/BotToolCatalog.swift` | 一句话教 `current-user-turn` 和更正偏好时的旧值处理 |
| Worker persona | `plugins/bot-runtime/prompts/system-prompt.md`、`system-prompt.zh-CN.md` | 记忆一节同一句话，不新增章节 |
| 回归 | `Tests/PhoneDSHBotTests/Memory/MemoryEvidenceTests.swift`、`scripts/ci/bot-e2e/catalog.json` | 用户回合可写 `user/`、非用户回合拒绝、伪造 seq 拒绝、跨回合不可复用；E02 mock 走 `user/` + 保留值 |
| eval 接线 | `scripts/ci/bot-e2e/harness/Tests/BotEvalTests/BotEvalRunner.swift` | 把本轮 `workspaceRoot` 传给 `BotRuntimeComposition.prepare`，使 eval 里的记录服务与宿主读同一份物化日志；只影响测试装配 |

实测发现物化 `session.v*.jsonl` 在本回合结束后才出现，因此保留值不能靠记录服务扫描物化日志；它必须来自
宿主实时 `session/follow` 观察。显式 `record://` 引用仍按原路径读取物化日志，所以 eval 的
`workspaceRoot` 接线也要修正，否则同一个 run 的显式证据永远找不到。

## 6. 失败路径

- 非用户回合、held/hidden 回合、maintainer 回合使用保留值：`memory-evidence-invalid`，不写事件。
- 本回合没有观察到匹配的用户消息（例如不是真实用户回合）：`memory-evidence-invalid`。
- 显式引用不存在、不属于本 Bot 或已抹除：沿用既有 `memory-evidence-invalid`／`record_erased`；保留值不接受模型提供的 session/seq。
- 模型自带伪造 seq：仍按普通引用校验，不存在即拒绝，不因为同一调用里另有保留值而放宽。

## 7. 未验证

- 真实模型只按本单元要求跑 BOT-E02 × 3；不声称其他场景或设备端到端。
- Android/HarmonyOS 没有 Bot runtime，不适用。
