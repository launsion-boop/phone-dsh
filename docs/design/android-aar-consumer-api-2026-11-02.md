<!-- SPDX-License-Identifier: MIT -->
# `:lib` 的 AAR：发布坐标、consumer API 与接入

日期：2026-11-02 · 车道：L66（给 `:lib` 补发布坐标，让 AAR 真的能被消费）
前身：L63（同一文件，当时的结论是「编译面成立，运行面不成立」）
状态：**编译面 + 运行面都成立**。`com.phonedsh:lib:0.1.0` 发布到 `android/build/repo`，
`android/lib-consumer-test` 只写一条坐标，`:lib-consumer-test:assembleRelease`（**R8 开**）通过。

> ## 边界（先读这一句，再看别的）
>
> **`com.phonedsh:lib:0.1.0` 是纯 UI 层**：它能渲染全部页面（`PdshNavHost` + `PdshTheme`）。
> **它不等于「能跑回合的宿主」。** 跑回合还要额外接三样东西——
> `:platform-android`（SPI 的 Android 实现）、`libpdsh_jni.so`（Rust 编解码）、
> 一个 `EngineHost` 实现（`:engine` 不发布）。
>
> 这三样**不在** 8 个构件里，也不该被期待会进来。把「一个坐标」说成「能跑 turn」
> 是本节要防的那种假承诺；详细的「给了什么 / 还要给什么」在 §3.3 / §3.4。

## 0. 一句话

L63 的 44 个缺失类不是 AAR 的 bug，是「没有发布坐标」的直接后果。
现在 8 个 `com.phonedsh:*` 构件有了 POM，consumer 写
`implementation("com.phonedsh:lib:0.1.0")` 一行，`:core`/`:domain` 的类随 `compile` scope 到达，
R8 通过。**对纯 UI 宿主**（也就是文首「边界」那块）来说，仍然要自己给的只有三样：
宿主 Activity、`PdshTheme`、返回链（库提供 `PdshBackLevel`，handler 见 §5 的可粘贴实现）；
要跑回合再按边界那段加三样。

## 1. 结论表

| 问题 | 结果 | 证据 |
| --- | --- | --- |
| 有发布坐标吗 | **有** | `com.phonedsh:lib:0.1.0`（以及 7 个兄弟），仓库 `android/build/repo` |
| 8 个构件都出得来吗 | **是** | AAR: lib/dsh/domain/controller/shell；JAR: core/net/platform |
| 别人能按坐标编译吗 | **能** | `:lib-consumer-test:assembleDebug`，依赖只有坐标 + `activity-compose` |
| **别人能按坐标过 R8 吗** | **能** | `:lib-consumer-test:assembleRelease` → `minifyReleaseWithR8` 通过，release APK 2,570,923 字节 |
| POM 带 `api` 边吗 | **带** | `lib-0.1.0.pom`：`dsh`/`platform`/`domain` 是 `compile`，`core-ktx` 是 `runtime`，Compose BOM 是 `<scope>import</scope>` |
| consumer 要依赖几个构件 | **1 个 `com.phonedsh`** | 另外要 1 个 `androidx.activity:activity-compose`（宿主 Activity） |
| `PdshTheme` 要包吗 | **必须** | 漏了编译过、第一个路由渲染即崩（§4） |
| `PdshBackHandler` 在 `:lib` 里吗 | **还不在** | 技术上能搬；本轮因 `android/lib/src/**` 由 L64 在写而未搬。§5 的参考实现已经放进探针（`BackHandler.kt`）随 `assembleRelease` 编译 + 过 R8，所以文档里的代码不是散文 |
| 裸 AAR 的 44 个缺失类 | **已消失** | `domain` AAR 有 138 个 `domain.connector`/`domain.device` 类，`core` JAR 有 `agentcore.JsonValue`/`JsonArray`/`JsonObject` |

L63 的结论「编译面成立，运行面不成立」只对**裸 AAR 文件**成立。发布坐标把这个洞补上了，
但补的方式是 POM，不是 AAR 变胖：`classes.jar` 仍是 1,576 个类，全在 `com.phonedsh.ui.*`。

## 2. 发布坐标怎么配

### 2.1 仓库在哪，为什么

**`android/build/repo`**（`android/build.gradle.kts` 的 `localRepositoryDir`），
声明在 `android/settings.gradle.kts` 的 `dependencyResolutionManagement.repositories` 里，
仓库名 `pdshLocal`，带 `content { includeGroup("com.phonedsh") }`，所以 Gradle 不会拿这个
目录去问 androidx/google 的构件。

不用 `~/.m2`（`mavenLocal()`）的原因，按重要性排：

1. **它是这个 checkout 的构建产物**，被根 `.gitignore` 的 `build/` 覆盖
   （`git check-ignore -v android/build/repo/...` → `android/.gitignore:3:build/`），
   所以 CI 每次从零开始，不可能解析到上一轮的残留；
2. **机器上别的项目的 `0.1.0` 不可能命中**——`~/.m2` 是全局的，两个项目都发 `0.1.0` 时
   谁赢取决于时间戳，那是很难查的一类「本机过、CI 红」；
3. **不写用户 home、不联网**，一个 `./gradlew publishLocalRepository` 就是全部；
4. 本地 file 仓库只能用 `maven { url = ... }` 声明，而本树的仓库策略白名单只放
   `google()`/`mavenCentral()`（§8.2）。in-tree 路径是这条策略能接受的最小扩张：
   它不是网络依赖，是构建产物。

代价：`./gradlew clean` 会连仓库一起删掉（`build/` 是 root 的 build dir）。
这是特性不是缺陷——发布是幂等的，consumer 的构建已经挂了 producer 边（§3.2 末尾）。

### 2.2 8 个构件

| 坐标 | 打包 | POM `compile`（`api`） | POM `runtime`（`implementation`） |
| --- | --- | --- | --- |
| `com.phonedsh:lib:0.1.0` | aar | `dsh` `platform` `domain`；compose `ui`/`foundation`/`ui-text`/`animation`/`material3`；`kotlin-stdlib` | `core-ktx`、`ui-tooling-preview` |
| `com.phonedsh:dsh:0.1.0` | aar | `platform` `core` `net` `controller` `shell` | `core-ktx`、`work-runtime` |
| `com.phonedsh:domain:0.1.0` | aar | `platform` | — |
| `com.phonedsh:controller:0.1.0` | aar | `core` `net` `platform` | — |
| `com.phonedsh:shell:0.1.0` | aar | `core` `platform` | — |
| `com.phonedsh:core:0.1.0` | jar | `platform`、`kotlinx-coroutines-core` | — |
| `com.phonedsh:net:0.1.0` | jar | `core` `platform` | Ktor `server-core`/`cio`/`websockets` |
| `com.phonedsh:platform:0.1.0` | jar | `kotlinx-coroutines-core` | — |

**不发布的**：`:app`（宿主）、`:engine`（WebView 引擎）、`:testkit`（设备测试）、
`:platform-android`（SPI 的 Android 实现）。理由见 §3.4。

发布面是 `:lib` 的 `api` 闭包：`:lib --api--> :dsh --api--> :platform/:core/:net/:controller/:shell`，
加上 `:lib --api--> :platform/:domain`。8 个就是闭包的全部。

### 2.3 版本：0.1.0，不是 `0.0.0-SNAPSHOT`

`android/build.gradle.kts` 的 `pdshVersion = "0.1.0"` 是唯一来源（`subprojects { version = pdshVersion }`），
`:lib/build.gradle.kts` 又显式钉了一次 `version = "0.1.0"`，因为它的坐标是公开入口，
读那一个文件就该看到发布出去的号。这个号与 `android/app/build.gradle.kts` 的
`versionName = "0.1.0"` 一致：**consumer 钉的 0.1.0 就是 app 0.1.0 所构建的那份代码**。

不用 SNAPSHOT 的具体理由：Gradle 对「changing module」（`-SNAPSHOT`）的默认缓存是 24 小时，
本地 file 仓库没有 snapshot 时间戳元数据可用来判断新旧，所以重新发布一个 SNAPSHOT
之后，consumer 可能一整天仍用缓存里那份旧的——症状是「我明明修了，它还是红的」。
`0.1.0` 是不可变坐标，重新发布时 `publish` 会覆盖同名文件，Gradle 用文件哈希判断变化。

### 2.4 怎么发布

```bash
cd android
./gradlew publishLocalRepository                          # 8 个全发（root 聚合任务）
./gradlew :lib:publishAllPublicationsToLocalRepository    # 只发 :lib
```

仓库布局是标准 Maven：`build/repo/com/phonedsh/<artifact>/0.1.0/<artifact>-0.1.0.{aar,jar,pom,module}`。
同时产出 `.module`（Gradle Module Metadata）：**Gradle consumer 优先读它**，
POM 是给 Maven/非 Gradle consumer 的降级路径。两份都验证过。

### 2.5 POM 里到底是什么（实测节选）

```xml
<groupId>com.phonedsh</groupId>
<artifactId>lib</artifactId>
<version>0.1.0</version>
<packaging>aar</packaging>
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>androidx.compose</groupId><artifactId>compose-bom</artifactId>
      <version>2025.01.00</version><type>pom</type><scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
<dependencies>
  <dependency><groupId>com.phonedsh</groupId><artifactId>dsh</artifactId>
    <version>0.1.0</version><scope>compile</scope></dependency>
  <dependency><groupId>com.phonedsh</groupId><artifactId>domain</artifactId>
    <version>0.1.0</version><scope>compile</scope></dependency>
  <dependency><groupId>com.phonedsh</groupId><artifactId>platform</artifactId>
    <version>0.1.0</version><scope>compile</scope></dependency>
  <dependency><groupId>androidx.compose.ui</groupId><artifactId>ui</artifactId>
    <scope>compile</scope></dependency>   <!-- 无 version：BOM 拥有它 -->
  <dependency><groupId>androidx.core</groupId><artifactId>core-ktx</artifactId>
    <version>1.15.0</version><scope>runtime</scope></dependency>
</dependencies>
```

三件事在这里同时被证明：

- **`api` → `compile`，`implementation` → `runtime`。** `core-ktx` 是 `implementation`，
  它在 consumer 的编译面之外、运行面之内——L63 §4.2 手给清单里唯一「本来就对」的那条。
- **`androidx.compose.*` 不带 version 也能解析**：BOM 以 `<scope>import</scope>` 进
  `dependencyManagement`。这是「手写 POM」方案里最容易坏掉的一条。
- `:lib` 自己的 `classes.jar` 不含 `:dsh`/`:core`/`:domain` 的任何类。运行时靠上表的
  `compile` 边把 8 个构件全拉进来。

### 2.6 三个实现上的坑（给维护者）

1. **`from(components["release"])` 必须写在模块自己的脚本里、并且包在 `afterEvaluate {}` 内。**
   AGP 在 variant API 里创建 `release` 软件组件，时机晚于任何能在 root 脚本里注册的
   `afterEvaluate`——直接写会得到 `SoftwareComponent with name 'release' not found`。
   反过来，把它推迟到 `gradle.projectsEvaluated` 又太晚：`publishAllPublicationsTo<Repo>Repository`
   已经解析完（结果是一个什么都不发的 UP-TO-DATE 任务），只补 `from()` 则
   `generateMetadataFileForReleasePublication` 不在图里，publish 报
   `artifact file does not exist: .../module.json`。两种都实测过。最终形态：
   **publication 在模块脚本里 `create`，`from` 在 `afterEvaluate`**；仓库与 POM 元数据在 root
   的 `plugins.withId("maven-publish")` 里用 `publications.withType<MavenPublication>().configureEach`
   统一配置（活集合，晚创建的 publication 也吃得到）。
2. **`:lib` 声明了 `android { publishing { singleVariant("release") } }`**，不要别的变体。
   顺带这也是 `-sources` jar 的开关：不加 `withSourcesJar()` 就不产 sources。为什么在意——
   `:lib` 的 token codegen 目录同时进了 kotlin 与 java 两个 source set，第一版 publish
   产出的 sources jar 是 248 条 entry / 78 条重复的坏包。宁可没有 sources，也不发坏包。
3. **JAR 模块用 `from(components["java"])`**，不需要 `afterEvaluate`（`java-library` 一应用
   组件就在）；AAR 模块用 `release`。

## 3. consumer 要写什么

### 3.1 仓库声明

外部工程在自己的 `settings.gradle.kts`：

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            name = "pdshLocal"
            // 指向发布仓库。换机器/换目录只改这一行。
            url = uri(rootDir.resolve("../phone-dsh/android/build/repo"))
            // 只有 com.phonedsh 会来这里找，androidx 不会被这个目录回答。
            content { includeGroup("com.phonedsh") }
        }
    }
}
```

这是本树 `:lib-consumer-test` 用的同一份声明（它在 `android/settings.gradle.kts` 里，
`url = uri(rootDir.resolve("build/repo"))`）。真正对外发布时把 `url` 换成远端仓库即可，
consumer 的依赖行不用改。

### 3.2 依赖：一条坐标 + 一条宿主依赖

```kotlin
dependencies {
    // 8 个 com.phonedsh 构件、Compose 运行时、Compose BOM 全从这一条的 POM 来。
    implementation("com.phonedsh:lib:0.1.0")

    // AAR 不能带 Activity。宿主自己提供 ComponentActivity + setContent。
    implementation("androidx.activity:activity-compose:1.9.3")
}
```

`android/lib-consumer-test/build.gradle.kts` 里现在就是这两行（`activity-compose` 通过
版本目录 `libs.androidx.activity.compose`）。**没有 `files(...)`，没有
`releaseImplementation(...)`，没有手写的 compose 清单。**

构建顺序：坐标是 Maven 依赖，没有 producer 边，所以探针模块加了
`tasks.named("preBuild") { dependsOn(":publishLocalRepository") }`。
真实 consumer 跑一次 `publishLocalRepository` 之后不需要这条边。

### 3.3 一条坐标带来什么（实测 `releaseCompileClasspath`）

```
+--- com.phonedsh:lib:0.1.0
|    +--- com.phonedsh:dsh:0.1.0
|    |    +--- com.phonedsh:platform:0.1.0
|    |    +--- com.phonedsh:core:0.1.0        (jar)
|    |    +--- com.phonedsh:net:0.1.0         (jar)
|    |    +--- com.phonedsh:controller:0.1.0  (aar)
|    |    +--- com.phonedsh:shell:0.1.0       (aar)
|    +--- com.phonedsh:platform:0.1.0
|    +--- com.phonedsh:domain:0.1.0           (aar)
|    +--- androidx.compose.ui:ui:1.7.6        ← 由 BOM 定版
|    +--- androidx.compose.foundation:foundation:1.7.6
|    +--- androidx.compose.material3:material3:1.3.1
|    +--- androidx.activity:activity-compose:1.9.3
```

**8 个全自动来，一个都不用自己加。**

### 3.4 consumer 仍然必须自己给的

| 要给的 | 为什么 | 不给会怎样 |
| --- | --- | --- |
| `androidx.activity:activity-compose` + 一个 `ComponentActivity` | AAR 是 Compose 面，不带 Activity | 没有东西能 `setContent` |
| Kotlin 2.1.0 + `org.jetbrains.kotlin.plugin.compose` | AAR 的 public 面是 composable；Kotlin 2.x 不装 Compose 插件编译不了 | `compileDebugKotlin` 直接失败 |
| `compileSdk 35`、`minSdk >= 26`、JVM target 17 | AAR manifest 的 `uses-sdk` 会在合并时拒绝更小的 minSdk | 合并失败或运行时 `NoSuchMethodError` |
| `PdshTheme { }` | §4 | **编译过，渲染崩** |
| 返回链（`PdshBackHandler` 或等价物） | §5 | 系统返回手势无响应 / 抢掉预测性返回动画 |
| `android:enableOnBackInvokedCallback="true"` | 预测性返回是**宿主** `<application>` 的选择，库不能替 consumer 声明 | 测量恒为 `NO`，系统走旧路径 |
| 可选：`:platform-android` | 不在 `:lib` 的 `api` 边上（没发布）。只有真要构造 `DefaultPhoneDshHost` 才需要它提供的 `Clock`/`LifecycleSignals`/`Notifier` | 纯 UI 宿主不需要；接引擎的宿主会缺 SPI 实现 |
| 可选：`libpdsh_jni.so` | 8 个构件里**没有任何一个**携带 native 库；`:shell` 只是 JNI 绑定面，`:app` 的 `PackagePdshJni` 负责拷 `.so` | 纯 UI 宿主不需要；一到 `WireCodec` 调用就 `UnsatisfiedLinkError` |
| 可选：`EngineHost` 实现 | `:engine`（WebView 引擎）不发布，`EngineHost` 是 `:platform` 的 SPI | 同上：接引擎才需要 |

一句话：**「UI 宿主」= 1 条坐标 + activity-compose；「能跑 turn 的宿主」还要 + `:platform-android`
+ `libpdsh_jni.so` + 一个 `EngineHost` 实现。** 后者不是一个 Maven 坐标能解决的，
本轮的探针也只证明了前者（§7.4）。

### 3.5 ⚠️ 传递 manifest 合并：UI 宿主要继承 `:dsh` 的权限

因为 `:lib` 把 `:dsh` 声明为 `api`，`:dsh` 的 AAR manifest 会合并进 consumer 的 manifest。
`:lib-consumer-test` 的 release APK 实测（`aapt2 dump badging` / `dump xmltree`）：

- `androidx.core.content.FileProvider`（authority `${applicationId}.pdsh.preview`）—
  **来自 `:lib` 自己的 manifest，必需**，预览分享要用；
- `androidx.startup.InitializationProvider` — 来自 `:dsh` → WorkManager；
- 7 个权限：`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`RUN_USER_INITIATED_JOBS`、
  `WAKE_LOCK`、`POST_NOTIFICATIONS`、`RECEIVE_BOOT_COMPLETED`、`ACCESS_NETWORK_STATE`。

**已知限制（登记，未修）**：一个纯 UI 宿主就这样继承了「后台任务 + 通知」的权限面。
这是 `:lib` 的依赖图决定的，不是 POM 能修的，也不是合并出错。短期处置：在 consumer
manifest 上用 `tools:node="remove"` 去掉确实不用的权限——先量再删，别把 FileProvider
也顺手删了。

**拆它需要什么（重要，别按直觉改 scope）**：

- **把 `api(":dsh")` 改成 `implementation(":dsh")` 修不了这件事。** manifest 合并看的是
  **runtime classpath**，`implementation` 依赖照样在上面，`:dsh` 的权限照样进来。
  能改的是编译面，不是权限面。
- 真正要做的只有一条：**把 `:dsh` 从 `:lib` 的依赖里拿掉**，让宿主自己声明
  `implementation("com.phonedsh:dsh:0.1.0")`。实测依据：`:lib/src/main` 里
  `import com.phonedsh.dsh.*` **0 处**（`:lib` 只 import `com.phonedsh.agentcore.*` 与
  `com.phonedsh.domain.*`），所以拿掉不需要改 `:lib` 的任何代码；`:dsh` 在 `:lib` 上纯粹是
  facade 再导出。
- 代价是 API 语义变更：今天「只写一条坐标就顺带拿到 facade」这件事会消失，宿主必须自己加
  `:dsh`。`:app` 不受影响——它本来就有 `implementation(project(":dsh"))`。
- 验证成本：一轮 `:lib` + `:app` + 探针三方的编译/R8 对比，外加消费者清单变化。所以是
  单独一轮，不是顺手改（§9.3）。

## 4. `PdshTheme`：必须包住

**这是硬要求，不是装饰。**

- `PdshTheme` 是 public：`android/lib/src/main/kotlin/com/phonedsh/ui/theme/UiTheme.kt:104`，
  签名 `PdshTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit)`。
- 它提供的两个 CompositionLocal 默认值都是抛异常：
  `UiTheme.kt:90` → `compositionLocalOf { error("PdshTheme is missing: no UiTokens in the composition") }`，
  `UiTheme.kt:94` 同款（`UiType`）。
- 所以：**不包它，`assembleDebug`/`assembleRelease` 都过，第一个路由一渲染就
  `IllegalStateException: PdshTheme is missing: no UiTokens in the composition`。**
  这就是 L63 报的「编译过、渲染即崩」的准确机制。
- 位置：必须在 `setContent { }` 里面（它用 `CompositionLocalProvider` + `remember`），
  并且包住 `PdshNavHost`。库刻意不自己包——深浅色是宿主自己的决定；宿主也可以
  `PdshTheme(darkTheme = myDarkFlag) { ... }` 把自己的 chrome 和 SDK 对齐。
- 它同时是 token 的读入口：`PdshThemeValues.tokens` / `PdshThemeValues.type`
  只在 `PdshTheme` 内有效。

`android/lib-consumer-test/src/main/kotlin/com/phonedsh/consumer/ProbeConsumer.kt` 里，
`PdshTheme { ... }` 是整个 SDK 面的最外层——照抄这一层就不会踩。

## 5. `PdshBackHandler`：本轮还没搬，先给可粘贴实现

### 5.1 判据与结论

`:app` 里那份：`android/app/src/main/kotlin/com/phonedsh/probe/BackNavigation.kt:63`，
`internal fun PdshBackHandler(enabled: Boolean, onBack: () -> Unit)`。

逐行读了它的依赖：

| 它用什么 | 在哪 | 能进 `:lib` 吗 |
| --- | --- | --- |
| `LocalOnBackPressedDispatcherOwner` / `OnBackPressedCallback` / `BackEventCompat` | `androidx.activity` / `activity-compose` | 能；`PdshNavHost` 本来就要求宿主在 `OnBackPressedDispatcherOwner` 里 |
| `PdshNavFacts` / `FactState` / `SettingsPlatformFacts` | `:lib`（`com.phonedsh.ui.*`） | 能，已经在同一个模块里 |
| `android.os.Build` / `android.util.Log` | 平台 | 能 |
| `Activity` / `OnBackInvokedDispatcher` | —— | **没用到**（`BackEventCompat` 是 androidx 的兼容层，不是平台 API） |
| `MANIFEST_DECLARES_BACK_INVOKED` | `:app` 的 manifest | 不能原样搬：`android:enableOnBackInvokedCallback` 是**宿主**的 `<application>` 属性 |

**搬它要加依赖，而且 `:lib` 现在完全没有这条依赖（已查清）**：

- `android/lib/build.gradle.kts` 里没有任何 `androidx.activity` 依赖，`lib/src/main` 里
  `androidx.activity` 的 import 是 **0 处**，已发布的 `lib-0.1.0.pom` 里也没有它。
  也就是说：**今天 consumer 的 `activity-compose` 是宿主自己声明的那一行**（§3.2），
  不是 `:lib` 带来的。
- 搬 handler 时必须在 `:lib` 加一条依赖，但**该用 `implementation`，不是 `api`**：
  `PdshBackHandler` 的 public 签名是 `(Boolean, () -> Unit) -> Unit`，**没有任何 activity 类型**；
  运行时它只需要宿主的 `OnBackPressedDispatcher`（`LocalOnBackPressedDispatcherOwner` 由宿主
  composition 提供，取不到就 `?: return` 静默退出）。所以 **runtime scope 就够**，
  编译面完全不用动——**不会出现「搬完之后每个 consumer 多一个必填 compile 依赖」**。
- 如果写成 `api(libs.androidx.activity.compose)`，后果是可量化的：`activity-compose:1.9.3`
  → `activity-ktx` → `activity` → `core` / `lifecycle-runtime` / `savedstate` /
  `versionedparcelable` 全部进入每个 consumer 的 **compile** 面。这些包在运行时本来就存在
  （宿主有 `ComponentActivity`），但把「宿主的决定」变成「库的决定」，版本也被库钉死。
  **所以：`implementation`，除非将来把 dispatcher 本身暴露进 public 签名（不建议）。**

**结论：技术上能搬，而且应该搬。** 它做的是「一条返回链 + 预测性返回的测量与分发」，
每个 consumer 都要重写一遍，重写时最容易写错的两件事（根路由注册回调、闭包读到旧的 nav）
都在这一段里。

**本轮没搬的原因不是技术，是排期**：本车道禁止写 `android/lib/src/**`（UI 车道 L64 正在该目录
作业），而本轮实测到 L64 有 3 个未提交改动
（`SettingsMetrics.kt` / `SettingsPage.kt` / `SettingsChrome.kt`）并让 `:lib` 编译红过一次。
两条车道同时改 `:lib` 会互相拖。搬的时机与做法见 §5.4。

### 5.2 参考实现（可粘贴，`internal` 就够）

这段已经以 `android/lib-consumer-test/src/main/kotlin/com/phonedsh/consumer/BackHandler.kt`
（`observingBackLayer` + 测量）与同目录 `ProbeConsumer.kt`（`BackCoordinator` 调用）的形式
**编译并过了 R8**（探针的 `assembleRelease` 会跑到它），所以下面不是未验证的散文。
放进你自己的应用时照抄、把包名换掉即可（`:app` 现在用的是同一份逻辑）。

**三层缺一不可**：`BackCoordinator` 注册唯一的平台回调；`observingBackLayer` 把路由内部那一级
包成 `PushBackLayer`；`PredictiveBack` 记录手势并回填设置页的「返回手势」行。只抄 coordinator
会得到一个「会动但没有测量」的版本——那一行会永远显示未知。

```kotlin
package com.example.host

import android.os.Build
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PushBackLayer
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.SettingsPlatformFacts
import com.phonedsh.ui.theme.generated.TokenBackLayer

/**
 * Wraps one [PushBackLayer] so the coordinator's gesture callbacks also feed
 * [PredictiveBack].
 *
 * [BackCoordinator] calls `onPredictiveBack*` only on the topmost present layer's
 * delegate, which is exactly the gesture the person performed; the delegate stays
 * the only consumer of the back. A gesture at the root registers no callback at
 * all, and no observation is claimed for it.
 */
internal fun observingBackLayer(
    layer: TokenBackLayer,
    onConsume: () -> Boolean,
): PushBackLayer = object : PushBackLayer {
    override val layer: TokenBackLayer = layer

    override fun consumeBack(): Boolean = onConsume()

    override fun onPredictiveBackStarted() {
        PredictiveBack.observeStarted(0f)
    }

    override fun onPredictiveBackProgressed(progress: Float) {
        PredictiveBack.observeProgressed(progress)
    }

    override fun onPredictiveBackCancelled() {
        PredictiveBack.observeCancelled()
    }
}

/** What this process has observed about the platform's back path. */
internal object PredictiveBack {
    private val started = mutableStateOf(false)      // composition-visible: the row moves on the first gesture
    private var maxProgress by mutableFloatStateOf(0f)

    val observedOnThisDevice: Boolean get() = started.value

    fun observeStarted(progress: Float) {
        maxProgress = maxOf(maxProgress, progress)
        if (!started.value) {
            started.value = true
            Log.i("PDSHNav", "predictive back: OnBackStarted (API ${Build.VERSION.SDK_INT})")
        }
    }

    fun observeProgressed(progress: Float) { maxProgress = maxOf(maxProgress, progress) }
    fun observeCancelled() { Log.i("PDSHNav", "predictive back: cancelled at progress=$maxProgress") }
}

/**
 * The 返回手势 row's value from three readings rather than one constant.
 * `declared` is the host's own manifest opt-in — read it from a unit test that
 * parses YOUR manifest, because the platform exposes no public getter.
 */
internal fun predictiveBackFact(
    sdkInt: Int = Build.VERSION.SDK_INT,
    declared: Boolean = MANIFEST_DECLARES_BACK_INVOKED,
    observed: Boolean = PredictiveBack.observedOnThisDevice,
): FactState = when {
    !declared -> FactState.NO
    sdkInt < Build.VERSION_CODES.TIRAMISU -> FactState.NO
    observed -> FactState.YES
    sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> FactState.UNKNOWN
    else -> FactState.YES          // API 33 cannot send BackEvent; declaration + invoker is the whole reading
}

/** Re-reads the one runtime-dependent fact the settings sheet shows. */
@Composable
internal fun PredictiveBack.measured(facts: PdshNavFacts): PdshNavFacts {
    val observed = observedOnThisDevice                 // composition-observed read: this is what moves the row
    val fact = predictiveBackFact(observed = observed)
    val platform = facts.settings.platform ?: SettingsPlatformFacts()
    if (platform.predictiveBack == fact) return facts
    return facts.copy(settings = facts.settings.copy(platform = platform.copy(predictiveBack = fact)))
}

/** The manifest's opt-in, as a constant because the platform has no public getter. */
internal const val MANIFEST_DECLARES_BACK_INVOKED: Boolean = true
```

The measurement half above is the whole of `BackHandler.kt`. The host's only
platform back callback is the library coordinator; `ProbeConsumer.kt` calls it
inside the host composable (this excerpt also imports
`androidx.compose.runtime.remember` and
`com.phonedsh.ui.nav.{BackCoordinator, PdshBackLevel, PushBackState}`):

```kotlin
var pushBack by remember { mutableStateOf(PushBackState()) }
val backLevel = remember { PdshBackLevel() }
val stackBackLayer = remember(backLevel) {
    observingBackLayer(TokenBackLayer.STACK) { backLevel.consume() }
}
BackCoordinator(
    state = pushBack,
    onStateChange = { next ->
        // The real consumer also pops `nav.stack` to `next.depth`.
        pushBack = next
    },
    layers = remember(stackBackLayer) { listOf(stackBackLayer) },
)
```

At the root no registered layer can consume and no `onExit` is supplied, so
`BackCoordinator` registers nothing: the platform's default `finish()` and the
predictive back-to-home animation stay in charge. That is the documented
"back at the start of the task" behaviour, and the reason a second handler must
not exist anywhere else.

宿主 manifest 必须有这一行（否则测量永远是 `NO`，而且系统走旧路径）：

```xml
<application
    android:enableOnBackInvokedCallback="true"
    ... >
```

配一个把常量钉回文件的单测（`:app` 的 `BackNavigationManifestTest` 就是模板）：
读 `src/main/AndroidManifest.xml`，断言 `<application>` 上确实带着
`android:enableOnBackInvokedCallback="true"`。没有这条测试，常量会慢慢变成谎言。

### 5.3 三个必须写对的点

1. **根路由不注册。** `enabled = backLevel.available || nav.canGoBack`（有抽屉/浮层再加进去）。
   根页面 `enabled = false` → 回调根本没注册 → 平台默认 `finish()` + 预测性返回动画接管。
2. **顺序只有一处**：`抽屉开着 → 关抽屉` → `backLevel.available → consume()` → `nav.pop()`。
   别的地方不要再 `BackHandler`，否则同一个手势有两个消费者。
3. **`rememberUpdatedState(onBack)`**：`nav` 每次手势都变，回调却只在 `enabled` 变化时重注册；
   直接闭包会读到旧 state。

### 5.4 搬到 `:lib` 的确切做法

将来由 `:lib` 的 owner 执行，三步：

1. 新文件 `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PdshBackHandler.kt`，把 §5.2 的
   四段放进去，`internal` 全部改成 `public`（`PdshBackHandler`、`PdshPredictiveBack`、
   `pdshPredictiveBackFact`、`PdshNavFacts.withMeasuredPredictiveBack`）；
2. `android/lib/build.gradle.kts` 加 **`implementation(libs.androidx.activity.compose)`**
   （不是 `api`，理由见 §5.1 末：public 签名里没有 activity 类型，runtime scope 就够，
   编译面不该被库改写）；
3. 删掉 `android/app/src/main/kotlin/com/phonedsh/probe/BackNavigation.kt` 里搬走的部分，
   `:app` 改用 `com.phonedsh.ui.nav.*`（`:app` 的 manifest 常量与 manifest 测试留在 `:app`）。
   `MANIFEST_DECLARES_BACK_INVOKED` 不进库：哪份 manifest 是宿主的事，库只接受 `declared`
   参数。

判断依据（给下一个读这段的人）：**「consumer 每个都要重写一遍」+「不依赖宿主类型」= 进 `:lib`。**
这条满足；`PdshTheme` 也满足（已经在库里）。

## 6. 最小可运行接入（不是「只有编译通过」的那种）

两个文件 + 一条 manifest 属性。与 `android/lib-consumer-test` 里已跑通的内容一一对应
（那边分成 `ConsumerActivity.kt` + `ProbeConsumer.kt`，这里合成一个文件方便粘贴）。

```xml
<!-- AndroidManifest.xml（节选） -->
<application android:enableOnBackInvokedCallback="true" ...>
    <activity android:name=".MainActivity" android:exported="true">
        <intent-filter>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent-filter>
    </activity>
</application>
```

```kotlin
// MainActivity.kt
package com.example.host

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.phonedsh.ui.nav.PdshBackLevel
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.theme.PdshTheme
// + §5.2 的 PdshBackHandler / PredictiveBack / predictiveBackFact / measured / 常量

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { HostApp() }
    }
}

@Composable
private fun HostApp() {
    // 1) 必须：不包它，第一个路由渲染就崩（§4）。
    PdshTheme {
        var nav by remember { mutableStateOf(PdshNavState()) }
        // 2) 全"未知"快照：每个字段默认就是诚实的 未知/EMPTY，不是 0。
        //    宿主真读了新值，facts 才会变——不要伪造成功。
        var facts by remember { mutableStateOf(PdshNavFacts()) }
        val backLevel = remember { PdshBackLevel() }

        // 3) 一条返回链：抽屉(无) → 路由内部那一级 → 路由栈；根页面不注册（§5.3）。
        PdshBackHandler(enabled = backLevel.available || nav.canGoBack) {
            if (!backLevel.consume()) nav = nav.pop()
        }

        // 4) 把本进程观测到的 返回手势 读数回填给设置页（§5.2 的 measured）。
        //    不改 facts 本身：measured 是纯投影，每次重组按当前观测重算一遍。
        val shownFacts = PredictiveBack.measured(facts)

        PdshNavHost(
            nav = nav,
            facts = shownFacts,
            onNavigate = { route -> nav = nav.push(route) },
            onBack = { nav = nav.pop() },
            onHome = { nav = nav.popToHome() },
            // 宿主没实现的手势：留空是诚实，不是偷懒。页面会显示"宿主未实现"，
            // 而不是假装写成功。
            onHostAction = { },
            // 5) 路由内部那一级返回：设置子页/文件夹下钻靠它，不传就丢一级。
            backLevel = backLevel,
            home = { HostHome(onOpenSessions = { nav = nav.push(PdshRoute.Sessions) }) },
            // 宿主自己的 WebView 槽位；这里给降级面，真宿主换成自己的 WebView。
            webSurface = { Text("the host owns the WebView") },
        )
    }
}

@Composable
private fun HostHome(onOpenSessions: () -> Unit) {
    Column(modifier = Modifier.fillMaxSize()) {
        Text("host home")
        Button(onClick = onOpenSessions) { Text("Sessions") }
    }
}
```

这段与探针的差别只有一处：探针的 `facts` 是 `remember { PdshNavFacts() }`（没有引擎，
所以没有真实的引擎读数可喂），其余——`PdshTheme` 包层、`PdshNavState`、
`PdshBackHandler` + `PdshBackLevel`、`PredictiveBack.measured` 回填、两个 slot composable
——**逐行相同**。探针的 `assembleDebug`/`assembleRelease` 都过了，manifest 里也写了
`android:enableOnBackInvokedCallback="true"`。

## 7. R8、consumer-rules，与探针到底证明了什么

### 7.1 44 个缺失类怎么没的

L63 在裸 AAR 上量到 44 条 `Missing class`：`agentcore` 7 条（canonical JSON）、
`domain.connector` 30 条、`domain.device` 7 条。现在：

- `com.phonedsh:core:0.1.0.jar` 含 `com/phonedsh/agentcore/JsonValue.class`、`JsonArray`、`JsonObject`…；
- `com.phonedsh:domain:0.1.0.aar` 的 `classes.jar` 含 **138** 个
  `com/phonedsh/domain/{connector,device}/*.class`；
- 两者都在 `:lib` POM 的 `compile` scope 上，所以 R8 的输入里有它们。

R8 通过不是「规则放行了」，是「类真的到了」。

### 7.2 consumer-rules 仍然在

`android/lib/src/main/consumer-rules.pro` 随 AAR 下发为 `proguard.txt`，
`-keepclasseswithmembernames class com.phonedsh.wire.NativeWire` 等 JNI 规则仍在；
探针 release 的 `build/outputs/mapping/release/configuration.txt` 里能看到它被 AGP 读进 R8 配置。
探针自己的 `proguard-rules.pro` 是空的（只有注释）：**没有一条规则是为了保住 SDK 的类而加的。**

### 7.3 为什么 release 2.5 MB、debug 14.4 MB

| APK | 字节 | 说明 |
| --- | --- | --- |
| debug | 19,820,783 | 全闭包未裁剪：`dsh` + WorkManager + Ktor(`net`) + coroutines + `domain`/`controller`/`shell` |
| release | 2,570,923 | R8 裁掉**探针从未到达**的部分 |

探针是纯 UI 宿主：它渲染 `PdshNavHost`，但从不构造引擎，所以 `:dsh`/`:shell`/`:net`(Ktor)/
WorkManager 一律不可达、被整段裁掉——这是 R8 的正确行为，不是「必要东西丢了」。证据：

- `mapping.txt` 里 `PdshNavHostKt` / `PdshNavFacts` / `PdshNavState` **都在**（被改名成 `P1.o0` 等）；
- `usage.txt` 里删掉的是探针没调用的成员（`PdshNavFacts.copy`、`PdshNavState.replaceTop`）；
- 真正用引擎的宿主里这些类可达，会保留。

APK 里那 4 个 `libandroidx.graphics.path.so` 来自 Compose（`androidx.graphics`），不是 SDK 的产物；
8 个构件**都不带 native 库**（§3.4）。

### 7.4 探针的边界（重要，别过度解读）

探针证明了：**坐标能解析、public 面能编译、R8 在完整闭包下能过、AAR 的 manifest 能合。**
它**没有**证明：引擎那条路（`libpdsh_jni.so` + worker bundle + `EngineHost` + `:platform-android`）
能跑。那条路需要一个会构造引擎的探针，本轮不在范围内——所以 §3.4 的「可选」三件不是装饰。

## 8. 门禁

### 8.1 `phone-android-release`（本车道扩了这一段的断言）

现在跑：

```bash
./gradlew :publishLocalRepository :lib-consumer-test:assembleDebug :lib-consumer-test:assembleRelease
```

然后断言（任一失败 = FAIL，不是 SKIP）：

1. 仓库里 8 个构件齐全：5 个 `.aar` + 3 个 `.jar` + 8 个 `.pom`；
2. `lib-0.1.0.pom` 的 `dsh`/`domain`/`platform` 是 `compile` scope（`api` 边到了）；
3. `dsh-0.1.0.pom` 的 `core`/`net`/`controller`/`shell`/`platform` 也是 `compile`；
4. `core-ktx` 是 `runtime` scope（`implementation` 没漏进编译面）；
5. Compose BOM 以 `<scope>import</scope>` 出现在 `dependencyManagement`；
6. 原有的 AAR 字节断言（5 个 consumer 入口 + `proguard.txt` 的 JNI 规则）+ consumer debug APK 存在；
   探针还会编译 §5.2 的返回链参考实现（`BackHandler.kt`），所以「文档里的接入代码能过 R8」
   也是这条 stage 在守；
7. 之后才是 APK 段（`.so` / worker bundle 缺就 SKIP，AAR+发布段永不 SKIP）。

第 2–5 条做过反向验证（把 POM 改坏，断言确实红）：

| 变异 | 结果 |
| --- | --- |
| `dsh` 的 scope `compile` → `runtime` | FAIL：`lib POM: com.phonedsh:dsh is runtime scope, not compile` |
| 删掉 BOM 的 `<scope>import</scope>` | FAIL：`lib POM: the Compose BOM is not imported` |
| 删掉 `shell-0.1.0.aar` | FAIL：`missing com/phonedsh/shell/0.1.0/shell-0.1.0.aar (aar)` |

实测一次通过，101 s（含 `:app:assembleRelease` 与 16 KB APK 证明）。

### 8.2 `phone-android-structure`

**本车道改了 `check_repositories` 的策略，方向是「收紧 + 一条窄例外」**，不是放开：

- 允许：一个 **in-tree 路径**的 `maven { }`——文件里必须同时出现 `build/repo` 和
  `url = uri(`（即路径而不是字符串 URL），只有 `android/settings.gradle.kts` 与
  `android/build.gradle.kts` 两处；
- 仍然拒绝：任何带 `://` 的行（包括 `file://` 与外部 `https://` 仓库）、
  `mavenLocal()`、`gradlePluginPortal()`、`jcenter()`、`flatDir { }`；
- 新增 3 条变异测试把两个方向都钉住：
  `test_in_tree_publish_repository_passes`、`test_external_maven_url_still_fails`
  （同一个文件里既有合法本地仓库、又有 `url = "https://evil.example.com/build/repo"` → 必须 FAIL）、
  `test_maven_local_next_to_in_tree_repository_fails`。

为什么必须有这条例外：`com.phonedsh:lib` 只能以坐标消费，而本地 file 仓库只能用
`maven { }` 声明；没有例外，这条检查会永久禁止「本树发布自己的构件」。

### 8.3 `phone-modules`

`scripts/ci/modules.py`（`Package.swift` 的 8 模块依赖图），与本车道的 Gradle 改动无关；
有 `Sources/PhoneDSHWire` 才跑，跑则不变。

## 9. Open questions

1. **`PdshBackHandler` 进 `:lib`。** 技术上成立（§5.1），卡在 `android/lib/src/**` 的并发所有权。
   待 L64 落盘后按 §5.4 搬，并把它变成 `:lib` public API 的一部分。
2. **`:platform-android` 要不要发布？** 现在不发布：它是 SPI 的 Android 实现，塞进 `:lib` 的
   `api` 边会污染纯 UI 宿主；但不发布，「一个坐标 = 能跑 turn 的宿主」就不成立。
   要么单独发一个 `com.phonedsh:platform-android`，要么在文档里永久保持「可选 + 手加」。
3. **`:lib` 的 `api(":dsh")` 带来 `:dsh` 的 manifest 合并**（7 个权限 + WorkManager provider，§3.5）。
   要不要把 facade 拆成独立坐标（`:lib` 只依赖 `:core`+`:domain`+`:platform`，
   宿主自己加 `:dsh`）？这会把「UI 宿主」的权限面收回到宿主手里，但也是 API 变更。
4. ~~`-Ppdsh.uiCoreOnly=true` 会用同一个坐标发布一个不同的闭包。~~
   **已修（本车道）**：`:lib` 的 `generatePomFileFor*` 与 `publish*` 任务在该 flag 为 true 时
   抛 `GradleException`，信息里点名缺的 5 个构件（dsh/controller/shell/net + 经 dsh 的 domain
   边）。实测：带 flag 跑 publish → `Task :lib:generatePomFileForReleasePublication FAILED`，
   且 `build/repo` 里的 POM 逐字节未变（守卫在写之前就失败）。flag 仍可用于
   `assembleDebug`/`test`——那才是它的用途。
5. **`:lib` 的 sources jar** 目前不发（§2.6 第 2 条：248 entry / 78 重复的坏包）。
   根因是 token codegen 目录同时进了 `kotlin` 和 `java` 两个 source set；修掉之后可以恢复
   `withSourcesJar()`。
6. **版本号有 4 处**：root `pdshVersion`、`:lib` 的 `version`、consumer 的
   `"com.phonedsh:lib:0.1.0"`、文档。想收成一处，得先解决「版本目录的每个 `[versions]` 条目
   都必须标 `# unverified pin`」这条门禁——一个**本树生产**的版本号不是 unverified pin。
7. **`PDSHShellPage` 仍是唯一 internal 的页面 composable**（L63 原报告）。走 `PdshRoute.Tools`
   没问题；要单页 API 才需要它 public。
8. **`PdshNavFacts` 没有 `unknown()` 工厂**（L63 原报告）。默认构造器就是「全未知」入口，
   别在文档里写 `PdshNavFacts.unknown()`。
9. **探针不覆盖引擎路径**（§7.4）。要证明「能跑 turn」，需要一个会构造 `EngineHost`、
   带 `.so` 与 worker bundle 的探针——那是下一条车道的量级。
