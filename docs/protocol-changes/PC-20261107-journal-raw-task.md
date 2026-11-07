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
(`sha256:a57ff654a8502d7c066336e3925e65cf8b5e3a16033e208f5d6347a4a04f4652`),
including unknown values, nested duplicate names, escaped names, distinct
Unicode scalar sequences and NUL in unknown keys/values. Parent inventory cases
are `spec/device/v1/golden/ble-task-inventory.jsonl`
(`sha256:31d4b96f12360a2d39da5870ceb23d9ca1ca2d69ffd3cc06b07ae495ea284305`),
with schema `spec/device/v1/schema/ble-task-inventory-vector.schema.json`
(`sha256:b76f0b0eed847fea6f0af450f8b9174783c986fa05cbdc82acadb11e4a68263b`).
The `embedded_task_raw_vectors` scenario must run every raw task case through
actual journal `records()` using a real valid parent and unchanged fingerprint,
expect each task vector's own `valid`, and compare rejected bytes before/after.
The two parent scenarios assert escaped duplicate `task` rejection and preserved
duplicate outer unknown-member behavior. Do not decode/re-encode the embedded
task to construct the inputs or to validate it; do not duplicate task validation.

## Ownership and acceptance

Coordinator owns `spec/**` and this record. Swift implementer owns only
`Sources/PhoneDSHDeviceTasks/UniqueJSONKeys.swift`,
`Sources/PhoneDSHDeviceTasks/DeviceTaskJournal.swift`, and
`Tests/PhoneDSHDeviceTasksTests/BLETaskIntentTests.swift`. Freeze this contract
and fixtures before that implementation. Run the real Swift journal and task
tests, `bash firmware/tests/run.sh`, `python3 -m unittest discover -s
examples/lan-mcp-device -p test_tasks.py`, and `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree`. Report each actual result,
including existing P0 failures. Physical reboot, device traffic, old identity
binding and trusted receipt recovery remain unverified and are not closed.
