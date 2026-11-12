<!-- SPDX-License-Identifier: MIT -->
# 交接提示词：iPhone 扫不到客厅 Redmi 电视（同网段但 TCP 全被挡）

日期：2026-11-12
分支：`codex/tonolink-volume-voice-keyboard-handoff`
HEAD：`c93a5b18`（工作树未提交；不要执行 git commit/checkout/stash/reset）
相关文件：[tv-discovery 交接](2026-11-12-tv-discovery.md)、[设计稿](../design/tv-discovery-zero-input-adb-2026-11-12.md)

## 复制给下一个代理的提示词

> 你在仓库 `/Users/macbook/Documents/phone-dsh` 工作（Swift + Kotlin 双端，phone-dsh）。
> 问题：iPhone 上的 Android ADB 页面自动扫描不到局域网电视 `192.0.2.221`（Xiaomi/Redmi，`MiTV-ASTP0`，SSDP 名称「<电视显示名>」）。用户说电视能 ping 通（2.4ms）、ADB 5555 开放、Mac 上 `adb devices` 显示 `device` 且授权保留。页面只显示 `192.0.2.111:5555`（Mac/AirPlay），没有电视。
>
> **已经确认的事实（不要重复推翻，先读证据）**
> - Mac `192.0.2.111`（en10 有线）到电视：`adb devices -l` → `192.0.2.221:5555 device product:mulan model:MiTV_ASTP0`；TCP `49152(DLNA)/5555/6091/6095` 全 open；`curl http://192.0.2.221:49152/description.xml` 返回 friendlyName「<电视显示名>」、manufacturer Xiaomi。
> - iPhone `192.0.2.15`（IPv4 接口只有 lo0/en0，未发现 utun）到电视：Network.framework `NWTVPortProbe` 和独立 BSD `connect()` 对 `49152/5555/6091/6095` **全部 false**；到 Mac `192.0.2.111:7000` **true**；Mac 在 `.111:5555` 临时开 listener 时，iPhone 能连上（Mac 侧 `accepted ('192.0.2.15', ...)`）。
> - `tvLocalSubnetHosts()` 返回 254 个主机 `.1-.254`，包含 `.221`；所以不是主机枚举漏了。
> - 断开 Mac 的 `adb disconnect 192.0.2.221:5555` 后，iPhone 仍连不上电视，排除“电视只允许一个 ADB host”。
> - iPhone 原始 SSDP multicast `sendto` 返回 `errno=65 (EHOSTUNREACH)`；项目没有 `com.apple.developer.networking.multicast` entitlement，首版不要通过 SSDP 解决。
> - App 扫描引擎不是问题：在引擎之外直接探测也失败；`TVDiscovery` 的 port-major 修复有回归测试，和这次漏报无关。
>
> **当前判断**：iPhone 的 Wi-Fi 到电视的 TCP 路径被 **电视侧 ACL/防火墙** 或 **AP/VLAN 隔离** 挡住，不是 ADB 授权、不是端口 5555 单点、不是 App 扫描逻辑。电视的 DLNA 端口 49152 同样不通，说明不只是 ADB。Mac 是有线 en10，所以能到电视；iPhone 能到 Mac 的任意 TCP，所以不是普遍的 Wi-Fi↔有线隔离，更像电视/路由器对 iPhone 的 ACL，或 iPhone 与电视同网段但不同 VLAN/SSID。用户说的 ping/5555 开放需要确认是从 **iPhone 本身** 还是从 Mac/另一台设备测的。
>
> **下一步（按顺序，先网络后 App）**
> 1. 让用户确认 iPhone 当前 Wi-Fi 的 SSID/VLAN，与电视（有线/无线）是否同一个；检查路由器是否开了 AP 隔离、访客网络、VLAN 隔离；Mesh 子节点/访客 SSID 换到主 SSID。
> 2. 在 **iPhone 本身** 上用 Network Analyzer/iNetTools 等测 `192.0.2.221:49152` 和 `:5555`：
>    - 两个都不通 → 路由/AP 或电视整机 ACL；
>    - 49152 通、5555 不通 → 电视的 ADB 防火墙/白名单。
> 3. 电视侧：`设置 → 网络/安全/开发者选项`，关闭“仅允许已授权设备 / ADB 白名单 / 网络隔离”，撤销 USB 调试授权，关/开网络调试，重启电视；允许 iPhone 的 `192.0.2.15`。Xiaomi/Redmi 的入口可能在 `账号与安全` 或 `通用设置 → 开发者选项`。电视若隐藏开发者选项，`设置 → 关于 → 产品型号` 连点 5–7 次。
> 4. 若电视有 Wi-Fi，查看其 Wi-Fi IP（可能不是 .221）并在 iPhone 当前 Wi-Fi 网段扫描；若电视只有有线，考虑把 iPhone 接到同一有线网络（USB-C Ethernet）或把电视接到同一 Wi-Fi。
> 5. 只有 iPhone 能 TCP 到电视后，重新打开 App 的 `我的 → 设置 → 权限与隐私 → Android ADB`；页面现在会自动扫描（不需要点“扫描局域网”），点「连接」，电视会弹 **新的** ADB 授权（Mac 的 `device`/授权是 Mac 的 adbkey，不复用于 iPhone App 的独立 key）。
> 6. 如果网络修好后仍不出现，再查 App：确认页面打开即扫描、候选里有 .221；不要留临时预览路由/debug print，`NativeShell.swift` 与 xcodeproj 要恢复到与 HEAD 一致。
>
> **不要做的事**
> - 不要改 `spec/`；不要伪造“已发现/已连接/已授权”；不要把不可达的 .221 列出来再让「连接」失败。
> - 不要声称在真机完成了电视连接，除非有 `adb`/页面状态/授权弹窗的实际证据。
> - 不要执行 git commit/checkout/stash/reset；不要删除用户的既有改动。
>
> **可在 App 里复现的路径**：打开 `Phone DSH`（当前真机安装的是本机临时签名 `com.tono.phonedsh.probe`），底部「我的」→「设置」→「权限与隐私」→「Android ADB」。页面打开会自动扫描；当前只会出现 `<电脑显示名> 192.0.2.111:5555 · AirPlay · 可能不是电视`。

## 现场细节

- iPhone：iPhone19,4（UDID `<UDID>`），iOS 27.2，Wi-Fi `192.0.2.15`。
- Mac：`192.0.2.111`（en10，AX88179B USB Ethernet）；en0 是 `192.0.2.215`；默认路由走 en0，但 `192.0.2.0/24` 走 en10。Mac 上 `adb` 在 `~/Library/Android/sdk/platform-tools/adb`。
- 电视：`192.0.2.221`，MiTV-ASTP0，DLNA `49152`，ADB `5555`，Xiaomi 服务 `6091/6095`。SSDP `LOCATION: http://192.0.2.221:49152/description.xml`。
- 真实日志（iPhone console，临时 debug 构建）：
  ```
  PDSH_TV_SCAN subnet_count=254 first=192.0.2.1 last=192.0.2.254
  PDSH_TV_PROBE 192.0.2.111:7000=true
  PDSH_TV_PROBE 192.0.2.221:5555=false
  PDSH_TV_PROBE 192.0.2.221:6091=false
  PDSH_TV_PROBE 192.0.2.221:6095=false
  PDSH_TV_PORT 192.0.2.221:49152=false
  PDSH_TV_PORT 192.0.2.111:7000=true
  PDSH_TV_SCAN found=192.0.2.111:5555
  PDSH_SSDP send errno=65
  ```
- Mac 侧：
  ```
  adb devices -l
  192.0.2.221:5555     device product:mulan model:MiTV_ASTP0 device:mulan transport_id:3
  python3 TCP 扫描：49152/5555/6091/6095 open
  curl http://192.0.2.221:49152/description.xml → friendlyName <电视显示名>
  ```

## 当前 App 代码状态（本轮已做，勿重复）

- iOS `AndroidADBSettingsPage.swift`：
  - 打开页面 `.onAppear` 自动 `scan()`（无需点按钮）；
  - 全新目标（无已保存 host）的「允许控制 Android」默认 `enabled = true`；已保存的显式关闭仍被尊重；
  - 候选端点用 `Text(verbatim:)`，避免端口 `5555` 显示成 `5,555`；
  - 连接成功后仍走 `ADBSettings.save(enabled: true, host, port)`。
- iOS `Config/PhoneDSHProbe-Info.plist`：本地网络用途说明加入电视自动发现；系统一次性 Allow 无法由 App 绕过。
- iOS `Sources/PhoneDSHADB/TVDiscovery.swift`：探测任务改为 port-major（先扫全网段 5555），`Tests/PhoneDSHADBTests/TVDiscoveryTests.swift` 新增顺序回归测试。
- Android `AndroidADBSettingsPage.kt`：同样打开页面自动 `onScan()`，fresh target 的开关默认 ON；`AndroidADBSettingsPageTest.kt` 14 例。
- 临时 SSDP/BSD/ICMP 探测、`-uiPreview settings.androidadb` 路由、自动 scan 参数均已删除；`NativeShell.swift` 与 `PhoneDSHProbe.xcodeproj` 已恢复到与修改前逐字节一致。

## 验证（本轮实际执行）

```
swift test --filter 'PhoneDSHADBTests'
Executed 51 tests, with 0 failures (0 unexpected)

xcodebuild ... -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
** BUILD SUCCEEDED **

gradlew :lib:testDebugUnitTest --offline
BUILD SUCCESSFUL；lib 共 111 classes / 1052 tests / 0 failures / 0 errors / 0 skipped
AndroidADBSettingsPageTest: 14 tests, 0 failures

gradlew :app:compileDebugKotlin --offline
BUILD SUCCESSFUL

page_structure_check.py：android-adb-settings sections 5/5、actions 7 labels、title 0，全部 divergences 0
```

真机：干净签名版 `com.tono.phonedsh.probe` 已安装在 iPhone19,4；页面打开自动扫描、开关默认 ON 已用截图确认。没有完成「连接电视 / ADB 授权 / 实际控制」——因为 iPhone 到电视 TCP 不通。

## 验收标准（下一位）

- 先给出「iPhone 本身」到 `192.0.2.221:49152` 和 `:5555` 的真实 TCP 结果（工具名 + 设备）。
- 然后才讨论 App：
  - 若 iPhone 能 TCP 到电视：重开页面应自动列出 .221，点连接应看到电视授权弹窗，授权后 `adb devices` 等价状态为 device，App 的 status 行出现「已连接：…」。
  - 若 iPhone 仍不能 TCP 到电视：记录为网络/电视侧阻塞，不要把失败写成 App 修复完成，也不要把 .221 伪造进候选。
- 保持 `spec/` 未改；不提交、不丢弃用户未提交改动。

## 2026-11-12 续：已定位根因并完成真机闭环验收

1. **路由器二层无线隔离根因与修复**：
   - 通过 `adb -s 192.0.2.221:5555 shell ip neigh show` 发现电视（`wlan0` 连 `<SSID-A>`）对 iPhone `192.0.2.15` 的 ARP 为 `FAILED`，而对有线 `en10` 的 Mac `192.0.2.111` 为 `REACHABLE`。
   - 登录 OpenWrt 路由器 `root@<gateway>` 查明 `wireless.default_radio0.isolate='1'`（`<SSID-A>` 开启了无线客户端二层隔离）。
   - 执行 `uci set wireless.default_radio0.isolate=0; uci set wireless.wifinet_<SSID-B>.isolate=0; uci commit wireless; wifi reload` 后，电视到 iPhone 的 ARP 立即变为 `192.0.2.15 dev wlan0 lladdr <MAC> REACHABLE`，ICMP 0% 丢包。
2. **iPhone 本身到电视 `49152` / `5555` 真实 TCP 结果**：
   - 设备：`iPhone19,4`（`<UDID>`，`192.0.2.15`），工具：`NWTVPortProbe`（`Network.framework` TCP）
   - 真实日志：`PDSH_TV_DIRECT 192.0.2.221:49152=true 192.0.2.221:5555=true`
3. **真机发现的 `ADBClient` 协议状态机 bug 与修复**：
   - 真机首次连接 `192.0.2.221:5555` 时，电视弹出 `com.android.systemui/.usb.UsbDebuggingActivity` 授权框并在 `AUTH(arg0: 3)` 后保持连接等待用户点击“允许”。超时或关闭时 `ADBPacket.read` 原本抛出 `.unreachable`（`ADB connection closed; check authorization and TCP/IP debugging`），导致 `TVConnector` 立即终止而非进入 `.awaitingAuthorization` 90 秒轮询。
   - 修复：`Sources/PhoneDSHADB/ADBClient.swift` 在 `authStep > 0` 握手阶段将非取消的 `.unreachable` 归类为 `.unauthorized`；`ADBShellTVChecker.summary` 单次探测超时设为 `4s`；`Tests/PhoneDSHADBTests/ADBProtocolTests.swift` 新增 `testConnectionClosedDuringAuthHandshakeReportsUnauthorized`（`PhoneDSHADBTests` 52/52 通过）。
4. **真机端到端发现 + 电视授权 + 连接成功证据**：
   ```
   PDSH_TV_DIRECT 192.0.2.221:49152=true 192.0.2.221:5555=true
   PDSH_TV_CANDIDATE 192.0.2.221:5555 name=<电视显示名> kind=androidTV score=100
   PDSH_TV_CANDIDATE 192.0.2.111:5555 name=<电脑显示名> kind=airplay score=50
   PDSH_TV_CONNECT_PHASE 192.0.2.221:5555 -> probing
   PDSH_TV_CONNECT_PHASE 192.0.2.221:5555 -> connected("MiTV-ASTP0")
   ```
   - 临时诊断钩子已全部移除，`NativeShell.swift`、`AndroidADBSettingsPage.swift`、`PhoneDSHProbe.xcodeproj/project.pbxproj` 均恢复至测试前逐字节一致（SHA-256 校验一致），干净版已重装回 iPhone 真机并启动。
