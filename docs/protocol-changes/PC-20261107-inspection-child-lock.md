# Freeze child lock visibility in legacy inspection

```yaml
change: PC-20261107-inspection-child-lock
contracts: [P07, P09, P18]
status: frozen
breaking: false
version_decision: No persisted or wire format change; the existing result kind unexamined is reused.
base: d0ee25de674187d656094535d3fff02231faa650
contract_revision: spec/device/v1/legacy-task-inspection.md@child-lock-v1
```

Protocol impact: P07; P09; P18. The previously frozen observation contract
requires unknown entries to be listed but forbids opening `.lock`. The scanner
currently omits that name at both directory levels. Consequently an unknown
`ble-ops/.lock` is silently lost from the observation. The amended owning
contract makes the two requirements explicit: skip only the expected root
`.lock`; report a child `.lock` as `unexamined`, without opening, reading,
rewriting or classifying it. It may be a hard link, symlink, directory or
regular file. Report no claims and infer no identity, task or outcome.

The root and child names are subject to existing count, cancellation and
incomplete-observation rules; they do not add an enumeration or consistency
guarantee. No task operation, retry, replay, authorization or new error is
added. The existing process-wide journal/inspection admission and descriptor
rules remain mandatory. The schema change extends only the fixture scenario
vocabulary, not the result format or the acceptance rules for old data.
Shared cases in `golden/legacy-task-inspection.jsonl` include an ordinary child
lock and a child hard-linked to the real root lock; retain the existing symlink,
FIFO, busy, cancellation, budget and replacement negative cases.

Compatibility: new inspector reading old data reports an extra `unexamined`
entry and changes no bytes. Old inspector reading the same data may omit this
entry, so its result cannot be treated as a complete inventory. New and old
UI consumers already know the `unexamined` kind; neither version may infer
recovery. There is no on-disk migration and rollback leaves all records and
locks in place. The new result does not make concurrent external writers or
POSIX locks outside the existing process-wide gate safe.

The coordinator owns `spec/**` and this record. The Swift implementer owns
`Sources/PhoneDSHDeviceTasks/DeviceTaskLegacyInspector.swift` and
`Tests/PhoneDSHDeviceTasksTests/DeviceTaskLegacyInspectorTests.swift`. Test both
new shared cases against the real scanner and temporary files: root lock is
not listed, child is listed once without claims or any candidate file open,
and both original bytes remain unchanged. Include the hard-link case after
the journal owner has fully closed; retain the active-owner busy fixture. Also
exercise a child symlink or FIFO as unexamined without opening it. Run
`swift test --filter DeviceTaskLegacyInspectorTests`,
`PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_spec_golden.LegacyTaskInspectionFixtureTests`,
and `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Report iPhone, power-loss, cross-process and device evidence separately; this
fix does not authenticate or recover old records and does not enable tasks.
