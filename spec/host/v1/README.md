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
| persistent external ingress queue (at-least-once, `request_id` dedupe, parked while the app is not running) | host behaviour above this contract; a connector must not write the WAL directly | `PLAN` §13.7 row J2 |
| tool-registry change while a worker runs (`registerTools()`) | belongs with the worker restart policy in `spec/v1` | `PLAN` §13.7 row J3 |
| a device command channel inside the worker protocol | two candidate designs, undecided | `PLAN` §13.7 row J4 |
| media port and the second foreground-service type | platform slice, `spec/platform` | `PLAN` §13.7 row J5 |
| per-device audio stack (BLE, codec, buffering, ASR) | protocol-specific implementation work | `PLAN` §13.7 row J7 |

## 10. Durable send outbox (P06, W1)

The UI→host send path is host behaviour above the worker contract (§9 row J2 is the *ingress* queue
for device commands; this is the user's outgoing message queue and has its own boundary). For all
backends it is one durable queue with the same observable rules.

- **Enqueue is the durable fact.** A send creates one entry and writes it with the §7 atomic order
  (temp file, fsync, rename, directory fsync) **before** any transport attempt. The entry is
  shown immediately as `queued`; a transport failure never removes it and never loses the user
  text. The file is `send-outbox/<rpcId>.json`, unique per `rpcId`.
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
- **Ordering and crash points.** Per session the queue is FIFO by `createdAtMs`; sessions are
  independent. The five kill points — before the file write, after the write before submit,
  mid-submit, `accepted` before `durable`, `durable` before delete — must neither lose nor
  duplicate: the first shows no accepted message (the UI may not have shown it), the last two
  replay the same `rpcId`, and the authority's `source.rpcId` is the only de-duplicator. Startup
  scans `send-outbox/` and resumes `queued`/`outcomeUnknown` entries; it never invents a new
  `rpcId`.
- **Backends.** `backend: local` and `backend: pc` use the same entry shape and machine; the PC
  path keeps its existing workspace/session scope. A backend switch never moves an entry to a
  different session.
- **No UI restriction.** The queue never refuses a send for a closed admission, an engine that is
  starting, or a running turn; it accepts and shows `queued`. The only new visible state is the
  existing "排队中" (queued) projection.
