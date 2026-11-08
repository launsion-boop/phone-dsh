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

## Implementation evidence

The model uses an internally owned operation and a single observable
presentation snapshot; it rechecks the publication revision after synchronous
Observation notifications. Existing method and getter names remain. The
following were run on the implementation tree based on frozen revision
`602e8000`:

- `bash examples/probe-app/scripts/legacy-inspection-ui-test.sh`: PASS, all
  18 shared scenarios, repeated-clear and advisory-cancellation checks on macOS, using
  the real model and a test-only inspector/result stub. Compiling the same
  harness with the pre-fix model made `start_reentered` FAIL: two inspector
  calls instead of one.
- `swiftc -typecheck -I .build/out/Products/Debug examples/probe-app/PhoneDSHProbe/LegacyTaskInspectionModel.swift`:
  PASS against the locally built macOS `PhoneDSHDeviceTasks` module.
- The iOS simulator test target built successfully with `xcodebuild -project
  PhoneDSHProbe.xcodeproj -scheme PhoneDSHSim -configuration Debug
  -destination 'platform=iOS Simulator,id=4166F406-E0EB-4A13-97A9-059E12B81E2C'
  -derivedDataPath /private/tmp/pdsh59-legacy-ui-derived
  -clonedSourcePackagesDirPath /private/tmp/pdsh59-legacy-ui-packages
  -only-testing:PhoneDSHSimTests/LegacyTaskInspectionModelTests
  CODE_SIGNING_ALLOWED=NO build-for-testing`. This compiles the added iOS
  tests but does not run them. The build changed the root `Package.resolved`;
  its pre-build contents were restored after inspection.
- `bash examples/probe-app/scripts/legacy-inspection-ui-test.sh --ios-simulator`:
  PASS, the 18 shared scenarios and both additional checks in a temporary iOS
  18.4 simulator, using the real model and the stub inspector/result. A linker
  warning reported a macOS sysroot while targeting the simulator; a separate
  `xcrun vtool -show-build` inspection of the identically built executable
  reported platform `IOSSIMULATOR`, minimum iOS 18.4, SDK 27.0. The test
  simulator was shut down and deleted. This is model runtime evidence, not
  evidence for the real inspector or SwiftUI presentation.
- `swift test --filter DeviceTaskLegacyInspectorTests`: PASS, 20 tests on
  macOS. The fixture schema command above: PASS, 6 tests. The three-gate
  command above: phone-spec PASS, phone-p0-conformance FAIL (stale page
  contracts and page checker test), phone-cross-tree PASS.

The actual iOS test bundle was NOT_RUN on this tree; an earlier attempt with
the available 18.4 runtime failed to load `libswiftWebKit.dylib`. iPhone,
ESP32, Android, physical power loss and authenticated task-session acceptance
are NOT_RUN. This implementation does not close GAP-16 or the unrelated
identity-confirmation Observation gap.
