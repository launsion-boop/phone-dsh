# PCLink v1 (P28)

Status: `target` — frozen contract; the B relay is implemented in this branch,
but P28 stays `target` until the C/D ends and the runtime evidence exist.
Revision label `pclink-v1.6` (automatic pairing approval after the verified
`pair.auth`, `approvedVia:"qr"|"manual"`, the admin `plugin` build facts and
the non-TTY/resilient `pclink pair`; see the change record's revision log).
The golden fixture revision moves to `pclink-v1.6` because the PC record's
`approvedVia` and the state-machine samples changed. The change record is
[PC-20261109-pclink-v1](../../../docs/protocol-changes/PC-20261109-pclink-v1.md);
its `contract_revision` is `spec/pclink/v1/README.md@pclink-v1.6`.

PCLink is the pair of a relay plane and an end-to-end plane between one iPhone
and one PC running `dsh web` through a PC plugin. It is **not** the DSH Remote
API: it carries DSH Remote `client-request` calls and streams unchanged. P14
owns the DSH Remote mux/client-request semantics, P06 owns DSH events and
approval/question semantics, and this contract owns only how those bytes travel
between a paired phone and PC through an untrusted relay.

Key words MUST, MUST NOT, SHOULD and MAY are normative. "Phone" is the iOS app;
"PC" is the PC plugin inside the `dsh web` process; "relay" is the public or
self-hosted relay. This contract is the only authority for PCLink; schemas under
`schema/` decide shapes and `golden/` decides concrete bytes and boundary cases.
A conflict among them is a defect that must be fixed in one change.

## 1. Threat model and non-goals

**Protected.** Against a relay that is honest-but-curious or actively malicious,
every end-to-end message is confidential and integrity protected, bound to one
pairing record and one fresh session, authenticated in both directions, forward
secret, and rejected on replay. The relay cannot read or modify an end-to-end
message, cannot impersonate either end, and cannot swap the PC public key during
QR pairing or the manual-code pairing. A dropped or delayed message can break
liveness but cannot turn into a different accepted message. A new pairing is
written only after the phone proves possession of the single-use secret shown
on the PC screen — the QR `S` or the manual code `C` — in a MACed `pair.auth`
that the PC verifies; the PC then approves **automatically** and sends
`pair.confirm` (§4.4). Possession of the screen secret is the approval (the
2026-11-10 user decision, matching the WhatsApp Web-class model): scanning the
QR or typing the code *is* the confirmation. This is a human-process control
in the sense that the PC screen is the secret channel, **not** a boundary
against a same-user PC process, a process that can see the screen, or an agent
running on an already-paired phone with PC shell access (non-goal 7).

**What the relay can do.** It can observe the outer headers (`v`, `type`, `sid`,
`seq`, `from`, `to` and the byte length of `body`), drop, delay or close
connections, correlate timing and sizes, learn machineIds, roles and the pair
payload (identity public keys, display names and pairing MACs), and deny
service. It can see the rendezvous value during pairing and can attempt to
guess the pairing secret offline. It cannot decrypt `body` of an `e2e` frame,
modify any authenticated field without detection, replay a frame into the same
session, or forge a relay authentication or pairing MAC without the
corresponding private key/secret. It also learns the mapping between a
`machineId` and the identity public key presented to it; PCLink does **not**
provide identity hiding (review L2).

**Assumed trusted (outside the cryptographic claim).**

- The phone OS and app process, the PC OS and the `dsh web` process, and their
  CSPRNGs.
- The user's physical control of the PC terminal/screen while a pairing slot is
  open: whoever can read the QR or manual code from that screen within its
  five-minute life can complete the pairing. The phone user's explicit pairing
  action (scan or code entry) and the full-owner warning. The PC does not ask
  its operator to compare a phone-displayed value; the one-time screen secret
  is the approval decision.
- TLS certificate validation for the relay WSS endpoint (§3.1). The relay is
  authenticated as a transport endpoint, not as a trusted content endpoint.
- The PC's local DSH instance and its owner Peer. The plugin has the same DSH
  authority as the local owner user.

**Explicit non-goals.**

1. Padding or traffic-analysis resistance; `body` lengths leak message sizes.
2. Endpoint compromise, malware, a jailbroken/rooted phone, or a compromised
   PC. A stolen unlocked phone is equivalent to full DSH owner access on the PC
   (shell, files, approvals, settings and plugins); the user decision is not to
   add an endpoint allowlist. The handling guidance for a stolen/lost phone is
   **revoke all pairings, then run `rotate-identity`**; a phone-only local
   removal is not authoritative. Other mitigations are the first-pairing
   warning, the one-time screen-secret approval path, the paired-notice/banner
   detection path, and end-to-end encryption, not endpoint restriction.
3. Relay availability, resistance to denial of service beyond the limits in
   §3.5, or durable store-and-forward. The relay has no persistence and never
   queues.
4. Post-quantum security, hardware-backed phone identity, secure boot, or
   resistance to a compromised relay operator that also controls the user's
   screen.
5. Hiding the fact that two machineIds communicate, hiding the machineId ↔
   public-key mapping, or hiding pairing metadata from the relay. PCLink v1
   provides no identity hiding.
6. A future `direct` transport. `connection.mode:"direct"` is reserved and is
   not callable in v1.
7. Defence against a same-user local process. Any process running as the PC
   user (including a prompt-injected DSH agent) can read `pairs.json`/the admin
   token, call the local admin API, or edit the files. The approval gate, the
   append-only `pairs.log` and the admin fence raise the cost and make silent
   writes detectable; they are **not** an absolute boundary against that
   process. See §4.6 and §8.1.

**Why there is no SAS (review C1).** The `pclink-v1` draft used a 40-bit manual
code displayed as eight Crockford characters and a six-digit SAS computed from
the two plaintext transcript hashes. That construction is not safe:

- Without a commitment, the relay sees the first transcript value before it
  must send its own; the relay can derive the 40-bit code from the rendezvous
  value (`sha256("pclink-v1/pair" || 0x00 || C)`, 2^40 SHA-256 operations) and
  then grind its forged ephemeral nonce until the six-digit SAS matches the
  phone's. The review's PoC ground a matching SAS in about nine seconds on one
  Node thread. The two screens then showed the same SAS and the user confirmed
  an attacker key.
- A SAS is only useful if it is short enough to compare and bound to a
  commitment that is sent **before** the attacker chooses its own key material.
  The v1 draft had neither. Changing the SAS protocol would still leave the
  40-bit code as the only confidentiality of the rendezvous.

`pclink-v1.1` removed the SAS entirely (no SAS field, user-confirmed value or
fixture) and raised the manual secret to **80 bits**; `pclink-v1.2` through
`pclink-v1.6` keep that removal: 16 Crockford base32 characters,
displayed as `XXXX-XXXX-XXXX-XXXX` and entered with `-`, spaces and letter case
ignored (`I`/`L`→`1`, `O`→`0`; `U` and every other non-alphabet character are
rejected). At 80 bits, deriving the rendezvous or testing a pairing MAC by
guessing the code is far outside the five-minute window and any realistic
offline budget. The pairing MAC itself authenticates both public keys,
machineIds, names, nonces and the relay origin, so the user only needs to keep
the 80-bit code secret and approve the right phone; there is no second
user-compared value to grind. The QR path carries a 128-bit secret and pins the
PC public key from the QR; QR remains the recommended path. The manual path
opens only the C slot and only after the user explicitly selects manual pairing;
the default opens only the QR/S slot (§4.3).

**Approval is possession of the one-time screen secret (user decision,
2026-11-10).** Both QR and manual pairing are approved by the PC automatically
after it verifies `pair.auth`: the joining phone has just proved it knows the
single-use secret displayed only on the PC screen, so scanning the QR (or
typing the manual code) *is* the confirmation. The PC MUST NOT wait for a local
operator to read a phone fingerprint and type it back, MUST NOT enter
`awaiting_approval` for a v1.6 pairing, and the CLI MUST NOT prompt for a
fingerprint. The phone's pairing page likewise no longer displays a fingerprint
for comparison; the fingerprint lives on the completed pairing's status/notice
and on the App's "已连接的电脑" page for later verification.

**Residual risk (accepted).** Anyone who can see or photograph the PC screen
while the slot is open — a bystander, a shared screen, a screen share, a video
call, a recording — can join first and be auto-approved, obtaining exactly the
full DSH control the legitimate phone would get. The slot is one per pairing,
single-use, expires after 300 s absolute, and the first successful join locks
out later joiners. Within that window the screen secret is the only human gate.
This is the same trust model as WhatsApp Web's "scan the QR on the screen", and
it was adopted because the compare-the-phone ritual failed on real hardware:
the user had to leave the iPhone to read its fingerprint into the PC, the phone
locked or backgrounded, the relay connection dropped, the PC reported
`pairing closed by peer: peer_offline`, and the pairing (and phone UI) hung.
The controls that remain are: one open slot, single successful join and a
300 s absolute expiry; the PC terminal and `status` print
`已配对：<phone name>（<fingerprint>）` plus the exact revoke command
(`pclink unpair <machineId>`, or `pclink unpair --all`) once the record is
durable; `pairs.log` records `approvedVia:"qr"|"manual"` and the record hash;
the PC sends `pclink.notice{kind:"paired"}` to every other established phone;
and the App's "已连接的电脑" page shows this phone's own fingerprint, pairing
mode and pairing time for later verification. If the code or QR leaked to a
screen observer, the user can revoke immediately.

The approval is **not** an absolute boundary (review M-A), and this contract
does not claim otherwise. A same-user PC process that can read `pairs.json`/the
admin token or call the admin API can drive the admin API; a process that can
see the screen can join first; and an agent running on an already-paired phone
with PC shell access can pair by acting as that phone's user. §8.1's
`Host`/`Origin`/`Content-Type` fence, the server-proof challenge, `pairs.log`,
the `/api/pclink.admin/*` source-Peer gate and the remote `pclink.admin/` ban
reduce and detect that class but do not make it impossible. The user is told
that pairing approval is the one-time screen secret, not a hardware boundary.

**Detection (review M-A).** After every successful new pairing the PC MUST
notify every **other** paired phone that has an established end-to-end session
with `pclink.notice{kind:"paired",name,fingerprint,at}` (§6), and the Web UI
plugin page MUST show a persistent banner for the most recent successful
pairing. The phone UI MUST display the notice. This is detection, not
prevention: a compromised PC can suppress it, which is why a stolen/lost phone
is handled by revoking all pairings and running `rotate-identity` (§4.6,
§8.3).

## 2. Conventions and identifiers

### 2.1 Encoding

- `b64url` means RFC 4648 base64url **without** padding (`A-Z`, `a-z`, `0-9`,
  `-`, `_`). A decoder MUST reject padding, a non-canonical re-encoding (the
  unused low bits of the last character must be zero), or a wrong decoded
  length. The lengths below are therefore exact string lengths.
- Ed25519 and X25519 public keys are the raw 32-byte RFC 8032 / RFC 7748
  encodings, 43 `b64url` characters. Ed25519 signatures are 64 raw bytes,
  86 `b64url` characters. Nonces and `sid` are raw random bytes, never a hash
  of a counter.
- `sha256` is SHA-256 over the exact concatenated bytes; all `*_hex` in the
  vectors is lowercase hex. `0x00` is one zero byte.
- All integers on the wire are JSON integers in their stated range; do not
  send `1.0`, leading zeroes or exponent notation for `seq`/`part`/`port`.
- Times are RFC 3339 UTC with second precision and a trailing `Z`
  (`YYYY-MM-DDTHH:MM:SSZ`). They are display metadata, never a security
  decision; no PCLink check depends on a synchronized clock.
- A `name`/`peerName` is 1–64 **UTF-8 bytes**, NFC-normalized, and contains no
  C0 (`U+0000`–`U+001F`), C1 (`U+007F`–`U+009F`) or Unicode `Cf` (format)
  character such as `U+202E`. JSON Schema `minLength`/`maxLength` count code
  points, not bytes; an implementation MUST additionally enforce the byte
  limit on the UTF-8 encoding (`Buffer.byteLength`/`String.utf8.count`) and
  MUST reject a non-NFC value rather than silently normalize it. The schema
  patterns below are a coarse guard; the byte/NFC/`Cf` rule is normative. This
  rule applies to PCLink's own name/display fields, not to DSH passthrough
  values (§2.3).

### 2.2 Machine identity

Each device has one long-lived Ed25519 identity key. `machineId` is:

```text
machineId = lower(base32_nopad(sha256(E)))[0:26]
```

where `E` is the 32-byte raw Ed25519 public key and `base32_nopad` uses the
RFC 4648 alphabet `A-Z2-7` with no padding. The result is exactly 26 lowercase
characters matching `^[a-z2-7]{26}$`; it is a 130-bit name, not a secret and not
a substitute for a signature. The relay MUST derive it from the presented
public key and reject a mismatch. Both ends MUST derive it the same way when
recording a pairing.

The **fingerprint** used for display and verification is
`machineId[0:12]`, displayed as three groups of four (`xxxx-xxxx-xxxx`) and
representing 60 bits. It is a human-checkable name for the key, not a security
boundary and not a pairing-approval input in v1.6. The PC terminal/`status`
prints it for each completed pairing and the completed record carries the full
machineId; the App's "已连接的电脑" page shows the phone's own fingerprint (and
the PC record's fingerprint) so the user can verify what was paired. While a
pairing is pending and before the record is durable, `status`/the Web UI MUST
NOT expose the pending peer's `machineId`, `publicKey` or fingerprint; only the
verified `peerName` may be shown. Fingerprint input normalization (ignore `-`,
spaces/whitespace and letter case) remains for selecting a paired phone in
`pclink unpair <fingerprint>`; it is not used to approve a pairing.

In pairing, both sides MUST derive the peer `machineId` from the peer public
key they received and compare it with the `machineId` member of
`pair.hello`/`pair.auth`; a mismatch is `auth_failed`. This binds the displayed
name and the record to the key actually carried by the pairing message (review
L5). The E2E handshake later proves possession of the corresponding private
key.

Private keys: the PC stores a raw 32-byte Ed25519 seed at
`$DSH_HOME/pclink/identity.key` mode 0600. The phone stores the raw seed in the
Keychain (service `dsh-pclink`, account `identity-v1`, accessibility
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable). The
phone key is software Keychain key material (Ed25519 is not a Secure Enclave
algorithm); a root/jailbreak compromise is outside the threat model. A missing
phone key while a pairing record exists is not silently regenerated: the app
shows re-pair. A missing PC key while pairing records exist regenerates the
identity, making every old record stale; the plugin MUST NOT silently reuse or
rewrite them.

### 2.3 JSON

Every relay frame and every decrypted inner message is exactly one UTF-8 JSON
object, no byte-order mark, no leading/trailing bytes. These rules apply to the
**wire text**; they are not a character filter on the JSON values a DSH endpoint
may legitimately produce:

- The root is exactly one JSON object, never an array, string, number, boolean
  or `null`.
- No UTF-8 BOM and no literal `0x00` byte anywhere in the frame. Outside a
  string only JSON whitespace (`0x20`, `0x09`, `0x0A`, `0x0D`) is allowed; a
  raw C0 control byte inside a string is invalid JSON. A literal NUL, BOM,
  leading/trailing bytes or malformed UTF-8 is `bad_frame`.
- Duplicate member names at any depth are rejected, compared as decoded Unicode
  scalar sequences (`"a"` and `"\u0061"` are the same member). `NaN`,
  `Infinity`, non-finite numbers, unpaired surrogates and non-object roots are
  rejected as `bad_frame`.
- A legal JSON escape `\u0000` inside a string is **not** a wire error. It
  decodes to `U+0000`, which is carried as DSH data. The same applies to
  `\u0001`–`\u001f` when a DSH value contains a control character. Uppercase or
  lowercase hex is legal JSON on the wire; canonical JSON always uses lowercase
  (`\u0000`), see below.
- Unknown members of a **PCLink object** (not keys inside a DSH passthrough
  value), unknown `type` values and unknown PCLink error codes are rejected as
  `bad_frame` (unknown DSH error codes are the exception in §9.3). A reserved
  namespace `task.*` or `call.*` is answered with the matching
  `task.*.error` / `call.*.error` with `code:"unavailable"`; that is the only
  unknown-type rule.

**PCLink-owned fields versus DSH passthrough values.** The boundary is
normative:

| Value kind | Members | Rule |
| --- | --- | --- |
| PCLink-defined string | `name`/`peerName`, `app.name`, `machineId`, `role`, `code`, `id`, `streamId`, `endpoint`, `suite`, `caps[]`, `at`, `fingerprint`, relay origins, QR/pairing fields | the member's own schema/field rule. The name rule (1–64 UTF-8 bytes, NFC, no C0/C1/`Cf`) rejects `U+0000`; pattern/enum fields reject it as a non-match. |
| PCLink display text | `message` in `relay.error`, `rpc.result.error`, `rpc.stream.error`, `session.reject`, `session.close` and reserved `*.error` | the field's own UTF-8/byte-cap rule. It is display metadata, not a DSH passthrough; a decoded `U+0000` here is outside the escaped-`U+0000` guarantee and MUST NOT be used as a channel for DSH output. |
| DSH passthrough | `rpc.call.args`, `rpc.stream.open.payload.args`, `rpc.result.result`, `rpc.stream.item.value`, the JSON value reassembled from `rpc.result.chunk.data`/`rpc.stream.chunk.data`, and event payloads nested inside those values | carried as DSH produced it: **no character filtering, no NUL stripping, no re-encoding or Unicode normalization**. A decoded `U+0000` is preserved. |

A receiver MUST NOT close a session merely because a decoded string in a
passthrough value contains `U+0000`. It MAY reject a `U+0000` in a PCLink-owned
field when that field's own rule rejects it; the name and pattern/enum rules
above do. The optional `error.details` object is part of the error object, not
one of the guaranteed passthrough values; it is not a channel for a DSH
`result`/`value`, and its nested content follows the error rule. An
implementation MAY additionally reject a decoded `U+0000` in a PCLink display
`message` under its own display-safety rule; that local rejection MUST NOT be
extended to a passthrough value. This boundary exists because pinned DSH
0.2.2-rc.1 model/tool output can legally contain a JSON `\u0000` escape in a
tool result; rejecting that escape as `bad_frame` would break the DSH call or
stream carrying it.

`canonical_json(x)` used by pairing MACs is UTF-8, with these exact rules:

- Object keys are sorted ascending by **Unicode scalar value (code point)**
  sequence, which is the same order as UTF-8 byte lexicographic order. This is
  **not** JavaScript `Array.prototype.sort()`'s default UTF-16 code-unit order
  and **not** Swift `String.<`'s canonical/locale-independent collation. Swift
  implementations MUST compare `Array(key.unicodeScalars)` (or UTF-8 bytes);
  the vectors include a key pair that distinguishes the two orders.
- No insignificant whitespace; arrays stay in order; `true`/`false`/`null`
  and numbers are exactly their JSON spellings.
- `"` and `\` are escaped. `U+0000` has no short form and is always the
  lowercase six-character escape `\u0000`. `U+0001`–`U+001F` use the short forms
  `\b \t \n \f \r` where defined, otherwise lowercase `\u00xx`; `U+007F` is
  emitted literally (it is not a C0 control). Every other code point, including
  non-ASCII text and `/`, is emitted as literal UTF-8 (no `\/`, no `\uXXXX` for
  non-ASCII). A lone surrogate is invalid.
- **Swift:** `JSONEncoder` escapes `/` as `\/` by default. Swift
  implementations MUST use `.withoutEscapingSlashes` (or a custom encoder) and
  a scalar-order key sort; a `JSONEncoder` default output is not canonical and
  will fail the pairing MAC.

For example, `canonical_json({"a<U+0000>b":"key","note":"a<U+0000>b"})` is the
text `{"a\u0000b":"key","note":"a\u0000b"}` (where each `\u0000` is six ASCII
characters), and `golden/pclink-v1-vectors.json` records that text and its
SHA-256 under `canonical_json.nul_escape`.

Message bodies on the wire do not have to be canonical unless a clause says so;
the golden vectors use the exact bytes shown.

## 3. Relay plane

### 3.1 Transport and frame grammar

The relay is a WebSocket server carrying **text** frames. Production MUST use
`wss` with a valid TLS certificate validated by the client against the system
trust store; `ws` is allowed only for loopback tests with an `http` origin. The
client MUST NOT use a custom certificate pin for v1 (self-hosted relays use
ordinary public certificates). Any origin string in this contract is an ASCII
`https`/`http` origin, **lowercase only**, default port omitted, no userinfo,
path, query or fragment, maximum 128 characters; `https://relay.example` is
canonical. A producer MUST NOT emit an uppercase character in the origin, and a
consumer MUST reject one rather than silently lowercasing it (review L7). The
schema patterns allow only `[a-z0-9.:-]` in the host/port part. IPv6 literal
origins are not used by a v1 loopback test (use `http://127.0.0.1:<port>`).
A `wss` URL is derived by replacing `https` with `wss` (or `http` with `ws`) and
using the `/` path.

The relay MUST be configured with its public origin
(`PCLINK_PUBLIC_ORIGIN`, e.g. `https://relay.example`; for a loopback test
`http://127.0.0.1:<port>`); it sends exactly that normalized origin in
`relay.challenge.relay`. A production relay without `PCLINK_PUBLIC_ORIGIN`
refuses to start rather than guessing from a Host header.

Each connection is a single ordered sequence of text frames. The relay MUST
reject binary frames (`bad_frame`, close 1003), a frame that is not one JSON
object, and any frame whose UTF-8 length exceeds 16 MiB. The relay MUST NOT
inspect or decrypt `e2e.body`; it forwards the outer object by `to` after
overwriting `from` with the authenticated machineId (§3.3). Relay-plane frames
and `e2e.handshake` carry only PCLink-owned fields; they contain no DSH
passthrough value. A relay MAY therefore keep rejecting every decoded `U+0000`
(and the literal byte) in outer JSON; the §2.3 escaped-`\u0000` allowance
applies only to the AEAD inner values and does not change the outer frame
grammar.

The first frame from the relay is `relay.challenge`; the first frame from the
client is `peer.auth`; the relay then sends `relay.ready`. No other client frame
is accepted before `relay.ready`. The client MUST reject a `relay.challenge`
whose `relay` does not equal the origin it dialed and, for a phone, the pairing
record/QR origin. The client MUST sign the exact origin string from the
challenge after that check.

### 3.2 Relay authentication

`relay.challenge` (relay → client):

```json
{"v":1,"type":"relay.challenge","nonce":"<32B b64url>","relay":"https://relay.example"}
```

`peer.auth` (client → relay):

```json
{"v":1,"type":"peer.auth","machineId":"<26 chars>","publicKey":"<32B b64url>",
 "role":"phone"|"pc","sig":"<64B b64url>"}
```

`role` is a routing claim, not an authenticated attribute: the relay has no
registry and the signature transcript does not cover it. Both ends enforce the
role in the E2E handshake (`peer.hello.role`, the direction of
`session.init`/`session.resp`) and the pairing slot role; a spoofer can only
label its own connection, it cannot change another machineId, decrypt a pair or
impersonate a key it does not hold. The relay's same-machineId role binding is
defence in depth, not the authority.

The signature transcript is exactly:

```text
"pclink-v1/relay-auth" || 0x00 || UTF8(relay) || 0x00 || nonce_raw_32
```

and `sig = Ed25519(identityKey, transcript)`. The relay verifies the signature,
derives `machineId` from `publicKey`, requires the presented `machineId` to
equal it, and requires `role` to be `phone` or `pc`. A failure is
`relay.error{code:"auth_failed"}` followed by close 4002. The relay sends a fresh
32-byte nonce for every connection; a replayed `peer.auth` fails on the new
nonce. The client MUST NOT sign a challenge whose `relay`/nonce it has not
validated.

The client has 10 seconds after the challenge to send a valid `peer.auth`; the
relay closes with `auth_failed` after that. After success the relay sends
`relay.ready`:

```json
{"v":1,"type":"relay.ready","machineId":"<26 chars>","role":"phone"|"pc"}
```

A client that receives a ready with a different machineId/role closes. A second
`peer.auth` or any other frame before `relay.ready` is `bad_frame`.

**Replacement.** A new authenticated connection for an existing machineId
replaces the old connection. The relay sends the old connection
`relay.error{code:"replaced"}` and closes it with 4001, then admits the new one.
A new connection that presents the same machineId with a different role is
rejected (`auth_failed`) rather than replacing. The replaced client SHOULD NOT
reconnect immediately; it waits at least 30 seconds with jitter to avoid a
replacement fight.

### 3.3 Routing and the PC allowlist

For `e2e` and `e2e.handshake`, the relay requires valid `to`, `from` and `sid`
headers and forwards the object to the connection whose authenticated machineId
equals `to`. The relay **overwrites** `from` with the authenticated machineId;
a client-supplied `from` is never trusted. `to` MUST be a valid machineId and
MUST differ from the sender. If the target is not connected, the relay sends:

```json
{"v":1,"type":"relay.offline","to":"<machineId>","id":"...","streamId":"...","sid":"..."}
```

with `id`/`streamId`/`sid` only when the source frame carried them. It never
queues. Other relay-plane frames are not routable.

A PC connection may send:

```json
{"v":1,"type":"relay.allow","peers":["<machineId>", "..."]}
```

The list replaces the previous list for that connection; it is not additive.
Only `role:"pc"` may send it; a phone sending it is `bad_frame`. The relay
stores it in memory for the lifetime of the PC connection and drops (does not
error) an `e2e` frame whose sender is not in the list. The allowlist applies to
`e2e` **application** frames only. `e2e.handshake` frames bypass the allowlist
so that a PC can answer `unpaired`/`auth_failed` after a local unpair. That
bypass is narrow: the outer object MUST be `e2e.handshake` and `body.type` MUST
be one of `session.init`/`session.resp`/`session.confirm`/`session.reject`; any
other body is `bad_frame`, so the bypass cannot carry application or `rpc.*`
data. Handshake frames are separately rate-limited by the relay as described
in §3.5 (per source machineId and per target machineId) and by the PC's
handshake limiter (§5.1). The phone has no allowlist: the relay forwards any
`e2e`/`e2e.handshake` whose `to` is the phone. The phone drops frames from a
machineId that is not its one paired PC.

The PC MUST send `relay.allow` immediately after `relay.ready`, after every
pairing change and on every reconnect; an absent list is empty. The relay treats
the list as advisory and never queues frames while it is empty.

The allowlist is a spam filter, not an authorization boundary. The PC MUST
validate every frame against its local pairing table and AEAD state (§5.6).

### 3.4 Heartbeats, idle close and close codes

Both sides implement `relay.ping`/`relay.pong`:

```json
{"v":1,"type":"relay.ping","nonce":"<16B b64url>"}
{"v":1,"type":"relay.pong","nonce":"<same>"}
```

Each side sends a ping after a uniform random 20–30 s interval (25 s ± 5 s).
The peer MUST answer immediately with the same nonce. Two consecutive pings
without a matching pong close the connection; the relay sends
`relay.error{code:"unavailable",message:"heartbeat timeout"}` before close 1001,
and a client MAY close without a frame. Pongs for an unknown/old nonce are
ignored. Timers use a monotonic clock and are not extended by traffic.

The relay closes a phone connection that has carried no authenticated
**business** frame (anything except `relay.ping`/`relay.pong`) in **either
direction** for 10 minutes: it sends `relay.error{code:"session_expired"}` and
closes 4004. A business frame forwarded **to** the phone (`e2e`,
`e2e.handshake` or `relay.pair.message`) resets the timer exactly like one sent
by it, so a phone that is only receiving from its PC is not idle-closed. (This
direction rule is the `pclink-v1.4` clarification.) The phone reconnects on
demand and establishes a new end-to-end session; there is no application
keepalive in v1. The PC connection is not idle-closed by this rule.

The PC cannot observe the phone's relay connection directly; it only sees the
E2E frames that arrive. The PC therefore applies its own E2E idle timeout: if
no `e2e` frame for a peer arrives in either direction for **15 minutes**, the
PC closes the logical session (best-effort `session.close{code:"session_expired"}`),
discards the keys and marks the peer offline. The phone also tears down its E2E
session when its relay connection closes; a silent half-open relay connection
is bounded by the PC's 15-minute rule and by the relay's 10-minute phone idle
rule. `status.online` is defined by the PC's own established-and-not-idle
session state (§8.2), never by a claimed observation of the phone's socket.

Close codes: 1000 normal, 1001 going away/heartbeat, 1003 binary frame, 1008
policy (`bad_frame`), 1009 frame too large, 4001 `replaced`, 4002 `auth_failed`,
4003 `rate_limited`, 4004 `session_expired`. A client treats any close without a
`relay.error` according to the close code; reconnect policy is §10.

### 3.5 Limits (relay defaults; environment-tunable)

No limit below introduces a queue: an offline target gets `relay.offline`, and
a frame dropped by the pair, daily, or slow-receiver limit is not retained for
later delivery.

| Limit | Default | Enforcement |
| --- | --- | --- |
| connections per source IP | 20 | reject/close with `relay.error{code:"rate_limited"}` before auth; IPv6 counts aggregate by /64 (§ below). The slot is released when the socket's `close` event fires, not when the relay starts its closing handshake (the handshake can take up to 30 s). |
| bytes per unordered machineId pair | 1 MiB/s, burst 4 MiB | token bucket over all forwarded frames; excess frame dropped and `relay.error{code:"rate_limited",retryAfterMs}` sent to the sender; connection stays. A single frame larger than the burst (up to the 16 MiB frame cap; §6.1's 8 MiB plaintext value can encode to more than 4 MiB on the wire) is forwarded when the bucket is full by **overdrawing** tokens: the balance goes negative and refills at the configured rate, so repeated oversized frames are still limited and none is queued. |
| bytes per unauthenticated frame | 4 KiB | before `relay.ready` the relay checks the frame length before UTF-8 decoding and JSON parsing; a larger frame is `frame_too_large` and close 1009. After `relay.ready` the 16 MiB single-frame cap applies. The pre-auth cap MUST be at most the frame cap. |
| single forwarded frame | 16 MiB | `frame_too_large` and close 1009 |
| buffered bytes per target connection | 24 MiB | checked as the target WebSocket `bufferedAmount` plus the incoming frame length before forwarding; if that would exceed the cap the frame is dropped, the sender receives `relay.error{code:"rate_limited",retryAfterMs}`, and the target connection stays. The relay keeps no application queue and never adds a frame that would exceed this cap (the §3.3 "never queues" rule); the sender retries after the receiver drains. |
| bytes per machineId per UTC day | 2 GiB | counter in memory; excess frame dropped and `rate_limited`/`retryAfterMs`; connection stays |
| machineId counters per UTC day | 100,000 | the in-memory daily byte map is capped; at the cap a new machineId evicts the oldest counter (FIFO), so the daily quota is best-effort. |
| open pairing slots per relay connection | 2 | `rendezvous_exhausted`/`bad_frame`; v1 opens exactly one slot per pairing (§4.3) |
| `e2e.handshake` frames per source machineId | 30/minute, burst 10 | separate token bucket for the allowlist bypass; excess frame dropped and `relay.error{code:"rate_limited",retryAfterMs}` to the sender; connection stays |
| `e2e.handshake` frames per target machineId | 300/minute, burst 100 | separate bucket so a PC cannot be flooded through the bypass; excess dropped + `rate_limited` to the sender |
| pairing joins per IP | 5/minute | `rate_limited`; IPv6 counts aggregate by /64 |
| pairing attempts per rendezvous | 10 joins | the 11th join is `rendezvous_exhausted`; the slot is deleted (single successful match) |
| pairing rendezvous lifetime | 300 s absolute | `rendezvous_expired` and delete |
| unauthenticated connection | 10 s | `auth_failed` and close |

The relay reads these from `PCLINK_MAX_CONNECTIONS_PER_IP`,
`PCLINK_PAIR_RATE_BYTES_PER_SEC`, `PCLINK_PAIR_BURST_BYTES`,
`PCLINK_MAX_FRAME_BYTES`, `PCLINK_UNAUTHENTICATED_MAX_FRAME_BYTES`,
`PCLINK_MAX_BUFFERED_BYTES_PER_CONNECTION`, `PCLINK_DAILY_BYTES_PER_MACHINE`,
`PCLINK_DAILY_BYTES_MAX_MACHINES`, `PCLINK_PAIR_JOINS_PER_IP_PER_MINUTE`,
`PCLINK_PAIR_ATTEMPTS_PER_RENDEZVOUS`,
`PCLINK_PAIR_RENDEZVOUS_TTL_SECONDS`, `PCLINK_MAX_PAIR_SLOTS_PER_CONNECTION`,
`PCLINK_HANDSHAKE_FRAMES_PER_SOURCE_PER_MINUTE`,
`PCLINK_HANDSHAKE_FRAMES_PER_TARGET_PER_MINUTE` and `PCLINK_PUBLIC_ORIGIN`. It
MUST refuse to start with a frame cap above 16 MiB or with the unauthenticated
cap above the frame cap. For every per-IP limit, an IPv6 source is counted by
its /64 prefix (mask the low 64 bits), so a single subscriber cannot rotate
addresses within its /64 to multiply a limit; IPv4 uses the exact address.
Counters and allowlists are in memory only; a relay restart clears them (a
daily quota is therefore best-effort across restarts). The relay has no
database, no volume and no persistent queue. It logs only metadata (timestamp,
event, short machineId hash prefix, frame type/length, error code), never
`body`, pairing codes, secrets or tokens; a source IP appears only as a
prefix of an HMAC-SHA-256 with a random salt generated at process start, which
is never persisted and changes on restart, so the log cannot be brute-forced
back to an IPv4 address. Retention is 7 days or less.

### 3.6 `relay.redirect` (reserved)

`relay.redirect{url}` is reserved for a future sharded relay. No v1 relay sends
it and no v1 client acts on it; a client that receives it logs and ignores it.
It never changes the origin, keys or pairing.

### 3.7 Relay frame registry

These are the only relay-plane `type` values in v1; an unregistered type is
`bad_frame` (the reserved inner namespaces are §6, not relay types).

| Type | Direction | Purpose |
| --- | --- | --- |
| `relay.challenge` | relay → client | nonce + public origin |
| `peer.auth` | client → relay | Ed25519 identity proof |
| `relay.ready` | relay → client | authenticated, replacement done |
| `relay.allow` | PC → relay | replace the PC's `e2e` allowlist |
| `relay.offline` | relay → client | target not connected; not queued |
| `relay.error` | relay → client | §9.1 code and optional correlation |
| `relay.ping` / `relay.pong` | both | 16-byte nonce heartbeat |
| `relay.redirect` | relay → client | reserved; ignored in v1 |
| `relay.pair.open` / `relay.pair.join` | PC / phone → relay | open/join a rendezvous |
| `relay.pair.joined` | relay → both | match notification |
| `relay.pair.message` | both → relay → other | opaque pairing payload |
| `relay.pair.close` | both → relay → other | delete the slot |
| `e2e` | both | AEAD application frame |
| `e2e.handshake` | both | plaintext bootstrap frame (§5.1) |

### 3.8 Sender-side pacing (`pclink-v1.5`)

The relay's §3.5 pair bucket is a **drop** boundary, not a queue. A sender that
emits a bulk result faster than the pair rate loses a frame, and a lost `e2e`
frame breaks the receiver's contiguous `seq` (§5.4) for the rest of that
session. Each end therefore paces its own E2E application frames **before**
they reach the relay:

- The accounting unit is the exact UTF-8 byte length of the serialized outer
  `e2e` frame (the same bytes the relay counts: `from`, `to`, `sid`, `seq`,
  `type` and the AEAD ciphertext, including the JSON syntax).
- Every established-session `e2e` frame (`peer.hello`, every `rpc.*` frame,
  chunk frames, notices and `session.close`) MUST acquire local tokens before
  it is written. The local bucket rate and burst MUST NOT exceed the §3.5 pair
  defaults (1 MiB/s, burst 4 MiB); this revision's reference implementation
  uses **0.9 MiB/s and a 3.5 MiB burst** so that relay overhead and handshake
  frames fit inside the same relay bucket.
- Pacing is **queueing, not dropping**. The sender MUST NOT discard, coalesce
  or reorder a queued frame: sealing assigns `seq`, and one writer seals and
  enqueues in that order, so the pacer emits in `seq` order (§5.4). A queued
  frame still belongs to its session and is discarded only if that session is
  closed before the frame is written.
- A single frame larger than the burst (an 8 MiB plaintext value can exceed
  3.5 MiB on the wire) MUST wait until the bucket is full and then **overdraw**,
  exactly like the relay's `pclink-v1.4` single-frame rule: the balance goes
  negative and refills at the configured rate. It is never sent early and never
  split by the pacer (the §6.2 chunking already bounds the frame).
- `e2e.handshake` frames are small and are separately rate-limited by the relay
  (§3.5). They MAY bypass the application pacer so a handshake step is not
  delayed behind an application backlog; their bytes still count against the
  relay's pair bucket, which the margin above covers.
- Relay-plane frames (`relay.ping`/`pong`/`allow`/pair messages) are not E2E
  application frames and are not paced by this bucket.

**Relay `rate_limited`.** A `relay.error{code:"rate_limited"}` caused by the
pair, daily, slow-receiver, connection or handshake limit carries **no `sid`
and no peer correlation** (the relay does not echo the dropped frame in v1). A
sender therefore MUST treat any such error received while it has established
E2E sessions as evidence that at least one of its own `e2e` frames was dropped:

- It MUST immediately make the affected sessions unusable: stop writing
  application frames on those sids, abort/reject their streams and calls, and
  discard the keys. Because the error is uncorrelated and one relay connection
  may serve several paired peers, a PC MUST invalidate **every** established
  session on that connection; the phone has at most its one paired sid.
- Before discarding the keys it SHOULD best-effort send
  `session.close{code:"rate_limited"}` on each affected sid so the peer learns
  the session is dead without waiting for its reassembly timeout. The close is
  one small terminal frame; a sender MAY write it directly, bypassing its
  application queue, so it is not delayed behind the backlog. It may itself be
  dropped by the same limit, in which case the receiver's §6.2 chunk timeout is
  the backstop.
  No frame may follow the close on that sid, and the sender MUST NOT retry or
  replay application frames on it.
- In-flight calls follow §7 **on the caller**: `read` retries automatically on
  a new session, `idempotent` retries with the same DSH idempotency key
  (`session/prompt` uses `request.requestId`), and `unsafe` becomes
  `unknown_outcome`. The PC plugin never replays a call or a result on its own.
- The caller MUST wait at least `retryAfterMs` before re-handshaking (a missing
  value means at least 1 000 ms). The phone reconnects and initiates; the PC
  answers the next `session.init` normally and never dials the phone. A
  dropped `e2e.handshake` frame is retried only within the §5.1 handshake
  attempt budget — no E2E session existed, so nothing is invalidated.
- The conservative all-sessions rule is required because v1 has no
  correlation: even an error that a relay produced while opening a pairing
  rendezvous on the same connection is indistinguishable from a dropped
  application frame. Closing and re-handshaking is safe (it loses no data that
  §7 cannot retry); continuing on a session with a possible `seq` gap is not.

## 4. Pairing

### 4.1 Materials and pairing mode

- **S** is 16 random bytes (128 bits). The QR URI carries it as `s`.
- **C** is a 10-byte (80-bit) value encoded as exactly 16 Crockford base32
  characters using the alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (no
  `I`, `L`, `O`, `U`). The PC displays it as `XXXX-XXXX-XXXX-XXXX`; input is
  normalized by uppercasing, removing `-`, spaces and other whitespace,
  mapping `O`→`0` and `I`/`L`→`1`, and then requiring exactly 16 characters
  from the canonical alphabet. `U` and every other character are rejected.
  The 16 characters are the big-endian 80-bit value; decoding yields 10 bytes.
- `S` and `C` are generated by the PC with a CSPRNG, are single-use (one
  successful pairing), and are never sent to the relay. The relay sees only a
  rendezvous value.
- **Pairing mode is explicit.** `mode:"qr"` (the default) opens only the S
  rendezvous slot and displays only the QR URI. `mode:"manual"` (CLI
  `pair --manual` or the Web UI "手动输入码" action) opens only the C slot and
  displays the 16-character code. A v1 pairing never opens both slots, so a
  relay cannot race the QR flow into the manual flow by pre-claiming a second
  slot. The relay still enforces a per-connection cap of two open slots for
  future/defensive use.
- The PC name is 1–64 UTF-8 bytes, NFC, with no C0/C1/`Cf` characters (review
  L4). The phone name has the same limits. Names are display metadata and are
  covered by the pairing MACs and shown in the completion output and notice.

### 4.2 QR URI

```text
pclink://pair?v=1&r=<urlencoded relayOrigin>&m=<pcMachineId>&k=<pcIdentityPub b64url>&s=<S b64url>&n=<urlencoded pcName>
```

The URI is at most 512 bytes. `r` is the normalized, lowercase origin (§3.1),
`m` the PC machineId, `k` the PC raw Ed25519 public key, `s` the 22-character
`b64url` of S, `n` the PC name. The parser MUST reject an unknown query
parameter, a duplicate parameter, a non-`pclink` scheme, a host other than
`pair`, a path, fragment, userinfo, a wrong `v`, a wrong `k`/`s` length, a name
outside 1–64 UTF-8 bytes/not NFC/containing C0, C1 or `Cf`, an uppercase origin,
or a raw `+` in the query. All spaces MUST be `%20`; a raw `+` is rejected
rather than guessed as a space (review M1 negative vector), and a literal `+`
in a value is encoded as `%2B`. The phone MUST verify that the PC `publicKey`
in `pair.hello` equals `k` from the QR **before** it writes a record; a
mismatch is `auth_failed` and the phone closes the rendezvous. The phone
derives `machineId` from `k` and requires it to equal `m`. The QR path no
longer goes through a PC local approval: after the phone proves possession of
`S` in a verified `pair.auth`, the PC approves automatically and sends
`pair.confirm` (§4.4). Scanning the QR displayed on the PC screen is the
approval; the QR removes the code-guessing risk and the operator round-trip.

### 4.3 Rendezvous

For a secret `X` (the 16-byte S or the 10-byte C) and the normalized relay
origin `relayOrigin` of this pairing:

```text
rendezvous = b64url(sha256(
    "pclink-v1/pair" || 0x00 || UTF8(relayOrigin) || 0x00 || X))[0:22]
```

The origin is part of the hash input (review Low-4), so a rendezvous value
computed for one relay cannot be replayed against a different relay even if the
same S/C secret were reused by mistake. The `[0:22]` applies to the base64url
text, not decoded bytes. In a `qr` pairing the PC opens exactly one S slot; in
a `manual` pairing it opens exactly one C slot:

```json
{"v":1,"type":"relay.pair.open","rendezvous":"<22 chars>"}
```

A v1 PC MUST NOT open both slots for one pairing. The relay still enforces
`PCLINK_MAX_PAIR_SLOTS_PER_CONNECTION` (default 2) so a future version cannot
open an unbounded number; exceeding it is `rendezvous_exhausted` (or
`bad_frame` for a malformed open). There is no "one slot joined closes the
other" rule in v1 — with one open slot there is nothing to close, and the old
rule was an attack lever in review C1.

The relay matches only a `role:"pc"` opener with a `role:"phone"` joiner. It
returns `relay.pair.joined{rendezvous, role, peerMachineId}` to both when the
phone joins; `role` is the recipient's role. A slot expires 300 s after `open`
(absolute, never extended), and is deleted on completion or close. **Single-use
means one successful pairing**: a slot accepts at most 10 `relay.pair.join`
attempts in total (failed joins count; the 11th is
`rendezvous_exhausted`), and after the first successful join it is locked to
that phone connection; a second phone joining the same slot is
`rendezvous_exhausted` and cannot exchange payloads. The slot is deleted when
`pair.final` is accepted/`paired` closes, or on any other close. This is
consistent with the 10-attempt limit (the two are one rule, not a conflict;
review L3). The relay enforces 5 joins/minute per IP, with IPv6 aggregated by
/64 (§3.5). A join for an unknown/expired slot is
`relay.error{code:"rendezvous_expired"}`; excess IP attempts are
`rate_limited`. The relay never logs the rendezvous or the payload.

After the join, either participant sends the inner pairing payload wrapped as:

```json
{"v":1,"type":"relay.pair.message","rendezvous":"<22 chars>","payload":{...}}
```

The relay forwards `payload` verbatim to the other participant. A participant
that has not joined, a message for a closed slot, or a message after completion
is `bad_frame`/`rendezvous_expired`. Either side ends with:

```json
{"v":1,"type":"relay.pair.close","rendezvous":"<22 chars>","reason":"paired"}
```

The relay forwards the close to the peer and deletes the slot. Reasons are
`paired`, `cancelled`, `rejected`, `peer_offline`, `rendezvous_expired`,
`rendezvous_exhausted`, `auth_failed`, `storage`, `timeout`. `rejected` is an
explicit local refusal (kept for a pre-v1.6 PC that still prompts for manual
approval and for a future UI); a v1.6 PC normally ends a successful pairing
with `paired` and never waits for an operator decision. `timeout` covers a
pairing payload or a pre-v1.6 approval prompt that did not finish in time. If a
participant disconnects, the relay sends the other
`relay.pair.close{reason:"peer_offline"}` and deletes the slot. A second
`relay.pair.open` for the same rendezvous on the same PC connection is
idempotent; another PC opening an existing slot is `rendezvous_exhausted`.

A forged `relay.pair.close` from a participant only ends that rendezvous; it
cannot create a record, change a key, or bypass the verified one-time
screen-secret check. The worst effect is liveness (the user re-runs the
pairing), which is accepted (review L7). The pairing MACs are the cryptographic
boundary; possession of the screen secret is a human-process barrier, not an
absolute boundary against the classes in non-goal 7. The relay's close delivery
is neither.

### 4.4 Pairing handshake and automatic approval

The pairing payloads are `pair.*` objects. The pairing key is:

```text
pair_key = HKDF-SHA256(ikm = X, salt = 32 zero bytes, info = "pclink-v1/pair-mac", 32)
```

`X` is the S or C secret for this slot. A MAC is:

```text
MAC(domain, object) = HMAC-SHA256(pair_key,
    UTF8(domain) || 0x00 || canonical_json(object_without_mac))
```

with domains `pclink-v1/pair-hello`, `pclink-v1/pair-auth`,
`pclink-v1/pair-confirm`, `pclink-v1/pair-final`. `mac` is the `b64url` of the
32-byte HMAC. The messages are:

1. PC → phone `pair.hello` (inside `relay.pair.message.payload`):

```json
{"v":1,"type":"pair.hello","role":"pc","machineId":"...","publicKey":"...",
 "name":"My PC","relay":"https://relay.example","nonce":"<32B b64url>","mac":"..."}
```

2. Phone → PC `pair.auth`:

```json
{"v":1,"type":"pair.auth","role":"phone","machineId":"...","publicKey":"...",
 "name":"iPhone","relay":"https://relay.example","nonce":"<32B b64url>",
 "peerNonce":"<the hello nonce>","mac":"..."}
```

3. PC → phone `pair.confirm` (sent automatically after the PC verifies
   `pair.auth`):

```json
{"v":1,"type":"pair.confirm","role":"pc","nonce":"<hello nonce>",
 "peerNonce":"<auth nonce>","transcriptHash":"<32B b64url>","mac":"..."}
```

4. Phone → PC `pair.final`:

```json
{"v":1,"type":"pair.final","role":"phone","nonce":"<auth nonce>",
 "peerNonce":"<hello nonce>","transcriptHash":"<32B b64url>","mac":"..."}
```

Let `hello` and `auth` be the objects without `mac`. Their canonical SHA-256
digests are `th1` and `th2`; `transcriptHash = sha256(th1 || 0x00 || th2)`
(raw bytes). `pair.confirm` and `pair.final` MUST carry exactly that hash and
MUST be verified with the domain-separated MAC. The `relay` field MUST equal
the relay origin of the connection and the QR/record origin. The phone verifies
`pair.hello.publicKey == k` (QR path), derives `machineId` from the key and
compares it with `m`/`machineId`; it verifies the hello MAC and verifies the
hello `name` is NFC/1–64 bytes/no C0/C1/`Cf` before display. The PC verifies the
auth MAC, derives the phone `machineId` from `pair.auth.publicKey` and requires
it to equal the message's `machineId` (review L5), and verifies the auth `name`
with the same rule. Both sides verify all received MACs and the
transcript hash before writing anything. Neither side trusts a key because the
relay said `joined`.

**Automatic approval by the one-time screen secret (user decision,
2026-11-10).** After verifying `pair.auth` — MAC, relay origin, machineId
derivation, name rule and transcript inputs — the PC MUST approve the pairing
immediately: record `approvedAt` (UTC now) and `approvedVia` (`"qr"` for a QR
slot, `"manual"` for a manual slot) in memory, then send `pair.confirm`. A v1.6
PC MUST NOT enter `awaiting_approval`, MUST NOT wait for any local operator
input, and MUST NOT accept or compare a phone-displayed fingerprint as an
approval. Scanning the terminal QR or typing the manual code *is* the approval:
the joining phone has just proved possession of the single-use secret displayed
only on the PC screen, and the slot permits exactly one successful join.

The PC CLI and pairing page MUST NOT prompt for a phone fingerprint. The
pending-peer redaction still applies while the slot is not durable: `status`
and the Web UI expose only the verified `peerName`, never the pending
`machineId`, `publicKey` or fingerprint (§8.2). The record is written only
after verifying `pair.final`, and the PC MUST append the record hash plus
`approvedVia` to `pairs.log` before replacing `pairs.json` (§4.6, §8.1). If the
audit append or the record write fails, it sends
`relay.pair.close{reason:"storage"}` and writes nothing usable; the phone rolls
back the record it wrote. If the phone's write fails, it sends `storage` and
the PC writes nothing.

**Residual risk (accepted).** Anyone who can see or photograph the PC screen
while the slot is open can join first and be auto-approved, obtaining full
control of this PC's DSH. The slot is one per pairing, single-use, expires
after 300 s absolute, and the first successful join locks out later joiners
(`rendezvous_exhausted`). Within that window the screen secret is the only
human gate. This matches the WhatsApp Web-class "scan the QR on the screen"
model. It replaced compare-the-phone (review High-1) because that ritual failed
on real hardware: the user had to leave the iPhone to read its fingerprint into
the PC, the phone locked or backgrounded, the relay connection dropped, the PC
reported `pairing closed by peer: peer_offline`, and both the pairing and the
phone UI hung. The mitigations that remain are: the PC terminal and `status`
print `已配对：<phone name>（<fingerprint>）` and the exact revoke command
(`pclink unpair <machineId>`, or `pclink unpair --all`) as soon as the record is
durable; `pairs.log` records `approvedVia:"qr"|"manual"` and the record hash;
the PC sends `pclink.notice{kind:"paired"}` to every other established phone
(§4.6); and the App's "已连接的电脑" page shows the phone's own fingerprint,
pairing mode and pairing time for later verification. A leaked or observed
screen secret is handled by revoking the pairing immediately.

The approval is **not** an absolute boundary (review M-A), and this contract
does not claim otherwise: a same-user PC process that can read `pairs.json`/the
admin token or call the admin API can drive the admin surface, a process that
can see the screen can join first, and an agent running on an already-paired
phone with PC shell access can pair by acting as that phone's user. §8.1's
`Host`/`Origin`/`Content-Type` fence, the server-proof challenge, `pairs.log`,
the `/api/pclink.admin/*` source-Peer gate and the remote `pclink.admin/` ban
reduce and detect that class but do not make it impossible.

The phone sends `pair.final` only after it has durably written its record. The
phone record does not carry `approvedVia` (the PC approval is a PC-side fact);
it carries the same peer key/name/origin fields plus an optional phone-side
`pairingMode` (`"qr"|"manual"`) so the completed-pairing page can show which
action the user performed. `pairingMode` is not an approval field and the PC
never reads it. A lost final leaves a
one-sided phone record; on the next connection the PC answers with a signed
`unpaired` reject and the phone asks the user before removing it (§5.2/§5.5).
The PC's record is never written by an unapproved or relay-only flow.

### 4.5 Manual code path and why there is no SAS

The manual path uses the same `pair.hello/auth/confirm/final` exchange and the
same 80-bit C secret as §4.1/§4.4. There is no SAS, no six-digit value and no
second user comparison. The security argument is:

- The relay sees only
  `rendezvous = b64url(sha256("pclink-v1/pair" || 0x00 || UTF8(relayOrigin) || 0x00 || C))`
  and the MACs. To substitute keys it must know C, because `pair_key` is
  derived from C and every `pair.hello/auth/confirm/final` is MACed under it.
  Recovering C from the rendezvous or testing a guessed C against a captured
  MAC requires ~2^80 SHA-256/HMAC operations; the 300 s slot life, the
  10-join limit and the origin-bound hash only add to that. This is the C1 fix:
  the old 40-bit code was grindable in the rendezvous (`2^40`) and the
  uncommitted six-digit SAS could then be ground (`10^6`); with 80 bits and no
  SAS there is no feasible grind and no short comparison value to match.
- Positive possession of C proves the joiner can read the PC screen; the phone
  user performs an explicit pairing action and accepts the full-owner warning.
  A v1.6 PC approves the verified `pair.auth` automatically (§4.4). An
  attacker who only observes the screen after the first successful join is
  locked out by the single-use slot; one who observes the screen *before* the
  legitimate phone joins can join first and is approved. That is the accepted
  residual risk (§1/§4.4), not a cryptographic failure: the 80-bit C still
  authenticates the exchanged keys.
- The QR path is stronger (128-bit S plus the `k` pin) and remains the
  recommended path. The manual path is for a camera-less/blocked-camera PC and
  is selected explicitly with `pair --manual`/the Web UI manual action; the
  default is QR-only.

The user-facing manual prompt MUST display the code as `XXXX-XXXX-XXXX-XXXX`,
state that it is single-use and expires in five minutes, and include the
full-owner warning in §4.6. The phone text MUST NOT claim that the relay cannot
learn that a pairing happened, and MUST NOT mention a SAS.

### 4.6 Pairing record, audit log and UI obligations

The PC record is exactly:

```json
{"peerMachineId":"...","peerPublicKey":"...","peerName":"...",
 "pairedAt":"2026-11-09T00:00:00Z","relayOrigin":"https://relay.example",
 "connection":{"mode":"relay"},
 "approvedAt":"2026-11-09T00:00:05Z","approvedVia":"qr"}
```

`approvedAt` and `approvedVia` are required on every PC record. A v1.6 PC writes
`approvedVia:"qr"` or `"manual"` — the pairing mode whose one-time screen
secret the phone proved — when it verifies `pair.auth` (§4.4); the record
itself is written only after `pair.final`. Records persisted by a pre-v1.6 PC
may carry the legacy values `"cli"`/`"webui"`; they remain valid and usable,
are never rewritten, and `status`/the UI display them as a legacy
fingerprint-approval pairing. The phone record has the same fields except
`approvedAt`/`approvedVia`, and MAY additionally carry `pairingMode`
(`"qr"|"manual"`, phone-side display metadata). Its approval is the phone
user's own pairing action (the scan or manual-code submit) and warning. `peerName` follows the §2.1
name rule (1–64 UTF-8 bytes, NFC, no C0/C1/`Cf`). The PC record is
`schema/pairing-record.schema.json` (it requires both approval fields); the
phone record is `schema/phone-pairing-record.schema.json` (it forbids the
approval fields and allows the optional `pairingMode`).

PC storage is `$DSH_HOME/pclink/pairs.json` as
`{"v":1,"pcMachineId":"...","pairs":[record...]}` (max 1024 records) and the
phone storage is in Application Support as
`{"v":1,"phoneMachineId":"...","records":[record]}` (exactly zero or one
record). Both files are 0600 and written by atomic replace (temp file in the
same directory, fsync file and directory, rename). If the top-level
`pcMachineId`/`phoneMachineId` does not equal the current identity's machineId,
every record is stale: it is preserved for inspection, never used, and the UI
requires a new pairing. The phone allows exactly one PC; it MUST block a new
pairing while a record exists and offer "unpair the old computer" first. The PC
may pair up to 1024 phones. `mode:"direct"` is reserved; a v1 reader that sees
it does not use the record and reports `unavailable`/unsupported mode.

**Append-only audit log (review H2).** The PC also owns
`$DSH_HOME/pclink/pairs.log`, a 0600 append-only NDJSON file
(`O_APPEND|O_CREAT`, one fsynced line per event). Each line is one object:

```json
{"v":1,"event":"pair","peerMachineId":"...","peerPublicKey":"...",
 "recordSha256":"<sha256 hex of canonical_json(record)>",
 "approvedAt":"...","approvedVia":"qr","at":"..."}
{"v":1,"event":"unpair","peerMachineId":"...","at":"..."}
{"v":1,"event":"rotate","oldMachineId":"...","newMachineId":"...","at":"..."}
```

Before `pairs.json` is replaced with a new record, the matching `pair` line
MUST be appended and fsynced. `recordSha256` is SHA-256 over the UTF-8
`canonical_json` of the complete record (including `approvedAt`/`approvedVia`).
On load, for every record the latest `pair`/`unpair` event for that
`peerMachineId` must be a `pair` line whose `peerMachineId`, `peerPublicKey`
and `recordSha256` match; otherwise the record is **unapproved** or **revoked**:
it is never used, it is preserved for inspection, and `status`/the Web UI shows
a warning (`usable:false` with `reason:"unapproved"|"revoked"`). Deleting
`pairs.log` therefore makes every record unusable and requires re-pairing; that
is deliberate fail-closed behaviour. `pairs.log` is append-only in v1 (no
rotation). A same-user process can still append a forged line or edit the file;
the log detects ordinary non-admin writes and raises the bar, it is not a
defence against a malicious same-user process (§1 non-goal 7).

**Revocation (review H2/M4).** The "revoke" action lists every pairing and
offers "revoke all" (and a per-record action). For each record, in this order:
close every E2E session for the peer and abort any in-progress handshake; append
the `unpair` tombstone line to `pairs.log` and fsync; remove the record from
`pairs.json`; update `relay.allow`. The `unpair` line is a persistent tombstone:
even if the record removal fails or the process crashes, the record is
`revoked` on the next load. If the tombstone append fails, the unpair fails and
the PC MUST NOT connect to the relay (fail-closed for the whole plugin) until it
succeeds; it MUST NOT merely keep the peer closed in memory. After removing all
records the user MAY rotate the PC identity with `pclink rotate-identity`
(§8.3). Rotation writes a new `identity.key` and a `rotate` line; every old
record becomes stale (`pcMachineId` mismatch) and every phone must re-pair. The
old key is not reused and no session or record is migrated.

**Stolen or lost phone (review M-A).** The required handling is **revoke all
pairings, then run `rotate-identity`**. Revoking only the stolen phone is not
enough when the phone may already hold the PC shell; rotating the PC identity
invalidates every old record and forces every phone to re-pair. A phone-only
local removal is not authoritative (§5.5). The CLI/Web UI MUST state this
sequence on the unpair/rotate screens.

**New-pairing notice (review M-A).** After the PC has durably written a new
record and audit line, it MUST send the following inner message over the
established end-to-end session to every **other** paired phone that currently
has one:

```json
{"type":"pclink.notice","kind":"paired","name":"iPhone",
 "fingerprint":"gewr-a3lz-quax","at":"2026-11-09T00:00:05Z"}
```

`name` and `fingerprint` identify the newly paired phone; `fingerprint` is the
same 12-character value derived from its machineId. The phone UI MUST display
the notice with a warning that an unexpected pairing means "revoke all and
rotate identity". The Web UI plugin page MUST show a persistent banner for the
most recent successful pairing (not a transient toast). There is no queued
notice: a phone that was offline when the pairing completed sees the banner on
the PC and the pair in `status` when it reconnects. A compromised PC can
suppress or forge this notice; it is a detection aid, not a security boundary.

Before the phone writes the first pairing record (or replaces a stale one), it
MUST show this exact warning and require an explicit pairing action — the scan
of the terminal QR or the submit of the manual code:

> 连接后，这台手机可以完整使用这台电脑上的 DSH（对话、Shell、文件、审批与设置）。

The PC CLI/terminal and Web UI MUST print/show the equivalent warning when the
QR/code is displayed. There is no local approval prompt in a v1.6 PC: the
verified `pair.auth` is approved automatically (§4.4). The pairing is never
silent. The phone MUST NOT describe the PC as tamper-resistant, and neither end
may claim endpoint restrictions that do not exist (there is no endpoint
allowlist; §7). A record is usable only after the PC's durable write and audit
line; a phone record whose PC never wrote is one-sided and is cleared only after
the signed-`unpaired` prompt in §5.5.

**Completed-pairing display obligations (P09).** After a pairing is durable, the
PC CLI/`status` MUST print `已配对：<phone name>（<fingerprint>）` and the exact
revoke command. The App's "已连接的电脑" page MUST show this phone's own
fingerprint (for verification), the pairing mode (扫码/手动码; a legacy record
may show its fingerprint-approval origin), and the pairing time. The pairing
page itself MUST NOT show a fingerprint card or instruct the user to type a
fingerprint into the PC.

## 5. End-to-end sessions

### 5.1 Handshake carrier

Before keys exist, the bootstrap messages travel in a distinct outer carrier:

```json
{"v":1,"type":"e2e.handshake","sid":"<16B b64url>","from":"<machineId>",
 "to":"<machineId>","body":{ /* session.init | session.resp | session.confirm | session.reject */ }}
```

`e2e.handshake` has no `seq`, no AEAD and no AAD. It is relay-visible; it MUST
NOT contain identity private keys, secrets or application data. `body` is a JSON
object. Only the phone initiates; the PC answers. A PC that sends `session.init`
or a phone that sends `session.resp` is `bad_frame`. The carrier contains only
PCLink fields and has no DSH passthrough member; the §2.3 escaped-`\u0000`
allowance applies to the AEAD inner messages, not to this plaintext carrier.

The phone chooses a fresh 16-byte `sid` for every handshake. The PC accepts at
most 10 handshake attempts per peer per minute and at most 64 pending
handshakes process-wide; excess attempts get
`session.reject{code:"rate_limited"}` (or are silently dropped if the PC cannot
even associate a pairing record; see below). The PC keeps a sid cache of at
most **4096** entries (active, completed and rejected) for **five minutes**.
On overflow it evicts the least-recently-used entry; eviction only weakens
replay detection for a sid older than the last 4096, and cannot create a
session without the phone's identity signature (the E2E handshake still
requires `sig_phone`). A reused sid still in the cache gets
`session.reject{code:"replay"}`. A new `session.init` for a peer with an
existing established session is allowed only as a rekey (§5.5); while one
handshake for that peer is already in progress, another init is
`rate_limited`. A phone MUST have at most one established and one handshaking
session per PC.

For an `e2e.handshake` whose `from` has **no local pairing record**, the PC MUST
send at most one signed `session.reject{code:"unpaired"}` for a syntactically
valid `session.init` and MUST NOT create a sid-cache entry or any session
state (review M3). The signed reject is useful so a phone whose PC was unpaired
can prompt its user (§5.2/§5.5), while the no-cache rule means an attacker
cannot exhaust the 4096-entry cache with unknown `from` values. The PC limits
these unknown-peer rejects to 5 per `from` per minute and 120 process-wide per
minute; beyond that it silently drops. It never sends `session.resp` to an
unknown `from`. A syntactically invalid init is silently dropped (no response,
no sid, no state); the signed `unpaired` reject is only for a well-formed init
from an unknown `from`. This is a deliberate choice over always dropping: the
signed reject is a small, bounded, rate-limited Ed25519 operation and it
preserves the user-visible "computer removed this phone" recovery path without
granting the attacker a record, a session or a cache slot. It reveals only that
the PC is online, which the relay already observes.

### 5.2 Handshake messages and transcripts

`session.init` (phone → PC):

```json
{"v":1,"type":"session.init","sid":"...","suite":"pclink-x25519-ed25519-chacha20poly1305-1",
 "eph":"<phone X25519 public, b64url>","nonce":"<32B b64url>"}
```

`session.resp` (PC → phone):

```json
{"v":1,"type":"session.resp","sid":"...","eph":"<PC X25519 public, b64url>",
 "nonce":"<32B b64url>","sig":"<Ed25519 PC signature>","confirm":"<32B b64url>"}
```

| Type | Direction | Authentication |
| --- | --- | --- |
| `session.init` | phone → PC | fresh `sid`, suite, phone ephemeral X25519 public key, phone nonce |
| `session.resp` | PC → phone | `sig_pc` over `T_resp`; `confirm_pc` under `k_confirm_pc` |
| `session.confirm` | phone → PC | `sig_phone` over `T_confirm`; `confirm_phone` under `k_confirm_phone` |
| `session.reject` | either, before keys | terminal code; a PC reject of a valid init carries `sig`; no key is installed |

The phone identity public key is deliberately **not** sent: the PC looks it
up in the pairing record by the outer `from` machineId, and the phone looks up
the PC key in its record/QR. This removes an in-band key-substitution surface,
but it does **not** hide identity: the outer `from`/`to` machineIds and the
relay's authenticated public-key mapping are visible to the relay (review L2).
PCLink v1 provides no identity hiding.

`session.confirm` (phone → PC):

```json
{"v":1,"type":"session.confirm","sid":"...","sig":"<Ed25519 phone signature>",
 "confirm":"<32B b64url>"}
```

`session.reject` (either, before keys; terminal for the handshake):

```json
{"v":1,"type":"session.reject","sid":"...","code":"unpaired","sig":"<PC Ed25519 signature>","message":"..."}
```

A **PC** reject that answers a syntactically valid `session.init` MUST carry
`sig`; `sig` is optional for a reject from the phone (the PC can verify the
phone's signature only if it has a record, and a phone reject is never a record
deletion trigger). The signature is (review H1):

```text
code in the signature is the UTF-8 string of the reject code
T_reject = "pclink-v1/session-reject" || 0x00 || th1 || 0x00 || UTF8(code)
sig      = Ed25519(IK_pc, T_reject)
```

`th1` is the transcript hash of the `session.init` being rejected. The phone
MUST verify `sig` with the pinned PC public key from its pairing record/QR and
MUST match the `th1`/`sid` of its own in-progress init. A reject with a missing
or invalid `sig`, or one whose `th1` does not match, is an **unauthenticated
handshake failure**: the phone fails that handshake, shows "无法连接电脑" and
may retry, but MUST NOT delete the pairing record, MUST NOT auto-pair and MUST
NOT treat the code as authoritative. `auth_failed` behaves the same way: it
never triggers automatic deletion or automatic re-pairing.

The exact transcript bytes use the raw `sid`, public keys and nonces, not their
`b64url` text, except that machineIds/suite/version are UTF-8 strings and the
domain strings are UTF-8. The protocol version and suite are bound in
`T_init`; `th1` then carries them into `T_resp`/`T_confirm` (review L1):

```text
T_init   = "pclink-v1/session-init" || 0x00 || "1" || 0x00 || UTF8(suite) || 0x00
           || UTF8(phoneMachineId) || 0x00 || UTF8(pcMachineId) || 0x00
           || sid || 0x00 || eph_phone || 0x00 || nonce_phone
th1      = sha256(T_init)

T_resp   = "pclink-v1/session-resp" || 0x00 || th1 || 0x00
           || eph_pc || 0x00 || nonce_pc
th2      = sha256(T_resp)
sig_pc   = Ed25519(IK_pc, T_resp)

T_confirm = "pclink-v1/session-confirm" || 0x00 || th2 || 0x00
            || UTF8(phoneMachineId) || 0x00 || UTF8(pcMachineId) || 0x00 || sid
th3      = sha256(T_confirm)
sig_phone = Ed25519(IK_phone, T_confirm)
```

The PC verifies `sig_phone` with the **pinned public key** from its pairing
record for `phoneMachineId`; it never trusts a key sent in the handshake. The
phone verifies `sig_pc` with the pinned PC key from its record/QR. The PC
checks `from`/`to` against its pairing table and the outer `sid` against the
body's `sid`; the phone does the reverse. A missing pairing record, a revoked
record or a stale identity gives a signed `session.reject{code:"unpaired"}` and
no keys. A wrong signature/MAC, a bad suite, a reflected/wrong-direction
message or an all-zero X25519 shared secret gives `session.reject{code:"auth_failed"}`
(if a response is sent). A suite not equal to the v1 suite gives
`version_unsupported`; a malformed frame gives `bad_frame`. The receiver waits
10 seconds for the next handshake message; on timeout it discards keys and
closes the logical handshake (no `session.reject` is required after keys).

Both ends MUST generate a **fresh ephemeral X25519 key pair for every
handshake** and MUST destroy the private key when the handshake fails or the
session closes (review M2). Reusing an ephemeral key across handshakes is a
protocol violation. A peer X25519 public key of all zeroes and a derived
`dh == 0^32` (which is the result for every low-order point) MUST be rejected
before any key derivation; the receiver treats it as `auth_failed` and never
installs keys. The phone also chooses a fresh 16-byte `sid` for every handshake.

### 5.3 Keys and confirmation

Let `dh = X25519(eph_phone_priv, eph_pc_pub) = X25519(eph_pc_priv, eph_phone_pub)`.
Reject `dh == 0^32` before deriving keys. The application and confirmation keys
are derived separately (review M2); the traffic keys are **not** reused for the
confirmations:

```text
salt = th2
k_phone_to_pc = HKDF-SHA256(ikm = dh, salt = th2, info = "pclink-v1/key/phone->pc", 32)
k_pc_to_phone = HKDF-SHA256(ikm = dh, salt = th2, info = "pclink-v1/key/pc->phone", 32)
k_confirm_phone = HKDF-SHA256(ikm = dh, salt = th2, info = "pclink-v1/key-confirm/phone->pc", 32)
k_confirm_pc    = HKDF-SHA256(ikm = dh, salt = th2, info = "pclink-v1/key-confirm/pc->phone", 32)
```

The key confirmations are:

```text
confirm_pc    = HMAC-SHA256(k_confirm_pc, "pclink-v1/confirm" || 0x00 || th2)
confirm_phone = HMAC-SHA256(k_confirm_phone, "pclink-v1/confirm" || 0x00 || th3)
```

The phone MUST verify `resp.sig` and `resp.confirm` before sending
`session.confirm`; the PC MUST verify `confirm.sig` and `confirm.confirm`
before it marks the session established, and at that point it MUST re-read its
pairing table and re-check that the record for `phoneMachineId` still exists,
matches the pinned key and is not revoked (review M4). If the record is gone,
the PC aborts the handshake and installs no keys. The ephemeral private keys
are destroyed when the session closes or the handshake fails. Identity keys are
used only for signatures. The transcripts bind both machineIds, the protocol
version, the suite, both ephemeral keys, both nonces and the sid; replayed or
cross-session messages fail. The `salt = th2` change makes the traffic and
confirmation keys depend on the full handshake transcript, not just
`(dh, sid)`.

### 5.4 AEAD frame, nonce, sequence and AAD

After the handshake, application messages use:

```json
{"v":1,"type":"e2e","sid":"<22 chars>","seq":0,"from":"<machineId>",
 "to":"<machineId>","body":"<b64url(ciphertext||tag)>"}
```

`body` is ChaCha20-Poly1305 over the UTF-8 bytes of exactly one inner message.
The nonce is 12 bytes: four zero bytes followed by the 8-byte big-endian `seq`:
`00000000 || u64be(seq)`. `seq` starts at 0 for each direction of each session
and is strictly contiguous: the receiver keeps `last_seq` per direction; the
first frame MUST be 0, every next frame MUST be `last_seq + 1`; `seq <= last_seq`
is `replay`, a gap (`seq > last_seq + 1`) is `bad_frame`. There is no sliding
window: WebSocket/TCP preserve order, the relay does not reorder, and a gap
means the session cannot be trusted. A relay may drop a frame; the result is a
closed session, not a silently skipped message.

The frame counter has a soft and a hard limit (review L3): at **2^19 (524,288)
frames** in one direction, or **1 GiB** of plaintext in that direction, the
sender MUST start a rekey (§5.5) and MUST NOT send new calls on the old
session. The old session may still finish the frames already in flight. The
hard cap is **2^20 (1,048,576) frames** per direction: a frame with
`seq >= 2^20` is `session_expired` and the receiver closes; the sender MUST
never emit it. The two limits do not conflict: 2^19 is the "start rekey" line,
2^20 is the "cannot use this session any more" line. A receiver that reaches
2 GiB of plaintext in one direction also closes with `session_expired` as a
backstop, but the sender's 1 GiB rekey obligation is the primary rule.

The AAD is exactly the following bytes (all text is UTF-8; decimal `seq` has no
leading zero):

```text
"pclink-v1/aad" || 0x00 || "1" || 0x00 || "e2e" || 0x00
 || sid_b64url || 0x00 || decimal(seq) || 0x00 || from || 0x00 || to
```

The receiver MUST reconstruct the AAD from the received outer fields and MUST
NOT trust `from` as identity: it verifies `from` equals the paired peer, `to`
equals itself, `sid` is the active session, and the AEAD tag. The relay's
allowlist is irrelevant to this check. Any change to `v`, `type`, `sid`, `seq`,
`from` or `to` fails decryption (`auth_failed`). The body is opaque to the
relay. The outer frame is closed: unknown members are `bad_frame`.

The byte counter for rekey counts the UTF-8 plaintext bytes of each inner
message actually sent in that direction (chunk frames count as their own
plaintext, not the reassembled value); 1 GiB = 2^30 bytes.

### 5.5 Rekey, close and replay

The **soft** threshold is 2^19 frames or 1 GiB of plaintext in one direction;
reaching it requires a new session (§5.4). Both ends maintain the frame/byte
counters for **both** directions: the phone initiates the rekey when either
direction reaches the soft threshold, and the PC never initiates a session. A
PC that reaches its send threshold stops producing new stream values after the
in-flight frame and lets the phone observe the counter; if the phone has not
rekeyed by the 2^20/2 GiB hard cap, the PC closes with `session_expired`. The
phone starts a new handshake (new sid, new ephemeral keys) and does not send new
calls on the old session. Once the new session is established (`peer.hello`
received), the phone sends `session.close{code:"rekey"}` on the old session and
closes it immediately; the old keys are destroyed. There is no 30-second drain:
WebSocket/TCP is ordered, so no old frame can arrive after the close on the
same connection, and every in-flight call/stream follows the retry rules of §7.
The PC, on receiving a new `session.init` for a peer with an established
session, permits one handshake; the older session remains usable until the new
session reaches `peer.hello`, then the PC closes the older session with
`session.close{code:"rekey"}` if the phone has not already done so. If the new
handshake fails, the older session is still valid; the phone may retry a fresh
handshake, and it must not send new calls on the older session after it has
started the rekey. A PC never initiates a session. The **hard** cap is 2^20
frames or 2 GiB of plaintext: the PC closes with
`session.close{code:"session_expired"}` at the cap; there is no 30-second grace
window and no separate "only if not rekeyed" rule (review L3).

`session.close{code,message?}` is the terminal inner message. Either end may
send it; after sending/receiving it, the sender/receiver stops accepting frames,
aborts all open streams, discards keys and never sends another frame on that
sid. In-flight unary calls follow the endpoint retry class: a definitive
`rpc.result` already received wins; otherwise a read/idempotent call may be
retried on the new session and an unsafe call becomes `unknown_outcome` (§7).
A frame for a closed/unknown sid is `session_expired`/`replay` and is dropped;
the PC never sends a result on a closed session. `session.close` does not
retroactively prove that an unsafe side effect did not happen.

**PC-side idle timeout (review M4).** The PC closes an established E2E session
after **15 minutes** in which no `e2e` frame for that sid arrived in either
direction (heartbeats are relay frames and do not count). It sends a best-effort
`session.close{code:"session_expired"}`, discards the keys and marks the peer
offline. `status.online` is true only for an established session that has not
hit this timeout. The PC cannot observe the phone's relay disconnect (that was
an incorrect `pclink-v1` statement); the phone's own relay close ends its E2E
session, and the 15-minute rule bounds a silent half-open case.

Unpair is symmetric at the session level. The PC's admin/DSH `unpair` first
aborts every in-progress handshake for that peer, closes every established
session for that peer with `session.close{code:"unpaired"}`, then discards
keys, appends the durable `unpair` tombstone to `pairs.log`, removes the record
and the allowlist entry (§4.6). The tombstone/removal ordering and the
fail-closed rule are normative: a record whose latest audit event is `unpair`
is never used even if the record file still contains it. A phone that receives
`session.close{code:"unpaired"}` on an authenticated session, or a verified
signed `session.reject{code:"unpaired"}` for its current init, MUST show
"电脑已解除与此手机的配对" and wait for the user's explicit confirmation before
removing the local record; it MUST NOT auto-delete and MUST NOT auto-pair. An
unauthenticated reject or an `auth_failed` never deletes the record. A
phone-initiated unpair sends `session.close{code:"unpaired"}` on a live session
as a best effort, discards keys and removes its record; the PC that receives
that close code also removes the phone record and allowlist entry through the
same tombstone path. If the phone is offline, its local removal cannot notify
the PC: the UI instructs the user to unpair on the PC as well, and the stale PC
record remains until then. The PC-side unpair is the authoritative revocation.

Rejected handshakes and used sids are remembered for five minutes (bounded by
the 4096-entry cache in §5.1). A session also ends on unpair, a changed pairing
record/identity, the PC's 15-minute idle timeout, the phone's relay connection
closing, or an explicit close. The first frame in each direction of an
established session MUST be `peer.hello`; `session.close` is also allowed as the
first frame to abort. Anything else before `peer.hello` (including an
`rpc.call`/`rpc.stream.open`) is `bad_frame`.

### 5.6 Peer hello, capabilities and DSH version

`peer.hello` (first AEAD message in each direction):

```json
{"v":1,"type":"peer.hello","role":"phone"|"pc",
 "caps":["workspace/1","pclink-x25519-ed25519-chacha20poly1305-1"],
 "dsh":{"version":"0.2.2-rc.1","commit":"66491b05"},
 "app":{"name":"phoneDSH","version":"0.1.0"},"name":"iPhone"}
```

`v` is the inner PCLink version (1). `role` MUST match the sender. `caps` is 1–16
unique ASCII capability names. PCLink v1 requires both `workspace/1` and the
suite name; if either is absent from the intersection, the receiver sends
`session.close{code:"version_unsupported"}` and closes. Extra unknown
capabilities are ignored. `dsh.version` is required and parses as SemVer
`MAJOR.MINOR.PATCH(-prerelease)?`; `dsh.commit` is optional 7–64 lowercase hex
(omit it when a packaged install cannot discover it; do not send `"unknown"`).
`app.name` (1–64) and `app.version` (1–32, `[0-9A-Za-z.+-]`) are display
metadata. `name` is 1–64 UTF-8 bytes, NFC, no C0/C1/`Cf` characters (review
L4); both `app.name` and `name` are display-only and are normalized/checked
before display, never used for routing or authorization.

The **tested DSH range** is `>=0.2.2-rc.1 <0.3.0` (SemVer, prereleases included).
A `dsh.version` outside that range is **not** a connection failure: the phone
shows a persistent "版本未验证" banner and the PC logs a warning. Individual
DSH endpoint failures are surfaced per endpoint (§7/§9); the transport does not
hide them. The range is checked on `install` and on every `peer.hello`.
`relay.challenge`/`peer.auth` have no DSH version check.

## 6. Inner messages

All inner messages are AEAD plaintexts. They are closed objects; the schema is
`schema/inner-message.schema.json`. The first message each way is `peer.hello`.
Inner JSON follows §2.3: a decoded `U+0000` under `rpc.call.args`,
`rpc.stream.open.payload.args`, `rpc.result.result`,
`rpc.stream.item.value` or reassembled chunk data is DSH data and MUST be
preserved; PCLink-owned fields in the same object (`type`,
`id`, `streamId`, `endpoint`, `code`, `message`, `name`, ...) keep their own
field rules. The message types are:

| Type | Direction | Purpose |
| --- | --- | --- |
| `peer.hello` | both | capabilities, DSH/app/display metadata |
| `rpc.call` | phone → PC | one DSH unary call |
| `rpc.result` | PC → phone | unary result |
| `rpc.result.chunk` | PC → phone | chunked unary result |
| `rpc.stream.open` | phone → PC | open one DSH stream |
| `rpc.stream.item` | PC → phone | one stream value |
| `rpc.stream.chunk` | PC → phone | chunked stream value |
| `rpc.stream.end` | PC → phone | stream terminal success |
| `rpc.stream.error` | PC → phone | stream terminal failure |
| `rpc.stream.cancel` | phone → PC | cancel one stream |
| `session.close` | both | terminal session close |
| `pclink.notice` | PC → phone | out-of-band display notice (new pairing) |
| `task.*.error`, `call.*.error` | both | reserved namespace default reply |

No other inner type is valid in v1. A receiver of an unmatched `task.*` or
`call.*` message (any suffix) MUST reply with the corresponding
`task.*.error`/`call.*.error`, `code:"unavailable"`, and no other effect. If
the reserved message has an `id`, the error echoes it. No reserved executor,
store or schema is defined.

`pclink.notice` is PC → phone only and is not a request, response or stream. In
v1 the only `kind` is `paired`:

```json
{"type":"pclink.notice","kind":"paired","name":"iPhone",
 "fingerprint":"gewr-a3lz-quax","at":"2026-11-09T00:00:05Z"}
```

The PC sends it after a durable new pairing to every other paired phone with an
established E2E session (§4.6). `name` follows the §2.1 name rule,
`fingerprint` is exactly `^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$`, and `at` is
the approval time. The phone MUST display the notice; it MUST NOT use it to
create, delete or modify a pairing. Unknown `kind` or any other extra member is
`bad_frame`.

### 6.1 Unary calls

```json
{"type":"rpc.call","id":"call-1","endpoint":"session/list","args":{"_request":{}}}
```

`id` is 1–64 `[A-Za-z0-9._:-]`, unique among in-flight calls in this session;
reuse while in flight is a request-level `bad_frame` (answer the duplicate with
`rpc.result{ok:false,error:{code:"bad_frame",message:"duplicate id"}}` and do
not execute it). `endpoint`
is the DSH `<ns>/<method>` string (the `$` namespace is allowed, e.g.
`$events/result`); it is not a URL or path. `args` is the exact DSH `args`
object, maximum 8 MiB of UTF-8 JSON. It is a §2.3 DSH passthrough value: a
decoded `U+0000` from a legal `\u0000` escape is data and MUST be forwarded to
DSH unchanged; do not apply the name/control-character rule to `args`. The PC
plugin does **not** rewrite args and does **not** consult a general allowlist.
There is exactly one forbidden endpoint prefix: a `rpc.call` or
`rpc.stream.open` whose `endpoint` starts with
`pclink.admin/` is answered with
`rpc.result{ok:false,error:{code:"forbidden",message:"remote pclink.admin calls are forbidden"}}`
or
`rpc.stream.error{error:{code:"forbidden",message:"remote pclink.admin calls are forbidden"}}`
and is **never** forwarded to DSH (review H2). This is not an endpoint
allowlist; every other DSH endpoint is forwarded as before.

The **authoritative** admin-route check is the request **source Peer**, not an
endpoint/path string (review M-B). In the `/api/pclink.admin/*` handler the
plugin MUST reject a request whose source Peer is a PCLink remote/relay-facing
Peer (the plugin's per-e2e-session Peer) and MUST NOT base the decision on the
endpoint prefix, a path alias or a casing variant. The forwarder's
`pclink.admin/` prefix test remains only as a cheap early rejection before DSH
dispatch. A remote `rpc.*` call that reaches the handler must still be refused
and surfaced as the PCLink `forbidden`; the owner Web UI path is unaffected.
DSH endpoint dispatch itself does exact, case-sensitive namespace/method
matching with no aliasing (§7), so no PCLink normalization or alias is added.
The local/Web UI admin routes are reachable only through the local admin carrier
and the DSH owner-only `/api/pclink.admin/*` routes, never through a remote
PCLink `rpc.*` call. The plugin constructs a DSH in-process
`client-request` with `payload:{"args":<args>}`, sends it through the owner
Peer's shared fetch handler, and answers:

```json
{"type":"rpc.result","id":"call-1","ok":true,"result":{...}}
{"type":"rpc.result","id":"call-1","ok":false,
 "error":{"code":"session/not-found","message":"...","details":{...}}}
```

`result` and `error` are mutually exclusive; `ok` decides which is present.
`result` is a §2.3 DSH passthrough value: a decoded `U+0000` in it is preserved
and never used to reject the frame. `error` is the PCLink error object, not a
DSH payload channel; its `message` is display text (§2.3). The error object is
always exactly `{code,message,details?}` with a required `message`;
`rpc.stream.error` uses the same
`{"type":"rpc.stream.error","streamId":"...","error":{code,message,details?}}`
shape and never a top-level `code`. A DSH error code is passed through
unchanged (the DSH code namespace, e.g. `gateway/arguments-invalid`,
`session/not-found`); it is not remapped to a PCLink code. `forbidden` is the
**PCLink** code from §9.1 and is the only PCLink-namespace code that may appear
in `rpc.result.error`/`rpc.stream.error.error`; there is no DSH
`gateway/forbidden` alias for it. `message` is capped at 2048 UTF-8 bytes;
`details` is an optional object. The plugin may complete a call after the e2e
session closed; the result is then discarded and never sent. It does not impose
a PCLink-level unary timeout.

`$events/result` is special: its `args` are exactly
`{clientId,eventId,outcome}` (one layer, never `{args:{...}}`). It MUST be sent
through the same owner Peer that opened the `$events` stream; another Peer
receives `gateway/interactions-forbidden` from DSH. The phone opens `$events`
before its prompt, remembers `clientId` from the `ready` frame and answers each
`waterfall` approval/question with this call. First answer wins; a later answer
is a no-op. A turn can require several approvals and the phone MUST answer each
one; closing the stream early leaves the turn pending. Approval/question
answers are `unsafe` (§7).

### 6.2 Streams, chunking and cancellation

```json
{"type":"rpc.stream.open","streamId":"stream-1","endpoint":"session/follow",
 "payload":{"args":{"request":{"address":{"kind":"session","sessionId":"session-1"},
 "maxMessages":1,"assistantStream":true}}}}
```

If the PC DSH profile has no `typertGateway`, the plugin MUST refuse to start
and report `unsupported-profile`; it does not dial the relay or advertise a PC
endpoint, and the phone shows the PC as unavailable. It does not start a
degraded unary-only service.

`payload` is exactly the DSH `wireStream.open` payload: an object with an `args`
member and no other members in v1. `streamId` is 1–64, unique per session and
never reused. The PC opens the stream through the same owner Peer used for
`$events/result` on that e2e session, with an **empty uplink** (v1 has no
client-to-stream values). Each yielded JS value becomes one
`rpc.stream.item{streamId,value}`. The stream ends with `rpc.stream.end` or
`rpc.stream.error{error:{code,message,details?}}`. A DSH stream error code is
passed through unchanged, except `forbidden` which is the PCLink code (§9.1).
`rpc.stream.cancel{streamId}` asks the PC to abort; the PC calls
the DSH abort controller and waits for the iterator's `return()` before sending
`rpc.stream.end`. If the iterator does not return within 30 seconds, the PC
sends
`rpc.stream.error{error:{code:"unavailable",message:"cancel did not settle"}}`
and closes the session; it never pretends the cancel finished. A cancel for an
already-terminal stream is ignored. Late items/chunks after `end`/`error`/cancel
are discarded.

**Chunking.** A single item's JSON encoding (the exact UTF-8 bytes of
`value`) up to 1 MiB is sent as one `rpc.stream.item`; if it is larger it is
split into `rpc.stream.chunk{streamId,part,last,data}` frames, where `part`
starts at 0 and increases by 1, `last` is true exactly on the final chunk, and
`data` is the `b64url` of a contiguous byte range of that same JSON encoding.
The receiver concatenates in part order, UTF-8 decodes exactly once and parses
exactly one JSON value; it MUST NOT deliver a partial value. The decoded value
is a §2.3 DSH passthrough: parse it without character filtering and preserve a
decoded `U+0000`. The reassembled plaintext MUST be ≤ 8 MiB; a larger value ends
that stream with
`rpc.stream.error{error:{code:"frame_too_large",message:"value exceeds 8 MiB"}}`.
A chunk `data` SHOULD be ≤ 1 MiB
raw bytes (the maximum chunk length is 1,500,000 `b64url` characters) so a
16 MiB relay frame always fits. If a stream is cancelled mid-item, all received
chunks are discarded; the phone never exposes a partial value.

A unary result is chunked the same way when the **entire `rpc.result` JSON**
(the object with its `id`, `ok` and result/error) exceeds 1 MiB:
`rpc.result.chunk{id,part,last,data}` frames carry contiguous UTF-8 bytes of
that object; the receiver reassembles and parses one `rpc.result`, whose `id`
MUST equal the chunk `id`. A normal `rpc.result` is never sent for a chunked
result. A reassembled result > 8 MiB is
`rpc.result{ok:false,error:{code:"frame_too_large",message:"result exceeds 8 MiB"}}`;
the chunk sequence is discarded. The 16 MiB
relay frame limit is independent: an `e2e` frame whose JSON text exceeds 16 MiB
is `frame_too_large`; the sender must chunk below it.

Reassembly enforces part order, exactly one `last`, no duplicate/missing parts,
no interleaving of two values on the same stream/id, and a **30-second
inactivity timeout per value** (`pclink-v1.5`). The timeout is measured from
the last accepted chunk of that value, not from the first: a large result that
keeps arriving is not failed at 30 seconds total, while a stalled sequence is.
At the timeout the receiver MUST discard the partial value and fail the
call/stream; it MUST NOT leave the call/stream pending forever. Failure obeys
the §7 class of the call/stream: a `read` unary call retries automatically on a
new session, an `idempotent` call retries with its same DSH idempotency key, an
`unsafe` call becomes `unknown_outcome`, and a `read`-class stream is closed and
reopened by its consumer. Chunks for **different** `streamId`s may interleave;
the receiver keys reassembly by `streamId`/`id` and never mixes two values
(review M1's interleaving vector). A malformed sequence fails that stream/call
with `bad_frame` and discards the partial value. `rpc.result.chunk` and `rpc.stream.chunk` count as
their own plaintext bytes for the 1 GiB rekey counter.

**Backpressure (v1).** There is no credit frame in v1. The PC pulls one DSH
value at a time and awaits the WebSocket send completion (or a `bufferedAmount`
below 64 KiB) before pulling the next; TCP/WebSocket backpressure propagates to
the DSH iterator, so one slow phone stops that stream rather than growing an
unbounded queue. Multiple streams may be in flight, but each stream has at
most one in-flight item/chunk at a time (there is no acknowledgement frame; the
sender simply does not produce the next value until the previous send has
completed). If the phone's reassembly buffer
would exceed 8 MiB for one value or 16 MiB total, it cancels the affected
stream(s) and discards the partial bytes. This is the v1 flow-control contract;
a credit frame would be a new protocol surface and is not part of v1.

### 6.3 `session.close`

`session.close{code,message?}` is terminal. `code` is from §9.1 (including
`rekey`); `message` ≤ 512 UTF-8 bytes. It stops all streams/calls on that sid;
the PC aborts/returns iterators, discards session state and keys; the phone
treats in-flight outcomes per §7. A `session.close` received before `peer.hello`
is a valid abort and is processed. No frame may follow a close on that sid.

## 7. `workspace/1` endpoints and retry classes

`spec/pclink/v1/endpoints.json` is normative for the endpoint inventory. It
lists every DSH endpoint the current phone UI calls, with `kind`
(`unary`/`stream`), `retry` (`read`/`idempotent`/`unsafe`) and `phoneOnly`.
The list is for version compatibility and retry classification only: **PCLink
v1 has no endpoint allowlist**. The PC plugin forwards every DSH endpoint the
owner Peer can dispatch, including settings and plugin management. The one
exception is the `pclink.admin/` prefix: a remote `rpc.call`/`rpc.stream.open`
for an endpoint whose name starts with `pclink.admin/` is answered with the
PCLink `forbidden` error object (§6.1) and is never forwarded. The
authoritative `/api/pclink.admin/*` gate is the source Peer, not the prefix
(§6.1/§8.2). DSH endpoint dispatch itself uses exact, case-sensitive
namespace/method strings and does no case folding or alias resolution; PCLink
does not add any either. That is a prohibition on remote administration
of PCLink itself, not a general endpoint allowlist. An endpoint not in the
list is treated as `unsafe` for retry purposes but is still forwarded (the DSH
method/version decides availability). `phoneOnly:true`
endpoints (`phone/*`) do not exist on the PC; the PC UI hides them and the PC
DSH answers `gateway/method-unavailable`/`lookup-not-found`, which the phone
shows as an unavailable feature.

| Class | After the reply is lost (disconnect, close, timeout) |
| --- | --- |
| `read` | Retry automatically on a new session, with fresh correlation ids and the current cursor/arguments. |
| `idempotent` | Retry with byte-identical DSH arguments and the same DSH idempotency key (`session/prompt` uses `request.requestId`; DSH `commands.ts` deduplicates it). A new PCLink `id` is allowed because it is only transport correlation. |
| `unsafe` | Do not resend. Surface `unknown_outcome`; the UI re-reads state/projections (`session/projections`, `workspace/follow`, `goals/get`, `job/list`, etc.) before offering a new action. |

The phone MUST NOT downgrade an `unsafe` action to a blind retry, and the PC
plugin MUST NOT deduplicate or replay on its own. The relay never queues and
the plugin never stores request results; idempotency is DSH's.

Two DSH 0.2.2-rc.1 argument shapes are called out because the current iOS App
is behind the pin (fixed by the D-stage PR; this contract does not normalize):

- `session/list` args MUST be `{"_request":{}}` (the reserved required
  parameter), not `{}`.
- `session/follow` args MUST contain `request.assistantStream` only as literal
  `true` or omit it; `false` fails DSH boundary validation.

The PC plugin passes `args`/`payload` through unchanged. The PCLink endpoint
inventory and its `sources` record the current call sites; the change record
lists the D-stage fixes.

## 8. Local admin plane (CLI and Web UI)

### 8.1 Files and identity

The PC plugin owns `$DSH_HOME/pclink/` (directory 0700):

- `identity.key` — raw 32-byte Ed25519 seed, 0600, never printed, copied or
  logged.
- `pairs.json` — `{"v":1,"pcMachineId":"...","pairs":[record...]}`, 0600, max
  1024 records, atomic replace.
- `pairs.log` — append-only NDJSON audit/tombstone log, 0600 (§4.6).
- `admin.json` — `{"v":1,"port":49152-65535,"token":"<32B b64url>"}`, 0600,
  replaced atomically on every plugin start. The token is 32 random bytes and
  is never logged, echoed, sent to the browser or included in a URL.

A stale `admin.json` from a crashed process is reported as "plugin not running";
the CLI never guesses a port. A stale port reused by another local user is not
trusted either: the CLI first runs an **HMAC server-proof challenge** and only
sends the Bearer token after the server proves it knows the token
(`POST /v1/challenge`, §8.2). This fixes the review L6 stale-port takeover
without exposing the token to an impostor. The plugin binds its admin server to
`127.0.0.1` only (no `0.0.0.0`, no IPv6 wildcard, no TLS needed on loopback).
The server MUST verify:

- `Host` is exactly `127.0.0.1:<the port it bound>`; any other `Host`, a
  missing `Host`, a DNS name, a different port or an IPv6 literal is rejected
  with 400 and no body.
- The request has **no** `Origin` header (any `Origin`, including `null`, is
  rejected with 403). There is no CORS and no `Access-Control-Allow-*`.
- Every `POST` has `Content-Type: application/json` (with optional
  `; charset=utf-8`); anything else is 415.
- The admin token is checked with a constant-time comparison; the server
  accepts only `Authorization: Bearer <token>`, no cookies, no query token.
  `/v1/challenge` is the only route allowed without the Bearer header.

Requests are UTF-8 JSON ≤ 64 KiB; responses are JSON ≤ 256 KiB; every response
is `Cache-Control: no-store`. The admin server works while the relay is offline;
pairing operations fail with `unavailable` until the relay is connected. A
non-loopback bind, a missing `Host`, or a browser-originated request is a
protocol error, never silently accepted.

### 8.2 Admin JSON API

All routes are `POST` except status; requests and responses are JSON objects.
The local `/v1/*` carrier is the CLI boundary; the Web UI uses the DSH
`/api/pclink.admin/*` owner routes below with the same bodies.

| Operation | Request | Success response |
| --- | --- | --- |
| `POST /v1/challenge` | `{nonce:"<32B b64url>"}` | `{v:1,nonce,proof:"<32B b64url HMAC>"}`; no Bearer |
| `GET /v1/status` | — | `{v:1,plugin:{version,packageSha256},identity:{machineId,publicKey,name},relay:{origin,state},pairs:[{peerMachineId,peerName,pairedAt,approvedAt,approvedVia,online,usable,reason?}],warnings:[...],pairing?:{id,state,mode,qrURI?,manualCode?,expiresAt,peerName?,peerMachineId?,peerFingerprint?,error?}}`; the pending peer fields are constrained by state (§ below) |
| `POST /v1/pair` | `{mode?:"qr"\|"manual",relay?,name?}` | `{v:1,pairing:{id,mode,relayOrigin,qrURI?,manualCode?,expiresAt}}` |
| `POST /v1/pair/approve` | `{pairingId,fingerprint}` | **Deprecated compatibility route, no v1.6 PC path.** A v1.6 PC never enters `awaiting_approval`, so it answers `unavailable` ("pairing is not awaiting approval"). Kept so a pre-v1.6 CLI/Web UI can talk to a v1.6 PC without a 404; its old fingerprint semantics remain documented only for a pre-v1.6 PC. |
| `POST /v1/pair/cancel` | `{pairingId,rejected?:true}` | `{v:1,cancelled:true}` |
| `POST /v1/unpair` | `{peerMachineId?}` or `{all:true}` | `{v:1,removed:[...]}` |
| `POST /v1/rotate-identity` | `{confirm:"rotate-identity"}` | `{v:1,rotated:true,oldMachineId,newMachineId}` |

The challenge proof is `HMAC-SHA256(token, "pclink-v1/admin-proof" || 0x00 ||
nonce_raw)`. The CLI verifies it in constant time; a missing/mismatched proof
means "plugin not running" and the CLI exits without sending the token.

`pairing.state` is `opening`, `waiting`, `joined`, `completed` or `failed` on a
v1.6 PC. `awaiting_approval` is retained only for a pre-v1.6 PC that still
requires compare-the-phone; a v1.6 PC MUST NOT expose it. `mode` is `qr` or
`manual`. `qrURI` appears only in `qr` mode while waiting; `manualCode` (the
formatted `XXXX-XXXX-XXXX-XXXX`) appears only in `manual` mode while waiting;
`sas` does not exist. `error` is a §9.1 code. `relay.state` is
`connected|connecting|offline`. `online` means an established E2E session that
has not hit the 15-minute idle timeout (§5.5). `usable` is false for an
unapproved/revoked record (§4.6) with the reason; the Web UI shows a warning
banner for each.

`plugin` is the build identity of the **running** plugin process: `version`
from the installed package manifest and `packageSha256`, the §8.3 deterministic
digest over the package files this process loaded. Both are captured at
process start; a later `dsh plugin add` changes the files on disk but not this
value, which is what lets the installer detect that a restart is required. The
field is required in a v1.6 status response. A pre-v1.6 plugin omits it; a
consumer in the upgrade window MUST treat the absence as an untracked old build
(and restart), never as a status failure.

**Pending-peer redaction (review High-1, retained).** While `pairing.state` is
`opening`/`waiting`/`joined` (and equally in the legacy `awaiting_approval`),
the `GET /v1/status` response and the Web UI `/api/pclink.admin/status` body
MUST NOT contain `peerMachineId`, `peerPublicKey`, `peerFingerprint` or any
other field from which the pending phone's machineId/fingerprint can be
derived. Only the verified `peerName` is exposed so the operator can see which
phone joined. After the record is durably written (`completed`),
`peerMachineId` and `peerFingerprint` MAY appear; they also appear in `pairs`.
The canonical fingerprint display is `machineId[0:12]` as `xxxx-xxxx-xxxx`. The
schema is `schema/admin-status.schema.json`; its samples include the
forbidden-field negative.

`POST /v1/pair` starts exactly one pairing (one slot: S for `qr`, C for
`manual`) and returns immediately. A second pair request while one is active
is `unavailable` ("pairing already in progress"); cancel first. When a phone
joins and its `pair.auth` verifies, the plugin moves to `joined`, records
`approvedAt`/`approvedVia` (`qr`/`manual`), sends `pair.confirm` automatically
and exposes only the phone name until `pair.final` completes the durable write
(§4.4/§4.6). It MUST NOT wait for a local approval, MUST NOT enter
`awaiting_approval`, and there is no 120 s approval timeout; the 300 s slot
expiry bounds the whole exchange. `POST /v1/pair/approve` is retained as a
deprecated compatibility route: on a v1.6 PC it returns `unavailable` because
no pairing is ever `awaiting_approval`; it does not destroy the slot. A
`pair/cancel` with `rejected:true` sends `relay.pair.close{reason:"rejected"}`;
without it, `cancelled`. There is no SAS failure path.

`POST /v1/unpair` aborts handshakes, closes sessions, appends the tombstone and
removes the record(s) per §4.6; `removed` is the list of machineIds. If the
tombstone append fails it reports the error and the plugin stays disconnected
from the relay until a retry succeeds. A stolen/lost phone is handled by
revoking all pairings and then rotating the PC identity; the UI states that
sequence. `POST /v1/rotate-identity` requires the literal confirmation, writes a
new `identity.key`, appends a `rotate` line and makes every old record stale;
every phone must re-pair. A phone that is offline when the identity rotates will
keep showing the PC offline; the phone UI uses the long-offline hint in §10,
because the new PC machineId is unknown to it.

For the Web UI plugin page, the plugin registers owner-only DSH routes on its
existing `/api` carrier with the same JSON bodies: `POST /api/pclink.admin/status`,
`/pair`, `/pair/approve`, `/pair/cancel`, `/unpair`, `/rotate-identity` (the
`/api` prefix is the DSH carrier; these six operation names are the complete
PCLink admin surface). `/pair/approve` is retained as the same deprecated
compatibility route as on the loopback carrier. There is no
`/api/pclink.admin/challenge`; that route exists only on the loopback CLI
carrier. The Web UI routes are protected by the
normal DSH browser/API authentication fence and are accepted only from an owner
Peer; the local loopback token is not accepted there. The browser page never
sees `admin.json` or its token and never talks to the loopback admin server
directly. The CLI never uses the DSH browser routes. A remote PCLink
`rpc.call`/`rpc.stream.open` cannot invoke any of these: the forwarder returns
`forbidden` for the `pclink.admin/` prefix before DSH dispatch, and the handler
itself MUST also refuse a request whose source Peer is the PCLink remote Peer
regardless of the endpoint string (§6.1). The page MUST show a persistent banner
for the most recent successful pairing and the warning for unapproved/revoked
records. A remote PCLink call that somehow reaches the handler is refused and
mapped to the PCLink `forbidden`; it never executes an admin operation.

### 8.3 CLI

`npx pclink status`, `pair`, `unpair` and `rotate-identity` read
`$DSH_HOME/pclink/admin.json` (0600), verify the `/v1/challenge` proof, then
send the Bearer token to the loopback admin API. `install` is the plugin-install
path (`dsh plugin --profile web add ...`) and is outside this contract.

- `pclink status` lists every pairing (name, machineId, fingerprint, approval
  timestamp/via, online/usable), the pending pairing state, the running plugin
  `version`/`packageSha256` (or an explicit "legacy/unknown" when a pre-v1.6 PC
  omits `plugin`), and any unapproved/revoked-record warning. `pclink status
  --json` prints the raw admin status body (plus the same absence tolerated),
  which is the install script's build-verification seam. While a pairing is
  pending and not durable it shows only the phone name, never the pending
  machineId/fingerprint/public key.
- `pclink pair` starts `mode:"qr"`, prints the five-minute expiry and the
  full-owner warning, and renders the QR in the terminal when stdout is a
  terminal and a renderer is available; it always prints the complete
  `pclink://` URI so a non-TTY/redirected run (CI, `curl | bash`, a log
  capture) never fails for lack of a TTY. `pclink pair --manual` starts
  `mode:"manual"` and prints the `XXXX-XXXX-XXXX-XXXX` code, expiry and
  warning. Neither mode prompts for or accepts a fingerprint, and neither
  requires a TTY: pairing is completed by the phone's scan/code entry alone.
  Both poll status until `completed`/`failed` or the five-minute deadline. A
  single admin request timeout or connection failure is retried within the
  deadline (the plugin may be busy while `dsh web` restarts); only a terminal
  pairing state or a non-retryable error ends the command. On completion the
  CLI prints `配对完成：<phone name>（<fingerprint>）` and the exact revoke
  command (`pclink unpair <machineId>` or `pclink unpair --all`). The CLI never
  prints a SAS.
- `pclink unpair` with no argument lists every pairing, requires a TTY
  confirmation and revokes all (or the selected machineId), then prints the
  result. For a stolen/lost phone it directs the user to revoke all and then
  run `rotate-identity`. It reports a tombstone/storage failure and leaves the
  plugin fail-closed rather than claiming success.
- `pclink rotate-identity` requires a TTY confirmation phrase and prints that
  every phone must re-pair and that an offline phone will keep showing the PC
  offline until manually unpaired; it is not offered as a silent background
  action.

Every command reports the PCLink error code and a human message; it never
rewrites an `auth_failed`/`unpaired` into a DSH 401/403. The destructive
commands (`unpair`, `rotate-identity`) keep their TTY confirmation; the
fingerprint comparison is no longer a pairing step, so pairing itself has no
TTY requirement and no human-process approval claim. A same-user process that
can call the admin API directly remains outside the boundary (§1 non-goal 7).

## 9. Error codes

### 9.1 PCLink codes

These codes are the PCLink error vocabulary. `relay.error`,
`session.close` and `session.reject` each use a schema-defined subset; some
entries are client-side outcomes rather than on-wire codes (`unknown_outcome`,
and `peer_offline` when the relay has sent `relay.offline`). A DSH endpoint
error carried in `rpc.result.error.code`/`rpc.stream.error.error.code` is a
**different namespace** and is passed through unchanged. The single exception
is `forbidden`, which is a PCLink code produced by the plugin; it is the only
PCLink code allowed in those two error objects (there is no DSH
`gateway/forbidden` alias for it).

| Code | Plane / producer | Meaning | Client behaviour / retry |
| --- | --- | --- | --- |
| `unavailable` | relay, PC, phone | method/feature/local dependency unavailable; no specific code fits | show feature unavailable; a read/idempotent call may retry after reconnect; an unsafe call is `unknown_outcome` |
| `unknown_outcome` | phone transport (local outcome, not a wire code) | an unsafe call/stream may have executed but no definitive reply arrived | do not resend; re-read state/projections; show "may have happened" |
| `peer_offline` | relay (`relay.offline` frame) / client | target not connected; the frame was not delivered | show PC offline; retry read/idempotent after reconnect; unsafe was not delivered |
| `unpaired` | PC, phone | no local pairing record, revoked, or stale identity | a **verified signed** reject/authenticated close shows "电脑已解除与此手机的配对" and waits for the user's explicit confirmation before deleting the phone record; an unauthenticated reject or `auth_failed` never deletes; never auto-pair |
| `auth_failed` | relay, PC, phone | signature/MAC/QR key mismatch, all-zero DH, auth timeout | stop; show authentication failed; do **not** auto-delete the record or auto-re-pair; the user may retry |
| `replaced` | relay | a newer connection for this machineId replaced this one | no immediate reconnect; wait ≥30 s with jitter; user may act |
| `session_expired` | PC, relay | sid closed/expired, phone relay idle, PC 15-minute E2E idle, or 2^20-frame/2 GiB hard cap | establish a new sid; retry per endpoint class |
| `replay` | PC, phone | `seq` not increasing, reused sid, replayed/cross-session handshake | close the session; do not retry the same frame; security event |
| `bad_frame` | any | malformed wire JSON, unknown member of a PCLink object/type/**PCLink code**, wrong direction, duplicate id in flight | close the affected session/connection; do not retry blindly |
| `frame_too_large` | relay, PC, phone | >16 MiB outer frame or >8 MiB plaintext value; oversized handshake/args | terminate that stream/call; UI shows the limit; no retry of the same payload |
| `rate_limited` | relay, PC | connection/pair/daily/handshake limit | wait `retryAfterMs`; read/idempotent may retry; unsafe is `unknown_outcome` only if it was sent |
| `version_unsupported` | PC, phone | no PCLink/suite caps intersection, bad suite, unknown record mode | stop; show upgrade/re-pair; no retry |
| `rendezvous_expired` | relay | pairing slot absent or >300 s | show code expired; generate a new code |
| `rendezvous_exhausted` | relay | slot already matched, or >10 join attempts | show code exhausted; generate a new code |
| `rekey` | phone, PC | planned session rotation at 2^19 frames or 1 GiB (soft threshold) | establish the new session; old outcomes follow §7; not an error |
| `forbidden` | PC plugin | a remote `rpc.call`/`rpc.stream.open` named a `pclink.admin/` endpoint, or a remote Peer reached an `/api/pclink.admin/*` handler | do not retry; PCLink code (not a DSH code); this is a prohibited remote admin call, not an endpoint allowlist |

`unknown_outcome` is produced only by the phone transport, never by the relay
or PC, and is not a `session.close`/`relay.error` wire code. `peer_offline` is
the client's name for an observed `relay.offline`; the relay does not send
`relay.error{code:"peer_offline"}`. **One mapping for an unknown PCLink code**
(review L3): an unknown code in `relay.error`, `session.close` or
`session.reject` is `bad_frame`; the frame is rejected/closed and never treated
as a new meaning. There is no second `unavailable` mapping for the same case.
An unknown **DSH** code in `rpc.result`/`rpc.stream.error` is a different
namespace: it is passed through/displayed as `unavailable` with the original
message preserved and does not close the PCLink session. `forbidden` is a
PCLink code produced by the plugin, not a relay/close code; it is not an alias
for `unavailable` or `bad_frame` (it names a deliberate remote-admin
prohibition). The `message` member of an error or close is PCLink display text,
not a DSH passthrough (§2.3); it keeps its byte cap and MUST NOT be used to
smuggle a DSH result/value that belongs in `result`, `value` or chunk data.

### 9.2 Relay authentication vs direct `DSHWebTransport`

The relay path has no cookie, launch token, `Host`/`Origin` fence or HTTP 401/403
semantics. `DSHWebTransport`'s 401/cookie re-exchange and 403/Host/Origin logic
are direct-loopback implementation details and MUST NOT be reused by the PCLink
transport. A relay `auth_failed`/`unpaired`/`replaced` is a pairing/connection
state, not a token refresh. A DSH endpoint can still return its own error code
(e.g. `gateway/method-unavailable`) through `rpc.result`; that is content, not
transport authentication. If the in-process DSH handler unexpectedly returns
HTTP 401/403, the plugin answers `rpc.result{ok:false,
error:{code:"unavailable",message:"in-process authentication failure"}}`; it
does not prompt for a DSH cookie.

## 10. Reconnect, heartbeat and recovery

- Relay heartbeat: 25 s ± 5 s jitter, two missed pongs close (§3.4).
- Phone relay idle: 10 minutes without business traffic; the relay closes with
  `session_expired`; the phone reconnects on demand.
- PC E2E idle: 15 minutes without any `e2e` frame for that sid; the PC closes
  the logical session with `session_expired`, discards keys and sets
  `status.online=false` (§5.5). The PC cannot observe the phone's relay
  disconnect; it uses this timeout and the frame itself.
- Reconnect backoff (phone and PC): attempts at 0.5 s, 1 s, 2 s, 4 s, 8 s, 16 s,
  30 s, then 30 s; each delay has ±20 % jitter; reset after 60 s of successful
  connection. The backoff is not a substitute for authentication; every new
  relay connection runs `relay.challenge`/`peer.auth` again. A phone-initiated
  resume (the phone returns to the foreground and replaces a possibly suspended
  socket, or the user retries from the connection screen) is not a failed
  attempt: the next delay is at most the second step (1 s ±20 %) instead of
  inheriting the failure streak, and a backoff wait already in flight when the
  resume arrives is cut short. The 60 s reset rule keeps applying to failures,
  and the cap never skips authentication or shortens the `replaced` minimum
  wait of 30 s (§9.1).
- `connecting` and `offline` are distinct phone states (v1.6 clarification,
  PC-20261110-pclink-foreground-resume-presence). `connecting` means the phone
  is dialing or handshaking, including the bounded resume above; `offline`
  means one dial already failed, or the connection dropped without a
  phone-initiated resume. While `connecting`, the phone MUST NOT present
  `电脑离线`; it presents its connecting copy instead.
- Every relay reconnect requires a new end-to-end handshake with a new `sid`,
  new ephemeral X25519 keys and a new `th2` salt; old keys are discarded. The
  relay restart loses allowlists/rendezvous/daily counters; the PC reconnects,
  re-sends `relay.allow`, and the phone reconnects with backoff.
- Stream recovery: `session/follow` reopens and uses its snapshot `cursor`; if
  the snapshot does not cover the last delivered durable event `seq`, the phone
  extends backwards with `session/page` (`throughSeq` = snapshot cursor,
  `beforeSeq` = current first record, `maxMessages` per page) until covered, and
  deduplicates by event `seq`. `workspace/follow` reopens and replaces the local
  baseline (there is no cursor). `$events` reopens before any prompt; the phone
  uses the new `ready.clientId` and never reuses the old one. `job/list`
  reopens and re-reads. A stream that cannot be recovered is shown as an error
  and the affected UI is re-read, never left stale.
- In-flight unary calls follow §7. A definitive `rpc.result` received before the
  close wins; otherwise `read` retries, `idempotent` retries with identical DSH
  arguments, `unsafe` becomes `unknown_outcome`.
- The phone never falls back from the PC backend to the phone backend because
  the PC is offline; it shows "电脑离线" and a retry. The user chooses the
  backend explicitly (P18 key ruling in the change record). The offline copy is
  required once a dial has failed or the connection dropped without a
  phone-initiated resume; during the bounded resume above the phone shows its
  connecting copy instead.
- **Long offline / changed PC identity (review Low-2).** When the phone has
  been unable to reach its paired PC for a long period (10 minutes of failed
  reconnect attempts, or whenever the user opens the connection screen while
  offline), it MUST show exactly: `电脑长时间离线。如果电脑已更换身份或解除配对，请手动解除配对。`
  The phone cannot distinguish a rotated PC identity from an offline PC because
  the new machineId is unknown; it MUST NOT auto-delete the record or auto-pair
  from an offline state. The user removes the stale phone record manually and
  pairs again. This is the recovery path after `rotate-identity` (§4.6,
  §8.3).
- Pending approvals/questions: after a new e2e session, the phone MUST reopen
  `$events` before prompting; DSH may redeliver a pending waterfall. If a
  pending request is not redelivered, the phone shows a re-read/refresh
  affordance rather than claiming it was answered. The PC plugin uses one owner
  Peer per e2e session and disposes it on close; it never answers with another
  Peer.

## 11. Compatibility and versioning

PCLink v1 is the first PCLink wire version; `pclink-v1.6` is the current revised
freeze before any implementation is accepted as conformant. A PCLink
implementation of `pclink-v1.5` exists on `main`, and the user may already have
its pair records on disk; §4.6 states the one-way record compatibility and the
rollback consequence. The unfrozen `pclink-v1` draft is superseded (no
implementation or persisted data exists); a `pclink-v1` draft record without
`approvedAt`/`approvedVia`/`pairs.log` is unapproved and unusable, so a draft
store must re-pair rather than be silently adopted. Future versions MUST use a
new protocol version/capability and an explicit change record; a v1 receiver
rejects `v != 1` (outer) or an unsupported suite/caps with
`version_unsupported`, never downgrades.

The pairing handshake bytes (`pair.hello/auth/confirm/final`), the QR/manual
secrets, the rendezvous, the relay plane and the E2E session bytes are
unchanged by v1.6. What changed is **who approves and when**, the persisted
record's `approvedVia` vocabulary and the admin `plugin` facts:

| Producer → consumer | Behaviour |
| --- | --- |
| old App (waits for `pair.confirm`) → new PC | **Interoperates.** After the phone's `pair.auth` verifies, the new PC sends `pair.confirm` immediately. The old App's "waiting for the PC operator" screen is satisfied as soon as the confirm arrives; the record is written normally. The old App may still display its own fingerprint while waiting — harmless, because the new PC never asks for it. |
| new App → old PC (still compare-the-phone) | **Interoperates, with a PC-side wait.** The new App sends `pair.auth` and waits for the old PC's `pair.confirm`; the old PC CLI still shows its fingerprint prompt. The App's waiting copy must be mode-neutral: "请在电脑上完成确认" (or "如果这台电脑仍要求确认，请在电脑上完成确认"), never instructing the user to read a fingerprint into the PC. If the PC operator never confirms, the old 120 s approval timeout closes the slot and the App reports the failure. |
| new PC → new App | this contract; `pair.confirm` is sent automatically and the App may auto-close on the authenticated confirm. |
| persisted v1.5 records (`approvedVia:"cli"|"webui"`) → new PC | **Usable without rewriting.** The record schema keeps the legacy enum values; `status`/the App show them as a legacy fingerprint-approval origin. New pairings always write `qr`/`manual`. |
| persisted v1.6 records (`approvedVia:"qr"|"manual"`) → rolled-back pre-v1.6 PC | **Fail-closed.** The old build's record validator accepts only `cli`/`webui`, so it treats the new record as unapproved/unusable and the phone must re-pair. Rolling back requires re-pairing; the plugin does not silently rewrite or adopt the new value. |
| persisted v1 → new / rollback (other files) | `identity.key`, `pairs.log` and `admin.json` are unchanged. A stale `pcMachineId`/`phoneMachineId`, a missing/mismatched `pairs.log` line, or a later `unpair` still makes a record unusable and requires re-pair. A build without PCLink ignores the directory. |

An old admin client that calls `/v1/pair/approve` against a new PC gets
`unavailable` because the new PC never enters `awaiting_approval`; it can still
poll `status` and observe `completed`. A new `status` response adds `plugin` and
new `approvedVia` values; an old client that ignores unknown members keeps
working, and a new client reading a pre-v1.6 status tolerates the missing
`plugin` member and the legacy `approvedVia` values.

The DSH API range is separate: `>=0.2.2-rc.1 <0.3.0` is the tested range; an
out-of-range PC is a warning, not a block, and individual endpoint failures are
visible. P14's DSH Remote `client-request`/mux and P06's event semantics are
unchanged: PCLink carries `args`/`payload` and event payloads byte-for-byte and
does not define a second DSH API. The P09 UI contract for the drawer/switch,
pairing page and "connected computer" page lands with the iOS PR; this contract
requires the user-visible obligations in §4.6/§10. The Swift module declaration
in `Package.swift` is a P12 change in the D-stage PR. `P18` owns the
`phone-dsh.drawer.backend` UserDefaults key (values `phone`|`pc`, default
`phone`); its owning-contract entry is added by the D-stage P18 change, not by
this record.

## 12. Shared fixtures, schemas and acceptance

- `golden/pclink-v1-vectors.json` is the shared crypto/fixture document:
  machineIds, relay-auth signatures, the complete handshake transcript
  (version/suite-bound `T_init`, `salt = th2`, separate confirm keys), the
  signed PC reject plus real reject-signature negatives (valid for init A,
  invalid for init B's `th1`; code-swapped), AEAD frames
  (AAD/nonce/ciphertext), canonical JSON (code-point key order, `/` literal,
  non-ASCII, lowercase `\u0000` for `U+0000`), chunking/interleaving, the
  `json_boundary` rows (legal escaped `U+0000` in `rpc.call.args`,
  `rpc.stream.open.payload.args`, `rpc.result.result`,
  `rpc.stream.item.value` and decoded chunk data is accepted and preserved; a
  literal `0x00`, BOM, duplicate member, lone surrogate, non-object root and a
  PCLink `name`/machineId containing `U+0000` are rejected), pairing QR, the
  80-bit/16-character manual
  code and Crockford normalization, the complete keyC manual-mode
  hello/auth/confirm/final MAC set with mutation/wrong-key negatives,
  origin-bound rendezvous (including a different-origin value), pairing
  MACs/records (`approvedVia:"qr"`), 12-character fingerprints with
  case/separator tolerance (display/unpair-target normalization; the former
  wrong-phone-approval negative is now a state-machine sample of automatic
  approval), the auto-approval model rows (`pair.auth` verified → confirm sent,
  both `qr` and `manual`), the paired-notice shape, audit entries, and invalid
  rows. `tools/vectors.mjs --write` regenerates it
  from fixed public labels; `--check` independently re-implements machineId,
  strict wire JSON (literal-NUL/BOM/duplicate/lone-surrogate/non-object-root
  rejection plus escaped-`U+0000` acceptance), canonical JSON, HKDF,
  origin-bound rendezvous, pair MAC, AEAD nonce/AAD/open,
  chunk split/reassembly, QR parse, Crockford decode, fingerprint
  normalization and the auto-approval/record load model. The checker owns its
  own domain/suite/alphabet/PKCS#8 constants, does not call the generator's
  helpers, and counts crypto negatives separately from the explicitly labelled
  state-machine model samples (the output says “状态机模型样例，非密码证据”).
  `sha256(utf8(label))` is the test private key; the labels and public values
  are in the document; no production key is stored.
- `schema/*.schema.json` are the closed shapes, including
  `admin-challenge.schema.json` for the CLI server proof,
  `admin-status.schema.json` for the `/v1/status` response (the required
  `plugin` build facts, `approvedVia` `qr|manual` plus the legacy
  `cli|webui`, and the retained legacy `awaiting_approval` variant that rejects
  `peerMachineId`/`peerPublicKey`/`peerFingerprint`), the `session.reject.sig`
  field, and the split PC/phone record schemas
  (`pairing-record.schema.json` requires `approvedAt`/`approvedVia` and accepts
  `qr`/`manual` plus the legacy values; `phone-pairing-record.schema.json`
  forbids them).
  `golden/schema-samples.json` carries at least one valid and one invalid
  sample per schema, including valid RPC-args and stream-item samples with a
  decoded `U+0000` and an invalid `pclink.notice.name` containing `U+0000`;
  `tools/check_samples.py` validates them with the repository's existing
  JSON-Schema subset validator, additionally enforces the name
  UTF-8/NFC/C0/C1/`Cf` rule, validates `endpoints.json` (unique names,
  stream=read, phone namespace, source files exist), and independently
  re-checks the `json_boundary` rows (raw NUL/BOM/duplicate/lone surrogate/
  non-object root rejection, escaped-`U+0000` preservation, and the PCLink
  field rule).
- `endpoints.json` is the normative endpoint inventory and retry classification.
  Unknown endpoints are `unsafe` for retry but not blocked; `pclink.admin/` is
  the one forbidden remote endpoint prefix (the `/api/pclink.admin/*` handler's
  source-Peer check is authoritative, not the prefix).
- Every end MUST drive its **real** decoder/state machine with the same golden
  document; a test that copies the values or only hashes the file does not
  count. The Node checker is a spec checker, not runtime conformance; B/C/D
  must add cross-end runtime evidence before P28 can change from `target` to
  `implemented`.

Acceptance commands per end (to be run in the implementer's branch; a missing
toolchain is SKIP/INCOMPLETE, never PASS):

```sh
# shared contract (also runs in phone-spec)
node spec/pclink/v1/tools/vectors.mjs --check
python3 spec/pclink/v1/tools/check_samples.py --root .
python3 spec/tools/registry_build.py --root . --check
python3 spec/tools/registry_check.py --root .
python3 spec/tools/schema_diff.py --root . --base "$(git merge-base HEAD origin/main)"
python3 spec/tools/cross_check.py --root .
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree
# phone-p0-conformance is a separate page-ratchet gate; at this revision it
# reports the 7 known GAP-32(d)/GAP-35 divergences.

# B relay
cd relay && npm ci && npm test
node ../spec/pclink/v1/tools/vectors.mjs --check

# C PC plugin + CLI
cd pclink && npm ci && npm test
node ../spec/pclink/v1/tools/vectors.mjs --check
# integration: dsh web + local relay + npx pclink status/pair/unpair + a real
# session/list, session/follow, session/prompt and $events approval

# D iOS
swift test --filter PhoneDSHPCLinkTests
swift build
node spec/pclink/v1/tools/vectors.mjs --check
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-sdk
```

The D-stage App wiring additionally needs the P09 page/source changes and the
P12 `Package.swift` declaration; those are separate changes. Android is out of
scope for v1 and its missing drawer actions are tracked as GAP-35. The P09 page
contract changes for the redesigned pairing page and the "connected computer"
page are part of the same branch (`spec/ui/v1/pages/pc-pairing.json`,
`connected-computer.json`); they do not change any wire byte.

## 13. Decisions frozen for review

These are contract-owner decisions, not implementation choices. A change
follows AGENTS.md §3.3 and the change record's revision log.

1. A plaintext bootstrap carrier `e2e.handshake` is separate from
   `e2e` because the first handshake message cannot be AEAD-encrypted before a
   key exists. It carries no identity key secrets and is covered by signatures
   and transcript hashes.
2. Rekey starts at the **soft** threshold (2^19 frames or 1 GiB); the old
   session closes immediately after the new `peer.hello`; no 30-second drain.
   The **hard** cap (2^20 frames or 2 GiB) closes with `session_expired`.
   Ordered transport plus the §7 retry classes make this safe.
3. No credit frame in v1; pull-based WebSocket backpressure plus the 8 MiB
   value/16 MiB frame caps and cancellation bound memory. A credit frame would
   be new protocol surface. There is no ack frame; "in-flight" is the sender's
   own one-at-a-time production rule.
4. The relay is self-contained: it uses only `node:crypto` and `ws`, and does
   not import the PC plugin's `pclink/core`. This keeps E2E/pairing-secret code
   out of the untrusted deployable and duplicates only the small identity/auth
   primitives, which the shared vectors pin.
5. QR pairing uses a 128-bit secret and pins `k`; manual pairing uses an
   **80-bit** code (16 Crockford characters, `XXXX-XXXX-XXXX-XXXX`), no SAS,
   and is available only in the explicit `manual` mode. The rendezvous hash is
   bound to the relay origin. The relay cannot feasibly guess C or test a MAC
   in the 300 s window; QR is recommended.
6. The relay sees pairing public keys, names and MACs (not S/C), and it sees
   the machineId ↔ public-key mapping. There is no SAS and no identity hiding.
7. The phone identity is a software Keychain Ed25519 key, not a Secure Enclave
   key (Ed25519 is not supported there). A stolen unlocked phone is full owner
   access; the handling is **revoke all pairings, then `rotate-identity`**.
8. DSH versions outside the tested range only warn; individual endpoint errors
   are shown. There is no endpoint allowlist and no silent endpoint filtering;
   `pclink.admin/` is a prohibited remote prefix, not an allowlist. The
   authoritative `/api/pclink.admin/*` check is the request source Peer; the
   prefix test is only a fast path.
9. The PC's `relay.allow` list is a spam filter; the PC validates every frame
   locally. `e2e.handshake` bypasses the allowlist only for the four handshake
   body types, is separately rate-limited, and a PC with no record answers one
   signed `unpaired` reject without caching the sid.
10. The admin token never reaches the browser; the Web UI uses the six
    owner-only DSH `/api/pclink.admin/*` operations and the CLI uses the
    loopback Bearer API plus the `POST /v1/challenge` server proof. Remote
    PCLink `rpc.*` calls for `pclink.admin/` are the PCLink `forbidden` code;
    the handler also refuses a PCLink remote source Peer regardless of the
    endpoint string.
11. Pairing approval is possession of the one-time screen secret (v1.6 user
    decision): after the verified `pair.auth`, the PC approves automatically
    for both QR and manual, records `approvedVia:"qr"|"manual"` and sends
    `pair.confirm`; there is no compare-the-phone step, no fingerprint TTY
    prompt and no `awaiting_approval` on a v1.6 PC. A pre-v1.6 PC may still
    require compare-the-phone; a new App's waiting copy stays mode-neutral. The
    accepted residual risk is a screen observer joining first; mitigations are
    the single-use 300 s slot, the first-join lock, the terminal/status
    `已配对：<name>（<fingerprint>）` readout with the revoke command, the
    `pairs.log` approval mode/hash, the other-phone `pclink.notice`, and the
    App's verification fields. `pairs.log` is an append-only approval/tombstone
    log; an unlogged record is unusable.
12. Both ends generate fresh ephemeral X25519 keys per handshake, reject
    all-zero/low-order DH, derive traffic keys with `salt = th2`, and derive
    `k_confirm_phone`/`k_confirm_pc` separately from the traffic keys. `T_init`
    binds the protocol version and suite.
13. A PC `session.reject` for `unpaired`/`auth_failed` carries an Ed25519
    signature over `th1` and the code; the phone verifies it with the pinned PC
    key and still asks the user before deleting a record. An unauthenticated
    reject only fails that handshake. `auth_failed` never auto-deletes or
    auto-repairs.
14. PC-side unpair writes a durable tombstone line before removing the record;
    the record is dead on load even if removal fails. If the tombstone write
    fails, the plugin stays off the relay (fail-closed) rather than claiming
    success. The PC's E2E idle timeout is 15 minutes; `status.online` follows
    that state, not an observation of the phone's socket.
15. Before a pairing record is durable, `/v1/status` and
    `/api/pclink.admin/status` do not expose the pending peer's machineId,
    public key or fingerprint; only the verified name is shown. A v1.6 PC
    normally moves from `joined` to `completed` within one round trip, so this
    window is short; the legacy `awaiting_approval` state keeps the same rule.
    The phone that has been offline for a long time shows the manual-unpair
    hint after an identity change, because it cannot detect the new PC identity.
16. The §2.3 strict JSON rule applies to wire bytes, not to decoded DSH values.
    A literal `0x00`, BOM, duplicate member, lone surrogate and non-object root
    are rejected; a legal `\u0000` escape in a DSH passthrough value is
    accepted and preserved. PCLink-owned fields keep their own rules, and the
    relay/`e2e.handshake` outer carriers contain no DSH passthrough value, so a
    relay may keep rejecting every NUL in outer frames. This is the adopted C
    implementer CCR (`pclink-v1.3`); no handshake or AEAD byte changes.
17. The admin status `plugin.version`/`plugin.packageSha256` describe the
    running process, captured at start, not the files currently on disk. The
    installer compares them with the post-`dsh plugin add` on-disk build and
    requires a verified restart when they differ; an absent `plugin` member
    means a pre-v1.6 build and is treated as "restart required if a plugin was
    running", never as an up-to-date result. This is what fixes the
    upgrade-without-restart bug.

## 14. Fixture and file map

| Path | Role |
| --- | --- |
| `README.md` | this normative contract |
| `endpoints.json` | normative `workspace/1` inventory and retry classes |
| `schema/*.schema.json` | closed relay/inner/handshake/pairing/admin shapes (including `admin-challenge.schema.json` and `admin-status.schema.json`) |
| `golden/pclink-v1-vectors.json` | shared crypto, pairing and JSON wire-boundary vectors (valid + invalid), `pclink-v1.6` |
| `golden/schema-samples.json` | valid/invalid sample per schema |
| `tools/vectors.mjs` | Node 24 generator + independent checker (no npm dependencies) |
| `tools/check_samples.py` | existing-validator schema/inventory checker plus the name byte/NFC/`Cf` rule and the `json_boundary` wire/field rows |
