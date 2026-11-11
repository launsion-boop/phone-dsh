# 持久待办审批（P26，S5 实现版）

```yaml
change: PC-20261111-bot-persistent-approval
contracts: [P26]
status: implemented
breaking: false
version_decision: 审批语义修订，事件类型与路由不变；追加 approval.requested 字段与自由文本状态值。新 App + 新 Worker 才提供持久语义；旧读者按未知状态保守显示。
base: d988108c1
contract_revision: spec/bot/v1/README.md@§2.7-persistent-approval-v2
```

Protocol impact: P26 — 把 target 冲突清单升级为可实现的持久审批语义（分类、挂起/恢复、过期、重启、出口）；P27: none — 复用既有审批卡投影，不新增行类型；P09: none — 不新增页面或动作；P05: none — 出口错误码是既有 403 拒绝的一个具体 `xl_error.code`，不新增路由。

## 1. 上一版冻结的衝突與本版處置

| 衝突 | 本版決定 |
| --- | --- |
| `BotApprovalCoordinator.defaultTimeoutMilliseconds = 300_000`，超时即拒绝 | 300 秒只保留给交互前台审批。持久待办在 `request` 时立即返回 `pending:true`，不进入 300 秒计时，不写拒绝。 |
| `approval-gate.ts` 的 330 秒 fetch abort，`tools/pre-execute` 会永久占住 | 宿主立即返回 pending；gate 不执行工具，调用宿主公开的 `Agent.cancel({kind:"hook",reason:"approval-pending"}, {keepInbox:true})` 结束本回合。没有跨 300 秒的阻塞调用。 |
| 身份登记 TTL（330 秒）覆盖等待 | 持久审批不跨等待持有登记：工具调用返回 pending 即结束，登记照常清理。批准后的新回合重新登记。TTL 不变。 |
| Worker 重启取消所有 pending，重启后没有恢复点 | Worker/App 重启保留持久待办：从 `approval.requested - approval.decided` 恢复；无 continuation 也可按 `approvalID + digest` 决定。非持久的旧 pending 在恢复时写 `cancelled`/`worker_restarted`。 |
| 用户不在场时“拒绝”是超时副作用 | routine/task 的拒绝只来自用户、显式取消、Bot 删除或 24 小时过期；过期是独立 `status:"expired"`，不是 timedOut。chat 隐藏唤醒没有恢复点，仍按原回合 300 秒完成审批。 |
| 执行恢复会重放副作用 | 任务/回合停在原地：任务写 `waiting_approval`；routine 写 `run_state.status:"waiting-approval"`。批准后在同一任务/会话开新回合并明确“不要重放已完成副作用”。 |

## 2. 實現版語義

### 2.1 分類與請求

- **交互**：`principal.kind == chat` 且宿主回合来源是 `user`（非 hidden/held）。保持 300 秒等待与超时拒绝。
- **持久**：`principal.kind` 为 `routine` 或 `task` 的回合。选择依据是宿主是否有可挂起的 run/task 恢复点；用户是否在看 App 不改变分类。
- **仍为交互**：`chat` 会话（前台主对话及 `task-settled`/held/`agent:` 隐藏唤醒）。隐藏唤醒没有可回放的原 prompt，若立即结束会在审批后留下无法恢复的待办；它保持 300 秒并在原回合继续。`verifier`/`maintainer` 的受限工具面不发审批卡。
- `approval.requested` 追加 `persistent:true`、`kind`、`requestedAt`、`expiresAt`、`origin`（`structural`/`egress`）；既有 `approvalID`/`digest`/`effects`/`alwaysScope` 不变。
- `/approval` 立即返回 `{ok:true,allowed:false,pending:true,approvalID,expiresAt}`。审批决定由既有 `user action kind=approval` 以 `approvalID + digest` 提交。

### 2.2 Worker 側

- `structural`：gate 不执行工具；调用 `exec.agent.cancel({kind:"hook",reason:"approval-pending"}, {keepInbox:true})` 结束回合，返回“等待审批、不要重试”的拒绝文本。
- `egress`：宿主 `/v1/http` 直接 403；沿用既有出口类 `error.code`/`X-PDSH-Proxy-Error`/`xl_error.code` = `egress_approval_denied`，消息说明等待批准、本次未发送、任务会在决定后恢复。本次网络写未执行，turns 结束后按任务规则停住。批准后同一任务重试时使用（一次性）Grant。
- 持久审批不延长登记 TTL、不保持 330 秒 fetch。交互审批的 300 秒/330 秒行为不变。

### 2.3 任務掛起與喚醒

- 回合结束仍有 pending：`task.updated` 写 `status:"waiting_approval"`、`error:"approval_pending"`，不写 `task.settled`；`AwaitTask`/`StopSubagent` 返回该记录。
- 批准：写 `task.resumed`，同一 DSH 会话新隐藏回合，`requestId = task-turn:<taskId>:approval:<approvalID>`；提示词要求从停下位置继续、不重放副作用；随后按既有完成/验证/父唤醒链。
- 拒绝/过期：写 `task.settled`，`status:"denied"`，`error:"approval_denied"`/`"approval_expired"`；异步 chat 任务唤醒父对话一次。
- 显式 `StopSubagent`：写 `approval.decided{status:"cancelled",reason:"task_stopped"}`，任务以 `stopped` 结束。

### 2.4 routine 掛起與恢復

- 运行停在 `run_state.status:"waiting-approval"`，记录 `waiting_approval_id`/`waiting_session_id`；该 attempt 不产生交付，tick 跳过。
- 批准：同一个 `runId`/attempt 恢复 `started`，用恢复的会话/新 request id 继续；拒绝/过期：`failed`，`error` 为 `approval_denied`/`approval_expired`，走普通交付。
- 手动取消停住的运行写 `approval.decided{status:"cancelled",reason:"routine_stopped"}`。

### 2.5 過期、一次性、重啟

- 过期 `expiresAt = requestedAt + 24h`：`approval.decided{decision:"deny",status:"expired",reason:"approval_expired",expired:true,timedOut:false}`；迟到的用户动作返回 stale，不产生 Grant。
- 决定一次性：同一 `approvalID + digest` 的并发第二决定 stale。
- App/Worker 重启：coordinator 从 durable 事件恢复 pending（不需要旧 continuation/登记）；任务/routine 的 waiting 记录随既有 durable snapshot 恢复并在启动时与审批状态对账。非持久的未决请求在恢复时写 `cancelled`/`worker_restarted`。
- 持久待办只在用户决定、24 小时过期、Bot 删除或显式停止时终止；Worker `/v1/http` 消费者取消只取消交互审批。

### 2.6 App 入口與本地通知

- 持久 pending 仍投影为消息流里的既有审批卡（`e-<botId>-approval-<approvalID>`），重启后重新显示 pending；抽屉/头像的待处理计数来自同一 durable 差集。
- 宿主预登记本地通知，标识 `approval-pending:<botId>:<approvalID>`，深链 `phonedsh://bot/<botId>/row/e-<botId>-approval-<approvalID>`；决定/过期/Bot 删除时撤销。60 秒后才提示，避免与应用内即时操作重复。

## 3. 向量與驗證

- `approval.requested` 的新字段与 `pending:true` 响应由 Swift `BotPersistentApprovalTests` 与 plugins `bot-identity-approval.test.ts` 的真实编解码/状态机覆盖。
- 状态字符串是既有自由字段的 additive 值：`waiting_approval`、`denied`（task），`waiting-approval`（routine），`expired`（approval）。不新增 schema/golden 文件；既有 event-envelope 的 `approval.requested`/`approval.decided` type 不变。

## 4. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| `persistent-approval-v1` | `s2-s4b` | 按 §3.8 冻结“审批不因超时拒绝”的目标与冲突；不实现。 | P26 owner、S5 持久审批单元；P27/P09 无变更 |
| `persistent-approval-v2` | `s3-approval` | 升级为实现版：按在场分类、立即 pending、任务/routine 挂起与唤醒、24h 过期、重启恢复、出口 fail-closed 与通知。 | P26/P27/P09；Bot MCP、bot-runtime gate、App Bot runtime |
