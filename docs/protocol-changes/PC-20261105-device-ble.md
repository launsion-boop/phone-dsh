# BLE Link import into phoneDSH

```yaml
change: PC-20261105-device-ble
contracts: [P05, P07, P09, P12, P18]
status: frozen
breaking: false
version_decision: Existing xiaozhi-link 1.2 framing and explicitly negotiated PDSH Tools v1; P07 host contract 1 unchanged.
base: 8ab1dde58abd21b5d057e995afd3cd1d93ba8e6f
contract_revision: spec/device/v1/ble-link.md@929361da4d3922b7ab78082f5d93bbeced2ec2e9
```

## Trigger and ownership

The current app has no BLE device adapter. Import the existing PDSH Link profile, reference firmware and authenticated native MCP tools from `e76cecd4` without replacing the Android MCP server. The coordinator is the contract owner, implementer and integrator. Protocol impact: P05; P07; P09; P18; P12: none — Swift package wiring, no change to the existing FFI or JNI ABI. The scope of this freeze is the BLE profile and its native MCP endpoint. LAN discovery and wire transport require their own contract revision and are not covered by this record.

The owning contract is `spec/device/v1/ble-link.md` and the existing host capability, envelope and receipt schemas; MCP transport is `spec/v1/native-mcp.md`. The profile's producer/consumer pairs are Swift/CoreBluetooth ↔ C/NimBLE device, and Worker MCP client ↔ authenticated Swift native MCP. Kotlin/Android and Rust have no BLE Link implementations in this change: they continue using their existing host contract and do not advertise these tools. No shared P07 host schema changes. UI adds a settings entry and explicit grants. The durable local intent store is read only by the BLE native host.

## Delta and semantics

The frozen Link profile specifies the existing UUIDs, handshake, bit allocation and tag, little-endian framing, CRC, 512-byte envelope, 4096-byte logical messages, segment and buffer limits, errors, and `UPLOAD`/`COMMIT`/`RESULT` behavior. Both peers must negotiate before extensions. Commit acceptance is not execution; an absent/unknown result produces no P07 device receipt, and the client retains its original operation identity to query without replay. Device events are best effort and not durable. A 60-second reconnection, reliable delivery and exactly-once effects are not promised. Same request ID with different content is rejected; deadlines, scope, journal durability and bounded storage are defined in the profile. Cancellation and disconnect cannot roll back a committed side effect. Device content is untrusted; users grant tools per connection, and home HTTP requires an exact approved private origin.

P05 adds named BLE tools on the existing authenticated MCP endpoint. The Android MCP tool catalog and lifecycle are preserved. P09 adds only the required scanning, connection and grant controls. P18 adds an independently keyed BLE intent directory, containing request IDs and fingerprints, with synchronization before side effects. No existing persisted format changes.

## Compatibility and deployment

| Pair | Behavior |
| --- | --- |
| Old device → new phone | Legacy handshake remains valid. If the capability and extension tag are absent, the phone must not send tool opcodes. Standard GATT follows its service/characteristic definitions. |
| New phone → old device | Same negotiation rule; unsupported profiles stay unavailable. |
| New phone → new reference device | Both negotiate the v1 Tools extension and use the bounded framing and query-only recovery above. |
| Old data → new / rollback | Existing P07, Android and Worker settings remain unchanged. BLE intents are additive; rollback cannot safely replay pending effects and leaves the new directory unused. Re-upgrade must retain it. |

App, native MCP and reference firmware must be released after their respective tests pass. The target profile cannot be presented as implemented until both production decoders consume shared positive and negative vectors and affected integration tests pass. Old deployed firmware remains supported by negotiation; upstream opcode allocation remains a compatibility risk and requires a new revision if it collides.

## Paths, acceptance and evidence

- Contract owner: `spec/device/v1/**`, `spec/v1/native-mcp.md`, `spec/v1/golden/native-mcp/**`, registry and this record.
- Swift implementer: `Sources/PhoneDSHBLE/**`, `Tests/PhoneDSHBLETests/**`, package and app wiring; C implementer: `firmware/**`. Coordinator owns both sets in this task.
- Shared valid vectors: `spec/device/v1/golden/{xiaozhi-ctl,pdsh-link}.jsonl`; invalid: `spec/device/v1/golden/invalid-ctl.jsonl` (CRC, length, truncation). Both production decoders must consume the same files. Additional tests cover unsupported negotiation, duplicate/conflicting requests, cancellation, reconnect and unknown results.
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` → NOT_RUN.
- `swift test --filter PhoneDSHBLETests` → NOT_RUN.
- `bash firmware/tests/run.sh` → NOT_RUN.
- `bash scripts/ci/smoke.sh` and applicable hygiene/license checks → NOT_RUN.
- Real iPhone/ESP32, BLE pairing/reconnect, HTTP integration and device power loss → NOT_VERIFIED on this head. Source-branch evidence in `docs/ble-hardware-testing.md` is historical only.

## Revisions

| Revision | Owner | Reason | Affected ends |
| --- | --- | --- | --- |
| `spec/device/v1/ble-link.md@929361da4d3922b7ab78082f5d93bbeced2ec2e9` | Coordinator | Freeze the existing profile and P07 uncertain-outcome mapping before implementation. | Swift host, C firmware, Worker MCP client |
