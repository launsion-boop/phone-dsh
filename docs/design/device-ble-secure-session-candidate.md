# Candidate: authenticated BLE device-task session

Status: **working security-design draft; not a frozen contract, not authority to
implement or enable task grants**. Based on repository CCR
`PC-20261107-ble-session-binding-ccr.md`, reviewed against its recorded
physical and simulator evidence and sources on 2026-11-07. The currently
registered task profile remains target and disabled. All proposed identifiers,
messages, limits and provisioning steps below require contract-owner review,
shared fixtures, compatibility decisions and independent security review.

Protocol impact: P07; P09 — candidate task authorization and presentation only; no behavior or feature enablement is approved.

## 1. Goal, threat boundary and non-goals

A phone may receive a task from a device and send acceptance/result/receipt only
inside a session authenticated to a previously and independently enrolled
phone/device key pair. An air-side active peer that does not own either enrolled
private key must be unable to substitute task bytes, result bytes or peer keys,
read protected traffic, or downgrade to plaintext task access. Expiry, replay,
lost-response and crash semantics must not authorize automatic re-execution.

This does not prove physical proximity. A transparent radio relay between the
correct endpoints remains possible, including after initial enrollment; TLS
endpoint authentication is not distance bounding. Availability against radio
jamming is not promised. A compromised phone, trusted provisioning host, or
physical extraction of an exportable unprotected device key is outside this
candidate's cryptographic claim. Device at-rest protection must be separately
selected and honestly displayed; the present reference implementation's NVS
private blob must not be described as hardware-protected.

## 2. Bootstrap and independent confirmation — concrete candidate

The present ESP32 reference board has no independently trusted display. A
physical bootstrap is therefore a **prerequisite**, not an implicit BLE TOFU.
This candidate chooses **offline entry**: the phone receives the fingerprint
from the operator, not a radio proof, and no CoreBluetooth connection or owner
generation is assumed to exist while the fingerprint is entered. A future
connection must separately prove possession of the matching key. Do not mix
this process with the existing connected legacy fingerprint-confirmation UI.

1. A dedicated, explicit local enrollment mode is entered by the physical
   operator. On a locally trusted USB-connected host/serial console, show the
   complete fingerprint of the reference board's existing P-256 device public
   key. The operator must know which physical board and trusted host/USB path
   they are using. A device name, BLE address, advertisement, unauthenticated
   packet or value displayed solely by the phone is not independent evidence.
2. The phone displays the complete fingerprint of its own generated P-256
   public key locally. Through the same trusted physical host/console the
   operator provides the full phone fingerprint to the board and confirms the
   board's readback. On the phone, the operator supplies/compares the board
   fingerprint obtained over the trusted wired channel, not one learned from
   the radio. Manual entry must compare the entire value; grouping for display
   must not silently truncate or map distinct byte sequences to one value.
3. Each side first records the other's independently confirmed fingerprint as
   **staged**, with a matching enrollment transaction and both key identities;
   staged is not an authorized pairing. Each side may later durably record its
   own local commitment only after the explicit per-side checks below. The two
   devices do not share an atomic commit. An interrupted, ambiguous or failed
   enrollment remains unauthorized; a local persisted pin alone cannot grant
   tasks. The first CoC/TLS attempt presents both
   certificates and confirms possession of the enrolled private keys; only
   then is the pair eligible for a separate explicit task grant. The offline
   entry and durable commit use their own local enrollment revision, not a
   fictional BLE generation. In a later connected session, asynchronous proof,
   session establishment and grant publication must each be tied to the current
   local connection owner, enrollment revision and peer key, not merely a BLE
   UUID. A disconnect or replacement invalidates those connected operations.
4. Enrollment commands, physical confirmation, permission to overwrite a
   pairing, user interaction, implementation and secure operation of the USB
   host have **not** been selected or tested. If the host/console path cannot
   be trusted, or no explicit physical confirmation can be obtained, the
   reference board must stay unpaired and tasks unavailable. A QR/display/OOB
   alternative requires equivalent independent provenance and its own design.

The trusted host, its software, cable, board firmware and the operator's
identification of the intended physical board are explicit assumptions. A
serial port alone does not authenticate a physical board. Unexpected or repeated
enrollment commands, replayed confirmations, concurrent enrollment and a
disconnect/replug during staging must fail closed without committing a new
binding; a candidate ceremony needs a fresh local enrollment challenge,
physical authorization and atomic commit/readback. Challenge encoding,
durable ordering and what the operator independently observes remain undecided.
These protections cannot rescue a malicious trusted provisioning host or
compromised board firmware.

### Candidate staged/committed crash and partial-commit policy

There is no distributed atomic write or final acknowledgment guaranteed to
reach both devices. The transaction may fail after either device writes staged
data, after one local commit, or after both local writes but before a final
confirmation is received. Neither a local `committed` bit nor a sent final
acknowledgment proves that the other side durably committed, received the
acknowledgment, or considers the enrollment complete. The protocol must not
claim atomic cross-device persistence or solve this by assuming a timeout is
success.

Candidate local records are `staged` and `committed`, each binding a fresh
enrollment transaction identifier to the exact local and peer fingerprints,
the locally confirmed operator action and a local storage revision. A staged
record only permits a bounded, mutually authenticated **enrollment-control**
exchange against that staged key; it does not grant task access or expose
task/receipt data. The individual record write/commit, malformed data and
readback failure must itself be fail-closed; its actual storage encoding and
atomicity remain to be frozen for both ends.

Each side's `committed` means only its own checked durable local commit. A
task session additionally requires a fresh protected readiness exchange in
which each non-compromised endpoint reports its *own* committed state, the
same enrollment transaction and both key fingerprints, and verifies the
other endpoint's matching report before its local task-admission point. This
is application evidence of matching local facts, not proof of global atomic
commit, physical presence, or what the other endpoint will retain after a
later failure. The board must check its own current committed record and
authorized phone key before each task effect; the phone separately checks its
own record, current owner and foreground grant. A staged, missing, unreadable,
corrupt, changed or different-transaction record on either side rejects task
admission without promoting, replaying or deleting anything.

If reset, link loss or power failure occurs before each side has locally
recorded the required user confirmation and its terminal local commit, or if
either side cannot establish whether its final confirmation was completed,
both sides remain task-ineligible for that transaction. On recovery, preserved
staged/partially committed records are **not automatically committed** from a
peer claim or from reconnect; require a new explicit trusted physical
reconciliation/reconfirmation ceremony before either may be promoted. If both
sides can establish their own previously completed local commit after a later
restart, they still need a fresh authenticated matching-record readiness check
and fresh phone foreground grant; reboot does not resume an old session. A
lost final acknowledgment by itself is not sufficient proof for either side.
Exact markers, transitions, when the final confirmation is deemed complete,
and how hardware/storage can reliably distinguish them are unresolved and
must be proven before freeze. Under arbitrary crashes this conservative policy
can sacrifice availability; it does not promise an atomic two-party decision.

Whether a previously valid pairing remains usable while another pairing is
staged is a **separate, unresolved compatibility/security decision**. Do not
silently revoke it, restore it or assume it survives an attempted replacement.
If a future decision preserves an old pair during unrelated new enrollment,
it needs isolated records, independent revocation/rollback semantics and tests;
an attempted key replacement/revocation with ambiguous commit must never
reactivate an old authority by default.

Candidate fingerprint: SHA-256 of exactly a validated 65-byte uncompressed
SEC1 P-256 public point, including the `0x04` prefix. The existing device label
`ble:` plus lowercase 64 hex digits can name the *device key* after validation;
phone-key namespace and any wire representation are not selected. A prefix,
UUID, fingerprint-only `UserDefaults` entry, or transient certificate label
must never be silently accepted as this two-sided enrollment. Check curve,
point encoding and on-curve validity, length and algorithm before hashing.
Whether migrating the existing P-256 key into a stronger device key store is
possible must be decided without silently regenerating a lost/corrupt key.

The reference firmware currently exports its generated private key to a 32-byte
NVS blob (`pdsh_identity.c`). The iOS feasibility runs used exportable
software Keychain keys and, for Mbed TLS, a private copy in process memory.
Neither proves non-exportability, protected flash, reboot/lock recovery or a
production threat posture. Choose one approved device storage/boot policy and
one phone signing/Keychain accessibility policy; audit PSA and temporary
buffer lifetime and erase on a best-effort basis without promising complete
zeroization. No fuse, Keychain, board or signing operation is authorized by
this draft.

Current `pdsh_identity.c` generates a new identity on `NVS_NOT_FOUND`.
The candidate rule that a lost enrolled key must not regenerate silently is
a **future requirement**, not existing behavior. The system needs an
authoritative and crash-safe distinction between genuinely first install,
interrupted initialization, missing/corrupt storage and previously enrolled
key loss. A board restore/rollback can erase or restore ordinary NVS markers;
without a trusted anti-rollback anchor there is no basis to assert protection
against physical rollback. Freeze a supported mechanism or explicitly narrow
the claim; do not infer first-install from `NVS_NOT_FOUND` or enable tasks after
an ambiguous restore. Do not alter hardware fuses in pursuit of this draft.

## 3. Session, connection ownership, and permission

* Candidate transport: TLS 1.3, mutually authenticated, over native LE L2CAP
  credit-based channel. iPhone is TLS client; ESP32 is TLS server. The PSM is
  read afresh for the current OS connection and is untrusted routing data,
  not authorization. Unexpected/stale callbacks and lost ownership follow
  the existing iOS connection/closing rules. An indistinguishable OS event
  cannot be proven fresh with a fabricated local token.
* Candidate initial authentication is **full handshake only**: disable 0-RTT,
  PSK-only authentication and TLS resumption/tickets until a separately
  frozen design binds them to current peer pins, trust revision and revocation.
  Each side gates its own actions on its own completed handshake and peer-pin
  verification. The client must not infer that the server has completed its
  client authentication merely from its own handshake returning; the
  post-handshake readiness candidate below provides a protected confirmation.
  Unknown versions, unsupported profile or mismatched keys fail closed. No
  fallback to task RPC over the old plaintext Link path is permitted.
* Certificate representation is an unresolved design choice, not equivalent
  to either MAC address or DNS identity. A candidate pin-based deployment
  could verify each leaf's validated P-256 public point against the independently
  enrolled key, while TLS CertificateVerify proves possession. A CA/hostname
  policy is a different option and needs its own reference-identity rules.
  Exact certificate type, allowed critical extensions, key usage/EKU, chain
  length and bytes, signature algorithms, expiration and no-clock policy must
  be specified. Never turn all certificate validation errors off to cope with
  a clockless board. Exception handling for a deliberately self-signed pinned
  key and omitted validity dates needs explicit security review; a test that
  clears date flags is not a production certificate policy.
* One local grant belongs to the authenticated key pair and current local
  connection/owner and foreground lifetime. The device must authorize the
  enrolled phone key as well as the phone authorizing the device; successful
  TLS or pairing alone does not imply authority to run a task. Phone foreground
  is a **phone-local** condition: the board cannot independently observe the
  phone OS foreground state. The board separately enforces its own durable
  paired-key authorization and any device-side policy before every effect.
  If the future application needs the board to receive a phone foreground or
  grant declaration, that must be an authenticated, protected non-task control
  message with explicit loss/revocation semantics; it is a peer assertion, not
  independent evidence of the phone's OS state. On connection
  loss, permission revocation, forgetting, device key change, manager-off,
  malformed stream, cryptographic/authentication failure, owner replacement
  or deadline, reject new operations, stop delivery and close the session.
  Do not reuse old intents or old in-flight callbacks on a new connection.
  Late local callback handling must use revision checks without asserting that
  CoreBluetooth supplies an application token. Session encryption and the
  local owner link do not prove that BLE and PSM advertisements are authentic.
* Fresh handshake and explicit grant are required after reconnect. Invalid or
  unauthenticated peers must not gain access to task information, including
  results/receipts, from the ordinary Link service. Ordinary Link keeps its
  separate user authorization and must not be silently upgraded or disabled
  merely because task authorization failed; actual transport failures still
  use its existing fail-closed lifecycle.

A protocol identifier/version and an application protocol binding (e.g. an
ALPN or another cryptographically bound profile context) are not selected.
They require an explicit domain/versioning and cross-protocol decision; this
draft does not add a wire field or assume a lab test supplies this property.

### Candidate post-handshake readiness, not a frozen message

The phone first completes its **local** TLS client handshake, validates the
server's enrolled key and rechecks its own owner and enrollment revision. It
then sends a bounded `READY_REQUEST` control message containing a fresh
cryptographically random client challenge. It does not send task data yet.
The ESP32 independently runs its **local** server handshake to successful
completion, verifies the client's Finished and required certificate
authentication/pin against the provisioned phone key, and rechecks its own
pairing revision and connection state. TLS progress never waits for the
application readiness request; an early buffered request is not acted on
until the server's local checks complete. This avoids making each endpoint wait
for application data before completing its own handshake.

Only after those local checks, the server sends a `READY_ACK` encrypted and
integrity-protected by that TLS connection. Candidate ACK contains an explicit
profile/version, both validated fingerprint identifiers, the exact client
challenge, a fresh server challenge, and a session binding. One possible binding
is a TLS exporter using a unique, profile-specific label and an unambiguous
length-prefixed context containing the profile/version, both fingerprints and
both challenges. Exact encoding, domain label, length bounds and whether both
TLS implementations expose this exporter are unresolved and require review;
neither this note nor the laboratory handshake proves an exporter integration.
The phone verifies the entire ACK, including echoed challenge, expected profile,
peer identities and binding, while its original local owner and enrollment
revision are still current. Only then may it consider the peer session ready;
it must still require its separate local foreground task grant.

The device's local readiness linearizes only after its own completed handshake,
pin checks and valid READY_REQUEST; emitting ACK is not proof the phone received
it and is not a task submission. The phone's readiness linearizes only after
verifying the complete ACK, not merely after its handshake call returns. To
prevent a request from being accepted before the phone has actually observed
the ACK, each candidate protected task request must echo the fresh server
challenge and bind it to the same session context; the device verifies it
before any task side effect. Both readiness messages also carry the local
committed enrollment transaction and key-pair identities described above.
The exact token placement is an unfrozen application-format
decision. Neither readiness message creates a task, mutates a receipt, grants
authority or proves physical proximity. A peer can transparently relay a
valid handshake and control message.

An ACK lost in transit or disconnect at any point leaves the phone not ready;
discard the session's challenges and queued control state, do not infer a task
was submitted, and require a fresh handshake/challenges after reconnect.
Repeated, stale, reflected, cross-profile, altered or cross-session readiness
messages are rejected without task side effects; no fallback is allowed. The
TLS record replay protection and session binding are separate from durable
task idempotency: an authorized client retrying a task across sessions still
requires the durable query-only rules below. The server must recheck local
authorization at each effect; an earlier ACK cannot promise no later
revocation, persistence failure or link loss.

## 4. Protected stream and bounded messages

The CoC streams carry TLS records. The application needs a separately frozen
message framing and canonical schema for task request, status, acceptance,
result, failure and query. Input is arbitrary fragments, may split/coalesce at
any byte and must not be delivered twice; an incomplete frame at EOF is not a
complete message. Reject malformed, oversized, duplicate-key, unsupported
version, wrong type and invalid UTF-8 before any durable side effect. TLS
record boundaries are not message boundaries. Do not treat a 512-byte Link
frame or a 256-byte CoC MTU as a TLS handshake, record or queue limit.

Before freeze, define numeric limits and enforce them in both actual ends:
TLS record negotiation, certificate chain/handshake, individual application
frame and decoded task, outstanding operations, fragment buffers, producer and
consumer queues, concurrent connections, total heap and handshake/operation
and idle deadlines. Specify write partial-progress/WANT_READ/WANT_WRITE,
credits, EOF, cancellation, disconnect and post-handshake events. Exact
NimBLE send/receive ownership must cover every return including queued
`BLE_HS_ESTALLED`: retrying an already-owned buffer must never duplicate a
byte. Fragment/stream tests need partial reads/writes, exhausted credits,
queued sends, adversarial over-credit and disconnect in each state. The
existing fixed NimBLE receive-slot/initial-credit hazard is an open security
blocker for production exposure; the 256-byte laboratory workaround is not a
proof of robustness or a substitute for a reviewed upstream/platform fix.

## 5. Durable task and legacy isolation

The protected task namespace and all result/receipt lookups must be distinct
from plaintext ordinary Link `RESULT`, including after restart. Every durable
intent and receipt must bind the authorized device key, authorized phone key
or principal, exact request identifier, idempotency identity and a canonical
request-byte digest. Define collision/length/canonicalization, same id with
changed request, interrupted persist, duplicate exact messages, expiration and
unreadable/corrupt/orphan records before implementation. Persist and verify
both sides' state transitions before claiming a durable acknowledgment.

Existing reference `pdsh_task_store_next` returns both `queued` and `accepted`
without distinguishing them in its response. A future receiver must not infer
that a returned accepted task is newly executable. Upon a lost reply, the
client must use an explicitly defined authenticated query/reconciliation
path; it must not automatically repeat possibly applied work. Old plaintext
receipts do not prove their author or request hash, so neither a later valid
key nor `ble:<UUID>` may upgrade them. The old plaintext Link `RESULT` is
keyed by UUID and does not reveal the stored request/idempotency hashes or
reliably classify whether a receipt belongs to a task. Therefore a candidate
fail-closed upgrade must quarantine **all pre-upgrade unclassified receipts**
from plaintext RESULT, including ones that may have been ordinary Link
results; it cannot preserve every old RESULT lookup and also claim old
task-result confidentiality. Preserve the old bytes for explicit local
inspection, without reclassifying or deleting them. Historical plaintext data
that were already disclosed cannot be made confidential retroactively.

New protected task receipts must never enter the old plaintext namespace. New
ordinary Link receipts may remain queryable only if stored in a separately
defined, explicitly classified namespace with cross-namespace UUID conflict
checks; a collision with legacy data is not evidence of equivalence, and an
unreadable legacy index must not be bypassed as an empty one. This candidate
needs a versioned durable format, exact `RESULT` error/unknown behavior and
both-end rollback rules before implementation. A rollback may restore old
plaintext access to the *preserved old* receipts and must be recorded as that
compatibility/security loss; it must not expose newly protected receipts.
Ambiguous, orphan, corrupt or previously untrusted records remain unresolved
and fail closed, never silently replayed/deleted or attributed to a new key.
Account for filesystem race and crash consistency gaps separately.

Task deadline validation is a separate decision from certificate date policy.
An elapsed monotonic connection timeout does not establish wall-clock time or
persisted task validity across process/device restart. If a trusted wall clock
is absent, untrusted, rolled back or otherwise cannot establish the task's
deadline, the candidate must not execute it and must report an explicitly
defined unresolved or unavailable outcome. Mark `expired` only when expiry is
actually established; do not infer validity from receipt
time, BLE connection time or TLS success. Decide a trustworthy time source,
clock rollback detection, skew policy, bounded offline behavior and durable
state semantics before freeze. Clearing certificate time flags is not a task
deadline policy. Test missing time, backward jump, reboot and expiry before
any irreversible effect.

## 6. Key change, revocation, and compatibility

Candidate initial policy: one enrolled phone key per reference board until an
explicit trusted physical revocation/reset ceremony; changed or missing keys
are rejected without replacement. Forget on either endpoint invalidates live
session authority before any asynchronous teardown and requires new explicit
independent enrollment. Avoid silent re-enrollment after corruption or loss.
Specify durable commit order, failed delete/write, concurrent grant, multiple
phones, intentional key rotation, board reset, backup, factory wipe and
rollback before freeze. `UserDefaults` legacy fingerprint labels are preserved
as legacy, not treated as peer key bindings or migrated authority.

| Pair | Candidate safe behavior |
| --- | --- |
| old phone → new device | Ordinary Link negotiation and new explicitly classified ordinary receipts may remain compatible; lookup of pre-upgrade unclassified receipts is intentionally unavailable, including old ordinary results. Plaintext target task ingress stays refused. |
| new phone → old device | Ordinary Link remains separately governed; secure session unavailable, no task downgrade or task grant. |
| new phone → new device | Only after independent two-way provisioning, full authenticated session, valid local foreground grant and healthy protected storage. |
| old on-disk data → new / rollback | Preserve without automatic authentication, conversion, replay or deletion; rollback cannot read or claim security for new protected records without a separately specified reversible format. |

A secure receipt namespace, storage format, RPC schema and capability signal
are **not yet approved**. The owner must define versioned old/new behavior
and fixtures and ensure old plaintext result routes cannot reveal protected
records before either end implements them.

## 7. Minimum shared acceptance vectors

These describe tests, not frozen bytes, generated keys or permission to run a
device experiment. After the owner defines a schema, each end must consume the
same positive/negative cases through its real parser, handshake and durable
state transitions; substitutes may replace transport edges, not declare trust.

1. Correct two enrolled keys, full mutual handshake, explicit task grant and
   one valid `next`/`accept`/terminal receipt through the protected namespace.
2. Either side presents a different key; same certificate with wrong private
   signing key; invalid point, altered transcript, changed ciphertext and
   truncated record. No protected task or receipt is delivered.
3. Unenrolled first use, fingerprint display substitution, declined physical
   confirmation, failed or interrupted trust write, altered NVS/Keychain
   entry, locally forgotten key and attempted silent re-enrollment.
4. Secure capability absent, malformed/unknown version, TLS downgrade, 0-RTT
   and resumption attempt; assert zero plaintext-task ingress or result read.
5. Reconnect with the same pins and a new local owner; stale completion,
   changed key, revoked grant, changed device/phone key and old connection
   callbacks after reconnect. An indistinguishable callback is not labeled
   old based on an invented OS token.
6. TLS partial read/write, zero progress/WANT_READ/WANT_WRITE, queue bounds,
   credit starvation and send ownership; truncated app message and EOF; a
   cooperative and adversarial CoC peer after any upstream repair.
7. Exact duplicate task and receipt; same id with different payload/hash/key;
   replay under a new session or different authenticated peer; out-of-order
   state, invalid UUID/UTF-8/duplicate JSON member and over-limit payload.
8. Power loss at each write/commit boundary, lost accept/result reply, queued
   versus already accepted `next`, restart and authenticated query-only
   recovery; explicit `outcome_unknown` without automatic execution retry.
9. Legacy `ble:<UUID>` intent, old public fingerprint, plaintext RESULT and
   corrupt/unreadable/orphan record cannot be converted into authority or
   returned from the protected namespace; data remain preserved.
10. Authentication fails without damaging a healthy ordinary Link; genuine
    link loss closes its own resources. Foreground revoke/forget/owner change
    while proof, write or outcome is in flight must not restore permission or
    deliver a stale result.
11. Client local handshake returns while the server has not yet verified its
    client certificate/Finished; no task data is sent or accepted. Then deliver
    protected READY_REQUEST/ACK only after the server's checks, and assert
    exactly one readiness transition without a wait cycle or task side effect.
    Alter/replay/reflect the challenges, binding or profile, replay across a
    new TLS session, drop ACK at each byte and reconnect; the phone remains
    not ready and neither side creates an intent/receipt.
12. Trusted USB enrollment with input/readback mismatch, reconnect, interrupted
    commit or replayed confirmation; no new pair becomes authorized. A serial
    peer is not by itself evidence of board identity. Separately test key
    storage absent on an enrolled board, corrupted initial-state marker and
    rollback; do not auto-generate a replacement or infer protection without a
    supported anti-rollback anchor.
13. Old receipt with unknown tool classification and a plain RESULT query:
    deny even if the old entry was actually ordinary. New classified ordinary
    receipt may be read; new protected receipt never appears in old RESULT.
    Exercise UUID collision, unreadable legacy index and rollback; do not
    claim past disclosures were undone.
14. Distinct task-deadline and certificate-clock tests: missing wall clock,
    backwards clock, reboot, expiry while disconnected and failure to persist
    a trusted time anchor. Monotonic session timeouts alone must not authorize
    a persisted task or relax certificate validation.
15. Interrupt enrollment after each staged write, after each local commit,
    after each user confirmation and at every final acknowledgment boundary;
    restart each side independently. A staged, partial, corrupt, missing or
    mismatched transaction admits no task and is never silently promoted.
    Explicit reconciliation is required for ambiguous completion. Even after
    two known local commits, require a fresh authenticated matching-record
    readiness exchange and phone grant; do not assert an atomic global commit.
    Separately test whichever policy the owner freezes for an already-valid
    old pairing during new enrollment, replacement and failed revocation.

Confirm each result through exact production state, durable bytes and real
continuation counts, with mutation tests; report simulator and physical runs
separately. A successful TLS record cannot prove its application side effect
was durable or executed exactly once.

## 8. Evidence and remaining blockers

Recorded evidence includes a separate iPhone/ESP32 laboratory native CoC TLS
1.3 mutual-certificate PING/PONG and wrong-leaf rejection in both directions;
its board had embedded exportable test keys, a test CA and ignored certificate
date flags. A separate physical iPhone/host TLS feasibility used an exportable
Keychain software key; it was not the CoC/ESP32 task session. The original
whole board image was restored and digest checked; application functionality
after reset was not independently established. No production task receipt,
key provisioning, secure persistence, device reboot recovery, hostile
on-air CoC robustness, final TLS policy or independent security review is
proved by those laboratory observations.

Minimum progress without an external user action: choose/review the threat
model and provisioning assumptions; statically audit the pinned library source,
versions and licenses without vendoring; specify candidate stream limits and
trust/error/migration matrix; prepare valid and adversarial fixtures and a
separate two-end review; identify supported upstream fix for the CoC hazard.
This work does not require turning on a target feature. A provisional contract
may be reviewed with explicit unmet prerequisites, but may not authorize
production use or mark GAP-16 closed while limits, trust and receipt behavior
remain undecided. Physical enrollment and verified dual-end/reboot/negative
acceptance require appropriate external cooperation and must not reuse a
previously rejected experiment. Automatic review refusals remain in force;
this document does not request or supply an authorization workaround.

Primary references: [RFC 9846 TLS 1.3](https://www.rfc-editor.org/info/rfc9846/)
(application defines identity and protocol binding; 0-RTT replay risk),
[Apple CBL2CAPChannel](https://developer.apple.com/documentation/corebluetooth/cbl2capchannel)
(stream and peer API), and [RFC 9525](https://www.rfc-editor.org/info/rfc9525/)
(service identity in TLS; its Web PKI rules are not automatically a pinned
BLE-key policy).
