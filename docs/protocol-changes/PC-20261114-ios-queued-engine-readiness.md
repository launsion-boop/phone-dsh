# iOS queued delivery readiness — first residency increment

Base: 29a733cb8f8f764e27629b5e126fcf572b042168.
Protocol impact: P09; P06; P07; P12: none — no SDK module or ABI changes; P16: none — Worker bootstrap and wire remain unchanged; P27: none — Bot rows and user actions remain unchanged.

This implements the architecture's first existing-outbox delivery slice, not APNs or a new
cold-target admission store. Scope is iOS and already-bound local DSH sessions. Bot-specific
admission, account-scoped external credentials, first-ever session persistence and new native
SQLite admission remain subsequent increments; no remote endpoint is added.

Freeze: ChatDeliveryPreparation decision takes foreground/background execution eligibility,
host presence, parked state, lifecycle/busy state, transport readiness and manual-recovery state.
It returns ready / start / resume / wait / deferred / needsAttention. Background may deliver
only to an already-ready host held by the existing keep-alive path. It never cold-boots or
resumes a parked host. Foreground queued work may start/resume via existing ChatModel methods.
A single recoveryFlushTask owns preparation, with the existing bounded 30s wait and host
boot/resume bounds. No new lifecycle state machine or timer-based idle eviction is introduced.

Admission remains SendOutbox's durable enqueue for an existing session. The entry's sessionId
and rpcId never change during preparation. Errors/timeouts keep the entry and existing
outcomeUnknown/read-back rules; a prepare result is never a delivery/execute receipt.
Foreground return retries queued preparation even when host is absent. First-ever background
send with no session is refused rather than booting or falsely promising durable acceptance.
The 1800s turn watchdog, device grant windows, background boot gate and user recovery remain.

Compatibility: same on-disk records and same downstream actions on old/new versions; only
when preparation is attempted changes. Android is unchanged. No persisted format/version bump.

Acceptance: policy regression matrix (parked host, busy transition, background constraints,
manual recovery), real SendOutbox reopen preserves target/key/state and never retries unknown
outcomes, Swift compilation of changed App source. Device/BLE/APNs and power tests are NOT_RUN
until actually executed; this increment does not claim to finish R0–R5.


## Revision 2: existing TonoLink ingress (contract owner: root)

The current device task contract is still target-only; this increment does not enable it.
TonoLink already submits owner voice text to local DSH. Reuse the real SendOutbox for this
producer instead of creating a second native execution ledger. Bot actions keep their existing
transactional nonce/effect ledger; choosing a new Bluetooth-to-Bot destination is not inferred
from whichever Bot happens to be selected. Server ingress/APNs is DEFERRED_BY_USER.

Freeze before implementation: snapshot the existing local DSH session and generate one UUIDv4
at wake, before ASR/unlock awaits. Enqueue recognized non-volume text with that exact session
and rpcId; refuse missing/device-only targets or unavailable protected data without speaking
an acceptance. A canceled recording cannot enqueue new work; cancellation after durable enqueue
stops voice waiting/playback, not the already accepted task. Repeated admission with the same
request ID must not overwrite an entry; there is no automatic duplicate replay from the board's
wrapping wake counter. This is a local receipt, not a new BLE frame or authentication claim.

The acknowledgement follows the successful durable write and says the request was saved;
it does not promise immediate execution. Pending work survives suspension/relaunch through the
existing queue. No cold WebContent boot/resume in background. A receipt contains sessionId/rpcId,
never just a Bool. Playback requires that exact authoritative user message, a matching turn and
its normal terminal event; text matching and the global running flag are not proof. A session
switch, failure, unknown attribution or timeout stops playback without resubmitting the prompt.

For the ordinary UI's first-ever local send, establish a foreground session first, then enqueue;
never submit directly before durability. No session means no acceptance. No persisted format
changes: old/new app versions read the same outbox and use the same downstream request IDs.
Old firmware/new app and new firmware/old app keep identical BLE bytes; only native target/ack
and playback timing change. Android stays unchanged per user scope.

Owner paths: root owns the P06/P07 text below, native App/ProbeKit implementation and tests.
Valid and invalid regression cases: exact request/turn, same text with a different request,
optimistic-only input, failed turn, different session, unavailable protected data, parked/cold
background, first session preparation, queue reopen and unknown outcome. No new golden wire
vector is necessary because encoded bytes and schema are unchanged. Acceptance commands:
`swift test` against the real policy/outbox sources; native iOS build; repository spec,
conformance and cross-tree checks; host smoke. Device wake/energy remain NOT_RUN unless run.
