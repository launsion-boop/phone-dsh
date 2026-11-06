# ESP32-S3 真机 BLE 自动测试

已在连接本机的 ESP32-S3 v0.2（16 MiB Flash）与 iPhone 14 Pro 上跑通。测试由 iPhone 上的独立 XCTest hardware scheme 驱动真实 `PhoneDSHBLE` / `DeviceMCPServer`，不是模拟空口。ESP32 使用 Wi-Fi 请求 Mac 临时 HTTP fixture，不控制实际家居设备。

## 本次验证

- 扫描、加密绑定、Link 1.2 / Tools v1 协商、工具发现。
- GPIO2 写入和电平读回；同 request UUID 重复提交返回相同 revision，不重复执行。
- 固件拒绝错误参数；断连重连可查询原回执。
- BLE home.http 真正发出 POST；同 journal key 重试和设备重启后恢复均只查询，HTTP fixture 实测动作请求总计 1 次。
- 通过 USB watchdog 真实重启后，NVS 回执和 state_revision 保留，boot_id 改变，GPIO 初始化为关。
- 大响应跨 ctl 消息取回，正文在 1024 字节处截断。
- 302 不跟随：fixture 的 redirect-target 请求数为 0。
- HTTP 超时返回 outcome_unknown，同 key 不重放：慢请求总计 1 次。

首轮真机测试定位并修复了两项实现/测试问题：设备广播名优先于系统缓存旧名称；上游 transport 的小型连接状态原分配到 PSRAM，参考外设改用片内 RAM，保留上游源文件和全部 socket / 截止时间逻辑。新增 transport 宿主回归验证截止时间、DNS 生命周期、分配上限及片内分配。

另一个测试启动问题是 Xcode 会将环境变量中的 `http://` 规范化为 `http:/`，所以 hardware runner 仅传 `IP:port`，在 XCTest 进程内构造 URL；没有放宽私网或 origin 校验。

## 可重复运行

先按 [参考固件指南](../firmware/esp32-reference/README.md) 配置并烧录实际硬件。用于测试的 Home origin 必须是 Mac 可被 ESP32 和 iPhone 同时访问的私网 IPv4 + 18767 端口，配置普通 GPIO（本次是 2）。固件的 Wi-Fi 配置放在被忽略的本机 sdkconfig；不要提交凭据。

首次测试需要在 iPhone 上允许 Phone DSH 的蓝牙、配对和本地网络访问。runner 不能绕过系统授权。设备应保留给这台 iPhone，不先用 Mac BLE 客户端占用唯一绑定。

```sh
export PDSH_BLE_FIXTURE_IP=192.168.1.111
export PDSH_BLE_SERIAL_PORT=/dev/cu.usbmodem1101
export PDSH_BLE_DEVICE_MAC=aa:bb:cc:dd:ee:ff
export PDSH_BLE_IPHONE_UDID=your-iphone-udid
export PDSH_ESP_PYTHON=/path/to/esp-idf-python-env/bin/python
bash scripts/testing/run-ble-hardware.sh
```

此脚本不会擦除或烧录。它核对 USB 序列号、启动带随机 token 的临时 fixture、构建专用 `PhoneDSHBLEHardware` scheme、配置 xctestrun、复位设备、运行测试、导出证据，然后关闭 fixture。默认普通 / 模拟器测试 scheme 不包含这些硬件测试。

输出在 `.build/ble-hardware-*/`：Xcode 构建 / 测试日志、Hardware.xcresult、JSON 附件、fixture 请求计数和复位记录。专用测试会实际写 GPIO、执行 fixture HTTP 和重启 ESP32；每轮占用有限数量的持久回执，设备 STORE_FULL 时拒绝新写，runner 不会自动清理日志绕过幂等。

## 本次备份与证据

本次先读取并校验了完整 16 MiB 原 Flash，再初始化新参考固件分区；后续修复仅重刷 app，保留新固件绑定和回执。

本机产物位于 `.build/esp32-hardware/`：

- `original-flash-<device-mac>.bin`：完整原固件备份（包含原设备配置，文件权限 0600）。
- `backup-manifest.json`：备份大小和 SHA-256。
- `report.json`：通过的真机证据、固件 SHA-256、HTTP 计数。
- `Hardware-07.xcresult`：通过的完整 XCTest 结果。
- `attachments-07/`：导出的原始证据附件。

原始备份和本地 sdkconfig 可能包含 Wi-Fi / 绑定信息，均未打入可分享的参考源码包或提交 Git。恢复原固件时应先进入下载模式、核对芯片 MAC，再把完整备份写回 0x0；恢复会替换当前参考固件及其 NVS 状态，不能作为普通重试或自动故障恢复动作。
