# 交接给 Android：引擎优先启动、静默后台启动、远程唤醒与宿主拥有的时间

基线为 [PR #217](https://github.com/launsion-boop/phone-dsh/pull/217) 合并提交
`09a3db1f5e330fed3ee3a85d7e6151d4aa057465`。Android 实现使用 host engine-launch v1
共享向量 revision 3。以下是当前实施状态，后面的交接索引保留作代码和契约导航。

- 进程前台启动和引擎 ready 边沿进入同一个合并式 ReadySweep。外部请求先读宿主准入账本，
  Bot 的提交使用原 downstream id，待处理的 held 项重放沿用同一个 DSH 请求 id。
- 宿主将 routine、DSH schedule、outbox settle 和 Gmail 的到期点落盘，同时投影到驻留计时器和
  WorkManager。系统 Worker 可扫准入账本并拉取云任务，工作完成时交还系统窗口。已有连接且已开启
  云任务的设备另外使用 15 分钟周期的原生补拉，系统可推迟。OS Worker 停止和首次解锁前读取失败
  都不会改写未读的账本。
- Gmail 复用已有 Google 授权。首次建立按账户隔离的基线，后续只取 History 和 From／Subject
  元数据，先写持久事件与 held 项再推进 cursor。GitHub 通知接口不接受产品现有 GitHub App
  用户令牌，见 [GitHub API 文档](https://docs.github.com/en/rest/activity/notifications?apiVersion=2022-11-28#list-notifications-for-the-authenticated-user)。
- 前台可运行已有主 Bot 的普通 routine，审批状态按持久 ID 对账并恢复可继续的 run。带完成条件
  验证的 routine 暂留在到期状态，等待独立 verifier 的实现。Android 仍缺 routine 到期系统通知及
  审批系统通知投影；当前的审批对账只作用于 App 状态与 routine。
- v1 Android 没有 FCM／厂商推送接入，WorkManager 是系统择时的拉取通道。无运行时事实时，无法
  确认目标的任务留在云端，不抢先 ACK。TonoLink／BLE、LAN／PCLink 的挂起入口和设备端能力仍待
  接线与真机验证。

本文件是交接说明，权威始终是下面列出的 spec、schema 和 golden。

## 1. 先读

1. 仓库根 `AGENTS.md`（尤其 §2 规则 1–3：一个边界一个权威、不只改一端、不放宽契约）。
2. 变更单 [PC-20261120-engine-first-launch](../protocol-changes/PC-20261120-engine-first-launch.md)，revision 3。§3.1 是 ios-bot CCR 的裁定，§3.2 是宿主拥有的时间，§3.3 是到期信号修订。
3. 规范：
   - [host README §10.2](../../spec/host/v1/README.md)：单一编排者、WakeReason（13 个，封闭）、WakeLease、决策函数、ReadySweep 九步、静默启动可见性。
   - [host README §10.3](../../spec/host/v1/README.md)：五条不变量、WakeDemand、唤醒投影、OS 通道、第 8–9 步。
   - [bot v2 §3.3](../../spec/bot/v2/README.md)：Bot 负责的第 4–7 步，connectorUpdate held 项，connector cursor，routine / connector 的 demand。
   - [platform §14.2](../../spec/platform/README.md)：Android 的平台事实（无推送、WorkManager 最小 15 分钟、Android 14+ 后台启动 `dataSync` FGS 的限制、投影通道映射）。

## 2. 两端必须直接读取的共享文件（不准手抄）

| 文件 | 内容 | Kotlin 测试必须覆盖 |
|---|---|---|
| `spec/host/v1/golden/engine-launch.json`（revision 3）+ `schema/engine-launch.schema.json` | 常量、wakeReasons、decisions、steps、demandSources；决策 / sweep / 投影的正反向量 | `decisionVectors`、`invalidDecisionVectors`、`sweepVectors`、`invalidSweepVectors`、`projectionVectors`、`invalidProjectionVectors` 全部，拒绝原因要与 golden 一致 |
| `spec/bot/v2/held-inbox-item.schema.json` + `golden/held-inbox.phone.json` | `connector-update` 两个封闭分支（gmail、github）及负例 | 正例编解码往返；6 个 schema 负例和语义负例都拒绝 |
| `spec/bot/v2/connector-cursor.schema.json` + `golden/connector-cursor.json` | cursor 记录，GitHub cursor 是 `{since, lastModified}` | 有效、无效向量和变异 |
| `spec/bot/v2/proactive-decision.schema.json`、`proactive-settings` 与 `golden/proactive.json` | `connector-update` 主动 kind | did / skip 向量 |

参考 oracle：`python3 spec/host/v1/tools/test_engine_launch.py`。它独立实现了决策顺序、步骤门、投影与严格解码，并检查 README 表格与 golden 一致。Kotlin 的实现应该与它给出相同的答案。

Android 的 `EngineLaunchPolicyTest` 直接运行共享启动决策正例。`ProactiveVectorTest` 与 `HeldInboxGoldenTest` 直接读取共享的 `proactive.json` 与 `held-inbox.phone.json`。已移除 `BotUiStrings.kt` 中过期的 `runtime.notReady`。

## 3. 架构要点（与 iOS 相同的不变量，不同的通道）

- **I1 意图先落宿主**：所有请求先 durable 写入（outbox、admission journal、wake inbox、routine store、WakeDemand 账本），再做任何事。
- **I2 时间归宿主**：每个将来的到期点都是一条 `WakeDemand`（source 封闭：`botRoutine`、`connectorScan`、`dshSchedule`、`hostRetry`）。DSH 会话定时任务由宿主在引擎就绪时用现有 DSH remote `schedule/list {active:true, limit:1}` 镜像，不新增 Worker 面。
- **I3 一个入口**：只有编排者启动 / 恢复引擎；其他生产者写入后调 `wake(reason, lease)`。
- **I4 一个出口**：ReadySweep 是源注册表，九个源按固定顺序执行；**每个新的引擎实例**（无论是哪条路径启动的）恰好触发一次 sweep；喚醒合并规则见 §10.2.5。
- **I5 挂起前投影**：账本变化、进入后台、park 之前，都调用 `WakeProjection.plan`，把结果提交到 OS 通道。

Android 通道映射（platform §14.2）：`residentTimerAtMs` 对应进程内定时器；`backgroundEarliestMs` 对应一次性 `WorkManager`，initial delay 取到这个时刻。精确 `AlarmManager` 需要 `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM`，是单独的 Android 决定。后台 Worker 只做原生 pass；只有在允许启动 `dataSync` 前台服务的豁免条件下才启动引擎。

## 4. Android 入口

- `ProbeEngineViewModel` 的前台／ready 观察与 `ReadySweep` 执行九步。Bot 的启动、held、
  routine 和审批用 `AppBotRuntime`。
- `WakeDemandLedger` 和 `WakeProjection` 是本地账本与共享投影；`HostWakeScheduler` 提交
  `HostWakeWorker`；`CloudTaskCenter` 做相同的 pull → admit → ack 原生流程。
- `HostAutomation` 在 schedule 写入后请求重读，`ChatSendQueue` 投影 settle 重试日期。
- `GmailWakeScan` 和 `ConnectorUpdateOutbox` 分别负责 Gmail cursor 与跨重启去重。两端
  继续共用 held-inbox 和 connector-cursor 文档，Android 当前只接入 Gmail 的实际扫描。

## 5. iOS 实现可作对照（行为参考，不是可抄的契约）

| 关注点 | iOS 文件 |
|---|---|
| 决策 / 步骤门 / 投影 / 合并 / 租约窗口的纯函数 | `examples/probe-app/ProbeKit/Lifecycle/{EngineLaunchPolicy,ReadySweep,WakeProjection,WakeMerge,LeaseWindowPolicy}.swift` |
| 编排者（阶段 A–D、合并、源注册表、第 1–3、8–9 步） | `examples/probe-app/PhoneDSHProbe/EngineLaunchOrchestrator.swift` |
| 账本（读不到 ≠ 不存在 ≠ 损坏） | `examples/probe-app/ProbeKit/Lifecycle/WakeDemand.swift`、`WakeScheduler.swift` |
| Bot 第 4–7 步、routine / connector demand | `Sources/PhoneDSHBot/{Wake,Routines,Connectors}/`、`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift` |

**两个容易踩的坑**（iOS 审查中都发现过，Android 同样适用）：
1. **读不到不等于不存在。** 文件存在但暂时读不了（Android 的 Direct Boot / 凭据加密存储在首次解锁前不可用），既不能当成「没有」，也不能当成「损坏」。账本和 connector cursor 在这种情况下必须跳过（`skipped(gate)`），并在解锁后重试；绝不能重置或覆盖，否则会丢到期时间，或静默跳过新邮件。
2. **租约窗口跟着工作结束。** `parkMarginMs` 是最晚停止点，不是必须等待的时间。没有回合在跑就立即结束 Worker；有回合就等它结束，或者等到 `deadline − parkMarginMs`。

## 6. 验收（Android 端）

- `bash android/tools/with-android-toolchain.sh ./gradlew :bot:test :net:test :app:testDebugUnitTest --no-daemon`，其中必须有读取上面共享 golden 的测试。
- `bash scripts/ci/check.sh --only phone-android-structure,phone-android-tests,phone-spec,phone-cross-tree`
- 变更单中 Android 一端的状态从 `not started` 更新为实际状态，并按 AGENTS.md §3.5 给出交接证据。
- 设备上的 WorkManager / FGS 时序只能用真机证明；模拟器结果记为 `NOT_RUN`，不能当作设备结论。
