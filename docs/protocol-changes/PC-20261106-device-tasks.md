# Device-initiated DSH task delegation

```yaml
change: PC-20261106-device-tasks
contracts: [P03, P05, P06, P07, P08, P09, P12, P16, P18, P20]
status: frozen
breaking: false
version_decision: Adopt the existing task-inbox message semantics as a new negotiated device profile; retain P07 host envelope version 1 and existing BLE Link Tools v1.
base: 48ea9bdd26a6c5f20fff74d1fff06f7c14efde5e
contract_revision: spec/device/v1/task-delegation.md@6495ae24a9127ff04f8afa27abe66e63a489e605
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

| `spec/device/v1/task-delegation.md@feb7f951e69923a6004c62017e9fc4cd3c056b0b` | Coordinator | Clarify that an optional deadline, when present, cannot be null as required by the existing schema. | Swift host, LAN Python device, BLE C firmware |

| `spec/device/v1/task-delegation.md@e66d71ff0d6aa0757ca96bc6ac4dc446e4f8b965` | Coordinator | Define NUL-free terminal output across the Link and LAN bindings; fail the task explicitly when model output cannot be represented. | Swift host, LAN Python device, BLE C firmware |

| `spec/device/v1/golden/task-outcome-cases.jsonl` | Coordinator | Share positive and negative terminal output cases across the two device bindings. | Swift host, LAN Python device, BLE C firmware |

| `spec/device/v1/task-delegation.md@67b37633990413d53f9ae0c4f778796222a0a7ac` | Coordinator | Freeze a local firmware result accessor so the device producer can consume the stored terminal outcome. | BLE C firmware |

| `spec/device/v1/golden/device-task-preset.yaml` | Coordinator | Preserve the exact real Worker preset document used by the pinned digest and adapter conformance tests. | Swift host, Worker DSH |

| `spec/device/v1/task-delegation.md@f510fbc1ce51f5672f7ec800dba9fc2fab15b102` | Coordinator | Fix old-phone compatibility: negotiate task exposure using a separate local HELLO app capability, retain the old HELLO fixture, and share positive/negative negotiation vectors. | Swift BLE host, C wire and reference firmware |

## Resolved contract change request: duplicate JSON members

CONTRACT CHANGE REQUEST
Contract: P07 @ `spec/device/v1/task-delegation.md@f510fbc1ce51f5672f7ec800dba9fc2fab15b102`   Clause: Task and result
Problem: Swift Foundation and cJSON retain the first occurrence of a repeated object key while Python `json.loads` retains the last. Device task interpretation can therefore diverge before validation. Evidence: Foundation decodes `{"x":1,"x":2}` as 1; Python decodes it as 2; cJSON's lookup returns the first member.
Proposal: reject duplicate object member names at every nesting level using raw JSON before decoding; publish positive and negative raw-wire fixtures, update Swift task intake, Python producer/parser and C validation and re-run both device bindings. Affects: Swift host, LAN Python reference, BLE C firmware.

The owner froze rejection of duplicate members at `spec/device/v1/task-delegation.md@96ed6f8f5f43e4f27aa90f1b1e846a881d8d921e`. The Swift, Python and C decoders consume `golden/task-raw-json-cases.jsonl`; their tests passed at `c9d95b31`. GAP-15 records that fix. The overall profile remains `target`: `PDSH_ENABLE_DEVICE_TASKS` is intentionally absent from application build settings until combined application acceptance. Device-originated DSH dispatch is not yet available in the installed app.

| `spec/device/v1/task-delegation.md@96ed6f8f5f43e4f27aa90f1b1e846a881d8d921e` | Coordinator | Reject duplicate object names at every depth before decoding; share raw JSON positive and negative vectors across Swift, Python and C. | Swift host, LAN Python device, BLE C firmware |


## Integration evidence at `1caf8846`

- Base / head: `48ea9bdd26a6c5f20fff74d1fff06f7c14efde5e` / `1caf8846` (this evidence update follows that head).
- Protocol impact: P06; P07; P08; P09; P16; P18; P20; P03: none — existing exec/handoff semantics unchanged; P05: none — native task intake has a separate explicit grant; P12: none — Swift package linkage only, no native ABI change.
- Contract revision: `spec/device/v1/task-delegation.md@96ed6f8f5f43e4f27aa90f1b1e846a881d8d921e`; BLE Link negotiation uses the shared capability vectors.
- Swift task executor, LAN inbox and BLE client: implemented and tested in host processes; application authorization UI and lifecycle integration: partial, behind an unset compile condition. Reference LAN device and BLE C firmware: implemented, host-tested; Worker no-tool preset and global guard: implemented, packed and exercised in a scripted Worker test. Kotlin/Rust/Harmony do not advertise the new task profile.
- `swift test --filter 'DeviceTaskTests|DeviceDSHRunnerTests|DeviceTaskIntakeTests|BLETaskCrossRuntimeTests|PDSHLinkTests'` → PASS at the implementation head; the BLE cross-runtime test drives the real Swift Link client and real C firmware state machine through a simulated transport. The DSH runner test uses real harness mapping with scripted events, not a live model.
- `python3 -m unittest test_tasks test_server` in `examples/lan-mcp-device` → PASS (10 tests, including actual local HTTPS/MCP, SSE and duplicate handling).
- `bash firmware/tests/run.sh` → PASS, including shared task, raw JSON, outcome, store and negotiation fixtures, C Link task state machine and sanitizers.
- `idf.py -B /tmp/pdsh-esp32-task-build build` with ESP-IDF 6.1 → PASS in an isolated build directory. `xcodebuild -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG PDSH_ENABLE_DEVICE_TASKS' build` → PASS at `8fa6f9d5` for the prepared UI configuration.
- `bash scripts/ci/check.sh --only phone-no-dsh-patch` → PASS. `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` → FAIL on existing `exec.md` line cap, stale UI provenance, and four native-MCP fixtures already consumed by tests but not registered by the cross-tree reader inventory. These were not weakened or deleted.
- Not verified: actual model-to-device task end-to-end, iPhone and ESP32 BLE air link, a trusted-LAN-device/iPhone run, power loss on physical hardware, final signed installation, Android/Harmony implementations. The current installed app does not expose device-originated tasks. The application feature condition remains unset pending combined acceptance and a review of the remaining baseline gate failures.

| `spec/device/v1/task-delegation.md@23a827ac628a03eb330760fac82bf885038c59d4` | Coordinator | Clarify that a received-state deadline is provisional and the five-minute cap starts with durable acceptance. | Swift host |

| `spec/device/v1/task-delegation.md@6504cd95499a2d3f4e573a4596972b8f2c8c6328` | Coordinator | Require calendar-valid ASCII RFC 3339 timestamps; Foundation otherwise normalizes invalid dates that Python and firmware reject. | Swift host, LAN Python device, BLE C firmware |

| `spec/device/v1/task-delegation.md@6495ae24a9127ff04f8afa27abe66e63a489e605` | Coordinator | Define duplicate member comparison on decoded Unicode scalar sequences, avoiding Swift-only canonical-equivalence rejection. | Swift host, LAN Python device, BLE C firmware |

## Physical iPhone Worker evidence at `35809e76`

- `xcodebuild test-without-building -xctestrun /tmp/pdsh-lzz-device-build/Build/Products/PhoneDSHDevice_iphoneos27.1-arm64.xctestrun -destination 'id=00008130-001474120091401C' -only-testing:PhoneDSHDeviceTests/DeviceTaskProductionTests/testDeviceTaskRunsInRealWorkerWithoutTools -parallel-testing-enabled NO -resultBundlePath /tmp/pdsh-device-task-real-worker2.xcresult` → PASS, 1 test on iPhonelzzzzzz. The real iOS WKWebView Worker, real `DeviceDSHRunner` and task executor completed a task against a scripted local model; the captured model request had no tools. This is not an external model or device transport E2E.
- Installed and launched the ordinary (task UI condition unset) app on that iPhone. A fresh regular chat prompt returned `PDSH_TEST_OK`; this verifies ordinary model chat only.
- Physical ESP32 air link, production-trusted physical LAN task peer, full device → real model → device, foreground grant revocation in the application and power-loss recovery → NOT_RUN. The separately negotiated device-task profile remains `target` and the task UI remains disabled. Reference BLE task/Link journals have finite non-evicting capacity and require a production lifecycle design.


## Physical LAN task round trip at `1b085632`

`xcodebuild test-without-building -xctestrun <private LAN fixture configuration> -destination 'id=00008130-001474120091401C' -only-testing:PhoneDSHDeviceTests/DeviceTaskProductionTests/testPhysicalLANDeviceToRealWorkerAndBack -parallel-testing-enabled NO -resultBundlePath /tmp/pdsh-device-lan-physical3.xcresult` → PASS, one test on iPhonelzzzzzz. A Python reference device on a separate Mac submitted a task over the actual local network. The iPhone used the real LAN inbox, durable executor and WKWebView Worker; a local scripted model returned `DEVICE_TASK_OK`, which was persisted by the Mac device. A repeated terminal report was accepted as the same outcome; the model request advertised no tools. The private test configuration contained only a short-lived fixture bearer and fixture certificate and was removed after the run.

The test target pinned that temporary certificate in its own `URLSession` delegate; the production inbox still uses unmodified system TLS trust. The app's user-facing task manager/grant lifecycle, a normally trusted production certificate, a real external model, physical BLE, and power-loss recovery were not exercised by this test. Task UI remains disabled and the task profile remains `target`.

### Physical iPhone, LAN reference device and configured model (2026-11-06)

At `e5c8a060` plus the physical test sources in this revision, `xcodebuild test-without-building -xctestrun /tmp/pdsh-lzz-device-build/Build/Products/PhoneDSHDevice_iphoneos27.1-arm64.xctestrun -destination 'id=00008130-001474120091401C' -only-testing:PhoneDSHDeviceTests/RealDeviceTaskModelTests/testDeviceTaskAgainstConfiguredModel -parallel-testing-enabled NO -resultBundlePath /tmp/pdsh-device-task-real-model2.xcresult` → PASS: the iPhone's actual configured external model completed a device-originated text task through the real isolated Worker and executor. The inbox was an in-process test double.

`xcodebuild test-without-building -xctestrun /tmp/pdsh-lzz-device-build/Build/Products/pdsh-lan-real-model.xctestrun -destination 'id=00008130-001474120091401C' -only-testing:PhoneDSHDeviceTests/RealDeviceTaskModelTests/testPhysicalLANDeviceToConfiguredModelAndBack -parallel-testing-enabled NO -resultBundlePath /tmp/pdsh-device-lan-real-model2.xcresult` → PASS: a Python reference device on the Mac submitted a task over physical Wi-Fi; the iPhone's real Worker sent it to the app's configured external model; the reference device persisted the completed `PDSH_DEVICE_OK` result and accepted the identical retry. The ephemeral reference certificate was pinned only by the test URLSession; no production trust policy was changed. The temporary private fixture and credentials were removed afterward. Earlier attempts failed before model dispatch because the application anchor was not ready and the xctestrun file was outside its test-products directory; the test and invocation were corrected.

This does not exercise the app task manager's user grant or foreground/revocation lifecycle, a production-trusted device certificate, physical BLE, or power-loss recovery. Device-origin sessions currently have no phone tools. The task profile remains `target`, and `PDSH_ENABLE_DEVICE_TASKS` remains unset pending combined acceptance. The bounded non-evicting BLE reference journals still require a production lifecycle design.

### Application task manager test (2026-11-06)

Base `46bd523b`; this change adds injection seams for the manager's existing settings, inbox constructor and connected-status check, with production defaults preserving their prior implementations. Protocol impact: P06; P07; P08; P09; P18; P20 — no contract delta; the test drives the existing device-task contract and foreground authorization behavior. The contract revision remains `spec/device/v1/task-delegation.md@23a827ac628a03eb330760fac82bf885038c59d4` plus the frozen revisions in the table above.

`xcodebuild test-without-building -xctestrun /tmp/pdsh-lzz-device-build/Build/Products/pdsh-lan-manager-test.xctestrun -destination 'id=00008130-001474120091401C' -only-testing:PhoneDSHDeviceTests/RealDeviceTaskModelTests/testLANManagerGrantAndForegroundLifecycle -parallel-testing-enabled NO -resultBundlePath /tmp/pdsh-device-manager-full2.xcresult` → PASS on the physical iPhone. With an isolated settings document and secret store, the real manager refused a missing grant; started the real LAN inbox and isolated DSH Worker; completed the reference-device task through the app-configured real model; stopped on explicit disable and simulated scene background; refused background start; and stopped after the underlying MCP grant was revoked. The phone journal recorded `PDSH_MANAGER_OK`; the Mac reference device independently recorded the same terminal result. The test pins the ephemeral certificate and substitutes the MCP connected-status check; it invokes the manager's lifecycle method directly rather than driving the UI or actual scene transition. No production TLS or user MCP settings were changed, and the temporary credentials were removed.

Actual MCP registry disconnect/reconnect, UI authorization and scene transitions, a system-trusted production device certificate, BLE air link, and physical power-loss recovery remain NOT_RUN. The profile remains `target`, the user-facing task feature condition remains unset, and the finite non-evicting BLE reference journals still require a production lifecycle design.

### Baseline gate reconciliation (2026-11-06)

Base `d4481ef3`. Protocol impact: P03: none — reflow existing `spec/v1/exec.md` prose without changing its words or execution semantics; P09: none — the attempted UI provenance refresh was not retained because it revealed 30 real iOS/Android page divergences that this change does not resolve; P18: none — the cross-tree reader registry now lists four existing ADB tests that already load their named native-MCP fixtures. No contract schema, golden vector, receiver behavior, checker assertion, or allowlist is weakened. The registry projection was regenerated from the unchanged execution contract semantics.

`bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS after this reconciliation, including cross-tree mutation checks. `bash scripts/ci/check.sh --only phone-p0-conformance` → FAIL on pre-existing stale UI provenance. An exploratory extraction after correcting those anchors exposed 30 checker-reported page-structure differences, including missing Android device settings pages and potential extraction/comparison false positives that require individual review; that exploratory UI diff was reverted rather than adding exceptions or misrepresenting the disabled target task switch as shipped. The overall required three-gate command remains FAIL until the UI baseline and Android differences are reconciled.

The same physical `testLANManagerGrantAndForegroundLifecycle` was rerun with the injected connected-status provider returning disconnected and then throwing a read error; `/tmp/pdsh-device-manager-disconnect.xcresult` → PASS. In both cases the real manager stopped the intake. This tests its fail-closed reaction, not a real Worker registry event.

### LAN startup authorization race (2026-11-06)

Base `6f390c52`. Protocol impact: P07 — implement the already frozen connection-scoped authorization requirement, with no new wire fields or compatibility change; P09: none — task-manager checks do not change the disabled UI; P06: none — the DSH harness and event semantics are unchanged; P18: none — persisted settings formats are unchanged. Contract revision: `spec/device/v1/task-delegation.md@23a827ac628a03eb330760fac82bf885038c59d4` and subsequent frozen clauses above. The manager now checks the live MCP registry before starting LAN intake and rechecks its foreground state and exact grant/credential after that asynchronous lookup. This closes the interval in which an old connected UI row or a grant revoked during lookup could otherwise start intake before the periodic monitor ran.

`xcodebuild test-without-building -xctestrun /tmp/pdsh-lzz-device-build/Build/Products/pdsh-lan-manager-test.xctestrun -destination 'id=00008130-001474120091401C' -only-testing:PhoneDSHDeviceTests/RealDeviceTaskModelTests/testLANManagerGrantAndForegroundLifecycle -parallel-testing-enabled NO -resultBundlePath /tmp/pdsh-device-manager-start-race.xcresult` → PASS on iPhone. The real manager rejected a stale connected row, a failed registry lookup and revocation while the injected lookup was suspended; it also passed the foreground, revocation, disconnect and lookup-failure checks described above. The connection-status provider was a controlled test double and the ephemeral TLS certificate was test-pinned. Actual registry updates and device-side power loss remain NOT_RUN.

At `a3f01016`, `/tmp/pdsh-device-manager-final.xcresult` → PASS for the same physical manager test with a new LAN reference-device task and the real configured external model after the startup-race fix. The device's SQLite terminal record independently contained `PDSH_MANAGER_OK`. This run also re-exercised the stale-row, suspended-lookup revocation, background, disconnect and status-error cases. The registry-status provider and temporary certificate remained test substitutes as described above.

### Physical BLE radio fixture (2026-11-06; incomplete)

Base `b07b0ab2`. Protocol impact: P07: none — test-only macOS peer uses the existing C Link encoder, decoder, segmentation and C task state machine; P09: none — an opt-in hosted device test changes no product UI. Contract revision remains the frozen task and BLE profiles listed above. `bash firmware/tests/run-macos-radio-peer.sh` → PASS for compiling the test peer and advertising `PDSHRT` with macOS CoreBluetooth. `xcodebuild test-without-building -xctestrun /tmp/pdsh-lzz-device-build/Build/Products/pdsh-ble-radio-test.xctestrun -destination 'id=00008130-001474120091401C' -only-testing:PhoneDSHDeviceTests/RealDeviceTaskModelTests/testBluetoothRadioReferenceDeviceToConfiguredModelAndBack -parallel-testing-enabled NO -resultBundlePath /tmp/pdsh-device-ble-radio.xcresult` → FAIL: the iPhone discovered the peer but the encrypted BLE connection failed with `Encryption is insufficient` while the pairing prompt was awaiting confirmation and the Mac was locked. No task was dispatched in this run. A completed paired-radio run, ESP32 hardware, and radio-disconnect recovery remain NOT_RUN. The peer is an in-memory test fixture, not deployed firmware or a substitute for ESP32 validation.

### Contract freeze: BLE task peer authentication (2026-11-06)

Base `3df4f97e`; Protocol impact: P07 — enforce the existing authenticated, bonded BLE task requirement; P09: none — no shipped UI changes. Trigger: on the physical iPhone, an explicitly unprotected test-only macOS peer completed Link HELLO and task-tool discovery without pairing; `testUnprotectedBluetoothPeerCannotBecomeTaskDevice` → FAIL in `/tmp/pdsh-device-ble-unprotected3.xcresult`. The previously observed pass in `/tmp/pdsh-device-ble-unprotected2.xcresult` was invalid because the fixture's HELLO and tool-list boot IDs disagreed and the connection failed for that unrelated reason. No task was sent to the unprotected peer.

Frozen delta: iOS MUST not expose BLE task support or grant device-task access unless it can independently verify the peer's authenticated binding; the current adapter lacks that evidence and therefore rejects every BLE task grant. No new fields, encodings, errors, retry or cancellation behavior are introduced. New iOS ↔ old or new BLE device: BLE task intake remains unavailable, while ordinary BLE Link behavior is unchanged. Existing task journal data remain readable; rollback to older code must keep the feature condition off. The LAN task binding is unaffected. The existing shared negative runtime fixture is the `PDSH_TEST_INSECURE=1` macOS C-firmware-backed radio peer plus `testUnprotectedBluetoothPeerCannotBecomeTaskDevice`; the encrypted/bonded positive case remains NOT_RUN pending system pairing. This is a fail-closed containment, not a claim that BLE authentication is solved.

A future enabled profile needs a separate owner-authored delta for authenticated identity, pairing/provisioning, key rotation, replay/recovery and old/new compatibility, with shared valid/invalid fixtures and both iOS and device implementations. GAP-16 tracks that requirement. Ownership: coordinator owns contract, Swift adapter and test peer; acceptance: the negative radio test must reject the unprotected peer, Swift BLE tests and C shared vectors must pass, and a production-capable positive authenticated radio test is required before removing containment.

Contract revision `be480461`; Swift implementation: `BLEDeviceStore` now keeps `supportsDeviceTasks` false and rejects every `grantDeviceTasks(..., enabled: true)` until authenticated peer proof exists. The negative radio fixture was corrected to use the same boot ID in HELLO and `tools/list`, and its explicit insecure mode exists only for this test. On the physical iPhone, `/tmp/pdsh-device-ble-unprotected4.xcresult` → PASS: the unprotected peer completed ordinary Link discovery, but task capability stayed unavailable and the explicit grant failed. This demonstrates containment, not a paired positive task path. `swift test --filter PhoneDSHBLETests` → PASS (22 tests); `bash firmware/tests/run.sh` → PASS; physical iOS build-for-testing → PASS. `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` → FAIL overall: `phone-spec` PASS, `phone-cross-tree` PASS, `phone-p0-conformance` FAIL on pre-existing stale `ChatPage.swift:4599` UI provenance. Actual paired BLE task dispatch, ESP32 radio, identity provisioning, user-interface authorization, and power-loss recovery remain NOT_RUN. GAP-16 remains open.

### Controlled stakeholder prototype (2026-11-06)

Base `7cf848cf`. Protocol impact: P06: none — the demo drives the existing task runner and isolated Worker; P07: none — it uses the existing LAN and Link formats and shared fixtures, without changing the production contract; P09: none — the localhost board and test-only harness do not change the shipping app UI. The user explicitly requested a time-boxed prototype. Existing profile status remains `target`; production BLE task authorization remains denied by GAP-16 and the app task UI remains disabled. Old/new compatibility and persisted task semantics are unchanged.

`PDSH_DEMO_PHONE=<connected-iPhone> bash scripts/demo/lan-task-demo.sh` → PASS on the physical iPhone for a free-text task: the real manager and configured external model returned `579` for `123+456`, persisted by the Mac LAN reference device. The test supplies an isolated grant, fixture-only certificate pin and connected-status substitute. `PDSH_DEMO_PHONE=<connected-iPhone> bash scripts/demo/ble-task-demo.sh` → PASS on the same iPhone with a manually paired Mac C reference peer: the real BLE channel, task executor and configured external model returned a response, independently read back from the peer's C state. This opt-in XCTest bypasses the production BLE store solely for the fixed, non-sensitive reference fixture and therefore is not device authentication or an ESP32 result. Both scripts clean their own temporary secrets and processes; the localhost board displays only actual persisted fixture results, with a clear prototype/no-phone-tools label. Physical ESP32 task dispatch, production TLS, user-facing authorization and actual scene lifecycle remain NOT_RUN. The previously identified UI gate failure and GAP-16 remain open.
