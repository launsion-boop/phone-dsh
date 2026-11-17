<!-- SPDX-License-Identifier: MIT -->
# 设备应用下发：Bot 写程序，用户确认，经 Link 装到设备（device-app-v1）

## 0. 摘要

```yaml
change: PC-20261117-device-app-push
contracts: [P07, P26]
status: frozen
breaking: false
version_decision: 无 Link wire 变更。新增一组设备自报的普通 Link 工具（app.*）和手机侧宿主工具；旧手机见到的只是不认识的工具名，旧设备没有这些工具即不是安装目标。
base: 1b20204a  # spec/device-bot-contract
contract_revision: device-app-v1.1  # spec/device/v1/device-app.md + schema/device-app-vector.schema.json + golden/device-app.jsonl (91 vectors, sha256 963187a6…3f7d), checker spec/v1/tools/test_device_app_golden.py
```

Protocol impact: P07; P26; P09: none — 设备应用的 UI 入口另出页面契约，本单只定名字「设备应用」; P18: none — 不新增持久化键，journal 回收是既有 Link journal 的清理，不改键名与格式; P25: none — 只新增一条 `ui.system_event`（`device.app.install`），事件 envelope 不变，若实现时发现需要新 schema 则回到本单修订; P27: none — 审批行沿用通用 `approval` 行，不加字段; P01/P02: none — 不碰通道编解码与 WAL。

## 1. 识别与角色

- 触发 → 现况 → 期望：
  - 触发：用户买了 FoloToy AI Passport（ESP32-C3，无 PSRAM，MicroPython），老板要求「一个 agent 一个 Bot」，希望该设备的 Bot 能写出精美的设备应用并装到设备上。
  - 现况：设备 Bot 已有契约（`device-bot-v1`），但没有任何下发设备代码的路径；Link 规范里没有安装工具；Passport 自带的 HTTP 管理口无认证，且能任意执行代码。
  - 期望：设备 Bot 经两个宿主工具把应用装到自己的设备上，每次安装都由用户在手机上确认；设备端只接受这条路径。
- 协调者兼 contract owner：本任务主 agent。
- Owning 契约：[device-app.md](../../spec/device/v1/device-app.md)、
  [schema](../../spec/device/v1/schema/device-app-vector.schema.json)、
  [golden](../../spec/device/v1/golden/device-app.jsonl)、
  [checker](../../spec/v1/tools/test_device_app_golden.py)。
- 受影响端：iOS（宿主工具、审批、静态检查、journal 回收、作者指南）；MicroPython 设备（Link 外设角色、安装器、运行时守卫，在仓库外的 speaker-touch-demo）；Android 不分配（GAP-20）。

## 2. 契约 delta

| 项 | 内容 |
| --- | --- |
| 字段／限额 | 文件 ≤ 8，单文件 ≤ 12288 字节，合计 ≤ 24576，`app.put` 原始字节 ≤ 2048（base64），会话空闲 120 s |
| 能力 | 设备自报工具 `app.info/begin/put/abort/commit/run/stop/remove`；`app.info` 返回 `protocol: device-app-v1` |
| 未知值 | 未声明这些工具或协议字符串不同的设备不是安装目标 |
| 回执 | `begin/put/abort/info` 为 staging，不占 Link 持久回执；`commit/run/stop/remove` 按 Link 回执与幂等规则不变 |
| 幂等 | `put` 以（会话、路径、偏移）可重放；`begin` 对同名同 digest 返回既有会话；提交原子换目录，旧应用在 commit 前不变 |
| 准入 | 7 个写工具 host-only：agent 来源的 `ble_link_call` 直接 `not_executed(host_only)` |
| 审批 | `DeviceAppInstall` 每次都弹一次性审批（含用户亲自发话的回合），绑定完整 digest，先审批后传输 |
| 静态检查 | token 级保守规则（§9），共享向量；设备端同表运行时守卫 |
| journal | 安装结束后回收该次安装的 staging 意图，不耗 4096 的终身额度 |
| 命名 | UI 叫「设备应用」，「小程序」保留给声明式面板 |
| 条款状态 | 全部 `target` |

自检（spec/README.md §5.1）：没有第二种信封或错误码；新工具均可选；不收紧或放宽任何两端共读的既有消息；没有重用或删除名称。

## 3. 相容性与发布

| Producer → Consumer | 处理 |
| --- | --- |
| 旧手机 → 新设备 | 手机把 `app.*` 当普通工具；agent 来源调用本就无法安装（旧手机无 host-only 规则，但这些工具在旧手机上只能由 agent 调用 → 设备必须自行要求配对窗口内绑定的链路，且设备端守卫与回收照常）。结论：旧手机可以调用，风险由「设备只接受绑定链路」与 §10 的设备要求兜底，发布说明须写明 |
| 新手机 → 旧设备 | `tools/list` 里没有 `app.*`，不显示安装能力 |
| 新 → 新 | 共享向量 |
| 旧数据 → 新 | 无持久化格式变更；设备上旧的 `/apps` 内容保持，`app.info` 列出但 digest 为空 |
| 回滚 | 回滚手机：不再能装；设备已装应用保留。回滚设备固件：`app.*` 消失 |

- 发布顺序：契约 → 并行实现（互不依赖，各自跑共享向量）→ 集成审查 → 真机联调（不在本单范围，需用户确认后另行进行）。
- 本单不刷机、不动串口。

## 4. 分工与证据

独占路径（实现者之间不得重叠）：

| 实现者 | 路径 |
| --- | --- |
| iOS 静态检查与摘要 | `Sources/PhoneDSHBot/DeviceApp/Validator/**`、`Tests/PhoneDSHBotTests/DeviceApp/Validator*` |
| iOS 安装编排（Link 调用、续传、journal 回收） | `Sources/PhoneDSHBLE/DeviceApp/**`、`Tests/PhoneDSHBLETests/DeviceApp*` |
| iOS Bot 工具、审批、作者指南、host-only 准入 | `Sources/PhoneDSHBot/DeviceApp/Tools/**`、对应测试；`Sources/PhoneDSHBLE/LinkToolCaller.swift` 仅加 host-only 判定 |
| Worker：审批门分类、per-caller 工具面（deny-unless-listed） | `plugins/bot-runtime/src/approval-gate.ts`、`plugins/bot-runtime/src/caller-catalog.ts`、`plugins/tests/bot-identity-approval.test.ts`、`plugins/tests/bot-caller-catalog.test.ts` |
| iOS 全调用方 `tools/list` 含两工具 | `Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift`（`toolDefinitions(callerBotID: nil)`）、`Tests/PhoneDSHBotTests/DeviceApp/DeviceAppToolsTests.swift` |
| MicroPython 设备端 Link 外设与安装器 | `speaker-touch-demo/passport-mpy/frozen/{link_peripheral,devapp,link_wire}.py` 与其测试 |
| MicroPython 运行时守卫与 HTTP 收紧 | `speaker-touch-demo/passport-mpy/frozen/{apprt,httpd,launcher,settings}.py` 的指定改动 |
| 设备应用样式库与示例应用 | `speaker-touch-demo/passport-mpy/frozen/kit.py`、`apps-golden/**` |

- 共享 fixtures：`spec/device/v1/golden/device-app.jsonl`（名字、路径、标题、manifest、digest、静态检查、put 规则）；Link 帧向量沿用 `golden/xiaozhi-ctl.jsonl` 与 `pdsh-link.jsonl`。
- 验收命令（`NOT_RUN` 直到实现者填写）：
  - `bash scripts/ci/check.sh --only phone-cross-tree` → PASS（契约编辑后，见交接记录）
  - `python3 -m unittest test_device_app_golden`（`spec/v1/tools`）→ PASS
  - iOS：`swift test --filter DeviceApp` → NOT_RUN
  - 设备端：host 上的 Python 单元测试（模拟 BLE）→ NOT_RUN
- 未验证：真机 BLE 吞吐与单调用延迟（无测量数据）、Wi-Fi+BLE 同开的内存余量、MicroPython 上 `esp32.NVS` 对 4 KB 以上 blob 的限制、配对窗口与 Just Works 的 MITM 风险。
- 剩余风险：静态检查是 token 级，不证明语法；设备端沙箱只能挡粗心生成，挡不住恶意；固件无签名，安全边界是配对加上用户逐次确认。

## 5. 修订记录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| device-app-v1 | 主 agent | 冻结；依据 5 份只读探索结果 | 6 个实现者（见 §4） |
| device-app-v1.1 | 主 agent | 收下 `kit` 导入变更请求（样式库实现者）；写入 `.devapp` 标记、`limits` 键名、提交遇运行中应用返回 `running`、按块计费的配额、EOF 词法错误行号、总大小由 DeviceAppStage 报告；oracle 改为完整匹配（结尾换行无效）并加 5 条向量；记录 `DeviceAppInstall` 自带审批、持久主体待决 | 全部实现者；设备端沙箱与安装器已按此改，iOS 校验器放行 `kit` |
| device-app-v1.2 | 主 agent（经 CCR 接受，由实现者代编辑契约） | 真机联调发现 Worker 只从全调用方 `tools/list` 注册 `mcp__phone__*` 工具，而 §10 把两个工具排除在该列表之外，模型看不到、调用得到 `unknown tool`；此前 Worker 审批门也未登记这两个名字，会以 `tool.unclassified`（session）送 `/approval`，被 App 以 `stale:always_scope` 拒绝 | Worker（审批门、caller-catalog）、iOS BotMCPRuntime、spec/bot/v1/tool-contracts.md §10、golden/tool-catalog.phone.json `deviceApp.note` |

## 6. CCR 与决定（device-app-v1.2）

```
CONTRACT CHANGE REQUEST
Contract: P26/P05 device-app tool surface @ device-app-v1.1  Clause: tool-contracts.md §10 last bullet
Problem: Worker 只从全调用方 tools/list 注册工具；per-caller 目录只能重述/隐藏已注册的 SendToAgent/CreateTeammate。设备应用工具只在 per-caller 目录 → Worker 永远没有注册 → unknown tool。
Proposal: (a) 宿主装了 device-app host 时，全调用方列表含两工具；(b) Worker caller-catalog 对这两个名字 deny-unless-listed：已识别调用方的 per-caller 目录不含时隐藏；(c) 宿主继续按 per-caller 目录拒绝未绑定调用方；(d) 修订 §10 与 golden 说明。
Decision: 接受（契约所有者）。
```

Worker 审批门（`approval-gate.ts` `AUTO_TOOLS`）：`DeviceAppStage`、`DeviceAppInstall`（裸名与 `mcp__phone__` 前缀）不产生 Worker effect、不走 `/approval`；Stage 是宿主 `read/auto`，Install 由 App 自己弹一次性、绑定 digest 的审批。近似名（如 `DeviceAppStageX`）仍是 `tool.unclassified`，不放宽。

### 相容性（device-app-v1.2）

| Producer → Consumer | 处理 |
| --- | --- |
| 新 App → 旧 Worker 镜像 | 全调用方列表多两个工具；旧 Worker 会把它们注册并对所有 Bot 可见（旧审批门把它们当 `tool.unclassified`/session，被 App 拒 `stale:always_scope`）。未绑定 Bot 的调用仍被宿主按 per-caller 目录拒绝。须同时更新 Worker 镜像 |
| 旧 App → 新 Worker | 全调用方列表没有这两个工具，Worker 无从注册；deny 对不存在的名字无效，其他工具面不变（无功能，无副作用） |
| 新 → 新 | 已绑定 Bot：两工具可见；未绑定的已识别 Bot：被隐藏且调用被拒；无法识别调用方（workbench）：保留全调用方面，宿主仍拒绝未绑定调用 |
| 旧数据 → 新 / 回滚 | 无持久化变更；回滚 App 即回到「不可见」 |

### 真机观测（device-app-v1.2 之后，无契约变更）

- 安装本身很快：自检 `-pdsh-selftest-device-app` 实测 4 次 Link 调用（begin、2×put、commit）共 1.5 s，`app.info` 往返约 0.5 s；2048 字节的 chunk 上限不是瓶颈，不需要更大的写或流水线。
- Worker 的 `Request timed out` 来自审批等待，不是传输：`DeviceAppInstall` 在宿主里先等一次性审批（交互审批默认最长 300 s），而 Worker 的 MCP 工具调用超时更短（约 130 s）。用户超过这个时间才点确认时，Worker 已放弃该调用，宿主那一次调用仍会在批准后完成安装（真机：`focus_timer` 摘要 `a6ad8577…` 已在 `/apps/.devapp`）。不允许在批准或完成之前返回（受理 ≠ 已执行），所以不改变返回时机。
- 重试语义：同一设备上同一 digest 的调用仍在等待确认或在传输时，重试返回错误码 `busy`，消息说明是同一个应用的上一次请求（不重复发起）；不同 digest 仍是原来的「正在安装另一个应用」。错误码集合不变，没有新字段。
- 剩余风险：用户确认慢于 Worker 超时，会让模型看到 `Request timed out` 而安装随后才发生。缓解办法（缩短交互审批等待、或让 Worker 对该工具放宽超时）需要单独的契约变更，本单未做。

## 7. device-app-v1.3：安装不再要求在蓝牙设备设置里手动授权

- 触发：真机上用户批准安装后失败 `device_not_authorized`（「设备的 app.* 还没有在蓝牙设备设置里授权」），用户只能去设置页手动给 8 个 `app.*` 打开授权。此前的 harness 预先授权过，所以没暴露。
- 选择：不由 App 自动授予（那会留下持久授权记录，之后别的路径也能用），而是在 Link 入口 `callLinkTool` 对 **user 来源**、名字在这 8 个之内的调用放过「设置授权」检查（`authorizeLink(..., userApprovedDeviceApp:)`），不授予、不记忆；其余检查（已连接、设备声明了该工具、busy、host-only）不变。agent 来源仍需要设置授权并被 host-only 拒绝，其他工具仍需各自授权。App 的 preflight 去掉授权检查。
- 理由：每次安装的一次性、绑定 digest 的审批就是这 8 次调用的授权；放过范围只含 user 来源 + 这 8 个名字，比自动授予小，也不改变任何持久状态。
- 契约：device-app.md 第 7 节加「Authorization (device-app-v1.3)」一条；没有改共享 golden／向量（授权检查不在其中）；`device_not_authorized` 保留不用。
- 相容性：新手机 → 旧设备／旧设备 → 新手机无线上变化；旧手机仍要求手动授权（行为更严，不会出错）；回滚即回到要求设置授权。
- 回归：`DeviceAppAdmissionTests.testUserOriginInstallToolsNeedNoSettingsGrantButAgentAndOtherToolsStillDo`（无授权时 user 来源 8 个全部成功、agent 来源全部拒绝、`light.set` 仍需授权；改动前失败）；`DeviceAppWiringTests.testPreflightCodes` 更新。
