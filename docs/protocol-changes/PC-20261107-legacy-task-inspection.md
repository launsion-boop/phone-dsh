# Freeze read-only legacy task inspection

```yaml
change: PC-20261107-legacy-task-inspection
contracts: [P07, P09, P18]
status: frozen
breaking: false
version_decision: No persisted or wire format change; concurrent journal initialization fails busy while a local inspection is active.
base: 1747309343746a5c4a571c1f743e2b45514e4cd0
contract_revision: spec/device/v1/legacy-task-inspection.md@sha256:5fe8797305fab7b6ea29fbc274e4179007a3d7a7a89e1cf92436e132ec629296
```

## Trigger and delta

Protocol impact: P07; P09; P18. Legacy task files can remain after BLE task
grants are refused; the current fail-fast journal reader creates storage and
acquires a process record lock, so it cannot provide a non-mutating evidence
view. A historical UUID, key fingerprint or plaintext result cannot prove a
past identity or remote outcome. Freeze the limited local inspection described
in the owning document, not automatic recovery or a new task capability.

An inspector reserves process-wide exclusion against **all** task-journal
initializers and owners before opening candidates; journal initialization
fails busy rather than waiting while an inspection is active. Ownership
registration must cover initialization and lock release, including error and
cancellation paths. The short bookkeeping mutex must never span I/O. Files are
observed via anchored no-follow descriptors, bounded preview/enumeration and
explicit incomplete status; the budgets do not change stored-data validity.
The UI begins only on user action, exposes no task or outcome contents or raw paths,
and never starts an engine or task. Existing journal files, unknown members,
locks, identity preferences and old receipts are not changed or authenticated.

Shared fixture `spec/device/v1/golden/legacy-task-inspection.jsonl` is SHA-256
`fd66070537571fa8bc6c43855106676e048fa1aaf6c4fae633f78e9a44feaf42`;
its schema SHA-256 is
`07608610da2ad4c13dabc2dbefb5cf091fe09ed9eff309fab6dc956a7949b8b6`.
The shared escaped-path vectors and schema have SHA-256
`a8912a2d9a4aea417f5b75f59e4966dae2bdda3bbfdd839c5f9fbd5150c8f988` and
`d5cee16d4c636bcf41f5bf79440772167b6ee1c47ea65ab74b9bdcd6608cacf7`.
The claim vectors and schema have SHA-256
`c2b2bbd27628e3924766e726e62064b17d1f4ca81ce81bbf2378f1380483d57f` and
`f64452bf415b16054d2f7210b0dde1b2a1dcd05b756bbf32dab09373391d35be`.
The linked owner clauses `task-delegation.md` and UI `page-completeness.md`
are SHA-256 `84d30b93f6b20a5c8cc38c060bbedb8e19d0ed16b2ed5207d6e5dd3e5ee65822`
and `5814478abbf64f6e4d42d47d4ee606baed6bad31cfc6479e31af9c8c7af7819d`.

## Compatibility and roles

Old data → new inspector remains untouched, including malformed, oversized,
unknown and orphaned files; any unexamined data remains explicitly incomplete.
New app → old data does not migrate identity, grant tasks or claim delivery.
Old app/rollback ignores the in-memory inspector; concurrent old processes are
not coordinated and cannot yield a verified snapshot. No wire/version/record
field changes. An iOS app-container file is unavailable to Android; the new
local affordance is not evidence for Android feature parity or a reason to
relax P0. The broader cross-platform device capabilities remain unfinished.

The coordinator owns `spec/**` and this change record. The core implementer owns
`Sources/PhoneDSHDeviceTasks/DeviceTaskJournal.swift`, new inspection/gate
files in that module and `Tests/PhoneDSHDeviceTasksTests/**`. The UI implementer
owns `examples/probe-app/PhoneDSHProbe/BluetoothDevicesPage.swift`, any new
probe-only presentation files and their probe tests; it must use the frozen
core API and not start task management. No other agent edits these paths.
Review the combined head, including the cross-process/in-process limitations.

Acceptance: `swift test --filter PhoneDSHDeviceTasksTests`; the affected
probe/UI build and tests using an isolated simulator; and
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Use actual files and existing journal code rather than copied model-only
validators. Record all failures and skips. GAP-24, legacy identity recovery,
secure task-session implementation and physical-device acceptance remain open.
