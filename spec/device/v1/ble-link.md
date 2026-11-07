# PDSH BLE Link Tools Profile v1

Status: `implemented` for the ordinary BLE Link tools profile in the registered Swift and reference C ends; runtime evidence is recorded in [the change record](../../../docs/protocol-changes/PC-20261105-device-ble.md). Current-head iPhone/ESP32 air-link and physical power-loss evidence is not available. The separately negotiated device-task profile remains `target`.


实现位置：`Sources/PhoneDSHBLE`（Swift SDK / CoreBluetooth）、`firmware/components/pdsh_link_wire`（纯 C wire 核心）、`firmware/esp32-reference`（ESP-IDF / NimBLE 参考外设）。本版包含 Link Core 工具、事件、Home HTTP；不包含音频、HID、通话或自动 Agent 触发。

## 与 xiaozhi-link 的兼容边界

以 xiaozhi-link commit `f7c72666e2210c02466337b72334d956a03b3657` 的 `docs/link-protocol.md` 为基线。本扩展是 PDSH 的可选 Tools Profile，不冒称已经获得上游 opcode / capability 分配，也不把旧固件升级成新功能。

保持原有 Service / ctl_rx / ctl_tx / audio_up UUID、u16 请求号、CCITT-FALSE CRC、512 字节最大信封、MTU 23–247 分段和 HELLO 的原有字段布局。没有重用已经预留给 NET_AP / VIDEO 的 0x50–0x53，也没有改变 v1.0–v1.2 任一已有 opcode 的意义。参考固件只实现 HELLO、GET_STATUS、未支持 SET 的短格式回执和新增 Tools Profile；不声明自己没有实现的录音 / HID / 时间 / OTA 等能力。

| 手机 | 设备 | 行为 |
|---|---|---|
| PDSH | 旧 xiaozhi-link v1.0–v1.2 | 完成旧握手，显示“未协商工具扩展”，绝不发送 0x54–0x56 |
| 旧 xiaozhi-link App | 参考固件 | 原 HELLO_ACK 前 25 字节照旧；仅声明实际工具能力，不推新事件；不提供录音等设备没有实现的功能 |
| PDSH | 参考固件 / 已加本扩展的固件 | 双向 capability 加扩展标签校验后使用工具 |

自动化会逐字节往返本仓库固定的全部旧 ctl 黄金向量。此为线格式兼容证据；尚不代表已用真实旧手机 App / 旧硬件跑过互通。

### 协商

- HELLO `proto_ver=0x0102`，`app_caps` bit10 为本地扩展 `PDSH_TOOLS`。不宣称 REC_WAL，因为本版没有音频 WAL / ACK。
- HELLO_ACK `dev_caps` bit20 为本地扩展 `PDSH_TOOLS`，前 25 字节保留旧格式。
- 支持本扩展且 App 声明 bit10 时，在 HELLO_ACK 尾部追加 8 字节：ASCII `PDSH`、`extension_version u16 LE=1`、`max_rpc u16 LE=4096`。
- 手机必须同时确认 bit20、完整标签、版本 1 和 max_rpc=4096；仅一个 capability 位不算协商成功，避免未来上游占用同一位时误发命令。
- 设备必须同时确认 app_caps bit10 才接受新请求 / 推新事件；否则返回短格式 UNSUPPORTED。major 不同的 HELLO 返回 BAD_VERSION。
- Device task inbox v1 additionally requires local `app_caps` bit11 (`PDSH_TASKS`) together with bit10. A device must neither advertise nor accept `pdsh.task.*` tools unless both bits were declared in the current HELLO. Older phones declaring only bit10 retain the exact existing ordinary tool list. This allocation is local, subject to upstream coordination, and does not alter older HELLO frames.
- 参考固件接受加密 + bonded 链路；手机先订阅 ctl_tx 和 audio_up 再 HELLO，后者仅为旧协议布局兼容，不传音频。

这些分配须在未来上游合并时协调；若发生冲突应升级扩展协商，不能静默改写已有部署。

## 通用 wire

```text
op:u8 | req_id:u16 LE | payload_len:u16 LE | payload | crc16:u16 LE
```

总长 7–512 字节，payload 最多 505。CRC-16/CCITT-FALSE：poly 0x1021、init 0xffff、无反射、xorout 0，覆盖前面的 op 到 payload。每次 ATT 写 / Notify 是 `seg:u8 | fragment`，bit1 FIRST、bit0 LAST、其它位为零；单段 0x03；fragment 上限 `min(ATT_MTU,247)-4`。同一消息段不能交错。超长 / 孤立续段 / CRC 错误不交付业务层。

请求号 1–65535，响应回显请求号且 `response_op=request_op|0x80`。本客户端一连接内不回绕请求号；耗尽要求重新连接。事件请求号 0。新工具请求不启用旧协议的通用自动重试逻辑，尤其绝不自动重试 COMMIT。

## 工具大消息

逻辑请求是最多 4096 字节 UTF-8 JSON，分成多条独立 ctl 消息，不提高旧信封的大小限制。设备只保留一个上传缓冲；必须按 offset 连续上传，同内容的重复片段可以 ACK，但不能延长首次接收时创建的单调时钟截止时间。完成后提交与查询分离，HTTP 不阻塞 ctl 响应线程。

| op | 请求 payload | 成功响应 payload |
|---|---|---|
| 0x54 UPLOAD | request UUID 16 字节；total u16；offset u16；ttl_ms u32；chunk 1–481 字节 | 0xD4：status=0 u8；next_offset u16 |
| 0x55 COMMIT | request UUID 16 字节 | 0xD5：status=0 u8；state u8 |
| 0x56 RESULT | request UUID 16 字节；offset u16 | 0xD6：status=0 u8；state u8；total u16；offset u16；chunk 0–499 字节 |

UUID 使用 RFC UUID 的打印顺序字节（不是 Windows GUID 的混合字节序）。total、offset、ttl 用小端。ttl_ms 为 100–30000；首片到达时确定设备截止时间，重复上传不续期；客户端默认 15000，并在本地使用单调截止时间。COMMIT 前或 worker 实际执行前过期均不得操作硬件或网络。

state：0 无记录、1 执行中、2 有完整 JSON 结果、3 outcome_unknown。state 非 2 时 RESULT 没有 chunk，total / offset 为零。state=2 的 total 必须 1–4096，返回的 offset 等于查询 offset，客户端必须逐片验证总长及匹配的 request_id。

错误使用旧 status 值：BAD_LEN=2、OUT_OF_RANGE / 冲突=5、BUSY=6、CANCELLED / 过期=9、INTERNAL=11、NOT_READY=13、UNSUPPORTED=14、STORE_FULL=15；允许仅 1 字节的短错误响应。未知 opcode 使用旧 NAK。上传、取消、断开都不能等同于撤销已提交的硬件动作。

### 逻辑请求与结果

```json
{"request_id":"ce6ec956-1111-4222-8333-123456789abc","name":"light.set","args":{"on":true},"idem_key":"64-character-sha256-of-phone-journal-key"}
```

root 只允许这四个字段；request_id 必须与二进制传输 UUID 一致。args 必须为对象。参考固件拒绝重复 root 字段、尾随非空 JSON、超过 16 层嵌套、NUL，以及不匹配工具的字段。name / args 通过 `tools/list` 发现。

```json
{"request_id":"ce6ec956-1111-4222-8333-123456789abc","status":"completed","result":{"on":true,"state_revision":1,"boot_id":123,"state_source":"gpio_level"}}
```

status 为 completed / failed / outcome_unknown。COMMIT 的 state=1 只是接受，不是成功。状态与回执是历史执行结果；设备重启后不能用旧 light.set 结果替代新的 light.get。state_revision 是持久化的 GPIO 状态修订计数，state_source 明确是 GPIO 读回，不代表存在灯具或执行器的独立物理反馈传感器。

`tools/list` 和 `light.get` 是只读请求，结果可暂存在 RAM，不占持久写回执。tools/list 返回 `device_id`（NVS 随机 UUID，不是 MAC）、`boot_id`（与 HELLO 相同）、`tools`（含 name、description、inputSchema）。不会把设备文本解释成系统指令。

The separately negotiated [task profile](task-delegation.md) additionally defines `pdsh.task.next` as read-only. Its acceptance and terminal task tools are mutations and retain the durable Link receipt and query-only recovery rules below.

## 持久化、重连和权限

1. 手机在上传前落盘工具意图，绑定 journal key、device UUID、工具名、参数摘要和 request UUID。相同 key 只查询同一个 request UUID，不重新上传或提交；参数冲突拒绝。即使第一次还没有到达设备，也宁可报告未知而不盲目重试。
2. 设备执行 light.set / home.http 前先 NVS commit intent（request UUID、幂等 key 摘要、整个请求摘要）。重复 request UUID 返回原状态；上传了不同内容则报冲突。换 request UUID 却复用 idem_key 也拒绝。
3. 再执行一次 GPIO / HTTP，之后 NVS commit 结果。若重启时只有 intent，则 state=3；不猜测成功，也不恢复执行。不因断线取消正在运行的有界 HTTP。
4. RESULT 是只读，可重连后继续查询。手机工具 `ble_link_result` 只允许查询本机日志里属于该设备、且对应工具仍获授权的 request UUID。
5. 本版手机 journal 最多 4096 条，参考设备持久回执最多 16 条，满时拒绝新的有副作用操作，绝不驱逐历史记录后允许旧命令再次执行。工具发现 / light.get 不耗设备持久回执。
6. 绑定与设备名不能替代 App scope。每次连接后逐工具授权，home.http 额外要求明确 origin。断连或蓝牙关闭清除授权；不自动连接、执行或重放。

取消当前 Link 工具会断开链路、停止客户端等待。已提交操作可能仍运行，恢复后只能查询；客户端错误必须保留 request_id。固件不会自动擦除 NVS 修复错误，否则会丢失幂等记录与绑定。

## Home HTTP Profile

`home.http` 的 args：method、url，及可选 headers、body、timeout_ms。手机与设备使用同一份从 xiaozhi-link 固定的 `xl_home_policy.c`，来源 / 哈希见 vendor/UPSTREAM.json。首版在旧策略之上进一步只允许私网 IPv4 字面量，不支持 DNS、.local、TLS、IPv6 或重定向。

- GET / POST / PUT / PATCH / DELETE，URL 最多 256 个 printable ASCII 字节。
- 10/8、172.16/12、192.168/16、169.254/16；手机用户与固件配置都必须允许相同的 IP:port。禁止 userinfo、公网 / loopback / 非标准数字 IP。
- 最多 4 个 header，name ≤32 字节、value ≤160 字节；拒绝 CRLF / NUL 和 Host / Content-Length / Transfer-Encoding；body ≤768 字节，GET / DELETE 无 body。
- timeout_ms 1000–10000，实际网络操作还受上传时确定的总截止时间限制。复用旧组件的固定目标 IPv4、带绝对截止时间的自定义 TCP transport，防止慢速响应拖长任务。
- 响应正文最多 1024 字节，UTF-8 净化，附 truncated；3xx 原样返回，不发第二条请求。
- 收到 HTTP 响应只表示该请求返回了状态码，不能证明家居动作已经成功。网络错误 / 超时可能发生在服务端已经执行之后，返回 outcome_unknown，不自动重试。

## 事件

0x6C，req_id=0，仅在双向 Tools 协商后发送。payload 是 ≤505 字节 JSON：

```json
{"event_id":"12345678-00000001","type":"button.pressed","device_id":"ce6ec956-1111-4222-8333-123456789abc","boot_id":305419896,"seq":1,"payload":{}}
```

event_id 是 boot_id 和 seq 各 8 位小写十六进制。手机校验设备身份、当前 boot_id、递增 seq，并在界面保留最近 32 条，重复 / 旧 boot 事件不交付。参考按键为按下边沿事件；此版是在线尽力交付，没有事件 WAL / 离线补传 / Agent 自动触发承诺。音频 WAL、持久 prefix ACK、credit、GAP 与补传须使用独立 Audio Profile，不能拿 ctl 接收当持久 ACK。

## 验证命令

```sh
swift test --filter 'PDSHLinkTests|BLEDeviceMCPTests|StandardBLETests'
bash firmware/tests/run.sh
# 先按 firmware/esp32-reference/README.md 构建，以获取固定 cJSON 依赖。
```

宿主 C 测试启用 AddressSanitizer / UndefinedBehaviorSanitizer，覆盖真实 wire、工具提交 / NVS / GPIO 控制代码、Home HTTP 执行代码（平台 / HTTP HAL 替身），以及上游纯策略测试。涵盖 CRC / 长度、最小 MTU 分片、重复 / 冲突、截止时间、无回执重启、NVS 失败、回执满和不跟随重定向。黄金向量由 C 生成并由 Swift 逐字节验证。替身测试和交叉编译均不能替代真机空口、配对、Wi-Fi 和实际家居服务的联调。

本项目另有 [原分支真机自动测试与证据说明](../../../docs/ble-hardware-testing.md)，已覆盖 iPhone 与 ESP32-S3 的实际 BLE 链路、HTTP、断连和重启恢复。参考 transport 通过片内 RAM 分配适配工作，无需初始化 PSRAM；vendor 原始文件未改动。

## P07 host mapping and recovery

A completed device operation can become an `applied` receipt only when the adapter has evidence it actually executed; a device-declared failure may become `failed` using an existing P07 code. An unknown, missing, timed-out or disconnected result is an unresolved host operation, not a device receipt. Preserve the request UUID and identity and query it on reconnection; do not replay a side-effecting commit. A successful commit acknowledgement means accepted, not applied. Events are online best-effort and have no offline delivery or replay guarantee. No promise of a 60-second reconnection or at-least-once delivery is made for this profile. Existing P07 host schemas remain unchanged.

The shared positive ctl vectors are `golden/xiaozhi-ctl.jsonl` and `golden/pdsh-link.jsonl`; `golden/invalid-ctl.jsonl` contains negative vectors. The Swift and C production decoders must consume these shared vectors. Tool descriptors and device content are untrusted data; only user-connected devices and explicitly granted tools are callable.

## Android decoder registration

The Android Link wire decoder, encoder and segment reassembler are a `target` implementation of this unchanged profile. They must consume the same `golden/xiaozhi-ctl.jsonl`, `golden/pdsh-link.jsonl` and `golden/invalid-ctl.jsonl` as the existing Swift and C endpoints and preserve the 512-byte envelope, CRC and ATT segmentation limits above. This registration does not claim Android GATT discovery, pairing, authorization, task intake or device runtime support. The separately negotiated task profile remains `target` and must not be called.

## Android Link channel target

The Android ordinary-Link channel is a `target` implementation of the existing
profile, not an authorization to call the device-task profile. Its
platform-independent state machine is tested before being connected to Android
GATT. It does not implement pairing, device identity, user grants, tool RPC,
durable intents or automatic reconnection. A future adapter must supply a new
connection generation and confirm both notification subscriptions before
starting the channel. It must deliver each write callback with the generation
and the identity of the exact outstanding write; stale callbacks cannot advance
a newer connection or a later write.

A channel starts by transmitting the existing HELLO with app capability bit10
and without bit11. Until a valid HELLO_ACK is received, application requests
are refused. A legacy valid HELLO_ACK without the complete Tools extension
permits ordinary Link but not opcodes 0x54–0x56. No other request can be in
flight. IDs are assigned once per connection from 1 through 65535 and are not
reused; exhaustion requires disconnect and a new channel. Transmit each ATT
segment by a write with response, waiting for the matching successful callback
before issuing the next. A matching response may arrive before the final write
callback; retain it but do not complete the request or begin another one until
the callback succeeds. Mismatched IDs and unexpected opcodes do not complete the
request. Link NAK 0xff with the current ID is a terminal explicit NAK; matching
0x6c/ID 0 is a separate best-effort event after handshake, not a response.

A timeout, cancellation, transport error, malformed incoming frame or disconnect
terminates the channel, clears its reassembler and pending data, and asks the
adapter to disconnect; if an operation has started, its remote outcome is
unknown. The channel never resends requests or treats a write callback as
execution. Callbacks from an old generation are ignored. Application-level
tool permissions, intent persistence, result queries and side-effect recovery
remain governed by the preceding profile and are not supplied by this state
machine. The state machine has no timer of its own: its owner supplies a
monotonic timeout event; its eventual adapter must enforce the existing Swift
three-second per-exchange deadline. The shared valid and invalid transition
scenarios are in `golden/android-link-channel.jsonl`; normal frame bytes remain
those in the existing shared ctl vectors. This target is not wired to a user
feature until an actual GATT adapter, authorization, persistence and runtime
evidence are available.
