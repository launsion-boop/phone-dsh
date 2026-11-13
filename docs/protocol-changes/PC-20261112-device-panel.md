# 设备面板（每个硬件一个「小程序」）— 契约变更单

```yaml
change: PC-20261112-device-panel
contracts: [P05, P07, P09, P18]
status: implemented
breaking: false
version_decision: 不改任何现有版本。面板只消费现有 PDSH Link Tools v1；面板描述是新增的独立版本化文件（v 1）。
base: 8f3de8b8375bc9c32add4517f6eaadc815b8d4b5
contract_revision: spec/device/v1/device-panel.md@5ed9d78d3f2b5c7eb22c8301dc3f39c98ee1bcec
```

Protocol impact: P05; P07; P08; P09; P18; P04: none — C 档只登记为保留项，不新增 handler、不改 bridge.md；
P21: none — B 档只是提案，`pdsh-page:` 的路由与 CSP 不变；
P24: none — `project.yml` 只加入既有 `PhoneDSHBLE` product 与源文件，`Package.resolved` 与解析锁不变；
P27: none — 新页面与采用 sheet 不涉及 Bot row、UserAction 或转录 schema。

冻结的范围是 A 档（原生面板 + 声明式描述）的**契约**。契约冻结时没有任何一端的实现；
2026-11-12 的 Swift 实施（WP1–WP5）落地后，owning spec 的端状态为 iOS `implemented`（真机未验）、
Android `target`（GAP-20），本文档状态为 `implemented`。

## 1. 识别与角色

- **Trigger。** 设备已经通过 `tools/list` 自报工具名、说明和 `inputSchema`，但只有 Agent 能用
  （`ble_link_tools` / `ble_link_call`）。用户想直接操作设备时没有界面。
- **现况。** Link 工具的唯一调用者是 `Sources/PhoneDSHBLE/DeviceMCPServer.swift`；蓝牙设备页只有连接和授权开关。
- **期望。** 每个已连接设备有一个面板，分档推进，每一档单独做发布决定：

  | 档 | 形态 | 是否执行生成的代码 | 能否操作设备 | 状态 |
  | --- | --- | --- | --- | --- |
  | A0 | 原生面板，由 `inputSchema` 确定性得到参数编辑器 | 否 | 能（用户点按） | 本单冻结 |
  | A1 | A0 + 模型生成的声明式描述（标签、分组、预设） | 否 | 能（用户点按） | 本单冻结 |
  | B | 生成的 H5，无桥，只读宿主快照 | 是（沙箱内） | 不能 | 提案，不在本单 |
  | C | 生成的 H5 + 意图桥 | 是 | 能（经宿主审批） | **保留，不是功能** |

- **角色。** 协调者兼 contract owner：本任务的协调者。implementer 与 reviewer-integrator：尚未指定，指定前不得开始实现。
- **Owning contract。** [spec/device/v1/device-panel.md](../../spec/device/v1/device-panel.md)（P07；§4 的宿主私有副本属 P18）；
  并发准入在 [ble-link.md](../../spec/device/v1/ble-link.md)「Link 调用准入」；
  P05 [native-mcp.md](../../spec/v1/native-mcp.md) 只加说明，工具表不变；P09 [ui/v1/README.md](../../spec/ui/v1/README.md) §1 登记页面。
- **受影响的端。**

  | 端 | 状态 | 理由 |
  | --- | --- | --- |
  | Swift 宿主（`Sources/PhoneDSHBLE`、probe-app UI） | not started | 唯一有 Link 工具调用路径的端 |
  | Worker | 不改 | 模型用现有文件工具写描述；不新增插件、工具或 Remote 方法，不需要重建 image |
  | C 固件（`firmware/**`、仓外 `tonolink-m21-r4-firmware`） | 不改 | 只读取现有 `tools/list` |
  | Kotlin／Android | 契约一并冻结；not started，受 GAP-20 阻塞 | 见 §2.4 |
  | HarmonyOS、Rust | 不改 | 无 BLE Link 实现 |

## 2. 契约 delta

规范文本在 owning spec 中，这里只列改动与决定。

| 项目 | Before → After／依据条款 |
| --- | --- |
| fields／encoding／limits | Link wire 不变。新增面板描述文件：封闭 schema，`v: 1`，≤16384 字节，嵌套 ≤16 层，文本 1–40 标量值（device-panel.md §4） |
| capability／version／unknown | 不新增能力位。描述的未知成员、未知 `v` 整份拒绝，不做部分采用（§4.2） |
| correlation／terminal outcome | 面板每次发送一个新的幂等 key 与 request UUID，恰好一个终态（§3） |
| error／deadline／cancel | 沿用 Link 现有错误与语义；不新增错误码 |
| idempotency／side effect unknown | 与 `ble_link_call` 相同：先落盘再上传，`outcome_unknown` 只能查询、不自动重放（§3） |
| origin／auth／scope／backpressure | 来源记为用户；受同一份授权约束；采用预设不构成 `home.http` 的 origin 批准；同一设备至多一个进行中的 Link 调用，忙在落盘前判定（ble-link.md「Link 调用准入」） |
| 条款状态 | 新增条款均为 `target`；ble-link.md 其余条款状态不变 |

### 2.1 已定的决定

1. **面板描述由模型写到工作区，用户在原生界面采用后由宿主校验并原样拷贝到私有目录**（用户决定，2026-11-12）。
   不新增 MCP 工具。面板只读私有副本。
2. **同一设备只允许一个进行中的 Link 调用，后到者得到现有的忙错误**（用户决定）。忙在落盘意图之前判定。
3. **面板调用不进入设备固定 Session**（用户决定）。P06 不在本单内；以后要让 Agent 看到面板操作需另一份变更单。
4. **Android 的面板契约一并冻结**（用户决定）。实现等 GAP-20 关闭（§2.4）。

### 2.2 起草过程中由 contract owner 改掉的两处

这两处与用户看过的草稿不同，由 contract owner 在写规范时决定。目前没有实现方，不同意时出新 revision 即可：

- **去掉 `tools_digest`。** 草稿用工具表的规范化 JSON 摘要判断描述是否过期。这需要一种三端（Swift、Kotlin、C 侧 JSON）
  一致的规范化编码，是为方便而新增的协议面（AGENTS.md §2 规则 7）。改为每次取得 `tools/list` 时对已采用的描述重新求值：
  引用的工具不在了，或预设不再通过该工具当前的 `inputSchema`，描述就不生效。代价是工具只改说明文字、不改 schema 时，
  描述不会失效。
- **控件是参数编辑器，不是设备状态。** 草稿把布尔参数写成「开关」、把无参工具写成「状态行」。工具表里没有只读标记，
  宿主无法知道无参工具是否有副作用，也无法知道 `light.get` 与 `light.set` 有关。所以：编辑器初始未设置，
  不显示为设备当前状态；任何工具都只在用户明确点按时调用，宿主不自动预读或轮询（device-panel.md §2）。

### 2.3 并发准入与现行行为的差距

现行源码（base，未做 runtime 实验）有两层忙判定：`DeviceMCPServer` 的 `activeLinkID` 在落盘前；
`BLEDeviceStore.invokeLink` 的 `linkBusy` 在落盘后，其拒绝被通用错误路径报告为 `outcome_unknown`。
这符合 ble-link.md 规则 1，不是违约。新条款要求合并为落盘前的同一个准入点，因此：

- 面板不得直接调用 `BLEDeviceStore.invokeLink`；意图落盘与调用序列要提成两个调用者共用的一段。
- Agent 在 store 忙的情形下，可观察结果由 `outcome_unknown` 变为忙且无记录。这是对现有消费者的行为变化，须有回归。
- 两处忙文本是否统一由 implementer 在实现时提出，属同一条款。

### 2.4 Android

- 契约对两端相同，读同一组向量。
- Android 普通 Link 通道仍是 `target`，没有工具 RPC、持久意图和用户授权；GAP-20 记录它没有可用的 GATT adapter。
  在 GAP-20 关闭并有两端 runtime 证据之前，Android 不渲染面板、不调用 Link 工具，也不放全部禁用的占位页。
- P09：`DevicePanelPage` 在 README §1 登记为 `later`。`spec/ui/v1/pages/*.json` 不手写，iOS 页面落地后由提取器生成，
  Android 一栏为 `missing`，与 `TonoLinkUSBOTAPage` 的登记方式相同：由 `_whitelist.json` 的
  `device-panel-ios-only` 引用 `platform.device-panel-ios` 登记为平台被迫差异（`os-forced`，GAP-20），
  不新增 `_baseline.json` 记录，也不为了通过检查去写 Android 页面或占位页。蓝牙设备页新增的实验入口
  （开关 + 打开面板）同属该平台差异，另有三个同 `platformRef` 的 ios-only 条目。
- 代价：双端规则在没有 Android 实现检验的情况下冻结。Android 落地时发现某条做不到，走 CONTRACT CHANGE REQUEST。

### 2.5 B、C 档

- **B**（无桥 H5 + 只读快照）需要在 P21 新增只读路由，而 render-media-v1.md 仍是 `draft`（GAP-09）。不在本单，不实现。
- **C**（意图桥）是保留项（AGENTS.md §2 规则 4）：不得实现，不得调用。解除保留需要 Apple 对 App Review Guideline 4.7.2
  的事先许可、作为 bridge.md 统一信封下的方法定义（不新增一次性 handler，见 GAP-01、GAP-05）、WebView 外的审批，
  以及一份带两端 runtime 证据的新变更单。

### 2.6 实施期协调者决定（2026-11-12）

实现开始前由协调者定下，均不改变 owning spec 的条款；实现方按这些答复工作：

1. **忙文本不新增第三条，也不合并现有两层。** 准入在 `LinkToolCaller` 合成一个 `LinkBusy` 错误，在 journal
   落盘之前抛出。`DeviceMCPServer` 把它映射回 base 的**分层**文本：`ble_link_call` 在两种忙情形下都是
   "Another Link call is running"；`ble_link_result` 在 MCP 自身有进行中的调用时仍是
   "Invalid result query or Link busy"，在 store 被面板／设备任务占用时仍是 "Link is busy"。
   面板自己把 `LinkBusy` 显示成本地化文案。除 §2.3 登记的「`ble_link_call` store 忙 → 忙且无记录」外，
   **对有效记录且已授权的请求**，MCP 的可观察文本逐字节不变。准入先于 journal 查找与授权，所以「忙 **且**
   request UUID 不在本机 journal」「忙 **且** 工具已撤销」「忙 **且** 工具未授权」这三类组合的错误优先级
   从 lookup／授权错误变成忙；它们本身就是无效或未授权的调用，没有 journal 或设备副作用，也没有有效消费者
   依赖旧文本，属于本条准入顺序的直接结果而非新增错误码。
2. **采用入口与工作区约定。** 入口只在面板页（工具栏／空状态「采用描述…」），清单来自工作区
   `device-panels/*.json`；模型把描述写到工作区路径 `device-panels/<Link device ID>.json`。
   这是给模型的命名约定，不是协议面：内容仍由 §4.2 求值，文件名不参与判定。不改 `FilesPage`。
3. **功能开关默认关闭且不持久化。** 用蓝牙设备页里的内存 `@State` 开关，默认 `false`；
   不新增 UserDefaults key（那会是新的 P18 表面）。A0 的发布决定仍按 §3。
4. **§2.2 的两处设计按冻结文本实施。** 截至实现开始未收到需求方推翻意见；若之后被推翻，
   出新 revision，WP1 与 WP4 重跑。
5. **`origin` 只表达调用面，不落盘。** 面板调用在类型上就是 `.user`，MCP 是 `.agent`；按 §2.6 第 2 条
   （计划口径）journal 格式不变，所以 `origin` 不写进 journal、也不进入面板结果记录。§3「来源记为用户」
   的实现方式是：面板这条路径根本不经过 Agent／模型，不存在把它归因为模型的记录。若以后要审计来源，
   那是 P18 的格式变更，须另提 CCR。
6. **内部接口冻结。** 协调者在 `6e626fb4` 提交了四个 Swift 内部接口骨架（`DevicePanelSchema.swift`、
   `DevicePanelDescriptor.swift`、`LinkToolCaller.swift`、`DevicePanelStore.swift`）以及设备模型上的
   `linkDeviceID` 原始值字段，只为四个工作包能并行编译；它们不是协议，实现方在各自工作包里替换。
   同时把既有 `UniqueJSONKeys` 的 `struct`／`init`／`check` 放开为 `public`，避免复制重复键扫描器；
   语义不变。

### 2.7 交付后审阅的修正（2026-11-12，契约 owner）

对实施 head `80da4725` 的审阅发现三处，均不改变 owning spec 的条款、共享向量或 Link wire／journal 格式：

1. **Agent 侧取消不再打断面板调用。** `BLEDeviceStore.cancelLinkOperations`（回合停止、MCP
   `notifications/cancelled`）原先断开所有占用 Link 槽位的设备，包括用户在面板里发起的调用，与 §3
   「不进入设备 Session」相悖。现在准入按 `origin` 标记：`.user` 的占用不被 Agent 侧取消断开；`.agent`
   与设备任务的占用行为不变。
2. **未结清的请求在离开面板页后保留。** 上次结果原先只在页面实例的内存里，`outcome_unknown` 后离开再进入
   会丢失 request UUID，既无法查询又允许重发，与 §3「恢复后只能查询」不符。现在按外设在进程内保留
   （`DevicePanelResultCache`）；仍不落盘（落盘是新的 P18 表面）。**App 重启后记录仍会丢失**：请求留在
   Link journal 里，但面板不再提供它的查询，记为剩余风险。
3. **收窄 device-panel.md §5 的 iOS 行。** 原文「模拟器 UI 测试通过」不实：面板只有 model 级测试。

### 2.8 真机跑通与体验修正（2026-11-12，契约 owner）

设备：iPhone `00008160-00023D1C2240000A`（iOS 27.2，经 longshu 的局域网配对），App `com.tono.phonedsh.probe`
（team `Q322S2LD93`，在 Mac Studio 构建签名），板子 `PhoneAgent-7356`（Link device ID
`468d389c-143c-443a-9b04-ea7be58b9a97`，自报 `light.set`、`light.get`，未自报 `home.http`）。

- **真机结果。** `DevicePanelHardwareDeviceTests.testPanelSwitchesLEDAndReadsItBack`（宿主在 App 进程内，真实
  `BLEDeviceStore.shared` + `callLinkTool(origin: .user)`）→ PASS，两次运行：面板 model 依次开、关、开，
  每次 `light.get` 读回的 `on` 与刚发送的一致，`state_revision` 逐次加一；随后经真实求值器与宿主私有存储采用
  一份描述（开灯／关灯／读取灯状态三个预设），预设按钮同样读回一致。该描述留在手机上。
- **未验证。** 页面在 App 自身导航栈里的样子与触控操作（XCUITest 在该机上启用自动化模式超时，截图取自测试自建的
  窗口）；采用 sheet 的真实交互；断电／断线恢复；撤销授权；模型生成描述；灯是否真的亮（只有设备自报的读回）。
- **体验修正（不改条款、向量或 wire）。**
  1. 发送按钮在已启用时是一块没有文字的黑条（列表的 tint 与前景同色）→ 改用 `HomePrimaryButtonStyle`；
     预设按钮直接以描述的 `label` 为按钮文字，一次点按即发送，按钮下方照实显示实际调用的工具与参数。
  2. 结果原先是截到 6 行的原始 JSON，关键字段被截掉 → 先显示设备是否完成、`result` 的标量成员逐行列出，
     原始 JSON 收进可展开项；设备自报 `failed` 时明确显示失败而不是当成功。
  3. 有描述时结果原先在同一工具的每个控件下各重复一次 → 改为页面底部一处「最近结果」。
  4. 去掉每个编辑器下重复的免责声明和三行说明，收成页脚一句；无参数工具的按钮叫「执行」；标题用设备名；
     断开后显示「设备已断开」而不是「没有工具」。
  5. **入口不再藏在开关后面。** 原先（§2.6 第 3 条）是蓝牙设备页里每次启动都要重新打开的内存开关；
     现在只要设备已连接并协商了 PDSH Tools v1 就显示「设备面板」入口。这推翻了 §3「功能放在开关后，默认关闭」
     的发布安排，由需求方 2026-11-12「把小程序跑通…从用户体验的角度去…更改」的指示决定；P09 页面契约与白名单已同步。
- **仍缺的一环（未做）。** Agent 还不知道描述的格式，也拿不到 Link device ID（`ble_link_tools` 不返回它），
  所以「让模型给设备生成面板」目前只能手写描述。补上它要改 native MCP 的工具输出与说明，属 P05 的契约变更，须另提。

### 2.9 Agent 生成描述所需的信息（2026-11-12，契约 owner；P05 增量）

- **触发 → 现状 → 期望。** 模型要写描述必须知道 Link device ID 与描述格式；`ble_link_tools` 只返回 `tools`，
  说明里也没有描述格式 → 结果对象新增 `device_id`（设备原样返回的 Link device ID）与 `panel_path`
  （宿主建议的工作区路径），并在该工具的 description 里写明描述的形状与「只有用户能采用」。
- **编码与限制。** 见 [native-mcp.md](../../spec/v1/native-mcp.md)「BLE tools」：`panel_path` 为
  `device-panels/<name>.json`，`<name>` 仅在 ID 是 1–64 个 ASCII 字母数字、`_`、`-` 时取 ID 本身，否则取其
  SHA-256 前 16 个十六进制字符。未协商 Link 时两个成员都不出现。
- **相容性。** 增量字段：旧模型／旧调用方忽略未知成员；旧 App 不返回它们，模型就无从写出正确的 `device_id`，
  采用时会得到 `device_mismatch` 或 `schema`，不会误采用。工具名、参数 schema、错误文本不变。Android 不提供这些工具。
  §2.6 第 2 条的文件名约定由「Link device ID」改为宿主给出的 `panel_path`（不安全的 ID 不再进入路径）。
- **证据。** `LinkAdmissionTests.testLinkToolsListingCarriesLinkDeviceIDAndPanelPath`（真实 `DeviceMCPServer` +
  `BLEDeviceStore`）；真机见 §4。**模型按说明实际写出合法描述**没有验证（需要真实模型回合）。

### 2.10 从对话直达面板（2026-11-12，契约 owner）

需求方真机试用：Agent 说「面板已生成」，点开文件只看到纯文本。对话与文件页打开工作区文件都走 `PreviewSurface`，
描述文件被当成普通 JSON。现在路径是 `device-panels/*.json` 的文件改由 `DevicePanelDescriptorPreview` 呈现：
用真实求值器对已连接设备的现行工具表求值，画出分组与按钮（不可点、不调用设备，并照实列出工具与参数），
给一个「采用并打开面板」按钮；采用成功后直接进入该设备的面板页。已采用同一份描述时按钮是「打开面板」；
求值不是 `ok` 时显示原因；设备未连接时提示先连接；文件内容收进可展开项。
不改变 §4.1 的规则：采用仍是用户在 WebView 之外原生界面里的明确动作，面板仍只读宿主私有副本；
owning spec §4.1 已补一句说明这两个入口。真机：`testAgentListingIsEnoughToAuthorAnAdoptableDescriptor`
在 App 窗口里呈现该预览并截图 → PASS；从对话里真实点开文件、点按采用后的跳转 → 未验证（需要人在手机上操作）。

### 2.11 面板按钮的反馈与样式（2026-11-12，契约 owner）

需求方真机反馈：点一个按钮，所有按钮都短暂变色；界面不好看。原因是调用进行中时所有控件都被 `disabled`
而整体变淡。现在只因持久原因（未授权、上次结果未结清、必填参数未设置）才变淡；有调用在途时其它控件只是不响应点按。
描述里连续的预设按钮排成两列卡片，被点的那一个显示进度，设备返回后短暂显示对勾（失败为警示）并给触感反馈——
这是对那一次调用的确认，不表示设备状态。按钮下不再逐个显示工具与参数（采用前的预览里仍照实列出，按钮的无障碍提示里也有）。
不改条款、向量或 wire。真机：`DevicePanelHardwareDeviceTests` → PASS（2 tests），截图确认卡片与对勾；
「其它按钮不再变色」是按代码路径判断的，没有逐帧证据，待需求方在手机上确认。

### 自检（spec/README.md §5.1）

- 第二种表达：没有。面板调用复用 Link 调用路径；描述是新文件，不是现有格式的别名。
- 新字段可选性：现有消息不加字段。描述整体可选，缺省即 A0。
- 收紧／放宽：不放宽 `home.http` 的 origin 规则与授权。并发条款使一种现有结果更精确（§2.3），已登记为行为变化。
- 未知值：描述的未知成员或未知 `v` 整份拒绝。
- 名称重用：无。

## 3. 相容性与发布

| Producer → Consumer | 行为 |
| --- | --- |
| 旧固件（无 Tools 扩展）→ 新 App | 协商不成立，没有面板，不发工具 opcode |
| 新固件 → 旧 App | 无影响 |
| 新固件 → 新 App | A0；有生效描述时 A1 |
| 固件升级后工具表变化 | 已采用的描述重新求值，不再是 `ok` 时回到 A0 |
| 旧数据 → 新／回滚 | 已采用的描述是新增文件，旧 App 忽略，重新升级须保留。Link journal 格式不变 |

- 功能放在开关后，默认关闭。A0 可独立发布；A1 依赖 A0。
- 条款保持 `target`，直到两端真实实现读过共享向量并有 runtime 证据。

## 4. 分工与证据

- **独占路径。** contract owner：`spec/**`、`spec/tools/registry_build.py`、`spec/v1/tools/test_device_panel_golden.py`、本单。
  Swift implementer（2026-11-12 指定，按计划 §7 分成互不重叠的 WP1–WP4，各自 worktree／分支）：
  `Sources/PhoneDSHBLE/**`、`Tests/PhoneDSHBLETests/**`、probe-app 面板页与 `project.yml`。
  Kotlin implementer：GAP-20 关闭后指定。
- **共享 fixtures。** `spec/device/v1/golden/device-panel-mapping.jsonl`（36 行）、
  `spec/device/v1/golden/device-panel-descriptor-cases.jsonl`（59 行，十种结果各至少一例）。两份都含正例、反例、
  数值与大小边界、未知值和判定顺序。
- **各端真实测试。** Swift：分类器与求值器读上述两份文件（`DevicePanelVectorTests`，10 tests，36+59 行逐行）；
  已采用描述的存储 12 tests（WP1 合入后真实求值器 round-trip 用例由 skip 转 PASS）；并发准入 7 tests
  （真实 `BLEDeviceStore` + journal；覆盖 `not_executed`、`outcome_unknown`、取消、撤销授权、两调用者并发，
  以及 loser 无 journal／winner 不受影响／同幂等 key 重试成功）。**真实断线**没有在新增准入回归里重做：
  断线语义由既有 `StandardGatt*`／`PDSHLinkTests` 覆盖，准入回归的 transport 是手写 fake，不是
  `golden/pdsh-link.jsonl` 帧。面板 model 12 tests（模拟器、fake source），含“工具表变化后重新求值”与
  “撤销授权后禁用发送”；面板在打开期间观察 `linkTools`／`linkToolDescriptors`／`grantedTools`／`linkDeviceID`
  并重新求值（观察接线只有编译级证据，model 级有上述两条测试）。**采用 sheet 的文件选择／预览／确认／移除
  交互没有 UI 测试**，只有 model 级测试。Kotlin：未实现（GAP-20）；C：不变。
- **命令 → 结果**（2026-11-12，集成分支 `feat/device-panel` 的评审 head，macOS arm64，Xcode 27.2 / Swift 6.4.2）：
  - `swift test --filter DevicePanelVectorTests` → PASS（10 tests）
  - `swift test --filter DevicePanelStoreTests` → PASS（12 tests）
  - `swift test --filter LinkAdmissionTests` → PASS（7 tests）
  - `swift test --filter LinkAdmissionTests` 的 M2 回归断言的是 store 层文本 "Link is busy"；MCP 层
    `activeLinkID` 的 "Invalid result query or Link busy" 没有新增测试（该分支未被本单修改，仍是既有行为）
  - `swift test --filter PhoneDSHBLETests` → FAIL：250 tests，12 failures / 10 unexpected，全部是既有的
    firmware-C-build 环境失败（8× `BLESecureCrossRuntimeTests`、2× `BLETaskCrossRuntimeTests`：缺 cJSON / mbedTLS /
    ESP-IDF reference build）；未改动的基线上同样失败
  - `python3 -m unittest discover -s spec/v1/tools -p 'test_device_panel_golden.py'` → PASS（6 tests；规范检查）
  - `python3 spec/tools/registry_build.py --check` → PASS
  - `bash scripts/ci/check.sh --only phone-spec` → PASS
  - `bash scripts/ci/check.sh --only phone-cross-tree` → PASS
  - `bash scripts/ci/check.sh --only phone-p0-conformance` → FAIL：`page-structure` 3 条基线外分歧，与开工前逐条相同
    （connectors extra-action、gmail-connector / git-hub-connector missing）；`DevicePanelPage` 与蓝牙设备页新增入口
    经 `_whitelist.json`（`platform.device-panel-ios`）登记，无新增失败。其余子检查 PASS
  - `bash scripts/ci/check.sh --only phone-hygiene` → FAIL：既有文件中的禁用词与域名；未改动的 base 上相同
  - `bash scripts/ci/check.sh --only phone-modules` → FAIL：`Package.swift` 既有 PhoneDSHStandardError 依赖记录缺失；
    未改动的 base 上逐字相同（不是本单引入）
  - `bash scripts/ci/check.sh --only phone-license`、`phone-no-dsh-patch` → PASS
  - `bash scripts/ci/check.sh --only phone-sdk` → FAIL：除上述 12 条 firmware-C 环境失败外，只有
    `PhoneDSHTests.ProbeScenePhaseWiringTests` 一条既有失败（base 上相同）；没有一条指向本单改动
  - `bash firmware/tests/run.sh` → FAIL：所有可运行 host 检查 PASS，停在缺 ESP-IDF reference build（cJSON）；
    未改动的 base 上相同。`bash firmware/tests/run.sh --portable-only` → PASS
  - probe-app：`xcodegen generate` → PASS（需先建 gitignored 的 `Bundle/worker/` 空目录，未提交）；
    `xcodebuild … -destination 'generic/platform=iOS Simulator' build` → PASS
  - `xcodebuild -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/DevicePanelModelTests test` → PASS（12 tests，
    iOS 18.0 模拟器；这是 model/fake 级证据，不是设备结论）
  - `python3 scripts/ci/protocol_impact.py --base main --body-file …` → PASS（触发 P05、P07、P09、P18）
  - §2.7 修正后（工作树，基于 `80da4725`）：`swift test --filter 'DevicePanel|LinkAdmission'` → PASS（30 tests，
    新增 `testAgentCancellationLeavesAUserPanelCallRunning`，真实 `BLEDeviceStore`）；
    `swift test --filter 'StandardGatt|PDSHLink|DeviceMCP'` → PASS（56 tests）；
    `xcodebuild -scheme PhoneDSHSim -destination 'generic/platform=iOS Simulator' build-for-testing` → PASS；
    `xcodebuild -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/DevicePanelModelTests test`（iOS 18.4 模拟器）
    → FAIL：测试包加载失败（`Library not loaded: /usr/lib/swift/libswiftWebKit.dylib`），在 §2.7 修改之前同样失败，
    所以新增的 `testReopenedPanelKeepsUnsettledRequestQueryOnly` 只有编译级证据，**NOT_RUN**；
    上面那条「iOS 18.0 模拟器 PASS」在审阅机上未能复现（该模拟器无法启动）
  - 真机 iPhone + TonoLink M21-R4（§2.8、§2.9）：`xcodebuild test-without-building … -only-testing:PhoneDSHDeviceTests/DevicePanelHardwareDeviceTests`
    （`TEST_RUNNER_PDSH_DEVICE_PANEL_TEST=1`）→ PASS（2 tests）：`testPanelSwitchesLEDAndReadsItBack` 三次运行均通过；
    `testAgentListingIsEnoughToAuthorAnAdoptableDescriptor` 一次：真机 `ble_link_tools` 返回 `device_id` 与
    `panel_path=device-panels/468d389c-143c-443a-9b04-ea7be58b9a97.json`，仅凭该返回写出的描述放到该路径后被采用页的
    解析函数读到并求值为 `ok`（文件由测试直接写入 materialized 工作区，不是经模型的文件工具）。
    XCUITest（触控级）→ NOT_RUN：启用自动化模式超时。真实模型回合生成描述 → NOT_RUN
  - §2.8／§2.9 修改后：`swift test --filter 'DevicePanel|LinkAdmission'` → PASS（31 tests）；
    `swift test --filter 'BLEDeviceMCP|DeviceMCPNative'` → PASS（14 tests）
- **未验证。** 真机 E2E（连接、发送、断电恢复、撤销授权、模型生成描述后采用）、断电/崩溃的持久性、
  模拟器里真实 BLE 路径（仅 fake source）、采用 sheet 的真实 UI 交互、已准入调用中的真实断线、
  Android 上规则的可行性。
- **剩余风险。** §2.4 的 Android 风险（GAP-20）；§2.3 的并发行为变化；参考实现与规范文本出自同一作者，
  没有第二个独立实现交叉验证向量；测试证明的是代码与共享向量一致，不是真机行为；
  `duplicate_key` 与深度溢出同时出现时 Python 参考实现与 Swift 的优先级不同（GAP-40，共享向量未覆盖）；
  预设参数使 Link 请求超过 4096 字节时，既有路径会先落盘、再在客户端编码阶段失败并被报成
  `outcome_unknown`（base 的 Agent 路径同样存在，面板预设更容易触发；本单未修，属 P05/P07 的既有边界）。

## 5. 审核边界（发布决定的依据，不是协议条款）

- App Review Guideline 4.7 允许不在二进制内的 HTML5／JavaScript 小程序；4.7.2 规定未经 Apple 事先许可不得向这类
  软件暴露原生平台 API 或技术；2.5.2 禁止下载或执行会引入或改变 App 功能的代码。
- A 档不执行任何生成的代码，只渲染数据。这是本单的判断，不是 Apple 的裁定。
- C 档直接适用 4.7.2，与 [个人应用架构文档](../architecture-upgrade-personal-apps-2026-10-29.md) §6.5 的结论一致。
- 待决（不阻塞 A 档）：是否启动 Apple 预沟通以解除 C 档的保留。

## 6. 修订纪录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| draft–draft-4 | 协调者 | 初稿；定下描述的存放与采用、并发规则、不进 Session、Android 一并冻结 | 无（没有实现方） |
| draft-5 | 协调者 | 写出 owning spec、schema 与向量；去掉 `tools_digest`；控件改为参数编辑器（§2.2） | 无（没有实现方） |
| `spec/device/v1/device-panel.md@5ed9d78d3f2b5c7eb22c8301dc3f39c98ee1bcec` | 协调者 | 冻结 A 档契约（用户指示执行冻结） | 无（没有实现方）；Swift implementer 待指定 |
| 同 revision（实施） | 协调者 + WP1–WP4 | Swift 实施落地；P18 目录/命名登记、P09 页面与平台差异登记；owning spec 端状态推进到 iOS `implemented`（真机未验） | iOS implementer（WP1–WP4）、WP5 评审 |
| 同 revision（评审后） | 协调者 + WP2/WP4 | WP5 评审：M2 恢复 `ble_link_result` 的两层既有忙文本；M1 面板观察工具表/授权变化；m3 `agent_only` 只显示名称与「仅 Agent 可用」；M3 修正 P18 状态；m2 登记 GAP-40；其余 MINOR 收窄声明或记为剩余风险 | WP2、WP4、WP5 |
| 同 revision（交付后审阅） | 契约 owner | §2.7：Agent 取消不打断面板调用；未结清请求跨页面保留；收窄 §5 iOS 行的测试声明 | iOS implementer |
| 同 revision（真机） | 契约 owner | §2.8：真机跑通 A0／A1 调用；面板体验修正；入口去掉开关 | iOS implementer |

## 7. 实施交付（2026-11-12）

| 项目 | 值 |
| --- | --- |
| Base | `8f3de8b8`（main 的 merge-base）；契约先以 `95124f59`／`5ed9d78d` 冻结 |
| Head | `e35a653d`（`feat/device-panel`；代码 head 与 WP5 复评的 `34a7137b` 相同，之后仅文档） |
| 分支 | `feat/device-panel`（集成）；`feat/device-panel-wp1-classifier` … `-wp4-ui`（各工作包） |
| 契约修订 | `spec/device/v1/device-panel.md@5ed9d78d3f2b5c7eb22c8301dc3f39c98ee1bcec`（条款未破坏性修改；P18/P09 按实施登记） |
| 端状态 | Swift/iOS `implemented`；Kotlin/Android `target`（GAP-20，未实现）；C 固件不变 |
| 评审 | WP5 独立评审两轮：`e323e3a3` 发现 3 MAJOR + 8 MINOR，`34a7137b` 复评确认 M1/M2/M3/m3 解决、m2 由 GAP-40 跟踪、无新 BLOCKER/MAJOR |
| 未验证 | 真机 iPhone + TonoLink M21-R4、断电/崩溃持久性、模型生成描述 E2E、Android、采用 sheet 真实 UI、真实断线、`.onChange` 的 UI 级观察 |
| 结论 | 可作为 `implemented` 交付 head；不得作为 `verified`／发布签收，真机证据齐了才推进 |

命令与逐条结果见 §4；两份共享向量、存储、准入与面板 model 的真实测试均通过，CI 只保留开工前已存在的失败
（`phone-p0-conformance` 的 3 条页面分歧由 GAP-38/GAP-39 跟踪、`phone-hygiene`、`phone-modules`、firmware-C
环境、`ProbeScenePhaseWiringTests`）。
