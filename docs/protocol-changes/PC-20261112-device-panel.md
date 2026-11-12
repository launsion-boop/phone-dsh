# 设备面板（每个硬件一个「小程序」）— 契约变更单

```yaml
change: PC-20261112-device-panel
contracts: [P05, P07, P09, P18]
status: draft
breaking: false
version_decision: 不改任何现有版本。面板只消费现有 PDSH Link Tools v1；面板描述是新增的独立版本化文件（v 1）。
base: 8f3de8b8375bc9c32add4517f6eaadc815b8d4b5
contract_revision:
```

Protocol impact: P05; P07; P09; P18; P04: none — C 档只登记为保留项，不新增 handler、不改 bridge.md；
P21: none — B 档只是提案，`pdsh-page:` 的路由与 CSP 不变。

冻结的范围是 A 档（原生面板 + 声明式描述）的**契约**。没有任何一端的实现；owning spec 的状态是 `target`。

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
  Android 一栏届时为 `missing`，与 `TonoLinkUSBOTAPage` 的登记方式相同。不新增 baseline 或 whitelist 记录。
- 代价：双端规则在没有 Android 实现检验的情况下冻结。Android 落地时发现某条做不到，走 CONTRACT CHANGE REQUEST。

### 2.5 B、C 档

- **B**（无桥 H5 + 只读快照）需要在 P21 新增只读路由，而 render-media-v1.md 仍是 `draft`（GAP-09）。不在本单，不实现。
- **C**（意图桥）是保留项（AGENTS.md §2 规则 4）：不得实现，不得调用。解除保留需要 Apple 对 App Review Guideline 4.7.2
  的事先许可、作为 bridge.md 统一信封下的方法定义（不新增一次性 handler，见 GAP-01、GAP-05）、WebView 外的审批，
  以及一份带两端 runtime 证据的新变更单。

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
  Swift implementer（待指定）：`Sources/PhoneDSHBLE/**`、`Tests/PhoneDSHBLETests/**`、probe-app 面板页。
  Kotlin implementer：GAP-20 关闭后指定。
- **共享 fixtures。** `spec/device/v1/golden/device-panel-mapping.jsonl`（36 行）、
  `spec/device/v1/golden/device-panel-descriptor-cases.jsonl`（59 行，十种结果各至少一例）。两份都含正例、反例、
  数值与大小边界、未知值和判定顺序。
- **各端真实测试（均未开始）。** 分类器与求值器读上述两份文件；调用路径经真实 `BLEDeviceStore` 与 journal，
  覆盖 `not_executed`、`outcome_unknown`、断线、撤销授权、并发准入，复用 `golden/pdsh-link.jsonl`。
- **命令 → 结果**（macOS，contract revision 的工作树）：
  - `python3 -m unittest discover -s spec/v1/tools -p 'test_device_panel_golden.py'` → PASS（6 tests；规范检查，不是 runtime 一致性）
  - `python3 spec/tools/registry_build.py --check` → PASS
  - `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-license` → PASS
  - `python3 scripts/ci/protocol_impact.py --base main` → PASS（触发 P05、P07、P09）
  - `bash scripts/ci/check.sh --only phone-p0-conformance` → FAIL：`page-structure` 报 3 条 baseline 外的分歧；
    未改动的 base 上结果相同，与本单无关。其中 `spec/ui/v1/README.md` 的检查通过
  - `bash scripts/ci/check.sh --only phone-hygiene` → FAIL：全部指向既有文件中的禁用词与域名，没有一条指向本单改动的文件
  - `swift test`、`bash firmware/tests/run.sh`、Android 测试 → NOT_RUN（没有实现改动）
  - 真机 iPhone + TonoLink M21-R4 → NOT_RUN
- **未验证。** 任何实现、任何 runtime 行为、Android 上规则的可行性。
- **剩余风险。** §2.4 的 Android 风险（GAP-20）；§2.3 的并发行为变化；参考实现与规范文本出自同一作者，
  没有第二个独立实现交叉验证向量。

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
