<!-- SPDX-License-Identifier: MIT -->
# `:dsh` 后台车道证据附录：API 33 上的 dataSync 回退实测（K4）

> 本文件是**证据记录**，不是设计文档。设计见方案 §7.2（官方通道选型）、
> §7.9（承诺分级表）、§7.10（评审补充）；白名单条目见
> `spec/platform/whitelist.json` 的 `platform.bgtask-drain-window` 与
> `platform.fgs-turn-notification`。
>
> 它存在的唯一原因：F7 车道交付时写明「API 26–33 的 FGS 回退分支只有纯函数单测
> （`TurnChannel.select`），没有 API 33 镜像实测」。API 34+ 才有 UIDT，所以
> **API 33 是回退路径唯一的实测机会**。本文件把能测的测了，测不了的逐条写成
> BLOCKED。

## 0. 宿主与复现

| 项 | 值 |
| --- | --- |
| 设备 | `emulator-5556`（AVD 名 `pdsh33(AVD)`，`sdk_gphone64_arm64`） |
| 系统 | API 33 / Android 13 |
| 应用 targetSdk | 35（`dumpsys` 的 `infoAllowStartForeground` 里可见 `targetSdkVersion:35`） |
| 另一台 | `emulator-5554` = API 35，**本车道按约束未运行任何命令** |

```sh
cd android
export JAVA_HOME="$JDK21_HOME"            # JDK 21
export ANDROID_HOME="$ANDROID_SDK"        # Android SDK（含 platform-tools、platforms;android-35）
export ANDROID_SERIAL=emulator-5556
./gradlew :dsh:connectedDebugAndroidTest --no-daemon --console=plain
```

只跑本车道新增的类：

```sh
./gradlew :dsh:connectedDebugAndroidTest --no-daemon --console=plain \
  -Pandroid.testInstrumentationRunnerArguments.class=com.phonedsh.dsh.background.Api33FallbackInstrumentedTest
```

测试 APK 是 library 的自插桩 APK（`com.phonedsh.dsh.test`，`target=com.phonedsh.dsh.test`）；
套件跑完后 AGP 会卸载它。下面的两段手工探针对此有依赖，步骤写在对应小节。

### 证据等级用词（全文统一）

| 标记 | 含义 |
| --- | --- |
| **实测(33)** | 在 `emulator-5556` 上跑出来的断言/输出 |
| **F7(35)** | F7 车道在 `emulator-5554` 上的既有结论；本车道未复跑，只引用 |
| **纯函数** | JVM 单测（`src/test/.../TurnChannelTest.kt`），不碰设备 |
| **源码** | 读 AOSP 源码得出，未在设备上观测 |
| **BLOCKED** | 本镜像做不到，文中写明缺什么 |
| **未验证** | 既没有实测也没有源码支撑 |

## 1. API 33 上的真实结果 — **上一轮记录，本轮未重跑**

> 本节数字来自较早的一次 instrumented 运行，**没有在 2026-10-31 的最终树上重跑**。
> 按本仓库的规矩，这属于「曾经测过、当前未测量」——引用时必须带上这句话，
> 不能当成当前代码的证据。`android/README.md` 的 `NOT_VERIFIED` 口径适用于它。

### 当时的结果（12 个 instrumented 用例）

`Starting 12 tests on pdsh33(AVD) - 13` → `BUILD SUCCESSFUL`；
XML 汇总：`tests=12 failures=0 errors=0 skipped=3`。

| 用例 | API 33 结果 | 备注 |
| --- | --- | --- |
| `Api33FallbackInstrumentedTest#deviceSelectorReturnsTheForegroundServiceAndUidtDoesNotExistHere` | **PASS（新）** | 真实 `SDK_INT` 选 FGS；UIDT 方法反射不存在 |
| `Api33FallbackInstrumentedTest#realStartForegroundServiceOpensADataSyncWindowSeenByDumpsys` | **PASS（新）** | 真实起服务 + `dumpsys` 断言 |
| `ForegroundServiceInstrumentedTest#foregroundServicePostsOngoingProgressNotificationWithStopAction` | PASS | 通知/停止按钮/durable marker |
| `ForegroundServiceInstrumentedTest#stopActionOnNotificationClosesAdmissionAndRemovesNotification` | PASS | 停止入口 |
| `ForegroundServiceInstrumentedTest#removingTheTaskStopsTheServiceAndLeavesTheMarker` | PASS | `stopWithTask` |
| `ForegroundServiceInstrumentedTest#runtimePermissionDeniedSelectsForegroundOnlyAndOpensNoWindow` | **SKIP（套件内）/ PASS（手工 revoke 后实测）** | revoke 会杀进程，套件不能原地翻；见 §1.1 |
| `TombstoneInstrumentedTest#tombstoneWorkIsEnqueuedVisibleAndOnlyNotifies` | PASS | 真 WorkManager + 真通知 |
| `TombstoneInstrumentedTest#bootReceiverPostsGuidanceAndStartsNothing` | PASS | 直接调用 receiver |
| `TombstoneInstrumentedTest#packageScopedBootBroadcastIsNotTreatedAsAReboot` | PASS | 包作用域 BOOT 不误报 |
| `UserInitiatedJobInstrumentedTest#userInitiatedJobIsBuiltScheduledAndPostsItsOwnProgressNotification` | **「PASS」但零断言 = BLOCKED** | 打印 `UIDT_BLOCKED: API 33 < 34` 后 `return`；JUnit 记为 PASS，不能当证据 |
| `ForceStopProbeInstrumentedTest#startTurnThenWaitForForceStop` | **SKIP（套件内）/ PASS（两段手工 probe）** | 见 §1.2 |
| `ForceStopProbeInstrumentedTest#nextOpenReadsTheInterruptedTurn` | **SKIP（套件内）/ PASS（两段手工 probe）** | 见 §1.2 |

> 注意上表第 10 行：这是现有套件在 API 33 上的一个**诚实性陷阱**——UIDT 用例
> 在 34 以下提前返回，AGP 仍报 PASS。本附录把它记作 BLOCKED，不当通过。

### 1.1 通知链路降级分支（套件外实测）

`runtimePermissionDenied...` 在套件里必然 SKIP（`pm revoke` 杀死插桩进程）。手工跑法：

```sh
adb -s emulator-5556 install -r -t \
  android/dsh/build/outputs/apk/androidTest/debug/dsh-debug-androidTest.apk
adb -s emulator-5556 shell pm revoke com.phonedsh.dsh.test android.permission.POST_NOTIFICATIONS
adb -s emulator-5556 shell am instrument -w \
  -e class 'com.phonedsh.dsh.background.ForegroundServiceInstrumentedTest#runtimePermissionDeniedSelectsForegroundOnlyAndOpensNoWindow' \
  com.phonedsh.dsh.test/androidx.test.runner.AndroidJUnitRunner
```

结果（实测(33)）：`OK (1 test)`。即真实满足：

* `capability.progressVisible == false`，`degradedReason == RUNTIME_PERMISSION_DENIED`；
* `TurnBackground.channel(context) == FOREGROUND_ONLY`；
* `TurnBackground.start(...) == ForegroundOnly(NOTIFICATIONS_UNAVAILABLE)`；
* 没有 FGS 窗口、没有 `PROGRESS_NOTIFICATION_ID` 通知；
* 中断被 `TombstoneScheduler` 排队成「下次打开报告」（epoch 43/step 2），且**不**发墓碑通知。

### 1.2 零回调 force-stop（套件外两段 probe）

```sh
# phase 1：起真实 FGS，等宿主 kill
adb -s emulator-5556 shell am instrument -w -e pdsh.phase start \
  -e class 'com.phonedsh.dsh.background.ForceStopProbeInstrumentedTest#startTurnThenWaitForForceStop' \
  com.phonedsh.dsh.test/androidx.test.runner.AndroidJUnitRunner &
adb -s emulator-5556 shell am force-stop com.phonedsh.dsh.test
# phase 2：新进程读 marker
adb -s emulator-5556 shell am instrument -w -e pdsh.phase verify \
  -e class 'com.phonedsh.dsh.background.ForceStopProbeInstrumentedTest#nextOpenReadsTheInterruptedTurn' \
  com.phonedsh.dsh.test/androidx.test.runner.AndroidJUnitRunner
```

结果（实测(33)）：phase 1 起服务后 `dumpsys` 能看到
`isForeground=true foregroundId=7301`；`am force-stop` 后 `dumpsys activity services`
变成 `(nothing)`（零回调杀进程）；phase 2 `OK (1 test)`——marker 仍是
epoch 61 / step 3，`reason == null`（**没有编造的停止原因**），WorkManager 墓碑把
它变成「检查点 + 不会自动续跑」的引导，并把 marker 标成已报告。

## 2. 本车道新增的 API 33 专属测试

文件：`android/dsh/src/androidTest/kotlin/com/phonedsh/dsh/background/Api33FallbackInstrumentedTest.kt`
（`assumeTrue(Build.VERSION.SDK_INT == 33)`，其它 API 上显式 skip，不会伪装成绿）。

### 2.1 `deviceSelectorReturnsTheForegroundServiceAndUidtDoesNotExistHere`

断言：

1. `TurnChannel.select(Build.VERSION.SDK_INT, capability) == DATA_SYNC_FOREGROUND_SERVICE`
   ——用的是**设备的真实 SDK_INT**，不是 JVM 测试里传的参数；
2. `TurnChannel.current(capability)` 与公共门面 `TurnBackground.channel(context)` 同样是 FGS；
3. `assertNotEquals(USER_INITIATED_JOB, TurnBackground.channel(context))`；
4. 同函数边界钉死：`select(33) == FGS`、`select(34) == UIDT`；
5. UIDT **不存在**是运行时事实：
   `JobInfo.Builder::class.java.getMethod("setUserInitiated", Boolean::class.javaPrimitiveType)`
   抛 `NoSuchMethodException`（`assertNull`）。这比「代码没走到」强：API 里根本没有这个方法。

### 2.2 `realStartForegroundServiceOpensADataSyncWindowSeenByDumpsys`

走**生产入口** `TurnBackground.start(context, TurnRequest(epoch=81, step=3, totalSteps=6), appVisible=true)`
→ `TurnJobScheduler.schedule` → `TurnForegroundService.start` →
`ContextCompat.startForegroundService`（真实 `startForegroundService`），断言：

1. 返回值 `== TurnStartResult.DataSyncForegroundServiceStarted`（不是 UIDT、不是 ForegroundOnly）；
2. `TurnRuntime.snapshot()` 进入 **`SCHEDULED`** 且 `backend == FOREGROUND_SERVICE`——
   `startForegroundService` 只说明**启动请求被接受**，`onStartCommand` 才是执行开始；
   相位随后由 `onStartCommand` 升级为 `RUNNING`。宿主把 `SCHEDULED | RUNNING` 都当作
   「后台窗口在位」（`TurnWindow.InPlace(backend, phase)`），所以切后台不会在排队期间被 drain；
3. `NotificationManager.activeNotifications` 里有 `PROGRESS_NOTIFICATION_ID`；
4. 安装包的**声明类型** `getServiceInfo(...).foregroundServiceType == FOREGROUND_SERVICE_TYPE_DATA_SYNC`；
5. `dumpsys activity services <pkg>` 的 ServiceRecord 里：
   `isForeground=true`、`foregroundId=7301`、
   `foregroundNoti=Notification(channel=pdsh_turn_progress ...)`、
   通知 `flags` 含 `FLAG_FOREGROUND_SERVICE`（0x40）、`startForegroundCount >= 1`；
6. 运行时 type 位掩码：有则严格断言 `== dataSync`；**API 33 上读不到**，打印
   `PDSH_API33_FGS_TYPE_READBACK_BLOCKED`（理由见 §2.3）。

### 2.3 为什么「type 是 dataSync」在 API 33 上不是一个 dumpsys 读数

实测(33) + 源码：

* API 33 的 `ServiceRecord.dump()`（AOSP `android-13.0.0_r1`，`services/core/java/com/android/server/am/ServiceRecord.java`）
  只打印 `isForeground= / foregroundId= / foregroundNoti=`，**没有** type 字段；
* API 33 的 `ServiceRecordProto`（`core/proto/android/server/activitymanagerservice.proto`）
  的 `Foreground` 只有 `id` 与 `notification`，也没有 type；
* `types=%08X` 是 **android-14 才加**的（同文件 `android-14.0.0_r1`），所以 API 35 的
  dumpsys 才有这个字段（**源码，本车道未在 5554 实测**）；
* 因此本车道用「平台自己的校验」替代读回：API 33 的
  `ActiveServices.setServiceForegroundInnerLocked` 在
  `(foregroundServiceType & manifestType) != foregroundServiceType` 时抛
  `IllegalArgumentException`。安装包只声明 `dataSync`（断言 4），服务请求
  `FOREGROUND_SERVICE_TYPE_DATA_SYNC`（源码），而提权被接受（`isForeground=true`、
  `startForegroundCount=1`）——平台记录的运行时 type 只能是 dataSync。

**这条结论的等级是「声明类型实测 + 平台校验接受」，不是「运行时 bitmask 读回」。**
不把它写成后者，也不编一个读数。

## 3. `dumpsys` 里的 FGS 真实证据

来自 `realStartForegroundService...` 的 `System.out`（`logcat -s System.out`，实测(33)）：

```text
PDSH_API33_FGS_DUMPSYS:
* ServiceRecord{d706e3e u0 com.phonedsh.dsh.test/com.phonedsh.dsh.background.TurnForegroundService}
    intent={cmp=com.phonedsh.dsh.test/com.phonedsh.dsh.background.TurnForegroundService}
    packageName=com.phonedsh.dsh.test
    processName=com.phonedsh.dsh.test
    app=ProcessRecord{e1e2cca 9678:com.phonedsh.dsh.test/u0a180}
    allowStartForeground=PROC_STATE_TOP
    startForegroundCount=1
    infoAllowStartForeground=[callingPackage: com.phonedsh.dsh.test; callingUid: 10180; uidState: TOP ; intent: Intent { cmp=com.phonedsh.dsh.test/com.phonedsh.dsh.background.TurnForegroundService (has extras) }; code:PROC_STATE_TOP; tempAllowListReason:<null>; targetSdkVersion:35; callerTargetSdkVersion:35; startForegroundCount:0; bindFromPackage:null]
    isForeground=true foregroundId=7301 foregroundNoti=Notification(channel=pdsh_turn_progress shortcut=null contentView=null vibrate=null sound=null defaults=0x0 flags=0x4a color=0xff2563eb category=service actions=1 vis=PUBLIC)
    createdFromFg=true
    startRequested=true delayedStop=false stopIfKilled=true callStart=true lastStartId=1
```

关键行：

* `isForeground=true` —— 服务真的在前台状态（不是「startForegroundService 没抛异常」）；
* `foregroundId=7301` —— 正是 `TurnNotifications.PROGRESS_NOTIFICATION_ID`；
* `foregroundNoti=Notification(channel=pdsh_turn_progress ...)` —— 正是回合通知渠道；
* `flags=0x4a`：`0x40` = `FLAG_FOREGROUND_SERVICE`，`0x8` = `FLAG_ONLY_ALERT_ONCE`，
  `0x2` = `FLAG_ONGOING_EVENT`；
* `startForegroundCount=1` —— 平台记录了一次提权；
* 下一行（同一次运行）：

```text
PDSH_API33_FGS_TYPE_READBACK_BLOCKED: API 33 ServiceRecord dump carries no foreground-service type field
```

`dumpsys` 是通过插桩进程里的 `UiAutomation.executeShellCommand` 执行的（shell 身份），
不是宿主侧事后补拍：断言与窗口在同一个瞬间。

## 4. API 35（UIDT 主） vs API 33（FGS 回退）逐条对照

> **API 35 列不是本车道测的**。按任务约束，`emulator-5554` 归别的车道，本车道
> 没有在它上面运行任何命令。标 `F7(35)` 的行引用 F7 车道既有结论，标 `源码` 的
> 行是读 AOSP 得出。真正属于本车道的实测全部在 API 33 列。

| # | 结论 | API 35（UIDT 主） | API 33（FGS 回退） | 证据等级 |
| --- | --- | --- | --- | --- |
| 1 | 真实 `SDK_INT` 的通道选择 | UIDT | `DATA_SYNC_FOREGROUND_SERVICE`，且永不 UIDT | 33 **实测**；35 `F7(35)` |
| 2 | 公共门面 `TurnBackground.channel()` | `USER_INITIATED_JOB`（UIDT 用例 `setUp` 里断言） | 同 1 | 33 **实测**；35 `F7(35)` |
| 3 | UIDT API 是否存在于框架 | 存在，`buildJobInfo()` 真实构造 `setUserInitiated(true)` | `setUserInitiated` 反射 `NoSuchMethodException` | 33 **实测**；34+ 源码 |
| 4 | 生产入口 `TurnBackground.start()` 的结果 | `UserInitiatedJobScheduled(8401)` | `DataSyncForegroundServiceStarted` | 33 **实测**；35 `F7(35)` |
| 5 | 提权后的真实窗口状态 | UIDT job 运行、job 自己的通知 | `isForeground=true`，`foregroundId=7301` | 33 **实测**（`dumpsys`）；35 `F7(35)` |
| 6 | 常驻通知 | job 通知（ongoing + 一个停止 action） | channel `pdsh_turn_progress`、`FLAG_FOREGROUND_SERVICE`、ongoing | 33 **实测**；35 `F7(35)` |
| 7 | **运行时 FGS type 读回** | `dumpsys` 打印 `types=%08X` | **BLOCKED**：text dump 与 proto 都没有 type 字段 | 33 **源码 + 实测**；35 **源码**（未实测） |
| 8 | 声明类型 | manifest `dataSync` | `ServiceInfo.foregroundServiceType == dataSync` | 33 **实测** |
| 9 | dataSync 6h 预算 / `onTimeout` | `onTimeout(int,int)`（API 35）、6h/24h 预算 | **不触发**：无预算，且 `onTimeout` 系列方法 API 34 才存在 | 两边都 **BLOCKED** |
| 10 | 通知链路降级（`POST_NOTIFICATIONS` 拒绝） | 同一用例在 34+ 仍 SKIP，需要 `pm revoke`；未取到 35 的手工记录 | 手工 revoke 后 `OK (1 test)`：FOREGROUND_ONLY、无窗口、排队报告 | 33 **实测**；35 **未验证** |
| 11 | 任务移除（`stopWithTask`） | 未在本车道测 | PASS：marker epoch 44 保留 | 33 **实测**；35 **未验证** |
| 12 | 零回调 force-stop | 未在本车道测 | 两段 probe PASS：epoch 61/step 3、`reason=null`、墓碑引导 | 33 **实测** |
| 13 | 墓碑 WorkManager + BOOT 引导 | 未在本车道测 | 三个用例 PASS | 33 **实测** |
| 14 | 后台起 FGS 被拒 → `START_NOT_ALLOWED` | 未测 | 未测（所有用例都在可见 Activity 下起服务） | 两边 **未验证** |
| 15 | API 26–32 同一分支 | — | 无镜像；只有纯函数 + 分支代码 | **纯函数**（`TurnChannelTest`） |

## 5. 从「纯函数推断」升级成「emulator 实测」的结论

1. **通道选型**：`TurnChannel.select` 在**真实 SDK_INT** 上返回 FGS——此前只有
   JVM 里传 `sdkInt = 33` 的参数化断言。
2. **公共门面**：`TurnBackground.channel(context)` 在 33 上返回 FGS（UI 读的就是它）。
3. **生产决策链**：`TurnBackground.start()` → `TurnJobScheduler.schedule()` 真的落到
   `DataSyncForegroundServiceStarted`。此前 `ForegroundServiceInstrumentedTest` 直接调
   `TurnForegroundService.start`，**绕过了 `TurnJobScheduler` 的分支选择**，所以
   「33 上会选 FGS 并真的启动」这条此前没有被设备证据覆盖。
4. **UIDT 不存在**：从「文档说 34+ 才有」升级为「本镜像框架类里没有
   `setUserInitiated`」的运行时事实。
5. **FGS 提权**：从「没抛异常」升级为 `dumpsys` 的 `isForeground=true` +
   `foregroundId=7301` + `FLAG_FOREGROUND_SERVICE` + `startForegroundCount=1`。
6. **通知链路降级**：从「用例设计上会降级」升级为 revoke 之后的真实 `OK (1 test)`。
7. **零回调 force-stop 与下次打开报告**：从手工探针的「设计如此」升级为 API 33 上
   两段 probe 全绿（marker 不被编造原因、墓碑只引导不续跑）。
8. **任务移除 / 墓碑 / BOOT 引导**：API 33 上三个用例全绿（此前只在 35 侧有记录）。

## 6. 仍然做不到的（BLOCKED，逐条写缺什么）

| # | 做不到的结论 | 缺什么 |
| --- | --- | --- |
| 1 | API 33 上**读回**运行时 FGS type 位掩码 | Android 13 没有公开 API，`ServiceRecord.dump()` 与 `ServiceRecordProto` 都没有该字段（`types=%08X` 是 android-14 才有）。需要 API 34+ 镜像、或系统权限下的 `ServiceRecord` 反射/`dumpsys` 扩展。本车道只用「声明类型 + 平台子集校验接受」间接证明 |
| 2 | `dataSync` 6h 预算到点后的 `onTimeout` → 只关 admission | 需要 Android 15（API 35）+ 连续 6 小时前台服务；API 33 没有该预算，`Service.onTimeout(int)` 也是 API 34 才加入。**这条路径至今没有在任何一个镜像上被执行过** |
| 3 | API 26–32 的回退行为 | 宿主只有 33 与 35 两台镜像。26–32 与 33 走同一分支（`else -> FGS`），但只有纯函数证据 |
| 4 | Android 12+ 后台起 FGS 被拒 → `ForegroundOnly(START_NOT_ALLOWED)` | 需要应用真正处于后台时调用 `startForegroundService`；插桩套件始终有可见 Activity（否则 UIDT/FGS 都不合法）。需要 `HOME` 之后从广播/服务侧发起的探针 |
| 5 | API 35 上「UIDT 排程失败 → 回退 FGS」 | 需要在 5554 上制造 `JobScheduler.schedule` 返回失败（配额/权限/不可见）。本车道不占用 5554 |
| 6 | 墓碑通知的实际送达延迟（WorkManager 15 分钟下限、OEM 推迟） | 需要长时间待机观测；本轮只验证「enqueue → 执行 → 通知」的功能链路 |
| 7 | OEM 查杀（华为/小米/OPPO/vivo 等）对 FGS 的影响 | 需要对应真机；方案 §7.5 明确只做引导、不做 per-OEM 代码分叉 |

## 7. 观察与 open questions（不修代码，`src/main` 属 J1 车道）

1. **`schedule()` 的返回值是乐观的**：`TurnJobScheduler.startForegroundService` 只要
   `startForegroundService` 没抛异常就返回 `DataSyncForegroundServiceStarted`；之后
   服务里的 `startForeground` 若被拒（服务内已经 catch 并 `stopSelf`），调用方拿到的
   仍是「已启动」。API 33 上实测提权成功，所以不是本轮 bug；但「返回值 == 窗口真的
   开了」这个语义需要调用方再用 `TurnRuntime.snapshot()` 复核。是否要把结果改成
   suspend/await 提权，是一条待定的 API 设计问题。
2. **API 33 的 `dumpsys` 缺 type 字段**，而「type 是 dataSync」是白名单
   `platform.fgs-turn-notification` / `platform.bgtask-drain-window` 的关键词。如果后续
   需要**直接**证据，最小成本是给 CI 固定一台 API 34+ 镜像做 `types=%08X` 断言；
   API 33 永远给不了。
3. **`UserInitiatedJobInstrumentedTest` 的 PASS 具有误导性**：34 以下它提前 `return`，
   JUnit 记 PASS。若要保持「无证据即不通过」的纪律，建议改成
   `Assume.assumeTrue(...)`（本车道没有改它：那是既有判据文件，改动会影响 35 侧车道的
   计数与历史记录；先报告，由 F7 决定）。
4. `android/README.md` 的「构建状态」表仍写着 `:app:connectedDebugAndroidTest`
   BLOCKED（无模拟器宿主），与现状不符；该文件不在本车道可写范围内，未改。
5. 本车道**没有修改** `android/dsh/src/main/**`（J1 正在改 `host/` 与 `exec/`），也没有
   发现 `src/main` 中后台相关代码的 bug；上面第 1 条是设计观察，不是已证实的缺陷。

## 8. 一句话总结

API 33 上，「回退通道被选中 → 真实 `startForegroundService` → 平台确认
`isForeground=true` + 回合通知（`FLAG_FOREGROUND_SERVICE`）→ 停止/任务移除/
零回调 force-stop → 下次打开报告」这一整条链已经是**emulator 实测**；
「运行时的 FGS type 位掩码」与「6 小时预算到点」仍然不是，前者受 Android 13 的
可观测面限制，后者受镜像/时长限制——两者都按 BLOCKED 记录，不写成通过。
