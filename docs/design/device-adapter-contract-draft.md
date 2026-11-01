# 开放设备协议：手机侧适配器契约（草案 v0）

- 日期：2026-10-31
- 状态：**草案 / 预留**。线格式由李光浩负责，本文只定「手机侧要求」。
- 归属：协议本体（帧格式、发现、配对、加密）— 李光浩；手机侧契约与一致性测试 — phone-dsh。
- 关系：`device-connector-2026-10-31.md` §4.6 的实现细节。

## 1. 边界

| | 协议负责（李光浩） | 手机侧负责（phone-dsh） |
|---|---|---|
| 发现与配对 | 广播/扫描、配对码、密钥交换 | 展示配对 UI、保存授权、设备命名 |
| 传输 | 帧格式、MTU、重传、保序、加密 | 适配器、预算、限流、超时 |
| 身份 | `deviceId` 生成与稳定 | deviceId → session 绑定 |
| 能力 | 设备声明原始清单 | 映射为 `pdsh-device-caps/1`、渲染 UI、门禁 |
| 语义 | 命令/回执的线格式 | 命令目录、幂等、审计、模型可见工具 |
| 会话 | 不涉及 | session、来源标记、受众路由、Outbox |

**原则**：协议只负责「把字节可靠、可鉴权地送到」，不负责「这句话是什么意思」。

## 2. 协议必须提供的 10 项

| # | 要求 | 验收标准 |
|---|---|---|
| 1 | 稳定 `deviceId` | 重连、重启、重新配对后不变；长度 ≤128，可打印 ASCII |
| 2 | 配对与鉴权 | 未配对设备发来的数据一律拒绝；配对码一次性、有有效期；密钥可吊销 |
| 3 | 分帧与上限 | 声明 maxFrameBytes（≤64 KiB）；超限帧有明确错误，不是断连 |
| 4 | 保序 + 至少一次 | 同一连接内按发送顺序交付；重连后不丢未确认消息 |
| 5 | 消息 ID 可去重 | 每条消息带 `msgId`，设备侧与手机侧都能按它去重 |
| 6 | 能力清单 | 连接后 5s 内提供；未知能力忽略而不是报错；清单可版本化 |
| 7 | 命令与回执 | 命令带 `id`、`action`、`args`、`expiresAt`；回执带 `id`、`status`、`code`、`data` |
| 8 | 重连与续传 | 断线后 60s 内自动重连；有游标能续传未确认消息 |
| 9 | 版本协商 | 握手交换 `protocolVersion` 与 `capabilityVersion`；不兼容时明确拒绝并给出原因 |
| 10 | 诊断 | 设备侧保留最近 100 条错误/事件，可经授权拉取；日志脱敏 |

## 3. 消息映射

> 信封与传输无关：设备直连、服务端中继（gateway ↔ phone）、MCP 出站，用的都是同一个 `DeviceEnvelope`；区别只在传输适配器。
>
> 控制与媒体必须分开：命令走「请求-回执」（幂等 + TTL），音频/位图走「流 + credit」。不要用同一个 `send() -> ack` 同时承载两者。

协议帧 → `DeviceEnvelope`（手机侧结构，协议可自定义线格式）：

| DeviceEnvelope 字段 | 来源 | 必填 |
|---|---|---|
| `msgId` | 协议消息 ID | 是 |
| `deviceId` | 配对身份 | 是 |
| `sessionId` | 手机侧映射，不由设备提供 | 是 |
| `dir` | `up` / `down` | 是 |
| `kind` | `text` / `voice` / `event` / `ack` / `command_result` | 是 |
| `origin` | 设备上行恒为 `device` | 是 |
| `seq` | 协议序号（单调） | 是 |
| `ts` | 设备时间（无墙钟可空） | 否 |
| `text` / `audio` | 二选一 | 视 kind |

上行注入 DSH：`HarnessCommand.prompt(text:attachments:requestID:)`，`requestID = "dev:" + msgId`；重复投递不重复执行。

## 4. 命令与回执

沿用 `tono.device-command.v1` 的语义（幂等、TTL、回执、状态版本），线格式可由协议自定：

```json
{"id":"cmd-001","action":"light.effect.set","args":{"effect":"breathe"},"expiresAt":"2026-10-31T10:00:30Z"}
{"id":"cmd-001","status":"applied","code":"ok","data":{"stateRevision":3}}
{"id":"cmd-001","status":"failed","code":"expired","data":{}}
```

错误码最小集：`unsupported`、`invalid_args`、`expired`、`busy`、`unauthorized`、`internal`、`timeout`。未知错误码按 `internal` 处理，不得吞掉。

**规则**：
- `id` 由手机侧生成，设备按 `id` 去重；同 ID 异内容 → `invalid_args`，不执行。
- `expiresAt` 过期不执行，回 `expired`。
- 状态上报（音量/灯效当前值）不带 `id`，**不能**用来完成命令。
- 回执必须反映真实执行结果，不能「先回 applied 再执行」。

## 5. 能力清单
> 能力词表以 `spec/host/v1/schema/device-capabilities.schema.json` 为唯一权威；本节只是输入材料，未标 `provisional` 的词以该 schema 为准。

协议提供原始清单，手机侧映射为：

```json
{
  "schema": "pdsh-device-caps/1",
  "deviceId": "…",
  "protocol": {"id": "…", "version": "…"},
  "capabilities": {
    "audio.tts": {"codec": "opus", "rate": 24000},
    "audio.asr": {"rate": 48000},
    "audio.mic.stream": {"codec": "opus", "rate": 16000, "frameMs": 20},
    "speaker.volume": {"range": [0, 100]},
    "render.light": {"effects": ["breathe", "doa"]},
    "render.pixel": {"w": 64, "h": 64, "format": "rgb565", "fps": 20},
    "render.epaper": {"w": 250, "h": 122, "format": "mono1", "refresh": "partial"},
    "render.screen": {"w": 1280, "h": 720, "formats": ["png", "html"]},
    "control.gpio": {"pins": [4, 5]}
  },
  "limits": {"maxFrameBytes": 65536, "audioKbps": 32},
  "auth": {"pairing": "code|ble-passkey|cert", "replay": "counter+ttl"}
}
```

- 未声明能力默认不可用；`vehicle.*` 默认不出现，需 `granted_by: oem`。
- 厂商扩展放 `vendor.<name>.*`，手机侧不解析、只透传。

## 6. 配对与信任

- 配对码方向不限（设备出码或手机出码都可），但必须**一次性 + 有效期 + 绑定 deviceId**。
- 若要「控制台出码、手机输入」，参考 OAuth Device Grant（RFC 8628）：设备出码 → 用户在手机确认 → 设备换 token；这要求协议侧有 token 端点。
- 密钥存 Keychain/安全区；设备侧量产启用安全启动 + 加密存储。
- 重放防护：单调计数 + TTL；不接受纯时间戳。

## 7. 版本与兼容

- 握手交换 `protocolVersion`（主.次）与 `capabilityVersion`；主版本不同即拒绝并提示升级。
- 新增字段必须可选；删除字段走主版本。
- 手机侧保留至少一个旧主版本的适配器。

## 8. 一致性测试清单（协议实现方联调前先跑）

1. 未配对设备连接 → 拒绝，且不泄露设备信息。
2. 重复 `msgId` → 只执行一次。
3. 过期命令 → `expired`，不执行。
4. 同 `id` 异内容 → `invalid_args`，不执行。
5. 乱序/丢包 → 保序交付，缺帧可重传。
6. 断线 60s 重连 → 未确认消息续传，无重复执行。
7. 超长帧 → 明确错误，连接不断。
8. 未知能力/未知字段 → 忽略，不崩溃。
9. 主版本不兼容 → 拒绝并给出原因。
10. 设备重启 → `deviceId` 不变，session 可恢复。

## 9. 交付物（给协议实现方）

- 协议文档（帧、握手、配对、错误码、版本）。
- 参考实现（至少 ESP32 一份）。
- 测试向量（合法帧/非法帧各一组）。
- 模拟器（能在 Mac 上跑，方便手机侧联调，不用每次烧板子）。

## 10. 未决

1. 协议是否复用 DeviceWS v2 的 hello/audio 分段，还是完全新格式？
2. 音频走同一连接还是分离通道？（ESP32 上 BLE 与 Wi-Fi 共存只有 50% 时间片）
3. 配对码由哪一侧生成？是否要接控制台？
4. 是否内置加密（还是依赖 BLE 配对 + 应用层密钥）？
5. `deviceId` 的生成规则（MAC / 芯片 ID / 出厂烧录）？
