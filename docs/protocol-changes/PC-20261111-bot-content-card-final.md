<!-- SPDX-License-Identifier: MIT -->

# 内容卡 `final` 收尾标记（P26 additive）

```yaml
change: PC-20261111-bot-content-card-final
contracts: [P26]
status: implemented
breaking: false
version_decision: Additive P26 revision. The five content-card input schemas gain an optional boolean `final` (default false). No wire field, event type, event payload, `cardType`, sequence domain, storage shape or `SendToUser` result schema changes; a failed card call never suppresses, and a missing/false `final` keeps the existing mid-task behaviour.
base: 13b782c3b
contract_revision: spec/bot/v1/README.md@content-card-final-v1 + spec/bot/v1/golden/tool-catalog.phone.json (implemented)
```

Protocol impact: P26. P25: none — no Bot event type, envelope, `card.presented` payload or sequence domain changed (the flag is input-only and is stripped from the card payload); P16: none — no Worker URL parameter, `PDSH_*` environment variable or init field changed; P13: none — no plugin Remote method changed; P06: none — the Worker uses the existing `tools/post-execute` seam and the DSH `turn/end` event; P05/P12/P03/P17: none — no gateway, shell, ledger or controller path changed.

## 1. 识别与角色

- **Trigger → 现况 → 期望。** 第二轮证明纯提示词无法阻止模型在内容卡工具返回后再补一句
  「已完成…」：BOT-E11 两版措辞都是 0/10，模型推理里写了「卡片后不写字」，拿到工具回执仍
  补文字。`ask_user`/`show_next_steps` 已有机制（Worker 在 `tools/post-execute` 成功后压掉
  文本 delta，直到 `turn/end`；宿主 `collectTurn` 在 `tool/result` 成功后置 `suppressWrapUp`
  并 `runtime.suppressText`，`SendToUser` 返回 `invalid_arguments`；**两者都不 cancel 回合**）。
  现在期望：内容卡在模型显式传 `final:true` 时复用同一处理，让收尾卡真正成为可见回复的最后
  一项；不传 `final` 的同 cardKey 进度更新保持原样。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s3-card`
  （worktree `dsh-work/s3-card`，分支 `s3/content-card-fix`）兼任，按 AGENTS.md §3.1 先改
  owning spec 与变更单，再实现 Swift 宿主、Worker 插件和提示词，最后跑规范、mock、selftest
  与真实模型验收。
- **Owning contract / fixtures.** P26：[spec/bot/v1/README.md](../../spec/bot/v1/README.md)
  §2.9 新增 `final` 语义；[tool-catalog.schema.json](../../spec/bot/v1/tool-catalog.schema.json)
  约束 `final` 声明形状；`golden/tool-catalog.phone.json` 的 `valid.p0` 替换五个内容卡的
  上游 p0 条目（只增加 `final`）；`golden/card-payload.phone.json` 增加接受/校验/剥离用例；
  `tools/validate_vectors.py` 对五个工具做强制检查与 4 条 mutation 自检。上游
  `golden/tool-catalog.json`、`golden/card-payload.json` 与 `export-vectors.mjs` 输出保持
  原样（导出器只有一条说明注释）。
- **受影响 producer / consumer.** Swift 宿主：
  `Sources/PhoneDSHBot/MCP/BotToolCatalog.swift`（schema/描述）、
  `BotCardPayloads.swift`（boolean 校验、不进卡片负载）、
  `BotMCPRuntime.swift`（成功 `final:true` 后禁止 `SendToUser`）、
  `BotDSHRemoteRuntime.swift`（读取 `tool/call` 参数、成功 `tool/result` 后置
  `suppressWrapUp`）。Worker：`plugins/bot-runtime/src/stream-forward.ts`（成功
  `tools/post-execute` 后压文本 delta）。提示词：`plugins/bot-runtime/prompts/*` 与
  `plugins/profile/phone.worker.cordis.patch.yml`（由 `assemblePrompt()` 生成）。评测：
  `scripts/ci/bot-e2e/{catalog.json,selftest.json,EVAL.md}`。Android/HarmonyOS 没有 Bot
  runtime，不需要跟进。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| fields／default | 无 `final` → 五个内容卡工具可传可选 JSON boolean `final`，缺省 `false`；其他类型是 `invalid_arguments`。 |
| 语义／terminal outcome | 无 → 成功调用且 `final:true` 后，本回合后续助手文本不投递、`SendToUser` 失败；与成功 `ask_user`/`show_next_steps` 相同。不是 cancel：不新增 `turn/end`，不改变 `turn/end.reason`。 |
| 失败／未知值 | 无 → `isError:true`、审批 block、参数校验失败均不压制；`final` 缺失按 false；`final:false` 与不传等价。 |
| 卡片负载 | 无 → `final` 不进入 `card.presented`、不进入 `card-payload` 结果；卡片的 `cardType`/字段不变。 |
| correlation／sequence | 不变 → 仍靠现有 `tool/call.callId` 与 `tool/result.message.toolCallId` 关联；`final` 只在该 call 内生效。 |
| error code／retryable | 不变 → 被压制期间 `SendToUser` 仍返回既有 `invalid_arguments`/`Text output is suppressed for this turn`；没有新错误码。 |
| origin／auth／scope | 不变 → `final` 不改变会话身份、审批或跨会话规则；只有当前 turn 的当前 session 受影响。 |

自检（spec/README.md §5.1）：没有新增第二种收尾表达（复用 ask_user 机制）；字段可选且有
明确缺省；没有收紧或放宽既有消息（卡片输出字节不变）；没有新增 enum；没有删除或重用名称。

## 3. 兼容性

| Producer → Consumer | 支援／拒绝方式及理由；对应测试 |
| --- | --- |
| old Swift → new Worker | 旧宿主不传 `final`：新 Worker 不压制，行为与旧版一致；Worker 仍按 `turn/end` 清理状态。 |
| new Swift → old Worker | 新宿主可传 `final`，旧 Worker 的 `tools/post-execute` 忽略它；宿主侧仍在 `tool/result` 后压文字并拒绝 `SendToUser`，因此终端行为成立。 |
| old model → new Swift/Worker | 模型不传 `final`：不压制，旧行为保留；不会因为 schema 多了可选字段而失败。 |
| new model → old Swift/Worker | 旧实现忽略 `final`（旧 schema 的 `additionalProperties:false` 只是模型面提示，宿主不做 JSON-schema 校验），调用仍成功，只是没有压制。 |
| persisted old data → new／rollback | 不适用：`final` 不落盘、不进事件、不进卡片负载；回滚只回到“卡后可能补文字”的旧体验。 |

- 版本决定：不升 schema/wire/event 版本；`final` 是 MCP 工具输入的可选控制字段，属于
  additive P26 revision。`card-payload` 与 `card.presented` 的字节不变。
- bundle／image 顺序：Worker 插件变更必须与宿主一起重建（`phone-bundle-fresh`）；没有持久化
  迁移，旧数据可在新旧版本间来回运行。
- `target`／`draft` 差异：P26 仍为 `target`；本单不声称真机渲染或非 deepseek-flash 模型的
  端到端行为。

## 4. 分工与证据

- 本单元由同一 agent 依次承担 contract owner、Swift/Worker implementer 与 evaluator；路径
  不与其他 worktree 重叠：`spec/bot/v1/**`、`spec/tools/bot/export-vectors.mjs`（注释）、
  `Sources/PhoneDSHBot/MCP/{BotToolCatalog,BotCardPayloads,BotMCPRuntime,BotDSHRemoteRuntime}.swift`、
  `Tests/PhoneDSHBotTests/MCP/**`、`plugins/bot-runtime/src/stream-forward.ts`、
  `plugins/tests/bot-channel-stream.test.ts`、`plugins/bot-runtime/prompts/**`、
  `plugins/profile/phone.worker.cordis.patch.yml`、`plugins/tests/bot-persona.test.ts`、
  `scripts/ci/bot-e2e/{catalog.json,selftest.json,EVAL.md}`、本单与 receipt。
- 共享 fixtures：`spec/bot/v1/golden/tool-catalog.phone.json`（五个工具 + `final` 声明）、
  `spec/bot/v1/golden/card-payload.phone.json`（`final:true`/`false` 被接受并剥离，字符串
  `final` 被拒绝）。Python 校验器、Swift `BotCardPayloadTests`/`BotToolCatalog` 测试和 TS
  运行时测试都读取这些向量或同一语义。
- Swift 测试：`BotCardPayloadTests`（五工具接受 boolean、剥离负载、拒绝非 boolean、schema
  声明；`ask_user` 不接受 `final` 语义）、`BotMCPRuntimeTests`（成功 final 卡后
  `SendToUser` 被拒；失败/无 final 不拒）、`BotDSHRemoteRuntimeTests`（final 卡后
  `assistant/message` 不进入对话、`turn/end` 仍正常；无 final/失败卡保留文字）。
- Worker 测试：`plugins/tests/bot-channel-stream.test.ts` 覆盖 final:true 压制、false/缺失
  不压制、block/失败不压制、`turn/end` 清理。
- 评测：`BOT-E11` 的 mock 最后一张卡传 `final:true`，`terminal:true` 保持不放宽；
  `BOT-SELFTEST-CARDS-FILES` 在 final 卡后给非空 `final_text` 并断言不出现（正例）；
  `BOT-SELFTEST-CARD-NO-FINAL` 断言无 `final` 时卡后文字仍可见（反例）。
- Exact commands → 结果：全部 PASS，见 `docs/receipts/s3-content-card-fix-20261111.md` 第三轮一节。真实模型 BOT-E11 4/5（≥4/5 验收线；失败的那次是模型没出卡，不是 terminal 失败），回归 E10/E12/E14/E03 各 3/3。
- 剩余风险：模型可能忘记传 `final:true`；此时宿主/Worker 不压制，`terminal` 仍会抓到卡后
  文字。提示词与工具描述降低概率但不能消除。非 deepseek-flash 模型、真机卡片渲染未验证。

## 5. 修订记录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| content-card-final-v1 | s3-card coordinator | 初始冻结：P26 additive 可选 `final`，复用 ask_user 抑制机制 | Swift 宿主、Worker、提示词、评测、spec 校验器 |
