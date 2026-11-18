<!-- SPDX-License-Identifier: MIT -->
# 设备连接创建 Bot：把现有行为升为契约，并补齐 GATT / LAN / Android

## 0. 摘要

```yaml
change: PC-20261117-device-bot-contract
contracts: [P07, P18]
status: frozen
breaking: false
version_decision: 无 wire 变更。`deviceBots.v1` 保持 v1，新增键前缀为可加字段；读者必须原样保留未知键。
base: 3e8b1923
contract_revision: device-bot-v1  # spec/device/v1/device-bot.md + schema/device-bot-binding.schema.json + golden/device-bot-binding.jsonl (sha256 7c226b6c…a06d), checker spec/v1/tools/test_device_bot_binding_golden.py
```

Protocol impact: P07; P18; P09: none — 设备徽标与忘记设备时删 Bot 另出页面契约（Q4）; P26: none — 本单不改 Bot 工具面，设备授权仍是 App 级（见 §2 D7，列为后续）;
P27: none — Bot profile 与 rows 不变，绑定保持手机本地。若 §5 的 Q2 选了 B（给 profile 加来源字段），
P27 随即触发，本单须重发。

承接 [PC-20261114-device-bot](PC-20261114-device-bot.md)（`implemented`）。本单不推翻它，
只做三件事：把它的行为写成可测契约；补它没覆盖的设备类别；修它实现里与契约精神不符的几处。

## 1. 识别与角色

### 1.1 现状（已核对代码，base 3e8b1923）

「连接设备 → 自动得到一个 Bot」**部分做到，仅 iOS，仅 Link 设备**。

| 设备类别 | iOS | Android |
| --- | --- | --- |
| TonoLink 板子（语音链路） | 已做：连上语音链路即建「手机助手」，语音转给它 | 无（GAP-20） |
| 其他 BLE Link 设备 | 已做：`tools/list` 成功后建 Bot | 无 |
| 标准 GATT 设备（电池、温湿度、提醒） | **没有** | 无 |
| LAN MCP 设备（`_pdsh-mcp._tcp`） | **没有** | 无 |

实现位于 [DeviceBotRegistry.swift](../../examples/probe-app/PhoneDSHProbe/DeviceBotRegistry.swift)，
绑定存 `UserDefaults["deviceBots.v1"]`（`[设备键: Bot id]`）。规范文本只有
[tonolink-board.md §4.1](../../spec/device/v1/tonolink-board.md) 的一段话，没有 schema、golden，
`Tests/` 下没有 `DeviceBot` 相关测试。

### 1.2 与契约精神不符的实现细节（对照代码）

1. **按名称+描述回绑**：`ensureBot` 在配对丢失时用 `name == && description ==` 找「已有 Bot」绑定。
   用户自建的同名 Bot（例如手动建的「手机助手」）会被当成设备的 Bot。身份靠文本猜，违反
   AGENTS.md 规则 6（语义要保持，不能只保形状）。
2. **设备自报文本进入模型可见的 Bot 描述**：`description(for:)` 把 `device.name` 与
   `linkTools` 的工具名原样拼进 Bot 描述。设备名、工具名都是不可信输入（见
   [docs/ble-devices.md](../ble-devices.md)），而 Bot 描述会进入模型上下文，这是提示注入面。
3. **创建不带作者审计**：`composition.createBot(...)` 走的是无 `author` 的旧路径；
   `CreateTeammate` 走 `createBot(author:)` 并落 `ui.system_event{teammate.created}`。设备建的
   Bot 在事件日志里没有来源。
4. **键空间不统一**：Link 设备用裸的小写 `linkDeviceID`；板子用 `tonolink:<BLE 名>`。BLE 名是
   可被冒用的广播名，不是身份。同一块板子之后若列出 tools，可能再得到一个 Link 键的 Bot。
5. **触发点是「列出工具」，不是「连接」**，且靠 3 秒轮询 `BLEDeviceStore`；没有事件边界，
   也没有对「连接 ≠ 信任」的明确规定。
6. **实现在 probe-app 里**，不在库目标中，无法被单元测试驱动共享 fixture。

### 1.3 角色

- 协调者兼 contract owner：本任务主 agent（本单只改 `docs/protocol-changes/`；`spec/` 在 freeze 时由它改）。
- 实现者（各自独占路径，见 §4）：iOS、Android 各一；Android 受 GAP-20 约束，只做 §3 允许的部分。
- 集成审查：同一 head 上合并审查，fixture 过各端真实解码器。
- Owning 契约（新增）：`spec/device/v1/device-bot.md`；schema
  `spec/device/v1/schema/device-bot-binding.schema.json`；golden
  `spec/device/v1/golden/device-bot-binding.jsonl`。tonolink-board §4.1 改为引用它。

## 2. 契约 delta（Q1–Q4 已在 §5 决定）

| 项 | Before → After |
| --- | --- |
| D1 规范归属 | 一段话在 tonolink-board §4.1 → 新 `device-bot.md` 是唯一权威，§4.1 只引用 |
| D2 设备键 | 裸 `linkDeviceID` / `tonolink:<名>` → 键由类别前缀定义：无前缀 = Link 设备 id（小写，保持兼容）；`gatt:<CoreBluetooth UUID 小写>`；`lan:<已授权 MCP 端点 id>`；`tonolink:<名>` 仅作遗留键，板子一旦能给出 Link id 就迁到 Link 键（旧键保留不删）。键是设备在本机的标识，不是密码学身份 |
| D3 触发 | 轮询到 `linkTools` 非空 → 每类一个明确事件：Link=身份校验通过且 `tools/list` 成功（不变）；GATT=用户为该设备打开读取或提醒授权；LAN=用户授权该 MCP 端点。**扫描、广播、仅连接都不建 Bot** |
| D4 创建幂等 | 名称+描述回绑 → 先持久写「创建意图」`{key, creationID}` 再建 Bot，崩溃后只凭 `creationID` 恢复；**删除名称+描述回绑** |
| D5 生命周期 | 仅有「删 Bot→下次重建」「忘记设备→保留 Bot」→ 补全转换表：忘记后再配对同一键=重绑原 Bot；设备身份变化（新 Link id）=新 Bot；同名设备=各自一个 Bot，名称加区分后缀；用户删 Bot 后绑定作废，下次触发重建 |
| D6 不可信文本 | 原样拼接 → Bot 名称、描述全部由固定模板生成；设备自报名只允许经清洗（去控制字符/换行、NFC、≤60 字符）后用作名称；**描述不含设备自报自由文本**；工具名仅在匹配 `^[a-z0-9_.-]{1,64}$` 时列出且最多 8 个 |
| D7 权限范围 | 隐含「Bot=设备沙箱」的误解 → 明写：设备 Bot 不获得额外权限，设备授权仍是 App 级、所有 Bot 共用；按设备收窄工具是单独的后续变更（P26），本单不做 |
| D8 作者审计 | 无 → 设备建 Bot 走 `createBot(author:)`，事件 `teammate.created` 的 author 来源标为设备（具体字段见 Q2） |
| D9 持久化 | `UserDefaults` 字典整体回写 → 规定读者必须保留未知键；写入后立即同步（现状已有，升为条款）；Bot id 不存在于名册视为未绑定 |
| D10 平台状态 | 未声明 → iOS：Link 与 TonoLink `implemented`，GATT/LAN `target`；Android：全部 `target`，依赖 GAP-20 与 [device panel §4](../../spec/device/v1/device-panel.md) 的 Android 落地 |
| D11 条款状态 | 把 D2–D9 在 iOS 落地前标 `target`，只有 Link/TonoLink 的现有行为标 `implemented` |

自检（spec/README.md §5.1）：未新增第二种表达（键前缀是同一映射的扩展）；新键均可选且缺省=无 Bot；
读者对未知前缀保留不解释；没有删除或重用任何旧键名；D4 收紧了回绑规则，属于对 iOS 自身存量行为的收紧，
见 §3 的旧数据一行。

## 3. 相容性与发布

| Producer → Consumer | 处理 |
| --- | --- |
| old build → new data（出现 `gatt:`/`lan:` 键） | 旧版的 `bindings` 读写整本字典，保留未知键；旧版按 Link id 查表不会命中新键，行为=不为该设备建 Bot。需测试：旧写回路径不丢键 |
| new build → old data（只有裸键/`tonolink:`） | 全部有效。`tonolink:` 键继续可用，不强迁 |
| new → new | fixture 驱动 |
| 已存在的名称+描述回绑结果 | 已回绑的配对原样保留；删除的只是**今后**的猜测回绑。若配对丢失，会多建一个 Bot 而不是误绑别人的 Bot，代价是可能重复，列入「剩余风险」 |
| 回滚 | 回滚到旧版：新键保留，Bot 退化为普通 Bot；桌面端看到的永远是普通 Bot |
| Android | 本单不实现；iOS 与 Android 的差异在 D10 明确记录，不用平台私有分支补 |

- 版本决定依据：`deviceBots.v1` 的键空间是可加的，既有读者保留未知键 → 不升版本。若 Q1 选了别的存储（见 §5），再重评。
- 发布顺序：先冻结 spec 与 fixture → iOS 迁入库目标并补测试 → 再放开 GATT/LAN 触发。回滚限制：无。

## 4. 分工与证据（freeze 时填死）

- iOS 实现者独占：`examples/probe-app/PhoneDSHProbe/DeviceBotRegistry.swift`（迁出到库目标后的新路径）、
  `Tests/…` 新增的绑定测试；Bot 创建的 author 改动只在调用点。
- Android 实现者：本单**不分配**；GAP-20 解除前不动。
- 共享 fixture（contract owner 产出）：键派生、清洗、创建意图恢复、生命周期转换，各含正例、
  反例（控制字符名、超长名、同名不同设备、未知前缀、Bot 已删、崩溃于建 Bot 之前/之后）。
- 验收命令（待实现后在 freeze 时锁定；以下均为 **NOT_RUN**）：
  - `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` → NOT_RUN
  - iOS 绑定测试（真实注册表 + 共享 fixture）→ NOT_RUN
  - `bash scripts/ci/check.sh --only phone-rust-tests` → 不适用（不碰 P01/P02 编解码）
- 不会声称的：真机上 GATT 设备 / LAN 设备的建 Bot、桌面端看到的新 Bot、删 Bot 后重建，
  都没有证据；PC-20261114 记录的真机证据只覆盖 TonoLink 板子。

## 5. contract owner 决定（2026-11-17，按倾向定稿）

| # | 决定 | 后果 |
| --- | --- | --- |
| Q1 | 绑定留在 `UserDefaults["deviceBots.v1"]`，保持手机本地 | 不触发 P25；§3 的版本决定成立 |
| Q2 | 不给 Bot profile 加来源字段；`creationID` 与设备来源写进 `teammate.created` 事件的 author | 不触发 P27，§0 的 P27: none 成立；事件字段的具体编码在 freeze 时按 `BotTeammateAuthor` 现有形状定 |
| Q3 | GATT 设备在用户为其打开读取或提醒授权时建 Bot，不在连接时建 | D3 的 ⚑ 解除；与 docs/ble-devices.md「授权≠配对」一致 |
| Q4 | 设备徽标与「忘记设备时是否删 Bot」不在本单；另出 P09 页面契约 | 本单只记录需求，不改 UI |

决定已定并已 freeze 为 `device-bot-v1`（见 §0）。iOS 实现者可按本单 §4 开工；Android 不分配（GAP-20）。
注意：spec 文件已写好但**尚未提交**；实现者须基于提交后的 SHA，并把该 SHA 记入本单 `contract_revision`。

## 6. 剩余风险与未验证

- 契约已冻结，但 iOS 代码未改：`DeviceBotRegistry` 仍在 probe-app，仍按名称+描述回绑，仍把设备名拼进描述，直到实现者按本单改完。
- spec checker 通过不等于运行时一致；iOS 真实函数尚未读这份 golden。
- D4 之后，丢失配对的存量设备会多出一个 Bot（可接受，但需发布说明）。
- D7 只是写明现状：设备 Bot 与其他 Bot 共享设备授权，没有隔离。
- Android 的 mDNS 授权流程尚未接线（见 lan-mcp.md），LAN 触发在 Android 上没有可挂的事件。
- 新发现的差距应在 freeze 时登记到 spec/README.md §7：设备 Bot 无规范、无测试、实现在示例 App（暂记 GAP-新号，待 owner 分配）。

## 7. 修订记录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| draft-1 | 主 agent | 审查 iOS「连接设备建 Bot」现状后起草 | 未通知（草案） |
| draft-2 | 主 agent | 用户按倾向定下 Q1–Q4（§5） | 未通知；待 freeze |
| device-bot-v1 | 主 agent | 写出 device-bot.md、schema、golden 与 checker，冻结；`contracts` 去掉 P09（本单不改页面） | iOS 实现者待指派；Android 不通知（GAP-20） |
| device-bot-v1.1 | 主 agent（contract editor） | 客户看到原始 BLE 名（PDSH-xxxx）与带安装管线工具名的描述：Link 设备具备全部 8 个 device-app 工具时描述改为固定客户语句；技术 id 形名字回落 `设备助手`（§5）。仅文本；键、decide、complete 不变，不改名存量 Bot。golden 新增 15 条 name、7 条 description 向量（正反例），checker 哈希钉更新为 be43586e…37bf9 | iOS：DeviceBotBinding.swift 与测试同改；probe `ensureLink` 无需改动（沿用 `linkDescription(tools:)`/`name`）；Android 不通知（GAP-20） |
| device-bot-v1.2 | 主 agent（contract editor） | 真机：审计行 `teammate.created` 一直被拒（`origin.source` 无效），每 3 s 轮询建一个 Bot，40 分钟泄漏 125 个「PDSH Passport N」。新增 §6「Atomic creation and bounded retry」：创建原子（审计失败则删除刚建的 profile）、按 key 的退避与失败上限；`decide`／`complete`／golden 不变 | iOS BotMCP/DeviceBot 与示例 App 宿主（本次已改）；Android 尚未实现设备 Bot（GAP-20），无需通知 |
