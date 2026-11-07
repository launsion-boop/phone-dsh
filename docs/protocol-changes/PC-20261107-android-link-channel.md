# Android ordinary Link channel state machine

```yaml
change: PC-20261107-android-link-channel
contracts: [P07]
status: frozen
breaking: false
version_decision: Existing Link Tools v1 unchanged; Android channel is target-only and has no production caller.
base: f09fcf7b1c5290bf792eb2492ce765e5d4c3033d
contract_revision: spec/device/v1/ble-link.md@sha256:2c1c5b45ce92045e92f40489d6bceadf32a7c53e4ae5b1362182c5af005b97e5
```

## Trigger and scope

Android has a target-only Link wire codec but no connection state machine. The
frozen delta in `ble-link.md` specifies the bounded ordinary-Link channel,
serial writes, negotiation and loss behavior without changing any wire bytes.
It is a platform adaptation of the Swift `BLELinkChannel` and reference C
wire/profile; the task profile remains target and MUST NOT be called. No GATT
adapter, permissions, user grant, journal, automatic reconnect or device task
intake is added by this change. Protocol impact: P07.

The channel uses the unchanged wire framing, HELLO, tool negotiation, request
IDs, timeouts, event and no-replay rules in the owning profile. The transport
provides a generation and unique identity for each outstanding write callback;
callbacks for a previous generation or previous write cannot advance the current
channel. An early matching response is retained until the corresponding final
write callback succeeds. The timeout is provided from a monotonic clock by a
future adapter; it must enforce the existing three-second exchange deadline.
Malformed input, timeout, cancellation or transport failure closes the channel;
an operation that started has unknown outcome. Explicit NAK is a distinct remote
response. A rejection because not ready, busy, ID exhausted or tools unsupported
never writes. New channel generation resets the reassembler and ID scope.

## Fixtures and compatibility

The shared valid/invalid transition scenarios and their schema are
`spec/device/v1/golden/android-link-channel.jsonl` and
`spec/device/v1/schema/android-link-channel-vector.schema.json`. Each `in` is
a state-machine input and `out` is the ordered list of externally observed
effects. The test harness uses the real codec for all writes and notifications:
`open` sends HELLO after both subscriptions; `write_ok` acknowledges the
outstanding write, `stale_write_ok` uses an older write identity, and
`write_error` fails the outstanding write. `hello_ack_tools` and
`hello_ack_legacy` are valid ACKs with and without the negotiated extension.
`status` sends opcode 0x02; `tool` attempts opcode 0x54. `status_response`
uses the current ID/opcode 0x82; wrong ID/opcode must not complete it. `event`
uses 0x6c/ID 0, `nak` 0xff/current ID, and `bad_crc` corrupts an otherwise
valid current response. `timeout` and `cancel` affect the current operation.
All scenarios use characteristic value length 244; additional tests must cover
fragmented writes at 20, response before final write callback, overlapping
requests, exhaustion, disconnect/reset and stale generation callbacks. Shared
ctl bytes are `xiaozhi-ctl.jsonl`, `pdsh-link.jsonl`, `invalid-ctl.jsonl`.

Old device → new Android: old HELLO remains accepted; without complete Tools
negotiation the new opcodes cannot be sent. New device → old phone and new →
new: wire behavior is unchanged. No on-disk format or existing producer changes;
old data and rollback are unaffected. Swift and C remain unchanged and must run
their existing shared wire-vector tests. The target state machine has no
production caller; a separately frozen transport, grants and persistent recovery
are needed before a feature is enabled.

## Ownership and acceptance

Coordinator exclusively owns `spec/**` and this record. Android implementer
owns only `android/domain/src/main/kotlin/com/phonedsh/domain/connector/ble/`
and matching test directory. Acceptance: `cd android && ./gradlew
:domain:testDebugUnitTest --tests '*BleLink*'`; `swift test --filter
'PDSHLinkTests|BLEDeviceMCPTests|StandardBLETests'`; `bash firmware/tests/run.sh`;
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Integrator reviews one combined head and records results. Android GATT, radio,
phone and ESP32 hardware remain NOT_RUN unless actually tested.

## Revision 2 — handshake NAK and premature response

The Android implementer reported that HELLO NAK had no specified terminal
state and that an early response might arrive before the final segment was
ever sent. A HELLO NAK now emits NAK then Disconnect and closes without an
Unknown effect; a matching response or NAK before the final segment has been
sent closes with Unknown and Disconnect. An early response after the final
segment has been sent still waits for its successful write callback. The shared
fixture adds the HELLO NAK case; the real Android channel test must cover the
premature multi-segment response and NAK cases. No wire format or existing
Swift/C producer changes. Android implementer notified at revision 2.
