<!-- SPDX-License-Identifier: MIT -->

# Bot Task 契约（Bot v1）

Status: normative. Contracts: P25 (durable events), P26 (BotToolSurface).
Contract revision: `bot-team-d12-v1` (`PC-20261113-bot-team-d12`). Swift is `implemented`;
Kotlin B6 is `not started` and MUST implement this document, not the D12 outline.

This document owns `Task`, `AwaitTask`, `StopSubagent`, the `persistedTask` snapshot, restore,
interrupted/settled/denied parent wakes, task request ids, timeout/cancel/reconcile, and the
interaction with the held inbox. `tool-contracts.md` §4 owns the short per-tool argument/result
summary; where it disagrees with this document, this document and the shared fixtures win.
`team.md` owns `SendToAgent`/`CreateTeammate`. `mcp-endpoint.md` §4/§5 owns the Worker restart and
prompt-idempotency frame; this document does not add a second event type or a task table.

Reference: `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift` (task sections),
`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift` (`startTask`/`awaitTask`/`stopTask`),
`Sources/PhoneDSHBot/MCP/BotMCPTypes.swift`, `Sources/PhoneDSHBot/Wake/BotTurnOrigin.swift`.
Where the D12 outline differs, §12 records the ruling.

## 1. Record and status

A task record (`BotTaskRecord.jsonValue`) is exactly:

```json
{"task_id":"…","sessionId":"…","status":"…","title":"…",
 "result":"…"?,"partial":"…"?,"error":"…"?,
 "completion":"…"?,"purpose":"…"?,"constraints":["…"]?,
 "budget":{"max_duration_ms":N}?,"verification":{…}?}
```

- `task_id` is `task-` + the first 12 lowercase hex characters of a UUID. `sessionId` is the DSH
  task session created for this task.
- `result` is the final assistant text only when the task completed; `partial` is the latest
  assistant text (or `""` for a freshly started task); `error` is the terminal reason.
- `completion`/`purpose` are omitted when empty; `constraints` is omitted when empty; `budget` is
  omitted when absent; `verification` is present for a verified task.
- The status domain is
  `running | stopping | waiting_approval | completed | failed | stopped | interrupted | denied`.
  There is **no `cancelled` task status**: a stopped task is `stopped` (D12's `cancelled` is
  rejected; §12 ruling 1). `waiting_approval` means parked on a durable approval and is terminal
  for `AwaitTask`, but not lifecycle-terminal: a later decision resumes or closes it.

Legal transitions:

| from | to | trigger |
| --- | --- | --- |
| `running` | `completed` | child turn completed |
| `running` | `failed` | child turn failed / transport error |
| `running` | `waiting_approval` | durable approval pending |
| `running` | `interrupted` | Worker restart or deliberate host park |
| `running` | `stopping` → `stopped` | `StopSubagent` / user stop |
| `waiting_approval` | `running` | approval allowed; the same session resumes |
| `waiting_approval` | `denied` | approval denied or expired |
| `waiting_approval` | `stopped` | stop/cancel of the parked approval |
| `stopping` | `stopped` | turn cancelled and work joined |
| restored `running|stopping` | `interrupted` | process restore (§6) |

`completed`, `failed`, `stopped`, `interrupted`, `denied` are lifecycle-terminal; `waiting_approval`
is terminal for reads.

## 2. `Task`

### 2.1 Arguments

| field | rule |
| --- | --- |
| `prompt` / `task_description` | one non-empty string after trimming is required |
| `task_title` / `description` | title; default `委派的任务` |
| `async` | boolean, default `false` |
| `timeout_ms` | integer 1,000–300,000, default 180,000; see §9 |
| `completion` | trimmed string, ≤ 4,000 characters; empty means no completion condition |
| `purpose` | trimmed string, ≤ 2,000 characters |
| `constraints` | ≤ 8 non-empty strings, each ≤ 500 characters; non-strings are ignored |
| `allowed_write_directories` | ≤ 32 strings; resolved per README §2.5 |
| `budget` | object with **only** `max_duration_ms`, integer 1,000–300,000 |

Accepted but unused in this revision (the runtime does not validate them):
`subagent_type`, `model`, `model_override`, `max_mode_override`, `default_expanded_while_running`,
`agent_id`, `attachments`, `mode`, `responding_to_message_ids`, `environment`, `machine`.
`task_id` or `resume` present is refused with `暂不支持从历史任务继续`.

Validation order: principal → `arguments` object → history keys → prompt → `timeout_ms` →
`completion` → `purpose` → `constraints` → `budget` → directories.

- Only a `chat` or `task` principal may call. Any other kind (routine/verifier/maintainer) is
  `invalid_arguments` `只有聊天或任务会话可以派发任务`.
- A `task` principal needs the `task.delegate` capability; this revision never grants it, so the
  result is `permission_denied` `当前任务会话里不能再派发任务`. A task child cannot spawn
  siblings.
- The production executor registers a `task.created` event before starting any work. The tool
  layer then appends `task.started` (the runtime does **not** write a second `task.created`; that
  would race the durable snapshot).
- `async:false` runs the child turn inside the call and returns a terminal record (normally
  `completed` or `failed`). `async:true` returns the `running` record after `task.created` and
  starts a background work item.
- When the returned record is `completed|failed|stopped`, the tool appends `task.settled` with
  `eventId:"settled:<taskId>"`. The durable event is idempotent: the executor may already have
  written it. `interrupted`, `denied` and `waiting_approval` do not trigger this extra append.

### 2.2 Result

Success: the task record plus `authorization`:

```json
{"workspaceRoot":"…","allowedWriteDirectories":["…"],
 "canWriteOutsideWorkspace":false,"canNetworkWrite":false,"canDelegateTasks":false}
```

`authorization` is resolved by the executor from the requested directories and the Bot workspace
root; this revision never grants network write or delegation. `AwaitTask` returns the same object
when the executor implements the authorizing seam. `StopSubagent` returns only the record (no
`authorization`). `content[0].text` is the canonical JSON of the full `structuredContent`; a
failure is the `BotMCPCallResult` failure shape (`ok:false,error{code,message}`, text = message).

Exact failures:

| condition | code | message |
| --- | --- | --- |
| non-chat/task caller | `invalid_arguments` | `只有聊天或任务会话可以派发任务` |
| task child without `task.delegate` | `permission_denied` | `当前任务会话里不能再派发任务` |
| missing prompt | `invalid_arguments` | `派发任务需要说明要做什么` |
| timeout out of range | `invalid_arguments` | `任务超时必须在 1000 到 300000 毫秒之间` |
| completion too long | `invalid_arguments` | `任务的完成条件最多 4000 个字符` |
| purpose too long | `invalid_arguments` | `任务的用途说明最多 2000 个字符` |
| constraints too many/long | `invalid_arguments` | `任务约束最多 8 条，每条最多 500 个字符` |
| budget has another key | `invalid_arguments` | `任务预算只接受 max_duration_ms` |
| budget out of range | `invalid_arguments` | `任务预算的 max_duration_ms 必须在 1000 到 300000 毫秒之间` |
| too many directories | `invalid_arguments` | `allowed_write_directories accepts at most 32 entries` |
| `task_id`/`resume` | `invalid_arguments` | `暂不支持从历史任务继续` |

## 3. `AwaitTask`

- Arguments: required non-empty `task_id`; optional `timeout_ms` integer 1,000–600,000, default
  180,000.
- Missing id → `invalid_arguments` `等待任务需要提供任务编号`; out-of-range timeout →
  `invalid_arguments` `等待任务的超时必须在 1000 到 600000 毫秒之间`.
- Ownership is resolved by the executor from the parent call. A task owned by another Bot throws
  `unauthorized` (`Unauthorized`); a task in another session of the same Bot is refused unless it
  is the current main-chat successor of a replaced epoch (§7.4).
- Wait behavior: if the current record is terminal for reads, return it immediately. Otherwise
  poll the **record** every 20 ms until the deadline; return the current record at the deadline.
  A timeout never cancels the task and never returns another task's record. Terminal for reads:
  `completed|failed|stopped|interrupted|denied|waiting_approval`.
- Wait on the record, not on the background work item that also delivers the parent wake: a
  settled record must return even if the wake turn is still blocked.
- A `completed|failed|stopped` record returned by the tool appends `task.settled` with
  `eventId:"settled:<taskId>"` (idempotent). `interrupted`/`denied`/`waiting_approval` do not.
  The result adds `authorization` when the executor supports it, otherwise returns the bare record.

## 4. `StopSubagent`

- Arguments: required `task_id` or its alias `id`; both empty/missing →
  `invalid_arguments` `停止任务需要提供任务编号`.
- Unknown task → `invalid_arguments` `unknown task: <taskId>` (the executor's `invalidRequest`).
- A task owned by another Bot/session fails `unauthorized`; the same main-chat successor rule as
  `AwaitTask` applies.
- If the record is already `stopped|completed|failed|interrupted|denied`, return it unchanged
  (no new transition; the tool wrapper still appends `task.stop_requested` and the idempotent
  `task.settled`).
- A live task: set `stopping`, cancel the task turn **including queued turns**, cancel and join
  the work item, keep `partial`, clear `result`/`error`, then write `stopped`.
  - The tool appends `task.stop_requested` (its event id is a random UUID; it is **not**
    `stop:<taskId>` — the D13 summary was wrong) followed by `task.settled` with
    `eventId:"settled:<taskId>"`.
  - A late result after the stop is dropped by the generation check; the stopped record is
    authoritative.
- A `waiting_approval` task is not live work, but it can be stopped: transition to `stopping` →
  `stopped`, cancel the durable approval with reason `task_stopped`, and write `task.updated`
  (`persisted:stopped:<taskId>`) plus `task.settled` (`settled:<taskId>`). No parent wake is sent
  for a stopped task.
- `StopSubagent` never adds `authorization`.

## 5. Durable `persistedTask` snapshot

`task.created` and `task.updated` carry the record fields **plus** a child object
`data.persistedTask`. `task.settled`, `task.started` and `task.stop_requested` carry only the
record fields. The snapshot is additive inside `data`; an old reader ignores it.
`persistedTask` is the only durable task projection; there is no task table.

Required keys (all present):

| key | type/meaning |
| --- | --- |
| `taskId` | the task id |
| `sessionId` | the DSH task session |
| `parentSessionId` | the session that called `Task` |
| `parentBotId` | the calling Bot |
| `parentIncarnation` | the caller's principal incarnation at dispatch |
| `parentKind` | `chat|task|routine` |
| `title` | the task title |
| `prompt` | the prompt sent to the child |
| `asynchronous` | boolean |
| `timeoutMs` | the dispatch timeout |
| `status` | the record status at write time |
| `createdAt` | **snapshot write time** in milliseconds, not the original create time |
| `wakeDelivered` | boolean durable wake marker |

Optional keys: `result`, `partial`, `error`, `authorization`, `completion`, `purpose`,
`constraints`, `budget`, `verification`, `waitingApprovalID`.

- `authorization` is the resolved subset; a snapshot without it (old row) restores the
  workspace-only default, never an unrestricted child.
- `completion`/`purpose`/`constraints`/`budget`/`verification` are optional so rows written before
  the S3 verifier restore as "no completion condition" rather than an unverifiable task.
- `createdAt` is re-stamped on every persist (`now()`), so it is not a stable task creation time.
  Kotlin MUST reproduce this byte value when writing the same event (the vector freezes
  `createdAt:1000` for the test clock).
- `wakeDelivered` is set only by the interrupted wake and the denied wake (§7); the ordinary
  completed-task wake does not set it (§7.1).

Event ids written by the runtime:

| event | eventId |
| --- | --- |
| `task.created` | `created:<taskId>` |
| `task.updated` settled | `persisted:settled:<taskId>` |
| `task.updated` stopped | `persisted:stopped:<taskId>` |
| `task.updated` failed | `persisted:failed:<taskId>` |
| `task.updated` interrupted | `persisted:interrupted:<taskId>` |
| `task.updated` parked | `persisted:waiting-approval:<taskId>` |
| `task.updated` resumed | `persisted:resumed:<taskId>` |
| `task.updated` denied | `persisted:denied:<taskId>` |
| `task.updated` wake marker | `persisted:wake:<taskId>` |
| `task.updated` denied wake marker | `persisted:denied-wake:<taskId>` |
| `task.settled` | `settled:<taskId>` |
| `task.resumed` | `resumed:<taskId>` |

`task.started` and `task.stop_requested` use generated ids. The MCP writer prefixes all ids with
`evt-<type>-`; a consumer matches on the suffix, not on the raw `eventId` string.

`task.resumed` carries
`{task_id,sessionId,status:"running",approvalID,resumedAt}` (not a full record); it is written
before the resumed work starts. `task.started` and `task.stop_requested` carry the record.

## 6. Restore

On construction (`BotDSHRemoteRuntime.init`) the runtime:

1. Scans durable events from commit 0 in pages of 1,000 (exclusive cursor on `commitSeq`).
2. Keeps the **latest** `persistedTask` per `taskId` where `parentBotId == this Bot`. A snapshot
   with another parent Bot is ignored.
3. Keeps the **latest** `task.settled` record per `task_id`.
4. Applies the settled record first: its `status`/`title`/`result`/`partial`/`error` are
   authoritative; missing `completion`/`purpose`/`constraints`/`budget`/`verification` fall back to
   the snapshot (so a restart does not drop the S3 contract).
5. Maps a remaining `running` or `stopping` status to `interrupted` with
   `error:"worker_restarted"`, `result:nil`, and the persisted `partial`. It writes a new
   `task.updated` (`persisted:interrupted:<taskId>`) before exposing the state.
6. Rebuilds `mainSessionEpochs` from durable `runtime.started` events (chat kind) so an erasure
   epoch switch can route a wake to the current main chat.
7. Queues one interrupted wake per task when the restored record is `interrupted`, the task was
   asynchronous, `parentKind == chat`, and `wakeDelivered == false`; the queue is deduplicated by
   task id and sorted.
8. Keeps `waiting_approval` as `waiting_approval` (not interrupted) and preserves
   `waitingApprovalID`; a Worker restart later reconciles it against the durable approval (§9.3).

Compatibility choice for a legacy `task.created`/`task.updated` without `persistedTask`: the task
is **ignored** (not restored, not mapped to interrupted). `AwaitTask`/`StopSubagent` then fail with
`unknown task: <taskId>`. This is the frozen choice from D12's "interrupted or ignored"; choosing
ignored avoids inventing a parent/wake for a record that never had one. `task.settled` widget rows
remain visible through the normal projection.

## 7. Parent wakes

A wake is a hidden chat turn: prompt starts `[SAND_HIDDEN_PROMPT][subagent]`, request id is
`task-settled:`/`task-interrupted:`, `hidden=true`, memory source `hidden-wake`. It is **not** a
user turn and does not consume held items. Every interpolated field (title, status, task id,
excerpt, error reason) passes through the v2 `escapedHeldField` (newlines, separators and tag
delimiters escaped) before it is concatenated; a Kotlin writer MUST escape the same fields. The parent session is the durable
`parentSessionId`, unless a chat parent was replaced by an erasure epoch switch; then the wake goes
to the current main session (§7.4). Task/routine parents keep their owner session.

### 7.1 Completed (settled) wake

For an asynchronous task whose parent is `chat`, after the terminal record and `task.settled` are
persisted, the runtime attempts exactly one hidden wake:

```
[SAND_HIDDEN_PROMPT][subagent]
<title> | <status> | <taskId>
<excerpt of the final text, ≤1200 characters>
```

When a verifier ran, the body is the verifier report form instead (status/verdict/summary/refs/
unverified/budget + the frozen `[verification_instruction]`). The request id is
`task-settled:<taskId>`.

This wake is **not** guarded by `wakeDelivered` and does not set it. Consequences:

- In-process, the wake is attempted once after settlement.
- A crash after the record/`task.settled` is durable but before/during the wake is **not** replayed
  by restore: the restored record is terminal, not interrupted. This is a known divergence from
  the D12 outline's "wake exactly once / durable marker" phrasing (D12 §7 ruling 3). The
  interrupted and denied wakes do have durable markers; the completed wake does not.
- A failed wake does not change the task record; the task remains `completed` and the user may
  never hear about it. Do not convert a failed wake into `failed`.

### 7.2 Interrupted wake

Queued by `workerRestarted`, `markTaskInterrupted` (host park) or restore (§6):

```
[SAND_HIDDEN_PROMPT][subagent]
<title> | interrupted | <taskId>
App 重启时中断了这个任务，结果还不完整。
```

- Request id: `task-interrupted:<taskId>`.
- `deliverInterruptedTaskWakes()` iterates the queued ids; for each task that is still
  `interrupted` and not `wakeDelivered`, it runs the hidden turn. Only `status == completed`
  counts: set `wakeDelivered = true`, write `task.updated` (`persisted:wake:<taskId>`), remove the
  id, and increment the returned count. A failure leaves the id queued for a later call.
- The same request id is reused on retry, so the DSH prompt dedupe key prevents a second turn if a
  crash happened between the turn and the marker. A second call after success returns 0.
- Restore queues at most one id per task; a task already `wakeDelivered` is not queued.

### 7.3 Denied wake

When a parked task is denied or expired (not cancelled), and the task is asynchronous with a
`chat` parent and `wakeDelivered == false`:

```
[SAND_HIDDEN_PROMPT][subagent]
<title> | denied | <taskId>
用户没有批准待确认的操作（<approval_denied|approval_expired>）。任务已经结束，没有执行。请如实告诉用户这次任务被拒绝了，不要把它说成已完成。
```

- Request id: `task-settled:<taskId>:approval:<approvalID>`.
- On success: set `wakeDelivered = true` and write `task.updated`
  (`persisted:denied-wake:<taskId>`). On failure: leave the record durable (`denied`) and do not
  turn it back into a success; this revision does not automatically retry a failed denied wake
  after the decision is consumed.
- A cancelled approval is `stopped` (`approval_cancelled`) and sends no wake.

### 7.4 Parent routing after an erasure epoch switch

`parentKind == chat` and `ownerBotId == this Bot`: if the durable parent session is no longer the
current main session because an erasure epoch replaced it, route the wake (and allow
`AwaitTask`/`StopSubagent` reads/stops from the successor) to the current main session. Every other
task keeps its recorded owner. A task's own `sessionId` is never replaced or reused.

## 8. Request ids

| purpose | id |
| --- | --- |
| child turn | `task-turn:<taskId>` |
| child turn resumed after approval | `task-turn:<taskId>:approval:<approvalID>` |
| completed parent wake | `task-settled:<taskId>` |
| denied parent wake | `task-settled:<taskId>:approval:<approvalID>` |
| interrupted parent wake | `task-interrupted:<taskId>` |
| verifier turn | `task-turn:verifier-<verificationId>` |

These are the same prefixes as the turn-origin table (`README` §4.1): `task-turn:` → origin `task`,
hidden; `task-settled:`/`task-interrupted:` → origin `task-wake`, hidden. A bare prefix or a
whitespace-only payload is `unknown`, never hidden. The approval suffix still classifies by the
leading prefix. A replay of the same id must reuse the DSH dedupe key; a random id is never
acceptable for a task turn or a wake.

## 9. Timeout, cancel and reconcile

### 9.1 Timeout

- `Task.timeout_ms` is a **budget**, not a turn kill: it is persisted in the snapshot, written as
  `budget_ms` in the child's `<task_contract>` when no `max_duration_ms` is given, and used to
  derive the verifier budget. The runtime does not cancel the child turn at this value. The
  dispatch range is 1,000–300,000.
- `AwaitTask.timeout_ms` is a caller-side wait bound (1,000–600,000, default 180,000). At the
  deadline it returns the current record (typically `running`), not an error; the task continues.
- Approval wait timeouts belong to P05 (`mcp-endpoint.md` §2.7): an interactive approval denies at
  300,000 ms; a durable approval is parked and reconciled, not killed.

### 9.2 Stop / late result

`StopSubagent` is the cancel path (§4). A child turn or work item that finishes after the
generation advanced is ignored: the stopped record is authoritative and no `task.settled` with a
late result is written. A late parent wake is not opened for a stopped task.

### 9.3 `waiting_approval` reconcile

- A decision that arrives while the task is still `running` is remembered
  (`earlyApprovalDecisions`) and applied after the turn parks.
- `workerRestarted` preserves `waiting_approval`, then `reconcileWaitingApprovals()` applies any
  durable decision that already exists: `allowed` → `running` + a resume turn with
  `task-turn:<taskId>:approval:<approvalID>` and an `[approval_resume]` suffix; `denied`/`expired`
  → `denied` with `approval_denied`/`approval_expired`; `cancelled` → `stopped` with
  `approval_cancelled` (no wake).
- Restore at process start does not itself call `reconcileWaitingApprovals`; the host MUST call it
  on the new process's Worker-restart/recovery path. Until then the task stays `waiting_approval`
  and `AwaitTask` returns that record.
- A stop of a parked task cancels the durable approval with reason `task_stopped` and writes
  `stopped`; no wake.

### 9.4 Host park vs real failure

`beginHostPark()` marks a deliberate Worker park (the S6 epoch eraser). A `session/follow` EOF or
transport error inside that window is an expected interruption: `markTaskInterrupted` (status
`interrupted`, `worker_restarted`, queued wake), never `failed`. Outside the window the same EOF is
a real `failed` with the transport error. `endHostPark()` clears the flag after the replacement
Worker is attached.

## 10. Held inbox and `SendToUser` interaction

- `Task` does not read, stage, consume or clear held inbox items. Starting a task from a chat turn
  leaves pending held items pending.
- A settled/interrupted/denied wake is hidden (`[SAND_HIDDEN_PROMPT]`), not a user/held turn, so it
  does not fold the held block and does not call `wakeWithHeldMessages`. The next **visible** user
  turn delivers pending held items through the existing v2 mechanism.
- `SendToUser` is refused in the hidden wake (`hiddenTextSessions`); it cannot be used to route a
  task result to the peer. A task result reaches the user through the wake's own text or through a
  later `SendToUser` in a visible turn.
- A task child that calls `SendToUser` is refused (`只有主聊天可以主动发消息`); task traffic is not a
  user chat.

## 11. Compatibility and version

- No new event type, table, column, endpoint or header. `task.created|updated|settled|started|
  stop_requested|resumed` are the existing durable event types; `persistedTask` is additive inside
  `data` and old readers ignore it.
- A task record without `persistedTask` is legacy and ignored on restore (§6). This is a stated
  compatibility choice, not data loss: the terminal `task.settled` widget row still projects.
- Status `interrupted`/`waiting_approval`/`denied`/`stopped` are additive free-form strings in the
  existing event data; old consumers render an unknown status conservatively. The old D13 summary's
  `cancelled` never appears (use `stopped`).
- `authorization` and the S3 fields are optional in the snapshot; a missing value restores the
  workspace-only default / "no completion condition", never an unrestricted or unverifiable task.
- No migration, no rollback special case: old rows are read, never rewritten. The only new writes
  are additive fields inside existing events.

## 12. Freeze rulings (D12 outline vs Swift/golden)

1. **`stopped`, not `cancelled`.** The outline lists `cancelled` in the task statuses; Swift's
   stop path writes `stopped`, and `denied`/`waiting_approval` are additional statuses. Freeze the
   §1 domain; Kotlin MUST NOT emit `cancelled` for a task. (`routine` uses `cancelled`; do not mix
   the two.)
2. **`persistedTask.createdAt` is the snapshot write time.** The outline implies a creation time;
   Swift re-stamps `now()` on every `persistTask`. Freeze Swift; a stable creation timestamp would
   be a new field.
3. **The completed wake has no durable `wakeDelivered` marker.** The outline says the wake marker
   is part of the snapshot and the wake happens exactly once. Swift marks only interrupted and
   denied wakes. A crash after a completed record and before its wake loses that wake; restore does
   not replay it. Freeze Swift and record the gap; do not add a second wake path.
4. **`Task.timeout_ms` does not kill the turn.** The outline's "timeout" section can be read as a
   turn timeout. Swift uses it as the child contract/verifier budget; only `AwaitTask.timeout_ms`
   bounds a wait. Freeze §9.
5. **`task.stop_requested` has a generated event id.** D13's `tool-contracts.md` §4.3 said
   `stop:<taskId>`; the Swift writer passes no event id for that event. Freeze the generated id and
   the idempotent `settled:<taskId>`.
6. **Legacy records without `persistedTask` are ignored, not interrupted.** D12 allowed either;
   Swift's restore skips them. Freeze "ignored" and the `unknown task` result.
7. **`waiting_approval` is terminal for `AwaitTask` but survives a restart.** It is not mapped to
   `interrupted`; a decision later resumes or closes it. Do not make `AwaitTask` wait through the
   approval.
8. **`StopSubagent` on a parked task cancels the durable approval** with reason `task_stopped` and
   writes `stopped`; the cancelled approval path writes no wake.
9. **The normal wake request id is `task-settled:<taskId>`,** including after an approval resume;
   the approval-resume turn itself is `task-turn:<taskId>:approval:<approvalID>`. The denied wake
   is the only `task-settled:<taskId>:approval:<approvalID>` form.
10. **`task.started` is written by the tool after the executor's `task.created`.** Do not move the
    durable create into the tool; a crash between the two would leave a running task with no
    record. The execute task path persists `task.created` before work begins.

## 13. Shared fixtures

`golden/task-cases.phone.json` (phone-only; `upstream: []`):

- `contract`: statuses, terminal sets, defaults/ranges, request-id templates, `persistedTask`
  required/optional keys, wake prompts and exact error strings.
- `valid`: 6 lifecycle cases (sync completed, async running, await completed, await timeout,
  stop by `task_id`, stop by `id`) with the expected record, authorization, event order, prompt
  request ids and persisted snapshot.
- `invalid`: 14 failure cases, including every `Task`/`AwaitTask`/`StopSubagent` validation string,
  unknown task, foreign session and a task child without delegation.
- `restoreCases`: interrupted + wake-once, settled-wins, waiting-approval survives, legacy ignored.
- `requestIdCases`: the five frozen request-id forms with their turn-origin classification.

`Tests/PhoneDSHBotTests/MCP/BotTaskCasesTests.swift` reads the file and drives the real
`BotMCPRuntime` tool layer, `BotDSHRemoteRuntime` and SQLite event store; it seeds `persistedTask`
events rather than hand-copying a record. `tools/validate_vectors.py` checks the contract values,
snapshot keys, restore mapping, request ids and nine mutations. `export-manifest.json` records the
digest.
