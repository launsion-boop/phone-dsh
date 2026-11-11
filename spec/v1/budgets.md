# budgets.md — host state machine, signals and budgets (phone-dsh-v1, proto 1)

Status: normative. This file fixes the host states, their transition table and driving signals (D14)
and the memory, concurrency, latency, restart and recovery budgets and disk quotas of PLAN §2.5.
Admission is defined by channel.md §4.5 and §4.7 and by [handoff.md](handoff.md) §1; the WAL,
materialized copy and manifest are those of [wal.md](wal.md). All values are constants checked by the
controller; nothing here is a measurement.

## 1. States

The host is always in exactly one of these states. Admission is `open` only in `Running`.

| State | Admission | Meaning |
|---|---|---|
| `Running` | open | Foreground; the worker executes tool work and the phone holds the fence. |
| `Draining` | closed | Close admission; until the 20 s deadline, wait for in-flight work and for every issued VFS_RESYNC whose Worker is still connected to be answered and settled (wal.md §5.1), then close a WAL epoch. A mismatch still unrepaired at the deadline enters `Failed` per wal.md §5.2 with its path and mseq; a disconnected Worker is not waited for. |
| `Parked` | closed | Background; WAL durable, WebContent stopped, no work scheduled. |
| `Recovering` | closed | Lease verification, WAL recovery, overlay pack, worker boot, replay; no side effect. |
| `Backoff` | closed | Upstream 429/5xx or no network path; retry with backoff and jitter. |
| `HandingOff` | closed | Fence CAS, snapshot and segments are being transferred to the remote. |
| `Remote` | closed | The remote holds execution authority; the phone only observes. |
| `Reclaiming` | closed | Reclaim in flight; the returned fence and segments are being applied. |
| `Failed` | closed | Terminal for this incarnation; no automatic in-process exit. A new process follows the persisted failure retry window. |

- `Recovering` keeps admission closed until the lease is verified and the recovered workspace is
  consistent with the WAL (wal.md §10). A worker HELLO before verification does not open admission.
- Every side effect needs the last LIFECYCLE and the last FENCE admission to be `open`
  (channel.md §4.5, handoff.md §1); during `Recovering` both are `closed`.
- A typed transient fault enters `Backoff`; a terminal workspace fault enters `Failed`. In the same
  incarnation only an explicit user reset leaves `Failed`; new-process retry never skips WAL/fence verification.

## 2. Transition table (D14)

Every row is fixed; the `Signal` column names the driving input of §3 and the guard is checked
before the transition.

| From | To | Signal / guard | Actions |
|---|---|---|---|
| boot: persisted `Running`, `Draining` or `Recovering` | `Recovering` | process start | Cold recovery: WAL scan, replay, overlay, worker boot; admission closed. |
| boot: persisted `Failed` | `Backoff` or `Recovering` | process start | A future `next_retry_at_ms` restores closed Backoff; an elapsed or absent deadline starts Recovering, never open admission. |
| boot: no persisted state | `Recovering` | process start | New workspace; WAL starts at mseq 1. |
| `Running` | `Draining` | scenePhase background | Close admission; start the background task and the 20 s timer. |
| `Draining` | `Parked` | background drain complete, or 20 s deadline | Close the epoch (wal.md §5.2), fsync, stop the worker. The wait includes outstanding VFS_RESYNC answers while the Worker is connected; a deadline ends the wait and aborts in-flight channel requests. If a base mismatch is still unrepaired the state becomes `Failed` (wal.md §5.2); otherwise the epoch close still runs. **Interrupted park.** If the escalation stopped the old Worker but its connection never reached a clean end (iOS froze or killed the WebContent), the escalation refuses to pack an overlay or boot a replacement, since the overlay could lag the WAL. That outcome still parks: after the loopback is gone the park closes the old connection, **requires** inbound-write quiescence (a handler still dispatching keeps the fail-loud path), then seals the WAL at its tail and records `fence.wal_seq` there (wal.md §5.2, §5.3). Turns the drain saw open are recorded as interrupted, never completed; the host writes no session record (D13/D14). The next `Parked → Recovering` boot mounts an overlay packed at the sealed tail and runs the Worker's `pdsh-recovery/resume` write-open for those sessions before admission opens, so DSH closes them as interrupted; that repair is bounded and best effort, reported when it fails and never blocking the resume. A frame still in the frozen socket was never acknowledged and is not in the WAL, so discarding it equals a crash. A teardown (`stop()`) keeps the fail-loud contract for the same outcome. |
| `Draining` | `Recovering` | restart path: planned WebContent restart, WebContent termination, or boot | Close the epoch, restart the worker, verify the lease. |
| `Parked` | `Recovering` | scenePhase active | Boot the worker and verify the lease; admission stays closed. |
| `Running` | `Recovering` | planned restart (policy, §4) or WebContent termination, still foreground | Close admission, close the epoch, restart WebContent at a tool-call boundary. |
| `Recovering` | `Running` | lease verified and admission opened | Send FENCE/LIFECYCLE `open`; resume work. |
| `Running` | `Backoff` | 429/5xx response, NWPath unsatisfied, or typed transient boot/transport fault | Close admission; persist the retry schedule. |
| `Backoff` | `Running` | Retry-After elapsed, network path satisfied, one probe succeeded | Reopen admission after a lease check. |
| `Running` | `HandingOff` | handoff decision while foreground | Close admission, close the epoch, freeze `wal_seq`, start handoff.md §2. |
| `Draining` | `HandingOff` | handoff decision while draining | Finish the epoch close, then start handoff.md §2. |
| `HandingOff` | `Remote` | fence, snapshot and segments accepted; remote admission open | The remote holds authority; the phone keeps its WAL read-only. |
| `HandingOff` | `Reclaiming` | handoff failed after a successful fence | Reclaim with the token before any local work reopens. |
| `Remote` | `Reclaiming` | reclaim requested (user or foreground return) | POST the reclaim token (handoff.md §5). |
| `Reclaiming` | `Recovering` | response applied, new fence persisted, epoch closed | Verify the lease; admission stays closed until `Recovering → Running`. |
| any state | `Failed` | `WAL_CORRUPT`, unrepaired base mismatch at an epoch close, materialization I/O failure, quota still exceeded after compaction, or an unrecoverable host defect | Close admission, record the condition, keep every durable WAL and journal byte. |
| `Failed` | `Recovering` | explicit user reset only, within this process | Clear the retry window; re-run recovery in this order: recover, pack the overlay, start the Worker, HELLO, VFS_RESYNC, settle. This row does **not** close an epoch; the next close is a periodic close or a drain. The WAL may still fail the same condition. |

No other edge exists. In particular, `Parked` never opens admission directly, `Remote` is never left
without `Reclaiming`, and a drain deadline never reopens admission.

## 3. Driving signals

| Signal | Source | Effect |
|---|---|---|
| scenePhase | App lifecycle | `background` → `Draining`; `active` → `Parked`/`Recovering` and lease verification. |
| background task expiry | iOS background task | Force the `Draining` deadline (20 s), abort in-flight requests, continue to the pending target. |
| WebContent termination | WKWebView delegate | Count it; in the foreground `Running`/`Draining` → `Recovering`. |
| planned restart timer | controller | Restart at a tool-call boundary when engine heap > 75% for 3 samples, after a WebContent termination, or after 24 h of continuous running; never mid-turn (§4). |
| thermalState | ProcessInfo | `fair` → sub-agent cap 1; `serious`/`critical` → LIFECYCLE `pause` at the next boundary, no new sub-agents, no new parallel accelerators. |
| battery / low power mode | ProcessInfo | Below 20 % and not charging, or Low Power Mode on → sub-agent cap 1, no optional accelerators; budgets are never raised. |
| NWPathMonitor | Network framework | unsatisfied → `Running` → `Backoff`; satisfied → `Backoff` → `Running` after one successful probe. |
| memory proxy | VFS bytes by prefix, session bytes, sampled engine heap, WebContent termination count | Budget actions in §4 order; VFS or heap pressure shares the same order; a hard cap after the actions → `Failed` (fail loud). |
| lease verification | controller and remote authority record | Required for `Recovering` → `Running`; failure keeps admission closed. |

**Engine-memory input sources (W2 rev 2, 2026-11-12).** In this revision the only **production**
input to the engine-memory side of the memory proxy is the platform **system memory warning**
(the `DispatchSource`/`didReceiveMemoryWarning` equivalent). The sampled engine heap named in the
row above and in §4 is `target`, not available: the repository has no production producer
(`PhoneDSHEngine` exposes no public heap probe, `WebEngineScripts` carries only console/boot, and
every `reportEngineHeapBytes` caller is a test). `reportEngineHeapBytes` remains the injection
point for tests and for the future P04 read-only probe. Until that probe exists, a missing sample
MUST NOT be read as zero, as headroom, or as a reason to raise a budget; the warning path uses the
existing action order `clearTmp → plannedRestart` and adds no UI prompt. The numeric §4 rows are
unchanged.

**Boot mapping for the rows above.** §2 lists the four persisted states it decided; these four were
left implicit and the port had to infer them, so they are written down here: persisted `Parked` →
`Parked` (the resume waits for an active scene), persisted `Backoff` → `Backoff`, persisted `Remote` →
`Remote`, persisted `HandingOff` follows the same closed retry-window boot mapping as `Failed`, and persisted
`Reclaiming` → `Recovering`. Only the `Parked` row has fixture evidence today
(`cold-start-after-reboot`); the other four are exercised by the transition matrix, not by a
perturbation fixture, and are marked accordingly. Classified failures persist optional `retry_count`,
`next_retry_at_ms`, and `failure_class`: delay is min(60 s, 5 s × 2^(retry_count − 1)), not a limit on process restarts; successful verified recovery resets it.

**Single-file limit versus the aggregate columns.** The aggregate columns (`workspace`, `VFS`, `heap`)
are budgeted for **that row's own** `single file` value. Raising `single file` is permitted up to the
row's `host maximum`, and the aggregates are then re-derived from the formula in this section — which
means they may exceed the numbers printed in the row. That is intended: the printed aggregates
describe the default single-file limit, not a ceiling that the derived values must stay under. An
implementation that raises the limit but keeps the printed aggregates is under-budgeting. The
`host maximum` column therefore documents the largest single-file value used by any row at or above
that tier; it is not a per-row permission that leaves the aggregates unchanged.

## 4. Budgets

Device tiers are selected once per boot from the physical memory ceiling. The 8 GB row is the
default; a lower row applies when the ceiling is below 8 GiB, and the 12 GiB row applies only when
the ceiling is at least 12 GiB. `MB`/`MiB` are 1 048 576 bytes.

| Resource | 12 GiB | 8 GiB (default) | 6 GiB | 4 GiB | ≤ 3 GiB |
|---|---|---|---|---|---|
| Engine heap | ≤ 832 MB | ≤ 448 MB | ≤ 256 MB | ≤ 192 MB | ≤ 144 MB |
| VFS logical bytes | ≤ 768 MB | ≤ 388 MB | ≤ 200 MB | ≤ 144 MB | ≤ 96 MB |
| VFS split: workspace / sessions / tmp | 576 / 96 / 96 MB | 288 / 50 / 50 MB | 120 / 40 / 40 MB | 80 / 32 / 32 MB | 48 / 24 / 24 MB |
| Single file | ≤ 256 MiB | ≤ 128 MiB | ≤ 48 MiB | ≤ 32 MiB | ≤ 16 MiB |
| Single file, host maximum | 256 MiB | 128 MiB | 128 MiB | 32 MiB | 16 MiB |
| WASI hot instance | ≤ 640 MB | ≤ 260 MB | ≤ 200 MB | ≤ 144 MB | ≤ 96 MB |
| App process | ≤ 540 MB | ≤ 230 MB | ≤ 140 MB | ≤ 120 MB | ≤ 100 MB |
| Peak | ≤ 50 % of the ceiling (6 GiB) | ≤ 50 % (4 GiB) | ≤ 50 % (3 GiB) | ≤ 50 % (2 GiB) | ≤ 50 % (1.5 GiB) |
| Sub-agents | ≤ 2; 1 when thermal fair | ≤ 2; 1 when thermal fair | ≤ 2; 1 fair | ≤ 1 | ≤ 1 |
| Loopback round trip | p95 < 5 ms | p95 < 5 ms | p95 < 5 ms | p95 < 5 ms | p95 < 5 ms |
| Planned WebContent restart | policy triggers, at a tool-call boundary | same | same | same | same |
| Recovery time target | `a + k·MB`, a ≤ 3 s, k ≤ 0.05 s/MB | same | same | same | same |

- The VFS caps are logical bytes and are enforced at write time; exceeding a prefix or the total is
  `ENOSPC` to the worker and is fail loud. `tmp` is cleared first under pressure because it is
  volatile (wal.md §6, §8); `home/` and `workspace/` are never evicted.
- The `tmp` bucket aggregates both volatile spellings, `/dsh/tmp/**` and `/tmp/**`; they resolve to
  one store, so a byte is counted once whichever name wrote it. They are the only writable non-sink
  roots. A `/dev/null` write is a device write and counts against no bucket.
- The single-file budget is the tier default above. The host may set `single_file_limit` in
  16 MiB ... 256 MiB: the 4 GiB and ≤ 3 GiB rows gate the value to their default, the 8 / 6 GiB rows
  accept up to 128 MiB, and the 12 GiB row accepts up to 256 MiB. A value outside the range is
  clamped, never a start failure.
- The workspace bucket is at least `2 × single_file_limit + headroom`, with 64 / 32 / 24 / 16 / 16 MiB
  of headroom for the five rows: 576 = 2 × 256 + 64, 288 = 2 × 128 + 32, 120 = 2 × 48 + 24, 80 =
  2 × 32 + 16, 48 = 2 × 16 + 16. The VFS logical cap is at least `workspace + sessions + tmp`, and
  the engine heap is at least the VFS logical cap. Raising the file limit raises workspace, VFS and
  heap in step; a configuration never lowers a bucket.
- A file larger than one mutation is published as one complete write followed by appended suffixes
  (channel.md §3.1, §6). An appended mutation carries only the suffix, never the complete post-write
  file: the host tracks the accepted logical size and refuses a chunk that would grow one file past
  the budget. The append path is O(chunk), not O(file), which is what the engine heap row assumes.
- The memory proxy includes the sampled engine heap. Exceeding the engine heap row triggers the
  action order below even while the VFS bytes are within budget; repeated WebContent terminations
  are likewise pressure.
- Budget actions under memory pressure run in this order and stop at the first one that restores the
  headroom: (1) clear the volatile tmp root (`/dsh/tmp/**` and `/tmp/**`); (2) planned WebContent
  restart at the next tool-call boundary; (3) handoff to the remote. A hard cap still exceeded after the actions is `Failed`.
- The recovery target is `a + k × MB`, with `a ≤ 3 s` and `k ≤ 0.05 s/MB`, where `MB` is the
  materialized tree in MiB rounded up. A full 128 MiB file costs 3 + 0.05 × 128 = 9.4 s; at the
  388 MB VFS cap the bound is 3 + 19.4 = 22.4 s, and at the 768 MB cap 3 + 38.4 = 41.4 s. The
  formula is unchanged; the values cover the larger workspace and the overlay repack.
- The loopback target is measured over at least 1000 sequential WebSocket echoes on the loopback
  origin and is informational for the controller; exceeding it never changes a state by itself.
- A planned restart or handoff starts only at a tool-call boundary: no frame is in flight, the epoch
  is closed (wal.md §5.2), and step records show no `exec_running` step. If a boundary does not arrive
  within 60 s, the controller drains and restarts anyway.

## 5. Disk quotas

| Store | Quota | Overflow rule |
|---|---|---|
| WAL segments | 512 MiB | Close the epoch, compact droppable segments and retry; still over after a second close → `Failed`. |
| Response log | 128 MiB | Drop complete, oldest replays first; a partial stream is never logged; still over → `Failed`. |
| Journal | 64 MiB | Prune entries whose step is `journaled` and durable; still over → `Failed`. |
| `video/` | 512 MiB (12 / 8 GiB; 384 / 256 / 192 MiB at 6 / 4 / ≤ 3 GiB) | Delete `completed` and already re-read sessions first; a session that was never re-read is never evicted; still over → `Failed`. |
| Domain stores (`session`, `memory`, `task`, …) | 64 MiB **per domain** | Refuse the write with an explicit quota error that names the domain, the quota and the usage; never evict, never truncate, never drop silently. `delete` releases the budget. A transaction that hits the quota rolls back unless the caller catches it. |

Quotas are absolute for every tier: a handoff or a restore does not raise them. None of these stores
ever evicts `home/`, `workspace/` or an un-journaled step; data is never silently dropped.

The domain-store quota is the one row that is a **policy default rather than a measured budget**: it
was chosen when the store landed, no workload has been profiled against it, and a deployment may
override it per domain. It is written down so an implementation cannot pick a number silently — the
row states the value in force, not a value that has been validated.
`Cache-Control: no-store` responses and lazy image shards are not persisted and do not count against
these quotas.

Repeated rewrites of one large file are reconciled by compaction, not by raising the quota. When an
append would cross the WAL quota the host closes the epoch in the D18 order, compacts every droppable
segment and retries; a second failure closes and compacts once more. After a close at most the newest
epoch-close segment and the open segment survive, so a 64 MiB rewrite cycle cannot accumulate five
whole-file records; if the quota is still exceeded after the second close the state becomes `Failed`.
The absolute WAL quota is 512 MiB because the 12 GiB row publishes 256 MiB files: one such file
rewritten twice would otherwise reach the former 256 MiB quota before compaction could help.
The `video/` store is a fourth quota-managed store: during encoding a video never touches the WAL
or the VFS, and a session's artefact counts against the workspace and single-file budgets only
after `video/read` has put it into the workspace. A session that is never re-read is marked
`orphaned` after 10 minutes and may be reclaimed; an unread session is never deleted to make room.

## 6. Revision note (large-file budget)

The W12-BIGFILE revision replaced the former row (engine heap 200 MB, VFS logical bytes 150 MB, VFS
split 50 / 50 / 50 MB, single file 15 MiB): that workspace bucket could not hold one 64 MiB file,
let alone two. The old row is superseded and not normative; 15 MiB survives only as the per-mutation
frame bound of channel.md. The recovery formula and the absolute WAL / journal quotas are unchanged.

The 12 GiB row (office/big-file) adds a larger workspace above the 8 GiB default: 256 MiB single
files, a 768 MB VFS, an 832 MB heap, a 640 MB WASI hot instance and a 540 MB app process. It is
selected only when the physical memory ceiling is at least 12 GiB; every lower tier keeps its
current row. The row raises the absolute WAL quota from 256 MiB to 512 MiB, because one 256 MiB
file rewritten twice would otherwise reach the old quota; the compaction rule itself is unchanged.

The VIDEO revision (spec-render-media-v1 §A) raises the 8 GiB single file from 64 to 128 MiB
(workspace 288, VFS 388, heap 448), so a 60 s 1080p artefact (96 MiB cap, ≈ 45 MB at 6 Mbps) fits
the published file budget, and adds the 60 s / 75 s duration, 4500-frame and 96 MiB output limits
per tier. The encoder's footprint is booked in the app process row (150 → 230 MB at 8 GiB,
400 → 540 MB at 12 GiB). Video artefacts live in the separate `video/` store of §5, so they do not
consume WAL bytes during encoding.

## 7. Target performance budgets (P03, W0)

Status: `target`. This section adds the performance rows the W0 baseline work will fill; it does not
change any value in §4 or §5. The numeric column is the literal `待基线` (baseline pending) for every
row: **no number printed here is a measurement**, and a row becomes a usable target only when a
device baseline report names the device model, commit, command and result. Until then the row is
not a pass/fail gate; it fixes the metric, the collection point and the two report画像 (light /
typical / heavy, plan §1.3) so two measurements cannot silently use different definitions.

| Metric | Unit | Light | Typical | Heavy | Collection point |
|---|---|---|---|---|---|
| Cold start to sendable | ms | 待基线 | 待基线 | 待基线 | process start → the first user message is accepted into the outbox and projected |
| First token latency | ms | 待基线 | 待基线 | 待基线 | prompt accepted → first model token reaches the page |
| fsync calls per turn | count | 待基线 | 待基线 | 待基线 | one user turn, all stores, counted at the `fsync`/`F_FULLFSYNC` call |
| Bytes written per turn | bytes | 待基线 | 待基线 | 待基线 | one user turn, WAL + materialized + journal + steps + exec ledger + response log |
| Idle 10 minutes: wakeups | count | 待基线 | 待基线 | 待基线 | process background for 10 min with no turn; CPU wakeups attributable to the host |
| Idle 10 minutes: bytes written | bytes | 待基线 | 待基线 | 待基线 | same window; every store, including a periodic epoch close |
| Host internal storage, steady state | bytes | 待基线 | 待基线 | 待基线 | WAL + materialized + journal + steps + exec + response log + caches; target formula in §9 |

- `待基线`（繁體寫作「待基線」）is one token, not a range. A report that substitutes an estimate (token count, prior
  device, another profile) does not fill the row.
- The first two rows are wall-clock latency and are **NOT_VERIFIED** until measured on a device;
  a simulator, a host build or a unit test cannot fill them.
- The turn rows count one ordinary user turn on the named fixture profile, not an average over a
  synthetic loop. The fixture definitions are `scripts/perf/` and `docs/perf/README.md`.
- This section is additive: no existing row or sentence above is superseded, and a row that later
  gains a number does not change §4 or §5.

## 8. Journal and step-record pruning (P03/P17, W2)

§5 already requires the journal to prune entries whose step is `journaled` and durable; that
sentence is made precise here because an implementation without a discardable set can only refuse
the write at 64 MiB.

- **Journal entry.** A journal entry may be deleted only when all of these hold: the step's
  `completed` record is present and its state is `journaled` (exec.md §4); that record is level-2
  durable (the journal `JOURNAL_ACK` level 2 was emitted, or a later epoch close covers it); no
  open recovery holds the entry; and no retained `start` record of the same step needs it for
  reconcile. Entries of a step whose terminal record is missing are never deleted. Deletion is
  whole-entry: a record is never half-removed, never rewritten with edited fields, and `jseq`
  values are never reused.
- **High-water retention (implementation constraint).** Pruning is a permission, not a requirement
  to delete to zero. The journal file header has no `jseq_base`; dropping a session's last record
  would lower `lastJseq` after a restart and make ChannelServer treat the next consecutive record
  as a gap. The host **MUST** keep, per session, the newest retained high-water/terminal record
  (and MAY keep the second-newest) when dropping it would decrease `lastJseq`; at most two records
  are kept for this reason. Retained records are kept whole, unmodified and with their original
  `jseq`. This floor does not widen any other deletion condition and never protects an
  un-journaled, non-durable or replay-referenced entry; keeping more than two records is not
  required and is not part of this rule.
- **Step record.** A line in `steps/<session_id>.ndjson` may be dropped only when the step's last
  recorded state is terminal (`journaled` or `abandoned`), the corresponding journal record is
  durable (for `journaled`) or the abandonment is durable (for `abandoned`), the step is not
  referenced by an open exec/dedup replay, and the file is first rewritten as a whole with the
  surviving lines. An open step's newest line and any line needed to identify it are never
  dropped. A torn final line is ignored and then removed by the rewrite, never treated as a
  state.
- **When.** Pruning runs after every successful epoch close (wal.md §5.2 step 5, before the
  level-2 ACK is considered complete is *not* allowed) and on a quota overflow before the fail-loud
  branch. It is silent: no user-visible prompt, banner or disabled state.
- **Crash safety.** A rewrite writes `*.tmp`, fsyncs it, renames it over the target and fsyncs the
  directory (wal.md §7.1 order). A kill before the rename leaves the old file, a kill after it
  leaves the new file; replay must accept either. Pruning never runs while the workspace is
  `Recovering`.
- **`JOURNAL_ACK` is unchanged.** Level 1 still acknowledges the append `write()`, level 2 still
  acknowledges the checkpoint/epoch fsync; pruning does not emit an ACK, does not lower a
  previously acknowledged level and does not let a not-yet-durable record be dropped. A pruned
  entry is invisible to replay, not "acknowledged and lost".
- **GAP.** `LogQuota.swift` currently has no discardable set and refuses at 64 MiB while every
  recovered body stays resident. That is a defect against this section, registered as GAP-38 in
  [README.md](README.md) §7, not a licence to raise the quota.

## 9. Host internal storage: total budget and levels (P03, W3)

The absolute per-store quotas in §5 are unchanged. This section adds the aggregate host-internal
view and the graded, silent actions; it is the only place the five levels are defined.

`hostInternalBytes` is the sum of the WAL, materialized copy, journal, `steps/`, `exec/`,
response-log entries that are not yet deletable, the overlay cache and the transcript snapshots.
It excludes the user workspace's own bytes only in the sense that the workspace is reported
separately as `workspaceLogicalBytes`; it is not excluded from the volume headroom. `availableImportantBytes` is
`volumeAvailableCapacityForImportantUsage` (falls back to the volume's available capacity where the
platform has no important-usage value).

| Level | Trigger | Automatic action | User-visible |
|---|---|---|---|
| 0 | after every epoch close | reclaim every droppable WAL segment and every response-log entry whose deletion condition holds (wal.md §12, gateway-security.md §11) | no |
| 1 | `hostInternalBytes > 1.3 × workspaceLogicalBytes` | the level-0 actions, then prune caches and cold snapshots; recreate them on demand | no |
| 2 | `availableImportantBytes < max(512 MiB, 10 % of the volume)` or the platform reports a low-space condition | level-1 actions, more aggressively; stop creating new caches; never touch §5's authoritative stores beyond their own rules | no |
| 3 | `workspaceLogicalBytes ≥ 90 % of the workspace bucket` | level-2 actions; emit one structured signal naming the largest files and sizes for the App to show after the turn | one card, at most once per workspace per day |
| 4 | no reclaimable data remains and the next write would fail | level-3 actions; fail the write with an explicit quota error that names the cause and the remedy | yes, that error |

- Levels 0–2 are completely silent. Level 3 produces a signal only; the App renders the card, and
  the model layer does not block the turn for it. Level 4 is the only new user-visible failure and
  it reuses the existing quota-error vocabulary rather than adding a second error meaning.
- Auto-deletion never removes `home/`, `workspace/`, a session log, or an un-journaled step. Only
  rebuildable content (overlay cache, transcript snapshots, response-log bodies whose deletion
  condition holds) may be removed, and a removed cache is rebuilt without a prompt or error.
- The 1.3 × workspace level-1 threshold and the level-2 headroom are **policy defaults, not
  measurements** (the same status as the §5 domain-store row); they are fixed here so an
  implementation cannot pick a different number silently.
- Level 4 is not a second quota for any store; §5's absolute values still govern, and a store
  below its own quota never fails because of this aggregate view.
