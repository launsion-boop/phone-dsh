<!-- SPDX-License-Identifier: MIT -->
# :platform — OS 原语 SPI

纯 JVM（`java-library`），**禁止 `import android.*`**；这是唯一不镜像 Swift 模块的层（方案 §5.1、评审 B6）。
`:core` / `:controller` / `:dsh` 只依赖这里的接口，JVM 测试统一用 `com.phonedsh.platform.testing.FakePlatform`。

## 六个接口

| 接口 | 成员 | 承接 `spec/platform/whitelist.json` | D14 / 方案 |
| --- | --- | --- | --- |
| `Clock` | `nowMillis()`, `monotonicMillis()` | —（20 s drain 与 Retry-After 的计时基础） | budgets §2、§4 |
| `LifecycleSignals` | `events: Flow<LifecycleSignal>` | `platform.scene-phase`、`platform.thermal-battery`、`platform.nwpathmonitor` | §3 scenePhase / thermalState / battery / NWPathMonitor |
| `Durability` | `fsyncPath`, `atomicReplace`, `level()` | `platform.fsync-epoch-close` | §11-R1、D2a；level 由实现回报 |
| `SecureStore` | `level`, `put`, `get` → `SecureLookup`, `delete` | `platform.keychain-credential-store`、`platform.keystore-downgrade-chain` | §7.3、§15-5、§11-R11 |
| `EngineHost` | `state`, `channel`, `handshake`, `start`, `stop` | 无直接条目；承接 §6.3 renderer-gone → `Recovering` | §6、D14 的 WebContent termination |
| `Notifier` | `availability`, `notify`, `cancel` | `platform.fgs-turn-notification`；`platform.post-notifications-degraded` 的可见性半边 | §9.4 |

## LifecycleSignal 变体

- `LifecycleSnapshot(signals)` → 订阅后的第一帧；`signals` 是适配器固定的启动顺序，不是 map 迭代顺序
- `ScenePhase(ACTIVE | INACTIVE | BACKGROUND)` → budgets §3 `scenePhase`
- `ThermalPressure(NOMINAL | FAIR | SERIOUS | CRITICAL)` → `thermalState`
- `Battery(percent, charging)` → battery / low-power mode
- `NetworkPath(available, expensive)` → `NWPathMonitor`
- `AppForeground(foreground)` → Android「进后台」与「Activity 重建」分离（`platform.scene-phase` 的 rationale）

`events` 是热流：每个收集者的第一帧必为 `LifecycleSnapshot`（可为空集合），之后才是变化，同一订阅内
不会出现第二个快照。`AppForeground` 与 `ScenePhase` 刻意分开，旋转屏幕不得触发 `Draining`。

## 诚实规则

- `LEVEL_2_POWER_LOSS_MEASURED` 只能由实测回报；`Durability` 实现**不得**默认返回它。
  `supportsLevel2Claim()` 只在 `MEASURED` 时为真（§11-R1、D2a：掉电台架本轮不做）。
- `SecureStore.level` 是当前安全级别的事实，不是承诺；UI 必须标注（§15-5）。
- `SecureStore.get` 返回 `SecureLookup`：`Found` / `Absent` / `Unreadable`。`Unreadable`（例如锁屏密码变更
  导致 Keystore key 失效）**不得**当成 `Absent`；`reason` 只放可安全展示的短标签（§11-R11、P3 reclaim 矩阵）。
- `Notifier.availability == DISABLED` 时调用方必须让降级对用户可见，不得假定后台进度可见（§7.4-4）。
- `atomicReplace` 的 target 只允许「旧字节」或「新字节」；中断不得留下半文件（`Durability` KDoc 是契约）。

## 22 条白名单里本层表达不了的

属于 `:net` / `:engine` / manifest / UI，不在六个 SPI 的职责内：

- `platform.nwlistener-loopback`、`platform.urlsession-http-client`（`:net` 的服务器与 HTTP 客户端）
- `platform.script-message-reply`、`platform.url-scheme-handler`（`:engine` 的 WebView 桥）
- `platform.bgtask-drain-window`、`platform.audio-keepalive`（app 层后台通道）
- `platform.lockdown-report`、`platform.webview-version-gate`（引擎能力报告，见 open question）
- `platform.budgettier-memory`（boot 期内存读取，建议后续加 `DeviceMemory` 信号）
- `platform.predictive-back`、`platform.network-security-config`、`platform.battery-exemption-policy`
- `platform.ws-upgrade-query-token`、`platform.coep-cross-origin-isolation`（`:net` 配置）

`platform.post-notifications-degraded` 只表达「呈现可见性」半边；UIDT 的降级不是通知接口能决定的。

## FakePlatform

`com.phonedsh.platform.testing.FakePlatform` 实现六接口：可推进时钟（`advanceBy` / `setNowMillis`）、
可发射信号（`emit`；每个收集者第一帧是自动生成的 `LifecycleSnapshot`）、内存 `SecureStore`
（`markUnreadable` 模拟 key 失效）、可配置 `DurabilityLevel` / `SecurityLevel`、记录 `notify` / `cancel`
并可触发停止按钮（`performAction`），`EngineHost` 委托给 `FakeEngineHost`。
`tempDir` 供需要真实文件的测试使用；`close()` 只删除自己创建的目录。

它是 test double，目前**随 `:platform` AAR 发布**；若发布物需要瘦身，由 `testFixtures` 或 `:testkit` 承载。

## 纪律

- 每个接口 ≤ 6 个成员；`.kt` 第 2 行 SPDX。
- `java.nio.file` 只出现在 `Durability`；真正的 `FileChannel.force` / rename / 目录 fsync 在 Android 适配器里。
- 新增接口前先证明它有 `spec/platform` 条目或 D14 驱动源，不做预留扩展点。
