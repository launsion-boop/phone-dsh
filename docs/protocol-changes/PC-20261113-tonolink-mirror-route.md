# TonoLink：首次学习投屏路线，之后无人值守重连；对话页启动不再闪「引擎还没启动」

```yaml
change: PC-20261113-tonolink-mirror-route
contracts: [P07, P09, P18]
status: implemented
breaking: false
version_decision: Additive. Three optional members in the existing app-private UserDefaults layout record; no board API, wire field or endpoint change.
base: 06a80094 (main, after PR #157 merged)
contract_revision: none (no owning spec text changes; the board HTTP API used is the existing /v1/phone/status and /v1/hid/*)
```

Protocol impact: P07; P09; P18. P07 — 只用既有板子接口（`/v1/phone/status` 的 `airplay.mirror_active`、`/v1/hid/*`），新增的只是 iOS 端怎么用它们。P09 — 对话页启动期的空状态与 TonoLink 调试中继新增的 `/agent/learn-mirror` 路由（DEBUG）。P18 — UserDefaults `phone-dsh.tonolink.phone-layout.v1` 新增三个可选成员（`mirrorRouteLearned`、`mirrorStop`、`mirrorRouteLearnedAt`）。

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

### 路线何时重新学习

学过的路线会过时：接收端会出现或消失（开一台电视会让列表行移动），用户也会拖动小圆点。以下情况把路线标为需要重新学习，下一次任务前只要画面在线就重新学（每个路线版本每次启动最多尝试一次，失败不会在每个任务前重复）：

| 触发 | 处理 |
| --- | --- |
| 自动重连失败 | 路线**作废**：不再盲点；提示用户手动投屏一次，投屏后自动重新学习 |
| 回主屏时发现小圆点不在保存的位置 | 路线作废（菜单跟着小圆点走，「控制中心」的位置也变了） |
| **每次手机任务开始、画面在线时**，小圆点不在保存的位置（最多每 60 秒查一次，需连续两次看到同一新位置） | 更新小圆点位置、路线作废，并在同一次准备里立即重新学习 |
| **投屏断开、Phone DSH 在前台时自动重连**：第一下点保存的小圆点位置，点在 App 自己的一层透明窗口上（`TonoLinkTapProbe`） | 窗口接到了这一下 = 小圆点不在那里：路线作废，不打开控制中心，提示用户手动投屏一次；窗口没接到 = 辅助触控接走了、菜单已打开：从菜单继续往下走（不再先回主屏） |
| 学习时间超过 7 天，或没有学习时间（旧版本学的），或学习时间在未来（改过时钟） | 继续可用于盲点重连，但下次画面在线时重新学习 |

任务开始时的检查在 `prepare()` 挂上板子键盘之后进行：外接键盘会让系统软键盘收起，所以不会把小圆点在键盘上方的临时位置误判为被拖动。

**未投屏位置的推算改为只用两个有文字的锚点。** 第一次重新学习的真机运行里，用 UI-Venus 找「列表最后一行」得到的位置不可靠，算出的未投屏位置是 812（正确应约 850）。现在的规则：板子行到「停止镜像」的间隔 ≤ 120（千分比；实测仅有分隔线和停止镜像时为 91，多一行约再加 63）时，板子是最后一行，未投屏位置就是「停止镜像」原来的位置（真机已验证能连上板子）；否则不保存盲点路线，断开后请用户手动选择。

判定逻辑在 `TonoLinkPhoneLayout.mirrorRouteNeedsLearning(now:)`／`mirrorRouteUsable`，由 `TonoLinkPhoneLayoutTests` 覆盖。

### 断开期间怎么发现小圆点被拖动

投屏断开时 App 看不到屏幕；iOS 不提供小圆点位置，也没有任何辅助触控事件；板子的 ⌘H／⌘Space 在这台 iPhone 上无效。但 Phone DSH 在前台时，可以在自己的界面上盖一层看不见的窗口（不透明度 0.011，窗口层级 alert+2）。真机实测：板子指针在小圆点上按下，按键被辅助触控接走（菜单打开），窗口收不到；在别处按下，窗口精确收到这一下（(500,400) 收到 (500.0, 400.2)），并且把它吞掉，App 里的按钮不会被按到。Esc 关不掉辅助触控菜单；悬停事件只送到一部分，所以用点按而不是悬停。

App 不在前台时（例如语音任务时用户在别的 App 里）做不了这个检查，重连照旧：先回主屏再按路线点，点空了才作废。

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
- `swift test --filter TonoLinkPhoneLayoutTests` → PASS（4 tests：旧数据不可盲点、7 天后重学、无日期重学、作废后不可用且可往返编码）
- 真机 `testDraggedAssistiveButtonIsFoundAtTheNextTask` → 前半 PASS：用板子指针把小圆点从 (913,844) 拖到 (85,524)，下一次 `prepare()` 用 22.8 s 发现并重新学习（新的控制中心位置 (514,578)），镜像保持在线。后半 FAIL：拖回原位只到了 (813,940)，「回到原位」断言失败；这次运行也暴露了「最后一行」推算不可靠（见 §2），已改规则
- 真机 `testPutAssistiveButtonBack`（新规则）→ 检查发现小圆点被移动、重新学习，未投屏位置 (328,849) = 停止镜像位置
- 2026-11-13 板子刷入 LED 固件（`ota_1`）后，镜像随板子重启断开：真机 `testPrepareRestartsADroppedMirror` → PASS，App 在前台，走「先点一下核对小圆点」的路径，20.2 s 连回（以前先回主屏约 25 s）
- 真机 `testRestartChecksTheButtonWhenTheAppIsInFront`（由板子 `POST /cmd airplay off/on` 断开镜像，App 留在前台）→ PASS：20.3 s 连回并取得新帧
- 真机 `testButtonDraggedWhileTheMirrorIsDownIsCaught` 第一次运行 → 检测部分 PASS：镜像断开时把小圆点从 (917,815) 拖到 (88,470)，下一次 `prepare()` 抛出「辅助触控小圆点的位置变了，没有自动投屏…」，路线作废，没有开始任何镜像，App 仍在前台（没有打开控制中心）。同一次运行的「放回原处」步骤 FAIL（测试脚手架问题，不是产品代码）：板子一次 batch 最多 64 步，长距离拖动被拒（422 `too_long`）；探针扫描从 y=150 开始，正好按在这台 iPhone 右侧竖排的状态栏上（约 y 90–220），系统接走这一下，App 离开前台
- 脚手架修正后：拖动拆成每段 ≤250 的短程；扫描从 y=260 开始；探针窗口显示不了时直接跳过而不是误报「找到」。`testRestoreButtonAndMirrorBlind` → PASS：用探针找到小圆点 (916,780)，确认 (917,815) 按下会被辅助触控接走，路线重新标记后 `prepare()` 连回镜像。拖动过程中用 `xcrun devicectl device capture screenshot` 在 longshu 上看手机（开发工具，不是产品路径）
- 修正后完整重跑 `testButtonDraggedWhileTheMirrorIsDownIsCaught` → NOT_RUN：手机开始拒绝启动测试包（「Developer App Certificate is not trusted」），屏幕上同时出现 Apple 账户登录请求对话框，需要手机主人处理
- 真机 `testPrepareRelearnsAnInvalidatedRouteThenRestarts` → PASS：路线作废后，`prepare()` 在画面在线时 24.3 s 内重新学会路线；随后沿新路线停止投屏，下一次 `prepare()` 24.8 s 自动连回板子并取得新帧。这也补上了「学习 → 停止 → 自动重连」三步的完整证据
- `python3 spec/ui/v1/tools/extract_ios_pages.py` → 重新生成 `chat`、`runtime-details` 页面契约（只有行号相关字段变化）
- 对话页启动不闪：真机测试进程启动时的截图显示正常空对话（Phone DSH 图标），不是「引擎还没启动」卡片；没有逐帧录像证据

## 5. 未验证 / 剩余风险

- **接收端列表变化**：学习之后若出现新的 AirPlay 接收端（例如排在板子后面的电视），未投屏列表里板子行的位置会变，盲点可能连到别的设备，而 App 无法察觉。缓解：路线 7 天重学一次；重连失败即作废、不再盲点。但在两次学习之间出现的新接收端，仍可能让一次盲点连到别的设备。
- 小圆点检查每次任务开始多一次 UI-Venus 调用（60 秒内的连续任务不重复）。镜像断开期间被拖动的小圆点，只有 Phone DSH 在前台时能在重连的第一下发现；App 在后台时仍要等重连失败才作废。
- 前台检查假定那一下要么落在辅助触控上、要么落在 App 的透明窗口上；若正好落在状态栏等系统窗口上，会被当成「小圆点还在」，之后的盲点失败再作废。
- 重连成功后的收尾是 Esc + 回主屏，所以从 App 里触发的重连结束时手机停在主屏，而不是回到 App。
- 板子不是设备列表最后一行（有名字排在它后面的接收端）时不支持自动重连。
- 7 天重学的路径只有单元测试，没有在真机上等满 7 天。
- **重连期间会动用户的手机**：回主屏、打开控制中心，约 25 秒。只在手机任务开始前、镜像已断时发生。
- 收尾关闭控制中心（Esc + 回主屏）在真机截图里没有得到清晰证据：重连后的第一张新帧仍显示控制中心与辅助触控菜单，下一次启动时手机在 App 内。
- 只在一台 iPhone、一个 iOS 版本、一块板子上验证；横屏、其他控制中心布局、辅助触控菜单里没有「控制中心」项的情况未测。
