# Freeze observable legacy identity confirmation

```yaml
change: PC-20261107-identity-observable-confirmation
contracts: [P07, P09, P18]
status: frozen
breaking: true
version_decision: Preserve the legacy defaults key, array and public APIs; tighten local confirmation ordering and present failures per device. No wire or durable format change.
base: d99d4c99365fefaf6eac5b87534932fbf5185e83
contract_revision: spec/device/v1/legacy-identity-preferences.md@observable-confirmation-v1
```

Protocol impact: P07; P09; P18. The visible-value storage subset of
`PC-20261107-legacy-identity-preservation` is implemented, but the actual store
ignores its result and an older confirmation or proof can overwrite newer
connection state through synchronous Observation or UserDefaults reentry.
The owning amendment and shared confirmation/observation vectors freeze the
local ordering and a guarded write-submission boundary. The safety decision
is per-device: a distinct identity revision and accepted attempt, captured
owner/channel/client and exact pending scalars must still match at publication.
Clearing or installing a channel or client invalidates old markers, even for
the same object. Lifecycle events and revocation cannot be discarded.

Guarded insertion and public insertion use the same lock and visible-value,
canonical-equivalence and exact-scalar readback rules. A stale state detected
after the initial read and immediately before `set` causes no write. Once
`set` has been entered, a callback can invalidate the state before the
underlying write; the write may happen and must not be rolled back. Nested
same-thread storage access is refused by the existing lock rule and does not
start an attempt or publish an additional identity result; it may be retried
explicitly. A valid new attempt during an Observation callback, after the
storage operation has returned, supersedes the old one. Checks are local and
cannot claim cross-process transactions, hidden-domain preservation, durable
flush or radio/session authentication. This change does not add any wire
message, field, version, on-disk representation, capability or retry.

Failure and precondition feedback moves from global status to the relevant
existing device's identity error, conditional on the same state after
Observation's synchronous notification. Missing device becomes a no-op. On
success the label is a historical UI marker only; it never grants tasks. A
failed write leaves pending for explicit retry. On either result, stale
operations publish nothing. Unrelated global Bluetooth status ordering and
scan-side-effect reentry are outside this change and remain source-review
risks; they must not be declared fixed by this local result. The dormant proof
completion uses the same ownership checks and does not access a target RPC in
tests or application discovery.

Compatibility: old callers and old valid arrays remain readable; old binaries
continue to lack these guards, and rollback may overwrite invalid old values.
New callers with old code retain signatures but not the new safety behavior.
New code with old data preserves visible wrong-type values and string spelling,
and never migrates UUID labels into public-key identities. New-to-new uses the
same public methods and tighter local UI result. Neither rollback nor a local
readback authenticates historical traffic. Android has no production BLE
identity endpoint; firmware and Worker formats are unchanged. PDSH device
identity/task proof and authenticated sessions remain target and disabled.

The coordinator owns `spec/**` and this record. The storage implementer owns
`Sources/PhoneDSHBLE/BLEIdentity.swift`; the store implementer owns
`Sources/PhoneDSHBLE/BLEDeviceStore.swift` and the Bluetooth-page owner owns
`examples/probe-app/PhoneDSHProbe/BluetoothDevicesPage.swift` plus its page
test. The separate test implementer owns
`Tests/PhoneDSHBLETests/LegacyIdentityObservationTests.swift`; implementers
coordinate internal debug-only physical and preference hooks, never replacing
`.standard` on the shared production store. Tests use the real confirmation,
real storage core and store state transitions, isolated actual UserDefaults
suites and controlled synchronous callbacks. Controlled failure injection is
not evidence that Foundation naturally produced that failure. Local proof
completion may be injected only after the proof-result boundary, with no
identity RPC or external side effects; it is not proof of signature validity
or real BLE behavior. Shared fixtures retain the previous 11 confirmation
cases and add 40 observation cases; compare all strings and array elements by
Unicode scalar sequence. A one-shot hook has a separate bounded count of
Observation callbacks; the result category is inferred from real state and
side effects, never a fake state-machine return. Each case checks both device
errors, global status, preference reads/sets, actual stored value, lifecycle
events and absence of task grants. Synthetic NFC/NFD labels test only local
ordering; syntactically valid fingerprint cases do not claim peer proof.
The canonical SHA-256 of the new fixture is
`e096eb49ca0a81fb7abfd3f3ef6df37cbcae89e18f0b7f8a5cec88bec1c02978`.

Acceptance: all shared cases and invalid mutations through the real store and
storage core; the existing visible-value/reentry vectors with real isolated
suites; synchronous lifecycle, different-device, scalar ABA and nested
confirmation during read/set/readback and Observation; old-marker admission
during channel/client installation's will-change notification rejected before
any write; failure UI rendered with the actual applicable build condition;
no target wire or task grant;
`swift test -j 2 --filter 'LegacyIdentityObservationTests|BLETrustedIdentitiesTests|BLEIdentityTests|StandardGattGrantOrderingTests|BLEDeviceMCPTests|PDSHLinkTests'`;
`swift build -c release --target PhoneDSHBLE -j 2`;
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest spec.tools.test_legacy_identity_preferences_schema`;
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
A simulator or injected callback does not establish real-device, restart,
crash, external-process, key-binding or authenticated session behavior.
GAP-28 remains partial until its actual local boundaries are verified and its
remaining durability and physical scope is separately stated. GAP-16 remains
open regardless of this local fix.
