# 电视发现与零输入 ADB 连接 — 实施计划

- 日期：2026-11-12
- 状态：`partially implemented` — 模块、iOS/Android 双端页面与单测已落地；真机连接/授权与真机网络路径尚未验证。
- 影响面：iOS 与 Android 同轮落地（P09 页面结构两端一致）；SSDP 与「一键装应用」仍为后续工作
- 关联文档：[Android ADB 控制](../android-adb.md)、[PC-20261105-native-ssh-adb](../protocol-changes/PC-20261105-native-ssh-adb.md)、[协议基线 §3/§4](../../spec/README.md)

## 1. 要解决的问题

现在的 ADB 是「专家模式」：用户得先在电视上查 IP，再手填到 `AndroidADBSettingsPage.swift:17`，
或者对模型说「连接 192.0.2.221:5555」。这一点在真机上直接暴露为三个症状：

1. **要输入 IP。** 电视 DHCP 一变就失效；电视的 IP 在电视设置里藏得深，遥控器打字更难。
2. **失败了不知道为什么。** `ADBClient.swift:91` 抛的是单一种类 `ADBFailure`，文案是一句话：
   「authorization refused; unlock Android and accept this iPhone's debugging key」。
   UI 分不清「没授权 / 网络不通 / 端口不对 / 设备不支持」，只能原样贴给用户。
3. **授权是一次性的，但没有「等它」的过程。** 用户在电视上点允许的那几秒，App 只会报错，
   不会自己去轮询、也不会在授权到位后自动继续。

目标体验（用户视角只有三步）：

```
打开设备页 → 卡片上直接出现「REDMI 电视 · 可控制」→ 点一下
          → 电视上弹「允许调试」，点允许 → 卡片变「已连接」，遥控面板可用
```

装应用同理：说一句「装 StudyOnTV」或点一个按钮，不需要用户碰 IP、端口、文件名。

## 2. 现状（代码调研结论）

> 下表是立项（实现前）的现状调研，保留作为设计依据；实现后的实际落点见 §6。

| 事实 | 位置 | 对计划的影响 |
| --- | --- | --- |
| ADB 端点是单条的 host/port，无设备身份 | `Sources/PhoneDSHADB/ADBSettings.swift:4-15`、key `phone-dsh.android-adb.configuration.v1` | 加「设备身份 + 重定位」需要新键，属 P18 |
| 连接失败只有一种错误类型 | `Sources/PhoneDSHADB/ADBClient.swift:75-95`、`ADBFailure` | 先做错误分类，后面 UI/agent 才能分支 |
| 已有局域网发现，但只认自家服务 | `Sources/PhoneDSHLAN/LANDeviceDiscovery.swift:26`（`_pdsh-mcp._tcp`） | 可复用其 15 秒窗口/过期语义，但不含电视 |
| Bonjour 只声明了两个类型 | `examples/probe-app/Config/PhoneDSHProbe-Info.plist`：`_pdsh._tcp.`、`_pdsh-mcp._tcp.` | 新增任何 service type 都要加 `NSBonjourServices` |
| 设置页只有一个表单 | `examples/probe-app/PhoneDSHProbe/AndroidADBSettingsPage.swift`，契约在 `spec/ui/v1/pages/android-adb-settings.json` | 改 UI 就是 P09 契约变更，还要动 Android 同页 |
| 电视侧无 mDNS 广播 | 实测：`_adb-tls-connect._tcp` 搜不到（Android 9 的 adbd 不广播） | 只有 Bonjour 找不到这台电视，**必须**扫端口 |
| 电视 5555 常开、6095/6091 为小米私有端口 | 实测 `192.0.2.221` | 端口指纹可作为「这是台小米系电视」的证据 |
| iPhone→Android 真机路径尚未验收 | `docs/android-adb.md:236` | 本计划的真机验收清单必须包含它 |

## 3. iOS 平台约束（决定方案形状，不是实现细节）

| 约束 | 后果 |
| --- | --- |
| 没有 `com.apple.developer.networking.multicast` | **SSDP/UPnP/DLNA 组播发现不可用**。只支持 DLNA 的电视发现不到，除非向 Apple 申请该 entitlement |
| Bonjour 需逐条声明 `NSBonjourServices` | 每加一个探测类型都要改 Info.plist |
| 首次局域网访问会弹系统授权 | 已有 `NSLocalNetworkUsageDescription`；扫描前必须有明确用户动作 |
| 只允许前台扫描，且扫描耗电 | 不做后台扫描、不做常驻轮询；结果缓存 + 手动刷新 |
| 可以单播连接任意内网地址 | `/24` 的 TCP 连接扫描可行（Fing 类 App 即如此），但要限并发/超时 |
| 无法执行 `adb`、无法 port forward、无法 `adb pair` | 「网络 ADB 没开」的设备，iPhone 端**无法代为打开**，只能给指引 |

结论：电视发现的正确形状是 **Bonjour 目录（覆盖会广播的电视）+ 单播端口探测（覆盖不会广播的电视）**，
SSDP 明确列为「需要 entitlement 才能做」的后续项。

## 4. 方案

### 4.1 发现管线

```
       ┌─ A. Bonjour 目录（10s）──────┐
触发 ──┼─ B. 单播端口探测（~3s）────┼─→ 合并去重 → 证据评分 → 排序 → 卡片
       └─ C. 历史设备缓存（0ms）─────┘
```

- **触发**：进入设备页的一次显式动作（「发现电视」按钮/下拉刷新），或首次进入且从未连接过。
- **A 与 B 并行**；A 的 10 秒窗口与 `LANDeviceDiscovery` 现有 15 秒语义保持一致。
- **C 先出结果**：上次连接过的设备立刻以「已知」状态呈现，后台再做 A/B 校正 IP。

### 4.2 A：Bonjour 目录

| Service type | 判读 | 置信度 |
| --- | --- | --- |
| `_androidtvremote2._tcp` | Android TV / Google TV 遥控服务 | 高 |
| `_googlecast._tcp` | 内置 Chromecast 的电视 | 高 |
| `_airplay._tcp` / `_raop._tcp` | Apple TV 或支持 AirPlay 的电视 | 高 |
| `_roku-rcp._tcp` | Roku 系 | 高 |
| `_adb-tls-connect._tcp` | Android 11+ 无线调试广播 | 高，但**只提示不连接**（六位配对码/TLS 未实现） |
| `_http._tcp` / `_workstation._tcp` | 泛泛，仅作为候选，不单独产出卡片 | 低 |

全部类型需加进 `NSBonjourServices`。表内类型除 `_pdsh-*` 外都**需要在真机上各验一次**；
未验证前只作为「候选标签」，不据此向用户断言设备身份。未验证的厂商私有类型（三星/LG）
**不进第一版**，避免把「猜」当成能力。

### 4.3 B：单播端口探测

对本机当前 Wi-Fi 的 `/24`（从 `getifaddrs` 取地址与掩码，不做跨网段），并发探测：

| 端口 | 含义 | 证据强度 |
| --- | --- | --- |
| 5555 | ADB TCP/IP | 强：直接对应「可控制」 |
| 6095 / 6091 | 小米 MIUI TV 私有服务（本机实测） | 强：品牌与电视形态 |
| 8009 | Cast | 中 |
| 7000 | AirPlay | 中 |
| 6466 / 6467 | Android TV Remote v2 | 中 |
| 8060 | Roku ECP | 中 |

实现约束：并发上限 64、单连接超时 400 ms、整体预算 8 s、可取消；`5555` 命中的主机立即进入连接流程，
其余端口命中的主机只作为「电视候选」展示，允许用户点一下再试。

> 端口命中只是**候选证据**，不是资产断言。卡片文案必须写「可能是电视」，不能写「是电视」。

### 4.4 合并与评分

候选结构（草案）：

```swift
public struct DiscoveredEndpoint: Identifiable, Sendable {
    public enum Evidence: Sendable {
        case bonjour(String)        // service type
        case port(UInt16)           // 5555 / 6095 / ...
        case adbBanner(String)      // 已授权后拿到的 device banner
        case cachedIdentity         // 上次连接过的串号
    }
    public let id: String           // stable: "host:port"
    public var host: String
    public var port: UInt16
    public var displayName: String
    public var brand: String?       // "Redmi" / "Xiaomi" / nil
    public var evidence: Set<Evidence>
    public var adbReachable: Bool
    public var authorization: AuthorizationState   // unknown / required / granted
    public var score: Int           // 5555+6095 = 高；单 Bonjour = 中
}
```

去重键 `host:port`；同一 host 的多个证据合并；显示名优先用 Bonjour/已授权 banner，
否则用 `host` + 品牌猜测（`小米系设备 · 192.0.2.221`）。

### 4.5 连接状态机

```
idle → probing ─┬→ unreachable      （端口不通：给「检查同一 Wi-Fi / 电视是否重启」）
                ├→ unauthorized ─→ waiting-for-approval ─┬→ connected
                │                                        └→ timeout（90s，给分厂商指引）
                └→ connected
```

关键点：

1. **错误分类先行**：把 `ADBFailure` 扩成带 `kind` 的类型
   （`.unreachable` / `.unauthorized` / `.busy` / `.protocol` / `.unsupported`），
   `ADBClient.swift:91` 抛 `.unauthorized`，UI 才能进入「等待授权」而不是报错。
2. **等待授权是正反馈**：进入该状态后每 2 s 重试一次轻量握手（不跑 shell），
   显示「请在电视上点『允许』」+ 已等待秒数；一旦握手通过，立即跑
   `checkConnection` 拿型号/版本/分辨率并自动保存端点。
3. **授权成功即持久化身份**：额外取 `ro.serialno`、`ro.product.model`、
   `ip link show wlan0`（MAC），写入设备档案，供 4.6 使用。
4. **超时不是死路**：90 s 未通过时展示「电视上没弹窗？→ 设置 → 开发者选项 → USB 调试」的分步指引。

### 4.6 身份与重连（对付 DHCP 漂移）

新键：`phone-dsh.tv-discovery.devices.v1`（设备档案列表）、
`phone-dsh.tv-discovery.last-endpoint.v1`（上次成功端点）。
启动或进入设备页时：先用缓存端点直连（<1 s），失败则用「串号/MAC」在发现结果里重新匹配；
匹配到新 IP 时**自动改端点并提示「电视换 IP 了，已自动找回」**。
历史里保留最近 8 台，超出按最后成功时间淘汰（P18 的键名与值域要登记）。

### 4.7 UI（P09）

设备页在「Android ADB」表单**之上**增加一块「发现的设备」，表单退化成「手动添加（高级）」：

| 状态 | 卡片 |
| --- | --- |
| 扫描中 | `正在查找局域网里的电视…` + 已发现 N 台 |
| 有结果 | 每台一行：`REDMI 电视 · 192.0.2.221 · 可控制`，右侧「连接」 |
| 等待授权 | `请在电视上点『允许』` + 秒表 + 「取消」；电视上没弹窗时展开指引 |
| 已连接 | 型号/系统/分辨率 + 「截图」「遥控」「装应用」「断开」 |
| 无结果 | `没找到。可能原因：电视没开网络调试 / 不同网段` + 「重试」「手动输入」 |

不删除手动输入——它是兜底，不是主路径。

### 4.8 工具面（P05）

本轮**没有新增或修改** native MCP 工具面：工具总数仍为 26 个，`spec/v1/native-mcp.md` 与 `spec/v1/golden/native-mcp/**` 未改。发现是设置页里的用户动作，agent 路径仍是既有的 `android_connect`。

| 工具 | 设计提案 | 本轮状态 |
| --- | --- | --- |
| `android_discover` | 跑一次发现，返回候选数组（host/port/brand/evidence/adbReachable），**不连接** | **未实现（推迟）**：Android 宿主端（`android/net` 的 ADB 实现）也声称提供同样的 26 个工具（`spec/v1/native-mcp.md`「Host status」），单端新增会破坏该契约；后续需要 iOS 与 Android 两端同改，并同步工具表与 golden 后才能加入 |
| `android_connect` | 接受 `host`+`port`，或接受 `candidateId`；连接后用同一轮询语义等授权，返回设备摘要 | 未扩展：保留既有 `host`/`port` 参数与语义；`candidateId` 未实现 |
| `android_install_apk` | 仍要求 workspace + sha256；不改语义 | 未改，维持原语义 |

工具面是协议（`spec/v1/native-mcp.md`）：任何新增工具都必须两端同改，不能只落一端。

### 4.9 一键装应用（把上一轮的坑固化）

预设源（JSON，随包下发，不进 spec）：

```json
{ "id": "studyontv", "label": "题了个题 · TV",
  "repo": "chadyi/StudyOnTV", "assetPattern": "StudyOnTV-Android-TV-.*\\.apk$",
  "packageName": "com.studyontv.tv" }
```

流程：`api.github.com` 取 latest release → 匹配资产 → `curl -L` 下载到 `/dsh/workspace/downloads/`
→ `shasum -a 256` → `android_install_apk(source: workspace, sha256)` → `android_launch_app`。

**必须在 UI 上暴露的前提**：GitHub release 资产会 302 到 `release-assets.githubusercontent.com`，
该 host 不在默认 egress 白名单（`examples/probe-app/PhoneDSHProbe/ChatModel.swift:40`）。
面板要检测白名单并在缺失时给一键补入，而不是等 `curl` 403。

## 5. 协议影响（按 [spec/README.md §4](../../spec/README.md) 的触发表）

实现结论（2026-11-12）：

```
Protocol impact: P05; P09; P17; P18; P27: none — 只改设置页发现 UI，不涉及 bot row/action-result 投影；P08: none — 未改 spec/platform/**，扫描只是 UI 动作；P07: none — 不新增 device wire/envelope，电视发现停留在 UI + ADB 工具面
```

本轮**没有新增或修改 MCP 工具面**：`android_discover` 被推迟，因为 Android 宿主端（`android/net` 的 ADB 实现）也声称提供同样的 26 个工具，单端新增会让两端工具目录不一致并破坏该契约；`spec/v1/native-mcp.md` 与 `spec/v1/golden/native-mcp/**` 本轮未改。

| ID | 为什么 |
| --- | --- |
| **P05** | **仅 `Sources/PhoneDSHADB` 内部实现变化，工具面仍为 26 个**：错误分类（`ADBFailureKind`）、取消/不可达区分、`.busy` 生产点、发现/连接/设备目录类型都在模块内，工具名、schema、回执不变；`spec/v1/native-mcp.md` 与 `spec/v1/golden/native-mcp/**` 未改 |
| **P09** | `examples/probe-app/PhoneDSHProbe/**` + `spec/ui/v1/pages/android-adb-settings.json`：发现 UI 已落地，页面契约已按源码再生成（5 sections / 25 rows / 7 actions，0 divergences）；Android 同页的**能力**差异（无 Bonjour 目录、无 remembered/lastEndpoint）是刻意范围，已写入 `docs/android-adb.md` 与交接稿，不当作 parity 已完成 |
| **P27** | none（路径触发，语义无关）：`examples/probe-app/PhoneDSHProbe/**` 在 P27 触发路径内，但本轮只改 Android ADB 设置页的发现 UI，不涉及 bot row / row-projection / action-result 投影；`spec/bot/**`、`spec/tools/bot/**`、`Sources/PhoneDSHBot/**` 均未改 |
| **P17** | ADB 走现有 exec bridge，不新增 envelope；`TVConnector` 是模块内 actor，不是新的跨进程端点。文件在触发路径内，显式声明「无 envelope 变化」 |
| **P18** | 新增 UserDefaults 键 `phone-dsh.tv-discovery.devices.v1`（按 serial 去重、上限 8 条）与 `phone-dsh.tv-discovery.last-endpoint.v1`（`{host, port}`）——键名即协议 |
| **P08** | 本轮不触发：`spec/platform/**` 未改；设计期的待裁决项（是否把局域网扫描登记为 platform capability）仍未落 spec，SSDP/组播也未实现 |
| **P07** | 不动。电视发现停留在 UI + ADB 工具面；若未来要把电视并入统一设备目录，再走一次契约变更 |

## 6. 实施记录（2026-11-12）

### 6.1 落地的文件

| 文件 | 内容 |
| --- | --- |
| `Sources/PhoneDSHADB/TVDiscovery.swift`（新） | `TVCandidate` / `TVEvidence` 模型、证据合并与评分、`TVDiscoveryEngine`（Bonjour 与端口探测并行、port-major 顺序、8 s 总预算、可取消）、`NWTVPortProbe`、`BonjourTVBrowser`、`tvLocalSubnetHosts()` |
| `Sources/PhoneDSHADB/TVConnector.swift`（新） | `TVConnectPhase` 状态流、`ADBShellTVChecker`（一次 shell 读 serial/model/release/`wm size`/wlan0 MAC）、仅对 `.unauthorized` 每 2 s 重试、90 s 超时 |
| `Sources/PhoneDSHADB/TVDeviceDirectory.swift`（新） | 按 serial 去重的最近 8 台设备、上次成功端点与 `forget` 清理，两枚 UserDefaults 键 |
| `Sources/PhoneDSHADB/ADBProtocol.swift`（改） | 新增 `ADBFailureKind`（unreachable / unauthorized / busy / protocolViolation / unsupported / cancelled / device），`ADBFailure` 带 `kind` 并保持旧初始化兼容 |
| `Sources/PhoneDSHADB/ADBTransport.swift`（改） | 区分调用方超时关闭与任务取消：仅任务取消标 `.cancelled`，其余网络失败标 `.unreachable` |
| `Sources/PhoneDSHADB/ADBClient.swift`（改） | AUTH 拒绝标 `.unauthorized`，协议/帧错误标 `.protocolViolation`，取消标 `.cancelled`；既有 message 保留 |
| `Sources/PhoneDSHADB/ADBMCPServer.swift`（改） | 已在运行的 Android 操作以 `.busy` 分类（文案不变）；工具名/schema/回执未变 |
| `Sources/PhoneDSHADB/ADBExecProvider.swift`（改） | 重复的文件传输以 `.busy` 分类（文案不变） |
| `Tests/PhoneDSHADBTests/TVDiscoveryTests.swift`（新，6 例） | 证据合并、评分排序、配置端口、总预算到期 |
| `Tests/PhoneDSHADBTests/TVConnectorTests.swift`（新，3 例） | 未授权→重试→已连接、不可达直接失败、成功后写设备目录 |
| `Tests/PhoneDSHADBTests/TVDeviceDirectoryTests.swift`（新，8 例） | 8 条上限与淘汰、serial 去重、`forget` 清端点、坏文档容错 |
| `examples/probe-app/PhoneDSHProbe/AndroidADBSettingsPage.swift`（改） | 「发现的电视」区域、扫描/候选卡、连接阶段与取消；手动表单保留为「手动添加（高级）」 |
| `examples/probe-app/Config/PhoneDSHProbe-Info.plist`（改） | `NSBonjourServices` 追加 `_androidtvremote2._tcp.`、`_googlecast._tcp.`、`_airplay._tcp.`、`_roku-rcp._tcp.` |
| `spec/ui/v1/pages/android-adb-settings.json`（再生成） | 5 sections / 25 rows / 7 actions，5/5 composable |
| `docs/android-adb.md`（改） | Discovery / Connecting / Remembered devices 三节 |

### 6.2 已执行的验证

- `swift build --target PhoneDSHADB` → PASS（Build complete）。
- `swift test --filter PhoneDSHADBTests` → PASS：**55/55**（review 修复后补 3 条：两个 wlan0/exit-code 用例与 remembered-port 用例）。其中 42 个单测（既有 33 例 + 新增 `TVDiscoveryTests` 6 例 + `TVConnectorTests` 3 例）通过；同一次运行还执行了工作树中已有的 `TVDeviceDirectoryTests` 8 例，亦全绿。网络路径使用注入的 `TVPortProbe` / `TVBonjourBrowsing` / `TVConnectionChecking` 替身。
- 页面契约已再生成并 `--check` 通过（按页）：`spec/ui/v1/pages/android-adb-settings.json`；`python3 spec/ui/v1/tools/extract_ios_pages.py --page AndroidADBSettingsPage --check` → `contracts up to date`（5 sections / 25 rows / 7 actions，5/5 composable）。全仓 `--check` 仍因无关的 `tono-link-usbota` 陈旧契约而 exit 1，本轮未改该页。
- Android 编译与单测：`JAVA_HOME=<jdk17> ./gradlew :lib:compileDebugKotlin :app:compileDebugKotlin --offline` → `BUILD SUCCESSFUL`；`:lib:testDebugUnitTest --offline` → `BUILD SUCCESSFUL`（111 classes / 1070 tests / 0 failures）。
- P09 页面结构：`page_structure_check.py` 对 `android-adb-settings` 页 `sections/actions/title` 均为 0 分歧；全仓仍为 12 条分歧（与本轮改动前的 HEAD 相同，属其它车道的既有债）。
- iOS App 可编译：`xcodebuild -project examples/probe-app/PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`（仅编译，未签名、未运行）。

### 6.3 未验证项

- 真机 iPhone ↔ Android TV 的连接与授权：授权弹窗、90 s 轮询、授权后一次 shell 读回、DHCP 换址后按 serial 重定位，均未执行。
- 真机 iPhone → 电视的网络可达性：iPhone 上 `192.0.2.221` 的 5555/6091/6095 全部不通，同刻 Mac 侧全开，判断为 AP 隔离/电视防火墙；这不是本轮代码能解决的。
- 真机 iPhone 扫描（已完成两次）：iPhone19,4 / iOS 27.2 上实跑扫描，约 8 s 出候选 `192.0.2.111:5555 · AirPlay · 可能不是电视`，并借此发现端口被 `LocalizedStringKey` 本地化成 `5,555` 的 bug，已改用 `Text(verbatim:)` 并更新页面契约锚点。
- 真实网络发现路径：`NWConnection` 端口探测与 `NetServiceBrowser` Bonjour 解析未在真机运行；单测只覆盖替身，Bonjour 实际命中率未验证。
- Android 真机：Android 端已实现同构 UI 与端口扫描（`:app` 的 `AndroidTvDiscovery`），但只在 JVM/Robolectric 单测与 Kotlin 编译层验证过，未在真机上扫描、未验证未授权重试。
- 真机网络发现路径（补充）：2026-11-12 在本机 macOS 上跑过一次真实局域网扫描（临时测试，跑完删除）：枚举 508 个地址、8.02 s 收敛、合并出 1 条候选（本机 AirPlay，`_airplay._tcp` + 7000 → 候选 `192.0.2.111:5555`）。这证明了 `NWConnection` + `NetServiceBrowser` + 合并评分在真实网络上不挂死且产出合理；但它不是 iPhone、也不含电视（当时电视离线，`192.0.2.221` ping 不通、5555 关闭）。
- SSDP / UPnP / DLNA：无 `com.apple.developer.networking.multicast` entitlement，未实现、未验证。
- macOS 构建：`swift build --target PhoneDSHADB` 的宿主编译通过，但全仓 `swift build`、macOS App/桌面目标及 macOS 上的运行行为未验证。

## 7. 工作拆解

| 阶段 | 内容 | 产出 | 验收 |
| --- | --- | --- | --- |
| **0. 错误分类** | `ADBFailure` 加 `kind`；`ADBClient` 的 AUTH 失败、连接超时、协议错分别归类 | `Sources/PhoneDSHADB/{ADBClient,ADBProtocol}.swift` | `swift test --filter PhoneDSHADBTests` |
| **1. 发现内核** | 端口探测器（可注入假实现）+ 合并/评分 + 候选模型 | 新 `Sources/PhoneDSHDiscovery/`（或并入 ADB 模块，见 Q1） | 纯逻辑单测：三种证据合并、去重、排序、超时取消 |
| **2. 发现编排** | Bonjour 目录、扫描预算、缓存读写 | 同上 + P18 键 | 单测 + 模拟器手工 |
| **3. 连接状态机** | 授权轮询、自动续跑、超时指引、身份落盘 | `ADBMCPServer`/新 `TVConnector` | 单测（伪造未授权→授权）+ 真机 |
| **4. UI** | 设备卡片、状态、指引；P09 页面契约同步；Android parity 排期 | probe-app + `spec/ui/v1/pages/**` | `ui_check.py`、`page_structure_check.py`、`phone-p0-conformance` |
| **5. 装应用** | 预设源、白名单检测、安装+启动 | 新工具插件或 App 内页 | 真机：电视上真装一次 StudyOnTV |

## 8. 验证

> 本节是计划的检查清单；2026-11-12 的实际执行结果见 §6.2，未验证项见 §6.3。

```sh
swift test --filter PhoneDSHADBTests          # 阶段 0/3
bash scripts/ci/check.sh --only phone-spec              # P05 工具面与 golden
bash scripts/ci/check.sh --only phone-p0-conformance    # P09 页面结构与 inventory
bash scripts/ci/check.sh --only phone-cross-tree        # registry 与触发图表一致
bash scripts/ci/check.sh --only phone-sdk               # 模块单测
```

真机清单（静态检查不能替代）：

1. 冷启动 → 设备页 → 3 秒内出现电视卡片，**不输入任何地址**
2. 点连接 → 电视弹授权 → 10 秒内自动进入已连接
3. 断开 Wi-Fi 重连/电视换 IP（DHCP 续约）→ 自动找回
4. 电视重启后跑一次：确认网络 ADB 是否失效，并验证失败文案能指向正确设置项
5. 装一次 StudyOnTV：搜索 → 下载 → 校验 → 安装 → 启动

## 9. 风险

| 风险 | 缓解 |
| --- | --- |
| 无组播权限 → 纯 DLNA 电视发现不到 | 端口探测兜底；把申请 multicast entitlement 列为独立事项 |
| `/24` 扫描在 App Store 审核被质疑 | 只在用户显式点击后扫、仅前台、结果缓存、不落外部 |
| 扫描耗电/发热 | 并发 64、单连接 400 ms、总预算 8 s、随时可取消 |
| 电视上不弹授权（MIUI TV 开发者选项被关） | 5555 开放但握手失败时给分厂商的一步步指引，而不是一句错误 |
| DHCP 漂移导致「明明是同一台却连不上」 | 串号/MAC 重定位（4.6） |
| iPhone→Android 真机路径本身未验收 | 本计划第一条真机测试就是它，先跑通再谈体验 |

## 10. 明确不做

- 不做 SSDP/UPnP（需要 entitlement）
- 不做 `adb pair`（Android 11 无线调试的 TLS + 六位码）
- 不做 USB（iPhone 无此能力）
- 不在后台扫描
- 第一版不做 Android 端 UI parity（记入 GAP-32）

## 11. 待定问题

1. **发现模块放哪**：新开 `Sources/PhoneDSHDiscovery/`（干净，但要动 `Package.swift` → P12），
   还是并入 `Sources/PhoneDSHADB/`（省一个模块，但发现与 ADB 耦合）。
2. **扫描范围**：全 `/24`，还是只扫「已知设备 + 网关同网段的前 64 个地址」以省电？
3. **是否默认自动连接上次设备**（用户可关）？
4. **是否申请 multicast entitlement**（决定能否支持 DLNA-only 电视，申请周期以周计）。
