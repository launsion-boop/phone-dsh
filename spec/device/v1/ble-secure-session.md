# BLE authenticated device-task session (`secure-session-v2`)

Status: `target` — frozen contract, **not implemented on any end**. Revision
label `ble-secure-session.md@secure-session-v2`; it supersedes
`secure-session-v1` (`0aa86466`) and resolves the independent
[security review](../../../docs/reviews/ble-secure-session-v1-review.md). The
freeze commit, the per-finding resolution and the v1 → v2 change list per end
are in
[PC-20261108-ble-secure-session](../../../docs/protocol-changes/PC-20261108-ble-secure-session.md).
No caller may enable a BLE task grant on the strength of this document. GAP-16
stays open until both ends implement this revision, run every shared fixture
and every conformance-matrix row (§13) through their real code, and the
physical acceptance in §14 is recorded. v1 was never implemented; there is no
v1 ↔ v2 interoperation to preserve.

This contract replaces the open questions of the
[candidate](../../../docs/design/device-ble-secure-session-candidate.md) and the
[session-binding CCR](../../../docs/protocol-changes/PC-20261107-ble-session-binding-ccr.md).
It owns: the offline enrollment ceremony and the board's enrollment mode, the
enrollment records, the BLE session transport (including pre-authentication
resource limits) and TLS profile, the application framing and messages carried
inside it, the phone and board session state machines, the BLE task identity,
the phone's secure transition intents and the reference firmware task store
v2. The task model itself (task fields, phone journal v1, terminal outcomes,
grant generations, isolated DSH session) remains owned by
[task-delegation.md](task-delegation.md); the ordinary Link profile remains
owned by [ble-link.md](ble-link.md) with the two board-side exceptions stated
in §11.1.

Key words MUST, MUST NOT, SHOULD and MAY are normative. "Phone" is the iOS app
(TLS client); "device" or "board" is the reference ESP32-S3 firmware (TLS
server).

## 1. Threat model and non-goals

**Protected.** Against an active radio attacker who holds neither enrolled
private key, every task, acceptance, result, failure and status byte is
confidential and integrity protected, bound to exactly one previously and
independently enrolled phone-key/device-key pair, and cannot be replayed,
reordered, reflected, moved to another session or downgraded to the plaintext
Link path. Task authority requires: both sides locally committed to the same
enrollment; the phone connecting to the one device the user selected (§8.2); a
fresh mutually authenticated TLS 1.3 handshake; a successful readiness
exchange (§8.3); and, on the phone, an explicit foreground grant. Lost replies,
crashes and timeouts never authorize automatic re-execution (§9). A radio peer
that holds no key can reach only the bounded pre-authentication surface of §5
and the TLS handshake; it MUST NOT be able to crash the board, exhaust its
memory or make it stop serving the enrolled phone after the peer leaves.

**Physical authorization.** Authority-changing console commands are accepted
only while the board is in enrollment mode, which only a person holding the
board's enrollment button for 5 s can enter, with a dedicated indicator
showing the mode; the action itself needs a second, distinct 3 s hold (§3.3).
An ordinary short press never authorizes anything. This defends against a
host that can only write the console (a serial monitor, a remote serial
bridge, a charging host, a shared lab machine).

**Assumed trusted (outside the cryptographic claim).**

- The operator, and the operator's identification of the physical board.
- **Every USB host the reference board is ever attached to.** The reference
  board has USB-Serial-JTAG and ROM download mode enabled, no secure boot and
  no flash encryption. Any attached host can, at any time and without the
  button, reset the chip into download mode, read the device private key
  (`pdsh_id/priv`), write any enrollment record or task store, or flash any
  firmware image. Enrollment mode is therefore a defence against a
  console-limited host only, **not** against a malicious USB host. A stolen
  device key gives permanent impersonation of that board toward its enrolled
  phone until the phone forgets the board or the board is reset and
  re-enrolled.
- The board firmware image; the phone OS and app.

Consequences that every end MUST state to the user: the board README and the
phone enrollment screen say that connecting the board to a computer gives that
computer full control of the board's task pairing and keys, and that only
trusted computers may be attached. The phone MUST NOT describe a reference
board as tamper-resistant.

**Deployment hardening (`production-hardened`, `target`, not part of the
reference board).** The assumption above changes only for a board that, after
provisioning, has: secure boot v2 enabled; flash encryption in release mode
(NVS encrypted); ROM download mode disabled or set to secure download mode;
USB-Serial-JTAG and JTAG disabled by eFuse; and a contract revision that
re-evaluates this section with evidence from that hardware. Until such a
revision exists, no end may claim any resistance to a host with USB or flash
access, and this profile's status for hardening is `none`.

**Explicit non-goals.**

1. Relay / distance bounding. A transparent radio relay between the two
   correct endpoints is possible at any time. TLS authenticates endpoints, not
   proximity.
2. Compromised phone or compromised host (see above).
3. Device key extraction on the reference board (see above). Physical access to
   the board's flash or USB yields the key.
4. Physical rollback. A whole-flash restore can bring back an earlier
   enrollment or key; there is no anti-rollback anchor (§4.3). Without secure
   boot an anti-rollback counter would be decorative.
5. Availability against a radio attacker. Jamming and CoC refusal can deny
   service; they fail closed. (Memory exhaustion and crashes are not
   permitted, see "Protected".)
6. Hidden-device privacy. The GATT service and PSM are discoverable.
7. Historical confidentiality. Data already sent over the plaintext Link path
   before the 2026-11-07 containment cannot be made confidential.

## 2. Identifiers

All hex in this contract is lowercase unless an input rule says otherwise.

| Name | Definition | Text form |
| --- | --- | --- |
| public key | SEC1 **uncompressed** P-256 point `0x04‖X‖Y`, exactly 65 bytes | 130 hex |
| fingerprint | SHA-256 of exactly those 65 bytes | 64 hex |
| device ID | device key fingerprint | `ble:` + 64 hex |
| phone ID | phone key fingerprint | `phone:` + 64 hex |
| enrollment ID (`eid`) | 16 bytes from the board's CSPRNG, fresh per `begin` | 32 hex |
| challenge (`cc`, `sc`) | 32 bytes from the sender's CSPRNG, fresh per session | 64 hex |

Before hashing, a public key MUST be checked in this order and rejected with
the first failing reason: hex (`not_hex`, then `uppercase`), length 65
(`length`), prefix `0x04` (`not_uncompressed`), each coordinate `< p`
(`coordinate_range`), point on the curve (`not_on_curve`). Compressed, hybrid
and raw `X‖Y` encodings are rejected, never converted.

The device ID is the same string as the experimental identity of
[ble-identity.md](ble-identity.md) §2 for the same key; that equality is not
authority (§11.3). `ble:<Link UUID>` is a legacy label and is never a device ID
in this profile. The roles MUST differ: a phone key whose fingerprint equals
the device fingerprint is rejected at enrollment (`same_key`), so a peer can
never satisfy both pins with one key.

**Randomness (board).** The ESP32-S3 RNG produces true random numbers only
while an entropy source is active (the RF subsystem, i.e. the BLE controller
or Wi-Fi, is enabled, or the SAR-ADC source is enabled through
`bootloader_random_enable()`). The board MUST NOT draw the device key, an
`eid`, an `sc` or any TLS randomness unless such a source is active at that
moment; first-boot key generation therefore runs after the BLE controller is
enabled or inside a `bootloader_random_enable()`/`bootloader_random_disable()`
bracket that ends before the ADC, Wi-Fi or BLE is used. The firmware logs which
source was active at key generation. The phone uses the platform CSPRNG
(`SecRandomCopyBytes`) and the key generator of §4.1.

Fixtures: `golden/ble-secure-identifiers.jsonl`.

## 3. Offline enrollment ceremony

### 3.1 Principle

The reference board has no trusted display, so trust is bootstrapped
**offline** through a physically attached, trusted USB/serial host (§1). The
phone learns the board fingerprint from the operator (who copied it from the
trusted host), never from the radio; the board learns the phone fingerprint
from the same host. Authority-changing board commands (`begin`, `revoke`,
`identity-reset`) are accepted only in **enrollment mode**, which only a
physical 5-second hold of the enrollment button enters (§3.3); the resulting
action needs a second, separate 3-second hold. Nothing in this ceremony uses
BLE. The connected TOFU UI of ble-identity.md is not part of it and MUST NOT
be reused for it.

Why this shape (review H1): v1 served the console permanently and committed on
any single press of the devkit BOOT button, which the operator already presses
to reopen the pairing window. A console-capable host could stage an attacker
phone and wait for a routine press. In v2 (a) the console is inert for
authority until a person performs a gesture that has no other meaning; (b) the
mode is visible on a dedicated indicator and bounded to 300 s; (c) every error
leaves the mode, so a host cannot probe or retry inside one arming; (d) the
confirming gesture is a hold that must start after the `press` line, so a
press already in progress or a routine tap cannot confirm, and a short press
aborts. A "hold at reset" gesture is not used because the reference button is
GPIO0, a strapping pin: holding it at reset enters ROM download mode.

Sequence (any order between phone steps P2/P3 and board steps B4/B5 is
allowed; the two commits are independent local facts, see §4.4):

```text
P1 phone shows its token  pdsh-phone-v1:<phone fp>
B1 operator holds the board button 5 s        board: armed window_s=300, indicator "armed"
B2 host:  pdsh-enroll begin                    board: begun eid=… device=…
B3 host:  pdsh-enroll phone eid=… phone=…      board: staged … token=pdsh-board-v1:<device fp>:<eid>
P2 operator enters that board token on the phone      phone record: staged
B4 host:  pdsh-enroll commit eid=… device=… phone=…   board: press …, indicator "confirm"
B5 operator holds the board button 3 s (new hold) within 30 s   board: committed … rev=n, mode locked
P3 operator compares, then confirms on the phone      phone record: committed
```

### 3.2 Console transport and line grammar

The board serves the console on its ESP-IDF primary console (USB-Serial-JTAG
or UART0, 115200 8N1 for UART). Each line is printable ASCII (0x20–0x7E),
1–384 bytes, terminated by LF; one CR immediately before LF is removed. Tokens
are separated by exactly one space; no leading/trailing space, no tab. A line
is **addressed to enrollment** iff its first token is exactly `pdsh-enroll`
(host→board) or `pdsh-enroll-r` (board→host). Unaddressed lines (logs, other
tools) are ignored by both parsers and get no response. An addressed line that
is too long, contains a non-printable byte, has an unknown verb or wrong
fields gets `error code=syntax cmd=<verb or ->`, where `cmd` echoes the verb
only if it is one of the known verbs. The board MUST NOT print any other line
beginning with `pdsh-enroll-r`. There is no host command that arms the board.

Fields are `name=value` in exactly the listed order, all mandatory, no extra
fields. `eid` = 32 hex, `device`/`phone` = 64 hex (bare fingerprint hex, no
`ble:`/`phone:` prefix), `rev` = decimal 0–4294967295 without leading zeros.

| Host command | Fields |
| --- | --- |
| `status` | — |
| `begin` | — |
| `phone` | `eid phone` |
| `commit` | `eid device phone` |
| `abort` | `eid` |
| `revoke` | `eid device phone` |
| `identity-reset` | — |

| Board response | Fields | Notes |
| --- | --- | --- |
| `status` | `state mode ctx device phone eid rev` | `state` ∈ none, committed, revoked, key_lost, key_unavailable, record_corrupt; `mode` ∈ locked, armed; `ctx` ∈ idle, begun, staged, press; `device` is `-` when the key is lost/unavailable; `phone`/`eid` are `-` unless state is committed/revoked |
| `armed` | `window_s` | unsolicited, when the arm hold completes; `window_s` = `300` |
| `begun` | `eid device` | |
| `staged` | `eid device phone token` | `token` = `pdsh-board-v1:<device>:<eid>` of the same line |
| `press` | `eid action timeout_s` | `action` ∈ commit, revoke, identity-reset; `eid` is `-` for identity-reset; `timeout_s` = `30` |
| `committed` | `eid device phone rev` | |
| `aborted` | `eid` | |
| `revoked` | `eid device phone rev` | |
| `reset` | `device` | new device fingerprint |
| `error` | `code cmd` | `cmd` = the verb of the command answered, or the pending `action` for a confirmation failure (`timeout`, `gesture`, `storage`), or `-` for enrollment-window expiry and for a syntax error without a known verb |

Error codes: `syntax`, `busy`, `occupied`, `no_session`, `state`,
`eid_mismatch`, `value_mismatch`, `same_key`, `timeout`, `storage`,
`controls_unavailable`, `not_armed`, `gesture`, `key_lost`,
`key_unavailable`, `record_corrupt`. The set is closed for this revision
(v1's `button_unavailable` is retired and is a syntax error); a host receiving
another code treats the attempt as failed. `status` fields are public
fingerprints, not secrets; `status` stays available while locked.

Fixtures: `golden/ble-secure-enrollment-lines.jsonl` (byte-exact, including CR,
over-length, non-ASCII, tab, lookalike-prefix, retired-code and missing-`mode`
cases).

### 3.3 Board state machine

The board has a durable state (§4.2) and volatile RAM state: `mode` ∈
`locked`, `armed`; and `ctx` ∈ `idle`, `begun(eid)`, `staged(eid, phone)`,
`press(action)`. Reboot, replug-induced reset or any power loss returns to
`locked` + `idle`. `ctx ≠ idle` only while `armed`. The staged phone
fingerprint exists on the board only in `ctx`.

**Physical controls.** Enrollment requires both an enrollment button and a
dedicated, physically visible indicator (the reference firmware uses a
low-active button on `PDSH_BUTTON_GPIO` and an indicator output configured for
enrollment only; it MUST NOT share the `light.*` LED). If either is not
configured the board never arms, and `begin`, `revoke` and `identity-reset`
answer `controls_unavailable`. Indicator: off while `locked`; the **armed**
pattern (1 Hz blink) while `armed` and `ctx ≠ press`; the **confirm** pattern
(4 Hz blink) while `ctx = press`.

**Gestures.** The button is debounced (≥ 50 ms). The firmware classifies each
press from its press edge:

| Gesture | Definition |
| --- | --- |
| `arm_hold` | held continuously ≥ 5 s from a press edge |
| `confirm_hold` | press edge observed after the latest `press` line, held continuously ≥ 3 s |
| `short_press` | press edge, released before the hold threshold that applies |
| `held_across_press_line` | press edge before the `press` line, still held after it; it has no effect at any time, and only a later press edge can confirm |

- While `locked`: every press edge keeps its ordinary meaning (pairing window,
  Link `button.pressed` event, unchanged from ble-link.md). An `arm_hold` with
  controls configured additionally sets `mode := armed`, starts a **300 s**
  enrollment window (absolute, never extended) and prints `armed window_s=300`.
  Nothing else changes the mode to `armed`.
- While `armed`: no gesture has its ordinary meaning (no pairing window, no
  Link event). Outside `ctx = press` every gesture is ignored (it neither
  extends nor re-arms). In `ctx = press`: `confirm_hold` executes the pending
  action; `short_press` fails with `error code=gesture cmd=<action>`;
  `held_across_press_line` does nothing.

**Leaving enrollment mode.** Every `error` response, and every successful
`committed`, `revoked`, `reset` or `aborted`, sets `mode := locked`,
`ctx := idle` with no further durable effect; so does reboot. Window expiry
prints `error code=timeout cmd=-`. One arming permits at most one completed
action.

Processing of an addressed host line, in order:

1. If `ctx = press`: fail `busy` (any addressed line, including `status` and
   syntax errors, aborts a pending confirmation).
2. A syntax error fails `syntax`.
3. `status` always answers and changes nothing.
4. If durable state is `key_lost`, `key_unavailable` or `record_corrupt`,
   every command except `identity-reset` fails with that state as the code.
5. `begin`, `revoke`, `identity-reset`: controls missing → fail
   `controls_unavailable`; `mode ≠ armed` → fail `not_armed`.
6. `begin`: `ctx ≠ idle` → `busy`; durable `committed` → `occupied`; else draw
   a fresh `eid`, `ctx := begun`, answer `begun`.
7. `phone`: `ctx = idle` → `no_session`; `ctx ≠ begun` → `state`; eid differs
   → `eid_mismatch`; phone = device fingerprint → `same_key`; else
   `ctx := staged`, answer `staged`.
8. `commit`: `ctx = idle` → `no_session`; `ctx ≠ staged` → `state`; eid
   differs → `eid_mismatch`; device or phone differs from the board key /
   staged phone → `value_mismatch`; else `ctx := press`, answer
   `press … action=commit`.
9. `abort`: `ctx = idle` → `no_session`; eid differs → `eid_mismatch`; else
   answer `aborted`.
10. `revoke`: `ctx ≠ idle` → `busy`; durable ≠ committed → `state`; any field
    differs from the committed record → `value_mismatch`; else
    `ctx := press`, answer `press … action=revoke`.
11. `identity-reset`: `ctx ≠ idle` → `busy`; durable `committed` → `occupied`
    (revoke first); else `ctx := press`, answer
    `press eid=- action=identity-reset`.

"Fail" means: answer `error code=<code> cmd=<…>` and leave enrollment mode.

**Confirmation.** In `ctx = press` only `confirm_hold` executes the action. No
`confirm_hold` within 30 s of the `press` line → `error code=timeout
cmd=<action>`. Any error ends the mode.

- `commit`: write the durable record `committed` with the context's eid,
  device, phone and `rev := rev + 1`; read it back and compare every field;
  only then answer `committed`. A write or readback failure answers
  `error code=storage cmd=commit`; the host learns the actual durable state only
  from a later `status`.
- `revoke`: first set the in-RAM revocation flag — every live session is
  closed with `err revoked` and no further request is processed (§8.4) — then
  write `revoked` with `rev := rev + 1`, read back, answer `revoked`. On write
  failure answer `storage`; the RAM flag stays set until reboot, after which
  the still-committed record is again authoritative (accepted limitation, see
  the change record L3). The operator must retry.
- `identity-reset`: erase `pdsh_enr/rec_v1`, commit, then erase `pdsh_id/priv`,
  commit; generate a new P-256 key under §2 randomness, persist it, read it
  back; the durable state becomes `none` with `rev = 0`; answer
  `reset device=<new fp>`. On failure answer `storage` and re-derive the durable
  state at the next command (§4.2). A reset changes the device ID; every phone
  record for the old fingerprint becomes permanently unusable (§4.4).

Fixtures: `golden/ble-secure-enrollment-states.jsonl`, `side=board`. Each step
lists the console output, the durable state, the volatile state
(`mode`, `ctx`, `indicator`) and, for gesture steps, `legacy_button` (whether
the press edge kept its ordinary pairing-window/Link-event meaning). Cases
include the locked console, short presses that never authorize, a short press
that aborts confirmation, a hold that began before the `press` line, window
expiry, missing indicator or button, stray gestures while armed, replug,
concurrent `begin`, replayed `commit`, confirmation timeout and interruption,
storage failure on commit, revoke and identity-reset, identity-reset from
`none`, `revoked`, `key_lost` and `record_corrupt`, key loss, same key, eid and
value mismatches, and syntax errors that disarm.

### 3.4 Phone ceremony

The phone token `pdsh-phone-v1:<64 hex>` is displayed in full (grouping into
blocks of four for readability is allowed; the copied value has no spaces).
The phone generates its key (§4.1) the first time it shows the token. The
enrollment screen shows the §1 USB warning and instructs the operator to hold
the board button for 5 s and watch the indicator before running the host
commands.

The board token input accepts exactly `pdsh-board-v1:<64 hex>:<32 hex>` after
removing leading/trailing ASCII space, tab, CR and LF; hex digits may be in
either case and are normalized to lowercase. Any other character, inner
whitespace, other version or missing part → `syntax`. Input methods (typing,
paste) are UI choices; the value MUST have come from the trusted host, never
from BLE, an advertisement, a label on the board or a previous connection.

Phone operations and results (closed result set: `ok`, `syntax`,
`no_phone_key`, `phone_key_lost`, `same_key`, `occupied`, `busy`, `state`,
`value_mismatch`, `record_corrupt`, `storage`):

| Operation | Precondition → effect |
| --- | --- |
| enter board token | key present; device ≠ phone; no record or `revoked` → write `staged` (rev+1). Same eid already staged → `ok`, no write. Other eid staged → `busy`. `committed` → `occupied`. |
| confirm (eid, device shown) | record `staged` with that eid and device → write `committed` (rev+1). Before confirming, the UI shows both full fingerprints and the eid and states that the board must have printed `committed` for the same values. |
| abort | `staged` → `revoked` (rev+1) |
| forget | `staged` or `committed` → `revoked` (rev+1); a live session generation is ended first (§8.4) |
| reset phone key | every `staged`/`committed` record → `revoked`, then a new key; required to leave `phone_key_lost` |

A failed write leaves the previous durable record (`storage`). A restart
preserves `staged` and `committed` records; a staged record is never promoted
by a restart, a reconnect or any peer message. Each committed record carries a
user-visible label chosen at confirmation (UI data, not part of the record
schema); the device selection and grant UI of §8.2 show that label together
with the device ID.

Fixtures: `golden/ble-secure-enrollment-states.jsonl`, `side=phone`.

## 4. Keys and enrollment records

### 4.1 Phone key

One P-256 signing key per app installation, used for every device, never
exportable:

- On hardware with a Secure Enclave (every supported iPhone) the key MUST be a
  Secure Enclave key (`kSecAttrTokenIDSecureEnclave`, `kSecAttrIsPermanent`,
  application tag `pdsh.ble.session.phone-key.v1`, access control
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with
  `.privateKeyUsage`, not synchronizable).
- Where no Secure Enclave exists (Simulator, test hosts) a software Keychain
  key with `kSecAttrIsExtractable = false` and the same attributes is
  permitted; the UI labels it "软件密钥".
- Every TLS CertificateVerify and the self-signed certificate are signed
  through `SecKeyCreateSignature` behind an opaque / external-signing hook of
  the TLS stack. The private key MUST NOT be copied into TLS-library memory,
  exported, or made extractable. If the chosen TLS stack cannot sign through
  such a hook, the implementer files a CONTRACT CHANGE REQUEST; it does not
  weaken this rule (review assumption 3).

The key is never written to logs, files, the Worker or the model. If the
Keychain reports the item absent while any enrollment record exists, the phone
is in `phone_key_lost`: no session, no silent regeneration; only "reset phone
key" (§3.4) leaves it. A transient Keychain error (locked device) is not loss
and changes nothing.

### 4.2 Board key and record

- Key: unchanged `pdsh_id/priv` (32-byte P-256 scalar, plain NVS). The device
  fingerprint of a board already running the TOFU firmware does not change.
  The device key signs only TLS 1.3 CertificateVerify messages and the board's
  own certificate: firmware that carries the secure service MUST NOT advertise
  or execute `pdsh.identity.prove` (§11.3). Board ECDSA signatures with the
  device key MUST be deterministic (RFC 6979: `MBEDTLS_ECDSA_DETERMINISTIC` /
  `PSA_ALG_DETERMINISTIC_ECDSA`); this is invisible on the wire (the phone
  verifies any valid ECDSA signature). If the pinned stack cannot do this on
  the TLS signing path, the implementer files a CONTRACT CHANGE REQUEST.
- Record: NVS namespace `pdsh_enr`, key `rec_v1`, UTF-8 JSON per
  `schema/ble-secure-enrollment-record.schema.json` with `side:"board"` and
  state `committed` or `revoked` only.
- Boot classification: `priv` OK and no record → `none`; `priv` OK and valid
  record → its state; `priv` OK and record unreadable/invalid →
  `record_corrupt`; `priv` NOT_FOUND and record present (any state, even
  corrupt) → `key_lost`; `priv` NOT_FOUND and no record → generate a key under
  §2 randomness (first install or total erase; no authority existed); any other
  `priv` read error or wrong length → `key_unavailable`. No state except
  `identity-reset` ever regenerates a key or clears a record.

### 4.3 Phone records

One file per device fingerprint: `Application Support/phoneDSH/ble-enrollment/v1/<device 64 hex>.json`,
UTF-8 JSON per the record schema with `side:"phone"`, written by atomic
replace with file and directory `fsync`, under an exclusive lock file in the
same directory, and read back before reporting success. An unreadable,
malformed, unknown-version or inconsistent file (name ≠ `device`, `phone` ≠
current key while `committed`) is `record_corrupt` for that device: preserved
byte-for-byte, never used, never overwritten except by an explicit user
recovery that first moves it aside to `<name>.corrupt-<n>`.

There is no anti-rollback anchor on either side. Restoring an older phone
backup or board flash image can revive an older committed record; this is a
declared non-goal (§1).

### 4.4 Lifecycle rules

- **Session eligibility** requires, on each side independently: own key
  present; own record for the peer `committed`; record `phone` equal to the
  current phone key (phone side) or to the peer certificate pin (board side).
- **No atomic two-party commit.** Each `committed` is a local fact. The
  readiness exchange (§8.3) proves that, at that moment, both endpoints hold
  committed records with the same eid and both IDs; it does not prove what the
  other side will retain after a later failure. If either side is staged,
  revoked, missing or different, readiness fails and no task flows. Recovery
  is a new ceremony (new eid) after the operator revokes/forgets the stale side.
- **One phone per board.** A board with a committed record refuses `begin`
  (`occupied`) until `revoke`.
- **Many boards per phone.** The phone keeps one record per device ID and
  connects to exactly one selected record at a time (§8.2).
- **Key change.** A changed device key (after `identity-reset` or a different
  board) has a different device ID: no record matches, the TLS pin fails,
  nothing is re-trusted in band. A changed phone key matches no board record.
  Both require a new ceremony.
- **Forget/revoke** first ends the live session generation (§8.4), then writes
  `revoked`. The revoked record (with its eid) is retained.
- **Orphaned slots (accepted liveness limit).** A board slot `accepted` by a
  revoked phone or by an old phone key can never be completed or failed over
  the session; with four slots and no eviction (§10) such slots reduce
  capacity until the board's task store is cleared out of band.

## 5. Transport, discovery and pre-authentication limits

- GATT primary service `d04ea024-c7fd-4a52-9ace-cf9d7567d0e6` ("PDSH secure
  session v1") containing exactly one characteristic: the Apple L2CAP PSM
  characteristic `abdd3056-28fa-441d-a470-55a75a52553a`, read-only, value =
  PSM as u16 little-endian, exactly 2 bytes, in the dynamic LE range
  `0x0080–0x00FF`. Any other length or range → secure session unavailable on
  this connection.
- The PSM, the service and any advertisement are untrusted routing data. The
  phone reads the PSM afresh on every connection and never caches it. The
  phone MUST NOT treat LE encryption, bonding or a successful read as
  authentication. When the board holds an LE bond it SHOULD require LE
  encryption for the PSM read and the CoC, as attack-surface reduction only.
- Transport: one LE credit-based L2CAP connection-oriented channel (CoC) per
  LE connection and at most one CoC on the board in total; the board refuses a
  second concurrent CoC. TLS records are written as an unframed byte stream
  across SDUs; SDU boundaries carry no meaning.

**Pre-authentication resource limits (board, review H3).** Everything below
holds before and after authentication; a peer that violates a rule loses the
CoC (L2CAP disconnect of the channel), never the LE link, and ordinary Link
and standard GATT continue.

| Item | Rule |
| --- | --- |
| receive MTU / MPS | MTU ≥ 256 (reference 512); MPS as configured; SDU length 0 or > MTU → close (`sdu_empty`, `sdu_oversize`); K-frame information payload > MPS → close (`kframe_oversize`); more bytes than the announced SDU length → close (`sdu_overrun`) |
| credits | at every instant, credits held by the peer + K-frames buffered but not yet consumed ≤ receive K-frame buffers. The initial grant equals the free buffers; credits are returned only when TLS has consumed an SDU and its buffers are free. A K-frame received while the peer holds no credit → close (`credit_overrun`), and the board MUST check credits before touching any receive slot |
| buffering | per CoC: receive K-frame buffers ≤ 4 (reference 3); one TLS input and one output buffer of ≤ 4352 + 256 bytes; one incomplete application frame (≤ 4098 bytes); total heap for one secure session ≤ 32 KiB, allocated on CoC accept and freed on close; global: one session |
| send path | at most 2 SDUs queued to the host stack; the producer waits for completion instead of queueing more; every NimBLE send return (including `BLE_HS_ESTALLED` and send-after-disconnect) has one documented buffer owner, and no byte is ever sent twice |
| timers | CoC open → handshake complete 15 s; after a failed or timed-out handshake the board accepts no new CoC for 2 s; after 3 consecutive failed handshakes on one LE connection the board refuses further CoCs on that LE connection |

The firmware implementer MUST record, in its change, which mechanism
guarantees "credits checked before touching a receive slot" in the pinned
NimBLE (an upstream fix with commit ID, a local wrapper on the real receive
path, or a build-time configuration with its argument) and prove it with the
`coc-*` rows of the conformance matrix (§13).

Fixtures: `golden/ble-secure-coc-cases.jsonl` (credit accounting and every
close reason, replayed through the board's real receive path above a fake
L2CAP).

## 6. TLS 1.3 profile

### 6.1 Handshake parameters (both ends, exactly)

| Item | Value |
| --- | --- |
| Version | TLS 1.3 only (`supported_versions` = 0x0304); RFC 9846 |
| Roles | phone = client, board = server |
| Cipher suite | `TLS_AES_128_GCM_SHA256` (0x1301) only |
| Group / key share | `secp256r1` (0x0017) only; the client always sends a P-256 key share; the server answers a ClientHello without one with `handshake_failure`, never HelloRetryRequest |
| Signature schemes | `ecdsa_secp256r1_sha256` (0x0403) only, in `signature_algorithms` and `signature_algorithms_cert` and the CertificateRequest |
| Key exchange mode | full (EC)DHE handshake only. The client sends no `pre_shared_key`, `psk_key_exchange_modes`, `early_data`, `post_handshake_auth`, `server_name`, `max_fragment_length` or `record_size_limit`. The server MUST NOT select a PSK or accept early data; whether it aborts on such extensions or ignores them and completes a full handshake is the server's choice (both are conformant). The server sends no NewSessionTicket |
| Client authentication | mandatory: server sends CertificateRequest (no `certificate_authorities`); an empty client Certificate → `certificate_required` alert |
| ALPN | client offers exactly `pdsh-ble-task/1`; server selects it or aborts with `no_application_protocol`; client aborts unless it was selected |
| Resumption, 0-RTT, PSK, tickets | not used; a client MUST NOT store or use any ticket it receives |
| Application data ordering | the board MUST NOT send application data (including 0.5-RTT data) before it has verified the client Certificate, CertificateVerify and Finished; the phone MUST NOT act on any application data delivered before its own handshake has returned and the server pin (§6.2) has passed — such data is a server message before `ready_req` and fails the session (`malformed`) |
| Post-handshake | neither end sends KeyUpdate; a received KeyUpdate fails the session (alert `unexpected_message` if the stack can send one, else close). Post-handshake authentication not used |
| Record size | each end is **configured** so that every outgoing record plaintext is ≤ 4352 bytes, and MUST reject an incoming record whose plaintext exceeds 4352 bytes with `record_overflow`. The largest handshake flight (a 1024-byte certificate plus CertificateVerify) fits the configured input buffer without handshake-message reassembly across buffers |

Any deviation fails the handshake; there is no fallback profile and no
plaintext mode. The ALPN identifier is unchanged from v1 (`pdsh-ble-task/1`):
v1 was never deployed, and the v2 wire messages are identical to v1; a future
revision that changes the wire uses a new ALPN identifier, and an endpoint
MUST NOT accept an ALPN it does not implement.

### 6.2 Certificates and pins

Each endpoint presents exactly one self-signed X.509 v3 certificate for its
enrolled key. Producer profile: serial 1–20 bytes; subject = issuer =
`CN=pdsh-ble-device` or `CN=pdsh-ble-phone`; validity `20260101000000Z` to
`99991231235959Z`; SPKI `id-ecPublicKey`/`prime256v1`, uncompressed point;
signature `ecdsa-with-SHA256`; extensions exactly basicConstraints (critical,
cA FALSE) and keyUsage (critical, digitalSignature); DER ≤ 1024 bytes.

A received certificate list is accepted iff **all** of the following hold; a
rejection reports the first failing reason in this order:

1. exactly one certificate (`no_certificate`, `chain_length`);
2. DER ≤ 1024 bytes (`oversize`) that parses as X.509 **v3** (an absent or
   other version is `malformed`);
3. SPKI is `id-ecPublicKey` with `prime256v1` and a valid uncompressed P-256
   point (`curve`), and its fingerprint equals the expected pin
   (`pin_mismatch`): on the board, the committed record's phone; on the phone,
   the device of the **one record the user selected** for this connection
   (§8.2) — never "any committed record";
4. the certificate's signature algorithm is `ecdsa-with-SHA256` in both
   places (`signature_algorithm`) and the signature verifies under its own
   SPKI (`bad_self_signature`);
5. basicConstraints absent or cA FALSE (`ca_true`); keyUsage present and
   including digitalSignature (`key_usage`); no extendedKeyUsage
   (`eku_present`); no unrecognized critical extension
   (`unknown_critical_extension`).

Not evaluated: validity dates (neither side has a trusted clock; enrollment
and revocation replace expiry), subject/issuer names, serial, unknown
non-critical extensions, and trust-chain status.

**Required outcome, mechanism free (review assumption 1).** Rules 1–5 are the
only acceptance decision; nothing else may accept a certificate, and nothing
else may reject one that passes them. The decision MUST be the application's
own evaluation of the received leaf DER, performed inside the TLS handshake,
and a negative decision MUST abort the handshake with `bad_certificate` before
any application data. An end MUST NOT use an "optional verify" mode whose
result is checked after the handshake. How an end reaches this outcome with
its library (verify callback, custom certificate verifier, cleared library
flags) is its own choice; the loopback rows `tls-certificate-vectors` and
`tls-negative-decision-aborts-handshake` of §13 prove it. Possession of the
private key is proven by TLS CertificateVerify; the pin is the only trust
decision.

Fixtures: `golden/ble-secure-certificates.jsonl` (DER per case with the
decision; dates, names, an absent basicConstraints and non-critical extensions
are accepted; another enrolled device's certificate, X.509 v1, compressed and
off-curve SPKI points are rejected). The checker re-derives every decision
from the DER with its own parser and verifier.

## 7. Application framing and messages

### 7.1 Framing

Inside the TLS application-data stream each message is
`length:u16 little-endian ‖ payload`, `1 ≤ length ≤ 4096`. A length of 0 or
greater than 4096 is a fatal `limit` error as soon as the two length bytes are
known, before any payload is buffered. TLS record boundaries and CoC SDU
boundaries are not message boundaries; a receiver handles arbitrary splits and
coalescing, buffers at most one incomplete frame (≤ 4098 bytes) and never
delivers a payload twice. Bytes left over at TLS close_notify, EOF or
disconnect are `truncated`: discarded, never delivered.

Fixtures: `golden/ble-secure-frames.jsonl` (unchanged from v1).

### 7.2 Payload decoding

A payload MUST be UTF-8 without a byte-order mark, exactly one JSON object
(insignificant JSON whitespace allowed, member order free), with no duplicate
member names at any depth (compared as decoded Unicode scalar sequences), no
NUL and no unpaired surrogate in any string or name, and no `NaN`/`Infinity`.
Integers are JSON integers without fraction or exponent. Members are closed:
an unknown member, unknown `v`, unknown `t`, a type sent in the wrong
direction, or any schema violation is a fatal `malformed` error. Byte limits
are counted in UTF-8: `output` ≤ 1024 bytes, failure `message` ≤ 256 bytes. A
`task` inside `next_r` MUST additionally satisfy every task rule of
task-delegation.md (§ Task and result), whose own unknown-member policy applies
inside the task object only.

Shape authority: `schema/ble-secure-message.schema.json`. Fixtures:
`golden/ble-secure-messages.jsonl` (hex payloads, valid and invalid).

### 7.3 Messages

Client → server (`seq` = 1…65535, strictly +1 per session starting at 1):

| `t` | Members besides `v:1`, `t`, `seq` | Meaning |
| --- | --- | --- |
| `ready_req` | `device`, `phone`, `eid`, `cc` | first message; the client's committed record and fresh client challenge |
| `next` | `sc` | read the next task offered to this phone |
| `accept` | `sc`, `id`, `idem` | queued → accepted by this phone |
| `complete` | `sc`, `id`, `idem`, `output`, `truncated` | accepted → completed |
| `fail` | `sc`, `id`, `idem`, `failure{kind,message}` | accepted → failed |
| `status` | `sc`, `id`, `idem` | query-only reconciliation; also the keepalive (§8.1) |
| `err` | `re`, `code` (no `seq`) | client-detected fatal error; then close. A client `err` MUST carry `re: 0` |

`id`/`idem` are the task `id` and `idempotency_key`; `sc` echoes the server
challenge of this session. Failure kinds and outcome bodies are those of
task-delegation.md.

Server → client (`re` = the request's `seq`):

| `t` | Members besides `v:1`, `t`, `re` | Meaning |
| --- | --- | --- |
| `ready_ack` | `device`, `phone`, `eid`, `cc` (echo), `sc` | `re` = 1 |
| `next_r` | `task` (object or null), `phase` (`queued`, `accepted`, or null with null task) | |
| `r` | `result` (`applied` / `duplicate`), `phase` after the request | |
| `status_r` | `phase` (`unknown`, `queued`, `accepted`, `completed`, `failed`), `mine`, optional `outcome` | `mine` = the slot's owner is this phone (false for unknown/queued); `outcome` present iff terminal and `mine` |
| `err` | `code` | `re` = request seq, or 0 if unsolicited |

### 7.4 Error codes

Closed set. **Fatal** (sender then sends close_notify and closes the CoC):
`malformed`, `limit`, `bad_sequence`, `bad_challenge`, `not_ready`,
`record_mismatch`, `revoked`, `storage`, `timeout`, `internal`. (An
unenrolled peer never gets this far: it fails the TLS pin with
`bad_certificate`.) **Request-level** (session continues): `unknown_task`,
`invalid_transition`, `conflict`, `wrong_owner`; the board sends them only in
answer to `accept`, `complete`, `fail` (all four) and `status` (`conflict`
only). An unknown code fails §7.2 decoding and is therefore fatal `malformed`.
`internal` is reserved for a local fault with no more specific code. TLS
alerts, CoC loss and decryption failure are fatal without an `err` message.

## 8. Session state machines

### 8.1 Limits and timers (monotonic clocks)

| Item | Value | Reason |
| --- | --- | --- |
| concurrent secure sessions | board 1; phone 1 per device ID | |
| outstanding requests | 1 (client sends the next request only after the response) | |
| requests per session | ≤ 65535 (`seq` exhausted → client closes and opens a new session) | |
| CoC open → local handshake complete | 15 s, each side | |
| phone handshake complete → valid `ready_ack` | 10 s | |
| board handshake complete → `ready_req` | 10 s (`err timeout`, close) | |
| phone wait for any response | 10 s → `err timeout`, close; the request outcome is unknown (§9.3) | board work per request is one NVS commit |
| phone keepalive | while the phone has an accepted or running task for this device and nothing else to send, it sends `status` for that task at most 30 s after the previous response | three keepalives fit in one idle period |
| board idle while ready | 90 s without a request → `err timeout`, close | 3 × keepalive, tolerates one lost keepalive round trip |
| session lifetime | 600 s from handshake completion; both close with close_notify only (no `err`); a request arriving later is not dispatched | bounds one TLS key schedule; > the 300 s task execution bound of task-delegation.md, so most tasks finish inside one session |
| grant accept window | 1800 s from the user's grant: `next` and `accept` allowed | one foreground working period |
| grant report window | until 600 s after the accept window ends: `status`, `complete`, `fail` only | ≥ 300 s execution bound for a task accepted at the last moment + one session renewal (15 s + 10 s + timeouts) with margin |
| failed session attempts | 3 consecutive session attempts that do not reach readiness end the grant | stops automatic reconnect loops |

Timers never extend on retransmitted or duplicate bytes. Why (review M3): in v1
the board closed an idle session after 60 s and the grant ended with every
session, so a five-minute task could not report its result without a new user
grant. In v2 `status` is the keepalive, and the grant belongs to the
CoreBluetooth connection generation, not to one TLS session; it still has an
explicit, bounded expiry.

### 8.2 Phone

**Generation and grant.** A **connection generation** is the phone's
non-reusable local token for one CoreBluetooth connection to one selected
device (the existing BLE connection/closing rules of ble-link.md apply;
CoreBluetooth offers no request token and none is invented). Inside one
generation the phone runs one or more **sessions** (each a fresh CoC, full
handshake and readiness), one at a time. The task grant is
task-delegation.md's intake grant for this generation and device ID: it is
created only by an explicit foreground user action after at least one session
of this generation has reached readiness; the grant UI names the selected
record's label and device ID, never the peripheral name or an advertisement.
The grant survives the close of a session (idle, lifetime, `seq` exhaustion,
response timeout, fatal error) and the phone MAY open a new session in the
same generation without a new grant. The grant ends — and the generation's
live session is closed first — on: disconnect, app background, forget, a
change of the selected record (state or rev), phone key loss or change, user
revocation, the end of the report window, or the third consecutive failed
session attempt.

**Device selection (review M1).** The user selects exactly one committed
record before the phone connects; that record is the generation's device. The
server pin of §6.2 is that record's device only; a certificate of any other
key — including another board the phone has enrolled — fails with
`pin_mismatch` and counts as a failed session attempt.

States per session: `closed → ready_wait → ready → closed` (PSM read, CoC and
handshake precede `ready_wait`).

1. Eligible only with the phone key present and the selected record
   `committed`. Read the PSM (§5), open the CoC, run the TLS client.
2. After the local handshake returns, re-check the generation and that the
   selected record is still `committed` with the same rev. Then send
   `ready_req` (seq 1) with a fresh `cc`. No task data is sent earlier.
3. On the response to `ready_req`: an `err` closes without reply; any type
   other than `ready_ack`, or `re ≠ 1`, → send `err malformed`; `device`,
   `phone` or `eid` ≠ the selected record → `err record_mismatch`; `cc` ≠ the
   sent challenge → `err bad_challenge`. Each closes without readiness and
   counts as a failed attempt. Otherwise store `sc`; the session is ready.
4. Requests are sent only while ready, with no outstanding request, with the
   grant active (`next`, `accept`) or active/report-only (`status`,
   `complete`, `fail`), with `seq = last + 1` and the session `sc`. With
   `last = 65535` the phone closes and opens a new session instead.
5. **Responses after readiness (review M2).** Let `O` be the outstanding
   request. A received fatal `err` with `re = 0` or `re = O.seq` closes the
   session; `O`'s outcome is unknown. Otherwise the response MUST have
   `re = O.seq` and match this table; anything else — a response with no
   outstanding request, another `re`, a duplicate, another type, another
   phase, a request-level `err` where none is allowed, a `ready_ack` — makes
   the phone send `err malformed` and close; `O`'s outcome is unknown and its
   intent stays for §9.3 recovery.

| Request | Acceptable response | Phone result |
| --- | --- | --- |
| `next` | `next_r` null/null | no task |
| `next` | `next_r` with a task that passes task-delegation validation, phase `queued` | task offered → §9.2 |
| `next` | `next_r` with such a task, phase `accepted` | accepted offer → §9.2 (never executed without a parent record) |
| `next` | `next_r` whose task fails task-delegation validation | fatal: `err malformed`, close |
| `next` | `next_r` whose task conflicts with an existing parent of this device (same `idempotency_key` with a different task, or same `id` with another key) | local conflict: not accepted, user-visible; no further `next` in this session; other requests continue |
| `accept` | `r` with `phase = accepted` (`applied` or `duplicate`) | applied: record `accepted` |
| `complete` | `r` with `phase = completed` | applied |
| `fail` | `r` with `phase = failed` | applied |
| `accept`, `complete`, `fail` | `err` `unknown_task`, `invalid_transition`, `conflict` or `wrong_owner` — on a first send or a resend | unresolved: keep the intent, never resend, user-visible; the session continues |
| `status` | `status_r` | delivered to §9.3 (or a keepalive) |
| `status` | `err conflict` | unresolved |

6. Ready is not permission: see "Generation and grant".

Fixtures (`side=phone` in `golden/ble-secure-session-sequences.jsonl`):
selection with two enrolled boards and a swap, readiness acceptance and every
rejection, the response table (positive and negative rows, including
request-level errors on a first send, wrong `re`, wrong type, wrong phase,
duplicate and unsolicited responses), local conflict, invalid offered task,
resend rules, `seq` exhaustion, response timeout, grant windows, session
renewal under one grant, failed-attempt limit and generation end.

### 8.3 Board

States: `listening → handshake → verified → ready → closed`.

1. TLS server with the client pin = the committed record's phone; without a
   committed record no CoC is served past the handshake (`bad_certificate`).
   Capture the record tuple (state, device, phone, eid, rev) at handshake
   completion.
2. In `verified` the only acceptable message is `ready_req` with `seq = 1`:
   another type → `not_ready`; another seq → `bad_sequence`; `device`,
   `phone` or `eid` different from the captured record → `record_mismatch`.
   A `ready_req` buffered before the handshake completed is processed only
   after it completes. On success draw a fresh `sc`, send `ready_ack`, enter
   `ready`.
3. In `ready`, for each request in order: `ready_req` again or
   `seq ≠ last+1` → `bad_sequence`; `sc` ≠ session `sc` → `bad_challenge`;
   RAM revocation flag set, or the current durable record differs from the
   captured tuple in **any** field (state, device, phone, eid, rev) →
   `revoked`. Only then dispatch (§9.1). These checks run immediately before
   every store mutation as well.
4. A client `err` closes without reply. Any fatal error closes. Timers per
   §8.1.

### 8.4 Closure and invalidation

Closing a session is: send `err` if a TLS session exists and the cause is
protocol-level (not on lifetime expiry), send close_notify, close the CoC,
discard all session state (challenges, sequence, buffered frames, captured
record, outstanding request). Disconnect, CoC loss, TLS alert, timer expiry,
`revoke`/forget, record or key change, manager off and app background each
close the session; those listed under "Generation and grant" also end the
generation. On the phone the session (and, where applicable, the generation)
is invalidated **before** any asynchronous teardown, so a late completion,
response or callback is discarded and cannot restore readiness, a grant or a
result. Every session starts at a fresh handshake with fresh challenges.
Closure never undoes or proves the absence of a device store mutation already
committed.

Fixtures (`side=device`): request before readiness, wrong eid/device, replayed
and skipped `seq`, stale `sc` from another session, second readiness, wrong
peer certificate, revoked record, revocation mid-session, a record replaced
mid-session by another still-`committed` record (and by a rev bump), ready
timeout, idle timeout, keepalive, lifetime, client error, server-only type
from the client.

## 9. Tasks over the session

### 9.1 Board semantics

The board's only side effects are task store transitions (§10). Every
transition commits NVS before its response is sent. Let `me` = the session's
`phone:` ID.

- `next`: the oldest slot that is `queued`, or `accepted` with `by = me`;
  `next_r` with that task and phase, else null/null. Slots owned by another
  phone or accepted without owner (pre-upgrade plaintext) are never offered.
- `accept`: unknown id → `unknown_task`; `idem` ≠ slot key → `conflict`;
  `queued` → set `accepted`, `by := me`, answer `applied`; `accepted` by me →
  `duplicate`; owned by another or no owner → `wrong_owner`; terminal by me →
  `invalid_transition`.
- `complete` / `fail`: unknown → `unknown_task`; key mismatch → `conflict`;
  `queued` → `invalid_transition`; not owned by me → `wrong_owner`;
  `accepted` → set terminal with the exact outcome body, `applied`; same
  terminal kind and identical outcome → `duplicate`; otherwise `conflict`
  (the stored outcome never changes).
- `status`: unknown → `status_r phase=unknown mine=false`; key mismatch →
  `conflict`; else phase, `mine`, and the outcome only if terminal and mine.
- A storage failure on any mutation is fatal `storage`; the slot is unchanged.

### 9.2 Phone journal binding

The BLE task device identity is the session's device ID `ble:<64 hex>`. It is
used unchanged as `device_id` in the phone task journal v1 and its `msg_id`
derivation (task-delegation.md), so the journal format does not change.

Before sending `accept`, `complete` or `fail` for the first time, the phone
durably installs a transition intent in the task journal's `ble-secure-ops`
subdirectory: file `<msg_id>-<action>.json` per
`schema/ble-secure-task-intent.schema.json` with `device_id`, `phone_id` (the
current phone key), `task_id`, `action`, `idem` and `arguments_sha256` =
SHA-256 of the canonical UTF-8 JSON of exactly the request arguments
(`{id,idem}`, `{id,idem,output,truncated}` or `{id,idem,failure}`): object keys
sorted, no insignificant whitespace, non-ASCII and `/` literal, `"` and `\`
escaped, U+0008/0009/000A/000C/000D as `\b \t \n \f \r`, other U+0000–U+001F
as `\u00xx` lowercase. The same atomic-install, lock, size, inventory and
fail-closed rules as the legacy `ble-ops` directory apply (task-delegation.md
§ Legacy BLE intent inventory), with secure intents matched to parent records
of the same device ID; complete/fail arguments are reconstructed solely from
the persisted parent terminal outcome. A pre-existing intent is never
rewritten. There is no Link request UUID.

Parent journal transitions keep their task-delegation meaning: the parent is
persisted (`received`) before `accept` is sent; `accepted` is recorded only
after `r` (`applied`/`duplicate`, phase `accepted`) or a §9.3 `applied`
decision, and before any DSH prompt; terminal outcomes are persisted before
`complete`/`fail` is sent. A `next_r` with phase `accepted` for which the phone
has no parent record is never executed; it stays unresolved and may only be
reported `fail` with `unknown_outcome` after an explicit user action that
itself follows the intent rules. An `accepted`/`running` parent offered again
by `next_r` follows task-delegation's unknown-outcome rule; the keepalive is
`status`, never `next`, so a running task is not re-offered by keepalives.

Fixtures: `golden/ble-secure-task-intents.jsonl`.

### 9.3 Lost replies, crashes and reconnection

TLS prevents replay and reordering inside one session; across sessions the
fresh challenges and `seq` restart make old messages unusable. Durable
idempotency is separate: when a response to `accept`/`complete`/`fail` is lost
(timeout, disconnect, crash, fatal error, malformed response), the phone keeps
the intent and, in a later ready session for the same device ID, first sends
`status` for that task and decides:

| Intent | `status` answer | Decision |
| --- | --- | --- |
| any, intent `phone_id` ≠ current phone key | anything, including no session | unresolved |
| accept | `accepted`, mine | applied |
| accept | `queued` | resend the identical persisted arguments |
| complete/fail | terminal, mine, same kind and identical outcome | applied |
| complete/fail | `accepted`, mine | resend identical arguments |
| any | `err conflict`; `unknown`; not mine; other terminal; `queued` for complete/fail | unresolved — keep, never resend, user-visible |
| any | no session, timeout, other fatal error | retry the query in a later session |

**Resend rule (review assumption 5).** A resend MUST be the very next request
the phone sends after that `status_r`, in the same session. If any other
request is sent first, or the session closes, the decision is void and the
phone queries again. A resend is never permitted on a missing, failed or
ambiguous answer, after a phone key change, or for the DSH turn itself: phone
restart with an accepted/running task still yields `unknown_outcome` under
task-delegation.md, never a second turn. A request-level error to a resend is
unresolved like one to a first send (§8.2).

Resend is safe because the board's transitions are deterministic,
owner-checked, single-session state changes with no external effect and no
transition back to `queued`, so a `queued` / `accepted, mine` answer proves the
earlier send was not applied and the precondition still holds.

Board crash: a transition is durable before its response; after reboot the
store tells the truth and the phone reconciles through `status`. Phone crash:
intents and parent records are durable before each send.

Fixtures: `golden/ble-secure-recovery.jsonl` (including phone key change);
phone-side resend sequencing in `golden/ble-secure-session-sequences.jsonl`;
device-side transitions there too (duplicate accept, conflicting terminal,
wrong owner, legacy accepted slot, idempotency-key mismatch, storage failure on
accept, complete and fail, reconnect after a lost reply).

### 9.4 Time

The board has no trusted clock and does not evaluate `deadline`. The phone
applies the task-delegation deadline rules with its own clock; certificate
dates are never used (§6.2). A monotonic session timer never establishes
task validity across restarts.

## 10. Reference firmware task store v2

NVS key `tasks_v2` (namespace unchanged), UTF-8 JSON per
`schema/ble-secure-task-store.schema.json`: `v:2`, `v1_sha256`, and v1 slots
plus optional `by` (`phone:` ID) on non-queued slots. At most four slots;
outcome iff terminal; no eviction; full store rejects local submission.
`v1_sha256` is the SHA-256 of the exact `tasks_v1` bytes present when the v2
document was first written, or null if `tasks_v1` was absent; every later v2
write keeps the value. Selection at boot:

| NVS | Result |
| --- | --- |
| `tasks_v2` valid, `tasks_v1` absent | use v2 |
| `tasks_v2` valid, `tasks_v1` present with SHA-256 = `v1_sha256` | use v2; `tasks_v1` ignored |
| `tasks_v2` valid, `tasks_v1` present and unreadable, or its SHA-256 ≠ `v1_sha256` (including `v1_sha256` null) | **disabled**: older firmware ran after the migration and changed `tasks_v1` (review M6); never merge, never drop silently |
| `tasks_v2` present but unreadable/invalid | disabled; **no** fallback to v1 |
| only `tasks_v1`, valid | migrate: view = v1 slots without `by`; the first mutation writes the complete v2 document with `v1_sha256` = SHA-256 of the stored `tasks_v1`; `tasks_v1` is left byte-identical |
| only `tasks_v1`, invalid/unreadable | disabled (as today) |
| neither | empty; the first write carries `v1_sha256: null` |

A disabled store refuses local submission and every session mutation
(`next_r` null, transitions `storage`); recovering it is an out-of-band erase
of the task keys by the operator. Pre-upgrade accepted slots have no owner and
are never offered or mutated over the session (§9.1). The local producer API
and `tools_task_result` read and write v2 after the upgrade. Fixtures:
`golden/ble-secure-task-store-cases.jsonl` (NVS text of an object value = its
compact JSON in fixture member order; `write_v1_sha256` is what the next v2
write carries).

## 11. Legacy data, plaintext refusal and unchanged profiles

1. **Ordinary Link and standard GATT are unchanged** (HELLO, opcodes, Tools v1,
   receipts, RESULT, events, permissions, iOS ordering rules of ble-link.md),
   with two board-side exceptions owned here: while the board is in
   enrollment mode a button gesture emits no `button.pressed` event and opens
   no pairing window (§3.3); and `pdsh.identity.prove` is retired (item 3).
   The secure service is additive.
2. **Plaintext task access is refused permanently.** The ordinary Link ingress
   never advertises or starts `pdsh.task.*`, regardless of `app_caps` bit10 or
   bit11 (`UNSUPPORTED` 14, no receipt, no store change;
   `golden/ble-task-plaintext-admission.jsonl`). No negotiation, error,
   capability or configuration ever falls back to it, on either end.
3. **Old identity labels and the prove tool.** `pdsh.ble.trustedIdentities`
   entries, including a label byte-identical to a device ID, are preserved per
   legacy-identity-preferences.md and never imported as enrollment records.
   Firmware that carries the secure service MUST NOT list
   `pdsh.identity.prove` in `tools/list` and answers a call to it exactly like
   a refused plaintext task call (`UNSUPPORTED` 14, no receipt, no signature),
   so the device key is never an unauthenticated signing oracle (review M4).
   No phone build calls the tool (ble-identity.md §1), so nothing on the phone
   changes.
4. **Old phone journals.** Parent records whose `device_id` is `ble:<UUID>`
   and every `ble-ops` intent are preserved byte-for-byte, keep their existing
   inventory and read-only inspection rules, and are never dispatched,
   reported, resent, converted to a device ID or attributed to an enrolled
   key. They cannot collide with secure records because `msg_id` includes the
   device ID string.
5. **Old board data.** `pdsh_id/priv` is kept; `tasks_v1` is migrated per §10;
   Link receipts are unchanged. A pre-upgrade task transition's Link RESULT
   returns only `{request_id,status,result:{}}` (its result is the empty
   object), and `pdsh.task.next` results were held only in RAM
   (`readonly_result` in `link_tools.c`, cleared at `tools_init` and HELLO), so
   no pre-upgrade task body or outcome survives in any Link receipt; leaving
   ordinary RESULT unchanged reveals no task content, no receipt quarantine is
   introduced, and no Link receipt is ever created for a secure transition.

## 12. Compatibility and rollback

| Producer → consumer | Behaviour |
| --- | --- |
| old phone → new firmware | ordinary Link unchanged except §11.1; old phone ignores the secure service; plaintext tasks refused as today; an old phone that calls `pdsh.identity.prove` (none ships one) gets `UNSUPPORTED` |
| new phone → old firmware | no secure service → BLE tasks unavailable, shown as "设备不支持安全任务会话"; no fallback; ordinary Link unchanged |
| new ↔ new, not enrolled / one side staged | handshake or readiness fails closed; UI points to the offline ceremony |
| new ↔ new, both committed | sessions per this contract |
| v1 ↔ v2 implementations | not supported and not needed: v1 was never implemented or released; the wire messages and ALPN are unchanged, but the enrollment console grammar (`mode`, `armed`, new error codes) and the task store document (`v1_sha256`) are not v1-compatible. No build may ship a v1 end |
| future revision | new ALPN; mismatch → `no_application_protocol`; no downgrade |
| old phone data → new phone | §11.3–11.4: preserved, inert |
| old board data → new firmware | §4.2 key kept, §10 migration |
| phone rollback | supported only to app builds that refuse every BLE task grant (the 2026-11-07 containment: `BLEDeviceStore.grantDeviceTasks(enabled: true)` always throws); rollback to an earlier build is **unsupported**. In a supported older build, enrollment files, `ble-secure-ops` and secure parent records are preserved and **not dispatched**: its executor refuses before touching the journal without authorization (`DeviceTaskExecutor.process` throws `unauthorized` first), and no BLE grant can exist; its reader accepts `ble:<64 hex>` device IDs as ordinary records; LAN is unaffected. Rolling forward resumes from the preserved state |
| firmware rollback | `rec_v1` and `tasks_v2` are ignored by old firmware; the old firmware sees the `tasks_v1` snapshot (stale phases, no post-upgrade tasks). Supported only to firmware that contains the plaintext-task denial (`PC-20261107-plaintext-task-admission`); earlier firmware could re-serve stale queued tasks over plaintext and is **unsupported** |
| firmware roll-forward after rollback | if the older firmware changed `tasks_v1`, the v2 store is **disabled** at boot (§10: SHA-256 mismatch), never merged and never silently dropped; tasks submitted under the older firmware are visible only by inspecting `tasks_v1` out of band. If `tasks_v1` is unchanged, v2 continues |

## 13. Shared fixtures and conformance matrix

Every file below is consumed by both ends through their real parsers, state
machines and stores (transport edges may be substituted; trust decisions may
not). `spec/v1/tools/test_ble_secure_session_golden.py` pins each file's
SHA-256, validates it against its schema and replays it through a reference
oracle (certificates through its own DER parser and P-256 verifier); it is a
spec checker, not runtime conformance.

| File | Schema | Swift end | Firmware end |
| --- | --- | --- | --- |
| `ble-secure-identifiers.jsonl` | `ble-secure-identifier-vector` | key validation, IDs, token input | key validation, IDs |
| `ble-secure-enrollment-lines.jsonl` | `ble-secure-enrollment-line` | — (host tooling optional) | console parser and printer |
| `ble-secure-enrollment-states.jsonl` | `ble-secure-enrollment-state-vector`, `ble-secure-enrollment-record` | `side=phone` | `side=board`, with the gesture classifier fed the listed gestures and the indicator driver observed |
| `ble-secure-certificates.jsonl` | `ble-secure-certificate-vector` | server-cert verifier (`role=device`) | client-cert verifier (`role=phone`) |
| `ble-secure-frames.jsonl` | `ble-secure-frame-vector` | frame decoder | frame decoder |
| `ble-secure-messages.jsonl` | `ble-secure-message-vector`, `ble-secure-message` | decoder (both directions) | decoder (both directions) |
| `ble-secure-session-sequences.jsonl` | `ble-secure-session-sequence` | `side=phone` | `side=device` |
| `ble-secure-recovery.jsonl` | `ble-secure-recovery-vector` | recovery decision | — |
| `ble-secure-task-intents.jsonl` | `ble-secure-task-intent` | intent writer/inventory | — |
| `ble-secure-task-store-cases.jsonl` | `ble-secure-task-store-case`, `ble-secure-task-store` | — | store selection, migration and roll-forward check |
| `ble-secure-coc-cases.jsonl` | `ble-secure-coc-case` | — | CoC receive path over a fake L2CAP |
| `ble-secure-conformance-matrix.jsonl` | `ble-secure-conformance-case` | every row with `phone` in `ends` | every row with `board` in `ends` |

Sequence vectors use test hooks that each end MUST provide in its test build
only: an injectable monotonic clock (`elapse`), a forced next storage failure
(`fail_next_write`), record replacement, and `set_last_seq` on the phone.

Live TLS handshakes, CoC attacks, entropy and physical tests cannot be fixed
bytes. `ble-secure-conformance-matrix.jsonl` lists each required case with its
area, ends, layers (`loopback` = the end's real TLS configuration against an
independent peer built from this profile; `host` = host test of the real code
with substituted transport; `device` = real hardware), stimulus, expected
outcome and, where fixed, the alert. Every listed end runs every row at every
listed layer and records the result under the row name; a row not run is
`NOT_RUN`, never `PASS`. The rows cover every §6.1 line negatively (version,
suite, group without HelloRetryRequest, missing key share, signature scheme,
ALPN absent/other/not selected, empty client certificate, PSK and early data
offered, ticket, 0.5-RTT data, KeyUpdate, record overflow and sender cap,
handshake buffer), the §6.2 decision live, every §5 limit (beyond credits,
zero-length SDU, SDU > MTU, K-frame > MPS, garbage instead of ClientHello,
disconnect during a queued send, second CoC, stall, ClientHello flood with
reconnect, enrolled phone still served afterwards), the retired prove tool,
deterministic board signatures, board entropy, and the §14 physical runs.

## 14. Acceptance before `implemented`

Exact per-end commands and file ownership are in the change record §4. Before
this document may change from `target`, and before any BLE task grant is
enabled, record: both ends passing every fixture above through real code;
every conformance-matrix row for each end with its result; a physical
iPhone ↔ reference ESP32-S3 run (with the enrollment button and indicator
fitted) with offline enrollment, a full task round trip, a task of at least
four minutes across a session renewal, reconnect, board reboot and phone
restart recovery; and the negative physical runs of the matrix (unenrolled
phone, unenrolled board, changed device key, revoked board, forgotten phone, a
Mac test peripheral without the device key, two enrolled boards swapped, short
presses that never arm or confirm). Simulator, loopback or static evidence
MUST NOT be reported as device evidence.

## 15. Decisions requiring independent security review

These are frozen for implementation. The review of v1 accepted each with the
conditions recorded in the change record, all of which this revision applies;
items 1–7 of the review's "needs a human security engineer" list remain open
and are tracked there. A change follows AGENTS.md §3.3.

1. Pinned self-signed certificates with dates ignored; outcome-based
   verification (§6.2).
2. No TLS exporter binding: readiness relies on all messages travelling in the
   one pin-verified TLS connection plus echoed per-session challenges, with
   the application-data ordering of §6.1 and device selection of §8.2.
3. Non-exportable phone key: Secure Enclave where present, software Keychain
   only without one; opaque signing (§4.1). Plain-NVS device key on the
   reference board, scoped by §1.
4. Physical authorization by enrollment mode (5 s arm hold, indicator, 300 s
   window, 3 s confirm hold), with every attached USB host trusted (§1, §3.3).
5. Resend after an authoritative `status`, only as the very next request
   (§9.3).
6. No anti-rollback anchor; unsupported rollback to pre-containment firmware
   or pre-containment app builds; roll-forward disables a diverged store.
7. Leaving ordinary Link RESULT unchanged for pre-upgrade task transitions
   (§11.5) instead of the candidate's receipt quarantine.
8. TLS record plaintext cap of 4352 bytes, configured on send and enforced on
   receive, without `record_size_limit`.
9. One device key for TLS with `pdsh.identity.prove` retired and deterministic
   board ECDSA, instead of a separate session key (§4.2, §11.3).
