# iOS GATT discovery ownership and ambiguity

```yaml
change: PC-20261107-gatt-discovery-ownership
contracts: [P07, P09]
status: frozen
breaking: true
version_decision: Preserve BLE wire and public grant APIs; tighten local discovery, ambiguity and timeout behavior.
base: 665d1dd166451b51916c3f333e55b5457811381f
contract_revision: spec/device/v1/ble-link.md@discovery-ownership-v1
```

Protocol impact: P07; P09; P18: none — existing intent and legacy preference
formats do not change. The current store does not keep discovery-request
ownership, can publish a standard profile before another same-UUID service has
reported its conflicting candidate, and can replace Link endpoint maps before
validating a second or partial result. It may also stop the discovery timer
based on cached characteristics rather than callbacks received for this owner.
GAP-31 and its discovery CCR describe the evidence and remaining scope.

The owning clauses are `spec/device/v1/ble-link.md` under iOS discovery
ownership and ambiguity, with the existing closing, read-claim and service
change clauses. The producer is CoreBluetooth's existing callbacks; the Swift
store consumes them and the Bluetooth page observes the store. The reference
firmware uses the unchanged Link format; Android device support remains target.
No Worker, Rust, Kotlin, firmware, wire encoding, field, error code, capability,
authentication or task behavior is added or migrated by this local change.

The delta changes request and object ownership, candidate publication and
ambiguity handling. A matching nil successful callback leaves its request
pending under the existing connection deadline; a non-nil empty result completes
locally. Matching errors close the current connected owner. Unknown, changed or
unrequested results quarantine the current owner; exact completed multiset
repeats are inert only while powered on and attributable. Multiple physical
Link services disable Link for that owner; ambiguous standard characteristics
disable only the affected profile, and another completed service UUID group
may remain usable. No implicit grant is created. Existing read first-winner,
no-replay and disconnect boundaries remain in force. The 20-second deadline is
not restarted by a callback; rediscovery requires a new explicit connection.

An object-reference ledger records local facts only. CoreBluetooth exposes no
application request token here: indistinguishable same-object callbacks from an
old attempt cannot be proven fresh, and a locally complete snapshot cannot prove
remote database completeness. [Apple's discovery callback documentation](https://developer.apple.com/documentation/corebluetooth/cbperipheraldelegate/peripheral(_:diddiscoverservices:))
and [characteristic discovery callback documentation](https://developer.apple.com/documentation/corebluetooth/cbperipheraldelegate/peripheral(_:diddiscovercharacteristicsfor:error:))
do not grant such a token. The power check is also local, not atomic with a
radio state change. A dynamic or unusual peripheral may now lose access or
require explicit reconnection; this is a conservative compatibility change.
Actual callback ordering and radio behavior require separate device evidence.

| Producer → consumer | Compatibility decision |
| --- | --- |
| Old peripheral → new app | Same wire and discoverable UUIDs. Unique correctly parented results retain the existing features; multiple or unassignable local objects now fail closed. An old peripheral need not be updated, but some devices may need reconnection or lose ambiguous profiles. |
| New peripheral → old app | Same wire; an old app may still select or overwrite ambiguous endpoints. No new behavior is assumed from it. |
| New peripheral → new app | Same encoding, limits and grant APIs; locally validated unique objects can be used, and ambiguity follows the frozen local failure policy. Neither end gains authenticated tasks. |
| Persisted old data → new / rollback | There is no new persisted representation or migration. Existing legacy preferences and grants retain their separate semantics. Rollback reads the same data but restores the old discovery-attribution weakness. |

There is no version or deployment ordering change: no on-wire version or
adapter is introduced. Existing installations must update the iOS code to get
this local behavior; rollback has the stated safety limitation. A target device
RPC and Android implementation stay target and must not be called by tests.

The coordinator owns `spec/**` and this change record. The Swift implementer
owns `Sources/PhoneDSHBLE/BLEDeviceStore.swift` and, only if needed for a
DEBUG-only physical endpoint seam, `Sources/PhoneDSHBLE/BLELinkChannel.swift`.
The separate runtime test implementer owns
`Tests/PhoneDSHBLETests/StandardGattDiscoveryOwnershipTests.swift`. If UI work
is needed a separate implementer may edit only the test-only
`examples/probe-app/identity-ui-harness/{Host,IdentityUITests}.swift`. The
integrator reviews all ends and tests at one head. The adapter may substitute
physical object references, properties, event delivery and command submission,
but may not fabricate an OS token, set real store ownership, grants, endpoint
maps or outcomes directly, or replace the real Link client/channel continuation.
Objects remain strongly held for the entire case. Historic preference tests use
only isolated storage, and task grants remain disabled.

Production delegates must acquire service parent/reference/UUID/primary and
characteristic parent/reference/UUID/properties snapshots from real
CoreBluetooth objects, and call the same event dispatchers used by the DEBUG
physical-object substitute. The substitute must preserve object identity,
array multiplicity and callback order; fake labels are not OS callback tokens.
New discovery vectors must first go through the actual connection submission
and connected state machine. Existing lifecycle tests' `testDiscover` and
`testPrepareLink` helpers directly establish later state and may remain solely
for those earlier tests; using them for new discovery-vector setup would not
verify discovery ownership. A real store-owned Link channel and client must be
exercised through their actual pending continuation, with only physical I/O
substituted; a separate fake Link transport does not satisfy this requirement.

The 66 shared cases are in `spec/device/v1/golden/standard-gatt-discovery-ownership.jsonl`, with their schema in `spec/device/v1/schema/standard-gatt-discovery-ownership.schema.json` and six malformed / ten semantic mutations in `spec/device/v1/golden/standard-gatt-discovery-mutations.json`. The SHA-256 of the JSONL bytes is `71e4f17e2a9b1abd2832447d56dddd3a894bbbb7a93d50fb12e5be32b0302451`. Shape validation alone is not runtime evidence: each semantic mutation must be rejected by the same comparator applied to actual production state and submissions. All cases have to execute; synthetic input is not evidence that an OS emitted it.

## Real-store setup

For each row use a fresh store, real isolated UserDefaults suite and two
independent peripherals represented by the strongly retained fake object graph.
Construct each listed service/characteristic as a physical test double with
its **actual reference identity**, UUID, parent reference, properties and
primary status. Never write expected selections, channel, owner, timer,
continuation, permissions, profile or result directly into the store.

1. Establish B through the real connect/didConnect and discovery submission /
   shared callback paths using `Bbat`, `Balert`, `Blink`, `BbatValue`,
   `BalertValue`, `Brx`, `Btx`, `Baudio`. Establish the actual channel, invoke
   real grants to enable B read and alert, and verify both real admission and
   a physical alert submission; retain B's actual owner, channel, client,
   identity and declaration baseline. B is an ordinary unrelated local peer.
2. Begin A's real connect attempt. Capture the actual discovery deadline and
   its scheduling/generation identity **at the original connect attempt**,
   before `didConnect`; do not start a fresh clock at service discovery. Drive
   actual A `didConnect`, which submits the original service discovery once.
   Stop before its result, establish A's public grant flags false, no Link
   channel, and no published profiles. Install real observation tracking.
3. Save the actual isolated preference value/scalars, B state and per-device
   physical submission, Link delivery and continuation baselines. Reset or
   subtract these setup counts. Every expected count in a step is cumulative
   **since this baseline**, including all nested callbacks. Thus
   `service_requests: 0` means no *additional* service request after the one
   already submitted by real setup. Run all B checks against actual store
   authority and public fields, not an injected `peer_b` result.

The fake can provide actual physical service/characteristic objects, error
values and send/receive bytes, and can record physical API calls. Real and
fake delegates must call one production discovery reducer after extracting
objects. The reducer, owner/peer admission, ledger, channel, notifications,
read claim/continuation, timer and UI mutations remain production code. Do not
supply an artificial app epoch as the CoreBluetooth source of a callback.

## Step and checkpoint semantics

`services` and `characteristics` physically deliver the listed callback for
`peer`/`service` with `error` and `items`; `null` and `[]` are distinct. An
array may repeat the same name, preserving its actual reference multiplicity.
Object properties are the callback-time physical fields. `physical_properties`,
`physical_primary`, and `physical_uuid` mutate only the fake physical object
before a later real callback; they do not mutate the store or its previously
captured immutable snapshot. `set_powered` changes only fake physical power,
not the manager callback or store owner state. `service_change` enters the
same production dispatcher as `didModifyServices`. Grant/read/value/cancel
steps call the real public grant/read, real value dispatcher and actual
continuation; background cancellation is waited until its real claim occurs.
`fire_discovery_timeout` invokes the originally captured connection-attempt
probe and the same production timeout handler, not an artificial timeout
state. All payload `[37]` read successes are checked for the full `37 % @ `
value and a valid in-window ISO timestamp; `draft.read`/731 checks the exact
NSError domain and code. Verify each continuation completes exactly once.

`expect` is the state at the end of the entire named input and all synchronous
nested work. Cumulative physical counts include nested work. `phase` is actual
owner phase and `device_state` is the public `Device.state`; `profiles` are
actual published profiles, additionally checked through real admission.
`link=active` requires the actual installed channel and selected RX/TX/audio
physical object identities and exactly the listed TX/audio notify submissions;
it does not claim successful authentication. `link=ambiguous/incomplete`
checks no new Link channel or Link notify and the exact `link_text`.
`link=absent` checks no Link channel/notifications. When `link_text` is present,
it is compared exactly, including `本次未发现 Link` after a completed no-Link
services result. `grants_a` checks actual declarations and visible Device fields;
discovery must not grant. Capability availability, a grant declaration, and an
already busy operation are distinct states. Where an admission snapshot is
needed, use a side-effect-free observation of the same production admission
predicates, not a reimplemented fake predicate. Invoke public read or alert
only at explicit fixture actions and include all resulting physical submissions
in their counts; the B alert positive control occurs during setup before
counters are baselined. Never call a target task operation; checking its disabled
declaration is not evidence that a target admission or task RPC was executed.
Where a read is in flight, the read timer is separate from `timer`, which
always denotes the original **connection/discovery deadline**. A `cancelled`
deadline must be a previously captured real deadline proven active, then
actually cancelled; `same` additionally requires the original scheduling
token and deadline to remain unchanged. Avoid sleeps as proof of deadline
identity. `peer_b=unchanged` checks B's owner/physical references, phase,
actual read/alert/tool declarations and side-effect-free admission, identity, channel/client,
profiles, visible fields, and unchanged independent timer; `alert-revoked`
changes only B's real alert declaration; `quarantined` checks all-owner
manager-unavailable cleanup. `pending` names the real local read state/result;
`read_completions` and `read_submissions` count all real attempts since setup.
All historical preference strings are compared by exact Unicode scalar order.

An `inject` runs exactly once **inside** its stated synchronous point:
`before_characteristic_reservation` runs before reservation and physical entry;
`after_characteristic_submit` runs only after the actual matching side-effect
entry has been recorded; `devices_will_change` is a real
`withObservationTracking` notification; `after_read_value_claim` runs after
the actual value/error wins the shared claim but before continuation finish.
If an inject has an `expect`, compare it immediately after the nested event
returns while still inside that outer stack, before the outer step resumes.
`devices_notifications_delta` and `status_notifications_delta` are changes
between entry and return of **that exact callback event**, excluding any
already underway enclosing notification. Re-arm fresh tracking as needed,
count nested notifications and set a finite recursion bound; do not conflate
top-level cumulative submission counters with these notification deltas.
The owner has specified that when the final selected request completes, the
original deadline is cancelled before publishing the completion's result or
entering its will-change observers; the reentrant last-result checkpoint
therefore expects `cancelled` exactly.

At least one active Link positive control must complete real notification
handling and route a valid segment through the real channel reassembler; use
real `PDSHLinkClient` HELLO and non-target `tools/list` if needed to supply
boot/device context. Compare entity object identities, not UUID alone. For
invalid/mutated outcomes, run the same comparator against the actual observed
checkpoints; `check.py` only proves mutation shape, not this runtime test.


## Additional required focused tests

The shared rows do not completely describe an ordinary real store-owned Link
exchange already physically submitted when a changed discovery result arrives.
Run this against the actual client/channel continuation: it ends outcome-unknown
once, without retry or replay, and old responses cannot be delivered. Also drive
a closing owner receiving an old discovery callback, then its actual applicable
disconnect boundary and explicit reconnect with a different service object; a
retained old service callback cannot be assigned to the new request. These are
local tests, not claims about physical callback origin. An indistinguishable old
callback using the same retained physical objects cannot be identified as old.

## Acceptance

- `PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_spec_golden.StandardGattDiscoveryOwnershipFixtureTests`: schema, shared rows and malformed and semantic mutation inventory.
- `swift test -j 2 --filter 'StandardGattDiscoveryOwnershipTests|StandardGattServiceChangeTests|StandardGattGrantOrderingTests|LegacyIdentityObservationTests|BLEIdentityTests|BLEDeviceMCPTests|PDSHLinkTests'`: all 66 rows, semantic mutation rejection by the real comparator, the focused pending-Link and reconnect cases, and existing affected lifecycle regressions.
- `swift build -c release --target PhoneDSHBLE -j 2`, then inspect the release object to ensure DEBUG test seams are absent.
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`; report each stage separately, including pre-existing failures.
- If the test-only UI harness is extended, run its real-page simulator tests; this is simulated input and does not establish actual Bluetooth behavior.

These tests do not prove physical iPhone/OS event ordering, real external
peripheral behavior, ESP32 tasks, restart, secure identity, Android or production
TLS. Do not mark GAP-31, GAP-16 or P0 closed on these local checks alone.

## Revision record

`discovery-ownership-v1`: contract owner freezes the local policy, 66 shared
object/event rows and mutations before dependent Swift implementation.

Freeze-stage checks: `PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1
python3 -m unittest test_spec_golden.StandardGattDiscoveryOwnershipFixtureTests`
→ PASS. The required combined CI command produced phone-spec PASS,
phone-p0-conformance FAIL on missing/stale iOS page contracts, and
phone-cross-tree FAIL because the new mutation inventory had no registered
reader. After registering its actual test reader, rerunning
`PYTHONDONTWRITEBYTECODE=1 bash scripts/ci/check.sh --only phone-cross-tree`
→ PASS. Discovery runtime, simulator and device acceptance remain NOT_RUN at
this revision; the fixture test validates shapes and inventory only.

## Revision v2 — global status publication intent

The implementer identified a reentrant cross-device status overwrite under
v1. The contract owner chose and froze global local intent ordering in
[PC-20261107-ble-status-order.md](PC-20261107-ble-status-order.md), with
separate shared fixtures and actual-callback tests. The v1 discovery object,
read, grant and Link cases remain required. The new revision does not close
GAP-30's separate status-driven side effects or imply radio evidence.

## Local implementation handoff

The store now takes immutable parent/object/UUID/property snapshots through one
production dispatcher for real CoreBluetooth callbacks and controlled physical
substitutes. Its store-owned endpoint map supplies the same read, alert, value
and notification admission on both paths. The 66 shared rows, wrong-expectation
mutations, real Link channel and pending operation, old endpoint callbacks,
manager-off reentry, and unrequested old service after reconnect run through
that store. This does not prove callback origin when the same OS objects are
reused, physical radio behavior or authenticated identity. Task grants remain
disabled. A non-active Link test verifies the underlying physical service and
endpoint storage is empty; B's physical standard endpoints remain the original
objects where its state is unaffected.

- After building the current candidate in the isolated scratch directory,
  `TMPDIR=/Volumes/dream/pdsh59-isolated.oyliws/tmp
  XDG_CACHE_HOME=/Volumes/dream/pdsh59-isolated.oyliws/cache
  SWIFTPM_MODULECACHE_OVERRIDE=/Volumes/dream/pdsh59-isolated.oyliws/clang-cache
  CLANG_MODULE_CACHE_PATH=/Volumes/dream/pdsh59-isolated.oyliws/clang-cache
  swift test --scratch-path /Volumes/dream/pdsh59-isolated.oyliws/scratch
  --cache-path /Volumes/dream/pdsh59-isolated.oyliws/cache
  --config-path /Volumes/dream/pdsh59-isolated.oyliws/config
  --security-path /Volumes/dream/pdsh59-isolated.oyliws/security --skip-build
  -j 2 --filter
  'BLEStatusOrderingTests|StandardGattDiscoveryOwnershipTests|StandardGattServiceChangeTests|StandardGattGrantOrderingTests|LegacyIdentityObservationTests|BLEIdentityTests|BLEDeviceMCPTests|PDSHLinkTests'`
  → PASS, 67 XCTest cases, including all 66 discovery vectors, ten semantic
  mutation checks, the v2 status tests and existing lifecycle tests. The
  initial combined run before the observation-test correction failed in the
  status test; its failure was not treated as a pass. Logs are in the isolated
  `full-retest.log` and `swift-test.log`.
- `TMPDIR=/Volumes/dream/pdsh59-isolated.oyliws/tmp
  XDG_CACHE_HOME=/Volumes/dream/pdsh59-isolated.oyliws/cache
  SWIFTPM_MODULECACHE_OVERRIDE=/Volumes/dream/pdsh59-isolated.oyliws/release-clang-cache
  CLANG_MODULE_CACHE_PATH=/Volumes/dream/pdsh59-isolated.oyliws/release-clang-cache
  swift build --scratch-path /Volumes/dream/pdsh59-isolated.oyliws/scratch
  --cache-path /Volumes/dream/pdsh59-isolated.oyliws/cache
  --config-path /Volumes/dream/pdsh59-isolated.oyliws/config
  --security-path /Volumes/dream/pdsh59-isolated.oyliws/security --skip-update
  -c release --target PhoneDSHBLE -j 2` → PASS, macOS arm64, with existing
  Swift concurrency warnings. After one invalid inspection attempt in which
  `swift-demangle` was not on PATH, the corrected inspection used
  `xcrun nm -m /Volumes/dream/pdsh59-isolated.oyliws/scratch/out/Intermediates.noindex/PhoneDSH.build/Release/PhoneDSHBLE-t.build/Objects-normal/arm64/BLEDeviceStore.o | xcrun swift-demangle > /Volumes/dream/pdsh59-isolated.oyliws/release-store-symbols.txt`
  with `set -o pipefail`, then
  `rg 'testDiscovery|testAdapter|TestAdapter|TestService|TestCharacteristic|testCaptureConnection|testReinstallCurrent' /Volumes/dream/pdsh59-isolated.oyliws/release-store-symbols.txt`
  → no matches. The corresponding BLELinkChannel object and inspected I/O
  seam names likewise yielded no matches.
- `TMPDIR=/Volumes/dream/pdsh59-isolated.oyliws/tmp
  XDG_CACHE_HOME=/Volumes/dream/pdsh59-isolated.oyliws/cache
  CLANG_MODULE_CACHE_PATH=/Volumes/dream/pdsh59-isolated.oyliws/clang-cache
  python3 -u examples/probe-app/identity-ui-harness/run.py --runtime
  com.apple.CoreSimulator.SimRuntime.iOS-18-4 --output-parent
  /Volumes/dream/pdsh59-isolated.oyliws --package-cache
  /Volumes/dream/pdsh59-isolated.oyliws/ios-packages` → FAIL: the new UI test
  tapped the switch row rather than its actual control; two original UI tests
  passed, and xcodebuild timed out while collecting diagnostics. After fixing
  that test, `TMPDIR=/Volumes/dream/pdsh59-isolated.oyliws/tmp
  XDG_CACHE_HOME=/Volumes/dream/pdsh59-isolated.oyliws/cache
  CLANG_MODULE_CACHE_PATH=/Volumes/dream/pdsh59-isolated.oyliws/clang-cache
  python3 -u /Volumes/dream/pdsh59-isolated.oyliws/rerun_ui.py` rebuilt the
  generated harness and ran all three tests on a new iOS 18.4 simulator → PASS.
  Both task-created simulators were deleted. Logs and retained runner are under
  `/Volumes/dream/pdsh59-isolated.oyliws/`. This is simulated radio input.
- `TMPDIR=/Volumes/dream/pdsh59-isolated.oyliws/tmp PYTHONDONTWRITEBYTECODE=1
  bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
  → phone-spec PASS; phone-p0-conformance FAIL on missing/stale page
  contracts; phone-cross-tree PASS. P0 remains a real failure and must not be
  downgraded to a skip. The earlier broader
  `swift test -j 2 --filter PhoneDSHBLETests` also remains FAIL: its two C
  bridge tests could not compile their pinned cJSON component and those target
  task paths are not exercised by the acceptance filter here.

Physical standard-GATT peripheral behavior, iPhone/ESP32 authenticated task
execution, reboot, key change, production TLS, Android device support, P0 and
independent security review are NOT_RUN or open. GAP-30 and GAP-31 remain
partial; GAP-16 remains open.

Post-integration source review identified the untested timeout/final-discovery
reentry described in [the deadline CCR](PC-20261107-discovery-deadline-ccr.md).
The 66 shared rows do not cover that winner; this handoff is partial and does
not claim complete conformance or merge readiness. Scan/stop reentry is tracked
separately in [the scan CCR](PC-20261107-ble-scan-reentry-ccr.md).
