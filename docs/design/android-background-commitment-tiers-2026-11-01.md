<!-- SPDX-License-Identifier: MIT -->
# 承诺分级表：Android 后台执行（P4 / 计划 §7.9）

日期：2026-11-01 · 车道：L39（后台与 OEM 接到 App 上）
状态：**接线完成（决策 a）**；端到端「切走仍续跑」**未达成**，卡点不在本车道（见 §5）

## 1. 决策：a —— 接线

`:dsh` 的后台机械（`TurnJobScheduler` / `TurnForegroundService` / `TurnJobService` /
`TombstoneScheduler` / `InterruptedTurnStore` / `TurnNotifications` / `BootReceiver` /
`TurnStopReceiver`）只读不改，`:app` 侧把调用点补上，并把 `HostNavFacts` 里硬编码的
`foregroundService = FactState.NO` 换成实测。

不选 (b)「只接 WorkManager」的理由：WorkManager 在这套机械里**不是回合通道**，只有墓碑
（`TombstoneScheduler` 的 15 分钟延期任务）。回合通道是 UIDT（API 34+）与 dataSync FGS
（API 26–33，或 UIDT 被拒时的回退），这正是计划 §7.2 的口径。
不选 (c)「明确不做」的理由：P4 要求的就是这条；且窗口是「诚实恢复 + 通知可见 + 优雅停止」
三件事的载体，不是可选装饰。

## 2. 两个前提的更正（一手读数）

| 派发时的说法 | 实测 | 证据 |
| --- | --- | --- |
| `TurnJobScheduler` 用 WorkManager（不是 UIDT） | **不成立**。它构造 UIDT `JobInfo`（`setUserInitiated(true)` + 网络估计字节 + 网络约束）交给 `JobScheduler.schedule`；WorkManager 只出现在 `TombstoneScheduler` | `TurnJobScheduler.kt:133-160`；设备上 `userInitiatedApproved: true (started as UIJ: true)` |
| manifest 里 service 0 / receiver 0 | **对 `:app` 的源 manifest 成立，对装出来的 APK 不成立**。`android/dsh/src/main/AndroidManifest.xml` 声明了 2 个 service + 2 个 receiver + 6 个权限，`:app` 依赖 `:dsh`，合并后全部进 APK | `aapt2 dump xmltree app-debug.apk`；`dumpsys package com.phonedsh.probe` |

所以真缺口只有一个：**`:app` 从不调用 `TurnBackground.start`**。`HostNavFacts` 的注释
「This app declares no service at all in its manifest」是照着源 manifest 写的，因此把一个
已经具备的能力报成了 NO —— 这是「谎报」的另一种形式。

**因此 `:app` 的 manifest 没有新增任何组件或权限**：四个组件已在 APK 里，重复声明会变成
第二个事实来源。该文件只加了一段注释，写清「源 manifest 看起来是 0，合并产物不是」以及
怎么读合并产物，避免下一个车道再照源文件下结论。

## 3. 接线点

| 位置 | 作用 |
| --- | --- |
| `ProbeEngineViewModel.runTurn()` | `ProbeRecovery.beginTurn()` 返回本轮 epoch，随后**在第一个 await 之前**调 `HostBackground.startTurn(epoch)`：UIDT 只能在可见时调度，FGS 在 Android 12+ 不能在后台启动 |
| `ProbeRecovery.endTurn()` → `HostBackground.endTurn()` | 关窗口 + 删 durable marker；成功、失败、协程被取消（`finally`）三条路径都会走到 |
| `MainActivity` | `跑一轮` 时若 `POST_NOTIFICATIONS` 未答，先问、拿到答案再跑（拒绝也照跑，降级为仅前台）；答案回来 bump `backgroundRevision`，让 facts 重算 |
| `HostBackground.declaration()` | `PackageManager` 回读合并后的 manifest：两个 service、两个 receiver、dataSync 类型、`FOREGROUND_SERVICE_DATA_SYNC` / `RUN_USER_INITIATED_JOBS` |
| `HostBackground.readings()` | 再加 `NotificationCapability.probe` 与 SDK 级别 |
| `backgroundWindowFact()` | 纯函数：通知不可见 → NO + 具体原因；否则「FGS 可用 or UIDT 可用」→ YES，都不行 → NO + 缺哪个组件 |

`foregroundService` 这个 fact 的定义沿用 `RuntimeSnapshot` 的 KDoc（「能不能开一个前台服务」），
所以它报的是**窗口能力**，不是「这一轮一定会跑完」。渲染面：运行时详情 → 前台服务 →
前台服务可用性；同时喂设置页「后台运行」开关与「系统通知」行（后者从 `UNKNOWN` 变成实测）。

## 4. 承诺分级表

证据等级按仓库纪律：**真机 gate** > **模拟器 gate** > **单测/代码** > **未测**。
本表所有「模拟器 gate」都是 API 35、自建 AVD（端口 5682，`-no-window`，用后删除），
**模拟器证据不向真机传递**。

| 场景 | 产品承诺 | 本车道实测 | UI 呈现 | 状态机映射 | 证据等级 |
| --- | --- | --- | --- | --- | --- |
| 前台 / 充电 | 回合必完成 | 未回归（既有能力） | 进度可见 | `Running` | 真机 gate 待补 |
| 后台窗口可开 | UIDT 或 dataSync FGS 起得来 | **达成**：job 8401 注册并进入执行槽；通知 7301 挂在 job 上；进程 `oom adj = 201`（非 cached） | 常驻通知「回合执行中」+「停止本轮」 | — | 模拟器 gate |
| 锁屏 / 切走（窗口在位） | 尽量完成；系统中断则诚实恢复 | **部分**：窗口开了，但宿主 drain 立刻停 worker → 回合以 `channel_lost` 结束（§5） | 通知 + 停止按钮 | `Running → Draining → Parked`（实测） | 模拟器 gate |
| 进程被杀 | WAL 到哪算哪；重启后可恢复 | 墓碑已注册（`Trace tag: TombstoneWorker`，最小延迟 14m59s964ms），送达未测 | 墓碑通知「第 N 步被中断」 | `Recovering` | 模拟器 gate（仅注册） |
| Task Manager Stop / OEM force-stop | 零回调；下次打开报告最后检查点 | 未测（本车道未做 kill 矩阵） | 下次打开时报告 | `Recovering`（无 drain） | 未测 |
| 低电 / 热压力 | 按策略降级 | **未实现**：thermal/battery 映射表不在本车道，页面显 未知 | 提示（缺） | `Running → Backoff` | 未测 |
| 重启后 | 不自动续跑；引导打开 app | `BootReceiver` 在 APK 里（aapt2 实测），送达未测 | BOOT 通知 | `Parked → Recovering` | 未测 |

两条硬边界（计划 §7.9 原文）：dataSync 6h 上限 → 超长回合按 `Draining` 收尾；Android 15
禁 `BOOT_COMPLETED` 起 dataSync FGS + Android 12+ 禁后台起 FGS → 「后台计划重启」改为
「下次前台补做」。本车道没有改变这两条。

### 4.1 「第 N 步」这一步还差什么

`TurnRequest.step` 现在是 0：`DshTurnClient` 没有逐事件的回调口子，`:app` 拿不到 tool
边界，所以 `TurnBackground.progress()` 没有被调用。后果是墓碑/中断文案说「进程在记录到
步骤之前被系统结束」，而不是「第 N 步」。这是**已知缺口**，不是谎报：进度条保持不确定态，
不编百分比（`TurnNotifications` 的规则），比编一个 step 诚实。

## 5. 端到端未达成：drain 不认识窗口（本车道外的卡点）

设备实测（API 35，HOME 键）：

```
PDSHHost: D14 Running -> Draining via scenePhase(background)
PDSHHost: drain: closing the epoch now (deadline in 19995 ms; no background window: this App declares no service)
PDSHHost: drain: epoch closed, durable_upto=25
PDSHHost: drain stops the worker (STOP_WORKER of Draining -> Parked)
PDSHEngine: state: Running -> Stopped
PDSHAppTurn: APP_TURN_FAILED reason=channel_lost
```

窗口确实在（`dumpsys jobscheduler` 里 8401 正在跑，slot `Running for: +32s`，进程
`oom adj=201`），但**宿主的 D14 策略在 `scenePhase(background)` 上无条件 drain 并停 worker**，
所以「切走仍续跑」这条承诺今天仍然不成立；窗口买到的是：进程不被降成 cached、通知可见、
停止按钮可用、epoch 在 drain 里正常关闭（`durable_upto=25`），而不是回合续跑。

修法在 `:dsh`（`DrainLane` / `PhoneDshHost` 的 `scenePhase(background)` 映射要知道「窗口开着」），
不在本车道的可写范围。`DrainLane` 里 `backgroundWindowAlways` 是 `false` 且只影响日志里的
`background_window=`，不影响状态机是否 drain —— 即使把它改成 true 也救不了回合。

在此之前，运行时详情那行「可用 / 应用退到后台时仍能继续回合」的**后半句是 UI 文案的过度承诺**：
它来自 `:lib` 的 `UiStrings.RUNTIME_FGS_AVAILABLE_HINT`，本车道不能改。要么 drain 先学会窗口，
要么这句文案降级成「后台窗口可开」。

## 6. 已知缺口（都登记，不静默）

1. **drain 停 worker** —— §5，`owner: :dsh host/controller`。
2. **step 进度** —— §4.1，需要 `DshTurnClient` 暴露逐事件回调。
3. **`BackgroundPage` 不在 App 的路由里** —— 它读的 `BackgroundSnapshot` 不是 `PdshNavFacts`
   的字段（`PdshNavFacts.kt` 没有 background 成员），`:lib/ui/page` 又属于别的车道，所以
   本车道把真读数落在既有三行上（运行时详情的 FGS 行、设置的后台运行、设置的系统通知）。
   要接 `BackgroundPage` 得先在 `:lib` 给它一个 facts 字段。
4. **thermal/battery 映射表** —— 计划 §7.10 要求显式表（含取不到信号时的默认档），未做。
5. **renderer WAIVED 回收阈值** —— 计划 P4 列了，本车道未涉及（属 `:engine` 车道）。
6. **dataSync FGS 回退路径未在本车道实测** —— 本车道只在 API 35 上跑了 UIDT；FGS 是
   `:dsh` 的 `Api33FallbackInstrumentedTest` 覆盖的段，本车道未复测。
7. **`notifier = DisabledNotifier`** —— `ProbeEngineViewModel` 传给宿主的仍是 DISABLED，注释
   理由是「`:app` 没有通知通道、也没有 POST_NOTIFICATIONS 流程」。这个理由现在不成立了
   （通道由 `TurnNotifications.ensureChannels` 建、权限由 `MainActivity` 问），但换 Notifier
   属于宿主恢复播报，不在本车道。

## 7. 证据目录（本车道跑过什么）

| 命令 | 结论 |
| --- | --- |
| `aapt2 dump xmltree app-debug.apk --file AndroidManifest.xml` | `TurnForegroundService`（`foregroundServiceType=0x1`、`stopWithTask=true`）、`TurnJobService`（`BIND_JOB_SERVICE`）、`TurnStopReceiver`、`BootReceiver`(BOOT_COMPLETED) 全在 APK 里 |
| `adb shell dumpsys package com.phonedsh.probe` | 5 个后台权限 `granted=true`；`BootReceiver` 有 filter |
| 点 `跑一轮` → 允许通知 | `BG_TURN_START channel=USER_INITIATED_JOB app_visible=true epoch=… declared=BackgroundDeclaration(foregroundService=true, dataSyncType=true, dataSyncPermission=true, jobService=true, userInitiatedPermission=true, stopReceiver=true, bootReceiver=true) result=uidt_scheduled:8401` |
| `adb shell dumpsys jobscheduler` | `JOB #u0a207/8401 … TurnJobService`；`Priority: 500 [MAX]`；`Network download/upload bytes: 8388608`；`Required constraints: CONNECTIVITY`；`userInitiatedApproved: true (started as UIJ: true)`；slot `Running for: +32s, timeout at: +4m28s` |
| 同上 | `JOB androidx.work.systemjobscheduler:u0a207/0 … Trace tag: TombstoneWorker`，`Minimum latency: +14m59s964ms` |
| `adb shell dumpsys notification --noredact` | id 7301、channel `pdsh_turn_progress`、`flags=ONGOING_EVENT|ONLY_ALERT_ONCE|USER_INITIATED_JOB`、标题「回合执行中」、action「停止本轮」、`progressIndeterminate=true` |
| 通知栏截图 | 「回合执行中」+ 不确定进度条 + 展开可见停止按钮 |
| HOME 后 1s `dumpsys activity processes` | `oom adj: cur=201`（非 cached）、`Services: TurnJobService` |
| `pm revoke POST_NOTIFICATIONS` 后重开 | 运行时详情 → 前台服务可用性 = **不可用**，副标题「通知权限未授予（POST_NOTIFICATIONS）：后台通道要求进度通知可见，回合降级为仅前台」 |

## 8. open questions

1. `scenePhase(background)` 要不要按「有窗口」分叉？如果要，信号源是 `:dsh` 宿主还是
   `:controller` 的 D14 表？（本车道倾向：D14 表新增一个「窗口在位」守卫，宿主只提供读数。）
2. 计划 §7.9 说锁屏「尽量完成」，但 D14 表把 `scenePhase(background)` 直接映射到
   `Draining`（= 关 epoch + 停 worker）。两者只能有一个是对的 —— 需要 §7.9 与 budgets.md §2
   对齐，否则每一版实现都会照着其中一份写出另一种行为。
3. `RUNTIME_FGS_AVAILABLE_HINT` 的文案权属：`:lib` 说「应用退到后台时仍能继续回合」，
   但这一轮不是它保证的。fact 报 YES（窗口能力）而文案承诺续跑，两边该由谁改口径？
4. 真机 gate（华米 OV 星 + 三星）还没跑；本表的「模拟器 gate」不能升级成真机承诺。
