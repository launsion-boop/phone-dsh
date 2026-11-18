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
contract_revision: device-app-v1.5  # device-app-v1.1 base below; v1.5 adds DeviceAppList / DeviceAppRemove (§9). spec/device/v1/device-app.md + schema/device-app-vector.schema.json + golden/device-app.jsonl (91 vectors, sha256 963187a6…3f7d), checker spec/v1/tools/test_device_app_golden.py
```

Protocol impact: P07; P26 (v1.5: tool-contracts §10, tool-catalog / tool-effects phone goldens, Worker approval-gate and caller-catalog); P09: none — 设备应用的 UI 入口另出页面契约，本单只定名字「设备应用」; P18: none — 不新增持久化键，journal 回收是既有 Link journal 的清理，不改键名与格式; P25: none — 只新增一条 `ui.system_event`（`device.app.install`），事件 envelope 不变，若实现时发现需要新 schema 则回到本单修订; P27: none — 审批行沿用通用 `approval` 行，不加字段; P01/P02: none — 不碰通道编解码与 WAL。

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
| device-app-v1.4 | 主 agent（客户旅程审计后，由实现者代编辑契约） | 客户不开设置、不看日志、不是开发者：审批卡与错误全部改为客户语言；装好后自动打开；结果未知与传输中断由安装器自己定论或重试一次 | iOS（工具宿主、效果卡、作者指南 v2、安装器接线、BLE 安装器、probe-app 接线）；Worker 无变化（审批门仍把两个名字视为 App 自有） |

| device-app-v1.5 | 主 agent（真机走查：客户装完后看不到设备上有什么，也不能停止或删除，`app.stop` / `app.remove` 无调用方） | 新增两个 Bot 宿主工具 `DeviceAppList`（只读）与 `DeviceAppRemove {name}`（一次性审批）；见 §9 | iOS（工具宿主、效果、客户措辞、BLE 接线、作者指南 v3、probe-app 接线）；Worker（审批门、caller-catalog）；golden `tool-catalog.phone.json` / `tool-effects.phone.json` 与 export-manifest 钉住的 sha256 |

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
- Worker 的 `Request timed out` 来自审批等待，不是传输：`DeviceAppInstall` 在宿主里先等一次性审批（交互审批卡片最长 300 s），而 Worker 的 MCP 工具调用超时原为 130 s。用户超过这个时间才点确认时，Worker 已放弃该调用，Bot 说「请求超时」而卡片还在，晚到的「允许」会在没人告知用户的情况下完成安装（真机：`focus_timer` 摘要 `a6ad8577…` 已在 `/apps/.devapp`）。不允许在批准或完成之前返回（受理 ≠ 已执行），所以不改变返回时机。
  **决定（GAP-44 收口，选「放宽 Worker 超时」）**：
  1. `plugins/profile/phone.worker.cordis.patch.yml` 的 `mcp-phone.toolCallTimeoutMs` 由 130000 改为 **330000**（卡片 300 s + 30 s，与 `BotAttributionRegistry.defaultTTLMilliseconds` 相同）。Worker 的 MCP 客户端按 server 配置超时，无法按工具设置，所以这是整个 `phone` server 的上限；不需要改 DSH 源码。长调用的 SSE keepalive（15 s）不变，传输层不受影响。因此人工应答一定先于 Worker 超时到达：点「允许」→ 正常安装并返回结果；300 s 无人应答 → 卡片过期，调用以 `approval timed out` 结束（不再是 Worker 的 `Request timed out`）。`/identity/cancel` 仍会关闭该调用的交互卡片，但只发生在调用真的被取消时，不再因 130 s 超时误触发。
  2. 副作用：其他 phone 工具一旦真的卡死，现在最长等 330 s 而不是 130 s。已有的有界等待（Worker 重连探测 10 s、聊天 egress 20 s、`AwaitTask` 自带 `timeout_ms`）不受影响。
  3. 提醒：`DeviceAppInstall` 的交互卡片在 10 s 后发本地通知「「<应用名>」在等你点「允许」，才会装到设备上」（其他审批仍为 60 s 通用文案）；通知权限在第一次出现设备应用安装审批时请求一次（不在 App 启动时），被拒绝不阻塞流程。
  回退：把 `toolCallTimeoutMs` 改回 130000 即回到旧行为（旧 App/旧 Worker 互通：该字段只在 Worker profile，宿主不读）。未验证：真机人工耗时（>130 s 才点允许）的端到端。
- 重试语义：同一设备上同一 digest 的调用仍在等待确认或在传输时，重试返回错误码 `busy`，消息说明是同一个应用的上一次请求（不重复发起）；不同 digest 仍是原来的「正在安装另一个应用」。错误码集合不变，没有新字段。
- 剩余风险：用户确认慢于 Worker 超时，会让模型看到 `Request timed out` 而安装随后才发生。缓解办法（缩短交互审批等待、或让 Worker 对该工具放宽超时）需要单独的契约变更，本单未做。

## 7. device-app-v1.3：安装不再要求在蓝牙设备设置里手动授权

- 触发：真机上用户批准安装后失败 `device_not_authorized`（「设备的 app.* 还没有在蓝牙设备设置里授权」），用户只能去设置页手动给 8 个 `app.*` 打开授权。此前的 harness 预先授权过，所以没暴露。
- 选择：不由 App 自动授予（那会留下持久授权记录，之后别的路径也能用），而是在 Link 入口 `callLinkTool` 对 **user 来源**、名字在这 8 个之内的调用放过「设置授权」检查（`authorizeLink(..., userApprovedDeviceApp:)`），不授予、不记忆；其余检查（已连接、设备声明了该工具、busy、host-only）不变。agent 来源仍需要设置授权并被 host-only 拒绝，其他工具仍需各自授权。App 的 preflight 去掉授权检查。
- 理由：每次安装的一次性、绑定 digest 的审批就是这 8 次调用的授权；放过范围只含 user 来源 + 这 8 个名字，比自动授予小，也不改变任何持久状态。
- 契约：device-app.md 第 7 节加「Authorization (device-app-v1.3)」一条；没有改共享 golden／向量（授权检查不在其中）；`device_not_authorized` 保留不用。
- 相容性：新手机 → 旧设备／旧设备 → 新手机无线上变化；旧手机仍要求手动授权（行为更严，不会出错）；回滚即回到要求设置授权。
- 回归：`DeviceAppAdmissionTests.testUserOriginInstallToolsNeedNoSettingsGrantButAgentAndOtherToolsStillDo`（无授权时 user 来源 8 个全部成功、agent 来源全部拒绝、`light.set` 仍需授权；改动前失败）；`DeviceAppWiringTests.testPreflightCodes` 更新。

## 8. device-app-v1.4：客户语言、自动打开、结果定论

- 触发：真机走查发现客户看到的是开发者话：审批卡列出 Link 设备 id、`counter`、摘要前 8 位和文件路径；失败回复带 `no_space`、「用设备应用列表确认」；装好后还要用户自己去设备上找应用；`outcome_unknown` 把判断推给 Bot。
- 决定（契约所有者）：
  1. **自动打开**：提交成功后宿主用同一 user 来源路径（同 v1.3 的放过）调用 `app.run`。`app.run` 失败不算安装失败，报「已装好，但没能自动打开，请在设备上选「X」打开」。成功语「已装好「X」并已在设备上打开。长按确定键退出。」（真实退出手势：长按确定 0.7 s 得到 `back`；3 s 强制结束，见设备端 DEVICE_APP_AUTHORING.md「Keys」）。客户文字不含摘要。
  2. **结果未知**：提交后回复丢失、超时或链路断开，安装器自己重新读 `app.info`（链路恢复后最多几次）：摘要一致 = 已安装，否则 = 没装上、原应用不变；只有设备读不出来才保持 `outcome_unknown`，并告诉客户让 Bot 再装一次（同摘要，可重复）。提交本身仍绝不发两次。提交中被断开的调用不再算「传输失败」，一律走未知结果的定论。
  3. **传输中断**：提交发出之前的断线、设备重启或看门狗，客户语「传输中断，设备上原来的应用没有改变。要重试吗？」；链路恢复后最多自动重试一次，同名同摘要（§6 规则 1 的续传规则），新的 install id（新的 staging journal key）；第二次中断或其他失败不重试。
  4. **审批卡**：见 device-app.md §12。客户可见文字不再含摘要、路径、Link 设备 id；完整摘要、设备 key、应用名仍在审批 `resource`，绑定不变。「会替换已有的「X」」只读手机侧已知状态（审批先于任何射频，§7 不变）。详情第一行仍是 `应用：<应用名>`，审批通知继续读它。
  5. **错误措辞**：device-app.md §8.1 一张表；结果里机器码保持稳定（`error.code`、`error.reason`），一句话放在 `message` 和可见文字里；给模型的指令只在 `hint`。
  6. **作者指南 v2**：先告知确认卡与 2 分钟内点「允许」，装好后说明应用已打开及退出方式，不对客户提摘要、错误码、工具名；仍 ≤ 6000 字符。
- 相容性：无 Link wire、无设备端变更（`app.run` 是既有 `app.*`，已在 v1.3 的放过名单内）。结果载荷只增不删：成功多 `opened`、`message`、`hint`（可含 `run_reason`），失败多 `error.reason`、`message`、`hint`、`diagnostic`；`error.code` 集合不变。旧 Worker/旧 Bot 照常读 `ok`/`error.code`。回滚 App：回到旧措辞，不自动打开。
- 未验证：真机上 `app.run` 之后的屏幕、设备在传输中重启后的重连时长（自动重试等待最多约 15 s，未经实测）、「会替换已有应用」在手机从未见过设备应用列表时不会出现。
- 回归：`DeviceAppToolsTests`（卡片文本与绑定、自动打开与失败、客户语句、规格 §8 每个码都有句子）、`DeviceAppWiringTests`（一次重试、不重试、未知结果由 info 定论）、`DeviceAppInstallerTests`（提交被断开按未知处理）。

## 9. device-app-v1.5：设备上有什么、怎么删（`DeviceAppList`、`DeviceAppRemove`）

- 触发：真机走查（客户旅程）。安装之后客户无处看到设备上装了什么，也不能停止或删除一个应用；Bot 回答不了「我设备上有什么」「把计时器删掉」。设备上的 `app.stop` / `app.remove` 没有任何调用方（只有自检）。
- 现况 → 期望：现况是 Bot 只有 `DeviceAppStage`、`DeviceAppInstall`；期望是绑定了设备应用能力的 Link 设备的 Bot 多两个宿主工具，可见性规则与前两者相同（全调用方 `tools/list` 列出，per-caller 目录只对已绑定 Bot 列出，Worker deny-unless-listed，未绑定的调用宿主拒绝）。
- 契约 delta：

| 项 | 内容 |
| --- | --- |
| `DeviceAppList {}` | 只读、无审批、无参数。设备取自绑定，不取自模型参数。链路检查（已连接、设备声明了工具）后读一次 `app.info`，返回 `{ok, count, apps:[{name,title,version?,running}], message, hint}`；设备自报的字符串一律清洗、截断。失败为 `error.code=list_failed`，`error.reason` 为机器码，`message` 取自 device-app.md §8.2 的客户句子 |
| `DeviceAppRemove {name}` | `name` 必须符合既有应用名规则（§2），路径与多余成员一律 `invalid_arguments`，且发生在审批与射频之前。**每次调用**都先弹一次性审批（含用户亲自发话的回合；`alwaysScope=none`，不提供长期授权；同一 330 s 卡片与同一 10 s 本地提醒），卡片文字为 `要从「<设备名>」上删除「<应用名>」吗？` + `删除后不能恢复，需要的话让我重新做一个。`；批准后才读 `app.info`、仅当该应用在运行时 `app.stop`（失败则不发 `app.remove`），再发一次 `app.remove {name}`。回复丢失由 `app.info` 定论（名字不在=已删除；还在=`not_removed`；读不出=`outcome_unknown`），绝不重发 |
| 授权 | 与 §7（v1.3）一致：`app.stop`、`app.remove` 本就在 user 来源免设置授权的八个名字之内，不新增名字；agent 来源仍 host-only 被拒 |
| 忙守卫 | 一台设备同一时刻一个操作：安装或删除占用设备（等审批或在射频上）时，另一个删除、安装和 `DeviceAppList` 返回 `busy`；同名删除的重试得到真实状态，不再弹第二张卡 |
| 审计 | 复用既有审计器，新增事件名 `ui.system_event{event:"device.app.remove", device, name, title?, was_running, author}`（无 digest、无文件）；写入失败为 `audit_recorded:false`。事件 envelope 不变（P25: none） |
| 措辞 | device-app.md §8.2 一张表（键为同一批机器码，句子不含「安装」、不含码）；未知码得到该工具的通用句，不会露出码 |
| Worker | `approval-gate.ts` 的 `AUTO_TOOLS` 增加两个名字（`DeviceAppList` 宿主 `read/auto`；`DeviceAppRemove` 由 App 自己弹卡，Worker 不提 effect、不走 `/approval`）；`caller-catalog.ts` 的 deny-unless-listed 集合增加两个名字。近似名（`DeviceAppListX`、`DeviceAppRemoveAll` 等）仍是 `tool.unclassified` |
| golden | `tool-catalog.phone.json` `deviceApp.tools` 增加两项；`tool-effects.phone.json` 增加 valid `DeviceAppList`、`DeviceAppRemove` 与 invalid `DeviceAppRemove`（路径当名字、不进 resource）、`DeviceAppList`（多余参数不影响分类）；合并后向量总数 31 → 35（`BotGoldenVectorTests` 钉住）；export-manifest 中两文件的 sha256 随之更新 |
| 作者指南 | v2 → v3，新增「查看和删除」一节（名字取自列表、先告诉用户会弹确认卡、只有 ok 才说已删除、不对客户提 name 与工具名）；仍 ≤ 6000 字符 |

- 相容性：

| Producer → Consumer | 处理 |
| --- | --- |
| 新 App → 旧 Worker 镜像 | 全调用方列表多两个工具；旧 Worker 会把它们当 `tool.unclassified`（session）送 `/approval`，被 App 拒 `stale:always_scope`，与 v1.2 同类；须同时更新 Worker 镜像 |
| 旧 App → 新 Worker | 全调用方列表没有这两个名字，deny 对不存在的名字无效，无功能无副作用 |
| 新手机 → 旧设备 | 只用设备既有的 `app.info`、`app.stop`、`app.remove`（device-app-v1 §5），没有新设备工具；缺少这些工具的设备被预检拒绝，客户得到「这台设备不支持设备应用」 |
| 旧数据 → 新 / 回滚 | 无持久化格式变更；`device.app.remove` 是新增的 `ui.system_event` 事件名，旧读取方按未知事件名忽略。回滚 App 即两工具不可见，设备上的应用保留 |

- 未验证：真机 `app.remove` 的回复形状与耗时、删除运行中应用时 `app.stop` 与 `app.remove` 之间的设备行为、probe-app 接线只通过 iOS 模拟器编译（未运行、未上真机）；`app.remove` 是 durable 调用，回复丢失后的 `app.info` 定论逻辑只由宿主测试覆盖。
- 回归（改动前失败）：`DeviceAppListRemoveTests`（可见性：已绑定/未绑定/全调用方；未绑定拒绝且读取与删除都不执行；列表客户文字与机器字段、不弹审批、设备取自绑定；`DeviceAppRemove` 批准前不执行、拒绝或取消不执行、每次调用各自审批、路径与坏名字在审批前拒绝、忙守卫、失败与未知不当作成功、审计事件）、`DeviceAppListRemoveWiringTests`（预检失败不读不发、只停运行中的目标、`stop_failed` 之后不发删除、丢失回复由 info 定论且只发一次）、措辞表覆盖测试（规格 §8 / §8.2 每个码都有句子，不含「安装」）、`BotGoldenVectorTests`（35）、`BotApprovalNotificationTests` 之外的删除提醒；Worker `bot-identity-approval.test.ts`、`bot-caller-catalog.test.ts`。
- 顺带修正：`DeviceAppToolsTests.testEveryDeviceErrorCodeOfTheSpecHasACustomerSentence` 在 v1.4 之后就不通过（它把 §8.1 里反引号括起的字段名 `reason`、`message`、`hint` 也当成设备错误码）；现在只读 §8 标题下的错误码段落，没有放宽任何断言。

### 真机观测：DeviceAppList 文本缺 name（device-app-v1.5 修订，无新字段）

- 现象：真机上模型调用 `DeviceAppList` 后无法删除应用。证据：模型会话里该工具的结果文本只有「设备上现在有 22 个设备应用：「呼吸 4-4-6」…」，没有 `apps[].name`；模型读的是 text content，不是 `structuredContent`。（同一次走查中两次「列出/删除」测试实际都发出了旧的呼吸提示词——shell 里 `sed` 没替换成功——所以模型的「重装」行为是对错误提示词的正确反应，不是它不会删除。）
- 修正：`DeviceAppList` 成功时的 text content 就是整个对象的 JSON（含 `apps[].name`、`message`、`hint`），结构不变；作者指南升到 v4，明确「删除/卸载/移除 → DeviceAppRemove，不用 Stage+Install」并说明从 List 的 JSON 取 `name`。tool-contracts.md §10 补一句。回归：`DeviceAppListRemoveTests.testListReturnsCustomerTextAndMachineFieldsWithoutAnApproval` 现用真解码器解析 text 并断言 `name`。

