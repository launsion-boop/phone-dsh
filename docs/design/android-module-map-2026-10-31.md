<!-- SPDX-License-Identifier: MIT -->
# Android 模块接线图（P0，2026-10-31）

**状态：结构骨架，构建 `BLOCKED(host)`。** 本文件是给下一轮接手人的接线图，不是实现说明。
已定决策：`minSdk 26` / `targetSdk 35`，首发侧载；本轮不写 Android 产品代码。

## 1. 三分区落位

| 分区 | 位置 | 本轮动作 |
| --- | --- | --- |
| 基线区 | `Sources/PhoneDSH*`、`Tests/`、`Package.swift` | 不动（Swift 参考实现） |
| 共享区 | `spec/`、`plugins/`、`shell/` | 不动；契约、Worker、Rust 仍是单一来源 |
| 适配区 | `android/` | 只新增结构、版本目录、CI 声明、自检 |

Android 不复制 `spec/` 或 `plugins/`；Kotlin 宿主读共享契约，不读 Swift 翻译。
`android/` 是唯一新增大树；`examples/probe-app` 不改名、不参与本轮。

## 2. Gradle 模块与 1:1 镜像

11 个 Gradle 模块，11 个 Kotlin 包对应 11 个 Swift 模块。模块数比 Swift 多一个，是因为 SPI 的**接口**与**Android 实现**分开：`:platform` 保持纯 JVM，`:core`/`:net` 这两个 JVM 模块才能直接消费它，而 Keystore/`Os.fsync`/`ActivityLifecycleCallbacks` 那些实现进 `:platform-android`。（曾考虑给 `:platform` 装上 AGP 再手写注册 JVM 变体，那会让构建依赖 AGP 内部约定，否决。）

| Gradle 模块 | 承载的包 | 形态 |
| --- | --- | --- |
| `:platform` | `com.phonedsh.platform` | Kotlin/JVM，唯一的 SPI 层，不镜像 Swift |
| `:platform-android` | `com.phonedsh.platform.android` | Android library，SPI 的 Android 实现（不镜像 Swift） |
| `:core` | `wire` / `log` / `agentcore` | Kotlin/JVM（零设备可测） |
| `:net` | `loopback` / `gateway` | Kotlin/JVM |
| `:controller` | `com.phonedsh.controller` | Android library |
| `:engine` | `com.phonedsh.engine` | Android library（WebView + EngineHost） |
| `:shell` | `com.phonedsh.shell` | Android library（JNI 绑定） |
| `:dsh` | `com.phonedsh.dsh` | Android library（门面聚合） |
| `:testkit` | `testkit.scenario` / `testkit.harness` | Android library（验证载具） |
| `:lib` | `com.phonedsh.lib` | 可发布 AAR 入口 |
| `:app` | `com.phonedsh.probe` | probe-app（验证载具） |

`:core`、`:net`、`:testkit` 是构建边界合并；**1:1 由包名承载，不是 module 数量**。
完整 11 行映射见 `android/README.md`。`:lib` / `:app` 是发布壳与验证壳，不承载 Swift 镜像。

## 3. AAR 消费方式

- 发布坐标占位：`com.phonedsh:lib:0.0.0-SNAPSHOT`（`group`/`version` 在 `lib/build.gradle.kts`）。
- 组合根应用（the composition-root app）只声明 `implementation("com.phonedsh:lib:0.0.0-SNAPSHOT")`。
- `:lib` 的 `api` 依赖是 `:dsh` 与 `:platform`；其余内部模块经 `:dsh` 传递，POM 统一版本。
- 不发布 `:app` / `:testkit`；`shell/consumer-rules.pro` 随 AAR 下发 R8 keep。
- 组合根应用不得直接依赖 `:core` / `:net` / `:controller` / `:engine` / `:shell`，避免绕过门面。

## 4. `:platform` SPI（六个接口）

| 接口 | 职责（一句话） |
| --- | --- |
| `Durability` | 提供 durable record、fsync 顺序与 epoch close；实现按 OS 分端。 |
| `Clock` | 提供 wall/monotonic 时间与调度原语，测试可注入假时钟。 |
| `SecureStore` | Keystore 支持的密钥/凭据存取，不落明文文件。 |
| `LifecycleSignals` | 进程、前后台、返回栈、renderer-gone 等生命周期信号。 |
| `EngineHost` | 创建/销毁 WebView、处理 renderer 死亡、挂接 loopback。 |
| `Notifier` | FGS 通知与用户可见状态，Android 侧建通知渠道。 |

SPI 是 P1 零设备依赖测试的前提；接口声明在 P1 落地，本轮只有包占位。

## 5. JNI 清单（`:shell` 验收项）

- Rust 以 `-C panic=unwind` 构建；每个 `extern "C"` 边界 `catch_unwind`，panic 不跨 FFI。
- wire 字节用 direct `ByteBuffer`，避免跨边界复制。
- R8 keep：`-keepclasseswithmembernames class com.phonedsh.shell.** { native <methods>; }`
  （已落在 `shell/consumer-rules.pro`；否则 release 才崩）。
- ABI：`arm64-v8a` 发布；`x86_64` 仅 debug（模拟器/测试）。
- 16KB 对齐：`-C link-arg=-Wl,-z,max-page-size=16384`，产物用 `readelf -l` 验收。
- `System.loadLibrary` 失败走诚实 stub（`notLinked`），不伪造成功；错误码入 ABI 文档。

## 6. 双 CI 宿主

| 宿主 | 职责 | 本轮状态 |
| --- | --- | --- |
| macOS（既有 Swift CI） | Swift 基线门禁 + JVM 级 Kotlin 测试 | 不改；Kotlin 段待 wrapper |
| Linux（`.github/workflows/android.yml`） | 结构自检；后续模拟器/instrumentation/真机矩阵 | 仅 `structure` job 生效 |

`structure` job 现在就能跑：`python3 android/tools/structure_check.py --root .` 加变异测试。
`jvm` job（`:core:test :testkit:test`）与 `emulator` job 均未启用：前者缺 wrapper，后者缺
SDK 与模拟器宿主。Worker image、golden、catalog 是一次构建的共享产物，两个宿主消费同一份。

## 7. 构建 BLOCKED 的原因与解除条件

| BLOCKED 项 | 原因 | 解除条件 |
| --- | --- | --- |
| Gradle 配置/构建 | 本机无 Gradle、无 wrapper；只有 JDK 27 与 NDK 30 | 装 JDK 17/21 + Gradle/生成 wrapper；在线解析版本目录 |
| Android 编译 | 无 Android SDK platform 35 / build-tools | 装 platform 35、build-tools；接受 licenses |
| 单测 `:core:test :testkit:test` | 依赖上一行的 Gradle/SDK | 前两项解除后跑通 |
| 模拟器 instrumentation | 无模拟器、无嵌套虚拟化宿主 | 独立 Linux 宿主 + SDK + emulator |
| 版本 pin | 本轮不联网；AGP/Kotlin/Compose 均标 `# unverified pin` | 在构建宿主解析并回写，去掉标注 |

解除后按顺序：结构自检 → `:core:test` → `:testkit:test` →（P1 加 manifest 后）
`:app:assembleDebug` → 模拟器 instrumentation。本轮不生成 wrapper 二进制、不运行 `gradlew`；
这是有意的，不是遗漏。

P1 入场项：`:app` / `:lib` 的 manifest 与资源在 P1 首个功能提交时加入；本轮保持零平台 XML，
避免在 `android/` 尚未进入 hygiene 扫描根时引入需要白名单的平台命名空间。
