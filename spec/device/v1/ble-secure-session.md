# BLE authenticated device-task session, v1 (`secure-session-v1`)

Status: `target` — frozen contract, **not implemented on any end**. Revision
label `ble-secure-session.md@secure-session-v1`; the freeze commit is recorded
in [PC-20261108-ble-secure-session](../../../docs/protocol-changes/PC-20261108-ble-secure-session.md).
No caller may enable a BLE task grant on the strength of this document. GAP-16
stays open until both ends implement this revision, run every shared fixture
through their real code, and the physical acceptance in §14 is recorded.

This contract replaces the open questions of the
[candidate](../../../docs/design/device-ble-secure-session-candidate.md) and the
[session-binding CCR](../../../docs/protocol-changes/PC-20261107-ble-session-binding-ccr.md).
It owns: the offline enrollment ceremony, the enrollment records, the BLE
session transport and TLS profile, the application framing and messages carried
inside it, the BLE task identity, the phone's secure transition intents and the
reference firmware task store v2. The task model itself (task fields, phone
journal v1, terminal outcomes, grant generations, isolated DSH session) remains
owned by [task-delegation.md](task-delegation.md); the ordinary Link profile
remains owned, unchanged, by [ble-link.md](ble-link.md).

Key words MUST, MUST NOT, SHOULD and MAY are normative. "Phone" is the iOS app
(TLS client); "device" or "board" is the reference ESP32 firmware (TLS server).

## 1. Threat model and non-goals

**Protected.** Against an active radio attacker who holds neither enrolled
private key, every task, acceptance, result, failure and status byte is
confidential and integrity protected, bound to exactly one previously and
independently enrolled phone-key/device-key pair, and cannot be replayed,
reordered, reflected, moved to another session or downgraded to the plaintext
Link path. Task authority requires: both sides locally committed to the same
enrollment, a fresh mutually authenticated TLS 1.3 handshake, a successful
readiness exchange (§8.3) and, on the phone, an explicit foreground grant.
Lost replies, crashes and timeouts never authorize automatic re-execution (§9).

**Assumed trusted (outside the cryptographic claim).** The operator; the
operator's identification of the physical board; the USB/serial host, its
software and cable used during enrollment; the board firmware image; the phone
OS and app. A malicious provisioning host or compromised firmware can enroll
any key it wishes; nothing here detects that.

**Explicit non-goals.**

1. Relay / distance bounding. A transparent radio relay between the two
   correct endpoints is possible at any time, including after enrollment.
   TLS authenticates endpoints, not proximity.
2. Compromised phone or compromised host. A phone that is itself compromised
   can use its own key; the protocol does not defend the device against it.
3. Device key extraction. The board's P-256 private key is a 32-byte blob in
   plain NVS (`pdsh_id/priv`); flash encryption, secure boot and eFuse changes
   are out of scope and MUST NOT be described as present. Physical access to
   the board's flash yields the key.
4. Physical rollback. A whole-flash restore can bring back an earlier
   enrollment or key; there is no anti-rollback anchor (§4.3).
5. Availability. Jamming, CoC refusal and storage exhaustion can deny service;
   they fail closed.
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

Fixtures: `golden/ble-secure-identifiers.jsonl`.

## 3. Offline enrollment ceremony

### 3.1 Principle

The reference board has no trusted display, so trust is bootstrapped
**offline** through a physically attached, trusted USB/serial host. The phone
learns the board fingerprint from the operator (who copied it from the trusted
host), never from the radio; the board learns the phone fingerprint from the
same host. A physical button press on the board authorizes every
authority-changing board action. Nothing in this ceremony uses BLE. The
existing connected TOFU UI of ble-identity.md is not part of it and MUST NOT
be reused for it.

Sequence (any order between phone steps P2/P3 and board steps B3/B4 is
allowed; the two commits are independent local facts, see §4.4):

```text
P1 phone shows its token  pdsh-phone-v1:<phone fp>
B1 host:  pdsh-enroll begin                    board: begun eid=… device=…
B2 host:  pdsh-enroll phone eid=… phone=…      board: staged … token=pdsh-board-v1:<device fp>:<eid>
P2 operator enters that board token on the phone      phone record: staged
B3 host:  pdsh-enroll commit eid=… device=… phone=…   board: press …
B4 operator presses the board button within 30 s      board: committed … rev=n
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
beginning with `pdsh-enroll-r`.

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
| `status` | `state ctx device phone eid rev` | `state` ∈ none, committed, revoked, key_lost, key_unavailable, record_corrupt; `ctx` ∈ idle, begun, staged, press; `device` is `-` when the key is lost/unavailable; `phone`/`eid` are `-` unless state is committed/revoked |
| `begun` | `eid device` | |
| `staged` | `eid device phone token` | `token` = `pdsh-board-v1:<device>:<eid>` of the same line |
| `press` | `eid action timeout_s` | `action` ∈ commit, revoke, identity-reset; `eid` is `-` for identity-reset; `timeout_s` = `30` |
| `committed` | `eid device phone rev` | |
| `aborted` | `eid` | |
| `revoked` | `eid device phone rev` | |
| `reset` | `device` | new device fingerprint |
| `error` | `code cmd` | `cmd` = verb or `-` for unsolicited timeouts |

Error codes: `syntax`, `busy`, `occupied`, `no_session`, `state`,
`eid_mismatch`, `value_mismatch`, `same_key`, `timeout`, `storage`,
`button_unavailable`, `key_lost`, `key_unavailable`, `record_corrupt`. The set
is closed for this revision; a host receiving another code treats the attempt
as failed.

Fixtures: `golden/ble-secure-enrollment-lines.jsonl` (byte-exact, including CR,
over-length, non-ASCII, tab and lookalike-prefix cases).

### 3.3 Board state machine

The board has a durable state (§4.2) and one volatile console context `ctx`:
`idle`, `begun(eid)`, `staged(eid, phone)`, `press(action)`. The context lives
only in RAM; reboot, replug-induced reset or any power loss returns it to
`idle`. It is the only place a staged phone fingerprint ever exists on the
board.

Processing of an addressed, well-formed command, in order:

1. If `ctx = press`: abort the pending action (`ctx := idle`), respond
   `error code=busy cmd=<verb>`, do **not** execute the command. Any addressed
   line, including `status` and syntax errors, aborts a pending press.
2. A syntax error responds `syntax` and leaves any `begun`/`staged` context
   unchanged.
3. `status` always answers and changes nothing.
4. If durable state is `key_lost`, `key_unavailable` or `record_corrupt`,
   every command except `identity-reset` answers with that state as the error
   code and aborts `ctx`.
5. `begin`: if `ctx ≠ idle` → `busy` and abort `ctx` (concurrent enrollment
   never continues); if durable `committed` → `occupied`; if no enrollment
   button is configured (`PDSH_BUTTON_GPIO = -1`) → `button_unavailable`;
   else draw a fresh `eid`, `ctx := begun`, answer `begun`, and start a
   120-second context deadline.
6. `phone`: `ctx = idle` → `no_session`; `ctx ≠ begun` → `state` + abort;
   eid differs → `eid_mismatch` + abort; phone = device fingerprint →
   `same_key` + abort; else `ctx := staged`, answer `staged`.
7. `commit`: `ctx = idle` → `no_session`; `ctx ≠ staged` → `state` + abort;
   eid differs → `eid_mismatch` + abort; device or phone differs from the
   board key / staged phone → `value_mismatch` + abort; else `ctx := press`,
   answer `press … action=commit`.
8. `abort`: `ctx = idle` → `no_session`; eid differs → `eid_mismatch` and
   abort anyway; else abort and answer `aborted`.
9. `revoke`: `ctx ≠ idle` → `busy` + abort; durable ≠ committed → `state`;
   any field differs from the committed record → `value_mismatch`; else
   `ctx := press`, answer `press … action=revoke`.
10. `identity-reset`: `ctx ≠ idle` → `busy` + abort; durable `committed` →
    `occupied` (revoke first); no button → `button_unavailable`; else
    `ctx := press`, answer `press eid=- action=identity-reset`.

"Abort" means `ctx := idle` with no durable effect. A `begun`/`staged` context
that reaches its 120-second deadline is aborted with an unsolicited
`error code=timeout cmd=-`.

**Button.** In `press`, only a press edge (release→press, debounced ≥ 50 ms)
observed *after* the `press` line was written counts; a held or earlier press
does not. No press within 30 s → `error code=timeout cmd=<action>`, abort.
Outside `press`, the button keeps its existing meaning (reopening the BLE
pairing window) and has no enrollment effect; a press consumed by enrollment
MUST NOT also open the pairing window.

**On press:**

- `commit`: write the durable record `committed` with the context's eid,
  device, phone and `rev := rev + 1`; read it back and compare every field;
  only then answer `committed`. A write or readback failure answers
  `error code=storage cmd=commit`; the host learns the actual durable state only
  from a later `status`.
- `revoke`: first set the in-RAM revocation flag — every live session is
  closed with `err revoked` and no further request is processed (§8.4) — then
  write `revoked` with `rev := rev + 1`, read back, answer `revoked`. On write
  failure answer `storage`; the RAM flag stays set until reboot, after which
  the still-committed record is again authoritative. The operator must retry.
- `identity-reset`: erase `pdsh_enr/rec_v1` and `pdsh_id/priv`, generate a
  new P-256 key with the PSA RNG, persist it, answer `reset device=<new fp>`.
  On failure answer `storage` and re-derive the durable state at the next
  command. A reset changes the device ID; every phone record for the old
  fingerprint becomes permanently unusable (§4.4).

Fixtures: `golden/ble-secure-enrollment-states.jsonl`, `side=board`, including
replug during staging, concurrent `begin`, replayed `commit`, press timeout,
interrupted press wait, storage failure on commit and revoke, key loss,
corrupt record, same key, eid and value mismatches, stray presses.

### 3.4 Phone ceremony

The phone token `pdsh-phone-v1:<64 hex>` is displayed in full (grouping into
blocks of four for readability is allowed; the copied value has no spaces).
The phone generates its key (§4.1) the first time it shows the token.

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
| forget | `staged` or `committed` → `revoked` (rev+1); a live session is invalidated first (§8.4) |
| reset phone key | every `staged`/`committed` record → `revoked`, then a new key; required to leave `phone_key_lost` |

A failed write leaves the previous durable record (`storage`). A restart
preserves `staged` and `committed` records; a staged record is never promoted
by a restart, a reconnect or any peer message.

Fixtures: `golden/ble-secure-enrollment-states.jsonl`, `side=phone`.

## 4. Keys and enrollment records

### 4.1 Phone key

One P-256 signing key per app installation, used for every device. Keychain
`kSecClassKey`, application tag `pdsh.ble.session.phone-key.v1`,
`kSecAttrIsPermanent`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
not synchronizable. A Secure Enclave key is RECOMMENDED; a non-exportable
software Keychain key is permitted in this revision only if the UI labels it
"软件密钥" (§15). The key is never exported to logs, files, the Worker or the
model. If the Keychain reports the item absent while any enrollment record
exists, the phone is in `phone_key_lost`: no session, no silent regeneration;
only "reset phone key" (§3.4) leaves it. A transient Keychain error (locked
device) is not loss and changes nothing.

### 4.2 Board key and record

- Key: unchanged `pdsh_id/priv` (32-byte P-256 scalar, plain NVS). The device
  fingerprint of a board already running the TOFU firmware does not change.
- Record: NVS namespace `pdsh_enr`, key `rec_v1`, UTF-8 JSON per
  `schema/ble-secure-enrollment-record.schema.json` with `side:"board"` and
  state `committed` or `revoked` only.
- Boot classification: `priv` OK and no record → `none`; `priv` OK and valid
  record → its state; `priv` OK and record unreadable/invalid →
  `record_corrupt`; `priv` NOT_FOUND and record present (any state, even
  corrupt) → `key_lost`; `priv` NOT_FOUND and no record → generate a key (first
  install or total erase; no authority existed); any other `priv` read error
  or wrong length → `key_unavailable`. This replaces the current
  "generate on NOT_FOUND" rule only in the `key_lost` case. No state except
  `identity-reset` (button) ever regenerates a key or clears a record.

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
  (`occupied`) until `revoke`. Re-enrollment therefore never coexists with an
  older valid pairing, and an ambiguous revoke cannot reactivate an old one.
- **Many boards per phone.** The phone keeps one record per device ID.
- **Key change.** A changed device key (after `identity-reset` or a different
  board) has a different device ID: no record matches, the TLS pin fails,
  nothing is re-trusted in band. A changed phone key matches no board record.
  Both require a new ceremony.
- **Forget/revoke** first invalidates the live session generation (§8.4),
  then writes `revoked`. The revoked record (with its eid) is retained.

## 5. Transport and discovery

- GATT primary service `d04ea024-c7fd-4a52-9ace-cf9d7567d0e6` ("PDSH secure
  session v1") containing exactly one characteristic: the Apple L2CAP PSM
  characteristic `abdd3056-28fa-441d-a470-55a75a52553a`, read-only, value =
  PSM as u16 little-endian, exactly 2 bytes, in the dynamic LE range
  `0x0080–0x00FF`. Any other length or range → secure session unavailable on
  this connection.
- The PSM, the service and any advertisement are untrusted routing data. The
  phone reads the PSM afresh on every connection and never caches it. The
  board MAY require LE encryption for the read; the phone MUST NOT treat LE
  encryption, bonding or a successful read as authentication.
- Transport: one LE credit-based L2CAP connection-oriented channel (CoC) per
  LE connection; the board refuses a second concurrent CoC. TLS records are
  written as an unframed byte stream across SDUs; SDU boundaries carry no
  meaning.
- Board receive MTU ≥ 256 bytes. Credit safety: the board MUST NOT grant (in
  the initial grant or any replenishment) more credits than K-frames its free
  receive buffering can hold, and MUST disconnect a peer that sends beyond its
  credits; it MUST NOT dereference a receive slot before checking credits.
  Every NimBLE send return path, including queued `BLE_HS_ESTALLED`, has
  defined buffer ownership and is never retried in a way that duplicates bytes.
- Ordinary Link and standard GATT services on the same connection are
  independent; a secure-session failure never disconnects them, and a genuine
  link loss closes both under their own rules.

## 6. TLS 1.3 profile

### 6.1 Handshake parameters (both ends, exactly)

| Item | Value |
| --- | --- |
| Version | TLS 1.3 only (`supported_versions` = 0x0304); RFC 9846 |
| Roles | phone = client, board = server |
| Cipher suite | `TLS_AES_128_GCM_SHA256` (0x1301) only |
| Group / key share | `secp256r1` (0x0017) only; the client always sends a P-256 key share; the server answers a ClientHello without one with `handshake_failure`, never HelloRetryRequest |
| Signature schemes | `ecdsa_secp256r1_sha256` (0x0403) only, in `signature_algorithms` and `signature_algorithms_cert` and the CertificateRequest |
| Key exchange mode | full (EC)DHE handshake only; client sends no `pre_shared_key`, `psk_key_exchange_modes`, `early_data`, `post_handshake_auth`, `server_name`, `max_fragment_length` or `record_size_limit`; server sends no NewSessionTicket and no `early_data` |
| Client authentication | mandatory: server sends CertificateRequest (no `certificate_authorities`); an empty client Certificate → `certificate_required` alert |
| ALPN | client offers exactly `pdsh-ble-task/1`; server selects it or aborts with `no_application_protocol`; client aborts unless it was selected |
| Resumption, 0-RTT, PSK, tickets | not used; a client MUST NOT store or use any ticket it receives |
| Post-handshake | KeyUpdate permitted per RFC 9846; post-handshake authentication not used |
| Record size | each side sends TLS records whose plaintext is ≤ 4352 bytes; a receiver MAY reject a larger record with `record_overflow` |

Any deviation fails the handshake; there is no fallback profile and no
plaintext mode. A future revision uses a new ALPN identifier; an endpoint MUST
NOT accept an ALPN it does not implement.

### 6.2 Certificates and pins

Each endpoint presents exactly one self-signed X.509 v3 certificate for its
enrolled key. Producer profile: serial 1–20 bytes; subject = issuer =
`CN=pdsh-ble-device` or `CN=pdsh-ble-phone`; validity `20260101000000Z` to
`99991231235959Z`; SPKI `id-ecPublicKey`/`prime256v1`, uncompressed point;
signature `ecdsa-with-SHA256`; extensions exactly basicConstraints (critical,
cA FALSE) and keyUsage (critical, digitalSignature); DER ≤ 1024 bytes.

A received certificate list is accepted iff **all** of:

1. exactly one certificate (`no_certificate`, `chain_length`);
2. DER ≤ 1024 bytes (`oversize`) that parses as X.509 v3 (`malformed`);
3. SPKI is a valid uncompressed P-256 point (`curve`) and its fingerprint
   equals the expected pin (`pin_mismatch`): on the board, the committed
   record's phone; on the phone, the device of a committed record (§8.2);
4. the certificate's own signature is `ecdsa-with-SHA256`
   (`signature_algorithm`) and verifies under its own SPKI
   (`bad_self_signature`);
5. basicConstraints absent or cA FALSE (`ca_true`); keyUsage present and
   including digitalSignature (`key_usage`); no extendedKeyUsage
   (`eku_present`); no unrecognized critical extension
   (`unknown_critical_extension`).

Not evaluated: validity dates (neither side has a trusted clock; enrollment
and revocation replace expiry), subject/issuer names, serial, unknown
non-critical extensions, and trust-chain status. A verifier built on a
library that reports trust/date failures MUST clear exactly the
"not trusted", "expired" and "not yet valid" results and nothing else, and
MUST still enforce 1–5 itself. Possession of the private key is proven by
TLS CertificateVerify; the pin is the only trust decision. Every rejection
uses the `bad_certificate` alert and no application data is exchanged.

Fixtures: `golden/ble-secure-certificates.jsonl` (DER per case with the
expected decision; dates, names and non-critical extensions are accepted).

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

Fixtures: `golden/ble-secure-frames.jsonl`.

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
| `status` | `sc`, `id`, `idem` | query-only reconciliation |
| `err` | `re:0`, `code` (no `seq`) | client-detected fatal error; then close |

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
`invalid_transition`, `conflict`, `wrong_owner`. An unknown code fails §7.2
decoding and is therefore fatal `malformed`. `internal` is reserved for a
local fault with no more specific code. TLS alerts, CoC loss and decryption
failure are fatal without an `err` message.

## 8. Session state machines

### 8.1 Limits and timers (monotonic clocks)

| Item | Value |
| --- | --- |
| concurrent secure sessions | board 1; phone 1 per device ID |
| outstanding requests | 1 (client sends the next request only after the response) |
| requests per session | ≤ 65535 (`seq` exhausted → client closes and reconnects) |
| CoC open → local handshake complete | 15 s, each side |
| phone handshake complete → valid `ready_ack` | 10 s |
| board handshake complete → `ready_req` | 10 s (`err timeout`, close) |
| phone wait for any response | 10 s → close; the request outcome is unknown (§9.3) |
| board idle while ready | 60 s without a request → `err timeout`, close |
| session lifetime | 600 s from handshake completion, then both close; reconnect needs a full handshake |

Timers never extend on retransmitted or duplicate bytes.

### 8.2 Phone

States: `idle → psm → coc → handshake → ready_wait → ready → closed`, all in one
non-reusable local **session generation** tied to the current CoreBluetooth
connection owner (the existing BLE connection/closing rules of ble-link.md
apply; CoreBluetooth offers no request token and none is invented).

1. Eligible only with the phone key present and at least one `committed`
   record. Read the PSM (§5), open the CoC, run the TLS client.
2. Server pin: accept iff the certificate passes §6.2 against the set of
   devices of the phone's `committed` records; the matching record becomes
   this session's record (device ID, eid, rev captured).
3. After the local handshake returns, re-check the generation and that the
   captured record is still `committed` with the same rev. Then send
   `ready_req` (seq 1) with a fresh `cc`. No task data is sent earlier.
4. On `ready_ack`: verify `re = 1`, `device`, `phone`, `eid` equal the
   captured record and `cc` equals the sent challenge; re-check generation and
   record rev. Store `sc`. Anything else (including an `err`, a `next_r`
   before the ACK, a mismatch) closes the session without readiness.
5. Ready is not permission. Task requests are sent only while the user's
   explicit foreground task grant for this generation and device ID is active
   (task-delegation.md grant-generation rules, with device identity =
   the session's `ble:` device ID). The grant ends on disconnect, background,
   forget, record change, key loss or session close.

Fixtures (`side=phone` in `golden/ble-secure-session-sequences.jsonl`):
readiness acceptance and rejection.

### 8.3 Board

States: `listening → handshake → verified → ready → closed`.

1. TLS server with the client pin = the committed record's phone; without a
   committed record no CoC is served past the handshake (`bad_certificate`).
   Capture the record (eid, phone, rev) at handshake completion.
2. In `verified` the only acceptable message is `ready_req` with `seq = 1`:
   another type → `not_ready`; another seq → `bad_sequence`; `device`,
   `phone` or `eid` different from the captured record → `record_mismatch`.
   A `ready_req` buffered before the handshake completed is processed only
   after it completes. On success draw a fresh `sc`, send `ready_ack`, enter
   `ready`.
3. In `ready`, for each request in order: `ready_req` again or
   `seq ≠ last+1` → `bad_sequence`; `sc` ≠ session `sc` → `bad_challenge`;
   RAM revocation flag set, or the current durable record no longer equals the
   captured (state, eid, phone, rev) → `revoked`. Only then dispatch (§9.1).
   These checks run immediately before every store mutation as well.
4. A client `err` closes without reply. Any fatal error closes.

### 8.4 Closure and invalidation

Closing is: send `err` if a TLS session exists and the cause is
protocol-level, send close_notify, close the CoC, discard all session state
(challenges, sequence, buffered frames, captured record). Disconnect, CoC
loss, TLS alert, timer expiry, `revoke`/forget, record or key change, manager
off and app background each close. On the phone the generation is invalidated
**before** any asynchronous teardown, so a late completion, response or
callback of that generation is discarded and cannot restore readiness, a grant
or a result. Reconnection always starts at a fresh handshake with fresh
challenges. Session closure never undoes or proves the absence of a device
store mutation already committed.

Fixtures (`side=device`): request before readiness, wrong eid/device, replayed
and skipped `seq`, stale `sc` from another session, second readiness, wrong
peer certificate, revoked record, revocation mid-session, timeouts,
client error, server-only type from the client.

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
- A storage failure is fatal `storage`; the slot is unchanged.

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
after `r` (`applied`/`duplicate`) or a §9.3 `applied` decision, and before any
DSH prompt; terminal outcomes are persisted before `complete`/`fail` is sent.
A `next_r` with phase `accepted` for which the phone has no parent record is
never executed; it stays unresolved and may only be reported `fail` with
`unknown_outcome` after an explicit user action that itself follows the
intent rules.

Fixtures: `golden/ble-secure-task-intents.jsonl`.

### 9.3 Lost replies, crashes and reconnection

TLS prevents replay and reordering inside one session; across sessions the
fresh challenges and `seq` restart make old messages unusable. Durable
idempotency is separate: when a response to `accept`/`complete`/`fail` is lost
(timeout, disconnect, crash), the phone keeps the intent and, in a later
ready session for the same device ID and the intent's `phone_id`, first sends
`status` for that task and decides:

| Intent | `status_r` | Decision |
| --- | --- | --- |
| accept | `accepted`, mine | applied |
| accept | `queued` | resend the identical persisted arguments |
| complete/fail | terminal, mine, same kind and identical outcome | applied |
| complete/fail | `accepted`, mine | resend identical arguments |
| any | `err conflict`; `unknown`; not mine; other terminal; `queued` for complete/fail | unresolved — keep, never resend, user-visible |
| any | no session, timeout, other fatal error | retry the query in a later session |

Resend is permitted only because the board's transitions are deterministic,
owner-checked state changes with no external effect, and only after an
authoritative `status` in the current session showed the precondition. It is
never permitted on a missing, failed or ambiguous answer, after a phone key
reset (`phone_id` ≠ current key → unresolved), or for the DSH turn itself:
phone restart with an accepted/running task still yields `unknown_outcome`
under task-delegation.md, never a second turn.

Board crash: a transition is durable before its response; after reboot the
store tells the truth and the phone reconciles through `status`. Phone crash:
intents and parent records are durable before each send.

Fixtures: `golden/ble-secure-recovery.jsonl`; device-side transitions in
`golden/ble-secure-session-sequences.jsonl` (duplicate accept, conflicting
terminal, wrong owner, legacy accepted slot, idempotency-key mismatch,
storage failure, reconnect after a lost reply).

### 9.4 Time

The board has no trusted clock and does not evaluate `deadline`. The phone
applies the task-delegation deadline rules with its own clock; certificate
dates are never used (§6.2). A monotonic session timer never establishes
task validity across restarts.

## 10. Reference firmware task store v2

NVS key `tasks_v2` (namespace unchanged), UTF-8 JSON per
`schema/ble-secure-task-store.schema.json`: v1 slots plus optional `by`
(`phone:` ID) on non-queued slots. At most four slots; outcome iff terminal;
no eviction; full store rejects local submission. Selection at boot:

| NVS | Result |
| --- | --- |
| `tasks_v2` present and valid | use it; `tasks_v1` ignored |
| `tasks_v2` present but unreadable/invalid | task store disabled; **no** fallback to v1 |
| only `tasks_v1`, valid | migrate: view = v1 slots without `by`; the first mutation writes the complete v2 document; `tasks_v1` is left byte-identical |
| only `tasks_v1`, invalid/unreadable | disabled (as today) |
| neither | empty |

Pre-upgrade accepted slots therefore have no owner and are never offered or
mutated over the session (§9.1). The local producer API and
`tools_task_result` read and write v2 after the upgrade. Fixtures:
`golden/ble-secure-task-store-cases.jsonl`.

## 11. Legacy data, plaintext refusal and unchanged profiles

1. **Ordinary Link and standard GATT are unchanged**: HELLO, opcodes, Tools v1,
   receipts, RESULT, events, permissions and the iOS ordering rules of
   ble-link.md. The secure service is additive.
2. **Plaintext task access is refused permanently.** The ordinary Link ingress
   never advertises or starts `pdsh.task.*`, regardless of `app_caps` bit10 or
   bit11 (`UNSUPPORTED` 14, no receipt, no store change;
   `golden/ble-task-plaintext-admission.jsonl`). No negotiation, error,
   capability or configuration ever falls back to it, on either end.
3. **Old identity labels.** `pdsh.ble.trustedIdentities` entries, including a
   label byte-identical to a device ID, are preserved per
   legacy-identity-preferences.md and never imported as enrollment records.
   `pdsh.identity.prove` remains an unchanged ordinary-Link diagnostic and is
   not part of this profile.
4. **Old phone journals.** Parent records whose `device_id` is `ble:<UUID>`
   and every `ble-ops` intent are preserved byte-for-byte, keep their existing
   inventory and read-only inspection rules, and are never dispatched,
   reported, resent, converted to a device ID or attributed to an enrolled
   key. They cannot collide with secure records because `msg_id` includes the
   device ID string.
5. **Old board data.** `pdsh_id/priv` is kept; `tasks_v1` is migrated per §10;
   Link receipts are unchanged. A pre-upgrade task transition's Link RESULT
   returns only `{request_id,status,result:{}}` (its result is the empty
   object), so leaving ordinary RESULT unchanged reveals no task content; no
   receipt quarantine is introduced, and no Link receipt is ever created for a
   secure transition.

## 12. Compatibility and rollback

| Producer → consumer | Behaviour |
| --- | --- |
| old phone → new firmware | ordinary Link unchanged; old phone ignores the secure service; plaintext tasks refused as today |
| new phone → old firmware | no secure service → BLE tasks unavailable, shown as "设备不支持安全任务会话"; no fallback; ordinary Link unchanged |
| new ↔ new, not enrolled / one side staged | handshake or readiness fails closed; UI points to the offline ceremony |
| new ↔ new, both committed | sessions per this contract |
| future revision | new ALPN; mismatch → `no_application_protocol`; no downgrade |
| old phone data → new phone | §11.3–11.4: preserved, inert |
| old board data → new firmware | §4.2 key kept, §10 migration |
| phone rollback | enrollment files, `ble-secure-ops` and secure parent records are preserved and ignored by the old app (its reader accepts the `ble:<64 hex>` device IDs as ordinary records; it refuses every BLE grant, so nothing is dispatched; LAN is unaffected). Rolling forward again resumes from the preserved state. |
| firmware rollback | `rec_v1` and `tasks_v2` are ignored; the old firmware sees the frozen `tasks_v1` snapshot (stale phases, no post-upgrade tasks). Rollback is supported only to firmware that contains the plaintext-task denial (`PC-20261107-plaintext-task-admission`); rolling back to earlier firmware could re-serve stale queued tasks over plaintext and is **unsupported**. |

## 13. Shared fixtures

Every file below is consumed by both ends through their real parsers, state
machines and stores (transport edges may be substituted; trust decisions may
not). `spec/v1/tools/test_ble_secure_session_golden.py` pins each file's
SHA-256, validates it against its schema and replays it through a reference
oracle; it is a spec checker, not runtime conformance.

| File | Schema | Swift end | Firmware end |
| --- | --- | --- | --- |
| `ble-secure-identifiers.jsonl` | `ble-secure-identifier-vector` | key validation, IDs, token input | key validation, IDs |
| `ble-secure-enrollment-lines.jsonl` | `ble-secure-enrollment-line` | — (host tooling optional) | console parser and printer |
| `ble-secure-enrollment-states.jsonl` | `ble-secure-enrollment-state-vector`, `ble-secure-enrollment-record` | `side=phone` | `side=board` |
| `ble-secure-certificates.jsonl` | `ble-secure-certificate-vector` | server-cert verifier | client-cert verifier |
| `ble-secure-frames.jsonl` | `ble-secure-frame-vector` | frame decoder | frame decoder |
| `ble-secure-messages.jsonl` | `ble-secure-message-vector`, `ble-secure-message` | decoder (both directions) | decoder (both directions) |
| `ble-secure-session-sequences.jsonl` | `ble-secure-session-sequence` | `side=phone` | `side=device` |
| `ble-secure-recovery.jsonl` | `ble-secure-recovery-vector` | recovery decision | — |
| `ble-secure-task-intents.jsonl` | `ble-secure-task-intent` | intent writer/inventory | — |
| `ble-secure-task-store-cases.jsonl` | `ble-secure-task-store-case`, `ble-secure-task-store` | — | store selection and migration |

Live TLS handshakes cannot be fixed bytes; each end additionally runs a
loopback handshake between its real TLS configuration and an independent peer
built from the same profile, covering every §6.1 row negatively (wrong
version, suite, group, ALPN, PSK/early data offered, missing client
certificate) and every §6.2 reason.

## 14. Acceptance before `implemented`

Exact per-end commands and file ownership are in the change record §4. Before
this document may change from `target`, and before any BLE task grant is
enabled, record: both ends passing every fixture above through real code; a
physical iPhone ↔ reference ESP32 run with offline enrollment, a full task
round trip, reconnect, board reboot and phone restart recovery; and negative
physical runs (unenrolled phone, unenrolled board, changed device key,
revoked board, forgotten phone, a Mac test peripheral without the device key).
Simulator, loopback or static evidence MUST NOT be reported as device evidence.

## 15. Decisions requiring independent security review

These are frozen for implementation but are explicitly flagged for a human
security reviewer; a change follows AGENTS.md §3.3.

1. Pinned self-signed certificates with dates ignored, and the exact library
   result-clearing rule of §6.2.
2. No TLS exporter binding: readiness relies on all messages travelling in the
   one pin-verified TLS connection plus echoed per-session challenges.
3. Software Keychain phone key permitted (Secure Enclave recommended) and the
   plain-NVS device key.
4. A single board button press as physical authorization, with a trusted host.
5. Resend after an authoritative `status` (§9.3) for owner-checked device
   transitions.
6. No anti-rollback anchor; unsupported rollback to pre-containment firmware.
7. Leaving ordinary Link RESULT unchanged for pre-upgrade task transitions
   (§11.5) instead of the candidate's receipt quarantine.
8. TLS record plaintext cap of 4352 bytes without `record_size_limit`.
