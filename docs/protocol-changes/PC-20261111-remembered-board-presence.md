# 记住的板子只在“在场”时才自动连接（P07）

```yaml
change: PC-20261111-remembered-board-presence
contracts: [P07]
status: implemented
breaking: false
version_decision: Behaviour fix inside the existing reconnect rule (ble-link.md rule 6). No wire, store key, grant or UI change.
base: 871488cf
contract_revision: spec/device/v1/ble-link.md rule 6 @ this PR head
```

Protocol impact: P07; P09: none — no page, row or copy changes; P27: none — TonoLinkVoiceHost.swift only asks the device store to reconnect, PC Link is unchanged

P07 — a remembered board is auto-connected only when present **and** connectable by this central (advertising, and the peripheral is `.disconnected`). A system-connected HID accessory is deliberately not adopted; see GAP-37. A board that is only known (`retrievePeripherals`) is listed but never connected blind; the post-drop watch runs about 6 minutes; the voice link's reconnect triggers the store's reconnect.

## 1. 问题

真机：板子重启离线几分钟后，聊天开灯报「Authorize this Link tool…」，蓝牙页显示「连接状态无法确认，暂不可用」，工具与授权清空，直到 App 重启。根因：`surfaceKnownPeripherals()` 把 `retrievePeripherals(withIdentifiers:)` 返回的“已知”板子当作发现记录并自动连接，掉线后的重试也对 `state == .disconnected` 的外设直接 `connect`。板子不在场时这次连接超时；按本规范的所有者规则，被取消的挂起连接没有断开回调可作证明，于是进入隔离，只能重启 App 解除。

## 2. Delta

| 项 | Before → After |
| --- | --- |
| 已知但不在场的记住板子 | 列出并自动连接（超时→隔离） → 只列出；**只有收到广播、且本 central 能提交连接（外设非 `.disconnected`）时才连接** |
| 系统层已连接的板子（例如 HID 自己重连） | 原设想“视为在场即连接” → **本版不接管**：`connect` 对外设状态非 `.disconnected` 直接返回，且接管系统连接会让 App 之后一次的断开拆掉系统 HID 链路；改为等广播或用户手动重连，登记为 GAP-37 |
| 掉线后观察 | 每 3 s × 20（1 分钟），且盲连 → 3 s × 20 后 15 s × 20（约 6 分钟），只在在场时连接，否则扫描等广播 |
| 语音 ctrl 连接恢复 | 无联动 → 触发 `reconnectRemembered()`（此时板子必然在场） |

隔离规则本身不变（仍不以超时或 `CBPeripheral.state` 作为断开证明）。

## 3. 相容性

纯手机端行为；无持久化、线格式或授权语义变化。

## 4. 证据

- `swift test --filter 'RememberedBoardPresenceTests|BLEIdentityTests'` → PASS；`PhoneDSHBLETests` 其余全部通过，`BLESecureCrossRuntimeTests`／`BLETaskCrossRuntimeTests` 因本机缺固件 C 工具链（cJSON／mbedTLS／IDF）失败，与本变更无关。
- 设备（longshu 上的 iPhone，PhoneAgent-7356）：板子控制台 `reboot` → 约 11 s 后设备库自动重新连接，再 5 s `light.get`／`light.set` 默认授权恢复，没有进入隔离；聊天「开灯」→ `ble_link_call light.set` → `on:true`、`completed`。
- 未验证：板子离线超过 6 分钟后、App 在后台时的恢复（此时依赖语音 ctrl 连接的挂起重连唤醒后触发）。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版 | iOS |
