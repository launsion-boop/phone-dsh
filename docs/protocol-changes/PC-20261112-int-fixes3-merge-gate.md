<!-- SPDX-License-Identifier: MIT -->

# 合并后全量门禁：恢复期工具边界、抹除后日志指针、记忆详情导航、审批取消原因与 Worker 时区（P09/P16/P26）

```yaml
change: PC-20261112-int-fixes3-merge-gate
contracts: [P09, P16, P26]
status: implemented
breaking: false
version_decision: Additive/presentation only. No frame, event type, envelope, schema, tool name, tool schema, route or persisted field changes. The one new Worker environment entry is the standard `TZ`, already understood by the existing shell; an old Worker ignores it and an old host simply does not send it.
base: a2848911
contract_revision: spec/ui/v1/pages/bot-info.md@int-fixes3-1 + Sources/PhoneDSH/PhoneDSH.swift@int-fixes3-1 + Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift@int-fixes3-1
```

Protocol impact: P09, P16, P26; P02: none — the session-epoch rewrite order and tombstone format are unchanged, only which already-written log the App reads after an epoch switch changes; P03: none — the journal remains out of the erasure scope (§5.3 covers materialized session logs only; see F6 below); P25: none — no BotEventLog shape/sequence change; P27: none — no row-protocol field change; P05/P14/P15: none — no HTTP route, mux frame or `PDSH_*` init field change.

## 1. 识别与角色

- **Trigger → 现况 → 期望。**
  1. 三个修复分支与 d-heal4 合并后，需要证明两边的行为都在且不互相干扰（report `int-fixes3-20261112.md`）。
  2. F1：替换 Worker 的 bind 窗口里，phone MCP `tools/call` 仍会一直等 App 侧 `transport.call`（`ChannelDSHTransport.collect` 没有响应截止时间），直到 Worker MCP 客户端的 `toolCallTimeoutMs: 130000` 才返回 `Request timed out`；宿主没有 `task.created`。d-heal4 修掉了 bind 自身挂死，但没有给工具调用设边界。
  3. F3：`BotProductionEnvironment.updateSessionID` 只改 session id，缓存着旧纪元的 `sessionLogURL`；行投影每次 `rebuild()` 都优先用这个旧 URL，聊天页因此停在旧历史，新纪元的 notice/审批卡不显示。冷启动时 `connect()` 也不刷新 log URL。
  4. F5：`BotInfoPage` 的 `NavigationStack(path: [BotInfoSection])` 是强类型数组路径，`BotMemoryDocumentInfo` 的目标无法 append，文档行只高亮不 push。
  5. F7：审批记录页只显示「已取消」，不显示 durable 事件里的 `reason=worker_restarted`。
  6. Bot 发现 #1：`just-bash` 的 `date` 读 `TZ`，没有就默认 UTC；runtime-context 却按宿主时区（Asia/Taipei）承诺本地时间，沙箱与注入上下文差 8 小时。
  7. F6（只调查）：抹除后 `journal.xljournal` 仍含原文。
- **Owner / implementer / reviewer.** 本单元 `int-fixes`; 契约与两端在同一 revision。
- **Owning contract / schema / fixtures.** P09 [`spec/ui/v1/pages/bot-info.md`](../../spec/ui/v1/pages/bot-info.md)（审批记录原因）；P16 [`PhoneDSHWorkerEnvironment`](../../Sources/PhoneDSH/PhoneDSH.swift)（`TZ`）；P26 [`spec/bot/v1/README.md`](../../spec/bot/v1/README.md) §2.7（工具结果与回执沿用既有 `unavailable`/`approval.*` 语义）；P02 [`spec/v1/wal.md`](../../spec/v1/wal.md) §5.3（只改写已关闭会话的 materialized JSONL）。
- **Producer/consumer.** Swift `BotRuntimeComposition`/`BotMCPRuntime` 产生恢复期工具错误；Worker MCP 客户端消费。`BotProductionEnvironment`/`BotProductionRowService` 产生聊天行；`BotChatModel` 消费。`BotProductionInfoService` 产生审批记录；`BotApprovalHistoryPage` 消费。Swift `PhoneDSHHost` 产生 Worker 环境；`just-bash` 消费 `TZ`。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 恢复期 `tools/call` | `BotMCPRuntime` 增加 App composition 注入的有界 readiness probe：`ready` 立即执行；`recovering/connecting` 最多等 10 s；`failed/stopped` 立即失败。错误复用既有 code `unavailable`，文案固定为「与 App 的连接正在恢复，请稍后重试。」不新增错误码、不改变成功结果。没有注入 probe 的库/测试环境保持原行为。 |
| 纪元切换后的日志指针 | `BotProductionEnvironment` 的 `sessionLogURL` 变为可更新；`connect()` 和 `updateSessionID()` 都按当前 session 重新定位。行投影仍用 `BotSessionLogSelection.logURL` 再校验一次：显式 URL 只在其父目录就是当前 session id 时生效，否则回退到当前 session 的最新 `session.v*.jsonl`。S6 的 notice、旧纪元未命中行、墓碑隐藏规则不变。 |
| 记忆文档详情导航 | P09 已有「文档详情可达」要求；实现改为 `NavigationPath`，`BotInfoSection` 与 `BotMemoryDocumentInfo` 两种值都能 push。没有新增页面或改导航结构。 |
| 审批记录取消原因 | `spec/ui/v1/pages/bot-info.md`：已取消行必须再显示一句人话原因；原始 reason 码只留在事件/诊断。`BotApprovalReceipt.cancellationReason` 是唯一映射层（`worker_restarted`→「App 重启时取消」等，未知码→「审批已取消」，无码的旧记录也显示通用句）。 |
| Worker 时区 | `PhoneDSHHost.workerEnvironment` 在没有显式 override 时写入 `TZ=TimeZone.current.identifier`（IANA 名）。runtime-context 的时区来源不变；`just-bash` 的 `date` 已支持 `TZ`。App override 仍优先，未设置时区和旧行为一致（UTC）。 |

自检：无第二种 envelope/别名；没有删除或复用既有枚举；`unavailable` 与 `approval.*` 是既有形状；没有改任何持久化格式；`TZ` 是标准进程环境而非 `PDSH_*` 协议字段。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| new App → new Worker | readiness probe 只在 App composition 绑定后安装；工具错误是普通 MCP `isError` 结果。`TZ` 使沙箱 `date` 与 runtime-context 一致。 |
| old App → new Worker | 没有 probe 时行为不变（可能仍等 130 s，这是旧 App 的已知缺陷）；没有 `TZ` 时 `date` 仍 UTC。 |
| new App → old Worker | 旧 Worker 不调用 probe；`TZ` 是标准环境，旧 shell 同样读取。新 App 的 `NavigationPath`/审批记录只是 UI，无 wire 依赖。 |
| old data → new／rollback | 旧审批事件没有 `reason` 时显示通用「审批已取消」；旧纪元 session log 仍在磁盘且按 S6 规则拼接；回滚不需要迁移。 |

## 4. 验证

- 先红后绿（本次实际输出）：
  - `BotRuntimeReadinessTests.testRejectedReadinessReturnsHumanErrorQuickly`：修前 `isError=nil`、`code=nil`、耗时 0.531 s 仍走 Task（因 probe 未生效）→ 修后 `unavailable` + 人话，0.005 s。
  - `BotSessionLogSelectionTests.testAStaleEpochCacheDoesNotWinOverTheCurrentSessionLog`：修前返回 `gb-main-old` → 修后返回 `gb-main-new`。
  - `RowProjectionGoldenTests.testCancelledApprovalReasonIsHumanReadable`：修前 4 个 nil → 修后映射通过。
  - `PhoneDSHWorkerEnvironmentTests.testWorkerEnvironmentCarriesTheHostTimeZone`：修前 nil → 修后 `Asia/Taipei`。
  - F5 的 XCUITest（`testInfoMemoryDocumentRowPushesTheDetailPage`）只能由 tester 在模拟器跑；本轮完整 `swift build`、Bot UI capture 和 App build 不把它当作已执行。
- 其余必跑门禁、截图与 App 构建结果见 `int-fixes3-20261112.md`（worktree 根目录）。
- 未验证：真实 iOS 模拟器上的 F3 冷启动/抹除复测、F5 点击、F7 截图交互；物理 iPhone；F6 的 journal 擦除（只调查，未改代码）。
