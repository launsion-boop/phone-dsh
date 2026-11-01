# Event kinds and their projections — spec/host/v1

Status: normative, contract version `1`, MIT. Owner: host contract owner.

`schema/harness-event.schema.json` is the sole authority for a host event's `kind`: exactly 15 snake_case values.
The numeral is checked against the table and the schema by `tools/host_check.py`. The trajectory
oracle writes the same events as slash **projection types**, and the UI state machine needs two
families the host does not report. This file is the single crosswalk between the three vocabularies.

- A **projection type** is a trajectory row type (`spec/v1/trajectory.md`). It is never a host
  value and MUST NOT appear in an event's `kind`.
- A **synthetic type** is a row with no host kind; §2 defines how host events project it. The UI
  owns two families and the trajectory oracle owns one. It is **not a host report**.

The tables below are machine-read by `tools/host_check.py` and `spec/tools/cross_check.py`. Keep
cell one backticked and the `golden` column to `yes`, `no`, `folded` or `none`.

## 1. Mapping table

One row per host kind. `golden` says whether the projection type occurs in
`spec/v1/golden/trajectory/*/expected*.jsonl`: `yes`; `no` (declared, no golden case yet);
`folded` (no row of its own, folded into the type's `data`); `none` (no projection row).

| host kind | projection type | golden | producer |
|---|---|---|---|
| `assistant_message` | `assistant/message` | yes | `AM:82-88` |
| `permission_requested` | `permission/request` | yes | `AR:402-409` (live, best effort) |
| `question_requested` | `question/request` | no | `AR:410-422` (live, best effort) |
| `session_status` | `session/start` | yes | `AR:388-393`, `AR:430-433` (live, best effort) |
| `tool_call` | `tool/call` | yes | `AM:89-93` |
| `tool_result` | `tool/result` | yes | `AM:94-107` |
| `turn_ended` | `turn/end` | yes | `AM:76-79` |
| `turn_started` | `turn/start` | no | `AM:74-75` |
| `user_message` | `user/message` | yes | `AM:62-66` |
| `usage` | `assistant/message` | folded | `AM:85-88` (`data.usage`) |
| `assistant_delta` | — | none | `AR:356-357` |
| `reasoning_delta` | — | none | `AR:358-361` |
| `progress` | — | none | `AM:80-81` (§2 carrier) |
| `exited` | — | none | no Swift producer in the baseline |
| `inbox_spliced` | — | none | `AM:67-73` |

`usage` has no row of its own: one DSH `assistant/message` that carries `data.usage` yields both
`assistant_message` and `usage` (`AM:82-88`), and the projection folds the counters into the
`assistant/message` row's `data.usage` (the `reorder-window` case under
`spec/v1/golden/trajectory` carries the folded example). A consumer MUST NOT emit a separate
`usage` trajectory row.

`session/start` is the session-scope row (`turnID` `-`) and maps `session_status`, not
`turn_started`; the two are not aliases.

### 1.1 Declared, not projected

These authoring types are in the trajectory's vocabulary but MUST NOT produce a row: stage 1
drops them whole (`spec/v1/trajectory.md` §2).

| type | class | reason |
|---|---|---|
| `metric/sample` | authoring type | dropped whole by trajectory stage 1 |
| `perf/sample` | authoring type | dropped whole by trajectory stage 1 |
| `debug/clock` | authoring type | dropped whole by trajectory stage 1 |
| `host/heartbeat` | authoring type | dropped whole by trajectory stage 1 |

The five host kinds with `—` in §1 are not projected either; the table above is only for the
authoring-side names that never reach the host.

### 1.2 Measured members of `tool_result`

`tool_result` carries three optional measurement members beside `summary` and
`tool_result_detail`, so a UI can show what a tool cost without opening the audit detail. They
are optional on purpose: a producer that does not measure one leaves it out, which keeps every
existing encoder and golden valid (host README §2.4).

**Absent means "not measured".** A consumer MUST render the unknown state for a missing member
and MUST NOT substitute `0`, `0 ms` or `{}`: a fabricated zero is a measurement the host never
made.

| member | schema | meaning | projection |
|---|---|---|---|
| `bytes` | integer ≥ 0 | UTF-8 byte count of the tool output | `data.bytes` of the `tool/result` row |
| `duration_ms` | integer ≥ 0 | wall-clock tool duration in whole milliseconds | `data.durationMs` of the row |
| `meta` | object | producer JSON about the result, passed through unparsed | `data.meta` of the row |

The projected shapes are golden-backed: `tool-exec-noise/expected.jsonl:2` carries `bytes` 1536,
`durationMs` 10 and `meta`, and `turn-error-vs-complete/expected.jsonl:3` carries `bytes` 17 and
`durationMs` 10. The oracle normalizes a byte count to an integer (a `1.5 KiB` label becomes
1536) and a duration to the nearest 10 ms (`spec/v1/trajectory.md` §5); both are projection rules
applied when the row is built, never a second time by a consumer of the host event. `meta` is the
only arbitrary-JSON member in the host tree besides the command's `tool_call.arguments` (host
README §2.3), and the oracle rounds the numbers inside it by the same stage-3 rule.

## 2. Synthetic types

None of these is a host kind and no host frame carries one in `kind`. A host MUST NOT emit one.
A row is emitted only when the named source field carries the marker; the projection never
invents an attempt, a compaction or a decision the host did not report.

| synthetic type | projected from | rule |
|---|---|---|
| `llm/retry` | `progress`, `session_status`, `turn_started` | `progress.phase` is `llm/retry` or starts `llm/retry/` → one row, `data.attempt` = `step`, `data.of` = `of` when present; `session_status.status` starting `retry ` → the same row with the attempt parsed from the text; `turn_started` resets the attempt counter |
| `compaction/*` | `progress`, `session_status`, `turn_ended` | `progress.phase` `compaction` or starting `compaction/` opens `compaction/start`; the closing phase or the enclosing `turn_ended` closes it; `session_status.status` starting `compacting` opens the same row; the subtype after the slash is kept |
| `permission/result` | `permission_requested` | one row per answered request: `data.id` = the request id, `data.decision` = `allow`/`deny`; written by the client that answers, never by the host; `seq` is the writer's own next ordinal (the golden writes 2 after the request's 1), not a host seq |

The `llm/retry` and `compaction/*` families are turn-scoped and are cleared on a session switch
like any other turn row. Neither is a trajectory type and neither appears in a trajectory golden.
`permission/result` is the one synthetic type the trajectory oracle writes; it has no host kind.

**Not a host report.** With today's DSH backend the mapper emits `progress` only with
`phase: "step"` (`AM:80-81`) and `session_status` only `running`/`idle`, `error: …` or
`permission.resolved …` (`AR:388-393`, `AR:430-433`), so no synthetic row is produced today.
That is correct: the UI must not fabricate a retry or a compaction it cannot observe.

## 3. Projection rules

**Position.** A durable host event produces at most one row per projection type. The row's `seq`
is the harness `seq` of the source event, `dshSeq * 8 + part`, parts numbered in emission order
inside one DSH event (`AM:25-33`, `AM:111-118`). `seq` is strictly increasing per session; a gap
is legal and is never "missing events" (host README §2.5). A best-effort event (no `seq`) never
becomes a trajectory row; it may only feed a synthetic row. The one exception is a client-written
synthetic row such as `permission/result`, which carries the writer's own ordinal.

**Ordering.** Rows order by `(sessionID, turnID, seq)`; the oracle's ordering window and
duplicate rules apply unchanged (`spec/v1/trajectory.md` §3).

**turnID.** Session-scope rows (`session_status` → `session/start`) use `-`. Every other row
uses the enclosing DSH turn number (`data.turn`, an integer) formatted `turn-%04d`, which is what
the goldens carry (`data.turn` 1 ↔ `turn-0001` in `reorder-window/expected.jsonl`; the shape is
pinned by `spec/v1/schema/trajectory.schema.json`). `turn_started`/`turn_ended` project their own
integer `turn_id` the same way. A synthesized turn id with no integer turn number has no
trajectory row: the shape has no slot for it, and inventing `turn-0000` would merge turns.

**Unknown authoring type: drop.** A DSH `type` with no row in §1 and no rule in §2 is dropped:
no row is written, the stream keeps running, and its `seq` counts as consumed (`AM:108-109`;
host README §2.2 rule 2). It is never passed through verbatim, renamed by a guess, or parked in a
side channel. The only types with a defined projection are the ones named here.

**Unknown host kind: drop.** A consumer reading a newer host applies the same rule: drop the
event, keep reading, consume the `seq` (host README §2.2 rule 2).

## 4. Boundary: `turn-event` is a UiState node kind, never a host kind

The UiState tree sub-spec (`spec/v1/trajectory.md` §7, `spec/v1/schema/ui-state-sequence.schema.json`)
has its own closed `kind` vocabulary: `root`, `session`, `turn`, `turn-event`, `bubble`,
`tool-row`, `thinking-pill`, `approval-card`, `composer`, `fail-loud-banner`, `status`. A node
kind is never an event kind, and `turn-event` is the one name that reads like an event kind. It
is the node at the `event/<seq>` grammar level, i.e. the parent of one projected event row, not a
turn lifecycle marker: `spec/v1/tools/trajectory_norm.py` maps the kind to that segment and
requires an `event/<seq>/<slot>` row to name the `event/<seq>` node as its parent. The turn
lifecycle is already host-reported by `turn_started` and `turn_ended` in §1, which project
`turn/start` and `turn/end`.

So no sixteenth host kind hides behind the name: a host MUST NOT write `turn-event` in `kind`,
and `tools/host_check.py` rejects a mapping-table row for it as an unknown host kind, which is
how this boundary stays closed. Whether a projector materializes the `event/<seq>` node at all is
a UiState-tree decision, not this tree's; only the name's vocabulary is settled here.
