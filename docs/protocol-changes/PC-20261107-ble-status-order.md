# Freeze local BLE status intent ordering

```yaml
change: PC-20261107-ble-status-order
contracts: [P07, P09]
status: frozen
breaking: true
version_decision: Preserve public status text and BLE wire; tighten local synchronous publication ordering without suppressing lifecycle effects.
base: 42df933f533bcdcbd4e2a2ae93eedec2e2d874b7
contract_revision: spec/device/v1/ble-link.md@discovery-ownership-v2
```

Protocol impact: P07; P09; P18: none — no stored preference format changes.
The discovery owner reported the CCR against `ble-link.md@discovery-ownership-v1`:
A's discovery-error status will-change can synchronously deliver B's error;
B finishes publishing and the older A publication overwrites it. If B instead
arrives during A's close/devices notification, A must already have reserved its
intent to prevent the same loss. Existing status writes in scanning, manager
state, connection failure/timeout, Link notifications and handshake also share
this text. A discovery-only revision cannot order them against B's other paths.

The owner chooses the local intent ordering specified in
`spec/device/v1/ble-link.md`: every status site reserves a fresh non-reusable
identity after eligibility and before message evaluation, physical effects or
Observation. A later eligible intent permanently supersedes an uncommitted
older one, even if the later intent then loses its own owner/power eligibility;
this is not a promise that the most recent attempted text will appear. The
same text reserves a fresh identity without another status mutation or
notification. Original owner, peer, power, channel and phase conditions are
rechecked at actual mutation. A losing or same-text publication does not cancel
the independent lifecycle operation or relax its own guards. This orders only
text publication and leaves GAP-30's other effects open. No wire, task grant,
stored data, OS token, security authentication or Android capability changes.

| Version relationship | Compatibility |
| --- | --- |
| Old app / existing peripherals | Existing wire and text; old synchronous observation order can show a stale status. |
| New app / old or new peripherals | Same wire and messages, but a later eligible local status intent supersedes older uncommitted text; same-value writes no longer notify. Lifecycle actions still use their own rules. |
| New peripheral / old app | Same wire; old UI behavior and its reentry weakness remain. |
| Old persisted data / new and rollback | No status is persisted and no identity/grant preference is migrated. Rollback restores older publication behavior. |

Coordinator owns `spec/**` and change records. The active discovery store
implementer exclusively owns `Sources/PhoneDSHBLE/BLEDeviceStore.swift` and
may add only necessary DEBUG physical-observation hooks there. A separate test
implementer owns `Tests/PhoneDSHBLETests/BLEStatusOrderingTests.swift`;
`StandardGattDiscoveryOwnershipTests.swift` remains with its current test
implementer. No target task may be invoked. Shared cases are `spec/device/v1/golden/standard-gatt-status-order.jsonl` with schema `spec/device/v1/schema/standard-gatt-status-order.schema.json`; ten schema-valid incorrect expectations are in `spec/device/v1/golden/standard-gatt-status-mutations.jsonl`. The SHA-256 of the exact case bytes is `f403e613669f3d3365733bdb68500ba185ef70ad6066246eea84ac6013b5e10d`. The actual store comparator must reject all semantic mutations. Schema tests also reject malformed nested input; they do not prove runtime behavior.

## Shared setup and instrumentation

Each row uses a fresh real `BLEDeviceStore`, isolated defaults and fake physical
adapter objects only; no helper may set internal owner phase, status, grant,
timer, endpoint map, status intent or result. Create distinct retained UUIDs
and peer objects A and B; C is required only for the three-event row or to
produce `PRIOR`. Establish all described devices through real `connect`,
physical `didConnect`, original service discovery submission and the shared
production callback reducer. The corresponding discovery request is genuinely
submitted and pending. Set A/B/C read and alert grants through the real public
grant API while connected; assert declarations and visible fields before each
case. They do not create reads or target device tasks. Retain their owners and
their actual connection-deadline probes.

Before baseline, feed the real manager-state dispatch `.poweredOn` once so
`READY` is the *actual current published status* `蓝牙已就绪，请点击扫描`.
Use nonempty distinct NSError `NSLocalizedDescriptionKey` values `A` and `B`;
`b-error-ready` uses the exact READY string. The names label expected text,
not tokens injected into CoreBluetooth. Assert the initial text is READY and
reset/subtract physical counts. A/B initial state is connected, service
request pending, and read/alert grant true, except where specified below.

Track real `status` with `withObservationTracking`, recording notifications
and rearming only when a nested level requires it; count the outer notification
already in progress. Track `devices` similarly only for the designated close
checkpoint. Each injection is consumed once at the stated level and has a
finite recursion bound. Actions execute synchronously on the same main actor.
The order of `injections` specifies nesting: the second can fire only inside
the event invoked by the first. A missing or twice-fired checkpoint is a test
failure. Do not model an old OS callback by attaching an application request
token; use the actual retained peer/service objects and real dispatcher.

`ab-discovering-status-prior`: use a separate C to create `PRIOR` by an actual
expected discovery error before A/B setup, then establish A/B with no call to
`testManagerState(.poweredOn)` that would overwrite it. Capture and assert
`PRIOR`, then reset counts. C is outside the measured A/B counts. The
`manager-powered-on` event then delivers the real manager callback while A/B
are active and must attempt the READY status. No automatic scan is pending.

`a-closing-b-discovering`: after common setup, invoke the real A disconnect,
retain A's exact peer, and assert A is closing; reset counts afterwards. B
remains connected with its discovery genuinely pending. The A error delivered
later is a physical late discovery callback in closing, not a fake status
write. It must be ignored and cannot win or request another disconnect.

`a-link-b-discovering`: complete A discovery via real callbacks with one
physical Link service and RX/TX/audio endpoints; retain the real installed
channel. Do not fabricate successful handshake/identity or start target task
tools. Do not deliver successful notify callbacks yet. Deliver
`a-link-notification-error-a` through the production notification dispatcher
for A's actual TX endpoint with NSError A; A teardown must detach/fail that
real channel once. B is still pending discovery. Subtract setup notify calls.

## Event and checkpoint semantics

* `a-error-a`, `b-error-b`, `b-error-ready`, `c-error-a`: deliver a real
  expected services callback, with matching peer, currently submitted request,
  `services == nil`, and the respective NSError. Error is not an empty result.
* `a-stale-error-a`: same physical services error on the already closing A.
* `a-discovery-timeout`: invoke A's captured original connection-deadline
  handler; assert it had actually been active before invocation.
* `physical-power-off`: change only fake physical manager power, without
  delivering the manager callback; production must notice at its existing
  post-observer power boundary and do all-owner cleanup. This simulates a local
  observation; it proves nothing about physical radio ordering.
* `manager-powered-on`: deliver the actual shared manager-state callback.
* `a-status-will-change`, `b-status-will-change`,
  `manager-status-will-change`: the actual outer status Observation will-change
  reached while that event is publishing. `a-close-devices-will-change` is
  reached inside A's real closing transition before it returns. These are not
  fake direct calls to an internal status setter.

`expect.status` is the final actual public status after the outermost action
and synchronous nested work return; `READY`, `A`, `B`, `PRIOR` map to the
distinct strings stated above. `phases` and `disconnects` are actual owners
and physical disconnect submissions per named device, cumulative after
setup; C may be omitted where it is not measured. Closing or quarantined
devices must actually revoke and visibly clear their read/alert permissions,
while connected peers retain their declarations. `status_notifications`,
where supplied, is the exact count after baseline including enclosing and
nested real will-change calls. It is omitted where either a stale outer
publication is blocked before registering Observation or reaches a guarded
no-op mutation; the final published value and all actions remain mandatory.

The `other` checks are not strings supplied by the adapter:

* `all-owner-unavailable`: B and A are both quarantined, captured discovery
  deadlines cancelled, grants and channels detached, no CoreBluetooth
  submission after fake power off, and prior claims preserved.
* `a-timeout-teardown`: original deadline is inactive and real A disconnect
  was submitted exactly once despite A's status losing.
* `a-link-teardown`: the same retained real A channel is no longer current,
  its pending non-target operation, if one was already submitted, completes
  outcome-unknown once; no new notify or retry follows the error.

The same-current test is important: while A's `A` text is suspended at
will-change, B reports exactly the already committed `READY`. B must receive
a newer local intent without triggering a nested status notification; A must
not commit after B returns. The ABA row checks actual three-level `A → B → A`
intents, not a string-comparison revision. The loss-of-power row ensures a
later initially eligible B invalidates A even though B itself never publishes.


## Acceptance

- `PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_spec_golden.BLEStatusOrderingFixtureTests`: shared case and malformed/mutated shape checks.
- `swift test -j 2 --filter 'BLEStatusOrderingTests|StandardGattDiscoveryOwnershipTests|StandardGattServiceChangeTests|StandardGattGrantOrderingTests|LegacyIdentityObservationTests|BLEIdentityTests|BLEDeviceMCPTests|PDSHLinkTests'`: all ten shared cases and ten semantic mutations through real store checkpoints; focused scan, handshake failure, repeated same-value observer, stale owner and power cases; and all existing affected lifecycle and discovery regressions.
- `swift build -c release --target PhoneDSHBLE -j 2`, with DEBUG seams absent from release objects.
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`, recording each stage.

No physical OS, radio, device or task result is inferred from these local
cases. The remaining status-driven side effects, real OS behavior, Android
support, P0 gate and authenticated task sessions remain open.

## Revision record

`discovery-ownership-v2` resolves the owner-reviewed CCR on status intent
ordering and adds shared cases before implementation. `discovery-ownership-v1`
continues to define object attribution and the 66 discovery scenarios.

Freeze-stage checks: `PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1
python3 -m unittest test_spec_golden.BLEStatusOrderingFixtureTests` → PASS
for case and mutation shapes. The required combined CI command produced
phone-spec PASS, phone-p0-conformance FAIL on the missing/stale page
contracts, and phone-cross-tree PASS. The pre-v2 discovery candidate's
57 local Swift tests passed, but status-v2 runtime, semantic-mutation,
simulator and physical-device acceptance are NOT_RUN at this revision.

## Local implementation handoff

All store status publication sites now reserve a non-reusable local intent
before applicable reentrant operations and commit only while the intent and
its original local guards remain valid. Equal text suppresses redundant
Observation without undoing the new intent. Discovery error and manager cleanup
claim their own lifecycle before publishing; stale connect failures and a
physically unavailable timeout do not reserve a status. Link notification
failure also retains the channel-installation revision across observation.
The status losing a race does not alone skip its required teardown.

The isolated `BLEStatusOrderingTests` retry → PASS, nine XCTest methods,
including the ten shared vectors, all ten semantic mutations through the real
comparator, and focused scan, stale owner, same-channel reinstall and actual
Link handshake failure. The complete affected filter then → PASS, 67 XCTest
methods; exact command, earlier failed attempt and log paths are recorded in
[the discovery handoff](PC-20261107-gatt-discovery-ownership.md). A release
build and inspected DEBUG seam symbols passed as recorded there. The local
ordering tests use simulated physical callbacks, not actual CoreBluetooth
radio evidence; other status-driven effects in GAP-30 remain open.
