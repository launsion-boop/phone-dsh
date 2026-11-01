<!-- SPDX-License-Identifier: MIT -->
# P22 证据：网络抖动杀死有序通道且不自愈（2026-11-01）

同一天第三个「状态机有异常入口、没有回到可用的出口」：P10 是 `Draining`（缺执行者），
P15 是 `Backoff`（缺执行者 + 契约有洞），本车道是**有序通道本身**——通道关了，
**没有任何 owner 会把它重开**，而唯一能重开它的东西（页面自己的 WebSocket 客户端）
在协议错误上是**永久**放弃的。

- 设备：自建 AVD `p22-5588`（`system-images;android-35;google_apis;arm64-v8a`，pixel_6，
  4 核 / 2 GB），端口 **5588**，SDK 35，`arm64-v8a`，
  `-no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect`。
- 探针：真实 `https://api.deepseek.com/anthropic`（`ApiKeyStore.importDevelopmentKey` 从
  `files/import-key.txt` 导入后删除明文；key 不出现在任何仓库文件里）。
- 网络抖动注入：`adb shell svc data disable` / `svc data enable`（本镜像的默认网络是
  cellular over `eth0`；Wi-Fi 在 netsim 上拿不到 DHCP 租约，`svc wifi disable` 是空操作，
  所以用 data 开关等价于飞行模式；见 §7）。
- 清理：实验结束 `adb emu kill` + `avdmanager delete avd -n p22-5588`。

## 1. 复现（修复前）

### 1.1 单独断网：通道不会死

`svc data disable` 20 s 后恢复，通道**完全不受影响**（loopback 是 `127.0.0.1`，网络切换
不碰它）：D14 走 P15 的 Backoff 往返，`channel-1` 从头到尾没关过。所以「断网」本身不足以
杀死通道。

### 1.2 断网 + 一轮正在跑：通道被 worker 自己关掉

`13:07:2x` 起一轮，`13:07:33` `svc data disable`，`13:07:48` `enable`（原始 logcat，
`PDSHHost` / `PDSHEngine` / `PDSHAppTurn`）：

```
11-01 13:07:33.104 I/PDSHHost( 4399): exec dispatch: tool=phone exec_id=… requires_mseq=91
11-01 13:07:35.226 D/PDSHHost( 4399): lifecycle signal: networkPath(unsatisfied)
11-01 13:07:35.226 I/PDSHHost( 4399): D14 Running -> Backoff via networkPath(unsatisfied) at 160766 ms (admission=closed, effects=3)
11-01 13:07:35.227 I/PDSHHost( 4399): retry schedule (network_path): attempt 1 in 953 ms (window 953 ms, admission stays closed)
11-01 13:07:37.902 I/PDSHHost( 4399): VFS mutation deferred: admission closed (D14)
   … 同一行 ×480，13:07:37.9 → 13:07:50.5 …
11-01 13:07:50.364 D/PDSHHost( 4399): lifecycle signal: networkPath(satisfied)
11-01 13:07:50.365 I/PDSHHost( 4399): D14 Backoff -> Running via retryProbeSucceeded(leaseVerified=true) at 175904 ms (admission=open, effects=5)
11-01 13:07:50.365 I/PDSHHost( 4399): retry schedule released: the host left Backoff
11-01 13:07:50.746 I/PDSHEngine( 4399): channel channel-1: closed cause=TRANSPORT_LOST (live=0)
11-01 13:07:50.746 I/PDSHHost( 4399): channel closed on channel-1: TRANSPORT_LOST
11-01 13:07:50.798 D/PDSHEngine( 4399): console ERROR: worker entry: VFS mutation refused; closing the ordered channel ChannelPeerError: BAD_MSEQ: expected mseq 105, got 585 (http://127.0.0.1:39021/worker-entry.js:94667)
11-01 13:07:50.803 D/PDSHEngine( 4399): console ERROR: webworker vfs: mutation observer failed ChannelPeerError: BAD_MSEQ: expected mseq 105, got 585
11-01 13:07:50.962 E/PDSHAppTurn( 4399): APP_TURN_FAILED reason=api_aborted
```

之后**三分钟里没有第二条 `channel channel-*` 行**（`grep -c "channel channel-"` 一直是 1），
页面客户端每 5 s 重连一次全部失败？不是——它**根本没在重连**：`BAD_MSEQ` 在客户端里是
`protocolFailure`，置 `fatalError` 后 `handleSocketLost` 直接 `return`（不排重连）。
宿主侧与 engine 侧也都没有重连循环。之后的回合：

```
11-01 13:09:32.474 I/PDSHAppTurn( 4399): session/create attempt 1 not answered (no_channel)
   … 1 Hz，连续 180 次 …
```

`uiautomator dump` 得到的界面（同一进程、同一时刻）：

```
宿主状态  运行中
D14       Running · admission open
引擎      运行中          EngineHostState.Running
通道      未连接
最近错误  channel lost (transport)
回合      失败   原因：api_aborted
```

**这就是用户可见缺陷**：界面同时说「运行中 / admission open」和「未连接 / api_aborted」，
而且这个组合在进程剩下的生命周期里不会再变。

## 2. 定位：谁关的，为什么没人重开

| 问题 | 答案（代码 + 日志） |
| --- | --- |
| `CLIENT_CLOSED`/`TRANSPORT_LOST` 是谁关的 | **worker（页面）自己**。`VfsSink.onMut` 在 admission 关闭时 `emit(VfsFrame.Resync(path))` 且**不 append、不 ACK**（`VfsSink.kt:186-192`，文件头自述「an explicit interim choice, not a perfect spec fit」）；bundled worker 对 `VFS_RESYNC` 只 `decodeVfsResync()` 然后 `return`（`worker-entry.js` `acceptNonHello`），既不复发也不回滚窗口。于是 worker 在 Backoff 的 13 s 里把 mseq 从 105 一路分配到 585，宿主仍期待 105；admission 一开，下一个 `VFS_MUT` 就是 `BAD_MSEQ`，**worker 主动 close**（`ChannelPeerError`）。 |
| 关闭后有没有重连循环 | **页面有**（`WebSocketChannelClient.scheduleReconnect`，100 ms 起、5 s 封顶，`handleSocketLost` 里排），但 `protocolFailure`（`BAD_MSEQ`/`RING_TIMEOUT`/`BAD_PAYLOAD`）会置 `fatalError`，`handleSocketLost` 直接返回 → **没有重连**。实测：关闭后 3 分钟零条 `channel channel-*`。 |
| 宿主侧 | `HostChannel.onClosed` 只做清理与 `abortApiExchanges("connection_closed")`，没有任何重开动作。 |
| `:engine` 的 `Running→Recovering→Running` | **只接了 `onRenderProcessGone`**（`WebViewEngine.kt` renderer 路径）。通道关闭不进 lifecycle，所以 `Recovering` 从来没被这次故障触发过。 |
| 为什么 `api_aborted` | `HostApiExchange.abort()` 无论什么原因都抛 `HostApiException("api_aborted")`；P22 之前「worker 主动 abort」和「通道没了」共用一个码。 |

**结论：不是「重开失败」，是「没有人重开」。** 页面在 fatal 之后永远不重连，宿主与 engine
也没有重开循环；唯一的出口（页面重载）没有任何 owner。

## 3. 与「mseq 水位」问题的关系

**同一族，但不是同一个 bug，也不是同一个位置。**

- 共同点：worker 侧 mseq 计数器与宿主 WAL/`next_mseq` 在**不连续点**上没有对账机制；
  HELLO 里的 `next_mseq` 是唯一的重锚点（worker `nextMseqValue = max(local, hello.next_mseq)`，
  `ws-client.ts:766`），只有**新页面**才会重新走这一步。
- 本车道的触发点：**admission 关闭期间的延迟写**（Backoff 里 480 条 `VFS_RESYNC`），
  水位差 480（105 → 585），修复手段是重载页面（新 worker 从 105 重新锚定）。
- 另一条车道报告的是**进程内 engine 重启**（worker 87 vs WAL 1811，方向相反），触发点是
  重启本身，不在 `VfsSink`。两者都不该靠「重连」修，只能靠「新 worker + HELLO 重锚定」。
- 因此：**自愈是两条车道共同的必需项**；本车道只做自愈，不改 `VfsSink` 的延迟策略
  （那是 durable 写路径，属另一条车道/契约讨论，见 §8）。

## 4. 改法（只用既有边，没有新状态）

新增 `android/engine/src/main/kotlin/com/phonedsh/engine/ChannelReopenLane.kt`（+ 三处接线）：

| 步骤 | 实现 | 设备日志 |
| --- | --- | --- |
| 通道关闭 → `Running -> Recovering` | `ObservedChannelHandler` 新增 `onChannelLost`/`onChannelOpened` 两个 seam；`WebViewEngine.reopenLane.onEpisodeStart` 调 `lifecycle.markRecovering()` | `ordered channel lost: Running -> Recovering (the page will be reloaded once the host accepts writes)` |
| 第一次窗口留给页面自己 | 4 s 退避同时是「客户端自我重连」的宽限；成功即取消 episode，**不重载** | `channel reopen: the page reopened the ordered channel on its own` |
| 宿主 admission 关闭时不重载 | `writesAllowed`（`:app` 传 `controller.admission == OPEN`） | `channel reopen: waiting for the host to accept writes (D14 admission is closed)` |
| 重载同一页 | `loadUrl(launchUrl(...))`，同 origin/cookie/token，**不新建 WebView**（单 WebView 不变量） | `channel reopen: reloading … (attempt 1, same WebView and origin)` |
| 退避 | `ReopenPolicy`：4 s → 翻倍 → 15 s 封顶；`attemptsWithin(30_000) = 3`；通道若在 20 s 内再掉线，退避**继续升**。第一个窗口 4 s 同时是「先让页面自己重连」的宽限（实测它需要 1.2 s，见 §8.0） | `channel reopen: attempt N in D ms (page reload)` |
| 新通道回来 → `Recovering -> Running` | `onOrderedChannelOpened` 里才 `markRunning`（不是 `loadUrl` 之后） | `state: Recovering -> Running(...)` + `recovered: … after 1 reload attempt(s)` |
| origin 卡住时升级为 worker 重启 | 设备实测（§6）发现重载拿不到通道：origin 的单通道槽仍被已死连接占着，新页面升级得到 **409**，重载多少次都没用。lane 用 `server.metrics().channelsRejected` 相对基线的增量判断，随后 `stop()+start()`（同一 D14 行的 `RESTART_WORKER`） | `channel reopen: escalating to a full worker restart (RESTART_WORKER)` → `the worker restarted; …` → `recovered: the restarted worker opened a new ordered channel` |

非静默（三处）：engine 日志（上表每一行）；UI —— `通道.最近错误` 现在对 `CLIENT_CLOSED`
也留字（此前只有 `TRANSPORT_LOST` 等有 note，最能杀死通道的那种关闭反而无声，见
`ChannelTelemetry.kt`），`EngineHostState.Recovering` 的说明文案改成同时覆盖两种原因
（`ProbeScreen.kt`）；`:dsh` —— 连接在请求下面断掉时抛新码 **`channel_lost`**
（不再是 `api_aborted`），并记录被这次断开带走的在途请求数。

`Draining`/`Parked`/`Failed` 一律不重开（`episodeMayContinue`）；`stop()`/启动失败/
渲染进程重建都会 `reopenLane.cancel()`（[shutdown] 第一件事）。

## 5. 单测 + 反向验证

新增 `ChannelReopenLaneTest`（12）、`ChannelLossExitTest`（3），改 `ChannelTelemetryTest`
（+2）与 `ObservedChannelHandlerTest`（+1）。反向验证（逐个删掉入口 → 测试红）：

| 删掉的东西 | 结果 |
| --- | --- |
| `ObservedChannelHandler.onClosed` 里的 `onChannelLost?.invoke(cause)` | `ObservedChannelHandlerTest.reportsTheOpenAndTheCloseOfALiveConnectionExactlyOnce` 红 |
| lane 的 `onEpisodeStart()` 调用 | `ChannelReopenLaneTest.aLostChannelIsReopenedByReloadingThePage` 红 |
| lane 的 `reload(attempt)` 调用 | `ChannelReopenLaneTest` **5** red（`aLostChannel…`、`aPageThatNeverReconnects…`、`noPageIsReloaded…`、`aChannelThatDiesAgain…`、`aChannelThatStayedUp…`） |
| `hostAcceptsWrites()` 闸门 | `ChannelReopenLaneTest.noPageIsReloadedWhileTheHostRefusesWrites` 红 |
| `ChannelLoss.failure()` 的 `channel_lost` 分支 | `ChannelLossExitTest.aConnectionThatEndsUnderARequestFailsItWithChannelLost` 红 |

不引入风暴的**数字**：`ReopenPolicy.DEFAULT.attemptsWithin(30_000) = 3`（4+8+15 s；第一个窗口同时是给页面自愈的宽限），
被单测钉住；`session/create` 的 1 s 定频重试（旧代码 180 次/3 分钟）改成
250 ms→2 s 退避，`createAttemptsWithin(30_000) = 17`，也被单测钉住。

## 6. 设备验证（修复后，同一进程）

### 6.1 通道被关 → 一次重载 → 通道回来 → 下一轮 `APP_TURN_OK`

pid 7197，`svc data disable` 20 s（`13:45:4x`）。turn 1 在抖动中失败并**明确报
`channel_lost`**（不再是 `api_aborted`），引擎重载后 1.1 s 内通道回来，turn 2 跑通：

```
11-01 13:45:44.597 I/PDSHAppTurn( 7197): APP_TURN_BUTTON prompt=62 chars
11-01 13:45:55.751 I/PDSHEngine( 7197): channel channel-1: closed cause=TRANSPORT_LOST (live=0)
11-01 13:45:55.751 W/PDSHEngine( 7197): ordered channel lost (cause=TRANSPORT_LOST); reopening the page for a new one (attempt 1, first backoff 1000 ms)
11-01 13:45:55.751 W/PDSHEngine( 7197): ordered channel lost: Running -> Recovering (the page will be reloaded once the host accepts writes)
11-01 13:45:55.751 E/PDSHAppTurn( 7197): APP_TURN_FAILED reason=channel_lost
11-01 13:45:55.752 I/PDSHEngine( 7197): channel reopen: attempt 1 in 1000 ms (page reload)
11-01 13:45:56.755 I/PDSHEngine( 7197): channel reopen: reloading the page (attempt 1)
11-01 13:45:56.763 I/PDSHEngine( 7197): channel reopen: reloading http://127.0.0.1:35525/ (attempt 1, same WebView and origin)
11-01 13:45:56.865 I/PDSHEngine( 7197): channel channel-2: open (live=1); frames are forwarded to the codec unchanged
11-01 13:45:56.865 I/PDSHEngine( 7197): recovered: the page reopened the ordered channel on the same origin; Running(origin=http://127.0.0.1:35525, port=35525) after 1 reload attempt(s)
11-01 13:45:57.014 I/PDSHEngine( 7197): channel reopen: the ordered channel is back after 1 reload attempt(s)
11-01 13:46:27.815 I/PDSHAppTurn( 7197): APP_TURN_BUTTON prompt=62 chars
11-01 13:46:35.308 I/PDSHAppTurn( 7197): APP_TURN_OK session=session-11d9b958-ee1a-4011-abff-df176f57575c kinds=turn_started,user_message,user_message,user_message,user_message,assistant_message,usage,tool_call,tool_result,assistant_message,usage,tool_call,tool_result,assistant_message,usage,tool_call,tool_result,assistant_message,usage,turn_ended reason=completed tool_edges=true
```

整个恢复花了 **1 块重载、1.1 s**；`channel-2` 的 HELLO 把 mseq 重新锚定（同一进程继续跑）。

### 6.2 僵尸通道（origin 拒绝升级）→ 看门狗 → 重载 → 通道回来 → `APP_TURN_OK`

**这是修的时候在设备上新发现的第二种死法**：通道的 close 从来没被 origin 看到，engine 仍
认为 `connected=true`，而 origin 的单通道槽被占着 → 页面每次重连都吃 **409**，`/api` 全部
超时。`ObservedChannelHandler.onClosed` 永远不会被调用，所以 lane 也不会启动。
新加的看门狗（`watchStaleChannel`）用 `channelsRejected` 的增长识别它：

```
11-01 13:47:18.045 E/PDSHEngine( 7197): stale ordered channel: the page asked for a new upgrade and the origin refused it (channelsRejected=2, channelsAccepted=2) while this engine still believes it is connected; the channel died without a close the origin could see
11-01 13:47:18.046 W/PDSHEngine( 7197): ordered channel lost (cause=TRANSPORT_LOST); reopening the page for a new one (attempt 1, first backoff 1000 ms)
11-01 13:47:18.046 W/PDSHEngine( 7197): ordered channel lost: Running -> Recovering (the page will be reloaded once the host accepts writes)
11-01 13:47:18.046 I/PDSHEngine( 7197): channel reopen: attempt 1 in 1000 ms (page reload)
11-01 13:47:19.051 I/PDSHEngine( 7197): channel reopen: reloading the page (attempt 1)
11-01 13:47:19.079 I/PDSHEngine( 7197): channel channel-2: closed cause=CLIENT_CLOSED (live=0)
11-01 13:47:19.080 E/PDSHAppTurn( 7197): APP_TURN_FAILED reason=channel_lost
11-01 13:47:19.185 I/PDSHEngine( 7197): channel channel-3: open (live=1); frames are forwarded to the codec unchanged
11-01 13:47:19.186 I/PDSHEngine( 7197): recovered: the page reopened the ordered channel on the same origin; Running(origin=http://127.0.0.1:35525, port=35525) after 1 reload attempt(s)
11-01 13:47:53.762 I/PDSHAppTurn( 7197): APP_TURN_BUTTON prompt=62 chars
11-01 13:47:58.869 I/PDSHAppTurn( 7197): APP_TURN_OK session=session-f699a655-d49f-484e-aee6-f6ee2bfcff95 kinds=… reason=completed tool_edges=true
```

### 6.3 抖动中的退避升级（设备侧）

同一进程里通道在 20 s 稳定窗内再次掉线时，退避**不重置**（`attempt 2`、`2000 ms`）：

```
11-01 13:48:39.032 W/PDSHEngine( 7614): ordered channel lost (cause=CLIENT_CLOSED); reopening the page for a new one (attempt 2, first backoff 2000 ms, escalating: the last channel did not stay up for 20000 ms)
11-01 13:48:41.127 I/PDSHEngine( 7614): channel channel-3: open (live=1); frames are forwarded to the codec unchanged
11-01 13:48:41.127 I/PDSHEngine( 7614): recovered: … after 2 reload attempt(s)
```

### 6.4 环境退化后的诚实记录（同一镜像，跑了一小时之后）

同一个 AVD 连续跑 ~40 次 `svc data` 切换后，WebView 的网络栈进入退化状态：**每次页面
载入后 1–2 s，有序通道都会自己 `TRANSPORT_LOST`**（`/api` 请求发出前后 ~150 ms 触发），
lane 每次都把它救回来（`channel-2/3/4…` 连续开合），但这一轮 turn 必然被打断：

```
11-01 14:01:44.013 I/PDSHAppTurn( 8528): APP_TURN_BUTTON prompt=62 chars
11-01 14:01:44.153 I/PDSHEngine( 8528): channel channel-4: closed cause=TRANSPORT_LOST (live=0)
11-01 14:01:44.159 E/PDSHAppTurn( 8528): APP_TURN_FAILED reason=channel_lost
11-01 14:01:44.160 I/PDSHEngine( 8528): channel reopen: attempt 1 in 4000 ms (page reload)
```

这不是本车道的行为（close 在宿主发出任何帧之前就发生，且每次都是新页面），也不影响
§6.1/§6.2 的结论；它说明**这台 AVD 的 WebView 网络状态不可信了**，fresh process 也一样
（`pid 9202` 同样在页面载入 1.8 s 后 `TRANSPORT_LOST`）。§6.1/§6.2 的 `APP_TURN_OK` 是同
一台设备、同一进程、在退化发生之前取得的。

### 6.5 lane 的尝试次数（不退避会风暴）

§6.1 的 episode：`grep -c "channel reopen: attempt"` = **1**，`grep -c "channel reopen: reloading the page"`
= **1**，从 `closed` 到 `recovered` 共 **1.11 s**。§6.2 同样是 1 次。
断网 20 s 期间重载次数 **0**（admission 关闭 → lane 停在等宿主那一步），恢复后 1 次。
重载连续失败时的上界由单测钉住：`attemptsWithin(30_000) = 3`（4+8+15 s）。

## 7. 环境限制（写清楚，不伪装）

- 本镜像 Wi-Fi（netsim）拿不到 DHCP 租约（`DhcpClient: Broadcasting DHCPDISCOVER` 无 OFFER，
  `wlan0` 只有 IPv6），默认网络是 cellular over `eth0`。因此抖动注入用 `svc data
  disable/enable`（等价于飞行模式），而不是任务里写的 `svc wifi disable`。
- `svc data disable` 单独不会杀死 loopback 通道（§1.1）——这是**真实结论**，不是没复现：
  loopback 不经过系统网络栈。
- 「admission 关闭时不重载」这条只有单测证据，没有设备证据：设备上让通道在 Backoff
  期间关闭的路径不可控（通道的死亡点恰好是 admission 重新打开的那一刻）。
- 页面重载会在 origin 侧留下「槽位仍被已死连接占着」的竞态（§4 最后一行、§6.3）：
  `:net` 没有「关掉某条连接」的 API，engine 只能整机重启。这是 `:net` 的契约缺口，
  本车道未改 `:net`。

## 8. open questions

0. **packaged worker 会在懒激活时关掉自己的通道，再在 ~1.2 s 后开一条新的**（设备实测：
   turn 的第一条 `/api/session/create` 到达后，`session-projection-cache` 立刻报
   `ChannelClosedError: channel closed`，1.2 s 后新通道 open）。这不是致命关闭，页面会
   自愈——所以 lane 的**第一个窗口不能短于它**：1 s 的窗口会在 1.0 s 重载，正好撞掉页面
   自己的重连（实测把一轮健康的 turn 打断了）。`ReopenPolicy.DEFAULT_FIRST_DELAY_MILLIS`
   因此定在 **4 s**（>1.2 s，<5 s 的客户端退避上限）。这是「先让页面自己修」的证据。
1. **`VfsSink` 的延迟策略是这条故障的触发器**：admission 关闭时回 `VFS_RESYNC` 但不
   append/ACK，而契约里 `VFS_RESYNC` 的语义是「物化失配后请求整文件重发，且不消费 mseq」
   （`channel.md` §3.4），bundled worker 并不实现它。要么让 worker 真的实现（`plugins/**`，
   本车道禁改），要么宿主持有延迟写并在 admission 重开时**按序**补 append+ACK。后者是
   durable 写路径的改动，应单独一条车道 + 契约确认。
2. **`:net` 缺少「关闭当前通道」的入口**：`LoopbackServer` 只有 `stop()`，没有
   `closeChannel()`/槽位超时。有了它，engine 的升级路径就不必整机重启。
3. **D14 没有「有序通道死亡」这一行**：WebContent 还活着，契约的
   `Running -> Recovering` 守卫写的是「WebContent terminated」。本车道用 engine 自己的
   `Recovering`（`:platform` 的 `Running -> Recovering -> Running`）表达，D14 全程停在
   `Running`——所以断连期间面板仍显示「宿主状态 运行中 / admission open」，只有「引擎
   恢复中 + 通道未连接 + 具体原因」在说真话。要不要给 budgets.md §2 加一行，属 spec owner。
4. **一轮在通道断开时必然失败**（`channel_lost`），不会自动重放：本车道只保证「下一轮能跑」。
   自动续跑与 P10/P15 的「不自动续跑」纪律一致，但用户体验上仍是一次可见失败。
5. **重载后 worker 的 VFS 内存视图从镜像重建**，而 WAL 已经前进到 `next_mseq`：mseq 连续
   （HELLO 重锚定）但**内容**是否一致没有对账证据（D8 的整树对账只在启动时跑）。这需要
   wal/物化车道的结论。
