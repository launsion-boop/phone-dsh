# BLE device identity proof (TOFU), v1

Status: `target` / experimental. This document records the identity proof
and first-use fingerprint flow that the Swift and reference C ends currently
encode, so that every document describes the same bytes. It is not an
authenticated session, it does not authorize BLE device tasks, and it does not
close GAP-16. No caller may treat a verified proof, a recorded fingerprint or
an entry in the trust list as authentication of later Link, task or receipt
traffic. The design history and open decisions are in
[PC-20261106-device-identity-tofu](../../../docs/protocol-changes/PC-20261106-device-identity-tofu.md);
the missing session contract is in
[PC-20261107-ble-session-binding-ccr](../../../docs/protocol-changes/PC-20261107-ble-session-binding-ccr.md).

## 1. What runs where

| Path | Default app build (`examples/probe-app/project.yml`) | `PDSH_ENABLE_DEVICE_TASKS` (only `examples/probe-app/identity-ui-harness/project.yml`) |
| --- | --- | --- |
| Firmware key generation, `pdsh.identity.prove` advertisement and signing | Device side; advertised only when the HELLO task profile is negotiated (§3) | same |
| Swift `BLEIdentity.verify` / `identity(publicKey:)` | Compiled; no production caller | same |
| Swift `BLEDeviceStore.proveIdentity` (sends the prove request) | Compiled, **never called** (`BLEDeviceStore.swift:1810`); ordinary discovery hides reserved `pdsh.identity.*` tools and never invokes them (`:9`, `:1707`) | same — the flag does not call it either |
| Pending-fingerprint UI and "记录此实验性指纹" button (`trustPendingIdentity`) | Not compiled (`examples/probe-app/PhoneDSHProbe/BluetoothDevicesPage.swift:115`) | Compiled; only reachable when `pendingIdentity` is set, which outside DEBUG test hooks (`testCaptureIdentityProof`) nothing does |
| `BLETrustedIdentities` (UserDefaults trust list) | Compiled; reads/writes only through the above and tests | same |
| `grantDeviceTasks(enabled: true)` | Always throws (`BLEDeviceStore.swift:1900`) — GAP-16 | same |

Therefore no build of the app currently sends `pdsh.identity.prove` on a real
connection. Hardware observations recorded in the change record predate the
2026-11-07 containment and describe earlier behaviour.

## 2. Identity string

`identity = "ble:" + lowerhex(SHA-256(P))`, where `P` is the 65-byte SEC1
uncompressed P-256 public key (`0x04 || X || Y`) presented in the proof. The
result is `ble:` followed by exactly 64 lowercase hex characters
(`Sources/PhoneDSHBLE/BLEIdentity.swift:47-49`). The phone derives it; the
device never sends a claimed identity string (`pdsh_identity.c:2-5`).

This is distinct from, and must not be confused with:

- the Link `device_id` UUID from `tools/list` (`linkIdentity`), which is an
  unauthenticated label; and
- `ble:<UUID>` strings, which are the identity form still required by the
  `target` task journal and BLE task-intent schema in
  [task-delegation.md](task-delegation.md). No conversion between the two forms
  is defined; `BLETaskIntent` rejects the fingerprint form. Resolving this is a
  precondition of any task use (change record, Compatibility).

## 3. Device key and the `pdsh.identity.prove` Link tool

Reference implementation: `firmware/esp32-reference/main/pdsh_identity.c`,
dispatch in `firmware/esp32-reference/main/link_tools.c:131-138,375-396`.

- One ECDSA P-256 key per device, generated with the PSA RNG on first boot
  when NVS namespace `pdsh_id` has no key `priv`, persisted (32-byte raw
  private scalar, plain NVS, no flash encryption assumed) before first use, and
  reloaded on every later boot (`pdsh_identity.c:21-45`). Any NVS read error
  other than "not found" disables the identity rather than regenerating.
- The tool is listed in `tools/list` only when the HELLO task profile is
  negotiated **and** the key loaded; an identity failure hides only this tool,
  ordinary Link tools are unchanged (`link_tools.c:131,234`).
- It is a normal Link Tools v1 call (no new opcode or envelope; limits and
  receipt rules from [ble-link.md](ble-link.md)). It creates no durable
  receipt: the result is held in the volatile read-only result slot.

Request arguments — exactly one member:

```json
{"nonce": "<64 lowercase hex chars = 32 random bytes>"}
```

The phone generates the nonce with `SecRandomCopyBytes`
(`BLEIdentity.swift:17-23`). The firmware accepts only exactly 64 characters of
`[0-9a-f]` (`pdsh_identity.c:75-92`); any other member, missing nonce, wrong
length or uppercase fails.

Signed message (identical on both ends, `pdsh_identity.c:106-114`,
`BLEIdentity.swift:40`):

```
M = UTF-8("phoneDSH BLE identity v1") || 0x00 || nonce(32 raw bytes) || 0x00 || P(65 raw bytes)
signature = ECDSA-P256-SHA256(M)   encoded as raw r||s, 64 bytes
```

The nonce is signed as raw bytes, not as its hex text, and the identity string
is not part of the message.

Successful Link result (`result_json`, `link_tools.c:78-89,392`):

```json
{"request_id": "<uuid>", "status": "completed",
 "result": {"pubkey": "<130 lowercase hex>", "signature": "<128 lowercase hex>"}}
```

Failure statuses (existing Link status values, `ble-link.md` §error table):
BUSY (6) while another Link operation runs; INTERNAL (11) when the nonce does
not decode or signing fails; the default BAD_LEN (2) when the task profile is
not negotiated, the key is unavailable, or the argument object has other keys.

Phone verification (`BLEIdentity.swift:26-45`, `BLEDeviceStore.swift:1811-1834`):
the reply must be `status:"completed"` with string `result.pubkey` and
`result.signature`; both must be lowercase hex, `pubkey` exactly 65 bytes
starting with `0x04` and a valid P-256 point, `signature` exactly 64 bytes;
the signature must verify over `M` with the presented key. Only then is the
identity derived. Any failure is an error, never a pending identity.

## 4. Confirmation and pinning (TOFU)

After a verified proof on the current connection, the store looks the derived
identity up in the trust list (`BLEDeviceStore.swift:1798-1803`):

- **Known** → `taskIdentity = identity`, `pendingIdentity = ""`.
- **Unknown** → `pendingIdentity = identity`; the flag-gated UI shows the full
  string (not a shortened SSH-style fingerprint) and the button
  "记录此实验性指纹". `trustPendingIdentity` appends the string to the trust list
  and, on a matching readback, moves it to `taskIdentity`
  (`BLEDeviceStore.swift:1837-1897`).

In both cases `supportsDeviceTasks` and `allowDeviceTasks` stay `false`.
Ordering, stale-result and reentrancy rules for confirmation are those of
[legacy-identity-preferences.md](legacy-identity-preferences.md) (frozen,
`observable-confirmation-v1`); this document does not change them.

## 5. Storage

- Phone: **UserDefaults** (`.standard`), key `pdsh.ble.trustedIdentities`, value
  an array of strings (`BLEIdentity.swift:71-143`). Not the Keychain. Only the
  identity string is stored — no public key, no CoreBluetooth peripheral UUID,
  no Link `device_id`, no timestamp. The same key also holds legacy labels
  (e.g. `ble:<UUID>`); all entries are preserved unchanged and are
  historical labels per [legacy-identity-preferences.md](legacy-identity-preferences.md).
  There is no forget/remove API or UI.
- Device: NVS namespace `pdsh_id`, key `priv` (§3).
- `pendingIdentity`, `taskIdentity` and identity error are in-memory UI
  markers on the device row.

Storing the public key in the Keychain is a *proposal* in the change record,
not implemented behaviour.

## 6. Key change, reconnect and restart

- **Key change:** the trust list is not bound to any physical device or label,
  so a device presenting a different key yields a different identity string,
  which is simply unknown → pending again. The old entry remains. There is no
  mismatch detection, warning or refusal. No test covers a key change; no
  hardware key-change test has been run.
- **Disconnect / channel or client replacement:** pending and confirmed
  markers and any task grant are cleared and the identity revision is
  invalidated (`BLEDeviceStore.swift:994-999,1000-1070`); a late proof or
  confirmation cannot apply to the new connection.
- **App restart:** in-memory markers are lost; the UserDefaults list survives
  subject to normal UserDefaults durability (not proven durable on power loss;
  see GAP-28). Because no build calls the prove helper, a restart never
  re-proves automatically.
- **Device reboot:** the key is reloaded from NVS, so the identity is stable
  across reboots if NVS is intact. Not verified on hardware after the
  2026-11-07 containment; power-loss persistence is NOT_RUN.

## 7. Limitations (normative for callers)

1. TOFU: a relay present at first use is pinned if the user confirms.
2. A live relay can forward a fresh proof at any later connection; proof
   possession is not channel binding, and later bytes are not integrity
   protected. It is not an authenticated session.
3. iOS cannot verify BLE bonding/encryption; all BLE task grants are refused
   (GAP-16). A recorded fingerprint must not change that.
4. No shared Swift/C proof vectors exist yet. `firmware/tests/test_link_tools.c`
   uses a stub signer (dispatch only); `Tests/PhoneDSHBLETests/BLEIdentityTests.swift`
   uses CryptoKit-generated keys. Cross-end signature conformance is therefore
   not machine-verified; adding shared valid/invalid vectors is required before
   any promotion of this status.
5. Device private key is in plain NVS.

GAPs: GAP-16 (task grants / session), GAP-28 (legacy preferences),
GAP-29–GAP-31 (iOS BLE lifecycle).
