<!-- SPDX-License-Identifier: MIT -->
# 决策记录：机型矩阵 + minSdk 26 + 分发渠道

日期：2026-11-01 · 车道：L41 · 状态：**已决定（可复核）**

这份文档补的是计划 `TonoWiki/briefs/2026-10-31-pdsh-android-port-plan.md` P0 里的那个「阻塞项」：
**机型矩阵 + minSdk + 分发渠道决策**。它此前**只存在于代码里**（`minSdk = 26` 写死在 10 个模块），
没有任何文字理由。本文把理由、矩阵定位和渠道建议一次写清，并把「不确定」标成不确定。

- 影响范围：`android/*/build.gradle.kts` 的 `minSdk` / `targetSdk`、P2a 的 16 KB 门禁、P4 的 OEM 策略、发布流程
- 不在本文范围：真机采购、Play Console 后台操作、`spec/**` 与 `android/**` 的任何代码改动

## 0. 一页结论

| 问题 | 结论 | 证据强度 |
| --- | --- | --- |
| minSdk 为什么是 26 | **被 API 26 才有的三类符号强制**：`java.nio.file`（101 处）、`java.time`（8 处）、`NotificationChannel`；且全仓**没有** core library desugaring | 代码 + 构建配置 |
| 26 是「历史遗留」吗 | **不是随手写的，但也没有文字理由**——它随唯一一次 Android 移植 commit `0e6d5977` 一次性落进 10 个模块 | `git log -S` |
| 能不能降到 24/25 | 技术上能，代价是重写 WAL 的 I/O 层（本仓库最贵的代码）+ 引入 desugaring + 版本门控通知渠道。**不建议** | 静态分析 |
| 有没有更强的下限（依赖库） | **没有**：`assembleRelease` 能过，说明没有 AAR 的 minSdk > 26（AGP 会直接 merge 失败） | 构建结果 |
| 机型矩阵是什么 | **测试目标定义**，不是实测结果。今天只有 API 33 / 35 两台 AVD 有 `emulator` 级证据 | `emulator` |
| 分发渠道 | **首发侧载；架构按 Play 合规设计；上架推迟到「后台通道接线 + 发布身份 + 签名」之后** | 决策（本文 §3） |
| 16 KB 页对齐 | **已满足**：`PT_LOAD` 三段全 `p_align=16384`，`zipalign -c -P 16` 通过 | 本机实测（§3.2） |

## 1. minSdk 为什么是 26（Android 8.0）

### 1.1 它现在写在哪

| 文件 | 行 | 值 |
| --- | --- | --- |
| `android/app/build.gradle.kts` | 201 | `minSdk = 26` |
| `android/lib/build.gradle.kts` | 30 | `minSdk = 26` |
| `android/dsh/build.gradle.kts` | 24 | `minSdk = 26` |
| `android/engine/build.gradle.kts` | 44 | `minSdk = 26` |
| `android/platform-android/build.gradle.kts` | 21 | `minSdk = 26` |
| `android/domain/build.gradle.kts` | 25 | `minSdk = 26` |
| `android/controller/build.gradle.kts` | 13 | `minSdk = 26` |
| `android/shell/build.gradle.kts` | 14 | `minSdk = 26` |
| `android/testkit/build.gradle.kts` | 15 | `minSdk = 26` |
| `android/core/build.gradle.kts` | — | 纯 JVM 模块（`java-library`），没有 `minSdk` 字段 |

合并后的清单也是 26，这是最终会被安装包携带的值：

```
android/app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml:9
    android:minSdkVersion="26"
    android:targetSdkVersion="35"
```

### 1.2 真实原因：三类 API 26 符号，且没有 desugaring

**先说否证**：代码里**没有任何一处**显式判断 26。

```bash
$ grep -rn "Build.VERSION_CODES.O\b" android/*/src/main | wc -l
0
$ grep -rn "@RequiresApi(26)" android/*/src/main | wc -l
0
```

`@RequiresApi` 在 `src/main` 里只出现在**更高**的级别上（34 / 35），是给「新 API 用前先判断」的场景：
`TurnJobScheduler.kt:132`、`TurnBackground.kt:139`、`TurnJobService.kt:62,72`（34）、`TurnForegroundService.kt:95`（35）。

所以 26 不是「某处写了 `if SDK_INT >= 26`」推出来的，而是**用到的符号本身的类库级别**推出来的：

| # | 符号 | 首见于 | 用在哪（示例） | 在 API 25 上的后果 |
| --- | --- | --- | --- | --- |
| 1 | `java.nio.file.{Path,Files,StandardOpenOption}` | API 26 | `android/core/.../log/WalPaths.kt:7-8`、`MaterializedInvariant.kt:9-12,235`、`WalSegmentReader.kt:12-13,226`、`WorkspaceLog.kt:19` | `NoClassDefFoundError: java.nio.file.Path`——**WAL 整个不可用**，不是降级 |
| 2 | `java.time.{Instant,ZoneId,OffsetDateTime}` | API 26 | `:lib` `SessionsPage.kt:115-116`、`NativeAutomationPage.kt:133-134`、`PdshNavHost.kt:191`；`:app` `HostNavFacts.kt:72`、`HostSessionsScreen.kt:33` | 打开会话页 / 自动化页即崩 |
| 3 | `NotificationChannel` + `NotificationManager.createNotificationChannel` + `getNotificationChannel` | API 26 | `android/dsh/.../TurnNotifications.kt:20,46-57`（**未加版本门控**）、`NotificationCapability.kt:86` | 后台通知面整体不可用；`TurnNotifications` 在类加载阶段就失败 |

用量分布（`android/*/src/main`，import 与全限定名都算）：

```bash
$ grep -rn "java.nio.file" android/*/src/main --include="*.kt" | wc -l
101
$ grep -rn "java.time" android/*/src/main --include="*.kt" | wc -l
8
# 模块分布（合计 101）：core 32 / engine 16 / lib 15 / testkit 12 / dsh 10 /
#                        platform-android 6 / platform 4 / net 4 / app 2
```

**关键前提：没有 desugaring。** 仓库里 `coreLibraryDesugaring` / `isCoreLibraryDesugaringEnabled` / `desugar_jdk_libs`
的出现次数是 0：

```bash
$ grep -rn "desugar\|coreLibraryDesugaring" android/ --include="*.kts" --include="*.toml" --include="*.properties" | grep -v "/build/"
（无输出）
```

没有 desugaring，`java.nio.file` 与 `java.time` 就是**硬下限**：API 26 以下不是「行为不同」，而是 `NoClassDefFoundError`。
**这就是 minSdk = 26 的真实原因。** 三者里最难拆的是 `java.nio.file`：它长在 WAL 的写路径上
（`FileChannel.open` / `StandardOpenOption` / 段文件与 manifest 的原子替换），而 WAL 是本仓库投入最大、
错误代价最高的模块（`spec/v1/wal.md` §5.2、D18 三步 fsync）。

### 1.3 再补一条设计侧的理由（不是硬约束，但写着更清楚）

后台设计本身把 26 当作「回退通道的起点」：

`android/dsh/src/main/kotlin/com/phonedsh/dsh/background/TurnChannel.kt:7-8`

> `- Android 8.0–13 (API 26–33): UIDT does not exist; dataSync FGS is the only official channel.
> The fallback is not a degraded mode on those releases.`

也就是说「Android 8.0 起才有官方的后台长任务回退通道（dataSync FGS 的现代形态 + 通知渠道）」是设计假设。
**这条是设计假设，不是编译期约束**——它与 §1.2 的三条硬约束指向同一个数字，所以 26 是自洽的，不是巧合。

### 1.4 不是原因的东西（排除掉，免得下一个人再查一遍）

| 候选 | 结论 | 依据 |
| --- | --- | --- |
| 某个依赖库要求 26 | **不是**。若有 AAR 的 `minSdk > 26`，AGP 会 merge 失败；`:app:assembleRelease` 已经能产出 APK | `android/app/build/outputs/apk/release/app-release-unsigned.apk` 存在 |
| Play 要求 26 | **不是**。Play 的强制项是 `targetSdk`（按年上移），对 `minSdk` 没有门槛 | §3.3 |
| 16 KB 页对齐要求 26 | **不是**。16 KB 与 `targetSdk ≥ 35` 挂钩，与 `minSdk` 无关 | §3.2 |
| Compose / AGP 要求 26 | **不是**。AGP 8.7.3 + compose-bom 2025.01.00 的 minSdk 下限远低于 26 | `android/gradle/libs.versions.toml:8-12` |
| 某条产品决策记录 | **没有**。`docs/design/` 下在此文之前没有任何 minSdk 记录 | 本文存在的理由 |

### 1.5 历史：一次 commit，没有讨论痕迹

```bash
$ git log --oneline -S "minSdk = 26" -- android/
0e6d5977 feat(android): 完整适配 PDSH —— 12 个模块、1475 个 JVM 测试、30 个设备级缺陷闭合
$ git log --oneline --reverse -- android/settings.gradle.kts
0e6d5977 feat(android): 完整适配 PDSH —— …（同一 commit）
```

整个 Android 树只有一个 commit，`minSdk = 26` 是随它一起进来的。**没有单独的决策 commit、没有 PR 讨论、
没有注释**——所以本文的 §1.2 是**从代码反推**的结论，不是复述一份曾经存在的理由。这一点必须写明：
它是「事后重建的因果」，不是「当时的记录」。反推的可信度来自三条符号的机械可查性（grep 即可复现）。

### 1.6 降到 24 / 25 要放弃什么

| 要动的地方 | 具体工作 | 风险 |
| --- | --- | --- |
| `java.nio.file`（101 处） | 把 WAL 写路径改回 `java.io` + `FileChannel`（`FileChannel` 本身 API 1 就有，`StandardOpenOption` 没有）；段文件与 manifest 的原子替换需要自己封装 `rename(2)` 语义 | **最高**。这是 D18 fsync 顺序与「manifest 原子替换」所在的代码；改错的表现是撕裂纪元，不是崩溃 |
| `java.time`（8 处） | 二选一：改为 `java.util.Date`/`Calendar`，或开 `coreLibraryDesugaring`（`desugar_jdk_libs`） | 中。desugaring 会给全仓加 D8 变体与构建时间，但改动面小 |
| `NotificationChannel` | 渠道创建/读取要按 `SDK_INT` 门控：26+ 走渠道，24/25 走无渠道通知；`NotificationCapability` 的「渠道被关」检测在 24/25 上**无法实现**（`getNotificationChannel` 是 26） | 中。会让「通知不可见 → 降级仅前台」这条承诺在 24/25 上退化成「只能靠 areNotificationsEnabled」 |
| 形态 | 24/25 = Android 7.0/7.1。这两档在 2026 年的存量、以及它们对 `dataSync` FGS 语义（8.0 才引入后台执行限制）的差异 | 未知，见 §2.5 |

**结论：降到 24/25 的收益是「多覆盖两档老设备」，代价是动 WAL 的 I/O 层。**
按本仓库「错了最贵的地方不冒险」的既有纪律（计划 §8「Rust 下沉只做 Wire→WAL 格式与恢复」同一逻辑），
**不建议降**。

### 1.7 升到 28+ 能得到什么

| 抬到 | 得到 | 值不值 |
| --- | --- | --- |
| 28（Android 9） | `FOREGROUND_SERVICE` 权限真实存在（26/27 上声明了也是空转）；明文流量默认拒绝（本仓库已用 `network_security_config.xml` 精确放行 `127.0.0.1`，不受影响） | 收益接近零：现在的代码已在 26 上正确处理了这两点 |
| 31（Android 12） | `PendingIntent` 可变性强制（代码里已经必须带 flag）、后台起 FGS 抛 `ForegroundServiceStartNotAllowedException` | 收益小：这些是「必须处理」而不是「抬门槛才能写」 |
| 33（Android 13） | `POST_NOTIFICATIONS` 运行时权限成为唯一模型，可删掉「无该权限」的历史分支 | 小：降级分支已经写好并有 API 33 实测（`android/dsh/README.md` §1.1） |
| 34（Android 14） | **UIDT 主通道可用，FGS 回退分支整体消失**（`TurnChannel` 只剩两态） | **收益最大**，但等于放弃 Android 8–13 的全部设备。这是产品取舍，不是技术取舍——**本轮不决定** |
| 35（Android 15） | 16 KB 页设备成为常态 | 无意义：16 KB 兼容性与 minSdk 无关 |

**一句话：抬门槛没有「解锁」什么，只是「少写分支」。** 分支已经写完了、也有测试，所以抬门槛的收益不足以抵消设备覆盖的损失。

### 1.8 改动纪律（谁能改 `minSdk`，改了要跑什么）

`minSdk` 是一个**跨 10 个模块的隐式契约**。任何改动必须同时：

1. 改 §1.1 表里的**全部**模块（漏一个会在该模块的 AAR/manifest merge 处报错，或更糟：静默通过但运行期崩）；
2. 重跑 §1.2 的三条 grep，确认新下限之下没有未门控的符号；
3. 重跑 `android/tools/structure_check.py` 与 `./gradlew test`；
4. 在**真的更低 API 的镜像**上跑一次 boot→HELLO（见 §2.4：今天没有 26–32 的镜像，所以这条现在**做不到**）；
5. 回来改本文 §1 与 §2。

**「随手改小试试」在本仓库是最坏的一种改动**：它不会在 CI 红，只会在某台老设备上崩。

## 2. 机型矩阵

### 2.1 这份矩阵是什么，不是什么

**是**：测试**目标**的定义——哪些 API 级别、哪些 OEM、哪些形态、哪些内核/页大小组合**必须**被覆盖，
以及每一格现在处于什么证据等级。

**不是**：实测结果。**本轮不做真机**（用户明确要求）。表里绝大多数格子今天是 `not-verified`，
这是矩阵的正常初始状态，不是缺陷。

### 2.2 证据等级（沿用本仓库既有分级）

定义来自 `docs/receipts/android-port-2026-10-31.md:7-14`：

| 等级 | 含义 |
| --- | --- |
| `jvm` | 纯 JVM 单测/集成测，无设备 |
| `emulator` | 模拟器上跑通（本仓库两台：API 35 = `emulator-5554` 系，API 33 = `emulator-5556` 系） |
| `device` | 真机才成立 —— **本轮全部未做** |
| `not-verified` | 没有证据，且**不得在产品文案里声称** |

### 2.3 矩阵（目标 × 现状等级）

#### A. API 级别轴

| API | Android | 通道（`TurnChannel.select`） | 现状等级 | 证据 / 缺什么 |
| --- | --- | --- | --- | --- |
| 26 | 8.0 | `DATA_SYNC_FOREGROUND_SERVICE` | `not-verified` | 无镜像。分支与 33 相同（`select` 的 `else`），但**没有在真 SDK_INT=26 上跑过** |
| 27 | 8.1 | 同上 | `not-verified` | 无镜像 |
| 28 | 9 | 同上 | `not-verified` | 无镜像 |
| 29 | 10 | 同上 | `not-verified` | 无镜像 |
| 30 | 11 | 同上 | `not-verified` | 无镜像 |
| 31 | 12 | 同上 | `not-verified` | 无镜像。**这一档最值得先补**：后台起 FGS 从此被拒（`START_NOT_ALLOWED`），是行为断点 |
| 32 | 12L | 同上 | `not-verified` | 无镜像 |
| 33 | 13 | 同上 | **`emulator`** | `android/dsh/README.md`（K4）：真实 `SDK_INT` 选 FGS、真实 `startForegroundService`、`dumpsys` 见 `isForeground=true` + `foregroundId=7301`、通知降级（revoke 后 `OK (1 test)`）、零回调 force-stop 两段 probe |
| 34 | 14 | `USER_INITIATED_JOB` | `not-verified`（本车道） | UIDT 只在 **35** 上跑过；34 上「UIDT 排程失败→回退 FGS」未测（`android/dsh/README.md` §6 第 5 条） |
| 35 | 15 | `USER_INITIATED_JOB` | **`emulator`** | `docs/receipts/android-p6-kill-matrix-2026-11-01.md`（kill 矩阵）、`android-port-2026-10-31.md` §47（drain 52 ms、后台 10 分钟→回前台→`APP_TURN_OK`）、`android-p23-budgets-tier-2026-11-01.md`（按内存选档） |
| 36 | 16 | — | `not-verified` | `compileSdk = 35`，**没有任何 36 的行为证据**；16 的变更（job 配额等）只在计划 §7.1 的背景段与 §7.8 的来源里被引用 |

**注**：K4 那张表自己写着「上一轮记录，本轮未重跑」（`android/dsh/README.md` §1 开头）。
引用 API 33 的证据时必须带上这句限定，否则会把它当成「当前树上的实测」。

#### B. OEM 轴（全部 `not-verified`）

| OEM | 已知风险（来自计划 §7.5，不是实测） | 现状等级 |
| --- | --- | --- |
| 华为 / 荣耀 | `HwPFWService` 对 wakelock ≥10min 标记、≥60min 强杀；`com.huawei.webview` ≈ Chromium 99 基线 | `not-verified` |
| 小米（HyperOS / MIUI） | Sleeping / Deep sleeping apps（3 天不用即睡） | `not-verified` |
| OPPO（ColorOS） / vivo（OriginOS） | 后台查杀、自启管理 | `not-verified` |
| 三星（One UI） | Sleeping apps / Deep sleeping apps；对 target 14 的合规 FGS 承诺改善 | `not-verified` |
| 原生（Pixel / AOSP） | 最接近 AVD 行为 | `not-verified`（AVD 只代表 AOSP 行为，**不代表任何 OEM**） |

**纪律**：计划 §7.5 已经把策略定成「引导放行，不做 per-OEM 代码分叉」。所以 OEM 轴的 `not-verified`
**不影响代码分叉决策**，只影响「我们敢不敢在文案里说后台能跑」——答案是 §2.6 的「不敢」。

#### C. 形态轴

| 形态 | 现状等级 | 说明 |
| --- | --- | --- |
| 手机竖屏 | `emulator` | 两台 AVD 都是 `pixel_6` 规格 |
| 手机横屏 | `not-verified` | 排期里没有任何横屏测试 |
| 平板 | `not-verified` | `:lib` 有 36 个页面，但**没有平板断点/双栏的证据** |
| 折叠 / 多窗口 | `not-verified` | 多窗口会改变 lifecycle 事件序列（`onStop` 时机），直接影响 §2.4 的 drain 证据 |
| 桌面模式 / DeX 类 | `not-verified` | 同上 |

#### D. WebView 内核轴

| 内核 | 现状等级 | 说明 |
| --- | --- | --- |
| AVD 自带（`android-35` google_apis） | `emulator` | 只证明「那一版内核」 |
| 华为 `com.huawei.webview`（≈ Chromium 99） | `not-verified` | **门槛是 M99**（计划 §4.1-8、R4）；本仓库没有任何 M99 上的实测 |
| 用户手动降级/停更的 WebView | `not-verified` | 探测代码在（见下），但没有采集过数据 |

探测能力**已实现**：`android/engine/src/main/kotlin/com/phonedsh/engine/WebViewEngine.kt:1171,1212`
（`WebView.getCurrentWebViewPackage()` + `WebSettings.getDefaultUserAgent()` 兜底），
`WebViewKernel.kt:238-241` 负责把 provider 包名与版本归类。**能力有，数据没有。**

#### E. 页大小轴（16 KB）

| 页大小 | 现状等级 | 说明 |
| --- | --- | --- |
| 4 KB（所有已知模拟器） | `emulator` | 16 KB 的属性在 4 KB 设备上**不可见**（`check-native-alignment.py` 的 docstring 明确写了这一点） |
| 16 KB（Pixel 8 类新机 / Android 15+ 的 16 KB 镜像） | `not-verified` | 只有**静态**证据：ELF `p_align` 与 APK zip 对齐（§3.2）。**没有一台 16 KB 设备上加载过 `.so`** |

#### F. 内存档位轴（`spec/v1/budgets.md` §4 的五档）

| 档 | 现状等级 | 证据 |
| --- | --- | --- |
| ≤ 3 GiB | `emulator` | `android-p23-budgets-tier-2026-11-01.md` 的 2 GB AVD（`hw.ramSize=2G`），档位选择与超档写入被拒 |
| ≥ 6 GiB | `emulator` | 同回执的 6 GiB AVD（`hw.ramSize=6144`） |
| 4 GiB | `not-verified` | 没有该内存配置的镜像 |
| 8 GiB（默认档） | `not-verified` | 没有该内存配置的镜像（AVD 默认不是 8 GiB） |
| 12 GiB | `not-verified` | 没有该内存配置的镜像 |
| 未知上限 / 读不到 `totalMem` | `jvm` | 回执 §…「未知上限 → 最小行」有单测，无设备 |

#### G. 存储轴

| 项 | 现状等级 | 说明 |
| --- | --- | --- |
| 模拟器 QCOW2（`userdata-qemu.img`） | `emulator` | kill 矩阵的全部证据都在这里 |
| f2fs / ext4 真机 | `not-verified` | **掉电语义（level-2）的整个论证卡在这里**，见 `android-durability-decision-2026-11-01.md` §3 |
| 可移除存储 / SD 卡 | `not-verified` | 应用只用内部存储，未设计外置 |

### 2.4 今天真有证据的格子（穷举）

| 格 | 等级 | 证据出处 |
| --- | --- | --- |
| API 35 / AOSP AVD / 手机竖屏 / 4 KB / 2 GB / QCOW2 | `emulator` | `docs/receipts/android-p6-kill-matrix-2026-11-01.md` §0-§1 |
| API 35 / AVD / boot→HELLO→一个完整回合 | `emulator` | `docs/receipts/android-port-2026-10-31.md` §4.1（`android/tools/run-app-turn.sh`，12 条断言） |
| API 35 / AVD / 后台 10 分钟→回前台→回合 OK | `emulator` | `docs/receipts/android-port-2026-10-31.md` §47 |
| API 35 / AVD / 按物理内存选 budgets 档 | `emulator` | `docs/receipts/android-p23-budgets-tier-2026-11-01.md` |
| API 33 / AVD / FGS 回退通道全链路 | `emulator` | `android/dsh/README.md`（K4；**「上一轮记录，本轮未重跑」**） |
| 纯 JVM（无设备）的语义层 | `jvm` | 839+ JVM 测试，`docs/receipts/android-port-2026-10-31.md:33` |
| 16 KB 静态合规 | 构建产物检查 | §3.2 的两条命令 |

**除这 7 行，矩阵里其它所有格子都是 `not-verified`。**

### 2.5 未知，以及缺什么证据

| 未知 | 缺什么 |
| --- | --- |
| API 26–32 的**真实**行为 | 一台 API 28 或 31 的镜像（`system-images;android-31;google_apis;arm64-v8a`），跑 boot→HELLO + 后台信号。**这是矩阵里最便宜的一格**：一条 `avdmanager create` 就够，不需要真机 |
| 34 上 UIDT 失败→FGS 回退 | API 34 镜像 + 制造 `JobScheduler.schedule` 失败（配额/不可见） |
| OEM 查杀的实际窗口 | 至少 4 台真机（华/米/OV/星）+ 长时待机观测。**这是矩阵里最贵的一格** |
| M99 WebView 上的可用性 | 一台华为真机（或一个能装 `com.huawei.webview` 的镜像——没有这种镜像） |
| 16 KB 设备上的 `.so` 加载 | 一台 Android 15 + 16 KB 页的真机或 16 KB 系统镜像（`-page-size 16k` 的 emulator 变体） |
| 折叠/多窗口的 lifecycle 差异 | 折叠机型或可配置多窗口的镜像 |
| 4 / 8 / 12 GiB 档 | 三个对应 `hw.ramSize` 的 AVD（便宜，但优先级低于 API 31） |
| 2 年后的设备分布 | **外部数据**。本仓库没有任何设备分布数字，本文不编 |

### 2.6 矩阵如何被使用（三条纪律）

1. **文案只能引用 `device` 或 `emulator` 的格子。** 一条承诺落在 `not-verified` 格子上，就是不允许写进产品文案
   （与 `android-promise-tiers-2026-11-01.md` 同一纪律）。
2. **`emulator` 不等于「设备类结论」。** AVD 是 AOSP + QCOW2，没有 OEM 的电源管理，没有真实 write cache。
   它可以证明「代码路径成立」，不能证明「用户设备上成立」。
3. **矩阵扩容的顺序按「每格能杀掉多少假设」排**，不按 OEM 名气排：
   API 31（后台起 FGS 断点）> 16 KB 设备/镜像 > API 34 > OEM 真机 > 8/12 GiB 档 > 平板/折叠。

## 3. 分发渠道

### 3.1 决定

> **首发走侧载；架构继续按 Play 合规设计；上架推迟到三件事之后：**
> **(a) 后台通道真正接线**（今天 `START_BACKGROUND_TASK` 无窗口，见 §3.5-C）、
> **(b) 发布身份替换 probe 身份**（`applicationId`/`versionName`）、
> **(c) release 签名与密钥管理落地**。

理由与代价在 §3.6/§3.7。**这个决定今天几乎没有代价，因为架构不受渠道影响**（计划 §7.6 第一条），
而且**今天根本没有后台能力可被渠道影响**——真正的分叉点在 P4 接线那天。

### 3.2 事实基础（全部本机可复核）

| 事实 | 证据 |
| --- | --- |
| `targetSdk = 35` | `android/app/build.gradle.kts:202`、`android/lib/build.gradle.kts:33`、`android/dsh/build.gradle.kts:29`；合并清单 `…/merged_manifest/release/…/AndroidManifest.xml:10` |
| `compileSdk = 35` | `android/app/build.gradle.kts:197` |
| **没有 release 签名配置** | `grep -n "signingConfig" android/app/build.gradle.kts` → 无输出；产物名就是 `app-release-unsigned.apk` |
| ~~发布身份是探针~~ | **已改（2026-11-02）**：`applicationId = "com.phonedsh.app"`、`label = "PDSH"`、`versionName = "0.1.0"`、`versionCode = 1`；`namespace` 仍是 `com.phonedsh.probe`（改它要搬 18 个文件，不值）。签名走两条路，无 keystore 时回落到调试签名并在关于页标明「调试签名，不可发布」 |
| release APK 存在且可检查 | `android/app/build/outputs/apk/release/app-release-unsigned.apk`（约 64 MB，含 65 MB worker bundle） |
| **16 KB：ELF 合规** | `python3 android/tools/check-native-alignment.py` → `LOAD[1..3] p_align=0x4000 (16384 bytes) OK` / `[PASS] … 3 PT_LOAD segment(s), min p_align=0x4000 (16384) is 16 KB-page ready` |
| **16 KB：APK zip 合规** | `zipalign -c -P 16 -v 4 app-release-unsigned.apk` → `Verification succesful`（build-tools 35.0.0） |
| 16 KB 只是静态证据 | 两台 AVD 都是 4 KB 页；`check-native-alignment.py` 的 docstring：该属性「invisible on a 4 KB emulator」 |

### 3.3 Play 的硬性要求（外部政策，逐条标复核状态）

> **纪律**：这些是**外部政策**，不是本仓库能自证的事实。`hygiene.py` 的 hostname 白名单不含这些文档域，
> 所以本文**不内联 URL**，只给「标题 + Play 帮助的 answer/路径段」，供发布前逐条复核。
> 表里 `已内联` 表示「已在本仓库的构建/代码里有对应动作」，`待复核` 表示「只能去公告页确认」。

| # | 要求 | 与本次决策的关系 | 状态 |
| --- | --- | --- | --- |
| 1 | **16 KB 页大小兼容**（对 target Android 15+ 的 app，2025-11 起对新应用与更新生效） | 本仓库**已满足**（§3.2）。所以 16 KB **不是**上架的阻塞点 | 已满足 + 待复核生效范围 |
| 2 | **target API 门槛**（按年上移，8 月 31 日一档；Play 帮助「Target API level requirements」answer/11926878） | `targetSdk = 35` 对应 2025 年那一档。**2026 年的门槛本仓库没有核实**；若已到 36，**上架路径的第一个硬门槛就是 targetSdk，而不是 16 KB** | **待复核（未知）** |
| 3 | **前台服务类型申报**（`dataSync` 需说明用途、用户影响；`specialUse` 需人工审核 + 演示视频） | 清单里**声明了** `dataSync` FGS（`android/dsh/src/main/AndroidManifest.xml`），但**产品路径从不启动它**（§3.5-C）。为一个不运行的通道写申报表是纯成本 | 待复核 |
| 4 | **`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`** 仅限特定类别 | 仓库**刻意不声明**（`:dsh` 清单注释与 `security-checklist`）：这条已经按 Play 边界做了 | 已内联 |
| 5 | **AI 生成内容**类政策（含不当内容的举报入口） | 本 app 会展示模型输出，**没有举报入口**。这是一条真实缺口，不是「待确认」 | **缺口** |
| 6 | **凭据/账号**：审核时需要能让审核员跑起来 | 模型 key **只能**从 `<files>/import-key.txt` 导入，且只在 debuggable 构建里生效（`MainActivity.kt` 的 `FLAG_DEBUGGABLE` 门控）。审核员拿不到 key，也**没有 UI 能输入 key**（§3.5-D） | **缺口** |

### 3.4 政策风险点：这个 app 到底做了什么

逐条对着「可能被点名」的行为，给出**代码事实**而不是印象：

| 行为 | 代码事实 | 风险判断 |
| --- | --- | --- |
| 读 `/dsh/home/**` | 这是**应用私有存储里的虚拟路径**，映射到 `files/xl/**`（D4 drip sink：`spec/v1/README.md:136`；VFS 根见 `spec/v1/budgets.md` §4 的 bucket 划分） | **无风险**。没有申请 `MANAGE_EXTERNAL_STORAGE`，也没有读写共享存储 |
| 跑 WebView | 单 WebView（`android-single-webview-invariant-2026-11-01.md`），只加载 `http://127.0.0.1:<随机端口>`（`network_security_config.xml` 只对 `127.0.0.1` 开明文） | 低。**没有 `addJavascriptInterface`**（全仓 grep 无命中），JS↔native 走 loopback WS，不走 JS 桥 |
| 动态下发 JS | worker bundle 以 **asset** 打包（`assets/worker-bundle.zip`），不联网拉 JS | **合规**。计划 §7.6 的红线（webview + JS bridge + 不可信内容）在**结构上**不成立：没有 JS 桥 |
| JIT / WASM | `shell/crates/pdsh-brush-wasm`、`pdsh-jaq-wasm`；`budgets.md` §4 的「WASI hot instance」行说明确实是 WASM 运行时 | 低-中。**这不是「下载可执行代码」**（WASM 随包/随 worker 分发，不是从商店外下发 dex/so），但 Play 对「解释执行」的态度要按公告复核 |
| 网络出口 | 模型 API 走 HTTPS（`DEEPSEEK_BASE_URL` 可配置）；gateway 有六类安全规则 + 28 条金标向量 | 无风险，且是加分项 |
| 后台 | **不启动任何前台服务**（§3.5-C） | 少一条申报，也少一条能力 |

### 3.5 与渠道决策直接相关的四个代码事实

**A. 16 KB 已经做了，所以「为 Play 做 16 KB」不是理由。**
它现在是 P2a 的门禁（`android/tools/check-native-alignment.py` + 会红的 unittest），与渠道无关。

**B. 发布身份还不是产品身份。**
`com.phonedsh.probe` + `0.0.0` + 无签名 = **三个独立的阻塞项**，任一不解决都上不了架、也发不了正式侧载版。
`applicationId` 一旦改变，已安装的探针版就无法原地升级（签名与包名都变）——这在侧载期无所谓，在公开分发前必须一次定死。

**C. 后台通道：声明了，但产品路径从不打开。**（这条最容易被误读，所以写全）

| 层 | 事实 | 证据 |
| --- | --- | --- |
| 声明 | `:dsh` 的 AAR **声明了** `TurnForegroundService`（`dataSync`）、`TurnJobService`（UIDT）、`TurnStopReceiver`、`BootReceiver`，并有 6 个权限 | `android/dsh/src/main/AndroidManifest.xml` |
| 合并 | 这些组件**确实进了 release APK 的合并清单** | `…/merged_manifest/release/…/AndroidManifest.xml:87-236`（service/receiver 多行） |
| `:app` 自己的清单 | 只有 1 个 activity、1 个 provider（来自 `:lib`），**没有 service/receiver** | `android/app/src/main/AndroidManifest.xml` |
| **产品路径** | **没有任何生产代码调用 `TurnBackground.start(...)`**——全仓只有 `android/dsh/src/androidTest/**` 调用它 | `grep -rn "TurnBackground\.start" android/*/src/main` → 空 |
| 后果 | D14 的 `START_BACKGROUND_TASK` 被如实上报为「**没有后台窗口**」，drain 在进程内完成（设备上 52 ms） | `android/dsh/src/main/kotlin/com/phonedsh/dsh/host/DrainLane.kt:39-48`；`docs/receipts/android-port-2026-10-31.md` §47 |

→ **所以：为 Play 写 FGS 申报表，是为一个永远不会启动的服务写。** 这不是「合规风险」，是「纯成本 + 虚假陈述风险」。

**D. release 包无法配置模型 key。**
`ApiKeyStore.save()` 的唯一调用者是 `importDevelopmentKey`（`ApiKeyStore.kt:275`），而它在
`MainActivity.kt` 里被 `FLAG_DEBUGGABLE` 门控。全仓**没有**任何 UI 或 Intent 入口能写 key。
后果：**release APK 装上之后跑不了真实回合**——这对「上架」是硬阻塞（审核员连不上模型），
对「侧载内测」是可用但要写清楚（内测包必须是 debug 构建）。

### 3.6 建议：侧载优先（含理由）

**建议：首发侧载（内测渠道），上架留到 §3.1 的三件事之后。**

| 理由 | 依据 |
| --- | --- |
| 1. 今天**没有**后台能力，而上架的核心成本（FGS 申报、`specialUse` 审核、AI 内容政策、审核可运行性）全在后台与模型侧 | §3.3 #3/#5/#6、§3.5-C/D |
| 2. 发布身份三件套（包名/版本/签名）都还没做，上架会**逼着**一次做完，而这三件事与「后台通道怎么接线」无关 | §3.5-B |
| 3. 侧载让 `specialUse` 这类「需要人工审核」的兜底通道变成可用（计划 §7.2 的通道表：`specialUse` 仅侧载版兜底），而 Play 版必须为它准备演示视频 | 计划 §7.2 通道表（第 249 行） |
| 4. 架构不受渠道影响：UIDT/FGS/Doze/freezer 这些系统级限制只看 `targetSdk` 与 ROM，不看安装来源 | 计划 §7.6 第一条 |
| 5. 恢复型产品最怕「恢复逻辑的 bug 推不出去」——但如果今天连恢复都还没接线，自动更新的收益是 0 | §3.5-C |
| 6. 16 KB 已满足，所以「为了 Play 才做 16 KB」这个动机不存在；侧载也不会因此少做什么 | §3.2 |

### 3.7 如果选另一条路（直接上架 Play），代价是什么

按「先做哪一件、各要多久/多大风险」排：

| # | 代价 | 具体工作 | 风险 |
| --- | --- | --- | --- |
| 1 | **审核可运行性** | 要么加一个「演示模式」（内置脚本上游，`android/tools/scripted-model-upstream.py` 已有现成实现），要么加 key 输入 UI 并在审核备注里给测试 key | 中。演示模式会引入「审核看到的行为 ≠ 真实行为」的信任问题 |
| 2 | **发布身份** | 定 `applicationId`、`versionName/versionCode` 策略、release 签名 + 密钥托管 | 中。包名一旦发布不可改 |
| 3 | **FGS 申报** | `dataSync` 的类型说明 + 用户影响说明 + **演示视频**；若用 `specialUse`，每次更新可能复审 | 中高。**而且要先接线**，否则是虚假申报 |
| 4 | **target API 跑步机** | 每年 8/31 前抬 `targetSdk`；抬一次要重跑 §1.8 的全部纪律 + 矩阵回归 | 中。这是永久成本，不是一次性 |
| 5 | **AI 内容政策** | 举报入口 + 处理流程 + 文案 | 中。缺失会被拒 |
| 6 | **隐私/数据安全表单** | 声明读了哪些设备信息（`DeviceCapabilities` 读型号/权限/内存档）、数据是否离开设备 | 低-中。本 app 的数据面很窄，但**必须逐项写** |
| 7 | **16 KB** | 已满足 | 无 |
| 8 | **审核不确定性** | 「WebView + 模型 key + 后台任务」这个组合天然容易被问 | 中。**被拒一次的成本通常是一次完整排期** |

**如果反过来选侧载，要付的代价（对称地写出来）：**

| # | 代价 | 缓解 |
| --- | --- | --- |
| 1 | 没有自动更新：恢复逻辑的 bug 修完推不出去 | 版本号 + 升级说明 + 迁移测试（`dataExtractionRules` 已排除敏感路径） |
| 2 | 没有 vitals / 崩溃遥测 | 诚实回执（`docs/receipts/**`）+ 用户手动回传日志 |
| 3 | 没有信任背书 → 用户更不愿意给通知权限、更容易被 OEM 杀 | 引导页 + `HostBackground` 的诚实读数（已有） |
| 4 | 安装摩擦（未知来源） | 内测渠道 + 说明文档 |
| 5 | Play 专属能力用不上（App Bundle 分发、分阶段发布） | 无（侧载本来就不需要） |
| 6 | 政策上更自由，但**系统级限制照旧**（Doze/freezer/后台起 FGS 被拒） | §2.6 的矩阵纪律 |

## 4. 与计划 / 既有回执不一致的地方

| # | 计划或文档说 | 实际是 | 影响 |
| --- | --- | --- | --- |
| 1 | 计划 P0 把「机型矩阵 + minSdk + 分发渠道」列为**阻塞项** | `minSdk` 早在代码里定死（10 个模块），只是没有记录；矩阵与渠道**确实**没有 | 本文把「已定未记」补上；「阻塞」应降级为「待扩容」（§2.5） |
| 2 | `DrainLane.kt:40` 注释：「The probe App declares no service (`AndroidManifest` has none)」 | `:app` 自己的清单确实没有，但 `:dsh` 的 AAR **声明了 6 个组件并合并进了 APK**（§3.5-C 表） | 「没有声明」与「声明了但从不启动」是两件事。**结论（无后台窗口）不变，理由要改**——否则下一个人会以为补个清单就能开窗口 |
| 3 | `PhoneDshHost.kt:669` 注释：「this App declares no service」 | 同上 | 同上 |
| 4 | 计划 §7.9 承诺表把「锁屏（UIDT/FGS 在位）」当作可承诺场景 | 通道**从未被产品路径启动**（§3.5-C） | 见 `android-promise-tiers-2026-11-01.md` §4 |
| 5 | 计划 §7.9 假设存在「后台回合」 | 不存在；后台发生的是**收尾**（drain → Parked），不是继续 | 同上 |

## 5. 这份文档什么时候该重写

**触发条件（命中任一条就重写，不要「顺手改一句」）：**

1. **P4 把后台通道接线落地**（`TurnBackground.start` 出现生产调用者）→ §3.5-C、§3.6、§3.7 全段作废重写；
   同时渠道决策要重新评估（那时 Play 申报表才有意义）。
2. **第一台真机到手** → 矩阵 B/C/D/E/F 轴的 `not-verified` 要逐格改成 `device` 或「测了不成立」。
3. **`minSdk` 或 `targetSdk` 变更** → §1 全段 + §3.3 #2 重写（并按 §1.8 跑完纪律）。
4. **`compileSdk` 抬到 36** → 矩阵 A 轴要加 API 36 行，§3.3 #2 要重新核。
5. **决定上架**（哪怕只是「开始准备」）→ §3.3 全部 `待复核` 必须变成有日期的复核结论；
   §3.5-B/D 的两个缺口必须先关。
6. **16 KB 从静态证据变成设备证据**（第一次在 16 KB 机器上装成功）→ §2.3-E、§3.2 更新。
7. **新增一个依赖 AAR 的 `minSdk` > 26** → §1.1 表与 §1.3 排除项要改（AGP 会先报错，但理由要留在这里）。

## 6. 证据附录（本文所有断言的复现命令）

```bash
# minSdk / targetSdk 全部落点
grep -n "minSdk\|targetSdk\|compileSdk" android/*/build.gradle.kts

# 合并后的清单（安装包真正携带的值与组件列表）
grep -n "minSdkVersion\|targetSdkVersion" \
  android/app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml
grep -n "<service\|<receiver" \
  android/app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml

# §1.2 的三条硬约束
grep -rn "java.nio.file" android/*/src/main --include="*.kt" | wc -l     # 101
grep -rn "java.time"     android/*/src/main --include="*.kt" | wc -l     # 8
grep -rn "NotificationChannel" android/*/src/main --include="*.kt"
grep -rn "desugar\|coreLibraryDesugaring" android/ --include="*.kts" --include="*.toml"  # 空

# §1.2 的否证
grep -rn "Build.VERSION_CODES.O\b" android/*/src/main | wc -l            # 0
grep -rn "@RequiresApi(26)" android/*/src/main | wc -l                   # 0

# §1.5 历史
git log --oneline -S "minSdk = 26" -- android/

# §3.5-C 后台通道没有被产品路径启动
grep -rn "TurnBackground\.start" android/*/src/main                      # 空
grep -rln "TurnBackground" android/*/src                                # 只有 :dsh 内部 + androidTest

# §3.2 16 KB 两条静态证据
python3 android/tools/check-native-alignment.py
"$ANDROID_HOME/build-tools/35.0.0/zipalign" -c -P 16 -vv \
  android/app/build/outputs/apk/release/app-release-unsigned.apk | tail -1

# §3.2 签名（应为空）
grep -n "signingConfig" android/app/build.gradle.kts

# §2.4 的证据出处
sed -n '1,60p' docs/receipts/android-p6-kill-matrix-2026-11-01.md
sed -n '2070,2110p' docs/receipts/android-port-2026-10-31.md
sed -n '1,60p' android/dsh/README.md
```
