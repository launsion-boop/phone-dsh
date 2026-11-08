<!-- SPDX-License-Identifier: MIT -->
# PDSH Android 适配树

> **状态：可构建、可测试、可在模拟器上跑通 boot→HELLO。**
> 13 个 Gradle 模块：原有 11 个 Swift 模块由 **7 个模块映射**（合并规则见下）；新增加的 Swift 模块中，BLE/LAN 仅有未接入的 target 解码器，ADB 合并进 `:net`（原生 MCP 工具，无 Worker 文件传输加速器），SSH/DeviceTasks 在 Android 无对应实现。另 6 个模块不属于原有 7 个映射
> （`:platform` 承载 SPI、`:platform-android` 承载 SPI 的 Android 实现、`:domain` 承载设备能力契约
> 与手机权限读数、`:lib` 是可发布 AAR、`:app` 是 probe-app、`:lib-consumer-test` 以发布坐标
> `com.phonedsh:lib:0.1.0` 消费 AAR）。`:domain` 的 **DomainStore 已删除**（2026-11-01：
> 1,019 行零生产消费者，它要服务的 session/memory/task 持久化在 Android 上尚未实现；`:dsh` 已有
> `HostStateStore` 与 `JournalStore` 两条写路径，留着它只会让下一个人以为 P6 已交付。
> **104,603 行 Kotlin 主代码 + 49,261 行单测 + 9,660 行 instrumented**（`wc -l`，**快照 2026-11-01
> 20:45 工作树**；命令见「门禁与数字」#12–#14，合并前树若再变按同一条命令重跑）。
> `bash android/tools/run-demo.sh` 一条命令完成 AVD→构建→装包→启动→抓 logcat→截图；
> `bash android/tools/inject-renderer-death.sh` 验证 renderer 被杀后重建恢复。
> 证据等级逐条标注在 `TonoWiki/briefs/2026-10-31-pdsh-android-full-port-plan.md`。

本文的每个数字都来自本文「门禁与数字」一节列出的那条命令；**没有跑过的数字写「未测量」**，
不从别的报告里转抄。

## 工具链引导（当前可写 HOME/XDG，不写共享机器目录）

本树不把 JDK/SDK 预装进 `PATH`、共享 SDK 目录或其它机器级位置，也**不再**使用
checkout 父目录下的 `task-writable/`。`android/tools/bootstrap-android-toolchain.sh`
把 **JDK 17（java 与 javac 同为 17）**、Android SDK **platform 35 / build-tools 35.0.0 /
platform-tools / cmdline-tools** 和 **Gradle 8.13** 的官方归档装到当前可写的
`$XDG_CACHE_HOME/pdsh/android`（未设置时 `$HOME/toolchains/pdsh-android`）；
`PDSH_TOOLCHAIN_DIR`、`ANDROID_HOME`、`JAVA_HOME` 已设置时按脚本打印的解析结果复用，
已有只读工具不会被修改。下载走固定版本 + 校验和 + 有限连接/下载超时，失败时打印完整命令与退出码。

安装与校验是两条独立命令：

```bash
# 1) 安装/修复（幂等；非交互接受 SDK licence；所有安装器 stdout/stderr 都打印）
bash android/tools/bootstrap-android-toolchain.sh

# 2) 只校验：不下载、不安装包、不写 local.properties；java/javac 必须同为 17，
#    sdkmanager 必须能列出三个包，committed wrapper 必须固定 Gradle 8.13 + SHA-256
bash android/tools/bootstrap-android-toolchain.sh --check

# 3) 每条隔离的 Gradle 命令都通过 wrapper 重新解析自己的环境（不假设别的 worker
#    的 local.properties / HOME / Gradle 缓存可见）；它设置可写的
#    GRADLE_USER_HOME 与 Robolectric 需要的 JAVA_TOOL_OPTIONS=-Duser.home=$HOME。
bash android/tools/with-android-toolchain.sh ./gradlew --version --no-daemon
```

wrapper 在 macOS 上使用调用者提供的 `JAVA_HOME`/`ANDROID_HOME` 同样工作；它只读
`local.properties` 的 `sdk.dir`（用 sed，不 source 不可信文件）。若必须手工导出：

```bash
PDSH_TOOLCHAIN_DIR="${PDSH_TOOLCHAIN_DIR:-${XDG_CACHE_HOME:+$XDG_CACHE_HOME/pdsh/android}}"
PDSH_TOOLCHAIN_DIR="${PDSH_TOOLCHAIN_DIR:-$HOME/toolchains/pdsh-android}"
export JAVA_HOME="$PDSH_TOOLCHAIN_DIR/jdk-17"
export ANDROID_HOME="$PDSH_TOOLCHAIN_DIR/android-sdk"
export GRADLE_USER_HOME="${XDG_CACHE_HOME:-$HOME}/pdsh/gradle"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
```

结构门禁与工具单测（不联网、不需要 Gradle）：

```bash
python3 android/tools/structure_check.py --root .
python3 -m unittest discover -s android/tools -p 'test_*.py'
```

`bootstrap-android-toolchain.sh` 的可覆盖变量、固定版本/校验和、失败时的退出码/完整命令，
以及 `test_bootstrap_android_toolchain.py` 使用的假下载器，见
[`android/tools/README.md`](tools/README.md)。工具测试不再整文件豁免绝对路径检查：
fixture 用临时目录或拼接构造路径，只有嵌入的 shebang 行被跳过。

### Gradle 构建图：JVM 测试与打包输入

`:app` 过去在 configuration 阶段 `check` Worker bundle 与 Android `.so`，导致不相关的
`:app:testDebugUnitTest` / `:lib:testDebugUnitTest` 在缺少 NDK/Worker 镜像时连配置都失败。
现在校验移到真正的打包消费者：

- `:engine:packageWorkerBundle` 依赖 always-running `:engine:verifyWorkerBundle`，校验 Worker
  bundle 目录存在且 `index.html`/`boot.js`/`worker-entry.js`/`tool-worker-python.js`/`workflow-isolate.js`/
  `image.tar.gz` 均非空、`image.tar.gz` 为 gzip；空目录或空文件同样失败，任何消费该 asset 的 APK/asset merge 仍会失败。
- `:app:package<Variant>PdshJni` 在 task action 中检查 `libpdsh_jni.so` 存在、非空且为 ELF；
  debug/release/instrumented APK 打包仍会失败，纯 JVM 测试不会触发它。
- `:testkit` 只让 `merge*AndroidTest*` 依赖 Worker/scenario/JNI staging，不再挂到 `preBuild`；
  connected/instrumented 测试 APK 仍保留缺失输入时的失败。
- 不生成 dummy `.so`、不伪造 Worker asset、不跳过测试任务，也没有可发布空产物的开关。
  完整生产 APK（真实 Worker/JNI）仍由 Mac owner 在最终验收时构建。

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
├── settings.gradle.kts        # 13 个 Gradle 模块 + version catalog
├── build.gradle.kts           # 根 plugins（apply false）
├── gradle.properties          # AndroidX / R 类 / JVM 最小开关
├── gradle/libs.versions.toml  # AGP/Kotlin/Compose 占位 pin（全部 unverified）
├── lib/                       # 可发布 AAR：com.phonedsh:lib:0.0.0-SNAPSHOT
├── app/                       # probe-app（验证载具）
├── testkit/                   # scenario runner / UI 状态录制 / fault driver
├── platform/                  # SPI 接口（纯 JVM）：Durability/Clock/SecureStore/LifecycleSignals/EngineHost/Notifier
├── platform-android/          # 上述 SPI 的 Android 实现（Keystore/Os.fsync/Lifecycle）
├── domain/                    # 设备能力契约 + 手机权限读数（DomainStore 已于 2026-11-01 删除）
├── core/                      # wire + log + agentcore
├── net/                       # loopback + gateway
├── controller/ engine/ dsh/
├── shell/                     # JNI 薄包装 pdsh-ffi 的统一 C ABI：rg / jaq（见 shell/README.md）
├── lib-consumer-test/           # 以 com.phonedsh:lib:0.1.0 坐标消费发布 AAR 的消费者探针
└── tools/                     # bootstrap + structure_check.py + test-count.sh + unittest
```

## Swift 模块 → Kotlin 包 → Gradle 模块（16/16）

| Swift 模块（`Sources/`） | Kotlin 包 | Gradle 模块 | 状态 | 说明 |
| --- | --- | --- | --- | --- |
| PhoneDSHAgentCore | `com.phonedsh.agentcore` | `:core` | mapped | 合并进 `:core`；宿主语义底层 |
| PhoneDSHWire | `com.phonedsh.wire` | `:core` | mapped | 合并进 `:core`；纯字节/金标 |
| PhoneDSHLog | `com.phonedsh.log` | `:core` | mapped | 合并进 `:core` |
| PhoneDSHLoopback | `com.phonedsh.loopback` | `:net` | mapped | 合并进 `:net` |
| PhoneDSHGateway | `com.phonedsh.gateway` | `:net` | mapped | 合并进 `:net` |
| PhoneDSHController | `com.phonedsh.controller` | `:controller` | mapped | 包与模块结构对应，不表示 API 或行为完全一致 |
| PhoneDSHEngine | `com.phonedsh.engine` | `:engine` | mapped | 包与模块结构对应；包含 WebView / EngineHost |
| PhoneDSHShell | `com.phonedsh.shell` | `:shell` | mapped | 包与模块结构对应；包含 JNI 绑定 |
| PhoneDSH | `com.phonedsh.dsh` | `:dsh` | mapped | DSH 实现在子包；根包仅为 marker，不能据此声称门面完成 |
| PhoneDSHScenario | `com.phonedsh.testkit.scenario` | `:testkit` | mapped | 合并进 `:testkit` |
| PhoneDSHHarness | `com.phonedsh.testkit.harness` | `:testkit` | mapped | 合并进 `:testkit` |
| PhoneDSHADB | `com.phonedsh.adb` | `:net` | mapped | 合并进 `:net`；`/mcp/native` 的 26 个 android_* 工具、RSA 身份（SecureStore）、回执与设置页；无 Worker `adb push/pull/stat` 加速器（见 PC-20261108-android-adb-host） |
| PhoneDSHSSH | — | — | absent | Android 无对应实现 |
| PhoneDSHBLE | `com.phonedsh.domain.connector.ble` | `:domain` | target | 仅未接线的 Link 编解码与状态机；没有 GATT、授权或设备任务 |
| PhoneDSHLAN | `com.phonedsh.domain.connector.lan` | `:domain` | target | 仅未接线的 DNS-SD 候选解码；没有发现或连接 |
| PhoneDSHDeviceTasks | — | — | absent | Android 无对应实现 |

**合并规则**：`:core`（wire + log + agentcore）、`:net`（loopback + gateway）、`:testkit`
（scenario + harness）是 Gradle 构建边界的合并；包名对应仅表示结构映射，不表示 API 或行为已完全一致。
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

> **快照警告**：上表是 2026-10-31 的 `test-count.sh` 输出，2026-11-01 **未复跑**。当时 `:lib` 有
> **21** 个 `*Page.kt`，prepared baseline 是 **34** 个；所以 `:lib` 的 287 和合计 1,095 对应旧树，不能和「门禁与数字」
> #10 的 34 个页面混着引用。要更新测试数，先重跑 `./gradlew test --rerun-tasks --no-daemon --continue`，
> 再跑 `bash android/tools/test-count.sh`（陷阱 #7）。

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

## 门禁与数字（2026-10-31 实测；#10、#12–#14 于 2026-11-01 复测）

| # | 命令 | 结果 |
| --- | --- | --- |
| 1 | `python3 android/tools/structure_check.py --root .` | 14/14 项通过：13 个 include=磁盘、13/13 build 文件、13 个模块清单、34 个 `*Page.kt`（含 `ChatPage.kt`）、11 个 Swift 模块各映射一次、371 个生产 `.kt` 无占位、0 处绝对路径、`local.properties` 已忽略、8 个 `# unverified pin` |
| 2 | `python3 spec/v1/tools/spec_golden.py --full` | **73 个文件**，0 error |
| 3 | `python3 spec/v1/tools/gateway_check.py --root .` | **30 条向量**，0 error（credential-injection=3 header-strip=3 redirect-scope=8 egress-classification=5 response-redaction=7 failure-surface=4） |
| 4 | `python3 spec/platform/tools/platform_check.py --root .` | 8 个文件、**24 条白名单**、0 failure（classes: hardware-absent=1 os-forced=22 policy-forbidden=1） |
| 5 | `python3 spec/ui/v1/tools/ui_check.py --root .` | 5 个文件、13 组对比度、7 组 DEFER AA、**38 个 geometry token**、1 个未测量 token |
| 6 | `python3 spec/host/v1/tools/host_check.py --root .` | **41 个文件**，0 error |
| 7 | `bash android/tools/test-count.sh` | 11 个模块、**1,095 条测试**、0 failing（见上表） |
| 8 | `python3 -m unittest discover -s android/tools -p 'test_*.py'` | **19 条**，OK（0.5 s） |
| 9 | `grep -c 'include(":' android/settings.gradle.kts` | **13** |
| 10 | `ls android/lib/src/main/kotlin/com/phonedsh/ui/page/*Page.kt \| wc -l` | **34** 个页面（prepared PR22/PR14 baseline，结构门禁的下限） |
| 11 | `find shell/crates -name "*.rs" \| xargs wc -l \| tail -1` | **27,742** 行 Rust（`:shell` 依赖的加速器实现，见 `shell/README.md`） |
| 12 | `find android -path "*/src/main/*" -name "*.kt" \| xargs wc -l \| tail -1` | **104,603** 行 Kotlin 主代码（2026-11-01 20:45 工作树） |
| 13 | `find android -path "*/src/test/*" -name "*.kt" \| xargs wc -l \| tail -1` | **49,261** 行 JVM 单测（2026-11-01 20:45） |
| 14 | `find android -path "*/src/androidTest/*" -name "*.kt" \| xargs wc -l \| tail -1` | **9,660** 行 instrumented（2026-11-01） |

## 纪律

- `structure_check.py` 的 `kotlin-stubs` 检查只禁「占位代码」（`TODO()`、not-implemented 抛错），不禁止真实逻辑。
- 版本 pin 全部标 `# unverified pin`；本轮不联网校验，换成本机解析出的版本后才可去掉标注。
- 仓库只允许 `google()` 与 `mavenCentral()`；`local.properties` 只由 bootstrap 生成且必须保持 gitignored，不提交、不硬编码绝对路径。
- 测试数只认 `test-count.sh` 的输出；引数字前先确认那次 `./gradlew test` 是 `--rerun-tasks` 跑的
  （陷阱 #7）。
