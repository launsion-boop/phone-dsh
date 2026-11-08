# Freeze conservative iOS service-change invalidation

```yaml
change: PC-20261107-gatt-service-change
contracts: [P07, P09]
status: frozen
breaking: true
version_decision: Preserve existing wire, public grants and errors; tighten local lifecycle admission and require an explicit new connection after an applicable disconnect boundary.
base: 1fb3385b9ed6cb133cf81c3fe444da01af0ec8bd
contract_revision: spec/device/v1/ble-link.md@service-change-v2
```

Protocol impact: P07; P09; P18: none — stored intent and legacy preference
representations remain unchanged. The iOS store does not handle the documented
`didModifyServices` delegate event, so it may retain service/characteristic
objects and an active Link channel after the database changes. The owning
contract freezes conservative per-connection invalidation using the existing
closing/quarantine, shared read-outcome claim, disconnect barrier and UI.
This is a local lifecycle change, not a new wire field, error code, task
capability, replay rule or format. Historical preferences are never rewritten.

[Apple's service-change documentation](https://developer.apple.com/documentation/corebluetooth/cbperipheraldelegate/peripheral%28_%3Adidmodifyservices%3A%29)
says previously discovered services in the invalidated list can no longer be
used. It permits rediscovery and does not require closing the whole connection.
Here, an empty or unrelated list also causes local teardown because the
application does not yet have a complete discovery-attribution contract; an
empty list is a conservative input case, not a claim that an OS emitted it.
An unrelated or frequent database change may interrupt a working device and
increase reconnect effort or energy use. No physical event sequence is inferred
from a locally injected callback. [Cancellation](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection%28_%3A%29)
is nonblocking; only the already-frozen, applicable
[completed disconnect callback](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanager%28_%3Adiddisconnectperipheral%3Aerror%3A%29?changes=_5)
may provide the local boundary. Local object or revision checks do not prove
which radio attempt produced a callback.

The producer is the existing CoreBluetooth delegate; the Swift store consumes
it, and the Bluetooth page displays the already-frozen closing/quarantine
states. Android standard GATT remains target; firmware and Worker encodings do
not change. Old binaries may continue using invalidated attributes; new code
conservatively invalidates and disconnects, including when only an unrelated
service changed. Old and new peripherals exchange the same wire; some dynamic
service databases now require an explicit reconnect and fresh grants. Rollback
restores the old unsafe lifecycle. No old on-disk data is migrated or removed.

The coordinator owns `spec/**` and this record. The store implementer owns
`Sources/PhoneDSHBLE/BLEDeviceStore.swift` and, for a DEBUG-only physical
write/response seam to exercise the real channel continuation,
`Sources/PhoneDSHBLE/BLELinkChannel.swift`; the separate test implementer owns
`Tests/PhoneDSHBLETests/StandardGattServiceChangeTests.swift`. Their internal
DEBUG-only adapter may substitute physical peripheral/service identity and
record side effects, but the real callback and test must share the same
production event dispatcher, outcome claim, continuation, Link receive path and
admission. It cannot assign an OS request token or directly set grants,
channel, pending state or terminal outcome. Historic labels use only isolated
UserDefaults in tests. Existing task grants remain disabled.
The independent UI test implementer may extend only the existing test-only
`examples/probe-app/identity-ui-harness/{Host,IdentityUITests}.swift` to inject
a simulated service change and inspect the real page; it does not change the
production probe's compilation condition or invoke any target task.
The accepted value/error path may expose a DEBUG-only one-shot checkpoint
immediately after its real shared outcome claim and before `finishRead`, so the
value/error-first cases execute that actual intermediate state. This hook must
not replace the claim, fabricate its result, or alter release behavior.

The 22 shared cases in
`spec/device/v1/golden/standard-gatt-service-change.jsonl` include empty,
known and unrelated lists, all three read-outcome winners, pre/post-reserve,
synchronous Observation reentry, duplicate service change, the disconnect
callback stack and later explicit reconnect, incorrect physical identity,
manager unavailability before the callback and during the claimed outcome,
other-device isolation, unknown device, connecting state and an in-flight
ordinary Link operation. The canonical SHA-256 is
`185d5c37e6837df54f031d290845e5a53580d9d1f32c81796b9e895b2157c3a5`.
Every row checks exact physical submission counts, lifecycle states, grants,
identity and channel, pending completion and timer, old Link deliveries and
legacy preference preservation. Invalid/mutated expectations must fail the
same comparator used for the real store. A test hook records simulated physical
side effects only; it does not establish actual CoreBluetooth callback origin.

### Shared case setup and actions

Except for `connecting-modification`, each case creates two distinct simulated
peripherals A and B through the real store: both are connected with read/alert
grants, current real Link channels and unbound local identity markers. Save
both actual channel/client object identities and first prove that a valid event
reaches each real channel. For `connecting-modification`, only B has this
connected setup; A has a submitted connection and no channel, identity or read.
B's grants and state are independent. A uses a recorded marker, except the
`connected-pending-identity` row which starts with a pending marker; both
retain no authenticated meaning.
When `initial_pending` is `a`, start one actual A standard-read continuation;
the reserve cases trigger the event at the named point in that actual read.
After setup and its positive Link events, establish the baseline for every
submission, completion and event-delivery counter immediately before the
named event; the boundary/repeat cases include the first change's cancellation
in the count. Store historical labels only in an isolated suite and compare its exact
content before/after by value type and Unicode scalars. `admission_check` of
`denied` means actually attempt read, alert, Link, discovery, notify and
connect after local invalidation, and check no such physical submission; for
the boundary row the connect attempt happens inside the callback stack. It is
not inferred from a phase or a fake result. `other-active` instead proves A's
original read token remains pending while a real A alert and Link admission
still submit and a current channel event is delivered; only then deliver A's
read value. A second A read remains unavailable while its first read is
pending. `not-tested` makes no admission claim. Late Link frames are delivered
through the actual store value-callback dispatcher with the old endpoint;
verify the old channel's receive/handler is not called. Do not directly feed
the detached channel. A `none` timer means
no A pending read was created; `absent-or-cancelled` admits either state but
never an active timer. All task grants stay disabled.

| Case(s) | Actual callback and additional ordered action |
| --- | --- |
| `connected-known`, `connected-empty`, `connected-unrelated`, `connected-pending-identity` | Deliver one matching A event with, respectively, a known object, no objects, an unrelated object, or a known object with a pending identity marker. These are inputs to the same production dispatcher; do not make the fake decide policy. |
| `read-value-wins`, `read-error-wins` | In the actual A eligible value/error claim hook deliver service change before the continuation finishes; the previously claimed result must finish once. A value case supplies Battery byte 37 and checks the real value, unit and valid timestamp. The error case supplies a controlled NSError and asserts the same domain and code survive, not only an error category. |
| `read-cancel-wins`, `read-service-change-wins` | Have a real background cancellation return after claiming but before queued main-actor cleanup, then deliver the change; in the reverse case trigger cancellation after the real disconnected claim but before cleanup. Await the original task once. |
| `read-before-reserve`, `read-after-reserve` | Deliver the event respectively before reserve and after reserve but before physical submission, within the actual A read path. |
| `reentrant-admission` | In A's first real devices will-change notification, once, attempt all denied A operations and late old Link event, and revoke B's alert grant. B's later declaration must survive A's outer publication. |
| `repeated-while-closing` | Deliver an A event, then an opposite empty/nonempty A event while closing; only the first may request cancellation. |
| `disconnect-boundary` | Deliver A change, then the real shared disconnect callback. Attempt connect inside its callback stack (denied); after the stack returns and its scheduled retirement reaches idle, explicitly connect once. Before fresh discovery and grant, read/alert remain denied. |
| `different-peer` | Deliver an event carrying a different simulated physical peripheral with A's UUID; use the existing unexpected-peer path and do not conflate B with A. |
| `manager-off-before-callback` | Set only the simulated manager's powered state off without delivering its state callback, then deliver the matching A change. The event invokes the existing all-owner unavailable transition; the read gets Bluetooth-unavailable if it wins. No physical command is sent. |
| `manager-off-during-claim` | Deliver matching A change; after its disconnected result wins the real read claim but before further publication/submission, synchronously change only the simulated manager state to off. The all-owner unavailable transition preserves that winner and submits no cancellation. |
| `other-device-change` | Deliver matching B change while A's read is pending; feed the real A value callback afterwards and await its successful result. Only B is closed. |
| `unknown-device` | Deliver an event for an object with an ID having no local owner; neither A nor B is changed. |
| `unknown-device-off` | Set only the simulated manager's powered state off without delivering its state callback, then deliver an event for an object with no local owner. The existing manager-unavailable transition invalidates A and B and finishes the pending read; no physical command is sent. |
| `connecting-modification` | Set up A with a submitted connect that has not produced didConnect (B stays connected); a matching unexpected modification quarantines A and requests cancellation under the existing pending-connect rule. |
| `link-inflight` | Start an ordinary non-task Link operation through the real client and store-owned channel with simulated physical I/O, wait until its real channel continuation is pending, then deliver A change. Await its one outcome-unknown termination; a later old response is not delivered or replayed. |
| `link-completed` | Complete an ordinary Link operation through the same real channel before delivering A change; its already returned result remains completed and is not retried or reinterpreted. |

An action hook is one-shot. For each `prepublication=revoked` case, inspect
the first actual relevant devices will-change callback: the affected owner's
phase and real admissions must already deny use, its identity provenance and
channel/client must be invalidated, and any captured read/timer must have its
claim and cleanup as specified. Observable device labels may still display
their old values inside will-change, but they cannot authorize an operation.
For manager-off rows, B's actual channel/client and identity provenance are
also cleared. Retained channels/clients must be the original objects, not
replacement fakes. The fixture's physical counts include all nested
actions, not just the outer callback, and no OS callback token is fabricated.
The test must independently verify first-winner outcome and exactly one
completion, absence of old Link delivery, A/B grants and state, unchanged
historical suite, and exact command counts; a fixture `scenario` name or a
fake-returned success is not itself an assertion.

Acceptance: the shared 22 cases, valid/invalid mutations and focused
value/cancel/disconnected first-winner tests against real continuations; a
real current `PDSHLinkClient` and store-owned `BLELinkChannel.exchange` with
controlled physical write/response for the in-flight outcome (the test cannot
replace the channel's continuation with an independent fake transport);
independent UI state reentry and other-device tests; `swift test -j 2 --filter
'StandardGattServiceChangeTests|StandardGattGrantOrderingTests|LegacyIdentityObservationTests|BLEIdentityTests|BLEDeviceMCPTests|PDSHLinkTests'`;
`swift build -c release --target PhoneDSHBLE -j 2`;
`PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest
 test_spec_golden.StandardGattServiceChangeFixtureTests`; and `bash
scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Report P0 and device failures or missing checks separately. The service-change
subset does not resolve GAP-31's multiple/duplicate discovery callbacks,
GAP-30, GAP-16, Android device support or authenticated task sessions. Actual
OS/device service-change and reconnect behavior remains NOT_RUN until tested
with appropriate controlled peripherals.

Revision v2 clarifies precedence: an unknown-owner event is ignored while
powered on, but when the manager is already unavailable the independently
required all-owner unavailability transition takes precedence. The new `unknown-device-off` shared case fixes the interaction explicitly. This clarifies the
same conservative manager-state behavior and adds no wire or device capability.
