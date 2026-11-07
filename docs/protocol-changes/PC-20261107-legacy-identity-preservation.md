# Freeze preservation of visible legacy identity preferences

```yaml
change: PC-20261107-legacy-identity-preservation
contracts: [P07, P09, P18]
status: frozen
breaking: true
version_decision: Preserve the draft void insertion API and add a result-bearing local operation for the probe; no wire or on-disk format change.
base: 603e4e64a28ddb5e7d2d4add517d2e10c4d190b7
contract_revision: spec/device/v1/legacy-identity-preferences.md@legacy-pref-v2
```

Protocol impact: P07; P09; P18. The current `stringArray(forKey:) ?? []`
conflates a visibly wrong-type old value with absence; insertion can replace
the old value and the probe may say it recorded an identity. Preserve the
visible old value and return failure to the probe instead, as the owning
document and shared fixtures specify. Keep the existing public void `insert`
signature, delegating to a new result-bearing `insertIfVisibleValid` operation;
the probe must use and check the latter. Existing source and symbol signatures
remain, but old callers do not receive an error and the tightened write behavior
is observable. Do not claim cross-version binary compatibility without a build.

No network, device or journal format changes. Old readers on valid arrays see
the same values. New readers preserve wrong-type values and do not enable the
old identity; old writers after rollback can still overwrite them. Valid old
labels stay in their original namespace and cannot authenticate a UUID or old
receipt. UserDefaults absence can also reflect lower-level unreadability;
cross-process writers and crash durability remain outside this amendment.

Coordinator owns `spec/**`, registry and this record. The Swift implementer
owns `Sources/PhoneDSHBLE/{BLEIdentity,BLEDeviceStore}.swift` and
`Tests/PhoneDSHBLETests/**`; no firmware, Android or Worker format changes.
Use real isolated UserDefaults suites and shared valid/invalid cases, test
same-process concurrent inserts and the probe failure path without reading or
modifying user preferences. Include a property-list Data wrong-type case and a
controlled UserDefaults spy for no-write on duplicate/wrong-type, and for a
set that is not observable on readback; the spy is not proof of real storage
failure. The membership query, compatibility wrapper and result operation use
the same reentrancy-safe process lock; exercise synchronous reentry during a
read, write and readback, including the old void wrapper without a nested
write. Verify retained spelling and order using Unicode scalar sequences, not
Swift's canonical-equivalent `String` array equality. Remove any unrelated test write to
`UserDefaults.standard` by using an isolated suite for the same assertion.
Verify public call-site compatibility and no
task grant on either success or failure. Acceptance: `swift test --filter
BLEIdentityTests`, affected BLE tests, `python3 -m unittest
spec.tools.test_legacy_identity_preferences_schema`, and `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree`. Report disk-constrained or
device checks as NOT_RUN; this does not solve identity binding, authenticated
sessions, GAP-16, GAP-24 or legacy task recovery.

Revision v2: implementer CCR noted that a plain lock deadlocks synchronous
reentry while a recursive lock alone can allow a nested read-modify-write to
be overwritten by the outer write. Same-thread nested API calls now fail
closed without accessing defaults; a separate shared fixture covers refusal
and explicit retry. Other threads remain serialized. This is not cross-process
isolation and does not make UserDefaults durable. The fixture schema admits
only the JSON property-list subset needed by these cases; this does not narrow
which pre-existing values the production store must preserve. Its negative
tests use the repository's existing schema validator without a new dependency.
