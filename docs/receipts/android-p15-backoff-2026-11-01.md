<!-- SPDX-License-Identifier: MIT -->
# P15 证据：第二个状态机死胡同 —— `Backoff`（2026-11-01）

同一天的第二个死胡同，形状与 P10 的 `Draining` 相同但**根因不同**：`Draining` 纯属「缺执行者」，
`Backoff` 是「缺执行者 **+** 契约有洞」。本文件是设备原始日志、逐条契约对照、改法与反向验证。

- 设备：自建 AVD `p15-5578`（`system-images;android-35;google_apis;arm64-v8a`，pixel_6，4 核 / 2 GB），
  端口 **5578**，SDK 35，`arm64-v8a`，`-no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect`。
- 探针：真实 `https://api.deepseek.com/anthropic`，key 经 `run-as … files/import-key.txt` 落盘后由
  `ApiKeyStore.importDevelopmentKey` 导入并删除明文（key 不出现在任何仓库文件里）。
- 清理：实验结束 `adb emu kill` + `avdmanager delete avd -n p15-5578`。

## 1. 复现（修复前，APK = 改动前源码）

启动 → `Recovering -> Running` → `svc wifi disable` + `svc data disable`：

```
11-01 12:44:17.803 I/PDSHHost( 4943): D14 Running -> Backoff via networkPath(unsatisfied) at 1386345 ms (admission=closed, effects=3)
11-01 12:44:17.813 D/PDSHHost( 4943): effect 'start the retry schedule' has no Notifier surface in this lane
```

`svc wifi enable` + `svc data enable` 之后：

```
11-01 12:44:26.935 D/PDSHHost( 4943): D14 observed networkPath(satisfied): network path recorded for the Backoff guard; no D14 edge
11-01 12:44:30.788 D/PDSHHost( 4943): D14 observed networkPath(satisfied): network path is already satisfied; no D14 edge
11-01 12:44:33.708 D/PDSHHost( 4943): D14 observed networkPath(satisfied): network path is already satisfied; no D14 edge
```

65 s 后整个进程**只有 1 条**状态迁移（`grep -c "D14 .* -> "` = 1）：永久停在 `Backoff`，
admission 永远 closed。日志本身点名了缺口：`effect 'start the retry schedule' has no Notifier surface in this lane`。

## 2. 契约对照（`spec/v1/budgets.md`，只读）

| 位置 | 原文 | 结论 |
| --- | --- | --- |
| `budgets.md:19` | `Backoff`「Upstream 429/5xx or no network path; retry with backoff and jitter.」 | 入口有两个，退出的概念只有一个 |
| `budgets.md:48` | `Running → Backoff`：guard「429/5xx response or NWPath unsatisfied」；actions「Close admission; **start the retry schedule**」 | 动作有名字，**没有 owner**（(A)） |
| `budgets.md:49` | `Backoff → Running`：guard「**Retry-After elapsed**, network path satisfied, **one probe succeeded**」 | 三个合取项；「Retry-After」与「probe」都没有 Source |
| `budgets.md:64-74` | §3 Driving signals 表 | 有 scenePhase / thermal / battery / NWPathMonitor / lease verification 的 Source；**没有 retry scheduler，也没有 probe** |
| `budgets.md:72` | NWPathMonitor 行：「satisfied → `Backoff` → `Running` **after one successful probe**」 | 与 :49 **互相矛盾**：这里不提 Retry-After |

结论：**(A) 缺执行者 + (B) 契约有洞，两者必须分开处理。**

- **(A)** `START_RETRY_SCHEDULE`（`ControllerEffect.kt:27`）无执行者；`RetryAfterElapsed`（`ControllerSignal.kt:70-73`）与
  `RetryProbeSucceeded`（`ControllerSignal.kt:75-81`）在**任何 main 源集**都没有生产者（只有测试）。
  这与 `Draining` 完全同形：边和信号都定义了，没人喂。
- **(B)** `Backoff → Running` 的 guard 要求 `isRetryAfterElapsed`（`ControllerStateMachine.kt:407-412`），
  而 NWPath 入口**根本没有 retry-after 概念**：入口没有 HTTP 响应，`UpstreamUnavailable(statusCode)`
  也**不携带** `Retry-After` 头，`HostSignalMapping.networkPath()` 只产出 satisfied/unsatisfied。
  §2:49 与 §3:72 对同一条边给出两种说法，而「NWPath 入口的 Retry-After 是什么」**契约没说**。
  同一处还有第二个洞：`onUpstreamUnavailable` 把 `isNetworkPathSatisfied` 重置为 false
  （`ControllerStateMachine.kt:356`），所以 429 入口即使有 retry-after，也必须等一次**新的** NWPath(satisfied)
  才能满足 guard —— 网络本来就没坏，那条观察不会再来。

## 3. 改了什么（实现侧，guard 一个字没动）

新增 `android/dsh/src/main/kotlin/com/phonedsh/dsh/host/`：

| 文件 | 职责 |
| --- | --- |
| `RetryLane.kt` | 每个 `Backoff` 入口一条 schedule：窗口到 → feed `RetryAfterElapsed` → 等 path satisfied → 跑一次 probe → 成功才 feed `RetryProbeSucceeded(leaseVerified=true)`；失败**不 feed**，只排下一个窗口 |
| `RetryProbe.kt` | 「one probe succeeded」的 seam；默认实现 = §2 Actions 列唯一点名的检查（一次 lease check），不是 hard-coded `true` |
| `RetryPolicy.kt` |  Exponential + 60 s cap + 20 % 向下抖动 + 5 次饱和（与 Swift `ModelGatewayBackoffPolicy` 默认值同节奏）；`Retry-After` 提示若存在则优先 |
| `HostStateStore.kt` | `host-state.json`（`PERSIST_HOST_STATE` 的执行者），字段与 Swift `PersistedHostState` 一致 |

接线（`PhoneDshHost.kt`）：`applyHostEffects` 执行 `START_RETRY_SCHEDULE` → `retry.arm(entry)`；
离开 `Backoff` → `retry.release()`；`dispatch` 在 `Backoff` 内把 NWPath 观察转给 lane；
`PERSIST_HOST_STATE` → `stateStore.save(...)`；boot 映射落在 `Backoff` 时用 `backoff_until_ms` 的剩余窗口 arm。
`android/app/.../ProbeEngineViewModel.kt`：`boot(persistedState = hostStateStore.load()?.state)`，
注入 `stateStore = hostStateStore`（此前是字面量 `null`，每次都是 `COLD_START`）。

## 4. 契约洞的改法建议（**未改 spec**，转 spec owner）

1. `budgets.md:49` 拆成两条边，按入口区分 guard：
   - `Backoff(upstream)` → `Running`：「Retry-After elapsed **或** 指数退避窗口 elapsed；一次 probe 成功」；
   - `Backoff(nwpath)` → `Running`：「NWPath satisfied；一次 probe 成功」——**没有 Retry-After**。
2. `budgets.md:64-74` 增加两行 Source：`retry scheduler`（controller；窗口到 → probe）、`retry probe`（controller；一次 lease check）。
3. `budgets.md:72` 的「after one successful probe」与 :49 的三合取项对齐，或明确 :72 是 :49 的简写。
4. `Backoff(upstream)` 进入时不应把「network path satisfied」清零（实现里 `ControllerStateMachine.kt:356`）：
   路径没变，清了之后 guard 只能等一条不会再来的观察。

## 5. 单测与反向验证

新增 `BackoffExitTest`（6）、`RetryLaneTest`（4）、`HostStateStoreTest`（7）。反向验证（逐个删生产者 → 对应测试红）：

| 删除的东西 | 结果 |
| --- | --- |
| `applyHostEffects` 里的 `armRetry(...)` | `BackoffExitTest` 4 failures（`aLostNetworkParks…`、`theUpstreamEntry…`、`everyTransitionPersists…`、`aFailedProbeKeeps…`） |
| `dispatch` 里的 `retry.onNetworkPath(...)` | `BackoffExitTest` **5** failures（多 `aHostBootedIntoAPersistedBackoffCanLeaveIt`） |
| `RetryLane.run` 里的 `onRetryAfterElapsed(...)` | `BackoffExitTest` 4 + `RetryLaneTest` 2 failures |
| `RetryLane.run` 里的 `onProbeSucceeded(...)` | `BackoffExitTest` 4 + `RetryLaneTest` 1 failure |
| `applyHostEffects` 里的 `persistHostState()` | `everyTransitionPersistsTheHostState` 红 |

## 6. 设备验证（修复后，pid 6216，同一进程）

```
11-01 12:53:16.907 I/PDSHHost( 6216): D14 Running -> Backoff via networkPath(unsatisfied) at 1925454 ms (admission=closed, effects=3)
11-01 12:53:16.907 I/PDSHHost( 6216): retry schedule (network_path): attempt 1 in 971 ms (window 971 ms, admission stays closed)
11-01 12:53:17.881 I/PDSHHost( 6216): retry schedule (network_path): the window elapsed; feeding RetryAfterElapsed for attempt 1
11-01 12:53:17.881 I/PDSHHost( 6216): retry schedule (network_path): attempt 1 waits for a satisfied network path before the probe (the guard needs both)
11-01 12:53:24.924 I/PDSHHost( 6216): retry probe succeeded (network_path, attempt 1); feeding RetryProbeSucceeded(leaseVerified=true)
11-01 12:53:24.924 I/PDSHHost( 6216): D14 Backoff -> Running via retryProbeSucceeded(leaseVerified=true) at 1933471 ms (admission=open, effects=5)
11-01 12:53:31.653 I/PDSHAppTurn( 6216): APP_TURN_BUTTON prompt=40 chars
11-01 12:53:38.079 I/PDSHAppTurn( 6216): APP_TURN_OK session=session-0f9dac5b-… kinds=…,tool_call,tool_result,…,turn_ended reason=completed tool_edges=true
```

同一进程内另有第二次连续抖动（`12:47:57` unsatisfied → `12:47:59` satisfied）也被同一条 schedule 正常带回 `Running`。
`host-state.json` 的 `backoff_until_ms` 在 `Backoff` 期间有值、回到 `Running` 后归 `null`。

## 7. P10 列的四个无 owner 项

| 项 | 处置 |
| --- | --- |
| `PERSIST_HOST_STATE` | **做了**：`HostStateStore` + boot 读取；设备证据 `boot: disposition=crash_recovery, state=Running (persisted_running)` |
| `PlannedRestartRequested` | 仍无生产者；§2 的 `Running → Recovering`（planned restart）在 Android 不可达 |
| handoff / reclaim | 仍无生产者；`HandingOff`/`Remote`/`Reclaiming` 三个状态在 Android 不可达（`persisted HandingOff → Failed` 因此也不可达） |
| `START_BACKGROUND_TASK` | 本 App 无 service，drain 毫秒级完成，`DrainOutcome.backgroundWindow=false` 报告（P10 已判定 drain 不需要它） |

## 8. 没做到的 / open questions

- **进程内 engine 重启会撞 mseq 水位**：`停止/启动` 后 worker 还带旧 mseq(87)，宿主 WAL 已到 1811，
  `WAL allocated mseq 1811 for the worker's 87; closing the transport` → `HANDLER_FAILED`。这是 engine/WAL 车道的既有行为，
  与本轮改动无关；复验时必须整进程重启。
- **网络抖动会杀死 WebView 的有序通道**：`channel closed cause=CLIENT_CLOSED` 后 UI 显示「未连接」，不会自愈
  （12:47:39 那次 turn 因此 `APP_TURN_FAILED reason=api_aborted`）。D14 状态是对的，缺的是 engine 侧重连。
- **probe 的语义**：本轮按 §2 Actions 列取「一次 lease check」。若 spec owner 指的是真正的网络探测（§3:72 的措辞），
  `RetryProbe` 这个 seam 直接换实现即可，`RetryLane` 不用改。
- `UpstreamUnavailable` 在 Android **没有生产者**（模型边缘未接线），所以 429 入口今天只在单测里被驱动。
