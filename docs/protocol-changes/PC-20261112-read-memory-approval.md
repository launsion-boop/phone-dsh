<!-- SPDX-License-Identifier: MIT -->

# ReadMemory 的只读分类与结构审批修复（P26）

```yaml
change: PC-20261112-read-memory-approval
contracts: [P26]
status: implemented
breaking: false
version_decision: Clarification of the already-frozen tool-effects classification. No schema, tool name, wire field, error code or event payload changes. The Worker structural gate now follows the golden `read + auto` entry instead of treating `ReadMemory` as `tool.unclassified`.
base: ad6dfde26
contract_revision: spec/bot/v1/README.md@read-memory-approval (tool-effects goldens unchanged)
```

Protocol impact: P26; P25: none — no event envelope, storage or journal shape changed; P13: none —
no plugin Remote method, contract*.ts or types.ts changed; P16: none — no Worker URL parameter,
`PDSH_*` env or `__PDSH_*` global changed.

## 1. 识别与角色

- **Trigger → 现况 → 期望。** 真实模型 E02 观察到只读的
  `mcp__phone__ReadMemory` 偶尔被结构审批拒绝，宿主返回 `stale:always_scope`。期望：与契约
  `spec/bot/v1/golden/tool-effects.phone.json` 冻结的 `read + auto` 一致，Worker 不请求审批卡，
  宿主在收到请求时也把空效果视为 auto-policy。
- **Coordinator / contract owner / implementer / reviewer.** 本单元 `s2-int` 兼任；契约分类没有
  改变，只补一条可执行语义并用两端回归测试锁定。
- **Owning contract / schema / fixtures.** P26：
  [spec/bot/v1/README.md](../../spec/bot/v1/README.md) §2；
  `spec/bot/v1/golden/tool-effects.phone.json`（`ReadMemory` 已为 `read + auto`）；
  `spec/bot/v1/golden/tool-effects.json`（`RecallMemory` 已是 `read + auto`）。
- **受影响的 producer / consumer.** Worker：
  `plugins/bot-runtime/src/approval-gate.ts`；Swift 宿主：
  `Sources/PhoneDSHBot/Authz/BotToolEffects.swift`（原实现已正确，新增回归）；
  测试：`plugins/tests/bot-identity-approval.test.ts`、
  `Tests/PhoneDSHBotTests/Authz/BotReadMemoryApprovalTests.swift`。

## 2. 根因与契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| Worker 结构审批分类 | `AUTO_TOOLS` 有 `RecallMemory` 但没有 S2 后加的 `ReadMemory` → `phoneEffectsForApproval('mcp__phone__ReadMemory')` 落到 `unclassifiedEffect`（`known:false`），payload 的 `alwaysScope` 为 `session`。现在把 `ReadMemory` 与 `RecallMemory` 一起归入 `AUTO_TOOLS`，`auto` 工具不进入结构审批 roundtrip。 |
| 宿主 `alwaysScope` 校验 | 宿主 `effectsForApproval` 把 `ReadMemory` 分类为 `read + auto` → 返回空 effects → 期望 `alwaysScope=until`；与 Worker 发出的 `session` 不一致时以 `stale:always_scope` 拒绝。修复后 Worker 不再发请求；即使宿主收到请求，空 effects 仍直接 `auto-policy` 放行。 |
| 契约 | `ReadMemory` 已是 `read + auto`，`RecallMemory` 已由上游 golden 冻结为 `read + auto`；README 补充“`auto` 工具不出审批卡、结构门禁必须使用同一分类”，避免再次漂移。没有新增字段或错误码。 |

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 Worker 仍可能发 `alwaysScope=session` 的 `ReadMemory` 审批请求；新宿主保持 `stale:always_scope` fail-closed，不会把未分类请求静默放行。宿主分类本身未改。 |
| new → old | 新 Worker 对 `ReadMemory` 不再发请求，旧宿主直接执行只读工具；无需新字段。 |
| new → new | 两端都按 golden 的 `read + auto` / 空 effects 处理；TS 单测断言 golden 与 gate 一致，Swift 单测断言宿主 `approve` 返回 `auto-policy` 且无 pending card。 |
| persisted old data → new／rollback | 无持久格式变化；回滚只会恢复偶尔的 `stale:always_scope` 拒绝，不产生静默放行。 |

## 4. 验证

- `cd plugins && npm run typecheck` → PASS
- `cd plugins && node scripts/run-tests.mjs tests/bot-identity-approval.test.ts` → PASS
- `swift test --disable-sandbox --filter BotReadMemoryApprovalTests` → PASS
- 完整门禁结果见集成单元报告。
