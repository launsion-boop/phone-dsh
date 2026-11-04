<!-- SPDX-License-Identifier: MIT -->
# 承诺分级表（Android · 2026-11-01 现状）

日期：2026-11-01 · 车道：L41 · 状态：**现行**（P4 接线落地前有效）

计划 `TonoWiki/briefs/2026-10-31-pdsh-android-port-plan.md` §7.9 要求「后台能力按场景 × 承诺 × 呈现 ×
状态机映射 × 证据等级分级」，并定了一条硬纪律：**每条承诺必须有对应证据等级，无证据即不承诺**。

这份文档执行那条纪律。它写的是**我们现在真正能承诺什么**，不是计划想承诺什么。
每一条都指到证据（测试名 / 回执 / 代码行）；指不到的，进 §3「不承诺」或 §5「已知缺陷」，不写成承诺。

> **一句话**：今天真正成立的用户承诺只有 **5 条**（P1–P5），全部只到 `emulator`；
> 后台「继续跑回合」这件事**不存在**，后台发生的是**收尾**。

## 0. 统计

| 类别 | 条数 | 最高证据等级 |
| --- | ---: | --- |
| 可以承诺（P1–P5） | 5 | `emulator` |
| 只在**测试 APK** 上成立、产品路径用不到（T1–T3） | 3 | `emulator`（自插桩 APK） |
| 明确**不承诺**（N1–N9） | 9 | — |
| `device` 级证据 | **0** | — |

## 1. 两个维度，不要混

**承诺强度**（产品对用户说什么）：

| 强度 | 含义 |
| --- | --- |
| **承诺** | 有证据，可以写进产品文案；不成立是我们的缺陷 |
| **尽力而为** | 有机制但没有证据，文案只能用「通常/一般情况下」，**不得**用肯定句 |
| **不承诺** | 没有证据或明确排除；文案里出现就是撒谎 |

**证据等级**（沿用 `docs/receipts/android-port-2026-10-31.md:7-14` 的既有分级）：

| 等级 | 含义 |
| --- | --- |
| `jvm` | 纯 JVM 测试，无设备 |
| `emulator` | 模拟器（API 35 = `emulator-5554` 系；API 33 = `emulator-5556` 系） |
| `device` | 真机 —— **本轮 0 条** |
| `not-verified` | 无证据，且不得声称 |

**「`emulator` 能不能写进产品文案」**：本仓库的口径是**能**，但必须带限定——`emulator` 证明「代码路径成立」，
不证明「用户设备上成立」。面向用户的文案（商店页 / 引导页）**只允许引用 `device`**；
`emulator` 只允许出现在给开发者的说明里（本文件、回执、PR）。这条比计划 §7.9 更严，理由是：
计划写 §7.9 时默认 P4 会产出真机回执，而 P4 还没接线。

## 2. 可以承诺的（P1–P5）

### P1 — 前台的一个回合会跑到 `completed`

- **承诺**：App 在前台时，发出的一轮对话会走完 `turn_started → tool_call → tool_result → turn_ended`，
  结束原因是 `completed`。
- **成立条件**：模型端点可达；工具在宿主 caps 内（不在则如实返回 `PENDING_HOST`/拒绝，不算违约）；进程不被杀。
- **证据**：
  - 脚本上游：`bash android/tools/run-app-turn.sh` **12/12 断言**，`emulator-5554`（`docs/receipts/android-port-2026-10-31.md` §4.1，第 75 行）
  - **真实模型**：`docs/receipts/android-port-2026-10-31.md` §47（第 2070 行）末尾
    `APP_TURN_OK … reason=completed tool_edges=true`（AVD 5564，真实 `api.deepseek.com` 上游）
- **等级**：`emulator`
- **不能承诺的**：真机；长回合（>30 s 前台未单独验证，见 N8）；release 构建（见 N9）。

### P2 — 退到后台会**收尾**，不丢已写内容

- **承诺**：App 退到后台时，宿主会关闭 admission、把当前纪元落盘
  （`CLOSE_EPOCH` + `FSYNC_MATERIALIZED`：文件 fsync → 目录 fsync → manifest 原子替换）、停掉 Worker，
  然后进入 `Parked`。**在后台不再继续执行这个回合。**
- **成立条件**：进程在收尾期间还活着。收尾在设备上是 **52 ms**，所以窗口很小。
- **证据**（`docs/receipts/android-port-2026-10-31.md` §47，第 2070–2100 行，AVD 5564 / API 35）：
  ```
  D14 Running -> Draining via scenePhase(background)
  closing the epoch now (deadline in 19994 ms; no background window…)
  epoch closed, durable_upto=6
  stops the worker
  D14 Draining -> Parked via drainCompleted   (admission=closed)
  ```
  代码：`android/dsh/src/main/kotlin/com/phonedsh/dsh/host/DrainLane.kt:24-31`（D18 顺序 + 「20 s 是上界不是等待」）
- **等级**：`emulator`
- **机制说明**：`spec/v1/budgets.md:16,42-43` 定义 `Draining`（20 s 死线、到期 abort in-flight、epoch 关闭照跑）；
  实现在 `ControllerBudgets.kt:151`（`DRAIN_DEADLINE_MILLIS = 20_000`）与 `DrainLane`
- **不能承诺的**：后台**继续**跑（见 N1）。

### P3 — 回前台会自动恢复，并能继续发新回合

- **承诺**：从后台回到前台时，宿主走 `Parked → Recovering → Running`，Worker 重新起来，用户可以再发一轮。
- **证据**：同一段设备日志（`docs/receipts/android-port-2026-10-31.md` §47）：
  后台等 **10 分钟** → `Parked -> Recovering via scenePhase(active)` → `Recovering -> Running via leaseCheckResult(verified=true)`
  → `APP_WORKER_READY` → `APP_TURN_OK`
- **等级**：`emulator`
- **不能承诺的**：被杀的进程（那时走 P4 的路径，且**不会**自动续跑，见 P6/T1）。

### P4 — 进程被杀，已写内容不丢（level 1）

- **承诺**：进程被系统或用户杀掉之后，**已经写进 WAL / journal / session 的内容一条不少**；重启后能恢复出来。
- **证据**：`docs/receipts/android-p6-kill-matrix-2026-11-01.md` §1 表 A1–A5（AVD 5566 / API 35）：

  | 杀法 | 结果 |
  | --- | --- |
  | `am force-stop`（回合中 / 空闲） | 杀前/杀后/恢复后 WAL 记录数、journal 记录数、session 行数**逐项相等**，`torn=[]` |
  | `kill -9`（回合中 / 空闲） | 同上 |
  | `am kill`（后台） | 同上 |

  逐格结论见同文件 §1.1：「进程被杀零丢失、零半截」。
- **等级**：`emulator`
- **边界**：这是 **level 1**。授权文案只有「进程被杀不丢」，见 §4 与
  `android-durability-decision-2026-11-01.md:9-11`。

### P5 — 不完整的尾部**能被检出并如实记录**

- **承诺**：崩溃/掉电留下的半截记录不会静默吞掉；启动时会按 `wal.md` §10 截断并**记录**
  （boot id / 段 / 偏移 / 丢弃字节），UI 出现横幅。
- **证据**（同回执 §1 表 A8 + A7）：
  - 注入 16 字节伪记录 → `WAL_TORN_TAIL_TRUNCATED boot=… segment=00000025 keep_len=14266 dropped_bytes=16 previous_len=14282`，截断后 `wal/1: on`
  - `adb emu kill` 之后被杀回合的 `session.v4.jsonl` 最后一行是 **NUL 填充的半截行**（真实撕裂，非注入）
- **等级**：`emulator`
- **一个诚实的缺口**：`:app` 构造 `WorkspaceLog` 时没传 sink，默认 `WalLogSink.NONE`，
  所以 `wal.md` §10 第 2 步要求的「记录 boot id/段/偏移」在产品路径上**只到 logcat，不到 durable 记录**
  （`docs/receipts/android-p6-kill-matrix-2026-11-01.md` 第 72 行的行内注）。
  **承诺「能被检出」成立；「被持久记录下来」在产品路径上不成立。**

## 3. 只在**测试 APK** 上成立、产品路径用不到的（T1–T3）

这三条是真实测出来的，但它们验的是 `:dsh` 的自插桩 APK（`com.phonedsh.dsh.test`），
而**产品 APK 从不启动这些组件**（见 N1 的证据）。写在这里，是为了不让下一个人把它们当成用户承诺。

### T1 — 前台服务通道：能开窗口、能停、能墓碑

- **证据**：`android/dsh/README.md`（K4 附录）§1 表，API 33（`emulator-5556`）：
  - `realStartForegroundServiceOpensADataSyncWindowSeenByDumpsys` PASS：`dumpsys` 见
    `isForeground=true foregroundId=7301 foregroundNoti=Notification(channel=pdsh_turn_progress …) flags=0x4a`
  - `stopActionOnNotificationClosesAdmissionAndRemovesNotification` PASS
  - `removingTheTaskStopsTheServiceAndLeavesTheMarker` PASS（`stopWithTask="true"`）
  - `TombstoneInstrumentedTest#tombstoneWorkIsEnqueuedVisibleAndOnlyNotifies` PASS
- **等级**：`emulator`（测试 APK）
- **限定**：K4 自己写着「上一轮记录，本轮未重跑」（该文件 §1 开头）。引用时必须带这句。

### T2 — 通知不可见 → 降级为「仅前台」

- **证据**：同附录 §1.1，手工 `pm revoke POST_NOTIFICATIONS` 后 `OK (1 test)`：
  `capability.progressVisible == false`、`TurnBackground.channel(...) == FOREGROUND_ONLY`、
  `TurnBackground.start(...) == ForegroundOnly(NOTIFICATIONS_UNAVAILABLE)`、无 FGS 窗口、无通知
- **等级**：`emulator`（测试 APK）
- **产品侧对应**：`:app` 的 `HostBackground.kt:113-130`（`backgroundWindowFact`）读的是同一组判定，
  页面上的「前台服务可用性」行因此与 `:dsh` 不会漂移。但**读数在，通道不会开**（N1）。

### T3 — UIDT（Android 14+）的真实排程

- **证据**：`UserInitiatedJobInstrumentedTest`（API 35，`emulator-5554`）；API 33 上 UIDT 方法**不存在**
  已被运行时证明（`JobInfo.Builder::class.java.getMethod("setUserInitiated")` 抛 `NoSuchMethodException`）
- **注意**：API 33 上该用例提前 `return` 却记 PASS，K4 已把它记作 BLOCKED 而不是通过
- **等级**：`emulator`（`F7(35)` 车道结论，K4 未复跑）

## 4. 明确不承诺的（N1–N9）

| # | 不承诺的内容 | 为什么 | 证据 |
| --- | --- | --- | --- |
| **N1** | **后台继续跑回合**（「你锁屏，任务继续」） | 产品路径**从不启动**任何后台窗口：没有生产代码调用 `TurnBackground.start(...)`；D14 的 `START_BACKGROUND_TASK` 被如实报成「没有后台窗口」；退到后台直接进 `Draining` | `grep -rn "TurnBackground\.start" android/*/src/main` → 空；`DrainLane.kt:39-48`；`PhoneDshHost.kt:668-670` |
| **N2** | 「进了后台这一轮也能跑完」 | 后台一进就关 admission：`arm the 20 s drain deadline` → `VFS mutation deferred: admission closed (D14)`；实测后台 **30.4 s** 后 Worker 的 durability ack 超时 → `APP_TURN_FAILED reason=incomplete` | `docs/receipts/android-port-2026-10-31.md`（§40 之后的「后台 10 分钟」实验，约 1500 行） |
| **N3** | 「掉电最多丢最后一个纪元」（level-2） | 本轮没有真机台架，`AndroidDurability.level()` 保持 `LEVEL_2_POWER_LOSS_UNVERIFIED`、`supportsLevel2Claim()` 为 false | `android-durability-decision-2026-11-01.md:9-17`；`AndroidDurability.kt:110-126` |
| **N4** | OEM 查杀下后台能活（华为/小米/OPPO/vivo/三星） | 一台真机都没有；计划 §7.5 只做「引导放行」，不做 per-OEM 分叉 | 矩阵 B 轴全 `not-verified`（`android-device-matrix-2026-11-01.md` §2.3-B） |
| **N5** | 低电 / 热压力下按策略降级（计划 §7.9 第 5 行，「探针」证据） | 映射表与降级代码在，但**没有任何探针实测**；`ThermalPressure`/`Battery` 读数只验证了「读得到」 | 计划 §7.10「thermal/battery 保守化落成显式映射表」仍是待办 |
| **N6** | 16 KB 页设备上能加载 | 只有静态合规（`p_align=16384` + `zipalign -P 16` 通过），**没有一台 16 KB 设备上装过** | 矩阵 E 轴；`android-device-matrix-2026-11-01.md` §3.2 |
| **N7** | 平板 / 折叠 / 横屏 / 多窗口 | 没有任何这类形态的证据 | 矩阵 C 轴全 `not-verified` |
| **N8** | 长回合（>30 s）的前台完成 | 唯一一个「45 s 观察窗」的回合本身只有 ~4 秒，回执自己写明「超长回合未被直接验证」 | `docs/receipts/android-port-2026-10-31.md` §4.1 的「诚实的范围说明」 |
| **N9** | release 包能跑真实回合 | 模型 key 唯一的写入路径是 `importDevelopmentKey`（`ApiKeyStore.kt:275`），且被 `FLAG_DEBUGGABLE` 门控；**全仓没有 key 输入 UI** | `android/app/src/main/kotlin/com/phonedsh/probe/MainActivity.kt`（`debuggable` 判断） |

**N9 是最容易被忽略的一条**：它意味着今天能跑真实回合的版本只有 **debug 构建 + 手工投放 `import-key.txt`**。
任何「下载即用」的承诺都不成立。

## 5. 已知缺陷（不是承诺问题，但用户会遇到）

| # | 缺陷 | 用户看到什么 | 状态 |
| --- | --- | --- | --- |
| **BUG-1**（**本行经两次更正，以下为终版**） | 「**已列入 manifest** 但文件是 0 字节」的段 → listed-missing 规则 → 高于水位 → `WAL_CORRUPT` → 工作区不可用。**根因是 `WorkspaceLog.kt:1287` 的 `createSegment` 写完 40 字节 header 后从不 fsync**（`FileChannel.open(...).use { }` 直接关，没有 `force()`），header 要等纪元关闭才落盘——**窗口 30–60 秒**。掉电落在这个窗口里，「清单说有这个段」与「文件是空的」就同时成立。 | 掉电 → 工作区不可用 | **未修**。★ 更正过程：我一度据 `ZeroLengthSegmentTest` 判定它「已修」——**错了**，那 5 条测的是**未列入**的 0 字节段（`twoZeroLengthSegmentsAreDroppedAndThePrefixRecovers`），而 `aListedZeroLengthSegmentAboveTheWatermarkStillFailsLoud` 明确钉住**已列入**的要 fail loud。两件不同的事。★ L42 用模拟器 `adb emu kill` **稳定复现**（「先建空文件 + fsync 目录发布 inode，再写负载不 fsync → size=0」）。 |
| BUG-1 的修法（不是「容忍」而是「别造出这个窗口」） | ① **`createSegment` 写完 header 立即 `force(true)`**——成本每纪元 1 次 fsync（实测 fsync(file) 会提交同一事务里的新 dirent，目录 fsync 可省）；② 恢复层容忍「未列入 + `<40 B`」的段（**需 spec 决定**，`wal.md:248-249` 与回执 §46 的裁定冲突） | —— | ① **已修**（2026-11-01：`createSegment` 写完 40 字节 header 后 `force(true)`，注释写明「header 在段被登记之前落盘」，`cd android && ./gradlew :core:test` BUILD SUCCESSFUL）② **待 spec** |
| BUG-1b | `1 ≤ len < 40` 的撕裂 header 段：`WorkspaceLog.kt:780` 只 `isEmpty()` 特判 | 同类砖化 | **未修**，需 spec 决定 |
| BUG-2 | `WAL_CORRUPT` 后屏幕仍显示「运行中」 | 用户不知道工作区已死 | **已修**：`ProbeRecovery.raiseWalUnavailable` + `RecoveryBanner` |
| 墓碑通知不投递 | 产品路径上 `TombstoneScheduler.enqueue` **只被 androidTest 调用**；main 里只有 `cancel` | 不会收到「第 N 步被中断」的通知；只有冷启动横幅 | 未接线（属 P4，不是缺陷单） |

**BUG-1 与 BUG-1b 都必须写进任何对外文案的免责范围**：**「进程被杀不丢」在两种掉电形态下不成立**——
① `createSegment` 的 header 未落盘时掉电（**已修**：`WorkspaceLog.kt` 现在写完 header 立即 `force(true)`）；
② 撕裂 40 字节 header 留下 **1–39 字节**段（**未修**，需 spec 决定）。
两种都不是「丢尾部」，而是**整个工作区报废**。 这正是 `android-durability-decision-2026-11-01.md` §4.3 的结论。

## 6. 对计划 §7.9 六行的逐行裁决

计划 §7.9 的表把「场景 × 承诺 × 呈现 × 状态机映射 × 证据等级」写好了，但它是**目标态**。
逐行裁决如下（「裁决」列才是今天能说的）：

| 计划行 | 计划写的承诺 | 计划证据等级 | 今天的裁决 |
| --- | --- | --- | --- |
| 前台 / 充电 | 回合必完成 | 真机 gate | **降级为 P1**（`emulator`，真机 gate 未达） |
| 锁屏（UIDT/FGS 在位） | 尽量完成；系统中断则诚实恢复 | 真机 gate | **不成立**（N1）：通道从未启动，进后台只收尾 |
| 进程被杀 | WAL 到哪算哪；重启后可恢复 | kill 矩阵 | **WAL 部分成立**（P4，`emulator`）；**「墓碑通知」在产品路径不成立**（T1 只在测试 APK） |
| Task Manager Stop / OEM force-stop | 零回调；下次打开报告最后检查点 | 真机 gate | **force-stop 零回调成立**（P6 A1–A5）；**「下次打开报告」成立**（`TURN_INTERRUPTED_PREVIOUS … reason=NO_CALLBACK` + 横幅）；**OEM 部分不成立**（N4） |
| 低电 / 热压力 | 按策略降级 | 探针 | **不成立**（N5，没有探针） |
| 重启后 | 不自动续跑；引导打开 app | 真机 gate | **代码与测试有，产品路径未验证**：`BootReceiver` 只发引导（`bootReceiverPostsGuidanceAndStartsNothing` PASS，测试 APK）；产品路径的「重启后」从未在真机/模拟器上走过 |

**顺带一条与计划不符的**：计划 §7.9 那张表的「呈现」列写「常驻通知 / 墓碑通知 / BOOT 通知」。
产品路径上**这三种通知一条都不会出现**——`:dsh` 的 `Notifier` 在 probe 里是 DISABLED
（`DrainLane.kt:39-41`「its `Notifier` is DISABLED, so there is no OS background window to open」）。
用户能看到的只有屏幕内横幅。

## 7. 授权文案（可以直接用 / 绝对不能用）

**允许**（每条都能指到本文件的一行）：

- 「前台执行时，一轮任务会完整跑完」→ P1
- 「退到后台会自动收尾并落盘，不会在后台继续跑」→ P2 + N1
- 「回到前台会自动接着用」→ P3
- 「进程被系统结束，已经写下的内容不会丢」→ P4
- 「不完整的结尾会被发现并记录」→ P5（**不要**说「会被修复」）
- 「掉电时会丢什么，我们不作承诺」→ N3

**禁止**：

- 「后台继续执行 / 锁屏也能跑」→ N1
- 「掉电最多丢最后一个纪元」→ N3
- 「不会被系统杀死 / 杀不死」→ N4
- 「低电自动降级」→ N5
- 「支持 16 KB 设备」→ N6
- 「支持平板」→ N7
- 「下载即用」→ N9

## 8. 这份文档什么时候该重写

1. **P4 把后台通道接线落地**（`TurnBackground.start` 出现生产调用者，或 `START_BACKGROUND_TASK` 真的开窗口）
   → N1/N2 作废，P2 的措辞要从「收尾」改成「继续 + 收尾」，§6 的计划行要重排。
2. **第一台真机回执** → 所有 `emulator` 行升级为 `device`，§1 的「商店文案只能引 `device`」才能解锁。
3. **BUG-1b 修复**（`1 ≤ len < 40` 可丢弃，需先改 `wal.md §7.2`）→ §5 的免责范围收窄。
4. **加 key 输入 UI / 演示模式** → N9 作废，P1 的「成立条件」放宽。
5. **`minSdk` / `targetSdk` 变更** → 与 `android-device-matrix-2026-11-01.md` §1.8 一起改（通道集合会变）。
6. **第一次在 16 KB 设备上装成功** → N6 作废。
7. **计划 §7.9 被改**（例如 P4 决定不做后台）→ §6 的对照表整段重写。

## 9. 未知 / 缺什么证据

| 未知 | 缺什么 |
| --- | --- |
| 真实设备上「退到后台」的时序 | 真机 + `dumpsys` 配对日志；模拟器上 drain 是 52 ms，真机上 closeEpoch 可能慢一个量级 |
| 后台被 LMK 杀 vs 不被杀的分布 | 低内存真机上的长时观测（本轮 2 GB AVD 都没杀，说明模拟器不能代表真机） |
| `Draining` 死线真正触发时的行为 | 要制造「epoch close 超过 20 s」：需要大 VFS（数百 MiB）+ 慢存储。**至今没有任何镜像上执行过 `FORCE_DRAIN_DEADLINE` 的真实路径**（JVM 有夹具 `drain-deadline-20s`） |
| 后台回合的替代方案（WorkManager 补做） | 计划 §7.10 已判「大概率不可行，改下次前台补做」；这条**没有实测**，也没有实现 |
| 低电/热的实际阈值行为 | 探针（真实的 `ThermalService` 读数 + 人为加热） |

## 10. 证据索引

```bash
# P1 前台回合
bash android/tools/run-app-turn.sh                    # 12 条断言；见回执 §4.1（第 75 行）
sed -n '2070,2110p' docs/receipts/android-port-2026-10-31.md   # §47 drain + 后台 10 分钟 + APP_TURN_OK

# P4 / P5 进程被杀与尾部
sed -n '1,60p' docs/receipts/android-p6-kill-matrix-2026-11-01.md

# N1 后台通道从未被产品路径启动
grep -rn "TurnBackground\.start" android/*/src/main   # 空
grep -rn "TurnBackground" android/*/src               # 只有 :dsh 内部 + androidTest
sed -n '39,48p' android/dsh/src/main/kotlin/com/phonedsh/dsh/host/DrainLane.kt

# N3 持久化承诺
grep -n "LEVEL_2_POWER_LOSS_UNVERIFIED\|supportsLevel2Claim" \
  android/platform-android/src/main/kotlin/com/phonedsh/platform/android/AndroidDurability.kt

# T1–T3 测试 APK 上的通道证据
sed -n '1,60p' android/dsh/README.md

# 契约（承诺的语义来源）
grep -n "20 s deadline" spec/v1/budgets.md
sed -n '145,155p' android/controller/src/main/kotlin/com/phonedsh/controller/ControllerBudgets.kt
```
