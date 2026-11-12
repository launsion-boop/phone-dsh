# PC-20261112-bot-egress-pending — 出口审批不阻塞请求、批准后重试复用 once Grant（P05/P26）

```yaml
change: PC-20261112-bot-egress-pending
contracts: [P05, P26]
status: implemented
breaking: false
version_decision: 无新 wire 字段、路由、JSON-RPC 方法、schema 或事件种类。只改 `/v1/http` 403 的时序语义与 Task 拒绝优先级，沿用既有 `egress_approval_denied`/`task_network_write_denied` 错误码。
base: 7a0f7085b5baf2570955299e5a75295e4b04b8ae
contract_revision: spec/bot/v1/README.md@PC-20261112-bot-egress-pending-r1
```

Protocol impact: P05; P17: none — `/v1/http` 路由、header 与 body 形状不变；P26; P09: none — 未改页面、行投影或 eval catalog；P25: none — 复用既有 `approval.requested`/`approval.decided`/`grant.*` 事件形状。

## 1. 触发与现况

第二轮真实模型联调（C1）证据：

- `PDSH_EGRESS_ALLOW` 已包含 httpbin.org，`curl -sS -m 30 -X POST` 触发审批卡；用户点「允许一次」时 `approval.decided{decision:allowOnce}` 与 `grant.consumed` 已写入，但 curl 仍在 30.08 s 以 `curl: (7) … Fetch is aborted` 结束。审批卡从请求到决定约 29.6 s，恰好在 curl `--max-time 30` 的边界；`/v1/http` 请求被调用方中止，真实响应无法交回。
- 同一窗口内 Task 子任务的 POST 只看到 `curl: (22) the host allow-list rejected`；宿主 `approveEgress` 已经生成了具名 `task_network_write_denied`，但 curl shim 把所有 403 都压成白名单句子。`example.com` 在白名单内，失败并非真实白名单拒绝。
- 另有两条独立运行时问题（AwaitTask 超时、主线程阻塞工具链）在本单元修复；它们不改变协议形状，见 `sim-fix-rt-20261112.md`。

**Trigger → 期望。** Worker 的 `/v1/http` fetch 可能在用户决定前被 `curl --max-time`/客户端超时中止。宿主不能把「等待用户 300 s」的代价压在这个请求上，也不能为死请求消费 allowOnce。现在要求：

1. egress 写一律按持久待办记录；chat 最多等待 20 s（present user 仍可让同一请求完成），超时返回 403 pending 的**人话**，卡片保留；Task/routine 立即返回 pending。
2. 用户批准后生成的 `once` Grant 不因原请求中止而消费；批准后的重试消耗该 Grant 并只发出一次真实写；批准前的重试复用同一张 pending 卡。
3. Task 缺少 `task.network-write` 的具名拒绝先于 allow-list；非 Task 的未列入主机仍走 `host_not_allowed`，不出卡。
4. Worker curl shim 在 403 带 `xl_error` 时把 `error.code` + `error.message` 原样交给模型，而不是统一显示 `host allow-list rejected`。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| egress 审批等待 | chat egress 以 300 s 交互 continuation 阻塞 `/v1/http` → 最多 20 s 有界等待；Task/routine 立即 pending。超时后 `/v1/http` 返回 403 `egress_approval_denied`，message 为「已提交审批，批准后请重试；这次网络写入没有发出」。依据 §2.4、§2.7。 |
| pending 卡与 once Grant | 交互批准在 decision 时消费 once Grant → egress 的 once Grant 保留到重试的 `standingDecision` 消费；批准前重试复用同一 session+host+method 的 pending 卡，不新增卡。依据 §2.4。 |
| Task 拒绝优先级 | 先 allow-list，再 Bot approver；白名单外 Task 只看到 `host_not_allowed` → 先 Task 子集判断（`task_network_write_denied`），再 allow-list；非 Task 未列入主机仍 `host_not_allowed`。依据 §2.4、§2.5。 |
| 403 错误呈现 | curl shim 对所有 403 输出 `host allow-list rejected` → 解析宿主 `xl_error` 信封，输出具名 `error.code` + 人话；普通上游 403 保持原文。依据 §2.4 的错误码契约。 |
| 卡片/事件 | `approval.requested` 继续写 `persistent:true`、`origin:"egress"`、`effects`；`approval.decided` 继续写 `decision/status`；不新增字段。 |
| 兼容 | 无新 schema 字段。旧 host + 新 Worker：curl 仍按旧 403 文案；新 host + 旧 Worker：旧 Worker 不解析 403 信封，仍显示旧句，但宿主回执和 Grant 语义正确。支持组合仍是同 bundle 新 App + 新 Worker。 |

自检（`spec/README.md` §5.1）：没有第二 envelope、别名或错误码；`egress_approval_denied` 仍表示「Bot 写未获用户授权/等待中」，`task_network_write_denied` 仍表示「Task 子集缺失」，`host_not_allowed` 仍表示「主机不在 allow-list」。时序变化不要求新版本字段。

## 3. 实现与证据

- Swift：`Sources/PhoneDSHBot/MCP/BotApprovalCoordinator.swift`（持久卡的有界 continuation、pending 去重、消费者取消不再删除 egress 卡）、`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift`（egress 一律 durable + 20 s chat 窗口 + Task 先于 allow-list）、`Sources/PhoneDSHGateway/ModelGateway.swift`（`hostAllowed` 传给 approver、审批先于 allow-list）、`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift`（传 `hostAllowed`）。
- Worker：`plugins/shell-ext/src/curl.ts`（403 `xl_error` 解析）。
- 测试：
  - `Tests/PhoneDSHBotTests/MCP/BotEgressGatewayIntegrationTests.swift`：真实 `BotMCPRuntime` + `ModelGateway` + loopback mock 上游；构造「用户决定晚于 fetch 预算」→ 首请求 403 pending，批准后重试 200，上游恰好 1 次，审批卡只有 1 张。
  - `Tests/PhoneDSHBotTests/Security/BotEgressApprovalTests.swift`：同请求窗口内批准、pending 去重、消费者取消保留 durable 卡、Task 具名拒绝（含白名单外）。
  - `Tests/PhoneDSHGatewayTests/BotEgressApprovalGatewayTests.swift`：Task 拒绝先于 allow-list；`notBot` 仍走 `host_not_allowed`。
  - `plugins/tests/shell-ext-curl.test.ts`：403 带 `xl_error` 时输出具名码与人话；普通 403 保持 generic。
- 运行结果见 `sim-fix-rt-20261112.md` 的必跑检查。

## 4. 回滚与剩余风险

- 回滚到旧 host：旧 host 仍按 300 s 交互等待；已写入的 pending `approval.requested` 会被旧 host 视为未知 persistent 卡（旧代码只恢复自己认识的形状），不影响已产生的 Grant。回滚不迁移任何持久格式。
- 批准后重试是一次新的 `/v1/http`；若 Worker 在批准与重试之间再次中止，Grant 仍在，重试仍不需要二次审批。
- 审批卡在 24 h 后过期；过期后重试会重新出卡（既有行为）。
- Worker curl 的 403 文案依赖宿主返回 `xl_error`；旧 host 的 403 body 没有该成员时保持原 generic 文案，不会误报具名码。
