# Device-initiated DSH task delegation

```yaml
change: PC-20261106-device-tasks
contracts: [P03, P05, P06, P07, P08, P09, P12, P16, P18, P20]
status: frozen
breaking: false
version_decision: Adopt the existing task-inbox message semantics as a new negotiated device profile; retain P07 host envelope version 1 and existing BLE Link Tools v1.
base: 48ea9bdd26a6c5f20fff74d1fff06f7c14efde5e
contract_revision: spec/device/v1/task-delegation.md@594075cf198a03f5dfcd119c30ca708e927bc084
```

## Trigger, scope and roles

A connected device must be able to submit a task to phoneDSH and receive the final result. The existing BLE/LAN integration provides phone-to-device tools only. The existing P07 host contract requires untrusted device turns to start with no tools, but the current DSH Remote harness cannot set a per-session tool allowlist. The coordinator owns the contract, implements all ends and reviews the combined head. Protocol impact: P03: none — scoped tool isolation does not change exec, handoff or existing journal semantics; P06; P07; P08; P09; P16; P18; P20; P05: none — LAN task intake uses a separate native, explicitly granted HTTPS path and does not change the existing gateway or MCP envelope; P12: none — package wiring only, no FFI/JNI/native ABI change.

The owning profile is `spec/device/v1/task-delegation.md` plus its task schema and shared task fixtures. Existing P07 envelope, harness and BLE Link schemas remain authoritative. Producers/consumers: authenticated LAN device SSE inbox ↔ Swift phone, BLE firmware task tools ↔ Swift Link client, and Swift task executor ↔ isolated Worker DSH session. Kotlin, Rust and Harmony have no registered implementation of this new profile; they do not advertise it and existing P07 behavior is unchanged. The user-visible result goes to the requesting device; tool output, approvals and questions do not.

## Delta and semantics

The task uses the adopted task inbox goal fields, per-device idempotency key, bounded text and deadline. LAN adds an explicitly authorized same-origin `/tasks` SSE and acceptance/terminal POST binding. BLE reuses the existing negotiated Tools RPC and adds four named task tools; it does not add opcodes. Authentication is from the paired/encrypted BLE connection or TLS-verified LAN endpoint and device bearer, not from task-supplied labels. The phone derives the P07 msg ID from device identity and idempotency key, assigns a persisted per-device sequence, and sends `dev:<msg_id>` to the harness. Unknown fields are ignored; unsupported body types are rejected. Payload bounds, charset, expiration and terminal outcomes are in the owning profile.

The phone persists intent before acceptance and before DSH submission, serializes tasks per device, persists a terminal result before reporting it and repeats only the report until acknowledgement. Duplicate keys with conflicting content are rejected. No result, lost connection, cancellation or timeout after submission is represented as a device `failed` receipt; after restart without proven outcome it is `unknown_outcome` and never rerun. Tool result, permission and question events are not exposed to the device. Device-origin sessions are isolated with a dedicated Worker-scoped preset and a monotonic execution guard; an unavailable or unverifiable preset rejects the task. Runtime tests must prove tools remain invisible/unexecutable, including tools registered after the scope begins. Device grants are explicit and default off; LAN task paths are separate from the MCP grant and BLE grants clear on disconnect. No claim of unattended operation while iOS suspends the app.

## Compatibility

| Pair | Behavior |
| --- | --- |
| Old device → new phone | No task tools or `/tasks` endpoint means task intake unavailable; existing BLE/LAN skills remain usable. |
| New device → old phone | The old phone does not consume its inbox; the device retains tasks until explicit acceptance or expiry. Existing Link/MCP operations remain unchanged. |
| New → new | Only an authorized connection and implemented/negotiated task profile may submit goals; task and outcome behavior follows the profile. |
| Old persisted data → new / rollback | Existing session, settings and WAL formats remain unchanged. New phone and device task journals are additive. Rollback retains them and never replays an unresolved task. |

The scoped Worker preset and its packed Worker image must be delivered with the host task executor. The phone must not invoke a target task profile before all affected implementations pass their shared fixtures. The LAN and BLE implementations are independently negotiable; partial deployment must not claim the absent binding.

## Ownership and acceptance

- Coordinator/contract owner: `spec/device/v1/task-delegation.md`, `spec/device/v1/schema/task.schema.json`, `spec/device/v1/golden/task-cases.jsonl`, registry and this record.
- Swift host: task inboxes, authenticated task grants, durable per-device ledger, DSH session adapter, app lifecycle and minimal UI; Worker: scoped no-tools preset and its packed assets; reference devices: LAN inbox server and BLE reference firmware. All are owned by the coordinator in this task.
- The Swift parser, reference LAN device and BLE firmware parser must drive their actual decoders using `golden/task-cases.jsonl`, with invalid shapes, ID collisions and timestamp/UTF-8 limits. Each binding needs real failure/reconnect tests, not copied JSON structs.
- Required: `swift test` for the task executor and both transports; firmware host tests; reference LAN TLS/SSE and duplicate/crash tests; Worker tests proving the device preset suppresses and denies tools; affected Worker asset rebuild; `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`; iOS app build; and real device evidence where available.
- `swift test --filter DeviceTaskTests` → PASS (6 tests: shared task vectors, UTF-8 bounds, lock/corruption, duplicate completion, interrupted run and unauthorized/concurrent delivery). Other task implementation commands → NOT_RUN. The task executor is not wired to either transport or a DSH runner yet. No DSH model, iPhone, BLE board or LAN device task E2E is claimed.

## Revisions

| Revision | Owner | Reason | Affected ends |
| --- | --- | --- | --- |
| `spec/device/v1/task-delegation.md@063cd484c4bed807315f4210e6ff56bff4819efd` | Coordinator | Device-origin task submission and result return requested; preserve P07 isolation and unknown-outcome semantics. | Swift host, Worker DSH, BLE C firmware, LAN reference device |
| `spec/device/v1/task-delegation.md@121963de5f204b5f4334126bc57150dc0bd92533` | Coordinator | Require alphanumeric first character on device task identifiers so HTTP path segments cannot be dot segments; add shared negative vector. | Swift host, Worker DSH, BLE C firmware, LAN reference device |
| `spec/device/v1/task-delegation.md@101d051f1f92bc2e4474859c51075dbe066c11d1` | Coordinator | Freeze the versioned host task journal and fail-closed recovery before implementation. | Swift host, Worker DSH, BLE C firmware, LAN reference device |
| `spec/device/v1/task-delegation.md@81af7b8255640e58d4bedada674a0f166a96da7b` | Coordinator | Reserve HTTP 409 for identical terminal reports and use 422 for conflicting results, so retries cannot mistake a conflict for success. | Swift host, Worker DSH, BLE C firmware, LAN reference device |
| `spec/device/v1/task-delegation.md@aa96005178b35c220cb4909a0daf3dad2cd41b5f` | Coordinator | Bound timestamp precision to milliseconds so Swift and device deadline comparisons agree. | Swift host, Worker DSH, BLE C firmware, LAN reference device |
| `spec/device/v1/task-delegation.md@facc4276ad421f1d989a69ad929e7d4efac7978f` | Coordinator | Pin the verified preset document and add an immutable-session-header global guard against a blank-session preset-switch race. | Swift host, Worker DSH, BLE C firmware, LAN reference device |

| `spec/device/v1/task-delegation.md@4338ff67726eb008d4c157cc542a2df118d34268` | Coordinator | Bind LAN identity to the authorized endpoint and verify the live global guard before each task. | Swift host, Worker DSH, LAN reference device |

| `spec/device/v1/task-delegation.md@abc9046d68e852e36f738dcb3f82a3a82d47d576` | Coordinator | Use the Loader-qualified inventory entry ID observed in the real packed Worker. | Swift host, Worker DSH |

| `spec/host/v1/golden/device-envelope-uplink-text-task.json` | Coordinator | Freeze the existing P07 uplink mapping for a LAN-originated task, including the derived identity and message ID. | Swift host |

| `spec/device/v1/task-delegation.md@562b87282d988b9933f988d1961097a58b5710dd` | Coordinator | Resolve the interaction with Link persistent receipts: task mutations are query-only after an uncertain upload; specify the remaining journal freeze before enabling the client. | Swift host, BLE C firmware |

| `spec/device/v1/task-delegation.md@86a6a6aba853b4834cbafb665de247ba53f704be` | Coordinator | Freeze the BLE transition intent journal, deterministic Link operation IDs and shared positive/negative vectors. | Swift host, BLE C firmware |

| `spec/device/v1/task-delegation.md@e9f10f57eacd6e5203ee10501bf75b97eb27f680` | Coordinator | Freeze bounded reference firmware task storage and transition results, including shared valid/invalid store fixtures. | BLE C firmware, Swift host |

| `spec/device/v1/task-delegation.md@cf2239edf5d35963c62b058af47f55e2e12be7f9` | Coordinator | Reject control and format characters in requester labels across Swift, Python and C, avoiding cJSON embedded-NUL truncation. | Swift host, LAN Python device, BLE C firmware |

| `spec/device/v1/task-delegation.md@594075cf198a03f5dfcd119c30ca708e927bc084` | Coordinator | Reject embedded NUL throughout task JSON before cJSON parsing so unknown members cannot hide truncated strings. | Swift host, LAN Python device, BLE C firmware |
