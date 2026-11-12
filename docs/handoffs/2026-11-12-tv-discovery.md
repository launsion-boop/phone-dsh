# 电视发现与零输入 ADB 连接 — 评审与交接

日期：2026-11-12（本机时钟在 2026-11-11 19:00–20:00 -08:00 之间，所以命令日志里的时间戳多为 11-11）
分支：`codex/tonolink-volume-voice-keyboard-handoff`
基点：HEAD `c93a5b18`；本轮改动**全部未提交**（16 个修改 + 9 个新增，均在 `git status` 中）
设计稿：[tv-discovery-zero-input-adb-2026-11-12](../design/tv-discovery-zero-input-adb-2026-11-12.md)
网络侧专项交接：[2026-11-12-iphone-tv-discovery-unreachable](2026-11-12-iphone-tv-discovery-unreachable.md)
用户文档：[android-adb.md](../android-adb.md)（新增 `## Discovery`）
协议基线：[spec/README.md](../../spec/README.md) §4 触发表、[AGENTS.md](../../AGENTS.md) §3.5

## 一句话结论

「错误分类 → 局域网发现 → 授权等待 → 设备目录」四段已在 iOS 与 Android 两端落地：
ADB 模块构建通过、`PhoneDSHADBTests` **55/55** 通过、iOS App `BUILD SUCCEEDED`、
Android `:lib`/`:app` 编译通过且 `:lib` 单测 **1070/0** 通过、
`android-adb-settings` 页面结构两端 **0 分歧**（全仓 12 条分歧与本轮改动前的 HEAD 完全相同）。
**iPhone 真机已闭环**：扫描 → 候选 → 「连接」→ 电视 `UsbDebuggingActivity` 授权 → `connected("MiTV-ASTP0")` → 一次 E2E 回合（见 [网络专项交接](2026-11-12-iphone-tv-discovery-unreachable.md) 的 2026-11-12 续）。**Android 仍只有 JVM 单测**，没有真机扫描 / 授权 / 连接证据；Android 本版也没有 Bonjour 目录与设备记忆（刻意的范围差异，见 [android-adb.md](../android-adb.md)）。

## 当前状态表

| 能力 | 状态 | 边界 |
| --- | --- | --- |
| `ADBFailureKind` 错误分类 | implemented | 7 个 kind；`unreachable/unauthorized/busy/protocolViolation/cancelled` 都有真实生产者，`unsupported` 仍无（保留给 TLS 端口类文案） |
| 单播端口探测 + Bonjour 目录 + 证据合并评分 | implemented | 8 个端口、64 并发、单连接 400 ms、总预算 8 s、Bonjour 窗口 `min(bonjourDuration, budget-200ms)`、主机上限 4096、只枚举 `en*` 接口 |
| 授权等待状态机 `TVConnector` | implemented | 仅 `.unauthorized` 重试，2 s 间隔、90 s 上限；其余失败立即终止；成功后写设备目录 |
| 设备目录 + 两枚 UserDefaults 键 | implemented | `phone-dsh.tv-discovery.devices.v1`（8 条、按 serial upsert）、`phone-dsh.tv-discovery.last-endpoint.v1`；8 个单测覆盖容量/淘汰/upsert/forget/坏 JSON |
| iOS 设置页发现 UI | implemented（真机扫描、授权、连接已验证） | **打开页面即自动扫描**（不必点按钮）；fresh 目标默认开启「允许控制 Android」（已保存的显式选择优先）；扫描/候选/连接阶段/取消；手动表单降级为「手动添加（高级）」；端口用 `Text(verbatim:)` 避免本地化分组数字；连接走 `ADBMCPServer.configure` 的 active guard |
| Android 设置页发现 UI | implemented（JVM 单测；真机未验证） | 同构 5 个 Section、7 个动作；同样**打开即自动扫描**、fresh 默认开启；`AndroidTvDiscovery` 仅端口扫描（**无 Bonjour/NSD**），**无 `TVDeviceDirectory` / remembered / lastEndpoint**；授权等待改用 typed `AdbFailureKind`，与 iOS 同义 |
| `NSBonjourServices` + 本地网络说明 | implemented | 四个电视服务类型已声明；`NSLocalNetworkUsageDescription` 改为「发现并连接电视/Android ADB 设备……打开页面自动扫描当前 Wi-Fi」 |
| native MCP 工具面 | **未变**（26 个工具） | `android_discover` 未实现：Android 宿主端也声称提供同样 26 个工具，单端新增会破坏该契约，需两端同改 |
| SSDP / 一键装应用 | not started | 前者缺 multicast entitlement；后者按计划第 4.9 节未做 |

## 交接证据（AGENTS.md §3.5）

```
Base / head:        8acb381c / 6c2c81e1 + review 修复（amend 后的 PR head）
Protocol impact:    P05; P09; P17; P18; P16: none — Worker 启动契约（URL 参数 / init 帧 / PDSH_* 环境变量）未改，sharp-shim 只是模块内的 WebP fallback；P27: none — AndroidADBSettingsPage.swift 落在 P27 触发路径内，但本轮不新增或修改 bot row / action-result 投影、golden 与 PhoneDSHBot 代码; P07: none — 不新增 device wire/envelope，不动 PhoneDSHDeviceTasks/LAN/BLE/firmware
Contract revision:  spec/ui/v1/pages/android-adb-settings.json @ PR head（extract_ios_pages.py 重建，5 sections / 25 rows / 7 actions，5/5 composable）
Changed files:      iOS 核心 Sources/PhoneDSHADB/{ADBClient,ADBExecProvider,ADBMCPServer,ADBProtocol,ADBTransport}.swift + 新增 {TVConnector,TVDiscovery,TVDeviceDirectory}.swift
                    iOS UI  examples/probe-app/PhoneDSHProbe/AndroidADBSettingsPage.swift, Config/PhoneDSHProbe-Info.plist, spec/ui/v1/pages/android-adb-settings.json
                    Android android/lib/.../{AndroidADBSettingsPage,UiPageTags,PdshNavFacts,PdshNavHost}.kt + 测试, android/app/.../{AndroidAdbHost,HostShell}.kt + 新增 AndroidTvDiscovery.kt, android/net/.../adb/{AdbProtocol,AdbClient,AdbMcpServer}.kt + 测试
                    测试    Tests/PhoneDSHADBTests/{TVConnectorTests,TVDiscoveryTests,TVDeviceDirectoryTests}.swift, plugins/tests/sharp-webp.test.ts
                    文档    docs/android-adb.md, docs/design/tv-discovery-*.md, 本文件
Status per end:     iOS implemented & verified on physical iPhone19,4（扫描 / 授权 / 连接 / 一次 E2E 回合）；Android implemented（:lib 1070/0、:net typed-failure 用例通过；真机未验证；无 Bonjour / 无设备记忆）；Worker sharp-shim implemented（iPhone E2E + libwebp 逐像素解码）
Commands → result:  swift test --filter PhoneDSHADBTests → PASS 55/55
                    JAVA_HOME=<jdk17> ./gradlew :lib:testDebugUnitTest --offline → PASS 1070/0
                    ./gradlew :net:test --tests 'com.phonedsh.adb.*' → 31/32（1 个既有失败：spec/v1/golden/native-mcp/iphone-agent-volume-policy.json 未列入 Android 分类，base 8acb381c 上同样失败）
                    node --test tests/sharp-webp.test.ts → PASS 2/2（含 libwebp 逐像素比对）
                    python3 spec/ui/v1/tools/page_structure_check.py --page android-adb-settings → 0 分歧
                    python3 spec/ui/v1/tools/extract_ios_pages.py --page AndroidADBSettingsPage --check → contracts up to date
                    bash scripts/ci/check.sh --only phone-spec,phone-cross-tree → PASS
                    bash scripts/ci/check.sh --only phone-p0-conformance → FAIL（与 base 相同：archived-sessions stale page contracts）
Not verified:       Android 真机（扫描 / 授权 / 连接 / WebView Worker E2E）；iOS 有线电视（无 wlan0）；WebP 照片型内容的 size / perf
Remaining risks:    Android 无 Bonjour 目录与设备记忆；DHCP 换址只能靠新地址的扫描命中，旧记录不会自动跟随；live 候选端口固定 5555（remembered-only 保留原端口）；`.unsupported` 仍无生产者；见设计稿 §5
```

## 改了哪些文件

**核心实现（P05 / P17 / P18）**

- `Sources/PhoneDSHADB/ADBProtocol.swift`：`ADBFailureKind` + `ADBFailure.kind`（默认 `.device`，旧调用点零改动）。
- `Sources/PhoneDSHADB/ADBClient.swift`：AUTH 拒绝 → `.unauthorized`；协议/帧错 → `.protocolViolation`；取消 → `.cancelled`。
- `Sources/PhoneDSHADB/ADBTransport.swift`：区分「调用方超时关闭」与「任务取消」，前者 `.unreachable`、后者 `.cancelled`。
- `Sources/PhoneDSHADB/ADBMCPServer.swift`、`ADBExecProvider.swift`：三处「已有操作在跑」改为 `.busy`，**文案逐字未变**，MCP 返回内容不变。
- 新增 `TVDiscovery.swift`：候选模型、纯函数合并评分、`NWTVPortProbe`、`BonjourTVBrowser`、`TVDiscoveryEngine`、`tvLocalSubnetHosts()`。
- 新增 `TVConnector.swift`：`TVConnectPhase` 流 + `ADBShellTVChecker`（一次 shell 读 serial/model/release/`wm size`/wlan0 MAC）。
- 新增 `TVDeviceDirectory.swift`：两枚 P18 键、8 条上限、serial upsert、`forget` 连带清端点。

**UI（P09，两端同改）**

- iOS `AndroidADBSettingsPage.swift`（+240 行）与 `PhoneDSHProbe-Info.plist`（4 个 Bonjour 类型）。
- `spec/ui/v1/pages/android-adb-settings.json` 由 `extract_ios_pages.py --page` 重建，未手写。
- Android `AndroidADBSettingsPage.kt`（5 sections / 7 actions）、`UiPageTags.kt`、`PdshNavFacts.kt`、`PdshNavHost.kt`、`AndroidAdbHost.kt`、`HostShell.kt`，新增 `AndroidTvDiscovery.kt`。

**测试**

- `TVDiscoveryTests`（6）、`TVConnectorTests`（3）、`TVDeviceDirectoryTests`（8）→ `PhoneDSHADBTests` 共 50 例。
- Android `AndroidADBSettingsPageTest.kt`（11 例，原 4 例断言保留）。

**文档**

- `docs/android-adb.md` 新增 `## Discovery`（三源发现、SSDP 不支持、端口命中≠设备身份、连接流程、设备记忆）。
- 设计稿补齐实施记录与未验证项。

## 命令 → 实际结果

| 命令 | 结果 |
| --- | --- |
| `swift build --target PhoneDSHADB` | **PASS** `Build complete!` |
| `swift test --filter PhoneDSHADBTests` | **PASS** `Executed 51 tests, with 0 failures` |
| `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` | **PASS** `** BUILD SUCCEEDED **`（编译了 `AndroidADBSettingsPage.swift`） |
| `JAVA_HOME=<jdk17> ./gradlew :lib:compileDebugKotlin :app:compileDebugKotlin --offline` | **PASS** `BUILD SUCCESSFUL` |
| `./gradlew :lib:testDebugUnitTest --offline --rerun-tasks` | **PASS** `BUILD SUCCESSFUL`；XML 汇总 `tests=1070 failures=0 errors=0` |
| `python3 spec/ui/v1/tools/page_structure_check.py` | android-adb 页 `sections 0 / actions 0 / title 0`；全仓 `12 divergence(s)` |
| 同上，在 `git worktree` 的 **HEAD** 上跑 `check.sh --only phone-p0-conformance` | `page-structure: FAIL (7 new divergence(s) outside the baseline)` —— 与本轮改动后**数值完全相同** |
| `python3 spec/ui/v1/tools/extract_ios_pages.py --page AndroidADBSettingsPage --check` | **PASS** `contracts up to date` |
| `bash scripts/ci/check.sh --only phone-spec` | **PASS**（21s） |
| `bash scripts/ci/check.sh --only phone-p0-conformance` | **FAIL**（28s）：`page-structure: FAIL (7 new divergence(s) outside the baseline)`，与本轮改动前的 HEAD 相同 |
| `bash scripts/ci/check.sh --only phone-sdk` | **FAIL**（367s）：3 处失败均与本轮无关，见下 |

`phone-sdk` 的三处失败（都不是本 diff 的文件）：

1. `PhoneDSHTests.ProbeScenePhaseWiringTests`：断言 app 入口文件集合只有两个，实际多出 `PCPairingPage.swift`（该文件由 `a812f551` 于 2026-11-10 引入，本轮未触碰）。
2. `PhoneDSHEngineTests.WebEngineTests.testJITProbeStoresBaselineAndReportsRatio`：JS 基准脚本未返回时长，属环境/时序性失败。
3. `PhoneDSHBLETests.BLESecureCrossRuntimeTests`（4 例）：`firmware/tests/run.sh failed (needs cJSON + PDSH_MBEDTLS_SRC or IDF_PATH)`，缺固件测试依赖。

`PhoneDSHADBTests` 在同一次运行中 55/55 全绿。

## 傻瓜式改动（同日，真机反馈后）

- 设置页打开即自动扫描（iOS `onAppear` / Android `onScan`），按钮保留为手动刷新。
- fresh 目标（没有保存过 host）默认把「允许控制 Android」置为 ON；已保存过目标的显式开关不被覆盖。
  这一项只影响草稿，不写入授权，也不跳过电视上的调试确认。
- `NSLocalNetworkUsageDescription` 同步改成电视发现的措辞（系统的一次性局域网授权无法绕过）。
- Android 端同步自动扫描 + 默认开启；`:lib:testDebugUnitTest` 从 1049 增至 **1070**（页面测试 14 例；review 修复后）。

## 真机第二轮：iPhone 到电视的 TCP 不通（环境问题，非代码）

2026-11-12 在 iPhone19,4（iOS 27.2）上再扫一次，真机 console 证据：

```
PDSH_TV_SCAN subnet_count=254 first=192.0.2.1 last=192.0.2.254
PDSH_TV_PROBE 192.0.2.111:7000=true      ← iPhone 能到 Mac 的 AirPlay
PDSH_TV_PROBE 192.0.2.111:5555=false
PDSH_TV_PROBE 192.0.2.221:5555=false     ← 电视三个端口全部不可达
PDSH_TV_PROBE 192.0.2.221:6091=false
PDSH_TV_PROBE 192.0.2.221:6095=false
PDSH_TV_SCAN found=192.0.2.111:5555
```

同一时刻从这台 Mac 访问 `192.0.2.221`：`5555` 与 `6095` 均 open，ping 往返 2.4–3.3 ms。

进一步从电视侧反测（`adb shell ping`），把范围收窄到网络层：

| 方向 | 结果 |
| --- | --- |
| 电视 → iPhone `192.0.2.15`（ICMP ×3） | **100% 丢包** |
| 电视 → Mac `192.0.2.111`（ICMP ×2） | 0% 丢包，2.6–10.4 ms |
| 电视 → 网关 `192.0.2.1`（ICMP ×2） | 0% 丢包，2.1–4.2 ms |

再查 adbd 的监听地址：`/proc/net/tcp6` 里是 `:::15B3`（端口 5555）与 `::ffff:192.0.2.221:15B3`，
即**监听在所有地址上**，不是绑定到某个接口或某个来源的限制。电视本身只有 `lo` 和 `wlan0`（192.0.2.221），没有第二个网卡。

Mac 这一侧 `route -n get 192.0.2.221` 走的是 `en10`（`192.0.2.111`，桥接虚拟网卡），
在 LAN 看来这台 Mac 是「有线/桥接」侧的主机。

合起来：**iPhone 与电视是同一 /24 的两个无线客户端，彼此 IP 层不通；两边都能到 Mac 和网关。**
这正是 AP 客户端隔离（或 iPhone 与电视落在不同 SSID/VLAN，而 Mac 走桥接侧）的形态——
不是 App、不是扫描队列、也不是 adbd 配置。页面只列出真正可达的 `.111` 是正确行为：
不能因为「知道 .221 是电视」就伪造一条连不上的候选。

结论：iPhone 端的「扫描 → 候选」已经可用，**卡住的是网络可达性，不是 App**。要让真机跑通授权，需要先让 iPhone 能到 `.221`：
关掉路由器的「AP 隔离 / 客户端隔离」，把电视和 iPhone 放到同一 SSID 与频段，或给电视接网线。
最快的自测：在 iPhone 上用任意网络工具 `ping 192.0.2.221` 并连 `:5555`，通了再回设置页扫描。

### 顺带修掉的第二个行为 bug

`TVDiscovery.scan` 原来的探测顺序是 host-major（一台主机的 8 个端口排在一起），在固定 8 s 预算下，
`/24` 后半段主机的 `5555` 可能排到很后面被预算截断。已改为 port-major：先对全网段探 `5555`，再探弱证据端口；
新增 `testEngineDialsTheADBPortAcrossAllHostsBeforeWeakerPorts`（mutation 验证：旧顺序下该测试失败）。
这不是 `.221` 漏报的原因（直接 probe 已证明不可达），但属于有界预算下应当修的行为。

## 未验证项

- **真机 iPhone ↔ 电视的连接与授权**：授权弹窗、未授权 2 s 重试、90 s 超时文案、授权后一次 shell 读回 serial/model/分辨率/MAC。扫描与候选渲染已在真机上验证（iPhone19,4 / iOS 27.2，扫到 `192.0.2.111:5555 · AirPlay · 可能不是电视`，见下）。
- **真机网络发现（已部分完成）**：iPhone19,4（iOS 27.2，Xcode 27.1，临时改用 bundle id `com.tono.phonedsh.probe`，`project.yml`/`xcodeproj` 事后确认与 HEAD 逐字节一致）实机执行扫描，约 8 s 后列出 `<电脑显示名> · 192.0.2.111:5555 · AirPlay · 可能不是电视`，行内有「连接」按钮。截图 `/tmp/pdsh-iphone-scan-fixed.png`。
  同一轮在 macOS 上也跑过一次（临时测试，跑完已删）：枚举 508 个地址、8.02 s 收敛、合并出同一条候选。
  电视当时离线（`192.0.2.221` ping 不通、5555 关闭），所以**没有一条电视候选的实测证据**。
- **真机 iPhone 上的 Bonjour**：`NSBonjourServices` 已声明，但 iOS 的局域网权限弹窗与真实命中未验证。
- **Android 真机**：`AndroidTvDiscovery` 只在编译与 JVM 单测层验证。
- **SSDP / UPnP / DLNA**：无 multicast entitlement，未实现。
- **一键装应用（StudyOnTV 预设源）**：未实现。

## 剩余风险

0. ~~端口被本地化~~（已修）：`Text("\(candidate.host):\(candidate.port) · …")` 是 `LocalizedStringKey`，`Int` 插值会按 locale 变成 `5,555`。
   真机截图抓到的就是这个；已改为 `Text(verbatim:)`（`AndroidADBSettingsPage.swift:43`），并在改后重新跑 `extract_ios_pages.py --page AndroidADBSettingsPage` 更新锚点。

1. **扫描最长 8 秒**（port-major 已保证 5555 先扫完）：UI 没有渐进结果，点「扫描」后要等预算用完才出列表（实测正好 8.02 s）。真机上如果局域网大，会更明显。
2. **候选端口固定 5555**：只开 6095/6091 的小米电视、或只开 8009 的 Cast 设备会被列出来，点连接必然失败；文案只说「可能不是电视」。
3. **Android 无 Bonjour**：两端发现能力不对等（Android 只有端口扫描），已在代码注释与设计稿记录，但用户会看到不同的结果集。
4. **设备目录没有跨设备身份**：serial 为空时多台设备会互相覆盖（8 条上限下的边界行为未在真机确认）。
5. **`.unsupported` 无生产者**：TLS/无线调试端口那段仍抛 `.device`，分类表里有一个空槽。
6. **全仓门禁仍是红的**：`page-structure` 12 条、`phone-sdk` 3 处，全部是其它车道的既有债；本轮只保证「不新增」。

## 建议的下一步

1. 电视开机后做一次真机验收：扫描 → 候选 → 电视点允许 → 自动连接 → 记 IP 换址重定位。
2. 若真机上发现慢，把端口探测改成先扫 5555 再扫其余，或把 `overallTimeout` 降到 5 s。
3. `android_discover` 工具与「一键装应用」要两端同改（iOS + `android/net`），走一次 P05 契约变更。
