# Perturbation fixtures — kill-replay matrix

Status: normative fixtures. Each file is one perturbation applied to a running host, the logical
timeline of what happens and the state the host must be observed in afterwards. The fixtures are the
oracle: the Swift suite, a Kotlin Android runner and any future runner are judged by the same files,
not by each other.

The host states and the legal edges are those of [budgets.md](../../budgets.md) §1–§2 (D14). The
durability, tail and recovery rules are those of [wal.md](../../wal.md) §5 and §10. This directory
never restates those documents as prose; it encodes one point of the matrix per file.

The fixtures were lifted from the Swift tests that used to be the only place these semantics lived
(`Tests/PhoneDSHKillTests/`, `Tests/PhoneDSHControllerTests/`, `Tests/PhoneDSHLogTests/`,
`Tests/PhoneDSHScenarioTests/`). Every assertion member carries the evidence class it was lifted
from; nothing here claims a measurement.

## 1. File shape

Every `*.json` in this directory validates against
[schema/perturbation.schema.json](../../schema/perturbation.schema.json):

```json
{
  "id": "kill-9-after-write",
  "verb": "kill_9",
  "title": "SIGKILL after two level-1 acked writes, with one tool step still open",
  "preconditions": {
    "host_state": "Running",
    "admission": "open",
    "epoch_open": true,
    "acked_mseq": 2,
    "open_steps": 1,
    "journaled_steps": 0,
    "exec_in_flight": false,
    "persisted_state": "Running",
    "worker_channel": "open",
    "notes": "A dispatched journal record is acked, then two writes are acked."
  },
  "timeline": [
    {"at": 0, "event": "journal dispatched acked; two writes acked", "expect_state": "Running"},
    {"at": 10, "event": "SIGKILL", "source": "Tests/PhoneDSHKillTests/Phase0KillMatrixTests.swift:456-460"},
    {"at": 20, "event": "process start", "expect_state": "Recovering"},
    {"at": 40, "event": "lease verified", "expect_state": "Running"}
  ],
  "expected": {
    "state": "Running",
    "state_path": ["Running", "Recovering", "Running"],
    "durability_level": "level_1",
    "wal_tail": "intact_open_epoch",
    "journal_gap": "step_open",
    "surfaced_to_user": "unmeasured",
    "acked_prefix_preserved": true,
    "materialized_equals_replay": true,
    "steps_open": 1,
    "steps_abandoned": 0,
    "settlement_reason": "absent",
    "field_evidence": {"state": "swift-test", "wal_tail": "swift-test"}
  },
  "evidence_level": "swift-test",
  "source": "Tests/PhoneDSHKillTests/Phase0KillMatrixTests.swift:456-487"
}
```

The example is abridged: every asserted member of `expected` needs its own `field_evidence` entry,
and the checker rejects a fixture that omits one.

* `id` — unique across both fixture families and equal to the file name.
* `at` — a **logical clock**: milliseconds since the fixture started, integer, non-decreasing, first
  value 0, never above 3 600 000. A wall-clock timestamp is a validation error.
* `source` — `path:line` or `path:line-line` of the Swift test or source that fixes the assertion, or
  `NEW` when no Swift anchor exists. The path may be under `Tests/`, `Sources/`, `scripts/` or
  `spec/`.

## 2. Verbs

| `verb` | What is perturbed | iOS mechanism | Android mechanism |
|---|---|---|---|
| `kill_9` | the host process, uncatchable | `SIGKILL` from the test (`kill(2)`) | kernel `SIGKILL` (LMK, force-stop, task-manager stop) |
| `sigterm` | the runner process | catchable stop request recorded by the signal guard | `SIGTERM`; no handler is guaranteed before a `SIGKILL` |
| `drain_timeout` | the drain window | 20 s background-task deadline, or the OS expiring the task | `onTimeout` (seconds) or no window at all |
| `system_reclaim` | the host process, zero callbacks | jetsam / memory-pressure reclaim | LMK, cached-app freezer |
| `power_loss_torn_tail` | the storage device | simulated by a short epoch-close record | real power loss; `fdatasync`/`fsync` on f2fs/ext4 |
| `renderer_terminate` | the page's execution context | `webViewWebContentProcessDidTerminate` | `onRenderProcessGone` (the instance must be destroyed and rebuilt) |
| `force_stop_zero_callback` | the whole app, with no callback and no reschedule | force quit (no callback either) | task-manager stop |
| `planned_restart` | the host's own restart | `plannedRestart` (D24) | the same facade call |
| `cold_start_after_reboot` | the process after a device reboot | app launched after reboot | user launches the app; `BOOT_COMPLETED` may not start a dataSync FGS |
| `write_without_ack` | the ack path only | append without `VFS_ACK` | the same wire path |
| `stop_seal_failure` | the teardown seal | a failing teardown still runs the terminal seal | the same host code, a different lifecycle source |

`stop_seal_failure` is not a kill: it exists because the terminal stop seal is the last line of
defence against an open epoch behind an inverted manifest, and that behaviour has a Swift regression
test worth lifting.

## 3. Expected members

`expected.state` is the **terminal** D14 state: the one the runner must observe when the timeline has
been replayed. `expected.state_path` lists every state that must be observed on the way, in order,
and its last element must equal `state`. A fixture with `state_path: ["Running","Recovering","Running"]`
is asserting two edges, not one.

| Member | Values | Meaning |
|---|---|---|
| `state` | the nine D14 states | terminal state |
| `state_path` | list of the nine D14 states | ordered observation path |
| `durability_level` | `level_1`, `level_2`, `none`, `unmeasured` | strongest durability promise asserted: level 1 survives process death (wal.md §5 step 3), level 2 survives power loss (wal.md §5.2 step 5) |
| `wal_tail` | `intact_open_epoch`, `truncated_to_last_complete`, `closed_epoch`, `unchanged`, `unmeasured` | shape of the newest retained segment after recovery |
| `journal_gap` | `none`, `step_open`, `step_abandoned`, `step_reconciled`, `unmeasured` | what the affected session's tool journal must show |
| `surfaced_to_user` | `none`, `orphan_step_settlement`, `boot_recovery_report`, `stop_error_to_caller`, `scenario_run_failure`, `unmeasured` | the user-visible channel, if any |
| `admission` | `open`, `closed`, `unmeasured` | admission after the timeline; open only in `Running` |
| `acked_prefix_preserved` | bool | every level-1 acked mseq present with the identical mutation |
| `unacked_records_retained` | bool | a record appended without an ack still survives and replays |
| `truncated_torn_tail` | bool | recovery truncated a torn tail |
| `materialized_equals_replay` | bool | the materialized copy equals the replay of the retained WAL |
| `steps_open`, `steps_abandoned` | integer | counts over the affected session's step records |
| `settlement_reason` | `worker-terminated`, `planned-restart`, `absent`, `unmeasured` | the terminal reason recorded on the affected step |
| `late_completion_does_not_advance` | bool | a late `completed` journal record does not revive or journalize the step |
| `no_drain_before_kill` | bool | the perturbation reached the host with no `Draining` edge and no close record |
| `worker_rehello` | bool | the replacement Worker sent a `HELLO` with a new boot id |
| `boot_disposition` | `cold_start`, `crash_recovery`, `parked_resume`, `user_reset`, `unmeasured` | the disposition the next process start reports |
| `fence_and_lifecycle_resent` | bool | the post-recovery `FENCE`/`LIFECYCLE open` pair was sent (`false`: admission stayed closed) |

`unmeasured` is an **absence of evidence**, never a value to assert. A member set to `unmeasured`
must have no `field_evidence` entry, and the runner must not test it.

## 4. What a runner must do

1. Build the preconditions: start the host, reach `preconditions.host_state`, apply the WAL and
   journal state named by `acked_mseq`, `open_steps` and `journaled_steps`, and persist
   `persisted_state` when it is not `absent`.
2. Apply the perturbation of `verb` at the time the timeline names it.
3. Record every host-state transition; assert that `state_path` is a subsequence of what was observed
   (order preserved, no extra requirement on states in between that are already in the path) and that
   the terminal state equals `state`.
4. Assert each remaining `expected` member that is not `unmeasured`:
   * `durability_level: level_1` — every mutation acknowledged at level 1 before the perturbation is
     present in the WAL with the identical bytes (compare the encoded record, not just the path).
   * `durability_level: level_2` — the epoch-close record is present and the manifest names the
     retained segments; the level-2 prefix survives a power-cut simulation.
   * `wal_tail` — `intact_open_epoch`: no close record and no gap; `closed_epoch`: the newest segment
     ends with an epoch-close record; `truncated_to_last_complete`: the last record is complete and
     the bytes after it are gone; `unchanged`: no byte was written by the perturbation.
   * `journal_gap` — `step_open`: the reconcile set is exactly the interrupted steps and none is
     terminal; `step_abandoned`: a terminal `abandoned` record owns the step, with
     `settlement_reason` as the recorded reason; `step_reconciled`: the step is `journaled` through
     the write-open route with no settlement reason; `none`: the journal is exactly as the
     preconditions left it.
   * `materialized_equals_replay` — replay the retained WAL onto an empty tree with the D9 rules and
     compare the result byte for byte with the materialized copy (files, directories and modes).
   * `boot_disposition` — read the next process start's disposition, not the state file alone.
5. Record the evidence for anything the fixture requires and the runner cannot observe as a runner
   failure, never as a pass.

`preconditions.admission` and `expected.admission` are constrained by D14: admission is `open` only
in `Running`, so a fixture that pairs them otherwise is invalid and the checker rejects it.

## 5. Evidence

`expected.field_evidence` maps each asserted member to where the assertion comes from:

| Value | Meaning |
|---|---|
| `swift-test` | a Swift test asserts it (or a catalog scenario assertion the Swift runner executes) |
| `swift-source` | the production Swift code fixes it; no test asserts it |
| `spec-only` | only the normative spec fixes it; no Swift code path or test exercises it |
| `NEW` | no Swift anchor; the assertion exists for the Android runner |

`evidence_level` MUST equal the **weakest** value in `field_evidence`, and the checker enforces it.
A fixture therefore cannot claim `swift-test` while one of its assertions is only `swift-source`.
`evidence_level: NEW` requires a `new_reason` explaining why the Android equivalent has no Swift
anchor, and `source: NEW` is only legal with `evidence_level: NEW`.

Only one fixture is `NEW` today: `force-stop-zero-callback`, and only its user-visible report is
new. Every `unmeasured` member is listed in §7.

## 6. Validation

```sh
python3 spec/v1/tools/fixture_check.py --root .
python3 -m unittest discover -s spec/v1/tools -p 'test_fixture_check.py' -v
```

The checker validates both fixture families against their schemas, enforces the cross-field laws of
§3 and prints the verb coverage matrix. It is the only consumer of these files inside this
repository; the Kotlin runner is the second consumer.

## 7. Known gaps

The following members are `unmeasured` somewhere in this directory, and no fixture asserts them:

* `surfaced_to_user` for `kill-9-after-write`, `kill-9-during-checkpoint`, `drain-deadline-20s`,
  `drain-background-task-expiry`, `power-loss-torn-tail`, `system-reclaim-host-killed`,
  `cold-start-after-reboot` and `write-without-ack`. The iOS baseline has no user-visible report for
  those paths; the Android tombstone notification and next-launch banner are plan items, not Swift
  behaviour. The one fixture that does assert a report is `force-stop-zero-callback`, where the
  member is `NEW`.
* `journal_gap` for `planned-restart-helper-failure`: the test asserts the failure and the closed
  admission, not the surviving step record.
* `client_outcome` in the upstream family for a malformed body (see the upstream README).

A `WAL_CORRUPT` (a CRC failure that is not at the tail, or an invalid record followed by a valid one)
has no fixture: the Swift suite has no test that produces it end to end, so lifting it would invent
an assertion. It belongs to a future fixture backed by a new Swift regression test.
