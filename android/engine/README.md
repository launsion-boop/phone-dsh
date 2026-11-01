<!-- SPDX-License-Identifier: MIT -->
# :engine — WebView 宿主（D2 车道）

`assets/worker-bundle.zip`（65 MB 预构建 worker）→ `filesDir/worker/` → `:net` loopback origin → 一个 WebView → 页面自建唯一 WebSocket → 帧原样交给 codec。`:app` 只依赖 `DemoEngine` + `createDemoEngine(...)`，不 import `WebViewEngine`/`android.webkit`。

## DemoEngine 签名（F5：直接实现 `:platform` 的 `EngineHost`）

```kotlin
// DemoEngine.kt —— 名字是 :platform SPI 的 alias，engine 不再重复声明这些类型
typealias EngineState = com.phonedsh.platform.EngineHostState
typealias ChannelStatus = com.phonedsh.platform.EngineChannelStatus
typealias HandshakeSummary = com.phonedsh.platform.EngineHandshake

interface DemoEngine : com.phonedsh.platform.EngineHost {  // state/channel/handshake/start/stop
    fun view(): android.view.View?   // 唯一 Android 侧增量，绝不以 WebView 类型暴露
}

// DemoEngineFactory.kt —— :app 只 import 这个工厂，不 import WebViewEngine
fun createDemoEngine(
    context: Context,
    channelHandler: LoopbackChannelHandler,
    logger: EngineLogger = AndroidEngineLogger(),
    workerAssets: WorkerAssets,
    pageParams: Map<String, String> = emptyMap(),
): DemoEngine
```

## EngineHost SPI 对齐（F5）：`:dsh` 不再需要直接依赖 `:engine`

- `DemoEngine` 现在**直接实现** `:platform` 的 `EngineHost`（`state`/`channel`/`handshake`/`start()`/`stop()`）；三个值类型是 platform `EngineHostState`/`EngineChannelStatus`/`EngineHandshake` 的 typealias，`DemoEngine.kt` 里同名同形的 sealed/data class 已删除。`:dsh` 持有 `EngineHost` 即可读生命周期/通道/握手（`FakeEngineHost` 已在 `:platform` 的 `testing` 包里）。
- 现状：`android/dsh/build.gradle.kts` 仍写着 `api(project(":engine"))`；引擎侧已就绪，删除该依赖属于 `:dsh` 车道（本车道禁改 `:dsh`）。
- **Kotlin 限制（踩坑）**：typealias 不能做嵌套类型的限定符——`EngineState.Stopped` / `is EngineState.Running` 编译不过（kotlinc 2.1.0 实测），`EngineState` 只能用在**类型位置**。engine 源码因此写 `EngineHostState.Stopped`；`:app` 里现有的 `EngineState.<变体>` 同样要改成 `EngineHostState.<变体>`（加 `import com.phonedsh.platform.EngineHostState`），纯类型注解可保留 `EngineState`。
- 视图与构造：`:app` 用 `createDemoEngine(...)` 构造、用 `DemoEngine.view()` 把唯一 WebView 挂进 `AndroidView`，于是 `grep -rn "android.webkit\|WebView" android/app` 为空。`view()` 返回 `android.view.View`；`stop()` 完成后返回 null，renderer 死亡或 stop 后旧实例已 `destroy()`、永不复用；`liveWebViews` 单实例断言未放松。
- 失败上报（真原因，不带 token / 完整 URL）：`LoopbackServer.lastFailure()` 与 `metrics().engineFailures` 已接进生命周期——
  - `start()` 失败：`Failed.reason = "loopback origin failed: <真实 cause>"`（解包 `LoopbackStartException`，例如 `SocketException: Operation not permitted`，而不是只有 host:port 的 wrapper）。
  - 运行期 origin 死亡：Running 期间每 500 ms 轮询 `lastFailure()`（`:net` 没有回调），命中即 `Failed("loopback origin failed: … (engineFailures=N)")` 并同时写 `channel.lastError`。
  - `OriginFailure` 把 `http(s)://…` 压成 `<url>`，并沿用 `EngineLogText.reasonOf` 的 query 截断 + 180 字符截断：`lastError` 里没有 token，也没有完整 URL。

## 方案 §6.3 五条 → 实现位置

| 要求 | 实现 | file:line |
| --- | --- | --- |
| 1 renderer 死亡进入 LIFECYCLE | `onRenderProcessGone` 返回 true；`didCrash()` 区分 crash/LMK；销毁→下一主循环重建→reload；Running→Recovering→Running；每次 start 最多 3 次 | WebViewEngine.kt:478 / :506 / :533 |
| 2 可见性纪律 | `setRendererPriorityPolicy(BOUND, false)`（第二参必须 false）；onPause/onResume 未接（无宿主） | WebViewEngine.kt:354 |
| 3 版本降为遥测 + 特性探测 | 版本号只作遥测：真实内核版本取页面 UA 的 `Chrome/NN`，**绝不解析 versionName**；`capabilities()` 保留 provider + `WebViewFeature` 三项遥测；**门禁是运行时特性检测** —— `onPageFinished` 后在页面内 JS 探测 `KernelFeature` 的 4 个 API（每项都引 worker 代码），缺必需项 → `Failed` + 用户可见原因（不白屏），版本低于 floor **124** 只记 degraded（worker 有前置垫片，Chromium 109 实跑通过） | WebViewEngine.kt:588/765/781、WebViewKernel.kt:55/144/167/307 |
| 4 WASI 永不带 pthreads | 不加载 wasm、不依赖 SAB；COOP/COEP 关闭（WebView 无跨源隔离），约束本身在 spec | WebViewEngine.kt:101 |
| 5 单 WebView + release 纪律 | `liveWebViews` 断言 + 关调试 + 禁 file/content/universalFile + 导航白名单 + 无 JS bridge；`view()` 只暴露 `View` | WebViewEngine.kt:304/306/374/337-343/416、NavigationPolicy.kt:27 |

## 关键实现事实（含踩坑）

- bundle 以**单个 zip** 进 APK：AGP 资产合并会把 `*.gz` 解压并去掉后缀（`image.tar.gz`→`image.tar`，25.2 MB→84.8 MB，字节也变），而 bundle 按 `.gz` 名字寻址；`packageWorkerBundle` 打 zip（engine/build.gradle.kts），`ZipWorkerAssetSource` 读回，条目名/字节与源逐字节一致（cmp 验证）。
- 静态子资源走 `shouldInterceptRequest`（LoopbackAssetResponder.kt:43），主 frame 走 `loadUrl(launchUrl())`（WebViewEngine.kt:240），`/channel` 留给真 server。
- 通道开 `allowQueryTokenOnChannel = true`（WebViewEngine.kt:95）：浏览器 WebSocket 不能带 header，worker 自己给 channel URL 加 token。
- COEP 是页面 boot 的隐形杀手：页面带 `COEP: require-corp` 时 Chromium 以 `net::ERR_BLOCKED_BY_RESPONSE` 拒绝被拦截的 **Worker 脚本**（普通 subresource 正常）；只有关掉 `crossOriginIsolation` 才通（WebViewEngine.kt:101）。单加 CORP 响应头不够。
- HELLO 用 `:core` 的 `WireCodec.decode`（ChannelTelemetry.kt:32/126），合并 worker/host 两帧；解码失败只写 `lastError`，不进 Failed。
- 帧计数/标签：inbound（ChannelTelemetry.kt:75）、outbound（:87），codec 经包装后的 connection 发送才计数；未知 type → `UNKNOWN(0xNN)`（FrameType.kt:20）。
- loopback 失败文本只有一个出口：OriginFailure.kt（start 用 `startReason`，运行期用 `runtimeReason`），WebViewEngine 的 Failed 与 `channel.lastError` 都经它，token/URL 规则见上一节。
- WebView 内核判据是**运行时特性检测**，不是版本比较：`KernelFeature` 的四项各自引 `worker/worker.js` 的真实调用点（`iterator()` 的 `Symbol.asyncIterator`、`inflateImageStream()` 的 `pipeThrough`/`DecompressionStream("gzip")`、primordials 的 `Symbol.dispose` 垫片）；UA 只用来取 `Chrome/NN`。缺必需特性 → `failEngine`；`Symbol.dispose` 是 optional（worker 自带 `Symbol.dispose || Symbol("Symbol.dispose")` 垫片），缺了只记 `shimmed`。
- **真实内核门槛是 Chromium 124，不是 99**：`ReadableStream.prototype[Symbol.asyncIterator]` 原生支持始于 Chrome 124（MDN BCD `api/ReadableStream.json` `@@asyncIterator`；caniuse `mdn-api_readablestream_--asynciterator` 列 4–123 不支持；Firefox 110、Safari 27）。`ChromiumVersion.FLOOR_MAJOR = 124` 只用于 degraded 文案与判定，**UNSUPPORTED 仍只由特性探测决定**。
- 探测测的是**垫片之后**的 surface：`WebViewKernelProbe.SCRIPT` 先安装与 worker 前导**同源**的垫片，再真实消费一个 chunk。这样才能覆盖 Chromium 99/109（华为基线 / android-33 镜像）：它们没有原生异步迭代，但 worker 的第一条 import 会装好。只测原生 API 会把这类能跑的内核误判为不支持（P11 实测 bug）。

  该副本是**被机器检查的副本，不是被信任的副本**：它早先只装 14 个前导属性里的 1 个，探测因此测的是比 worker 实际得到的**弱得多**的 surface。现在 `plugins/worker-entry/src/webview-kernel-probe.test.ts` 会跑**真实的**四个前导模块 installer 与这份脚本，各自抽取安装的属性名，差集非空即红并**点名缺失项**；`boot.ts` 若新增第五个前导模块，另一条测试同样会红。前导覆盖的四个模块是 `jsc-compat.ts` / `es2023-compat.ts` / `abort-signal-compat.ts` / `scheduler-compat.ts`。
- Chromium 109 还缺 worker 依赖的三组 **JS/平台内置**，全部由 worker 前置垫片补齐（不是内核门槛）：`Array.prototype.toReversed/toSorted/toSpliced/with` 与 `String.prototype.isWellFormed/toWellFormed`（Chrome 110/111，`es2023-compat.ts`）、`AbortSignal.any`（Chrome 116，`abort-signal-compat.ts`）、`scheduler.yield`（Chrome 129，`scheduler-compat.ts`）。这三项是 P11 在真机上逐条撞出来的，不是推测。

## 有序通道断开后的出口（P22，2026-11-01）

**缺陷**：页面那一条 WebSocket 断开后没有任何 owner 重开它。页面自己的客户端只在**非致命**
错误上重连（`backoffMinMs` 100 ms、上限 5 s），而 `BAD_MSEQ`/`RING_TIMEOUT` 会置
`fatalError` 并**永久**停止重连；宿主侧、engine 侧都没有重连循环；`Running -> Recovering
-> Running` 只接了渲染进程死亡。结果：通道一断，App 静默停在「未连接」，之后每一轮都是
`no_channel` / `api_aborted`，只能杀进程（实测 2026-11-01，模拟器 API 35）。

**改法**（`ChannelReopenLane.kt`，用既有边，没有新状态）：

| 步骤 | 实现 | 日志 |
| --- | --- | --- |
| 断开即进 `Recovering` | `ObservedChannelHandler.onChannelLost` → `ChannelReopenLane.onEpisodeStart` → `lifecycle.markRecovering()`（`Running -> Recovering`） | `ordered channel lost: Running -> Recovering (the page will be reloaded once the host accepts writes)` |
| 先给页面自己 1 s | 首次退避窗口就是给客户端自我重连的窗口；成功则整个 episode 取消（**不重载**） | `channel reopen: the page reopened the ordered channel on its own` |
| 宿主不接受写时不重载 | `writesAllowed`（`:app` 传 `controller.admission == OPEN`）；admission 关闭时**只等不重载**，否则新 worker 的首个 `VFS_MUT` 会被 `VFS_RESYNC` 拒绝，mseq 再次跑飞 | `channel reopen: waiting for the host to accept writes (D14 admission is closed)` |
| 重载同一页（不新建 WebView） | `loadUrl(launchUrl(...))`，同 origin、同 cookie、同 token；`createWebView` 只属于渲染进程死亡路径 | `channel reopen: reloading <base url> (attempt N, same WebView and origin)` |
| 退避 | `ReopenPolicy`：1 s 起、翻倍、15 s 封顶；**30 s 内最多 5 次重载**（`attemptsWithin(30_000)`）。页面若在 20 s 内再次掉线，退避**继续升**（不重置） | `channel reopen: attempt N in D ms (page reload)` |
| 成功 | 通道重新 `open` → `onChannelOpened` → `Recovering -> Running`（**只在通道真的回来后**才回 Running，不是 `loadUrl` 之后） | `recovered: the page reopened the ordered channel on the same origin; Running(...) after N reload attempt(s)` |
| 僵尸通道（新发现） | `onClosed` **不会来**：origin 的单通道槽被已死连接占着，engine 仍认为 `connected=true`，页面每次重连都吃 409。`watchStaleChannel` 每秒读 `LoopbackMetrics.channelsRejected`，在 `connected=true` 时增长即判定僵尸（`StaleChannelRule`），走同一条 episode | `stale ordered channel: the page asked for a new upgrade and the origin refused it (channelsRejected=N, channelsAccepted=M) …` |
| 重载也拿不到通道 | 槽位仍被占着时重载无用；lane 用 `channelsRejected` 相对基线的增量判定，改为 `stop()+start()`（同一 D14 行的 `RESTART_WORKER`） | `channel reopen: escalating to a full worker restart (RESTART_WORKER)` → `recovered: the restarted worker opened a new ordered channel` |

- 通道重开后 worker 的 `nextMseq` 从宿主 HELLO 的 `next_mseq` 重新锚定（`max(local,
  hello.next_mseq)`），这正是 `BAD_MSEQ` 之后唯一能修复失配的东西：引擎在设备日志里
  从 `expected 224 / got 3085` 直接回到 `next_mseq=105`，同一进程继续跑通。
- `reload` 只在 `Running`/`Recovering` 两态、且页面还在时执行；`stop()` / 启动失败 /
  渲染进程重建都会 `reopenLane.cancel()`（`shutdown()` 第一件事）。
- UI：`EngineHostState.Recovering` 的说明文案改成同时覆盖「渲染进程退出」和「有序通道断开」
  两种原因（`ProbeScreen.kt`）；`通道.最近错误` 现在对 `CLIENT_CLOSED` 也留字（此前
  只有 `TRANSPORT_LOST` 等有 note，最能杀死通道的那种关闭反而无声）。

## 验证（真跑）

- `:engine:assembleDebug` BUILD SUCCESSFUL；AAR 内含 `assets/worker-bundle.zip`。
- `:engine:test` debug 变体 **74 tests / 0 failed**（2026-11-01 复跑；含新增 `WebViewKernelTest` 11：UA 版本抽取、vendor 分桶、必需/可选特性判定、UNVERIFIED/DEGRADED/UNSUPPORTED、`evaluateJavascript` 双层解码、探测脚本覆盖全部 feature id）。
- 模拟器（pdsh35 / SDK 35 / WebView 124）**2/2 instrumented PASS**；新断言：Running 时 `view() === currentWebView`，stop 后 `view() == null`。关键 logcat：

```
state: Stopped -> Starting
webview created on the UI thread (live=1, provider=com.google.android.webview)
state: Starting -> Running(origin=http://127.0.0.1:42617, port=42617)
page finished: http://127.0.0.1:42617/ (title="DSH booting")
channel channel-1: open (live=1); frames are forwarded to the codec unchanged
channel: status=EngineChannelStatus(connected=true, framesFromWorker=1, framesToWorker=0, lastFrameType=HELLO, lastError=hello decode unavailable (libpdsh_jni not packaged)) handshake=null
webview destroyed (live=0, rendererGone=false)
```

## 内核门槛实测（P11，2026-11-01）

同一份 APK、同一个 `probe.sh` 探针，只换模拟器镜像：

| 镜像 | WebView | 探测结果 | 回合 |
| --- | --- | --- | --- |
| android-33（`p11-5572`，自建） | 109.0.5414.123 | `verdict=degraded`、四个特性全 true | **APP_TURN_OK**，模型回复「P11 内核门槛已修正」 |
| android-35（P3 车道） | 124.0.6367.219 | 原生支持，`supported` | 正常（P3） |

修复前的同一镜像（`FLOOR_MAJOR = 99` + 只测原生 API）逐字报错：

```
webview kernel: provider=com.google.android.webview/109.0.5414.123, vendor=google,
  Chromium 109 (provider 109.0.5414.123), verdict=unsupported,
  features=readable-stream-async-iteration:false,readable-stream-pipe-through:true,
  decompression-stream-gzip:true,symbol-dispose:true
state: Running(...) -> Failed(webview kernel cannot run the worker: missing
  readable-stream-async-iteration (Chromium 109 (provider 109.0.5414.123)))
```

修复后同一镜像：`verdict=degraded`、`readable-stream-async-iteration:true`，随后回合跑通。**结论：M99 假设下这个产品在 99/109 类内核上不可用；真实需求是 Chromium 124 原生，或带前置垫片的 109（已实测）。**

## 未验证 / BLOCKED

- renderer 死亡注入：**未验证**（路径已实现，未在模拟器 kill `sandboxed_process` 观察 Recovering→Running）。
- HELLO 真解码：**BLOCKED(libpdsh_jni)** — `.so` 未打进 APK（cargo-ndk 未装），首帧已标 HELLO，`handshake=null`、`lastError` 说明原因。
- 运行期 loopback 死亡：**未在设备上注入验证**（watcher 路径已实现；失败文本由 OriginFailureTest 覆盖，`:net` 侧由 LoopbackStartFailureTest 覆盖）。
- 真机 / 华为 WebView / 32 位 ABI / onPause-onResume 可见性 / FGS 无 Activity 宿主：**未验证**。
- WebView 内核探测的设备侧验证：**android-33（WebView 109.0.5414.123）与 android-35（124.0.6367.219）均已实测**（P11，2026-11-01）；华为真机仍未验证——只有「Chromium 99 基线」的厂商文档说法，没有一台设备跑过。
- 页面 "DSH ready" 文案未断言（只看通道与 HELLO 帧）。

## loopback API 不合用处（未改 :net，仅报告）

1. 静态资源 header-only：只能靠 `shouldInterceptRequest` 绕；iOS 的 D22 launch cookie 才是正解。
2. `LoopbackServer.start()` 现在会同步失败（`LoopbackStartException`，`cause` 是真实 IOException）；但**运行期**死亡只记录在 `lastFailure()`/`metrics().engineFailures`，没有回调/Flow，engine 只能 500 ms 轮询。
3. `crossOriginIsolation` 默认 true 会阻断 WebView worker；`allowQueryTokenOnChannel` 默认 false 需 engine 自己开。
