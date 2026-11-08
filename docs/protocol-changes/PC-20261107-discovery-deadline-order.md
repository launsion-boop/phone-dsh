# Discovery deadline first-winner

```yaml
change: PC-20261107-discovery-deadline-order
contracts: [P07, P09]
status: frozen
breaking: true
version_decision: Preserve BLE wire and original 20-second deadline; define a fail-closed local first-winner and existing disconnect outcomes.
base: d6cfb0b8d2f6b999b10f0eac585ffd40cac84750
contract_revision: spec/device/v1/ble-link.md@discovery-deadline-v1
```

Protocol impact: P07; P09; P18: none — no saved identity or task format
changes. [The CCR](PC-20261107-discovery-deadline-ccr.md) identified an
unresolved reentry where a completed discovery result is published during the
older timeout's status observer but the older timeout later disconnects it.
The existing tests do not cover that interleaving. This source observation is
not physical CoreBluetooth timing evidence.

The owner chooses timeout-first when a current active timeout handler has
already entered and passed its own owner/timer/power admission. It reserves its
status intent, removes/cancels the deadline and denies owner admission before
any observer, physical disconnect or synchronous callback. Conversely a final
accepted discovery result that cancels the deadline first makes any later old
timer inert. The connected close's physical disconnect is submitted before its
devices will-change; an earlier read-claim callback may observe power off before
that submission, in which case none is sent. This is local API ordering only,
not an OS disconnect acknowledgment. Preserve existing first-winner read and
Link outcomes, another owner's independent deadline and status-v2 order.
Power-off follows the all-owner policy; never replay an unknown outcome. The
complete normative rule is in `spec/device/v1/ble-link.md`.

The linearization order is: check that the captured identity is still the
current active deadline and that power is available; reserve the timeout status
revision; claim, remove and cancel that exact deadline; close owner admission;
then perform any potentially reentrant hook, Observation or physical
submission. A stale timer exits before checking power and does not reserve an
intent. If the otherwise eligible current deadline sees power unavailable,
apply all-owner unavailability before any timeout intent or command.

| Producer → consumer | Compatibility |
| --- | --- |
| Old peripheral → new iOS app | Unchanged wire. A discovery result racing after an entered winning timeout can no longer briefly appear; explicit reconnection remains necessary. |
| New peripheral → old iOS app | Same wire; old app can still publish and then erase a result in the reentrant race. |
| New peripheral → new iOS app | Same wire and fixed deadline; local first-winner and existing grants determine outcome. |
| Persisted old data → new / rollback | No data representation changes; rollback restores the old local ambiguity. |

The coordinator owns `spec/**` and this record. The iOS source implementer
owns `Sources/PhoneDSHBLE/BLEDeviceStore.swift`; the separate runtime test
implementer owns `Tests/PhoneDSHBLETests/StandardGattDiscoveryDeadlineTests.swift`.
A DEBUG-only physical adapter may substitute callbacks, timer probes and
physical I/O, but must use the real store, original timeout, read claim and
Link channel continuation. It must not invent OS request tokens, directly
assign owner/grants/result/endpoints, or call target task/identity RPCs. The 19 shared cases are in `spec/device/v1/golden/standard-gatt-discovery-deadline.jsonl` and their schema in `spec/device/v1/schema/standard-gatt-discovery-deadline.schema.json`. Six malformed and 22 schema-valid semantic mutations are in `spec/device/v1/golden/standard-gatt-discovery-deadline-mutations.jsonl`. The exact JSONL SHA-256 is `2a050d7f876360240a1c2f5416da3edf0dccb34effe60d176cc3960166970974`. An actual production-state comparator must reject every semantic mutation; shape validation alone is not runtime evidence.

## Common real-store setup

Use a fresh isolated UserDefaults suite and the DEBUG physical adapter solely for real store physical calls/callbacks. Do not assign owner, timer, profile endpoint, grants, phase, status, result or claims. A and B have different UUIDs and distinct physical objects. Call real `connect`, capture each active connection timeout via `testCaptureConnectionTimeout` (both probes must first prove active), then `testDidConnect`. Discover services through `testDiscoveryServices` and real matching characteristic callbacks; retain reference-identical peer/service/endpoints. B has a valid battery endpoint/read declaration, while a separate B temperature request stays submitted and its original timer remains active. Record B owner, physical peer, endpoints, declaration, profile list, pending identity, channel/client, actual active timer identity and commands. Verify B remains usable with its actual admission method whenever no other device read is pending. B's real characteristic callback error is injected only in `b-error` and closes B; eligible timeout power-off and manager callback cases invalidate both; a stale timer after a bit-only power flip does not.

A basic setup has a submitted final temperature request and no published temperature endpoint. In read-pending additionally complete A battery discovery, grant real read, begin `store.read` and wait for the actual pending operation before the outer action. In link-pending complete A's real Link discovery/notification/HELLO/tools-list exchange while its distinct temperature request remains submitted; explicitly grant the non-target `light.get` tool and start real `queryLink` using a controlled physical peer. Hold the actual response after physical write/ACK, assert a real pending channel exchange. Never call task or identity RPC. `link-response-then-timeout` releases a real channel-framed terminal JSON response with `request_id` exactly equal to the query UUID, `status` equal to `completed`, and `result` equal to `{ "value": 42 }`. Wait for the actual `queryLink` caller continuation to return exactly once, assert its value is non-nil and matches that complete object and request ID, and only then fire A's captured timer. A nil `queryLink` return means still executing and is never `value-once`. Track and compare real encoded query (`0x56`) and execution (`0x55`) submission counts at setup, result and after teardown: the tested query submits no new execution, and timeout neither resubmits a query nor executes a task. Count actual encoded requests, not fixture expectations. In reconnected, capture old timer; close and deliver the real didDisconnect callback, await its post-return retirement, explicitly reconnect and submit the new discovery, prove owner and timer differ and new timer active; reset physical call counters, then invoke the captured old timer.

Events: `final` injects the actual submitted A temperature characteristic callback with correct parent/peer and readable endpoint; `timeout`/`old-timer` invoke the originally captured production timeout handler probe, including after cancellation (not a synthetic setter); `read-value` enters the actual physical value dispatcher; `poweroff` only sets the adapter’s physical powered-on bit false, without delivering a manager callback; the timeout/close’s next real power check invokes the existing all-owner unavailable path. `manager-off` instead invokes the shared real manager-state callback path `testManagerState(.poweredOff)`, which publishes its own eligible unavailable status; `b-error` delivers B's submitted discovery callback error with localized text `B-ERROR`. During setup, before connecting, call `testRadioOn()` through the real shared manager powered-on callback and assert its actual status `蓝牙已就绪，请点击扫描` as `PRIOR`. After setup connections and their `stopScan()` calls, assert that the actual status still equals `PRIOR`, then clear setup command counters. `timeout` is the actual timeout message `连接或服务发现超时`; `b-error` is the actual injected localized `B-ERROR`. No test-only status setter is permitted. Assert `b_timer`, `new_timer`, endpoint/owner identities, admission, physical side effect submissions and their timing, as well as the row's values. `disconnects` counts actual adapter disconnect submissions for A from after setup; no ignored reentry may increment it. `old_timer` is the captured probe state, not a replacement timer.

`other=unchanged` compares the full recorded B tuple and timer identity/state; `b-closing` checks B's actual teardown, one B physical disconnect and cancelled timer; `all-quarantined` checks real A/B phases, grants and endpoints cleared, channels detached and both timers cancelled, and no physical call **after** power-off. A prior actual disconnect issued before nested power-off is retained in the count. For a nested physical-bit-only flip, `other=unchanged` means B’s stored owner, grants, endpoints and timer are unchanged inside that checkpoint; actual B admissions already fail while physical power is off. B is cleaned only when the outer production frame reaches its next power check. `final_endpoint` compares the store's real endpoint object identity and profile publication, not an expected fixture variable. `link` and `read` use actual continuation completion/error and a separate exactly-once counter; rejected admission or fake test setter is not a completion. A late held Link response after close must not replay any request or complete twice.

Each `inject` is wired to a fresh one-shot `withObservationTracking` on the specified actual `devices`/`status` value, or the corresponding existing DEBUG `afterReadValueClaim` or `afterReadOutcomeClaim` hook. Assert the hook fires once; capture and compare every nested `expect` after the inner event returns while still in the outer call stack. At `final-devices-will-change`, the endpoint is deliberately still absent because will-change runs before the outer setter; the captured timer is already cancelled, and the final endpoint must then appear after the outer call returns. `timeout-devices-will-change` is after close's actual disconnect submission in this candidate, so nested power-off preserves its count of one; if the implementation changes ordering the contract must be revised, not silently loosened. `timeout-status-will-change` must arise from real timeout status publication; establish PRIOR unequal to timeout first. Track status intents using observed final text and notification counts as an additional focused assertion; do not let read/Link result calculations be inferred from the row's expected values.

The JSONL describes post-action state, not nested state unless explicitly under `inject.expect`. Each row must run independently through the production state machine. Run every row and compare actual snapshot fields to every expected key, with scalar-sensitive strings and booleans distinct from numeric values. Apply each invalid-schema mutation and require the real schema validator to reject it; apply each semantic mutation to a copy of the relevant expected snapshot and require the *same runtime comparator* to reject it against the captured actual snapshot. Also test comparator type-confusion/Unicode and prove all mutation names consumed. Never duplicate fixture expected outcome logic inside an adapter. Counts, timeouts and no-op checks need positive controls so an event hook that never fires cannot pass.


## Added connecting and claim-window controls

`connecting-timeout-then-old-services` uses the ordinary A `connect` only; the adapter records the submitted physical connect and original active deadline, but does **not** deliver `testDidConnect`. Clear subsequent event counters. Invoke that captured timer and then deliver a real services callback from the retained old physical peer. Its outcome is quarantined, one submitted A disconnect, no endpoint and no new characteristic-discovery submission. The callback cannot be accepted as evidence of a successful connection; the quarantine label likewise does not imply a physical disconnect. B remains fully unchanged, including its active timer and endpoint identities. Timeout status is subject to the same reserved intent and current local eligibility as the connected case.

`poweroff-after-timeout-read-claim` uses the `read-pending` setup. Its `after-read-outcome-claim` hook is the existing physical-free DEBUG hook immediately after the real close path wins the shared pending-read `.disconnected` claim, before read completion, closing observation, or the disconnect submission. Only flip the physical power bit there, without a manager callback. Immediately after that nested event, A’s local phase is closing, its old deadline is already cancelled, while B’s stored state and deadline remain unchanged, and no A disconnect was submitted. After the hook returns, the outer production close observes unavailable power and runs all-owner cleanup: both owners become quarantined and both deadlines are cancelled. Once async cleanup completes, the real read continuation resumes exactly once with the original disconnected outcome, not unavailable. Already claimed results must not be rewritten. `prior` means this timeout never commits a stale status after physical unavailability. A test that sets the claim or calls an artificial unavailable finisher cannot demonstrate this case.

`read-cancel-claim-before-timeout` starts the same real read, requests cancellation from a background task while the main actor is held at the synchronous test checkpoint, waits for the real cancellation call to return and verifies the existing read claim is cancellation, then invokes the captured timeout before actor-isolated cancellation cleanup can execute. Expected continuation is `cancelled-once`, even though timeout wins the separate deadline decision and closes. Wait for actual continuation completion and assert one physical disconnect. Do not use a sleep to infer the prior claim or force it with a test setter.

`extra_discovery_requests` counts A's actual services or characteristics submissions after setup and must equal zero on **every** row. This gives a direct negative assertion for the late connecting services callback, in addition to endpoint and phase checks. In the timeout devices-observation case, the selected contract requires the existing physical disconnect submission to precede that observation; the count is a local call record, never evidence that CoreBluetooth completed it.

## Power event distinction and stale timer precedence

`poweroff-before-timeout`, `poweroff-during-timeout-devices`, and `poweroff-after-timeout-read-claim` change only the fake physical powered-on bit. They do not themselves deliver a manager callback or create its status intent. At the devices will-change checkpoint, A is still locally closing, the already-submitted disconnect remains one, B is still locally unchanged and A's timer has already been cancelled; only once the outer frame resumes and performs its real power check are both owners quarantined. At the read-claim hook A is locally closing and its timer was already cancelled before the hook; B and its timer remain unchanged during the injected bit flip. Record those nested observations independently. The timer handler or close path's subsequent power check performs manager-unavailable cleanup; the invalid timeout status stays PRIOR.

`manager-off-callback-during-timeout-devices` is the positive contrast: at the same devices-observation point call `testManagerState(.poweredOff)`, which changes the physical state and runs the same actual manager-state handler as the production callback. The nested checkpoint observes both owners quarantined, timers cancelled and one pre-existing A disconnect. The manager's later eligible status intent commits the actual unavailable message (`蓝牙不可用，状态：4` for CoreBluetooth `.poweredOff`), so it supersedes the outer timeout intent. Re-arm observers one-shot and guard the injection itself against nested manager-driven notifications. Compare `manager-off` against the actual text, never a test-injected status.

`completion-poweroff-old-timer-inert` first completes final discovery and verifies the original deadline cancelled, then flips *only* physical power off, then invokes the captured stale timeout before any manager callback or other eligible event. Timer ownership/activeness is checked first, so this old callback does not perform all-owner cleanup, submit any command or status, invalidate B's still-local owner/timer or remove A's already-published endpoint. `phase=connected` and `other=unchanged` describe retained local state only: B's read admission fails with physical power off, and this row does not broadcast or claim that either device remains available. Later delivery of a real manager callback must run the existing all-owner unavailable rule, separately.

For every row, `physical_commands_after_poweroff` counts all physical adapter commands at/after the instant of bit change and must be zero. Commands issued before that instant remain in their original counters. The control needs a physical command log with temporal checkpoints rather than comparing the expected fixture with itself.

## Deadline identity is not owner identity

Each actual production scheduling of a connection/discovery timeout creates a fresh, non-reusable deadline identity coupled to that timer's current active ownership. The actual scheduled handler captures that same identity; a callback must compare it to the currently active deadline for that owner before checking power or doing anything else. Cancellation/completion/teardown removes or invalidates that exact active identity. A later timer, including one scheduled for the same owner if production ever permits it, cannot match an earlier captured identity. `Owner.deadlineRevision` allocated once per owner is insufficient to establish this property: it could remain identical across two timer installations.

The DEBUG captured probe and any read-only timer identity probe must expose the *same identity created by the real production schedule*, not an independently generated DEBUG counter and not the owner identity. The test obtains it after real connect, proves that actual timer active, captures the actual handler, and observes cancellation and, on real reconnect, the newly installed timer's distinct identity and continued activity. No fixture should directly install or replace an internal timer or manufacture a state users cannot reach; production invariants and identity allocation must be reviewed in addition to real-state tests.

## Acceptance

- `PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_spec_golden.StandardGattDiscoveryDeadlineFixtureTests` for valid rows, malformed inputs and semantic mutation shapes.
- `swift test -j 2 --filter 'StandardGattDiscoveryDeadlineTests|BLEStatusOrderingTests|StandardGattDiscoveryOwnershipTests|StandardGattServiceChangeTests|StandardGattGrantOrderingTests|LegacyIdentityObservationTests|BLEIdentityTests|BLEDeviceMCPTests|PDSHLinkTests'` for all 19 cases, semantic mutation rejection by the same real comparator, and all affected existing lifecycle tests.
- `swift build -c release --target PhoneDSHBLE -j 2` plus release-symbol inspection for DEBUG seams.
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`, reporting each gate separately.

This is a local iOS lifecycle decision only. Android device capability, task
sessions, physical device/OS timing, reboot and power-loss behavior remain
separately unverified. Do not close GAP-31, GAP-16 or P0 from simulated cases.

## Freeze-stage evidence

`PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest
 test_spec_golden.StandardGattDiscoveryDeadlineFixtureTests` → PASS (19 shared
rows, six malformed and 22 semantic mutation shapes). `TMPDIR=/Volumes/dream/pdsh59-isolated.oyliws/tmp
PYTHONDONTWRITEBYTECODE=1 bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → phone-spec PASS,
phone-p0-conformance FAIL on missing/stale page contracts, phone-cross-tree
PASS. These checks do not exercise the deadline implementation. At this
revision all new runtime scenarios, simulator and physical tests are NOT_RUN.

## Implementation handoff

The iOS store now couples each real scheduled connection deadline to a fresh
object identity and validates it before processing an expiry. It claims and
cancels the eligible deadline before entering close, and uses a separate
manager-unavailable revision to prevent a nested off/on transition from
reviving an older frame. The shared disconnect submission path also guards
against a nested duplicate submission. These are local ordering decisions;
they do not establish physical disconnection or authenticated device identity.

An independent review requested two additional checks before runtime evidence
could satisfy this record: compare B's actual authoritative read and alert
declarations and real endpoints, and compare the entire returned Link object.
The runtime test now includes both and a positive real Alert admission control.
Four focused cases separately exercise an off/on transition in the read-claim
window, an unavailable event after a physical bit change, a nested duplicate
didConnect and an off/on transition immediately before disconnect submission.

`TMPDIR=/Volumes/dream/pdsh59-isolated.oyliws/tmp PYTHONDONTWRITEBYTECODE=1
bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
on the implementation → phone-spec PASS; phone-p0-conformance FAIL (missing or
stale page contracts); phone-cross-tree PASS. Full log:
`/Volumes/dream/pdsh59-isolated.oyliws/deadline-final-gates.log`. The macOS
arm64 `swift build -c release --target PhoneDSHBLE -j 2` with isolated scratch
and caches → PASS; `xcrun nm -m` piped to `xcrun swift-demangle` found no
inspected DEBUG adapter, timer, or disconnect-hook symbols in the release
object. Build and symbol logs are `deadline-release.log` and
`deadline-release-symbols.txt` in the same isolated directory. These checks
are not a real-device, task-session, or P0 conformance result.

The isolated `deadline_ui.py` runner built the actual Bluetooth devices page
and ran its three UI regression cases on an iOS 18.4 simulator → PASS (3/3),
then deleted its task-created simulator. The radio and callbacks in this UI
harness are simulated. The build, test, and runner logs are under
`/Volumes/dream/pdsh59-isolated.oyliws/`; no physical iPhone or ESP32 result is
implied.

After the independent-review test strengthening, the following command with
all scratch, configuration and caches isolated under
`/Volumes/dream/pdsh59-isolated.oyliws/` → PASS, 73 tests and 0 failures:

```sh
swift test --scratch-path /Volumes/dream/pdsh59-isolated.oyliws/scratch \
  --cache-path /Volumes/dream/pdsh59-isolated.oyliws/cache \
  --config-path /Volumes/dream/pdsh59-isolated.oyliws/config \
  --security-path /Volumes/dream/pdsh59-isolated.oyliws/security \
  --skip-update -j 2 \
  --filter 'StandardGattDiscoveryDeadlineTests|BLEStatusOrderingTests|StandardGattDiscoveryOwnershipTests|StandardGattServiceChangeTests|StandardGattGrantOrderingTests|LegacyIdentityObservationTests|BLEIdentityTests|BLEDeviceMCPTests|PDSHLinkTests'
```

The full runtime log is `deadline-final-runtime.log` in that isolated
directory. This final rerun also checks A's authoritative grants and every
standard and Link endpoint after all-owner unavailability, plus real admission
rejection with no additional physical command. An independent review examined
the same source and test files before the run (SHA-256 `6ecb5940fcc8c9d63b21b481fbd8916f019a6d28a2b275c28c98710a155fc2cb`
and `b2d4d65dc1fcfc32650ce9590c2d0227972b0df0420de2b6b2efd95d8c5f9c41`,
respectively). The run includes all 19 shared deadline rows and 22 schema-valid
semantic mutation rejections by the same actual-state comparator. The four
known-bug scan diagnostics described in the separate CCR are excluded from
this count. Device, power-loss, production TLS and task E2E remain NOT_RUN.
