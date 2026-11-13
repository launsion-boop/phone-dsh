# 设备面板（A 档）多 Agent 实施计划

日期：2026-11-12
读者：接手实现的协调者，以及他分派的各个 Agent。本文自成一体，不需要读之前的对话。
契约：[PC-20261112-device-panel](../protocol-changes/PC-20261112-device-panel.md)（`frozen`），
contract revision `spec/device/v1/device-panel.md@5ed9d78d3f2b5c7eb22c8301dc3f39c98ee1bcec`
契约所在 PR：[launsion-boop/phone-dsh#138](https://github.com/launsion-boop/phone-dsh/pull/138)，分支 `contract/device-panel`，head `95124f59`
协作规则：[AGENTS.md](../../AGENTS.md) §2、§3；[协议基线](../../spec/README.md) §3、§4、§7

## 1. 一句话

给每台已连接的 PDSH Link 设备做一个**原生**面板：按设备自报的工具参数 schema 生成输入控件，用户点按后调用设备工具；
可选地采用一份由模型生成的声明式描述来改标签、分组和预设。只做 iOS。不执行任何生成的代码。

契约已经冻结，实现一行都没写。本计划把实现拆成五个工作包，其中三个可以并行。

## 2. 开工前必须知道的

| 事项 | 状态 |
| --- | --- |
| 契约（规范、schema、向量、检查器） | 已冻结，在 PR #138。**先合并它，或从它的 head `95124f59` 拉分支**；不要基于没有这些文件的 `main` 开工 |
| iOS 实现 | not started — 本计划的全部工作 |
| Android 实现 | **不做**。受 GAP-20 阻塞（Android 没有可用的 Link 工具调用路径）。不渲染面板，不放占位页，不动 `android/**` |
| 固件 | **不改**。面板只读设备现有的 `tools/list`。不动 `firmware/**`，也不动仓外的 `tonolink-m21-r4-firmware` |
| Worker／插件 | **不改**。不新增 MCP 工具、插件、Remote 方法；不需要重建 Worker image |
| 生成 H5 的面板（B、C 档） | **不做**。C 档是保留项，实现它违反 AGENTS.md §2 规则 4 |

接手者需要的环境：macOS + Xcode（跑 `swift test` 和 probe-app）、Python 3、XcodeGen；真机验收需要一台 iPhone 和一块
TonoLink M21-R4（固件 `4359ac2` 或更新，能协商 PDSH Tools v1）。

两个与本工作无关、开工前就存在的门禁失败，不要去「修绿」，也不要因此放宽任何检查：

- `bash scripts/ci/check.sh --only phone-p0-conformance` → FAIL：`page-structure` 报 3 条基线外分歧（`main@8f3de8b8` 上相同）。
- `bash scripts/ci/check.sh --only phone-hygiene` → FAIL：既有文件里的禁用词与域名。

验收标准是「不新增失败」：开工前先各跑一次并保存输出，交付时逐条对比。

## 3. 必读（每个 Agent 开工前）

1. [AGENTS.md](../../AGENTS.md) 全文。重点：§2 七条规则、§3.2 实现者只在自己的路径里工作、§3.3 契约有问题时停下来提 CCR。
2. [spec/device/v1/device-panel.md](../../spec/device/v1/device-panel.md) 全文。这是规范，本计划与它冲突时以它为准。
3. [spec/device/v1/ble-link.md](../../spec/device/v1/ble-link.md) 的「逻辑请求与结果」「持久化、重连和权限」「Link 调用准入」三节。
4. [变更单](../protocol-changes/PC-20261112-device-panel.md) §2.1–§2.4。
5. 自己工作包列出的现有源码与测试。

## 4. 角色

| 角色 | 人数 | 职责 | 能改的路径 |
| --- | --- | --- | --- |
| 协调者兼 contract owner | 1 | 分派、处理 CCR、维护变更单；**唯一**能改 `spec/**` 的角色 | `spec/**`、`spec/tools/registry_build.py`、`docs/protocol-changes/PC-20261112-device-panel.md`、本文 |
| Agent A：分类器与求值器 | 1 | WP1 | 见 WP1 |
| Agent B：调用准入 | 1 | WP2 | 见 WP2 |
| Agent C：描述存储 | 1 | WP3 | 见 WP3 |
| Agent D：面板 UI | 1 | WP4 | 见 WP4 |
| 评审兼集成者 | 1 | WP5；不得同时是 A–D 中任何一个的实现者 | 只读；合并冲突由对应实现者修 |

实现者之间路径不重叠。需要改别人路径里的东西时，向协调者提出，由那条路径的所有者改。

## 5. 依赖与并行

```text
PR #138 合并（或从 95124f59 拉分支）
        │
        ├── WP1 分类器与求值器（A）──┐
        ├── WP2 调用准入（B）────────┼── WP4 面板 UI（D）── WP5 集成与真机（评审者）
        └── WP3 描述存储（C）────────┘
```

- WP1、WP2、WP3 互不依赖对方的实现，只依赖 §6 的接口签名，**可以同时开工**。
- WP4 在 §6 的签名定下后可以先搭界面，但要等 WP1–WP3 合入集成分支后才能验收。
- 建议每个工作包一个 git worktree 和一条分支，都从同一个基点拉出：
  `feat/device-panel-wp1-classifier`、`-wp2-admission`、`-wp3-store`、`-wp4-ui`，集成分支 `feat/device-panel`。

## 6. 工作包之间的内部接口

这些是 Swift 模块内部的 API，不是协议。它们的作用只是让四个 Agent 能并行。名字可以在开工会上调整，
但调整后要告诉所有人；语义必须与规范一致。

```swift
// WP1 提供（Sources/PhoneDSHBLE/DevicePanelSchema.swift）
enum DevicePanelEditor: Equatable {
    case toggle(arg: String, required: Bool)
    case slider(arg: String, required: Bool, integer: Bool, min: Double, max: Double)
    case picker(arg: String, required: Bool, options: [String])
}
enum DevicePanelRender: Equatable { case editors([DevicePanelEditor]), agentOnly }
func classifyDevicePanelTool(inputSchema: JSONValue) -> DevicePanelRender          // device-panel.md §2

// WP1 提供（Sources/PhoneDSHBLE/DevicePanelDescriptor.swift）
enum DevicePanelDescriptorResult: String {                                         // device-panel.md §4.2
    case ok, too_large, invalid_json, duplicate_key, schema, unsupported_version,
         device_mismatch, tool_not_advertised, tool_not_supported, preset_invalid
}
struct DevicePanelDescriptor { /* title、controls（tool、label、group、preset） */ }
func evaluateDevicePanelDescriptor(_ bytes: Data, linkDeviceID: String, tools: [JSONValue])
    -> (DevicePanelDescriptorResult, DevicePanelDescriptor?)                       // 只有 .ok 时有值

// WP2 提供（Sources/PhoneDSHBLE/LinkToolCaller.swift）
enum LinkCallOrigin { case agent, user }
// 面板与 DeviceMCPServer 共用的唯一入口：准入 → 授权 → 落盘意图 → 调用／查询。
// 忙在落盘之前抛出，且不产生 journal 记录。
func callLinkTool(deviceID: UUID, name: String, arguments: JSONValue,
                  idempotencyKey: String, origin: LinkCallOrigin) async throws -> LinkCallOutcome
// WP2 还要在 BLEDeviceStore 的设备模型上暴露设备原样返回的 Link device ID（见 WP2 第 4 条）。

// WP3 提供（Sources/PhoneDSHBLE/DevicePanelStore.swift）
func adoptDevicePanelDescriptor(_ bytes: Data, linkDeviceID: String, tools: [JSONValue]) throws -> DevicePanelDescriptorResult
func activeDevicePanelDescriptor(linkDeviceID: String, tools: [JSONValue]) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?)?
func removeDevicePanelDescriptor(linkDeviceID: String) throws
```

## 7. 工作包

### WP1 — 分类器与描述求值器（Agent A）

**目标。** 两个纯函数，没有蓝牙、没有 UI、没有文件 IO：按 device-panel.md §2 把一个工具的 `inputSchema` 分类成编辑器列表；
按 §4.2 对描述字节求值。

**独占路径。**

- `Sources/PhoneDSHBLE/DevicePanelSchema.swift`（新）
- `Sources/PhoneDSHBLE/DevicePanelDescriptor.swift`（新）
- `Tests/PhoneDSHBLETests/DevicePanelVectorTests.swift`（新）

**要做的。**

1. 实现 `classifyDevicePanelTool`，逐条对应 §2：根形式、四种属性形式、必填与可选的区别、按参数名的 Unicode 码位排序。
2. 实现 `evaluateDevicePanelDescriptor`，判定顺序与 §4.2 的表完全一致。
3. 测试读取 `spec/device/v1/golden/device-panel-mapping.jsonl`（36 行）和
   `spec/device/v1/golden/device-panel-descriptor-cases.jsonl`（59 行），**每一行**都经真实函数并断言结果。
   定位仓库根目录的写法参考 `Tests/PhoneDSHBLETests/BLEScanIntentTests.swift`。测试必须断言行数，防止文件读空也通过。

**容易做错的地方。**

- **重复成员名。** `JSONSerialization` 和 `JSONDecoder` 会悄悄丢掉重复的 key，必须在解析前扫描原始字节。
  仓库里已有 `Sources/PhoneDSHDeviceTasks/UniqueJSONKeys.swift`（`PhoneDSHBLE` 依赖该模块）。它目前是 internal，
  要复用需请协调者安排该文件的所有者放开可见性；不要复制一份。
- **`v` 必须是整数 1。** `1.0` 和 `"1"` 都是 `unsupported_version`。Foundation 解析后分不清 `1` 和 `1.0`，
  需要看原始 token。向量 `version_float_one` 专门测这一条。
- **预设里的 `integer` 相反**：`50.0` 可以通过（向量 `preset_integral_float`），`50.5` 不行。两处规则不同，别统一。
- **大小按字节算**（16384，UTF-8），文本长度按 Unicode 标量值算（40），不是 `String.count`（字素簇）也不是 UTF-16 长度。
- **嵌套深度**：根容器算第 1 层，对象和数组都计，超过 16 层是 `invalid_json`。
- **`NaN`／`Infinity`** 是 `invalid_json`。
- **整数界** 的绝对值上限是 2^53−1；`9007199254740992` 作为界时该属性不受支持。别让它经过 `Double` 后被四舍五入成合法值。
- **`device_id` 逐字比较**，不折叠大小写（向量 `device_id_case_differs`）。
- 属性 schema 多一个成员（哪怕是 `description`）就不受支持。这是有意的封闭规则，不要「宽容处理」。

**验收。**

- `swift test --filter DevicePanelVectorTests` → PASS，且两份向量逐行通过。
- 至少再加：故意改坏一行期望值时测试会失败（防止测试是空转的）。

**Protocol impact：** P07（`Sources/PhoneDSHBLE/**`）。

---

### WP2 — Link 调用准入（Agent B）

**目标。** 把「落盘意图 + 调用」从 `DeviceMCPServer` 提成面板和 Agent 共用的一段，并让「忙」在落盘之前判定
（ble-link.md「Link 调用准入」）。这是本计划里**唯一改变现有行为**的工作包，风险最高。

**独占路径。**

- `Sources/PhoneDSHBLE/DeviceMCPServer.swift`
- `Sources/PhoneDSHBLE/BLEDeviceStore.swift`
- `Sources/PhoneDSHBLE/LinkToolJournal.swift`
- `Sources/PhoneDSHBLE/LinkToolCaller.swift`（新）
- `Tests/PhoneDSHBLETests/BLEDeviceMCPTests.swift`、`DeviceMCPNativeRegressionTests.swift`、`LinkAdmissionTests.swift`（新）

**现状（先读懂再动）。**

- `DeviceMCPServer.swift` 的 `ble_link_call` 分支：检查 `activeLinkID` → `authorizeLink` → `linkJournal.prepare`（落盘）→
  `BLEDeviceStore.invokeLink` 或 `queryLink`。
- `BLEDeviceStore.invokeLink`／`queryLink` 内部再检查一次 `linkBusy`，此时意图已经落盘；它的拒绝被外层的通用 `catch`
  报告成 `outcome_unknown`。

**要做的。**

1. 新增共用入口（§6 的 `callLinkTool`）。顺序必须是：**准入（忙则立即失败）→ 授权 → 落盘意图 → 调用或查询**。
2. `DeviceMCPServer` 的 `ble_link_call`、`ble_link_result` 改为调用这个入口。面板（WP4）也只调用它。
   `BLEDeviceStore.invokeLink` 不再有 `PhoneDSHBLE` 之外或绕过入口的调用者。
3. 被准入拒绝的调用：没有 journal 记录，没有 request UUID，没有上传字节。
4. 在设备模型上暴露设备在 `tools/list` 中**原样返回**的 Link device ID。现在的 `linkIdentity` 是 `deviceID.lowercased()`
   （`BLEDeviceStore.swift` 有两处赋值，约 1743 行和 2154 行），而规范要求描述的 `device_id` 逐字比较。新增一个字段保存原值；不要改 `linkIdentity`
   的现有含义，它有别的使用者。
5. journal 需要记录来源（agent／user）吗？规范只要求「来源记为用户」且面板的 request UUID 不交给 Agent。
   最小做法是来源只影响面板自己的显示与日志，**不改 journal 的落盘格式**。如果你认为必须改格式，那是 P18 持久化变更，
   停下来提 CCR。

**必须保持不变的。**

- MCP 工具表、工具名、参数、返回文本、错误文本，除下面一种情形外逐字节不变。`golden/native-mcp/ble-devices.json` 相关测试必须原样通过。
- 幂等 key、request UUID、`not_executed`、`outcome_unknown` 只能查询不重放（ble-link.md 规则 1–7）。
- 设备任务（`DeviceTaskManager`）占用 Link 的路径继续工作。

**唯一允许的可观察变化。** Agent 调用时 store 正忙（例如面板或设备任务占着 Link）：以前是「落盘 + `outcome_unknown`」，
现在是「忙，且无记录」。为它写一条回归：先让另一调用占住 Link，再发起 `ble_link_call`，断言得到忙错误、
journal 目录没有新文件、之后用同一幂等 key 重新调用可以正常执行。

**需要协调者决定的。** 现在有两条忙文本（"Another Link call is running"、"Link is busy"）。合并准入后是否统一成一条，
开工前问协调者。在得到答复前保留现有文本，不新增第三条，不新增错误码。

**验收。**

- `swift test --filter PhoneDSHBLETests` → PASS，现有测试无修改地通过（除非某个测试断言的正是上面那种被改变的行为，
  这种情况列出来交给评审者）。
- 新的 `LinkAdmissionTests`：两个调用者并发、被拒者无 journal 记录、先到者不受影响、被拒后可重试、
  `ble_link_result` 在调用进行中被拒的行为。
- `bash firmware/tests/run.sh` → PASS（确认没碰设备端；不需要改任何固件文件）。

**Protocol impact：** P05; P07; P18: none — `LinkToolJournal.swift` 被触及但落盘格式不变（若格式变了，这条不成立，先提 CCR）。

---

### WP3 — 已采用描述的存储（Agent C）

**目标。** device-panel.md §4.1：把通过求值的描述字节原样、原子地存到宿主私有目录，每台设备至多一份；读取时重新求值。

**独占路径。**

- `Sources/PhoneDSHBLE/DevicePanelStore.swift`（新）
- `Tests/PhoneDSHBLETests/DevicePanelStoreTests.swift`（新）

**要做的。**

1. `adopt`：调用 WP1 的求值器；不是 `ok` 就不写，返回结果，已有的那份保持不变。是 `ok` 才原子写入**原始字节**，不重新序列化。
2. `active`：读出字节，用**当前**的 `tools/list` 重新求值。不是 `ok` 时返回结果和原因，但**不删除**文件
   （固件回滚或工具表恢复后它可能重新生效）。
3. `remove`：删除该设备的那一份。
4. 存放在 Application Support 下的专用子目录。文件名**不能**直接用 Link device ID（它是设备给的任意字符串，
   可能含 `/` 或 `..`）；用它的 SHA-256 十六进制做文件名。
5. 目录位置可注入，测试用临时目录。

**边界情况要有测试。** 写入中途失败不留下半个文件；同一设备第二次采用覆盖第一次；采用失败不影响已有的；
两台设备互不影响；Link device ID 含路径字符；文件被外部改坏后 `active` 返回对应的失败结果而不是崩溃。

**需要协调者做的。** 这份私有副本是新的持久化格式（P18）。把最终的目录名和文件命名规则告诉协调者，
由他登记到 `spec/README.md` 的 P18 行和触发表，并重新生成 `spec/registry.json`。你不要自己改 `spec/`。

**验收。** `swift test --filter DevicePanelStoreTests` → PASS。

**Protocol impact：** P07; P18。

---

### WP4 — 面板页与采用界面（Agent D）

**目标。** 用户能看到的部分。依赖 WP1–WP3。

**独占路径。**

- `examples/probe-app/PhoneDSHProbe/DevicePanelPage.swift`（新）
- `examples/probe-app/PhoneDSHProbe/DevicePanelAdoptionSheet.swift`（新）
- `examples/probe-app/PhoneDSHProbe/BluetoothDevicesPage.swift`（只加入口）
- `examples/probe-app/project.yml` 及由 XcodeGen 生成的工程文件（如需）
- 对应的 UI 测试文件（新）

**要做的。**

1. 入口：蓝牙设备页里，已连接且已协商 PDSH Tools v1 的设备行进入面板页。整个功能放在一个默认**关闭**的开关后面。
2. 没有生效描述时：按 `tools/list` 的顺序列出每个工具。`editors` 的工具显示它的编辑器和一个发送按钮；
   `agentOnly` 的工具只显示名称和「仅 Agent 可用」。
3. 有生效描述时：只显示描述里的控件，按数组顺序、按 `group` 分组。带 `preset` 的是按钮；不带的显示该工具的编辑器。
4. 发送：只调用 WP2 的 `callLinkTool`，`origin: .user`，每次点按生成新的幂等 key。同一设备有调用在进行时，其余发送控件禁用。
5. 结果显示：`not_executed` 显示状态名并允许重发；`outcome_unknown` 显示「结果未知」和一个查询按钮，**不自动重试**；
   成功时显示该工具最近一次返回的结果文本和时间。
6. 采用界面：原生 sheet，列出将显示的每个控件、它调用的工具、每个预设的**完整参数**。用户确认后才调用 WP3 的 `adopt`。
   失败时显示结果码对应的原因。提供「移除描述」。
7. 已采用的描述失效时（重新求值不是 `ok`），面板回到第 2 条并显示原因。

**规范里的硬性约束，最容易在 UI 层被无意破坏。**

- **不自动调用任何工具。** 打开页面、下拉刷新、定时器都不行，哪怕工具叫 `light.get`。只有用户点发送才调用。
- **编辑器不是设备状态。** 初始是「未设置」，不能默认显示成关或 0。发送成功后也不要把开关标成「设备已开」。
  对布尔参数，用两个选项（比如分段控件）比用系统开关更不容易误导，因为开关没有「未设置」态。
- **设备文本一律纯文本。** 工具名、说明、结果都可能是恶意内容：不用 `Text(LocalizedStringKey)`／Markdown／`AttributedString`
  解析它，不把它当链接，长文本截断。描述里的 `label`／`title`／`group` 同理。
- 工具被撤销授权时控件禁用。采用描述不等于授权，也不等于批准 `home.http` 的 origin。
- 面板调用不写入任何会话、不触发模型回合、不产生 host 事件。
- 采用界面不能放在 WebView 里。

**两个需要协调者在开工时定的产品问题**（规范没有规定，定下来后写进变更单）：

- 「采用」从哪里触发：建议在面板页放「从工作区选择描述文件」，并且在文件／产物列表里对符合命名约定的 JSON 文件提供「采用为设备面板」。
- 模型该把描述写到工作区的哪个路径、叫什么名字。规范只说「工作区里的普通文件」。需要一个约定，Agent 才知道往哪写。
  注意：约定路径名不需要新增协议面，但如果想让模型**知道**这个约定（改系统提示或预设），那会触及插件或 preset，要另行评估。

**做完后交给协调者的事。** iOS 页面落地后，页面结构契约要由提取器生成（`spec/ui/v1/tools/extract_ios_pages.py`），
`spec/ui/v1/README.md` §1 的 `DevicePanelPage` 行要补入口细节。这些在 `spec/` 下，由协调者做；你提供页面源码路径和入口说明。
Android 一栏会是 `missing`，这是预期的，不要为此去写 Kotlin 页面。

**验收。**

- probe-app 的模拟器构建通过（命令见 §9）。
- 模拟器里用一个假的设备数据源能走通：无描述面板、采用描述、描述失效回退、移除描述。
- 以上不算设备验证。真机部分在 WP5。

**Protocol impact：** P07; P09。

---

### WP5 — 集成、评审与真机验收（评审兼集成者）

1. 把四条分支合到 `feat/device-panel`，在**同一个 head SHA** 上评审合并后的 diff，不是分别看四个 PR。
2. 逐条核对：
   - 两份共享向量确实经过 Swift 的真实分类器和求值器（不是测试里手写的副本）。
   - 面板和 `DeviceMCPServer` 走的是同一个调用入口；全仓搜索 `invokeLink(`，确认没有绕过准入的调用者。
   - WP4 的六条硬性约束，逐条在代码里找到依据。
   - 没有人改了 `spec/`（协调者除外）、`android/**`、`firmware/**`、`plugins/**`。
   - 变更单 §2.3 的行为变化有回归覆盖。
3. 跑 §9 的全部命令，结果原样记录。
4. 真机（iPhone + TonoLink M21-R4）：
   - 连接板子，打开面板，看到 `light.set`、`light.get`（配置了 Home origin 时还有 `home.http`，应显示为仅 Agent 可用）。
   - 发送 `light.set {on: true}`／`{on: false}`，灯实际变化；点 `light.get` 得到结果。
   - 面板调用进行中，让 Agent 调 `ble_link_call`：Agent 得到忙，之后重试成功。反过来也测一次。
   - 发送后立刻让板子断电：面板显示「结果未知」，不自动重发；板子恢复后查询得到状态。
   - 让模型为这块板子生成描述，采用，面板按描述显示；采用一份 `device_id` 不符的描述被拒。
   - 在设置里撤销 `light.set` 授权：对应控件禁用。
5. 发现两端不一致或规范有歧义：在 owning contract 里解决（交给协调者），然后重跑受影响的端。新发现的分歧登记为 GAP。
6. 全部通过后，由协调者把 device-panel.md 的 iOS 状态和变更单的 `status` 推进到 `implemented`；真机证据齐了才是 `verified`。
   **模拟器结果不能写成设备结论。**

## 8. 契约有问题时

实现者发现规范有歧义、写错了、或在平台上做不到，**不要绕过去**，停下那一部分并发给协调者：

```text
CONTRACT CHANGE REQUEST
Contract: P07 @ spec/device/v1/device-panel.md@5ed9d78d   Clause: <文件#小节>
Problem: <按现文无法实现之处，附证据>
Proposal: <最小的改动>   Affects: <其他端>
```

协调者更新规范、向量和变更单，出新的 revision，通知所有受影响的 Agent。在此之前任何人不得加本地字段、别名、兜底分支。

已经能预见、值得提前想的几处：

- 规范要求 `device_id` 逐字比较，而现有 store 把 Link device ID 转成小写保存（WP2 第 4 条）。按本计划暴露原值即可；
  如果实际拿不到原值，这是一条 CCR。
- 向量的参考实现和规范文本出自同一作者，没有被第二个独立实现验证过。Swift 实现与某行向量不一致时，
  **先怀疑向量**：对照规范文本判断谁对，向量错了就提 CCR，不要改实现去迁就错的向量，也不要反过来悄悄改向量。
- 变更单 §2.2 记了两处由 contract owner 决定、需求方尚未明确确认的设计（去掉 `tools_digest`；控件是参数输入而非设备状态）。
  开工前请协调者向需求方确认。若被推翻，会出新 revision，WP1 和 WP4 受影响。

## 9. 验收命令

在集成分支的同一个 head 上运行，结果按 `PASS｜FAIL｜SKIP｜INCOMPLETE｜NOT_RUN` 原样记录。

```sh
# 规范检查（不是 runtime 一致性）
python3 -m unittest discover -s spec/v1/tools -p 'test_device_panel_golden.py'
python3 spec/tools/registry_build.py --check
bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree

# Swift 真实实现
swift test --filter PhoneDSHBLETests
bash scripts/ci/check.sh --only phone-sdk

# 确认设备端未变
bash firmware/tests/run.sh

# App 构建（在 examples/probe-app 下）
xcodebuild -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# 其余门禁
bash scripts/ci/check.sh --only phone-hygiene,phone-license,phone-modules,phone-no-dsh-patch

# PR 描述里的 Protocol impact 声明
python3 scripts/ci/protocol_impact.py --base main --body-file <PR 正文文件>
```

`phone-p0-conformance` 和 `phone-hygiene` 开工前就是 FAIL（见 §2）。要求是失败条目与开工前相同，不多不少。
协调者为 WP4 生成页面结构契约后，`phone-p0-conformance` 里与 `DevicePanelPage` 有关的条目必须是干净的。

## 10. 每个 Agent 的交付格式

每个工作包交付时，按 AGENTS.md §3.5 填写：

```text
Base / head:        <sha> / <sha>
Protocol impact:    <见各工作包>
Contract revision:  spec/device/v1/device-panel.md@5ed9d78d3f2b5c7eb22c8301dc3f39c98ee1bcec
Changed files:      <按端列出>
Status per end:     Swift implemented｜partial；Kotlin not started（GAP-20）；C 不变
Commands → result:  <确切命令> → PASS｜FAIL｜SKIP｜INCOMPLETE｜NOT_RUN
Not verified:       <真机、断电、模型 E2E、其他平台…>
Remaining risks:    <以及跟踪它的 GAP 或负责人>
```

## 11. 给各 Agent 的开工指令（可直接粘贴）

把对应的一段连同本文的路径发给 Agent。每段都假定 Agent 会先读 §3 的必读材料。

**Agent A（WP1）**

> 在仓库 phone-dsh 里实现设备面板的分类器和描述求值器。先读 `AGENTS.md`、`spec/device/v1/device-panel.md`
> 和 `docs/handoffs/2026-11-12-device-panel-implementation-plan.md` 的 §6、§7 WP1。只在 WP1 列出的三个文件里工作，
> 不改 `spec/`。两个函数必须让 `spec/device/v1/golden/device-panel-mapping.jsonl` 和 `device-panel-descriptor-cases.jsonl`
> 的每一行通过，测试直接读这两份文件。规范或向量有问题时按计划 §8 提 CONTRACT CHANGE REQUEST 并停下那一部分，
> 不要绕过。完成标准：`swift test --filter DevicePanelVectorTests` 通过，并按计划 §10 的格式交付。

**Agent B（WP2）**

> 在仓库 phone-dsh 里把 Link 工具调用的「准入 → 授权 → 落盘 → 调用」提成一个共用入口，让忙在落盘之前判定。
> 先读 `AGENTS.md`、`spec/device/v1/ble-link.md` 的「持久化、重连和权限」与「Link 调用准入」、
> 以及计划文档 `docs/handoffs/2026-11-12-device-panel-implementation-plan.md` 的 §6、§7 WP2。只在 WP2 列出的文件里工作。
> 现有 MCP 行为除计划写明的那一种情形外必须逐字节不变，现有测试必须原样通过。不改 journal 的落盘格式；
> 认为必须改时停下来提 CONTRACT CHANGE REQUEST。完成标准：`swift test --filter PhoneDSHBLETests` 通过，
> 新增并发准入回归，按计划 §10 的格式交付，并单独列出每一处可观察行为的变化。

**Agent C（WP3）**

> 在仓库 phone-dsh 里实现已采用面板描述的宿主私有存储。先读 `AGENTS.md`、`spec/device/v1/device-panel.md` §4、
> 计划文档 `docs/handoffs/2026-11-12-device-panel-implementation-plan.md` 的 §6、§7 WP3。只在 WP3 列出的两个文件里工作。
> 求值器由别人实现，按 §6 的签名调用；在它合入之前可以用一个测试替身。原样、原子地存字节，文件名用 Link device ID 的
> SHA-256。完成标准：`swift test --filter DevicePanelStoreTests` 通过，按计划 §10 的格式交付，
> 并把最终的目录与命名规则报告给协调者以便登记 P18。

**Agent D（WP4）**

> 在仓库 phone-dsh 的 probe-app 里实现设备面板页和描述采用界面。先读 `AGENTS.md`、`spec/device/v1/device-panel.md`
> 全文、计划文档 `docs/handoffs/2026-11-12-device-panel-implementation-plan.md` 的 §6、§7 WP4。只在 WP4 列出的文件里工作，
> 不写 Android，不改 `spec/`。调用设备只能通过共用入口 `callLinkTool`。WP4 小节里的六条硬性约束每一条都要遵守，
> 尤其是：不自动调用任何工具、编辑器不显示为设备状态、设备文本只作纯文本。整个功能放在默认关闭的开关后面。
> 完成标准：模拟器构建通过，四个流程可走通，按计划 §10 的格式交付，并说明哪些只在模拟器验证过。

**评审兼集成者（WP5）**

> 评审并集成设备面板的四个工作包。先读 `AGENTS.md` §3.4、`spec/device/v1/device-panel.md`、
> 变更单 `docs/protocol-changes/PC-20261112-device-panel.md` 和计划文档
> `docs/handoffs/2026-11-12-device-panel-implementation-plan.md` 的 §7 WP5、§9。在同一个 head SHA 上评审合并后的 diff。
> 你不修改实现；发现问题时指给对应的实现者或协调者。结果如实记录，模拟器结果不得写成设备结论。

## 12. 不要做的事

- 不实现生成 H5 的面板，不给任何 WebView 加调用设备的 message handler。
- 不新增 MCP 工具、wire 字段、能力位、错误码、环境变量或依赖。
- 不为了让测试通过而放宽 schema、删向量、改期望值、扩 baseline 或跳过检查。
- 不写 Android 页面或 Android Link 调用。
- 不改固件。想要颜色、亮度之类的新控件，那是固件工具表的变更，需要另一份变更单。
- 不让实现者改 `spec/`。
- 不把本计划当规范。它与 device-panel.md 冲突时，规范为准，并告诉协调者修正本文。
