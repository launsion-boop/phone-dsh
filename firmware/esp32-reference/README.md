# ESP32-S3 PDSH BLE Link 参考固件

这是独立的 ESP-IDF 6.1 / NimBLE 项目，复用 phone-dsh 内的纯 C wire 核心和 xiaozhi-link MIT Home HTTP 策略 / 有界 TCP transport。没有修改旁边的 xiaozhi-link 仓库，也不依赖它的绝对路径。

提供：旧 Link HELLO / GET_STATUS、协商式 PDSH Tools v1、工具发现、`light.set` / `light.get`、BLE `home.http`、按键事件、加密绑定与持久化幂等回执。没有 LLM / MCP runtime / 云账号 / 音频依赖。线协议详见 [PDSH BLE Link](../../spec/device/v1/ble-link.md)。

## 构建

安装 ESP-IDF 6.1 和 ESP32-S3 工具链后，从本目录：

```sh
. /path/to/esp-idf/export.sh
idf.py set-target esp32s3
idf.py menuconfig
idf.py build
```

配置项：

| 菜单 | 配置 | 用途 |
|---|---|---|
| PDSH reference board | PDSH_LED_GPIO | 接普通单色 LED 的 GPIO；默认 -1 不操作任何引脚。不支持 WS2812 / RGB 数字灯协议 |
| PDSH reference board | PDSH_BUTTON_GPIO | 低电平按键，默认 0（开发板 BOOT）；-1 禁用 |
| PDSH reference board | PDSH_WIFI_SSID / PASSWORD | 家居 Wi-Fi；空 SSID 关闭 Wi-Fi |
| PDSH Home HTTP | PDSH_HOME_ORIGIN | 唯一允许地址，例如 `http://192.168.1.50:8123`；空值禁用 home.http |

工具按实际配置声明：LED GPIO 未配置不暴露 light.*；没有 Wi-Fi SSID / Home origin 不暴露 home.http。默认配置没有硬件控制能力；先选对板子引脚、接好限流电阻，再启用。Wi-Fi 配置仅用于此参考固件，配置文件和 build 目录已 gitignore，不要把真实凭据提交到仓库。产品集成可替换为自己的安全配网与凭据存储。

其它具备 BLE 的 ESP32 型号可按 IDF 的 set-target 调整引脚、闪存和分区，但当前交叉编译验证目标是 **ESP32-S3**。本项目无需 PSRAM；`pdsh_home_transport.c` 为上游传输代码提供小型状态对象的片内 RAM 分配适配，保留 vendor 原文件。

## 烧录与手机接入

选择实际开发板串口后，由操作者执行：

```sh
idf.py -p /dev/cu.usbmodemYOUR_DEVICE flash monitor
```

1. 设备没有绑定记录时，上电开放 60 秒配对窗口；窗口过期可按一下配置的按键重新开放。已有绑定时只允许原手机重连，不自动删除旧绑定或替换机主。NimBLE 库容量配置为 2 是规避 IDF 6.1 的单元素数组编译问题；应用仍在 GAP 接入处限制唯一已绑定机主。
2. iPhone 的 PDSH → 设置 → 蓝牙设备，扫描 `PDSH ESP32 Link`，手动连接并完成系统配对。
3. 页面显示 Link 版本、boot ID、NVS 设备 UUID、已发现工具后，为需要的工具分别授权。
4. home.http 还要在手机上填写与固件相同的 origin，如 `http://192.168.1.50:8123`。
5. 聊天中让 Agent 先调用 `ble_devices`、`ble_link_tools` 查看参数，再通过 `ble_link_call` 执行。旧固件只会显示未协商扩展，不会被发新命令。

例：

```json
{"device_id":"<手机列出的 CoreBluetooth UUID>","name":"light.set","args":{"on":true}}
```

```json
{"device_id":"<手机列出的 CoreBluetooth UUID>","name":"home.http","args":{"method":"GET","url":"http://192.168.1.50:8123/api/","timeout_ms":5000}}
```

这些是 `ble_link_call` 参数；工具日志负责提供幂等 key，不要用新 key 自动重试网络失败。恢复后使用错误 / 结果里的 request_id 调 `ble_link_result`。light.set 的读回是 GPIO 电平，并非灯具外部反馈；用 light.get 获取重启后的当前状态。

## 集成与资源边界

- `../components/pdsh_link_wire`：纯 C11，无 RTOS / ESP 依赖；既供 Swift Package 编译，也供 ESP-IDF 和 host 测试使用。
- `../components/pdsh_home`：参数校验和有界 HTTP；vendored 来源、许可证和文件摘要保留在 vendor/。
- `main/link_tools.c`：单任务工具执行、NVS 意图 / 结果日志、UUID / key 冲突保护；硬件可将 light.* 分支替换成自己的能力。
- `main/main.c`：NimBLE UUID / 安全 / 分段、HELLO、队列、事件与 Wi-Fi glue。

自定义工具应增加 tools/list 描述和严格的参数校验，并沿用“持久 intent → 一次执行 → 持久 result”的顺序。不能在 ACK 上传、COMMIT accepted 或收到 Notify 时伪称执行完成。接入原 xiaozhi-link 固件时，只移植按 capability 协商的 0x54–0x56 分派与此组件，不替换其录音 / HID / OTA 状态机或旧包格式；op / cap 为本项目扩展，需与未来上游分配协调。

参考回执表为 16 条有副作用命令，满后 STORE_FULL；没有自动驱逐或擦除。它是幂等安全参考，不是无限容量的生产日志。若需要清理 / 更换机主，应先核对未决动作、设计新的执行命名空间 / 所有权生命周期，再清理；擦除 Flash 会同时丢失绑定与幂等历史。启动遇到 NVS 错误会停止，不会自行 erase 修复。

设备向手机派任务时，设备本地应用可调用 `tools_task_submit` 并传入 [任务协议](../../spec/device/v1/task-delegation.md) 的 JSON goal。返回 true 表示设备已确认持久保存；false 包括存储结果不确定，不能据此假设没有保存。手机单独授权后通过 Link 查询和确认，设备可调用 `tools_task_result(id)` 获取阶段和最终结果，返回的 JSON 对象由调用方释放。参考队列保留最多 4 条历史任务，满后拒绝新任务；Link 的 16 条写回执限制仍独立生效。这是参考实现，不能当作无限队列。新增任务路径尚未在实体 ESP32 与 iPhone 之间验证。

LE Secure Connections + Just Works + 物理窗口提供本参考的绑定流程，不包含设备证书 / ATTEST、MITM 数字比较或加密 NVS；生产设备可另接入身份认证与 Flash / NVS 加密。本版手机每次连接仍独立授权，设备 UUID / 广播名不能当作密码学身份。

## 本地验证

先 `idf.py build` 解析固定 cJSON 依赖，然后回仓库根目录：

```sh
bash firmware/tests/run.sh
swift test --filter 'PDSHLinkTests|BLEDeviceMCPTests|StandardBLETests'
```

C 宿主测试使用真实工具和 HTTP 控制代码、模拟 NVS / GPIO / RTOS / HTTP 平台，带 ASan / UBSan；不声称验证了真实 BLE、真实 Wi-Fi、引脚接线或家居动作。固件 build 输出包含 bootloader、partition-table、pdsh_ble_reference.bin。已在 ESP32-S3 与iPhone 14 Pro 上完成真实 BLE / HTTP / 断连 / 重启自动测试；详见 [真机测试与复现步骤](../../docs/ble-hardware-testing.md)。GPIO 验证为 GPIO2 电平读回，不声称观察了实际灯具发光。
