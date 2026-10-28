# exec.md — execution, idempotency and step records (phone-dsh-v1, proto 1)

Status: normative. `EXEC_REQ`, `EXEC_EVT` and `EXEC_CTL` are the frames of channel.md §4.2–§4.4;
their request and event fields are the exec-bridge v1 shapes. Two execution paths exist: commands
run **in the worker** (default, including `bash -c` and everything that writes the workspace) and
**read-only accelerators** run on the host. The host observes and persists the step state machine.

## 1. Two idempotency keys (D10)

Both keys exist and are never conflated:

- `XL_IDEMPOTENCY_KEY` — unchanged tool-journal key `xl1-<32 lowercase hex>`, derived from the
  session and call identity. It is injected into the command environment and identifies the tool
  call (the step). Nothing in this specification redefines it.
- `idem_key` — 64 lowercase hex characters carried in EXEC_REQ, derived as

```
idem_key = sha256( XL_IDEMPOTENCY_KEY ‖ 0x1F ‖ canonical_json(argv)
                   ‖ 0x1F ‖ cwd ‖ 0x1F ‖ env_hash )
```

  - `canonical_json(argv)` is the canonical JSON array of channel.md §5 (UTF-8, no insignificant
    whitespace, integers only, `/` not escaped, no `\u` escapes for non-ASCII).
  - `cwd` is the exact absolute path string of EXEC_REQ, not normalized.
  - `env_hash` is the lowercase hex sha256 of the canonical JSON of the `env` object, including
    `null` values (an absent `env` is `{}`). Because the key is injected into the command
    environment, it is normally a member of `env` as well.
  - The separators are single bytes `0x1F`, not text.
  - **Fallback** when `XL_IDEMPOTENCY_KEY` is absent: replace the first segment with
    `session_id ‖ 0x1F ‖ turn_id ‖ 0x1F ‖ step_id`, where `session_id` follows D6 and `turn_id` and
    the D20 ordinal `step_id` are unsigned decimal ASCII without leading zeros. The rest of the
    formula is unchanged.
  - The checksum is over the byte concatenation; the result is lowercase hex, no prefix.

**One step id per call (D20).** `step_id` is the decimal ordinal of the tool call within its turn:
the first tool call dispatched in a turn has `step_id = 1`, and every later tool call of the same
turn adds one (`2`, `3`, …). The worker assigns the ordinal in dispatch order as unsigned decimal
ASCII without leading zeros; a re-issued or replayed request of the same call keeps its ordinal.
`turn_id` and `session_id` come from the DSH session. The exec dedup entry (§2) and every step-record
line (§4) store the same decimal `step_id` and the enclosing `turn_id`; the tool-journal
`XL_IDEMPOTENCY_KEY`, when present, locates the same step in addition and never changes `step_id`.

`golden/frames/exec-req-1.json` pins the derivation: `XL_IDEMPOTENCY_KEY` =
`xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0`, argv `["rg","--json","needle"]`, cwd `/dsh/workspace`,
env_hash `1593f0621f1c7147f4fcd89aded71706fa43da470d2b5276c5de90d4d8fe9741`, idem_key
`2d3562b36e18c2441bd7bb4ed95c67bd72a86983387bd7f04f6d1ef1668cc81a`. The checker re-derives it.
The host rejects an `idem_key` that is not 64 lowercase hex with `BAD_PAYLOAD` (channel.md §10).

## 2. Dedup table, replay and conflict (D10)

The host keeps a persistent dedup table under `Library/xl/<workspace_id>/exec/`, one file per key:
`exec/<idem_key>.json` (`idem_key` is 64 hex characters and safe as a file name). The entry records
`{v:1, kind:"exec", idem_key, exec_id, argv, cwd, step_id, turn_id, created_at_ms, terminal, events[]}`;
`step_id` (the D20 ordinal) and `turn_id` are copied from §1, so this entry and the step record
locate the same step. MCP entries of §5 use the same file layout with `kind:"mcp"`. The intent entry
is written and fsynced before the process starts; each event is recorded before it is emitted, so a
replay can never omit an event the worker already saw. Files are written with the same temp-file +
rename + directory-fsync rule as `manifest.json` (wal.md §7.1) or appended per entry.

- **Replay.** A repeated `idem_key` with the same `argv` and `cwd` is never executed again. The host
  replays the recorded event stream from `seq = 0` on a new `EXEC_REQ`; the `start` event carries
  `"replayed": true` (exec-bridge v1 §4.1/§4.5). If the recorded stream is still live, the host
  replays the recorded prefix and continues from the provider; a second process is never started.
  If the record has no terminal event because the host died mid-execution, the host appends a
  terminal `{"type":"error","code":"interrupted",...}` event instead of executing, and marks the
  entry terminal. Replayed events keep the recorded `exec_id`; the worker derives that id
  deterministically from the same tool call, so it matches the re-issued request.
- **Conflict detection compares `argv` and `cwd` only.** Different `env`, `stdin`, `deadline`,
  `grace_ms`, `tier`, `confine`, `requires_mseq` or connection state are not conflicts. A repeated
  key whose `argv` or `cwd` differs is answered with a terminal `EXEC_EVT` error
  `exec_id_conflict`; the recorded entry is left unchanged and nothing executes. An `exec_id` may
  not be reused for a different `idem_key`.
- **Retention.** An entry is retained at least until the step is `journaled` and the tool result is
  durable, and is pruned with the journal quota (budgets.md, W1); the table survives every boot and
  is the reason a re-issued EXEC_REQ after reconnect (channel.md §9.5) has no second side effect.
- **Admission.** While admission is closed the host starts no execution; the request receives a
  terminal `EXEC_EVT` error (`admission_closed`) and is not added to the dedup table as executed.
- `exec_id` follows D6 and identifies the process for `EXEC_CTL` and events; the worker uses one
  `exec_id` per spawn, conventionally `<XL_IDEMPOTENCY_KEY>-<n>`.

### 2.1 `requires_mseq`

`requires_mseq` is the VFS mseq through which this command needs the workspace to be stable; `0`
means no dependency. Before dispatch the host MUST have appended every mutation with
`mseq <= requires_mseq` to the WAL (level 1) and applied it to the view the accelerator reads:

- `acked_mseq < requires_mseq` → the request waits; it is not executed early.
- materialization of a path touched at or below `requires_mseq` is waiting for a base-mismatch repair
  (wal.md §5.1) → the host waits for the resolving complete write; the accelerator never reads a
  stale or deferred view.
- `requires_mseq = 0` → dispatch as soon as admission is open.
- the deadline or a closed admission while waiting ends the request with a terminal error and no
  execution; the dedup entry stays replayable.

`requires_mseq` is a readiness fence, not a new idempotency key. VFS and exec frames share the
ordered channel, but the host's WAL/materialization pipeline may lag the channel; this field makes the
dependency explicit.

### 2.2 `grace_ms` and deadlines

`grace_ms` follows exec-bridge v1: an integer `1..60000`, absent means `3000` (exec-bridge v1 §4.1
request fields, which set the same maximum). `0`, negative or larger than 60000 is `BAD_PAYLOAD`; the
host never clamps silently. Cancel and deadline deliver SIGTERM to the process group, wait `grace_ms`,
then SIGKILL (exec-bridge v1 §4.4). A deadline that has already passed before dispatch yields a
terminal `error` event and no execution.

## 3. Executor inversion (D12)

The default executor is the worker itself. `bash -c`, shell built-ins and every command that can
write the workspace run in the official runtime's JavaScript shell inside the worker (later Wasm
brush / just-bash); they never travel as EXEC_REQ and never execute in the App.

Only read-only **accelerators** advertised in the host HELLO caps may travel as `0x20`:

| `accelerator:<name>` | Command |
|---|---|
| `accelerator:rg` | `rg` |
| `accelerator:jaq` | `jaq` |
| `accelerator:ts-parse` | `ts-parse` |
| `accelerator:ts-query` | `ts-query` |
| `accelerator:phone` | `phone` |
| `accelerator:ctx` | `ctx` |

- A command is an accelerator only when `argv[0]` is exactly one of the advertised names. Anything
  else stays worker-local (or fails in the worker); it is not forwarded because "it looked
  read-only".
- The host verifies the name against its own caps before starting. An unadvertised command is
  answered with a terminal `unsupported` error and is not executed. A missing `accelerator:`
  capability means the worker must run the command itself.
- **`confine` keeps the exec-bridge v1 values and is never a rejection criterion.** The host validates
  `confine` against its advertised capabilities; `confine.mode` is `read-only` or `workspace-write`.
  Accelerators are read-only by construction, so the host runs them read-only regardless of the
  requested mode. A request with `confine.mode = "workspace-write"` — the canonical
  `golden/frames/exec-req-1.json` sends it with `rg` — is executed, never rejected, and the effective
  confinement is read-only, not negotiated with the worker. The requested `confine`, `tier` and
  transport fields are not part of the identity or conflict check (§2). Only an `argv[0]` that is not
  an advertised accelerator is `unsupported`.
- Accelerators never write the workspace. Their effects are reads; a write attempt fails. `exit`
  carries **no change manifest**: VFS changes of a worker-local command travel as ordinary VFS_MUT
  frames at their own mseq and are journaled independently of the exec event stream.
- `EXEC_CTL` `cancel` and `stdin` map to exec-bridge v1 cancel/stdin. Events follow exec-bridge v1:
  `exit` is sent immediately after the process exited and both streams reached EOF; background
  children are reported with `quiescent: false` and a later `quiescent` event. The host keeps an
  accelerator running when its connection drops and retains its events for replay under §2.

## 4. Step state machine (D13)

The App observes and persists a step record per tool call; the worker never writes it. The seven
progress states are unchanged (D13); the terminal `abandoned` owner record is an amendment to D13
recorded in [README.md](README.md) §4. The states are ordered, followed by that terminal owner:

| # | State | Entered when | Evidence |
|---|---|---|---|
| 1 | `model_streaming` | the host model gateway starts streaming the model response for the turn that produces the call | gateway |
| 2 | `tool_dispatched` | the journal's dispatched record for the call is durable, before the tool body runs | JOURNAL frame |
| 3 | `exec_running` | an `EXEC_EVT start` for a host-executed accelerator of this step is observed | EXEC frame |
| 4 | `exit_persisted` | the terminal exec event is durable in the ledger (§2) | EXEC frame + ledger |
| 5 | `checkpoint_applied` | the tool-call checkpoint covering this call is persisted | checkpoint record |
| 6 | `wal_written` | every VFS mutation of the step is WAL-appended at level 1 (`acked_mseq` covers its last mseq; a read-only accelerator is immediate at its `requires_mseq`) | VFS_ACK |
| 7 | `journaled` | the journal's completed record is durable (level 1; level 2 at the next checkpoint or epoch close) | JOURNAL frame |
| terminal | `abandoned` | a Worker termination, failed drain, or planned Worker restart left the step without a terminal journal record after the host drove the replacement Worker's write-open reconcile for each affected stored session and the bounded grace expired | host reconciliation |

- A **worker-local `bash -c`** step records exactly the three tool-call transitions
  `tool_dispatched → wal_written → journaled`. `exec_running`, `exit_persisted` and
  `checkpoint_applied` do not apply: the host never sees the process. `model_streaming` belongs to
  the turn rather than to an individual tool call (D20): it is recorded once on the enclosing turn and
  attached to the step record when the dispatched journal record resolves its id.
- A **host-executed accelerator** step records all seven; `exit_persisted` and
  `checkpoint_applied` exist only for it (D13). Transitions are monotonic; replaying an earlier
  state is ignored, and a forward gap is filled only from the evidence above, never guessed.
- **`abandoned` is not a tool result.** It only records that the host gave up ownership of an interrupted step after the replacement
  Worker failed to reconcile it, so `steps/<session_id>.ndjson` and the per-step snapshot close instead of staying at `tool_dispatched`
  forever. It never fabricates a completed journal record, never produces tool-result evidence, and is terminal: a later journal record
  cannot move the step to `journaled`.
- **Reconcile before abandoning.** DSH reconciles the tool journal only when a stored session is opened for writing
  (`sessionPersistence.open(id, "write")`). History reads such as `session/page` and `session/follow` never open the writer and cannot
  settle a journal `start`. The host therefore calls the phone-only recovery route (`POST /api/pdsh-recovery/reconcile`), which opens
  each affected stored session for writing, lets the mounted phone persistence wrapper run DSH's reconcile, and immediately closes the
  handle without activating an Agent or sending a prompt. The terminal `tool/result` and JOURNAL `completed`/`resolved` records then
  arrive through the normal channel before the host's bounded grace expires. Only the steps still open after that attempt are abandoned;
  the host does not wait for a journal record the Worker never had a reason to send.
- **Interrupted-turn recovery (phone-only).** `POST /api/pdsh-recovery/resume` uses the same authenticated `/api` carrier as reconcile.
  Its JSON body is `{sessionId, timeoutMs?}` (1-5000 ms, default 3000). The Worker opens the stored session for writing and delegates to
  DSH's `interruptedTurnClosers` repair before closing the writer. It never publishes or disposes an Agent, clears the pending inbox, or
  sends a model request; queued next-turn user messages remain available. The response is
  `{ok:true,value:{sessionId,access:"write",closed:true,appended}}`. The host requires the resulting materialized `turn/end` proof;
  Swift does not write a DSH session record. Failures return `{ok:false,error:{code,message}}`: 415 content-type, 413 body, 400
  JSON/session/budget, 404 not-found, 409 writer-held, 499 cancelled, 504 timeout, or 500 failed. A timeout releases its writer and
  returns no success value. The separate reconcile route settles the tool journal; this resume route repairs an interrupted turn through
  DSH's existing repair API.
- **Storage.** `Library/xl/<workspace_id>/steps/<session_id>.ndjson` (D6-validated `session_id`), written only by the App. One JSON
  object per line, appended with `write` + `fsync`: `{v:1, step_id, turn_id, state, at_ms, mseq?, jseq?, exec_id?, settled_reason?}`.
  `step_id` is the decimal D20 ordinal assigned in §1 and `turn_id` is the enclosing turn; the triple `(session_id, turn_id, step_id)`
  locates a step and the journal key locates it too when present, so the dedup entry and this record always agree. Each accelerator
  `exec_id` and `idem_key` is stored in the same record. `settled_reason` is optional and is written only for `abandoned`
  (`worker-terminated`, `planned-restart`, `drain-timeout`). A torn final line is ignored on load; the last record for a step locator is
  the current state. A step interrupted between states is resumed from the journal's reconcile plan, not from memory.
- Step records are the observation log; they do not replace the authorities: the WAL mseq and the
  journal `(session_id, jseq)` remain the durable facts. A missing transition can always be
  reconstructed from those, and the record is then appended.

## 5. MCP calls

Every MCP tool request sent by the worker crosses the host loopback `/mcp` reverse proxy with an
`Idempotency-Key: <idem_key>` header (64 lowercase hex, §1). The host records the request and
response in the same ledger under that key with entry kind `mcp`, and replays the recorded response
for a repeated key instead of forwarding a duplicate side effect.

- The key is derived by the same formula: the canonical JSON of the MCP tool arguments object takes
  the `argv` slot and `cwd` is the request's `cwd` member, or the session workspace root when absent.
  When `XL_IDEMPOTENCY_KEY` is unavailable, the §1 fallback applies.
- The MCP JSON-RPC `id` is a transport correlation only and is never used as an idempotency key.
  Header names are case-insensitive on HTTP; the value is opaque and echoed unchanged.
- A request without the header is forwarded but cannot be deduplicated; side-effecting tools are
  expected to send the header.

## 6. Later waves
The fence token, admission and the handoff/reclaim sequence are fixed by handoff.md (W1); the host
state machine, transition table, driving signals and budget constants are fixed by budgets.md (W1).
This file fixes only the two keys, the dedup/replay rules, executor inversion and the step records.
