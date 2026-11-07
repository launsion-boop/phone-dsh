# Validate raw embedded tasks during journal recovery

```yaml
change: PC-20261107-journal-raw-task
contracts: [P06, P07, P18]
status: frozen
breaking: true
version_decision: Preserve journal v1 and task v1; refuse ambiguous/corrupt old records instead of interpreting or rewriting them.
base: f0d6c759724d5b889aad319ddbfecf7cbfa6a64d
contract_revision: spec/device/v1/task-delegation.md@sha256:834b74f58e3bc2d077bbcaea032dc20cb4b4d01f3648360490229834d8ec844a
```

## Trigger and delta

`DeviceTaskJournal.records()` decodes the parent through `JSONDecoder` before
checking a re-encoded task. Duplicate task keys and forbidden NULs in unknown
task members can thus disappear before validation. In the owning P07 target
contract, unknown task members are allowed, but duplicate decoded member names
and NUL anywhere inside the original task are forbidden. Recovery must apply
that same rule to the original embedded bytes before any use or mutation.
Protocol impact: P06, P07, P18. P06 is triggered by the owning task specification; no Worker session-isolation code is changed. No new wire field, task format, or journal version
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
(`sha256:e2b5dde8ae9354daca78f23d486e224a852d59749d1dc2e03ef5ffdf8379c1b8`),
including unknown values, nested duplicate names, escaped names, distinct
Unicode scalar sequences and NUL in unknown keys/values. Parent inventory cases
are `spec/device/v1/golden/ble-task-inventory.jsonl`
(`sha256:10ccf816e91a95cc03a52f035c50a45e2bd618223b05cec4a4b6ef88fefe0953`),
with schema `spec/device/v1/schema/ble-task-inventory-vector.schema.json`
(`sha256:7350d73e861c3e4228dd1830796a68aac96800c6c1c11386e485b5b891e35624`).
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

## Revision 5 — raw task JSON grammar and UTF-8 across all ends

Independent tests found further violations of the existing unknown-member
contract: Swift eagerly materializes unknown numbers and rejects valid large
values, Python's default decoder accepts NaN and Infinity and rejects long valid
integers, and cJSON accepts invalid number spellings, raw controls in strings,
and invalid UTF-8 in unknown members. A valid ignored JSON number is not bounded
by native floating-point range or Python's global integer digit limit; it must
not become an accepted value for a known string field. Invalid syntax and UTF-8
are rejected, without widening the existing transport size limits. These are
existing input compatibility/security corrections, not a new wire format.

The shared raw task JSON vectors now cover a 5,000-digit valid unknown integer,
valid exponent overflow/underflow, invalid non-JSON numeric tokens and raw
control characters. The additional raw-byte vectors
`spec/device/v1/golden/task-raw-bytes.jsonl`
(`sha256:6497afd4ae5fd4179068c380a5335972f044c2938d72adcb26b45380c0060ac7`)
use `schema/task-raw-bytes-vector.schema.json`
(`sha256:7d6ed3bafb7cd1a88ad51d815ff541eb9288f369825a0f2435b1129e72766c2c`)
to carry invalid UTF-8, non-UTF-8 standalone task bytes, invalid outer whitespace and valid multibyte input as hex. Unlike a legacy parent journal, the standalone task wire is UTF-8. Decode the bytes without
replacement and run each case through the real Swift, C and Python task
validators. Also exercise those inputs inside a real Swift journal and preserve
invalid record bytes. The Swift implementer additionally owns
`Tests/PhoneDSHDeviceTasksTests/DeviceTaskTests.swift`; the C/Python implementer
additionally owns `firmware/esp32-reference/main/pdsh_task_validate.c`,
`firmware/tests/test_task_validate.c`, and `firmware/tests/run.sh`. Do not
modify the user's global Python integer limit, relax input checks, add a new
wire field or dependency, or convert ignored numbers to unbounded native values.
Test known fields with numbers to make sure they are still rejected.

Nesting-depth behavior remains a separate unresolved cross-end gap; these
fixtures do not establish agreement for arbitrary nesting. No task enablement,
legacy BLE identity migration or physical-device claim follows from this fix.

## Revision 6 — task-wire BOM versus legacy parent BOM

Standalone task JSON is UTF-8 without a leading byte-order mark. The old
Swift decoder already rejected a standalone BOM, while the C and Python
reference decoders previously accepted it; the shared raw-byte fixture now
requires all three to reject it. This tightens previously accepted malformed
wire input: old BOM-emitting producers must remove it before interoperating
with the new consumers. The separate compatibility decision for an existing
parent journal remains unchanged: its supported initial BOMs are accepted, and
a task extracted from such a parent has no added marker. Rejection must not
rewrite a journal or authorize or replay a task.

## Revision 7 — unambiguous journal identity and outcome

Independent real-journal tests demonstrated that Foundation silently picks
one of repeated known parent `device_id` and outcome `output` fields; another
consumer can select a different identity or terminal result. Freeze the owning
contract's complete list of known parent and outcome members as unique by
decoded Unicode scalar sequence, including escaped and same-value duplicates.
`task` is required exactly once; other known members retain their existing
required/optional rules. Apply the outcome rule regardless of which outcome
variant is selected. Preserve duplicate unknown members at both parent and
outcome levels, and preserve valid outer NUL and encoding compatibility.

This intentionally refuses ambiguous old records previously accepted by the
Foundation decoder; the actual v1 writer never emitted duplicate names. Keep
such bytes untouched and unresolved; do not automatically select a value,
replay, acknowledge or migrate them. The shared inventory cases cover every
known parent and outcome name, escaped and same-value duplicates, and valid
duplicate unknown outcome members; tests must drive actual received and
terminal records and verify failed recovery leaves evidence unchanged.
The rev6 19-byte-vector count must also replace the previous exact count of 18.

## Implementation and verification

Implementation head: `4775b5f8`; contract revision 8: `e603233c`.
Swift journal/task, C reference validation, and Python LAN task ingestion are
implemented against the shared fixtures. `swift test --filter
PhoneDSHDeviceTasksTests` → PASS, 27 tests; the real journal tests consume 74
inventory scenarios, all 36 raw JSON inputs and 19 raw byte inputs, and check
that failed recovery leaves the evidence unchanged. `python3 -m unittest
discover -s examples/lan-mcp-device -p test_tasks.py` → PASS, 7 tests; the
full LAN reference suite with Node 22 → PASS, 17 tests. The C host suite,
run in an isolated tree with the actual source and fully verified locked cJSON,
→ PASS under ASan/UBSan, including 36 raw JSON and 19 raw byte cases.

An isolated ESP32-S3 reference-firmware build using fixed ESP-IDF 6.1 and
the verified locked cJSON → PASS; the new validator source compiled, but the
task-submission validator section was discarded from that default-config final
binary, so this does not establish runtime inclusion or device behavior.
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
→ PASS / FAIL / PASS; P0 still reports eight missing or stale UI contracts.
The C validator's public input is a NUL-terminated string; raw bytes after the
first NUL cannot be verified by that function. The Link upload path has a
separate length-aware NUL check; these tests do not prove all possible C callers
preserve length. No identity binding, trustworthy old receipt, authenticated
BLE session, physical ESP32 task, power-loss or device-reboot result is claimed.

## Revision 8 — inactive and identical outcome duplicate evidence

The revision 7 outcome rule already applies to known fields irrespective of
variant and rejects identical repeated values. Add shared real-journal negative
cases for an inactive `failure_kind` repeated inside a completed outcome and
for identical repeated `output`; the contract and decoder behavior are
unchanged. The implementer must drive them through `records()` and prove that
the rejected evidence remains unchanged.
