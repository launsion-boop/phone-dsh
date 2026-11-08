# BLE authenticated device-task session (GAP-16 contract freeze)

```yaml
change: PC-20261108-ble-secure-session
contracts: [P06, P07]
status: frozen
breaking: true
version_decision: New ALPN-identified session profile pdsh-ble-task/1 (secure-session-v1) on an additive GATT service; BLE task device_id changes from ble:<Link UUID> to ble:<device key fingerprint> with no conversion (old records legacy, preserved, inert); plaintext Link task access permanently refused; ordinary Link, standard GATT, phone task journal v1 and existing schemas unchanged.
base: 0e9ad261 (codex/fix-pr59, PR #59 head)
contract_revision: spec/device/v1/ble-secure-session.md@secure-session-v1 (freeze commit 0aa86466)
```

Protocol impact: P06; P07. P18: none — no UserDefaults key or settings file
changes; the enrollment record and Keychain item are new P07-owned persistence
defined in the owning contract, and `pdsh.ble.trustedIdentities` is only
declared never-imported. P09: none — no UI contract or page changes in this
freeze; the enrollment and grant screens are a separate P09 change by the
Swift implementer. P12/P24: none in this change — the TLS library dependency
is **not** selected or added here (§4).

## 1. Identification and roles

- **Trigger → current → expected.** GAP-16: an unauthenticated peer could
  negotiate BLE task tools; the TOFU proof is relayable and later bytes are
  unprotected; all BLE task grants are refused and the reference firmware
  refuses plaintext task calls. Expected: a frozen, reviewable contract for
  an offline-enrolled, mutually authenticated, integrity-protected task
  session, with shared fixtures, so the Swift and firmware ends can be built
  in parallel. Nothing is enabled by this change.
- **Coordinator / contract owner:** this change (P07 contract owner). Swift
  implementer and C firmware implementer: to be assigned (§4).
  Reviewer/integrator: to be assigned; must not be either implementer.
- **Owning contract:** [spec/device/v1/ble-secure-session.md](../../spec/device/v1/ble-secure-session.md)
  with schemas `spec/device/v1/schema/ble-secure-*.schema.json` and fixtures
  `spec/device/v1/golden/ble-secure-*.jsonl`; spec checker
  `spec/v1/tools/test_ble_secure_session_golden.py`.
- **Affected ends:** Swift `Sources/PhoneDSHBLE`, `Sources/PhoneDSHDeviceTasks`
  (phone, TLS client); C `firmware/esp32-reference` (board, TLS server,
  console). Kotlin/Android, Rust, TS and HarmonyOS have no BLE task end; the
  Android ordinary Link target is unaffected.

## 2. Contract delta

| Item | Before → after |
| --- | --- |
| BLE task identity | `ble:<Link UUID>` (device-claimed) → `ble:` + SHA-256 of the enrolled device's uncompressed P-256 key (spec §2, §9.2). UUID form is `legacy` (task-delegation.md § Legacy Link task binding). |
| Trust bootstrap | TOFU over BLE (never shipped) → offline enrollment over the board's serial console with button press, both fingerprints, `eid`, staged → committed per side (spec §3, §4). |
| Transport | Link `pdsh.task.*` tools (refused since 2026-11-07) → new GATT service `d04ea024-…` + PSM characteristic → LE CoC → TLS 1.3 (spec §5, §6). |
| TLS | none → TLS 1.3 only, AES-128-GCM-SHA256, secp256r1, ecdsa_secp256r1_sha256, mutual auth, ALPN `pdsh-ble-task/1`, no PSK/0-RTT/tickets/SNI, ≤ 4352-byte records, pinned self-signed certificates with dates ignored (spec §6). |
| Messages | Link JSON RPC → u16-LE length-prefixed closed JSON messages `ready_req/ack`, `next/next_r`, `accept/complete/fail` → `r`, `status/status_r`, `err` (spec §7). |
| Ordering / replay | Link request UUID + receipt → TLS + per-session `cc`/`sc` + strict `seq`; one outstanding request (spec §8). |
| Errors | Link status codes → closed set; fatal vs request-level (spec §7.4). |
| Idempotency / recovery | Link RESULT query-only → `status` query; resend only after an authoritative status shows the precondition (spec §9.3). |
| Persistence (phone) | `ble-ops/` Link intents → new `ble-secure-ops/` intents (no request UUID, with `phone_id`); journal v1 unchanged; enrollment records under `ble-enrollment/v1/`; Keychain phone key. |
| Persistence (board) | `pdsh_id/priv` unchanged except no regeneration when a record exists; new `pdsh_enr/rec_v1`; task store `tasks_v1` → `tasks_v2` with owner `by` (spec §4.2, §10). |
| Plaintext tasks | interim refusal → permanent refusal (ble-link.md, task-delegation.md, spec §11.2). |
| Clause status | new contract `target`; task-delegation BLE binding `target` via the new contract; Link task binding `legacy`. |

Self-check (spec/README.md §5.1): no second expression of an existing
meaning — the Link task binding is retired, not aliased; no existing schema or
golden is changed; every new enum is in a closed, versioned (ALPN) message set
whose unknown values are fatal; no name or number is reused (new GATT UUID,
new NVS keys, new directory names).

### Deviations from the candidate design (contract-owner decisions)

1. Staged state exists only in board RAM (lost on reboot/replug) and in a
   durable phone record; no enrollment-control exchange over BLE for staged
   pairs. Sessions require both sides committed.
2. No TLS exporter binding (unverified API on both stacks and redundant with
   in-connection challenges); flagged for review (spec §15.2).
3. The candidate's quarantine of pre-upgrade Link receipts is not adopted:
   task-transition Link results are `{}` and reveal no task content, so
   ordinary RESULT stays unchanged as required by decision (4) (spec §11.5).
4. A device-side owner (`by`) on accepted/terminal slots replaces inference
   from the ambiguous v1 `next`.
5. One enrolled phone per board; replacement requires revoke first.

## 3. Compatibility and release

The full matrix is spec §12. Summary:

| Producer → consumer | Behaviour |
| --- | --- |
| old → new | old phones keep ordinary Link and stay refused for tasks; old board data migrated (key kept, `tasks_v1` → v2 view) |
| new → old | new phone finds no secure service → tasks unavailable; no fallback |
| new → new | enrolled pairs only |
| persisted old data → new / rollback | legacy UUID records, `ble-ops` intents and trust labels preserved, never authenticated or replayed; phone rollback leaves new files inert; firmware rollback only to firmware with the plaintext denial |

- Version rule: P07 device profile; the secure session is versioned by ALPN,
  not by Link HELLO bits. Link `app_caps` bit11 keeps its allocation and never
  enables tasks.
- Release order: either end may ship first because nothing is enabled until
  both are present and enrolled; the phone keeps refusing BLE grants until the
  §14 acceptance of the spec is recorded and a later change flips the grant.
- `target` remaining: everything in this contract.

## 4. Ownership, acceptance commands and evidence

File ownership is disjoint. Nobody but the contract owner edits `spec/**`,
this change record, `docs/design/device-ble-secure-session-candidate.md` or the
code-contract files of other IDs. A problem with the contract is reported as a
CONTRACT CHANGE REQUEST (AGENTS.md §3.3), not patched locally.

### 4.1 Swift implementer (phone end)

Owns:
- new `Sources/PhoneDSHBLE/SecureSession/**` (phone key, enrollment records
  and ceremony state, token parsing, PSM/CoC client, TLS client adapter,
  certificate builder/verifier, framing, message codec, session state machine,
  readiness);
- `Sources/PhoneDSHBLE/{BLEDeviceStore,BLEDeviceTaskInbox}.swift` (wiring the
  session generation and the grant; BLE grants stay refused until the spec's
  §14 acceptance is recorded in a later change);
- new `Sources/PhoneDSHDeviceTasks/BLESecureTaskIntent.swift` and the
  `ble-secure-ops` inventory in `Sources/PhoneDSHDeviceTasks/DeviceTaskJournal.swift`;
- new `Tests/PhoneDSHBLETests/BLESecure*Tests.swift`,
  `Tests/PhoneDSHDeviceTasksTests/BLESecure*Tests.swift`.

Not owned / separate approval: the TLS library (Package.swift, Package.resolved,
`plugins/THIRD_PARTY.md`) needs its own P12/P24 change record before merge;
probe-app screens under `examples/probe-app/**` need a P09 change.

Must consume through real code: identifiers, enrollment-states `side=phone`,
certificates (`role=device`), frames, messages, session-sequences
`side=phone`, recovery, task-intents; plus the loopback TLS negatives of
spec §13.

Acceptance commands (all must PASS; a skipped stage is INCOMPLETE):

```sh
swift test --filter PhoneDSHBLETests.BLESecure
swift test --filter PhoneDSHDeviceTasksTests.BLESecure
swift test --filter PhoneDSHBLETests
swift test --filter PhoneDSHDeviceTasksTests
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-sdk,phone-license,phone-hygiene
python3 scripts/ci/protocol_impact.py --base 0e9ad261 --body-file <PR body>
```

### 4.2 C firmware implementer (board end)

Owns:
- new `firmware/esp32-reference/main/pdsh_enroll.{c,h}` (console grammar and
  §3.3 state machine), `pdsh_secure_session.{c,h}` (GATT service, CoC with
  credit safety, TLS server, readiness), `pdsh_secure_msg.{c,h}` (framing,
  message codec), `pdsh_secure_cert.{c,h}` (certificate builder/verifier);
- `firmware/esp32-reference/main/{pdsh_identity.c,pdsh_task_store.c,pdsh_task_store.h,main.c,Kconfig.projbuild,CMakeLists.txt}`,
  `firmware/esp32-reference/{sdkconfig.defaults,README.md}`;
- `firmware/esp32-reference/main/link_tools.c` only to keep the permanent
  plaintext denial (no task behaviour may be added there);
- new `firmware/tests/test_secure_*.c` and `firmware/tests/run.sh`.

Must consume through real code: identifiers (public_key/identifier/eid),
enrollment-lines, enrollment-states `side=board`, certificates
(`role=phone`), frames, messages, session-sequences `side=device`,
task-store-cases; existing `ble-task-plaintext-admission.jsonl` keeps passing.

Acceptance commands:

```sh
bash firmware/tests/run.sh          # must run the new secure-session host tests over every listed golden
(cd firmware/esp32-reference && idf.py set-target esp32s3 && idf.py build)   # ESP-IDF v6.1 fff9895c
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-license,phone-hygiene
python3 scripts/ci/protocol_impact.py --base 0e9ad261 --body-file <PR body>
```

`firmware/tests/run.sh` must add, with nonzero exit on any mismatch:
`secure-enroll <lines.jsonl> <states.jsonl>`,
`secure-session --identifiers … --certificates … --frames … --messages … --sequences …`
and `task-store-v2 <task-store-cases.jsonl>` invocations over the files in
`spec/device/v1/golden`, compiled with `-fsanitize=address,undefined` like the
existing host tests.

### 4.3 Integrator

At one head SHA: both ends' commands above, then the spec's §14 physical
acceptance on a real iPhone and reference ESP32-S3 (offline enrollment, task
round trip, reconnect, board reboot, phone restart, and the negative peers).
Only then may a separate change enable BLE grants and mark the profile
`implemented`; GAP-16 closes only with that evidence.

### 4.4 Evidence of this freeze

| Command | Result |
| --- | --- |
| `python3 -B -m unittest test_ble_secure_session_golden` (in `spec/v1/tools`) | PASS (15 tests) |
| `python3 -B spec/tools/registry_build.py --write` | PASS (regenerated) |
| `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-hygiene,phone-license` | phone-spec PASS, phone-cross-tree PASS (24 contracts, 423 references; 86 schemas, 0 breaking), phone-license PASS; phone-hygiene FAIL — pre-existing: `scripts/ci/hygiene.py` reports the same 50 findings on base `0e9ad261` (only line numbers in the candidate doc shift) |
| semantic mutation of 4 fixtures with re-pinned hashes | checker FAILs each (oracle replay, not only the hash) |

Not run: any Swift or C build (no implementation exists), any device, radio,
TLS handshake, Keychain or power-loss test. Fixture certificates and keys were
generated offline with Python `cryptography`; no private key is stored.

## 5. Revision log

| revision | by | reason | ends notified |
| --- | --- | --- | --- |
| secure-session-v1 (`0aa86466`) | P07 contract owner | initial freeze; resolves PC-20261107-ble-session-binding-ccr (task `device_id`) | Swift, C firmware (via this record) |
