# TonoLink：首次学习投屏路线，之后无人值守重连；对话页启动不再闪「引擎还没启动」

```yaml
change: PC-20261113-tonolink-mirror-route
contracts: [P07, P09, P18]
status: implemented
breaking: false
version_decision: Additive. Two optional members in the existing app-private UserDefaults layout record; no board API, wire field or endpoint change.
base: 06a80094 (main, after PR #157 merged)
contract_revision: none (no owning spec text changes; the board HTTP API used is the existing /v1/phone/status and /v1/hid/*)
```

Protocol impact: P07; P09; P18. P07 — 只用既有板子接口（`/v1/phone/status` 的 `airplay.mirror_active`、`/v1/hid/*`），新增的只是 iOS 端怎么用它们。P09 — 对话页启动期的空状态与 TonoLink 调试中继新增的 `/agent/learn-mirror` 路由（DEBUG）。P18 — UserDefaults `phone-dsh.tonolink.phone-layout.v1` 新增两个可选成员。

## 1. 触发 → 现状 → 期望

- **投屏**。UI-Venus 操作 iPhone 要先有 AirPlay 屏幕镜像（板子是接收端）。镜像一断（锁屏、拔线），`prepare()` 会盲点「小圆点 → 控制中心 → 屏幕镜像 → 板子」，但这些坐标是另一台手机写死的默认值，从没按用户的手机校准，所以基本点不中，用户只能每次自己在控制中心选一次。另外镜像断开后取屏器仍保留最后一帧，`prepare()` 把它当成「画面在线」，根本不去重连。
- **期望**：用户第一次手动投屏后，App 在下一次手机任务前自动学会这台手机的路线；之后镜像断开时，下一次任务开始前自动连回板子，失败时停在主屏并告诉用户怎么做。
- **对话页**：App 每次启动都会自动启动引擎，启动的那一两秒里对话页显示「引擎还没启动 / 正在启动…」卡片，用户每次都看到它闪一下。期望：启动中显示正常空对话；只有真的没启动起来（失败、被停掉，或 3 秒内没人启动它）才显示那张卡片。

## 2. 改动

| 位置 | 改动 |
| --- | --- |
| `Sources/PhoneDSHBLE/TonoLinkPhoneHands.swift` | `TonoLinkPhoneLayout` 新增可选 `mirrorRouteLearned`、`mirrorStop`；`startMirroring()` 拆出 `openMirrorList()`；新增 `phoneStatus()`、`airplayName()` |
| `examples/probe-app/PhoneDSHProbe/IPhoneAgentHost.swift` | `prepare()` 先问板子 `mirror_active`；`learnMirrorRoute()` 在画面上逐步定位并核实每一步画面确有变化；`restartMirror()` 只盲点一次；首次未学习时不再盲点 |
| `examples/probe-app/PhoneDSHProbe/ChatModel.swift`、`ChatPage.swift` | `engineStartAttempts` 计数；空状态 A 只在启动结束仍无引擎或 3 秒宽限后显示 |
| `examples/probe-app/project.yml` | `PhoneDSHDeviceTests` 补上 `NativeStreamDraftStore.swift`（main 上 `PhoneDSHSimTests` 已加、真机孪生目标漏加，导致真机测试编译失败） |
| `examples/probe-app/PhoneDSHDeviceTests/TonoLinkMirrorDeviceTests.swift` | 新的真机测试 |

### 学习路线（`learnMirrorRoute`）

前提是镜像在线（画面就是它读的东西）。步骤：在画面上找小圆点（不信任保存的位置，用户会拖动它）→ 点开菜单（画面平均差 ≥ 6）→ 找「控制中心」（不能和小圆点重合）→ 点开控制中心（差 ≥ 12）→ 找「屏幕镜像」→ 点开设备列表（差 ≥ 2，列表是小弹窗）→ 找板子那一行、「停止镜像」、最后一个设备行 → Esc + 回主屏关掉控制中心。**从不点板子那一行**，所以运行中的镜像不受影响。UI-Venus 在目标不存在时也会给出坐标，所以每一步都以画面变化为准，而不是以模型回答为准。

### 列表几何（真机实测，iPhone19,4，iOS 27.2）

- 投屏中，列表 = 设备行 + 分隔线 + 「停止镜像」。未投屏时没有后两项，弹窗**底边不动**，所有设备行整体下移这一段的高度。
- 实测：未投屏时点「投屏中学到的板子行」，手机去连了它上面的「李光浩的电脑」（longshu 的 AirPlay 接收端同时出现活动）；点「停止镜像」原来的位置，6 秒内板子报告 `mirror_active=true`，longshu 无活动。
- 因此保存的 `mirrorTarget` 是**未投屏时**板子的行：投屏中的行 + （停止镜像 − 最后一个设备行）。

### 为什么只盲点一次

App 无法知道一次盲点连到了哪个接收端：iOS 不把 AirPlay 镜像报告成第二块屏幕（`UIScreen.screens.count == 1`）；音频路由只在 App 启动瞬间显示 `AirPlay|TonoLink USB`，App 自己的音频会话起来后约 0.5 秒就变回扬声器。所以重连只点学到的那一个位置，10 秒内板子没报告镜像就回主屏并提示用户，不尝试第二个猜测。

## 3. 相容性

| 方向 | 行为 |
| --- | --- |
| 旧数据 → 新 App | 旧 layout JSON 没有新成员，解码为 nil = 未学习：不盲点，首次提示用户手动投屏；之后自动学习 |
| 新数据 → 旧 App（回滚） | `JSONDecoder` 忽略未知成员；旧 App 使用学到的坐标盲点（它不知道未投屏时行会下移，仍按 `mirrorTarget` 点，而新 App 存的正是未投屏位置，所以回滚后反而更准） |
| 板子固件 | 不变。`/v1/phone/status` 不报告接收端名称时用 Kconfig 默认名 `TonoLink USB` |

## 4. 命令 → 结果（2026-11-13，Mac Studio 构建签名，longshu 上的 iPhone `00008160-00023D1C2240000A`，iOS 27.2，板子 `PhoneAgent-7356`）

- 真机 `TonoLinkMirrorDeviceTests/testProbeState` → PASS（只读：镜像在线，720×1048 画面）
- 真机 `testLearnRouteThenRestartMirrorUnattended` → 学习与「停止镜像」PASS；最后一步在本记录修复 `prepare()` 用旧帧判断在线之前 FAIL（0.04 s 返回、没有重连），修复后未重跑完整的三步版本
- 真机 `testPrepareRestartsADroppedMirror`（镜像已断、路线已学）→ PASS：`prepare()` 用 24.9 s 自动连回板子，板子 `mirror_active=true`，取得重连后的新帧
- 真机几何实验（见 §2）→ 结论如上；测试本身未保留在仓库
- `swift test --filter 'TonoLink|DevicePanel|LinkAdmission|IPhoneAgent'` → PASS（93 tests）
- `python3 spec/ui/v1/tools/extract_ios_pages.py` → 重新生成 `chat`、`runtime-details` 页面契约（只有行号相关字段变化）
- 对话页启动不闪：真机测试进程启动时的截图显示正常空对话（Phone DSH 图标），不是「引擎还没启动」卡片；没有逐帧录像证据

## 5. 未验证 / 剩余风险

- **接收端列表变化**：学习之后若出现新的 AirPlay 接收端（例如排在板子后面的电视），未投屏列表里板子行的位置会变，盲点可能连到别的设备，而 App 无法察觉。缓解：每次任务前看到画面且路线未学习时才学习；失败后用户手动投屏一次，下一次会按新画面判断（目前只在 `mirrorRouteLearned != true` 时学习，**已学习的路线不会自动重新学习**，这是待做项）。
- **重连期间会动用户的手机**：回主屏、打开控制中心，约 25 秒。只在手机任务开始前、镜像已断时发生。
- 收尾关闭控制中心（Esc + 回主屏）在真机截图里没有得到清晰证据：重连后的第一张新帧仍显示控制中心与辅助触控菜单，下一次启动时手机在 App 内。
- 只在一台 iPhone、一个 iOS 版本、一块板子上验证；横屏、其他控制中心布局、辅助触控菜单里没有「控制中心」项的情况未测。
