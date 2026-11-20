# spec/host/v1 — host-side contract tree

Status: normative, contract version `1`, MIT.
**Owner: host contract owner.** Not the iOS team, not the Android team. Both implement this
tree; neither edits a rule to match its own code.

`spec/v1` fixes the byte contract between a host and the DSH worker. It says nothing about what a
host exposes to its own UI, to a device, or to a platform. Those surfaces lived only in Swift, so a
Kotlin port could only translate Swift. This tree fixes them language-neutrally: schemas, golden
instances and one checker. It is the only judge of the Kotlin `:agentcore` module (port brief §4.2,
§5, §13.1). Swift stays the reference implementation and the first place a behaviour is proven on a
device; it is not the definition. A disagreement with Swift is a defect report against this tree
(port brief §5.3).

Citations are `short:line`: `AH` = Sources/PhoneDSHAgentCore/AgentHarness.swift, `AR` =
Sources/PhoneDSHAgentCore/DSH/DSHRemoteHarness.swift, `AM` = .../DSHEventMapper.swift, `AT` =
.../DSHRemoteTransport.swift, `PE` = Sources/PhoneDSHAgentCore/ProviderError.swift, `HOST` =
Sources/PhoneDSH/PhoneDSH.swift, `HOSTIMPL` = Sources/PhoneDSH/PhoneDSHHost.swift, `WIRE` =
Sources/PhoneDSHWire/JSONPayloads.swift, `CONN` = docs/design/device-connector-2026-10-31.md,
`DRAFT` = docs/design/device-adapter-contract-draft.md, `PLAN` = the out-of-tree Android port brief
(cited only where a rule has no in-tree source).

## 1. Boundary

In scope: the host↔host API (open a session, send a command, consume an ordered event stream, read a
goal), the host↔device seam (envelope, capability manifest, receipt), and the host facade a platform
layer drives (`start`/`stop`/`harness()`).

| Not here | Lives in |
|---|---|
| frame header, WAL, exec, handoff, budgets, host state-machine table | `spec/v1` |
| a device protocol's own wire format | `DRAFT` §1; frozen later, not now (`PLAN` §13.4) |
| durability, secure store, lifecycle signals, renderer host | `spec/platform` |
| screens, tokens, interaction states | `spec/ui/v1` |

Three rules keep the boundary from drifting: (1) anything describing *how a host talks to a
worker* belongs to `spec/v1`, even when the backend is local (`AH:480-501` hides the difference);
(2) anything describing *what a third-party device protocol must provide* stays in `DRAFT` until
the protocol freezes, so only the shapes it maps onto are fixed here (`CONN` §4.6); (3) a member
that only exists to make one OS happy belongs to `spec/platform`, never here.

## 2. Version and compatibility (contract 1, frozen)

### 2.1 Version values

- The device envelope carries `v`, integer `1`; another major version is rejected before any other
  member is read (`CONN` §4.1, `DRAFT` §7).
- The capability manifest carries `schema: "pdsh-device-caps/1"` (`CONN` §4.5, `DRAFT` §5).
- Harness messages carry no version member: the tree is versioned by path (`spec/host/v1`) and the
  capability set says what a backend can do (`AH:17-77`).
- `protocol.version` is `MAJOR.MINOR`; the major number is the negotiation unit (`DRAFT` §7,
  `CONN:252`). No feature probing, no silent downgrade: a mismatch fails loud.

### 2.2 Decoders (MUST)

1. Ignore every member the schema does not define. Unknown optional members are how this contract
   grows; a decoder that rejects them breaks on the first additive change (`PLAN` §13.7). The
   memory of that rule is `golden/*` with `ignore_members`, which the checker executes.
2. An unknown event `kind` is dropped, the stream keeps running, and its `seq` counts as consumed; a
   cursor that stalls on an unknown event would replay it forever (`AH:490-494`).
3. An unknown capability name means "not supported" and never raises; `vendor.*` is passed through
   unparsed (`CONN:198`, `DRAFT:101-102`).
4. An unknown receipt `code` is treated as `internal` and never swallowed (`DRAFT` §4).
5. An absent optional member takes its documented default: no `attachments` means none (`AH:251`),
   no `questions` means a single flat prompt (`AH:314`), `last_seq` absent means not reported
   (`AH:150-151`).

### 2.3 Encoding and encoders (MUST NOT)

- Member names are `lower_snake_case`; reference property names are not normative.
- A time member is an integer count of milliseconds since the Unix epoch, matching the journal
  (`AM:55`): `time_ms`, `ts_ms`, `expires_at_ms`, `retry_after_ms`. A binary member is base64 text
  (`data_base64`).
- Arbitrary JSON is allowed only where a schema says so (`tool_call.arguments`, `tool_result.meta`);
  map members carry string values (`metadata`, `headers`).
- Never emit a member outside the schema, `seq` on a best-effort event, or a receipt as a state
  report. The goldens are the encoder targets; `spec/v1` README §2 states the same asymmetry for
  the worker contract.

### 2.4 What bumps the version

| Change | Version |
|---|---|
| add an optional member, an event kind, a capability name, a receipt code | none: decoders already tolerate it (§2.2) |
| add a required member, rename or remove a member, change what an existing value means | major |
| narrow a value range (shorter max, smaller enum) | major, because a valid encoder is now rejected |

### 2.5 Resume negotiation (hard-coded)

| `resume` | Host behaviour | Source |
|---|---|---|
| `native` | resubscribe with `events(after: last durable seq processed)` | `AH:18-20`, `AH:490-494` |
| `replay` | re-read a transcript and rebuild state client-side | `AH:21-22` |
| `none` | start over; nothing is replayed | `AH:23` |

- A transport loss ends the stream with `unavailable`; the caller resubscribes from its last durable `seq` (`AH:492-494`, `AR:262-265`, `PE:31-37`).
- The cursor advances only on durable events; best-effort events carry no `seq` and are never replayed (`AH:414-415`, `AH:453`, `AR:350-364`).
- A backend drops any event whose `seq` is not above the cursor, so redelivery is harmless (`AR:373-375`).
- `seq` is an ordinal, not a count: DSH maps `dsh seq * 8 + part`, so gaps are legal and the first durable seq may be `0` (`AM:25-33`); never derive "events missed" from a gap.

## 3. File map

| File | Contents |
|---|---|
| `README.md` | boundary, version rules, the three source classes, golden format |
| `schema/harness-capabilities.schema.json` | the seven capability members and their value sets (`AH:17-77`) |
| `schema/harness-session.schema.json` | what `openSession` returns: `id`, `capabilities`, `last_seq` (`AH:147-163`) |
| `schema/harness-session-request.schema.json` | open/resume parameters and MCP client-tool references (`AH:81-144`) |
| `schema/harness-command.schema.json` | the seven commands, `oneOf` by `kind` (`AH:249-262`) |
| `schema/harness-event.schema.json` | the 15 event kinds, durable vs best effort (`AH:389-454`) |
| `event-kinds.md` | host kind → trajectory projection type, synthetic UI families, seq/turn rules, measured `tool_result` members |
| `schema/harness-goal.schema.json` | goal projection; `blocked` requires a reason (`AH:458-477`) |
| `schema/harness-error.schema.json` | the eight error classes and the retry split (`PE:12-37`) |
| `schema/device-envelope.schema.json` | transport-independent device envelope (`CONN` §4.1, `DRAFT` §3) |
| `schema/device-capabilities.schema.json` | manifest: capability map, limits, auth (`CONN` §4.5, `DRAFT` §5) |
| `schema/device-receipt.schema.json` | applied/failed receipt of one downlink command (`DRAFT` §4) |
| `schema/outbox-entry.schema.json` | one durable send-outbox entry: `rpcId`, state and timestamps (§10) |
| `schema/engine-launch.schema.json` | the shared engine-launch vector document: closed wake reasons, decisions, steps, thresholds and per-step budgets (§10.2) |
| `golden/engine-launch.json` | valid and invalid decision/sweep vectors, read directly by the Swift and Kotlin tests (§10.2) |
| `golden/*.json` | at least one instance per schema; event sequences prove resume |
| `tools/host_check.py` | schema lint, golden validation, sequence and capability rules |
| `tools/test_host_check.py` | mutation tests that keep the gate honest |
| `tools/outbox_invalid_cases.json` | negative outbox cases (UUID, state and transition) read by `test_outbox_contract.py` |
| `tools/test_outbox_contract.py` | state-machine and schema negatives for the outbox |

## 4. Source A — AgentHarness (`AH:480-501`)

| Operation | Contract | Source |
|---|---|---|
| `capabilities` | static set of the backend; a session may narrow it, never widen it | `AH:480-482` |
| `openSession(request)` | new session when `session_id` is absent, resume when present; returns `id` + capabilities (+ optional `last_seq`) | `AH:484-485`, `AH:110-163` |
| `send(command, to:)` | one command per call; the session id is out of band | `AH:487-488` |
| `events(session_id, after:)` | `nil` means from the beginning of what the backend retains; the stream finishes when the session exits | `AH:490-494` |
| `goal(session_id)` | default `nil` for backends without goals | `AH:496-497`, `AH:503-505` |
| `closeSession(session_id)` | default no-op; frees client resources, never deletes the remote session | `AH:499-500`, `AH:503-504` |

| `kind` | Required | Rules | Source |
|---|---|---|---|
| `prompt` | `text`, `request_id` | idempotent by `request_id`; a backend may accept image attachments only and must reject others with `unsupported` | `AH:251`, `AH:487-488`, `AR:171-179` |
| `steer` | `text`, `request_id` | legal only while the turn runs and only with `capabilities.steer` | `AH:252-253` |
| `cancel` | — | no cause on the wire | `AH:254`, `AR:124-125` |
| `cancel_with_cause` | `cause` | four cause kinds; the DSH projection is nested (table below) | `AH:191-246`, `AH:255-258` |
| `permission_response` | `request_id`, `decision` | `allow_once`/`allow_always`/`deny`; a backend without "always" degrades to once and asks again | `AH:259`, `AH:185-189`, `AR:134-137` |
| `question_response` | `request_id`, `answer` | `answer` is a string; a JSON object maps question ids to selections; an unknown pending request is `invalid_request`, never dropped silently | `AH:260`, `AH:297-327`, `AR:188-195` |
| `shutdown` | — | only where the backend has a remote shutdown, else `unsupported` | `AH:261`, `AR:146-147` |

Cancel causes (`AH:191-246`): flat in the host contract, nested in the DSH request.

| Host value | DSH `session/cancel` cause | Source |
|---|---|---|
| `{kind: user}` | `{"kind":"user"}` | `AH:219-223` |
| `{kind: hook}` | `{kind: hook, reason: {kind: hook}}` | `AH:224-227` |
| `{kind: budget, detail}` | `{kind: hook, reason: {kind: budget, detail}}` | `AH:228-235` |
| `{kind: timeout, detail}` | `{kind: hook, reason: {kind: timeout, detail}}` | `AH:236-243` |

Durable event kinds carry `seq`; best-effort kinds never do (`AH:389-415`, `AH:453`).

| Durable | Best effort |
|---|---|
| `assistant_message`, `tool_call`, `tool_result`, `user_message`, `inbox_spliced`, `turn_started`, `turn_ended`, `progress`, `usage` | `assistant_delta`, `reasoning_delta`, `permission_requested`, `question_requested`, `session_status`, `exited` |

### 4.1 Event-kind crosswalk

`event-kinds.md` is the one machine-readable crosswalk from the 15 host kinds to the
trajectory projection types, the synthetic UI rows, and the seq/turn rules. A host that emits a
kind absent from that table, or a trajectory row not derivable from it, is out of contract.

Projection rules a reimplementation must not "improve":

- `tool_result.summary` is single-line and bounded (280 characters); `tool_result_detail` keeps newlines up to a 64 KiB audit bound and, over it, ends with a spill marker naming the session log and the DSH event seq (`AH:357-386`, `AM:162-195`).
- `tool_result.bytes`, `duration_ms` and `meta` are optional measurements; absent means "not measured", so a UI shows unknown and never a fabricated `0` (`event-kinds.md` §1.2).
- `turn_ended.reason` is the compatibility projection; `raw_turn_end_kind` keeps the producer label (`AH:421-434`, `AM:136-153`). `aborted` and `interrupted` are both `cancelled`; unknown producer kinds are `failed`.
- `user_message.source` and `inbox_spliced.messages[].source` come from the producer; an unreadable source is `unknown`, never `user` (`AM:128-130`). One DSH event may become several harness events, which is what the seq slots are for (`AM:82-88`).

Error classes (`PE:12-29`): `unsupported`, `unauthorized`, `unavailable`, `rate_limited`,
`invalid_request`, `invalid_response`, `cancelled`, `conflict`. Only `unavailable` and `rate_limited`
are retryable (`PE:31-37`); the DSH transport maps its codes onto these classes (`AT:53-69`).

## 5. Source B — the device seam

Status: `CONN` §4.6 and `DRAFT` define this seam, and there is no Swift implementation of it in the
repository today. That makes this tree, not Swift, the Kotlin source.

- **Control and media never share a shape** (`CONN:220-232`): control is request → receipt
  (idempotent, TTL, state revision); media is a stream with credit. Collapsing both into one
  `send() -> ack` has to be undone as soon as a call (20 ms frames) exists (`PLAN` §13.3).
- **Envelope**: `dir` is `up`/`down`; every uplink has `origin: device`, a downlink is `phone` or
  `agent` (`DRAFT` §3). `session_id` is mapped by the host and never supplied by the device
  (`DRAFT` §3). An uplink becomes a prompt with `request_id = "dev:" + msg_id`, which is what makes
  redelivery idempotent (`PLAN` §13.2, `DRAFT` §3).
- **Receipt**: `id` is the command id, `status` is `applied`/`failed`, `data` carries the resulting
  state revision. The same id with different content is `invalid_args` and is not executed; an
  expired command is not executed; a state report without an id can never complete a command
  (`DRAFT` §4, `CONN:158-163`).
- **Capabilities**: an undeclared capability is unavailable; `vehicle.*` appears only with
  `granted_by: oem`; `vendor.*` is passed through unparsed (`CONN:191-198`, `DRAFT:101-102`);
  `max_frame_bytes` is bounded at 64 KiB (`CONN:250`).
- **Trust**: an uplink is untrusted input; a device-originated turn starts with an empty tool set;
  every write goes through the capability gate (`CONN:165-171`). A device never sees the event
  stream, permission requests or question requests (`CONN:155,171`).
- **Media** uses credit, not per-frame acks; clock and sequence rules belong to the protocol
  (`CONN` §4.9).

**Vocabulary authority.** `schema/device-capabilities.schema.json` is the sole authority for the
capability vocabulary; `CONN` §4.5 and `DRAFT` §5 are input material. The union is kept, and a
name no device golden uses carries `provisional: true` in that schema (the checker fails on an
unmarked or a stale marker). `display.text` is the legacy spelling of the `render.*` family and
stays declared; `light.effect.set` is a command, never a capability. An unknown name is
unavailable (§2.2 rule 3).

## 6. Source C — the host facade

- Six coarse states: `stopped`, `starting`, `running`, `draining`, `remote`, `failed`, with the
  fail-loud exit through `reset()`/`userReset()` (`HOST:384-399`).
- Operations: `start`, `stop`, `reset`, `userReset`, `plannedRestart(reason)`, `beginHandoff`,
  `reclaim` (three overloads), `reportEngineHeapBytes`, `diagnostics` (`HOST:407-462`); errors are a
  closed 13-case enum (`HOST:465-493`).
- `harness()` refuses `notStarted`, `failed` and Lockdown Mode, and returns a per-call supervisor
  wrapper: replacing the harness releases the old subscription and disarms that supervisor
  (`HOSTIMPL:2439-2463`). A host must not cache one harness across a recovery.
- Admission is separate from the facade state and is published to the loopback layer as
  `open`/`closed` (`HOST:666-667`, `WIRE:481-484`).

## 7. Golden format

Every `golden/*.json` is `{"name", "schema", "instance", "notes"}`:

```json
{"name": "...", "schema": "schema/<name>.schema.json", "instance": {}, "notes": "<file>:<line> ..."}
```

- `schema` is resolved inside this tree; a golden pointing outside it or at an absent schema fails.
- `notes` must cite a source; it is the only prose in the tree and it is checked, not trusted.
- `ignore_members` (optional) lists members removed before validation, and the instance must carry them: the executable form of §2.2 rule 1.
- A list `instance` is an ordered event sequence of `schema/harness-event.schema.json`; `seq_rule` is `dense` (default: starts at 1, steps by 1) or `sparse` (strictly increasing, gaps allowed, e.g. a DSH mapping), and `resume` declares `after_seq`/`expect_next_seq`, which the checker compares against the sequence.
- Goldens are encoder targets. Decoder leniency (§2.2) is expressed by `ignore_members`, never by loosening a schema.

## 8. Verification

```
python3 spec/host/v1/tools/host_check.py --root .
python3 -m unittest discover -s spec/host/v1/tools -p 'test_*.py' -v
```

One line per schema and per golden, exit 1 on a mismatch, 2 on a usage or I/O error. The checker
reuses `spec/v1/tools/spec_golden.py` for loading and validation; the keyword subset it supports is
the subset this tree may use.

## 9. Not fixed here

Named so that a Kotlin engineer does not invent them locally.

| Gap | Why it is not here | Source |
|---|---|---|
| persistent external ingress queue (at-least-once, `request_id` dedupe, parked while the app is not running) | fixed for the phone host by [external-admission.md](external-admission.md) (§11, `target`); a connector still must not write the WAL directly | `PLAN` §13.7 row J2 |
| tool-registry change while a worker runs (`registerTools()`) | belongs with the worker restart policy in `spec/v1` | `PLAN` §13.7 row J3 |
| a device command channel inside the worker protocol | two candidate designs, undecided | `PLAN` §13.7 row J4 |
| media port and the second foreground-service type | platform slice, `spec/platform` | `PLAN` §13.7 row J5 |
| per-device audio stack (BLE, codec, buffering, ASR) | protocol-specific implementation work | `PLAN` §13.7 row J7 |

## 10. Durable send outbox (P06, W1)

The UI→host send path is host behaviour above the worker contract (§9 row J2 is the *ingress* queue
for device commands; this is the user's outgoing message queue and has its own boundary). For the
local App-container backend it is one durable queue with the same observable rules.

**Scope (W1 rev 5, 2026-11-12; owner-authorized).** The durable outbox, its state machine, `rpcId`
and delete condition apply to the **local App-container backend**. The `pc` backend stays on its
pre-W1 direct path this round and is **not** crash-durable; it has no contract-defined
authoritative-history equivalent for the delete condition (GAP-40). The schema still accepts
`backend: "pc"` for forward compatibility, but this round no producer writes a pc entry and no pc
entry carries the durable guarantee.

Text prompts and attachment sends use **one**
outbox, the same `queued → submitting → accepted → durable` + `outcomeUnknown` machine, the same
enqueue-time lowercase UUIDv4 `rpcId`, and the same delete condition: an entry is deleted only
after authoritative history contains a `user_message` whose `source.rpcId` equals it and the
entry is `durable`. This is an explicit owner-authorized scope expansion from Rev 2, not a silent
widening; the state machine and `rpcId` semantics are unchanged. An attachment entry carries
references plus minimal metadata, never inline bytes.

- **Enqueue is the durable fact.** A send creates one entry and writes it with the §7 atomic order
  (temp file, fsync, rename, directory fsync) **before** any transport attempt. The entry is
  shown immediately as `queued`; a transport failure never removes it and never loses the user
  text. The file is `send-outbox/<rpcId>.json`, unique per `rpcId`.
- **Attachments.** An entry may carry `attachments[]`; each item has `id`, `kind`, `byteSize`,
  `sha256`, `contentType`, `filename` and `storePath` (schema: `outbox-entry.schema.json`). The
  bytes live **only** in the outbox-owned store at `send-outbox/attachments/<rpcId>/<attachmentId>`
  — the same durable app-container tree as the entry, never `Library/Caches`, never Worker-volatile
  `/dsh/tmp`, never inline/base64 in the entry. Before an entry is committed, every attachment file
  is written, fsynced and its digest verified; then the entry is atomically written. This gives at
  least level-1 durability: the bytes are lost only if the device container itself is destroyed.
- **Text and attachment-only sends.** A text-only entry keeps `text` non-empty (1–1,000,000
  characters). `text` MAY be the empty string **iff** `attachments` is non-empty; an attachment-only
  send therefore has a valid entry without a synthetic caption. Empty text with no attachments is
  invalid (schema `oneOf`: non-empty-text variant, or empty-text plus `attachments` `minItems: 1`).
- **Attachment count.** `attachments` is bounded at 20, mirroring the host-declared per-message
  image limit (`imageLimits.maxImagesPerMessage`, `NativeImageLimits.fallback = 20`). The App must
  not exceed the host-declared limit and must not silently drop attachments; when the declared
  limit is lower, that lower value wins. A 21st attachment is an invalid entry, not a new refusal
  path in the UI.
- **Attachment lifecycle.** An attachment file is unlinked only after its entry is deleted per the
  delete condition above; the entry (and its files) are never removed while the entry exists. Delete
  the entry first, then its `attachments/<rpcId>/` directory. Startup GC removes an
  `attachments/<rpcId>/` directory only when no `send-outbox/<rpcId>.json` exists (crash between
  entry delete and unlink, or a crash before the entry write); it never removes files referenced by
  an existing entry.
- **`rpcId`.** A lowercase UUIDv4 generated at enqueue, immutable for the entry's life. It is the
  `source.rpcId` of the user message and the only idempotency key used for delivery. The authority
  de-duplicates by it; a retry of the same entry reuses it.
- **State machine.** `queued → submitting → accepted → durable`, plus
  `submitting → outcomeUnknown`. The only other allowed edges are
  `outcomeUnknown → accepted` (read-back found the `rpcId`) and `outcomeUnknown → queued`
  (read-back proved the message absent before a resend). No other edge exists; `durable` is not a
  stored state after deletion (the file is removed).
- **Delete condition.** An entry is deleted **only** after an authoritative history contains a
  `user_message` whose `source.rpcId` equals the entry's `rpcId`, and the entry is `durable`.
  A local `accepted` acknowledgement is not enough; an `outcomeUnknown` entry is not deleted
  until the read-back resolves it.
- **Outcome unknown.** A transport interruption after the request was written is
  `outcomeUnknown`, never an automatic resend. The host first reads the authoritative history
  (the same source that would make it `durable`); if the `rpcId` is present it becomes `accepted`
  then `durable`; if proof of absence is available it returns to `queued` with the same `rpcId`;
  if the read-back cannot run it stays `outcomeUnknown` and does not resend.
  Proof of absence is one follow snapshot whose inbox projection is present and does not hold
  the `rpcId`, plus that snapshot's history walked back past the entry's `createdAtMs` (or to its
  beginning) without finding it. A prompt held in the inbox is `accepted`, not absent. A snapshot
  without the inbox projection, a failed or non-advancing page read, or an unknown that has not
  yet settled (3 s, doubling per attempt up to 300 s) proves nothing. A user retry does not
  replace this proof.
- **Attachment consistency at dispatch.** Immediately before a first submit, and again before any
  retry, verify every referenced file exists and its bytes match `sha256`. On a missing file or a
  digest mismatch the host MUST NOT submit the entry, MUST NOT fall back to a text-only send, and
  MUST NOT drop or re-create it; the entry stays in its current state (`queued`, or `outcomeUnknown`
  if a previous submit's outcome is unresolved) with an internal `lastError` of
  `attachment_missing` or `attachment_digest_mismatch`. It is retried only after the reference is
  restored and verified. A previous submit is never repeated with a new `rpcId`; if the authority
  already has the `source.rpcId`, the normal `accepted`/`durable` path applies. This is an internal
  diagnostic only: the user sees no new prompt, banner or error, and "排队中" is the only visible
  state allowed for the blocked entry.
- **Ordering and crash points.** Per session the queue is FIFO by `createdAtMs`; sessions are
  independent. The five kill points — before the file write, after the write before submit,
  mid-submit, `accepted` before `durable`, `durable` before delete — must neither lose nor
  duplicate: the first shows no accepted message (the UI may not have shown it), the last two
  replay the same `rpcId`, and the authority's `source.rpcId` is the only de-duplicator. Startup
  scans `send-outbox/` and resumes `queued`/`outcomeUnknown` entries; it never invents a new
  `rpcId`. An entry whose attachment files were partially written is not resumable until the files
  are complete and digest-verified; its partial files are treated as the missing case above, never
  as inline bytes.
- **Backends.** Only `backend: local` is on the durable outbox this round. The `pc` backend keeps
  its existing pre-W1 direct path, workspace/session scope and transport; it is not crash-durable
  and is out of scope until GAP-40 defines an authoritative-history equivalent. A backend switch
  never moves an entry to a different session.
- **No UI restriction.** The queue never refuses a send for a closed admission, an engine that is
  starting, or a running turn; it accepts and shows `queued`. The only new visible state is the
  existing "排队中" (queued) projection.


### 10.1 iOS queued engine preparation

The iOS local queue may accept an already-bound session while the engine is absent, parked or
busy. Acceptance means the existing outbox entry is durable, not that execution has started.
Foreground delivery joins one preparation task and uses existing start/resume transitions.
Execution eligibility is one answer: the App is not in the background (a cold launch is still
inactive), or the process is held resident by an audio keep-alive — the chat's own or another
owner's, such as a connected TonoLink board — or the App holds a valid wake lease whose remaining
time is at least the launch threshold for the host state (§10.2). While eligible, queued work may
start, resume or deliver through the existing transitions, in foreground or background, and a
background delivery takes the chat's own keep-alive for that turn so the existing turn-end path
decides whether to park. Without eligibility a background callback alone never authorizes
WebContent boot/resume; a start refused for that reason runs at the next foreground return. Manual
recovery and explicit stop gates remain authoritative; an explicit stop pauses queued
preparation even while a boot is in flight. Foreground return retries retained queued work.
A first-ever UI send must establish a foreground session and then enqueue before submitting;
there is no durable receipt while no session or protected storage is available.
Storage availability is the result of the outbox write itself, not the lock state: a locked
phone whose outbox is writable admits durably, and queued delivery then waits until protected
data is available again (the unlock notification or the next foreground return retries it).

If execution eligibility is lost while writing the submitting marker, the same live sender
may defer an entry before calling transport, using submitting → outcomeUnknown → queued
with its original ID. This branch has direct proof that no transport attempt occurred. That
proof does not survive a crash and cannot be inferred from a saved error string; recovered
submitting/unknown entries still require authoritative reconciliation before retry.

### 10.2 Engine-first launch, wake leases and ReadySweep (P06, `engine-launch-v1`)

Status: normative, frozen by
[PC-20261120-engine-first-launch](../../../docs/protocol-changes/PC-20261120-engine-first-launch.md).
This section is language-neutral. Swift implements it first on iOS; Kotlin implements the same
closed value sets, the same constants and the same pure functions on Android, and both ends test
them by reading [golden/engine-launch.json](golden/engine-launch.json) with
[schema/engine-launch.schema.json](schema/engine-launch.schema.json) directly. A hand-copied vector
or a platform-only threshold is out of contract.

**One orchestrator.** Each platform has exactly one launch orchestrator. It owns when the engine
starts or resumes, which wake is being served, and whether a ReadySweep step may run. A wake source
(§10.2.2) records the request durably and then calls that one orchestrator; it never starts the
engine itself, never calls the Bot runtime, and never runs a sweep on its own.

**ReadySweep ownership split (fixed).** The orchestrator runs steps 1–3 itself — `userOutbox`,
`externalAdmission`, `cloudTaskPull`. `BotRuntimeComposition.runReadySweep(_:)` runs steps 4–7 —
`botHeldInbox`, `missedRoutines`, `connectorScan`, `approvalReminderSync`. The orchestrator merges
both halves into **one** `ReadySweepReport`, ordered as §10.2.5 lists them; there is no second
report and no second order. `EngineLaunchOutcome` and the report's wrapper types are app-internal:
only the `decision` values and the step/outcome vocabulary in this section are contract.

**Four stages, fixed order.** A wake runs the stages in this order and no stage invents work for
another:

| Stage | Content | Needs the engine |
|---|---|---|
| A | immediate content: restore the DSH transcript snapshot; open the Bot store and prepare the Bot composition without a host; render the roster and the persisted Bot rows (including held inbox and device-task results already written); scan the send outbox and the admission journal; pull cloud tasks | no |
| B | ensure the engine: one idempotent boot/resume decision (§10.2.4) | — |
| C | bind consumers in the existing order: Bot composition starts on the host, the DSH session adopts it, the MCP listener is checked | yes |
| D | ReadySweep (§10.2.5) | yes |

Stage A must finish before anything waits on the engine: the Bot page shows persisted content and
the chat shows its snapshot even when the engine never becomes eligible.

**Launch gating is not tab selection.** The local phone engine starts at launch, silently, when the
app is on the phone backend, or at least one Bot exists, or the send outbox or the admission journal
holds pending work. A UI segment or tab is never the only gate for Bot work; the PC relay keeps its
existing path.

#### 10.2.1 `WakeReason` (closed)

`WakeReason` is a closed enumeration. A new transport adds a value only through a contract revision
that also updates the golden; a free-form string is invalid and is rejected, never coerced.

| Value | Origin | Lease source |
|---|---|---|
| `coldLaunch` | process start | none (a cold launch is still `inactive`, §10.1) |
| `foreground` | scene becomes active / foreground return | none (foreground eligibility) |
| `unlock` | protected data became available | none; eligibility still needs foreground, keep-alive or a lease |
| `cloudTaskPush` | background push callback | `beginBackgroundTask` / the callback's granted time |
| `boardWake` | connected TonoLink board | existing resident audio / `bluetooth-central` |
| `bleRequest` | another trusted BLE device | existing resident audio, or a granted background task |
| `lanRequest` | LAN device, TonoLink relay or Bot MCP HTTP listener request | `beginBackgroundTask` while the process is resident; unreachable while suspended |
| `pcLinkRequest` | PCLink relay request | `beginBackgroundTask` while the process is resident |
| `bgProcessing` | `BGProcessingTask` / one-shot background worker | the task's expiration handler |
| `routineNotificationTap` | user taps a routine-due local notification | none (user interaction = foreground) |
| `engineRecovered` | the existing recovery finished | none |

#### 10.2.2 `WakeSource` adapters

One adapter per channel. An adapter does exactly three things:

1. receive the request and write it durably first — the external admission journal, the send outbox
   or the Bot wake inbox as that channel already requires — before any engine action;
2. call the one orchestrator with the `WakeReason` and the lease it was granted (or `nil`);
3. return without starting the engine, calling the Bot runtime or running any sweep.

The existing Bot-side `WakeSignalSource` is the Bot-channel adapter interface and is reused, not
duplicated. Adapting a push, a board, a LAN/Bot MCP listener or a PCLink request is the host's job;
the adapter never becomes a second launch path.

**iOS reachability (platform fact, not a new feature).** Once the App is suspended, a local LAN
listener receives no connection and BLE can wake it only through a registered restorable
connection. A remote peer that cannot reach the phone therefore retries through the cloud task
queue ([cloud-tasks.md](../../v1/cloud-tasks.md) §8) which wakes the phone with a background push.
Reachability and the fallback decision belong to the requester; the phone adds no listener and no
keep-alive for this.

#### 10.2.3 `WakeLease`

```json
{"wakeId":"<lowercase UUIDv4>","reason":"cloudTaskPush","grantedAtMs":0,"deadlineMs":30000}
```

`wakeId` is generated once per wake. `deadlineMs` comes from the system, never from a fixed budget:
the remaining background time, a `BGTask` expiration handler, or the Android worker's stop signal.
`remainingMs = deadlineMs − now` at the point of the check. A missing lease is `null`; a negative
remaining value is invalid input.

**Thresholds (provisional constants).** These are contract constants, not tuning knobs scattered in
code. They are provisional values and are re-measured on a real device by the `ios-wake-spike`
tool; a change is a contract revision, never a local edit.

| Constant | Value | Meaning |
|---|---|---|
| `minLeaseForColdBootMs` | `20000` | with no host (or a failed host), the lease must leave at least 20 s |
| `minLeaseForResumeMs` | `8000` | with a parked host, the lease must leave at least 8 s |
| `parkMarginMs` | `5000` | park the host and end the background task this long before the deadline |

#### 10.2.4 Decision function

`EngineLaunchPolicy.decide(reason, foreground, residentAudio, hostState, leaseRemainingMs,
userStopped, needsReset)` is pure and total over the decision input in the golden. `hostState` is
one of `absent`, `parked`, `running`, `failed`. The result is one of `boot`, `resume`, `ready`,
`nativeOnly`, `defer`, `needsAttention`, evaluated in this order:

1. `needsReset` is true → `needsAttention`. This is the existing fail-loud reset path; a silent
   retry is forbidden.
2. `userStopped` is true → `defer`. An explicit stop is authoritative for every reason; queued work
   is retained and retried when the gate clears.
3. `hostState == running` → `ready`. The engine is already usable; a short lease does not stop it,
   it only limits ReadySweep steps.
4. `eligible = foreground || residentAudio || (leaseRemainingMs != null && leaseRemainingMs >=
   requiredLease)`, where `requiredLease` is `minLeaseForResumeMs` for `parked` and
   `minLeaseForColdBootMs` for `absent` and `failed`.
5. not eligible → `nativeOnly`. Stage A still runs; one deferred wake is scheduled
   (`BGProcessingTask` on iOS, a one-shot worker on Android).
6. `parked` → `resume`; `absent` or `failed` → `boot`.

`reason` selects the lease source and is recorded for diagnostics; it does not add a branch. A
wake that cannot boot never drops a request: the request is already durable in the journal, the
outbox or the wake inbox, and the next eligible wake executes it. A `failed` host goes through the
existing backoff/recovery; only `needsReset` asks for the user.

#### 10.2.5 ReadySweep (seven steps, once per wake)

After stage C the orchestrator runs the sweep in this fixed order:

| # | Step | Content |
|---|---|---|
| 1 | `userOutbox` | drain the user's queued send-outbox entries (highest priority) |
| 2 | `externalAdmission` | one external-admission dispatch pass for records already admitted |
| 3 | `cloudTaskPull` | pull → admit → ack cloud tasks; skipped when this wake already pulled successfully within `cloudPullFreshnessMs = 30000` |
| 4 | `botHeldInbox` | replay durable Bot held-inbox items whose confirmation event is absent |
| 5 | `missedRoutines` | catch up enabled routines whose `nextRunAt` is due; several missed slots collapse into one run |
| 6 | `connectorScan` | metadata-only Gmail/GitHub delta scan by the persisted cursor, then a `connectorUpdate` held item |
| 7 | `approvalReminderSync` | reconcile the approval-reminder projection with the durable pending approvals |

**Step gate.** Immediately before a step, `ReadySweepPolicy.shouldRun(step, remainingMs)` decides
`run` iff `remainingMs >= parkMarginMs + stepBudgetMs(step)`. The per-step budgets are provisional,
like the three thresholds above:

| Step | `stepBudgetMs` |
|---|---|
| `userOutbox` | 2000 |
| `externalAdmission` | 2000 |
| `cloudTaskPull` | 5000 |
| `botHeldInbox` | 2000 |
| `missedRoutines` | 5000 |
| `connectorScan` | 10000 |
| `approvalReminderSync` | 1000 |

A step that does not run is `skipped` with one of the closed reasons below, is left for the next
wake, and is never half-run: each step either completes its durable write or leaves no partial state for the next
wake to misread. A step that fails records `failed` with an internal reason and does not abort the
remaining steps; it is retried by the next wake. Step results are the closed vocabulary
`ran | skipped(reason) | failed(reason)`; `skipped` reasons are `lease`, `already-pulled`,
`no-work` and `gate` (a user gate such as explicit stop), and no step failure presents a
user-visible error by itself.

**Idempotency.** Each step is idempotent: the outbox reuses its `rpcId` (§10), admission reuses
`admissionId`/`downstreamId` ([external-admission.md](external-admission.md) §3), cloud pull and ack
are lease-based and first-wins ([cloud-tasks.md](../../v1/cloud-tasks.md) §5), the held inbox
reuses `requestId` (bot v2), a routine catch-up writes one run per due schedule and collapses
several missed slots into one, the connector scan advances its cursor only after the held item is
durable (write-before-enqueue) and dedupes by connector plus cursor interval, and the approval
reminder sync reconciles a projection instead of appending.

**Once per (`engineIncarnation`, `wakeId`).** `engineIncarnation` is a monotonically increasing
integer owned by the orchestrator; it increments when a new host instance is adopted (boot or
resume) and is stable while that host runs. The sweep for one pair runs at most once. A second wake
that arrives while the first is in flight is merged: it does not boot again, does not queue a second
sweep, and awaits the first sweep's report. Different `wakeId`s serialize; a wake during boot is
merged into the boot, not replayed after it.

#### 10.2.6 Silent-start visibility

- A boot or resume initiated by the orchestrator writes **no** transcript status line (including
  `Booting the Worker…` and any host-stage line) and presents **no** error. A failure follows the
  existing backoff/reset path silently. Only a user action that is waiting on the engine and
  ultimately fails uses the existing error path and its existing copy.
- Stage A content is shown while the engine is absent: the Bot page renders the roster and the
  persisted rows that already exist; it never shows an engine-waiting prompt. The deleted
  `请先启动引擎` waiting copy (PC-20261120-engine-first-launch) must not be reintroduced.
- A skipped or failed ReadySweep step adds no visible row, banner or notification. Proactive
  delivery keeps its own rules (bot v2 §3); the sweep only produces the inputs.

## 11. External admission journal (P06)

A request that arrives from outside the composer is admitted into a native journal before any
owner executes it. Identity, dedupe, stages, limits, storage and shared vectors are frozen in
[external-admission.md](external-admission.md) (`external-admission-v1`, `target`). It links to
the §10 outbox by `downstreamId`; it does not replace it.
