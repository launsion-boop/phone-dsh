<!-- SPDX-License-Identifier: MIT -->
# PC-20261113-phone-info — the iOS host answers the `info` row the Worker already publishes

## 0. 摘要

```yaml
change: PC-20261113-phone-info
contracts: [P19]
status: draft
breaking: false
version_decision: 无版本变更。`phone` 的调用形式、`P19` envelope 字段（`ok`/`tool`/`egress`/`scope`/`data`/`nextCursor`/`truncated`）、256 KiB 上限与错误码全部不变；只是 iOS 宿主补上 Worker 清单已经发布的那一行 `info`。
base: 175fe3f586393df660e77e8ab6fc0ddd157e81b9
contract_revision: 本单所属 commit（draft）——`examples/probe-app/ProbeKit/Capabilities/PhoneCapabilityGate.swift` 的 `info` 路由、`PhoneDeviceTools.info()`、`PhoneCapabilityBridge` 的 `case "info"`
```

## 1. 识别与角色

- **Trigger → 现况 → 期望。** `plugins/worker-entry/src/capabilities.ts` 的 `phoneCapability()` 对任何 `accelerator:phone` 宿主发布唯一一行 `info`（注释依据 Android `PhoneInfoTool`；HELLO 只带加速器、不带工具目录）。iOS 的 `PhoneToolCatalog.routes` 有 32 条、没有 `info`，`CompositePhoneToolBridge` 落进兜底并返回 `unknownTool`。真机：`phone info` → `{"ok":false,"tool":"info","error":{"code":"unknown_tool",…}}`。期望：iOS 宿主的实际路由覆盖清单发布的行，`phone info` 返回 `ok:true` 与 `data.model`/`data.systemVersion`/`data.display`。
- **Coordinator / contract owner**：本 worktree（宿主私有工具面）。**Implementer**：同一 commit 的 ProbeKit；没有 Kotlin/Rust 端需要改。
- **Owning spec / fixtures / schema**：P19（phone 工具 envelope）没有因本单改字段；`PhoneToolEnvelope` 是宿主实现。`PhoneToolCatalog.routes` 是「工具名 → 能力门禁」的唯一表。测试：`examples/probe-app/PhoneDSHSimTests/PhoneInfoToolTests.swift`。
- **受影响的 producer / consumer**：
  - Producer：iOS `PhoneCapabilityBridge`（`handles` 来自 catalog）；`PhoneDeviceTools.info()` 读 `UIDevice`/`UIScreen`，无需权限。
  - Consumer：Worker 的 `phone info` 命令（Rust `pdsh-phone` 把 `phone.<tool>` 转发给宿主），以及读 `capabilities.json` 的模型。
  - **未被要求**：HELLO 携带工具目录（治本方案，P01/P14/P17 范围）；Android 的 Kotlin `PhoneInfoTool`；`phone` 命令的 argv/JSON 形式。

## 2. 契约 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| `PhoneToolCatalog.routes["info"]` | 不存在 → `capability: .device`、`scope: "device.read"`、`writes: false`、`requiresFullAccess: false`。`.device` 在 iOS 权限模型里 `defaultEnabled == true` 且 `isReadOnlyAlwaysOn == true`，不会弹权限页。 |
| `PhoneCapabilityBridge.call` | `case "info"` 不存在 → `payload = device.info()`。 |
| `PhoneDeviceTools.info()` | 不存在 → `model`（SDK 设备类别）、`systemName`、`systemVersion`、`idiom`、`machine`（`uname` 硬件标识）、`display`（points/scale/native px/nativeScale）。 |
| P19 envelope | **不变**。`ok`、`tool`、`egress`、`scope`、`data`、`nextCursor`、`truncated` 的字段/编码/上限不变；`info` 走同一个 `PhoneToolEnvelope.success`。 |
| 错误语义 | **不变**。未知工具仍是 `unknown_tool`；`.device` 关闭仍是 `capability_disabled`。不新增错误码。 |
| `capabilities.json` | **不变**（本单没有改生成器；`info` 一行原本就发布）。 |

**自檢（spec/README.md §5.1）。** 没有新增第二种表达：`info` 没有第二个路由、没有第二个 envelope。没有放寬任何权限：`.device` 是只读且默认启用，不触发系统授权。没有新 enum/错误码。没有删除或重用任何名称。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old iOS host → new Worker manifest | 旧 host 没有 `info` 路由 → 仍返回 `unknown_tool`；清单原本就发布该行，这是**修复前的矛盾**，不是新协议。升级 host 后消失。 |
| new iOS host → old Worker manifest | 新 host 多一条可由 `phone.info` 调用的路由；旧 Worker 不发布该行，没有消费者会误用。无行为冲突。 |
| new → new | `phone info` → `{"ok":true,"tool":"info","data":{…}}`；`PhoneInfoToolTests` 直接驱动真实 `PhoneCapabilityBridge`，断言 catalog 路由、payload 字段与 envelope。 |
| persisted old data → new／rollback | 不適用：`info` 不读写任何持久化状态；没有 schema/版本字段。 |

- **版本決定**：不升版本。宿主私有路由的补齐，不改变任何跨端字节或 envelope。
- **部署順序**：ProbeKit/宿主（本 commit）→ 真机/模拟器验证 `phone info`。Worker 与清单不需要同步发布。
- **`target` 與仍保留的差異**：HELLO 带工具目录仍为 `target`；在那之前，Worker 只能发布「唯一已验证行」，宿主必须自己保证该行存在。任何新增手机工具仍要在 host catalog 与控制端同时落。

## 4. 分工與證據

- **本單獨占路徑**：`examples/probe-app/ProbeKit/Capabilities/PhoneCapabilityGate.swift`、`examples/probe-app/ProbeKit/Capabilities/PhoneDeviceTools.swift`、`examples/probe-app/ProbeKit/PhoneCapabilityBridge.swift`、`examples/probe-app/PhoneDSHSimTests/PhoneInfoToolTests.swift`、本单。
- **共享 fixtures**：无新增 golden；`PhoneInfoToolTests` 用真实 catalog/bridge 与 `UIDevice`/`UIScreen`。catalog 的正例是 `"info"` 存在；负例由既有 unknown-tool 测试覆盖。
- **各端真實 proof**：
  - `xcodebuild test -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/PhoneInfoToolTests` → **PASS**（3 tests，2026-11-13，模拟器 iPhone 17 Pro）。
  - `swift test --filter PhoneDSHBotTests` → **PASS**（750 tests；本单不依赖 Bot 包，顺带回归）。
  - 真机 `phone info` → **NOT_VERIFIED**（本机只能跑模拟器；交接单的真机证据仍是 `unknown_tool`）。
- **剩餘風險**：iOS 的 `UIDevice.model` 是 "iPhone" 而非营销型号；`machine`（`uname`）给硬件标识作为补充。`UIScreen.main` 在 iOS 26 的弃用警告未处理（与文件内既有 `deviceStatus` 同一做法）。HELLO 目录缺口未关，换平台仍可能重演。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | 本 worktree | 2026-11-13 交接单 P1-2：iOS 缺 `info` 路由，清单与宿主不一致。 | iOS 宿主；Worker/Android 只读记录；P01/P14/P17 owner 保留 HELLO 目录方案 |
