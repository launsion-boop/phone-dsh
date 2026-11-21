# 交接给 Android：引擎优先启动、静默后台启动、远程唤醒与宿主拥有的时间

记录时间：2026-11-20。iOS 端已在分支 `feat/engine-first-launch` 实现（PR 见本文件所在提交的 PR）。Android 已接入冷启动决策和连接器暂存消息。到期账本、系统调度、完整 ReadySweep 和增量扫描仍待实现。本文件是交接说明，不是契约：权威始终是下面列出的 spec、schema 和 golden。

## 1. 先读

1. 仓库根 `AGENTS.md`（尤其 §2 规则 1–3：一个边界一个权威、不只改一端、不放宽契约）。
2. 变更单 [PC-20261120-engine-first-launch](../protocol-changes/PC-20261120-engine-first-launch.md)，revision 3。§3.1 是 ios-bot CCR 的裁定，§3.2 是 revision 3（宿主拥有的时间）。
3. 规范：
   - [host README §10.2](../../spec/host/v1/README.md)：单一编排者、WakeReason（13 个，封闭）、WakeLease、决策函数、ReadySweep 九步、静默启动可见性。
   - [host README §10.3](../../spec/host/v1/README.md)：五条不变量、WakeDemand、唤醒投影、OS 通道、第 8–9 步。
   - [bot v2 §3.3](../../spec/bot/v2/README.md)：Bot 负责的第 4–7 步，connectorUpdate held 项，connector cursor，routine / connector 的 demand。
   - [platform §14.2](../../spec/platform/README.md)：Android 的平台事实（无推送、WorkManager 最小 15 分钟、Android 14+ 后台启动 `dataSync` FGS 的限制、投影通道映射）。

## 2. 两端必须直接读取的共享文件（不准手抄）

| 文件 | 内容 | Kotlin 测试必须覆盖 |
|---|---|---|
| `spec/host/v1/golden/engine-launch.json`（revision 2）+ `schema/engine-launch.schema.json` | 常量、wakeReasons、decisions、steps、demandSources；决策 / sweep / 投影的正反向量 | `decisionVectors`、`invalidDecisionVectors`、`sweepVectors`、`invalidSweepVectors`、`projectionVectors`、`invalidProjectionVectors` 全部，拒绝原因要与 golden 一致 |
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

## 4. Android 现状的关键入口（已读代码）

- `android/app/.../probe/ProbeEngineViewModel.kt`：`init` 里已经先 `appBotRuntime?.start()` 再 `host.start()`，顺序接近阶段 A→B，但没有 ReadySweep，也没有账本。`startBotRuntime()` / `stopBotRuntime()` 跟随 Activity 的 `onStart` / `onStop`。
- `android/app/.../probe/MainActivity.kt`：`onStart` 调用 `CloudTaskCenter.appBecameActive()`；`onStop` 停止 Bot runtime。
- `android/app/.../probe/cloudtasks/`：无推送，`push: null`；没有编排者。
- `android/bot/.../wake/WakeInboxModels.kt`：`WakeSignalSource` 接口已存在。
- `android/net/.../connectors/{gmail,github}/`：需要增量查询（Gmail `history.list`，GitHub notifications 的 `since` + `If-Modified-Since`），只取元数据。
- `android/dsh/.../background/`：`TombstoneScheduler`（WorkManager）、`dataSync` FGS。

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
