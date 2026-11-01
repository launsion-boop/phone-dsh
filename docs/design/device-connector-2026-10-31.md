# 设备连接器架构（ESP32 / 树莓派 / 车机）

- 日期：2026-10-31
- 状态：调研结论 + 架构提案，未实现
- 范围：手机端 DeepSeek Harness（phone-dsh）如何作为「大脑」，连接纯终端设备；不含托管云服务
- 相关资产：遗留 link 工程（BLE link v1.2 + XiaozhiLinkKit）、自有设备固件（DeviceWS v2）、实时客户端（chat-server / 命令 broker）

## 0. 结论摘要

1. **不要新造一套设备协议。** 团队已有两条可复用主线：DeviceWS v2（Wi-Fi，Opus 音频 + `tono.device-command.v1` 命令/回执）和遗留 link 工程的 BLE link v1.2（配件形态，手机做大脑）。连接器应做在这两条之上，统一消息信封，而不是再造第三条。
2. **主路径定为「服务端中继」**（已确认）：设备连自有服务器（设备鉴权 + 用量计量），语音在服务端做 ASR/TTS，Agent 请求经中继交给 phone DSH。接受 DSH 作为云 LLM 的工具，同时保留「DSH 当主脑」的路由开关。**手机不在音频链路上**，绕开 iOS 后台限制。
   - **A｜局域网直连**：降级为开发/离线兜底；手机当服务端，不承担量产链路。
   - **C｜link 形态**：新配件路线，复用遗留 link 工程。
   - **D｜开放协议**：李光浩负责，手机侧预留适配器（§4.6）。
3. **语音出局域网、连自有服务器**（已确认）：设备只负责采集/播放，ASR/TTS 与计量都在服务端；设备鉴权、配额与计费在网关做。
4. **渲染目标四类都做**（已确认）：灯效、像素屏、墨水屏、普通屏，统一成 RenderIR 后按设备能力选择（§4.8）。
5. **「控制台生成配对码 → phone DSH 输入 → 小智中继」这个具体流程在官方云上不存在。** 6 位激活码是「设备 → 账号」绑定，没有反向接口；现实等价物是「控制台生成 MCP 接入点 URL（自带 token）→ 手机粘进 DSH」，或服务端直接按账号绑定设备。
6. **通话是连接器的一等能力，不是「截取电话」。** 设备成为通话的一端（HFP 中继 / BLE `call_up` / USB UAC2），App 拥有控制权，云端 voice 模型作为第三个参与者混入音频；接听策略与通话总结由 DSH 直接改（`call.policy.set` / `call.summary.get`）。四条路径团队都有可运行代码。
7. **产品上先做「内容下发 + 语音随身」，不要做电视去广告和车机。**
8. **云侧不在本方案内**：Device Gateway、Inference Gateway、Credits 由平台文档负责（`TonoWiki/briefs/2026-10-29-pdsh-open-platform-architecture.md` §6）。本方案只留三个接缝 —— `InferenceProvider`、`UsageSink`、`DeviceGatewayAdapter`，手机侧不实现、不设计。
9. **开放设备协议本身不在本方案内**：由李光浩负责，本文只在第 4.6 节预留适配器契约（任何协议满足它就能接入），并用一致性测试清单约束，不预设它的线格式。

## 1. 需求模型

设备是同一个 DSH 会话的另一个参与者 + 执行端，不是被投屏的手机：

```
设备（麦/喇叭/灯/屏/执行器）
   │ WSS（DeviceWS）
   ▼
自有服务器（鉴权 · 计量 · ASR/TTS · RenderIR · 命令 broker）
   │ 出站 WSS MCP（tool / brain 两种路由）
   ▼
手机 DSH 会话（deviceID → 固定 sessionID）
   ├ 上行注入：session/prompt（幂等 requestID）
   └ 下行投递：session/follow + 投递策略
```

- 一个设备一个固定 session；手机端在这个 session 发的消息 = 对设备的控制/交代。
- 设备上行消息带来源标识，模型与 UI 都能区分「人说的」和「设备说的」。
- **一个 session 有两个受众**（手机前的用户、远端设备），必须显式路由，否则模型会把给用户的解释念给设备听。
- 语音不经过手机：设备 ↔ 服务器完成 ASR/TTS，手机只处理文本与工具（tool 模式下 DSH 是云 LLM 的工具）。

## 2. 关键事实（带证据）

### 2.1 DeviceWS v2（自有 ESP32 设备，Wi-Fi）

| 事实 | 证据 |
|---|---|
| 单条 WS：Text=JSON，Binary=音频；上行 8 字节头 + 48k/20ms Opus；下行 24k/20ms 裸 Opus，`audio_start`/`audio_finish` 分段 | 实时客户端 `connections/chat-server/devicews/PROTOCOL.md:31-62` |
| 握手 `Authorization: Bearer <设备JWT>`，hello 自报 device_id 不作准，服务端内省后替换；10s 内必须首帧 | 同上 `:166-257` |
| 下行命令 `tono.device-command.v1`：action 闭集 7 个（音量/灯效/call.dial/通话策略/firmware.update 等），整帧 ≤2048B | `wire/devicecommand/model.go:13-32` |
| 回执 `applied` 必带正 `state_revision` + 实际值；失败带封闭 failure_reason | `model.go:641-783` |
| TTL 由 `expires_at` 控制；`command_id == idempotency_key`，同 ID 异内容 → `idempotency_conflict`；固件只缓存 4 条 | `devicews/command.go:224-311`、`FW/device_ws.c:825-839` |
| 状态上报（`volume`/`light`）不带 command_id，不能用来完成命令 | `PROTOCOL.md:360-643` |
| **投递 HTTP 入口未注册**，只有 `/v1/device-commands/stats`；本版云端无法真正下发命令 | `cmd/device-ws/main.go:922` |
| 固件只校验 `type` + `version` 即进 READY；未知 type 直接断连 | `FW/device_ws.c:1854-1885` |

**含义**：命令/回执契约已经足够好（幂等、TTL、状态投影），可以直接搬到手机端；缺的是「谁来当服务端」。

### 2.2 小智（存量设备）

| 事实 | 证据 |
|---|---|
| 设备只认 OTA 下发的地址：启动先 POST `CONFIG_OTA_URL`，响应里的 `websocket{url,token}` / `mqtt{}` 决定真正连哪 | `78/xiaozhi-esp32/main/ota.cc` |
| `Ota::GetCheckVersionUrl()` 允许 NVS `wifi/ota_url` 覆盖，但官方 UI 无入口（自有 fork 有 `ota url` 控制台命令） | `xiaozhi-link/firmware/components/xl_xiaozhi/xl_xz_ota.c` |
| 帧：`hello` / `listen` / `abort` / `stt` / `llm` / `tts` / `mcp` / `system` + 二进制 Opus（v1 裸帧，v2/v3 带头） | `docs/websocket.md` |
| 6 位激活码是「设备显示 → 控制台输入」绑定账号，服务端轮询 `POST {ota}/activate` 换 token | 同上 |
| 官方控制台支持 MCP 接入点：给一条 WS 地址，本地 MCP client 出站连它，云 LLM 可调你的工具 | 公开教程（第三方），需以控制台实际能力为准 |
| 自建 `xiaozhi-esp32-server`：LLM 可指 OpenAI/Dify/Coze/FastGPT，ASR/TTS 可换，自带 `/mcp_endpoint/mcp/?token=` 出站接入点 | `xinnan-tech/xiaozhi-esp32-server` |

### 2.3 遗留 link 工程（自有 link 形态）

- BLE link v1.2：录音上行、HID 下行、唤醒、状态/通话/通知事件；USB HID/UAC2 复合设备。
- `XiaozhiLinkKit` 已有：录音补传、单一转写路径、`AgentSubsystem`（本地 DSH）、`VoiceSubsystem`（唤醒→ASR→回答→TTS）、MCP server 模块、`PhoneRelayClient`（出站 WSS MCP）。
- 文档明确：**跨设备 link 互操作（小智设备接入本 link / 本 link 控制小智设备）尚未实现**。

### 2.4 平台硬约束

| 约束 | 结论 |
|---|---|
| iOS 后台 | 只有 `audio` 后台模式 + 活跃 `AVAudioSession` 能续跑；纯 BLE/WSS 中继会被挂起 |
| iOS AEC | 系统语音处理只作用于手机自身麦克风/扬声器，**设备外放的回声必须在设备端消** |
| 蜂窝通话 | App 拿不到蜂窝音轨，但**设备可以作为 HFP 耳机拿到**，再经 BLE 中继给 App（CallMate 已量产）；CallKit 只做 VoIP |
| BLE / Wi-Fi 共存 | ESP-IDF 官方：两者同时连接时按时间片约 50/50 抢同一射频 |
| mDNS | 跨 VLAN / AP 隔离经常失效；只能当发现辅助，不能当信任 |
| 车机 | AAOS 第三方只能做导航/POI/IoT/天气模板，拿不到车控写权限；车厂 Linux 需商务合作 |

## 3. 接入路径对比（含预留的开放协议）

| | **A｜本地直连（自有设备，设备可达手机时）** | B｜云中继（存量小智） | C｜link 配件 | D｜开放协议（预留） |
|---|---|---|---|---|
| 设备改动 | 连手机（BLE/Wi-Fi），现有 DeviceWS/link 能用 | **零改动** | 刷 link 固件 | 按协议实现（李光浩） |
| 手机改动 | Device SPI + 各协议适配器 | 出站 WSS MCP + `dsh.ask` | 复用 XiaozhiLinkKit | 一个 TransportAdapter |
| ASR/TTS | 注入 `InferenceProvider`（云侧由平台提供） | 小智云（原流程） | 手机侧或 Provider | 协议不规定 |
| 音频路径 | 设备 ↔ 手机 | 设备 ↔ 云 | 设备 ↔ 手机（BLE） | 取决于协议 |
| 计量 | Credits + 设备轴两本账 | 云端自算 | 手机侧 | 协议方提供 |
| 谁当大脑 | 手机 DSH（tool/brain 可切） | 云 LLM | 手机 DSH | 手机 DSH |
| 主要失败点 | 手机后台/适配器工作量 | 云 LLM 二次改写、工具超时 | 存量设备刷机即离云 | 协议未定 |
| 适合 | 自有设备、局域网/近场 | 存量设备快速接入 | 新配件 | 第三方生态 |

**结论**：这是两种部署形态，不分主次——设备能连到手机就走 A（音频不经云、延迟最低），连不到就走 B（零固件改动）。**手机不进任何音频链路的假设不成立**：A 形态下设备音频就是送到手机；iOS 后台只影响「手机持续联网转发」，不影响「设备→手机」。C 供新配件；D 由李光浩推进，手机侧只保留适配器契约。

## 4. 统一架构

```
┌──────────────── 手机 DSH（Agent 平面） ────────────────┐
│ Session（deviceID → sessionID）                         │
│  ├ DeviceEnvelope（来源/受众/序号）                      │
│  ├ DeliveryPolicy（回复给谁、是否 TTS）                  │
│  ├ DeviceOutbox（离线队列、at-least-once）               │
│  ├ CapabilityGrant（逐设备逐能力授权）                   │
│  └ DeviceCapabilityManifest（设备声明）                  │
└──────────┬───────────────────────────┬─────────────────┘
           │ 出站 WSS MCP（主）          │ 适配器（兜底/新协议）
           ▼                            ▼
┌──── 自有服务器（设备平面） ────┐    局域网直连 / BLE link
│ Device Gateway（鉴权/配额/计量）│
│ Voice Service（ASR/TTS）        │
│ Agent Router（tool / brain）    │
│ Render Service（RenderIR）      │
│ Command Broker（命令/回执）     │
└──────────────┬──────────────────┘
               │ WSS（DeviceWS）
          ESP32 / Pi / 车机
```

### 4.1 消息信封

```json
{
  "v": 1,
  "msgId": "dev-01-000123",
  "deviceId": "esp32-8c4f...",
  "sessionId": "sess-...",
  "dir": "up",
  "kind": "voice|text|event|ack|command_result",
  "origin": "device|phone|agent",
  "audience": "phone|device|both",
  "seq": 123,
  "ts": "2026-10-31T10:00:00Z",
  "text": "…",
  "audio": {"codec": "opus", "rate": 48000, "ms": 20}
}
```

- 上行注入 DSH 用 `HarnessCommand.prompt(text:attachments:requestID:)`，`requestID = "dev:" + msgId`，天然幂等；重投不重复执行。
- **来源不进正文**：`HarnessCommand.prompt` 增加 `origin`（`user` / `device(id, seq)`）；远端 DSH 不支持时降级为「attachment + ledger」（按 `requestID="dev:"+msgId` 反查），文本保持原样。正文前缀既可伪造，也会污染检索与复制。

### 4.2 路由与策略

- **工具优先，策略兜底**：`device.say(text, audience)`、`device.control(action, args)` 走 `PhoneToolBridge`，并由 `CapabilityGatedToolBridge` 声明受门禁。
- **audience 只由工具显式给出**，不从「这轮谁发起」推断（多轮对话没有发起方语义）。未显式指定时路由到**最近一次人类输入的通道**。
- 会话级策略只保留：`tts`、`maxChars`（≤1000）、`allowStructuredControl`、`interruptPolicy`。
- `assistantMessage` 按上述规则投递；`toolResult` 永不投设备；`permission/question` 只到手机。
- 结构化控制**不要**混进自然语言；语音只是消息载体。

### 4.3 幂等与可靠性

- 上行：`msgId` 主键 Outbox（pending → sent → acked），重连补发；实现直接套 `PhoneDSHGateway/ResponseLog` 的幂等日记，不另造。
- 下行命令：`command_id` 幂等 + `expires_at` TTL + 回执 `applied/failed` + `state_revision`；沿用 DeviceWS 契约。
- 状态上报不能完成命令（现有契约已明确）。
- 设备侧按 `msgId` 去重，服务端按 `requestID` 去重。

### 4.4 安全

- 设备上行是**不可信输入**：默认只当数据；设备发起的一轮默认工具集为空；写操作必须过 `PhoneCapabilityGate`（含生物识别）。
- 授权链：`DeviceGrantStore`（用户逐设备逐能力开）∩ `manifest` ∩ `origin=device` → gate。
- **身份与配对接 `tono-account`，不要自建**：设备侧 `attest`（ESP32-S3 用 eFuse base MAC + HMAC-SHA256 一机一密；SF32 用 AES-256-ECB UID），换 30 天设备 token；配对用**设备出 6 位码、用户在 App 输入**（`POST /v1/device/pairing-codes` → `POST /v1/me/devices`），归属有 generation，解绑/挂失/改名都有现成接口。
- 传输：WSS + 证书 pin；命令带单调计数 + `expires_at` 防重放；mDNS 只做发现，发现后必须再鉴权。
- 审计：记录 deviceId、命令、结果；设备拿不到 `$events`/`permission` 流。

### 4.5 能力清单（manifest）
> 能力词表以 `spec/host/v1/schema/device-capabilities.schema.json` 为唯一权威；本节只是输入材料，未标 `provisional` 的词以该 schema 为准。

```json
{
  "schema": "pdsh-device-caps/1",
  "deviceId": "…",
  "transport": "wss|ble|mcp",
  "capabilities": {
    "audio.tts": {"codec": "opus", "rate": 24000},
    "audio.asr": {"rate": 48000},
    "audio.mic.stream": {"codec": "opus", "rate": 16000, "frameMs": 20, "maxMinutes": 120},
    "display.text": {"maxChars": 512},
    "light.effect": {"effects": ["breathe", "doa", "…"]},
    "speaker.volume": {"range": [0, 100]},
    "control.gpio": {"pins": [4, 5]},
    "call.ble": {"uplink": "call_up", "codec": "opus"},
    "call.hfp": {"profile": "HF", "codec": "cvsd|msbc"},
    "call.uac": {"telephony": "hid", "codec": "usb"},
    "vehicle.*": {"granted_by": "oem"}
  },
  "limits": {"textBytes": 2048, "audioKbps": 32},
  "auth": {"pairing": "ble-passkey", "replay": "counter+ttl"}
}
```

UI 由 manifest 渲染；未声明能力默认不可用；`vehicle.*` 默认不出现。

### 4.6 开放设备协议：预留的适配器契约

开放协议由李光浩负责，本文**不定义它的线格式**。手机侧只规定「一个设备协议要接进 DSH 必须满足什么」，用一个适配器接口把它隔开：

```swift
public protocol DeviceTransportAdapter: Sendable {
    /// 协议标识与版本，用于 manifest 与诊断。
    var descriptor: DeviceProtocolDescriptor { get }

    /// 发现与配对。返回的设备必须带稳定的 deviceId。
    func discover() async throws -> [DeviceCandidate]
    func pair(_ candidate: DeviceCandidate, code: String?) async throws -> PairedDevice

    /// 连接与鉴权。连接成功后协议层的重连由适配器自己负责。
    func connect(_ device: PairedDevice) async throws -> any DeviceTransportSession

    /// 设备声明的能力（原始 JSON，映射由手机侧完成）。
    func capabilities(for session: any DeviceTransportSession) async throws -> JSONValue
}

public protocol DeviceTransportSession: Sendable {
    var deviceID: String { get }
    /// 控制面：命令 → 回执（幂等、TTL、状态版本）。一帧一等，语义同步。
    func control() -> any DeviceControlPort
    /// 媒体面：双向流 + credit 节流。发送返回即入队，不等逐帧回执。
    func media(_ kind: MediaKind) -> any DeviceMediaPort
    func close() async
}

public protocol DeviceControlPort: Sendable {
    func request(_ command: DeviceCommand) async throws -> DeviceAck
    func events() -> AsyncThrowingStream<DeviceEvent, Error>
}

public protocol DeviceMediaPort: Sendable {
    func inbound() -> AsyncThrowingStream<MediaFrame, Error>   // 上行音频/位图
    func outbound() -> AsyncThrowingStream<MediaFrame, Error>  // 下发 TTS/帧
    func send(_ frame: MediaFrame) async throws                // 入队即返回，背压用 credit
    func credit() -> Int
}
```

**这是本方案最容易做错的一处**：控制是「请求-回执」，媒体是「流 + credit」。把两者压进同一个 `send() -> ack`，接通话（20ms 帧）时必然整体推翻。

适配器只承担 6 项，其余上收手机侧：

| # | 要求 | 说明 |
|---|---|---|
| 1 | 稳定 `deviceId` | 重连/重启不变，≤128 可打印 ASCII |
| 2 | 配对与鉴权 | 未配对一律拒绝；密钥可吊销 |
| 3 | 帧上限声明 | maxFrameBytes ≤64 KiB；超限有明确错误 |
| 4 | 消息 ID | 每条带 `msgId`，设备侧按它去重 |
| 5 | 版本协商 | `protocolVersion` / `capabilityVersion`，主版本不兼容即拒绝 |
| 6 | 脱敏诊断 | 最近 100 条错误可经授权拉取 |

保序、至少一次、续传游标**不要求设备实现**：由手机侧 `DeviceOutbox` 负责重发与补齐，设备只需「按 `msgId` 去重 + 环形缓冲 N=4」（与 DeviceWS 固件现有 4 条缓存一致）。把重传窗口压给 ESP32 是行不通的。

手机侧统一提供、协议不需要重复实现：消息信封与来源标记、Outbox 与幂等、会话路由与投递策略、能力授权与门禁、审计。

**与现有两条路径的关系**：DeviceWS 与 link 各写一个适配器即可复用同一套上层；新开放协议是第三个适配器。三者共用 `DeviceEnvelope`、`DeviceDeliveryPolicy`、`DeviceGrantStore`、`DeviceOutbox`，不共享线格式。

**验收方式**：`DeviceTransportAdapterConformance` 测试套件（协议无关）——适配器只要通过它，就能接进 DSH；协议实现方（李光浩）在联调前先跑这 10 项。

> 契约草案见 [device-adapter-contract-draft.md](device-adapter-contract-draft.md)，协议冻结后再决定是否提升为 `spec/v1/`。

### 4.7 云侧预留（本方案不实现）

云侧的 Device Gateway、Inference Gateway、Credits 账本由平台文档负责（`TonoWiki/briefs/2026-10-29-pdsh-open-platform-architecture.md` §6），本方案**只留三个接缝**，不设计、不实现：

```swift
/// 推理接缝：Tono 托管 / BYOK / 自建端点都实现它，手机侧不关心是哪个。
public protocol InferenceProvider: Sendable {
    func streamText(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceDelta, Error>
    func streamASR(_ audio: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASRPartial, Error>
    func streamTTS(_ text: String) -> AsyncThrowingStream<AudioFrame, Error>
}

/// 用量接缝：一次操作一条记录，具体记账在平台侧，手机只上报与展示回执。
public protocol UsageSink: Sendable {
    func record(_ usage: UsageRecord) async
    func quote(operation: OperationKind) async -> UsageQuote?
}

/// 设备网关接缝：仅给「设备不能直连手机」的场景（存量小智、远程设备）。
public protocol DeviceGatewayAdapter: Sendable {
    func register(deviceID: String, sessionID: String) async throws
    func relay(_ envelope: DeviceEnvelope) async throws
}
```

- 手机侧只依赖这三个协议；换成托管、BYOK 或自建，都不改连接器。
- 设备鉴权与配对仍走 `tono-account`（attest + 6 位配对码 + 设备 token），这部分是既有服务，不是新设计。
- 计量：连接器只产 `UsageRecord`，不维护余额、不扣费、不做费率表。

### 4.8 渲染目标（灯效 / 像素屏 / 墨水屏 / 普通屏）

统一成**意图**而不是位图：`RenderIntent` 描述「要表达什么」，每个目标做一次有损投影。

```json
{"intentId":"ri-01","target":"pixel","semantic":{"title":"今日待办","body":"3 项","accent":"#0E9F6E","urgency":2},
 "bitmap":{"hash":"sha256:…","w":64,"h":64,"format":"rgb565","chunks":4,"url":"/v1/render/ri-01.bin"}}
```

| 目标 | 投影 | 下发方式 | 刷新 |
|---|---|---|---|
| `screen` | 原文 + 样式 | 命令带 `htmlUrl`/`pngUrl` | 按交互 |
| `pixel` | 调色板量化 → RGB565 | **命令只带 hash/url**，数据走 HTTP 回拉或二进制通道 `render_chunk` | 10–30 fps |
| `epaper` | 1-bit 文本布局 | 同 pixel，单帧、按需 | 秒级 |
| `light` | `accent` + `urgency` → 效果/节奏 | 直接 `light.effect.set` | 实时 |

**不要走命令帧传位图**：`tono.device-command.v1` 整帧 ≤2048 B，装不下 64×64 RGB565 的 8 KiB。命令只携带 `hash + 尺寸 + url`，设备按 hash 回拉、续传、命中不重传；回执只校验 hash。

- `semantic` 必填，是最终兜底：连位图都发不出去时退到 `display.text`（纯文本 + 强调色）。
- 降级链固定：`screen → pixel → epaper → light → display.text`，逐级有损，不跨级乱跳；位图只产最高分辨率一份，向下转码。

### 4.9 设备麦克风：持续录音是独立能力

设备麦不只是通话的一部分，PDSH 要能把它当成**持续输入源**直接调用：

```swift
public protocol DeviceMicrophone: Sendable {
    func start(_ options: MicOptions) async throws -> AsyncThrowingStream<AudioChunk, Error>
    func stop() async
    func pause() async
    func resume() async
}

public struct MicOptions: Sendable {
    public var codec: AudioCodec        // opus 16k/20ms 起
    public var gain: Float              // 线性 0...1
    public var vad: VADMode             // device | phone | off
    public var maxDuration: TimeInterval
    public var storeLocally: Bool       // 默认 true，落手机
}
```

**工程要点**：

- **复用现有采集链路**：遗留 link 工程的录音环 + 补传（`xl_rec` / RecordingSubsystem）、link 的 `audio_up` 特征、DeviceWS 的 8 字节头 + Opus 上行；不新建音频协议。
- **背压用 credit，不用 ack**：20 ms 帧逐帧等回执必然卡死；设备端按窗口发，手机按 `credit()` 归还。
- **时钟与序号**：每帧带设备单调 `seq` 与 8 kHz 墙钟锚点；断线重连按 `seq` 补洞，缺帧标记为空洞而不是静默拼接。
- **本地优先落盘**：先写手机端录音文件（WAL + 分段），再送 ASR；`storeLocally` 默认 true，云端只拿转写或按需片段。
- **后台**：iOS 需要 `audio` 后台模式 + 活跃 `AVAudioSession`（哪怕设备音频走 BLE，也要占住采集会话）；锁屏/来电中断时进入 `paused` 并上报，不假装还在录。
- **隐私**：开始/停止都有明确提示与审计（谁、哪个设备、多久）；暂停后设备端必须真的停采，不能只停发送。
- **与通话的关系**：通话是双工混音会话（§7），持续录音是单向上行；两者共用 `DeviceMediaPort`，但会话生命周期、优先级、打断策略不同——通话时默认暂停持续录音。

## 5. 设备形态## 5. 设备形态

| 形态 | 结论 | 理由 |
|---|---|---|
| ESP32-S3（自有 microBoard） | **v0 主力** | 已有 DeviceWS/音频/灯效/OTA；Wi-Fi 主链路 |
| ESP32-C6 | 纯控制设备可选 | 便宜、Wi-Fi 6 + BLE 5，无音频压力 |
| 树莓派 | **v0 不做，只预留适配器**（M5 再实现 WSS + 配对 + manifest + GPIO） | 完整 Linux、相机/文件/GPIO，但成本与功耗高一个量级；先用 ESP32 把链路跑顺 |
| AAOS 车机 | **v0 不做** | 第三方无车控写权限，只能做模板应用；可规模化只有投影 |
| 车厂 Linux | **不做** | 需商务合作、单车厂定制、OTA 备案 |

## 6. 语音管线（音频在本地链路，推理走 Inference Gateway）

```
设备麦 → 设备 AEC/NS/VAD → Opus → 手机（BLE/Wi-Fi）
  → 抖动缓冲 → 手机 Streaming ASR（Tono Inference Gateway / BYOK）
  → 文本 → DSH 会话
  → 回复 → 手机 Streaming TTS（同一网关）→ Opus → 设备播放
```

- **设备 ↔ 手机是音频链路，手机 ↔ 推理服务是另一段**：ASR/TTS 通过注入的 `InferenceProvider`（托管/BYOK/自建均可），本方案不实现该服务。
- 延迟预算（估算）：设备→手机 15–40ms、手机封装+上行 50–100ms、ASR 首 partial 120–300ms、推理 400–900ms、TTS 首包 150–350ms、回推+预缓冲 60–120ms → **首音约 1.1–1.8s**。
- **AEC 必须在设备端**（手机的系统 AEC 不作用于设备外放）；半双工（播报停麦）作兜底；打断先停播再上报 cancel。
- **计量只上报**：连接器中只产生 `UsageRecord`（ASR 秒 / TTS 字符 / token / 命令数），余额与费率由平台侧负责。
- 不建议：BLE 传连续音频；把 48k 高保真塞进 BLE；让手机做「音频中继」转发设备音频到云（多一跳且破坏 AEC 参考）。

## 7. 通话能力（不是「截取电话」，是让设备成为通话的一端、让 Agent 加入混音）

前面版本把这件事写成「手机侧不可行」，是在用「App 截取蜂窝音轨」的错误模型看问题。团队已有的实现是另一条路：**设备成为手机的通话音频端点，App 拥有通话控制权，云端 voice 模型作为第三个参与者混进音频**。

### 7.1 三种承载（按设备能力选）

| 承载 | 适用设备 | 音频路径 | 控制 | 现状 |
|---|---|---|---|---|
| **HFP 中继（CallMate 形态）** | 带经典蓝牙的 MCU（SF32） | 手机 ⇄ 设备（SCO）→ 设备 ⇄ App（BLE Opus）→ 云端 | HFP AT + ANCS 来电人 | **已量产**（EchoCard/CallMate） |
| **BLE call 通道** | S3/C6（BLE only） | 设备 ⇄ App（`call_up` 0x0106 + `CALL_AUDIO`） | `CALL_ACTION` | link v1.1 已实现 |
| **USB UAC2** | 带 USB 的配件 | 设备 ⇄ 手机（USB 音频） | HID Telephony + ANCS | link 固件已实现 |

关键点：**蜂窝通话不是「App 去截取」，而是设备先当 HFP 耳机把通话接过来，再把音频经 BLE 中继给 App**。CallMate 已经这么跑：`手机 ⇄ HFP(SCO) ⇄ MCU ⇄ BLE(Opus 16k/60ms/16kbps) ⇄ App ⇄ 云端 STT/LLM/TTS`，来电人从 ANCS 取，接听/挂断走 HFP AT。这条对 S3/C6 不成立（无经典蓝牙），所以 S3 走 BLE call_up（限 App 内通话）或 UAC2。


承载差异收进能力位：HFP = AT + ANCS、Opus 16k/60ms/16kbps、**没有 `setMix`**；`call_up` = 16k/20ms/16kbps、能力最全；UAC2 = HID + 重采样。上层按能力位降级，不要按承载类型写 `if`。
### 7.2 已有实现（直接复用，不重写）

- `XiaozhiLinkCall`：
  - `CallController`：`answer` / `decline` / `hangUp` / `prepareRoute`，状态以 `EVT_CALL_STATE` 推送。
  - `CallAudioUplink`：设备 → App 的通话音频（`call_up`），带 `callId`、Opus、混音参数。
  - `CallBridgeCoordinator`：把外部 call agent 接进来——`decide` 返回 `.ignore` / `.monitor` / `.handle`，`.handle` 依次尝试接听方法、等路由、`active_confirmed` 后开混音（`agentGain` / `micGain`）；用户先接、路由被拿走或交接时 Agent 自动闭嘴，**从不代替用户挂断**。
- `xl_call`：纯 C 状态机（idle → ringing → route_preparing → answer_submitted → active_confirmed → ended），每步超时回退；ANCS 取来电人，HID Telephony 按键接听，UAC 路由重枚举；三种接听策略。
- `sf32-callgate`：HFP HF 桥，SCO 经 UART 到 ESP32。

### 7.3 在连接器里的位置

通话是与「语音」「渲染」并列的一等能力，不是异常分支：

```swift
/// 三条承载各一个实现；上层只认这个协议。
public protocol CallBearer: Sendable {
    var kind: CallBearerKind { get }          // .hfp / .bleCall / .uac2
    func control() -> any CallControlPort     // answer / decline / hangUp / dial
    func media() -> any CallMediaPort         // 双向流 + setMix
}

public protocol CallService: Sendable {
    func snapshot() async -> CallSnapshot
    func answer(_ callID: String, method: CallControlMethod) async throws
    func decline(_ callID: String) async throws
    func hangUp(_ callID: String) async throws
    func dial(_ request: CallDialRequest) async throws
    func attachAgent(_ callID: String, mix: CallMixSetting) async throws
    func detachAgent(_ callID: String) async throws
}
```

- `attachAgent` 就是 `CallAudioBridge`（`CallBridgeCoordinator.swift:159`）的 façade，不要另写桥接。
- 手机侧 `CallMediaBridge` 内嵌 `CallBridgeCoordinator`（`CallBridgeOptions` 已把 decide 3s / route 8s / answerProgress 6s / takeoverGrace 8s / linkLoss 5s 参数化），不要重写超时逻辑。
- **混音留在设备端**：手机只发 `setMix(agentGain, micGain)` 与音频流；设备拿自己的扬声器参考做 AEC。手机若做三路混音，设备 AEC 会失去 agent 参考信号，回声会直接进对端。
- 增益线性 `0...1`（`-6 dB = 0.5`）；`mix` 不跨会话保留，每次 `start` 重发。
- 打断：near-end 能量 VAD（开口 ≥80ms）→ `agentGain` 降到 0.25、hangover 400ms 回升；先停 inject（credit 停发即止）再切 `.micOnly`。
- 设备能力清单增加 `call.ble` / `call.hfp` / `call.uac`，适配器按声明选承载。

### 7.4 接听策略与通话总结（DSH 的一等工具）

- **CallPolicy**（按账号 + 设备，版本化）：陌生号码、骚扰标记、时间段、联系人组、是否 AI 代接、代接话术、转人工条件、是否录音/转写。
- **工具面**：`call.policy.get` / `call.policy.set` / `call.summary.get` / `call.summary.list` / `call.transcript.get`，走 `PhoneToolBridge` + 能力门禁。
- **通话结束流程**：转写（复用 `ASRTranscriptionCoordinator`，不二次 ASR）→ DSH 生成结构化总结（对方、事由、结论、待办、风险等级）→ 写 DomainStore + 通知；可选回设备播报。
- **与 CallMate 对齐**：`CallSessionController` 管状态，`ChatSummaryService` 管摘要，用通话 `sid` 关联；不要另起一套。
- **两条硬规矩**：AI 代接必须先播提示（「正在由 AI 助理接听」）；策略改动留版本与审计，事后可查是谁在什么时候改了哪条。

### 7.5 两个已踩过的坑（写进设计，不要重犯）

1. **ANCS 是系统级绑定，一台手机只能一个 MCU 订阅**。iOS 会对配对过的 MCU 自动回连并恢复 ANCS，App 的「单连接互斥」管不到系统层——旧 MCU 会静默抢走通知与来电。CallMate 的处理是 MCU 侧按 `set_phone_os` 门控订阅 + 每台手机只保留一个活跃 MCU；连接器在支持多设备前必须先解决这个，否则多设备会互相抢来电。
2. **HFP 中继的音频口径是固定的**：Opus 16 kHz mono、60 ms/帧、16 kbps，两端必须一致；上行=来电者→MCU→App→云，下行=云 TTS→App→MCU→来电者（MCU 是耳机视角，命名与产品直觉相反）。改帧长就会同时破坏延迟与抖动缓冲。

### 7.6 工程参数（不是风险清单）

- 延迟预算：HFP/SCO 单向 ~100ms；BLE `call_up` 单向 80–150ms（20ms 帧 + 抖动缓冲）；USB UAC ~20–40ms。
- 音频口径：Opus 16 kHz mono、20–60 ms 帧固定；两端不一致会同时破坏延迟与抖动缓冲。
- 回声：设备端 AEC + 双讲检测；Agent 播报时把 `micGain` 压低（0.35）而不是静音，避免听不见用户插话。
- 混音默认：`agentGain = 0.5`（-6 dB）、`micGain = 1.0`；用户开口 → `DownlinkAudioPump.interrupt()` → `setMix(.full, 0.35, 1.0)`，静默 ~800 ms 后回升（800 ms 为经验值，未固化为常量）。
- 失败回退：接听方法逐个尝试 → 路由超时回 ringing → `answer_submitted` 永不当作「已接通」，只有 `active_confirmed` 才算；Agent 永不代挂断。
- 长通话：设备侧 Opus 连续编码 + 手机端 10 s 窗口增量转写，避免整通录音上传；转写复用唯一 Coordinator，不二次 ASR。

### 7.7 结论

通话不是「能不能截取系统音频」的问题，而是「设备站在通话的哪一端」。BLE 设备通过 `call_up` + `CALL_AUDIO` 就能完整参与 App 内通话；系统蜂窝通话走 HFP 或 USB UAC2。三条路径团队都有可运行代码，连接器要做的只是把它们抽象成 `CallService` 并接到会话上。

## 8. 产品价值排序

| 场景 | 价值 | 可行 | 判断 |
|---|---|---|---|
| 语音随身（设备做麦/喇叭，手机做大脑） | 5 | 4 | 核心，v1 |
| 内容下发（手机生成 → 设备执行：像素/灯效/墨水屏） | 4 | 5 | **v0 首选** |
| 家居/电视控制 | 3 | 5 | 底座能力，走 ADB/IR/CEC 时受机型限制 |
| 老人看护 | 5 | 3 | 后续，需雷达 + 家属端 + 7×24 |
| 儿童陪伴 | 4 | 3 | 受内容审核与备案约束 |
| 电视去广告 | 4 | 2 | **不做成产品**：ADB 强绑机型、绕过拦截有监管风险、已有判赔案例 |
| 通话中继（Agent 加入通话） | 5 | 4 | **一等能力**：三条承载已实现，接 `CallService` 即可，v1 做 |
| 车机 | 4 | 1 | **不做**：车规与商务门槛 |

Top 3：语音随身（价值最大）、内容下发（最快落地）、老人看护（后面做）。

## 9. 路线图

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **v0-W1** | 信封 + 幂等命令 + mock 设备回放（复用 `PhoneDSHLoopback`）：`DeviceEnvelope`、`tono.device-command.v1` 语义、Outbox | 重复投递只执行一次；离线重启补发 |
| **v0-W2** | 适配器骨架 + BLE 与 Wi-Fi 各一个实现；自有 ESP32 真机命令往返 | 手机下发 → 设备执行 → 回执可见；重连不重复执行 |
| **v0-W3** | 能力清单 + 门禁 + 灯效/像素屏两投影 | 未声明能力拒绝；像素屏分块传输不断帧 |
| **v1** | 语音（`InferenceProvider` 接入）+ 设备麦持续录音 + 通话 | 语音一轮端到端；设备麦连续录 10 分钟不丢帧 |
| **v2** | 存量小智 MCP 中继（`tool` 模式） + `brain` 模式开关 | 小智说出问题 → DSH 回答 → 设备播报 |
| **v3** | 墨水屏 / 普通屏投影、树莓派适配器（预留） | 同一意图四种目标正确降级 |

## 10. 风险与未决

1. 官方小智 MCP 接入点的条款、限流、是否长期开放——**未确认**，需产品侧核实。
2. 单台设备只能连一个 WS 端点：手机与云不能同时在线，需要端点切换或云代理。
3. 设备上行注入的提示注入风险：靠最小授权 + 默认空工具集 + 审计，不做正文清洗。
4. iOS 后台长连接不稳：长任务必须两段式。
5. 遗留 link 工程的真机证据普遍是 NOT_VERIFIED，跨设备 link 互操作尚未实现。
6. 树莓派 secure boot 会锁死换钥，量产前要定策略。

## 10.5 评审采纳记录

- 2026-10-31 GLM-5.3：来源标记改为 envelope + system 标注（正文不前缀）；audience 改为工具显式指定；传输拆控制面/媒体面（本次最大结构改动）；通话复用 `CallBridgeOptions` 超时与 `DownlinkAudioPump.interrupt()` 的打断、增益改线性 `0...1`；渲染从 `RenderIR` 改为 `RenderIntent` + 逐目标有损投影；v0 砍到「信封 + 命令 + 双适配器 + 门禁 + 灯效/像素屏」。
- 2026-10-31 Kimi k3.1-pro：来源改用 `origin` 字段；补上复用清单（`ResponseLog` → Outbox、`ASRTranscriptionCoordinator` → 通话转写、`CallAudioBridge` → attachAgent façade、`PhoneDSHLoopback` → M0 mock）；渲染补 `display.text` 兜底与按能力位降级；（远端 DSH 降级 attachment+ledger）；适配器义务从 10 项收敛到 6 项，保序/重传上收 Outbox（设备只做 msgId 去重 + 4 条环形缓冲）；渲染命令只带 hash/url，位图走 HTTP 回拉或 `render_chunk`；通话混音留在设备端（手机只发 setMix），否则设备 AEC 丢参考；v0 进一步砍到「契约 + ESP32 适配器 + Outbox + 门禁 + 灯效/像素屏」。
- 2026-10-31 产品反馈：设备麦持续录音提升为独立能力（§4.9）；通话补上接听策略与通话总结（§7.4）。

## 11. 已确认决策与剩余问题

**已确认（2026-10-31）：**

1. 接受 `tool` 模式：DSH 作为云 LLM 的工具；`brain` 模式作为可选项保留（M6）。
2. 服务端做控制中继：设备鉴权、配额、计量、命令投递都在自有服务器。
3. 语音出局域网、连自有服务器端口；ASR/TTS 与计量在服务端。
4. 先做 ESP32；树莓派只预留适配器能力（M5）。
5. 渲染目标四类都做：灯效、像素屏、墨水屏、普通屏。

**仍需对齐：**

1. 服务端中继的落点：改造现有 `chat-server`，还是新起一个 gateway 服务？（影响 M1 排期）
2. 语音供应商与计费单位（秒/字符/token）——影响计量 schema 与对账。
3. 开放协议（李光浩）的线格式、配对码方向、音频是否走同一通道——决定适配器实现，需在 M0 内对齐。
4. conformance 套件由谁维护：协议实现方跑，还是 phone-dsh 在 CI 里当门槛？
5. 像素屏/墨水屏的具体硬件规格（分辨率、色深、刷新率）——决定 RenderIR 的尺寸与预算。
