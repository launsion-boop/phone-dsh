<!-- SPDX-License-Identifier: MIT -->

# 合并后回归：计划重启后的首条对话、审批工具结果人话、审批取消文案与抹除范围说明（P09/P26）

```yaml
change: PC-20261112-int-polish2-approval-erasure
contracts: [P09, P26]
status: implemented
breaking: false
version_decision: Presentation-only. No frame, event type, envelope, schema, tool name, tool schema, route or persisted field changes. The approval tool result keeps every structured field; only its leading MCP text content gains one human sentence. Erasure scope and the tombstone format are unchanged; the journal stays out of scope and the copy now says so.
base: 8898f418
contract_revision: spec/ui/v1/pages/bot-info.md@int-polish2-1 + Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift@int-polish2-1 + Sources/PhoneDSHBot/MCP/BotApprovalCoordinator.swift@int-polish2-1 + examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift@int-polish2-1
```

Protocol impact: P09, P26; P02: none — the session-epoch erasure scope, tombstone format and rewrite order are unchanged; P03: none — `journal.xljournal` remains out of scope, only the user-facing confirmation says so; P25: none — no BotEventLog type or payload changes; P27: none — the approval row-projection fields are unchanged, the new sentence is model-facing MCP text; P06: none — no host event, frame or state-machine change; P16: none — no Worker environment or init change.

## 1. 识别与角色

- **Trigger → 现况 → 期望。**
  1. **高（回归）** `BotCompositionE2ETests.testProductionCompositionUsesRealHostAndWorker`：`host.plannedRestart` 之后立即 `sendUserMessage("重启后的继续对话")`，返回 `status=cancelled`（期望 `completed`）；`3e62bea5` 上 42/42 全过，之后合入的改动引入。根因链见 §2.1。
  2. **中** 真实模型把 `RequestApproval` 的工具结果 JSON 原样复述，正文出现 `RequestApproval` / `allowed` / `decision` / `scope` / `session` / `approval-…`。旧结果只有结构化 JSON，模型没有可转述的人话。
  3. **中低** 重启取消待审批的 `ui.notice` 是英文三处硬编码（`BotApprovalCoordinator` 的 `cancelAll`、`cancelInteractive`、恢复路径），与审批记录页的 `BotApprovalReceipt.cancellationReason` 中文映射脱节。
  4. **用户已决定** 抹除只覆盖会话日志与记忆（P02 §5.3），工具操作日志 `journal.xljournal` 不在范围内，可能仍含原文；不改范围，只在单文档、本 Bot 记忆、共享 `user/` 记忆（含二次确认）的后果说明里补半句。
- **Owner / implementer / reviewer.** 本单元 `int-polish2`；契约与两端（`spec/ui/v1/pages/bot-info.md`、Swift Bot runtime、probe UI）在同一 revision 修改；未 commit/push。
- **Owning contract / fixtures.** P09 [`spec/ui/v1/pages/bot-info.md`](../../spec/ui/v1/pages/bot-info.md)（抹除范围与确认文案）；P26 `BotMCPRuntime.execute` 的 `RequestApproval` 结果文本与 `BotApprovalCoordinator` 的取消通知（既有 `approval.*`/tool-result 语义，不新增字段）；P02 §5.3 只描述范围，未改协议。截图夹具 `BotFixtures.swift` 新增四个 `infoErase*` case；`CaptureUITests` 断言四段文案。
- **Producer/consumer.** Swift `BotMCPRuntime` 产生审批工具文本，Worker MCP 客户端/模型消费；`BotApprovalCoordinator` 产生 `ui.notice`，`BotSessionLogProjection`/聊天页消费；`BotDSHRemoteRuntime` 产生 `sendUserMessage` 结果，App 行服务/测试消费；`BotRuntimeComposition` 的 readiness 门消费 host 的 `currentWorkerBootID` 与 recovery scheduler 的 `recoveredBootID`（只读）。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 计划重启后的首条对话 | `BotDSHRemoteRuntime.sendUserMessage`/`sendAgentMessage`/`runRoutine` 在开回合前调用 `BotMCPRuntime.waitUntilRuntimeReady()`（App composition 注入的有界 probe；库/测试没有 probe 时保持原行为）。`BotRuntimeComposition.isRuntimeReady()` 要求 `state == .ready`：计划重启在 `.restarted`/`.workerHello` 时已经进入 `.recovering`，所以新回合会等到 rebind 的 `attachTransport` 完成后才开；不比较 host 内部 boot id（引擎可能轮换内部 id 而 HELLO 未到达 App，transport 始终使用最新 channel）。probe 超时返回既有 `unavailable` 语义的人话「与 App 的连接正在恢复，请稍后重试。」；不新增错误码、不改回合帧。 |
| `RequestApproval` 工具结果 | `content[0].text` 首行改为一句人话（`用户已允许，本次对话内都有效。` / `用户已总是允许，之后同类操作不必再问。` / `用户已允许这一次，可以继续。` / `这次请求没有获得允许，已经停止。` / `审批请求已经发出，正在等用户确认。`），结构化 JSON 原样放在换行之后；`structuredContent` 一个字段不变。模型不再只有 `allowed`/`decision`/`scope`/`approvalId` 可抄。 |
| 审批取消通知 | `ui.notice.text` 统一由 `BotApprovalCoordinator.cancellationNotice(reason)` 生成：`BotApprovalReceipt.cancellationReason(reason)` 的中文映射加句号（`worker_restarted` → `App 重启时取消。`，`bot_deleted` → `Bot 已删除时取消。`，未知 → `审批已取消。`）。`approval.decided.reason` 原始码保持不变。 |
| 抹除确认文案 | 四个确认框的后果说明末尾统一追加 `；App 内部的操作日志可能仍保留原文。`（单文档、抹除本 Bot 记忆、共享 `user/` 记忆首次与最后确认）。`spec/ui/v1/pages/bot-info.md` 写明抹除范围只含会话日志与记忆文档，`journal.xljournal` 不在范围内；范围、墓碑格式、事件和宿主流程不变。 |

自检：没有第二种 envelope/别名；没有删除或复用既有枚举；`structuredContent` 与 `approval.decided.reason` 保持原形状；没有改任何持久化格式或工具 schema；只新增/复用一个 bounded readiness API，不新增 wire 字段。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| new App → new Worker | 审批结果仍是合法 MCP `content`+`structuredContent`；首句人话只改变模型看到的文本前缀。计划重启后的回合在 rebind 完成后再开；工具 readiness 不变。 |
| old App → new Worker | 旧 App 没有 turn readiness gate，仍可能在重启窗口被取消（旧缺陷）；旧 App 读新审批文本时仍能解析结构化字段；取消通知与抹除文案只在本端显示。 |
| new App → old Worker | 旧 Worker 不调用 turn readiness API 也不受影响；审批结果文本变化不依赖 Worker 版本；旧 Worker 仍收到相同 structuredContent。 |
| old data → new／rollback | 旧 `approval.requested` 无 `persistent` 时仍按既有 restore 规则关闭并显示中文 `App 重启时取消。`；旧抹除记录/事件不变；无需迁移或回滚步骤。 |

## 4. 验证

见 worktree 根目录 `int-polish2-20261112.md`（第一行结论、逐项命令与结果、截图路径、BotE2E 未执行项）。
