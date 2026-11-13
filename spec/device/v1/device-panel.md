# 设备面板 v1（device-panel-v1）

Status: `partial` — iOS `implemented`（真机已跑通灯的开、关、读回，见变更单 §2.8），Android `target`（受 GAP-20 阻塞，未实现）。
Owner: P07（面板与调用语义）；宿主私有的已采用描述属 P18。
变更单：[PC-20261112-device-panel](../../../docs/protocol-changes/PC-20261112-device-panel.md)。

iOS 端已实现 §2 的分类器、§4.2 的求值器、§3 的调用路径与原生面板页：真实函数读 §7 的两份共享向量
（`Tests/PhoneDSHBLETests/DevicePanelVectorTests.swift`），已采用描述的存储、并发准入与调用有各自的回归，
面板页只经共用的 `LinkToolCaller` 调用设备。真机（iPhone + TonoLink M21-R4）上面板 model 经真实 BLE Link
完成了 `light.set`／`light.get` 的开、关、读回，以及采用描述后的预设按钮；断电恢复、撤销授权、
模型生成描述和页面在 App 导航里的触控操作仍未验证。Android 端未实现（GAP-20），不得把面板作为可用功能呈现（[基线](../../README.md) §2 状态词汇）。

## 1. 范围

设备面板让用户直接操作一台已连接、已协商 PDSH Link Tools v1 的设备，而不经过 Agent。它是
[BLE Link](ble-link.md) 工具的第二个调用者，不改变 Link 的 wire、opcode、能力位、工具表或错误。

- 面板只渲染数据：设备自报的 `tools/list`，以及可选的声明式描述（§4）。宿主不执行任何由模型或设备提供的代码。
- 设备文本（工具名、说明、schema、结果）和描述都是不受信任的数据：只作纯文本显示，宿主可截断，
  不解释为标记、链接或指令。
- 不在范围内：TonoLink 的 HID 与屏幕通道（[tonolink-board.md](tonolink-board.md) §1 不经 Link）；
  设备任务 profile；在页面内运行生成的 HTML／JS（变更单 §2.4、§2.5，前者是提案，后者是保留项）。
- 未协商 Tools 扩展的设备没有面板。

## 2. 由 `inputSchema` 得到编辑器

宿主对 `tools/list` 中每个工具的 `inputSchema` 运行下面的确定性分类。结果是 `editors`（附编辑器列表）
或 `agent_only`。`agent_only` 的工具在面板中只显示名称与「仅 Agent 可用」，不能从面板调用，除非有预设（§4）。

**根形式。** `inputSchema` 必须是 JSON 对象，成员只能是 `type`、`properties`、`required`、`additionalProperties`，并且：

- `type` 是 `"object"`，`additionalProperties` 是 `false`；
- `properties` 是对象，成员不超过 16 个；
- `required` 缺省为空；存在时是互不相同的字符串数组，每个都是 `properties` 的成员名。

否则整个工具是 `agent_only`。

**属性 → 编辑器。** 属性 schema 的成员集合必须**恰好**是下表某一行，多一个成员（包括 `description`）就不受支持：

| 属性 schema | 编辑器 | 条件 |
| --- | --- | --- |
| `{type: "boolean"}` | `toggle` | — |
| `{type: "integer", minimum, maximum}` | `slider`，`integer: true` | 两个界都是整数值，绝对值 ≤ 2^53−1，`minimum < maximum` |
| `{type: "number", minimum, maximum}` | `slider`，`integer: false` | 两个界都是有限数，`minimum < maximum` |
| `{type: "string", enum}` | `picker` | 1–32 个互不相同的字符串，每个 1–64 个 Unicode 标量值 |

- 必填属性不受支持时，整个工具是 `agent_only`。
- 可选属性不受支持时，该属性没有编辑器，面板永远不发送它；工具仍可渲染。
- 编辑器按参数名的 Unicode 码位升序排列（JSON 对象成员顺序不可移植）。工具按 `tools/list` 的数组顺序排列。
- 没有属性的工具是 `editors` 且列表为空：只有一个发送动作，参数是 `{}`。

**编辑器是参数输入，不是设备状态。** 宿主无法从工具表得知一个工具是否只读，也无法得知两个工具之间的关系：

- 编辑器初始为未设置。宿主不得把它显示成设备的当前状态，也不得因为调用被接受就推断设备已改变。
- 每个工具只有在用户明确点按发送时才被调用。宿主不得自动调用、轮询或在打开面板时预读任何工具，
  即使它看起来只读。
- 必填编辑器全部已设置后才能发送。未设置的可选参数不出现在请求里。
- 面板可以显示每个工具最近一次返回的结果（纯文本、可截断）及其时间；这是那次调用的结果，不是实时值。

## 3. 面板发起的调用

面板调用与 Agent 的 `ble_link_call` 是同一种 Link 逻辑请求，[BLE Link](ble-link.md)
「逻辑请求与结果」「持久化、重连和权限」的全部规则原样适用。面板不得另写一套调用实现，也不得绕过 journal。

| 项目 | 规则 |
| --- | --- |
| 请求 | 不变：≤4096 字节 JSON，root 四字段 |
| 关联 | 每次发送生成新的 journal 幂等 key 与 request UUID；一次发送恰好一个终态 |
| 授权 | 受同一份按设备、按工具的授权约束（规则 6）。工具被撤销时其控件禁用；`home.http` 仍须通过精确批准的私有 origin 校验，采用预设不构成批准 |
| 来源 | 记为用户，不记为模型 |
| 未执行 | `not_executed`（规则 7）：显示状态名，可重新发送 |
| 结果未知 | `outcome_unknown`：只显示「结果未知」并提供查询；**不自动重放**，不显示猜测的设备状态 |
| 取消／断线 | 沿用现有语义：已提交的操作可能仍在运行，恢复后只能查询 |
| 并发 | 见 [BLE Link](ble-link.md)「Link 调用准入」（`target`） |

**不进入设备 Session。** 面板调用不产生 host 事件，不写入设备固定 Session 的会话记录，不触发模型回合。
Agent 不会被告知面板操作，它要了解设备状态只能自己调用工具。面板调用写入同一个 Link journal；
其 request UUID 不交给 Agent，`ble_link_result` 的规则 4 不变，也不为面板记录另加过滤。

## 4. 面板描述

描述是一份可选的 JSON 文件，由模型生成，只改变面板**怎么显示**，不扩大**能做什么**：它不能修改授权、工具表或审批。
格式由 [schema/device-panel-descriptor.schema.json](schema/device-panel-descriptor.schema.json) 规定，封闭未知成员。

```json
{"v": 1, "device_id": "<Link device ID>", "title": "书房",
 "controls": [{"tool": "light.set", "label": "开灯", "group": "灯光", "preset": {"on": true}}]}
```

- `device_id` 是设备在 `tools/list` 中返回的 Link device ID，按字符串逐字比较（不折叠大小写）。
- `title`、`label`、`group` 是 1–40 个 Unicode 标量值的纯文本，不含 U+0000–U+001F 与 U+007F。
- `controls` 有 1–32 项，按数组顺序显示。带 `preset` 的项是一个按钮，点按即以该参数调用；
  不带 `preset` 的项用 `label` 显示该工具的 §2 编辑器。
- 有生效的描述时，面板只显示描述列出的控件；没有时显示 §2 的全部工具。

### 4.1 存放与采用

1. 模型用现有文件工具把描述写成工作区里的普通文件。不为此新增 MCP 工具、插件或 Remote 方法。
2. 用户在原生界面对该文件执行「采用」。采用界面在 WebView 之外，列出将显示的每个控件、它调用的工具，
   以及每个预设的完整参数；用户确认后才写入。
3. 宿主此时对文件字节求值（§4.2）。结果不是 `ok` 时不写入，显示原因，此前已采用的描述保持不变。
4. 结果是 `ok` 时，宿主把这些字节原样拷贝到宿主私有目录，按 Link device ID 存放，每台设备至多一份。
   写入必须原子；宿主不重新序列化。
   iOS 上有两个等价的入口：面板页的「采用描述…」，以及在对话或文件页打开 `device-panels/*.json` 时的原生预览。
   预览只画出控件的样子并照实列出每个控件将调用的工具与参数，其中的控件不调用设备；采用仍是用户在预览里的一次明确点按。
5. 面板只读宿主私有的那一份。工作区文件之后被改写或删除不影响已采用的描述；要生效必须再次采用。
6. 用户可以随时移除已采用的描述。

宿主私有副本是持久化格式（P18）：`<app container>/Library/Application Support/device-panels/`
下、文件名为 Link device ID 的 UTF-8 字节的 SHA-256 小写十六进制加 `.json`（64 个十六进制字符 + `.json`，
每台设备恰好一份）；目录按需创建。设备 ID 是设备自报的任意字符串，从不作为路径组成部分。
文件内容是描述字节本身，没有 envelope、没有附加元数据；格式就是本节的描述文件，`v` 是唯一的版本号。
旧 App 忽略该目录；回滚后重新升级须保留这些文件。

### 4.2 求值

`evaluate(字节, Link device ID, tools)` 按下列顺序返回第一个命中的结果。采用时，以及每次取得该设备新的
`tools/list` 时，宿主都对已采用的字节重新求值；结果不是 `ok` 时该描述不生效，面板回到 §2 并显示原因。
不做部分采用。

| 顺序 | 条件 | 结果 |
| --- | --- | --- |
| 1 | 超过 16384 字节 | `too_large` |
| 2 | 不是单个合法的 UTF-8 JSON 值（含截断、尾随非空白、`NaN`／`Infinity`），或容器嵌套超过 16 层（根容器为第 1 层，对象与数组都计） | `invalid_json` |
| 3 | 任意层的对象有重复成员名 | `duplicate_key` |
| 4 | 根不是对象 | `schema` |
| 5 | 根有成员 `v`，但它不是整数 1（`1.0`、`"1"` 都不是） | `unsupported_version` |
| 6 | 不符合描述 schema（含缺少 `v`） | `schema` |
| 7 | `device_id` 不等于该设备的 Link device ID | `device_mismatch` |
| 8 | 按数组顺序检查每个控件，返回第一个失败：见下 | — |
| 9 | 以上都未命中 | `ok` |

重复成员名可能在语法错误之前或之后被发现；一份文档同时有这两类问题时，结果是实现定义的二者之一，
共享向量不含这种情况。

第 8 步对每个控件：

- `tool` 不在 `tools` 中 → `tool_not_advertised`。
- 没有 `preset`：该工具的 §2 分类不是 `editors` → `tool_not_supported`。
- 有 `preset`：
  - 工具的 `inputSchema` 不满足 §2 的根形式，或有属性 schema 用了 `type`、`enum`、`minimum`、`maximum` 之外的成员，
    或 `type` 不是 `boolean`、`integer`、`number`、`string`、`object` 之一，或 `enum` 不是数组，
    或 `minimum`／`maximum` 出现在非数值类型上或不是有限数 → `tool_not_supported`。
  - `preset` 有 `properties` 之外的成员，缺少 `required` 的成员，或某个值不满足其属性的 `type`、`enum`、
    `minimum`、`maximum` → `preset_invalid`。`integer` 接受数学上为整数且绝对值 ≤ 2^53−1 的数；
    `object` 接受任意 JSON 对象；`enum` 比较要求类型相同且值相等；`null` 不满足任何类型。

预设校验所用的子集比 §2 的编辑器宽，所以预设可以调用 `agent_only` 的工具（例如带自由 `url` 的 `home.http`）。
这不放宽该工具自身的任何限制：设备仍是参数的最终校验者，§3 的授权与 origin 校验在每次调用时照常执行。

授权不是求值的一部分：描述引用了当前未授权的工具时仍可为 `ok`，对应控件按 §3 禁用。

## 5. 平台

| 端 | 状态 |
| --- | --- |
| iOS（Swift） | `implemented`：分类器、求值器、存储、准入与面板页；共享向量通过；面板 model 有 fake source 测试和一条真机测试（真实 BLE Link，`DevicePanelHardwareDeviceTests`）；没有触控级 UI 测试 |
| Android（Kotlin） | `target`，未实现，且受 GAP-20 阻塞：普通 Link 通道没有工具 RPC、持久意图与用户授权（[BLE Link](ble-link.md)「Android Link channel target」）。在该通道落地并有两端 runtime 证据之前，Android 不渲染面板，不调用 Link 工具，也不放置全部禁用的占位页 |
| 固件（C） | 不变。本文不要求设备新增字段、工具或行为 |

本文的规则对两个平台相同，两端读同一组向量。Android 实现时若某条规则在该平台无法照做，按
[AGENTS.md](../../../AGENTS.md) §3.3 提出 CONTRACT CHANGE REQUEST，不在 Android 侧另行处理。

## 6. 兼容性

- 旧固件（无 Tools 扩展）↔ 新 App：协商不成立，没有面板，不发工具 opcode。
- 新固件 ↔ 旧 App：无影响。
- 固件升级后工具表变化：已采用的描述重新求值；不再是 `ok` 时不生效，回到 §2。
- 旧数据／回滚：已采用的描述是新增文件，旧 App 忽略它，重新升级时必须保留。Link journal 格式不变。
- 未知 `v`：`unsupported_version`，整份不采用。`v` 1 的格式新增成员需要新的 `v`。

## 7. 共享向量与验证

- [golden/device-panel-mapping.jsonl](golden/device-panel-mapping.jsonl)：§2 的分类，
  行格式 [schema/device-panel-mapping-vector.schema.json](schema/device-panel-mapping-vector.schema.json)。
  含不受支持的根与属性、数值与枚举边界、可选与必填的差别。
- [golden/device-panel-descriptor-cases.jsonl](golden/device-panel-descriptor-cases.jsonl)：§4.2 的求值，
  行格式 [schema/device-panel-descriptor-case.schema.json](schema/device-panel-descriptor-case.schema.json)。
  `descriptor` 是待求值的原始文本；每个结果至少一例，并含大小边界、嵌套边界、重复成员名与判定顺序。

```sh
python3 -m unittest discover -s spec/v1/tools -p 'test_device_panel_golden.py'
```

该检查器固定向量内容、按 schema 校验，并用一份依本文写成的参考实现重放每一行。它是规范检查，不是 runtime 一致性：
每一端必须让真实的分类器和求值器读这两份文件。调用路径的回归（`not_executed`、`outcome_unknown`、断线、撤销授权、
并发准入）必须经真实的设备 store 与 journal，复用 [golden/pdsh-link.jsonl](golden/pdsh-link.jsonl)。
