# BLE authenticated device-task session (GAP-16 contract freeze, revision `secure-session-v2.1`)

```yaml
change: PC-20261108-ble-secure-session
contracts: [P06, P07]
status: frozen
breaking: true
version_decision: New ALPN-identified session profile pdsh-ble-task/1 (secure-session-v2, superseding the never-implemented secure-session-v1 with unchanged wire messages and ALPN) on an additive GATT service; physically entered enrollment mode; pdsh.identity.prove retired on secure-service firmware; task store v2 records the migrated tasks_v1 digest; BLE task device_id changes from ble:<Link UUID> to ble:<device key fingerprint> with no conversion (old records legacy, preserved, inert); plaintext Link task access permanently refused; ordinary Link, standard GATT, phone task journal v1 and existing schemas unchanged.
base: 0e9ad261 (codex/fix-pr59, PR #59 head)
contract_revision: spec/device/v1/ble-secure-session.md@secure-session-v2.1 (amends secure-session-v2, freeze commit e031b643 pinned 5f6fd5d3; v1 freeze 0aa86466, pinned 082aff5f; v2.1 commit in §7)
```

Protocol impact (v1 freeze): P06; P07. P18: none — no UserDefaults key or settings file
changes; the enrollment record and Keychain item are new P07-owned persistence
defined in the owning contract, and `pdsh.ble.trustedIdentities` is only
declared never-imported. P09: none — no UI contract or page changes in this
freeze; the enrollment and grant screens are a separate P09 change by the
Swift implementer. P12/P24: none in this change — the TLS library dependency
is **not** selected or added here (§4). The v2 revision's own declaration is
in §6.1.

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

Must consume through real code (revision `secure-session-v2`): identifiers,
enrollment-states `side=phone`, certificates (`role=device`), frames, messages,
session-sequences `side=phone`, recovery, task-intents; plus every row of
`ble-secure-conformance-matrix.jsonl` whose `ends` contains `phone` (TLS
loopback rows against an independent peer; physical rows only at integration).
The v1 → v2 change list for this end is §6.4.

Acceptance commands (all must PASS; a skipped stage is INCOMPLETE):

```sh
swift test --filter PhoneDSHBLETests.BLESecure
swift test --filter PhoneDSHDeviceTasksTests.BLESecure
swift test --filter PhoneDSHBLETests
swift test --filter PhoneDSHDeviceTasksTests
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-sdk,phone-license,phone-hygiene
python3 scripts/ci/protocol_impact.py --base e031b643 --body-file <PR body>
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
  plaintext denial and to retire `pdsh.identity.prove` (spec §11.3; no task
  behaviour may be added there);
- new `firmware/tests/test_secure_*.c` and `firmware/tests/run.sh`.

Must consume through real code (revision `secure-session-v2`): identifiers
(public_key/identifier/eid), enrollment-lines, enrollment-states `side=board`
(gesture classifier and indicator driver included), certificates
(`role=phone`), frames, messages, session-sequences `side=device`,
task-store-cases, coc-cases; every row of `ble-secure-conformance-matrix.jsonl`
whose `ends` contains `board`; existing `ble-task-plaintext-admission.jsonl`
keeps passing. The v1 → v2 change list for this end is §6.5.

Acceptance commands:

```sh
bash firmware/tests/run.sh          # must run the new secure-session host tests over every listed golden
(cd firmware/esp32-reference && idf.py set-target esp32s3 && idf.py build)   # ESP-IDF v6.1 fff9895c
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-license,phone-hygiene
python3 scripts/ci/protocol_impact.py --base e031b643 --body-file <PR body>
```

`firmware/tests/run.sh` must add, with nonzero exit on any mismatch:
`secure-enroll <lines.jsonl> <states.jsonl>`,
`secure-session --identifiers … --certificates … --frames … --messages … --sequences …`,
`secure-coc <coc-cases.jsonl>`
and `task-store-v2 <task-store-cases.jsonl>` invocations over the files in
`spec/device/v1/golden`, compiled with `-fsanitize=address,undefined` like the
existing host tests.

### 4.3 Integrator

At one head SHA: both ends' commands above and their conformance-matrix
results, then the spec's §14 physical acceptance on a real iPhone and
reference ESP32-S3 with the enrollment button and indicator fitted (offline
enrollment, task round trip, a ≥ 4-minute task across a session renewal,
reconnect, board reboot, phone restart, and the negative peers including two
swapped enrolled boards).
Only then may a separate change enable BLE grants and mark the profile
`implemented`; GAP-16 closes only with that evidence.

### 4.4 Evidence of the v1 freeze

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
| secure-session-v2 (`e031b643`) | P07 contract owner | resolves the independent security review [`docs/reviews/ble-secure-session-v1-review.md`](../reviews/ble-secure-session-v1-review.md) (H1–H3, M1–M6, assumption conditions, L1/L2/L4); §6 below | Swift (`ws/ss-swift`) and C firmware (`ws/ss-firmware`) implementers, via §6.4 and §6.5 |
| secure-session-v2.1 (§7) | P07 contract owner (integrator `ws/ss-integrate`) | resolves the implementers' open items against v2 (`e3d37565` Swift, `8a63b3d4` firmware, merged `3505b690`): two CONTRACT CHANGE REQUESTs and two findings; adds the cross-runtime conformance test; §7 below | both ends, via §7.3 (changes made by the integrator in the same branch) |

## 6. Revision `secure-session-v2` (contract change after independent review)

### 6.1 Identification

```text
Contract:          P07 (owner), P06 (task-delegation BLE binding text)
Base:              082aff5f (secure-session-v1 pinned) + 2c237169 (review), merged as b3e2de90
Trigger:           §3.4 review verdict "approve with required changes"; AGENTS.md §3.3
Current → expected: v1 frozen, not implemented on any end → v2 frozen, not implemented;
                   both implementers rebase onto v2 before any end is merged
Version decision:  same ALPN pdsh-ble-task/1 and identical wire messages (v1 was never
                   implemented or released, so no v1 end can exist to confuse); the
                   console grammar, board state machine, phone state machine, timers,
                   task store document and fixtures change. No v1 end may ship.
```

Protocol impact (this revision): P06; P07 — spec, schemas, goldens and checker
of the P07 contract, plus the BLE-binding paragraph of task-delegation.md (P06
text only, no task-model change). P09: none — no UI contract changes here; the
USB warning, arm-hold instructions, device selection and grant naming are
requirements the Swift implementer realizes through its own P09 change. P18:
none — no UserDefaults key or settings file changes. P12/P24: none — no
dependency is added (the checker's ECDSA verifier is pure Python).

### 6.2 Per-finding resolution

| Finding | Resolution | Where |
| --- | --- | --- |
| H1 enrollment via routine press on an always-live console | **Fixed.** Authority-changing verbs require enrollment mode, entered only by a 5 s hold (no host command arms); dedicated indicator required (armed 1 Hz, confirm 4 Hz), else `controls_unavailable`; absolute 300 s window; every error and every completed action leaves the mode; confirmation is a separate 3 s hold whose press edge follows the `press` line; a short press aborts (`gesture`); a hold begun before the line never confirms; no pairing window / Link event while armed. Hold-at-reset rejected: GPIO0 is a strapping pin (download mode). | spec §3.1–§3.3, §11.1; `ble-secure-enrollment-states.jsonl` (32 board cases), `-lines.jsonl` |
| H2 any USB host has full authority | **Fixed by honest scoping.** §1 now states that every attached USB host is trusted with key, records and firmware, and the reference board is not resistant to it; UI/README obligation; `production-hardened` profile (secure boot v2, flash encryption release, secure download mode, USB-JTAG/JTAG eFuse-disabled) listed as `target` with hardening status `none` and requiring its own revision with hardware evidence. | spec §1, §3.4 |
| H3 pre-auth CoC/TLS memory safety untested | **Fixed.** Normative limits table (credits ≤ free buffers at every instant, return credits only on consume, close on credit overrun / SDU 0 / SDU > MTU / K-frame > MPS / SDU overrun, ≤ 4 rx K-frames, ≤ 32 KiB per session, 1 session global, ≤ 2 queued SDUs, defined `BLE_HS_ESTALLED` ownership, 2 s back-off, 3 failed handshakes per LE link); implementer must record the credit-check mechanism; LE encryption SHOULD when bonded. Oracle-replayed credit vectors plus 10 `coc-*` matrix rows (host and device). | spec §5, §13; `ble-secure-coc-cases.jsonl`, `ble-secure-conformance-matrix.jsonl` |
| M1 phone pins any committed device | **Fixed.** User selects one record before connecting; server pin is that record only; another enrolled board → `pin_mismatch`; grant only after readiness, naming the record label and device ID. | spec §6.2 rule 3, §8.2; cert `other-enrolled-device`; sequences `phone-two-boards-swap-rejected`, `phone-selected-second-board`, `phone-grant-requires-readiness`; matrix `physical-two-enrolled-boards-swap` |
| M2 phone post-readiness unspecified | **Fixed.** Response table (type, `re`, phase), request-level errors on first send and resend → unresolved, session continues; everything else → `err malformed` + close with intent kept; invalid offered task → malformed; local idempotency conflict → no accept, `next` suspended. | spec §7.4, §8.2 step 5, §9.3; 49 `side=phone` sequences |
| M3 timers cannot complete a normal task | **Fixed.** `status` is the keepalive (≤ 30 s); board idle 90 s; lifetime 600 s unchanged; the grant belongs to the CoreBluetooth connection generation and survives session renewal; explicit bounds: accept window 1800 s, report window +600 s, 3 failed attempts end it. Numbers justified in §8.1. | spec §8.1, §8.2; device `keepalive-status-keeps-session`, `lifetime-expires`, `idle-timeout`; phone `phone-grant-survives-session-renewal`, `phone-grant-accept-window`, `phone-failed-attempts-end-grant` |
| M4 signing oracle; entropy | **Decided: one key, oracle removed.** Keep the device key for TLS (existing device IDs stay valid; a split key would change every device ID and still leave the prove oracle unless also retired). Firmware with the secure service retires `pdsh.identity.prove` (not listed; call → `UNSUPPORTED` 14, no signature); board ECDSA is deterministic (RFC 6979) on the remaining signing path; device key, `eid`, `sc` and TLS randomness are drawn only while a documented ESP32-S3 entropy source is active (BLE/Wi-Fi RF on, or `bootloader_random_enable()`), first-boot generation moved accordingly and logged. | spec §2, §4.2, §11.3, ble-identity.md; matrix `board-identity-prove-retired`, `board-deterministic-ecdsa`, `board-entropy-before-secret-generation` |
| M5 MUSTs without negatives; weak oracle | **Fixed.** Every listed gap now has vectors: full-tuple record check (`record-replaced-while-committed`, `record-rev-bumped-same-values`; oracle compares the whole captured tuple); phone key mismatch (`phone-key-changed*` recovery, `phone-recovery-key-changed`); storage on complete/fail; seq exhaustion (`phone-seq-exhausted`); lifetime; certificates `not-before-far-future-ignored`, `basic-constraints-absent`, `x509-v1`, `compressed-spki-point`, `off-curve-spki-point`; identity-reset from `none`/`revoked` and its storage failure; consumed press emits no Link event (`legacy_button`); loopback negatives (record overflow, ticket, 0.5-RTT, KeyUpdate) as matrix rows. The checker now decides certificates from DER with its own parser and P-256 verifier (no dependency, so never SKIP). | checker; all goldens |
| M6 compatibility rows | **Fixed.** Roll-forward: `tasks_v2.v1_sha256` records the migrated `tasks_v1` digest; a changed/unreadable/new `tasks_v1` disables the store (never merge or drop). Phone rollback floor: only to builds that refuse every BLE grant; "not dispatched" with code references and a required Swift test. v1 ↔ v2 row. | spec §10, §12; store cases `v1-changed-after-migration`, `v1-appeared-after-fresh-v2`, `v1-unreadable-after-migration`, `v1-removed-after-migration`, `v2-missing-v1-sha256` |
| L1 KeyUpdate permitted | **Fixed.** Never sent; received → session fails. | spec §6.1; matrix `tls-key-update-received` |
| L2 PSK/early data abort vs ignore | **Fixed.** Outcome-based: server never selects PSK or accepts early data; aborting or ignoring both conformant; client ClientHello inspected. | spec §6.1; matrix `tls-psk-offered`, `tls-early-data-offered`, `tls-client-hello-profile` |
| L3 revoke storage failure re-activates after reboot | **Accepted, unchanged.** The failure happens while the operator is present (enrollment mode is attended) and is reported as `storage`; a persisted "revoke pending" marker would need a second write to the same failing NVS and could itself fail; the phone-side `forget` is independent and should accompany any revoke. Re-activation needs a storage fault and a reboot before the operator retries. Recorded as a limitation in spec §3.3. | spec §3.3 |
| L4 consistency items | **Fixed.** `cmd` wording for unsolicited lines; identity-reset erase order (`rec_v1` then `priv`, each committed) and `rev = 0`; client `err` `re` MUST be 0 in §7.3; §11.5 now cites the RAM-only `pdsh.task.next` results; orphaned slots recorded as a liveness limit in §4.4. | spec §3.2, §3.3, §4.4, §7.3, §11.5 |

### 6.3 Review assumptions (spec §15) and their conditions

| # | Review decision | How v2 applies the conditions |
| --- | --- | --- |
| A1 certificates, dates ignored | accept with conditions | §6.2 now states the outcome (rules 1–5 decide, inside the handshake, abort with `bad_certificate`, no optional verify), leaves the library mechanism to each end, and adds the missing vectors; loopback rows `tls-certificate-vectors`, `tls-negative-decision-aborts-handshake` |
| A2 no exporter | accept with conditions | §6.1 "Application data ordering" (no 0.5-RTT from the board; phone ignores nothing — data before `ready_req` fails the session); M1 fixed; rows `tls-no-half-rtt-data`, `tls-half-rtt-data-before-ready` |
| A3 phone key | accept with conditions | §4.1: Secure Enclave mandatory where present; software key only without SE and non-extractable; all signing through `SecKeyCreateSignature` via an opaque hook; export forbidden; CCR if impossible |
| A4 button authorization | reject as written | replaced by enrollment mode (H1) with the honest USB statement (H2) |
| A5 resend | accept with conditions | resend only as the very next request (§9.3; `phone-resend-not-next-request`, `phone-resend-without-status`); phone-key-mismatch vectors; first-send request-level errors defined (M2) |
| A6 no anti-rollback | accept with conditions | roll-forward detection and phone-rollback floor (M6) |
| A7 Link RESULT unchanged | accept | §11.5 cites the RAM-only `next` results |
| A8 4352-byte cap | accept with conditions | sender cap configured on both ends, receiver MUST reject with `record_overflow`, handshake flight fits the input buffer; rows `tls-record-overflow`, `tls-record-sender-cap`, `tls-client-flight-fits-input-buffer` |

### 6.4 What the Swift (phone) end must change from v1

Unchanged from v1: identifiers and token parsing, phone enrollment records and
ceremony, framing, message codec, intent format and `ble-secure-ops`
inventory, journal binding, wire messages, ALPN.

1. **Device selection (M1).** Replace "pin = set of committed records" with
   one user-selected record per connection generation; server pin = that
   record's device; another key (including another enrolled board) →
   `pin_mismatch`. Store a user label with each committed record (UI data).
2. **Generation vs session and grant (M3).** Model the CoreBluetooth
   connection generation for one selected device containing successive
   sessions. Grant only by foreground action after a session of the
   generation reached readiness; the grant UI names label + device ID. The
   grant survives session close; ends on disconnect, background, forget,
   record state/rev change, key loss/change, user revoke, accept window
   (1800 s) / report window (+600 s), or 3 consecutive failed attempts. In the
   report window only `status`/`complete`/`fail`.
3. **Response handling (M2).** Implement the §8.2 table exactly: correlate by
   `re`; check type and `r.phase`; request-level errors to
   accept/complete/fail (first send or resend) → unresolved, session
   continues; `err conflict` to status → unresolved; anything else → send
   `err malformed` (`re: 0`) and close. Readiness failures send
   `err record_mismatch` / `err bad_challenge` / `err malformed`. Invalid
   offered task → malformed; local idempotency conflict → no accept, no more
   `next` in that session.
4. **Timers.** Response wait 10 s → `err timeout` + close; lifetime 600 s →
   close_notify only; keepalive `status` ≤ 30 s while a task is accepted or
   running (never `next`); `seq` 65535 → close and open a new session.
5. **Recovery (A5).** Resend only as the very next request after the
   `status_r` that allowed it; any other request voids it. Intent `phone_id` ≠
   current key → unresolved.
6. **Phone key (A3).** Secure Enclave key on device; software non-extractable
   key only without SE ("软件密钥"); every signature through
   `SecKeyCreateSignature` via the TLS stack's opaque-signing hook; never
   export or make extractable. If the chosen TLS stack cannot do this, file a
   CONTRACT CHANGE REQUEST.
7. **TLS (A1, A2, A8, L1, L2).** Verification inside the handshake with the
   §6.2 outcome (v3 required; compressed/off-curve points → `curve`); never
   send KeyUpdate, fail on receipt; outgoing records ≤ 4352, reject larger with
   `record_overflow`; discard any NewSessionTicket; application data before
   `ready_req` fails the session; ClientHello carries only the §6.1
   extensions.
8. **UI (via its own P09 change).** USB warning; arm-hold and indicator
   instructions; device selection and grant naming.
9. **Tests.** Consume the regenerated files (new phone sequence schema,
   recovery `intent_phone_id`/`current_phone_id`, new certificate vectors), the
   test hooks of spec §13 (`elapse`, `set_last_seq`), every matrix row with
   `phone`; add a test that `DeviceTaskExecutor.process(authorized: false)`
   throws `unauthorized` before touching the journal for a secure parent
   record (phone rollback row).

### 6.5 What the C (firmware) end must change from v1

Unchanged from v1: identifiers, certificate producer profile, framing, message
codec, wire messages, ALPN, board task semantics (§9.1), plaintext denial.

1. **Enrollment mode (H1).** Gesture classifier (debounce ≥ 50 ms; `arm_hold`
   5 s; `confirm_hold` 3 s with press edge after the `press` line;
   `short_press`; `held_across_press_line`); `mode` locked/armed; 300 s
   absolute window; `armed window_s=300` line; `mode` field in `status`;
   codes `controls_unavailable`, `not_armed`, `gesture` (remove
   `button_unavailable`); every error (including `syntax`) and every success
   disarms; `begin`/`revoke`/`identity-reset` require armed; while armed, no
   pairing window and no `button.pressed`; while locked the press edge is
   unchanged.
2. **Indicator.** A dedicated output (new Kconfig, default unset; MUST NOT be
   the `light.*` LED), patterns off / 1 Hz / 4 Hz; without button or indicator
   the board never arms.
3. **identity-reset.** Erase `rec_v1` then `priv`, each committed; `rev = 0`;
   key generation under the entropy rule.
4. **Keys (M4).** Retire `pdsh.identity.prove` in `link_tools.c` (not listed,
   call → 14, no receipt, no signature); deterministic ECDSA on the TLS
   signing path; generate the device key, `eid`, `sc` and TLS randomness only
   with an active entropy source — move first-boot generation after
   `nimble_port_init()`/controller enable or bracket it with
   `bootloader_random_enable/disable`, and log the source.
5. **CoC (H3).** Implement the §5 table (credit accounting checked before any
   receive slot is touched, close reasons, ≤ 4 rx K-frames, ≤ 32 KiB per
   session, ≤ 2 queued SDUs, `BLE_HS_ESTALLED` ownership, 2 s back-off,
   3 failed handshakes per LE link); record the mechanism used in the pinned
   NimBLE; SHOULD require LE encryption when bonded.
6. **TLS (A2, A8, L1, L2).** No application data before client Finished is
   verified; no tickets; PSK/early data never selected; KeyUpdate never sent,
   receipt fails; record cap on send and receive; verification inside the
   handshake.
7. **Session timers.** Idle 90 s (`err timeout`); lifetime 600 s
   (close_notify only, no dispatch afterwards); full captured-tuple check
   before every dispatch and mutation.
8. **Task store (M6).** `v1_sha256` field; boot selection per spec §10
   including the roll-forward check; disabled-store behaviour.
9. **Tests and docs.** `firmware/tests/run.sh` adds `secure-coc`; the
   `secure-enroll` runner feeds gestures and asserts `volatile` and
   `legacy_button`; store runner checks `write_v1_sha256`; every matrix row
   with `board`; README: USB warning, required button + indicator wiring.

### 6.6 Still needs a human security engineer

Unchanged by this revision and tracked under GAP-16 (review "Needs a human
cryptographer / security engineer"):

1. Mbed TLS (ESP-IDF v6.1 fork and upstream) wiring of the §6.2 outcome
   without a trusted clock or CA chain; that no optional-verify path remains.
2. iOS: whether a Secure Enclave key can drive TLS 1.3 CertificateVerify
   through the chosen stack's opaque-signing hook, and the residual
   process-memory exposure.
3. ESP32-S3 entropy at first boot and at each handshake in ESP-IDF v6.1 (RF
   state, `bootloader_random_enable` semantics), and confirmation that the TLS
   signing path honours RFC 6979.
4. Confirmation that retiring `pdsh.identity.prove` plus deterministic ECDSA is
   sufficient key separation, versus a separate session key.
5. NimBLE CoC robustness against an adversarial pre-auth peer, including the
   over-credit dereference and every send return path, on hardware.
6. Ergonomics of the 5 s / 3 s gestures and indicator with real operators.
7. KeyUpdate, ticket, PSK/early-data and 0.5-RTT behaviour of both stacks as
   configured (matrix rows on real configurations).
8. A plan and evidence for the `production-hardened` profile (secure boot,
   flash encryption, secure download mode, eFuse) if the board is ever to
   resist a USB-attached host.

### 6.7 Evidence of the v2 freeze

| Command | Result |
| --- | --- |
| `python3 -B -m unittest test_ble_secure_session_golden` (in `spec/v1/tools`) | PASS (18 tests) |
| scratch mutation harness (21 mutations: 3 certificate relabels, 15 oracle edits reverting a v2 rule or weakening a check, 1 board fixture edit, 2 deleted vectors; fixture digests re-pinned) | 21/21 caught; unmutated copy PASS |
| `python3 -B spec/tools/registry_build.py --write` | PASS (regenerated; P07 authority text) |
| `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | phone-spec PASS (230 tests); phone-cross-tree PASS (8/8 invariants, registry byte-identical, 24 contracts / 423 references, schema diff 88 schemas, 0 breaking) |
| `python3 scripts/ci/protocol_impact.py --base 082aff5f --body-file <commit body>` | PASS (`P06; P07`, P09/P18 none with reasons; 2 triggered IDs, 35 changed paths) |

Fixtures were regenerated by a scratch generator (not committed) with fixture
keys derived from fixed labels and certificates built with Python
`cryptography` 48.0.0, which also cross-verified the accepted profiles; every
certificate decision is re-derived by the checker's own DER parser and P-256
verifier. `ble-secure-frames.jsonl` is byte-identical to v1; every other
fixture changed and is re-pinned. No private key is stored.

Not run: any Swift or C build or test (no implementation exists on either
branch), any TLS handshake, radio, device, Keychain/Secure Enclave, entropy or
power-loss test; `phone-hygiene` and `phone-license` (not in this revision's
gate list).

## 7. Revision `secure-session-v2.1` (implementer CCRs, integration)

### 7.1 Identification

```text
Contract:          P07 (owner); P06: none — no task model, journal or intent change
Base:              3505b690 (ws/ss-integrate = contract 5f6fd5d3 + Swift e3d37565 + firmware 8a63b3d4)
Trigger:           implementer reports at integration (AGENTS.md §3.3): CCR plaintext-admission
                   fixture vs §11.3; CCR mbedTLS 4.1 post-Finished alert; finding mbedTLS drops
                   oversize records without an alert; clarification of the v1_sha256 bytes
Current → expected: v2 frozen, both ends implemented as library + host tests, never run
                   against each other → v2.1 frozen with every item decided in the spec,
                   fixtures and checkers, both ends updated, and the real Swift end driven
                   against the real C end over an in-memory byte pipe
Version decision:  no wire, ALPN, key, record, enrollment or store format change. The v2.1
                   rules only decide what v2 left ambiguous; every v2-conformant sender is
                   v2.1-conformant (no conformant sender pads beyond 4353 inner bytes: the
                   phone does not pad, mbedTLS pads only up to its 4096-byte content limit).
                   The receive side is tightened, never loosened.
```

Protocol impact (this revision): P07 — owning spec, plaintext-admission schema
and golden, task-store and matrix goldens, both checkers, the two ends and
their tests. P06: none — task-delegation.md, the phone journal and secure
intents are untouched. P09: none — no UI or page contract. P12: none — no
native ABI, FFI or Package.swift change; mbedTLS stays a test-time source
pointed to by `PDSH_MBEDTLS_SRC`/`IDF_PATH`, never vendored. P18: none — no
UserDefaults key or settings file.

### 7.2 Decisions

| Item | Decision (normative text) | Fixtures / checker |
| --- | --- | --- |
| (a) CCR: `ble-task-plaintext-admission.jsonl` expected `identity_visible: true` for `app_caps` 3072 although §11.3 retires `pdsh.identity.prove` once the secure service is registered | Both firmware kinds are contract: every row gains `secure_service` and `identity_call` (`proof` / `unsupported` / `refused`). Without the secure service the legacy rule of ble-link.md is unchanged (visible and callable iff bit10+bit11); with it the tool is never listed and a call is `UNSUPPORTED` 14 with no receipt and no signature, for every capability set. "Carries the secure service" = registered at boot (§11.1). ble-link.md cites §11.3. | golden 5 → 10 rows; schema adds the two required members; `test_spec_golden.py` derives both columns and rejects a row without `secure_service` |
| (b) CCR: mbedTLS 4.1 protects its alert about the client flight with the server handshake keys after its Finished, so the phone sees `bad_record_mac`, not `bad_certificate`/`certificate_required` | The alert stays mandatory **for the board** (`certificate_required`, `bad_certificate`, `decrypt_error`, before any application data, then close). The **client-observable** outcome is only: the session fails closed before readiness (no `ready_ack` accepted, nothing sent after `ready_req`, a failed attempt); the phone may observe the alert, `bad_record_mac` or EOF. A matrix row's `alert` is the deciding end's alert (§6.1 "Client-observable outcome", §6.2, §13). No security property changes: the decision, its timing and the absence of application data are unchanged. | matrix stimuli of `tls-certificate-vectors`, `tls-negative-decision-aborts-handshake`, `tls-client-certificate-empty`; board loopback and cross-runtime `physical-unenrolled-phone` assert it |
| (c) finding: mbedTLS 4.1 drops oversize records without an alert; the board sent `record_overflow` itself for every `MBEDTLS_ERR_SSL_INVALID_RECORD` | **Restricted.** `record_overflow` iff, decided from the header before decryption: protected record (outer `application_data`) with `TLSCiphertext.length` > 4369 (= 4352 + 1 + 16; TLSInnerPlaintext ≤ 4353 including padding), or any other record > 4352. A ≤ 4369 protected record is never overflow whatever its padding. Every other invalid record fails closed with the RFC 9846 alert where identifiable (`bad_record_mac`, `unexpected_message`, `decode_error`), never `record_overflow`, never followed by close_notify. | new matrix row `tls-record-invalid-not-overflow` (both ends); `tls-record-overflow` stimulus states the 4369/4370 boundary and the unprotected case; checker `REQUIRED_MATRIX` |
| (d) clarification: `v1_sha256` bytes | SHA-256 of the `tasks_v1` JSON text, i.e. the NVS blob without its single terminating NUL; a blob that is not text + one NUL is unreadable. `tasks_v2` and `rec_v1` use the same storage form. | store case `v1-digest-over-terminator` (digest including the NUL → `disabled`); checker asserts the case and the digest it carries |

### 7.3 Changes per end (made in this revision's branch)

Board (`firmware/esp32-reference/main/pdsh_secure_session.c`):
1. Record limit decided from each header as bytes pass to mbedTLS (`track_records`): `record_overflow` exactly per (c), for the ClientHello gate too (was `decode_error` above 16384). Before, an over-limit protected record whose length exceeded mbedTLS's input payload got `BAD_INPUT_DATA` (no alert, then close_notify), and an unknown record type or an inner plaintext without content type got `record_overflow`.
2. Post-handshake fatal read errors no longer send close_notify after the failure: KeyUpdate and any other unexpected post-handshake message → `unexpected_message` (before: close_notify only, contrary to §6.1 "alert if the stack can"); invalid record within the limit → `decode_error`; authentication failure → `bad_record_mac` (sent by mbedTLS with `MBEDTLS_SSL_ALL_ALERT_MESSAGES`, else by the board); peer alert → no answer.

Phone (`Sources/PhoneDSHBLE/SecureSession/BLESecureTLSCore.swift`): the protected-record receive limit is 4369 (was 4352 + 256 = 4608, so a 4370–4608 record reached decryption and surfaced as `bad_record_mac` instead of `record_overflow`). Test-build hooks only (`#if DEBUG`): `TLSRecordKeys.sealForTesting`, `BLESecureTLSClient.writeProtectedRecordForTesting`.

Tests and tooling: `firmware/tests/test_link_tools.c` consumes both admission columns; `test_secure_task_store.c` expects 20 store vectors; `run.sh` builds the cross-runtime bridge and runs on Darwin (no GNU `--wrap` there: the §5 heap budget is reported `NOT_RUN` on Darwin and measured on Linux); new `firmware/tests/test_secure_bridge.c` and `Tests/PhoneDSHBLETests/BLESecureCrossRuntimeTests.swift`; `BLESecureTLSTests.testRecordLimitIsDecidedFromTheHeader` (phone end of (c)).

### 7.4 Cross-runtime conformance

`BLESecureCrossRuntimeTests` launches `.build/link-host/secure-bridge` (built
by `firmware/tests/run.sh`): the board's own `pdsh_identity`, `pdsh_enroll`,
`pdsh_secure_cert`, `pdsh_secure_msg`, `pdsh_secure_session` (including the §5
CoC receive path with credit flow from an honest L2CAP sender, MTU 512, MPS
247, 3 K-frame buffers) and `pdsh_task_store`, linked with mbedTLS 4.1.0 at
espressif/mbedtls `a2b32072ea898afc1ed5b6caf6931e36028c91d6` (the
`components/mbedtls/mbedtls` gitlink of ESP-IDF v6.1 `fff9895c`; tree
`4558786a`, identical to galic's `/opt/esp-idf` checkout). Only the radio, the
NVS flash and the clocks are substituted. The Swift side is the real
enrollment ceremony, certificate builder/verifier, TLS 1.3 client, framing,
codec and `BLESecurePhoneGeneration`. `PDSH_SECURE_BRIDGE=<binary>` runs a
prebuilt (mutated) board for mutation evidence.

| Case | Board observed | Phone observed | Matrix rows covered cross-runtime |
| --- | --- | --- | --- |
| offline enrollment → handshake → ready → next/accept/keepalive×3/complete/duplicate → idle close → renewal under the grant → lifetime | console `armed`/`begun`/`staged`/`press`/`committed`; store `completed`, `by` = phone ID; idle `err timeout` at 90 s; lifetime close_notify only | `.ready`, `.taskOffered`, `.applied`; grant `.active` across sessions; 0 failed attempts | host layer of `physical-enroll-and-task-round-trip`, `physical-long-task-across-session-renewal` (time simulated), `tls-no-half-rtt-data`, `tls-no-ticket-sent`, `tls-record-sender-cap` (phone accepted every board record) |
| board reboot between accept and complete | store kept `accepted` | `status` → `status_resend` → `applied` once | host layer of `physical-board-reboot-recovery` |
| two enrolled boards, A selected, B answers (M1) | B never reaches the application layer; task untouched | `pin_mismatch` in the handshake, 1 failed attempt; A still served | `physical-two-enrolled-boards-swap`, `tls-negative-decision-aborts-handshake` (phone end) |
| unenrolled phone key (committed locally only) | reason `pin_mismatch` after its Finished; store untouched | no readiness, 1 failed attempt, grant refused; raw client sees `bad_record_mac` (v2.1 (b)) | `physical-unenrolled-phone`, `tls-negative-decision-aborts-handshake` (board end) |
| KeyUpdate from the phone after readiness | alert 10, closed | receives alert 10 | `tls-key-update-received` (board end; was NOT_RUN on the board) |
| padded record of 4369 / 4370 bytes; 4353 bytes of content | 4369 served (`status_r`); 4370 and 4353-content → alert 22 | receives alert 22 | `tls-record-overflow` (board end) |
| bad tag; unknown outer type; inner plaintext without type | alerts 20, 50, 50; never 22 | receives the alert | `tls-record-invalid-not-overflow` (board end) |
| request before ready; skipped and replayed seq; second `ready_req`; stale `sc`; wrong eid | `not_ready`, `bad_sequence` ×3, `bad_challenge`, `record_mismatch`, each closes; store unchanged | receives each `err`, then close_notify | device-side sequence rules §8.3 over live TLS |
| lost accept, intervening `next`, resend; lost complete response | `queued` until the authorized resend; outcome never changed by a conflicting complete | `status_resend` voided by `next` (`refused_requery`), then `applied`; `status_applied` without resend; conflicting complete `unresolved` | `phone-resend-not-next-request` behaviour (§9.3) live |

Interop bugs found by this test and fixed: board KeyUpdate handling (close_notify instead of `unexpected_message`), board record-limit classification (§7.3 board 1–2), phone receive limit (§7.3 phone); harness-only issue: `run.sh` failed on Darwin since 8a63b3d4 (GNU `--wrap`), which also broke the existing `BLETaskCrossRuntimeTests` on macOS.

### 7.5 Evidence (head `3a4deeb9`)

```text
Base / head:        3505b690 / 3a4deeb9 (contract revision commit 8762d192, implementation 3a4deeb9)
Protocol impact:    P07; P06/P09/P12/P18: none (reasons in the commit bodies)
Contract revision:  spec/device/v1/ble-secure-session.md@secure-session-v2.1 (8762d192)
Changed files:      contract: spec/device/v1/{ble-secure-session.md,ble-link.md}, plaintext-admission
                    schema+golden, task-store and matrix goldens, spec/v1/tools checkers,
                    spec/README.md, spec/registry.json, this record;
                    board: pdsh_secure_session.c; tests: run.sh, test_link_tools.c,
                    test_secure_task_store.c, test_secure_session.c, test_secure_bridge.c (new);
                    phone: BLESecureTLSCore.swift, BLESecureTLSClient.swift (DEBUG hook);
                    tests: BLESecureTLSTests.swift, BLESecureCrossRuntimeTests.swift (new)
Status per end:     board implemented (library + host); phone implemented (library; no product
                    path, BLE grants still refused); physical acceptance not started
```

| Command | Result |
| --- | --- |
| `IDF_PATH=/opt/esp-idf bash firmware/tests/run.sh` on galic (Linux, ESP-IDF v6.1 `fff9895c`) | PASS — admission 10, task store v2 20, enrollment, identifiers/certificates/frames/messages/sequences, TLS loopback 33 cases, CoC, prove retired, heap 31653 ≤ 32768 bytes |
| `idf.py set-target esp32s3 && idf.py build` on galic | PASS (`pdsh_ble_reference.bin` 0xc2950) |
| `PDSH_MBEDTLS_SRC=<mbedtls a2b32072> bash firmware/tests/run.sh` on macOS | PASS; heap budget `NOT_RUN` on Darwin (no GNU `--wrap`) |
| `swift test --filter BLESecure` | PASS (36 BLE + 6 DeviceTasks tests) |
| `swift test --filter BLESecureCrossRuntimeTests` | PASS (8 tests; table §7.4) |
| `swift test --filter PhoneDSHBLETests` | PASS (140 tests, 0 skipped; includes `BLETaskCrossRuntimeTests`) |
| `swift test --filter PhoneDSHDeviceTasksTests` | PASS (59 tests) |
| `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-license` | PASS (registry byte-identical; 88 schemas, 0 breaking) |
| `python3 scripts/ci/protocol_impact.py --base 3505b690 --body-file <3a4deeb9 body>` | PASS (P07 triggered, 21 paths) |
| mutation: cross-runtime test against the board of `3505b690` (`PDSH_SECURE_BRIDGE`) | FAIL as intended: KeyUpdate (close_notify, no alert), record rows (padded 4370 stalls the board, bad tag closes without alert, unknown type and missing inner type answered `record_overflow`) |
| mutation: phone limit back to 4608 | `testRecordLimitIsDecidedFromTheHeader` FAIL as intended (bad_record_mac) |
| mutation: checkers (secure admission row visible; secure rows deleted; matrix row deleted and re-pinned; terminator case with NUL-free digest and re-pinned) | 4/4 caught; unmutated PASS |

Not verified: any radio, NimBLE, real CoC credits, device, iPhone, Secure
Enclave, entropy, power loss or physical gesture (§14 unchanged); the board's
behaviour with `MBEDTLS_SSL_ALL_ALERT_MESSAGES` disabled; the matrix rows not
named in §7.4 at the cross-runtime layer (they keep their per-end host /
loopback results); KeyUpdate sent by the board (mbedTLS 4.1 cannot send one;
phone end covered against OpenSSL). Remaining risks stay under GAP-16 and §6.6.

