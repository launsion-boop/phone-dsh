<!-- SPDX-License-Identifier: MIT -->
# PDSH Android 适配树

> **状态：可构建、可测试、可在模拟器上跑通 boot→HELLO。**
> 12 个 Gradle 模块：11 个 Swift 模块由 **7 个模块镜像**（合并规则见下），另 5 个不镜像 Swift
> （`:platform` 承载 SPI、`:platform-android` 承载 SPI 的 Android 实现、`:domain` 承载 P6 的域名
> 存储与设备能力、`:lib` 是可发布 AAR、`:app` 是 probe-app）。
> **56,248 行 Kotlin 主代码 + 31,270 行单测 + 3,174 行 instrumented**（`wc -l`，2026-10-31 实测）。
> `bash android/tools/run-demo.sh` 一条命令完成 AVD→构建→装包→启动→抓 logcat→截图；
> `bash android/tools/inject-renderer-death.sh` 验证 renderer 被杀后重建恢复。
> 证据等级逐条标注在 `TonoWiki/briefs/2026-10-31-pdsh-android-full-port-plan.md`。

本文的每个数字都来自本文「门禁与数字」一节列出的那条命令；**没有跑过的数字写「未测量」**，
不从别的报告里转抄。

## 两种壳：产品壳 vs 诊断壳

`spec/ui/v1/README.md` §1 说 `WebSurfacePage` 的入口是「RootView 的默认面（引擎就绪时）」。
这句话针对的是**产品壳**——在真正的 DSH App 里，WebView 就是整个界面。

本仓库的 `:app` 是**诊断壳**（`ProbeScreen` + `HostShell`）：它的职责是让人能操作并观察
（跑一个回合、看事件、点进各页），所以引擎就绪时**不会**自动切到 WebSurface。默认面由
`--ez pdsh.face.web true` 这个 launch 参数 opt-in。

**这不是漏实现 §1，是两个不同的壳。** 产品壳的默认面规则在移植时保持原样，只是本仓库
不构建产品壳。两者混淆会导致两个错误：以为我们没实现规范，或者把诊断壳改成产品壳而
失去可观测性。

## 像素基线的边界（必读）

`android/tools/screenshot-capture.sh` 拍 11 张基线（6 个签名面 + 4 个整页 + 1 张字高探针）。
它是**回归门禁**，不是 parity 证明：

- **能证明**：从今以后 UI 改动导致的视觉回归会被抓住（像素 diff > 0.1% 判失败）。
- **不能证明**：Android 与 iOS 视觉一致。基线由**当前 Android 实现**生成，所以它钉住的是
  「不要变得更糟」，不是「和别人一样」。

脚本每次先跑一个 fontScale 1.0 vs 2.0 的字高实验（52→99 px、栅格 36→65 px）才允许写基线——
被否决的 Robolectric/layoutlib 链路在两种 scale 下都报 35 px，那是假数据。
该门禁目前**只能本地手动跑**：CI 的 hosted runner 没有 KVM，跑不了模拟器。

## 先读这个

[KOTLIN-TRAPS.md](KOTLIN-TRAPS.md) 记着本移植踩过的 **10 个** Kotlin/Gradle 陷阱。它们的共同点是**报错位置离真凶很远**。
动 `HostChannel`、改 build 文件、写 KDoc、加 instrumented 测试之前读一遍，能省掉那 20 分钟。
其中第 7 条（`BUILD SUCCESSFUL` 可以是「什么都没跑」）先把「本文的数字怎么来的」讲清楚了：
测试任务被增量构建跳过时，`test-count.sh` 读到的也是上一次的 XML。

## 目录

```text
android/
├── settings.gradle.kts        # 12 个 Gradle 模块 + version catalog
├── build.gradle.kts           # 根 plugins（apply false）
├── gradle.properties          # AndroidX / R 类 / JVM 最小开关
├── gradle/libs.versions.toml  # AGP/Kotlin/Compose 占位 pin（全部 unverified）
├── lib/                       # 可发布 AAR：com.phonedsh:lib:0.0.0-SNAPSHOT
├── app/                       # probe-app（验证载具）
├── testkit/                   # scenario runner / UI 状态录制 / fault driver
├── platform/                  # SPI 接口（纯 JVM）：Durability/Clock/SecureStore/LifecycleSignals/EngineHost/Notifier
├── platform-android/          # 上述 SPI 的 Android 实现（Keystore/Os.fsync/Lifecycle）
├── domain/                    # P6：DomainStore（framework SQLite）+ DeviceCapabilities
├── core/                      # wire + log + agentcore
├── net/                       # loopback + gateway
├── controller/ engine/ dsh/
├── shell/                     # JNI 薄包装 pdsh-ffi 的统一 C ABI：rg / jaq（见 shell/README.md）
└── tools/                     # structure_check.py + test-count.sh + unittest
```

## Swift 模块 → Kotlin 包 → Gradle 模块（11/11）

| Swift 模块（`Sources/`） | Kotlin 包 | Gradle 模块 | 说明 |
| --- | --- | --- | --- |
| PhoneDSHAgentCore | `com.phonedsh.agentcore` | `:core` | 合并进 `:core`；宿主语义底层 |
| PhoneDSHWire | `com.phonedsh.wire` | `:core` | 合并进 `:core`；纯字节/金标 |
| PhoneDSHLog | `com.phonedsh.log` | `:core` | 合并进 `:core` |
| PhoneDSHLoopback | `com.phonedsh.loopback` | `:net` | 合并进 `:net` |
| PhoneDSHGateway | `com.phonedsh.gateway` | `:net` | 合并进 `:net` |
| PhoneDSHController | `com.phonedsh.controller` | `:controller` | 1:1 |
| PhoneDSHEngine | `com.phonedsh.engine` | `:engine` | 1:1（WebView / EngineHost） |
| PhoneDSHShell | `com.phonedsh.shell` | `:shell` | 1:1（JNI 绑定） |
| PhoneDSH | `com.phonedsh.dsh` | `:dsh` | 1:1（门面聚合） |
| PhoneDSHScenario | `com.phonedsh.testkit.scenario` | `:testkit` | 合并进 `:testkit` |
| PhoneDSHHarness | `com.phonedsh.testkit.harness` | `:testkit` | 合并进 `:testkit` |

**合并规则**：`:core`（wire + log + agentcore）、`:net`（loopback + gateway）、`:testkit`
（scenario + harness）是 Gradle 构建边界的合并；**1:1 由包名承载，不是 module 数量**。
审查时先看包名，再看 `:platform` 这个唯一的 SPI 层（它不镜像 Swift）。

## AAR 坐标与消费

- 发布坐标：`com.phonedsh:lib:0.0.0-SNAPSHOT`（`group`/`version` 在 `lib/build.gradle.kts`）。
- 组合根应用（the composition-root app）只声明这一条；`:dsh` 与 `:platform` 作为 `api`
  传递依赖随 `:lib` 的 POM 发布，版本统一。不要直接依赖内部模块。
- `:testkit` / `:app` 不发布；`shell/consumer-rules.pro` 随 AAR 下发 R8 keep 规则。

## JVM 测试数（`bash android/tools/test-count.sh`）

下表是 `android/tools/test-count.sh` 的逐模块输出，数字来自一次
`./gradlew test --rerun-tasks --no-daemon --continue`（2026-10-31）之后的 XML。

| 模块 | 测试 | 覆盖内容 |
| --- | --- | --- |
| `:platform` | **18** | SPI 契约与 fake |
| `:platform-android` | **11** | Keystore / Os.fsync / Lifecycle 实现 |
| `:domain` | **79** | 22 条共享 contract + 设备能力 schema/manifest/key-range |
| `:core` | **139** | wire JNI + WAL + agentcore |
| `:net` | **148** | 56 loopback + 92 gateway（60 = 30 条向量 × 2 断言，其余为规则/变异/目录/egress） |
| `:controller` | **67** | 含扰动夹具 + md 驱动的预算表校验 |
| `:engine` | **51** | WebView / EngineHost / worker 资源 |
| `:shell` | **39** | JNI 绑定 + rg/jaq 真加速器 + 帧解码 + panic 边界 |
| `:dsh` | **148** | host HELLO / VFS sink / exec 桥 / 后台 / 工具桥 |
| `:lib` | **287** | UiState 投影 + 6 签名面 + 21 个页面 + ChatScreenState |
| `:testkit` | **108**（1 skipped） | 场景 runner + 轨迹归一化 + host 场景执行 |
| `:app` | 无结果 | probe-app 不跑 JVM 单测 |
| **合计** | **1,095** | 11 个模块，0 failing |

计数口径（`test-count.sh` 的注释里也写了）：Android library/application 的 JUnit 结果在
`build/test-results/testDebugUnitTest`，`java-library` 模块（`:core`/`:net`/`:platform`）在
`build/test-results/test`；**每个模块只计一个变体**，不把 debug/release 两份相加
（旧表里 `:engine 92 = 46 × 2`、`:platform-android 22 = 11 × 2` 就是相加造成的虚高）。

### instrumented（**本轮未测量**）

本轮没有跑模拟器/真机，下面几行是**上一轮的记录**，本轮未复跑，不作为本文任何数字的依据：

| 命令 | 状态 |
| --- | --- |
| `:domain:connectedDebugAndroidTest` | 28/28（上一轮，两个 API）——**本轮未测量** |
| `:engine:connectedDebugAndroidTest` | 2/2（上一轮，emulator-5554）——**本轮未测量** |
| `:platform-android:connectedDebugAndroidTest` | 12/12（上一轮，API 33 与 35）——**本轮未测量** |
| `:dsh:connectedDebugAndroidTest` | 12/12 on API 33、7 pass/3 skip on API 35（上一轮）——**本轮未测量** |
| `bash android/tools/run-demo.sh` | exit 0 + 截图（上一轮）——**本轮未复跑** |
| `bash android/tools/inject-renderer-death.sh` | exit 0，7/7 断言（上一轮）——**本轮未复跑** |

两条模拟器：`emulator-5554` = API 35（主证据），`emulator-5556` = API 33（回退路径证据）。两个脚本都会把 `adb`
固定到一台设备；同时开着两台时裸 `adb` 会报 `more than one device/emulator`。

**未做的**：真机验证（掉电语义、OEM 查杀、华为 WebView 内核、32 位 ABI）按决定推迟到 PR 之后；
`level-2` 掉电承诺在台架缺席时固定为 `NOT_VERIFIED`。

## 门禁与数字（2026-10-31 实测，逐条命令）

| # | 命令 | 结果 |
| --- | --- | --- |
| 1 | `python3 android/tools/structure_check.py --root .` | 9/9 项通过：12 个 include=磁盘、12/12 build 文件、11 个 Swift 模块各映射一次、250 个生产 `.kt` 无占位、0 处绝对路径、8 个 `# unverified pin` |
| 2 | `python3 spec/v1/tools/spec_golden.py --full` | **73 个文件**，0 error |
| 3 | `python3 spec/v1/tools/gateway_check.py --root .` | **30 条向量**，0 error（credential-injection=3 header-strip=3 redirect-scope=8 egress-classification=5 response-redaction=7 failure-surface=4） |
| 4 | `python3 spec/platform/tools/platform_check.py --root .` | 8 个文件、**24 条白名单**、0 failure（classes: hardware-absent=1 os-forced=22 policy-forbidden=1） |
| 5 | `python3 spec/ui/v1/tools/ui_check.py --root .` | 5 个文件、13 组对比度、7 组 DEFER AA、**38 个 geometry token**、1 个未测量 token |
| 6 | `python3 spec/host/v1/tools/host_check.py --root .` | **41 个文件**，0 error |
| 7 | `bash android/tools/test-count.sh` | 11 个模块、**1,095 条测试**、0 failing（见上表） |
| 8 | `python3 -m unittest discover -s android/tools -p 'test_*.py'` | **19 条**，OK（0.5 s） |
| 9 | `grep -c 'include(":' android/settings.gradle.kts` | **12** |
| 10 | `ls android/lib/src/main/kotlin/com/phonedsh/ui/page/*Page.kt \| wc -l` | **21** 个页面 |
| 11 | `find shell/crates -name "*.rs" \| xargs wc -l \| tail -1` | **27,742** 行 Rust（`:shell` 依赖的加速器实现，见 `shell/README.md`） |
| 12 | `find android -path "*/src/main/*" -name "*.kt" \| xargs wc -l \| tail -1` | **56,248** 行 Kotlin 主代码 |
| 13 | `find android -path "*/src/test/*" -name "*.kt" \| xargs wc -l \| tail -1` | **31,270** 行 JVM 单测 |
| 14 | `find android -path "*/src/androidTest/*" -name "*.kt" \| xargs wc -l \| tail -1` | **3,174** 行 instrumented |

## 纪律

- `structure_check.py` 的 `kotlin-stubs` 检查只禁「占位代码」（`TODO()`、not-implemented 抛错），不禁止真实逻辑。
- 版本 pin 全部标 `# unverified pin`；本轮不联网校验，换成本机解析出的版本后才可去掉标注。
- 仓库只允许 `google()` 与 `mavenCentral()`；不放 `local.properties`、不硬编码绝对路径。
- 测试数只认 `test-count.sh` 的输出；引数字前先确认那次 `./gradlew test` 是 `--rerun-tasks` 跑的
  （陷阱 #7）。
