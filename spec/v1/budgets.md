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
| `Draining` | closed | Close admission, wait for in-flight work, close a WAL epoch; 20 s deadline. |
| `Parked` | closed | Background; WAL durable, WebContent stopped, no work scheduled. |
| `Recovering` | closed | Lease verification, WAL recovery, overlay pack, worker boot, replay; no side effect. |
| `Backoff` | closed | Upstream 429/5xx or no network path; retry with backoff and jitter. |
| `HandingOff` | closed | Fence CAS, snapshot and segments are being transferred to the remote. |
| `Remote` | closed | The remote holds execution authority; the phone only observes. |
| `Reclaiming` | closed | Reclaim in flight; the returned fence and segments are being applied. |
| `Failed` | closed | Fail loud; the user must act. No automatic exit from this state. |

- `Recovering` keeps admission closed until the lease is verified and the recovered workspace is
  consistent with the WAL (wal.md §10). A worker HELLO before verification does not open admission.
- Every side effect needs the last LIFECYCLE and the last FENCE admission to be `open`
  (channel.md §4.5, handoff.md §1); during `Recovering` both are `closed`.
- `Failed` is entered on an unrecoverable condition; a boot that finds a persisted `Failed` starts in
  `Failed`, and only an explicit user reset moves it to `Recovering`.

## 2. Transition table (D14)

Every row is fixed; the `Signal` column names the driving input of §3 and the guard is checked
before the transition.

| From | To | Signal / guard | Actions |
|---|---|---|---|
| boot: persisted `Running`, `Draining` or `Recovering` | `Recovering` | process start | Cold recovery: WAL scan, replay, overlay, worker boot; admission closed. |
| boot: persisted `Failed` | `Failed` | process start | Keep admission closed; report the user action needed. |
| boot: no persisted state | `Recovering` | process start | New workspace; WAL starts at mseq 1. |
| `Running` | `Draining` | scenePhase background | Close admission; start the background task and the 20 s timer. |
| `Draining` | `Parked` | background drain complete, or 20 s deadline | Close the epoch (wal.md §5.2), fsync, stop the worker. A deadline ends the wait and aborts in-flight channel requests; the epoch close still runs. |
| `Draining` | `Recovering` | restart path: planned WebContent restart, WebContent termination, or boot | Close the epoch, restart the worker, verify the lease. |
| `Parked` | `Recovering` | scenePhase active | Boot the worker and verify the lease; admission stays closed. |
| `Running` | `Recovering` | planned restart (2 h, §4) or WebContent termination, still foreground | Close admission, close the epoch, restart WebContent at a tool-call boundary. |
| `Recovering` | `Running` | lease verified and admission opened | Send FENCE/LIFECYCLE `open`; resume work. |
| `Running` | `Backoff` | 429/5xx response or NWPath unsatisfied | Close admission; start the retry schedule. |
| `Backoff` | `Running` | Retry-After elapsed, network path satisfied, one probe succeeded | Reopen admission after a lease check. |
| `Running` | `HandingOff` | handoff decision while foreground | Close admission, close the epoch, freeze `wal_seq`, start handoff.md §2. |
| `Draining` | `HandingOff` | handoff decision while draining | Finish the epoch close, then start handoff.md §2. |
| `HandingOff` | `Remote` | fence, snapshot and segments accepted; remote admission open | The remote holds authority; the phone keeps its WAL read-only. |
| `HandingOff` | `Reclaiming` | handoff failed after a successful fence | Reclaim with the token before any local work reopens. |
| `Remote` | `Reclaiming` | reclaim requested (user or foreground return) | POST the reclaim token (handoff.md §5). |
| `Reclaiming` | `Recovering` | response applied, new fence persisted, epoch closed | Verify the lease; admission stays closed until `Recovering → Running`. |
| any state | `Failed` | `WAL_CORRUPT`, unrepaired base mismatch at an epoch close, materialization I/O failure, quota still exceeded after compaction, or an unrecoverable host defect | Close admission, record the condition, keep every durable WAL and journal byte. |
| `Failed` | `Recovering` | explicit user reset only | Re-run recovery; the WAL may still fail the same condition. |

No other edge exists. In particular, `Parked` never opens admission directly, `Remote` is never left
without `Reclaiming`, and a drain deadline never reopens admission.

## 3. Driving signals

| Signal | Source | Effect |
|---|---|---|
| scenePhase | App lifecycle | `background` → `Draining`; `active` → `Parked`/`Recovering` and lease verification. |
| background task expiry | iOS background task | Force the `Draining` deadline (20 s), abort in-flight requests, continue to the pending target. |
| WebContent termination | WKWebView delegate | Count it; in the foreground `Running`/`Draining` → `Recovering`. |
| planned restart timer | controller | Every 2 h of foreground work, restart at the next tool-call boundary (§4). |
| thermalState | ProcessInfo | `fair` → sub-agent cap 1; `serious`/`critical` → LIFECYCLE `pause` at the next boundary, no new sub-agents, no new parallel accelerators. |
| battery / low power mode | ProcessInfo | Below 20 % and not charging, or Low Power Mode on → sub-agent cap 1, no optional accelerators; budgets are never raised. |
| NWPathMonitor | Network framework | unsatisfied → `Running` → `Backoff`; satisfied → `Backoff` → `Running` after one successful probe. |
| memory proxy | VFS bytes by prefix, session bytes, sampled engine heap, WebContent termination count | Budget actions in §4 order; VFS or heap pressure shares the same order; a hard cap after the actions → `Failed` (fail loud). |
| lease verification | controller and remote authority record | Required for `Recovering` → `Running`; failure keeps admission closed. |

## 4. Budgets

Device tiers are selected once per boot from the physical memory ceiling. The 8 GB row is the
default; a lower row applies when the ceiling is below 8 GiB. `MB`/`MiB` are 1 048 576 bytes.

| Resource | 8 GiB (default) | 6 GiB | 4 GiB | ≤ 3 GiB |
|---|---|---|---|---|
| Engine heap | ≤ 320 MB | ≤ 256 MB | ≤ 192 MB | ≤ 144 MB |
| VFS logical bytes | ≤ 260 MB | ≤ 200 MB | ≤ 144 MB | ≤ 96 MB |
| VFS split: workspace / sessions / tmp | 160 / 50 / 50 MB | 120 / 40 / 40 MB | 80 / 32 / 32 MB | 48 / 24 / 24 MB |
| Single file | ≤ 64 MiB | ≤ 48 MiB | ≤ 32 MiB | ≤ 16 MiB |
| Single file, host maximum | 128 MiB | 128 MiB | 32 MiB | 16 MiB |
| WASI hot instance | ≤ 260 MB | ≤ 200 MB | ≤ 144 MB | ≤ 96 MB |
| App process | ≤ 150 MB | ≤ 140 MB | ≤ 120 MB | ≤ 100 MB |
| Peak | ≤ 50 % of the ceiling (4 GiB) | ≤ 50 % (3 GiB) | ≤ 50 % (2 GiB) | ≤ 50 % (1.5 GiB) |
| Sub-agents | ≤ 2; 1 when thermal fair | ≤ 2; 1 fair | ≤ 1 | ≤ 1 |
| Loopback round trip | p95 < 5 ms | p95 < 5 ms | p95 < 5 ms | p95 < 5 ms |
| Planned WebContent restart | every 2 h at a tool-call boundary | same | same | same |
| Recovery time target | `a + k·MB`, a ≤ 3 s, k ≤ 0.05 s/MB | same | same | same |

- The VFS caps are logical bytes and are enforced at write time; exceeding a prefix or the total is
  `ENOSPC` to the worker and is fail loud. `tmp` is cleared first under pressure because it is
  volatile (wal.md §6, §8); `home/` and `workspace/` are never evicted.
- The `tmp` bucket aggregates both volatile spellings, `/dsh/tmp/**` and `/tmp/**`; they resolve to
  one store, so a byte is counted once whichever name wrote it. They are the only writable non-sink
  roots. A `/dev/null` write is a device write and counts against no bucket.
- The single-file budget is the tier default above. The host may set `single_file_limit` in
  16 MiB ... 128 MiB: the 4 GiB and ≤ 3 GiB rows gate the value to their default, and the 8 / 6 GiB
  rows accept up to 128 MiB. A value outside the range is clamped, never a start failure.
- The workspace bucket is at least `2 × single_file_limit + headroom`, with 32 / 24 / 16 / 16 MiB of
  headroom for the four rows: 160 = 2 × 64 + 32, 120 = 2 × 48 + 24, 80 = 2 × 32 + 16, 48 =
  2 × 16 + 16. The VFS logical cap is at least `workspace + sessions + tmp`, and the engine heap is
  at least the VFS logical cap. Raising the file limit raises workspace, VFS and heap in step; a
  configuration never lowers a bucket.
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
  materialized tree in MiB rounded up. A full 64 MiB file costs 3 + 0.05 × 64 = 6.2 s; at the new
  260 MB VFS cap the bound is 3 + 13 = 16 s. The formula is unchanged; the values cover the larger
  workspace and the overlay repack.
- The loopback target is measured over at least 1000 sequential WebSocket echoes on the loopback
  origin and is informational for the controller; exceeding it never changes a state by itself.
- A planned restart or handoff starts only at a tool-call boundary: no frame is in flight, the epoch
  is closed (wal.md §5.2), and step records show no `exec_running` step. If a boundary does not arrive
  within 60 s, the controller drains and restarts anyway.

## 5. Disk quotas

| Store | Quota | Overflow rule |
|---|---|---|
| WAL segments | 256 MiB | Close the epoch, compact droppable segments and retry; still over after a second close → `Failed`. |
| Response log | 128 MiB | Drop complete, oldest replays first; a partial stream is never logged; still over → `Failed`. |
| Journal | 64 MiB | Prune entries whose step is `journaled` and durable; still over → `Failed`. |

Quotas are absolute for every tier: a handoff or a restore does not raise them. None of the three
stores ever evicts `home/`, `workspace/` or an un-journaled step; data is never silently dropped.
`Cache-Control: no-store` responses and lazy image shards are not persisted and do not count against
these quotas.

Repeated rewrites of one large file are reconciled by compaction, not by raising the quota. When an
append would cross the WAL quota the host closes the epoch in the D18 order, compacts every droppable
segment and retries; a second failure closes and compacts once more. After a close at most the newest
epoch-close segment and the open segment survive, so a 64 MiB rewrite cycle cannot accumulate five
whole-file records; if the quota is still exceeded after the second close the state becomes `Failed`.

## 6. Revision note (large-file budget)

The W12-BIGFILE revision replaced the former row (engine heap 200 MB, VFS logical bytes 150 MB, VFS
split 50 / 50 / 50 MB, single file 15 MiB): that workspace bucket could not hold one 64 MiB file,
let alone two. The old row is superseded and not normative; 15 MiB survives only as the per-mutation
frame bound of channel.md. The recovery formula and the absolute WAL / journal quotas are unchanged.
