# Validate raw embedded tasks during journal recovery

```yaml
change: PC-20261107-journal-raw-task
contracts: [P07, P18]
status: frozen
breaking: true
version_decision: Preserve journal v1 and task v1; refuse ambiguous/corrupt old records instead of interpreting or rewriting them.
base: f0d6c759724d5b889aad319ddbfecf7cbfa6a64d
contract_revision: spec/device/v1/task-delegation.md@sha256:9cd23d1b318fc0e7951986e5de9dcb549897b1983cda1f89ec44d70526a51531
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
as ambiguous. Other valid parent keys and unknown outer values keep the existing
compatibility behavior; malformed JSON and invalid Unicode scalars are corrupt even when the old Foundation decoder lazily ignored them; in particular do not start rejecting duplicate outer
unknown members merely to implement this check. Invalid data blocks inventory
under the existing journal lock and is preserved byte-for-byte; no acceptance,
prompt, receipt, migration, deletion, or automatic replay follows. This does not
establish BLE identity or make a plaintext result trustworthy.

## Compatibility and fixtures

Valid old v1 data, including valid unknown task members, prior permitted
outer unknown members, and UTF-8/16/32 encodings accepted by the existing
platform decoder, stays readable unchanged. Lossless transcoding of text is
permitted before extracting the raw task, but object decoding/re-encoding is not. An old ambiguous parent or a
task that violated the already specified raw rule fails closed; an old reader
may incorrectly accept it. Newly written valid records remain readable by old
and new readers. Rolling back loses the new rejection, so BLE task grants remain
closed and unresolved evidence must remain intact. No C or Python wire
producer changes: they must still consume the same task fixtures.

Shared task positives and negatives are `spec/device/v1/golden/task-raw-json-cases.jsonl`
(`sha256:7a5a5b71ddfce2bad775fe6ef13728774fc1fdf9130d53d0e448c5f914fe5b6a`),
including unknown values, nested duplicate names, escaped names, distinct
Unicode scalar sequences and NUL in unknown keys/values. Parent inventory cases
are `spec/device/v1/golden/ble-task-inventory.jsonl`
(`sha256:bfb01ffc9d843ae2993565fcdc2f7ab58a6c3e67bae93c051e589352e1325699`),
with schema `spec/device/v1/schema/ble-task-inventory-vector.schema.json`
(`sha256:a2750beb594f3874c161dcb12d0f3fef19b657d1ffcb1db7c091b78eec69283c`).
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

## Revision 3 — preserve encodings; reject invalid JSON

At `9cbefd44`, independent probes showed the existing record decoder accepts
UTF-8 BOM and UTF-16/32 encodings, so freeze shared valid cases for the formats
it accepts, including supported BOMs. The original parent must still pass the
platform record decoder: a transcoding implementation must not expand that
acceptance, for example by treating this platform's rejected UTF-32LE BOM as
valid. Text-level conversion must preserve Unicode scalars and JSON escape
lexemes; it is not object-level re-serialization.

The platform decoder may lazily ignore malformed strings in unknown outer
values. Those are corrupt JSON, not an allowed unknown-field extension: raw
invalid escape, unpaired surrogate and unescaped control characters are
rejected throughout the record, including unknown values. This intentionally
closes a pre-existing corruption hole and can make previously misaccepted
invalid records unreadable; keep the bytes for explicit recovery. Valid outer
unknown duplicate names and NUL strings still keep their prior behavior.

## Revision 4 — scalar agreement and JSON number syntax

An independent reviewer reproduced that the Python LAN task consumer accepted
unknown-member strings containing unpaired Unicode surrogates, while Swift and
C reject them. Freeze scalar validity throughout every task string and key; a
properly paired surrogate escape remains valid. The real shared raw vectors now
cover unknown high/low surrogate values and keys plus a valid pair. The Python
implementer exclusively owns `examples/lan-mcp-device/tasks.py` and its existing
`test_tasks.py`, and must reject invalid scalars recursively without changing
unknown-member or valid Unicode behavior. This tightens previously invalid
inputs; valid old data and the wire format remain unchanged. Swift, Python and C
must all consume the same revised vectors.

The raw parent scanner must also validate number and literal *syntax* even in
unknown fields, since the platform decoder may lazily ignore invalid `01` or
`1e`. Validate the JSON grammar without converting unknown numbers to a numeric
type: the shared parent fixtures require large valid exponent `1e9999` and a
valid exponent to remain accepted. This is not a new numeric-domain limit.

A lossless transcoder must not silently discard trailing incomplete code units;
shared UTF-16 and UTF-32 parent negatives cover that case.
