# Android device transport decoders

```yaml
change: PC-20261107-android-device-decoders
contracts: [P07]
status: frozen
breaking: false
version_decision: Existing BLE Link Tools Profile v1 and LAN pdsh-mcp-1 unchanged; Android decoders are target-only, with no Android discovery, transport or task feature enabled.
base: 8fa659babf90886c152730de392a88f22ee61896
contract_revision: spec/device/v1/ble-link.md@sha256:6389bd39d67c1102742b26eecaeea297de4b82ba62ebdbf70f657df22fe2e273; spec/device/v1/lan-mcp.md@sha256:941b7f6cbc5cdccdbdc5d25a45f99095f5463aa51e85db953e46a26824184b81
```

## Trigger, ownership and scope

Android has neither a registered production BLE Link transport nor a raw DNS-SD discovery adapter for these profiles. This revision registers a **target-only Android implementation** of their existing byte-level decoders. It does not enable task intake, negotiate a new capability, change existing Swift/C/Python wire semantics, authorize a device, make a network connection or provide a fake discovery UI. Protocol impact: P07. Contract owner owns `spec/**` and this record; implementers must not edit them. Kotlin decoders are in separate packages within `android/domain/src/main/kotlin/com/phonedsh/domain/connector/`, and each owner edits only its assigned package and corresponding tests.

## Delta and compatibility

- BLE: consume and emit the same envelope as `ble-link.md`, including exact CRC, 512-byte bound, ATT segment framing and negotiation. `golden/xiaozhi-ctl.jsonl` and `golden/pdsh-link.jsonl` contain valid vectors; `golden/invalid-ctl.jsonl` contains invalid frames. The Android decoder/reassembler must drive these exact bytes and invalid/truncation, orphan continuation, oversize, corrupted CRC and reconnect reset paths. As in the current Swift and C receivers, a new FIRST discards an unfinished buffer and starts a new one. Fragments have no sequence number: arbitrary middle-fragment reordering or interleaving is not reliably detectable, and CRC is not authentication. Senders must not interleave; no stronger receiver or security guarantee is inferred. The codec is not a GATT adapter and it must not call the target task profile.
- LAN: parse raw DNS-SD length-prefixed TXT, validated service name, SRV hostname and port into the existing HTTPS `/mcp` candidate, without connecting or granting access. Existing `golden/lan-discovery.jsonl` and the new raw-byte valid/invalid `golden/lan-discovery-raw.jsonl` are shared by Swift and Android real candidate decoders; the new vector shape is `schema/lan-discovery-raw-vector.schema.json`. Unknown TXT keys are ignored, duplicate profile is rejected and framing is not reconstructed from a lossy dictionary. No new discovery message is introduced.
- Old producers → new Android decoder, and new producer → old Swift decoder: existing profile unchanged and shared vectors determine acceptance. New → new: same acceptance and URL semantics, without a connection or grant. Old persisted data / rollback: no new persistence is created and existing files are untouched. Until Android provides an independently verified raw DNS-SD/SRV source, GATT transport, authorization and lifecycle, the decoders are not wired to user-facing features and do not establish Android capability or device conformance.
- The existing Swift, C firmware and Python reference remain registered unchanged. Swift must consume the added raw TXT vectors through its real `LANDeviceCandidate`; reference Python producer continues its existing shared advertisement vectors. Android API-level limitations and any future raw mDNS transport need a separately frozen implementation contract; this revision does not loosen the raw TXT or hostname requirements.

## Disjoint paths and acceptance

- Coordinator/contract owner: `spec/device/v1/**`, `spec/README.md`, `spec/registry.json` and this change record.
- Android LAN implementer: `android/domain/src/main/kotlin/com/phonedsh/domain/connector/lan/**` and `android/domain/src/test/kotlin/com/phonedsh/domain/connector/lan/**`. Acceptance: `cd android && ./gradlew :domain:testDebugUnitTest --tests '*LanDiscovery*'`.
- Android BLE implementer: `android/domain/src/main/kotlin/com/phonedsh/domain/connector/ble/**` and `android/domain/src/test/kotlin/com/phonedsh/domain/connector/ble/**`. Acceptance: `cd android && ./gradlew :domain:testDebugUnitTest --tests '*BleLink*'`.
- Swift test implementer: `Tests/PhoneDSHLANTests/LANAdvertisementTests.swift` only. Acceptance: `swift test --filter LANAdvertisementTests`.
- Integrator: `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`, existing Swift BLE and firmware shared-vector tests, the Android tests above and a combined review. `phone-p0-conformance` has known source/page drift and is not expected to become green by this slice. Device, radio, model and Android discovery runtime remain NOT_RUN until actually executed.

The contract revision is the two source file hashes above and the shared fixture content committed with this record. Any ambiguity or divergence is a contract change request; do not widen parsers or alter fixtures to make a platform pass.

## Revision 2

Clarifies receiver FIRST/reset semantics and the limits of detecting reordered fragments after implementer review; no wire change. Android implementations must use this revision.

## Implementation evidence (2026-11-07)

Android BLE and LAN decoders are implemented as internal, non-wired code; Android GATT, discovery, authorization and UI are not implemented by this change. The BLE decoder reads all 171 shared valid and 3 invalid frame vectors; LAN reads the existing and raw TXT vector sets. With a locally configured JDK 17 and Android SDK, `cd android && ./gradlew :domain:testDebugUnitTest --tests '*BleLink*' --tests '*LanDiscovery*'` → PASS (10 tests, no skips). `swift test --filter 'LANAdvertisementTests|PDSHLinkTests'` → PASS (5 LAN and 11 BLE tests). `bash firmware/tests/run.sh` → PASS with the locked cJSON sources and the explicitly unavailable identity host stub; this is not identity or radio evidence. Physical Android, iPhone, ESP32, DNS-SD/GATT lifecycle, authentication and device-task E2E → NOT_RUN. Existing P0 and hygiene gates remain FAIL. GAP-17 and GAP-18 remain open.

Additional gate observations: `bash scripts/ci/check.sh --only phone-android-structure,phone-gate-contracts` → FAIL / FAIL. The structure checker expects 11 Swift module directories and reports 16 on this branch; the base main reports 13 against the same expected 11. The gate-contract selftest fails because the repository hygiene scan reports existing findings. `bash scripts/ci/check.sh --only phone-plugins,phone-image,phone-sdk` → SKIP / SKIP / FAIL on the first run: plugin dependencies were absent, and one WebEngine JIT benchmark returned no duration. The same JIT test passed when rerun alone; that does not turn the original aggregate failure into a pass. These gate failures and skips remain open pending full reruns and diagnosis.
