# iOS queued delivery readiness — first residency increment

Base: 29a733cb8f8f764e27629b5e126fcf572b042168.
Protocol impact: P09; P06; P07; P05; P12: none — no SDK module or ABI changes; P16: none — Worker bootstrap and wire remain unchanged; P27: none — Bot rows and user actions remain unchanged.

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

### Attribution clarification (revision 3)

Source review of the pinned DSH `session-turn-outline` confirms `turn/start` precedes the
prompt, but `user/message` need not contain `data.turn`. The consumer must fold observed
turn/start/end boundaries, as the DSH projection does, rather than require a nonexistent
field. Live acknowledgement receives the current open turn from the same ordered event pump;
history projection derives it only from boundaries actually present in the page. A page that
starts mid-turn cannot invent attribution. Tests use a real mapped user event without `turn`.

### Pre-transport deferral clarification (revision 4)

If lifecycle eligibility changes during the durable `markSubmitting` await, the same live
sender still knows it has not called transport. It may use the existing submitting →
outcomeUnknown → queued edges to defer that unsent entry with the same ID. This proof is local
to that live pre-transport branch and must never be inferred from a persisted error string or
from an entry recovered after a crash. A crash between the two writes remains ambiguous and
requires authoritative reconciliation. No new stored state, field or transition is added.


### Cross-document alignment (revision 5)

P05 `cloud-voice.md` §4 described the former current-chat routing and pre-admission wording.
Align that native-consumer paragraph with the P07 frozen admission/receipt rules. Cloud ASR/TTS
endpoints, credentials, audio bytes, chunk limits and error handling remain unchanged; only
when the native consumer acknowledges and which proven reply it selects change. Existing cloud
producers/consumers require no wire migration.


### Resident execution eligibility (revision 6)

Review of the frozen revision found that background preparation only honoured the chat's own
`keepingAlive`. A connected TonoLink board holds `SilentAudioKeepAlive` under its own owner, so
the process stayed resident while a host parked before the board connected was never resumed:
voice was saved ("已经记下了") and waited for the user to open the App. The foreground gate on
`start()`/`resumeHost` also refused every caller, including a cold launch still `.inactive`.

Delta (P06 §10.1, P07 §4.1.1; no wire, schema, outbox or BLE byte change):

- One eligibility answer `ChatDeliveryPreparation.executionEligible`: not in background, or
  the chat keep-alive, or any resident `SilentAudioKeepAlive` owner. Preparation, drain, the
  pre-transport recheck, start/resume and voice deferral all read it.
- While eligible, background preparation may start or resume through the existing methods.
  A background delivery takes the chat's own keep-alive for that turn; the existing turn-end
  path then parks unless the board is still armed.
- A start refused for eligibility is remembered and performed at the next foreground return.
- An explicit stop pauses queued preparation and cancels the preparation task before the busy
  check, so a boot started by queued work never drains afterwards.
- A send pinned to another session no longer becomes the on-screen session's retry target.
- Voice waiting does not time out while preparation is in flight, and re-derives progress only
  when events, items, turn boundaries or sessions change.

Not changed after source review: a mid-turn `.prompt` is a DSH `followup` (next-turn inbox), so
its `user/message` follows the next `turn/start`; live attribution by open turn stays correct.

Compatibility: same records and requests old↔new; rollback restores foreground-only preparation
without losing queued entries. Android/firmware unchanged. Device background boot/resume under a
board keep-alive, BLE cold relaunch and power are NOT_RUN until executed on hardware.


### Device findings (revision 7, implementation only)

Device run (receipt §真机驻留验证) proved background execution on a parked host under the board
keep-alive, and found two native gaps with no contract change: (1) after start/resume the
preparation task drained once mid-recovery and nothing retried in background — it now loops
until `.ready` with one preparation per task; (2) a pump that failed while parked could hang in
a resync against the parked page — a resume now restarts it from `lastSeq` while recovering.


### Spoken acknowledgement only when deferred (revision 8)

Device use: the owner found 「好的，已经记下了」 before every answer redundant once background
execution is direct. P07 §4.1.1 / P05 `cloud-voice.md`: admission is unchanged (durable enqueue
before any acceptance), but the acknowledgement is spoken once only when execution cannot start
now (deferred, or no engine within the admission bound), worded 「已经记下了，打开手机后继续处理」.
Executable work speaks only its answer; the LED shows it running. No wire, BLE or record change.

### Locked admission and proof of absence (revision 9, PROPOSED — needs contract owner sign-off)

Review after merge found two ways a request could be lost or stuck.

1. Admission used `isProtectedDataAvailable` as a stand-in for "storage is writable". A voice
   command on a locked phone whose board unlock failed was dropped with a log line only. P06
   §10.1 / P07 §4.1.1 / P05 `cloud-voice.md`: the outbox write itself decides whether there is a
   durable receipt. A locked phone admits; queued delivery (not `start()`/`resumeHost` in
   general, and not Bot work) waits for protected data, so the deferred acknowledgement
   「已经记下了，打开手机后继续处理」 is true, and the unlock notification retries delivery. Text
   that is not saved, or has no local session, is spoken as a failure.
2. P06 §10 allows `outcomeUnknown → queued` only on proof of absence, but the read-back could only
   ever answer "found". With the user-retry requeue removed in revision 2, an unsent unknown had
   no exit. The read-back now defines that proof (see §10 "Outcome unknown"): inbox projection
   and history from one follow snapshot. The state machine, `rpcId` and the DSH `requestId`
   de-duplication are unchanged; a resend after proof reuses the original `rpcId`.

Compatibility: no record, schema, wire or BLE change. Old↔new read the same queue; rollback
restores lock-gated admission and leaves unknown entries in place. Not verified on hardware:
locked admission with a failed board unlock, delivery on the unlock notification, and the spoken
failure are NOT_RUN.

### Background AirPlay speech (P08 ios-audio-session revision 3)

See `spec/platform/ios-audio-session.md` §2: a speaker claim switches to playAndRecord only for an
AirPlay output; the voice host keeps its foreground-armed claim through a background board drop
and keeps the keep-alive for 600 s. Device evidence in the receipt.
