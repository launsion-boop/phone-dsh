# CCR: discovery deadline and final callback first-winner

```yaml
change: PC-20261107-discovery-deadline-ccr
contracts: [P07, P09]
status: draft
breaking: pending
version_decision: pending — no new deadline winner is approved by this request
base: 9e313f84526918c5bf52d3b54e56a80f04785796
contract_revision: pending
```

Protocol impact: P07; P09. Source review of the implementation candidate found
an untested synchronous reentry: a current connection's timeout handler begins
while its original deadline is active. During its status will-change observer,
the matching final characteristic callback completes, cancels that deadline
and publishes its discovered capability. The older timeout handler then
checks only owner and phase and disconnects the connection, clearing the result
it just allowed to publish. This is a source-derived interleaving, not a claim
that CoreBluetooth has emitted it or that a physical device was tested.

`spec/device/v1/ble-link.md@discovery-ownership-v2` fixes the original deadline,
requires its cancellation on complete discovery and orders global status
intents, but does not specify which of an entered timeout and the final callback
wins. The existing 66 discovery and ten status cases do not exercise this
interaction. Neither a local timer revision nor an app owner proves radio event
origin. Do not claim this candidate fully conforms or mark GAP-31 closed.

The contract owner must choose and freeze one first-winner and its
linearization before implementation. A candidate is to let a currently eligible
timeout claim before its first status/devices Observation, preventing an
embedded discovery completion from publishing; if completion first cancels the
original deadline, the later timeout is inert. Define power-off precedence,
prior read/Link outcome claims, exactly-once disconnect and cancellation,
previous timer after reconnect, another owner's timer and current status intent
ordering. A different design that allows final discovery to win needs equally
explicit and tested cancellation/teardown rules. Neither option is approved by
this draft.

Required evidence includes shared positive/negative fixtures executed by the
real store's connection, timer, callback and read/Link continuation paths,
synchronous Observation reentry, stale timer after reconnect, power loss and
two-device isolation. No target task, identity RPC, BLE wire, Android/firmware
format or historical storage migration is authorized here. Report physical
peripheral/OS behavior separately.
