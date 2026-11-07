# Global legacy BLE task intent inventory

```yaml
change: PC-20261107-ble-intent-inventory
contracts: [P07, P18]
status: frozen
breaking: false
version_decision: Existing v1 task and BLE intent formats unchanged; detect pre-existing corrupt or unprovable history globally and fail closed.
base: 5e85bc444a6ad2a1c9f15b861efc09f0f2d1973a
contract_revision: spec/device/v1/task-delegation.md@sha256:38a462693ecf7af919fa7755fcd0fd8529e40ce3f115d8df27d7c69821f0a3f9
```

## Trigger and scope

`DeviceTaskJournal.records()` validated task files but inspected a BLE operation
intent only when a particular task/action was looked up. A renamed device label
or orphan/corrupt file could therefore evade the documented fail-closed journal
rule. The owner freezes the inventory clause and valid/invalid shared scenarios
before implementation. Protocol impact: P07, P18. This is an integrity check for
existing data, not identity authentication, task authorization, automatic
migration, receipt verification or an implementation of the target task
profile. BLE task grants remain closed.

No field, encoding, persisted byte format, wire message or endpoint changes.
While holding the existing journal ownership lock, validate every task record as
before and then inventory every entry of `ble-ops` as specified. Reconstruct
accept arguments from the parent task and complete/fail arguments from the
persisted terminal outcome; recompute and compare the complete intent using the
existing real derivation. Fail the whole inventory for unreadable, corrupt,
orphan, extra or inconsistent data regardless of the device currently being
processed. Never delete or rewrite an entry, acknowledge a task, query an old
plaintext receipt or rerun an operation merely because inventory passed.

## Compatibility, roles and evidence

Valid old v1 records → new reader: accepted unchanged and remain query-only;
invalid or orphan records → new reader: rejected without modifications, as
required by the existing fail-closed rule. New writer → old reader: same v1
format, but an old reader lacks this global safety check; rollback therefore
must keep BLE task grants disabled and preserve all data. New → new uses the
same intent derivation. No wire or firmware producer is modified; new secure
receipt recovery and trusted UUID/key binding require a separate frozen
contract and cannot be inferred from these checks.

Owning authority `spec/device/v1/task-delegation.md`; code contract
`DeviceTaskJournal.swift` implements the existing v1 files. The shared intent
schema and `golden/ble-task-link-ops.jsonl` are unchanged; the shared positive
and negative inventory scenarios are `golden/ble-task-inventory.jsonl` with
`schema/ble-task-inventory-vector.schema.json`. Tests must construct real parent
and intent files with the actual journal and real intent derivation, then apply
the fixture mutation and call the actual inventory; no duplicate decoder.
Cover missing directory, three valid actions, orphan and changed identity,
derived value and terminal mismatch, corruption, duplicate keys, symlinks,
extra file and bounds; check that failing scans do not modify the evidence.

Coordinator owns `spec/**` and this record. Swift implementer exclusively owns
`Sources/PhoneDSHDeviceTasks/DeviceTaskJournal.swift` and
`Tests/PhoneDSHDeviceTasksTests/BLETaskIntentTests.swift` or a new test in that
test directory. Do not modify other implementations or specs. Acceptance:
`swift test --filter BLETaskIntentTests`; `swift test --filter
PhoneDSHDeviceTasksTests`; `bash firmware/tests/run.sh`; and `bash
scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Real power loss, device, key binding and task E2E remain NOT_RUN without their
separate runtime evidence.

## Revision 2 — validate before first write

Implementer observed that validating only the subsequent inventory leaves a
window in which caller-supplied arguments can disagree with the parent and be
written/uploaded first. The existing terminal-outcome rule also applies before
writing any new intent: reconstruct the canonical arguments from the parent and
reject mismatches before writing or invoking the Link. The shared scenarios now
include wrong arguments for accept, complete and fail. Old valid records and
wire formats remain unchanged. Swift implementer notified of revision 2.
