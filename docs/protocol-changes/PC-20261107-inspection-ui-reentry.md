# Freeze reentrant legacy inspection presentation

```yaml
change: PC-20261107-inspection-ui-reentry
contracts: [P07, P09]
status: frozen
breaking: true
version_decision: Keep existing local read-only properties and methods; change observable transition ordering, with no wire or on-disk format change.
base: 3f522d9d42be865733092647d08a26fc6be997e2
contract_revision: spec/device/v1/legacy-task-inspection.md@inspection-ui-v1
```

Protocol impact: P07; P09; P18: none — this changes only transient
presentation state, not persisted records or preferences. The current model
publishes observed fields before installing its task and publishes completion
using ordinary setters. Synchronous Observation callbacks can reenter it:
a macOS Swift 6.4 harness compiling the actual model and using a controlled
stub inspector observed two concurrent inspector calls, a clear before
startup that failed to cancel the call, and a result revived after clear.
This is model-level runtime evidence, not a real filesystem, iOS or device
test. The owning document freezes the operation ordering and the shared
success, cancellation and reentry vectors before implementation.

No record, task, preference, key, wire field, error code or remote call is
changed. Old callers keep the same methods and read-only values. A new model
may deliver fewer or differently ordered notifications and does not preserve
the erroneous old duplicate or stale-result behavior; old binaries after
rollback still have that bug. The pre-existing scanner gate remains the owner
of filesystem admission. This change does not authenticate or execute old
records and does not permit BLE task grants. There is no persisted-data
migration or cross-process guarantee.

The coordinator owns `spec/**` and this record. The Swift implementer owns
`examples/probe-app/PhoneDSHProbe/LegacyTaskInspectionModel.swift`,
`examples/probe-app/PhoneDSHSimTests/LegacyTaskInspectionModelTests.swift`,
and focused test harness files under `examples/probe-app/scripts/` for this
model only. The host-side harness is justified by the current simulator
runtime failing to launch the real test bundle: it must compile the real
model source, not a copied state machine; a test-only result/inspector stub is
allowed and its limitations must be reported. The same real model's existing
simulator tests must receive matching reentry regressions, without assuming
the simulator is available. The shared fixture cases must drive the real
model and `withObservationTracking`, check inspector call counts, paused
operation state, cancellation, old-result discard and new-start preservation.
Test no-op reentry and finite event sequences, including an old publication
resuming after its inspector has returned, its slot retired and a new start
has been accepted. Valid scanner results, including busy and cancelled results,
must be passed through without fabrication unless cleared.

Acceptance: the shared-fixture model harness on macOS; the affected simulator
tests when the runtime can launch them; `swift test --filter
DeviceTaskLegacyInspectorTests`; `PYTHONPATH=spec/v1/tools
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest
test_spec_golden.LegacyTaskInspectionFixtureTests`; and `bash
scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Report exact commands and any simulator/device NOT_RUN. The model harness does
not demonstrate hardware, durable recovery, production session security, or
Android parity.
