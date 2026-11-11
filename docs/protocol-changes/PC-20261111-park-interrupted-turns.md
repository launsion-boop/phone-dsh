# 后台 park 在无终态升级下以“轮次记为 interrupted”收尾（P06/P17）

```yaml
change: PC-20261111-park-interrupted-turns
contracts: [P06, P17]
status: implemented
breaking: false
version_decision: 不改线格式与状态机边集；只在既有 `Draining → Parked` 边上写明一条收尾路径（PR #110）
base: d551fc39
contract_revision: spec/v1/budgets.md §1 `Draining → Parked` @ this PR head
```

Protocol impact: P06; P17; P02: none — WAL 段格式、manifest 与 fsync 顺序未变（仍按 wal.md §5.2/§5.3 封尾并记 `fence.wal_seq`）；P09/P18/P28: none — 无页面、键或 PC Link 变更

## 1. 问题

`shortcuts.run` 会让 App 在一轮对话中间进入后台，于是触发 `park()`。iOS 冻结或杀掉 WebContent 后，旧连接发不出干净的 peer EOF；有界升级因此拒绝重打包 overlay、拒绝启动替代 Worker（这是对的：overlay 可能落后 WAL）并把结果标成 `nonRetryable`。旧实现把这个结果交给 `fail()`：宿主进 Failed，用户必须手动恢复（现场：`Park failed: … did not quiesce before the overlay repack`）。

`spec/v1/budgets.md` §1 的 `Draining → Parked` 那列本来就写着「deadline 结束等待、中止 in-flight channel 请求……否则纪元关闭照常进行」，也就是说规范允许 park 完成，旧实现与规范相反。PR #110 把实现拉回规范。

## 2. Delta

| 项 | Before → After |
| --- | --- |
| 后台 park 遇到该升级结果 | `fail()`，宿主 Failed，需手动恢复 → **以 Parked 收尾**：不打包 overlay、不启动替代 Worker |
| 封 WAL 前置条件 | 仅「等」handler quiesce → 关闭旧连接并**要求** `waitForInboundWritesToQuiesce() == true`；仍有 handler 在派发则保持 fail-loud |
| 未结束的轮次 | 无记录（且不写会话记录） → park 期间记录为 interrupted（内存），宿主仍绝不写会话记录（D13/D14） |
| resume | 从 WAL 重打 overlay 后开准入 → 开准入**之前**对每个 interrupted 会话调用既有的 `POST /api/pdsh-recovery/resume`，由 DSH 自己补 `tool/result` 与 `turn/end{kind:'interrupted'}`；有界、best effort，失败只告警 |
| `stop()`（teardown） | fail-loud → **不变**，仍是 fail-loud |
| 状态机边集 | 不变（D14 的表格没有新增边，只给 `Draining → Parked` 补了一种收尾条件） |

## 3. 相容性

| 情境 | 处理 |
| --- | --- |
| 旧数据 → 新实现 | park 只封 WAL 尾并记 fence；overlay 由 resume 从该 WAL 重打，格式未变 |
| 新实现 → 回滚 | 回滚后同一现场会重新走 fail-loud（Failed），已封的 WAL/overlay 仍可被旧 build 读取 |
| 不写会话记录 | 宿主不写任何 DSH 会话记录；interrupted 只存在于内存与 `console` 事件里 |

## 4. 证据与未覆盖

- `Tests/PhoneDSHTests/PhoneDSHNonQuiescentParkTests.swift`（PR #110）：park 后 Parked、无 `lastError`、terminate 一次、boot 一次、`fence.wal_seq == WAL tail`、overlay 未重打包、宿主 journal 无 `turn/end`；resume 后 boot 二次、overlay watermark == 封好的尾、`pdsh-recovery/resume` 被调用、journal 以 interrupted `turn/end` + `tool/result` 结束；`stop()` 仍 fail-loud。
- **未覆盖**：(a) 测试把修复后的 journal 用 `MockWorker.setRecoveryResumeJournal` 脚本化，因此「DSH 的 `interruptedTurnClosers` 真的补 `tool/result`」是上游 pin 的假设，不是本仓库的运行时证据；(b)「loopback 停止后仍有 handler 在派发 → 仍 fail loud」这条分支没有测试；(c) 未在真机跑过。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| working-tree | 本单作者 | 把 PR #110 的行为写进 owning spec（此前只有 PR 描述） | P06/P17（宿主生命周期）、P02（WAL 封尾，无格式变化） |
