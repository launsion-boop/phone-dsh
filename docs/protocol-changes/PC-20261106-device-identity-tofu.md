# BLE device identity: trust on first use (SSH-style), proposed

```yaml
change: PC-20261106-device-identity-tofu
contracts: [P06, P07, P08]
status: draft
breaking: true
version_decision: pending — UUID task journals require an explicit migration or fail-closed rollback decision
closes: GAP-16 (only after the acceptance evidence below)
base: 7cf848cfb031830df61ded38b071f28ee71f81f3
contract_revision: pending (spec/device/v1/ble-identity.md is not yet written; owner freeze required before any implementation)
```

## Why

GAP-16 exists because iOS cannot see whether a BLE peer is bonded and encrypted, so an advertised name, UUID, tools list or task capability proves nothing. The proposal draws on SSH-style first-use confirmation: the phone shows a fingerprint and the user confirms it. The current prototype recognizes confirmed fingerprints but has no stable binding that can detect a changed key for the same physical device.

## Proposed design and unresolved differences

This is not a frozen contract. The descriptions below distinguish the proposal from the current prototype; no task grant may rely on it until the contract and acceptance evidence are complete.

1. **Device key.** Each reference device holds one ECDSA P-256 key pair. It is generated on first boot when no key exists, and the private key is kept in the device's NVS. Signatures are raw 64-byte `r||s`, which CryptoKit (`P256.Signing.ECDSASignature(rawRepresentation:)`) and mbedTLS/PSA both accept.
2. **Identity.** `ble:` followed by the lowercase hex SHA-256 of the 65-byte uncompressed public key. The `tools/list` UUID is only a label and must not be used as identity. This replaces the NVS-claimed UUID as the authority for task grants.
3. **Pinning (first use).** After the user taps Allow on a sheet showing the fingerprint (first 16 hex characters grouped as in SSH), the proposed design stores the public key in the Keychain. The prototype instead stores fingerprint strings in UserDefaults; it does not store a public key or a binding from a stable device label to a key. This storage and migration decision is unresolved.
4. **Proof per connection.** After the encrypted Link is up and before any task capability is shown, the phone calls a Link tool `pdsh.identity.prove` with a fresh 32-byte nonce from `SecRandomCopyBytes`. The current Swift verifier and C signer use SHA-256 of UTF-8 `phoneDSH BLE identity v1`, NUL, the 32 raw nonce bytes, NUL, and the 65 raw public-key bytes; the signature is raw P-256 `r||s`. The Link request encodes the nonce as lowercase hex and the response encodes `pubkey` and `signature` as lowercase hex. The phone verifies with the presented key and derives its fingerprint. This differs from the earlier proposal that signed hex nonce and the identity string; a frozen contract and shared vectors must choose the bytes explicitly.
5. **Mismatch.** The prototype cannot detect a changed key for the same physical device: a new fingerprint is treated as a new identity and requires confirmation. It has no stable-label-to-key binding or forget UI. Key-change detection and recovery remain design and acceptance work; do not claim mismatch rejection.
6. **Task gate.** The proposed gate requires proof on the current connection and explicit trust; it must remain fail-closed until the target contract and acceptance evidence are complete. A grant must clear on disconnect.
7. **Residual risk (accepted, same as SSH).** A relay attacker who is present at the first connection can be trusted if the user taps Allow. A relay later can still forward a live proof. The mitigation is the visible fingerprint plus the requirement that first use happens with the device physically at hand. This is not MITM-proof and must not be described as such.

## Compatibility

- Old phone, new device: ordinary Link remains unchanged; task behavior must be verified against the actual negotiated capability and must not be assumed from the absence of an identity call.
- New phone, old device: no `pdsh.identity.prove` tool exists, so task grants stay refused. Ordinary Link is unchanged.
- Existing NVS bonds on the current board are not trusted. They do not provide identity.
- Existing target task journals and Link intents use `ble:<UUID>`, while the prototype identity is `ble:<sha256>`; `BLETaskIntent.make` rejects the latter. The contract owner must decide how old records are retained, rejected or migrated and how rollback behaves before changing the schema, fixtures and consumers. No silent conversion or replay is safe.

## Required shared fixtures (owner freeze, before code)

- Valid: nonce plus identity plus signature that verifies with the pinned key.
- Invalid: wrong nonce, wrong identity string, signature over a different domain string, signature from a different key, truncated or DER-encoded signature, identity that is not the hash of the presented key.

Swift (`CryptoKit`) and C (`mbedtls`/PSA) must each run these vectors through their real verify path.

## Acceptance (none of this is claimed yet)

1. `swift test` for the verify path and the pin store, using the shared vectors.
2. Firmware host tests for key generation, persistence and signing, using the same vectors.
3. Physical, ESP32: first-use confirmation, then reconnect and proof PASS; key mismatch refused; unprotected test peer refused.
4. Physical, unprotected Mac test peer: task grant still refused.
5. Power-loss/reboot: key and pin survive. Not verified until run on hardware.

## Not in this change

- No reflash of the current board without explicit authorization. The board currently runs `107dd4c-dirty`, which has no task inbox or identity tool.
- No change to `spec/` in this draft. The owner must freeze the contract revision first.
- No `PDSH_ENABLE_DEVICE_TASKS` enablement and no removal of the fail-closed guard until acceptance items 1 to 4 pass.

## Historical implementation status (2026-11-06)

- Firmware: `firmware/esp32-reference/main/pdsh_identity.c` generates and stores the P-256 key in NVS namespace `pdsh_id`; `pdsh.identity.prove` is offered only when the task profile is negotiated. `idf.py build` PASS with `-Werror`.
- Phone: `Sources/PhoneDSHBLE/BLEIdentity.swift` verifies the proof; `BLEDeviceStore` proves identity after tools/list, holds an unconfirmed identity as pending, and `trustPendingIdentity` confirms it. `grantDeviceTasks(enabled: true)` requires a proof on this connection plus a confirmed identity. iOS app `build` for the simulator PASS.
- Flashed to `/dev/cu.usbmodem1101`; the board boots and advertises the new firmware. The NVS partition was not written by the flash.
- Radio: `testPhysicalESP32OrdinaryLinkAndTaskContainment` PASS on the physical iPhone against the flashed ESP32 (2026-11-06 20:25, after the user accepted the pairing prompt earlier). The ordinary Link completed and the signed identity proof verified; the identity stayed pending (not trusted) so the task grant stayed refused. Earlier failures were a test race (the verdict was read before the proof returned) and a test setting that disabled task negotiation; both fixed in the test, not in the device.
- At this stage proof verification on hardware had been observed, but first-use confirmation and trusted reconnect had not yet been verified; the subsequent evidence below records those later observations. Key-change refusal and reboot persistence remain unverified.
- Residual risks: the key is stored in plain NVS (no flash encryption assumed); first use can be relayed if the user taps Allow; trust is keyed by the fingerprint only, so a changed key appears as a new device rather than an alarm. The spec owner still has to freeze `spec/device/v1/` for the identity change; `spec/device/v1/task-delegation.md` still describes the `ble:<UUID>` identity until then.

## Trusted reconnect evidence (2026-11-06, uncommitted)

- After the user confirmed the fingerprint on the iPhone, `testPhysicalESP32OrdinaryLinkAndTaskContainment` on the physical ESP32 printed `PDSH_IDENTITY_STATE name=PDSH ESP32 Link trusted=true pending=false supports=true`. The signed proof verified on reconnect without a new prompt, and `grantDeviceTasks(enabled: true)` was allowed, then revoked by the test.
- Not verified: an end-to-end device task submitted through the ESP32 inbox and its final reply; key-change refusal; reboot persistence after reinstall.

## Review correction (2026-11-07)

Ordinary Link discovery no longer invokes the unfrozen identity proof, and BLE task grants remain refused. The following prototype observations above describe earlier behavior, not the current gate.

The identity design is still draft: `spec/device/v1/ble-identity.md` and shared Swift/C verification vectors do not exist. The existing Swift task-intent validator and its shared fixtures still require a UUID and reject the fingerprint emitted by the prototype. The phone stores only fingerprint strings in UserDefaults, and key replacement is presented as a new identity rather than detected as a mismatch. Neither the proposed Keychain behavior nor key-change refusal is implemented. Do not promote the task profile or enable grants on this evidence.

## Interim containment (2026-11-07)

Base: `93c0eaef25a6a01b12b47c912ff6d41577a05091`. Protocol impact: P07; P09 — task entry points and UI availability are contained; P06: none — no harness or task execution semantics changed. Contract revision: none for the proposed identity design; the existing task-delegation GAP-16 rule still requires refusal. No wire format or persisted data is migrated. The ordinary Link discovers ordinary tools without calling the unfrozen identity method, even if a peer advertises it. The main probe no longer sets the task build condition. BLE task grants fail closed even if an in-memory device has stale optimistic state; revocation remains available. Previously confirmed fingerprint strings are left untouched and do not authorize tasks.

Compatibility: ordinary Link peers continue to use the existing profile; no identity proof is sent. Both old and new task peers are refused by this phone's BLE grant. A rollback to the earlier draft can re-enable an unverified grant and must not be used as a production rollback. LAN task code and existing journals remain unchanged, but the production probe does not compile its task entry points by default. The identity specification, old UUID-intent handling, secure key binding, key replacement, actual ESP32 task round trip, restart persistence, production TLS and UI/MCP lifecycle acceptance remain open; this containment is not a merge-readiness claim.

Interim evidence on the containment tree: `swift test --filter PhoneDSHBLETests` → PASS (27 tests); `bash firmware/tests/run.sh` → PASS using the locked cJSON source files, with the host identity stub explicitly unavailable (not a signature test); `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS, respectively. P0 fails first at stale UI provenance and further source reconciliation exposes actual cross-platform page differences. The baseline `phone-hygiene` and `phone-license` gates also FAIL on unchanged existing findings. iPhone/ESP32, ESP-IDF 6.1 build, power-loss, production TLS and model end-to-end evidence for this tree are NOT_RUN. The target task profile remains target; no physical acceptance or GAP closure is claimed.

## Session integrity gap (2026-11-07)

The challenge signature proves possession of a key for that challenge; it does not authenticate the subsequent task or receipt bytes. Because iOS cannot independently verify a protected BLE link, an active intermediary can forward the proof and then alter later traffic. [PC-20261107-ble-session-binding-ccr](PC-20261107-ble-session-binding-ccr.md) records the missing session contract and acceptance. The draft proof, fingerprint confirmation, and Keychain storage alone must not be used to close GAP-16 or enable BLE task grants.

Simulator build evidence (2026-11-07): generated `examples/probe-app/PhoneDSHProbe.xcodeproj` with `xcodegen generate`, then ran `xcodebuild -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/pdsh59-ios-build CODE_SIGNING_ALLOWED=NO build` from `examples/probe-app` → BUILD SUCCEEDED. The worker resource directory was empty; this verifies compilation only, not a runnable Worker, a simulator execution, an iPhone or task acceptance. The generated project resolved its additional app packages and changed the working copy of `Package.resolved`; that generated change was discarded, so this build is not evidence of a reproducible locked dependency graph. It does not close any contract gap.

Reference firmware build evidence (2026-11-07): at source head `449db65ccc556518dac7542f0fbb91fe1d58ba56`, with the official ESP-IDF v6.1 tag `fff9895c82d744c7237be8847347bdd1b07c6643` and the resolved cJSON sources matching the component lock, ran `idf.py -B /private/tmp/pdsh-pr59-idf61-build -D SDKCONFIG=/private/tmp/pdsh-pr59-idf61-sdkconfig build` from `firmware/esp32-reference` → PASS (`CONFIG_IDF_TARGET=esp32s3`). Build log: `/private/tmp/pdsh-pr59-idf61-build.log`. This is a cross-compile, not a flash, radio test, task acceptance or restart/power-loss test; no GAP is closed.
