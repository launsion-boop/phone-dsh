# CCR: queue action acknowledgements and session isolation

```yaml
change: PC-20261107-queue-action-ccr
status: draft
contracts: [P09]
base: f938f692
```

This is an audit and change request, not a frozen contract or implementation
authorization. The affected queue code predates PR 59, but its stale P09 page
contract prevents P0 conformance. The fixed DSH checkout's
`packages/api/session-controller/src/commands.ts:413-489` changes the inbox
and returns a value containing `accepted: true`; that acknowledgement does not
establish persistence or execution. The existing Swift test transport returns
`{ok:true}`, while the two clients do not validate that value.

`examples/probe-app/ProbeKit/ComposerQueue.swift` applies an acknowledged
mutation and treats subsequent refresh as best effort. Android
`android/app/src/main/kotlin/com/phonedsh/probe/ProbeEngineViewModel.kt`
currently requires a matching readback before reporting success; failure to
read or a later inbox change can be reported as if the mutation itself failed.
For a missing item, iOS removes the row and shows edit/remove failure; Android
removes the row without that notice. Both silently converge selected steer
errors. Static inspection also shows that each end compares session identifiers
but not a session generation; a late result after A→B→A can affect the new A.
The iOS failure path additionally writes `lastError` after awaiting refresh
without another session check. These are findings, not runtime conformance
results; no behavior has been changed by this record.

Before implementation the owners must agree on acceptance versus unknown
outcome, allowed extra acknowledgement fields under the actual DSH Remote
policy, reconciliation of changed readbacks, precise visible error behavior,
and a generation that rejects stale results without claiming cancellation.
Freeze the applicable P09 and any triggered transport contracts, compatibility
and rollback, and shared positive and negative fixtures first. At minimum cover
valid and malformed acknowledgement values, explicit errors, readback failure
and later changes, edit/remove/steer, and A→B→A. Drive those fixtures through
both real queue state machines and their visible notices, including failure and
reconnect paths. Never infer an automatic retry, persistence or exactly-once
execution from an acknowledgement. The current draft does not close GAP-22.
