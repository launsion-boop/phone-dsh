# Device-initiated DSH tasks, v1

Status: `target`. This contract coordinates the device inbox, the phone's durable task executor, and DSH. It uses the existing P07 DeviceEnvelope and the host harness; it does not define a replacement envelope. BLE and LAN devices submit goals to their own local inbox; the phone initiates the connection and consumes that inbox after explicit user authorization.

## Trust and routing

The user explicitly enables device-originated DSH tasks for each authenticated connection. The default is disabled. Disconnect or revocation stops intake. LAN authorization explicitly covers the derived HTTPS `/tasks` path as well as the existing `/mcp` endpoint; credentials never enter the Worker, model, broadcast, or logs. The LAN host and port must be the same as the selected MCP endpoint, normal TLS hostname verification is mandatory, redirects are rejected, and a changed endpoint or credential revokes the task grant. BLE intake is carried only by the authenticated session of [ble-secure-session.md](ble-secure-session.md) (`secure-session-v1`, `target`): an offline-enrolled phone/device key pair, a mutually authenticated TLS 1.3 session over LE CoC and a successful readiness exchange; its device identity is the enrolled device key fingerprint. LE bonding or encryption, the ordinary Link connection, device names, advertised capabilities, characteristic presence and `requester` are untrusted labels or claims, never authentication. Until both ends implement that frozen revision and its physical acceptance is recorded, the iOS adapter MUST refuse all BLE task grants and leave task support unavailable; see GAP-16. Ordinary BLE tools remain governed by their own profile.

The reference firmware's ordinary Link ingress denies plaintext BLE task
requests as specified in `ble-link.md`, independently of client claims. This
denial is permanent (`ble-secure-session.md` §11): no negotiation or error ever
falls back to plaintext task access. Locally submitted tasks and existing NVS
records are retained; submission does not mean that a phone received or
accepted a task. The denial does not authenticate or migrate legacy receipts.

The separate [legacy inspection contract](legacy-task-inspection.md) defines
the limited, read-only local inspection of old phone records; it is not task
intake, authenticated recovery or authorization to replay.

A task's authenticated `device_id` comes from the connection, never from task text. The phone maps it to its device session. For a device/idempotency-key pair, `msg_id` is lowercase SHA-256 of UTF-8 device ID, a zero byte, then UTF-8 idempotency key. It is used in a P07 uplink envelope with `origin=device`, `dir=up`, `kind=text`, a host-assigned persistent monotonically increasing per-device sequence, the mapped session ID, and the goal text. The harness request ID is exactly `dev:` plus that `msg_id`. The host records this mapping durably; device text is never promoted to system instructions. Session and source attribution must be retained independently of message text.

For LAN, the connection identity is `lan:` followed by lowercase SHA-256 of the UTF-8 exact selected MCP URL. It is meaningful only after the HTTPS connection has authenticated the host and accepted its credential; it is not an identity claimed by discovery or task content. An endpoint or credential change requires a new explicit grant. Grant state is in memory, defaults off and ends on disconnect, revocation or app suspension.

An intake grant is scoped to one non-reusable connection generation, including
while an asynchronous start is pending. Revocation invalidates that generation
before waiting for its start or stop to finish. Once revocation returns, no
intake worker belonging to that generation may remain, even when the start reaches
the intake after revocation began. Cleanup of an old generation must not stop,
remove, or restore the grant of a later generation, including when two UI
entries map to the same device identity. A later start may fail busy while an
old job is still stopping; it requires a fresh user action to retry. The app's
late completion or stop notification from an old generation cannot alter the
new one; app cleanup uses the captured generation, not an unscoped stop.
In particular a connection-monitor result returned after an await must still
own the same generation before it can revoke that generation.
An attempt that returns busy never owns the incumbent job and its failure
cleanup must not stop or change it. The incumbent occupies its device identity
until its worker has actually finished, not merely until
cancellation was requested. No retry is scheduled for a busy attempt. App
suspension invalidates and cancels all active or starting generations before
awaiting any one stop. A job that does not finish on cancellation remains
stopping and busy; no timeout may treat it as finished or admit an overlap.
After the worker exits, its `onStopped` notification runs independently and
may complete after the stop call and a later generation's start. The app's
notification closure captures the old generation and must not change the
later generation. The existing public `onStopped` signature carries no token;
an arbitrary caller can explicitly call the legacy `stop(deviceID:)` or
`stopAll()` from it, which acts on current workers, including a newer one.
Those unscoped operations are not generation-safe and must not be used for
app cleanup of an old grant. Stops wait for
workers, not notifications, so callbacks may stop their own or other devices
without workers and notifications waiting on each other. This changes the
waiting behavior of public Swift stop calls while preserving their source
signatures. A worker's own `next` or runner must not synchronously await a stop
that joins that same worker; requesting cancellation is not proof of completion.
Cancellation does not prove that a task submitted before cancellation had no
effect; its existing journal and unknown-outcome rules remain in force. The
shared `golden/task-grant-generations.jsonl` cases describe these ordering
requirements. This does not enable BLE tasks or change the target status.

A device-origin session starts with no model-callable tools: the Worker must create it with a dedicated scoped preset that hides all global tools and denies all tool execution, including future registrations and scoped tools. A missing, changed or unverified isolation preset fails closed before prompting. The host verifies `session/create` and `session/projections` select `pdsh-device-task` and verifies the UTF-8 `agentPresets/read` document SHA-256 equals `fee91c0e29e6cde569076ee899b32935fda12bdb3824501cca58b5b233a12887`. A separate global Worker guard denies all tool execution when the immutable session header records `agentPreset=pdsh-device-task`, even if a blank session is recomposed to a different preset between verification and prompt. The guard and scoped restriction must both be installed before task intake is enabled. This profile does not grant phone or device control tools to the task; adding per-device tool grants requires a later contract revision. A static system-level policy may identify the session as device-originated. Tool results, permission requests and question requests are never sent to the device. Only the final assistant text or an explicit terminal failure is returned. No background availability is promised while iOS suspends the app.

Immediately before creating a session and before every prompt, the host checks the existing `phone/pluginList` inventory for exactly one `include:device-task-guard` entry whose module is `@phone-dsh/dsh-lifecycle-gate/device-guard`, enabled is true and fiber phase is `active`. Missing inventory, duplicate or non-active entries fail closed. This inventory check is in addition to the preset document and session checks; it adds no Remote method.

## Task and result

The device sends a JSON task with `id`, `idempotency_key`, `requester`, `created_at`, optional `deadline`, and `body={"type":"goal","text":...}`. `id` and `idempotency_key` are 1–64 ASCII characters, starting with an ASCII letter or digit and continuing with `[A-Za-z0-9._:-]`; text is 1–768 UTF-8 bytes and may contain printable characters, newline, carriage return or tab only. `requester` is a display label of 1–128 UTF-8 bytes and contains no Unicode control or format characters. Times are calendar-valid RFC 3339 UTC timestamps using ASCII digits and ending in `Z`, with at most three fractional second digits; if supplied, `deadline` must be a timestamp (not null) later than `created_at`. The phone enforces the earlier of the declared deadline and five minutes after durable acceptance. The received-state journal deadline is provisional; after the device confirms acceptance, the phone records the accepted state and recomputes the five-minute bound in the same durable update, before any DSH prompt. Devices lacking a real-time clock omit `deadline`; their `created_at` is informational. Unknown task members are ignored, but duplicate object member names at any depth (compared as decoded Unicode scalar sequences, without normalization), a NUL, or an unpaired Unicode surrogate in any string or object key anywhere in the task are rejected before decoding, and unknown body types are rejected as unsupported. No binary/media or arbitrary instructions fields are accepted as authority.

The raw task must be UTF-8 without a byte-order mark and use valid JSON number,
literal and string syntax at every
depth, including ignored members. An ignored numeric value has no additional
numeric range or precision requirement: consumers may validate its syntax
without converting it to a platform numeric type. This does not relax the
requirements on known task fields or the enclosing transport's size limits.
`golden/task-raw-bytes.jsonl` encodes input as hex so invalid UTF-8 vectors
reach every real decoder unchanged.

Before acknowledging acceptance or sending a prompt, the phone atomically persists the authenticated device identity, task ID, key, content fingerprint, request ID, session ID, deadline and state. The same device/key and same task is deduplicated; a conflicting body or task ID is rejected. A key on another device is a distinct task. At most one task per device is running, with a bounded store of 4096 records; full storage rejects new work instead of forgetting deduplication evidence. A terminal result is persisted before reporting and retried to the device until acknowledged. The device must treat an identical terminal report as idempotent and reject a conflicting report.

An accepted request is not an executed task. While running, loss of connection does not start a second DSH turn. On phone restart, any accepted or running task whose outcome is not provably recorded is reported as `unknown_outcome`, not replayed; no cancellation, timeout or dropped connection proves that an action did not happen. If a task expires before prompt submission it is `expired`; after submission an unconfirmed timeout is `unknown_outcome`. The phone may cancel a timed-out session, but still reports `unknown_outcome` unless a definitive outcome is obtained. Completion reports only final assistant text, capped at 1024 UTF-8 bytes without breaking UTF-8; truncation is explicit. Output and failure messages cannot contain NUL. If model output contains NUL, the phone reports a `failed` outcome instead of a completion. Failure kinds are `denied`, `unavailable`, `expired`, `failed`, `unknown_outcome`. Permission or question requests are not forwarded to the device; they fail closed if the task cannot proceed under the isolated preset.

## Phone journal format

The host stores one UTF-8 JSON file named `<msg_id>.json` per operation in an application-private directory, plus an exclusive lock. Version 1 has required `v:1`, `device_id`, `task` (the validated known task fields), `fingerprint` (lowercase SHA-256 of the sorted-key UTF-8 JSON encoding of the known task), `msg_id`, `request_id`, `seq`, `session_id`, `phase`, and `deadline_ms` (integer Unix milliseconds). `phase` is `received`, `accepted`, `running`, or `terminal`. Terminal records additionally carry `outcome`: either `{kind:"completed",output:string,truncated:boolean}` or `{kind:"failed",failure_kind:<failure kind>,message:string}`; the failure message is bounded to 256 UTF-8 bytes. Optional unknown object members are ignored. Unknown version, phase, invalid state, inconsistent identity, corrupt data or unreadable journal fails closed, never starts a task or overwrites the file. The journal writer holds the exclusive directory lock for its lifetime; an atomic file replacement and synchronized file and directory are required before the corresponding accept, prompt or terminal report. Sequence is allocated from the maximum stored sequence for that device and starts at 1. No record is evicted automatically; rollback preserves the directory.

## LAN binding

The authorized phone opens HTTPS `GET /tasks` on the same origin as `/mcp` with the existing host-managed device bearer credential. The server rejects unauthenticated connections before returning data. It returns `text/event-stream`; each `event: task` contains one JSON task, and it redelivers every unfinished task on reconnect. A heartbeat comment at least every 30 seconds is recommended. The phone limits an SSE line to 8192 bytes, an event to 4096 bytes and unacknowledged in-memory tasks per device to one; malformed or oversized events close the stream. It sends `POST /tasks/<id>/accept`, `.../complete` and `.../fail` with JSON bodies, only after the relevant journal state is durable. Complete carries `{"output":"...","truncated":false}`; fail carries `{"failure":{"kind":"...","message":"..."}}`. The ID path segment uses URL encoding, no query, and no redirects. A duplicate matching terminal result is acknowledged with 200/204 or 409; a conflicting result is rejected with 422 and must not overwrite the original. A 409 is reserved for a matching terminal report. The existing relay task inbox protocol is the input to this binding; this in-repository revision is the authority for phoneDSH.

## BLE binding

The BLE binding is `ble-secure-session.md@secure-session-v1` (`target`): its
`next`, `accept`, `complete`, `fail` and `status` messages carry the task
representation, outcome bodies and terminal semantics of this document inside
the authenticated session, and its §9 defines the BLE device identity, the
secure transition intents (`ble-secure-ops`) and lost-reply recovery. The
**BLE task identity is `ble:` + lowercase hex SHA-256 of the enrolled device's
65-byte uncompressed P-256 public key**, i.e. the session's device ID; it is
used unchanged as the journal `device_id` and in the `msg_id` derivation
above. It replaces the earlier `ble:<Link UUID>` form, which is now `legacy`.

### Legacy Link task binding (`legacy`, permanently refused)

The rest of this section records the earlier plaintext Link task binding so
that its persisted data stays readable. It is never used for new work: the
reference firmware refuses these tool calls on ordinary Link ingress, the
phone never sends them, and no record below is dispatched, reported, resent,
converted to the fingerprint identity or attributed to an enrolled key
(`ble-secure-session.md` §11.4).

A Link device with Tools v1 negotiation, the current HELLO `PDSH_TASKS` app capability (bit11), and the listed task tools may expose `pdsh.task.next`, `pdsh.task.accept`, `pdsh.task.complete`, `pdsh.task.fail` through its existing `tools/list`. No new BLE opcode or envelope is used. `next` takes `{}` and returns `{ "task": <task or null> }` in the normal Link completed result. `accept` takes `{ "id": "..." }`; `complete` and `fail` take the same bodies as LAN plus `id`. The device persists its task until a terminal report, supports repeated reads and deduplicates repeated reports. The phone polls only while connected and authorized; Link events are hints and carry no delivery guarantee. The full encoded Link logical request/result, not just text, must fit its existing 4096-byte limit. Devices without all four tools are unsupported for task submission and never receive them. Reserved task tools are host control-plane operations and must not be offered as ordinary model-callable device skills.

In legacy records the BLE task `device_id` in task journals and transition intents is `ble:` followed by the lower-case Link `device_id` UUID returned by the negotiated Link `tools/list` (enforced by `Sources/PhoneDSHDeviceTasks/BLETaskIntent.swift` and `schema/ble-task-intent.schema.json`), not the CoreBluetooth display name or discovery identifier. That UUID is a device-claimed label, not an authenticated identity. The fingerprint form defined above is a different string; no mapping or migration between the two forms exists or may be added, and a legacy UUID-labelled journal record or intent is never treated as authenticated or replayed automatically. `pdsh.task.next` is read-only and consumes no persistent Link receipt; each of the other three calls is a side effect governed by the existing BLE Link durable-intent, result-query and no-replay rules. Before the first upload of each task transition, the phone must durably persist its Link request UUID, idempotency key, argument fingerprint and authenticated device identity. After a crash or lost reply the phone may query that UUID; a missing or unknown Link receipt never authorizes re-upload. An unresolved transition remains unresolved and the task is not dispatched or reported as successful. The device's existing bounded Link receipt ledger can fill, at which point new mutations fail closed. The task binding does not silently evict or reset it.

The transition intent journal lives in the task journal's `ble-ops` subdirectory and is covered by the same exclusive directory lock. One UTF-8 JSON file named `<msg_id>-<action>.json` holds `v:1`, `msg_id`, `device_id`, `task_id`, `action` (`accept`, `complete`, or `fail`), `request_id`, `idem_key`, and `arguments_sha256`. Before the first upload the file is atomically installed and synchronized with its directory; a pre-existing file is verified and followed only by a Link result query. A crash between persisting the file and upload may therefore leave a task unresolved; it must not be replayed. Corrupt, mismatched, unreadable or unknown-version records fail closed. The parent task journal is retained across rollback.

For a transition, let `digest` be SHA-256 of UTF-8 `phoneDSH BLE task v1`, NUL, the lowercase hexadecimal task `msg_id`, NUL, and the ASCII action. `idem_key` is the lowercase hex digest. The request UUID is formed from the first 16 digest bytes with UUID version bits set to 5 and variant bits set to RFC 4122, formatted lowercase. `arguments_sha256` is SHA-256 of the UTF-8 compact JSON encoding of the exact Link args with object keys sorted and non-ASCII characters preserved. The shared `schema/ble-task-intent.schema.json` and `golden/ble-task-link-ops.jsonl` define valid and invalid records; the derivation and payload checks are semantic requirements in addition to the schema. A result report uses the terminal outcome already persisted in the parent journal; it cannot be changed after the intent is created.

On legacy reference firmware (task store v1; superseded by task store v2 in `ble-secure-session.md` §10 once implemented), `next` returns the oldest nonterminal task or null. Successful `accept`, `complete` and `fail` return an empty result object with Link status `completed`. An unknown task, an invalid transition, or a conflicting terminal outcome returns Link status `failed`; an identical terminal transition is idempotent. The firmware stores up to four lifetime task records under NVS key `tasks_v1`, as a UTF-8 JSON object with `v:1` and `slots` array. Each slot has `task` containing only the known task members and `phase` (`queued`, `accepted`, `completed`, or `failed`); completed and failed slots also contain the exact corresponding terminal `outcome` body excluding `id`. The producer submits locally through the firmware API; it does not create a network listener. The local `tools_task_result(id)` returns a newly owned JSON object with `phase` and, only for a terminal task, `outcome`; unknown ID or unavailable storage returns null. A repeated matching task ID and idempotency key is idempotent, while reuse with changed content or reuse of either identifier for a different task fails. Full storage rejects submission and never evicts history. An unreadable, malformed, inconsistent or unknown-version store disables task submission and task transitions rather than clearing it. Each mutation commits NVS before returning success. `schema/ble-task-store.schema.json` and `golden/ble-task-store-cases.jsonl` define the persisted structure; transition, identity and terminal body semantics are validated in addition to the schema. The reference's finite task and Link receipt limits are independent; both can stop new work and neither is silently reset.

## Compatibility and evidence

Older devices omit task tools or return 404 for `/tasks`; the phone leaves task intake unavailable without changing their existing tools. Older phones do not declare `PDSH_TASKS`, so a new BLE device hides and refuses task control tools and retains ordinary Link behavior; devices must not infer task acceptance without an explicit accept response. New peers use the same task representation and terminal semantics over their negotiated binding. Existing P07 envelope/receipt schema and old persisted data remain readable; new task journals are additive. Rollback must keep the journal, and cannot re-execute or abandon an unresolved operation as if it failed.

`schema/task.schema.json` defines the shared task shape; semantic UTF-8, timestamp, identity and state-machine rules above are normative. `golden/task-cases.jsonl` contains valid and invalid producer inputs. Both device and phone implementations must consume the same fixtures, and tests must cover unauthorized devices, duplicate/conflicting deliveries, persistence before accept, cancellation, crash after submission, duplicate completion, timeout, reconnect and isolation of device-originated model tools. Static schema checks alone are not runtime conformance.

## Legacy BLE intent inventory (target recovery)

Before task records are used for any device, the phone must inventory the whole
`ble-ops` directory under the task-journal lock, not only the file selected by
an incoming device label or task. Absence of this directory means no BLE
intents. If present it must be a real directory, not a symbolic link; it may
contain at most 12288 entries (three possible actions for each of 4096 task
records), all regular non-symlink intent files, each at most 65536 bytes.
Unreadable paths, directories, symbolic links, extraneous entries, duplicate
JSON keys, malformed or unknown-version data fail the whole inventory closed.
No inventory result authorizes a task, proves the historical device key,
imports a trust record, changes a journal or establishes an old receipt's
origin. The on-disk format and derived identifiers above remain unchanged.

Before writing a new transition intent, the phone must reconstruct the
arguments from the parent and reject any mismatch; a valid inventory alone must
not allow inconsistent caller arguments to be persisted or uploaded. Each
intent must name exactly one validated parent record, match that record's
BLE UUID, task ID, action and canonical `<msg_id>-<action>.json` filename, and
match the request UUID, idempotency key and argument hash re-derived using the
existing rules. Accept arguments are `{id}`. Complete and fail arguments are
reconstructed solely from the corresponding already-persisted terminal parent
outcome; a missing or different terminal outcome fails closed. The exact key
set must match the existing intent schema. An orphan, changed identity,
conflicting arguments or corruption blocks inventory for all device labels:
the data is retained and unresolved, never deleted, silently migrated or
replayed. Existing valid v1 intents remain query-only. Invalid or unprovable
history requires an explicit future recovery decision; this inventory does not
make the existing unauthenticated plaintext RESULT a trustworthy receipt.
`golden/ble-task-inventory.jsonl` enumerates the shared valid and invalid
inventory scenarios; tests must use real journal records and intents.

When reading an existing phone task record, validate the original encoded
`task` value before a JSON decoder can discard any member. Preserve valid
UTF-8, UTF-16 and UTF-32 JSON encodings accepted by the platform's existing
record decoder, including its supported initial encoding markers; lossless
text transcoding is allowed, but decoding to an object and re-encoding it is
not. Reject malformed JSON syntax or invalid Unicode scalars anywhere in the
record, including unknown outer values. Each known top-level record member
(`v`, `device_id`, `task`, `fingerprint`, `msg_id`, `request_id`, `seq`,
`session_id`, `phase`, `deadline_ms`, `outcome`) may occur at most once, and
`task` must occur exactly once. Within an `outcome` object each known member
(`kind`, `output`, `truncated`, `failure_kind`, `message`) may occur at most
once regardless of outcome kind. Compare names as decoded Unicode scalar
sequences without normalization; escaped spellings count as the same name.
Unknown outer and outcome members retain their existing duplicate-name policy.
The original task bytes must satisfy the task rules in § Task and
result, including unknown nested members, duplicate names and NUL rejection;
valid unknown task members remain ignored. An ambiguous or invalid record or task makes
the journal corrupt, without rewriting or deleting evidence, acknowledging a
task, or replaying an operation. Other valid top-level record members keep
their existing compatibility policy. `golden/task-raw-json-cases.jsonl` is also
used as embedded-task input to the real journal inventory tests;
`golden/ble-task-inventory.jsonl` covers the parent-member ambiguity and
existing outer unknown-member behavior. This validation alone does not
authenticate the historical source or resolve old BLE receipts.
