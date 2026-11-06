# BLE device identity: trust on first use (SSH-style), proposed

```yaml
change: PC-20261106-device-identity-tofu
contracts: [P06, P07, P08]
status: implemented-unverified-on-radio
breaking: false
closes: GAP-16 (only after the acceptance evidence below)
base: 7cf848cfb031830df61ded38b071f28ee71f81f3
contract_revision: pending (spec/device/v1/ble-identity.md is not yet written; owner freeze required before any implementation)
```

## Why

GAP-16 exists because iOS cannot see whether a BLE peer is bonded and encrypted, so an advertised name, UUID, tools list or task capability proves nothing. The product choice here is SSH's model: the first connection shows the device's key fingerprint and the user confirms on the phone; afterwards the phone pins that key and refuses any other key for the same device.

## Decisions (concrete, no open options)

1. **Device key.** Each reference device holds one ECDSA P-256 key pair. It is generated on first boot when no key exists, and the private key is kept in the device's NVS. Signatures are raw 64-byte `r||s`, which CryptoKit (`P256.Signing.ECDSASignature(rawRepresentation:)`) and mbedTLS/PSA both accept.
2. **Identity.** `ble:` followed by the lowercase hex SHA-256 of the 65-byte uncompressed public key. The `tools/list` UUID is only a label and must not be used as identity. This replaces the NVS-claimed UUID as the authority for task grants.
3. **Pinning (first use).** After the user taps Allow on a sheet showing the fingerprint (first 16 hex characters grouped as in SSH), the phone stores the public key in the Keychain, keyed by identity. Pins are never updated silently.
4. **Proof per connection.** After the encrypted Link is up and before any task capability is shown, the phone calls a Link tool `pdsh.identity.prove` with a fresh 32-byte nonce from `SecRandomCopyBytes`. The device returns an ECDSA signature over the UTF-8 string `phoneDSH BLE identity v1` NUL, the lowercase hex nonce, NUL, the device's identity string. The phone verifies with the pinned key.
5. **Mismatch.** A different key for an already pinned identity is refused with no prompt. The only path forward is an explicit "forget device" in settings, followed by a new first-use confirmation.
6. **Task gate.** `supportsDeviceTasks` becomes true only after a successful proof on the current connection. A grant stays per-connection and clears on disconnect, as today.
7. **Residual risk (accepted, same as SSH).** A relay attacker who is present at the first connection can be trusted if the user taps Allow. A relay later can still forward a live proof. The mitigation is the visible fingerprint plus the requirement that first use happens with the device physically at hand. This is not MITM-proof and must not be described as such.

## Compatibility

- Old phone, new device: the phone never calls `pdsh.identity.prove`, so task tools stay hidden. Ordinary Link is unchanged.
- New phone, old device: no `pdsh.identity.prove` tool exists, so task grants stay refused. Ordinary Link is unchanged.
- Existing NVS bonds on the current board are not trusted. They do not provide identity.

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

## Implementation status (2026-11-06, uncommitted)

- Firmware: `firmware/esp32-reference/main/pdsh_identity.c` generates and stores the P-256 key in NVS namespace `pdsh_id`; `pdsh.identity.prove` is offered only when the task profile is negotiated. `idf.py build` PASS with `-Werror`.
- Phone: `Sources/PhoneDSHBLE/BLEIdentity.swift` verifies the proof; `BLEDeviceStore` proves identity after tools/list, holds an unconfirmed identity as pending, and `trustPendingIdentity` confirms it. `grantDeviceTasks(enabled: true)` requires a proof on this connection plus a confirmed identity. iOS app `build` for the simulator PASS.
- Flashed to `/dev/cu.usbmodem1101`; the board boots and advertises the new firmware. The NVS partition was not written by the flash.
- Radio: `testPhysicalESP32OrdinaryLinkAndTaskContainment` PASS on the physical iPhone against the flashed ESP32 (2026-11-06 20:25, after the user accepted the pairing prompt earlier). The ordinary Link completed and the signed identity proof verified; the identity stayed pending (not trusted) so the task grant stayed refused. Earlier failures were a test race (the verdict was read before the proof returned) and a test setting that disabled task negotiation; both fixed in the test, not in the device.
- Not verified: proof verification on hardware, first-use trust flow in the UI, reconnect with a trusted key, key-change refusal, reboot persistence of the key and trust.
- Residual risks: the key is stored in plain NVS (no flash encryption assumed); first use can be relayed if the user taps Allow; trust is keyed by the fingerprint only, so a changed key appears as a new device rather than an alarm. The spec owner still has to freeze `spec/device/v1/` for the identity change; `spec/device/v1/task-delegation.md` still describes the `ble:<UUID>` identity until then.

## Trusted reconnect evidence (2026-11-06, uncommitted)

- After the user confirmed the fingerprint on the iPhone, `testPhysicalESP32OrdinaryLinkAndTaskContainment` on the physical ESP32 printed `PDSH_IDENTITY_STATE name=PDSH ESP32 Link trusted=true pending=false supports=true`. The signed proof verified on reconnect without a new prompt, and `grantDeviceTasks(enabled: true)` was allowed, then revoked by the test.
- Not verified: an end-to-end device task submitted through the ESP32 inbox and its final reply; key-change refusal; reboot persistence after reinstall.
