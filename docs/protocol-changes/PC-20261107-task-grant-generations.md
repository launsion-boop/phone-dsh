# Freeze task intake revocation across asynchronous starts

```yaml
change: PC-20261107-task-grant-generations
contracts: [P07, P09]
status: frozen
breaking: true
version_decision: Change the unmerged target Swift API behavior in PR 59; no wire, storage, or capability version change. Callers requiring notification completion must await their own notification signal.
base: 1e488f83633230cbdfe3562e0eb7e20b483899de
contract_revision: spec/device/v1/task-delegation.md@grant-generations-v5
```

## Trigger, contract, and roles

Protocol impact: P07; P09: none — the UI control and presentation do not
change; its asynchronous authorization lifetime is made consistent with P07.
The iOS manager marks a device active, then awaits an actor start. A stop
may invalidate its UI generation before that start is delivered. A controlled
experiment with an inserted delivery gate demonstrates an orphaned job under
that ordering; it does not establish that an unmodified production runtime
has exhibited the ordering. Cleaning by device ID alone can instead cancel a
newer generation. The owning trust and routing clause and the shared scenario
fixture freeze the cancellation, busy, stale callback and identity rules.

The coordinator owns `spec/**` and this record. The iOS implementer owns
`Sources/PhoneDSHDeviceTasks/DeviceTaskIntake.swift`, the probe's
`DeviceTaskManager.swift`, a small shared lifecycle coordinator in
`Sources/PhoneDSHDeviceTasks/` if needed for testing, and affected Swift tests. The integrator reviews
the combined head. Tests must use real intake and manager lifecycle code with
controlled actor delivery, not a duplicate implementation. The old start's
cancelled handle must be installed before the manager can suspend; revocation
invalidates it synchronously, cancels and awaits it, then stops only a matching
intake token. The intake checks cancellation before installing a job. A
completed start racing cancellation is still joined and its exact token
stopped. A busy attempt never owns the incumbent and its cleanup cannot touch
it; the incumbent remains reserved until its worker finishes.
Same-device starts cannot overlap and a busy result is not retried without a
new grant. App suspension invalidates all generations before awaiting any
stop. A job which ignores cancellation remains stopping and busy, without a
timeout that pretends it is finished. Real code must consume every shared scenario, including
negative cases and stale callbacks. BLE grants remain refused.

No producer or consumer wire representation changes. Firmware, LAN device,
Android and other consumers retain the existing task semantics; there is no
new task data for them to parse. This fixes the phone-side grant lifetime only.
No journal is renamed, rewritten, recovered, or replayed by this change.

## Compatibility and verification

Old phone to new device and new phone to old device preserve their current
wire behavior; the latter gains the stricter local revocation guarantee. New/new has
the same encoding and task protocol. Existing persisted data and rollback stay
unchanged; rolling back also restores the old scheduling risk. Cancellation
cannot prove that an earlier DSH submission did not execute. No target feature
becomes implemented, and no physical-device or cryptographic session claim is
made.

Shared `spec/device/v1/golden/task-grant-generations.jsonl` and its schema
enumerate start cancellation, stop after start, stale stop, different UI key
with the same device, stale callback, and busy behavior. Observe the incumbent
alive during busy and count live jobs, starts, and automatic retries. Verify
that an attempt after busy needs a fresh user action. Test suspension with two
devices and one blocked stop. The previous public Swift intake entry points
must remain source-compatible for their old callers; the app's coordinator
must not use an unscoped stop to cancel a new generation. Already in-flight
network or DSH operations can have unknown outcomes. After a stop returns the
revoked job cannot initiate any further accept, prompt, report, or retry.
Old public Swift calls retain their signatures but stops no longer wait for
the separate notification callback. An arbitrary old callback calling a legacy
unscoped stop intentionally targets the current worker; it cannot be advertised
as generation-safe. App callbacks capture and compare their generation and
must not perform unscoped cleanup. Tests must exercise same-job, cross-job,
and stop-all callback reentrancy, held notifications after worker completion,
and verify that live workers do not release device reservations early.
Acceptance commands:
`swift test --filter PhoneDSHDeviceTasksTests`; the probe manager's actual
Xcode tests for generation ordering; and `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree`. Report each result exactly;
existing P0 failures and device tests are not converted to passes. Remaining
GAP-16 and journal recovery risks are unaffected.

## Revision history

`grant-generations-v2`: independent review found that final booleans alone did
not constrain busy cleanup, overlapping work or multi-device suspension. Added
ordered steps, intermediate observations and explicit API compatibility;
implementers were paused before implementation and notified of this revision.

`grant-generations-v3`: the stale-event case now delays an old LAN monitor
result, not the intake's own unfinished stop callback. The latter retains the
device reservation and has a separate busy case. Monitor completion rechecks
the generation after every suspension before it can stop. The step `stop_old`
initiates stop asynchronously; only `await_old_stop` waits for it. A held stop
return is held after the job and its callback have both completed. Start counts
are the number of new user start actions, not actor deliveries or automatic
retries. Observations precede test cleanup. Busy recovery requires a second,
fresh user start after old stop completes. Implementers were paused pending
this revision.

`grant-generations-v4`: implementer CCR found that retaining a worker through
`onStopped` and awaiting that worker from the callback deadlocks. Independent
review chose to separate worker completion and token-scoped notification:
stops join the worker, not the notification, and late callbacks cannot affect
new generations. This revises v2/v3's callback reservation rule and changes
public Swift stop waiting behavior. A worker cannot await its own join. Shared
scenarios cover held notifications, self-stop and cross-device stop callbacks.

`grant-generations-v5`: independent review noted the old public callback has
no generation argument and its unscoped stop methods address current workers.
The guarantee is for app-owned token-scoped cleanup, not arbitrary public
callbacks. A negative scenario retains and proves the legacy unscoped risk;
the app's old token-scoped notification must leave the new worker running.

The public intake source is absent from the task's main baseline
`9b3b31e7291695530765c7d61a32753d902748f9`; it was introduced on this unmerged
draft branch. Repository call-site audit found only the probe manager using
`onStopped`; other existing tests stop without a callback. This does not prove
there are no external draft consumers. Existing source still compiles, but a
caller that depended on stop joining the notification must migrate to its own
explicit completion signal; rollback restores the prior waiting behavior and
its callback deadlock risk. The old/new device matrix above describes wire
compatibility, not this Swift behavioral change.

In fixtures, `stop_old_hold_return_after_job_and_callback_finish` deliberately
waits for the notification in the test; it is not a promise that stop waits.
The held-notification case must observe that stop has returned while the
notification remains blocked. The stop-all callback case explicitly starts a
separate external stop-all before awaiting it.
