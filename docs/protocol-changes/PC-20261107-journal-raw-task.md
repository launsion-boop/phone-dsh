# Validate raw embedded tasks during journal recovery

```yaml
change: PC-20261107-journal-raw-task
contracts: [P07, P18]
status: frozen
breaking: true
version_decision: Preserve journal v1 and task v1; refuse ambiguous/corrupt old records instead of interpreting or rewriting them.
base: f0d6c759724d5b889aad319ddbfecf7cbfa6a64d
contract_revision: spec/device/v1/task-delegation.md@sha256:79d84d0aed27a3165a3e80fab63361b844320fa335190204b24376093acd7842
```

## Trigger and delta

`DeviceTaskJournal.records()` decodes the parent through `JSONDecoder` before
checking a re-encoded task. Duplicate task keys and forbidden NULs in unknown
task members can thus disappear before validation. In the owning P07 target
contract, unknown task members are allowed, but duplicate decoded member names
and NUL anywhere inside the original task are forbidden. Recovery must apply
that same rule to the original embedded bytes before any use or mutation.
Protocol impact: P07, P18. No new wire field, task format, or journal version
is introduced.

A parent record must contain exactly one top-level `task` name, compared by
decoded Unicode scalar sequence, including escaped spellings. Its original
value must pass the existing real `DeviceTask.decode`, including malformed,
duplicate, unknown-member and NUL rules. Duplicate `task` parents are refused
as ambiguous. Other parent keys and unknown outer values keep the existing
compatibility behavior; in particular do not start rejecting duplicate outer
unknown members merely to implement this check. Invalid data blocks inventory
under the existing journal lock and is preserved byte-for-byte; no acceptance,
prompt, receipt, migration, deletion, or automatic replay follows. This does not
establish BLE identity or make a plaintext result trustworthy.

## Compatibility and fixtures

Valid old v1 data, including valid unknown task members and prior permitted
outer unknown members, stays readable unchanged. An old ambiguous parent or a
task that violated the already specified raw rule fails closed; an old reader
may incorrectly accept it. Newly written valid records remain readable by old
and new readers. Rolling back loses the new rejection, so BLE task grants remain
closed and unresolved evidence must remain intact. No C or Python wire
producer changes: they must still consume the same task fixtures.

Shared task positives and negatives are `spec/device/v1/golden/task-raw-json-cases.jsonl`
(`sha256:269b4363e41a09cda1a6787c576f47fc4bcc413942462039cf965a4988e216d0`),
including unknown values, nested duplicate names, escaped names, distinct
Unicode scalar sequences and NUL in unknown keys/values. Parent inventory cases
are `spec/device/v1/golden/ble-task-inventory.jsonl`
(`sha256:d448a72f8d7f791afc0b8176234ce3a15eeb695c9eb04899938094ecfd490781`),
with schema `spec/device/v1/schema/ble-task-inventory-vector.schema.json`
(`sha256:afc62e2f4425c42b1fd1abef80b91aece47ba01073e70e3888fbaca5d7664758`).
The `embedded_task_raw_vectors` scenario must run every raw task case through
actual journal `records()` using a real valid parent and unchanged fingerprint,
expect each task vector's own `valid`, and compare rejected bytes before/after.
Parent scenarios cover an escaped unique task name, both duplicate-task orders,
task at either end, missing/null/array task, nested names and delimiter escapes,
and preserved outer unknown-member duplicate/NUL behavior. Do not decode/re-encode the embedded
task to construct the inputs or to validate it; do not duplicate task validation.

## Ownership and acceptance

Coordinator owns `spec/**` and this record. Swift implementer owns only
`Sources/PhoneDSHDeviceTasks/UniqueJSONKeys.swift`,
`Sources/PhoneDSHDeviceTasks/DeviceTask.swift`,
`Sources/PhoneDSHDeviceTasks/DeviceTaskJournal.swift`, and
`Tests/PhoneDSHDeviceTasksTests/BLETaskIntentTests.swift`. Freeze this contract
and fixtures before that implementation. Run the real Swift journal and task
tests, `bash firmware/tests/run.sh`, `python3 -m unittest discover -s
examples/lan-mcp-device -p test_tasks.py`, and `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree`. Report each actual result,
including existing P0 failures. Physical reboot, device traffic, old identity
binding and trusted receipt recovery remain unverified and are not closed.

## Revision 2 — raw NUL before Foundation conversion

At `770b9731`, an independent reviewer reproduced an additional violation in
`DeviceTask.decode`: Foundation can collapse scalar-distinct but canonically
equivalent keys before the NUL scan, hiding a forbidden value. The task rules
are unchanged; the new fixture cases require checking every original decoded
string before conversion to a Foundation dictionary. The shared raw vectors
now contain positive scalar-distinct names and negative hidden NUL in either
value position. The parent extraction vectors also cover offsets, escaping and
outer-member compatibility. The implementer is additionally assigned
`DeviceTask.swift`; it must use the one shared raw validation mechanism, preserve
scalar-sequence (not normalized) key equality, and not impose task rules on
outer unknown record values. C, Python and Swift all re-run the revised vectors.
No input bound is added here; the existing unbounded parent-file read is a
separate recovery risk requiring its own version and compatibility decision.
