# LAN MCP 参考设备

这是可运行的 Python 参考设备：它通过 TLS 和设备 bearer 凭证提供 MCP 工具，并可通过 Bonjour 发布 `_pdsh-mcp._tcp`。`light.get` / `light.set` / `light.result` 操作 SQLite 中的**模拟**灯，不连接真实 GPIO。协议和兼容性以 `spec/device/v1/lan-mcp.md` 为准。

准备证书和凭证：

1. 取得可被手机系统信任、且 DNS 名称与设备发布的主机名相符的服务器证书和私钥。自建 CA 须通过设备管理流程安装并在手机上信任；服务不会关闭证书检查。
2. 用 `umask 077` 和 `openssl rand -hex 32 > device-token` 生成独立设备凭证，确保文件权限为 0600。通过已认证的线下渠道把凭证提供给用户，不要提交文件或在广播中发送。
3. 在设备运行（替换占位路径和实际主机名）：

```sh
python3 examples/lan-mcp-device/server.py \
  --cert device-cert.pem --key device-key.pem --token-file device-token \
  --hostname device.example --port 8443 --state device-state.sqlite \
  --publish-name "Reference device"
```

`--publish-name` 使用 macOS 的 `dns-sd`；其 SRV 目标是本机 Bonjour 主机名，必须与 `--hostname`、证书名称一致。其他平台应使用系统 DNS-SD 实现发布相同 service、端口和 TXT `profile=pdsh-mcp-1`。服务器只在 `/mcp` 提供服务。手机在 MCP 设置中扫描并选择设备，核对 HTTPS 地址，在 Authorization 字段输入 `Bearer ` 加设备凭证并保存。用户需授权本地网络访问；发现不到时可按现有 MCP 设置手动添加 URL。

`light.set` 要求调用方提供 `operation_id`：相同 ID 与参数返回原结果，不同参数发生冲突。模拟状态和结果在同一 SQLite 事务持久化，最多保留 4096 条后拒绝新操作；`light.result` 查询原 ID，未找到返回 `outcome_unknown`。设备接真实执行器时需要自行实现断电、持久化与回执的边界，不能把本示例的 SQLite 事务当作物理动作的原子保证。

验证：`python3 examples/lan-mcp-device/test_discovery.py` 和 `python3 examples/lan-mcp-device/test_server.py`。后者生成临时证书与私有凭证，测试认证失败、TLS 证书验证、断线查询、持久去重，以及真实 MCP SDK 和 phoneDSH MCP 管理器的工具注册与调用。该测试需要项目 `plugins` 的既有依赖和 Node；它不声称完成 iPhone 或 ESP32 真机验证。
