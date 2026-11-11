# Android device-capability port plan (waves 2–3)

Status: **plan**. This file changes no contract, schema, golden, wire format, persisted key or code.
It tells wave-2/wave-3 implementers what to build on Android, in what order, against which
authority, and what evidence is required before any status word moves.

Owner: wave-1 planning worker W1-04 (P07 device capabilities). Implementers and reviewers are named
per checkpoint; the contract owner remains the only editor of `spec/**`.

Base: branch `feat/android-parity` at `56e7b6ce`, worktree
`dsh/20261111-200540/03-04-device-port-plan`. Numbers in this file are line counts measured at that
head with `wc -l`, unless marked *estimate*.

Protocol impact: **P07, P05, P08, P06, P18, P09** are all discussed as future work. This file itself
declares no impact: it is a document under `docs/design/`, no other path changes. (The task handoff
states this again in the AGENTS.md §3.5 form.)

Related: [roadmap](../parity/android-parity-roadmap.md), [lessons](../parity/lessons.md),
[protocol baseline](../../spec/README.md) §3/§7,
[BLE Link profile](../../spec/device/v1/ble-link.md),
[Android standard GATT](../../spec/device/v1/android-standard-gatt.md),
[Android BLE discovery](../../spec/device/v1/android-ble-discovery.md),
[BLE secure session](../../spec/device/v1/ble-secure-session.md),
[device tasks](../../spec/device/v1/task-delegation.md),
[LAN MCP](../../spec/device/v1/lan-mcp.md),
[TonoLink board](../../spec/device/v1/tonolink-board.md),
[cloud voice](../../spec/v1/cloud-voice.md),
[iOS audio ownership](../../spec/platform/ios-audio-session.md).

---

## 1. Summary and decisions

### 1.1 Capability disposition

| # | Capability | iOS consumer (LOC) | Owning contract, status at this head | Android today | Disposition | Wave |
| --- | --- | --- | --- | --- | --- | --- |
| A | BLE connection ownership, trust, reconnect (GAP-20) | `BLEDeviceStore` 2,435 + `BLEDeviceTrustMemory` 57 + `StandardBLE` 61 | `ble-link.md` rule 6, `implemented`, **but scoped "(iOS App)"**; `android-standard-gatt.md` `implemented` for the read/alert slice only; GAP-20 open | scan + standard GATT reads + one no-response alert write; no Link, no trust memory, no reconnect, no bonding | **Port, after a contract freeze.** Its spec is *not* ready today (§2) | 2 |
| B | PDSH Link (ordinary tools profile) | `PDSHLink` 188 + `BLELinkChannel` 101 + `HomeHTTPPolicy` 50 + `LinkToolJournal` 50 | `ble-link.md` `implemented`; Android decoder/channel registered as `target` (§"Android decoder registration", "Android Link channel target") | Kotlin codec + channel state machine (304 + tests), driven by the four shared goldens; **no GATT adapter, no client, no tools** | **Port.** Wire half already done; the adapter is the GAP-20 work | 2 |
| C | BLE authenticated task session (`secure-session-v2.1`) | `SecureSession/**` 4,104 | `ble-secure-session.md` **`target`**, nothing enabled, GAP-16 | none | **Port in wave 3**, not enabled until §14 acceptance on both ends | 3 |
| D | Device tasks (Link legacy + secure binding + LAN inbox) | `PhoneDSHDeviceTasks` 2,130 | `task-delegation.md` **`target`**; BLE binding depends on C | `PhoneDSHDeviceTasks` maps to **nothing** (`android-module-map.json`: `status: absent`) | **Port after B and C.** Android Link task binding is permanently refused by firmware (ble-secure-session.md §11) | 3 |
| E | TonoLink voice turn + CloudVoice | `TonoLinkVoice` 97, `TonoLinkCtrlBLE` 304, host 510; `CloudVoice` 432 | `tonolink-board.md` `implemented` (iOS consumer only; §4.1 `partial`), `cloud-voice.md` `partial` (iOS consumer only) | none; no consumer, no ctrl adapter, no cloud speech client | **Port.** The only TonoLink half that is a real Android capability gap | 2 (JVM halves) / 3 (platform) |
| F | TonoLink screen (APV1), phone-hands (HID gestures), USB OTA, DEBUG relay | `TonoLinkScreen` 496, `TonoLinkPhoneHands` 273, `TonoLinkUSBOTA` 264 + `TonoLinkUSBOTAProtocol` 307 + `TonoLinkUSBTransport` 174, `TonoLinkRelay` 315 + `TonoLinkPortForward` 183 + `TonoLinkBLEDebug*` 304 | `tonolink-board.md` §1–§6 (board is AirPlay receiver + Bluetooth HID; relay is DEBUG-only, no authentication) | none | **Do not port the screen/HID paths as-is; USB OTA is conditional; relay is not ported.** Reasons in §3.6 | — |
| G | UI-Venus agent (`iphone_agent_run`) | `PhoneDSHVenus` 1,001 + host 405 | `native-mcp.md` "iPhone agent tool (implemented on iOS)"; `tonolink-board.md` §6 | Android already operates its own UI through `android_*` ADB tools on the same native MCP endpoint | **Do not port.** `spec/platform/whitelist.json` already records this capability as `os-forced` | — |
| H | LAN MCP | `PhoneDSHLAN` 168 | `lan-mcp.md` `implemented`; Android explicitly `partial`; pin trust model `target` | strict mDNS querier + shared decoder wired to the MCP page (partial, per PC-20261108-android-lan-mdns) | **Finish the wiring**, not the discovery. Blocked by P13/P18 outside this scope | 2 (tests) / 3 (authorization) |

"Wave" is the roadmap's wave number; §4 fixes the execution order inside each wave.

### 1.2 Decisions

**D1 — GAP-20 is not spec-ready, so BLE trust/reconnect is not the first *code* checkpoint.**
The first checkpoint is a contract freeze (C0). Evidence and the exact test are in §2. The roadmap's
"wave 2: BLE trust/reconnect (GAP-20)" is kept as the wave-2 *theme*, but its order inside wave 2 is
transport → Link → trust, because a "trusted Link tool" cannot be exercised before the Link channel
exists, and the Link channel cannot be built before the write-ownership model is frozen.

**D2 — TonoLink voice, not the rest of TonoLink, is the portable capability.** The voice turn talks to
the ctrl GATT service, not to the Link profile, so it does not depend on GAP-20. Its wire contract and
judge fixture (`golden/tonolink-voice.json`) are frozen. It is therefore the only device capability
that can be implemented in wave 2 in parallel with the BLE transport work. The screen path depends on
AirPlay mirroring (no Android sender); the HID path is a phone-control mechanism Android already has
through ADB; the relay is a DEBUG-only unauthenticated listener. UI-Venus is already recorded as
`os-forced` with the ADB tools as the Android mechanism.

**D3 — Nothing in waves 2–3 moves a status word to `implemented` on Android without the evidence the
owning spec names.** `target` stays `target`; `partial` stays `partial` until the named missing piece
exists. The port plan itself is not evidence.

**D4 — Android task grants stay off until the secure session's §14 acceptance exists on both ends.**
This mirrors the iOS rule (`BLEDeviceStore.grantDeviceTasks` refuses unless the package is built with
`PDSH_ENABLE_DEVICE_TASKS`, and even then only admits a live secure lease). Android must not grow a
plaintext task path "to test the rest"; the firmware refuses it permanently (ble-link.md §"协商" lines 29–30,
`golden/ble-task-plaintext-admission.jsonl`).

**D5 — LAN MCP's remaining Android gap is not in `lan-mcp.md`.** Discovery and decoding are done and
tested. What is missing is the MCP page's *save path* — the remote-call mechanism already exists
(`DshTurnClient.call`, used by `HostAutomation` for `phone/createSchedule`) — plus a host-managed
credential/grant store (the iOS path is `MCPSettingsModel` → `transport().call("phone/mcpUpsert", …)`
→ Keychain grant). That is P13/P18 work; see §7. The pin trust model (`lan-mcp.md` §"TLS trust
model") is `target` for every phone end and is not required for OS-trust parity.

---

## 2. Is GAP-20's spec ready? (ordering test)

The task asked to put BLE trust/reconnect first **if its spec is ready**. It is not. The test below is
deliberately mechanical so a later reader can re-run it at another head.

| Test | What must be true | Evidence at `56e7b6ce` | Verdict |
| --- | --- | --- | --- |
| T1 owning clause | A normative clause defines the behaviour **for Android** | `ble-link.md` rule 6 is titled `6. **受信任的已连接设备（iOS App）。**` (line 86). Its body names `UserDefaults` keys (`phone-dsh.ble.revoked-grants.v1`, `phone-dsh.ble.remembered-boards.v1`), CoreBluetooth callbacks (`didConnect`, `retrievePeripherals`) and says the library default is `trustConnectedDevices = false`. `native-mcp.md` §"BLE tools" repeats "the iOS app trusts a board the user connected". No clause defines an Android trust record, its keys, or its value format. | **No** |
| T2 required CCR | GAP-20's own close condition says to freeze the callback ownership, permission and security semantics first | `spec/README.md` GAP-20: "按 [CCR] … 凍結可驗證的回調歸屬、權限及安全語義；實際 Android adapter 與通道共同覆蓋陳舊/重複回調、失敗和斷線，並以真機證據驗證後才關閉". That CCR, `PC-20261107-android-gatt-ccr.md`, is `status: draft`, `contract_revision: pending`, and `version_decision: pending — no Android GATT transport is approved or connected`. | **No** |
| T3 shared fixtures for the behaviour | The trust/reconnect decisions have a shared fixture both ends run | The only Android BLE goldens are `android-ble-discovery.jsonl`, `ble-scan-intent*.jsonl`, `standard-gatt-{decode,status-order,grant-order,discovery-*,service-change}.jsonl`, `android-link-channel.jsonl`. None models remembered boards, revocations, default-allow, present-only reconnect, or quarantine-across-restart. `android-link-channel.jsonl` is a wire state machine whose write token is *supplied by the test*, not by the OS. | **No** |
| T4 transport prerequisite | An Android GATT **write-with-response** adapter exists | `AndroidBleDevices.kt` implements reads and one `WRITE_TYPE_NO_RESPONSE` alert write (line 293–304); its own comment says "No Link channel, task, identity, bonding or agent tool lives here (GAP-20 keeps those `target`)". AOSP `BluetoothGattCallback.onCharacteristicWrite` carries `(BluetoothGatt, BluetoothGattCharacteristic, int status)` — no value, no request token (verified in `android-14.0.0_r20`, see §5.6). | **No** |

**Conclusion.** BLE trust/reconnect is **not** first as code. C0 (contract freeze) is first; then the
GATT write adapter (2A.1), then Link (2A.2), then trust/reconnect (2A.3). This is not a rejection of
the roadmap's priority — it is the same priority with its real prerequisite made explicit.

What *would* change the answer: a frozen revision of `ble-link.md` that (a) adds an Android clause
with its own storage format, and (b) freezes `PC-20261107-android-gatt-ccr` into an adapter ownership
model. Even then, 2A.3's *Link-tool* half still needs 2A.1/2A.2; only the pure trust/reconnect state
machine could be written earlier, and it could be written in parallel once C0 lands. If the contract
owner freezes both before wave 2 starts, implementers may run 2A.3's JVM half concurrently with 2A.1
and should say so in their handoff; the checkpoint order below does not change.

---

## 3. Capability plans

Every subsection uses the same shape: iOS implementation → spec coverage and Android status quotes →
Android platform constraints → what Android already has → missing spec deltas → checkpoints. Shared
platform material (permissions, API levels, Doze, foreground services, bonding, audio) is in §5 and is
only referenced here.

### 3.1 BLE connection ownership, trust and reconnect (GAP-20)

#### 3.1.1 iOS implementation

| File | LOC | Role |
| --- | --- | --- |
| `Sources/PhoneDSHBLE/BLEDeviceStore.swift` | 2,435 | the whole page store: scan intent, connection owner/generation, discovery ledger, read claim, grants, trust application, remembered reconnect, Link installation, secure-session transport (`selectSecureDevice`, `openSecureStream`), identity proof, task grant admission, Link invoke/query |
| `BLEDeviceTrustMemory.swift` | 57 | the two persisted maps: revoked names per key, remembered peripheral UUID → display name |
| `StandardBLE.swift` | 61 | allowlisted SIG profiles, strict decoders, `alertCommand` |
| `BLEIdentity.swift` | 143 | legacy TOFU `ble:` label (`target`, GAP-16; not authentication) |

State machine, in the order the code enforces it:

- `Owner.Phase = idle → connecting → connected → closing → quarantined`. One `Owner` per peripheral
  UUID; each accepted `connect` makes a new one and clears the previous read/alert declarations.
- Every deferred effect carries a non-reusable `Revision` (status text, scan intent, read/alert
  versions, identity, channel installation, disconnect). A stale callback whose revision is no longer
  current is dropped. `close()` reserves the closing phase and detaches continuations *before* any
  observable notification.
- Deadlines: scan 15 s; connect + service discovery 20 s; read 10 s; closing → quarantine 20 s; secure
  PSM read 10 s; CoC open 15 s.
- `closing` means "a disconnect was submitted and we are waiting for the disconnect callback to
  return". `quarantined` means "the boundary cannot be established" — no reconnect, no read, no Link,
  until the app restarts. This is what a blind reconnect buys you, and why the reconnect policy is
  present-only.
- Discovery: one service request per connection, one characteristic request per selected service
  object, an immutable snapshot per completed callback, duplicate-snapshot no-op, nil-array =
  uncertain, changed result = quarantine.
- Trust (only when `trustConnectedDevices = true`, which the app sets at launch):
  connect = trust. After `tools/list`, `grantedTools = advertised − revoked(deviceID)`; a user switch
  writes a revocation; `rememberBoard` records the peripheral. Standard read/alert are allowed by
  default and stored as `@read`/`@alert` revocations keyed by peripheral UUID.
- Reconnect: `reconnectRemembered()` at launch → `autoConnectIDs` + `scan()`. On disconnect,
  `scheduleRememberedReconnect` watches 3 s × 20 then 15 s × 20 (≈ 6 min) and submits a connect only
  when `rememberedBoardIsPresent(systemConnected:advertised:)` is true **and** the peripheral is
  `.disconnected`; a system-owned connection is not adopted (GAP-37). `forgetAndDisconnect` removes
  the memory first.

#### 3.1.2 Spec coverage and what it says about Android

- Owning clause: `ble-link.md` rule 6 — iOS-only, full text quoted in §2/T1.
- `android-standard-gatt.md:6–9`: "This slice … does **not** implement or claim the PDSH Link channel,
  Link tools, device tasks, device identity, pairing/bonding, agent tool exposure or any write that
  needs a GATT response. GAP-20 (per-write callback ownership and link-security evidence) stays open
  and keeps all of those `target` on Android."
- `android-standard-gatt.md:39–41`: "Android does not initiate bonding. A peripheral that requires an
  encrypted link fails its read with an insufficient-authentication/encryption status, which is shown
  as a read failure, not as success."
- `android-standard-gatt.md:45–48`: the two switches "default to off and reset on every new
  generation"; "On Android they gate only the manual buttons on this page; no agent tool is exposed, so
  the page states that agent access is not available on Android."
- `ble-link.md:95` still says "Android standard GATT remains target." — **contradicts**
  `android-standard-gatt.md:3` (`implemented`). CCR-2 in §6.
- `spec/README.md` GAP-20 (quoted in §2/T2) and GAP-37 (system-connected remembered board is not
  adopted; owner P07, open).

#### 3.1.3 Android platform constraints

Detailed matrix in §5. The ones that shape this capability:

- **No write callback identity.** `BluetoothGattCallback.onCharacteristicWrite` gives no token and no
  bytes; API 33 added value-carrying overloads for *read* and *notification*, not for write. A delayed
  or duplicate callback for an earlier write to the same characteristic cannot be distinguished from
  the current one. This is GAP-20 and it is not an implementation detail — it must be a frozen rule.
- **One GATT object per connection, one operation at a time.** `BluetoothGatt` serialises operations
  (`mDeviceBusy`); a second `writeCharacteristic` returns false. That helps ordering but does not
  label callbacks. `gatt.close()` releases the client; a late callback after close is a real-world
  hazard the adapter must fail closed on.
- **Bonding is not initiated today.** The reference firmware wants an encrypted + bonded link for the
  ordinary Link path. Android will auto-start pairing when an access needs encryption, but the app
  must handle `ACTION_PAIRING_REQUEST` (PIN/passkey) and `ACTION_BOND_STATE_CHANGED`; bond state is not
  proof of current link encryption (GAP-20 says the public encryption-status API is not available
  across minSdk 26). So "bond before Link" is a policy decision, not a checkbox.
- **Reconnect.** `connectGatt(..., autoConnect = true)` lets the controller reconnect when the device
  advertises again, but the app cannot observe "present" before the connection, and the callback
  discipline differs from `autoConnect = false`. The present-only rule of rule 6 has no direct
  Android analogue; the spec delta must choose between (a) scan-gated explicit connect, mirroring iOS,
  or (b) `autoConnect = true` with a documented loss of the present gate.
- **Background scanning.** Unfiltered scans are suspended with the screen off / in Doze; an app cannot
  start a foreground service from a scan result on Android 12+. A remembered-board reconnect that
  relies on scanning only works while a foreground service or a visible page holds the process (§5.3).
- **Addresses.** `BluetoothDevice.getAddress()` is not a stable key on modern Android (randomised
  addresses; the platform may return a placeholder). Rule 6 keys standard grants by *peripheral UUID*,
  which is an iOS concept. Android must key by its own opaque scan id or by the Link device ID; this is
  part of the delta, not something to improvise.

#### 3.1.4 What Android already has

- `:domain` scan state machine and coordinator (`BleScanMachine`, `BleScanCoordinator`,
  `BleScanSource`/`BleScanSession`), already implementing `android-ble-discovery.md` with process-wide
  quarantine and host/page leases; JVM tests in `:app`.
- `AndroidBleDevices.kt` (377 lines): connect/discover/read/alert, generation check per `BluetoothGatt`,
  20 s connect deadline, 10 s read, expired read closes the generation, grants reset per generation —
  the `android-standard-gatt.md` slice.
- `StandardBleProfile.kt` (81) + `standard-gatt-decode.jsonl` consumer.
- `AndroidBleScan.kt`, `BlePermissionRegistry.kt`, manifest permissions for API 26–35.
- No bond handling, no Link, no trust memory, no reconnect, no native `ble_*` tools.

#### 3.1.5 Missing spec deltas

| ID | Delta | Owner | Blocks |
| --- | --- | --- | --- |
| D-1 | Android clause for trusted connected devices: keys, value format, default-allow, revocation, remembered-board presence rule, reconnect window, no-adopt rule, and whether a system-connected board is adopted | P07 contract owner (CCR-1) | 2A.3 |
| D-2 | Freeze the GATT adapter ownership model: callback attribution (what a duplicate/stale callback may do), descriptor-write ownership for the two notification subscriptions, bonding policy for the encrypted firmware, and the allowed security claim | P07/P08 owner (CCR-3 = the existing draft CCR) | 2A.1, 2A.2 |
| D-3 | Shared fixture for the trust/reconnect state machine (Android-relevant fields only; no iOS object identity). Proposed name `spec/device/v1/golden/android-ble-trust.jsonl`, registered in `spec/tools/cross_check.py` | P07 owner + gate owner | 2A.3 tests |
| D-4 | Delete or narrow `ble-link.md:95` "Android standard GATT remains target" | P07 owner (CCR-2) | 2A.1 status claims |
| D-5 | Record that `legacy-identity-preferences.md` (UserDefaults, iOS-only legacy data) is not applicable on Android and creates no key | P07/P18 owner | 2A.3 review |

#### 3.1.6 Checkpoints

The **Device?** column uses: `no` = JVM/unit-testable, `partially` = JVM half plus a
device row that must be recorded `NOT_RUN` until run, `yes`/`must` = device-only evidence (a JVM pass
does not satisfy it). Estimates are Kotlin production + test lines, from the iOS size and the existing
Android modules; they are planning ranges, not commitments.

| ID | Content | Owned paths | Fixtures / goldens | Acceptance command | Est. (prod + test) | Device? |
| --- | --- | --- | --- | --- | --- | --- |
| **C0** | Contract freeze packet: CCR-1, CCR-2, CCR-3 + D-3/D-5 records. No code | `spec/device/v1/ble-link.md`, `docs/protocol-changes/PC-…` (owner only) | new `android-ble-trust.jsonl` + schema; registry row updated | `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | doc-sized (≈ 150–250 lines of contract) | no |
| **2A.1** | GATT write adapter + connection generation + callback quarantine on top of the existing standard slice: write-with-response, per-generation token ledger, descriptor writes, disconnect/close boundaries, MTU request | `android/app/src/main/kotlin/com/phonedsh/probe/AndroidBleGatt.kt` (new), `AndroidBleDevices.kt` (extend); pure ownership ledger in `android/domain/.../connector/ble/BleGattOwnership.kt` (new) | new adapter cases; reuses `android-link-channel.jsonl` only through 2A.2 | `bash android/tools/with-android-toolchain.sh ./gradlew --no-daemon :domain:testDebugUnitTest :app:testDebugUnitTest`; `bash scripts/ci/check.sh --only phone-android-tests` | 700–1,000 + 500–700 | **yes**: duplicate/stale callback, disconnect, bond behaviour cannot be proven on JVM (mark NOT_RUN) |
| **2A.2** | Link client over the adapter: hello, `tools/list`, upload/commit/result, `home.http` policy, events, 3 s per-exchange deadline, no auto-retry | `android/domain/.../connector/ble/BleLinkClient.kt` (new), `HomeHttpPolicy.kt` (new, JNI to the vendored C or a Kotlin port with the same vectors — see §7), `android/app/.../AndroidBleLink.kt` (new) | `xiaozhi-ctl.jsonl`, `pdsh-link.jsonl`, `invalid-ctl.jsonl`, `android-link-channel.jsonl`, `ble-task-plaintext-admission.jsonl` (negative: must never send task tools) | `:domain:testDebugUnitTest` (codec/channel) + `:app:testDebugUnitTest` (adapter orchestration) | 600–900 + 400–600 | partially (fake adapter on JVM; real radio NOT_RUN) |
| **2A.3** | Trust memory + remembered boards + reconnect policy, after rule 6's Android clause exists | `android/domain/.../connector/ble/BleTrustMemory.kt` (new, storage seam), `android/app/.../AndroidBleTrustStore.kt` (new, SharedPreferences), `AndroidBleDevices.kt` (apply/defaults) | new `android-ble-trust.jsonl` (D-3) | `:domain:testDebugUnitTest`, `:app:testDebugUnitTest` | 400–600 + 300–500 | partially (reconnect timing/presence on device NOT_RUN) |
| **2A.4** | Native MCP `ble_devices`, `ble_read`, `ble_alert`, `ble_link_tools`, `ble_link_call`, `ble_link_result` on Android's existing endpoint | `android/app/.../AndroidBleHost.kt` (new, composes `AdbMcpServer` like iOS `DeviceMCPServer` composes `ADBMCPServer`), `ProbeEngineViewModel` nativeMcp wiring | `spec/v1/golden/native-mcp/ble-devices.json` (new consumer) | `:app:testDebugUnitTest`; `bash scripts/ci/check.sh --only phone-android-tests` | 500–700 + 300–500 | no (JVM), plus one device smoke |

Exit criteria for 3.1: the Android page can connect, read, alert, open Link, list and call a granted
tool, remember the board, reconnect only when present, and never report a submitted write or alert as
executed. GAP-20 stays open until a real Android phone + reference board run covers stale/duplicate
callbacks, failure and disconnect, as its close condition requires.

---

### 3.2 PDSH Link (ordinary Link tools profile)

#### 3.2.1 iOS implementation

| File | LOC | Role |
| --- | --- | --- |
| `PDSHLink.swift` | 188 | service UUIDs, envelope encode/decode, ATT segmentation/reassembly, HELLO/HELLO_ACK negotiation, `PDSHLinkClient` (`handshake`, `invoke` = upload chunks → commit → poll `query`, `query`), `LinkNotExecuted`, event identity/sequence |
| `BLELinkChannel.swift` | 101 | CoreBluetooth transport: one outstanding exchange, 3 s deadline, write-with-response chaining, NAK/timeout/cancel → fail + `onFailure` (the store disconnects) |
| `HomeHTTPPolicy.swift` | 50 | `home.http` args validation through the vendored C policy (`xl_home_policy.c`), private-IPv4 only, origin allowlist |
| `LinkToolJournal.swift` | 50 | receipt directory + idempotency journal for `ble_link_call` |
| `DeviceMCPServer.swift` | 171 | six `ble_*` native MCP tools in front of the ADB server |

State machine: `envelope → segments(writeLimit)`; `HELLO(0x01)` with app cap bit10 and **not** bit11;
HELLO_ACK must confirm bit20 + the `PDSH` tag + version 1 + max_rpc 4096; request IDs 1…65535 once per
connection; one request in flight; response may arrive before the last write callback (retain, then
complete after the callback); a response before the final segment is sent = violation → close with
unknown outcome; 0xff NAK is terminal; 0x6c/0 events only after handshake; timeout/cancel/transport
error/malformed frame/disconnect → terminate, clear reassembler, ask the adapter to disconnect, remote
outcome unknown; never resend.

#### 3.2.2 Spec coverage and Android status

- `ble-link.md:712–714` "Android decoder registration": "The Android Link wire decoder, encoder and
  segment reassembler are a `target` implementation of this unchanged profile. They must consume the
  same `golden/xiaozhi-ctl.jsonl`, `golden/pdsh-link.jsonl` and `golden/invalid-ctl.jsonl` … This
  registration does not claim Android GATT discovery, pairing, authorization, task intake or device
  runtime support."
- `ble-link.md:716–726` "Android Link channel target": "A future adapter must supply a new connection
  generation and confirm both notification subscriptions before starting the channel. It must deliver
  each write callback with the generation and the identity of the exact outstanding write; stale
  callbacks cannot advance a newer connection or a later write."
- `ble-link.md:753–757`: "The state machine has no timer of its own: its owner supplies a monotonic
  timeout event; its eventual adapter must enforce the existing Swift three-second per-exchange
  deadline. … This target is not wired to a user feature until an actual GATT adapter, authorization,
  persistence and runtime evidence are available."
- `ble-link.md:91–95` (iOS ordering amendment) ends with "Android standard GATT remains target." (CCR-2).

#### 3.2.3 Android platform constraints

- Write limit: `BluetoothGatt` writes are `MTU − 3`; default MTU 23 → 20 bytes until `requestMtu(247)`
  succeeds (`onMtuChanged`). The channel takes a `writeLimit`, so a small MTU is correct-but-slow; the
  adapter should request 247 once per connection and accept whatever the OS grants.
- Notifications: `setCharacteristicNotification` + a descriptor write to the CCCD; the channel's
  `open(txSubscribed, audioSubscribed)` requires both confirmed. Descriptor writes have the same
  no-token callback problem as characteristic writes (§5.6).
- `home.http`: the iOS side calls the vendored C policy; Android has no binding. Either add a JNI
  binding to the same C (preferred: one authority) or port and validate against the same upstream
  policy tests plus new shared vectors — a decision for P12/P07 owners (§7).
- No `CBPeripheral.maximumWriteValueLength`; use `requestMtu` + `onMtuChanged`.
- The app must not treat a successful `writeCharacteristic` return as delivery; only the callback is.

#### 3.2.4 What Android already has

- `BleLinkCodec.kt` (146): envelope, CRC-16/CCITT-FALSE, segmentation, reassembly, HELLO/HELLO_ACK,
  `Peer`. Its tests read all three shared ctl vectors plus the 12-row `android-link-channel.jsonl`
  through the real codec.
- `BleLinkChannel.kt` (158): target state machine with generation, write tokens, `unknown` on failure,
  `Disconnect` effect, one outstanding request, NAK handling, response-before-write-ack handling.
- **Not present**: any use of these from the app (`internal` visibility), the client (upload/commit/
  result), `home.http` policy, the six MCP tools, persistence of tool intents, trust.

#### 3.2.5 Missing spec deltas

None for the wire profile: it is frozen and Android is registered as `target`. The missing piece is
the adapter contract (D-2/CCR-3) and the `home.http` policy binding decision (P12, §7 item 3).

#### 3.2.6 Checkpoints

The Link work lives inside **2A.2** (§3.1.6); the sub-checkpoints below are the reviewable units. All
of them are JVM-testable through the real codec/channel; none of them proves the adapter's callback
attribution (that is 2A.1's device run).

| ID | Sub-checkpoint | Path | Fixture | Acceptance | Est. | Device? |
| --- | --- | --- | --- | --- | --- | --- |
| L-1 | HELLO/HELLO_ACK: app cap bit10 only, device bit20 + tag + version + max_rpc; legacy ACK keeps ordinary Link but rejects 0x54–0x56; NAK closes | `:domain/.../ble/BleLinkClient.kt` | `android-link-channel.jsonl`, `invalid-ctl.jsonl` | `:domain:testDebugUnitTest` | 150–250 | no |
| L-2 | Upload/commit/result: 4096-byte request, 15000 ms default TTL, no auto-retry, conflict (5) = query only, state machine of `state` 0/1/2/3 | same | `pdsh-link.jsonl`, `xiaozhi-ctl.jsonl` | `:domain:testDebugUnitTest` | 200–300 | no |
| L-3 | `home.http` arguments through the shared C policy (JNI) or a validated port; origin allowlist; private IPv4 only | `:domain/.../ble/HomeHttpPolicy.kt` | upstream policy tests + new shared vectors (owner) | `:domain:testDebugUnitTest` | 150–250 (+ JNI, §7 item 3) | no |
| L-4 | Events: boot_id match, monotonic seq, last 32, duplicate/old boot dropped, never an MCP trigger | `:domain/.../ble/BleLinkEvents.kt` | `pdsh-link.jsonl` event rows | `:domain:testDebugUnitTest` | 80–150 | no |
| L-5 | `ble_*` native MCP tools: descriptors, idempotency key required, receipt, no replay, cancel | `:app/.../AndroidBleHost.kt` | `spec/v1/golden/native-mcp/ble-devices.json` | `:app:testDebugUnitTest` | 300–500 | one device smoke |

The firmware-side negative case is mandatory in L-1: a `pdsh.task.*` name must never be sent or
accepted (ble-link.md §"协商" lines 29–30; `golden/ble-task-plaintext-admission.jsonl`).

---

### 3.3 BLE authenticated task session (`secure-session-v2.1`)

#### 3.3.1 iOS implementation

| File | LOC | Role |
| --- | --- | --- |
| `SecureSession/BLESecureTLSClient.swift` | 434 | TLS 1.3 client over the CoC byte stream: ClientHello, key schedule, records, certificate verification, ALPN, close |
| `SecureSession/BLESecureTLSCore.swift` | 307 | TLS constants, HKDF key schedule (RFC 8446 §7.1), AES-128-GCM record protection, handshake buffer, signature helpers |
| `SecureSession/BLESecureMessage.swift` | 322 | closed message schema (client/server), encode/decode, outcome JSON |
| `SecureSession/BLESecurePhoneSessionCore.swift` | 309 | the phone state machine: session states, grant windows, sequence, response table, intent/recovery decisions |
| `SecureSession/BLESecureSession.swift` | 274 | generation actor: one session at a time, timers, `openSession`/`request`/`end` |
| `SecureSession/BLESecureTaskIntake.swift` | 330 | grant-scoped intake loop, one outstanding request, keepalive, resend-as-next-request, renewal |
| `SecureSession/BLESecureSessionCoordinator.swift` | 320 | UI-facing coordinator: enrollment, selection, phase, notices |
| `SecureSession/BLESecureEnrollment.swift` | 336 | records, state machine, file store (atomic install + fsync) |
| `SecureSession/BLESecureCertificate.swift` | 209 | producer + verifier for the pinned self-signed certs |
| `SecureSession/BLESecureIdentifiers.swift` | 155 | key validation, fingerprints, IDs, tokens |
| `SecureSession/BLESecureJSON.swift` | 281 | strict JSON (duplicate keys, NUL, surrogates) |
| `SecureSession/BLESecureDER.swift` | 110 | minimal DER reader/writer |
| `SecureSession/BLESecureL2CAPStream.swift` | 238 | bounded byte stream over `CBL2CAPChannel`, buffering limits, close reasons |
| `SecureSession/BLESecureFraming.swift` | 63 | `length:u16` framing, 1…4096 |
| `SecureSession/BLESecureTransport.swift` | 96 | stream protocol, memory pipe, service/PSM constants |
| `SecureSession/BLESecureLease.swift` | 44 | connection-generation token |
| `SecureSession/BLESecureConsole.swift` | 98 | enrollment console line grammar |
| `SecureSession/BLESecurePhoneKey.swift` | 178 | Secure-Enclave-backed key, Keychain store, software fallback |
| `BLEDeviceStore.swift` (secure part) | ≈ 200 of 2,435 | PSM read, CoC open, lease admission, teardown on selection change/disconnect |

State machine: `closed → ready_wait → ready`; PSM read (2 bytes LE, 0x0080–0x00FF) → CoC → TLS 1.3 with
client cert and server pin → `ready_req(seq 1)` with fresh `cc` → validate `ready_ack` (`re`, `device`,
`phone`, `eid`, `cc`) → ready. Grant windows: accept 1800 s from the user's grant; report-only until
600 s after that; 3 consecutive failed session attempts end the grant; keepalive `status` at most every
30 s; idle 90 s; session lifetime 600 s; response wait 10 s. On disconnect/background/forget/record
change/key change/revocation the live session is invalidated **before** teardown so late callbacks
cannot restore readiness.

#### 3.3.2 Spec coverage and Android status

- `ble-secure-session.md:3–21`: "Status: `target` — frozen contract; both ends exist as library code
  and host tests only, nothing is enabled. … No caller may enable a BLE task grant on the strength of
  this document. GAP-16 stays open until both ends implement this revision, run every shared fixture
  and every conformance-matrix row (§13) through their real code, and the physical acceptance in §14
  is recorded."
- `ble-secure-session.md:37–39`: "**Phone** is the iOS app (TLS client); **device** or **board** is the
  reference ESP32-S3 firmware (TLS server)." — an Android phone is not in the vocabulary today.
- `ble-secure-session.md:482–498` (transport): GATT service `d04ea024-…`, PSM characteristic
  `abdd3056-…` read-only 2 bytes LE, one LE credit-based CoC, "The phone reads the PSM afresh on every
  connection and never caches it."
- `ble-secure-session.md:529–540` (TLS profile): TLS 1.3 only, `TLS_AES_128_GCM_SHA256` only,
  `secp256r1` only, `ecdsa_secp256r1_sha256` only, ALPN `pdsh-ble-task/1` exactly, no PSK/0-RTT/
  tickets/KeyUpdate, records ≤ 4352 content / ≤ 4369 protected.
- `ble-secure-session.md:1108–1121` (§14): physical iPhone ↔ reference ESP32-S3 acceptance, including a
  4-minute task across a session renewal, reconnect, board reboot and phone restart, and negative
  physical runs.
- `spec/README.md` GAP-16: contract frozen, implementation pending, explicitly a real-device closure.

#### 3.3.3 Android platform constraints

- **API 29+ only.** LE L2CAP CoC client (`BluetoothDevice.createL2capChannel` /
  `createInsecureL2capChannel`) was added in Android 10 (API 29). With `minSdk = 26`, Android 8–9
  (API 26–28) have no CoC at all. The secure session must be *unavailable* there, never downgraded —
  the spec has no plaintext fallback (`ble-secure-session.md` §6.1: "no fallback profile and no plaintext
  mode").
- **Two CoC kinds, neither equal to Apple's.** The secure `createL2capChannel` documents "the remote
  device will be authenticated and communication on this socket will be encrypted" (i.e. it requires an
  authenticated link key / bond); `createInsecureL2capChannel` may be unauthenticated and unencrypted.
  Apple's CoC has no such choice. The contract must say which one Android uses and what it may claim
  (§6 CCR-4). The TLS pin remains the only trust decision either way (`ble-secure-session.md` §5: "The phone MUST NOT
  treat LE encryption, bonding or a successful read as authentication").
- **Platform TLS cannot express the whole §6.1 profile.** `SSLContext`/`SSLEngine` can select TLS 1.3
  and the cipher suite, present a client certificate and run a pin check inside the handshake
  (`X509TrustManager.checkServerTrusted`), and set ALPN. It cannot portably restrict
  `supported_groups` to P-256 only, forbid HelloRetryRequest, or pin `signature_algorithms` across
  API 26–35. §6.1 is explicit that "any deviation fails the handshake", so a conformant Android client
  is likely a **minimal TLS 1.3 client written against JCA** (AES-GCM, SHA-256, ECDH P-256, ECDSA) —
  the same choice iOS made with CryptoKit. That is the largest and riskiest item in this plan; it also
  needs an independent security review (§15 of the spec).
- **CoC stream shape.** `BluetoothSocket` gives blocking `InputStream`/`OutputStream`; the adapter must
  move bytes on a dedicated thread/coroutine and preserve order. TLS record boundaries are not SDU
  boundaries (`ble-secure-session.md` §5), so a byte-stream wrapper is required.
- **Bond vs pin.** If the board requires an encrypted link for the PSM read, Android must be bonded
  before the read; if not, the read works unbonded. Bonding UI (PIN/passkey) is a new Android surface
  and a new user-facing failure mode.

#### 3.3.4 What Android already has

Nothing for the secure session. No L2CAP code, no TLS client, no enrollment store, no pinned
certificate verifier. `android/domain`'s `BleLinkCodec` is unrelated.

#### 3.3.5 Missing spec deltas

| ID | Delta | Owner | Blocks |
| --- | --- | --- | --- |
| D-7 | Android transport note: API 29 floor, which CoC variant, what "LE encryption" claim is allowed, and the requirement that API 26–28 report "secure session unavailable" | P07 owner (CCR-4) | 3B.1 |
| D-8 | Register Android as a phone end for the §13 fixture table and the conformance matrix (every row with `phone` in `ends` must be run by Android too, or the row must record `NOT_RUN` for `android`) | P07 owner | 3B.2 |
| D-9 | Phone-key storage: iOS uses Secure Enclave/Keychain; Android needs an equivalent that never exports the key (AndroidKeyStore EC key + `Signature`) and a documented fallback. This is a new end-specific clause, not a port of the Swift one | P07 + P18 owner | 3B.1 |

#### 3.3.6 Checkpoints

| ID | Content | Owned paths | Fixtures | Acceptance | Est. | Device? |
| --- | --- | --- | --- | --- | --- | --- |
| **3B.1** | Identifiers + JSON + DER + certificate verifier + enrollment records/console, no transport | `android/domain/.../secure/` (new) | `ble-secure-identifiers.jsonl`, `ble-secure-enrollment-lines.jsonl`, `ble-secure-enrollment-states.jsonl` (`side=phone`), `ble-secure-certificates.jsonl` (`role=device`), `ble-secure-messages.jsonl`, `ble-secure-frames.jsonl` | `:domain:testDebugUnitTest` | 1,200–1,800 | no |
| **3B.2** | Phone session core + generation + recovery decisions | same package | `ble-secure-session-sequences.jsonl` (`side=phone`), `ble-secure-recovery.jsonl`, `ble-secure-task-intents.jsonl` | `:domain:testDebugUnitTest` | 900–1,400 | no |
| **3B.3** | L2CAP CoC transport + TLS 1.3 client + PSM read + lease/teardown | `android/app/.../AndroidBleSecure.kt` (new) | `ble-secure-coc-cases.jsonl` is board-side; phone side uses `ble-secure-conformance-matrix.jsonl` loopback rows | device/loopback only; JVM NOT_RUN | 1,800–2,800 | **yes** (loopback host + real phone) |
| **3B.4** | Coordinator, enrollment UI, selection, grant admission | `:app` page + `:lib` page contract | none shared; UI evidence per P09 | `:lib:testDebugUnitTest` + device | 600–1,000 | yes for enrollment gesture/indicator |
| **3B.5** | Conformance matrix + §14 physical acceptance (blocked by firmware side) | — | `ble-secure-conformance-matrix.jsonl`, `ble-secure-coc-cases.jsonl` | row-by-row record; `NOT_RUN` is a valid recorded result | — | **must** |

Do **not** start 3B.3 before D-7 is frozen and before the independent review item in
`ble-secure-session.md` §15 is assigned. A TLS client is not a place to learn on the main branch.

---

### 3.4 Device tasks

#### 3.4.1 iOS implementation

| File | LOC | Role |
| --- | --- | --- |
| `DeviceTaskJournal.swift` | 481 | versioned per-operation journal, exclusive directory lock, atomic replace + fsync, phases `received/accepted/running/terminal`, sequence allocation, legacy inventory |
| `DeviceTaskExecutor.swift` | 224 | serialise per device, persist intent before effects, deadline reconciliation, terminal settlement |
| `DeviceTask.swift` | 160 | task validation (ids, idempotency key, requester, timestamps, UTF-8, depth, duplicates, NUL) |
| `DeviceTaskIntake.swift` | 113 | foreground connection-scoped intake loops, generation-safe start/stop |
| `DeviceTaskGrantCoordinator.swift` | 83 | per-UI-grant token, pending start handle, invalidation before suspension |
| `BLESecureTaskIntent.swift` | 225 | secure transition arguments, intent install, `fresh` vs query-only |
| `BLETaskIntent.swift` | 44 | legacy Link intent record |
| `LANDeviceTaskInbox.swift` | 124 | HTTPS SSE `/tasks` + accept/complete/fail, no redirects |
| `TaskSSEParser.swift` | 38 | bounded SSE line/event parser |
| `UniqueJSONKeys.swift` | 210 | reject duplicate members before decoding |
| `DeviceDSHRunner.swift` | 137 | isolated `pdsh-device-task` session, preset/SHA verification, final text only |
| `DeviceTaskLegacyInspector.swift` | 291 | read-only inspection of old records (legacy contract) |

State machine: task `received → accepted → running → terminal`; one task per device; 4096-record store;
the earlier of the device deadline and 5 minutes after durable acceptance; on restart an unprovable
outcome is `unknown_outcome`, never replayed; terminal report persisted before it is sent and retried
until acknowledged; BLE transitions install an intent (`<msg_id>-<action>.json`) before the first
upload and may only query afterwards; the isolated DSH session has no model-callable tools and its
preset SHA-256 is verified before prompting.

#### 3.4.2 Spec coverage and Android status

- `task-delegation.md:3`: "Status: `target`." and `:7`: "Until both ends implement that frozen revision
  and its physical acceptance is recorded, the iOS adapter MUST refuse all BLE task grants and leave
  task support unavailable; see GAP-16."
- `task-delegation.md:86–88` (LAN binding) is normative, but the profile's status is `target`; the BLE
  binding is explicitly `secure-session-v2`.
- `task-delegation.md:106–117`: the legacy Link binding is "`legacy`, permanently refused".
- `android-module-map.json`: `PhoneDSHDeviceTasks` → `kotlin: null`, `gradle: null`, `status: absent`.
- `legacy-task-inspection.md:10–11`: "Android has no access to an iOS app container; no Android device
  capability or parity is claimed by this initial iOS-only inspection."

#### 3.4.3 Android platform constraints

- Durable journal: `:dsh` has `JournalStore`/`HostStateStore`; the device-task journal has stronger
  rules (exclusive directory lock, atomic replace + directory fsync, no eviction). Java's
  `FileChannel` cannot be opened on a directory for fsync on Android (`FileChannel` is a file channel;
  opening a directory throws), so "synchronized file and directory" needs a native helper (POSIX
  `open`/`fsync`) or a frozen deviation. **This is a real portability question for §"Phone journal format"** and
  must be raised with the contract owner before 3C.1 (see §6.6, Q-1).
- No background availability promise: Android's FGS keeps the intake loop alive while the app process
  lives, but Doze/OEM kills can still stop it. The spec says "No background availability is promised
  while iOS suspends the app"; Android's promise must be stated separately, not inherited.
- Storage location: app-private `noBackupFilesDir` (the repo already keeps receipts there) — a restored
  backup must not replay a task.
- LAN `/tasks` SSE: `HttpURLConnection` can stream it, but certificate pinning and "no redirects" must
  be explicit; the pin trust model is `target` for all ends.

#### 3.4.4 What Android already has

Nothing: no device-task module, no journal, no isolated `pdsh-device-task` preset verification, no SSE
inbox. `HostAgentPresets` exists for other sessions.

#### 3.4.5 Missing spec deltas

| ID | Delta | Owner | Blocks |
| --- | --- | --- | --- |
| D-10 | Android durability statement for the §"Phone journal format" rules: directory fsync equivalent, lock implementation, and what "synchronized" means on Android | P06/P07 owner | 3C.1 |
| D-11 | Android end registration in `task-delegation.md` (both the LAN and secure bindings) and a statement that no Android task grant is enabled before GAP-16 closes | P06/P07 owner | 3C.3 |

#### 3.4.6 Checkpoints

| ID | Content | Owned paths | Fixtures | Acceptance | Est. | Device? |
| --- | --- | --- | --- | --- | --- | --- |
| **3C.1** | Task validation + journal + executor + settlement (no transport) | `android/domain/.../devicetask/` (new) or `android/dsh/.../devicetask/` (decide with P06) | `task-cases.jsonl`, `task-raw-bytes.jsonl`, `task-raw-json-cases.jsonl`, `task-outcome-cases.jsonl`, `task-grant-generations.jsonl`, `ble-task-inventory.jsonl`, `ble-task-store-cases.jsonl` (read side) | `:domain:testDebugUnitTest` or `:dsh:testDebugUnitTest` | 1,200–1,800 | no |
| **3C.2** | LAN inbox: SSE `/tasks`, accept/complete/fail, bounded parser, no redirects | `android/net/.../device/` (new) | `task-raw-bytes.jsonl` invalid cases; new SSE cases (owner) | `:net:testDebugUnitTest` | 400–600 | no (loopback), yes for real LAN device |
| **3C.3** | Secure binding: intents, one outstanding request, resend-as-next-request, keepalive, grant-scoped intake | `android/.../devicetask/` | `ble-secure-task-intents.jsonl`, `ble-secure-session-sequences.jsonl`, `ble-secure-task-store-cases.jsonl` | `:domain:`/`:dsh:` tests | 600–900 | yes (with 3B.5) |
| **3C.4** | Isolated DSH session: verify preset document SHA + session projection + lifecycle-gate inventory before prompting | `android/dsh/.../turn/` | preset SHA from `task-delegation.md`; no shared golden | device only (needs Worker) | 300–500 | **yes** |

The whole of 3C stays behind D-11 and the `target` status. It must not be wired to a UI grant while
the contract says `target`.

---

### 3.5 TonoLink voice turn and CloudVoice

#### 3.5.1 iOS implementation

| File | LOC | Role |
| --- | --- | --- |
| `Sources/PhoneDSHBLE/TonoLinkVoice.swift` | 97 | `ev wake` / `ev listen_end` parser (strict decimals, unknown members ignored), audio packet parser (4-byte header, id low byte, 0…160 Opus), `listen` command, tally (gaps counted, not filled) |
| `Sources/PhoneDSHBLE/TonoLinkCtrlBLE.swift` | 304 | ctrl GATT client: `5DBD66EC-…` service, `cmd` write, `status` notify (encryption required), optional `audio` notify; restorable central, line parsing, `command`/`request` with seq, OTA writes |
| `Sources/PhoneDSHBLE/TonoLinkUSBOTAProtocol.swift` / `TonoLinkUSBOTA.swift` / `TonoLinkUSBTransport.swift` | 307 / 264 / 174 | board HTTP/console framing and OTA flow (shared with §3.6) |
| `Sources/PhoneDSH/CloudVoice/CloudVoiceProtocol.swift` | 222 | `CloudVoice` constants (ASR wss URL, subprotocol, TTS URL/voice/rate, timeouts, queue cap), `start`/`finish`/`cancel`, TTS body, ASR message classification, `speakable` + `chunks` |
| `Sources/PhoneDSH/CloudVoice/CloudVoiceClients.swift` | 210 | `CloudASRSession` (WebSocket, `started` gate, ordered forwarding, deadlines, outcome), `CloudTTSClient` (streaming PCM), credential resolution |
| `examples/probe-app/PhoneDSHProbe/TonoLinkVoiceHost.swift` | 510 | the turn: supervise link, arm speaker, wake → 「我在」 → `listen` immediately → forward Opus → ASR outcome → acknowledge → chat → speak reply; background task; DEBUG routes |
| `examples/probe-app/ProbeKit/PhoneAudioSessionLease.swift` | (ProbeKit) | iOS audio ownership; **not ported** (see §3.5.3) |

State machine of the turn: one long-lived ctrl link (restorable, parked reconnect); `ev wake` cancels
any recording/recognising/speaking turn, increments `turnID`, opens an ASR session, plays 「我在」,
writes `<seq> listen <id>` **as soon as 「我在」 has played** (not when ASR is ready), buffers board
Opus (≤ 700 packets = 14 s) until `started`, forwards in order, ends on last-flag or `ev listen_end`
(whichever first), uses only `final` texts after `completed`, then sends the text to the current chat,
plays 「好的，马上处理」, and speaks the reply's last assistant text in speakable chunks.

#### 3.5.2 Spec coverage and Android status

- `tonolink-board.md:3`: "Status: `implemented` (iOS consumer only; §4.1 voice turn `partial` until
  device evidence)."
- `tonolink-board.md:14`: "The consumer is `Sources/PhoneDSHBLE/TonoLink*.swift` plus
  `Sources/PhoneDSHVenus/IPhoneAgent*.swift`. **Android and HarmonyOS have no consumer.**"
- `tonolink-board.md:67–98` (§4.1) is the normative voice contract, with
  `golden/tonolink-voice.json` as "the judge where this text could be read two ways", and the consumer
  rules quoted in §3.5.1.
- `cloud-voice.md:3`: "Status: `partial` (iOS consumer only, until device evidence)." and `:14`:
  "**Android and HarmonyOS have no consumer.**"
- `spec/platform/whitelist.json` `platform.tonolink-voice-background-wake`:
  `"android": "Android has no TonoLink voice consumer; a future one would hold the BLE link in the
  existing foreground service instead of a background mode."` — this entry already anticipates the
  port and names the mechanism.
- `ios-audio-session.md:5`: "Android continues to use the foreground-service policy in `whitelist.json`."
  That is the platform-level statement that the iOS audio-lease contract is not the Android mechanism;
  the Android design must be the FGS + `AudioTrack`/focus path of §5.3/§5.5, not a port of
  `PhoneAudioSessionLease`.

#### 3.5.3 Android platform constraints

- **Background BLE.** iOS declares `bluetooth-central` and keeps a restorable central with a parked
  connect. Android's equivalent is a foreground service of type `connectedDevice` (API 29+; permission
  `FOREGROUND_SERVICE_CONNECTED_DEVICE` from API 34) started while the user is in the app. Android 12+
  forbids starting an FGS from the background, and a BLE scan/notification cannot start one. So the
  contract's "a wake may arrive while suspended" becomes "while the voice service is running"; if the
  service was never started, wake is unavailable — a user-visible difference to record, not hide.
- **Doze.** An established GATT connection usually survives Doze, but notification delivery can be
  delayed and the radio may be shared. An FGS is the supported mitigation; OEM battery managers remain
  out of contract. Device evidence is required for "wake while screen off".
- **Audio output.** There is no AirPlay on Android, so the iOS speaker-override rule (force the built-in
  speaker when the output is the board's AirPlay sink) has no analogue. The board presents USB NCM
  (network), not a USB audio sink. Android routes media to the current output (speaker/headphones/A2DP)
  automatically. The port uses `AudioTrack` (streaming 16 kHz mono s16le) with
  `USAGE_MEDIA`/`CONTENT_TYPE_SPEECH`, an `AudioFocusRequest` (API 26+) with
  `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`, and `setAudioAttributes`; it must abandon focus on turn end
  and stop playback on focus loss. SCO (`startBluetoothSco`/`setCommunicationDevice`) is for
  communication capture/playback and is **not** needed here: the board records, the phone only plays.
- **Microphone.** The TonoLink voice turn does not capture on the phone — the board does. So no
  `RECORD_AUDIO` and no background-microphone restriction applies to this capability. Android's
  background mic limits (API 30+) are only relevant to a future phone-mic voice input, which is a
  different (P08) capability and is not part of this plan.
- **TTS.** Android has `TextToSpeech` (the chat reply read-aloud button already uses it,
  `MainActivity.kt:209`, `:289`). Cloud TTS is a different path (PCM stream → `AudioTrack`), so the
  platform TTS engine is not reused; it stays as the chat button's mechanism.
- **Opus.** Android has no Opus decoder in the platform; the voice path **forwards** Opus to the cloud
  ASR and never decodes it, so no codec dependency is added. (If a later change wants local playback of
  board audio, that needs a codec decision.)
- **No WebSocket client in the platform.** Android has no `java.net.http` client and no WebSocket API;
  the ASR transport is `wss://`. Either implement the RFC 6455 client over `SSLSocket` (small, testable
  against the shared message cases, no new dependency) or add a third-party WebSocket dependency — a
  P05 dependency decision under AGENTS.md §6, not an implementer's choice. The plan prefers the minimal
  client.
- **`cmd` write attribution.** Each `cmd` line carries `<seq>` and the board's `ack <seq>` names it, so
  the *response* is self-identifying even though the write callback is not. That is why voice does not
  need GAP-20's adapter contract, but the adapter must still fail closed on write errors and
  disconnects (an `ack` that never arrives is a failed turn, not a retry).
- **API floor.** ctrl GATT + FGS + `AudioTrack` all work at API 26. The `connectedDevice` FGS *type*
  and the typed `startForeground(id, notification, type)` call are API 29+; below 29 the manifest type
  is ignored and the untyped `startForeground(id, notification)` is used. Declare the type in the
  manifest for 29+, and branch the call, not the policy.

#### 3.5.4 What Android already has

- Scan + standard GATT (not the ctrl service), FGS infrastructure (`TurnForegroundService`, UIDT job,
  notification channels), `TextToSpeech` for chat replies, a `:net` HTTP stack, no WebSocket client for
  ASR, no cloud voice client, no TonoLink codec.
- `spec/platform/whitelist.json` already names `startForeground` as the Android mechanism.

#### 3.5.5 Missing spec deltas

| ID | Delta | Owner | Blocks |
| --- | --- | --- | --- |
| D-12 | Register Android as a consumer of `tonolink-board.md` §4.1 and `cloud-voice.md`, with the Android background statement ("wake is available only while the voice foreground service runs") and API 26 floor | P07 + P05 owner | 2B.1/2B.2 claim, 3A.1 |
| D-13 | Android audio note: no AirPlay override, media focus policy, no phone capture; add a `spec/platform` entry (or extend the whitelist entry with `evidence_level` + mechanism) | P08 owner | 3A.2 |
| D-14 | Decide whether the voice turn's "app background" acceptance is a new shared fixture or a device-only record. Proposal: device-only, because it is a platform lifecycle property; record the Android fields alongside the iOS ones | P07/P08 owner | 3A.3 |

#### 3.5.6 Checkpoints

| ID | Content | Owned paths | Fixtures | Acceptance | Est. | Device? |
| --- | --- | --- | --- | --- | --- | --- |
| **2B.1** | Voice wire codec: event line parser, audio packet parser, `listen` builder, tally | `android/domain/.../tonolink/TonoLinkVoice.kt` (new) | `golden/tonolink-voice.json` (16 events / 2 listen commands / 8 packets) | `:domain:testDebugUnitTest` | 150–250 | no |
| **2B.2** | Cloud voice client: ASR WebSocket (`pdsh-asr.v1`, RFC 6455 over `SSLSocket` unless P05 approves a dependency), `started` gating, ordered queue ≤ 100, deadlines, outcome classification, TTS streaming + `speakable`/`chunks` | `android/net/.../voice/` (new) | `spec/v1/golden/cloud-voice/cases.json` | `:net:testDebugUnitTest` | 600–900 (incl. minimal WS client) | no (stub server), cloud E2E later |
| **3A.1** | ctrl GATT adapter: service/characteristic discovery, `cmd`/`status`/`audio`, line framing, seq/ack, encryption-required failure, reconnect/supervise | `android/app/.../AndroidTonoLinkCtrl.kt` (new) | `golden/xiaozhi-ctl.jsonl` is **not** this service; voice lines use `tonolink-voice.json`; console grammar is `TonoLinkBLEDebugProtocol` (no shared golden) | `:app:testDebugUnitTest` + device | 700–1,000 | **yes** |
| **3A.2** | Foreground voice service: `connectedDevice` type, notification, start/stop from the page, no background start; audio focus + `AudioTrack` playback | `android/dsh/.../background/VoiceForegroundService.kt` (proposed; P08 owner confirms) + `:app` binding | none | device only (FGS type + notification + audio route) | 500–800 | **must** |
| **3A.3** | Turn state machine: wake → 「我在」 → `listen` → forward → ASR → chat → speak; cancellation on new wake; 700-packet buffer | `android/app/.../TonoLinkVoiceHost.kt` (new) | `tonolink-voice.json` for the pieces; turn ordering is device evidence | device + board | 700–1,000 | **must** |

3A.3's chat wiring uses the existing `ChatTurnRunner`/`ChatModel` equivalent; it must send through the
same composer path (no second message envelope) and must not read the reply by scanning a UI list.

---

### 3.6 TonoLink screen, phone-hands, USB OTA and DEBUG relay

#### 3.6.1 iOS implementation

| File | LOC | Role |
| --- | --- | --- |
| `TonoLinkScreen.swift` | 496 | APV1 parser (2 MiB cap), NAL handling, VideoToolbox decoder, JPEG snapshot, one TCP connection to the board, "newer than" frame sequencing |
| `TonoLinkPhoneHands.swift` | 273 | board HTTP over USB NCM: gestures (`/v1/hid/batch`), HID enable with ≥ 6 s backoff, AssistiveTouch geometry, typing segmentation, mirrored-layout points, `503 busy_exec` resend |
| `TonoLinkUSBOTA.swift` | 264 | OTA state machine over ctrl BLE + USB HTTP: connect, image upload, reboot, confirm, Wi-Fi config |
| `TonoLinkUSBOTAProtocol.swift` | 307 | console/OTA framing and status codes |
| `TonoLinkUSBTransport.swift` | 174 | authenticated `:8768` USB session, HTTP client |
| `TonoLinkRelay.swift` | 315 | DEBUG relay router on `:8780` (no auth) |
| `TonoLinkPortForward.swift` | 183 | TCP forwarder for `:8767`/`:8769` |
| `TonoLinkBLEDebug.swift` / `TonoLinkBLEDebugProtocol.swift` | 166 / 138 | DEBUG console and test routes |

State machines: APV1 (12-byte header, `configuration/video/reset`, NAL reorder, decoder reset on
`reset`, snapshot only for a frame decoded after the previous action); HID (status gate
`hid.{keyboard,absolute,input_mode}` all true, one batch per request, HTTP timeout = 15 s + planned
duration, `503 busy_exec` retried every 300 ms up to ~3 s because the board ran nothing, any other
failure = "not executed" and no retry); OTA (BLE connect → USB auth → upload → reboot → settle →
confirm poll).

#### 3.6.2 Spec coverage and Android status

- `tonolink-board.md:6–14`: the board is "the phone's **hands** (Bluetooth HID keyboard and absolute
  mouse) and its **eyes** (an AirPlay receiver that the phone mirrors its screen to)"; "Android and
  HarmonyOS have no consumer."
- `tonolink-board.md:18–28` (§1): "Phone control does not use the Link Tools profile in v1 … Moving HID
  actions into Link tools is a separate, not yet frozen change (phase 2); until it is frozen, no end
  may send HID through Link."
- `tonolink-board.md:30–48` (§2), `:50–57` (§3), `:100–117` (§5 relay: "The relay has **no
  authentication**: anyone on that Wi-Fi can drive the phone and flash the board while it is on. It is
  compiled only under `#if DEBUG` … and is never part of a release build.").
- `native-mcp.md:110–134`: `iphone_agent_run` is an iOS tool; "the Android host does not serve it."
- `spec/platform/whitelist.json` `platform.tonolink-iphone-agent`, divergence class `os-forced`:
  `"android": "The Android host already controls an Android phone through its own ADB tools on the same
  native MCP endpoint (android_* tools, spec/v1/native-mcp.md), so it needs no board, no
  iphone_agent_run and no UI-Venus/board settings pages."`

#### 3.6.3 Android platform constraints

- **No AirPlay.** The board is an AirPlay *receiver*; iOS mirrors to it. Android has no AirPlay sender.
  Nothing on the Android side can produce the APV1 stream the board emits without either (a) a
  board-side Android screen-ingest protocol (producer change, outside this repository) or (b) a
  MediaProjection encoder talking to a new board endpoint. Both are new contracts, not ports.
- **USB NCM host support is device-dependent.** The board presents `192.168.247.1` over USB NCM. Using
  it from Android requires the phone to act as a USB host and to expose the NCM interface as a network
  (kernel `cdc_ncm`/`rndis_host`, `EthernetManager` on some OEMs). This is not guaranteed by Android
  and must be measured per device before any HID/OTA work; if the interface is not surfaced, none of
  §2/§3 of `tonolink-board.md` is reachable from Android.
- **HID has no Android consumer.** `platform.tonolink-iphone-agent` already records that Android
  controls its own UI through ADB. Porting HID gestures would create a second, unaudited phone-control
  path with no agent that uses it.
- **Relay.** Porting a DEBUG-only, unauthenticated LAN listener to a second platform multiplies the
  exposure and has no user-facing capability behind it; if a relay is ever needed on Android it needs
  its own authenticated contract.
- **OTA** is the only piece with an independent user value (recover/update the board from the phone)
  and no AirPlay/HID dependency, but it still needs NCM (HTTP paths) plus the ctrl GATT service.

#### 3.6.4 What Android already has

Nothing for these paths. No APV1/MediaCodec screen client, no board HTTP client, no NCM handling, no
OTA, no relay.

#### 3.6.5 Missing spec deltas

| ID | Delta | Owner | Blocks |
| --- | --- | --- | --- |
| D-15 | If Android screen ingest is wanted: a producer-side contract (new board endpoint/protocol) — not a revision of `tonolink-board.md` §3, because APV1 is the board's *output* format | P07 owner + board firmware owner | 3E.x (not planned) |
| D-16 | If Android USB OTA is wanted: an Android transport note (NCM requirement, no AirPlay, ctrl service only) and a statement of which devices qualify | P07 owner | 3E.1 |
| D-17 | Relay: record that it stays iOS-DEBUG-only and must not be ported without an authenticated contract | P07 owner | none (decision) |

#### 3.6.6 Disposition and (conditional) checkpoints

| Piece | Decision | Reason |
| --- | --- | --- |
| Screen / APV1 | **Do not port now** | no Android AirPlay source; needs a board-side contract (D-15) |
| Phone-hands / HID | **Do not port** | no consumer; ADB is the Android mechanism (`platform.tonolink-iphone-agent`) |
| DEBUG relay | **Do not port** | unauthenticated, DEBUG-only; no capability value |
| USB OTA | **Conditional, wave 3+**; only after D-16 and an NCM device measurement | independent value, but platform-gated |

| ID | Content | Owned paths | Fixtures | Acceptance | Est. | Device? |
| --- | --- | --- | --- | --- | --- | --- |
| **0E.1** (investigation) | Measure USB NCM on the target Android devices: does the board's `192.168.247.1` appear, and can the app reach `/v1/info`? | none (record in the evidence log) | none | manual; record device model + API + result | 0.5–1 day | **must** |
| **3E.1** (only if 0E.1 passes and D-16 freezes) | Board HTTP client + OTA state machine + ctrl OTA transport | `android/app/.../TonoLinkUSB*.kt` (new), `:net` HTTP | `golden/xiaozhi-ctl.jsonl` does not cover ctrl OTA; `TonoLinkUSBOTAProtocol` has unit tests on iOS only | `:app:testDebugUnitTest` + device | 700–1,000 | **must** |

---

### 3.7 UI-Venus agent

#### 3.7.1 iOS implementation

| File | LOC | Role |
| --- | --- | --- |
| `PhoneDSHVenus/IPhoneAgent.swift` | 314 | the agent loop: screen → model → one action, step limit, screenshot diff, repeat/ping-pong guard, permission prompt → `CallUser` |
| `IPhoneAgentGuards.swift` | 82 | action guards |
| `IPhoneAgentMCPServer.swift` | 173 | `iphone_agent_run` native MCP tool: idempotency receipt, one run at a time, cancellation, timeout |
| `VenusAction.swift` | 205 | action parser (text + JSON forms), normalisation |
| `VenusClient.swift` | 164 | OpenAI-compatible vision client: models allowlist, 16 MiB body cap, 2 MiB response cap, no redirects, no credential in errors |
| `VenusSettings.swift` | 50 | HTTPS endpoint + model + key in a dedicated Keychain service |
| `VenusFailure.swift` | 13 | failure codes |
| `examples/probe-app/PhoneDSHProbe/IPhoneAgentHost.swift` | 405 | device implementation: `prepare` (HID + mirror warmup), `screenshot`, `perform`, `home` via AssistiveTouch, Spotlight launch, DEBUG routes |

State machine: one run at a time; each step = fresh screenshot (decoded after the previous action), model
call, parse one action, execute, compare screenshots (36×52 grayscale, mean diff < 2/255 = unchanged),
tell the model when nothing changed; three repeats or two ping-pongs → one nudge that is not executed,
then stop with `finished=false` and an answer starting 「卡住了」; a system permission/privacy prompt ends
the run with `CallUser`. The tool persists a receipt keyed by the idempotency key before touching the
phone; a repeat returns the stored result; an interrupted run is `outcome_unknown` and never replayed.

#### 3.7.2 Spec coverage and Android status

- `native-mcp.md:110–134` (§"iPhone agent tool (implemented on iOS)"): additive tool, input
  `{"task": string}`, error `status` set, idempotency key required, receipt semantics, one task at a
  time, "the Android host does not serve it."
- `tonolink-board.md:119–141` (§6): model endpoint/settings, screenshot diff, repeat guard, Home via
  AssistiveTouch, `CallUser` on system prompts.
- `spec/platform/whitelist.json` `platform.tonolink-iphone-agent`: `os-forced`, Android mechanism
  `android_*` ADB tools, evidence level `device-gate`.

#### 3.7.3 Android platform constraints (why this is not a port)

- The capability "the agent operates the phone's UI" already exists on Android through ADB
  (`android_*` tools on `/mcp/native`, 26 tools). It needs no external board.
- A faithful port of the *agent loop guard* would need an Android screenshot source. Options are
  MediaProjection (user consent per capture session, FGS type `mediaProjection`, no background start)
  and AccessibilityService (a new privileged surface with Play policy consequences). Neither is in the
  current contract; both are new features, not parity.
- Venus settings and the board pages would configure hardware the Android host does not serve; the
  whitelist explicitly forbids copying them.

#### 3.7.4 What Android already has

`AdbMcpServer` (26 `android_*` tools) on the native MCP endpoint, `AndroidAdbHost` composition root,
the Android ADB settings page, and the Worker's MCP path. No vision model client, no agent loop, no
screenshot source.

#### 3.7.5 Missing spec deltas

No implementation delta is required for parity, because the whitelist already records the divergence.
Two paper gaps remain:

| ID | Delta | Owner |
| --- | --- | --- |
| D-21 | The `os-forced` class carries an obligation in `spec/platform/README.md` line 60: "语义等价是义务；只能换机制，不能放宽语义". The entry's capability is "the agent operates the phone's UI"; the Android mechanism (`android_*` ADB tools) does **not** implement §6's observable guards (screenshot diff, repeat/ping-pong stop, `CallUser` on a system prompt). Either narrow the entry's claimed capability or add the equivalent guard semantics to the Android ADB tool layer; do not leave the obligation unmet. | P08 + P07 owner |
| D-22 | Re-check `evidence_level: device-gate` against a real device run; if none exists, re-grade or attach it. | P08/P09 owner |

Neither is a reason to port UI-Venus: the mechanism gap is in the guard layer, not in the model client.

#### 3.7.6 Checkpoints

| ID | Content | Owner | Acceptance |
| --- | --- | --- | --- |
| **0G.1** (paper) | Re-read `platform.tonolink-iphone-agent` against the shipped ADB tool list: (a) does the `device-gate` evidence exist, (b) are the §6 guard semantics (D-21) provided by anything on Android? Record the answer; if (a) is no, re-grade or attach evidence; if (b) is no, file D-21 with the P08/P07 owner | P08/P09 owner | a one-paragraph evidence note + D-21 decision; no code |

No Android implementation is planned for UI-Venus. If a product decision later wants model-driven
Android UI automation, it needs its own contract (screenshot source, consent, guards) and must not be
introduced as "the UI-Venus port".

---

### 3.8 LAN MCP

#### 3.8.1 iOS implementation

| File | LOC | Role |
| --- | --- | --- |
| `Sources/PhoneDSHLAN/LANAdvertisement.swift` | 75 | `LANDeviceCandidate`: service name 1–63 UTF-8, port 1–65535, TXT `profile=pdsh-mcp-1` exactly, `canon(host)` (ASCII-only, lowercase, LDH labels, no `xn--`, no numeric final label), URL built from `H` with path `/mcp`, the port omitted only when it is 443 |
| `LANDeviceDiscovery.swift` | 93 | NetServiceBrowser, 15 s scan, 100 candidates, 120 s expiry, removal on service loss |

State machine: user-started browse → resolve each instance (5 s) → candidate only if TXT and hostname
pass → display as unverified → selection pre-fills the MCP editor (URL, `device_<12hex>` name, 60 s
timeout, empty Authorization row). Discovery never connects, grants or calls a tool.

#### 3.8.2 Spec coverage and Android status

- `lan-mcp.md:3` status: "`implemented` for LAN discovery and phone-to-device MCP in the registered
  Swift and reference Python ends … The per-device certificate pin trust model below is `target`:
  phones still validate with the OS trust store."
- `lan-mcp.md:21`: "**Android is a partial implementation:** its bounded mDNS querier supplies the raw
  TXT bytes and SRV hostname to the shared decoder without lossy conversion
  ([PC-20261108-android-lan-mdns]), but the existing MCP authorization flow is not wired on Android (a
  selected candidate only pre-fills an editor that cannot persist) and discovery has not been verified
  on a physical phone's Wi-Fi."
- `lan-mcp.md:74–80` (§"TLS trust model"): pin format `sha256/…`, enrollment bundle, connection check,
  rotation, forget, failure codes, compatibility. Acceptance includes "equivalent Android tests through
  a custom `X509TrustManager` (OkHttp `CertificatePinner` alone also requires system trust)".
- `lan-mcp.md:19` bounds: SRV port 1–65535, TLS name `H`, IPv6/IPv4 literals never targets.

#### 3.8.3 Android platform constraints

- **Multicast.** `MulticastLock` (normal `CHANGE_WIFI_MULTICAST_STATE`) is required; Wi-Fi only; VPN
  and some OEM Wi-Fi stacks drop multicast. `NsdManager` is unusable for this profile because it
  collapses duplicate TXT keys into a `Map` and resolves to an `InetAddress` (already documented in
  PC-20261108-android-lan-mdns §2).
- **TLS name and pin.** The HTTPS URL host must be `H` and certificate validation must use `H`.
  This tree uses `HttpsURLConnection`, so a pin is enforced by installing an `SSLSocketFactory`
  built from a custom `X509TrustManager` (system-trust bypass for the enrolled leaf only) while
  keeping the default hostname verifier. `CertificatePinner` is an OkHttp feature and is not
  used here.
- **Doze / background.** Discovery is user-started and lasts 15 s; no background promise is needed.
  The task inbox (`/tasks` SSE) is a longer-lived connection and needs an FGS, which belongs to §3.4.
- **Credentials.** A host-managed secret store exists (`AndroidSecureStore`, `noBackupFilesDir`); the
  MCP grant/`headersFromEnv` model does not exist on Android yet.

#### 3.8.4 What Android already has

| Layer | File | LOC | State |
| --- | --- | --- | --- |
| DNS wire parser | `:domain/.../lan/DnsMessage.kt` | 304 | strict, bounded, whole-datagram refusal; 10 tests + 20,000 seeded mutations |
| candidate decoder | `:domain/.../lan/LanDiscoveryDecoder.kt` | 109 | consumes `lan-discovery*.jsonl` |
| browser/folding | `:domain/.../lan/LanMdnsBrowser.kt` | 212 | instance budget, TTL/goodbye, ambiguity drops |
| app querier | `:app/.../AndroidLanDiscovery.kt` | 286 | Wi-Fi-only, multicast lock, source admission, 15 s/120 s |
| UI | `MCP page` | — | candidate rows (name, URL, 未验证), selection pre-fills a **read-only** editor |
| tests | `DnsMessageParserTest`, `LanMdnsBrowserTest`, `LanDiscoveryDecoderTest` | — | shared vectors through the real pipeline |

Missing: the save path (`phone/mcpUpsert`), the host-managed credential/grant store, OS-trust TLS
validation from a native page (nothing connects today), pin trust, `/tasks`.

#### 3.8.5 Missing spec deltas

| ID | Delta | Owner | Blocks |
| --- | --- | --- | --- |
| D-18 | Android grant/credential storage: where the bearer credential lives, how `headersFromEnv`-equivalent injection is done, and the rollback story. (P18 owns stored settings; `lan-mcp.md` deliberately leaves this to P18.) | P18 + P05 owner | 3D.1 |
| D-19 | Pin enrollment bundle format + shared vectors (the spec says this is required before the pin model leaves `target`; no end may implement a partial pin path) | P07 owner | 3D.2 |
| D-20 | Record that Android discovery evidence is host-level until a physical phone's Wi-Fi run exists (already said in `lan-mcp.md`; keep it) | P07 owner | status claims |

#### 3.8.6 Checkpoints

| ID | Content | Owned paths | Fixtures | Acceptance | Est. | Device? |
| --- | --- | --- | --- | --- | --- | --- |
| **2E.1** | Prove the existing Android decoder/browser still matches the shared vectors after any change (no new code expected) | `:domain`, `:app` tests | `lan-discovery.jsonl`, `lan-discovery-raw.jsonl`, `lan-discovery-alabel.jsonl`, `lan-publication.jsonl` (`consistent` rows) | `:domain:testDebugUnitTest` | 0 new prod; test-only | no |
| **3D.1** | MCP save path: call `phone/mcpUpsert` through the existing `DshTurnClient.call` (the same path `HostAutomation` already uses for `phone/createSchedule`), host credential store + exact-URL grant, registry refresh, honest read-back | `android/app/.../HostMcp*.kt` (new/extend `HostShell` MCP actions), `:net`/`:dsh` secret injection, `:lib` editor `writable` fact | none; the Worker owns `phone-mcp` behaviour and its tests | `:app:testDebugUnitTest`; `:lib:testDebugUnitTest`; real device + reference device for E2E | 400–700 | **yes** for E2E |
| **3D.2** (only after D-19) | Per-device pin trust: custom `X509TrustManager`, enrollment bundle, rotation, forget, no credential sent on failure | `:net/.../lan/PinnedTrust.kt` (new) + UI | new shared pin vectors (owner) | `:net:testDebugUnitTest` + generated-cert tests | 400–600 | no for cert cases; yes for a real device |
| **3D.3** | `/tasks` SSE inbox | shares 3C.2 | `task-raw-*` + new SSE cases | `:net:testDebugUnitTest` | (counted in 3C.2) | loopback + real device |

Note the stale UI text: `HostShell.kt:1663–1666` and `:1786–1794` say "本宿主没有改写 MCP 注册表的工具
（phone/mcpUpsert）". The remote-call mechanism exists; the *page wiring and credential store* do not.
3D.1 must remove those strings in the same change; once the path exists they would be
user-visible false statements.

---

## 4. Execution order (waves, dependencies, ownership)

### 4.1 Order

| Step | Checkpoints | Depends on | Can run in parallel with | Exit evidence |
| --- | --- | --- | --- | --- |
| 0 | **C0** contract freeze (CCR-1/2/3, D-3/D-5; optionally D-7/D-8) | contract owner | D-12/D-13/D-18 paper work | merged spec revision + shared fixtures + registry update; `phone-spec,phone-p0-conformance,phone-cross-tree` PASS |
| 1 (wave 2) | **2A.1** GATT adapter | C0 (CCR-3) | 2B.1, 2B.2, 2E.1 | JVM tests + device adapter evidence (duplicate/stale/disconnect) |
| 2 (wave 2) | **2A.2** Link client/tools | 2A.1 | 2B.1/2B.2, 3D.1 (LAN) | shared ctl goldens + adapter JVM tests + one device smoke |
| 3 (wave 2) | **2A.3** trust/reconnect, **2A.4** native `ble_*` tools | 2A.2, C0 (CCR-1, D-3) | 3D.1 | trust golden through the real store + device reconnect run |
| 4 (wave 2) | **2B.1** voice codec, **2B.2** cloud voice | D-12 (registration) | step 1–3 | goldens through the real parsers; stub-server E2E |
| 5 (wave 3) | **3A.1–3A.3** voice platform | 2B.*, D-12/D-13, FGS decision | 3B.1, 3C.1 | device: wake with screen off, full turn, audio route, notification |
| 6 (wave 3) | **3B.1/3B.2** secure-session non-transport halves | D-7…D-9, C0 | 3A, 3C.1 | shared fixtures through the real state machine |
| 7 (wave 3) | **3B.3–3B.5** secure transport + acceptance | 3B.1/2, firmware side, security review | 3C.2, 3D.2 | conformance matrix rows + §14 physical record |
| 8 (wave 3) | **3C.1–3C.4** device tasks | 3C.1: D-10; 3C.2: D-11; 3C.3: 2A.2 + 3B.5; all: D-11 | 3D.2 | journal/task fixtures + device E2E with the secure board |
| 9 (wave 3) | **3D.1–3D.3** LAN finish, **3E.1** optional OTA | P13/P18, 0E.1, D-16 | — | device E2E with the reference LAN device; OTA only if measured |

### 4.2 What must not start

- No Android **task grant UI or code path** before 3B.5 and D-11. The firmware refuses plaintext task
  requests permanently; a UI that offers the switch would be a lie.
- No **secure-session transport** before D-7 and an assigned owner for the independent review items in
  `ble-secure-session.md` §15.
- No **Link over GATT** before CCR-3 is frozen; the old draft CCR says a fake callback test that always
  supplies the right token proves nothing, and that is still true.
- No **HID/relay port**, and no screen path without D-15.
- No **new golden** without the contract owner; no test may inline a copy of a golden (lessons §4).

### 4.3 Suggested worker split

| Worker | Owns | Does not touch |
| --- | --- | --- |
| W2-BLE | 2A.1–2A.4 (`:domain/.../ble`, `:app/AndroidBle*`, native MCP composition) | `spec/**`, voice, tasks |
| W2-VOICE | 2B.1–2B.2 (`:domain/.../tonolink`, `:net/.../voice`) | `:app` GATT plumbing (W2-BLE/W3-VOICE owns) |
| W3-VOICE | 3A.1–3A.3 (`:app/AndroidTonoLink*`, `:dsh` or `:app` voice FGS) | BLE adapter |
| W3-SECURE | 3B.1–3B.5 (`:domain/.../secure`, `:app/AndroidBleSecure`, enrollment UI) | task journal |
| W3-TASKS | 3C.1–3C.4 (`:domain`/`:dsh` device task, `:net` SSE) | secure transport |
| W3-LAN | 3D.1–3D.3 (MCP save path, pin trust) with P13/P18 owners | discovery (done) |

Shared files that need one owner at a time: `AndroidBleDevices.kt` (W2-BLE), the app manifest
(W3-VOICE/W2-BLE), `ProbeEngineViewModel.nativeMcp` wiring (W2-BLE then W3-LAN), `HostShell.kt`
(W3-LAN).

---

## 5. Shared Android platform constraints

This section is the reference for the per-capability notes above. The app's `minSdk` is 26 and
`targetSdk` is 35 in every module (`android/app/build.gradle.kts:435–436`,
`android/domain/build.gradle.kts`, `android/dsh/build.gradle.kts`). Everything below is stated for that
range.

### 5.1 Permissions and API floor

| Capability | API 26–30 | API 31+ | Notes |
| --- | --- | --- | --- |
| BLE discovery | `BLUETOOTH` + `BLUETOOTH_ADMIN` (both `maxSdkVersion=30`) + `ACCESS_FINE_LOCATION` | `BLUETOOTH_SCAN` with `usesPermissionFlags="neverForLocation"` | already declared in `android/app/src/main/AndroidManifest.xml`; the `neverForLocation` flag can filter some beacons — the advertised name/RSSI are display-only anyway |
| BLE connect / GATT | `BLUETOOTH`/`BLUETOOTH_ADMIN` | `BLUETOOTH_CONNECT` (runtime) | requested at the first connect today; `connectGatt`, `createBond`, `createL2capChannel`, `getBondedDevices` all need it |
| BLE advertise | not needed | `BLUETOOTH_ADVERTISE` | do not declare |
| LAN multicast | `CHANGE_WIFI_MULTICAST_STATE` (normal), `ACCESS_NETWORK_STATE` | same | no location permission involved |
| Voice foreground service | `FOREGROUND_SERVICE` | `FOREGROUND_SERVICE_CONNECTED_DEVICE` (API 34+) | type `connectedDevice` is API 29+ |
| Notifications | channel required (26+) | `POST_NOTIFICATIONS` runtime (33+) | denial degrades the FGS to an invisible service; record it, do not crash |
| Audio playback | no permission | no permission | `AudioTrack` + focus |
| Microphone | `RECORD_AUDIO` (not declared today) | same | **not used by the TonoLink voice path** (the board records); only a future phone-mic input would add it |

### 5.2 Background scanning, Doze and app standby

- An unfiltered BLE scan is suspended with the screen off; Doze and app-standby further defer work. The
  contract's "scan only from a visible page" (`android-ble-discovery.md`) is therefore also the only
  reliable scan.
- Android 12+ forbids starting a foreground service from the background; a scan result or a BLE
  notification cannot start one. A voice/reconnect service must be started while the user is in the
  app, then kept running.
- `connectGatt(..., autoConnect = true)` lets the controller reconnect when the device advertises
  again, but the app cannot observe presence first, and callback timing differs. Whether that is an
  acceptable substitute for rule 6's "present" gate is a contract decision (CCR-1), not an
  implementation choice.
- OEM battery managers (Xiaomi/Huawei/OPPO/…) kill foreground services and drop BLE; nothing in this
  plan promises otherwise. Device evidence must name the OEM and the outcome.

### 5.3 Foreground services

| Type | Constant | Permission (34+) | Suitable for | Limit |
| --- | --- | --- | --- | --- |
| `dataSync` | `FOREGROUND_SERVICE_TYPE_DATA_SYNC` | `FOREGROUND_SERVICE_DATA_SYNC` | the existing turn window | Android 15: 6 h per 24 h |
| `connectedDevice` | `FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE` | `FOREGROUND_SERVICE_CONNECTED_DEVICE` | BLE link, voice wake, secure session | no time cap |
| `mediaPlayback` | `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK` | `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | continuous TTS playback | no time cap |
| `microphone` | `FOREGROUND_SERVICE_TYPE_MICROPHONE` | `FOREGROUND_SERVICE_MICROPHONE` | phone-mic capture (not this plan) | while-in-use rules |

The existing `:dsh` background surface declares a `dataSync` service with `stopWithTask="true"`
(`android/dsh/src/main/AndroidManifest.xml`). The voice service must **not** reuse `dataSync`: its
6-hour cap would end a day-long wake link, and its semantics ("a turn window") are wrong. Use
`connectedDevice`, and only add `mediaPlayback` if playback outlives the BLE link. The manifest owner
for the new service is a P08 decision (§7).

### 5.4 Bonding, encryption and L2CAP CoC

- The current Android slice does not bond (`android-standard-gatt.md:39`) and reports an
  insufficient-authentication/encryption read as a visible failure.
- The reference firmware's Link ingress is specified as encrypted + bonded (ble-link.md line 31:
  "参考固件接受加密 + bonded 链路"; PC-20261107-android-gatt-ccr states it requires one). If Android is
  to use it, bonding becomes a precondition; `ACTION_PAIRING_REQUEST` (PIN/passkey) and
  `ACTION_BOND_STATE_CHANGED` must be handled, and a denied/cancelled pairing is a user-visible
  failure, not a retry loop.
- **Bond state is not link encryption.** `getBondState()` says a key exists; it does not prove the
  current connection is encrypted. GAP-20 says the public encryption-status API is not available across
  this app's minimum API level; do not infer a security claim from `BONDED`.
- **LE CoC**: `BluetoothDevice.createL2capChannel(psm)` (secure; "the remote device will be authenticated
  and communication on this socket will be encrypted") and `createInsecureL2capChannel(psm)` were both
  added in API 29. There is no "encrypted but not authenticated" variant, which is the closest analogue
  to Apple's CoC. Both return a `BluetoothSocket` with blocking streams; the caller must move bytes off
  the main thread. See the AOSP
  [BluetoothDevice.java](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/tags/android-14.0.0_r20/framework/java/android/bluetooth/BluetoothDevice.java).
- With `minSdk = 26`, API 26–28 have **no CoC**: the secure session is unavailable there and must say
  so, never downgrade.

### 5.5 Audio focus, routing, SCO and the microphone

- The voice turn only *plays* cloud TTS. Use `AudioTrack` in streaming mode with
  `AudioAttributes(USAGE_MEDIA, CONTENT_TYPE_SPEECH)` and an `AudioFocusRequest` (API 26+) with
  `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`; abandon on turn end, stop on focus loss. `TextToSpeech` stays
  the mechanism for the chat "read aloud" button (`MainActivity.kt:209`, `:289`); it is not the cloud
  voice path.
- **No AirPlay on Android.** The iOS speaker override exists because the board is an AirPlay sink that
  discards audio. Android has no AirPlay sender, so the board never becomes the audio route; media goes
  to speaker/headphones/A2DP by normal routing. Do not port the `PhoneAudioSessionLease` speaker claim.
- **SCO is not needed.** SCO is the narrow-band communication route (`startBluetoothSco`, deprecated in
  API 31, replaced by `setCommunicationDevice`); the voice turn is playback-only and the board records.
  Adding SCO would route audio *to* a headset, not solve anything.
- **Microphone in the background**: Android 11+ denies while-in-use microphone access to background
  apps unless a `microphone`-typed FGS is running (and Android 14 restricts starting that type from the
  background). The TonoLink design avoids this entirely by recording on the board. A future phone-mic
  voice input is a separate capability with its own contract; do not smuggle it into this plan.

### 5.6 GATT write-callback identity (GAP-20 core)

At `android-14.0.0_r20`, `BluetoothGattCallback` declares:

```java
public void onCharacteristicWrite(BluetoothGatt gatt,
        BluetoothGattCharacteristic characteristic, int status) { }
```

There is a value-carrying overload for reads
(`onCharacteristicRead(gatt, characteristic, byte[] value, int status)`) and for notifications
(`onCharacteristicChanged(gatt, characteristic, byte[] value)`), but **not for writes**. The dispatcher
in `BluetoothGatt.java` calls exactly that three-argument method. So the callback carries no bytes and
no application token; the GATT object identifies the connection generation, not the write.

Two consequences the plan relies on:

1. The `token` in `android-link-channel.jsonl` and in `BleLinkChannel.writeComplete(...)` is supplied by
   the **adapter**, not by the OS. A test that always supplies the right token proves the state machine,
   not the platform (this is the draft CCR's own warning).
2. Any adapter model must either (a) document a platform limitation and fail closed on ambiguity
   (close the connection when a callback cannot be attributed), or (b) cite a documented OS guarantee
   that identifies the write — the public API has none today. The frozen contract must pick one, and
   the choice must be testable with duplicate/stale/disconnect cases.

Source: [BluetoothGattCallback.java](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/tags/android-14.0.0_r20/framework/java/android/bluetooth/BluetoothGattCallback.java),
[BluetoothGatt.java](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/tags/android-14.0.0_r20/framework/java/android/bluetooth/BluetoothGatt.java).

### 5.7 Storage and durability

- Secrets: `AndroidSecureStore` (AndroidKeyStore AES-GCM, `noBackupFilesDir`) already backs the ADB
  identity and API keys; reuse it for MCP credentials and the phone key (§3.3/§3.8).
- Device-task journal: `FileChannel.force` on a **directory** is not supported on Linux/Android, while
  `task-delegation.md` requires "a synchronized file and directory" before accept/prompt/terminal. The
  implementer needs a native helper (JNI) or a frozen deviation (D-10). Do not silently drop the
  directory sync.
- Trust memory: iOS uses `UserDefaults` dictionaries; Android has no equivalent typed plist. A
  `SharedPreferences` JSON value is the natural choice, but the key names and the value format are a
  contract decision (CCR-1), not an implementation detail — P18 says persisted key names are protocol.

### 5.8 HTTP, TLS and WebSocket stack

- HTTP is `java.net.HttpURLConnection` everywhere in this tree (`TonoAccountSession`, the gateway
  transport, the model proxy). There is no OkHttp, no Ktor client and no `java.net.http` on Android.
- TLS is the platform `SSLSocket`/`HttpsURLConnection` stack. A pin is enforced by a custom
  `X509TrustManager` installed through an `SSLSocketFactory`; hostname verification must stay on
  (`HttpsURLConnection.getDefaultHostnameVerifier()`), never replaced with a permissive verifier.
- ALPN (`SSLParameters.setApplicationProtocols`, `SSLSocket.setHandshakeApplicationProtocolSelector`) is
  API 29+, which coincides with the CoC floor for the secure session but not with `minSdk`.
- **No WebSocket client.** The ASR `wss://` endpoint of `cloud-voice.md` §2 needs either a minimal RFC 6455 client
  over `SSLSocket` or an approved dependency (AGENTS.md §6: a new dependency needs a concrete gap and
  an owner). The plan prefers the minimal client because the ASR subset is small and the shared
  `cloud-voice/cases.json` can drive it.
- Pinning across the two consumers (LAN MCP and the task inbox) must be one trust component, not two
  (shared by the Worker MCP native egress and the task inbox, per `lan-mcp.md` §"TLS trust model").

### 5.9 What "device evidence" means in this plan

A JVM test proves a state machine; it does not prove a radio, a lifecycle, an audio route or a TLS
handshake. Every checkpoint marked **Device? yes/must** above needs a record with: device model, API
level, OEM build, board firmware commit, the exact scenario, the observed result, and the limits
(e.g. "screen off, 10 minutes, no wake delivered"). Rows that were not run are recorded `NOT_RUN`, never
omitted.

---

## 6. Contract change requests and spec deltas

### CCR-1 — Android trusted connected devices (rule 6 scope and storage)

```
CONTRACT CHANGE REQUEST
Contract: P07 @ 56e7b6ce   Clause: spec/device/v1/ble-link.md §"持久化、重连和权限" rule 6
Problem: Rule 6 is titled "受信任的已连接设备（iOS App）" and its body is written entirely in
  CoreBluetooth/UserDefaults terms: `phone-dsh.ble.revoked-grants.v1`,
  `phone-dsh.ble.remembered-boards.v1`, `retrievePeripherals`, `didConnect`, `CBPeripheral.state`,
  the two system-connected exceptions (GAP-37). Android has no CoreBluetooth, no peripheral UUID,
  and no plist. Implementing the same user-visible behaviour on Android would require inventing a
  key name, a value format and a "present" test not in any contract (AGENTS.md §2.1/§2.7).
  Android also has no clause that says whether the Android app is allowed to trust a connected board
  at all: android-standard-gatt.md §Grants says its two switches gate only manual buttons and that
  "no agent tool is exposed".
Proposal: Add "§ Android trusted connected devices" to ble-link.md with:
  (a) the same decision ("connect = trust; a switch off is a remembered revocation") and the same
      "never execute or replay automatically" rule;
  (b) Android storage: key names and value format (JSON in app-private SharedPreferences, suggested
      `phone-dsh.ble.revoked-grants.v1` / `...remembered-boards.v1`, with the Android value's
      `deviceKey` = Link device ID for tools and opaque scan id for `@read`/`@alert`);
  (c) the "present" test: scan-advertised only, or `autoConnect=true` with the documented loss of the
      gate; and the system-connected-board rule (adopt or not; GAP-37 applies only to iOS today);
  (d) default `trustConnectedDevices = false` for the library, app sets true, mirroring iOS.
  Keep the iOS clause unchanged. No wire change.
Affects: P07 (Android), P09 (Bluetooth page rows/copy), P18 (Android key names/format), roadmap §"BLE 信任/重連".
```

**Why now:** 2A.3 cannot be reviewed without it, and the alternative (copying iOS keys into
`SharedPreferences` with a JSON value) is exactly the kind of unrecorded platform branch AGENTS.md
forbids.

### CCR-2 — `ble-link.md` still calls Android standard GATT `target`

```
CONTRACT CHANGE REQUEST
Contract: P07 @ 56e7b6ce   Clause: spec/device/v1/ble-link.md §"iOS standard GATT authorization ordering", last sentence
Problem: The sentence "Android standard GATT remains target." contradicts
  spec/device/v1/android-standard-gatt.md:3 ("Status: `implemented` for the Android app's Bluetooth
  devices page") and the change record PC-20261107-android-ble-standard-gatt (status implemented).
  A reader following ble-link.md would conclude the read/alert slice is not shipped; a reader
  following android-standard-gatt.md would conclude it is. The roadmap and the page contract
  currently disagree with one of them.
Proposal: Replace the sentence with what is actually still target on Android — Link, Link tools,
  authorization/trust, device identity, bonding, task intake, agent tool exposure — and point at
  android-standard-gatt.md for the shipped read/alert slice. No behaviour change.
Affects: P07 status claims, spec/README P07 row, roadmap capability table.
```

### CCR-3 — Freeze the Android GATT adapter ownership model (existing draft CCR)

```
CONTRACT CHANGE REQUEST
Contract: P07/P08 @ 56e7b6ce   Clause: docs/protocol-changes/PC-20261107-android-gatt-ccr.md
Problem: GAP-20's close condition requires this CCR to be frozen before an adapter exists; it is
  `status: draft`, `contract_revision: pending`, `version_decision: pending`. The plan's 2A.1/2A.2
  checkpoints and every Link/trust/task path sit behind it. The draft correctly says that a fake
  callback carrying the right token proves nothing about the OS, and that bond state is not
  encryption evidence.
Proposal: Freeze, at minimum:
  (a) the adapter's write-attribution rule (what a duplicate/stale callback may do; whether the
      adapter closes the connection on ambiguity) and the same rule for CCCD descriptor writes;
  (b) the connection-generation and teardown rules on Android (when a `BluetoothGatt` may be closed,
      when a late callback is ignored, what `close()` proves);
  (c) the bonding policy for the reference firmware and the exact security claim allowed (bond ≠
      encryption; what the adapter may say on failure);
  (d) the adversarial test matrix: duplicate callback, stale callback after reconnect, callback after
      close, write error, disconnect mid-write, and the "no token" limitation recorded rather than
      simulated away.
  Then record shared fixtures (a new Android adapter golden or an extension of
  android-link-channel.jsonl) and the API 26–35 permission story.
Affects: P07/P08, Android adapter, Link, trust, secure session, tasks; iOS unaffected.
```

### CCR-4 — Android transport for `secure-session-v2.1`

```
CONTRACT CHANGE REQUEST
Contract: P07 @ 56e7b6ce   Clause: spec/device/v1/ble-secure-session.md §5 (transport), §6.1 (TLS profile), §8.2 (phone)
Problem: The contract's "phone" is "the iOS app (TLS client)" (§"Key words") and its transport section
  assumes Apple's L2CAP CoC. On Android:
  - LE CoC exists only from API 29; minSdk is 26, so two supported OS levels can never run the
    session. The contract has no "unavailable on this OS level" statement for a phone.
  - Android offers a *secure* CoC that requires an authenticated link key (bond) and an *insecure*
    one that may be unencrypted. The contract says the board SHOULD require LE encryption when
    bonded but never says which variant a phone uses or what it may claim; "bond" and "encryption"
    are not the same thing on Android (GAP-20).
  - §6.1 requires an exact TLS profile (P-256 only, no HelloRetryRequest, one signature scheme).
    Android's platform TLS stack does not expose all of those knobs across API 26–35, so a
    conformant client may have to implement TLS 1.3 itself. The contract allows only "any deviation
    fails", which is implementable but must be acknowledged as a from-scratch TLS client, not a
    configuration.
Proposal: Add an Android transport paragraph: API 29 floor with an explicit "secure session
  unavailable" result on 26–28; which CoC variant is used and that link encryption/bonding is never
  a trust decision; and a statement that an end which cannot express §6.1 with its platform stack
  must implement the profile itself (as iOS did) and prove it with the §13 matrix. No wire change.
Affects: P07 Android, GAP-16 closure evidence, §13 fixture table (Android column/rows), §14 acceptance
  (add an Android phone run or record `NOT_RUN` per row).
```

### 6.5 Spec deltas requested (no contradiction, but not yet written)

| ID | Where | Delta | Owner |
| --- | --- | --- | --- |
| D-3 | `spec/device/v1/golden/` + schema | shared trust/reconnect fixture for the Android state machine | P07 + gate owner |
| D-5 | `legacy-identity-preferences.md` | "not applicable on Android; no key is created" note | P07/P18 |
| D-8 | `ble-secure-session.md` §13 | Android column/rows for fixtures and the conformance matrix | P07 |
| D-10 | `task-delegation.md` §"Phone journal format" | Android durability equivalent (directory sync, lock) | P06/P07 |
| D-11 | `task-delegation.md` | Android end registration + "no grant before GAP-16" statement | P06/P07 |
| D-12 | `tonolink-board.md`, `cloud-voice.md` | register Android consumers; Android background statement; API floor | P07/P05 |
| D-13 | `spec/platform/` + whitelist | Android audio/FGS note; update `platform.tonolink-voice-background-wake` mechanism/evidence | P08 |
| D-16 | `tonolink-board.md` §2 | Android USB OTA transport note (NCM, no AirPlay) — only if 0E.1 passes | P07 |
| D-18 | P18 (settings) | Android MCP credential/grant storage and injection | P18/P05 |
| D-19 | `lan-mcp.md` §"TLS trust model" | pin enrollment bundle + shared vectors (required before any pin path) | P07 |
| D-21 | `spec/platform/whitelist.json` + the Android ADB tool layer | either narrow the `platform.tonolink-iphone-agent` capability or provide §6-equivalent guard semantics on Android | P08/P07 |

### 6.6 Open questions

- **Q-1 (durability).** Does the task journal's "synchronized directory" requirement have an Android
  equivalent without a native helper? If not, D-10 must state the deviation. Owner: P06/P07.
- **Q-2 (voice parity).** Is "wake works only while the voice foreground service runs" an acceptable
  Android parity statement, or does the product require a stronger always-on claim that Android
  cannot honestly make? Owner: product + P07/P08. The whitelist wording currently implies the former.
- **Q-3 (reconnect).** Scan-gated explicit connect (iOS-shaped) versus `autoConnect = true` (Android
  native). This is CCR-1(c); do not let the first implementer decide it by accident.

---

## 7. Needed outside my scope

I own only `docs/design/android-device-port-plan.md`. The following changes are required for this plan
but belong to other owners/paths. Each is a request, not a change made here.

1. **Contract owner (P07/P05/P06/P08):** CCR-1…CCR-4 and the deltas in §6.5; the new
   `android-ble-trust.jsonl` (+ schema) and the Android rows/columns in the secure-session fixture
   table; the status/registration lines for TonoLink voice and cloud voice; the `ble-link.md:95`
   correction.
2. **Gate owner:** register any new golden and each new Android consumer in `spec/tools/cross_check.py`
   (the pair list around lines 100–130) and in `spec/README.md` §3/§4. New goldens are not "done" until every
   consumer is registered.
3. **P12 native ABI:** the `home.http` policy binding. Preferred: compile the vendored
   `xl_home_policy.c` (`firmware/components/pdsh_home/vendor`) into the Android native library and
   expose it through JNI, so both ends run one policy. Fallback: a Kotlin port validated against the
   upstream policy tests plus new shared vectors. Adding a C source to the Android build is a P12
   change (`android/**/CMakeLists.txt`, JNI surface).
4. **P13/P18:** the MCP save path and credential store (3D.1). The remote-call mechanism already
   exists (`DshTurnClient.call`, used by `HostAutomation` for `phone/createSchedule`); what is missing
   is the MCP page wiring, the exact-URL grant, host-managed headers (`headersFromEnv` equivalent) and
   the `:lib` editor's `writable` fact (`HostNavFacts.kt:281`).
5. **P08:** decide where the voice foreground service lives (`:dsh` background package vs `:app`) and
   add the manifest type/permission and the whitelist entry update. The existing `dataSync` service
   must not be reused.
6. **P09:** the Bluetooth page contract for the Android trust/reconnect states. The iOS strings
   `正在等待系统断开，暂不可重连` and `连接状态无法确认，暂不可用` (ble-link.md §"iOS standard GATT
   authorization ordering") have no Android rows yet; `page_structure_check.py` must stay at its
   existing baseline (do not add whitelist lines).
7. **Firmware/board owner:** a reference board for wave-2 Link/trust and wave-3 secure-session runs;
   the firmware side of `secure-session-v2.1` is already library code but not enabled (§14).
8. **Android README/structure owner:** `android/README.md` status cells and
   `spec/platform/android-module-map.json` (`PhoneDSHBLE`/`PhoneDSHLAN` `target`;
   `PhoneDSHDeviceTasks` `absent`). These are gate-checked (`phone-android-structure`), so they change
   only after the corresponding code lands, in the same PR.
9. **`HostShell.kt` MCP strings** (3D.1) — the stale "no `phone/mcpUpsert` tool" text; owned by the
   MCP page implementer, not by this document.

---

## 8. Verification and evidence plan

### 8.1 Commands

| Purpose | Command | Result meaning |
| --- | --- | --- |
| Contract/spec edits | `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | PASS = specs, schemas, goldens, registry consistent; not runtime conformance |
| Android JVM (domain) | `bash android/tools/with-android-toolchain.sh ./gradlew --no-daemon :domain:testDebugUnitTest` | real Kotlin state machines/codecs against on-disk goldens |
| Android JVM (app/lib/dsh/net) | `bash android/tools/with-android-toolchain.sh ./gradlew --no-daemon :app:testDebugUnitTest :lib:testDebugUnitTest :dsh:testDebugUnitTest :net:testDebugUnitTest` | app tests need the Rust JNI build first (below) |
| Rust JNI prerequisite | `bash android/tools/with-rust-toolchain.sh cargo build --locked --manifest-path shell/Cargo.toml -p pdsh-jni` | SKIP/INCOMPLETE without cargo is never PASS |
| Aggregate Android gate | `bash scripts/ci/check.sh --only phone-android-tests` | runs the JVM suites; does not prove a device |
| Android structure | `bash scripts/ci/check.sh --only phone-android-structure` | module map, readme map, 16 KB gates |
| Instrumented (device) | `bash android/tools/with-android-toolchain.sh ./gradlew --no-daemon :app:connectedDebugAndroidTest` (and `:dsh:connectedDebugAndroidTest`) | requires a connected device; `NOT_RUN` otherwise |
| iOS reference (provenance only) | `swift test --filter 'PDSHLinkTests\|BLEDeviceMCPTests\|StandardBLETests\|TonoLinkVoiceTests'` and `swift test --filter 'PhoneDSHTests.CloudVoiceTests'` | confirms the iOS consumer still matches the shared fixtures; not an Android result |
| Firmware host tests (board-side reference) | `bash firmware/tests/run.sh` | C wire/policy tests; not a radio test |

Notes:

- `:app` tests build the Rust JNI library first (lessons.md §6). A missing cargo is `SKIP/INCOMPLETE`,
  never `PASS`.
- `:lib` is the published UI module; page contracts are checked by `page_structure_check.py` (P09),
  which is not an Android runtime test.
- The reference iOS tests are *provenance*: they show the same fixture is consumed by the other end.
  They do not upgrade an Android row.

### 8.2 What can only be `NOT_RUN` on JVM

| Area | Why | Where it is recorded |
| --- | --- | --- |
| Radio callback order, duplicate/stale write callbacks, post-close callbacks | no OS token; only a real controller produces them | 2A.1 device run |
| Bonding / pairing prompts / encrypted vs unencrypted link | needs a peripheral that requests encryption | 2A.1/2A.2 |
| Screen-off wake, Doze, OEM kill | lifecycle/radio | 3A.3 |
| Foreground-service type acceptance, notification visibility, start-from-background refusal | platform policy | 3A.2 |
| Audio focus, route (speaker/A2DP), `AudioTrack` drain | device audio HAL | 3A.2 |
| L2CAP CoC open/limits and TLS handshake with the board | needs both ends | 3B.3–3B.5 |
| USB NCM reachability | kernel/OEM | 0E.1 |
| LAN discovery on real Wi-Fi / real device TLS | network stack | 3D.1 |
| Secure-session §14 physical runs | acceptance | 3B.5 |

### 8.3 Device matrix (minimum)

| Slot | Requirement | Why |
| --- | --- | --- |
| A | API 26–28 phone | proves the "no CoC → secure session unavailable" path and the legacy permission path |
| B | API 29–33 phone | CoC + `connectedDevice` FGS + `BLUETOOTH_SCAN`/`CONNECT` |
| C | API 34–35 phone | FGS type permissions, `POST_NOTIFICATIONS`, dataSync limits |
| D | one OEM with aggressive battery management (if available) | honesty about Doze/OEM kills |
| Board | reference ESP32-S3 with the Link firmware and the secure-session firmware (for 3B.5) | the only end that can accept Link/secure traffic |
| LAN | reference `examples/lan-mcp-device` on a Mac | LAN E2E |

No slot means the corresponding row is `NOT_RUN`; it does not mean "probably fine".

### 8.4 Evidence record format

For each checkpoint, append to the PR (not to this file):

```
Checkpoint: 2A.1
Device: <model>, API <n>, build <fingerprint>, OEM <vendor>
Board: <name>, firmware <commit>
Scenario: <one line>            Fixture: <golden path or "device-only">
Command / steps: <exact>
Observed: <what the log/UI showed>
Result: PASS | FAIL | NOT_RUN
Limits: <what was not exercised>
```

### 8.5 What was actually run for this document

This is a documents-only change: one new file under `docs/design/`, no product code, contract, schema
or fixture. No stage in `bash scripts/ci/check.sh --list` covers `docs/design/**`, so no product check
is claimed.

| Check | Command | Result at this head |
| --- | --- | --- |
| repository consistency (untouched paths) | `bash scripts/ci/check.sh --only phone-cross-tree` | **PASS** (22 s; 8/8 invariants, registry byte-identical, 91 tests OK) |
| links and paths in this file | local Python scan of every Markdown link target | **PASS**: 15 targets, 0 missing; the only unresolved backticked paths are the proposed `.../` files in Appendix C |
| whitespace | `git diff --check` | **PASS** |
| public-repo hygiene | `bash scripts/ci/check.sh --only phone-hygiene` | **FAIL — pre-existing**: 357 findings at base `56e7b6ce` and the same 357 after this file; none are in this file (checked explicitly). Not fixed here (lessons.md §3). |
| Android JVM / instrumented / iOS / firmware suites | — | **NOT_RUN** (no code changed; nothing in this file can be proven by them) |

The handoff for the task repeats these results in the AGENTS.md §3.5 form.

---

## 9. Risks and open questions

| ID | Risk | Impact | Mitigation / owner |
| --- | --- | --- | --- |
| R1 | A from-scratch Android TLS 1.3 client is security-critical and large (≈ 1,800–2,800 lines) | 3B.3 slips or ships a subtle bug | independent review (`ble-secure-session.md` §15), loopback conformance rows first, no enablement before §14; P07 + security reviewer |
| R2 | GAP-20 may not be freezable in the form the draft proposes (no OS write token) | Link/trust/tasks stay `target` on Android indefinitely | the frozen rule must allow a documented fail-closed limitation (CCR-3); do not fake a token in production |
| R3 | Android background guarantees are weaker than iOS's `bluetooth-central` | voice wake parity is partial; Doze/OEM kills | FGS `connectedDevice`, explicit user-visible state, honest whitelist wording; device evidence per OEM |
| R4 | USB NCM may not be reachable on many phones | HID/OTA paths are dead there | 0E.1 measurement first; do not promise OTA |
| R5 | Cross-team dependencies (P12 policy binding, P13/P18 MCP store, P08 FGS location) | checkpoints stall in "waiting" | named in §7; start the paper work in parallel with C0 |
| R6 | Stale contract lines (CCR-2, rule 6's iOS-only title) mislead implementers | someone implements a platform branch and calls it parity | CCR-1/CCR-2 before code; reviewers cite this file |
| R7 | Test-only tokens mistaken for OS guarantees (the draft CCR's warning) | a green JVM suite hides a real ambiguity | device cases in 2A.1; `NOT_RUN` honesty |
| R8 | No reference board available during wave 2 | Link/trust acceptance stalls at "JVM only" | book the board before 2A.1; record `NOT_RUN` meanwhile |
| R9 | Golden/consumer registration forgotten for new Android fixtures | gate stays green while parity is unproven | §7 item 2; `cross_check.py` pair list |
| R10 | The roadmap says "BLE trust/reconnect wave 2" and a reader skips C0 | code starts without a frozen rule | §2 and D1; reviewers reject a 2A.3 PR without the C0 revision |

---

## Appendix A — iOS consumer inventory (measured at `56e7b6ce`)

| Group | Files | LOC |
| --- | --- | --- |
| BLE core | `BLEDeviceStore.swift` 2,435; `StandardBLE.swift` 61; `PDSHLink.swift` 188; `BLELinkChannel.swift` 101; `BLEIdentity.swift` 143; `BLEDeviceTrustMemory.swift` 57; `BLEDeviceTaskInbox.swift` 43; `DeviceMCPServer.swift` 171; `HomeHTTPPolicy.swift` 50; `LinkToolJournal.swift` 50 | 3,299 |
| Secure session | `SecureSession/*.swift` (18 files) | 4,104 |
| TonoLink | `TonoLink*.swift` (11 files) | 2,717 |
| Cloud voice | `Sources/PhoneDSH/CloudVoice/*.swift` | 432 |
| UI-Venus | `Sources/PhoneDSHVenus/*.swift` | 1,001 |
| Device tasks | `Sources/PhoneDSHDeviceTasks/*.swift` | 2,130 |
| LAN | `Sources/PhoneDSHLAN/*.swift` | 168 |
| App hosts | `TonoLinkVoiceHost.swift` 510; `IPhoneAgentHost.swift` 405 | 915 |
| **Total (device-facing)** | | **≈ 14,766** |

## Appendix B — Fixtures a port must consume (and who consumes them today)

| Fixture | Rows / shape | iOS consumer | Android consumer today |
| --- | --- | --- | --- |
| `golden/xiaozhi-ctl.jsonl` | 165 | `PDSHLinkTests` | `BleLinkCodecTest` |
| `golden/pdsh-link.jsonl` | 6 | `PDSHLinkTests` | `BleLinkCodecTest` |
| `golden/invalid-ctl.jsonl` | 3 | `PDSHLinkTests` | `BleLinkCodecTest` |
| `golden/android-link-channel.jsonl` | 12 scenarios | — | `BleLinkChannelTest` |
| `golden/standard-gatt-decode.jsonl` | 34 | `StandardGATTDecodeVectorTests` | `StandardBleProfileTest` |
| `golden/ble-scan-intent.jsonl` / `-mutations` | 14 / 22 | `BLEScanIntentTests` | `BleScanMachineTest` (app) |
| `golden/standard-gatt-status-order.jsonl` | 10 | `BLEStatusOrderingTests` | — |
| `golden/standard-gatt-grant-order.jsonl` | 50 | `StandardGattGrantOrderingTests` | — |
| `golden/standard-gatt-discovery-ownership.jsonl` | 66 | `StandardGattDiscoveryOwnershipTests` | — |
| `golden/standard-gatt-discovery-deadline.jsonl` | 19 | `StandardGattDiscoveryDeadlineTests` | — |
| `golden/standard-gatt-service-change.jsonl` | 22 | `StandardGattServiceChangeTests` | — |
| `golden/ble-task-plaintext-admission.jsonl` | 10 | `BLESecureFixtureTests` | — (must be a negative case in 2A.2) |
| `golden/tonolink-voice.json` | 16 events, 2 commands, 8 packets | `TonoLinkVoiceTests` | — (2B.1) |
| `spec/v1/golden/cloud-voice/cases.json` | 11 constants, 9 credentials, 16 messages, 7 transcripts, 5 speakable, 4 chunk cases | `CloudVoiceTests` | — (2B.2) |
| `golden/ble-secure-*.jsonl` (12 files) | see `ble-secure-session.md` §13 | `BLESecure*Tests` | — (3B) |
| `golden/task-*.jsonl`, `ble-task-*.jsonl` | see `task-delegation.md` | `DeviceTask*Tests` | — (3C) |
| `golden/lan-discovery*.jsonl`, `lan-publication.jsonl` | 9 / 31 / 29 / 23 | `LANAdvertisementTests` | `LanDiscoveryDecoderTest`, `LanMdnsBrowserTest` |

Empty "Android consumer" cells are work, not permission to copy a fixture into Kotlin (lessons.md §4:
read the shared file from disk, drive the real code).

## Appendix C — Proposed Android file map (nothing here exists yet)

| Checkpoint | Proposed path | Kind |
| --- | --- | --- |
| 2A.1 | `android/domain/src/main/kotlin/com/phonedsh/domain/connector/ble/BleGattOwnership.kt` | pure state machine (JVM) |
| 2A.1 | `android/app/src/main/kotlin/com/phonedsh/probe/AndroidBleGatt.kt` | platform adapter |
| 2A.2 | `android/domain/.../connector/ble/BleLinkClient.kt`, `HomeHttpPolicy.kt` | pure client/policy |
| 2A.2 | `android/app/src/main/kotlin/com/phonedsh/probe/AndroidBleLink.kt` | wiring |
| 2A.3 | `android/domain/.../connector/ble/BleTrustMemory.kt`; `android/app/.../AndroidBleTrustStore.kt` | policy + storage |
| 2A.4 | `android/app/.../AndroidBleHost.kt` | native MCP composition |
| 2B.1 | `android/domain/.../tonolink/TonoLinkVoice.kt` | codec |
| 2B.2 | `android/net/.../voice/CloudAsr.kt`, `CloudTts.kt`, `Speakable.kt` | network |
| 3A.1 | `android/app/.../AndroidTonoLinkCtrl.kt` | platform adapter |
| 3A.2 | `android/dsh/.../background/VoiceForegroundService.kt` (P08 decides) + `:app` binding | service |
| 3A.3 | `android/app/.../TonoLinkVoiceHost.kt` | turn state machine |
| 3B.* | `android/domain/.../secure/**`, `android/app/.../AndroidBleSecure.kt`, enrollment UI | library + adapter + UI |
| 3C.* | `android/domain/.../devicetask/**` or `android/dsh/.../devicetask/**`; `android/net/.../device/` | journal/executor/inbox |
| 3D.1 | `android/app/.../HostMcp*.kt`; `:net`/`:dsh` secret injection; `:lib` MCP editor | wiring |
| 3D.2 | `android/net/.../lan/PinnedTrust.kt` | trust |
| 3E.1 | `android/app/.../TonoLinkUSB*.kt` | conditional |
