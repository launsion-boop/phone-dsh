# Freeze reference-firmware plaintext task admission

```yaml
change: PC-20261107-plaintext-task-admission
contracts: [P07]
status: frozen
breaking: true
version_decision: Interim reference-firmware admission restriction; no new wire version or secure capability. Authenticated task profile remains target.
base: a5ae7f9fa0e562792ce7bedad19d8e7ce2d8ff7a
contract_revision: spec/device/v1/ble-link.md@sha256:b0e9be0cea78557bb2d2a2cd35a6c43674e307e408a9252f3862531140d7c75a
```

## Trigger and delta

Protocol impact: P07. A bonded peer declaring `PDSH_TASKS` can currently
discover and invoke the reference firmware's plaintext task tools even though
the independent identity proof cannot protect later commands. The iOS
adapter already refuses task grants. Both discovery and actual firmware
dispatch must now deny new plaintext task requests, while retaining the
ordinary Link profile and separately negotiated identity proof. The latter is
only proof of key possession and can be relayed. Locally queued tasks and all
old records are preserved; local submission does not mean delivery.

For a unique new UUID, valid task request, healthy store and idle dispatcher,
the four task tools return the existing Link `UNSUPPORTED` (14) and produce no
new receipt, job or task-store change. Existing UUID lookup is handled before
the request name is known; its ordinary legacy receipt behavior is unchanged.
An old receipt has no reliable tool type, so this restriction does not
authenticate it or promise task-result confidentiality. Reset and reconnect
never grant task admission. The ordinary Link message, result, timeout,
idempotency, cancellation and recovery rules are otherwise unchanged.

The interim contract is the owning `ble-link.md` SHA above and
`task-delegation.md@sha256:ea318408aad3f923b707d58f3beb0ffa3a914f33cb8c34f0ce9898f96f27dd3b`.
Shared `golden/ble-task-plaintext-admission.jsonl@sha256:1109e9f64212a729147b1c0fb450f3edfc02dc0f6b31cb00752617a634965a18`
and `schema/ble-task-plaintext-admission.schema.json@sha256:63651df77f96213a918d8f0da00c8d4d506218770a1c42aa23ee4c38beb7c1fe`
assume the identity service is healthy and describe negotiated capability
cases, including unknown bits. Tests must drive actual ordinary Link upload,
COMMIT, tools/list and RESULT, not just the bit predicate. The existing target
task-core vectors are retained and remain target tests, not release-admission
evidence.

## Compatibility and implementation ownership

Old phone → new firmware: ordinary tools stay available; a phone declaring
tasks sees no task tools, and manual new plaintext requests are denied. New
phone → old firmware: iOS independently denies task grants; an unrelated old
client may still invoke old firmware, which cannot be fixed remotely. New →
new has the same fail-closed admission until a separately frozen authenticated
session exists. Old task and ordinary receipt bytes remain untouched; rollback
restores the old unsafe admission, not authenticated recovery. No version or
capability bit is reassigned, and no automatic replay is authorized.

The coordinator owns `spec/**` and this record. The firmware implementer owns
`firmware/esp32-reference/main/link_tools.c` and firmware host tests only. A
test-only target-core entry point may exercise the already existing target
positive cases, but must not be present in release builds or callable by the
ordinary ingress. It is not an authenticated session. Real ingress tests must
cover all shared capability rows, manually uploaded valid requests for each
task method, omission from tools/list, no task/receipt mutation, ordinary
tools and prior-result recovery, identity-proof discovery and dispatch using a
controlled stub, reset/reconnect, and unchanged locally queued tasks. Test
stubs do not prove cryptographic identity or radio behavior.

Acceptance: `bash firmware/tests/run.sh` with the locked cJSON component;
`swift test --filter 'PDSHLinkTests|BLETaskCrossRuntimeTests'`; and
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Record every failure, skip and target-only test. Review release symbols and
build the actual ESP-IDF target; physical iPhone/ESP32 positive and negative
task-session tests remain separate requirements. This change does not close
GAP-16, solve Android discovery or complete the user's goal.
