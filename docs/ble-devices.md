# 标准 BLE 设备接入（首版）

目标为接入 iOS App 和原生 MCP 路由：设置 → 蓝牙设备。标准 GATT 优先；需要通用工具 / Home Bridge 的 ESP32 可以使用与 上游 Link 线格式兼容的可选 PDSH Link Tools 扩展。

## 用户闭环

1. 在设置页主动扫描并允许系统蓝牙权限；扫描最多 15 秒，离开页面即停止。
2. 手动选择设备连接，App 只发现下表中的标准服务和特征。
3. 逐设备打开读取授权；需要蜂鸣、震动或闪光提醒时，另外打开提醒控制授权。
4. 可在页面直接读取 / 提交提醒，也可以在聊天中让 Agent 使用 `ble_devices`、`ble_read`、`ble_alert`。
5. 断连、蓝牙关闭或 App 重启后重新连接并授权。不后台自动连接、不承诺永久连接。

设备 UUID 是 CoreBluetooth 对此 App 的外设标识，不是 MAC，也不是密码学身份。设备名、读数都属于不可信输入。系统根据设备的 GATT 安全要求处理配对；此 UI 的授权是 App 工具权限，不代表完成了加密绑定或设备身份验证。

## 支持的标准能力

| profile | Service | Characteristic | 数据 / 操作 |
|---|---|---|---|
| battery | 180F | 2A19 | uint8，0–100 % |
| temperature | 181A | 2A6E | LE sint16，0.01 °C，拒绝未知 / 禁用范围 |
| humidity | 181A | 2A6F | LE uint16，0.01 %，0–100 % |
| manufacturer | 180A | 2A29 | UTF-8 厂商名 |
| model | 180A | 2A24 | UTF-8 型号 |
| alert | 1802 | 2A06 | Write Without Response，0 停止 / 1 轻度 / 2 高度提醒 |

必须同时匹配 Service 和 Characteristic，不按特征 UUID 猜用途。多个同类服务实例导致能力不明确时不暴露该能力；首版不提供实例选择。读取要求实际 Read 属性；首版没有 Notify-only 设备订阅支持。

Immediate Alert 是寻找设备的提醒能力，不能作为通用 `light.set`、门锁或继电器协议。标准只规定提醒等级，实际由设备选择蜂鸣 / 震动 / 闪光。App 只报告 `submitted_unconfirmed`，不会报告已执行或伪造 state_revision。

## Agent 工具

工具继续走已有的、带鉴权的 `/mcp/native`，保留所有 Android 工具；Worker 侧沿用原生 MCP 注册机制。

- `ble_link_tools {"device_id":"<UUID>"}`：查看协商后的设备工具描述与 JSON 参数 schema，不执行动作。
- `ble_link_call {"device_id":"<UUID>","name":"light.set","args":{"on":true}}`：执行已获单独授权的设备工具；home.http 还需明确 origin。调用前持久化意图，中断后同 key 只查询，不再提交。
- `ble_link_result {"device_id":"<UUID>","request_id":"<UUID>"}`：按本地日志中的 request UUID 恢复查询，不重放动作。
- `ble_devices {}`：只列出用户扫描发现的设备、支持能力和本次连接授权，不触发扫描 / 配对。
- `ble_read {"device_id":"<UUID>","profile":"temperature"}`：新发起一次读取，结果带测量接收时间；不拿缓存冒充实时数据。10 秒超时，取消 / 超时断开连接，防止迟到回调被下一次读取误用。
- `ble_alert {"device_id":"<UUID>","level":1}`：还要求工具日志注入 `x-pdsh-idempotency-key`。持久化调用意图后才提交写入；同 key 不再写，参数不一致报冲突。重试或中断后只返回 `outcome_unknown`，需要检查设备。收据最多 4096 条，满时拒绝新写，不驱逐旧收据。

不提供任意 GATT UUID、原始写入或自动重放工具。蓝牙操作由主队列拥有，CoreBluetooth delegate 使用同一主队列；主线程隔离的 delegate conformance 使用 `@preconcurrency` 做运行时隔离检查。

## ESP32 / 其他硬件最短接入

实现上述标准 GATT 服务中的任意子集即可，不需要模型、MCP、DSH、账号或 PDSH JSON 消息：

- ESP-IDF/NimBLE：注册 Primary Service；为上述读特征配置 Read 和可选 Notify，按表编码读值。
- 提醒设备：注册 1802 / 2A06，配置 Write Without Response；只接受单字节 0、1、2。断连停止提醒，并提供本地停止动作或超时。
- 未知测量要使用标准未知值，不能用演示常量冒充传感器测量。
- 标准服务本身未必要求认证；需要保密或可信控制的产品还必须在固件中配置合适的配对、加密和物理在场机制。

标准电池 / 温湿度设备不需要修改固件，只要已经暴露对应的可读 GATT 服务。厂商私有协议、只在广告中广播的传感器、HID、经典蓝牙 HFP/A2DP、HomeKit/Matter、BLE Mesh 都不属于本版驱动范围。

## 虚拟设备

仓库提供 macOS CoreBluetooth 外设 `examples/ble-standard-device`。所有读数都是明确标注的合成 fixture：75%、25 °C、50%；提醒仅打印日志，不操作真实执行器。

从仓库根目录运行：

```sh
bash examples/ble-standard-device/build.sh
.build/BLEFixture.app/Contents/MacOS/BLEFixture
```

在 macOS 授权蓝牙后，iPhone 上扫描 `PDSH Virtual Fixture`，连接并授权即可测试。退出进程停止广告。需要具备外设广播能力的 Mac；不保证每个 Mac / iOS Simulator 都能模拟 BLE。这个示例不是 ESP32 固件。

## PDSH Link 与 ESP32 参考固件

已实现按 capability 和扩展标签协商的 Link Core：沿用 上游 Link UUID、HELLO、512 字节信封、CRC 和分段，在空闲的 0x54–0x56 增加有界工具上传 / 提交 / 结果查询。旧固件不声明能力时绝不发送扩展。

ESP-IDF 6.1 / NimBLE 参考固件提供 light.set / light.get、home.http、按键事件与 NVS 幂等。默认不操作 GPIO、不连接 Wi-Fi；根据实际板子配置后启用。参考硬件目标是 ESP32-S3；原分支记录了 ESP32-S3 和 iPhone 的 [真机 BLE / HTTP / 断连 / 重启验证](ble-hardware-testing.md)。

- [完整协议与兼容矩阵](../spec/device/v1/ble-link.md)
- [参考固件构建、接线配置和接入步骤](../firmware/esp32-reference/README.md)

音频、HID、通话、事件持久 WAL / 离线补传、自动 Agent 触发仍不在本版。旧 上游 Link 原本的 home.http 走 DeviceWS / MCP；旧设备要增加该协商扩展才可经 BLE 调用，不能无修改获得新能力。

## 规范与验证

- Apple CoreBluetooth
- Bluetooth SIG Assigned Numbers
- Immediate Alert Service
- GATT Specification Supplement

自动化：`swift test --filter StandardBLETests` 验证小端 / 负温度、长度、未知值、禁止范围、UTF-8 和提醒边界。iOS device build 验证 App 路由、UI 与 CoreBluetooth 编译；虚拟外设独立编译验证。真实空口、配对、断连回调与 ESP32 执行状态必须另用实际硬件验证，不能用编译通过替代。
