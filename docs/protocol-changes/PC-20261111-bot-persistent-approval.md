# 持久待办审批（P26，S5 target）

```yaml
change: PC-20261111-bot-persistent-approval
contracts: [P26]
status: target
breaking: true
version_decision: 需要一次显式的审批语义修订；本记录只冻结冲突清单与目标语义，不实现。落地前维持现有 300 秒超时拒绝。
base: 0bbe253f6
contract_revision: spec/bot/v1/README.md@§2.7-persistent-approval-v1
```

Protocol impact: P26 — 冻结“routine／异步 Task 的审批不因超时拒绝”的目标语义、需要修改的契约与风险；P27、P09: none — 本记录不新增行或页面动作，UI 只在后续实现时展示 pending 状态

## 1. 現況與衝突

- `BotApprovalCoordinator.defaultTimeoutMilliseconds = 300_000`；超时 `expire` 写 `approval.decided{decision:"deny",status:"denied",timedOut:true}` 并返回 `allowed:false`。
- Worker 侧 `plugins/bot-runtime/src/approval-gate.ts` 的 `postApproval` 在 330 秒 abort；`tools/pre-execute` 的 `next()` 要等到这个 fetch 返回后才继续。
- 身份登记（`BotAttributionRegistry`）默认 TTL 覆盖同一等待窗口；`workerRestarted()` 会取消所有 pending 并写拒绝。
- 因此 routine、异步 Task、隐藏回合和 `agent:` 回合在用户不在场时得到的“拒绝”不是用户决定，而是超时副作用，违反 §3.8“审批不因超时拒绝”。

## 2. 目標語義（凍結）

1. 非交互回合（routine、异步 Task、隐藏唤醒、`agent:`、held）的审批请求是一条**持久待办**；超时只改变“是否仍在等”的诊断，不产生拒绝决定。
2. 审批在 App/Worker/进程重启后仍可被用户处理；用户以 `approvalID + digest` 决定，且只能生效一次。
3. 任务/回合在等待期间停在原地；决定送达后从同一逻辑位置恢复，不能重放已完成的工具副作用。
4. 交互前台回合是否保留 300 秒超时需要单独修订；本记录只冻结非交互回合。
5. 取消、撤销 Bot、Worker 重启仍是显式终止条件；它们写 `approval.decided`（`status:"cancelled"`/`"unavailable"`），不伪装成用户拒绝。

## 3. 需要改的契約與路徑

| 路徑 | 需要的修改 | 風險 |
| --- | --- | --- |
| `BotApprovalCoordinator` | pending 状态 durable 化；`resolve` 不再只依赖内存 continuation；重启后按 `approvalID` 重新绑定等待者或挂起决定。 | 等待者跨进程不存在时如何“恢复执行”没有现成机制。 |
| `plugins/bot-runtime/src/approval-gate.ts` | 330 秒 abort 改为可恢复等待/租约，`tools/pre-execute` 不能永久占住调用；需要 Worker/插件侧协议。 | 超出 `s2-s4b` 允许修改的路径；需要另立单元。 |
| `BotAttributionRegistry` | 登记 TTL/incarnation 要覆盖停住的等待，或恢复时重新登记同一次调用。 | 与 token rotate/revoke 语义交叉。 |
| 行投影/UI | pending 审批在重启后仍显示；决定只生效一次；失败要 fail-loud。 | 需要新 durable 状态，不能只改 UI。 |
| 执行恢复 | 每个工具调用需要可重放的执行 seam；现有“fetch 返回就执行”的模型不满足。 | 最大的实现风险；可能需要任务/回合级“暂停+恢复”协议。 |

## 4. 為什麼本單元只凍結

- `BotApprovalCoordinator.swift`、Worker 插件、身份登记与工具执行 seam 都不在 `s2-s4b` 的允许修改路径内。
- 把超时从 300 秒直接改成“无限等待”会让 Worker 的工具调用永久悬挂，且 App 重启后没有恢复点，风险高于收益。
- 因此保留现状 300 秒语义，冻结目标与冲突清单；实现由 S5 的持久审批单元完成，届时需要新的契约 revision 和两端运行证据。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| `persistent-approval-v1` | `s2-s4b` | 按 §3.8 冻结“审批不因超时拒绝”的目标与冲突；不实现。 | P26 owner、S5 持久审批单元；P27/P09 无变更 |
