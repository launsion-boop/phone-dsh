# Freeze iOS standard GATT grant ordering and quarantine

```yaml
change: PC-20261107-standard-gatt-grant-order
contracts: [P07, P09]
status: frozen
breaking: true
version_decision: Preserve the existing local grant signatures and wire formats; tighten local admission, cancellation and connection lifecycle.
base: ef6afede85c0580bca75ccb2b3b6e97caa78a955
contract_revision: spec/device/v1/ble-link.md@standard-gatt-grant-v1
```

Protocol impact: P07; P09; P05: none — the existing MCP request and result
envelopes are unchanged although the timing of an observable denial changes;
P18: none — alert intents and durable records keep
their existing representation and no-repeat behavior. GAP-29 reproduces a
later local revocation overwritten by an older `grant`. The owning contract
now fixes local field ordering, immediate revocation admission, captured
pending-read outcome and continuation ownership, and conservative
disconnect quarantine. It retains the existing nil/same-value/alert-only
pending-read side effect. The 47 shared positive and negative scenarios fix
real Observation, cancellation races, Link dispatch, resource ownership and
adapter-side-effect expectations; the canonical fixture digest is
`f24755201a5ce6375e7b7baf2f2cf0146c24b3ba452c3fdd568b679ef888f40e`.

Old callers retain their method signatures. A new implementation clears old
grants when a new connect is accepted, rejects operations while a connection
is closing or cannot be attributed, and exposes that unavailable state on the
Bluetooth page; older callers may therefore observe a denial where the old
implementation let an unsafe operation proceed. With a new caller and old
binary, method calls still work but the old ordering and quarantine defects
remain; do not claim equivalent protection. No wire or disk format changes,
and rollback preserves existing data but restores the old behavior. The
firmware Link wire and receipts remain unchanged. Android has no production
standard GATT endpoint and remains target; this amendment does not enable it.
The existing alert intent, same-key outcome-unknown and no-repeat policy is not
changed or replaced with a new receipt API.

The coordinator owns `spec/**`, registry and this record. The Swift store
implementer owns `Sources/PhoneDSHBLE/BLEDeviceStore.swift` and, only where
needed to exercise the existing real channel dispatch,
`Sources/PhoneDSHBLE/BLELinkChannel.swift`. A separate Swift test implementer
owns `Tests/PhoneDSHBLETests/StandardGattGrantOrderingTests.swift`; the store
and test implementers coordinate the internal adapter interface. The UI
implementer owns `examples/probe-app/PhoneDSHProbe/BluetoothDevicesPage.swift`
and affected `examples/probe-app/PhoneDSHSimTests/**` only. A test adapter is
internal and debug-only, can supply simulated physical peripheral and
characteristic identity, state and received bytes, replace physical side
effects, and feed the same production callback and real channel receive
transitions. It cannot directly grant permission or fabricate an OS request
token. The normal `shared` initializer always uses CoreBluetooth;
release build must not expose or depend on that adapter. Tests use the real
store, observation, admission, outcome claim, continuation and Link reassembly;
they do not substitute a hand-written state machine. Test callbacks cannot
claim that a synthetic owner was supplied by CoreBluetooth.

Acceptance: shared 47-case runtime tests and mutations of critical expected
fields against the real store; `swift test --filter
'StandardGattGrantOrderingTests|StandardBLETests|BLEDeviceMCPTests|PDSHLinkTests'`;
release build of `PhoneDSHBLE`; iOS Bluetooth-page build and real page tests
that render closing and quarantine, check disabled actions and observe the
transition after the permitted boundary;
`PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest
test_spec_golden.StandardGattGrantOrderingFixtureTests`; and `bash
scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Report all failures and skips separately. A source-level or injected-callback
test is not real CoreBluetooth or GATT evidence. Full GAP-29 closure needs
iPhone and controlled peripherals implementing the standard services, with
read, cancellation, notification, disconnect and reconnect scenarios; the
reference ESP32's Link-only services are not that evidence. GAP-16, Android
device capability, identity recovery and P0 remain independently open.
