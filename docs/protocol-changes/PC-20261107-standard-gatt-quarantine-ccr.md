# Draft: local GATT grant ordering and disconnect quarantine

```yaml
change: PC-20261107-standard-gatt-quarantine-ccr
contracts: [P07, P09]
status: draft
breaking: true
version_decision: pending — no implementation or new wire format is approved by this request
base: 7af9544bceab60a9748b48aca6949df48adcc190
contract_revision: pending
```

Protocol impact: P07; P09. GAP-29 records a real `BLEDeviceStore` Observation
failure: a later synchronous revocation can be overwritten by an earlier
grant. The existing [identity Observation CCR](PC-20261107-identity-observation-ccr.md)
also records stale continuation, connection and resource ownership risks.
This request proposes a separate local authorization boundary; it does not
freeze it, enable a target profile, or close GAP-16.

## Candidate behavior to review

- Each observed connection attempt has a non-reusable app-local owner. At an
  accepted connect, clear prior standard read and alert grants before any
  observable notification or CoreBluetooth call. The existing void `grant`
  API may still accept a declaration while idle, but it cannot authorize a
  GATT operation while disconnected and must not survive the next connect.
  This changes the existing treatment of grants set while disconnected.
- Track read and alert declarations independently per device. Within one
  live local owner, a later nested declaration wins for that field without
  discarding an unrelated field or another device's change. Revoke changes
  local admission before an Observation callback can reenter `read` or
  `alert`; a new grant becomes usable only once its own still-current
  publication has committed. A connection invalidation revokes both fields,
  regardless of these per-field ordering rules. All writes to the observable
  device array must avoid restoring an older whole-array snapshot after a
  callback; authorization and lifecycle side effects need their own owner
  checks.
- Preserve the current unusual side effect unless a different compatibility
  decision is explicitly frozen: any `grant` call for a device with a pending
  read, including nil/nil, same-value and alert-only calls, ends that captured
  read and requests disconnection. First deny admission, detach its exact
  continuation and timer, then complete the captured read once. Never use a
  later UUID lookup to finish a new read or disconnect a newer owner. A
  previously submitted alert is still `submitted_unconfirmed`; do not claim
  it was recalled or retry it automatically. Existing durable MCP alert
  intents, same-key `outcome_unknown` and no-repeat behavior are outside this
  proposed delta; this does not assert an independent alert-receipt query.
  The freeze must say whether an existing pending read makes both grants
  immediately unavailable before any notification and must distinguish
  cancel before `connect` is sent to CoreBluetooth from cancel after it is
  sent. A later grant in a genuinely new local owner must not restore an old
  owner's grant or cause the old cleanup to affect new resources.
- A candidate `closing` state blocks a new connect or read for that peripheral
  while the old attempt has no verified completion boundary. It must also
  block standard alert submission and account for Link operations, service
  discovery and old timers owned by that connection; a still-connected
  `CBPeripheral.state` is not permission to issue another operation. Apple describes
  [`cancelPeripheralConnection(_:)`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection%28_%3A%29?changes=_2_1__2_8&language=objc)
  as nonblocking. For a previously connected peripheral, Apple states that
  after [`didDisconnectPeripheral`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanager%28_%3Adiddisconnectperipheral%3Aerror%3A%29?changes=_5)
  executes, its peripheral delegate gets no further calls and discovered
  attributes are invalid. A proposed implementation would wait until that
  applicable callback has returned before allowing a new attempt and fresh
  discovery, with automatic reconnect disabled; calling cancel, waiting a
  fixed time or observing a state string alone would not release quarantine.
  This remains a proposal, not proof
  that every old or new system callback is attributable to an app epoch.
- A cancelled pending connect, `didFailToConnect`, radio-off/reset, manager
  replacement, and an unexpected late `didConnect` need explicit transition
  and recovery decisions. If an applicable boundary cannot be established,
  remain unavailable rather than guessing. A characteristic value delegate
  can carry both reads and subscribed notifications without a request token;
  notification/read overlap and whether disabling notifications drains queued
  events need a separate conservative rule and evidence. The current reference
  ESP32 Link firmware is not evidence for standard Battery, Environmental
  Sensing, Device Information or Immediate Alert characteristics.

The local SDK also states that commands should be issued only while the
central is powered on, and that a state below powered off invalidates
peripherals obtained from that manager. A subsequent powered-on state or
rediscovery alone does not establish that every old central callback has
drained. A freeze must address manager and peripheral ownership and reject
unknown callbacks without treating radio power state as a disconnect barrier.
The value callback is also used for subscribed notifications; a matching
characteristic object or a test-injected token alone cannot distinguish them.

## Required freeze and acceptance

Before implementation, specify every transition and the UI-visible unavailable
state, cancellation and retry policy; decide behavior for nil/no-op requests,
connecting and disconnected grants, radio state changes, unexpected callbacks
and same-field versus cross-field reentry. Include an old/new/rollback matrix,
shared positive and negative event fixtures, and exact test seams that exercise
the real store, continuation and state machine rather than a copy. Tests must
cover immediate revocation admission, same/different field and device reentry,
the captured pending token and its single completion, stale timer/cancel,
barrier-before-reconnect, unavailable or duplicate callbacks, and a new read
after confirmed rediscovery. A fake callback bearing a test token does not
prove that CoreBluetooth actually supplies or preserves that association.

The Apple ordering statement is not proof of radio identity, authenticated
traffic, liveness, cross-process ordering, all OS versions or behavior on
unobserved hardware. iPhone tests need a controlled peripheral that actually
implements the standard GATT services, including notification/read and
reconnect cases; a host state-machine test or the Link-only ESP32 is not that
evidence. Android GATT remains `target` and requires its own implementation and
device verification. An unresolved platform guarantee is a contract change
request, not permission to add a timeout-based fallback.
