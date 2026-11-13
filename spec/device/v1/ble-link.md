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
- The reference firmware's ordinary Link ingress MUST NOT advertise or start a new `pdsh.task.*` request, even when both bits are set. This denial is permanent: BLE tasks are carried only by the authenticated session of [ble-secure-session.md](ble-secure-session.md) (§11), which adds its own GATT service and never falls back to this path. For a valid new request UUID and an otherwise healthy, idle store, COMMIT returns the existing `UNSUPPORTED` status (14) for `pdsh.task.next`, `accept`, `complete`, and `fail`; the denied request creates no durable Link receipt and does not change the task store. Firmware without the secure service may still advertise and answer the identity proof under its existing capability conditions; it is relayable and does not authorize a task. Firmware that registered the secure service retires it (not listed; a call returns `UNSUPPORTED` 14 with no receipt and no signature; [ble-secure-session.md](ble-secure-session.md) §11.3). Ordinary Link operations retain their existing semantics. A pre-existing request UUID is governed by the existing receipt/replay rules before a new request can be classified; its legacy RESULT is not authenticated by this rule. `golden/ble-task-plaintext-admission.jsonl` specifies the shared new-request scenarios, each with the secure service absent and present. This denial is not itself an authenticated session.
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
5. 本版手机 journal 最多 4096 条。参考设备持久回执最多 16 条，且受 NVS 空间约束（一条回执约 4.2 KB，NVS 与绑定共用）。**回执保留**：当没有空槽，或写入回执 / 结果时 NVS 返回空间不足，设备驱逐**最旧的已结束回执**（state 2 或 3；按随回执记录的年龄 `s00…s15`，无年龄的旧固件回执视为最旧），**绝不驱逐运行中（state 1）的回执**，然后重试写入。驱逐前先把该回执的 request UUID 与幂等 key 摘要写入持久**墓碑环**（至少 16 条，`tombs` / `tomb_n`）：此后复用该 key 或 request UUID 的 COMMIT 仍返回冲突 5，绝不再次执行；对该 request UUID 的 RESULT 返回 state=3（outcome_unknown）。墓碑环满时覆盖最旧墓碑；手机绝不复用 journal key，所以更旧的 key 不会被合法重发。仍无可驱逐回执时才返回 STORE_FULL。墓碑读取失败时设备视为不健康并拒绝新的副作用操作。工具发现 / light.get 不耗设备持久回执。
6. **受信任的已连接设备（iOS App）。** 用户在 App 内连接一块板子即是信任决定：Link 握手完成后，该板子声明的全部普通 Link 工具与标准读取 / 提醒默认允许，无需逐项点击；用户关闭某个开关即撤销，且撤销被记住（UserDefaults `phone-dsh.ble.revoked-grants.v1`：Link 工具按设备在 HELLO 中自报的 Link device ID 记录，读取 / 提醒按 peripheral UUID 记录为 `@read` / `@alert`）。用户连接过的板子记录在 `phone-dsh.ble.remembered-boards.v1`，App 启动时以及板子掉线（重启、超出范围）后会自动重连——重连在断线回调完全返回之后经普通连接路径发起，绝不在回调内；**只在板子确实在场时发起**（扫描收到它的广播），绝不对仅“已知”（`retrievePeripherals`）或系统层已连接但不归 App 所有（例如系统作为 HID 自己重新连上）的板子盲目发起连接：前者那次连接会超时，按下文所有者规则进入“连接状态无法确认”隔离，直到 App 重启；后者 App 拿不到 `didConnect`，且接管一条系统连接意味着 App 之后一次的断开会把系统正在维持的 HID 链路一起断掉，所以本版不自动接管（见 GAP-37，只能等它广播或由用户重连）。对任何“已知但不在场”的板子都不得盲目连接：那次连接会超时，按下文所有者规则进入“连接状态无法确认”隔离，直到 App 重启。掉线后先每 3 s、一分钟后每 15 s 观察约 6 分钟；用户点“断开连接”即不再自动重连。扫描同时列出系统已连接（例如经 HID）且提供 Link 服务的外设，且已记住 / 系统已连接的板子不受 100 条发现上限影响。限制：Link device ID 由设备自报、非密码学身份，自报同一 ID 的设备会继承这些决定；home.http 仍额外要求明确 origin。库默认（`trustConnectedDevices = false`）保持旧行为：每次连接后逐工具授权、断连清除授权、不自动连接。任何情况下都不自动执行或重放工具。
7. **被拒绝的 UPLOAD / COMMIT 未执行。** COMMIT 之前不得操作硬件，所以设备拒绝 UPLOAD，或以 5 以外的状态拒绝 COMMIT 时，什么都没有运行：手机报告 `not_executed`（附状态名，如 STORE_FULL / BUSY / INTERNAL），可以发起新调用。COMMIT 冲突 5 可能表示同一请求此前已提交，仍报告 outcome_unknown、只能查询。设备拒绝某请求的 COMMIT 后释放属于该请求的上传缓冲，下一个请求不会因其 TTL 被回答 BUSY。

取消当前 Link 工具会断开链路、停止客户端等待。已提交操作可能仍运行，恢复后只能查询；客户端错误必须保留 request_id。固件不会自动擦除 NVS 修复错误，否则会丢失幂等记录与绑定。

### Link 调用准入（`target`）

Status: `target`，由 [PC-20261112-device-panel](../../../docs/protocol-changes/PC-20261112-device-panel.md) 冻结，尚未实现。
在实现并有回归之前，现行行为如本节末尾所述，任何调用者都不得依赖新的准入顺序。

同一设备同一时刻至多一个进行中的 Link 工具调用或结果查询。准入对所有调用者相同：Agent 的 `ble_link_call`／
`ble_link_result`、[设备面板](device-panel.md)，以及占用同一 Link 的其他宿主操作。

1. 忙必须在**落盘意图之前**判定。被拒绝的调用没有 journal 记录，没有 request UUID，没有上传任何字节，
   等同未执行，调用者可以发起新调用。
2. 后到者得到现有的 Link 忙错误。不排队，不抢占，不新增错误码；先到者不受影响。
3. 准入成功之后的一切仍按上面的规则 1–7：先落盘再上传，未知结果只能查询。

现行行为（`8f3de8b8` 源码，未做 runtime 实验）：`DeviceMCPServer` 在落盘前拒绝第二个 MCP 调用；
`BLEDeviceStore.invokeLink` 的忙检查在意图落盘之后，其拒绝经通用错误路径报告为 `outcome_unknown`，尽管没有上传。
这符合规则 1，所以不是违约；实现本节时两处合并为落盘前的同一个准入点，Agent 在该情形下的可观察结果由
`outcome_unknown` 变为忙且无记录，须有回归覆盖。

### iOS standard GATT authorization ordering

Status: frozen local amendment, implementation pending. This is not a device
identity, authenticated session, change to ATT/Link encoding, or permission to
call the target device-task profile. Android standard GATT remains target.

The iOS standard-data read and Immediate Alert permissions are separate,
per-device local declarations. A declaration with a nil field leaves that
field unchanged; later synchronous reentrant declarations of the same field
win. A declaration for a different field or device must not be lost merely
because it is nested in an Observation callback. A declaration covering both
fields records both intentions before any observable notification; a later
declaration may replace only the field it names. An invalidated connection
owner revokes both permissions, taking precedence over older declarations.
Revocation immediately prevents admission before any observer can reenter.
An enabling declaration does not grant admission until its still-current
observable commit completes. A stale publication must never restore a revoked
permission or overwrite an unrelated later device change.

Each accepted connection attempt begins a new local owner and clears both
earlier permissions before notifying observers or sending the connect command.
A disconnected caller can still set a declaration as before, but it cannot
operate GATT while disconnected and it does not survive an accepted connect.
A declaration made during the new `connecting` owner is an explicit new
declaration; it grants no operation until the local owner is connected, any
required prior disconnect boundary has completed, services have been
rediscovered, and the characteristic belongs to that current owner. A
`CBPeripheral.state` value by itself is not sufficient admission evidence.
These local labels do not prove peer identity, link encryption, or radio
liveness. No authorization is inherited from discovery, the device name,
an old owner, a prior task identity or a characteristic's presence.

For compatibility, a `grant` call when a standard read is pending for the
same device ends that captured read and requests disconnection even if both
arguments are nil, a value is unchanged, or only alert was specified. Before
any observable notification, the old owner becomes closing, both permissions
become unavailable, and that specific read continuation and timer are
detached. If this grant wins the pending operation's outcome claim, complete
it once with the existing permission-changed failure; if another terminal
event already won, preserve that earlier outcome. Do not finish a later read, cancel a later timer, or disconnect a
new owner by re-looking-up a UUID. If no matching read was pending at entry,
this call must not cancel one installed by a later reentrant operation.

When a submitted read instead times out or the caller cancels it before an
eligible completion callback, detach that exact continuation and, if this
event wins its outcome claim, fail it once with the existing timeout or
cancellation result. Preserve any earlier winning outcome. Revoke the old owner's
grants and enter the same closing quarantine before an observer can install
a new read. If the manager is powered on, request disconnection of that old
connection; otherwise do not issue CoreBluetooth commands. A read cancelled
before submission reservation may end locally without a disconnect. An eligible
completion callback for the sole submitted read on a never-subscribed
characteristic may finish that read with its actual value or error; this rule
does not assert that the OS supplies a request token or that undocumented
duplicate radio callbacks can be distinguished from a later read.

Caller cancellation can arrive off the main actor. Cancellation, eligible
value/error completion, timeout, grant, disconnect and manager unavailability
must compete for the same single thread-safe local outcome claim for the
captured operation. The first valid claim decides the continuation's result;
later events cannot replace it or resume it twice. An operation whose outcome
is claimed but whose continuation or owner has not yet been cleaned up remains
an old resource: a later grant still performs the applicable revocation and
closing, without changing the claimed result. Create the claim before any
possible submission. Reserve submission under the same short bookkeeping
before the physical call: cancellation that wins before reservation prevents
submission; if reservation wins first, cancellation treats the operation as
possibly submitted and requires closing even if the eventual physical call is
suppressed. No claim lock is held across an Observation notification,
CoreBluetooth call, continuation resume or await. This determines local
cancellation order, not the physical origin of an OS callback.

Closing denies new standard reads, alerts, Link calls, discovery operations
and connection attempts for that peripheral. A positive grant while closing
or quarantined is refused and leaves both effective permissions unavailable;
the interface reports that the connection is unavailable. Revocations remain
permitted. Cancellation of a submitted
CoreBluetooth command is not a completed disconnect. For a locally exclusive,
previously connected attempt with system auto-reconnect disabled, a candidate
may leave closing only after the applicable `didDisconnectPeripheral`
delegate callback has completely returned; subsequent attempts rediscover
services and characteristics. User requests during that callback do not pass
the boundary early. A natural disconnect of the current, previously
connected, locally exclusive owner follows the same rule: revoke and clear
the old owner, then allow a new explicit connection after the applicable
callback has returned. An ambiguous or unexpected event does not acquire
that owner merely by matching its UUID. If the application cannot establish this boundary,
including a cancelled pending connection, unexpected callback, radio reset or
manager replacement, it stays unavailable rather than using a timeout or
`CBPeripheral.state` as proof. A connect cancelled before being submitted to
CoreBluetooth can terminate locally, because it has no submitted operation.
The interface must tell the user when the peripheral remains unavailable and
that a new connection requires new authorization. It must not claim an
operation has been undone; an already submitted alert remains
`submitted_unconfirmed` and is not automatically retried.
The Bluetooth page keeps that device visible, displays `正在等待系统断开，暂不可重连`
while closing and `连接状态无法确认，暂不可用` while quarantined, and does not
offer connect, read, alert or Link actions for that owner. A successfully
started new connection explains that authorization must be given again. These
are local UI statements, not a claim that a physical connection has ended.

When the central becomes unavailable, revoke local admission and detach the
affected pending read before publishing status. If unavailability wins its
outcome claim, finish it once with the existing Bluetooth-unavailable failure;
otherwise preserve the already claimed outcome. Do not issue CoreBluetooth
commands while the manager is not powered on. When the manager state makes
previously obtained peripheral objects invalid, discard them and require new
discovery. A later powered-on state or rediscovery alone is not proof that
old callbacks have drained. A positive declaration during closing or
quarantine is refused; revocation is always accepted and cannot make a
closing connection usable.
If no connection attempt has ever been submitted for an idle peripheral, there
is no old connection attempt to quarantine solely because the manager becomes
unavailable. Commands remain disabled while it is unavailable; after power
returns an explicit connection can start if the peripheral object is still
valid, or after the required rediscovery if the manager invalidated it. This
exception does not release an outstanding or ambiguously finished attempt.

#### iOS service database changes

For a `didModifyServices` event on the current locally exclusive connected
peripheral, treat the current connection's entire service database as
unavailable, whether the supplied invalidated list is empty, names a used
service, or names another service. This is an intentionally conservative app
policy: Apple's service-change documentation invalidates the listed previously
discovered services but does not require disconnecting the whole peripheral.
It means an unrelated service change may interrupt otherwise working Link and
standard GATT and require a new explicit connection and new grants.

Before notifying observers or submitting any further physical command, revoke
the owner's standard and tool admission, invalidate the identity and current
service/characteristic maps, detach its Link channel/client and old pending
read and timers, and preserve any already-claimed read outcome. If the change
wins the pending read's claim, complete it once using the existing
`Device disconnected` error; a later value, timeout or cancellation cannot
replace the winner. Pending reads and state belonging to another device remain
its own. Do not change the legacy preference value. A submitted Link operation
without a terminal result remains outcome-unknown and a submitted alert
remains submitted-unconfirmed; neither is automatically replayed or claimed
to be undone. An already completed Link result is not retroactively changed.

While the manager is powered on, the matching previously connected owner
enters closing and requests cancellation of that connection once for the
service-change event. A repeated matching service-change event while closing or
quarantined must not submit another cancellation or release the boundary.
Other independently unexpected events continue to follow their existing
fail-closed rules. A current connecting or otherwise unassignable attempt is
quarantined; any cancellation is subject to the existing pending-connect and
manager-state rules. While the manager is powered on, an event for no local
owner cannot affect another device; a different physical object for a known UUID follows the existing unexpected
peer policy, not UUID-only attribution.

If the manager is already unavailable when this callback arrives, apply the
existing manager-unavailable transition to all affected local owners and
pending reads immediately, even if the manager-state callback has not yet run;
do not submit CoreBluetooth commands. This is a local observation of manager
state, not proof of when the physical radio changed. After a valid matching
disconnect callback has completely returned, the existing connected-owner
boundary may permit an explicit reconnect with fresh discovery and grants;
timeout, a cancellation request, a late event or an ambiguous callback is not
that boundary. If an indistinguishable old callback is delivered using the
same physical object for a newer owner, the conservative policy can close the
new owner; a local revision does not prove its radio origin.
Recheck the manager before a physical cancellation and after any synchronous
callback in the teardown path. If it became unavailable before cancellation,
apply that same all-owner manager-unavailable transition before further
observable publication and issue no physical cancellation. Preserve any read
outcome already claimed before the change; do not reinterpret it as failure.

The shared `golden/standard-gatt-service-change.jsonl` cases exercise the real
store's callback dispatch and state machine using simulated physical objects.
They do not establish which service-change sequences or object reuse an OS or
peripheral produces. Duplicate discovery, multiple services with the same
UUID and source attribution beyond this event remain open in GAP-31.

#### iOS discovery ownership and ambiguity

For each locally exclusive connected owner, submit service discovery at most
once, and submit characteristic discovery at most once per selected concrete
service object. Keep a local ledger of the actual peripheral and service object
references, each request's planned/submitted/completed state, and immutable
callback snapshots until that owner is retired. The ledger matches app-visible
objects and local submissions only; CoreBluetooth does not provide an app
request token. If an old callback and a current callback use indistinguishable
objects and data, the ledger cannot prove the radio origin or freshness.
Do not infer a peer's identity, bonding, database completeness or OS callback
order from it. The service-change and disconnect boundaries above still apply.

While a matching submitted request is still pending, a services callback with `error == nil` and `services == nil` is
uncertain: do not publish a result, reissue discovery or restart the deadline;
keep waiting until a non-nil result or the existing bounded timeout. A non-nil
empty array is a completed empty local result, not proof the remote database
has no services. A matching submitted characteristic callback with `error ==
nil` and `characteristics == nil` is likewise uncertain and remains pending
under the same fixed deadline; repeated nil callbacks have no side effect. An
empty array is a completed result with no candidates. The existing 20-second
connection deadline starts at the connection attempt, not at discovery or at
each callback; this change does not extend it. An expected discovery error closes the current connection with
the existing disconnected outcome and applicable disconnect boundary; it is
not converted to a successful empty result. Unknown/unrequested callbacks or
changed completed results from a current connected owner are quarantined under
the existing unassignable-event policy. Closing/quarantined owners cannot be
revived by a late discovery callback; an unknown ID while powered on cannot
alter another owner. If the manager is unavailable at a discovery callback or
becomes unavailable during a synchronous callback before a physical command,
apply the existing all-owner manager-unavailable transition and send no new
CoreBluetooth command. A nil or error callback after a non-nil result was
already completed is not a successful duplicate and follows the same
unassignable/changed policy; it must not reopen the completed request.

Before publishing any candidate or sending a characteristic discovery, take
a complete local services snapshot and plan all selected service instances.
Retain actual service object references and UUIDs, including duplicate
occurrences in the snapshot; do not use UUID as an instance identifier or
reduce the snapshot to a set. Requests are made once per distinct selected
service object, so repeated references to the same object do not cause
duplicate physical requests. Before filtering any result, verify that every
returned service's parent is the current peripheral by object identity;
likewise every returned characteristic must have the exact callback service
as its parent. An absent or different parent is unassignable and quarantines
the current connected owner, even when that object has an unrelated UUID or
another valid candidate exists. Ignore unrelated UUIDs only after this check.
Record the selected
objects for every standard UUID group before the first request is submitted;
then consider distinct selected services in the order of their first appearance
in that snapshot, skipping only the stated policy skips. Reserve each request
immediately before its physical call, after checking
the current owner, peer, ledger and powered state. This is a local
may-have-been-submitted boundary, not evidence that the OS accepted a command:
there is no await or user/test callback between the reservation and physical
API entry. Any before-submit test hook runs before reservation; if it changes
the state, no command is submitted. Once reservation wins, conservatively
treat the request as possibly submitted. A callback for an object that was
only planned and never reserved is not attributable to a later request.
The power and ownership check is the last *locally observable* check, not an
atomic guarantee about radio state. If unavailability is observed before
reservation, run the all-owner unavailable transition without submitting.
After an API returns or synchronous callback reenters, if unavailability is
observed, run that transition before publishing or submitting another command.

If the services snapshot contains no Link service, no Link discovery or
notification is sent, `linkState` reports `本次未发现 Link`, and supported
standard services may proceed. After a completed services snapshot, including
an empty array, the device remains `已连接` unless a separate error/teardown
wins; this initial local connection state does not assert characteristic
discovery completion or profile availability, and the fixed discovery deadline
continues until the completion rule below is met. The UI describes only this
local result. If it has
more than one distinct Link service object, do not select one, combine their
characteristics or submit a Link request; display `发现多个 Link 服务，暂不可用`
and allow separately valid standard profiles. Record each such Link instance
as explicitly skipped for this reason. Repeated references to one Link
object count as one instance for planning. With exactly one Link service,
stage its characteristic result before publishing any endpoint or channel:
RX, TX and audio-up each require exactly one distinct characteristic object
of the required UUID, belonging to that service. RX must support write, TX
and audio-up must support notify. Repeated references to the same actual
characteristic count as one candidate, while different objects with the same
required UUID are ambiguous even if only one has the needed property. An
empty/incomplete/ambiguous/unsupported initial result displays
`Link 特征不完整或存在歧义`, installs no Link channel and sends no Link
notifications; unrelated characteristics do not make a required UUID
ambiguous. Independently valid standard profiles remain available. Once a
complete unique result is accepted, install only that actual channel and
submit TX then audio-up notification under the existing owner/channel
installation guards. A later changed, incomplete or unrequested result must
never replace an endpoint table while retaining the old channel or identity.

For each standard service UUID, collect all distinct service objects selected
in the completed services snapshot. Publish no profile from that UUID group
until every selected member has completed its submitted characteristic
request or was explicitly and validly skipped; a planned-but-not-submitted
member and a submitted-but-pending member both prevent group publication.
Other completed UUID groups may publish independently. For each allowlisted profile, count
distinct characteristic objects with its service/characteristic UUID and
correct parent across the whole group *before* checking capabilities. Exactly
one candidate with the required read or write-without-response property may
become available. Multiple distinct candidates make only that profile
ambiguous, including when one lacks the required property; no candidate or a
single unsupported candidate makes that profile unavailable. Repeated array
references to the same object do not create an extra candidate. No discovery
implicitly grants read, alert, tool or task permission. The discovery deadline
is cancelled only after the services result is completed and every selected
member has completed its submitted request or was explicitly and validly
skipped by the ambiguity policy. A planned-but-not-submitted member also
prevents deadline cancellation; cached non-nil characteristics do not finish
a request. An empty selected set, or one consisting entirely of explicit
policy skips, satisfies this completion condition. Once the completion
condition first becomes true, remove and cancel that owner's discovery deadline
before publishing the completion-causing result or entering its Observation
callbacks; this local timer action cannot authorize any operation. Recheck the
owner and power before publication and any subsequent physical command. Timers
for reads and other owners retain their own ownership.

For a locally completed successful callback, store an immutable discovery
snapshot before any Observation notification or next physical command. A
later callback with the same current peripheral, service where applicable,
and same object-reference **multiset** in any order is a no-op only while the
manager is powered on and that current owner is connected and attributable,
and only when its
relevant snapshot fields also match. A services snapshot contains service
object identity, UUID and primary status; it does not include characteristics
which may be discovered later. A characteristic snapshot contains its parent
service, each characteristic object identity, UUID and discovered properties
bits. Runtime value, notification state, descriptors and RSSI are not
discovery snapshot fields. Repeated occurrences remain in the multiset even
though planning deduplicates the same object. A duplicate must not send a
request or notification, publish any devices/status mutation, cancel a timer,
restore a grant or replace a channel. An error callback is never an idempotent
successful duplicate. A different object, parent, UUID, properties value or
multiset after completion is changed, even if its UUID text matches. Manager
unavailability takes precedence over this no-op and triggers the existing
all-owner unavailability transition.

Reserve a submitted local request before its physical call. Consume a request
and record its accepted non-nil result before any subsequent synchronous
callback or Observation notification; a nil uncertain result remains pending.
After each such callback or notification, and inside
the actual devices mutation after will-change observers, recheck the current
owner, peer, relevant ledger/group revision and physical power before
publishing or submitting the next command. A later disconnect, service change,
different result or B-device grant must not be overwritten by an older A
publication. The existing single read-outcome claim and no-replay rules apply
to closing/quarantine while a read or Link operation is pending; a previously
won outcome stays won. These rules describe local behavior and intentionally
tighten compatibility for ambiguous devices; real OS and peripheral behavior
still require separate evidence.

Each actual connection/discovery deadline scheduling has a fresh non-reusable
local identity retained by its production timer and handler. A probe for that
deadline observes the same identity; an owner identity or a DEBUG-only counter
is not a substitute for it. The original connection/discovery deadline and the
final accepted discovery result have one local first-winner decision. If the currently owned active
deadline handler is admitted first, reserve its status intent, remove and
cancel that deadline, and move its owner out of connected/connecting admission
before any Observation notification, physical disconnect or other synchronous
callback. A later discovery callback for that closing or quarantined owner
cannot publish a profile, install or revive a channel, grant access or restart
the deadline. The existing close path claims any pending read once, terminates
an unfinished committed Link operation with outcome unknown and does not
replay it. An already claimed read result or already returned Link result is
not replaced. A connected owner enters closing; an owner whose connection is
still pending follows the existing quarantine boundary. A connected owner's
eligible physical disconnect submission precedes its closing devices
will-change notification. This is an ordering of local API submission, not
evidence that CoreBluetooth has completed disconnection.

If discovery completion removes and cancels that owner's original deadline
first, a later invocation of the captured old timeout is a no-op, even when it
is reentered inside the completion's will-change notification. An old owner's
timeout cannot affect a new connection, its deadline or another device. The
timeout's status text is published only after close while the captured owner,
its closing/quarantined phase, current local status intent and power remain
eligible; a later status intent may supersede the text without undoing close.
First establish that the captured deadline still belongs to the current owner
and is active. An old or cancelled timeout is inert even if physical power is
already unavailable; it cannot independently alter another owner, and a later
eligible event or manager callback handles that unavailability. If power is
unavailable for an otherwise eligible current deadline, apply the existing
all-owner unavailable transition without a timeout status or physical
disconnect. If power becomes unavailable during the winning close, apply that transition as soon as locally
observed, submit no subsequent physical command and preserve earlier local
claims and already submitted commands. A local timer or revision is not an OS
request token and does not prove callback freshness or physical timing.
Shared deadline cases and malformed/semantic mutations are in
`golden/standard-gatt-discovery-deadline.jsonl` and
`golden/standard-gatt-discovery-deadline-mutations.jsonl`; the real-store setup
and assertions are specified in
`docs/protocol-changes/PC-20261107-discovery-deadline-order.md`.

For the store's shared `status` text, all publication sites participate in one
local, non-reusable revision sequence. Once an event or user action satisfies
its original eligibility checks and is known to intend a status, reserve its
revision before evaluating a potentially reentrant message, taking a physical
side effect, or notifying any observer, including the devices notifications
in connection teardown. An ineligible stale event cannot reserve a revision.
Before writing inside the actual status mutation, recheck that the reserved
revision is still current and that the original operation's applicable owner,
peer, phase, channel and power conditions still hold. A later eligible intent
permanently invalidates an older uncommitted intent even if that later intent
subsequently becomes ineligible and commits no text. A same-text intent still
reserves a fresh revision, but if the currently stored text is already equal,
it makes no status mutation or Observation notification. Text equality is not
an operation identity and cannot resurrect an older intent. Revision identities
are local only; they do not label OS callbacks or authorize devices.

This ordering covers scan initialization/rejection/start, manager state,
connection timeout/failure, discovery and notification failure, asynchronous
Link handshake failure and the Link-busy indication. Losing the status text
race never by itself cancels or duplicates the event's required disconnect,
timeout, scan or other side effect; those use their own existing lifecycle
guards. This rule orders only local status text, not every other effect of a
scan or asynchronous callback; the remaining global-state reentry work in
GAP-30 is not thereby closed. Shared state and status observation must be tested
through the real store and callbacks; a test-only setter or token is not proof
of event eligibility. The shared status inputs and expected local outcomes are
`golden/standard-gatt-status-order.jsonl`; their setup, semantic mutations and
required side-effect checks are in
`docs/protocol-changes/PC-20261107-ble-status-order.md`.

Scan intent (`scan-intent-v1`). An admitted `scan()` (powered-on manager, or
an uninitialized manager that it will construct), every `stopScan()`, including
the one issued by `connect`, a scan deadline expiry and all-owner manager
unavailability each take a fresh, non-reusable local scan intent before any
Observation, physical command or status evaluation. Taking it immediately
invalidates the older intent, its pending initialization start and its
15-second deadline. A `scan()` rejected because an initialized manager is
unavailable takes no intent; it only publishes its rejection text. Every later
effect of an operation — manager construction, the `scanning` write (rechecked
inside the actual mutation, after will-change), its scan status eligibility,
deadline installation and the powered-on automatic start — happens only while
that operation's intent is still current; a superseded operation returns
without writing. A physical command already submitted is never retracted, and
a stale frame never submits another. Each deadline belongs to exactly one
intent; on firing it first checks that it is still that current intent's
deadline (a stale or cancelled deadline is inert regardless of power) and only
then performs the ordinary stop. `stopScan()` publishes no status text, so a
superseded start leaves the earlier text in place. `scanning` is the local
projection of the current intent, not `CBCentralManager.isScanning` or radio
acknowledgement; a same-value write makes no mutation. A constructor already
entered cannot be retracted, but a cancelled initialization never enters it.
Shared cases and malformed/semantic mutations are
`golden/ble-scan-intent.jsonl` and `golden/ble-scan-intent-mutations.jsonl`;
setup and assertions are in
`docs/protocol-changes/PC-20261107-ble-scan-reentry-ccr.md`. This is local
ordering only; real CoreBluetooth radio sequencing is not established by it.

The shared discovery object graphs, ordered callbacks and expected checkpoints
are in `golden/standard-gatt-discovery-ownership.jsonl`, with malformed and
semantic mutations in `golden/standard-gatt-discovery-mutations.json`. Their
real-store setup, observation and physical submission rules and additional
in-flight Link and reconnect tests are specified by
`docs/protocol-changes/PC-20261107-gatt-discovery-ownership.md`. Shape checks
alone do not establish that the production store follows these cases.

The value callback is used for both reads and notifications and has no app
request token. A standard read cannot rely on a callback as its result if the
application has subscribed to notifications for that characteristic during
the current owner or cannot establish that no such subscription occurred;
disabling notifications alone is not evidence that queued updates drained.
Application-level operation tokens protect locally captured timers,
continuations and side effects, but do not label arbitrary OS callbacks.
Unknown or unassignable events fail closed; no app epoch is evidence of the
radio source. Before the standard-read decision, events for a supported Link
characteristic discovered for the current connected local owner are routed
to that owner's real, still-active Link channel and do not finish a standard
read merely because one is pending. A late Link event while closing,
quarantined or manager-unavailable does not invoke the old channel's event
handler or recreate resources. A truly unassigned event is not made valid by a UUID match.
System auto-reconnect must remain disabled for the proposed
disconnect boundary. The Apple documentation cited in
`PC-20261107-standard-gatt-quarantine-ccr.md` is the basis for that boundary;
physical OS and peripheral behavior still requires independent verification.

Shared `golden/standard-gatt-grant-order.jsonl` cases define the local
success and failure interleavings, including same-field and cross-field
reentry, admission during revoke, old pending ownership and the disconnect
boundary. Tests drive the actual store and its actual authorization and
continuation transitions with controlled callbacks; injected labels are not
evidence that CoreBluetooth supplies a radio request token. An OS/device test
requires an actual controlled peripheral implementing the relevant standard
services. The Link-only reference ESP32 is not that evidence.

For those cases, A and B are distinct locally simulated peripherals with
independent initial connected owners unless a case explicitly specifies a
different starting phase; unspecified grants begin false. The internal test
adapter may replace physical peripheral/characteristic identity, state,
received bytes and CoreBluetooth submissions, and feeds the same production
callback transitions and real Link channel byte-level receive path. It cannot
directly set grants or claim that an OS callback carries an app request token.
Grants, admission, local owner and
pending-continuation state all run through the real store. Initial true grants
are established by real `grant` calls before tracking begins, and a real
controlled `read` installs any initial pending operation. Each nested action
is executed synchronously once from a real `withObservationTracking`
callback. Counts exclude setup submissions; observations must be bounded.
The fixture's booleans are the final displayed grants, `phase` is A's local
phase, `pending` records the old/new continuation outcome, and submission
counts count only actions after setup. `b_phase` is B's local phase;
`unavailable_visible` checks the store's user-visible unavailable state for A;
separate real Bluetooth-page tests must verify that state renders its message,
does not offer blocked actions, and clears or transitions correctly after the
applicable boundary. A package-level store test alone is not UI evidence.
`discovery_submissions` counts service or characteristic discovery,
`link_submissions` counts outgoing Link operations; `link_deliveries` counts
an actual decoded TX event delivered through the real Link channel, not a
call to a fake channel. The existing audio characteristic is not asserted to
deliver an event. `other_closing_commands` counts
GATT/notification commands other than the
separately counted disconnect request attempted after A enters closing or quarantine. In those cases the test actively
attempts read, alert, Link, discovery and another GATT/notification submission;
none may reach the adapter. `pending_error`, `pending_value`, and
`old_read_timer` describe the captured old read, not an invented OS request
token. `absent-or-cancelled` accepts either no timer ever created or an
existing timer actually cancelled; it never accepts an active old timer.
Compare the existing error category and actual timer ownership rather than
only a generic failed state. For `pending_value=expected`, the controlled
adapter supplies the Battery Level byte 37. Exercise the production decoder
and public returned string, require its exact `37 % @ ` prefix, parse its
ISO-8601 timestamp and check it against the test's bounded start/end interval
with one second of rounding tolerance. Do not replace the production decoder
or formatter with a prebuilt result string.
`other_unavailable_commands` counts other CoreBluetooth commands attempted
while the manager is unavailable. `closing` means a sent or immediately
pending disconnect is awaiting an applicable boundary; `quarantined` means
the required boundary cannot presently be established and no retry is
submitted. `inner_admission=denied` means the
operation attempted at the specified checkpoint does not reach the physical
adapter. For `pending-nil`, `pending-same`, and `pending-alert`, also assert
the original continuation is resumed once with permission-changed failure and
its timer is cancelled. For `radio-off`, the original continuation fails once
with the existing Bluetooth-unavailable failure and no CoreBluetooth command
is sent while unavailable.

| Scenario | Required actions and checkpoints |
| --- | --- |
| `read-grant-revoke`, `read-revoke-grant` | Start A read false/true respectively. Outer sets it true/false; notification sets it false/true. |
| `alert-grant-revoke`, `alert-revoke-grant` | The corresponding two interleavings for A alert. |
| `cross-fields` | Outer enables A read; notification enables A alert. |
| `both-read-revoke`, `both-alert-revoke` | Outer enables both A grants; notification revokes only the named field. |
| `cross-device-grant` | Outer enables A read; notification enables B read. |
| `cross-device-revoke` | Initially B read is true; outer enables A read and notification revokes B read. |
| `alert-revoke-admission` | Initially A alert is true. Outer revokes it; notification invokes the public alert operation, which must be denied with zero adapter writes. |
| `alert-grant-admission` | Outer enables A alert. Notification's public alert is denied; after the enable commits, one explicit alert reaches the adapter once. |
| `other-write-revoke` | Initially A read is true. An unrelated real device-field update notifies; its observer revokes A read. The outer update must not restore read. |
| `clear-during-grant` | Outer enables A read; notification invokes the real disconnect operation. It submits one cancellation request, old grants cannot be restored and A is closing. |
| `retry-after-barrier` | A previously connected owner is closing. Inside its actual disconnect callback request reconnect and assert no connect submission. After that callback returns and the local owner reaches idle, issue a new explicit connect; it is submitted once under a new owner with both grants false. |
| `cancel-pending-connect` | Setup has already submitted A's first connect and A is connecting. After counters reset, cancel it. A later ambiguous connect callback must not authorize or start discovery and causes a second cancellation request; a further connect is denied while the attempt remains quarantined. |
| `radio-off`, `radio-reset` | A and B both have both grants; A has one pending read. Simulate the named manager unavailability, attempt scan/stop, discovery, Link and standard operations while unavailable, then power on without a confirmed boundary. Both devices are quarantined and grants revoked, the old read fails once, no unavailable command is sent, and a new attempt is denied. A reset invalidates both old peripheral objects. |
| `pending-nil`, `pending-same`, `pending-alert` | A has both grants and one pending read. Call `grant` with nil/nil, read=true, or alert=false respectively. The captured read fails once and the owner closes. |
| `stale-timer-new-owner` | In setup, fail the old pending read, process an applicable disconnect boundary, explicitly reconnect and authorize A read, then start a new pending read. Assert each step and the old continuation's single failure, then reset submission counters. Deliver the old application's captured timer/cancel callback: the new read remains pending and its owner is not disconnected. This token is app-local, not an OS callback field. |
| `notification-ambiguous` | A read grant is true but the characteristic was subscribed during this owner; the read is denied before physical submission. |
| `timeout-no-barrier` | A closing owner receives only a local timeout and no applicable disconnect boundary. A new connect remains denied. |
| `idle-grant-connect-clear` | A is idle with both grants explicitly set. Accept a new connect; before any physical connect submission, both old grants are false. The new owner is connecting and submits one connect. |
| `connecting-grant` | A is connecting. An explicit new read grant is recorded for that owner, but a read attempted before connection and rediscovery is denied without physical submission. |
| `cancel-before-connect-submit` | A connect starts from idle; a synchronous observer requests disconnect before the physical connect is submitted. End that unsent attempt locally without a connect or disconnect submission. |
| `read-revoke-admission` | Initially A read is true. The outer call revokes it; the notification exercises the synchronous admission boundary used by the real async read and is denied before any adapter read. |
| `new-pending-during-grant` | A read is true and no read is pending at entry. The outer call enables alert; its notification installs a new actual read continuation through the same production pending transition and submits one fake read. The earlier grant must not cancel that later read or disconnect its owner. |
| `grant-during-closing` | A is closing. A new positive grant is refused, both grants stay false and the unavailable state is displayed. |
| `connect-cancel-didfail` | A submitted connect is cancelled, then a failed-connect callback arrives without a proven boundary for the old attempt. A remains quarantined and a new connect is denied. |
| `notification-unknown` | A read grant is true, but the store cannot establish that the characteristic was never subscribed during this owner. Read admission is denied without adapter submission. |
| `pending-timeout`, `pending-cancel` | A has both grants and one submitted pending read. Trigger its real local timeout or caller cancellation. The captured continuation fails once with the existing timeout or cancellation error, both grants are revoked, one old disconnect is requested and A closes. A new read and connect before a boundary are denied. |
| `unexpected-central` | A new owner is connected with both grants. Deliver an extra `didConnect` for that same connected peripheral without inventing an OS token. The store fails closed, revokes grants, requests a disconnect and reports unavailable. Then actually attempt both connect and read; neither reaches the adapter. An event indistinguishable from a valid event is not thereby classified as old. |
| `unknown-characteristic` | A has both grants and one submitted pending read. Deliver a value callback for a different, unassignable characteristic without inventing an OS token. The pending read fails once, both grants are revoked, one disconnect is requested and A is unavailable. Then actually attempt both connect and read; neither reaches the adapter. |
| `new-connect-discovery` | A's prior confirmed disconnect boundary is complete and a new attempt is connecting. Deliver the new attempt's applicable connection event; the real transition submits one service discovery, remains unauthorized, and marks the local owner connected. |
| `link-event-while-read` | A has an authorized standard read pending and an active Link channel. Deliver a valid current-owner Link TX event through the real shared dispatch and channel reassembler; the real channel delivers that event once, the standard read and its timer remain pending, and the connection is not cancelled. A truly unknown characteristic still follows `unknown-characteristic`. |
| `link-event-while-closing` | In setup, A has an active Link channel and a pending standard read, then a grant ends that read and begins closing. Assert its single permission-changed failure, then reset submission counters. Deliver a late Link TX event before the disconnect callback returns: no Link event is delivered, no grant or read is restored, and no new command is sent. |
| `duplicate-closing-grant` | A is closing. Refuse a positive grant, then install a fresh observer and repeat the same request. It remains unavailable, sends no command and does not recursively notify for a no-effect repeat. |
| `cancel-before-value`, `value-before-cancel` | A has one submitted read. Arrange the local cancellation claim before an otherwise eligible controlled value callback, or the value completion claim before cancellation, respectively. The former fails once and closes; the latter completes once with the expected value and later cancellation cannot replace it. Neither order assigns an app token to an OS event. |
| `cancel-before-grant`, `grant-before-cancel` | A has one submitted read. Arrange the named first local outcome claim, then the other event before cleanup completes. The winner's existing error is retained, the read resumes once and the old owner closes once. |
| `cancel-before-radio-off` | A has one submitted read. A background caller claims cancellation; before main-actor cleanup runs, the manager becomes unavailable. Retain cancellation as the outcome, revoke both devices as for radio-off, and issue no unavailable CoreBluetooth command. |
| `value-before-timeout` | A's eligible value completion wins; before a new read is started, deliver the old local timeout callback. The value remains the outcome, the old timer is cancelled and the old timeout does not close the owner. |
| `cancel-before-read-reserve`, `cancel-after-read-reserve` | Cancel from a background caller at a controlled point before, or after, the local submission reservation but before the fake adapter submits. Before reservation, no read or disconnect is submitted and the current owner remains usable. After reservation, the read may have been submitted: the test suppresses the not-yet-issued fake call, but the owner still closes and requests disconnect. Both cases return cancellation once. |
| `natural-disconnect-barrier` | A is the sole current connected owner, with auto-reconnect disabled. Deliver its natural disconnect. During its callback an explicit connect is denied; after the callback returns and the boundary is applied, a new explicit connect is submitted once with both grants cleared. |
| `idle-radio-off-on`, `idle-radio-reset` | A and B are idle and no connection attempt has been submitted. Turn the manager off or reset it, then power it on; in the reset case rediscover A as a new valid peripheral. No command is issued while unavailable; a subsequent explicit connect for A is submitted once, with no old grants. |

For `retry-after-barrier`, record a checkpoint inside the disconnect callback
before it returns and a second checkpoint after it returns; neither a queued
callback nor a fake that accepts an app token substitutes for the real store
transition. For `stale-timer-new-owner`, inspect both old and new continuations
and timers: the old one finishes once, while the new one remains unresolved
until the test explicitly cleans it up. The fixture does not claim that a
CoreBluetooth value callback identifies which physical read produced it.
Because a synchronous Observation callback cannot await `read`, an
inside-notification read-admission case must exercise the same synchronous
admission boundary called by the real `read`; scheduling an async task only
after the callback returns is not evidence for that checkpoint. The public
`alert` method is synchronous and is exercised directly in its cases.
`new-pending-during-grant` exercises the same synchronous pending/admission
transition called by the real public async read with a pre-captured real
continuation. Separate allowed and denied public async `read` tests must
verify that wiring; directly mutating a test pending field is insufficient.
For `cancel-before-value` and `cancel-before-radio-off`, while the main actor remains in a controlled
synchronous test callback, cancel the real read task from a background thread
and wait only for that cancellation call to return, with a bounded timeout.
Deliver the eligible value or manager-unavailable event respectively before
allowing any queued main-actor cleanup to run; this proves the cancellation
claim is not merely a later actor task.
In the reservation cases, use a controlled test barrier immediately before
or after the real production submission reservation, cancel from another
thread, then resume the actor; no synthetic OS request token is introduced.

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
the callback succeeds. A matching response before the final segment has been
sent is a protocol violation: close the channel and retain an unknown outcome.
Mismatched IDs and unexpected opcodes do not complete the request. Link NAK
0xff with the current ID is a terminal explicit NAK; a HELLO NAK also closes
the channel and requests disconnection. Matching 0x6c/ID 0 is a separate
best-effort event after handshake, not a response.

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
