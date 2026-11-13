# P27 DSH session log → `BotRow` projection

Status: **normative**, phone-owned (`P27`, delta `D11`, checkpoint `B7a`), frozen by
`PC-20261112-android-bot-w4`. This file is not an upstream `dsh-bot` export and is not covered by
`spec/bot/v1/dshbot-pin.json`.

Implementation of record: `Sources/PhoneDSHBot/Rows/BotSessionLogProjection.swift`,
`BotStreamingRowLimiter.swift`, `BotDisplayContract.swift`, plus the App history page in
`examples/probe-app/PhoneDSHProbe/Bot/BotProductionServices.swift`. The Swift code is the reference
implementation, not the definition. Line references are to the phoneDSH tree at the freeze base
`e477497b`.

The JSON shapes are owned by `row.schema.json` and `row-batch.schema.json`; this file owns the
**function** from the inputs to those shapes. `spec/bot/v1/golden/projection.phone.json` is the
shared fixture.

MUST/MUST NOT/SHOULD/MAY are RFC 2119.

## 1. Input, output, purity

Inputs:

- **Session epochs**, oldest first. Each epoch is `{sessionID, records[]}` where `records` is the
  ordered DSH session log for that physical session (`session-lifecycle.md` §7). All epochs of one
  Bot main chat are projected together; the newest epoch is the live one. A single-epoch call is the
  one-element form.
- **Durable Bot events** (`BotEvent`) of the Bot, in any order. The projection sorts them itself.
- **Held request nonces**, an optional `requestId → chat-action nonce` map used only for the
  held-delivery row.

Output is `BotRowProjectionSnapshot`:

```json
{"rows": [BotRow...], "tombstones": [BotRow...], "cursor": <int>, "changes": [change...]}
```

`rows` are live rows sorted by `(seq, id)`. `tombstones` are deleted rows, same order. `cursor` is
the number of applied row changes (upsert or delete) and is also the head `updatedSeq`. `changes` is
the ordered list of `{upsert(row)}` / `{delete(id, updatedSeq)}` used by `watch(after:)` (§9). None of
this is durable: rebuilding from the same inputs yields the same snapshot, and no row is written to
the Bot store. The streaming limiter (§10) is the only in-memory overlay.

The projection is pure and order-stable: it never reads the clock, network or disk. `time` values
come only from the inputs.

## 2. Session-log record decoding (`parseJSONL`)

`BotDSHSessionEvent.parseJSONL` (`BotSessionLogProjection.swift:164-198`) is normative. Input is the
file/window bytes; the output is `{events, diagnostics}`.

1. Split the bytes on LF (`0x0A`), keeping empty subsequences. For each line, drop leading `0x20`,
   `0x09` and `0x0D`; skip the line when nothing remains.
2. The **first non-empty** record may be the v4 session header. It is skipped only if it decodes as
   `{"type":"session","version":4,"id":<string>,"createdAt":<int>,"isSeeded":<bool>,"delegationDepth":<int>}`
   with every listed member present (`:151-158,173-179`). A v3 header, a header missing
   `delegationDepth`, or a header anywhere other than the first record is not a header.
3. Every other non-empty record is decoded as an event (`:180-185`) with these required members:
   `type: string`, `seq: int`, `time: int64`, `data: object` (object of `BotJSONValue`). Optional:
   `surfaceOp`, `eventId` (member name `eventId`; `:147-149`). `data` is required even when empty:
   `{"type":"user/message","seq":7,"time":7}` is invalid and skipped.
4. A record whose `surfaceOp` is present must decode as one of the two canonical shapes (`:18-53`):
   - the string `"append"`;
   - an object with **exactly** three members `{"op":"replace","startSeq":<int>,"endSeq":<int>}`,
     `op` exactly `"replace"`, `startSeq >= 0`, `endSeq >= startSeq`.

   Anything else (`"start"/"end"` spellings from v0–v2, extra members, a non-string non-object, a
   negative start, `endSeq < startSeq`) makes the **record** invalid and it is skipped. JSON `null`
   for `surfaceOp` is the same as absent.
5. A decode failure is not fatal. The record is appended to diagnostics with its **1-based physical
   line number** and its `seq` when the surrounding JSON is still readable and numeric
   (`:183-197`); a syntactically broken line has `seq = null`. Parsing continues.
6. The returned `events` array preserves file order and contains only the valid records; no sorting
   or deduplication happens here (deduplication is §4.1).

The v4 header is the only non-event record this contract recognizes. `type:"session"` appearing
later is a valid (if ignored) event.

## 3. Identifiers, `entrySeq`, ordering

### 3.1 `rowID`

`rowID(sessionID, seq)` (`:920-922`) = `"e-" + sessionID + "-" + seq` where `seq` is the **record**
sequence number, not `entrySeq`. Fixed forms elsewhere:

| source | row id |
| --- | --- |
| DSH `user/message`, `assistant/message`, `turn/end`, automation/routine entry | `e-<sessionID>-<record seq>` |
| DSH `tool/call` approval | `e-<sessionID>-<record seq>-approval` |
| UI event fallback | `e-ui-<eventId>` |
| UI approval | `e-<botID>-approval-<approvalID>` |
| UI verification/task | `e-<botID>-task-<taskID>` |
| UI automation/routine | `e-<botID>-automation-<runID>` |
| progress widget | keeps the **first** id assigned to its `(botID, cardKey)` (§8) |

`sessionID` is the physical session id (including a legacy non-`gb-` id); it is never normalised.

### 3.2 `entrySeq`

`BotRow.seq` is `entrySeq(time, sourceSeq)` (`:924-931`), with 64-bit wrapping arithmetic:

```
positiveSource = max(0, sourceSeq) % 1000
milliseconds   = time * 1000
if multiplication overflows or milliseconds is outside Int range:
    return time < 0 ? Int.min : Int.max
value = Int(milliseconds)
if value + positiveSource overflows: return Int.max
return value + positiveSource
```

`sourceSeq` is the record `seq` for DSH rows, `commitSeq ?? 0` for UI rows, and the placeholder
`commitSeq` for a delete placeholder. Only the low three decimal digits of `sourceSeq` participate.
`row.schema.json` requires `seq >= 0`, so a session log with a negative `time` is outside this
contract even though the arithmetic is defined.

### 3.3 Ordering

Two different orders exist and both are normative:

- **Application order** (`BotRowOrder`, `:236-248,301,324`): mutate in this order:
  1. epoch index (`0` for the only epoch; for UI events `1` in the single-epoch form, or
     `max(1, epochCount)` when epochs are present);
  2. source sequence: record `seq` for DSH, `commitSeq ?? 0` for UI;
  3. `time`;
  4. array index in the input list.

  Consequently every DSH mutation is applied before every UI mutation, even when a late DSH record
  has a later wall-clock time than an earlier UI event.
- **Display order** (`rowOrder`, `:908-911`): `(seq, id)` ascending, i.e. `entrySeq` then id. This is
  the order of `rows` and `tombstones` in the snapshot and in batches.

`updatedSeq` is assigned in application order (§8), starting at 1; it is not derived from `seq`.

## 4. DSH record → row mapping

`projectDSH` (`:349-537`) iterates the epoch records in input order, with state `turn`,
`hiddenTurns`, `hiddenFallback`, `awaitingCard`, `toolNames`, approval `calls`, and `seenEventIDs`.

### 4.1 Duplicate records

The first record carrying a given `eventId` wins; every later record with the same `eventId` is
skipped (`:370`). Records without `eventId` are never deduplicated.

### 4.2 Ignored record types

The following types never produce a row (`:352-359`), after `turn/start` bookkeeping:
`session`, `permission/preset`, `sandbox/mode`, `approval/policy`, `system/message`,
`developer/message`, `agent/inbox/spliced`, `request/header`, `request/context`, `session/title`,
`session/end-seed`, `phone-dsh/session-erasure`, `session-log-deepseek/delivery-accepted`,
`job/registered`, `job/settled`, `step/start`, `step/end`, `turn/start`, `assistant/stream`.
Any other type falls through §4.10 (automation) or is skipped.

### 4.3 `turn/start`

Sets the current turn to `data.turn` when it is a finite integral number (else keeps the previous
turn) and continues; it never creates a row (`:372-375`).

### 4.4 `user/message`

Read in this order (`:378-427`):

1. `message = data.message` as an object, else `{}`; `role = data.role` else `message.role`.
2. `surfaceOp = record.surfaceOp` else `data.surfaceOp` decoded by §2.4.
3. `source = data.source` else `message.source`; `sourceKind = source.kind` when both are objects.
4. `rawText` = concatenation of `{type:"text", text}` blocks in `data.content` else
   `message.content`, in order, without separators. `content` may be absent → `""`.
5. `visibleRawText = BotSessionContinuation.strip(rawText)` (`Journal/BotSessionErasure.swift:315-324`):
   if the text starts with `<session_continuation>`, cut through the first
   `</session_continuation>` and trim whitespace; if the marker has no closing tag, the visible text
   is empty; otherwise unchanged.
6. `origin = BotTurnOrigin.from(source)` (`Wake/BotTurnOrigin.swift:33-42,88-93`). Missing/non-object
   source, or a non-string/missing `rpcId`, is `unknown` (visible, not held, not hidden).
7. If `origin.hidden` (routine, task, task-wake): when the current turn is `> 0`, insert it into
   `hiddenTurns`, else set `hiddenFallback = true`; clear `awaitingCard`; **skip**. No row.
8. Clear `awaitingCard`.
9. `injected = (source == nil && isInjected(rawText))` (`:933-936`): `rawText` is empty, or starts with
   `Current runtime context.`, or starts with `<system-reminder>`, or starts with
   `Check the [exit code: N] marker`. A record that carries any `source` is never classified by
   text.
10. Skip unless **all** hold: `role == "user"`, `surfaceOp == "append"`, `visibleRawText` is not
    empty, not injected, and `sourceKind` is absent or exactly `"user"`.
11. If `origin.kind == .agent`, skip: another Bot's immediate message already has its `agent.comm`
    row and must not become a user bubble.
12. When `origin.held`, replace the visible text with `stripHeldMessages` (`:938-949`): remove the
    first `<held_agent_messages>…</held_agent_messages>` block, remove leading newlines after it,
    collapse runs of spaces/tabs before a newline, and trim. A held record without a complete block
    keeps its text.
13. Parse the attachment block (`BotAttachmentPrompt.parse`, P27 D3): the row text becomes the
    parsed text; when the visible text contains the open marker, copy parsed attachments into
    `body.attachments` and rewrite `body.content` to one text block with the parsed text.
14. `body = fieldsFrom(message)` (drop `id`, `rowID`, `type`, `cardType`, `cardKey`, `trust`,
    `tainted`) plus `text`. `kind = message`, `role = "user"`, trust `owner_direct`,
    `createdAt = time`.
15. `chatActionNonce` (in-memory only, never JSON): when `source.kind == "user"` and
    `source.rpcId` is `user-action:<nonce>` with a non-whitespace nonce, that nonce. For a held
    origin it is instead the unique `conversation.turn_started` action nonce for the same turn
    (`heldActionNonces`), else the `heldRequestNonces[rpcId]` fallback. Ambiguity (two candidate
    actions for the turn) yields nil (`:328-347`).

A `user/message` with `surfaceOp` `"replace"` or absent is skipped entirely; it is not appended to
the conversation surface, even if its text is visible. Replacement markers never rewrite or delete
an existing row (§5).

### 4.5 `assistant/message`

(`:428-442`)

1. `message = data.message` object else `{}`; `messageTurn = data.turn` else the current turn.
2. Skip when `hiddenFallback`, `messageTurn` is in `hiddenTurns`, or `awaitingCard` is true (§4.7).
3. `text` = concatenated text blocks of `message.content`; skip when empty.
4. `body = {"text": text}`; add `reasoning` (concatenated `{type:"reasoning"}` blocks) when
   non-empty; copy `step`/`turn` from `data` when present.
5. Row id `e-<sessionID>-<seq>`, `kind = sendMessage`, `role = "assistant"`, trust `model`.

The row is not tied to a preceding `turn/start`; a pre-turn-start assistant message with no hidden
state is visible.

### 4.6 `tool/call`

(`:443-473`)

1. `name = data.name` string else `""`; `callID = data.callId` string else the record row id;
   remember `toolNames[callID] = name`.
2. `isApprovalTool(name)`: the last `__`-separated component, then its last `.`-separated component,
   equals `RequestApproval` (`:965-967`). Examples: `RequestApproval`,
   `mcp__phone__RequestApproval`, `tools.RequestApproval`. A non-approval tool call produces **no
   row** here; the phone's tool-process list is a separate App projection, not this contract.
3. `arguments` = `data.arguments` parsed as a JSON object. The recorded member is a JSON-encoded
   **string** (DSH records the model's argument text); a missing value, an object value, or a string
   that does not decode to an object yields `{}` (`:959-963`).
4. `action = arguments.action` non-empty else `未知操作`; `command = arguments.command` string else
   `""`; `requestID = arguments.requestId` else `data.requestId` else
   `"<sessionID>:<record seq>:<callID>"`.
5. Row id `e-<sessionID>-<seq>-approval`; body `type = approval` with fields from `arguments` plus:
   `action`, `command`, `status:"pending"`, `requestId`, `approvalID` (same value), `callId`,
   `title:"允许执行「<action>」吗？"`, `text:"待审批：<action>"`, and
   `ask:{requestId, action, target, status:"pending"}` where `action` is
   `"command-execution"` when `command` is non-empty else `"other"`, `target` is `command` when
   non-empty else `action` (`:1010-1012`). `kind = sendMessage`, role nil, trust `model`.
6. Remember the call so a later `tool/result` can update this same row.

### 4.7 `tool/result`

(`:474-496`)

1. `message = data.message` object else `{}`; `callID = message.toolCallId` else `data.callId` else
   `""`; `text` = concatenated text blocks of `message.content`.
2. If the call was an approval call, update **that** row (same id) with:
   `status = approvalStatus(text)`, `resultText = text`,
   `text = "<approvalLabel(status)>：<action>"`,
   `ask.status = approvalAskStatus(status)`; append an upsert mutation at the result record's order.
   `approvalStatus` (`:974-988`): parsed `arguments.allowed == false` or `decision == "denied"` →
   `denied`; `allowed == true` → `allowed`; else case-insensitive text markers
   `永不允许`/`永不允許`/`never allow` → `never`; `总是允许`/`總是允許`/`always allow` → `always`;
   `超时`/`逾時`/`timed out`/`timeout` → `timed-out`; `拒绝`/`拒絕`/`denied`/`rejected`/`not allowed`
   → `denied`; `允许`/`允許`/`allowed` → `allowed`; else `unknown`. The structured checks come
   first, so a denial JSON can never render as allowed.
   `approvalAskStatus`: `allowed`/`always` → `allowed`; `timed-out` → `timed-out`; `unknown` →
   `pending`; else unchanged (`:1001-1008`). `approvalLabel` is the frozen zh string table
   (`:990-999`).
3. Independently of the row update: when `text` starts with `已顯示`, `已显示` or `Displayed` and the
   remembered tool name's suffix is `ask_user` or `show_next_steps`, set `awaitingCard = true`
   (`:492-496`). This suppresses later assistant text until the next user message or `turn/end`.
4. Non-approval tool results never create a row.

### 4.8 `turn/end`

(`:497-512`)

1. Clear `awaitingCard`, remove the current turn from `hiddenTurns`, clear `hiddenFallback`.
2. `reason = data.reason` object; `reasonKind = reason.kind`.
3. Skip when `reasonKind` is missing, `"completed"` or `"aborted"`.
4. `detail = "：" + reason.error.message.prefix(200)` when present; `hint` is
   `"（API Key 无效或已被覆盖，请到设置重新粘贴）"` when `reason.error.status == 401`; text is
   `"回合失败<detail><hint>"` truncated to 400 characters.
5. Row `type = notice`, fields `{tone:"error", text}`, `kind = event`, role nil, trust `model`, id
   `e-<sessionID>-<seq>`.

### 4.9 Hidden-turn state

- `turn/start` sets `turn`.
- A hidden `user/message` with `turn > 0` hides every later assistant message of that turn and the
  turn's wrap-up; the hidden user message itself never becomes a row. `turn/end` ends that.
- A hidden `user/message` without a positive turn sets `hiddenFallback`, which hides assistant
  messages until the next `turn/end`.
- `awaitingCard` hides assistant text after a question/steps card result until the next
  `user/message` (any role-bearing user record processed at §4.4 step 8) or `turn/end`.

### 4.10 Automation / routine records

(`:513-533`) For a type starting with `automation/` or `routine/`:

1. `run = data.automation` else `data.routine` else `data.run` (object) else `{}`.
2. `automationID = run.automationId` else `run.id` (non-empty strings); `name = run.name` else
   `run.title`. Skip when both are absent.
3. `status`: `run.status` else `data.status`, lowercased, when in
   `{confirming, running, sent, failed, idle}`; else derive from the last `/`-separated type
   component: `start|started|run|running` → `running`; `end|ended|done|completed|sent` → `sent`;
   `fail|failed|error` → `failed`; otherwise `idle` (`:1014-1022`).
4. Body `type = automation`, fields from `run` plus `title` (name or `例行任务`), `status`, and
   `automation` = `run` overlaid with `automationId` (JSON null when absent), `name`, `status`.
5. Row id `e-<sessionID>-<seq>`, `kind = message`, role nil, trust `model`.

### 4.11 Unknown record

Skipped. It is not fatal, has no row, and does not affect `awaitingCard`/hidden state.

## 5. `surfaceOp` semantics in the projection

`surfaceOp` is decoded (§2.4) and used for exactly one decision: a `user/message` contributes a user
row only when its effective `surfaceOp` is `"append"` (§4.4 step 10). A `"replace"` marker records an
inclusive surface range that DSH replaced for model context; the projection does **not** apply that
range to rows, does not delete the covered rows and does not rewrite their ids. This is deliberate:
row identity is the physical log position, and a replacement of `system/message` context (the common
case) has no row at all. A second host MUST NOT implement range replacement in this projector.

The canonical object form is `{"op":"replace","startSeq":<int>,"endSeq":<int>}`. The v0–v2
`start`/`end` spelling is invalid input (§2.4), not an accepted alias.

## 6. Durable Bot event → row mapping

`projectUI` (`:539-676`) processes the Bot's durable events. Erased payloads (`$erased == true`) are
skipped (`:544-546`). A principal with a `botId` other than this Bot is skipped; `botId == nil` is
accepted. `data` must be an object. The first event with a given `eventId` wins (`:547-548`).

Events are ordered by `(commitSeq ?? Int.max, time, eventId)` (`:900-906`) before processing; the
application order key uses `(time, ui source, commitSeq ?? 0, index)` (§3.3).

### 6.1 Payload flattening

For each supported event, `payload` starts as `data` and then shallow-merges, in this order, the
object values of `row`, `entry`, `message`, `body`, `card`, `task`, `automation`, `routine`, `run`,
`notice` (later keys win; `:569-572`). `fieldsFrom` drops `id`, `rowID`, `type`, `cardType`,
`cardKey`, `trust`, `tainted` when the body is built (`:1024-1026`).

Trust is `owner_direct` only when the event origin is `.local(source: "user")`; every other origin
(`mcp`, `ipc`, `card-bridge`, DSH, …) is `model` (`:573`, `:1052-1057`). A UI row never carries
`chatActionNonce`.

The default row id is `e-ui-<eventId>`; `payload.id` else `payload.rowID` override it before the
type-specific rules.

### 6.2 Supported types and bodies

The closed supported list (`:562-567`):
`card.presented`, `ui.send_to_user`, `ui.notice`, `ui.system_event`, `agent.comm`,
`approval.requested`, `approval.decided`, `task.created`, `task.started`, `task.updated`,
`task.stop_requested`, `task.settled`, `task.resumed`, `conversation.automation_run`,
`routine.run_started`, `routine.run_finished`, `verification.reported`, `bot.greeting_seeded`.
Any other durable type (including `conversation.*` rows written by the DSH turn path) is not
projected as a row here; the DSH records are the source for those rows.

| event | body / kind / role | id and status rules |
| --- | --- | --- |
| `ui.notice`, `ui.system_event` | `notice`, `kind = event` | id as above; rendering is decided by `BotDisplayContract` |
| `approval.requested`, `approval.decided` | `approval` | `approvalID = payload.approvalID \|\| approvalId \|\| requestId \|\| requestID`; when present, id = `payload.id` else `e-<botID>-approval-<approvalID>`. Status: `payload.status` if present; else requested → `pending`, decided `deny` → `denied`, `always` → `always`, anything else → `allowed`. `fields.approvalID` is set when known. |
| `verification.reported` | widget `task`, `cardKey = task:<taskID>` | only when `payload.subjectKind == "task"`; `taskID = task_id \|\| subjectId \|\| subjectID`; id = `e-<botID>-task-<taskID>`; otherwise skip |
| `task.*` | widget `task` | `nativeTaskID = payload.task_id`; `taskID = task_id \|\| taskID \|\| taskId \|\| threadID`; if a task id exists, `stableID = e-<botID>-task-<taskID>`, and id = `stableID` when `task_id` was present else `payload.id \|\| stableID`. `cardKey = payload.cardKey \|\| task:<taskID>` |
| `conversation.automation_run`, `routine.run_*` | `automation`, `kind = message` | `runID = payload.runID \|\| runId \|\| event.runId`; when present id = `payload.id \|\| e-<botID>-automation-<runID>` |
| `agent.comm` | `text`; role from `payload.role` else `inbound`/`incoming` → `user`, else `assistant`; `kind = message` when role is user else `sendMessage` | flatten `payload.agentComm` into the body when absent; text = `agentComm.message \|\| agentComm.replyText \|\| payload.message \|\| payload.replyText` |
| `bot.greeting_seeded` | `text`; role `assistant`; text falls back to `payload.content` | |
| `card.presented` and every payload with `cardType` | `uiBody` (§6.3) | answered/dismissed cards applied first (§6.4) |

`ui.send_to_user` falls through to `uiBody` and uses its `payload.type` (default `text`).

### 6.3 `uiBody` fallback

(`:697-719`) When the type-specific rules above do not build a body:

- If `event.type == "card.presented"` or `payload.cardType` exists: a missing/empty `cardType` →
  no body (skip). `cardType == "attachment"` or `"file"` → body `attachment` with `cardKey`; a
  known `BotWidgetCardType` → body `widget` with that card type and `cardKey`; an unknown card type
  → skip.
- Else `rawType = payload.type ?? "text"`: `text` → body `text`; `attachment` → body `attachment`;
  `widget` → skip; `local-tool-permission` / `approval` → body `approval`; `automation` → body
  `automation`; `notice` → body `notice`; any other → skip.
- For a `text` body, role = `payload.role ?? "assistant"`, kind = `message` when role is `user` else
  `sendMessage`, and the row is skipped unless `text`, `content` or `replyText` is a non-empty
  string.
- A body that stays nil is skipped.

### 6.4 Card outcomes

Before processing, `cardOutcomes` scans the same Bot's events in the same stable order
(`:678-695`): `card.answered` maps `cardID → optionID` (last wins; a missing option id keeps the
previous or `""`); `card.dismissed` adds the card id to a dismissed set. Then:

- `card.presented` for a dismissed card is skipped entirely (the closed card must stay hidden after
  a cache rebuild).
- `card.presented` for an answered card gets `status:"answered"` and
  `answeredOptionID:<optionID>` in its body; the presented card itself still projects.

### 6.5 Deletion

`transcript.row_deleted` (`:550-560`) is a delete mutation, not a row:

- id = `data.rowID` else `data.id` else nested `data.row.id`;
- placeholder body `deleted` with `deletedAt = event.time` (ms number), `seq =
  entrySeq(event.time, commitSeq ?? 0)`, `createdAt = event.time`;
- if the delete id is already tombstoned, skip; otherwise create the tombstone (§8).

A delete for a row that was never seen is valid and produces a tombstone with no `deletedKind`.

## 7. Epochs

`project(botID:epochs:uiEvents:)` (`:309-326`):

1. Process each epoch in the supplied order with its own `sessionID` and records; the epoch index is
   the application-order `source`.
2. Process the Bot events once, after every epoch, with source `max(1, epochCount)`.
3. Sort all mutations by §3.3 and apply once. Rows keep their physical session ids; an older epoch's
   row is a normal row, not a tombstone.
4. `phone-dsh/session-erasure` records are ignored (§4.2); erasure is represented by the epoch
   switch plus the durable events.

The epoch chain itself is a host input (`session-lifecycle.md` §7): the App loads the ordered
`runtime.started` chat sessions, deduplicates by session id keeping the first occurrence, appends the
current id when unseen, and drops an older epoch whose log is empty
(`BotProductionServices.swift:224-259`). When the chain is empty the host projects one empty epoch
with the current id.

The one-shot continuation block is stripped from a user message text (§4.4 step 5); it is model
context, never a user bubble.

## 8. Apply, progress collapse, tombstones, cursor

`apply` (`:721-790`) walks the sorted mutations:

For an **upsert**:

1. If the body is `widget`/`progress` with a `cardKey`, compute `progressKey = "<botID>:<cardKey>"`.
   If that key already maps to a row id, the mutation's id is replaced by the mapped id (the first
   id for the card key wins). The mapping is recorded even when the mutation is a no-op.
2. If the id is tombstoned, skip (a tombstone is never resurrected).
3. Merge `provenance.eventIDs` with the previous row's, preserving order and uniqueness. Trust is
   the **new** mutation's trust (not the strongest); `tainted` is the OR of old and new
   (`:739-742`).
4. Build the row: `seq = old.seq ?? input.seq`, `updatedSeq = old.updatedSeq ?? 0`,
   `createdAt = old.createdAt ?? input.createdAt`; `kind/role/body` from the mutation; `streaming =
   false`; `chatActionNonce = input.chatActionNonce`.
5. If the old and new rows have the same content (`sameContent`, `:913-918`: id, botID, seq, kind,
   role, body, provenance, streaming, createdAt, chatActionNonce — **not** `updatedSeq`), no change
   is applied and no cursor is consumed.
6. Otherwise `cursor += 1`, `row.updatedSeq = cursor`, store the row, record
   `upsert(row)`.
7. Two widget `task` rows for the same id merge their `additionalProperties`: old fields first, new
   fields overlay (`:746-753`). This keeps a Task card's step list when a verifier report updates its
   status.

For a **delete**:

1. If the id is already tombstoned, skip.
2. `cursor += 1`; body = old body (or the placeholder body), `type = deleted`, `cardType`/`cardKey`
   removed, `additionalProperties` = placeholder body's properties (the `deletedAt`); when an old row
   exists, add `deletedKind = old.kind.rawValue`.
3. Merge event ids; provenance trust is `projector`, `tainted = false`.
4. Row id keeps the old `seq` when the row existed, else the placeholder `seq`; `updatedSeq =
   cursor`, `kind = event`, role nil, `createdAt` = old or placeholder time.
5. Remove the live row, add the tombstone, remove any progress mapping pointing at the id, record
   `delete(id, cursor)`.

The output `cursor` is the number of applied changes. `rows` and `tombstones` are sorted by §3.3
display order.

## 9. History, `watch(after:)`, cursor reset

`BotRowHistory` (`:800-898`) holds one snapshot.

- `history()` returns live rows; `tombstones()` returns tombstones; `cursor()` returns the head.
- `rebuild(botID:sessionID:sessionEvents:uiEvents:)` and
  `rebuild(botID:epochs:uiEvents:heldRequestNonces:)` project the inputs, **reconcile** them with the
  current snapshot (§9.1), replace the snapshot and return a **reset** batch:
  `{rows: all live rows, deletes: tombstone ids sorted by updatedSeq, cursor: head, reset: true}`.
- `replaceWithRebuiltCache(snapshot)` installs an already projected snapshot through the same
  reconciliation (used after a cold cache rebuild).
- `watch(after cursor)`:
  - `cursor <= 0` or `cursor > head` → the same **reset** batch as `rebuild`;
  - otherwise select the changes whose `updatedSeq > cursor`, keep only the latest change per id,
    sort by `updatedSeq`, and return `{rows: upserts in that order, deletes: deleted ids in that
    order, cursor: head, reset: false}`. A cursor equal to the head returns an empty non-reset batch.

The reset condition is structural: a client whose cursor is not in `[1, head]` cannot apply an
incremental update and MUST replace its view.

### 9.1 Reconciliation

`reconciled` (`:849-891`) is used on every rebuild after the first:

- Seed from the existing snapshot's rows, tombstones, changes and cursor.
- For each projected live row not tombstoned: if an existing row has the same content, keep it
  unchanged (it consumes no cursor); otherwise `cursor += 1`, set `updatedSeq = cursor`, store it and
  append an upsert change.
- For each projected tombstone not already tombstoned: `cursor += 1`, set `updatedSeq = cursor`,
  remove any live row, store it and append a delete change.
- For each previously live row absent from the projection and not tombstoned: `cursor += 1`, remove
  it and append a delete change.
- Rows are never resurrected: once a tombstone exists for an id, no later projected row can bring it
  back.

This makes a rebuild idempotent (the second rebuild of identical inputs returns the same reset batch
and appends no changes) and makes a reconnect delta converge with an uninterrupted projection.

## 10. Streaming limiter

`BotStreamingRowLimiter` (`BotStreamingRowLimiter.swift:6-90`) is the only streaming surface. It is
in-memory and never durable; projected rows have `streaming == false`.

- Maximum **10 updates per second** (`maximumUpdatesPerSecond`).
- Clock: `monotonic(now)` sets `lastNow = max(lastNow, now)`; the limiter never moves backwards.
  Prune emissions `<= now - 1` (a one-second rolling window).
- `submit(row, now)`:
  1. compute the monotonic clock and prune;
  2. overlay the row with `streaming = true` (same `updatedSeq`); replace any pending row with the
     same id, keeping the original pending insertion order; remember a new id at the next insertion
     counter;
  3. if fewer than 10 emissions are in the window, emit immediately (remove from pending, store in
     `visible[id]`, append the clock to emissions) and return the emitted row; otherwise return
     nil and leave the row pending.
- Coalescing: only the last submitted body per row id survives in `pending`; a row that was already
  emitted stays in `visible` with its last emitted body until a later emission replaces it.
- `flush(now)` prunes, then emits pending rows oldest-insertion-first while the window has capacity,
  returning them in emission order.
- `rows()` returns visible rows sorted by `(seq, id)`.
- `pendingCount()` is the number of distinct pending ids. `nextFlushAt()` is nil when nothing is
  pending, else `min(emissions) + 1` (the earliest retained emission plus one second). Note it is
  based on the emission window, not on the pending row's creation time.
- `remove(id)` drops the id from pending, order and visible. `clear()` drops everything including
  emissions.
- Emissions at exactly `now - 1` leave the window, so the 11th update can be emitted at
  `firstEmission + 1 s`.

The limiter does not invent rows: the caller supplies an already projected row (or an overlay) whose
`id`, `seq` and `body` follow §3/§8. A row deleted from the projection must also be `remove`d from
the limiter by the App.

## 11. Display contract relation

`row.schema.json` and `row-batch.schema.json` freeze the wire shape; `row-projection.json` (upstream,
untouched) freezes the **input kind → surface** display table for
`BotDisplayContract.project(_ input:profile:)` (`BotDisplayContract.swift:78-200`). This file and
`projection.phone.json` freeze the **log → row** function, and its expected `display` objects freeze
the composition that the Bot page actually renders:

`BotDisplayContract.project(_ row:)` (`:205-230`) first derives an input object from a row:

| row body | derived `kind` | extra input |
| --- | --- | --- |
| `text` | `message` | `role`; a `message` row with nil role is treated as `user` |
| `widget` | `card` | `cardType`, `cardKey` |
| `attachment` | `card` | `cardType = "attachment"`, `cardKey` |
| `approval` | `approval` | |
| `automation` | `routine-run` | |
| `notice` | `notice`, or `system-event` when `event` is present | |
| `deleted` | `deleted` | |

and then applies the `row-projection.json` table with profile `phoneP0` (the App default) or
`upstreamReference`. Consequences that are normative here:

- A `message` body with role `user` and non-empty text renders on the `bubble` surface; an
  attachment-only user message has empty text but remains renderable because
  `input.attachments` is non-empty (`:120-132`).
- A `sendMessage` assistant text row renders on `bubble` with `wire {kind:"send-message",
  type:"text"}`.
- `question`/`steps` render as `widget-card` when they carry a prompt/help text or at least one
  option/step; without data they are hidden.
- `progress`, `checklist`, `link`, `document` and `task` cards render on their surfaces when their
  required data is present; `table`, `callout`, `info`, `payload` and `library` are protocol-visible
  but not phone-P0 renderable (they are hidden under profile `phoneP0`).
- `attachment` renders as `attachment-card`, `approval` as `approval-card` (a pending approval is
  not renderable; any decided status with data is), `automation` as `automation-row`, `notice` only
  for tones `error`/`denied`/`denial` and not `contextOnly`, and `deleted` is always hidden.
- `ui.system_event` only renders for event names `outbound`, `inbound`, `summary`, `renamed`;
  unknown system events are hidden even though they produce a row.
- `tool-call` and `separator` rows are hidden; the upstream reference profile renders separators,
  phoneP0 does not. This projector never produces either kind.

Changing a surface is a breaking UI change (P09) even when the row JSON is unchanged.

## 12. History paging (App surface, P09 consumer)

`BotProductionRowService.history(before:limit:)`
(`examples/probe-app/PhoneDSHProbe/Bot/BotProductionServices.swift:370-383`) is the App's paging
function over the projected rows:

1. rebuild (so the page is current), then read `history()` in display order;
2. `before == nil` means the end (newest window); otherwise `before` MUST be an existing row id and
   the page ends **before** that index; an unknown id throws
   `invalidService("历史行游标不可用")`;
3. `limit` is clamped to at least 1; the page is the **last** `max(1, limit)` rows of the eligible
   prefix, in display order;
4. `nextCursor` is the first row id of the page (nil for an empty page); `hasMore` is true when the
   eligible prefix is longer than the page.

This is app-layer consumer logic in `examples/probe-app/**`, which no SwiftPM test target can reach;
its iOS conformance is **NOT_RUN** in the B7a round (see `docs/design/android-bot-spec-deltas.md`
§D11). The row contract above does not depend on it: a host may page differently as long as it
renders the same rows in the same display order.

## 13. Failure and compatibility

- A damaged session-log line is skipped and reported in diagnostics; it never fails the rebuild
  (`RowHistoryTests.testDamagedRecordIsSkippedWithDiagnosticsAndRebuildContinues`).
- An unknown durable event type is skipped; it is not fatal.
- An unknown session record type is skipped unless it is an automation/routine type.
- Old DSH logs replay through the same table; `surfaceOp` `start`/`end` spellings are invalid and
  skipped, not migrated at read time (the v2→v3 migration owns that).
- The projection cursor is in memory. An app restart rebuilds from the log plus durable events; there
  is no schema migration.
- A tombstone is permanent for the lifetime of the in-memory history; a cold rebuild reconstructs it
  from the durable delete event.

The shared vectors are `spec/bot/v1/golden/projection.phone.json`. Every expected row validates
against `row.schema.json`, and the Swift test runs the real parser, projector, history and limiter.
