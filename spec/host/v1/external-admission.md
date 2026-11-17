# External admission journal (P06)

Revision `external-admission-v1`, frozen 2026-11-16. Status: `target` — no end is implemented
yet; do not claim it until each end has runtime evidence. Change record:
[PC-20261116-external-admission](../../../docs/protocol-changes/PC-20261116-external-admission.md).

This fills README §9 row J2 for the phone host. A request that arrives from outside the
composer — a TonoLink voice command, a task fetched from the phone task queue
([cloud-tasks.md](../../v1/cloud-tasks.md)) — is first written to a native journal, and only
then handed to the owner that executes it. The journal records **that the request was admitted
and which downstream id carries it**. It does not execute anything, does not copy conversation
history, and does not replace the send outbox (§10), the Bot wake inbox or the Bot effect ledger.

Shape: [admission-record.schema.json](schema/admission-record.schema.json). Shared behaviour
vectors, read by every end's real decoder and state machine:
[fixtures/external-admission-v1.json](fixtures/external-admission-v1.json).

## 1. Record and identity

- `principal` is who the request is attributed to: `local` (the person holding the phone; a
  TonoLink board is not an authenticated principal, GAP-16) or `account:<tono user id>`.
- `source` is the adapter that received it: `kind` plus the adapter's own stable `id`
  (`tonolink-voice`: lowercase hex SHA-256 of the UTF-8 board name; `cloud-task`: the phone's
  registered `device_id`).
- `sourceRequestId` is the request id chosen by the source and repeated on every redelivery.
- `admissionId = lowercase_hex(SHA-256(principal ‖ 0x00 ‖ source.kind ‖ 0x00 ‖ source.id ‖ 0x00 ‖
  sourceRequestId))`, all UTF-8. It is the only dedupe key and the file name.
- `target` is fixed at admission: `{kind:"dsh-session",sessionId}` or `{kind:"bot",botId}`.
  Delivery never re-reads "the currently selected chat".
- `contentSha256 = lowercase_hex(SHA-256(UTF-8 text))`. `text` is 1–16384 UTF-8 **bytes**
  (the schema bounds characters; the byte bound is a law in the vectors).
- `downstreamId` is a lowercase UUIDv4 generated at admission and immutable. It is the send-outbox
  `rpcId` for a `dsh-session` target and the user-action nonce for a `bot` target. Every delivery
  attempt of this record uses it; a new id is never minted for a retry.
- `expiresAtMs − now` at admission must be within 1 000 … 604 800 000 ms (7 days).

## 2. Admission

Admission is one decision followed by one atomic write. The result is one of:

| Result | Condition | Effect |
|---|---|---|
| `invalid` | a field breaks the schema or the byte / TTL law | nothing written |
| `duplicate` | a record with this `admissionId` exists (any stage, including terminal) and its `target` and `contentSha256` equal the request's | nothing written; the existing record is the receipt |
| `conflict` | same `admissionId`, different `target` or `contentSha256` | nothing written; the existing record is never overwritten |
| `capacity` | 256 pending records (`admitted` or `dispatching`) already exist, or the directory already holds 2048 entries of any kind | nothing written; the source keeps the request |
| `storage` | the write failed | no receipt |
| `admitted` | otherwise | record written with `stage: admitted`, `attempts: 0` |

Checks run in the order of the table. A durable receipt exists only for `admitted` and
`duplicate`; it carries `admissionId`, `downstreamId` and the current `stage`, never a bare
boolean. A source must not be told "received" for any other result. Storage availability is the
result of the write itself, not the lock state (same rule as §10.1).

## 3. Stages

`admitted → dispatching → linked → completed | failed | unknown`

| Edge | Allowed when |
|---|---|
| `admitted → dispatching` | immediately before the downstream write; the stage is durable first |
| `dispatching → linked` | the downstream owner durably holds `downstreamId` |
| `dispatching → admitted` | the same live sender saw the downstream write fail definitely; `attempts += 1`, `nextAttemptAtMs = now + min(3000·2^(attempts−1), 300000)` |
| `admitted → expired` | `now ≥ expiresAtMs` |
| `admitted → cancelled` | the source or the user withdrew it, the target was deleted, or the account of an `account:` principal signed out |
| `admitted → failed`, `dispatching → failed` | the downstream owner refused definitely (`target_missing`, `not_authorized`), or `attempts` would exceed 12 (`retry_exhausted`) |
| `linked → completed`, `linked → failed` | the downstream owner reports the terminal outcome of the work started by `downstreamId` |
| `linked → unknown` | no such report by `admittedAtMs + 1 209 600 000` ms (14 days), or the downstream owner can no longer attribute it |

No other edge exists and no edge leaves a terminal stage. `text` is removed in the same write
that leaves the pending stages. Waiting for execution conditions (engine not eligible, Bot unit
not started, phone locked) is **not** an attempt and changes nothing in the record.

A `dispatching` record found after a restart has no proof either way. It is resolved by
repeating the downstream write with the same `downstreamId` — the downstream owner
de-duplicates by that id (§10 `rpcId`; Bot user-action nonce) — and never by expiring,
cancelling or re-admitting it.

`completed` requires the downstream owner's own terminal evidence: for a `dsh-session` target,
the authoritative history holds a `user_message` whose `source.rpcId` equals `downstreamId` and
that message's turn reached its normal terminal event; a failed or cancelled turn is `failed`.
A `bot` target has no contract-defined terminal read-back yet: such a record stays `linked`
until the 14-day rule makes it `unknown`. `linked` is never reported as executed.

## 4. Dispatch, sweep and limits

- Dispatch is sequential, FIFO by (`admittedAtMs`, `admissionId`), at most 16 records per pass,
  skipping records whose `nextAttemptAtMs` is in the future. Immediately before each dispatch the
  host re-checks expiry, that the target still exists and that an `account:` principal is still
  the signed-in account.
- A `dsh-session` record is handed to the send outbox with `rpcId = downstreamId` and joins the
  §10.1 preparation entry; a `bot` record is handed to that Bot's existing user-action path with
  `nonce = downstreamId` once its unit is running. The journal never boots an engine itself.
- Sweep runs at open and before each pass: `admitted` records past `expiresAtMs` become
  `expired`; a terminal record is deleted when `now ≥ max(expiresAtMs, settledAtMs + 86 400 000)`;
  until then it is the dedupe tombstone. Pending and `linked` records are never deleted by sweep.
- A file that does not decode as a v1 record (corrupt, or written by a newer version) is left
  untouched, counted toward the 2048 bound, never dispatched and never deleted.

## 5. Storage

One file per record, `admissions/<admissionId>.json`, in the same app-private durable tree as
`send-outbox/` (iOS `<Application Support>/phone-dsh/`; Android `filesDir`), written with the §7
atomic order, mode 0600. iOS sets `completeUntilFirstUserAuthentication` explicitly. Opening the
journal needs no Worker, engine or Bot runtime.

## 6. Compatibility

New files only; no existing record changes. An older build ignores `admissions/`. A newer
record version is handled by the undecodable-file rule above. Disabling the feature stops new
admissions and leaves existing records in place.
